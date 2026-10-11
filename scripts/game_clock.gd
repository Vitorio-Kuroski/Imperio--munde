class_name GameClock
extends RefCounted
## Relógio do jogo: data, pausa e velocidades (estilo EU4, 1 a 5).

signal day_passed
signal month_passed
signal year_passed
signal changed   # data, pausa ou velocidade mudaram

const DAYS_IN_MONTH := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const MONTHS := ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
## Segundos reais por dia de jogo, para cada velocidade
const SECONDS_PER_DAY := [1.0, 0.5, 0.25, 0.1, 0.03]

var year := 1444
var month := 11   # 1..12
var day := 11
var speed := 2    # 1..5
var paused := true
var _acc := 0.0


func process(delta: float) -> void:
	if paused:
		return
	_acc += delta
	var step: float = SECONDS_PER_DAY[speed - 1]
	var guard := 0
	while _acc >= step and guard < 10:
		_acc -= step
		guard += 1
		_advance_day()


func _advance_day() -> void:
	day += 1
	day_passed.emit()
	if day > DAYS_IN_MONTH[month - 1]:
		day = 1
		month += 1
		if month > 12:
			month = 1
			year += 1
			year_passed.emit()
		month_passed.emit()
	changed.emit()


func toggle_pause() -> void:
	paused = not paused
	changed.emit()


func set_speed(s: int) -> void:
	speed = clampi(s, 1, 5)
	changed.emit()


func date_text() -> String:
	return "%d %s %d" % [day, MONTHS[month - 1], year]
