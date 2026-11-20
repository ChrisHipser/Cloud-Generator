extends Node3D
# Time of day, weather, sun/moon light, global atmosphere uniforms, lightning.

signal thunder(pos: Vector3, delay: float, power: float)

var hour := 7.0
var day := 0
var wind := Vector2.ZERO
var env := Environment.new()
var sun := DirectionalLight3D.new()
var sky_mat := ShaderMaterial.new()
var flash := Vector4.ZERO
var field: Node
var light_col := Vector3.ONE
var amb := Color.WHITE
var _flash_t := 0.0
var _flash_pos := Vector3.ZERO
var _next_strike := 4.0
var _bolt := MeshInstance3D.new()
var _bolt_light := OmniLight3D.new()
var _bolt_t := 0.0
var _rng := RandomNumberGenerator.new()
var time_frozen := false


func _ready() -> void:
	sky_mat.shader = load("res://shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.4
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.03
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1800.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_blur = 1.5
	add_child(sun)
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.albedo_color = Color(0.85, 0.9, 1.0)
	bm.emission_enabled = true
	bm.emission = Color(0.8, 0.85, 1.0)
	bm.emission_energy_multiplier = 12.0
	_bolt.material_override = bm
	_bolt.visible = false
	add_child(_bolt)
	_bolt_light.omni_range = 4000.0
	_bolt_light.light_energy = 0.0
	_bolt_light.light_color = Color(0.8, 0.85, 1.0)
	add_child(_bolt_light)
	P.changed.connect(_on_param)
	_rng.randomize()


func _on_param(n: String, _c: String) -> void:
	if n == "new_weather":
		roll_weather()


func roll_weather() -> void:
	var r := _rng.randf()
	var ov := _rng.randf_range(0.0, 0.2)
	if r > 0.6:
		ov = _rng.randf_range(0.3, 0.6)
	if r > 0.85:
		ov = _rng.randf_range(0.7, 1.0)
	P.setv("overcast", ov)
	P.setv("cirrus", _rng.randf_range(0.2, 1.3) * (1.0 - ov * 0.5))
	P.setv("cumulus_count", float(_rng.randi_range(35, 120)))
	P.setv("deck_cover", _rng.randf_range(0.3, 0.8))
	P.setv("storm_count", float(_rng.randi_range(0, 4)))
	P.setv("seed", float(_rng.randi_range(1, 99)))


func advance_hours(h: float) -> void:
	hour += h
	if hour >= 24.0:
		hour -= 24.0
		day += 1
		roll_weather()


func _process(delta: float) -> void:
	if not time_frozen:   # (only the screenshot tour freezes time)
		advance_hours(delta * P.v.time_flow / 60.0)
	wind += Vector2(4.0, 1.6) * P.v.drift * delta
	P.wind = wind
	RenderingServer.global_shader_parameter_set("g_wind", wind)
	_update_sky()
	_update_lightning(delta)


func sun_dir_for(h: float) -> Vector3:
	var a := (h - 6.0) / 24.0 * TAU
	# time warp: the sun (and the moon opposite it) crawl near the horizon and hurry
	# through noon / midnight, so sunrise + sunset light fills about half the day
	a -= P.v.sun_linger * sin(2.0 * a) * 0.5
	var elev := sin(a) * 1.15
	var az := (h / 24.0) * TAU * 0.5 + 0.6
	var d := Vector3(cos(az) * cos(a), elev, sin(az) * cos(a) * 0.6 + 0.35)
	return d.normalized()


func _update_sky() -> void:
	var sd := sun_dir_for(hour)
	var md := -sd
	md = (md + Vector3(0.15, 0.25, 0.1)).normalized()
	var e := rad_to_deg(asin(sd.y))
	var ov: float = P.v.overcast
	var day_k := smoothstep(-6.0, 4.0, e)
	var golden := 1.0 - smoothstep(2.0, 22.0, e)
	var low := smoothstep(-5.0, 1.0, e) * golden

	# sunlight colour from Rayleigh + aerosol extinction through the air mass (Kasten-Young),
	# relative to noon so midday stays white; "sunset richness" thickens the path
	var ee := maxf(e, -0.5)
	var am := 1.0 / (sin(deg_to_rad(ee + 0.5)) + 0.50572 * pow(ee + 0.5 + 6.07995, -1.6364))
	var tau: Vector3 = Vector3(0.066, 0.128, 0.285) * P.v.sunset_rich
	var tr := Vector3(exp(-tau.x * (am - 1.0)), exp(-tau.y * (am - 1.0)), exp(-tau.z * (am - 1.0)))
	var sc := tr / pow(maxf(tr.x, 0.02), 0.35)
	sc *= smoothstep(-4.0, 1.0, e)
	var zen := Vector3(0.10, 0.27, 0.72).lerp(Vector3(0.20, 0.16, 0.42), golden)
	zen = Vector3(0.006, 0.012, 0.035).lerp(zen, day_k)
	var hor := Vector3(0.60, 0.74, 0.95).lerp(Vector3(1.0, 0.44, 0.2), low)
	hor = Vector3(0.025, 0.035, 0.07).lerp(hor, day_k)
	var at := Vector3(0.46, 0.58, 0.85).lerp(Vector3(0.66, 0.42, 0.44), golden)
	at = Vector3(0.06, 0.08, 0.15).lerp(at, day_k)
	var ab := Vector3(0.34, 0.35, 0.38).lerp(Vector3(0.46, 0.24, 0.18), golden)
	ab = Vector3(0.03, 0.04, 0.07).lerp(ab, day_k)
	var grey := (zen + hor) * 0.5
	var g := (grey.x + grey.y + grey.z) / 3.0
	zen = zen.lerp(Vector3(g, g, g) * 0.9, ov * 0.7)
	hor = hor.lerp(Vector3(g, g, g) * 1.05, ov * 0.6)

	var night := 1.0 - day_k
	var ld := sd
	var lc := sc * 3.2 * (1.0 - ov * 0.55)
	if e < -4.0:
		ld = md
		lc = Vector3(0.42, 0.50, 0.78) * 1.1 * smoothstep(-4.0, -9.0, e) * (1.0 - ov * 0.6)
	light_col = lc
	RenderingServer.global_shader_parameter_set("g_sun_dir", sd)
	RenderingServer.global_shader_parameter_set("g_moon_dir", md)
	RenderingServer.global_shader_parameter_set("g_light_dir", ld)
	RenderingServer.global_shader_parameter_set("g_light_col", lc)
	RenderingServer.global_shader_parameter_set("g_sun_col", sc * 6.0 * (1.0 - ov * 0.6))
	RenderingServer.global_shader_parameter_set("g_zenith", zen)
	RenderingServer.global_shader_parameter_set("g_horizon", hor)
	RenderingServer.global_shader_parameter_set("g_amb_top", at)
	RenderingServer.global_shader_parameter_set("g_amb_bot", ab)
	RenderingServer.global_shader_parameter_set("g_night", night)
	RenderingServer.global_shader_parameter_set("g_overcast", ov)
	RenderingServer.global_shader_parameter_set("g_haze", lerpf(26000.0, 11000.0, ov))

	sun.look_at_from_position(Vector3.ZERO, -ld, Vector3.UP if absf(ld.y) < 0.99 else Vector3.FORWARD)
	var lcm := lc.length() / 1.732
	sun.light_color = Color(lc.x, lc.y, lc.z) / max(lcm, 0.001)
	sun.light_energy = lcm * 0.9
	sun.shadow_enabled = lcm > 0.05
	amb = Color(at.x * 0.6 + ab.x * 0.4, at.y * 0.6 + ab.y * 0.4, at.z * 0.6 + ab.z * 0.4)
	env.ambient_light_color = amb
	# a touch more saturation while the sun is low keeps sunset reds from washing to pink
	env.adjustment_saturation = lerpf(1.08, 1.25, golden * day_k)
	env.ambient_light_energy = 1.0
	sky_mat.set_shader_parameter("cirrus_amt", P.v.cirrus)
	sky_mat.set_shader_parameter("star_amt", P.v.stars)
	sky_mat.set_shader_parameter("cirrus_wind", wind * 0.00012)
	sky_mat.set_shader_parameter("time_s", Time.get_ticks_msec() / 1000.0)


func _update_lightning(delta: float) -> void:
	if field == null or field.storms.is_empty():
		flash = Vector4.ZERO
		return
	_next_strike -= delta
	if _next_strike <= 0.0:
		_next_strike = _rng.randf_range(2.5, 11.0)
		var s: Dictionary = field.storms[_rng.randi() % field.storms.size()]
		var c: Vector3 = s.pos + Vector3(wind.x, 0.0, wind.y)
		var cam := get_viewport().get_camera_3d()
		if cam:
			# storms tile every 16 km; pick the copy nearest the camera
			var dom: Vector3 = field.dom
			c.x += round((cam.global_position.x - c.x) / dom.x) * dom.x
			c.z += round((cam.global_position.z - c.z) / dom.z) * dom.z
		var a := _rng.randf() * TAU
		var r: float = _rng.randf() * s.r * 0.7
		_flash_pos = c + Vector3(cos(a) * r, _rng.randf_range(400.0, 1600.0), sin(a) * r)
		_flash_t = 0.0
		var ground := _rng.randf() < 0.55
		if ground:
			_make_bolt(_flash_pos, Vector3(_flash_pos.x + _rng.randf_range(-200, 200), 0.0, _flash_pos.z + _rng.randf_range(-200, 200)))
		var dist := cam.global_position.distance_to(_flash_pos) if cam else 3000.0
		thunder.emit(_flash_pos, dist / 343.0, 1.0 if ground else 0.6)
	if _flash_t < 1.0:
		_flash_t += delta
		var k := 0.0
		if _flash_t < 0.08: k = 1.0
		elif _flash_t < 0.14: k = 0.2
		elif _flash_t < 0.24: k = 0.85
		else: k = max(0.0, 1.0 - (_flash_t - 0.24) * 2.5) * 0.5
		flash = Vector4(_flash_pos.x, _flash_pos.y, _flash_pos.z, k)
		_bolt_light.global_position = _flash_pos
		_bolt_light.light_energy = k * 6.0
	else:
		flash = Vector4.ZERO
		_bolt_light.light_energy = 0.0
	if _bolt.visible:
		_bolt_t -= delta
		if _bolt_t <= 0.0:
			_bolt.visible = false


func _make_bolt(a: Vector3, b: Vector3) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array = [a]
	var n := 24
	for i in range(1, n):
		var t := float(i) / n
		var p := a.lerp(b, t) + Vector3(_rng.randf_range(-60, 60), 0, _rng.randf_range(-60, 60))
		pts.append(p)
	pts.append(b)
	for i in pts.size() - 1:
		var p0: Vector3 = pts[i]
		var p1: Vector3 = pts[i + 1]
		var w := 3.5
		for side in [Vector3(w, 0, 0), Vector3(0, 0, w)]:
			im.surface_add_vertex(p0 - side); im.surface_add_vertex(p0 + side); im.surface_add_vertex(p1 + side)
			im.surface_add_vertex(p0 - side); im.surface_add_vertex(p1 + side); im.surface_add_vertex(p1 - side)
	im.surface_end()
	_bolt.mesh = im
	_bolt.visible = true
	_bolt_t = 0.22
