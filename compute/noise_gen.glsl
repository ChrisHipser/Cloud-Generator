#[compute]
#version 450
// Tiling 3D cloud noise, 128^3 RGBA8.
// R = Perlin-Worley (billows)  G = Worley fbm (mid)  B = Worley fbm (fine)  A = gradient fbm (warp / tendrils)

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(rgba8, set = 0, binding = 0) uniform restrict writeonly image3D out_img;

const int N = 128;

uint hash(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v.x ^ v.y ^ v.z;
}

vec3 rand3(ivec3 c, int period) {
	c = ((c % period) + period) % period;
	uint h = hash(uvec3(c));
	uint h2 = hash(uvec3(c) + uvec3(17u, 59u, 101u));
	return vec3(float(h & 0xFFFFu), float(h >> 16u), float(h2 & 0xFFFFu)) / 65535.0;
}

float worley(vec3 p, int period) {
	ivec3 ip = ivec3(floor(p));
	vec3 fp = fract(p);
	float md = 9.0;
	for (int k = -1; k <= 1; k++)
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		vec3 o = vec3(i, j, k);
		vec3 d = o + rand3(ip + ivec3(i, j, k), period) - fp;
		md = min(md, dot(d, d));
	}
	return sqrt(md);
}

float gnoise(vec3 p, int period) {
	ivec3 ip = ivec3(floor(p));
	vec3 f = fract(p);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float res = 0.0;
	float v[8];
	for (int c = 0; c < 8; c++) {
		ivec3 o = ivec3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
		vec3 g = rand3(ip + o, period) * 2.0 - 1.0;
		v[c] = dot(normalize(g + 1e-4), f - vec3(o));
	}
	float x0 = mix(v[0], v[1], u.x), x1 = mix(v[2], v[3], u.x);
	float x2 = mix(v[4], v[5], u.x), x3 = mix(v[6], v[7], u.x);
	return mix(mix(x0, x1, u.y), mix(x2, x3, u.y), u.z);
}

float gfbm(vec3 uvw, int f, int oct) {
	float s = 0.0, a = 0.5, w = 0.0;
	for (int i = 0; i < oct; i++) {
		s += gnoise(uvw * float(f), f) * a;
		w += a;
		a *= 0.5;
		f *= 2;
	}
	return clamp(s / w * 0.5 * 1.6 + 0.5, 0.0, 1.0);
}

float wfbm(vec3 uvw, int f) {
	return 1.0 - (worley(uvw * float(f), f) * 0.625 + worley(uvw * float(f * 2), f * 2) * 0.25 + worley(uvw * float(f * 4), f * 4) * 0.125);
}

float remap(float v, float a, float b, float c, float d) {
	return c + (v - a) / max(b - a, 1e-4) * (d - c);
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(id, ivec3(N)))) return;
	vec3 uvw = (vec3(id) + 0.5) / float(N);
	float pf = gfbm(uvw, 4, 5);
	float w1 = wfbm(uvw, 4);
	float pw = clamp(remap(pf, w1 - 1.0, 1.0, 0.0, 1.0), 0.0, 1.0);
	float g = wfbm(uvw, 6);
	float b = wfbm(uvw, 12);
	float a = gfbm(uvw + vec3(0.37, 0.11, 0.73), 3, 4);
	imageStore(out_img, id, vec4(pw, g, b, a));
}
