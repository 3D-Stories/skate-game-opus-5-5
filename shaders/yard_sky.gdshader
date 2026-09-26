// The daylight outside the east windows, on the yard shell Blender builds past the wall
// (unlit; kept out of the lightmap bake). Each view ray is followed out past the shell to
// a few virtual layers at their real distances east of the hall, so they move with the
// right parallax: utility poles and wires, a line of trees, the rooflines of the next
// blocks, then an overcast-bright sky with clouds on a plane 400 m up. The yard's gravel
// in front of them, for views down out of the windows from the rafters.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform vec3 horizon_col : source_color = vec3(0.84, 0.87, 0.90);
uniform vec3 zenith_col : source_color = vec3(0.47, 0.60, 0.80);
uniform vec3 cloud_col : source_color = vec3(0.97, 0.97, 0.96);
uniform vec3 cloud_shade : source_color = vec3(0.70, 0.73, 0.78);
uniform vec3 roof_col : source_color = vec3(0.36, 0.38, 0.42);
uniform vec3 tree_col : source_color = vec3(0.13, 0.17, 0.12);
uniform vec3 pole_col : source_color = vec3(0.12, 0.11, 0.10);
uniform vec3 gravel_col : source_color = vec3(0.40, 0.38, 0.34);
uniform float energy = 1.2;
uniform float wall_x = 20.0;       // the hall's east wall (Godot x)

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash1(float x) { return fract(sin(x * 127.1) * 43758.5453); }
float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x), mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int k = 0; k < 5; k++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.0, 5.0);
		a *= 0.5;
	}
	return s;
}

// coverage of a line of half-width w at distance d, anti-aliased over the pixel footprint
float line_cov(float d, float w, float fw) {
	return clamp((w + fw - abs(d)) / max(fw * 2.0, 1e-4), 0.0, 1.0);
}

vec3 sky(vec3 d) {
	float up = clamp(d.y, 0.0, 1.0);
	vec3 c = mix(horizon_col, zenith_col, smoothstep(0.02, 0.55, up));
	// clouds on a plane 400 m up, fading into the haze at the horizon
	vec2 cp = d.xz / max(d.y, 0.04) * 400.0;
	float n = fbm(cp * 0.0035 + vec2(3.0, 9.0));
	float cov = smoothstep(0.42, 0.72, n);
	float shade = smoothstep(0.55, 0.85, fbm(cp * 0.009 + vec2(11.0, 1.0)));
	vec3 cl = mix(cloud_col, cloud_shade, shade * 0.6);
	c = mix(c, cl, cov * smoothstep(0.0, 0.12, up) * 0.9);
	// a brighter band where the overcast meets the ground
	c += vec3(0.06) * (1.0 - smoothstep(0.0, 0.08, up));
	return c;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 d = normalize(wpos - cam);
	vec3 col = sky(d);
	float t_ground = d.y < -1e-4 ? -cam.y / d.y : 1e9;
	float dx = max(d.x, 1e-4);
	float covered = 0.0;       // what is already hidden by a nearer layer

	// the gravel yard, when the ray reaches the ground before the next layer
	float t_poles = (wall_x + 18.0 - cam.x) / dx;
	if (d.x > 1e-3 && t_ground < t_poles) {
		vec3 g = cam + d * t_ground;
		float n = fbm(g.xz * 0.6);
		vec3 gc = gravel_col * (0.75 + 0.5 * n);
		gc = mix(gc, gc * 0.55, smoothstep(0.62, 0.7, fbm(g.xz * 0.12 + 4.0)));   // damp patches
		col = mix(gc, horizon_col, clamp(t_ground / 140.0, 0.0, 0.5));
	} else if (d.x > 1e-3) {
		// utility poles every 30 m, 18 m out, with three sagging wires
		vec3 p = cam + d * t_poles;
		float fz = fwidth(p.z) + 1e-4;
		float fy = fwidth(p.y) + 1e-4;
		float cell = floor((p.z + 7.0) / 30.0);
		float lz = p.z + 7.0 - cell * 30.0;          // 0..30 along the span
		float pole = line_cov(lz - 15.0, 0.16, fz) * step(p.y, 9.6) * step(0.0, p.y);
		float arm = line_cov(lz - 15.0, 1.1, fz) * line_cov(p.y - 9.0, 0.07, fy);
		float wires = 0.0;
		for (int k = 0; k < 3; k++) {
			float off = float(k - 1) * 0.9;
			float s = (lz - 15.0 - off) / 15.0;       // -1..1 between the poles (wrapped)
			s = s - 2.0 * floor((s + 1.0) * 0.5);
			float wy = 8.95 - 0.75 * (1.0 - s * s);
			wires = max(wires, line_cov(p.y - wy, 0.012, fy) * 0.85);
		}
		float c = clamp(max(max(pole, arm), wires), 0.0, 1.0);
		col = mix(col, mix(pole_col, horizon_col, 0.12), c);
		covered = c;

		// a line of trees 35 m out, in clumps
		float t_trees = (wall_x + 35.0 - cam.x) / dx;
		if (t_ground > t_trees) {
			vec3 q = cam + d * t_trees;
			float clump = smoothstep(0.45, 0.62, fbm(vec2(q.z * 0.05, 2.0)));     // clumps with gaps
			float h = mix(1.2, 9.5, clump) + 2.5 * (fbm(vec2(q.z * 0.4, 7.0)) - 0.5);
			float edge = (fbm(q.zy * 1.8) - 0.5) * 2.0;           // leafy, broken outline
			float tree = smoothstep(0.0, 0.2, h + edge - q.y) * step(0.0, q.y);
			// darker inside and underneath, lit crowns, leaf-sized light and shade
			float leaf = fbm(q.zy * 4.0);
			vec3 tc = tree_col * mix(0.55, 1.6, smoothstep(h - 3.5, h + 0.5, q.y)) * (0.6 + 0.8 * leaf);
			tc = mix(tc, horizon_col, 0.16);
			col = mix(col, tc, tree * (1.0 - covered));
			covered = max(covered, tree);
		}
		// the rooflines of the next blocks, 90 m out, in the haze
		float t_roofs = (wall_x + 90.0 - cam.x) / dx;
		if (t_ground > t_roofs && covered < 1.0) {
			vec3 r = cam + d * t_roofs;
			float bi = floor(r.z / 16.0);
			float bh = mix(5.0, 17.0, hash1(bi + 3.0));
			bh += step(0.8, hash1(bi + 11.0)) * step(abs(fract(r.z / 16.0) - 0.5), 0.12) * 6.0;   // a water tower or a plant stack
			float roof = smoothstep(0.0, fwidth(r.y) * 1.5 + 1e-3, bh - r.y) * step(0.0, r.y);
			vec3 rc = roof_col * (0.85 + 0.3 * hash1(bi));
			rc *= 0.92 + 0.08 * step(0.5, fract(r.y * 0.33));      // storeys
			rc = mix(rc, horizon_col, 0.5);
			col = mix(col, rc, roof * (1.0 - covered));
		}
	}
	ALBEDO = col * energy;
}
