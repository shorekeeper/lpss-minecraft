#ifndef NEAR_GLSL
#define NEAR_GLSL
#include "/lib/voxel.glsl"

// Per-voxel occluder neighbourhood, written by the second grid step once the
// voxels are final and read by the cone trace. Each cell holds two words:
// the mask and a copy of the voxel, so a trace reads one cell with one
// load. Mask bits 0-5 say which face neighbour is a cube, full terrain or
// entity box, in +X -X +Y -Y +Z -Z order, bits 8-13 which is a partial
// block, bits 16-21 which is leaves; bit 7 says the voxel itself is a
// cube, bit 6 that it is partial. Bit 23 says an edge or corner neighbour
// is a cube other than leaves; it stays clear for a cube itself, which no
// trace crosses. Bit 22 says one of the 26 neighbours holds rectangle
// leaders, see lib/mesh_rect.glsl; shadowcomp_c sets it from the cell
// that holds them once the lists are compacted. Every cell is rewritten
// each frame, so the buffer needs no clearing.

layout(std430, binding = 2) buffer VoxelNear {
    uvec2 cell[];   // x: mask, y: voxel
} voxelNear;

const uint NEAR_RECT_AROUND = 1u << 22;

int nearIndex(ivec3 c) { return (c.z * VOXEL_SIZE + c.y) * VOXEL_SIZE + c.x; }

uvec2 nearCell(ivec3 c) { return voxelInside(c) ? voxelNear.cell[nearIndex(c)] : uvec2(0u); }
uint nearMask(ivec3 c) { return nearCell(c).x; }
bool nearFull(uint m, int face) { return ((m >> uint(face)) & 1u) != 0u; }
bool nearPartial(uint m, int face) { return ((m >> uint(8 + face)) & 1u) != 0u; }
bool nearLeaves(uint m, int face) { return ((m >> uint(16 + face)) & 1u) != 0u; }
bool nearSelfFull(uint m) { return (m & 0x80u) != 0u; }
bool nearSelfPartial(uint m) { return (m & 0x40u) != 0u; }
bool nearSelfOccluder(uint m) { return (m & 0xC0u) != 0u; }
// Any face neighbour that stops a trace: cube, partial block or leaves
bool nearAnyOccluder(uint m) { return (m & 0x3F3F3Fu) != 0u; }
bool nearRectAround(uint m) { return (m & NEAR_RECT_AROUND) != 0u; }
bool nearDiagonalCube(uint m) { return (m & (1u << 23)) != 0u; }

#endif