class_name Economy
extends RefCounted
## Tesouro de cada país (ducados), com as regras do EU4 (eu4.paradoxwikis.com/Economy):
##  Receitas (por mês = por ano ÷ 12):
##   - impostos: imposto base × (1 + modificador de impostos);
##   - produção: produção base × 0,2 × preço do produto × (1 + eficiência de produção);
##   - ouro: o ouro não é vendido; cada unidade produzida (produção base × 0,2) rende 40 ducados por
##     ano e gera inflação de 0,5 por ano × a parte do ouro na receita;
##   - vassalos: cada vassalo (e apanágio) paga 10% (+ vassal_income) da sua renda de impostos ao
##     suserano — para o vassalo é um gasto diplomático.
##  Despesas: conselheiros (salário × inflação), juros dos empréstimos, gastos diplomáticos e
##  combate à corrupção (barra de 0 a 0,05 ducado por desenvolvimento por mês; no máximo tira 1 de
##  corrupção por ano). Manutenção de exército, frota, fortes, colônias e estados ainda não existem.
##  Empréstimos: tamanho = piso(0,5 × desenvolvimento) × (1 + eficiência comercial da tecnologia
##  diplomática); juros de 4% ao ano (+ interest; +5 na falência; mínimo 1%); máximo de empréstimos
##  = renda mensal ÷ juros mensais de um empréstimo; cada um dura 5 anos e, se não houver dinheiro
##  para pagar no vencimento, é renovado por mais 5 (+0,1 de inflação, como ao pedir). No vermelho, o
##  país pede empréstimos sozinho; sem poder pedir mais, vai à falência.
##  Inflação: soma-se aos gastos (salários dos conselheiros, em Advisors.salary); cai por ano com inflation_reduction
##  (Mestre da casa da moeda, ideias) e com "Reduzir inflação" (−2 por 75 pontos adm).
##  Desvalorizar a moeda: um empréstimo de dinheiro sem dívida, por +2 de corrução (até 90).
##  Falência: zera empréstimos, tesouro e pontos de monarca (−100), tira 25% da inflação, dispensa
##  os conselheiros e por 5 anos dá juros +5, conselheiros, tecnologia e ideias 50% mais caros e
##  difusão de instituições −50%.

signal changed(tag: String)

const START_TREASURY := 100.0
const GOODS_PER_PRODUCTION := 0.2
const DEFAULT_PRICE := 2.5
const GOLD_PER_UNIT := 40.0            # ducados por ano por unidade de ouro produzida
const GOLD_INFLATION := 0.5            # inflação por ano com 100% da receita vinda do ouro
const VASSAL_FEE := 0.10               # parte da renda de impostos que o vassalo paga
const VASSAL_TYPES := ["vassal", "appanage"]
const BASE_INTEREST := 4.0             # % ao ano
const LOAN_YEARS := 5
const LOAN_INFLATION := 0.1
const REDUCE_INFLATION := 2.0
const REDUCE_INFLATION_COST := 75
const MAX_ROOT_OUT := 0.05             # ducados por desenvolvimento por mês
const DEBASE_CORRUPTION := 2.0
const DEBASE_MAX_CORRUPTION := 90.0
const BANKRUPTCY_YEARS := 5
const BANKRUPTCY_MODS := {"interest": 5.0, "advisor_cost": 0.5, "technology_cost": 0.5, "idea_cost": 0.5,
		"global_institution_spread": -0.5}
const AI_REPAY_MARGIN := 2.0           # a IA paga um empréstimo quando tem o dobro do valor

var map: MapView
var clock: GameClock
var power: MonarchPower
var advisors: Advisors
var diplomacy: Diplomacy               # main.gd define (vassalos)
var trade: Trade                       # main.gd define (renda de comércio)
var religion: Religion                 # main.gd define (manutenção dos missionários)
var treasury := {}                     # tag -> ducados
var loans := {}                        # tag -> [{amount, rate, expires (AAAAMMDD)}]
var inflation := {}                    # tag -> %
var corruption := {}                   # tag -> 0..100
var root_out := {}                     # tag -> 0..1 (barra de combate à corrupção)
var bankrupt_until := {}               # tag -> AAAAMMDD
var history := {}                      # tag -> PackedFloat32Array (inflação dos últimos 120 meses)
var _counted_version := -1
var _base := {}                        # tag -> {"tax", "prod", "gold" (unidades), "dev"} por ano
var _overlord := {}                    # vassalo -> suserano que recebe a taxa
var _vassals := {}                     # suserano -> [vassalos que pagam]
var _inc_cache := {}                   # tag -> income() (limpo todo mês e quando os efeitos mudam)


func setup(m: MapView, c: GameClock, pw: MonarchPower, adv: Advisors) -> void:
	map = m
	clock = c
	power = pw
	advisors = adv
	for tag in map.countries:
		treasury[tag] = START_TREASURY
	_recount()
	clock.month_passed.connect(_on_month)
	clock.year_passed.connect(_on_year)


func _today() -> int:
	return clock.year * 10000 + clock.month * 100 + clock.day


## Soma imposto, produção, ouro e desenvolvimento (por ano, sem modificadores) numa passada.
func _recount() -> void:
	_counted_version = map.owner_version
	_inc_cache.clear()
	_base.clear()
	for p in map.provinces:
		var tag: String = p["owner"]
		if tag == "" or p["sea"]:
			continue
		# construções: local_tax_modifier, local_production_efficiency e trade_goods_size (manufaturas)
		var tax := float(p.get("base_tax", float(p["development"]) / 3.0)) * (1.0 + map.building_mod(p, "local_tax_modifier"))
		var goods := map.goods_produced(p)
		var prod_eff := 1.0 + map.building_mod(p, "local_production_efficiency")
		var gid: String = p.get("trade_goods", "")
		if not _base.has(tag):
			_base[tag] = {"tax": 0.0, "prod": 0.0, "gold": 0.0, "dev": 0.0}
		_base[tag]["tax"] += tax
		_base[tag]["dev"] += float(p["development"])
		if gid == "gold":
			_base[tag]["gold"] += goods
		else:
			var price := float(map.trade_goods[gid]["price"]) if map.trade_goods.has(gid) else DEFAULT_PRICE
			_base[tag]["prod"] += goods * price * prod_eff
	_overlord.clear()
	_vassals.clear()
	if diplomacy:
		for r in diplomacy.relations:
			var kind: String = r.get("subject_type", r["type"])
			if kind in VASSAL_TYPES:
				_overlord[r["second"]] = r["first"]
				if not _vassals.has(r["first"]):
					_vassals[r["first"]] = []
				_vassals[r["first"]].append(r["second"])


func _b(tag: String) -> Dictionary:
	return _base.get(tag, {"tax": 0.0, "prod": 0.0, "gold": 0.0, "dev": 0.0})


func development(tag: String) -> float:
	return float(_b(tag)["dev"])


func _tax(tag: String) -> float:
	return float(_b(tag)["tax"]) / 12.0 * maxf(0.0, 1.0 + power.modifier(tag, "global_tax_modifier"))


## Taxa mensal que o vassalo `tag` paga ao suserano (0 se não for vassalo).
func vassal_fee(tag: String) -> float:
	if not _overlord.has(tag):
		return 0.0
	return _tax(tag) * maxf(0.0, VASSAL_FEE + power.modifier(_overlord[tag], "vassal_income"))


## Renda mensal: {"tax", "production", "trade", "gold", "vassals", "total"} (as outras linhas do EU4 são 0).
func income(tag: String) -> Dictionary:
	if _inc_cache.has(tag):
		return _inc_cache[tag]
	var b := _b(tag)
	var tax := _tax(tag)
	var prod: float = b["prod"] / 12.0 * maxf(0.0, 1.0 + power.modifier(tag, "production_efficiency"))
	var gold: float = b["gold"] * GOLD_PER_UNIT / 12.0
	var vas := 0.0
	for v in _vassals.get(tag, []):
		vas += vassal_fee(v)
	var tr := trade.income(tag) if trade else 0.0
	var out := {"tax": tax, "production": prod, "trade": tr, "gold": gold, "vassals": vas,
			"total": tax + prod + tr + gold + vas}
	_inc_cache[tag] = out
	return out


## Esquece a renda guardada (efeitos do país mudaram; o suserano depende do imposto do vassalo).
func invalidate(tag: String) -> void:
	_inc_cache.erase(tag)
	if _overlord.has(tag):
		_inc_cache.erase(_overlord[tag])


## Gastos mensais: {"advisors", "interest", "diplomatic", "corruption", "missionaries", "total"}.
func expenses(tag: String) -> Dictionary:
	var adv := advisors.total_salary(tag) if advisors else 0.0     # já com a inflação
	var interest := 0.0
	for l in loans.get(tag, []):
		interest += float(l["amount"]) * float(l["rate"]) / 100.0 / 12.0
	var dip := vassal_fee(tag)
	var cor := root_out_cost(tag)
	var mis := religion.cost(tag) if religion else 0.0
	return {"advisors": adv, "interest": interest, "diplomatic": dip, "corruption": cor, "missionaries": mis,
			"total": adv + interest + dip + cor + mis}


func balance(tag: String) -> float:
	return float(income(tag)["total"]) - float(expenses(tag)["total"])


func money(tag: String) -> float:
	return float(treasury.get(tag, 0.0))


func spend(tag: String, amount: float) -> bool:
	if money(tag) < amount:
		return false
	treasury[tag] = money(tag) - amount
	_changed(tag)
	return true


func _changed(tag: String) -> void:
	if tag == power.player:
		changed.emit(tag)


# ------------------------------------------------------------------ empréstimos
func is_bankrupt(tag: String) -> bool:
	return int(bankrupt_until.get(tag, 0)) > _today()


## Juros ao ano (%) de um empréstimo novo.
func interest_rate(tag: String) -> float:
	return maxf(1.0, BASE_INTEREST + power.modifier(tag, "interest"))


## Eficiência comercial vinda da tecnologia diplomática (aumenta o tamanho dos empréstimos).
func _tech_trade_efficiency(tag: String) -> float:
	var lvl := TechWindow.level_of(map, tag, "dip", power)
	var s := 0.0
	var techs: Array = map.technologies.get("dip", [])
	for i in mini(lvl + 1, techs.size()):
		s += float(techs[i].get("modifiers", {}).get("trade_efficiency", 0.0))
	return s


func loan_size(tag: String) -> float:
	return maxf(1.0, floorf(0.5 * development(tag)) * (1.0 + _tech_trade_efficiency(tag)))


func loan_count(tag: String) -> int:
	return loans.get(tag, []).size()


func debt(tag: String) -> float:
	var d := 0.0
	for l in loans.get(tag, []):
		d += float(l["amount"])
	return d


## Quantos empréstimos o país pode ter: renda mensal ÷ juros mensais de um empréstimo.
func max_loans(tag: String) -> int:
	var per := loan_size(tag) * interest_rate(tag) / 100.0 / 12.0
	return int(floorf(float(income(tag)["total"]) / per)) if per > 0.0 else 0


func can_take_loan(tag: String) -> bool:
	return loan_count(tag) < max_loans(tag)


func take_loan(tag: String) -> bool:
	if not can_take_loan(tag):
		return false
	var size := loan_size(tag)
	if not loans.has(tag):
		loans[tag] = []
	loans[tag].append({"amount": size, "rate": interest_rate(tag),
			"expires": _today() + LOAN_YEARS * 10000})
	treasury[tag] = money(tag) + size
	_add_inflation(tag, LOAN_INFLATION)
	_changed(tag)
	return true


## Paga o empréstimo `i` (o mais antigo se -1).
func repay_loan(tag: String, i := 0) -> bool:
	var ls: Array = loans.get(tag, [])
	if i < 0 or i >= ls.size() or money(tag) < float(ls[i]["amount"]):
		return false
	treasury[tag] = money(tag) - float(ls[i]["amount"])
	ls.remove_at(i)
	_changed(tag)
	return true


func repay_all(tag: String) -> bool:
	if loan_count(tag) == 0 or money(tag) < debt(tag):
		return false
	treasury[tag] = money(tag) - debt(tag)
	loans[tag] = []
	_changed(tag)
	return true


# ------------------------------------------------------------------ inflação e corrupção
func inflation_of(tag: String) -> float:
	return float(inflation.get(tag, 0.0))


func _add_inflation(tag: String, v: float) -> void:
	inflation[tag] = maxf(0.0, inflation_of(tag) + v)


func reduce_inflation_cost(tag: String) -> int:
	return roundi(REDUCE_INFLATION_COST * maxf(0.0, 1.0 + power.modifier(tag, "reduce_inflation_cost")))


func can_reduce_inflation(tag: String) -> bool:
	return inflation_of(tag) > 0.0 and power.points(tag, "adm") >= reduce_inflation_cost(tag)


func reduce_inflation(tag: String) -> bool:
	if not can_reduce_inflation(tag):
		return false
	power.state[tag]["points"]["adm"] = power.points(tag, "adm") - reduce_inflation_cost(tag)
	_add_inflation(tag, -REDUCE_INFLATION)
	power.notify(tag)
	_changed(tag)
	return true


func corruption_of(tag: String) -> float:
	return float(corruption.get(tag, 0.0))


func can_debase(tag: String) -> bool:
	return corruption_of(tag) + DEBASE_CORRUPTION <= DEBASE_MAX_CORRUPTION


func debase_currency(tag: String) -> bool:
	if not can_debase(tag):
		return false
	treasury[tag] = money(tag) + loan_size(tag)
	corruption[tag] = corruption_of(tag) + DEBASE_CORRUPTION
	_changed(tag)
	return true


func root_out_cost(tag: String) -> float:
	return float(root_out.get(tag, 0.0)) * MAX_ROOT_OUT * development(tag)


func set_root_out(tag: String, v: float) -> void:
	root_out[tag] = clampf(v, 0.0, 1.0)
	_changed(tag)


# ------------------------------------------------------------------ falência
func can_declare_bankruptcy(tag: String) -> bool:
	return loan_count(tag) > 0 and not is_bankrupt(tag)


func declare_bankruptcy(tag: String) -> void:
	loans[tag] = []
	if not is_bankrupt(tag):
		inflation[tag] = inflation_of(tag) * 0.75
	treasury[tag] = 0.0
	bankrupt_until[tag] = _today() + BANKRUPTCY_YEARS * 10000
	if advisors:
		while advisors.dismiss_most_expensive(tag):
			pass
	if power.state.has(tag):
		for cat in MonarchPower.CATS:
			power.state[tag]["points"][cat] = -100
	power.invalidate(tag)
	power.notify(tag)
	_changed(tag)


## Efeitos da falência (somados em MonarchPower.modifier).
func modifiers(tag: String) -> Dictionary:
	return BANKRUPTCY_MODS if is_bankrupt(tag) else {}


# ------------------------------------------------------------------ mês e ano
func _on_month() -> void:
	if map.owner_version != _counted_version:   # só recalcula quando algum dono muda
		_recount()
	_inc_cache.clear()
	if trade:
		trade.recompute()
	var today := _today()
	for tag in treasury:
		var inc := income(tag)
		treasury[tag] = money(tag) + float(inc["total"]) - float(expenses(tag)["total"])
		# ouro gera inflação conforme a parte dele na receita
		if float(inc["total"]) > 0.0 and float(inc["gold"]) > 0.0:
			var mod := 1.0 + power.modifier(tag, "monthly_gold_inflation_modifier")
			_add_inflation(tag, GOLD_INFLATION / 12.0 * float(inc["gold"]) / float(inc["total"]) * maxf(0.0, mod))
		# combate à corrupção: no máximo −1 por ano
		if float(root_out.get(tag, 0.0)) > 0.0:
			corruption[tag] = maxf(0.0, corruption_of(tag) - float(root_out[tag]) / 12.0)
		# vencimento dos empréstimos: paga se puder, senão renova
		var ls: Array = loans.get(tag, [])
		for l in ls.duplicate():
			if int(l["expires"]) <= today:
				if money(tag) >= float(l["amount"]):
					treasury[tag] = money(tag) - float(l["amount"])
					ls.erase(l)
				else:
					l["expires"] = int(l["expires"]) + LOAN_YEARS * 10000
					_add_inflation(tag, LOAN_INFLATION)
		# no vermelho: empréstimos; sem poder pedir mais, falência
		while treasury[tag] < 0.0:
			if not take_loan(tag):
				declare_bankruptcy(tag)
				break
		# IA paga empréstimos quando sobra dinheiro
		if tag != power.player:
			while loan_count(tag) > 0 and money(tag) >= float(loans[tag][0]["amount"]) * AI_REPAY_MARGIN:
				repay_loan(tag, 0)
		if bankrupt_until.has(tag) and int(bankrupt_until[tag]) <= today:
			bankrupt_until.erase(tag)
			power.invalidate(tag)
		if tag == power.player:
			if not history.has(tag):
				history[tag] = PackedFloat32Array()
			history[tag].append(inflation_of(tag))
			if history[tag].size() > 120:
				history[tag] = history[tag].slice(history[tag].size() - 120)
	changed.emit(power.player)


func _on_year() -> void:
	for tag in treasury:
		var red := power.modifier(tag, "inflation_reduction")
		if red > 0.0 and inflation_of(tag) > 0.0:
			_add_inflation(tag, -red)
		var yc := power.modifier(tag, "yearly_corruption")
		if yc != 0.0:
			corruption[tag] = clampf(corruption_of(tag) + yc, 0.0, 100.0)
