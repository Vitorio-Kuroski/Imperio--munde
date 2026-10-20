class_name MapView
extends Sprite2D
## Mapa político baseado em imagem de IDs + shader.
## assets/province_ids.png guarda o id de cada província (R = byte baixo, G = byte alto).
## A cor de cada província vive numa textura-paleta; mudar o dono atualiza só 5 pixels.

const SEA_COLOR := Color(0.16, 0.30, 0.46)
const UNOWNED_COLOR := Color(0.45, 0.43, 0.38)
## Cores do modo de mapa "terreno" (rótulos gerados por tools/refine_world.py).
const TERRAIN_COLORS := {
	"geleira": Color8(235, 240, 245),
	"tundra": Color8(160, 170, 150),
	"montanhas": Color8(120, 105, 95),
	"colinas": Color8(150, 140, 100),
	"planalto": Color8(170, 150, 110),
	"deserto": Color8(225, 200, 140),
	"estepe": Color8(195, 190, 120),
	"savana": Color8(190, 175, 90),
	"selva": Color8(40, 110, 50),
	"floresta": Color8(60, 120, 70),
	"planície": Color8(140, 180, 90),
	"pântano": Color8(90, 120, 100),
	# terrenos que só existem no mapa do EU4 (map/terrain.txt)
	"fazendas": Color8(175, 200, 85),
	"bosque": Color8(95, 145, 80),
	"deserto costeiro": Color8(215, 195, 150),
	"litoral": Color8(155, 185, 140),
	"terras secas": Color8(200, 175, 115),
	"intransitável": Color8(95, 90, 85),
}

enum MapMode { POLITICO, TERRENO, CULTURA, RELIGIAO, PRODUTOS, COMERCIO, REGIOES, INSTITUICOES, DIPLOMACIA }
const MAP_MODE_NAMES := ["político", "terreno", "cultura", "religião", "produtos", "comércio", "regiões",
		"instituições", "diplomacia"]
const MAP_MODE_KEYS := ["MAPMODE_POLITICAL", "MAPMODE_TERRAIN", "MAPMODE_CULTURE", "MAPMODE_RELIGION",
		"MAPMODE_TRADE_GOODS", "MAPMODE_TRADE", "MAPMODE_REGION", "MAPMODE_INSTITUTIONS", "MAPMODE_DIPLOMACY"]
## Cores do modo diplomacia (relação com o país em foco).
const DIPLO_COLORS := {"self": Color(0.13, 0.55, 0.22), "subject": Color(0.45, 0.78, 0.40),
		"overlord": Color(0.80, 0.55, 0.18), "ally": Color(0.22, 0.45, 0.85), "marriage": Color(0.82, 0.45, 0.72),
		"guarantee": Color(0.45, 0.72, 0.85), "same_bloc": Color(0.70, 0.70, 0.35), "war": Color(0.85, 0.15, 0.12),
		"recent_enemy": Color(0.55, 0.22, 0.20)}
const DIPLO_NAMES := {"self": "o país", "subject": "súdito", "overlord": "suserano", "ally": "aliado",
		"marriage": "casamento real", "guarantee": "garantia", "same_bloc": "súdito do mesmo suserano",
		"war": "em guerra", "recent_enemy": "inimigo recente"}
const DIPLO_NAMES_EN := {"self": "the country", "subject": "subject", "overlord": "overlord", "ally": "ally",
		"marriage": "royal marriage", "guarantee": "guarantee", "same_bloc": "subject of the same overlord",
		"war": "at war", "recent_enemy": "recent enemy"}

signal owner_changed(pid: int, old: String, new: String)   # set_owner_of (Discovery)

var map_w: int
var map_h: int
var provinces: Array = []
var countries: Dictionary = {}     # tag -> dict
var country_index: Dictionary = {} # tag -> 1..N (0 = sem dono)
var cultures: Dictionary = {}      # id -> dict (name, group, color)
var culture_index: Dictionary = {} # id -> 1..N (0 = nenhuma)
var religions: Dictionary = {}     # id -> dict (name, group, color); vazio se o mapa não tiver religiões
var religion_index: Dictionary = {} # id -> 1..N (0 = nenhuma)
var trade_goods: Dictionary = {}   # id -> dict (name, color, price); vazio se o mapa não tiver produtos
var trade_good_index: Dictionary = {} # id -> 1..N (0 = nenhum)
var _event_mods := {}                # nome -> efeitos (common/event_modifiers), cache de province_modifier
var trade_nodes: Dictionary = {}   # id -> dict (name, color, location, inland, end, outgoing)
var centers_of_trade: Array = []   # [{id, name, level, type coastal/inland, trade_power}]
var trade_rules: Dictionary = {}   # regras do comércio (modificadores estáticos e defines do EU4)
var trade_view: Trade              # simulação de comércio (main.gd define; dica do modo comércio)
var trade_node_index: Dictionary = {} # id -> 1..N (0 = nenhum)
var buildings: Dictionary = {}     # id -> dict (name, cost, time, modifiers, replaces, goods)
var trade_flows: TradeFlows        # setas do modo comércio
var terrains: Dictionary = {}      # rótulo -> dict (eu4, movement_cost, defence, supply_limit...)
var areas: Dictionary = {}         # id -> dict (name, region, color)
var area_index: Dictionary = {}    # id -> 1..N
var regions: Dictionary = {}       # id -> dict (name, superregion)
var region_index: Dictionary = {}  # id -> 1..N
var superregions: Dictionary = {}  # id -> dict (name)
var continents: Dictionary = {}    # id -> dict (name)
var adjacencies: Array = []        # estreitos: [{from, to, type, through}]
var technologies: Dictionary = {}  # "adm"/"dip"/"mil" -> [{level, year, modifiers, buildings, unlocks, units, institutions}]
var tech_groups: Dictionary = {}   # id -> {start_level, cost_modifier}
var idea_groups: Array = []        # grupos de ideias (category adm/dip/mil, bonus, ideas)
var opinion_modifiers: Dictionary = {}  # common/opinion_modifiers do EU4 (id -> opinion, max, yearly_decay, months...)
var casus_belli: Array = []         # common/cb_types do EU4 ({id, triggered, prerequisites...}; CasusBelli)
var war_goals: Array = []           # common/wargoal_types do EU4 ({id, type, attacker, defender})
## O resto da diplomacia do EU4: actions (condições/efeito das ações), scripted_actions, static_actions,
## subject_types (atributos resolvidos), peace_treaties, insults e defines (NDiplomacy).
var diplomacy_data: Dictionary = {}
var national_ideas: Array = []     # ideias nacionais/de grupo/genéricas (start, bonus, ideas); países têm "ideas"
var institutions: Array = []       # instituições (id, name, color, bonus, start_date, start_province)
var inst_view: Institutions        # presença atual (para o modo de mapa instituições)
var diplo_view: Diplomacy          # relações (modo diplomacia)
var diplo_focus := ""              # país em foco no modo diplomacia
var diplomacy: Array = []          # relações de 1444 (type, first, second, subject_type)
var emperor := ""                  # imperador do Sacro Império
var celestial_emperor := ""
var wars: Array = []               # guerras ativas/recentes (history/wars)
var advisor_types: Array = []      # tipos de conselheiro (category, modifiers)
var advisors: Array = []           # conselheiros históricos (name, location, skill, type, date, death_date)
var units: Dictionary = {}         # id -> {name, type, unit_type, atributos, tech, level}
var _building_pt := {}             # rótulos dos efeitos (data/construcoes_pt.json)
var id_image: Image
var palette_image: Image
var palette_tex: ImageTexture
var mat: ShaderMaterial
var selected_id := -1
var map_mode := MapMode.POLITICO
var owner_version := 0            # muda a cada troca de dono (Economy recalcula a renda)
var _flags_tex: Texture2D          # atlas das bandeiras (vazio sem gfx/flags)
var _flag_cache := {}              # tag -> AtlasTexture
var icons := {}                    # chave ("good:grain", "religion:catholic", "inst:feudalism", "advisor:artist",
                                   # "building:temple", "group:trade_ideas", "mod:global_tax_modifier") -> posição
var _icons_tex: Texture2D          # atlas dos ícones da interface (vazio sem gfx/interface)
var _icon_cache := {}
var ui_dir := ""                   # pasta das texturas de interface do EU4 (Eu4Theme), ao lado do mapa
var river_lines: Array = []         # rios em linhas ([largura, x0, y0, ...], ver RiverLayer)
var has_terrain_textures := false   # modo terreno com as texturas do EU4 (terrain.bmp ou colormap)
var gui_dir := ""                  # pasta das telas do EU4 (Eu4Gui)
var source := ""                   # de onde veio o mapa (caminho do map.json)
var map_dir := ""                  # pasta do province_ids.png e das texturas do mapa
var discovery: Discovery           # main.gd define (Terra Incógnita do jogador)


func load_map(map_scale: float) -> void:
	# Prioridade: mapa do EU4 importado no jogo (user://eu4, ver Eu4Importer) >
	# importado pelo tools/import_eu4.py (res://data/eu4) > mundo > mapa antigo da Europa.
	var json_path := "res://data/map.json"
	var ids_path := "res://assets/province_ids.png"
	if Eu4Importer.has_import():
		json_path = Eu4Importer.OUT_DIR + "/map.json"
		ids_path = Eu4Importer.OUT_DIR + "/province_ids.png"
	elif FileAccess.file_exists("res://data/eu4/map.json") and ResourceLoader.exists("res://assets/eu4/province_ids.png"):
		json_path = "res://data/eu4/map.json"
		ids_path = "res://assets/eu4/province_ids.png"
	elif FileAccess.file_exists("res://data/world/map.json") and ResourceLoader.exists("res://assets/world/province_ids.png"):
		json_path = "res://data/world/map.json"
		ids_path = "res://assets/world/province_ids.png"
	source = json_path
	print("Mapa carregado de: ", json_path)
	var data = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	# localização original do EU4 (loc.txt gravado pelos importadores): nomes como no jogo
	Loc.load_file(json_path.get_base_dir() + "/loc.txt")
	# todos os scripts do EU4 (eu4data/, lidos sob demanda)
	Eu4Data.set_base(json_path.get_base_dir())
	if Loc.active():
		_apply_loc(data)
	map_w = int(data["width"])
	map_h = int(data["height"])
	provinces = data["provinces"]
	var n := 1
	for c in data["countries"]:
		countries[c["tag"]] = c
		country_index[c["tag"]] = n
		n += 1
	n = 1
	for c in data.get("cultures", []):
		cultures[c["id"]] = c
		culture_index[c["id"]] = n
		n += 1
	n = 1
	for r in data.get("religions", []):
		religions[r["id"]] = r
		religion_index[r["id"]] = n
		n += 1
	n = 1
	for g in data.get("trade_goods", []):
		trade_goods[g["id"]] = g
		trade_good_index[g["id"]] = n
		n += 1
	n = 1
	for t in data.get("trade_nodes", []):
		trade_nodes[t["id"]] = t
		trade_node_index[t["id"]] = n
		n += 1
	for b in data.get("buildings", []):
		buildings[b["id"]] = b
	for t in data.get("terrains", []):
		terrains[t["id"]] = t
	n = 1
	for a in data.get("areas", []):
		areas[a["id"]] = a
		area_index[a["id"]] = n
		n += 1
	n = 1
	for r in data.get("regions", []):
		regions[r["id"]] = r
		region_index[r["id"]] = n
		n += 1
	for r in data.get("superregions", []):
		superregions[r["id"]] = r
	for c in data.get("continents", []):
		continents[c["id"]] = c
	adjacencies = data.get("adjacencies", [])
	technologies = data.get("technologies", {})
	for g in data.get("tech_groups", []):
		tech_groups[g["id"]] = g
	for u in data.get("units", []):
		units[u["id"]] = u
	idea_groups = data.get("idea_groups", [])
	advisor_types = data.get("advisor_types", [])
	institutions = data.get("institutions", [])
	diplomacy = data.get("diplomacy", [])
	# união pessoal: o sócio menor tem o governante (e o herdeiro) do sócio maior, como no EU4
	# (Suécia e Noruega com Christopher III da Dinamarca em 1444)
	for r in diplomacy:
		if r.get("type", "") in ["union", "personal_union"] and countries.has(r["first"]) and countries.has(r["second"]):
			var senior: Dictionary = countries[r["first"]]
			var junior: Dictionary = countries[r["second"]]
			for k in ["monarch", "heir"]:
				if senior.get(k) is Dictionary and not (junior.get(k) is Dictionary and str(junior[k].get("name", "")) != ""):
					junior[k] = (senior[k] as Dictionary).duplicate(true)
	emperor = data.get("emperor", "")
	celestial_emperor = data.get("celestial_emperor", "")
	wars = data.get("wars", [])
	icons = data.get("icons", {})
	centers_of_trade = data.get("centers_of_trade", [])
	trade_rules = data.get("trade_rules", {})
	advisors = data.get("advisors", [])
	national_ideas = data.get("national_ideas", [])
	opinion_modifiers = data.get("opinion_modifiers", {})
	casus_belli = data.get("casus_belli", [])
	war_goals = data.get("war_goals", [])
	diplomacy_data = data.get("diplomacy_data", {})

	var ids_tex: Texture2D
	if ids_path.begins_with("user://"):
		# arquivo fora do projeto: carrega sem compressão (cada pixel é um id exato)
		id_image = Image.load_from_file(ids_path)
		ids_tex = ImageTexture.create_from_image(id_image)
	else:
		ids_tex = load(ids_path) as Texture2D
		id_image = ids_tex.get_image()

	# linhas 0-4 = províncias, linha 5 = paleta do terrain.bmp (por isso largura ≥ 256)
	palette_image = Image.create(maxi(provinces.size(), 256), 6, false, Image.FORMAT_RGBA8)
	for p in provinces:
		_write_palette(int(p["id"]))
	palette_tex = ImageTexture.create_from_image(palette_image)

	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/map.gdshader") as Shader
	mat.set_shader_parameter("ids", ids_tex)
	# rios (rivers.png ao lado do province_ids.png: índice da paleta do rivers.bmp do EU4)
	var rivers_path := ids_path.get_base_dir() + "/rivers.png"
	var rivers_tex: Texture2D = null
	if rivers_path.begins_with("user://"):
		if FileAccess.file_exists(rivers_path):
			rivers_tex = ImageTexture.create_from_image(Image.load_from_file(rivers_path))
	elif ResourceLoader.exists(rivers_path):
		rivers_tex = load(rivers_path) as Texture2D
	river_lines = data.get("rivers", [])
	if rivers_tex and river_lines.is_empty():      # sem as linhas (importação antiga): os pixels
		mat.set_shader_parameter("rivers", rivers_tex)
		mat.set_shader_parameter("has_rivers", true)
	# bandeiras (flags.png ao lado do province_ids.png: atlas com FLAG_SIZE px por país)
	var flags_path := ids_path.get_base_dir() + "/flags.png"
	if flags_path.begins_with("user://"):
		if FileAccess.file_exists(flags_path):
			_flags_tex = ImageTexture.create_from_image(Image.load_from_file(flags_path))
	elif ResourceLoader.exists(flags_path):
		_flags_tex = load(flags_path) as Texture2D
	ui_dir = ids_path.get_base_dir() + "/ui"
	gui_dir = ids_path.get_base_dir() + "/gui"
	# ícones da interface (icons.png: atlas com ICON_SIZE px por ícone)
	var icons_path := ids_path.get_base_dir() + "/icons.png"
	if icons_path.begins_with("user://"):
		if FileAccess.file_exists(icons_path):
			_icons_tex = ImageTexture.create_from_image(Image.load_from_file(icons_path))
	elif ResourceLoader.exists(icons_path):
		_icons_tex = load(icons_path) as Texture2D
	mat.set_shader_parameter("palette", palette_tex)
	map_dir = ids_path.get_base_dir()
	_load_map_textures(data.get("map_textures", {}))
	mat.set_shader_parameter("map_size", Vector2(map_w, map_h))
	mat.set_shader_parameter("selected_id", -1)
	material = mat

	texture = ids_tex
	centered = false
	scale = Vector2(map_scale, map_scale)

	if not trade_nodes.is_empty():
		trade_flows = TradeFlows.new()
		trade_flows.visible = false
		add_child(trade_flows)
		trade_flows.setup(self)


## Troca os nomes pelos da localização do EU4 (chaves do próprio jogo; sem a chave fica o nome atual).
func _apply_loc(data: Dictionary) -> void:
	var by_id := func(list_key: String, prefix := "") -> void:
		for e in data.get(list_key, []):
			if e is Dictionary and e.has("id"):
				e["name"] = Loc.t(prefix + str(e["id"]), str(e.get("name", e["id"])))
	for p in data["provinces"]:
		p["name"] = Loc.t("PROV%d" % int(p["id"]), str(p.get("name", "")))
	for c in data["countries"]:
		c["name"] = Loc.t(str(c["tag"]), str(c.get("name", "")))
	for k in ["cultures", "religions", "trade_goods", "trade_nodes", "areas", "regions", "superregions", "continents",
			"governments", "institutions", "advisor_types", "units", "centers_of_trade"]:
		by_id.call(k)
	by_id.call("buildings", "building_")
	for t in data.get("terrains", []):
		t["name"] = Loc.t(str(t.get("eu4", "")), str(t["id"]).capitalize())
	for list_key in ["idea_groups", "national_ideas"]:
		for g in data.get(list_key, []):
			g["name"] = Loc.t(str(g["id"]), str(g.get("name", "")))
			for i in g.get("ideas", []):
				i["name"] = Loc.t(str(i["id"]), str(i.get("name", "")))
	var techs: Dictionary = data.get("technologies", {})
	for cat in techs:
		for t in techs[cat]:
			var key := "%s_tech_cs_%d_name" % [cat, int(t["level"])]
			if Loc.has(key):
				t["name"] = Loc.t(key)


## Soma de um efeito das construções da província (local_tax_modifier, trade_goods_size...).
func building_mod(p: Dictionary, key: String) -> float:
	var s := 0.0
	for b in p.get("buildings", []):
		s += float(buildings.get(b, {}).get("modifiers", {}).get(key, 0.0))
	for m in p.get("modifiers", []):        # modificadores permanentes do histórico (estuários, Sound Toll...)
		s += float(province_modifier(str(m)).get(key, 0.0))
	return s


## Efeitos numéricos de um modificador de common/event_modifiers (em cache).
func province_modifier(name: String) -> Dictionary:
	if not _event_mods.has(name):
		var d := {}
		var tree = Eu4Data.merged("common/event_modifiers").get(name, [])
		if tree is Array:
			for kv in tree:
				if kv is Array and kv.size() == 2 and str(kv[1]).is_valid_float():
					d[str(kv[0])] = float(str(kv[1]))
		_event_mods[name] = d
	return _event_mods[name]


## Bens produzidos por ano: (produção base × 0,2 + trade_goods_size das construções e modificadores)
## × (1 + trade_goods_size_modifier).
func goods_produced(p: Dictionary) -> float:
	return (float(p.get("base_production", float(p["development"]) / 3.0)) * 0.2 + building_mod(p, "trade_goods_size")) \
			* maxf(0.0, 1.0 + building_mod(p, "trade_goods_size_modifier"))


## Nome do modo de mapa (localização do EU4, senão em português).
static func map_mode_name(mode: int) -> String:
	return Loc.t(MAP_MODE_KEYS[mode], MAP_MODE_NAMES[mode])


## Nome do terreno (rótulo do mapa -> nome do EU4 com a localização, senão o rótulo).
func terrain_name(label: String) -> String:
	return str(terrains.get(label, {}).get("name", label.capitalize()))


## Bandeira do país (null se não houver bandeiras importadas).
func flag_texture(tag: String) -> Texture2D:
	if _flags_tex == null or not countries.has(tag) or not countries[tag].has("flag"):
		return null
	if not _flag_cache.has(tag):
		var i := int(countries[tag]["flag"])
		var at := AtlasTexture.new()
		at.atlas = _flags_tex
		at.region = Rect2((i % Eu4Importer.FLAGS_PER_ROW) * Eu4Importer.FLAG_SIZE,
				(i / Eu4Importer.FLAGS_PER_ROW) * Eu4Importer.FLAG_SIZE, Eu4Importer.FLAG_SIZE, Eu4Importer.FLAG_SIZE)
		_flag_cache[tag] = at
	return _flag_cache[tag]


## Ícone da interface do EU4 pela chave ("good:grain"...); null se não houver.
func icon_texture(key: String) -> Texture2D:
	if _icons_tex == null or not icons.has(key):
		return null
	if not _icon_cache.has(key):
		var i := int(icons[key])
		var at := AtlasTexture.new()
		at.atlas = _icons_tex
		at.region = Rect2((i % Eu4Importer.ICONS_PER_ROW) * Eu4Importer.ICON_SIZE,
				(i / Eu4Importer.ICONS_PER_ROW) * Eu4Importer.ICON_SIZE, Eu4Importer.ICON_SIZE, Eu4Importer.ICON_SIZE)
		_icon_cache[key] = at
	return _icon_cache[key]


## Ícone da ideia: o do seu primeiro efeito.
func idea_icon(idea: Dictionary) -> Texture2D:
	var m: Dictionary = idea.get("modifiers", {})
	return icon_texture("mod:" + str(m.keys()[0])) if not m.is_empty() else null


## TextureRect quadrado de `px` pixels com dica (para fileiras de ícones na interface).
static func icon_rect(tex: Texture2D, px: int, tip := "") -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.custom_minimum_size = Vector2(px, px)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.tooltip_text = tip
	if tip == "":
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## `c` com o ícone à esquerda (ou o próprio `c` se não houver ícone; com `keep_space`, um vão do
## tamanho do ícone para alinhar com as linhas que têm).
static func with_icon(tex: Texture2D, c: Control, px := 28, keep_space := false) -> Control:
	if tex == null and not keep_space:
		return c
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	hb.add_child(icon_rect(tex, px))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(c)
	return hb


func province_color(pid: int) -> Color:
	var p: Dictionary = provinces[pid]
	if p["sea"]:
		return SEA_COLOR
	if map_mode == MapMode.TERRENO:
		return TERRAIN_COLORS.get(p["terrain"], UNOWNED_COLOR)
	if map_mode == MapMode.CULTURA:
		return culture_color(p.get("culture", ""))
	if map_mode == MapMode.RELIGIAO:
		return religion_color(p.get("religion", ""))
	if map_mode == MapMode.PRODUTOS:
		return trade_good_color(p.get("trade_goods", ""))
	if map_mode == MapMode.COMERCIO:
		return trade_node_color(p.get("trade_node", ""))
	if map_mode == MapMode.REGIOES:
		return area_color(p.get("area", ""))
	if map_mode == MapMode.INSTITUICOES:
		return institution_color(pid)
	if map_mode == MapMode.DIPLOMACIA:
		return diplomacy_color(pid)
	var tag: String = p["owner"]
	if tag == "" or not countries.has(tag):
		return UNOWNED_COLOR
	var c: Array = countries[tag]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


func culture_color(cid: String) -> Color:
	if not cultures.has(cid):
		return UNOWNED_COLOR
	var c: Array = cultures[cid]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


func religion_color(rid: String) -> Color:
	if not religions.has(rid):
		return UNOWNED_COLOR
	var c: Array = religions[rid]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


func trade_good_color(gid: String) -> Color:
	if not trade_goods.has(gid):
		return UNOWNED_COLOR
	var c: Array = trade_goods[gid]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


func trade_node_color(nid: String) -> Color:
	if not trade_nodes.has(nid):
		return UNOWNED_COLOR
	var c: Array = trade_nodes[nid]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


## Cor do modo diplomacia: relação do dono com o país em foco; os outros ficam cinza (o Sacro
## Império em cinza dourado).
func diplomacy_color(pid: int) -> Color:
	var p: Dictionary = provinces[pid]
	var rel := diplo_view.relation(diplo_focus, p["owner"]) if diplo_view else ""
	if DIPLO_COLORS.has(rel):
		return DIPLO_COLORS[rel]
	if p["owner"] == "":
		return Color(0.30, 0.29, 0.27)
	return Color(0.52, 0.48, 0.36) if p.get("hre", false) else Color(0.42, 0.41, 0.38)


## Cor do modo instituições: a instituição mais recente, mais forte quanto maior a presença.
func institution_color(pid: int) -> Color:
	if inst_view == null:
		return UNOWNED_COLOR
	var iid := inst_view.focus()
	if iid == "":
		return UNOWNED_COLOR
	var c: Array = inst_view.by_id[iid]["color"]
	var t := inst_view.province_progress(iid, pid) / 100.0
	return Color(0.30, 0.29, 0.27).lerp(Color8(int(c[0]), int(c[1]), int(c[2])), t)


## Repinta a paleta no modo atual (quando os dados do modo mudam, ex.: instituições se espalhando).
func refresh_colors() -> void:
	for p in provinces:
		_write_palette(int(p["id"]))
	palette_tex.update(palette_image)


func area_color(aid: String) -> Color:
	if not areas.has(aid) or not areas[aid].has("color"):
		return UNOWNED_COLOR
	var c: Array = areas[aid]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


## Efeitos de uma construção em texto ("nível de forte +2, imposto +40%").
func building_effects(bid: String) -> String:
	if not buildings.has(bid):
		return ""
	if _building_pt.is_empty() and FileAccess.file_exists("res://data/construcoes_pt.json"):
		_building_pt = JSON.parse_string(FileAccess.get_file_as_string("res://data/construcoes_pt.json"))
	var labels: Dictionary = _building_pt.get("efeitos", {})
	var absolute: Array = _building_pt.get("absolutos", [])
	var parts := []
	var mods: Dictionary = buildings[bid].get("modifiers", {})
	for k in mods:
		var v = mods[k]
		if not (v is float or v is int) or not labels.has(k):
			continue
		var txt: String
		if k in absolute:
			txt = ("%+d" % v) if float(v) == floorf(v) else ("%+.2f" % v)
		else:
			txt = "%+d%%" % roundi(v * 100.0)
		if Loc.active():
			parts.append("%s: %s" % [Loc.modifier(k, Eu4Importer.pretty_key(k)), txt])
		else:
			parts.append("%s %s" % [labels[k], txt.replace(".", Loc.dec)])
	if buildings[bid].has("goods"):
		var names := []
		for g in buildings[bid]["goods"]:
			names.append(trade_goods[g]["name"] if trade_goods.has(g) else g)
		parts.append(Loc.s("produção de ", "produces ") + ", ".join(names))
	return ", ".join(parts)


## O modo de mapa tem dados neste mapa? (cultura e religião só existem em alguns mapas)
func has_map_mode(mode: MapMode) -> bool:
	match mode:
		MapMode.CULTURA:
			return not cultures.is_empty()
		MapMode.RELIGIAO:
			return not religions.is_empty()
		MapMode.PRODUTOS:
			return not trade_goods.is_empty()
		MapMode.COMERCIO:
			return not trade_nodes.is_empty()
		MapMode.REGIOES:
			return not areas.is_empty()
		MapMode.INSTITUICOES:
			return not institutions.is_empty()
		MapMode.DIPLOMACIA:
			return not diplomacy.is_empty()
	return true


func _write_palette(pid: int) -> void:
	var p: Dictionary = provinces[pid]
	var col := province_color(pid)
	col.a = 1.0
	palette_image.set_pixel(pid, 0, col)
	var owner_idx: int = country_index.get(p["owner"], 0)
	var cult_idx: int = culture_index.get(p.get("culture", ""), 0)
	var rel_idx: int = religion_index.get(p.get("religion", ""), 0)
	palette_image.set_pixel(pid, 2, Color((owner_idx >> 8) / 255.0, (rel_idx & 255) / 255.0,
			(rel_idx >> 8) / 255.0, 1.0))
	var good_idx: int = trade_good_index.get(p.get("trade_goods", ""), 0)
	var node_idx: int = trade_node_index.get(p.get("trade_node", ""), 0)
	palette_image.set_pixel(pid, 3, Color((good_idx & 255) / 255.0, (good_idx >> 8) / 255.0,
			(node_idx & 255) / 255.0, (node_idx >> 8) / 255.0))
	var area_idx: int = area_index.get(p.get("area", ""), 0)
	var reg_idx: int = region_index.get(p.get("region", ""), 0)
	palette_image.set_pixel(pid, 4, Color((area_idx & 255) / 255.0, (area_idx >> 8) / 255.0,
			(reg_idx & 255) / 255.0, (reg_idx >> 8) / 255.0))
	palette_image.set_pixel(pid, 1, Color((owner_idx & 255) / 255.0, (cult_idx & 255) / 255.0,
			(cult_idx >> 8) / 255.0, 1.0 if p["sea"] else 0.0))


func set_owner_of(pid: int, tag: String) -> void:
	var old: String = provinces[pid]["owner"]
	provinces[pid]["owner"] = tag
	owner_version += 1
	_write_palette(pid)
	palette_tex.update(palette_image)
	owner_changed.emit(pid, old, tag)


## Muda a religião da província (conversão) e atualiza a paleta (modo religião).
func set_religion_of(pid: int, rid: String) -> void:
	provinces[pid]["religion"] = rid
	_write_palette(pid)
	palette_tex.update(palette_image)


## Troca o modo de mapa (reescreve a paleta inteira uma vez; as bordas de país continuam).
func set_map_mode(mode: MapMode) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	# nos modos cultura, religião e produtos as bordas fortes separam culturas/religiões/produtos
	var bm := 0
	if mode == MapMode.CULTURA:
		bm = 1
	elif mode == MapMode.RELIGIAO:
		bm = 2
	elif mode == MapMode.PRODUTOS:
		bm = 3
	elif mode == MapMode.COMERCIO:
		bm = 4
	elif mode == MapMode.REGIOES:
		bm = 5
	if trade_flows:
		trade_flows.visible = mode == MapMode.COMERCIO
	mat.set_shader_parameter("border_mode", bm)
	mat.set_shader_parameter("terrain_view", mode == MapMode.TERRENO and has_terrain_textures)
	for p in provinces:
		_write_palette(int(p["id"]))
	palette_tex.update(palette_image)


## Texturas do mapa do EU4 (ver Eu4Importer._map_textures): relevo (normal.png) para a luz,
## altitude (height.png) para a profundidade do mar, terreno (terrain_idx.png + paleta do
## terrain.bmp) e colormaps (colormap.png, colormap_water.png) se a instalação tinha.
func _load_map_textures(info: Dictionary) -> void:
	var ld := func(name: String) -> Texture2D:
		return map_texture(name)
	for pr in [["normal.png", "normal_map", "has_normal"], ["height.png", "height_map", "has_height"],
			["colormap.png", "colormap", "has_colormap"], ["colormap_water.png", "water_colormap", "has_water_colormap"]]:
		var t: Texture2D = ld.call(pr[0])
		if t:
			mat.set_shader_parameter(pr[1], t)
			mat.set_shader_parameter(pr[2], true)
			if pr[0] == "colormap.png":
				has_terrain_textures = true
	var ti: Texture2D = ld.call("terrain_idx.png")
	var pal: Array = info.get("terrain_palette", [])
	if ti and pal.size() == 256:
		for i in 256:                  # linha 5 da paleta (o celular só aceita 8 texturas no shader)
			palette_image.set_pixel(i, 5, Color8(int(pal[i][0]), int(pal[i][1]), int(pal[i][2])))
		palette_tex.update(palette_image)
		mat.set_shader_parameter("terrain_idx", ti)
		has_terrain_textures = true
	# luz do EU4 (NGraphics LIGHT_DIRECTION: para onde a luz vai, x leste, y cima, z norte) em
	# coordenadas da imagem (x direita, y baixo, z para fora): vetor que aponta para a luz
	var lx := float(Eu4Data.define("NGraphics", "LIGHT_DIRECTION_X", -1.0))
	var ly := float(Eu4Data.define("NGraphics", "LIGHT_DIRECTION_Y", -1.0))
	var lz := float(Eu4Data.define("NGraphics", "LIGHT_DIRECTION_Z", 0.5))
	mat.set_shader_parameter("light_dir", Vector3(-lx, lz, -ly).normalized())


## Textura ao lado do province_ids.png ("terra_incognita.png"...), ou null.
func map_texture(name: String) -> Texture2D:
	var path := map_dir + "/" + name
	if path.begins_with("user://"):
		return ImageTexture.create_from_image(Image.load_from_file(path)) if FileAccess.file_exists(path) else null
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


## Província em Terra Incógnita para o jogador (não se seleciona nem mostra nada dela).
func hidden(pid: int) -> bool:
	return discovery != null and discovery.enabled and pid >= 0 and not discovery.knows(discovery.power.player, pid)


func select(pid: int) -> void:
	selected_id = pid
	mat.set_shader_parameter("selected_id", pid)


## Retorna o id da província sob a posição do mouse (ou -1).
func province_at_mouse() -> int:
	var p := get_local_mouse_position()
	var x := int(p.x)
	var y := int(p.y)
	if x < 0 or y < 0 or x >= map_w or y >= map_h:
		return -1
	var c := id_image.get_pixel(x, y)
	return c.r8 + c.g8 * 256


func province_center(pid: int) -> Vector2:
	var c: Array = provinces[pid]["center"]
	return Vector2(c[0], c[1]) * scale


func provinces_of(tag: String) -> Array:
	if _owned_version != owner_version:         # refeito quando um dono muda (antes varria tudo a cada chamada)
		_owned.clear()
		for p in provinces:
			var t: String = p["owner"]
			if t != "":
				if not _owned.has(t):
					_owned[t] = []
				_owned[t].append(p)
		_owned_version = owner_version
	return (_owned.get(tag, []) as Array).duplicate()


var _owned := {}                    # tag -> províncias (cache de provinces_of)
var _owned_version := -1
