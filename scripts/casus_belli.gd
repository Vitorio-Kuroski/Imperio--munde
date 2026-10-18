class_name CasusBelli
extends RefCounted
## Casus belli do EU4 (common/cb_types, importados em `map.casus_belli`, com os objetivos de guerra
## de common/wargoal_types em `map.war_goals`):
##  - Um país tem o casus belli contra outro quando as condições `prerequisites_self` (no próprio
##    país) e `prerequisites` (ROOT = quem declara, FROM = o alvo) são verdadeiras, o casus belli não
##    é só de eventos (`is_triggered_only`) e, se `valid_for_subject = no`, quem declara não é súdito.
##  - As condições são avaliadas com três valores (verdadeiro, falso, desconhecido): AND/OR/NOT
##    (NOT = nenhum dos itens), mudança de escopo (FROM, ROOT, capital_scope, any_owned_province,
##    any_neighbor_province) e as condições mais usadas (vizinhança, religião, grupo religioso,
##    governo, reformas, tag, grupo tecnológico, cultura, súditos, Sacro Império, imperador,
##    núcleos e reivindicações de 1444, região, continente...). O que depende de coisas que o jogo
##    ainda não tem (flags, missões, eventos, excomunhão, trégua) é falso; condição desconhecida deixa
##    o resultado desconhecido, e desconhecido no fim conta como falso.
##  - Declarar guerra sem casus belli custa NO_CB_STABILITY (2) de estabilidade (regra do EU4).

const NO_CB_STABILITY := -2
## Preferência ao escolher o casus belli da declaração (os outros vêm depois, na ordem do arquivo).
const PREFERRED := ["cb_core", "cb_conquest", "cb_independence_war", "cb_heretic", "cb_crusade", "cb_imperial",
		"cb_nationalist", "cb_tribal_feud", "cb_horde_vs_civ", "cb_claim_throne"]
const PT_NAMES := {"cb_core": "Reconquista", "cb_conquest": "Conquista", "cb_independence_war": "Guerra de independência",
		"cb_heretic": "Purgar a heresia", "cb_crusade": "Guerra santa", "cb_imperial": "Imperial",
		"cb_nationalist": "Nacionalista", "cb_tribal_feud": "Rixa tribal", "cb_horde_vs_civ": "Horda contra civilizados",
		"cb_claim_throne": "Reivindicar o trono", "cb_defender_of_the_faith": "Defensor da fé",
		"cb_excommunication": "Excomunhão", "cb_liberation": "Libertação", "cb_colonial": "Colonial",
		"cb_humiliate": "Humilhar rival", "cb_trade_war": "Guerra comercial", "cb_super_badboy": "Coalizão"}

var map: MapView
var power: MonarchPower
var diplomacy: Diplomacy
var war: War
var cbs := {}                     # id -> casus belli (map.casus_belli)
var goals := {}                   # id -> objetivo de guerra (map.war_goals)
var _order := []                  # ids na ordem do arquivo
var _neigh := {}                  # tag -> {vizinhos por terra}
var _neigh_version := -1


func setup(m: MapView, pw: MonarchPower, d: Diplomacy, w: War) -> void:
	map = m
	power = pw
	diplomacy = d
	war = w
	for c in map.casus_belli:
		cbs[c["id"]] = c
		_order.append(c["id"])
	for g in map.war_goals:
		goals[g["id"]] = g


func enabled() -> bool:
	return not cbs.is_empty()


static func name_of(id: String) -> String:
	return Loc.t(id, PT_NAMES.get(id, Eu4Importer.pretty_key(id.trim_prefix("cb_"))))


## Casus belli que `a` tem contra `b`, o preferido primeiro.
func available(a: String, b: String) -> Array:
	var out := []
	if a == b or not map.countries.has(a) or not map.countries.has(b):
		return out
	var subject := diplomacy.overlord(a).size() > 0
	for id in _order:
		var c: Dictionary = cbs[id]
		if c["triggered"] or (subject and not c["valid_for_subject"] and not c["independence"]):
			continue
		if c["independence"] and not subject:
			continue
		if _test(c["prerequisites_self"], {"tag": a}, a, b) != true:
			continue
		if _test(c["prerequisites"], {"tag": a}, a, b) != true:
			continue
		out.append(id)
	out.sort_custom(func(x, y):
		var px := PREFERRED.find(x)
		var py := PREFERRED.find(y)
		px = px if px >= 0 else 100 + _order.find(x)
		py = py if py >= 0 else 100 + _order.find(y)
		return px < py)
	return out


## Avalia um bloco de condições do EU4 com ROOT = `root` e FROM = `from` (true, false ou null =
## desconhecido). Usado também pelas condições das ações diplomáticas e dos insultos.
func check(tree: Array, root: String, from: String) -> Variant:
	return _test(tree, {"tag": root}, root, from)


## O mesmo para um bloco no escopo de província (allowed_provinces dos objetivos de guerra).
func check_province(tree: Array, pid: int, root: String, from: String) -> Variant:
	return _test(tree, {"pid": pid}, root, from)


func best(a: String, b: String) -> String:
	var l := available(a, b)
	return l[0] if not l.is_empty() else ""


func war_goal_of(cb: String) -> String:
	return str(cbs.get(cb, {}).get("war_goal", ""))


# ------------------------------------------------------------------ avaliação
## Bloco = AND dos itens (vazio = verdadeiro).
func _test(items: Array, scope: Dictionary, root: String, from: String) -> Variant:
	var res: Variant = true
	for it in items:
		var v: Variant = _cond(str(it[0]), it[1], scope, root, from)
		if v == false:
			return false
		if v == null:
			res = null
	return res


func _any(items: Array, scope: Dictionary, root: String, from: String) -> Variant:
	var res: Variant = false
	for it in items:
		var v: Variant = _cond(str(it[0]), it[1], scope, root, from)
		if v == true:
			return true
		if v == null:
			res = null
	return res


static func _not(v: Variant) -> Variant:
	return null if v == null else not v


## País indicado pelo valor ("ROOT", "FROM", tag) ou "" se não for país.
func _country(v: String, root: String, from: String) -> String:
	match v.to_upper():
		"ROOT":
			return root
		"FROM":
			return from
	return v if map.countries.has(v) else ""


func _yes(v: Variant) -> bool:
	return str(v) == "yes"


## Coisas que o jogo ainda não tem (flags, missões, eventos...): sempre falsas.
const ALWAYS_FALSE := ["has_country_flag", "has_global_flag", "mission_completed", "has_ruler_flag",
		"has_country_modifier", "has_province_flag", "is_excommunicated", "is_defender_of_faith",
		"is_hegemon", "trade_embargo_by", "trade_league_embargoed_by", "is_trade_league_leader", "is_league_leader",
		"is_in_league_war", "is_league_enemy", "is_rival", "is_colonial_nation_of", "coalition_target",
		"is_in_coalition_war", "has_privateers", "has_spawned_supported_rebels", "is_revolution_target",
		"hre_religion_treaty", "crusade_target", "is_imperial_ban_allowed", "hre_reform_passed", "is_religion_reformed",
		"has_government_attribute",      # atributos especiais de reformas (guerras santas melhoradas...)
		"invasion_nation", "colony_claim", "num_of_coalition_members", "succession_claim", "cb_on_government_enemies"]
var unknown := {}                 # condições que o jogo não conhece (para depurar): chave -> vezes


func _cond(k: String, v: Variant, scope: Dictionary, root: String, from: String) -> Variant:
	if k in ALWAYS_FALSE:
		return false
	var tag: String = scope.get("tag", "")
	var pid: int = int(scope.get("pid", -1))
	match k:
		"AND":
			return _test(v, scope, root, from) if v is Array else null
		"OR", "or":
			return _any(v, scope, root, from) if v is Array else null
		"NOT":
			return _not(_any(v, scope, root, from)) if v is Array else null
		"FROM", "from":
			return _test(v, {"tag": from}, root, from) if v is Array else null
		"ROOT", "root":
			return _test(v, {"tag": root}, root, from) if v is Array else null
		"capital_scope":
			if tag == "" or not (v is Array):
				return null
			var cap := int(map.countries.get(tag, {}).get("capital", -1))
			return _test(v, {"pid": cap}, root, from) if cap >= 0 and cap < map.provinces.size() else false
		"any_owned_province":
			if tag == "" or not (v is Array):
				return null
			var res: Variant = false
			for p in map.provinces_of(tag):
				var r: Variant = _test(v, {"pid": int(p["id"])}, root, from)
				if r == true:
					return true
				if r == null:
					res = null
			return res
		"any_neighbor_province":
			if not (v is Array):
				return null
			var list := []
			if pid >= 0:
				list = map.provinces[pid].get("neighbors", [])
			elif tag != "":
				var mine := {}
				for p in map.provinces_of(tag):
					mine[int(p["id"])] = true
				var seen := {}
				for p in map.provinces_of(tag):
					for n in p.get("neighbors", []):
						if not mine.has(int(n)) and not seen.has(int(n)):
							seen[int(n)] = true
							list.append(int(n))
			var res: Variant = false
			for n in list:
				if map.provinces[int(n)]["sea"]:
					continue
				var r: Variant = _test(v, {"pid": int(n)}, root, from)
				if r == true:
					return true
				if r == null:
					res = null
			return res
		"always":
			return _yes(v)
		"is_revolutionary":
			return not _yes(v)
		"has_dlc":
			return true
		"cb_on_religious_enemies":
			return _yes(v)
		"ai":
			return _yes(v) == (tag != power.player)
		"exists":
			var t := _country(str(v), root, from)
			return t != "" and not map.provinces_of(t).is_empty()
	var r: Variant = null
	if pid >= 0:
		r = _prov_cond(k, v, pid, root, from)
	elif tag != "":
		r = _country_cond(k, v, tag, root, from)
	if r == null:
		unknown[k] = int(unknown.get(k, 0)) + 1
	return r


func _country_cond(k: String, v: Variant, tag: String, root: String, from: String) -> Variant:
	var c: Dictionary = map.countries.get(tag, {})
	var s := str(v)
	match k:
		"tag":
			return tag == _country(s, root, from) or tag == s
		"government":
			return str(c.get("government", "")) == s
		"has_reform":
			return s in c.get("reforms", [])
		"technology_group":
			var o := _country(s, root, from)
			return str(c.get("tech_group", "")) == (str(map.countries[o].get("tech_group", "")) if o != "" else s)
		"religion":
			var o := _country(s, root, from)
			return str(c.get("religion", "")) == (str(map.countries[o].get("religion", "")) if o != "" else s)
		"religion_group":
			var o := _country(s, root, from)
			var g := _rel_group(str(c.get("religion", "")))
			return g != "" and g == (_rel_group(str(map.countries[o].get("religion", ""))) if o != "" else s)
		"has_matching_religion":
			var o := _country(s, root, from)
			return o != "" and str(c.get("religion", "")) == str(map.countries[o].get("religion", ""))
		"primary_culture":
			var o := _country(s, root, from)
			return str(c.get("primary_culture", "")) == (str(map.countries[o].get("primary_culture", "")) if o != "" else s)
		"culture_group":
			var o := _country(s, root, from)
			if o == "":
				return null             # o mapa guarda o nome do grupo, não o id
			var g := _cul_group(str(c.get("primary_culture", "")))
			return g != "" and g == _cul_group(str(map.countries[o].get("primary_culture", "")))
		"is_neighbor_of":
			var o := _country(s, root, from)
			return o != "" and _neighbors(tag).has(o)
		"is_subject":
			return (diplomacy.overlord(tag).size() > 0) == _yes(v)
		"is_free_or_tributary_trigger":
			var ov := diplomacy.overlord(tag)
			return (ov.is_empty() or ov[1] == "tributary_state") == _yes(v)
		"is_subject_other_than_tributary_trigger":
			var ov := diplomacy.overlord(tag)
			return (not ov.is_empty() and ov[1] != "tributary_state") == _yes(v)
		"is_subject_of", "vassal_of":
			var o := _country(s, root, from)
			var ov := diplomacy.overlord(tag)
			return o != "" and not ov.is_empty() and ov[0] == o
		"overlord_of":
			var o := _country(s, root, from)
			var ov := diplomacy.overlord(o) if o != "" else []
			return not ov.is_empty() and ov[0] == tag
		"junior_union_with":
			var o := _country(s, root, from)
			var ov := diplomacy.overlord(tag)
			return o != "" and not ov.is_empty() and ov[0] == o and ov[1] == "union"
		"alliance_with":
			return _country(s, root, from) in diplomacy.allies(tag)
		"truce_with":
			var o := _country(s, root, from)
			return war != null and o != "" and war.has_truce(tag, o)
		"war_with":
			var o := _country(s, root, from)
			return war != null and o != "" and war.hostile(tag, o)
		"has_heir":
			return (not c.get("heir", {}).is_empty()) == _yes(v)
		"has_regency":
			return not _yes(v)
		"has_ruler":
			return str(c.get("monarch", {}).get("name", "")) == s
		"dynasty":
			var o := _country(s, root, from)
			var dyn := str(c.get("monarch", {}).get("dynasty", ""))
			return dyn != "" and dyn == (str(map.countries[o].get("monarch", {}).get("dynasty", "")) if o != "" else s)
		"government_rank":
			return s.is_valid_float() and int(c.get("rank", 1)) >= int(float(s))
		"owns":
			return s.is_valid_int() and int(s) < map.provinces.size() and map.provinces[int(s)]["owner"] == tag
		"is_emperor":
			return (tag == diplomacy.emperor) == _yes(v)
		"is_emperor_of_china":
			return (tag == diplomacy.celestial_emperor) == _yes(v)
		"is_elector":
			return diplomacy.is_elector(tag) == _yes(v)
		"is_part_of_hre":
			var cap := int(c.get("capital", -1))
			var hre: bool = cap >= 0 and cap < map.provinces.size() and map.provinces[cap].get("hre", false)
			return hre == _yes(v)
		"is_native_tribe":
			return (str(c.get("government", "")) == "native") == _yes(v)
		"is_nomad", "is_migratory_tribe":
			var nomad := false
			for r in c.get("reforms", []):
				if "horde" in str(r) or "steppe" in str(r):
					nomad = true
			return nomad == _yes(v)
		"num_of_cities":
			return s.is_valid_float() and map.provinces_of(tag).size() >= int(float(s))
		"dip_tech":
			return s.is_valid_float() and TechWindow.level_of(map, tag, "dip", power) >= int(float(s))
		"adm_tech", "mil_tech":
			return s.is_valid_float() and TechWindow.level_of(map, tag, k.substr(0, 3), power) >= int(float(s))
		"full_idea_group":
			for g in power.adopted(tag):
				if g["id"] == s:
					var grp: Dictionary = power.idea_groups.get(s, {})
					return int(g["n"]) >= grp.get("ideas", []).size()
			return false
		"any_subject_country":
			if not (v is Array):
				return null
			var res: Variant = false
			for sub in diplomacy.subjects(tag):
				var r: Variant = _test(v, {"tag": sub[0]}, root, from)
				if r == true:
					return true
				if r == null:
					res = null
			return res
		"claim":
			var o := _country(s, root, from)
			if o == "":
				return null
			for p in map.provinces_of(o):
				if tag in p.get("claims", []):
					return true
			return false
		"core_claim":
			var o := _country(s, root, from)
			if o == "":
				return null
			for p in map.provinces_of(o):
				if tag in p.get("cores", []):
					return true
			return false
	return null


func _prov_cond(k: String, v: Variant, pid: int, root: String, from: String) -> Variant:
	var p: Dictionary = map.provinces[pid]
	var s := str(v)
	match k:
		"is_part_of_hre":
			return bool(p.get("hre", false)) == _yes(v)
		"region", "superregion", "continent", "area":
			return str(p.get(k, "")) == s
		"owned_by", "country_or_non_sovereign_subject_holds":
			var o := _country(s, root, from)
			return o != "" and p["owner"] == o
		"is_core":
			var o := _country(s, root, from)
			return o != "" and (o in p.get("cores", []) or (p["owner"] == o and not p.has("cores")))
		"is_claim":
			var o := _country(s, root, from)
			return o != "" and o in p.get("claims", [])
		"religion":
			var o := _country(s, root, from)
			return str(p.get("religion", "")) == (str(map.countries[o].get("religion", "")) if o != "" else s)
		"religion_group":
			var o := _country(s, root, from)
			var g := _rel_group(str(p.get("religion", "")))
			return g != "" and g == (_rel_group(str(map.countries[o].get("religion", ""))) if o != "" else s)
		"culture":
			var o := _country(s, root, from)
			return str(p.get("culture", "")) == (str(map.countries[o].get("primary_culture", "")) if o != "" else s)
		"has_owner_accepted_culture":
			var c: Dictionary = map.countries.get(p["owner"], {})
			var cul := str(p.get("culture", ""))
			return (cul == str(c.get("primary_culture", "")) or cul in c.get("accepted_cultures", [])) == _yes(v)
		"is_capital":
			var c: Dictionary = map.countries.get(p["owner"], {})
			return (int(c.get("capital", -1)) == pid) == _yes(v)
		"province_id":
			return s.is_valid_int() and int(s) == pid
		"has_terrain":
			return str(map.terrains.get(p.get("terrain", ""), {}).get("eu4", "")) == s
		"fort_level":
			var lvl := map.building_mod(p, "fort_level")
			if int(map.countries.get(p["owner"], {}).get("capital", -1)) == pid:
				lvl += 1.0
			return s.is_valid_float() and lvl >= float(s)
	return null


func _rel_group(rid: String) -> String:
	return str(map.religions.get(rid, {}).get("group", ""))


func _cul_group(cid: String) -> String:
	return str(map.cultures.get(cid, {}).get("group", ""))


## Países que fazem fronteira por terra com `tag` (refeito quando um dono muda).
func _neighbors(tag: String) -> Dictionary:
	if _neigh_version != map.owner_version:
		_neigh_version = map.owner_version
		_neigh.clear()
		for p in map.provinces:
			var o: String = p["owner"]
			if o == "" or p["sea"]:
				continue
			for n in p.get("neighbors", []):
				var q: Dictionary = map.provinces[int(n)]
				var o2: String = q["owner"]
				if o2 != "" and o2 != o and not q["sea"]:
					if not _neigh.has(o):
						_neigh[o] = {}
					_neigh[o][o2] = true
	return _neigh.get(tag, {})
