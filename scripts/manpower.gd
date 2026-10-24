class_name Manpower
extends RefCounted
## Efetivo (manpower) dos países, regras do EU4 (em milhares de homens, como o EU4 guarda):
##  - Máximo = (Σ das províncias: efetivo base × BASE_MP_TO_MANPOWER (0,25 = 250 homens) × (1 +
##    local_manpower_modifier do núcleo (+75%, modificador estático `core`) e das construções
##    (quartel...)) + local_manpower das construções + global_manpower (10 = 10 mil, valores
##    básicos do EU4) + efeitos) × (1 + global_manpower_modifier). Todas as províncias do país
##    contam como núcleo (o jogo ainda não tem núcleos separados) e a autonomia é 0.
##  - Recuperação por mês = máximo ÷ (MAX_MANPOWER anos × 12) × (1 + manpower_recovery_speed),
##    no mínimo MIN_MONTHLY_MANPOWER (100 homens); não passa do máximo.
##  - Em 1444 todo país começa com o efetivo cheio. Ainda não há exércitos que o gastem.

signal changed(tag: String)

var map: MapView
var clock: GameClock
var power: MonarchPower
var current := {}                  # tag -> efetivo atual (milhares)
var _max := {}                     # tag -> máximo (milhares), refeito quando um dono muda
var _version := -1
var _rules := {}


func setup(m: MapView, c: GameClock, pw: MonarchPower) -> void:
	map = m
	clock = c
	power = pw
	_rules = map.trade_rules
	_recount()
	for t in _max:
		current[t] = _max[t]
	clock.month_passed.connect(_on_month)


func _rule(k: String, default: float) -> float:
	return float(_rules.get(k, default))


## Efetivo que a província dá ao máximo do país (milhares), como o EU4: (efetivo base × 250 +
## local_manpower) × (1 + núcleo 0,75 + província de terra 0,25 (`land_province`) + cultura não aceita
## (−0,15 no mesmo grupo, `same_culture_group`; −0,33 fora, `non_accepted_culture`) + construções e
## modificadores) × (1 − autonomia local).
func province_manpower(p: Dictionary) -> float:
	if p["sea"] or p["owner"] == "":
		return 0.0
	var owner: String = p["owner"]
	var base := float(p.get("base_manpower", float(p["development"]) / 3.0))
	var mod := 1.0 + _static("land_province", 0.25) + map.building_mod(p, "local_manpower_modifier")
	if not p.has("cores") or owner in p["cores"]:
		mod += _rule("core_manpower", 0.75)
	var cul: String = p.get("culture", "")
	var c: Dictionary = map.countries.get(owner, {})
	var prim: String = c.get("primary_culture", "")
	if cul != "" and prim != "" and cul != prim and not (cul in c.get("accepted_cultures", [])):
		var same := _group_of(cul) != "" and _group_of(cul) == _group_of(prim)
		mod += _static("same_culture_group", -0.15) if same else _static("non_accepted_culture", -0.33)
	var autonomy := clampf(float(p.get("local_autonomy", 0.0)) / 100.0, 0.0, 1.0)
	return (base * _rule("base_mp_to_manpower", 0.25) + map.building_mod(p, "local_manpower")) * maxf(0.0, mod) \
			* (1.0 - autonomy)


var _statics := {}
var _groups := {}


## local_manpower_modifier de um modificador estático do EU4 (common/static_modifiers).
func _static(block: String, default: float) -> float:
	if not _statics.has(block):
		var v := default
		var tree = Eu4Data.merged("common/static_modifiers").get(block, [])
		if tree is Array:
			for kv in tree:
				if kv is Array and kv.size() == 2 and kv[0] == "local_manpower_modifier" and str(kv[1]).is_valid_float():
					v = float(str(kv[1]))
		_statics[block] = v
	return _statics[block]


func _group_of(cul: String) -> String:
	if _groups.is_empty():
		for id in map.cultures:
			_groups[id] = str(map.cultures[id].get("group", ""))
	return str(_groups.get(cul, ""))


func _recount() -> void:
	_version = map.owner_version
	var sums := {}
	for p in map.provinces:
		var t: String = p["owner"]
		if t != "" and not p["sea"]:
			sums[t] = float(sums.get(t, 0.0)) + province_manpower(p)
	_max.clear()
	var base := float(_rules.get("base_values", {}).get("global_manpower", 10))
	for t in sums:
		_max[t] = (float(sums[t]) + base + power.modifier(t, "global_manpower")) \
				* maxf(0.0, 1.0 + power.modifier(t, "global_manpower_modifier"))


func max_of(tag: String) -> float:
	if _version != map.owner_version:
		_recount()
	return float(_max.get(tag, 0.0))


func of(tag: String) -> float:
	return minf(float(current.get(tag, 0.0)), max_of(tag))


func monthly(tag: String) -> float:
	var m := max_of(tag)
	if m <= 0.0:
		return 0.0
	var rec := m / (_rule("max_manpower", 10) * 12.0) * maxf(0.0, 1.0 + power.modifier(tag, "manpower_recovery_speed"))
	return maxf(rec, _rule("min_monthly_manpower", 0.1))


## "12,3k" / "850" como no EU4.
static func fmt(thousands: float) -> String:
	if thousands < 1.0:
		return str(roundi(thousands * 1000.0))
	if thousands < 10.0:
		var s := "%.1f" % thousands
		if s.ends_with(".0"):           # como o EU4: "3k", não "3.0k"
			s = s.left(-2)
		return s.replace(".", Loc.dec) + "k"
	return "%dk" % roundi(thousands)


func _on_month() -> void:
	if _version != map.owner_version:
		_recount()
	for t in _max:
		var m: float = _max[t]
		var cur := float(current.get(t, m))
		if cur < m:
			current[t] = minf(m, cur + monthly(t))
		elif cur > m:
			current[t] = m
	if power.player != "":
		changed.emit(power.player)
