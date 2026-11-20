// Baked cloud signed-distance field (tiles in XZ), shared by clouds / terrain / water.
// Positions passed in are in CLOUD SPACE (world minus accumulated wind drift).

uniform sampler3D sdf_tex : filter_linear, repeat_enable;
uniform vec3 sdf_dom = vec3(16384.0, 3200.0, 16384.0);
uniform float sdf_soft = 64.0;
global uniform vec2 g_wind;
#define wind_offset g_wind

// x = signed distance (m), y = storm weight
vec2 sample_sdf(vec3 p) {
	vec3 uvw = p / sdf_dom;
	float oy = max(max(-p.y, p.y - sdf_dom.y), 0.0);
	uvw.y = clamp(uvw.y, 0.006, 0.994);
	vec2 s = textureLod(sdf_tex, uvw, 0.0).rg;
	s.x += oy;
	return s;
}

float base_m(vec3 p) {
	return clamp(0.5 - sample_sdf(p).x / (2.0 * sdf_soft), 0.0, 1.0);
}

// Cheap cloud shadow for surfaces: sample the field where the light ray crosses
// the main cloud altitudes. p is WORLD space.
float cloud_shadow(vec3 p) {
	vec3 L = g_light_dir;
	float ly = max(L.y, 0.05);
	float s = 0.0;
	const float lv[4] = float[4](800.0, 1150.0, 1600.0, 2100.0);
	for (int i = 0; i < 4; i++) {
		float t = (lv[i] - p.y) / ly;
		if (t > 0.0 && t < 20000.0) {
			vec3 q = p + L * t;
			q.xz -= wind_offset;
			s += smoothstep(0.25, 0.75, base_m(q));
		}
	}
	return clamp(s * 0.6, 0.0, 1.0);
}
