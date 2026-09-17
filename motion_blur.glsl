#[compute]
#version 450

// -----------------------------------------------------------------------
// Derinlik + kamera-reprojeksiyon + velocity-buffer tabanlı motion blur.
//
// binding 0: bu karenin renk tamponu (yazma hedefi)
// binding 1: derinlik tamponu (nearest sampler)
// binding 2: bu karenin renginin KOPYASI (linear sampler, örnekleme kaynağı)
// binding 3: Godot'un velocity/motion-vector tamponu (nearest sampler)
// -----------------------------------------------------------------------

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_output;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D color_input;
layout(set = 0, binding = 3) uniform sampler2D velocity_tex;

layout(push_constant, std430) uniform Params {
	mat4 reprojection_matrix; // prev_view_projection * inverse(current_view_projection)
	float strength;
	float sample_count;
	float max_velocity_uv;
	float object_velocity_scale;
	float has_velocity;        // 1.0: velocity_tex geçerli, 0.0: yok say
	float debug_show_velocity; // 1.0: hız görselleştirme modu
	float _pad0;
	float _pad1;
} params;

// Bir noktanın bu karedeki derinliğinden, kamera hareketi kaynaklı
// UV kaymasını (bu kare UV'si - önceki kare UV'si) hesaplar.
vec2 camera_velocity(vec2 uv, float depth) {
	vec4 ndc_current = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 clip_prev = params.reprojection_matrix * ndc_current;
	if (abs(clip_prev.w) < 1e-6) {
		return vec2(0.0);
	}
	vec2 uv_prev = (clip_prev.xy / clip_prev.w) * 0.5 + 0.5;
	return uv - uv_prev;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_output);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float depth = texture(depth_tex, uv).r;

	vec2 cam_vel = camera_velocity(uv, depth);

	vec2 obj_vel = vec2(0.0);
	bool used_object_velocity = false;
	if (params.has_velocity > 0.5) {
		// Godot'un motion-vector formatı resmi olarak belgelenmemiştir; en
		// yaygın kabul gören yorum, RG kanallarının doğrudan UV-uzayında
		// "bu piksel önceki karede nerdeydi" farkını (current_uv - prev_uv)
		// vermesidir. object_velocity_scale ile kalibre edin.
		vec2 raw = texture(velocity_tex, uv).rg;
		obj_vel = raw * params.object_velocity_scale;
		// Anlamlı bir hareket varsa (gürültü tabanından büyükse) bu pikselin
		// gerçek (kamera+obje) hareketi olarak kabul edip kamera-only tahmini
		// yerine bunu kullanıyoruz.
		if (length(raw) > 0.0005) {
			used_object_velocity = true;
		}
	}

	vec2 velocity = (used_object_velocity ? obj_vel : cam_vel) * params.strength;

	if (params.debug_show_velocity > 0.5) {
		vec3 dbg = used_object_velocity
			? vec3(0.0, clamp(length(obj_vel) * 20.0, 0.0, 1.0), 0.0)
			: vec3(clamp(length(cam_vel) * 20.0, 0.0, 1.0), 0.0, 0.0);
		imageStore(color_output, pixel, vec4(dbg, 1.0));
		return;
	}

	float vel_len = length(velocity);
	if (vel_len > params.max_velocity_uv && vel_len > 0.0) {
		velocity *= params.max_velocity_uv / vel_len;
	}

	int samples = max(1, int(params.sample_count));
	vec3 color;

	if (samples <= 1 || vel_len < 1e-6) {
		color = texture(color_input, uv).rgb;
	} else {
		vec3 accum = vec3(0.0);
		for (int i = 0; i < samples; i++) {
			// -0.5 .. +0.5 arasında, mevcut pikselin ETRAFINDA simetrik örnekleme
			float t = (float(i) / float(samples - 1)) - 0.5;
			vec2 sample_uv = clamp(uv - velocity * t, vec2(0.0), vec2(1.0));
			accum += texture(color_input, sample_uv).rgb;
		}
		color = accum / float(samples);
	}

	imageStore(color_output, pixel, vec4(color, 1.0));
}
