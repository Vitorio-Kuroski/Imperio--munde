class_name DiploActions
extends RefCounted
## Opiniões entre países e ações diplomáticas do jogador (regras do EU4, aproximadas):
##  - opinion(a, b) = o que `a` acha de `b`: soma dos modificadores do EU4 (common/opinion_modifiers,
##    importados em map.opinion_modifiers): mesma religião (+25) ou religião diferente do mesmo
##    grupo (−20) / de outro grupo (−10), aliança (+50), casamento real (+25), garantido por `b`
##    (+10), mesma dinastia (+15), guerra (−20); mais os que duram e somem com o tempo: relações
##    melhoradas (até +100, caem 3/ano sem diplomata), insultado (−50, sobe 5/ano, 10 anos),
##    quebrou aliança (−50, 1/ano) e quebrou casamento (−75, 3/ano).
##  - Diplomatas = diplomats dos valores básicos do EU4 (2) + efeitos. Melhorar relações ocupa um
##    diplomata até ser chamado de volta: +3 por mês × IMPROVE_RELATION_SPEED × (1 +
##    improve_relation_modifier) na opinião do alvo sobre o país, até o máximo do modificador.
##  - Ações: melhorar relações, propor aliança (opinião ≥ MIN_RELATIONS_TO_ALLY dos dois lados),
##    propor casamento real (dois governos monárquicos), garantir independência, romper aliança,
##    romper casamento e insultar. Aliança e casamento dependem da resposta do outro país
##    (`acceptance`: pontos a favor e contra, aceita se a soma for > 0 — uma aproximação do EU4,
##    com a opinião sobre nós, religião, tamanho relativo, distância e alianças que ele já tem);
##    as outras são unilaterais.
##  - A IA ainda não propõe nada nem usa diplomatas.

signal changed(tag: String)

const ACTIONS := ["improve", "alliance", "royal_marriage", "guarantee", "break_alliance", "break_marriage", "insult"]
const IMPROVE_BASE := 3.0

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var economy: Economy
var stability: Stability           # main.gd define (romper casamento custa estabilidade)
var legitimacy: Legitimacy         # main.gd define (casar com quem tem menos prestígio/legitimidade custa)
var mods := {}                     # opinion_modifiers do EU4
var timed := {}                    # "A>B" -> {modificador: [valor, meses restantes ou -1]} (opinião de A sobre B)
var improving := {}                # país -> [alvos com diplomata melhorando relações]
var _rules := {}


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, eco: Economy) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	economy = eco
	mods = map.opinion_modifiers
	_rules = map.trade_rules
	clock.month_passed.connect(_on_month)


func enabled() -> bool:
	return not mods.is_empty()


func _mod(id: String, key: String, default: float) -> float:
	return float(mods.get(id, {}).get(key, default))


# ------------------------------------------------------------------ opinião
## Modificadores da opinião de `a` sobre `b`: [[id, valor]].
func breakdown(a: String, b: String) -> Array:
	var out := []
	if a == b or not map.countries.has(a) or not map.countries.has(b):
		return out
	var ca: Dictionary = map.countries[a]
	var cb: Dictionary = map.countries[b]
	var ra: String = ca.get("religion", "")
	var rb: String = cb.get("religion", "")
	if ra != "" and ra == rb:
		out.append(["same_religion", _mod("same_religion", "opinion", 25)])
	elif map.religions.has(ra) and map.religions.has(rb):
		if map.religions[ra]["group"] == map.religions[rb]["group"]:
			out.append(["different_religion_same_group", _mod("different_religion_same_group", "opinion", -20)])
		else:
			out.append(["different_religions_group", _mod("different_religions_group", "opinion", -10)])
	var da := str(ca.get("monarch", {}).get("dynasty", ""))
	if da != "" and da == str(cb.get("monarch", {}).get("dynasty", "")):
		out.append(["same_dynasty", _mod("same_dynasty", "opinion", 15)])
	if b in diplomacy.allies(a):
		out.append(["alliance", _mod("alliance", "opinion", 50)])
	if b in diplomacy.marriages(a):
		out.append(["royal_marriage", _mod("royal_marriage", "opinion", 25)])
	if b in diplomacy.guarantors(a):
		out.append(["guaranteed", _mod("guaranteed", "opinion", 10)])
	if diplomacy.enemies(a, b) == true:
		out.append(["at_war", _mod("at_war", "opinion", -20)])
	for id in timed.get(a + ">" + b, {}):
		var v: float = timed[a + ">" + b][id][0]
		if absf(v) >= 0.5:
			out.append([id, v])
	return out


func opinion(a: String, b: String) -> int:
	var s := 0.0
	for x in breakdown(a, b):
		s += float(x[1])
	return clampi(roundi(s), -200, 200)


static func breakdown_text(items: Array) -> String:
	var lines := []
	for x in items:
		lines.append("%s: %+d" % [Loc.t(str(x[0]), Eu4Importer.pretty_key(str(x[0]))), roundi(float(x[1]))])
	return "\n".join(lines)


func _add_timed(a: String, b: String, id: String) -> void:
	var key := a + ">" + b
	if not timed.has(key):
		timed[key] = {}
	# duração: months ou years do EU4 (0 ou nada = até a opinião voltar a 0)
	var months := int(_mod(id, "months", 0)) + int(_mod(id, "years", 0)) * 12
	timed[key][id] = [_mod(id, "opinion", 0), months if months > 0 else -1]


# ------------------------------------------------------------------ diplomatas
func diplomats(tag: String) -> int:
	return int(_rules.get("base_values", {}).get("diplomats", 2)) + int(power.modifier(tag, "diplomats"))


func free_diplomats(tag: String) -> int:
	return maxi(0, diplomats(tag) - improving.get(tag, []).size())


func is_improving(tag: String, target: String) -> bool:
	return target in improving.get(tag, [])


func improve_rate(tag: String) -> float:
	return IMPROVE_BASE * float(_rules.get("improve_relation_speed", 1)) \
			* maxf(0.0, 1.0 + power.modifier(tag, "improve_relation_modifier"))


# ------------------------------------------------------------------ ações
func _monarchy(tag: String) -> bool:
	return str(map.countries.get(tag, {}).get("government", "")) == "monarchy"


func _distance(a: String, b: String) -> float:
	var pa := int(map.countries.get(a, {}).get("capital", -1))
	var pb := int(map.countries.get(b, {}).get("capital", -1))
	if pa < 0 or pb < 0 or pa >= map.provinces.size() or pb >= map.provinces.size():
		return 0.0
	var ca: Array = map.provinces[pa]["center"]
	var cb: Array = map.provinces[pb]["center"]
	return Vector2(float(ca[0]), float(ca[1])).distance_to(Vector2(float(cb[0]), float(cb[1])))


## Pontos a favor e contra `target` aceitar a proposta de `actor`: [[motivo, valor]].
func acceptance(action: String, actor: String, target: String) -> Array:
	var out := []
	var op := opinion(target, actor)
	out.append([Loc.s("Opinião sobre nós", "Opinion of us"), roundi(op / 4.0)])
	var ra: String = map.countries[actor].get("religion", "")
	var rt: String = map.countries[target].get("religion", "")
	var same_group: bool = map.religions.has(ra) and map.religions.has(rt) \
			and map.religions[ra]["group"] == map.religions[rt]["group"]
	match action:
		"alliance":
			out.append([Loc.s("Relutância básica", "Base reluctance"), -20])
			if ra == rt:
				out.append([Loc.s("Mesma religião", "Same religion"), 10])
			elif not same_group:
				out.append([Loc.s("Religião de outro grupo", "Different religion group"), -20])
			var dev_a := maxf(1.0, economy.development(actor))
			var dev_t := maxf(1.0, economy.development(target))
			out.append([Loc.s("Tamanho relativo", "Relative strength"), clampi(roundi((dev_a / dev_t - 1.0) * 10.0), -30, 30)])
			out.append([Loc.s("Distância", "Distance"), -mini(60, roundi(_distance(actor, target) / 40.0))])
			var n := diplomacy.allies(target).size()
			if n >= 2:
				out.append([Loc.s("Já tem %d alianças", "Already has %d alliances") % n, -10 * (n - 1)])
		"royal_marriage":
			out.append([Loc.s("Relutância básica", "Base reluctance"), -10])
			if ra == rt:
				out.append([Loc.s("Mesma religião", "Same religion"), 10])
			elif not same_group:
				out.append([Loc.s("Religião de outro grupo", "Different religion group"), -1000])
			var n := diplomacy.marriages(target).size()
			if n >= 2:
				out.append([Loc.s("Já tem %d casamentos", "Already has %d marriages") % n, -10 * (n - 1)])
	return out


func acceptance_score(action: String, actor: String, target: String) -> int:
	var s := 0
	for x in acceptance(action, actor, target):
		s += int(x[1])
	return s


## "" se `actor` pode fazer a ação com `target`, senão o motivo.
func why_not(action: String, actor: String, target: String) -> String:
	if actor == target or not map.countries.has(target):
		return "?"
	var allied: bool = target in diplomacy.allies(actor)
	var married: bool = target in diplomacy.marriages(actor)
	match action:
		"improve":
			if is_improving(actor, target):
				return ""                       # chamar o diplomata de volta
			if free_diplomats(actor) <= 0:
				return Loc.s("Sem diplomata livre", "No free diplomat")
			var cur := float(timed.get(target + ">" + actor, {}).get("improved_relation", [0.0])[0])
			if cur >= _mod("improved_relation", "max", 100):
				return Loc.s("Relações já no máximo", "Relations already at maximum")
		"alliance":
			if allied:
				return Loc.s("Já são aliados", "Already allied")
			var lim := int(_rules.get("min_relations_to_ally", -25))
			if opinion(target, actor) < lim or opinion(actor, target) < lim:
				return Loc.s("Opinião abaixo de %d", "Opinion below %d") % lim
			if diplomacy.overlord(target).size() > 0:
				return Loc.s("É súdito de outro país", "Is a subject")
		"royal_marriage":
			if married:
				return Loc.s("Já há casamento real", "Already married")
			if not _monarchy(actor) or not _monarchy(target):
				return Loc.s("Só entre monarquias", "Monarchies only")
		"guarantee":
			if target in diplomacy.guarantees(actor):
				return Loc.s("Já garantido", "Already guaranteed")
			if diplomacy.overlord(target).size() > 0:
				return Loc.s("É súdito de outro país", "Is a subject")
		"break_alliance":
			if not allied:
				return Loc.s("Não são aliados", "Not allied")
		"break_marriage":
			if not married:
				return Loc.s("Não há casamento real", "Not married")
		"insult":
			if timed.get(target + ">" + actor, {}).has("insulted"):
				return Loc.s("Já foi insultado", "Already insulted")
	return ""


## Faz a ação; devolve a mensagem do resultado (aceito/recusado).
func act(action: String, actor: String, target: String) -> String:
	var why := why_not(action, actor, target)
	if why != "":
		return why
	var name: String = map.countries[target]["name"]
	var msg := ""
	match action:
		"improve":
			if is_improving(actor, target):
				improving[actor].erase(target)
				msg = Loc.s("Diplomata chamado de volta", "Diplomat recalled")
			else:
				if not improving.has(actor):
					improving[actor] = []
				improving[actor].append(target)
				msg = Loc.s("Diplomata enviado para melhorar relações com %s", "Diplomat sent to improve relations with %s") % name
		"alliance", "royal_marriage":
			if acceptance_score(action, actor, target) > 0:
				diplomacy.add_relation(action, actor, target)
				if action == "royal_marriage" and legitimacy:
					legitimacy.on_marriage(actor, target)
				msg = Loc.s("%s aceitou", "%s accepted") % name
			else:
				msg = Loc.s("%s recusou", "%s declined") % name
		"guarantee":
			diplomacy.add_relation("guarantee", actor, target)
			msg = Loc.s("Independência de %s garantida", "Guaranteed the independence of %s") % name
		"break_alliance":
			diplomacy.remove_relation("alliance", actor, target)
			_add_timed(target, actor, "break_alliance")
			msg = Loc.s("Aliança com %s rompida", "Alliance with %s broken") % name
		"break_marriage":
			diplomacy.remove_relation("royal_marriage", actor, target)
			_add_timed(target, actor, "break_marriage")
			if stability:
				stability.on_break_marriage(actor)
			msg = Loc.s("Casamento com %s rompido", "Marriage with %s broken") % name
		"insult":
			_add_timed(target, actor, "insulted")
			msg = Loc.s("%s foi insultado", "%s was insulted") % name
	_changed(actor)
	return msg


func _changed(tag: String) -> void:
	if tag == power.player:
		changed.emit(tag)


func _on_month() -> void:
	# diplomatas melhorando relações
	for actor in improving:
		for target in improving[actor]:
			var key: String = target + ">" + actor
			if not timed.has(key):
				timed[key] = {}
			var cur: Array = timed[key].get("improved_relation", [0.0, -1])
			cur[0] = minf(_mod("improved_relation", "max", 100), float(cur[0]) + improve_rate(actor))
			timed[key]["improved_relation"] = cur
	# o resto volta para 0 com o tempo (yearly_decay) e some quando acaba o prazo (months)
	for key in timed.keys():
		var parts: PackedStringArray = (key as String).split(">")
		for id in timed[key].keys():
			var e: Array = timed[key][id]
			var being_improved: bool = id == "improved_relation" and parts.size() == 2 \
					and is_improving(parts[1], parts[0])
			if not being_improved:
				var dec := _mod(id, "yearly_decay", 0) / 12.0
				e[0] = maxf(0.0, float(e[0]) - dec) if float(e[0]) > 0.0 else minf(0.0, float(e[0]) + dec)
			if int(e[1]) > 0:
				e[1] = int(e[1]) - 1
			if int(e[1]) == 0 or (absf(float(e[0])) < 0.01 and not being_improved):
				timed[key].erase(id)
		if timed[key].is_empty():
			timed.erase(key)
	if improving.has(power.player):
		changed.emit(power.player)
