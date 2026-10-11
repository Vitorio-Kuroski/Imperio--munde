#!/usr/bin/env python3
"""Gera o mapa real (Europa + Oriente Medio + Norte da Africa) com ~1000 provincias.

Entradas (tools/data/):
  ne_50m_land.geojson   Natural Earth (dominio publico): contorno real da terra
  nations_1444.txt      nacoes de 1444 e cidades-ancora (lat/lon)

Saidas (a partir da pasta do projeto):
  assets/provinces.png     cor unica por provincia (para humanos)
  assets/province_ids.png  id da provincia em R (baixo) e G (alto) -> usado pelo Godot
  data/map.json            provincias, paises, vizinhos

Uso: python3 tools/gen_map.py [alvo_de_provincias_de_terra]   (padrao 940)
Requer: Pillow, numpy, scipy
"""
import colorsys
import json
import math
import random
import sys
from collections import defaultdict

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.spatial import cKDTree

# ------------------------------------------------------------ geometria do mapa
LON0, LON1 = -12.0, 63.0
LAT0, LAT1 = 14.0, 71.0          # LAT0 = sul, LAT1 = norte
W = 2048
PXDEG = W / (LON1 - LON0)         # pixels por grau de longitude
RAD = 180.0 / math.pi


def merc(lat):
    lat = np.clip(lat, -85, 85)
    return np.log(np.tan(np.pi / 4 + np.radians(lat) / 2))


MY1 = float(merc(LAT1))
H = int(round((float(merc(LAT1)) - float(merc(LAT0))) * PXDEG * RAD))


def to_px(lat, lon):
    x = (np.asarray(lon, dtype=np.float64) - LON0) * PXDEG
    y = (MY1 - merc(np.asarray(lat, dtype=np.float64))) * PXDEG * RAD
    return x, y


def to_ll(x, y):
    lon = LON0 + np.asarray(x) / PXDEG
    m = MY1 - np.asarray(y) / (PXDEG * RAD)
    lat = np.degrees(2 * np.arctan(np.exp(m)) - np.pi / 2)
    return lat, lon


def km_per_px(lat):
    return 111.32 * math.cos(math.radians(lat)) / PXDEG


def haversine(lat1, lon1, lat2, lon2):
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dphi = p2 - p1
    dl = np.radians(lon2) - np.radians(lon1)
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * 6371.0 * np.arcsin(np.sqrt(a))


random.seed(1444)
rng = np.random.default_rng(1444)
LAND_TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 940

# ------------------------------------------------------------ mascara de terra
print("Rasterizando terra...", flush=True)
gj = json.load(open("tools/data/ne_50m_land.geojson", encoding="utf-8"))
polys = []
for f in gj["features"]:
    g = f["geometry"]
    parts = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    for rings in parts:
        ext = np.array(rings[0])
        if ext[:, 1].max() < LAT0 - 5 or ext[:, 1].min() > LAT1 + 5:
            continue
        if ext[:, 0].max() < LON0 - 5 or ext[:, 0].min() > LON1 + 5:
            continue
        px = [np.stack(to_px(np.array(r)[:, 1], np.array(r)[:, 0]), axis=1) for r in rings]
        a = px[0]
        area = abs(np.dot(a[:, 0], np.roll(a[:, 1], 1)) - np.dot(a[:, 1], np.roll(a[:, 0], 1))) / 2
        polys.append((area, px))
polys.sort(key=lambda t: -t[0])
mimg = Image.new("L", (W, H), 0)
dr = ImageDraw.Draw(mimg)
for _, px in polys:
    dr.polygon([tuple(p) for p in px[0]], fill=1)
    for hole in px[1:]:
        dr.polygon([tuple(p) for p in hole], fill=0)
land = np.array(mimg, dtype=bool)

# remove ilhotas minusculas
STRUCT = np.ones((3, 3))
lab, ncomp = ndimage.label(land, structure=STRUCT)
areas = np.bincount(lab.ravel(), minlength=ncomp + 1)
keep = areas >= 90
keep[0] = False
land &= keep[lab]
lab, ncomp = ndimage.label(land, structure=STRUCT)
print(f"  mapa {W}x{H}, {ncomp} massas de terra", flush=True)

# snap para pixel de terra mais proximo
_, (snap_y, snap_x) = ndimage.distance_transform_edt(~land, return_indices=True)


def snap(x, y):
    xi = int(min(max(round(x), 0), W - 1))
    yi = int(min(max(round(y), 0), H - 1))
    return float(snap_x[yi, xi]), float(snap_y[yi, xi])


# ------------------------------------------------------------ nacoes e ancoras
DEF_REACH = 75.0
nations = []
anchors = []   # dict(name, lat, lon, reach, nation_idx, x, y)
for line in open("tools/data/nations_1444.txt", encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    tag, name, col, anc = line.split("|")
    ni = len(nations)
    first = True
    cap_anchor = None
    for it in [s for s in anc.split(";") if s]:
        p = it.split(",")
        reach = float(p[3]) if len(p) > 3 else DEF_REACH
        x, y = to_px(float(p[1]), float(p[2]))
        sx, sy = snap(float(x), float(y))
        anchors.append({"name": p[0], "lat": float(p[1]), "lon": float(p[2]), "reach": reach,
                        "nation": ni, "x": sx, "y": sy, "capital": first})
        if first:
            cap_anchor = len(anchors) - 1
            first = False
    nations.append({"tag": tag, "name": name, "color": [int(v) for v in col.split(",")],
                    "cap_anchor": cap_anchor})

# remove ancoras que caem no mesmo pixel / muito coladas
kept = []
for a in anchors:
    if any(math.hypot(a["x"] - b["x"], a["y"] - b["y"]) < 10 for b in kept):
        if a["capital"]:           # capital tem prioridade
            kept = [b for b in kept if math.hypot(a["x"] - b["x"], a["y"] - b["y"]) >= 10]
            kept.append(a)
        continue
    kept.append(a)
anchors = kept
cap_names = {a["nation"]: a["name"] for a in anchors if a["capital"]}
print(f"  {len(nations)} nacoes, {len(anchors)} ancoras", flush=True)


# ------------------------------------------------------------ densidade das sementes de preenchimento
def spacing_km(lat, lon):
    if lat < 31 and lon < 30:
        return 320      # Saara
    if lat < 32 and lon > 34 and lon < 56:
        return 320      # Arabia
    if lat < 30 and lon >= 30:
        return 260
    if lat > 62:
        return 220
    if lon > 38 or lat > 58:
        return 210      # Russia
    if lon > 25 and lat > 44:
        return 140      # Europa oriental
    if lat >= 42 and lon <= 25:
        return 85
    if lon > 40 or (lat < 38 and lon > 30):
        return 150      # Oriente Medio
    if lat < 37 and lon < 12:
        return 140      # Magrebe
    return 100


ys_land, xs_land = np.nonzero(land)
cand_idx = rng.permutation(len(xs_land))[:200000]
cand = np.stack([xs_land[cand_idx], ys_land[cand_idx]], axis=1).astype(np.float64)
cand_lat, cand_lon = to_ll(cand[:, 0], cand[:, 1])
cand_r = np.array([spacing_km(a, b) / km_per_px(a) for a, b in zip(cand_lat, cand_lon)])


def build_fill(mult):
    cell = 64.0
    grid = defaultdict(list)
    pts = []

    def add(x, y):
        grid[(int(x // cell), int(y // cell))].append(len(pts))
        pts.append((x, y))

    for a in anchors:
        add(a["x"], a["y"])
    out = []
    for (x, y), r in zip(cand, cand_r):
        r *= mult
        reach = int(r // cell) + 1
        cx, cy = int(x // cell), int(y // cell)
        ok = True
        for gx in range(cx - reach, cx + reach + 1):
            for gy in range(cy - reach, cy + reach + 1):
                for k in grid.get((gx, gy), ()):
                    px_, py_ = pts[k]
                    if (px_ - x) ** 2 + (py_ - y) ** 2 < r * r:
                        ok = False
                        break
                if not ok:
                    break
            if not ok:
                break
        if ok:
            add(x, y)
            out.append((float(x), float(y)))
    return out


# conta ilhas sem ancora (ganham uma semente cada)
anchor_comp = {int(lab[int(a["y"]), int(a["x"])]) for a in anchors}
extra_islands = [c for c in range(1, ncomp + 1) if c not in anchor_comp]

lo, hi = 0.3, 4.0
fill = []
for _ in range(14):
    mid = (lo + hi) / 2
    fill = build_fill(mid)
    total = len(anchors) + len(fill) + len(extra_islands)
    if abs(total - LAND_TARGET) <= 6:
        break
    if total > LAND_TARGET:
        lo = mid
    else:
        hi = mid
print(f"  sementes: {len(anchors)} ancoras + {len(fill)} preenchimento + {len(extra_islands)} ilhas", flush=True)

# lista final de sementes de terra
lseeds = []   # dict(x, y, anchor_idx|None)
for i, a in enumerate(anchors):
    lseeds.append({"x": a["x"], "y": a["y"], "anchor": i})
for x, y in fill:
    lseeds.append({"x": x, "y": y, "anchor": None})
for c in extra_islands:
    yy_, xx_ = np.nonzero(lab == c)
    k = len(xx_) // 2
    lseeds.append({"x": float(xx_[k]), "y": float(yy_[k]), "anchor": None})
L = len(lseeds)

# ------------------------------------------------------------ mares
SEAS = [
    ("Mar do Norte", 56, 3), ("Mar do Norte Setentrional", 60.5, 2), ("Canal da Mancha", 50.0, -2.0),
    ("Mar da Irlanda", 53.6, -5.0), ("Mar Céltico", 50.5, -7.5), ("Oceano Atlântico Norte", 54, -11),
    ("Atlântico das Hébridas", 58.5, -8), ("Golfo da Biscaia", 45.5, -5.5), ("Atlântico Ibérico", 38.5, -11),
    ("Atlântico Marroquino", 31, -10.5), ("Mar de Alborão", 36.0, -3.0), ("Mediterrâneo Ocidental", 39.5, 3.5),
    ("Mar Tirreno", 40, 12), ("Mar da Ligúria", 43.5, 8.5), ("Mar Adriático", 43.0, 15.5), ("Mar Jônico", 38.0, 18.0),
    ("Mediterrâneo Central", 35.5, 12), ("Golfo da Sirte", 32.2, 18.5), ("Mediterrâneo Oriental", 34.0, 29),
    ("Mar Egeu", 38.7, 25.0), ("Mar de Mármara", 40.7, 28.0), ("Mar Negro Ocidental", 43.5, 30.5),
    ("Mar Negro Oriental", 43.0, 37.0), ("Mar de Azov", 46.0, 36.8), ("Mar Cáspio Norte", 45.5, 51.0),
    ("Mar Cáspio Sul", 38.5, 51.5), ("Mar Báltico Meridional", 55, 17), ("Mar Báltico Central", 58.5, 20),
    ("Golfo da Finlândia", 59.9, 26), ("Golfo de Bótnia", 62.5, 20), ("Cattegat", 57.0, 10.8),
    ("Mar da Noruega", 66, 5), ("Mar de Barents", 70.5, 35), ("Mar Branco", 65.5, 37.5),
    ("Mar Vermelho Setentrional", 26, 35), ("Mar Vermelho Meridional", 18, 40), ("Golfo Pérsico", 27.5, 51.5),
    ("Golfo de Omã", 24.5, 58.5), ("Mar da Arábia", 17.5, 58.5), ("Golfo de Suez", 28.5, 33.0),
]
sea_seeds = []
for n, la, lo_ in SEAS:
    x, y = to_px(la, lo_)
    xi, yi = int(round(float(x))), int(round(float(y)))
    if 0 <= xi < W and 0 <= yi < H and not land[yi, xi]:
        sea_seeds.append({"name": n, "x": float(x), "y": float(y)})
    else:
        print("  aviso: mar fora do alvo ->", n)
# grade para oceanos grandes
step = 330.0
gy = step / 2
fill_sea = 0
while gy < H:
    gx = step / 2
    while gx < W:
        x = gx + random.uniform(-0.25, 0.25) * step
        y = gy + random.uniform(-0.25, 0.25) * step
        xi, yi = int(x), int(y)
        if 0 <= xi < W and 0 <= yi < H and not land[yi, xi]:
            if all(math.hypot(x - s["x"], y - s["y"]) > step * 0.55 for s in sea_seeds):
                sea_seeds.append({"name": None, "x": x, "y": y})
                fill_sea += 1
        gx += step
    gy += step
S = len(sea_seeds)
N = L + S
print(f"  {L} provincias de terra + {S} de mar = {N}", flush=True)

# ------------------------------------------------------------ voronoi com ruido
print("Voronoi...", flush=True)
yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
xw = xx + 7 * np.sin(yy / 37.0 + 1.3) + 5 * np.sin(yy / 12.0 + xx / 51.0) + 2.5 * np.sin(xx / 6.0)
yw = yy + 7 * np.sin(xx / 43.0 + 0.4) + 5 * np.sin(xx / 14.0 + yy / 47.0) + 2.5 * np.sin(yy / 8.0)

objs = ndimage.find_objects(lab)
ids = None
for attempt in range(4):
    ids = np.full((H, W), -1, dtype=np.int32)
    ls_xy = np.array([[s_["x"], s_["y"]] for s_ in lseeds])
    lseed_comp = np.array([lab[int(s_["y"]), int(s_["x"])] for s_ in lseeds])
    for c in range(1, ncomp + 1):
        sl = objs[c - 1]
        m = lab[sl] == c
        sy_, sx_ = np.nonzero(m)
        gy_, gx_ = sy_ + sl[0].start, sx_ + sl[1].start
        members = np.nonzero(lseed_comp == c)[0]
        if len(members) == 0:
            continue
        if len(members) == 1:
            ids[gy_, gx_] = members[0]
        else:
            tree = cKDTree(ls_xy[members])
            _, nn = tree.query(np.stack([xw[gy_, gx_], yw[gy_, gx_]], axis=1))
            ids[gy_, gx_] = members[nn]
    areas_l = np.bincount(ids[land].ravel(), minlength=len(lseeds))
    bad = [i for i, s_ in enumerate(lseeds) if s_["anchor"] is None and areas_l[i] < 45]
    if not bad:
        break
    bad = set(bad)
    lseeds = [s_ for i, s_ in enumerate(lseeds) if i not in bad]
    print(f"  podadas {len(bad)} sementes minusculas", flush=True)
L = len(lseeds)
N = L + S

ss_xy = np.array([[s["x"], s["y"]] for s in sea_seeds])
wy, wx = np.nonzero(~land)
tree = cKDTree(ss_xy)
_, nn = tree.query(np.stack([xw[wy, wx], yw[wy, wx]], axis=1), workers=-1)
ids[wy, wx] = L + nn
assert (ids >= 0).all()

# ------------------------------------------------------------ imagens
used = set()
colors = []
for i in range(N):
    c = ((i * 53 + 20) % 256, (i * 97 + 40) % 256, (i * 29 + 60) % 256)
    while c in used:
        c = ((c[0] + 1) % 256, c[1], c[2])
    used.add(c)
    colors.append(c)
palette = np.array(colors, dtype=np.uint8)
Image.fromarray(palette[ids], "RGB").save("assets/provinces.png", optimize=True)
idimg = np.zeros((H, W, 3), dtype=np.uint8)
idimg[..., 0] = ids & 255
idimg[..., 1] = ids >> 8
Image.fromarray(idimg, "RGB").save("assets/province_ids.png", optimize=True)

# ------------------------------------------------------------ vizinhos e centros
pairs = set()
for a, b in ((ids[:, :-1], ids[:, 1:]), (ids[:-1, :], ids[1:, :])):
    m = a != b
    lo_ = np.minimum(a[m], b[m]).astype(np.int64)
    hi_ = np.maximum(a[m], b[m]).astype(np.int64)
    pairs.update(np.unique(lo_ * N + hi_).tolist())
neigh = [set() for _ in range(N)]
for k in pairs:
    p, q = divmod(k, N)
    neigh[p].add(q)
    neigh[q].add(p)

flat = ids.ravel()
cnt = np.bincount(flat, minlength=N).astype(np.float64)
cx = np.bincount(flat, weights=xx.ravel(), minlength=N) / np.maximum(cnt, 1)
cy = np.bincount(flat, weights=yy.ravel(), minlength=N) / np.maximum(cnt, 1)
clat, clon = to_ll(cx, cy)

# ------------------------------------------------------------ donos de 1444
print("Atribuindo donos de 1444...", flush=True)
A_lat = np.array([a["lat"] for a in anchors])
A_lon = np.array([a["lon"] for a in anchors])
A_reach = np.array([a["reach"] for a in anchors])
A_nat = np.array([a["nation"] for a in anchors])
owner = [-1] * N       # indice da nacao, -1 = sem dono
nearest_anchor = [0] * N
for i in range(L):
    d = haversine(clat[i], clon[i], A_lat, A_lon)
    score = d - A_reach
    k = int(np.argmin(score))
    nearest_anchor[i] = int(np.argmin(d))
    owner[i] = int(A_nat[k]) if score[k] <= 200 else -1
for i, s in enumerate(lseeds):
    if s["anchor"] is not None:
        owner[i] = int(A_nat[s["anchor"]])
        nearest_anchor[i] = s["anchor"]

# ------------------------------------------------------------ nomes
DIRS = ["Leste", "Nordeste", "Norte", "Noroeste", "Oeste", "Sudoeste", "Sul", "Sudeste"]
names = [None] * N
for i, s in enumerate(lseeds):
    if s["anchor"] is not None:
        names[i] = anchors[s["anchor"]]["name"]
for i in range(L):
    if names[i] is not None:
        continue
    k = nearest_anchor[i]
    if owner[i] >= 0:
        # ancora mais proxima do mesmo dono
        same = np.nonzero(A_nat == owner[i])[0]
        d = haversine(clat[i], clon[i], A_lat[same], A_lon[same])
        k = int(same[int(np.argmin(d))])
    a = anchors[k]
    dx = (clon[i] - a["lon"]) * math.cos(math.radians(a["lat"])) * 111.32
    dy = (clat[i] - a["lat"]) * 111.32
    ang = (math.degrees(math.atan2(dy, dx)) + 360 + 22.5) % 360
    dname = DIRS[int(ang // 45)]
    base = f"{a['name']} {dname}"
    if owner[i] < 0:
        base = f"Terras de {a['name']} ({dname})"
    names[i] = base
sea_counter = defaultdict(int)
for j, s in enumerate(sea_seeds):
    if s["name"]:
        names[L + j] = s["name"]
for j, s in enumerate(sea_seeds):
    if names[L + j] is None:
        d = [math.hypot(s["x"] - t["x"], s["y"] - t["y"]) if t["name"] else 1e9 for t in sea_seeds]
        base = sea_seeds[int(np.argmin(d))]["name"]
        names[L + j] = f"Águas de {base}"
# unicidade
seen = defaultdict(int)
for i in range(N):
    seen[names[i]] += 1
dup = defaultdict(int)
for i in range(N):
    if seen[names[i]] > 1:
        dup[names[i]] += 1
        if dup[names[i]] > 1:
            names[i] = f"{names[i]} {['', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII'][min(dup[names[i]] - 1, 7)]}"

# ------------------------------------------------------------ terreno e desenvolvimento
def box(lat, lon, la0, la1, lo0, lo1):
    return la0 <= lat <= la1 and lo0 <= lon <= lo1


def terrain_for(lat, lon):
    r = random.random()
    if (box(lat, lon, 45.3, 47.7, 6.0, 14.0) or box(lat, lon, 42.3, 43.3, -2.0, 3.0) or
            box(lat, lon, 46.5, 49.5, 20.5, 26.5) or box(lat, lon, 41.0, 43.6, 40.0, 48.5) or
            box(lat, lon, 36.5, 38.5, 30.0, 37.0) or box(lat, lon, 30.0, 36.0, 46.0, 52.5) or
            box(lat, lon, 60.0, 69.0, 6.0, 15.0) or box(lat, lon, 30.5, 35.5, -9.0, -1.0)):
        return "montanha" if r < 0.6 else "colina"
    if (lat < 31.5 and lon < 29) or (lat < 32.5 and 34 < lon < 56) or box(lat, lon, 27, 36, 54, 63):
        return "deserto" if r < 0.8 else "colina"
    if box(lat, lon, 51, 53.5, 24, 31):
        return "pântano" if r < 0.5 else "floresta"
    if box(lat, lon, 44, 52, 30, 55) and r < 0.7:
        return "estepe"
    if lat > 56:
        return "floresta" if r < 0.7 else ("colina" if r < 0.85 else "planície")
    if r < 0.45:
        return "planície"
    if r < 0.7:
        return "colina"
    if r < 0.88:
        return "floresta"
    return "pântano" if (lat > 51 and r < 0.93) else "planície"


def dev_for(lat, lon):
    if box(lat, lon, 43, 46, 7, 14) or box(lat, lon, 50, 53, 2, 7):
        return 9
    if box(lat, lon, 36, 40.5, 12, 18):
        return 7
    if box(lat, lon, 44, 55, -5, 20):
        return 7
    if box(lat, lon, 36, 44, -10, 3):
        return 6
    if box(lat, lon, 36, 42, 26, 36) or box(lat, lon, 29, 37, 30, 40):
        return 6
    if lat > 58:
        return 3
    if lon > 30 and lat > 46:
        return 4
    if lat < 33 and lon < 30:
        return 4
    return 5


provinces = []
cap_ids = {}
for i in range(N):
    sea = i >= L
    p = {"id": i, "name": names[i], "color": list(colors[i]), "sea": sea,
         "owner": "" if (sea or owner[i] < 0) else nations[owner[i]]["tag"],
         "terrain": "mar" if sea else terrain_for(float(clat[i]), float(clon[i])),
         "development": 0, "center": [round(float(cx[i]), 1), round(float(cy[i]), 1)],
         "neighbors": sorted(neigh[i])}
    if not sea:
        base = dev_for(float(clat[i]), float(clon[i]))
        is_anchor = lseeds[i]["anchor"] is not None
        d = base + (random.randint(1, 4) if is_anchor else random.randint(-1, 2))
        if is_anchor and anchors[lseeds[i]["anchor"]]["capital"]:
            d += 4
            cap_ids[owner[i]] = i
        p["development"] = max(1, min(20, d))
    provinces.append(p)

countries = []
for ni, n in enumerate(nations):
    if ni not in cap_ids:
        continue
    countries.append({"tag": n["tag"], "name": n["name"], "color": n["color"], "capital": cap_ids[ni]})

with open("data/map.json", "w", encoding="utf-8") as f:
    json.dump({"width": W, "height": H, "countries": countries, "provinces": provinces},
              f, ensure_ascii=False, separators=(",", ":"))

owned = defaultdict(int)
for p in provinces:
    if p["owner"]:
        owned[p["owner"]] += 1
unowned = sum(1 for p in provinces if not p["sea"] and not p["owner"])
print(f"\nOK: {N} provincias ({L} terra, {S} mar), {len(countries)} paises, mapa {W}x{H}")
top = sorted(owned.items(), key=lambda t: -t[1])[:8]
print("maiores:", ", ".join(f"{t}={n}" for t, n in top))
print("terra sem dono:", unowned, "| area minima (px):", int(cnt[:L].min()), "| media:", int(cnt[:L].mean()))
small = [(names[i], int(cnt[i])) for i in range(L) if cnt[i] < 60]
print("provincias com < 60 px:", len(small), small[:10])
