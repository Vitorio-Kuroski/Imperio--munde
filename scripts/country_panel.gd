class_name CountryPanel
extends PanelContainer
## Painel do país (canto superior direito): governo, reformas, posto, capital, grupo tecnológico,
## culturas, religião, foco nacional, governante e herdeiro em 1444 (mapa do EU4), além de
## províncias e desenvolvimento. Os nomes em português vêm de data/governos_pt.json.

const START := [1444, 11, 11]
const FOCUS := {"ADM": "Administrativo", "DIP": "Diplomático", "MIL": "Militar"}

signal techs_requested(tag: String)

var tag := ""
var power: MonarchPower           # main.gd define
var _map: MapView
var _label: Label
var _tech_button: Button
var _pt := {}


func _init() -> void:
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	offset_right = -12
	offset_top = 44
	var vb := VBoxContainer.new()
	add_child(vb)
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size.x = 320
	vb.add_child(_label)
	_tech_button = Button.new()
	_tech_button.text = "Ver tecnologias e unidades"
	_tech_button.pressed.connect(func(): techs_requested.emit(tag))
	vb.add_child(_tech_button)
	if FileAccess.file_exists("res://data/governos_pt.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/governos_pt.json"))
		if d is Dictionary:
			_pt = d
	hide()


## Mostra o país `t` (vazio esconde o painel).
func show_country(map: MapView, t: String) -> void:
	tag = t
	_map = map
	if t == "" or not map.countries.has(t):
		hide()
		return
	var c: Dictionary = map.countries[t]
	var lines := ["%s (%s)" % [c["name"], t]]
	var gov := ""
	if c.has("government"):
		gov = _pt.get("governos", {}).get(c["government"], Eu4Importer.pretty_key(c["government"]))
	var reforms := []
	for r in c.get("reforms", []):
		reforms.append(_pt.get("reformas", {}).get(r, Eu4Importer.pretty_key(r, "_reform")))
	if gov != "" or not reforms.is_empty():
		lines.append("Governo: " + gov + (" — " + ", ".join(reforms) if not reforms.is_empty() else ""))
	if c.has("rank"):
		lines.append("Posto: " + str(_pt.get("postos", {}).get(str(c["rank"]), c["rank"])))
	var cap := int(c.get("capital", 0))
	if cap > 0 and cap < map.provinces.size():
		lines.append("Capital: " + map.provinces[cap]["name"])
	if c.has("tech_group"):
		lines.append("Grupo tecnológico: " + _pt.get("grupos_tecnologicos", {}).get(c["tech_group"],
				Eu4Importer.pretty_key(c["tech_group"])))
		if map.tech_groups.has(c["tech_group"]):
			var g: Dictionary = map.tech_groups[c["tech_group"]]
			lines.append("Tecnologia: adm %d · dip %d · mil %d (custo %+d%%)" % [
					TechWindow.level_of(map, t, "adm", power), TechWindow.level_of(map, t, "dip", power),
					TechWindow.level_of(map, t, "mil", power), roundi(float(g["cost_modifier"]) * 100.0)])
	if power and power.state.has(t):
		lines.append("Pontos de monarca: adm %d (+%d) · dip %d (+%d) · mil %d (+%d) por mês" % [
				power.points(t, "adm"), power.gain(t, "adm"), power.points(t, "dip"), power.gain(t, "dip"),
				power.points(t, "mil"), power.gain(t, "mil")])
	var cur := TechWindow.current_units(map, t, power) if not map.units.is_empty() else {}
	var army := []
	for ty in [["infantry", "infantaria"], ["cavalry", "cavalaria"], ["artillery", "artilharia"]]:
		if cur.has(ty[0]):
			army.append("%s: %s" % [ty[1], cur[ty[0]]["name"]])
	if not army.is_empty():
		lines.append("Exército: " + "; ".join(army))
	_tech_button.visible = not map.technologies.is_empty() and map.tech_groups.has(c.get("tech_group", ""))
	if c.has("primary_culture"):
		lines.append("Cultura principal: " + _culture(map, c["primary_culture"]))
	var acc := []
	for a in c.get("accepted_cultures", []):
		acc.append(_culture(map, a))
	if not acc.is_empty():
		lines.append("Culturas aceitas: " + ", ".join(acc))
	if c.has("religion"):
		var rid: String = c["religion"]
		lines.append("Religião: " + (map.religions[rid]["name"] if map.religions.has(rid) else Eu4Importer.pretty_key(rid)))
	if c.has("national_focus"):
		lines.append("Foco nacional: " + FOCUS.get(c["national_focus"], c["national_focus"]))
	if c.has("monarch"):
		lines.append("Governante: " + _person(c["monarch"]))
	if c.has("heir"):
		lines.append("Herdeiro: " + _person(c["heir"]))
	var n := 0
	var dev := 0
	for p in map.provinces:
		if p["owner"] == t:
			n += 1
			dev += int(p["development"])
	lines.append("Províncias: %d · desenvolvimento %d" % [n, dev])
	_label.text = "\n".join(lines)
	show()
	reset_size()


## Atualiza o texto (por exemplo, quando os pontos mudam no fim do mês).
func refresh() -> void:
	if visible and _map:
		show_country(_map, tag)


func _culture(map: MapView, cid: String) -> String:
	return map.cultures[cid]["name"] if map.cultures.has(cid) else Eu4Importer.pretty_key(cid)


## "Charles VII de Valois, 41 anos (adm 4 · dip 2 · mil 4)"
func _person(p: Dictionary) -> String:
	var txt: String = p.get("name", "?")
	if p.has("dynasty"):
		txt += " " + p["dynasty"]
	var b := str(p.get("birth_date", "")).split(".")
	if b.size() == 3 and b[0].is_valid_int():
		var age: int = START[0] - int(b[0])
		if int(b[1]) * 100 + int(b[2]) > START[1] * 100 + START[2]:
			age -= 1
		txt += ", %d anos" % age
	if p.has("adm"):
		txt += " (adm %d · dip %d · mil %d)" % [p.get("adm", 0), p.get("dip", 0), p.get("mil", 0)]
	return txt
