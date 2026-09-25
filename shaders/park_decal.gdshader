// Graffiti decals: the park surface shader with the atlas alpha as coverage (paint over the
// wall 1.5 cm behind), lit by the same baked lightmap on UV2 plus the real-time sun.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D lightmap_tex : hint_default_black, filter_linear, repeat_disable;
uniform float lightmap_scale = 6.0;
uniform float lightmap_energy = 1.0;
uniform float roughness = 0.72;
uniform float ambient_keep = 0.2;

void fragment() {
	vec4 a = texture(albedo_tex, UV);
	ALBEDO = a.rgb;
	ALPHA = a.a;
	ROUGHNESS = roughness;
	vec3 lm = pow(texture(lightmap_tex, UV2).rgb, vec3(2.2)) * lightmap_scale;
	EMISSION = a.rgb * lm * lightmap_energy;
	AO = ambient_keep;
	AO_LIGHT_AFFECT = 0.0;
}
