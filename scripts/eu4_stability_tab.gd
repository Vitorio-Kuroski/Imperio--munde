class_name Eu4StabilityTab
extends RefCounted
## Aba "Estabilidade e Expansão" da tela do país (countrystabilityview.gui): estabilidade com a
## barra de −3 a +3, o botão de aumentar (custo em pontos adm; só para o jogador) e os efeitos
## atuais. O resto da aba (sobre-extensão, cansaço de guerra, colônias, agitação, desastres...)
## ainda não existe no jogo e fica escondido.

const KEEP := ["countryview_bg", "close_button", "window_title", "stability", "stability_icon",
		"stability_negative_progress", "stability_positive_progress", "stability_progress_frame",
		"stability_value", "stability_boost"]

var view: Eu4CountryView
var root: Control
var _effects: Label
var _effects_title: Label
var _ae: Label
var _ae_title: Label


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countrystabilityview")
	if root == null:
		return false
	for ch in root.get_children():
		if ch is Control and not (String(ch.name) in KEEP):
			(ch as Control).hide()
	var b := root.find_child("stability_boost", true, false) as BaseButton
	if b:
		b.pressed.connect(_on_boost)
	if not Loc.active():
		view._txt(root, "window_title", "Estabilidade e Expansão")
		view._txt(root, "stability", "Estabilidade")
		if b:
			view._set_button_text(b, "Aumentar")
	# efeitos da estabilidade atual: título na faixa vermelha e a lista na caixa grande de baixo
	# (no EU4 ali ficam a agitação e as revoltas, que o jogo ainda não tem)
	_effects_title = _label(Vector2(40, 352), Vector2(320, 20))
	_effects = _label(Vector2(36, 375), Vector2(260, 260))
	_effects.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# expansão agressiva: os países com mais AE contra nós (e quem já está em coalizão)
	_ae_title = _label(Vector2(300, 352), Vector2(240, 20))
	_ae = _label(Vector2(310, 375), Vector2(250, 205))
	_ae.clip_text = true
	_ae.mouse_filter = Control.MOUSE_FILTER_PASS
	return true


func _label(pos: Vector2, sz: Vector2) -> Label:
	var l := Label.new()
	view.gui.style_label(l, "vic_18")
	l.position = pos
	l.size = sz
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(l)
	return l


func fill(tag: String) -> void:
	var st := view.stability
	if st == null:
		return
	var s := st.of(tag)
	view._txt(root, "stability_value", Stability.fmt(s), st.tooltip(tag))
	var neg := root.find_child("stability_negative_progress", true, false) as Eu4Gui.Progress
	if neg:        # preto por cima do vermelho: o vermelho cresce do centro para a esquerda
		neg.set_value(1.0 - float(maxi(0, -s)) / float(-Stability.MIN))
	var pos := root.find_child("stability_positive_progress", true, false) as Eu4Gui.Progress
	if pos:
		pos.set_value(float(maxi(0, s)) / float(Stability.MAX))
	var b := root.find_child("stability_boost", true, false) as Eu4Gui.Button2
	if b:
		var why := st.why_not(tag) if tag == view.player else Loc.s("Só no seu país", "Only for your country")
		b.visible = tag == view.player
		b.disabled = why != ""
		b.tooltip_text = (Loc.s("Aumentar a estabilidade: %d pontos administrativos",
				"Increase stability: %d administrative power") % st.cost(tag)) + ("\n" + why if why != "" else "")
	var e := st.effects(tag)
	var shown := {}
	for k in Stability.TIP_KEYS:
		if e.has(k) and float(e[k]) != 0.0:
			shown[k] = e[k]
	_effects_title.text = Loc.s("Efeitos da estabilidade", "Effects of stability")
	_effects.text = str(view.fmt_mods.call(shown)).replace(", ", "\n") \
			if not shown.is_empty() and view.fmt_mods.is_valid() else Loc.s("Nenhum (estabilidade 0)", "None (stability 0)")


	_fill_ae(tag)


func _fill_ae(tag: String) -> void:
	var co: Coalition = view.diplo.coalition if view.diplo else null
	_ae.visible = co != null
	_ae_title.visible = co != null
	if co == null:
		return
	_ae_title.text = Loc.t("aggressive_expansion", "Expansão agressiva")
	var list := co.ae_against(tag)
	var lines := []
	var tips := []
	for x in list:
		var t: String = x[0]
		var line := "%s: %d%s" % [view.map.countries[t]["name"], roundi(x[1]),
				" *" if t in co.members_against(tag) else ""]
		if lines.size() < 7:
			lines.append(line)
		tips.append(line)
	if list.is_empty():
		lines.append(Loc.s("Nenhuma", "None"))
	var n := co.members_against(tag).size()
	if n > 0:
		lines.append(Loc.s("Coalizão contra nós: %d países", "Coalition against us: %d countries") % n)
	_ae.text = "\n".join(lines)
	_ae.tooltip_text = Loc.s("Com %d ou mais e opinião negativa, o país entra numa coalizão contra nós (*). Cai %s por ano.",
			"At %d or more with a negative opinion, the country joins a coalition against us (*). Decays %s per year.") % [
			roundi(co.threshold()), str(roundi(view.diplo._mod(Coalition.AE_ID, "yearly_decay", 2)))] \
			+ ("\n" + "\n".join(tips) if not tips.is_empty() else "")


func _on_boost() -> void:
	if view.stability and view.stability.boost(view.player):
		view.refresh()
