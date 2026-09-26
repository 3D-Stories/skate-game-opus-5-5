// The east windows' glass: grimy old factory glass with the daylight behind it.
// Breaking a window keeps its four panes and knocks a jagged hole in each, so shards stay
// stuck in the corners and along the frame, their broken edges catching the light.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;

uniform vec3 win_center;           // world centre of the window (Godot axes)
uniform vec2 win_half = vec2(1.4, 1.0);   // half width along the wall (z), half height
uniform float broken = 0.0;
uniform float seed = 0.0;
uniform vec3 tint : source_color = vec3(0.46, 0.55, 0.55);
uniform vec3 grime_col : source_color = vec3(0.24, 0.22, 0.18);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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
	for (int k = 0; k < 4; k++) {
		s += a * vnoise(p);
		p = p * 2.07 + vec2(5.0, 13.0);
		a *= 0.5;
	}
	return s;
}

void fragment() {
	vec2 w = vec2(wpos.z - win_center.z, wpos.y - win_center.y) / win_half;   // -1..1 over the window
	vec2 pid = step(0.0, w);                              // which of the four panes
	vec2 pc = (w - (pid * 2.0 - 1.0) * 0.5) * 2.0;        // -1..1 within the pane
	float glint = 0.0;
	if (broken > 0.5) {
		// the hole: an irregular polygon with straight glass edges round the pane's centre.
		// Most corners reach out to (or past) the frame; about a third are the tips of
		// long shards left pointing in.
		float ps = seed * 7.13 + dot(pid, vec2(3.7, 11.3));
		float N = 13.0;
		float a01 = (atan(pc.y, pc.x) / 6.2831853 + 0.5) * N;
		float si = floor(a01);
		float s1 = mod(si + 1.0, N);
		float ra = hash2(vec2(si, ps + 9.0)) < 0.33 ? mix(0.22, 0.55, hash2(vec2(si, ps))) : mix(0.78, 1.35, hash2(vec2(si, ps)));
		float rb = hash2(vec2(s1, ps + 9.0)) < 0.33 ? mix(0.22, 0.55, hash2(vec2(s1, ps))) : mix(0.78, 1.35, hash2(vec2(s1, ps)));
		float aa = (si / N - 0.5) * 6.2831853;
		float ab = ((si + 1.0) / N - 0.5) * 6.2831853;
		vec2 A = ra * vec2(cos(aa), sin(aa));
		vec2 ed = rb * vec2(cos(ab), sin(ab)) - A;
		float side_o = ed.x * (-A.y) - ed.y * (-A.x);             // the centre's side of edge A-B
		float side_p = ed.x * (pc.y - A.y) - ed.y * (pc.x - A.x);
		if (side_o * side_p > 0.0) {
			discard;
		}
		float edge_d = abs(side_p) / max(length(ed), 1e-4);      // distance to the broken edge
		glint = 1.0 - smoothstep(0.0, 0.03, edge_d);
	}
	// grime: blotches, rain streaks down the pane and dirt piled in the corners
	vec2 g = vec2(wpos.z, wpos.y);
	float blot = fbm(g * vec2(1.6, 1.1) + seed * 3.1);
	float streak = fbm(vec2(g.x * 7.0, g.y * 0.35) + seed);
	float corner = smoothstep(0.55, 1.0, max(abs(pc.x), abs(pc.y)));
	float dirt = clamp(blot * 0.9 + streak * 0.45 - 0.55 + corner * 0.35, 0.0, 1.0);
	ALBEDO = mix(tint, grime_col, dirt);
	ALPHA = mix(0.30, 0.82, dirt);
	ROUGHNESS = mix(0.04, 0.55, dirt);
	SPECULAR = 0.9;
	// daylight coming through the clean glass, a pale glow at the broken edges
	EMISSION = tint * 0.22 * (1.0 - dirt) + vec3(0.55, 0.66, 0.62) * glint * 0.8;
	ALPHA = max(ALPHA, glint * 0.9);
}
