#version 430 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/voxel.glsl"

// Terrain voxelization, first half. Every terrain vertex within
// voxelDistance passes through here regardless of what the shadow camera
// sees. The vertex resolves its block's cell and classification and hands
// them, with its position inside the block and on its sprite, to
// shadow.gsh, which sees the whole triangle. at_midBlock points from the
// vertex to the block centre in 1/64 block units and is the only reliable
// mark of terrain: mc_Entity reads -1 for entities as well as for unmapped
// blocks.

uniform mat4 shadowModelViewInverse;
uniform vec3 cameraPosition;
uniform sampler2D gtexture;

in vec4 mc_Entity;
in vec4 at_midBlock;
in vec2 mc_midTexCoord;

out vec3 gWorld;
out vec3 gMid;
out vec2 gUV;
out vec3 gAlbedo;
flat out vec2 gMidUV;
flat out int gTerrain;
flat out uint gVoxel;
flat out ivec3 gIdx;
#if DEBUG_VIEW == 24
flat out vec3 gNormal;
#endif

void main() {
    gl_Position = ftransform();
#if DEBUG_VIEW == 24
    gNormal = mat3(shadowModelViewInverse) * (gl_NormalMatrix * gl_Normal);
#endif

    vec3 camRel = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;
    bool hasMid = dot(at_midBlock.xyz, at_midBlock.xyz) > 0.5;
    gWorld = camRel;
    gMid = at_midBlock.xyz;
    gUV = gl_MultiTexCoord0.xy;
    gMidUV = mc_midTexCoord;
    gAlbedo = vec3(0.0);
    gTerrain = hasMid ? 1 : 0;
    gVoxel = 0u;
    gIdx = ivec3(-1);
    if (!hasMid) return;

    gIdx = ivec3(floor(camRel + cameraPosition + at_midBlock.xyz / 64.0)) - voxelOrigin(cameraPosition);

    // Unmapped blocks arrive as -1; anything below the 10000 base is "unknown"
    int id = mc_Entity.x > 9999.5 ? int(mc_Entity.x + 0.5) - 10000 : 0;

    bool solid; int emission; int colorClass; bool leaves;
    classifyVoxel(id, solid, emission, colorClass, leaves);
#if DEBUG_VIEW == 16
    // The id as read, and whether the attribute was below the base
    gAlbedo = vec3(float(id) / 255.0, mc_Entity.x < 9999.5 ? 1.0 : 0.0, 0.0);
    gVoxel = 1u;
    return;
#endif
    if (!solid && emission == 0) return; // air-like: leave the cleared zero

    gVoxel = packVoxel(solid, emission, colorClass) | (leaves ? VOXEL_LEAVES : 0u);
    // Mean albedo of the block's texture, tinted
    if (solid) gAlbedo = srgbToLinear(textureLod(gtexture, mc_midTexCoord, 2.0).rgb) * gl_Color.rgb;
}
