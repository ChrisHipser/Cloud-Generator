#[compute]
#version 450
// Bakes the far-field cloud signed distance field: smooth union of flat-bottomed
// spheres (metaballs) + a bumpy deck shelf with holes. Tiles in XZ.
// Output RG16F: R = signed distance (m), G = storm weight.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
layout(rg16f, set = 0, binding = 0) uniform restrict writeonly image3D out_img;
layout(set = 0, binding = 1) uniform sampler3D noise_tex;
// per sphere: [c.xyz, r] [base_y, storm, 0, 0]
layout(set = 0, binding = 2, std430) readonly buffer Spheres { vec4 sph[]; };
// bins: 16x16 bins over domain, (start, count) pairs, then indices
layout(set = 0, binding = 3, std430) readonly buffer Bins { uvec2 bin[256]; uint idx[]; };
layout(set = 0, binding = 4, std430) readonly buffer Params {
	vec4 dom;      // xyz domain, w = displacement
	vec4 deck;     // alt, thick, cover, bump
	vec4 misc;     // smooth_k, deck_on, max_dist, seed
	ivec4 res;     // grid resolution
};

float smin(float a, float b, float k) {
	float h = max(k - abs(a - b), 0.0) / k;
	return min(a, b) - h * h * k * 0.25;
}

float smax(float a, float b, float k) {
	return -smin(-a, -b, k);
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(id, res.xyz))) return;
	vec3 p = (vec3(id) + 0.5) / vec3(res.xyz) * dom.xyz;
	float k = misc.x;
	float maxd = misc.z;
	float d = maxd;
	float ds = maxd;

	ivec2 b = ivec2(floor(p.xz / dom.xz * 16.0)) & 15;
	uvec2 bi = bin[b.y * 16 + b.x];
	for (uint n = 0u; n < bi.y; n++) {
		uint s = idx[bi.x + n];
		vec4 a = sph[s * 2u];
		vec4 c = sph[s * 2u + 1u];
		vec3 dv = p - a.xyz;
		dv.xz -= dom.xz * round(dv.xz / dom.xz);
		float ls = length(dv * vec3(1.0, 1.0 / max(c.z, 0.2), 1.0)) * min(1.0, max(c.z, 0.2));
		float e = ls - a.w;
		e = smax(e, c.x - p.y, 40.0);
		if (e < d + k) {
			d = smin(d, e, k);
		}
		if (c.y > 0.5) {
			ds = min(ds, e);
		}
	}

	if (misc.y > 0.5) {
		vec3 q = vec3(p.x, misc.w * 13.0, p.z);
		float n1 = texture(noise_tex, vec3(q.xz / 4096.0, 0.31).xzy).a;
		float n2 = texture(noise_tex, vec3(q.xz / 2048.0, 0.67).xzy).r;
		float cov = n1 * 0.65 + n2 * 0.35;
		float hole = (cov - (1.0 - deck.z)) * 1400.0;
		float bump = texture(noise_tex, vec3(p.xz / 1024.0, 0.5).xzy).g;
		float mid = deck.x + deck.y * 0.5;
		float dd = abs(p.y - mid) - deck.y * 0.5 - deck.w * (bump - 0.45) * deck.y * 0.9;
		float dk = smax(dd, -hole, 120.0);
		d = smin(d, dk, k * 0.7);
	}

	float disp = texture(noise_tex, p / 2048.0).r;
	d += (0.5 - disp) * dom.w;
	d = clamp(d, -800.0, maxd);
	float storm = clamp(1.0 - ds / 350.0, 0.0, 1.0);
	imageStore(out_img, id, vec4(d, storm, 0.0, 0.0));
}
