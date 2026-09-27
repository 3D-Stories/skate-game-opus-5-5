// Skin for the Compatibility renderer: subsurface scattering is approximated with wrapped,
// red-shifted diffuse around the terminator plus a soft two-lobe specular (oily sheen +
// broad skin gloss). Albedo/normal/roughness come from the Blender-baked maps.
shader_type spatial;
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap;
uniform float normal_strength = 1.0;
uniform vec3 scatter_color : source_color = vec3(0.95, 0.32, 0.22);
uniform float wrap = 0.42;
uniform float scatter_amount = 0.55;
uniform float spec_strength = 0.55;
uniform float ambient_boost = 1.0;
// Character builder: skin under the worn clothes is not drawn. Each face carries the bits of
// the garments that cover it in its vertex colour (red: bits 0-7, green: 8-15, 1/255 steps);
// the faces whose bits meet hidden_mask collapse to a point (no raster, no shadow).
uniform int hidden_mask = 0;

varying float v_rough;

void vertex() {
	if (hidden_mask != 0) {
		int bits = int(round(COLOR.r * 255.0)) | (int(round(COLOR.g * 255.0)) << 8);
		if ((bits & hidden_mask) != 0) {
			VERTEX = vec3(0.0);
		}
	}
}

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb;
	ALBEDO = a;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	float r = texture(rough_tex, UV).g;
	ROUGHNESS = r;
	v_rough = r;
	SPECULAR = 0.35;
	// a little ambient translucency so shadowed skin is never grey
	EMISSION = a * scatter_color * 0.015 * ambient_boost;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float d = clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0);
	float lam = clamp(ndl, 0.0, 1.0);
	// scattered light bleeds past the terminator and saturates it red
	vec3 diffuse = mix(vec3(lam), vec3(d) * scatter_color, scatter_amount * (1.0 - lam));
	// shadows are softened by the scatter as well
	float shadow = mix(ATTENUATION, 1.0, 0.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * diffuse * shadow / PI;
	vec3 h = normalize(LIGHT + VIEW);
	float ndh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float rr = max(0.18, v_rough);
	float a2 = rr * rr * rr * rr;
	float dd = ndh * ndh * (a2 - 1.0) + 1.0;
	float ggx = a2 / (PI * dd * dd);
	float broad = pow(ndh, 18.0) * 0.25;
	float fres = 0.028 + 0.972 * pow(1.0 - clamp(dot(h, VIEW), 0.0, 1.0), 5.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * lam * (ggx * fres * 0.25 + broad * 0.06) * spec_strength;
}
