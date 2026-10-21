class_name Eu4Tooltip
extends CanvasLayer
## Dica (tooltip) como a do EU4, no lugar da dica do Godot (desligada: gui/timers/tooltip_delay_sec
## muito alto no project.godot). Tudo vem do EU4: o bloco textBoxType "ToolTip" de interface/core.gui
## (fundo tiles_dialog, borderSize 18, maxWidth 400) com a fonte ToolTip_Font (garamond_16) de core.gfx e as cores do texto de
## interface/core.gfx (textcolors da fonte; §R…§! vermelho, §Y amarelo, §G verde, como nas dicas do
## EU4 — `Loc.bbcode`). Mostra o tooltip_text do controle sob o mouse depois de DELAY segundos, junto
## do ponteiro e sempre dentro da tela, em escala inteira (1:1 como o EU4, ou 2× em telas grandes — `scale_of`).

const DELAY := 0.5                  # o mesmo atraso padrão das dicas do Godot que ela substitui
const OFFSET := Vector2(16, 16)     # distância do ponteiro

var gui: Eu4Gui
var scale_of: Callable              # -> float (main.gui_scale)
var _panel: PanelContainer
var _label: RichTextLabel
var _owner: Control
var _text := ""
var _time := 0.0
var _max_width := 400.0
var _colors := {}
var _wrap := 337.0                  # largura máxima do texto


func setup(g: Eu4Gui, scale_fn: Callable) -> void:
	gui = g
	scale_of = scale_fn
	layer = 128
	var box := _tooltip_box()
	var border := Eu4Gui._vec(box, "bordersize") if not box.is_empty() else Vector2(18, 18)
	_max_width = float(str(Eu4Gui._val(box, "maxwidth", "400")).to_float()) if not box.is_empty() else 400.0
	# a fonte das dicas é a ToolTip_Font de core.gfx (garamond_16); a vic_18 do textBoxType fica de reserva
	var font_name := "ToolTip_Font" if gui.font_defs.has("ToolTip_Font") else (str(Eu4Gui._val(box, "font", "vic_18")) if not box.is_empty() else "vic_18")
	var tex_path := str(Eu4Gui._val(box, "texturefile", "gfx/interface/tiles_dialog.tga")).replace("\\\\", "/").replace("\\", "/")
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxTexture.new()
	# o sprite "ToolTip" de core.gfx (textSpriteType com a textura tiles_dialog do textBoxType)
	var tex := gui.sprite_frame("ToolTip") if gui.sprites.has("ToolTip") else null
	if tex == null:
		tex = gui.texture(tex_path.get_basename() + ".png")
	if tex:
		sb.texture = tex
		sb.texture_margin_left = border.x
		sb.texture_margin_right = border.x
		sb.texture_margin_top = border.y
		sb.texture_margin_bottom = border.y
		sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
		sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	# medidas da dica do EU4 (captura 1366 × 768): texto até maxWidth − 3,5 × borderSize (337 px) e
	# margem de ¾ da borda em volta (a caixa fica com ~357 px)
	sb.content_margin_left = border.x * 0.75
	sb.content_margin_right = border.x * 0.75
	sb.content_margin_top = border.y * 0.75
	sb.content_margin_bottom = border.y * 0.75
	_wrap = _max_width - 3.5 * border.x
	_panel.add_theme_stylebox_override("panel", sb)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := gui.font(font_name)
	if not f.is_empty():
		_label.add_theme_font_override("normal_font", f[0])
		_label.add_theme_font_size_override("normal_font_size", f[1])
		_label.add_theme_color_override("default_color", f[2])
	_label.add_theme_constant_override("line_separation", 0)
	_panel.add_child(_label)
	add_child(_panel)
	_panel.hide()
	# cores: as textcolors da vic_18 (a fonte do textBoxType ToolTip) — as que a captura do EU4 mostra
	_colors = gui.text_colors(str(Eu4Gui._val(box, "font", "vic_18")) if not box.is_empty() else "vic_18")


## O textBoxType "ToolTip" de core.gui ([] se o core.gui não foi importado).
func _tooltip_box() -> Array:
	var tree: Array = gui.files.get("core", [])
	for kv in tree:
		if kv[1] is Array:
			for x in kv[1]:
				if x[1] is Array and (x[0] as String).to_lower() == "textboxtype" and str(Eu4Gui._val(x[1], "name", "")) == "ToolTip":
					return x[1]
			if (kv[0] as String).to_lower() == "textboxtype" and str(Eu4Gui._val(kv[1], "name", "")) == "ToolTip":
				return kv[1]
	return []


func _process(delta: float) -> void:
	var vp := get_viewport()
	var c := vp.gui_get_hovered_control()
	var text := ""
	if c and c.is_visible_in_tree():
		text = c.get_tooltip(c.get_local_mouse_position())
	if c != _owner or text != _text:
		_owner = c
		_text = text
		_time = 0.0
		_panel.hide()
	if text == "":
		return
	_time += delta
	if _time < DELAY:
		return
	if not _panel.visible:
		show_text(text)
	_place()


## Mostra a dica com `text` (códigos de cor do EU4) junto do ponteiro.
func show_text(text: String) -> void:
	# escala inteira (1:1 como o EU4; 2× em telas grandes): a garamond_16 tem traços de 1 px que
	# se deformam numa escala fracionária
	var sc: float = float(scale_of.call()) if scale_of.is_valid() else 1.0
	sc = maxf(1.0, floorf(sc))
	_panel.scale = Vector2(sc, sc)
	var inner := _wrap
	_label.text = Loc.bbcode(text, _colors)
	# largura: a da linha mais longa, até a maxWidth do EU4 (o texto quebra nela)
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size.x = 0
	_label.size.x = inner
	var w := minf(_label.get_content_width() + 2.0, inner)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size.x = w
	_label.size = Vector2(w, 0)
	_panel.reset_size()
	_panel.show()
	_place()


func _place() -> void:
	var vp := get_viewport().get_visible_rect().size
	var m := get_viewport().get_mouse_position()
	var sz := _panel.get_combined_minimum_size() * _panel.scale
	var p := m + OFFSET
	if p.x + sz.x > vp.x:
		p.x = maxf(0.0, m.x - OFFSET.x - sz.x)
	if p.y + sz.y > vp.y:
		p.y = maxf(0.0, m.y - OFFSET.y - sz.y)
	_panel.position = p
