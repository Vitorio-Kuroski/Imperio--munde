shader_type canvas_item;
// Pinta o mapa político a partir de:
//  - ids:     imagem com o id da província em R (byte baixo) e G (byte alto)
//  - palette: textura N x 5. Linha 0 = cor da província.
//             Linha 1 = R: índice do país dono (byte baixo; 0 = nenhum), G+B: índice da
//             cultura (byte baixo/alto, 0 = nenhuma), A: 1.0 se for mar.
//             Linha 2 = R: byte alto do índice do país dono (até 65535 países),
//             G+B: índice da religião (byte baixo/alto, 0 = nenhuma).
//             Linha 3 = R+G: índice do produto, B+A: índice do nó de comércio (byte baixo/alto, 0 = nenhum).
//             Linha 4 = R+G: índice da área, B+A: índice da região.
//  - rivers:  índice da paleta do rivers.bmp do EU4 (< 254 = rio), opcional.
//  - texturas do mapa do EU4 (opcionais, ver MapView._load_map_textures): normal_map (world_normal.bmp,
//    metade da resolução) ilumina o relevo com a luz do EU4 (light_dir); height_map (heightmap.bmp)
//    escurece o mar fundo; terrain_idx + terrain_pal (terrain.bmp) ou colormap pintam o modo terreno
//    (terrain_view); water_colormap pinta o mar.
// Trocar o dono de uma província = mudar 5 pixels da paleta (sem loops em GDScript).

uniform sampler2D ids : filter_nearest, repeat_disable;
uniform sampler2D palette : filter_nearest, repeat_disable;
uniform sampler2D rivers : filter_nearest, repeat_disable;
uniform bool has_rivers = false;
const vec3 RIVER_COLOR = vec3(0.20, 0.40, 0.72);
uniform vec2 map_size = vec2(2048.0, 2411.0);
uniform int selected_id = -1;
uniform sampler2D normal_map : filter_linear, repeat_disable;
uniform bool has_normal = false;
uniform sampler2D height_map : filter_linear, repeat_disable;
uniform bool has_height = false;
uniform sampler2D terrain_idx : filter_nearest, repeat_disable;
uniform sampler2D terrain_pal : filter_nearest, repeat_disable;
uniform sampler2D colormap : filter_linear, repeat_disable;
uniform bool has_colormap = false;
uniform sampler2D water_colormap : filter_linear, repeat_disable;
uniform bool has_water_colormap = false;
uniform bool terrain_view = false;
uniform vec3 light_dir = vec3(0.67, 0.33, 0.67);
const float SEA_LEVEL = 95.0 / 255.0;      // nível do mar no heightmap.bmp do EU4
uniform int border_mode = 0;   // bordas fortes entre: 0 = países, 1 = culturas, 2 = religiões, 3 = produtos, 4 = nós de comércio,
                               // 5 = regiões (e bordas médias entre áreas)

int id_at(ivec2 p) {
	ivec2 s = ivec2(map_size);
	p = clamp(p, ivec2(0), s - ivec2(1));
	vec4 c = texelFetch(ids, p, 0);
	return int(c.r * 255.0 + 0.5) + int(c.g * 255.0 + 0.5) * 256;
}

vec4 color_of(int id) {
	return texelFetch(palette, ivec2(id, 0), 0);
}

vec4 info_of(int id) {
	return texelFetch(palette, ivec2(id, 1), 0);
}

int owner_of(int id, vec4 inf) {
	return int(inf.r * 255.0 + 0.5) + int(texelFetch(palette, ivec2(id, 2), 0).r * 255.0 + 0.5) * 256;
}

int religion_of(int id) {
	vec4 r = texelFetch(palette, ivec2(id, 2), 0);
	return int(r.g * 255.0 + 0.5) + int(r.b * 255.0 + 0.5) * 256;
}

ivec2 area_region_of(int id) {
	vec4 g = texelFetch(palette, ivec2(id, 4), 0);
	return ivec2(int(g.r * 255.0 + 0.5) + int(g.g * 255.0 + 0.5) * 256,
			int(g.b * 255.0 + 0.5) + int(g.a * 255.0 + 0.5) * 256);
}

int node_of(int id) {
	vec4 g = texelFetch(palette, ivec2(id, 3), 0);
	return int(g.b * 255.0 + 0.5) + int(g.a * 255.0 + 0.5) * 256;
}

int good_of(int id) {
	vec4 g = texelFetch(palette, ivec2(id, 3), 0);
	return int(g.r * 255.0 + 0.5) + int(g.g * 255.0 + 0.5) * 256;
}

int culture_of(vec4 inf) {
	return int(inf.g * 255.0 + 0.5) + int(inf.b * 255.0 + 0.5) * 256;
}

float edge_to(int id, vec4 inf, ivec2 p) {
	int nid = id_at(p);
	if (nid == id) {
		return 0.0;
	}
	vec4 ninf = info_of(nid);
	bool sea = inf.a > 0.5;
	bool nsea = ninf.a > 0.5;
	if (sea && nsea) {
		return 0.0;               // sem borda entre mares
	}
	if (sea != nsea) {
		return 0.75;              // costa
	}
	if (border_mode == 1) {
		if (culture_of(inf) != culture_of(ninf)) {
			return 0.75;          // fronteira entre culturas
		}
	} else if (border_mode == 2) {
		if (religion_of(id) != religion_of(nid)) {
			return 0.75;          // fronteira entre religiões
		}
	} else if (border_mode == 3) {
		if (good_of(id) != good_of(nid)) {
			return 0.75;          // fronteira entre produtos
		}
	} else if (border_mode == 4) {
		if (node_of(id) != node_of(nid)) {
			return 0.75;          // fronteira entre nós de comércio
		}
	} else if (border_mode == 5) {
		ivec2 a = area_region_of(id);
		ivec2 b = area_region_of(nid);
		if (a.y != b.y) {
			return 0.75;          // fronteira entre regiões
		}
		if (a.x != b.x) {
			return 0.45;          // divisa entre áreas
		}
	} else if (owner_of(id, inf) != owner_of(nid, ninf)) {
		return 0.75;              // fronteira entre países
	}
	return 0.22;                  // divisa entre províncias do mesmo país
}

vec3 terrain_pal_at(ivec2 p) {
	p = clamp(p, ivec2(0), textureSize(terrain_idx, 0) - ivec2(1));
	int ti = int(texelFetch(terrain_idx, p, 0).r * 255.0 + 0.5);
	return texelFetch(terrain_pal, ivec2(ti, 0), 0).rgb;
}

// cor do terrain.bmp suavizada: as cores (não os índices) dos 4 pixels vizinhos misturadas
vec3 terrain_color(vec2 uv) {
	vec2 ts = vec2(textureSize(terrain_idx, 0));
	vec2 f = uv * ts - 0.5;
	ivec2 i = ivec2(floor(f));
	vec2 w = fract(f);
	vec3 c00 = terrain_pal_at(i);
	vec3 c10 = terrain_pal_at(i + ivec2(1, 0));
	vec3 c01 = terrain_pal_at(i + ivec2(0, 1));
	vec3 c11 = terrain_pal_at(i + ivec2(1, 1));
	return mix(mix(c00, c10, w.x), mix(c01, c11, w.x), w.y);
}

void fragment() {
	ivec2 p = ivec2(UV * map_size);
	int id = id_at(p);
	vec4 inf = info_of(id);
	vec3 c = color_of(id).rgb;
	bool sea = inf.a > 0.5;
	if (sea) {
		if (has_water_colormap) {
			c = texture(water_colormap, UV).rgb;
		}
		if (has_height) {            // mar fundo mais escuro, raso mais claro
			float d = clamp((SEA_LEVEL - texture(height_map, UV).r) / SEA_LEVEL, 0.0, 1.0);
			c *= mix(1.18, 0.62, sqrt(d));
		}
	} else if (terrain_view) {
		if (has_colormap) {
			c = texture(colormap, UV).rgb;
		} else {
			c = terrain_color(UV);
		}
	}
	if (has_normal) {                // relevo iluminado pela luz do EU4
		vec3 n = texture(normal_map, UV).rgb * 2.0 - 1.0;
		n = normalize(vec3(n.x, -n.y, n.z));
		float l = dot(n, normalize(light_dir));
		float flat_l = normalize(light_dir).z;
		c *= clamp(1.0 + (l - flat_l) * (sea ? 0.6 : 1.6), 0.45, 1.45);
	}
	if (id == selected_id) {
		c = mix(c, vec3(1.0), 0.4);
	}
	float e = max(edge_to(id, inf, p + ivec2(1, 0)), edge_to(id, inf, p + ivec2(0, 1)));
	if (has_rivers && inf.a < 0.5) {
		float r = texelFetch(rivers, clamp(p, ivec2(0), ivec2(map_size) - ivec2(1)), 0).r * 255.0;
		if (r < 253.5) {
			c = mix(c, RIVER_COLOR, 0.85);
		}
	}
	c = mix(c, vec3(0.04), e);
	COLOR = vec4(c, 1.0);
}
