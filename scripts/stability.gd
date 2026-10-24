class_name Stability
extends RefCounted
## Estabilidade dos países, regras do EU4:
##  - Vai de −3 a +3; em 1444 todo país começa com 0 (como no EU4: Suécia e Noruega mostram +0).
##  - Aumentar (`boost`) custa PS_BOOST_STABILITY (100) pontos adm × (1 + stability_cost_modifier);
##    cada ponto de estabilidade positiva soma +50% ao custo (modificador estático positive_stability).
##  - Efeitos: modificadores estáticos `stability` × estabilidade, `positive_stability` × estabilidade
##    (se > 0: +5% de impostos, +0,5% de força missionária, −0,02 de corrupção anual, +5% de difusão
##    de instituições...) e `negative_stability` × estabilidade (se < 0: +1 de juros, −1 de
##    legitimidade, +2 de agitação... por ponto). Somados em `MonarchPower.modifier` fora do cache.
##  - Perdas: romper casamento real (BREAK_MARRIAGE_STABILITY_PENALTY, −1). `add(tag, n)` para as
##    futuras (morte do monarca, guerras, eventos).
##  - IA: aumenta quando está abaixo de +1 e tem os pontos.

signal changed(tag: String)

const MIN := -3
const MAX := 3
const START := 0
const AI_TARGET := 1             # a IA aumenta a estabilidade até aqui
## Efeitos mostrados na dica (os de estamentos, harmonia, decadência... ficam de fora).
const TIP_KEYS := ["global_tax_modifier", "global_missionary_strength", "yearly_corruption",
		"global_institution_spread", "stability_cost_modifier", "global_trade_power", "global_spy_defence",
		"interest", "legitimacy", "global_unrest"]

var map: MapView
var clock: GameClock
var power: MonarchPower
var value := {}                  # tag -> estabilidade
var fmt_mods: Callable           # efeitos -> texto (IdeasWindow.fmt_mods), para a dica
var _all := {}                   # efeitos por ponto (modificador estático `stability`)
var _pos := {}                   # positive_stability
var _neg := {}                   # negative_stability
var _rules := {}


func setup(m: MapView, c: GameClock, pw: MonarchPower) -> void:
	map = m
	clock = c
	power = pw
	_rules = map.trade_rules
	var st: Dictionary = _rules.get("statics", {})
	_all = st.get("stability", {})
	_pos = st.get("positive_stability", {})
	_neg = st.get("negative_stability", {})
	if _pos.is_empty():          # sem os dados importados: os principais efeitos do EU4
		_pos = {"global_unrest": -1, "global_tax_modifier": 0.05, "global_missionary_strength": 0.005,
				"stability_cost_modifier": 0.5, "yearly_corruption": -0.02, "global_institution_spread": 0.05}
	if _neg.is_empty():
		_neg = {"global_unrest": -2, "legitimacy": 1, "interest": -1}
	if _all.is_empty():
		_all = {"global_trade_power": 0.01, "global_spy_defence": 0.05}
	for t in map.countries:
		value[t] = START
	pw.stability = self
	clock.month_passed.connect(_on_month)


func of(tag: String) -> int:
	return int(value.get(tag, START))


## Muda a estabilidade em `n` (fica entre −3 e +3).
func add(tag: String, n: int) -> void:
	value[tag] = clampi(of(tag) + n, MIN, MAX)
	power.invalidate(tag)        # impostos e juros em cache da economia
	if tag == power.player:
		changed.emit(tag)
		power.notify(tag)


## Parte de um efeito que vem da estabilidade atual.
func effect(tag: String, key: String) -> float:
	var s := of(tag)
	if s == 0:
		return 0.0
	var v := float(_all.get(key, 0.0)) * s
	v += float(_pos.get(key, 0.0)) * s if s > 0 else float(_neg.get(key, 0.0)) * s
	return v


## Todos os efeitos da estabilidade atual: chave -> valor.
func effects(tag: String) -> Dictionary:
	var out := {}
	var s := of(tag)
	if s == 0:
		return out
	for d in [_all, _pos if s > 0 else _neg]:
		for k in d:
			if d[k] is float or d[k] is int:
				out[k] = float(out.get(k, 0.0)) + float(d[k]) * s
	return out


func cost(tag: String) -> int:
	return roundi(float(_rules.get("ps_boost_stability", 100)) \
			* maxf(0.0, 1.0 + power.modifier(tag, "stability_cost_modifier")))


## Motivo de não poder aumentar ("" = pode).
func why_not(tag: String) -> String:
	if of(tag) >= MAX:
		return Loc.s("A estabilidade já está no máximo (+3)", "Stability is already at its maximum (+3)")
	if power.points(tag, "adm") < cost(tag):
		return Loc.s("Faltam pontos administrativos (%d de %d)", "Not enough administrative power (%d of %d)") % [
				power.points(tag, "adm"), cost(tag)]
	return ""


func boost(tag: String) -> bool:
	if why_not(tag) != "":
		return false
	power.state[tag]["points"]["adm"] -= cost(tag)
	add(tag, 1)
	return true


## Romper casamento real: −1 (define BREAK_MARRIAGE_STABILITY_PENALTY).
func on_break_marriage(tag: String) -> void:
	add(tag, int(_rules.get("break_marriage_stability_penalty", -1)))


## Texto da dica: valor, custo de aumentar e efeitos atuais.
func tooltip(tag: String) -> String:
	var t := Loc.s("Estabilidade: %s", "Stability: %s") % fmt(of(tag))
	if of(tag) < MAX:
		t += "\n" + Loc.s("Aumentar custa %d pontos administrativos", "Increasing costs %d administrative power") % cost(tag)
	var all := effects(tag)
	var e := {}
	for k in TIP_KEYS:
		if all.has(k) and float(all[k]) != 0.0:
			e[k] = all[k]
	if not e.is_empty() and fmt_mods.is_valid():
		t += "\n" + Loc.s("Efeitos: ", "Effects: ") + str(fmt_mods.call(e))
	return t


static func fmt(s: int) -> String:
	return ("%+d" % s) if s != 0 else "0"


func _on_month() -> void:
	for t in value:
		if t != power.player and of(t) < AI_TARGET and why_not(t) == "":
			boost(t)
