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
  map/terrain.txt, map/terrain.bmp, map/trees.bmp (terreno do proprio EU4; sem eles o terreno e
                                               estimado pelo heightmap e pelo clima)
  map/area.txt, map/region.txt, map/superregion.txt, map/continent.txt (geografia; opcionais)
  map/rivers.bmp (rios), map/adjacencies.csv (estreitos); opcionais
  common/technologies/*.txt, common/technology.txt (tecnologias e grupos tecnologicos; opcionais)
  common/units/*.txt                           (unidades: tipo, grupo, atributos; opcional)
  common/ideas/*.txt                           (ideias nacionais e grupos de ideias; opcional)
  common/advisortypes/*.txt, history/advisors/*.txt (tipos de conselheiro e conselheiros historicos)
  common/institutions/*.txt                    (instituicoes: origem, bonus e onde ja existem em 1444)
  history/diplomacy/*.txt                      (aliancas, suditos, casamentos, unioes, imperadores em 1444)
  history/wars/*.txt                           (guerras ativas e dos ultimos 10 anos, com batalhas)
  gfx/flags/TAG.tga                            (bandeiras -> assets/eu4/flags.png, 64 px cada)
  gfx/interface/... + interface/*.gfx          (icones de produtos, religioes, instituicoes, conselheiros,
                                               construcoes e ideias -> assets/eu4/icons.png, 48 px cada;
                                               molduras de janela, botoes e rolagem -> assets/eu4/ui/)
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
import shutil
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


def country_history(items, cutoff):
    """Pais no dia de inicio: governo, reformas, grupo tecnologico, cultura principal e aceitas,
    religiao, capital, posto, foco nacional, monarca e herdeiro (blocos datados ate a data)."""
    seq = [(k, v) for k, v in items if k and not (DATE_RE.match(k) and isinstance(v, list))]
    dated = sorted(((tuple(int(x) for x in k.split(".")), v) for k, v in items
                    if k and DATE_RE.match(k) and isinstance(v, list)), key=lambda t: t[0])
    for d, v in dated:
        if d <= cutoff:
            seq += [(k, x) for k, x in v if k]
    h = {"reforms": [], "accepted_cultures": []}
    keys = {"government": "government", "technology_group": "tech_group", "primary_culture": "primary_culture",
            "religion": "religion", "capital": "capital", "national_focus": "national_focus"}
    for k, v in seq:
        if isinstance(v, str):
            if k in keys:
                h[keys[k]] = v
            elif k == "government_rank" and v.isdigit():
                h["rank"] = int(v)
            elif k == "add_government_reform" and v not in h["reforms"]:
                h["reforms"].append(v)
            elif k == "add_accepted_culture" and v not in h["accepted_cultures"]:
                h["accepted_cultures"].append(v)
            elif k == "remove_accepted_culture" and v in h["accepted_cultures"]:
                h["accepted_cultures"].remove(v)
            elif k == "elector":
                if v == "yes":
                    h["elector"] = True
                else:
                    h.pop("elector", None)
            elif k == "mercantilism" and to_num(v) is not None:
                h["mercantilism"] = to_num(v)
            elif k == "add_prestige" and to_num(v) is not None:
                h["prestige"] = to_num(h.get("prestige", 0) + to_num(v))
        elif k in ("monarch", "heir") and isinstance(v, list):
            person = {}
            for kk, vv in v:
                if kk in ("name", "dynasty", "birth_date") and isinstance(vv, str):
                    person[kk] = vv
                elif kk in ("adm", "dip", "mil") and isinstance(vv, str) and vv.isdigit():
                    person[kk] = int(vv)
            h[k] = person
            if k == "monarch" and "heir" in h and h["heir"].get("name") == person.get("name"):
                del h["heir"]       # o herdeiro virou o monarca
    return h


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


def core_claims(items, cutoff):
    """Nucleos e reivindicacoes da provincia no dia de inicio (add_core/remove_core/add_claim/remove_claim
    no topo e nos blocos datados ate a data, em ordem). -> (nucleos, reivindicacoes), ordenados."""
    seq = [(k, v) for k, v in items if k and not (DATE_RE.match(k) and isinstance(v, list))]
    dated = sorted(((tuple(int(x) for x in k.split(".")), v) for k, v in items
                    if k and DATE_RE.match(k) and isinstance(v, list)), key=lambda t: t[0])
    for d, v in dated:
        if d <= cutoff:
            seq += [(k, x) for k, x in v if k]
    cores, claims = [], []
    for k, v in seq:
        if not isinstance(v, str):
            continue
        if k == "add_core" and v not in cores:
            cores.append(v)
        elif k == "remove_core" and v in cores:
            cores.remove(v)
        elif k == "add_claim" and v not in claims:
            claims.append(v)
        elif k == "remove_claim" and v in claims:
            claims.remove(v)
    return sorted(cores), sorted(claims)


def script_tree(items):
    """Arvore do script do EU4 em listas [chave, valor] (chave "" para itens soltos), para o JSON."""
    return [[k or "", script_tree(v) if isinstance(v, list) else v] for k, v in items]


def eu4_casus_belli(root):
    """Casus belli (common/cb_types) e objetivos de guerra (common/wargoal_types), com as condicoes
    (prerequisites) e os blocos de paz em arvore; o jogo avalia um subconjunto das condicoes."""
    cbs, wgs = [], []
    seen = set()
    for f in sorted(glob.glob(os.path.join(root, "common", "cb_types", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not name or not isinstance(val, list) or name in seen:
                continue
            seen.add(name)
            cb = {"id": name, "triggered": False, "months": 0, "valid_for_subject": True, "exclusive": False,
                  "independence": False, "prerequisites_self": [], "prerequisites": [], "war_goal": ""}
            for k, v in val:
                if k == "is_triggered_only" and isinstance(v, str):
                    cb["triggered"] = v == "yes"
                elif k in ("valid_for_subject", "exclusive", "independence") and isinstance(v, str):
                    cb[k] = v == "yes"
                elif k == "months" and to_num(v) is not None:
                    cb["months"] = to_num(v)
                elif k in ("prerequisites_self", "prerequisites") and isinstance(v, list):
                    cb[k] = script_tree(v)
                elif k == "war_goal" and isinstance(v, str):
                    cb["war_goal"] = v
            cbs.append(cb)
    seen = set()
    for f in sorted(glob.glob(os.path.join(root, "common", "wargoal_types", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not name or not isinstance(val, list) or name in seen:
                continue
            seen.add(name)
            wg = {"id": name, "type": "", "attacker": [], "defender": [], "war_name": ""}
            for k, v in val:
                if k in ("type", "war_name") and isinstance(v, str):
                    wg[k] = v
                elif k in ("attacker", "defender") and isinstance(v, list):
                    wg[k] = script_tree(v)
            wgs.append(wg)
    return cbs, wgs


def script_value(v):
    """Valor simples do script do EU4: numero, yes/no -> bool, ou o texto."""
    if v in ("yes", "no"):
        return v == "yes"
    n = to_num(v)
    return n if n is not None else v


def eu4_diplomacy_data(root):
    """Tudo de diplomacia do EU4 que o jogo ainda nao tinha: condicoes e efeitos das acoes
    (common/diplomatic_actions), acoes por script (common/new_diplomatic_actions; static_actions =
    icone/dica das acoes fixas), tipos de suditos resolvidos (common/subject_types, copy_from),
    tratados de paz por script (common/peace_treaties), insultos (common/insults) e as constantes
    NDiplomacy do common/defines.lua. Condicoes e efeitos ficam em arvore [chave, valor]."""
    out = {"actions": {}, "scripted_actions": {}, "static_actions": {}, "subject_types": {},
           "peace_treaties": {}, "insults": [], "defines": {}}
    for f in sorted(glob.glob(os.path.join(root, "common", "diplomatic_actions", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not name or not isinstance(val, list) or name in out["actions"]:
                continue
            a = {"conditions": [], "effect": []}
            for k, v in val:
                if k == "condition" and isinstance(v, list):
                    c = {"tooltip": "", "potential": [], "allow": []}
                    for kk, vv in v:
                        if kk == "tooltip" and isinstance(vv, str):
                            c["tooltip"] = vv
                        elif kk in ("potential", "allow") and isinstance(vv, list):
                            c[kk] = script_tree(vv)
                    a["conditions"].append(c)
                elif k == "effect" and isinstance(v, list):
                    a["effect"] = script_tree(v)
            out["actions"][name] = a
    for f in sorted(glob.glob(os.path.join(root, "common", "new_diplomatic_actions", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not name or not isinstance(val, list):
                continue
            if name == "static_actions":
                for k, v in val:
                    if k and isinstance(v, list) and k not in out["static_actions"]:
                        out["static_actions"][k] = {kk: script_value(vv) for kk, vv in v if kk and isinstance(vv, str)}
            elif name not in out["scripted_actions"]:
                out["scripted_actions"][name] = script_tree(val)
    raw = {}
    order = []
    for f in sorted(glob.glob(os.path.join(root, "common", "subject_types", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not name or not isinstance(val, list):
                continue
            if name not in raw:
                raw[name] = []
                order.append(name)
            raw[name] += val
    done = {}

    def resolve(name, depth=0):
        if name in done:
            return done[name]
        own = {}
        base = {}
        for k, v in raw.get(name, []):
            if k == "copy_from" and isinstance(v, str) and v in raw and depth < 10:
                base = {kk: vv for kk, vv in resolve(v, depth + 1).items() if kk != "count"}
            elif k and isinstance(v, str):
                own[k] = script_value(v)
        res = dict(base)
        res.update(own)
        done[name] = res
        return res
    for name in order:
        if name != "default":
            out["subject_types"][name] = resolve(name)
    for f in sorted(glob.glob(os.path.join(root, "common", "peace_treaties", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if name and isinstance(val, list) and name not in out["peace_treaties"]:
                out["peace_treaties"][name] = script_tree(val)
    seen = set()
    for f in sorted(glob.glob(os.path.join(root, "common", "insults", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if name and isinstance(val, list) and name not in seen:
                seen.add(name)
                trig = next((v for k, v in val if k == "trigger" and isinstance(v, list)), [])
                out["insults"].append({"id": name, "trigger": script_tree(trig)})
    dl = os.path.join(root, "common", "defines.lua")
    if os.path.isfile(dl):
        m = re.search(r"NDiplomacy\s*=\s*\{(.*?)\n\}", read_text(dl), re.S)
        if m:
            for mm in re.finditer(r"\b([A-Z][A-Z0-9_]*)\s*=\s*(-?[0-9.]+)", re.sub(r"--[^\n]*", "", m.group(1))):
                if to_num(mm.group(2)) is not None and mm.group(1) not in out["defines"]:
                    out["defines"][mm.group(1)] = to_num(mm.group(2))
    return out


# pastas de script do EU4 gravadas inteiras (em arvore) em data/eu4/eu4data/ (Eu4Data no jogo)
SCRIPT_TOPS = ["common", "history", "events", "decisions", "missions"]


def lua_defines(text):
    """Constantes de um .lua do EU4: blocos NX = { CHAVE = valor } -> {NX: {CHAVE: valor}} e
    sobrescritas NDefines.NX.CHAVE = valor -> {"NX.CHAVE": valor}. Numeros viram numero, textos ficam."""
    text = re.sub(r"--[^\n]*", "", text)
    blocks = {}
    for m in re.finditer(r"\b(?!NDefines\b)(N[A-Za-z]+)\s*=\s*\{(.*?)\n\}", text, re.S):
        d = blocks.setdefault(m.group(1), {})
        for mm in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("[^"]*"|-?[0-9.]+)', m.group(2)):
            v = mm.group(2)
            d.setdefault(mm.group(1), v.strip('"') if v.startswith('"') else to_num(v))
    over = {}
    for mm in re.finditer(r'\bNDefines\.(N[A-Za-z]+)\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("[^"]*"|-?[0-9.]+)', text):
        v = mm.group(3)
        over.setdefault(mm.group(1) + "." + mm.group(2), v.strip('"') if v.startswith('"') else to_num(v))
    return blocks, over


def eu4_all_data(root, out):
    """Todos os scripts do EU4 em arvore [chave, valor], um JSON por pasta, para o jogo usar as regras
    originais: eu4data/<pasta>.json = {arquivo sem .txt: arvore} (common/<x>, history/<x>, events,
    decisions, missions; os .txt soltos de common/ em common/_files.json), eu4data/map.json = os
    .txt/.map da pasta map, eu4data/defines.json = todas as constantes dos .lua (blocos + overrides
    por arquivo de common/defines/) e eu4data/index.json = pasta -> numero de arquivos."""
    out = os.path.join(out, "eu4data")
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    groups = {}                                  # pasta relativa -> [arquivos]
    for top in SCRIPT_TOPS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
            for fn in files:
                if not fn.lower().endswith(".txt"):
                    continue
                key = rel
                if rel == "common":
                    key = "common/_files"
                elif rel.count("/") > 1:                 # subpastas ficam com a pasta de cima
                    key = "/".join(rel.split("/")[:2])
                groups.setdefault(key, []).append(os.path.join(dirpath, fn))
    mdir = os.path.join(root, "map")
    if os.path.isdir(mdir):
        groups["map"] = [os.path.join(mdir, f) for f in os.listdir(mdir)
                         if f.lower().endswith((".txt", ".map")) and os.path.isfile(os.path.join(mdir, f))]
    index = {}
    for key in sorted(groups):
        files = sorted(groups[key], key=lambda f: os.path.relpath(f, root).replace(os.sep, "/"))
        data = {}
        for f in files:
            name = os.path.relpath(f, root).replace(os.sep, "/")
            name = name[len(key) + 1:] if name.startswith(key + "/") else os.path.basename(name)
            data.setdefault(re.sub(r"\.(txt|map)$", "", name, flags=re.I), script_tree(parse_script(read_text(f))))
        path = os.path.join(out, key + ".json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fo:
            json.dump(data, fo, ensure_ascii=False, separators=(",", ":"))
        index[key] = len(data)
    defines = {"overrides": {}}
    luas = [os.path.join(root, "common", "defines.lua")] + \
        sorted(glob.glob(os.path.join(root, "common", "defines", "*.lua")))
    for f in luas:
        if os.path.isfile(f):
            blocks, over = lua_defines(read_text(f))
            for b, d in blocks.items():
                tgt = defines.setdefault(b, {})
                for k, v in d.items():
                    tgt.setdefault(k, v)
            if over:
                defines["overrides"][os.path.splitext(os.path.basename(f))[0]] = over
    with open(os.path.join(out, "defines.json"), "w", encoding="utf-8") as fo:
        json.dump(defines, fo, ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as fo:
        json.dump(index, fo, ensure_ascii=False, separators=(",", ":"))
    return index


# texturas do mapa do EU4 gravadas ao lado do province_ids.png (o shader do mapa usa)
MAP_TEXTURES = ["normal.png", "height.png", "terrain_idx.png", "colormap.png", "colormap_water.png"]
COLORMAPS = ["colormap_summer", "colormap_spring", "colormap_autumn", "colormap_winter"]


def map_textures(root, W, H, out_dir):
    """Texturas do mapa do EU4: normal.png (map/world_normal.bmp, relevo para a luz), height.png
    (map/heightmap.bmp a cada 2 px, profundidade do mar), terrain_idx.png (indice do
    map/terrain.bmp a cada 2 px; as cores da paleta vao em terrain_palette) e, se a instalacao tem,
    colormap.png (map/terrain/colormap_summer.dds ou outra estacao) e colormap_water.png.
    Devolve {"terrain_palette": [[r, g, b] x 256]} (vazio sem o terrain.bmp)."""
    info = {}
    for f in MAP_TEXTURES:
        if os.path.isfile(os.path.join(out_dir, f)):
            os.remove(os.path.join(out_dir, f))
    mdir = os.path.join(root, "map")
    p = os.path.join(mdir, "world_normal.bmp")
    if os.path.isfile(p):
        Image.open(p).convert("RGB").save(os.path.join(out_dir, "normal.png"), optimize=True)
    p = os.path.join(mdir, "heightmap.bmp")
    if os.path.isfile(p):
        hm = Image.open(p).convert("L")
        if hm.size == (W, H):
            Image.fromarray(np.ascontiguousarray(np.asarray(hm, dtype=np.uint8)[::2, ::2]), "L").save(
                os.path.join(out_dir, "height.png"), optimize=True)
    p = os.path.join(mdir, "terrain.bmp")
    if os.path.isfile(p):
        tb = Image.open(p)
        if tb.mode == "P" and tb.size == (W, H):
            Image.fromarray(np.ascontiguousarray(np.asarray(tb, dtype=np.uint8)[::2, ::2]), "L").save(
                os.path.join(out_dir, "terrain_idx.png"), optimize=True)
            pal = (tb.getpalette() or []) + [0] * 768
            info["terrain_palette"] = [pal[i * 3:i * 3 + 3] for i in range(256)]
    tdir = os.path.join(mdir, "terrain")
    for name, dst in [(c, "colormap.png") for c in COLORMAPS] + [("colormap_water", "colormap_water.png")]:
        p = os.path.join(tdir, name + ".dds")
        if os.path.isfile(p) and not os.path.isfile(os.path.join(out_dir, dst)):
            im = load_rgba(p, False)
            if im is not None:
                im.convert("RGB").save(os.path.join(out_dir, dst), optimize=True)
    return info


def river_lines(riv):
    """Rios do rivers.bmp em linhas (o EU4 desenha curvas a partir dos pixels): pixels com indice
    < 254; vizinhos nas 4 direcoes, e na diagonal so quando nenhum dos dois pixels entre eles e rio.
    As linhas vao de uma ponta/juncao (grau != 2) ate outra (os lacos fechados depois), na ordem dos
    pixels (y, x). Cada linha = [largura, x0, y0, x1, y1, ...]; largura = maior indice >= 3 dela
    (3 = mais fino ... 11 = mais largo; 0-2 sao marcadores de nascente/afluente/divisao)."""
    H, W = riv.shape
    ys, xs = np.nonzero(riv < 254)
    val = {int(y) * W + int(x): int(riv[y, x]) for y, x in zip(ys, xs)}
    keys = sorted(val)
    orth = ((1, 0), (0, 1), (-1, 0), (0, -1))
    diag = ((1, 1), (-1, 1), (-1, -1), (1, -1))
    nb = {}
    for k in keys:
        y, x = divmod(k, W)
        out = []
        for dx, dy in orth:
            nx, ny = x + dx, y + dy
            if 0 <= nx < W and 0 <= ny < H and ny * W + nx in val:
                out.append(ny * W + nx)
        for dx, dy in diag:
            nx, ny = x + dx, y + dy
            if 0 <= nx < W and 0 <= ny < H and ny * W + nx in val \
                    and (y * W + nx) not in val and (ny * W + x) not in val:
                out.append(ny * W + nx)
        nb[k] = out
    done = set()
    lines = []

    def walk(a, b):
        pts = [a, b]
        done.add((min(a, b), max(a, b)))
        prev, cur = a, b
        while len(nb[cur]) == 2 and cur != a:
            nxt = nb[cur][0] if nb[cur][0] != prev else nb[cur][1]
            e = (min(cur, nxt), max(cur, nxt))
            if e in done:
                break
            done.add(e)
            pts.append(nxt)
            prev, cur = cur, nxt
        wv = max([val[q] for q in pts if val[q] >= 3] or [3])
        line = [wv]
        for q in pts:
            line += [q % W, q // W]
        lines.append(line)

    for k in keys:
        if len(nb[k]) != 2:
            for n in nb[k]:
                if (min(k, n), max(k, n)) not in done:
                    walk(k, n)
    for k in keys:
        for n in nb[k]:
            if (min(k, n), max(k, n)) not in done:
                walk(k, n)
    return lines


def to_num(v):
    """"2" -> 2, "0.25" -> 0.25, outra coisa -> None."""
    try:
        f = float(v)
        return int(f) if f == int(f) else f
    except (TypeError, ValueError):
        return None


def eu4_technologies(root, building_ids, loc=None):
    """Arvores adm/dip/mil (common/technologies) e grupos tecnologicos (common/technology.txt)."""
    techs = {}
    for cat in ("adm", "dip", "mil"):
        path = os.path.join(root, "common", "technologies", cat + ".txt")
        if not os.path.isfile(path):
            continue
        lst = []
        for k, v in parse_script(read_text(path)):
            if k != "technology" or not isinstance(v, list):
                continue
            t = {"level": len(lst), "year": 0, "modifiers": {}, "buildings": [], "unlocks": [], "units": [],
                 "institutions": {}}
            if loc and f"{cat}_tech_cs_{len(lst)}_name" in loc:
                t["name"] = loc[f"{cat}_tech_cs_{len(lst)}_name"]
            for kk, vv in v:
                if not kk:
                    continue
                if kk == "year" and to_num(vv) is not None:
                    t["year"] = int(to_num(vv))
                elif kk == "expects_institution" and isinstance(vv, list):
                    for a, b in vv:
                        if a and to_num(b) is not None:
                            t["institutions"][a] = to_num(b)
                elif kk == "enable" and isinstance(vv, str):
                    t["units"].append(vv)
                elif vv == "yes":
                    (t["buildings"] if kk in building_ids else t["unlocks"]).append(kk)
                elif kk != "sprite_level" and isinstance(vv, str) and to_num(vv) is not None:
                    t["modifiers"][kk] = to_num(vv)
            lst.append(t)
        techs[cat] = lst
    groups = []
    tp = os.path.join(root, "common", "technology.txt")
    if os.path.isfile(tp):
        for k, v in parse_script(read_text(tp)):
            if k == "groups" and isinstance(v, list):
                for g, gv in v:
                    if g and isinstance(gv, list):
                        d = {"id": g, "start_level": 0, "cost_modifier": 0}
                        for kk, vv in gv:
                            if kk == "start_level" and to_num(vv) is not None:
                                d["start_level"] = int(to_num(vv))
                            elif kk == "start_cost_modifier" and to_num(vv) is not None:
                                d["cost_modifier"] = to_num(vv)
                        groups.append(d)
    return techs, groups


UNIT_NUM_KEYS = ("maneuver", "offensive_morale", "defensive_morale", "offensive_fire", "defensive_fire",
                 "offensive_shock", "defensive_shock", "hull_size", "base_cannons", "blockade", "sailors",
                 "sail_speed", "trade_power")


def eu4_units(root, technologies, loc=None):
    """Unidades (common/units/<id>.txt) com o nivel e a arvore da tecnologia que as libera."""
    unlock = {}
    for cat in ("mil", "dip"):
        for t in technologies.get(cat, []):
            for u in t["units"]:
                unlock.setdefault(u, (cat, t["level"]))
    units = []
    for uf in sorted(glob.glob(os.path.join(root, "common", "units", "*.txt"))):
        uid = os.path.splitext(os.path.basename(uf))[0]
        u = {"id": uid, "name": (loc or {}).get(uid) or pretty_key(uid), "type": ""}
        for k, v in parse_script(read_text(uf)):
            if k == "type" and isinstance(v, str):
                u["type"] = v
            elif k == "unit_type" and isinstance(v, str):
                u["unit_type"] = v
            elif k in UNIT_NUM_KEYS and to_num(v) is not None:
                u[k] = to_num(v)
        if uid in unlock:
            u["tech"], u["level"] = unlock[uid]
        units.append(u)
    return units


TRIGGER_KEYS = {"tag": "tag", "primary_culture": "primary_culture", "culture_group": "culture_group",
                "religion": "religion", "religion_group": "religion_group", "technology_group": "tech_group",
                "government": "government"}


FALSE_AT_START = {"is_revolutionary", "is_revolution_target", "is_federation_nation", "is_colonial_nation",
                  "is_client_nation", "has_country_flag", "primitives"}


def eval_cond(k, v, ctx):
    """Condicao de trigger do EU4 (so as que da para saber em 1444; o resto conta como falsa)."""
    if not k:
        return True
    kl = k.lower()
    if kl == "or":
        return isinstance(v, list) and any(eval_cond(a, b, ctx) for a, b in v if a)
    if kl == "and":
        return isinstance(v, list) and all(eval_cond(a, b, ctx) for a, b in v if a)
    if kl == "not":
        return isinstance(v, list) and not any(eval_cond(a, b, ctx) for a, b in v if a)
    if not isinstance(v, str):
        return False
    if kl == "always":
        return v == "yes"
    if kl in TRIGGER_KEYS:
        return ctx.get(TRIGGER_KEYS[kl]) == v
    if kl in FALSE_AT_START:
        return v == "no"        # nada disso e verdade em 1444
    return False


def idea_mods(items):
    out = {}
    for k, v in items:
        if k and isinstance(v, str):
            n = to_num(v)
            if n is not None:
                out[k] = n
            elif v == "yes":
                out[k] = True
    return out


def eu4_ideas(root, countries, culture_group_of, religion_group_of, loc=None):
    """Grupos de ideias (com category) e ideias nacionais (free = yes). Cada pais recebe em "ideas" o
    primeiro conjunto livre (na ordem dos arquivos) cujo trigger ele cumpre: nacional > de grupo >
    generico (default_ideas)."""
    with open("data/ideias_pt.json", encoding="utf-8") as f:
        pt = json.load(f)["grupos"]
    groups, free_sets = [], []
    for fn in sorted(glob.glob(os.path.join(root, "common", "ideas", "*.txt"))):
        for name, items in parse_script(read_text(fn)):
            if not name or not isinstance(items, list):
                continue
            loc = loc or {}
            st = {"id": name, "name": pt.get(name) or loc.get(name) or pretty_key(name, "_ideas"), "start": {},
                  "bonus": {}, "ideas": []}
            trigger, free = None, False
            # prefixo das ideias: "norse_ideas_x" e "fra_x" (FRA_ideas) viram "X"
            prefix = name.lower() + "_" if any(k and k.lower().startswith(name.lower() + "_") for k, _ in items) \
                else name.lower().removesuffix("_ideas") + "_"
            for k, v in items:
                if k == "category" and isinstance(v, str):
                    st["category"] = v.lower()
                elif k in ("start", "bonus") and isinstance(v, list):
                    st[k] = idea_mods(v)
                elif k == "free":
                    free = v == "yes"
                elif k == "trigger" and isinstance(v, list):
                    trigger = v
                elif k and k not in ("ai_will_do", "important") and isinstance(v, list):
                    nm = loc.get(k) or pretty_key(k[len(prefix):] if k.lower().startswith(prefix) else k)
                    st["ideas"].append({"id": k, "name": nm, "modifiers": idea_mods(v)})
            if free:
                free_sets.append((st, trigger))
            elif "category" in st:
                if trigger is not None:
                    st["restricted"] = True     # exige governo/condicao especial
                groups.append(st)
    used = {}
    for c in countries:
        ctx = dict(c)
        ctx["culture_group"] = culture_group_of.get(c.get("primary_culture", ""), "")
        ctx["religion_group"] = religion_group_of.get(c.get("religion", ""), "")
        for st, trig in free_sets:
            if trig is None or all(eval_cond(a, b, ctx) for a, b in trig if a):
                c["ideas"] = st["id"]
                used[st["id"]] = st
                break
    national = [st for st, _ in free_sets if st["id"] in used]
    return groups, national


# constantes de comercio do common/defines.lua (nome -> chave no map.json)
TRADE_DEFINES = ["TRADE_CAPITAL_POWER", "TRADE_NON_CAPITAL_OFFICE", "TRADE_MERCHANT_PRESENT", "TRADE_ADDED_VALUE_MODIFER",
                 "TRADE_PROPAGATE_DIVIDER", "TRADE_PROPAGATE_THRESHOLD", "TRADED_FRACTION_FOR_BONUS",
                 "MERCHANT_MAX_POWER_BONUS", "MIN_RELATIONS_TO_ALLY", "IMPROVE_RELATION_SPEED", "INSULT_TRUST",
                 "BASE_MP_TO_MANPOWER", "MAX_MANPOWER", "MIN_MONTHLY_MANPOWER",
                 "PS_BOOST_STABILITY", "BREAK_MARRIAGE_STABILITY_PENALTY",
                 "FORM_MARRIAGE_HIGHER_PRESTIGE", "FORM_MARRIAGE_HIGHER_LEGITIMACY",
                 "INFANTRY_COST", "CAVALRY_COST", "ARTILLERY_COST", "INFANTRY_TIME", "CAVALRY_TIME", "ARTILLERY_TIME",
                 "INFANTRY_SPEED", "LAND_MAINTENANCE_FACTOR", "LAND_TECH_MAINTENANCE_IMPACT",
                 "LAND_FORCELIMIT_EXTRA_COST_FACTOR", "MONTHLY_REINFORCE", "STARTING_ARMY_SIZE",
                 "INF_REGIMENT_MANPOWER_COST", "MIN_ARMY_MAINTENANCE",
                 "BASE_COMBAT_WIDTH", "MAX_COMBAT_WIDTH", "DAYS_PER_PHASE", "COMBAT_DICE_SIDE", "WAR_LENGTH_DAMAGE_MODIFIER",
                 "BATTLE_DAILY_MORALE_DAMAGE", "OVERRUN_FACTOR", "PRESTIGE_FROM_LAND", "MORALE_RECOVERY_SPEED",
                 "MORALE_RECOVERY_SPEED_OWN_TERRITORY", "GARRISON_SIZE", "SIEGE_FORCE_NEEDED_MULTIPLIER", "DAYS_PER_SIEGE_PHASE",
                 "SIEGE_WIN", "SIEGE_MEMORY", "SIEGE_ATTRITION", "SUPPLYLIMIT_BASE_MULTIPLIER", "WARSCORE_MAX_FROM_BATTLES",
                 "SIEGE_BONUS_SUPPLIES_SHORTAGE", "SIEGE_BONUS_FOOD_SHORTAGE", "SIEGE_BONUS_WATER_SHORTAGE", "SIEGE_BONUS_DEFENDERS_DESERT"]
# modificadores estaticos usados no comercio: (bloco, efeito, chave no map.json)
TRADE_STATIC = [("development", "province_trade_power_value", "dev_trade_power"),
                ("development", "local_missionary_strength", "dev_missionary_strength"),
                ("coastal", "province_trade_power_modifier", "coastal_trade_power"),
                ("mercantilism", "global_prov_trade_power_modifier", "mercantilism_trade_power"),
                ("base_values", "merchants", "base_merchants"),
                ("core", "local_manpower_modifier", "core_manpower")]
# blocos inteiros de modificadores estaticos guardados em trade_rules["statics"] (efeitos numericos)
STATIC_BLOCKS = ["prestige", "emperor", "stability", "positive_stability", "negative_stability",
                 "legitimacy", "num_of_marriages", "republican_tradition",
                 "inverse_republican_tradition", "devotion", "development", "capital_city"]


def eu4_trade(root, loc):
    """Centros de comercio (common/centers_of_trade) e regras de comercio (modificadores estaticos e defines)."""
    cots = []
    with open("data/comercio_pt.json", encoding="utf-8") as fp:
        cot_pt = json.load(fp).get("centros", {})
    for f in sorted(glob.glob(os.path.join(root, "common", "centers_of_trade", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not isinstance(val, list):
                continue
            d = {k: v for k, v in val if k}
            pm = {k: v for k, v in d.get("province_modifiers", []) if k} if isinstance(d.get("province_modifiers"), list) else {}
            if to_num(d.get("level")) is None:
                continue
            cots.append({"id": name, "name": cot_pt.get(name) or loc.get(name) or pretty_key(name), "level": int(to_num(d["level"])),
                         "type": d.get("type", ""), "trade_power": to_num(pm.get("province_trade_power_value", "0")) or 0})
    rules = {}
    for f in sorted(glob.glob(os.path.join(root, "common", "static_modifiers", "*.txt"))):
        blocks = {k: v for k, v in parse_script(read_text(f)) if k and isinstance(v, list)}
        for block, key, out in TRADE_STATIC:
            if block in blocks and out not in rules:
                v = next((to_num(x) for k, x in blocks[block] if k == key and to_num(x) is not None), None)
                if v is not None:
                    rules[out] = v
    for f in sorted(glob.glob(os.path.join(root, "common", "static_modifiers", "*.txt"))):
        for k, v in parse_script(read_text(f)):
            if k == "base_values" and isinstance(v, list) and "base_values" not in rules:
                bv = {}
                for kk, vv in v:
                    if kk and kk not in bv and to_num(vv) is not None:
                        bv[kk] = to_num(vv)
                rules["base_values"] = bv
            if k in STATIC_BLOCKS and isinstance(v, list) and k not in rules.setdefault("statics", {}):
                st = {}
                for kk, vv in v:
                    if kk and kk not in st and to_num(vv) is not None:
                        st[kk] = to_num(vv)
                rules["statics"][k] = st
    dl = os.path.join(root, "common", "defines.lua")
    if os.path.isfile(dl):
        text = read_text(dl)
        for name in TRADE_DEFINES:
            m = re.search(r"\b%s\s*=\s*(-?[0-9.]+)" % name, text)
            if m and to_num(m.group(1)) is not None:
                rules[name.lower()] = to_num(m.group(1))
    return cots, rules


def eu4_opinions(root):
    """Modificadores de opiniao (common/opinion_modifiers): id -> efeitos numericos (opinion, max, min,
    yearly_decay, months...). A 1a definicao de cada um vale; a de cada chave dentro dele tambem."""
    out = {}
    for f in sorted(glob.glob(os.path.join(root, "common", "opinion_modifiers", "*.txt"))):
        for name, val in parse_script(read_text(f)):
            if not name or not isinstance(val, list) or name in out:
                continue
            d = {}
            for k, v in val:
                if k and k not in d and to_num(v) is not None:
                    d[k] = to_num(v)
            out[name] = d
    return out


def eu4_advisors(root, defs):
    """Tipos de conselheiro (categoria e efeitos) e conselheiros historicos (nome, provincia, nivel, datas)."""
    with open("data/conselheiros_pt.json", encoding="utf-8") as f:
        pt = json.load(f)
    types = []
    for fn in sorted(glob.glob(os.path.join(root, "common", "advisortypes", "*.txt"))):
        for name, items in parse_script(read_text(fn)):
            if not name or not isinstance(items, list):
                continue
            cat = next((v for k, v in items if k == "monarch_power" and isinstance(v, str)), "")
            if not cat:
                continue
            types.append({"id": name, "name": pt.get(name) or pretty_key(name), "category": cat.lower(),
                          "modifiers": idea_mods([(k, v) for k, v in items if k not in ("monarch_power", "chance")])})
    known = {t["id"] for t in types}
    advisors = []
    for fn in sorted(glob.glob(os.path.join(root, "history", "advisors", "*.txt"))):
        for k, items in parse_script(read_text(fn)):
            if k != "advisor" or not isinstance(items, list):
                continue
            a = {}
            for kk, v in items:
                if kk in ("name", "type", "date", "death_date") and isinstance(v, str):
                    a[kk] = v
                elif kk in ("advisor_id", "location", "skill") and isinstance(v, str) and v.isdigit():
                    a["id" if kk == "advisor_id" else kk] = int(v)
                elif kk == "female" and v == "yes":
                    a["female"] = True
            if a.get("type") in known and a.get("location") in defs and "name" in a:
                advisors.append(a)
    return types, advisors


COUNTRY_TRIGGERS = {"technology_group": "tech_group", "government": "government", "primary_culture": "primary_culture",
                    "religion": "religion", "tag": "tag"}


def eval_country(k, v, c):
    """Condicao de pais (owner = { ... }) para o history das instituicoes."""
    if not k:
        return True
    kl = k.lower()
    if kl in ("or", "and", "not"):
        if not isinstance(v, list):
            return False
        r = [eval_country(a, b, c) for a, b in v if a]
        return any(r) if kl == "or" else (all(r) if kl == "and" else not any(r))
    if not isinstance(v, str):
        return False
    if kl in COUNTRY_TRIGGERS:
        return c.get(COUNTRY_TRIGGERS[kl]) == v
    if kl == "has_reform":
        return v in c.get("reforms", [])
    if kl in FALSE_AT_START or kl == "is_playing_custom_nation":
        return v == "no"
    return False


def eval_province(k, v, p, c, year):
    """Condicao de provincia (history das instituicoes). p = provincia (com culture_group), c = dono."""
    if not k:
        return True
    kl = k.lower()
    if kl in ("or", "and", "not"):
        if not isinstance(v, list):
            return False
        r = [eval_province(a, b, p, c, year) for a, b in v if a]
        return any(r) if kl == "or" else (all(r) if kl == "and" else not any(r))
    if kl == "owner":
        return c is not None and isinstance(v, list) and all(eval_country(a, b, c) for a, b in v if a)
    if not isinstance(v, str):
        return False
    if kl == "is_year":
        return v.isdigit() and int(v) <= year
    if kl in ("continent", "region", "superregion", "area", "culture", "culture_group", "religion", "trade_goods"):
        return p.get(kl) == v
    if kl == "province_id":
        return v.isdigit() and int(v) == p["id"]
    return False


def eu4_institutions(root, cutoff):
    """Instituicoes (bonus, data e provincia de origem) e o trigger "history" que diz onde ja existem."""
    with open("data/instituicoes_pt.json", encoding="utf-8") as f:
        pt = json.load(f)
    out = []
    for fn in sorted(glob.glob(os.path.join(root, "common", "institutions", "*.txt"))):
        for name, items in parse_script(read_text(fn)):
            if not name or not isinstance(items, list):
                continue
            inst = {"id": name, "name": pt["nomes"].get(name) or pretty_key(name),
                    "color": pt["cores"].get(name) or hashed_color(name), "bonus": {}}
            hist = None
            for k, v in items:
                if k == "bonus" and isinstance(v, list):
                    inst["bonus"] = idea_mods(v)
                elif k == "historical_start_date" and isinstance(v, str):
                    inst["start_date"] = v
                elif k == "historical_start_province" and isinstance(v, str) and v.isdigit():
                    inst["start_province"] = int(v)
                elif k == "history" and isinstance(v, list):
                    hist = v
            out.append((inst, hist))
    return out


def date_tuple(s):
    p = (s or "").split(".")
    try:
        return tuple(int(x) for x in (p + ["1", "1"])[:3])
    except ValueError:
        return (9999, 1, 1)


def eu4_diplomacy(root, cutoff):
    """Relacoes ativas na data (history/diplomacy): [{type, first, second, subject_type?}], imperador do
    Sacro Imperio e imperador celestial."""
    rel, emperor, celestial = [], "", ""
    for fn in sorted(glob.glob(os.path.join(root, "history", "diplomacy", "*.txt"))):
        dated = []
        for k, v in parse_script(read_text(fn)):
            if not k or not isinstance(v, list):
                continue
            if DATE_RE.match(k):
                dated.append((date_tuple(k), v))
                continue
            d = {kk: vv for kk, vv in v if kk and isinstance(vv, str)}
            if "first" in d and "second" in d and \
                    date_tuple(d.get("start_date", "1.1.1")) <= cutoff < date_tuple(d.get("end_date", "9999.1.1")):
                r = {"type": k, "first": d["first"], "second": d["second"]}
                if "subject_type" in d:
                    r["subject_type"] = d["subject_type"]
                rel.append(r)
        for dte, v in sorted(dated, key=lambda t: t[0]):
            if dte <= cutoff:
                for kk, vv in v:
                    if kk == "emperor" and isinstance(vv, str):
                        emperor = "" if vv == "---" else vv
                    elif kk == "celestial_emperor" and isinstance(vv, str):
                        celestial = "" if vv == "---" else vv
    return rel, emperor, celestial


RECENT_WAR_YEARS = 10


def eu4_wars(root, cutoff):
    """Guerras ativas na data e as que acabaram nos ultimos RECENT_WAR_YEARS anos: nome, inicio e fim,
    objetivo, atacantes e defensores (todos os que participaram ate a data; "active" lista os que ainda
    lutam) e batalhas ate a data."""
    out = []
    since = (cutoff[0] - RECENT_WAR_YEARS, cutoff[1], cutoff[2])
    for fn in sorted(glob.glob(os.path.join(root, "history", "wars", "*.txt"))):
        items = parse_script(read_text(fn))
        dated = sorted(((date_tuple(k), v) for k, v in items if k and DATE_RE.match(k) and isinstance(v, list)),
                       key=lambda t: t[0])
        dated = [(d, v) for d, v in dated if d <= cutoff]
        if not dated:
            continue
        att, de, att_now, de_now, battles = [], [], set(), set(), []
        for d, v in dated:
            for k, x in v:
                if k == "add_attacker" and isinstance(x, str):
                    att_now.add(x)
                    if x not in att:
                        att.append(x)
                elif k == "add_defender" and isinstance(x, str):
                    de_now.add(x)
                    if x not in de:
                        de.append(x)
                elif k == "rem_attacker":
                    att_now.discard(x)
                elif k == "rem_defender":
                    de_now.discard(x)
                elif k == "battle" and isinstance(x, list):
                    b = {"date": "%d.%d.%d" % d}
                    for bk, bv in x:
                        if bk == "name" and isinstance(bv, str):
                            b["name"] = bv
                        elif bk == "location" and isinstance(bv, str) and bv.isdigit():
                            b["location"] = int(bv)
                        elif bk == "result" and isinstance(bv, str):
                            b["attacker_won"] = bv == "yes"
                        elif bk in ("attacker", "defender") and isinstance(bv, list):
                            side = {kk: vv for kk, vv in bv if kk in ("country", "commander") and isinstance(vv, str)}
                            for kk, vv in bv:
                                if kk in ("infantry", "cavalry", "artillery", "losses") and isinstance(vv, str) \
                                        and vv.isdigit():
                                    side[kk] = int(vv)
                            b[bk] = side
                    battles.append(b)
        active = bool(att_now and de_now)
        if not active and dated[-1][0] < since:
            continue
        w = {"name": next((v for k, v in items if k == "name" and isinstance(v, str)), os.path.basename(fn)),
             "start": "%d.%d.%d" % dated[0][0], "end": "" if active else "%d.%d.%d" % dated[-1][0],
             "attackers": att, "defenders": de, "battles": battles}
        if active:
            w["active"] = sorted(att_now) + sorted(de_now)
        goal = next((v for k, v in items if k == "war_goal" and isinstance(v, list)), [])
        g = {k: v for k, v in goal if k in ("type", "casus_belli") and isinstance(v, str)}
        prov = next((v for k, v in goal if k == "province" and isinstance(v, str) and v.isdigit()), None)
        if prov:
            g["province"] = int(prov)
        if g:
            w["war_goal"] = g
        out.append(w)
    return out


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


FLAG_SIZE, FLAGS_PER_ROW = 64, 32


def make_flags(root, countries):
    """Atlas assets/eu4/flags.png com as bandeiras (na ordem dos paises); o pais ganha "flag" = posicao."""
    out = "assets/eu4/flags.png"
    if os.path.isfile(out):
        os.remove(out)
    found = {}
    for d in (os.path.join(root, "gfx", "flags"), os.path.join(root, "flags")):
        if os.path.isdir(d):
            for f in os.listdir(d):
                if re.fullmatch(r"[A-Za-z0-9]{3}\.tga", f):
                    found.setdefault(f[:3].upper(), os.path.join(d, f))
    with_flag = [c for c in countries if c["tag"] in found]
    if not with_flag:
        return
    rows = (len(with_flag) + FLAGS_PER_ROW - 1) // FLAGS_PER_ROW
    atlas = Image.new("RGBA", (FLAGS_PER_ROW * FLAG_SIZE, rows * FLAG_SIZE))
    n = 0
    for c in with_flag:
        try:
            img = Image.open(found[c["tag"]]).convert("RGB").convert("RGBA").resize((FLAG_SIZE, FLAG_SIZE),
                                                                                    Image.LANCZOS)
        except OSError:
            continue
        atlas.paste(img, ((n % FLAGS_PER_ROW) * FLAG_SIZE, (n // FLAGS_PER_ROW) * FLAG_SIZE))
        c["flag"] = n
        n += 1
    atlas.save(out, optimize=True)


ICON_SIZE, ICONS_PER_ROW = 48, 32


def gfx_sprites(root, frames=None):
    """Sprites das interface/*.gfx: nome -> caminho da textura (minusculo, com /); se `frames` for um
    dict, recebe nome -> noOfFrames (quadros da tira)."""
    out = {}
    for fn in sorted(glob.glob(os.path.join(root, "interface", "**", "*.gfx"), recursive=True)):
        def walk(items):
            for k, v in items:
                if isinstance(v, list):
                    d = {kk.lower(): vv for kk, vv in v
                         if kk and kk.lower() in ("name", "texturefile", "noofframes") and isinstance(vv, str)}
                    if "name" in d and "texturefile" in d and d["name"] not in out:
                        out[d["name"]] = re.sub(r"[\\/]+", "/", d["texturefile"]).lower()
                        if frames is not None and "noofframes" in d:
                            frames[d["name"]] = max(1, int(to_num(d["noofframes"])))
                    walk(v)
        walk(parse_script(read_text(fn)))
    return out


def icon_sources(root, trade_goods, religions, institutions, advisor_types, buildings, idea_groups, national):
    """Lista de (chave, caminho relativo, quadro, quadros) dos icones; quadro = indice numa tira (ou -1),
    quadros = total da tira pelo noOfFrames do .gfx (0 = quadros quadrados). Mesma regra do importador do jogo."""
    frames = {}
    sprites = gfx_sprites(root, frames)
    src = []
    for i, g in enumerate(trade_goods):
        src.append(("good:" + g["id"], "gfx/interface/resources.dds", i, 0))
    # religioes: a tira do GFX_icon_religion (mods com mais religioes mudam a textura e o noOfFrames)
    rtex = sprites.get("GFX_icon_religion", "gfx/interface/icon_religion.dds")
    rn = frames.get("GFX_icon_religion", 0)
    for r in religions:
        if "icon" in r and (rn == 0 or r["icon"] <= rn):
            src.append(("religion:" + r["id"], rtex, r["icon"] - 1, rn))
    for inst in institutions:
        src.append(("inst:" + inst["id"], sprites.get("GFX_icon_institution_" + inst["id"],
                                                     "gfx/interface/institutions/%s.dds" % inst["id"]), -1, 0))
    for t in advisor_types:
        src.append(("advisor:" + t["id"], sprites.get("GFX_advisor_" + t["id"],
                                                     "gfx/interface/advisors/%s.tga" % t["id"]), -1, 0))
    for b in buildings:
        if "GFX_" + b["id"] in sprites:
            src.append(("building:" + b["id"], sprites["GFX_" + b["id"]], -1, 0))
    for g in idea_groups:
        src.append(("group:" + g["id"], sprites.get("GFX_idea_" + g["id"], "gfx/interface/ideas/idea_%s.dds" % g["id"]),
                    -1, 0))
    mods = []
    for st in list(idea_groups) + list(national):
        for idea in st["ideas"]:
            first = next(iter(idea["modifiers"]), "")
            if first and first not in mods:
                mods.append(first)
    for m in mods:
        src.append(("mod:" + m, "gfx/interface/ideas_eu4/%s.dds" % m.lower(), -1, 0))
    return src


# texturas da interface usadas no tema do jogo: arquivo de saida -> (origem, lado para reduzir ou 0)
UI_TEXTURES = [("panel", "gfx/interface/tiles_dialog.dds", 0), ("panel_small", "gfx/interface/tiles_dialog.dds", 48),
               ("button", "gfx/interface/button_straight_255_32.dds", 0),
               ("scroll_track", "gfx/interface/scroll_track.dds", 0),
               ("scroll_grabber", "gfx/interface/scroll_drager.dds", 0)]


# telas do EU4 que o jogo monta (scripts/eu4_gui.gd) e sprites extras (botoes dos modos de mapa)
GUI_FILES = ["topbar", "speed_controls", "minimappanel", "provinceview", "countryview", "countrycourtview",
             "countrygovernmentview", "countrytechnologyview", "countryideasview",
             "countryeconomyview", "countryreligionview",
             "macrobuildinterface_override", "macrobuildinterface", "countrydiplomacyview", "countrystabilityview",
             "unitpanel_card", "unitpanel_main", "unitpanel_sub", "peaceview", "frontend"]   # o _override vem antes: as janelas dele valem
GUI_EXTRA_SPRITES = ["GFX_mapmode_political", "GFX_mapmode_terrain", "GFX_mapmode_culture", "GFX_mapmode_religion",
                     "GFX_mapmode_trade_goods", "GFX_mapmode_trade", "GFX_mapmode_areas", "GFX_mapmode_institutions",
                     "GFX_mapmode_diplomatic", "GFX_scroll_up", "GFX_scroll_down", "GFX_scroll_drager",
                     "GFX_scroll_track", "GFX_country_icon_religion",
                     "GFX_diplomacy_alliances", "GFX_diplomacy_royalmarriage", "GFX_diplomacy_leadvassal",
                     "GFX_diplomacy_amvassal", "GFX_diplomacy_leadunions", "GFX_diplomacy_inunion",
                     "GFX_diplomacy_guaranteed", "GFX_diplomacy_guaranting", "GFX_diplomacy_we_increase_relation",
                     "GFX_diplomacy_they_increase_relation", "GFX_diplomacy_war", "GFX_diplomacy_leadmarch",
                     "GFX_diplomacy_action_relation", "GFX_diplomacy_action_alliance", "GFX_diplomacy_action_requestpeace",
                     "GFX_diplomacy_action_dynasty", "GFX_diplomacy_action_influence", "GFX_diplomacy_coalitions"]
# icones de terreno da tela da provincia (GFX_combat_terrain_<terreno do EU4>)
COMBAT_TERRAINS = ["GFX_combat_terrain_" + t for t in (
    "coastal_desert", "coastline", "desert", "desert_mountain", "drylands", "farmlands", "forest", "glacier",
    "grasslands", "highlands", "hills", "jungle", "marsh", "mountain", "ocean", "plains", "savannah",
    "steppe", "woods")]
SPRITE_KINDS = ["spritetype", "frameanimatedspritetype", "textspritetype", "corneredtilespritetype",
                "maskedshieldtype", "progressbartype"]


def load_rgba(path, fix_alpha=True):
    """Imagem RGBA (alfa todo zerado vira opaco, se fix_alpha), ou None."""
    try:
        im = Image.open(path).convert("RGBA")
    except OSError:
        return None
    if fix_alpha and im.getchannel("A").getextrema()[1] == 0:
        im = im.convert("RGB").convert("RGBA")
    return im


def make_gui(root):
    """Telas do EU4 em assets/eu4/gui/: gui.json (arvores dos .gui, sprites e fontes usados), texturas
    em PNG e fontes (.fnt + pagina em PNG). Mesma saida do importador do jogo."""
    import shutil
    out = "assets/eu4/gui"
    if os.path.isdir(out):
        shutil.rmtree(out)
    idir = os.path.join(root, "interface")
    if not os.path.isdir(idir):
        return
    gui_by_low, gfx_files = {}, []
    for d, _, fs in os.walk(idir):
        for f in fs:
            if f.lower().endswith(".gui"):
                gui_by_low.setdefault(f.lower(), os.path.join(d, f))
            elif f.lower().endswith(".gfx"):
                gfx_files.append(os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/"))
    files = {}
    for d, _, fs in os.walk(os.path.join(root, "gfx")):
        if "flags" in os.path.relpath(d, root).replace(os.sep, "/").lower().split("/"):
            continue
        for f in fs:
            full = os.path.join(d, f)
            files.setdefault(os.path.relpath(full, root).replace(os.sep, "/").lower(), full)

    def conv(items):
        return [["" if k is None else k, conv(v) if isinstance(v, list) else v] for k, v in items]

    trees, used, used_fonts = {}, set(), {"tahoma_60"}       # tahoma_60 = fonte dos nomes no mapa (Mapfont)

    def refs(items):
        for k, v in items:
            kl = (k or "").lower()
            if isinstance(v, list):
                refs(v)
            elif kl in ("spritetype", "quadtexturesprite"):
                used.add(v)
            elif kl in ("font", "buttonfont"):
                used_fonts.add(v)

    for g in GUI_FILES:
        p = gui_by_low.get(g + ".gui")
        if p:
            trees[g] = conv(parse_script(read_text(p)))
            refs(trees[g])
    if not trees:
        return
    used.update(GUI_EXTRA_SPRITES + COMBAT_TERRAINS)

    def kv(items):
        d = {}
        for k, v in items:
            if k and k.lower() not in d:
                d[k.lower()] = v
        return d

    defs, font_defs = {}, {}

    def collect(items):
        for k, v in items:
            if not isinstance(v, list):
                continue
            kl = (k or "").lower()
            d = kv(v)
            if kl in SPRITE_KINDS and "name" in d:
                defs.setdefault(d["name"], (kl, d))
            elif kl == "bitmapfont" and "name" in d:
                font_defs.setdefault(d["name"], d)
            else:
                collect(v)

    for rel in sorted(gfx_files):
        collect(parse_script(read_text(os.path.join(root, *rel.split("/")))))
    done = {}

    def texture(path):
        rel = re.sub(r"[\\/]+", "/", path.lower())
        if rel in done:
            return done[rel]
        src = rel if rel in files else re.sub(r"\.(dds|tga)$", lambda m: ".tga" if m.group(1) == "dds" else ".dds", rel)
        res = ""
        if src in files:
            im = load_rgba(files[src], src.endswith(".tga"))   # .dds transparentes de proposito
            if im is not None:
                res = os.path.splitext(rel)[0] + ".png"
                dst = os.path.join(out, *res.split("/"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                im.save(dst)
        done[rel] = res
        return res

    def xy(v):
        if not isinstance(v, list):
            return [0, 0]
        d = kv(v)
        return [int(float(d.get("x", "0") or 0)), int(float(d.get("y", "0") or 0))]

    os.makedirs(out, exist_ok=True)
    sprites = {}
    for n in sorted(used):
        if n not in defs:
            continue
        kind, d = defs[n]
        s = {"kind": kind}
        for key, dst in (("texturefile", "texture"), ("texturefile1", "texture"), ("texturefile2", "texture2")):
            if isinstance(d.get(key), str) and dst not in s:
                t = texture(d[key])
                if t:
                    s[dst] = t
        if "texture" not in s:
            continue
        if "noofframes" in d:
            s["frames"] = max(1, int(float(d["noofframes"])))
        if "bordersize" in d:
            s["border"] = xy(d["bordersize"])
        if "size" in d:
            s["size"] = xy(d["size"])
        sprites[n] = s
    fonts = {}
    for n in sorted(used_fonts):
        fd = font_defs.get(n, {})
        path = str(fd.get("path", "gfx/fonts/" + n)).lower().replace("\\", "/")
        base = path.rsplit("/", 1)[-1]
        fnt = "gfx/fonts/" + base + ".fnt"
        if fnt not in files:
            continue
        page = texture("gfx/fonts/" + base + ".tga")
        if not page:
            continue
        dst = os.path.join(out, *fnt.split("/"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(files[fnt], "rb") as fi, open(dst, "wb") as fo:
            fo.write(fi.read())
        fonts[n] = {"fnt": fnt, "page": page, "color": str(fd.get("color", "0xffffffff")).lower()}
    with open(os.path.join(out, "gui.json"), "w", encoding="utf-8") as f:
        json.dump({"files": trees, "sprites": sprites, "fonts": fonts}, f, ensure_ascii=False)


def make_ui(root):
    """Molduras/botoes do EU4 em assets/eu4/ui/ (o jogo monta um tema com elas)."""
    out = "assets/eu4/ui"
    for name, _, _ in UI_TEXTURES:
        if os.path.isfile(os.path.join(out, name + ".png")):
            os.remove(os.path.join(out, name + ".png"))
    for name, rel, side in UI_TEXTURES:
        path = None
        for cand in (rel, rel[:-4] + ".tga"):
            p = os.path.join(root, *cand.split("/"))
            if os.path.isfile(p):
                path = p
                break
        if path is None:
            continue
        try:
            im = Image.open(path).convert("RGBA")
        except OSError:
            continue
        if side:
            im = im.resize((side, side), Image.LANCZOS)
        os.makedirs(out, exist_ok=True)
        im.save(os.path.join(out, name + ".png"), optimize=True)


def make_icons(root, trade_goods, religions, institutions, advisor_types, buildings, idea_groups, national):
    """Atlas assets/eu4/icons.png (ICON_SIZE px) e o dicionario chave -> posicao."""
    out = "assets/eu4/icons.png"
    if os.path.isfile(out):
        os.remove(out)
    files = {}
    gdir = os.path.join(root, "gfx", "interface")
    if not os.path.isdir(gdir):
        return {}
    for d, _, fs in os.walk(gdir):
        for f in fs:
            full = os.path.join(d, f)
            files[os.path.relpath(full, root).replace(os.sep, "/").lower()] = full
    cells, index, cache = [], {}, {}
    for key, rel, frame, nframes in icon_sources(root, trade_goods, religions, institutions, advisor_types, buildings,
                                        idea_groups, national):
        rel = rel.lower()
        if rel not in files:     # .dds <-> .tga
            alt = re.sub(r"\.(dds|tga)$", lambda m: ".tga" if m.group(1) == "dds" else ".dds", rel)
            if alt not in files:
                continue
            rel = alt
        if rel not in cache:
            try:
                im = Image.open(files[rel]).convert("RGBA")
            except OSError:
                cache[rel] = None
                continue
            if im.getchannel("A").getextrema()[1] == 0:      # alfa todo zerado: trata como opaco
                im = im.convert("RGB").convert("RGBA")
            cache[rel] = im
        im = cache[rel]
        if im is None:
            continue
        if frame >= 0:
            fw = im.width // nframes if nframes > 0 else im.height
            if fw <= 0 or (frame + 1) * fw > im.width:
                continue
            im = im.crop((frame * fw, 0, (frame + 1) * fw, im.height))
        index[key] = len(cells)
        cells.append(im.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS))
    if not cells:
        return {}
    rows = (len(cells) + ICONS_PER_ROW - 1) // ICONS_PER_ROW
    atlas = Image.new("RGBA", (ICONS_PER_ROW * ICON_SIZE, rows * ICON_SIZE))
    for i, im in enumerate(cells):
        atlas.paste(im, ((i % ICONS_PER_ROW) * ICON_SIZE, (i // ICONS_PER_ROW) * ICON_SIZE))
    atlas.save(out, optimize=True)
    return index


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


def pretty_key(key, suffix=""):
    """"ile_de_france_area" -> "Ile De France" (mesma regra do importador do jogo)."""
    if suffix and key.endswith(suffix):
        key = key[:-len(suffix)]
    return " ".join(w[:1].upper() + w[1:] for w in key.split("_") if w)


def eu4_terrain(root, ids, n_prov):
    """Terreno do proprio EU4: terrain_override do terrain.txt > arvores (trees.bmp, >= 30% da
    provincia) > terreno mais comum no terrain.bmp (sem contar agua). Amostra a cada 2 px.
    Retorna ({id: rotulo em portugues}, lista de terrenos com custo de movimento etc.)."""
    tp, bp = os.path.join(root, "map", "terrain.txt"), os.path.join(root, "map", "terrain.bmp")
    if not (os.path.isfile(tp) and os.path.isfile(bp)):
        return {}, []
    with open("data/geografia_pt.json", encoding="utf-8") as f:
        pt = json.load(f)["terrenos"]
    top = dict((k, v) for k, v in parse_script(read_text(tp)) if k)
    terrains, override, water, seen = [], {}, set(), set()
    for cat, items in top.get("categories", []):
        if not isinstance(items, list) or cat == "pti":
            continue
        t = {"id": pt.get(cat, cat), "eu4": cat}
        for k, v in items:
            if k in ("movement_cost", "defence", "supply_limit", "local_development_cost") and isinstance(v, str):
                try:
                    t[k] = float(v)
                except ValueError:
                    pass
            elif k == "is_water" and v == "yes":
                water.add(cat)
            elif k == "terrain_override" and isinstance(v, list):
                for kk, x in v:
                    if kk is None and x.isdigit():
                        override.setdefault(int(x), cat)
        if t["id"] not in seen and cat not in water:
            seen.add(t["id"])
            terrains.append(t)
    idx_type = {}
    for name, items in top.get("terrain", []):
        if isinstance(items, list):
            typ = next((v for k, v in items if k == "type"), None)
            col = next((v for k, v in items if k == "color" and isinstance(v, list)), [])
            for kk, x in col:
                if kk is None and x.isdigit() and typ:
                    idx_type[int(x)] = typ
    tree_type = {}
    for name, items in top.get("tree", []):
        if isinstance(items, list):
            typ = next((v for k, v in items if k == "terrain"), None)
            col = next((v for k, v in items if k == "color" and isinstance(v, list)), [])
            for kk, x in col:
                if kk is None and x.isdigit() and typ in ("forest", "woods", "jungle"):
                    tree_type[int(x)] = typ
    H, W = ids.shape
    sid = ids[::2, ::2].ravel().astype(np.int64)
    tb = np.asarray(Image.open(bp))[::2, ::2].ravel()
    counts = np.zeros((n_prov, 256), np.int64)
    np.add.at(counts, (sid, tb.astype(np.int64)), 1)
    cats = sorted(set(idx_type.values()))
    total = np.bincount(sid, minlength=n_prov)
    tree_frac = {}
    trp = os.path.join(root, "map", "trees.bmp")
    if os.path.isfile(trp) and tree_type:
        tr = np.asarray(Image.open(trp))
        th, tw = tr.shape
        yy = (np.arange(0, H, 2) * th // H)[:, None]
        xx = (np.arange(0, W, 2) * tw // W)[None, :]
        tv = tr[yy, xx].ravel()
        for typ in set(tree_type.values()):
            m = np.isin(tv, [i for i, t in tree_type.items() if t == typ])
            tree_frac[typ] = np.bincount(sid, weights=m, minlength=n_prov) / np.maximum(total, 1)
    out = {}
    for pid in range(1, n_prov):
        cat = override.get(pid)
        if cat is None and tree_frac:
            best = max(sorted(tree_frac), key=lambda t: tree_frac[t][pid])
            if tree_frac[best][pid] >= 0.3:
                cat = best
        if cat is None:
            score = {}
            for i in np.nonzero(counts[pid])[0]:
                typ = idx_type.get(int(i))
                if typ and typ not in water:
                    score[typ] = score.get(typ, 0) + int(counts[pid, i])
            if score:
                cat = max(sorted(score), key=lambda t: score[t])
        if cat and cat not in water:
            out[pid] = pt.get(cat, cat)
    return out, terrains


def eu4_geography(root, loc=None):
    """Areas, regioes, super-regioes e continentes (map/area.txt etc.)."""
    with open("data/geografia_pt.json", encoding="utf-8") as f:
        pt = json.load(f)
    g = {"areas": [], "regions": [], "superregions": [], "continents": [],
         "area_of": {}, "region_of": {}, "superregion_of": {}, "continent_of": {}}

    def blocks(name):
        path = os.path.join(root, "map", name)
        return [(k, v) for k, v in parse_script(read_text(path)) if k and isinstance(v, list)] \
            if os.path.isfile(path) else []
    region_of_area, super_of_region = {}, {}
    for sname, items in blocks("superregion.txt"):
        if sname == "new_world_superregion":
            continue
        g["superregions"].append({"id": sname, "name": pt["superregioes"].get(sname) or pretty_key(sname, "_superregion")})
        for kk, x in items:
            if kk is None:
                super_of_region.setdefault(x, sname)
    for rname, items in blocks("region.txt"):
        if rname == "random_new_world_region":
            continue
        g["regions"].append({"id": rname, "name": pt["regioes"].get(rname) or (loc or {}).get(rname)
                             or pretty_key(rname, "_region"),
                             "superregion": super_of_region.get(rname, "")})
        for k, v in items:
            if k == "areas" and isinstance(v, list):
                for kk, x in v:
                    if kk is None:
                        region_of_area.setdefault(x, rname)
    for aname, items in blocks("area.txt"):
        reg = region_of_area.get(aname, "")
        base = hashed_color(reg or aname)
        hh, ss, vv = colorsys.rgb_to_hsv(*(v / 255 for v in base))
        k = hashlib.md5(aname.encode()).digest()
        col = [int(c * 255) for c in colorsys.hsv_to_rgb((hh + (k[0] - 128) / 2600) % 1.0,
               min(1, max(0.3, ss + (k[1] - 128) / 900)), min(1, max(0.4, vv + (k[2] - 128) / 700)))]
        g["areas"].append({"id": aname, "name": (loc or {}).get(aname) or pretty_key(aname, "_area"), "region": reg,
                           "color": col})
        for kk, x in items:
            if kk is None and x.isdigit():
                pid = int(x)
                g["area_of"].setdefault(pid, aname)
                if reg:
                    g["region_of"].setdefault(pid, reg)
                    if super_of_region.get(reg):
                        g["superregion_of"].setdefault(pid, super_of_region[reg])
    for cname, items in blocks("continent.txt"):
        if cname in ("island_check_provinces", "new_world"):
            continue
        g["continents"].append({"id": cname, "name": pt["continentes"].get(cname) or pretty_key(cname)})
        for kk, x in items:
            if kk is None and x.isdigit():
                g["continent_of"].setdefault(int(x), cname)
    return g


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

    # localizacao em ingles (todos os arquivos; a primeira definicao de cada chave vale, como no jogo)
    loc = {}
    for f in find_loc(root, "*_l_english.yml"):
        for m in re.finditer(r'^\s*([A-Za-z0-9_]+):\d*\s+"(.*)"\s*$', read_text(f), re.M):
            loc.setdefault(m.group(1), m.group(2))

    # a localizacao inteira vai para data/eu4/loc.txt (o jogo usa nos nomes e nas telas)
    os.makedirs("data/eu4", exist_ok=True)
    with open("data/eu4/loc.txt", "w", encoding="utf-8") as lf:
        for k in sorted(loc):
            lf.write("%s\t%s\n" % (k, loc[k].replace("\t", " ")))

    # nomes de provincias (localizacao em ingles)
    prov_names = {int(k[4:]): v for k, v in loc.items() if re.fullmatch(r"PROV\d+", k)}

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
    terrain_of, terrains = eu4_terrain(root, ids, n_prov)
    rp = os.path.join(root, "map", "rivers.bmp")
    river_vec = []
    if os.path.isfile(rp):
        riv = Image.open(rp)
        if riv.mode == "P" and riv.size == (W, H):
            # indice da paleta do rivers.bmp (< 254 = rio; 254 = terra, 255 = mar), o shader le direto
            Image.fromarray(np.asarray(riv, dtype=np.uint8), "L").save("assets/eu4/rivers.png", optimize=True)
            print("Rios em linhas...", flush=True)
            river_vec = river_lines(np.asarray(riv, dtype=np.uint8))
    del ids
    print("Texturas do mapa (relevo, altitude, terreno)...", flush=True)
    map_tex = map_textures(root, W, H, "assets/eu4")

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
    hre = set()             # provincias do Sacro Imperio em 1444
    cot = {}            # centro de comercio (nivel)
    culture = {}
    religion = {}
    cores = {}              # pid -> nucleos (quando ha algum de outro pais que nao o dono)
    claims = {}             # pid -> reivindicacoes
    for f in glob.glob(os.path.join(root, "history", "provinces", "*.txt")):
        m = re.match(r"\s*(\d+)", os.path.basename(f))
        if not m:
            continue
        pid = int(m.group(1))
        if pid not in defs:
            continue
        items = parse_script(read_text(f))
        st = state_at(items, cutoff)
        co, cl = core_claims(items, cutoff)
        if co:
            cores[pid] = co
        if cl:
            claims[pid] = cl
        o = st.get("owner")
        if isinstance(o, str) and o:
            owner[pid] = o
        if st.get("hre") == "yes":
            hre.add(pid)
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
    names = {k: v for k, v in loc.items() if re.fullmatch(r"[A-Z0-9]{3}", k)}

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
        hist = {}
        for hf in sorted(glob.glob(os.path.join(root, "history", "countries", tag + "*.txt"))):
            if not re.match(re.escape(tag) + r"\s*-", os.path.basename(hf)):
                continue
            hist = country_history(parse_script(read_text(hf)), cutoff)
            c = hist.pop("capital", "")
            if c.isdigit() and int(c) in defs:
                capital = int(c)
            break
        countries.append({"tag": tag, "name": names.get(tag, tag), "color": color, "capital": capital, **hist})

    # tipos de governo (common/governments)
    with open("data/governos_pt.json", encoding="utf-8") as f:
        gov_pt = json.load(f)["governos"]
    governments = []
    for gf in sorted(glob.glob(os.path.join(root, "common", "governments", "*.txt"))):
        for gname, gval in parse_script(read_text(gf)):
            if isinstance(gval, list) and any(k == "reform_levels" for k, _ in gval):
                governments.append({"id": gname, "name": gov_pt.get(gname) or pretty_key(gname)})

    # ---------------------------------------------------------- culturas
    groups = {}
    for cf in glob.glob(os.path.join(root, "common", "cultures", "*.txt")):
        for gname, gval in parse_script(read_text(cf)):
            if isinstance(gval, list):
                for cname, cval in gval:
                    if isinstance(cval, list) and cname not in ("graphical_culture", "male_names",
                                                                "female_names", "dynasty_names"):
                        groups[cname] = gname
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

    religions, seen, rel_group = [], set(), {}
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
                rel_group[rname] = gname
                rel = {"id": rname, "name": nice(rname), "group": nice(gname), "color": [int(v) for v in vals[:3]]}
                icon = next((to_num(v) for k, v in rval if k == "icon" and to_num(v) is not None), None)
                if icon is not None:
                    rel["icon"] = int(icon)
                cm = next((v for k, v in rval if k == "country" and isinstance(v, list)), None)
                if cm:      # efeitos da religiao no pais (so os numericos)
                    mods = {}
                    for k, v in cm:
                        if k and k not in mods and to_num(v) is not None:
                            mods[k] = to_num(v)
                    if mods:
                        rel["modifiers"] = mods
                religions.append(rel)
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

    geo = eu4_geography(root, loc)
    technologies, tech_groups = eu4_technologies(root, {b["id"] for b in buildings}, loc)
    units = eu4_units(root, technologies, loc)
    adjacencies = []
    ap_ = os.path.join(root, "map", "adjacencies.csv")
    if os.path.isfile(ap_):
        for line in read_text(ap_).splitlines():
            q = line.split(";")
            if len(q) >= 4 and q[0].isdigit() and q[1].isdigit():
                adjacencies.append({"from": int(q[0]), "to": int(q[1]), "type": q[2],
                                    "through": int(q[3]) if q[3].lstrip("-").isdigit() else -1})

    # ---------------------------------------------------------- ideias (common/ideas)
    idea_groups, national_ideas = eu4_ideas(root, countries, groups, rel_group, loc)
    advisor_types, advisors = eu4_advisors(root, defs)
    centers_of_trade, trade_rules = eu4_trade(root, loc)
    opinion_modifiers = eu4_opinions(root)
    casus_belli, war_goals = eu4_casus_belli(root)
    diplomacy_data = eu4_diplomacy_data(root)
    inst_raw = eu4_institutions(root, cutoff)
    diplomacy, emperor, celestial = eu4_diplomacy(root, cutoff)
    wars = eu4_wars(root, cutoff)
    used_tags = {c["tag"] for c in countries}
    diplomacy = [r for r in diplomacy if r["first"] in used_tags and r["second"] in used_tags]
    emperor = emperor if emperor in used_tags else ""
    celestial = celestial if celestial in used_tags else ""
    institutions = [i for i, _ in inst_raw]
    country_of = {c["tag"]: c for c in countries}

    # ---------------------------------------------------------- bandeiras (gfx/flags/TAG.tga)
    make_flags(root, countries)
    make_ui(root)
    make_gui(root)
    icons = make_icons(root, trade_goods, religions, institutions, advisor_types, buildings, idea_groups,
                       national_ideas)

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
            "terrain": "mar" if sea else (terrain_of.get(pid) if pid in terrain_of and "impassable"
                                            not in climates.get(pid, ()) else classify_terrain(pid, h_mean, h_std, climates)),
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
            if pid in hre:
                prov["hre"] = True
            if any(t != owner.get(pid) for t in cores.get(pid, [])):
                prov["cores"] = cores[pid]
            if pid in claims:
                prov["claims"] = claims[pid]
            prov["base_tax"], prov["base_production"], prov["base_manpower"] = dev_parts.get(pid, (0, 0, 0))
            prov["coastal"] = any(q in sea_ids for q in neigh[pid])
            prov["base_development"] = prov["development"]
        if pid in node_of:
            prov["trade_node"] = node_of[pid]
        for k, d in (("area", geo["area_of"]), ("region", geo["region_of"]), ("superregion", geo["superregion_of"]),
                     ("continent", geo["continent_of"])):
            if pid in d:
                prov[k] = d[pid]
        if not sea and inst_raw:
            pctx = dict(prov, culture_group=groups.get(prov.get("culture", ""), ""))
            owner_c = country_of.get(prov["owner"])
            have = [i["id"] for i, h in inst_raw
                    if h is not None and all(eval_province(a, b, pctx, owner_c, cutoff[0]) for a, b in h if a)]
            if have:
                prov["institutions"] = have
        provinces.append(prov)

    with open("data/eu4/map.json", "w", encoding="utf-8") as f:
        json.dump({"width": W, "height": H, "countries": countries, "cultures": cultures,
                   "religions": religions, "trade_goods": trade_goods, "trade_nodes": trade_nodes,
                   "buildings": buildings, "terrains": terrains, "areas": geo["areas"], "regions": geo["regions"],
                   "superregions": geo["superregions"], "continents": geo["continents"],
                   "adjacencies": adjacencies, "governments": governments,
                   "technologies": technologies, "tech_groups": tech_groups, "units": units,
                   "idea_groups": idea_groups, "national_ideas": national_ideas,
                   "advisor_types": advisor_types, "advisors": advisors,
                   "centers_of_trade": centers_of_trade, "trade_rules": trade_rules,
                   "opinion_modifiers": opinion_modifiers, "casus_belli": casus_belli, "war_goals": war_goals,
                   "diplomacy_data": diplomacy_data, "map_textures": map_tex, "rivers": river_vec,
                   "institutions": institutions, "diplomacy": diplomacy, "emperor": emperor,
                   "celestial_emperor": celestial, "wars": wars, "icons": icons, "provinces": provinces},
                  f, ensure_ascii=False, separators=(",", ":"))

    print("Gravando todos os scripts do EU4 (data/eu4/eu4data)...", flush=True)
    index = eu4_all_data(root, "data/eu4")
    print("  %d pastas, %d arquivos" % (len(index), sum(index.values())), flush=True)

    n_own = sum(1 for p in provinces if p["owner"])
    print(f"\nOK: mapa {W}x{H}, {len(defs)} provincias ({len(sea_ids)} de mar/lagos), "
          f"{len(countries)} paises, {n_own} provincias com dono em {args.data}")
    print("Abra o projeto no Godot: ele usa data/eu4/ e assets/eu4/ automaticamente.")
    print("Para voltar ao mapa de exemplo, apague as pastas data/eu4 e assets/eu4.")


if __name__ == "__main__":
    main()
