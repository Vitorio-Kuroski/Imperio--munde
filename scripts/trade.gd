class_name Trade
extends RefCounted
## Comércio do EU4 (versão simplificada, com os dados e as regras importados):
##  - valor comercial da província = bens produzidos (produção base × 0,2) × preço (o ouro não entra:
##    vira renda de ouro);
##  - poder comercial da província = (desenvolvimento × 0,2 + centro de comércio) × (1 + 25% se
##    costeira + construções) × (1 + poder comercial provincial do país: ideias + mercantilismo ×
##    2 — 10% de mercantilismo dá +20%);
##  - em cada nó, o poder de um país é a soma das suas províncias ali (+5 na capital comercial,
##    o nó da capital) × (1 + global_trade_power);
##  - os nós são processados de cima para baixo (pelas rotas `outgoing`): o país coleta no nó da
##    capital e onde tiver mercador; nos outros nós o poder dele "transfere": empurra o valor para o
##    nó seguinte que leva à sua capital (ou, sem caminho, repartido entre as saídas);
##  - parte coletada = valor × poder de quem coleta ÷ poder total; cada coletor leva a sua parte
##    × (1 + eficiência comercial; +10% com mercador) ÷ 12 por mês. Coletar fora da capital tem
##    −50% de poder;
##  - mercadores (2 por país) vão sozinhos para os nós fora da capital onde o país tem mais poder:
##    se a capital fica rio abaixo, puxam o valor para ela (+10% de poder); senão coletam ali.
## Ainda não há: mudar a capital comercial, escolher mercadores, navios leves, embargos, ligas.

var map: MapView
var power: MonarchPower
var nodes: Array = []                   # ids na ordem de processamento (de cima para baixo)
var index := {}                         # id -> posição
var out_links: Array = []               # posição -> [posições dos nós seguintes]
var reach: Array = []                   # posição -> {posição: true} nós alcançáveis descendo
var local_value: PackedFloat32Array     # valor gerado pelas províncias do nó
var total_value: PackedFloat32Array     # local + o que chega de cima
var outgoing_value: PackedFloat32Array  # o que desce para os nós seguintes
var node_power: Array = []              # posição -> {tag: poder}
var collecting: Array = []              # posição -> {tag: true} quem coleta ali
var steering: Array = []                # posição -> {tag: true} quem tem mercador puxando o valor
var collected: Array = []               # posição -> {tag: ducados por mês}
var prov_value: PackedFloat32Array      # por província
var prov_power: PackedFloat32Array
var merchants := {}                     # tag -> [posições dos nós com mercador]
var _income := {}                       # tag -> ducados por mês
var _cot := {}                          # "coastal1" -> poder
var _rules := {}
var _static_version := -1               # dados fixos das províncias (refeitos quando um dono muda)
var _pids := PackedInt32Array()         # províncias de terra com nó
var _pnode := PackedInt32Array()
var _pbase := PackedFloat32Array()      # poder antes dos modificadores do país
var _tech_eff := PackedFloat32Array()   # eficiência comercial somada da tecnologia dip até cada nível


func setup(m: MapView, pw: MonarchPower) -> void:
	map = m
	power = pw
	_rules = map.trade_rules
	for c in map.centers_of_trade:
		_cot["%s%d" % [c["type"], int(c["level"])]] = float(c["trade_power"])
	_order_nodes()
	var s := 0.0
	for t in map.technologies.get("dip", []):
		s += float(t.get("modifiers", {}).get("trade_efficiency", 0.0))
		_tech_eff.append(s)
	map.trade_view = self


func enabled() -> bool:
	return not nodes.is_empty()


func _rule(k: String, default: float) -> float:
	return float(_rules.get(k, default))


## Ordena os nós de cima para baixo (ordem topológica das rotas) e guarda quem alcança quem.
func _order_nodes() -> void:
	var ids: Array = map.trade_nodes.keys()
	ids.sort()
	var indeg := {}
	for id in ids:
		indeg[id] = 0
	for id in ids:
		for o in map.trade_nodes[id].get("outgoing", []):
			if indeg.has(o["to"]):
				indeg[o["to"]] += 1
	var queue := []
	for id in ids:
		if indeg[id] == 0:
			queue.append(id)
	while not queue.is_empty():
		var id: String = queue.pop_front()
		nodes.append(id)
		for o in map.trade_nodes[id].get("outgoing", []):
			if indeg.has(o["to"]):
				indeg[o["to"]] -= 1
				if indeg[o["to"]] == 0:
					queue.append(o["to"])
	for id in ids:                       # rotas em ciclo (não deveria haver): vão no fim
		if not (id in nodes):
			nodes.append(id)
	for i in nodes.size():
		index[nodes[i]] = i
	out_links.resize(nodes.size())
	reach.resize(nodes.size())
	for i in nodes.size():
		var outs := []
		for o in map.trade_nodes[nodes[i]].get("outgoing", []):
			if index.has(o["to"]) and index[o["to"]] > i:
				outs.append(index[o["to"]])
		out_links[i] = outs
	for i in range(nodes.size() - 1, -1, -1):
		var r := {}
		for j in out_links[i]:
			r[j] = true
			r.merge(reach[j])
		reach[i] = r


## Nó da capital comercial do país (-1 se não houver).
func home(tag: String) -> int:
	var cap := int(map.countries.get(tag, {}).get("capital", 0))
	if cap <= 0 or cap >= map.provinces.size() or map.provinces[cap]["owner"] != tag:
		return -1
	return int(index.get(map.provinces[cap].get("trade_node", ""), -1))


## Poder comercial provincial do país (ideias, efeitos e mercantilismo).
func _country_power_mod(tag: String) -> float:
	var merc := float(map.countries.get(tag, {}).get("mercantilism", 10)) / 100.0
	return power.modifier(tag, "global_prov_trade_power_modifier") + merc * _rule("mercantilism_trade_power", 2.0)


func trade_efficiency(tag: String) -> float:
	var lvl := TechWindow.level_of(map, tag, "dip", power)
	var s := power.modifier(tag, "trade_efficiency")
	if not _tech_eff.is_empty():
		s += _tech_eff[clampi(lvl, 0, _tech_eff.size() - 1)]
	return s


## Recalcula valores, poderes e a renda de comércio de todos (uma vez por mês).
func recompute() -> void:
	if nodes.is_empty():
		return
	var n := nodes.size()
	var np := map.provinces.size()
	local_value = PackedFloat32Array()
	local_value.resize(n)
	total_value = PackedFloat32Array()
	total_value.resize(n)
	outgoing_value = PackedFloat32Array()
	outgoing_value.resize(n)
	prov_power = PackedFloat32Array()
	prov_power.resize(np)
	node_power = []
	collecting = []
	steering = []
	collected = []
	for i in n:
		node_power.append({})
		collecting.append({})
		steering.append({})
		collected.append({})
	if _static_version != map.owner_version:
		_static()
	var cmod := {}
	var nodes_of := {}                  # tag -> [nós onde tem poder]
	for k in _pids.size():
		var pid := _pids[k]
		var i := _pnode[k]
		local_value[i] += prov_value[pid]
		var owner: String = map.provinces[pid]["owner"]
		if owner == "":
			continue
		if not cmod.has(owner):
			cmod[owner] = maxf(0.0, 1.0 + _country_power_mod(owner))
			nodes_of[owner] = []
		prov_power[pid] = _pbase[k] * cmod[owner]
		var d: Dictionary = node_power[i]
		if not d.has(owner):
			d[owner] = 0.0
			nodes_of[owner].append(i)
		d[owner] += prov_power[pid]
	# capital comercial, poder global, mercadores
	var cap_power := _rule("trade_capital_power", 5.0)
	var non_cap := _rule("trade_non_capital_office", -0.5)
	var homes := {}
	merchants.clear()
	for tag in cmod:
		var h := home(tag)
		homes[tag] = h
		if h >= 0:
			node_power[h][tag] = float(node_power[h].get(tag, 0.0)) + cap_power
			collecting[h][tag] = true
	var gmod := {}
	for tag in cmod:
		gmod[tag] = maxf(0.0, 1.0 + power.modifier(tag, "global_trade_power"))
	for i in n:
		for tag in node_power[i]:
			node_power[i][tag] *= gmod[tag]
	var base_merchants := int(_rule("base_merchants", 2))
	var merchant_steer := _rule("trade_added_value_modifer", 0.05) * 2.0    # mercador puxando: +10% de poder
	for tag in cmod:
		var cand := []
		for i in nodes_of[tag]:
			if i != homes[tag]:
				cand.append(i)
		cand.sort_custom(func(a, b): return node_power[a][tag] > node_power[b][tag])
		var mine := []
		var h: int = homes[tag]
		for k in mini(base_merchants + int(power.modifier(tag, "merchants")), cand.size()):
			var i: int = cand[k]
			mine.append(i)
			if h >= 0 and reach[i].has(h):
				steering[i][tag] = true            # a capital fica rio abaixo: o mercador puxa o valor para lá
				node_power[i][tag] *= 1.0 + merchant_steer
			else:
				collecting[i][tag] = true          # sem caminho até a capital: coleta ali (−50% de poder)
				node_power[i][tag] *= maxf(0.0, 1.0 + non_cap)
		merchants[tag] = mine
	# de cima para baixo
	_income.clear()
	var present := _rule("trade_merchant_present", 0.1)
	var effs := {}
	for i in n:
		total_value[i] += local_value[i]
		var tot := 0.0
		var col := 0.0
		for tag in node_power[i]:
			tot += node_power[i][tag]
			if collecting[i].has(tag):
				col += node_power[i][tag]
		if tot <= 0.0:
			continue
		var v := total_value[i]
		for tag in collecting[i]:
			var share: float = v * node_power[i][tag] / tot
			if not effs.has(tag):
				effs[tag] = trade_efficiency(tag)
			var eff: float = 1.0 + effs[tag] + (present if i != homes.get(tag, -1) else 0.0)
			var inc := share * maxf(0.0, eff) / 12.0
			collected[i][tag] = inc
			_income[tag] = float(_income.get(tag, 0.0)) + inc
		# o resto desce pelas saídas, puxado por quem transfere
		var outs: Array = out_links[i]
		if outs.is_empty():
			continue
		for tag in node_power[i]:
			if collecting[i].has(tag):
				continue
			var flow: float = v * node_power[i][tag] / tot
			var h: int = homes.get(tag, -1)
			var target := -1
			if h >= 0:
				for j in outs:
					if j == h or reach[j].has(h):
						target = j
						break
			if target >= 0:
				total_value[target] += flow
			else:
				for j in outs:
					total_value[j] += flow / outs.size()
			outgoing_value[i] += flow


## Dados das províncias que só mudam com o dono: nó, valor comercial e poder antes dos
## modificadores do país (desenvolvimento, centro de comércio, costa, construções).
func _static() -> void:
	_static_version = map.owner_version
	var dev_tp := _rule("dev_trade_power", 0.2)
	var coastal_tp := _rule("coastal_trade_power", 0.25)
	_pids = PackedInt32Array()
	_pnode = PackedInt32Array()
	_pbase = PackedFloat32Array()
	prov_value = PackedFloat32Array()
	prov_value.resize(map.provinces.size())
	for p in map.provinces:
		if p["sea"]:
			continue
		var i := int(index.get(p.get("trade_node", ""), -1))
		if i < 0:
			continue
		var pid := int(p["id"])
		var gid: String = p.get("trade_goods", "")
		if gid != "gold" and map.trade_goods.has(gid):
			prov_value[pid] = float(p.get("base_production", 0)) * 0.2 * float(map.trade_goods[gid]["price"])
		var base := float(p["development"]) * dev_tp
		var cot := int(p.get("center_of_trade", 0))
		if cot > 0:
			var inland: bool = map.trade_nodes.get(p.get("trade_node", ""), {}).get("inland", false) \
					or not p.get("coastal", false)
			base += float(_cot.get("%s%d" % ["inland" if inland else "coastal", cot], 0.0))
		var mult := 1.0
		if p.get("coastal", false):
			mult += coastal_tp
		for bid in p.get("buildings", []):
			mult += float(map.buildings.get(bid, {}).get("modifiers", {}).get("province_trade_power_modifier", 0.0))
		_pids.append(pid)
		_pnode.append(i)
		_pbase.append(base * mult)


## Renda de comércio do país por mês.
func income(tag: String) -> float:
	return float(_income.get(tag, 0.0))


func node_of(pid: int) -> int:
	return int(index.get(map.provinces[pid].get("trade_node", ""), -1))


## Parte (0 a 1) do poder do país no nó `i`.
func share(tag: String, i: int) -> float:
	if i < 0 or i >= node_power.size():
		return 0.0
	var tot := 0.0
	for t in node_power[i]:
		tot += node_power[i][t]
	return float(node_power[i].get(tag, 0.0)) / tot if tot > 0.0 else 0.0
