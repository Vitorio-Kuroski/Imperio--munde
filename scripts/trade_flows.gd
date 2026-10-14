class_name TradeFlows
extends Node2D
## Setas do modo de mapa "comércio": para onde o comércio corre entre os nós (rota pelas
## províncias do `path` de cada saída) e um círculo na sede de cada nó.
## Fica dentro do MapView (coordenadas em pixels do mapa) e se redesenha quando o zoom muda,
## para a espessura na tela ficar constante.

const LINE_PX := 2.2        # espessura na tela
const ARROW_PX := 9.0
const NODE_PX := 5.0

var map: MapView
var _routes: Array = []     # [PackedVector2Array] já suavizadas
var _nodes: Array = []      # [[Vector2, Color]]
var _zoom := -1.0


func setup(m: MapView) -> void:
	map = m
	_routes.clear()
	_nodes.clear()
	var loc_of := {}
	for nid in map.trade_nodes:
		var n: Dictionary = map.trade_nodes[nid]
		var loc := int(n.get("location", 0))
		if loc > 0 and loc < map.provinces.size():
			loc_of[nid] = loc
			_nodes.append([_center(loc), map.trade_node_color(nid)])
	for nid in loc_of:
		for o in map.trade_nodes[nid].get("outgoing", []):
			if not loc_of.has(o["to"]):
				continue
			var pts := PackedVector2Array([_center(loc_of[nid])])
			for pid in o.get("path", []):
				if int(pid) < map.provinces.size():
					pts.append(_center(int(pid)))
			pts.append(_center(loc_of[o["to"]]))
			# quebra a rota onde ela atravessaria o mapa inteiro (volta ao mundo pelo Pacífico)
			var piece := PackedVector2Array()
			for p in pts:
				if piece.size() > 0 and absf(p.x - piece[piece.size() - 1].x) > map.map_w * 0.5:
					if piece.size() > 1:
						_routes.append([_smooth(piece), false])
					piece = PackedVector2Array()
				if piece.is_empty() or p.distance_to(piece[piece.size() - 1]) > 0.5:
					piece.append(p)
			if piece.size() > 1:
				_routes.append([_smooth(piece), true])
	queue_redraw()


func _center(pid: int) -> Vector2:
	var c: Array = map.provinces[pid]["center"]
	return Vector2(c[0], c[1])


## Curva Catmull-Rom passando pelos pontos (rotas sem quinas).
func _smooth(p: PackedVector2Array) -> PackedVector2Array:
	if p.size() < 3:
		return p
	var out := PackedVector2Array()
	for i in p.size() - 1:
		var p0 := p[maxi(i - 1, 0)]
		var p1 := p[i]
		var p2 := p[i + 1]
		var p3 := p[mini(i + 2, p.size() - 1)]
		for k in 8:
			var t := k / 8.0
			var t2 := t * t
			var t3 := t2 * t
			out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
					+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	out.append(p[p.size() - 1])
	return out


func _process(_delta: float) -> void:
	if not visible:
		return
	var cam := get_viewport().get_camera_2d()
	var z := cam.zoom.x * global_scale.x if cam else 1.0
	if not is_equal_approx(z, _zoom):
		_zoom = z
		queue_redraw()


func _draw() -> void:
	if _zoom <= 0.0:
		return
	var px := 1.0 / _zoom          # 1 pixel da tela em pixels do mapa
	var dark := Color(0.05, 0.05, 0.08, 0.85)
	var light := Color(1.0, 0.97, 0.85, 0.95)
	for r in _routes:
		var pts: PackedVector2Array = r[0]
		draw_polyline(pts, dark, (LINE_PX + 2.0) * px, true)
		draw_polyline(pts, light, LINE_PX * px, true)
		if r[1]:
			_arrow(pts, px, dark, light)
	for n in _nodes:
		draw_circle(n[0], (NODE_PX + 1.5) * px, dark)
		draw_circle(n[0], NODE_PX * px, n[1])


## Ponta de seta no fim da rota, recuada para não cobrir o círculo do nó de destino.
func _arrow(pts: PackedVector2Array, px: float, dark: Color, light: Color) -> void:
	var tip := pts[pts.size() - 1]
	var back := (NODE_PX + 2.0) * px
	var i := pts.size() - 2
	while i > 0 and pts[i].distance_to(tip) < back + ARROW_PX * px:
		i -= 1
	var dir := (tip - pts[i]).normalized()
	if dir == Vector2.ZERO:
		return
	tip -= dir * back
	var side := dir.orthogonal() * ARROW_PX * 0.55 * px
	var base := tip - dir * ARROW_PX * px
	draw_colored_polygon(PackedVector2Array([tip + dir * px * 1.5, base + side * 1.35 - dir * px,
			base - side * 1.35 - dir * px]), dark)
	draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), light)
