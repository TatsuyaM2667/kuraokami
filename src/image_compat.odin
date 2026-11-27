package kuraokami

import "base:intrinsics"
import "core:bytes"
import "core:image"

// image.Image の画素を []u8 で返す。Odin dev-2026-11 から pixels が bytes.Buffer ではなく [dynamic]u8 になった
// (LLVM 23 で動く Odin は dev-2026-11 以降)。when の選ばれなかった側は型検査されないので、どちらの Odin でもビルドできる
image_bytes :: proc(img: ^image.Image) -> []u8 {
	when intrinsics.type_is_dynamic_array(type_of(img.pixels)) {
		return img.pixels[:]
	} else {
		return bytes.buffer_to_bytes(&img.pixels)
	}
}
