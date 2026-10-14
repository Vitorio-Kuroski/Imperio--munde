class_name Eu4ProvinceView
extends Control
## Tela da província do EU4 (provinceview.gui), no lugar do painel de texto da esquerda: nome,
## área e região, terreno, capital, imposto/produção/efetivo e desenvolvimento, renda, religião
## (com o ícone), cultura, efetivo e suprimento, produto (ícone e preço), nó de comércio, Sacro
## Império, construções e instituições. O que o jogo ainda não simula fica escondido (só os
## elementos de KEEP aparecem).

signal closed

## Elementos do .gui que aparecem (os outros e as janelas sem nenhum deles ficam escondidos).
const KEEP := ["provinceview_bg", "province_terrain", "trade_icon", "military_icon", "institution_icon",
		"province_banner", "provincename", "capitalname", "region_name", "have_capital", "close_button",
		"tax_base_icon", "tax_base_value", "prod_base_icon", "prod_base_value", "mp_base_icon", "mp_base_value",
		"development_icon", "development_value", "tax", "tax_value", "production", "production_value", "total",
		"total_value", "religion_title", "religion", "religion_icon", "culture_title", "culture", "hre_icon",
		"demographics_header", "military_header", "trade_header", "manpower", "manpower_value", "supply",
		"supply_value", "goodsproduced", "goodsproduced_value", "resource_icon", "resource_price_value",
		"resource_price_gold", "tradenode_button", "modifiers"]
## Subjanelas que o jogo ainda não usa (têm elementos com os mesmos nomes dos de KEEP).
const HIDE_WINDOWS := ["state_window", "buildings_window", "change_culture_view", "build_army_view", "build_navy_view",
		"foreign_province_window", "client_state_selection", "transfer_occupation_window", "tradegoods_province_window",
		"allied_objectives_list"]
## Os valores de imposto/produção/efetivo ficam em y = 0 no .gui; o EU4 os desce para a linha dos
## ícones (positionType development_value_vertical_position_not_exploitable).
const DEV_VALUE_Y := 68.0

var gui: Eu4Gui
var map: MapView
var institutions: Institutions
var terrain_tip: Callable          # rótulo do terreno -> texto extra (main.gd)
var pid := -1
var _win: Control


func setup(g: Eu4Gui, m: MapView, inst: Institutions) -> bool:
	gui = g
	map = m
	institutions = inst
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var w := g.find_window("provinceview")
	if w.is_empty():
		return false
	_win = g.build("provinceview")
	if _win == null:
		return false
	add_child(_win)
	# posição de quando a tela está aberta (show_position; a "position" é a de fora da tela)
	var sp := Eu4Gui._vec(w, "show_position")
	var sz := Eu4Gui._vec(w, "size")
	_win.offset_left = sp.x
	_win.offset_top = sp.y
	_win.offset_right = sp.x + sz.x
	_win.offset_bottom = sp.y + sz.y
	_keep_only(_win)
	for n in HIDE_WINDOWS:
		var x := _n(n)
		if x:
			x.hide()
	for n in ["tax_base_value", "prod_base_value", "mp_base_value"]:
		var l := _n(n)
		if l:
			var h := l.offset_bottom - l.offset_top
			l.offset_top = DEV_VALUE_Y
			l.offset_bottom = DEV_VALUE_Y + h
	var close := _n("close_button") as BaseButton
	if close:
		close.pressed.connect(func():
			hide()
			closed.emit())
		close.tooltip_text = "Fechar"
	_txt("demographics_header", "Demografia")
	_txt("military_header", "Militar")
	_txt("trade_header", "Comércio")
	_txt("tax", "Imposto:")
	_txt("production", "Produção:")
	_txt("total", "Total:")
	_txt("religion_title", "Religião")
	_txt("culture_title", "Cultura")
	_txt("manpower", "Efetivo:")
	_txt("supply", "Suprimento:")
	_txt("goodsproduced", "Bens produzidos:")
	_tip("tax_base_icon", "Imposto base")
	_tip("prod_base_icon", "Produção base")
	_tip("mp_base_icon", "Efetivo base")
	_tip("development_icon", "Desenvolvimento")
	hide()
	return true


## Esconde tudo o que não está em KEEP; uma janela fica visível se algo dentro dela fica.
func _keep_only(c: Control) -> bool:
	var any := false
	for ch in c.get_children():
		if not (ch is Control):
			continue
		var name := String(ch.name)
		var keep := name in KEEP
		if not keep and ch.get_child_count() > 0 and not (ch is BaseButton):
			keep = _keep_only(ch)
		ch.visible = keep
		any = any or keep
	return any


func _n(name: String) -> Control:
	return _win.find_child(name, true, false) as Control


func _txt(name: String, text: String) -> void:
	var c := _n(name)
	if c is Label:
		(c as Label).text = text
	elif c is BaseButton:
		var l := c.get_node_or_null("Text") as Label
		if l == null:
			l = Label.new()
			l.name = "Text"
			l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			gui.style_label(l, "vic_18")
			c.add_child(l)
		l.text = text


func _tip(name: String, text: String) -> void:
	var c := _n(name)
	if c:
		c.tooltip_text = text


func _show(name: String, on: bool) -> void:
	var c := _n(name)
	if c:
		c.visible = on


static func _num(x: float) -> String:
	return ("%.2f" % x).replace(".", ",")


## Mostra a província `id` (-1 ou mar esconde a tela).
func show_province(id: int) -> void:
	pid = id
	if id < 0 or id >= map.provinces.size() or map.provinces[id]["sea"]:
		hide()
		return
	var p: Dictionary = map.provinces[id]
	_txt("provincename", p["name"])
	var aid: String = p.get("area", "")
	var rid: String = p.get("region", "")
	_txt("capitalname", map.areas[aid]["name"] if map.areas.has(aid) else "")
	_txt("region_name", map.regions[rid]["name"] if map.regions.has(rid) else "")
	var owner: String = p["owner"]
	_show("have_capital", owner != "" and int(map.countries.get(owner, {}).get("capital", -1)) == id)
	_tip("have_capital", "Capital de " + str(map.countries.get(owner, {}).get("name", "")))
	_tip("province_banner", "Dono: %s" % (map.countries[owner]["name"] if map.countries.has(owner) else "ninguém"))
	# terreno
	var eu4_t := ""
	for t in map.terrains.values():
		if t.get("id", "") == p["terrain"]:
			eu4_t = t.get("eu4", "")
	var ter := _n("province_terrain") as Eu4Gui.Icon
	if ter:
		var spr := "GFX_combat_terrain_" + eu4_t
		ter.visible = gui.sprites.has(spr)
		if ter.visible:
			ter.set_sprite(gui, spr, 0)
		ter.tooltip_text = "Terreno: %s%s" % [p["terrain"], terrain_tip.call(p["terrain"]) if terrain_tip.is_valid() else ""]
	# desenvolvimento
	var bt := int(p.get("base_tax", 0))
	var bp := int(p.get("base_production", 0))
	var bm := int(p.get("base_manpower", 0))
	_txt("tax_base_value", str(bt))
	_txt("prod_base_value", str(bp))
	_txt("mp_base_value", str(bm))
	_txt("development_value", str(int(p["development"])))
	var gid: String = p.get("trade_goods", "")
	var price := float(map.trade_goods[gid]["price"]) if map.trade_goods.has(gid) else 0.0
	var tax := bt / 12.0
	var prod := bp * 0.2 * price / 12.0
	_txt("tax_value", _num(tax))
	_txt("production_value", _num(prod))
	_txt("total_value", _num(tax + prod))
	_tip("tax_value", "Ducados por mês")
	_tip("production_value", "Ducados por mês (produção × 0,2 × preço do produto)")
	# religião e cultura
	var rel: String = p.get("religion", "")
	_txt("religion", map.religions[rel]["name"] if map.religions.has(rel) else "—")
	var ri := _n("religion_icon") as Eu4Gui.Icon
	if ri:
		var icon := int(map.religions.get(rel, {}).get("icon", 0))
		ri.visible = icon > 0
		if icon > 0:
			ri.set_frame(icon - 1)
		ri.tooltip_text = map.religions[rel]["name"] if map.religions.has(rel) else ""
	var cul: String = p.get("culture", "")
	_txt("culture", map.cultures[cul]["name"] if map.cultures.has(cul) else "—")
	_tip("culture", ("Grupo: " + map.cultures[cul]["group"]) if map.cultures.has(cul) and map.cultures[cul]["group"] != "" else "")
	_show("hre_icon", p.get("hre", false))
	_tip("hre_icon", "Sacro Império Romano")
	# militar
	_txt("manpower_value", str(bm * 250))
	var sup := 0.0
	for t in map.terrains.values():
		if t.get("id", "") == p["terrain"]:
			sup = float(t.get("supply_limit", 0.0))
	_txt("supply_value", str(int(sup)) if sup > 0 else "—")
	# comércio
	_txt("goodsproduced_value", _num(bp * 0.2))
	var gi := -1
	var k := 0
	for g in map.trade_goods:
		if g == gid:
			gi = k
		k += 1
	var res := _n("resource_icon") as Eu4Gui.Button2
	if res:
		res.visible = gi >= 0
		if gi >= 0:
			res.set_frame(gi)
			res.tooltip_text = map.trade_goods[gid]["name"]
	_txt("resource_price_value", _num(price) if gi >= 0 else "")
	_tip("resource_price_value", "Preço de %s" % map.trade_goods[gid]["name"] if gi >= 0 else "")
	var nid: String = p.get("trade_node", "")
	_txt("tradenode_button", map.trade_nodes[nid]["name"] if map.trade_nodes.has(nid) else "")
	_tip("tradenode_button", "Nó de comércio" + (" · centro de comércio nível %d" % int(p["center_of_trade"]) \
			if int(p.get("center_of_trade", 0)) > 0 else ""))
	# construções (ícones na faixa dos modificadores) e instituições
	var box := _n("modifiers")
	if box:
		for ch in box.get_children():
			box.remove_child(ch)
			ch.queue_free()
		for bid in p.get("buildings", []):
			var tex := map.icon_texture("building:" + bid)
			if tex and map.buildings.has(bid):
				var eff := map.building_effects(bid)
				box.add_child(MapView.icon_rect(tex, 30, map.buildings[bid]["name"] + (" (%s)" % eff if eff != "" else "")))
	var inst := []
	if institutions and institutions.enabled():
		for i in institutions.list:
			var pr := institutions.province_progress(i["id"], id)
			if pr > 0.0:
				inst.append("%s %d%%" % [i["name"], roundi(pr)])
	_show("institution_icon", not inst.is_empty())
	_tip("institution_icon", "Instituições: " + ", ".join(inst))
	show()
