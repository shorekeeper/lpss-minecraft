#ifndef MATERIAL_GLSL
#define MATERIAL_GLSL
#include "/lib/settings.glsl"

// Material ids from block.properties, arriving as (mc_Entity.x - 10000):
//   0 unmapped   1 emissive   2 water   3 concrete/asphalt   4 soil/vegetation   5 metal
struct Material {
    float roughness;
    float f0;        // reflectance at normal incidence
    float porosity;  // how much water soaks in: darkens instead of sheening
};

Material materialFromId(float id) {
    Material m;
    // Unmapped: rough and porous, so unknown mod blocks never turn into mirrors
    m.roughness = 0.85; m.f0 = 0.04; m.porosity = 0.70;
    int i = int(id + 0.5);
    if (i == 1 || i == 11) { m.roughness = 0.90; m.f0 = 0.00; m.porosity = 0.00; }
    else if (i == 3) { m.roughness = 0.60; m.f0 = 0.04; m.porosity = 0.30; }
    else if (i == 4 || i == 10) { m.roughness = 0.95; m.f0 = 0.03; m.porosity = 0.95; }
    else if (i == 5) { m.roughness = 0.35; m.f0 = 0.50; m.porosity = 0.00; }
    else if (i == 8) { m.roughness = 0.15; m.f0 = 0.04; m.porosity = 0.00; }
    return m;
}

// Uniform wetness, no pattern. Soaked matter darkens; only sealed matter
// turns glossy.
void applyWetness(inout Material m, inout vec3 albedo, float wet) {
    albedo *= 1.0 - 0.40 * wet * m.porosity;
    m.roughness *= 1.0 - 0.45 * wet * (1.0 - m.porosity);
}

#endif

