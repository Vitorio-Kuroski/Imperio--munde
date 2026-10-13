extends Node2D
## Cena principal: câmera, interface e ligação entre mapa e relógio.

const MAP_SCALE := 1.0
const CAM_SPEED := 900.0
var zoom_min := 0.25
const ZOOM_MAX := 8.0

var map: MapView
var clock := GameClock.new()
var camera: Camera2D
var player_tag := ""

# UI
var ui: CanvasLayer
var top_bar: PanelContainer
var country_label: Label
var date_label: Label
var speed_label: Label
var pause_button: Button
var mode_button: Button
var side_panel: PanelContainer
var info_label: Label
var tooltip: MapTooltip
var start_panel: CenterContainer


func _ready() -> void:
	map = MapView.new()
	add_child(map)
	map.load_map(MAP_SCALE)

	camera = Camera2D.new()
	add_child(camera)
	camera.position = Vector2(map.map_w, map.map_h) * MAP_SCALE * 0.5
	# Zoom que enquadra o mapa inteiro na janela (serve para qualquer tamanho de mapa)
	var vp := get_viewport_rect().size
	var fit: float = minf(vp.x / (map.map_w * MAP_SCALE), vp.y / (map.map_h * MAP_SCALE))
	zoom_min = fit * 0.9
	camera.zoom = Vector2(fit, fit)
	camera.make_current()

	_build_ui()
	clock.changed.connect(_refresh_top_bar)
	clock.month_passed.connect(_on_month_passed)
	_refresh_top_bar()


# ------------------------------------------------------------------ interface
func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)

	# Barra superior
	top_bar = PanelContainer.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	ui.add_child(top_bar)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	top_bar.add_child(hb)

	country_label = Label.new()
	country_label.custom_minimum_size.x = 340
	hb.add_child(country_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	mode_button = Button.new()
	mode_button.tooltip_text = "Modo de mapa: político, terreno, cultura (T)"
	mode_button.pressed.connect(_toggle_map_mode)
	hb.add_child(mode_button)

	date_label = Label.new()
	date_label.custom_minimum_size.x = 130
	hb.add_child(date_label)

	pause_button = Button.new()
	pause_button.text = "▶"
	pause_button.custom_minimum_size.x = 40
	pause_button.pressed.connect(clock.toggle_pause)
	hb.add_child(pause_button)

	var slower := Button.new()
	slower.text = "−"
	slower.pressed.connect(func(): clock.set_speed(clock.speed - 1))
	hb.add_child(slower)

	speed_label = Label.new()
	speed_label.custom_minimum_size.x = 70
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hb.add_child(speed_label)

	var faster := Button.new()
	faster.text = "+"
	faster.pressed.connect(func(): clock.set_speed(clock.speed + 1))
	hb.add_child(faster)

	# Painel lateral (informações da província)
	side_panel = PanelContainer.new()
	side_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	side_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	side_panel.offset_left = 12
	side_panel.offset_bottom = -12
	side_panel.custom_minimum_size = Vector2(300, 150)
	ui.add_child(side_panel)
	info_label = Label.new()
	info_label.text = "Clique em uma província."
	side_panel.add_child(info_label)
	side_panel.hide()

	# Tela de escolha de país
	start_panel = CenterContainer.new()
	start_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(start_panel)
	var box := PanelContainer.new()
	start_panel.add_child(box)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	box.add_child(outer)
	var title := Label.new()
	title.text = "Imperium Mundi — escolha seu país"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 520)
	outer.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 4)
	scroll.add_child(vb)
	# Países ordenados do maior para o menor número de províncias
	var counts := {}
	for p in map.provinces:
		if p["owner"] != "":
			counts[p["owner"]] = int(counts.get(p["owner"], 0)) + 1
	var tags: Array = map.countries.keys()
	tags.sort_custom(func(a, b): return int(counts.get(a, 0)) > int(counts.get(b, 0)))
	for tag in tags:
		var c: Dictionary = map.countries[tag]
		var b := Button.new()
		b.text = "%s  (%d prov.)" % [c["name"], int(counts.get(tag, 0))]
		b.custom_minimum_size = Vector2(340, 32)
		b.pressed.connect(_start_game.bind(tag))
		vb.add_child(b)

	# Dica do mapa (criada por último para ficar por cima)
	tooltip = MapTooltip.new()
	ui.add_child(tooltip)


func _start_game(tag: String) -> void:
	player_tag = tag
	start_panel.hide()
	var cap: int = int(map.countries[tag]["capital"])
	camera.position = map.province_center(cap)
	camera.zoom = Vector2(1.2, 1.2)
	map.select(cap)
	_show_province(cap)
	_refresh_top_bar()


func _refresh_top_bar() -> void:
	if player_tag != "":
		var mine := map.provinces_of(player_tag)
		var dev := 0
		for p in mine:
			dev += int(p["development"])
		country_label.text = "%s — %d prov., desenv. %d" % [map.countries[player_tag]["name"], mine.size(), dev]
	else:
		country_label.text = ""
	date_label.text = clock.date_text()
	pause_button.text = "▶" if clock.paused else "⏸"
	speed_label.text = "Vel. %d/5" % clock.speed
	mode_button.text = "Mapa: %s" % MapView.MAP_MODE_NAMES[map.map_mode]


## Alterna político -> terreno -> cultura -> político.
func _toggle_map_mode() -> void:
	map.set_map_mode(((map.map_mode + 1) % MapView.MAP_MODE_NAMES.size()) as MapView.MapMode)
	_refresh_top_bar()
	if map.selected_id >= 0:
		_show_province(map.selected_id)


func _show_province(pid: int) -> void:
	if pid < 0:
		side_panel.hide()
		return
	var p: Dictionary = map.provinces[pid]
	var txt := "%s\n" % p["name"]
	if p["sea"]:
		txt += "Águas navegáveis"
	else:
		var owner_name := "Sem dono"
		if p["owner"] != "":
			owner_name = "%s (%s)" % [map.countries[p["owner"]]["name"], p["owner"]]
		txt += "Dono: %s\nTerreno: %s\nDesenvolvimento: %d" % [owner_name, p["terrain"], p["development"]]
		var cid: String = p.get("culture", "")
		if map.cultures.has(cid):
			var grp: String = map.cultures[cid]["group"]
			txt += "\nCultura: %s" % map.cultures[cid]["name"] + (" (%s)" % grp if grp != "" else "")
		if p.get("coastal", false):
			txt += "\nCosteira"
	info_label.text = txt
	side_panel.show()


func _on_month_passed() -> void:
	# Gancho para a economia, eventos mensais, IA etc.
	pass


# ------------------------------------------------------------------ loop e entrada
func _process(delta: float) -> void:
	clock.process(delta)
	_update_tooltip()

	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1
	if dir != Vector2.ZERO:
		camera.position += dir.normalized() * CAM_SPEED * delta / camera.zoom.x
		_clamp_camera()


func _update_tooltip() -> void:
	var m := get_viewport().get_mouse_position()
	var over_ui := start_panel.visible or top_bar.get_global_rect().has_point(m) \
			or (side_panel.visible and side_panel.get_global_rect().has_point(m))
	tooltip.update_for(map, -1 if over_ui else map.province_at_mouse(), m)


func _clamp_camera() -> void:
	var size := Vector2(map.map_w, map.map_h) * MAP_SCALE
	camera.position = camera.position.clamp(Vector2.ZERO, size)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if player_tag != "":
					var pid := map.province_at_mouse()
					map.select(pid)
					_show_province(pid)
			MOUSE_BUTTON_WHEEL_UP:
				camera.zoom = (camera.zoom * 1.12).clamp(Vector2(zoom_min, zoom_min), Vector2(ZOOM_MAX, ZOOM_MAX))
			MOUSE_BUTTON_WHEEL_DOWN:
				camera.zoom = (camera.zoom / 1.12).clamp(Vector2(zoom_min, zoom_min), Vector2(ZOOM_MAX, ZOOM_MAX))
	elif event is InputEventScreenDrag and event.index == 0:
		# celular: arrastar com um dedo move o mapa
		camera.position -= event.relative / camera.zoom
		_clamp_camera()
	elif event is InputEventMagnifyGesture:
		# celular: pinçar com dois dedos dá zoom
		camera.zoom = (camera.zoom * event.factor).clamp(Vector2(zoom_min, zoom_min), Vector2(ZOOM_MAX, ZOOM_MAX))
	elif event is InputEventMouseMotion:
		if event.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE):
			camera.position -= event.relative / camera.zoom
			_clamp_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_T:
				_toggle_map_mode()
			KEY_SPACE:
				if player_tag != "":
					clock.toggle_pause()
			KEY_EQUAL, KEY_KP_ADD:
				clock.set_speed(clock.speed + 1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				clock.set_speed(clock.speed - 1)
