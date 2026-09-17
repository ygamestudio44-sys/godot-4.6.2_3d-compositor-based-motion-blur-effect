@tool
extends CompositorEffect
class_name MotionBlurEffect
## ---------------------------------------------------------------------------
## Derinlik + Velocity-Buffer tabanlı Motion Blur (Godot 4.3+, Forward+)
## ---------------------------------------------------------------------------
## İki hız kaynağını birlikte kullanır:
## 1) KAMERA REPROJEKSİYONU: Bu karenin derinlik değerinden dünya konumu
##    hesaplanır, önceki karenin view-projection'ıyla yeniden projekte edilir.
##    Kamera dönüşü/ötelemesi/zoom kaynaklı bulanıklığı üretir; HER pikselde
##    (derinlik olan her yerde) geçerlidir, sabit kamerada bu değer ~0 olur.
## 2) VELOCITY BUFFER (render_scene_buffers.get_velocity_layer): Godot'un
##    motion vector tamponu; hareket eden mesh/skeleton/particle gibi
##    nesnelerin (kamera sabit dursa bile) gerçek ekran-uzayı hareketini verir.
##
## Piksel bazında: velocity buffer'da anlamlı bir değer varsa (obje hareket
## ediyorsa) onu kullanırız; yoksa (gökyüzü, transparan yüzeyler, vs. -
## bunlar motion vector yazmaz) kamera-reprojeksiyon değerine düşeriz.
##
## ÖNEMLİ UYARI: Godot'ta bu velocity tamponunun tam sayısal birimi/işareti
## RESMİ OLARAK BELGELENMEMİŞ (Godot ekibi ve topluluğu bunu hâlâ deneyerek
## çözüyor). Bu yüzden `velocity_scale` parametresini ekledim ve aşağıdaki
## `debug_show_velocity` ile ham buffer'ı ekranda görselleştirip elle
## kalibre edebilirsin: obje hızını artırıp/azaltıp bulanıklık yönünün ve
## şiddetinin mantıklı göründüğü noktayı bul.
##
## KURULUM:
## 1) Proje ayarlarından Renderer = Forward+ olmalı (Mobile/Compatibility'de
##    CompositorEffect yok).
## 2) Bu .gd ve motion_blur.glsl dosyalarını projenize (ör. res://motion_blur/)
##    kopyalayın.
## 3) WorldEnvironment düğümünüzü seçin -> Environment -> Compositor
##    (yoksa yeni bir Compositor kaynağı oluşturun) -> Compositor Effects
##    dizisine "+" ile bu script'i (MotionBlurEffect.new() gibi) ya da
##    bu .gd dosyasını bir Resource olarak ekleyin.
## 4) Export edilen parametrelerden (strength, sample_count, max_velocity)
##    sahnenize göre ince ayar yapın.
## ---------------------------------------------------------------------------

## Bulanıklığın genel şiddeti. 1.0 = fizik olarak "doğru" tahmini yoğunluk.
@export_range(0.0, 4.0, 0.01) var strength: float = 1.0

## Hız vektörü boyunca alınan örnek sayısı. Yüksek = daha pürüzsüz ama daha pahalı.
@export_range(4, 32) var sample_count: int = 16

## UV uzayında izin verilen maksimum kayma (0.05 = ekran genişliğinin %5'i).
## Ani kamera sıçramalarında aşırı "yayılmayı" (smear) engeller.
@export_range(0.0, 0.2, 0.001) var max_velocity_uv: float = 0.05

## Godot'un velocity buffer'ından okunan ham değeri UV kaymasına çevirmek
## için kalibrasyon çarpanı. Godot bu formatı belgelemediği için varsayılan
## 1.0'dan başlayıp debug_show_velocity ile gözle ayarlaman gerekebilir.
@export_range(0.0, 8.0, 0.01) var object_velocity_scale: float = 1.0

## true ise, blur yerine ham hız vektörünün büyüklüğünü (kırmızı = kamera
## reprojeksiyonu, yeşil = velocity buffer) ekrana basar. Kalibrasyon içindir.
@export var debug_show_velocity: bool = false

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var copy_shader: RID
var copy_pipeline: RID
var linear_sampler: RID
var nearest_sampler: RID

var _prev_view_projection: Dictionary = {} # view(int) -> Projection
var _has_prev: Dictionary = {}             # view(int) -> bool

const GROUP_SIZE := 8


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# Hareket eden nesnelerin de bulanıklaşması için Godot'un motion vector
	# (velocity buffer) üretimini zorluyoruz. Bu, Particles/MultiMesh/Skeleton
	# için ek bir maliyet getirir ama nesne motion blur'u için zorunludur.
	needs_motion_vectors = true
	rd = RenderingServer.get_rendering_device()
	if rd:
		RenderingServer.call_on_render_thread(_initialize_compute_resources)


func _initialize_compute_resources() -> void:
	var shader_file: RDShaderFile = load("res://motion_blur/motion_blur.glsl")
	if shader_file == null:
		push_error("motion_blur.glsl bulunamadı. Dosyayı res://motion_blur/ altına koyduğunuzdan emin olun.")
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)

	var copy_shader_file: RDShaderFile = load("res://motion_blur/motion_blur_copy.glsl")
	if copy_shader_file == null:
		push_error("motion_blur_copy.glsl bulunamadı. Dosyayı res://motion_blur/ altına koyduğunuzdan emin olun.")
		return
	var copy_spirv: RDShaderSPIRV = copy_shader_file.get_spirv()
	copy_shader = rd.shader_create_from_spirv(copy_spirv)
	copy_pipeline = rd.compute_pipeline_create(copy_shader)

	var lin_state := RDSamplerState.new()
	lin_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	lin_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_sampler = rd.sampler_create(lin_state)

	var near_state := RDSamplerState.new()
	near_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	near_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	near_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	near_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	nearest_sampler = rd.sampler_create(near_state)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd:
			if shader.is_valid():
				rd.free_rid(shader)
			if copy_shader.is_valid():
				rd.free_rid(copy_shader)
			if linear_sampler.is_valid():
				rd.free_rid(linear_sampler)
			if nearest_sampler.is_valid():
				rd.free_rid(nearest_sampler)


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if not rd or p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	if not pipeline.is_valid() or not copy_pipeline.is_valid():
		return

	var render_scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var render_scene_data: RenderSceneDataRD = render_data.get_render_scene_data()
	if not render_scene_buffers or not render_scene_data:
		return

	var size: Vector2i = render_scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	var x_groups := (size.x - 1) / GROUP_SIZE + 1
	var y_groups := (size.y - 1) / GROUP_SIZE + 1

	var cam_transform: Transform3D = render_scene_data.get_cam_transform()
	var cam_projection: Projection = render_scene_data.get_cam_projection()
	# Tam view-projection = projeksiyon * view (view = kamera transformunun tersi)
	var view_projection: Projection = cam_projection * Projection(cam_transform.affine_inverse())
	var inv_view_projection: Projection = view_projection.inverse()

	var view_count: int = render_scene_buffers.get_view_count()

	for view in range(view_count):
		if not _has_prev.get(view, false):
			_prev_view_projection[view] = view_projection
			_has_prev[view] = true

		var prev_vp: Projection = _prev_view_projection[view]
		# Bu kare NDC'sinden -> dünya -> önceki kare NDC'sine tek matrisle geçiş
		var reprojection_matrix: Projection = prev_vp * inv_view_projection

		var color_image: RID = render_scene_buffers.get_color_layer(view)
		var depth_image: RID = render_scene_buffers.get_depth_layer(view)
		var velocity_image: RID = render_scene_buffers.get_velocity_layer(view)
		var has_velocity: bool = velocity_image.is_valid()
		if not has_velocity:
			# İlk birkaç karede henüz tahsis edilmemiş olabilir; bu karede
			# sadece kamera-reprojeksiyonuna düşülecek şekilde derinliği
			# tekrar kullanıyoruz (aşağıda dummy olarak depth_image veriyoruz,
			# shader binding=3'ü zaten "has_velocity=0" ile yok sayacak).
			velocity_image = depth_image

		# Bu karenin rengini, ONU ÜZERİNE YAZMADAN ÖNCE bir kopyaya alıyoruz.
		# (Compute shader aynı görüntüden hem okuyup hem yazsaydı, invocation'lar
		# arası sıralama garantisi olmadığından "yırtılma" artefaktları oluşurdu.)
		# NOT: rd.texture_copy() KULLANMIYORUZ çünkü Godot'un dahili renk
		# tamponu TEXTURE_USAGE_CAN_COPY_FROM_BIT ile işaretli değil. Onun
		# yerine ayrı bir compute geçişiyle (imageLoad/imageStore) kopyalıyoruz;
		# bu sadece storage-image erişimi gerektirir, ki tampon zaten bunu
		# destekliyor (aşağıdaki blur pipeline'ı da aynı tamponu image2D
		# olarak kullanıyor).
		var copy_name := StringName("motion_blur_copy_%d" % view)
		var color_copy: RID = render_scene_buffers.create_texture(
			"motion_blur",
			copy_name,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1,
			size,
			1, 1, true, false
		)

		var copy_uniforms: Array[RDUniform] = []
		var u_copy_src := RDUniform.new()
		u_copy_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_copy_src.binding = 0
		u_copy_src.add_id(color_image)
		copy_uniforms.append(u_copy_src)

		var u_copy_dst := RDUniform.new()
		u_copy_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_copy_dst.binding = 1
		u_copy_dst.add_id(color_copy)
		copy_uniforms.append(u_copy_dst)

		var copy_uniform_set := rd.uniform_set_create(copy_uniforms, copy_shader, 0)

		var copy_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(copy_list, copy_pipeline)
		rd.compute_list_bind_uniform_set(copy_list, copy_uniform_set, 0)
		rd.compute_list_dispatch(copy_list, x_groups, y_groups, 1)
		rd.compute_list_end()

		var uniforms: Array[RDUniform] = []

		var u_out := RDUniform.new()
		u_out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_out.binding = 0
		u_out.add_id(color_image)
		uniforms.append(u_out)

		var u_depth := RDUniform.new()
		u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_depth.binding = 1
		u_depth.add_id(nearest_sampler)
		u_depth.add_id(depth_image)
		uniforms.append(u_depth)

		var u_color_in := RDUniform.new()
		u_color_in.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_color_in.binding = 2
		u_color_in.add_id(linear_sampler)
		u_color_in.add_id(color_copy)
		uniforms.append(u_color_in)

		var u_velocity := RDUniform.new()
		u_velocity.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_velocity.binding = 3
		u_velocity.add_id(nearest_sampler)
		u_velocity.add_id(velocity_image)
		uniforms.append(u_velocity)

		var uniform_set := rd.uniform_set_create(uniforms, shader, 0)

		var pc := PackedFloat32Array()
		for col in [reprojection_matrix.x, reprojection_matrix.y, reprojection_matrix.z, reprojection_matrix.w]:
			pc.append(col.x); pc.append(col.y); pc.append(col.z); pc.append(col.w)
		pc.append(strength)
		pc.append(float(sample_count))
		pc.append(max_velocity_uv)
		pc.append(object_velocity_scale)
		pc.append(1.0 if has_velocity else 0.0)
		pc.append(1.0 if debug_show_velocity else 0.0)
		pc.append(0.0) # hizalama için yedek
		pc.append(0.0) # hizalama için yedek (toplamda 16 float boyutu olsun)

		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, pc.to_byte_array(), pc.size() * 4)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

		_prev_view_projection[view] = view_projection

	# --- Bilinen sınırlar ---
	# - Transparan malzemeler ve (motor sürümüne göre) bazı particle/skybox
	#   kurulumları velocity buffer'a yazmayabilir; bu pikseller otomatik
	#   olarak kamera-reprojeksiyon değerine düşer (shader'da has_velocity
	#   kontrolü + velocity uzunluğu eşiği ile).
	# - object_velocity_scale kalibrasyonu gerekebilir; debug_show_velocity'yi
	#   açıp obje hızını değiştirerek doğru ölçeği bulabilirsiniz.
