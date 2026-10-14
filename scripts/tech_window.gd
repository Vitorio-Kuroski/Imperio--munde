class_name TechWindow
extends PanelContainer
## Janela das tecnologias (mapa do EU4): as três árvores (administrativa, diplomática, militar)
## com ano, efeitos, construções e governos liberados e instituições esperadas. Marca o que o
## país já tem (nível inicial do grupo tecnológico) e o próximo nível.

const CATS := [["adm", "Administrativa"], ["dip", "Diplomática"], ["mil", "Militar"]]
const DONE := Color(0.62, 0.85, 0.55)
const NEXT := Color(1.0, 0.86, 0.45)
const LATER := Color(0.72, 0.72, 0.70)
const UNIT_TYPES := [["infantry", "Infantaria"], ["cavalry", "Cavalaria"], ["artillery", "Artilharia"],
		["heavy_ship", "Naus pesadas"], ["light_ship", "Naus leves"], ["galley", "Galés"], ["transport", "Transportes"]]

var power: MonarchPower           # pontos e níveis atuais (main.gd define)
var player := ""                  # só o país do jogador ganha o botão "Pesquisar"
var _map: MapView
var _tag := ""
var _title: Label
var _tabs: TabContainer
var _pt := {}


func _init() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.12, 0.98)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)
	var top := HBoxContainer.new()
	vb.add_child(top)
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	var close := Button.new()
	close.text = "Fechar"
	close.pressed.connect(hide)
	top.add_child(close)
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(640, 480)
	vb.add_child(_tabs)
	if FileAccess.file_exists("res://data/tecnologias_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/tecnologias_pt.json"))
		if d is Dictionary:
			_pt = d
	hide()


## Nível do país na árvore `cat`: o atual (MonarchPower) ou o inicial do grupo tecnológico.
static func level_of(map: MapView, tag: String, cat := "mil", pw: MonarchPower = null) -> int:
	if pw and pw.state.has(tag):
		return pw.tech(tag, cat)
	var g: String = map.countries.get(tag, {}).get("tech_group", "")
	return int(map.tech_groups[g]["start_level"]) if map.tech_groups.has(g) else 0


## Redesenha a janela (depois de pesquisar ou quando os pontos mudam).
func refresh() -> void:
	if visible and _map:
		var tab := _tabs.current_tab
		show_for(_map, _tag)
		_tabs.current_tab = tab


func show_for(map: MapView, tag: String) -> void:
	if not map.countries.has(tag):
		return
	_map = map
	_tag = tag
	var lv := {}
	for cat in CATS:
		lv[cat[0]] = level_of(map, tag, cat[0], power)
	_title.text = "Tecnologias — %s (adm %d · dip %d · mil %d)" % [map.countries[tag]["name"], lv["adm"], lv["dip"],
			lv["mil"]]
	if power and power.state.has(tag):
		_title.text += "   pontos: adm %d · dip %d · mil %d" % [power.points(tag, "adm"), power.points(tag, "dip"),
				power.points(tag, "mil")]
	for c in _tabs.get_children():
		_tabs.remove_child(c)
		c.queue_free()
	for cat in CATS:
		var lvl: int = lv[cat[0]]
		var scroll := ScrollContainer.new()
		scroll.name = cat[1]
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_tabs.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 6)
		scroll.add_child(list)
		if power and tag == player:
			var cost := power.tech_cost(tag, cat[0])
			var b := Button.new()
			b.text = "Pesquisar o nível %d (%d pontos %s; você tem %d)" % [lvl + 1, cost, cat[0], power.points(tag, cat[0])] \
					if cost >= 0 else "Árvore completa"
			b.disabled = not power.can_research(tag, cat[0])
			b.pressed.connect(func():
				power.research(tag, cat[0])
				refresh())
			list.add_child(b)
		var names: Array = _pt.get("nomes", {}).get(cat[0], [])
		for t in map.technologies.get(cat[0], []):
			var n := int(t["level"])
			var l := Label.new()
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 600
			var mark := "✓" if n <= lvl else ("→" if n == lvl + 1 else "  ")
			var nm: String = names[n] if n < names.size() else str(t.get("name", "Tecnologia %s %d" % [cat[1].to_lower(), n]))
			l.text = "%s %d · %d · %s%s" % [mark, n, int(t["year"]), nm, _details(map, t, tag)]
			l.add_theme_color_override("font_color", DONE if n <= lvl else (NEXT if n == lvl + 1 else LATER))
			list.add_child(l)
	if not map.units.is_empty():
		_units_tab(map, tag)
	show()
	reset_size()


## Unidades que o país pode ter: as do seu grupo tecnológico + artilharia e navios (sem grupo).
static func units_for(map: MapView, tag: String) -> Array:
	var g: String = map.countries.get(tag, {}).get("tech_group", "")
	var out := []
	for u in map.units.values():
		if u.has("level") and (not u.has("unit_type") or u["unit_type"] == g):
			out.append(u)
	out.sort_custom(func(a, b):
		if a["type"] != b["type"]:
			return a["type"] < b["type"]
		if int(a["level"]) != int(b["level"]):
			return int(a["level"]) < int(b["level"])
		return a["id"] < b["id"])
	return out


## Melhor unidade já liberada de cada tipo ("infantry" -> unidade), a que o país usa agora.
static func current_units(map: MapView, tag: String, pw: MonarchPower = null) -> Dictionary:
	var best := {}
	for u in units_for(map, tag):
		if int(u["level"]) <= level_of(map, tag, u.get("tech", "mil"), pw):
			best[u["type"]] = u          # a lista vem em ordem de nível
	return best


func _units_tab(map: MapView, tag: String) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Unidades"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	var all := units_for(map, tag)
	var cur := current_units(map, tag, power)
	for ty in UNIT_TYPES:
		var head := Label.new()
		head.text = ty[1]
		head.add_theme_font_size_override("font_size", 17)
		list.add_child(head)
		for u in all:
			if u["type"] != ty[0]:
				continue
			var n := int(u["level"])
			var lvl := level_of(map, tag, u["tech"], power)
			var l := Label.new()
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 600
			var mark := "★" if cur.get(ty[0]) == u else ("✓" if n <= lvl else "  ")
			l.text = "%s %s %d · %s — %s" % [mark, u["tech"], n, u["name"], unit_stats(u)]
			l.add_theme_color_override("font_color", NEXT if mark == "★" else (DONE if n <= lvl else LATER))
			list.add_child(l)


## "fogo 1/0 · choque 2/1 · moral 1/1 · manobra 1" (ataque/defesa) ou atributos do navio.
static func unit_stats(u: Dictionary) -> String:
	if u.has("hull_size"):
		var p := ["casco %s" % u["hull_size"], "canhões %s" % u.get("base_cannons", 0),
				"marinheiros %s" % u.get("sailors", 0), "velocidade %s" % str(u.get("sail_speed", 0)).replace(".", ",")]
		if u.has("trade_power"):
			p.append("poder comercial %s" % str(u["trade_power"]).replace(".", ","))
		return ", ".join(p)
	return "fogo %s/%s · choque %s/%s · moral %s/%s · manobra %s" % [u.get("offensive_fire", 0),
			u.get("defensive_fire", 0), u.get("offensive_shock", 0), u.get("defensive_shock", 0),
			u.get("offensive_morale", 0), u.get("defensive_morale", 0), u.get("maneuver", 0)]


func _details(map: MapView, t: Dictionary, tag: String) -> String:
	var parts := []
	var labels: Dictionary = _pt.get("efeitos", {})
	var absolute: Array = _pt.get("absolutos", [])
	var mods: Dictionary = t.get("modifiers", {})
	for k in mods:
		if not labels.has(k):
			continue
		var v = mods[k]
		var txt: String
		if k in absolute:
			txt = ("%+d" % v) if float(v) == floorf(v) else ("%+.2f" % v)
		else:
			txt = "%+d%%" % roundi(v * 100.0)
		parts.append("%s %s" % [labels[k], txt.replace(".", ",")])
	var lib := []
	for b in t.get("buildings", []):
		lib.append(map.buildings[b]["name"] if map.buildings.has(b) else Eu4Importer.pretty_key(b))
	for u in t.get("unlocks", []):
		if not (u as String).ends_with("_legacy"):
			lib.append(_pt.get("liberacoes", {}).get(u, Eu4Importer.pretty_key(u)))
	var g: String = map.countries.get(tag, {}).get("tech_group", "")
	for uid in t.get("units", []):
		var u: Dictionary = map.units.get(uid, {})
		if not u.is_empty() and (not u.has("unit_type") or u["unit_type"] == g):
			lib.append(u["name"])         # só as unidades do grupo tecnológico do país
	var txt := ""
	if not parts.is_empty():
		txt += "\n     " + ", ".join(parts)
	if not lib.is_empty():
		txt += "\n     libera: " + ", ".join(lib)
	var inst := []
	var iv: Institutions = power.institutions if power else null
	for i in t.get("institutions", {}):
		var mark := ""
		if iv and iv.enabled():
			mark = " ✓" if iv.has_embraced(tag, i) else " ✗"
		inst.append("%s %d%%%s" % [_pt.get("instituicoes", {}).get(i, Eu4Importer.pretty_key(i)),
				roundi(float(t["institutions"][i]) * 100.0), mark])
	if not inst.is_empty():
		txt += "\n     espera: " + ", ".join(inst) + \
				(" (✗ = não adotada: encarece a pesquisa pelo valor esperado)" if " ✗" in ", ".join(inst) else "")
	return txt
