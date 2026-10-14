#!/usr/bin/env python3
"""Gera o mapa-múndi do jogo a partir de uma imagem de províncias (estilo mapchart.net).

Uso: python3 tools/gen_world.py caminho/da/imagem.png [preview.png]
Saída: data/world/map.json e assets/world/province_ids.png

- Cada região fechada da imagem (cinza de terra cercado por linhas) vira uma província.
- Branco = mar; mares grandes viram zonas marítimas (grade de sementes, mais densa perto da costa).
- A imagem é georreferenciada (projeção Miller, ajustada contra a costa do Natural Earth)
  para dar nomes (cidades reais) e donos de 1444 (âncoras de tools/data/nations_*.txt).
Requer: pillow numpy scipy
"""
import json, math, os, sys
import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import cKDTree

Image.MAX_IMAGE_PIXELS = None
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEO = json.load(open(os.path.join(ROOT, "tools/data/world_georef.json")))
LON0, SX, Y0, B = GEO["lon0"], GEO["sx"], GEO["y0"], GEO["b"]
CROP_H = GEO["crop_h"]
SEA_MIN = 3000          # componentes brancos menores viram lagos (terra)
CORE_MIN = 30           # área mínima de uma região para ser província própria
FINE, COARSE, NEAR = 110, 300, 170


def merc(phi):
    return np.log(np.tan(np.pi / 4 + phi / 2))


def ll_to_px(lat, lon):
    lat = np.radians(np.asarray(lat, float))
    return (np.asarray(lon, float) - LON0) * SX, Y0 - B * 1.25 * merc(0.8 * lat)


def px_to_ll(x, y):
    m = (Y0 - np.asarray(y, float)) / (1.25 * B)
    phi = 2 * np.arctan(np.exp(m)) - np.pi / 2
    return np.degrees(phi / 0.8), LON0 + np.asarray(x, float) / SX


def haversine(lat1, lon1, lat2, lon2):
    p1, p2 = np.radians(lat1), np.radians(lat2)
    a = np.sin((p2 - p1) / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(np.radians(lon2 - lon1) / 2) ** 2
    return 12742.0 * np.arcsin(np.sqrt(a))


def roman(n):
    out = ""
    for v, s in [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]:
        while n >= v:
            out += s
            n -= v
    return out


src = sys.argv[1]
prev_out = sys.argv[2] if len(sys.argv) > 2 else None
print("lendo imagem...")
g = np.asarray(Image.open(src).convert("L"))[:CROP_H].copy()
H, W = g.shape
print("tamanho", W, H)

# ---------------------------------------------------------------- mar e terra
sea0 = g >= 240
lab_s, ns = ndimage.label(sea0, structure=np.ones((3, 3)))
areas = np.bincount(lab_s.ravel(), minlength=ns + 1)
big_ids = [i for i in range(1, ns + 1) if areas[i] >= SEA_MIN]
sea = np.isin(lab_s, big_ids)
del lab_s
land = ~sea
print("componentes de mar grandes:", len(big_ids))

# ---------------------------------------------------------------- províncias de terra
core = land & (g >= 211) & (g < 240)
lab_c, nc = ndimage.label(core)
ca = np.bincount(lab_c.ravel(), minlength=nc + 1)
keep = np.nonzero(ca >= CORE_MIN)[0]
keep = keep[keep > 0]
remap = np.zeros(nc + 1, np.int32)
remap[keep] = np.arange(1, len(keep) + 1)
seeds = remap[lab_c]
del lab_c, core
nl = len(keep)
# ilhas/pedaços de terra sem nenhuma região própria viram província
lab_l, nlc = ndimage.label(land, structure=np.ones((3, 3)))
has = np.zeros(nlc + 1, bool)
has[np.unique(lab_l[seeds > 0])] = True
la = np.bincount(lab_l.ravel(), minlength=nlc + 1)
extra = [i for i in range(1, nlc + 1) if not has[i] and la[i] >= 8]
tiny = [i for i in range(1, nlc + 1) if not has[i] and la[i] < 8]
for i in extra:
    nl += 1
    seeds[lab_l == i] = nl
if tiny:
    m = np.isin(lab_l, tiny)
    land[m] = False
    sea[m] = True
del lab_l
print("províncias de terra:", nl, "(ilhas sem região própria:", len(extra), ")")
idx = ndimage.distance_transform_edt(seeds == 0, return_distances=False, return_indices=True)
lab = seeds[idx[0], idx[1]]
del idx, seeds
lab[~land] = 0
lab = lab.astype(np.int32) - 1      # terra: 0..nl-1; resto: -1

# ---------------------------------------------------------------- zonas marítimas
print("zonas marítimas...")
dist_land = ndimage.distance_transform_edt(~land)
lab_sea, nsc = ndimage.label(sea, structure=np.ones((3, 3)))
sea_n = 0
sl_all = ndimage.find_objects(lab_sea)
for ci in range(1, nsc + 1):
    sl = sl_all[ci - 1]
    if sl is None:
        continue
    m = lab_sea[sl] == ci
    if m.sum() < 1:
        continue
    d = dist_land[sl]
    h, w = m.shape
    sd = np.zeros(m.shape, bool)
    y0s, x0s = sl[0].start, sl[1].start
    for spacing, sel in ((FINE, d < NEAR), (COARSE, d >= NEAR)):
        ys = np.arange((-y0s) % spacing + spacing // 2 - spacing // 2, h, spacing)
        xs = np.arange((-x0s) % spacing, w, spacing)
        for yy in ys:
            for xx in xs:
                if m[yy, xx] and sel[yy, xx]:
                    sd[yy, xx] = True
    if not sd.any():
        yy, xx = np.nonzero(m)
        k = np.argmin((yy - yy.mean()) ** 2 + (xx - xx.mean()) ** 2)
        sd[yy[k], xx[k]] = True
    ii = ndimage.distance_transform_edt(~sd, return_distances=False, return_indices=True)
    sid = np.zeros(m.shape, np.int32)
    sid[sd] = np.arange(1, sd.sum() + 1)
    z = sid[ii[0], ii[1]]
    sub = lab[sl]
    sub[m] = nl + sea_n + z[m] - 1
    sea_n += int(sd.sum())
del lab_sea, dist_land
N = nl + sea_n
print("zonas marítimas:", sea_n, " total:", N)
assert lab.min() >= 0

# ---------------------------------------------------------------- estatísticas
print("centros e vizinhanças...")
cnt = np.zeros(N)
sx_ = np.zeros(N)
sy_ = np.zeros(N)
xs_row = np.arange(W, dtype=np.float64)
nb = set()
CH = 200
for r0 in range(0, H, CH):
    blk = lab[r0:r0 + CH]
    flat = blk.ravel()
    cnt += np.bincount(flat, minlength=N)
    sx_ += np.bincount(flat, weights=np.tile(xs_row, blk.shape[0]), minlength=N)
    sy_ += np.bincount(flat, weights=np.repeat(np.arange(r0, r0 + blk.shape[0], dtype=np.float64), W), minlength=N)
    for a, b in ((blk[:, :-1], blk[:, 1:]), (blk[:-1], blk[1:])):
        mk = a != b
        lo = np.minimum(a[mk], b[mk]).astype(np.int64)
        hi = np.maximum(a[mk], b[mk]).astype(np.int64)
        for c in np.unique(lo * N + hi):
            nb.add(int(c))
    # junção entre blocos
    if r0 + CH < H:
        a, b = lab[r0 + CH - 1], lab[r0 + CH]
        mk = a != b
        lo = np.minimum(a[mk], b[mk]).astype(np.int64)
        hi = np.maximum(a[mk], b[mk]).astype(np.int64)
        for c in np.unique(lo * N + hi):
            nb.add(int(c))
neigh = [[] for _ in range(N)]
for c in nb:
    a, b = divmod(c, N)
    neigh[a].append(b)
    neigh[b].append(a)
cx = sx_ / np.maximum(cnt, 1)
cy = sy_ / np.maximum(cnt, 1)
# centro dentro da própria província
objs = ndimage.find_objects(lab + 1)
centers = []
for i in range(N):
    x, y = int(round(cx[i])), int(round(cy[i]))
    x, y = min(max(x, 0), W - 1), min(max(y, 0), H - 1)
    if lab[y, x] != i:
        sl = objs[i]
        yy, xx = np.nonzero(lab[sl] == i)
        k = np.argmin((yy + sl[0].start - cy[i]) ** 2 + (xx + sl[1].start - cx[i]) ** 2)
        x, y = xx[k] + sl[1].start, yy[k] + sl[0].start
    centers.append((float(x), float(y)))
centers = np.array(centers)
lat, lon = px_to_ll(centers[:, 0], centers[:, 1])

# ---------------------------------------------------------------- nomes (cidades reais)
print("nomes...")
feats = json.load(open(os.path.join(ROOT, "tools/data/ne_10m_populated_places_simple.geojson"), encoding="utf-8"))["features"]
pl = []
for f in feats:
    p = f["properties"]
    pl.append((p["name"], float(p["latitude"]), float(p["longitude"]), float(p["pop_max"] or 0)))
pnames = [p[0] for p in pl]
plat = np.array([p[1] for p in pl])
plon = np.array([p[2] for p in pl])
ppop = np.array([p[3] for p in pl])
ppx, ppy = ll_to_px(plat, plon)
on = (ppx >= 0) & (ppx < W) & (ppy >= 0) & (ppy < H)
pid_at = np.full(len(pl), -1)
pid_at[on] = lab[ppy[on].astype(int), ppx[on].astype(int)]
big = ppop >= 1e6
print("cidades >1M sobre terra: %.0f%%" % (100 * np.mean((pid_at[big & on] >= 0) & (pid_at[big & on] < nl))))
best = np.full(nl, -1)
for k in np.argsort(ppop):               # a de maior população vence
    p = pid_at[k]
    if 0 <= p < nl:
        best[p] = k
land_pl = np.nonzero((pid_at >= 0) & (pid_at < nl))[0]
tree = cKDTree(np.c_[ppx[land_pl], ppy[land_pl]])
DIRS = ["Leste", "Sudeste", "Sul", "Sudoeste", "Oeste", "Noroeste", "Norte", "Nordeste"]
names = [""] * N
pop_of = np.zeros(N)
for i in range(nl):
    if best[i] >= 0:
        names[i] = pnames[best[i]]
        pop_of[i] = ppop[best[i]]
    else:
        d, j = tree.query(centers[i])
        k = land_pl[j]
        ang = math.degrees(math.atan2(-(centers[i][1] - ppy[k]), centers[i][0] - ppx[k])) % 360
        names[i] = "%s %s" % (pnames[k], DIRS[int(((ang + 22.5) % 360) // 45)])
        pop_of[i] = ppop[k] * 0.1
for i in range(nl, N):
    d, j = tree.query(centers[i])
    if d < 130:
        names[i] = "Mar de %s" % pnames[land_pl[j]]
    else:
        la_, lo_ = lat[i], lon[i]
        if la_ > 66:
            o = "Oceano Ártico"
        elif -70 < lo_ < 20 and la_ > -60:
            o = "Atlântico Norte" if la_ > 0 else "Atlântico Sul"
        elif 20 <= lo_ < 120 and la_ < 30:
            o = "Oceano Índico"
        else:
            o = "Pacífico Norte" if la_ > 0 else "Pacífico Sul"
        names[i] = o
seen = {}
for i in range(N):
    n = names[i]
    seen[n] = seen.get(n, 0) + 1
    if seen[n] > 1:
        names[i] = "%s %s" % (n, roman(seen[n]))
# garante unicidade absoluta
final = set()
for i in range(N):
    while names[i] in final:
        names[i] += "'"
    final.add(names[i])

# ---------------------------------------------------------------- donos de 1444
print("donos...")
nations, anchors = [], []
for fn in ("nations_1444.txt", "nations_world_1444.txt"):
    for line in open(os.path.join(ROOT, "tools/data", fn), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        tag, name, col, anc = line.split("|")
        ni = len(nations)
        first = True
        for it in [s for s in anc.split(";") if s]:
            p = it.split(",")
            anchors.append((float(p[1]), float(p[2]), float(p[3]) if len(p) > 3 else 75.0, ni, first))
            first = False
        nations.append({"tag": tag, "name": name, "color": [int(v) for v in col.split(",")]})
A = np.array([(a[0], a[1], a[2], a[3]) for a in anchors])
owner = np.full(N, -1)
for i in range(nl):
    d = haversine(lat[i], lon[i], A[:, 0], A[:, 1]) - A[:, 2]
    k = int(np.argmin(d))
    if d[k] <= 200:
        owner[i] = int(A[k, 3])
# capital = província própria mais próxima da âncora principal
capital = {}
for ni, n in enumerate(nations):
    mine = np.nonzero(owner[:nl] == ni)[0]
    if len(mine) == 0:
        continue
    ca = next(a for a in anchors if a[3] == ni and a[4])
    d = haversine(lat[mine], lon[mine], ca[0], ca[1])
    capital[ni] = int(mine[np.argmin(d)])
used = sorted(capital)
tag_idx = {ni: j for j, ni in enumerate(used)}
countries = [{"tag": nations[ni]["tag"], "name": nations[ni]["name"], "color": nations[ni]["color"],
              "capital": capital[ni]} for ni in used]
print("países com terras:", len(countries), " províncias sem dono:", int(np.sum(owner[:nl] < 0)))

# ---------------------------------------------------------------- saída
provinces = []
for i in range(N):
    sea_ = i >= nl
    h = (i * 0.61803398875) % 1.0
    import colorsys
    c = [int(v * 255) for v in colorsys.hsv_to_rgb(h, 0.5 + 0.4 * ((i * 7) % 5) / 4, 0.55 + 0.4 * ((i * 3) % 4) / 3)]
    provinces.append({
        "id": i, "name": names[i], "color": c, "sea": sea_,
        "owner": "" if sea_ or owner[i] < 0 else nations[owner[i]]["tag"],
        "terrain": "mar" if sea_ else "—",
        "development": 0 if sea_ else int(min(30, 2 + max(0, 3 * (math.log10(max(pop_of[i], 1)) - 4)))),
        "center": [round(float(centers[i][0]), 1), round(float(centers[i][1]), 1)],
        "neighbors": sorted(neigh[i]),
    })
os.makedirs(os.path.join(ROOT, "data/world"), exist_ok=True)
os.makedirs(os.path.join(ROOT, "assets/world"), exist_ok=True)
with open(os.path.join(ROOT, "data/world/map.json"), "w", encoding="utf-8") as f:
    json.dump({"width": W, "height": H, "countries": countries, "provinces": provinces}, f, ensure_ascii=False, separators=(",", ":"))
rgb = np.zeros((H, W, 3), np.uint8)
rgb[..., 0] = lab & 255
rgb[..., 1] = (lab >> 8) & 255
Image.fromarray(rgb).save(os.path.join(ROOT, "assets/world/province_ids.png"), optimize=False, compress_level=6)
print("salvo: %d províncias (%d terra, %d mar)" % (N, nl, sea_n))

if prev_out:
    pal = np.zeros((N + 1, 3), np.uint8)
    for p in provinces:
        if p["sea"]:
            pal[p["id"]] = (40, 76, 117)
        elif p["owner"]:
            pal[p["id"]] = next(c["color"] for c in countries if c["tag"] == p["owner"])
        else:
            pal[p["id"]] = (115, 110, 97)
    img = pal[lab]
    edge = np.zeros((H, W), bool)
    edge[:, 1:] |= lab[:, 1:] != lab[:, :-1]
    edge[1:, :] |= lab[1:, :] != lab[:-1, :]
    img[edge] = (img[edge] * 0.6).astype(np.uint8)
    Image.fromarray(img).resize((W // 3, H // 3), Image.BILINEAR).save(prev_out)
