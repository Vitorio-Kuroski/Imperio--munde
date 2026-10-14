class_name Eu4MacroBuilder
extends Control
## Tela "construir" do EU4 (macrobuildinterface.gui, aberta pelo botão do martelo e da espada sob
## o escudo da barra superior). Abas laterais como no EU4; funcionam as que o jogo já tem:
##  - Construções: grade com as construções do EU4 (new_buildings_entry: ícone e custo; apagada
##    se a tecnologia ainda não liberou). Clicar numa abre a lista das províncias do país com
##    vagas, produto, custo e o que está em obra (building_province_list_entry); clicar na linha
##    constrói (ou cancela a obra em andamento, devolvendo o dinheiro).
##  - Desenvolvimento: as províncias do país com custo, desenvolvimento e os botões de imposto,
##    produção e efetivo (development_entry).
##  - Missionários: as províncias de outra religião com tempo, barra e Enviar/Chamar.
## As outras abas (exército, marinha, núcleos, autonomia, cultura, estados, diplomacia,
## exploração) ficam apagadas até o jogo ter essas mecânicas.

signal closed

const TABS := ["land_units_button", "navy_units_button", "core_button", "missionary_button", "autonomy_button",
		"culture_button", "buildings_button", "development_button", "states_button", "diplomacy_button",
		"exploit_button"]
const WORKING := {"missionary_button": "missionary", "buildings_button": "buildings",
		"development_button": "development"}
const TAB_KEYS := {"land_units_button": "MACRO_LAND_UNITS_TAB", "navy_units_button": "MACRO_NAVY_UNITS_TAB",
		"core_button": "CV_BUILD_CORE", "missionary_button": "HINT_MISSIONARY_TITLE",
		"autonomy_button": "LOCAL_AUTONOMY", "culture_button": "LEDGER_CULTURE",
		"buildings_button": "MACRO_PROVINCE_IMPROVEMENTS", "development_button": "DEVELOP_PROVINCE",
		"states_button": "HEADER_STATES", "diplomacy_button": "HEADER_DIPLOMACY", "exploit_button": "EXPLOIT"}
const TAB_PT := {"land_units_button": "Recrutar regimentos", "navy_units_button": "Construir navios",
		"core_button": "Criar núcleo", "missionary_button": "Missionários", "autonomy_button": "Autonomia",
		"culture_button": "Cultura", "buildings_button": "Construções", "development_button": "Desenvolver província",
		"states_button": "Estados", "diplomacy_button": "Diplomacia", "exploit_button": "Exploração"}
const HEADERS := {"missionary": "missionary_header", "buildings_list": "building_province_list_header",
		"development": "development_header"}
const GOOD := Color(0.55, 0.9, 0.45)
const DIM := Color(0.45, 0.45, 0.45)

var gui: Eu4Gui
var map: MapView
var power: MonarchPower
var economy: Economy
var religion: Religion
var construction: Construction
var player := ""
var tab := "buildings"
var building := ""                  # construção escolhida na grade ("" = mostrar a grade)
var _root: Control
var _list: Control


func setup(g: Eu4Gui, m: MapView, pw: MonarchPower, eco: Economy, rel: Religion, con: Construction) -> bool:
	gui = g
	map = m
	power = pw
	economy = eco
	religion = rel
	construction = con
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var w := gui.find_window("macro_build_interface")
	if w.is_empty() or gui.find_window("new_buildings_entry").is_empty():
		return false
	_root = gui.build("macro_build_interface")
	if _root == null:
		return false
	var sp := Eu4Gui._vec(w, "show_position")
	var sz := Eu4Gui._vec(w, "size")
	_root.offset_left = sp.x
	_root.offset_top = sp.y
	_root.offset_right = sp.x + sz.x
	_root.offset_bottom = sp.y + sz.y
	add_child(_root)
	for ch in _root.get_children():       # cabeçalhos e janelas de cada aba: só o da aba atual aparece
		if ch.get_class() == "Control":
			(ch as Control).hide()
	_list = _root.find_child("content_list", true, false) as Control
	for n in TABS:
		var b := _root.find_child(n, false, false) as Eu4Gui.Button2
		if b == null:
			continue
		b.tooltip_text = Loc.t(TAB_KEYS[n], TAB_PT[n])
		if WORKING.has(n):
			var t: String = WORKING[n]
			b.pressed.connect(func(): _set_tab(t))
		else:
			b.disabled = true
			b.modulate = DIM
			b.tooltip_text += Loc.s(" (ainda não existe no jogo)", " (not in the game yet)")
	var close := _root.find_child("close_button", false, false) as BaseButton
	if close:
		close.tooltip_text = Loc.t("CLOSE", "Fechar")
		close.pressed.connect(func():
			hide()
			closed.emit())
	var back := _header("buildings_list").find_child("close_button", true, false) as BaseButton \
			if _header("buildings_list") else null
	if back:
		back.tooltip_text = Loc.t("MACRO_BUILDING_LIST_WINDOW_CLOSE", "Voltar às construções")
		back.pressed.connect(func():
			building = ""
			refresh())
	for h in HEADERS.values():           # o jogo ainda não tem súditos nem territórios
		var hw := _root.find_child(h, false, false)
		if hw:
			for n in ["show_subjects", "show_subjects_title", "show_territories", "show_territories_title"]:
				Eu4CountryView._hide(hw, n)
	for n in ["force_limit", "units_in_production"]:
		var l := _root.find_child(n, false, false) as Label
		if l:
			l.text = ""
	if construction:
		construction.changed.connect(func(_t): refresh())
	if religion:
		religion.changed.connect(func(_t): refresh())
	power.changed.connect(func(_t): refresh())
	hide()
	return true


func _header(key: String) -> Control:
	return _root.find_child(HEADERS[key], false, false) as Control


func open(t := "") -> void:
	if t != "":
		tab = t
	show()
	refresh()


func _set_tab(t: String) -> void:
	tab = t
	building = ""
	refresh()


func _txt(root: Control, n: String, text: String, tip := "") -> void:
	var l := root.find_child(n, true, false) as Label
	if l:
		l.text = text
		if tip != "":
			l.tooltip_text = tip
			l.mouse_filter = Control.MOUSE_FILTER_PASS


func refresh() -> void:
	if not visible or player == "" or _root == null:
		return
	for n in TABS:
		var b := _root.find_child(n, false, false) as Eu4Gui.Button2
		if b and not b.disabled:
			b.set_frame(1 if WORKING.get(n, "") == tab else 0)
	var key := tab if tab != "buildings" else ("buildings_list" if building != "" else "")
	for k in HEADERS:
		var h := _header(k)
		if h:
			h.visible = k == key
	var status := _root.find_child("units_in_production", false, false) as Label
	if status:
		status.text = ""
	match tab:
		"buildings":
			if building == "":
				_fill_grid()
			else:
				_fill_building_list()
		"development":
			_fill_development()
		"missionary":
			_fill_missionaries()


func _title(text: String) -> void:
	_txt(_root, "macro_title", text)


func _mine() -> Array:
	var out := []
	for p in map.provinces:
		if p["owner"] == player and not p["sea"]:
			out.append(p)
	return out


static func _n(x: float) -> String:
	return (("%.2f" % x) if x != floorf(x) else str(int(x))).replace(".", Loc.dec)


# ------------------------------------------------------------------ construções
## Grade do EU4: botões build_<id> e textos <id>_cost; o genérico "manufactory" escolhe a
## manufatura do produto de cada província.
func _fill_grid() -> void:
	_title(Loc.t("MACRO_PROVINCE_IMPROVEMENTS", "Construções"))
	var grid := gui.fill_list(_list, "new_buildings_entry", 1)
	if grid.is_empty():
		return
	var g: Control = grid[0]
	Eu4CountryView._hide(g, "current_building")
	var ids := construction.buildable_ids(player)
	for b in g.find_children("build_*", "", true, false):
		var bid := String(b.name).trim_prefix("build_")
		var btn := b as BaseButton
		var cost_l := g.find_child(bid + "_cost", true, false) as Label
		var generic := bid == "manufactory"
		if not generic and not (bid in ids):
			btn.hide()
			if cost_l:
				cost_l.hide()
			continue
		var tex := map.icon_texture("building:" + bid) if not generic else _manufactory_icon()
		if tex and btn is TextureButton:
			var tb := btn as TextureButton
			tb.texture_normal = tex
			tb.texture_hover = null
			tb.texture_pressed = null
			tb.texture_disabled = null
			tb.texture_click_mask = null
			tb.ignore_texture_size = true
			tb.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.toggle_mode = false
		var unlocked := generic or construction.is_unlocked(player, bid)
		var n_ok := _count_buildable(bid)
		btn.modulate = Color.WHITE if unlocked and n_ok > 0 else (Color(0.75, 0.75, 0.75) if unlocked else DIM)
		var bname: String = Loc.t("MACRO_BUILDING_GENERIC_MANUFACTORY_TITLE", "Manufatura") if generic \
				else str(map.buildings[bid]["name"])
		var tip := bname
		if not generic:
			var eff := map.building_effects(bid)
			if eff != "":
				tip += "\n" + eff
			tip += "\n" + Loc.s("%s ducados, %d meses", "%s ducats, %d months") % [_n(construction.cost(player, bid)),
					construction.months(player, bid)]
			if not unlocked:
				var u: Array = construction.unlock[bid]
				tip += "\n" + Loc.s("Liberada na tecnologia %s %d", "Unlocked at %s technology %d") % [u[0], u[1]]
		tip += "\n" + Loc.s("Pode ser construída em %d província(s)", "Can be built in %d province(s)") % n_ok
		btn.tooltip_text = tip
		if cost_l:
			cost_l.text = _n(construction.cost(player, bid)) if not generic else "500"
			cost_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		for cn in btn.pressed.get_connections():
			btn.pressed.disconnect(cn["callable"])
		btn.pressed.connect(func():
			building = bid
			refresh())
	var q := 0
	for pid in construction.queue:
		if construction.queue[pid]["tag"] == player:
			q += 1
	var status := _root.find_child("units_in_production", false, false) as Label
	if status:
		status.text = Loc.s("Obras em andamento: %d", "Under construction: %d") % q


func _manufactory_icon() -> Texture2D:
	for bid in ["textile", "weapons", "wharf", "farm_estate", "mills", "plantations", "tradecompany"]:
		var t := map.icon_texture("building:" + bid)
		if t:
			return t
	return null


## Manufatura que serve para a província (a do produto dela), ou "".
func _manufactory_for(p: Dictionary) -> String:
	for bid in map.buildings:
		var goods: Array = map.buildings[bid].get("goods", [])
		if p.get("trade_goods", "") in goods:
			return bid
	return ""


func _bid_for(p: Dictionary) -> String:
	return _manufactory_for(p) if building == "manufactory" else building


func _count_buildable(bid: String) -> int:
	var n := 0
	for p in _mine():
		var b := _manufactory_for(p) if bid == "manufactory" else bid
		if b != "" and construction.can_build(player, int(p["id"]), b):
			n += 1
	return n


func _fill_building_list() -> void:
	var generic := building == "manufactory"
	_title(Loc.t("MACRO_BUILD_MANUFACTORY_TITLE", "Construir manufaturas") if generic \
			else Loc.f("MACRO_BUILDING_LIST_WINDOW_TITLE", {"BUILDINGNAME": map.buildings[building]["name"]},
			"Construir %s nas províncias" % map.buildings[building]["name"]))
	# primeiro onde dá para construir, depois as obras em andamento, depois o resto; por desenvolvimento
	var provs := _mine()
	var rank := func(p: Dictionary) -> int:
		var pid := int(p["id"])
		var b: String = _bid_for(p)
		if b != "" and construction.can_build(player, pid, b):
			return 0
		return 1 if construction.queue.has(pid) else 2
	provs.sort_custom(func(a, b):
		var ra: int = rank.call(a)
		var rb: int = rank.call(b)
		return ra < rb if ra != rb else int(a["development"]) > int(b["development"]))
	var rows := gui.fill_list(_list, "building_province_list_entry", provs.size())
	for i in rows.size():
		_building_row(rows[i], provs[i])


func _building_row(row: Control, p: Dictionary) -> void:
	var pid := int(p["id"])
	var bid := _bid_for(p)
	_txt(row, "province_name", str(p["name"]))
	_txt(row, "free_slots", "%d/%d" % [construction.used_slots(pid), construction.slots(pid)],
			Loc.s("Vagas ocupadas / total", "Used / total building slots"))
	var gi := map.trade_goods.keys().find(p.get("trade_goods", ""))
	var gic := row.find_child("tradegood_icon", true, false) as Eu4Gui.Icon
	if gic:
		gic.visible = gi >= 0
		if gi >= 0:
			gic.set_frame(gi)
			gic.tooltip_text = str(map.trade_goods[p["trade_goods"]]["name"])
	var btn := row.find_child("province_button", true, false) as BaseButton
	var why := construction.why_not(player, pid, bid) if bid != "" else Loc.s("O produto da província não serve",
			"Wrong trade good")
	var q: Dictionary = construction.queue.get(pid, {})
	var col := Color.WHITE
	if not q.is_empty():
		_txt(row, "building_cost", "%d m" % int(q["left"]))
		_txt(row, "improvement_text", str(map.buildings.get(q["id"], {}).get("name", "")))
		col = Color(1, 0.9, 0.55)
	else:
		_txt(row, "building_cost", _n(construction.cost(player, bid)) if bid != "" else "—")
		_txt(row, "improvement_text", _gain_text(p, bid) if why == "" else why)
		col = Color.WHITE if why == "" else Color(0.65, 0.65, 0.65)
	for n in ["province_name", "free_slots", "building_cost", "improvement_text"]:
		var l := row.find_child(n, true, false) as Label
		if l:
			l.add_theme_color_override("font_color", col)
	if btn == null:
		return
	for cn in btn.pressed.get_connections():
		btn.pressed.disconnect(cn["callable"])
	if not q.is_empty():
		btn.tooltip_text = Loc.f("MACRO_ARE_BUILDING", {"BUILDING": map.buildings.get(q["id"], {}).get("name", ""),
				"PROVINCE": p["name"]}, "Construindo") + "\n" + Loc.t("MACRO_CANCEL", "Clique para cancelar") \
				+ Loc.s(" (o dinheiro volta)", " (refunded)")
		btn.pressed.connect(func(): construction.cancel(pid))
	elif why == "":
		btn.tooltip_text = Loc.f("MACRO_CLICK_TO_BUILD", {"PROVINCE": p["name"]}, "Clique para construir em %s" % p["name"]) \
				+ "\n%s: %s" % [map.buildings[bid]["name"], map.building_effects(bid)]
		btn.pressed.connect(func(): construction.build(player, pid, bid))
	else:
		btn.tooltip_text = why


## Ganho estimado da construção na província (renda/mês, bens ou poder comercial), como o EU4 mostra.
func _gain_text(p: Dictionary, bid: String) -> String:
	var m: Dictionary = map.buildings.get(bid, {}).get("modifiers", {})
	var gid: String = p.get("trade_goods", "")
	var price := float(map.trade_goods[gid]["price"]) if map.trade_goods.has(gid) else 0.0
	if m.has("local_tax_modifier"):
		return "+%s/m" % _n(snappedf(float(p.get("base_tax", 0)) * float(m["local_tax_modifier"]) / 12.0, 0.01))
	if m.has("local_production_efficiency"):
		return "+%s/m" % _n(snappedf(map.goods_produced(p) * price * float(m["local_production_efficiency"]) / 12.0, 0.01))
	if m.has("trade_goods_size") or not map.buildings.get(bid, {}).get("goods", []).is_empty():
		return Loc.s("+%s bens", "+%s goods") % _n(float(m.get("trade_goods_size", 1.0)))
	if m.has("province_trade_power_modifier") and map.trade_view and not map.trade_view.prov_power.is_empty():
		return "+%s%%" % _n(float(m["province_trade_power_modifier"]) * 100.0)
	return ""


# ------------------------------------------------------------------ desenvolvimento
func _fill_development() -> void:
	_title(Loc.t("DEVELOP_PROVINCE", "Desenvolver província"))
	var provs := _mine()
	provs.sort_custom(func(a, b): return construction.dev_cost(player, int(a["id"])) < construction.dev_cost(player, int(b["id"])) \
			if construction.dev_cost(player, int(a["id"])) != construction.dev_cost(player, int(b["id"])) \
			else int(a["development"]) > int(b["development"]))
	var rows := gui.fill_list(_list, "development_entry", provs.size())
	for i in rows.size():
		var row: Control = rows[i]
		var p: Dictionary = provs[i]
		var pid := int(p["id"])
		var cost := construction.dev_cost(player, pid)
		_txt(row, "province_name", str(p["name"]))
		_txt(row, "cost", str(cost), Loc.t("DEVELOPMENT_COST", "Custo de desenvolvimento"))
		_txt(row, "development", str(int(p["development"])), Loc.t("DEVELOPMENT_TEXT", "Desenvolvimento"))
		_txt(row, "autonomy", "0%")
		var gi := map.trade_goods.keys().find(p.get("trade_goods", ""))
		var gic := row.find_child("trade_good", true, false) as Eu4Gui.Icon
		if gic:
			gic.visible = gi >= 0
			if gi >= 0:
				gic.set_frame(gi)
				gic.tooltip_text = str(map.trade_goods[p["trade_goods"]]["name"])
		for kind in Construction.DEV_KINDS:
			var field: String = Construction.DEV_KINDS[kind][0]
			var cat: String = Construction.DEV_KINDS[kind][1]
			_txt(row, kind, str(int(p.get(field, 0))))
			var b := row.find_child(kind + "_button", true, false) as BaseButton
			if b == null:
				continue
			var ok := construction.can_develop(player, pid, kind)
			b.disabled = not ok
			b.modulate = Color.WHITE if ok else Color(0.6, 0.6, 0.6)
			b.tooltip_text = Loc.s("+1 de %s por %d pontos %s (você tem %d)", "+1 %s for %d %s points (you have %d)") % [
					Loc.t({"tax": "BASE_TAX", "production": "BASE_PRODUCTION", "manpower": "BASE_MANPOWER"}[kind], kind),
					cost, cat, power.points(player, cat)]
			for cn in b.pressed.get_connections():
				b.pressed.disconnect(cn["callable"])
			var k: String = kind
			b.pressed.connect(func(): construction.develop(player, pid, k))


# ------------------------------------------------------------------ missionários
func _fill_missionaries() -> void:
	_title(Loc.t("HINT_MISSIONARY_TITLE", "Missionários") + " %d/%d" % [religion.missions.get(player, {}).size(),
			religion.max_missionaries(player)] if religion else "")
	if religion == null:
		gui.fill_list(_list, "", 0)
		return
	var provs := []
	for p in _mine():
		if religion.can_convert(player, int(p["id"])) or religion.has_mission(player, int(p["id"])):
			provs.append(p)
	provs.sort_custom(func(a, b):
		var ma := religion.has_mission(player, int(a["id"]))
		var mb := religion.has_mission(player, int(b["id"]))
		return ma if ma != mb else religion.months_left(player, int(a["id"])) < religion.months_left(player, int(b["id"])))
	var rows := gui.fill_list(_list, "send_missionary_entry", provs.size())
	for i in rows.size():
		var row: Control = rows[i]
		var p: Dictionary = provs[i]
		var pid := int(p["id"])
		var rid: String = p.get("religion", "")
		_txt(row, "province_name", str(p["name"]))
		_txt(row, "religion", str(map.religions.get(rid, {}).get("name", rid)))
		var ic := row.find_child("province_religion", true, false) as Eu4Gui.Icon
		if ic:
			ic.set_religion(map.religions.get(rid, {}))
		var active := religion.has_mission(player, pid)
		var ml := religion.months_left(player, pid)
		_txt(row, "time", str(ml) if ml >= 0 else "—", Loc.s("Meses até converter", "Months until converted"))
		var bar := row.find_child("missionary_progress", true, false) as Control
		var frame := row.find_child("missionary_progress_frame", true, false) as Control
		var cancel := row.find_child("province_missionaryprogress_cancel", true, false) as BaseButton
		var send := row.find_child("send", true, false) as BaseButton
		if bar:
			bar.visible = active
			bar.scale.x = clampf(religion.progress(player, pid) / 100.0, 0.0, 1.0)
		if frame:
			frame.visible = active
		if cancel:
			cancel.visible = active
			cancel.tooltip_text = Loc.t("RECALL", "Chamar")
			for cn in cancel.pressed.get_connections():
				cancel.pressed.disconnect(cn["callable"])
			cancel.pressed.connect(func(): religion.recall(player, pid))
		if send:
			send.visible = not active
			send.disabled = not religion.can_send(player, pid)
			send.modulate = Color.WHITE if not send.disabled else Color(0.6, 0.6, 0.6)
			var s := religion.strength(player, pid)
			send.tooltip_text = Loc.s("Força líquida %s%% por mês, %s ducados por mês", "Net strength %s%% per month, %s ducats per month") \
					% [_n(snappedf(s * 100.0, 0.01)), _n(snappedf(religion.mission_cost(pid, player), 0.01))]
			for cn in send.pressed.get_connections():
				send.pressed.disconnect(cn["callable"])
			send.pressed.connect(func(): religion.send(player, pid))
