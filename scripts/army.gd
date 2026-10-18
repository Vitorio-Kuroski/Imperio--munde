class_name Army
extends RefCounted
## Exércitos terrestres, regras do EU4:
##  - Regimento = 1000 homens de infantaria, cavalaria ou artilharia (a melhor unidade liberada
##    pela tecnologia militar do país, `TechWindow.current_units`), com força 0–1.
##  - Limite de força = (6 + 0,1 por desenvolvimento (modificador estático development) +
##    land_forcelimit) × (1 + land_forcelimit_modifier).
##  - Recrutar custa INFANTRY/CAVALRY/ARTILLERY_COST ducados (10/25/30) × (1 + <tipo>_cost) e
##    1000 de efetivo, e leva INFANTRY/CAVALRY/ARTILLERY_TIME dias (60/90/120) × (1 + recruitment_time)
##    numa província própria; o regimento entra no exército do país que estiver nela (ou num novo).
##  - Manutenção por mês = Σ custo × LAND_MAINTENANCE_FACTOR (0,25) ÷ 12 × (1 + 2% por nível da
##    tecnologia militar, LAND_TECH_MAINTENANCE_IMPACT) × (1 + land_maintenance_modifier) ×
##    (1 + inflação) × barra de manutenção; acima do limite de força, × (1 + 2 × excesso ÷ limite)
##    (LAND_FORCELIMIT_EXTRA_COST_FACTOR). Entra na despesa "army" da `Economy`.
##  - Reforço por mês: +MONTHLY_REINFORCE (10%) × (1 + reinforce_speed) × barra da força de cada
##    regimento, gastando o efetivo correspondente.
##  - Moral máxima = moral das tecnologias militares (land_morale) × (1 + land_morale) × barra.
##  - Em 1444 cada país começa com STARTING_ARMY_SIZE (75%) do limite de força na capital (um quarto
##    de cavalaria), sem gastar efetivo.
##  - Movimento: caminho mais curto (AStar2D pelos centros das províncias de terra vizinhas e
##    estreitos) só por províncias que o país pode entrar (próprias, sem dono, de aliados, súditos e
##    suseranos); cada passo leva distância ÷ (INFANTRY_SPEED × 5 px/dia × (1 + movement_speed))
##    × custo de movimento do terreno de destino (≈ 8 dias numa província plana).
##  - Guerra (`war`): pode entrar nas terras dos inimigos; batalhas em `Combat`, cercos em `Siege`.
##    Quem perde recua (`retreat`) para a província amiga mais perto, sem poder lutar até chegar.
##  - Moral de cada regimento (`morale`): recupera MORALE_RECOVERY_SPEED (15%) da máxima por mês
##    (+5% em território controlado pelo país) fora de batalha.
##  - Atrito por mês: com mais regimentos na província que o limite de suprimento (suprimento do
##    terreno, ou SUPPLYLIMIT_BASE_MULTIPLIER = 6, × (1 + 0,02 por desenvolvimento) + supply_limit das
##    tecnologias), perde-se (regimentos ÷ limite)% dos homens, até 5%; cercar soma SIEGE_ATTRITION (1%).
##  - Ainda sem generais; a IA de guerra fica em `WarAI`.

signal changed(tag: String)
signal moved                      # algum exército mudou de lugar (o mapa redesenha os marcadores)

const TYPES := ["infantry", "cavalry", "artillery"]
const BASE_FORCELIMIT := 6.0
const PX_PER_SPEED := 5.0         # px do mapa por dia para velocidade 1

var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var manpower: Manpower
var diplomacy: Diplomacy
var armies := {}                  # id -> {id, tag, name, loc, regs: [{type, unit, str}], path, days, need}
var queue := {}                   # pid -> [{tag, type, left, total, paid}]
var budget := {}                  # tag -> 0..1 (barra de manutenção do exército)
var _next_id := 1
var _count := {}                  # tag -> exércitos já criados (para o nome)
var _rules := {}
var _terrain := {}                # id do terreno -> custo de movimento
var _astar := AStar2D.new()
var war: War                      # main.gd define (guerras: entrar em terra inimiga)
var combat: Combat                # Combat.setup define
var siege: Siege                  # Siege.setup define
var _day := 0                     # dias desde o início (ordem de chegada nas províncias)
var _fl_version := -1
var _fl := {}                     # tag -> limite de força (cache até um dono mudar)
var _stats := {}                  # tag -> [regimentos, Σ custo base] (refeito quando `_dirty`)
var _dirty := true


func setup(m: MapView, c: GameClock, pw: MonarchPower, eco: Economy, mp: Manpower, d: Diplomacy) -> void:
	map = m
	clock = c
	power = pw
	economy = eco
	manpower = mp
	diplomacy = d
	_rules = map.trade_rules
	for t in map.terrains:              # rótulo -> {eu4, movement_cost...}
		_terrain[t] = float(map.terrains[t].get("movement_cost", 1.0))
	_build_graph()
	_starting_armies()
	clock.day_passed.connect(_on_day)
	clock.month_passed.connect(_on_month)


func _rule(k: String, default: float) -> float:
	return float(_rules.get(k, default))


# ------------------------------------------------------------------ limite de força e custos
func force_limit(tag: String) -> float:
	if _fl_version != map.owner_version:
		_fl_version = map.owner_version
		_fl.clear()
		var per_dev := float(_rules.get("statics", {}).get("development", {}).get("land_forcelimit", 0.1))
		for p in map.provinces:
			var o: String = p["owner"]
			if o != "" and not p["sea"]:
				_fl[o] = float(_fl.get(o, 0.0)) + float(p["development"]) * per_dev
	return (BASE_FORCELIMIT + float(_fl.get(tag, 0.0)) + power.modifier(tag, "land_forcelimit")) \
			* maxf(0.0, 1.0 + power.modifier(tag, "land_forcelimit_modifier"))


## [regimentos, Σ custo] de cada país numa passada só (a economia pede de todos todo mês).
func _stat(tag: String) -> Array:
	if _dirty:
		_dirty = false
		_stats.clear()
		for a in armies.values():
			var st: Array = _stats.get(a["tag"], [0, 0.0])
			for r in a["regs"]:
				st[0] += 1
				st[1] += reg_cost(a["tag"], r["type"])
			_stats[a["tag"]] = st
	return _stats.get(tag, [0, 0.0])


func regiments(tag: String) -> int:
	return int(_stat(tag)[0]) + queued(tag)


func queued(tag: String) -> int:
	var n := 0
	for pid in queue:
		for q in queue[pid]:
			if q["tag"] == tag:
				n += 1
	return n


func reg_cost(tag: String, type: String) -> float:
	var base := _rule(type + "_cost", {"infantry": 10.0, "cavalry": 25.0, "artillery": 30.0}[type])
	return base * maxf(0.0, 1.0 + power.modifier(tag, type + "_cost"))


func reg_days(tag: String, type: String) -> int:
	var base := _rule(type + "_time", {"infantry": 60.0, "cavalry": 90.0, "artillery": 120.0}[type])
	return maxi(1, roundi(base * maxf(0.0, 1.0 + power.modifier(tag, "recruitment_time"))))


func budget_of(tag: String) -> float:
	return float(budget.get(tag, 1.0))


## Barra de manutenção do exército: de MIN_ARMY_MAINTENANCE (10%) a 100%.
func set_budget(tag: String, v: float) -> void:
	budget[tag] = clampf(v, _rule("min_army_maintenance", 0.1), 1.0)
	economy.invalidate(tag)
	_changed(tag)


## Manutenção por mês com a barra em 100% (para a dica) ou com a barra atual.
func maintenance(tag: String, full := false) -> float:
	var s := float(_stat(tag)[1])
	if s == 0.0:
		return 0.0
	var m := s * _rule("land_maintenance_factor", 0.25) / 12.0
	m *= 1.0 + _rule("land_tech_maintenance_impact", 0.02) * TechWindow.level_of(map, tag, "mil", power)
	m *= maxf(0.0, 1.0 + power.modifier(tag, "land_maintenance_modifier"))
	var fl := force_limit(tag)
	var n := float(_stat(tag)[0])
	if fl > 0.0 and n > fl:
		m *= 1.0 + _rule("land_forcelimit_extra_cost_factor", 2.0) * (n - fl) / fl
	m *= 1.0 + economy.inflation_of(tag) / 100.0
	return m if full else m * budget_of(tag)


func max_morale(tag: String) -> float:
	var lvl := TechWindow.level_of(map, tag, "mil", power)
	var base := 0.0
	var techs: Array = map.technologies.get("mil", [])
	for i in mini(lvl + 1, techs.size()):
		base += float(techs[i].get("modifiers", {}).get("land_morale", 0.0))
	if base == 0.0:
		base = 2.0
	return base * maxf(0.0, 1.0 + power.modifier(tag, "land_morale")) * budget_of(tag)


## Melhor unidade de cada tipo que o país já liberou: tipo -> {id, name, ...}.
func units(tag: String) -> Dictionary:
	return TechWindow.current_units(map, tag, power)


# ------------------------------------------------------------------ exércitos
func armies_of(tag: String) -> Array:
	var out := []
	for a in armies.values():
		if a["tag"] == tag:
			out.append(a)
	return out


func armies_at(pid: int) -> Array:
	var out := []
	for a in armies.values():
		if int(a["loc"]) == pid:
			out.append(a)
	return out


func strength(a: Dictionary) -> float:     # em milhares de homens
	var s := 0.0
	for r in a["regs"]:
		s += float(r["str"])
	return s


func count(a: Dictionary, type: String) -> int:
	var n := 0
	for r in a["regs"]:
		if r["type"] == type:
			n += 1
	return n


func _new_army(tag: String, pid: int) -> Dictionary:
	_count[tag] = int(_count.get(tag, 0)) + 1
	var a := {"id": _next_id, "tag": tag, "name": army_name(int(_count[tag])), "loc": pid, "regs": [],
			"path": [], "days": 0, "need": 0, "since": _day, "retreat": false}
	armies[_next_id] = a
	_next_id += 1
	return a


static func army_name(n: int) -> String:
	if Loc.active():
		var suf := "th"
		if n % 100 < 11 or n % 100 > 13:
			suf = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
		return "%d%s Army" % [n, suf]
	return "%dº Exército" % n


func _reg(tag: String, type: String, st := 1.0) -> Dictionary:
	var u: Dictionary = units(tag).get(type, {})
	return {"type": type, "unit": str(u.get("id", "")), "str": st, "morale": max_morale(tag)}


func mark_dirty() -> void:
	_dirty = true


func _starting_armies() -> void:
	var size := _rule("starting_army_size", 0.75)
	for tag in map.countries:
		var cap := int(map.countries[tag].get("capital", -1))
		if cap < 0 or cap >= map.provinces.size() or map.provinces[cap]["owner"] != tag:
			continue
		var n := maxi(1, roundi(force_limit(tag) * size))
		var cav := n / 4 if units(tag).has("cavalry") else 0
		var a := _new_army(tag, cap)
		for i in n:
			a["regs"].append(_reg(tag, "cavalry" if i < cav else "infantry"))


## Motivo de não poder recrutar `type` em `pid` ("" = pode).
func why_not(tag: String, pid: int, type: String) -> String:
	if pid < 0 or pid >= map.provinces.size() or map.provinces[pid]["owner"] != tag:
		return Loc.s("Só nas suas províncias", "Only in your own provinces")
	if war and war.controller_of(pid) != tag:
		return Loc.s("A província está ocupada", "The province is occupied")
	if war and _enemy_at(tag, pid):
		return Loc.s("Há um exército inimigo na província", "There is an enemy army in the province")
	if not units(tag).has(type):
		return Loc.s("Nenhuma unidade desse tipo liberada", "No unit of this type unlocked")
	if economy.money(tag) < reg_cost(tag, type):
		return Loc.s("Faltam ducados (%d)", "Not enough ducats (%d)") % ceili(reg_cost(tag, type))
	if manpower and manpower.of(tag) < _rule("inf_regiment_manpower_cost", 1.0):
		return Loc.s("Falta efetivo (1000 homens)", "Not enough manpower (1000 men)")
	return ""


func _enemy_at(tag: String, pid: int) -> bool:
	for a in armies_at(pid):
		if war.hostile(tag, a["tag"]):
			return true
	return false


## Província própria, controlada e sem inimigos para a IA recrutar (a capital, se puder).
func _safe_province(tag: String) -> int:
	var cap := int(map.countries.get(tag, {}).get("capital", -1))
	if cap >= 0 and why_not(tag, cap, "infantry") == "":
		return cap
	for p in map.provinces_of(tag):
		if why_not(tag, int(p["id"]), "infantry") == "":
			return int(p["id"])
	return -1


func recruit(tag: String, pid: int, type: String) -> bool:
	if why_not(tag, pid, type) != "":
		return false
	var cost := reg_cost(tag, type)
	economy.spend(tag, cost)
	if manpower:
		manpower.current[tag] = manpower.of(tag) - _rule("inf_regiment_manpower_cost", 1.0)
	var d := reg_days(tag, type)
	if not queue.has(pid):
		queue[pid] = []
	queue[pid].append({"tag": tag, "type": type, "left": d, "total": d, "paid": cost})
	_changed(tag)
	return true


func cancel(pid: int, i: int) -> void:
	var q: Array = queue.get(pid, [])
	if i < 0 or i >= q.size():
		return
	var it: Dictionary = q[i]
	q.remove_at(i)
	if q.is_empty():
		queue.erase(pid)
	economy.treasury[it["tag"]] = economy.money(it["tag"]) + float(it["paid"])
	if manpower:
		manpower.current[it["tag"]] = manpower.of(it["tag"]) + _rule("inf_regiment_manpower_cost", 1.0)
	_changed(it["tag"])


func disband(id: int) -> void:
	var a: Dictionary = armies.get(id, {})
	if a.is_empty():
		return
	armies.erase(id)
	_dirty = true
	moved.emit()
	_changed(a["tag"])


## Separa metade dos regimentos (de cada tipo) num exército novo no mesmo lugar.
func split(id: int) -> Dictionary:
	var a: Dictionary = armies.get(id, {})
	if a.is_empty() or a["regs"].size() < 2:
		return {}
	var b := _new_army(a["tag"], int(a["loc"]))
	for ty in TYPES:
		var mine := []
		for r in a["regs"]:
			if r["type"] == ty:
				mine.append(r)
		for i in mine.size() / 2:
			a["regs"].erase(mine[i])
			b["regs"].append(mine[i])
	if b["regs"].is_empty():          # um só tipo com número ímpar: leva pelo menos um
		b["regs"].append(a["regs"].pop_back())
	moved.emit()
	_changed(a["tag"])
	return b


## Junta ao exército `id` os outros do mesmo país parados na mesma província.
func merge_here(id: int) -> void:
	var a: Dictionary = armies.get(id, {})
	if a.is_empty():
		return
	for b in armies_at(int(a["loc"])):
		if b["id"] != id and b["tag"] == a["tag"] and b["path"].is_empty():
			a["regs"].append_array(b["regs"])
			armies.erase(b["id"])
	moved.emit()
	_changed(a["tag"])


# ------------------------------------------------------------------ movimento
func _center(pid: int) -> Vector2:
	var c: Array = map.provinces[pid]["center"]
	return Vector2(c[0], c[1])


func _build_graph() -> void:
	_astar.clear()
	for p in map.provinces:
		if not p["sea"]:
			_astar.add_point(int(p["id"]), _center(int(p["id"])), _terrain.get(p.get("terrain", ""), 1.0))
	for p in map.provinces:
		if p["sea"]:
			continue
		for n in p.get("neighbors", []):
			if _astar.has_point(int(n)) and not _astar.are_points_connected(int(p["id"]), int(n)):
				_astar.connect_points(int(p["id"]), int(n))
	for adj in map.adjacencies:       # estreitos
		var a := int(adj.get("from", -1))
		var b := int(adj.get("to", -1))
		if _astar.has_point(a) and _astar.has_point(b) and not _astar.are_points_connected(a, b):
			_astar.connect_points(a, b)


## Donos de províncias onde o país pode entrar: ele, aliados, súditos, suserano e os outros
## súditos do mesmo suserano ("" = sem dono também pode).
func allowed_owners(tag: String) -> Dictionary:
	var ok := {tag: true, "": true}
	if diplomacy == null:
		return ok
	for t in diplomacy.allies(tag):
		ok[t] = true
	if war:
		for t in war.enemies_of(tag):
			ok[t] = true
	for s in diplomacy.subjects(tag):         # [súdito, tipo]
		ok[s[0]] = true
	var top := diplomacy.top_overlord(tag)
	if top != "" and top != tag:
		ok[top] = true
		for s in diplomacy.subjects(top):
			ok[s[0]] = true
	return ok


func can_enter(tag: String, pid: int) -> bool:
	return allowed_owners(tag).has(map.provinces[pid]["owner"])


## Caminho de `from` até `to` (sem a origem); vazio se não houver.
func find_path(tag: String, from: int, to: int) -> Array:
	if not _astar.has_point(from) or not _astar.has_point(to) or not can_enter(tag, to):
		return []
	var ok := allowed_owners(tag)
	var off := []
	for id in _astar.get_point_ids():
		if id != from and not ok.has(map.provinces[id]["owner"]):
			_astar.set_point_disabled(id, true)
			off.append(id)
	var path := _astar.get_id_path(from, to)
	for id in off:
		_astar.set_point_disabled(id, false)
	var out := []
	for i in range(1, path.size()):
		out.append(int(path[i]))
	return out


func hop_days(tag: String, from: int, to: int) -> int:
	var d := _center(from).distance_to(_center(to))
	if d > map.map_w * 0.5:            # volta ao mundo (borda do mapa)
		d = map.map_w - d
	var speed := _rule("infantry_speed", 0.7) * PX_PER_SPEED * maxf(0.1, 1.0 + power.modifier(tag, "movement_speed"))
	return maxi(1, roundi(d / speed * float(_terrain.get(map.provinces[to].get("terrain", ""), 1.0))))


func move(id: int, to: int) -> bool:
	var a: Dictionary = armies.get(id, {})
	if a.is_empty() or a.get("retreat", false) or (combat and combat.in_battle(id)):
		return false
	if to == int(a["loc"]):
		a["path"] = []
		moved.emit()
		return true
	var path := find_path(a["tag"], int(a["loc"]), to)
	if path.is_empty():
		return false
	var keep_progress: bool = not a["path"].is_empty() and int(a["path"][0]) == int(path[0])
	a["path"] = path
	if not keep_progress:
		a["days"] = 0
		a["need"] = hop_days(a["tag"], int(a["loc"]), int(path[0]))
	moved.emit()
	return true


## Dias até chegar ao fim do caminho.
func eta(a: Dictionary) -> int:
	if a["path"].is_empty():
		return 0
	var d := int(a["need"]) - int(a["days"])
	var prev := int(a["path"][0])
	for i in range(1, a["path"].size()):
		d += hop_days(a["tag"], prev, int(a["path"][i]))
		prev = int(a["path"][i])
	return d


func _on_day() -> void:
	_day += 1
	var any := false
	for a in armies.values():
		if a["path"].is_empty():
			continue
		any = true                    # a posição no mapa anda todo dia
		a["days"] = int(a["days"]) + 1
		if int(a["days"]) >= int(a["need"]):
			a["loc"] = int(a["path"].pop_front())
			a["days"] = 0
			a["since"] = _day
			if a["path"].is_empty():
				a["retreat"] = false
			if not a["path"].is_empty():
				if not can_enter(a["tag"], int(a["path"][0])):      # a fronteira fechou no caminho
					a["path"] = []
				else:
					a["need"] = hop_days(a["tag"], int(a["loc"]), int(a["path"][0]))
			any = true
	# recrutamento
	var done := []
	for pid in queue:
		for q in queue[pid]:
			q["left"] = int(q["left"]) - 1
			if int(q["left"]) <= 0:
				done.append([pid, q])
	for d in done:
		var pid: int = d[0]
		var q: Dictionary = d[1]
		queue[pid].erase(q)
		if queue[pid].is_empty():
			queue.erase(pid)
		if map.provinces[pid]["owner"] != q["tag"] or (war and (war.controller_of(pid) != q["tag"] or _enemy_at(q["tag"], pid))):
			continue                      # perdida, ocupada ou com inimigo: o regimento não sai
		var target := {}
		for a in armies_at(pid):
			if a["tag"] == q["tag"] and a["path"].is_empty():
				target = a
				break
		if target.is_empty():
			target = _new_army(q["tag"], pid)
		target["regs"].append(_reg(q["tag"], q["type"]))
		any = true
		_changed(q["tag"])
	if any:
		moved.emit()


func _on_month() -> void:
	_dirty = true                     # custos dependem de efeitos que mudam (ideias, tecnologia)
	_ai_budget()
	_attrition()
	_recover_morale()
	_ai_recruit()
	if manpower == null:
		return
	for a in armies.values():
		var tag: String = a["tag"]
		var rate := _rule("monthly_reinforce", 0.1) * maxf(0.0, 1.0 + power.modifier(tag, "reinforce_speed")) * budget_of(tag)
		for r in a["regs"]:
			var miss := 1.0 - float(r["str"])
			if miss <= 0.0:
				continue
			var add := minf(minf(miss, rate), manpower.of(tag))
			if add <= 0.0:
				break
			r["str"] = float(r["str"]) + add
			manpower.current[tag] = manpower.of(tag) - add
	if power.player != "":
		_changed(power.player)


# ------------------------------------------------------------------ retirada, paz, moral, atrito
## Recuo depois de perder: vai para a província mais perto (busca em largura pelos vizinhos) que
## o país pode entrar, controlada por ele ou por amigos e sem exército inimigo; sem saída, o
## exército é destruído.
func retreat(id: int) -> void:
	var a: Dictionary = armies.get(id, {})
	if a.is_empty():
		return
	var tag: String = a["tag"]
	var start := int(a["loc"])
	var ok := allowed_owners(tag)
	var seen := {start: true}
	var q := [start]
	var target := -1
	while not q.is_empty() and target < 0 and seen.size() < 400:
		var cur: int = q.pop_front()
		for n in _astar.get_point_connections(cur):
			if seen.has(n):
				continue
			seen[n] = true
			if not ok.has(map.provinces[n]["owner"]):
				continue
			q.append(n)
			var ctrl: String = war.controller_of(n) if war else map.provinces[n]["owner"]
			if war and war.hostile(tag, ctrl):
				continue
			var enemy := false
			for b in armies_at(n):
				if war and war.hostile(tag, b["tag"]):
					enemy = true
			if not enemy:
				target = n
				break
	var path := find_path(tag, start, target) if target >= 0 else []
	if path.is_empty():
		disband(id)
		return
	a["path"] = path
	a["days"] = 0
	a["need"] = hop_days(tag, start, int(path[0]))
	a["retreat"] = true
	moved.emit()


## Paz: exércitos que ficaram em terra onde não podem entrar voltam para a capital.
func send_home_after_peace() -> void:
	for a in armies.values():
		var tag: String = a["tag"]
		if can_enter(tag, int(a["loc"])):
			if not a["path"].is_empty() and not can_enter(tag, int(a["path"][a["path"].size() - 1])):
				a["path"] = []
			continue
		var cap := int(map.countries.get(tag, {}).get("capital", -1))
		if cap >= 0 and map.provinces[cap]["owner"] == tag:
			a["loc"] = cap
			a["path"] = []
			a["retreat"] = false
	moved.emit()


## Limite de suprimento (em regimentos) da província para o país.
func supply_limit(pid: int, tag: String) -> float:
	var p: Dictionary = map.provinces[pid]
	var t: Dictionary = map.terrains.get(p.get("terrain", ""), {})
	var base := float(t.get("supply_limit", _rule("supplylimit_base_multiplier", 6.0)))
	var per_dev := float(_rules.get("statics", {}).get("development", {}).get("supply_limit_modifier", 0.02))
	var tech := combat.tech_value(tag, "supply_limit") if combat else 0.0
	return base * (1.0 + per_dev * float(p["development"])) + tech


## Atrito (% por mês) dos exércitos na província `pid` (todos os regimentos ali contam).
func attrition_at(pid: int, tag: String) -> float:
	var n := 0
	for a in armies_at(pid):
		n += a["regs"].size()
	var lim := supply_limit(pid, tag)
	var att := 0.0
	if n > lim and lim > 0.0:
		att = minf(5.0, float(n) / lim)
	if siege and siege.sieges.has(pid) and siege.sieges[pid]["tag"] == tag:
		att += _rule("siege_attrition", 1.0)
	return att


func _attrition() -> void:
	var done := {}
	for a in armies.values():
		var key := "%d|%s" % [int(a["loc"]), a["tag"]]
		if not done.has(key):
			done[key] = attrition_at(int(a["loc"]), a["tag"])
		var att: float = done[key]
		if att <= 0.0:
			continue
		for r in a["regs"]:
			r["str"] = float(r["str"]) * (1.0 - att / 100.0)


func _recover_morale() -> void:
	for a in armies.values():
		if combat and combat.in_battle(int(a["id"])):
			continue
		var tag: String = a["tag"]
		var mx := max_morale(tag)
		var ctrl: String = war.controller_of(int(a["loc"])) if war else map.provinces[int(a["loc"])]["owner"]
		var rate := _rule("morale_recovery_speed", 0.15) + (_rule("morale_recovery_speed_own_territory", 0.05) if ctrl == tag else 0.0)
		for r in a["regs"]:
			r["morale"] = minf(mx, float(r.get("morale", 0.0)) + mx * rate)


## Moral média dos regimentos do exército.
func morale(a: Dictionary) -> float:
	if a["regs"].is_empty():
		return 0.0
	var s := 0.0
	for r in a["regs"]:
		s += float(r.get("morale", 0.0))
	return s / a["regs"].size()


## IA em guerra: recruta infantaria na capital enquanto estiver abaixo do limite de força e o
## tesouro aguentar (um regimento por mês).
func _ai_recruit() -> void:
	if war == null:
		return
	var done := {}
	for w in war.wars.values():
		for tag in w["attackers"] + w["defenders"]:
			if tag == power.player or done.has(tag):
				continue
			done[tag] = true
			if regiments(tag) >= force_limit(tag) or economy.money(tag) < reg_cost(tag, "infantry") * 3.0:
				continue
			var pid := _safe_province(tag)
			if pid >= 0:
				recruit(tag, pid, "infantry")


## IA: em paz a barra de manutenção fica no que a renda paga (como a IA do EU4, que baixa a
## manutenção fora da guerra), entre o mínimo e 100%.
func _ai_budget() -> void:
	var done := {}
	for a in armies.values():
		var tag: String = a["tag"]
		if tag == power.player or done.has(tag):
			continue
		done[tag] = true
		var full := maintenance(tag, true)
		if full <= 0.0:
			continue
		if war and war.at_war(tag):
			budget[tag] = 1.0             # em guerra, manutenção cheia
			continue
		var exp: Dictionary = economy.expenses(tag)
		var other := float(exp["total"]) - float(exp.get("army", 0.0))
		var spare := float(economy.income(tag)["total"]) - other - 0.1
		budget[tag] = clampf(spare / full, _rule("min_army_maintenance", 0.1), 1.0)


func _changed(tag: String) -> void:
	_dirty = true
	if tag == power.player:
		changed.emit(tag)
