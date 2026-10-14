class_name Eu4IdeasTab
extends RefCounted
## Aba Ideias da tela do país do EU4 (countryideasview.gui): ideias nacionais (tradições,
## as 7 ideias com as liberadas acesas, ambição e barra de progresso) e as vagas de grupos de
## ideias (grupo adotado com as 7 ideias e a barra, ou vaga livre). No país do jogador, clicar na
## próxima ideia de um grupo a compra e clicar numa vaga livre abre a escolha de grupos.

signal choose_group_requested(tag: String)

const POWER_ICONS := {"adm": "GFX_icon_powers_administrative", "dip": "GFX_icon_powers_diplomatic",
		"mil": "GFX_icon_powers_military"}
const DIM := Color(0.38, 0.38, 0.38)

var view: Eu4CountryView
var root: Control
var _pt := {}


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countryideasview")
	if root == null:
		return false
	Eu4CountryView._hide(root, "countryideaview_ideagroupunlock")
	if FileAccess.file_exists("res://data/tecnologias_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/tecnologias_pt.json"))
		if d is Dictionary:
			_pt = d
	return true


func _mods_text(m: Dictionary) -> String:
	return str(view.fmt_mods.call(m)) if view.fmt_mods.is_valid() else ""


func _first_value(m: Dictionary) -> String:
	if m.is_empty():
		return ""
	var k: String = m.keys()[0]
	var v := float(m[k])
	# como no EU4: efeitos fracionários em porcentagem com uma casa ("+20,0%"), os outros com duas ("+1,00")
	return (("%+.1f%%" % (v * 100.0)) if absf(v) < 1.0 and v != floorf(v) else ("%+.2f" % v)).replace(".", Loc.dec)


func _idea_icon(idea: Dictionary, px: int, on: bool, tip: String) -> TextureRect:
	var tex := view.map.idea_icon(idea)
	var r := MapView.icon_rect(tex, px, tip)
	r.mouse_filter = Control.MOUSE_FILTER_STOP
	r.size_flags_vertical = Control.SIZE_SHRINK_BEGIN       # a caixa centraliza na vertical
	if not on:
		r.modulate = DIM
	return r


func fill(tag: String) -> void:
	var map := view.map
	var power := view.power
	var c: Dictionary = map.countries[tag]
	view._txt(root, "window_title", Loc.t("HEADER_IDEAS", "Ideias") + " — " + c["name"])
	# ideias nacionais
	var nat: Dictionary = power.national_ideas.get(c.get("ideas", ""), {}) if power else {}
	var shield := root.find_child("unique_ideas_category", true, false) as Eu4Gui.Button2
	if shield:
		var ft := map.flag_texture(tag)
		var img := ft.get_image() if ft else null
		shield.set_flag(ImageTexture.create_from_image(img) if img else null)
	var un := power.national_unlocked(tag) if power and power.state.has(tag) else 0
	view._txt(root, "unique_ideas_idea_title", str(nat.get("name", "Ideias nacionais")) if not nat.is_empty() \
			else Loc.s("Sem ideias nacionais", "No national ideas"))
	var start: Dictionary = nat.get("start", {})
	var keys := start.keys()
	for i in 2:
		var ic := root.find_child("unique_ideas_start_icon_%d" % (i + 1), true, false) as Eu4Gui.Icon
		if i < keys.size():
			var one := {keys[i]: start[keys[i]]}
			if ic:
				ic.show()
				ic.set_tex(map.icon_texture("mod:" + str(keys[i])))
				ic.tooltip_text = Loc.t("ND_TRADITIONS", "Tradição") + ": " + _mods_text(one)
			view._txt(root, "unique_ideas_start_desc_%d" % (i + 1), _first_value(one), Loc.t("ND_TRADITIONS", "Tradição") + ": " + _mods_text(one))
		else:
			if ic:
				ic.hide()
			view._txt(root, "unique_ideas_start_desc_%d" % (i + 1), "")
	var bonus: Dictionary = nat.get("bonus", {})
	var bi := root.find_child("unique_ideas_bonus_icon", true, false) as Eu4Gui.Icon
	if bi:
		bi.visible = not bonus.is_empty()
		if not bonus.is_empty():
			bi.set_tex(map.icon_texture("mod:" + str(bonus.keys()[0])))
			bi.tooltip_text = Loc.t("ND_AMBITION", "Ambição") + ": " + _mods_text(bonus)
	view._txt(root, "unique_ideas_bonus_desc", _first_value(bonus), Loc.t("ND_AMBITION", "Ambição") + ": " + _mods_text(bonus))
	var box := root.find_child("unique_ideas", true, false) as Control
	if box:
		Eu4TechTab._clear(box)
		if not box.has_meta("moved"):      # ícones de 64 px centrados nas 7 molduras (52 px)
			box.set_meta("moved", true)
			box.offset_left += 14
			box.offset_right += 14
			box.offset_top -= 5
			box.offset_bottom -= 5
		box.add_theme_constant_override("separation", -11)
		for i in nat.get("ideas", []).size():
			var idea: Dictionary = nat["ideas"][i]
			box.add_child(_idea_icon(idea, 64, i < un, "%s: %s%s" % [idea["name"], _mods_text(idea["modifiers"]),
					"" if i < un else Loc.s(" (liberada a cada 3 ideias de grupo)", " (unlocked every 3 group ideas)")]))
	var up := root.find_child("idea_unique_progress", true, false) as Eu4Gui.Progress
	if up:
		up.set_value(un / 7.0)
		up.tooltip_text = Loc.s("%d/7 ideias nacionais", "%d/7 national ideas") % un
	# todas as vagas de grupos (como no EU4), alternando esquerda e direita: grupo adotado, vaga livre
	# ou "Liberada em <tecnologia administrativa> (nível)"
	var slots := power.idea_slots(tag) if power and power.state.has(tag) else 0
	var adopted: Array = power.adopted(tag) if power and power.state.has(tag) else []
	var max_slots: int = power._slots_at[power._slots_at.size() - 1] if power and not power._slots_at.is_empty() else slots
	var total := maxi(maxi(slots, adopted.size()), max_slots)
	var cols := [root.find_child("ideagroups_listbox_left", true, false) as Control,
			root.find_child("ideagroups_listbox_right", true, false) as Control]
	for col in cols:
		view.gui.fill_list(col, "", 0)
	for k in total:
		_slot(cols[k % 2], tag, adopted, slots, k)


## Nível adm que libera a vaga `k` (0 = primeira): [nível, nome da tecnologia] ou [] se nenhum.
func _unlock_tech(k: int) -> Array:
	var sa: PackedInt32Array = view.power._slots_at
	for lvl in sa.size():
		if sa[lvl] >= k + 1:
			var names: Array = _pt.get("nomes", {}).get("adm", []) if not Loc.active() else []
			var techs: Array = view.map.technologies.get("adm", [])
			var nm := str(names[lvl]) if lvl < names.size() else (str(techs[lvl].get("name", "")) if lvl < techs.size() else "")
			return [lvl, nm]
	return []


func _slot(list: Control, tag: String, adopted: Array, slots: int, k: int) -> void:
	var gui := view.gui
	if list == null:
		return
	if k < adopted.size():
		var row := gui.add_item(list, "countryideaview_ideagroupitem")
		if row:
			row.get_parent().custom_minimum_size.y = 84
			_group(row, tag, adopted[k])
		return
	var row := gui.add_item(list, "countryideaview_ideagroupunlockitem")
	if row == null:
		return
	row.get_parent().custom_minimum_size.y = 84
	var b := row.find_child("unlock", true, false) as BaseButton
	var glow := row.find_child("available_idea_glow", true, false) as Control
	var free := k < slots
	if free:
		view._txt(row, "txt", Loc.s("Escolher um grupo de ideias", "Pick an idea group") if tag == view.player \
				else Loc.t("CV_IDEAS_GROUP_UNLOCK", "Vaga livre"))
		if b:
			b.pressed.connect(func(): choose_group_requested.emit(tag))
	else:
		var u := _unlock_tech(k)
		view._txt(row, "txt", Loc.f("CV_IDEAS_UNLOCK_ADM_LEVEL", {"NAME": "%s (%d)" % [u[1], u[0]]}, "Liberada em\n%s (%d)" % [u[1], u[0]]) if not u.is_empty() \
				else Loc.t("REFORM_LEVEL_LOCKED", "Bloqueada"))
		if b:
			b.disabled = true
			b.modulate = Color(0.62, 0.62, 0.62)
			b.tooltip_text = Loc.s("Vaga liberada pela tecnologia administrativa %d", "Slot unlocked by administrative technology %d") % u[0] \
					if not u.is_empty() else ""
	if glow:
		glow.visible = free and tag == view.player
	var l := row.find_child("txt", true, false) as Label
	if l:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.offset_top = 6
		l.offset_bottom = 60


func _group(row: Control, tag: String, g: Dictionary) -> void:
	var map := view.map
	var power := view.power
	var grp: Dictionary = power.idea_groups[g["id"]]
	var n := int(g["n"])
	Eu4CountryView._hide(row, "abandon_idea_button")
	Eu4CountryView._hide(row, "ideas_bonus_icon")
	var cat: Eu4Gui.Icon = row.find_child("ideas_category", true, false) as Eu4Gui.Icon
	if cat:
		cat.set_tex(map.icon_texture("group:" + g["id"]))
		cat.tooltip_text = Loc.s("Bônus do grupo completo: ", "Full group bonus: ") + _mods_text(grp.get("bonus", {}))
	var cost := row.find_child("ideas_cost", true, false) as Eu4Gui.Icon
	var c: String = grp.get("category", "adm")
	if cost and view.gui.sprites.has(POWER_ICONS.get(c, "")):
		cost.set_sprite(view.gui, POWER_ICONS[c], 0)
	view._txt(row, "ideas_idea_title", "%s %d/%d" % [grp["name"], n, grp["ideas"].size()])
	var box := row.find_child("ideas", true, false) as Control
	if box:
		Eu4TechTab._clear(box)
		if not box.has_meta("moved"):      # as ideias (countryideaview_ideaitem) ficam 25 px acima da caixa
			box.set_meta("moved", true)
			box.offset_top -= 27
			box.offset_bottom -= 27
			box.offset_left -= 2
		box.add_theme_constant_override("separation", 0)
		for i in grp["ideas"].size():
			var idea: Dictionary = grp["ideas"][i]
			var tip := "%s: %s" % [idea["name"], _mods_text(idea["modifiers"])]
			var can_buy: bool = i == n and tag == view.player and power.can_buy_idea(tag, g["id"])
			if i == n:
				tip += Loc.s("\n(próxima: %d pontos %s%s)", "\n(next: %d %s points%s)") % [power.idea_cost(tag), c,
						Loc.s("; clique para comprar", "; click to buy") if can_buy else ""]
			var r := _idea_icon(idea, 28, i < n, tip)
			if can_buy:
				r.modulate = Color(1, 1, 0.75)
				var gid: String = g["id"]
				r.gui_input.connect(func(e: InputEvent):
					if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
						if power.buy_idea(tag, gid):
							view.refresh())
			box.add_child(r)
	var prog := row.find_child("idea_progress", true, false) as Eu4Gui.Progress
	if prog:
		prog.set_value(float(n) / maxf(1.0, grp["ideas"].size()))
