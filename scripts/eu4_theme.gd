class_name Eu4Theme
extends RefCounted
## Tema da interface com as texturas do EU4 importadas (pasta ui/ ao lado do mapa importado):
## moldura das janelas (tiles_dialog), botões (button_straight), abas e barra de rolagem.
## Sem as texturas, build() devolve null e o jogo fica com o visual padrão do Godot.

const GOLD := Color(1.0, 0.86, 0.55)
const TEXT := Color(0.93, 0.90, 0.82)


static func _tex(dir: String, name: String) -> Texture2D:
	var p := "%s/%s.png" % [dir, name]
	if p.begins_with("user://"):
		if FileAccess.file_exists(p):
			var img := Image.load_from_file(p)
			if img and not img.is_empty():
				return ImageTexture.create_from_image(img)
		return null
	return load(p) as Texture2D if ResourceLoader.exists(p) else null


static func _box(t: Texture2D, margin: float, content: Vector4, mod := Color.WHITE) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = t
	sb.set_texture_margin_all(margin)
	sb.content_margin_left = content.x
	sb.content_margin_top = content.y
	sb.content_margin_right = content.z
	sb.content_margin_bottom = content.w
	sb.modulate_color = mod
	return sb


## Tema montado com as texturas da pasta `dir` (null se não houver a moldura das janelas).
static func build(dir: String) -> Theme:
	var panel := _tex(dir, "panel")
	if panel == null:
		return null
	var th := Theme.new()
	var small := _tex(dir, "panel_small")
	th.set_stylebox("panel", "PanelContainer", _box(panel, 32, Vector4(14, 12, 14, 12)))
	th.set_stylebox("panel", "PopupPanel", _box(panel, 32, Vector4(14, 12, 14, 12)))
	th.set_stylebox("panel", "TooltipPanel", _box(small if small else panel, 16 if small else 32, Vector4(9, 6, 9, 6)))
	# variação para barras e dicas pequenas (barra superior, dica do mapa)
	th.set_type_variation("Eu4Small", "PanelContainer")
	th.set_stylebox("panel", "Eu4Small", _box(small if small else panel, 16 if small else 32, Vector4(10, 4, 10, 4)))
	th.set_color("font_color", "Label", TEXT)
	th.set_color("font_color", "TooltipLabel", TEXT)

	var btn := _tex(dir, "button")
	if btn:
		var pad := Vector4(12, 5, 12, 5)
		th.set_stylebox("normal", "Button", _box(btn, 8, pad))
		th.set_stylebox("hover", "Button", _box(btn, 8, pad, Color(1.25, 1.2, 1.1)))
		th.set_stylebox("pressed", "Button", _box(btn, 8, pad, Color(0.75, 0.75, 0.75)))
		th.set_stylebox("disabled", "Button", _box(btn, 8, pad, Color(0.55, 0.55, 0.55, 0.8)))
		th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
		th.set_color("font_color", "Button", TEXT)
		th.set_color("font_hover_color", "Button", GOLD)
		th.set_color("font_pressed_color", "Button", GOLD)
		th.set_color("font_focus_color", "Button", TEXT)
		th.set_color("font_disabled_color", "Button", Color(0.6, 0.58, 0.54))
		# abas: a selecionada clara, as outras escurecidas
		th.set_stylebox("tab_selected", "TabContainer", _box(btn, 8, pad))
		th.set_stylebox("tab_hovered", "TabContainer", _box(btn, 8, pad, Color(0.95, 0.92, 0.85)))
		th.set_stylebox("tab_unselected", "TabContainer", _box(btn, 8, pad, Color(0.6, 0.6, 0.6)))
		th.set_stylebox("panel", "TabContainer", StyleBoxEmpty.new())
		th.set_color("font_selected_color", "TabContainer", GOLD)
		th.set_color("font_unselected_color", "TabContainer", TEXT)
		th.set_color("font_hovered_color", "TabContainer", GOLD)

	var track := _tex(dir, "scroll_track")
	var grab := _tex(dir, "scroll_grabber")
	if track and grab:
		for sb_type in ["VScrollBar", "HScrollBar"]:
			th.set_stylebox("scroll", sb_type, _box(track, 4, Vector4(2, 2, 2, 2)))
			th.set_stylebox("grabber", sb_type, _box(grab, 5, Vector4(4, 4, 4, 4)))
			th.set_stylebox("grabber_highlight", sb_type, _box(grab, 5, Vector4(4, 4, 4, 4), Color(1.25, 1.2, 1.1)))
			th.set_stylebox("grabber_pressed", sb_type, _box(grab, 5, Vector4(4, 4, 4, 4), Color(0.8, 0.8, 0.8)))
	return th
