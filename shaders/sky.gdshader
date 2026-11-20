shader_type sky;
render_mode use_debanding;

#include "res://shaders/common.gdshaderinc"

uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform float cirrus_amt = 0.7;
uniform float star_amt = 1.0;
uniform vec2 cirrus_wind = vec2(0.0);
uniform float time_s = 0.0;

float h31(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

vec3 hue(float h) {
	return clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

float n2(vec2 uv) { return texture(noise_tex, vec3(uv.x, 0.5, uv.y)).a; }
float w2(vec2 uv) { return texture(noise_tex, vec3(uv.x, 0.25, uv.y)).g; }

vec3 stars(vec3 d) {
	vec3 col = vec3(0.0);
	for (int l = 0; l < 3; l++) {
		float sc = 180.0 + float(l) * 160.0;
		vec3 p = d * sc;
		vec3 ip = floor(p);
		vec3 fp = fract(p) - 0.5;
		float h = h31(ip + float(l) * 17.0);
		if (h > 0.965 - float(l) * 0.01) {
			vec3 o = (vec3(h31(ip + 1.3), h31(ip + 2.7), h31(ip + 5.1)) - 0.5) * 0.6;
			float r = length(fp - o);
			float b = pow(fract(h * 91.7), 6.0) * 6.0 + 0.4;
			float tw = 0.75 + 0.25 * sin(time_s * (2.0 + h * 9.0) + h * 80.0);
			vec3 tint = mix(vec3(0.7, 0.8, 1.0), vec3(1.0, 0.85, 0.65), fract(h * 37.0));
			col += tint * b * tw * smoothstep(0.09, 0.0, r);
		}
	}
	// milky way band
	vec3 gp = normalize(vec3(0.35, 0.82, 0.45));
	float band = 1.0 - abs(dot(d, gp));
	// mottled star clouds with dark dust lanes, a soft warm core, no hard stripe
	vec2 guv = vec2(atan(d.z, d.x) / 6.2831 * 4.0, dot(d, gp) * 2.0);
	float wob = (n2(guv * 0.45 + 5.1) - 0.5) * 0.06;
	float b2 = clamp(1.0 - abs(dot(d, gp) + wob), 0.0, 1.0);   // pow(negative) = NaN
	float m = pow(b2, 14.0);
	float dust = n2(guv * 0.7) * 0.45 + n2(guv * 2.3) * 0.3 + n2(guv * 6.1 + 1.3) * 0.25;
	float clumps = smoothstep(0.35, 0.8, dust);
	float lanes = smoothstep(0.45, 0.65, n2(guv * 1.4 + 3.0)) * smoothstep(0.6, 1.0, b2 * 1.02);
	col += vec3(0.55, 0.6, 0.85) * m * clumps * (1.0 - lanes * 0.8) * 0.32;
	col += vec3(1.0, 0.82, 0.62) * pow(b2, 60.0) * clumps * (1.0 - lanes) * 0.22;
	// two faint spiral galaxies
	vec3 gal[2] = vec3[2](normalize(vec3(-0.5, 0.6, 0.62)), normalize(vec3(0.7, 0.45, -0.55)));
	for (int i = 0; i < 2; i++) {
		vec3 c = gal[i];
		vec3 t1 = normalize(cross(c, vec3(0.0, 1.0, 0.0)));
		vec3 t2 = cross(c, t1);
		vec2 q = vec2(dot(d, t1), dot(d, t2)) * 60.0;
		q = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * q;
		q.y *= 2.4;
		float r = length(q);
		float ang = atan(q.y, q.x);
		float arm = 0.5 + 0.5 * sin(ang * 2.0 - r * 3.5);
		col += vec3(0.8, 0.75, 1.0) * exp(-r * 1.4) * (0.6 + arm * 0.6) * step(0.0, dot(d, c)) * 0.9;
	}
	return col * star_amt;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 col = atmo(d);
	float day = 1.0 - g_night;

	// sun disc + corona
	float cs = dot(d, g_sun_dir);
	float sun = smoothstep(0.99965, 0.99985, cs);
	col += g_sun_col * sun * 12.0 * (1.0 - g_overcast * 0.85);
	col += g_sun_col * pow(max(cs, 0.0), 900.0) * 0.6;

	// moon
	float cm = dot(d, g_moon_dir);
	float moon = smoothstep(0.99955, 0.99972, cm);
	vec3 mn = normalize(d - g_moon_dir * cm);
	float crater = n2(vec2(dot(mn, vec3(1, 0, 0)), dot(mn, vec3(0, 0, 1))) * 40.0 + 0.3);
	col += vec3(0.85, 0.88, 1.0) * moon * (0.9 + crater * 0.5) * 3.0 * g_night;
	col += vec3(0.25, 0.3, 0.45) * pow(max(cm, 0.0), 300.0) * g_night;

	if (d.y > 0.0) {
		// night sky
		float sv = smoothstep(0.0, 0.08, d.y) * g_night * (1.0 - g_overcast * 0.9);
		col += stars(d) * sv;

		// cirrus: soft wind-combed ice fibres ("mares' tails") on a high, curved layer.
		// Several rotated noise octaves so nothing repeats or lines up into stripes.
		vec2 uv = d.xz / (d.y + 0.22) * 0.5 + cirrus_wind;
		mat2 r1 = mat2(vec2(0.88, 0.47), vec2(-0.47, 0.88));
		mat2 r2 = mat2(vec2(0.6, -0.8), vec2(0.8, 0.6));
		vec2 w = vec2(n2(uv * 0.031 + 1.7), n2(r2 * uv * 0.029 + 4.1)) - 0.5;
		vec2 q = r1 * uv + w * 9.0;
		// stretched along the wind: fibres, not bands
		vec2 sq = vec2(q.x * 0.018, q.y * 0.075);
		float body = n2(sq) * 0.55 + n2(r2 * sq * 2.1 + 0.37) * 0.3 + n2(r1 * sq * 4.3 + 0.71) * 0.15;
		float patchy = smoothstep(0.38, 0.72, n2(uv * 0.012 + w * 0.4 + 7.3));
		float fib = w2(vec2(q.x * 0.05, q.y * 0.6)) * 0.6 + w2(r2 * vec2(q.x * 0.11, q.y * 1.3)) * 0.4;
		float ci = smoothstep(0.42, 0.78, body) * patchy * (0.55 + 0.45 * fib) * cirrus_amt;
		ci *= smoothstep(0.02, 0.3, d.y);
		float sa = acos(clamp(cs, -1.0, 1.0));
		// ice-crystal colours only near the sun, plus the 22 degree halo
		vec3 irid = mix(vec3(1.0), hue(sa * 2.6 + fib * 0.5 + time_s * 0.002) * 0.4 + 0.6, exp(-sa * 2.2) * 0.8);
		float hx = (sa - 0.384) / 0.022;
		float halo = exp(-hx * hx);
		vec3 ccol = (g_light_col * 0.11 * (0.6 + 0.9 * pow(max(cs, 0.0), 6.0)) + g_amb_top * 0.6) * irid;
		ccol += hue(sa * 9.0) * halo * g_sun_col * 0.045 * day;
		col = mix(col, ccol, clamp(ci * 0.7, 0.0, 0.8));

		// high overcast sheet
		float ov = g_overcast;
		if (ov > 0.01) {
			vec2 ou = d.xz / (d.y + 0.15) * 0.25 + cirrus_wind * 0.5;
			float sheet = n2(ou * 0.15) * 0.6 + n2(ou * 0.6) * 0.4;
			float cover = smoothstep(1.0 - ov * 1.2, 1.0 - ov * 0.4, sheet) * smoothstep(0.0, 0.25, d.y);
			vec3 gray = mix(g_horizon, vec3(dot(g_horizon, vec3(0.33))), 0.6) * (0.75 + 0.25 * sheet);
			gray += g_sun_col * pow(max(cs, 0.0), 8.0) * 0.04;
			col = mix(col, gray, cover * 0.9);
		}
	}
	COLOR = col;
}
