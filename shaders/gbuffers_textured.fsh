#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"

// Root of the fallback chain: terrain, entities, hand, particles, block
// entities all land here unless given their own program. Writes the G-buffer;
// shading happens in deferred.fsh.

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vcolor;
in vec3 wnormal;
in float matId;
flat in float terrain;
flat in vec3 blockCell;

/* DRAWBUFFERS:0126 */
void main() {
    vec4 albedo = texture(gtexture, texcoord) * vcolor;
    if (albedo.a < alphaTestRef) discard;

    // Alpha is forced to 1.0: the fork injects its own alpha-test emulation on
    // iris_FragData0.a and would otherwise discard translucent-looking texels.
    gl_FragData[0] = vec4(albedo.rgb, 1.0);                       // sRGB albedo
    gl_FragData[1] = vec4(normalize(wnormal) * 0.5 + 0.5, 1.0);  // world normal
    gl_FragData[2] = vec4(normalizeLightmap(lmcoord), matId / 255.0, terrain);
    gl_FragData[3] = vec4(blockCell, terrain);                    // grid cell of the block
}
