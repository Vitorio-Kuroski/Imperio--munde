class_name Eu4CountryView
extends Control
## Tela do país do EU4 (countryview.gui + countrycourtview.gui + countrygovernmentview.gui), no
## lugar do painel de texto do país:
##  - abas (countryview_tabs): Corte e Governo são desta tela; Tecnologia e Ideias abrem as janelas
##    do jogo; Diplomacia abre o resumo em texto (relações, guerras, instituições, economia);
##  - Corte: governante e herdeiro (idade, adm/dip/mil), conselheiros (retrato, nível, salário,
##    efeito; clicar abre a janela de conselheiros) e foco nacional;
##  - Governo: tipo de governo, reformas, cultura principal, culturas aceitas e as outras culturas
##    das províncias (com o desenvolvimento), religião, instituições adotadas e grupos de ideias.

signal shown(tag: String)
signal techs_requested(tag: String)
signal ideas_requested(tag: String)
signal advisors_requested(tag: String)
signal summary_requested(tag: String)
signal peace_requested(tag: String)     # "Negociar paz" na aba Diplomacia (main abre a tela de paz)
signal closed

const TABS := {"tab_court": "court", "tab_gov": "gov", "tab_economy": "economy", "tab_technology": "tech",
		"tab_ideas": "ideas", "tab_religion": "religion", "tab_stability": "stability",
		"tab_diplomacy": "summary"}
const TAB_TIPS := {"tab_court": "Corte", "tab_gov": "Governo", "tab_economy": "Economia", "tab_religion": "Religião", "tab_technology": "Tecnologia", "tab_ideas": "Ideias",
		"tab_stability": "Estabilidade e Expansão", "tab_diplomacy": "Diplomacia"}
const TAB_KEYS := {"tab_court": "HEADER_COURT", "tab_gov": "HEADER_GOVERNMENT", "tab_economy": "HEADER_ECONOMY",
		"tab_religion": "HEADER_RELIGION", "tab_technology": "HEADER_TECHNOLOGY", "tab_ideas": "HEADER_IDEAS",
		"tab_stability": "HEADER_STABILITY_EXPANSION", "tab_diplomacy": "HEADER_DIPLOMACY"}
const POWER_ICONS := {"adm": "GFX_icon_powers_administrative", "dip": "GFX_icon_powers_diplomatic",
		"mil": "GFX_icon_powers_military"}
const COURT_HIDE := ["abdicate_ruler_button", "extend_regency_button", "election_info", "monarch_heir_claim",
		"support_heir_button", "disinherit_button", "assign_heir_button", "queen_gender",
		"monarch_queen_name", "monarch_queen_age", "monarch_queen_adm_value", "monarch_queen_adm_icon",
		"monarch_queen_dip_value", "monarch_queen_dip_icon", "monarch_queen_mil_value", "monarch_queen_mil_icon",
		"monarch_queen_crown_icon", "monarch_queen_personality_list", "court_select"]
const GOV_HIDE := ["revolution_target_icon", "claim_revolution_icon", "claim_revolution_button", "government_change",
		"government_upgrade", "icon_government_desc_1", "government_desc_1", "icon_government_desc_2",
		"government_desc_2", "icon_government_desc_3", "government_desc_3", "strengthen_government",
		"absolutism_icon", "absolutism_value", "max_absolutism_icon", "max_absolutism_value",
		"revolutionary_zeal_icon", "revolutionary_zeal_value", "max_revolutionary_zeal_icon",
		"max_revolutionary_zeal_value", "revolution_spread_button", "revolution_spread_icon",
		"revolution_spread_bad_bar", "revolution_spread_good_bar", "revolution_spread_frame", "election_info",
		"accepted_sort_name_btn", "accepted_sort_union_btn", "accepted_sort_dev_btn", "non_accepted_sort_name_btn",
		"non_accepted_sort_brother_btn", "non_accepted_sort_dev_btn", "accepted_culture_slots",
		"assimilated_cultures_window", "modifier_view_button", "modifier_view", "bg_top"]
const GOV_FRAMES := {"monarchy": 0, "republic": 1, "theocracy": 2, "tribal": 3, "native": 4}

var gui: Eu4Gui
var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var advisors: Advisors
var institutions: Institutions
var religion: Religion            # main.gd define (conversão religiosa)
var fmt_mods: Callable              # efeitos -> texto (IdeasWindow.fmt_mods)
var player := ""                    # país do jogador (só ele pesquisa e compra ideias)
var tag := ""
var tab := "court"
var tech_tab: Eu4TechTab
var ideas_tab: Eu4IdeasTab
var economy_tab: Eu4EconomyTab
var religion_tab: Eu4ReligionTab
var diplomacy_tab: Eu4DiplomacyTab
var stability_tab: Eu4StabilityTab
var diplomacy: Diplomacy            # main.gd define (relações)
var diplo: DiploActions             # main.gd define (opiniões e ações diplomáticas)
var manpower: Manpower              # main.gd define (efetivo)
var prestige: Prestige              # main.gd define (prestígio)
var stability: Stability            # main.gd define (estabilidade)
var army: Army                      # main.gd define (exércitos)
var _tabs: Control
var _court: Control
var _gov: Control
var _pt := {}
var _select_cat := ""               # categoria aberta no "Select Advisor" ("" = fechado)


func setup(g: Eu4Gui, m: MapView, c: GameClock) -> bool:
	gui = g
	map = m
	clock = c
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_court = _open("countrycourtview")
	_gov = _open("countrygovernmentview")
	tech_tab = Eu4TechTab.new()
	if not tech_tab.setup(self):
		tech_tab = null
	economy_tab = Eu4EconomyTab.new()
	if not economy_tab.setup(self):
		economy_tab = null
	religion_tab = Eu4ReligionTab.new()
	if not religion_tab.setup(self):
		religion_tab = null
	diplomacy_tab = Eu4DiplomacyTab.new()
	if not diplomacy_tab.setup(self):
		diplomacy_tab = null
	stability_tab = Eu4StabilityTab.new()
	if not stability_tab.setup(self):
		stability_tab = null
	ideas_tab = Eu4IdeasTab.new()
	if ideas_tab.setup(self):
		ideas_tab.choose_group_requested.connect(func(t: String): ideas_requested.emit(t))
	else:
		ideas_tab = null
	_tabs = _open("countryview")         # por cima das telas (as abas ficam sobre a moldura)
	if _court == null or _gov == null or _tabs == null:
		return false
	for n in COURT_HIDE:
		_hide(_court, n)
	for n in GOV_HIDE:
		_hide(_gov, n)
	var pages := [_court, _gov]
	if tech_tab:
		pages.append(tech_tab.root)
	if ideas_tab:
		pages.append(ideas_tab.root)
	if economy_tab:
		pages.append(economy_tab.root)
	if religion_tab:
		pages.append(religion_tab.root)
	if diplomacy_tab:
		pages.append(diplomacy_tab.root)
	if stability_tab:
		pages.append(stability_tab.root)
	for v in pages:
		var close := v.find_child("close_button", true, false) as BaseButton
		if close:
			close.tooltip_text = Loc.t("CLOSE", "Fechar")
			close.pressed.connect(func():
				hide()
				closed.emit())
	# abas: as que o jogo tem; as outras somem
	var tw := _tabs.find_child("countryview_tabs", true, false)
	for b in (tw.get_children() if tw else []):
		if not (b is Eu4Gui.Button2):
			continue
		var n := String(b.name)
		if not TABS.has(n):
			b.hide()
			continue
		b.tooltip_text = Loc.t(TAB_KEYS[n], TAB_TIPS[n])
		var t: String = TABS[n]
		b.pressed.connect(func(): _on_tab(t))
	# o EU4 desenha o ganho mensal e a barra de pontos de cada linha fora da largura da lista (x 370–500)
	var abl := _court.find_child("abilities_listbox", true, false) as Control
	if abl:
		abl.clip_contents = false
	var back := _court.find_child("back_button", true, false) as BaseButton
	if back:
		back.pressed.connect(func():
			_select_cat = ""
			refresh())
	if not Loc.active():       # com a localização do EU4 os rótulos já vêm do .gui
		_txt(_gov, "accepted_cultures_label", "Culturas aceitas")
		_txt(_gov, "non_accepted_cultures_label", "Outras culturas")
		_txt(_gov, "modifiers_title", "Religião e instituições")
	if FileAccess.file_exists("res://data/governos_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/governos_pt.json"))
		if d is Dictionary:
			_pt = d
	hide()
	return true


## Monta a janela `name` na posição de aberta (show_position).
func _open(name: String) -> Control:
	var w := gui.find_window(name)
	if w.is_empty():
		return null
	var c := gui.build(name)
	if c == null:
		return null
	var sp := Eu4Gui._vec(w, "show_position")
	var sz := Eu4Gui._vec(w, "size")
	c.offset_left = sp.x
	c.offset_top = sp.y
	c.offset_right = sp.x + sz.x
	c.offset_bottom = sp.y + sz.y
	add_child(c)
	return c


## Altura do fundo de cada aba (590 px nas de tamanho fixo do EU4; a Religião usa o fundo _large
## ou _huge pela altura da tela, if_resolution). As abas menores são aumentadas por inteiro
## (`_fit_scale`) até a altura da Religião, em vez de esticar o fundo.
const PAGE_BG := ["GFX_court_view_bg", "GFX_economy_view_bg", "GFX_technology_view_bg",
		"GFX_country_ideas_view_bg", "GFX_local_government_view_bg", "GFX_country_religion_view_bg_large",
		"GFX_country_religion_view_bg_huge", "GFX_country_religion_view_bg",
		"GFX_country_diplomacy_view_bg_bottom_standard", "GFX_country_government_view_bg"]


func _bg_height(root: Control) -> float:
	var h := 0.0
	for ch in root.get_children():
		var ic := ch as Eu4Gui.Icon
		if ic and ic.visible and ic.sprite in PAGE_BG:
			h = maxf(h, ic.size.y)
	return h


## Escala da aba `page` para ficar com a altura da aba Religião; a barra de abas acompanha,
## tudo a partir do canto de cima da aba.
func _fit_scale(page: Control) -> void:
	var s := 1.0
	if religion_tab and page != religion_tab.root:
		var h := _bg_height(page)
		var target := _bg_height(religion_tab.root)
		if h > 0.0 and target > h:
			s = target / h
	for c in [page, _tabs]:
		c.pivot_offset = page.position - c.position
		c.scale = Vector2(s, s)


static func _hide(root: Control, n: String) -> void:
	var c := root.find_child(n, true, false) as Control
	if c:
		c.hide()


func _txt(root: Control, n: String, text: String, tip := "") -> void:
	var l := root.find_child(n, true, false) as Label
	if l:
		l.text = text
		Eu4Gui.fit_label(l)
		l.tooltip_text = tip
		if tip != "":
			l.mouse_filter = Control.MOUSE_FILTER_PASS


## Texto de um botão do EU4 (rótulo "Text" por cima; criado se o .gui não tiver).
func _set_button_text(b: Control, text: String) -> void:
	var l := b.get_node_or_null("Text") as Label
	if l == null:
		l = Label.new()
		l.name = "Text"
		l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gui.style_label(l, "vic_18")
		b.add_child(l)
	l.text = text


func _on_tab(t: String) -> void:
	match t:
		"court", "gov":
			tab = t
			refresh()
		"economy":
			if economy_tab:
				tab = t
				refresh()
		"religion":
			if religion_tab:
				tab = t
				refresh()
		"stability":
			if stability_tab and stability:
				tab = t
				refresh()
		"tech":
			if tech_tab:
				tab = t
				refresh()
			else:
				techs_requested.emit(tag)
		"ideas":
			if ideas_tab:
				tab = t
				refresh()
			else:
				ideas_requested.emit(tag)
		"summary":
			if diplomacy_tab and diplo:
				tab = "diplomacy"
				diplomacy_tab.mode = ""
				refresh()
			else:
				summary_requested.emit(tag)


## Mostra o país `t` (vazio esconde).
func show_country(t: String) -> void:
	tag = t
	if t == "" or not map.countries.has(t):
		hide()
		return
	show()
	refresh()
	shown.emit(t)


func refresh() -> void:
	if not visible or not map.countries.has(tag):
		return
	_court.visible = tab == "court"
	_gov.visible = tab == "gov"
	if tech_tab:
		tech_tab.root.visible = tab == "tech"
	if ideas_tab:
		ideas_tab.root.visible = tab == "ideas"
	if economy_tab:
		economy_tab.root.visible = tab == "economy"
	if religion_tab:
		religion_tab.root.visible = tab == "religion"
	if diplomacy_tab:
		diplomacy_tab.root.visible = tab == "diplomacy"
	if stability_tab:
		stability_tab.root.visible = tab == "stability"
	for pg in [_court, _gov, tech_tab.root if tech_tab else null, ideas_tab.root if ideas_tab else null,
			economy_tab.root if economy_tab else null, religion_tab.root if religion_tab else null,
			diplomacy_tab.root if diplomacy_tab else null, stability_tab.root if stability_tab else null]:
		if pg and pg.visible:
			_fit_scale(pg)
	var tw := _tabs.find_child("countryview_tabs", true, false)
	for n in TABS:
		var b := tw.find_child(n, false, false) as Eu4Gui.Button2 if tw else null
		if b and b.visible:
			b.set_frame(1 if TABS[n] == tab or (TABS[n] == "summary" and tab == "diplomacy") else 0)
	match tab:
		"court":
			_fill_court()
		"gov":
			_fill_gov()
		"tech":
			tech_tab.fill(tag)
		"ideas":
			ideas_tab.fill(tag)
		"economy":
			economy_tab.fill(tag)
		"religion":
			religion_tab.fill(tag)
		"diplomacy":
			diplomacy_tab.fill(tag)
		"stability":
			stability_tab.fill(tag)


func _gov_name(c: Dictionary) -> String:
	var gov: String = c.get("government", "")
	var name: String = _pt.get("governos", {}).get(gov, Eu4Importer.pretty_key(gov)) if gov != "" else ""
	var rank := str(_pt.get("postos", {}).get(str(c.get("rank", "")), ""))
	if Loc.active():
		name = Loc.t(gov + "_name", Loc.t(gov.to_upper(), name)) if gov != "" else ""
		rank = Loc.t("RANK_%s" % str(c.get("rank", "")), rank)
	return name + (" · " + rank if rank != "" else "")


func _age(person: Dictionary) -> int:
	var b := str(person.get("birth_date", "")).split(".")
	if b.size() < 3 or not b[0].is_valid_int():
		return -1
	var y := clock.year - int(b[0])
	if clock.month < int(b[1]) or (clock.month == int(b[1]) and clock.day < int(b[2])):
		y -= 1
	return y


func _person(prefix: String, p: Dictionary, title: String) -> void:
	var name := str(p.get("name", ""))
	if p.get("dynasty", "") != "":
		name += " " + str(p["dynasty"])
	_txt(_court, prefix + "_title" if prefix == "monarch" else prefix + "_name", (title + name).strip_edges())
	var age := _age(p)
	_txt(_court, prefix + ("_ruler_age" if prefix == "monarch" else "_age"), Loc.f("AGE", {"AGE": str(age)}, "Idade: %d" % age)
			if age >= 0 else "")
	for cat in ["adm", "dip", "mil"]:
		_txt(_court, "%s_%s_value" % [prefix, cat], str(int(p.get(cat, 0))) if p.has(cat) else "")


func _fill_court() -> void:
	var c: Dictionary = map.countries[tag]
	_txt(_court, "window_title", Loc.t("HEADER_COURT", "Corte"), c["name"])
	var m: Dictionary = c.get("monarch", {})
	# título do governante como no EU4 (government_names: ruler_male; "King", "Král"...) e regência
	var rt := diplomacy_tab.gov_title(tag, "ruler_male") if diplomacy_tab else ""
	var regency := Eu4DiplomacyTab.is_regency(tag) or str(m.get("name", "")) == ""
	_person("monarch", m, "" if regency else (rt + " " if rt != "" else ""))
	if regency:
		_txt(_court, "monarch_title", (str(m.get("name", "")) + " " + Loc.t("INTERREGNUM", "(Interregno)")).strip_edges())
	_show_in(_court, "monarch_gender", true)
	var heir: Dictionary = c.get("heir", {})
	for n in ["monarch_heir_adm_value", "monarch_heir_adm_icon", "monarch_heir_dip_value", "monarch_heir_dip_icon",
			"monarch_heir_mil_value", "monarch_heir_mil_icon", "monarch_heir_crown_icon", "monarch_heir_age"]:
		var x := _court.find_child(n, true, false) as Control
		if x:
			x.visible = not heir.is_empty()
	_show_in(_court, "heir_gender", not heir.is_empty())
	if heir.is_empty():
		_txt(_court, "monarch_heir_name", Loc.t("NO_HEIR", "Sem herdeiro legítimo"))
	else:
		_person("monarch_heir", heir, Loc.t("HEIR", "Herdeiro") + ": ")
	# consorte (o jogo ainda não tem: "No Consort", como o EU4 sem consorte)
	_show_in(_court, "monarch_queen_name", true)
	_txt(_court, "monarch_queen_name", Loc.s("Sem consorte", "No Consort"))
	for n in ["monarch_queen_age", "monarch_queen_adm_value", "monarch_queen_adm_icon", "monarch_queen_dip_value",
			"monarch_queen_dip_icon", "monarch_queen_mil_value", "monarch_queen_mil_icon", "monarch_queen_crown_icon",
			"queen_gender"]:
		_show_in(_court, n, false)
	_fill_select()
	# conselheiros (uma linha por categoria)
	var list := _court.find_child("abilities_listbox", true, false) as Control
	var rows := gui.fill_list(list, "countrycourtview_abilitylistitem", Advisors.CATS.size() if advisors else 0)
	for i in rows.size():
		_advisor_row(rows[i], Advisors.CATS[i])
	# foco nacional
	var focus := str(c.get("national_focus", "")).to_upper()
	for cat in ["ADM", "DIP", "MIL"]:
		var b := _court.find_child("national_focus_" + cat, true, false) as Eu4Gui.Button2
		if b:
			b.set_frame(1 if focus == cat else 0)
			b.tooltip_text = Loc.s("Foco nacional: %s", "National focus: %s") % (Loc.s({"ADM": "administrativo",
					"DIP": "diplomático", "MIL": "militar"}[cat], Loc.t(cat + "_POWER", cat))) \
					+ (Loc.s(" (atual)", " (current)") if focus == cat else "")
		if power and power.state.has(tag):
			var ic := _court.find_child("icon_" + cat, true, false) as Control
			if ic:
				ic.tooltip_text = Loc.s("%d pontos (+%d por mês)", "%d points (+%d per month)") % [power.points(tag, cat.to_lower()),
						power.gain(tag, cat.to_lower())]


func _advisor_row(row: Control, cat: String) -> void:
	for n in ["advisor_activefor", "advisor_sack", "advisor_promote",
			"advisor_indicator_religion", "advisor_indicator_religion_icon", "advisor_indicator_culture"]:
		_hide(row, n)
	# à direita, como no EU4: ganho mensal de pontos e a barra com os pontos ("70 Power")
	if power and power.state.has(tag):
		var pts := power.points(tag, cat)
		_txt(row, "ability_skill", str(power.gain(tag, cat)), Loc.s("Pontos por mês", "Points per month"))
		_txt(row, "power", Loc.f("CV_COURT_POWER", {"POWER": str(pts)}, "%d pontos" % pts))
		var pb := row.find_child("power_progress", true, false) as Eu4Gui.Progress
		if pb:
			pb.set_value(float(pts) / float(MonarchPower.MAX_POINTS))
	var a := advisors.get_hired(tag, cat)
	var btn := row.find_child("advisor_button", true, false) as Eu4Gui.Button2
	var icon := row.find_child("advisor_skill_icon", true, false) as Eu4Gui.Icon
	if icon and gui.sprites.has(POWER_ICONS[cat]):
		icon.set_sprite(gui, POWER_ICONS[cat], 0)
	var mods := row.find_child("advisor_modifier_listbox", true, false) as Control
	if mods:
		mods.offset_right = mods.offset_left + 270     # o efeito cabe numa linha
	if a.is_empty():
		_txt(row, "advisor_name", Loc.t("NO_ADVISOR", "Sem conselheiro"))
		_txt(row, "advisor_ability_skill", "")
		_txt(row, "advisor_cost", "")
		gui.fill_list(mods, "advisor_modifier_item", 0)
	else:
		var t: Dictionary = advisors.types.get(a["type"], {})
		_txt(row, "advisor_name", str(a["name"]), str(t.get("name", a["type"])))
		_txt(row, "advisor_ability_skill", str(int(a["skill"])))
		_txt(row, "advisor_cost", Loc.s("%s · %s ducados/mês", "%s · %s ducats/month") % [t.get("name", a["type"]),
				AdvisorsWindow._n(advisors.salary(tag, a))])
		var items := gui.fill_list(mods, "advisor_modifier_item", 1)
		if not items.is_empty():
			_hide(items[0], "advisor_modifier_icon")
			_txt(items[0], "advisor_desc", str(fmt_mods.call(t.get("modifiers", {}))) if fmt_mods.is_valid() else "")
	if btn:
		var tex := map.icon_texture("advisor:" + a["type"]) if not a.is_empty() else null
		if tex:
			btn.texture_normal = tex
			btn.texture_hover = null
			btn.texture_pressed = null
			btn.texture_click_mask = null
		else:
			btn.setup(gui, "GFX_advisor_noAdvisorType")
		btn.tooltip_text = Loc.t("LEDGER_ADVISORS", "Conselheiros")
		for cn in btn.pressed.get_connections():
			btn.pressed.disconnect(cn["callable"])
		btn.pressed.connect(func():          # "Select Advisor" do EU4 na própria aba (só o jogador contrata)
			if tag == player:
				_select_cat = cat
				refresh()
			else:
				advisors_requested.emit(tag))


## "Select Advisor" (court_select) dentro da aba Corte: os candidatos da categoria com retrato,
## nível, efeito, salário mensal, idade e onde nasceram; clicar contrata; Back volta.
func _fill_select() -> void:
	var sel := _court.find_child("court_select", true, false) as Control
	if sel == null:
		return
	sel.visible = _select_cat != "" and advisors != null
	if not sel.visible:
		return
	var cands: Array = advisors.candidates(tag, _select_cat)
	var list := sel.find_child("court_select_slider", true, false) as Control
	var rows := gui.fill_list(list, "advisor_selection_entry", cands.size())
	_show_in(sel, "no_advisors_label", cands.is_empty())
	for i in rows.size():
		var a: Dictionary = cands[i]
		var row: Control = rows[i]
		var t: Dictionary = advisors.types.get(a["type"], {})
		for n in ["advisor_indicator_religion", "advisor_indicator_religion_icon", "advisor_indicator_culture",
				"purchase", "purchase_cost", "effect_icon"]:
			_hide(row, n)
		_txt(row, "name", str(a["name"]), str(t.get("name", a["type"])))
		_txt(row, "skill_value", str(int(a["skill"])))
		for c2 in ["ADM", "DIP", "MIL"]:
			_show_in(row, "skill_icon_" + c2, c2.to_lower() == _select_cat)
		_txt(row, "effect", str(fmt_mods.call(t.get("modifiers", {}))) if fmt_mods.is_valid() else "")
		_txt(row, "title", AdvisorsWindow._n(advisors.salary(tag, a)) + " " + Loc.s("por mês", "monthly"))
		_txt(row, "value", "")
		_txt(row, "desc", Loc.f("AGE", {"AGE": str(int(a.get("age", 0)))}, "Idade: %d" % int(a.get("age", 0))) if a.has("age") else "")
		var loc := int(a.get("location", -1))
		_txt(row, "home", (Loc.s("Nascido em %s.", "Born in %s.") % map.provinces[loc]["name"]) if loc >= 0 and loc < map.provinces.size() else "")
		var pic := row.find_child("advisor_button", true, false) as Eu4Gui.Button2
		if pic:
			var tex := map.icon_texture("advisor:" + a["type"])
			if tex:
				pic.texture_normal = tex
				pic.texture_hover = null
				pic.texture_pressed = null
				pic.texture_click_mask = null
			pic.tooltip_text = str(t.get("name", a["type"]))
		var hire := row.find_child("dismiss_button", true, false) as BaseButton   # a porta da direita contrata
		var why := "" if economy == null or economy.money(tag) >= advisors.salary(tag, a) \
				else Loc.s("Dinheiro insuficiente", "Not enough money")
		for b in [hire, pic]:
			if b == null:
				continue
			for cn in b.pressed.get_connections():
				b.pressed.disconnect(cn["callable"])
			b.disabled = why != ""
			b.pressed.connect(func():
				if advisors.hire(tag, _select_cat, i):
					_select_cat = ""
				refresh())
		if hire:
			hire.tooltip_text = Loc.s("Contratar", "Hire") + (("\n" + why) if why != "" else "")


func _show_in(root: Control, n: String, on: bool) -> void:
	var c := root.find_child(n, true, false) as Control
	if c:
		c.visible = on


func _culture_name(cid: String) -> String:
	return map.cultures[cid]["name"] if map.cultures.has(cid) else Eu4Importer.pretty_key(cid)


func _fill_gov() -> void:
	var c: Dictionary = map.countries[tag]
	_txt(_gov, "window_title", c["name"])
	var gi := _gov.find_child("government_type_icon", true, false) as Eu4Gui.Icon
	if gi:
		gi.set_frame(int(GOV_FRAMES.get(str(c.get("government", "")), 0)))
	_txt(_gov, "government_name", _gov_name(c))
	# reformas na lista do meio
	var list := _gov.find_child("specific_governments_list", true, false) as Control
	var vb := list.get_node_or_null("Items") if list else null
	if vb:
		for ch in vb.get_children():
			vb.remove_child(ch)
			ch.queue_free()
		for r in c.get("reforms", []):
			var l := Label.new()
			gui.style_label(l, "vic_18")
			l.text = "• " + Loc.t(r, str(_pt.get("reformas", {}).get(r, Eu4Importer.pretty_key(r, "_reform"))))
			vb.add_child(l)
	var pc: String = c.get("primary_culture", "")
	_txt(_gov, "monarch_cultures", Loc.t("HINT_PRIMARYCULTURE_TITLE", "Cultura principal") + ": " + _culture_name(pc) if pc != "" else "")
	# culturas: aceitas e as outras presentes nas províncias, com o desenvolvimento
	var dev := {}
	for p in map.provinces:
		if p["owner"] == tag and p.get("culture", "") != "":
			dev[p["culture"]] = int(dev.get(p["culture"], 0)) + int(p["development"])
	var acc := [pc] + Array(c.get("accepted_cultures", []))
	var others := []
	for cid in dev:
		if not (cid in acc):
			others.append(cid)
	others.sort_custom(func(a, b): return dev[a] > dev[b])
	_culture_list("accepted_cultures_listbox", acc.filter(func(x): return x != ""), dev)
	_culture_list("non_accepted_cultures_listbox", others, dev)
	# religião, instituições adotadas e grupos de ideias nas faixas de modificadores
	var boxes := []
	for i in range(1, 5):
		var b := _gov.find_child("modifiers_box_%d" % i, true, false) as Control
		if b:
			for ch in b.get_children():
				b.remove_child(ch)
				ch.queue_free()
			boxes.append(b)
	if boxes.is_empty():
		return
	var rid: String = c.get("religion", "")
	var rtip := Loc.t("RELIGION", "Religião") + ": " + str(map.religions.get(rid, {}).get("name", rid))
	if gui.sprites.has("GFX_country_icon_religion"):      # ícone de religião do país do EU4
		var ri := Eu4Gui.Icon.new()
		ri.set_sprite(gui, "GFX_country_icon_religion", 0)
		ri.set_religion(map.religions.get(rid, {}))
		ri.tooltip_text = rtip
		ri.custom_minimum_size = Vector2(34, 34)
		ri.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if ri.visible:
			boxes[0].add_child(ri)
		else:
			ri.free()
	if boxes[0].get_child_count() == 0:
		var rt := map.icon_texture("religion:" + rid)
		if rt:
			boxes[0].add_child(MapView.icon_rect(rt, 30, rtip))
	if institutions and institutions.enabled() and boxes.size() > 1:
		for inst in institutions.list:
			if institutions.has_embraced(tag, inst["id"]):
				var t := map.icon_texture("inst:" + inst["id"])
				if t:
					boxes[1].add_child(MapView.icon_rect(t, 30, inst["name"] + Loc.s(" (adotada)", " (embraced)")))
	if power and boxes.size() > 2:
		var k := 2
		for g in power.adopted(tag):
			var t := map.icon_texture("group:" + g["id"])
			if t and k < boxes.size():
				boxes[k].add_child(MapView.icon_rect(t, 30, "%s %d/7" % [power.idea_groups[g["id"]]["name"], int(g["n"])]))
				if boxes[k].get_child_count() >= 5:
					k += 1


func _culture_list(n: String, ids: Array, dev: Dictionary) -> void:
	var list := _gov.find_child(n, true, false) as Control
	var rows := gui.fill_list(list, "gov_view_cultureviewitem", ids.size())
	for i in rows.size():
		for h in ["acceptance_level_icon", "select_button", "promote_button", "demote_button"]:
			_hide(rows[i], h)
		var cid: String = ids[i]
		var grp := str(map.cultures.get(cid, {}).get("group", ""))
		_txt(rows[i], "name", _culture_name(cid), Loc.t("GROUP", "Grupo") + ": " + Loc.t(grp, grp) if grp != "" else "")
		_txt(rows[i], "dev", str(dev.get(cid, 0)))
