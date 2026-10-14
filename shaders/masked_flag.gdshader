shader_type canvas_item;
// Bandeira recortada pela máscara do escudo do EU4 (alfa da máscara).
uniform sampler2D mask : filter_linear;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	COLOR = vec4(c.rgb, c.a * texture(mask, UV).a);
}
