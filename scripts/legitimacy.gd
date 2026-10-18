class_name Legitimacy
extends RefCounted
## Legitimidade das monarquias (e dos governos tribais que não são hordas), regras do EU4:
##  - Vai de 0 a 100; em 1444 começa em 100. Repúblicas, teocracias, nativos e hordas não têm
##    (no EU4 usam tradição republicana, devoção, unidade da horda...).
##  - Por mês += legitimidade anual ÷ 12: efeito `legitimacy` (ideias, conselheiros; +1 com 100 de
##    prestígio e −1 por ponto de estabilidade negativa, que já entram em `MonarchPower.modifier`)
##    + 0,1 por casamento real (modificador estático num_of_marriages). Não há ganho básico.
##  - Efeitos: modificador estático `legitimacy` × (legitimidade − 50) ÷ 100 (com 100: −2 de
##    agitação, +1 de tolerância, +1 de reputação diplomática, +5% de renda dos vassalos...; abaixo
##    de 50 o contrário). Somados em `MonarchPower.modifier` fora do cache.
##  - Casamento real: quem tem mais prestígio perde 2 e quem tem mais legitimidade perde 3
##    (FORM_MARRIAGE_HIGHER_PRESTIGE/LEGITIMACY). `add(tag, n)` para as futuras (herdeiros, eventos).

signal changed(tag: String)

const MIN := 0.0
const MAX := 100.0
const START := 100.0
## Efeitos mostrados na dica.
const TIP_KEYS := ["global_unrest", "tolerance_own", "tolerance_heretic", "tolerance_heathen",
		"diplomatic_reputation", "vassal_income", "max_absolutism"]

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var prestige: Prestige
var value := {}                  # tag -> legitimidade (só os países que a usam)
var fmt_mods: Callable           # efeitos -> texto (IdeasWindow.fmt_mods), para a dica
var _effects := {}               # modificador estático `legitimacy` (por (legitimidade − 50) ÷ 100)
var _per_marriage := 0.1
var _rules := {}


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, pr: Prestige) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	prestige = pr
	_rules = map.trade_rules
	var st: Dictionary = _rules.get("statics", {})
	_effects = st.get("legitimacy", {})
	if _effects.is_empty():      # sem os dados importados: os principais efeitos do EU4
		_effects = {"global_unrest": -4, "tolerance_own": 2, "tolerance_heathen": 2, "tolerance_heretic": 2,
				"diplomatic_reputation": 2, "vassal_income": 0.1}
	_per_marriage = float(st.get("num_of_marriages", {}).get("legitimacy", 0.1))
	for t in map.countries:
		if uses(t):
			value[t] = START
	pw.legitimacy = self
	clock.month_passed.connect(_on_month)


## O país usa legitimidade? (monarquias e tribais que não são hordas)
func uses(tag: String) -> bool:
	var c: Dictionary = map.countries.get(tag, {})
	var gov := str(c.get("government", ""))
	if gov == "monarchy":
		return true
	if gov != "tribal":
		return false
	for r in c.get("reforms", []):
		if "horde" in str(r):
			return false
	return true


func of(tag: String) -> float:
	return float(value.get(tag, 0.0))


func add(tag: String, amount: float) -> void:
	if not value.has(tag):
		return
	value[tag] = clampf(of(tag) + amount, MIN, MAX)
	if tag == power.player:
		changed.emit(tag)


## Parte de um efeito que vem da legitimidade atual.
func effect(tag: String, key: String) -> float:
	if not value.has(tag):
		return 0.0
	var v = _effects.get(key)
	if v == null or not (v is float or v is int):
		return 0.0
	return float(v) * (of(tag) - 50.0) / 100.0


func effects(tag: String) -> Dictionary:
	var out := {}
	if not value.has(tag) or of(tag) == 50.0:
		return out
	for k in _effects:
		if _effects[k] is float or _effects[k] is int:
			out[k] = float(_effects[k]) * (of(tag) - 50.0) / 100.0
	return out


## Legitimidade por ano (efeitos + casamentos reais).
func yearly(tag: String) -> float:
	var n := diplomacy.marriages(tag).size() if diplomacy else 0
	return power.modifier(tag, "legitimacy") + n * _per_marriage


## Casamento real formado entre `a` e `b`: quem tem mais prestígio ou mais legitimidade perde.
func on_marriage(a: String, b: String) -> void:
	for p in [[a, b], [b, a]]:
		if prestige and prestige.of(p[0]) > prestige.of(p[1]):
			add(p[0], float(_rules.get("form_marriage_higher_prestige", -2)))
		if value.has(p[0]) and of(p[0]) > of(p[1]):
			add(p[0], float(_rules.get("form_marriage_higher_legitimacy", -3)))


## Texto da dica: valor, mudança por ano e efeitos atuais.
func tooltip(tag: String) -> String:
	if not value.has(tag):
		return Loc.s("Este governo não usa legitimidade", "This government does not use legitimacy")
	var t := Loc.s("Legitimidade: %s", "Legitimacy: %s") % Prestige._num(of(tag), false)
	t += "\n" + Loc.s("Por ano: %s (efeitos %s, casamentos reais %s)", "Yearly: %s (modifiers %s, royal marriages %s)") % [
			Prestige._num(yearly(tag), true), Prestige._num(power.modifier(tag, "legitimacy"), true),
			Prestige._num(yearly(tag) - power.modifier(tag, "legitimacy"), true)]
	var all := effects(tag)
	var e := {}
	for k in TIP_KEYS:
		if all.has(k) and float(all[k]) != 0.0:
			e[k] = all[k]
	if not e.is_empty() and fmt_mods.is_valid():
		t += "\n" + Loc.s("Efeitos: ", "Effects: ") + str(fmt_mods.call(e))
	return t


func _on_month() -> void:
	for t in value:
		var y := yearly(t)
		if y != 0.0:
			value[t] = clampf(float(value[t]) + y / 12.0, MIN, MAX)
	if power.player != "":
		changed.emit(power.player)
