#version 440
// wb.frag - viewer colour pipeline on a tile:
//   lin = in ^ gammaIn                      tiles are gamma-encoded 8-bit (2.2),
//                                           old proxies linear (gammaIn = 1)
//   lin = toe(lin)                          black point with a soft toe (below)
//   lin = cm * lin                          white balance + 3x3 + exposure,
//                                           folded into cm (profile or grey-world)
//   out = srgb(lin)          if gammaOn     the profile view, sRGB for the screen
//   out = lin ^ (1/gammaIn)  otherwise      back to the tile's own encoding
// Nothing in the proxies or the TIFF is touched.
//
// Black point. The hard form is max(lin - pedestal, 0): the chart's black
// patch (3.1% reflectance, sRGB 50) lands on 0 and every shadow below it is
// cut off. With knee > 0 (linear, fraction of full scale) the cut becomes a
// toe: above t = pedestal + knee the output is lin - pedestal as before; below
// it, knee * (lin / t) ^ (t / knee), a power curve that is 0 at 0, meets the
// line at t with the same slope, and keeps every gradation in between in
// order. The deepest shadows read as black, nothing is clipped, nothing is
// lifted. knee = 0 is the hard clip.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    mat4 cm;
    vec4 pedestal;
    float gammaOn;
    float gammaIn;
    float knee;
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
    vec3 lin = c - pedestal.rgb;
    if (knee > 0.0) {
        vec3 t = pedestal.rgb + vec3(knee);
        vec3 toe = knee * pow(max(c, vec3(0.0)) / t, t / vec3(knee));
        c = mix(lin, toe, step(c, t));          // c <= t: the toe, else the line
    } else {
        c = max(lin, vec3(0.0));
    }
    c = clamp((cm * vec4(c, 1.0)).rgb, vec3(0.0), vec3(1.0));
    c = (gammaOn > 0.5) ? srgb(c) : pow(c, vec3(1.0 / gammaIn));
    fragColor = vec4(c, 1.0) * qt_Opacity;
}
