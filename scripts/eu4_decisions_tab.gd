class_name Eu4DecisionsTab
extends RefCounted
## Aba "Decisões e Políticas" da tela do país do EU4 (countrydecisionsview.gui):
##  - Políticas (`Policies`): para cada categoria o máximo (adm/dip/mil_capacity, BASE_POSSIBLE_POLICIES
##    + efeitos) e o custo mensal em pontos (adm/dip/mil_cost); as vagas numa linha centrada (espaço
##    50 como no .gui): adotadas (countrydecisionsview_activepolicy, os ícones dos dois grupos de
##    ideias que ela exige), vagas grátis (GFX_policy_icon_frame_free, o "+") e vagas pagas
##    (GFX_policy_icon_frame_empty, o "?"); clicar abre a new_policy_window com as políticas que o
##    país vê (potential) em três colunas; a lista dos efeitos somados (COUNTRY_POLICIES_EFFECT).
##  - Decisões nacionais (decisions/, via Eu4Data): as que o país vê (`potential` verdadeiro pelo
##    avaliador do CasusBelli; o que ele não conhece conta como falso), "major" com a faixa própria;
##    "?" com a descrição e as condições do `allow` (✓/✗). O botão de tomar (select_button) fica
##    ativo no país do jogador quando o `allow` vale; a dica lista os efeitos (`Eu4Effects.describe`)
##    e clicar pede confirmação e roda o bloco `effect` (`take`).

const SLOT := Vector2(100, 32)      # tamanho das janelas de vaga no .gui
const ROW_DROP := 17.0
const DECISION_TINT := Color(0.38, 0.62, 1.0)   # cor das faixas nas capturas do EU4
const MAJOR_TINT := Color(0.62, 0.95, 0.42)              # a faixa da decisão começa 17 px acima da linha (y −17)
const CAT_ROWS := {"adm": "adminstrative_policies", "dip": "diplomacy_policies", "mil": "military_policies"}

var view: Eu4CountryView
var root: Control
var _picking := false
var _decisions: Array = []         # [{id, major, potential, allow, effect}] (lidas uma vez)
var _confirm: ConfirmationDialog
var _pending := ""                 # decisão esperando a confirmação


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countrydecisionsview")
	if root == null:
		return false
	for cat in CAT_ROWS:
		var row := root.find_child(CAT_ROWS[cat], true, false) as BoxContainer
		if row:
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			row.add_theme_constant_override("separation", 50)
	var pw := root.find_child("new_policy_window", true, false) as Control
	if pw:
		pw.hide()
		var back := pw.find_child("back", true, false) as BaseButton
		if back:
			back.pressed.connect(func():
				_picking = false
				view.refresh())
	for f in Eu4Data.folder("decisions").values():
		for kv in f:
			if kv[0] != "country_decisions" or not (kv[1] is Array):
				continue
			for d in kv[1]:
				if not (d[1] is Array):
					continue
				var e := {"id": str(d[0]), "major": false, "potential": [], "allow": [], "effect": []}
				for x in d[1]:
					match x[0]:
						"major":
							e["major"] = str(x[1]) == "yes"
						"potential", "allow", "effect":
							e[x[0]] = x[1] if x[1] is Array else []
				_decisions.append(e)
	_confirm = ConfirmationDialog.new()
	_confirm.ok_button_text = Loc.t("DECISION_TAKE", Loc.s("Tomar a decisão", "Take decision"))
	_confirm.cancel_button_text = Loc.t("CANCEL", "Cancelar")
	_confirm.confirmed.connect(func():
		if take(view.player, _pending):
			view.message.emit(Loc.s("Decisão tomada: %s", "Decision taken: %s") % _title(_pending))
		view.refresh())
	root.add_child(_confirm)
	return true


func _find(id: String) -> Dictionary:
	for d in _decisions:
		if d["id"] == id:
			return d
	return {}


func _title(id: String) -> String:
	return Loc.t(id + "_title", Eu4Importer.pretty_key(id))


## Pode tomar a decisão agora (potential e allow verdadeiros)?
func can_take(tag: String, id: String) -> bool:
	var d := _find(id)
	var cbs: CasusBelli = view.diplo.cbs if view.diplo else null
	return not d.is_empty() and cbs != null and view.effects != null 			and cbs.check(d["potential"], tag, tag) == true and cbs.check(d["allow"], tag, tag) == true


## Toma a decisão: roda o bloco `effect` com ROOT = o país.
func take(tag: String, id: String) -> bool:
	if not can_take(tag, id):
		return false
	view.effects.run(_find(id)["effect"], tag)
	return true


func fill(tag: String) -> void:
	var pol: Policies = view.policies
	var mine := tag == view.player
	for cat in ["adm", "dip", "mil"]:
		if pol:
			view._txt(root, cat + "_capacity", str(pol.capacity(tag, cat)),
					Loc.s("Máximo de políticas nesta categoria", "Maximum policies in this category"))
			view._txt(root, cat + "_cost", ("%d" % roundi(pol.monthly_cost(tag, cat))),
					Loc.s("Pontos por mês gastos com políticas (%d grátis)", "Points per month spent on policies (%d free)") % pol.free_slots(tag, cat))
		_fill_slots(tag, cat, mine)
	view._txt(root, "modifiers_title", Loc.t("COUNTRY_POLICIES_EFFECT", "Nossas políticas nos dão:"))
	_fill_effects(tag)
	_fill_decisions(tag)
	var pw := root.find_child("new_policy_window", true, false) as Control
	if pw:
		pw.visible = _picking and mine
		if view._tabs:
			view._tabs.visible = not pw.visible     # a janela de escolher cobre a barra de abas
		if pw.visible:
			_fill_picker(tag, pw)


func _clear(box: Control) -> void:
	for ch in box.get_children():
		box.remove_child(ch)
		ch.queue_free()


func _fill_slots(tag: String, cat: String, mine: bool) -> void:
	var row := root.find_child(CAT_ROWS[cat], true, false) as Control
	if row == null:
		return
	_clear(row)
	var pol: Policies = view.policies
	var act: Array = pol.of(tag, cat) if pol else []
	var cap := pol.capacity(tag, cat) if pol else 3
	var free := pol.free_slots(tag, cat) if pol else 1
	for p in act:
		var it := view.gui.build("countrydecisionsview_activepolicy")
		if it == null:
			continue
		it.custom_minimum_size = SLOT
		var groups := _groups_of(pol.defs[p["id"]]["potential"])
		for i in 2:
			var b := it.find_child("button%d" % (i + 1), true, false) as Eu4Gui.Button2
			if b:
				var tex := view.map.icon_texture("group:" + groups[i]) if i < groups.size() else null
				if tex:
					b.texture_normal = tex
					b.texture_hover = null
					b.texture_pressed = null
					b.texture_click_mask = null
				b.tooltip_text = _policy_tip(p["id"]) + (("\n" + pol.why_not_cancel(tag, p["id"])) if mine else "")
				if mine:
					var pid: String = p["id"]
					b.pressed.connect(func():          # cancelar (depois de MINIMUM_POLICY_TIME anos)
						if pol.cancel(tag, pid):
							view.refresh())
		row.add_child(it)
	for i in range(act.size(), cap):
		var it := view.gui.build("countrydecisionsview_possiblepolicy")
		if it == null:
			continue
		it.custom_minimum_size = SLOT
		var b := it.find_child("button", true, false) as Eu4Gui.Button2
		if b:
			if i < free and view.gui.sprites.has("GFX_policy_icon_frame_free"):
				b.setup(view.gui, "GFX_policy_icon_frame_free")
			b.tooltip_text = (Loc.s("Vaga grátis", "Free slot") if i < free else Loc.s("Vaga (custa %d ponto por mês)", "Slot (costs %d point per month)") % 1) \
					+ ("\n" + Loc.s("Clique para escolher uma política", "Click to pick a policy") if mine else "")
			if mine:
				b.pressed.connect(func():
					_picking = true
					view.refresh())
		row.add_child(it)


## Grupos de ideias que a política exige (has_idea_group do potential), para os ícones.
func _groups_of(pot: Array) -> Array:
	var out := []
	for kv in pot:
		if kv[0] == "has_idea_group":
			out.append(str(kv[1]))
	return out


func _policy_tip(id: String) -> String:
	var pol: Policies = view.policies
	var mods: Dictionary = pol.defs.get(id, {}).get("modifiers", {})
	return pol.name_of(id) + ("\n" + str(view.fmt_mods.call(mods)) if view.fmt_mods.is_valid() else "")


func _fill_effects(tag: String) -> void:
	var list := root.find_child("modifiers_description_list", true, false) as Control
	if list == null or view.policies == null:
		return
	var mods := view.policies.modifiers(tag)
	var keys := mods.keys()
	var rows := view.gui.fill_list(list, "countrydecisionsview_policymodifier", keys.size())
	for i in rows.size():
		var k: String = keys[i]
		var tex := view.map.icon_texture("mod:" + k)
		var ic := rows[i].find_child("modifier_icon", true, false) as Eu4Gui.Icon
		if ic:
			ic.visible = tex != null
			if tex:
				ic.texture = tex
		view._txt(rows[i], "modifier_value", str(view.fmt_mods.call({k: mods[k]})) if view.fmt_mods.is_valid() else "%s %+.2f" % [k, mods[k]])


func _fill_decisions(tag: String) -> void:
	var list := root.find_child("decisions_listbox", true, false) as Control
	if list == null:
		return
	var cbs: CasusBelli = view.diplo.cbs if view.diplo else null
	var vis := []
	for d in _decisions:
		if cbs and cbs.check(d["potential"], tag, tag) == true:
			vis.append(d)
	vis.sort_custom(func(x, y): return x["major"] and not y["major"])   # as "major" primeiro
	view.gui.fill_list(list, "", 0)
	for d in vis:
		var row := view.gui.add_item(list, "countrydecisionsview_major_decision_entry" if d["major"] else "countrydecisionsview_decision_entry")
		if row == null:
			continue
		for ch in row.get_children():
			if ch is Control:
				(ch as Control).position.y += ROW_DROP
		var ban := row.find_child("decisions_banner", true, false) as CanvasItem
		if ban:                          # a faixa é cinza: o EU4 a pinta (verde nas "major", azul nas outras)
			ban.self_modulate = MAJOR_TINT if d["major"] else DECISION_TINT
		var di := row.find_child("decision_icon", true, false) as Control
		if di:
			di.hide()
		var title := _title(d["id"])
		var tl := row.find_child("title", true, false) as Label
		if tl:
			tl.text = title
			Eu4Gui.fit_label(tl)
		var ok: bool = cbs.check(d["allow"], tag, tag) == true
		var info := row.find_child("info_icon", true, false) as Control
		if info:
			info.mouse_filter = Control.MOUSE_FILTER_PASS
			info.tooltip_text = title + "\n\n" + Loc.t(d["id"] + "_desc", "") + "\n\n" + Loc.s("Requisitos:", "Requirements:") + "\n" \
					+ _requirements(d["allow"], tag, cbs)
		var sel := row.find_child("select_button", true, false) as BaseButton
		if sel:
			var fx := _effects_text(d, tag)
			var can := ok and tag == view.player and view.effects != null
			sel.disabled = not can
			sel.tooltip_text = (Loc.s("Os requisitos são cumpridos", "The requirements are met") if ok else Loc.s("Os requisitos não são cumpridos", "The requirements are not met")) \
					+ ":\n" + _requirements(d["allow"], tag, cbs) + "\n\n" + Loc.s("Efeitos:", "Effects:") + "\n" + fx
			if can:
				var did: String = d["id"]
				sel.pressed.connect(func():
					_pending = did
					_confirm.title = _title(did)
					_confirm.dialog_text = Loc.s("Tomar a decisão «%s»?", "Take the decision \"%s\"?") % _title(did) + "\n\n" + fx
					_confirm.popup_centered())
		var cb := row.find_child("decision_checkbox", true, false) as BaseButton
		if cb:
			cb.tooltip_text = Loc.s("Avisar quando der para tomar", "Notify when it can be taken")


func _effects_text(d: Dictionary, tag: String) -> String:
	if view.effects == null:
		return ""
	var lines: Array = view.effects.describe(d["effect"], tag)
	return "
".join(lines) if not lines.is_empty() else Loc.s("(só efeitos que este jogo ainda não mostra)", "(only effects this game does not show yet)")


var _trig: Eu4Triggers


## Requisitos (allow) como na dica do EU4 (`Eu4Triggers`: frases da localização, ✓/✗, recuo).
func _requirements(tree: Array, tag: String, cbs: CasusBelli) -> String:
	if _trig == null:
		_trig = Eu4Triggers.new(view.map, cbs)
	var t := _trig.text(tree, tag)
	return t if t != "" else Loc.s("(nenhum)", "(none)")


## Condições do allow, uma por linha, com ✓/✗ (? = o jogo ainda não sabe avaliar).
func _conditions(tree: Array, tag: String, cbs: CasusBelli) -> String:
	var lines := []
	for kv in tree:
		var r: Variant = cbs.check([kv], tag, tag) if cbs else null
		var mark := "✓" if r == true else ("✗" if r == false else "?")
		var v := str(kv[1]) if not (kv[1] is Array) else "{…}"
		lines.append("%s %s = %s" % [mark, kv[0], v])
	return "\n".join(lines)


func _fill_picker(tag: String, pw: Control) -> void:
	var pol: Policies = view.policies
	if pol == null:
		return
	for cat in ["adm", "dip", "mil"]:
		var ids := pol.visible(tag, cat)
		view._txt(pw, cat + "_count", "%d/%d" % [pol.of(tag, cat).size(), pol.capacity(tag, cat)])
		var list := pw.find_child(cat + "_list", true, false) as Control
		var rows := view.gui.fill_list(list, "countrydecisionsview_pickpolicy", ids.size())
		for i in rows.size():
			var id: String = ids[i]
			var row: Control = rows[i]
			view._txt(row, "title", pol.name_of(id))
			view._txt(row, "effect", str(view.fmt_mods.call(pol.defs[id]["modifiers"])) if view.fmt_mods.is_valid() else "")
			var b := row.find_child("select", true, false) as BaseButton
			if b:
				var why := pol.why_not_enact(tag, id)
				b.disabled = why != ""
				b.tooltip_text = _policy_tip(id) + (("\n" + why) if why != "" else "")
				b.pressed.connect(func():
					if pol.enact(tag, id):
						_picking = false
					view.refresh())
	_show(pw, "no_policy_explanation", pol.visible(tag, "adm").is_empty() and pol.visible(tag, "dip").is_empty() \
			and pol.visible(tag, "mil").is_empty())


func _show(r: Control, n: String, on: bool) -> void:
	var x := r.find_child(n, true, false) as Control
	if x:
		x.visible = on
