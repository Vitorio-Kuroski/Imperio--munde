class_name MapTooltip
extends PanelContainer
## Dica que segue o mouse sobre o mapa. Mostra a província e, conforme o modo de mapa,
## a cultura (modo cultura), a religião (modo religião), o produto (modo produtos), o nó de comércio (modo comércio), a área e a região (modo regiões), a instituição (modo instituições), a relação diplomática (modo diplomacia), o dono (modo político) ou o terreno (modo terreno).

const OFFSET := Vector2(16, 18)

var _swatch: ColorRect
var _flag: TextureRect             # bandeira do dono (modos político e diplomacia) ou ícone (religião, produtos, instituições)
var _title: Label
var _sub: Label
var _last_pid := -2
var _last_mode := -1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.10, 0.92)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 8
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", sb)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 7)
	add_child(hb)

	_swatch = ColorRect.new()
	_swatch.custom_minimum_size = Vector2(11, 11)
	_swatch.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var swatch_box := MarginContainer.new()     # alinha o quadradinho com a 1ª linha
	swatch_box.add_theme_constant_override("margin_top", 5)
	swatch_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	swatch_box.add_child(_swatch)
	hb.add_child(swatch_box)
	_flag = TextureRect.new()
	_flag.custom_minimum_size = Vector2(28, 28)
	_flag.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_flag.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(_flag)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 0)
	hb.add_child(vb)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	vb.add_child(_title)
	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", 13)
	_sub.add_theme_color_override("font_color", Color(0.78, 0.78, 0.74))
	vb.add_child(_sub)
	hide()


## Atualiza a dica para a província `pid` (-1 esconde) perto da posição `mouse` (tela).
func update_for(map: MapView, pid: int, mouse: Vector2) -> void:
	if pid < 0:
		hide()
		_last_pid = -2
		return
	if pid != _last_pid or map.map_mode != _last_mode:
		_fill(map, pid)
		_last_pid = pid
		_last_mode = map.map_mode
		reset_size()
	var vp := get_viewport_rect().size
	var pos := mouse + OFFSET
	# não deixa sair da tela: vira para o outro lado do cursor perto das bordas
	if pos.x + size.x > vp.x:
		pos.x = mouse.x - OFFSET.x - size.x
	if pos.y + size.y > vp.y:
		pos.y = mouse.y - OFFSET.y - size.y
	position = pos
	show()


func _fill(map: MapView, pid: int) -> void:
	var p: Dictionary = map.provinces[pid]
	if map.hidden(pid):                 # Terra Incógnita: nada da província aparece
		_title.text = Loc.t("TERRA_INCOGNITA", "Terra Incógnita")
		_sub.text = ""
		_flag.visible = false
		_swatch.get_parent().visible = true
		_swatch.color = Color(0.37, 0.35, 0.32)
		return
	_sub.text = p["name"]
	var flag: Texture2D = null
	if map.map_mode in [MapView.MapMode.POLITICO, MapView.MapMode.DIPLOMACIA] and not p["sea"]:
		flag = map.flag_texture(p["owner"])
	elif not p["sea"]:
		match map.map_mode:
			MapView.MapMode.RELIGIAO:
				flag = map.icon_texture("religion:" + str(p.get("religion", "")))
			MapView.MapMode.PRODUTOS:
				flag = map.icon_texture("good:" + str(p.get("trade_goods", "")))
			MapView.MapMode.INSTITUICOES:
				if map.inst_view and map.inst_view.focus() != "":
					flag = map.icon_texture("inst:" + map.inst_view.focus())
	_flag.texture = flag
	_flag.visible = flag != null
	_swatch.get_parent().visible = flag == null
	if p["sea"]:
		_title.text = Loc.s("Mar", "Sea")
		_swatch.color = MapView.SEA_COLOR
		return
	match map.map_mode:
		MapView.MapMode.CULTURA:
			var cid: String = p.get("culture", "")
			if map.cultures.has(cid):
				var c: Dictionary = map.cultures[cid]
				_title.text = c["name"]
				_sub.text = "%s · %s" % [p["name"], Loc.t(c["group"], c["group"])] if c["group"] != "" else p["name"]
			else:
				_title.text = Loc.s("Cultura desconhecida", "Unknown culture")
			_swatch.color = map.culture_color(cid)
		MapView.MapMode.RELIGIAO:
			var rid: String = p.get("religion", "")
			if map.religions.has(rid):
				var r: Dictionary = map.religions[rid]
				_title.text = r["name"]
				_sub.text = "%s · %s" % [p["name"], Loc.t(r["group"], r["group"])] if r["group"] != "" else p["name"]
			else:
				_title.text = Loc.s("Sem religião definida", "No religion")
			_swatch.color = map.religion_color(rid)
		MapView.MapMode.PRODUTOS:
			var gid: String = p.get("trade_goods", "")
			if map.trade_goods.has(gid):
				var g: Dictionary = map.trade_goods[gid]
				_title.text = g["name"]
				_sub.text = "%s · %s %s" % [p["name"], Loc.t("PW_PRICE", "preço").to_lower(),
						Loc.s(str(snappedf(float(g["price"]), 0.01)).trim_suffix(".0").replace(".", Loc.dec), str(snappedf(float(g["price"]), 0.01)).trim_suffix(".0"))]
			else:
				_title.text = Loc.s("Sem produto", "No trade goods")
			_swatch.color = map.trade_good_color(gid)
		MapView.MapMode.COMERCIO:
			var nid: String = p.get("trade_node", "")
			if map.trade_nodes.has(nid):
				var n: Dictionary = map.trade_nodes[nid]
				_title.text = Loc.t("TRADENODE", "Nó") + ": " + n["name"]
				var bits := [p["name"]]
				if int(n.get("location", 0)) == pid:
					bits.append(Loc.s("sede do nó", "node seat"))
				elif int(p.get("center_of_trade", 0)) > 0:
					bits.append(Loc.s("centro de comércio %d", "center of trade %d") % int(p["center_of_trade"]))
				var tv: Trade = map.trade_view
				if tv and tv.enabled() and not tv.total_value.is_empty():
					var i := tv.node_of(pid)
					if i >= 0:
						bits.append(Loc.s("valor %s", "value %s") % Loc.s(str(snappedf(tv.total_value[i], 0.1)).replace(".", Loc.dec), str(snappedf(tv.total_value[i], 0.1))))
						var me: String = map.diplo_focus
						if me != "" and tv.share(me, i) > 0.0:
							bits.append("%s %d%%" % [me, roundi(tv.share(me, i) * 100.0)])
				_sub.text = " · ".join(bits)
			else:
				_title.text = Loc.s("Fora das rotas de comércio", "Outside the trade routes")
			_swatch.color = map.trade_node_color(nid)
		MapView.MapMode.REGIOES:
			var aid: String = p.get("area", "")
			if map.areas.has(aid):
				_title.text = map.areas[aid]["name"]
				var rid: String = p.get("region", "")
				if map.regions.has(rid):
					_sub.text = "%s · %s" % [p["name"], map.regions[rid]["name"]]
			else:
				_title.text = Loc.s("Sem área", "No area")
			_swatch.color = map.area_color(aid)
		MapView.MapMode.INSTITUICOES:
			var iv: Institutions = map.inst_view
			var iid := iv.focus() if iv else ""
			if iid != "":
				_title.text = iv.name_of(iid)
				_sub.text = "%s · %d%%" % [p["name"], roundi(iv.province_progress(iid, pid))]
			else:
				_title.text = Loc.s("Sem instituições", "No institutions")
			_swatch.color = map.institution_color(pid)
		MapView.MapMode.DIPLOMACIA:
			var tag: String = p["owner"]
			_title.text = map.countries[tag]["name"] if map.countries.has(tag) else Loc.s("Sem dono", "Unowned")
			var rel := map.diplo_view.relation(map.diplo_focus, tag) if map.diplo_view else ""
			var bits := [p["name"]]
			if MapView.DIPLO_NAMES.has(rel):
				bits.append(Loc.s(MapView.DIPLO_NAMES[rel], MapView.DIPLO_NAMES_EN[rel]))
			if p.get("hre", false):
				bits.append(Loc.t("HINT_HRE_TITLE", "Sacro Império"))
			_sub.text = " · ".join(bits)
			_swatch.color = map.diplomacy_color(pid)
		MapView.MapMode.TERRENO:
			_title.text = map.terrain_name(p["terrain"])
			_swatch.color = MapView.TERRAIN_COLORS.get(p["terrain"], MapView.UNOWNED_COLOR)
		_:
			var tag: String = p["owner"]
			_title.text = map.countries[tag]["name"] if map.countries.has(tag) else Loc.s("Sem dono", "Unowned")
			if map.countries.has(tag):
				_sub.text = "%s · %s" % [p["name"], tag]
			_swatch.color = map.province_color(pid)
