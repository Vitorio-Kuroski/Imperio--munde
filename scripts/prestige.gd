class_name Prestige
extends RefCounted
## Prestígio dos países, regras do EU4:
##  - Vai de −100 a +100. Em 1444 vem do `add_prestige` do histórico do país (Ming +45), os
##    outros começam em 0.
##  - Por mês muda (prestígio anual − decaimento) ÷ 12: prestígio anual = efeito `prestige` (ideias,
##    religião, conselheiros... e +1 do imperador do Sacro Império, modificador estático `emperor`);
##    decaimento = prestígio × (prestige_decay: 5% dos valores básicos + efeitos), puxando para 0.
##  - Efeitos: o modificador estático `prestige` do EU4 vezes prestígio ÷ 100 (com +100: +15% de
##    poder comercial, +10% de moral, +50% de melhorar relações, −10% no custo de adotar instituição...;
##    com prestígio negativo, o contrário). Somados em `MonarchPower.modifier` sem passar pelo cache
##    (mudam todo mês).
##  - `add(tag, valor)` para ganhos e perdas (guerras, paz, eventos — ainda não existem).

signal changed(tag: String)

const MIN := -100.0
const MAX := 100.0
## Efeitos do prestígio mostrados na dica (os de estamentos, autoridade, fervor... ficam de fora).
const TIP_KEYS := ["global_trade_power", "land_morale", "naval_morale", "global_spy_defence", "legitimacy",
		"improve_relation_modifier", "ae_impact", "embracement_cost"]

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var value := {}                  # tag -> prestígio
var _effects := {}               # efeitos com prestígio 100 (modificador estático `prestige`)
var _emperor := {}               # modificador estático `emperor`
var fmt_mods: Callable           # efeitos -> texto (IdeasWindow.fmt_mods), para a dica


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	var st: Dictionary = map.trade_rules.get("statics", {})
	_effects = st.get("prestige", {})
	_emperor = st.get("emperor", {})
	if _effects.is_empty():       # sem os dados importados: os principais efeitos do EU4
		_effects = {"global_trade_power": 0.15, "land_morale": 0.1, "naval_morale": 0.1,
				"improve_relation_modifier": 0.5, "embracement_cost": -0.1}
	if _emperor.is_empty():
		_emperor = {"prestige": 1}
	for t in map.countries:
		value[t] = clampf(float(map.countries[t].get("prestige", 0)), MIN, MAX)
	pw.prestige = self
	if diplomacy and diplomacy.emperor != "":
		pw.invalidate(diplomacy.emperor)
	clock.month_passed.connect(_on_month)


func of(tag: String) -> float:
	return float(value.get(tag, 0.0))


func add(tag: String, amount: float) -> void:
	value[tag] = clampf(of(tag) + amount, MIN, MAX)
	if tag == power.player:
		changed.emit(tag)


## Efeitos do modificador estático do imperador (só para ele), somados aos do país.
func static_modifiers(tag: String) -> Dictionary:
	if diplomacy and tag != "" and tag == diplomacy.emperor:
		return _emperor
	return {}


## Parte de um efeito que vem do prestígio atual.
func effect(tag: String, key: String) -> float:
	var v = _effects.get(key)
	if v == null or not (v is float or v is int):
		return 0.0
	return float(v) * of(tag) / 100.0


## Todos os efeitos do prestígio atual: chave -> valor.
func effects(tag: String) -> Dictionary:
	var out := {}
	var p := of(tag)
	for k in _effects:
		if (_effects[k] is float or _effects[k] is int) and float(_effects[k]) != 0.0 and p != 0.0:
			out[k] = float(_effects[k]) * p / 100.0
	return out


## Prestígio anual dos efeitos (ideias, religião, imperador...).
func yearly_gain(tag: String) -> float:
	return power.modifier(tag, "prestige")


func decay_rate(tag: String) -> float:
	var base := float(map.trade_rules.get("base_values", {}).get("prestige_decay", 0.05))
	return maxf(0.0, base + power.modifier(tag, "prestige_decay"))


## Mudança por ano no prestígio atual (ganho − decaimento).
func yearly_change(tag: String) -> float:
	return yearly_gain(tag) - of(tag) * decay_rate(tag)


## Texto da dica: valor, mudança por ano (ganho e decaimento) e efeitos atuais.
func tooltip(tag: String) -> String:
	var p := of(tag)
	var t := Loc.s("Prestígio: %s", "Prestige: %s") % _num(p, false)
	t += "\n" + Loc.s("Por ano: %s (ganho %s, decaimento %s%% do atual: %s)",
			"Yearly: %s (gain %s, decay %s%% of current: %s)") % [_num(yearly_change(tag), true),
			_num(yearly_gain(tag), true), _num(decay_rate(tag) * 100.0, false), _num(-p * decay_rate(tag), true)]
	var all := effects(tag)
	var e := {}
	for k in TIP_KEYS:
		if all.has(k):
			e[k] = all[k]
	if not e.is_empty() and fmt_mods.is_valid():
		t += "\n" + Loc.s("Efeitos: ", "Effects: ") + str(fmt_mods.call(e))
	return t


static func _num(v: float, sign: bool) -> String:
	return (("%+.2f" if sign else "%.2f") % v).replace(".", Loc.dec)


func _on_month() -> void:
	for t in value:
		var v: float = value[t]
		var ch := yearly_change(t)
		if ch != 0.0:
			value[t] = clampf(v + ch / 12.0, MIN, MAX)
	if power.player != "":
		changed.emit(power.player)
