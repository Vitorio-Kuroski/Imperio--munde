class_name AdvisorsWindow
extends PanelContainer
## Janela dos conselheiros: para cada categoria (adm/dip/mil), o contratado (com botão de dispensar)
## e os candidatos do ano (históricos marcados com ★), com nível, salário e efeito.
## Só o país do jogador pode contratar; para os outros é só leitura.

const CAT_NAMES := {"adm": "Administrativo", "dip": "Diplomático", "mil": "Militar"}

var advisors: Advisors
var economy: Economy
var player := ""
var fmt: Callable                 # formata efeitos (IdeasWindow.fmt_mods)
var _map: MapView
var _tag := ""
var _title: Label
var _list: VBoxContainer


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
	scroll.custom_minimum_size = Vector2(640, 460)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)
	hide()


func refresh() -> void:
	if visible and _map:
		show_for(_map, _tag)


func show_for(map: MapView, tag: String) -> void:
	if not map.countries.has(tag) or advisors == null:
		return
	_map = map
	_tag = tag
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_title.text = "Conselheiros — %s   (tesouro %s ducados, saldo %s/mês)" % [map.countries[tag]["name"],
			_n(economy.money(tag)), _n(economy.balance(tag), true)]
	for cat in Advisors.CATS:
		var head := Label.new()
		head.text = CAT_NAMES[cat]
		head.add_theme_font_size_override("font_size", 17)
		_list.add_child(head)
		var h := advisors.get_hired(tag, cat)
		var row := HBoxContainer.new()
		var l := _label("Contratado: " + (_desc(tag, h) if not h.is_empty() else "ninguém"))
		l.add_theme_color_override("font_color", Color(0.62, 0.85, 0.55) if not h.is_empty() else Color(0.72, 0.72, 0.70))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if not h.is_empty() and map.icon_texture("advisor:" + h["type"]):
			row.add_child(MapView.icon_rect(map.icon_texture("advisor:" + h["type"]), 44))
		row.add_child(l)
		if tag == player and not h.is_empty():
			var b := Button.new()
			b.text = "Dispensar"
			b.pressed.connect(func():
				advisors.dismiss(tag, cat)
				refresh())
			row.add_child(b)
		_list.add_child(row)
		var cands := advisors.candidates(tag, cat)
		for i in cands.size():
			var r := HBoxContainer.new()
			var cl := _label("   " + _desc(tag, cands[i]))
			cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var ptex := map.icon_texture("advisor:" + cands[i]["type"])
			if ptex:
				cl.text = _desc(tag, cands[i])
				r.add_child(MapView.icon_rect(ptex, 36))
			r.add_child(cl)
			if tag == player:
				var b := Button.new()
				b.text = "Contratar"
				b.disabled = economy.money(tag) < advisors.salary(tag, cands[i])
				var idx := i
				b.pressed.connect(func():
					advisors.hire(tag, cat, idx)
					refresh())
				r.add_child(b)
			_list.add_child(r)
	show()
	reset_size()


## "★ Jean Froissart — Artista nível 2 (+2 adm/mês) · 4 ducados/mês · custo de estabilidade -10%"
func _desc(tag: String, a: Dictionary) -> String:
	var t: Dictionary = advisors.types.get(a["type"], {})
	var txt: String = ("★ %s — %s" % [a["name"], t.get("name", a["type"])]) if a.get("historical", false) \
			else str(t.get("name", a["type"]))
	txt += " nível %d (+%d %s/mês) · %s ducados/mês" % [int(a["skill"]), int(a["skill"]), a["category"],
			_n(advisors.salary(tag, a))]
	if fmt.is_valid():
		txt += " · " + str(fmt.call(t.get("modifiers", {})))
	return txt


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 480
	return l


static func _n(x: float, sign := false) -> String:
	var t := ("%+.1f" if sign else "%.1f") % x
	return t.replace(".", ",")
