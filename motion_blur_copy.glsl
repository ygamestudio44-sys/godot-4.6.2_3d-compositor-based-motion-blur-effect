#[compute]
#version 450

// Ana renk tamponunu bir "scratch" (yedek) tampona kopyalar. texture_copy()
// yerine bunu kullanıyoruz çünkü Godot'un dahili renk tamponu
// TEXTURE_USAGE_CAN_COPY_FROM_BIT ile işaretli değil; ama storage-image
// (imageLoad/imageStore) erişimini zaten destekliyor.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src_color;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst_color;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(src_color);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	imageStore(dst_color, pixel, imageLoad(src_color, pixel));
}
