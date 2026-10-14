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

enum MapMode { POLITICO, TERRENO, CULTURA, RELIGIAO, PRODUTOS, COMERCIO, REGIOES }
const MAP_MODE_NAMES := ["político", "terreno", "cultura", "religião", "produtos", "comércio", "regiões"]

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
var trade_nodes: Dictionary = {}   # id -> dict (name, color, location, inland, end, outgoing)
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
var national_ideas: Array = []     # ideias nacionais/de grupo/genéricas (start, bonus, ideas); países têm "ideas"
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
var source := ""                   # de onde veio o mapa (caminho do map.json)


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
	advisors = data.get("advisors", [])
	national_ideas = data.get("national_ideas", [])

	var ids_tex: Texture2D
	if ids_path.begins_with("user://"):
		# arquivo fora do projeto: carrega sem compressão (cada pixel é um id exato)
		id_image = Image.load_from_file(ids_path)
		ids_tex = ImageTexture.create_from_image(id_image)
	else:
		ids_tex = load(ids_path) as Texture2D
		id_image = ids_tex.get_image()

	palette_image = Image.create(provinces.size(), 5, false, Image.FORMAT_RGBA8)
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
	if rivers_tex:
		mat.set_shader_parameter("rivers", rivers_tex)
		mat.set_shader_parameter("has_rivers", true)
	mat.set_shader_parameter("palette", palette_tex)
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
		parts.append("%s %s" % [labels[k], txt.replace(".", ",")])
	if buildings[bid].has("goods"):
		var names := []
		for g in buildings[bid]["goods"]:
			names.append(trade_goods[g]["name"] if trade_goods.has(g) else g)
		parts.append("produção de " + ", ".join(names))
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
	provinces[pid]["owner"] = tag
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
	for p in provinces:
		_write_palette(int(p["id"]))
	palette_tex.update(palette_image)


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
	var out := []
	for p in provinces:
		if p["owner"] == tag:
			out.append(p)
	return out
