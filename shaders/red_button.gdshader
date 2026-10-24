shader_type canvas_item;

// Botão "Declare War" da aba Diplomacia do EU4: o list_button azul pintado de vermelho (o EU4 não
// tem sprite vermelho para ele). Só os pixels azulados mudam; a moldura dourada fica.
void fragment() {
	vec4 c = COLOR;
	float blue = clamp((c.b - c.r) * 4.0, 0.0, 1.0);
	float l = dot(c.rgb, vec3(0.3, 0.59, 0.11));
	COLOR = vec4(mix(c.rgb, l * vec3(2.1, 0.62, 0.6), blue), c.a);
}
