extends Node2D
## Cena principal: câmera, interface e ligação entre mapa e relógio.

const MAP_SCALE := 1.0
const CAM_SPEED := 900.0
var zoom_min := 0.25
const ZOOM_MAX := 8.0

var map: MapView
var clock := GameClock.new()
var power := MonarchPower.new()
var economy := Economy.new()
var advisors := Advisors.new()
var institutions := Institutions.new()
var diplomacy := Diplomacy.new()
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
var country_panel: CountryPanel
var tech_window: TechWindow
var ideas_window: IdeasWindow
var advisors_window: AdvisorsWindow
var start_panel: CenterContainer
var eu4_status: Label
var eu4_buttons: Array[Button] = []
var importer: Eu4Importer
var import_thread: Thread


func _ready() -> void:
	map = MapView.new()
	add_child(map)
	map.load_map(MAP_SCALE)
	power.setup(map, clock)
	power.advisors = advisors
	economy.setup(map, clock, power, advisors)
	advisors.setup(map, clock, power, economy)
	institutions.setup(map, clock, power, economy)
	power.institutions = institutions
	map.inst_view = institutions
	diplomacy.setup(map)
	map.diplo_view = diplomacy

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
	country_label.custom_minimum_size.x = 640
	hb.add_child(country_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	mode_button = Button.new()
	mode_button.tooltip_text = "Modo de mapa: político, terreno, cultura, religião, produtos, comércio, regiões, instituições, diplomacia (T)"
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
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.custom_minimum_size.x = 340
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
	_build_eu4_box(outer)
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

	# Painel do país (dono da província selecionada ou o país do jogador)
	country_panel = CountryPanel.new()
	ui.add_child(country_panel)
	tech_window = TechWindow.new()
	tech_window.power = power
	ui.add_child(tech_window)
	country_panel.power = power
	ideas_window = IdeasWindow.new()
	ideas_window.power = power
	ui.add_child(ideas_window)
	country_panel.ideas_requested.connect(func(t: String):
		tech_window.hide()
		ideas_window.show_for(map, t))
	advisors_window = AdvisorsWindow.new()
	advisors_window.advisors = advisors
	advisors_window.economy = economy
	advisors_window.fmt = ideas_window.fmt_mods
	ui.add_child(advisors_window)
	country_panel.economy = economy
	country_panel.advisors = advisors
	country_panel.advisors_requested.connect(func(t: String):
		tech_window.hide()
		ideas_window.hide()
		advisors_window.show_for(map, t))
	var refresh_all := func(_t):
		country_panel.refresh()
		tech_window.refresh()
		ideas_window.refresh()
		advisors_window.refresh()
		_refresh_top_bar()
	power.changed.connect(refresh_all)
	country_panel.institutions = institutions
	country_panel.diplomacy = diplomacy
	country_panel.shown.connect(func(t: String):
		if map.diplo_focus != t:
			map.diplo_focus = t
			if map.map_mode == MapView.MapMode.DIPLOMACIA:
				map.refresh_colors())
	institutions.changed.connect(func(_t):
		if map.map_mode == MapView.MapMode.INSTITUICOES:
			map.refresh_colors()
		refresh_all.call(_t))
	economy.changed.connect(refresh_all)
	advisors.changed.connect(func(t):
		if t == player_tag:
			refresh_all.call(t))
	country_panel.techs_requested.connect(func(t: String):
		if ideas_window:
			ideas_window.hide()
		tech_window.show_for(map, t))

	# Dica do mapa (criada por último para ficar por cima)
	tooltip = MapTooltip.new()
	ui.add_child(tooltip)


# ------------------------------------------------------------------ mapa do EU4 (opcional)
## Botões da tela inicial para importar o mapa e os donos de 1444 dos arquivos do EU4 do jogador.
func _build_eu4_box(parent: VBoxContainer) -> void:
	var using_eu4 := map.source.begins_with(Eu4Importer.OUT_DIR)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	eu4_status = Label.new()
	eu4_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	eu4_status.custom_minimum_size.x = 380
	eu4_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eu4_status.add_theme_font_size_override("font_size", 13)
	eu4_status.text = "Usando o mapa importado do EU4." if using_eu4 \
			else "Tem o Europa Universalis IV? Carregue o mapa dele (pasta do jogo ou .zip com map/, history/, common/)."
	box.add_child(eu4_status)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 6)
	box.add_child(hb)
	var b_dir := Button.new()
	b_dir.text = "Pasta do EU4..."
	b_dir.pressed.connect(_open_eu4_dialog.bind(true))
	hb.add_child(b_dir)
	var b_zip := Button.new()
	b_zip.text = "Arquivos .zip..."
	b_zip.pressed.connect(_open_eu4_dialog.bind(false))
	hb.add_child(b_zip)
	eu4_buttons = [b_dir, b_zip]
	if Eu4Importer.has_import():
		var b_def := Button.new()
		b_def.text = "Mapa padrão"
		b_def.tooltip_text = "Apaga o mapa importado do EU4 e volta ao mapa do jogo"
		b_def.pressed.connect(func():
			Eu4Importer.remove_import()
			get_tree().reload_current_scene())
		hb.add_child(b_def)
		eu4_buttons.append(b_def)


func _open_eu4_dialog(folder: bool) -> void:
	if OS.get_name() == "Android":
		# precisa de acesso aos arquivos do aparelho (o Android pergunta ao jogador)
		OS.request_permissions()
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = false
	if folder:
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		dlg.title = "Escolha a pasta do Europa Universalis IV"
	else:
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES
		dlg.title = "Escolha os .zip com map/, history/ e common/ do EU4"
		dlg.filters = PackedStringArray(["*.zip ; Arquivos zip"])
	dlg.current_dir = _guess_eu4_dir(folder)
	dlg.size = Vector2i(get_viewport_rect().size * 0.8)
	dlg.dir_selected.connect(func(d: String): _import_eu4(PackedStringArray([d])))
	dlg.files_selected.connect(_import_eu4)
	dlg.visibility_changed.connect(func(): if not dlg.visible: dlg.queue_free())
	ui.add_child(dlg)
	dlg.popup_centered()


## Pasta inicial do diálogo: instalação comum do EU4 na Steam, senão Downloads.
func _guess_eu4_dir(folder: bool) -> String:
	if folder:
		var home := OS.get_environment("HOME")
		for d in ["C:/Program Files (x86)/Steam/steamapps/common/Europa Universalis IV",
				"C:/Program Files/Steam/steamapps/common/Europa Universalis IV",
				home + "/.steam/steam/steamapps/common/Europa Universalis IV",
				home + "/.local/share/Steam/steamapps/common/Europa Universalis IV",
				home + "/Library/Application Support/Steam/steamapps/common/Europa Universalis IV"]:
			if DirAccess.dir_exists_absolute(d):
				return d.get_base_dir()
	return OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)


func _import_eu4(paths: PackedStringArray) -> void:
	if import_thread != null:
		return
	importer = Eu4Importer.new()
	var found := 0
	for p in paths:
		found += importer.add_source(p)
	if found == 0:
		eu4_status.text = "Não achei arquivos do EU4 aí. Escolha a pasta do jogo (a que tem map/, history/ e common/) ou os .zip."
		importer = null
		return
	for b in eu4_buttons:
		b.disabled = true
	eu4_status.text = "Importando..."
	import_thread = Thread.new()
	import_thread.start(importer.run)


## Acompanha a importação (chamado todo quadro). Retorna true quando a cena vai ser recarregada.
func _poll_import() -> bool:
	if import_thread == null:
		return false
	if not importer.done:
		eu4_status.text = importer.get_status()
		return false
	import_thread.wait_to_finish()
	import_thread = null
	if importer.error != "":
		eu4_status.text = importer.error
		for b in eu4_buttons:
			b.disabled = false
		return false
	get_tree().reload_current_scene()      # recarrega com o mapa novo
	return true


func _start_game(tag: String) -> void:
	player_tag = tag
	power.player = tag
	tech_window.player = tag
	ideas_window.player = tag
	advisors_window.player = tag
	start_panel.hide()
	var cap: int = int(map.countries[tag]["capital"])
	camera.position = map.province_center(cap)
	camera.zoom = Vector2(1.2, 1.2)
	map.select(cap)
	_show_province(cap)
	country_panel.show_country(map, tag)
	_refresh_top_bar()


func _refresh_top_bar() -> void:
	if player_tag != "":
		var mine := map.provinces_of(player_tag)
		var dev := 0
		for p in mine:
			dev += int(p["development"])
		country_label.text = "%s — %d prov., desenv. %d   %s ducados (%s)   ADM %d · DIP %d · MIL %d" % [
				map.countries[player_tag]["name"], mine.size(), dev, AdvisorsWindow._n(economy.money(player_tag)),
				AdvisorsWindow._n(economy.balance(player_tag), true), power.points(player_tag, "adm"),
				power.points(player_tag, "dip"), power.points(player_tag, "mil")]
	else:
		country_label.text = ""
	date_label.text = clock.date_text()
	pause_button.text = "▶" if clock.paused else "⏸"
	speed_label.text = "Vel. %d/5" % clock.speed
	mode_button.text = "Mapa: %s" % MapView.MAP_MODE_NAMES[map.map_mode]


## Alterna político -> terreno -> cultura -> religião -> produtos -> comércio -> regiões -> político (pula os modos sem dados no mapa).
func _toggle_map_mode() -> void:
	var mode := map.map_mode
	for i in MapView.MAP_MODE_NAMES.size():
		mode = ((mode + 1) % MapView.MAP_MODE_NAMES.size()) as MapView.MapMode
		if map.has_map_mode(mode):
			break
	map.set_map_mode(mode)
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
		txt += "Dono: %s\nTerreno: %s%s\nDesenvolvimento: %d" % [owner_name, p["terrain"], _terrain_info(p["terrain"]),
				p["development"]]
		if p.has("base_tax"):
			txt += "\n   imposto %d · produção %d · efetivo %d" % [p["base_tax"], p["base_production"], p["base_manpower"]]
		var gid: String = p.get("trade_goods", "")
		if map.trade_goods.has(gid):
			txt += "\nProduto: %s (preço %s)" % [map.trade_goods[gid]["name"], _num(map.trade_goods[gid]["price"])]
		var nid: String = p.get("trade_node", "")
		if map.trade_nodes.has(nid):
			txt += "\nNó de comércio: %s" % map.trade_nodes[nid]["name"]
		if int(p.get("center_of_trade", 0)) > 0:
			txt += "\nCentro de comércio nível %d" % int(p["center_of_trade"])
		for bid in p.get("buildings", []):
			if map.buildings.has(bid):
				var eff := map.building_effects(bid)
				txt += "\nConstrução: %s" % map.buildings[bid]["name"] + (" (%s)" % eff if eff != "" else "")
		var cid: String = p.get("culture", "")
		if map.cultures.has(cid):
			var grp: String = map.cultures[cid]["group"]
			txt += "\nCultura: %s" % map.cultures[cid]["name"] + (" (%s)" % grp if grp != "" else "")
		var rid: String = p.get("religion", "")
		if map.religions.has(rid):
			var rgrp: String = map.religions[rid]["group"]
			txt += "\nReligião: %s" % map.religions[rid]["name"] + (" (%s)" % rgrp if rgrp != "" else "")
		if p.get("coastal", false):
			txt += "\nCosteira"
		if p.get("hre", false):
			txt += "\nSacro Império Romano"
		for b in diplomacy.battles_at(pid):
			var att: Dictionary = b.get("attacker", {})
			var de: Dictionary = b.get("defender", {})
			var winner: Dictionary = att if b.get("attacker_won", false) else de
			txt += "\nBatalha de %s (%s): %s × %s, vitória de %s" % [b.get("name", "?"), CountryPanel._fmt_date(b["date"]),
					_cname(att.get("country", "")), _cname(de.get("country", "")), _cname(winner.get("country", ""))]
	if institutions.enabled() and not p["sea"]:
		var have := []
		for inst in institutions.list:
			var pr := institutions.province_progress(inst["id"], pid)
			if pr >= 100.0:
				have.append(inst["name"])
			elif pr > 0.0:
				have.append("%s %d%%" % [inst["name"], roundi(pr)])
		if not have.is_empty():
			txt += "\nInstituições: " + ", ".join(have)
	txt += _geography_info(p)
	info_label.text = txt
	side_panel.show()
	_fit_side_panel.call_deferred()


## Ajusta o painel ao texto, mantendo-o colado no canto inferior esquerdo.
func _fit_side_panel() -> void:
	side_panel.reset_size()
	side_panel.position.y = get_viewport_rect().size.y - side_panel.size.y - 12


func _cname(t: String) -> String:
	return map.countries[t]["name"] if map.countries.has(t) else t


## " (movimento ×1,25, defesa +1)" a partir de map.terrains (só no mapa do EU4).
func _terrain_info(label: String) -> String:
	if not map.terrains.has(label):
		return ""
	var t: Dictionary = map.terrains[label]
	var parts := []
	if t.has("movement_cost"):
		parts.append("movimento ×" + _num(t["movement_cost"]))
	if float(t.get("defence", 0)) != 0.0:
		parts.append("defesa %+d" % int(t["defence"]))
	if t.has("supply_limit"):
		parts.append("suprimento " + _num(t["supply_limit"]))
	return " (%s)" % ", ".join(parts) if not parts.is_empty() else ""


## Linhas de área / região / super-região / continente (mapa do EU4).
func _geography_info(p: Dictionary) -> String:
	var txt := ""
	var aid: String = p.get("area", "")
	if map.areas.has(aid):
		txt += "\nÁrea: " + map.areas[aid]["name"]
	var rid: String = p.get("region", "")
	if map.regions.has(rid):
		txt += "\nRegião: " + map.regions[rid]["name"]
		var sid: String = p.get("superregion", "")
		if map.superregions.has(sid):
			txt += " (%s)" % map.superregions[sid]["name"]
	var cid: String = p.get("continent", "")
	if map.continents.has(cid):
		txt += "\nContinente: " + map.continents[cid]["name"]
	return txt


## Número com vírgula decimal (2.5 -> "2,5"; 3.0 -> "3").
static func _num(x: float) -> String:
	var t := str(snappedf(x, 0.01))
	if t.ends_with(".0"):
		t = t.left(-2)
	return t.replace(".", ",")


func _on_month_passed() -> void:
	# Gancho para a economia, eventos mensais, IA etc.
	pass


# ------------------------------------------------------------------ loop e entrada
func _process(delta: float) -> void:
	if _poll_import():
		return          # a cena está sendo recarregada com o mapa novo
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
			or (side_panel.visible and side_panel.get_global_rect().has_point(m)) \
			or (country_panel.visible and country_panel.get_global_rect().has_point(m)) \
			or (tech_window.visible and tech_window.get_global_rect().has_point(m)) \
			or (ideas_window.visible and ideas_window.get_global_rect().has_point(m)) \
			or (advisors_window.visible and advisors_window.get_global_rect().has_point(m))
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
					var owner: String = map.provinces[pid]["owner"] if pid >= 0 else ""
					country_panel.show_country(map, owner if owner != "" else player_tag)
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
