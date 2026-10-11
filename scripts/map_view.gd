class_name MapView
extends Sprite2D
## Mapa político baseado em imagem de IDs + shader.
## assets/province_ids.png guarda o id de cada província (R = byte baixo, G = byte alto).
## A cor de cada província vive numa textura-paleta; mudar o dono atualiza só 2 pixels.

const SEA_COLOR := Color(0.16, 0.30, 0.46)
const UNOWNED_COLOR := Color(0.45, 0.43, 0.38)

var map_w: int
var map_h: int
var provinces: Array = []
var countries: Dictionary = {}     # tag -> dict
var country_index: Dictionary = {} # tag -> 1..N (0 = sem dono)
var id_image: Image
var palette_image: Image
var palette_tex: ImageTexture
var mat: ShaderMaterial
var selected_id := -1


func load_map(map_scale: float) -> void:
	# Se existir um mapa importado do EU4 (tools/import_eu4.py), ele tem prioridade.
	var json_path := "res://data/map.json"
	var ids_path := "res://assets/province_ids.png"
	if FileAccess.file_exists("res://data/eu4/map.json") and ResourceLoader.exists("res://assets/eu4/province_ids.png"):
		json_path = "res://data/eu4/map.json"
		ids_path = "res://assets/eu4/province_ids.png"
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

	var ids_tex := load(ids_path) as Texture2D
	id_image = ids_tex.get_image()

	palette_image = Image.create(provinces.size(), 2, false, Image.FORMAT_RGBA8)
	for p in provinces:
		_write_palette(int(p["id"]))
	palette_tex = ImageTexture.create_from_image(palette_image)

	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/map.gdshader") as Shader
	mat.set_shader_parameter("ids", ids_tex)
	mat.set_shader_parameter("palette", palette_tex)
	mat.set_shader_parameter("map_size", Vector2(map_w, map_h))
	mat.set_shader_parameter("selected_id", -1)
	material = mat

	texture = ids_tex
	centered = false
	scale = Vector2(map_scale, map_scale)


func province_color(pid: int) -> Color:
	var p: Dictionary = provinces[pid]
	if p["sea"]:
		return SEA_COLOR
	var tag: String = p["owner"]
	if tag == "" or not countries.has(tag):
		return UNOWNED_COLOR
	var c: Array = countries[tag]["color"]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


func _write_palette(pid: int) -> void:
	var p: Dictionary = provinces[pid]
	var col := province_color(pid)
	col.a = 1.0
	palette_image.set_pixel(pid, 0, col)
	var owner_idx: int = country_index.get(p["owner"], 0)
	palette_image.set_pixel(pid, 1, Color(owner_idx / 255.0, 0.0, 0.0, 1.0 if p["sea"] else 0.0))


func set_owner_of(pid: int, tag: String) -> void:
	provinces[pid]["owner"] = tag
	_write_palette(pid)
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
