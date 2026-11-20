// Shared atmosphere model. Every shader (sky, clouds, terrain, water) fogs
// toward the same function so the whole frame stays in one palette.

global uniform vec3 g_sun_dir;
global uniform vec3 g_moon_dir;
global uniform vec3 g_light_dir;
global uniform vec3 g_light_col;
global uniform vec3 g_sun_col;
global uniform vec3 g_zenith;
global uniform vec3 g_horizon;
global uniform vec3 g_amb_top;
global uniform vec3 g_amb_bot;
global uniform float g_night;
global uniform float g_overcast;
global uniform float g_haze;

vec3 atmo(vec3 rd) {
	float y = max(rd.y, 0.0);
	float h = pow(1.0 - y, 4.0);
	vec3 col = mix(g_zenith, g_horizon, h);
	float cs = max(dot(rd, g_sun_dir), 0.0);
	float low = pow(1.0 - y, 10.0);
	col += g_sun_col * (pow(cs, 5.0) * 0.035 * (0.25 + 0.75 * h) + pow(cs, 48.0) * 0.07 + pow(cs, 3.0) * low * 0.06);
	float anti = max(-dot(rd, g_sun_dir), 0.0);
	float lowsun = 1.0 - smoothstep(0.0, 0.35, abs(g_sun_dir.y));
	col += vec3(0.10, 0.04, 0.07) * anti * anti * h * lowsun * (1.0 - g_night);
	if (rd.y < 0.0) {
		col = mix(col, g_horizon * 0.55 + g_zenith * 0.15, smoothstep(0.0, -0.25, rd.y));
	}
	return col;
}

vec3 haze_col(vec3 rd) {
	vec3 d = normalize(vec3(rd.x, 0.03 + max(rd.y, 0.0) * 0.2, rd.z));
	return atmo(d);
}

float haze_amount(float dist) {
	return 1.0 - exp(-dist / g_haze);
}
