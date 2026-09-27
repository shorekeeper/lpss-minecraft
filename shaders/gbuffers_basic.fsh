#version 330 compatibility
#include "/lib/settings.glsl"

// Untextured geometry: selection box, lines, leash. Written into the G-buffer
// with a neutral normal and full sky light so deferred does not shade it with
// whatever was left in colortex1/2 underneath.

in vec4 vcolor;

/* DRAWBUFFERS:012 */
void main() {
    if (vcolor.a < 0.1) discard;
    gl_FragData[0] = vec4(vcolor.rgb, 1.0);
    gl_FragData[1] = vec4(0.5, 1.0, 0.5, 1.0);
    gl_FragData[2] = vec4(0.0, 1.0, 0.0, 1.0);
}

