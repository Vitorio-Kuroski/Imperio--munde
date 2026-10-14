class_name Eu4ReligionTab
extends RefCounted
## Aba Religião da tela do país do EU4 (countryreligionview.gui): religião do Estado (ícone e
## efeitos, que valem para o país), tolerância à própria fé, a heréticos e a pagãos (valores
## básicos do EU4 + efeitos), unidade religiosa (parte do desenvolvimento com a religião do
## Estado), força missionária e a lista das províncias com a religião de cada uma. Conversão,
## missionários e as mecânicas próprias de cada religião (papado, piedade, carma...) ficam
## escondidas até o jogo as ter.

const HIDE := ["secondary_religion_banner", "secondary_religion_name", "secondary_religion_icon", "religious_school_window",
		"religion_sub_modifiers_listbox", "convert_button", "convert_secondary_button", "orthodox_specific_window",
		"shinto_specific_window", "confucianism_specific_window", "coptic_specific_window", "muslim_specific_window",
		"buddhist_specific_window", "personal_deity", "fetishist_cult", "sikh_guru_window", "totemism_ancestor_window",
		"catholic_specific_window", "protestant_specific_window", "jewish_specific_window", "anglican_specific_window",
		"fervor_specific_window", "show_subjects", "show_subjects_title", "automatic_missionariy_BG",
		"automatic_missionary_title", "missionary_icon_list", "assign_automatic_missionary", "full_unity_bg", "full_unity",
		"defender_of_the_faith_tier", "become_Defender_of_the_Faith", "defender_of_the_faith_emperor_button",
		"defender_of_the_faith_button", "defender_of_the_faith_shield", "defender_of_the_faith_emperor_shield",
		"defender_title", "countryreligionview_convert", "deity_selection_screen", "power_enabled", "sort_time"]
const GOOD := Color(0.55, 0.9, 0.45)
const BAD := Color(1.0, 0.42, 0.35)

var view: Eu4CountryView
var root: Control


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countryreligionview")
	if root == null:
		return false
	for n in HIDE:
		Eu4CountryView._hide(root, n)
	for ch in root.get_children():       # subjanelas (mecânicas de cada religião, telas de escolha)
		if ch.get_class() == "Control":
			(ch as Control).hide()
	Eu4CountryView._hide(root, "icon_tolerance_heretic")    # o .gui usa o ícone da 1ª religião ali
	Eu4CountryView._hide(root, "icon_tolerance_heathen")
	view._txt(root, "label_tolerance", "Tolerância")
	view._txt(root, "conversion", "Províncias")
	Eu4CountryView._hide(root, "sort_mission")
	for b in [["sort_name", "Nome"], ["sort_religion", "Religião"], ["sort_unity", "Desenv."]]:
		var btn := root.find_child(b[0], true, false) as Control
		if btn:
			view._set_button_text(btn, b[1])
	var list := root.find_child("province_listbox", true, false) as Control
	if list:            # o .gui não dá tamanho à lista
		list.offset_left = 8
		list.offset_right = 540
		list.offset_bottom = list.offset_top + 160
	return true


func _base(k: String) -> float:
	return float(view.map.trade_rules.get("base_values", {}).get(k, 0.0))


func _religion_icon(ic: Eu4Gui.Icon, rid: String) -> void:
	if ic == null:
		return
	var icon := int(view.map.religions.get(rid, {}).get("icon", 0))
	ic.visible = icon > 0
	if icon > 0:
		ic.set_frame(icon - 1)
	ic.tooltip_text = str(view.map.religions.get(rid, {}).get("name", ""))


func fill(tag: String) -> void:
	var map := view.map
	var pw := view.power
	var c: Dictionary = map.countries[tag]
	var rid: String = c.get("religion", "")
	var rel: Dictionary = map.religions.get(rid, {})
	view._txt(root, "window_title", "Religião — " + c["name"])
	view._txt(root, "current_religion_name", str(rel.get("name", "—")), "Grupo: " + str(rel.get("group", "")))
	_religion_icon(root.find_child("current_religion_icon", true, false) as Eu4Gui.Icon, rid)
	# efeitos da religião
	var mods_list := root.find_child("religion_modifiers_listbox", true, false) as Control
	var mods: Dictionary = rel.get("modifiers", {})
	var rows := view.gui.fill_list(mods_list, "religion_modifier_item", mods.size())
	var keys := mods.keys()
	for i in rows.size():
		var one := {keys[i]: mods[keys[i]]}
		var ic := rows[i].find_child("modifier_icon", true, false) as Eu4Gui.Icon
		var tex := map.icon_texture("mod:" + str(keys[i]))
		if ic:
			ic.visible = tex != null
			if tex:
				ic.set_tex(tex)
		view._txt(rows[i], "modifier_bonus", str(view.fmt_mods.call(one)) if view.fmt_mods.is_valid() else str(keys[i]))
	# tolerância (valores básicos do EU4 + efeitos de ideias, religião etc.)
	var tol := {"own": _base("tolerance_own") + pw.modifier(tag, "tolerance_own"),
			"heretic": _base("tolerance_heretic") + pw.modifier(tag, "tolerance_heretic"),
			"heathen": _base("tolerance_heathen") + pw.modifier(tag, "tolerance_heathen")}
	var names := {"own": "da própria fé", "heretic": "a heréticos (mesmo grupo)", "heathen": "a pagãos (outros grupos)"}
	for k in tol:
		var v: float = tol[k]
		view._txt(root, "val_tolerance_" + k, ("%+.0f" % v) if v == floorf(v) else ("%+.1f" % v).replace(".", ","),
				"Tolerância " + names[k])
		var l := root.find_child("val_tolerance_" + k, true, false) as Label
		if l:
			l.add_theme_color_override("font_color", GOOD if v >= 0.0 else BAD)
		var ic := root.find_child("icon_tolerance_" + k, true, false) as Control
		if ic:
			ic.tooltip_text = "Tolerância " + names[k]
	_religion_icon(root.find_child("icon_tolerance_own", true, false) as Eu4Gui.Icon, rid)
	# unidade religiosa e força missionária
	var total := 0.0
	var same := 0.0
	var provs := []
	for p in map.provinces:
		if p["owner"] == tag and not p["sea"]:
			provs.append(p)
			total += float(p["development"])
			if p.get("religion", "") == rid:
				same += float(p["development"])
	var unity := same / total if total > 0.0 else 1.0
	view._txt(root, "religiousunity_value", "%d%%" % roundi(unity * 100.0),
			"Unidade religiosa: parte do desenvolvimento das províncias com a religião do Estado")
	var ms := _base("global_missionary_strength") + pw.modifier(tag, "global_missionary_strength")
	view._txt(root, "missionary_strength_value", ("%+.1f%%" % (ms * 100.0)).replace(".", ","), "Força missionária")
	# províncias: primeiro as de outra religião, depois por desenvolvimento
	provs.sort_custom(func(a, b):
		var oa: bool = a.get("religion", "") != rid
		var ob: bool = b.get("religion", "") != rid
		if oa != ob:
			return oa
		return int(a["development"]) > int(b["development"]))
	var list := root.find_child("province_listbox", true, false) as Control
	var items := view.gui.fill_list(list, "countryreligionview_provincelistitem", provs.size())
	for i in items.size():
		var p: Dictionary = provs[i]
		var pr: String = p.get("religion", "")
		for h in ["missionary_progress", "time", "send_missionary_text"]:
			Eu4CountryView._hide(items[i], h)
		for ch in items[i].get_children():      # botões de missionário (ainda não há missionários)
			if ch is BaseButton:
				(ch as Control).hide()
		view._txt(items[i], "name", p["name"])
		view._txt(items[i], "religion", str(map.religions.get(pr, {}).get("name", "—")))
		_religion_icon(items[i].find_child("province_religion", true, false) as Eu4Gui.Icon, pr)
		var ok := pr == rid
		view._txt(items[i], "unity", "%d" % int(p["development"]), "Desenvolvimento" + ("" if ok else " (outra religião)"))
		var ul := items[i].find_child("unity", true, false) as Label
		if ul:
			ul.add_theme_color_override("font_color", GOOD if ok else BAD)
