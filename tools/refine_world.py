#!/usr/bin/env python3
"""Refina o mapa-múndi já gerado (data/world/map.json) SEM mudar os ids das províncias.

Uso (a partir da pasta do projeto):
  python3 tools/refine_world.py              # donos, costa e nomes (mantém o terreno salvo)
  python3 tools/refine_world.py --terreno    # também recalcula o terreno (baixa ~60 MB na 1ª vez)
  python3 tools/refine_world.py --previa previa.png [--modo terreno|cultura]

- Donos de 1444: cada âncora de tools/data/nations_*.txt cresce pelo grafo de vizinhança
  (Dijkstra a partir da província da âncora). O custo de uma província é a distância em linha
  reta até a âncora menos o alcance, mas ela só é alcançada por um caminho de vizinhos (cruzar
  uma zona marítima soma SEA_PENALTY). Assim os países ficam contíguos e não pulam mares.
  Fica com o país de menor custo; acima de LIMIT_KM fica sem dono.
- Culturas de 1444: âncoras de tools/data/cultures_1444.txt crescem do mesmo jeito, sem limite
  (toda província de terra recebe uma cultura); o mar pode ser cruzado em cadeia, mais caro.
- Terreno: relevo do ETOPO5 (NOAA, domínio público) + clima do WorldClim 2.1 (Fick & Hijmans,
  2017; não pode ser redistribuído: é baixado para tools/data/raw/, fora do git). Só o rótulo
  final de cada província vai para o map.json.
- Nomes: províncias sem cidade própria e longe de cidades recebem o nome da região geográfica
  (Natural Earth, ex.: "Deserto do Sara III"); nomes repetidos ganham numeral romano.
Requer: pillow numpy scipy
"""
import heapq, json, os, sys, urllib.request, zipfile
from collections import Counter
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.spatial import cKDTree

Image.MAX_IMAGE_PIXELS = None
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "tools/data")
RAW = os.path.join(DATA, "raw")
MAP_JSON = os.path.join(ROOT, "data/world/map.json")
IDS_PNG = os.path.join(ROOT, "assets/world/province_ids.png")
GEO = json.load(open(os.path.join(DATA, "world_georef.json")))
LON0, SX, Y0, B = GEO["lon0"], GEO["sx"], GEO["y0"], GEO["b"]

LIMIT_KM = 200       # distância máxima (já descontado o alcance da âncora) para ter dono
SEA_PENALTY = 120    # km extras para cruzar uma zona marítima
STEP = 3             # amostragem dos pixels do mapa para terreno e regiões
REMOTE_PX = 45       # sem cidade a menos disso (px) -> nome da região geográfica
SNAP_PX = 12         # cidade/âncora que cai no mar procura terra até essa distância (px)

ETOPO_URL = "https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO5/TOPO/ETOPO5/ETOPO5.DOS"
WC_URL = "https://geodata.ucdavis.edu/climate/worldclim/2_1/base/wc2.1_10m_%s.zip"

# Terrenos (nome no jogo); a ordem aqui não importa, a regra está em classify().
TERRAINS = ["geleira", "tundra", "montanhas", "colinas", "planalto", "deserto", "estepe",
            "savana", "selva", "floresta", "planície", "pântano"]


def px_to_ll(x, y):
    m = (Y0 - np.asarray(y, float)) / (1.25 * B)
    phi = 2 * np.arctan(np.exp(m)) - np.pi / 2
    lon = LON0 + np.asarray(x, float) / SX
    return np.degrees(phi / 0.8), (lon + 180.0) % 360.0 - 180.0


def ll_to_px(lat, lon):
    lat = np.radians(np.asarray(lat, float))
    x = ((np.asarray(lon, float) - LON0) % 360.0) * SX
    return x, Y0 - B * 1.25 * np.log(np.tan(np.pi / 4 + 0.8 * lat / 2))


def haversine(lat1, lon1, lat2, lon2):
    p1, p2 = np.radians(lat1), np.radians(lat2)
    a = np.sin((p2 - p1) / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(np.radians(lon2 - lon1) / 2) ** 2
    return 12742.0 * np.arcsin(np.sqrt(np.minimum(a, 1.0)))


def roman(n):
    out = ""
    for v, s in [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]:
        while n >= v:
            out += s
            n -= v
    return out


def download(url, path):
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print("baixando", url)
    urllib.request.urlretrieve(url, path + ".part")
    os.replace(path + ".part", path)


# ------------------------------------------------------------------ leitura
args = sys.argv[1:]
do_terrain = "--terreno" in args
prev_out = args[args.index("--previa") + 1] if "--previa" in args else None
prev_mode = args[args.index("--modo") + 1] if "--modo" in args else "politico"

data = json.load(open(MAP_JSON, encoding="utf-8"))
P = data["provinces"]
N = len(P)
W, H = data["width"], data["height"]
sea = np.array([p["sea"] for p in P])
nl = int((~sea).sum())
assert not sea[:nl].any(), "esperado: terra 0..nl-1, mar depois"
im = np.asarray(Image.open(IDS_PNG).convert("RGB"))
lab = im[..., 0].astype(np.int32) | (im[..., 1].astype(np.int32) << 8)
del im
assert lab.shape == (H, W) and lab.max() < N
centers = np.array([p["center"] for p in P], float)
lat, lon = px_to_ll(centers[:, 0], centers[:, 1])
neigh = [p["neighbors"] for p in P]

# amostra regular dos pixels (para terreno e regiões)
ys = np.arange(STEP // 2, H, STEP)
xs = np.arange(STEP // 2, W, STEP)
sample = lab[np.ix_(ys, xs)]
s_lat = np.broadcast_to(px_to_ll(0, ys)[0][:, None], sample.shape)
s_lon = np.broadcast_to(px_to_ll(xs, 0)[1][None, :], sample.shape)
s_land = sample < nl
cnt = np.bincount(sample.ravel(), minlength=N).astype(float)


def prov_mean(values, mask=None):
    """Média de um campo (amostrado como `sample`) por província, ignorando NaN."""
    v = values.ravel()
    ok = ~np.isnan(v)
    if mask is not None:
        ok &= mask.ravel()
    s = np.bincount(sample.ravel()[ok], weights=v[ok], minlength=N)
    c = np.bincount(sample.ravel()[ok], minlength=N)
    out = np.full(N, np.nan)
    out[c > 0] = s[c > 0] / c[c > 0]
    return out


# ------------------------------------------------------------------ costa
coastal = np.zeros(N, bool)
for i in range(nl):
    coastal[i] = any(sea[j] for j in neigh[i])

# ------------------------------------------------------------------ terreno
def fill_nan(a):
    bad = np.isnan(a)
    if not bad.any():
        return a
    idx = ndimage.distance_transform_edt(bad, return_distances=False, return_indices=True)
    return a[idx[0], idx[1]]


def grid_sample(grid, lat_top, res):
    """Amostra uma grade lat/lon global (linha 0 = lat_top, coluna 0 = lon -180) nos pontos do mapa."""
    r = np.clip(((lat_top - s_lat) / res).astype(int), 0, grid.shape[0] - 1)
    c = (((s_lon + 180.0) % 360.0) / res).astype(int) % grid.shape[1]
    return grid[r, c]


def classify(elev, rough, prec, tavg, twarm, tcold):
    if twarm < 0:
        return "geleira"
    if elev > 2600 or (elev > 1400 and rough > 450) or rough > 750:
        return "montanhas"
    if twarm < 10:
        return "tundra"
    pth = 20 * tavg + 140          # limiar de aridez de Köppen (mm/ano)
    if prec < 0.5 * pth:
        return "deserto"
    if rough > 260 or (elev > 700 and rough > 160):
        return "colinas"
    if elev > 1200:
        return "planalto"
    if prec < pth:
        return "savana" if tcold >= 15 else "estepe"
    if tcold >= 18:
        return "selva" if prec >= 1700 else "savana"
    if twarm < 17 or prec > 1300:
        return "floresta"          # taiga e florestas úmidas
    if elev < 60 and prec > 1000 and tcold > 5:
        return "pântano"
    return "planície"


terrain = [p["terrain"] for p in P]
if do_terrain:
    print("terreno: relevo (ETOPO5)...")
    etopo_path = os.path.join(RAW, "ETOPO5.DOS")
    download(ETOPO_URL, etopo_path)
    e = np.fromfile(etopo_path, "<i2").reshape(2160, 4320).astype(np.float32)
    e = np.roll(e, 2160, axis=1)                       # coluna 0 = lon -180
    mean = ndimage.uniform_filter(e, 5, mode="wrap")
    rough = np.sqrt(np.maximum(ndimage.uniform_filter(e * e, 5, mode="wrap") - mean * mean, 0))
    elev = prov_mean(np.maximum(grid_sample(e, 90.0, 1 / 12), 0))
    rgh = prov_mean(grid_sample(rough, 90.0, 1 / 12))
    print("terreno: clima (WorldClim 2.1)...")
    clim = {}
    for var in ("prec", "tavg"):
        zp = os.path.join(RAW, "wc2.1_10m_%s.zip" % var)
        download(WC_URL % var, zp)
        months = []
        with zipfile.ZipFile(zp) as z:
            for m in range(1, 13):
                with z.open("wc2.1_10m_%s_%02d.tif" % (var, m)) as f:
                    a = np.array(Image.open(f), np.float32)
                a[a < -1000] = np.nan
                months.append(fill_nan(a))
        clim[var] = np.stack(months)
    prec = prov_mean(grid_sample(clim["prec"].sum(0), 90.0, 1 / 6))
    tavg = prov_mean(grid_sample(clim["tavg"].mean(0), 90.0, 1 / 6))
    twarm = prov_mean(grid_sample(clim["tavg"].max(0), 90.0, 1 / 6))
    tcold = prov_mean(grid_sample(clim["tavg"].min(0), 90.0, 1 / 6))
    del clim, e, mean, rough
    for i in range(nl):
        if np.isnan(elev[i]):            # província pequena demais para a amostra
            terrain[i] = "planície"
            continue
        terrain[i] = classify(elev[i], rgh[i], prec[i], tavg[i], twarm[i], tcold[i])
    for i in range(nl, N):
        terrain[i] = "mar"
    print("  ", Counter(terrain[:nl]).most_common())

# ------------------------------------------------------------------ donos de 1444
print("donos...")
nations, anchors = [], []
for fn in ("nations_1444.txt", "nations_world_1444.txt"):
    for line in open(os.path.join(DATA, fn), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        tag, name, col, anc = line.split("|")
        ni = len(nations)
        first = True
        for it in [s for s in anc.split(";") if s]:
            q = it.split(",")
            anchors.append((float(q[1]), float(q[2]), float(q[3]) if len(q) > 3 else 75.0, ni, first))
            first = False
        nations.append({"tag": tag, "name": name, "color": [int(v) for v in col.split(",")]})



def seed_of(a_lat, a_lon, snap=SNAP_PX):
    """Província de terra que contém a âncora (ou a do pixel de terra mais próximo, p/ cidades costeiras)."""
    x, y = ll_to_px(a_lat, a_lon)
    xi, yi = int(x), int(y)
    if 0 <= xi < W and 0 <= yi < H:
        if lab[yi, xi] < nl:
            return int(lab[yi, xi])
        y0, x0 = max(yi - snap, 0), max(xi - snap, 0)
        win = lab[y0:yi + snap + 1, x0:xi + snap + 1]
        yy, xx = np.nonzero(win < nl)
        if len(yy):
            m = np.argmin((yy + y0 - yi) ** 2 + (xx + x0 - xi) ** 2)
            return int(win[yy[m], xx[m]])
    d = haversine(a_lat, a_lon, lat[:nl], lon[:nl])
    k = int(np.argmin(d))
    return k if d[k] < 300 else -1


def grow(anchors, limit, sea_penalty, sea_chain):
    """Dijkstra a partir das províncias das âncoras (lat, lon, alcance, ...).

    O custo de uma província é a distância em linha reta até a âncora menos o alcance, mas ela
    só é alcançada por um caminho de vizinhos; cada zona marítima no caminho soma sea_penalty.
    sea_chain=False: o mar é ponte de um passo só (terra -> mar -> terra).
    Retorna (custo, índice da âncora vencedora, província-semente de cada âncora).
    """
    dist = np.full(N, np.inf)
    src = np.full(N, -1)
    heap = []
    seeds = []
    for ai, a in enumerate(anchors):
        s = seed_of(a[0], a[1])
        seeds.append(s)
        if s < 0:
            continue
        # a província que contém a âncora é dela; entre âncoras na mesma província vence a
        # mais próxima do centro
        d0 = -a[2] + 0.01 * float(haversine(a[0], a[1], lat[s], lon[s]))
        if d0 < dist[s]:
            dist[s] = d0
            src[s] = ai
            heapq.heappush(heap, (d0, s, ai))
    while heap:
        d, u, ai = heapq.heappop(heap)
        if d > dist[u] or src[u] != ai:
            continue
        if d > limit:
            break
        a_lat, a_lon, reach = anchors[ai][:3]
        for v in neigh[u]:
            if sea[u] and sea[v] and not sea_chain:
                continue
            nd = max(d, float(haversine(a_lat, a_lon, lat[v], lon[v])) - reach)
            if sea[v]:
                nd += sea_penalty
            if nd < dist[v]:
                dist[v] = nd
                src[v] = ai
                heapq.heappush(heap, (nd, v, ai))
    return dist, src, seeds


dist, src, seeds = grow(anchors, LIMIT_KM, SEA_PENALTY, sea_chain=False)
owner = np.full(N, -1)
for i in range(nl):
    if src[i] >= 0 and dist[i] <= LIMIT_KM:
        owner[i] = anchors[src[i]][3]
# a província da capital é sempre do próprio país
# (se duas capitais caem na mesma província, a segunda vai para a vizinha livre mais próxima)
capital = {}
for ai, (a_lat, a_lon, reach, ni, first) in enumerate(anchors):
    if not first or seeds[ai] < 0:
        continue
    s = seeds[ai]
    if s in capital.values():
        free = [v for v in neigh[s] if not sea[v] and v not in capital.values()]
        if not free:
            continue
        s = min(free, key=lambda v: float(haversine(a_lat, a_lon, lat[v], lon[v])))
        print("  capital de %s movida para a província vizinha %d" % (nations[ni]["tag"], s))
    owner[s] = ni
    capital[ni] = s
lost = [nations[ni]["tag"] for ni in range(len(nations)) if ni not in capital]
print("  países:", len(capital), " sem dono:", int((owner[:nl] < 0).sum()), " sem capital em terra:", lost)

# ------------------------------------------------------------------ culturas de 1444
print("culturas...")
import colorsys
cultures, c_anchors = [], []
group, gcol, gsize = "", (128, 128, 128), {}
for line in open(os.path.join(DATA, "cultures_1444.txt"), encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("@"):
        group, col = line[1:].split("|")
        gcol = tuple(int(v) for v in col.split(","))
        continue
    cid, name, anc = line.split("|")
    ci = len(cultures)
    cultures.append({"id": cid, "name": name, "group": group, "base": gcol, "k": gsize.get(group, 0)})
    gsize[group] = gsize.get(group, 0) + 1
    for it in [q for q in anc.split(";") if q]:
        q = it.split(",")
        c_anchors.append((float(q[1]), float(q[2]), float(q[3]) if len(q) > 3 else 0.0, ci))
assert len({c["id"] for c in cultures}) == len(cultures), "id de cultura repetido"
# cor: tom do grupo, variando matiz, saturação e brilho entre as culturas do mesmo grupo
for c in cultures:
    h, sat, val = colorsys.rgb_to_hsv(*(v / 255 for v in c["base"]))
    n, k = gsize[c["group"]], c["k"]
    h = (h + (k - (n - 1) / 2) * min(0.03, 0.16 / max(n, 1))) % 1.0
    sat = min(1.0, max(0.25, sat * (0.75, 1.0, 1.2)[k % 3]))
    val = min(1.0, max(0.35, val * (1.0, 0.82, 1.12, 0.92)[k % 4]))
    c["color"] = [int(round(v * 255)) for v in colorsys.hsv_to_rgb(h, sat, val)]
    del c["base"], c["k"]
c_dist, c_src, c_seeds = grow(c_anchors, np.inf, 400, sea_chain=True)
culture = np.full(N, -1)
for i in range(nl):
    if c_src[i] >= 0:
        culture[i] = c_anchors[c_src[i]][3]
    else:                                # inalcançável (não deveria acontecer): âncora mais próxima
        culture[i] = c_anchors[int(np.argmin([haversine(a[0], a[1], lat[i], lon[i]) for a in c_anchors]))][3]
unused = [c["id"] for ci, c in enumerate(cultures) if not (culture[:nl] == ci).any()]
print("  culturas:", len(cultures), " sem província:", unused)

# ------------------------------------------------------------------ nomes
print("nomes...")
geo = json.load(open(os.path.join(DATA, "ne_50m_geography_regions.geojson"), encoding="utf-8"))["features"]
# rasteriza as regiões (as menores por cima) na grade amostrada
reg_img = Image.new("I", (len(xs), len(ys)), -1)
drw = ImageDraw.Draw(reg_img)
order = sorted(range(len(geo)), key=lambda k: geo[k]["properties"]["rank"])  # grandes primeiro
for k in order:
    g = geo[k]["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    for poly in polys:
        ring = np.array(poly[0], float)
        if len(ring) < 3:
            continue
        x, y = ll_to_px(ring[:, 1], ring[:, 0])
        # anéis que cruzam a emenda da projeção são desenhados dos dois lados
        if x.max() - x.min() > W / 2:
            x = np.where(x > W / 2, x - 360 * SX, x)
        pts = list(zip((x / STEP).tolist(), (y / STEP).tolist()))
        drw.polygon(pts, fill=k)
        if x.min() < 0:
            drw.polygon([(px + 360 * SX / STEP, py) for px, py in pts], fill=k)
reg = np.array(reg_img)
# região mais frequente em cada província
region_of = np.full(N, -1)
mask = (reg >= 0) & s_land
if mask.any():
    key = sample[mask].astype(np.int64) * len(geo) + reg[mask]
    u, c = np.unique(key, return_counts=True)
    best = {}
    for kk, cc in zip(u, c):
        p, r = divmod(int(kk), len(geo))
        if cc > best.get(p, (0, -1))[0]:
            best[p] = (cc, r)
    for p, (cc, r) in best.items():
        if cc * 2 >= cnt[p]:            # região cobre pelo menos metade da província
            region_of[p] = r

feats = json.load(open(os.path.join(DATA, "ne_10m_populated_places_simple.geojson"), encoding="utf-8"))["features"]
pnames = [f["properties"]["name"] for f in feats]
plat = np.array([float(f["properties"]["latitude"]) for f in feats])
plon = np.array([float(f["properties"]["longitude"]) for f in feats])
ppop = np.array([float(f["properties"]["pop_max"] or 0) for f in feats])
ppx, ppy = ll_to_px(plat, plon)
# província de cada cidade; cidades de litoral que caem no mar vão para a terra mais próxima
SNAP = SNAP_PX
pid_at = np.full(len(feats), -1)
for k in np.nonzero((ppx >= 0) & (ppx < W) & (ppy >= 0) & (ppy < H))[0]:
    x, y = int(ppx[k]), int(ppy[k])
    if lab[y, x] < nl:
        pid_at[k] = lab[y, x]
        continue
    y0, x0 = max(y - SNAP, 0), max(x - SNAP, 0)
    win = lab[y0:y + SNAP + 1, x0:x + SNAP + 1]
    yy, xx = np.nonzero(win < nl)
    if len(yy):
        m = np.argmin((yy + y0 - y) ** 2 + (xx + x0 - x) ** 2)
        pid_at[k] = win[yy[m], xx[m]]
city = np.full(nl, -1)
for k in np.argsort(ppop):               # a de maior população vence
    if pid_at[k] >= 0:
        city[pid_at[k]] = k
land_pl = np.nonzero(pid_at >= 0)[0]
tree = cKDTree(np.c_[ppx[land_pl], ppy[land_pl]])
DIRS = ("Leste", "Sudeste", "Sul", "Sudoeste", "Oeste", "Noroeste", "Norte", "Nordeste")


def base_name(n):
    """Tira o numeral romano e os apóstrofos de um nome já gerado."""
    n = n.rstrip("'")
    parts = n.split(" ")
    if len(parts) > 1 and parts[-1] and all(ch in "IVX" for ch in parts[-1]):
        n = " ".join(parts[:-1])
    return n


names = [base_name(p["name"]) for p in P]   # mares mantêm o nome do gerador
rank = np.zeros(N)                            # quem fica sem numeral entre nomes repetidos
by_region = 0
for i in range(nl):
    if city[i] >= 0:
        names[i] = pnames[city[i]]
        rank[i] = 1e12 + ppop[city[i]]
        continue
    d, j = tree.query(centers[i])
    if d > REMOTE_PX and region_of[i] >= 0:
        names[i] = geo[region_of[i]]["properties"]["name"]
        by_region += 1
    else:
        k = land_pl[j]
        ang = np.degrees(np.arctan2(-(centers[i][1] - ppy[k]), centers[i][0] - ppx[k])) % 360
        names[i] = "%s %s" % (pnames[k], DIRS[int(((ang + 22.5) % 360) // 45)])
    rank[i] = -d
# nomes repetidos: o principal (cidade mais populosa) fica sem numeral, os outros ganham II, III...
groups = {}
for i in range(N):
    groups.setdefault(names[i], []).append(i)
for n, ids in groups.items():
    if len(ids) > 1:
        ids.sort(key=lambda i: (-rank[i], centers[i][0]))
        for k, i in enumerate(ids[1:]):
            names[i] = "%s %s" % (n, roman(k + 2))
assert len(set(names)) == N, "nomes repetidos"
print("  com cidade própria:", int((city >= 0).sum()), " nomeadas por região:", by_region)

# capital: a província da maior cidade real a até 25 km da âncora principal, se for do país
for ai, (a_lat, a_lon, reach, ni, first) in enumerate(anchors):
    if not first or ni not in capital:
        continue
    near = np.nonzero((haversine(a_lat, a_lon, plat, plon) < 25) & (pid_at >= 0))[0]
    if len(near):
        p = int(pid_at[near[np.argmax(ppop[near])]])
        if owner[p] == ni:
            capital[ni] = p
used = [ni for ni in range(len(nations)) if ni in capital]
countries = [{"tag": nations[ni]["tag"], "name": nations[ni]["name"], "color": nations[ni]["color"],
              "capital": capital[ni]} for ni in used]

# ------------------------------------------------------------------ desenvolvimento por terreno
DEV_MULT = {"geleira": 0.0, "tundra": 0.4, "deserto": 0.5, "montanhas": 0.6, "estepe": 0.8,
            "selva": 0.7, "pântano": 0.8, "floresta": 0.9, "colinas": 0.95, "planalto": 0.9,
            "savana": 0.9, "planície": 1.1}

# ------------------------------------------------------------------ saída
for i, p in enumerate(P):
    p["name"] = names[i]
    p["terrain"] = terrain[i]
    if not p["sea"]:
        p["owner"] = nations[owner[i]]["tag"] if owner[i] >= 0 else ""
        p["coastal"] = bool(coastal[i])
        p["culture"] = cultures[culture[i]]["id"]
        if do_terrain:
            base = p.get("base_development", p["development"])
            p["base_development"] = base
            p["development"] = max(1, int(round(base * DEV_MULT.get(terrain[i], 1.0))))
data["countries"] = countries
data["cultures"] = [c for ci, c in enumerate(cultures) if (culture[:nl] == ci).any()]
with open(MAP_JSON, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
print("salvo:", MAP_JSON)

if prev_out:
    TCOL = {"geleira": (235, 240, 245), "tundra": (160, 170, 150), "montanhas": (120, 105, 95),
            "colinas": (150, 140, 100), "planalto": (170, 150, 110), "deserto": (225, 200, 140),
            "estepe": (195, 190, 120), "savana": (190, 175, 90), "selva": (40, 110, 50),
            "floresta": (60, 120, 70), "planície": (140, 180, 90), "pântano": (90, 120, 100)}
    tag_col = {c["tag"]: c["color"] for c in countries}
    pal = np.zeros((N, 3), np.uint8)
    own_i = np.zeros(N, int)
    for p in P:
        i = p["id"]
        if p["sea"]:
            pal[i] = (40, 77, 117)
        elif prev_mode == "terreno":
            pal[i] = TCOL.get(p["terrain"], (115, 110, 97))
        elif prev_mode == "cultura":
            pal[i] = cultures[culture[i]]["color"]
        else:
            pal[i] = tag_col.get(p["owner"], (115, 110, 97))
        own_i[i] = -2 if p["sea"] else (culture[i] if prev_mode == "cultura" else owner[i])
    img = pal[lab].astype(np.float32)
    e = np.zeros(lab.shape, np.float32)
    for dy, dx in ((0, 1), (1, 0)):
        a, b = lab[:H - dy, :W - dx], lab[dy:, dx:]
        v = np.where(a == b, 0.0, np.where(sea[a] & sea[b], 0.0,
                     np.where(own_i[a] != own_i[b], 0.75, 0.22)))
        e[:H - dy, :W - dx] = np.maximum(e[:H - dy, :W - dx], v)
    img = img * (1 - e[..., None]) + 10 * e[..., None]
    Image.fromarray(img.astype(np.uint8)).resize((W // 3, H // 3), Image.LANCZOS).save(prev_out)
    print("prévia:", prev_out)
