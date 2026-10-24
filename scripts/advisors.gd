class_name Advisors
extends RefCounted
## Conselheiros (mapa do EU4): um por categoria (adm/dip/mil). Cada um soma o seu nível (1 a 3)
## aos pontos de monarca da categoria e dá o efeito do seu tipo (common/advisortypes). Salário
## mensal = nível² ducados × (1 + custo de conselheiros das ideias).
## Candidatos: os conselheiros históricos (history/advisors) vivos na data e nascidos numa
## província do país, mais candidatos gerados até 3 por categoria; renovados todo ano.
## A IA contrata o candidato mais barato quando o saldo mensal cobre o salário.

signal changed(tag: String)

const CATS := ["adm", "dip", "mil"]
const POOL_SIZE := 3

var map: MapView
var clock: GameClock
var power: MonarchPower
var economy: Economy
var types := {}                  # id -> {name, category, modifiers}
var by_cat := {"adm": [], "dip": [], "mil": []}
var hired := {}                  # tag -> {cat: conselheiro}
var pool := {}                   # tag -> {cat: [conselheiros]}
var _used := {}                  # ids de conselheiros históricos já contratados
var _rng := RandomNumberGenerator.new()


func setup(m: MapView, c: GameClock, pw: MonarchPower, eco: Economy) -> void:
	map = m
	clock = c
	power = pw
	economy = eco
	for t in map.advisor_types:
		types[t["id"]] = t
		if by_cat.has(t["category"]):
			by_cat[t["category"]].append(t["id"])
	_rng.randomize()
	clock.month_passed.connect(_on_month)
	clock.year_passed.connect(func(): pool.clear())     # candidatos novos todo ano


func enabled() -> bool:
	return not types.is_empty()


## Salário mensal: nível² × (1 + advisor_cost), +0,5% por ano desde 1444 e a inflação do país.
func salary(tag: String, a: Dictionary) -> float:
	var s := int(a["skill"])
	var years := maxi(0, clock.year - 1444)
	var infl := economy.inflation_of(tag) / 100.0 if economy else 0.0
	return s * s * maxf(0.1, 1.0 + power.modifier(tag, "advisor_cost")) * (1.0 + 0.005 * years) * (1.0 + infl)


func total_salary(tag: String) -> float:
	var t := 0.0
	for cat in hired.get(tag, {}):
		t += salary(tag, hired[tag][cat])
	return t


func get_hired_count(tag: String) -> int:
	return hired.get(tag, {}).size()


func get_hired(tag: String, cat: String) -> Dictionary:
	return hired.get(tag, {}).get(cat, {})


func skill(tag: String, cat: String) -> int:
	return int(get_hired(tag, cat).get("skill", 0))


## Efeitos dos conselheiros contratados (somados aos das ideias em MonarchPower.modifier).
func modifiers(tag: String) -> Dictionary:
	var out := {}
	for cat in hired.get(tag, {}):
		var t: Dictionary = types.get(hired[tag][cat]["type"], {})
		for k in t.get("modifiers", {}):
			var v = t["modifiers"][k]
			if v is float or v is int:
				out[k] = float(out.get(k, 0.0)) + float(v)
	return out


## Candidatos do país numa categoria (gera na primeira consulta do ano).
func candidates(tag: String, cat: String) -> Array:
	if not pool.has(tag):
		pool[tag] = _make_pool(tag)
	return pool[tag].get(cat, [])


func hire(tag: String, cat: String, idx: int) -> bool:
	var c := candidates(tag, cat)
	if idx < 0 or idx >= c.size() or economy.money(tag) < salary(tag, c[idx]):
		return false
	var a: Dictionary = c[idx]
	if not hired.has(tag):
		hired[tag] = {}
	if hired[tag].has(cat):
		dismiss(tag, cat)
	hired[tag][cat] = a
	c.remove_at(idx)
	if a.has("id"):
		_used[a["id"]] = true
	power.invalidate(tag)
	if tag == power.player:
		changed.emit(tag)
	return true


func dismiss(tag: String, cat: String) -> void:
	if hired.get(tag, {}).has(cat):
		hired[tag].erase(cat)
		power.invalidate(tag)
		if tag == power.player:
			changed.emit(tag)


func dismiss_most_expensive(tag: String) -> bool:
	var best := ""
	for cat in hired.get(tag, {}):
		if best == "" or int(hired[tag][cat]["skill"]) > int(hired[tag][best]["skill"]):
			best = cat
	if best == "":
		return false
	dismiss(tag, best)
	return true


func _date_num(s: String) -> int:
	var p := s.split(".")
	if p.size() < 1 or not p[0].is_valid_int():
		return 0
	return int(p[0]) * 10000 + (int(p[1]) if p.size() > 1 else 1) * 100 + (int(p[2]) if p.size() > 2 else 1)


func _make_pool(tag: String) -> Dictionary:
	var out := {"adm": [], "dip": [], "mil": []}
	var today := clock.year * 10000 + clock.month * 100 + clock.day
	# históricos: vivos hoje e nascidos numa província do país
	for a in map.advisors:
		if _used.has(a.get("id", -1)):
			continue
		var loc := int(a["location"])
		if loc >= map.provinces.size() or map.provinces[loc]["owner"] != tag:
			continue
		if _date_num(a.get("date", "1.1.1")) > today or _date_num(a.get("death_date", "9999.1.1")) <= today:
			continue
		var t: Dictionary = types[a["type"]]
		var adv := {"name": a["name"], "type": a["type"], "skill": clampi(int(a.get("skill", 1)), 1, 3),
				"category": t["category"], "historical": true, "id": a.get("id", -1), "location": loc,
				"age": _random_age()}
		if out.has(t["category"]) and out[t["category"]].size() < POOL_SIZE:
			out[t["category"]].append(adv)
	# gerados até completar (nascidos numa província do país)
	var mine := map.provinces_of(tag)
	for cat in CATS:
		while out[cat].size() < POOL_SIZE and not by_cat[cat].is_empty():
			var tid: String = by_cat[cat][_rng.randi() % by_cat[cat].size()]
			var r := _rng.randf()
			var sk := 1 if r < 0.6 else (2 if r < 0.9 else 3)
			var adv := {"name": types[tid]["name"], "type": tid, "skill": sk, "category": cat, "age": _random_age()}
			if not mine.is_empty():
				adv["location"] = int(mine[_rng.randi() % mine.size()]["id"])
			out[cat].append(adv)
	return out


## Idade de um conselheiro novo: ADVISOR_MIN/MAX_DEFAULT_AGE do EU4 (18–60), sorteada.
func _random_age() -> int:
	return _rng.randi_range(int(Eu4Data.define("NCountry", "ADVISOR_MIN_DEFAULT_AGE", 18)),
			int(Eu4Data.define("NCountry", "ADVISOR_MAX_DEFAULT_AGE", 60)))


func _on_month() -> void:
	if not enabled():
		return
	for tag in map.countries:
		if tag == power.player or get_hired_count(tag) == 3:
			continue
		var bal := economy.balance(tag)
		if bal <= 1.0 or economy.money(tag) <= 0.0:
			continue
		for cat in CATS:
			if not get_hired(tag, cat).is_empty():
				continue
			var c := candidates(tag, cat)
			var best := -1
			for i in c.size():
				if best < 0 or int(c[i]["skill"]) < int(c[best]["skill"]):
					best = i
			# a IA só contrata se o saldo mensal continuar positivo
			if best >= 0 and bal > salary(tag, c[best]):
				bal -= salary(tag, c[best])
				hire(tag, cat, best)
