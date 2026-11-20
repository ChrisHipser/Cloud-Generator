extends Node
# Near-field compute fluid around the player (cloud space). Owns the GPU grid,
# feeds it the player wake, the beam and splash events every frame.

const RDU = preload("res://scripts/rdu.gd")

var field: Node
var rd: RenderingDevice
var N := 96
var cell := 7.0
var origin := Vector3.ZERO
var dens_tex := Texture3DRD.new()
var t := {}
var shader := RID()
var pipe := RID()
var uset := RID()
var pbuf := RID()
var samp := RID()
var _sdf_bound := RID()
var _ok := false
var _reseed := true
var _time := 0.0

var player_pos := Vector3.ZERO   # cloud space
var player_vel := Vector3.ZERO   # relative to cloud frame
var player_right := Vector3.RIGHT
var beam_on := false
var beam_start := Vector3.ZERO
var beam_dir := Vector3.FORWARD
var beam_len := 160.0
var events: Array = []


func _ready() -> void:
	N = int(P.v.grid_q)
	RenderingServer.call_on_render_thread(_rt_init.bind(N))
	P.changed.connect(_on_param)


func _on_param(n: String, _cat: String) -> void:
	if n == "grid_q":
		var nn := int(P.v.grid_q)
		if nn != N:
			N = nn
			_ok = false
			RenderingServer.call_on_render_thread(_rt_init.bind(N))
	elif n == "transition" or n == "fluid_on":
		_reseed = true


func extent() -> float:
	return N * cell


func _rt_init(n: int) -> void:
	rd = RenderingServer.get_rendering_device()
	if not shader.is_valid():
		shader = RDU.compile(rd, "res://compute/fluid.glsl")
		pipe = rd.compute_pipeline_create(shader)
		samp = RDU.sampler(rd, true)
		pbuf = rd.storage_buffer_create(16 * 16 + 16 * 16 * 2)
	for k in t:
		if t[k].is_valid():
			rd.free_rid(t[k])
	if uset.is_valid() and rd.uniform_set_is_valid(uset):
		rd.free_rid(uset)
	uset = RID()
	var sz := Vector3i(n, n, n)
	var f16 := RenderingDevice.DATA_FORMAT_R16_SFLOAT
	var v16 := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	t = {
		"velA": RDU.tex3d(rd, v16, sz), "velB": RDU.tex3d(rd, v16, sz),
		"densA": RDU.tex3d(rd, f16, sz), "densB": RDU.tex3d(rd, f16, sz),
		"prA": RDU.tex3d(rd, f16, sz), "prB": RDU.tex3d(rd, f16, sz),
		"div": RDU.tex3d(rd, f16, sz),
	}
	_sdf_bound = RID()
	_finish_init.call_deferred(t["densA"])


func _exit_tree() -> void:
	# free GPU resources (F2 reloads the whole world)
	_ok = false
	dens_tex.texture_rd_rid = RID()
	var res: Array = [uset, pipe]
	for k in t:
		res.append(t[k])
	res.append_array([pbuf, samp, shader])
	var dev := rd
	if dev == null:
		return
	RenderingServer.call_on_render_thread(func():
		for r in res:
			if r.is_valid():
				dev.free_rid(r))


func _finish_init(rid: RID) -> void:
	dens_tex.texture_rd_rid = rid
	_reseed = true
	_ok = true


func debug_dump() -> void:
	var o := origin
	var c := cell
	RenderingServer.call_on_render_thread(func():
		var d := rd.texture_get_data(t.densA, 0)
		_debug_report.call_deferred(d, o, c))


func _debug_report(d: PackedByteArray, o: Vector3, c: float) -> void:
	var rng := RandomNumberGenerator.new()
	var sd := 0.0
	var st := 0.0
	var diff := 0.0
	var nan := 0
	var cnt := 0
	for k in 3000:
		var i := Vector3i(rng.randi() % N, rng.randi() % N, rng.randi() % N)
		var v := d.decode_half(((i.z * N + i.y) * N + i.x) * 2)
		var p := o + (Vector3(i) + Vector3(0.5, 0.5, 0.5)) * c
		var tg: float = field.coverage(p)
		if is_nan(v):
			nan += 1
			continue
		sd += v
		st += tg
		diff += absf(v - tg)
		cnt += 1
	print("FLUID DEBUG N=%d cell=%.2f origin=%s player=%s meanD=%.4f meanT=%.4f meanAbsDiff=%.4f nan=%d" % [N, c, str(o.round()), str(player_pos.round()), sd / max(cnt, 1), st / max(cnt, 1), diff / max(cnt, 1), nan])


func add_event(type: int, pos: Vector3, dir: Vector3, strength: float, life: float) -> void:
	events.append({"type": type, "pos": pos, "dir": dir, "s": strength, "age": 0.0, "life": life})
	if events.size() > 8:
		events.pop_front()


func step(delta: float) -> void:
	if not _ok or field == null or not field.sdf_rid.is_valid():
		return
	_time += delta
	var dt: float = min(delta, 1.0 / 30.0)
	cell = (2.0 * P.v.transition + 60.0) / N
	var half := extent() * 0.5
	var want := ((player_pos - Vector3(half, half, half)) / cell).floor() * cell
	var sh := Vector3i(roundi((want.x - origin.x) / cell), roundi((want.y - origin.y) / cell), roundi((want.z - origin.z) / cell))
	if _reseed:
		sh = Vector3i(N, N, N)
		_reseed = false
	origin = want

	for e in events:
		e.age += dt
		if e.type == 3:
			e.pos = player_pos - player_vel.normalized() * 6.0
		elif e.type == 4:
			e.pos = player_pos
	events = events.filter(func(e): return e.age < e.life)

	var f := PackedFloat32Array()
	f.append_array([origin.x, origin.y, origin.z, cell])
	var head := f.to_byte_array()
	head.append_array(PackedInt32Array([sh.x, sh.y, sh.z, N]).to_byte_array())
	var g := PackedFloat32Array()
	g.append_array([field.dom.x, field.dom.y, field.dom.z, field.sdf_soft])
	var spd := player_vel.length()
	g.append_array([player_pos.x, player_pos.y, player_pos.z, 7.0 + minf(spd, 200.0) * 0.09])
	g.append_array([player_vel.x, player_vel.y, player_vel.z, spd])
	g.append_array([beam_start.x, beam_start.y, beam_start.z, 1.0 if beam_on else 0.0])
	g.append_array([beam_dir.x, beam_dir.y, beam_dir.z, beam_len])
	g.append_array([P.v.beam_radius, P.v.beam_power, _time, dt])
	g.append_array([P.v.heal, P.v.wake, P.v.swirl, P.v.turbulence])
	g.append_array([P.v.splash, 0.5, P.v.beam_cone, P.v.wake_turb])
	g.append_array([player_right.x, player_right.y, player_right.z, 0.0])
	for i in 8:
		if i < events.size():
			var e: Dictionary = events[i]
			var st: float = e.s * pow(1.0 - e.age / e.life, 1.5)
			g.append_array([e.pos.x, e.pos.y, e.pos.z, float(e.type), e.dir.x, e.dir.y, e.dir.z, st])
		else:
			g.append_array([0, 0, 0, 0, 0, 0, 0, 0])
	head.append_array(g.to_byte_array())
	var iters := int(P.v.pressure_iters)
	RenderingServer.call_on_render_thread(_rt_step.bind(head, iters, field.sdf_rid, field.noise_rid))


func _rt_step(bytes: PackedByteArray, iters: int, sdf_rid: RID, noise_rid: RID) -> void:
	if not t.has("velA"):
		return
	if not uset.is_valid() or _sdf_bound != sdf_rid or not rd.uniform_set_is_valid(uset):
		_sdf_bound = sdf_rid
		uset = rd.uniform_set_create([
			RDU.u_img(0, t.velA), RDU.u_img(1, t.velB), RDU.u_img(2, t.densA), RDU.u_img(3, t.densB),
			RDU.u_img(4, t.prA), RDU.u_img(5, t.prB), RDU.u_img(6, t.div),
			RDU.u_tex(7, samp, sdf_rid), RDU.u_tex(8, samp, noise_rid), RDU.u_ssbo(9, pbuf)], shader, 0)
	rd.buffer_update(pbuf, 0, bytes.size(), bytes)
	var g := N / 8
	var seq := [0, 1, 2]
	if iters > 0:
		seq.append(3)
		for i in iters:
			seq.append(4 if i % 2 == 0 else 5)
		seq.append(6)
	seq.append(7)
	for mode in seq:
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		var pc := PackedInt32Array([mode, 0, 0, 0]).to_byte_array()
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, g, g, g)
		rd.compute_list_end()
