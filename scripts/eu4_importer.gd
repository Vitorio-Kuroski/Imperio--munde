class_name Eu4Importer
extends RefCounted
## Importa, dentro do jogo, o mapa e os donos de 1444 a partir dos arquivos do EU4 do
## jogador: a pasta de instalação do jogo e/ou arquivos .zip com map/, history/ e common/.
## O resultado vai para user://eu4/ (map.json + province_ids.png), que MapView prefere.
## Os arquivos do jogo nunca são copiados para o projeto nem distribuídos com ele.
## Mesma lógica de tools/import_eu4.py (o script Python continua servindo para o editor).

const OUT_DIR := "user://eu4"
const CUTOFF := 14441111            # 1444.11.11 como AAAAMMDD
const TOPS := ["map/", "history/", "common/", "localisation/"]
const MAP_FILES := ["provinces.bmp", "definition.csv", "default.map", "climate.txt", "heightmap.bmp"]

var status := ""                    # mensagem de progresso (a interface lê)
var error := ""                     # vazio = deu certo
var done := false

var _mutex := Mutex.new()
var _index := {}                    # caminho relativo -> [zip (-1 = pasta), caminho completo]
var _zips: Array[FileAccess] = []
var _zip_entries: Array[Dictionary] = []    # por zip: nome -> [método, tam. comprimido, tam. real, crc, offset]
var _tok := RegEx.create_from_string("#[^\\n]*|\"[^\"]*\"|[{}=]|[^\\s{}=#\"]+")


static func has_import() -> bool:
	return FileAccess.file_exists(OUT_DIR + "/map.json") and FileAccess.file_exists(OUT_DIR + "/province_ids.png")


## Apaga o mapa importado (o jogo volta ao mapa padrão).
static func remove_import() -> void:
	for f in ["map.json", "province_ids.png"]:
		if FileAccess.file_exists(OUT_DIR + "/" + f):
			DirAccess.remove_absolute(OUT_DIR + "/" + f)


# ------------------------------------------------------------------ fontes (pasta ou .zip)
## Adiciona uma pasta (a do jogo ou qualquer subpasta) ou um .zip. Retorna quantos arquivos úteis achou.
func add_source(path: String) -> int:
	var before := _index.size()
	if path.get_extension().to_lower() == "zip":
		var entries := _zip_index(path)
		if entries.is_empty():
			return 0
		_zips.append(FileAccess.open(path, FileAccess.READ))
		_zip_entries.append(entries)
		for f in entries:
			var rel := _rel(f)
			if rel != "":
				_index[rel] = [_zips.size() - 1, f]
	elif DirAccess.dir_exists_absolute(path):
		_walk(path.rstrip("/\\"), 0)
	return _index.size() - before


func _walk(dir: String, depth: int) -> void:
	if depth > 6:
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		var full := dir + "/" + f
		var rel := _rel(full)
		if rel != "":
			_index[rel] = [-1, full]
	for sub in d.get_directories():
		var low: String = sub.to_lower()
		# não desce em pastas grandes que não interessam
		if low in ["gfx", "sound", "music", "interface", "tutorial", "dlc", "launcher", "events", "decisions",
				"missions", "gui", "fonts", "shaders", "assets", "ideas", "units", "wars", "advisors", "diplomacy"]:
			continue
		_walk(dir + "/" + sub, depth + 1)


## Caminho relativo à pasta do jogo ("map/definition.csv"), ou "" se o arquivo não interessa.
func _rel(p: String) -> String:
	p = p.replace("\\", "/")
	var best := -1
	for t in TOPS:
		var i := 0
		while true:
			i = p.find(t, i)
			if i < 0:
				break
			if i == 0 or p[i - 1] == "/":
				if best < 0 or i < best:
					best = i
				break
			i += 1
	var rel := p.substr(best) if best >= 0 else ""
	if rel == "" and p.get_file() in MAP_FILES:
		rel = "map/" + p.get_file()        # arquivo solto (ex.: um .zip só com provinces.bmp)
	if rel.begins_with("map/"):
		return rel if rel.get_file() in MAP_FILES and rel.count("/") == 1 else ""
	for keep in ["history/provinces/", "history/countries/", "common/countries/", "common/country_tags/",
			"common/cultures/", "common/religions/", "common/tradegoods/", "common/prices/", "common/tradenodes/",
			"common/buildings/"]:
		if rel.begins_with(keep) and rel.ends_with(".txt"):
			return rel
	if rel.begins_with("localisation/") and rel.ends_with("_l_english.yml"):
		return rel
	return ""


func _list(prefix: String) -> PackedStringArray:
	var out := PackedStringArray()
	for k in _index:
		if (k as String).begins_with(prefix):
			out.append(k)
	out.sort()
	return out


func _bytes(rel: String) -> PackedByteArray:
	var e: Array = _index[rel]
	if e[0] < 0:
		return FileAccess.get_file_as_bytes(e[1])
	return _zip_read(e[0], e[1])


# ------------------------------------------------------------------ leitura de .zip
# O ZIPReader do Godot procura o arquivo do começo do índice a cada leitura (milhares de
# arquivos de history/ levam ~40 s); aqui o índice central é lido uma vez só.

## Índice central do zip: nome -> [método, tamanho comprimido, tamanho real, crc32, offset do cabeçalho local].
func _zip_index(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var flen := f.get_length()
	var tail_len := mini(flen, 65557)
	f.seek(flen - tail_len)
	var tail := f.get_buffer(tail_len)
	var eocd := -1
	for i in range(tail_len - 22, -1, -1):
		if tail[i] == 0x50 and tail[i + 1] == 0x4B and tail[i + 2] == 0x05 and tail[i + 3] == 0x06:
			eocd = i
			break
	if eocd < 0:
		return {}
	var cd_size := tail.decode_u32(eocd + 12)
	var cd_off := tail.decode_u32(eocd + 16)
	if cd_off == 0xFFFFFFFF or cd_off + cd_size > flen:
		return {}       # zip64 (> 4 GB) não é suportado
	f.seek(cd_off)
	var cd := f.get_buffer(cd_size)
	var out := {}
	var o := 0
	while o + 46 <= cd.size() and cd.decode_u32(o) == 0x02014B50:
		var nlen := cd.decode_u16(o + 28)
		var name := cd.slice(o + 46, o + 46 + nlen).get_string_from_utf8()
		if not name.ends_with("/"):
			out[name] = [cd.decode_u16(o + 10), cd.decode_u32(o + 20), cd.decode_u32(o + 24),
					cd.decode_u32(o + 16), cd.decode_u32(o + 42)]
		o += 46 + nlen + cd.decode_u16(o + 30) + cd.decode_u16(o + 32)
	return out


func _zip_read(zi: int, name: String) -> PackedByteArray:
	var f := _zips[zi]
	var e: Array = _zip_entries[zi][name]
	f.seek(e[4])
	var head := f.get_buffer(30)
	if head.size() < 30 or head.decode_u32(0) != 0x04034B50:
		return PackedByteArray()
	f.seek(e[4] + 30 + head.decode_u16(26) + head.decode_u16(28))
	var raw := f.get_buffer(e[1])
	if e[0] == 0:
		return raw          # guardado sem compressão
	if e[0] != 8:
		return PackedByteArray()
	# DEFLATE puro: embrulha como gzip (cabeçalho + dados + crc32 + tamanho) para o Godot descomprimir
	var gz := PackedByteArray([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
	gz.append_array(raw)
	var trailer := PackedByteArray()
	trailer.resize(8)
	trailer.encode_u32(0, e[3])
	trailer.encode_u32(4, e[2])
	gz.append_array(trailer)
	if e[2] == 0:
		return PackedByteArray()
	return gz.decompress(e[2], FileAccess.COMPRESSION_GZIP)


## Texto: UTF-8 se tiver BOM (localização), senão Latin-1/cp1252 (resto dos arquivos do EU4).
func _text(rel: String) -> String:
	var b := _bytes(rel)
	if b.size() >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
		return b.slice(3).get_string_from_utf8()
	return b.get_string_from_ascii()


func _set_status(s: String) -> void:
	_mutex.lock()
	status = s
	_mutex.unlock()


func get_status() -> String:
	_mutex.lock()
	var s := status
	_mutex.unlock()
	return s


# ------------------------------------------------------------------ parser de script Paradox
## Lista de [chave, valor]; valor = String ou Array (bloco). Itens soltos têm chave "".
func _parse(text: String) -> Array:
	var toks := PackedStringArray()
	for m in _tok.search_all(text):
		var t := m.get_string()
		if not t.begins_with("#"):
			toks.append(t)
	var pos := [0]
	return _block(toks, pos)


func _block(toks: PackedStringArray, pos: Array) -> Array:
	var items := []
	var n := toks.size()
	while pos[0] < n:
		var t: String = toks[pos[0]]
		pos[0] += 1
		if t == "}":
			return items
		if t == "{" or t == "=":
			continue
		if pos[0] < n and toks[pos[0]] == "=":
			pos[0] += 1
			var v: Variant = ""
			if pos[0] < n and toks[pos[0]] == "{":
				pos[0] += 1
				v = _block(toks, pos)
			elif pos[0] < n:
				v = toks[pos[0]].trim_prefix("\"").trim_suffix("\"")
				pos[0] += 1
				if pos[0] < n and toks[pos[0]] == "{":      # ex.: color = rgb { 1 2 3 }
					pos[0] += 1
					v = _block(toks, pos)
			items.append([t.trim_prefix("\"").trim_suffix("\""), v])
		else:
			items.append(["", t.trim_prefix("\"").trim_suffix("\"")])
	return items


func _date(k: String) -> int:
	var p := k.split(".")
	if p.size() != 3 or not (p[0].is_valid_int() and p[1].is_valid_int() and p[2].is_valid_int()):
		return -1
	return int(p[0]) * 10000 + int(p[1]) * 100 + int(p[2])


## Estado no dia de início: chaves de topo + blocos datados até a data, em ordem.
func _state_at(items: Array) -> Dictionary:
	var st := {}
	var dated := []
	for kv in items:
		if kv[0] == "":
			continue
		var d := _date(kv[0])
		if d >= 0 and kv[1] is Array:
			dated.append([d, kv[1]])
		else:
			st[kv[0]] = kv[1]
	dated.sort_custom(func(a, b): return a[0] < b[0])
	for e in dated:
		if e[0] <= CUTOFF:
			for kv in e[1]:
				if kv[0] == "":
					continue
				if (kv[0] as String).begins_with("add_base_") and kv[1] is String:
					# add_base_tax = 1 etc.: soma ao valor base (base_tax)
					var base: String = (kv[0] as String).substr(4)
					st[base] = str(float(str(st.get(base, "0"))) + float(kv[1]))
				else:
					st[kv[0]] = kv[1]
	return st


func _ids_in_block(text: String, name: String) -> Dictionary:
	var out := {}
	var m := RegEx.create_from_string(name + "\\s*=\\s*(?:LIST\\s*)?\\{([^}]*)\\}").search(text)
	if m == null:
		return out
	var body := RegEx.create_from_string("#[^\\n]*").sub(m.get_string(1), "", true)
	for r in RegEx.create_from_string("RANGE\\s*\\{\\s*(\\d+)\\s+(\\d+)\\s*\\}").search_all(body):
		for i in range(int(r.get_string(1)), int(r.get_string(2)) + 1):
			out[i] = true
	body = RegEx.create_from_string("RANGE\\s*\\{[^}]*\\}").sub(body, "", true)
	for x in RegEx.create_from_string("\\d+").search_all(body):
		out[int(x.get_string())] = true
	return out


static func hashed_color(key: String) -> Array:
	var h := key.md5_buffer()
	var c := Color.from_hsv(h[0] / 255.0, 0.45 + 0.3 * h[1] / 255.0, 0.55 + 0.35 * h[2] / 255.0)
	return [int(c.r * 255), int(c.g * 255), int(c.b * 255)]


# ------------------------------------------------------------------ importação
## Para rodar numa Thread: faz tudo e preenche error/done.
func run() -> void:
	error = _import()
	done = true


func _import() -> String:
	var missing := []
	for need in ["map/provinces.bmp", "map/definition.csv", "map/default.map"]:
		if not _index.has(need):
			missing.append(need)
	if _list("history/provinces/").is_empty():
		missing.append("history/provinces/")
	if not missing.is_empty():
		return "Faltam arquivos do EU4: " + ", ".join(missing)

	# ---- definições de províncias
	_set_status("Lendo definition.csv...")
	var defs := {}                  # id -> nome
	var key_to_id := {}             # cor RGB (int) -> id
	var max_id := 0
	for line in _text("map/definition.csv").split("\n"):
		var p := line.strip_edges().split(";")
		if p.size() < 4 or not p[0].is_valid_int() or int(p[0]) == 0:
			continue
		var pid := int(p[0])
		defs[pid] = p[4] if p.size() > 4 else ""
		key_to_id[(int(p[1]) << 16) | (int(p[2]) << 8) | int(p[3])] = pid
		max_id = maxi(max_id, pid)
	var n_prov := max_id + 1
	var dmap := _text("map/default.map")
	var sea := _ids_in_block(dmap, "sea_starts")
	sea.merge(_ids_in_block(dmap, "lakes"))
	var climates := {}
	if _index.has("map/climate.txt"):
		var ct := _text("map/climate.txt")
		for k in ["tropical", "arid", "arctic", "severe_winter", "impassable"]:
			for pid in _ids_in_block(ct, k):
				if not climates.has(pid):
					climates[pid] = {}
				climates[pid][k] = true

	# ---- provinces.bmp -> imagem de ids, vizinhos e centros (uma passada)
	_set_status("Lendo o mapa de províncias (provinces.bmp)...")
	var img := Image.new()
	if img.load_bmp_from_buffer(_bytes("map/provinces.bmp")) != OK:
		return "Não consegui ler map/provinces.bmp"
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	img = null
	var out := PackedByteArray()
	out.resize(w * h * 3)
	var prev_row := PackedInt32Array()
	prev_row.resize(w)
	var cur_row := PackedInt32Array()
	cur_row.resize(w)
	var pairs := {}
	var cnt := PackedFloat64Array()
	cnt.resize(n_prov)
	var sx := PackedFloat64Array()
	sx.resize(n_prov)
	var sy := PackedFloat64Array()
	sy.resize(n_prov)
	var o := 0
	for y in h:
		if y % 128 == 0:
			_set_status("Convertendo províncias... %d%%" % (100 * y / h))
		var prev_key := -1
		var pid := 0
		var run_x := 0
		for x in w:
			var key: int = (data[o] << 16) | (data[o + 1] << 8) | data[o + 2]
			if key != prev_key:
				var nid: int = key_to_id.get(key, 0)
				if prev_key >= 0:
					if nid != pid:
						pairs[mini(pid, nid) * 65536 + maxi(pid, nid)] = true
					var ln := x - run_x
					cnt[pid] += ln
					sx[pid] += ln * (run_x + x - 1) * 0.5
					sy[pid] += ln * y
				pid = nid
				prev_key = key
				run_x = x
			if y > 0 and prev_row[x] != pid:
				var q: int = prev_row[x]
				pairs[mini(pid, q) * 65536 + maxi(pid, q)] = true
			cur_row[x] = pid
			out[o] = pid & 255
			out[o + 1] = pid >> 8
			o += 3
		var ln2 := w - run_x
		cnt[pid] += ln2
		sx[pid] += ln2 * (run_x + w - 1) * 0.5
		sy[pid] += ln2 * y
		var tmp := prev_row
		prev_row = cur_row
		cur_row = tmp
	data = PackedByteArray()
	var neigh := []
	neigh.resize(n_prov)
	for i in n_prov:
		neigh[i] = []
	for k in pairs:
		var a: int = k / 65536
		var b: int = k % 65536
		neigh[a].append(b)
		neigh[b].append(a)

	# ---- relevo (heightmap.bmp, amostrado a cada 2 px) para o terreno
	var hsum := PackedFloat64Array()
	var hsq := PackedFloat64Array()
	var hcnt := PackedFloat64Array()
	var has_height := false
	if _index.has("map/heightmap.bmp"):
		_set_status("Lendo o relevo (heightmap.bmp)...")
		var him := Image.new()
		if him.load_bmp_from_buffer(_bytes("map/heightmap.bmp")) == OK and him.get_width() == w and him.get_height() == h:
			him.convert(Image.FORMAT_L8)
			var hd := him.get_data()
			hsum.resize(n_prov)
			hsq.resize(n_prov)
			hcnt.resize(n_prov)
			for y in range(0, h, 2):
				for x in range(0, w, 2):
					var i := y * w + x
					var q: int = out[i * 3] | (out[i * 3 + 1] << 8)
					var v: float = hd[i]
					hsum[q] += v
					hsq[q] += v * v
					hcnt[q] += 1
			has_height = true

	_set_status("Gravando o mapa...")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var idimg := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, out)
	if idimg.save_png(OUT_DIR + "/province_ids.png") != OK:
		return "Não consegui gravar " + OUT_DIR + "/province_ids.png"
	idimg = null
	out = PackedByteArray()

	# ---- construções (common/buildings)
	var buildings := _buildings()
	var bids := {}
	for b in buildings:
		bids[b["id"]] = true

	# ---- história das províncias (dono, cultura, religião, desenvolvimento)
	var owner := {}
	var culture := {}
	var religion := {}
	var dev := {}
	var dev_parts := {}             # id -> [imposto, produção, efetivo]
	var goods := {}
	var prov_buildings := {}
	var cot := {}                   # centro de comércio (nível)
	var files := _list("history/provinces/")
	for fi in files.size():
		if fi % 200 == 0:
			_set_status("Lendo a história das províncias... %d/%d" % [fi, files.size()])
		var f: String = files[fi]
		var m := RegEx.create_from_string("^\\s*(\\d+)").search(f.get_file())
		if m == null:
			continue
		var pid := int(m.get_string(1))
		if not defs.has(pid):
			continue
		var st := _state_at(_parse(_text(f)))
		if st.get("owner") is String and st["owner"] != "":
			owner[pid] = st["owner"]
		if st.get("culture") is String:
			culture[pid] = st["culture"]
		if st.get("religion") is String:
			religion[pid] = st["religion"]
		if st.get("trade_goods") is String:
			goods[pid] = st["trade_goods"]
		var parts := []
		for k in ["base_tax", "base_production", "base_manpower"]:
			parts.append(int(round(float(str(st.get(k, "0"))))))
		dev_parts[pid] = parts
		var have := []
		for b in bids:
			if st.get(b) is String and st[b] == "yes":
				have.append(b)
		if not have.is_empty():
			prov_buildings[pid] = have
		var c := int(float(str(st.get("center_of_trade", "0"))))
		if c > 0:
			cot[pid] = c
		dev[pid] = parts[0] + parts[1] + parts[2]

	# ---- localização (opcional)
	_set_status("Lendo países e culturas...")
	var loc := {}
	var loc_re := RegEx.create_from_string("(?m)^\\s*([A-Za-z0-9_]+):\\d*\\s+\"(.*)\"\\s*$")
	for f in _list("localisation/"):
		for m in loc_re.search_all(_text(f)):
			if not loc.has(m.get_string(1)):
				loc[m.get_string(1)] = m.get_string(2)

	# ---- países
	var tags := {}
	for f in _list("common/country_tags/"):
		for m in RegEx.create_from_string("(?m)^\\s*([A-Z0-9]{3})\\s*=\\s*\"([^\"]+)\"").search_all(_text(f)):
			tags[m.get_string(1)] = m.get_string(2).replace("\\", "/")
	var file_names := {}
	var hist_country := {}
	var camel := RegEx.create_from_string("(?<=[a-z])(?=[A-Z])")
	for f in _list("history/countries/"):
		var m := RegEx.create_from_string("^\\s*([A-Z0-9]{3})\\s*-\\s*(.+?)\\.txt$").search(f.get_file())
		if m:
			file_names[m.get_string(1)] = camel.sub(m.get_string(2).strip_edges(), " ", true)
			hist_country[m.get_string(1)] = f
	var used := {}
	for t in owner.values():
		used[t] = true
	var used_tags := used.keys()
	used_tags.sort()
	if used_tags.size() > 65535:
		return "Países demais (%d)." % used_tags.size()
	var first_prov := {}
	var owned_ids := owner.keys()
	owned_ids.sort()
	for pid in owned_ids:
		if not first_prov.has(owner[pid]):
			first_prov[owner[pid]] = pid
	var countries := []
	for tag in used_tags:
		var color := hashed_color(tag)
		var rel := "common/" + str(tags.get(tag, ""))
		if tags.has(tag) and _index.has(rel):
			for kv in _parse(_text(rel)):
				if kv[0] == "color" and kv[1] is Array:
					var vals := []
					for x in kv[1]:
						if x[0] == "" and str(x[1]).is_valid_float():
							vals.append(float(x[1]))
					if vals.size() >= 3:
						if vals[0] <= 1.0 and vals[1] <= 1.0 and vals[2] <= 1.0:
							vals = [vals[0] * 255, vals[1] * 255, vals[2] * 255]
						color = [int(vals[0]), int(vals[1]), int(vals[2])]
					break
		var capital: int = first_prov.get(tag, 1)
		if hist_country.has(tag):
			var st := _state_at(_parse(_text(hist_country[tag])))
			var c := str(st.get("capital", ""))
			if c.is_valid_int() and defs.has(int(c)):
				capital = int(c)
		var name: String = loc.get(tag, file_names.get(tag, tag))
		countries.append({"tag": tag, "name": name, "color": color, "capital": capital})

	# ---- culturas (grupos de common/cultures, se houver)
	var groups := {}
	for f in _list("common/cultures/"):
		for g in _parse(_text(f)):
			if g[1] is Array:
				for c in g[1]:
					if c[1] is Array and not (c[0] in ["graphical_culture", "male_names", "female_names", "dynasty_names", ""]):
						groups[c[0]] = g[0]
	var cult_ids := {}
	for c in culture.values():
		cult_ids[c] = true
	var cult_list := cult_ids.keys()
	cult_list.sort()
	var cultures := []
	for cid in cult_list:
		var g: String = groups.get(cid, "")
		var col := hashed_color(g if g != "" else cid)
		if g != "":     # mesma família de cor dentro do grupo
			var k := (cid as String).md5_buffer()
			var base := Color8(col[0], col[1], col[2])
			var c2 := Color.from_hsv(fposmod(base.h + (k[0] - 128) / 2600.0, 1.0),
					clampf(base.s + (k[1] - 128) / 900.0, 0.3, 1.0), clampf(base.v + (k[2] - 128) / 700.0, 0.4, 1.0))
			col = [int(c2.r * 255), int(c2.g * 255), int(c2.b * 255)]
		cultures.append({"id": cid, "name": loc.get(cid, (cid as String).capitalize()),
				"group": (loc.get(g, g.capitalize()) if g != "" else ""), "color": col})

	# ---- religiões (grupos e cores de common/religions; nomes em português de data/religioes_pt.json)
	var religions := _religions(religion.values(), loc)
	var trade_goods := _trade_goods(goods.values(), loc)
	var node_of := {}
	var trade_nodes := _trade_nodes(loc, node_of)

	# ---- map.json
	_set_status("Gravando os dados...")
	var provinces := []
	for pid in n_prov:
		var c := cnt[pid]
		var center := [round(sx[pid] / maxf(c, 1.0) * 10) / 10.0, round(sy[pid] / maxf(c, 1.0) * 10) / 10.0]
		if pid == 0:
			provinces.append({"id": 0, "name": "—", "sea": true, "owner": "", "terrain": "mar",
					"development": 0, "center": center, "neighbors": neigh[0]})
			continue
		var is_sea := sea.has(pid)
		var nm: String = loc.get("PROV%d" % pid, "")
		if nm == "":
			nm = defs.get(pid, "")
			if nm == "" or nm == "x":
				nm = "Província %d" % pid
		var prov := {"id": pid, "name": nm, "sea": is_sea, "owner": "" if is_sea else owner.get(pid, ""),
				"terrain": "mar", "development": 0, "center": center, "neighbors": neigh[pid]}
		if not is_sea:
			var hm := -1.0
			var hs := 0.0
			if has_height and hcnt[pid] > 0:
				hm = hsum[pid] / hcnt[pid]
				hs = sqrt(maxf(hsq[pid] / hcnt[pid] - hm * hm, 0.0))
			prov["terrain"] = _terrain(climates.get(pid, {}), hm, hs)
			prov["development"] = dev.get(pid, 0)
			prov["base_development"] = prov["development"]
			prov["culture"] = culture.get(pid, "")
			prov["religion"] = religion.get(pid, "")
			prov["trade_goods"] = goods.get(pid, "")
			var parts: Array = dev_parts.get(pid, [0, 0, 0])
			prov["base_tax"] = parts[0]
			prov["base_production"] = parts[1]
			prov["base_manpower"] = parts[2]
			if prov_buildings.has(pid):
				prov["buildings"] = prov_buildings[pid]
			if cot.has(pid):
				prov["center_of_trade"] = cot[pid]
		if node_of.has(pid):
			prov["trade_node"] = node_of[pid]
			var coastal := false
			for q in neigh[pid]:
				if sea.has(q):
					coastal = true
					break
			prov["coastal"] = coastal
		provinces.append(prov)
	var f := FileAccess.open(OUT_DIR + "/map.json", FileAccess.WRITE)
	if f == null:
		return "Não consegui gravar " + OUT_DIR + "/map.json"
	f.store_string(JSON.stringify({"width": w, "height": h, "countries": countries, "cultures": cultures,
			"religions": religions, "trade_goods": trade_goods, "trade_nodes": trade_nodes, "buildings": buildings,
			"provinces": provinces}))
	f.close()
	_set_status("Pronto: %d províncias, %d países em 11/11/1444." % [defs.size(), countries.size()])
	return ""


## Nós de comércio {id, name, color, location, inland, end, outgoing: [{to, path}]} de common/tradenodes;
## preenche node_of (província -> nó). Nomes de data/nos_comercio_pt.json.
func _trade_nodes(loc: Dictionary, node_of: Dictionary) -> Array:
	var pt := _json("res://data/nos_comercio_pt.json")
	var out := []
	for f in _list("common/tradenodes/"):
		for n in _parse(_text(f)):
			if not (n[1] is Array):
				continue
			var nid: String = n[0]
			var node := {"id": nid, "name": pt.get(nid, loc.get(nid, nid.capitalize())), "color": hashed_color(nid),
					"location": 0, "inland": false, "end": false, "outgoing": []}
			for kv in n[1]:
				match kv[0]:
					"location":
						if str(kv[1]).is_valid_int():
							node["location"] = int(kv[1])
					"color":
						var col := _numbers(kv[1])
						if col.size() >= 3:
							if col[0] <= 1.0 and col[1] <= 1.0 and col[2] <= 1.0:
								col = [col[0] * 255, col[1] * 255, col[2] * 255]
							node["color"] = [mini(255, int(col[0] + 0.5)), mini(255, int(col[1] + 0.5)),
									mini(255, int(col[2] + 0.5))]
					"inland", "end":
						node[kv[0]] = kv[1] is String and kv[1] == "yes"
					"outgoing":
						if kv[1] is Array:
							var to := ""
							var path := []
							for x in kv[1]:
								if x[0] == "name":
									to = str(x[1])
								elif x[0] == "path" and x[1] is Array:
									for y in x[1]:
										if y[0] == "" and str(y[1]).is_valid_int():
											path.append(int(y[1]))
							node["outgoing"].append({"to": to, "path": path})
					"members":
						if kv[1] is Array:
							for y in kv[1]:
								if y[0] == "" and str(y[1]).is_valid_int() and not node_of.has(int(y[1])):
									node_of[int(y[1])] = nid
			out.append(node)
	return out


## Construções de common/buildings: {id, name, cost, time, modifiers, replaces?, goods?, one_per_country?}.
func _buildings() -> Array:
	var pt: Dictionary = _json("res://data/construcoes_pt.json").get("nomes", {})
	var out := []
	var by_id := {}
	for f in _list("common/buildings/"):
		for bk in _parse(_text(f)):
			if not (bk[1] is Array):
				continue
			var b := {"id": bk[0], "name": pt.get(bk[0], (bk[0] as String).capitalize())}
			var mods := {}
			for kv in bk[1]:
				match kv[0]:
					"cost", "time":
						if str(kv[1]).is_valid_float():
							b[kv[0]] = _int_if_whole(float(kv[1]))
					"modifier":
						if kv[1] is Array:
							for m in kv[1]:
								if m[0] != "" and m[1] is String:
									if m[1] == "yes":
										mods[m[0]] = true
									elif (m[1] as String).is_valid_float():
										mods[m[0]] = _int_if_whole(float(m[1]))
									else:
										mods[m[0]] = m[1]
					"make_obsolete":
						if kv[1] is String:
							b["replaces"] = kv[1]
					"manufactory":
						if kv[1] is Array:
							var g := []
							for x in kv[1]:
								if x[0] == "":
									g.append(x[1])
							b["goods"] = g
					"one_per_country":
						if kv[1] is String and kv[1] == "yes":
							b["one_per_country"] = true
			b["modifiers"] = mods
			out.append(b)
			by_id[b["id"]] = b
	# manufaturas especiais herdam custo e tempo da "manufactory"
	for b in out:
		if b.has("goods") and not b.has("cost") and by_id.has("manufactory"):
			for k in ["cost", "time"]:
				if by_id["manufactory"].has(k):
					b[k] = by_id["manufactory"][k]
	return out


func _int_if_whole(x: float) -> Variant:
	return int(x) if x == floorf(x) else x


func _numbers(v: Variant) -> Array:
	var out := []
	if v is Array:
		for x in v:
			if x[0] == "" and str(x[1]).is_valid_float():
				out.append(float(x[1]))
	return out


func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


## Lista de produtos {id, name, color, price}: os de common/tradegoods (cor) com o preço base de
## common/prices, mais os usados nas províncias que não estiverem lá. Nomes de data/produtos_pt.json.
func _trade_goods(used: Array, loc: Dictionary) -> Array:
	var pt: Dictionary = {}
	if FileAccess.file_exists("res://data/produtos_pt.json"):
		pt = JSON.parse_string(FileAccess.get_file_as_string("res://data/produtos_pt.json"))
	var prices := {}
	for f in _list("common/prices/"):
		for g in _parse(_text(f)):
			if g[1] is Array:
				for kv in g[1]:
					if kv[0] == "base_price" and str(kv[1]).is_valid_float():
						prices[g[0]] = float(kv[1])
	var out := []
	var seen := {}
	for f in _list("common/tradegoods/"):
		for g in _parse(_text(f)):
			if not (g[1] is Array) or seen.has(g[0]):
				continue
			var col := []
			for kv in g[1]:
				if kv[0] == "color" and kv[1] is Array:
					for x in kv[1]:
						if x[0] == "" and str(x[1]).is_valid_float():
							col.append(float(x[1]))
					break
			if col.size() < 3:
				continue
			if col[0] <= 1.0 and col[1] <= 1.0 and col[2] <= 1.0:
				col = [col[0] * 255, col[1] * 255, col[2] * 255]
			seen[g[0]] = true
			out.append({"id": g[0], "name": pt.get(g[0], loc.get(g[0], (g[0] as String).capitalize())),
					"color": [mini(255, int(round(col[0]))), mini(255, int(round(col[1]))), mini(255, int(round(col[2])))],
					"price": prices.get(g[0], 1.0)})
	var rest := {}
	for gid in used:
		if gid != "" and not seen.has(gid):
			rest[gid] = true
	var keys := rest.keys()
	keys.sort()
	for gid in keys:
		out.append({"id": gid, "name": pt.get(gid, loc.get(gid, (gid as String).capitalize())),
				"color": hashed_color(gid), "price": prices.get(gid, 1.0)})
	return out


## Lista de religiões {id, name, group, color}: todas as de common/religions (na ordem do arquivo)
## mais as usadas nas províncias que não estiverem lá.
func _religions(used: Array, loc: Dictionary) -> Array:
	var pt: Dictionary = {}
	if FileAccess.file_exists("res://data/religioes_pt.json"):
		pt = JSON.parse_string(FileAccess.get_file_as_string("res://data/religioes_pt.json"))
	var nice := func(k: String) -> String: return pt.get(k, loc.get(k, k.capitalize()))
	var out := []
	var seen := {}
	for f in _list("common/religions/"):
		for g in _parse(_text(f)):
			if not (g[1] is Array):
				continue
			for r in g[1]:
				if not (r[1] is Array) or seen.has(r[0]):
					continue
				var col := []
				for kv in r[1]:
					if kv[0] == "color" and kv[1] is Array:
						for x in kv[1]:
							if x[0] == "" and str(x[1]).is_valid_float():
								col.append(float(x[1]))
				if col.size() < 3:
					continue        # não é religião (ex.: flag_emblem_index_range)
				if col[0] <= 1.0 and col[1] <= 1.0 and col[2] <= 1.0:
					col = [col[0] * 255, col[1] * 255, col[2] * 255]
				seen[r[0]] = true
				out.append({"id": r[0], "name": nice.call(r[0]), "group": nice.call(g[0]),
						"color": [int(col[0]), int(col[1]), int(col[2])]})
	var rest := {}
	for r in used:
		if r != "" and not seen.has(r):
			rest[r] = true
	var keys := rest.keys()
	keys.sort()
	for r in keys:
		out.append({"id": r, "name": nice.call(r), "group": "", "color": hashed_color(r)})
	return out


func _terrain(c: Dictionary, hm: float, hs: float) -> String:
	if c.has("impassable"):
		return "intransitável"
	if hm >= 0.0:
		if hm > 165 or hs > 16:
			return "montanhas"
		if hm > 125 or hs > 8:
			return "deserto" if c.has("arid") else "colinas"
	if c.has("arid"):
		return "deserto"
	if c.has("arctic"):
		return "tundra"
	if c.has("tropical"):
		return "selva"
	if c.has("severe_winter"):
		return "floresta"
	return "planície"
