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
		"defender_title", "deity_selection_screen", "power_enabled"]
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
	# conversão do país: o botão abre a lista de religiões (countryreligionview_convert)
	var cb := root.find_child("convert_button", true, false) as BaseButton
	if cb:
		cb.show()
		cb.tooltip_text = Loc.s("Mudar a religião do Estado", "Change the state religion")
		cb.pressed.connect(func(): _show_convert(true))
	var cw := root.find_child("countryreligionview_convert", true, false) as Control
	if cw:
		view._txt(cw, "title", Loc.t("CONVERT", "Mudar a religião do Estado"))
		var back := cw.find_child("back_button", true, false) as Control
		if back:
			view._set_button_text(back, Loc.t("BACK", "Voltar"))
			(back as BaseButton).pressed.connect(func(): _show_convert(false))
	Eu4CountryView._hide(root, "icon_tolerance_heretic")    # o .gui usa o ícone da 1ª religião ali
	Eu4CountryView._hide(root, "icon_tolerance_heathen")
	view._txt(root, "label_tolerance", Loc.t("TOLERANCE", "Tolerância"))
	view._txt(root, "conversion", Loc.s("Províncias", "Provinces"))
	for b in [["sort_name", Loc.t("NAME", "Nome")], ["sort_religion", Loc.t("RELIGION", "Religião")],
			["sort_unity", Loc.s("Desenv.", "Dev.")], ["sort_mission", Loc.t("ENVOY_MISSIONARY", "Missionário")]]:
		var btn := root.find_child(b[0], true, false) as Control
		if btn:
			view._set_button_text(btn, b[1])
	return true


func _base(k: String) -> float:
	return float(view.map.trade_rules.get("base_values", {}).get(k, 0.0))


func _religion_icon(ic: Eu4Gui.Icon, rid: String) -> void:
	if ic == null:
		return
	ic.set_religion(view.map.religions.get(rid, {}))


## Botão, barra e tempo do missionário numa linha da lista de províncias.
func _missionary(row: Control, tag: String, pid: int) -> void:
	var rel := view.religion
	var btn := row.find_child("send_missionary", true, false) as BaseButton
	var bar := row.find_child("missionary_progress", true, false) as Eu4Gui.Progress
	var frame := row.find_child("missionary_progress_frame", true, false) as Control
	var convertible := rel != null and rel.can_convert(tag, pid)
	var active := rel != null and rel.has_mission(tag, pid)
	for c in [btn, row.find_child("send_missionary_text", true, false)]:
		if c:
			(c as Control).visible = convertible and tag == view.player
	if bar:
		bar.visible = active
		bar.set_value(rel.progress(tag, pid) / 100.0 if active else 0.0)
	if frame:
		frame.visible = active
	if not convertible:
		view._txt(row, "time", "")
		return
	var ml := rel.months_left(tag, pid)
	var s := rel.strength(tag, pid)
	view._txt(row, "time", ("%d m" % ml) if active and ml >= 0 else "", Loc.s("Meses até converter", "Months until converted") if active else "")
	if btn == null:
		return
	for cn in btn.pressed.get_connections():
		btn.pressed.disconnect(cn["callable"])
	if active:
		view._txt(row, "send_missionary_text", Loc.t("RECALL", "Chamar"))
		btn.disabled = false
		btn.modulate = Color.WHITE
		btn.tooltip_text = Loc.s("Convertendo: %d%% (%s%% por mês, %s ducados por mês)",
				"Converting: %d%% (%s%% per month, %s ducats per month)") % [roundi(rel.progress(tag, pid)),
				AdvisorsWindow._n(s * 100.0), AdvisorsWindow._n(rel.mission_cost(pid, tag))]
		btn.pressed.connect(func():
			rel.recall(tag, pid)
			view.refresh())
	else:
		view._txt(row, "send_missionary_text", Loc.t("SEND", "Enviar"))
		btn.disabled = not rel.can_send(tag, pid)
		btn.modulate = Color(0.6, 0.6, 0.6) if btn.disabled else Color.WHITE
		btn.tooltip_text = Loc.s("Força líquida %s%% por mês (%d meses), %s ducados por mês",
				"Net strength %s%% per month (%d months), %s ducats per month") % [AdvisorsWindow._n(s * 100.0),
				ceili(100.0 / (s * 100.0)) if s > 0.0 else 0, AdvisorsWindow._n(rel.mission_cost(pid, tag))] if s > 0.0 \
				else Loc.s("Força missionária insuficiente (a resistência é 0,1% por desenvolvimento)",
				"Missionary strength too low (resistance is 0.1% per development)")
		if rel.free_missionaries(tag) <= 0:
			btn.tooltip_text += Loc.s("\nSem missionário livre", "\nNo free missionary")
		btn.pressed.connect(func():
			rel.send(tag, pid)
			view.refresh())


var _tag := ""


func _show_convert(on: bool) -> void:
	var cw := root.find_child("countryreligionview_convert", true, false) as Control
	if cw == null:
		return
	cw.visible = on
	if not on:
		return
	var map := view.map
	var rel := view.religion
	# religiões presentes nas províncias do país (a da capital pode virar a do Estado)
	var found := {}
	for p in map.provinces:
		if p["owner"] == _tag and p.get("religion", "") != "" and p["religion"] != rel.state_religion(_tag):
			found[p["religion"]] = int(found.get(p["religion"], 0)) + int(p["development"])
	var ids := found.keys()
	ids.sort_custom(func(a, b): return found[a] > found[b])
	var list := cw.find_child("religions_listbox", true, false) as Control
	var rows := view.gui.fill_list(list, "religionlistitem", ids.size())
	view._txt(cw, "religion_messagetext", "" if not ids.is_empty() else Loc.t("NO_POTENTIAL_RELIGION", "Nenhuma outra religião nas suas províncias"))
	for i in rows.size():
		var rid: String = ids[i]
		_religion_icon(rows[i].find_child("religion_icon", true, false) as Eu4Gui.Icon, rid)
		view._txt(rows[i], "religion_name", str(map.religions.get(rid, {}).get("name", rid)))
		Eu4CountryView._hide(rows[i], "reformation_center_icon")
		view._txt(rows[i], "reformation_center_desc", Loc.s("Desenvolvimento nas suas províncias: %d", "Development in your provinces: %d") % found[rid])
		var ml := rows[i].find_child("religion_modifiers_listbox_convert", true, false) as Control
		var mods: Dictionary = map.religions.get(rid, {}).get("modifiers", {})
		var mrows := view.gui.fill_list(ml, "religion_modifier_item", mods.size())
		var keys := mods.keys()
		for k in mrows.size():
			Eu4CountryView._hide(mrows[k], "modifier_icon")
			view._txt(mrows[k], "modifier_bonus", str(view.fmt_mods.call({keys[k]: mods[keys[k]]})) \
					if view.fmt_mods.is_valid() else str(keys[k]))
		var b := rows[i].find_child("religion_convert_now", true, false) as BaseButton
		if b:
			var ok := _tag == view.player and rel.can_convert_country(_tag, rid)
			b.disabled = not ok
			b.modulate = Color.WHITE if ok else Color(0.6, 0.6, 0.6)
			b.tooltip_text = Loc.s("Converter o país a %s", "Convert the country to %s") % map.religions.get(rid, {}).get("name", rid) if ok \
					else Loc.s("Só dá para adotar a religião da sua capital", "Only the religion of your capital can be adopted")
			b.pressed.connect(func():
				if rel.convert_country(_tag, rid):
					_show_convert(false)
					view.refresh())


func fill(tag: String) -> void:
	_tag = tag
	var map := view.map
	var pw := view.power
	var c: Dictionary = map.countries[tag]
	var rid: String = c.get("religion", "")
	var rel: Dictionary = map.religions.get(rid, {})
	view._txt(root, "window_title", Loc.t("HEADER_RELIGION", "Religião") + " — " + c["name"])
	view._txt(root, "current_religion_name", str(rel.get("name", "—")), Loc.t("GROUP", "Grupo") + ": " + Loc.t(str(rel.get("group", "")), str(rel.get("group", ""))))
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
	var names := {"own": Loc.t("tolerance_own", "Tolerância da própria fé"), "heretic": Loc.t("tolerance_heretic",
			"Tolerância a heréticos (mesmo grupo)"), "heathen": Loc.t("tolerance_heathen", "Tolerância a pagãos (outros grupos)")}
	for k in tol:
		var v: float = tol[k]
		view._txt(root, "val_tolerance_" + k, ("%+.0f" % v) if v == floorf(v) else ("%+.1f" % v).replace(".", Loc.dec),
				names[k])
		var l := root.find_child("val_tolerance_" + k, true, false) as Label
		if l:
			l.add_theme_color_override("font_color", GOOD if v >= 0.0 else BAD)
		var ic := root.find_child("icon_tolerance_" + k, true, false) as Control
		if ic:
			ic.tooltip_text = names[k]
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
			Loc.t("religious_unity", "Unidade religiosa") + Loc.s(": parte do desenvolvimento das províncias com a religião do Estado",
			": share of province development with the state religion"))
	var ms := _base("global_missionary_strength") + pw.modifier(tag, "global_missionary_strength")
	view._txt(root, "missionary_strength_value", ("%+.1f%%" % (ms * 100.0)).replace(".", Loc.dec), Loc.t("GLOBAL_MISSIONARY_STRENGTH", "Força missionária"))
	var rg := view.religion
	if rg:
		view._txt(root, "conversion", Loc.t("HINT_MISSIONARY_TITLE", "Missionários") + " %d/%d" % [rg.missions.get(tag, {}).size(),
				rg.max_missionaries(tag)], Loc.s("Missionários convertendo / total. A força líquida em cada província é a " \
				+ "força missionária menos 0,1% por desenvolvimento.", "Missionaries converting / total. The net strength in " \
				+ "each province is the missionary strength minus 0.1% per development."))
	# províncias: primeiro as com missionário, depois as de outra religião, depois por desenvolvimento
	var rgs := view.religion
	provs.sort_custom(func(a, b):
		var ma: bool = rgs != null and rgs.has_mission(tag, int(a["id"]))
		var mb: bool = rgs != null and rgs.has_mission(tag, int(b["id"]))
		if ma != mb:
			return ma
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
		_missionary(items[i], tag, int(p["id"]))
		view._txt(items[i], "name", p["name"])
		view._txt(items[i], "religion", str(map.religions.get(pr, {}).get("name", "—")))
		_religion_icon(items[i].find_child("province_religion", true, false) as Eu4Gui.Icon, pr)
		var ok := pr == rid
		view._txt(items[i], "unity", "%d" % int(p["development"]), Loc.t("DEVELOPMENT", "Desenvolvimento") + ("" if ok else Loc.s(" (outra religião)", " (other religion)")))
		var ul := items[i].find_child("unity", true, false) as Label
		if ul:
			ul.add_theme_color_override("font_color", GOOD if ok else BAD)
