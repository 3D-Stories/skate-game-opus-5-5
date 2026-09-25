// Warehouse surfaces: tiling PBR maps on UV + the Blender-baked lightmap on UV2.
// The lightmap holds every light except the sun's direct light (lamps, skylight/sky
// light, window light, bounce); the real-time DirectionalLight adds the sun with shadows.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D lightmap_tex : hint_default_black, filter_linear, repeat_disable;
uniform float lightmap_scale = 6.0;
uniform float lightmap_energy = 1.0;
uniform float metallic = 0.0;
uniform float normal_depth = 1.0;
uniform float rough_mult = 1.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform bool use_lightmap = true;
uniform float ambient_keep = 0.2;

void fragment() {
	vec4 a = texture(albedo_tex, UV);
	vec3 alb = a.rgb * tint;
	ALBEDO = alb;
	ROUGHNESS = clamp(a.a * rough_mult, 0.04, 1.0);
	METALLIC = metallic;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	if (use_lightmap) {
		vec3 lm = pow(texture(lightmap_tex, UV2).rgb, vec3(2.2)) * lightmap_scale;
		EMISSION = alb * lm * lightmap_energy;
		AO = ambient_keep;
		AO_LIGHT_AFFECT = 0.0;
	}
}
