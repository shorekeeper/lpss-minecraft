#ifndef LAMP_GLSL
#define LAMP_GLSL
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"

// What a lamp emits, shared by the traced direct term, the bounce, the fog
// and the lightmap calibration. No buffers are declared here, so forward
// shaded programs may include it.

// Smooth fade to zero at LPV_RANGE (Karis 2013), so the reach of a lamp has
// no edge. d2 is the squared distance travelled from the lamp.
float lampWindow(float d2) {
    float x = d2 / (LPV_RANGE * LPV_RANGE);
    float f = clamp(1.0 - x * x, 0.0, 1.0);
    return f * f;
}

// A lamp may stand for a cluster of emitters, see LAMP_CLUSTER: bit 28
// marks one, bits 29-31 hold the member count less one, and the span bits
// hold the mean position of the members instead, in sixteenths of the
// cluster cell per axis, four bits each, rounded; with a cell two blocks
// wide a block centre lands on a sixteenth exactly
const uint LAMP_CLUSTER_BIT = 1u << 28;
bool lampClustered(uint v) { return (v & LAMP_CLUSTER_BIT) != 0u; }
float lampCount(uint v) { return float(((v >> 29) & 7u) + 1u); }

uint lampClusterPack(vec3 p) {
    uvec3 q = uvec3(clamp(round(p / float(LAMP_CLUSTER) * 16.0), 0.0, 15.0));
    return (q.x | (q.y << 4) | (q.z << 8)) << uint(VOXEL_SPAN_SHIFT);
}

vec3 lampClusterOffset(uint v) {
    uint s = v >> uint(VOXEL_SPAN_SHIFT);
    uvec3 q = uvec3(s, s >> 4, s >> 8) & 15u;
    return vec3(q) / 16.0 * float(LAMP_CLUSTER);
}

// Radiant strength by lamp class, times the members of a cluster. Class 0
// only arises from the floodlight id: on this fork no block reports an
// emission of its own.
float lampStrength(uint v) {
    int c = voxelColorClass(v);
    float s = FLOOD_STRENGTH;
    if (c == 1) s = 1.0;
    else if (c == 2) s = 1.2;
    else if (c == 3) s = 0.15;
    return s * lampCount(v);
}

vec3 lampIntensity(uint v) { return emissionColor(voxelColorClass(v)) * lampStrength(v); }

// Unshadowed irradiance of a lamp at squared distance d2 arriving with
// cosine ndl, before LPV_EMISSION. DIRECT_SOFTNESS is the squared radius
// of the emitting body, which caps the value next to the lamp.
float lampFalloff(float d2, float ndl) {
    return ndl / (d2 + DIRECT_SOFTNESS) * lampWindow(d2);
}

#endif

