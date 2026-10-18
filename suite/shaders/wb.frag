#version 440
// wb.frag — viewer colour pipeline on a tile, linear in, display out:
//   c = cm * max(c - pedestal, 0)        white balance + 3x3 matrix + exposure,
//                                        all folded into cm (profile or grey-world)
//   c = srgb(c) when gammaOn             the sRGB transfer, so a linear 16-bit scan
//                                        is seen the way a display expects it
// Tiles are linear 8-bit (ingest shifts 16-bit down, no gamma), so the profile
// fitted on the linear TIFF applies here unchanged. Nothing in the proxies or
// the TIFF is touched.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    mat4 cm;
    vec4 pedestal;
    float gammaOn;
};
layout(binding = 1) uniform sampler2D source;
vec3 srgb(vec3 l) {
    vec3 lo = l * 12.92;
    vec3 hi = 1.055 * pow(l, vec3(1.0 / 2.4)) - 0.055;
    return mix(lo, hi, step(vec3(0.0031308), l));
}
void main()
{
    vec3 c = texture(source, qt_TexCoord0).rgb;
    c = max(c - pedestal.rgb, vec3(0.0));
    c = clamp((cm * vec4(c, 1.0)).rgb, vec3(0.0), vec3(1.0));
    if (gammaOn > 0.5) c = srgb(c);
    fragColor = vec4(c, 1.0) * qt_Opacity;
}
