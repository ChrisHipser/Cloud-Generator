extends Node3D
# GPU-generated wonderland terrain: compute heightmap -> CPU copy (collision, lakes)
# -> geomorphing clipmap rings that follow the camera.

const RDU = preload("res://scripts/rdu.gd")
const SIZE := 16384.0
const RES := 2048
const LEVELS := 8
const GRID := 128
const SNOW_LINE := 1250.0
const TERRAIN_SEED := 137

var rd: RenderingDevice
var hrid := RID()
var height_tex := Texture2DRD.new()
var data := PackedByteArray()
var ready_ok := false
var lakes: Array = []   # {pos: Vector2, r: float, level: float}
var levels: Array = []
var mat := ShaderMaterial.new()
var lake_root := Node3D.new()
var water_mat: ShaderMaterial
var gen_ms := 0.0

signal generated


func _ready() -> void:
	mat.shader = load("res://shaders/terrain.gdshader")
	mat.set_shader_parameter("height_tex", height_tex)
	mat.set_shader_parameter("terrain_size", SIZE)
	mat.set_shader_parameter("texel", SIZE / RES)
	mat.set_shader_parameter("snow_line", SNOW_LINE)
	var mesh := _grid_mesh(GRID)
	for i in LEVELS:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if i < 5 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 4000.0
		add_child(mi)
		levels.append(mi)
	add_child(lake_root)
	RenderingServer.call_on_render_thread(_rt_gen.bind(TERRAIN_SEED))


func _exit_tree() -> void:
	# free the heightmap (F2 reloads the whole world)
	height_tex.texture_rd_rid = RID()
	var r := hrid
	var dev := rd
	if dev != null and r.is_valid():
		RenderingServer.call_on_render_thread(func(): dev.free_rid(r))


func _grid_mesh(n: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := n / 2
	for z in range(-h, h + 1):
		for x in range(-h, h + 1):
			st.add_vertex(Vector3(x, 0, z))
	var w := n + 1
	for z in n:
		for x in n:
			var i := z * w + x
			if (x + z) % 2 == 0:
				st.add_index(i); st.add_index(i + 1); st.add_index(i + w)
				st.add_index(i + 1); st.add_index(i + w + 1); st.add_index(i + w)
			else:
				st.add_index(i); st.add_index(i + 1); st.add_index(i + w + 1)
				st.add_index(i); st.add_index(i + w + 1); st.add_index(i + w)
	var m := st.commit()
	m.custom_aabb = AABB(Vector3(-h, -200, -h), Vector3(n, 4000, n))
	return m


func _rt_gen(seed: int) -> void:
	var t0 := Time.get_ticks_usec()
	rd = RenderingServer.get_rendering_device()
	var sh := RDU.compile(rd, "res://compute/terrain_gen.glsl")
	var pipe := rd.compute_pipeline_create(sh)
	hrid = RDU.tex2d(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, RES, RES)
	var pb := PackedFloat32Array([SIZE, RES, float(seed), -70.0]).to_byte_array()
	var buf := rd.storage_buffer_create(pb.size(), pb)
	var us := rd.uniform_set_create([RDU.u_img(0, hrid), RDU.u_ssbo(1, buf)], sh, 0)
	RDU.run(rd, pipe, us, RES / 16, RES / 16, 1)
	var d := rd.texture_get_data(hrid, 0)
	rd.free_rid(us)
	rd.free_rid(buf)
	rd.free_rid(pipe)
	rd.free_rid(sh)
	_on_gen.call_deferred(d, (Time.get_ticks_usec() - t0) / 1000.0)


func _on_gen(d: PackedByteArray, ms: float) -> void:
	data = d
	gen_ms = ms
	_make_lakes()
	var up := data
	RenderingServer.call_on_render_thread(func(): rd.texture_update(hrid, 0, up))
	height_tex.texture_rd_rid = hrid
	ready_ok = true
	var mx := -1e9
	var above := 0
	var snowy := 0
	for iz in 96:
		for ix in 96:
			var x := (ix / 96.0 - 0.5) * SIZE
			var z := (iz / 96.0 - 0.5) * SIZE
			var h := height(x, z)
			mx = max(mx, h)
			if h > SNOW_LINE:
				above += 1
			if is_snow(x, z):
				snowy += 1
	print("Terrain generated in %.1f ms, %d lakes, max %.0f m, %.1f%% above snowline, %.1f%% walkable snow" % [ms, lakes.size(), mx, above / 92.16, snowy / 92.16])
	generated.emit()


func _h(ix: int, iz: int) -> float:
	ix = clampi(ix, 0, RES - 1)
	iz = clampi(iz, 0, RES - 1)
	return data.decode_float((iz * RES + ix) * 16)


func height(x: float, z: float) -> float:
	if data.is_empty():
		return 0.0
	var gx := (x / SIZE + 0.5) * RES - 0.5
	var gz := (z / SIZE + 0.5) * RES - 0.5
	var ix := floori(gx)
	var iz := floori(gz)
	var fx := gx - ix
	var fz := gz - iz
	return lerpf(lerpf(_h(ix, iz), _h(ix + 1, iz), fx), lerpf(_h(ix, iz + 1), _h(ix + 1, iz + 1), fx), fz)


func normal(x: float, z: float) -> Vector3:
	var e := SIZE / RES
	return Vector3(height(x - e, z) - height(x + e, z), 2.0 * e, height(x, z - e) - height(x, z + e)).normalized()


func water_level(x: float, z: float) -> float:
	var lv := 0.0
	for l in lakes:
		if Vector2(x, z).distance_to(l.pos) < l.r * 1.05:
			lv = max(lv, l.level)
	return lv


func is_snow(x: float, z: float) -> bool:
	return height(x, z) > SNOW_LINE + 60.0 and normal(x, z).y > 0.55


func _make_lakes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	lakes.clear()
	var tries := 0
	while lakes.size() < 14 and tries < 900:
		tries += 1
		var p := Vector2(rng.randf_range(-0.36, 0.36), rng.randf_range(-0.36, 0.36)) * SIZE
		var r := rng.randf_range(110.0, 300.0)
		var hc := height(p.x, p.y)
		if hc < 25.0 or hc > 1550.0:
			continue
		var lo := 1e9
		var hi := -1e9
		for k in 16:
			var a := k * TAU / 16.0
			var hh := height(p.x + cos(a) * r, p.y + sin(a) * r)
			lo = min(lo, hh)
			hi = max(hi, hh)
		if hi - lo > 45.0:
			continue
		var clash := false
		for l in lakes:
			if l.pos.distance_to(p) < l.r + r + 400.0:
				clash = true
		if clash:
			continue
		var level := lo - 1.5
		var depth := rng.randf_range(8.0, 18.0)
		lakes.append({"pos": p, "r": r, "level": level})
		var e := SIZE / RES
		var rad := int(ceil(r * 1.3 / e))
		var cx := int((p.x / SIZE + 0.5) * RES)
		var cz := int((p.y / SIZE + 0.5) * RES)
		for iz in range(cz - rad, cz + rad + 1):
			for ix in range(cx - rad, cx + rad + 1):
				if ix < 0 or iz < 0 or ix >= RES or iz >= RES:
					continue
				var wx := ((ix + 0.5) / RES - 0.5) * SIZE
				var wz := ((iz + 0.5) / RES - 0.5) * SIZE
				var q := Vector2(wx, wz).distance_to(p) / r
				var off := (iz * RES + ix) * 16
				if q < 1.0:
					var nh := level - depth * (1.0 - q * q) - 0.5
					data.encode_float(off, min(data.decode_float(off), nh))
				if q < 1.3:
					data.encode_float(off + 12, max(data.decode_float(off + 12), clampf((1.3 - q) / 0.3, 0.0, 1.0)))


func update_view(cam: Vector3) -> void:
	var prev_c := Vector2.ZERO
	var prev_h := 0.0
	for i in LEVELS:
		var s := 4.0 * pow(2.0, i)
		var snap := s * 2.0
		var c := Vector2(floor(cam.x / snap) * snap, floor(cam.z / snap) * snap)
		var mi: MeshInstance3D = levels[i]
		mi.transform = Transform3D(Basis.from_scale(Vector3(s, 1, s)), Vector3(c.x, 0, c.y))
		mi.set_instance_shader_parameter("spacing", s)
		mi.set_instance_shader_parameter("level_center", c)
		mi.set_instance_shader_parameter("level_half", s * GRID * 0.5)
		mi.set_instance_shader_parameter("inner_center", prev_c)
		mi.set_instance_shader_parameter("inner_half", prev_h if i > 0 else 0.0)
		prev_c = c
		prev_h = s * GRID * 0.5
