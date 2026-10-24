class_name Eu4Data
extends RefCounted
## Todos os scripts do EU4, como os importadores gravaram em eu4data/ ao lado do map.json (ver
## `Eu4Importer._all_data` e `tools/import_eu4.py` eu4_all_data), para os sistemas do jogo usarem as
## regras originais. Cada pasta é lida só quando alguém pede (e fica em cache):
##  - `folder("common/estates")` = {arquivo sem .txt: árvore}; árvore = [[chave, valor], ...] com
##    valor = texto ou árvore (chave "" para itens soltos), como em `map.diplomacy_data`.
##  - `merged("common/estates")` = {chave do topo: valor} juntando os arquivos em ordem (a primeira
##    definição vale).
##  - Pastas: common/<x> (todas as do EU4; os .txt soltos em common/_files), history/<x>, events,
##    decisions, missions (se a instalação tem), map (os .txt/.map da pasta map: positions,
##    trade_winds, seasons, ambient_object, provincegroup...).
##  - `define("NMilitary", "INFANTRY_COST", 10)`: constantes de todos os blocos do defines.lua;
##    `defines()["overrides"]` = as sobrescritas de common/defines/*.lua (dificuldades).
##  - `folders()` = pasta -> número de arquivos.
## Sem o EU4 importado, tudo vem vazio (`available()` falso).

static var base := ""             # pasta eu4data (MapView define ao carregar o mapa)
static var _cache := {}
static var _merged := {}


static func set_base(map_dir: String) -> void:
	base = map_dir + "/eu4data"
	_cache.clear()
	_merged.clear()


static func available() -> bool:
	return base != "" and FileAccess.file_exists(base + "/index.json")


static func _load(name: String) -> Variant:
	if _cache.has(name):
		return _cache[name]
	var v: Variant = {}
	if base != "" and FileAccess.file_exists(base + "/" + name + ".json"):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + "/" + name + ".json"))
		if parsed is Dictionary:
			v = parsed
	_cache[name] = v
	return v


## Pasta -> número de arquivos.
static func folders() -> Dictionary:
	return _load("index")


static func folder(path: String) -> Dictionary:
	return _load(path)


static func merged(path: String) -> Dictionary:
	if _merged.has(path):
		return _merged[path]
	var out := {}
	var files := folder(path)
	var names := files.keys()
	names.sort()
	for n in names:
		for kv in files[n]:
			if kv[0] != "" and not out.has(kv[0]):
				out[kv[0]] = kv[1]
	_merged[path] = out
	return out


static func defines() -> Dictionary:
	return _load("defines")


static func define(block: String, key: String, default: Variant = null) -> Variant:
	return defines().get(block, {}).get(key, default)


## Libera a memória das pastas lidas.
static func clear_cache() -> void:
	_cache.clear()
	_merged.clear()
