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
var clock: GameClock                    # main.gd define (viagem dos mercadores)
var power: MonarchPower
var nodes: Array = []                   # ids na ordem de processamento (de cima para baixo)
var index := {}                         # id -> posição
var out_links: Array = []               # posição -> [posições dos nós seguintes]
var reach: Array = []                   # posição -> {posição: true} nós alcançáveis descendo
var local_value: PackedFloat32Array     # valor gerado pelas províncias do nó
var total_value: PackedFloat32Array     # local + o que chega de cima
var outgoing_value: PackedFloat32Array  # o que desce para os nós seguintes
var node_power: Array = []              # posição -> {tag: poder}
var provincial: Array = []              # posição -> {tag: poder provincial (das províncias ali)}
var in_links: Array = []                # posição -> [posições dos nós imediatamente acima]
var collecting: Array = []              # posição -> {tag: true} quem coleta ali
var steering: Array = []                # posição -> {tag: true} quem tem mercador puxando o valor
var collected: Array = []               # posição -> {tag: ducados por mês}
var prov_value: PackedFloat32Array      # por província
var prov_power: PackedFloat32Array
var merchants := {}                     # tag -> [posições dos nós com mercador]
var arrival := {}                       # "tag|nó" -> dia (unix ÷ 86400) em que o mercador chega
var dev := {}                           # tag -> desenvolvimento total (para o poder de caravana)
var _income := {}                       # tag -> ducados por mês
var _cot := {}                          # "coastal1" -> poder
var _rules := {}
var _static_version := -1               # dados fixos das províncias (refeitos quando um dono muda)
var _pids := PackedInt32Array()         # províncias de terra com nó
var _pnode := PackedInt32Array()
var _pbase := PackedFloat32Array()      # poder básico da província (desenvolvimento + centro de comércio)
var _pmul := PackedFloat32Array()       # 1 + modificadores locais (costa, construções)
var _tech_eff := PackedFloat32Array()   # eficiência comercial somada da tecnologia dip até cada nível
var _tech_range := PackedFloat32Array() # alcance comercial somado da tecnologia dip até cada nível

const PROPAGATE_MIN := 10.0             # poder provincial mínimo para propagar rio acima (wiki do EU4)
const AUTONOMY_TRADE_POWER := -0.5    # local_autonomy_multiplicative do EU4
const MERCHANT_POWER := 2.0             # poder do mercador no nó (wiki do EU4)
const MAX_STEER_BONUS_MERCHANTS := 5    # além de 5 mercadores numa rota o valor não sobe mais


func setup(m: MapView, pw: MonarchPower) -> void:
	map = m
	power = pw
	_rules = map.trade_rules
	for c in map.centers_of_trade:
		_cot["%s%d" % [c["type"], int(c["level"])]] = float(c["trade_power"])
	_order_nodes()
	var s := 0.0
	var rg := 0.0
	for t in map.technologies.get("dip", []):
		s += float(t.get("modifiers", {}).get("trade_efficiency", 0.0))
		rg += float(t.get("modifiers", {}).get("trade_range", 0.0))
		_tech_eff.append(s)
		_tech_range.append(rg)
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
	in_links.resize(nodes.size())
	for i in nodes.size():
		in_links[i] = []
	reach.resize(nodes.size())
	for i in nodes.size():
		var outs := []
		for o in map.trade_nodes[nodes[i]].get("outgoing", []):
			if index.has(o["to"]) and index[o["to"]] > i:
				outs.append(index[o["to"]])
		out_links[i] = outs
		for j in outs:
			in_links[j].append(i)
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


## Recalcula valores, poderes e a renda de comércio de todos (uma vez por mês), pelas regras do EU4
## (wiki "Trade" e as constantes NEconomy do defines.lua):
##  - poder provincial no nó = Σ das províncias do país ali (`_static` × mercantilismo/ideias);
##  - quem tem ≥ PROPAGATE_MIN (10) de poder provincial num nó manda 1/TRADE_PROPAGATE_DIVIDER (20%)
##    dele a cada nó imediatamente acima ("transfers from traders downstream"), sem os modificadores
##    globais;
##  - + TRADE_CAPITAL_POWER (5) no nó da capital comercial, + caravana se esse nó é do interior,
##    + MERCHANT_POWER (2) onde há mercador; tudo × (1 + global_trade_power + TRADE_POWER_HOME_BONUS
##    (10%) por mercador direcionando, no nó da capital, se nenhum coleta fora dela); coletar fora
##    da capital: × (1 + TRADE_NON_CAPITAL_OFFICE) (−50%). O mercador só vale depois de chegar
##    (`arrival`): em 11/11/1444 os do EU4 ainda estão a caminho (Suécia: Krakow 7,97 = 20% do
##    poder provincial no Báltico, sem os +2);
##  - em cada nó, de cima para baixo, só contam os que coletam e os que transferem para baixo
##    (quem tem a capital rio acima fica fora): coletor leva valor × poder ÷ poder efetivo, e o
##    valor × poder dos que transferem ÷ poder efetivo desce. Só os mercadores escolhem a saída
##    (poder × (1 + trade_steering)); sem eles, divide igual. Cada mercador numa rota aumenta o
##    valor nela em TRADE_ADDED_VALUE_MODIFER (5%) ÷ n (n-ésimo mercador) × (1 + trade_steering);
##  - renda = valor coletado × (max(1 + eficiência, 1%) + TRADE_MERCHANT_PRESENT (10%) com
##    mercador) ÷ 12;
##  - mercadores (sozinhos, como a IA do EU4): direcionam para a capital nos nós rio acima dela ao
##    alcance comercial, os de maior valor primeiro; os que sobram coletam onde o país tem mais poder.
func recompute() -> void:
	if nodes.is_empty():
		return
	var n := nodes.size()
	var np := map.provinces.size()
	var last_value := total_value          # valor do mês anterior (escolha dos mercadores)
	local_value = PackedFloat32Array()
	local_value.resize(n)
	total_value = PackedFloat32Array()
	total_value.resize(n)
	outgoing_value = PackedFloat32Array()
	outgoing_value.resize(n)
	prov_power = PackedFloat32Array()
	prov_power.resize(np)
	node_power = []
	provincial = []
	collecting = []
	steering = []
	collected = []
	for i in n:
		node_power.append({})
		provincial.append({})
		collecting.append({})
		steering.append({})
		collected.append({})
	if _static_version != map.owner_version:
		_static()
	var cmod := {}
	var owned := {}                     # tag -> [províncias] (alcance comercial)
	dev.clear()
	for k in _pids.size():
		var pid := _pids[k]
		var i := _pnode[k]
		local_value[i] += prov_value[pid]
		var owner: String = map.provinces[pid]["owner"]
		if owner == "":
			continue
		if not cmod.has(owner):
			cmod[owner] = _country_power_mod(owner)
			owned[owner] = []
			dev[owner] = 0.0
		dev[owner] += float(map.provinces[pid].get("development", 0))
		owned[owner].append(pid)
		# local (costa, construções) e do país (mercantilismo, ideias) somam no mesmo modificador, como no EU4
		prov_power[pid] = _pbase[k] * maxf(0.0, _pmul[k] + cmod[owner])
		provincial[i][owner] = float(provincial[i].get(owner, 0.0)) + prov_power[pid]
	if last_value.size() != n:
		last_value = local_value
	# poder antes dos modificadores globais: provincial + o que vem dos nós de baixo
	var raw := []
	for i in n:
		raw.append(provincial[i].duplicate())
	var frac := 1.0 / maxf(1.0, float(Eu4Data.define("NEconomy", "TRADE_PROPAGATE_DIVIDER", 5)))
	for i in n:
		for tag in provincial[i]:
			var pv: float = provincial[i][tag]
			if pv < PROPAGATE_MIN:
				continue
			for j in in_links[i]:
				raw[j][tag] = float(raw[j].get(tag, 0.0)) + pv * frac
	# capital comercial e mercadores
	var homes := {}
	merchants.clear()
	var target := {}                    # "tag|nó" -> saída escolhida pelo mercador que direciona
	var outside := {}                   # tag -> true se um mercador coleta fora da capital
	var base_merchants := int(_rule("base_merchants", 2))
	var today := _today()
	var new_arrival := {}
	for tag in cmod:
		var h := home(tag)
		homes[tag] = h
		if h < 0:
			continue
		var cnt := base_merchants + int(power.modifier(tag, "merchants"))
		var steer_c := []
		for i in n:
			if i != h and reach[i].has(h) and _in_range(tag, i, owned[tag]):
				steer_c.append(i)
		steer_c.sort_custom(func(x, y): return last_value[x] > last_value[y])
		var mine := []
		for i in steer_c:
			if mine.size() >= cnt:
				break
			mine.append(i)
			if _present(tag, i, today, new_arrival):
				steering[i][tag] = true
			for j in out_links[i]:
				if j == h or reach[j].has(h):
					target["%s|%d" % [tag, i]] = j
					break
		if mine.size() < cnt:           # sem mais nós para direcionar: coleta onde tem mais poder
			var col_c := []
			for i in n:
				if i != h and not (i in mine) and float(provincial[i].get(tag, 0.0)) > 0.0:
					col_c.append(i)
			col_c.sort_custom(func(x, y): return provincial[x][tag] > provincial[y][tag])
			for i in col_c:
				if mine.size() >= cnt:
					break
				mine.append(i)
				if _present(tag, i, today, new_arrival):
					collecting[i][tag] = true
					outside[tag] = true
		merchants[tag] = mine
	arrival = new_arrival
	var cap_power := float(Eu4Data.define("NEconomy", "TRADE_CAPITAL_POWER", _rule("trade_capital_power", 5.0)))
	var non_cap := float(Eu4Data.define("NEconomy", "TRADE_NON_CAPITAL_OFFICE", _rule("trade_non_capital_office", -0.5)))
	var home_bonus := float(Eu4Data.define("NEconomy", "TRADE_POWER_HOME_BONUS", 0.1))
	var home_bonus_max := float(Eu4Data.define("NEconomy", "TRADE_POWER_HOME_BONUS_MAX", 1.0))
	for tag in homes:
		var h: int = homes[tag]
		if h < 0:
			continue
		raw[h][tag] = float(raw[h].get(tag, 0.0)) + cap_power
		if map.trade_nodes.get(nodes[h], {}).get("inland", false):
			raw[h][tag] += caravan_power(tag)     # bônus de caravana: nó da capital do interior
		collecting[h][tag] = true
		for i in merchants[tag]:
			if today >= int(arrival.get("%s|%d" % [tag, i], 0)):
				raw[i][tag] = float(raw[i].get(tag, 0.0)) + MERCHANT_POWER
	var gmod := {}
	for i in n:
		for tag in raw[i]:
			if not gmod.has(tag):
				gmod[tag] = power.modifier(tag, "global_trade_power")
			var m: float = 1.0 + gmod[tag]
			var h: int = homes.get(tag, -1)
			if i == h and not outside.has(tag):    # +10% por mercador direcionando (já chegado)
				var ns := 0
				for k in merchants.get(tag, []):
					if steering[k].has(tag):
						ns += 1
				m += minf(home_bonus_max, home_bonus * ns)
			if collecting[i].has(tag) and i != h:
				m *= 1.0 + non_cap
			node_power[i][tag] = float(raw[i][tag]) * maxf(0.0, m)
	# valor de cima para baixo
	_income.clear()
	var present := float(Eu4Data.define("NEconomy", "TRADE_MERCHANT_PRESENT", _rule("trade_merchant_present", 0.1)))
	var added := float(Eu4Data.define("NEconomy", "TRADE_ADDED_VALUE_MODIFER", _rule("trade_added_value_modifer", 0.05)))
	var effs := {}
	var steer_mod := {}
	for i in n:
		total_value[i] += local_value[i]
		var col := 0.0
		var trans := 0.0
		for tag in node_power[i]:
			var p: float = node_power[i][tag]
			if collecting[i].has(tag):
				col += p
			else:
				var h: int = homes.get(tag, -1)
				if h >= 0 and reach[i].has(h):
					trans += p           # quem tem a capital rio acima (ou sem caminho) não conta
		var eff_total := col + trans
		if eff_total <= 0.0:
			continue
		var v := total_value[i]
		for tag in collecting[i]:
			var share: float = v * node_power[i][tag] / eff_total
			if not effs.has(tag):
				effs[tag] = trade_efficiency(tag)
			var mult := maxf(1.0 + effs[tag], 0.01) + (present if i != homes.get(tag, -1) else 0.0)
			var inc := share * mult / 12.0
			collected[i][tag] = inc
			_income[tag] = float(_income.get(tag, 0.0)) + inc
		var outs: Array = out_links[i]
		if outs.is_empty() or trans <= 0.0:
			continue
		var outgoing := v * trans / eff_total
		outgoing_value[i] = outgoing
		# saídas: poder dos mercadores que direcionam × (1 + trade_steering); bônus de valor por mercador
		var pull := {}
		var count := {}
		var boost := {}
		var tot_pull := 0.0
		for tag in steering[i]:
			var j: int = target.get("%s|%d" % [tag, i], -1)
			if j < 0:
				continue
			if not steer_mod.has(tag):
				steer_mod[tag] = power.modifier(tag, "trade_steering")
			var sp: float = float(node_power[i].get(tag, 0.0)) * maxf(0.0, 1.0 + steer_mod[tag])
			pull[j] = float(pull.get(j, 0.0)) + sp
			tot_pull += sp
			count[j] = int(count.get(j, 0)) + 1
			if count[j] <= MAX_STEER_BONUS_MERCHANTS:
				boost[j] = float(boost.get(j, 0.0)) + added / float(count[j]) * maxf(0.0, 1.0 + steer_mod[tag])
		for j in outs:
			var part: float = outgoing * (float(pull.get(j, 0.0)) / tot_pull if tot_pull > 0.0 else 1.0 / outs.size())
			total_value[j] += part * (1.0 + float(boost.get(j, 0.0)))


## O mercador do país no nó `i` já chegou? Marca a chegada dos novos: distância da capital ao
## centro do nó ÷ MERCHANT_SPEED (20 px por dia) — APROXIMAÇÃO: o EU4 não publica a fórmula.
func _present(tag: String, i: int, today: int, new_arrival: Dictionary) -> bool:
	var key := "%s|%d" % [tag, i]
	if arrival.has(key):
		new_arrival[key] = arrival[key]
	else:
		var cap := int(map.countries.get(tag, {}).get("capital", -1))
		var loc := int(map.trade_nodes.get(nodes[i], {}).get("location", -1))
		var days := 0
		if cap > 0 and cap < map.provinces.size() and loc > 0 and loc < map.provinces.size():
			days = ceili(map.province_center(cap).distance_to(map.province_center(loc))
					/ maxf(1.0, float(Eu4Data.define("NEconomy", "MERCHANT_SPEED", 20.0))))
		new_arrival[key] = today + days
	return today >= int(new_arrival[key])


func _today() -> int:
	if clock == null:
		return 1 << 30                  # sem relógio: todos já chegaram
	return int(Time.get_unix_time_from_datetime_dict({"year": clock.year, "month": clock.month, "day": clock.day,
			"hour": 0, "minute": 0, "second": 0}) / 86400)


## O nó `i` está ao alcance comercial do país (distância do centro do nó até a província mais perto)?
func _in_range(tag: String, i: int, provs: Array) -> bool:
	var loc := int(map.trade_nodes.get(nodes[i], {}).get("location", -1))
	if loc <= 0 or loc >= map.provinces.size():
		return true
	var c := map.province_center(loc)
	var r := trade_range(tag)
	var r2 := r * r
	for pid in provs:
		if map.province_center(pid).distance_squared_to(c) <= r2:
			return true
	return false


## Alcance comercial: Σ trade_range das tecnologias dip × (1 + trade_range_modifier).
func trade_range(tag: String) -> float:
	var lvl := TechWindow.level_of(map, tag, "dip", power)
	var r := _tech_range[clampi(lvl, 0, _tech_range.size() - 1)] if not _tech_range.is_empty() else 0.0
	return r * maxf(0.0, 1.0 + power.modifier(tag, "trade_range_modifier"))


## Dados das províncias que só mudam com o dono: nó, valor comercial e poder antes dos
## modificadores do país (desenvolvimento, centro de comércio, costa, construções).
func _static() -> void:
	_static_version = map.owner_version
	var dev_tp := _rule("dev_trade_power", 0.2)
	var coastal_tp := _rule("coastal_trade_power", 0.25)
	_pids = PackedInt32Array()
	_pnode = PackedInt32Array()
	_pbase = PackedFloat32Array()
	_pmul = PackedFloat32Array()
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
			prov_value[pid] = map.goods_produced(p) * float(map.trade_goods[gid]["price"])
		var base := float(p["development"]) * dev_tp + map.building_mod(p, "province_trade_power_value")
		var cot := int(p.get("center_of_trade", 0))
		if cot > 0:
			var inland: bool = map.trade_nodes.get(p.get("trade_node", ""), {}).get("inland", false) \
					or not p.get("coastal", false)
			base += float(_cot.get("%s%d" % ["inland" if inland else "coastal", cot], 0.0))
		var mult := 1.0
		if p.get("coastal", false):
			mult += coastal_tp
		# autonomia local (local_autonomy_multiplicative: province_trade_power_modifier −0,5 × autonomia)
		mult += AUTONOMY_TRADE_POWER * float(p.get("local_autonomy", 0.0)) / 100.0
		mult += map.building_mod(p, "province_trade_power_modifier")   # construções e modificadores da província
		_pids.append(pid)
		_pnode.append(i)
		_pbase.append(base)
		_pmul.append(mult)


## Poder de caravana ("Inland bonus" da aba Comércio): desenvolvimento ÷ CARAVAN_FACTOR (3), entre
## CARAVAN_POWER_MIN (2) e MAX (50), × (1 + caravan_power). Soma ao poder no nó da capital comercial
## quando ele é do interior.
func caravan_power(tag: String) -> float:
	var f := maxf(0.001, float(Eu4Data.define("NEconomy", "CARAVAN_FACTOR", 3.0)))
	var v := clampf(float(dev.get(tag, 0.0)) / f, float(Eu4Data.define("NEconomy", "CARAVAN_POWER_MIN", 2.0)),
			float(Eu4Data.define("NEconomy", "CARAVAN_POWER_MAX", 50.0)))
	return v * maxf(0.0, 1.0 + power.modifier(tag, "caravan_power"))


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
