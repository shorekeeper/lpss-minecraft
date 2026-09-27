#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

// Depth- and normal-aware 4x4 box over the AO term. The gradient noise is
// structured, so a small box over it reads as smooth. Reads colortex3,
// writes colortex3: the loader flips the buffer, so the read sees the
// previous pass.

uniform sampler2D colortex1;
uniform sampler2D colortex3;
uniform sampler2D depthtex0;
uniform float near;
uniform float far;

in vec2 texcoord;

float linearDepth(float d) {
    return 2.0 * near * far / (far + near - (d * 2.0 - 1.0) * (far - near));
}

/* DRAWBUFFERS:3 */
void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);
    float dc = texelFetch(depthtex0, px, 0).r;
    if (dc >= 1.0) {
        gl_FragData[0] = vec4(1.0);
        return;
    }
    float zc = linearDepth(dc);
    vec3 nc = texelFetch(colortex1, px, 0).rgb * 2.0 - 1.0;

    float sum = 0.0;
    float wsum = 0.0;
    for (int y = -1; y <= 2; y++) {
        for (int x = -1; x <= 2; x++) {
            ivec2 p = px + ivec2(x, y);
            float d = texelFetch(depthtex0, p, 0).r;
            if (d >= 1.0) continue;
            float z = linearDepth(d);
            vec3 n = texelFetch(colortex1, p, 0).rgb * 2.0 - 1.0;
            float w = 1.0 / (1.0 + 60.0 * abs(z - zc) / zc);
            w *= pow(max(dot(n, nc), 0.0), 8.0);
            sum += texelFetch(colortex3, p, 0).r * w;
            wsum += w;
        }
    }
    gl_FragData[0] = vec4(sum / max(wsum, 1e-4), 0.0, 0.0, 1.0);
}