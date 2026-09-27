#ifndef ATMOSPHERE_GLSL
#define ATMOSPHERE_GLSL
#include "/lib/settings.glsl"

// Declared here rather than per program so that every user of ambientScale
// sees the same value without redeclaring it.
uniform float rainStrength;
uniform float temperature;
uniform int biome_precipitation;

#ifndef PPT_SNOW
#define PPT_SNOW 2
#endif

// Whether precipitation here falls as snow: the biome says so, or it is
// cold enough for the game to lay snow
bool snowing() { return biome_precipitation == PPT_SNOW || temperature < 0.15; }

float ambientScale(float day) {
    float weather = 1.0 - 0.25 * rainStrength;
    return mix(NIGHT_FLOOR, 1.0, day) * SKY_BRIGHTNESS * weather;
}

// Flat overcast dome: no sun disc, horizon slightly brighter than the zenith,
// below the horizon it fades into the fog colour so haze and ground read as
// one mass.
vec3 overcastSky(vec3 dir, float day) {
    float h = clamp(dir.y, -1.0, 1.0);
    float horizonW = pow(1.0 - max(h, 0.0), 3.0);
    vec3 sky = mix(SKY_ZENITH, SKY_HORIZON, horizonW);
    sky = mix(sky, FOG_COLOR, smoothstep(0.0, -0.12, h));
    return sky * ambientScale(day);
}

// Analytic integral of density d0 * exp(-k * (y - base)) along a ray segment.
// Returns optical depth, not transmittance.
float heightFogDepth(vec3 ro, vec3 rd, float dist) {
    float k  = FOG_FALLOFF;
    float d0 = 0.005 * FOG_DENSITY;
    float dStart = d0 * exp(-k * (ro.y - FOG_HEIGHT));
    float ty = rd.y;
    if (abs(ty) < 1e-4) return dStart * dist;
    return dStart * (1.0 - exp(-k * ty * dist)) / (k * ty);
}

// Uniform mist that scales with render distance so the far plane never shows.
float distanceFogDepth(float dist, float farPlane) {
    float x = dist / (farPlane * FOG_DISTANCE);
    return x * x * 1.2;
}

// The same two media as local densities, for the volumetric march
float heightFogDensity(float y) {
    return 0.005 * FOG_DENSITY * exp(-FOG_FALLOFF * (y - FOG_HEIGHT));
}

float distanceFogDensity(float dist, float farPlane) {
    float s = farPlane * FOG_DISTANCE;
    return 2.4 * dist / (s * s);
}

vec3 fogColor(vec3 rd, float day) {
    // Slightly brighter towards the horizon, matching the dome
    float horizonW = pow(1.0 - abs(rd.y), 2.0);
    return mix(FOG_COLOR, SKY_HORIZON, horizonW * 0.35) * ambientScale(day);
}

#endif

