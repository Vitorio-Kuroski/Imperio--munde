#!/usr/bin/env python3
"""Importa o mapa e os donos de 1444 da SUA instalacao do Europa Universalis IV.

Le (da pasta do jogo; so os dois primeiros grupos sao obrigatorios):
  map/provinces.bmp, map/definition.csv, map/default.map
  history/provinces/*.txt (dono, cultura e religiao em 1444), history/countries/*.txt
  map/climate.txt, map/heightmap.bmp           (terreno; opcionais)
  common/country_tags/*.txt, common/countries/*.txt   (cores dos paises; opcionais)
  common/cultures/*.txt                        (grupos de cultura; opcional)
  common/religions/*.txt                       (religioes, grupos e cores; opcional)
  common/tradegoods/*.txt, common/prices/*.txt (produtos, cores e precos; opcional)
  common/tradenodes/*.txt                      (nos de comercio e para onde o comercio corre; opcional)
  common/buildings/*.txt                       (construcoes: custo, tempo, efeitos; opcional)
  localisation/*_l_english.yml                 (nomes; opcional)
Sem common/countries, as cores vem de tools/data/nations_*.txt (mesma tag) ou sao geradas;
sem localizacao, o nome do pais vem do arquivo history/countries/"TAG - Nome.txt".

Escreve (na pasta do projeto):
  assets/eu4/province_ids.png   id da provincia em R (byte baixo) e G (byte alto)
  data/eu4/map.json             provincias, paises, vizinhos (mesmo formato do mapa de exemplo)

O jogo usa data/eu4/ automaticamente quando a pasta existe. Esses arquivos sao
derivados de dados da Paradox: ficam no .gitignore, nao publique nem distribua.

Uso (a partir da pasta do projeto):
  python3 tools/import_eu4.py                       # tenta achar o EU4 sozinho
  python3 tools/import_eu4.py "/caminho/Europa Universalis IV"
  python3 tools/import_eu4.py CAMINHO --data 1444.11.11
Requer: Pillow, numpy
"""
import argparse
import colorsys
import glob
import hashlib
import json
import os
import re
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

COMMON_PATHS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\Europa Universalis IV",
    r"C:\Program Files\Steam\steamapps\common\Europa Universalis IV",
    r"D:\SteamLibrary\steamapps\common\Europa Universalis IV",
    os.path.expanduser("~/Library/Application Support/Steam/steamapps/common/Europa Universalis IV"),
    os.path.expanduser("~/.steam/steam/steamapps/common/Europa Universalis IV"),
    os.path.expanduser("~/.local/share/Steam/steamapps/common/Europa Universalis IV"),
]

DATE_RE = re.compile(r"^\d+\.\d+\.\d+$")
TOKEN_RE = re.compile(r'#[^\n]*|"[^"]*"|[{}=]|[^\s{}=#"]+')


# ------------------------------------------------------------ parser de script Paradox
def read_text(path):
    with open(path, "rb") as f:
        raw = f.read()
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")


def parse_script(text):
    """Retorna lista de (chave, valor); valor = str ou lista de pares. Itens soltos tem chave None."""
    toks = [t for t in TOKEN_RE.findall(text) if not t.startswith("#")]
    pos = 0

    def block():
        nonlocal pos
        items = []
        while pos < len(toks):
            t = toks[pos]
            pos += 1
            if t == "}":
                return items
            if t in ("{", "="):
                continue
            if pos < len(toks) and toks[pos] == "=":
                pos += 1
                if pos < len(toks) and toks[pos] == "{":
                    pos += 1
                    v = block()
                elif pos < len(toks):
                    v = toks[pos].strip('"')
                    pos += 1
                    if pos < len(toks) and toks[pos] == "{":   # ex.: color = rgb { 1 2 3 }
                        pos += 1
                        v = block()
                else:
                    v = ""
                items.append((t.strip('"'), v))
            else:
                items.append((None, t.strip('"')))
        return items

    return block()


def state_at(items, cutoff):
    """Aplica as chaves de topo e os blocos datados <= cutoff (em ordem cronologica)."""
    st = {}
    dated = []
    for k, v in items:
        if k is None:
            continue
        if DATE_RE.match(k) and isinstance(v, list):
            dated.append((tuple(int(x) for x in k.split(".")), v))
        else:
            st[k] = v
    for d, v in sorted(dated, key=lambda t: t[0]):
        if d <= cutoff:
            for k2, v2 in v:
                if k2 is None:
                    continue
                if k2.startswith("add_base_") and isinstance(v2, str):
                    # add_base_tax = 1 etc.: soma ao valor base (base_tax)
                    try:
                        st[k2[4:]] = str(float(st.get(k2[4:], 0) or 0) + float(v2))
                    except ValueError:
                        pass
                else:
                    st[k2] = v2
    return st


def parse_building(bid, items, names):
    """Construcao de common/buildings: custo, tempo (meses), efeitos (modifier), o que substitui."""
    def num(v):
        try:
            f = float(v)
            return int(f) if f == int(f) else f
        except (TypeError, ValueError):
            return None
    b = {"id": bid, "name": names.get(bid) or bid.replace("_", " ").capitalize()}
    mods = {}
    for k, v in items:
        if k in ("cost", "time") and num(v) is not None:
            b[k] = num(v)
        elif k == "modifier" and isinstance(v, list):
            for mk, mv in v:
                if mk and isinstance(mv, str):
                    mods[mk] = True if mv == "yes" else (num(mv) if num(mv) is not None else mv)
        elif k == "make_obsolete" and isinstance(v, str):
            b["replaces"] = v
        elif k == "manufactory" and isinstance(v, list):
            b["goods"] = [x for kk, x in v if kk is None]
        elif k == "one_per_country" and v == "yes":
            b["one_per_country"] = True
    b["modifiers"] = mods
    return b


def ids_in_block(text, name):
    """Le listas como  sea_starts = { 1 2 3 }  (aceita LIST/RANGE). Retorna set de ints."""
    out = set()
    m = re.search(name + r"\s*=\s*(?:LIST\s*)?\{([^}]*)\}", text, re.S)
    if not m:
        return out
    body = re.sub(r"#[^\n]*", "", m.group(1))
    for r in re.finditer(r"RANGE\s*\{\s*(\d+)\s+(\d+)\s*\}", body):
        out.update(range(int(r.group(1)), int(r.group(2)) + 1))
    body = re.sub(r"RANGE\s*\{[^}]*\}", "", body)
    out.update(int(x) for x in re.findall(r"\d+", body))
    return out


def find_loc(root, pattern):
    files = sorted(glob.glob(os.path.join(root, "localisation", pattern)))
    files += sorted(glob.glob(os.path.join(root, "localisation", "**", pattern), recursive=True))
    return list(dict.fromkeys(files))


def hashed_color(key, sat=(0.45, 0.75), val=(0.55, 0.9)):
    """Cor estável gerada a partir de um texto (para países/culturas sem cor definida)."""
    h = hashlib.md5(key.encode()).digest()
    return [int(c * 255) for c in colorsys.hsv_to_rgb(h[0] / 255,
            sat[0] + (sat[1] - sat[0]) * h[1] / 255, val[0] + (val[1] - val[0]) * h[2] / 255)]


def classify_terrain(pid, hmean, hstd, climates):
    """Terreno a partir do relevo do heightmap e do clima do climate.txt do EU4."""
    if "impassable" in climates.get(pid, ()):
        return "intransitável"
    c = climates.get(pid, ())
    if hmean is not None:
        hm, hs = hmean[pid], hstd[pid]
        if hm > 165 or hs > 16:
            return "montanhas"
        if hm > 125 or hs > 8:
            return "colinas" if "arid" not in c else "deserto"
    if "arid" in c:
        return "deserto"
    if "arctic" in c:
        return "tundra"
    if "tropical" in c:
        return "selva"
    if "severe_winter" in c:
        return "floresta"
    return "planície"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("eu4", nargs="?", help="pasta de instalacao do Europa Universalis IV")
    ap.add_argument("--data", default="1444.11.11", help="data de inicio (padrao 1444.11.11)")
    args = ap.parse_args()

    root = args.eu4
    if not root:
        root = next((p for p in COMMON_PATHS if os.path.isdir(os.path.join(p, "map"))), None)
    if not root or not os.path.isfile(os.path.join(root, "map", "provinces.bmp")):
        sys.exit("Nao achei o EU4. Passe a pasta do jogo (a que contem map/ e history/):\n"
                 "  python3 tools/import_eu4.py \"/caminho/Europa Universalis IV\"")
    cutoff = tuple(int(x) for x in args.data.split("."))
    print("EU4 em:", root)

    # ---------------------------------------------------------- definicoes de provincias
    defs = {}   # id -> (r, g, b, nome)
    for line in read_text(os.path.join(root, "map", "definition.csv")).splitlines():
        p = line.strip().split(";")
        if len(p) < 4 or not p[0].isdigit():
            continue
        pid = int(p[0])
        if pid == 0:
            continue
        defs[pid] = (int(p[1]), int(p[2]), int(p[3]), p[4] if len(p) > 4 else "")
    max_id = max(defs)
    n_prov = max_id + 1        # indice 0 = provincia ficticia (pixels sem cor conhecida)
    print(f"  {len(defs)} provincias (id maximo {max_id})")

    dmap = read_text(os.path.join(root, "map", "default.map"))
    sea_ids = ids_in_block(dmap, "sea_starts") | ids_in_block(dmap, "lakes")
    climates = {}
    clim = os.path.join(root, "map", "climate.txt")
    if os.path.isfile(clim):
        ctext = read_text(clim)
        for key in ("tropical", "arid", "arctic", "mild_winter", "normal_winter", "severe_winter", "impassable"):
            for pid in ids_in_block(ctext, key):
                climates.setdefault(pid, set()).add(key)

    # nomes de provincias (localizacao em ingles)
    prov_names = {}
    for f in find_loc(root, "*prov_names*_l_english.yml"):
        for m in re.finditer(r'^\s*PROV(\d+):\d*\s+"(.*)"\s*$', read_text(f), re.M):
            prov_names.setdefault(int(m.group(1)), m.group(2))

    # ---------------------------------------------------------- bitmap -> imagem de ids
    print("Lendo provinces.bmp...", flush=True)
    bmp = np.array(Image.open(os.path.join(root, "map", "provinces.bmp")).convert("RGB"))
    H, W, _ = bmp.shape
    key = (bmp[..., 0].astype(np.int64) << 16) | (bmp[..., 1].astype(np.int64) << 8) | bmp[..., 2].astype(np.int64)
    del bmp
    ids_list = sorted(defs)
    keys = np.array([(defs[i][0] << 16) | (defs[i][1] << 8) | defs[i][2] for i in ids_list], dtype=np.int64)
    order = np.argsort(keys)
    keys_sorted = keys[order]
    ids_sorted = np.array(ids_list, dtype=np.int32)[order]
    flat = key.ravel()
    pos = np.searchsorted(keys_sorted, flat)
    pos[pos >= len(keys_sorted)] = 0
    hit = keys_sorted[pos] == flat
    ids = np.where(hit, ids_sorted[pos], 0).astype(np.int32).reshape(H, W)
    del key, flat, pos, hit
    miss = int((ids == 0).sum())
    if miss:
        print(f"  aviso: {miss} pixels com cor fora do definition.csv (viram provincia 0)")

    os.makedirs("assets/eu4", exist_ok=True)
    os.makedirs("data/eu4", exist_ok=True)
    idimg = np.zeros((H, W, 3), dtype=np.uint8)
    idimg[..., 0] = ids & 255
    idimg[..., 1] = ids >> 8
    Image.fromarray(idimg, "RGB").save("assets/eu4/province_ids.png", optimize=True)
    del idimg

    # ---------------------------------------------------------- vizinhos e centros
    print("Calculando vizinhos e centros...", flush=True)
    pairs = set()
    for a, b in ((ids[:, :-1], ids[:, 1:]), (ids[:-1, :], ids[1:, :])):
        m = a != b
        lo = np.minimum(a[m], b[m]).astype(np.int64)
        hi = np.maximum(a[m], b[m]).astype(np.int64)
        pairs.update(np.unique(lo * n_prov + hi).tolist())
    neigh = [set() for _ in range(n_prov)]
    for k in pairs:
        p, q = divmod(k, n_prov)
        neigh[p].add(q)
        neigh[q].add(p)
    cnt = np.zeros(n_prov)
    sx = np.zeros(n_prov)
    sy = np.zeros(n_prov)
    xs = np.arange(W, dtype=np.float64)
    for y0 in range(0, H, 128):
        blk = ids[y0:y0 + 128]
        ys = np.arange(y0, y0 + blk.shape[0], dtype=np.float64)[:, None] * np.ones((1, W))
        xx = np.ones((blk.shape[0], 1)) * xs[None, :]
        cnt += np.bincount(blk.ravel(), minlength=n_prov)
        sx += np.bincount(blk.ravel(), weights=xx.ravel(), minlength=n_prov)
        sy += np.bincount(blk.ravel(), weights=ys.ravel(), minlength=n_prov)
    cx = sx / np.maximum(cnt, 1)
    cy = sy / np.maximum(cnt, 1)
    # relevo médio e rugosidade de cada província (map/heightmap.bmp; nível do mar ~ 95)
    h_mean = h_std = None
    hm_path = os.path.join(root, "map", "heightmap.bmp")
    if os.path.isfile(hm_path):
        hm = np.asarray(Image.open(hm_path).convert("L"), dtype=np.float64)
        if hm.shape == ids.shape:
            fl = ids.ravel()
            s1 = np.bincount(fl, weights=hm.ravel(), minlength=n_prov)
            s2 = np.bincount(fl, weights=(hm * hm).ravel(), minlength=n_prov)
            h_mean = s1 / np.maximum(cnt, 1)
            h_std = np.sqrt(np.maximum(s2 / np.maximum(cnt, 1) - h_mean ** 2, 0))
        del hm
    del ids

    # ---------------------------------------------------------- construcoes (common/buildings)
    with open("data/construcoes_pt.json", encoding="utf-8") as f:
        build_pt = json.load(f)["nomes"]
    buildings = []
    for bf in sorted(glob.glob(os.path.join(root, "common", "buildings", "*.txt"))):
        for bname, bval in parse_script(read_text(bf)):
            if isinstance(bval, list):
                buildings.append(parse_building(bname, bval, build_pt))
    bmap = {b["id"]: b for b in buildings}
    for b in buildings:     # manufaturas especiais herdam custo e tempo da "manufactory"
        if "goods" in b and "cost" not in b and "manufactory" in bmap:
            for k in ("cost", "time"):
                if k in bmap["manufactory"]:
                    b[k] = bmap["manufactory"][k]

    # ---------------------------------------------------------- historia das provincias (dono em 1444)
    print("Lendo historia das provincias...", flush=True)
    owner = {}
    dev = {}
    dev_parts = {}      # pid -> (imposto, producao, efetivo)
    goods = {}
    prov_buildings = {}
    cot = {}            # centro de comercio (nivel)
    culture = {}
    religion = {}
    for f in glob.glob(os.path.join(root, "history", "provinces", "*.txt")):
        m = re.match(r"\s*(\d+)", os.path.basename(f))
        if not m:
            continue
        pid = int(m.group(1))
        if pid not in defs:
            continue
        st = state_at(parse_script(read_text(f)), cutoff)
        o = st.get("owner")
        if isinstance(o, str) and o:
            owner[pid] = o
        for k, dst in (("culture", culture), ("religion", religion), ("trade_goods", goods)):
            v = st.get(k)
            if isinstance(v, str) and v:
                dst[pid] = v
        parts = []
        for k in ("base_tax", "base_production", "base_manpower"):
            try:
                parts.append(int(round(float(st.get(k, 0) or 0))))
            except (TypeError, ValueError):
                parts.append(0)
        dev_parts[pid] = tuple(parts)
        have = [b for b in bmap if st.get(b) == "yes"]
        if have:
            prov_buildings[pid] = have
        try:
            if int(float(st.get("center_of_trade", 0) or 0)) > 0:
                cot[pid] = int(float(st["center_of_trade"]))
        except (TypeError, ValueError):
            pass
        dev[pid] = sum(parts)

    # ---------------------------------------------------------- paises
    print("Lendo paises...", flush=True)
    tags = {}
    for f in glob.glob(os.path.join(root, "common", "country_tags", "*.txt")):
        for m in re.finditer(r'^\s*([A-Z0-9]{3})\s*=\s*"([^"]+)"', read_text(f), re.M):
            tags[m.group(1)] = m.group(2)
    names = {}
    for f in find_loc(root, "*countries*_l_english.yml"):
        for m in re.finditer(r'^\s*([A-Z0-9]{3}):\d*\s+"(.*)"\s*$', read_text(f), re.M):
            names.setdefault(m.group(1), m.group(2))

    for hf in glob.glob(os.path.join(root, "history", "countries", "*.txt")):
        m = re.match(r"\s*([A-Z0-9]{3})\s*-\s*(.+?)\.txt$", os.path.basename(hf))
        if m:
            names.setdefault(m.group(1), re.sub(r"(?<=[a-z])(?=[A-Z])", " ", m.group(2).strip()))
    # cores de reserva: as do mapa do projeto para a mesma tag
    own_colors = {}
    for nf in glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "nations_*.txt")):
        for line in read_text(nf).splitlines():
            q = line.split("|")
            if len(q) >= 3 and re.fullmatch(r"[A-Z0-9]{3}", q[0]):
                try:
                    own_colors[q[0]] = [int(v) for v in q[2].split(",")]
                except ValueError:
                    pass

    used = sorted(set(owner.values()))
    if len(used) > 65535:
        sys.exit(f"{len(used)} paises: o shader suporta no maximo 65535.")
    first_prov = {}
    for pid in sorted(owner):
        first_prov.setdefault(owner[pid], pid)

    countries = []
    for tag in used:
        color = own_colors.get(tag) or hashed_color(tag)
        rel = tags.get(tag)
        if rel:
            cf = os.path.join(root, "common", rel.replace("\\", "/"))
            if os.path.isfile(cf):
                for k, v in parse_script(read_text(cf)):
                    if k == "color" and isinstance(v, list):
                        vals = [float(x[1]) for x in v if x[0] is None]
                        if len(vals) >= 3:
                            if all(c <= 1.0 for c in vals[:3]) and any("." in str(x[1]) for x in v):
                                vals = [c * 255 for c in vals]
                            color = [int(c) for c in vals[:3]]
                        break
        capital = first_prov.get(tag, 1)
        for hf in glob.glob(os.path.join(root, "history", "countries", tag + " -*.txt")):
            st = state_at(parse_script(read_text(hf)), cutoff)
            c = st.get("capital")
            if isinstance(c, str) and c.isdigit() and int(c) in defs:
                capital = int(c)
            break
        countries.append({"tag": tag, "name": names.get(tag, tag), "color": color, "capital": capital})

    # ---------------------------------------------------------- culturas
    groups = {}
    for cf in glob.glob(os.path.join(root, "common", "cultures", "*.txt")):
        for gname, gval in parse_script(read_text(cf)):
            if isinstance(gval, list):
                for cname, cval in gval:
                    if isinstance(cval, list) and cname not in ("graphical_culture", "male_names",
                                                                "female_names", "dynasty_names"):
                        groups[cname] = gname
    loc = {}
    for f in find_loc(root, "*_l_english.yml"):
        for m in re.finditer(r'^\s*([a-z_]+):\d*\s+"(.*)"\s*$', read_text(f), re.M):
            loc.setdefault(m.group(1), m.group(2))

    def pretty(key):
        return loc.get(key) or key.replace("_", " ").title()

    cultures = []
    for cid in sorted(set(culture.values())):
        g = groups.get(cid, "")
        if g:   # cultura do mesmo grupo: tom parecido
            base = hashed_color(g)
            hh, ss, vv = colorsys.rgb_to_hsv(*(v / 255 for v in base))
            k = hashlib.md5(cid.encode()).digest()
            col = [int(c * 255) for c in colorsys.hsv_to_rgb((hh + (k[0] - 128) / 2600) % 1.0,
                   min(1, max(0.3, ss + (k[1] - 128) / 900)), min(1, max(0.4, vv + (k[2] - 128) / 700)))]
        else:
            col = hashed_color(cid)
        cultures.append({"id": cid, "name": pretty(cid), "group": pretty(g) if g else "", "color": col})

    # ---------------------------------------------------------- religioes
    # todas as de common/religions (ordem do arquivo) + as usadas que faltarem; nomes em
    # portugues de data/religioes_pt.json
    with open("data/religioes_pt.json", encoding="utf-8") as f:
        pt = json.load(f)

    def nice(key):
        return pt.get(key) or pretty(key)

    religions, seen = [], set()
    for rf in sorted(glob.glob(os.path.join(root, "common", "religions", "*.txt"))):
        for gname, gval in parse_script(read_text(rf)):
            if not isinstance(gval, list):
                continue
            for rname, rval in gval:
                if not isinstance(rval, list) or rname in seen:
                    continue
                col = next((v for k, v in rval if k == "color" and isinstance(v, list)), None)
                vals = [float(v) for k, v in (col or []) if k is None and re.fullmatch(r"-?[\d.]+", v)]
                if len(vals) < 3:
                    continue    # nao e religiao (ex.: flag_emblem_index_range)
                if max(vals[:3]) <= 1.0:
                    vals = [v * 255 for v in vals]
                seen.add(rname)
                religions.append({"id": rname, "name": nice(rname), "group": nice(gname),
                                  "color": [int(v) for v in vals[:3]]})
    for rid in sorted(set(religion.values()) - seen - {""}):
        religions.append({"id": rid, "name": nice(rid), "group": "", "color": hashed_color(rid)})

    # ---------------------------------------------------------- produtos (common/tradegoods + prices)
    with open("data/produtos_pt.json", encoding="utf-8") as f:
        goods_pt = json.load(f)
    prices = {}
    for pf in sorted(glob.glob(os.path.join(root, "common", "prices", "*.txt"))):
        for gname, gval in parse_script(read_text(pf)):
            if isinstance(gval, list):
                for k, v in gval:
                    if k == "base_price" and isinstance(v, str):
                        try:
                            prices[gname] = float(v)
                        except ValueError:
                            pass
    trade_goods, seen = [], set()
    for tf in sorted(glob.glob(os.path.join(root, "common", "tradegoods", "*.txt"))):
        for gname, gval in parse_script(read_text(tf)):
            if not isinstance(gval, list) or gname in seen:
                continue
            col = next((v for k, v in gval if k == "color" and isinstance(v, list)), None)
            vals = [float(v) for k, v in (col or []) if k is None and re.fullmatch(r"-?[\d.]+", v)]
            if len(vals) < 3:
                continue
            if max(vals[:3]) <= 1.0:
                vals = [v * 255 for v in vals]
            seen.add(gname)
            trade_goods.append({"id": gname, "name": goods_pt.get(gname) or pretty(gname),
                                "color": [min(255, int(v + 0.5)) for v in vals[:3]],
                                "price": prices.get(gname, 1.0)})
    for gid in sorted(set(goods.values()) - seen):
        trade_goods.append({"id": gid, "name": goods_pt.get(gid) or pretty(gid), "color": hashed_color(gid),
                            "price": prices.get(gid, 1.0)})

    # ---------------------------------------------------------- nos de comercio (common/tradenodes)
    with open("data/nos_comercio_pt.json", encoding="utf-8") as f:
        node_pt = json.load(f)
    trade_nodes, node_of = [], {}
    for nf in sorted(glob.glob(os.path.join(root, "common", "tradenodes", "*.txt"))):
        for nname, nval in parse_script(read_text(nf)):
            if not isinstance(nval, list):
                continue
            node = {"id": nname, "name": node_pt.get(nname) or pretty(nname), "color": hashed_color(nname),
                    "location": 0, "inland": False, "end": False, "outgoing": []}
            for k, v in nval:
                if k == "location" and isinstance(v, str) and v.isdigit():
                    node["location"] = int(v)
                elif k == "color" and isinstance(v, list):
                    vals = [float(x) for kk, x in v if kk is None and re.fullmatch(r"-?[\d.]+", x)]
                    if len(vals) >= 3:
                        if max(vals[:3]) <= 1.0:
                            vals = [x * 255 for x in vals]
                        node["color"] = [min(255, int(x + 0.5)) for x in vals[:3]]
                elif k in ("inland", "end") and v == "yes":
                    node[k] = True
                elif k == "outgoing" and isinstance(v, list):
                    to = next((x for kk, x in v if kk == "name" and isinstance(x, str)), "")
                    path = next((x for kk, x in v if kk == "path" and isinstance(x, list)), [])
                    node["outgoing"].append({"to": to, "path": [int(x) for kk, x in path
                                                                 if kk is None and x.isdigit()]})
                elif k == "members" and isinstance(v, list):
                    for kk, x in v:
                        if kk is None and x.isdigit():
                            node_of.setdefault(int(x), nname)
            trade_nodes.append(node)

    # ---------------------------------------------------------- map.json
    provinces = []
    for pid in range(n_prov):
        if pid == 0:
            provinces.append({"id": 0, "name": "—", "sea": True, "owner": "", "terrain": "mar",
                              "development": 0, "center": [0, 0], "neighbors": sorted(neigh[0])})
            continue
        sea = pid in sea_ids
        if pid in prov_names:
            nm = prov_names[pid]
        else:
            nm = defs[pid][3] if defs[pid][3] not in ("", "x") else f"Província {pid}"
        prov = {
            "id": pid, "name": nm, "sea": sea,
            "owner": "" if sea else owner.get(pid, ""),
            "terrain": "mar" if sea else classify_terrain(pid, h_mean, h_std, climates),
            "development": 0 if sea else dev.get(pid, 0),
            "center": [round(float(cx[pid]), 1), round(float(cy[pid]), 1)],
            "neighbors": sorted(neigh[pid]),
        }
        if not sea:
            prov["culture"] = culture.get(pid, "")
            prov["religion"] = religion.get(pid, "")
            prov["trade_goods"] = goods.get(pid, "")
            if pid in prov_buildings:
                prov["buildings"] = prov_buildings[pid]
            if pid in cot:
                prov["center_of_trade"] = cot[pid]
        if pid in node_of:
            prov["trade_node"] = node_of[pid]
            prov["base_tax"], prov["base_production"], prov["base_manpower"] = dev_parts.get(pid, (0, 0, 0))
            prov["coastal"] = any(q in sea_ids for q in neigh[pid])
            prov["base_development"] = prov["development"]
        provinces.append(prov)

    with open("data/eu4/map.json", "w", encoding="utf-8") as f:
        json.dump({"width": W, "height": H, "countries": countries, "cultures": cultures,
                   "religions": religions, "trade_goods": trade_goods, "trade_nodes": trade_nodes,
                   "buildings": buildings, "provinces": provinces},
                  f, ensure_ascii=False, separators=(",", ":"))

    n_own = sum(1 for p in provinces if p["owner"])
    print(f"\nOK: mapa {W}x{H}, {len(defs)} provincias ({len(sea_ids)} de mar/lagos), "
          f"{len(countries)} paises, {n_own} provincias com dono em {args.data}")
    print("Abra o projeto no Godot: ele usa data/eu4/ e assets/eu4/ automaticamente.")
    print("Para voltar ao mapa de exemplo, apague as pastas data/eu4 e assets/eu4.")


if __name__ == "__main__":
    main()
