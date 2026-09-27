#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"

uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

in vec4 mc_Entity;
in vec4 at_midBlock;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 vcolor;
out vec3 wnormal;
out float matId;
flat out float terrain;
flat out vec3 blockCell;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vcolor   = gl_Color;
    wnormal  = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    // Unmapped blocks read as -1 on this fork, unbound attributes as 0
    matId = clamp(mc_Entity.x - 10000.0, 0.0, 255.0);
    // at_midBlock is only ever bound for terrain; entities, hand and
    // particles read it as zero
    terrain = dot(at_midBlock.xyz, at_midBlock.xyz) > 0.5 ? 1.0 : 0.0;
    // Grid index of the block the vertex belongs to, which for a thin block
    // is not the cell behind its surface
    vec3 world = (gbufferModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz + cameraPosition;
    blockCell = vec3(ivec3(floor(world + at_midBlock.xyz / 64.0)) - voxelOrigin(cameraPosition)) / 255.0;
}
