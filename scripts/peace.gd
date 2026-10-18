class_name Peace
extends RefCounted
## Tratados de paz pelo placar da guerra, regras do EU4 (constantes do bloco NDiplomacy do
## common/defines.lua, em `map.diplomacy_data.defines`):
##  - Termos (`options`): tomar província (desenvolvimento × PEACE_COST_DEMAND_PROVINCE 0,8;
##    × 1,1 se quem recebe não a ocupa — PEACE_COST_DEMAND_NON_OCCUPIED_PROVINCE_MULT; × 1,2 se for a
##    capital; × peace_cost_factor do objetivo de guerra quando a província está nos allowed_provinces
##    dele), vassalizar (desenvolvimento do país × PEACE_COST_BECOME_VASSAL 0,8), ouro (cada
##    "empréstimo" do tamanho dos do país que paga custa PEACE_COST_GOLD_STEP 5, até
##    PEACE_COST_GOLD_MAX 5) e conceder derrota (PEACE_COST_CONCEDE 10, +10 de prestígio).
##  - Dá para pedir província ocupada pelo seu lado, vizinha das suas terras ou onde você tem núcleo
##    ou reivindicação. Negociando com o líder do outro lado, valem as províncias de todos os países
##    dele e a paz acaba a guerra; com outro país, é paz separada só com ele (e os súditos dele).
##  - A IA aceita uma exigência se o custo não passa do placar a seu favor (`score_for` de quem
##    pede); aceita uma oferta se o que recebe vale pelo menos o placar dela; paz branca se ela não
##    está ganhando (placar ≤ 10).
##  - Ao assinar: províncias mudam de dono (`MapView.set_owner_of`; país sem províncias é anexado e
##    perde os exércitos; capital perdida passa para a maior província que sobrou), vassalagem,
##    ouro, prestígio (PO_DEMAND_PROVINCES_PRESTIGE 0,25 por desenvolvimento, PO_BECOME_VASSAL_PRESTIGE,
##    PO_CONCEDE_DEFEAT_PRESTIGE) e trégua de TRUCE_YEARS (5) + SCALED_TRUCE_YEARS (10) × custo ÷ 100.
##  - A IA que está ganhando (placar ≥ 25, guerra com 6 meses ou mais) pede as províncias que ocupa e
##    ouro até o placar: ao jogador é uma proposta (sinal `offered`), entre a IA a paz é assinada;
##    guerra da IA empatada há 5 anos acaba em paz branca. A coalizão só aceita paz branca com placar
##    ≤ 10 − PEACE_COALITION_FACTOR (30). Tomar províncias gera expansão agressiva (`Coalition`).

signal offered(deal: Dictionary)        # proposta da IA para o jogador
signal signed(deal: Dictionary)

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var war: War
var economy: Economy
var army: Army
var prestige: Prestige
var cbs: CasusBelli
var coalition: Coalition          # main.gd define (expansão agressiva ao assinar)
var _defs := {}
var _rng := RandomNumberGenerator.new()


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, w: War, eco: Economy, a: Army,
		pr: Prestige, cb: CasusBelli) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	war = w
	economy = eco
	army = a
	prestige = pr
	cbs = cb
	_defs = map.diplomacy_data.get("defines", {})
	_rng.randomize()
	clock.month_passed.connect(_on_month)


func _d(k: String, def: float) -> float:
	return float(_defs.get(k, def))


## Líder de um lado (o primeiro da lista) e se `tag` é líder.
static func leader(w: Dictionary, side: String) -> String:
	return str(w[side][0]) if not w[side].is_empty() else ""


func side_of(w: Dictionary, tag: String) -> String:
	return "attackers" if tag in w["attackers"] else ("defenders" if tag in w["defenders"] else "")


## Países que entregam termos quando `giver` negocia: o lado inteiro se ele é o líder, senão ele e
## os súditos dele que estão na guerra.
func giver_bloc(w: Dictionary, giver: String) -> Array:
	var side := side_of(w, giver)
	if side == "":
		return []
	if leader(w, side) == giver:
		return w[side].duplicate()
	var out := [giver]
	for s in diplomacy.subjects(giver):
		if s[0] in w[side]:
			out.append(s[0])
	return out


func is_full_peace(w: Dictionary, a: String, b: String) -> bool:
	return leader(w, side_of(w, a)) == a and leader(w, side_of(w, b)) == b


# ------------------------------------------------------------------ termos e custos
## Custo (placar) de tomar a província `pid` para `receiver` na guerra `w`.
func province_cost(w: Dictionary, pid: int, receiver: String) -> float:
	var p: Dictionary = map.provinces[pid]
	var c := float(p["development"]) * _d("PEACE_COST_DEMAND_PROVINCE", 0.8)
	var rside := side_of(w, receiver)
	if not (war.controller.get(pid, "") in w.get(rside, [])):
		c *= _d("PEACE_COST_DEMAND_NON_OCCUPIED_PROVINCE_MULT", 1.1)
	if int(map.countries.get(p["owner"], {}).get("capital", -1)) == pid:
		c *= _d("PEACE_COST_DEMAND_CAPITAL_MULT", 1.2)
	var f := _goal_factor(w, pid, receiver)
	return c * f


## peace_cost_factor do objetivo de guerra se a província está nos allowed_provinces dele.
func _goal_factor(w: Dictionary, pid: int, receiver: String) -> float:
	return _goal_value(w, pid, receiver, "peace_cost_factor", false)


## badboy_factor do objetivo de guerra (expansão agressiva): nas províncias dos allowed_provinces
## dele, ou em todas se ele não limita as províncias.
func badboy_factor(w: Dictionary, pid: int, receiver: String) -> float:
	return _goal_value(w, pid, receiver, "badboy_factor", true)


func _goal_value(w: Dictionary, pid: int, receiver: String, key: String, unrestricted: bool) -> float:
	var gid: String = w.get("war_goal", "")
	if gid == "" or cbs == null or not cbs.goals.has(gid):
		return 1.0
	var block_name := "attacker" if receiver in w["attackers"] else "defender"
	var block: Array = cbs.goals[gid].get(block_name, [])
	var factor := 1.0
	var allowed: Array = []
	for it in block:
		if it[0] == key and str(it[1]).is_valid_float():
			factor = float(it[1])
		elif it[0] == "allowed_provinces" and it[1] is Array:
			allowed = it[1]
	if allowed.is_empty():
		return factor if unrestricted else 1.0
	var root := leader(w, "attackers") if block_name == "attacker" else leader(w, "defenders")
	var from := leader(w, "defenders") if block_name == "attacker" else leader(w, "attackers")
	return factor if cbs.check_province(allowed, pid, root, from) == true else 1.0


## Províncias que `receiver` pode pedir de `giver` (e do bloco dele).
func demandable(w: Dictionary, receiver: String, giver: String) -> Array:
	var rside := side_of(w, receiver)
	var mine := {}
	for p in map.provinces_of(receiver):
		mine[int(p["id"])] = true
	var out := []
	for t in giver_bloc(w, giver):
		for p in map.provinces_of(t):
			var pid := int(p["id"])
			var ok: bool = war.controller.get(pid, "") in w[rside] or receiver in p.get("cores", []) \
					or receiver in p.get("claims", [])
			if not ok:
				for n in p.get("neighbors", []):
					if mine.has(int(n)):
						ok = true
						break
			if ok:
				out.append(pid)
	out.sort_custom(func(a, b): return province_cost(w, a, receiver) > province_cost(w, b, receiver))
	return out


func vassal_cost(giver: String) -> float:
	return minf(100.0, economy.development(giver) * _d("PEACE_COST_BECOME_VASSAL", 0.8))


func can_vassalize(w: Dictionary, receiver: String, giver: String) -> bool:
	return diplomacy.overlord(giver).is_empty() and not diplomacy.overlord(receiver).size() > 0 \
			and giver != leader(w, side_of(w, receiver))


func gold_amount(giver: String, steps: int) -> float:
	return economy.loan_size(giver) * steps


## Custo total de um acordo {war, receiver, giver, provinces [pid], vassal bool, gold int, concede bool}.
func cost(deal: Dictionary) -> float:
	var w: Dictionary = war.wars.get(int(deal["war"]), {})
	if w.is_empty():
		return 0.0
	var c := 0.0
	for pid in deal.get("provinces", []):
		c += province_cost(w, int(pid), deal["receiver"])
	if deal.get("vassal", false):
		c += vassal_cost(deal["giver"])
	c += float(deal.get("gold", 0)) * _d("PEACE_COST_GOLD_STEP", 5)
	if deal.get("concede", false):
		c += _d("PEACE_COST_CONCEDE", 10)
	return c


func prestige_gain(deal: Dictionary) -> float:
	var g := 0.0
	for pid in deal.get("provinces", []):
		g += float(map.provinces[int(pid)]["development"]) * _d("PO_DEMAND_PROVINCES_PRESTIGE", 0.25)
	if deal.get("vassal", false):
		g += economy.development(deal["giver"]) * _d("PO_BECOME_VASSAL_PRESTIGE", 0.25)
	if deal.get("concede", false):
		g += _d("PO_CONCEDE_DEFEAT_PRESTIGE", 10)
	return minf(g, _d("MAX_PEACE_TREATY_PRESTIGE", 100))


## O outro lado aceita? `asker` = quem propõe (o jogador), `deal.receiver` = quem ganha os termos.
func accepts(deal: Dictionary, asker: String) -> bool:
	var w: Dictionary = war.wars.get(int(deal["war"]), {})
	if w.is_empty():
		return false
	var c := cost(deal)
	var other: String = deal["giver"] if deal["receiver"] == asker else deal["receiver"]
	if c <= 0.0:                                          # paz branca (a coalizão resiste mais)
		var coal := _d("PEACE_COALITION_FACTOR", 30) if w.get("coalition", false) and other in w["attackers"] else 0.0
		return war.score_for(w, other) <= 10.0 - coal
	if deal["receiver"] == asker:                         # exigência
		return c <= war.score_for(w, asker) + 0.001
	return c + 0.001 >= war.score_for(w, other)          # oferta: o que recebem paga o placar deles


# ------------------------------------------------------------------ assinar
func sign(deal: Dictionary) -> void:
	var w: Dictionary = war.wars.get(int(deal["war"]), {})
	if w.is_empty():
		return
	var rec: String = deal["receiver"]
	var giv: String = deal["giver"]
	var c := cost(deal)
	if coalition:
		coalition.apply_deal(deal)
	var losers := {}
	for pid in deal.get("provinces", []):
		var p: Dictionary = map.provinces[int(pid)]
		losers[p["owner"]] = true
		war.controller.erase(int(pid))
		map.set_owner_of(int(pid), rec)
	for t in losers:
		_fix_capital(t)
	if deal.get("vassal", false):
		diplomacy.add_relation("vassal", rec, giv)
	var g := minf(gold_amount(giv, int(deal.get("gold", 0))), maxf(0.0, economy.money(giv)))
	if g > 0.0:
		economy.treasury[giv] = economy.money(giv) - g
		economy.treasury[rec] = economy.money(rec) + g
	if prestige:
		prestige.add(rec, prestige_gain(deal))
		if deal.get("concede", false):
			prestige.add(giv, -_d("PO_CONCEDE_DEFEAT_PRESTIGE", 10))
	# fim da guerra (ou paz separada)
	var full := is_full_peace(w, rec, giv)
	var leaving := giver_bloc(w, giv) if not full else []
	if not full and not (giv in leaving):
		leaving.append(giv)
	var years := _d("TRUCE_YEARS", 5) + _d("SCALED_TRUCE_YEARS", 10) * clampf(c / 100.0, 0.0, 1.0)
	war.add_truce(rec, giv, years)
	if full:
		war.end_war(int(w["id"]))
	else:
		war.leave_war(int(w["id"]), leaving)
	for t in losers:
		if map.provinces_of(t).is_empty():
			_annexed(t)
	economy._recount()
	power.invalidate(rec)
	power.invalidate(giv)
	signed.emit(deal)


func _fix_capital(tag: String) -> void:
	var c: Dictionary = map.countries.get(tag, {})
	var cap := int(c.get("capital", -1))
	if cap >= 0 and cap < map.provinces.size() and map.provinces[cap]["owner"] == tag:
		return
	var best := -1
	var dev := -1
	for p in map.provinces_of(tag):
		if int(p["development"]) > dev:
			dev = int(p["development"])
			best = int(p["id"])
	if best >= 0:
		c["capital"] = best


## País sem províncias: sai das guerras e os exércitos somem.
func _annexed(tag: String) -> void:
	for a in army.armies_of(tag):
		army.disband(int(a["id"]))
	for w in war.wars.values().duplicate():
		if tag in w["attackers"] or tag in w["defenders"]:
			war.leave_war(int(w["id"]), [tag])


# ------------------------------------------------------------------ IA faz a paz
## Todo mês: o líder que está ganhando (placar ≥ 25, guerra com 6 meses ou mais, 25% de chance) pede
## o que ocupa e ouro até o placar; ao jogador é uma proposta (sinal `offered`), entre países da IA a
## paz é assinada. Guerra da IA empatada há 5 anos ou mais acaba em paz branca (10% por mês).
func _on_month() -> void:
	var p := power.player
	var asked := false
	for w in war.wars.values().duplicate():
		if not war.wars.has(int(w["id"])):
			continue
		var a := leader(w, "attackers")
		var d := leader(w, "defenders")
		if a == "" or d == "":
			continue
		var s := war.score(w)
		var winner := a if s > 0.0 else d
		var loser := d if s > 0.0 else a
		var ws := absf(s)
		var months := war.months_since_start(w)
		if winner == p:
			continue                                       # o jogador decide a própria paz
		if ws < 25.0:
			if loser != p and months >= 60 and _rng.randf() < 0.1:
				war.white_peace(int(w["id"]))
			continue
		if months < 6 or _rng.randf() > 0.25:
			continue
		if loser == p and asked:
			continue                                       # uma proposta ao jogador por mês
		var deal := ai_deal(w, winner, loser, ws)
		if cost(deal) <= 0.0:
			continue
		if loser == p:
			asked = true
			offered.emit(deal)
		else:
			self.sign(deal)                                # (sem self. seria a função sign() do Godot)


## Acordo da IA vencedora: províncias que o lado dela ocupa e ouro até o placar `score`.
func ai_deal(w: Dictionary, winner: String, loser: String, score: float) -> Dictionary:
	var ws := side_of(w, winner)
	var deal := {"war": int(w["id"]), "receiver": winner, "giver": loser, "provinces": [], "vassal": false, "gold": 0,
			"concede": false}
	var left := score
	for pid in demandable(w, winner, loser):
		if not (war.controller.get(pid, "") in w[ws]):
			continue                                      # a IA pede só o que ocupa
		var c := province_cost(w, pid, winner)
		if c <= left:
			deal["provinces"].append(pid)
			left -= c
	var steps := mini(int(_d("PEACE_COST_GOLD_MAX", 5)), int(left / _d("PEACE_COST_GOLD_STEP", 5)))
	if steps > 0 and economy.money(loser) > 0.0:
		deal["gold"] = steps
		left -= steps * _d("PEACE_COST_GOLD_STEP", 5)
	if deal["provinces"].is_empty() and deal["gold"] == 0 and left >= _d("PEACE_COST_CONCEDE", 10):
		deal["concede"] = true
	return deal


## Texto curto do acordo (para a proposta da IA e o aviso).
func describe(deal: Dictionary) -> String:
	var parts := []
	var provs: Array = deal.get("provinces", [])
	if not provs.is_empty():
		parts.append(Loc.s("províncias: ", "provinces: ") + ", ".join(provs.map(func(x): return map.provinces[int(x)]["name"])))
	if deal.get("vassal", false):
		parts.append(Loc.s("vassalagem", "vassalization"))
	if int(deal.get("gold", 0)) > 0:
		parts.append(Loc.s("%d ducados", "%d ducats") % roundi(gold_amount(deal["giver"], int(deal["gold"]))))
	if deal.get("concede", false):
		parts.append(Loc.s("conceder derrota", "concede defeat"))
	if parts.is_empty():
		parts.append(Loc.s("paz branca", "white peace"))
	return "; ".join(parts)
