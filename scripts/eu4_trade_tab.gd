class_name Eu4TradeTab
extends RefCounted
## Aba "Comércio" da tela do país (countrytradeview.gui), como no EU4: eficiência comercial, alcance,
## direcionamento, poder comercial global, mercantilismo (botão Promote Mercantilism: 100 dip, +1),
## eficiência de corsários, bônus do interior (poder de caravana, `Trade.caravan_power`) e bens
## produzidos; a renda de comércio com a pizza da parte dela na renda; embargos e transferências
## ("None": ainda não existem) e a lista dos nós onde o país tem poder (ordem do poder, como o EU4):
## escudo de quem tem mais poder no nó, nome, mercador, coleta (+) / puxa (seta verde) / transfere
## (seta azul), renda, poder total, nosso poder e valor. Os mercadores ainda são automáticos: o
## botão Send/Change fica apagado.

const TRADE_RANGE := 200.0          # alcance básico do EU4 (fixo no motor, não está nos arquivos)
const PIE_CENTER := Vector2(320, 133) # piechartType trade_income_from_trade_pie (size = raio 20)
const PIE_RADIUS := 20.0

var view: Eu4CountryView
var root: Control
var _pie: Control
var _pie_share := 0.0


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countrytradeview")
	if root == null:
		return false
	# janela de enviar mercador (Collect from Trade / Transfer Trade Power): os mercadores ainda são automáticos
	var smw := root.find_child("send_merchant_window", true, false) as Control
	if smw:
		smw.hide()
	_pie = Control.new()
	_pie.mouse_filter = Control.MOUSE_FILTER_PASS
	_pie.position = PIE_CENTER - Vector2(PIE_RADIUS, PIE_RADIUS)
	_pie.size = Vector2(PIE_RADIUS, PIE_RADIUS) * 2.0
	_pie.draw.connect(_draw_pie)
	var ov := root.find_child("trade_pie_overlay", true, false) as Control
	if ov:              # a moldura por cima da pizza, centrada nela
		_pie.position = ov.position + ov.size / 2.0 - Vector2(PIE_RADIUS, PIE_RADIUS)
		ov.get_parent().add_child(_pie)
		ov.get_parent().move_child(_pie, ov.get_index())
	else:
		root.add_child(_pie)
	var pm := root.find_child("promote_mercantilism", true, false) as BaseButton
	if pm:
		pm.pressed.connect(_on_promote)
	var tl := root.find_child("tradenode_list", true, false) as Control
	if tl:              # o escudo da linha fica à esquerda da lista (x −32), como no EU4
		tl.clip_contents = false
	if not Loc.active():
		view._txt(root, "window_title", "Comércio")
	return true


func _trade() -> Trade:
	return view.economy.trade if view.economy else null


func _pct(x: float, signed := true) -> String:
	var s := ("%+.1f%%" if signed else "%.1f%%") % (x * 100.0)
	return s.replace(".", Loc.dec)


func _color_pct(n: String, x: float) -> void:
	view._txt(root, n, _pct(x))
	var l := root.find_child(n, true, false) as Label
	if l:
		l.modulate = Color(0.4, 0.9, 0.4) if x > 0.0005 else (Color(1, 0.35, 0.3) if x < -0.0005 else Color.WHITE)


func fill(tag: String) -> void:
	var tr := _trade()
	var pw := view.power
	if tr == null or pw == null:
		return
	var c: Dictionary = view.map.countries[tag]
	_color_pct("trade_efficiency_value", tr.trade_efficiency(tag))
	view._txt(root, "trade_range_value", str(roundi(TRADE_RANGE * maxf(0.0, 1.0 + pw.modifier(tag, "trade_range_modifier")))))
	_color_pct("trade_steering_value", pw.modifier(tag, "trade_steering"))
	_color_pct("global_trade_power_value", pw.modifier(tag, "global_trade_power"))
	var merc := float(c.get("mercantilism", 10))
	view._txt(root, "mercantilism_value", _pct(merc / 100.0, false))
	var ml := root.find_child("mercantilism_value", true, false) as Label
	if ml:
		ml.modulate = Color(0.4, 0.9, 0.4)
	_color_pct("privateer_value", pw.modifier(tag, "privateer_efficiency"))
	var car := tr.caravan_power(tag)
	view._txt(root, "inland_merchant_value", "+%d" % roundi(car), Loc.s(
			"Poder de caravana: desenvolvimento ÷ 3 (entre 2 e 50). Soma ao poder na capital comercial quando o nó é do interior.",
			"Caravan power: development ÷ 3 (between 2 and 50). Added to the trade capital's node when it is inland."))
	var il := root.find_child("inland_merchant_value", true, false) as Label
	if il:
		il.modulate = Color(0.4, 0.9, 0.4)
	_color_pct("global_tradegoods_value", pw.modifier(tag, "trade_goods_size_modifier"))
	# promover o mercantilismo (só o jogador)
	var pm := root.find_child("promote_mercantilism", true, false) as BaseButton
	if pm:
		var why := _why_not_promote(tag)
		pm.visible = tag == view.player
		pm.disabled = why != ""
		pm.tooltip_text = Loc.s("Promover o mercantilismo: +%d%% por %d pontos diplomáticos", "Promote mercantilism: +%d%% for %d diplomatic power") \
				% [_promote_step(), _promote_cost()] + ("\n" + why if why != "" else "")
	# renda de comércio e a parte dela na renda total
	var inc: Dictionary = view.economy.income(tag)
	var t := float(inc.get("trade", 0.0))
	var tot := float(inc.get("total", 0.0))
	_pie_share = clampf(t / tot, 0.0, 1.0) if tot > 0.0 else 0.0
	view._txt(root, "trade_income_from_trade_value", ("%.2f" % t).replace(".", Loc.dec),
			Loc.s("Renda de comércio: %s por mês (%d%% da renda)", "Trade income: %s per month (%d%% of income)")
			% [("%.2f" % t).replace(".", Loc.dec), roundi(_pie_share * 100.0)])
	_pie.tooltip_text = Loc.s("%d%% da renda vem do comércio", "%d%% of income comes from trade") % roundi(_pie_share * 100.0)
	_pie.queue_redraw()
	# embargos e transferência de poder: ainda não existem
	for n in ["trade_our_embargoes_none", "trade_embargoes_on_us_none", "transferring_trade_none"]:
		view._txt(root, n, Loc.t("GO_NONE", "Nenhum"))
	view._txt(root, "trade_our_embargoes_efficiency_value", _pct(merc / 100.0))   # como o EU4 mostra (= mercantilismo)
	_fill_nodes(tag, tr)


## Nós onde o país tem poder, do maior poder para o menor.
func _fill_nodes(tag: String, tr: Trade) -> void:
	var list := root.find_child("tradenode_list", true, false) as Control
	if list == null:
		return
	var ids := []
	for i in tr.node_power.size():
		if float(tr.node_power[i].get(tag, 0.0)) > 0.0:
			ids.append(i)
	ids.sort_custom(func(a, b): return tr.node_power[a][tag] > tr.node_power[b][tag])
	var rows := view.gui.fill_list(list, "trade_node_item", ids.size())
	var home := tr.home(tag)
	var eff := tr.trade_efficiency(tag)
	var mine: Array = tr.merchants.get(tag, [])
	for k in rows.size():
		var i: int = ids[k]
		var row: Control = rows[k]
		var node: Dictionary = view.map.trade_nodes.get(tr.nodes[i], {})
		var np: Dictionary = tr.node_power[i]
		var tot := 0.0
		var top := ""
		for t in np:
			tot += np[t]
			if top == "" or np[t] > np[top]:
				top = t
		var sh := row.find_child("shield", true, false) as Eu4Gui.Button2
		if sh and top != "":
			var ft := view.map.flag_texture(top)
			var img := ft.get_image() if ft else null
			sh.set_flag(ImageTexture.create_from_image(img) if img else null)
			sh.tooltip_text = Loc.s("Maior poder no nó: %s (%d%%)", "Most trade power in the node: %s (%d%%)") % [
					view.map.countries.get(top, {}).get("name", top), roundi(np[top] / tot * 100.0)]
		view._txt(row, "location", str(node.get("name", tr.nodes[i])))
		var collects: bool = tr.collecting[i].has(tag)
		var steers: bool = tr.steering[i].has(tag)
		var merchant: bool = i in mine
		var tm := row.find_child("trader_mission", true, false) as Eu4Gui.Icon
		if tm:              # quadros: 0 = sem mercador, 1 = posto comercial, 2 = mercador
			tm.set_frame(2 if merchant else 0)
			tm.tooltip_text = Loc.s("Mercador", "Merchant") if merchant else Loc.s("Sem mercador", "No merchant")
		var ii := row.find_child("income_indicator", true, false) as Eu4Gui.Icon
		if ii:              # quadros: 0 = coleta, 1 = puxa para a capital, 2 = transfere
			ii.set_frame(0 if collects else (1 if steers else 2))
			ii.mouse_filter = Control.MOUSE_FILTER_PASS
			ii.tooltip_text = (Loc.s("Coletando", "Collecting") if collects else (Loc.s("Direcionando o comércio para a capital comercial",
					"Steering trade to our trade capital") if steers else Loc.s("Transferindo o poder comercial rio abaixo",
					"Transferring trade power downstream")))
		# renda: o que coleta ali; nos outros, o valor que o nosso poder empurra (APROXIMAÇÃO do EU4)
		var v := float(tr.total_value[i]) / 12.0      # valor por mês, como o EU4 mostra
		var inc := float(tr.collected[i].get(tag, 0.0)) if collects else v * float(np[tag]) / tot * maxf(0.0, 1.0 + eff)
		view._txt(row, "income", ("%.2f" % inc).replace(".", Loc.dec))
		view._txt(row, "total_power", _num(tot))
		view._txt(row, "current_power", _num(np[tag]))
		view._txt(row, "current_value", ("%.2f" % v).replace(".", Loc.dec))
		var b := row.find_child("send_merchant", true, false) as BaseButton
		if b:
			view._set_button_text(b, Loc.t("CHANGE", "Trocar") if merchant else Loc.t("SEND", "Enviar"))
			b.visible = tag == view.player and i != home
			b.disabled = true
			b.tooltip_text = Loc.t("CHANGE_MERCHANT_MISSION", "Mudar a missão do mercador") + "\n" \
					+ Loc.s("Os mercadores ainda vão sozinhos aos nós de maior poder", "Merchants are still placed automatically")


## Poder com 3 algarismos, como o EU4 ("251", "46.9", "9.79").
func _num(x: float) -> String:
	var s := str(roundi(x)) if x >= 100.0 else ("%.1f" % x if x >= 10.0 else "%.2f" % x)
	return s.replace(".", Loc.dec)


func _promote_cost() -> int:
	return int(Eu4Data.define("NCountry", "PS_PROMOTE_MERCANTILISM", 100))


func _promote_step() -> int:
	return int(Eu4Data.define("NCountry", "PROMOTE_MERCANTILISM_INCREASE", 1))


func _why_not_promote(tag: String) -> String:
	if tag != view.player:
		return Loc.s("Só no seu país", "Only for your country")
	if float(view.map.countries[tag].get("mercantilism", 10)) >= 100.0:
		return Loc.s("O mercantilismo já está no máximo", "Mercantilism is already at its maximum")
	if view.power.points(tag, "dip") < _promote_cost():
		return Loc.s("Faltam pontos diplomáticos", "Not enough diplomatic power")
	return ""


func _on_promote() -> void:
	var tag := view.player
	if _why_not_promote(tag) != "":
		return
	view.power.state[tag]["points"]["dip"] -= _promote_cost()
	var c: Dictionary = view.map.countries[tag]
	c["mercantilism"] = minf(100.0, float(c.get("mercantilism", 10)) + _promote_step())
	view.power.invalidate(tag)
	view.power.notify(tag)
	_trade().recompute()            # o poder comercial muda já
	view.refresh()


func _draw_pie() -> void:
	var r := PIE_RADIUS
	var ctr := Vector2(r, r)
	_pie.draw_circle(ctr, r, Color(0.16, 0.16, 0.16))
	if _pie_share <= 0.0:
		return
	var pts := PackedVector2Array([ctr])
	var n := maxi(2, ceili(48 * _pie_share))
	for k in n + 1:          # do topo, no sentido horário
		var a := -PI / 2.0 + TAU * _pie_share * float(k) / float(n)
		pts.append(ctr + Vector2(cos(a), sin(a)) * r)
	_pie.draw_colored_polygon(pts, Color(0.18, 0.62, 0.2))
