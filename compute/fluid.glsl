#[compute]
#version 450
// Near-field cloud fluid: a player-centred 3D grid (in cloud space) carrying
// velocity + cloud density. Semi-Lagrangian advection, optional Jacobi pressure
// projection, healing toward the baked far-field so the hand-off is seamless.
// One shader, many passes selected by push constant `mode`.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image3D velA;
layout(rgba16f, set = 0, binding = 1) uniform restrict image3D velB;
layout(r16f, set = 0, binding = 2) uniform restrict image3D densA;
layout(r16f, set = 0, binding = 3) uniform restrict image3D densB;
layout(r16f, set = 0, binding = 4) uniform restrict image3D prA;
layout(r16f, set = 0, binding = 5) uniform restrict image3D prB;
layout(r16f, set = 0, binding = 6) uniform restrict image3D divT;
layout(set = 0, binding = 7) uniform sampler3D sdf_tex;
layout(set = 0, binding = 8) uniform sampler3D noise_tex;
layout(set = 0, binding = 9, std430) readonly buffer Params {
	vec4 origin;   // grid min (cloud space), w = cell size
	ivec4 shift;   // xyz cell shift this frame, w = N
	vec4 sdom;     // sdf domain xyz, w = sdf_soft
	vec4 player;   // xyz cloud space, w = wake radius
	vec4 pvel;     // xyz velocity rel. to cloud frame, w = speed
	vec4 beam0;    // start xyz, w = active
	vec4 beam1;    // dir xyz, w = length
	vec4 beam2;    // radius, power, time, dt
	vec4 tune;     // heal, wake, swirl, turbulence
	vec4 tune2;    // splash, damping, beam cone (far-end radius multiplier), wake turbulence
	vec4 right;    // player wing axis
	vec4 ev[16];   // 8 events: [pos.xyz, type] [dir.xyz, strength]
};

layout(push_constant, std430) uniform PC { ivec4 pc; };

int N;

float target(vec3 p) {
	vec3 uvw = p / sdom.xyz;
	float oy = max(max(-p.y, p.y - sdom.y), 0.0);
	uvw.y = clamp(uvw.y, 0.006, 0.994);
	float d = textureLod(sdf_tex, uvw, 0.0).r + oy;
	return clamp(0.5 - d / (2.0 * sdom.w), 0.0, 1.0);
}

vec3 cpos(vec3 c) { return origin.xyz + (c + 0.5) * origin.w; }

bool inside(ivec3 c) { return all(greaterThanEqual(c, ivec3(0))) && all(lessThan(c, ivec3(N))); }

vec4 velAt(ivec3 c, bool useB) {
	if (!inside(c)) return vec4(0.0);
	return useB ? imageLoad(velB, c) : imageLoad(velA, c);
}

float pAt(ivec3 c, bool useB) {
	c = clamp(c, ivec3(0), ivec3(N - 1));
	return useB ? imageLoad(prB, c).r : imageLoad(prA, c).r;
}

vec3 sampleVelB(vec3 g) {
	vec3 f = g - 0.5;
	ivec3 i = ivec3(floor(f));
	vec3 t = f - vec3(i);
	vec3 r = vec3(0.0);
	for (int k = 0; k < 8; k++) {
		ivec3 o = ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
		vec3 w3 = mix(1.0 - t, t, vec3(o));
		r += velAt(i + o, true).xyz * (w3.x * w3.y * w3.z);
	}
	return r;
}

float sampleDensB(vec3 g) {
	vec3 f = g - 0.5;
	ivec3 i = ivec3(floor(f));
	vec3 t = f - vec3(i);
	float r = 0.0;
	for (int k = 0; k < 8; k++) {
		ivec3 o = ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
		ivec3 c = i + o;
		vec3 w3 = mix(1.0 - t, t, vec3(o));
		float v = inside(c) ? imageLoad(densB, c).r : target(cpos(vec3(c)));
		r += v * (w3.x * w3.y * w3.z);
	}
	return r;
}

float sq(float x) { return x * x; }

vec3 perp(vec3 r, vec3 axis, out float along) {
	along = dot(r, axis);
	return r - axis * along;
}

void main() {
	N = shift.w;
	ivec3 c = ivec3(gl_GlobalInvocationID);
	if (!inside(c)) return;
	int mode = pc.x;
	float dt = beam2.w;
	float cell = origin.w;
	vec3 p = cpos(vec3(c));

	if (mode == 0) {
		// scroll grid with the player; newly exposed cells seed from the far field
		ivec3 s = c + shift.xyz;
		if (inside(s)) {
			imageStore(velB, c, imageLoad(velA, s));
			imageStore(densB, c, imageLoad(densA, s));
		} else {
			imageStore(velB, c, vec4(0.0));
			imageStore(densB, c, vec4(target(p)));
		}
		return;
	}

	if (mode == 1) {
		vec3 v = imageLoad(velB, c).xyz;
		float d = imageLoad(densB, c).r;
		float spd = pvel.w;
		vec3 vd = spd > 0.5 ? pvel.xyz / spd : vec3(0.0, 0.0, -1.0);
		vec3 r = p - player.xyz;
		float along;
		vec3 rp = perp(r, vd, along);
		float rho = length(rp);
		vec3 rn = rho > 1e-3 ? rp / rho : vec3(0.0);
		float R = player.w;

		// wake: drag air behind, bow push aside in front, twin wingtip vortices
		if (along < 0.0) {
			float f = exp(-rho * rho / (R * R)) * exp(along / (spd * 0.5 + 12.0));
			v += vd * spd * 0.9 * f * tune.y * dt * 4.0;
			vec3 sw = cross(vd, rn);
			float side = sign(dot(rp, right.xyz) + 1e-4);
			v += sw * side * spd * 0.55 * f * tune.z * dt * 5.0;
			d -= d * f * 0.8 * tune.y * dt * clamp(spd / 40.0, 0.0, 1.5);
			// churning eddies in the wake
			if (tune2.w > 0.0) {
				vec3 wq = p / 34.0 + vec3(beam2.z * 0.9, beam2.z * 0.4, -beam2.z * 0.7);
				vec3 wn = vec3(textureLod(noise_tex, wq, 0.0).a, textureLod(noise_tex, wq + 0.37, 0.0).a, textureLod(noise_tex, wq + 0.71, 0.0).a) - 0.5;
				v += wn * min(spd, 160.0) * f * tune2.w * dt * 9.0;
			}
		} else if (along < R * 1.5) {
			float f = exp(-rho * rho / (R * R * 0.6)) * (1.0 - along / (R * 1.5));
			v += (rn * 1.2 + vd * 0.4) * spd * f * tune.y * dt * 6.0;
		}

		// cloud beam: carve, blow open, drift
		if (beam0.w > 0.5) {
			vec3 q = p - beam0.xyz;
			float s = clamp(dot(q, beam1.xyz), 0.0, beam1.w);
			vec3 qq = q - beam1.xyz * s;
			float dist = length(qq);
			float rad = beam2.x * mix(1.0, tune2.z, s / max(beam1.w, 1.0));
			float f = smoothstep(rad, rad * 0.35, dist) * beam2.y;
			f *= smoothstep(beam1.w, beam1.w * 0.7, s);
			d -= f * dt * 3.2;
			vec3 out_ = dist > 1e-3 ? qq / dist : vec3(0.0, 1.0, 0.0);
			v += (out_ * 55.0 + beam1.xyz * 30.0) * f * dt;
		}

		// splash events (entry crown / exit wound / tendril whirl)
		for (int e = 0; e < 8; e++) {
			vec4 a = ev[e * 2];
			vec4 b = ev[e * 2 + 1];
			if (a.w < 0.5 || b.w <= 0.001) continue;
			vec3 u = b.xyz;
			float st = b.w * tune2.x;
			float al;
			vec3 rr = perp(p - a.xyz, u, al);
			float rh = length(rr);
			vec3 rnn = rh > 1e-3 ? rr / rh : vec3(0.0);
			float sz = 10.0 + st * 18.0;
			if (a.w < 1.5) {
				// entry: crown splash thrown back and outward, hole punched
				float ring = exp(-sq((rh - sz * 0.9) / (sz * 0.5))) * exp(-sq((al + sz * 0.3) / (sz * 0.7)));
				v += (rnn * 1.1 - u * 0.9) * st * 45.0 * ring * dt * 6.0;
				d += ring * st * dt * 2.5;
				float core = exp(-(rh * rh + al * al) / (sz * sz * 0.5));
				d -= core * st * dt * 4.0;
			} else if (a.w < 2.5) {
				// exit: puffed-out wound bulging forward with you
				float f = exp(-(rh * rh) / (sz * sz)) * exp(-sq((al - sz * 0.6) / sz));
				v += (u * 1.0 + rnn * 0.75) * st * 50.0 * f * dt * 6.0;
				d += f * st * dt * 3.0;
			} else if (a.w > 3.5) {
				// boost puff: a force burst that shoves cloud away from you in every direction
				float R3 = 35.0 + st * 40.0;
				vec3 q3 = p - a.xyz;
				float r3 = length(q3);
				vec3 n3 = r3 > 1e-3 ? q3 / r3 : vec3(0.0, 1.0, 0.0);
				float shell = exp(-sq((r3 - R3 * 0.8) / (R3 * 0.45)));
				float core = exp(-sq(r3 / R3));
				v += n3 * st * 75.0 * (shell + core * 0.6) * dt * 6.0;
				d -= core * st * dt * 5.0;
			} else {
				// tendril whirlwind trailing behind after exiting
				float f = exp(-(rh * rh) / (sz * sz * 0.35)) * exp(-abs(al + sz) / (sz * 1.5));
				v += cross(u, rnn) * st * 40.0 * f * dt * 6.0 - u * st * 10.0 * f * dt;
				d += f * st * dt * 2.2;
			}
		}

		// gentle living turbulence inside clouds
		if (d > 0.02 && tune.w > 0.0) {
			vec3 nq = p / 380.0 + vec3(0.0, beam2.z * 0.01, 0.0);
			vec3 n = vec3(textureLod(noise_tex, nq, 0.0).a, textureLod(noise_tex, nq + 0.31, 0.0).a, textureLod(noise_tex, nq + 0.67, 0.0).a) - 0.5;
			v += n * tune.w * 6.0 * dt;
		}

		float sp = length(v);
		if (sp > 90.0) v *= 90.0 / sp;
		if (any(isnan(v)) || any(isinf(v))) v = vec3(0.0);
		if (isnan(d) || isinf(d)) d = target(p);
		imageStore(velB, c, vec4(v, 0.0));
		imageStore(densB, c, vec4(clamp(d, 0.0, 1.6)));
		return;
	}

	if (mode == 2) {
		vec3 v = imageLoad(velB, c).xyz;
		vec3 back = vec3(c) + 0.5 - v * dt / cell;
		vec3 nv = sampleVelB(back) * exp(-dt * tune2.y);
		if (any(isnan(nv)) || any(isinf(nv))) nv = vec3(0.0);
		imageStore(velA, c, vec4(nv, 0.0));
		return;
	}

	if (mode == 3) {
		float dv = (velAt(c + ivec3(1, 0, 0), false).x - velAt(c - ivec3(1, 0, 0), false).x
			+ velAt(c + ivec3(0, 1, 0), false).y - velAt(c - ivec3(0, 1, 0), false).y
			+ velAt(c + ivec3(0, 0, 1), false).z - velAt(c - ivec3(0, 0, 1), false).z) / (2.0 * cell);
		imageStore(divT, c, vec4(dv));
		imageStore(prA, c, vec4(pAt(c, false) * 0.8));
		return;
	}

	if (mode == 4 || mode == 5) {
		bool fromB = mode == 5;
		float s = pAt(c + ivec3(1, 0, 0), fromB) + pAt(c - ivec3(1, 0, 0), fromB)
			+ pAt(c + ivec3(0, 1, 0), fromB) + pAt(c - ivec3(0, 1, 0), fromB)
			+ pAt(c + ivec3(0, 0, 1), fromB) + pAt(c - ivec3(0, 0, 1), fromB);
		float np = (s - imageLoad(divT, c).r * cell * cell) / 6.0;
		if (fromB) imageStore(prA, c, vec4(np)); else imageStore(prB, c, vec4(np));
		return;
	}

	if (mode == 6) {
		vec3 g = vec3(pAt(c + ivec3(1, 0, 0), false) - pAt(c - ivec3(1, 0, 0), false),
			pAt(c + ivec3(0, 1, 0), false) - pAt(c - ivec3(0, 1, 0), false),
			pAt(c + ivec3(0, 0, 1), false) - pAt(c - ivec3(0, 0, 1), false)) / (2.0 * cell);
		vec4 v = imageLoad(velA, c);
		vec3 nv = v.xyz - g;
		if (any(isnan(nv)) || any(isinf(nv))) nv = vec3(0.0);
		imageStore(velA, c, vec4(nv, 0.0));
		return;
	}

	if (mode == 7) {
		vec3 v = imageLoad(velA, c).xyz;
		vec3 back = vec3(c) + 0.5 - v * dt / cell;
		float d = sampleDensB(back);
		float t = target(p);
		d += (t - d) * (1.0 - exp(-tune.x * dt));
		if (isnan(d) || isinf(d)) d = t;
		imageStore(densA, c, vec4(clamp(d, 0.0, 1.6)));
		return;
	}
}
