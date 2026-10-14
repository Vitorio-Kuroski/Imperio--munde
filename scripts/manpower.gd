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


## Efetivo que a província dá ao máximo do país (milhares).
func province_manpower(p: Dictionary) -> float:
	if p["sea"] or p["owner"] == "":
		return 0.0
	var base := float(p.get("base_manpower", float(p["development"]) / 3.0))
	return base * _rule("base_mp_to_manpower", 0.25) * maxf(0.0, 1.0 + _rule("core_manpower", 0.75) \
			+ map.building_mod(p, "local_manpower_modifier")) + map.building_mod(p, "local_manpower")


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
		return ("%.1fk" % thousands).replace(".", Loc.dec)
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
