class_name Siege
extends RefCounted
## Cercos e ocupação, regras do EU4 (constantes do common/defines.lua):
##  - Nível do forte = fort_level das construções (fort_15th 2, fort_16th 4...) + 1 na capital
##    (modificador estático capital_city). Guarnição = GARRISON_SIZE (1000) × nível.
##  - Um exército parado (sem batalha, sem retirada) numa província controlada por um inimigo cerca
##    se tiver ao menos SIEGE_FORCE_NEEDED_MULTIPLIER (3) × a guarnição. Província sem forte é
##    ocupada em meia fase (15 dias).
##  - Com forte: a cada DAYS_PER_SIEGE_PHASE (30) dias rola 1–14 + situação do cerco + artilharia
##    (1 por regimento de artilharia ÷ nível do forte, até 5); com SIEGE_WIN (20) ou mais a província
##    cai. Senão o dado muda a situação como no EU4: 6–7 falta de suprimentos (SIEGE_BONUS_SUPPLIES_
##    SHORTAGE +1), 8–9 falta de comida (+2), 10–11 falta de água (+3), 12–13 deserção (+2), até
##    SIEGE_MEMORY (11). Uma batalha na província não desfaz o cerco.
##  - Ocupada, `War.controller[pid]` passa ao país do exército (a província de um aliado volta ao
##    dono). Província própria ocupada pelo inimigo é retomada do mesmo jeito.
##  - Ainda sem zona de controle, assalto, bloqueio naval e generais.

signal captured(pid: int, by: String, from: String)

var map: MapView
var clock: GameClock
var army: Army
var war: War
var sieges := {}                  # pid -> {tag, days, status, level}
var _rules := {}
var _rng := RandomNumberGenerator.new()


func setup(m: MapView, c: GameClock, a: Army, w: War) -> void:
	map = m
	clock = c
	army = a
	war = w
	_rules = map.trade_rules
	_rng.randomize()
	army.siege = self
	clock.day_passed.connect(_on_day)


func _rule(k: String, d: float) -> float:
	return float(_rules.get(k, d))


func fort_level(pid: int) -> int:
	var p: Dictionary = map.provinces[pid]
	var lvl := map.building_mod(p, "fort_level")
	var o: String = p["owner"]
	if o != "" and int(map.countries.get(o, {}).get("capital", -1)) == pid:
		lvl += float(_rules.get("statics", {}).get("capital_city", {}).get("fort_level", 1))
	return int(lvl)


func garrison(pid: int) -> float:     # em milhares
	return _rule("garrison_size", 1000) * fort_level(pid) / 1000.0


## Cerco em andamento na província (vazio se nenhum).
func siege_at(pid: int) -> Dictionary:
	return sieges.get(pid, {})


## Progresso da fase atual (0–1).
func phase_progress(pid: int) -> float:
	var s: Dictionary = sieges.get(pid, {})
	if s.is_empty():
		return 0.0
	var len := _rule("days_per_siege_phase", 30) * (0.5 if int(s["level"]) == 0 else 1.0)
	return fmod(float(s["days"]), len) / len


func _on_day() -> void:
	# exércitos que podem cercar, por província
	var by_loc := {}
	for a in army.armies.values():
		if not a["path"].is_empty() or a.get("retreat", false) or army.combat and army.combat.in_battle(int(a["id"])):
			continue
		var pid := int(a["loc"])
		var ctrl := war.controller_of(pid)
		if not war.hostile(a["tag"], ctrl):
			continue
		if not by_loc.has(pid):
			by_loc[pid] = []
		by_loc[pid].append(a)
	for pid in sieges.keys():
		if not by_loc.has(pid) and not (army.combat and army.combat.battles.has(pid)):
			sieges.erase(pid)            # o cerco acabou (saíram, perderam, paz)
	for pid in by_loc:
		if army.combat and army.combat.battles.has(pid):
			continue
		var list: Array = by_loc[pid]
		var tag: String = list[0]["tag"]
		var men := 0.0
		var art := 0
		for a in list:
			men += army.strength(a)
			art += army.count(a, "artillery")
		var lvl := fort_level(pid)
		if men < _rule("siege_force_needed_multiplier", 3) * garrison(pid):
			sieges.erase(pid)
			continue
		if not sieges.has(pid):
			sieges[pid] = {"tag": tag, "days": 0, "status": 0, "level": lvl, "last_roll": 0}
		var s: Dictionary = sieges[pid]
		s["days"] = int(s["days"]) + 1
		var phase := _rule("days_per_siege_phase", 30)
		if lvl == 0:
			if s["days"] >= phase * 0.5:
				_capture(pid, tag)
			continue
		if int(s["days"]) % int(phase) != 0:
			continue
		var roll := _rng.randi_range(1, 14)
		var bonus := mini(5, art / maxi(1, lvl))
		s["last_roll"] = roll
		if roll + int(s["status"]) + bonus >= int(_rule("siege_win", 20)):
			_capture(pid, tag)
		else:
			var add := 0
			if roll >= 12:
				add = int(_rule("siege_bonus_defenders_desert", 2))
			elif roll >= 10:
				add = int(_rule("siege_bonus_water_shortage", 3))
			elif roll >= 8:
				add = int(_rule("siege_bonus_food_shortage", 2))
			elif roll >= 6:
				add = int(_rule("siege_bonus_supplies_shortage", 1))
			s["status"] = mini(int(_rule("siege_memory", 11)), int(s["status"]) + add)


func _capture(pid: int, tag: String) -> void:
	sieges.erase(pid)
	var owner: String = map.provinces[pid]["owner"]
	var from := war.controller_of(pid)
	if owner == tag or not war.hostile(tag, owner):
		war.controller.erase(pid)           # volta ao dono (próprio ou aliado)
	else:
		war.controller[pid] = tag
	army.moved.emit()
	war.changed.emit()
	captured.emit(pid, tag, from)
