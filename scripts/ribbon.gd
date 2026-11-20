extends MeshInstance3D
# Verlet-simulated cloth strip (ribbon / scarf). Simulated in a frame that translates
# with its anchor, so it streams cleanly behind you even at 500 m/s. Air drag pulls it
# into the relative wind; a travelling flutter wave makes it flap faster as you speed up.

var anchor: Node3D
var count := 16
var seg := 0.16
var width := 0.12
var flutter := 1.0
var drag := 5.0
var air_vel := Vector3.ZERO   # owner velocity (world)
var color := Color(0.85, 0.03, 0.06)
var metallic := 0.35
var rough := 0.18

var _p := PackedVector3Array()
var _q := PackedVector3Array()
var _last := Vector3.ZERO
var _t := 0.0
var _started := false


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	extra_cull_margin = 20.0
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = rough
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	# satin sheen: a glossy clear-coat keeps the colour saturated while it shines
	m.clearcoat_enabled = metallic > 0.1
	m.clearcoat = 1.0
	m.clearcoat_roughness = 0.08
	m.backlight_enabled = true
	m.backlight = Color(color.r * 0.5, color.g * 0.5, color.b * 0.5)
	material_override = m


func reset() -> void:
	_started = false


func _setup() -> void:
	var a := anchor.global_position
	var back := anchor.global_transform.basis.z
	_p.resize(count)
	_q.resize(count)
	for i in count:
		_p[i] = a + back * seg * i
		_q[i] = _p[i]
	_last = a
	_started = true


func sim(dt: float) -> void:
	if anchor == null or not anchor.is_inside_tree() or not is_visible_in_tree():
		return
	var a := anchor.global_position
	if not _started or a.distance_to(_last) > 60.0:
		_setup()
	_t += dt
	# carry the strip with the anchor (pure translation); dynamics happen relative to it
	var sh := a - _last
	_last = a
	for i in count:
		_p[i] += sh
		_q[i] += sh
	var spd := air_vel.length()
	var wind := -air_vel
	var up_ref := anchor.global_transform.basis.y
	var freq := minf(TAU * (1.2 + spd * 0.14), TAU * 18.0)
	var amp := (2.0 + minf(spd, 120.0) * 0.9 + maxf(spd - 120.0, 0.0) * 0.08) * flutter
	var kd := drag + minf(spd, 300.0) * 0.05
	var steps := 3
	var h := minf(dt, 1.0 / 30.0) / steps
	for s in steps:
		for i in range(1, count):
			var v := (_p[i] - _q[i]) / h
			var rel := wind - v
			var acc := rel * kd + Vector3(0, -9.8, 0)
			# flutter: a travelling wave normal to the strip, stronger toward the free end
			var dir := (_p[i] - _p[i - 1])
			if dir.length() > 1e-5:
				dir = dir.normalized()
			var nrm := (up_ref - dir * up_ref.dot(dir))
			if nrm.length() > 1e-4:
				nrm = nrm.normalized()
			var fi := float(i) / float(count - 1)
			acc += nrm * sin(_t * freq - i * 0.85) * amp * (0.25 + fi)
			var np := _p[i] + (_p[i] - _q[i]) * 0.985 + acc * h * h
			_q[i] = _p[i]
			_p[i] = np
		_p[0] = a
		_q[0] = a
		for it in 2:
			for i in range(1, count):
				var d := _p[i] - _p[i - 1]
				var l := d.length()
				if l < 1e-6:
					continue
				var corr := d * ((l - seg) / l)
				if i == 1:
					_p[i] -= corr
				else:
					_p[i] -= corr * 0.5
					_p[i - 1] += corr * 0.5
		# follow-the-leader pass: exact segment lengths, no stretching even at 500 m/s
		for i in range(1, count):
			var d := _p[i] - _p[i - 1]
			var l := d.length()
			if l < 1e-6:
				continue
			var np := _p[i - 1] + d * (seg / l)
			_q[i] += np - _p[i]
			_p[i] = np
	_build(up_ref)


func _build(up_ref: Vector3) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var side_ref := anchor.global_transform.basis.x
	for i in count:
		var d := (_p[mini(i + 1, count - 1)] - _p[maxi(i - 1, 0)])
		if d.length() < 1e-5:
			d = anchor.global_transform.basis.z
		d = d.normalized()
		var side := side_ref - d * side_ref.dot(d)
		if side.length() < 1e-4:
			side = d.cross(up_ref)
		side = side.normalized()
		var n := d.cross(side).normalized()
		var w := width * (1.0 - 0.35 * float(i) / count)
		im.surface_set_normal(n)
		im.surface_add_vertex(_p[i] - side * w * 0.5)
		im.surface_set_normal(n)
		im.surface_add_vertex(_p[i] + side * w * 0.5)
	im.surface_end()
	mesh = im
