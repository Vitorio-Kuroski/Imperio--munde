class_name Combat
extends RefCounted
## Batalhas terrestres, regras do EU4 (constantes do common/defines.lua):
##  - Começa quando exércitos de países em guerra (`War.hostile`) estão parados ou chegam à mesma
##    província (os que estão em retirada não lutam). Atacante = o lado que chegou por último.
##  - Cada lado põe na linha de frente até a largura de combate (BASE_COMBAT_WIDTH 15 + combat_width
##    das tecnologias, máx. MAX_COMBAT_WIDTH 40): infantaria, depois cavalaria, depois artilharia; a
##    artilharia que sobra fica atrás e atira com metade do dano.
##  - Fases de DAYS_PER_PHASE (3) dias: fogo, choque, fogo... Por dia cada lado rola um dado de
##    COMBAT_DICE_SIDE (10) faces; o atacante perde a defesa do terreno (colinas, montanhas...).
##  - Cada regimento da frente bate no da frente inimiga à sua frente: baixas (homens) = (15 + 5 ×
##    (dado + pip ofensivo da fase − pip defensivo do alvo)) × valor da tecnologia para o tipo e a
##    fase (infantry_fire, cavalry_shock...) × força do regimento × (1 + WAR_LENGTH_DAMAGE_MODIFIER ×
##    dia) × (1 + discipline); dano de moral no alvo = baixas ÷ 540 × moral máxima do atacante. Todo
##    regimento na frente perde BATTLE_DAILY_MORALE_DAMAGE (1%) da moral máxima por dia.
##  - Um lado perde quando a frente fica sem moral ou sem homens; se tinha OVERRUN_FACTOR (10) vezes
##    menos homens, é aniquilado no 1º dia. Quem perde recua (`Army.retreat`); o vencedor ganha
##    prestígio (até PRESTIGE_FROM_LAND = 10) e placar na guerra.
##  - Ainda sem generais, travessia de rios, flancos e reserva.

signal battle_started(pid: int)
signal battle_ended(info: Dictionary)   # {pid, name, winner, loser, attacker_won, losses: [atac., def.], ...}

var map: MapView
var clock: GameClock
var power: MonarchPower
var army: Army
var war: War
var prestige: Prestige
var battles := {}                 # pid -> {pid, sides: [[ids], [ids]], day, start_men, losses, rolls, phase}
var _rules := {}
var _rng := RandomNumberGenerator.new()


func setup(m: MapView, c: GameClock, pw: MonarchPower, a: Army, w: War, pr: Prestige) -> void:
	map = m
	clock = c
	power = pw
	army = a
	war = w
	prestige = pr
	_rules = map.trade_rules
	_rng.randomize()
	army.combat = self
	clock.day_passed.connect(_on_day)


func _rule(k: String, d: float) -> float:
	return float(_rules.get(k, d))


func in_battle(id: int) -> bool:
	var a: Dictionary = army.armies.get(id, {})
	return not a.is_empty() and battles.has(int(a["loc"])) and (id in battles[int(a["loc"])]["sides"][0] \
			or id in battles[int(a["loc"])]["sides"][1])


## Valor somado de uma chave nas tecnologias militares já pesquisadas (infantry_fire, combat_width...).
func tech_value(tag: String, key: String) -> float:
	var lvl := TechWindow.level_of(map, tag, "mil", power)
	var s := 0.0
	var techs: Array = map.technologies.get("mil", [])
	for i in mini(lvl + 1, techs.size()):
		s += float(techs[i].get("modifiers", {}).get(key, 0.0))
	return s


func width(tag: String) -> int:
	return int(minf(_rule("max_combat_width", 40), _rule("base_combat_width", 15) + tech_value(tag, "combat_width")))


func _terrain_defence(pid: int) -> int:
	var t: Dictionary = map.terrains.get(map.provinces[pid].get("terrain", ""), {})
	return int(t.get("defence", 0))


# ------------------------------------------------------------------ início
func _start_battles() -> void:
	var by_loc := {}
	for a in army.armies.values():
		if a.get("retreat", false) or not a["path"].is_empty() and int(a["days"]) > 0:
			continue
		var pid := int(a["loc"])
		if not by_loc.has(pid):
			by_loc[pid] = []
		by_loc[pid].append(a)
	for pid in by_loc:
		var list: Array = by_loc[pid]
		if battles.has(pid):
			_join(battles[pid], list)
			continue
		if list.size() < 2:
			continue
		# dois lados: os amigos do primeiro e os inimigos dele
		var first: String = list[0]["tag"]
		var s0 := []
		var s1 := []
		for a in list:
			if a["tag"] == first or not war.hostile(first, a["tag"]):
				if not _hostile_to_any(a["tag"], list, first):
					s0.append(a)
			elif war.hostile(first, a["tag"]):
				s1.append(a)
		if s0.is_empty() or s1.is_empty():
			continue
		# atacante = quem chegou por último
		var t0 := 0
		var t1 := 0
		for a in s0:
			t0 = maxi(t0, int(a.get("since", 0)))
		for a in s1:
			t1 = maxi(t1, int(a.get("since", 0)))
		var att := s0 if t0 >= t1 else s1
		var dfn := s1 if att == s0 else s0
		var b := {"pid": pid, "sides": [att.map(func(a): return int(a["id"])), dfn.map(func(a): return int(a["id"]))],
				"day": 0, "start_men": [_men(att), _men(dfn)], "losses": [0.0, 0.0], "rolls": [0, 0], "phase": "fire",
				"tags": [att[0]["tag"], dfn[0]["tag"]]}
		battles[pid] = b
		for a in att + dfn:
			a["path"] = []                # quem está em batalha para
		battle_started.emit(pid)


func _hostile_to_any(tag: String, list: Array, first: String) -> bool:
	return false if tag == first else war.hostile(tag, first)


func _join(b: Dictionary, list: Array) -> void:
	for a in list:
		var id := int(a["id"])
		if id in b["sides"][0] or id in b["sides"][1] or a.get("retreat", false):
			continue
		for s in 2:
			if not war.hostile(a["tag"], b["tags"][s]) and war.hostile(a["tag"], b["tags"][1 - s]):
				b["sides"][s].append(id)
				a["path"] = []
				break


func _men(list: Array) -> float:
	var s := 0.0
	for a in list:
		s += army.strength(a)
	return s


# ------------------------------------------------------------------ dia de batalha
func _on_day() -> void:
	_start_battles()
	for pid in battles.keys():
		_step(battles[pid])


## Regimentos de um lado: [[reg, tag, unidade], ...] dos exércitos que ainda existem.
func _regs(ids: Array) -> Array:
	var out := []
	for id in ids:
		var a: Dictionary = army.armies.get(id, {})
		if a.is_empty():
			continue
		for r in a["regs"]:
			if float(r["str"]) > 0.0 and float(r.get("morale", 0.0)) > 0.0:
				out.append([r, a["tag"], map.units.get(r["unit"], {})])
	return out


## Linha de frente (até a largura) e artilharia de trás.
func _deploy(regs: Array, w: int) -> Array:
	var front := []
	var back := []
	for ty in Army.TYPES:
		for x in regs:
			if x[0]["type"] != ty:
				continue
			if front.size() < w:
				front.append(x)
			elif ty == "artillery":
				back.append(x)
	return [front, back]


func _step(b: Dictionary) -> void:
	var day := int(b["day"])
	var phase := "fire" if (day / int(_rule("days_per_phase", 3))) % 2 == 0 else "shock"
	b["phase"] = phase
	var regs := [_regs(b["sides"][0]), _regs(b["sides"][1])]
	if regs[0].is_empty() or regs[1].is_empty():
		_end(b, 1 if regs[0].is_empty() else 0)
		return
	var dice := int(_rule("combat_dice_side", 10))
	var rolls := [_rng.randi_range(0, dice - 1), _rng.randi_range(0, dice - 1)]
	b["rolls"] = rolls.duplicate()
	var terr := _terrain_defence(int(b["pid"]))
	var lines := []
	for s in 2:
		var tag: String = b["tags"][s]
		lines.append(_deploy(regs[s], width(tag)))
	# dano dos dois lados ao mesmo tempo
	var hits := [[], []]               # por lado: [[reg_alvo, homens, moral], ...]
	for s in 2:
		var o := 1 - s
		var front_o: Array = lines[o][0]
		if front_o.is_empty():
			continue
		var roll := int(rolls[s]) - (terr if s == 0 else 0)
		var shooters: Array = lines[s][0] + lines[s][1]
		for i in shooters.size():
			var x: Array = shooters[i]
			var r: Dictionary = x[0]
			var tag: String = x[1]
			var u: Dictionary = x[2]
			var tgt: Array = front_o[i % front_o.size()]
			var pip := int(u.get("offensive_" + phase, 0)) - int(tgt[2].get("defensive_" + phase, 0))
			var base := maxf(0.0, 15.0 + 5.0 * float(roll + pip))
			var mult := tech_value(tag, str(r["type"]) + "_" + phase)
			if i >= lines[s][0].size():
				mult *= 0.5                  # artilharia de trás
			var men := base * mult * float(r["str"]) * (1.0 + _rule("war_length_damage_modifier", 0.01) * day) \
					* maxf(0.0, 1.0 + power.modifier(tag, "discipline"))
			hits[o].append([tgt[0], men, men / 540.0 * army.max_morale(tag)])
	for s in 2:
		for h in hits[s]:
			var r: Dictionary = h[0]
			var lost := minf(float(r["str"]) * 1000.0, float(h[1]))
			r["str"] = float(r["str"]) - lost / 1000.0
			r["morale"] = float(r.get("morale", 0.0)) - float(h[2])
			b["losses"][s] = float(b["losses"][s]) + lost
		for x in lines[s][0]:
			x[0]["morale"] = float(x[0].get("morale", 0.0)) - _rule("battle_daily_morale_damage", 0.01) * army.max_morale(x[1])
	b["day"] = day + 1
	# regimentos sem homens somem
	for s in 2:
		for id in b["sides"][s]:
			var a: Dictionary = army.armies.get(id, {})
			if not a.is_empty():
				a["regs"] = a["regs"].filter(func(r): return float(r["str"]) > 0.001)
	army.mark_dirty()
	var alive := [_regs(b["sides"][0]).size(), _regs(b["sides"][1]).size()]
	var men := [_men_ids(b["sides"][0]), _men_ids(b["sides"][1])]
	var over := _rule("overrun_factor", 10)
	if alive[0] == 0 or alive[1] == 0:
		_end(b, 1 if alive[0] == 0 else 0)
	elif day == 0 and men[0] >= men[1] * over:
		_end(b, 0, true)
	elif day == 0 and men[1] >= men[0] * over:
		_end(b, 1, true)


func _men_ids(ids: Array) -> float:
	var s := 0.0
	for id in ids:
		var a: Dictionary = army.armies.get(id, {})
		if not a.is_empty():
			s += army.strength(a)
	return s


## Fim da batalha: `w` = lado vencedor (0 atacante, 1 defensor).
func _end(b: Dictionary, w: int, overrun := false) -> void:
	var pid := int(b["pid"])
	battles.erase(pid)
	var l := 1 - w
	var wt: String = b["tags"][w]
	var lt: String = b["tags"][l]
	var losses: Array = b["losses"]
	for id in b["sides"][l]:
		var a: Dictionary = army.armies.get(id, {})
		if a.is_empty():
			continue
		if overrun or a["regs"].is_empty():
			army.disband(id)
		else:
			army.retreat(id)
	for id in b["sides"][w]:
		var a: Dictionary = army.armies.get(id, {})
		if not a.is_empty() and a["regs"].is_empty():
			army.disband(id)
	var enemy_k := float(losses[l]) / 1000.0
	if prestige:
		var gain := minf(_rule("prestige_from_land", 10), enemy_k / 2.0)
		prestige.add(wt, gain)
		prestige.add(lt, -gain / 2.0)
	war.add_battle(wt, lt, enemy_k)
	army.moved.emit()
	battle_ended.emit({"pid": pid, "name": map.provinces[pid]["name"], "winner": wt, "loser": lt,
			"attacker_won": w == 0, "losses": losses, "overrun": overrun, "tags": b["tags"], "days": b["day"]})
