class_name Eu4EstatesTab
extends RefCounted
## Aba "Estamentos" da tela do país (countryestatesview.gui), como nas capturas do EU4 (Suécia 1444):
##  - no alto, a pizza das terras (coroa + estamentos, cores de common/estates) e a grade
##    estates_dev_share_gridbox (estate_dev_share_item: ícone + %, primeiro os estamentos, depois a
##    coroa com GFX_crownland; dica ESTATE_CONTROLS + influência das terras e equilíbrio); os efeitos
##    da terra da coroa com ícone e valor em verde/vermelho (crown_land_modifier_icon/desc_1–4); as
##    ações da coroa (Vender títulos, Convocar a dieta, Tomar terras — GFX_sale_of_titles,
##    GFX_summon_the_diet, GFX_seize_land; apagadas, ainda não existem); a agenda (nenhuma);
##  - a lista dos estamentos (estate_item): ícone (GFX_estates_icons, quadro = icon − 1), nome,
##    "N / 6", lealdade e influência (dicas com o equilíbrio e a mudança mensal), os três maiores
##    efeitos atuais (verde/vermelho) e a fileira de privilégios: os concedidos (ícone privilege_<x>;
##    no país do jogador, clicar revoga, com confirmação) e uma vaga vazia (GFX_privilege_blank) que
##    abre a janela Privileges;
##  - janela Privileges (estate_privileges_window de estate_privileges.gui): "Grant <estamento>
##    privileges" (PRIVILEGE_PICKER_SUB_TITLE), lista estate_privilege_entry na ordem do arquivo (os
##    com is_valid): ícone, nome, lealdade/influência/terra da coroa/absolutismo máximo, Modifiers
##    (efeitos atuais: escalados pela lealdade/influência e pelas terras), Effects (o on_granted pelo
##    Eu4Effects.describe), "Can't be revoked until" (cooldown_years a partir de hoje); clicar no
##    ícone concede (Estates.grant), apagado com o motivo.
## O Eu4Gui não monta gridBoxType: as grades são montadas aqui, nas posições dos slots.

const ROW_HEIGHT := 130                       # slotsize do estate_items_gridbox
const ROW_WIDTH := 500                        # largura do estates_listbox
const ROW_SHIFT := -28                        # position.x da janela estate_item
const PIE_CENTER := Vector2(29.5, 25.5)       # centro do disco na textura da moldura (pixels x 9–50, y 5–46)
const PIE_RADIUS := 20.0                      # dentro do aro escuro (raio médio 19,4)
const CROWN_COLOR := Color(0.92, 0.88, 0.80)  # a coroa na pizza
var YELLOW := Eu4Gui.TEXT_YELLOW            # cores do texto do EU4 (textcolors da vic_18, `setup`)
var GOOD := Eu4Gui.TEXT_GREEN
var BAD := Eu4Gui.TEXT_RED
const INTERACTIONS := [["GFX_sale_of_titles", "ESTATES_SALE_OF_TITLES_DESC", "Vender 10% da terra da coroa aos estamentos"],
		["GFX_summon_the_diet", "ESTATES_SUMMON_THE_DIET_DESC", "Convocar a dieta para escolher uma agenda"],
		["GFX_seize_land", "ESTATES_SEIZE_LAND_DESC", "Tomar 5% das terras dos estamentos para a coroa"]]
## Modificadores em que menos é melhor (para a cor do valor, como o EU4 pinta).
const LOWER_IS_BETTER := ["cost", "maintenance", "liberty_desire", "unrest", "autonomy", "corruption", "decay",
		"inflation", "interest", "war_exhaustion", "ae_impact", "build_time", "time"]

var view: Eu4CountryView
var root: Control
var _pie: Control
var _shares := []                   # [[cor, %]] da pizza
var _grid: Control                  # grade das terras
var _crown_btns: Control            # ações da coroa
var _win: Control                   # janela Privileges
var _win_estate := ""
var _confirm: ConfirmationDialog
var _pending := ""                  # privilégio a revogar


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countryestatesview")
	if root == null:
		return false
	YELLOW = v.gui.text_color("Y", YELLOW)
	GOOD = v.gui.text_color("G", GOOD)
	BAD = v.gui.text_color("R", BAD)
	for n in ["agenda_icon", "agenda_state"]:
		Eu4CountryView._hide(root, n)
	# pizza das terras (o sprite piechart não vira imagem: desenhada aqui, sob a moldura)
	var ov := root.find_child("dev_share_pie_chart_overlays", true, false) as Control
	_pie = Control.new()
	_pie.mouse_filter = Control.MOUSE_FILTER_PASS
	_pie.draw.connect(_draw_pie)
	if ov:                              # o disco da moldura (provinceView_chart_overlay) fica em (30, 26) com
		var sc: Vector2 = ov.scale      # raio 20,5 na textura de 62 × 65; o .gui ainda aumenta a moldura (scale)
		var r := PIE_RADIUS * sc.x
		_pie.position = ov.position + PIE_CENTER * sc - Vector2(r, r)
		_pie.size = Vector2(r, r) * 2.0
		ov.get_parent().add_child(_pie)
		ov.get_parent().move_child(_pie, ov.get_index())
	_grid = _grid_at("estates_dev_share_gridbox")
	_crown_btns = _grid_at("crown_land_interactions")
	if _crown_btns:
		for k in INTERACTIONS.size():
			var it := view.gui.build("crown_land_interaction_item")
			if it == null:
				continue
			_crown_btns.add_child(it)
			it.position = Vector2(48 * k, 0)
			var b := it.find_child("interaction_button", true, false) as Eu4Gui.Button2
			if b:
				if view.gui.sprites.has(INTERACTIONS[k][0]):
					b.setup(view.gui, INTERACTIONS[k][0])
				b.disabled = true
				b.tooltip_text = Loc.t(INTERACTIONS[k][1], INTERACTIONS[k][2]) + "\n" + Loc.s("Ainda não existe neste jogo", "Not in this game yet")
	if not Loc.active():
		view._txt(root, "window_title", "Estamentos")
		view._txt(root, "dev_share_title", "Terras dos estamentos")
		view._txt(root, "crownland_title", "Terra da coroa")
		view._txt(root, "agenda_title", "Agenda")
	# janela Privileges (no centro da tela, por cima da tela do país)
	_win = view.gui.build("estate_privileges_window")
	if _win:
		view.add_child(_win)
		_win.z_index = 3
		_win.hide()
		var cb := _win.find_child("close_button", true, false) as BaseButton
		if cb:
			cb.pressed.connect(func(): _win.hide())
		view._txt(_win, "header_label", Loc.t("PRIVILEGE_PICKER_TITLE", "Privilégios"))
	_confirm = ConfirmationDialog.new()
	view.add_child(_confirm)
	_confirm.confirmed.connect(func():
		if _pending != "" and _est().revoke(view.player, _pending):
			view.refresh()
		_pending = "")
	return true


## Control no lugar de um gridBoxType do .gui (o Eu4Gui não monta grades).
func _grid_at(name: String) -> Control:
	var it := _find_item(view.gui.find_window("countryestatesview"), name)
	if it.is_empty():
		return null
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.position = Eu4Gui._vec(it, "position")
	root.add_child(c)
	return c


func _find_item(items: Array, name: String) -> Array:
	for kv in items:
		if kv[1] is Array:
			if str(Eu4Gui._val(kv[1], "name", "")) == name:
				return kv[1]
			var r := _find_item(kv[1], name)
			if not r.is_empty():
				return r
	return []


func _est() -> Estates:
	return view.estates


## % como o EU4 mostra: truncado (11,5 → "11%", 15,8 → "15%").
func _pct(x: float, dec := 0) -> String:
	if dec == 0:
		return "%d%%" % int(floorf(x + 0.0001))
	return (("%." + str(dec) + "f%%") % x).replace(".", Loc.dec)


static var _absolute := []


## "+10.0%" / "−10.00" como o EU4: valores absolutos com 2 casas, percentuais com 1.
func _val_text(k: String, v: float) -> String:
	if _absolute.is_empty() and FileAccess.file_exists("res://data/ideias_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/ideias_pt.json"))
		if d is Dictionary:
			_absolute = d.get("absolutos", [])
	var t := ("%+.2f" % v) if k in _absolute else ("%+.1f%%" % (v * 100.0))
	return t.replace(".", Loc.dec)


static func good(k: String, v: float) -> bool:
	for w in LOWER_IS_BETTER:
		if w in k:
			return v < 0.0
	return v > 0.0


func fill(tag: String) -> void:
	var e := _est()
	if e == null or not e.of.has(tag):
		view.gui.fill_list(root.find_child("estates_listbox", true, false) as Control, "", 0)
		return
	# pizza e grade das terras: os estamentos e depois a coroa
	_shares = []
	var cells := []
	for id in e.of[tag]:
		_shares.append([_color(id), e.land_of(tag, id)])
		cells.append([id, e.land_of(tag, id)])
	_shares.append([CROWN_COLOR, e.crown_land(tag)])
	cells.append(["", e.crown_land(tag)])
	_pie.queue_redraw()
	if _grid:
		for c in _grid.get_children():
			c.queue_free()
		for k in cells.size():
			var it := view.gui.build("estate_dev_share_item")
			if it == null:
				break
			_grid.add_child(it)
			it.position = Vector2(58 * (k % 3), 30 * (k / 3))
			var id: String = cells[k][0]
			var ic := it.find_child("estate_icon", true, false) as Eu4Gui.Icon
			if ic:
				if id == "":
					if view.gui.sprites.has("GFX_crownland"):
						ic.set_sprite(view.gui, "GFX_crownland", 0)
						ic.scale = Vector2(0.6, 0.6)
				else:
					ic.set_frame(int(Estates._num(e.defs[id], "icon", 1)) - 1)
			var tip := ""
			if id == "":
				tip = Loc.s("A coroa controla %s das terras.", "The Crown controls %s of your land.") % _pct(cells[k][1], 1)
			else:
				tip = Loc.f("ESTATE_CONTROLS", {"ESTATE": e.name_of(id), "PERCENT": _pct(cells[k][1], 1)},
						"%s controla %s das terras." % [e.name_of(id), _pct(cells[k][1], 1)])
				var per := float(Eu4Data.define("NCountry", "ESTATE_INFLUENCE_PER_DEV", 0.5))
				var own := Estates._mods(Estates.tget(e.defs[id], "land_ownership_modifier"))
				var leq: float = float(own.get(Estates.short(id) + "_loyalty_modifier", 0.0)) * cells[k][1]
				tip += "\n--------------\n%s %s: %s" % [e.name_of(id), Loc.s("Influência", "Influence"), _pct(cells[k][1] * per, 1)]
				if leq != 0.0:
					tip += "\n%s %s: %+.1f%%" % [e.name_of(id), Loc.s("Equilíbrio da lealdade", "Loyalty Equilibrium"), leq]
			view._txt(it, "dev_share_text", _pct(cells[k][1]), tip)
			var dl := it.find_child("dev_share_text", true, false) as Label
			if dl:
				dl.modulate = YELLOW          # o EU4 escreve as porcentagens em amarelo
	# efeitos da terra da coroa
	var cl := e.crown_land(tag)
	var cmods := {}
	for b in e.crown_bonus:
		if cl >= float(b["from"]) and cl < float(b["to"]):
			cmods = b["modifier"]
	_mod_slots(root, "crown_land_modifier", cmods, 4, Loc.t("CROWN_LAND_NO_EFFECT", "Sem efeito"))
	view._txt(root, "agenda_effects", "", "")
	# estamentos
	var list := root.find_child("estates_listbox", true, false) as Control
	var rows := view.gui.fill_list(list, "estate_item", e.of[tag].size())
	if list is ScrollContainer:          # sem crescer com as linhas (o EU4 recorta)
		(list as ScrollContainer).horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		list.size.x = ROW_WIDTH
	for k in rows.size():
		var id: String = e.of[tag][k]
		var row: Control = rows[k]
		var holder := row.get_parent() as Control
		if holder:                      # slot do estate_items_gridbox: 500 × 130 (a janela tem 600 × 200)
			holder.custom_minimum_size = Vector2(ROW_WIDTH, ROW_HEIGHT)
		row.position.x = ROW_SHIFT       # a janela estate_item fica em x −28 no .gui
		var ic := row.find_child("icon", true, false) as Eu4Gui.Icon
		if ic:
			ic.set_frame(int(Estates._num(e.defs[id], "icon", 1)) - 1)
		view._txt(row, "name", e.name_of(id))
		var loy := e.loyalty_of(tag, id)
		var eq := e.equilibrium(tag, id)
		view._txt(row, "loyalty", _pct(loy), Loc.s("A lealdade de %s é %s e vai para o equilíbrio de %s (%s por mês).",
				"The %s loyalty is %s and will drift towards the equilibrium of %s every month by %s.") % [e.name_of(id),
				_pct(loy, 1), _pct(eq, 1), ("%+.2f" % _monthly(loy, eq)).replace(".", Loc.dec)])
		var inf := e.influence(tag, id)
		view._txt(row, "influence", _pct(inf), Loc.s("Influência de %s: %s (os efeitos valem × %s)", "%s influence: %s (effects × %s)") % [
				e.name_of(id), _pct(inf, 1), str(Estates.influence_scale(inf)).replace(".", Loc.dec)])
		_mod_slots(row, "modifier", e.estate_effects(tag, id), 3, "")
		_privileges(row, tag, id)


func _monthly(loy: float, eq: float) -> float:
	var lo := float(Eu4Data.define("NCountry", "ESTATE_LOYALTY_DECAY_BASE_MIN", 2.0))
	var hi := float(Eu4Data.define("NCountry", "ESTATE_LOYALTY_DECAY_BASE_MAX", 5.0))
	var diff := eq - loy
	var rate := lerpf(lo, hi, clampf(absf(diff) / 50.0, 0.0, 1.0)) / 12.0
	return clampf(diff, -rate, rate)


## Até `n` efeitos (os maiores em módulo) nas caixas <prefixo>_icon_i / _desc_i, com o ícone do
## modificador e o valor em verde (bom) ou vermelho (ruim).
func _mod_slots(parent: Control, prefix: String, mods: Dictionary, n: int, none: String) -> void:
	# rr_* (influência dos revolucionários/realistas) não aparece na tela do EU4
	var keys := mods.keys().filter(func(k): return absf(float(mods[k])) > 0.0001 and not str(k).begins_with("rr_"))
	keys.sort_custom(func(a, b): return absf(float(mods[a])) > absf(float(mods[b])))
	for i in n:
		var icon := _mod_icon(parent, "%s_icon_%d" % [prefix, i + 1])
		var desc := parent.find_child("%s_desc_%d" % [prefix, i + 1], true, false) as Label
		if i < keys.size():
			var k: String = keys[i]
			var v := float(mods[k])
			var tip := str(view.fmt_mods.call({k: v})) if view.fmt_mods.is_valid() else k
			if icon:
				var tex := view.map.icon_texture("mod:" + k)
				icon.texture = tex
				icon.visible = tex != null
				icon.tooltip_text = tip
				icon.mouse_filter = Control.MOUSE_FILTER_PASS
				icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				icon.size = Vector2(22, 22)
			if desc:
				desc.show()
				view._txt(parent, "%s_desc_%d" % [prefix, i + 1], _val_text(k, v), tip)
				desc.modulate = GOOD if good(k, v) else BAD
		else:
			if icon:
				icon.hide()
			if desc:
				desc.visible = i == 0 and none != ""
				desc.modulate = Color.WHITE
				if desc.visible:
					view._txt(parent, "%s_desc_%d" % [prefix, i + 1], none, Loc.t("CROWN_LAND_NO_EFFECT_TOOLTIP", ""))


## Ícone de um efeito (modifier_icon_N / crown_land_modifier_icon_N). O .gui usa
## GFX_event_bg_transparency (o EU4 troca pelo ícone do modificador), que não é importado: o
## elemento não existe e é criado aqui, na posição do .gui.
func _mod_icon(parent: Control, n: String) -> TextureRect:
	var ic := parent.find_child(n, true, false) as TextureRect
	if ic:
		return ic
	var win := "estate_item" if n.begins_with("modifier_") else "countryestatesview"
	var it := _find_item(view.gui.find_window(win), n)
	if it.is_empty():
		return null
	ic = TextureRect.new()
	ic.name = n
	ic.position = Eu4Gui._vec(it, "position")
	var desc := parent.find_child(n.replace("_icon_", "_desc_"), true, false) as Control
	(desc.get_parent() if desc else parent).add_child(ic)
	return ic


## Fileira de privilégios: os concedidos e uma vaga vazia que abre a janela; "N / 6".
func _privileges(row: Control, tag: String, id: String) -> void:
	var e := _est()
	var mine := e.privileges_of(tag, id)
	var maxp := e.max_privileges(tag)
	view._txt(row, "privileges_count", "%d / %d" % [mine.size(), maxp], Loc.s("Privilégios concedidos", "Granted privileges"))
	var list := row.find_child("privileges_list", true, false) as Control
	var sb := row.find_child("privileges_scrollbar", true, false) as Control
	if sb:                              # a fileira cabe sem rolar (até 6 + a vaga): o EU4 não mostra a barra
		sb.hide()
	if list == null:
		return
	var holder := Control.new()            # a lista do EU4 é horizontal: ícones lado a lado
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.get_parent().add_child(holder)
	holder.position = list.position
	list.hide()
	var n := mine.size() + (1 if mine.size() < maxp else 0)
	for k in n:
		var it := view.gui.build("estate_privilege_item")
		if it == null:
			break
		holder.add_child(it)
		it.position = Vector2(k * 52, 0)
		var b := it.find_child("privilege_button", true, false) as Eu4Gui.Button2
		var frame := it.find_child("privilege_frame_button", true, false) as BaseButton
		if k < mine.size():
			var p: String = mine[k]
			var spr := str(Estates.tget(e.privs[p], "icon"))
			if b and view.gui.sprites.has(spr):
				b.setup(view.gui, spr)
			var tip := e.text(p, tag, id, p) + "\n" + _mods_text(e.privilege_effects(tag, p))
			for c in [b, frame]:
				if c:
					c.tooltip_text = tip
			if tag == view.player and b:
				var pid: String = p
				b.pressed.connect(func(): _ask_revoke(pid))
		else:                           # vaga vazia: abre a janela Privileges
			if b:
				b.hide()
			if frame:
				frame.tooltip_text = Loc.f("PRIVILEGE_PICKER_SUB_TITLE", {"ESTATE": e.name_of(id)}, "Conceder privilégios")
				frame.disabled = tag != view.player
				var eid: String = id
				frame.pressed.connect(func(): open_privileges(eid))


func _ask_revoke(p: String) -> void:
	var e := _est()
	var why := e.why_not_revoke(view.player, p)
	if why != "":
		view.message.emit(why)
		return
	_pending = p
	_confirm.dialog_text = Loc.s("Revogar \"%s\"? %s perde 20% de lealdade.", "Revoke \"%s\"? %s loses 20% loyalty.") % [
			e.text(p, view.player, e._estate_of_privilege(p), p), e.name_of(e._estate_of_privilege(p))]
	_confirm.popup_centered()


func _mods_text(m: Dictionary) -> String:
	if m.is_empty() or not view.fmt_mods.is_valid():
		return ""
	return str(view.fmt_mods.call(m)).replace(", ", "\n")


## Janela Privileges do estamento `id` (só para o jogador).
func open_privileges(id: String) -> void:
	if _win == null:
		return
	_win_estate = id
	_win.show()
	_fill_window()


func _fill_window() -> void:
	var e := _est()
	var tag := view.player
	var id := _win_estate
	view._txt(_win, "label", Loc.f("PRIVILEGE_PICKER_SUB_TITLE", {"ESTATE": e.name_of(id)}, "Conceder privilégios de " + e.name_of(id)))
	var list := _win.find_child("privileges_listbox", true, false) as Control
	var ps := e.grantable(tag, id).filter(func(p): return not (p in e.privileges.get(tag, [])))
	var rows := view.gui.fill_list(list, "estate_privilege_entry", ps.size())
	for k in rows.size():
		var p: String = ps[k]
		var row: Control = rows[k]
		var tree: Array = e.privs[p]
		view._txt(row, "title", e.text(p, tag, id, p), e.text(p + "_desc", tag, id, ""))
		var b := row.find_child("privilege_button", true, false) as Eu4Gui.Button2
		var spr := str(Estates.tget(tree, "icon"))
		if b and view.gui.sprites.has(spr):
			b.setup(view.gui, spr)
		# lealdade, influência, terra da coroa e absolutismo máximo
		_set_icon(row, "loyalty_icon", "GFX_estate_loyalty_L")
		_set_icon(row, "influence_icon", "GFX_estate_influence_L")
		var loy := Estates._num(tree, "loyalty", 0.0) * 100.0
		var inf := Estates._num(tree, "influence", 0.0) * 100.0
		var share := Estates._num(tree, "land_share", 0.0)
		var absm := Estates._num(tree, "max_absolutism", 0.0)
		_colored(row, "loyalty", "%d%%" % roundi(loy), loy, true)
		_colored(row, "influence", "%d%%" % roundi(inf), inf, false)
		_colored(row, "landshare", "%d%%" % roundi(-share), -share, true)
		_colored(row, "max_absolutism", "%d" % roundi(absm), absm, true)
		# efeitos (Modifiers) e o on_granted (Effects)
		var mods := e.privilege_effects(tag, p)
		var mt := _mods_text(mods)
		view._txt(row, "modifiers", Loc.s("Modificadores:", "Modifiers:") + "\n" + (mt if mt != "" else Loc.s("Sem mais modificadores.", "Has no further modifiers.")))
		var og = Estates.tget(tree, "on_granted")
		var lines: Array = view.effects.describe(og, tag, tag) if og is Array and view.effects else []
		view._txt(row, "effects", Loc.s("Efeitos:", "Effects:") + "\n" + ("\n".join(lines) if not lines.is_empty()
				else Loc.t("has_no_effects_on_granted", "Sem efeitos ao conceder.")))
		for n in ["modifiers", "effects"]:
			var l := row.find_child(n, true, false) as Label
			if l:
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				l.clip_text = true
		var cd := int(Estates._num(tree, "cooldown_years", 0.0))
		view._txt(row, "cooldown", Loc.f("ESTATE_PRIVILEGE_COOLDOWN", {"DATE": "%d.%d.%d" % [view.clock.year + cd, view.clock.month, view.clock.day]},
				"Não pode ser revogado até %d" % (view.clock.year + cd)) if cd > 0 else "")
		var why := e.why_not_grant(tag, p)
		if b:
			b.disabled = why != ""
			b.tooltip_text = Loc.s("Conceder", "Grant") + " " + e.text(p, tag, id, p) + ("\n" + why if why != "" else "")
			var pid: String = p
			b.pressed.connect(func():
				if e.grant(view.player, pid):
					_win.hide()
					view.refresh())


## Ícone da coluna: o .gui usa GFX_idea_unknown (o EU4 troca pelo do estamento), que não é
## importado — então o ícone é criado aqui, no canto da caixa (loyalty_entry...).
func _set_icon(row: Control, n: String, spr: String) -> void:
	if not view.gui.sprites.has(spr):
		return
	var nic := row.find_child(n, true, false) as TextureRect
	if nic is Eu4Gui.Icon:
		(nic as Eu4Gui.Icon).set_sprite(view.gui, spr, 0)
	var box := row.find_child(n.replace("_icon", "_entry"), true, false) as Control
	if nic == null and box:
		nic = view.gui._icon(spr, 0, Vector2.ZERO) as TextureRect
		nic.name = n
		box.add_child(nic)
	if nic:
		nic.scale = Vector2.ONE
		nic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		nic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		nic.custom_minimum_size = Vector2(24, 24)    # como o EU4 desenha (o elemento do .gui é menor)
		nic.size = Vector2(24, 24)
		nic.position = Vector2(4, 1)


## Valor da coluna em verde (bom), vermelho (ruim) ou amarelo (influência), como o EU4.
func _colored(row: Control, n: String, t: String, v: float, higher_good: bool) -> void:
	view._txt(row, n, t)
	var l := row.find_child(n, true, false) as Label
	if l:
		if not higher_good:
			l.modulate = YELLOW
		elif absf(v) < 0.001:
			l.modulate = Color.WHITE
		else:
			l.modulate = GOOD if (v > 0.0) == higher_good else BAD


func _color(id: String) -> Color:
	var c = Estates.tget(_est().defs.get(id, []), "color")
	if c is Array and c.size() >= 3:
		var v := []
		for x in c:
			v.append(float(str(x[1] if x is Array else x)))
		if v[0] > 1.0 or v[1] > 1.0 or v[2] > 1.0:
			return Color8(int(v[0]), int(v[1]), int(v[2]))
		return Color(v[0], v[1], v[2])
	return Color.from_hsv(float(hash(id) % 360) / 360.0, 0.5, 0.75)


func _draw_pie() -> void:
	var r := _pie.size.x / 2.0
	var ctr := Vector2(r, r)
	var tot := 0.0
	for s in _shares:
		tot += float(s[1])
	if tot <= 0.0:
		return
	var a0 := 0.0                       # como o EU4: começa às 3 horas e gira no sentido anti-horário
	for s in _shares:
		var frac := float(s[1]) / tot
		if frac <= 0.0:
			continue
		var pts := PackedVector2Array([ctr])
		var steps := maxi(2, ceili(64 * frac))
		for k in steps + 1:
			var a := a0 - TAU * frac * float(k) / float(steps)
			pts.append(ctr + Vector2(cos(a), sin(a)) * r)
		_pie.draw_colored_polygon(pts, s[0])
		# divisão antisserrilhada na cor da fatia (a borda de fora fica sob o aro da moldura)
		_pie.draw_line(ctr, pts[1], s[0], 1.0, true)
		a0 -= TAU * frac
