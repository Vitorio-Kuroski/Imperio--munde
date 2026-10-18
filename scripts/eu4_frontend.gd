class_name Eu4Frontend
extends Control
## Tela de escolha de país do EU4 (janela `lobby` do frontend.gui), sobre o mapa:
##  - Esquerda: início histórico (start_type_options: Início histórico; Jogos salvos ainda não
##    existem), marcadores (bookmarks_list de bookmark_entry, de common/bookmarks em ordem de data,
##    o `default = yes` primeiro entre os da mesma data) e a data (datewidget). Só os marcadores de
##    11/11/1444 podem ser jogados (o mapa é importado nessa data); os outros ficam apagados.
##  - Topo: "O mundo em 1444" (year_label), "Clique no mapa para escolher um país" e os modos de
##    mapa do lobby que o jogo tem.
##  - Direita (singleplayer): escudo, posto, religião, grupo tecnológico, nome, governo, situação
##    (independente ou súdito), governante e adm/dip/mil, tecnologias, as 7 ideias nacionais,
##    províncias, desenvolvimento, fortes e as relações com escudos; Jogar, País aleatório, Voltar.
##  - Embaixo: descrição do marcador (scenario_description) e os escudos dos países do marcador
##    (`shield` em shield_position + i × shield_offset, centrados embaixo).
##  - Clicar no mapa (main.gd chama `select`) ou num escudo escolhe o país; o escudo e o marcador
##    movem a câmera (sinal `focus`).

signal play(tag: String)
signal back
signal focus(pid: int, zoom: bool)       # zoom = marcador (altura do frontend), senão só move

## Elementos do lobby que o jogo não usa (multijogador, criador de países, salvamentos, DLCs...).
const HIDE := ["lobby_chat_edit", "largefonts_lobby_chat_edit", "speech_enabled_lobby_chat_edit",
		"speech_enabled_largefonts_lobby_chat_edit", "speech_enabled_lobby_chat_button", "mic_button",
		"lobby_chat_button", "chatlog", "nation_designer_bottom_panel", "random_new_world_loading_window",
		"enabled_dlc_list_1", "enabled_dlc_list_0", "save_games", "lessons", "observe_mode_title",
		"observe_mode_button", "gameoptions_button", "find_button", "option_button", "multiplayer", "no_player",
		"country_tab", "players_tab", "country_tab_title", "players_tab_title", "ironman_icon", "ironman_label",
		"random_new_world_button", "enable_custom_nation_button", "nation_designer_button", "suggested_dlc_list",
		"secondary_religion_icon", "nation_designer_hint_bg", "nation_designer_hint", "ideas_value",
		"year_up1", "year_down1", "year_up2", "year_down2", "year_up3", "year_down3", "month_down", "day_down",
		"month_up", "day_up", "mapmode_empire", "mapmode_economy", "mapmode_players", "mapmode_expansion",
		"mapmode_content", "mapmode_unit", "mapmode_music"]
const MAPMODES := {"mapmode_terrain": MapView.MapMode.TERRENO, "mapmode_political": MapView.MapMode.POLITICO,
		"mapmode_trade": MapView.MapMode.COMERCIO, "mapmode_religion": MapView.MapMode.RELIGIAO,
		"mapmode_diplomacy": MapView.MapMode.DIPLOMACIA, "mapmode_region": MapView.MapMode.REGIOES,
		"mapmode_culture": MapView.MapMode.CULTURA}
const START_DATE := [1444, 11, 11]

var gui: Eu4Gui
var map: MapView
var power: MonarchPower
var diplomacy: Diplomacy
var siege: Siege                  # fortes (opcional)
var gov_name: Callable            # país -> nome do governo (Eu4CountryView._gov_name)
var bookmarks := []               # [{name, desc, date [a, m, d], center, countries, default}]
var bookmark := {}
var selected := ""
var _root: Control
var _sp: Control                  # painel do país (singleplayer)
var _shields: Control
var _shield_list := []            # [[tag, botão, brilho]]
var _flags := {}


## Bandeira como textura comum (o recorte do escudo não funciona com AtlasTexture).
func _flag(t: String) -> Texture2D:
	if not _flags.has(t):
		var ft := map.flag_texture(t)
		var img := ft.get_image() if ft else null
		_flags[t] = ImageTexture.create_from_image(img) if img else null
	return _flags[t]


func setup(g: Eu4Gui, m: MapView, pw: MonarchPower, d: Diplomacy) -> bool:
	gui = g
	map = m
	power = pw
	diplomacy = d
	if gui.find_window("lobby").is_empty():
		return false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root = gui.build("lobby")
	if _root == null:
		return false
	add_child(_root)
	_sp = _root.find_child("singleplayer", true, false) as Control
	for n in ["left", "right", "top", "bottom"]:
		_show_position(n)
	for n in HIDE:
		var c := _find(n)
		if c:
			c.hide()
	_shields = Control.new()
	_shields.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shields.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_root.add_child(_shields)
	_start_types()
	_load_bookmarks()
	_fill_bookmarks()
	_button("play_button", func():
		if selected != "":
			play.emit(selected), "")
	_button("random_country_button", _random_country, "")
	_button("back_button", func(): back.emit(), "")
	for n in MAPMODES:
		var b := _find(n) as BaseButton
		if b == null:
			continue
		var mode: MapView.MapMode = MAPMODES[n]
		if not map.has_map_mode(mode):
			b.hide()
			continue
		b.tooltip_text = Loc.s("Modo de mapa: ", "Map mode: ") + MapView.map_mode_name(mode)
		b.pressed.connect(func(): map.set_map_mode(mode))
	_txt("select_label", Loc.t("FE_SELECT_NATION", "Clique no mapa para escolher um país..."))
	_txt("startdatelabel", Loc.t("FE_STARTING_DATE", "Data de início"))
	var def := 0
	for i in bookmarks.size():
		if bookmarks[i]["default"] and _playable(bookmarks[i]):
			def = i
			break
	if not bookmarks.is_empty():
		select_bookmark(def)
	else:
		_txt("year_label", Loc.s("O mundo em 1444", "The world 1444 AD"))
		_show_date(START_DATE)
	return true


## Elemento pelo nome: primeiro no painel do país (singleplayer; a janela do multijogador, escondida,
## tem os mesmos nomes), depois no lobby inteiro.
func _find(n: String) -> Control:
	var c: Control = _sp.find_child(n, true, false) as Control if _sp else null
	return c if c else _root.find_child(n, true, false) as Control


func _txt(n: String, t: String, tip := "", root: Control = null) -> void:
	var l := (root.find_child(n, true, false) if root else _find(n)) as Label
	if l:
		l.text = t
		Eu4Gui.fit_label(l)
		if tip != "":
			l.tooltip_text = tip
			l.mouse_filter = Control.MOUSE_FILTER_PASS


func _button(n: String, f: Callable, tip: String) -> void:
	var b := _find(n) as BaseButton
	if b:
		b.pressed.connect(f)
		if tip != "":
			b.tooltip_text = tip


## Coloca a janela na show_position do EU4 (as janelas do lobby entram deslizando até ela).
func _show_position(n: String) -> void:
	var c := _find(n)
	var w := gui.find_window(n)
	if c == null or w.is_empty():
		return
	w = gui._resolve(w)
	var sp := Eu4Gui._vec(w, "show_position")
	if Eu4Gui._yes(w, "fullscreen"):
		c.offset_left = sp.x
		c.offset_top = sp.y
		c.offset_right = sp.x
		c.offset_bottom = sp.y
	else:
		gui._place(c, w + [["position", [["x", str(sp.x)], ["y", str(sp.y)]]]], Eu4Gui._vec(w, "size"))


## Abas Início histórico / Jogos salvos (start_type_option).
func _start_types() -> void:
	var box := _find("start_type_options")
	if box == null:
		return
	for i in 2:
		var w := gui.build("start_type_option")
		if w == null:
			return
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(80, 50)
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(w)
		box.add_child(holder)
		var b := w.find_child("button", true, false) as Eu4Gui.Button2
		var ic := w.find_child("icon", true, false) as Eu4Gui.Icon
		if ic:
			ic.set_frame(i)
		if b:
			b.tooltip_text = Loc.t("FE_HISTORICAL_START", "Início histórico") if i == 0 else \
					Loc.t("FE_SAVED_GAMES", "Jogos salvos") + "\n" + Loc.s("(ainda não existem)", "(not yet available)")
			b.disabled = i == 1
			b.set_frame(1 if i == 0 else 3)


# ------------------------------------------------------------------ marcadores
func _load_bookmarks() -> void:
	var files := Eu4Data.folder("common/bookmarks")
	var names := files.keys()
	names.sort()
	var order := 0
	for fn in names:
		for kv in files[fn]:
			if kv[0] != "bookmark" or not (kv[1] is Array):
				continue
			var b := {"name": "", "desc": "", "date": START_DATE, "center": -1, "countries": [], "default": false,
					"order": order}
			order += 1
			for x in kv[1]:
				match str(x[0]):
					"name":
						b["name"] = str(x[1])
					"desc":
						b["desc"] = str(x[1])
					"date":
						var p := str(x[1]).split(".")
						if p.size() == 3:
							b["date"] = [int(p[0]), int(p[1]), int(p[2])]
					"center":
						b["center"] = int(str(x[1]))
					"default":
						b["default"] = str(x[1]) == "yes"
					"country":
						if map.countries.has(str(x[1])):
							b["countries"].append(str(x[1]))
			bookmarks.append(b)
	bookmarks.sort_custom(func(a, b):
		var da: int = a["date"][0] * 10000 + a["date"][1] * 100 + a["date"][2]
		var db: int = b["date"][0] * 10000 + b["date"][1] * 100 + b["date"][2]
		if da != db:
			return da < db
		if a["default"] != b["default"]:
			return a["default"]
		return a["order"] < b["order"])


func _playable(b: Dictionary) -> bool:
	return b["date"] == START_DATE


func _fill_bookmarks() -> void:
	var list := _find("bookmarks_list")
	if list == null:
		return
	var rows := gui.fill_list(list, "bookmark_entry", bookmarks.size())
	for i in rows.size():
		var b: Dictionary = bookmarks[i]
		var row: Control = rows[i]
		_txt("title", Loc.t(b["name"], Eu4Importer.pretty_key(b["name"])), "", row)
		_txt("date", Loc.date(b["date"][0], b["date"][1], b["date"][2]), "", row)
		var btn := row.find_child("bookmark", true, false) as Eu4Gui.Button2
		if btn == null:
			continue
		var idx := i
		btn.pressed.connect(func(): select_bookmark(idx))
		if not _playable(b):
			btn.disabled = true
			row.modulate = Color(0.6, 0.6, 0.6)
			btn.tooltip_text = Loc.s("Ainda não: o mapa é importado em 11 de novembro de 1444",
					"Not yet: the map is imported on 11 November 1444")


func select_bookmark(i: int) -> void:
	if i < 0 or i >= bookmarks.size() or not _playable(bookmarks[i]):
		return
	bookmark = bookmarks[i]
	var list := _find("bookmarks_list")
	if list:
		var items := list.get_node_or_null("Items")
		for j in (items.get_child_count() if items else 0):
			var btn := items.get_child(j).find_child("bookmark", true, false) as Eu4Gui.Button2
			if btn and not btn.disabled:
				btn.set_frame(1 if j == i else 0)
	var y: int = bookmark["date"][0]
	_txt("year_label", Loc.t("FE_THE_WORLD_1453", "O mundo em 1453").replace("1453", str(y)))
	_show_date(bookmark["date"])
	_txt("scenario_description", Loc.t(bookmark["desc"], ""))
	_make_shields(bookmark["countries"])
	if int(bookmark["center"]) >= 0 and int(bookmark["center"]) < map.provinces.size():
		focus.emit(int(bookmark["center"]), true)
	if not bookmark["countries"].is_empty() and (selected == "" or not (selected in bookmark["countries"])):
		select(bookmark["countries"][0], false)


func _show_date(d: Array) -> void:
	_txt("year", str(d[0]))
	_txt("daymonth", Loc.date(d[0], d[1], d[2]).replace(str(d[0]), "").strip_edges())


func _make_shields(tags: Array) -> void:
	var nl := _find("selected_nation_label")
	if nl:
		nl.z_index = 1                      # por cima da faixa (diplomacy_banner), como no EU4
	for ch in _shields.get_children():
		ch.queue_free()
	_shield_list.clear()
	var pos := _pos_type("shield_position", Vector2(-13, -270))
	var step := _pos_type("shield_offset", Vector2(70, 0))
	var n := tags.size()
	for i in n:
		var t: String = tags[i]
		var b := gui.build_element("shield", "frontend") as Eu4Gui.Button2
		if b == null:
			return
		var glow := gui.build_element("shield_thin_glow", "frontend")
		var at := pos + step * (i - (n - 1) * 0.5) - Vector2(b.custom_minimum_size.x * 0.5 - 13, 0)
		if glow:
			glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			glow.position = at + Vector2(8, -5) - (glow.custom_minimum_size - b.custom_minimum_size) * 0.5
			_shields.add_child(glow)
		b.position = at
		b.set_flag(_flag(t))
		b.tooltip_text = str(map.countries[t]["name"])
		b.pressed.connect(func(): select(t))
		_shields.add_child(b)
		_shield_list.append([t, b, glow])
	_glow()


func _pos_type(n: String, def: Vector2) -> Vector2:
	var e := gui._find_any(gui.files.get("frontend", []), n)
	return Eu4Gui._vec(e[1], "position") if not e.is_empty() else def


func _glow() -> void:
	for s in _shield_list:
		if s[2]:
			(s[2] as Control).visible = s[0] == selected


# ------------------------------------------------------------------ país escolhido
func _random_country() -> void:
	var tags := []
	for t in map.countries:
		if not map.provinces_of(t).is_empty():
			tags.append(t)
	if not tags.is_empty():
		select(tags[randi() % tags.size()])


## Escolhe o país (do mapa, dos escudos ou aleatório); `move` = câmera vai para a capital.
func select(tag: String, move := true) -> void:
	if not map.countries.has(tag) or map.provinces_of(tag).is_empty():
		return
	selected = tag
	_glow()
	var c: Dictionary = map.countries[tag]
	if move:
		focus.emit(int(c.get("capital", -1)), false)
	map.select(int(c.get("capital", -1)))
	if map.diplo_focus != tag:
		map.diplo_focus = tag
		if map.map_mode == MapView.MapMode.DIPLOMACIA:
			map.refresh_colors()
	var sh := _find("player_shield") as Eu4Gui.Button2
	if sh:
		sh.set_flag(_flag(tag))
		sh.tooltip_text = str(c["name"])
	var rank := _find("government_rank") as Eu4Gui.Icon
	if rank:
		rank.set_frame(clampi(int(c.get("rank", 1)) - 1, 0, 2))
		rank.tooltip_text = Loc.t("RANK_%d" % int(c.get("rank", 1)), "")
	var ri := _find("religion_icon") as Eu4Gui.Icon
	if ri:
		var rel: Dictionary = map.religions.get(c.get("religion", ""), {})
		ri.set_religion(rel)
		ri.tooltip_text = str(rel.get("name", ""))
	var tg := _find("techgroup_icon") as Eu4Gui.Icon
	if tg:
		var gi: int = map.tech_groups.keys().find(c.get("tech_group", ""))     # quadro = ordem do technology.txt
		tg.visible = gi >= 0
		if gi >= 0:
			tg.set_frame(gi)
			tg.tooltip_text = Loc.t(str(c.get("tech_group", "")), str(c.get("tech_group", "")))
	_txt("selected_nation_label", str(c["name"]))
	_txt("selected_fog", _title(c))
	var ov := diplomacy.overlord(tag) if diplomacy else []
	_txt("selected_nation_status_label", Loc.t("INDEPENDANT", "Nação independente") if ov.is_empty() else \
			"%s (%s)" % [diplomacy.subject_name(ov[1]), map.countries.get(ov[0], {}).get("name", ov[0])])
	var m: Dictionary = c.get("monarch", {})
	var ruler := (str(m.get("name", "")) + " " + str(m.get("dynasty", ""))).strip_edges()
	_txt("selected_ruler", ruler if ruler != "" else Loc.s("(Interregno)", "(Interregnum)"))
	for cat in ["adm", "dip", "mil"]:
		_txt("ruler_%s_value" % cat, str(m.get(cat, 0)))
		_txt("%stech_value" % cat, str(power.tech(tag, cat)) if power and power.state.has(tag) else "",
				Loc.s("Nível de tecnologia", "Technology level"))
	_fill_ideas(c)
	var dev := 0
	var forts := 0
	var provs := map.provinces_of(tag)
	for p in provs:
		dev += int(p["development"])
		if siege and siege.fort_level(int(p["id"])) > 0:
			forts += 1
	_txt("provinces_value", str(provs.size()), Loc.s("Províncias", "Provinces"))
	_txt("economy_value", str(dev), Loc.s("Desenvolvimento total", "Total development"))
	_txt("fort_value", str(forts), Loc.s("Fortes", "Forts"))
	_fill_diplomacy(tag)


## Título do país como no EU4: Ducado/Reino/Império pelo posto nas monarquias (e tribos), senão o
## nome do governo.
func _title(c: Dictionary) -> String:
	var gov := str(c.get("government", ""))
	if gov in ["monarchy", "tribal"] and c.get("rank") != null:      # sem posto no histórico: o governo
		var r := clampi(int(c.get("rank", 1)), 1, 3)
		return Loc.t(["DUCHY", "KINGDOM", "EMPIRE"][r - 1], ["Ducado", "Reino", "Império"][r - 1])
	return str(gov_name.call(c)).get_slice(" · ", 0) if gov_name.is_valid() else gov


func _fill_ideas(c: Dictionary) -> void:
	var set := {}
	for s in map.national_ideas:
		if s.get("id", "") == c.get("ideas", ""):
			set = s
			break
	_txt("national_ideagroup_name", (str(set.get("name", "")) + ":") if not set.is_empty() else "")
	var ideas: Array = set.get("ideas", [])
	for i in 7:
		var ic := _find("national_idea%d" % (i + 1)) as TextureRect
		if ic == null:
			continue
		ic.visible = i < ideas.size()
		if i < ideas.size():
			var tex := map.idea_icon(ideas[i])
			if tex:
				ic.texture = tex
				ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			ic.tooltip_text = str(ideas[i].get("name", ""))


## Relações: aliados, casamentos, súditos, suserano e garantias, com o ícone da relação e escudos.
func _fill_diplomacy(tag: String) -> void:
	var list := _find("diplomatic_listbox")
	var vb := list.get_node_or_null("Items") if list else null
	if vb == null or diplomacy == null:
		return
	for ch in vb.get_children():
		ch.queue_free()
	var subs := []
	for s in diplomacy.subjects(tag):
		subs.append(s[0])
	var ov := diplomacy.overlord(tag)
	var rows := [["GFX_diplomacy_alliances", Loc.t("LEDGER_ALLIES", "Aliados"), diplomacy.allies(tag)],
			["GFX_diplomacy_royalmarriage", Loc.t("royal_marriage", "Casamentos reais"), diplomacy.marriages(tag)],
			["GFX_diplomacy_leadvassal", Loc.t("HEADER_SUBJECTS", "Súditos"), subs],
			["GFX_diplomacy_amvassal", Loc.t("HEADER_OVERLORD", "Suserano"), [ov[0]] if ov.size() > 0 else []],
			["GFX_diplomacy_guaranting", Loc.t("GUARANTEEING", "Garantindo"), diplomacy.guarantees(tag)]]
	for r in rows:
		if (r[2] as Array).is_empty():
			continue
		var line := HFlowContainer.new()
		line.add_theme_constant_override("h_separation", 2)
		line.custom_minimum_size.x = 190
		if gui.sprites.has(r[0]):
			var ic := Eu4Gui.Icon.new()
			ic.set_sprite(gui, r[0], 0)
			ic.tooltip_text = r[1]
			line.add_child(ic)
		for t in r[2]:
			if not map.countries.has(t):
				continue
			var holder := gui.build("countrydiplomacyview_shielditem")
			if holder == null:
				break
			holder.custom_minimum_size = Vector2(28, 32)
			line.add_child(holder)
			var s := holder.find_child("shield", true, false) as Eu4Gui.Button2
			if s:
				s.set_flag(_flag(t))
				s.tooltip_text = "%s: %s" % [r[1], map.countries[t]["name"]]
				var tt: String = t
				s.pressed.connect(func(): select(tt))
		vb.add_child(line)
