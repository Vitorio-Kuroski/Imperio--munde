class_name Legitimacy
extends RefCounted
## Legitimidade, tradição republicana e devoção (o "poder do governo" de cada país), regras do EU4.
## Cada país usa um tipo (`kind`), pelo governo:
##  - Monarquias e tribais que não são hordas: legitimidade (0–100). Anual = efeito `legitimacy`
##    (ideias, conselheiros; +1 com 100 de prestígio e −1 por ponto de estabilidade negativa, que já
##    entram em `MonarchPower.modifier`) + 0,1 por casamento real (modificador estático
##    num_of_marriages); sem ganho básico. Efeitos = modificador estático `legitimacy` ×
##    (legitimidade − 50) ÷ 100 (com 100: −2 de agitação, +1 de tolerância, +1 de reputação
##    diplomática, +5% de renda dos vassalos...). Casamento real: quem tem mais prestígio perde 2 e
##    quem tem mais legitimidade perde 3 (FORM_MARRIAGE_HIGHER_PRESTIGE/LEGITIMACY).
##  - Repúblicas: tradição republicana (0–100). Anual = +1 (valores básicos) + efeito
##    `republican_tradition`. Efeitos = `republican_tradition` × tradição ÷ 100 (−2 de agitação com
##    100) + `inverse_republican_tradition` × (1 − tradição ÷ 100) (com 0: +200% no custo de
##    estabilidade). As eleições ainda não existem.
##  - Teocracias: devoção (0–100). Anual = −0,5 (valores básicos) + efeito `devotion` (+0,5 por ponto
##    de estabilidade positiva, +1 por ponto negativo...). Efeitos = `devotion` × (devoção − 50) ÷ 100
##    (com 100: +1 de prestígio anual, +25% de impostos...).
##  - Nativos e hordas não têm (no EU4 a horda usa unidade da horda).
## Tudo começa em 100 em 1444. Os efeitos somam em `MonarchPower.modifier` fora do cache.

signal changed(tag: String)

const MIN := 0.0
const MAX := 100.0
const START := 100.0
const KINDS := ["legitimacy", "republican_tradition", "devotion"]
## Efeitos mostrados na dica, por tipo.
const TIP_KEYS := {
	"legitimacy": ["global_unrest", "tolerance_own", "tolerance_heretic", "tolerance_heathen",
			"diplomatic_reputation", "vassal_income", "max_absolutism"],
	"republican_tradition": ["global_unrest", "stability_cost_modifier", "reform_progress_growth"],
	"devotion": ["prestige", "global_tax_modifier", "papal_influence", "church_power_modifier"],
}
## Ícone/texto da barra superior do EU4 para cada tipo.
const HUD := {"legitimacy": ["icon_leg", "text_leg"], "republican_tradition": ["icon_rep", "text_rep"],
		"devotion": ["icon_dev", "text_dev"]}

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var prestige: Prestige
var value := {}                  # tag -> valor (só os países que usam algum tipo)
var kinds := {}                  # tag -> "legitimacy" / "republican_tradition" / "devotion"
var fmt_mods: Callable           # efeitos -> texto (IdeasWindow.fmt_mods), para a dica
var _st := {}                    # modificadores estáticos (trade_rules.statics)
var _base := {}                  # valores básicos (republican_tradition +1, devotion −0,5 por ano)
var _per_marriage := 0.1
var _rules := {}


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, pr: Prestige) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	prestige = pr
	_rules = map.trade_rules
	_st = _rules.get("statics", {}).duplicate()
	_base = _rules.get("base_values", {})
	if not _st.has("legitimacy"):      # sem os dados importados: os principais efeitos do EU4
		_st["legitimacy"] = {"global_unrest": -4, "tolerance_own": 2, "tolerance_heathen": 2,
				"tolerance_heretic": 2, "diplomatic_reputation": 2, "vassal_income": 0.1}
	if not _st.has("republican_tradition"):
		_st["republican_tradition"] = {"global_unrest": -2}
	if not _st.has("inverse_republican_tradition"):
		_st["inverse_republican_tradition"] = {"stability_cost_modifier": 2.0}
	if not _st.has("devotion"):
		_st["devotion"] = {"prestige": 2, "global_tax_modifier": 0.5}
	_per_marriage = float(_st.get("num_of_marriages", {}).get("legitimacy", 0.1))
	for t in map.countries:
		var k := kind_for(t)
		if k != "":
			kinds[t] = k
			value[t] = START
	pw.legitimacy = self
	clock.month_passed.connect(_on_month)


## Tipo que o governo do país usa ("" = nenhum).
func kind_for(tag: String) -> String:
	var c: Dictionary = map.countries.get(tag, {})
	match str(c.get("government", "")):
		"monarchy":
			return "legitimacy"
		"republic":
			return "republican_tradition"
		"theocracy":
			return "devotion"
		"tribal":
			for r in c.get("reforms", []):
				if "horde" in str(r):
					return ""
			return "legitimacy"
	return ""


func kind(tag: String) -> String:
	return str(kinds.get(tag, ""))


## O país usa legitimidade (monarquias e tribais)?
func uses(tag: String) -> bool:
	return kind(tag) == "legitimacy"


func of(tag: String) -> float:
	return float(value.get(tag, 0.0))


func add(tag: String, amount: float) -> void:
	if not value.has(tag):
		return
	value[tag] = clampf(of(tag) + amount, MIN, MAX)
	if tag == power.player:
		changed.emit(tag)


## Pesos de cada bloco estático no valor atual: [[bloco, peso], ...].
func _weights(tag: String) -> Array:
	var v := of(tag)
	match kind(tag):
		"legitimacy":
			return [["legitimacy", (v - 50.0) / 100.0]]
		"republican_tradition":
			return [["republican_tradition", v / 100.0], ["inverse_republican_tradition", 1.0 - v / 100.0]]
		"devotion":
			return [["devotion", (v - 50.0) / 100.0]]
	return []


## Parte de um efeito que vem do valor atual.
func effect(tag: String, key: String) -> float:
	if not value.has(tag):
		return 0.0
	var out := 0.0
	for w in _weights(tag):
		var x = _st.get(w[0], {}).get(key)
		if x is float or x is int:
			out += float(x) * float(w[1])
	return out


func effects(tag: String) -> Dictionary:
	var out := {}
	for w in _weights(tag):
		if float(w[1]) == 0.0:
			continue
		var d: Dictionary = _st.get(w[0], {})
		for k in d:
			if d[k] is float or d[k] is int:
				out[k] = float(out.get(k, 0.0)) + float(d[k]) * float(w[1])
	return out


## Mudança por ano: [total, efeitos, outro (casamentos ou valor básico)].
func yearly_parts(tag: String) -> Array:
	var k := kind(tag)
	if k == "":
		return [0.0, 0.0, 0.0]
	var mods := power.modifier(tag, k)
	var other := 0.0
	if k == "legitimacy":
		other = (diplomacy.marriages(tag).size() if diplomacy else 0) * _per_marriage
	else:
		other = float(_base.get(k, 1.0 if k == "republican_tradition" else -0.5))
	return [mods + other, mods, other]


func yearly(tag: String) -> float:
	return float(yearly_parts(tag)[0])


## Casamento real formado entre `a` e `b`: quem tem mais prestígio ou mais legitimidade perde.
func on_marriage(a: String, b: String) -> void:
	for p in [[a, b], [b, a]]:
		if prestige and prestige.of(p[0]) > prestige.of(p[1]):
			add(p[0], float(_rules.get("form_marriage_higher_prestige", -2)))
		if uses(p[0]) and uses(p[1]) and of(p[0]) > of(p[1]):
			add(p[0], float(_rules.get("form_marriage_higher_legitimacy", -3)))


## Nome do tipo (com a localização do EU4, se houver).
static func kind_name(k: String) -> String:
	match k:
		"legitimacy":
			return Loc.t("LEGITIMACY", Loc.s("Legitimidade", "Legitimacy"))
		"republican_tradition":
			return Loc.t("REPUBLICAN_TRADITION", Loc.s("Tradição republicana", "Republican Tradition"))
		"devotion":
			return Loc.t("DEVOTION", Loc.s("Devoção", "Devotion"))
	return ""


## Texto da dica: valor, mudança por ano e efeitos atuais.
func tooltip(tag: String) -> String:
	var k := kind(tag)
	if k == "":
		return Loc.s("Este governo não usa legitimidade, tradição republicana nem devoção",
				"This government uses no legitimacy, republican tradition or devotion")
	var y := yearly_parts(tag)
	var t := "%s: %s" % [kind_name(k), Prestige._num(of(tag), false)]
	if k == "legitimacy":
		t += "\n" + Loc.s("Por ano: %s (efeitos %s, casamentos reais %s)", "Yearly: %s (modifiers %s, royal marriages %s)") % [
				Prestige._num(y[0], true), Prestige._num(y[1], true), Prestige._num(y[2], true)]
	else:
		t += "\n" + Loc.s("Por ano: %s (básico %s, efeitos %s)", "Yearly: %s (base %s, modifiers %s)") % [
				Prestige._num(y[0], true), Prestige._num(y[2], true), Prestige._num(y[1], true)]
	var all := effects(tag)
	var e := {}
	for key in TIP_KEYS.get(k, []):
		if all.has(key) and absf(float(all[key])) > 0.0001:
			e[key] = all[key]
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
