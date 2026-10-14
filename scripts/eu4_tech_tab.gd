class_name Eu4TechTab
extends RefCounted
## Aba Tecnologia da tela do país do EU4 (countrytechnologyview.gui): uma tabela por árvore
## (adm/dip/mil) com o nível atual, o próximo nível (nome, custo, ano, botão de pesquisar, barra
## de pontos, instituições esperadas e construções liberadas) e o total dos efeitos já pesquisados.

const CATS := ["adm", "dip", "mil"]
## Valor da tabela -> [efeito somado das tecnologias, é porcentagem?]
const STATS := {
	"adm": {"tech_allowed_idea_groups_value": ["allowed_idea_groups", false],
			"tech_production_efficiency_value": ["production_efficiency", true],
			"tech_administrative_efficiency_value": ["administrative_efficiency", true],
			"tech_development_cost_modifier_value": ["development_cost_modifier", true],
			"tech_governing_capacity_value": ["governing_capacity", false]},
	"dip": {"tech_trade_efficiency_value": ["trade_efficiency", true], "tech_trade_range_value": ["trade_range", false],
			"tech_range_value": ["range", false], "tech_colonial_growth_value": ["global_colonial_growth", false],
			"tech_naval_morale_value": ["naval_morale", false], "tech_maintenance_value": ["naval_maintenance", true],
			"tech_engagement_value": ["naval_engagement_width", false]},
	"mil": {"tech_inf_fire_value": ["infantry_fire", false], "tech_inf_shock_value": ["infantry_shock", false],
			"tech_cav_fire_value": ["cavalry_fire", false], "tech_cav_shock_value": ["cavalry_shock", false],
			"tech_art_fire_value": ["artillery_fire", false], "tech_art_shock_value": ["artillery_shock", false],
			"tech_land_morale_value": ["land_morale", false], "tech_supply_limit_value": ["supply_limit", false],
			"tech_military_tactics_value": ["military_tactics", false], "tech_combatwidth_value": ["combat_width", false],
			"tech_maneuver_value": ["maneuver_value", false]}}
## Unidade atual de cada tipo -> nome no .gui.
const UNIT_NAMES := {"infantry": "tech_unit_infantry_name", "cavalry": "tech_unit_cavalry_name",
		"artillery": "tech_unit_artillery_name", "heavy_ship": "tech_nav_heavy_ship_name",
		"light_ship": "tech_nav_light_ship_name", "galley": "tech_nav_galley_name",
		"transport": "tech_nav_transport_name"}
const HIDE := ["tech_gov_monarchy_unlock", "tech_gov_monarchy", "tech_gov_monarchy_name", "tech_gov_republic_unlock",
		"tech_gov_republic", "tech_gov_republic_name", "tech_gov_tribal_unlock", "tech_gov_tribal", "tech_gov_tribal_name",
		"tech_enable", "buildings", "tech_accepted_cultures", "tech_unit_infantry_unlock", "tech_unit_cavalry_unlock",
		"tech_unit_artillery_unlock", "tech_nav_heavy_ship_unlock", "tech_nav_light_ship_unlock",
		"tech_nav_galley_unlock", "tech_nav_transport_unlock", "tech_unit_infantry", "tech_unit_cavalry",
		"tech_unit_artillery", "tech_nav_heavy_ship", "tech_nav_light_ship", "tech_nav_galley", "tech_nav_transport"]

var view: Eu4CountryView
var root: Control
var _pt := {}


func setup(v: Eu4CountryView) -> bool:
	view = v
	root = v._open("countrytechnologyview")
	if root == null:
		return false
	for n in ["show_institutions", "innovativeness_icon", "innovativeness_text", "institutions_window"]:
		Eu4CountryView._hide(root, n)
	if FileAccess.file_exists("res://data/tecnologias_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/tecnologias_pt.json"))
		if d is Dictionary:
			_pt = d
	return true


func _name(cat: String, t: Dictionary) -> String:
	var names: Array = _pt.get("nomes", {}).get(cat, [])
	var n := int(t["level"])
	if Loc.active() and t.has("name"):        # nome da localização do EU4 (MapView._apply_loc)
		return str(t["name"])
	return str(names[n]) if n < names.size() else str(t.get("name", "Nível %d" % n))


static func _fmt(v: float, pct: bool) -> String:
	if pct:
		return ("%+d%%" % roundi(v * 100.0))
	return (("%+d" % int(v)) if v == floorf(v) else ("%+.2f" % v)).replace(".", Loc.dec)


func fill(tag: String) -> void:
	var map := view.map
	var power := view.power
	view._txt(root, "window_title", Loc.t("HEADER_TECHNOLOGY", "Tecnologia") + " — " + map.countries[tag]["name"])
	var tables := root.find_child("tables", true, false) as Control
	view.gui.fill_list(tables, "", 0)
	var cur_units := TechWindow.current_units(map, tag, power) if not map.units.is_empty() else {}
	for cat in CATS:
		var t := view.gui.add_item(tables, "countrytechnologyview_table_%s_tech" % cat)
		if t:
			_fill_table(t, tag, cat, cur_units)


func _fill_table(t: Control, tag: String, cat: String, cur_units: Dictionary) -> void:
	var map := view.map
	var power := view.power
	for n in HIDE:
		Eu4CountryView._hide(t, n)
	var techs: Array = map.technologies.get(cat, [])
	var lvl := TechWindow.level_of(map, tag, cat, power)
	var cur: Dictionary = techs[lvl] if lvl < techs.size() else {}
	var nxt: Dictionary = techs[lvl + 1] if lvl + 1 < techs.size() else {}
	view._txt(t, "tech", _name(cat, cur) if not cur.is_empty() else "")
	view._txt(t, "current_tech_level", str(lvl))
	# próximo nível
	var cost := power.tech_cost(tag, cat) if power and power.state.has(tag) else -1
	var pts := power.points(tag, cat) if power and power.state.has(tag) else 0
	var btn := t.find_child("tech_research", true, false) as BaseButton
	if nxt.is_empty():
		view._txt(t, "tech_research_name", Loc.s("Árvore completa", "Tree completed"))
	else:
		view._txt(t, "tech_research_name", "%s (%d)" % [_name(cat, nxt), cost] if cost >= 0 else _name(cat, nxt))
	if btn:
		btn.disabled = not (power and tag == view.player and power.can_research(tag, cat))
		btn.tooltip_text = (Loc.s("Pesquisar o nível %d: %d pontos %s (você tem %d)",
				"Research level %d: %d %s points (you have %d)") % [lvl + 1, cost, cat, pts]) \
				if not nxt.is_empty() and cost >= 0 else ""
		for cn in btn.pressed.get_connections():
			btn.pressed.disconnect(cn["callable"])
		btn.pressed.connect(func():
			if power.research(tag, cat):
				view.refresh())
	var prog := t.find_child("power_progress", true, false) as Eu4Gui.Progress
	if prog:
		prog.set_value(float(pts) / float(cost) if cost > 0 else 1.0)
		prog.tooltip_text = Loc.s("%d / %d pontos", "%d / %d points") % [pts, cost] if cost > 0 else ""
	view._txt(t, "time_value", str(int(nxt.get("year", 0))) if not nxt.is_empty() else "", \
			Loc.s("Ano da tecnologia (pesquisar antes custa mais)", "Technology year (researching ahead of time costs more)"))
	# instituições esperadas e construções liberadas pelo próximo nível
	var ib := t.find_child("required_institutions_box", true, false) as Control
	if ib:
		_clear(ib)
		var exp: Dictionary = nxt.get("institutions", {})
		for iid in exp:
			var tex := map.icon_texture("inst:" + iid)
			if tex:
				var ok := view.institutions != null and view.institutions.has_embraced(tag, iid)
				var r := MapView.icon_rect(tex, 24, "%s %d%% (%s)" % [view.institutions.name_of(iid) if view.institutions \
						else iid, roundi(float(exp[iid]) * 100.0), Loc.t("EMBRACED", "adotada") if ok \
							else Loc.s("não adotada: encarece a pesquisa", "Not Embraced: research costs more")])
				r.modulate = Color.WHITE if ok else Color(1, 0.55, 0.55)
				ib.add_child(r)
	var items := t.find_child("tech_researchitems", true, false) as Control
	if items:
		_clear(items)
		for b in nxt.get("buildings", []):
			var tex := map.icon_texture("building:" + b)
			if tex and items.get_child_count() < 6:
				items.add_child(MapView.icon_rect(tex, 30, Loc.s("Libera: ", "Unlocks: ") + str(map.buildings.get(b, {}).get("name", b))))
	# efeitos somados até o nível atual
	var sums := {}
	for i in mini(lvl + 1, techs.size()):
		var mods: Dictionary = techs[i].get("modifiers", {})
		for k in mods:
			if k == "allowed_idea_groups":       # total do nível, não acréscimo
				sums[k] = maxf(float(sums.get(k, 0.0)), float(mods[k]))
			else:
				sums[k] = float(sums.get(k, 0.0)) + float(mods[k])
	var st: Dictionary = STATS[cat]
	for n in st:
		view._txt(t, n, _fmt(float(sums.get(st[n][0], 0.0)), st[n][1]))
	for ty in UNIT_NAMES:
		if cur_units.has(ty):
			view._txt(t, UNIT_NAMES[ty], str(cur_units[ty]["name"]), TechWindow.unit_stats(cur_units[ty]))


static func _clear(c: Control) -> void:
	for ch in c.get_children():
		c.remove_child(ch)
		ch.queue_free()
