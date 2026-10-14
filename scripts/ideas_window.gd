class_name IdeasWindow
extends PanelContainer
## Janela das ideias (mapa do EU4): ideias nacionais do país (tradições, 7 ideias liberadas a cada 3
## ideias de grupo, ambição), grupos adotados com o botão de comprar a próxima ideia e a lista de
## grupos para adotar quando houver vaga. Nomes e efeitos em português de data/ideias_pt.json.

const DONE := Color(0.62, 0.85, 0.55)
const NEXT := Color(1.0, 0.86, 0.45)
const LATER := Color(0.72, 0.72, 0.70)

var power: MonarchPower
var player := ""
var _map: MapView
var _tag := ""
var _title: Label
var _list: VBoxContainer
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
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(660, 500)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)
	if FileAccess.file_exists("res://data/ideias_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/ideias_pt.json"))
		if d is Dictionary:
			_pt = d
	hide()


func refresh() -> void:
	if visible and _map:
		show_for(_map, _tag)


func show_for(map: MapView, tag: String) -> void:
	if not map.countries.has(tag) or power == null:
		return
	_map = map
	_tag = tag
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var c: Dictionary = map.countries[tag]
	var slots := power.idea_slots(tag)
	_title.text = "Ideias — %s   (grupos %d/%d · custo %d pontos por ideia)" % [c["name"], power.adopted(tag).size(),
			slots, power.idea_cost(tag)]

	# ideias nacionais
	var nat: Dictionary = power.national_ideas.get(c.get("ideas", ""), {})
	if not nat.is_empty():
		var nm: String = "de " + c["name"] if (nat["id"] as String).begins_with(tag) else "— " + nat["name"]
		_head("Ideias nacionais %s (%d/7 liberadas; 1 a cada 3 ideias de grupo)" % [nm, power.national_unlocked(tag)])
		_line("Tradições: " + fmt_mods(nat["start"]), DONE)
		var un := power.national_unlocked(tag)
		for i in nat["ideas"].size():
			var idea: Dictionary = nat["ideas"][i]
			_line("%s %s: %s" % ["✓" if i < un else "  ", idea["name"], fmt_mods(idea["modifiers"])],
					DONE if i < un else LATER, map.idea_icon(idea))
		_line("Ambição (todas as 7): " + fmt_mods(nat["bonus"]), DONE if un >= nat["ideas"].size() else LATER)

	# grupos adotados
	for g in power.adopted(tag):
		var grp: Dictionary = power.idea_groups[g["id"]]
		var cat: String = grp["category"]
		var n := int(g["n"])
		_head("%s (%s) — %d/%d" % [grp["name"], _pt.get("categorias", {}).get(cat.to_upper(), cat), n, grp["ideas"].size()],
				map.icon_texture("group:" + g["id"]))
		for i in grp["ideas"].size():
			var idea: Dictionary = grp["ideas"][i]
			_line("%s %s: %s" % ["✓" if i < n else ("→" if i == n else "  "), idea["name"], fmt_mods(idea["modifiers"])],
					DONE if i < n else (NEXT if i == n else LATER), map.idea_icon(idea))
		_line("Bônus (grupo completo): " + fmt_mods(grp["bonus"]), DONE if n >= grp["ideas"].size() else LATER)
		if tag == player and n < grp["ideas"].size():
			var b := Button.new()
			b.text = "Comprar a próxima ideia (%d pontos %s; você tem %d)" % [power.idea_cost(tag), cat,
					power.points(tag, cat)]
			b.disabled = not power.can_buy_idea(tag, g["id"])
			var gid: String = g["id"]
			b.pressed.connect(func():
				power.buy_idea(tag, gid)
				refresh())
			_list.add_child(b)

	# grupos para adotar
	if tag == player:
		if power.adopted(tag).size() < slots:
			_head("Adotar um grupo de ideias (vaga livre)")
			for cat in ["adm", "dip", "mil"]:
				var row := HFlowContainer.new()
				for gid in power.idea_groups:
					var grp: Dictionary = power.idea_groups[gid]
					if grp.get("category", "") != cat or not power.can_adopt(tag, gid):
						continue
					var b := Button.new()
					b.text = grp["name"]
					b.tooltip_text = "Bônus: " + fmt_mods(grp["bonus"])
					b.icon = map.icon_texture("group:" + gid)
					b.add_theme_constant_override("icon_max_width", 28)
					b.pressed.connect(func():
						power.adopt(tag, gid)
						refresh())
					row.add_child(b)
				var l := Label.new()
				l.text = _pt.get("categorias", {}).get(cat.to_upper(), cat).capitalize() + ":"
				_list.add_child(l)
				_list.add_child(row)
		elif slots == 0:
			_line("Sem vagas para grupos de ideias: a primeira vem com a tecnologia administrativa " +
					"\"Ideias nacionais\" (nível 5).", LATER)
	show()
	reset_size()


func _head(text: String, icon: Texture2D = null) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 620 if icon == null else 580
	l.add_theme_font_size_override("font_size", 17)
	_list.add_child(MapView.with_icon(icon, l, 36))


func _line(text: String, color: Color, icon: Texture2D = null) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 620 if _map == null or _map.icons.is_empty() else 590
	l.add_theme_color_override("font_color", color)
	_list.add_child(MapView.with_icon(icon, l, 24, _map != null and not _map.icons.is_empty()))


## {"global_tax_modifier": 0.1, "prestige": 1} -> "imposto +10%, prestígio anual +1"
func fmt_mods(mods: Dictionary) -> String:
	var labels: Dictionary = _pt.get("efeitos", {})
	var absolute: Array = _pt.get("absolutos", [])
	var parts := []
	for k in mods:
		var v = mods[k]
		if not (v is float or v is int):
			continue
		var label: String = labels.get(k, Eu4Importer.pretty_key(k).to_lower())
		if Loc.active():        # nome do efeito na localização do EU4 (senão o nome da chave em inglês)
			label = Loc.modifier(k, Eu4Importer.pretty_key(k))
		var txt: String
		if k in absolute:
			txt = ("%+d" % v) if float(v) == floorf(v) else ("%+.2f" % v)
		else:
			var pct := float(v) * 100.0
			txt = ("%+d%%" % roundi(pct)) if is_equal_approx(pct, roundf(pct)) else ("%+.1f%%" % pct)
		parts.append(("%s: %s" % [label, txt]) if Loc.active() else ("%s %s" % [label, txt.replace(".", Loc.dec)]))
	return ", ".join(parts) if not parts.is_empty() else "—"
