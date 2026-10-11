#!/usr/bin/env python3
"""Converte um mapa de cores unicas (assets/provinces.png) em assets/province_ids.png.

Use depois de editar/desenhar seu proprio provinces.png e de registrar cada
cor em data/map.json (campo "color" de cada provincia, com "id" sequencial 0..N-1).

Uso: python3 tools/colors_to_ids.py
"""
import json

import numpy as np
from PIL import Image

data = json.load(open("data/map.json", encoding="utf-8"))
img = np.array(Image.open("assets/provinces.png").convert("RGB"))
h, w, _ = img.shape
key = (img[..., 0].astype(np.int64) << 16) | (img[..., 1].astype(np.int64) << 8) | img[..., 2]

ids = np.full((h, w), -1, dtype=np.int64)
for p in data["provinces"]:
    r, g, b = p["color"]
    ids[key == ((r << 16) | (g << 8) | b)] = p["id"]

missing = int((ids < 0).sum())
if missing:
    raise SystemExit(f"{missing} pixels com cor que nao esta no map.json")

out = np.zeros((h, w, 3), dtype=np.uint8)
out[..., 0] = ids & 255
out[..., 1] = ids >> 8
Image.fromarray(out, "RGB").save("assets/province_ids.png", optimize=True)
print(f"ok: {w}x{h}, {len(data['provinces'])} provincias")
