class_name CountryPanel
extends PanelContainer
## Painel do país (canto superior direito): governo, reformas, posto, capital, grupo tecnológico,
## culturas, religião, foco nacional, governante e herdeiro em 1444 (mapa do EU4), além de
## províncias e desenvolvimento. Os nomes em português vêm de data/governos_pt.json.

const START := [1444, 11, 11]
const FOCUS := {"ADM": "Administrativo", "DIP": "Diplomático", "MIL": "Militar"}

signal techs_requested(tag: String)
signal ideas_requested(tag: String)
signal advisors_requested(tag: String)
signal shown(tag: String)

var tag := ""
var power: MonarchPower           # main.gd define
var _map: MapView
var _label: Label
var _scroll: ScrollContainer
var _flag: TextureRect
var _tech_button: Button
var _ideas_button: Button
var _advisors_button: Button
var economy: Economy
var institutions: Institutions
var diplomacy: Diplomacy
var _embrace_button: Button
var _embrace_id := ""
var advisors: Advisors
var _pt := {}


func _init() -> void:
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	offset_right = -12
	offset_top = 44
	var vb := VBoxContainer.new()
	add_child(vb)
	_flag = TextureRect.new()
	_flag.custom_minimum_size = Vector2(56, 56)
	_flag.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_flag.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	vb.add_child(_flag)
	_scroll = ScrollContainer.new()          # o texto rola se não couber na tela
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(_scroll)
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size.x = 320
	_scroll.add_child(_label)
	_tech_button = Button.new()
	_tech_button.text = "Ver tecnologias e unidades"
	_tech_button.pressed.connect(func(): techs_requested.emit(tag))
	vb.add_child(_tech_button)
	_ideas_button = Button.new()
	_ideas_button.text = "Ver ideias"
	_ideas_button.pressed.connect(func(): ideas_requested.emit(tag))
	vb.add_child(_ideas_button)
	_advisors_button = Button.new()
	_advisors_button.text = "Ver conselheiros"
	_advisors_button.pressed.connect(func(): advisors_requested.emit(tag))
	vb.add_child(_advisors_button)
	_embrace_button = Button.new()
	_embrace_button.pressed.connect(func():
		if institutions and institutions.embrace(tag, _embrace_id):
			refresh())
	vb.add_child(_embrace_button)
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
	_flag.texture = map.flag_texture(t)
	_flag.visible = _flag.texture != null
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
	if economy:
		var inc := economy.income(t)
		var exp := economy.expenses(t)
		lines.append("Tesouro: %s ducados (%s/mês: imposto %s, produção %s, conselheiros -%s)" % [
				AdvisorsWindow._n(economy.money(t)), AdvisorsWindow._n(economy.balance(t), true),
				AdvisorsWindow._n(inc["tax"]), AdvisorsWindow._n(inc["production"]), AdvisorsWindow._n(exp["advisors"])])
	if advisors and advisors.enabled():
		var adv := []
		for cat in Advisors.CATS:
			var h := advisors.get_hired(t, cat)
			adv.append("%s %s" % [cat, ("%s %d" % [advisors.types[h["type"]]["name"], int(h["skill"])]) if not h.is_empty() else "—"])
		lines.append("Conselheiros: " + " · ".join(adv))
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
	if power and not map.national_ideas.is_empty():
		var nat: Dictionary = power.national_ideas.get(c.get("ideas", ""), {})
		var txt := "Ideias: "
		if not nat.is_empty():
			txt += ("nacionais" if (nat["id"] as String).begins_with(t) else nat["name"]) + \
					" %d/7 · " % power.national_unlocked(t)
		var gr := []
		for g in power.adopted(t):
			gr.append("%s %d/7" % [power.idea_groups[g["id"]]["name"], int(g["n"])])
		txt += "grupos %d/%d" % [power.adopted(t).size(), power.idea_slots(t)] + (" (%s)" % ", ".join(gr) if not gr.is_empty() else "")
		lines.append(txt)
	_embrace_button.visible = false
	if institutions and institutions.enabled():
		var parts := []
		for inst in institutions.list:
			var iid: String = inst["id"]
			if not institutions.born.has(iid):
				continue
			if institutions.has_embraced(t, iid):
				parts.append(inst["name"] + " ✓")
			else:
				var pr := institutions.present(t, iid)
				parts.append("%s %d%%" % [inst["name"], roundi(pr * 100.0)])
				if t == power.player and pr >= Institutions.EMBRACE_MIN and not _embrace_button.visible:
					_embrace_id = iid
					_embrace_button.text = "Adotar %s (%s ducados)" % [inst["name"],
							AdvisorsWindow._n(institutions.embrace_cost(t, iid))]
					_embrace_button.disabled = not institutions.can_embrace(t, iid)
					_embrace_button.visible = true
		if not parts.is_empty():
			lines.append("Instituições: " + ", ".join(parts))
	_ideas_button.visible = power != null and not map.national_ideas.is_empty()
	_advisors_button.visible = advisors != null and advisors.enabled()
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
	if diplomacy and diplomacy.enabled():
		var at := 1
		for i in lines.size():
			if (lines[i] as String).begins_with("Capital:"):
				at = i + 1
		var dl := _diplomacy_lines(map, t)
		for i in dl.size():
			lines.insert(at + i, dl[i])
	lines.append("Províncias: %d · desenvolvimento %d" % [n, dev])
	_label.text = "\n".join(lines)
	# altura do texto limitada à tela (os botões ficam sempre visíveis embaixo)
	var buttons := 0
	for b in [_tech_button, _ideas_button, _advisors_button, _embrace_button]:
		if b.visible:
			buttons += 1
	var max_h := get_viewport_rect().size.y - 44.0 - 24.0 - buttons * 36.0 - (60.0 if _flag.visible else 0.0)
	_scroll.custom_minimum_size = Vector2(336, minf(_label.get_combined_minimum_size().y, max_h))
	shown.emit(t)
	show()
	reset_size()


## Atualiza o texto (por exemplo, quando os pontos mudam no fim do mês).
func refresh() -> void:
	if visible and _map:
		show_country(_map, tag)


func _cname(map: MapView, t: String) -> String:
	return map.countries[t]["name"] if map.countries.has(t) else t


func _diplomacy_lines(map: MapView, t: String) -> Array:
	var out := []
	var ov := diplomacy.overlord(t)
	if not ov.is_empty():
		out.append("Suserano: %s (%s)" % [_cname(map, ov[0]), diplomacy.subject_name(ov[1])])
	var subs := []
	for s in diplomacy.subjects(t):
		subs.append("%s (%s)" % [_cname(map, s[0]), diplomacy.subject_name(s[1])])
	if not subs.is_empty():
		out.append("Súditos: " + ", ".join(subs))
	for pair in [["Aliados", diplomacy.allies(t)], ["Casamentos reais", diplomacy.marriages(t)],
			["Garante", diplomacy.guarantees(t)], ["Garantido por", diplomacy.guarantors(t)]]:
		if not pair[1].is_empty():
			var names := []
			for o in pair[1]:
				names.append(_cname(map, o))
			out.append("%s: %s" % [pair[0], ", ".join(names)])
	if t == diplomacy.emperor:
		out.append("Imperador do Sacro Império Romano")
	elif diplomacy.is_elector(t):
		out.append("Príncipe-eleitor do Sacro Império")
	elif diplomacy.in_hre(t):
		out.append("Membro do Sacro Império (imperador: %s)" % _cname(map, diplomacy.emperor))
	if t == diplomacy.celestial_emperor:
		out.append("Imperador celestial (Mandato do Céu)")
	for w in diplomacy.wars_of(t):
		var side := Diplomacy.side_of(w, t)
		var other: Array = w["defenders"] if side == "attackers" else w["attackers"]
		var names := []
		for o in other:
			names.append(_cname(map, o))
		var years := "%s–%s" % [str(w["start"]).get_slice(".", 0), str(w["end"]).get_slice(".", 0)] \
				if w["end"] != "" else "desde %s" % str(w["start"]).get_slice(".", 0)
		var cb := diplomacy.cb_name(w)
		var txt := "%s %s (%s%s; contra %s)" % ["Em guerra:" if w.has("active") else "Guerra recente:", w["name"],
				years, (", " + cb) if cb != "" else "", ", ".join(names)]
		for b in w.get("battles", []):
			var mine: bool = side != "" and str(b.get("attacker", {}).get("country", "")) in w[side]
			var won: bool = b.get("attacker_won", false) == mine
			txt += " — batalha de %s (%s, %s)" % [b.get("name", "?"), _fmt_date(b["date"]), "vitória" if won else "derrota"]
		out.append(txt)
	return out


static func _fmt_date(d: String) -> String:
	var p := d.split(".")
	return "%s/%s/%s" % [p[2], p[1], p[0]] if p.size() == 3 else d


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
