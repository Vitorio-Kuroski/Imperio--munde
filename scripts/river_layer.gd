class_name RiverLayer
extends Node2D
## Rios desenhados como curvas finas, como no EU4 (filho do MapView, sobre as províncias): as linhas
## que os importadores tiram do rivers.bmp (`map.rivers`: [largura, x0, y0, ...] em pixels) são
## suavizadas (médias móveis e um passo de Chaikin, sem mexer nas pontas) e desenhadas com
## antisserrilhado; a largura vem do índice do rivers.bmp (3 = mais fino ... 11 = mais largo, `WIDTH`
## em pixels do mapa), no mínimo `MIN_PX` na tela. Com elas o shader não pinta os pixels dos rios.

const COLOR := Color(0.24, 0.45, 0.78, 0.9)
const WIDTH := {3: 0.18, 4: 0.24, 5: 0.3, 6: 0.36, 7: 0.42, 8: 0.48, 9: 0.55, 10: 0.62, 11: 0.7}
const MIN_PX := 1.0

var camera: MapCamera
var lines := []                    # [{pts: PackedVector2Array, w: float, rect: Rect2}]
var _last_xform := Transform2D()


func setup(m: MapView, cam: MapCamera) -> void:
	camera = cam
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	for l in m.river_lines:
		var raw := PackedVector2Array()
		for i in range(1, l.size() - 1, 2):
			raw.append(Vector2(float(l[i]) + 0.5, float(l[i + 1]) + 0.5))
		if raw.size() < 2:
			continue
		var pts := _chaikin(_smooth(_smooth(raw)))
		var r := Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			r = r.expand(p)
		lines.append({"pts": pts, "w": float(WIDTH.get(int(l[0]), 0.18)), "rect": r.grow(2.0)})


## Média móvel de 3 pontos (as pontas ficam onde estão: ligam com outros rios e com o mar).
static func _smooth(p: PackedVector2Array) -> PackedVector2Array:
	if p.size() < 3:
		return p
	var out := PackedVector2Array([p[0]])
	for i in range(1, p.size() - 1):
		out.append((p[i - 1] + p[i] * 2.0 + p[i + 1]) * 0.25)
	out.append(p[p.size() - 1])
	return out


static func _chaikin(p: PackedVector2Array) -> PackedVector2Array:
	if p.size() < 3:
		return p
	var out := PackedVector2Array([p[0]])
	for i in p.size() - 1:
		out.append(p[i].lerp(p[i + 1], 0.25))
		out.append(p[i].lerp(p[i + 1], 0.75))
	out.append(p[p.size() - 1])
	return out


func _process(_d: float) -> void:
	var xf := get_canvas_transform()
	if xf != _last_xform:
		_last_xform = xf
		queue_redraw()


func _draw() -> void:
	if camera == null:
		return
	var z := camera.zoom.x
	var view := Rect2(camera.screen_to_world(Vector2.ZERO), get_viewport_rect().size / z)
	for l in lines:
		if view.intersects(l["rect"]):
			draw_polyline(l["pts"], COLOR, maxf(float(l["w"]), MIN_PX / z), true)
