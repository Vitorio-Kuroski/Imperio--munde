class_name Eu4MainMenu
extends Control
## Menu principal do EU4 (janelas mainmenu_panel_* do frontend.gui), a primeira tela do jogo: logo
## no alto à esquerda, logo do estúdio à direita e, embaixo, Single Player (abre a escolha de país),
## Multiplayer, Tutorial, Credits, Options (abre a tela de mapa/importação do jogo) e Exit, com a
## versão. Atrás, o mapa no modo terreno, como no EU4. Sem jogos salvos, "Continue Game" não aparece;
## multijogador, tutorial e créditos ainda não existem e ficam apagados. A loja de DLC
## (new_content) e os botões sociais/conta não entram.

signal single_player
signal options

const PANELS := ["mainmenu_panel_upperleft", "mainmenu_panel_upperright", "mainmenu_panel_bottom"]
const TODO := ["multi_player_button", "tutorial_button", "credits_button"]
const HIDE := ["continue_container", "nudge_button"]

var gui: Eu4Gui


func setup(g: Eu4Gui) -> bool:
	gui = g
	if gui.find_window("mainmenu_panel_bottom").is_empty():
		return false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for n in PANELS:
		var p := gui.build(n)          # position = show_position nos três
		if p == null:
			continue
		add_child(p)
		# janela fullScreen com orientation fora do canto: a origem dos filhos é o ponto da tela
		# (CENTER_DOWN) + position, como no EU4
		var w := gui._resolve(gui.find_window(n))
		var a: Vector2 = Eu4Gui.ANCHORS.get(str(Eu4Gui._val(w, "orientation", "upper_left")).to_lower(), Vector2.ZERO)
		if a != Vector2.ZERO:
			var pos := Eu4Gui._vec(w, "position")
			p.anchor_left = a.x
			p.anchor_right = a.x
			p.anchor_top = a.y
			p.anchor_bottom = a.y
			p.offset_left = pos.x
			p.offset_right = pos.x
			p.offset_top = pos.y
			p.offset_bottom = pos.y
	for n in HIDE:
		var c := find_child(n, true, false) as Control
		if c:
			c.hide()
	_button("single_player_button", func(): single_player.emit(), "")
	_button("settings_button", func(): options.emit(), Loc.s("Mapa e importação do EU4", "Map and EU4 import"))
	_button("exit_button", func(): get_tree().quit(), "")
	for n in TODO:
		var b := find_child(n, true, false) as BaseButton
		if b:
			b.disabled = true
			b.tooltip_text = Loc.s("Ainda não existe neste jogo", "Not in this game yet")
	var v := find_child("version_label", true, false) as Label
	if v:
		v.text = str(ProjectSettings.get_setting("application/config/name", "Imperium Mundi"))
		Eu4Gui.fit_label(v)
	return true


func _button(n: String, f: Callable, tip: String) -> void:
	var b := find_child(n, true, false) as BaseButton
	if b:
		b.pressed.connect(f)
		if tip != "":
			b.tooltip_text = tip
