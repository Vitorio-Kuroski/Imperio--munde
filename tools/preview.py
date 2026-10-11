#!/usr/bin/env python3
"""Gera uma previa politica do mapa (imita o shader do jogo).

Uso: python3 tools/preview.py saida.png [largura]   (a partir da pasta do projeto)
"""
import json
import sys

import numpy as np
from PIL import Image

out_path = sys.argv[1] if len(sys.argv) > 1 else "preview.png"
out_w = int(sys.argv[2]) if len(sys.argv) > 2 else 1024

d = json.load(open("data/map.json", encoding="utf-8"))
P = d["provinces"]
N = len(P)
im = np.array(Image.open("assets/province_ids.png").convert("RGB")).astype(np.int64)
ids = im[..., 0] + im[..., 1] * 256
tag_idx = {c["tag"]: i + 1 for i, c in enumerate(d["countries"])}
pal = {c["tag"]: c["color"] for c in d["countries"]}
colr = np.zeros((N, 3), np.uint8)
own = np.zeros(N, int)
sea = np.zeros(N, bool)
for p in P:
    sea[p["id"]] = p["sea"]
    own[p["id"]] = tag_idx.get(p["owner"], 0)
    colr[p["id"]] = (40, 77, 117) if p["sea"] else pal.get(p["owner"], (115, 110, 97))
img = colr[ids].astype(np.float32)
e = np.zeros(ids.shape, np.float32)
for dy, dx in ((0, 1), (1, 0)):
    a = ids[:ids.shape[0] - dy, :ids.shape[1] - dx]
    b = ids[dy:, dx:]
    sa, sb = sea[a], sea[b]
    v = np.where(sa & sb, 0.0, np.where(sa != sb, 0.75, np.where(own[a] != own[b], 0.75, 0.22)))
    v = np.where(a != b, v, 0.0)
    sl = (slice(0, ids.shape[0] - dy), slice(0, ids.shape[1] - dx))
    e[sl] = np.maximum(e[sl], v)
img = img * (1 - e[..., None]) + 10 * e[..., None]
out = Image.fromarray(img.astype(np.uint8))
h = int(out.height * out_w / out.width)
out.resize((out_w, h), Image.LANCZOS).save(out_path)
print("ok", out_path)
