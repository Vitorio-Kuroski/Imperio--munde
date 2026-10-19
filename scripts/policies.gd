class_name Policies
extends RefCounted
## Políticas do EU4 (common/policies, via Eu4Data), com as regras do defines.lua:
##  - cada categoria (ADM/DIP/MIL, campo monarch_power) aceita BASE_POSSIBLE_POLICIES (3) +
##    possible_<cat>_policy políticas; BASE_FREE_POLICIES (1) + free_<cat>_policy são de graça e cada
##    uma além disso custa POLICY_COST (1) ponto daquela categoria por mês;
##  - uma política fica pelo menos MINIMUM_POLICY_TIME (10) anos antes de poder ser cancelada;
##  - aparece se o `potential` vale (grupos de ideias adotados) e pode ser adotada se o `allow` vale
##    (grupos completos), pelo avaliador do CasusBelli; os efeitos (o resto das chaves) entram em
##    `MonarchPower.modifier` (`modifiers`).
## A IA ainda não adota políticas.

signal changed(tag: String)

const CATS := ["adm", "dip", "mil"]
const SKIP := ["monarch_power", "potential", "allow", "effect", "removed_effect", "ai_will_do"]

var map: MapView
var clock: GameClock
var power: MonarchPower
var cbs: CasusBelli
var defs := {}                     # id -> {id, cat, potential, allow, modifiers}
var active := {}                   # tag -> [{id, since (AAAAMMDD)}]
var _base := 3
var _free := 1
var _cost := 1.0
var _min_years := 10


func setup(m: MapView, c: GameClock, pw: MonarchPower, cb: CasusBelli) -> void:
	map = m
	clock = c
	power = pw
	cbs = cb
	_base = int(Eu4Data.define("NCountry", "BASE_POSSIBLE_POLICIES", 3))
	_free = int(Eu4Data.define("NCountry", "BASE_FREE_POLICIES", 1))
	_cost = float(Eu4Data.define("NCountry", "POLICY_COST", 1))
	_min_years = int(Eu4Data.define("NCountry", "MINIMUM_POLICY_TIME", 10))
	for id in Eu4Data.merged("common/policies"):
		var tree = Eu4Data.merged("common/policies")[id]
		if not (tree is Array):
			continue
		var d := {"id": id, "cat": "", "potential": [], "allow": [], "modifiers": {}}
		for kv in tree:
			match kv[0]:
				"monarch_power":
					d["cat"] = str(kv[1]).to_lower()
				"potential", "allow":
					d[kv[0]] = kv[1] if kv[1] is Array else []
				_:
					if not (kv[0] in SKIP) and str(kv[1]).is_valid_float():
						d["modifiers"][kv[0]] = float(kv[1])
		if d["cat"] in CATS:
			defs[id] = d
	clock.month_passed.connect(_on_month)


func name_of(id: String) -> String:
	return Loc.t(id, Eu4Importer.pretty_key(id))


func of(tag: String, cat: String = "") -> Array:
	var out := []
	for p in active.get(tag, []):
		if cat == "" or defs.get(p["id"], {}).get("cat", "") == cat:
			out.append(p)
	return out


func capacity(tag: String, cat: String) -> int:
	return _base + int(power.modifier(tag, "possible_%s_policy" % cat))


func free_slots(tag: String, cat: String) -> int:
	return _free + int(power.modifier(tag, "free_%s_policy" % cat))


## Pontos da categoria gastos por mês com as políticas.
func monthly_cost(tag: String, cat: String) -> float:
	return _cost * maxi(0, of(tag, cat).size() - free_slots(tag, cat))


## Políticas da categoria que o país vê (potential verdadeiro), adotadas ou não.
func visible(tag: String, cat: String) -> Array:
	var out := []
	for id in defs:
		var d: Dictionary = defs[id]
		if d["cat"] == cat and cbs and cbs.check(d["potential"], tag, tag) == true:
			out.append(id)
	return out


func has(tag: String, id: String) -> bool:
	for p in active.get(tag, []):
		if p["id"] == id:
			return true
	return false


func why_not_enact(tag: String, id: String) -> String:
	var d: Dictionary = defs.get(id, {})
	if d.is_empty() or has(tag, id):
		return "?"
	if cbs == null or cbs.check(d["allow"], tag, tag) != true:
		return Loc.s("Os grupos de ideias exigidos não estão completos", "The required idea groups are not complete")
	if of(tag, d["cat"]).size() >= capacity(tag, d["cat"]):
		return Loc.s("Sem vaga nesta categoria", "No free slot in this category")
	return ""


func enact(tag: String, id: String) -> bool:
	if why_not_enact(tag, id) != "":
		return false
	if not active.has(tag):
		active[tag] = []
	active[tag].append({"id": id, "since": clock.year * 10000 + clock.month * 100 + clock.day})
	power.invalidate(tag)
	if tag == power.player:
		changed.emit(tag)
	return true


func why_not_cancel(tag: String, id: String) -> String:
	for p in active.get(tag, []):
		if p["id"] == id:
			var until := int(p["since"]) + _min_years * 10000
			if clock.year * 10000 + clock.month * 100 + clock.day < until:
				return Loc.s("Só pode ser cancelada em %s", "Can only be cancelled on %s") % Loc.date(until / 10000, (until / 100) % 100, until % 100)
			return ""
	return "?"


func cancel(tag: String, id: String) -> bool:
	if why_not_cancel(tag, id) != "":
		return false
	for p in active[tag]:
		if p["id"] == id:
			active[tag].erase(p)
			break
	power.invalidate(tag)
	if tag == power.player:
		changed.emit(tag)
	return true


## Efeitos somados das políticas do país (MonarchPower._sum_mods).
func modifiers(tag: String) -> Dictionary:
	var out := {}
	for p in active.get(tag, []):
		var m: Dictionary = defs.get(p["id"], {}).get("modifiers", {})
		for k in m:
			out[k] = float(out.get(k, 0.0)) + float(m[k])
	return out


## Todo mês: cada política além das grátis custa POLICY_COST pontos da sua categoria.
func _on_month() -> void:
	for tag in active:
		if not power.state.has(tag):
			continue
		for cat in CATS:
			var c := monthly_cost(tag, cat)
			if c > 0.0:
				power.state[tag]["points"][cat] = maxi(0, int(power.state[tag]["points"][cat]) - int(c))
				if tag == power.player:
					power.notify(tag)
