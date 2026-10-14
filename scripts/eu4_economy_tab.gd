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

## [chave, nome, chave da localização do EU4]
const INCOMES := [["tax", "Impostos", "INCOMETAX"], ["production", "Produção", "INCOMEPROD"],
		["trade", "Comércio", "INCOMETRADE"], ["gold", "Ouro", "INCOMEGOLD"], ["tariffs", "Tarifas", "INCOMETARRIFFS"],
		["vassals", "Vassalos", "INCOMEVASSAL"], ["harbor", "Taxas portuárias", "INCOMEHARBORFEES"],
		["subsidies", "Subsídios", "INCOMESUBS"], ["spoils", "Espólios de guerra", "SPOILS_OF_WAR_ECOVIEW"],
		["reparations", "Reparações de guerra", "INCOME_WAR_REPARATION"], ["condottieri", "Condottieri", "CONDOTTIERI"],
		["knowledge", "Partilha de conhecimento", "KNOWLEDGE_SHARING_ECOVIEW"]]
## [chave, nome, tem barra, chave da localização do EU4]
const EXPENSES := [["advisors", "Conselheiros", false, "EXPENSECOURT"],
		["states", "Manutenção dos estados", false, "EXPENSE_STATE_MAINTENANCE"],
		["interest", "Juros", false, "EXPENSEINTEREST"], ["diplomatic", "Gastos diplomáticos", false, "EXPENSEDIPLOMATIC"],
		["forts", "Manutenção dos fortes", false, "EXPENSEFORTM"], ["colonial", "Manutenção colonial", true, "EXPENSECOLONIAL"],
		["missionaries", "Manutenção de missionários", true, "EXPENSEMISSIONARY"],
		["corruption", "Combate à corrupção", true, "EXPENSE_CORRUPTION"], ["army", "Manutenção do exército", true, "EXPENSEAM"],
		["fleet", "Manutenção da frota", true, "EXPENSEFM"]]
const NOT_YET := ["Ainda não existe no jogo", "Not in the game yet"]
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
	if not Loc.active():       # com a localização do EU4 os rótulos já vêm do .gui
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
	_confirm.title = Loc.t("CV_GO_BANKRUPT_TITLE", "Declarar falência")
	_confirm.dialog_text = Loc.s("Declarar falência? Os empréstimos, o tesouro e os conselheiros se vão, os pontos de\n" \
			+ "monarca caem para −100 e por 5 anos juros, tecnologias, ideias e conselheiros ficam mais caros.",
			"Declare bankruptcy? Loans, treasury and advisors are gone, monarch points drop to −100 and for\n" \
			+ "5 years interest, technologies, ideas and advisors cost more.")
	_confirm.ok_button_text = Loc.t("CV_GO_BANKRUPT_TITLE", "Declarar falência")
	_confirm.cancel_button_text = Loc.t("CANCEL", "Cancelar")
	_confirm.confirmed.connect(func(): view.economy.declare_bankruptcy(_tag))
	root.add_child(_confirm)
	var wt := root.find_child("raise_wartaxes", true, false) as BaseButton
	if wt:
		wt.disabled = true
		wt.modulate = Color(0.75, 0.75, 0.75)
		wt.tooltip_text = Loc.s("Impostos de guerra: só em guerra (o jogo ainda não tem guerras)",
				"War taxes: only at war (the game has no wars yet)")
	var rl := root.find_child("countryeconomyview_repayloan", true, false) as Control
	if rl:
		rl.hide()
		view._txt(rl, "title", Loc.t("LEDGER_LOANS", "Empréstimos"))
		var back := rl.find_child("back_button", true, false) as BaseButton
		if back:
			view._set_button_text(back, Loc.t("BACK", "Voltar"))
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
		view._txt(rows[i], "loan_lender", Loc.f("CV_ECONOMY_LOAN_LENDER", {"LENDER": Loc.t("BANK", "Banco")}, "Banco"))
		view._txt(rows[i], "loan_amount_interest", Loc.f("CV_ECONOMY_LOAN_AMOUNT_INTEREST",
				{"AMOUNT": AdvisorsWindow._n(float(l["amount"])), "INTEREST": AdvisorsWindow._n(float(l["rate"]))},
				"%s ducados a %s%% ao ano" % [AdvisorsWindow._n(float(l["amount"])), AdvisorsWindow._n(float(l["rate"]))]))
		var e := int(l["expires"])
		view._txt(rows[i], "loan_expire", Loc.f("CV_ECONOMY_LOAN_EXPIRE", {"DATE": Loc.date(e / 10000, (e / 100) % 100, e % 100)},
				"Vence em " + Loc.date(e / 10000, (e / 100) % 100, e % 100)))
		var pay := rows[i].find_child("pay_button", true, false) as BaseButton
		if pay:
			view._set_button_text(pay, Loc.t("CV_ECONOMY_LOAN_REPAY", "Pagar"))
			pay.disabled = _tag != view.player or eco.money(_tag) < float(l["amount"])
			var idx := i
			pay.pressed.connect(func():
				eco.repay_loan(_tag, idx)
				view.refresh()
				_fill_loans())
	view._txt(rl, "title", Loc.s("Empréstimos (%d) — dívida de %s ducados", "Loans (%d) — debt of %s ducats") \
			% [ls.size(), AdvisorsWindow._n(eco.debt(_tag))] if not ls.is_empty() \
			else Loc.t("CV_ECONOMY_LOAN_NOREPAY_BUTTON_DESC", "Nenhum empréstimo"))


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
	return ("%.2f" % x).replace(".", Loc.dec)


static func _pct(x: float) -> String:
	return ("(%.1f%%)" % (x * 100.0)).replace(".", Loc.dec)


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
	view._txt(root, "window_title", Loc.t("HEADER_ECONOMY", "Economia") + " — " + c["name"])
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
	var tips := {"tax": Loc.s("Imposto base %d por ano ÷ 12 × (1 + modificador de impostos)",
					"Base tax %d per year ÷ 12 × (1 + tax modifier)") % bt,
			"production": Loc.s("Produção base %d × 0,2 × preço do produto por ano ÷ 12 × (1 + eficiência de produção)",
					"Base production %d × 0.2 × goods price per year ÷ 12 × (1 + production efficiency)") % bp,
			"gold": Loc.s("Cada unidade de ouro produzida rende 40 ducados por ano (e gera inflação)",
					"Each unit of gold produced yields 40 ducats per year (and causes inflation)"),
			"trade": _trade_tip(tag),
			"vassals": Loc.s("Vassalos pagam %d%% da renda de impostos deles", "Vassals pay %d%% of their tax income") \
					% roundi(100.0 * (Economy.VASSAL_FEE + pw.modifier(tag, "vassal_income")))}
	var incomes := root.find_child("incomes_listbox", true, false) as Control
	if incomes and not incomes.has_meta("wide"):     # o valor (x 170, 54 px) passa da lista de 180 px
		incomes.set_meta("wide", true)
		incomes.offset_right = incomes.offset_left + 232
	view.gui.fill_list(incomes, "", 0)
	for it in INCOMES:
		_line(incomes, Loc.t(it[2], it[1]), float(inc.get(it[0], 0.0)), grey.get(it[0], ""), GOOD,
				tips.get(it[0], Loc.s(NOT_YET[0], NOT_YET[1])))
	var expenses := root.find_child("expenses_listbox", true, false) as Control
	view.gui.fill_list(expenses, "", 0)
	var adv_names := []
	if view.advisors and view.advisors.enabled():
		for cat in Advisors.CATS:
			var a := view.advisors.get_hired(tag, cat)
			if not a.is_empty():
				adv_names.append("%s (%s %d)" % [a["name"], cat, int(a["skill"])])
	var etips := {"advisors": Loc.t("LEDGER_ADVISORS", "Conselheiros") + ": " + (", ".join(adv_names) \
			if not adv_names.is_empty() else Loc.s("nenhum", "none")) \
			+ Loc.s(" (salário +0,5% por ano desde 1444, + inflação)", " (salary +0.5% per year since 1444, + inflation)"),
			"interest": Loc.s("%d empréstimo(s), dívida de %s ducados", "%d loan(s), debt of %s ducats") \
					% [eco.loan_count(tag), AdvisorsWindow._n(eco.debt(tag))],
			"diplomatic": Loc.t("EXPENSEVASSAL", "Taxa paga ao suserano") if eco.vassal_fee(tag) > 0.0 else Loc.s("Nenhum", "None"),
			"corruption": Loc.s("Corrupção atual: %s (a barra cheia gasta 0,05 ducado por desenvolvimento e tira 1 por ano)",
					"Current corruption: %s (a full bar costs 0.05 ducats per development and removes 1 per year)") \
					% AdvisorsWindow._n(eco.corruption_of(tag)),
			"missionaries": (Loc.s("%d missionário(s) convertendo (0,5 + 5%% do desenvolvimento da província por mês)",
					"%d missionary(ies) converting (0.5 + 5%% of the province development per month)") \
					% view.religion.missions.get(tag, {}).size()) if view.religion else ""}
	for it in EXPENSES:
		_line(expenses, Loc.t(it[3], it[1]), float(exp.get(it[0], 0.0)), "", BAD,
				etips.get(it[0], Loc.s(NOT_YET[0], NOT_YET[1])))
		if it[2]:
			var s := view.gui.add_item(expenses, "countryeconomyview_listitem_slider")
			if s:
				s.get_parent().custom_minimum_size.y = 16
				var sl := s.find_child("slider", true, false) as Eu4Gui.ScrollBar2
				if sl and it[0] == "corruption":
					sl.set_value(float(eco.root_out.get(tag, 0.0)))
					sl.editable = mine
					sl.tooltip_text = Loc.t("EXPENSE_CORRUPTION", "Combate à corrupção") + ": %d%%" % roundi(sl.value * 100.0)
					sl.value_changed.connect(func(v: float):
						eco.set_root_out(tag, v)
						view.refresh())
				elif sl and it[0] == "missionaries" and view.religion:
					sl.set_value(view.religion.budget_of(tag))
					sl.editable = mine
					sl.tooltip_text = Loc.s("Missionários: %d%% (menos gasto, conversão mais lenta)",
							"Missionaries: %d%% (less spending, slower conversion)") % roundi(sl.value * 100.0)
					sl.value_changed.connect(func(v: float):
						view.religion.set_budget(tag, v)
						view.refresh())
				elif sl:
					sl.tooltip_text = Loc.s("Manutenção: 100% (ainda não ajustável)", "Maintenance: 100% (not adjustable yet)")
	view._txt(root, "incomes_total", _n(float(inc["total"])))
	view._txt(root, "expenses_total", _n(float(exp["total"])))
	_color("incomes_total", GOOD)
	_color("expenses_total", BAD)
	var bal := eco.balance(tag)
	view._txt(root, "balance", ("%+.2f" % bal).replace(".", Loc.dec),
			Loc.s("Por mês. Tesouro: %s ducados", "Per month. Treasury: %s ducats") % AdvisorsWindow._n(eco.money(tag)))
	_color("balance", GOOD if bal >= 0.0 else BAD)
	view._txt(root, "inflation_info", ("%.2f%%" % eco.inflation_of(tag)).replace(".", Loc.dec),
			Loc.s("Inflação: aumenta os gastos (conselheiros) nessa porcentagem",
			"Inflation: raises expenses (advisors) by this percentage"))
	view._txt(root, "war_exhaustion", Loc.s("0,0/20", "0.0/20"), Loc.t("WEXTITLE", "Cansaço de guerra") + " — " + Loc.s(NOT_YET[0], NOT_YET[1]))
	view._txt(root, "development_base", str(int(eco.development(tag))), Loc.t("country_development", "Desenvolvimento total"))
	# botões
	var size := eco.loan_size(tag)
	view._txt(root, "take_loan_sum", str(int(size)))
	_state("take_loan", mine and eco.can_take_loan(tag), Loc.s("Pedir um empréstimo de %d ducados a %s%% ao ano (%d de %d; +0,1 de inflação)",
			"Take a loan of %d ducats at %s%% per year (%d of %d; +0.1 inflation)") \
			% [int(size), AdvisorsWindow._n(eco.interest_rate(tag)), eco.loan_count(tag), eco.max_loans(tag)])
	_state("repay_loan", eco.loan_count(tag) > 0, Loc.t("CV_ECONOMY_LOAN_REPAY_BUTTON_DESC", "Ver e pagar empréstimos"))
	_state("repay_all_loans", mine and eco.loan_count(tag) > 0 and eco.money(tag) >= eco.debt(tag),
			Loc.s("Pagar todos os empréstimos (%s ducados)", "Repay all loans (%s ducats)") % AdvisorsWindow._n(eco.debt(tag)))
	_state("combat_inflation", mine and eco.can_reduce_inflation(tag),
			Loc.s("Reduzir a inflação em 2 por %d pontos administrativos", "Reduce inflation by 2 for %d administrative points") \
			% eco.reduce_inflation_cost(tag))
	_state("debase_currency", mine and eco.can_debase(tag),
			Loc.s("Desvalorizar a moeda: +%d ducados por +2 de corrupção (corrupção atual %s)",
			"Debase currency: +%d ducats for +2 corruption (current corruption %s)") % [int(size),
			AdvisorsWindow._n(eco.corruption_of(tag))])
	_state("go_bankrupt", mine and eco.can_declare_bankruptcy(tag), Loc.s("Declarar falência (precisa ter empréstimos)",
			"Declare bankruptcy (needs loans)") if not eco.is_bankrupt(tag) else Loc.t("bankruptcy", "Em falência"))
	if _chart:
		_chart.queue_redraw()
		_chart.tooltip_text = Loc.s("Inflação nos últimos 10 anos", "Inflation over the last 10 years")
	var rl := root.find_child("countryeconomyview_repayloan", true, false) as Control
	if rl and rl.visible:
		_fill_loans()


func _trade_tip(tag: String) -> String:
	var tv: Trade = view.map.trade_view
	if tv == null or not tv.enabled():
		return Loc.s("Sem nós de comércio no mapa", "No trade nodes on the map")
	var parts := []
	for i in tv.collected.size():
		if tv.collected[i].has(tag):
			var nid: String = tv.nodes[i]
			parts.append(Loc.s("%s: %s (%d%% do poder%s)", "%s: %s (%d%% of the power%s)") % [view.map.trade_nodes[nid]["name"],
					_n(tv.collected[i][tag]), roundi(tv.share(tag, i) * 100.0), Loc.s(", capital comercial", ", trade capital") \
					if i == tv.home(tag) else Loc.s(", mercador", ", merchant")])
	return Loc.s("Coleta de comércio por mês:\n", "Trade collected per month:\n") + ("\n".join(parts) if not parts.is_empty() \
			else Loc.s("nenhuma", "none"))


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
