#!/usr/bin/env python3
"""Redesenha as províncias de terra da Europa (e Anatólia/Cáucaso) com dados livres.

Uso (a partir da pasta do projeto):
  python3 tools/rebuild_europe.py [--previa previa.png]
  python3 tools/refine_world.py --terreno        # depois: donos, nomes, culturas e terreno

- Sementes: cidades reais do Natural Earth (maiores primeiro), com um espaçamento mínimo que
  cresce para o leste e o norte (como a densidade de províncias de um mapa de 1444); áreas
  vazias recebem sementes extras.
- Formas: watershed compacta sobre uma imagem de "barreiras": relevo (ETOPO5, as divisas caem
  nas cristas), rios principais e fronteiras de países/regiões administrativas (Natural Earth).
- O resto do mundo e as zonas marítimas não mudam de forma; os ids de TODAS as províncias são
  renumerados (terra 0..nl-1, mar depois). Rode tools/refine_world.py --terreno em seguida.
Dados baixados para tools/data/raw/ (fora do git). Requer: pillow numpy scipy scikit-image
"""
import colorsys, json, math, os, sys, urllib.request
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from skimage.segmentation import watershed

Image.MAX_IMAGE_PIXELS = None
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "tools/data")
RAW = os.path.join(DATA, "raw")
MAP_JSON = os.path.join(ROOT, "data/world/map.json")
IDS_PNG = os.path.join(ROOT, "assets/world/province_ids.png")
GEO = json.load(open(os.path.join(DATA, "world_georef.json")))
LON0, SX, Y0, B = GEO["lon0"], GEO["sx"], GEO["y0"], GEO["b"]
NE_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/%s.geojson"
ETOPO_URL = "https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO5/TOPO/ETOPO5/ETOPO5.DOS"

# Países (ISO A3 do Natural Earth) cujo território entra na reconstrução.
EUROPE = set("""ISL NOR SWE FIN DNK GBR IRL NLD BEL LUX FRA ESP PRT AND MCO DEU CHE AUT LIE ITA SMR
VAT MLT SVN HRV BIH SRB KOS MNE MKD ALB GRC BGR ROU MDA UKR BLR LTU LVA EST POL CZE SVK HUN RUS
TUR CYP CYN GEO ARM AZE FRO ALA IMN GGY JEY GIB""".split())
RUS_MAX_LON = 60.0          # Rússia só até os Urais
BBOX = (-25.0, 62.0, 34.0, 72.5)   # lon_min, lon_max, lat_min, lat_max da janela de trabalho

BASE_KM = int(os.environ.get("BASE_KM", "72"))               # espaçamento entre sementes no oeste/centro da Europa
ADMIN_MIN_KM2 = 2500        # fronteiras admin-1 só contam entre unidades maiores que isto
W_ELEV, W_RIVER, W_ADMIN, W_COUNTRY = 1.0, 0.55, 0.35, 0.6
COMPACTNESS = float(os.environ.get("COMPACTNESS", "0.0006"))
W_NOISE = float(os.environ.get("W_NOISE", "0.8"))             # micro-relevo artificial: divisas sinuosas nas planícies
MIN_FRAC = 0.22             # províncias menores que isto x área nominal são fundidas


def spacing_km(lat, lon):
    s = BASE_KM
    if 2 < lon < 17 and 44 < lat < 55:
        s *= 0.78               # Sacro Império, Países Baixos e norte da Itália: muitos estados pequenos
    if lon > 27:
        s *= 1.3
    if lon > 40:
        s *= 1.35
    if lat > 59:
        s *= 1.5
    if lat > 64:
        s *= 1.5
    return s


def ll_to_px(lat, lon):
    lat = np.radians(np.asarray(lat, float))
    x = ((np.asarray(lon, float) - LON0) % 360.0) * SX
    return x, Y0 - B * 1.25 * np.log(np.tan(np.pi / 4 + 0.8 * lat / 2))


def px_to_ll(x, y):
    m = (Y0 - np.asarray(y, float)) / (1.25 * B)
    phi = 2 * np.arctan(np.exp(m)) - np.pi / 2
    lon = LON0 + np.asarray(x, float) / SX
    return np.degrees(phi / 0.8), (lon + 180.0) % 360.0 - 180.0


def km_per_px(lat):
    """Tamanho aproximado de 1 px (km) na latitude dada (projeção Miller do mapa)."""
    return 111.32 * np.cos(np.radians(lat)) / SX


def download(name, url):
    path = os.path.join(RAW, name)
    if not os.path.exists(path):
        os.makedirs(RAW, exist_ok=True)
        print("baixando", url)
        urllib.request.urlretrieve(url, path + ".part")
        os.replace(path + ".part", path)
    return path


def ne(name):
    return json.load(open(download(name + ".geojson", NE_URL % name), encoding="utf-8"))["features"]


prev_out = sys.argv[sys.argv.index("--previa") + 1] if "--previa" in sys.argv else None

# ------------------------------------------------------------------ mapa atual
data = json.load(open(MAP_JSON, encoding="utf-8"))
P = data["provinces"]
N = len(P)
H, W = data["height"], data["width"]
sea = np.array([p["sea"] for p in P])
nl = int((~sea).sum())
im = np.asarray(Image.open(IDS_PNG).convert("RGB"))
lab = im[..., 0].astype(np.int32) | (im[..., 1].astype(np.int32) << 8)
del im

# janela de trabalho
X0, Y1 = [int(v) for v in ll_to_px(BBOX[2], BBOX[0])]
X1, Y0w = [int(v) for v in ll_to_px(BBOX[3], BBOX[1])]
X0, X1 = max(X0, 0), min(X1 + 1, W)
YA, YB = max(Y0w, 0), min(Y1 + 1, H)
win = lab[YA:YB, X0:X1]
h, w = win.shape
print("janela", (X0, YA, X1, YB), w, "x", h)
glat = px_to_ll(0, np.arange(YA, YB) + 0.5)[0][:, None] * np.ones((1, w))
glon = px_to_ll(np.arange(X0, X1) + 0.5, 0)[1][None, :] * np.ones((h, 1))
land_w = win < nl


def to_win(ring):
    x, y = ll_to_px(ring[:, 1], ring[:, 0])
    return list(zip((x - X0).tolist(), (y - YA).tolist()))


def polys_of(geom):
    if geom is None:
        return []
    return geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]


# ------------------------------------------------------------------ regiões administrativas
print("admin-1...")
adm = ne("ne_10m_admin_1_states_provinces")
adm_img = Image.new("I", (w, h), 0)
drw = ImageDraw.Draw(adm_img)
adm_info = [None]
for f in adm:
    pr = f["properties"]
    a3 = pr["adm0_a3"]
    if a3 not in EUROPE:
        continue
    k = len(adm_info)
    adm_info.append((a3, float(pr.get("area_sqkm") or 0)))
    for poly in polys_of(f["geometry"]):
        ring = np.array(poly[0], float)
        if len(ring) < 3 or ring[:, 0].max() < BBOX[0] or ring[:, 0].min() > BBOX[1]:
            continue
        drw.polygon(to_win(ring), fill=k)
        for hole in poly[1:]:
            hole = np.array(hole, float)
            if len(hole) >= 3:
                drw.polygon(to_win(hole), fill=0)
adm_id = np.array(adm_img, np.int32)
# a costa do mapa não bate 100% com a do Natural Earth: terra sem região herda a mais próxima
miss = adm_id == 0
idx = ndimage.distance_transform_edt(miss, return_distances=False, return_indices=True)
adm_near = adm_id[idx[0], idx[1]]
near_d = ndimage.distance_transform_edt(miss)
adm_id = np.where(land_w & miss & (near_d < 25), adm_near, adm_id)
country = np.array([""] + [a[0] for a in adm_info[1:]])[adm_id]
area_km2 = np.array([0.0] + [a[1] for a in adm_info[1:]])[adm_id]
region = land_w & (adm_id > 0) & ~((country == "RUS") & (glon > RUS_MAX_LON))

# a reconstrução troca províncias inteiras: entra toda província antiga com maioria na região
cnt_all = np.bincount(win[land_w], minlength=N)
cnt_reg = np.bincount(win[region], minlength=N)
full = np.bincount(lab[lab < nl], minlength=N)
take = np.zeros(N, bool)
take[:nl] = (cnt_reg[:nl] * 2 > full[:nl]) & (cnt_all[:nl] == full[:nl])
region = take[win]
print("províncias antigas substituídas:", int(take.sum()))

# ------------------------------------------------------------------ barreiras
print("barreiras...")
etopo = np.fromfile(download("ETOPO5.DOS", ETOPO_URL), "<i2").reshape(2160, 4320).astype(np.float32)
etopo = np.roll(etopo, 2160, axis=1)
r = np.clip(((90.0 - glat) * 12).astype(int), 0, 2159)
c = (((glon + 180.0) % 360.0) * 12).astype(int) % 4320
fr = (90.0 - glat) * 12 - r
fc = ((glon + 180.0) % 360.0) * 12 - c
r2, c2 = np.minimum(r + 1, 2159), (c + 1) % 4320
elev = (etopo[r, c] * (1 - fr) * (1 - fc) + etopo[r2, c] * fr * (1 - fc)
        + etopo[r, c2] * (1 - fr) * fc + etopo[r2, c2] * fr * fc)
elev = ndimage.gaussian_filter(np.maximum(elev, 0), 1.5)
elev_n = np.sqrt(elev / 3000.0)                     # realça colinas sem saturar nos Alpes

riv = Image.new("L", (w, h), 0)
drw = ImageDraw.Draw(riv)
for name, maxrank, width in (("ne_10m_rivers_lake_centerlines", 7, 2), ("ne_10m_rivers_europe", 9, 1)):
    for f in ne(name):
        pr = f["properties"]
        if pr.get("featurecla") not in ("River", "Lake Centerline") or (pr.get("scalerank") or 99) > maxrank:
            continue
        g = f["geometry"]
        if g is None:
            continue
        lines = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
        for ln in lines:
            ln = np.array(ln, float)
            if len(ln) < 2 or ln[:, 0].max() < BBOX[0] or ln[:, 0].min() > BBOX[1]:
                continue
            strength = 255 if (pr.get("scalerank") or 9) <= 4 else 170
            drw.line(to_win(ln[:, :2]), fill=strength, width=width)
river = ndimage.gaussian_filter(np.asarray(riv, np.float32) / 255.0, 1.0)

edge_c = np.zeros((h, w), bool)
edge_a = np.zeros((h, w), bool)
for dy, dx in ((0, 1), (1, 0)):
    a, b = adm_id[:h - dy, :w - dx], adm_id[dy:, dx:]
    diff = (a != b) & (a > 0) & (b > 0)
    ca, cb = country[:h - dy, :w - dx], country[dy:, dx:]
    big = (area_km2[:h - dy, :w - dx] >= ADMIN_MIN_KM2) & (area_km2[dy:, dx:] >= ADMIN_MIN_KM2)
    edge_c[:h - dy, :w - dx] |= diff & (ca != cb)
    edge_a[:h - dy, :w - dx] |= diff & (ca == cb) & big
admin = np.maximum(W_COUNTRY * ndimage.gaussian_filter(edge_c.astype(np.float32), 1.2) * 2.5,
                   W_ADMIN * ndimage.gaussian_filter(edge_a.astype(np.float32), 1.2) * 2.5)
# ruído fractal fixo (semente constante): várias escalas, normalizado para 0..1
rng = np.random.default_rng(1444)
noise = np.zeros((h, w), np.float32)
for sigma, amp in ((24, 1.0), (10, 0.6), (4, 0.35)):
    nz = ndimage.gaussian_filter(rng.standard_normal((h, w)).astype(np.float32), sigma)
    noise += amp * (nz - nz.mean()) / (nz.std() + 1e-9)
noise = (noise - noise.min()) / (noise.max() - noise.min())
barrier = W_ELEV * elev_n + W_RIVER * river + np.minimum(admin, 1.0) + W_NOISE * noise
barrier = ndimage.gaussian_filter(barrier, 1.0)    # sem platôs (evita divisas em "escada")

# ------------------------------------------------------------------ sementes
print("sementes...")
places = []
for f in json.load(open(os.path.join(DATA, "ne_10m_populated_places_simple.geojson"), encoding="utf-8"))["features"]:
    pr = f["properties"]
    places.append((float(pr["pop_max"] or 0), float(pr["latitude"]), float(pr["longitude"]), pr["name"]))
places.sort(reverse=True)
seeds = []          # (y, x) na janela
seed_km = []


def free(y, x, la, lo):
    if not seeds:
        return True
    s = spacing_km(la, lo)
    sy, sx = np.array(seeds).T
    d = np.hypot(sy - y, sx - x) * km_per_px(la)
    return bool((d >= 0.5 * (s + np.array(seed_km))).all())


for pop, la, lo, nm in places:
    x, y = ll_to_px(la, lo)
    xi, yi = int(x) - X0, int(y) - YA
    if not (0 <= xi < w and 0 <= yi < h):
        continue
    if not region[yi, xi]:      # cidade de litoral no mar: procura terra perto
        y0, x0 = max(yi - 8, 0), max(xi - 8, 0)
        yy, xx = np.nonzero(region[y0:yi + 9, x0:xi + 9])
        if not len(yy):
            continue
        k = np.argmin((yy + y0 - yi) ** 2 + (xx + x0 - xi) ** 2)
        yi, xi = int(yy[k] + y0), int(xx[k] + x0)
    if free(yi, xi, la, lo):
        seeds.append((yi, xi))
        seed_km.append(spacing_km(la, lo))
n_city = len(seeds)
# preenche áreas sem cidade com uma grade
step = 6
for yi in range(0, h, step):
    for xi in range(0, w, step):
        if region[yi, xi] and free(yi, xi, glat[yi, xi], glon[yi, xi]):
            seeds.append((yi, xi))
            seed_km.append(spacing_km(glat[yi, xi], glon[yi, xi]))
print("  sementes: %d cidades + %d de preenchimento" % (n_city, len(seeds) - n_city))

markers = np.zeros((h, w), np.int32)
for k, (yi, xi) in enumerate(seeds):
    markers[yi, xi] = k + 1
# ilhas sem semente ganham uma no centro
comp, ncomp = ndimage.label(region, structure=np.ones((3, 3)))
has = np.zeros(ncomp + 1, bool)
has[np.unique(comp[markers > 0])] = True
for ci, sl in enumerate(ndimage.find_objects(comp), start=1):
    if has[ci] or sl is None:
        continue
    yy, xx = np.nonzero(comp[sl] == ci)
    if len(yy) < 40:
        continue
    k = np.argmin((yy - yy.mean()) ** 2 + (xx - xx.mean()) ** 2)
    seeds.append((int(yy[k] + sl[0].start), int(xx[k] + sl[1].start)))
    markers[seeds[-1]] = len(seeds)

# ------------------------------------------------------------------ watershed
print("watershed...")
# cada semente vira o fundo de uma bacia: cidades à beira de rios (barreira alta) não ficam
# sufocadas pelas vizinhas
dots = np.zeros((h, w), np.float32)
dots[markers > 0] = 1.0
basin = ndimage.gaussian_filter(dots, 2.0)
barrier = barrier - 0.8 * np.minimum(basin / basin.max(), 1.0)
seg = watershed(barrier, markers, connectivity=2, mask=region, compactness=COMPACTNESS)
# pedaços de terra sem semente (ilhotas) vão para a província mais próxima
rest = region & (seg == 0)
if rest.any():
    idx = ndimage.distance_transform_edt(seg == 0, return_distances=False, return_indices=True)
    seg[rest] = seg[idx[0][rest], idx[1][rest]]

# remove tiras finas e suaviza as divisas: cada pixel vai para o "miolo" (área onde toda a
# vizinhança 5x5 é da mesma província) mais próximo
fill = np.where(region, seg, -1)
interior = region & (ndimage.maximum_filter(fill, 5) == ndimage.minimum_filter(fill, 5))
if interior.any():
    idx = ndimage.distance_transform_edt(~interior, return_distances=False, return_indices=True)
    near = seg[idx[0], idx[1]]
    seg = np.where(region, near, 0)


def relabel(seg):
    u, inv = np.unique(seg, return_inverse=True)
    return inv.reshape(seg.shape).astype(np.int32), len(u) - 1   # 0 = fora da região


def adjacency(seg):
    pairs = {}
    for a, b in ((seg[:, :-1], seg[:, 1:]), (seg[:-1], seg[1:])):
        m = (a != b) & (a > 0) & (b > 0)
        lo, hi = np.minimum(a[m], b[m]), np.maximum(a[m], b[m])
        u, cnt = np.unique(lo.astype(np.int64) * 1_000_000 + hi, return_counts=True)
        for key, cc in zip(u, cnt):
            pairs[int(key)] = pairs.get(int(key), 0) + int(cc)
    return pairs


# funde províncias pequenas na vizinha com maior fronteira (repete até estabilizar)
for it in range(8):
    seg, n = relabel(seg)
    area = np.bincount(seg.ravel(), minlength=n + 1)
    lat_c = ndimage.mean(glat, seg, index=np.arange(n + 1))
    lon_c = ndimage.mean(glon, seg, index=np.arange(n + 1))
    nominal = np.array([math.pi * (spacing_km(lat_c[i], lon_c[i]) / 2) ** 2 / km_per_px(lat_c[i]) ** 2
                        if i else 0 for i in range(n + 1)])
    small = [i for i in range(1, n + 1) if area[i] < MIN_FRAC * nominal[i]]
    if not small:
        break
    best = {}
    for key, cc in adjacency(seg).items():
        a, b = divmod(key, 1_000_000)
        for s_, o in ((a, b), (b, a)):
            if cc > best.get(s_, (0, 0))[0]:
                best[s_] = (cc, o)
    remap = np.arange(n + 1)
    merged = 0
    for i in sorted(small, key=lambda i: area[i]):
        if i in best and remap[best[i][1]] != i:
            remap[i] = remap[best[i][1]]
            merged += 1
    if not merged:
        break
    for _ in range(4):
        remap = remap[remap]
    seg = remap[seg]
    print("  fusão %d: %d províncias pequenas" % (it + 1, merged))
seg, n_new = relabel(seg)
# uma província nunca atravessa o mar: cada pedaço de terra separado vira província própria;
# pedaços muito pequenos (ilhotas) vão para a província vizinha por terra, se houver
nxt = n_new + 1
islets = 0
for i, sl in enumerate(ndimage.find_objects(seg), start=1):
    if sl is None:
        continue
    comp, nc = ndimage.label(seg[sl] == i, structure=np.ones((3, 3)))
    if nc < 2:
        continue
    sizes = np.bincount(comp.ravel())[1:]
    for k in range(1, nc + 1):
        if k == np.argmax(sizes) + 1:
            continue
        seg[sl][comp == k] = nxt
        nxt += 1
        islets += 1
seg, n_new = relabel(seg)
area = np.bincount(seg.ravel(), minlength=n_new + 1)
best = {}
for key, cc in adjacency(seg).items():
    a_, b_ = divmod(key, 1_000_000)
    for s_, o in ((a_, b_), (b_, a_)):
        if area[s_] < 25 and cc > best.get(s_, (0, 0))[0]:
            best[s_] = (cc, o)
remap = np.arange(n_new + 1)
for i_, (cc, o) in best.items():
    if area[o] >= 25:
        remap[i_] = o
seg, n_new = relabel(remap[seg])
print("  pedaços separados pelo mar viraram províncias próprias:", islets)
print("províncias novas na Europa:", n_new)

# ------------------------------------------------------------------ monta o mapa novo
keep_land = [i for i in range(nl) if not take[i]]
new_nl = len(keep_land) + n_new
old2new = np.full(N, -1, np.int64)
old2new[keep_land] = np.arange(len(keep_land))
sea_ids = list(range(nl, N))
old2new[sea_ids] = new_nl + np.arange(len(sea_ids))
NN = new_nl + len(sea_ids)
lab2 = old2new[lab]
sub = lab2[YA:YB, X0:X1]
sub[seg > 0] = len(keep_land) + seg[seg > 0] - 1
lab2[YA:YB, X0:X1] = sub
assert lab2.min() >= 0 and lab2.max() < NN and NN < 65536
lab2 = lab2.astype(np.int32)
print("total: %d províncias (%d terra, %d mar)" % (NN, new_nl, len(sea_ids)))

# centros e vizinhanças (mesmo método de gen_world.py)
cnt = np.zeros(NN)
sxs = np.zeros(NN)
sys_ = np.zeros(NN)
xs_row = np.arange(W, dtype=np.float64)
nb = set()
CH = 200
for r0 in range(0, H, CH):
    blk = lab2[r0:r0 + CH + 1]
    core = lab2[r0:r0 + CH]
    flat = core.ravel()
    cnt += np.bincount(flat, minlength=NN)
    sxs += np.bincount(flat, weights=np.tile(xs_row, core.shape[0]), minlength=NN)
    sys_ += np.bincount(flat, weights=np.repeat(np.arange(r0, r0 + core.shape[0], dtype=np.float64), W), minlength=NN)
    for a, b in ((core[:, :-1], core[:, 1:]), (blk[:-1], blk[1:])):
        mk = a != b
        lo = np.minimum(a[mk], b[mk]).astype(np.int64)
        hi = np.maximum(a[mk], b[mk]).astype(np.int64)
        nb.update(np.unique(lo * NN + hi).tolist())
neigh = [[] for _ in range(NN)]
for key in nb:
    a, b = divmod(key, NN)
    neigh[a].append(b)
    neigh[b].append(a)
cx, cy = sxs / np.maximum(cnt, 1), sys_ / np.maximum(cnt, 1)
objs = ndimage.find_objects(lab2 + 1)
centers = []
for i in range(NN):
    x, y = min(max(int(round(cx[i])), 0), W - 1), min(max(int(round(cy[i])), 0), H - 1)
    if lab2[y, x] != i:
        sl = objs[i]
        yy, xx = np.nonzero(lab2[sl] == i)
        k = np.argmin((yy + sl[0].start - cy[i]) ** 2 + (xx + sl[1].start - cx[i]) ** 2)
        x, y = int(xx[k] + sl[1].start), int(yy[k] + sl[0].start)
    centers.append((float(x), float(y)))

# desenvolvimento-base das novas: maior cidade dentro da província (como gen_world.py)
pop_of = np.zeros(NN)
for pop, la, lo, nm in places:
    x, y = ll_to_px(la, lo)
    xi, yi = int(x), int(y)
    if 0 <= xi < W and 0 <= yi < H:
        q = lab2[yi, xi]
        if len(keep_land) <= q < new_nl and pop > pop_of[q]:
            pop_of[q] = pop

provinces = []
for i in range(NN):
    if i < len(keep_land):
        p = dict(P[keep_land[i]])
    elif i < new_nl:
        hh = (i * 0.61803398875) % 1.0
        col = [int(v * 255) for v in colorsys.hsv_to_rgb(hh, 0.5 + 0.4 * ((i * 7) % 5) / 4, 0.55 + 0.4 * ((i * 3) % 4) / 3)]
        dev = int(min(30, 2 + max(0, 3 * (math.log10(max(pop_of[i], 1)) - 4)))) if pop_of[i] > 0 else 2
        p = {"name": "Província %d" % i, "color": col, "sea": False, "owner": "", "terrain": "planície",
             "development": dev, "base_development": dev}
    else:
        p = dict(P[sea_ids[i - new_nl]])
    p["id"] = i
    p["center"] = [round(centers[i][0], 1), round(centers[i][1], 1)]
    p["neighbors"] = sorted(neigh[i])
    provinces.append(p)
for c in data["countries"]:
    c["capital"] = int(old2new[c["capital"]]) if old2new[c["capital"]] >= 0 else 0
data["provinces"] = provinces
with open(MAP_JSON, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
# a tabela de donos (tools/data/donos_1444.csv) migra para os ids novos: cada província nova
# fica com o dono da província antiga com que mais se sobrepõe
OWNERS_CSV = os.path.join(DATA, "donos_1444.csv")
if os.path.exists(OWNERS_CSV):
    old_owner = [p.get("owner", "") if not p["sea"] else "" for p in P]
    for line in open(OWNERS_CSV, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            f = (line.split(";") + ["", ""])[:3]
            if int(f[0]) < nl and (not f[2] or P[int(f[0])]["name"] == f[2]):
                old_owner[int(f[0])] = f[1]
    land2 = lab2 < new_nl
    pairs = lab2[land2].astype(np.int64) * N + lab[land2]
    u, cnt_ = np.unique(pairs, return_counts=True)
    best_old = {}
    for key, cc in zip(u, cnt_):
        nw, od = divmod(int(key), N)
        if cc > best_old.get(nw, (0, -1))[0]:
            best_old[nw] = (cc, od)
    with open(OWNERS_CSV, "w", encoding="utf-8") as f:
        f.write("# migrada por rebuild_europe.py; refine_world.py reescreve com os nomes\n")
        for nw in range(new_nl):
            od = best_old.get(nw, (0, -1))[1]
            f.write("%d;%s;\n" % (nw, old_owner[od] if od >= 0 and od < nl else ""))
    print("tabela de donos migrada para os ids novos")
rgb = np.zeros((H, W, 3), np.uint8)
rgb[..., 0] = lab2 & 255
rgb[..., 1] = (lab2 >> 8) & 255
Image.fromarray(rgb).save(IDS_PNG, optimize=False, compress_level=6)
print("salvo. Agora rode: python3 tools/refine_world.py --terreno")

if prev_out:
    sub = lab2[YA:YB, X0:X1]
    sea2 = np.array([p["sea"] for p in provinces])
    img = np.where(sea2[sub][..., None], [95, 143, 179], [205, 195, 165]).astype(np.uint8)
    e = np.zeros(sub.shape, bool)
    e[:, 1:] |= sub[:, 1:] != sub[:, :-1]
    e[1:] |= sub[1:] != sub[:-1]
    img[e & ~sea2[sub]] = (60, 60, 60)
    Image.fromarray(img).save(prev_out)
    print("prévia:", prev_out)
