class_name Eu4UnitPanel
extends Control
## Painel do exército selecionado, com as telas do EU4: single_unitpanel (unitpanel_main.gui) e o
## cartão `unitpanel` (unitpanel_card.gui) por cima, com a lista dos regimentos (subunit_entry,
## unitpanel_sub.gui).
##  - Cartão: nome, tamanho, onde está ou para onde vai (e em quantos dias), botões de dividir ao
##    meio (newunitbutton02) e dispensar (disbandbutton); dica com moral e manutenção.
##  - Topo: infantaria/cavalaria/artilharia com o número de regimentos e os homens; o "+" recruta
##    um regimento daquele tipo na província onde o exército está (se for do jogador).
##  - attach_unit_button junta os outros exércitos do país parados na mesma província.
##  - O resto (generais, missões, cercos, transporte...) ainda não existe e fica escondido.
## Só os exércitos do jogador têm botões; os de outros países só mostram.

signal closed

const MAIN_KEEP := ["regiment_bg", "lu_unit_type_1", "lu_unit_type_1_count", "lu_unit_type_1_value",
		"lu_build_unit_1_button", "lu_unit_type_2", "lu_unit_type_2_count", "lu_unit_type_2_value",
		"lu_build_unit_2_button", "lu_unit_type_3", "lu_unit_type_3_count", "lu_unit_type_3_value",
		"lu_build_unit_3_button", "subunitlist", "attach_unit_button"]
const CARD_KEEP := ["unitpanel_bg_pc", "land_units", "unit1_type", "unit1_count", "unit2_type", "unit2_count",
		"unit3_type", "unit3_count", "unitstrength_land", "unitlocation", "unit_destination", "disbandbutton",
		"newunitbutton02", "unitattrition", "unit_attrition_icon"]
const SUB_KEEP := ["band_regiment", "icon_type", "subunit_amount", "subunit_type", "RegName"]
const FRAMES := {"infantry": 0, "cavalry": 1, "artillery": 2}

var gui: Eu4Gui
var map: MapView
var army: Army
var player := ""
var id := -1
var _main: Control
var _card: Control
var _name: Label
var _rows: Array = []              # linhas da lista de regimentos (reaproveitadas)


func setup(g: Eu4Gui, m: MapView, a: Army) -> bool:
	gui = g
	map = m
	army = a
	if gui.find_window("single_unitpanel").is_empty() or gui.find_window("unitpanel").is_empty():
		return false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_main = gui.build("single_unitpanel")
	_card = gui.build("unitpanel")
	if _main == null or _card == null:
		return false
	var w := gui.find_window("single_unitpanel")
	var sp := Eu4Gui._vec(gui._resolve(w), "show_position")    # dentro de if_resolution
	_main.position = sp
	add_child(_main)
	_card.position = sp + Vector2(0, -74)     # o fundo do cartão (99 px, em y = 35) termina sobre o topo do regiment_bg
	add_child(_card)
	_keep(_main, MAIN_KEEP)
	_keep(_card, CARD_KEEP)
	_name = Label.new()            # unitname é um editBoxType (o Eu4Gui não monta)
	gui.style_label(_name, "vic_18")
	_name.position = Vector2(52, 49)
	_name.size = Vector2(170, 22)
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_find(_card, "unitpanel_bg_pc").get_parent().add_child(_name)
	for i in 3:
		var ty: String = Army.TYPES[i]
		var ic := _find(_main, "lu_unit_type_%d" % (i + 1)) as Eu4Gui.Icon
		if ic:
			ic.set_frame(FRAMES[ty])
		var ci := _find(_card, "unit%d_type" % (i + 1)) as Eu4Gui.Button2
		if ci:
			ci.set_frame(FRAMES[ty])
		var b := _find(_main, "lu_build_unit_%d_button" % (i + 1)) as BaseButton
		if b:
			b.pressed.connect(_recruit.bind(ty))
			if ic and b.get_parent() == ic.get_parent():     # no .gui o "+" fica fora do lugar
				b.position = ic.position + Vector2(66, -12)
	_button(_card, "newunitbutton02", func(): _split(), Loc.t("UNIT_SPLIT", Loc.s("Dividir ao meio", "Split in half")))
	_button(_card, "disbandbutton", func(): _disband(), Loc.s("Dispensar o exército", "Disband the army"))
	_button(_main, "attach_unit_button", func():
		army.merge_here(id)
		refresh(), Loc.s("Juntar os outros exércitos parados aqui", "Merge the other armies standing here"))
	army.changed.connect(func(_t): _queue())
	army.moved.connect(_queue)
	hide()
	return true


var _pending := false


## Várias mudanças no mesmo quadro (vários dias na velocidade máxima) viram uma atualização só.
func _queue() -> void:
	if _pending or not visible:
		return
	_pending = true
	(func():
		_pending = false
		refresh()).call_deferred()


func _find(root: Control, n: String) -> Control:
	return root.find_child(n, true, false) as Control


func _button(root: Control, n: String, f: Callable, tip: String) -> void:
	var b := _find(root, n) as BaseButton
	if b:
		b.pressed.connect(f)
		b.tooltip_text = tip


## Esconde tudo que não está em `keep` (nem contém algo de `keep`).
func _keep(root: Control, keep: Array) -> void:
	var need := {}
	for n in keep:
		var c := _find(root, n)
		while c and c != root:
			need[c] = true
			c = c.get_parent() as Control
	for c in root.find_children("*", "Control", true, false):
		if not need.has(c) and String(c.name) != "Items" and not _inside_kept(c, root, keep):
			c.hide()


func _inside_kept(c: Node, root: Control, keep: Array) -> bool:
	var p := c.get_parent()
	while p and p != root:
		if String(p.name) in keep:
			return true
		p = p.get_parent()
	return false


func show_army(a_id: int) -> void:
	id = a_id
	if not army.armies.has(id):
		hide()
		return
	show()
	refresh()


func close() -> void:
	id = -1
	hide()
	closed.emit()


func refresh() -> void:
	if not visible:
		return
	var a: Dictionary = army.armies.get(id, {})
	if a.is_empty():
		close()
		return
	var tag: String = a["tag"]
	var mine := tag == player
	var c: Dictionary = map.countries.get(tag, {})
	_name.text = str(a["name"]) + ("" if mine else " (%s)" % c.get("name", tag))
	_txt(_card, "unitstrength_land", Manpower.fmt(army.strength(a)),
			Loc.s("Moral %s de %s · manutenção %s ducados/mês (todos os regimentos do país)",
			"Morale %s of %s · maintenance %s ducats/month (all of the country's regiments)") % [
			_n(army.morale(a)), _n(army.max_morale(tag)), _n(army.maintenance(tag))])
	var pid := int(a["loc"])
	var att := army.attrition_at(pid, tag)
	_txt(_card, "unitattrition", ("%.1f%%" % att).replace(".", Loc.dec), Loc.s("Atrito por mês: %s regimentos na província, limite de suprimento %s",
			"Attrition per month: %s regiments in the province, supply limit %s") % [
			str(army.armies_at(pid).reduce(func(s, b): return s + b["regs"].size(), 0)), _n(army.supply_limit(pid, tag))])
	var here: String = map.provinces[pid]["name"]
	var status := ""
	if army.combat and army.combat.in_battle(id):
		var b: Dictionary = army.combat.battles[pid]
		status = Loc.s("Em batalha (dia %d, %s; dados %d × %d)", "In battle (day %d, %s; dice %d × %d)") % [int(b["day"]),
				Loc.s("fogo", "fire") if b["phase"] == "fire" else Loc.s("choque", "shock"), int(b["rolls"][0]), int(b["rolls"][1])]
	elif a.get("retreat", false):
		status = Loc.s("Em retirada", "Retreating")
	elif army.siege and army.siege.sieges.has(pid) and army.siege.sieges[pid]["tag"] == tag:
		var s: Dictionary = army.siege.sieges[pid]
		status = Loc.s("Cercando: forte %d, situação +%d, %d dias (último dado %d; precisa de 20)",
				"Sieging: fort %d, status +%d, %d days (last roll %d; needs 20)") % [int(s["level"]), int(s["status"]),
				int(s["days"]), int(s["last_roll"])]
	here += (" — " + status) if status != "" else ""
	var dest := _find(_card, "unit_destination")
	if a["path"].is_empty():
		_txt(_card, "unitlocation", map.provinces[pid]["name"], here)
		if dest:
			dest.hide()
	else:
		var to: String = map.provinces[int(a["path"][a["path"].size() - 1])]["name"]
		_txt(_card, "unitlocation", map.provinces[pid]["name"], here + "\n" + Loc.s("Indo para %s: %d dias", "Moving to %s: %d days") % [to, army.eta(a)])
		if dest:
			dest.show()
			dest.tooltip_text = Loc.s("Indo para %s: %d dias", "Moving to %s: %d days") % [to, army.eta(a)]
	for i in 3:
		var ty: String = Army.TYPES[i]
		var n := army.count(a, ty)
		var men := 0.0
		for r in a["regs"]:
			if r["type"] == ty:
				men += float(r["str"])
		_txt(_card, "unit%d_count" % (i + 1), str(n))
		_txt(_main, "lu_unit_type_%d_count" % (i + 1), str(n))
		_txt(_main, "lu_unit_type_%d_value" % (i + 1), Manpower.fmt(men))
		var u: Dictionary = army.units(tag).get(ty, {})
		var ic := _find(_main, "lu_unit_type_%d" % (i + 1))
		if ic:
			ic.tooltip_text = str(u.get("name", ty))
		var b := _find(_main, "lu_build_unit_%d_button" % (i + 1)) as BaseButton
		if b:
			b.visible = mine
			var why := army.why_not(tag, int(a["loc"]), ty) if a["path"].is_empty() \
					else Loc.s("O exército está em marcha", "The army is moving")
			b.disabled = why != ""
			b.modulate = Color(0.45, 0.45, 0.45) if b.disabled else Color.WHITE
			b.tooltip_text = Loc.s("Recrutar %s aqui: %d ducados, 1000 homens, %d dias", "Recruit %s here: %d ducats, 1000 men, %d days") % [
					u.get("name", ty), ceili(army.reg_cost(tag, ty)), army.reg_days(tag, ty)] + ("\n" + why if why != "" else "") \
					+ _queue_text(int(a["loc"]), tag)
	for n in ["newunitbutton02", "disbandbutton"]:
		var x := _find(_card, n)
		if x:
			x.visible = mine
	var at := _find(_main, "attach_unit_button")
	if at:
		var others := 0
		for b in army.armies_at(int(a["loc"])):
			if b["id"] != id and b["tag"] == tag and b["path"].is_empty():
				others += 1
		at.visible = mine and others > 0
	# regimentos: as linhas só são refeitas quando o número muda (montar uma é caro)
	var list := _find(_main, "subunitlist")
	var regs: Array = a["regs"].duplicate()          # infantaria, cavalaria, artilharia
	regs.sort_custom(func(x, y): return Army.TYPES.find(x["type"]) < Army.TYPES.find(y["type"]))
	var n: int = regs.size()
	if _rows.size() != n or (n > 0 and not is_instance_valid(_rows[0])):
		_rows = gui.fill_list(list, "subunit_entry", n)
		for row in _rows:
			_keep(row, SUB_KEEP)
	for i in mini(_rows.size(), n):
		_reg_row(_rows[i], regs[i])


func _queue_text(pid: int, tag: String) -> String:
	var q: Array = army.queue.get(pid, [])
	var parts := []
	for it in q:
		if it["tag"] == tag:
			parts.append("%s (%d)" % [_type_name(it["type"]), int(it["left"])])
	return ("\n" + Loc.s("Recrutando: ", "Recruiting: ") + ", ".join(parts)) if not parts.is_empty() else ""


static func _type_name(ty: String) -> String:
	return Loc.t(ty.to_upper(), {"infantry": "Infantaria", "cavalry": "Cavalaria", "artillery": "Artilharia"}.get(ty, ty))


func _reg_row(row: Control, r: Dictionary) -> void:
	var ic := _find(row, "icon_type") as Eu4Gui.Icon
	if ic:
		ic.set_frame(FRAMES.get(r["type"], 0))
	var u: Dictionary = map.units.get(r["unit"], {})
	var nm := row.get_node_or_null("RegName") as Label
	if nm == null:                     # subunit_name é um editBoxType
		nm = Label.new()
		nm.name = "RegName"
		gui.style_label(nm, "vic_18")
		nm.position = Vector2(34, 6)
		nm.size = Vector2(190, 20)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(nm)
	nm.text = _type_name(r["type"])
	_txt(row, "subunit_type", str(u.get("name", r["unit"])))
	_txt(row, "subunit_amount", str(roundi(float(r["str"]) * 1000.0)))


func _txt(root: Control, n: String, t: String, tip := "") -> void:
	var l := _find(root, n) as Label
	if l:
		l.text = t
		Eu4Gui.fit_label(l)
		l.tooltip_text = tip
		if tip != "":
			l.mouse_filter = Control.MOUSE_FILTER_PASS


static func _n(v: float) -> String:
	return ("%.2f" % v).replace(".", Loc.dec)


func _recruit(ty: String) -> void:
	var a: Dictionary = army.armies.get(id, {})
	if not a.is_empty() and a["tag"] == player:
		army.recruit(player, int(a["loc"]), ty)
		refresh()


func _split() -> void:
	var b := army.split(id)
	refresh()


func _disband() -> void:
	army.disband(id)
	close()
