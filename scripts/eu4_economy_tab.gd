class_name Eu4EconomyTab
extends RefCounted
## Aba Economia da tela do país do EU4 (countryeconomyview.gui), com todas as linhas do EU4:
## receitas (com a parte de cada uma no total, em cinza) e despesas (as de manutenção com a barra
## deslizante), totais, saldo, inflação, cansaço de guerra e desenvolvimento. O jogo hoje só tem
## imposto, produção e conselheiros: as outras linhas ficam em 0,00, as barras no máximo e os botões
## (empréstimos, impostos de guerra, inflação, falência) aparecem desativados.

const INCOMES := [["tax", "Impostos"], ["production", "Produção"], ["trade", "Comércio"], ["gold", "Ouro"],
		["tariffs", "Tarifas"], ["vassals", "Vassalos"], ["harbor", "Taxas portuárias"], ["subsidies", "Subsídios"],
		["spoils", "Espólios de guerra"], ["reparations", "Reparações de guerra"], ["condottieri", "Condottieri"],
		["knowledge", "Partilha de conhecimento"]]
## [chave, nome, tem barra de manutenção]
const EXPENSES := [["advisors", "Conselheiros", false], ["states", "Manutenção dos estados", false],
		["interest", "Juros", false], ["diplomatic", "Gastos diplomáticos", false], ["forts", "Manutenção dos fortes", false],
		["colonial", "Manutenção colonial", true], ["missionaries", "Manutenção de missionários", true],
		["corruption", "Combate à corrupção", true], ["army", "Manutenção do exército", true],
		["fleet", "Manutenção da frota", true]]
const BUTTONS := {"debase_currency": "Desvalorizar a moeda", "take_loan": "Pedir empréstimo",
		"repay_loan": "Pagar empréstimo", "repay_all_loans": "Pagar todos os empréstimos",
		"raise_wartaxes": "Impostos de guerra", "combat_inflation": "Combater a inflação",
		"go_bankrupt": "Declarar falência"}
const HIDE := ["inflation_linechart", "take_loan_sum", "countryeconomyview_repayloan"]
const GOOD := Color(0.55, 0.9, 0.45)
const BAD := Color(1.0, 0.42, 0.35)
const ZERO := Color(0.95, 0.9, 0.6)

var view: Eu4CountryView
var root: Control


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countryeconomyview")
	if root == null:
		return false
	for n in HIDE:
		Eu4CountryView._hide(root, n)
	for n in BUTTONS:
		var b := root.find_child(n, true, false) as BaseButton
		if b:
			b.disabled = true
			b.modulate = Color(0.75, 0.75, 0.75)
			b.tooltip_text = BUTTONS[n] + " (ainda não existe no jogo)"
	view._txt(root, "incomes", "Receitas")
	view._txt(root, "expenses", "Despesas")
	view._txt(root, "incomes_total_text", "Receita total:")
	view._txt(root, "expences_total_text", "Despesa total:")
	view._txt(root, "balance_title", "Saldo:")
	return true


static func _n(x: float) -> String:
	return ("%.2f" % x).replace(".", ",")


func _line(list: Control, name: String, value: float, share: String, color: Color, tip := "") -> void:
	var row := view.gui.add_item(list, "countryeconomyview_listitem")
	if row == null:
		return
	view._txt(row, "name", name, tip)
	view._txt(row, "value2", share)
	view._txt(row, "value", _n(value), tip)
	var l := row.find_child("value", true, false) as Label
	if l:
		l.add_theme_color_override("font_color", color if absf(value) >= 0.005 else ZERO)


func fill(tag: String) -> void:
	var map := view.map
	var eco := view.economy
	var c: Dictionary = map.countries[tag]
	view._txt(root, "window_title", "Economia — " + c["name"])
	var inc := eco.income(tag)
	var exp := eco.expenses(tag)
	var bt := 0
	var bp := 0
	var dev := 0
	for p in map.provinces:
		if p["owner"] == tag:
			bt += int(p.get("base_tax", 0))
			bp += int(p.get("base_production", 0))
			dev += int(p["development"])
	var total := float(inc["total"])
	var tips := {"tax": "Imposto base %d por ano ÷ 12, com o modificador de impostos" % bt,
			"production": "Produção base %d × 0,2 × preço do produto por ano ÷ 12, com a eficiência de produção" % bp}
	var incomes := root.find_child("incomes_listbox", true, false) as Control
	if incomes and not incomes.has_meta("wide"):     # o valor (x 170, 54 px) passa da lista de 180 px
		incomes.set_meta("wide", true)
		incomes.offset_right = incomes.offset_left + 232
	view.gui.fill_list(incomes, "", 0)
	for it in INCOMES:
		var v := float(inc.get(it[0], 0.0))
		var share := "(%.1f%%)" % (v / total * 100.0) if total > 0.0 and v > 0.0 else ""
		_line(incomes, it[1], v, share.replace(".", ","), GOOD, tips.get(it[0], "Ainda não existe no jogo"))
	var expenses := root.find_child("expenses_listbox", true, false) as Control
	view.gui.fill_list(expenses, "", 0)
	var adv_names := []
	if view.advisors and view.advisors.enabled():
		for cat in Advisors.CATS:
			var a := view.advisors.get_hired(tag, cat)
			if not a.is_empty():
				adv_names.append("%s (%s %d)" % [a["name"], cat, int(a["skill"])])
	for it in EXPENSES:
		var v := float(exp.get(it[0], 0.0))
		var tip := ("Conselheiros: " + (", ".join(adv_names) if not adv_names.is_empty() else "nenhum")) \
				if it[0] == "advisors" else "Ainda não existe no jogo"
		_line(expenses, it[1], v, "", BAD, tip)
		if it[2]:
			var s := view.gui.add_item(expenses, "countryeconomyview_listitem_slider")
			if s:
				s.get_parent().custom_minimum_size.y = 16
				var sl := s.find_child("slider", true, false) as Control
				if sl:
					sl.tooltip_text = "Manutenção: 100% (ainda não ajustável)"
	view._txt(root, "incomes_total", _n(total))
	view._txt(root, "expenses_total", _n(float(exp["total"])))
	_color("incomes_total", GOOD)
	_color("expenses_total", BAD)
	var bal := eco.balance(tag)
	view._txt(root, "balance", ("%+.2f" % bal).replace(".", ","),
			"Por mês. Tesouro: %s ducados" % AdvisorsWindow._n(eco.money(tag)))
	_color("balance", GOOD if bal >= 0.0 else BAD)
	view._txt(root, "inflation_info", "0,00%", "Inflação (ainda não existe no jogo)")
	view._txt(root, "war_exhaustion", "0,0/20", "Cansaço de guerra (ainda não existe no jogo)")
	view._txt(root, "development_base", str(dev), "Desenvolvimento total")


func _color(n: String, col: Color) -> void:
	var l := root.find_child(n, true, false) as Label
	if l:
		l.add_theme_color_override("font_color", col)
