extends Node3D
# Flocks that move like schools of fish: boids + wandering goals, cloud and terrain
# avoidance, beam nudges. Rendered with one MultiMesh per flock, flapping in the shader.

signal bird_call(pos: Vector3, species: int)

const SPECIES := [
	{"name": "swallow", "size": 0.55, "speed": 17.0, "count": Vector2i(22, 42), "flap": 15.0, "col": Color(0.12, 0.13, 0.18)},
	{"name": "gull", "size": 1.2, "speed": 14.0, "count": Vector2i(9, 18), "flap": 6.5, "col": Color(0.92, 0.92, 0.9)},
	{"name": "crane", "size": 2.0, "speed": 13.0, "count": Vector2i(7, 12), "flap": 4.0, "col": Color(0.6, 0.6, 0.62)},
	{"name": "stork", "size": 2.6, "speed": 12.0, "count": Vector2i(5, 9), "flap": 3.2, "col": Color(0.95, 0.95, 0.93)},
]
const FLOCKS := 7

var field: Node
var player: Node3D
var terrain: Node
var flocks: Array = []
var _rng := RandomNumberGenerator.new()
var _shader := Shader.new()
var _frame := 0


func _ready() -> void:
	_rng.randomize()
	_shader.code = """shader_type spatial;
render_mode cull_disabled;
uniform vec3 col : source_color = vec3(0.9);
uniform float flap = 6.0;
void vertex() {
	float side = abs(VERTEX.x);
	float ph = TIME * flap * (0.8 + INSTANCE_CUSTOM.x * 0.4) + INSTANCE_CUSTOM.x * 6.28;
	float glide = INSTANCE_CUSTOM.y;
	VERTEX.y += sin(ph) * side * 0.75 * (1.0 - glide);
	VERTEX.y += side * 0.12 * glide;
}
void fragment() {
	ALBEDO = col * (0.85 + 0.15 * UV.x);
	ROUGHNESS = 0.9;
}"""


func _bird_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var v := [
		Vector3(0, 0, -0.9), Vector3(-0.15, 0, 0.1), Vector3(0.15, 0, 0.1),
		Vector3(0, 0, 0.1), Vector3(-0.15, 0, 0.1), Vector3(0, 0, 0.8),
		Vector3(0, 0, 0.1), Vector3(0, 0, 0.8), Vector3(0.15, 0, 0.1),
		Vector3(-0.1, 0, -0.35), Vector3(-1.6, 0.05, 0.05), Vector3(-0.1, 0, 0.25),
		Vector3(0.1, 0, -0.35), Vector3(0.1, 0, 0.25), Vector3(1.6, 0.05, 0.05),
		Vector3(0, 0.08, -0.9), Vector3(0, 0.12, -0.6), Vector3(0, -0.05, -0.6),
	]
	for p in v:
		st.set_uv(Vector2(1.0 - absf(p.x) / 1.6, 0))
		st.set_normal(Vector3.UP)
		st.add_vertex(p)
	return st.commit()


func _spawn(f: Dictionary = {}) -> Dictionary:
	var sp := _rng.randi() % SPECIES.size()
	if _rng.randf() < 0.45:
		sp = 0
	var spec: Dictionary = SPECIES[sp]
	var n := _rng.randi_range(spec.count.x, spec.count.y)
	var pp := player.global_position
	var a := _rng.randf() * TAU
	var d := _rng.randf_range(250.0, 1100.0)
	# half the time, put the flock somewhere ahead of you so it crosses your path
	var pf: Vector3 = -player.global_transform.basis.z
	if _rng.randf() < 0.5 and Vector2(pf.x, pf.z).length() > 0.2:
		a = atan2(pf.z, pf.x) + _rng.randf_range(-0.6, 0.6)
		d = _rng.randf_range(350.0, 900.0) + player.speed * 4.0
	var c := pp + Vector3(cos(a) * d, 0, sin(a) * d)
	var gh: float = max(terrain.height(c.x, c.z), 0.0)
	# near your own altitude (birds avoid the inside of clouds on their own)
	c.y = clampf(pp.y + _rng.randf_range(-120.0, 90.0), gh + 70.0, 3000.0)
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var dir := Vector3(cos(a + 1.5), 0, sin(a + 1.5))
	if _rng.randf() < 0.5:
		dir = -dir
	for i in n:
		pos.append(c + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.5, 0.5), _rng.randf_range(-1, 1)) * spec.size * 12.0)
		vel.append(dir * spec.speed)
	var mmi: MultiMeshInstance3D = f.get("mmi", null)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mmi)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _bird_mesh()
	mm.instance_count = n
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("col", spec.col)
	mat.set_shader_parameter("flap", spec.flap)
	mmi.material_override = mat
	mmi.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
	var phases := PackedFloat32Array()
	for i in n:
		phases.append(_rng.randf())
	return {"sp": sp, "spec": spec, "pos": pos, "vel": vel, "goal": c + dir * 600.0, "mmi": mmi, "ph": phases, "call_t": _rng.randf_range(1.0, 5.0), "glide": PackedFloat32Array()}


func update(dt: float) -> void:
	if player == null or terrain == null or not terrain.ready_ok:
		return
	_frame += 1
	while flocks.size() < FLOCKS:
		flocks.append(_spawn())
	var pp := player.global_position
	var wo := Vector3(P.wind.x, 0, P.wind.y)
	for fi in flocks.size():
		var f: Dictionary = flocks[fi]
		var spec: Dictionary = f.spec
		var pos: PackedVector3Array = f.pos
		var vel: PackedVector3Array = f.vel
		var n := pos.size()
		var cen := Vector3.ZERO
		var avg := Vector3.ZERO
		for i in n:
			cen += pos[i]
			avg += vel[i]
		cen /= n
		avg /= n
		if cen.distance_to(pp) > 2600.0:
			flocks[fi] = _spawn(f)
			continue
		if cen.distance_to(f.goal) < 120.0 or _rng.randf() < dt * 0.05:
			var a := _rng.randf() * TAU
			var g: Vector3 = cen + Vector3(cos(a), 0, sin(a)) * _rng.randf_range(300.0, 900.0)
			var gh: float = max(terrain.height(g.x, g.z), 0.0)
			g.y = clampf(cen.y + _rng.randf_range(-120.0, 120.0), gh + 80.0, 3000.0)
			f.goal = g
		var sep_r: float = spec.size * 4.0
		var spd: float = spec.speed
		# avoid clouds: probe ahead of the flock in cloud space (staggered across frames)
		var avoid := Vector3.ZERO
		if field and field.ready_ok and (_frame + fi) % 3 == 0:
			var probe := cen + avg.normalized() * 90.0 - wo
			var sd: float = field.sdf_fast(probe)
			if sd < 120.0:
				avoid = field.gradient(probe) * (120.0 - sd) * 0.25 + Vector3.UP * 4.0
				f.goal = cen + field.gradient(probe) * 400.0
		f["avoid"] = avoid if avoid != Vector3.ZERO else f.get("avoid", Vector3.ZERO) * 0.95
		var mm: MultiMesh = f.mmi.multimesh
		for i in n:
			var p := pos[i]
			var v := vel[i]
			var sep := Vector3.ZERO
			# starling-style: each bird tracks ~7 topological neighbours, O(n) not O(n^2)
			for k in range(1, 8):
				var j := (i + k * 3) % n
				if j == i:
					continue
				var d := p - pos[j]
				var l := d.length()
				if l < sep_r and l > 0.001:
					sep += d / (l * l) * sep_r
			var acc := sep * 2.2
			acc += (avg - v) * 0.9
			acc += (cen - p) * 0.25
			acc += (f.goal - p).normalized() * 2.5
			acc += f.avoid
			var gh: float = max(terrain.height(p.x, p.z), terrain.water_level(p.x, p.z))
			if p.y < gh + 40.0:
				acc.y += (gh + 40.0 - p.y) * 0.6
			if player.beam_on:
				var q: Vector3 = p - (pp + player.beam_dir * 3.0)
				var bl: float = P.v.beam_len
				var s := clampf(q.dot(player.beam_dir), 0.0, bl)
				var off: Vector3 = q - player.beam_dir * s
				var r: float = P.v.beam_radius * 1.6 * lerpf(1.0, P.v.beam_cone, s / bl)
				if off.length() < r:
					acc += off.normalized() * 35.0 * (1.0 - off.length() / r) + Vector3.UP * 6.0
			var pd := p - pp
			if pd.length() < 25.0:
				acc += pd.normalized() * 20.0
			v += acc * dt
			var sl := v.length()
			v = v / max(sl, 0.01) * clampf(sl, spd * 0.7, spd * 1.5)
			p += v * dt
			pos[i] = p
			vel[i] = v
			var fwd := v.normalized()
			var bank := clampf(acc.dot(fwd.cross(Vector3.UP)) * 0.05, -0.8, 0.8)
			var bx := Vector3.UP.cross(-fwd).normalized()
			if bx.length() < 0.5:
				bx = Vector3.RIGHT
			var by := (-fwd).cross(bx)
			var basis := Basis(bx, by, -fwd).rotated(fwd, bank).scaled(Vector3.ONE * spec.size)
			mm.set_instance_transform(i, Transform3D(basis, p))
			var glide := 1.0 if v.y < -1.0 else 0.0
			mm.set_instance_custom_data(i, Color(f.ph[i], glide, 0, 0))
		f.pos = pos
		f.vel = vel
		# occasional echoing calls when near
		var dist := cen.distance_to(pp)
		f.call_t -= dt
		if f.call_t <= 0.0:
			f.call_t = _rng.randf_range(2.0, 7.0)
			if dist < 600.0:
				bird_call.emit(cen, f.sp)
