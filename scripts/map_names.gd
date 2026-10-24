class_name MapNames
extends Node2D
## Nomes escritos no mapa, como no EU4 (filho do MapView, desenhado sobre as províncias):
##  - Países: o EU4 não guarda onde escrever o nome; ele calcula pela forma do território, e aqui
##    também: na maior parte contínua das terras do país (províncias vizinhas do mesmo dono), os
##    pixels amostrados (`STEP`) dão o eixo principal (PCA) e uma curva de 2º grau ajustada ao longo
##    dele; o nome em maiúsculas é espalhado por ~80% do comprimento, com letras do tamanho que cabe
##    na largura do território. Refeito quando um dono muda (`MapView.owner_version`).
##  - Províncias: posição e rotação do texto do map/positions.txt do EU4 (3º par de `position`,
##    3º valor de `rotation`; y de baixo para cima), tamanho pela área da província; sem o arquivo,
##    o centro da província.
##  - Fonte do EU4 `tahoma_60` (Mapfont, Trajan Pro, cor 0x333333 do core.gfx), com mipmaps; sem
##    ela, a fonte padrão.
##  - Zoom (`MapCamera.height`): países a partir de COUNTRY_FROM de altura, províncias até
##    PROVINCE_NAME_DRAW_DISTANCE (500, defines.lua NGraphics), com transição; só os nomes na tela
##    e com letras de pelo menos MIN_SCREEN_PX são desenhados.

const STEP := 6                    # amostragem dos pixels do mapa (1 a cada STEP × STEP)
const MIN_SCREEN_PX := 7.0
const MAX_SCREEN_PX := 160.0
const COUNTRY_FROM := 420.0        # altura em que os nomes dos países começam a aparecer
const FADE := 120.0
const FILL := 0.8                  # parte do comprimento do território ocupada pelo nome

var map: MapView
var camera: MapCamera
var font: Font
var font_size := 64
var color := Color8(0x33, 0x33, 0x33)
var countries := []                # [{tag, text, chars [[letra, pos, ângulo]], size (px do mapa), rect}]
var provinces := []                # [{text, pos, angle, size}]
var _samples := {}                 # pid -> PackedVector2Array (pixels amostrados)
var _version := -1
var _last_xform := Transform2D()
var _last_h := -1.0
var _pending := 0.0


func setup(m: MapView, cam: MapCamera, gui: Eu4Gui) -> void:
	map = m
	camera = cam
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_load_font(gui)
	_sample_pixels()
	_province_names()
	_country_names()


func _load_font(gui: Eu4Gui) -> void:
	if gui and gui.font_defs.has("tahoma_60"):
		var fd: Dictionary = gui.font_defs["tahoma_60"]
		var full: String = gui.dir + "/" + fd["fnt"]
		var page := gui.image(fd["page"])
		if page and FileAccess.file_exists(full):
			page = page.duplicate()
			page.generate_mipmaps()
			var f := gui._bitmap_font(FileAccess.get_file_as_bytes(full).get_string_from_ascii(), page)
			if not f.is_empty():
				font = f[0]
				font_size = f[1]
				var c := str(fd.get("color", "")).trim_prefix("0x")
				if c.length() == 8 and c.is_valid_hex_number():
					var v := c.hex_to_int()
					color = Color8((v >> 16) & 255, (v >> 8) & 255, v & 255)
	if font == null:
		font = ThemeDB.fallback_font
		font_size = 64


## Pixels amostrados de cada província (para a forma dos países).
func _sample_pixels() -> void:
	var img := map.id_image
	if img == null:
		return
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var bpp := data.size() / (w * h)
	if bpp < 2:
		return
	var tmp := {}
	for y in range(STEP / 2, h, STEP):
		var row := y * w * bpp
		for x in range(STEP / 2, w, STEP):
			var i := row + x * bpp
			var pid := data[i] + data[i + 1] * 256
			if not tmp.has(pid):
				tmp[pid] = PackedVector2Array()
			tmp[pid].append(Vector2(x, y))
	_samples = tmp


func _process(delta: float) -> void:
	if map == null:
		return
	if map.owner_version != _version:
		_pending += delta
		if _pending > 0.5 or _version < 0:           # trocas de dono em sequência: refaz uma vez
			_pending = 0.0
			_country_names()
	var xf := get_canvas_transform()
	if xf != _last_xform or camera.height != _last_h:
		_last_xform = xf
		_last_h = camera.height
		queue_redraw()


# ------------------------------------------------------------------ países
func _country_names() -> void:
	_version = map.owner_version
	countries.clear()
	var by_owner := {}
	for p in map.provinces:
		if p["sea"] or p["owner"] == "":
			continue
		if not by_owner.has(p["owner"]):
			by_owner[p["owner"]] = []
		by_owner[p["owner"]].append(int(p["id"]))
	for tag in by_owner:
		var comp := _largest_component(tag, by_owner[tag])
		var pts := PackedVector2Array()
		for pid in comp:
			pts.append_array(_samples.get(pid, PackedVector2Array([map.province_center(pid)])))
		var lay := _layout(str(map.countries.get(tag, {}).get("name", tag)).to_upper(), pts)
		if not lay.is_empty():
			lay["tag"] = tag
			countries.append(lay)
	queue_redraw()


func _largest_component(tag: String, pids: Array) -> Array:
	var seen := {}
	var best := []
	var best_n := -1
	for start in pids:
		if seen.has(start):
			continue
		var comp := [start]
		seen[start] = true
		var i := 0
		while i < comp.size():
			for n in map.provinces[comp[i]].get("neighbors", []):
				var nid := int(n)
				if not seen.has(nid) and nid < map.provinces.size() and map.provinces[nid]["owner"] == tag:
					seen[nid] = true
					comp.append(nid)
			i += 1
		var size := 0
		for pid in comp:
			size += _samples.get(pid, PackedVector2Array()).size()
		if size > best_n:
			best_n = size
			best = comp
	return best


## Nome espalhado por uma curva de 2º grau ao longo do eixo principal dos pontos.
func _layout(text: String, pts: PackedVector2Array) -> Dictionary:
	var n := pts.size()
	if n < 3 or text.strip_edges() == "":
		return {}
	var m := Vector2.ZERO
	for p in pts:
		m += p
	m /= n
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	for p in pts:
		var d := p - m
		sxx += d.x * d.x
		syy += d.y * d.y
		sxy += d.x * d.y
	var ang := 0.5 * atan2(2.0 * sxy, sxx - syy)
	var u := Vector2(cos(ang), sin(ang))
	if u.x < 0.0:
		u = -u
	var v := Vector2(-u.y, u.x)
	# coordenadas no eixo (t) e de lado (s); mínimos quadrados de s = a t² + b t + c
	var ts := PackedFloat32Array()
	ts.resize(n)
	var s0 := 0.0; var s1 := 0.0; var s2 := 0.0; var s3 := 0.0; var s4 := 0.0
	var r0 := 0.0; var r1 := 0.0; var r2 := 0.0
	for i in n:
		var d := pts[i] - m
		var t := d.dot(u)
		var s := d.dot(v)
		ts[i] = t
		var t2 := t * t
		s0 += 1.0; s1 += t; s2 += t2; s3 += t2 * t; s4 += t2 * t2
		r0 += s; r1 += s * t; r2 += s * t2
	var sorted := ts.duplicate()
	sorted.sort()
	var t_lo := sorted[int(n * 0.04)]
	var t_hi := sorted[int(n * 0.96) - 1] if n > 25 else sorted[n - 1]
	var length := t_hi - t_lo
	if length <= 1.0:
		return {}
	var abc := _solve3([[s4, s3, s2, r2], [s3, s2, s1, r1], [s2, s1, s0, r0]])
	var a: float = abc[0]
	var b: float = abc[1]
	var c: float = abc[2]
	# curvatura limitada (o EU4 curva pouco): flecha de no máximo 15% do comprimento
	var sag := absf(a) * length * length / 4.0
	if sag > 0.15 * length:
		var k := 0.15 * length / sag
		a *= k
	# largura: espalhamento dos pontos em volta da curva
	var res := 0.0
	for i in n:
		var t: float = ts[i]
		var s := (pts[i] - m).dot(v) - (a * t * t + b * t + c)
		res += s * s
	var thick := sqrt(res / n) * 2.2
	# tamanho das letras: cabe na largura e o nome cabe no comprimento
	var adv := 0.0
	for ch in text:
		adv += font.get_char_size(ch.unicode_at(0), font_size).x
	if adv <= 0.0:
		return {}
	var size := minf(thick * 0.55, length * FILL / adv * font_size)
	if size < 2.0:
		return {}
	var scale := size / font_size
	# letras espalhadas: o resto do comprimento vira espaço entre elas
	var total := length * FILL
	var gaps := maxf(1.0, text.length() - 1)
	var extra := maxf(0.0, (total - adv * scale) / gaps)
	extra = minf(extra, size * 1.2)
	var used := adv * scale + extra * gaps
	# posições pela distância ao longo da curva
	var curve := func(t: float) -> Vector2:
		return m + u * t + v * (a * t * t + b * t + c)
	var mid := (t_lo + t_hi) * 0.5
	var table := []                 # [t, distância acumulada]
	var steps := 64
	var acc := 0.0
	var prev: Vector2 = curve.call(t_lo)
	table.append([t_lo, 0.0])
	for i in range(1, steps + 1):
		var t := t_lo + length * i / steps
		var p: Vector2 = curve.call(t)
		acc += p.distance_to(prev)
		prev = p
		table.append([t, acc])
	var start := (acc - used) * 0.5
	var chars := []
	var dist := start
	var rect := Rect2(curve.call(mid), Vector2.ZERO)
	for ch in text:
		var w := font.get_char_size(ch.unicode_at(0), font_size).x * scale
		var tc := _t_at(table, dist + w * 0.5)
		var pos: Vector2 = curve.call(tc)
		var deriv := u + v * (2.0 * a * tc + b)
		chars.append([ch, pos, deriv.angle(), w])
		rect = rect.expand(pos)
		dist += w + extra
	return {"text": text, "chars": chars, "size": size, "rect": rect.grow(size)}


static func _t_at(table: Array, d: float) -> float:
	for i in range(1, table.size()):
		if table[i][1] >= d:
			var a: Array = table[i - 1]
			var b: Array = table[i]
			var f: float = (d - a[1]) / maxf(0.0001, b[1] - a[1])
			return lerpf(a[0], b[0], f)
	return table[-1][0]


## Sistema 3×3 (eliminação de Gauss); [0, 0, média] se for singular.
static func _solve3(mx: Array) -> Array:
	for col in 3:
		var piv := col
		for r in range(col + 1, 3):
			if absf(mx[r][col]) > absf(mx[piv][col]):
				piv = r
		if absf(mx[piv][col]) < 1e-9:
			return [0.0, 0.0, mx[2][3] / maxf(1.0, mx[2][2])]
		var tmp: Array = mx[col]
		mx[col] = mx[piv]
		mx[piv] = tmp
		for r in 3:
			if r != col:
				var f: float = mx[r][col] / mx[col][col]
				for k in range(col, 4):
					mx[r][k] -= f * mx[col][k]
	return [mx[0][3] / mx[0][0], mx[1][3] / mx[1][1], mx[2][3] / mx[2][2]]


# ------------------------------------------------------------------ províncias
func _province_names() -> void:
	provinces.clear()
	var pos := {}
	var tree: Array = Eu4Data.folder("map").get("positions", [])
	for kv in tree:
		if not (kv[1] is Array) or not str(kv[0]).is_valid_int():
			continue
		var p := []
		var r := []
		for x in kv[1]:
			if x[0] == "position" and x[1] is Array:
				for y in x[1]:
					p.append(float(str(y[1])))
			elif x[0] == "rotation" and x[1] is Array:
				for y in x[1]:
					r.append(float(str(y[1])))
		if p.size() >= 6:
			pos[int(kv[0])] = [Vector2(p[4], map.map_h - p[5]), -r[2] if r.size() >= 3 else 0.0]
	for p in map.provinces:
		if p["sea"]:
			continue
		var pid := int(p["id"])
		var text := str(p.get("name", ""))
		if text == "":
			continue
		var at: Array = pos.get(pid, [map.province_center(pid), 0.0])
		var area := float(_samples.get(pid, PackedVector2Array()).size() * STEP * STEP)
		var adv := 0.0
		for ch in text:
			adv += font.get_char_size(ch.unicode_at(0), font_size).x
		# a largura do nome fica perto da largura da província (raiz da área)
		var size := clampf(sqrt(maxf(area, 16.0)) * 0.8 / maxf(1.0, adv) * font_size, 2.2, 4.5)
		provinces.append({"text": text, "pos": at[0], "angle": at[1], "size": size, "adv": adv})


# ------------------------------------------------------------------ desenho
func _draw() -> void:
	if map == null or camera == null:
		return
	var h := camera.height
	var view := Rect2(camera.screen_to_world(Vector2.ZERO), get_viewport_rect().size / camera.zoom.x)
	var z := camera.zoom.x
	var ca := clampf((h - COUNTRY_FROM) / FADE, 0.0, 1.0)
	var pd := float(Eu4Data.define("NGraphics", "PROVINCE_NAME_DRAW_DISTANCE", 500.0))
	var pa := clampf((pd - h) / FADE, 0.0, 1.0)
	if ca > 0.0:
		var col := Color(color, 0.85 * ca)
		for c in countries:
			var px: float = c["size"] * z
			if px < MIN_SCREEN_PX or px > MAX_SCREEN_PX or not view.intersects(c["rect"]):
				continue
			var k: float = c["size"] / font_size
			for ch in c["chars"]:
				draw_set_transform(ch[1], ch[2], Vector2(k, k))
				draw_char(font, Vector2(-ch[3] * 0.5 / k, font_size * 0.35), ch[0], font_size, col)
	if pa > 0.0:
		var col := Color(color, 0.9 * pa)
		for p in provinces:
			var px: float = p["size"] * z
			if px < MIN_SCREEN_PX or not view.has_point(p["pos"]):
				continue
			var k: float = p["size"] / font_size
			draw_set_transform(p["pos"], p["angle"], Vector2(k, k))
			draw_string(font, Vector2(-p["adv"] * 0.5, font_size * 0.35), p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1,
					font_size, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
