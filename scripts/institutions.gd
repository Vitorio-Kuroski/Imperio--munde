class_name Institutions
extends RefCounted
## Instituições (mapa do EU4): Feudalismo, Renascimento, Colonialismo, Imprensa...
##  - Presença por província (0 a 100%). Em 1444 vem do "history" do common/institutions
##    (Feudalismo em boa parte da Eurásia); as outras surgem na data e na província históricas
##    (Renascimento em 1450 em Florença etc.).
##  - Espalham-se todo mês para as províncias de terra vizinhas de uma que já tem 100%:
##    +SPREAD_NEIGHBOR por mês (× difusão de instituições das ideias), +SPREAD_CAPITAL se a capital
##    do dono já tem.
##  - O país adota (embrace) pagando EMBRACE_COST_PER_DEV ducados por desenvolvimento que ainda não
##    tem a instituição, desde que ela esteja em pelo menos 10% do seu desenvolvimento. Em 1444 cada
##    país já adota as que estão em metade ou mais do seu desenvolvimento.
##  - Cada instituição esperada por uma tecnologia e não adotada encarece a pesquisa pelo valor
##    esperado (Feudalismo 50% -> +50%). As adotadas dão o seu bônus.

signal changed(tag: String)

const SPREAD_NEIGHBOR := 2.5
const SPREAD_CAPITAL := 1.0
const EMBRACE_MIN := 0.10
const START_EMBRACE := 0.5
const EMBRACE_COST_PER_DEV := 2.0

var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var list: Array = []             # instituições na ordem do arquivo
var by_id := {}
var born := {}                   # id -> true
var progress := {}               # id -> PackedFloat32Array (por província)
var front := {}                  # id -> {pid: true} províncias incompletas vizinhas de uma completa
var embraced := {}               # tag -> {id: true}
var _stats := {}                 # id -> tag -> [desenvolvimento total, desenvolvimento com a instituição]


func setup(m: MapView, c: GameClock, pw: MonarchPower, eco: Economy) -> void:
	map = m
	clock = c
	power = pw
	economy = eco
	list = map.institutions
	for inst in list:
		by_id[inst["id"]] = inst
		var arr := PackedFloat32Array()
		arr.resize(map.provinces.size())
		progress[inst["id"]] = arr
		front[inst["id"]] = {}
	for p in map.provinces:
		for iid in p.get("institutions", []):
			if progress.has(iid):
				progress[iid][int(p["id"])] = 100.0
				born[iid] = true
	for iid in born:
		_rebuild_front(iid)
	for tag in map.countries:
		embraced[tag] = {}
		for iid in born:
			if present(tag, iid) >= START_EMBRACE:
				embraced[tag][iid] = true
	clock.month_passed.connect(_on_month)


func enabled() -> bool:
	return not list.is_empty()


func name_of(iid: String) -> String:
	return by_id.get(iid, {}).get("name", iid)


func has_embraced(tag: String, iid: String) -> bool:
	return embraced.get(tag, {}).has(iid)


## A instituição mais recente que já surgiu (a que o modo de mapa mostra).
func focus() -> String:
	var f := ""
	for inst in list:
		if born.has(inst["id"]):
			f = inst["id"]
	return f


func province_progress(iid: String, pid: int) -> float:
	return float(progress[iid][pid]) if progress.has(iid) else 0.0


## Soma, numa passada, o desenvolvimento total e o com a instituição de cada país.
func _recount(iid: String) -> void:
	var st := {}
	var arr: PackedFloat32Array = progress[iid]
	for p in map.provinces:
		var tag: String = p["owner"]
		if tag == "":
			continue
		var d := maxf(1.0, float(p["development"]))
		if not st.has(tag):
			st[tag] = [0.0, 0.0]
		st[tag][0] += d
		st[tag][1] += d * arr[int(p["id"])] / 100.0
	_stats[iid] = st


func _stat(tag: String, iid: String) -> Array:
	if not progress.has(iid):
		return [0.0, 0.0]
	if not _stats.has(iid):
		_recount(iid)
	return _stats[iid].get(tag, [0.0, 0.0])


## Fração (0 a 1) do desenvolvimento do país em que a instituição está presente.
func present(tag: String, iid: String) -> float:
	var s := _stat(tag, iid)
	return s[1] / s[0] if s[0] > 0.0 else 0.0


## Custo para adotar: ducados por desenvolvimento que ainda não tem a instituição.
func embrace_cost(tag: String, iid: String) -> float:
	var s := _stat(tag, iid)
	return (s[0] - s[1]) * EMBRACE_COST_PER_DEV * maxf(0.0, 1.0 + power.modifier(tag, "embracement_cost"))


func can_embrace(tag: String, iid: String) -> bool:
	return born.has(iid) and not has_embraced(tag, iid) and present(tag, iid) >= EMBRACE_MIN \
			and economy.money(tag) >= embrace_cost(tag, iid)


func embrace(tag: String, iid: String) -> bool:
	if not can_embrace(tag, iid) or not economy.spend(tag, embrace_cost(tag, iid)):
		return false
	embraced[tag][iid] = true
	power.invalidate(tag)
	if tag == power.player:
		changed.emit(tag)
	return true


## Acréscimo no custo de uma tecnologia: soma do valor esperado das instituições não adotadas.
func tech_penalty(tag: String, tech: Dictionary) -> float:
	var pen := 0.0
	var exp: Dictionary = tech.get("institutions", {})
	for iid in exp:
		if by_id.has(iid) and not has_embraced(tag, iid):
			pen += float(exp[iid])
	return pen


## Bônus das instituições adotadas (somados em MonarchPower.modifier).
func modifiers(tag: String) -> Dictionary:
	var out := {}
	for iid in embraced.get(tag, {}):
		var b: Dictionary = by_id[iid].get("bonus", {})
		for k in b:
			if b[k] is float or b[k] is int:
				out[k] = float(out.get(k, 0.0)) + float(b[k])
	return out


func _land_neighbors(pid: int) -> Array:
	var out := []
	for q in map.provinces[pid]["neighbors"]:
		var qi := int(q)
		if qi > 0 and not map.provinces[qi]["sea"]:
			out.append(qi)
	return out


func _rebuild_front(iid: String) -> void:
	var f := {}
	var arr: PackedFloat32Array = progress[iid]
	for p in map.provinces:
		var pid := int(p["id"])
		if arr[pid] >= 100.0:
			for q in _land_neighbors(pid):
				if arr[q] < 100.0:
					f[q] = true
	front[iid] = f


func _date_num(s: String) -> int:
	var p := s.split(".")
	if p.size() < 3 or not p[0].is_valid_int():
		return 99999999
	return int(p[0]) * 10000 + int(p[1]) * 100 + int(p[2])


func _on_month() -> void:
	if list.is_empty():
		return
	var today := clock.year * 10000 + clock.month * 100 + clock.day
	# surgimento na data e província históricas
	for inst in list:
		var iid: String = inst["id"]
		if born.has(iid) or _date_num(inst.get("start_date", "")) > today:
			continue
		var sp := int(inst.get("start_province", 0))
		if sp > 0 and sp < map.provinces.size():
			progress[iid][sp] = 100.0
			born[iid] = true
			_stats.erase(iid)
			_rebuild_front(iid)
	# difusão pelas fronteiras
	for iid in born:
		var arr: PackedFloat32Array = progress[iid]
		var done := []
		for pid in front[iid]:
			var owner: String = map.provinces[pid]["owner"]
			var gain := SPREAD_NEIGHBOR
			if owner != "":
				gain *= maxf(0.0, 1.0 + power.modifier(owner, "global_institution_spread"))
				var cap := int(map.countries.get(owner, {}).get("capital", 0))
				if cap > 0 and arr[cap] >= 100.0:
					gain += SPREAD_CAPITAL
			arr[pid] = minf(100.0, arr[pid] + gain)
			if arr[pid] >= 100.0:
				done.append(pid)
		progress[iid] = arr
		_stats.erase(iid)
		for pid in done:
			front[iid].erase(pid)
			for q in _land_neighbors(pid):
				if arr[q] < 100.0:
					front[iid][q] = true
	# IA adota quando pode pagar e ainda sobra metade do tesouro
	for tag in map.countries:
		if tag == power.player:
			continue
		for iid in born:
			if not has_embraced(tag, iid) and present(tag, iid) >= EMBRACE_MIN \
					and embrace_cost(tag, iid) * 2.0 <= economy.money(tag):
				embrace(tag, iid)
	changed.emit(power.player)
