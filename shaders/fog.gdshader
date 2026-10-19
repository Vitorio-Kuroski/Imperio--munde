shader_type canvas_item;
render_mode blend_premul_alpha;
// Terra Incógnita e névoa de guerra por cima do mapa (FogLayer), como no EU4 (gfx/FX/standardfuncsgfx.fxh):
//  - GetTIColor: a textura map_overlay_tile.dds repetida a cada 1876×2048 px do mapa; cor final =
//    lerp(cor, TI, TI).
//  - GetFoW: ruído Fogofwar.dds a cada 256 px andando com o tempo, sombra = sin((ruído +
//    frac(t × 0,1)) × 2π) × 0,1 + 0,5; cor × saturate(visível + sombra).
// Saída em alfa pré-multiplicado: final = TI × ti + mapa × névoa × (1 − ti).

uniform sampler2D fow_map : filter_linear, repeat_disable;   // R = Terra Incógnita, G = visível (fog_bake)
uniform sampler2D ti_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_ti = false;
uniform sampler2D fow_noise : filter_linear_mipmap, repeat_enable;
uniform bool has_noise = false;
uniform vec2 map_size = vec2(5632.0, 2048.0);
const vec2 TI_TILE = vec2(1876.0, 2048.0);
const vec3 TI_FALLBACK = vec3(0.37, 0.35, 0.32);

void fragment() {
	vec2 v = texture(fow_map, UV).rg;
	float ti = v.r > 0.99 ? 1.0 : v.r;
	vec3 tic = has_ti ? texture(ti_tex, UV * map_size / TI_TILE).rgb : TI_FALLBACK;
	vec2 pos = UV * map_size;
	float n = has_noise ? texture(fow_noise, pos / 256.0 + TIME * 0.02).r : 0.5;
	float shade = sin((n + fract(TIME * 0.1)) * 6.28318531) * 0.1 + 0.5;
	float fow = clamp(v.g + shade, 0.0, 1.0);
	COLOR = vec4(tic * ti, 1.0 - fow * (1.0 - ti));
}
