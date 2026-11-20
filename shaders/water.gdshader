shader_type spatial;
render_mode world_vertex_coords, unshaded, cull_disabled, fog_disabled;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/field.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform float terrain_size = 16384.0;
uniform float level = 0.0;
uniform float wave_amp = 1.0;
uniform float time_s = 0.0;
uniform vec3 ripple = vec3(0.0, 0.0, -100.0);   // xz + start time of last splash

varying vec3 wpos;

// one wave's height + slope; amplitude fades once its wavelength is under a pixel or so
vec3 wave(vec2 p, vec2 dir, float wl, float steep, float dist) {
	float k = 6.2831 / wl;
	float c = sqrt(9.8 / k);
	vec2 d = normalize(dir);
	float f = k * (dot(d, p) - c * time_s);
	float fade = 1.0 - smoothstep(wl * 4.0, wl * 18.0, dist);
	float s = steep * fade * wave_amp;
	return vec3(s / k * sin(f), d * s * cos(f));
}

void vertex() {
	VERTEX.y = level;
	wpos = VERTEX;
}

void fragment() {
	vec3 p = wpos;
	vec3 v = normalize(p - CAMERA_POSITION_WORLD);
	float dist = length(p - CAMERA_POSITION_WORLD);
	vec3 w = wave(p.xz, vec2(1.0, 0.31), 93.0, 0.07, dist)
		+ wave(p.xz, vec2(0.61, 1.0), 51.7, 0.06, dist)
		+ wave(p.xz, vec2(-0.37, 0.93), 29.3, 0.06, dist)
		+ wave(p.xz, vec2(0.83, -0.47), 17.1, 0.05, dist)
		+ wave(p.xz, vec2(0.12, 1.0), 11.3, 0.05, dist)
		+ wave(p.xz, vec2(-0.71, -0.58), 6.7, 0.045, dist)
		+ wave(p.xz, vec2(0.97, 0.05), 4.1, 0.04, dist);
	vec3 n = normalize(vec3(-w.y, 1.0, -w.z));
	float crest = w.x;
	float dfade = 1.0 - smoothstep(200.0, 3000.0, dist);
	vec3 q = vec3(p.x, time_s * 0.6, p.z);
	vec2 dn = vec2(texture(noise_tex, q / 40.0).a - 0.5, texture(noise_tex, q / 40.0 + 0.5).a - 0.5)
		+ vec2(texture(noise_tex, q / 9.0).a - 0.5, texture(noise_tex, q / 9.0 + 0.3).a - 0.5) * 0.6;
	// splash ripple rings
	float rt = time_s - ripple.z;
	if (rt > 0.0 && rt < 6.0) {
		vec2 rd2 = p.xz - ripple.xy;
		float r = length(rd2);
		float ring = sin(r * 0.9 - rt * 7.0) * exp(-abs(r - rt * 7.0) * 0.12) * exp(-rt * 0.5);
		dn += normalize(rd2 + 1e-4) * ring * 0.8;
	}
	// detail normals fade out before their tiling becomes visible; a broad noise keeps far water alive
	float nfade = 1.0 - smoothstep(120.0, 800.0, dist);
	vec2 far_n = vec2(texture(noise_tex, vec3(p.x / 900.0, time_s * 0.01, p.z / 700.0)).a - 0.5,
		texture(noise_tex, vec3(p.z / 800.0, 0.37 + time_s * 0.01, p.x / 1000.0)).a - 0.5);
	n = normalize(n + vec3(dn.x, 0.0, dn.y) * 0.35 * nfade + vec3(far_n.x, 0.0, far_n.y) * 0.12);
	if (dot(n, -v) < 0.0) n = normalize(n + v * 0.5);

	vec3 r = reflect(v, n);
	r.y = abs(r.y);
	float fres = 0.02 + 0.98 * pow(1.0 - max(dot(-v, n), 0.0), 5.0);
	vec3 refl = atmo(r);
	float cs = cloud_shadow(p);
	vec3 L = g_light_dir;
	float shin = mix(900.0, 160.0, smoothstep(200.0, 3000.0, dist));
	float spec = pow(max(dot(r, L), 0.0), shin) * mix(60.0, 12.0, smoothstep(200.0, 3000.0, dist)) + pow(max(dot(r, L), 0.0), 60.0) * 1.2;
	vec3 sunref = g_light_col * spec * (1.0 - cs * 0.9);

	float th = textureLod(height_tex, p.xz / terrain_size + 0.5, 0.0).r;
	float depth = max(level - th, 0.0);
	vec3 deep = vec3(0.01, 0.06, 0.09);
	vec3 shallow = vec3(0.06, 0.25, 0.24);
	vec3 body = mix(shallow, deep, 1.0 - exp(-depth * 0.12));
	vec3 amb = mix(g_amb_bot, g_amb_top, 0.5);
	float sss = pow(max(dot(v, L), 0.0), 4.0) * max(crest, 0.0) * 0.6;
	vec3 water = body * (amb * 0.9 + g_light_col * max(L.y, 0.0) * 0.25 * (1.0 - cs * 0.6)) + vec3(0.05, 0.25, 0.2) * sss * g_light_col * 0.05;
	vec3 col = mix(water, refl * (1.0 - cs * 0.35), fres) + sunref;
	float foam = smoothstep(1.2, 0.0, depth) * (0.6 + 0.4 * sin(depth * 6.0 - time_s * 2.0));
	foam += smoothstep(1.0, 1.8, crest) * 0.25 * (texture(noise_tex, vec3(p.x / 12.0, time_s * 0.05, p.z / 12.0)).g);
	col = mix(col, (amb + g_light_col * max(L.y, 0.0) * 0.3) * 0.9, clamp(foam, 0.0, 1.0) * 0.7);
	col = mix(col, haze_col(v), haze_amount(dist));
	ALBEDO = col;
}
