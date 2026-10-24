shader_type canvas_item;
// Assa a Terra Incógnita e a névoa do jogador numa textura de 1/4 do mapa (FogLayer), como a FoWTexture
// do EU4 (baixa resolução, filtrada: bordas suaves). R = Terra Incógnita (1 = desconhecida),
// G = visível (1 = fora da névoa). Cada pixel é a média de 4 pontos do province_ids.

uniform sampler2D ids : filter_nearest, repeat_disable;
uniform sampler2D view : filter_nearest, repeat_disable;   // N×1 (Discovery.view_image)
uniform vec2 map_size = vec2(5632.0, 2048.0);
uniform vec2 cell = vec2(4.0, 4.0);                      // px do mapa por pixel da textura

vec2 view_at(vec2 px) {
	ivec2 p = clamp(ivec2(px), ivec2(0), ivec2(map_size) - ivec2(1));
	vec4 c = texelFetch(ids, p, 0);
	int id = int(c.r * 255.0 + 0.5) + int(c.g * 255.0 + 0.5) * 256;
	return texelFetch(view, ivec2(id, 0), 0).rg;
}

void fragment() {
	vec2 px = UV * map_size;
	vec2 q = cell * 0.25;
	vec2 v = (view_at(px + vec2(-q.x, -q.y)) + view_at(px + vec2(q.x, -q.y))
			+ view_at(px + vec2(-q.x, q.y)) + view_at(px + vec2(q.x, q.y))) * 0.25;
	COLOR = vec4(v, 0.0, 1.0);
}
