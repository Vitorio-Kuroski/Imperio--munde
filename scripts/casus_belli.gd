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
##    núcleos e reivindicações de 1444, região, continente...). Flags e modificadores de país vêm do
##    `Eu4Effects`; o que depende de coisas que o jogo ainda não tem (missões, excomunhão...) é
##    falso; condição desconhecida deixa
##    o resultado desconhecido, e desconhecido no fim conta como falso.
##  - Declarar guerra sem casus belli custa NO_CB_STABILITY (2) de estabilidade (regra do EU4).

const NO_CB_STABILITY := -2
## Preferência ao escolher o casus belli da declaração (os outros vêm depois, na ordem do arquivo).
const PREFERRED := ["cb_super_badboy", "cb_core", "cb_conquest", "cb_independence_war", "cb_heretic", "cb_crusade", "cb_imperial",
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
var diplo: DiploActions           # main.gd define (has_opinion_modifier)
var coalition: Coalition          # main.gd define (coalition_target, num_of_coalition_members...)
var economy: Economy              # main.gd define (treasury, years_of_income)
var estates: Estates              # main.gd define (has_estate, has_estate_privilege)
var trade_share_override := -1.0   # ≥ 0: trade_income_percentage fixo (partilha das terras na partida)
var effects: Eu4Effects           # Eu4Effects.setup define (flags, modificadores de país, change_tag)
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
## has_government_attribute: atributo (chave = yes, também dentro de custom_attributes) de uma
## reforma do país ou da reforma básica do governo (common/governments basic_reform).
func _gov_attribute(tag: String, attr: String) -> bool:
	var c: Dictionary = map.countries.get(tag, {})
	var reforms: Array = (c.get("reforms", []) as Array).duplicate()
	var gov = Eu4Data.merged("common/governments").get(str(c.get("government", "")), [])
	var basic = Estates.tget(gov, "basic_reform")
	if basic != null:
		reforms.append(str(basic))
	var all := Eu4Data.merged("common/government_reforms")
	for r in reforms:
		var tree = all.get(str(r), [])
		if str(Estates.tget(tree, attr)) == "yes" or str(Estates.tget(Estates.tget(tree, "custom_attributes"), attr)) == "yes":
			return true
	return false


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
## if/else_if/else (gatilhos condicionais do EU4): `if = { limit = { A } B }` exige B só se A vale;
## o `else` seguinte vale quando nenhum if/else_if da corrente teve o limit verdadeiro.
func _test(items: Array, scope: Dictionary, root: String, from: String) -> Variant:
	var res: Variant = true
	var taken: Variant = true          # algum if/else_if anterior da corrente teve o limit verdadeiro
	for it in items:
		var k := str(it[0])
		var v: Variant
		if k == "if" or k == "else_if" or k == "else":
			if not (it[1] is Array):
				continue
			if k != "if" and taken == true:
				continue
			if k == "else":
				v = true if taken == null else _test(it[1], scope, root, from)
				taken = true
			else:
				var lim: Variant = true
				var body := []
				for kv in it[1]:
					if kv[0] == "limit":
						lim = _test(kv[1], scope, root, from) if kv[1] is Array else null
					else:
						body.append(kv)
				taken = lim
				v = _test(body, scope, root, from) if lim == true else (true if lim == false else null)
		else:
			taken = true
			v = _cond(k, it[1], scope, root, from)
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
	if effects:                   # quem formou outra nação (change_tag) responde pela tag nova
		return effects.key_of(v)
	return v if map.countries.has(v) else ""


func _yes(v: Variant) -> bool:
	return str(v) == "yes"


## Coisas que o jogo ainda não tem (flags, missões, eventos...): sempre falsas.
const ALWAYS_FALSE := ["mission_completed", "has_ruler_flag", "has_province_flag", "is_excommunicated", "is_defender_of_faith",
		"is_hegemon", "trade_embargo_by", "trade_league_embargoed_by", "is_trade_league_leader", "is_league_leader",
		"is_in_league_war", "is_league_enemy", "is_rival", "is_colonial_nation_of", "has_privateers",
		"has_spawned_supported_rebels", "is_revolution_target",
		"hre_religion_treaty", "crusade_target", "is_imperial_ban_allowed", "hre_reform_passed", "is_religion_reformed",
		"has_government_attribute",      # atributos especiais de reformas (guerras santas melhoradas...)
		"invasion_nation", "colony_claim", "succession_claim", "cb_on_government_enemies"]
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
		"is_colonial_nation", "is_former_colonial_nation", "is_playing_custom_nation", "is_lesser_in_union_with_player":
			return not _yes(v)          # não existem nações coloniais nem personalizadas no jogo
		"army_professionalism":         # ainda não existe: 0, como no começo do EU4
			return str(v).is_valid_float() and str(v).to_float() <= 0.0
		"normal_or_historical_nations":
			return _yes(v)              # regra de jogo: nações históricas (não aleatórias)
		"end_game_tags_blocked":
			return not _yes(v)          # regra de jogo padrão do EU4: não bloqueia
		"tooltip", "custom_tooltip":
			return true                 # só texto da dica
		"custom_trigger_tooltip":
			return _test(v, scope, root, from) if v is Array else null
		"was_tag":                      # tags que o país já teve (change_tag do Eu4Effects)
			return tag != "" and (effects.was_tag(tag, str(v)) if effects else tag == str(v))
		"has_country_flag":
			return tag != "" and effects != null and effects.has_flag(tag, str(v))
		"has_global_flag":
			return effects != null and effects.has_global_flag(str(v))
		"has_country_modifier":
			return tag != "" and effects != null and effects.has_modifier(tag, str(v))
		"is_revolutionary":
			return not _yes(v)
		"has_dlc":
			return true
		# estamentos
		"has_estate":
			return tag != "" and estates != null and estates.has(tag, str(v))
		"has_estate_privilege":
			return tag != "" and estates != null and str(v) in estates.privileges.get(tag, [])
		"has_government_attribute":
			return tag != "" and _gov_attribute(tag, str(v))
		"has_enabled_estate", "has_unlocked_estate", "has_disabled_estate", "has_any_estate_disaster_active", \
				"has_not_own_estate_disaster_active", "has_ruler_modifier", "has_absolutism_reduction_for_estate_privileges":
			return false                # desastres, modificadores do governante, estamentos ligados por evento: não existem
		"trade_income_percentage":
			if tag == "" or not str(v).is_valid_float():
				return null
			if trade_share_override >= 0.0:
				return trade_share_override >= float(str(v))
			if economy == null:
				return null
			var inc: Dictionary = economy.income(tag)
			var tot := float(inc.get("total", 0.0))
			return tot > 0.0 and float(inc.get("trade", 0.0)) / tot >= float(str(v))
		"dominant_religion":
			if tag == "":
				return null
			var o := _country(str(v), root, from)
			var want: String = str(map.countries[o].get("religion", "")) if o != "" else str(v)
			var dev := {}
			for p in map.provinces_of(tag):
				var r := str(p.get("religion", ""))
				dev[r] = float(dev.get(r, 0.0)) + float(p["development"])
			var best := ""
			for r in dev:
				if best == "" or dev[r] > dev[best]:
					best = r
			return best == want
		"province_has_center_of_trade_of_level":
			return pid >= 0 and str(v).is_valid_float() and int(map.provinces[pid].get("center_of_trade", 0)) >= int(float(str(v)))
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
	if r == null and v is String and (v == "yes" or v == "no"):
		# gatilho pronto do EU4 (common/scripted_triggers): "x = yes" avalia o bloco, "x = no" o nega
		var st: Variant = Eu4Data.merged("common/scripted_triggers").get(k)
		if st is Array and not JSON.stringify(st).contains("$"):
			r = _test(st, scope, root, from)
			if v == "no":
				r = _not(r)
	if r == null:
		unknown[k] = int(unknown.get(k, 0)) + 1
	return r


func _country_cond(k: String, v: Variant, tag: String, root: String, from: String) -> Variant:
	var c: Dictionary = map.countries.get(tag, {})
	var s := str(v)
	match k:
		"tag":
			if s.to_upper() == "ROOT" or s.to_upper() == "FROM":
				return tag == _country(s, root, from)
			return (effects.current_tag(tag) if effects else tag) == s
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
			if o == "":                 # id do grupo (common/cultures): o mapa guarda só o nome
				return _cul_group_id(str(c.get("primary_culture", ""))) == s
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
		"coalition_target":
			var o := _country(s, root, from)
			return coalition != null and o != "" and coalition.target_of(tag) == o
		"num_of_coalition_members":
			var t := coalition.target_of(tag) if coalition else ""
			return t != "" and s.is_valid_float() and coalition.members_against(t).size() >= int(float(s))
		"is_in_coalition_war":
			return coalition != null and coalition.in_coalition_war(tag) == _yes(v)
		"has_opinion_modifier":
			if diplo == null or not (v is Array):
				return null
			var mid := ""
			var who := ""
			var val: Variant = null
			for it in v:
				match str(it[0]):
					"modifier":
						mid = str(it[1])
					"who":
						who = _country(str(it[1]), root, from)
					"value":
						val = float(str(it[1])) if str(it[1]).is_valid_float() else null
			if mid == "" or who == "":
				return null
			var e: Variant = diplo.timed.get(tag + ">" + who, {}).get(mid)
			if e == null:
				# os temporários que o jogo controla; os outros (alianças...) ficam desconhecidos
				return false if mid in ["aggressive_expansion", "insulted", "improved_relation", "break_alliance",
						"break_marriage"] else null
			return val == null or float(e[0]) >= float(val)
		"truce_with":
			var o := _country(s, root, from)
			return war != null and o != "" and war.has_truce(tag, o)
		"is_at_war":
			return war != null and war.at_war(tag) == _yes(v)
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
		"adm_power", "dip_power", "mil_power":
			return s.is_valid_float() and power.points(tag, k.substr(0, 3)) >= float(s)
		"treasury":
			return economy != null and s.is_valid_float() and economy.money(tag) >= float(s)
		"years_of_income":
			return economy != null and s.is_valid_float() \
					and economy.money(tag) >= float(s) * 12.0 * float(economy.income(tag).get("total", 0.0))
		"stability":
			return effects != null and effects.stability != null and s.is_valid_float() and effects.stability.of(tag) >= int(float(s))
		"prestige":
			return effects != null and effects.prestige != null and s.is_valid_float() and effects.prestige.of(tag) >= float(s)
		"owns_core_province":
			return s.is_valid_int() and int(s) < map.provinces.size() and map.provinces[int(s)]["owner"] == tag 					and _prov_cond("is_core", tag, int(s), root, from) == true
		"num_of_owned_provinces_with":
			if not (v is Array):
				return null
			var need := 1
			var conds := []
			for it in v:
				if str(it[0]) == "value":
					need = int(float(str(it[1]))) if str(it[1]).is_valid_float() else 1
				else:
					conds.append(it)
			var cnt := 0
			for p in map.provinces_of(tag):
				var r: Variant = _test(conds, {"pid": int(p["id"])}, root, from)
				if r == null:
					return null
				if r == true:
					cnt += 1
					if cnt >= need:
						return true
			return false
		"owns":
			return s.is_valid_int() and int(s) < map.provinces.size() and map.provinces[int(s)]["owner"] == tag
		"capital":
			return s.is_valid_int() and int(c.get("capital", -1)) == int(s)
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
		"has_idea_group":
			for g in power.adopted(tag):
				if g["id"] == s:
					return true
			return false
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
		"is_claim", "is_permanent_claim":
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
		"development":
			return s.is_valid_float() and float(p["development"]) >= float(s)
		"base_tax", "base_production", "base_manpower":
			return s.is_valid_float() and float(p.get(k, 0)) >= float(s)
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


var _rel_groups := {}


## Id do grupo religioso em common/religions ("christian" para catholic). O mapa guarda só o nome
## traduzido do grupo ("Cristã"), que não serve para comparar com religion_group = christian.
func _rel_group(rid: String) -> String:
	if _rel_groups.is_empty():
		var rel := Eu4Data.merged("common/religions")
		for gid in rel:
			if not (rel[gid] is Array):
				continue
			for kv in rel[gid]:
				if kv[1] is Array and JSON.stringify(kv[1]).contains("\"icon\""):
					_rel_groups[kv[0]] = gid
		_rel_groups[""] = ""
	if _rel_groups.size() > 1:
		return str(_rel_groups.get(rid, ""))
	return str(map.religions.get(rid, {}).get("group", ""))


var _group_ids := {}


## Id do grupo da cultura em common/cultures ("scandinavian" para swedish).
func _cul_group_id(cid: String) -> String:
	if _group_ids.is_empty():
		for gid in Eu4Data.merged("common/cultures"):
			var tree: Variant = Eu4Data.merged("common/cultures")[gid]
			if not (tree is Array):
				continue
			for kv in tree:
				if kv[1] is Array and not (kv[0] in ["graphical_culture", "male_names", "female_names", "dynasty_names", "country", "province"]):
					_group_ids[kv[0]] = gid
		_group_ids[""] = ""
	return str(_group_ids.get(cid, ""))


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
