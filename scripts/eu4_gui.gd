class_name Eu4Gui
extends RefCounted
## Monta as telas do EU4 (interface/*.gui) com as texturas e as fontes do jogo do usuário, a partir
## do que o importador gravou na pasta gui/ ao lado do mapa (gui.json + PNGs + fontes .fnt).
##  - windowType -> Control; iconType -> Eu4Gui.Icon (TextureRect que só aceita o mouse onde a
##    imagem não é transparente); guiButtonType/buttonType/checkboxType -> TextureButton (quadros
##    do sprite: normal, mouse em cima, apertado, desativado); instantTextBoxType/textBoxType -> Label
##    com a fonte bitmap do EU4.
##  - "orientation" é o ponto do pai a que a posição se refere; "origo" é o ponto do próprio elemento.
##  - Cada elemento fica em `nodes` pelo nome (o primeiro com o nome vale) para o jogo preencher.

const ANCHORS := {"upper_left": Vector2(0, 0), "upper_right": Vector2(1, 0), "lower_left": Vector2(0, 1),
		"lower_right": Vector2(1, 1), "center": Vector2(0.5, 0.5), "center_up": Vector2(0.5, 0),
		"center_down": Vector2(0.5, 1), "center_left": Vector2(0, 0.5), "center_right": Vector2(1, 0.5),
		"left": Vector2(0, 0.5), "right": Vector2(1, 0.5)}

var dir := ""
var files := {}                     # nome do .gui -> árvore [[chave, valor]]
var sprites := {}                   # nome -> {kind, texture, texture2?, frames?, border?, size?}
var font_defs := {}                 # nome -> {fnt, page, color}
var nodes := {}                     # nome do elemento -> Control (do último build)
var _images := {}                   # caminho -> Image
var _textures := {}                 # caminho -> Texture2D
var _frames := {}                   # "caminho#quadro#n" -> AtlasTexture
var _fonts := {}                    # nome -> [FontFile, tamanho, cor]


## Carrega a pasta gui/ (null se não houver telas importadas).
static func open(gui_dir: String) -> Eu4Gui:
	var p := gui_dir + "/gui.json"
	if not FileAccess.file_exists(p):
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary) or (d.get("files", {}) as Dictionary).is_empty():
		return null
	var g := Eu4Gui.new()
	g.dir = gui_dir
	g.files = d["files"]
	g.sprites = d.get("sprites", {})
	g.font_defs = d.get("fonts", {})
	return g


# ------------------------------------------------------------------ texturas
func image(path: String) -> Image:
	if not _images.has(path):
		var img: Image = null
		var full := dir + "/" + path
		if full.begins_with("user://"):
			if FileAccess.file_exists(full):
				img = Image.load_from_file(full)
		elif ResourceLoader.exists(full):
			var t := load(full) as Texture2D
			if t:
				img = t.get_image()
		if img and img.is_compressed():
			img.decompress()
		if img:
			img.convert(Image.FORMAT_RGBA8)
		_images[path] = img
	return _images[path]


func texture(path: String) -> Texture2D:
	if not _textures.has(path):
		var img := image(path)
		_textures[path] = ImageTexture.create_from_image(img) if img else null
	return _textures[path]


## Número de quadros do sprite (tira horizontal). No escudo (maskedShieldType) os quadros são de
## outra textura (símbolos de súdito), a moldura é uma só.
func frames_of(sprite: String) -> int:
	var s: Dictionary = sprites.get(sprite, {})
	if s.get("kind", "") == "maskedshieldtype":
		return 1
	return int(s.get("frames", 1))


## Quadro `frame` (0 = primeiro) do sprite, ou null.
func sprite_frame(sprite: String, frame := 0) -> Texture2D:
	var s: Dictionary = sprites.get(sprite, {})
	if s.is_empty():
		return null
	var tex := texture(s["texture"])
	if tex == null:
		return null
	var n := maxi(1, frames_of(sprite))
	if n == 1:
		return tex
	frame = clampi(frame, 0, n - 1)
	var key := "%s#%d#%d" % [s["texture"], frame, n]
	if not _frames.has(key):
		var at := AtlasTexture.new()
		at.atlas = tex
		var w := tex.get_width() / n
		at.region = Rect2(frame * w, 0, w, tex.get_height())
		_frames[key] = at
	return _frames[key]


## Imagem do quadro (para o teste de clique nas partes transparentes).
func frame_image(sprite: String, frame := 0) -> Image:
	var s: Dictionary = sprites.get(sprite, {})
	if s.is_empty():
		return null
	var img := image(s["texture"])
	if img == null:
		return null
	var n := maxi(1, frames_of(sprite))
	if n == 1:
		return img
	var w := img.get_width() / n
	return img.get_region(Rect2i(clampi(frame, 0, n - 1) * w, 0, w, img.get_height()))


# ------------------------------------------------------------------ fontes bitmap (.fnt do EU4)
## [FontFile, tamanho, cor] da fonte do EU4 com esse nome (null se não houver).
func font(name: String) -> Array:
	if _fonts.has(name):
		return _fonts[name]
	var out: Array = []
	var fd: Dictionary = font_defs.get(name, {})
	if not fd.is_empty():
		var page := image(fd["page"])
		var text := ""
		var full: String = dir + "/" + fd["fnt"]
		if FileAccess.file_exists(full):
			text = FileAccess.get_file_as_bytes(full).get_string_from_ascii()
		if page and text != "":
			out = _bitmap_font(text, page)
			if not out.is_empty():
				var c := str(fd.get("color", "0xffffffff")).trim_prefix("0x")
				var col := Color.WHITE
				if c.length() == 8 and c.is_valid_hex_number():
					var v := c.hex_to_int()
					col = Color8((v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) & 255)
				out.append(col)
	_fonts[name] = out
	return out


static func _fields(line: String) -> Dictionary:
	var d := {}
	for part in line.split(" ", false):
		var i := part.find("=")
		if i > 0:
			d[part.substr(0, i)] = part.substr(i + 1).trim_prefix("\"").trim_suffix("\"")
	return d


## BMFont em texto (o EU4 usa ids do cp1252) -> [FontFile, tamanho].
func _bitmap_font(text: String, page: Image) -> Array:
	var ff := FontFile.new()
	var size := 0
	var line_h := 0
	var base := 0
	var chars := []
	var kerns := []
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.begins_with("info "):
			size = absi(int(_fields(line).get("size", "0")))
		elif line.begins_with("common "):
			var c := _fields(line)
			line_h = int(c.get("lineHeight", "0"))
			base = int(c.get("base", "0"))
		elif line.begins_with("char "):
			chars.append(_fields(line))
		elif line.begins_with("kerning "):
			kerns.append(_fields(line))
	if line_h <= 0 or chars.is_empty():
		return []
	if size <= 0:
		size = line_h
	var sz := Vector2i(size, 0)
	ff.fixed_size = size
	ff.set_texture_image(0, sz, 0, page)
	ff.set_cache_ascent(0, size, base)
	ff.set_cache_descent(0, size, line_h - base)
	for c in chars:
		var cp := _codepoint(int(c.get("id", "0")))
		if cp <= 0:
			continue
		var w := int(c.get("width", "0"))
		var h := int(c.get("height", "0"))
		ff.set_glyph_advance(0, size, cp, Vector2(int(c.get("xadvance", "0")), 0))
		ff.set_glyph_offset(0, sz, cp, Vector2(int(c.get("xoffset", "0")), int(c.get("yoffset", "0")) - base))
		ff.set_glyph_size(0, sz, cp, Vector2(w, h))
		ff.set_glyph_uv_rect(0, sz, cp, Rect2(int(c.get("x", "0")), int(c.get("y", "0")), w, h))
		ff.set_glyph_texture_idx(0, sz, cp, 0)
	for k in kerns:
		var a := _codepoint(int(k.get("first", "0")))
		var b := _codepoint(int(k.get("second", "0")))
		ff.set_kerning(0, size, Vector2i(a, b), Vector2(int(k.get("amount", "0")), 0))
	ff.fallbacks = [ThemeDB.fallback_font]
	return [ff, size]


static func _codepoint(id: int) -> int:
	return int(Eu4Importer.CP1252.get(id, id)) if id >= 0x80 and id <= 0x9F else id


## Aplica a fonte do EU4 ao rótulo (tamanho e cor da fonte).
func style_label(l: Label, font_name: String) -> void:
	var f := font(font_name)
	if f.is_empty():
		l.add_theme_font_size_override("font_size", 15)
		return
	l.add_theme_font_override("font", f[0])
	l.add_theme_font_size_override("font_size", f[1])
	l.add_theme_color_override("font_color", f[2])
	l.add_theme_constant_override("line_spacing", 0)


# ------------------------------------------------------------------ montagem
## Bloco windowType com esse nome em qualquer .gui carregado ([] se não houver).
func find_window(name: String) -> Array:
	for f in files:
		var w := _find(files[f], name)
		if not w.is_empty():
			return w
	return []


func _find(items: Array, name: String) -> Array:
	for kv in items:
		if kv[1] is Array:
			var k := (kv[0] as String).to_lower()
			if k == "windowtype" and _val(kv[1], "name") == name:
				return kv[1]
			var r := _find(kv[1], name)
			if not r.is_empty():
				return r
	return []


static func _val(items: Array, key: String, default: Variant = "") -> Variant:
	for kv in items:
		if (kv[0] as String).to_lower() == key:
			return kv[1]
	return default


static func _vec(items: Array, key: String) -> Vector2:
	var v = _val(items, key, null)
	if not (v is Array):
		return Vector2.ZERO
	return Vector2(str(_val(v, "x", "0")).to_float(), str(_val(v, "y", "0")).to_float())


static func _yes(items: Array, key: String) -> bool:
	return str(_val(items, key, "no")).to_lower() in ["yes", "1", "true"]


## Monta a janela `name`. Devolve um Control preso aos cantos do pai conforme a orientação.
func build(name: String) -> Control:
	var w := find_window(name)
	if w.is_empty():
		return null
	return _element("windowtype", w)


## Enche uma lista (listboxType) com `count` cópias da janela `item` (windowType); devolve as cópias.
func fill_list(list: Control, item: String, count: int) -> Array:
	var out := []
	var vb := list.get_node_or_null("Items") if list else null
	if vb == null:
		return out
	for ch in vb.get_children():
		vb.remove_child(ch)
		ch.queue_free()
	var w := find_window(item)
	if w.is_empty():
		return out
	var sz := _vec(w, "size")
	for i in count:
		var holder := Control.new()
		holder.custom_minimum_size = sz
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c := _element("windowtype", w)
		c.anchor_left = 0
		c.anchor_top = 0
		c.anchor_right = 0
		c.anchor_bottom = 0
		c.offset_left = 0
		c.offset_top = 0
		c.offset_right = sz.x
		c.offset_bottom = sz.y
		holder.add_child(c)
		vb.add_child(holder)
		out.append(c)
	return out


func _place(c: Control, items: Array, size: Vector2) -> void:
	var a: Vector2 = ANCHORS.get(str(_val(items, "orientation", "upper_left")).to_lower(), Vector2.ZERO)
	var o: Vector2 = ANCHORS.get(str(_val(items, "origo", "upper_left")).to_lower(), Vector2.ZERO)
	var pos := _vec(items, "position") - o * size
	c.anchor_left = a.x
	c.anchor_right = a.x
	c.anchor_top = a.y
	c.anchor_bottom = a.y
	c.offset_left = pos.x
	c.offset_top = pos.y
	c.offset_right = pos.x + size.x
	c.offset_bottom = pos.y + size.y


func _element(kind: String, items: Array) -> Control:
	var name := str(_val(items, "name", ""))
	var c: Control = null
	match kind:
		"windowtype", "containerwindowtype":
			c = Control.new()
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if _yes(items, "fullscreen"):
				c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				c.offset_top = _vec(items, "position").y
			else:
				_place(c, items, _vec(items, "size"))
			var bg := str(_val(items, "background", ""))
			if bg != "" and sprites.has(bg):
				var b := _icon(bg, 0, _vec(items, "size"))
				b.set_anchors_preset(Control.PRESET_FULL_RECT)
				c.add_child(b)
			for kv in items:
				if kv[1] is Array:
					var child := _element((kv[0] as String).to_lower(), kv[1])
					if child:
						c.add_child(child)
		"icontype":
			var spr := str(_val(items, "spritetype", _val(items, "quadtexturesprite", "")))
			if not sprites.has(spr):
				return null
			var sc := str(_val(items, "scale", "1")).to_float()
			var ic := _icon(spr, int(str(_val(items, "frame", "1")).to_float()) - 1, Vector2.ZERO)
			if _yes(items, "alwaystransparent"):
				ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ic.scale = Vector2(sc, sc) if sc > 0.0 else Vector2.ONE
			c = ic
			_place(c, items, ic.custom_minimum_size)
		"guibuttontype", "buttontype", "checkboxtype":
			var spr := str(_val(items, "quadtexturesprite", _val(items, "spritetype", "")))
			var b := Button2.new()
			if sprites.has(spr):
				b.setup(self, spr)
			var sc := str(_val(items, "scale", "1")).to_float()
			b.scale = Vector2(sc, sc) if sc > 0.0 else Vector2.ONE
			b.toggle_mode = kind == "checkboxtype"
			var txt := str(_val(items, "buttontext", ""))
			if txt != "":
				var l := Label.new()
				l.set_anchors_preset(Control.PRESET_FULL_RECT)
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				l.mouse_filter = Control.MOUSE_FILTER_IGNORE
				l.text = txt if not txt.contains("_") else ""
				style_label(l, str(_val(items, "buttonfont", "vic_18")))
				l.name = "Text"
				b.add_child(l)
			var tip := str(_val(items, "tooltip", ""))
			if tip != "" and not tip.contains("_"):
				b.tooltip_text = tip
			c = b
			_place(c, items, b.custom_minimum_size)
		"listboxtype", "smoothlistboxtype":
			var sc := ScrollContainer.new()
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			sc.mouse_filter = Control.MOUSE_FILTER_PASS
			var sz := _vec(items, "size")
			_place(sc, items, sz if sz.x > 0 and sz.y > 0 else Vector2(300, 200))
			var vb := VBoxContainer.new()
			vb.name = "Items"
			vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vb.add_theme_constant_override("separation", int(str(_val(items, "spacing", "0")).to_float()))
			sc.add_child(vb)
			c = sc
		"overlappingelementsboxtype":
			c = HBoxContainer.new()
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.add_theme_constant_override("separation", 2)
			_place(c, items, _vec(items, "size"))
		"instanttextboxtype", "textboxtype", "edittextboxtype", "editboxtype":
			var l := Label.new()
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			style_label(l, str(_val(items, "font", "vic_18")))
			var fmt := str(_val(items, "format", "left")).to_lower()
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if fmt in ["centre", "center"] \
					else (HORIZONTAL_ALIGNMENT_RIGHT if fmt == "right" else HORIZONTAL_ALIGNMENT_LEFT)
			var mw := str(_val(items, "maxwidth", "0")).to_float()
			var mh := str(_val(items, "maxheight", "0")).to_float()
			var lh := 18.0
			var f := font(str(_val(items, "font", "vic_18")))
			if not f.is_empty():
				lh = float(f[1])
			if mh > lh * 1.6:
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			var bs := _vec(items, "bordersize")
			var box := Vector2(mw if mw > 0 else 200.0, maxf(mh, lh))
			_place(l, items, box)
			l.offset_left += bs.x
			l.offset_right -= bs.x
			l.offset_top += bs.y
			l.clip_text = false
			l.text = ""
			c = l
		_:
			return null
	if c and name != "":
		c.name = name.validate_node_name()
		if not nodes.has(name):
			nodes[name] = c
	return c


func _icon(spr: String, frame: int, size: Vector2) -> Control:
	var s: Dictionary = sprites[spr]
	if s.get("kind", "") == "corneredtilespritetype":
		var np := NinePatchRect.new()
		np.texture = texture(s["texture"])
		var b: Array = s.get("border", [0, 0])
		np.patch_margin_left = b[0]
		np.patch_margin_right = b[0]
		np.patch_margin_top = b[1]
		np.patch_margin_bottom = b[1]
		var sz: Array = s.get("size", [0, 0])
		np.custom_minimum_size = size if size != Vector2.ZERO else Vector2(sz[0], sz[1])
		np.mouse_filter = Control.MOUSE_FILTER_STOP
		return np
	var ic := Icon.new()
	ic.set_sprite(self, spr, frame)
	return ic


## Ícone que só pega o mouse onde a imagem não é transparente (a arte do EU4 tem muito vazio).
class Icon extends TextureRect:
	var gui: Eu4Gui
	var sprite := ""
	var frame := 0
	var _img: Image

	func set_sprite(g: Eu4Gui, spr: String, f := 0) -> void:
		gui = g
		sprite = spr
		frame = f
		texture = g.sprite_frame(spr, f)
		_img = g.frame_image(spr, f)
		stretch_mode = TextureRect.STRETCH_SCALE
		expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		custom_minimum_size = texture.get_size() if texture else Vector2.ZERO
		size = custom_minimum_size

	func set_frame(f: int) -> void:
		if gui and f != frame:
			set_sprite(gui, sprite, f)

	func _has_point(p: Vector2) -> bool:
		if _img == null or not Rect2(Vector2.ZERO, size).has_point(p):
			return false
		var q := Vector2i(int(p.x * _img.get_width() / maxf(size.x, 1.0)), int(p.y * _img.get_height() / maxf(size.y, 1.0)))
		q = q.clamp(Vector2i.ZERO, Vector2i(_img.get_width() - 1, _img.get_height() - 1))
		return _img.get_pixelv(q).a > 0.1


## Botão do EU4: quadros do sprite = normal, mouse em cima, apertado, desativado (com menos
## quadros, o mouse em cima clareia o normal). `set_frame` troca o quadro base (estados como a velocidade).
class Button2 extends TextureButton:
	var gui: Eu4Gui
	var sprite := ""
	var base_frame := 0

	var _flag_rect: TextureRect          # escudo: bandeira recortada pela máscara, sob a moldura

	func setup(g: Eu4Gui, spr: String) -> void:
		gui = g
		sprite = spr
		_apply()
		var s: Dictionary = g.sprites.get(spr, {})
		if s.get("kind", "") == "maskedshieldtype" and s.has("texture2"):
			var mask := g.texture(s["texture2"])
			var over := texture_normal
			texture_normal = null
			texture_hover = null
			texture_pressed = null
			_flag_rect = TextureRect.new()
			_flag_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_flag_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			_flag_rect.stretch_mode = TextureRect.STRETCH_SCALE
			var ms := mask.get_size() if mask else Vector2(64, 64)
			_flag_rect.position = (custom_minimum_size - ms) / 2.0
			_flag_rect.size = ms
			var mat := ShaderMaterial.new()
			mat.shader = preload("res://shaders/masked_flag.gdshader")
			mat.set_shader_parameter("mask", mask)
			_flag_rect.material = mat
			add_child(_flag_rect)
			var o := TextureRect.new()
			o.texture = over
			o.mouse_filter = Control.MOUSE_FILTER_IGNORE
			o.size = custom_minimum_size
			add_child(o)

	## Escudo: bandeira (Texture2D comum, não AtlasTexture) mostrada dentro da moldura.
	func set_flag(tex: Texture2D) -> void:
		if _flag_rect:
			_flag_rect.texture = tex

	func set_frame(f: int) -> void:
		base_frame = f
		_apply()

	func _apply() -> void:
		var n := gui.frames_of(sprite)
		ignore_texture_size = true
		stretch_mode = TextureButton.STRETCH_SCALE
		texture_normal = gui.sprite_frame(sprite, base_frame)
		if base_frame == 0 and n in [3, 4]:
			texture_hover = gui.sprite_frame(sprite, 1)
			texture_pressed = gui.sprite_frame(sprite, 2)
			texture_disabled = gui.sprite_frame(sprite, 3) if n >= 4 else null
		else:
			texture_hover = null
			texture_pressed = null
			texture_disabled = null
		var img := gui.frame_image(sprite, base_frame)
		if img:
			var bm := BitMap.new()
			bm.create_from_image_alpha(img, 0.1)
			texture_click_mask = bm
		custom_minimum_size = texture_normal.get_size() if texture_normal else Vector2.ZERO
		size = custom_minimum_size
		if not mouse_entered.is_connected(_hover):
			mouse_entered.connect(_hover.bind(true))
			mouse_exited.connect(_hover.bind(false))

	func _hover(on: bool) -> void:
		if texture_hover == null:
			self_modulate = Color(1.25, 1.2, 1.1) if on and not disabled else Color.WHITE
