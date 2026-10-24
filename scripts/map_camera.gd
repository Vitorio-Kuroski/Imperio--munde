class_name MapCamera
extends Camera2D
## Câmera do mapa com o zoom do EU4:
##  - A câmera tem uma altura entre CAMERA_MIN_HEIGHT (50) e CAMERA_MAX_HEIGHT (3000) do
##    defines.lua do EU4 (bloco NFrontend; sem os dados, os mesmos valores); na altura h a tela mostra
##    h × VIEW_PER_HEIGHT px do mapa na vertical (o campo de visão do EU4: na altura máxima cabe o
##    mapa inteiro de 2048 px; mapas mais altos aumentam o máximo para caberem).
##  - Mais perto que MAX_PIXEL_ZOOM (8 pontos da tela por pixel do mapa) a imagem das províncias vira
##    blocos (o EU4 desenha o relevo em 3D; aqui o mapa é a imagem de pixels), então a altura mínima
##    é a maior entre CAMERA_MIN_HEIGHT e a que dá esse zoom (`min_h`).
##  - Roda do mouse: aproxima/afasta em direção ao ponteiro (o ponto do mapa sob o mouse fica
##    parado), com animação suave; cada passo multiplica a altura por WHEEL_STEP.
##  - Pinça (celular): em direção ao meio dos dedos, sem animação.
##  - Botões de zoom do minimapa: em direção ao centro da tela, suave.
##  - `focus(ponto, fração)`: centraliza num ponto com a altura = fração da máxima
##    (PROVINCE_FOCUS_ZOOM_HEIGHT 0,25 do EU4 = início do jogo na capital).
##  - A posição fica sempre dentro do mapa (`clamp_to_map`).

const VIEW_PER_HEIGHT := 0.7
const WHEEL_STEP := 1.25
const SMOOTH := 14.0              # velocidade da animação (1/s)
const MAX_PIXEL_ZOOM := 8.0

var min_height := 50.0
var max_height := 3000.0
var height := 3000.0
var target_height := 3000.0
var map_size := Vector2.ZERO
var _anchor := Vector2.ZERO       # ponto da tela que fica parado durante o zoom


func setup(size: Vector2) -> void:
	map_size = size
	min_height = float(Eu4Data.define("NFrontend", "CAMERA_MIN_HEIGHT", 50.0))
	max_height = maxf(float(Eu4Data.define("NFrontend", "CAMERA_MAX_HEIGHT", 3000.0)), size.y / VIEW_PER_HEIGHT)
	position = size * 0.5
	set_height(max_height)


## Pontos da tela <-> mapa (sem rotação, âncora no centro).
func screen_to_world(p: Vector2) -> Vector2:
	return position + (p - get_viewport_rect().size * 0.5) / zoom.x


func _zoom_for(h: float) -> float:
	return get_viewport_rect().size.y / (h * VIEW_PER_HEIGHT)


## Altura mínima de verdade (ver MAX_PIXEL_ZOOM).
func min_h() -> float:
	return minf(max_height, maxf(min_height, get_viewport_rect().size.y / (MAX_PIXEL_ZOOM * VIEW_PER_HEIGHT)))


func set_height(h: float) -> void:
	height = clampf(h, min_h(), max_height)
	target_height = height
	zoom = Vector2.ONE * _zoom_for(height)
	clamp_to_map()


## Aproxima (`factor` > 1) ou afasta mantendo parado o ponto `screen_point` da tela.
func zoom_by(factor: float, screen_point: Vector2, smooth := true) -> void:
	_anchor = screen_point
	target_height = clampf(target_height / factor, min_h(), max_height)
	if not smooth:
		_apply(target_height)


## Fator de um passo da roda (`factor` do evento: 0 = um passo inteiro; touchpads mandam frações).
static func wheel_factor(event_factor: float) -> float:
	return pow(WHEEL_STEP, event_factor) if event_factor > 0.0 else WHEEL_STEP


func zoom_center(factor: float) -> void:
	zoom_by(factor, get_viewport_rect().size * 0.5)


func focus(point: Vector2, height_fraction: float) -> void:
	position = point
	set_height(max_height * height_fraction)


func _apply(h: float) -> void:
	var before := screen_to_world(_anchor)
	height = h
	zoom = Vector2.ONE * _zoom_for(height)
	position += before - screen_to_world(_anchor)
	clamp_to_map()


func clamp_to_map() -> void:
	if map_size != Vector2.ZERO:
		position = position.clamp(Vector2.ZERO, map_size)


func _process(delta: float) -> void:
	if absf(height - target_height) > 0.01:
		var h := lerpf(height, target_height, 1.0 - exp(-SMOOTH * delta))
		if absf(h - target_height) < 0.5:
			h = target_height
		_apply(h)
	elif absf(zoom.x - _zoom_for(height)) > 0.0001:
		zoom = Vector2.ONE * _zoom_for(height)          # a janela mudou de tamanho
