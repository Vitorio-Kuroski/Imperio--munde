class_name Religion
extends RefCounted
## Conversão religiosa (regras do EU4):
##  - Missionários: cada país tem `missionaries` dos valores básicos do EU4 (1) + efeitos. Um
##    missionário numa província própria de outra religião soma por mês a força missionária
##    líquida ao progresso; com 100% a província passa à religião do Estado e o missionário fica
##    livre.
##  - Força missionária = global_missionary_strength (2% básico + efeitos) + força contra
##    heréticos (mesmo grupo religioso) ou pagãos (outro grupo) − resistência da província
##    (desenvolvimento × 0,1%, do modificador estático `development` do EU4). Sem força líquida
##    positiva não dá para converter.
##  - Manutenção de cada missionário (despesa "Manutenção de missionários"): 0,5 + 5% do
##    desenvolvimento da província por mês, × a barra de missionários da aba Economia (que também
##    reduz a força na mesma proporção).
##  - O país pode mudar a religião do Estado para a religião da sua capital (convert_country).
##  - IA (a cada 3 meses): manda os missionários livres para a província de outra religião onde
##    converte mais depressa, se o saldo cobrir a manutenção.

signal changed(tag: String)

const COST_BASE := 0.5
const COST_PER_DEV := 0.05

var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var missions := {}                 # tag -> {pid: progresso 0..100}
var budget := {}                   # tag -> 0..1 (barra de missionários)


func setup(m: MapView, c: GameClock, pw: MonarchPower, eco: Economy) -> void:
	map = m
	clock = c
	power = pw
	economy = eco
	clock.month_passed.connect(_on_month)


func enabled() -> bool:
	return not map.religions.is_empty()


func _base(k: String, default: float) -> float:
	return float(map.trade_rules.get("base_values", {}).get(k, default))


func max_missionaries(tag: String) -> int:
	return maxi(0, int(_base("missionaries", 1.0) + power.modifier(tag, "missionaries")))


func free_missionaries(tag: String) -> int:
	return max_missionaries(tag) - missions.get(tag, {}).size()


func state_religion(tag: String) -> String:
	return str(map.countries.get(tag, {}).get("religion", ""))


func budget_of(tag: String) -> float:
	return float(budget.get(tag, 1.0))


## Força missionária líquida por mês (fração: 0,02 = 2%) na província `pid` (pode ser negativa).
func strength(tag: String, pid: int) -> float:
	var p: Dictionary = map.provinces[pid]
	var rid := state_religion(tag)
	var pr: String = p.get("religion", "")
	var s := _base("global_missionary_strength", 0.02) + power.modifier(tag, "global_missionary_strength")
	var same_group: bool = map.religions.has(rid) and map.religions.has(pr) \
			and map.religions[rid]["group"] == map.religions[pr]["group"]
	s += power.modifier(tag, "global_heretic_missionary_strength" if same_group else "global_heathen_missionary_strength")
	s += float(p["development"]) * float(map.trade_rules.get("dev_missionary_strength", -0.001))
	s += map.building_mod(p, "local_missionary_strength")      # catedral
	return s * budget_of(tag)


func can_convert(tag: String, pid: int) -> bool:
	if pid < 0 or pid >= map.provinces.size():
		return false
	var p: Dictionary = map.provinces[pid]
	return p["owner"] == tag and not p["sea"] and p.get("religion", "") != "" \
			and p.get("religion", "") != state_religion(tag) and map.religions.has(state_religion(tag))


func has_mission(tag: String, pid: int) -> bool:
	return missions.get(tag, {}).has(pid)


func progress(tag: String, pid: int) -> float:
	return float(missions.get(tag, {}).get(pid, 0.0))


func can_send(tag: String, pid: int) -> bool:
	return can_convert(tag, pid) and not has_mission(tag, pid) and free_missionaries(tag) > 0 and strength(tag, pid) > 0.0


func send(tag: String, pid: int) -> bool:
	if not can_send(tag, pid):
		return false
	if not missions.has(tag):
		missions[tag] = {}
	missions[tag][pid] = 0.0
	_changed(tag)
	return true


func recall(tag: String, pid: int) -> void:
	if missions.get(tag, {}).erase(pid):
		_changed(tag)


## Meses que faltam para converter (-1 se não avança).
func months_left(tag: String, pid: int) -> int:
	var s := strength(tag, pid)
	if s <= 0.0:
		return -1
	return ceili((100.0 - progress(tag, pid)) / (s * 100.0))


## Manutenção mensal de um missionário na província (já com a barra).
func mission_cost(pid: int, tag: String) -> float:
	return (COST_BASE + COST_PER_DEV * float(map.provinces[pid]["development"])) * budget_of(tag)


## Despesa mensal com missionários do país.
func cost(tag: String) -> float:
	var c := 0.0
	for pid in missions.get(tag, {}):
		c += mission_cost(pid, tag)
	return c


func set_budget(tag: String, v: float) -> void:
	budget[tag] = clampf(v, 0.0, 1.0)
	_changed(tag)


## Religiões para as quais o país pode se converter: a da capital (se for outra).
func can_convert_country(tag: String, rid: String) -> bool:
	var cap := int(map.countries.get(tag, {}).get("capital", 0))
	return map.religions.has(rid) and rid != state_religion(tag) and cap > 0 and cap < map.provinces.size() \
			and map.provinces[cap].get("religion", "") == rid


func convert_country(tag: String, rid: String) -> bool:
	if not can_convert_country(tag, rid):
		return false
	map.countries[tag]["religion"] = rid
	# missões em províncias que já são da nova religião acabam
	for pid in missions.get(tag, {}).keys():
		if map.provinces[pid].get("religion", "") == rid:
			missions[tag].erase(pid)
	power.invalidate(tag)      # efeitos da religião mudam
	_changed(tag)
	return true


func _changed(tag: String) -> void:
	if economy:
		economy.invalidate(tag)
	if tag == power.player:
		changed.emit(tag)


func _on_month() -> void:
	if not enabled():
		return
	for tag in missions.keys():
		var ms: Dictionary = missions[tag]
		for pid in ms.keys():
			if not can_convert(tag, pid):
				ms.erase(pid)            # mudou de dono ou já é da religião do Estado
				continue
			ms[pid] = float(ms[pid]) + maxf(0.0, strength(tag, pid)) * 100.0
			if ms[pid] >= 100.0:
				ms.erase(pid)
				map.set_religion_of(pid, state_religion(tag))
	if clock.month % 3 == 1:          # a IA escolhe missões a cada 3 meses (percorre todas as províncias)
		_ai()
	changed.emit(power.player)


## IA: missionários livres vão para a província de outra religião que converte mais depressa.
func _ai() -> void:
	var best := {}                     # tag -> [pid, força]
	var base := {}                     # tag -> [força contra heréticos, contra pagãos] (sem a resistência)
	var dev_res := float(map.trade_rules.get("dev_missionary_strength", -0.001))
	for p in map.provinces:
		var tag: String = p["owner"]
		if tag == "" or tag == power.player or p["sea"]:
			continue
		var pr: String = p.get("religion", "")
		var rid := str(map.countries.get(tag, {}).get("religion", ""))
		if pr == "" or pr == rid or not map.religions.has(rid) or not map.religions.has(pr):
			continue
		var pid := int(p["id"])
		if has_mission(tag, pid):
			continue
		if not base.has(tag):
			if free_missionaries(tag) <= 0:
				base[tag] = null
			else:
				var b := _base("global_missionary_strength", 0.02) + power.modifier(tag, "global_missionary_strength")
				base[tag] = [b + power.modifier(tag, "global_heretic_missionary_strength"),
						b + power.modifier(tag, "global_heathen_missionary_strength")]
		if base[tag] == null:
			continue
		var same: bool = map.religions[rid]["group"] == map.religions[pr]["group"]
		var s: float = (base[tag][0] if same else base[tag][1]) + float(p["development"]) * dev_res
		if s > 0.0 and (not best.has(tag) or s > best[tag][1]):
			best[tag] = [pid, s]
	for tag in best:
		var pid: int = best[tag][0]
		if free_missionaries(tag) > 0 and economy.balance(tag) > mission_cost(pid, tag):
			send(tag, pid)
