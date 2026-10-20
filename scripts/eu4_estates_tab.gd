class_name Eu4EstatesTab
extends RefCounted
## Aba "Estamentos" da tela do país (countryestatesview.gui), como no EU4:
##  - no alto, a pizza das terras (coroa + estamentos, cores de common/estates) com a grade
##    estates_dev_share_gridbox (ícone + %, estate_dev_share_item); os efeitos atuais da terra da
##    coroa (crown_land_modifier_icon/desc_1–4); as ações da coroa (Tomar terras / Vender títulos,
##    apagadas: ainda não existem); a agenda (nenhuma: agendas não existem);
##  - a lista dos estamentos (estate_item): ícone (GFX_estates_icons, quadro = icon − 1), nome,
##    lealdade e influência (dicas com o equilíbrio, a mudança mensal e de onde vem a influência),
##    os três maiores efeitos atuais com o ícone do modificador e os privilégios (estate_privilege_item:
##    ícone privilege_<x> do .gfx, dica com os efeitos) e "N/6".
## O Eu4Gui não monta gridBoxType: as grades são montadas aqui, nas posições dos slots.

const ROW_HEIGHT := 130                       # slotsize do estate_items_gridbox
const ROW_WIDTH := 500                        # largura do estates_listbox
const CROWN_COLOR := Color(0.85, 0.78, 0.55)  # a coroa na pizza

var view: Eu4CountryView
var root: Control
var _pie: Control
var _shares := []                   # [[cor, %]] da pizza
var _grid: Control                  # grade das terras
var _crown_btns: Control            # ações da coroa


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countryestatesview")
	if root == null:
		return false
	for n in ["agenda_icon", "agenda_state"]:
		Eu4CountryView._hide(root, n)
	# pizza das terras (o sprite piechart não vira imagem: desenhada aqui, sob a moldura)
	var ov := root.find_child("dev_share_pie_chart_overlays", true, false) as Control
	_pie = Control.new()
	_pie.mouse_filter = Control.MOUSE_FILTER_PASS
	_pie.draw.connect(_draw_pie)
	if ov:
		var r := ov.size.x / 2.0
		_pie.position = ov.position + ov.size / 2.0 - Vector2(r, r) * 0.82
		_pie.size = Vector2(r, r) * 2.0 * 0.82
		ov.get_parent().add_child(_pie)
		ov.get_parent().move_child(_pie, ov.get_index())
	_grid = _grid_at("estates_dev_share_gridbox")
	_crown_btns = _grid_at("crown_land_interactions")
	if _crown_btns:
		for k in 2:
			var it := view.gui.build("crown_land_interaction_item")
			if it == null:
				continue
			_crown_btns.add_child(it)
			it.position = Vector2(48 * k, 0)
			var b := it.find_child("interaction_button", true, false) as BaseButton
			if b:
				b.disabled = true
				b.tooltip_text = (Loc.t("ESTATES_SEIZE_LAND_DESC", "Tomar 5% das terras dos estamentos para a coroa") if k == 0 \
						else Loc.t("ESTATES_SALE_OF_TITLES_DESC", "Vender 10% da terra da coroa aos estamentos")) \
						+ "\n" + Loc.s("Ainda não existe neste jogo", "Not in this game yet")
	if not Loc.active():
		view._txt(root, "window_title", "Estamentos")
		view._txt(root, "dev_share_title", "Terras dos estamentos")
		view._txt(root, "crownland_title", "Terra da coroa")
		view._txt(root, "agenda_title", "Agenda")
	return true


## Control no lugar de um gridBoxType do .gui (o Eu4Gui não monta grades).
func _grid_at(name: String) -> Control:
	var w := view.gui.find_window("countryestatesview")
	var it := _find_item(w, name)
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


func _pct(x: float) -> String:
	return "%d%%" % roundi(x)


## "+10%" / "−5" como o EU4, pelo mesmo formatador das ideias (o texto depois de ": ").
func _val_text(k: String, v: float) -> String:
	var t := str(view.fmt_mods.call({k: v})) if view.fmt_mods.is_valid() else "%+.2f" % v
	var i := t.rfind(": ")
	return t.substr(i + 2) if i >= 0 else t.split(" ")[-1]


func fill(tag: String) -> void:
	var e := _est()
	if e == null or not e.of.has(tag):
		view.gui.fill_list(root.find_child("estates_listbox", true, false) as Control, "", 0)
		return
	var map := view.map
	# pizza e grade das terras
	_shares = [[CROWN_COLOR, e.crown_land(tag)]]
	for c in (_grid.get_children() if _grid else []):
		c.queue_free()
	var cells := [["", e.crown_land(tag)]]
	for id in e.of[tag]:
		_shares.append([_color(id), e.land_of(tag, id)])
		cells.append([id, e.land_of(tag, id)])
	_pie.queue_redraw()
	if _grid:
		for k in cells.size():
			var it := view.gui.build("estate_dev_share_item")
			if it == null:
				break
			_grid.add_child(it)
			it.position = Vector2(58 * (k % 3), 30 * (k / 3))
			var ic := it.find_child("estate_icon", true, false) as Eu4Gui.Icon
			var id: String = cells[k][0]
			if ic:
				if id == "":
					ic.hide()       # a coroa não tem ícone na tira
				else:
					ic.set_frame(int(Estates._num(e.defs[id], "icon", 1)) - 1)
			var name := Loc.t("CROWN_LAND", "Coroa") if id == "" else Loc.t(id, Estates.short(id))
			view._txt(it, "dev_share_text", _pct(cells[k][1]), name + ": " + _pct(cells[k][1]))
	# efeitos da terra da coroa
	var cl := e.crown_land(tag)
	var cmods := {}
	for b in e.crown_bonus:
		if cl >= float(b["from"]) and cl < float(b["to"]):
			cmods = b["modifier"]
	_mod_slots(root, "crown_land_modifier", cmods, 4, Loc.t("CROWN_LAND_NO_EFFECT", "Sem efeito"))
	view._txt(root, "agenda_effects", Loc.s("Nenhuma agenda", "No agenda"), Loc.s("As agendas dos estamentos ainda não existem neste jogo",
			"Estate agendas are not in this game yet"))
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
		var ic := row.find_child("icon", true, false) as Eu4Gui.Icon
		if ic:
			ic.set_frame(int(Estates._num(e.defs[id], "icon", 1)) - 1)
		view._txt(row, "name", Loc.t(id, Estates.short(id)))
		var loy := e.loyalty_of(tag, id)
		var eq := e.equilibrium(tag, id)
		view._txt(row, "loyalty", _pct(loy), Loc.s("Lealdade %s: vai para o equilíbrio %s (%s por mês). Terras: %s",
				"Loyalty %s: drifting towards the equilibrium of %s (%s per month). Land: %s") % [_pct(loy), _pct(eq),
				("%+.2f" % _monthly(loy, eq)).replace(".", Loc.dec), _pct(e.land_of(tag, id))])
		var inf := e.influence(tag, id)
		view._txt(row, "influence", _pct(inf), Loc.s("Influência %s (os efeitos valem × %s)", "Influence %s (effects × %s)") % [
				_pct(inf), str(Estates.influence_scale(inf)).replace(".", Loc.dec)] + "\n" + Loc.t("ESTATE_INFLUENCE_TOOLTIP_DELAYED", "").replace("$DANGER|Y$", "100"))
		_mod_slots(row, "modifier", e.estate_effects(tag, id), 3, "")
		_privileges(row, tag, id)


func _monthly(loy: float, eq: float) -> float:
	var lo := float(Eu4Data.define("NCountry", "ESTATE_LOYALTY_DECAY_BASE_MIN", 2.0))
	var hi := float(Eu4Data.define("NCountry", "ESTATE_LOYALTY_DECAY_BASE_MAX", 5.0))
	var diff := eq - loy
	var rate := lerpf(lo, hi, clampf(absf(diff) / 50.0, 0.0, 1.0)) / 12.0
	return clampf(diff, -rate, rate)


## Até `n` efeitos (os maiores em módulo) nas caixas <prefixo>_icon_i / _desc_i, com o ícone do modificador.
func _mod_slots(parent: Control, prefix: String, mods: Dictionary, n: int, none: String) -> void:
	var keys := mods.keys().filter(func(k): return absf(float(mods[k])) > 0.0001)
	keys.sort_custom(func(a, b): return absf(float(mods[a])) > absf(float(mods[b])))
	for i in n:
		var icon := parent.find_child("%s_icon_%d" % [prefix, i + 1], true, false) as TextureRect
		var desc := parent.find_child("%s_desc_%d" % [prefix, i + 1], true, false) as Label
		if i < keys.size():
			var k: String = keys[i]
			var tip := str(view.fmt_mods.call({k: mods[k]})) if view.fmt_mods.is_valid() else k
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
				view._txt(parent, "%s_desc_%d" % [prefix, i + 1], _val_text(k, float(mods[k])), tip)
		else:
			if icon:
				icon.hide()
			if desc:
				desc.visible = i == 0 and none != ""
				if desc.visible:
					view._txt(parent, "%s_desc_%d" % [prefix, i + 1], none, Loc.t("CROWN_LAND_NO_EFFECT_TOOLTIP", ""))


## Privilégios do estamento (ícones na privileges_list) e "N/6".
func _privileges(row: Control, tag: String, id: String) -> void:
	var e := _est()
	var mine := e.privileges_of(tag, id)
	var maxp := int(Eu4Data.define("NCountry", "ESTATE_PRIVILEGES_MAX_CONCURRENT", 6))
	view._txt(row, "privileges_count", "%d/%d" % [mine.size(), maxp], Loc.s("Privilégios concedidos", "Granted privileges"))
	var list := row.find_child("privileges_list", true, false) as Control
	if list == null:
		return
	var holder := Control.new()            # a lista do EU4 é horizontal (spacing 20): ícones lado a lado
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.get_parent().add_child(holder)
	holder.position = list.position
	list.hide()
	for k in mine.size():
		var p: String = mine[k]
		var it := view.gui.build("estate_privilege_item")
		if it == null:
			break
		holder.add_child(it)
		it.position = Vector2(k * 52, 0)
		var b := it.find_child("privilege_button", true, false) as Eu4Gui.Button2
		var spr := str(Estates.tget(e.privs[p], "icon"))
		if b and view.gui.sprites.has(spr):
			b.setup(view.gui, spr)
		var mods := Estates._mods(Estates.tget(e.privs[p], "benefits"))
		var pen := Estates._mods(Estates.tget(e.privs[p], "penalties"))
		var lines := [Loc.t(p, p)]
		if not mods.is_empty():
			lines.append(view.fmt_mods.call(mods))
		if not pen.is_empty():
			lines.append(view.fmt_mods.call(pen))
		lines.append(Loc.s("Lealdade %+d%%, influência %+d%%, terras %+d%%", "Loyalty %+d%%, influence %+d%%, land %+d%%") % [
				roundi(Estates._num(e.privs[p], "loyalty", 0.0) * 100.0), roundi(Estates._num(e.privs[p], "influence", 0.0) * 100.0),
				roundi(Estates._num(e.privs[p], "land_share", 0.0))])
		for n in ["privilege_button", "privilege_frame_button"]:
			var c := it.find_child(n, true, false) as Control
			if c:
				c.tooltip_text = "\n".join(lines)


func _color(id: String) -> Color:
	var c = Estates.tget(e_defs(id), "color")
	if c is Array and c.size() >= 3:
		var r := float(str(c[0][1] if c[0] is Array else c[0]))
		var g := float(str(c[1][1] if c[1] is Array else c[1]))
		var bl := float(str(c[2][1] if c[2] is Array else c[2]))
		if r > 1.0 or g > 1.0 or bl > 1.0:
			return Color8(int(r), int(g), int(bl))
		return Color(r, g, bl)
	return Color.from_hsv(float(hash(id) % 360) / 360.0, 0.5, 0.75)


func e_defs(id: String) -> Array:
	return _est().defs.get(id, [])


func _draw_pie() -> void:
	var r := _pie.size.x / 2.0
	var ctr := Vector2(r, r)
	var tot := 0.0
	for s in _shares:
		tot += float(s[1])
	if tot <= 0.0:
		return
	var a0 := -PI / 2.0
	for s in _shares:
		var frac := float(s[1]) / tot
		if frac <= 0.0:
			continue
		var pts := PackedVector2Array([ctr])
		var steps := maxi(2, ceili(64 * frac))
		for k in steps + 1:
			var a := a0 + TAU * frac * float(k) / float(steps)
			pts.append(ctr + Vector2(cos(a), sin(a)) * r)
		_pie.draw_colored_polygon(pts, s[0])
		a0 += TAU * frac
