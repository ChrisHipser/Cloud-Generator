shader_type spatial;
render_mode world_vertex_coords, cull_back;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/field.gdshaderinc"

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform float terrain_size = 16384.0;
uniform float texel = 8.0;
uniform float snow_line = 1650.0;

instance uniform float spacing = 4.0;
instance uniform vec2 inner_center = vec2(0.0);
instance uniform float inner_half = 0.0;
instance uniform vec2 level_center = vec2(0.0);
instance uniform float level_half = 256.0;

varying vec3 wpos;
varying float morphk;

vec4 hs(vec2 xz) {
	return textureLod(height_tex, xz / terrain_size + 0.5, 0.0);
}

void vertex() {
	vec2 xz = VERTEX.xz;
	vec2 d = abs(xz - level_center);
	float k = smoothstep(level_half * 0.72, level_half * 0.94, max(d.x, d.y));
	vec2 gp = xz / spacing;
	vec2 fr = fract(gp * 0.5) * 2.0;
	gp -= fr * k;
	xz = gp * spacing;
	VERTEX.xz = xz;
	VERTEX.y = hs(xz).r;
	wpos = VERTEX;
	morphk = k;
}

float n3(vec3 p) { return texture(noise_tex, p).a; }

void fragment() {
	vec3 p = wpos;
	if (inner_half > 0.0) {
		vec2 dd = abs(p.xz - inner_center);
		if (max(dd.x, dd.y) < inner_half) discard;
	}
	float e = max(texel, spacing * 0.5);
	float hl = hs(p.xz - vec2(e, 0)).r;
	float hr = hs(p.xz + vec2(e, 0)).r;
	float hd = hs(p.xz - vec2(0, e)).r;
	float hu = hs(p.xz + vec2(0, e)).r;
	vec3 n = normalize(vec3(hl - hr, 2.0 * e, hd - hu));
	vec4 info = hs(p.xz);
	float mesa = info.g;
	float spire = info.b;
	float lake = info.a;
	float dist = length(p - CAMERA_POSITION_WORLD);

	// detail normal (pockmarks / jaggedness) fades with distance
	float dfade = 1.0 - smoothstep(300.0, 2500.0, dist);
	vec3 q = p / 90.0;
	float pits = texture(noise_tex, p / 140.0).g;
	vec3 dn = vec3(n3(q) - 0.5, 0.0, n3(q + 0.37) - 0.5) * 0.9 + vec3(pits - 0.5, 0.0, texture(noise_tex, p / 140.0 + 0.5).g - 0.5) * spire * 1.2;
	n = normalize(n + dn * dfade * 0.6);
	float slope = 1.0 - n.y;

	float nn = texture(noise_tex, p / 1200.0).a;
	float nf = texture(noise_tex, p / 60.0).r;
	vec3 grass = mix(vec3(0.20, 0.31, 0.10), vec3(0.44, 0.45, 0.19), smoothstep(0.35, 0.7, nn));
	grass = mix(grass, vec3(0.53, 0.47, 0.26), smoothstep(0.6, 0.8, nf) * 0.4);
	vec3 granite = mix(vec3(0.36, 0.35, 0.35), vec3(0.52, 0.50, 0.48), nf);
	float band = sin(p.y * 0.11 + nn * 6.0) * 0.5 + 0.5;
	float band2 = sin(p.y * 0.37 + nf * 3.0) * 0.5 + 0.5;
	vec3 sand_st = mix(vec3(0.60, 0.30, 0.17), vec3(0.80, 0.55, 0.34), band) * mix(0.85, 1.08, band2);
	vec3 basalt = mix(vec3(0.15, 0.14, 0.15), vec3(0.30, 0.26, 0.24), pits);
	basalt *= mix(0.55, 1.0, smoothstep(0.25, 0.45, pits));
	vec3 rock = mix(granite, sand_st, smoothstep(0.1, 0.6, mesa));
	rock = mix(rock, basalt, smoothstep(0.2, 0.7, spire) * 0.85);
	float rocky = smoothstep(0.18, 0.42, slope + (nf - 0.5) * 0.15);
	vec3 col = mix(grass, rock, rocky);
	// talus fans of loose scree at mid slopes
	col = mix(col, rock * 0.85 + 0.05, smoothstep(0.12, 0.2, slope) * (1.0 - rocky) * 0.6);

	float sl = snow_line + (nn - 0.5) * 420.0;
	float snow = smoothstep(sl, sl + 90.0, p.y) * (1.0 - smoothstep(0.42, 0.62, slope));
	snow = max(snow, smoothstep(sl + 350.0, sl + 600.0, p.y) * 0.6 * (1.0 - smoothstep(0.6, 0.8, slope)));
	col = mix(col, vec3(0.93, 0.95, 1.0), snow);

	float beach = smoothstep(7.0, 2.0, p.y) + lake * smoothstep(1.0, 0.0, abs(lake - 0.85)) * 0.0;
	col = mix(col, vec3(0.76, 0.68, 0.50), clamp(beach, 0.0, 1.0) * (1.0 - snow));
	col = mix(col, vec3(0.42, 0.38, 0.28), smoothstep(0.3, 0.9, lake));
	col = mix(col, vec3(0.20, 0.22, 0.20), smoothstep(0.0, -8.0, p.y));

	float cs = cloud_shadow(p);
	col *= mix(1.0, 0.42, cs);

	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.55, snow);
	SPECULAR = mix(0.2, 0.5, snow) * (1.0 - cs);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	vec3 vd = normalize(p - CAMERA_POSITION_WORLD);
	FOG = vec4(haze_col(vd), haze_amount(dist));
}
