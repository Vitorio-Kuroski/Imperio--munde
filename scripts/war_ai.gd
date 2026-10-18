class_name WarAI
extends RefCounted
## IA dos exércitos em guerra (todos os países menos o jogador), a cada 5 dias, para cada exército
## parado (sem batalha, sem retirada, sem cerco em andamento):
##  1. ataca o exército inimigo mais perto em terra do seu lado se for até 1,2× mais fraco que ele;
##  2. senão retoma a província própria (ou de aliado) ocupada mais perto;
##  3. senão, se o seu lado não for muito mais fraco (≥ 0,8× os homens do inimigo), vai cercar a
##     província inimiga mais perto que ainda não ocupou, evitando exércitos muito mais fortes;
##  4. senão fica onde está.
## Não junta exércitos, não usa frota e não pede paz.

const EVERY_DAYS := 5
const CANDIDATES := 12            # quantas províncias mais perto testam o caminho

var map: MapView
var clock: GameClock
var power: MonarchPower
var army: Army
var war: War
var _tick := 0


func setup(m: MapView, c: GameClock, pw: MonarchPower, a: Army, w: War) -> void:
	map = m
	clock = c
	power = pw
	army = a
	war = w
	clock.day_passed.connect(_on_day)


func _on_day() -> void:
	_tick += 1
	if _tick % EVERY_DAYS != 0 or war.wars.is_empty():
		return
	var tags := {}
	for w in war.wars.values():
		for t in w["attackers"] + w["defenders"]:
			if t != power.player:
				tags[t] = true
	for t in tags:
		for a in army.armies_of(t):
			_think(a)


func _idle(a: Dictionary) -> bool:
	if not a["path"].is_empty() or a.get("retreat", false) or a["regs"].is_empty():
		return false
	if army.combat and army.combat.in_battle(int(a["id"])):
		return false
	var s: Dictionary = army.siege.siege_at(int(a["loc"])) if army.siege else {}
	return s.is_empty() or s["tag"] != a["tag"]


func _center(pid: int) -> Vector2:
	var c: Array = map.provinces[pid]["center"]
	return Vector2(c[0], c[1])


func _think(a: Dictionary) -> void:
	if not _idle(a):
		return
	var tag: String = a["tag"]
	var mine := army.strength(a)
	var here := _center(int(a["loc"]))
	var enemies := war.enemies_of(tag)
	var friends := {tag: true}
	for t in army.diplomacy.allies(tag):
		friends[t] = true
	# 1. exército inimigo em terra do nosso lado
	var targets := []
	for b in army.armies.values():
		if not (b["tag"] in enemies) or b.get("retreat", false):
			continue
		var owner: String = map.provinces[int(b["loc"])]["owner"]
		if friends.has(owner) and army.strength(b) <= mine * 1.2:
			targets.append(int(b["loc"]))
	if _go(a, targets, here):
		return
	# 2. províncias nossas ocupadas
	targets = []
	for pid in war.controller:
		if friends.has(map.provinces[pid]["owner"]) and war.hostile(tag, war.controller[pid]):
			targets.append(int(pid))
	if _go(a, targets, here):
		return
	# 3. ofensiva
	var my_side := 0.0
	var their_side := 0.0
	for b in army.armies.values():
		if friends.has(b["tag"]):
			my_side += army.strength(b)
		elif b["tag"] in enemies:
			their_side += army.strength(b)
	if my_side < their_side * 0.8:
		return
	var strong := {}
	for b in army.armies.values():
		if b["tag"] in enemies and army.strength(b) > mine * 1.5:
			strong[int(b["loc"])] = true
	targets = []
	for e in enemies:
		for p in map.provinces_of(e):
			var pid := int(p["id"])
			if strong.has(pid) or not war.hostile(tag, war.controller_of(pid)):
				continue
			if army.siege and mine < 3.0 * army.siege.garrison(pid):
				continue
			targets.append(pid)
	_go(a, targets, here)


## Manda o exército para o alvo mais perto que tem caminho; devolve se mandou.
func _go(a: Dictionary, targets: Array, here: Vector2) -> bool:
	if targets.is_empty():
		return false
	targets.sort_custom(func(x, y): return _center(x).distance_squared_to(here) < _center(y).distance_squared_to(here))
	for i in mini(CANDIDATES, targets.size()):
		var pid: int = targets[i]
		if pid == int(a["loc"]):
			return true                       # já está lá (vai cercar/lutar)
		if army.move(int(a["id"]), pid):
			return true
	return false
