#!/usr/bin/env python3
"""Importa o mapa e os donos de 1444 da SUA instalacao do Europa Universalis IV.

Le (da pasta do jogo):
  map/provinces.bmp, map/definition.csv, map/default.map, map/climate.txt
  history/provinces/*.txt, history/countries/*.txt
  common/country_tags/*.txt, common/countries/*.txt
  localisation/*countries*_l_english.yml, localisation/*prov_names*_l_english.yml

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
import glob
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
                if k2 is not None:
                    st[k2] = v2
    return st


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
    wasteland = set()
    clim = os.path.join(root, "map", "climate.txt")
    if os.path.isfile(clim):
        wasteland = ids_in_block(read_text(clim), "impassable")

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
    del ids

    # ---------------------------------------------------------- historia das provincias (dono em 1444)
    print("Lendo historia das provincias...", flush=True)
    owner = {}
    dev = {}
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
        try:
            dev[pid] = int(round(sum(float(st.get(k, 0) or 0) for k in ("base_tax", "base_production", "base_manpower"))))
        except (TypeError, ValueError):
            dev[pid] = 0

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

    used = sorted(set(owner.values()))
    if len(used) > 255:
        sys.exit(f"{len(used)} paises: o shader suporta no maximo 255.")
    first_prov = {}
    for pid in sorted(owner):
        first_prov.setdefault(owner[pid], pid)

    countries = []
    for tag in used:
        color = [128, 128, 128]
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
        provinces.append({
            "id": pid, "name": nm, "sea": sea,
            "owner": "" if sea else owner.get(pid, ""),
            "terrain": "mar" if sea else ("intransitável" if pid in wasteland else "—"),
            "development": 0 if sea else dev.get(pid, 0),
            "center": [round(float(cx[pid]), 1), round(float(cy[pid]), 1)],
            "neighbors": sorted(neigh[pid]),
        })

    with open("data/eu4/map.json", "w", encoding="utf-8") as f:
        json.dump({"width": W, "height": H, "countries": countries, "provinces": provinces},
                  f, ensure_ascii=False, separators=(",", ":"))

    n_own = sum(1 for p in provinces if p["owner"])
    print(f"\nOK: mapa {W}x{H}, {len(defs)} provincias ({len(sea_ids)} de mar/lagos), "
          f"{len(countries)} paises, {n_own} provincias com dono em {args.data}")
    print("Abra o projeto no Godot: ele usa data/eu4/ e assets/eu4/ automaticamente.")
    print("Para voltar ao mapa de exemplo, apague as pastas data/eu4 e assets/eu4.")


if __name__ == "__main__":
    main()
