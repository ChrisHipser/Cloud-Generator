extends Node3D
# A whimsical aviator (leather cap, brass goggles, handlebar moustache, silk scarf) under an
# old-fashioned ribbed glider: radiating wooden ribs, scalloped patchwork canvas, a little
# cruciform tail with a shiny red ribbon. Procedurally posed: wings unfurl in flight and
# fold on the ground; run / jump / swim cycles. Scarf and ribbon are cloth-simulated.

const Ribbon = preload("res://scripts/ribbon.gd")

var body := Node3D.new()        # pivot at hips
var head := Node3D.new()
var arm_l := Node3D.new()
var arm_r := Node3D.new()
var leg_l := Node3D.new()
var leg_r := Node3D.new()
var shin_l := Node3D.new()
var shin_r := Node3D.new()
var wing := Node3D.new()        # mounted above the shoulders
var half_l := Node3D.new()
var half_r := Node3D.new()
var tip_l := Marker3D.new()
var tip_r := Marker3D.new()
var tail_tip := Marker3D.new()
var neck := Marker3D.new()
var ribbon: MeshInstance3D = Ribbon.new()
var scarf: MeshInstance3D = Ribbon.new()

var open := 1.0          # 0 folded .. 1 spread
var prone := 1.0         # 0 upright .. 1 lying in harness
var run_phase := 0.0
var run_amt := 0.0
var crouch := 0.0
var tuck := 0.0
var swim := 0.0
var flex := 0.0
var bank_flex := 0.0
var air_vel := Vector3.ZERO
var _t := 0.0
var _fp := false


func _mat(c: Color, rough := 0.8, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _capsule(r: float, h: float, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = h
	cm.radial_segments = 12
	cm.rings = 4
	mi.mesh = cm
	mi.material_override = m
	return mi


func _sphere(r: float, m: Material, pos: Vector3, sc := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 14
	sm.rings = 8
	mi.mesh = sm
	mi.material_override = m
	mi.position = pos
	mi.scale = sc
	return mi


func _cyl(r: float, h: float, m: Material, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = 14
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	return mi


func _stick(a: Vector3, b: Vector3, r: float, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = maxf(a.distance_to(b), 0.001)
	cm.radial_segments = 6
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = m
	var mid := (a + b) * 0.5
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	mi.transform = Transform3D(Basis(x, y, z), mid)
	return mi


func _ready() -> void:
	var skin := _mat(Color(0.9, 0.7, 0.56))
	var cheek := _mat(Color(0.95, 0.62, 0.52))
	var jacket := _mat(Color(0.46, 0.27, 0.14), 0.55)
	var leather := _mat(Color(0.33, 0.19, 0.1), 0.5)
	var fleece := _mat(Color(0.95, 0.9, 0.8), 1.0)
	var trousers := _mat(Color(0.62, 0.56, 0.42))
	var boots := _mat(Color(0.2, 0.12, 0.07), 0.45)
	var brass := _mat(Color(0.88, 0.66, 0.3), 0.3, 0.9)
	var glass := _mat(Color(0.55, 0.82, 0.88), 0.05, 0.3)
	var tash := _mat(Color(0.4, 0.24, 0.12), 0.9)
	add_child(body)

	# --- the aviator
	var torso := _capsule(0.2, 0.74, jacket)
	torso.position = Vector3(0, 0.38, 0)
	body.add_child(torso)
	body.add_child(_cyl(0.205, 0.06, leather, Vector3(0, 0.12, 0)))                 # belt
	body.add_child(_cyl(0.035, 0.07, brass, Vector3(0, 0.12, -0.2), Vector3(PI * 0.5, 0, 0)))  # buckle
	var collar := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.07
	tm.outer_radius = 0.16
	collar.mesh = tm
	collar.material_override = fleece
	collar.position = Vector3(0, 0.72, 0)
	body.add_child(collar)
	var satchel := MeshInstance3D.new()
	var bx := BoxMesh.new()
	bx.size = Vector3(0.22, 0.17, 0.08)
	satchel.mesh = bx
	satchel.material_override = leather
	satchel.position = Vector3(0.2, 0.16, 0.12)
	satchel.rotation.y = 0.5
	body.add_child(satchel)
	body.add_child(_stick(Vector3(0.2, 0.2, 0.12), Vector3(-0.16, 0.66, 0.0), 0.012, leather))  # strap
	# head
	head.position = Vector3(0, 0.9, 0)
	body.add_child(head)
	head.add_child(_sphere(0.13, skin, Vector3.ZERO))
	head.add_child(_sphere(0.032, cheek, Vector3(0, -0.01, -0.128)))                  # nose
	head.add_child(_sphere(0.022, cheek, Vector3(-0.07, -0.025, -0.105)))             # cheeks
	head.add_child(_sphere(0.022, cheek, Vector3(0.07, -0.025, -0.105)))
	for s in [-1, 1]:
		var m := _capsule(0.013, 0.1, tash)                                            # handlebar moustache
		m.position = Vector3(0.045 * s, -0.045, -0.117)
		m.rotation = Vector3(0, 0, -s * 1.15)
		head.add_child(m)
		head.add_child(_sphere(0.016, tash, Vector3(0.088 * s, -0.03, -0.1)))          # curled tips
	var cap := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.142
	hm.height = 0.16
	hm.is_hemisphere = true
	cap.mesh = hm
	cap.material_override = leather
	cap.position = Vector3(0, 0.015, 0.005)
	head.add_child(cap)
	head.add_child(_sphere(0.05, leather, Vector3(-0.125, -0.03, 0.0), Vector3(0.5, 1.4, 1.0)))   # ear flaps
	head.add_child(_sphere(0.05, leather, Vector3(0.125, -0.03, 0.0), Vector3(0.5, 1.4, 1.0)))
	var strap := MeshInstance3D.new()
	var st := TorusMesh.new()
	st.inner_radius = 0.133
	st.outer_radius = 0.146
	strap.mesh = st
	strap.material_override = _mat(Color(0.15, 0.1, 0.07))
	strap.position = Vector3(0, 0.035, 0)
	head.add_child(strap)
	for s in [-1, 1]:                                                                   # goggles
		head.add_child(_cyl(0.042, 0.03, brass, Vector3(0.052 * s, 0.035, -0.125), Vector3(PI * 0.5, 0, 0)))
		head.add_child(_cyl(0.034, 0.034, glass, Vector3(0.052 * s, 0.035, -0.127), Vector3(PI * 0.5, 0, 0)))
	neck.position = Vector3(0, 0.74, 0.1)
	body.add_child(neck)
	for side in [-1, 1]:
		var arm: Node3D = arm_l if side < 0 else arm_r
		arm.position = Vector3(0.25 * side, 0.66, 0)
		body.add_child(arm)
		var a := _capsule(0.068, 0.56, jacket)
		a.position = Vector3(0, -0.25, 0)
		arm.add_child(a)
		arm.add_child(_sphere(0.06, leather, Vector3(0, -0.56, 0)))                    # glove
		var leg: Node3D = leg_l if side < 0 else leg_r
		leg.position = Vector3(0.1 * side, 0.02, 0)
		body.add_child(leg)
		var th := _capsule(0.088, 0.46, trousers)
		th.position = Vector3(0, -0.21, 0)
		leg.add_child(th)
		var shin: Node3D = shin_l if side < 0 else shin_r
		shin.position = Vector3(0, -0.42, 0)
		leg.add_child(shin)
		var sh := _capsule(0.074, 0.46, boots)
		sh.position = Vector3(0, -0.2, 0)
		shin.add_child(sh)
		shin.add_child(_sphere(0.07, boots, Vector3(0, -0.42, -0.06), Vector3(1.0, 0.7, 1.5)))  # toe

	# --- the glider: keel along -Z, two halves hinged at the keel, tail on a boom
	var wood := _mat(Color(0.56, 0.38, 0.21), 0.55)
	var wire := _mat(Color(0.12, 0.1, 0.09), 0.4, 0.6)
	var sail := StandardMaterial3D.new()
	sail.vertex_color_use_as_albedo = true
	sail.roughness = 0.85
	sail.cull_mode = BaseMaterial3D.CULL_DISABLED
	sail.backlight_enabled = true
	sail.backlight = Color(0.55, 0.42, 0.28)
	wing.position = Vector3(0, 1.15, 0)
	add_child(wing)
	wing.add_child(_stick(Vector3(0, 0, -1.55), Vector3(0, 0.03, 1.4), 0.028, wood))         # keel
	wing.add_child(_stick(Vector3(0, 0.02, 1.3), Vector3(0, 0.13, 3.15), 0.02, wood))        # tail boom
	wing.add_child(_stick(Vector3(0, 0, 0.1), Vector3(0, 0.78, 0.1), 0.02, wood))            # kingpost
	wing.add_child(_stick(Vector3(0, 0, 0.1), Vector3(-0.55, -1.0, 0.0), 0.018, wood))       # A-frame
	wing.add_child(_stick(Vector3(0, 0, 0.1), Vector3(0.55, -1.0, 0.0), 0.018, wood))
	wing.add_child(_stick(Vector3(-0.58, -1.0, 0.0), Vector3(0.58, -1.0, 0.0), 0.018, wood))
	wing.add_child(_stick(Vector3(0, 0.78, 0.1), Vector3(0, 0.14, 3.1), 0.005, wire))
	wing.add_child(_stick(Vector3(0, 0.78, 0.1), Vector3(0, 0, -1.5), 0.005, wire))
	for p in [Vector3(0, 0, -1.55), Vector3(0, 0.78, 0.1), Vector3(-0.56, -1.0, 0.0), Vector3(0.56, -1.0, 0.0)]:
		wing.add_child(_sphere(0.035, brass, p))
	_build_tail(sail, wood)
	for side in [-1, 1]:
		_build_half(side, sail, wood, wire, brass)

	# cloth: shiny red ribbon off the tail, cream silk scarf off the neck
	tail_tip.position = Vector3(0, 0.14, 3.2)
	wing.add_child(tail_tip)
	ribbon.anchor = tail_tip
	ribbon.count = 18
	ribbon.seg = 0.17
	ribbon.width = 0.11
	ribbon.color = Color(0.72, 0.0, 0.03)
	ribbon.metallic = 0.15
	ribbon.rough = 0.3
	add_child(ribbon)
	scarf.anchor = neck
	scarf.count = 12
	scarf.seg = 0.095
	scarf.width = 0.11
	scarf.flutter = 1.3
	scarf.drag = 4.0
	scarf.color = Color(0.97, 0.94, 0.86)
	scarf.metallic = 0.05
	scarf.rough = 0.35
	add_child(scarf)


func _le(s: float, u: float) -> Vector3:
	# leading edge: bowed forward, gentle dihedral
	var nose := Vector3(0, 0, -1.5)
	var tip := Vector3(3.7 * s, 0.3, 0.55)
	return nose.lerp(tip, u) + Vector3(0, 0.06 * sin(PI * u), -0.38 * sin(PI * u))


func _rib(s: float, u: float, f: float) -> Vector3:
	var c := lerpf(2.9, 0.38, pow(u, 1.15))
	var dir := Vector3(0.28 * s * u, -0.04, 1.0).normalized()
	return _le(s, u) + dir * c * f + Vector3(0, sin(PI * f) * 0.065 * c, 0)


func _build_half(s: float, sail: Material, wood: Material, wire: Material, brass: Material) -> void:
	var half: Node3D = half_l if s < 0 else half_r
	wing.add_child(half)
	var R := 7
	var CF := [0.0, 0.25, 0.5, 0.75, 1.0]
	var SP := [0.0, 0.5, 1.0]
	var cream := Color(0.94, 0.89, 0.77)
	var tan_c := Color(0.86, 0.78, 0.62)
	var teal := Color(0.42, 0.66, 0.64)
	var rose := Color(0.88, 0.45, 0.36)
	var stool := SurfaceTool.new()
	stool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in R:
		var u0 := float(i) / R
		var u1 := float(i + 1) / R
		var pc := cream if i % 2 == 0 else tan_c
		if i == R - 2:
			pc = teal
		elif i == 2:
			pc = rose
		var grid: Array = []
		for f in CF:
			var row: Array = []
			for t in SP:
				# scalloped trailing edge between ribs
				var fe: float = f * (1.0 - 0.17 * sin(PI * t) * pow(f, 3.0))
				var p := _rib(s, u0, fe).lerp(_rib(s, u1, fe), t)
				p.y -= 0.03 * sin(PI * t) * f
				row.append(p)
			grid.append(row)
		for a in CF.size() - 1:
			for bb in SP.size() - 1:
				var q00: Vector3 = grid[a][bb]
				var q01: Vector3 = grid[a][bb + 1]
				var q10: Vector3 = grid[a + 1][bb]
				var q11: Vector3 = grid[a + 1][bb + 1]
				var shade := 0.93 + 0.07 * sin(PI * (bb + 0.5) / 2.0)
				var c := Color(pc.r * shade, pc.g * shade, pc.b * shade)
				for v in [q00, q10, q11, q00, q11, q01]:
					stool.set_color(c)
					stool.add_vertex(v)
	stool.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = stool.commit()
	mi.material_override = sail
	half.add_child(mi)
	# wooden ribs and the leading-edge spar
	for i in R + 1:
		var u := float(i) / R
		var lift := Vector3(0, 0.012, 0)
		half.add_child(_stick(_rib(s, u, 0.0) + lift, _rib(s, u, 0.5) + lift, 0.012, wood))
		half.add_child(_stick(_rib(s, u, 0.5) + lift, _rib(s, u, 1.0) + lift, 0.01, wood))
		if i < R:
			half.add_child(_stick(_le(s, u), _le(s, float(i + 1) / R), 0.022, wood))
	# bracing wires from the kingpost and the control bar
	var anchor := _le(s, 0.55)
	half.add_child(_stick(Vector3(0, 0.78, 0.1), anchor, 0.005, wire))
	half.add_child(_stick(Vector3(0.56 * s, -1.0, 0.0), anchor, 0.005, wire))
	half.add_child(_sphere(0.03, brass, anchor))
	var tipm: Marker3D = tip_l if s < 0 else tip_r
	tipm.position = _le(s, 1.0)
	half.add_child(tipm)


func _build_tail(sail: Material, wood: Material) -> void:
	var stool := SurfaceTool.new()
	stool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cream := Color(0.93, 0.88, 0.76)
	var red := Color(0.8, 0.22, 0.18)
	var r0 := Vector3(0, 0.13, 2.45)
	for s in [-1.0, 1.0]:
		var outer := Vector3(0.8 * s, 0.13, 3.2)
		var mid := Vector3(0.38 * s, 0.13, 3.05)
		var back := Vector3(0, 0.13, 3.18)
		for v in [r0, outer, mid, r0, mid, back]:
			stool.set_color(cream)
			stool.add_vertex(v)
	var f0 := Vector3(0, 0.13, 2.55)
	var f1 := Vector3(0, 0.66, 3.12)
	var f2 := Vector3(0, 0.13, 3.22)
	var fm := Vector3(0, 0.36, 3.05)
	for v in [f0, f1, fm, f0, fm, f2]:
		stool.set_color(red)
		stool.add_vertex(v)
	stool.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = stool.commit()
	mi.material_override = sail
	wing.add_child(mi)
	for s in [-1.0, 1.0]:
		wing.add_child(_stick(r0, Vector3(0.8 * s, 0.135, 3.2), 0.008, wood))
	wing.add_child(_stick(f0, f1, 0.008, wood))


func reset_cloth() -> void:
	ribbon.reset()
	scarf.reset()


func animate(delta: float) -> void:
	_t += delta
	# wing fold: halves swing up/back over the shoulders and shrink in
	var f := 1.0 - open
	half_l.rotation = Vector3(-f * 0.2, f * 0.25, -f * 1.45 + bank_flex * 0.08 + flex * 0.06)
	half_r.rotation = Vector3(-f * 0.2, -f * 0.25, f * 1.45 + bank_flex * 0.08 - flex * 0.06)
	half_l.scale = Vector3(lerpf(0.22, 1.0, open), 1, lerpf(0.75, 1.0, open))
	half_r.scale = Vector3(lerpf(0.22, 1.0, open), 1, lerpf(0.75, 1.0, open))
	wing.position = Vector3(0, lerpf(1.0, 1.15, open), lerpf(0.28, 0.0, open))
	wing.rotation.x = lerpf(1.35, 0.0, open)

	# body: prone in harness when flying, upright when on the ground
	body.rotation.x = -prone * 1.45 + crouch * 0.25
	body.position = Vector3(0, lerpf(0.95, 0.15, prone) - crouch * 0.35 - swim * 0.6, lerpf(0.0, 0.1, prone))
	# head looks forward when prone, bobs a little
	head.rotation = Vector3(prone * 1.2 + sin(_t * 1.3) * 0.04, sin(_t * 0.7) * 0.08, 0)

	var sw := sin(run_phase) * run_amt
	var swm := sin(_t * 4.0) * swim
	var arm_fly := prone * -2.6
	arm_l.rotation = Vector3(arm_fly - sw * 0.9 + swm * 1.2 + tuck * -0.6, 0, -0.15 - swim * 0.9)
	arm_r.rotation = Vector3(arm_fly + sw * 0.9 - swm * 1.2 + tuck * -0.6, 0, 0.15 + swim * 0.9)
	var leg_fly := prone * 0.1 + sin(_t * 1.1) * 0.04 * prone
	leg_l.rotation.x = leg_fly + sw * 0.95 + crouch * -1.3 + tuck * -1.4 + swm * 0.4
	leg_r.rotation.x = leg_fly - sw * 0.95 + crouch * -1.3 + tuck * -1.4 - swm * 0.4
	shin_l.rotation.x = max(0.0, -sw) * 1.4 * run_amt + crouch * 2.2 + tuck * 2.0 + prone * 0.15
	shin_r.rotation.x = max(0.0, sw) * 1.4 * run_amt + crouch * 2.2 + tuck * 2.0 + prone * 0.25
	ribbon.air_vel = air_vel
	scarf.air_vel = air_vel
	ribbon.sim(delta)
	if not _fp:
		scarf.sim(delta)


func set_first_person(fp: bool) -> void:
	_fp = fp
	body.visible = not fp
	scarf.visible = not fp
