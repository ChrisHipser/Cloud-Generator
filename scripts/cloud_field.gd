extends Node
# Far-field clouds: generates metaball "billow" spheres + thunderheads, bakes them
# (with the deck shelf) into a tiling SDF volume on the GPU, and keeps a CPU copy
# for gameplay queries (in-cloud detection, bird avoidance, audio).

const RDU = preload("res://scripts/rdu.gd")

signal baked

var rd: RenderingDevice
var noise_rid := RID()
var sdf_rid := RID()
var noise_tex := Texture3DRD.new()
var sdf_tex := Texture3DRD.new()
var dom := Vector3(16384, 3200, 16384)
var res := Vector3i(384, 160, 384)
var sdf_soft := 64.0

var clusters: Array = []   # {pos: Vector3, r: float, storm: bool}
var storms: Array = []     # {pos: Vector3 (x, base, z), r: float, top: float}

var cpu: PackedByteArray = PackedByteArray()
var cpu_res := Vector3i.ZERO
var ready_ok := false

var _bake_shader := RID()
var _bake_pipe := RID()
var _noise_shader := RID()
var _noise_pipe := RID()
var _samp := RID()
var _dirty := 0.0
var _rebake_requested := false
var bake_ms := 0.0


func _ready() -> void:
	RenderingServer.call_on_render_thread(_rt_init)
	P.changed.connect(_on_param)


func _on_param(n: String, cat: String) -> void:
	if cat == "spawn" or n == "new_weather":
		_dirty = 0.35


func _process(delta: float) -> void:
	if _dirty > 0.0:
		_dirty -= delta
		if _dirty <= 0.0:
			generate()


func _rt_init() -> void:
	rd = RenderingServer.get_rendering_device()
	_samp = RDU.sampler(rd, true)
	_noise_shader = RDU.compile(rd, "res://compute/noise_gen.glsl")
	_noise_pipe = rd.compute_pipeline_create(_noise_shader)
	noise_rid = RDU.tex3d(rd, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, Vector3i(128, 128, 128))
	var us := rd.uniform_set_create([RDU.u_img(0, noise_rid)], _noise_shader, 0)
	RDU.run(rd, _noise_pipe, us, 16, 16, 16)
	_bake_shader = RDU.compile(rd, "res://compute/sdf_bake.glsl")
	_bake_pipe = rd.compute_pipeline_create(_bake_shader)
	_set_noise.call_deferred(noise_rid)


func _exit_tree() -> void:
	# free GPU resources (F2 reloads the whole world)
	noise_tex.texture_rd_rid = RID()
	sdf_tex.texture_rd_rid = RID()
	var res: Array = [_bake_pipe, _noise_pipe, sdf_rid, noise_rid, _samp, _bake_shader, _noise_shader]
	var dev := rd
	if dev == null:
		return
	RenderingServer.call_on_render_thread(func():
		for r in res:
			if r.is_valid():
				dev.free_rid(r))


func _set_noise(rid: RID) -> void:
	noise_tex.texture_rd_rid = rid


func generate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(P.v.seed) * 7919 + 13
	var sph := PackedFloat32Array()
	clusters.clear()
	storms.clear()
	var vst: float = P.v.vstretch
	var cum: Array = []
	for i in int(P.v.cumulus_count):
		var c := Vector3(rng.randf() * dom.x, 0.0, rng.randf() * dom.z)
		var base: float = P.v.cumulus_alt + rng.randf() * P.v.cumulus_spread
		var size: float = 240.0 * P.v.cloud_size * rng.randf_range(0.55, 1.45)
		var nb := int(P.v.billows) + rng.randi_range(-2, 3)
		var top := base
		for b in max(nb, 2):
			var a := rng.randf() * TAU
			var rr := size * sqrt(rng.randf()) * 1.25
			var fall := 1.0 - rr / (size * 1.7)
			var r := size * rng.randf_range(0.42, 0.85) * (0.55 + 0.45 * fall)
			var by := base + r * 0.5 + rng.randf() * size * 0.8 * vst * fall
			_add(sph, Vector3(c.x + cos(a) * rr, by, c.z + sin(a) * rr), r, base, false, 0.85 * vst)
			top = max(top, by + r)
		clusters.append({"pos": Vector3(c.x, (base + top) * 0.5, c.z), "r": size * 1.6, "h": top - base, "storm": false})
		cum.append({"c": c, "base": base, "size": size, "top": top})
	# web bridges: chains of billows linking neighbouring clusters into interlocked webs
	var web: float = P.v.web
	var reach: float = P.v.web_reach
	if web > 0.0:
		for i in cum.size():
			if rng.randf() > web:
				continue
			var a: Dictionary = cum[i]
			var links := 1 + (1 if rng.randf() < web * 0.6 else 0)
			var cand: Array = []
			for j in cum.size():
				if j == i:
					continue
				var b: Dictionary = cum[j]
				var dx: float = b.c.x - a.c.x
				var dz: float = b.c.z - a.c.z
				dx -= dom.x * round(dx / dom.x)
				dz -= dom.z * round(dz / dom.z)
				var dd := Vector2(dx, dz).length()
				if dd < reach:
					cand.append([dd, j, dx, dz])
			cand.sort_custom(func(p, q): return p[0] < q[0])
			for li in mini(links, cand.size()):
				var b: Dictionary = cum[cand[li][1]]
				var dd: float = cand[li][0]
				var bsz: float = minf(a.size, b.size)
				var steps := maxi(2, int(dd / (bsz * 0.55)))
				var base2: float = minf(a.base, b.base)
				for k in range(1, steps):
					var t := float(k) / steps
					var x: float = a.c.x + cand[li][2] * t + rng.randf_range(-0.2, 0.2) * bsz
					var z: float = a.c.z + cand[li][3] * t + rng.randf_range(-0.2, 0.2) * bsz
					var sag := sin(PI * t) * rng.randf_range(-0.1, 0.35) * bsz
					var r := bsz * rng.randf_range(0.32, 0.6) * (0.75 + 0.25 * cos(PI * (t - 0.5) * 2.0))
					var by: float = lerpf(a.base, b.base, t) + r * 0.6 + sag
					_add(sph, Vector3(x, by, z), r, base2, false, 0.8 * vst)
	var sw_k: float = P.v.storm_width
	var anv: float = P.v.storm_anvil
	for i in int(P.v.storm_count):
		var c := Vector3(rng.randf() * dom.x, 0.0, rng.randf() * dom.z)
		var base: float = P.v.storm_base
		var top: float = maxf(P.v.storm_top, base + 900.0)
		var y := base + 300.0 * sw_k
		var sw := rng.randf() * TAU
		# lumpy towering column: rings of smaller billows that twist as they climb
		while y < top - 350.0 * P.v.storm_anvil_thick:
			var rad := rng.randf_range(330.0, 470.0) * sw_k * (1.0 - 0.2 * (y - base) / (top - base))
			for k in 6:
				var a: float = sw + k * TAU / 6.0 + y * 0.003 * P.v.storm_twist + rng.randf_range(-0.3, 0.3)
				var off := rad * rng.randf_range(0.7, 1.15)
				_add(sph, Vector3(c.x + cos(a) * off, y + rng.randf_range(-80.0, 80.0), c.z + sin(a) * off), rad, base, true, 1.0)
			_add(sph, Vector3(c.x, y, c.z), rad * 1.1, base, true, 1.0)
			y += 240.0
		if anv > 0.02:
			for k in int(6 + 6 * anv):
				var a := rng.randf() * TAU
				var off := rng.randf_range(300.0, 1500.0) * anv * maxf(sw_k, 0.6)
				_add(sph, Vector3(c.x + cos(a) * off, top - 250.0 * P.v.storm_anvil_thick, c.z + sin(a) * off), rng.randf_range(600.0, 850.0) * (0.5 + 0.5 * anv), base, true, 0.38 * P.v.storm_anvil_thick)
		storms.append({"pos": Vector3(c.x, base, c.z), "r": 900.0 * sw_k, "top": top})
		clusters.append({"pos": Vector3(c.x, (base + top) * 0.5, c.z), "r": 1600.0 * maxf(sw_k, anv), "h": top - base, "storm": true})

	# spatial bins (16x16 over the tile) so each voxel only visits nearby billows
	var k: float = P.v.smooth_k
	var maxd := 600.0
	var bins: Array = []
	for i in 256:
		bins.append(PackedInt32Array())
	var bs := dom.x / 16.0
	var count := sph.size() / 8
	for s in count:
		var cx := sph[s * 8]
		var cz := sph[s * 8 + 2]
		var infl: float = sph[s * 8 + 3] * maxf(1.0, sph[s * 8 + 6]) + k + maxd
		var x0 := int(floor((cx - infl) / bs))
		var x1 := int(floor((cx + infl) / bs))
		var z0 := int(floor((cz - infl) / bs))
		var z1 := int(floor((cz + infl) / bs))
		for bz in range(z0, z1 + 1):
			for bx in range(x0, x1 + 1):
				var bi := posmod(bz, 16) * 16 + posmod(bx, 16)
				if not bins[bi].has(s):
					bins[bi].append(s)
	var head := PackedInt32Array()
	var idx := PackedInt32Array()
	for i in 256:
		head.append(idx.size())
		head.append(bins[i].size())
		idx.append_array(bins[i])
	if idx.is_empty():
		idx.append(0)
	if sph.is_empty():
		sph.append_array([0, -9999, 0, 1, 0, 0, 1, 0])
	var params := PackedFloat32Array([dom.x, dom.y, dom.z, 70.0 * P.v.puff,
		P.v.deck_alt, P.v.deck_thick, P.v.deck_cover, P.v.deck_bump,
		k, 1.0 if P.v.deck_on else 0.0, maxd, P.v.seed]).to_byte_array()
	var rv: int = P.v.sdf_res
	# ~20 m vertical voxels: coarser ones show up as horizontal terraces on flat cloud faces
	var ry := 160 if rv <= 384 else 224
	params.append_array(PackedInt32Array([rv, ry, rv, 0]).to_byte_array())
	var binbytes := head.to_byte_array()
	binbytes.append_array(idx.to_byte_array())
	RenderingServer.call_on_render_thread(_rt_bake.bind(sph.to_byte_array(), binbytes, params, Vector3i(rv, ry, rv)))


func _add(sph: PackedFloat32Array, c: Vector3, r: float, base: float, storm: bool, vs: float) -> void:
	sph.append_array([c.x, c.y, c.z, r, base, 1.0 if storm else 0.0, vs, 0.0])


func _rt_bake(sph: PackedByteArray, bins: PackedByteArray, params: PackedByteArray, nres: Vector3i) -> void:
	if not _bake_pipe.is_valid():
		return
	var t0 := Time.get_ticks_usec()
	var old := RID()
	if not sdf_rid.is_valid() or nres != res:
		old = sdf_rid
		res = nres
		sdf_rid = RDU.tex3d(rd, RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, res)
	var b_s := rd.storage_buffer_create(sph.size(), sph)
	var b_b := rd.storage_buffer_create(bins.size(), bins)
	var b_p := rd.storage_buffer_create(params.size(), params)
	var us := rd.uniform_set_create([
		RDU.u_img(0, sdf_rid), RDU.u_tex(1, _samp, noise_rid),
		RDU.u_ssbo(2, b_s), RDU.u_ssbo(3, b_b), RDU.u_ssbo(4, b_p)], _bake_shader, 0)
	RDU.run(rd, _bake_pipe, us, res.x / 4, res.y / 4, res.z / 4)
	var data := rd.texture_get_data(sdf_rid, 0)
	rd.free_rid(us)
	rd.free_rid(b_s)
	rd.free_rid(b_b)
	rd.free_rid(b_p)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_on_baked.call_deferred(sdf_rid, data, res, old, ms)


func _on_baked(rid: RID, data: PackedByteArray, r: Vector3i, old: RID, ms: float) -> void:
	sdf_tex.texture_rd_rid = rid
	cpu = data
	cpu_res = r
	bake_ms = ms
	ready_ok = true
	if old.is_valid():
		RenderingServer.call_on_render_thread(func(): rd.free_rid(old))
	print("Cloud SDF baked %s in %.1f ms (%d clusters, %d storms)" % [str(r), ms, clusters.size(), storms.size()])
	baked.emit()


# --- CPU queries (cloud space) -------------------------------------------

func _tex(x: int, y: int, z: int) -> float:
	x = posmod(x, cpu_res.x)
	z = posmod(z, cpu_res.z)
	y = clampi(y, 0, cpu_res.y - 1)
	return cpu.decode_half(((z * cpu_res.y + y) * cpu_res.x + x) * 4)


func sdf(p: Vector3) -> float:
	if cpu.is_empty():
		return 1000.0
	var g := Vector3(p.x / dom.x * cpu_res.x, p.y / dom.y * cpu_res.y, p.z / dom.z * cpu_res.z) - Vector3(0.5, 0.5, 0.5)
	var oy: float = max(max(-p.y, p.y - dom.y), 0.0)
	var i := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	var f := g - Vector3(i)
	var c00: float = lerp(_tex(i.x, i.y, i.z), _tex(i.x + 1, i.y, i.z), f.x)
	var c10: float = lerp(_tex(i.x, i.y + 1, i.z), _tex(i.x + 1, i.y + 1, i.z), f.x)
	var c01: float = lerp(_tex(i.x, i.y, i.z + 1), _tex(i.x + 1, i.y, i.z + 1), f.x)
	var c11: float = lerp(_tex(i.x, i.y + 1, i.z + 1), _tex(i.x + 1, i.y + 1, i.z + 1), f.x)
	return lerp(lerp(c00, c10, f.y), lerp(c01, c11, f.y), f.z) + oy


func sdf_fast(p: Vector3) -> float:
	if cpu.is_empty():
		return 1000.0
	return _tex(int(p.x / dom.x * cpu_res.x), int(p.y / dom.y * cpu_res.y), int(p.z / dom.z * cpu_res.z)) + max(max(-p.y, p.y - dom.y), 0.0)


func coverage(p: Vector3) -> float:
	return clampf(0.5 - sdf(p) / (2.0 * sdf_soft), 0.0, 1.0)


func gradient(p: Vector3) -> Vector3:
	var e := 40.0
	return Vector3(sdf_fast(p + Vector3(e, 0, 0)) - sdf_fast(p - Vector3(e, 0, 0)),
		sdf_fast(p + Vector3(0, e, 0)) - sdf_fast(p - Vector3(0, e, 0)),
		sdf_fast(p + Vector3(0, 0, e)) - sdf_fast(p - Vector3(0, 0, e))).normalized()
