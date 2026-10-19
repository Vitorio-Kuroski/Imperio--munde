class_name ArmyLayer
extends Node2D
## Marcadores dos exércitos no mapa (filho do MapView, coordenadas em pixels do mapa), como os do
## EU4: caixa com a bandeira do país e o tamanho ("8k"), embaixo do centro da província; vários na
## mesma província ficam empilhados. Exército em marcha aparece entre as duas províncias. O
## selecionado tem borda dourada e o caminho com a seta e os dias até chegar.
## Guerra: exércitos inimigos do jogador com borda vermelha, em retirada meio apagados; batalha
## com espadas cruzadas sobre a província; cerco com a barra da fase embaixo do marcador; província
## ocupada com a bandeira de quem a controla no centro.
## Tamanho constante na tela (redesenha quando o zoom muda).

const BOX := Vector2(58, 18)       # na tela
const FLAG := Vector2(24, 16)
const GAP := 3.0

var map: MapView
var army: Army
var war: War
var combat: Combat
var siege: Siege
var discovery: Discovery           # névoa de guerra: exércitos de fora escondidos
var selected := -1
var _zoom := -1.0
var _font: Font
var _rects := {}                   # id -> Rect2 (mapa) do último desenho, para o clique


func setup(m: MapView, a: Army) -> void:
	map = m
	army = a
	_font = ThemeDB.fallback_font
	army.moved.connect(queue_redraw)
	army.changed.connect(func(_t): queue_redraw())
	z_index = 5


func _process(_d: float) -> void:
	var cam := get_viewport().get_camera_2d()
	if cam and not is_equal_approx(cam.zoom.x, _zoom):
		_zoom = cam.zoom.x
		queue_redraw()


## Exército sob o ponto (coordenadas do mapa), ou −1.
func army_at(p: Vector2) -> int:
	var best := -1
	for id in _rects:
		if (_rects[id] as Rect2).has_point(p):
			best = id
			if id == selected:
				return id
	return best


func _center(pid: int) -> Vector2:
	var c: Array = map.provinces[pid]["center"]
	return Vector2(c[0], c[1])


## Posição do exército (entre a província atual e a próxima, se estiver em marcha).
func _pos(a: Dictionary) -> Vector2:
	var p := _center(int(a["loc"]))
	if not a["path"].is_empty() and int(a["need"]) > 0:
		var q := _center(int(a["path"][0]))
		if absf(q.x - p.x) < map.map_w * 0.5:
			p = p.lerp(q, clampf(float(a["days"]) / float(a["need"]), 0.0, 1.0))
	return p


func _draw() -> void:
	_rects.clear()
	if army == null:
		return
	var z := maxf(_zoom, 0.01)
	var s := 1.0 / z                  # px do mapa por px da tela
	var box := BOX * s
	var vis := get_viewport_rect()
	var cam := get_viewport().get_camera_2d()
	var view := Rect2(cam.get_screen_center_position() - vis.size * 0.5 * s, vis.size * s).grow(box.x) if cam else Rect2()
	# empilha por província
	var stacks := {}
	var share := discovery.sharers(army.power.player) if discovery and discovery.enabled and army.power else {}
	for a in army.armies.values():
		if not share.is_empty() and not share.has(a["tag"]) and not discovery.visible_to_player(int(a["loc"])) 				and (a["path"].is_empty() or not discovery.visible_to_player(int(a["path"][0]))):
			continue                  # sob a névoa de guerra
		var key := int(a["loc"]) if a["path"].is_empty() else -int(a["id"])
		if not stacks.has(key):
			stacks[key] = []
		stacks[key].append(a)
	# caminho do selecionado (por baixo dos marcadores)
	var sel: Dictionary = army.armies.get(selected, {})
	if not sel.is_empty() and not sel["path"].is_empty():
		var pts := PackedVector2Array([_pos(sel)])
		for pid in sel["path"]:
			var c := _center(int(pid))
			if absf(c.x - pts[pts.size() - 1].x) > map.map_w * 0.5:
				break
			pts.append(c)
		draw_polyline(pts, Color(0.1, 0.1, 0.1, 0.7), 4.0 * s, true)
		draw_polyline(pts, Color(0.35, 0.85, 0.35), 2.2 * s, true)
		if pts.size() >= 2:
			var e := pts[pts.size() - 1]
			var dir := (e - pts[pts.size() - 2]).normalized()
			var n := Vector2(-dir.y, dir.x)
			draw_colored_polygon(PackedVector2Array([e + dir * 4 * s, e - dir * 7 * s + n * 5 * s, e - dir * 7 * s - n * 5 * s]),
					Color(0.35, 0.85, 0.35))
			draw_set_transform(e + Vector2(6, -6) * s, 0.0, Vector2(s, s))
			draw_string_outline(_font, Vector2.ZERO, Loc.s("%d dias", "%d days") % army.eta(sel), HORIZONTAL_ALIGNMENT_LEFT,
					-1, 14, 4, Color(0, 0, 0, 0.8))
			draw_string(_font, Vector2.ZERO, Loc.s("%d dias", "%d days") % army.eta(sel), HORIZONTAL_ALIGNMENT_LEFT,
					-1, 14, Color.WHITE)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# províncias ocupadas: bandeira de quem controla
	if war:
		for pid in war.controller:
			var c := _center(int(pid))
			var fr := Rect2(c + Vector2(-9, -20) * s, Vector2(18, 12) * s)
			if cam and not view.intersects(fr):
				continue
			var fl := map.flag_texture(war.controller[pid])
			draw_rect(fr.grow(1.0 * s), Color(0.9, 0.2, 0.15))
			if fl:
				draw_texture_rect(fl, fr, false)
	for key in stacks:
		var list: Array = stacks[key]
		var base := _pos(list[0]) + Vector2(-box.x * 0.5, 4.0 * s)
		for i in list.size():
			var a: Dictionary = list[i]
			var r := Rect2(base + Vector2(0, (box.y + GAP * s) * i), box)
			if cam and not view.intersects(r):
				continue
			_rects[int(a["id"])] = r
			_counter(a, r, s, int(a["id"]) == selected)
		if key >= 0:
			var bottom := base + Vector2(0, (box.y + GAP * s) * list.size())
			if siege and siege.sieges.has(key):          # barra da fase do cerco
				var bar := Rect2(bottom, Vector2(box.x, 4.0 * s))
				draw_rect(bar, Color(0.1, 0.1, 0.1, 0.9))
				draw_rect(Rect2(bar.position, Vector2(box.x * siege.phase_progress(key), bar.size.y)), Color(0.95, 0.75, 0.2))
			if combat and combat.battles.has(key):        # espadas cruzadas
				var c := base + Vector2(box.x * 0.5, -10.0 * s)
				for d in [Vector2(-1, -1), Vector2(1, -1)]:
					draw_line(c - d * 7 * s, c + d * 7 * s, Color(0.05, 0.05, 0.05), 4.0 * s)
					draw_line(c - d * 7 * s, c + d * 7 * s, Color(0.95, 0.85, 0.6), 2.0 * s)


func _counter(a: Dictionary, r: Rect2, s: float, sel: bool) -> void:
	var mine: bool = army.power != null and a["tag"] == army.power.player
	var enemy: bool = war != null and army.power != null and war.hostile(army.power.player, a["tag"])
	var fade := 0.55 if a.get("retreat", false) else 1.0
	draw_rect(r, Color(0.08, 0.08, 0.1, 0.88 * fade))
	var border := Color(1.0, 0.82, 0.3) if sel else (Color(0.55, 0.85, 0.5) if mine else \
			(Color(0.95, 0.25, 0.2) if enemy else Color(0.55, 0.55, 0.6)))
	draw_rect(r, border, false, (2.0 if sel or enemy else 1.0) * s)
	var fl := map.flag_texture(a["tag"])
	var fr := Rect2(r.position + Vector2(1, 1) * s, FLAG * s)
	if fl:
		draw_texture_rect(fl, fr, false)
	else:
		var c: Variant = map.countries.get(a["tag"], {}).get("color", null)
		draw_rect(fr, Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0) if c is Array else Color.GRAY)
	var txt := Manpower.fmt(army.strength(a))
	var fs := 13
	var tw := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	# texto desenhado em pixels da tela: escala o transform para s
	draw_set_transform(r.position + Vector2(FLAG.x + 4, 0) * s, 0.0, Vector2(s, s))
	draw_string(_font, Vector2((BOX.x - FLAG.x - 6 - tw) * 0.5, 14), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
