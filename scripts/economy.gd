class_name Economy
extends RefCounted
## Tesouro de cada país (ducados). Primeira versão, simples:
##  - renda de imposto: cada ponto de imposto (base_tax) rende 1 ducado por ano;
##  - renda de produção: cada ponto de produção produz 0,2 de mercadoria por ano, vendida pelo preço
##    do produto da província (2,5 se não houver produto);
##  - os efeitos "imposto" (global_tax_modifier) e "eficiência de produção" das ideias e conselheiros
##    aumentam essas rendas;
##  - gastos: salário dos conselheiros.
## No mapa sem imposto/produção separados, o desenvolvimento é dividido em três partes iguais.

signal changed(tag: String)

const START_TREASURY := 100.0
const GOODS_PER_PRODUCTION := 0.2
const DEFAULT_PRICE := 2.5

var map: MapView
var clock: GameClock
var power: MonarchPower
var advisors: Advisors
var treasury := {}               # tag -> ducados
var _counted_version := -1
var _base := {}                  # tag -> {"tax": por ano, "prod": por ano} (recalculado todo mês)


func setup(m: MapView, c: GameClock, pw: MonarchPower, adv: Advisors) -> void:
	map = m
	clock = c
	power = pw
	advisors = adv
	for tag in map.countries:
		treasury[tag] = START_TREASURY
	_recount()
	clock.month_passed.connect(_on_month)


## Soma imposto e produção (ducados por ano, sem modificadores) de todos os países numa passada.
func _recount() -> void:
	_counted_version = map.owner_version
	_base.clear()
	for p in map.provinces:
		var tag: String = p["owner"]
		if tag == "" or p["sea"]:
			continue
		var tax := float(p.get("base_tax", float(p["development"]) / 3.0))
		var prod := float(p.get("base_production", float(p["development"]) / 3.0))
		var gid: String = p.get("trade_goods", "")
		var price := float(map.trade_goods[gid]["price"]) if map.trade_goods.has(gid) else DEFAULT_PRICE
		if not _base.has(tag):
			_base[tag] = {"tax": 0.0, "prod": 0.0}
		_base[tag]["tax"] += tax
		_base[tag]["prod"] += prod * GOODS_PER_PRODUCTION * price


## Renda mensal: {"tax", "production", "total"}.
func income(tag: String) -> Dictionary:
	var b: Dictionary = _base.get(tag, {"tax": 0.0, "prod": 0.0})
	var tax: float = b["tax"] / 12.0 * maxf(0.0, 1.0 + power.modifier(tag, "global_tax_modifier"))
	var prod: float = b["prod"] / 12.0 * maxf(0.0, 1.0 + power.modifier(tag, "production_efficiency"))
	return {"tax": tax, "production": prod, "total": tax + prod}


## Gastos mensais: {"advisors", "total"}.
func expenses(tag: String) -> Dictionary:
	var adv := advisors.total_salary(tag) if advisors else 0.0
	return {"advisors": adv, "total": adv}


func balance(tag: String) -> float:
	return float(income(tag)["total"]) - float(expenses(tag)["total"])


func money(tag: String) -> float:
	return float(treasury.get(tag, 0.0))


func spend(tag: String, amount: float) -> bool:
	if money(tag) < amount:
		return false
	treasury[tag] = money(tag) - amount
	if tag == power.player:
		changed.emit(tag)
	return true


func _on_month() -> void:
	if map.owner_version != _counted_version:   # só recalcula quando algum dono muda
		_recount()
	for tag in treasury:
		treasury[tag] = money(tag) + balance(tag)
		# sem empréstimos ainda: no vermelho, o país dispensa o conselheiro mais caro
		while treasury[tag] < 0.0 and advisors and advisors.dismiss_most_expensive(tag):
			pass
	changed.emit(power.player)
