#version 330 compatibility
#include "/lib/settings.glsl"

uniform mat4 gbufferModelViewInverse;

in vec4 mc_Entity;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vcolor;
out vec3 wnormal;
out float matId;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vcolor   = gl_Color;
    wnormal  = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    // Unmapped blocks read as -1 on this fork, unbound attributes as 0
    matId = clamp(mc_Entity.x - 10000.0, 0.0, 255.0);
}

