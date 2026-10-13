shader_type canvas_item;
// Pinta o mapa político a partir de:
//  - ids:     imagem com o id da província em R (byte baixo) e G (byte alto)
//  - palette: textura N x 3. Linha 0 = cor da província.
//             Linha 1 = R: índice do país dono (byte baixo; 0 = nenhum), G+B: índice da
//             cultura (byte baixo/alto, 0 = nenhuma), A: 1.0 se for mar.
//             Linha 2 = R: byte alto do índice do país dono (até 65535 países).
// Trocar o dono de uma província = mudar 3 pixels da paleta (sem loops em GDScript).

uniform sampler2D ids : filter_nearest, repeat_disable;
uniform sampler2D palette : filter_nearest, repeat_disable;
uniform vec2 map_size = vec2(2048.0, 2411.0);
uniform int selected_id = -1;
uniform int border_mode = 0;   // 0 = bordas fortes entre países, 1 = entre culturas

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
	} else if (owner_of(id, inf) != owner_of(nid, ninf)) {
		return 0.75;              // fronteira entre países
	}
	return 0.22;                  // divisa entre províncias do mesmo país
}

void fragment() {
	ivec2 p = ivec2(UV * map_size);
	int id = id_at(p);
	vec4 inf = info_of(id);
	vec3 c = color_of(id).rgb;
	if (id == selected_id) {
		c = mix(c, vec3(1.0), 0.4);
	}
	float e = max(edge_to(id, inf, p + ivec2(1, 0)), edge_to(id, inf, p + ivec2(0, 1)));
	c = mix(c, vec3(0.04), e);
	COLOR = vec4(c, 1.0);
}
