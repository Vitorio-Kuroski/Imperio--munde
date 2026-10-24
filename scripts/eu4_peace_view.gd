class_name Eu4PeaceView
extends Control
## Tela de paz do EU4 (peace_view, peaceview.gui): negociação do jogador com um país inimigo.
##  - Abas Exigir (demand_tab: o jogador recebe) e Oferecer (offer_tab: o jogador entrega).
##  - Categorias: províncias (secede_provinces) e tratados (treaties: vassalizar, conceder derrota);
##    as outras categorias do EU4 ainda não existem e ficam escondidas.
##  - Lista (peace_list de peace_entry): clicar põe/tira o termo; cada linha com a bandeira de quem
##    entrega, o custo em placar e o prestígio; ícone do objetivo de guerra nas províncias que ele
##    barateia.
##  - Expansão agressiva (aggressiveexp_value: a maior que um país recebe; dica com os mais afetados).
##  - Ouro com +/− (inccash/deccash), placar da guerra, valor da proposta ÷ placar, prestígio, seta de
##    aceitaria/recusaria (terms_accepted/terms_declined), Enviar (send), Limpar (reset_button) e fechar.
## As regras e custos ficam em `Peace`.

signal message(text: String)

const HIDE := ["give_up_cores", "peace_icon_revokecores", "peace_icon_revokecores_glow", "return_cores",
		"peace_icon_returncores", "peace_icon_returncores_glow", "cancel_vassals", "peace_icon_cancelvassal",
		"peace_icon_cancelvassal_glow", "release_nations", "peace_icon_releasenation", "peace_icon_releasenation_glow",
		"annul_treaties", "peace_icon_annultreaty", "peace_icon_annultreaty_glow", "suggest_peace_button",
		"surrender_button", "dip_icon", "dip_value", "coalition_icon",
		"overex_icon", "overex_value", "adm_icon", "adm_value", "better_offer_icon", "sort_overex", "sort_dip_cost",
		"belligerents_box", "affected_allies", "affected_enemies", "player_shield_AL", "opponent_shield_AL",
		"peace_icon_cede_glow", "peace_icon_treaties_glow"]

var gui: Eu4Gui
var map: MapView
var peace: Peace
var war: War
var player := ""
var enemy := ""
var deal := {}
var mode := "demand"              # "demand" (exigir) ou "offer" (oferecer)
var category := "provinces"       # "provinces" ou "treaties"
var _root: Control
var _flags := {}                  # nome do escudo -> TextureRect com a bandeira


func setup(g: Eu4Gui, m: MapView, p: Peace, w: War) -> bool:
	gui = g
	map = m
	peace = p
	war = w
	if gui.find_window("peace_view").is_empty():
		return false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root = gui.build("peace_view")
	if _root == null:
		return false
	# a janela do EU4 é presa ao canto de baixo (LOWER_LEFT, y = −568): no layout de 768 px fica em
	# y = 200; aqui ela vai para o mesmo lugar, sem depender da tela cheia
	_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.position = Vector2(55, 768 - 568)
	_root.size = Vector2(608, 571)
	add_child(_root)
	for n in HIDE:
		var c := _find(n)
		if c:
			c.hide()
	for n in ["player_shield", "opponent_shield"]:      # bandeira por cima do escudo
		var ic := _find(n)
		if ic:
			var tr := TextureRect.new()
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.position = ic.position + ic.size * 0.22
			tr.size = ic.size * 0.56
			ic.get_parent().add_child(tr)
			ic.get_parent().move_child(tr, ic.get_index())
			_flags[n] = tr
	_button("demand_tab", func(): _set_mode("demand"), Loc.t("DEMAND_PEACE", "Exigir"))
	_button("offer_tab", func(): _set_mode("offer"), Loc.t("OFFER_PEACE", "Oferecer"))
	_button("secede_provinces", func():
		category = "provinces"
		refresh(), Loc.s("Províncias", "Provinces"))
	_button("peace_icon_cede", func():
		category = "provinces"
		refresh(), Loc.s("Províncias", "Provinces"))
	_button("treaties", func():
		category = "treaties"
		refresh(), Loc.s("Tratados: vassalizar, conceder derrota", "Treaties: vassalize, concede defeat"))
	_button("peace_icon_treaties", func():
		category = "treaties"
		refresh(), Loc.s("Tratados", "Treaties"))
	_button("inccash", func():
		deal["gold"] = mini(int(peace._d("PEACE_COST_GOLD_MAX", 5)), int(deal.get("gold", 0)) + 1)
		refresh(), Loc.s("Mais ouro", "More gold"))
	_button("deccash", func():
		deal["gold"] = maxi(0, int(deal.get("gold", 0)) - 1)
		refresh(), Loc.s("Menos ouro", "Less gold"))
	_button("reset_button", func():
		_clear()
		refresh(), Loc.t("CLEAR_OFFER", "Limpar"))
	_button("send", _send, Loc.t("SEND_OFFER", "Enviar"))
	_button("cancel", close, Loc.t("CLOSE", "Fechar"))
	if not Loc.active():
		_txt("demand_tab_title", "Exigir")
		_txt("offer_tab_title", "Oferecer")
		_txt("warscore_label", "Placar")
		_txt("offer_score_label", "Valor da proposta:")
		for b in [["reset_button", "Limpar"], ["send", "Enviar"]]:
			var x := _find(b[0])
			if x:
				_set_button_text(x, b[1])
	hide()
	return true


func _find(n: String) -> Control:
	return _root.find_child(n, true, false) as Control


func _button(n: String, f: Callable, tip: String) -> void:
	var b := _find(n) as BaseButton
	if b:
		b.pressed.connect(f)
		b.tooltip_text = tip


func _txt(n: String, t: String, tip := "", root: Control = null) -> void:
	var l := (root if root else _root).find_child(n, true, false) as Label
	if l:
		l.text = t
		Eu4Gui.fit_label(l)
		if tip != "":
			l.tooltip_text = tip
			l.mouse_filter = Control.MOUSE_FILTER_PASS


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


## Abre a negociação com `t` (precisa estar em guerra com o jogador).
func open_with(t: String) -> void:
	var w := war.war_between(player, t)
	if w.is_empty():
		return
	enemy = t
	mode = "demand"
	category = "provinces"
	_clear()
	show()
	refresh()


func close() -> void:
	hide()


func _clear() -> void:
	var w := war.war_between(player, enemy)
	var rec := player if mode == "demand" else enemy
	var giv := enemy if mode == "demand" else player
	deal = {"war": int(w.get("id", -1)), "receiver": rec, "giver": giv, "provinces": [], "vassal": false, "gold": 0,
			"concede": false}


func _set_mode(m: String) -> void:
	mode = m
	_clear()
	refresh()


func refresh() -> void:
	if not visible:
		return
	var w: Dictionary = war.wars.get(int(deal.get("war", -1)), {})
	if w.is_empty():
		close()
		return
	for n in ["peace_view_demand_bg", "peace_view_offer_bg"]:
		var c := _find(n)
		if c:
			c.visible = n.contains(mode)
	for b in [["demand_tab", "demand"], ["offer_tab", "offer"]]:
		var x := _find(b[0]) as Eu4Gui.Button2
		if x:
			x.set_frame(1 if mode == b[1] else 0)
	if _flags.has("player_shield"):
		_flags["player_shield"].texture = map.flag_texture(player)
	if _flags.has("opponent_shield"):
		_flags["opponent_shield"].texture = map.flag_texture(enemy)
	_txt("war_name", str(w["name"]))
	var score := war.score_for(w, player)
	_txt("warscore", ("%+d%%" % roundi(score)), Loc.s("Placar da guerra para nós: ocupações e batalhas",
			"War score for us: occupations and battles"))
	for n in ["war_cb_icon", "war_wargoal_icon"]:
		var ic := _find(n)
		if ic:
			ic.tooltip_text = (Loc.s("Casus belli: %s", "Casus belli: %s") % CasusBelli.name_of(w.get("cb", ""))) \
					if w.get("cb", "") != "" else Loc.s("Sem casus belli", "No casus belli")
	_fill_list(w)
	var c := peace.cost(deal)
	var mine := score if mode == "demand" else war.score_for(w, enemy)
	_txt("offer_score", "%d%%" % roundi(c), Loc.s("Custo do acordo: %d%% (placar de quem recebe: %d%%)",
			"Deal cost: %d%% (war score of the receiver: %d%%)") % [roundi(c), roundi(maxf(0.0, mine))])
	_txt("prestige_value", ("%+.1f" % peace.prestige_gain(deal)).replace(".", Loc.dec))
	_fill_ae()
	_txt("cash", str(roundi(peace.gold_amount(deal["giver"], int(deal.get("gold", 0))))),
			Loc.s("Ouro: %d empréstimo(s) do tamanho dos de quem paga (%d%% de placar cada)",
			"Gold: %d loan(s) of the payer's loan size (%d%% war score each)") % [int(deal.get("gold", 0)),
			roundi(peace._d("PEACE_COST_GOLD_STEP", 5))])
	var ok := peace.accepts(deal, player)
	for n in ["terms_accepted", "terms_declined"]:
		var x := _find(n)
		if x:
			x.visible = (n == "terms_accepted") == ok
			x.tooltip_text = Loc.s("Aceitariam", "Would accept") if ok else Loc.s("Recusariam: o custo passa do placar",
					"Would refuse: the cost exceeds the war score")
	var full := peace.is_full_peace(w, player, enemy)
	_txt("desc", peace.describe(deal) + "\n" + (Loc.s("Acaba a guerra", "Ends the war") if full else \
			Loc.s("Paz separada com %s", "Separate peace with %s") % map.countries[enemy]["name"]))


## Expansão agressiva do acordo (para quem recebe): a base e, na dica, os países mais afetados.
func _fill_ae() -> void:
	var co := peace.coalition
	for n in ["aggressiveexp_icon", "aggressiveexp_value"]:
		var x := _find(n)
		if x:
			x.visible = co != null
	if co == null:
		return
	var rec: String = deal["receiver"]
	var got := co.deal_ae(deal)
	var top := got.keys()
	top.sort_custom(func(a, b): return got[a] > got[b])
	var lines := [Loc.s("Expansão agressiva para %s (base %s)", "Aggressive expansion for %s (base %s)") % [
			map.countries[rec]["name"], ("%.1f" % co.deal_base(deal)).replace(".", Loc.dec)]]
	for t in top.slice(0, 10):
		var total: float = co.ae(t, rec) + float(got[t])
		lines.append("%s: +%s (%s)%s" % [map.countries[t]["name"], ("%.1f" % got[t]).replace(".", Loc.dec),
				("%.0f" % total), Loc.s(" — pode entrar em coalizão", " — may join a coalition") \
				if total >= co.threshold() and co.ae(t, rec) < co.threshold() else ""])
	if top.size() > 10:
		lines.append(Loc.s("e mais %d países", "and %d more countries") % (top.size() - 10))
	var mx: float = got[top[0]] if not top.is_empty() else 0.0
	_txt("aggressiveexp_value", ("%.1f" % mx).replace(".", Loc.dec), "\n".join(lines))
	var ic := _find("aggressiveexp_icon")
	if ic:
		ic.tooltip_text = "\n".join(lines)


func _fill_list(w: Dictionary) -> void:
	var list := _find("peace_list")
	var items := []          # [tipo, valor, texto, custo, prestígio, bandeira, objetivo de guerra?]
	var rec: String = deal["receiver"]
	var giv: String = deal["giver"]
	if category == "provinces":
		for pid in peace.demandable(w, rec, giv):
			var p: Dictionary = map.provinces[pid]
			var c := peace.province_cost(w, pid, rec)
			items.append(["province", pid, "%s (%d)" % [p["name"], int(p["development"])], c,
					float(p["development"]) * peace._d("PO_DEMAND_PROVINCES_PRESTIGE", 0.25), p["owner"],
					peace._goal_factor(w, pid, rec) < 1.0])
	else:
		if peace.can_vassalize(w, rec, giv):
			items.append(["vassal", true, Loc.s("Vassalizar %s", "Vassalize %s") % map.countries[giv]["name"],
					peace.vassal_cost(giv), peace.economy.development(giv) * peace._d("PO_BECOME_VASSAL_PRESTIGE", 0.25), giv, false])
		items.append(["concede", true, Loc.s("Conceder derrota", "Concede defeat"), peace._d("PEACE_COST_CONCEDE", 10),
				peace._d("PO_CONCEDE_DEFEAT_PRESTIGE", 10), giv, false])
	var rows := gui.fill_list(list, "peace_entry", items.size())
	for i in rows.size():
		var it: Array = items[i]
		var row: Control = rows[i]
		for n in ["desire_icon", "claim_button", "perma_claim_button", "country_flag_2", "unlawful_territory",
				"dip_cost", "overex"]:
			var x := row.find_child(n, true, false) as Control
			if x:
				x.hide()
		var core := row.find_child("core_button", true, false) as Control
		if core:
			core.visible = it[0] == "province" and rec in map.provinces[int(it[1])].get("cores", [])
			core.tooltip_text = Loc.s("Núcleo de quem recebe", "Core of the receiver")
		var wg := row.find_child("wargoal_icon", true, false) as Control
		if wg:
			wg.visible = it[6]
			wg.tooltip_text = Loc.s("Objetivo de guerra: custo menor", "War goal: lower cost")
		var fl := row.find_child("country_flag", true, false) as Eu4Gui.Button2
		if fl:
			fl.set_flag(map.flag_texture(str(it[5])))
		_txt("text", str(it[2]), "", row)
		_txt("score", "%d%%" % roundi(float(it[3])), "", row)
		_txt("prestige", str(roundi(float(it[4]))), "", row)
		var sel := row.find_child("select", true, false) as BaseButton
		if sel:
			var on := _has(it)
			if sel is Eu4Gui.Button2:
				(sel as Eu4Gui.Button2).set_frame(1 if on else 0)
			sel.modulate = Color(1.15, 1.1, 0.8) if on else Color.WHITE
			var item := it
			sel.pressed.connect(func():
				_toggle(item)
				refresh())


func _has(it: Array) -> bool:
	match it[0]:
		"province":
			return int(it[1]) in deal["provinces"]
		"vassal":
			return deal.get("vassal", false)
		"concede":
			return deal.get("concede", false)
	return false


func _toggle(it: Array) -> void:
	match it[0]:
		"province":
			var pid := int(it[1])
			if pid in deal["provinces"]:
				deal["provinces"].erase(pid)
			else:
				deal["provinces"].append(pid)
		"vassal":
			deal["vassal"] = not deal.get("vassal", false)
		"concede":
			deal["concede"] = not deal.get("concede", false)


func _send() -> void:
	if peace.accepts(deal, player):
		var text := peace.describe(deal)
		peace.sign(deal)
		message.emit(Loc.s("%s aceitou a paz: %s", "%s accepted peace: %s") % [map.countries[enemy]["name"], text])
		close()
	else:
		message.emit(Loc.s("%s recusou a proposta", "%s refused the offer") % map.countries[enemy]["name"])
