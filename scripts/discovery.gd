class_name Discovery
extends RefCounted
## Terra Incógnita e névoa de guerra, pelas regras do EU4.
##  - O que cada país conhece vem do `discovered_by` de history/provinces (Eu4Data): por grupo
##    tecnológico (western, eastern, ottoman...) ou por tag, valendo as datas até o início do jogo
##    (ex.: `1498.1.1 = { discovered_by = POR }` só vale depois). O dono sempre conhece a província.
##    Mares não têm histórico no EU4: aqui um mar é conhecido quando alguma província vizinha de
##    terra é (APROXIMAÇÃO; o oceano aberto fica em Terra Incógnita).
##  - Descobertas novas (exército que entra numa província, província ganha) se espalham pelo grupo
##    tecnológico depois de PROVINCE_DISCOVERY_YEARS_TECHNOLOGY (50) anos e pela religião depois de
##    PROVINCE_DISCOVERY_YEARS_RELIGION (100); o primeiro do grupo tecnológico a descobrir uma
##    província de uma região ganha PROVINCE_DISCOVERY_PRESTIGE (0,1) de prestígio. Quem perde uma
##    província continua conhecendo.
##  - Sem explorador/conquistador (o jogo ainda não tem) ninguém entra em Terra Incógnita, exceto em
##    terra de quem está em guerra com ele (dica HINT_TERRAINCOGNITA_TEXT): `Army.can_enter`/`find_path`.
##  - Névoa de guerra (só para o jogador; a IA vê tudo): visível = províncias do jogador, dos aliados,
##    súditos e suserano que entram nas guerras uns dos outros (tributários não; e as que eles ocupam), as com exércitos deles e as vizinhas de todas essas
##    (APROXIMAÇÃO do alcance de visão do EU4, que não está nos arquivos). Exércitos de fora sob a
##    névoa ficam escondidos (`ArmyLayer`). A IA esquecer unidades escondidas
##    (FOG_OF_WAR_FORGET_CHANCE) não faz sentido enquanto a IA vê tudo.
## O mapa mostra os dois pela textura `view_tex` (N×1: R = 255 em Terra Incógnita, G = 255 visível),
## usada pelo `FogLayer`. Desempenho: o que cada grupo tecnológico conhece fica em `_group_known` e o
## de cada país em `_known_cache` (atualizados a cada descoberta, sem refazer tudo); a visão das
## províncias só é refeita quando donos, ocupações ou aliados mudam (`_base_key`).

signal view_changed                # o que o jogador conhece/vê mudou (FogLayer atualiza)

var map: MapView
var clock: GameClock
var power: MonarchPower
var diplomacy: Diplomacy
var prestige: Prestige
var army: Army                     # main.gd define (exércitos dão visão)
var war: War
var enabled := false               # main liga ao começar o jogo (antes: o mapa todo, como no lobby)
var _groups: Array = []            # pid -> {grupo tecnológico: true}
var _tags: Array = []              # pid -> {tag: true}
var _by_tag := {}                  # tag -> [pid] (as de `_tags`, para montar `known_of`)
var _group_known := {}             # grupo tecnológico -> PackedByteArray (1 = conhece)
var _known_cache := {}             # tag -> PackedByteArray (grupo + próprias descobertas)
var _found: Array = []             # descobertas a espalhar: [pid, tag, AAAAMMDD, fase (0 = grupo, 1 = religião)]
var _region_groups := {}           # região -> {grupo tecnológico: true} (prestígio da 1ª descoberta)
var _years_tech := 50
var _years_rel := 100
var _discovery_prestige := 0.1
var _avail := false
var view_image: Image
var view_tex: ImageTexture
var _visible := PackedByteArray()
var _known_drawn := PackedByteArray()  # o `known_of` do jogador desenhado na textura
var _dirty := true                 # o que o jogador conhece mudou
var _base_key := ""                # donos/ocupações/aliados da última `_base_vis`
var _base_vis := PackedByteArray() # visão das províncias (sem os exércitos)


func setup(m: MapView, c: GameClock, pw: MonarchPower, d: Diplomacy, pr: Prestige) -> void:
	map = m
	clock = c
	power = pw
	diplomacy = d
	prestige = pr
	_years_tech = int(Eu4Data.define("NCountry", "PROVINCE_DISCOVERY_YEARS_TECHNOLOGY", 50))
	_years_rel = int(Eu4Data.define("NCountry", "PROVINCE_DISCOVERY_YEARS_RELIGION", 100))
	_discovery_prestige = float(Eu4Data.define("NCountry", "PROVINCE_DISCOVERY_PRESTIGE", 0.1))
	var n := map.provinces.size()
	_groups.resize(n)
	_tags.resize(n)
	for i in n:
		_groups[i] = {}
		_tags[i] = {}
	_read_history()
	view_image = Image.create(maxi(n, 1), 1, false, Image.FORMAT_RGBA8)
	view_tex = ImageTexture.create_from_image(view_image)
	clock.month_passed.connect(_on_month)
	clock.day_passed.connect(_on_day)
	map.owner_changed.connect(_on_owner_changed)


## O EU4 importado tem o histórico das províncias? (sem ele não há Terra Incógnita)
func available() -> bool:
	return _avail


static func _date_num(s: String) -> int:
	var p := s.split(".")
	if p.size() != 3 or not p[0].is_valid_int():
		return -1
	return int(p[0]) * 10000 + int(p[1]) * 100 + int(p[2])


func _today() -> int:
	return clock.year * 10000 + clock.month * 100 + clock.day


func _add_entry(pid: int, v: String) -> void:
	v = v.strip_edges()
	if map.tech_groups.has(v):
		_groups[pid][v] = true
	elif v != "":
		_tags[pid][v.to_upper()] = true


## discovered_by de history/provinces, com as entradas datadas até hoje (início do jogo).
func _read_history() -> void:
	var hist := Eu4Data.folder("history/provinces")
	_avail = not hist.is_empty()
	if not _avail:
		return
	var today := _today()
	var names := hist.keys()
	names.sort()
	var seen := {}
	var re := RegEx.create_from_string("^\\s*(\\d+)")
	for fname in names:
		var m := re.search(str(fname))
		if m == null:
			continue
		var pid := int(m.get_string(1))
		if pid <= 0 or pid >= map.provinces.size() or seen.has(pid):
			continue
		seen[pid] = true                       # arquivo repetido: o primeiro vale
		for kv in hist[fname]:
			if kv[0] == "discovered_by":
				_add_entry(pid, str(kv[1]))
			elif kv[1] is Array:
				var d := _date_num(str(kv[0]))
				if d < 0 or d > today:
					continue
				for kv2 in kv[1]:
					if kv2[0] == "discovered_by":
						_add_entry(pid, str(kv2[1]))
	# mares: conhecidos por quem conhece uma província vizinha de terra (aproximação)
	for p in map.provinces:
		if not p["sea"]:
			continue
		var pid := int(p["id"])
		for nb in p.get("neighbors", []):
			if not map.provinces[int(nb)]["sea"]:
				_groups[pid].merge(_groups[int(nb)])
				_tags[pid].merge(_tags[int(nb)])
	# tabelas por grupo tecnológico e por país; regiões já conhecidas por cada grupo
	for g in map.tech_groups:
		var arr := PackedByteArray()
		arr.resize(map.provinces.size())
		_group_known[g] = arr
	for p in map.provinces:
		var pid := int(p["id"])
		for g in _groups[pid]:
			_group_known[g][pid] = 1
		for t in _tags[pid]:
			if not _by_tag.has(t):
				_by_tag[t] = []
			_by_tag[t].append(pid)
		var reg: String = p.get("region", "")
		if reg == "":
			continue
		var gs: Dictionary = _region_groups.get(reg, {})
		gs.merge(_groups[pid])
		for t in _tags[pid]:
			var g := _group_of(t)
			if g != "":
				gs[g] = true
		_region_groups[reg] = gs


func _group_of(tag: String) -> String:
	return str(map.countries.get(tag, {}).get("tech_group", ""))


## `tag` já tinha descoberto a província (sem contar ser o dono)?
func _knew(tag: String, pid: int) -> bool:
	if _tags[pid].has(tag):
		return true
	var g := _group_of(tag)
	return g != "" and _groups[pid].has(g)


## `tag` conhece a província?
func knows(tag: String, pid: int) -> bool:
	if pid < 0 or pid >= map.provinces.size():
		return false
	if not _avail or tag == "":
		return true
	return map.provinces[pid]["owner"] == tag or _knew(tag, pid)


## Províncias que `tag` descobriu (1 = conhece; as próprias contam por `knows`), em cache.
func known_of(tag: String) -> PackedByteArray:
	if _known_cache.has(tag):
		return _known_cache[tag]
	var g := _group_of(tag)
	var out: PackedByteArray
	if _group_known.has(g):
		out = (_group_known[g] as PackedByteArray).duplicate()
	else:
		out = PackedByteArray()
		out.resize(map.provinces.size())
	for pid in _by_tag.get(tag, []):
		out[pid] = 1
	for p in map.provinces:                    # as próprias (dono sempre conhece)
		if p["owner"] == tag:
			out[int(p["id"])] = 1
	_known_cache[tag] = out
	return out


func _mark_tag(tag: String, pid: int) -> void:
	if _tags[pid].has(tag):
		return
	_tags[pid][tag] = true
	if not _by_tag.has(tag):
		_by_tag[tag] = []
	_by_tag[tag].append(pid)
	if _known_cache.has(tag):
		_known_cache[tag][pid] = 1
	if power and tag == power.player:
		_dirty = true


func _mark_group(g: String, pid: int) -> void:
	if g == "" or _groups[pid].has(g):
		return
	_groups[pid][g] = true
	if _group_known.has(g):
		_group_known[g][pid] = 1
	for t in _known_cache:                     # países do grupo já em cache
		if _group_of(t) == g:
			_known_cache[t][pid] = 1
	if power and _group_of(power.player) == g:
		_dirty = true


## `tag` descobre a província (exército que entrou, província ganha).
func discover(tag: String, pid: int) -> void:
	if not _avail or tag == "" or pid < 0 or pid >= map.provinces.size() or _knew(tag, pid):
		return
	var reg: String = map.provinces[pid].get("region", "")
	var g := _group_of(tag)
	if reg != "" and g != "" and not _region_groups.get(reg, {}).has(g):
		if prestige:
			prestige.add(tag, _discovery_prestige)    # primeiro do grupo a chegar nesta região
		if not _region_groups.has(reg):
			_region_groups[reg] = {}
		_region_groups[reg][g] = true
	_mark_tag(tag, pid)
	_found.append([pid, tag, _today(), 0])
	# mares vizinhos de terra conhecida também (como no começo)
	for nb in map.provinces[pid].get("neighbors", []):
		if map.provinces[int(nb)]["sea"]:
			_mark_tag(tag, int(nb))
	if enabled and _dirty:
		refresh()


func _on_owner_changed(pid: int, old: String, new: String) -> void:
	if old != "":
		_mark_tag(old, pid)                    # quem perdeu continua conhecendo
	discover(new, pid)
	if _known_cache.has(new):
		_known_cache[new][pid] = 1
	if power and (old == power.player or new == power.player):
		_dirty = true
	if enabled:
		refresh()


## Espalha as descobertas: grupo tecnológico depois de 50 anos, religião depois de 100.
func _on_month() -> void:
	if _found.is_empty():
		return
	var today := _today()
	var keep := []
	for f in _found:
		var pid: int = f[0]
		var tag: String = f[1]
		var years := float(today - int(f[2])) / 10000.0
		if int(f[3]) == 0 and years >= _years_tech:
			_mark_group(_group_of(tag), pid)
			f[3] = 1
		if int(f[3]) == 1 and years >= _years_rel:
			var rel: String = str(map.countries.get(tag, {}).get("religion", ""))
			for t in map.countries:
				if rel != "" and str(map.countries[t].get("religion", "")) == rel:
					_mark_tag(t, pid)
			continue
		keep.append(f)
	_found = keep
	if enabled and _dirty:
		refresh()


func _on_day() -> void:
	if enabled:
		refresh()


## Países cuja visão o jogador compartilha: ele, aliados e o bloco de súditos/suserano que entram
## nas guerras uns dos outros (tributários ficam de fora, como em `War._bloc`).
func sharers(tag: String) -> Dictionary:
	var out := {tag: true}
	if diplomacy:
		for t in diplomacy.allies(tag):
			out[t] = true
		if war:
			for t in war._bloc(tag):
				out[t] = true
	return out


## O jogador vê a província agora (fora da névoa)?
func visible_to_player(pid: int) -> bool:
	if not enabled:
		return true
	return pid >= 0 and pid < _visible.size() and _visible[pid] == 1


func _see(vis: PackedByteArray, pid: int) -> void:
	vis[pid] = 1
	for nb in map.provinces[pid].get("neighbors", []):
		vis[int(nb)] = 1


## Refaz a textura do mapa (Terra Incógnita e névoa do jogador); só atualiza se mudou.
func refresh() -> void:
	if not enabled or power == null or power.player == "":
		return
	var player := power.player
	var share := sharers(player)
	var occ: Dictionary = war.controller if war else {}
	var key := "%d|%s|%d" % [map.owner_version, ",".join(share.keys()), occ.hash()]
	if key != _base_key:                       # visão das províncias (donos, ocupações, aliados)
		_base_key = key
		_base_vis = PackedByteArray()
		_base_vis.resize(map.provinces.size())
		for p in map.provinces:
			if share.has(p["owner"]):
				_see(_base_vis, int(p["id"]))
		for pid in occ:
			if share.has(occ[pid]):
				_see(_base_vis, int(pid))
	var vis := _base_vis.duplicate()
	if army:
		for a in army.armies.values():
			if share.has(a["tag"]):
				_see(vis, int(a["loc"]))
				if not a["path"].is_empty():
					_see(vis, int(a["path"][0]))
	var known := _known_drawn
	if _dirty or known.is_empty():
		_dirty = false
		known = known_of(player)
	if vis == _visible and known == _known_drawn and not known.is_empty():
		return
	_visible = vis
	_known_drawn = known.duplicate()
	var data := PackedByteArray()
	data.resize(vis.size() * 4)
	for i in vis.size():
		if known[i] == 0 and map.provinces[i]["owner"] != player:
			data[i * 4] = 255
		if vis[i] == 1:
			data[i * 4 + 1] = 255
		data[i * 4 + 3] = 255
	view_image.set_data(vis.size(), 1, false, Image.FORMAT_RGBA8, data)
	view_tex.update(view_image)
	view_changed.emit()


## Liga a Terra Incógnita e a névoa (início do jogo).
func start() -> void:
	enabled = true
	_known_cache.clear()
	_visible = PackedByteArray()
	_known_drawn = PackedByteArray()
	_base_key = ""
	_dirty = true
	refresh()
