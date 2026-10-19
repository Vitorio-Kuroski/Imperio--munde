class_name Diplomacy
extends RefCounted
## Relações entre países no início (history/diplomacy do EU4, ativas em 11/11/1444): súditos
## (vassalo, união pessoal, marca, dependências como apanágio), alianças, casamentos reais,
## garantias e ligas comerciais; mais o Sacro Império (províncias "hre", imperador, eleitores) e o
## imperador celestial; e as guerras (history/wars) ativas ou dos últimos 10 anos, com batalhas.
## Alianças, casamentos reais e garantias mudam pelas ações diplomáticas (DiploActions, via
## add_relation/remove_relation); súditos e guerras ainda são fixos.

const SUBJECT_TYPES := ["vassal", "union", "march", "dependency"]
const SUBJECT_NAMES := {"vassal": "vassalo", "union": "união pessoal", "march": "marca", "appanage": "apanágio",
		"tributary_state": "estado tributário", "daimyo_vassal": "daimiô", "core_eyalet": "eyalet",
		"eyalet": "eyalet", "colony": "colônia", "client_vassal": "estado cliente", "trade_company": "companhia"}

var map: MapView
var relations: Array = []        # [{type, first, second, subject_type?}]
var emperor := ""
var celestial_emperor := ""
var _overlord := {}              # súdito -> [suserano, tipo]
var _subjects := {}              # suserano -> [[súdito, tipo]]
var _allies := {}                # tag -> [tags]
var _marriages := {}
var _guarantees := {}            # garantidor -> [garantidos]
var _guarantors := {}            # garantido -> [garantidores]
var wars: Array = []             # guerras ativas e dos últimos 10 anos (name, start, end, attackers, defenders, battles)
var _wars_of := {}               # tag -> [guerras]
var _battles_at := {}            # província -> [batalhas]
var war: War                     # main.gd define (guerras durante o jogo)

const CB_NAMES := {"cb_conquest": "conquista", "cb_border_war": "guerra de fronteira", "cb_core": "reconquista",
		"cb_claim_throne": "reivindicação do trono", "cb_independence_war": "independência", "cb_insult": "insulto",
		"cb_trade_war": "guerra comercial", "cb_vassalize_mission": "vassalização", "cb_super_badboy": "coalizão",
		"cb_crusade": "cruzada", "cb_holy_war": "guerra santa", "cb_restore_personal_union": "união pessoal"}


func setup(m: MapView) -> void:
	map = m
	relations = map.diplomacy
	emperor = map.emperor
	celestial_emperor = map.celestial_emperor
	wars = map.wars
	for w in wars:
		for t in w["attackers"] + w["defenders"]:
			_add(_wars_of, t, w)
		for b in w.get("battles", []):
			if b.has("location"):
				_add(_battles_at, int(b["location"]), b)
	for r in relations:
		var a: String = r["first"]
		var b: String = r["second"]
		var t: String = r["type"]
		if t in SUBJECT_TYPES:
			var kind: String = r.get("subject_type", t)
			_overlord[b] = [a, kind]
			_add(_subjects, a, [b, kind])
		elif t == "alliance":
			_add(_allies, a, b)
			_add(_allies, b, a)
		elif t == "royal_marriage":
			_add(_marriages, a, b)
			_add(_marriages, b, a)
		elif t == "guarantee":
			_add(_guarantees, a, b)
			_add(_guarantors, b, a)


## Nova aliança, casamento real ou garantia (a = quem garante) entre `a` e `b`.
func add_relation(type: String, a: String, b: String) -> void:
	relations.append({"type": type, "first": a, "second": b})
	match type:
		"alliance":
			_add(_allies, a, b)
			_add(_allies, b, a)
		"royal_marriage":
			_add(_marriages, a, b)
			_add(_marriages, b, a)
		"guarantee":
			_add(_guarantees, a, b)
			_add(_guarantors, b, a)
		"vassal":
			_overlord[b] = [a, "vassal"]
			_add(_subjects, a, [b, "vassal"])
	_changed()


## Desfaz a relação (nos dois sentidos para aliança e casamento; a garantia é de `a` para `b`).
func remove_relation(type: String, a: String, b: String) -> void:
	relations = relations.filter(func(r): return not (r["type"] == type and ((r["first"] == a and r["second"] == b) \
			or (type != "guarantee" and r["first"] == b and r["second"] == a))))
	match type:
		"alliance":
			_allies.get(a, []).erase(b)
			_allies.get(b, []).erase(a)
		"royal_marriage":
			_marriages.get(a, []).erase(b)
			_marriages.get(b, []).erase(a)
		"guarantee":
			_guarantees.get(a, []).erase(b)
			_guarantors.get(b, []).erase(a)
	_changed()


## `sub` deixa de ser súdito (independência ganha na guerra).
func release(sub: String) -> void:
	if not _overlord.has(sub):
		return
	var ov: String = _overlord[sub][0]
	_overlord.erase(sub)
	_subjects[ov] = _subjects.get(ov, []).filter(func(x): return x[0] != sub)
	relations = relations.filter(func(r): return not (r["second"] == sub and r["first"] == ov
			and not (r["type"] in ["alliance", "royal_marriage", "guarantee"])))
	_changed()


func _changed() -> void:
	if map.map_mode == MapView.MapMode.DIPLOMACIA:
		map.refresh_colors()


func _add(d: Dictionary, k: Variant, v: Variant) -> void:
	if not d.has(k):
		d[k] = []
	d[k].append(v)


func enabled() -> bool:
	return not relations.is_empty() or emperor != "" or not wars.is_empty()


func wars_of(tag: String) -> Array:
	return _wars_of.get(tag, [])


func battles_at(pid: int) -> Array:
	return _battles_at.get(pid, [])


## Lado do país numa guerra: "attackers", "defenders" ou "".
static func side_of(w: Dictionary, tag: String) -> String:
	if tag in w["attackers"]:
		return "attackers"
	if tag in w["defenders"]:
		return "defenders"
	return ""


func cb_name(w: Dictionary) -> String:
	var cb: String = w.get("war_goal", {}).get("casus_belli", "")
	return CB_NAMES.get(cb, Eu4Importer.pretty_key(cb.trim_prefix("cb_")).to_lower()) if cb != "" else ""


## Inimigos de `a` e `b` numa guerra ativa (true) ou recente (false); null se nunca se enfrentaram.
func enemies(a: String, b: String) -> Variant:
	for w in wars_of(a):
		var sa := side_of(w, a)
		var sb := side_of(w, b)
		if sa != "" and sb != "" and sa != sb:
			return w.has("active")
	return null


func overlord(tag: String) -> Array:
	return _overlord.get(tag, [])


## Suserano no topo da cadeia (o próprio país se não for súdito).
func top_overlord(tag: String) -> String:
	var t := tag
	var guard := 0
	while _overlord.has(t) and guard < 10:
		t = _overlord[t][0]
		guard += 1
	return t


func subjects(tag: String) -> Array:
	return _subjects.get(tag, [])


func allies(tag: String) -> Array:
	return _allies.get(tag, [])


func marriages(tag: String) -> Array:
	return _marriages.get(tag, [])


func guarantees(tag: String) -> Array:
	return _guarantees.get(tag, [])


func guarantors(tag: String) -> Array:
	return _guarantors.get(tag, [])


## Tipo de súdito do EU4 (common/subject_types) de uma relação: "union" é personal_union.
static func subject_type_id(kind: String) -> String:
	return "personal_union" if kind == "union" else kind


## Atributos do tipo de súdito (joins_overlords_wars, pays_overlord, base_liberty_desire...); vazio
## sem os dados importados.
func subject_type(kind: String) -> Dictionary:
	return map.diplomacy_data.get("subject_types", {}).get(subject_type_id(kind), {})


func subject_name(kind: String) -> String:
	var id := subject_type_id(kind)
	var pt: String = SUBJECT_NAMES.get(kind, Eu4Importer.pretty_key(kind).to_lower())
	return Loc.t(id + "_title", Loc.t(id, pt)) if Loc.active() else pt


func in_hre(tag: String) -> bool:
	var cap := int(map.countries.get(tag, {}).get("capital", 0))
	return cap > 0 and cap < map.provinces.size() and map.provinces[cap].get("hre", false)


func is_elector(tag: String) -> bool:
	return map.countries.get(tag, {}).get("elector", false)


## Relação de `other` vista por `focus` (para o modo de mapa diplomacia).
func relation(focus: String, other: String) -> String:
	if other == "" or focus == "":
		return ""
	if other == focus:
		return "self"
	if overlord(other).size() > 0 and overlord(other)[0] == focus:
		return "subject"
	if top_overlord(other) == focus:
		return "subject"
	if overlord(focus).size() > 0 and overlord(focus)[0] == other:
		return "overlord"
	if other in allies(focus):
		return "ally"
	if other in marriages(focus):
		return "marriage"
	if other in guarantees(focus) or other in guarantors(focus):
		return "guarantee"
	if overlord(focus).size() > 0 and top_overlord(other) == top_overlord(focus):
		return "same_bloc"          # outro súdito do mesmo suserano
	if war and war.hostile(focus, other):
		return "war"
	var e = enemies(focus, other)
	if e != null:
		return "war" if e else "recent_enemy"
	return ""
