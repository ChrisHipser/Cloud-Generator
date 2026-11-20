extends Node
# Global tweakable parameter registry (autoload "P").
# The options panels are generated from `defs`; systems read `P.v.<name>`.
# Values persist between sessions in user://settings.cfg (right-click a slider to reset it).

signal changed(pname: String, cat: String)

const SAVE_PATH := "user://settings.cfg"

var defs: Array = []
var v: Dictionary = {}
var defaults: Dictionary = {}
var tips: Dictionary = {}
var cats: Dictionary = {}
var wind := Vector2.ZERO   # accumulated cloud drift (world = cloud + wind)
var _save_t := -1.0
var _persist := true

const PRESETS := [
	{"name": "Low", "grid_q": 64, "pressure_iters": 0, "steps": 44, "light_q": 2.0, "step_scale": 1.5, "render_scale": 0.6, "sdf_res": 256},
	{"name": "Medium", "grid_q": 96, "pressure_iters": 2, "steps": 64, "light_q": 3.0, "step_scale": 1.15, "render_scale": 0.75, "sdf_res": 384},
	{"name": "High", "grid_q": 128, "pressure_iters": 4, "steps": 88, "light_q": 4.0, "step_scale": 1.0, "render_scale": 0.9, "sdf_res": 384},
	{"name": "Ultra", "grid_q": 160, "pressure_iters": 8, "steps": 128, "light_q": 5.0, "step_scale": 0.8, "render_scale": 1.0, "sdf_res": 512},
]


func _init() -> void:
	_sec("Flight")
	_bool("mouse_steer", "Mouse steering (M)", false, "flight", "The nose eases toward the mouse reticle. Mouse is captured while flying.")
	_f("mouse_sens", "Mouse sensitivity", 1.0, 0.2, 3.0, "flight", 0.0, "How far the aim reticle moves per mouse movement.")
	_bool("invert_pitch", "Inverted pitch (S climbs)", true, "flight", "Airplane-style pitch: S pulls the nose up, W pushes it down.")
	_f("control_rate", "Control responsiveness", 1.0, 0.4, 2.0, "flight", 0.0, "Multiplies pitch, roll and yaw rates.")
	_f("auto_level", "Wing auto-level", 0.35, 0.0, 1.5, "flight", 0.0, "Gently rolls the wings level when you let go of Q/E. Never fights you once you're past 70 degrees of bank or inverted. Never touches pitch.")
	_f("fov", "Field of view", 74.0, 30.0, 110.0, "flight", 1.0, "Base camera field of view. Alt + scroll changes it too.")
	_f("cam_shake", "Camera shake", 1.0, 0.0, 2.0, "flight", 0.0, "Shake from speed, splashes, sonic booms and thunder.")

	_sec("Cloud look")
	_f("puff", "Puffiness", 0.85, 0.0, 1.5, "look", 0.0, "How deeply the billow noise carves into each cloud. Higher = lumpier cauliflower tops.")
	_f("billow_scale", "Billow size (m)", 420.0, 150.0, 1600.0, "look", 0.0, "Size of the individual cauliflower billows.")
	_f("detail", "Fine detail", 0.6, 0.0, 1.5, "look", 0.0, "Small-scale erosion on cloud edges.")
	_f("tendril", "Tendrils", 0.5, 0.0, 1.5, "look", 0.0, "Swirling domain-warp that pulls edges into wispy tendrils.")
	_f("edge_soft", "Edge softness", 0.10, 0.02, 0.4, "look", 0.0, "Low = crisp, solid-looking edges. High = soft, misty edges.")
	_f("density", "Fullness", 1.0, 0.2, 3.0, "look", 0.0, "Optical density of the cloud body.")
	_f("transparency", "Subtle transparency", 0.1, 0.0, 0.9, "look", 0.0, "Lets a little light through thin parts.")
	_f("mist", "Mist halo", 0.35, 0.0, 2.0, "look", 0.0, "Faint haze around each cloud.")
	_f("reflectivity", "Reflectivity", 1.0, 0.3, 2.0, "look", 0.0, "How much direct sun / moon light the clouds scatter back.")
	_f("silver", "Silver lining", 1.0, 0.0, 2.5, "look", 0.0, "Bright rim when looking toward the sun through cloud edges.")
	_f("solidness", "Solid shading", 0.6, 0.0, 1.0, "look", 0.0, "Adds surface-like shading from the cloud's shape, so it reads as a solid form.")
	_f("shadow_dark", "Self-shadowing", 1.0, 0.2, 2.5, "look", 0.0, "How dark the shaded undersides get.")
	_f("drift", "Wind drift", 1.0, 0.0, 5.0, "look", 0.0, "How fast the whole cloudscape drifts with the wind.")

	_sec("Cumulus")
	_f("seed", "Seed", 7.0, 1.0, 99.0, "spawn", 1.0, "Changes the layout of every cloud.")
	_f("cumulus_count", "Cumulus count", 70.0, 0.0, 220.0, "spawn", 1.0, "Number of cumulus clusters in the 16 km tile.")
	_f("cloud_size", "Cloud size", 1.0, 0.4, 2.5, "spawn", 0.0, "Overall size of each cumulus cluster.")
	_f("billows", "Billows per cloud", 9.0, 3.0, 20.0, "spawn", 1.0, "How many blobs make up each cluster.")
	_f("vstretch", "Tower-iness", 1.0, 0.4, 2.5, "spawn", 0.0, "Stretches clusters upward into towers.")
	_f("cumulus_alt", "Base altitude", 850.0, 300.0, 2500.0, "spawn", 10.0, "Flat cloud-base height (m).")
	_f("cumulus_spread", "Altitude spread", 350.0, 0.0, 900.0, "spawn", 10.0, "Random variation of the cloud base between clusters.")
	_f("smooth_k", "Blob melt", 90.0, 10.0, 600.0, "spawn", 1.0, "Smooth-union radius: how much neighbouring blobs melt together.")
	_f("web", "Web bridges", 0.35, 0.0, 1.0, "spawn", 0.0, "Fraction of clusters that grow billowy bridges to their neighbours, forming interlocked webs.")
	_f("web_reach", "Web reach (m)", 1400.0, 300.0, 4000.0, "spawn", 50.0, "How far apart two clusters can be and still get bridged.")

	_sec("Cloud deck")
	_bool("deck_on", "Cloud deck shelf", true, "spawn", "A flat shelf of cloud with gaps. Fly above it for the dreamscape.")
	_f("deck_alt", "Deck altitude", 2000.0, 1200.0, 2800.0, "spawn", 10.0, "Height of the deck's underside (m).")
	_f("deck_thick", "Deck thickness", 200.0, 40.0, 1200.0, "spawn", 10.0, "Vertical thickness of the deck (m).")
	_f("deck_cover", "Deck coverage", 0.55, 0.1, 0.95, "spawn", 0.0, "Fraction of the sky the deck covers. Lower = more gaps.")
	_f("deck_bump", "Deck bumpiness", 1.0, 0.0, 2.5, "spawn", 0.0, "Rolling lumps on the deck's top and bottom.")

	_sec("Thunderheads")
	_f("storm_count", "Thunderheads", 2.0, 0.0, 6.0, "spawn", 1.0, "Number of storm towers (with rain and lightning) in the tile.")
	_f("storm_top", "Tower top (m)", 2850.0, 1500.0, 3150.0, "spawn", 10.0, "Altitude of the anvil.")
	_f("storm_base", "Tower base (m)", 260.0, 60.0, 1200.0, "spawn", 10.0, "Altitude where the dark storm base starts.")
	_f("storm_width", "Tower width", 1.0, 0.4, 2.5, "spawn", 0.0, "Scales the width of the column.")
	_f("storm_anvil", "Anvil spread", 1.0, 0.0, 2.5, "spawn", 0.0, "How far the flat anvil top spreads out.")
	_f("storm_anvil_thick", "Anvil thickness", 1.0, 0.3, 2.5, "spawn", 0.0, "Vertical thickness of the anvil.")
	_f("storm_twist", "Tower twist", 1.0, 0.0, 3.0, "spawn", 0.0, "How much the billow rings twist as they climb.")

	_sec("Fluid simulation")
	_bool("fluid_on", "Fluid near-field", true, "fluid", "Clouds close to you are simulated as a fluid you can push and carve.")
	_f("transition", "Fluid > solid distance (m)", 320.0, 120.0, 700.0, "fluid", 5.0, "Radius of the simulated zone. Beyond it clouds are the solid far field.")
	_choice("grid_q", "Fluid grid", [64, 96, 128, 160, 192], 96, "fluid_grid", "Simulation resolution. Higher = finer holes and wakes, more GPU.")
	_choice("pressure_iters", "Pressure iterations", [0, 2, 4, 8, 16], 2, "fluid", "Makes the air incompressible (rolling swirls). More = more GPU.")
	_f("heal", "Heal rate", 0.12, 0.01, 1.0, "fluid", 0.0, "How quickly holes and wakes fill back in.")
	_f("wake", "Wake interaction", 1.0, 0.0, 3.0, "fluid", 0.0, "How strongly your body drags, parts and bores through the fluid clouds.")
	_f("wake_turb", "Wake turbulence", 1.0, 0.0, 4.0, "fluid", 0.0, "Churning eddies left behind in your wake.")
	_f("swirl", "Wingtip vortices", 1.0, 0.0, 3.0, "fluid", 0.0, "Twin rolling vortices off the wingtips.")
	_f("turbulence", "Ambient turbulence", 0.6, 0.0, 3.0, "fluid", 0.0, "Gentle living motion inside clouds.")
	_f("splash", "Entry / exit splash", 1.0, 0.0, 3.0, "fluid", 0.0, "Size of the crown splash on entering and the puffed exit wound on leaving.")
	_f("boost_puff", "Boost puff", 1.0, 0.0, 3.0, "fluid", 0.0, "Force burst that shoves clouds away when you pass 120 m/s and the sound barrier.")

	_sec("Cloud beam")
	_f("beam_len", "Beam length (m)", 320.0, 60.0, 700.0, "fluid", 5.0, "Reach of the beam. It only carves inside the fluid zone.")
	_f("beam_radius", "Beam radius (m)", 26.0, 6.0, 80.0, "fluid", 0.0, "Width of the beam where it leaves you.")
	_f("beam_cone", "Far-end width", 1.6, 0.2, 6.0, "fluid", 0.0, "Diameter multiplier at the far end. Above 1 = a widening cone, below 1 = a narrowing spear.")
	_f("beam_power", "Beam power", 1.5, 0.2, 8.0, "fluid", 0.0, "How fast the beam dissolves and blows cloud aside.")

	_sec("Graphics")
	_choice("preset", "Quality preset (1-4)", ["Low", "Medium", "High", "Ultra"], "Medium", "preset", "Sets resolution, march steps, lighting and fluid grid together.")
	_f("render_scale", "Render scale", 0.75, 0.4, 1.0, "gfx", 0.05, "3D resolution before FSR upscaling. Big GPU lever.")
	_f("steps", "Cloud march steps", 64.0, 24.0, 160.0, "gfx", 1.0, "Samples per pixel along each view ray.")
	_f("light_q", "Lighting quality", 3.0, 1.0, 5.0, "gfx", 1.0, "1 = single scattering. 3 = multiple-scattering octaves + sun shafts. 5 = longer shadow rays and three scattering orders.")
	_f("step_scale", "March step size", 1.15, 0.6, 2.5, "gfx", 0.0, "Larger steps = faster, grainier clouds.")
	_f("far_range", "Solid cloud range (m)", 11000.0, 4000.0, 16000.0, "gfx", 100.0, "Raymarch distance. Beyond it, billboard impostors take over.")
	_choice("sdf_res", "Cloud field resolution", [256, 384, 512], 384, "spawn", "Resolution of the baked far-field distance volume.")
	_bool("impostors", "Far billboard impostors", true, "gfx", "Cheap billboard clouds beyond the raymarch range.")
	_bool("vsync", "V-Sync", true, "gfx", "Lock to the display refresh rate.")

	_sec("Sky & weather")
	_f("time_flow", "Time flow (min / sec)", 0.5, 0.0, 30.0, "sky", 0.0, "Game minutes per real second. 0 stops the clock.")
	_f("sun_linger", "Golden-hour linger", 0.85, 0.0, 0.95, "sky", 0.0, "How much the sun and moon slow down near the horizon. 0.85 = roughly half the day is sunrise / sunset light.")
	_f("sunset_rich", "Sunset richness", 1.2, 0.3, 2.5, "sky", 0.0, "Atmospheric thickness the low sun shines through. Higher = deeper reds.")
	_f("overcast", "High overcast", 0.1, 0.0, 1.0, "sky", 0.0, "Grey high-altitude sheet that dims the sun.")
	_f("cirrus", "Cirrus", 0.7, 0.0, 1.5, "sky", 0.0, "Wispy ice-crystal clouds high above.")
	_f("stars", "Star brightness", 1.0, 0.0, 3.0, "sky", 0.0, "Stars, Milky Way and galaxies at night.")
	_button("new_weather", "Roll new weather", "sky", "Randomise overcast, cirrus, cloud counts and storms (V).")

	_sec("Sound")
	_f("volume", "Master", 0.8, 0.0, 1.0, "audio", 0.0, "Everything.")
	_f("music", "Music", 0.55, 0.0, 1.0, "audio", 0.0, "The generative soundtrack that follows what you're doing.")
	_f("wind_vol", "Air rush", 0.35, 0.0, 1.0, "audio", 0.0, "Wind noise that rises with speed.")
	_f("beam_vol", "Beam", 0.5, 0.0, 1.0, "audio", 0.0, "The wah-wah cloud beam.")
	_f("fx_vol", "Effects", 0.7, 0.0, 1.0, "audio", 0.0, "Whooshes, splashes, booms, landings and footsteps.")
	_f("nature_vol", "Nature", 0.7, 0.0, 1.0, "audio", 0.0, "Birds, rain and thunder.")

	for k in v:
		defaults[k] = v[k]
	_persist = not ("--shots" in OS.get_cmdline_user_args())
	if _persist:
		_load()


func _sec(t: String) -> void:
	defs.append({"type": "section", "label": t})


func _f(n: String, label: String, d: float, lo: float, hi: float, cat: String, step: float = 0.0, tip: String = "") -> void:
	defs.append({"type": "float", "name": n, "label": label, "min": lo, "max": hi, "step": step})
	v[n] = d
	cats[n] = cat
	tips[n] = tip


func _bool(n: String, label: String, d: bool, cat: String, tip: String = "") -> void:
	defs.append({"type": "bool", "name": n, "label": label})
	v[n] = d
	cats[n] = cat
	tips[n] = tip


func _choice(n: String, label: String, options: Array, d, cat: String, tip: String = "") -> void:
	defs.append({"type": "choice", "name": n, "label": label, "options": options})
	v[n] = d
	cats[n] = cat
	tips[n] = tip


func _button(n: String, label: String, cat: String, tip: String = "") -> void:
	defs.append({"type": "button", "name": n, "label": label})
	cats[n] = cat
	tips[n] = tip


func setv(n: String, val) -> void:
	if v.has(n) and typeof(v[n]) == typeof(val) and v[n] == val:
		return
	v[n] = val
	_save_t = 1.0
	changed.emit(n, cats.get(n, "ui"))


func reset(n: String) -> void:
	if defaults.has(n):
		setv(n, defaults[n])


func press(n: String) -> void:
	changed.emit(n, cats[n])


func apply_preset(i: int) -> void:
	var p: Dictionary = PRESETS[clampi(i, 0, PRESETS.size() - 1)]
	for key in p:
		if key == "name":
			continue
		var val = p[key]
		if typeof(v[key]) == TYPE_FLOAT:
			val = float(val)
		setv(key, val)
	v["preset"] = p["name"]
	_save_t = 1.0
	changed.emit("preset_applied", "ui")


func _process(delta: float) -> void:
	if _save_t > 0.0:
		_save_t -= delta
		if _save_t <= 0.0:
			save()


func _exit_tree() -> void:
	if _save_t > 0.0:
		save()


func save() -> void:
	_save_t = -1.0
	if not _persist:
		return
	var cf := ConfigFile.new()
	for k in v:
		cf.set_value("params", k, v[k])
	cf.save(SAVE_PATH)


func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	for k in cf.get_section_keys("params"):
		if v.has(k) and typeof(cf.get_value("params", k)) == typeof(v[k]):
			v[k] = cf.get_value("params", k)
