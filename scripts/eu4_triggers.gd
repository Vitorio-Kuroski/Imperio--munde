class_name Eu4Triggers
extends RefCounted
## Requisitos (blocos de condição do EU4: allow, potential...) em texto, como a dica do EU4: uma
## linha por condição com ✓/✗ (? = o jogo ainda não sabe avaliar), blocos OR/NOT/escopos com recuo.
## Usa as frases da localização do EU4 quando existem (OWNS, OWNS_CORE_PROVINCE, IS_SUBJECT,
## EXISTS, IS_NOT_GREAT_POWER...) e, para o que o motor do EU4 monta sozinho, o mesmo jeito de
## escrever ("Stability is at least 1", "Administrative technology is at least 10"...), em inglês
## com a localização do EU4 ou em português sem ela. O que não conhece fica "chave = valor".

var map: MapView
var cbs: CasusBelli


func _init(m: MapView, c: CasusBelli) -> void:
	map = m
	cbs = c


## Linhas do bloco (recuo de 2 espaços por nível). `root` = país avaliado; `mark` = mostrar ✓/✗.
func describe(tree: Array, root: String, depth := 0, mark := true) -> Array:
	var out := []
	for kv in tree:
		out.append_array(_one(kv, root, depth, mark))
	return out


func text(tree: Array, root: String) -> String:
	return "\n".join(describe(tree, root))


func _mark(kv: Array, root: String, mark: bool) -> String:
	if not mark or cbs == null:
		return ""
	var r: Variant = cbs.check([kv], root, root)
	return "✓ " if r == true else ("✗ " if r == false else "? ")


func _pad(depth: int) -> String:
	return "  ".repeat(depth)


func _one(kv: Array, root: String, depth: int, mark: bool) -> Array:
	var k: String = str(kv[0])
	var v = kv[1]
	var p := _pad(depth)
	match k:
		"AND":
			if v is Array:
				return describe(v, root, depth, mark)
		"OR":
			if v is Array:
				return [p + _mark(kv, root, mark) + _s("Uma destas:", "One of the following must be true:")] + describe(v, root, depth + 1, mark)
		"NOT":
			if v is Array:
				if v.size() == 1 and not (v[0][1] is Array):
					return [p + _mark(kv, root, mark) + _phrase(str(v[0][0]), v[0][1], true)]
				return [p + _mark(kv, root, mark) + _s("Nenhuma destas:", "None of the following must be true:")] + describe(v, root, depth + 1, false)
		"custom_trigger_tooltip":
			if v is Array:
				var tip := ""
				var rest := []
				for x in v:
					if x[0] == "tooltip":
						tip = Loc.t(str(x[1]), "")
					else:
						rest.append(x)
				if tip != "":
					return [p + _mark(kv, root, mark) + tip]
				return describe(rest, root, depth, mark)
		"tooltip", "custom_tooltip":
			return []
		"if":
			if v is Array:              # só vale o que está dentro quando o limit vale
				var lim: Array = []
				var rest := []
				for x in v:
					if x[0] == "limit" and x[1] is Array:
						lim = x[1]
					else:
						rest.append(x)
				if cbs and cbs.check(lim, root, root) == true:
					return describe(rest, root, depth, mark)
				return []
		"else", "else_if":
			return []
		"capital_scope":
			if v is Array:
				return [p + _mark(kv, root, mark) + _s("Capital:", "Capital:")] + describe(v, root, depth + 1, false)
		"num_of_owned_provinces_with", "any_owned_province", "all_owned_province":
			if v is Array:
				var n := 1
				var rest := []
				for x in v:
					if x[0] == "value":
						n = int(str(x[1]).to_float())
					else:
						rest.append(x)
				var head := _s("Possui ao menos %d províncias com:", "Owns at least %d provinces that:") % n if k == "num_of_owned_provinces_with" \
						else (_s("Alguma província própria:", "Any owned province:") if k == "any_owned_province" else _s("Todas as províncias próprias:", "All owned provinces:"))
				return [p + _mark(kv, root, mark) + head] + describe(rest, root, depth + 1, false)
	if v is Array:                   # escopo desconhecido (tag, região, província...)
		return [p + _mark(kv, root, mark) + _scope_name(k) + ":"] + describe(v, root, depth + 1, false)
	return [p + _mark(kv, root, mark) + _phrase(k, v, false)]


func _scope_name(k: String) -> String:
	if map.countries.has(k):
		return str(map.countries[k]["name"])
	if k.is_valid_int() and int(k) < map.provinces.size():
		return str(map.provinces[int(k)]["name"])
	if map.regions.has(k):
		return str(map.regions[k]["name"])
	if map.areas.has(k):
		return str(map.areas[k]["name"])
	return Loc.t(k, Eu4Importer.pretty_key(k))


func _country(t: String) -> String:
	return str(map.countries.get(t, {}).get("name", Loc.t(t, t)))


func _prov(id: String) -> String:
	if id.is_valid_int() and int(id) >= 0 and int(id) < map.provinces.size():
		return str(map.provinces[int(id)]["name"])
	return id


func _s(pt: String, en: String) -> String:
	return Loc.s(pt, en)


## Frase de uma condição simples (`neg` = dentro de um NOT de uma condição só).
func _phrase(k: String, v: Variant, neg: bool) -> String:
	var s := str(v)
	var yes := s == "yes"
	var no := s == "no"
	var t := ""
	match k:
		"owns_core_province":
			t = Loc.t("OWNS_CORE_PROVINCE", "Possui a província núcleo:").strip_edges() + " " + _prov(s)
		"owns":
			t = Loc.t("OWNS", "Possui").strip_edges() + " " + _prov(s)
		"is_core":
			t = _s("É núcleo de %s", "Is core of %s") % _country(s)
		"owned_by":
			t = _s("Pertence a %s", "Owned by %s") % _country(s)
		"is_at_war":
			t = (_s("Está em guerra", "Is at war") if yes else _s("Não está em guerra", "Is not at war"))
		"is_free_or_tributary_trigger":
			t = (_s("Não é súdito (ou é tributário)", "Is not a subject nation (or is a tributary)") if yes
					else _s("É súdito", "Is a subject nation"))
		"is_subject":
			t = Loc.t("IS_SUBJECT", "É um súdito") if yes else _s("Não é súdito", "Is not a subject nation")
		"is_subject_of":
			t = Loc.t("IS_SUBJECT_OF", "É súdito de").strip_edges() + " " + _country(s)
		"exists":
			t = (_s("Existe", "Exists") if yes else (_s("Não existe", "Does not exist") if no else _country(s) + Loc.t("EXISTS", " existe")))
		"tag":
			t = _s("É %s", "Is %s") % _country(s)
		"was_tag":
			t = _s("Já foi %s", "Has been %s") % _country(s)
		"stability":
			t = _s("Estabilidade de pelo menos %s", "Stability is at least %s") % s
		"prestige":
			t = _s("Prestígio de pelo menos %s", "Prestige is at least %s") % s
		"legitimacy":
			t = _s("Legitimidade de pelo menos %s", "Legitimacy is at least %s") % s
		"treasury":
			t = _s("Tesouro de pelo menos %s ducados", "Has at least %s ducats") % s
		"adm_tech":
			t = _s("Tecnologia administrativa de pelo menos %s", "Administrative technology is at least %s") % s
		"dip_tech":
			t = _s("Tecnologia diplomática de pelo menos %s", "Diplomatic technology is at least %s") % s
		"mil_tech":
			t = _s("Tecnologia militar de pelo menos %s", "Military technology is at least %s") % s
		"adm_power", "dip_power", "mil_power":
			var nm: String = {"adm_power": Loc.t("ADM_POWER", "poder administrativo"), "dip_power": Loc.t("DIP_POWER", "poder diplomático"),
					"mil_power": Loc.t("MIL_POWER", "poder militar")}[k]
			t = _s("Tem pelo menos %s de %s", "Has at least %s %s") % [s, nm]
		"army_professionalism":
			t = _s("Profissionalismo do exército de pelo menos %d%%", "Army Professionalism is at least %d%%") % roundi(s.to_float() * 100.0)
		"num_of_cities":
			t = _s("Possui pelo menos %s cidades", "Owns at least %s cities") % s
		"total_development":
			t = Loc.t("TOTAL_DEVELOPMENT", "Desenvolvimento total") + " ≥ " + s
		"religion":
			t = _s("Religião é %s", "Religion is %s") % str(map.religions.get(s, {}).get("name", Loc.t(s, s)))
		"religion_group":
			t = _s("Grupo religioso é %s", "Religion group is %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"primary_culture", "culture":
			t = _s("Cultura é %s", "Culture is %s") % str(map.cultures.get(s, {}).get("name", Loc.t(s, s)))
		"culture_group":
			t = _s("Grupo de cultura é %s", "Culture group is %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"government":
			t = _s("Governo é %s", "Government is %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"is_nomad":
			t = _s("É nômade", "Is a nomad") if yes else _s("Não é nômade", "Is not a nomad")
		"is_great_power":
			t = _s("É uma grande potência", "Is a Great Power") if yes else Loc.t("IS_NOT_GREAT_POWER", "Não é uma grande potência")
		"is_emperor":
			t = _s("É o imperador", "Is the Emperor") if yes else _s("Não é o imperador", "Is not the Emperor")
		"has_dlc":
			t = _s("Tem o DLC %s", "Has the %s DLC") % s
		"has_country_flag", "had_country_flag":
			t = _s("Tem a marca %s", "Has flag %s") % s
		"has_country_modifier":
			t = _s("Tem o modificador %s", "Has modifier %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"has_idea_group":
			t = _s("Adotou %s", "Has adopted %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"full_idea_group":
			t = _s("Completou %s", "Has completed %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"has_institution":
			t = _s("Adotou a instituição %s", "Has embraced %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		"region", "area", "continent", "superregion":
			t = _s("Fica em %s", "Is in %s") % _scope_name(s)
		"province_id":
			t = _prov(s)
		"is_city":
			t = _s("É uma cidade", "Is a city") if yes else _s("Não é uma cidade", "Is not a city")
		"is_state":
			t = _s("É um estado", "Is a state") if yes else _s("Não é um estado", "Is not a state")
		"has_regency":
			t = _s("Tem regência", "Has a regency") if yes else _s("Não tem regência", "Does not have a regency")
		"ai":
			t = _s("É controlado pela IA", "Is AI controlled") if yes else _s("É controlado por um jogador", "Is controlled by a player")
		"is_colonial_nation":
			t = _s("É uma nação colonial", "Is a colonial nation") if yes else _s("Não é uma nação colonial", "Is not a colonial nation")
		"normal_or_historical_nations":
			t = _s("Nações normais ou históricas", "Normal or historical nations")
		"was_never_end_game_tag_trigger":
			t = Loc.t("was_never_end_game_tag_trigger_tt", _s("Nunca foi uma nação do fim do jogo", "Was never an end-game nation"))
		_:
			var st: Variant = Eu4Data.merged("common/scripted_triggers").get(k)
			if st is Array:
				t = Loc.t(k + "_tt", Loc.t(k, Eu4Importer.pretty_key(k)))
			else:
				t = "%s = %s" % [Loc.t(k, k), Loc.t(s, s)]
	if neg:                          # NOT de uma condição só: a frase negada, como o EU4
		match k:
			"exists":
				return _country(s) + _s(" não existe", " does not exist") if not (yes or no) else t
			"tag":
				return _s("Não é %s", "Is not %s") % _country(s)
			"was_tag":
				return _s("Nunca foi %s", "Has never been %s") % _country(s)
			"owns", "owns_core_province":
				return _s("Não possui %s", "Does not own %s") % _prov(s)
			"religion":
				return _s("Religião não é %s", "Religion is not %s") % str(map.religions.get(s, {}).get("name", Loc.t(s, s)))
			"has_country_flag", "had_country_flag":
				return _s("Não tem a marca %s", "Does not have flag %s") % s
			"has_country_modifier":
				return _s("Não tem o modificador %s", "Does not have modifier %s") % Loc.t(s, Eu4Importer.pretty_key(s))
			"government":
				return _s("Governo não é %s", "Government is not %s") % Loc.t(s, Eu4Importer.pretty_key(s))
		t = _s("NÃO: ", "NOT: ") + t
	return t
