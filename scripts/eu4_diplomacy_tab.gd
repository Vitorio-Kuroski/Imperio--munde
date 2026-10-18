class_name Eu4DiplomacyTab
extends RefCounted
## Aba Diplomacia da tela do país do EU4 (countrydiplomacyview.gui):
##  - topo: escudo, religião, nome, governo, Sacro Império, governante e herdeiro (adm/dip/mil),
##    tecnologias, ideias compradas, culturas aceitas, desenvolvimento, corrupção e as opiniões
##    entre o país e o jogador (dica com os modificadores);
##  - relações (diplomatic_listbox): aliados, casamentos reais, súditos, suserano, garantias e
##    relações sendo melhoradas, cada linha com os escudos dos países (clicar abre o país);
##  - à direita, num país que não é o do jogador, as ações diplomáticas (DiploActions) com o ícone
##    e a seta de "aceitaria/recusaria" (dica com os motivos); no país do jogador, a opinião dos
##    outros países sobre ele.
## O que o jogo ainda não tem (rivais, espiões, confiança, favores,
## exércitos) fica escondido.

const HIDE := ["secondary_religion_icon", "religious_school_icon", "countryshield_glow", "num_relations_bg",
		"num_relations_value", "num_relations_icon", "reputation_bg", "reputation_icon", "reputation_value",
		"personality_icons_strip", "policies_icon", "policies_value", "revanchism_icon", "revanchism_value",
		"spy_icon", "spy_value", "land_forcelimit_value", "land_forcelimit_icon", "naval_forcelimit_value",
		"naval_forcelimit_icon",
		"techgroup_icon", "election_info", "label_enemies", "enemies_box",
		"label_rivals", "rivals_box", "label_rivals_not_possible", "sort_search", "sort_search_edit", "sort_name",
		"sort_opinion", "sort_opinion_1", "sort_opinion_2", "sort_opinion_3", "sort_opinion_4", "sort_opinion_5",
		"show_diplofeedback", "button_createvassals", "feedback_bg", "trust_label", "diplomacy_trust_progress_bar",
		"diplomacy_trust_progress_frame", "diplomacy_trust_progress_indicator", "trust_value", "favors_label",
		"diplomacy_favors_progress_bar", "diplomacy_favors_progress_frame", "diplomacy_favors_progress_indicator",
		"favors_value", "button_view_player_country", "provincelist_label", "provincelist_desc", "provincelist",
		"join_offensive_wars_checkbox", "manual_manage_label", "manual_manage_checkbox", "neutral_icon",
		"neutral_label", "neutral_checkbox", "friendly_icon", "friendly_label", "friendly_checkbox", "hostile_icon",
		"hostile_label", "hostile_checkbox", "threatened_icon", "threat_label", "threat_checkbox",
		"vassal_select_window", "select_rivals_window", "monarch_gender", "heir_gender", "attitude_icons_strip",
		"attitude_icons_strip02", "member_of_HRE"]
## Ação -> [chave da localização, nome em português, ícone]
const ACTIONS := {"improve": ["IMPROVERELATIONTITLE", "Melhorar relações", "GFX_diplomacy_action_relation"],
		"alliance": ["ALLIANCETITLE", "Propor aliança", "GFX_diplomacy_action_alliance"],
		"royal_marriage": ["RMTITLE", "Casamento real", "GFX_diplomacy_action_dynasty"],
		"guarantee": ["", "Garantir independência", "GFX_diplomacy_action_influence"],
		"break_alliance": ["BREAKALLIANCETITLE", "Romper aliança", "GFX_diplomacy_action_alliance"],
		"break_marriage": ["", "Romper casamento real", "GFX_diplomacy_action_dynasty"],
		"insult": ["INSULTTITLE", "Enviar um insulto", "GFX_diplomacy_action_relation"],
		"declare_war": ["", "Declarar guerra", "GFX_diplomacy_action_declarewar"],
		"white_peace": ["", "Negociar paz", "GFX_diplomacy_action_requestpeace"]}
const GOOD := Color(0.55, 0.9, 0.45)
const BAD := Color(1.0, 0.42, 0.35)

var view: Eu4CountryView
var root: Control
var mode := ""                      # "actions" ou "opinions" ("" = conforme o país)
var last_message := ""


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countrydiplomacyview")
	if root == null:
		return false
	for n in HIDE:
		Eu4CountryView._hide(root, n)
	var ba := root.find_child("show_diploactions", true, false) as BaseButton
	if ba:
		ba.tooltip_text = Loc.s("Ações diplomáticas", "Diplomatic actions")
		ba.pressed.connect(func():
			mode = "actions"
			view.refresh())
	var bo := root.find_child("show_opinions", true, false) as BaseButton
	if bo:
		bo.tooltip_text = Loc.t("OPINION", "Opinião")
		bo.pressed.connect(func():
			mode = "opinions"
			view.refresh())
	var sh := root.find_child("countryshield", true, false) as BaseButton
	if sh:
		sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return true


func _flag_tex(t: String) -> Texture2D:
	var ft := view.map.flag_texture(t)
	var img := ft.get_image() if ft else null
	return ImageTexture.create_from_image(img) if img else null


func _num(x: float) -> String:
	return ("%+d" % roundi(x))


func fill(tag: String) -> void:
	var map := view.map
	var c: Dictionary = map.countries[tag]
	var dip := view.diplo
	var d := view.diplomacy
	var player := view.player
	view._txt(root, "window_title", Loc.t("HEADER_DIPLOMACY", "Diplomacia") + " — " + c["name"])
	var sh := root.find_child("countryshield", true, false) as Eu4Gui.Button2
	if sh:
		sh.set_flag(_flag_tex(tag))
	var ri := root.find_child("religion_icon", true, false) as Eu4Gui.Icon
	if ri:
		ri.set_religion(map.religions.get(c.get("religion", ""), {}))
	view._txt(root, "label_nation", c["name"])
	view._txt(root, "label_fog", view._gov_name(c))
	var rank := root.find_child("government_rank", true, false) as Eu4Gui.Icon
	if rank:
		rank.set_frame(clampi(int(c.get("rank", 1)) - 1, 0, 2))
		rank.tooltip_text = Loc.t("RANK_%d" % int(c.get("rank", 1)), "")
	var hre := root.find_child("member_of_HRE", true, false) as Control
	if hre and d:
		hre.visible = d.in_hre(tag)
		hre.tooltip_text = Loc.t("HINT_HRE_TITLE", "Sacro Império")
	# governante e herdeiro
	var m: Dictionary = c.get("monarch", {})
	view._txt(root, "label_ruler", (str(m.get("name", "")) + " " + str(m.get("dynasty", ""))).strip_edges())
	for cat in ["adm", "dip", "mil"]:
		view._txt(root, "ruler_%s_value" % cat, str(m.get(cat, "")))
	var heir: Dictionary = c.get("heir", {})
	view._txt(root, "monarch_heir_label", Loc.t("HEIR", "Herdeiro") + ":" if not heir.is_empty() else "")
	view._txt(root, "monarch_heir_name", (str(heir.get("name", "")) + " " + str(heir.get("dynasty", ""))).strip_edges())
	view._txt(root, "monarch_heir_info", ("%s/%s/%s" % [heir.get("adm", ""), heir.get("dip", ""), heir.get("mil", "")]) \
			if not heir.is_empty() else "")
	# números do país
	var pw := view.power
	if pw and pw.state.has(tag):
		for cat in ["adm", "dip", "mil"]:
			view._txt(root, cat + "_value", str(pw.tech(tag, cat)), Loc.s("Nível de tecnologia", "Technology level"))
		var n := 0
		for g in pw.adopted(tag):
			n += int(g["n"])
		view._txt(root, "ideas_value", str(n), Loc.s("Ideias compradas", "Ideas bought"))
	view._txt(root, "cultures_value", str(1 + c.get("accepted_cultures", []).size()),
			Loc.t("HINT_ACCEPTCULTURE_TITLE", "Culturas aceitas"))
	if view.manpower:
		view._txt(root, "manpower_value", Manpower.fmt(view.manpower.of(tag)), Loc.s("Efetivo: %s de %s",
				"Manpower: %s of %s") % [Manpower.fmt(view.manpower.of(tag)), Manpower.fmt(view.manpower.max_of(tag))])
		var ml := root.find_child("manpower_value", true, false) as Control
		if ml:
			ml.z_index = 1        # "116k" passa por cima da borda do ícone (que vem depois no .gui)
	if view.stability:
		view._txt(root, "stability_value", Stability.fmt(view.stability.of(tag)), view.stability.tooltip(tag))
	if view.prestige:
		view._txt(root, "prestige_value", str(roundi(view.prestige.of(tag))), view.prestige.tooltip(tag))
	if view.economy:
		view._txt(root, "score_value", str(int(view.economy.development(tag))), Loc.t("DEVELOPMENT_TEXT", "Desenvolvimento"))
		view._txt(root, "corruption_value", (("%.1f" % view.economy.corruption_of(tag)).replace(".", Loc.dec)),
				Loc.t("corruption", "Corrupção"))
	# opiniões entre o país e o jogador
	var rel_vis := dip != null and dip.enabled() and player != "" and player != tag
	for n in ["relation_bg", "relation_value", "relation_bg_2", "relation_value_2", "improve_relation_icon",
			"improve_relation_bg", "improve_relation_value"]:
		var x := root.find_child(n, true, false) as Control
		if x:
			x.visible = rel_vis
	if rel_vis:
		var o1 := dip.opinion(tag, player)
		var o2 := dip.opinion(player, tag)
		_value(root, "relation_value", _num(o1), o1, Loc.f("OPINIONOF", {"WHO_ADJ": c["name"], "NAME": map.countries[player]["name"]},
				"Opinião de %s sobre %s:" % [c["name"], map.countries[player]["name"]]) + "\n" \
				+ DiploActions.breakdown_text(dip.breakdown(tag, player)))
		_value(root, "relation_value_2", _num(o2), o2, Loc.f("OPINIONOF", {"WHO_ADJ": map.countries[player]["name"],
				"NAME": c["name"]}, "Opinião de %s sobre %s:" % [map.countries[player]["name"], c["name"]]) + "\n" \
				+ DiploActions.breakdown_text(dip.breakdown(player, tag)))
		var imp: float = dip.timed.get(tag + ">" + player, {}).get("improved_relation", [0.0])[0]
		view._txt(root, "improve_relation_value", _num(imp), Loc.t("IMPROVE_RELATION_MODIFIER", "Relações melhoradas"))
	_fill_relations(tag)
	var m2 := mode if mode != "" else ("opinions" if tag == player else "actions")
	if tag == player or not rel_vis:
		m2 = "opinions"
	var al := root.find_child("diploaction_list", true, false) as Control
	var ol := root.find_child("diploopinion_list", true, false) as Control
	if al:
		al.visible = m2 == "actions"
	if ol:
		ol.visible = m2 == "opinions"
		if not ol.has_meta("tall") and al:       # a lista de opiniões ocupa o lugar das duas
			ol.set_meta("tall", true)
			ol.offset_top = al.offset_top
	for n in ["show_diploactions", "show_opinions"]:
		var b := root.find_child(n, true, false) as Eu4Gui.Button2
		if b:
			b.visible = rel_vis
			b.set_frame(1 if (n == "show_diploactions") == (m2 == "actions") else 0)
	if m2 == "actions":
		_fill_actions(tag)
	else:
		_fill_opinions(tag)


func _value(r: Control, n: String, text: String, v: float, tip: String) -> void:
	view._txt(r, n, text, tip)
	var l := r.find_child(n, true, false) as Label
	if l:
		l.add_theme_color_override("font_color", GOOD if v > 0 else (BAD if v < 0 else Color.WHITE))


func _fill_relations(tag: String) -> void:
	var d := view.diplomacy
	var list := root.find_child("diplomatic_listbox", true, false) as Control
	if d == null or list == null:
		return
	var rows := []          # [ícone, texto, países]
	if view.diplo and view.diplo.war:
		rows.append(["GFX_diplomacy_war", Loc.s("Em guerra com", "At war with"), view.diplo.war.enemies_of(tag)])
	rows.append(["GFX_diplomacy_alliances", Loc.t("LEDGER_ALLIES", "Aliados"), d.allies(tag)])
	rows.append(["GFX_diplomacy_royalmarriage", Loc.t("royal_marriage", "Casamentos reais"), d.marriages(tag)])
	var subs := []
	for s in d.subjects(tag):
		subs.append(s[0])
	rows.append(["GFX_diplomacy_leadvassal", Loc.t("HEADER_SUBJECTS", "Súditos"), subs])
	var ov := d.overlord(tag)
	rows.append(["GFX_diplomacy_amvassal", Loc.t("HEADER_OVERLORD", "Suserano"), [ov[0]] if ov.size() > 0 else []])
	rows.append(["GFX_diplomacy_guaranting", Loc.t("GUARANTEEING", "Garantindo"), d.guarantees(tag)])
	rows.append(["GFX_diplomacy_guaranteed", Loc.s("Garantido por", "Guaranteed by"), d.guarantors(tag)])
	if view.diplo:
		rows.append(["GFX_diplomacy_we_increase_relation", Loc.t("MACRO_IMPROVE_RELATIONS", "Melhorando relações"),
				view.diplo.improving.get(tag, [])])
	rows = rows.filter(func(r): return not (r[2] as Array).is_empty())
	var items := view.gui.fill_list(list, "countrydiplomacyview_diplistitem", rows.size())
	for i in items.size():
		var row: Control = items[i]
		var ic := row.find_child("icon", true, false) as Eu4Gui.Icon
		if ic:
			if view.gui.sprites.has(rows[i][0]):
				ic.set_sprite(view.gui, rows[i][0], 0)
			ic.tooltip_text = rows[i][1]
		view._txt(row, "infotext", "")
		var box := row.find_child("box", true, false) as Control
		if box == null:
			continue
		for t in rows[i][2]:
			if not view.map.countries.has(t):
				continue
			var holder := view.gui.build("countrydiplomacyview_shielditem")
			if holder == null:
				continue
			holder.custom_minimum_size = Vector2(28, 32)
			box.add_child(holder)
			var s := holder.find_child("shield", true, false) as Eu4Gui.Button2
			if s:
				s.set_flag(_flag_tex(t))
				s.tooltip_text = "%s: %s" % [rows[i][1], view.map.countries[t]["name"]]
				var tt: String = t
				s.pressed.connect(func(): view.show_country(tt))


func _fill_actions(tag: String) -> void:
	var dip := view.diplo
	var list := root.find_child("diploaction_list", true, false) as Control
	var player := view.player
	var ids := []
	for a in DiploActions.ACTIONS:
		# romper só aparece quando há o que romper; insultar/garantir/aliança sempre
		if a == "break_alliance" and not (tag in view.diplomacy.allies(player)):
			continue
		if a == "break_marriage" and not (tag in view.diplomacy.marriages(player)):
			continue
		if a == "alliance" and tag in view.diplomacy.allies(player):
			continue
		if a == "royal_marriage" and tag in view.diplomacy.marriages(player):
			continue
		var at_war: bool = dip.war != null and dip.war.hostile(player, tag)
		if (a == "declare_war" and at_war) or (a == "white_peace" and not at_war):
			continue
		if at_war and a in ["improve", "alliance", "royal_marriage", "guarantee", "insult"]:
			continue
		ids.append(a)
	var rows := view.gui.fill_list(list, "diploactionentry", ids.size())
	for i in rows.size():
		var a: String = ids[i]
		var row: Control = rows[i]
		var info: Array = ACTIONS[a]
		var name := Loc.t(info[0], info[1]) if info[0] != "" else Loc.s(info[1], {"guarantee": "Guarantee Independence",
				"break_marriage": "Break Royal Marriage", "white_peace": "Sue for Peace",
				"declare_war": "Declare War"}.get(a, info[1]))
		if a == "improve" and dip.is_improving(player, tag):
			name = Loc.t("RECALL", "Chamar de volta") + " — " + Loc.t("MACRO_IMPROVE_RELATIONS", "Melhorar relações")
		var btn := row.find_child("button_diploaction", true, false) as BaseButton
		if btn:
			view._set_button_text(btn, name)
			var l := btn.get_node_or_null("Text") as Label
			if l:
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				l.offset_left = 26
		var ic := row.find_child("action_icon", true, false) as Eu4Gui.Icon
		if ic and view.gui.sprites.has(info[2]):
			ic.set_sprite(view.gui, info[2], 0)
		var cbi := row.find_child("cb_list_icon", true, false) as Control
		var cb_list: Array = dip.cbs.available(player, tag) if a == "declare_war" and dip.cbs else []
		if cbi:
			cbi.visible = not cb_list.is_empty()
		var dico := row.find_child("diplomat", true, false) as Control
		if dico:
			dico.visible = a == "improve"
		var why := dip.why_not(a, player, tag)
		var tip := name
		var acc := row.find_child("ai_accept", true, false) as Eu4Gui.Icon
		if a in ["alliance", "royal_marriage", "white_peace"]:
			var score := dip.acceptance_score(a, player, tag)
			var lines := []
			for x in dip.acceptance(a, player, tag):
				lines.append("%s: %+d" % [x[0], int(x[1])])
			tip += "\n" + "\n".join(lines) + "\n" + (Loc.s("Aceitaria (%+d)", "Would accept (%+d)") % score if score > 0 \
					else Loc.s("Recusaria (%+d)", "Would decline (%+d)") % score)
			if acc:
				acc.visible = true
				acc.set_frame(0 if score > 0 else 1)
		elif acc:
			acc.hide()
		if a == "improve":
			tip += "\n" + Loc.s("Diplomatas livres: %d/%d · +%s por mês", "Free diplomats: %d/%d · +%s per month") % [
					dip.free_diplomats(player), dip.diplomats(player), ("%.1f" % dip.improve_rate(player)).replace(".", Loc.dec)]
		if a == "declare_war" and dip.cbs:
			if cb_list.is_empty():
				tip += "\n" + Loc.s("Sem casus belli: declarar custa %d de estabilidade", "No casus belli: declaring costs %d stability") \
						% -CasusBelli.NO_CB_STABILITY
			else:
				tip += "\n" + Loc.s("Casus belli: ", "Casus belli: ") + ", ".join(cb_list.map(func(c): return CasusBelli.name_of(c))) \
						+ "\n" + Loc.s("Será usado: %s", "Will use: %s") % CasusBelli.name_of(cb_list[0])
		if why != "":
			tip += "\n" + why
		if btn:
			btn.disabled = why != ""
			btn.modulate = Color.WHITE if why == "" else Color(0.6, 0.6, 0.6)
			btn.tooltip_text = tip
			for cn in btn.pressed.get_connections():
				btn.pressed.disconnect(cn["callable"])
			btn.pressed.connect(func():
				if a == "white_peace" and not view.peace_requested.get_connections().is_empty():
					view.peace_requested.emit(tag)      # abre a tela de paz do EU4
					return
				last_message = dip.act(a, player, tag)
				view.refresh())
	var status := root.find_child("label_rivals_not_possible", true, false) as Label
	if status:
		status.visible = last_message != ""
		status.text = last_message


## Opinião dos outros países sobre `tag` (os de relação mais forte primeiro).
func _fill_opinions(tag: String) -> void:
	var dip := view.diplo
	var list := root.find_child("diploopinion_list", true, false) as Control
	if dip == null or list == null:
		return
	var others := []
	for t in view.map.countries:
		if t == tag or view.economy.development(t) <= 0.0:
			continue
		var o := dip.opinion(t, tag)
		if o != 0:
			others.append([t, o])
	others.sort_custom(func(x, y): return absi(x[1]) > absi(y[1]))
	others = others.slice(0, 40)
	var rows := view.gui.fill_list(list, "countryactionentry", others.size())
	for i in rows.size():
		var t: String = others[i][0]
		var row: Control = rows[i]
		view._txt(row, "country_name", str(view.map.countries[t]["name"]))
		_value(row, "country_opinion", _num(others[i][1]), others[i][1], DiploActions.breakdown_text(dip.breakdown(t, tag)))
		view._txt(row, "country_opinion_2", "")
		var f := row.find_child("country_flag", true, false) as TextureButton
		if f:
			var ft := view.map.flag_texture(t)
			if ft:
				f.texture_normal = ft
				f.texture_hover = null
				f.texture_pressed = null
				f.texture_click_mask = null
				f.ignore_texture_size = true
				f.stretch_mode = TextureButton.STRETCH_SCALE
		var b := row.find_child("button_diploaction", true, false) as BaseButton
		if b:
			var tt := t
			for cn in b.pressed.get_connections():
				b.pressed.disconnect(cn["callable"])
			b.pressed.connect(func(): view.show_country(tt))
			b.tooltip_text = str(view.map.countries[t]["name"])
