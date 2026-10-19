class_name War
extends RefCounted
## Guerras durante o jogo (as de 1444 em history/wars ficam na `Diplomacy`, só leitura):
##  - `declare(atacante, alvo)`: o alvo e os aliados dele (e o suserano/súditos) defendem; os aliados
##    do atacante que não são aliados do alvo entram do lado dele (no EU4 eles podem recusar).
##    Guerra de coalizão (`declare(..., membros)`): atacam só os membros da coalizão e os súditos
##    deles; ao fim, todos ficam com trégua com o alvo.
##  - Ocupação: `controller[pid]` = quem controla a província (só as ocupadas; senão o dono).
##  - Placar (`score`, −100 a +100 para os atacantes): províncias ocupadas (desenvolvimento ocupado
##    ÷ desenvolvimento total do lado inimigo × 100) + batalhas (até WARSCORE_MAX_FROM_BATTLES = 40).
##  - `white_peace(id)`: paz branca, tudo volta como era (ocupações desfeitas, exércitos em terra
##    inimiga voltam para a capital). A IA aceita se não está ganhando (placar dela ≤ 10).

signal changed

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var wars := {}                    # id -> {id, name, attackers, defenders, start, battle_score}
var controller := {}              # pid -> tag que ocupa
var truces := {}                  # "A|B" (ordenado) -> data AAAAMMDD em que a trégua acaba
var army: Army                    # main.gd define (paz: exércitos voltam para casa)
var _next := 1
var _start_unix := 0               # data de início do jogo (DAYS_TO_DECLARE_WAR conta a partir dela)
var _rules := {}


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy) -> void:
	map = m
	clock = c
	_start_unix = _today_unix()
	power = pw
	diplomacy = d
	_rules = map.trade_rules


func controller_of(pid: int) -> String:
	return str(controller.get(pid, map.provinces[pid]["owner"]))


func wars_of(tag: String) -> Array:
	var out := []
	for w in wars.values():
		if tag in w["attackers"] or tag in w["defenders"]:
			out.append(w)
	return out


func at_war(tag: String) -> bool:
	for w in wars.values():
		if tag in w["attackers"] or tag in w["defenders"]:
			return true
	return false


## `a` e `b` estão em lados opostos de alguma guerra?
func hostile(a: String, b: String) -> bool:
	if a == b or a == "" or b == "":
		return false
	for w in wars.values():
		if (a in w["attackers"] and b in w["defenders"]) or (a in w["defenders"] and b in w["attackers"]):
			return true
	return false


func enemies_of(tag: String) -> Array:
	var out := []
	for w in wars.values():
		if tag in w["attackers"]:
			out.append_array(w["defenders"])
		elif tag in w["defenders"]:
			out.append_array(w["attackers"])
	return out


## Guerra em que `a` e `b` se enfrentam (vazio se nenhuma).
func war_between(a: String, b: String) -> Dictionary:
	for w in wars.values():
		if (a in w["attackers"] and b in w["defenders"]) or (a in w["defenders"] and b in w["attackers"]):
			return w
	return {}


## "" se `a` pode declarar guerra a `b`, senão o motivo.
func why_not_declare(a: String, b: String) -> String:
	if a == b or not map.countries.has(b):
		return "?"
	# DAYS_TO_DECLARE_WAR (30) dias depois do início antes de qualquer guerra (CANNOT_DECLARE_WAR_FIRST_MONTH)
	var wait := int(Eu4Data.define("NDiplomacy", "DAYS_TO_DECLARE_WAR", 30))
	if _start_unix != 0 and _today_unix() - _start_unix < wait * 86400:
		var d := Time.get_datetime_dict_from_unix_time(_start_unix + wait * 86400)
		var ds := Loc.date(int(d["year"]), int(d["month"]), int(d["day"]))
		return Loc.f("CANNOT_DECLARE_WAR_FIRST_MONTH", {"DATE": ds}, "Só dá para declarar guerra a partir de %s." % ds)
	if map.provinces_of(b).is_empty():
		return Loc.s("Não tem províncias", "Has no provinces")
	if hostile(a, b):
		return Loc.s("Já estão em guerra", "Already at war")
	if has_truce(a, b):
		var t := int(truces[_tkey(a, b)])
		return Loc.s("Trégua até %s", "Truce until %s") % Loc.date(t / 10000, (t / 100) % 100, t % 100)
	if b in diplomacy.allies(a):
		return Loc.s("São aliados (rompa a aliança antes)", "Allied (break the alliance first)")
	if diplomacy.top_overlord(a) == diplomacy.top_overlord(b) and not is_independence(a, b):
		return Loc.s("Mesmo suserano ou súdito", "Same overlord or subject")
	if b in diplomacy.guarantees(a):
		return Loc.s("Você garante a independência dele", "You guarantee their independence")
	return ""


func _today_unix() -> int:
	return Time.get_unix_time_from_datetime_dict({"year": clock.year, "month": clock.month, "day": clock.day,
			"hour": 0, "minute": 0, "second": 0})


## `a` é súdito direto de `b` num tipo que pode lutar pela independência (can_fight_independence_war)?
func is_independence(a: String, b: String) -> bool:
	var ov: Array = diplomacy.overlord(a)
	return not ov.is_empty() and ov[0] == b and diplomacy.subject_type(str(ov[1])).get("can_fight_independence_war", false) == true


## Bloco de um país: ele, o suserano no topo e todos os súditos desse suserano (só sobe/desce por
## tipos de súdito que entram nas guerras do suserano — `joins_overlords_wars` do EU4).
func _bloc(tag: String) -> Array:
	var top := tag
	var guard := 0
	while guard < 10:
		var ov := diplomacy.overlord(top)
		if ov.is_empty() or diplomacy.subject_type(ov[1]).get("joins_overlords_wars", true) == false:
			break
		top = ov[0]
		guard += 1
	var out := [top]
	var i := 0
	while i < out.size():
		for s in diplomacy.subjects(out[i]):
			# tipos de súdito que não entram nas guerras do suserano (tributários...) ficam de fora
			if not (s[0] in out) and diplomacy.subject_type(s[1]).get("joins_overlords_wars", true) != false:
				out.append(s[0])
		i += 1
	if not (tag in out):
		out.append(tag)
	return out


## Declara guerra de `a` a `b` com o casus belli `cb` ("" = sem motivo). Com `coalition` (membros da
## coalizão contra `b`), atacam só eles e os súditos deles (guerra de coalizão).
func declare(a: String, b: String, cb := "", goal := "", coalition: Array = [], called: Variant = null) -> Dictionary:
	if why_not_declare(a, b) != "":
		return {}
	var s := sides(a, b, coalition, called)
	var attackers: Array = s[0]
	var defenders: Array = s[1]
	var w := {"id": _next, "name": Loc.s("Guerra %s–%s", "%s–%s War") % [map.countries[a]["name"], map.countries[b]["name"]],
			"attackers": attackers, "defenders": defenders, "start": [clock.year, clock.month, clock.day],
			"battle_score": 0.0, "cb": cb, "war_goal": goal, "coalition": not coalition.is_empty()}
	if not coalition.is_empty():
		w["name"] = Loc.s("Coalizão contra %s", "Coalition against %s") % map.countries[b]["name"]
	wars[_next] = w
	_next += 1
	changed.emit()
	return w


## Lados de uma guerra de `a` contra `b`: [atacantes, defensores]. `called` = aliados de `a` chamados
## (null = todos, como antes; a janela Declarar guerra do EU4 deixa escolher). Na guerra de
## independência o súdito sai do bloco do suserano e luta só com os próprios súditos e aliados.
func sides(a: String, b: String, coalition: Array = [], called: Variant = null) -> Array:
	var indep := is_independence(a, b)
	var own := [a]
	if indep:
		for sub in diplomacy.subjects(a):
			own.append(sub[0])
	var defenders := _bloc(b)
	if indep:
		for t in own:
			defenders.erase(t)
	for t in defenders.duplicate():
		for al in diplomacy.allies(t) + diplomacy.guarantors(t):
			if not (al in defenders) and al != a and not (al in _bloc(a)):
				for x in _bloc(al):
					if not (x in defenders):
						defenders.append(x)
	var attackers := []
	for t in (own if indep else _bloc(a)):
		if not (t in defenders):
			attackers.append(t)
	for m in coalition:
		for x in _bloc(m):
			if not (x in defenders) and not (x in attackers):
				attackers.append(x)
	for al in (diplomacy.allies(a) if coalition.is_empty() else []):
		if al in defenders or al in attackers:
			continue
		if called is Array and not (al in called):
			continue
		var ok := true
		for d in defenders:              # aliado dos dois lados fica de fora
			if d in diplomacy.allies(al):
				ok = false
		if ok:
			for x in _bloc(al):
				if not (x in defenders) and not (x in attackers):
					attackers.append(x)
	return [attackers, defenders]


## Placar dos atacantes (−100 a +100).
func score(w: Dictionary) -> float:
	var occ := _occupation(w["defenders"], w["attackers"]) - _occupation(w["attackers"], w["defenders"])
	var cap := float(_rules.get("warscore_max_from_battles", 40))
	return clampf(occ + clampf(float(w["battle_score"]), -cap, cap), -100.0, 100.0)


## % do desenvolvimento de `victims` ocupado por `occupiers`.
func _occupation(victims: Array, occupiers: Array) -> float:
	var total := 0.0
	var occ := 0.0
	for p in map.provinces:
		if p["sea"] or not (p["owner"] in victims):
			continue
		var d := float(p["development"])
		total += d
		if controller.get(int(p["id"]), "") in occupiers:
			occ += d
	return occ / total * 100.0 if total > 0.0 else 0.0


## Placar visto pelo lado de `tag` (positivo = ganhando).
func score_for(w: Dictionary, tag: String) -> float:
	return score(w) if tag in w["attackers"] else -score(w)


## Vitória numa batalha: soma ao placar (perdas do inimigo em milhares ÷ 2, como aproximação).
func add_battle(winner: String, loser: String, enemy_losses_k: float) -> void:
	var w := war_between(winner, loser)
	if w.is_empty():
		return
	var pts := maxf(1.0, enemy_losses_k / 2.0)
	w["battle_score"] = float(w["battle_score"]) + (pts if winner in w["attackers"] else -pts)


## A IA do outro lado aceitaria a paz branca? (se ela não está ganhando)
func accepts_white_peace(w: Dictionary, asker: String) -> bool:
	var other: String = w["defenders"][0] if asker in w["attackers"] else w["attackers"][0]
	return other == power.player or score_for(w, other) <= 10.0


func white_peace(id: int) -> void:
	var w: Dictionary = wars.get(id, {})
	if w.is_empty():
		return
	if not w["attackers"].is_empty() and not w["defenders"].is_empty():
		add_truce(w["attackers"][0], w["defenders"][0], float(map.diplomacy_data.get("defines", {}).get("TRUCE_YEARS", 5)))
	end_war(id)


## Acaba a guerra: desfaz as ocupações entre os lados e manda para casa quem ficou em terra proibida.
func end_war(id: int) -> void:
	var w: Dictionary = wars.get(id, {})
	if w.is_empty():
		return
	wars.erase(id)
	if w.get("coalition", false) and not w["defenders"].is_empty():
		# guerra de coalizão: trégua de todos os membros com o alvo (saem da coalizão)
		for t in w["attackers"]:
			add_truce(t, w["defenders"][0], float(map.diplomacy_data.get("defines", {}).get("TRUCE_YEARS", 5)))
	_clear_occupation(w["attackers"], w["defenders"])
	if army:
		army.send_home_after_peace()
	changed.emit()


## Paz separada: `tags` saem da guerra (ocupações entre eles e o outro lado desfeitas); se um lado
## fica vazio, a guerra acaba.
func leave_war(id: int, tags: Array) -> void:
	var w: Dictionary = wars.get(id, {})
	if w.is_empty():
		return
	for side in ["attackers", "defenders"]:
		var other: Array = w["defenders"] if side == "attackers" else w["attackers"]
		var gone: Array = w[side].filter(func(t): return t in tags)
		if not gone.is_empty():
			_clear_occupation(gone, other)
			w[side] = w[side].filter(func(t): return not (t in tags))
	if w["attackers"].is_empty() or w["defenders"].is_empty():
		end_war(id)
		return
	if army:
		army.send_home_after_peace()
	changed.emit()


func _clear_occupation(a: Array, b: Array) -> void:
	for pid in controller.keys():
		var o: String = map.provinces[pid]["owner"]
		var c: String = controller[pid]
		if (o in a and c in b) or (o in b and c in a):
			controller.erase(pid)


# ------------------------------------------------------------------ trégua
static func _tkey(a: String, b: String) -> String:
	return a + "|" + b if a < b else b + "|" + a


func today() -> int:
	return clock.year * 10000 + clock.month * 100 + clock.day


## Trégua de `years` anos (com fração em meses) entre `a` e `b`.
func add_truce(a: String, b: String, years: float) -> void:
	var months := roundi(years * 12.0)
	var y := clock.year + (clock.month - 1 + months) / 12
	var m := (clock.month - 1 + months) % 12 + 1
	truces[_tkey(a, b)] = maxi(int(truces.get(_tkey(a, b), 0)), y * 10000 + m * 100 + clock.day)


func has_truce(a: String, b: String) -> bool:
	return int(truces.get(_tkey(a, b), 0)) > today()


func months_since_start(w: Dictionary) -> int:
	var s: Array = w.get("start", [clock.year, clock.month, clock.day])
	return (clock.year - int(s[0])) * 12 + clock.month - int(s[1])
