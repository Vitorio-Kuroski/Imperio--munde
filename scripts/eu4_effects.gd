class_name Eu4Effects
extends RefCounted
## Executor dos blocos de efeito do EU4 (`effect` das decisões, e no futuro eventos e missões) sobre
## os sistemas que o jogo já tem. Também guarda o estado que os efeitos criam e as condições leem:
##  - flags de país e globais (`set_country_flag`/`clr_country_flag`, `set_global_flag`; o
##    `CasusBelli` lê has_country_flag/has_global_flag daqui);
##  - modificadores de país com duração (`add_country_modifier` com `name` de common/event_modifiers e
##    `duration` em dias, −1 = para sempre; `remove_country_modifier`; os efeitos numéricos entram em
##    `MonarchPower.modifier` por `modifiers(tag)`; has_country_modifier no `CasusBelli`);
##  - formação de nação (`change_tag`): APROXIMAÇÃO — o país continua com a chave interna (todos os
##    sistemas guardam o estado pela tag), mas passa a se chamar e ter a cor da nova tag (common/
##    countries, localização), as ideias nacionais dela (common/ideas) e as condições `tag`, `exists`,
##    `was_tag` e os valores "SCA" passam a apontar para ele (`current_tag`, `key_of`). A bandeira
##    continua a antiga (o atlas só tem as bandeiras dos países de 1444).
## Escopos: país e província ({"tag"} / {"pid"}, os mesmos do avaliador do `CasusBelli`), ROOT, FROM,
## PREV, owner, capital_scope, every_/random_ owned_province, province, country, subject_country,
## neighbor_country, e áreas/regiões/superregiões/continentes, ids de província e tags como escopo
## (com `limit`). if/else_if/else, hidden_effect, custom_tooltip e os efeitos prontos de
## common/scripted_effects ("x = yes", sem parâmetros $). Efeito desconhecido é ignorado e contado em
## `unknown` (chave -> vezes); `describe` dá as linhas da dica com o que vai acontecer.

signal changed(tag: String)

const ITER := ["every_owned_province", "random_owned_province", "every_province", "random_province",
		"every_country", "random_country", "every_subject_country", "random_subject_country",
		"every_neighbor_country", "random_neighbor_country", "every_core_province", "random_core_province"]
## Efeitos que só mexem em coisas que o jogo não tem e não mudam nada visível aqui (nem contam como
## desconhecidos): textos, pré-visualizações, missões trocadas...
const NOOP := ["custom_tooltip", "tooltip", "swap_non_generic_missions", "update_mission_previews",
		"restore_country_name", "restore_country_color", "save_event_target_as", "save_global_event_target_as",
		"log", "show_ambient_object"]
const IDEA_SKIP := ["start", "bonus", "trigger", "free", "ai_will_do", "important", "category"]

var map: MapView
var clock: GameClock
var power: MonarchPower
var cbs: CasusBelli
var economy: Economy
var prestige: Prestige
var stability: Stability
var legitimacy: Legitimacy
var diplomacy: Diplomacy
var religion: Religion

var day := 0                      # dias desde o início (para as durações)
var flags := {}                   # tag -> {flag: dia}
var global_flags := {}            # flag -> dia
var country_mods := {}            # tag -> {nome: dia em que acaba (−1 = nunca)}
var formed := {}                  # chave interna -> tag atual (change_tag)
var former := {}                  # chave interna -> [tags que já teve]
var unknown := {}                 # efeitos ignorados: chave -> vezes
var _mod_defs := {}               # nome -> {efeito: valor} (common/event_modifiers)


func setup(m: MapView, c: GameClock, pw: MonarchPower, cb: CasusBelli) -> void:
	map = m
	clock = c
	power = pw
	cbs = cb
	cbs.effects = self
	power.effects = self
	clock.day_passed.connect(func(): day += 1)
	clock.month_passed.connect(_expire)


# ------------------------------------------------------------------ estado lido pelas condições
func has_flag(tag: String, f: String) -> bool:
	return flags.get(tag, {}).has(f)


func has_global_flag(f: String) -> bool:
	return global_flags.has(f)


func has_modifier(tag: String, name: String) -> bool:
	var end: Variant = country_mods.get(tag, {}).get(name)
	return end != null and (int(end) < 0 or int(end) > day)


## Tag que o país usa hoje (a de quem formou outra nação; senão a própria chave).
func current_tag(key: String) -> String:
	return str(formed.get(key, key))


## Chave interna do país que usa `tag` hoje ("" se ninguém usa; a chave antiga de quem formou outra
## nação também deixa de existir).
func key_of(tag: String) -> String:
	for k in formed:
		if formed[k] == tag:
			return k
	if formed.has(tag) and formed[tag] != tag:
		return ""
	return tag if map.countries.has(tag) else ""


func was_tag(key: String, tag: String) -> bool:
	return key == tag or current_tag(key) == tag or tag in former.get(key, [])


## Efeitos somados dos modificadores de país ativos (entram em MonarchPower._sum_mods).
func modifiers(tag: String) -> Dictionary:
	var out := {}
	for n in country_mods.get(tag, {}):
		if not has_modifier(tag, n):
			continue
		var d: Dictionary = mod_def(n)
		for k in d:
			out[k] = float(out.get(k, 0.0)) + float(d[k])
	return out


func mod_def(name: String) -> Dictionary:
	if not _mod_defs.has(name):
		var out := {}
		var tree: Variant = Eu4Data.merged("common/event_modifiers").get(name)
		if tree is Array:
			for kv in tree:
				if str(kv[1]).is_valid_float():
					out[str(kv[0])] = float(str(kv[1]))
		_mod_defs[name] = out
	return _mod_defs[name]


func _expire() -> void:
	for tag in country_mods:
		for n in country_mods[tag].keys():
			if not has_modifier(tag, n):
				country_mods[tag].erase(n)
				power.invalidate(tag)
				_changed(tag)


# ------------------------------------------------------------------ execução
## Roda um bloco de efeitos com ROOT = `root` (no escopo do país) e FROM = `from`.
func run(tree: Array, root: String, from := "") -> void:
	_run(tree, {"tag": root}, {}, root, from if from != "" else root)
	power.invalidate(root)
	if economy:
		economy.invalidate(root)
	_changed(root)


func _run(items: Array, scope: Dictionary, prev: Dictionary, root: String, from: String) -> void:
	var chain_done := false            # algum if/else_if anterior da corrente já rodou
	for it in items:
		var k := str(it[0])
		var v: Variant = it[1]
		match k:
			"if":
				chain_done = _if(v, scope, prev, root, from)
				continue
			"else_if":
				if not chain_done:
					chain_done = _if(v, scope, prev, root, from)
				continue
			"else":
				if not chain_done and v is Array:
					_run(v, scope, prev, root, from)
				chain_done = true
				continue
		chain_done = false
		_effect(k, v, scope, prev, root, from)


func _if(v: Variant, scope: Dictionary, prev: Dictionary, root: String, from: String) -> bool:
	if not (v is Array):
		return false
	if not _limit(v, scope, root, from):
		return false
	_run(_without_limit(v), scope, prev, root, from)
	return true


func _limit(block: Array, scope: Dictionary, root: String, from: String) -> bool:
	for kv in block:
		if kv[0] == "limit":
			return kv[1] is Array and cbs._test(kv[1], scope, root, from) == true
	return true


func _without_limit(block: Array) -> Array:
	return block.filter(func(kv): return kv[0] != "limit")


## País indicado pelo valor (ROOT, FROM, PREV, THIS, tag atual) ou "".
func _who(v: Variant, scope: Dictionary, prev: Dictionary, root: String, from: String) -> String:
	var s := str(v)
	match s.to_upper():
		"ROOT":
			return root
		"FROM":
			return from
		"THIS":
			return str(scope.get("tag", _owner(scope)))
		"PREV":
			return str(prev.get("tag", _owner(prev)))
		"OWNER":
			return _owner(scope)
	return key_of(s)


func _owner(scope: Dictionary) -> String:
	if scope.has("tag"):
		return str(scope["tag"])
	var pid := int(scope.get("pid", -1))
	return str(map.provinces[pid]["owner"]) if pid >= 0 and pid < map.provinces.size() else ""


func _num(v: Variant) -> float:
	var s := str(v)
	return float(s) if s.is_valid_float() else 0.0


func _effect(k: String, v: Variant, scope: Dictionary, prev: Dictionary, root: String, from: String) -> void:
	if k in NOOP:
		return
	var tag: String = scope.get("tag", "")
	var pid: int = int(scope.get("pid", -1))
	# mudanças de escopo
	match k:
		"hidden_effect":
			if v is Array:
				_run(v, scope, prev, root, from)
			return
		"ROOT", "root", "FROM", "from", "PREV", "prev", "owner", "controller":
			var t := _who(k if k != "controller" else "owner", scope, prev, root, from)
			if t != "" and v is Array and _limit(v, {"tag": t}, root, from):
				_run(_without_limit(v), {"tag": t}, scope, root, from)
			return
		"capital_scope":
			var cap := int(map.countries.get(tag, {}).get("capital", -1)) if tag != "" else -1
			if cap >= 0 and v is Array and _limit(v, {"pid": cap}, root, from):
				_run(_without_limit(v), {"pid": cap}, scope, root, from)
			return
	if k in ITER:
		if v is Array:
			_iterate(k, v, scope, root, from)
		return
	if v is Array and _geo_scope(k, v, scope, root, from):
		return
	var r := false
	if tag != "":
		r = _country_effect(k, v, tag, scope, prev, root, from)
	elif pid >= 0:
		r = _province_effect(k, v, pid, scope, prev, root, from)
	if not r and (str(v) == "yes" or str(v) == "no"):
		var se: Variant = Eu4Data.merged("common/scripted_effects").get(k)
		if se is Array and not JSON.stringify(se).contains("$"):
			if str(v) == "yes":
				_run(se, scope, prev, root, from)
			r = true
	if not r:
		unknown[k] = int(unknown.get(k, 0)) + 1


func _iterate(k: String, v: Array, scope: Dictionary, root: String, from: String) -> void:
	var tag := _owner(scope)
	var kind := k.trim_prefix("every_").trim_prefix("random_")
	var list := []                     # escopos candidatos
	match kind:
		"owned_province":
			for p in map.provinces_of(tag):
				list.append({"pid": int(p["id"])})
		"core_province":
			for p in map.provinces:
				if not p["sea"] and cbs._prov_cond("is_core", tag, int(p["id"]), root, from) == true:
					list.append({"pid": int(p["id"])})
		"province":
			for p in map.provinces:
				if not p["sea"]:
					list.append({"pid": int(p["id"])})
		"country":
			for t in map.countries:
				if not map.provinces_of(t).is_empty():
					list.append({"tag": t})
		"subject_country":
			for s in (diplomacy.subjects(tag) if diplomacy else []):
				list.append({"tag": s[0]})
		"neighbor_country":
			for t in cbs._neighbors(tag):
				list.append({"tag": t})
	list = list.filter(func(sc): return _limit(v, sc, root, from))
	if list.is_empty():
		return
	var body := _without_limit(v)
	if k.begins_with("random_"):
		_run(body, list[randi() % list.size()], scope, root, from)
	else:
		for sc in list:
			_run(body, sc, scope, root, from)


## Área, região, superregião, continente, id de província ou tag usados como escopo.
func _geo_scope(k: String, v: Array, scope: Dictionary, root: String, from: String) -> bool:
	if k.is_valid_int():
		var pid := int(k)
		if pid > 0 and pid < map.provinces.size() and _limit(v, {"pid": pid}, root, from):
			_run(_without_limit(v), {"pid": pid}, scope, root, from)
		return pid > 0 and pid < map.provinces.size()
	var field := ""
	if map.areas.has(k):
		field = "area"
	elif map.regions.has(k):
		field = "region"
	elif map.superregions.has(k):
		field = "superregion"
	elif map.continents.has(k):
		field = "continent"
	if field == "":
		var t := key_of(k)
		if t != "" and k == k.to_upper() and k.length() == 3:
			if _limit(v, {"tag": t}, root, from):
				_run(_without_limit(v), {"tag": t}, scope, root, from)
			return true
		return false
	var body := _without_limit(v)
	for p in map.provinces:
		if str(p.get(field, "")) == k and _limit(v, {"pid": int(p["id"])}, root, from):
			_run(body, {"pid": int(p["id"])}, scope, root, from)
	return true


func _country_effect(k: String, v: Variant, tag: String, scope: Dictionary, prev: Dictionary, root: String, from: String) -> bool:
	var c: Dictionary = map.countries[tag]
	var n := _num(v)
	match k:
		"add_prestige":
			if prestige:
				prestige.add(tag, n)
		"add_stability":
			if stability:
				stability.add(tag, int(n))
		"add_treasury":
			if economy:
				economy.treasury[tag] = economy.money(tag) + n
		"add_years_of_income":
			if economy:
				economy.treasury[tag] = economy.money(tag) + n * 12.0 * float(economy.income(tag).get("total", 0.0))
		"add_adm_power", "add_dip_power", "add_mil_power":
			var cat := k.substr(4, 3)
			if power.state.has(tag):
				power.state[tag]["points"][cat] = clampi(power.points(tag, cat) + int(n), -999, MonarchPower.MAX_POINTS)
		"add_legitimacy", "add_republican_tradition", "add_devotion":
			if legitimacy and legitimacy.kind(tag) == k.trim_prefix("add_"):
				legitimacy.add(tag, n)
		"set_country_flag":
			if not flags.has(tag):
				flags[tag] = {}
			flags[tag][str(v)] = day
		"clr_country_flag":
			flags.get(tag, {}).erase(str(v))
		"set_global_flag":
			global_flags[str(v)] = day
		"clr_global_flag":
			global_flags.erase(str(v))
		"add_country_modifier":
			if not (v is Array):
				return false
			var name := ""
			var dur := -1
			for kv in v:
				match str(kv[0]):
					"name":
						name = str(kv[1])
					"duration":
						dur = int(_num(kv[1]))
			if name == "":
				return false
			if not country_mods.has(tag):
				country_mods[tag] = {}
			country_mods[tag][name] = -1 if dur < 0 else day + dur
		"remove_country_modifier":
			country_mods.get(tag, {}).erase(str(v))
		"change_tag":
			_change_tag(tag, str(v))
		"set_government_rank":
			c["rank"] = int(n)
		"change_government":
			c["government"] = str(v)
		"add_government_reform":
			if not c.has("reforms"):
				c["reforms"] = []
			if not (str(v) in c["reforms"]):
				c["reforms"].append(str(v))
		"remove_government_reform":
			c.get("reforms", []).erase(str(v))
		"change_religion":
			var o := _who(v, scope, prev, root, from)
			c["religion"] = str(map.countries[o]["religion"]) if o != "" else str(v)
		"change_primary_culture":
			var o := _who(v, scope, prev, root, from)
			c["primary_culture"] = str(map.countries[o]["primary_culture"]) if o != "" else str(v)
		"add_accepted_culture":
			if not c.has("accepted_cultures"):
				c["accepted_cultures"] = []
			if not (str(v) in c["accepted_cultures"]):
				c["accepted_cultures"].append(str(v))
		"remove_accepted_culture":
			c.get("accepted_cultures", []).erase(str(v))
		"set_capital":
			var pid := int(n)
			if pid > 0 and pid < map.provinces.size() and map.provinces[pid]["owner"] == tag:
				c["capital"] = pid
				map.owner_version += 1
		"change_country_color":
			if v is Array:
				for kv in v:
					if kv[0] == "color" and kv[1] is Array and kv[1].size() >= 3:
						c["color"] = [int(_num(kv[1][0][1])), int(_num(kv[1][1][1])), int(_num(kv[1][2][1]))]
				_recolor()
		"override_country_name":
			c["name"] = Loc.t(str(v), Eu4Importer.pretty_key(str(v)))
			map.owner_version += 1
		"add_core", "add_claim", "add_permanent_claim", "remove_core", "remove_claim":
			var pid := int(n)               # no escopo de país o valor é a província
			if pid > 0 and pid < map.provinces.size():
				_province_effect(k, "PREV", pid, {"pid": pid}, scope, root, from)
		_:
			return false
	return true


func _province_effect(k: String, v: Variant, pid: int, scope: Dictionary, prev: Dictionary, root: String, from: String) -> bool:
	var p: Dictionary = map.provinces[pid]
	var n := _num(v)
	match k:
		"add_core":
			var t := _who(v, scope, prev, root, from)
			if t != "":
				var cores: Array = p.get("cores", [p["owner"]] if p["owner"] != "" else [])
				if not (t in cores):
					cores.append(t)
				p["cores"] = cores
		"remove_core":
			var t := _who(v, scope, prev, root, from)
			if t != "":
				var cores: Array = p.get("cores", [p["owner"]] if p["owner"] != "" else [])
				cores.erase(t)
				p["cores"] = cores
		"add_claim", "add_permanent_claim":
			var t := _who(v, scope, prev, root, from)
			if t != "" and not cbs._prov_cond("is_core", t, pid, root, from) == true:
				var cl: Array = p.get("claims", [])
				if not (t in cl):
					cl.append(t)
				p["claims"] = cl
		"remove_claim":
			p.get("claims", []).erase(_who(v, scope, prev, root, from))
		"change_religion":
			var o := _who(v, scope, prev, root, from)
			map.set_religion_of(pid, str(map.countries[o]["religion"]) if o != "" else str(v))
		"change_culture":
			var o := _who(v, scope, prev, root, from)
			p["culture"] = str(map.countries[o]["primary_culture"]) if o != "" else str(v)
			map.refresh_colors()
		"add_base_tax", "add_base_production", "add_base_manpower":
			var f := k.trim_prefix("add_")
			var add := int(n)
			p[f] = int(p.get(f, 0)) + add
			p["development"] = int(p["development"]) + add
			map.owner_version += 1
			if economy:
				economy._recount()
		"set_in_empire":
			p["hre"] = str(v) == "yes"
		"cede_province", "add_territorial_core":
			var t := _who(v, scope, prev, root, from) if k == "cede_province" else str(p["owner"])
			if k == "cede_province" and t != "":
				map.set_owner_of(pid, t)
			elif t != "":
				_province_effect("add_core", t, pid, scope, prev, root, from)
		_:
			return false
	return true


func _change_tag(key: String, new_tag: String) -> void:
	var old := current_tag(key)
	if old == new_tag:
		return
	if not former.has(key):
		former[key] = []
	if not (old in former[key]):
		former[key].append(old)
	formed[key] = new_tag
	var c: Dictionary = map.countries[key]
	c["name"] = Loc.t(new_tag, new_tag)
	var file := str(Eu4Data.merged("common/country_tags").get(new_tag, ""))      # "countries/Scandinavia.txt"
	var def: Variant = Eu4Data.folder("common/countries").get(file.get_file().get_basename()) if file != "" else null
	if def is Array:
		for kv in def:
			if kv[0] == "color" and kv[1] is Array and kv[1].size() >= 3:
				c["color"] = [int(_num(kv[1][0][1])), int(_num(kv[1][1][1])), int(_num(kv[1][2][1]))]
	var ideas := _national_ideas_of(new_tag)
	if ideas != "":
		c["ideas"] = ideas
	map.owner_version += 1             # nomes no mapa, caches por país
	_recolor()
	power.invalidate(key)


## Conjunto de ideias nacionais cujo trigger pede `tag` (common/ideas), acrescentado ao MonarchPower.
func _national_ideas_of(tag: String) -> String:
	var all := Eu4Data.merged("common/ideas")
	for id in all:
		var tree: Variant = all[id]
		if not (tree is Array):
			continue
		var trig: Variant = null
		for kv in tree:
			if kv[0] == "trigger":
				trig = kv[1]
		if not (trig is Array) or not JSON.stringify(trig).contains("[\"tag\",\"%s\"]" % tag):
			continue
		if power.national_ideas.has(id):
			return id
		var nat := {"id": id, "name": Loc.t(id, Eu4Importer.pretty_key(id)), "start": {}, "bonus": {}, "ideas": []}
		for kv in tree:
			if not (kv[1] is Array):
				continue
			var mods := {}
			for m in kv[1]:
				if str(m[1]).is_valid_float():
					mods[str(m[0])] = float(str(m[1]))
			if kv[0] == "start" or kv[0] == "bonus":
				nat[kv[0]] = mods
			elif not (kv[0] in IDEA_SKIP):
				nat["ideas"].append({"id": kv[0], "name": Loc.t(kv[0], Eu4Importer.pretty_key(kv[0])), "modifiers": mods})
		power.national_ideas[id] = nat
		return id
	return ""


func _recolor() -> void:
	map.refresh_colors()


func _changed(tag: String) -> void:
	if tag == power.player:
		changed.emit(tag)
		power.notify(tag)


# ------------------------------------------------------------------ dica
## Linhas legíveis com o que o bloco faz (para a dica e a confirmação). Os ramos de if só aparecem se
## a condição vale agora; hidden_effect não aparece (como no EU4).
func describe(tree: Array, root: String, from := "") -> Array:
	var out := []
	_desc(tree, {"tag": root}, root, from if from != "" else root, out, 0)
	return out


func _desc(items: Array, scope: Dictionary, root: String, from: String, out: Array, depth: int) -> void:
	var chain_done := false
	var pad := "  ".repeat(depth)
	for it in items:
		var k := str(it[0])
		var v: Variant = it[1]
		match k:
			"if", "else_if":
				if k == "if" or not chain_done:
					chain_done = v is Array and _limit(v, scope, root, from)
					if chain_done:
						_desc(_without_limit(v), scope, root, from, out, depth)
				continue
			"else":
				if not chain_done and v is Array:
					_desc(v, scope, root, from, out, depth)
				chain_done = true
				continue
		chain_done = false
		var line := _line(k, v, scope, root, from)
		if line != "":
			out.append(pad + line)
		elif v is Array and (k in ITER or k == "capital_scope" or map.areas.has(k) or map.regions.has(k) \
				or map.superregions.has(k) or k in ["ROOT", "FROM", "owner"]):
			var sub := []
			_desc(_without_limit(v), scope, root, from, sub, depth + 1)
			if not sub.is_empty():
				out.append(pad + _scope_name(k) + ":")
				out.append_array(sub)


func _scope_name(k: String) -> String:
	match k:
		"every_owned_province":
			return Loc.s("Todas as províncias próprias (que cumprem)", "Every owned province (that matches)")
		"capital_scope":
			return Loc.s("Capital", "Capital")
		"random_owned_province":
			return Loc.s("Uma província própria", "A random owned province")
	return Loc.t(k, Eu4Importer.pretty_key(k))


func _line(k: String, v: Variant, scope: Dictionary, root: String, from: String) -> String:
	var s := str(v)
	var n := _num(v)
	match k:
		"add_prestige":
			return Loc.s("Prestígio %s", "Prestige %s") % _sg(n)
		"add_stability":
			return Loc.s("Estabilidade %+d", "Stability %+d") % int(n)
		"add_treasury":
			return Loc.s("Tesouro %s ducados", "Treasury %s ducats") % _sg(n)
		"add_years_of_income":
			return Loc.s("Tesouro %s anos de renda", "Treasury %s years of income") % _sg(n)
		"add_adm_power", "add_dip_power", "add_mil_power":
			return "%s %+d" % [k.substr(4, 3).to_upper(), int(n)]
		"add_legitimacy":
			return Loc.s("Legitimidade %s", "Legitimacy %s") % _sg(n)
		"add_republican_tradition":
			return Loc.s("Tradição republicana %s", "Republican tradition %s") % _sg(n)
		"add_devotion":
			return Loc.s("Devoção %s", "Devotion %s") % _sg(n)
		"change_tag":
			return Loc.s("O país passa a ser %s", "Country becomes %s") % Loc.t(s, s)
		"set_government_rank":
			return Loc.s("Posto do governo: %d", "Government rank: %d") % int(n)
		"add_country_modifier":
			var name := ""
			var dur := -1
			for kv in v if v is Array else []:
				if kv[0] == "name":
					name = str(kv[1])
				elif kv[0] == "duration":
					dur = int(_num(kv[1]))
			var mods := mod_def(name)
			var txt := Loc.s("Modificador «%s»", "Modifier \"%s\"") % Loc.t(name, Eu4Importer.pretty_key(name))
			if dur >= 0:
				txt += Loc.s(" por %d dias", " for %d days") % dur
			var parts := []
			for m in mods:
				parts.append("%s %s" % [Loc.modifier(m, Eu4Importer.pretty_key(m)), _sg(mods[m])])
			return txt + ((" (" + ", ".join(parts) + ")") if not parts.is_empty() else "")
		"remove_country_modifier":
			return Loc.s("Perde o modificador «%s»", "Loses modifier \"%s\"") % Loc.t(s, Eu4Importer.pretty_key(s))
		"change_religion":
			return Loc.s("Religião: %s", "Religion: %s") % Loc.t(s, s)
		"change_primary_culture":
			return Loc.s("Cultura principal: %s", "Primary culture: %s") % Loc.t(s, s)
		"add_accepted_culture":
			return Loc.s("Aceita a cultura %s", "Accepts culture %s") % Loc.t(s, s)
		"add_permanent_claim", "add_claim":
			return Loc.s("Reivindicação para %s", "Claim for %s") % Loc.t(s, s)
		"add_core":
			return Loc.s("Núcleo para %s", "Core for %s") % Loc.t(s, s)
		"add_base_tax", "add_base_production", "add_base_manpower":
			return "%s %+d" % [Loc.t(k.trim_prefix("add_").to_upper(), Eu4Importer.pretty_key(k.trim_prefix("add_"))), int(n)]
		"set_capital":
			return Loc.s("Capital em %s", "Capital moves to %s") % (str(map.provinces[int(n)]["name"]) if int(n) > 0 and int(n) < map.provinces.size() else s)
		"override_country_name":
			return Loc.s("Nome do país: %s", "Country name: %s") % Loc.t(s, s)
		"change_government":
			return Loc.s("Governo: %s", "Government: %s") % Loc.t(s, s)
		"add_government_reform":
			return Loc.s("Reforma: %s", "Reform: %s") % Loc.t(s, s)
	return ""


static func _sg(n: float) -> String:
	return ("%+d" % int(n)) if n == floorf(n) else ("%+.2f" % n).replace(".", Loc.dec)
