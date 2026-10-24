class_name Coalition
extends RefCounted
## Expansão agressiva e coalizões, regras do EU4 (constantes AE_* do bloco NDiplomacy do
## common/defines.lua, em `map.diplomacy_data.defines`):
##  - Tomar províncias na paz gera expansão agressiva (AE): o modificador de opinião
##    `aggressive_expansion` do EU4 (−1 por ponto, some 2 por ano, mín. −1000) de cada país sobre quem
##    tomou. Base por província = desenvolvimento (até AE_PROVINCE_CAP 30) × badboy_factor do objetivo
##    de guerra (nas províncias dos allowed_provinces dele, ou em todas se ele não limita); vassalizar
##    gera a metade disso pelas províncias do vassalo (`VASSAL_AE`, aproximação). × DEFENDER_AE_MULT
##    (0,75) se quem toma é o defensor, × (1 + ae_impact), × (1 + desenvolvimento de quem toma ×
##    AE_ATTACKER_DEVELOPMENT ÷ 20, até +50%).
##  - Cada país recebe a base × (1 + mesma cultura da província AE_SAME_CULTURE 0,5 ou mesmo grupo
##    AE_SAME_CULTURE_GROUP 0,25 + mesma religião de quem toma AE_SAME_RELIGION 0,5 / outro grupo
##    AE_DIFFERENT_RELIGION −0,5 + conquista infiel AE_INFIDEL_CONQUEST 0,25 + dentro do Sacro Império
##    AE_HRE_INTERNAL 0,5) × AE_DISTANCE_BASE (0,75) elevado à distância ÷ 100 px (da capital dele até
##    a província).
##  - Coalizão: com AE ≥ 50 (AE_COALITION_THRESHOLD −50) e opinião negativa, a IA entra na coalizão
##    contra o país (uma coalizão por vez; não entra aliado, súdito, nem quem tem trégua com o alvo);
##    sai quando a AE cai abaixo disso. O jogador entra e sai pela aba Diplomacia (ação form_coalition
##    do EU4).
##  - Guerra de coalizão: casus belli cb_super_badboy do EU4 (num_of_coalition_members, objetivo
##    superiority_punitive). Por mês, se o casus belli vale e a soma dos regimentos da coalizão passa a
##    do alvo e dos aliados dele, o membro mais forte (da IA) declara (20% por mês) e todos entram; ao
##    fim, trégua de todos com o alvo.

signal changed
signal notice(text: String)

const AE_ID := "aggressive_expansion"
const VASSAL_AE := 0.5
const COALITION_CB := "cb_super_badboy"
const MIN_MEMBERS := 3          # sem os dados do EU4 (num_of_coalition_members do cb_super_badboy)

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var war: War
var dip: DiploActions
var army: Army
var economy: Economy
var cbs: CasusBelli
var peace: Peace
var members := {}              # alvo -> [membros]
var _defs := {}
var _rng := RandomNumberGenerator.new()


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, w: War, dp: DiploActions, a: Army,
		eco: Economy, cb: CasusBelli, pc: Peace) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	war = w
	dip = dp
	army = a
	economy = eco
	cbs = cb
	peace = pc
	_defs = map.diplomacy_data.get("defines", {})
	if not dip.mods.has(AE_ID):        # sem os dados do EU4: o modificador do common/opinion_modifiers
		dip.mods[AE_ID] = {"opinion": -1, "yearly_decay": 2, "min": -1000}
	_rng.randomize()
	clock.month_passed.connect(_on_month)


func _d(k: String, def: float) -> float:
	return float(_defs.get(k, def))


## AE mínima para entrar numa coalizão (50).
func threshold() -> float:
	return -_d("AE_COALITION_THRESHOLD", -50)


# ------------------------------------------------------------------ expansão agressiva
## AE de `observer` contra `tag` (positiva).
func ae(observer: String, tag: String) -> float:
	return -float(dip.timed.get(observer + ">" + tag, {}).get(AE_ID, [0.0])[0])


func add_ae(observer: String, tag: String, amount: float) -> void:
	if amount <= 0.0 or observer == tag:
		return
	var key := observer + ">" + tag
	if not dip.timed.has(key):
		dip.timed[key] = {}
	var cur: Array = dip.timed[key].get(AE_ID, [0.0, -1])
	var per := absf(dip._mod(AE_ID, "opinion", -1))
	cur[0] = maxf(dip._mod(AE_ID, "min", -1000), float(cur[0]) - amount * per)
	dip.timed[key][AE_ID] = cur


## Países com AE contra `tag`, a maior primeiro: [[país, AE]].
func ae_against(tag: String) -> Array:
	var out := []
	var suffix := ">" + tag
	for key in dip.timed:
		if (key as String).ends_with(suffix) and dip.timed[key].has(AE_ID):
			var o := (key as String).get_slice(">", 0)
			var v := ae(o, tag)
			if v >= 0.5 and map.countries.has(o) and economy.development(o) > 0.0:
				out.append([o, v])
	out.sort_custom(func(x, y): return x[1] > y[1])
	return out


## Multiplicadores de quem toma: ae_impact, defensor, tamanho.
func _taker_mult(w: Dictionary, taker: String) -> float:
	var m := maxf(0.0, 1.0 + power.modifier(taker, "ae_impact"))
	if taker in w.get("defenders", []):
		m *= _d("DEFENDER_AE_MULT", 0.75)
	m *= 1.0 + minf(0.5, economy.development(taker) * _d("AE_ATTACKER_DEVELOPMENT", 0.01) / 20.0)
	return m


## Base da AE de cada termo do acordo: [[pid, base]].
func _deal_items(deal: Dictionary) -> Array:
	var w: Dictionary = war.wars.get(int(deal.get("war", -1)), {})
	var taker: String = deal["receiver"]
	var cap := _d("AE_PROVINCE_CAP", 30)
	var items := []
	for pid in deal.get("provinces", []):
		var dev := minf(float(map.provinces[int(pid)]["development"]), cap)
		items.append([int(pid), dev * peace.badboy_factor(w, int(pid), taker)])
	if deal.get("vassal", false):
		for p in map.provinces_of(deal["giver"]):
			items.append([int(p["id"]), minf(float(p["development"]), cap) * VASSAL_AE])
	return items


## Base da AE do acordo (antes dos multiplicadores de cada país).
func deal_base(deal: Dictionary) -> float:
	var w: Dictionary = war.wars.get(int(deal.get("war", -1)), {})
	var s := 0.0
	for it in _deal_items(deal):
		s += float(it[1])
	return s * _taker_mult(w, deal["receiver"])


## AE que cada país recebe contra quem recebe os termos: {país: AE}.
func deal_ae(deal: Dictionary) -> Dictionary:
	var out := {}
	var w: Dictionary = war.wars.get(int(deal.get("war", -1)), {})
	var taker: String = deal["receiver"]
	var items := _deal_items(deal)
	if items.is_empty() or not map.countries.has(taker):
		return out
	var tm := _taker_mult(w, taker)
	var tc: Dictionary = map.countries[taker]
	var dist_base := _d("AE_DISTANCE_BASE", 0.75)
	var hre_taker := _in_hre(taker)
	var caps := {}
	for o in map.countries:
		var cap := int(map.countries[o].get("capital", -1))
		if o != taker and cap >= 0 and cap < map.provinces.size() and map.provinces[cap]["owner"] == o:
			caps[o] = Vector2(float(map.provinces[cap]["center"][0]), float(map.provinces[cap]["center"][1]))
	for it in items:
		var base := float(it[1]) * tm
		if base <= 0.0:
			continue
		var p: Dictionary = map.provinces[int(it[0])]
		var pc := Vector2(float(p["center"][0]), float(p["center"][1]))
		var pcul: String = p.get("culture", "")
		var prel: String = p.get("religion", "")
		for o in caps:                     # distância da capital de cada país até a província
			var dm := pow(dist_base, pc.distance_to(caps[o]) / 100.0)
			if dm < 0.01:
				continue
			var oc: Dictionary = map.countries.get(o, {})
			var rel := 1.0
			var ocul: String = oc.get("primary_culture", "")
			if ocul != "" and ocul == pcul:
				rel += _d("AE_SAME_CULTURE", 0.5)
			elif _cgroup(ocul) != "" and _cgroup(ocul) == _cgroup(pcul):
				rel += _d("AE_SAME_CULTURE_GROUP", 0.25)
			var orel: String = oc.get("religion", "")
			var trel: String = tc.get("religion", "")
			if orel != "" and orel == trel:
				rel += _d("AE_SAME_RELIGION", 0.5)
			elif _rgroup(orel) != "" and _rgroup(orel) == _rgroup(trel):
				rel += _d("AE_SAME_RELIGION_GROUP", 0.0)
			elif _rgroup(orel) != "" and _rgroup(trel) != "":
				rel += _d("AE_DIFFERENT_RELIGION", -0.5)
			if orel != "" and orel == prel and _rgroup(trel) != _rgroup(prel):
				rel += _d("AE_INFIDEL_CONQUEST", 0.25)
			if hre_taker and p.get("hre", false) and _in_hre(o):
				rel += _d("AE_HRE_INTERNAL", 0.5)
			var v := base * maxf(0.0, rel) * dm
			if v > 0.0:
				out[o] = float(out.get(o, 0.0)) + v
	for o in out.keys():
		if out[o] < 0.5:
			out.erase(o)
	return out


## Aplica a AE do acordo (antes de as províncias mudarem de dono).
func apply_deal(deal: Dictionary) -> void:
	var got := deal_ae(deal)
	for o in got:
		add_ae(o, deal["receiver"], got[o])
	if not got.is_empty() and (deal["receiver"] == power.player or power.player in got):
		changed.emit()


func _cgroup(c: String) -> String:
	return str(map.cultures.get(c, {}).get("group", "")) if c != "" else ""


func _rgroup(r: String) -> String:
	return str(map.religions.get(r, {}).get("group", "")) if r != "" else ""


func _in_hre(tag: String) -> bool:
	var cap := int(map.countries.get(tag, {}).get("capital", -1))
	return cap >= 0 and cap < map.provinces.size() and map.provinces[cap].get("hre", false)


# ------------------------------------------------------------------ coalizões
## Alvo da coalizão de que `tag` participa ("" se nenhuma).
func target_of(tag: String) -> String:
	for t in members:
		if tag in members[t]:
			return t
	return ""


func members_against(tag: String) -> Array:
	return members.get(tag, [])


func in_coalition_war(tag: String) -> bool:
	for w in war.wars.values():
		if w.get("coalition", false) and (tag in w["attackers"] or tag in w["defenders"]):
			return true
	return false


## "" se `tag` pode continuar (ou estar) numa coalizão contra `target`, senão o motivo.
func why_not_member(tag: String, target: String) -> String:
	if tag == target or not map.countries.has(target) or map.provinces_of(target).is_empty():
		return "?"
	if map.provinces_of(tag).is_empty():
		return "?"
	if ae(tag, target) < threshold():
		return Loc.s("Expansão agressiva abaixo de %d", "Aggressive expansion below %d") % roundi(threshold())
	if target in diplomacy.allies(tag):
		return Loc.s("São aliados", "Allied")
	if diplomacy.overlord(tag).size() > 0:
		return Loc.s("Súditos não entram em coalizões", "Subjects cannot join coalitions")
	var ov := diplomacy.overlord(target)
	if ov.size() > 0 and ov[0] == tag:
		return Loc.s("É súdito seu", "Is your subject")
	if war.has_truce(tag, target):
		return Loc.s("Trégua com %s", "Truce with %s") % map.countries[target]["name"]
	return ""


func why_not_join(tag: String, target: String) -> String:
	var cur := target_of(tag)
	if cur == target:
		return Loc.s("Já está na coalizão", "Already in the coalition")
	if cur != "":
		return Loc.s("Já está na coalizão contra %s", "Already in the coalition against %s") % map.countries[cur]["name"]
	return why_not_member(tag, target)


func join(tag: String, target: String) -> bool:
	if why_not_join(tag, target) != "":
		return false
	if not members.has(target):
		members[target] = []
	members[target].append(tag)
	if target == power.player and tag != power.player:
		notice.emit(Loc.s("%s entrou na coalizão contra você (%d membros)", "%s joined the coalition against you (%d members)")
				% [map.countries[tag]["name"], members[target].size()])
	_changed(tag, target)
	return true


func leave(tag: String, target: String) -> void:
	if not (tag in members.get(target, [])):
		return
	members[target].erase(tag)
	if members[target].is_empty():
		members.erase(target)
	_changed(tag, target)


func _changed(tag: String, target: String) -> void:
	if power.player in [tag, target]:
		changed.emit()


## Regimentos de um grupo de países (com os súditos que entram nas guerras).
func _strength(tags: Array) -> float:
	var s := 0.0
	var seen := {}
	for t in tags:
		for x in war._bloc(t):
			if not seen.has(x):
				seen[x] = true
				s += army.regiments(x)
	return s


## A coalizão contra `target` tem o casus belli de coalizão (cb_super_badboy do EU4)?
func has_cb(tag: String, target: String) -> bool:
	if cbs and cbs.cbs.has(COALITION_CB):
		return COALITION_CB in cbs.available(tag, target)
	return members_against(target).size() >= MIN_MEMBERS and not in_coalition_war(target)


func _maybe_war(target: String) -> void:
	var ms: Array = members_against(target).duplicate()
	if ms.is_empty() or in_coalition_war(target):
		return
	var ai := ms.filter(func(t): return t != power.player)
	ai.sort_custom(func(x, y): return army.regiments(x) > army.regiments(y))
	var lead := ""
	for t in ai:
		if war.why_not_declare(t, target) == "" and has_cb(t, target):
			lead = t
			break
	if lead == "":
		return
	var enemies := [target]
	enemies.append_array(diplomacy.allies(target))
	enemies.append_array(diplomacy.guarantors(target))
	if _strength(ms) <= _strength(enemies) or _rng.randf() > 0.2:
		return
	var goal := cbs.war_goal_of(COALITION_CB) if cbs else ""
	var w := war.declare(lead, target, COALITION_CB, goal, ms)
	if w.is_empty():
		return
	if power.player == target:
		notice.emit(Loc.s("A coalizão de %d países liderada por %s declarou guerra a você!",
				"The coalition of %d countries led by %s declared war on you!") % [w["attackers"].size(),
				map.countries[lead]["name"]])
	elif power.player in w["attackers"]:
		notice.emit(Loc.s("A coalizão declarou guerra a %s: você entra na guerra",
				"The coalition declared war on %s: you join the war") % map.countries[target]["name"])


func _on_month() -> void:
	# saem os que não podem mais (AE abaixo do limite, aliança, trégua...)
	for t in members.keys():
		for m in members.get(t, []).duplicate():
			if why_not_member(m, t) != "":
				leave(m, t)
	# a IA entra com AE ≥ 50 e opinião negativa
	var thr := threshold()
	for key in dip.timed.keys():
		var e: Dictionary = dip.timed[key]
		if not e.has(AE_ID) or -float(e[AE_ID][0]) < thr:
			continue
		var o := (key as String).get_slice(">", 0)
		var t := (key as String).get_slice(">", 1)
		if o == power.player or target_of(o) != "" or dip.opinion(o, t) >= 0:
			continue
		join(o, t)
	for t in members.keys():
		if members.has(t):
			_maybe_war(t)
