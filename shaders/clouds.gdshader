shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

// Fullscreen cloud raymarcher.
// Near the player: density comes from the compute fluid grid (holes, wakes, splashes).
// Beyond `transition`: density comes straight from the baked metaball SDF, eroded by the
// same billow noise, so the hand-off is seamless (the fluid heals toward that same field).
// Lighting: SDF light march + multiple-scattering octaves (Wrenninge), powder term,
// Mie-like optics (silver lining, glory around your shadow, pale fogbow), sun shafts.

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/field.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform sampler3D fluid_tex : filter_linear;

uniform vec3 fluid_origin = vec3(0.0);
uniform float fluid_extent = 700.0;
uniform float fluid_on = 1.0;
uniform float transition = 320.0;
uniform vec3 player_pos = vec3(0.0);
uniform vec3 player_right = vec3(1.0, 0.0, 0.0);
uniform float incloud_s = 0.0;   // camera-in-cloud amount, smoothed over time on the CPU
uniform float cam_m = 0.0;       // raw coverage at the camera

uniform float puff = 0.85;
uniform float billow_scale = 800.0;
uniform float detail = 0.6;
uniform float tendril = 0.5;
uniform float edge_soft = 0.1;
uniform float fullness = 1.0;
uniform float transparency = 0.1;
uniform float mist = 0.35;
uniform float reflectivity = 1.0;
uniform float silver = 1.0;
uniform float solidness = 0.6;
uniform float shadow_dark = 1.0;

uniform int steps = 64;
uniform int light_q = 3;
uniform float step_scale = 1.15;
uniform float far_range = 11000.0;
uniform float time_s = 0.0;

uniform int storm_n = 0;
uniform vec4 storms[6];
uniform vec4 flash = vec4(0.0);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * c, 1.5));
}

float cloud_phase(float c, float k) {
	// dual-lobe HG (forward + back) plus a sharp forward peak for the silver lining;
	// k < 1 flattens the lobes for higher scattering orders. Normalised: isotropic == 1.
	return (mix(hg(c, 0.6 * k), hg(c, -0.25 * k), 0.3) + silver * hg(c, 0.9 * k) * 0.25) * 4.0 * PI;
}

float sq(float x) { return x * x; }

float fluid_mix(vec3 pw, vec3 pc, float base, out bool in_grid) {
	vec3 u = (pc - fluid_origin) / fluid_extent;
	in_grid = all(greaterThan(u, vec3(0.01))) && all(lessThan(u, vec3(0.99)));
	if (!in_grid || fluid_on < 0.5) {
		in_grid = false;
		return base;
	}
	float w = 1.0 - smoothstep(transition * 0.6, transition * 0.97, length(pw - player_pos));
	if (w <= 0.0) return base;
	float d = textureLod(fluid_tex, u, 0.0).r;
	return mix(base, d, w);
}

float shape_density(vec3 pc, float m, float fine) {
	if (m <= 0.002) return 0.0;
	vec3 drift = vec3(time_s * 1.5, 0.0, time_s * 0.7);
	vec4 wn = textureLod(noise_tex, (pc + drift) / (billow_scale * 2.6), 0.0);
	vec3 warp = (wn.agb - 0.5) * tendril * vec3(0.5, 0.18, 0.5);
	vec4 n = textureLod(noise_tex, pc / billow_scale + warp, 0.0);
	float bill = n.r * 0.65 + n.g * 0.35;
	float s = m - puff * 0.55 * (1.0 - bill);
	// fine erosion fades out smoothly with distance (a hard cutoff made clouds pop in a shell)
	if (fine > 0.0 && s > -0.15 && s < edge_soft * 3.0) {
		float n2 = textureLod(noise_tex, pc / (billow_scale * 0.21) + warp * 2.5, 0.0).b;
		s -= detail * 0.16 * (1.0 - n2) * fine;
	}
	return smoothstep(0.0, edge_soft, s);
}

float player_shadow(vec3 p) {
	// the glider's silhouette projected along the light; exaggerated a little so it reads
	vec3 q = player_pos - p;
	float tl = dot(q, g_light_dir);
	if (tl < 0.0 || tl > 900.0) return 0.0;
	vec3 pr = q - g_light_dir * tl;
	float a = dot(pr, player_right);
	vec3 rest = pr - player_right * a;
	float e = length(vec2(a / 6.0, length(rest) / 2.4));
	float soft = 0.12 + tl * 0.0035;
	return (1.0 - smoothstep(1.0 - soft, 1.0 + soft, e)) * mix(1.0, 0.45, tl / 900.0);
}

vec3 sdf_normal(vec3 pc, float e) {
	return normalize(vec3(
		sample_sdf(pc + vec3(e, 0, 0)).x - sample_sdf(pc - vec3(e, 0, 0)).x,
		sample_sdf(pc + vec3(0, e, 0)).x - sample_sdf(pc - vec3(0, e, 0)).x,
		sample_sdf(pc + vec3(0, 0, e)).x - sample_sdf(pc - vec3(0, 0, e)).x) + 1e-4);
}

float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vp.xyz /= vp.w;
	float scene_t = depth <= 0.000001 ? 1e9 : length(vp.xyz);
	vec3 rd = normalize((INV_VIEW_MATRIX * vec4(normalize(vp.xyz), 0.0)).xyz);
	vec3 ro = CAMERA_POSITION_WORLD;

	vec3 wo = vec3(wind_offset.x, 0.0, wind_offset.y);
	float ymax = sdf_dom.y;
	float t0 = 0.0;
	float t1 = min(scene_t, far_range);
	if (abs(rd.y) > 1e-5) {
		float ta = (0.0 - ro.y) / rd.y;
		float tb = (ymax - ro.y) / rd.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = min(t1, max(ta, tb));
	} else if (ro.y < 0.0 || ro.y > ymax) {
		t1 = -1.0;
	}

	// inside a cloud: amount is smoothed over time on the CPU so the view never flickers
	float incloud = incloud_s;
	bool inside_first = incloud > 0.02;

	int lq = clamp(light_q, 1, 5);
	int taps = lq <= 1 ? 2 : (lq <= 3 ? 3 : (lq == 4 ? 4 : 5));
	int octs = lq <= 1 ? 1 : (lq <= 3 ? 2 : 3);

	vec3 L = g_light_dir;
	float cth = dot(rd, L);
	// optics around the anti-light point (sun behind you): glory rings + a pale fogbow
	float th = acos(clamp(-cth, -1.0, 1.0));
	vec3 glory = exp(-th / 0.032) * (0.5 + 0.5 * cos(6.2831 * th / vec3(0.031, 0.027, 0.023))) * 3.2;
	vec3 fogbow = vec3(exp(-sq((th - 0.715) / 0.045)), exp(-sq((th - 0.70) / 0.045)), exp(-sq((th - 0.685) / 0.045))) * 0.45;
	vec3 ph0 = vec3(cloud_phase(cth, 1.0)) + (glory + fogbow) * reflectivity;
	float ph1 = cloud_phase(cth, 0.5);
	float ph2 = cloud_phase(cth, 0.25);
	float hg_shaft = hg(cth, 0.6);

	vec3 hz = haze_col(rd);
	float sig0 = 0.05 * fullness * (1.0 - transparency * 0.85);
	vec3 col = vec3(0.0);
	float T = 1.0;
	float far_fade_start = far_range * 0.72;
	vec3 hit_n = vec3(0.0);
	float hit_t = -1.0;
	float prev_m = cam_m;
	float jit = ign(FRAGCOORD.xy + vec2(fract(time_s * 7.13) * 61.0, fract(time_s * 3.7) * 37.0));
	float t = t0;
	float st_min = 6.0 * step_scale;
	vec3 rimc = (g_amb_top * 0.7 + g_light_col * 0.22 + vec3(0.04)) * vec3(0.85, 0.95, 1.08);

	if (t1 > t0) {
		t += st_min * jit;
		for (int i = 0; i < steps; i++) {
			if (t >= t1 || T < 0.015) break;
			vec3 p = ro + rd * t;
			vec3 pc = p - wo;
			// sub-voxel dither of the far-field lookup: turns the trilinear terracing of
			// the baked SDF (stripes on broad, flat cloud faces) into fine, even grain
			float hj = hash13(vec3(FRAGCOORD.xy * 1.37, float(i) * 0.71 + fract(time_s * 3.3) * 57.0));
			vec3 dj = (fract(hj * vec3(1.0, 37.17, 91.31)) - 0.5) * vec3(14.0, 12.0, 14.0) * smoothstep(300.0, 1200.0, t);
			vec2 sd = sample_sdf(pc + dj);
			float base = clamp(0.5 - sd.x / (2.0 * sdf_soft), 0.0, 1.0);
			bool ingrid = false;
			float m = fluid_mix(p, pc, base, ingrid);
			float st = min(st_min + t * 0.011 * step_scale, 160.0);
			if (m <= 0.002) {
				float skip = sd.x - sdf_soft * 1.1 - 16.0;
				if (ingrid && length(p - player_pos) < transition) skip = min(skip, 25.0);
				// crepuscular shafts: sunlight leaking through gaps (faded, never a hard edge)
				if (lq >= 2 && t < 6000.0) {
					float stp = max(skip, st);
					float o1 = base_m(pc + L * 220.0) + base_m(pc + L * 600.0);
					float vis = exp(-o1 * 2.5);
					col += T * g_light_col * vis * hg_shaft * stp * 0.000035 * (1.0 - g_night * 0.8) * (1.0 - smoothstep(4500.0, 6000.0, t));
				}
				if (inside_first) {
					// leaving the cloud you're in: outline its shell (inverse x-ray)
					vec3 gn = sdf_normal(pc, 30.0);
					float graze = 1.0 - abs(dot(gn, rd));
					col += T * rimc * (0.08 + 0.8 * graze * graze * graze) * incloud * 0.6;
					inside_first = false;
				}
				hit_t = -1.0;   // the next cloud along the ray gets its own surface normal
				prev_m = m;
				t += max(skip, st * (0.6 + 0.8 * hash13(vec3(FRAGCOORD.yx, float(i) * 1.37 + fract(time_s * 5.1) * 71.0))));
				continue;
			}
			float fine = 1.0 - smoothstep(1800.0, 3200.0, t);
			float dns = shape_density(pc, m, fine);
			float fade = 1.0 - smoothstep(far_fade_start, far_range, t);
			dns *= fade;
			float mistd = mist * 0.05 * smoothstep(0.0, 0.5, m) * (1.0 - dns) * fade;
			float sig = (dns * sig0 + mistd * 0.008) * (inside_first ? mix(1.0, 0.008, incloud) : 1.0);

			if (inside_first && prev_m >= 0.15 && m < 0.15) {
				vec3 gn = sdf_normal(pc, 30.0);
				float graze = 1.0 - abs(dot(gn, rd));
				col += T * rimc * (0.08 + 0.8 * graze * graze * graze) * incloud * 0.6;
				inside_first = false;
				hit_t = -1.0;
			}
			prev_m = m;

			if (sig > 1e-5) {
				if (hit_t < 0.0 && dns > 0.05) {
					hit_t = t;
					hit_n = sdf_normal(pc, 55.0);
				}
				// light march through the SDF field
				float od = 0.0;
				float prv = 0.0;
				float lj = 0.75 + 0.5 * fract(hj * 13.7);
				for (int k = 0; k < 5; k++) {
					if (k >= taps) break;
					float ld = 16.0 * pow(2.7, float(k)) * lj;
					od += base_m(pc + L * ld) * (ld - prv);
					prv = ld;
				}
				od *= 0.035 * fullness * shadow_dark;
				// multiple scattering as octaves of decreasing extinction and flatter phase
				vec3 S = ph0 * exp(-od);
				if (octs >= 2) S += vec3(ph1 * 0.35 * exp(-od * 0.35));
				if (octs >= 3) S += vec3(ph2 * 0.15 * exp(-od * 0.12));
				if (octs == 1) S += vec3(0.45 * exp(-od * 0.22));
				float powder = 1.0 - exp(-od * 1.8 - dns * 0.6);
				vec3 lit = S * mix(1.0, powder, 0.45);
				float up = base_m(pc + vec3(0.0, 140.0, 0.0));
				if (lq >= 4) up = up * 0.6 + base_m(pc + vec3(0.0, 380.0, 0.0)) * 0.4;
				float litk = clamp(dot(lit, vec3(0.333)), 0.0, 1.0);
				vec3 amb = mix(g_amb_top, g_amb_bot, up * 0.75 + (1.0 - litk) * 0.15);
				float storm = sd.y;
				float alb = mix(1.0, 0.42, storm);
				float ps = 1.0;
				if (length(p - player_pos) < 900.0) ps = 1.0 - 0.88 * player_shadow(p);
				vec3 direct = g_light_col * lit * 0.6 * reflectivity * ps;
				if (hit_t > 0.0 && t - hit_t < 90.0) {
					float lam = clamp(dot(hit_n, L) * 0.6 + 0.4, 0.0, 1.0);
					direct *= mix(1.0, lam * 1.35, solidness * (1.0 - smoothstep(0.0, 90.0, t - hit_t)));
				}
				vec3 s = (direct * mix(1.0, 0.55, storm) + amb * 0.8) * alb;
				if (flash.w > 0.0) {
					s += vec3(0.75, 0.8, 1.0) * flash.w * 9.0 * exp(-length(p - flash.xyz) / 650.0) * (0.4 + storm);
				}
				s = mix(s, hz, haze_amount(t));
				float a = 1.0 - exp(-sig * st);
				col += T * s * a;
				T *= 1.0 - a;
			}
			// per-step white-noise jitter turns wood-grain banding into fine, even grain
			t += st * (0.6 + 0.8 * hash13(vec3(FRAGCOORD.xy, float(i) + fract(time_s * 7.3) * 113.0)));
		}
	}

	// rain shafts under thunderheads
	for (int i = 0; i < 6; i++) {
		if (i >= storm_n) break;
		vec4 sv = storms[i];
		vec2 c = sv.xy + wind_offset;
		vec2 oc = ro.xz - c;
		float a = dot(rd.xz, rd.xz);
		float b = dot(oc, rd.xz);
		float cc = dot(oc, oc) - sv.z * sv.z;
		float disc = b * b - a * cc;
		if (disc > 0.0 && a > 1e-6) {
			float sqd = sqrt(disc);
			float e0 = max((-b - sqd) / a, 0.0);
			float e1 = min((-b + sqd) / a, scene_t);
			if (abs(rd.y) > 1e-5) {
				float tb = (sv.w - ro.y) / rd.y;
				if (rd.y > 0.0) e1 = min(e1, tb); else e0 = max(e0, tb);
			}
			float chord = max(e1 - e0, 0.0);
			if (chord > 0.0) {
				float ra = 1.0 - exp(-chord * 0.0009);
				vec3 rc = (g_amb_bot * 0.9 + g_light_col * 0.04) * 0.7;
				col += T * rc * ra;
				T *= 1.0 - ra;
			}
		}
	}

	// soft grey veil while inside a cloud: dim but never a white-out
	if (incloud > 0.0) {
		vec3 veil = (g_amb_top * 0.8 + g_light_col * 0.13) * 0.9;
		col += T * veil * incloud * 0.16;
		T *= 1.0 - incloud * 0.16;
	}

	float alpha = 1.0 - T;
	if (alpha < 0.002 && length(col) < 0.002) discard;
	ALBEDO = col / max(alpha, 0.001);
	ALPHA = clamp(alpha, 0.0, 1.0);
	if (alpha < 0.002) {
		// pure additive light (shafts, shell outline) – approximate with a tiny alpha
		ALBEDO = col * 50.0;
		ALPHA = 0.02;
	}
}
