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
## Caracteres do cp1252 que o Latin-1 não tem (0x80-0x9F -> Unicode).
const CP1252 := {0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
		0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
		0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
		0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178}
const MAP_FILES := ["provinces.bmp", "definition.csv", "default.map", "climate.txt", "heightmap.bmp", "terrain.txt",
		"terrain.bmp", "trees.bmp", "rivers.bmp", "area.txt", "region.txt", "superregion.txt", "continent.txt",
		"adjacencies.csv"]

var status := ""                    # mensagem de progresso (a interface lê)
var error := ""                     # vazio = deu certo
var done := false

var _mutex := Mutex.new()
var _index := {}                    # caminho relativo -> [zip (-1 = pasta), caminho completo]
var _zips: Array[FileAccess] = []
var _zip_entries: Array[Dictionary] = []
var _loc := {}                      # localização em inglês (nomes oficiais quando não há tradução)    # por zip: nome -> [método, tam. comprimido, tam. real, crc, offset]
var _high_re := RegEx.create_from_string("[\\x{80}-\\x{FF}]")
var _tok := RegEx.create_from_string("#[^\\n]*|\"[^\"]*\"|[{}=]|[^\\s{}=#\"]+")


static func has_import() -> bool:
	return FileAccess.file_exists(OUT_DIR + "/map.json") and FileAccess.file_exists(OUT_DIR + "/province_ids.png")


## Apaga o mapa importado (o jogo volta ao mapa padrão).
static func remove_import() -> void:
	for f in ["map.json", "province_ids.png", "rivers.png"]:
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
			"common/buildings/", "common/governments/", "common/technologies/", "common/units/", "common/ideas/",
			"common/advisortypes/", "history/advisors/", "common/institutions/", "history/diplomacy/", "history/wars/"]:
		if rel.begins_with(keep) and rel.ends_with(".txt"):
			return rel
	if rel.begins_with("localisation/") and rel.ends_with("_l_english.yml"):
		return rel
	if rel == "common/technology.txt":
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
	var s := b.get_string_from_ascii()          # Latin-1
	var high: Array[int] = []
	for m in _high_re.search_all(s):
		high.append(m.get_start())
	if high.is_empty():
		return s                                # só ASCII
	if _is_utf8(b, high):
		return b.get_string_from_utf8()         # alguns arquivos são UTF-8 sem BOM
	for code in CP1252:                         # 0x80-0x9F do cp1252 (š, œ, ž, aspas...)
		var ch := String.chr(code)
		if s.contains(ch):
			s = s.replace(ch, String.chr(CP1252[code]))
	return s


## Os bytes >= 0x80 (posições `high`) formam sequências UTF-8 válidas?
func _is_utf8(b: PackedByteArray, high: Array[int]) -> bool:
	var k := 0
	while k < high.size():
		var i := high[k]
		var c := b[i]
		var n := 0
		if c >= 0xC2 and c <= 0xDF:
			n = 1
		elif c >= 0xE0 and c <= 0xEF:
			n = 2
		elif c >= 0xF0 and c <= 0xF4:
			n = 3
		else:
			return false
		for j in range(1, n + 1):
			if k + j >= high.size() or high[k + j] != i + j or b[i + j] > 0xBF:
				return false
		k += n + 1
	return true


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


## País no dia de início: governo, reformas, grupo tecnológico, cultura principal e aceitas, religião,
## capital, posto, foco nacional, monarca e herdeiro (blocos datados até a data).
func _country_history(items: Array) -> Dictionary:
	var seq := []
	var dated := []
	for kv in items:
		if kv[0] == "":
			continue
		var d := _date(kv[0])
		if d >= 0 and kv[1] is Array:
			dated.append([d, kv[1]])
		else:
			seq.append(kv)
	dated.sort_custom(func(a, b): return a[0] < b[0])
	for e in dated:
		if e[0] <= CUTOFF:
			for kv in e[1]:
				if kv[0] != "":
					seq.append(kv)
	var h := {"reforms": [], "accepted_cultures": []}
	var keys := {"government": "government", "technology_group": "tech_group", "primary_culture": "primary_culture",
			"religion": "religion", "capital": "capital", "national_focus": "national_focus"}
	for kv in seq:
		var k: String = kv[0]
		var v = kv[1]
		if v is String:
			if keys.has(k):
				h[keys[k]] = v
			elif k == "government_rank" and (v as String).is_valid_int():
				h["rank"] = int(v)
			elif k == "add_government_reform" and not (v in h["reforms"]):
				h["reforms"].append(v)
			elif k == "add_accepted_culture" and not (v in h["accepted_cultures"]):
				h["accepted_cultures"].append(v)
			elif k == "remove_accepted_culture":
				h["accepted_cultures"].erase(v)
			elif k == "elector":
				if v == "yes":
					h["elector"] = true
				else:
					h.erase("elector")
		elif k in ["monarch", "heir"] and v is Array:
			var person := {}
			for x in v:
				if x[0] in ["name", "dynasty", "birth_date"] and x[1] is String:
					person[x[0]] = x[1]
				elif x[0] in ["adm", "dip", "mil"] and x[1] is String and (x[1] as String).is_valid_int():
					person[x[0]] = int(x[1])
			h[k] = person
			if k == "monarch" and h.has("heir") and h["heir"].get("name") == person.get("name"):
				h.erase("heir")     # o herdeiro virou o monarca
	return h


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

	# ---- terreno do próprio EU4 (terrain.txt + terrain.bmp + trees.bmp) e rios
	var terrains := []
	var terrain_of := _eu4_terrain(out, w, h, n_prov, terrains)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	if FileAccess.file_exists(OUT_DIR + "/rivers.png"):
		DirAccess.remove_absolute(OUT_DIR + "/rivers.png")
	if _index.has("map/rivers.bmp"):
		_set_status("Lendo os rios (rivers.bmp)...")
		var rv := _bmp8("map/rivers.bmp")
		if not rv.is_empty() and rv[0] == w and rv[1] == h:
			# índice da paleta (< 254 = rio; 254 = terra; 255 = mar), o shader lê direto
			Image.create_from_data(w, h, false, Image.FORMAT_L8, rv[2]).save_png(OUT_DIR + "/rivers.png")

	_set_status("Gravando o mapa...")
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
	var hre := {}                   # províncias do Sacro Império em 1444
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
		if st.get("hre") is String and st["hre"] == "yes":
			hre[pid] = true
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
		var hist := {}
		if hist_country.has(tag):
			hist = _country_history(_parse(_text(hist_country[tag])))
			var c := str(hist.get("capital", ""))
			hist.erase("capital")
			if c.is_valid_int() and defs.has(int(c)):
				capital = int(c)
		var name: String = loc.get(tag, file_names.get(tag, tag))
		var country := {"tag": tag, "name": name, "color": color, "capital": capital}
		country.merge(hist)
		countries.append(country)

	# tipos de governo (common/governments)
	var gov_pt: Dictionary = _json("res://data/governos_pt.json").get("governos", {})
	var governments := []
	for f in _list("common/governments/"):
		for g in _parse(_text(f)):
			if g[1] is Array:
				for kv in g[1]:
					if kv[0] == "reform_levels":
						governments.append({"id": g[0], "name": gov_pt.get(g[0], pretty_key(g[0]))})
						break

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
	var rel_group := {}
	var religions := _religions(religion.values(), loc, rel_group)
	var trade_goods := _trade_goods(goods.values(), loc)
	var node_of := {}
	var trade_nodes := _trade_nodes(loc, node_of)

	# ---- geografia (áreas, regiões, super-regiões, continentes) e estreitos
	_loc = loc
	var geo := _geography()
	var tech_groups := []
	var technologies := _technologies(buildings, tech_groups)
	var units := _units(technologies)
	var national_ideas := []
	var idea_groups := _ideas(countries, groups, rel_group, national_ideas)
	var advisors := []
	var advisor_types := _advisors(defs, advisors)
	var inst_raw := _institutions()
	var dip := _diplomacy()
	var wars := _wars()
	var tag_set := {}
	for c in countries:
		tag_set[c["tag"]] = true
	var diplomacy := []
	for r in dip[0]:
		if tag_set.has(r["first"]) and tag_set.has(r["second"]):
			diplomacy.append(r)
	var emperor: String = dip[1] if tag_set.has(dip[1]) else ""
	var celestial: String = dip[2] if tag_set.has(dip[2]) else ""
	var institutions := []
	for e in inst_raw:
		institutions.append(e[0])
	var country_of := {}
	for c in countries:
		country_of[c["tag"]] = c
	var adjacencies := []
	if _index.has("map/adjacencies.csv"):
		for line in _text("map/adjacencies.csv").split("\n"):
			var q := line.split(";")
			if q.size() >= 4 and q[0].is_valid_int() and q[1].is_valid_int() and int(q[0]) > 0 and int(q[1]) > 0:
				adjacencies.append({"from": int(q[0]), "to": int(q[1]), "type": q[2],
						"through": int(q[3]) if q[3].is_valid_int() else -1})

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
			if terrain_of.has(pid) and not climates.get(pid, {}).has("impassable"):
				prov["terrain"] = terrain_of[pid]
			else:
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
			if hre.has(pid):
				prov["hre"] = true
			var coastal := false
			for q in neigh[pid]:
				if sea.has(q):
					coastal = true
					break
			prov["coastal"] = coastal
		if node_of.has(pid):
			prov["trade_node"] = node_of[pid]
		for k in ["area", "region", "superregion", "continent"]:
			if geo[k + "_of"].has(pid):
				prov[k] = geo[k + "_of"][pid]
		if not is_sea and not inst_raw.is_empty():
			var pctx := prov.duplicate()
			pctx["culture_group"] = groups.get(prov.get("culture", ""), "")
			var owner_c: Variant = country_of.get(prov["owner"], null)
			var have := []
			for e in inst_raw:
				if e[1] == null:
					continue
				var ok := true
				for x in e[1]:
					if x[0] != "" and not _eval_province(x[0], x[1], pctx, owner_c):
						ok = false
						break
				if ok:
					have.append(e[0]["id"])
			if not have.is_empty():
				prov["institutions"] = have
		provinces.append(prov)
	var f := FileAccess.open(OUT_DIR + "/map.json", FileAccess.WRITE)
	if f == null:
		return "Não consegui gravar " + OUT_DIR + "/map.json"
	f.store_string(JSON.stringify({"width": w, "height": h, "countries": countries, "cultures": cultures,
			"religions": religions, "trade_goods": trade_goods, "trade_nodes": trade_nodes, "buildings": buildings,
			"terrains": terrains, "areas": geo["areas"], "regions": geo["regions"], "superregions": geo["superregions"],
			"continents": geo["continents"], "adjacencies": adjacencies, "governments": governments,
			"technologies": technologies, "tech_groups": tech_groups, "units": units,
			"idea_groups": idea_groups, "national_ideas": national_ideas,
			"advisor_types": advisor_types, "advisors": advisors,
			"institutions": institutions, "diplomacy": diplomacy, "emperor": emperor,
			"celestial_emperor": celestial, "wars": wars, "provinces": provinces}))
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
func _religions(used: Array, loc: Dictionary, rel_group: Dictionary) -> Array:
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
				rel_group[r[0]] = g[0]
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


## BMP de 8 bits (paleta) -> [largura, altura, índices de cima para baixo]; [] se não der.
func _bmp8(rel: String) -> Array:
	var b := _bytes(rel)
	if b.size() < 54 or b[0] != 0x42 or b[1] != 0x4D or b.decode_u16(28) != 8 or b.decode_u32(30) != 0:
		return []
	var off := b.decode_u32(10)
	var bw := b.decode_s32(18)
	var bh := b.decode_s32(22)
	var bottom_up := bh > 0
	bh = absi(bh)
	var row := ((bw * 8 + 31) / 32) * 4
	if off + row * bh > b.size():
		return []
	var data := PackedByteArray()
	for y in bh:
		var src := off + (bh - 1 - y if bottom_up else y) * row
		data.append_array(b.slice(src, src + bw))
	return [bw, bh, data]


## "ile_de_france_area" -> "Ile De France" (mesma regra do tools/import_eu4.py).
static func pretty_key(key: String, suffix := "") -> String:
	if suffix != "" and key.ends_with(suffix):
		key = key.left(-suffix.length())
	var words := []
	for wd in key.split("_", false):
		words.append(wd.left(1).to_upper() + wd.substr(1))
	return " ".join(words)


## Terreno do EU4: terrain_override do terrain.txt > árvores (trees.bmp, >= 30% da província) >
## terreno mais comum no terrain.bmp (sem contar água). Amostra a cada 2 px. Preenche `terrains`
## (rótulo em português, custo de movimento, defesa, limite de suprimento...) e retorna id -> rótulo.
func _eu4_terrain(ids: PackedByteArray, w: int, h: int, n_prov: int, terrains: Array) -> Dictionary:
	if not (_index.has("map/terrain.txt") and _index.has("map/terrain.bmp")):
		return {}
	_set_status("Lendo o terreno (terrain.bmp)...")
	var tb := _bmp8("map/terrain.bmp")
	if tb.is_empty() or tb[0] != w or tb[1] != h:
		return {}
	var pt: Dictionary = _json("res://data/geografia_pt.json").get("terrenos", {})
	var top := {}
	for kv in _parse(_text("map/terrain.txt")):
		if kv[0] != "" and not top.has(kv[0]):
			top[kv[0]] = kv[1]
	var override := {}
	var water := {}
	var seen := {}
	for c in top.get("categories", []):
		if not (c[1] is Array) or c[0] == "pti":
			continue
		var t := {"id": pt.get(c[0], c[0]), "eu4": c[0]}
		for kv in c[1]:
			if kv[0] in ["movement_cost", "defence", "supply_limit", "local_development_cost"] and str(kv[1]).is_valid_float():
				t[kv[0]] = float(kv[1])
			elif kv[0] == "is_water" and str(kv[1]) == "yes":
				water[c[0]] = true
			elif kv[0] == "terrain_override" and kv[1] is Array:
				for x in kv[1]:
					if x[0] == "" and str(x[1]).is_valid_int() and not override.has(int(x[1])):
						override[int(x[1])] = c[0]
		if not seen.has(t["id"]) and not water.has(c[0]):
			seen[t["id"]] = true
			terrains.append(t)
	var idx_type := {}
	for e in top.get("terrain", []):
		if e[1] is Array:
			var typ := ""
			for kv in e[1]:
				if kv[0] == "type":
					typ = str(kv[1])
			for kv in e[1]:
				if kv[0] == "color" and kv[1] is Array and typ != "":
					for x in kv[1]:
						if x[0] == "" and str(x[1]).is_valid_int():
							idx_type[int(x[1])] = typ
	var tree_type := {}
	for e in top.get("tree", []):
		if e[1] is Array:
			var typ := ""
			for kv in e[1]:
				if kv[0] == "terrain":
					typ = str(kv[1])
			if typ in ["forest", "woods", "jungle"]:
				for kv in e[1]:
					if kv[0] == "color" and kv[1] is Array:
						for x in kv[1]:
							if x[0] == "" and str(x[1]).is_valid_int():
								tree_type[int(x[1])] = typ
	# contagem por província (amostra a cada 2 px)
	var counts := PackedInt32Array()
	counts.resize(n_prov * 256)
	var total := PackedInt32Array()
	total.resize(n_prov)
	var tdata: PackedByteArray = tb[2]
	var tree_names: Array = tree_type.values()
	var tnames := {}
	for t in tree_names:
		tnames[t] = true
	var tree_list: Array = tnames.keys()
	tree_list.sort()
	var tree_cnt := []
	for t in tree_list:
		var a := PackedInt32Array()
		a.resize(n_prov)
		tree_cnt.append(a)
	var tv := PackedByteArray()
	var tw := 0
	var th := 0
	if _index.has("map/trees.bmp") and not tree_list.is_empty():
		var tr := _bmp8("map/trees.bmp")
		if not tr.is_empty():
			tw = tr[0]
			th = tr[1]
			tv = tr[2]
	var tree_slot := PackedInt32Array()      # índice do trees.bmp -> posição em tree_list (-1 = não é árvore)
	tree_slot.resize(256)
	tree_slot.fill(-1)
	for i in tree_type:
		tree_slot[i] = tree_list.find(tree_type[i])
	for y in range(0, h, 2):
		if y % 256 == 0:
			_set_status("Lendo o terreno (terrain.bmp)... %d%%" % (100 * y / h))
		var ty := y * th / h
		for x in range(0, w, 2):
			var i := y * w + x
			var q: int = ids[i * 3] | (ids[i * 3 + 1] << 8)
			counts[q * 256 + tdata[i]] += 1
			total[q] += 1
			if tw > 0:
				var s: int = tree_slot[tv[ty * tw + x * tw / w]]
				if s >= 0:
					tree_cnt[s][q] += 1
	var sorted_types: Array = []
	for i in idx_type:
		if not (idx_type[i] in sorted_types):
			sorted_types.append(idx_type[i])
	sorted_types.sort()
	var out := {}
	for pid in range(1, n_prov):
		var cat: String = override.get(pid, "")
		if cat == "" and tw > 0 and total[pid] > 0:
			var best := -1
			var best_f := -1.0
			for s in tree_list.size():
				var fr: float = float(tree_cnt[s][pid]) / total[pid]
				if fr > best_f:
					best_f = fr
					best = s
			if best >= 0 and best_f >= 0.3:
				cat = tree_list[best]
		if cat == "":
			var score := {}
			for i in idx_type:
				var c: int = counts[pid * 256 + i]
				if c > 0 and not water.has(idx_type[i]):
					score[idx_type[i]] = score.get(idx_type[i], 0) + c
			var best_s := 0
			for typ in sorted_types:
				if score.get(typ, 0) > best_s:
					best_s = score[typ]
					cat = typ
		if cat != "" and not water.has(cat):
			out[pid] = pt.get(cat, cat)
	return out


## Áreas, regiões, super-regiões e continentes (map/area.txt etc.).
func _geography() -> Dictionary:
	var pt := _json("res://data/geografia_pt.json")
	var g := {"areas": [], "regions": [], "superregions": [], "continents": [],
			"area_of": {}, "region_of": {}, "superregion_of": {}, "continent_of": {}}
	var region_of_area := {}
	var super_of_region := {}
	for e in _blocks("map/superregion.txt"):
		if e[0] == "new_world_superregion":
			continue
		g["superregions"].append({"id": e[0], "name": pt["superregioes"].get(e[0], pretty_key(e[0], "_superregion"))})
		for x in e[1]:
			if x[0] == "" and not super_of_region.has(x[1]):
				super_of_region[x[1]] = e[0]
	for e in _blocks("map/region.txt"):
		if e[0] == "random_new_world_region":
			continue
		g["regions"].append({"id": e[0], "name": pt["regioes"].get(e[0], _loc.get(e[0], pretty_key(e[0], "_region"))),
				"superregion": super_of_region.get(e[0], "")})
		for kv in e[1]:
			if kv[0] == "areas" and kv[1] is Array:
				for x in kv[1]:
					if x[0] == "" and not region_of_area.has(x[1]):
						region_of_area[x[1]] = e[0]
	for e in _blocks("map/area.txt"):
		var reg: String = region_of_area.get(e[0], "")
		var base := hashed_color(reg if reg != "" else e[0])
		var k := (e[0] as String).md5_buffer()
		var bc := Color8(base[0], base[1], base[2])
		var c2 := Color.from_hsv(fposmod(bc.h + (k[0] - 128) / 2600.0, 1.0),
				clampf(bc.s + (k[1] - 128) / 900.0, 0.3, 1.0), clampf(bc.v + (k[2] - 128) / 700.0, 0.4, 1.0))
		g["areas"].append({"id": e[0], "name": _loc.get(e[0], pretty_key(e[0], "_area")), "region": reg,
				"color": [int(c2.r * 255), int(c2.g * 255), int(c2.b * 255)]})
		for x in e[1]:
			if x[0] == "" and str(x[1]).is_valid_int():
				var pid := int(x[1])
				if not g["area_of"].has(pid):
					g["area_of"][pid] = e[0]
				if reg != "":
					if not g["region_of"].has(pid):
						g["region_of"][pid] = reg
					if super_of_region.get(reg, "") != "" and not g["superregion_of"].has(pid):
						g["superregion_of"][pid] = super_of_region[reg]
	for e in _blocks("map/continent.txt"):
		if e[0] in ["island_check_provinces", "new_world"]:
			continue
		g["continents"].append({"id": e[0], "name": pt["continentes"].get(e[0], pretty_key(e[0]))})
		for x in e[1]:
			if x[0] == "" and str(x[1]).is_valid_int() and not g["continent_of"].has(int(x[1])):
				g["continent_of"][int(x[1])] = e[0]
	return g


## Árvores adm/dip/mil (common/technologies) e grupos tecnológicos (common/technology.txt).
func _technologies(buildings: Array, groups: Array) -> Dictionary:
	var bids := {}
	for b in buildings:
		bids[b["id"]] = true
	var techs := {}
	for cat in ["adm", "dip", "mil"]:
		var rel := "common/technologies/%s.txt" % cat
		if not _index.has(rel):
			continue
		var lst := []
		for kv in _parse(_text(rel)):
			if kv[0] != "technology" or not (kv[1] is Array):
				continue
			var t := {"level": lst.size(), "year": 0, "modifiers": {}, "buildings": [], "unlocks": [], "units": [],
					"institutions": {}}
			var lk := "%s_tech_cs_%d_name" % [cat, lst.size()]
			if _loc.has(lk):
				t["name"] = _loc[lk]
			for x in kv[1]:
				var k: String = x[0]
				var v = x[1]
				if k == "":
					continue
				if k == "year" and str(v).is_valid_float():
					t["year"] = int(float(v))
				elif k == "expects_institution" and v is Array:
					for y in v:
						if y[0] != "" and str(y[1]).is_valid_float():
							t["institutions"][y[0]] = _int_if_whole(float(y[1]))
				elif k == "enable" and v is String:
					t["units"].append(v)
				elif v is String and v == "yes":
					t["buildings" if bids.has(k) else "unlocks"].append(k)
				elif k != "sprite_level" and v is String and (v as String).is_valid_float():
					t["modifiers"][k] = _int_if_whole(float(v))
			lst.append(t)
		techs[cat] = lst
	if _index.has("common/technology.txt"):
		for kv in _parse(_text("common/technology.txt")):
			if kv[0] == "groups" and kv[1] is Array:
				for g in kv[1]:
					if g[0] != "" and g[1] is Array:
						var d := {"id": g[0], "start_level": 0, "cost_modifier": 0}
						for x in g[1]:
							if x[0] == "start_level" and str(x[1]).is_valid_float():
								d["start_level"] = int(float(x[1]))
							elif x[0] == "start_cost_modifier" and str(x[1]).is_valid_float():
								d["cost_modifier"] = _int_if_whole(float(x[1]))
						groups.append(d)
	return techs


const TRIGGER_KEYS := {"tag": "tag", "primary_culture": "primary_culture", "culture_group": "culture_group",
		"religion": "religion", "religion_group": "religion_group", "technology_group": "tech_group",
		"government": "government"}
const FALSE_AT_START := ["is_revolutionary", "is_revolution_target", "is_federation_nation", "is_colonial_nation",
		"is_client_nation", "has_country_flag", "primitives"]


## Condição de trigger do EU4 (só as que dá para saber em 1444; o resto conta como falsa).
func _eval_cond(k: String, v: Variant, ctx: Dictionary) -> bool:
	if k == "":
		return true
	var kl := k.to_lower()
	if kl in ["or", "and", "not"]:
		if not (v is Array):
			return false
		var any := false
		var all := true
		for x in v:
			if x[0] == "":
				continue
			if _eval_cond(x[0], x[1], ctx):
				any = true
			else:
				all = false
		return any if kl == "or" else (all if kl == "and" else not any)
	if not (v is String):
		return false
	if kl == "always":
		return v == "yes"
	if TRIGGER_KEYS.has(kl):
		return str(ctx.get(TRIGGER_KEYS[kl], "")) == v
	if kl in FALSE_AT_START:
		return v == "no"        # nada disso é verdade em 1444
	return false


func _idea_mods(items: Array) -> Dictionary:
	var out := {}
	for kv in items:
		if kv[0] != "" and kv[1] is String:
			if (kv[1] as String).is_valid_float():
				out[kv[0]] = _int_if_whole(float(kv[1]))
			elif kv[1] == "yes":
				out[kv[0]] = true
	return out


## Grupos de ideias (com category) e ideias nacionais (free = yes). Cada país recebe em "ideas" o
## primeiro conjunto livre (na ordem dos arquivos) cujo trigger ele cumpre: nacional > de grupo > genérico.
func _ideas(countries: Array, culture_group_of: Dictionary, religion_group_of: Dictionary, national: Array) -> Array:
	var pt: Dictionary = _json("res://data/ideias_pt.json").get("grupos", {})
	var groups := []
	var free_sets := []
	for f in _list("common/ideas/"):
		for e in _parse(_text(f)):
			if e[0] == "" or not (e[1] is Array):
				continue
			var name: String = e[0]
			var st := {"id": name, "name": pt.get(name, _loc.get(name, pretty_key(name, "_ideas"))), "start": {},
					"bonus": {}, "ideas": []}
			var trigger = null
			var free := false
			# prefixo das ideias: "norse_ideas_x" e "fra_x" (FRA_ideas) viram "X"
			var prefix := name.to_lower() + "_"
			var full := false
			for kv in e[1]:
				if (kv[0] as String).to_lower().begins_with(prefix):
					full = true
					break
			if not full:
				prefix = name.to_lower().trim_suffix("_ideas") + "_"
			for kv in e[1]:
				var k: String = kv[0]
				if k == "category" and kv[1] is String:
					st["category"] = (kv[1] as String).to_lower()
				elif k in ["start", "bonus"] and kv[1] is Array:
					st[k] = _idea_mods(kv[1])
				elif k == "free":
					free = kv[1] is String and kv[1] == "yes"
				elif k == "trigger" and kv[1] is Array:
					trigger = kv[1]
				elif k != "" and not (k in ["ai_will_do", "important"]) and kv[1] is Array:
					st["ideas"].append({"id": k, "name": _loc.get(k,
							pretty_key(k.substr(prefix.length()) if k.to_lower().begins_with(prefix) else k)),
							"modifiers": _idea_mods(kv[1])})
			if free:
				free_sets.append([st, trigger])
			elif st.has("category"):
				if trigger != null:
					st["restricted"] = true     # exige governo/condição especial
				groups.append(st)
	var used := {}
	for c in countries:
		var ctx: Dictionary = c.duplicate()
		ctx["culture_group"] = culture_group_of.get(c.get("primary_culture", ""), "")
		ctx["religion_group"] = religion_group_of.get(c.get("religion", ""), "")
		for fs in free_sets:
			var ok := true
			if fs[1] != null:
				for x in fs[1]:
					if x[0] != "" and not _eval_cond(x[0], x[1], ctx):
						ok = false
						break
			if ok:
				c["ideas"] = fs[0]["id"]
				used[fs[0]["id"]] = true
				break
	for fs in free_sets:
		if used.has(fs[0]["id"]):
			national.append(fs[0])
	return groups


const COUNTRY_TRIGGERS := {"technology_group": "tech_group", "government": "government",
		"primary_culture": "primary_culture", "religion": "religion", "tag": "tag"}


## Condição de país (owner = { ... }) para o history das instituições.
func _eval_country(k: String, v: Variant, c: Dictionary) -> bool:
	if k == "":
		return true
	var kl := k.to_lower()
	if kl in ["or", "and", "not"]:
		if not (v is Array):
			return false
		var any := false
		var all := true
		for x in v:
			if x[0] == "":
				continue
			if _eval_country(x[0], x[1], c):
				any = true
			else:
				all = false
		return any if kl == "or" else (all if kl == "and" else not any)
	if not (v is String):
		return false
	if COUNTRY_TRIGGERS.has(kl):
		return str(c.get(COUNTRY_TRIGGERS[kl], "")) == v
	if kl == "has_reform":
		return v in c.get("reforms", [])
	if kl in FALSE_AT_START or kl == "is_playing_custom_nation":
		return v == "no"
	return false


## Condição de província (history das instituições). p = província (com culture_group), c = dono.
func _eval_province(k: String, v: Variant, p: Dictionary, c: Variant) -> bool:
	if k == "":
		return true
	var kl := k.to_lower()
	if kl in ["or", "and", "not"]:
		if not (v is Array):
			return false
		var any := false
		var all := true
		for x in v:
			if x[0] == "":
				continue
			if _eval_province(x[0], x[1], p, c):
				any = true
			else:
				all = false
		return any if kl == "or" else (all if kl == "and" else not any)
	if kl == "owner":
		if c == null or not (v is Array):
			return false
		for x in v:
			if x[0] != "" and not _eval_country(x[0], x[1], c):
				return false
		return true
	if not (v is String):
		return false
	if kl == "is_year":
		return (v as String).is_valid_int() and int(v) <= CUTOFF / 10000
	if kl in ["continent", "region", "superregion", "area", "culture", "culture_group", "religion", "trade_goods"]:
		return str(p.get(kl, "")) == v
	if kl == "province_id":
		return (v as String).is_valid_int() and int(v) == int(p["id"])
	return false


func _date_or(s: String, default: int) -> int:
	var p := s.split(".")
	while p.size() < 3:
		p.append("1")
	if not (p[0].is_valid_int() and p[1].is_valid_int() and p[2].is_valid_int()):
		return default
	return int(p[0]) * 10000 + int(p[1]) * 100 + int(p[2])


## Relações ativas na data (history/diplomacy) [{type, first, second, subject_type?}], imperador do
## Sacro Império e imperador celestial.
func _diplomacy() -> Array:
	var rel := []
	var emperor := ""
	var celestial := ""
	for f in _list("history/diplomacy/"):
		var dated := []
		for kv in _parse(_text(f)):
			if kv[0] == "" or not (kv[1] is Array):
				continue
			var dd := _date(kv[0])
			if dd >= 0:
				dated.append([dd, kv[1]])
				continue
			var d := {}
			for x in kv[1]:
				if x[0] != "" and x[1] is String:
					d[x[0]] = x[1]
			if d.has("first") and d.has("second") and _date_or(d.get("start_date", "1.1.1"), 99999999) <= CUTOFF \
					and CUTOFF < _date_or(d.get("end_date", "9999.1.1"), 99999999):
				var r := {"type": kv[0], "first": d["first"], "second": d["second"]}
				if d.has("subject_type"):
					r["subject_type"] = d["subject_type"]
				rel.append(r)
		dated.sort_custom(func(a, b): return a[0] < b[0])
		for e in dated:
			if e[0] <= CUTOFF:
				for x in e[1]:
					if x[0] == "emperor" and x[1] is String:
						emperor = "" if x[1] == "---" else x[1]
					elif x[0] == "celestial_emperor" and x[1] is String:
						celestial = "" if x[1] == "---" else x[1]
	return [rel, emperor, celestial]


const RECENT_WAR_YEARS := 10


func _dstr(d: int) -> String:
	return "%d.%d.%d" % [d / 10000, (d / 100) % 100, d % 100]


## Guerras ativas na data e as que acabaram nos últimos RECENT_WAR_YEARS anos (mesma regra do script Python).
func _wars() -> Array:
	var out := []
	var since := CUTOFF - RECENT_WAR_YEARS * 10000
	for f in _list("history/wars/"):
		var items := _parse(_text(f))
		var dated := []
		for kv in items:
			if kv[0] != "" and kv[1] is Array:
				var d := _date(kv[0])
				if d >= 0 and d <= CUTOFF:
					dated.append([d, kv[1]])
		if dated.is_empty():
			continue
		dated.sort_custom(func(a, b): return a[0] < b[0])
		var att := []
		var de := []
		var att_now := {}
		var de_now := {}
		var battles := []
		for e in dated:
			for x in e[1]:
				var k: String = x[0]
				var v = x[1]
				if k == "add_attacker" and v is String:
					att_now[v] = true
					if not (v in att):
						att.append(v)
				elif k == "add_defender" and v is String:
					de_now[v] = true
					if not (v in de):
						de.append(v)
				elif k == "rem_attacker" and v is String:
					att_now.erase(v)
				elif k == "rem_defender" and v is String:
					de_now.erase(v)
				elif k == "battle" and v is Array:
					var b := {"date": _dstr(e[0])}
					for bv in v:
						if bv[0] == "name" and bv[1] is String:
							b["name"] = bv[1]
						elif bv[0] == "location" and str(bv[1]).is_valid_int() and not str(bv[1]).begins_with("-"):
							b["location"] = int(bv[1])
						elif bv[0] == "result" and bv[1] is String:
							b["attacker_won"] = bv[1] == "yes"
						elif bv[0] in ["attacker", "defender"] and bv[1] is Array:
							var side := {}
							for y in bv[1]:
								if y[0] in ["country", "commander"] and y[1] is String:
									side[y[0]] = y[1]
								elif y[0] in ["infantry", "cavalry", "artillery", "losses"] and y[1] is String \
										and (y[1] as String).is_valid_int() and not (y[1] as String).begins_with("-"):
									side[y[0]] = int(y[1])
							b[bv[0]] = side
					battles.append(b)
		var active := not att_now.is_empty() and not de_now.is_empty()
		if not active and dated[dated.size() - 1][0] < since:
			continue
		var name := f.get_file()
		for kv in items:
			if kv[0] == "name" and kv[1] is String:
				name = kv[1]
				break
		var w := {"name": name, "start": _dstr(dated[0][0]), "end": "" if active else _dstr(dated[dated.size() - 1][0]),
				"attackers": att, "defenders": de, "battles": battles}
		if active:
			var a1 := att_now.keys()
			a1.sort()
			var d1 := de_now.keys()
			d1.sort()
			w["active"] = a1 + d1
		for kv in items:
			if kv[0] == "war_goal" and kv[1] is Array:
				var g := {}
				for y in kv[1]:
					if y[0] in ["type", "casus_belli"] and y[1] is String:
						g[y[0]] = y[1]
					elif y[0] == "province" and str(y[1]).is_valid_int() and not str(y[1]).begins_with("-"):
						g["province"] = int(y[1])
				if not g.is_empty():
					w["war_goal"] = g
				break
		out.append(w)
	return out


## Instituições [{id, name, color, bonus, start_date, start_province}, trigger history ou null].
func _institutions() -> Array:
	var pt := _json("res://data/instituicoes_pt.json")
	var out := []
	for f in _list("common/institutions/"):
		for e in _parse(_text(f)):
			if e[0] == "" or not (e[1] is Array):
				continue
			var inst := {"id": e[0], "name": pt.get("nomes", {}).get(e[0], pretty_key(e[0])),
					"color": pt.get("cores", {}).get(e[0], hashed_color(e[0])), "bonus": {}}
			var hist = null
			for kv in e[1]:
				if kv[0] == "bonus" and kv[1] is Array:
					inst["bonus"] = _idea_mods(kv[1])
				elif kv[0] == "historical_start_date" and kv[1] is String:
					inst["start_date"] = kv[1]
				elif kv[0] == "historical_start_province" and str(kv[1]).is_valid_int():
					inst["start_province"] = int(kv[1])
				elif kv[0] == "history" and kv[1] is Array:
					hist = kv[1]
			out.append([inst, hist])
	return out


## Tipos de conselheiro (categoria e efeitos) e conselheiros históricos (nome, província, nível, datas).
func _advisors(defs: Dictionary, advisors: Array) -> Array:
	var pt := _json("res://data/conselheiros_pt.json")
	var types := []
	var known := {}
	for f in _list("common/advisortypes/"):
		for e in _parse(_text(f)):
			if e[0] == "" or not (e[1] is Array):
				continue
			var cat := ""
			var rest := []
			for kv in e[1]:
				if kv[0] == "monarch_power" and kv[1] is String:
					cat = kv[1]
				elif kv[0] != "chance":
					rest.append(kv)
			if cat == "":
				continue
			types.append({"id": e[0], "name": pt.get(e[0], pretty_key(e[0])), "category": cat.to_lower(),
					"modifiers": _idea_mods(rest)})
			known[e[0]] = true
	for f in _list("history/advisors/"):
		for e in _parse(_text(f)):
			if e[0] != "advisor" or not (e[1] is Array):
				continue
			var a := {}
			for kv in e[1]:
				var k: String = kv[0]
				if k in ["name", "type", "date", "death_date"] and kv[1] is String:
					a[k] = kv[1]
				elif k in ["advisor_id", "location", "skill"] and kv[1] is String and (kv[1] as String).is_valid_int() \
						and not (kv[1] as String).begins_with("-"):
					a["id" if k == "advisor_id" else k] = int(kv[1])
				elif k == "female" and kv[1] is String and kv[1] == "yes":
					a["female"] = true
			if known.has(a.get("type", "")) and defs.has(a.get("location", -1)) and a.has("name"):
				advisors.append(a)
	return types


const UNIT_NUM_KEYS := ["maneuver", "offensive_morale", "defensive_morale", "offensive_fire", "defensive_fire",
		"offensive_shock", "defensive_shock", "hull_size", "base_cannons", "blockade", "sailors", "sail_speed",
		"trade_power"]


## Unidades (common/units/<id>.txt) com o nível e a árvore da tecnologia que as libera.
func _units(technologies: Dictionary) -> Array:
	var unlock := {}
	for cat in ["mil", "dip"]:
		for t in technologies.get(cat, []):
			for u in t["units"]:
				if not unlock.has(u):
					unlock[u] = [cat, t["level"]]
	var out := []
	for f in _list("common/units/"):
		var uid := f.get_file().get_basename()
		var u := {"id": uid, "name": _loc.get(uid, pretty_key(uid)), "type": ""}
		for kv in _parse(_text(f)):
			if kv[0] == "type" and kv[1] is String:
				u["type"] = kv[1]
			elif kv[0] == "unit_type" and kv[1] is String:
				u["unit_type"] = kv[1]
			elif kv[0] in UNIT_NUM_KEYS and str(kv[1]).is_valid_float():
				u[kv[0]] = _int_if_whole(float(kv[1]))
		if unlock.has(uid):
			u["tech"] = unlock[uid][0]
			u["level"] = unlock[uid][1]
		out.append(u)
	return out


## Blocos de topo [nome, itens] de um arquivo de script (vazio se o arquivo não existir).
func _blocks(rel: String) -> Array:
	var out := []
	if _index.has(rel):
		for kv in _parse(_text(rel)):
			if kv[0] != "" and kv[1] is Array:
				out.append(kv)
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
