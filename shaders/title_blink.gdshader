shader_type canvas_item;

uniform float blink : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D cover_texture : source_color, filter_linear_mipmap;
uniform vec4 left_eye = vec4(0.670, 0.238, 0.048, 0.066);
uniform vec4 right_eye = vec4(0.718, 0.218, 0.048, 0.066);

float eye_mask(vec2 uv, vec4 eye) {
	vec2 local = (uv - eye.xy) / eye.zw;
	vec2 centred = (local - vec2(0.5)) / vec2(0.55, 0.48);
	return 1.0 - smoothstep(0.88, 1.0, dot(centred, centred));
}

vec4 close_eye(vec2 uv, vec4 eye, float amount) {
	vec2 local = (uv - eye.xy) / eye.zw;
	// Pull matching cheek colour from immediately below each eye, then draw a
	// small curved lash. This avoids the vertical colour bars produced by
	// stretching the open iris and never samples the surrounding hair.
	vec2 skin_uv = vec2(uv.x, eye.y + eye.w * 1.15);
	vec4 skin = texture(cover_texture, skin_uv);
	float arch = 0.50 + 0.075 * (1.0 - pow((local.x - 0.5) * 2.0, 2.0));
	float lash = 1.0 - smoothstep(0.022, 0.055, abs(local.y - arch));
	vec4 ink = vec4(0.12, 0.025, 0.035, skin.a);
	return mix(skin, ink, lash);
}

void fragment() {
	vec4 base = texture(cover_texture, UV);
	float left = eye_mask(UV, left_eye);
	float right = eye_mask(UV, right_eye);
	float mask = max(left, right) * blink;
	vec4 shut = left >= right
		? close_eye(UV, left_eye, blink)
		: close_eye(UV, right_eye, blink);
	COLOR = mix(base, shut, mask);
}
