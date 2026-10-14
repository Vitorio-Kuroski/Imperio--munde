class_name TechWindow
extends PanelContainer
## Janela das tecnologias (mapa do EU4): as três árvores (administrativa, diplomática, militar)
## com ano, efeitos, construções e governos liberados e instituições esperadas. Marca o que o
## país já tem (nível inicial do grupo tecnológico) e o próximo nível.

const CATS := [["adm", "Administrativa"], ["dip", "Diplomática"], ["mil", "Militar"]]
const DONE := Color(0.62, 0.85, 0.55)
const NEXT := Color(1.0, 0.86, 0.45)
const LATER := Color(0.72, 0.72, 0.70)

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


## Nível inicial do país em cada árvore (o start_level do grupo tecnológico).
static func level_of(map: MapView, tag: String) -> int:
	var g: String = map.countries.get(tag, {}).get("tech_group", "")
	return int(map.tech_groups[g]["start_level"]) if map.tech_groups.has(g) else 0


func show_for(map: MapView, tag: String) -> void:
	if not map.countries.has(tag):
		return
	var lvl := level_of(map, tag)
	_title.text = "Tecnologias — %s (nível %d nas três árvores)" % [map.countries[tag]["name"], lvl]
	for c in _tabs.get_children():
		_tabs.remove_child(c)
		c.queue_free()
	for cat in CATS:
		var scroll := ScrollContainer.new()
		scroll.name = cat[1]
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_tabs.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 6)
		scroll.add_child(list)
		var names: Array = _pt.get("nomes", {}).get(cat[0], [])
		for t in map.technologies.get(cat[0], []):
			var n := int(t["level"])
			var l := Label.new()
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 600
			var mark := "✓" if n <= lvl else ("→" if n == lvl + 1 else "  ")
			var nm: String = names[n] if n < names.size() else "Tecnologia %s %d" % [cat[1].to_lower(), n]
			l.text = "%s %d · %d · %s%s" % [mark, n, int(t["year"]), nm, _details(map, t)]
			l.add_theme_color_override("font_color", DONE if n <= lvl else (NEXT if n == lvl + 1 else LATER))
			list.add_child(l)
	show()
	reset_size()


func _details(map: MapView, t: Dictionary) -> String:
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
	if not t.get("units", []).is_empty():
		var nu: int = t["units"].size()
		lib.append("1 tipo de unidade" if nu == 1 else "%d tipos de unidade" % nu)
	var txt := ""
	if not parts.is_empty():
		txt += "\n     " + ", ".join(parts)
	if not lib.is_empty():
		txt += "\n     libera: " + ", ".join(lib)
	var inst := []
	for i in t.get("institutions", {}):
		inst.append("%s %d%%" % [_pt.get("instituicoes", {}).get(i, Eu4Importer.pretty_key(i)),
				roundi(float(t["institutions"][i]) * 100.0)])
	if not inst.is_empty():
		txt += "\n     espera: " + ", ".join(inst)
	return txt
