extends CanvasLayer
# Minimal, whimsical flight HUD (attitude, speed, altitude, heading), clock + FPS (top left),
# shortcut list (left), options split into columns along the left and right edges (no
# scrolling, never over the centre), a sound mixer pop-out, pause, exit confirmation.

var player: Node3D
var rig: Node3D
var sky: Node
var fluid: Node
var field: Node

var root := Control.new()
var fx := ColorRect.new()
var inst := Control.new()
var keys_panel := PanelContainer.new()
var opt_toggle := Button.new()
var snd_toggle := Button.new()
var snd_panel := PanelContainer.new()
var confirm := ConfirmationDialog.new()
var toast := Label.new()
var _toast_t := 0.0
var controls := {}
var options_open := false
var sound_open := false
var user_paused := false
var font := SystemFont.new()
var font_b := SystemFont.new()
var _gpu_ms := 0.0
var _cpu_ms := 0.0
var hud_visible := true
var _keys_wanted := true

var _cols: Array = []           # 4 option columns: L1, R1, L2, R2
var _sections: Array = []       # {node, box, est}

const COL_W := 280.0
const ROW_H := 22.0
const TOP_L := 96.0
const TOP_R := 52.0

const INK := Color(1.0, 0.97, 0.9)
const INK_DIM := Color(1.0, 0.97, 0.9, 0.55)
const SHADOW := Color(0.04, 0.06, 0.12, 0.42)
const CORAL := Color(1.0, 0.56, 0.42)
const MINT := Color(0.62, 1.0, 0.86)
const SKYC := Color(0.66, 0.88, 1.0)
const WARM := Color(1.0, 0.8, 0.5)

const KEYS := [
	["W / S", "Pitch (S climbs)"],
	["A / D", "Yaw"],
	["Q / E", "Roll"],
	["Shift / Ctrl", "Throttle up / down (to 500 m/s)"],
	["Space / LMB", "Cloud beam  ·  on foot: jump, hold = launch"],
	["M", "Mouse steering"],
	["C", "Camera: first person / chase / free"],
	["Middle drag", "Look around (3rd person)"],
	["T", "Reset camera"],
	["Scroll", "Zoom  ·  Alt + scroll: field of view"],
	["N", "+90 minutes"],
	["V", "New weather"],
	["Caps Lock", "Pause"],
	["1 - 4", "Quality preset"],
	["R", "Respawn above the clouds"],
	["F2", "Reload world (keeps settings)"],
	["O  /  K", "Options  /  sound mixer"],
	["H  /  F1", "Hide this list  /  hide HUD"],
	["F11  /  Esc", "Fullscreen  /  exit"],
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	font.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Helvetica Neue", "Arial"])
	font_b.font_names = font.font_names
	font_b.font_weight = 600
	var th := Theme.new()
	th.default_font = font
	th.default_font_size = 13
	root.theme = th
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform float speed_k = 0.0;
uniform float super_k = 0.0;
uniform float aspect = 1.777;
uniform float px = 0.001;
uniform float tt = 0.0;
float h(float x) { return fract(sin(x * 91.345) * 47453.5453); }
void fragment() {
	vec2 c = UV - 0.5;
	c.x *= aspect;
	float r = length(c);
	float a = atan(c.y, c.x) / 6.28318 + 0.5;
	float N = 360.0;
	float fa = a * N;
	float id = floor(fa);
	float rnd = h(id);
	float lane = step(1.0 - (0.05 + speed_k * 0.16 + super_k * 0.12), rnd);
	// hair-thin lines: distance to the lane centre in screen units
	float dc = abs(fract(fa) - 0.5) * (6.28318 / N) * r;
	float line = smoothstep(px * 1.1, 0.0, dc);
	float ph = fract(r * (1.2 + rnd * 1.5) - tt * (0.6 + speed_k * 2.2 + super_k * 3.0) - rnd * 7.0);
	float dash = smoothstep(0.0, 0.12, ph) * smoothstep(0.7, 0.25, ph);
	float streak = lane * line * dash * smoothstep(0.34, 0.85, r) * (speed_k * 0.16 + super_k * 0.14);
	float vig = smoothstep(0.62, 1.25, r) * (0.16 + super_k * 0.1);
	float al = streak + vig;
	COLOR = vec4(vec3(streak / max(al, 1e-3)) * vec3(0.95, 0.98, 1.0), clamp(al, 0.0, 0.6));
}"""
	var sm := ShaderMaterial.new()
	sm.shader = sh
	fx.material = sm
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fx)

	inst.set_anchors_preset(Control.PRESET_FULL_RECT)
	inst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inst.draw.connect(_draw_inst)
	root.add_child(inst)

	_build_keys()
	_build_options()
	_build_sound()

	toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast.position = Vector2(-250, 74)
	toast.size = Vector2(500, 30)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.add_theme_font_size_override("font_size", 18)
	toast.add_theme_color_override("font_color", INK)
	toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	toast.add_theme_constant_override("shadow_offset_x", 1)
	toast.add_theme_constant_override("shadow_offset_y", 2)
	toast.modulate.a = 0.0
	root.add_child(toast)

	confirm.title = "Leave the sky?"
	confirm.dialog_text = "Exit Cloud Glider?"
	confirm.ok_button_text = "Exit"
	confirm.cancel_button_text = "Keep flying"
	confirm.process_mode = Node.PROCESS_MODE_ALWAYS
	confirm.confirmed.connect(func(): get_tree().quit())
	confirm.canceled.connect(func(): get_tree().paused = user_paused)
	add_child(confirm)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	get_viewport().size_changed.connect(_layout_options)


func _unhandled_input(e: InputEvent) -> void:
	if player and player.tour:
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.physical_keycode:
		KEY_CAPSLOCK:
			user_paused = not user_paused
			get_tree().paused = user_paused
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			ask_exit()
			get_viewport().set_input_as_handled()


func _panel_style(alpha := 0.62) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.03, 0.05, 0.08, alpha)
	s.border_color = Color(1.0, 0.95, 0.85, 0.12)
	s.set_border_width_all(1)
	s.set_corner_radius_all(10)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s


func _build_keys() -> void:
	keys_panel.add_theme_stylebox_override("panel", _panel_style(0.42))
	keys_panel.position = Vector2(14, TOP_L)
	keys_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(keys_panel)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 1)
	keys_panel.add_child(g)
	for k in KEYS:
		var a := Label.new()
		a.text = k[0]
		a.add_theme_font_override("font", font_b)
		a.add_theme_font_size_override("font_size", 13)
		a.add_theme_color_override("font_color", WARM)
		g.add_child(a)
		var b := Label.new()
		b.text = k[1]
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0, 0.88))
		g.add_child(b)


func _toggle_btn(b: Button, text: String, x: float) -> void:
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	b.position = Vector2(x, 12)
	b.size = Vector2(104, 30)
	root.add_child(b)


func _build_options() -> void:
	_toggle_btn(opt_toggle, "Options  ◂", -118)
	opt_toggle.pressed.connect(func(): set_options(not options_open))
	for i in 4:
		var pc := PanelContainer.new()
		pc.add_theme_stylebox_override("panel", _panel_style(0.74))
		pc.visible = false
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		pc.add_child(vb)
		root.add_child(pc)
		_cols.append(pc)

	var cur: Dictionary = {}
	for d in P.defs:
		if d.type == "section":
			if d.label == "Sound":
				cur = {}
				continue
			var holder := VBoxContainer.new()
			holder.add_theme_constant_override("separation", 2)
			var hb := Button.new()
			hb.text = "▾  " + d.label
			hb.alignment = HORIZONTAL_ALIGNMENT_LEFT
			hb.flat = true
			hb.focus_mode = Control.FOCUS_NONE
			hb.custom_minimum_size.y = 24
			hb.add_theme_font_override("font", font_b)
			hb.add_theme_color_override("font_color", WARM)
			holder.add_child(hb)
			var box := VBoxContainer.new()
			box.add_theme_constant_override("separation", 2)
			holder.add_child(box)
			cur = {"node": holder, "box": box, "rows": 0}
			_sections.append(cur)
			var label: String = d.label
			hb.pressed.connect(func():
				box.visible = not box.visible
				hb.text = ("▾  " if box.visible else "▸  ") + label
				_layout_options())
			continue
		if cur.is_empty():
			continue
		cur.box.add_child(_make_control(d))
		cur.rows += 1
	P.changed.connect(_sync_control)
	_layout_options()


func _build_sound() -> void:
	_toggle_btn(snd_toggle, "Sound  ♪", -230)
	snd_toggle.pressed.connect(func(): set_sound(not sound_open))
	snd_panel.add_theme_stylebox_override("panel", _panel_style(0.74))
	snd_panel.visible = false
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	snd_panel.add_child(vb)
	var t := Label.new()
	t.text = "Sound mixer"
	t.add_theme_font_override("font", font_b)
	t.add_theme_color_override("font_color", WARM)
	vb.add_child(t)
	var in_sound := false
	for d in P.defs:
		if d.type == "section":
			in_sound = d.label == "Sound"
			continue
		if in_sound:
			vb.add_child(_make_control(d))
	root.add_child(snd_panel)


func _layout_options() -> void:
	if _cols.is_empty():
		return
	var vs := root.get_viewport_rect().size
	var avail_l := vs.y - TOP_L - 12.0
	var avail_r := vs.y - TOP_R - 12.0
	for s in _sections:
		var n: Node = s.node
		if n.get_parent():
			n.get_parent().remove_child(n)
	var order := [0, 1, 2, 3]
	var ci := 0
	var used := 0.0
	for s in _sections:
		var box: VBoxContainer = s.box
		var h: float = 26.0 + (s.rows * (ROW_H + 2.0) if box.visible else 0.0)
		var avail: float = avail_l if order[ci] % 2 == 0 else avail_r
		if used > 0.0 and used + h > avail - 16.0 and ci < 3:
			ci += 1
			used = 0.0
		(_cols[order[ci]].get_child(0) as VBoxContainer).add_child(s.node)
		used += h + 2.0
	var xs := [14.0, vs.x - 14.0 - COL_W, 14.0 + COL_W + 8.0, vs.x - 14.0 - COL_W * 2.0 - 8.0]
	for i in 4:
		var pc: PanelContainer = _cols[i]
		pc.position = Vector2(xs[i], TOP_L if i % 2 == 0 else TOP_R)
		pc.custom_minimum_size = Vector2(COL_W, 0)
		pc.size = Vector2(COL_W, 0)
		pc.reset_size()
		pc.visible = options_open and pc.get_child(0).get_child_count() > 0
	snd_panel.position = Vector2(vs.x - 14.0 - COL_W, TOP_R)
	snd_panel.custom_minimum_size = Vector2(COL_W, 0)
	snd_panel.reset_size()


func _tip(c: Control, n: String) -> void:
	var t: String = P.tips.get(n, "")
	if t != "":
		c.tooltip_text = t + "\n(right-click to reset)"
	else:
		c.tooltip_text = "Right-click to reset"


func _reset_on_right_click(c: Control, n: String) -> void:
	c.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			P.reset(n)
			c.accept_event())


func _make_control(d: Dictionary) -> Control:
	var n: String = d.get("name", "")
	match d.type:
		"float":
			var row := HBoxContainer.new()
			row.custom_minimum_size.y = ROW_H
			row.mouse_filter = Control.MOUSE_FILTER_PASS
			var l := Label.new()
			l.text = d.label
			l.custom_minimum_size.x = 122
			l.clip_text = true
			l.mouse_filter = Control.MOUSE_FILTER_PASS
			l.add_theme_font_size_override("font_size", 12)
			l.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0, 0.9))
			var s := HSlider.new()
			s.min_value = d.min
			s.max_value = d.max
			s.step = d.step if d.step > 0.0 else (d.max - d.min) / 200.0
			s.value = P.v[n]
			s.focus_mode = Control.FOCUS_NONE
			s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var val := Label.new()
			val.custom_minimum_size.x = 42
			val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			val.mouse_filter = Control.MOUSE_FILTER_PASS
			val.add_theme_font_size_override("font_size", 12)
			val.add_theme_color_override("font_color", SKYC)
			val.text = _fmt(P.v[n])
			s.value_changed.connect(func(x):
				val.text = _fmt(x)
				P.setv(n, float(x)))
			row.add_child(l)
			row.add_child(s)
			row.add_child(val)
			for c in [row, l, s, val]:
				_tip(c, n)
			_reset_on_right_click(s, n)
			_reset_on_right_click(l, n)
			controls[n] = [s, val]
			return row
		"bool":
			var c := CheckBox.new()
			c.text = d.label
			c.custom_minimum_size.y = ROW_H
			c.add_theme_font_size_override("font_size", 12)
			c.button_pressed = P.v[n]
			c.focus_mode = Control.FOCUS_NONE
			c.toggled.connect(func(b): P.setv(n, b))
			_tip(c, n)
			_reset_on_right_click(c, n)
			controls[n] = [c]
			return c
		"choice":
			var row := HBoxContainer.new()
			row.custom_minimum_size.y = ROW_H
			var l := Label.new()
			l.text = d.label
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.mouse_filter = Control.MOUSE_FILTER_PASS
			l.add_theme_font_size_override("font_size", 12)
			row.add_child(l)
			var o := OptionButton.new()
			o.focus_mode = Control.FOCUS_NONE
			o.add_theme_font_size_override("font_size", 12)
			var opts: Array = d.options
			for i in opts.size():
				o.add_item(str(opts[i]), i)
				if opts[i] == P.v[n]:
					o.select(i)
			o.item_selected.connect(func(i):
				if n == "preset":
					P.apply_preset(i)
				else:
					P.setv(n, opts[i]))
			row.add_child(o)
			_tip(l, n)
			_tip(o, n)
			_reset_on_right_click(o, n)
			controls[n] = [o, opts]
			return row
		"button":
			var b := Button.new()
			b.text = d.label
			b.custom_minimum_size.y = ROW_H
			b.add_theme_font_size_override("font_size", 12)
			b.focus_mode = Control.FOCUS_NONE
			b.pressed.connect(func(): P.press(n))
			_tip(b, n)
			return b
	return Control.new()


func _fmt(x: float) -> String:
	if absf(x) >= 100.0:
		return "%d" % roundi(x)
	return "%.2f" % x


func _sync_control(n: String, _c: String) -> void:
	if n == "preset_applied":
		var o: OptionButton = controls["preset"][0]
		var opts: Array = controls["preset"][1]
		o.select(opts.find(P.v.preset))
		for k in controls:
			_sync_control(k, "")
		return
	if not controls.has(n):
		return
	var c = controls[n][0]
	if c is HSlider:
		c.set_value_no_signal(P.v[n])
		controls[n][1].text = _fmt(P.v[n])
	elif c is CheckBox:
		c.set_pressed_no_signal(P.v[n])
	elif c is OptionButton:
		var idx: int = controls[n][1].find(P.v[n])
		if idx >= 0:
			c.select(idx)


func set_options(open: bool) -> void:
	options_open = open
	if open and sound_open:
		set_sound(false)
	opt_toggle.text = "Options  ▸" if open else "Options  ◂"
	keys_panel.visible = hud_visible and _keys_wanted and not open
	_layout_options()


func set_sound(open: bool) -> void:
	sound_open = open
	if open and options_open:
		set_options(false)
	snd_panel.visible = open
	_layout_options()


func toggle_keys() -> void:
	_keys_wanted = not _keys_wanted
	keys_panel.visible = hud_visible and _keys_wanted and not options_open


func set_hud_visible(on: bool) -> void:
	hud_visible = on
	keys_panel.visible = on and _keys_wanted and not options_open
	opt_toggle.visible = on
	snd_toggle.visible = on


func any_panel_open() -> bool:
	return options_open or sound_open


func show_toast(t: String) -> void:
	toast.text = t
	_toast_t = 2.2


func ask_exit() -> void:
	get_tree().paused = true
	confirm.popup_centered(Vector2i(320, 120))


func _process(delta: float) -> void:
	_toast_t -= delta
	toast.modulate.a = clampf(_toast_t, 0.0, 1.0)
	_gpu_ms = lerpf(_gpu_ms, RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()), 0.05)
	_cpu_ms = lerpf(_cpu_ms, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.05)
	if player:
		var m := fx.material as ShaderMaterial
		var vs := root.get_viewport_rect().size
		m.set_shader_parameter("aspect", vs.x / max(vs.y, 1.0))
		m.set_shader_parameter("px", 1.0 / max(vs.y, 1.0))
		m.set_shader_parameter("speed_k", clampf((player.speed - 60.0) / 260.0, 0.0, 1.0) if player.mode == 0 else 0.0)
		m.set_shader_parameter("super_k", player.super_k)
		m.set_shader_parameter("tt", Time.get_ticks_msec() / 1000.0)
		fx.visible = hud_visible
	inst.queue_redraw()


# ------------------------------------------------------------- drawing helpers

const SH_OFF := Vector2(0.0, 0.8)


func _line(a: Vector2, b: Vector2, c: Color, w := 1.5) -> void:
	# soft dark halo underneath so every stroke reads against white cloud
	inst.draw_line(a + SH_OFF, b + SH_OFF, Color(SHADOW, SHADOW.a * c.a), w + 2.4, true)
	inst.draw_line(a, b, c, w, true)


func _poly(pts: PackedVector2Array, c: Color, w := 1.5) -> void:
	var s := PackedVector2Array()
	for p in pts:
		s.append(p + SH_OFF)
	inst.draw_polyline(s, Color(SHADOW, SHADOW.a * c.a), w + 2.4, true)
	inst.draw_polyline(pts, c, w, true)


func _tri(p: Vector2, dir: Vector2, size: float, c: Color) -> void:
	var n := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([p + dir * size, p - dir * size * 0.6 + n * size * 0.75, p - dir * size * 0.6 - n * size * 0.75])
	var sp := PackedVector2Array()
	for q in pts:
		sp.append(q + SH_OFF)
	inst.draw_colored_polygon(sp, Color(SHADOW, SHADOW.a * c.a))
	inst.draw_colored_polygon(pts, c)


func _arc(c: Vector2, r: float, a0: float, a1: float, col: Color, w := 1.5) -> void:
	inst.draw_arc(c + SH_OFF, r, a0, a1, 48, Color(SHADOW, SHADOW.a * col.a), w + 1.2, true)
	inst.draw_arc(c, r, a0, a1, 48, col, w, true)


func _txt(p: Vector2, s: String, size := 13, col := INK, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0, bold := false) -> void:
	var f := font_b if bold else font
	inst.draw_string_outline(f, p + SH_OFF, s, align, w, size, 5 if size >= 20 else 4, Color(SHADOW, minf(SHADOW.a * col.a * 1.3, 0.6)))
	inst.draw_string(f, p, s, align, w, size, col)


func _dashed(a: Vector2, b: Vector2, c: Color, dash := 7.0) -> void:
	var l := a.distance_to(b)
	var d := (b - a) / maxf(l, 0.001)
	var t := 0.0
	while t < l:
		_line(a + d * t, a + d * minf(t + dash, l), c, 1.3)
		t += dash * 2.0


func _cloud_glyph(p: Vector2, s: float, c: Color) -> void:
	for o in [Vector2(-0.6, 0.15), Vector2(0.0, -0.2), Vector2(0.6, 0.15)]:
		inst.draw_circle(p + o * s + SH_OFF, s * (0.55 if o.y < 0 else 0.42), Color(SHADOW, SHADOW.a * c.a))
	for o in [Vector2(-0.6, 0.15), Vector2(0.0, -0.2), Vector2(0.6, 0.15)]:
		inst.draw_circle(p + o * s, s * (0.55 if o.y < 0 else 0.42), c)


# ------------------------------------------------------------- instruments

func _draw_inst() -> void:
	if player == null:
		return
	var vs := inst.size
	if user_paused:
		_txt(Vector2(0, vs.y * 0.42), "paused", 40, INK, HORIZONTAL_ALIGNMENT_CENTER, vs.x, true)
		_txt(Vector2(0, vs.y * 0.42 + 30), "Caps Lock to drift on", 14, INK_DIM, HORIZONTAL_ALIGNMENT_CENTER, vs.x)
	if not hud_visible:
		return
	_draw_info(vs)
	var cx := vs.x * 0.5
	var ctr := vs * 0.5
	var b := player.global_transform.basis.orthonormalized()
	var fwd := -b.z
	var spd: float = player.speed
	var cam: Camera3D = rig.cam
	var flying: bool = player.mode == 0

	# --- reticle / mouse aim
	var aimp: Vector3 = player.global_position + (player.aim_dir if P.v.mouse_steer else fwd) * 400.0
	if not cam.is_position_behind(aimp):
		var sp := cam.unproject_position(aimp)
		_arc(sp, 6.0, 0, TAU, Color(1, 1, 1, 0.7), 1.2)
		inst.draw_circle(sp, 1.3, Color(1, 1, 1, 0.8))
		if player.charge > 0.01:
			var full: bool = player.charge >= 0.99
			_arc(sp, 22.0, -PI * 0.5, -PI * 0.5 + TAU * player.charge, WARM if not full else MINT, 3.0)
			_txt(sp + Vector2(-80, 46), "lift-off!" if full else ("hop" if player.charge < 0.3 else "hold to launch…"), 13, WARM, HORIZONTAL_ALIGNMENT_CENTER, 160)

	# --- heading ribbon (top)
	var hdg := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	if absf(fwd.y) > 0.97:
		hdg = fposmod(rad_to_deg(atan2(b.y.x * signf(-fwd.y), -b.y.z * signf(-fwd.y))), 360.0)
	var tw := 360.0
	var ty := 30.0
	for i in range(-20, 21):
		var deg: float = floorf(hdg / 5.0) * 5.0 + i * 5.0
		var x: float = cx + (deg - hdg) * 4.0
		var off := absf(x - cx) / (tw * 0.5)
		if off > 1.0:
			continue
		var al := 1.0 - off * off
		var d := fposmod(deg, 360.0)
		var major := int(d) % 30 == 0
		_line(Vector2(x, ty + 10), Vector2(x, ty + (2 if major else 6)), Color(INK, 0.6 * al), 1.2)
		if major:
			var card := {0: "N", 90: "E", 180: "S", 270: "W"}
			var lab: String = str(card.get(int(d), str(int(d / 10.0))))
			_txt(Vector2(x - 20, ty - 2), lab, 13 if card.has(int(d)) else 11, Color(WARM if card.has(int(d)) else INK, al), HORIZONTAL_ALIGNMENT_CENTER, 40, card.has(int(d)))
	_tri(Vector2(cx, ty + 15), Vector2(0, -1), 5.0, CORAL)
	_txt(Vector2(cx - 30, ty + 34), "%03d°" % int(hdg), 12, INK_DIM, HORIZONTAL_ALIGNMENT_CENTER, 60)

	if flying:
		_draw_attitude(vs, ctr, b, cam)
	_draw_speed(Vector2(cx - 300.0, ctr.y), spd)
	_draw_alt(Vector2(cx + 300.0, ctr.y))

	# --- status tags (bottom centre)
	var tags: Array = []
	if player.super_on: tags.append(["supersonic", WARM])
	elif player.boosting and flying: tags.append(["boost", SKYC])
	if player.stall_k > 0.05 and flying: tags.append(["stall", CORAL])
	if player.in_cloud: tags.append(["in cloud", INK])
	if player.beam_on: tags.append(["beam", SKYC])
	if player.mode == 1: tags.append(["on foot", MINT])
	if player.mode == 2: tags.append(["swimming", SKYC])
	if P.v.mouse_steer: tags.append(["mouse aim", INK_DIM])
	if rig.view == 2: tags.append(["free camera", INK_DIM])
	var tot := 0.0
	for t in tags:
		tot += 18.0 + t[0].length() * 7.5 + 8.0
	var tx := cx - tot * 0.5
	for t in tags:
		var w: float = 18.0 + t[0].length() * 7.5
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0, 0, 0, 0)
		st.border_color = Color(t[1], 0.6)
		st.set_border_width_all(1)
		st.set_corner_radius_all(11)
		inst.draw_style_box(st, Rect2(tx, vs.y - 52, w, 22))
		_txt(Vector2(tx, vs.y - 36), t[0], 12, t[1], HORIZONTAL_ALIGNMENT_CENTER, w)
		tx += w + 8.0


func _draw_info(vs: Vector2) -> void:
	# clock (with a tiny sun / moon), FPS and a one-line status: always visible
	var hh: float = sky.hour
	var clock := "%02d:%02d" % [int(hh), int(fmod(hh, 1.0) * 60.0)]
	var e: float = rad_to_deg(asin(clampf(sky.sun_dir_for(hh).y, -1.0, 1.0)))
	var phase := "night"
	if e > 24.0: phase = "midday" if absf(hh - 12.0) < 2.5 else ("morning" if hh < 12.0 else "afternoon")
	elif e > 6.0: phase = "golden hour"
	elif e > -1.0: phase = "sunrise" if hh < 12.0 else "sunset"
	elif e > -9.0: phase = "blue hour"
	var ic := Vector2(26, 34)
	if e > -1.0:
		inst.draw_circle(ic + SH_OFF, 8.0, Color(SHADOW, 0.4))
		inst.draw_circle(ic, 8.0, WARM)
		for k in 8:
			var a := k * TAU / 8.0 + hh
			_line(ic + Vector2(cos(a), sin(a)) * 11.0, ic + Vector2(cos(a), sin(a)) * 14.0, WARM, 1.5)
	else:
		inst.draw_circle(ic + SH_OFF, 8.0, Color(SHADOW, 0.4))
		inst.draw_circle(ic, 8.0, Color(0.92, 0.94, 1.0))
		inst.draw_circle(ic + Vector2(4, -3), 7.0, Color(0.25, 0.3, 0.45))
	_txt(Vector2(46, 44), clock, 28, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_txt(Vector2(132, 43), phase, 14, WARM)
	var fps := Engine.get_frames_per_second()
	_txt(Vector2(16, 66), "%d fps   gpu %.1f · cpu %.1f ms" % [fps, _gpu_ms, _cpu_ms], 12, INK if fps >= 55 else CORAL)
	var ov: float = P.v.overcast
	var wx := "clear" if ov < 0.25 else ("hazy" if ov < 0.6 else "overcast")
	var ns: int = field.storms.size() if field else 0
	_txt(Vector2(16, 83), "%s · %s · %d storm%s" % [P.v.preset, wx, ns, "" if ns == 1 else "s"], 12, INK_DIM)


func _draw_attitude(vs: Vector2, ctr: Vector2, b: Basis, cam: Camera3D) -> void:
	var fwd := -b.z
	var bank := atan2(-b.x.y, b.y.y)
	var pitch := rad_to_deg(asin(clampf(fwd.y, -1, 1)))
	var ppd := vs.y / cam.fov
	var rot := Transform2D(-bank, ctr)
	var lim := vs.y * 0.28

	# horizon line with a gap for the little glider, ground-side ticks at its ends
	var hy := pitch * ppd
	var clamped := absf(hy) > lim
	var hyc := clampf(hy, -lim, lim)
	var hc := Color(INK, 0.85 if not clamped else 0.45)
	if clamped:
		_dashed(rot * Vector2(-250, hyc), rot * Vector2(-54, hyc), hc)
		_dashed(rot * Vector2(54, hyc), rot * Vector2(250, hyc), hc)
		# chevrons point back toward the horizon
		var dir := signf(hy)
		for k in 2:
			var cy := hyc - dir * (26.0 + k * 14.0)
			_poly(PackedVector2Array([rot * Vector2(-14, cy - dir * 7), rot * Vector2(0, cy + dir * 3), rot * Vector2(14, cy - dir * 7)]), Color(CORAL, 0.75), 2.0)
	else:
		_line(rot * Vector2(-250, hy), rot * Vector2(-54, hy), hc, 1.6)
		_line(rot * Vector2(54, hy), rot * Vector2(250, hy), hc, 1.6)
		_line(rot * Vector2(-250, hy), rot * Vector2(-250, hy + 8), hc, 1.6)
		_line(rot * Vector2(250, hy), rot * Vector2(250, hy + 8), hc, 1.6)

	# pitch ladder: short rungs every 10 deg near the current pitch (dashed below the horizon)
	for k in range(-9, 10):
		if k == 0:
			continue
		var a := k * 10.0
		var y := (pitch - a) * ppd
		if absf(y) > lim:
			continue
		var al := (1.0 - absf(y) / lim) * 0.7
		var c := Color(INK, al)
		var half := 30.0 if absf(a) < 45.0 else 22.0
		if a > 0:
			_line(rot * Vector2(-half - 24, y), rot * Vector2(-24, y), c, 1.2)
			_line(rot * Vector2(24, y), rot * Vector2(half + 24, y), c, 1.2)
		else:
			_dashed(rot * Vector2(-half - 24, y), rot * Vector2(-24, y), c, 4.0)
			_dashed(rot * Vector2(24, y), rot * Vector2(half + 24, y), c, 4.0)
		_txt(rot * Vector2(half + 28, y + 4), str(int(absf(a))), 10, c)

	# the little glider symbol (fixed): a gull-wing "w"
	var g := Color(CORAL, 0.95)
	_poly(PackedVector2Array([ctr + Vector2(-34, 2), ctr + Vector2(-16, 2), ctr + Vector2(-8, 9), ctr + Vector2(0, 2), ctr + Vector2(8, 9), ctr + Vector2(16, 2), ctr + Vector2(34, 2)]), g, 2.4)
	inst.draw_circle(ctr + Vector2(0, 2), 2.2, g)

	# bank scale (fixed arc on top) and the sky pointer that rolls with the horizon
	var rb := 150.0
	_arc(ctr, rb, deg_to_rad(-150), deg_to_rad(-30), Color(INK, 0.35), 1.2)
	for dg in [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60]:
		var ang := deg_to_rad(-90.0 + dg)
		var l := 10.0 if dg % 30 == 0 else 5.0
		var u := Vector2(cos(ang), sin(ang))
		_line(ctr + u * rb, ctr + u * (rb + l), Color(INK, 0.6 if dg != 0 else 0.9), 1.3)
	var pa := -PI * 0.5 - bank
	var pu := Vector2(cos(pa), sin(pa))
	_tri(ctr + pu * (rb - 9.0), pu, 7.0, CORAL)
	var bd := rad_to_deg(bank)
	if absf(bd) > 2.0:
		_txt(ctr + pu * (rb - 28.0) + Vector2(-24, 4), "%d°" % roundi(absf(bd)), 11, Color(INK, 0.8), HORIZONTAL_ALIGNMENT_CENTER, 48)

	# flight-path marker: where you're actually going
	if player.speed > 3.0:
		var fp: Vector3 = player.global_position + player.vel.normalized() * 400.0
		if not cam.is_position_behind(fp):
			var s := cam.unproject_position(fp)
			var mc := Color(MINT, 0.85)
			_arc(s, 5.0, 0, TAU, mc, 1.5)
			_line(s + Vector2(-15, 0), s + Vector2(-5, 0), mc, 1.5)
			_line(s + Vector2(5, 0), s + Vector2(15, 0), mc, 1.5)
			_line(s + Vector2(0, -5), s + Vector2(0, -11), mc, 1.5)

	# stall
	if player.stall_k > 0.05:
		var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() / 110.0)
		_txt(ctr + Vector2(-100, 74), "stall", 20, Color(CORAL, player.stall_k * pulse), HORIZONTAL_ALIGNMENT_CENTER, 200, true)
		_txt(ctr + Vector2(-100, 94), "let the nose drop to gather speed", 12, Color(INK, player.stall_k * 0.8), HORIZONTAL_ALIGNMENT_CENTER, 200)


func _draw_speed(c: Vector2, spd: float) -> void:
	# tape without a background: ticks on the right edge, value to the left, throttle bug
	var h := 260.0
	var ppu := 2.2
	var top := c.y - h * 0.5
	for i in range(-14, 15):
		var val: float = floorf(spd / 10.0) * 10.0 + i * 10.0
		if val < 0.0:
			continue
		var y: float = c.y - (val - spd) * ppu
		if absf(y - c.y) > h * 0.5:
			continue
		var al := 1.0 - pow(absf(y - c.y) / (h * 0.5), 2.0)
		var major := int(round(val)) % 50 == 0
		_line(Vector2(c.x, y), Vector2(c.x - (12.0 if major else 6.0), y), Color(INK, 0.7 * al), 1.2)
		if major and absf(y - c.y) > 16.0:
			_txt(Vector2(c.x - 64, y + 4), str(int(val)), 11, Color(INK, 0.65 * al), HORIZONTAL_ALIGNMENT_RIGHT, 46)
	# sound barrier tick
	var ys: float = c.y - (343.0 - spd) * ppu
	if absf(ys - c.y) < h * 0.5:
		_line(Vector2(c.x + 2, ys), Vector2(c.x - 18, ys), Color(WARM, 0.9), 2.0)
		_txt(Vector2(c.x + 6, ys + 4), "sound", 10, WARM)
	# throttle bug
	var thr: float = player.throttle
	var yt: float = clampf(c.y - (thr - spd) * ppu, top, top + h)
	_tri(Vector2(c.x + 8, yt), Vector2(-1, 0), 6.0, CORAL)
	_txt(Vector2(c.x + 16, yt + 4), "%d" % roundi(thr), 11, Color(CORAL, 0.9))
	# value
	_tri(Vector2(c.x - 4, c.y), Vector2(1, 0), 5.0, INK)
	_txt(Vector2(c.x - 110, c.y + 10), "%d" % roundi(spd), 28, INK, HORIZONTAL_ALIGNMENT_RIGHT, 92, true)
	_txt(Vector2(c.x - 110, c.y + 26), "m/s", 11, INK_DIM, HORIZONTAL_ALIGNMENT_RIGHT, 92)
	var y2 := top + h + 22.0
	_txt(Vector2(c.x - 110, y2), "throttle %d" % roundi(thr), 11, Color(CORAL, 0.85), HORIZONTAL_ALIGNMENT_RIGHT, 110)
	if spd > 80.0:
		_txt(Vector2(c.x - 110, y2 + 16), "mach %.2f" % (spd / 343.0), 11, INK_DIM, HORIZONTAL_ALIGNMENT_RIGHT, 110)
	_txt(Vector2(c.x - 110, top - 10), "%.1f g" % player.gload, 11, INK_DIM, HORIZONTAL_ALIGNMENT_RIGHT, 110)


func _draw_alt(c: Vector2) -> void:
	var alt: float = player.global_position.y
	var h := 260.0
	var ppu := 0.5
	var top := c.y - h * 0.5
	for i in range(-14, 15):
		var val: float = floorf(alt / 50.0) * 50.0 + i * 50.0
		var y: float = c.y - (val - alt) * ppu
		if absf(y - c.y) > h * 0.5:
			continue
		var al := 1.0 - pow(absf(y - c.y) / (h * 0.5), 2.0)
		var major := int(round(val)) % 100 == 0
		_line(Vector2(c.x, y), Vector2(c.x + (12.0 if major else 6.0), y), Color(INK, 0.7 * al), 1.2)
		if major and absf(y - c.y) > 16.0:
			_txt(Vector2(c.x + 16, y + 4), str(int(val)), 11, Color(INK, 0.65 * al))
	# cloud deck band and the ground
	if P.v.deck_on:
		var d0: float = P.v.deck_alt
		var d1: float = d0 + P.v.deck_thick
		var y0 := clampf(c.y - (d0 - alt) * ppu, top, top + h)
		var y1 := clampf(c.y - (d1 - alt) * ppu, top, top + h)
		if y0 - y1 > 1.0:
			inst.draw_line(Vector2(c.x - 3, y0), Vector2(c.x - 3, y1), Color(1, 1, 1, 0.45), 4.0)
			_cloud_glyph(Vector2(c.x - 14, (y0 + y1) * 0.5), 5.0, Color(1, 1, 1, 0.7))
	var gy: float = c.y + player.agl * ppu
	if gy < top + h:
		for k in 5:
			_line(Vector2(c.x, gy + k * 5.0), Vector2(c.x + 10, gy + k * 5.0 - 5.0), Color(MINT, 0.6), 1.2)
	_tri(Vector2(c.x + 4, c.y), Vector2(-1, 0), 5.0, INK)
	_txt(Vector2(c.x + 16, c.y + 10), "%d" % roundi(alt), 28, INK, HORIZONTAL_ALIGNMENT_LEFT, -1, true)
	_txt(Vector2(c.x + 16, c.y + 26), "m", 11, INK_DIM)
	var vsp: float = player.vspeed
	var arrow := "▲" if vsp > 0.3 else ("▼" if vsp < -0.3 else "•")
	_txt(Vector2(c.x + 16, top + h + 22), "%s %.1f m/s" % [arrow, absf(vsp)], 11, MINT if vsp >= 0.0 else SKYC)
	_txt(Vector2(c.x + 16, top + h + 38), "%d above ground" % roundi(player.agl), 11, INK_DIM)
