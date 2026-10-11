#!/usr/bin/env python3
"""Gera o mapa de exemplo (~1000 provincias).

Saidas (a partir da pasta do projeto):
  assets/provinces.png     cor unica por provincia (para humanos / editar)
  assets/province_ids.png  id da provincia em R (baixo) e G (alto) -> usado pelo Godot
  data/map.json            provincias, paises, vizinhos

Uso: python3 tools/gen_map.py [passo_terra]   (padrao 36; menor = mais provincias)
Requer: Pillow, numpy, scipy
"""
import colorsys
import json
import random
import sys
from collections import deque

import numpy as np
from PIL import Image
from scipy.spatial import cKDTree

W, H = 2048, 1024
SEED = 1444
LAND_STEP = float(sys.argv[1]) if len(sys.argv) > 1 else 36.0
SEA_STEP = 120.0
N_COUNTRIES = 24

random.seed(SEED)
np.random.seed(SEED)

# ------------------------------------------------------------ terra / mar (ruido)
def fbm(w, h):
    total = np.zeros((h, w), np.float32)
    amp = 1.0
    for gw, gh in [(5, 3), (10, 5), (20, 10), (40, 20), (80, 40)]:
        g = np.random.rand(gh, gw).astype(np.float32)
        im = Image.fromarray(g).resize((w, h), Image.BICUBIC)
        total += amp * np.asarray(im, dtype=np.float32)
        amp *= 0.5
    return (total - total.min()) / (total.max() - total.min())


noise = fbm(W, H)
yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
edge = np.minimum.reduce([xx, W - xx, yy, H - yy]) / (0.12 * H)
edge = np.clip(edge, 0, 1)
edge = edge * edge * (3 - 2 * edge)
land_field = noise * (0.25 + 0.75 * edge)
THR = float(np.quantile(land_field, 0.46))


def is_land(x, y):
    xi = min(max(int(x), 0), W - 1)
    yi = min(max(int(y), 0), H - 1)
    return land_field[yi, xi] >= THR


# ------------------------------------------------------------ sementes
land_seeds = []
y = LAND_STEP / 2
while y < H:
    x = LAND_STEP / 2
    while x < W:
        px = x + random.uniform(-0.38, 0.38) * LAND_STEP
        py = y + random.uniform(-0.38, 0.38) * LAND_STEP
        if is_land(px, py):
            land_seeds.append((px, py))
        x += LAND_STEP
    y += LAND_STEP

sea_seeds = []
y = SEA_STEP / 2
while y < H:
    x = SEA_STEP / 2
    while x < W:
        px = x + random.uniform(-0.3, 0.3) * SEA_STEP
        py = y + random.uniform(-0.3, 0.3) * SEA_STEP
        if not is_land(px, py):
            sea_seeds.append((px, py))
        x += SEA_STEP
    y += SEA_STEP

# remove mar colado em terra (celulas minusculas)
ls = cKDTree(np.array(land_seeds))
sea_seeds = [s for s in sea_seeds if ls.query(s)[0] > LAND_STEP * 0.8]

seeds = land_seeds + sea_seeds
n_land = len(land_seeds)
N = len(seeds)

# ------------------------------------------------------------ voronoi com ruido
xw = xx + 8 * np.sin(yy / 41.0 + 1.3) + 6 * np.sin(yy / 13.0 + xx / 57.0) + 3 * np.sin(xx / 7.0)
yw = yy + 8 * np.sin(xx / 47.0 + 0.4) + 6 * np.sin(xx / 15.0 + yy / 53.0) + 3 * np.sin(yy / 9.0)
tree = cKDTree(np.array(seeds))
_, ids = tree.query(np.stack([xw.ravel(), yw.ravel()], axis=1), workers=-1)
ids = ids.reshape(H, W).astype(np.int32)

# ------------------------------------------------------------ cores unicas e imagens
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
    lo = np.minimum(a[m], b[m]).astype(np.int64)
    hi = np.maximum(a[m], b[m]).astype(np.int64)
    pairs.update(np.unique(lo * N + hi).tolist())
neigh = [set() for _ in range(N)]
for k in pairs:
    p, q = divmod(k, N)
    neigh[p].add(q)
    neigh[q].add(p)

flat = ids.ravel()
cnt = np.bincount(flat, minlength=N).astype(np.float64)
cx = np.bincount(flat, weights=xx.ravel(), minlength=N) / np.maximum(cnt, 1)
cy = np.bincount(flat, weights=yy.ravel(), minlength=N) / np.maximum(cnt, 1)

# ------------------------------------------------------------ nomes
SYL_A = ["Val", "Kar", "Mer", "Tor", "Sal", "Bra", "Nor", "Isk", "Dra", "Vel", "Gal", "Bar", "Lun",
         "Cor", "Mor", "Fen", "Ald", "Rav", "Hel", "Ost", "Tar", "Zan", "Pel", "Quin", "Sev", "Ber",
         "Kol", "Lor", "Mir", "Nav", "Ort", "Pra", "Rad", "Sil", "Tev", "Ulm", "Vor", "Yar", "Zel", "Cas"]
SYL_M = ["", "", "", "an", "or", "el", "ar", "in", "ov", "un"]
SYL_B = ["dor", "via", "nia", "gard", "mar", "burg", "ton", "land", "ora", "esa", "ina", "ovo", "ak",
         "um", "ia", "heim", "polis", "ria"]
names = set()


def make_name():
    while True:
        n = random.choice(SYL_A) + random.choice(SYL_M) + random.choice(SYL_B)
        if n not in names:
            names.add(n)
            return n


# ------------------------------------------------------------ paises
# componentes de terra
comp = [-1] * N
comps = []
for s in range(n_land):
    if comp[s] != -1:
        continue
    q = deque([s])
    comp[s] = len(comps)
    members = []
    while q:
        u = q.popleft()
        members.append(u)
        for v in neigh[u]:
            if v < n_land and comp[v] == -1:
                comp[v] = comp[s]
                q.append(v)
    comps.append(members)
big = {i for i, m in enumerate(comps) if len(m) >= 40}
cands = [i for i in range(n_land) if comp[i] in big]

cap = [random.choice(cands)]
while len(cap) < N_COUNTRIES:
    best_i, best_d = None, -1
    for i in cands:
        if i in cap:
            continue
        d = min((cx[i] - cx[c]) ** 2 + (cy[i] - cy[c]) ** 2 for c in cap)
        if d > best_d:
            best_i, best_d = i, d
    cap.append(best_i)

TITLES = ["Reino de", "Império", "Ducado de", "República de", "Sultanato de", "Grão-Ducado de",
          "Khanato de", "Principado de", "Condado de", "Califado de"]
countries = []
tags = set()
for k, c in enumerate(cap):
    root = make_name()
    tag = root[:3].upper()
    while tag in tags:
        tag = chr(65 + random.randrange(26)) + tag[1:]
    tags.add(tag)
    h = (k * 0.61803398875) % 1.0
    r, g, b = colorsys.hsv_to_rgb(h, 0.55 + 0.15 * (k % 3) / 2, 0.78 + 0.1 * (k % 2))
    countries.append({"tag": tag, "name": f"{random.choice(TITLES)} {root}",
                      "color": [int(r * 255), int(g * 255), int(b * 255)], "capital": c})

owner = [""] * N
frontier = {}
for ct in countries:
    owner[ct["capital"]] = ct["tag"]
    frontier[ct["tag"]] = [ct["capital"]]
active = set(frontier)
while active:
    for ct in countries:
        tag = ct["tag"]
        if tag not in active:
            continue
        fr = frontier[tag]
        grown = False
        while fr and not grown:
            j = random.randrange(len(fr))
            u = fr[j]
            free = [v for v in neigh[u] if v < n_land and owner[v] == ""]
            if not free:
                fr[j] = fr[-1]
                fr.pop()
                continue
            v = random.choice(free)
            owner[v] = tag
            fr.append(v)
            grown = True
        if not grown:
            active.discard(tag)

# ------------------------------------------------------------ provincias
TERRAINS = ["planície", "floresta", "colina", "montanha", "deserto", "pântano"]
SEA_PREFIX = ["Mar de", "Golfo de", "Estreito de", "Oceano de"]
provinces = []
for i in range(N):
    sea = i >= n_land
    nm = make_name()
    provinces.append({
        "id": i,
        "name": f"{random.choice(SEA_PREFIX)} {nm}" if sea else nm,
        "color": list(colors[i]),
        "sea": sea,
        "owner": owner[i],
        "terrain": "mar" if sea else random.choice(TERRAINS),
        "development": 0 if sea else random.randint(3, 12),
        "center": [round(float(cx[i]), 1), round(float(cy[i]), 1)],
        "neighbors": sorted(neigh[i]),
    })

with open("data/map.json", "w", encoding="utf-8") as f:
    json.dump({"width": W, "height": H, "countries": countries, "provinces": provinces},
              f, ensure_ascii=False, separators=(",", ":"))

print(f"{N} provincias: {n_land} de terra, {N - n_land} de mar, {len(countries)} paises")
sizes = sorted(sum(1 for p in provinces if p["owner"] == c["tag"]) for c in countries)
print("provincias por pais (min/mediana/max):", sizes[0], sizes[len(sizes) // 2], sizes[-1])
print("terra sem dono:", sum(1 for p in provinces if not p["sea"] and p["owner"] == ""))
print("area media (px):", int(cnt[:n_land].mean()), "| minima:", int(cnt[:n_land].min()))
