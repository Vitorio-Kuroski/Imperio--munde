class_name Eu4EconomyTab
extends RefCounted
## Aba Economia da tela do país do EU4 (countryeconomyview.gui), com as linhas do EU4:
##  - receitas com a eficiência/modificador de cada uma em cinza (impostos, produção, comércio,
##    tarifas, vassalos) — imposto, produção, ouro e vassalos já existem; as outras ficam em 0,00;
##  - despesas: conselheiros, juros, gastos diplomáticos (taxa de vassalo) e combate à corrupção
##    (a barra funciona); as manutenções que o jogo ainda não tem ficam em 0,00 com a barra cheia;
##  - totais, saldo, gráfico da inflação (últimos 10 anos), cansaço de guerra, desenvolvimento;
##  - botões (só no país do jogador): pedir empréstimo (com o valor), pagar um (lista dos
##    empréstimos) ou todos, reduzir inflação (75 adm), desvalorizar a moeda e declarar falência
##    (com confirmação). Impostos de guerra ficam desativados (o jogo ainda não tem guerras).

const INCOMES := [["tax", "Impostos"], ["production", "Produção"], ["trade", "Comércio"], ["gold", "Ouro"],
		["tariffs", "Tarifas"], ["vassals", "Vassalos"], ["harbor", "Taxas portuárias"], ["subsidies", "Subsídios"],
		["spoils", "Espólios de guerra"], ["reparations", "Reparações de guerra"], ["condottieri", "Condottieri"],
		["knowledge", "Partilha de conhecimento"]]
## [chave, nome, tem barra]
const EXPENSES := [["advisors", "Conselheiros", false], ["states", "Manutenção dos estados", false],
		["interest", "Juros", false], ["diplomatic", "Gastos diplomáticos", false], ["forts", "Manutenção dos fortes", false],
		["colonial", "Manutenção colonial", true], ["missionaries", "Manutenção de missionários", true],
		["corruption", "Combate à corrupção", true], ["army", "Manutenção do exército", true],
		["fleet", "Manutenção da frota", true]]
const HIDE := ["inflation_dev_icon"]
const GOOD := Color(0.55, 0.9, 0.45)
const BAD := Color(1.0, 0.42, 0.35)
const ZERO := Color(0.95, 0.9, 0.6)

var view: Eu4CountryView
var root: Control
var _tag := ""
var _confirm: ConfirmationDialog
var _chart: Control


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countryeconomyview")
	if root == null:
		return false
	for n in HIDE:
		Eu4CountryView._hide(root, n)
	view._txt(root, "incomes", "Receitas")
	view._txt(root, "expenses", "Despesas")
	view._txt(root, "incomes_total_text", "Receita total:")
	view._txt(root, "expences_total_text", "Despesa total:")
	view._txt(root, "balance_title", "Saldo:")
	_button("take_loan", func(): view.economy.take_loan(_tag))
	_button("repay_loan", func(): _show_loans(true))
	_button("repay_all_loans", func(): view.economy.repay_all(_tag))
	_button("combat_inflation", func(): view.economy.reduce_inflation(_tag))
	_button("debase_currency", func(): view.economy.debase_currency(_tag))
	_button("go_bankrupt", func(): _confirm.popup_centered())
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Declarar falência"
	_confirm.dialog_text = "Declarar falência? Os empréstimos, o tesouro e os conselheiros se vão, os pontos de\n" \
			+ "monarca caem para −100 e por 5 anos juros, tecnologias, ideias e conselheiros ficam mais caros."
	_confirm.ok_button_text = "Declarar falência"
	_confirm.cancel_button_text = "Cancelar"
	_confirm.confirmed.connect(func(): view.economy.declare_bankruptcy(_tag))
	root.add_child(_confirm)
	var wt := root.find_child("raise_wartaxes", true, false) as BaseButton
	if wt:
		wt.disabled = true
		wt.modulate = Color(0.75, 0.75, 0.75)
		wt.tooltip_text = "Impostos de guerra: só em guerra (o jogo ainda não tem guerras)"
	var rl := root.find_child("countryeconomyview_repayloan", true, false) as Control
	if rl:
		rl.hide()
		view._txt(rl, "title", "Empréstimos")
		var back := rl.find_child("back_button", true, false) as BaseButton
		if back:
			view._set_button_text(back, "Voltar")
			back.pressed.connect(func(): _show_loans(false))
	# gráfico da inflação desenhado sobre o fundo do .gui
	var bg := root.find_child("inflation_linechart_bg", true, false) as Control
	Eu4CountryView._hide(root, "inflation_linechart")
	if bg:
		_chart = Control.new()
		_chart.mouse_filter = Control.MOUSE_FILTER_PASS
		_chart.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_chart.draw.connect(_draw_chart)
		bg.add_child(_chart)
	return true


func _button(n: String, f: Callable) -> void:
	var b := root.find_child(n, true, false) as BaseButton
	if b:
		b.pressed.connect(func():
			f.call()
			view.refresh())


func _show_loans(on: bool) -> void:
	var rl := root.find_child("countryeconomyview_repayloan", true, false) as Control
	if rl:
		rl.visible = on
	if on:
		_fill_loans()


func _fill_loans() -> void:
	var eco := view.economy
	var rl := root.find_child("countryeconomyview_repayloan", true, false) as Control
	var list := rl.find_child("loans_listbox", true, false) as Control if rl else null
	var ls: Array = eco.loans.get(_tag, [])
	var rows := view.gui.fill_list(list, "countryeconomyview_loanrepayitem", ls.size())
	for i in rows.size():
		var l: Dictionary = ls[i]
		view._txt(rows[i], "loan_lender", "Banco")
		view._txt(rows[i], "loan_amount_interest", "%s ducados a %s%% ao ano" % [AdvisorsWindow._n(float(l["amount"])),
				AdvisorsWindow._n(float(l["rate"]))])
		var e := int(l["expires"])
		view._txt(rows[i], "loan_expire", "Vence em %d/%d/%d" % [e % 100, (e / 100) % 100, e / 10000])
		var pay := rows[i].find_child("pay_button", true, false) as BaseButton
		if pay:
			view._set_button_text(pay, "Pagar")
			pay.disabled = _tag != view.player or eco.money(_tag) < float(l["amount"])
			var idx := i
			pay.pressed.connect(func():
				eco.repay_loan(_tag, idx)
				view.refresh()
				_fill_loans())
	view._txt(rl, "title", "Empréstimos (%d) — dívida de %s ducados" % [ls.size(), AdvisorsWindow._n(eco.debt(_tag))] \
			if not ls.is_empty() else "Nenhum empréstimo")


func _draw_chart() -> void:
	var h: PackedFloat32Array = view.economy.history.get(_tag, PackedFloat32Array())
	var sz := _chart.size
	if h.size() < 2:
		_chart.draw_line(Vector2(0, sz.y - 2), Vector2(sz.x, sz.y - 2), BAD, 2.0)
		return
	var top := 1.0
	for v in h:
		top = maxf(top, v * 1.1)
	var pts := PackedVector2Array()
	for i in h.size():
		pts.append(Vector2(sz.x * i / 119.0, sz.y - 2 - (sz.y - 4) * h[i] / top))
	_chart.draw_polyline(pts, BAD, 2.0, true)


static func _n(x: float) -> String:
	return ("%.2f" % x).replace(".", ",")


static func _pct(x: float) -> String:
	return ("(%.1f%%)" % (x * 100.0)).replace(".", ",")


func _line(list: Control, name: String, value: float, grey: String, color: Color, tip := "") -> Control:
	var row := view.gui.add_item(list, "countryeconomyview_listitem")
	if row == null:
		return null
	view._txt(row, "name", name, tip)
	view._txt(row, "value2", grey)
	view._txt(row, "value", _n(value), tip)
	var l := row.find_child("value", true, false) as Label
	if l:
		l.add_theme_color_override("font_color", color if absf(value) >= 0.005 else ZERO)
	return row


func fill(tag: String) -> void:
	_tag = tag
	var map := view.map
	var eco := view.economy
	var pw := view.power
	var mine := tag == view.player
	var c: Dictionary = map.countries[tag]
	view._txt(root, "window_title", "Economia — " + c["name"])
	var inc := eco.income(tag)
	var exp := eco.expenses(tag)
	var bt := 0
	var bp := 0
	for p in map.provinces:
		if p["owner"] == tag:
			bt += int(p.get("base_tax", 0))
			bp += int(p.get("base_production", 0))
	var grey := {"tax": _pct(pw.modifier(tag, "global_tax_modifier")),
			"production": _pct(pw.modifier(tag, "production_efficiency")),
			"trade": _pct(pw.modifier(tag, "trade_efficiency") + eco._tech_trade_efficiency(tag)),
			"tariffs": _pct(0.0), "vassals": _pct(Economy.VASSAL_FEE + pw.modifier(tag, "vassal_income"))}
	var tips := {"tax": "Imposto base %d por ano ÷ 12 × (1 + modificador de impostos)" % bt,
			"production": "Produção base %d × 0,2 × preço do produto por ano ÷ 12 × (1 + eficiência de produção)" % bp,
			"gold": "Cada unidade de ouro produzida rende 40 ducados por ano (e gera inflação)",
			"trade": _trade_tip(tag),
			"vassals": "Vassalos pagam %d%% da renda de impostos deles" % roundi(100.0 * (Economy.VASSAL_FEE \
					+ pw.modifier(tag, "vassal_income")))}
	var incomes := root.find_child("incomes_listbox", true, false) as Control
	if incomes and not incomes.has_meta("wide"):     # o valor (x 170, 54 px) passa da lista de 180 px
		incomes.set_meta("wide", true)
		incomes.offset_right = incomes.offset_left + 232
	view.gui.fill_list(incomes, "", 0)
	for it in INCOMES:
		_line(incomes, it[1], float(inc.get(it[0], 0.0)), grey.get(it[0], ""), GOOD, tips.get(it[0], "Ainda não existe no jogo"))
	var expenses := root.find_child("expenses_listbox", true, false) as Control
	view.gui.fill_list(expenses, "", 0)
	var adv_names := []
	if view.advisors and view.advisors.enabled():
		for cat in Advisors.CATS:
			var a := view.advisors.get_hired(tag, cat)
			if not a.is_empty():
				adv_names.append("%s (%s %d)" % [a["name"], cat, int(a["skill"])])
	var etips := {"advisors": "Conselheiros: " + (", ".join(adv_names) if not adv_names.is_empty() else "nenhum") \
			+ " (salário +0,5% por ano desde 1444, + inflação)",
			"interest": "%d empréstimo(s), dívida de %s ducados" % [eco.loan_count(tag), AdvisorsWindow._n(eco.debt(tag))],
			"diplomatic": "Taxa paga ao suserano" if eco.vassal_fee(tag) > 0.0 else "Nenhum",
			"corruption": "Corrupção atual: %s (a barra cheia gasta 0,05 ducado por desenvolvimento e tira 1 por ano)" \
					% AdvisorsWindow._n(eco.corruption_of(tag)),
			"missionaries": ("%d missionário(s) convertendo (0,5 + 5%% do desenvolvimento da província por mês)" \
					% view.religion.missions.get(tag, {}).size()) if view.religion else ""}
	for it in EXPENSES:
		_line(expenses, it[1], float(exp.get(it[0], 0.0)), "", BAD, etips.get(it[0], "Ainda não existe no jogo"))
		if it[2]:
			var s := view.gui.add_item(expenses, "countryeconomyview_listitem_slider")
			if s:
				s.get_parent().custom_minimum_size.y = 16
				var sl := s.find_child("slider", true, false) as Eu4Gui.ScrollBar2
				if sl and it[0] == "corruption":
					sl.set_value(float(eco.root_out.get(tag, 0.0)))
					sl.editable = mine
					sl.tooltip_text = "Combate à corrupção: %d%%" % roundi(sl.value * 100.0)
					sl.value_changed.connect(func(v: float):
						eco.set_root_out(tag, v)
						view.refresh())
				elif sl and it[0] == "missionaries" and view.religion:
					sl.set_value(view.religion.budget_of(tag))
					sl.editable = mine
					sl.tooltip_text = "Missionários: %d%% (menos gasto, conversão mais lenta)" % roundi(sl.value * 100.0)
					sl.value_changed.connect(func(v: float):
						view.religion.set_budget(tag, v)
						view.refresh())
				elif sl:
					sl.tooltip_text = "Manutenção: 100% (ainda não ajustável)"
	view._txt(root, "incomes_total", _n(float(inc["total"])))
	view._txt(root, "expenses_total", _n(float(exp["total"])))
	_color("incomes_total", GOOD)
	_color("expenses_total", BAD)
	var bal := eco.balance(tag)
	view._txt(root, "balance", ("%+.2f" % bal).replace(".", ","),
			"Por mês. Tesouro: %s ducados" % AdvisorsWindow._n(eco.money(tag)))
	_color("balance", GOOD if bal >= 0.0 else BAD)
	view._txt(root, "inflation_info", ("%.2f%%" % eco.inflation_of(tag)).replace(".", ","),
			"Inflação: aumenta os gastos (conselheiros) nessa porcentagem")
	view._txt(root, "war_exhaustion", "0,0/20", "Cansaço de guerra (ainda não existe no jogo)")
	view._txt(root, "development_base", str(int(eco.development(tag))), "Desenvolvimento total")
	# botões
	var size := eco.loan_size(tag)
	view._txt(root, "take_loan_sum", str(int(size)))
	_state("take_loan", mine and eco.can_take_loan(tag), "Pedir um empréstimo de %d ducados a %s%% ao ano (%d de %d; +0,1 de inflação)" \
			% [int(size), AdvisorsWindow._n(eco.interest_rate(tag)), eco.loan_count(tag), eco.max_loans(tag)])
	_state("repay_loan", eco.loan_count(tag) > 0, "Ver e pagar empréstimos")
	_state("repay_all_loans", mine and eco.loan_count(tag) > 0 and eco.money(tag) >= eco.debt(tag),
			"Pagar todos os empréstimos (%s ducados)" % AdvisorsWindow._n(eco.debt(tag)))
	_state("combat_inflation", mine and eco.can_reduce_inflation(tag),
			"Reduzir a inflação em 2 por %d pontos administrativos" % eco.reduce_inflation_cost(tag))
	_state("debase_currency", mine and eco.can_debase(tag),
			"Desvalorizar a moeda: +%d ducados por +2 de corrupção (corrupção atual %s)" % [int(size),
			AdvisorsWindow._n(eco.corruption_of(tag))])
	_state("go_bankrupt", mine and eco.can_declare_bankruptcy(tag), "Declarar falência (precisa ter empréstimos)" \
			if not eco.is_bankrupt(tag) else "Em falência")
	if _chart:
		_chart.queue_redraw()
		_chart.tooltip_text = "Inflação nos últimos 10 anos"
	var rl := root.find_child("countryeconomyview_repayloan", true, false) as Control
	if rl and rl.visible:
		_fill_loans()


func _trade_tip(tag: String) -> String:
	var tv: Trade = view.map.trade_view
	if tv == null or not tv.enabled():
		return "Sem nós de comércio no mapa"
	var parts := []
	for i in tv.collected.size():
		if tv.collected[i].has(tag):
			var nid: String = tv.nodes[i]
			parts.append("%s: %s (%d%% do poder%s)" % [view.map.trade_nodes[nid]["name"], _n(tv.collected[i][tag]),
					roundi(tv.share(tag, i) * 100.0), ", capital comercial" if i == tv.home(tag) else ", mercador"])
	return "Coleta de comércio por mês:\n" + ("\n".join(parts) if not parts.is_empty() else "nenhuma")


func _state(n: String, on: bool, tip: String) -> void:
	var b := root.find_child(n, true, false) as BaseButton
	if b:
		b.disabled = not on
		b.modulate = Color.WHITE if on else Color(0.7, 0.7, 0.7)
		b.tooltip_text = tip


func _color(n: String, col: Color) -> void:
	var l := root.find_child(n, true, false) as Label
	if l:
		l.add_theme_color_override("font_color", col)
