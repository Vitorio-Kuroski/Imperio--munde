class_name Rivals
extends RefCounted
## Rivais, pelas regras do EU4 que estão nos arquivos:
##  - até NUM_POSSIBLE_RIVALS (3) por país; trocar/tirar um rival só depois de CHANGE_RIVAL_YEARS (5)
##    anos e custa PS_REPLACE_RIVAL (100) pontos diplomáticos; não se põe nem se tira em guerra
##    (NOT_ADD_RIVAL_AT_WAR / NOT_REMOVE_RIVAL_AT_WAR);
##  - vassalos e sócios menores de união pessoal não escolhem rivais (RIVALS_NOT_POSSIBLE_SUBJECT);
##  - opinião: quem escolhe tem o modificador `rival` (−100) sobre o rival, e o rival `enemy` (−50)
##    sobre quem o escolheu (common/opinion_modifiers); não há aliança entre rivais (THEY_ARE_OUR_RIVAL,
##    THEY_RIVAL_US).
## APROXIMAÇÃO (o resto é do motor do EU4, não está nos arquivos): rival válido = país independente
## ao alcance (fronteira por terra ou capital a até `RANGE` px) com entre metade (`MIN_POWER`) e o
## dobro (`MAX_POWER`) do desenvolvimento de quem escolhe (Boêmia: Hungria, Polônia e Áustria, como no EU4), sem aliança nem relação de súdito; a IA fica com os maiores
## válidos (no começo e todo mês, se tiver vaga) e solta os que deixam de valer.
## "Rivals" na aba Diplomacia = `of(tag)`; "Enemies" = `enemies_of(tag)` (quem o tem como rival).

signal changed(tag: String)

const RANGE := 150.0               # px do mapa entre as capitais (sem fronteira)
const MIN_POWER := 0.5             # fração mínima do desenvolvimento de quem escolhe ("fraco demais")
const MAX_POWER := 2.0             # fração máxima ("forte demais")

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var war: War
var cbs: CasusBelli                # fronteiras (`_neighbors`)
var rivals := {}                   # tag -> [tags]
var since := {}                    # "A>B" -> AAAAMMDD em que A pôs B como rival
var _max := 3
var _change_years := 5
var _replace_cost := 100
var _dev := {}                     # tag -> desenvolvimento (refeito todo mês)
var _cap := {}                     # tag -> centro da capital (refeito todo mês)
var _no_cand := {}                 # tag -> ano em que não achou candidato (tenta de novo 5 anos depois)
var _version := -1                 # map.owner_version do último _recount
var _sorted: Array = []            # tags por desenvolvimento crescente (candidatos por busca binária)
var _sorted_dev := PackedFloat32Array()


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, w: War, cb: CasusBelli) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	war = w
	cbs = cb
	_max = int(Eu4Data.define("NDiplomacy", "NUM_POSSIBLE_RIVALS", 3))
	_change_years = int(Eu4Data.define("NDiplomacy", "CHANGE_RIVAL_YEARS", 5))
	_replace_cost = int(Eu4Data.define("NCountry", "PS_REPLACE_RIVAL", 100))
	clock.month_passed.connect(_on_month)


func _today() -> int:
	return clock.year * 10000 + clock.month * 100 + clock.day


func _recount() -> void:
	if _version == map.owner_version and not _dev.is_empty():
		return                          # nada mudou de dono nem de desenvolvimento
	_version = map.owner_version
	_dev.clear()
	_cap.clear()
	for p in map.provinces:
		var o: String = p["owner"]
		if o != "":
			_dev[o] = float(_dev.get(o, 0.0)) + float(p["development"])
	_sorted = _dev.keys()
	_sorted.sort_custom(func(x, y): return float(_dev[x]) < float(_dev[y]))
	_sorted_dev.resize(_sorted.size())
	for i in _sorted.size():
		_sorted_dev[i] = float(_dev[_sorted[i]])
	for t in _dev:
		var c := int(map.countries.get(t, {}).get("capital", -1))
		if c >= 0 and c < map.provinces.size():
			var v: Array = map.provinces[c]["center"]
			_cap[t] = Vector2(float(v[0]), float(v[1]))


func dev(tag: String) -> float:
	if _dev.is_empty():
		_recount()
	return float(_dev.get(tag, 0.0))


func of(tag: String) -> Array:
	return rivals.get(tag, [])


func is_rival(a: String, b: String) -> bool:
	return b in rivals.get(a, [])


## Países que têm `tag` como rival ("Enemies").
func enemies_of(tag: String) -> Array:
	var out := []
	for t in rivals:
		if tag in rivals[t]:
			out.append(t)
	return out


## Vassalos e sócios menores de união não escolhem rivais.
func can_pick(tag: String) -> bool:
	if diplomacy == null:
		return true
	var ov: Array = diplomacy.overlord(tag)
	if ov.is_empty():
		return true
	return not (diplomacy.subject_type_id(str(ov[1])) in ["vassal", "personal_union", "march"] or str(ov[1]) in ["vassal", "union", "march"])


func _in_range(a: String, b: String) -> bool:
	if cbs and cbs._neighbors(a).has(b):
		return true
	if not _cap.has(a) or not _cap.has(b):
		return false
	var p: Vector2 = _cap[a]
	var q: Vector2 = _cap[b]
	var dx := absf(p.x - q.x)
	dx = minf(dx, map.map_w - dx)
	return dx <= RANGE and absf(p.y - q.y) <= RANGE and Vector2(dx, p.y - q.y).length() <= RANGE


## `b` pode ser rival de `a`? (motivo; "" = pode)
func why_not_valid(a: String, b: String) -> String:
	if a == b or not map.countries.has(b) or dev(b) <= 0.0:
		return "?"
	if dev(b) < MIN_POWER * dev(a):
		return Loc.s("Fraco demais", "Too weak")
	if dev(b) > MAX_POWER * dev(a):
		return Loc.s("Forte demais", "Too strong")
	if not _in_range(a, b):
		return Loc.s("Fora de alcance", "Out of range")
	if diplomacy:
		if b in diplomacy.allies(a):
			return Loc.s("É nosso aliado", "Is our ally")
		if diplomacy.top_overlord(a) == diplomacy.top_overlord(b):
			return Loc.s("Mesmo suserano ou súdito", "Same overlord or subject")
		if not diplomacy.overlord(b).is_empty() and not can_pick(b):
			return Loc.s("É súdito de outro país", "Is a subject")
	return ""


## Candidatos válidos para `a` (os maiores primeiro).
func candidates(a: String) -> Array:
	var out := []
	if not can_pick(a):
		return out
	if _dev.is_empty():
		_recount()
	# só os países com 0,5× a 2× o desenvolvimento (os outros não valem)
	var lo := _sorted_dev.bsearch(MIN_POWER * dev(a))
	var hi := _sorted_dev.bsearch(MAX_POWER * dev(a), false)
	for i in range(lo, hi):
		var t: String = _sorted[i]
		if t != a and why_not_valid(a, t) == "":
			out.append(t)
	# vizinhos de fronteira primeiro, depois os maiores (Boêmia: Hungria, Polônia e Áustria)
	var nb: Dictionary = cbs._neighbors(a) if cbs else {}
	out.sort_custom(func(x, y):
		if nb.has(x) != nb.has(y):
			return nb.has(x)
		return dev(x) > dev(y))
	return out


## Motivo de não poder pôr `b` como rival de `a` agora ("" = pode).
func why_not_add(a: String, b: String) -> String:
	if is_rival(a, b):
		return "?"
	if not can_pick(a):
		return Loc.t("RIVALS_NOT_POSSIBLE_SUBJECT", "Súditos não escolhem rivais")
	if war and war.at_war(a):
		return Loc.t("NOT_ADD_RIVAL_AT_WAR", "Não se põe rival em guerra")
	var v := why_not_valid(a, b)
	if v != "":
		return v
	if of(a).size() >= _max:
		return Loc.s("Já tem %d rivais (tire um primeiro)", "Already has %d rivals (remove one first)") % _max
	return ""


## Motivo de não poder tirar `b` dos rivais de `a` ("" = pode; custa PS_REPLACE_RIVAL pontos dip).
func why_not_remove(a: String, b: String) -> String:
	if not is_rival(a, b):
		return "?"
	if war and war.at_war(a):
		return Loc.t("NOT_REMOVE_RIVAL_AT_WAR", "Não se tira rival em guerra")
	var until := int(since.get(a + ">" + b, 0)) + _change_years * 10000
	if _today() < until:
		return Loc.s("Só depois de %s", "Not before %s") % Loc.date(until / 10000, (until / 100) % 100, until % 100)
	if power and power.points(a, "dip") < _replace_cost:
		return Loc.s("Faltam pontos diplomáticos (%d)", "Not enough diplomatic power (%d)") % _replace_cost
	return ""


func remove_cost() -> int:
	return _replace_cost


func add(a: String, b: String) -> bool:
	if why_not_add(a, b) != "":
		return false
	if not rivals.has(a):
		rivals[a] = []
	rivals[a].append(b)
	since[a + ">" + b] = _today()
	_notify(a, b)
	return true


func remove(a: String, b: String, free := false) -> bool:
	if not free and why_not_remove(a, b) != "":
		return false
	if not free and power:
		power.state[a]["points"]["dip"] -= _replace_cost
		power.notify(a)
	rivals[a].erase(b)
	since.erase(a + ">" + b)
	_notify(a, b)
	return true


func _notify(a: String, b: String) -> void:
	if power and (a == power.player or b == power.player):
		changed.emit(a)


## IA: solta os que deixaram de valer e completa as vagas com os maiores válidos.
func ai_pick(tag: String) -> void:
	for b in of(tag).duplicate():
		if not map.countries.has(b) or dev(b) <= 0.0 or (diplomacy and b in diplomacy.allies(tag)) or not can_pick(tag):
			remove(tag, b, true)
	if not can_pick(tag) or (war and war.at_war(tag)) or of(tag).size() >= _max:
		return
	if clock.year < int(_no_cand.get(tag, -100)) + 5:
		return
	var cands := candidates(tag)
	if cands.is_empty():
		_no_cand[tag] = clock.year
		return
	_no_cand.erase(tag)
	for b in cands:
		if of(tag).size() >= _max:
			break
		if not is_rival(tag, b):
			add(tag, b)


## Começo do jogo: todos os países da IA escolhem (o jogador escolhe na aba Diplomacia).
func start() -> void:
	_recount()
	for t in _dev:
		if power == null or t != power.player:
			ai_pick(t)


## Todo mês: refaz o desenvolvimento; a IA solta rivais que deixaram de valer e, uma vez por ano
## (cada país num mês), tenta completar as vagas (procurar candidatos é caro com 665 países).
func _on_month() -> void:
	_recount()
	for t in _dev:
		if power != null and t == power.player:
			continue
		var full := of(t).size() >= _max
		if not full and (t.hash() + clock.month) % 12 == 0:
			ai_pick(t)
		elif not of(t).is_empty():
			for b in of(t).duplicate():
				if not map.countries.has(b) or dev(b) <= 0.0 or (diplomacy and b in diplomacy.allies(t)):
					remove(t, b, true)
