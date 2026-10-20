class_name Estates
extends RefCounted
## Estamentos do EU4 (common/estates, common/estate_privileges, common/estate_crown_land e as
## constantes ESTATE_* do NCountry), com os números conferidos nas dicas do EU4 (Suécia e Noruega,
## 11/11/1444):
##  - estamentos do país = os de common/estates cujo `trigger` vale (clero, nobreza, burgueses...);
##  - influência (0–100) = base_influence + influence_modifier cujo trigger vale + `<estamento>_
##    influence_modifier` do país × 100 (reformas: monarchy_mechanic e feudalism_reform +5 para a
##    nobreza) + `influence` dos privilégios × 100 + terras × ESTATE_INFLUENCE_PER_DEV (0,5) ×
##    influence_from_dev_modifier (até ESTATE_MAX_INFLUENCE_FROM_DEV). Suécia: nobreza 42 (EU4 42),
##    burgueses 23,5 (23), clero 15,5 (15); Noruega: 65, 10, 20 (iguais);
##  - terras (% do país): na partida cada estamento recebe 2 × a influência sem terras (ainda sem
##    renda comercial e sem os privilégios), até 100 −
##    ESTATE_MIN_DISTRIBUTED_CROWNLAND (30) no total (reduz na proporção); depois os
##    change_estate_land_share e os land_share dos privilégios do history/countries — APROXIMAÇÃO
##    (o EU4 não publica a regra), que dá as terras exatas da Suécia (17/11/45) e da Noruega
##    (10/20/50); coroa = o resto;
##  - lealdade (0–100) começa em 50 (como no EU4) e anda para o equilíbrio = ESTATE_DEFAULT_LOYALTY
##    (30) + land_ownership_modifier × terras + loyalty_modifier cujo trigger vale + `<estamento>_
##    loyalty_modifier` do país × 100 + `loyalty` dos privilégios × 100, de ESTATE_LOYALTY_DECAY_
##    BASE_MIN (2) a _MAX (5) pontos por ano conforme a distância;
##  - efeitos no país: country_modifier_happy (lealdade ≥ ESTATE_HAPPY_THRESHOLD 60) / _neutral /
##    _angry (< ESTATE_ANGRY_THRESHOLD 30) × a faixa da influência (< 20: ¼, < 40: ½, < 60: ¾,
##    senão 1 — ESTATE_INFLUENCE_LEVEL_1/2/3), mais benefits/penalties dos privilégios,
##    modifier_by_land_ownership × terras do estamento e o bônus da terra da coroa
##    (estate_crown_land). Burgueses neutros com 23% = +10% de eficiência comercial (EU4: +10%).
## Ainda não há: conceder/revogar privilégios, agendas, tomar/vender terras, desastres de estamento.

signal changed(tag: String)

const START_LOYALTY := 50.0

var map: MapView
var clock: GameClock
var power: MonarchPower
var cbs: CasusBelli
var economy: Economy
var defs := {}                      # id -> árvore (common/estates)
var privs := {}                     # id -> árvore (common/estate_privileges)
var crown_bonus := []               # [{from, to, modifier}] (estate_crown_land)
var of := {}                        # tag -> [ids dos estamentos do país]
var land := {}                      # tag -> {id: % das terras}
var loyalty := {}                   # tag -> {id: lealdade}
var privileges := {}                # tag -> [ids dos privilégios]
var _eff := {}                      # tag -> efeitos somados (refeitos todo mês)
var _inf_mods := {}                 # id -> [[trigger, influência]] (sem o EST_VAL_COT)
var _loy_mods := {}                 # id -> [[trigger, lealdade]]
var _base_cache := {}               # "tag|id" -> influência sem terras (do mês)
var _eq_cache := {}                 # "tag|id" -> equilíbrio da lealdade (do mês)
var _busy := false
var _month := 0
var _slots := {}


func _slot(t: String) -> int:
	if not _slots.has(t):
		_slots[t] = _slots.size() % 12
	return _slots[t]


func setup(m: MapView, c: GameClock, pw: MonarchPower, cb: CasusBelli, eco: Economy) -> void:
	map = m
	clock = c
	power = pw
	cbs = cb
	economy = eco
	defs = Eu4Data.merged("common/estates")
	privs = Eu4Data.merged("common/estate_privileges")
	for f in Eu4Data.folder("common/estate_crown_land").values():
		for kv in f:
			if kv[0] == "bonus" and kv[1] is Array:
				crown_bonus.append({"from": _num(kv[1], "range_from", -100.0), "to": _num(kv[1], "range_to", 100.0),
						"modifier": _mods(tget(kv[1], "modifier"))})
	if defs.is_empty():
		return
	for id in defs:
		var im := []
		var lm := []
		for kv in defs[id]:
			if not (kv[1] is Array) or not (kv[0] == "influence_modifier" or kv[0] == "loyalty_modifier"):
				continue
			var trig = tget(kv[1], "trigger")
			if not (trig is Array):
				continue
			if kv[0] == "influence_modifier":
				if not JSON.stringify(trig).contains("province_has_center_of_trade_of_level"):
					im.append([trig, _num(kv[1], "influence", 0.0)])
			else:
				lm.append([trig, _num(kv[1], "loyalty", 0.0)])
		_inf_mods[id] = im
		_loy_mods[id] = lm
	_start()
	clock.month_passed.connect(_on_month)


func enabled() -> bool:
	return not defs.is_empty()


# ------------------------------------------------------------------ árvores
static func tget(tree: Variant, key: String) -> Variant:
	if tree is Array:
		for kv in tree:
			if kv is Array and kv.size() == 2 and kv[0] == key:
				return kv[1]
	return null


static func _num(tree: Variant, key: String, default: float) -> float:
	var v = tget(tree, key)
	return float(str(v)) if v != null and str(v).is_valid_float() else default


## Efeitos numéricos de um bloco de modificadores.
static func _mods(tree: Variant) -> Dictionary:
	var d := {}
	if tree is Array:
		for kv in tree:
			if kv is Array and kv.size() == 2 and not (kv[1] is Array) and str(kv[1]).is_valid_float():
				d[str(kv[0])] = float(d.get(str(kv[0]), 0.0)) + float(str(kv[1]))
	return d


static func short(id: String) -> String:
	return id.trim_prefix("estate_")


# ------------------------------------------------------------------ partida
func _start() -> void:
	var hist := _history()
	var max_land := 100.0 - float(Eu4Data.define("NCountry", "ESTATE_MIN_DISTRIBUTED_CROWNLAND", 30.0))
	for t in map.countries:
		if map.provinces_of(t).is_empty():
			continue
		var mine := []
		for id in defs:
			var trig = tget(defs[id], "trigger")
			if trig is Array and cbs.check(trig, t, t) == true:
				mine.append(id)
		if mine.is_empty():
			continue
		of[t] = mine
		var h: Dictionary = hist.get(t, {})
		privileges[t] = (h.get("privileges", []) as Array).filter(func(p): return privs.has(p))
		var l := {}
		var tot := 0.0
		for id in mine:
			l[id] = maxf(0.0, 2.0 * _influence_base(t, id, true))
			tot += l[id]
		if tot > max_land and tot > 0.0:
			for id in l:
				l[id] *= max_land / tot
		for ch in h.get("land", []):
			if l.has(ch[0]):
				l[ch[0]] = clampf(float(l[ch[0]]) + float(ch[1]), 0.0, 100.0)
		for p in privileges[t]:
			var e := _estate_of_privilege(p)
			if l.has(e):
				l[e] = float(l[e]) + _num(privs[p], "land_share", 0.0)
		land[t] = l
		var lo := {}
		for id in mine:
			lo[id] = START_LOYALTY
		loyalty[t] = lo
	for t in of:
		_eff[t] = _compute(t)


## Privilégios e mudanças de terra do history/countries até a data de início.
func _history() -> Dictionary:
	var out := {}
	var cutoff := clock.year * 10000 + clock.month * 100 + clock.day
	for fname in Eu4Data.folder("history/countries"):
		var tag := str(fname).substr(0, 3)
		var seq := []
		var dated := []
		for kv in Eu4Data.folder("history/countries")[fname]:
			var k := str(kv[0])
			var parts := k.split(".")
			if parts.size() == 3 and parts[0].is_valid_int() and kv[1] is Array:
				dated.append([int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2]), kv[1]])
			else:
				seq.append(kv)
		dated.sort_custom(func(a, b): return a[0] < b[0])
		for d in dated:
			if d[0] <= cutoff:
				seq.append_array(d[1])
		var pr := []
		var ld := []
		for kv in seq:
			match str(kv[0]):
				"set_estate_privilege":
					if not (str(kv[1]) in pr):
						pr.append(str(kv[1]))
				"remove_estate_privilege":
					pr.erase(str(kv[1]))
				"change_estate_land_share":
					var e = tget(kv[1], "estate")
					if e != null:
						ld.append([str(e), _num(kv[1], "share", 0.0)])
		if not pr.is_empty() or not ld.is_empty():
			out[tag] = {"privileges": pr, "land": ld}
	return out


func _estate_of_privilege(p: String) -> String:
	for id in defs:
		if p.begins_with(id + "_"):
			return id
	return ""


# ------------------------------------------------------------------ valores
func has(tag: String, id: String) -> bool:
	return id in of.get(tag, [])


func land_of(tag: String, id: String) -> float:
	return float(land.get(tag, {}).get(id, 0.0))


func crown_land(tag: String) -> float:
	var s := 0.0
	for id in land.get(tag, {}):
		s += float(land[tag][id])
	return maxf(0.0, 100.0 - s)


func loyalty_of(tag: String, id: String) -> float:
	return float(loyalty.get(tag, {}).get(id, 0.0))


func privileges_of(tag: String, id: String) -> Array:
	return (privileges.get(tag, []) as Array).filter(func(p): return _estate_of_privilege(p) == id)


## Influência sem a parte das terras. `at_start` = a conta da partida, quando o EU4 reparte as
## terras: ainda sem renda comercial (trade_income_percentage = 0) e sem os privilégios.
## O EST_VAL_COT (+5 com centro de comércio) não entra: nas dicas do EU4 1.37 a Suécia e a Noruega
## têm centro de comércio e não ganham os +5 (APROXIMAÇÃO pelos números: Suécia 23, Noruega 10).
func _influence_base(tag: String, id: String, at_start := false) -> float:
	var key := "%s|%s" % [tag, id]
	if not at_start and _base_cache.has(key):
		return _base_cache[key]
	var d: Array = defs[id]
	var v := _num(d, "base_influence", 0.0)
	if at_start:
		cbs.trade_share_override = 0.0
	for m in _inf_mods[id]:
		if cbs.check(m[0], tag, tag) == true:
			v += m[1]
	cbs.trade_share_override = -1.0
	v += power.modifier(tag, short(id) + "_influence_modifier") * 100.0
	if not at_start:
		for p in privileges.get(tag, []):
			if _estate_of_privilege(p) == id:
				v += _num(privs[p], "influence", 0.0) * 100.0
		_base_cache[key] = v
	return v


func influence(tag: String, id: String) -> float:
	if not defs.has(id):
		return 0.0
	var per := float(Eu4Data.define("NCountry", "ESTATE_INFLUENCE_PER_DEV", 0.5)) * _num(defs[id], "influence_from_dev_modifier", 1.0)
	var from_land := minf(land_of(tag, id) * per, float(Eu4Data.define("NCountry", "ESTATE_MAX_INFLUENCE_FROM_DEV", 100.0)))
	return clampf(_influence_base(tag, id) + from_land, 0.0, 100.0)


func equilibrium(tag: String, id: String) -> float:
	var key := "%s|%s" % [tag, id]
	if _eq_cache.has(key):
		return _eq_cache[key]
	var d: Array = defs[id]
	var v := float(Eu4Data.define("NCountry", "ESTATE_DEFAULT_LOYALTY", 30.0))
	var own := _mods(tget(d, "land_ownership_modifier"))     # × terras (0–1): ex. burghers_loyalty_modifier 0,2
	v += float(own.get(short(id) + "_loyalty_modifier", 0.0)) * land_of(tag, id)
	for m in _loy_mods[id]:
		if cbs.check(m[0], tag, tag) == true:
			v += m[1]
	v += power.modifier(tag, short(id) + "_loyalty_modifier") * 100.0
	for p in privileges.get(tag, []):
		if _estate_of_privilege(p) == id:
			v += _num(privs[p], "loyalty", 0.0) * 100.0
	_eq_cache[key] = clampf(v, 0.0, 100.0)
	return _eq_cache[key]


## Faixa da influência que multiplica os efeitos do estamento (¼, ½, ¾, 1).
static func influence_scale(inf: float) -> float:
	if inf < float(Eu4Data.define("NCountry", "ESTATE_INFLUENCE_LEVEL_1", 20)):
		return 0.25
	if inf < float(Eu4Data.define("NCountry", "ESTATE_INFLUENCE_LEVEL_2", 40)):
		return 0.5
	if inf < float(Eu4Data.define("NCountry", "ESTATE_INFLUENCE_LEVEL_3", 60)):
		return 0.75
	return 1.0


## "happy", "neutral" ou "angry" pela lealdade.
static func mood(loy: float) -> String:
	if loy >= float(Eu4Data.define("NCountry", "ESTATE_HAPPY_THRESHOLD", 60)):
		return "happy"
	if loy >= float(Eu4Data.define("NCountry", "ESTATE_ANGRY_THRESHOLD", 30)):
		return "neutral"
	return "angry"


## Efeitos de um estamento no país: {chave: valor}.
func estate_effects(tag: String, id: String) -> Dictionary:
	var out := {}
	var sc := influence_scale(influence(tag, id))
	var mm := _mods(tget(defs[id], "country_modifier_" + mood(loyalty_of(tag, id))))
	for k in mm:
		out[k] = float(out.get(k, 0.0)) + mm[k] * sc
	for p in privileges.get(tag, []):
		if _estate_of_privilege(p) != id:
			continue
		for blk in ["benefits", "penalties"]:
			var b := _mods(tget(privs[p], blk))
			for k in b:
				out[k] = float(out.get(k, 0.0)) + b[k]
		var bl := _mods(tget(privs[p], "modifier_by_land_ownership"))
		for k in bl:
			out[k] = float(out.get(k, 0.0)) + bl[k] * land_of(tag, id) / 100.0
	return out


func _compute(tag: String) -> Dictionary:
	_busy = true
	var out := {}
	for id in of.get(tag, []):
		var e := estate_effects(tag, id)
		for k in e:
			out[k] = float(out.get(k, 0.0)) + e[k]
	var cl := crown_land(tag)
	for b in crown_bonus:
		if cl >= float(b["from"]) and cl < float(b["to"]):
			for k in b["modifier"]:
				out[k] = float(out.get(k, 0.0)) + float(b["modifier"][k])
	_busy = false
	return out


## Efeito somado de todos os estamentos (fora do cache do MonarchPower, como o prestígio).
func effect(tag: String, key: String) -> float:
	if _busy:
		return 0.0
	return float(_eff.get(tag, {}).get(key, 0.0))


func effects(tag: String) -> Dictionary:
	return {} if _busy else _eff.get(tag, {})


# ------------------------------------------------------------------ tempo
## Por mês a lealdade anda para o equilíbrio. As condições (influência e equilíbrio) são caras
## (~0,6 s para todos): o jogador é refeito todo mês e cada país da IA uma vez por ano, um doze
## avos por mês (`_slot`).
func _on_month() -> void:
	_month += 1
	var lo_rate := float(Eu4Data.define("NCountry", "ESTATE_LOYALTY_DECAY_BASE_MIN", 2.0))
	var hi_rate := float(Eu4Data.define("NCountry", "ESTATE_LOYALTY_DECAY_BASE_MAX", 5.0))
	for t in of:
		var fresh: bool = t == power.player or _slot(t) == _month % 12
		if fresh:
			for id in of[t]:
				_base_cache.erase("%s|%s" % [t, id])
				_eq_cache.erase("%s|%s" % [t, id])
		for id in of[t]:
			var cur := loyalty_of(t, id)
			var eq := equilibrium(t, id)
			var diff := eq - cur
			if absf(diff) < 0.001:
				continue
			var rate := lerpf(lo_rate, hi_rate, clampf(absf(diff) / 50.0, 0.0, 1.0)) / 12.0
			loyalty[t][id] = cur + clampf(diff, -rate, rate)
		if fresh or not _eff.has(t):
			_eff[t] = _compute(t)
		if t == power.player:
			changed.emit(t)
