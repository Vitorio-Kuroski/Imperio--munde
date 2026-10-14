class_name Construction
extends RefCounted
## Construções e desenvolvimento das províncias (regras do EU4, tela "construir" do EU4):
##  - Construções (common/buildings): liberadas pela tecnologia que as lista; custam `cost` ducados
##    × (1 + build_cost) e levam `time` meses × (1 + build_time). Uma por vez em cada província;
##    cancelar devolve o dinheiro. As que substituem outra (`replaces`, ex. catedral ← templo)
##    ocupam a mesma vaga; não dá para construir uma que já foi substituída. As de costa (docas,
##    estaleiros, defesa costeira) só em províncias costeiras; manufaturas (`goods`) só onde o
##    produto bate (ou "all") e no máximo uma por província; `one_per_country` só uma no país.
##    As nativas só para governo nativo.
##  - Vagas (modificadores estáticos do EU4): 2 (`city`) + 0,1 por desenvolvimento
##    (`development`) + allowed_num_of_buildings das construções (universidade), até 12.
##  - Desenvolvimento: +1 de imposto (adm), produção (dip) ou efetivo (mil) por 50 pontos ×
##    (1 + development_cost do país + local_development_cost do terreno e das construções +
##    3% por desenvolvimento acima de 9, dobrando a cada 10 — `development_scaled` do EU4), mín. 10%.
##  - Efeitos já usados no jogo: local_tax_modifier e local_production_efficiency (Economy),
##    trade_goods_size (bens produzidos, Economy e Trade), province_trade_power_modifier (Trade),
##    local_missionary_strength (Religion) e local_development_cost (aqui).
##  - A IA ainda não constrói nem desenvolve.

signal changed(tag: String)

const BASE_SLOTS := 2.0            # modificador estático city: allowed_num_of_buildings = 2
const SLOTS_PER_DEV := 0.1         # modificador estático development: allowed_num_of_buildings = 0.1
const MAX_SLOTS := 12              # MAX_BUILDING_SLOTS (common/defines.lua)
const DEV_BASE_COST := 50.0
const DEV_SCALED := 0.03           # modificador estático development_scaled: local_development_cost = 0.03
const COASTAL := ["dock", "drydock", "shipyard", "grand_shipyard", "coastal_defence", "naval_battery",
		"impressment_offices", "wharf"]
const DEV_KINDS := {"tax": ["base_tax", "adm"], "production": ["base_production", "dip"],
		"manpower": ["base_manpower", "mil"]}

var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var unlock := {}                   # construção -> [árvore, nível da tecnologia que a libera]
var queue := {}                    # pid -> {"tag", "id", "left" (meses), "total", "paid"}
var _upgrades := {}                # construção -> [as que ela substitui, direta ou indiretamente]


func setup(m: MapView, c: GameClock, pw: MonarchPower, eco: Economy) -> void:
	map = m
	clock = c
	power = pw
	economy = eco
	for cat in map.technologies:
		for t in map.technologies[cat]:
			for b in t.get("buildings", []):
				if not unlock.has(b):
					unlock[b] = [cat, int(t["level"])]
	for b in map.buildings:
		var chain := []
		var r: String = str(map.buildings[b].get("replaces", ""))
		while r != "" and map.buildings.has(r) and not (r in chain):
			chain.append(r)
			r = str(map.buildings[r].get("replaces", ""))
		_upgrades[b] = chain
	clock.month_passed.connect(_on_month)


func enabled() -> bool:
	return not map.buildings.is_empty()


# ------------------------------------------------------------------ construções
## Soma de um efeito das construções da província.
func local_mod(pid: int, key: String) -> float:
	var s := 0.0
	for b in map.provinces[pid].get("buildings", []):
		s += float(map.buildings.get(b, {}).get("modifiers", {}).get(key, 0.0))
	return s


func slots(pid: int) -> int:
	var p: Dictionary = map.provinces[pid]
	return mini(MAX_SLOTS, int(floor(BASE_SLOTS + SLOTS_PER_DEV * float(p["development"]) \
			+ local_mod(pid, "allowed_num_of_buildings"))))


## Vagas ocupadas: cada construção ocupa uma (as que se substituem já saíram da lista);
## a que está em obra também conta, salvo se for melhoria de uma que já existe.
func used_slots(pid: int) -> int:
	var n: int = map.provinces[pid].get("buildings", []).size()
	if queue.has(pid) and not _is_upgrade(pid, queue[pid]["id"]):
		n += 1
	return n


func _is_upgrade(pid: int, bid: String) -> bool:
	for old in _upgrades.get(bid, []):
		if old in map.provinces[pid].get("buildings", []):
			return true
	return false


func _is_manufactory(bid: String) -> bool:
	return map.buildings.get(bid, {}).has("goods")


func is_unlocked(tag: String, bid: String) -> bool:
	if not unlock.has(bid):
		return false
	return power.tech(tag, unlock[bid][0]) >= int(unlock[bid][1])


## Construções que aparecem na tela do país (nativas só para governo nativo; a "manufactory"
## genérica do EU4 não se constrói direto).
func buildable_ids(tag: String) -> Array:
	var native: bool = str(map.countries.get(tag, {}).get("government", "")) == "native"
	var out := []
	for bid in map.buildings:
		if bid == "manufactory" or not unlock.has(bid):
			continue
		if bid.begins_with("native_") != native:
			continue
		out.append(bid)
	return out


func cost(tag: String, bid: String) -> float:
	return float(map.buildings.get(bid, {}).get("cost", 0)) * maxf(0.1, 1.0 + power.modifier(tag, "build_cost"))


func months(tag: String, bid: String) -> int:
	return maxi(1, roundi(float(map.buildings.get(bid, {}).get("time", 12)) \
			* maxf(0.1, 1.0 + power.modifier(tag, "build_time"))))


## "" se dá para construir `bid` na província `pid`, senão o motivo (para a dica).
func why_not(tag: String, pid: int, bid: String) -> String:
	var p: Dictionary = map.provinces[pid]
	if p["owner"] != tag or p["sea"]:
		return Loc.s("Não é sua", "Not yours")
	var b: Dictionary = map.buildings.get(bid, {})
	if b.is_empty():
		return "?"
	if not is_unlocked(tag, bid):
		return Loc.s("Tecnologia %s %d", "Technology %s %d") % [unlock[bid][0], unlock[bid][1]] \
				if unlock.has(bid) else Loc.s("Bloqueada", "Locked")
	var have: Array = p.get("buildings", [])
	if bid in have:
		return Loc.s("Já construída", "Already built")
	for other in have:
		if bid in _upgrades.get(other, []):
			return Loc.s("Já tem uma melhor", "Already has a better one")
	if queue.has(pid):
		return Loc.s("Já há uma obra na província", "Already building here")
	if bid in COASTAL and not p.get("coastal", false):
		return Loc.s("Só em província costeira", "Coastal province only")
	if _is_manufactory(bid):
		var goods: Array = b["goods"]
		if not ("all" in goods) and not (p.get("trade_goods", "") in goods):
			return Loc.s("O produto da província não serve", "Wrong trade good")
		for other in have:
			if _is_manufactory(other):
				return Loc.s("Já tem uma manufatura", "Already has a manufactory")
	if b.get("one_per_country", false):
		for q in map.provinces:
			if q["owner"] == tag and (bid in q.get("buildings", [])):
				return Loc.s("Só uma por país", "One per country")
	if not _is_upgrade(pid, bid) and used_slots(pid) >= slots(pid):
		return Loc.s("Sem vaga (%d/%d)", "No free slot (%d/%d)") % [used_slots(pid), slots(pid)]
	if economy.money(tag) < cost(tag, bid):
		return Loc.s("Faltam ducados", "Not enough ducats")
	return ""


func can_build(tag: String, pid: int, bid: String) -> bool:
	return why_not(tag, pid, bid) == ""


func build(tag: String, pid: int, bid: String) -> bool:
	if not can_build(tag, pid, bid):
		return false
	var c := cost(tag, bid)
	if not economy.spend(tag, c):
		return false
	var m := months(tag, bid)
	queue[pid] = {"tag": tag, "id": bid, "left": m, "total": m, "paid": c}
	_changed(tag)
	return true


## Cancela a obra da província e devolve o dinheiro.
func cancel(pid: int) -> void:
	if not queue.has(pid):
		return
	var q: Dictionary = queue[pid]
	queue.erase(pid)
	economy.treasury[q["tag"]] = economy.money(q["tag"]) + float(q["paid"])
	_changed(q["tag"])


## Progresso da obra (0..1) ou -1 se não há.
func progress(pid: int) -> float:
	if not queue.has(pid):
		return -1.0
	var q: Dictionary = queue[pid]
	return 1.0 - float(q["left"]) / float(q["total"])


func _finish(pid: int, q: Dictionary) -> void:
	var p: Dictionary = map.provinces[pid]
	if p["owner"] != q["tag"]:
		return                         # a província mudou de dono: a obra se perde
	var have: Array = p.get("buildings", []).duplicate()
	for old in _upgrades.get(q["id"], []):
		have.erase(old)
	have.append(q["id"])
	p["buildings"] = have
	_province_changed(q["tag"])


# ------------------------------------------------------------------ desenvolvimento
func dev_cost(tag: String, pid: int) -> int:
	var p: Dictionary = map.provinces[pid]
	var dev := int(p["development"])
	var scaled := 0.0
	for d in range(10, dev + 1):            # 3% por ponto acima de 9, dobrando a cada 10
		scaled += DEV_SCALED * float(1 + (d - 10) / 10)
	var terr := float(map.terrains.get(p.get("terrain", ""), {}).get("local_development_cost", 0.0))
	var mod := power.modifier(tag, "development_cost") + terr + local_mod(pid, "local_development_cost") + scaled
	return maxi(1, roundi(DEV_BASE_COST * maxf(0.1, 1.0 + mod)))


func can_develop(tag: String, pid: int, kind: String) -> bool:
	var p: Dictionary = map.provinces[pid]
	return DEV_KINDS.has(kind) and p["owner"] == tag and not p["sea"] \
			and power.points(tag, DEV_KINDS[kind][1]) >= dev_cost(tag, pid)


## +1 de imposto/produção/efetivo na província, pagando com os pontos de monarca da categoria.
func develop(tag: String, pid: int, kind: String) -> bool:
	if not can_develop(tag, pid, kind):
		return false
	var p: Dictionary = map.provinces[pid]
	var cat: String = DEV_KINDS[kind][1]
	power.state[tag]["points"][cat] -= dev_cost(tag, pid)
	p[DEV_KINDS[kind][0]] = int(p.get(DEV_KINDS[kind][0], 0)) + 1
	p["development"] = int(p["development"]) + 1
	power.notify(tag)
	_province_changed(tag)
	return true


# ------------------------------------------------------------------
## Renda, comércio e o desenvolvimento total são refeitos (como numa troca de dono).
func _province_changed(tag: String) -> void:
	map.owner_version += 1
	economy._recount()
	_changed(tag)


func _changed(tag: String) -> void:
	if tag == power.player:
		changed.emit(tag)


func _on_month() -> void:
	for pid in queue.keys():
		var q: Dictionary = queue[pid]
		q["left"] = int(q["left"]) - 1
		if int(q["left"]) <= 0:
			queue.erase(pid)
			_finish(pid, q)
		elif q["tag"] == power.player:
			changed.emit(q["tag"])
