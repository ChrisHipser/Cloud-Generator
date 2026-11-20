extends Node3D
# Forgiving full 3-axis flight model with weight, lift and momentum, plus ground / swim modes.
# Shift / Ctrl set a throttle (target airspeed, 0..500 m/s). Below ~9 m/s you stall:
# lift fades and the nose drops into the fall.

enum Mode { FLY, GROUND, WATER }

signal splashed(pos: Vector3, power: float)
signal landed(pos: Vector3, power: float)
signal sonic_boom
signal boost_started
signal cloud_enter(power: float)
signal cloud_exit(power: float)
signal footstep(snow: bool)

const CRUISE := 50.0
const MAX_SPEED := 500.0
const BOOST_SPD := 120.0
const SONIC := 343.0
const GRAV := 9.8 * 0.82

var terrain: Node
var field: Node
var fluid: Node
var cam_rig: Node
var model := preload("res://scripts/pilot_model.gd").new()

var mode := Mode.FLY
var vel := Vector3(0, 0, -CRUISE)
var ang := Vector3.ZERO           # pitch, yaw, roll rates (body)
var aim_dir := Vector3.FORWARD    # mouse-steer target
var throttle := CRUISE            # target airspeed (m/s)
var speed := 0.0
var agl := 0.0
var vspeed := 0.0
var gload := 1.0
var boosting := false             # in boost territory (> 120 m/s)
var super_on := false             # past the sound barrier
var super_k := 0.0                # 0..1 eased intensities for fx
var boost_k := 0.0
var stalled := false
var stall_k := 0.0
var in_cloud := false
var cloud_cov := 0.0
var beam_on := false
var force_beam := false
var force_boost := false
var beam_dir := Vector3.FORWARD
var charge := 0.0
var _charging := false
var _launch_grace := 0.0
var facing := 0.0                 # ground yaw
var _ground_vel := Vector3.ZERO
var _step_acc := 0.0
var _foot := 1.0
var _prev_vel := Vector3.ZERO
var _cloud_cool := 0.0
var water_y := 0.0
var _lake_t := 0.0

var trail_l: Array = []
var trail_r: Array = []
var _trail_t := 0.0
var trail_mesh := MeshInstance3D.new()
var beam_mesh := MeshInstance3D.new()
var beam_cyl := CylinderMesh.new()
var ring_mesh := MeshInstance3D.new()
var _ring_t := 9.0
var prints: Array = []
var _print_i := 0
var _print_tex: Texture2D

var tour := false   # automated screenshot tour: ignore the keyboard
var frozen := false # tour: hold position (beam test)


func _ready() -> void:
	add_child(model)
	# contrails
	var tm := StandardMaterial3D.new()
	tm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tm.vertex_color_use_as_albedo = true
	tm.cull_mode = BaseMaterial3D.CULL_DISABLED
	tm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	trail_mesh.material_override = tm
	trail_mesh.top_level = true
	trail_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	trail_mesh.extra_cull_margin = 10000.0
	add_child(trail_mesh)
	# beam: a faint shimmering cone (start radius 1, far radius = cone multiplier)
	var bsh := Shader.new()
	bsh.code = """shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
uniform float power = 1.0;
void fragment() {
	float along = UV.y;
	float f = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.5);
	float wah = 0.6 + 0.4 * sin(TIME * 25.13);
	float n = sin(UV.y * 60.0 - TIME * 30.0 + UV.x * 25.0) * 0.5 + 0.5;
	float a = (0.1 + 0.9 * f * f) * (0.5 + 0.5 * n) * smoothstep(0.0, 0.5, along) * smoothstep(1.0, 0.95, along);
	ALBEDO = vec3(0.75, 0.88, 1.0) * a * power * wah * 0.16;
}"""
	var bm := ShaderMaterial.new()
	bm.shader = bsh
	beam_cyl.top_radius = 1.0
	beam_cyl.bottom_radius = 1.0
	beam_cyl.height = 1.0
	beam_cyl.radial_segments = 20
	beam_cyl.cap_top = false
	beam_cyl.cap_bottom = false
	beam_mesh.mesh = beam_cyl
	beam_mesh.material_override = bm
	beam_mesh.top_level = true
	beam_mesh.visible = false
	beam_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam_mesh)
	# sonic ring
	var tor := TorusMesh.new()
	tor.inner_radius = 0.9
	tor.outer_radius = 1.0
	tor.rings = 32
	ring_mesh.mesh = tor
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = Color(1, 1, 1, 0.0)
	ring_mesh.material_override = rm
	ring_mesh.top_level = true
	ring_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring_mesh)
	_print_tex = _make_print_tex()


func _make_print_tex() -> Texture2D:
	var img := Image.create(32, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 32:
			var u := (x - 15.5) / 16.0
			var v := (y - 31.5) / 32.0
			var sole := pow(u / 0.75, 2) + pow((v + 0.2) / 0.75, 2) < 1.0
			var heel := pow(u / 0.6, 2) + pow((v - 0.65) / 0.3, 2) < 1.0
			var a := 0.0
			if sole or heel:
				a = 0.75
			img.set_pixel(x, y, Color(0.55, 0.62, 0.75, a))
	return ImageTexture.create_from_image(img)


func respawn(pos: Vector3, heading: float) -> void:
	global_position = pos
	global_transform.basis = Basis(Vector3.UP, heading)
	vel = -global_transform.basis.z * CRUISE
	throttle = maxf(throttle, CRUISE) if throttle > 1.0 else CRUISE
	ang = Vector3.ZERO
	aim_dir = -global_transform.basis.z
	mode = Mode.FLY
	model.open = 1.0
	model.prone = 1.0
	trail_l.clear()
	trail_r.clear()
	in_cloud = false
	_cloud_cool = 0.5
	_launch_grace = 0.5
	model.reset_cloth()


func cloud_pos(p: Vector3) -> Vector3:
	return p - Vector3(P.wind.x, 0.0, P.wind.y)


func physics(delta: float) -> void:
	if frozen:
		beam_on = force_beam
		beam_dir = -global_transform.basis.z
		_update_cloud(delta)
		_update_fx(delta)
		model.air_vel = vel
		model.animate(delta)
		return
	_prev_vel = vel
	match mode:
		Mode.FLY:
			_fly(delta)
		Mode.GROUND:
			_ground(delta)
		Mode.WATER:
			_water(delta)
	speed = vel.length()
	vspeed = vel.y
	var acc: Vector3 = (vel - _prev_vel) / maxf(delta, 1e-4) + Vector3(0, 9.8, 0)
	gload = lerpf(gload, acc.dot(global_transform.basis.y) / 9.8, 1.0 - exp(-delta * 6.0))
	agl = global_position.y - max(terrain.height(global_position.x, global_position.z), terrain.water_level(global_position.x, global_position.z))
	_update_cloud(delta)
	_update_fx(delta)
	model.air_vel = vel
	model.animate(delta)


func _inp(a: String) -> float:
	if tour:
		return 0.0
	return 1.0 if Input.is_action_pressed(a) else 0.0


func _fly(dt: float) -> void:
	var b := global_transform.basis.orthonormalized()
	var fwd := -b.z
	var up := b.y
	var right := b.x
	var spd := vel.length()
	model.open = move_toward(model.open, 1.0, dt * 3.0)
	model.prone = move_toward(model.prone, model.open, dt * 3.0)
	model.tuck = move_toward(model.tuck, 0.0, dt * 3.0)
	model.crouch = move_toward(model.crouch, 0.0, dt * 4.0)
	model.run_amt = move_toward(model.run_amt, 0.0, dt * 4.0)
	model.swim = 0.0
	_launch_grace = maxf(_launch_grace - dt, 0.0)

	var pitch_in := (_inp("pitch_up") - _inp("pitch_down"))
	if not P.v.invert_pitch:
		pitch_in = -pitch_in
	var yaw_in := _inp("yaw_left") - _inp("yaw_right")
	var roll_in := _inp("roll_right") - _inp("roll_left")
	var bank := atan2(-right.y, up.y)

	if P.v.mouse_steer:
		var local := b.inverse() * aim_dir
		var pe := atan2(local.y, -local.z)
		var ye := atan2(-local.x, -local.z)
		var want_bank := clampf(-ye * 2.2, -1.1, 1.1)
		pitch_in = clampf(pitch_in + pe * 2.6, -1.0, 1.0)
		yaw_in = clampf(yaw_in + ye * 1.6, -1.0, 1.0)
		if up.y > 0.0:
			roll_in = clampf(roll_in + (want_bank - bank) * 1.8, -1.0, 1.0)
		var off := fwd.angle_to(aim_dir)
		if off > 1.2:
			aim_dir = aim_dir.slerp(fwd, 1.0 - exp(-dt * 2.0)).normalized()

	# control authority: nearly full down to ~12 m/s, only fading as you approach a stall
	var auth := 0.12 + 0.88 * smoothstep(1.5, 12.0, spd)
	var cr: float = P.v.control_rate
	var tp := pitch_in * 1.6 * auth * cr
	var ty := yaw_in * 0.9 * auth * cr
	var tr := roll_in * 2.8 * auth * cr
	# wing auto-level only near upright, never on pitch, never fighting aerobatics
	var al: float = P.v.auto_level
	if absf(roll_in) < 0.1 and absf(bank) < 1.2 and up.y > 0.25:
		tr += -bank * al * 1.5
	ang = ang.lerp(Vector3(tp, ty, tr), 1.0 - exp(-dt * 4.5))

	b = Basis(b.x, ang.x * dt) * b
	b = Basis(b.y, ang.y * dt) * b
	b = Basis(b.z, -ang.z * dt) * b
	# coordinated bank-to-turn; fades out when pointing straight up / down or inverted
	var vert := clampf(1.0 - absf(fwd.y) * 1.15, 0.0, 1.0)
	var turn := -sin(bank) * 0.9 * smoothstep(3.0, 20.0, spd) * model.open * vert
	b = Basis(Vector3.UP, turn * dt) * b
	# stall: below ~9 m/s the nose weathervanes into the airflow (which is falling)
	if not stalled and spd < 8.0:
		stalled = true
	elif stalled and spd > 13.0:
		stalled = false
	stall_k = move_toward(stall_k, 1.0 if stalled else 0.0, dt * 3.0)
	var vane := (1.0 - smoothstep(4.0, 14.0, spd)) * 2.4
	if spd > 0.5 and vane > 0.0:
		var vd := vel / spd
		var ax := (-b.z).cross(vd)
		if ax.length() > 1e-4:
			b = Basis(ax.normalized(), (-b.z).angle_to(vd) * minf(vane * dt, 1.0)) * b
	b = b.orthonormalized()
	global_transform.basis = b
	fwd = -b.z
	up = b.y

	# throttle: shift up, ctrl down (target airspeed)
	if force_boost:
		throttle = 360.0
	elif not tour:
		var rate := 25.0 + throttle * 0.9
		if Input.is_action_pressed("boost"):
			throttle = minf(throttle + rate * dt, MAX_SPEED)
		if Input.is_action_pressed("slow"):
			throttle = maxf(throttle - rate * dt, 0.0)
	var diff := throttle - spd
	var amax := 18.0 + throttle * 0.14
	var thrust := clampf(diff * 0.9, -(6.0 + spd * 0.05), amax)
	vel += fwd * thrust * dt * smoothstep(0.0, 0.5, model.open)

	# gravity, lift and airflow alignment = "air under the wings"
	vel.y -= GRAV * dt
	var lk := smoothstep(4.0, 30.0, spd)
	vel += up * GRAV * lk * model.open * dt
	spd = vel.length()
	if spd > 0.01:
		var vd := vel / spd
		var k := (2.3 + spd * 0.004) * pow(smoothstep(4.0, 30.0, spd), 1.4) * model.open
		var nd := vd.slerp(fwd, 1.0 - exp(-k * dt))
		vel = nd * spd
	if vel.length() > MAX_SPEED * 1.12:
		vel = vel.normalized() * MAX_SPEED * 1.12
	global_position += vel * dt

	# boost territory and the sound barrier
	spd = vel.length()
	if not boosting and spd > BOOST_SPD:
		boosting = true
		boost_started.emit()
		_puff(1.0)
	elif boosting and spd < BOOST_SPD - 20.0:
		boosting = false
	if not super_on and spd > SONIC:
		super_on = true
		_ring_t = 0.0
		sonic_boom.emit()
		_puff(2.2)
	elif super_on and spd < SONIC - 25.0:
		super_on = false
	boost_k = move_toward(boost_k, clampf((spd - 80.0) / 160.0, 0.0, 1.0), dt * 2.0)
	super_k = move_toward(super_k, clampf((spd - 300.0) / 120.0, 0.0, 1.0), dt * 1.5)

	# beam
	beam_on = force_beam or (not tour and (Input.is_action_pressed("beam") or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _mouse_over_ui())))
	beam_dir = aim_dir if P.v.mouse_steer else fwd

	# terrain / water contact
	var gh: float = terrain.height(global_position.x, global_position.z)
	var wl: float = terrain.water_level(global_position.x, global_position.z)
	if wl > gh and global_position.y < wl + 0.2:
		_enter_water(wl)
	elif global_position.y < gh + 0.9:
		if _launch_grace > 0.0 and vel.y > 0.0:
			global_position.y = gh + 0.9
		else:
			_land(gh)


func _puff(pw: float) -> void:
	if fluid and P.v.boost_puff > 0.0:
		var vd := vel.normalized() if vel.length() > 1.0 else -global_transform.basis.z
		fluid.add_event(4, cloud_pos(global_position), vd, pw * P.v.boost_puff, 1.4)


func _mouse_over_ui() -> bool:
	var hov := get_viewport().gui_get_hovered_control()
	return hov != null


func _land(gh: float) -> void:
	var p := global_position
	global_position = Vector3(p.x, gh, p.z)
	var hv := Vector3(vel.x, 0, vel.z)
	landed.emit(global_position, clampf(-vel.y / 20.0 + vel.length() / 120.0, 0.1, 1.5))
	_ground_vel = hv.limit_length(18.0)
	var f := -global_transform.basis.z
	if Vector2(f.x, f.z).length() < 0.05:
		f = global_transform.basis.y
	facing = atan2(-f.x, -f.z)
	vel = _ground_vel
	mode = Mode.GROUND
	super_on = false
	boosting = false
	stalled = false
	beam_on = false


func _enter_water(wl: float) -> void:
	var pw := clampf(vel.length() / 60.0, 0.2, 2.5)
	splashed.emit(Vector3(global_position.x, wl, global_position.z), pw)
	water_y = wl
	vel *= 0.15
	_ground_vel = Vector3(vel.x, 0, vel.z)
	vel.y = 0.0
	var f := -global_transform.basis.z
	if Vector2(f.x, f.z).length() < 0.05:
		f = global_transform.basis.y
	facing = atan2(-f.x, -f.z)
	mode = Mode.WATER
	super_on = false
	boosting = false
	stalled = false
	beam_on = false


func _move_input() -> Vector3:
	var x := _inp("yaw_right") - _inp("yaw_left")
	var z := _inp("pitch_down") - _inp("pitch_up")   # W forward, S back on foot
	var cy: float = cam_rig.yaw if cam_rig else facing
	var v := Vector3(x, 0, -z)
	if v.length() > 1.0:
		v = v.normalized()
	return Basis(Vector3.UP, cy) * v


func _ground(dt: float) -> void:
	model.open = move_toward(model.open, 0.0, dt * 2.5)
	model.prone = move_toward(model.prone, 0.0, dt * 4.0)
	model.tuck = move_toward(model.tuck, 0.0, dt * 4.0)
	model.swim = 0.0
	var mv := _move_input()
	var sprint := not tour and Input.is_action_pressed("boost")
	var top := 15.0 if sprint else 7.0
	_ground_vel = _ground_vel.lerp(mv * top, 1.0 - exp(-dt * (6.0 if mv.length() > 0.1 else 3.0)))
	var hs := _ground_vel.length()
	if hs > 0.5:
		var want := atan2(-_ground_vel.x, -_ground_vel.z)
		facing = lerp_angle(facing, want, 1.0 - exp(-dt * 10.0))
	var p := global_position + _ground_vel * dt
	var gh: float = terrain.height(p.x, p.z)
	p.y = gh
	var wl: float = terrain.water_level(p.x, p.z)
	global_position = p
	global_transform.basis = Basis(Vector3.UP, facing)
	vel = _ground_vel
	model.run_amt = move_toward(model.run_amt, clampf(hs / 7.0, 0.0, 1.3), dt * 5.0)
	model.run_phase += dt * (6.0 + hs * 0.75)
	_step_acc += hs * dt
	var stride := 1.4 if sprint else 0.85
	if _step_acc > stride:
		_step_acc = 0.0
		_foot = -_foot
		var snow: bool = terrain.is_snow(p.x, p.z)
		footstep.emit(snow)
		if snow:
			_footprint(p + global_transform.basis.x * 0.17 * _foot)
	if wl > gh + 0.6:
		_enter_water(wl)
		return
	_jump_input(dt)


func _jump_input(dt: float) -> void:
	var held := not tour and Input.is_action_pressed("beam")
	if held:
		_charging = true
		charge = min(charge + dt / 1.1, 1.0)
		model.crouch = move_toward(model.crouch, 0.4 + charge * 0.6, dt * 4.0)
		if charge >= 1.0:
			_launch(1.0)   # fully charged: you're flung into the sky
	elif _charging:
		_launch(charge)
	else:
		model.crouch = move_toward(model.crouch, 0.0, dt * 4.0)


func _launch(k: float) -> void:
	# k < ~0.35 is a hop; anything more and the wings snap open and you fly off
	_charging = false
	var fwd := Basis(Vector3.UP, facing) * Vector3.FORWARD
	var hop := k < 0.3
	vel = Vector3(0, 8.0 + k * 42.0, 0) + fwd * (6.0 + _ground_vel.length() * 0.8 + k * 26.0)
	global_position.y += 1.0
	var b := Basis(Vector3.UP, facing)
	b = Basis(b.x, 0.25 + k * 0.35) * b
	global_transform.basis = b
	ang = Vector3.ZERO
	aim_dir = -b.z
	mode = Mode.FLY
	model.crouch = 0.0
	charge = 0.0
	if hop:
		model.open = 0.0
		model.tuck = 1.0
		_launch_grace = 0.0
	else:
		model.open = 0.6
		model.tuck = 0.4
		throttle = maxf(throttle, CRUISE)
		_launch_grace = 1.5


func _water(dt: float) -> void:
	model.open = move_toward(model.open, 0.0, dt * 3.0)
	model.prone = move_toward(model.prone, 0.6, dt * 2.0)
	model.swim = move_toward(model.swim, 1.0, dt * 2.0)
	model.run_amt = 0.0
	var mv := _move_input()
	_ground_vel = _ground_vel.lerp(mv * 3.2, 1.0 - exp(-dt * 1.5))
	var hs := _ground_vel.length()
	if hs > 0.3:
		facing = lerp_angle(facing, atan2(-_ground_vel.x, -_ground_vel.z), 1.0 - exp(-dt * 4.0))
	_lake_t += dt
	var p := global_position + _ground_vel * dt
	p.y = water_y - 0.55 + sin(_lake_t * 1.7) * 0.12
	var gh: float = terrain.height(p.x, p.z)
	if gh > water_y - 0.3:
		mode = Mode.GROUND
		model.swim = 0.0
	global_position = p
	global_transform.basis = Basis(Vector3.UP, facing)
	vel = _ground_vel
	_jump_input(dt)
	if mode == Mode.FLY:
		splashed.emit(Vector3(p.x, water_y, p.z), 0.6)


func _footprint(p: Vector3) -> void:
	var d: Decal
	if prints.size() < 300:
		d = Decal.new()
		d.texture_albedo = _print_tex
		d.size = Vector3(0.22, 0.6, 0.4)
		d.top_level = true
		d.upper_fade = 0.3
		d.lower_fade = 0.3
		get_parent().add_child(d)
		prints.append(d)
	else:
		d = prints[_print_i]
		_print_i = (_print_i + 1) % prints.size()
	d.global_transform = Transform3D(Basis(Vector3.UP, facing), p + Vector3(0, 0.1, 0))


func _update_cloud(dt: float) -> void:
	if field == null or not field.ready_ok:
		return
	var pc := cloud_pos(global_position)
	cloud_cov = field.coverage(pc)
	var now := cloud_cov > 0.55
	_cloud_cool -= dt
	if fluid:
		fluid.player_pos = pc
		var w: Vector2 = Vector2(4.0, 1.6) * P.v.drift
		fluid.player_vel = vel - Vector3(w.x, 0, w.y)
		fluid.player_right = global_transform.basis.x
		fluid.beam_on = beam_on and mode == Mode.FLY
		fluid.beam_dir = beam_dir
		fluid.beam_start = pc + beam_dir * 3.0
		fluid.beam_len = P.v.beam_len
	if now != in_cloud and _cloud_cool <= 0.0:
		in_cloud = now
		_cloud_cool = 0.25
		var pw := clampf(speed / 55.0, 0.25, 2.8)
		var vd := vel.normalized() if speed > 1.0 else -global_transform.basis.z
		if fluid:
			if now:
				fluid.add_event(1, pc, vd, pw, 0.9)
				cloud_enter.emit(pw)
			else:
				fluid.add_event(2, pc, vd, pw, 1.0)
				fluid.add_event(3, pc, vd, pw * 1.3, 1.6)
				cloud_exit.emit(pw)


func _update_fx(dt: float) -> void:
	# contrails from the wingtips
	_trail_t += dt
	if _trail_t > 0.025:
		_trail_t = 0.0
		var a := clampf((speed - 30.0) / 60.0, 0.0, 1.0) * model.open if mode == Mode.FLY else 0.0
		trail_l.push_front([model.tip_l.global_position, a])
		trail_r.push_front([model.tip_r.global_position, a])
		if trail_l.size() > 90:
			trail_l.pop_back()
			trail_r.pop_back()
	_draw_trails()
	# beam visual (a cone: radius at the far end = beam_cone x start radius)
	beam_mesh.visible = beam_on and mode == Mode.FLY
	if beam_mesh.visible:
		var len: float = P.v.beam_len
		var cone: float = P.v.beam_cone
		if absf(beam_cyl.bottom_radius - cone) > 0.01:
			beam_cyl.bottom_radius = cone
		var s := global_position + beam_dir * 3.0
		var y := beam_dir
		var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
		var z := x.cross(y)
		var r: float = P.v.beam_radius * 0.3
		beam_mesh.global_transform = Transform3D(Basis(x * r, -y * len, z * r), s + y * len * 0.5)
		(beam_mesh.material_override as ShaderMaterial).set_shader_parameter("power", clampf(0.6 + P.v.beam_power * 0.25, 0.6, 2.2))
	# sonic ring
	_ring_t += dt
	var rm := ring_mesh.material_override as StandardMaterial3D
	if _ring_t < 1.2:
		ring_mesh.visible = true
		var rr := 3.0 + _ring_t * 90.0
		var vd := vel.normalized()
		var x2 := vd.cross(Vector3.UP).normalized()
		if x2.length() < 0.1:
			x2 = Vector3.RIGHT
		var y2 := x2.cross(vd)
		ring_mesh.global_transform = Transform3D(Basis(x2 * rr, vd * rr * 0.3, y2 * rr), global_position - vd * (_ring_t * 30.0))
		rm.albedo_color = Color(1, 1, 1, 0.5 * (1.0 - _ring_t / 1.2))
	else:
		ring_mesh.visible = false
	model.flex = clampf(gload - 1.0, -1.0, 2.0)
	model.bank_flex = ang.z * 0.2


func _draw_trails() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var im := ImmediateMesh.new()
	var any := false
	for tr in [trail_l, trail_r]:
		if tr.size() < 2:
			continue
		any = true
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in tr.size():
			var p: Vector3 = tr[i][0]
			var a: float = tr[i][1]
			var age: float = float(i) / float(tr.size())
			var nxt: Vector3 = tr[mini(i + 1, tr.size() - 1)][0]
			var d: Vector3 = (p - nxt)
			if d.length() < 0.001:
				d = Vector3.FORWARD
			var to_cam: Vector3 = cam.global_position - p
			var side: Vector3 = d.cross(to_cam).normalized()
			var w: float = 0.04 + age * 0.4
			# fade where the trail passes the camera so it never smears across the screen
			var cf: float = smoothstep(8.0, 45.0, to_cam.length())
			var al: float = a * (1.0 - age) * 0.45 * cf
			im.surface_set_color(Color(1, 1, 1, al))
			im.surface_add_vertex(p - side * w)
			im.surface_set_color(Color(1, 1, 1, al))
			im.surface_add_vertex(p + side * w)
		im.surface_end()
	trail_mesh.mesh = im if any else null
