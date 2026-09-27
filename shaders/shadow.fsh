#version 330 compatibility

// Nothing is ever read back from the shadow map. The pass exists so that
// shadow.vsh runs over all terrain around the player. These constants are
// plain GLSL, so they need no comment wrapper.
const int   shadowMapResolution = 256;
const float shadowDistance = 64.0;
const float shadowDistanceRenderMul = 1.0;
const float voxelDistance = 64.0;

void main() { discard; }

