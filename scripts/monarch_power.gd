class_name MonarchPower
extends RefCounted
## Pontos de monarca (administrativo, diplomático, militar) e o nível de tecnologia de cada país.
## Todo mês cada país ganha BASE_GAIN + a nota do governante em cada categoria (como no EU4).
## Os pontos pagam o próximo nível de cada árvore de tecnologia: custo base 600 × (1 + modificador
## do grupo tecnológico), +10% por ano pesquisado antes do ano da tecnologia.
## O jogador pesquisa pela janela de tecnologias; os outros países pesquisam sozinhos quando podem.
## Ideias: cada grupo adotado (vagas = allowed_idea_groups das tecnologias adm) tem 7 ideias de
## IDEA_COST pontos da categoria do grupo; a cada 3 ideias de grupo o país libera 1 ideia nacional.
## Os efeitos das ideias somam em modifier(); por enquanto só os custos de tecnologia e de ideias
## são aplicados (o resto entra quando houver economia e exércitos).

signal changed(tag: String)

const CATS := ["adm", "dip", "mil"]
const BASE_GAIN := 3
const START_POINTS := 50
const MAX_POINTS := 999
const BASE_TECH_COST := 600
const AHEAD_PENALTY := 0.10      # por ano antes do ano da tecnologia
const IDEA_COST := 400
const AI_IDEA_RESERVE := 900     # a IA só compra ideias com os pontos quase no máximo

var map: MapView
var clock: GameClock
var player := ""
var state := {}                  # tag -> {"points", "tech", "groups": [{"id", "n"}]}
var idea_groups := {}            # id -> grupo (map.idea_groups)
var national_ideas := {}         # id -> conjunto (map.national_ideas)
var _mods_cache := {}            # tag -> modificadores somados
var _slots_at := PackedInt32Array() # vagas de grupos de ideias por nível adm (acumulado)
var advisors: Advisors           # conselheiros somam nível aos pontos e efeitos aos modificadores
var institutions: Institutions   # instituições não adotadas encarecem tecnologias; adotadas dão bônus
var economy: Economy             # falência encarece tecnologias, ideias e conselheiros


func setup(m: MapView, c: GameClock) -> void:
	map = m
	clock = c
	for g in map.idea_groups:
		idea_groups[g["id"]] = g
	for g in map.national_ideas:
		national_ideas[g["id"]] = g
	var acc := 0
	for t in map.technologies.get("adm", []):
		# no EU4 allowed_idea_groups é o total de vagas naquele nível (1, 2, 3...), não um acréscimo
		acc = maxi(acc, int(t.get("modifiers", {}).get("allowed_idea_groups", 0)))
		_slots_at.append(acc)
	for tag in map.countries:
		var g: String = map.countries[tag].get("tech_group", "")
		var lvl := int(map.tech_groups[g]["start_level"]) if map.tech_groups.has(g) else 0
		state[tag] = {"points": {"adm": START_POINTS, "dip": START_POINTS, "mil": START_POINTS},
				"tech": {"adm": lvl, "dip": lvl, "mil": lvl}, "groups": []}
	clock.month_passed.connect(_on_month)


func points(tag: String, cat: String) -> int:
	return int(state[tag]["points"][cat]) if state.has(tag) else 0


func tech(tag: String, cat: String) -> int:
	return int(state[tag]["tech"][cat]) if state.has(tag) else 0


## Ganho mensal: base + nota do governante + nível do conselheiro (adm/dip/mil).
func gain(tag: String, cat: String) -> int:
	var m: Dictionary = map.countries.get(tag, {}).get("monarch", {})
	return BASE_GAIN + int(m.get(cat, 0)) + (advisors.skill(tag, cat) if advisors else 0)


## Esquece a soma de efeitos guardada (ideias ou conselheiros mudaram).
func invalidate(tag: String) -> void:
	_mods_cache.erase(tag)
	if economy:
		economy.invalidate(tag)


## Avisa a interface que os pontos do país mudaram (só para o jogador).
func notify(tag: String) -> void:
	if tag == player:
		changed.emit(tag)


## Custo do próximo nível da árvore `cat` (-1 se não houver próximo).
func tech_cost(tag: String, cat: String) -> int:
	var techs: Array = map.technologies.get(cat, [])
	var nxt := tech(tag, cat) + 1
	if nxt >= techs.size():
		return -1
	var g: String = map.countries.get(tag, {}).get("tech_group", "")
	var mod := float(map.tech_groups[g]["cost_modifier"]) if map.tech_groups.has(g) else 0.0
	var ahead := maxi(0, int(techs[nxt]["year"]) - clock.year)
	var ideas_mod := modifier(tag, "technology_cost") + modifier(tag, cat + "_tech_cost_modifier")
	var inst_pen := institutions.tech_penalty(tag, techs[nxt]) if institutions else 0.0
	return roundi(BASE_TECH_COST * (1.0 + mod) * (1.0 + AHEAD_PENALTY * ahead) * maxf(0.1, 1.0 + ideas_mod)
			* (1.0 + inst_pen))


func can_research(tag: String, cat: String) -> bool:
	var c := tech_cost(tag, cat)
	return c >= 0 and points(tag, cat) >= c


func research(tag: String, cat: String) -> bool:
	var c := tech_cost(tag, cat)
	if c < 0 or points(tag, cat) < c:
		return false
	state[tag]["points"][cat] -= c
	state[tag]["tech"][cat] += 1
	_mods_cache.erase(tag)
	if tag == player:
		changed.emit(tag)
	return true


# ------------------------------------------------------------------ ideias
## Vagas de grupos de ideias: allowed_idea_groups da tecnologia adm mais alta já pesquisada (é um total).
func idea_slots(tag: String) -> int:
	if _slots_at.is_empty():
		return 0
	return _slots_at[clampi(tech(tag, "adm"), 0, _slots_at.size() - 1)]


func adopted(tag: String) -> Array:
	return state[tag]["groups"] if state.has(tag) else []


func ideas_in(tag: String, gid: String) -> int:
	for g in adopted(tag):
		if g["id"] == gid:
			return int(g["n"])
	return -1                    # não adotado


## Ideias nacionais liberadas: 1 a cada 3 ideias de grupo compradas (máximo 7).
func national_unlocked(tag: String) -> int:
	var total := 0
	for g in adopted(tag):
		total += int(g["n"])
	return mini(7, total / 3)


func idea_cost(tag: String) -> int:
	return roundi(IDEA_COST * maxf(0.1, 1.0 + modifier(tag, "idea_cost")))


func can_adopt(tag: String, gid: String) -> bool:
	return idea_groups.has(gid) and not idea_groups[gid].get("restricted", false) and ideas_in(tag, gid) < 0 \
			and adopted(tag).size() < idea_slots(tag)


func adopt(tag: String, gid: String) -> bool:
	if not can_adopt(tag, gid):
		return false
	state[tag]["groups"].append({"id": gid, "n": 0})
	if tag == player:
		changed.emit(tag)
	return true


func can_buy_idea(tag: String, gid: String) -> bool:
	var n := ideas_in(tag, gid)
	if n < 0 or n >= idea_groups[gid]["ideas"].size():
		return false
	return points(tag, idea_groups[gid]["category"]) >= idea_cost(tag)


func buy_idea(tag: String, gid: String) -> bool:
	if not can_buy_idea(tag, gid):
		return false
	state[tag]["points"][idea_groups[gid]["category"]] -= idea_cost(tag)
	for g in adopted(tag):
		if g["id"] == gid:
			g["n"] += 1
	_mods_cache.erase(tag)
	if tag == player:
		changed.emit(tag)
	return true


## Soma de um efeito das ideias do país (tradições, ideias liberadas e bônus completos).
func modifier(tag: String, key: String) -> float:
	if not _mods_cache.has(tag):
		_mods_cache[tag] = _sum_mods(tag)
	return float(_mods_cache[tag].get(key, 0.0))


func all_modifiers(tag: String) -> Dictionary:
	if not _mods_cache.has(tag):
		_mods_cache[tag] = _sum_mods(tag)
	return _mods_cache[tag]


func _sum_mods(tag: String) -> Dictionary:
	var out := {}
	var add := func(d: Dictionary):
		for k in d:
			if d[k] is float or d[k] is int:
				out[k] = float(out.get(k, 0.0)) + float(d[k])
	var nat: Dictionary = national_ideas.get(map.countries.get(tag, {}).get("ideas", ""), {})
	if not nat.is_empty():
		add.call(nat["start"])
		var un := national_unlocked(tag)
		for i in mini(un, nat["ideas"].size()):
			add.call(nat["ideas"][i]["modifiers"])
		if un >= nat["ideas"].size():
			add.call(nat["bonus"])
	for g in adopted(tag):
		var grp: Dictionary = idea_groups[g["id"]]
		for i in mini(int(g["n"]), grp["ideas"].size()):
			add.call(grp["ideas"][i]["modifiers"])
		if int(g["n"]) >= grp["ideas"].size():
			add.call(grp["bonus"])
	if advisors:
		add.call(advisors.modifiers(tag))
	if institutions:
		add.call(institutions.modifiers(tag))
	if economy:
		add.call(economy.modifiers(tag))
	return out


## IA: adota um grupo da categoria do maior talento do governante e compra ideias com sobra de pontos.
func _ai_ideas(tag: String) -> void:
	if idea_groups.is_empty():
		return
	var slots := idea_slots(tag)
	if slots == 0:
		return
	if adopted(tag).size() < slots:
		var m: Dictionary = map.countries.get(tag, {}).get("monarch", {})
		var best := "adm"
		for cat in CATS:
			if int(m.get(cat, 0)) > int(m.get(best, 0)):
				best = cat
		for gid in idea_groups:
			if idea_groups[gid].get("category", "") == best and can_adopt(tag, gid):
				adopt(tag, gid)
				break
	for g in adopted(tag):
		var cat: String = idea_groups[g["id"]]["category"]
		if points(tag, cat) >= AI_IDEA_RESERVE:
			buy_idea(tag, g["id"])


func _on_month() -> void:
	for tag in state:
		for cat in CATS:
			state[tag]["points"][cat] = mini(MAX_POINTS, points(tag, cat) + gain(tag, cat))
		if tag != player and not map.technologies.is_empty():
			for cat in CATS:        # IA simples: pesquisa assim que tiver pontos
				if points(tag, cat) >= 200:   # nenhuma tecnologia custa menos que isso
					research(tag, cat)
			_ai_ideas(tag)
	changed.emit(player)
