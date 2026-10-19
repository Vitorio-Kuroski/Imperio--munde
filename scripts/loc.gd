class_name Loc
extends RefCounted
## Localização original do EU4 (localisation/*_l_english.yml), que os importadores gravam em
## loc.txt ao lado do map.json ("chave<TAB>texto" por linha). Com ela, nomes e textos das telas
## ficam como no jogo original; sem ela (mapa padrão), valem os textos em português do projeto.
##  - t("CV_INCOMES", "Receitas") -> "Income" (sem os códigos de cor §Y…§! e ícones £gold£)
##  - f("CV_BALANCE", {"VAL": "+6,07"}) troca $VAL$ (também aceita $VAL|Y$ etc.)
##  - modifier("tolerance_own") -> "Tolerance of the True Faith"

static var table := {}
static var dec := ","                  # separador decimal: "." com a localização do EU4 (inglês)
static var _color := RegEx.create_from_string("§[A-Za-z!]")
static var _icon := RegEx.create_from_string("£[^£ ]*£?")


static func load_file(path: String) -> void:
	table = {}
	dec = ","
	if not FileAccess.file_exists(path):
		return
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var i := line.find("\t")
		if i > 0:
			table[line.substr(0, i)] = line.substr(i + 1)
	dec = "." if active() else ","


static func active() -> bool:
	return not table.is_empty()


static func has(key: String) -> bool:
	return table.has(key)


static func clean(s: String) -> String:
	s = _color.sub(s, "", true)
	s = _icon.sub(s, "", true)
	return s.replace("\\n", "\n").strip_edges()


## Texto da chave (limpo) ou `fallback` (o próprio texto em português quando não há localização).
static func t(key: String, fallback := "") -> String:
	if table.has(key):
		return clean(table[key])
	return fallback


## Texto com variáveis $NOME$ trocadas.
static func f(key: String, vars: Dictionary, fallback := "") -> String:
	var s := t(key, "")
	if s == "":
		s = fallback
	for k in vars:
		s = s.replace("$%s$" % k, str(vars[k]))
		var re := RegEx.create_from_string("\\$%s\\|[^$]*\\$" % k)
		s = re.sub(s, str(vars[k]), true)
	return s


## Inteiro com separador de milhar como no EU4 ("7,371"; em português "7.371").
static func num(v: float) -> String:
	var n := roundi(v)
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = ("," if dec == "." else ".") + s.right(3) + out
		s = s.left(-3)
	return ("-" if n < 0 else "") + s + out


## Nome de um efeito (modificador) do EU4.
static func modifier(key: String, fallback := "") -> String:
	for k in ["MODIFIER_" + key.to_upper(), key, key.to_upper()]:
		if table.has(k):
			return clean(table[k])
	return fallback


## Texto fixo de uma tela: vazio se a chave não existe ou se o texto depende de variáveis ($VAL$, [Root...]).
static func plain(key: String, fallback := "") -> String:
	var s := t(key, fallback)
	return "" if s.contains("$") or s.contains("[") else s


## Texto do jogo sem chave no EU4: o inglês com a localização importada, senão o português.
static func s(pt: String, en: String) -> String:
	return en if active() else pt


const MONTHS := ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
		"November", "December"]


## Data como no EU4 ("11 November 1444") com a localização; senão "11/11/1444".
static func date(y: int, m: int, d: int) -> String:
	if active() and m >= 1 and m <= 12:
		return "%d %s %d" % [d, t(MONTHS[m - 1], MONTHS[m - 1]), y]
	return "%d/%d/%d" % [d, m, y]
