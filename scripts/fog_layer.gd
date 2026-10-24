class_name FogLayer
extends Sprite2D
## Terra Incógnita e névoa de guerra desenhadas por cima do mapa, dos rios e dos nomes (filho do
## MapView, sob os exércitos): `shaders/fog.gdshader` com as texturas do EU4 (terra_incognita.png =
## map_overlay_tile.dds, fow_noise.png = Fogofwar.dds; sem elas, cor lisa e névoa sem ruído).
## O estado de cada província (`Discovery.view_image`) é assado por `shaders/fog_bake.gdshader` numa
## textura de 1/4 do mapa (SubViewport, só quando muda), lida com filtro linear: bordas suaves como a
## FoWTexture do EU4.

const CELL := 4                       # px do mapa por pixel da textura assada

var map: MapView
var discovery: Discovery
var _vp: SubViewport
var _bake: ColorRect


func setup(m: MapView, d: Discovery) -> void:
	map = m
	discovery = d
	texture = m.texture
	centered = false
	visible = false
	_vp = SubViewport.new()
	_vp.size = Vector2i(ceili(float(m.map_w) / CELL), ceili(float(m.map_h) / CELL))
	_vp.transparent_bg = false
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_bake = ColorRect.new()
	_bake.size = Vector2(_vp.size)
	var bm := ShaderMaterial.new()
	bm.shader = load("res://shaders/fog_bake.gdshader") as Shader
	bm.set_shader_parameter("ids", m.texture)
	bm.set_shader_parameter("view", d.view_tex)
	bm.set_shader_parameter("map_size", Vector2(m.map_w, m.map_h))
	bm.set_shader_parameter("cell", Vector2(float(m.map_w) / _vp.size.x, float(m.map_h) / _vp.size.y))
	_bake.material = bm
	_vp.add_child(_bake)
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/fog.gdshader") as Shader
	sm.set_shader_parameter("fow_map", _vp.get_texture())
	sm.set_shader_parameter("map_size", Vector2(m.map_w, m.map_h))
	var ti := _mipmapped(m.map_texture("terra_incognita.png"))
	if ti:
		sm.set_shader_parameter("ti_tex", ti)
		sm.set_shader_parameter("has_ti", true)
	var noise := _mipmapped(m.map_texture("fow_noise.png"))
	if noise:
		sm.set_shader_parameter("fow_noise", noise)
		sm.set_shader_parameter("has_noise", true)
	material = sm
	d.view_changed.connect(_rebake)


## Com mipmaps (a textura repetida fica pequena no zoom de longe).
static func _mipmapped(t: Texture2D) -> Texture2D:
	if t == null:
		return null
	var img := t.get_image()
	if img == null:
		return t
	if img.is_compressed():
		img.decompress()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _rebake() -> void:
	visible = discovery.enabled
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
