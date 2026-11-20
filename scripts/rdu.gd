extends RefCounted
# Small RenderingDevice helpers shared by the compute-driven systems.


static func compile(rd: RenderingDevice, path: String) -> RID:
	var file: RDShaderFile = load(path)
	if file == null:
		push_error("Cannot load compute shader " + path)
		return RID()
	var spirv: RDShaderSPIRV = file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("Compute compile error in %s:\n%s" % [path, spirv.compile_error_compute])
		print("COMPUTE ERROR ", path, "\n", spirv.compile_error_compute)
		return RID()
	return rd.shader_create_from_spirv(spirv)


static func tex3d(rd: RenderingDevice, format: int, n: Vector3i) -> RID:
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.format = format
	tf.width = n.x
	tf.height = n.y
	tf.depth = n.z
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var rid := rd.texture_create(tf, RDTextureView.new(), [])
	rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid


static func tex2d(rd: RenderingDevice, format: int, w: int, h: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.format = format
	tf.width = w
	tf.height = h
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(tf, RDTextureView.new(), [])


static func sampler(rd: RenderingDevice, repeat: bool) -> RID:
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	var m := RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT if repeat else RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_u = m
	s.repeat_v = m
	s.repeat_w = m
	return rd.sampler_create(s)


static func u_tex(binding: int, samp: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(samp)
	u.add_id(tex)
	return u


static func u_img(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


static func u_ubo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


static func u_ssbo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


static func run(rd: RenderingDevice, pipeline: RID, uset: RID, gx: int, gy: int, gz: int) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_dispatch(cl, gx, gy, gz)
	rd.compute_list_end()
