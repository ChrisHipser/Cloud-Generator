#[compute]
#version 450
// Procedural "wonderland" terrain heightmap.
// RGBA32F: R = height (m), G = mesa/sandstone weight, B = spire/basalt weight, A = lake mask (CPU fills)

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2D out_img;
layout(set = 0, binding = 1, std430) readonly buffer Params {
	vec4 dom;   // size, res, seed, sea_floor
};

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p + dom.z * 0.731) * 43758.5453123);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(dot(hash2(i), f), dot(hash2(i + vec2(1, 0)), f - vec2(1, 0)), u.x),
		mix(dot(hash2(i + vec2(0, 1)), f - vec2(0, 1)), dot(hash2(i + vec2(1, 1)), f - vec2(1, 1)), u.x), u.y) * 1.4;
}

float fbm(vec2 p, int oct) {
	float s = 0.0, a = 0.5;
	mat2 r = mat2(1.6, 1.2, -1.2, 1.6);
	for (int i = 0; i < oct; i++) { s += a * noise(p); p = r * p; a *= 0.5; }
	return s;
}

float ridged(vec2 p, int oct) {
	float s = 0.0, a = 0.5, prev = 1.0;
	mat2 r = mat2(1.7, 1.1, -1.1, 1.7);
	for (int i = 0; i < oct; i++) {
		float n = 1.0 - abs(noise(p));
		n = n * n;
		s += n * a * (0.5 + prev * 0.7);
		prev = n;
		p = r * p;
		a *= 0.5;
	}
	return s;
}

float worley(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float md = 9.0;
	for (int y = -1; y <= 1; y++)
	for (int x = -1; x <= 1; x++) {
		vec2 o = vec2(x, y);
		vec2 r = hash2(i + o) * 0.5 + 0.5;
		md = min(md, length(o + r - f));
	}
	return md;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	int R = int(dom.y);
	if (id.x >= R || id.y >= R) return;
	vec2 p = ((vec2(id) + 0.5) / float(R) - 0.5) * dom.x;   // meters, centered
	vec2 q = p / 1000.0;

	// domain warp for organic shapes
	vec2 w = vec2(fbm(q * 0.35 + 3.1, 4), fbm(q * 0.35 - 7.7, 4));
	vec2 qw = q + w * 1.6;

	// island mask: coast with bays, ocean beyond
	float r = length(p) / (dom.x * 0.5);
	float coast = r + fbm(q * 0.22 + 11.0, 4) * 0.35;
	float land = smoothstep(0.98, 0.72, coast);

	// rolling meadows
	float plains = 40.0 + fbm(qw * 0.6, 5) * 90.0;

	// region selectors
	float alpine = smoothstep(-0.25, 0.2, fbm(q * 0.13 + 1.7, 3));
	float mesa = smoothstep(0.0, 0.3, fbm(q * 0.16 - 5.3, 3)) * (1.0 - alpine * 0.8);
	float spires = smoothstep(0.15, 0.4, fbm(q * 0.2 + 9.9, 3)) * (1.0 - alpine * 0.6);

	// jagged ridged mountains with snowy peaks
	float mount = ridged(qw * 0.45, 7);
	// steepen the ridged field into proper summits, soft-capped around 3.4 km
	mount = pow(max(mount * 1.5, 0.0), 1.8) * 1500.0 * alpine;
	mount = 3400.0 * (1.0 - exp(-mount / 3400.0));

	// mesas, buttes and stepped canyon walls
	float mbase = (fbm(qw * 0.5 + 4.0, 5) * 0.5 + 0.5);
	float plateau = smoothstep(0.52, 0.58, mbase) * 380.0 + smoothstep(0.66, 0.70, mbase) * 260.0;
	float terr = plateau;
	float step_h = 70.0;
	float hh = terr + fbm(qw * 1.5, 3) * 30.0;
	float tq = floor(hh / step_h);
	float tf = fract(hh / step_h);
	terr = (tq + smoothstep(0.55, 0.85, tf)) * step_h;
	float canyon = 1.0 - abs(noise(qw * 0.33 + 20.0));
	canyon = smoothstep(0.90, 0.975, canyon);
	terr -= canyon * 260.0;

	// hoodoo spires and pockmarked pillars
	float wv = worley(qw * 4.0);
	float pill = pow(clamp(1.0 - wv * 1.8, 0.0, 1.0), 2.5) * 320.0 * spires;
	float arches = smoothstep(0.08, 0.0, abs(noise(qw * 2.3) )) * 60.0 * spires;

	float h = plains + mount + terr * mesa + pill + arches;
	// river-ish valleys through plains
	float valley = 1.0 - abs(noise(qw * 0.25 - 13.0));
	h -= smoothstep(0.93, 0.99, valley) * 60.0 * (1.0 - alpine);
	// talus / rock slide roughness
	h += fbm(q * 9.0, 4) * 10.0 * (alpine + mesa);

	h = mix(dom.w, h, land);
	imageStore(out_img, id, vec4(h, mesa * land, spires * land, 0.0));
}
