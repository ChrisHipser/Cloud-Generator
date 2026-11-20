extends MultiMeshInstance3D
# Optional billboard impostors for cloud clusters beyond the raymarch range.
# They fade in across the same band where the raymarched clouds fade out.

var field: Node
var mat := ShaderMaterial.new()
var _t := 0.0


func _ready() -> void:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
#include "res://shaders/common.gdshaderinc"
uniform sampler3D noise_tex : filter_linear, repeat_enable;
uniform float far_range = 11000.0;
varying float vdist;
varying vec3 vworld;
varying vec2 vsize;
varying float vid;
void vertex() {
	vec3 c = (MODEL_MATRIX * vec4(INSTANCE_CUSTOM.xyz, 1.0)).xyz;
	vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vsize = vec2(INSTANCE_CUSTOM.w, INSTANCE_CUSTOM.w * 0.55);
	vec3 w = c + right * VERTEX.x * vsize.x + up * VERTEX.y * vsize.y * 1.4;
	vworld = w;
	vid = float(INSTANCE_ID % 17);
	vdist = length(c - CAMERA_POSITION_WORLD);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(w, 1.0);
}
void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float n = texture(noise_tex, vec3(UV * 1.3, vid * 0.06)).r;
	float n2 = texture(noise_tex, vec3(UV * 3.1 + 0.3, vid * 0.047)).g;
	float flat_b = smoothstep(-0.75, -0.45, q.y);
	float r = length(q * vec2(1.0, 1.2 - q.y * 0.3));
	float d = (1.0 - r) + (n - 0.5) * 0.7 + (n2 - 0.5) * 0.25;
	float a = smoothstep(0.0, 0.25, d) * flat_b * smoothstep(1.0, 0.75, r);
	float fade = smoothstep(far_range * 0.72, far_range, vdist) * (1.0 - smoothstep(38000.0, 52000.0, vdist));
	vec3 L = g_light_dir;
	float top = clamp(q.y * 0.5 + 0.5, 0.0, 1.0);
	float lit = clamp(0.35 + top * 0.65 + (n - 0.5) * 0.4, 0.0, 1.2);
	vec3 col = g_light_col * lit * 0.3 * (0.6 + 0.4 * max(L.y, 0.0)) + mix(g_amb_bot, g_amb_top, top);
	vec3 rd = normalize(vworld - CAMERA_POSITION_WORLD);
	col = mix(col, haze_col(rd), haze_amount(vdist) * 0.9);
	ALBEDO = col;
	ALPHA = a * fade * 0.92;
}"""
	mat.shader = sh
	# drawn BEFORE the raymarched clouds so nearer clouds composite over them
	mat.render_priority = -20
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = q
	custom_aabb = AABB(Vector3(-1e6, -1e4, -1e6), Vector3(2e6, 2e4, 2e6))


func refresh(cam: Vector3) -> void:
	_t = 0.0
	if field == null or field.clusters.is_empty():
		multimesh.instance_count = 0
		return
	var wv: Vector2 = P.wind
	var dom: Vector3 = field.dom
	var far: float = P.v.far_range
	var list: Array = []
	for c in field.clusters:
		var base: Vector3 = c.pos + Vector3(wv.x, 0, wv.y)
		var bx: float = base.x + round((cam.x - base.x) / dom.x) * dom.x
		var bz: float = base.z + round((cam.z - base.z) / dom.z) * dom.z
		for ix in range(-2, 3):
			for iz in range(-2, 3):
				var p := Vector3(bx + ix * dom.x, base.y, bz + iz * dom.z)
				var d := Vector2(p.x - cam.x, p.z - cam.z).length()
				if d > far * 0.7 and d < 52000.0:
					list.append([p, c.r * (1.6 if c.storm else 1.15)])
	multimesh.instance_count = list.size()
	for i in list.size():
		multimesh.set_instance_transform(i, Transform3D.IDENTITY)
		var p: Vector3 = list[i][0]
		multimesh.set_instance_custom_data(i, Color(p.x, p.y, p.z, list[i][1]))
	mat.set_shader_parameter("far_range", far)
