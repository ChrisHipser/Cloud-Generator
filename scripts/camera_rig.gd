extends Node3D
# Cameras: first person, chase (follows you fully, even upside down) and a free orbit.
# Middle-drag looks around in third person: chase springs back on release, free stays put.
# Scroll zooms, Alt + scroll changes the field of view, T resets the view.

enum View { FPV, CHASE, FREE }

var player: Node3D
var terrain: Node
var cam := Camera3D.new()
var view := View.CHASE
var first := false
var dist := 10.0
var yaw := 0.0                  # heading used for on-foot movement
var orbit_yaw := 0.0
var orbit_pitch := 0.0
var dragging := false
var shake := 0.0
var kick := 0.0
var _t := 0.0
var _off := Vector3(0, 3, 10)
var _frame := Basis()
var _basis := Basis()
var _pos := Vector3.ZERO
var motes := GPUParticles3D.new()

const VIEW_NAMES := ["First person", "Chase camera", "Free camera  (middle-drag to orbit)"]


func _ready() -> void:
	cam.near = 0.08
	cam.far = 70000.0
	cam.fov = P.v.fov
	add_child(cam)
	cam.current = true
	# world-space motes: the parallax of drifting specks sells speed
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(45, 30, 45)
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 1.0
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	motes.process_material = pm
	motes.amount = 700
	motes.lifetime = 2.5
	motes.local_coords = false
	motes.visibility_aabb = AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))
	var q := QuadMesh.new()
	q.size = Vector2(0.07, 0.07)
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mm.albedo_color = Color(1, 1, 1, 0.35)
	mm.vertex_color_use_as_albedo = true
	q.material = mm
	motes.draw_pass_1 = q
	motes.position = Vector3(0, 0, -35)
	cam.add_child(motes)


func _unhandled_input(e: InputEvent) -> void:
	if player and player.tour:
		return
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = e.pressed and view != View.FPV
			get_viewport().set_input_as_handled()
		elif e.pressed and (e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var up: bool = e.button_index == MOUSE_BUTTON_WHEEL_UP
			if e.alt_pressed:
				P.setv("fov", clampf(P.v.fov + (-3.0 if up else 3.0), 30.0, 110.0))
			else:
				dist = maxf(dist * 0.88, 3.5) if up else minf(dist * 1.14, 320.0)
			get_viewport().set_input_as_handled()
	elif e is InputEventMouseMotion and dragging:
		orbit_yaw -= e.relative.x * 0.006
		orbit_pitch = clampf(orbit_pitch - e.relative.y * 0.006, -1.5, 1.5)
		get_viewport().set_input_as_handled()


func cycle_view() -> String:
	set_view((view + 1) % 3)
	return VIEW_NAMES[view]


func set_view(v: int) -> void:
	var was := view
	view = v as View
	first = view == View.FPV
	player.model.set_first_person(first)
	dragging = false
	if view == View.FREE and was != View.FREE:
		# start the free orbit from wherever the camera currently sits
		var d := (_pos - player.global_position)
		if d.length() > 0.5:
			d = d.normalized()
			orbit_yaw = atan2(d.x, d.z)
			orbit_pitch = asin(clampf(d.y, -1.0, 1.0))
	elif view == View.CHASE:
		orbit_yaw = 0.0
		orbit_pitch = 0.0


func reset_view() -> void:
	if view == View.FREE:
		var f: Vector3 = -player.global_transform.basis.z
		orbit_yaw = atan2(-f.x, -f.z)
		orbit_pitch = 0.25
	else:
		orbit_yaw = 0.0
		orbit_pitch = 0.0
	_frame = player.global_transform.basis.orthonormalized()


func update(dt: float) -> void:
	_t += dt
	var p := player.global_position
	var b := player.global_transform.basis.orthonormalized()
	var flying: bool = player.mode == 0
	var spd: float = player.speed
	var sk := clampf((spd - 30.0) / 300.0, 0.0, 1.0)
	var up := Vector3.UP
	var look_at := p

	if view == View.FPV:
		if flying:
			_pos = p + b * Vector3(0, 0.55, -0.75)
			_basis = _basis.slerp(b, 1.0 - exp(-dt * 16.0)).orthonormalized()
		else:
			if spd > 1.0:
				yaw = lerp_angle(yaw, player.facing, 1.0 - exp(-dt * 1.4))
			var yb := Basis(Vector3.UP, yaw)
			_pos = p + Vector3(0, 1.62, 0) + yb * Vector3(0, 0, -0.15)
			_basis = _basis.slerp(yb, 1.0 - exp(-dt * 12.0)).orthonormalized()
		if flying:
			var f := -b.z
			yaw = atan2(-f.x, -f.z)
	else:
		var d := dist * (1.0 + sk * 0.25)
		var want_off: Vector3
		if view == View.CHASE:
			# reference frame: the pilot's full orientation in the air (loops, inverted),
			# heading-only on the ground
			var ref: Basis
			if flying:
				ref = b
			else:
				if spd > 1.0:
					yaw = lerp_angle(yaw, player.facing, 1.0 - exp(-dt * 1.4))
				ref = Basis(Vector3.UP, yaw)
			_frame = _frame.slerp(ref, 1.0 - exp(-dt * (7.0 if flying else 5.0))).orthonormalized()
			if not dragging:
				var k := 1.0 - exp(-dt * 3.5)
				orbit_yaw = lerpf(orbit_yaw, 0.0, k)
				orbit_pitch = lerpf(orbit_pitch, 0.0, k)
			var lift := 0.16 if flying else 0.38
			var dir := Basis(Vector3.UP, orbit_yaw) * Basis(Vector3.RIGHT, -orbit_pitch) * Vector3(0, lift, 1).normalized()
			want_off = _frame * dir * d
			up = _frame.y
			look_at = p + _frame * Vector3(0, 0.6 if flying else 1.3, -4.0 if flying else 0.0)
			if flying:
				var f := -b.z
				yaw = atan2(-f.x, -f.z)
		else:
			# free orbit in world space around the pilot
			var dir := Basis(Vector3.UP, orbit_yaw) * Basis(Vector3.RIGHT, -orbit_pitch) * Vector3(0, 0, 1)
			want_off = dir * d
			up = Vector3.UP
			look_at = p + Vector3(0, 0.8, 0)
			var cf := -want_off
			yaw = atan2(-cf.x, -cf.z)
		# offsets are relative to the pilot, so the camera never lags behind at 500 m/s
		_off = _off.lerp(want_off, 1.0 - exp(-dt * 11.0))
		_pos = p + _off
		var fwd := (look_at - _pos)
		if fwd.length() < 0.01:
			fwd = -b.z
		if absf(fwd.normalized().dot(up)) > 0.995:
			up = b.z
		_basis = _basis.slerp(Basis.looking_at(fwd, up), 1.0 - exp(-dt * 14.0)).orthonormalized()

	# pull the camera in if a slope sits between it and the pilot
	if terrain and view != View.FPV:
		var head := p + Vector3.UP * 1.5
		for k in range(1, 9):
			var f := k / 8.0
			var q := head.lerp(_pos, f)
			if q.y < terrain.height(q.x, q.z) + 1.0:
				_pos = head.lerp(_pos, max(f - 0.15, 0.05))
				break
	# keep above ground and water
	if terrain:
		var gh: float = max(terrain.height(_pos.x, _pos.z), terrain.water_level(_pos.x, _pos.z))
		if _pos.y < gh + 1.2:
			_pos.y = gh + 1.2
	global_transform = Transform3D(_basis, _pos)

	# FOV narrows ever so slightly with speed; the sound barrier punches in a touch more
	kick = move_toward(kick, 0.0, dt * 1.8)
	var fov: float = P.v.fov - sk * 8.0 - player.super_k * 3.0 - kick * 5.0
	cam.fov = lerpf(cam.fov, clampf(fov, 20.0, 120.0), 1.0 - exp(-dt * 5.0))

	shake = move_toward(shake, 0.0, dt * 1.5)
	var amp: float = (player.boost_k * 0.025 + player.super_k * 0.08 + (0.03 if player.in_cloud else 0.0) * sk + shake) * P.v.cam_shake
	cam.h_offset = (sin(_t * 37.0) * 0.6 + sin(_t * 61.0) * 0.4) * amp
	cam.v_offset = (sin(_t * 43.0) * 0.6 + cos(_t * 71.0) * 0.4) * amp
	motes.amount_ratio = clampf(0.25 + sk * 1.5, 0.0, 1.0) if flying else 0.15
