// Hair cards: alpha-to-coverage (works with MSAA in WebGL2), double sided, Kajiya-Kay
// anisotropic highlights along the strand direction (card V = binormal).
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float alpha_cut = 0.35;
uniform vec3 spec_color : source_color = vec3(0.62, 0.5, 0.4);
uniform float spec_shift = 0.08;
uniform float spec_power = 70.0;
uniform float spec_strength = 0.3;

varying vec3 v_strand;

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	ALPHA_ANTIALIASING_EDGE = 0.3;
	ROUGHNESS = 0.55;
	v_strand = BINORMAL;
	SPECULAR = 0.3;
	// flip the normal on back faces so both sides light the same
	if (!FRONT_FACING) { NORMAL = -NORMAL; }
	// root occlusion: darker toward the scalp
	AO = mix(0.45, 1.0, UV.y);
	AO_LIGHT_AFFECT = 0.4;
}

void light() {
	vec3 t = normalize(v_strand + NORMAL * spec_shift);
	vec3 h = normalize(LIGHT + VIEW);
	float th = dot(t, h);
	float s = sqrt(max(0.0, 1.0 - th * th));
	float kk = pow(s, spec_power);
	float ndl = clamp(dot(NORMAL, LIGHT) * 0.7 + 0.3, 0.0, 1.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * ndl / PI;
	SPECULAR_LIGHT += LIGHT_COLOR / PI * ATTENUATION * spec_color * kk * spec_strength * ndl;
}
