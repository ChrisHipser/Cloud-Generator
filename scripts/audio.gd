extends Node
# Fully procedural sound: a generative soundtrack that never loops (soft pads, kalimba
# plucks and glassy bells over slowly wandering chords, shaped by what you're doing),
# gentle air rush, a wah-wah sci-fi beam, rain, thunder, splashes, footsteps and echoing
# bird calls. Every family has its own bus so the mixer sliders can balance them.

const SR := 22050

var player: Node3D
var field: Node
var sky: Node
var streams := {}
var loops := {}
var ready_ok := false
var _task := -1
var _gen := {}
var _wind_lp: AudioEffectLowPassFilter
var _music_lp: AudioEffectLowPassFilter
var _music_rv: AudioEffectReverb
var _rng := RandomNumberGenerator.new()
var _pending_thunder: Array = []
var bird_pool: Array = []
var _bird_i := 0

# --- generative music state
var _pool: Array = []
var _pool_i := 0
var _queue: Array = []          # [delay, sample, midi, db]
var _mood := "calm"
var _chord: Array = []
var _chord_i := 0
var _chord_t := 0.0
var _note_t := 2.0
var _mel := 4
var _was_beam := false
var _was_cloud := false

const BASE_MIDI := {"pad": 57, "pluck": 69, "bell": 81}
const MOODS := {
	# D major / lydian colours by day
	"calm": {"chords": [[50, 54, 57, 61, 64], [47, 50, 54, 57, 64], [43, 47, 50, 54, 61], [45, 52, 57, 59, 64], [40, 55, 59, 62, 66]],
		"scale": [62, 64, 66, 69, 71, 74, 76, 78, 81, 83], "dur": Vector2(9.0, 14.0)},
	# above the deck: high, glassy, floating
	"high": {"chords": [[50, 57, 61, 64, 68], [52, 56, 59, 64, 68], [47, 54, 57, 61, 62], [45, 52, 57, 61, 64]],
		"scale": [69, 71, 73, 76, 78, 80, 81, 83, 85, 88], "dur": Vector2(12.0, 18.0)},
	# night: D dorian, low and hushed
	"night": {"chords": [[50, 53, 57, 60, 64], [46, 50, 53, 57, 62], [41, 48, 53, 57, 64], [48, 52, 55, 57, 62], [43, 50, 53, 58, 62]],
		"scale": [62, 64, 65, 67, 69, 72, 74, 76, 77, 79], "dur": Vector2(11.0, 16.0)},
	# near a storm: darker and sparse
	"storm": {"chords": [[38, 45, 50, 53, 57], [34, 41, 46, 50, 53], [36, 43, 48, 51, 55]],
		"scale": [57, 60, 62, 63, 65, 67, 69, 72], "dur": Vector2(8.0, 12.0)},
}


func _ready() -> void:
	_rng.randomize()
	_make_buses()
	_task = WorkerThreadPool.add_task(_generate_all)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _bus(name: String, send: String) -> int:
	var i := AudioServer.get_bus_index(name)
	if i >= 0:
		return i
	i = AudioServer.bus_count
	AudioServer.add_bus(i)
	AudioServer.set_bus_name(i, name)
	AudioServer.set_bus_send(i, send)
	return i


func _make_buses() -> void:
	var fresh := AudioServer.get_bus_index("Music") < 0
	var mi := _bus("Music", "Master")
	var wi := _bus("Wind", "Master")
	_bus("Beam", "Master")
	_bus("FX", "Master")
	_bus("Nature", "Master")
	var ei := _bus("Echo", "Nature")
	if fresh:
		var rv := AudioEffectReverb.new()
		rv.room_size = 0.9
		rv.damping = 0.45
		rv.wet = 0.42
		rv.dry = 0.75
		rv.spread = 1.0
		rv.predelay_msec = 60.0
		AudioServer.add_bus_effect(mi, rv)
		var md := AudioEffectDelay.new()
		md.tap1_active = true
		md.tap1_delay_ms = 620.0
		md.tap1_level_db = -14.0
		md.tap1_pan = -0.4
		md.tap2_active = true
		md.tap2_delay_ms = 930.0
		md.tap2_level_db = -18.0
		md.tap2_pan = 0.4
		AudioServer.add_bus_effect(mi, md)
		var mlp := AudioEffectLowPassFilter.new()
		mlp.cutoff_hz = 9000.0
		AudioServer.add_bus_effect(mi, mlp)
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 900.0
		AudioServer.add_bus_effect(wi, lp)
		var erv := AudioEffectReverb.new()
		erv.room_size = 0.95
		erv.damping = 0.35
		erv.wet = 0.55
		erv.dry = 0.6
		erv.spread = 1.0
		erv.predelay_msec = 90.0
		AudioServer.add_bus_effect(ei, erv)
		var dl := AudioEffectDelay.new()
		dl.tap1_active = true
		dl.tap1_delay_ms = 380.0
		dl.tap1_level_db = -9.0
		dl.tap2_active = true
		dl.tap2_delay_ms = 760.0
		dl.tap2_level_db = -15.0
		AudioServer.add_bus_effect(ei, dl)
	_music_rv = AudioServer.get_bus_effect(mi, 0) as AudioEffectReverb
	_music_lp = AudioServer.get_bus_effect(mi, 2) as AudioEffectLowPassFilter
	_wind_lp = AudioServer.get_bus_effect(wi, 0) as AudioEffectLowPassFilter


# ---------------------------------------------------------------- synthesis

func _noise_loop(sec: float, color: float) -> PackedFloat32Array:
	var n := int(sec * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var y := 0.0
	var rng := RandomNumberGenerator.new()
	var a := lerpf(1.0, 0.02, color)
	for i in n:
		y += (rng.randf_range(-1.0, 1.0) - y) * a
		out[i] = y
	out = _normalize(out, 0.8)
	return _loopify(out, int(0.25 * SR))


func _normalize(b: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m := 0.0001
	for v in b:
		m = max(m, absf(v))
	var k := peak / m
	for i in b.size():
		b[i] *= k
	return b


func _loopify(b: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	# crossfade the tail into the head, then drop the head so the seam is invisible
	var n := b.size()
	for i in fade:
		var t := float(i) / fade
		b[n - fade + i] = b[n - fade + i] * (1.0 - t) + b[i] * t
	return b.slice(fade, n)


func _tone(sec: float, f0: float, partials: Array, attack: float, sustain_end: float, detune: float) -> PackedFloat32Array:
	# additive voice; partials = [ratio, amp, decay/s]; release is a cosine fade after sustain_end
	var n := int(sec * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	for pr in partials:
		for det in ([-1.0, 1.0] if detune > 0.0 else [0.0]):
			var f: float = f0 * pr[0] * (1.0 + det * detune)
			var d := TAU * f / SR
			var cd := cos(d)
			var sd := sin(d)
			var c := 1.0
			var s := 0.0
			var amp: float = pr[1] * (0.5 if detune > 0.0 else 1.0)
			var k: float = exp(-pr[2] / SR)
			var env := 1.0
			for i in n:
				var nc := c * cd - s * sd
				s = c * sd + s * cd
				c = nc
				out[i] += s * amp * env
				env *= k
	var a_n := int(attack * SR)
	var r0 := int(sustain_end * SR)
	for i in n:
		var g := 1.0
		if i < a_n:
			g = smoothstep(0.0, 1.0, float(i) / a_n)
		if i > r0:
			g *= 0.5 + 0.5 * cos(PI * float(i - r0) / float(n - r0))
		out[i] *= g
	return _normalize(out, 0.7)


func _beam_loop() -> PackedFloat32Array:
	# light sci-fi "wah wah wah": a buzzy oscillator through a resonant filter swept at 4 Hz,
	# with a shimmering vibrato tone on top. Rendered twice; the settled second pass loops.
	var sec := 2.0
	var n := int(sec * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var low := 0.0
	var band := 0.0
	var ph := 0.0
	var ph2 := 0.0
	for pass_i in 2:
		for i in n:
			var t := float(i) / SR
			ph = fmod(ph + 165.0 / SR, 1.0)
			var saw := ph * 2.0 - 1.0
			var sub := sin(TAU * 82.5 * t)
			var x := saw * 0.6 + sub * 0.4
			var fc := 260.0 + 1500.0 * pow(0.5 + 0.5 * sin(TAU * 4.0 * t - PI * 0.5), 2.0)
			var f := 2.0 * sin(PI * fc / SR)
			low += f * band
			var high := x - low - 0.22 * band
			band += f * high
			ph2 += TAU * (1320.0 + 25.0 * sin(TAU * 6.0 * t)) / SR
			var shimmer := sin(ph2) * 0.08 * (0.5 + 0.5 * sin(TAU * 4.0 * t))
			if pass_i == 1:
				out[i] = band * 0.6 + low * 0.25 + shimmer
	return _normalize(out, 0.7)


func _oneshot(sec: float, fn: Callable) -> PackedFloat32Array:
	var n := int(sec * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var st := {"y": 0.0, "y2": 0.0, "ph": 0.0, "rng": RandomNumberGenerator.new()}
	for i in n:
		out[i] = fn.call(float(i) / SR, st)
	return _normalize(out, 0.9)


func _wav(b: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(b.size() * 2)
	for i in b.size():
		bytes.encode_s16(i * 2, int(clampf(b[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = b.size()
	return w


func _generate_all() -> void:
	var t0 := Time.get_ticks_msec()
	var g := {}
	g["wind_low"] = _wav(_noise_loop(3.0, 0.985), true)
	g["wind_high"] = _wav(_noise_loop(2.5, 0.8), true)
	g["rain"] = _wav(_rain(2.0), true)
	g["beam"] = _wav(_beam_loop(), true)
	# instruments (repitched per note): warm pad, kalimba-ish pluck, glassy bell
	g["pad"] = _wav(_tone(7.0, 220.0, [[1.0, 1.0, 0.05], [2.0, 0.22, 0.2], [3.0, 0.07, 0.4], [0.5, 0.3, 0.02]], 1.8, 4.0, 0.0018), false)
	g["pluck"] = _wav(_tone(3.0, 440.0, [[1.0, 1.0, 1.5], [2.0, 0.1, 4.0], [5.4, 0.06, 10.0]], 0.006, 2.2, 0.0), false)
	g["bell"] = _wav(_tone(4.0, 880.0, [[1.0, 1.0, 0.8], [2.0, 0.3, 1.4], [3.01, 0.14, 2.2], [4.2, 0.07, 3.5]], 0.012, 3.0, 0.0), false)
	for spec in [["thunder", 5.0], ["boom", 1.6], ["splash", 1.3], ["whoosh", 1.4], ["step", 0.09],
			["crunch", 0.16], ["thud", 0.5], ["bird0", 0.9], ["bird1", 1.1], ["bird2", 1.3], ["bird3", 1.0]]:
		g[spec[0]] = _wav(_oneshot(spec[1], Callable(self, "_s_" + spec[0])), false)
	_gen = g
	print("Audio synthesized in %d ms (worker thread)" % (Time.get_ticks_msec() - t0))


# one-shot generators: (t seconds, state dict) -> sample
func _nz(s: Dictionary, a: float) -> float:
	s.y += (s.rng.randf_range(-1.0, 1.0) - s.y) * a
	return s.y


func _s_thunder(t: float, s: Dictionary) -> float:
	var y := _nz(s, 0.03)
	var crack: float = s.rng.randf_range(-1.0, 1.0) * exp(-t * 9.0) * 0.6
	return y * exp(-t * 0.9) * (0.7 + 0.3 * sin(t * 7.0 + sin(t * 2.3) * 3.0)) * 4.0 + crack


func _s_boom(t: float, s: Dictionary) -> float:
	s.ph += TAU * lerpf(70.0, 28.0, min(t * 2.0, 1.0)) / SR
	return sin(s.ph) * exp(-t * 3.0) + _nz(s, 0.15) * exp(-t * 6.0) * 2.0


func _s_splash(t: float, s: Dictionary) -> float:
	var y := _nz(s, lerpf(0.9, 0.2, min(t, 1.0)))
	if s.rng.randf() < 0.002:
		s.ph = 0.0
		s.y2 = s.rng.randf_range(400.0, 1200.0)
	s.ph += 1.0 / SR
	var bub: float = sin(TAU * s.y2 * s.ph * (1.0 + s.ph * 8.0)) * exp(-s.ph * 30.0) * 0.3
	return y * exp(-t * 3.5) * (0.4 + 0.6 * exp(-t * 12.0)) + bub * exp(-t * 1.5)


func _s_whoosh(t: float, s: Dictionary) -> float:
	var e := sin(min(t / 1.4, 1.0) * PI)
	return _nz(s, lerpf(0.05, 0.6, e)) * e


func _s_step(t: float, s: Dictionary) -> float:
	return _nz(s, 0.5) * exp(-t * 60.0)


func _s_crunch(t: float, s: Dictionary) -> float:
	var v: float = s.rng.randf_range(-1.0, 1.0) * (1.0 if s.rng.randf() < 0.25 else 0.2)
	return v * exp(-t * 25.0)


func _s_thud(t: float, s: Dictionary) -> float:
	s.ph += TAU * 55.0 / SR
	return sin(s.ph) * exp(-t * 9.0) + _nz(s, 0.1) * exp(-t * 14.0)


func _s_bird0(t: float, s: Dictionary) -> float:
	var k := fmod(t, 0.15) / 0.15
	var on := 1.0 if k < 0.55 else 0.0
	s.ph += TAU * (3200.0 + 1400.0 * sin(k * 9.0) + 600.0 * sin(t * 40.0)) / SR
	return sin(s.ph) * on * sin(min(k / 0.55, 1.0) * PI)


func _s_bird1(t: float, s: Dictionary) -> float:
	s.ph += TAU * lerpf(1350.0, 760.0, min(t / 0.6, 1.0)) / SR
	var e := sin(min(t / 0.9, 1.0) * PI) * (0.8 + 0.2 * sin(t * 60.0))
	var ph: float = s.ph
	return (sin(ph) + 0.45 * sin(2.0 * ph) + 0.25 * sin(3.0 * ph)) * e * 0.6


func _s_bird2(t: float, s: Dictionary) -> float:
	s.ph += TAU * (560.0 + 40.0 * sin(t * 6.0)) / SR
	var e := 0.0
	if t < 0.5:
		e = sin(t / 0.5 * PI)
	elif t > 0.6:
		e = sin(min((t - 0.6) / 0.6, 1.0) * PI)
	var ph: float = s.ph
	return (sin(ph) + 0.6 * sin(2.0 * ph) + 0.4 * sin(3.0 * ph + 0.5) + 0.2 * sin(5.0 * ph)) * e * 0.45


func _s_bird3(t: float, s: Dictionary) -> float:
	return s.rng.randf_range(-1.0, 1.0) * exp(-fmod(t, 0.06) * 160.0) * (1.0 - t)


func _rain(sec: float) -> PackedFloat32Array:
	var n := int(sec * SR)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	var y := 0.0
	var prev := 0.0
	for i in n:
		var w := rng.randf_range(-1, 1)
		y += (w - y) * 0.35
		var hp := y - prev
		prev = y
		var drop := 0.0
		if rng.randf() < 0.004:
			drop = rng.randf_range(-1, 1) * 3.0
		out[i] = hp * 1.4 + y * 0.25 + drop
	out = _normalize(out, 0.7)
	return _loopify(out, int(0.2 * SR))


# ---------------------------------------------------------------- playback

func _loop_player(name: String, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = streams[name]
	p.bus = bus
	p.volume_db = -80.0
	add_child(p)
	p.play()
	loops[name] = p
	return p


func _vol(x: float) -> float:
	return linear_to_db(maxf(x, 0.0001))


func _process(delta: float) -> void:
	if not ready_ok:
		if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
			WorkerThreadPool.wait_for_task_completion(_task)
			streams = _gen
			_task = -1
			_loop_player("wind_low", "Wind")
			_loop_player("wind_high", "Wind")
			_loop_player("rain", "Nature")
			_loop_player("beam", "Beam")
			for i in 4:
				var b := AudioStreamPlayer3D.new()
				b.bus = "Echo"
				b.unit_size = 60.0
				b.max_distance = 900.0
				b.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
				add_child(b)
				bird_pool.append(b)
			for i in 22:
				var p := AudioStreamPlayer.new()
				p.bus = "Music"
				add_child(p)
				_pool.append(p)
			ready_ok = true
		return
	AudioServer.set_bus_volume_db(0, _vol(P.v.volume))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), _vol(P.v.music))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Wind"), _vol(P.v.wind_vol))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Beam"), _vol(P.v.beam_vol))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("FX"), _vol(P.v.fx_vol))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Nature"), _vol(P.v.nature_vol))
	if player == null:
		return
	var spd: float = player.speed
	var flying: bool = player.mode == 0
	var deck_top: float = P.v.deck_alt + P.v.deck_thick
	var above := clampf((player.global_position.y - deck_top) / 250.0, 0.0, 1.0) if P.v.deck_on else 0.0
	var sk := clampf(spd / 160.0, 0.0, 1.2)
	_setl("wind_low", (-30.0 + sk * 14.0 - above * 6.0) if flying else -36.0, 0.7 + sk * 0.3, delta)
	var hw := -46.0 + sk * 18.0 - above * 8.0
	if player.in_cloud:
		hw += 4.0
	_setl("wind_high", hw if flying else -60.0, 0.8 + sk * 0.4, delta)
	_wind_lp.cutoff_hz = lerpf(lerpf(450.0, 3200.0, clampf(sk, 0.0, 1.0)), 380.0, above)
	var beam_on: bool = player.beam_on
	_setl("beam", -4.0 if beam_on else -80.0, 0.92 + clampf(P.v.beam_power, 0.0, 8.0) * 0.03, delta * (6.0 if beam_on else 3.0))
	_setl("rain", _rain_level(), 1.0, delta)
	for th in _pending_thunder:
		th.t -= delta
		if th.t <= 0.0:
			_shot("thunder", lerpf(0.0, -22.0, clampf(th.d / 9000.0, 0.0, 1.0)) + 2.0 * th.p, _rng.randf_range(0.75, 1.05), "Nature")
	_pending_thunder = _pending_thunder.filter(func(x): return x.t > 0.0)
	_music(delta, spd, flying, above)


func _setl(n: String, db: float, pitch: float, delta: float) -> void:
	if not loops.has(n):
		return
	var p: AudioStreamPlayer = loops[n]
	p.volume_db = lerpf(p.volume_db, db, 1.0 - exp(-delta * 3.0))
	p.pitch_scale = lerpf(p.pitch_scale, max(pitch, 0.05), 1.0 - exp(-delta * 3.0))


# ---------------------------------------------------------------- generative music

func _note(sample: String, midi: float, db: float, delay := 0.0) -> void:
	_queue.append([delay, sample, midi, db])


func _play_now(sample: String, midi: float, db: float) -> void:
	if not streams.has(sample):
		return
	var p: AudioStreamPlayer = _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = streams[sample]
	p.pitch_scale = pow(2.0, (midi - BASE_MIDI[sample]) / 12.0)
	p.volume_db = db
	p.play()


func _pick_mood(above: float) -> String:
	if _rain_level() > -24.0:
		return "storm"
	if sky and _is_night():
		return "night"
	if above > 0.5:
		return "high"
	return "calm"


func _is_night() -> bool:
	var e: float = rad_to_deg(asin(clampf(sky.sun_dir_for(sky.hour).y, -1.0, 1.0)))
	return e < -5.0


func _music(dt: float, spd: float, flying: bool, above: float) -> void:
	# scheduled notes
	for q in _queue:
		q[0] -= dt
		if q[0] <= 0.0:
			_play_now(q[1], q[2], q[3])
	_queue = _queue.filter(func(q): return q[0] > 0.0)

	var energy := clampf(spd / 220.0, 0.0, 1.0) if flying else (0.15 if player.mode == 1 else 0.05)
	var in_cloud: bool = player.in_cloud
	# filter: muffled inside clouds and underwater, open in clear air
	var cut := 9000.0
	if in_cloud:
		cut = 1400.0
	if player.mode == 2:
		cut = 1800.0
	_music_lp.cutoff_hz = lerpf(_music_lp.cutoff_hz, cut, 1.0 - exp(-dt * 2.0))
	_music_rv.wet = lerpf(_music_rv.wet, 0.42 + above * 0.25, 1.0 - exp(-dt * 0.5))

	var mood := _pick_mood(above)
	_chord_t -= dt
	if _chord.is_empty() or _chord_t <= 0.0 or (mood != _mood and _chord_t < MOODS[_mood].dur.x - 3.0):
		_new_chord(mood)
	var m: Dictionary = MOODS[_mood]
	var scale: Array = m.scale

	# melody: a gentle random walk over the scale, density and pace follow your speed
	_note_t -= dt
	if _note_t <= 0.0:
		var bpm := 66.0 + energy * 46.0
		var beat := 60.0 / bpm
		var rest_p := lerpf(0.45, 0.12, energy) + (0.25 if in_cloud else 0.0)
		var choices := [1, 2, 2, 3, 4] if energy < 0.4 else [1, 1, 2, 2, 3]
		_note_t = beat * float(choices[_rng.randi() % choices.size()]) * (0.5 if energy > 0.75 and _rng.randf() < 0.4 else 1.0)
		if _rng.randf() > rest_p:
			var stepv := [-2, -1, -1, 0, 1, 1, 2]
			_mel = clampi(_mel + stepv[_rng.randi() % stepv.size()], 0, scale.size() - 1)
			if _rng.randf() < 0.3:
				_mel = _nearest_chord_tone(scale)
			var timbre := "pluck"
			if _mood == "high" or (energy < 0.25 and _rng.randf() < 0.3):
				timbre = "bell"
			if _mood == "storm" or in_cloud:
				timbre = "pad" if _rng.randf() < 0.6 else "bell"
			var octv := 12.0 if timbre == "pad" else 0.0
			var db := lerpf(-15.0, -9.0, energy) + (-4.0 if timbre == "bell" else 0.0) + (-6.0 if timbre == "pad" else 0.0)
			_note(timbre, scale[_mel] - octv, db)
			# a quick ripple of chord tones now and then when you're moving fast
			if energy > 0.55 and _rng.randf() < 0.18:
				for k in 3:
					_note("pluck", _chord[(k + 2) % _chord.size()] + 12, db - 3.0, (k + 1) * beat * 0.25)

	# little musical answers to what you do
	if player.beam_on and not _was_beam:
		for k in 3:
			_note("bell", scale[mini(scale.size() - 1, 4 + k * 2)], -14.0, k * 0.11)
	_was_beam = player.beam_on
	if in_cloud != _was_cloud:
		_note("bell" if in_cloud else "pluck", scale[_rng.randi_range(3, scale.size() - 1)], -13.0)
	_was_cloud = in_cloud


func _nearest_chord_tone(scale: Array) -> int:
	var cur: float = scale[_mel]
	var best := _mel
	var bd := 99.0
	for i in scale.size():
		for c in _chord:
			if (int(scale[i]) - int(c)) % 12 == 0:
				var d := absf(scale[i] - cur)
				if d < bd:
					bd = d
					best = i
	return best


func _new_chord(mood: String) -> void:
	_mood = mood
	var m: Dictionary = MOODS[mood]
	var cs: Array = m.chords
	var ni := _rng.randi() % cs.size()
	if cs.size() > 1 and ni == _chord_i:
		ni = (ni + 1 + _rng.randi() % (cs.size() - 1)) % cs.size()
	_chord_i = ni
	_chord = cs[ni]
	_chord_t = _rng.randf_range(m.dur.x, m.dur.y)
	# a soft pad: root an octave down plus two colour tones, staggered like breathing
	_note("pad", _chord[0] - 12, -15.0)
	_note("pad", _chord[2], -19.0, 0.6)
	_note("pad", _chord[3 + _rng.randi() % 2], -21.0, 1.3)


func _rain_level() -> float:
	if field == null or sky == null:
		return -80.0
	var pp := player.global_position
	var w: Vector2 = sky.wind
	var best := -80.0
	for s in field.storms:
		var c := Vector2(s.pos.x + w.x, s.pos.z + w.y)
		var d := Vector2(pp.x, pp.z)
		var dom: Vector3 = field.dom
		var dx: float = fposmod(d.x - c.x + dom.x * 0.5, dom.x) - dom.x * 0.5
		var dz: float = fposmod(d.y - c.y + dom.z * 0.5, dom.z) - dom.z * 0.5
		var r := Vector2(dx, dz).length()
		if r < s.r * 1.6 and pp.y < s.pos.y + 400.0:
			best = max(best, lerpf(-4.0, -30.0, clampf((r - s.r * 0.7) / (s.r * 0.9), 0.0, 1.0)))
	return best


func _shot(n: String, db: float, pitch := 1.0, bus := "FX") -> void:
	if not streams.has(n):
		return
	var p := AudioStreamPlayer.new()
	p.stream = streams[n]
	p.volume_db = db
	p.pitch_scale = pitch
	p.bus = bus
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)


func whoosh(power: float) -> void:
	_shot("whoosh", -18.0 + power * 6.0, 0.8 + power * 0.15)


func splash(power: float) -> void:
	_shot("splash", -10.0 + power * 6.0, 1.15 - power * 0.15)


func boom() -> void:
	_shot("boom", 0.0, 1.0)
	_shot("whoosh", -6.0, 0.6)
	if ready_ok and not _chord.is_empty():
		# a swelling chord as you break the sound barrier
		for k in 3:
			_note("pad", _chord[k + 1], -13.0, k * 0.08)
		_note("bell", _chord[0] + 24, -12.0, 0.3)


func boost() -> void:
	_shot("whoosh", -14.0, 1.3)
	if ready_ok and not _chord.is_empty():
		for k in 4:
			_note("pluck", _chord[k % _chord.size()] + 12, -14.0, k * 0.09)


func land(power: float) -> void:
	_shot("thud", -12.0 + power * 6.0)
	if ready_ok and not _chord.is_empty():
		_note("pluck", _chord[0], -16.0, 0.15)


func step(snow: bool) -> void:
	_shot("crunch" if snow else "step", -16.0 if snow else -20.0, _rng.randf_range(0.85, 1.15))


func thunder(pos: Vector3, delay: float, power: float) -> void:
	_pending_thunder.append({"t": min(delay, 12.0), "d": delay * 343.0, "p": power})


func bird(pos: Vector3, species: int) -> void:
	if not ready_ok:
		return
	var b: AudioStreamPlayer3D = bird_pool[_bird_i]
	_bird_i = (_bird_i + 1) % bird_pool.size()
	b.stream = streams["bird%d" % species]
	b.global_position = pos
	b.pitch_scale = _rng.randf_range(0.85, 1.15)
	b.volume_db = -6.0
	b.play()
