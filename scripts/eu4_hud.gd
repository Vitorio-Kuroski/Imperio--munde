class_name Eu4Hud
extends Control
## Interface do EU4 montada com os .gui do jogo do usuário (Eu4Gui): barra superior (topbar.gui:
## escudo com a bandeira, nome do país, tesouro, pontos de monarca), data e velocidade
## (speed_controls.gui) e botões dos modos de mapa e de zoom (minimappanel.gui). Substitui a barra
## superior simples do main.gd quando as telas foram importadas.

signal shield_pressed
signal build_pressed                 # botão "construir" (martelo e espada) sob o escudo
signal zoom_requested(factor: float)

## Botões custom_mapmode_N do minimappanel.gui -> modo de mapa e sprite do EU4.
const MAPMODES := [[MapView.MapMode.POLITICO, "GFX_mapmode_political"], [MapView.MapMode.TERRENO, "GFX_mapmode_terrain"],
		[MapView.MapMode.CULTURA, "GFX_mapmode_culture"], [MapView.MapMode.RELIGIAO, "GFX_mapmode_religion"],
		[MapView.MapMode.PRODUTOS, "GFX_mapmode_trade_goods"], [MapView.MapMode.COMERCIO, "GFX_mapmode_trade"],
		[MapView.MapMode.REGIOES, "GFX_mapmode_areas"], [MapView.MapMode.INSTITUICOES, "GFX_mapmode_institutions"],
		[MapView.MapMode.DIPLOMACIA, "GFX_mapmode_diplomatic"]]
## Elementos dos .gui sem equivalente no jogo (ainda): ficam escondidos.
const HIDDEN := ["player_shield_glow", "great_power_button_base", "great_power_button", "government_reforms_button_base",
		"government_reforms_progress", "government_reforms_button", "powerprojection_topbar",
		"liberty_desire_topbar", "alerts_parent", "hotkey_assign_parent", "timeline_controls", "mapmode_list_window",
		"mapmode_item", "add_mapmode_item", "icon_dev", "text_dev", "icon_meritocracy", "text_meritocracy", "icon_leg",
		"text_leg", "icon_rep", "text_rep", "icon_unity", "text_unity", "current_age_button", "age_icon", "age_title",
		"button_nextsong", "button_timeline", "button_achievements", "button_outliner", "history_button",
		"menubar_modifiers_button", "menu_button", "ledger_button", "button_goto", "button_pick_shortcut", "closebutton",
		"OPENbutton", "category_button_political", "category_button_map", "category_button_geographical",
		"category_button_economical", "custom_mapmode_overlay", "custom_mapmode_10", "brown_bg", "topbar_1",
		"topbar_2", "topbar_3"]

var gui: Eu4Gui
var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var religion: Religion             # opcional (missionários na barra)
var manpower: Manpower             # opcional (efetivo na barra)
var prestige: Prestige             # opcional (prestígio na barra)
var player := ""
var _flag_tag := ""
var _dev_version := -1
var _dev := {}                     # tag -> desenvolvimento total (refeito quando um dono muda)


## Monta a interface; false se faltar alguma tela (o main.gd fica com a barra simples).
func setup(g: Eu4Gui, m: MapView, c: GameClock, pw: MonarchPower, eco: Economy) -> bool:
	gui = g
	map = m
	clock = c
	power = pw
	economy = eco
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for w in ["topbar", "speed_controls", "minimap_panel"]:
		var c2 := g.build(w)
		if c2 == null:
			return false
		add_child(c2)
	for n in HIDDEN:
		if g.nodes.has(n):
			g.nodes[n].hide()
	_text("pause_banner_text", Loc.t("CORE_PAUSED", "Pausado"))
	var shield := _node("player_shield") as Eu4Gui.Button2
	if shield:
		shield.pressed.connect(func(): shield_pressed.emit())
		shield.tooltip_text = Loc.s("Abrir o painel do seu país", "Open your country view")
	var bb := _node("open_build_interface_button") as BaseButton
	if bb:
		bb.pressed.connect(func(): build_pressed.emit())
		bb.tooltip_text = Loc.t("MACRO_OPEN_INTERFACE_TOOLTIP", "Construir: construções, desenvolvimento e missionários")
	_button("button_pause", clock.toggle_pause, Loc.s("Pausar / continuar (espaço)", "Pause / resume (space)"))
	_button("speed_indicator", clock.toggle_pause, Loc.t("PW_SPEED", "Velocidade"))
	_button("button_speedup", func(): clock.set_speed(clock.speed + 1), Loc.s("Mais rápido (+)", "Faster (+)"))
	_button("button_speeddown", func(): clock.set_speed(clock.speed - 1), Loc.s("Mais devagar (−)", "Slower (−)"))
	_button("zoom_in", func(): zoom_requested.emit(1.25), Loc.t("ZOOM_IN", "Aproximar"))
	_button("zoom_out", func(): zoom_requested.emit(0.8), Loc.t("ZOOM_OUT", "Afastar"))
	for i in MAPMODES.size():
		var b := _node("custom_mapmode_%d" % (i + 1)) as Eu4Gui.Button2
		if b == null:
			continue
		var mode: int = MAPMODES[i][0]
		if not map.has_map_mode(mode as MapView.MapMode) or not g.sprites.has(MAPMODES[i][1]):
			b.hide()
			continue
		b.setup(g, MAPMODES[i][1])
		b.tooltip_text = Loc.s("Modo de mapa: ", "Map mode: ") + MapView.map_mode_name(mode)
		b.pressed.connect(func():
			map.set_map_mode(mode as MapView.MapMode)
			refresh())
	_tip("icon_gold", Loc.t("HINT_DUCATS_TITLE", "Tesouro (ducados)"))
	_tip("icon_ADM", Loc.t("ADM_POWER", "Pontos administrativos"))
	_tip("icon_DIP", Loc.t("DIP_POWER", "Pontos diplomáticos"))
	_tip("icon_MIL", Loc.t("MIL_POWER", "Pontos militares"))
	_tip("icon_score", Loc.s("Desenvolvimento total e posição entre os países", "Total development and rank among countries"))
	_tip("icon_corruption", Loc.t("corruption", "Corrupção"))
	_tip("icon_missionary", Loc.t("HINT_MISSIONARY_TITLE", "Missionários"))
	_tip("icon_manpower", Loc.t("HINT_MANPOWER_TITLE", "Efetivo"))
	_tip("icon_prestige", Loc.t("HINT_PRESTIGE_TITLE", "Prestígio"))
	_tip("icon_merchant", Loc.t("HINT_MERCHANT_TITLE", "Mercadores"))
	_tip("icon_settler", Loc.t("HINT_COLONIST_TITLE", "Colonos"))
	_tip("icon_diplomat", Loc.t("HINT_DIPLOMAT_TITLE", "Diplomatas"))
	refresh()
	return true


func _node(n: String) -> Control:
	return gui.nodes.get(n) as Control


func _text(n: String, t: String) -> void:
	var l := _node(n) as Label
	if l:
		l.text = t


func _tip(n: String, t: String) -> void:
	var c := _node(n)
	if c:
		c.tooltip_text = t


func _button(n: String, f: Callable, tip: String) -> void:
	var b := _node(n) as BaseButton
	if b:
		b.pressed.connect(f)
		b.tooltip_text = tip


## Atualiza números, data, velocidade, bandeira e o modo de mapa escolhido.
func refresh() -> void:
	if gui == null:
		return
	_text("DateText", clock.date_text())
	var si := _node("speed_indicator") as Eu4Gui.Button2
	if si:
		si.set_frame(clampi(clock.speed, 1, 5) - 1 + (5 if clock.paused else 0))
	var pw := _node("pause_window")
	if pw:
		pw.visible = clock.paused and player != ""
	for i in MAPMODES.size():
		var b := _node("custom_mapmode_%d" % (i + 1)) as Eu4Gui.Button2
		if b and b.visible and b.sprite == MAPMODES[i][1]:
			var sel: int = 1 if map.map_mode == MAPMODES[i][0] else 0
			if b.base_frame != sel:
				b.set_frame(sel)
	var has := player != "" and map.countries.has(player)
	_text("PlayerNationText", map.countries[player]["name"] if has else "Imperium Mundi")
	var shield := _node("player_shield") as Eu4Gui.Button2
	if shield and _flag_tag != player:
		_flag_tag = player
		var ft := map.flag_texture(player) if has else null
		var img := ft.get_image() if ft else null
		shield.set_flag(ImageTexture.create_from_image(img) if img else null)
	if not has:
		for n in ["text_gold", "text_manpower", "text_sailors", "text_stability", "text_prestige", "text_ADM",
				"text_DIP", "text_MIL", "text_score", "text_score_rank", "text_merchants", "text_settlers",
				"text_diplomats", "text_missionaries", "text_corruption"]:
			_text(n, "")
		return
	_text("text_gold", str(int(economy.money(player))))
	_tip("text_gold", Loc.s("Saldo: %s ducados/mês · %d empréstimo(s) · inflação %s%%%s",
			"Balance: %s ducats/month · %d loan(s) · inflation %s%%%s") % [
			AdvisorsWindow._n(economy.balance(player), true), economy.loan_count(player),
			AdvisorsWindow._n(economy.inflation_of(player)),
			Loc.s(" · EM FALÊNCIA", " · BANKRUPT") if economy.is_bankrupt(player) else ""])
	_text("text_corruption", AdvisorsWindow._n(economy.corruption_of(player)))
	for cat in ["adm", "dip", "mil"]:
		_text("text_" + cat.to_upper(), str(power.points(player, cat)))
	# ainda não simulados no jogo
	for n in ["text_manpower", "text_sailors", "text_stability", "text_prestige", "text_merchants", "text_settlers",
			"text_diplomats", "text_missionaries"]:
		_text(n, "—")
	if manpower:          # efetivo atual (dica: máximo e recuperação por mês)
		_text("text_manpower", Manpower.fmt(manpower.of(player)))
		_tip("text_manpower", Loc.s("Efetivo: %s de %s (+%s por mês)", "Manpower: %s of %s (+%s per month)") % [
				Manpower.fmt(manpower.of(player)), Manpower.fmt(manpower.max_of(player)), Manpower.fmt(manpower.monthly(player))])
	if prestige:          # prestígio (dica: mudança por ano e efeitos)
		_text("text_prestige", str(roundi(prestige.of(player))))
		_tip("text_prestige", prestige.tooltip(player))
	# enviados como no EU4: livres/total (mercadores, colonos, diplomatas, missionários)
	var base: Dictionary = map.trade_rules.get("base_values", {})
	var tv: Trade = map.trade_view
	if tv and tv.enabled():
		var mt := int(tv._rule("base_merchants", 2)) + int(power.modifier(player, "merchants"))
		_text("text_merchants", "%d/%d" % [maxi(0, mt - tv.merchants.get(player, []).size()), mt])
		_tip("text_merchants", Loc.s("Mercadores livres/total (vão sozinhos aos nós de maior poder)",
				"Free/total merchants (placed automatically in the strongest nodes)"))
	if not base.is_empty():
		var col := int(base.get("colonists", 0)) + int(power.modifier(player, "colonists"))
		_text("text_settlers", "%d/%d" % [col, col])
		var dip := int(base.get("diplomats", 0)) + int(power.modifier(player, "diplomats"))
		_text("text_diplomats", "%d/%d" % [dip, dip])
	if religion and religion.enabled():      # missionários livres/total, como no EU4
		_text("text_missionaries", "%d/%d" % [religion.free_missionaries(player), religion.max_missionaries(player)])
	if _dev_version != map.owner_version:
		_dev_version = map.owner_version
		_dev = {}
		for p in map.provinces:
			var o: String = p["owner"]
			if o != "":
				_dev[o] = int(_dev.get(o, 0)) + int(p["development"])
	var dev := _dev
	var mine: int = dev.get(player, 0)
	var rank := 1
	for t in dev:
		if dev[t] > mine:
			rank += 1
	_text("text_score", str(mine))
	_text("text_score_rank", (Loc.s("%dº", "#%d")) % rank)
