class_name Eu4ProvinceView
extends Control
## Tela da província do EU4 (provinceview.gui), no lugar do painel de texto da esquerda, como o
## EU4 a mostra em telas de 768 px: abas província/estado (a do estado apagada), faixa com o nome,
## a cidade-capital (history/provinces `capital`), área e região e o terreno num ícone pequeno no
## meio da faixa; imposto/produção/efetivo com os botões de desenvolver (só na província do
## jogador) e o custo, desenvolvimento, renda, núcleos e reivindicações (escudos), agitação e
## autonomia (o jogo ainda não tem: "---" e 0%), religião (com o ícone), cultura, Sacro Império;
## província de outro país: escudo, nome, opinião dele sobre o jogador, governo, tecnologia
## militar e o botão Diplomacia (abre a aba Diplomacia do país); militar: efetivo, suprimento
## (`Army.supply_limit`), marinheiros, forte (nível, guarnição = 1000 × nível), objetivo;
## comércio: produto (ícone e preço), nó, poder e valor; construções e instituições.
## O resto fica escondido (só os elementos de KEEP aparecem).

signal closed
signal owner_requested(tag: String)
signal diplomacy_requested(tag: String)   # botão Diplomacia da província de outro país

## Elementos do .gui que aparecem (os outros e as janelas sem nenhum deles ficam escondidos).
const KEEP := ["provinceview_bg", "provinceview_foreign_bg", "trade_icon", "military_icon", "institution_icon",
		"province_banner", "provincename", "capitalname", "area_name", "region_name", "have_capital", "close_button",
		"province_tab_button", "states_tab_button", "tax_base_increase_button", "prod_base_increase_button",
		"mp_base_increase_button", "improve_icon", "improve_value", "claims_title", "cores_box", "unrest_title",
		"unrest_value", "local_autonomy_title", "local_autonomy_value", "inc_autonomy_button", "dec_autonomy_button",
		"sailor", "sailor_value", "building_fort", "no_building_fort", "province_view_fort_nr_bg", "fort_number",
		"maintenance_icon", "fort_maintenance_checkbox", "defensiveness_icon", "defensiveness_value",
		"garrison_value", "select_allied_objective", "shield", "country_name", "opinion_box", "government_type_icon",
		"miltech_icon", "miltech_value", "button_diploaction",
		"tax_base_icon", "tax_base_value", "prod_base_icon", "prod_base_value", "mp_base_icon", "mp_base_value",
		"development_icon", "development_value", "tax", "tax_value", "production", "production_value", "total",
		"total_value", "religion_title", "religion", "religion_icon", "culture_title", "culture", "hre_icon",
		"demographics_header", "military_header", "trade_header", "manpower", "manpower_value", "supply",
		"supply_value", "goodsproduced", "goodsproduced_value", "resource_icon", "resource_price_value",
		"resource_price_gold", "tradenode_button", "modifiers", "tradepower", "tradepower_value", "tradevalue",
		"tradevalue_value"]
## Subjanelas que o jogo ainda não usa (têm elementos com os mesmos nomes dos de KEEP).
const HIDE_WINDOWS := ["state_window", "buildings_window", "change_culture_view", "build_army_view", "build_navy_view",
		"client_state_selection", "transfer_occupation_window", "tradegoods_province_window",
		"allied_objectives_list"]
## Os valores de imposto/produção/efetivo ficam em y = 0 no .gui; o EU4 os desce para a linha dos
## ícones (positionType development_value_vertical_position_not_exploitable).
const DEV_VALUE_Y := 68.0

var manpower: Manpower             # main.gd define (efetivo das províncias)
var gui: Eu4Gui
var map: MapView
var institutions: Institutions
var terrain_tip: Callable          # rótulo do terreno -> texto extra (main.gd)
var army: Army                     # main.gd define (suprimento)
var siege: Siege                   # forte e guarnição
var construction: Construction     # desenvolver
var power: MonarchPower            # tecnologia militar, jogador
var diplo: DiploActions            # opinião
var pid := -1
var _win: Control
var _terrain_small: TextureRect    # terreno no meio da faixa (o EU4 em 768 px não mostra a imagem grande)
var _capitals := {}                # pid -> cidade-capital (history/provinces)
var _flags := {}                   # tag -> ImageTexture (o recorte do escudo não aceita AtlasTexture)
var _off := ""                     # dica dos controles que ainda não existem


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
		close.tooltip_text = Loc.t("CLOSE", "Fechar")
	if not Loc.active():        # com a localização do EU4, os rótulos já vêm do .gui (TAX, HEADER_TRADE...)
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
		_txt("tradepower", "Poder comercial:")
		_txt("tradevalue", "Valor comercial:")
	_tip("tax_base_icon", Loc.t("BASE_TAX", "Imposto base"))
	_tip("prod_base_icon", Loc.t("BASE_PRODUCTION", "Produção base"))
	_tip("mp_base_icon", Loc.t("BASE_MANPOWER", "Efetivo base"))
	_tip("development_icon", Loc.t("DEVELOPMENT", "Desenvolvimento"))
	_off = Loc.s("Ainda não existe neste jogo", "Not in this game yet")
	for n in ["states_tab_button", "inc_autonomy_button", "dec_autonomy_button", "fort_maintenance_checkbox",
			"select_allied_objective"]:
		var b := _n(n) as BaseButton
		if b:
			Eu4UnitPanel._set_enabled(b, false)
			b.tooltip_text = _off
	var cb := _n("fort_maintenance_checkbox") as BaseButton
	if cb:
		cb.button_pressed = true
	_txt("select_allied_objective", Loc.t("NO_OBJECTIVE", "Sem objetivo"))
	for kind in [["tax_base_increase_button", "tax"], ["prod_base_increase_button", "production"],
			["mp_base_increase_button", "manpower"]]:
		var b := _n(kind[0]) as BaseButton
		if b:
			b.pressed.connect(func():
				if construction and power and pid >= 0 and construction.develop(power.player, pid, kind[1]):
					show_province(pid))
	var dip := _n("button_diploaction") as BaseButton
	if dip:
		dip.pressed.connect(func():
			if pid >= 0 and map.provinces[pid]["owner"] != "":
				diplomacy_requested.emit(map.provinces[pid]["owner"]))
	var big := _n("province_terrain")
	if big:
		big.hide()                 # a imagem grande só aparece no layout alto do EU4
	var banner := _n("province_banner")
	if banner:
		_terrain_small = TextureRect.new()
		_terrain_small.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_terrain_small.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_terrain_small.size = Vector2(26, 26)
		_terrain_small.mouse_filter = Control.MOUSE_FILTER_STOP
		banner.get_parent().add_child(_terrain_small)
		var bw: float = banner.size.x
		_terrain_small.position = banner.position + Vector2(bw * 0.5 - 2, (banner.size.y - 26) * 0.5 + 1)
	if banner:
		banner.mouse_filter = Control.MOUSE_FILTER_STOP
		banner.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and pid >= 0:
				var o: String = map.provinces[pid]["owner"]
				if o != "":
					owner_requested.emit(o))
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
	return ("%.2f" % x).replace(".", Loc.dec)


## Cidade-capital da província (`capital` do history/provinces; sem ela, o nome da província).
func _capital_of(id: int) -> String:
	if _capitals.is_empty():
		var re := RegEx.create_from_string("^\\s*(\\d+)")
		for fname in Eu4Data.folder("history/provinces"):
			var m := re.search(str(fname))
			if m == null:
				continue
			var k := int(m.get_string(1))
			if _capitals.has(k):
				continue
			for kv in Eu4Data.folder("history/provinces")[fname]:
				if kv[0] == "capital":
					_capitals[k] = str(kv[1])
					break
		_capitals[-1] = ""
	return str(_capitals.get(id, map.provinces[id]["name"]))


func _flag(t: String) -> Texture2D:
	if not _flags.has(t):
		var ft := map.flag_texture(t)
		var img := ft.get_image() if ft else null
		_flags[t] = ImageTexture.create_from_image(img) if img else null
	return _flags[t]


## Província de outro país: escudo, nome, opinião dele sobre o jogador, governo, tecnologia militar.
func _fill_foreign(owner: String, player: String) -> void:
	var c: Dictionary = map.countries.get(owner, {})
	var sh := _n("shield") as Eu4Gui.Button2
	if sh:
		sh.set_flag(_flag(owner))
		sh.tooltip_text = str(c.get("name", owner))
		if not sh.pressed.is_connected(_on_shield):
			sh.pressed.connect(_on_shield)
	_txt("country_name", str(c.get("name", owner)))
	var l := _n("country_name") as Label
	if l:
		Eu4Gui.fit_label(l)
	if diplo and player != "":
		var op := diplo.opinion(owner, player)
		_txt("opinion_box", ("%+d" % op))
		var ob := _n("opinion_box") as Label
		if ob:
			ob.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if op > 0 else (Color(0.95, 0.3, 0.3) if op < 0 else Color.WHITE))
		_tip("opinion_box", Loc.s("Opinião de %s sobre nós", "%s's opinion of us") % c.get("name", owner))
	var gi := _n("government_type_icon") as Eu4Gui.Icon
	if gi:
		gi.set_frame(int(Eu4CountryView.GOV_FRAMES.get(str(c.get("government", "")), 0)))
		gi.tooltip_text = Loc.t(str(c.get("government", "")), str(c.get("government", "")))
	if power:
		_txt("miltech_value", str(power.tech(owner, "mil")))
		_tip("miltech_value", Loc.t("MILITARY_TECH", "Tecnologia militar"))


func _on_shield() -> void:
	if pid >= 0 and map.provinces[pid]["owner"] != "":
		owner_requested.emit(map.provinces[pid]["owner"])


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
	var area_nm: String = map.areas[aid]["name"] if map.areas.has(aid) else ""
	_txt("capitalname", _capital_of(id))
	_txt("area_name", area_nm)
	_txt("region_name", map.regions[rid]["name"] if map.regions.has(rid) else "")
	_txt("province_tab_button", p["name"])
	_txt("states_tab_button", area_nm)
	var owner: String = p["owner"]
	var player: String = power.player if power else ""
	var mine := owner != "" and owner == player
	var foreign := owner != "" and not mine
	_show("provinceview_bg", not foreign)
	_show("provinceview_foreign_bg", foreign)
	_show("foreign_province_window", foreign)
	if foreign:
		_fill_foreign(owner, player)
	_show("have_capital", owner != "" and int(map.countries.get(owner, {}).get("capital", -1)) == id)
	_tip("have_capital", Loc.s("Capital de ", "Capital of ") + str(map.countries.get(owner, {}).get("name", "")))
	_tip("province_banner", Loc.s("Dono: %s (clique para abrir o país)", "Owner: %s (click to open the country)") % \
			(map.countries[owner]["name"] if map.countries.has(owner) else Loc.s("ninguém", "nobody")))
	# terreno
	var eu4_t := ""
	for t in map.terrains.values():
		if t.get("id", "") == p["terrain"]:
			eu4_t = t.get("eu4", "")
	var ter := _n("province_terrain") as Eu4Gui.Icon
	if ter:
		var spr := "GFX_combat_terrain_" + eu4_t
		var has := gui.sprites.has(spr)
		if has:
			ter.set_sprite(gui, spr, 0)
		ter.hide()
		if _terrain_small:
			_terrain_small.visible = has
			_terrain_small.texture = gui.sprite_frame(spr, 0) if has else null
			_terrain_small.tooltip_text = "%s: %s%s" % [Loc.t("terrain", "Terreno"), map.terrain_name(p["terrain"]), terrain_tip.call(p["terrain"]) if terrain_tip.is_valid() else ""]
	# desenvolvimento
	var bt := int(p.get("base_tax", 0))
	var bp := int(p.get("base_production", 0))
	var bm := int(p.get("base_manpower", 0))
	_txt("tax_base_value", str(bt))
	_txt("prod_base_value", str(bp))
	_txt("mp_base_value", str(bm))
	_txt("development_value", str(int(p["development"])))
	# botões de desenvolver: no lugar dos ícones; só na província do jogador
	for kind in [["tax_base_increase_button", "tax_base_icon", "tax", "adm"], ["prod_base_increase_button", "prod_base_icon",
			"production", "dip"], ["mp_base_increase_button", "mp_base_icon", "manpower", "mil"]]:
		var b := _n(kind[0]) as BaseButton
		_show(kind[1], b == null)
		if b and construction:
			b.disabled = not (mine and construction.can_develop(owner, id, kind[2]))   # o EU4 não os acinzenta
			b.tooltip_text = (Loc.s("Desenvolver (%d pontos %s)", "Develop (%d %s points)") % [construction.dev_cost(owner, id),
					kind[3].to_upper()]) if mine else Loc.s("Só nas suas províncias", "Only in your own provinces")
	_show("improve_icon", construction != null and owner != "")
	_txt("improve_value", str(construction.dev_cost(owner, id)) if construction and owner != "" else "")
	_tip("improve_value", Loc.s("Custo de desenvolver", "Development cost"))
	# núcleos e reivindicações (escudos)
	var cores: Array = p.get("cores", [owner] if owner != "" else [])
	var claims: Array = p.get("claims", [])
	var box2 := _n("cores_box")
	if box2:
		for ch in box2.get_children():
			box2.remove_child(ch)
			ch.queue_free()
		for t in cores + claims:
			var item := gui.build("ClaimShieldItem" if t in claims and not (t in cores) else "CoreShieldItem")
			if item == null:
				continue
			var sh := item.find_child("CoreShieldButton", true, false) as Eu4Gui.Button2
			if sh:
				sh.set_flag(_flag(t))
				sh.tooltip_text = ("%s: %s" % [Loc.t("CLAIMS", "Reivindicação") if t in claims and not (t in cores) else Loc.t("CORE", "Núcleo"),
						map.countries.get(t, {}).get("name", t)])
			item.custom_minimum_size = Vector2(26, 30)
			box2.add_child(item)
	_txt("unrest_value", "---" if foreign else "0.00")
	_tip("unrest_value", _off)
	_txt("local_autonomy_value", ("%.1f%%" % 0.0).replace(".", Loc.dec))
	_tip("local_autonomy_value", _off)
	var gid: String = p.get("trade_goods", "")
	var price := float(map.trade_goods[gid]["price"]) if map.trade_goods.has(gid) else 0.0
	var tax := bt * (1.0 + map.building_mod(p, "local_tax_modifier")) / 12.0
	var prod := map.goods_produced(p) * price * (1.0 + map.building_mod(p, "local_production_efficiency")) / 12.0
	_txt("tax_value", _num(tax))
	_txt("production_value", _num(prod))
	_txt("total_value", _num(tax + prod))
	_tip("tax_value", Loc.s("Ducados por mês", "Ducats per month"))
	_tip("production_value", Loc.s("Ducados por mês (produção × 0,2 × preço do produto)",
			"Ducats per month (production × 0.2 × goods price)"))
	# religião e cultura
	var rel: String = p.get("religion", "")
	_txt("religion", map.religions[rel]["name"] if map.religions.has(rel) else "—")
	var ri := _n("religion_icon") as Eu4Gui.Icon
	if ri:
		ri.set_religion(map.religions.get(rel, {}))
	var cul: String = p.get("culture", "")
	_txt("culture", map.cultures[cul]["name"] if map.cultures.has(cul) else "—")
	_tip("culture", ("%s: %s" % [Loc.t("GROUP", "Grupo"), Loc.t(map.cultures[cul]["group"], map.cultures[cul]["group"])]) if map.cultures.has(cul) and map.cultures[cul]["group"] != "" else "")
	_show("hre_icon", p.get("hre", false))
	_tip("hre_icon", Loc.t("HINT_HRE_TITLE", "Sacro Império Romano"))
	# militar
	if manpower:          # o que a província dá ao efetivo máximo do país (núcleo +75%, quartéis...)
		_txt("manpower_value", str(roundi(manpower.province_manpower(p) * 1000.0)))
		_tip("manpower_value", Loc.s("Efetivo base %d × 250 × (1 + núcleo + construções)",
				"Base manpower %d × 250 × (1 + core + buildings)") % bm)
	else:
		_txt("manpower_value", str(bm * 250))
	var sup := 0.0
	for t in map.terrains.values():
		if t.get("id", "") == p["terrain"]:
			sup = float(t.get("supply_limit", 0.0))
	if army and owner != "":
		sup = army.supply_limit(id, owner)
	_txt("supply_value", str(roundi(sup)) if sup > 0 else "—")
	_show("sailor", not p.get("coastal", false))
	_show("sailor_value", not p.get("coastal", false))
	_txt("sailor_value", "0")
	# forte
	var lvl := siege.fort_level(id) if siege else 0
	_show("building_fort", lvl > 0)
	_show("no_building_fort", lvl == 0)
	_show("province_view_fort_nr_bg", lvl > 0)
	_show("fort_number", lvl > 0)
	_txt("fort_number", str(lvl))
	_txt("garrison_value", Loc.num(lvl * 1000.0) if lvl > 0 else "0")
	_tip("garrison_value", Loc.s("Guarnição", "Garrison"))
	_txt("defensiveness_value", ("%d%%" % 0))
	var bf := _n("building_fort") as Eu4Gui.Icon
	if bf and lvl > 0:
		for bid in p.get("buildings", []):
			if float(map.buildings.get(bid, {}).get("modifiers", {}).get("fort_level", 0)) > 0 and gui.sprites.has("GFX_" + bid):
				bf.set_sprite(gui, "GFX_" + bid, 0)
				bf.tooltip_text = map.buildings[bid]["name"]
	# comércio
	_txt("goodsproduced_value", _num(map.goods_produced(p)))
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
	_tip("resource_price_value", "%s: %s" % [Loc.t("PW_PRICE", "Preço"), map.trade_goods[gid]["name"]] if gi >= 0 else "")
	var tv: Trade = map.trade_view
	if tv and tv.enabled() and not tv.prov_power.is_empty():
		_txt("tradepower_value", _num(tv.prov_power[id]))
		_txt("tradevalue_value", _num(tv.prov_value[id]))
		_tip("tradepower_value", Loc.s("Desenvolvimento × 0,2 + centro de comércio, × (1 + costa, construções, mercantilismo)",
				"Development × 0.2 + center of trade, × (1 + coast, buildings, mercantilism)"))
		_tip("tradevalue_value", Loc.s("Bens produzidos × preço (por ano)", "Goods produced × price (per year)"))
	var nid: String = p.get("trade_node", "")
	_txt("tradenode_button", map.trade_nodes[nid]["name"] if map.trade_nodes.has(nid) else "")
	_tip("tradenode_button", Loc.t("TRADENODE", "Nó de comércio") + (Loc.s(" · centro de comércio nível %d", " · center of trade level %d") % int(p["center_of_trade"]) \
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
	_tip("institution_icon", Loc.t("INSTITUTIONS", "Instituições") + ": " + ", ".join(inst))
	show()
