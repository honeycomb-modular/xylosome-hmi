#version 440
// wb.frag — per-channel gain on a tile (white balance in the viewer).
// Tiles are linear 8-bit (ingest shifts 16-bit down, no gamma), so a plain
// multiply is the physically right correction; clamp so lifted channels clip
// white instead of wrapping.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 gain;
};
layout(binding = 1) uniform sampler2D source;
void main()
{
    vec4 c = texture(source, qt_TexCoord0);
    fragColor = vec4(min(c.rgb * gain.rgb, vec3(1.0)), 1.0) * qt_Opacity;
}
