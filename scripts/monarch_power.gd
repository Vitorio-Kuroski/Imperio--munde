class_name MonarchPower
extends RefCounted
## Pontos de monarca (administrativo, diplomático, militar) e o nível de tecnologia de cada país.
## Todo mês cada país ganha BASE_GAIN + a nota do governante em cada categoria (como no EU4).
## Os pontos pagam o próximo nível de cada árvore de tecnologia: custo base 600 × (1 + modificador
## do grupo tecnológico), +10% por ano pesquisado antes do ano da tecnologia.
## O jogador pesquisa pela janela de tecnologias; os outros países pesquisam sozinhos quando podem.

signal changed(tag: String)

const CATS := ["adm", "dip", "mil"]
const BASE_GAIN := 3
const START_POINTS := 50
const MAX_POINTS := 999
const BASE_TECH_COST := 600
const AHEAD_PENALTY := 0.10      # por ano antes do ano da tecnologia

var map: MapView
var clock: GameClock
var player := ""
var state := {}                  # tag -> {"points": {adm, dip, mil}, "tech": {adm, dip, mil}}


func setup(m: MapView, c: GameClock) -> void:
	map = m
	clock = c
	for tag in map.countries:
		var g: String = map.countries[tag].get("tech_group", "")
		var lvl := int(map.tech_groups[g]["start_level"]) if map.tech_groups.has(g) else 0
		state[tag] = {"points": {"adm": START_POINTS, "dip": START_POINTS, "mil": START_POINTS},
				"tech": {"adm": lvl, "dip": lvl, "mil": lvl}}
	clock.month_passed.connect(_on_month)


func points(tag: String, cat: String) -> int:
	return int(state[tag]["points"][cat]) if state.has(tag) else 0


func tech(tag: String, cat: String) -> int:
	return int(state[tag]["tech"][cat]) if state.has(tag) else 0


## Ganho mensal: base + nota do governante (adm/dip/mil).
func gain(tag: String, cat: String) -> int:
	var m: Dictionary = map.countries.get(tag, {}).get("monarch", {})
	return BASE_GAIN + int(m.get(cat, 0))


## Custo do próximo nível da árvore `cat` (-1 se não houver próximo).
func tech_cost(tag: String, cat: String) -> int:
	var techs: Array = map.technologies.get(cat, [])
	var nxt := tech(tag, cat) + 1
	if nxt >= techs.size():
		return -1
	var g: String = map.countries.get(tag, {}).get("tech_group", "")
	var mod := float(map.tech_groups[g]["cost_modifier"]) if map.tech_groups.has(g) else 0.0
	var ahead := maxi(0, int(techs[nxt]["year"]) - clock.year)
	return roundi(BASE_TECH_COST * (1.0 + mod) * (1.0 + AHEAD_PENALTY * ahead))


func can_research(tag: String, cat: String) -> bool:
	var c := tech_cost(tag, cat)
	return c >= 0 and points(tag, cat) >= c


func research(tag: String, cat: String) -> bool:
	if not can_research(tag, cat):
		return false
	state[tag]["points"][cat] -= tech_cost(tag, cat)
	state[tag]["tech"][cat] += 1
	changed.emit(tag)
	return true


func _on_month() -> void:
	for tag in state:
		for cat in CATS:
			state[tag]["points"][cat] = mini(MAX_POINTS, points(tag, cat) + gain(tag, cat))
		if tag != player and not map.technologies.is_empty():
			for cat in CATS:        # IA simples: pesquisa assim que tiver pontos
				research(tag, cat)
	changed.emit(player)
