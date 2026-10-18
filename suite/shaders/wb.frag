#version 440
// wb.frag — viewer colour pipeline on a tile:
//   lin = in ^ gammaIn                      tiles are gamma-encoded 8-bit (2.2),
//                                           old proxies linear (gammaIn = 1)
//   lin = cm * max(lin - pedestal, 0)       white balance + 3x3 + exposure,
//                                           folded into cm (profile or grey-world)
//   out = srgb(lin)          if gammaOn     the profile view, sRGB for the screen
//   out = lin ^ (1/gammaIn)  otherwise      back to the tile's own encoding
// Nothing in the proxies or the TIFF is touched.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    mat4 cm;
    vec4 pedestal;
    float gammaOn;
    float gammaIn;
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
    c = pow(max(c, vec3(0.0)), vec3(gammaIn));
    c = max(c - pedestal.rgb, vec3(0.0));
    c = clamp((cm * vec4(c, 1.0)).rgb, vec3(0.0), vec3(1.0));
    c = (gammaOn > 0.5) ? srgb(c) : pow(c, vec3(1.0 / gammaIn));
    fragColor = vec4(c, 1.0) * qt_Opacity;
}
