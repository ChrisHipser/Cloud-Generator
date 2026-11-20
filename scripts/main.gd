extends Node3D
# Builds and wires the whole world. Run with `-- --shots` for an automated
# screenshot + performance tour (writes PNGs into res://shots).

const CloudField = preload("res://scripts/cloud_field.gd")
const Fluid = preload("res://scripts/fluid.gd")
const Terrain = preload("res://scripts/terrain.gd")
const SkyEnv = preload("res://scripts/sky_env.gd")
const Player = preload("res://scripts/player.gd")
const Rig = preload("res://scripts/camera_rig.gd")
const Hud = preload("res://scripts/hud.gd")
const Birds = preload("res://scripts/birds.gd")
const Audio = preload("res://scripts/audio.gd")
const Impostors = preload("res://scripts/impostors.gd")

var field: Node
var fluid: Node
var terrain: Node3D
var sky: Node3D
var player: Node3D
var rig: Node3D
var hud: CanvasLayer
var birds: Node3D
var audio: Node
var impostors: MultiMeshInstance3D
var clouds := MeshInstance3D.new()
var cloud_mat := ShaderMaterial.new()
var ocean := MeshInstance3D.new()
var ocean_mat := ShaderMaterial.new()
var lake_mats: Array = []
var splash_fx: GPUParticles3D
var dust_fx: GPUParticles3D
var _imp_t := 0.0
var _incloud := 0.0
var _spawned := false
var _shots := false
var _shot_state := {}


func _ready() -> void:
	_setup_input()
	_shots = "--shots" in OS.get_cmdline_user_args()
	field = CloudField.new()
	add_child(field)
	fluid = Fluid.new()
	fluid.field = field
	add_child(fluid)
	sky = SkyEnv.new()
	sky.field = field
	add_child(sky)
	terrain = Terrain.new()
	add_child(terrain)
	terrain.generated.connect(_on_terrain)
	player = Player.new()
	player.terrain = terrain
	player.field = field
	player.fluid = fluid
	add_child(player)
	rig = Rig.new()
	rig.player = player
	rig.terrain = terrain
	add_child(rig)
	player.cam_rig = rig
	birds = Birds.new()
	birds.field = field
	birds.player = player
	birds.terrain = terrain
	add_child(birds)
	audio = Audio.new()
	audio.player = player
	audio.field = field
	audio.sky = sky
	add_child(audio)
	hud = Hud.new()
	hud.player = player
	hud.rig = rig
	hud.sky = sky
	hud.fluid = fluid
	hud.field = field
	add_child(hud)
	impostors = Impostors.new()
	impostors.field = field
	add_child(impostors)

	# fullscreen cloud raymarch quad
	cloud_mat.shader = load("res://shaders/clouds.gdshader")
	cloud_mat.render_priority = -10
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	q.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	clouds.mesh = q
	clouds.material_override = cloud_mat
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clouds.extra_cull_margin = 16384.0
	add_child(clouds)

	# ocean
	ocean_mat.shader = load("res://shaders/water.gdshader")
	ocean.mesh = _polar_mesh(48, 72, 3.0, 45000.0)
	ocean.material_override = ocean_mat
	ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ocean.extra_cull_margin = 50000.0
	add_child(ocean)
	_shared_textures(ocean_mat)
	_shared_textures(cloud_mat)
	_shared_textures(terrain.mat)
	cloud_mat.set_shader_parameter("fluid_tex", fluid.dens_tex)
	sky.sky_mat.set_shader_parameter("noise_tex", field.noise_tex)
	impostors.mat.set_shader_parameter("noise_tex", field.noise_tex)

	splash_fx = _burst(Color(0.9, 0.95, 1.0, 0.8), 160, 14.0, 0.25)
	dust_fx = _burst(Color(0.75, 0.7, 0.62, 0.6), 60, 4.0, 0.4)

	player.splashed.connect(_on_splash)
	player.landed.connect(_on_land)
	player.sonic_boom.connect(func():
		audio.boom()
		rig.kick = 1.0
		rig.shake = 0.6)
	player.boost_started.connect(func():
		audio.boost()
		rig.kick = 0.45
		rig.shake = max(rig.shake, 0.12))
	player.cloud_enter.connect(func(pw):
		audio.whoosh(pw)
		rig.shake = max(rig.shake, 0.08 * pw))
	player.cloud_exit.connect(func(pw):
		audio.whoosh(pw * 0.8)
		rig.shake = max(rig.shake, 0.05 * pw))
	player.footstep.connect(func(snow): audio.step(snow))
	sky.thunder.connect(func(pos, delay, pw):
		audio.thunder(pos, delay, pw)
		if delay < 4.0:
			rig.shake = max(rig.shake, 0.15 * pw))
	birds.bird_call.connect(func(pos, sp): audio.bird(pos, sp))
	field.baked.connect(func(): impostors.refresh(rig.global_position))
	P.changed.connect(_on_param)

	player.respawn(Vector3(0, 700, 2500), 0.0)
	_apply_vsync()
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	get_viewport().scaling_3d_scale = P.v.render_scale
	get_viewport().fsr_sharpness = 0.4
	if _shots:
		sky.time_frozen = true
		player.tour = true
	field.generate.call_deferred()
	if "--reload-test" in OS.get_cmdline_user_args():
		# self-test for F2: reload the world once, then quit
		var n: int = P.get_meta("reloads", 0)
		get_tree().create_timer(5.0).timeout.connect(func():
			if n == 0:
				P.set_meta("reloads", 1)
				get_tree().reload_current_scene()
			else:
				print("RELOAD OK  buses=%d" % AudioServer.bus_count)
				get_tree().quit())


func _shared_textures(m: ShaderMaterial) -> void:
	m.set_shader_parameter("sdf_tex", field.sdf_tex)
	m.set_shader_parameter("noise_tex", field.noise_tex)
	m.set_shader_parameter("sdf_dom", field.dom)
	m.set_shader_parameter("height_tex", terrain.height_tex)
	m.set_shader_parameter("terrain_size", terrain.SIZE)


func _on_terrain() -> void:
	for l in terrain.lakes:
		var mi := MeshInstance3D.new()
		mi.mesh = _polar_mesh(10, 40, 1.5, l.r * 1.05)
		var m := ocean_mat.duplicate() as ShaderMaterial
		m.set_shader_parameter("level", l.level)
		m.set_shader_parameter("wave_amp", 0.18)
		mi.material_override = m
		mi.position = Vector3(l.pos.x, 0, l.pos.y)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 200.0
		add_child(mi)
		lake_mats.append(m)
	if not _spawned:
		_spawned = true
		var gh: float = terrain.height(0, 2500)
		player.respawn(Vector3(0, max(gh + 450.0, 700.0), 2500), 0.0)


func _polar_mesh(rings: int, segs: int, r0: float, r1: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_vertex(Vector3.ZERO)
	var k := pow(r1 / r0, 1.0 / (rings - 1))
	for i in rings:
		var r := r0 * pow(k, i)
		for j in segs:
			var a := j * TAU / segs
			st.add_vertex(Vector3(cos(a) * r, 0, sin(a) * r))
	for j in segs:
		st.add_index(0)
		st.add_index(1 + (j + 1) % segs)
		st.add_index(1 + j)
	for i in rings - 1:
		for j in segs:
			var a := 1 + i * segs + j
			var b := 1 + i * segs + (j + 1) % segs
			var c := a + segs
			var d := b + segs
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	var m := st.commit()
	m.custom_aabb = AABB(Vector3(-r1, -50, -r1), Vector3(r1 * 2, 100, r1 * 2))
	return m


func _burst(col: Color, amount: int, vel: float, size: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 60.0
	pm.initial_velocity_min = vel * 0.4
	pm.initial_velocity_max = vel
	pm.gravity = Vector3(0, -9.8, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 1.5
	pm.scale_min = 0.5
	pm.scale_max = 1.5
	p.process_material = pm
	p.amount = amount
	p.one_shot = true
	p.explosiveness = 0.95
	p.lifetime = 1.6
	p.emitting = false
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_color = col
	q.material = m
	p.draw_pass_1 = q
	p.visibility_aabb = AABB(Vector3(-50, -50, -50), Vector3(100, 100, 100))
	add_child(p)
	return p


func _on_splash(pos: Vector3, pw: float) -> void:
	splash_fx.global_position = pos
	(splash_fx.process_material as ParticleProcessMaterial).initial_velocity_max = 6.0 + pw * 10.0
	splash_fx.restart()
	splash_fx.emitting = true
	audio.splash(pw)
	var t := Time.get_ticks_msec() / 1000.0
	for m in lake_mats + [ocean_mat]:
		m.set_shader_parameter("ripple", Vector3(pos.x, pos.z, t))
	rig.shake = max(rig.shake, 0.2 * pw)


func _on_land(pos: Vector3, pw: float) -> void:
	dust_fx.global_position = pos
	var snow: bool = terrain.is_snow(pos.x, pos.z)
	((dust_fx.draw_pass_1 as QuadMesh).material as StandardMaterial3D).albedo_color = Color(0.95, 0.97, 1.0, 0.8) if snow else Color(0.72, 0.66, 0.56, 0.6)
	dust_fx.restart()
	dust_fx.emitting = true
	audio.land(pw)
	rig.shake = max(rig.shake, 0.12 * pw)


func _on_param(n: String, cat: String) -> void:
	if n == "render_scale":
		get_viewport().scaling_3d_scale = P.v.render_scale
	elif n == "vsync":
		_apply_vsync()
	elif n == "far_range" or n == "impostors":
		impostors.refresh(rig.global_position)


func _apply_vsync() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if P.v.vsync else DisplayServer.VSYNC_DISABLED)


# ------------------------------------------------------------------ input

func _key(action: String, key: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	elif not InputMap.action_get_events(action).is_empty():
		return   # already bound (F2 reload)
	var e := InputEventKey.new()
	e.physical_keycode = key
	InputMap.action_add_event(action, e)


func _setup_input() -> void:
	_key("pitch_down", KEY_W)
	_key("pitch_up", KEY_S)
	_key("yaw_left", KEY_A)
	_key("yaw_right", KEY_D)
	_key("roll_left", KEY_Q)
	_key("roll_right", KEY_E)
	_key("boost", KEY_SHIFT)
	_key("slow", KEY_CTRL)
	_key("beam", KEY_SPACE)


func _unhandled_input(e: InputEvent) -> void:
	if _shots:
		return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not rig.dragging:
		# aim rotates about the camera's own axes: no limits, loops and inverted flight work
		var s: float = P.v.mouse_sens * 0.0018
		var cb: Basis = rig.cam.global_transform.basis
		var d: Vector3 = player.aim_dir
		d = d.rotated(cb.y.normalized(), -e.relative.x * s)
		d = d.rotated(cb.x.normalized(), -e.relative.y * s)
		player.aim_dir = d.normalized()
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.physical_keycode:
		KEY_C:
			hud.show_toast(rig.cycle_view())
		KEY_T:
			rig.reset_view()
			hud.show_toast("Camera reset")
		KEY_N:
			sky.advance_hours(1.5)
			hud.show_toast("%02d:%02d" % [int(sky.hour), int(fmod(sky.hour, 1.0) * 60.0)])
		KEY_K:
			hud.set_sound(not hud.sound_open)
		KEY_F2:
			P.save()
			get_tree().reload_current_scene()
		KEY_V:
			sky.roll_weather()
			hud.show_toast("New weather")
		KEY_M:
			P.setv("mouse_steer", not P.v.mouse_steer)
			player.aim_dir = -player.global_transform.basis.z
			hud.show_toast("Mouse steering " + ("on" if P.v.mouse_steer else "off"))
		KEY_O:
			hud.set_options(not hud.options_open)
		KEY_H:
			hud.toggle_keys()
		KEY_F1:
			hud.set_hud_visible(not hud.hud_visible)
		KEY_F11:
			var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)
		KEY_R:
			var p := player.global_position
			player.respawn(Vector3(p.x, P.v.deck_alt + P.v.deck_thick + 250.0, p.z), rig.yaw)
			hud.show_toast("Respawned above the deck")
		KEY_1, KEY_2, KEY_3, KEY_4:
			var i: int = e.physical_keycode - KEY_1
			P.apply_preset(i)
			hud.show_toast("Quality: " + P.PRESETS[i].name)


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	var want_capture: bool = P.v.mouse_steer and not hud.any_panel_open() and not get_tree().paused
	var mm := Input.MOUSE_MODE_CAPTURED if want_capture else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != mm and not _shots:
		Input.mouse_mode = mm
	if not terrain.ready_ok:
		return
	if _shots:
		_shot_tour(delta)
	player.physics(delta)
	rig.update(delta)
	var cp: Vector3 = rig.global_position
	terrain.update_view(cp)
	ocean.global_position = Vector3(cp.x, 0, cp.z)
	fluid.step(delta)
	birds.update(delta)
	# camera-in-cloud amount, eased so the view never flickers light / dark
	var cm := 0.0
	if field.ready_ok:
		cm = field.coverage(cp - Vector3(sky.wind.x, 0, sky.wind.y))
	var tgt := smoothstep(0.2, 0.5, cm)
	_incloud = lerpf(_incloud, tgt, 1.0 - exp(-delta * (4.0 if tgt > _incloud else 1.4)))
	cloud_mat.set_shader_parameter("incloud_s", _incloud if _incloud > 0.003 else 0.0)
	cloud_mat.set_shader_parameter("cam_m", cm)
	_update_cloud_uniforms()
	var t := Time.get_ticks_msec() / 1000.0
	ocean_mat.set_shader_parameter("time_s", t)
	for m in lake_mats:
		m.set_shader_parameter("time_s", t)
	_imp_t += delta
	if _imp_t > 1.0:
		_imp_t = 0.0
		impostors.visible = P.v.impostors
		if P.v.impostors:
			impostors.refresh(cp)


func _update_cloud_uniforms() -> void:
	var m := cloud_mat
	for k in ["puff", "billow_scale", "detail", "tendril", "edge_soft", "transparency", "mist", "reflectivity", "silver", "solidness", "shadow_dark", "step_scale", "far_range", "transition"]:
		m.set_shader_parameter(k, P.v[k])
	m.set_shader_parameter("fullness", P.v.density)
	m.set_shader_parameter("steps", int(P.v.steps))
	m.set_shader_parameter("light_q", int(P.v.light_q))
	m.set_shader_parameter("fluid_on", 1.0 if P.v.fluid_on else 0.0)
	m.set_shader_parameter("fluid_origin", fluid.origin)
	m.set_shader_parameter("fluid_extent", fluid.extent())
	m.set_shader_parameter("player_pos", player.global_position)
	m.set_shader_parameter("player_right", player.global_transform.basis.x)
	m.set_shader_parameter("time_s", Time.get_ticks_msec() / 1000.0)
	m.set_shader_parameter("flash", sky.flash)
	m.set_shader_parameter("sdf_soft", field.sdf_soft)
	# storms (cloud space, nearest tiled copy to the camera)
	var cam := rig.global_position - Vector3(sky.wind.x, 0, sky.wind.y)
	var arr: Array = []
	for s in field.storms:
		var x: float = s.pos.x + round((cam.x - s.pos.x) / field.dom.x) * field.dom.x
		var z: float = s.pos.z + round((cam.z - s.pos.z) / field.dom.z) * field.dom.z
		arr.append(Vector4(x, z, s.r * 0.8, s.pos.y))
	while arr.size() < 6:
		arr.append(Vector4.ZERO)
	m.set_shader_parameter("storms", arr.slice(0, 6))
	m.set_shader_parameter("storm_n", min(field.storms.size(), 6))


# ------------------------------------------------------------------ screenshot tour

func _shot_tour(delta: float) -> void:
	var s := _shot_state
	if s.is_empty():
		s.i = -1
		s.wait = 2.5
		s.fps = []
		var dir := ProjectSettings.globalize_path("res://shots")
		DirAccess.make_dir_recursive_absolute(dir)
		var only: String = ""
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--only="):
				only = a.substr(7)
		s.list = [
			{"name": "01_morning_cumulus", "hour": 8.5, "near": 3, "dist": 900.0, "pitch": 0.02},
			{"name": "02_noon_above_deck", "hour": 12.5, "pos": Vector3(0, 2480, 0), "yaw": 0.8, "pitch": -0.12, "clear": true},
			{"name": "03_golden_hour", "hour": 17.3, "near": 7, "dist": 1100.0, "pitch": 0.0},
			{"name": "04_sunset_deck", "hour": 17.85, "pos": Vector3(-2000, 2420, 1000), "yaw": 1.2, "pitch": -0.06, "clear": true, "face_sun": true},
			{"name": "05_night_stars", "hour": 23.0, "pos": Vector3(0, 2500, 0), "yaw": 0.3, "pitch": 0.45, "clear": true},
			{"name": "06_low_terrain", "hour": 10.0, "pos": Vector3(-3000, 0, 3000), "agl": 320.0, "yaw": -0.6, "pitch": -0.1, "clear": true},
			{"name": "07_in_cloud", "hour": 14.0, "incloud": 5},
			{"name": "07b_in_cloud_nofluid", "hour": 14.0, "incloud": 5, "params": {"fluid_on": false}},
			{"name": "08a_before_beam", "hour": 13.0, "near": 11, "dist": 40.0, "pitch": 0.0, "freeze": true},
			{"name": "08b_beam_hole", "hour": 13.0, "near": 11, "dist": 40.0, "pitch": 0.0, "beam": true, "freeze": true},
			{"name": "09_first_person", "hour": 15.5, "near": 2, "dist": 1500.0, "pitch": 0.0, "fp": true},
			{"name": "10_thunderhead", "hour": 15.0, "storm": true, "dist": 3800.0},
			{"name": "11_sonic_boost", "hour": 9.5, "near": 4, "dist": 600.0, "pitch": 0.0, "boost": true},
			{"name": "12_landed", "hour": 11.0, "pos": Vector3(-3000, 0, 3000), "agl": 25.0, "yaw": -0.6, "pitch": -0.7},
			{"name": "13_lake_splash", "hour": 11.5, "lake": true, "pitch": -0.8},
			{"name": "14_snow_peak", "hour": 12.0, "snow": true, "pitch": -0.9},
			{"name": "15_options_open", "hour": 16.0, "near": 9, "dist": 1300.0, "pitch": 0.05, "options": true},
			{"name": "16_banked_hud", "hour": 7.2, "near": 6, "dist": 1500.0, "pitch": 0.15, "roll": 0.6},
			{"name": "17_shadow_glory", "hour": 9.0, "glory": true, "fp": true, "nohud": true},
			{"name": "18_pilot_closeup", "hour": 16.5, "near": 4, "dist": 1400.0, "pitch": 0.0, "cam": Vector3(4.2, 2.3, 0.18)},
			{"name": "19_supersonic_ribbon", "hour": 10.5, "pos": Vector3(3000, 2450, -2000), "clear": true, "boost": true, "cam": Vector3(6.0, 0.6, 0.25)},
		]
		if only != "":
			s.list = s.list.filter(func(x): return x.name.begins_with(only))
	s.wait -= delta
	if s.wait > 0.0:
		if s.i >= 0:
			s.fps.append(Engine.get_frames_per_second())
		return
	if s.i >= 0:
		var img := get_viewport().get_texture().get_image()
		var path := ProjectSettings.globalize_path("res://shots/%s.png" % s.list[s.i].name)
		img.save_png(path)
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		print("SHOT %s fps=%d gpu=%.2fms cpu=%.2fms" % [s.list[s.i].name, Engine.get_frames_per_second(), gpu, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
		fluid.debug_dump()
	s.i += 1
	if s.i >= s.list.size():
		print("TOUR DONE")
		get_tree().quit()
		return
	var sh: Dictionary = s.list[s.i]
	P.setv("fluid_on", true)
	for k in sh.get("params", {}):
		P.setv(k, sh.params[k])
	sky.hour = sh.hour
	var wo := Vector3(sky.wind.x, 0, sky.wind.y)
	var pos: Vector3 = sh.get("pos", Vector3.ZERO)
	var yaw: float = sh.get("yaw", 0.0)
	var cum: Array = field.clusters.filter(func(c): return not c.storm)
	if sh.has("near") and not cum.is_empty():
		var c: Dictionary = cum[int(sh.near) % cum.size()]
		var tgt: Vector3 = c.pos + wo
		var away := Vector3(cos(sh.near * 1.7), 0, sin(sh.near * 1.7))
		pos = tgt + away * (c.r + sh.dist)
		pos.y = tgt.y
		var d := tgt - pos
		yaw = atan2(-d.x, -d.z)
	if sh.has("incloud") and not cum.is_empty():
		var c: Dictionary = cum[int(sh.incloud) % cum.size()]
		pos = c.pos + wo
	if sh.get("storm", false) and not field.storms.is_empty():
		var st: Dictionary = field.storms[0]
		var tgt: Vector3 = st.pos + wo + Vector3(0, 1200, 0)
		pos = tgt + Vector3(sh.dist, 300, sh.dist * 0.3)
		var d := tgt - pos
		yaw = atan2(-d.x, -d.z)
	if sh.get("glory", false) and not cum.is_empty():
		# hover up-sun of a cloud top, looking down along the shadow line
		var c: Dictionary = cum[3 % cum.size()]
		var sd: Vector3 = sky.sun_dir_for(sh.hour)
		var top: Vector3 = c.pos + wo + Vector3(0, c.h * 0.5, 0)
		pos = top + sd * 260.0
		yaw = atan2(sd.x, sd.z)
		sh["pitch"] = asin(clampf(-sd.y, -1.0, 1.0))
		sh["freeze"] = true
	if sh.get("face_sun", false):
		var sd: Vector3 = sky.sun_dir_for(sh.hour)
		yaw = atan2(-sd.x, -sd.z)
	if sh.get("lake", false) and not terrain.lakes.is_empty():
		var l: Dictionary = terrain.lakes[0]
		pos = Vector3(l.pos.x, l.level + 18.0, l.pos.y) - Vector3(-sin(yaw), 0, -cos(yaw)) * 20.0
	if sh.get("snow", false):
		# find the highest snowy spot near the island centre
		var best := Vector3(0, -1e9, 0)
		for k in 400:
			var q := Vector3(randf_range(-6000, 6000), 0, randf_range(-6000, 6000))
			var h: float = terrain.height(q.x, q.z)
			if h > best.y and terrain.is_snow(q.x, q.z):
				best = Vector3(q.x, h, q.z)
		if best.y > -1e8:
			pos = best + Vector3(0, 14, 0)
	if sh.has("agl"):
		pos.y = terrain.height(pos.x, pos.z) + sh.agl
	if sh.get("clear", false):
		for k in 60:
			if field.coverage(pos - wo) < 0.02 and field.coverage(pos - wo + Vector3(0, 150, 0)) < 0.02:
				break
			pos += Vector3(310, 0, 170)
			if sh.has("agl"):
				pos.y = terrain.height(pos.x, pos.z) + sh.agl
	var gh: float = terrain.height(pos.x, pos.z)
	if not (sh.has("agl") or sh.has("lake") or sh.has("snow")):
		pos.y = max(pos.y, gh + 60.0)
	player.respawn(pos, yaw)
	var b := Basis(Vector3.UP, yaw)
	player.global_transform.basis = Basis(b.x, sh.get("pitch", 0.0)) * b
	player.vel = -player.global_transform.basis.z * 50.0
	player.force_beam = sh.get("beam", false)
	player.frozen = sh.get("freeze", false)
	player.force_boost = sh.get("boost", false)
	player.throttle = 50.0
	if sh.get("boost", false):
		player.vel = -player.global_transform.basis.z * 330.0
	rig.set_view(0 if sh.get("fp", false) else 1)
	rig.reset_view()
	rig.dist = 10.0
	if sh.has("cam"):
		# free camera at (distance, yaw offset from heading, pitch)
		rig.set_view(2)
		rig.dist = sh.cam.x
		rig.orbit_yaw = yaw + sh.cam.y
		rig.orbit_pitch = sh.cam.z
	hud.set_options(sh.get("options", false))
	hud.set_hud_visible(not sh.get("nohud", false))
	if sh.has("roll"):
		player.global_transform.basis = Basis(-player.global_transform.basis.z, sh.roll) * player.global_transform.basis
	print("  shot %s at %s yaw %.2f cov %.2f" % [sh.name, str(pos.round()), yaw, field.coverage(pos - wo)])
	s.wait = 2.5
