#ifndef SNOW_GLSL
#define SNOW_GLSL
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/volume.glsl"

// Falling snow, in two parts. Near the camera the flakes are marched
// along the view ray: the air is divided into two grids of growing cell
// size covering two bands of distance, every cell holds up to
// SNOW_DENSITY flakes at hashed positions, the field of a grid falls and
// drifts as a whole and each flake sways about its place; the far grid
// falls slower than the near one, so the two fields move apart. A flake
// is a disc, or a segment of the distance it travels in SNOW_STREAK
// seconds. One smaller than a pixel is tested against a pixel-sized disc
// and weighed by the area it covers, with a floor of SNOW_GRAIN: by the
// area alone a flake of a few millimetres is gone at three blocks, while
// the eye sees a snowfall as a grain of dots to the veil. A share
// SNOW_LARGE of the flakes are drawn four times the size in the plane of
// the screen, turning slowly, once they are wide enough for their shape
// to show: six-armed stars, and among them by SNOW_BREAK stars that have
// lost arms and clumps of a few flakes stuck together. The bands overlap
// a little and the flakes fade across the overlap; the first block in
// front of the camera is faded as well, since a flake there covers a
// great many pixels.
//
// Past SNOW_RANGE the flakes are too many and too small to draw one by
// one and read as fog; the veil is that fog, an extinction per block with
// the same swell as the wind, laid over the scene and the sky and over
// the marched flakes by their distance.
//
// Flakes are lit like the surfaces: the sky term through the sky grid's
// share at their cell, which also thins them out under a roof or a crown,
// and the block light of the air from the fog volume, so they glow beside
// a lamp. The light is read once per cell on its first hit, so the loads
// do not grow with the density. No textures are read.

uniform float frameTimeCounter;
uniform mat4 gbufferProjection;
uniform float viewHeight;

// Defined by the including program: block light irradiance of the air
vec3 fogIrradiance(vec3 p);

const int SNOW_LEVELS = 2;
const float SNOW_CELL[2] = float[2](0.5, 1.0);
const float SNOW_BAND[2] = float[2](0.34, 1.0);        // far end of each band as a share of the range
const float SNOW_LEVEL_FALL[2] = float[2](1.0, 0.75);  // fall speed of each field
const int SNOW_PER_CELL_MAX = 4;
const float SNOW_LARGE_SCALE = 4.0;
const float SNOW_NEAR = 0.4;
const float SNOW_NEAR_FADE = 1.2;
const float SNOW_ALBEDO = 0.85;
const float SNOW_GUST_RATE = 0.37;
const float SNOW_VEIL_RANGE = 256.0;

float snowStrength() { return snowing() ? rainStrength : 0.0; }

// The wind and the veil swell and ease in one slow cycle
float snowGust(float time) { return 1.0 + SNOW_GUST * sin(SNOW_GUST_RATE * time); }

vec3 snowWindDir() {
    float a = radians(SNOW_WIND_ANGLE);
    return vec3(cos(a), 0.0, sin(a));
}

// Displacement of a field since time zero
vec3 snowDrift(float time, float fall) {
    float run = SNOW_WIND * (time - SNOW_GUST * cos(SNOW_GUST_RATE * time) / SNOW_GUST_RATE);
    return snowWindDir() * run + vec3(0.0, -SNOW_FALL * fall * time, 0.0);
}

vec3 snowVelocity(float time, float fall) {
    return snowWindDir() * (SNOW_WIND * snowGust(time)) + vec3(0.0, -SNOW_FALL * fall, 0.0);
}

float snowVeilDepth(float dist, float time) {
    return SNOW_VEIL * snowStrength() * snowGust(time) * min(dist, SNOW_VEIL_RANGE);
}

// Snow in the air scatters the whole sky; the veil is lighter than the
// fog and the horizon
vec3 snowVeilColor(vec3 rd, float day) {
    return mix(fogColor(rd, day), vec3(0.42, 0.45, 0.50) * ambientScale(day), 0.6);
}

vec3 snowVeil(vec3 color, vec3 rd, float dist, float day) {
    float od = snowVeilDepth(dist, frameTimeCounter);
    if (od <= 0.0) return color;
    return mix(color, snowVeilColor(rd, day), 1.0 - exp(-od));
}

vec4 snowHash(ivec3 c, int salt) {
    uint h0 = voxelHash(uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(c.z) * 83492791u ^ uint(salt) * 2654435761u);
    uint h1 = voxelHash(h0 ^ 0x9E3779B9u);
    return vec4(h0 & 0xFFFFu, h0 >> 16, h1 & 0xFFFFu, h1 >> 16) / 65536.0;
}

// Distance from the ray to the segment a .. b, and the ray parameter of
// the point nearest to it
float raySegmentDistance(vec3 ro, vec3 rd, vec3 a, vec3 b, out float tc) {
    vec3 u = b - a;
    vec3 w = a - ro;
    float bb = dot(rd, u);
    float c = dot(u, u);
    float d = dot(rd, w);
    float e = dot(u, w);
    float den = c - bb * bb;
    float s = den > 1e-8 ? clamp((bb * d - e) / den, 0.0, 1.0) : 0.0;
    tc = d + bb * s;
    return length(ro + rd * tc - (a + u * s));
}

// Coverage of a six-armed star of radius R at offset q in the plane of
// the screen, turned by rot; aa is half a pixel at the flake's distance.
// The arm the point falls in is found, the plane folded onto it, and a
// hub, the arm and a pair of branches are drawn. Each arm draws its own
// length from seed: a share broken of them is snapped short and loses
// its branches.
float snowStar(vec2 q, float R, float rot, float aa, float seed, float broken) {
    float r = length(q);
    float ang = mod(atan(q.y, q.x) + rot, 6.28318530718);
    int arm = int(ang * 0.95492965855);
    float a6 = abs(ang - (float(arm) + 0.5) * 1.0471975512);
    float ah = fract(seed * 7.13 + float(arm) * 0.6180339887);
    float len = ah < broken ? 0.3 + 0.4 * fract(ah * 91.0) : 1.0;
    vec2 p = vec2(r * cos(a6), r * sin(a6));
    float w = 0.09 * R;
    float d = max(p.y - w, p.x - len * R);
    d = min(d, r - 0.28 * R);
    if (len > 0.99) {
        vec2 b = p - vec2(0.52 * R, 0.0);
        float along = dot(b, vec2(0.5, 0.8660254));
        float across = abs(dot(b, vec2(-0.8660254, 0.5))) - 0.8 * w;
        if (along > 0.0 && along < 0.38 * R) d = min(d, across);
    }
    return 1.0 - smoothstep(-aa, aa, d);
}

// Coverage of a clump: three discs stuck together inside radius R
float snowClump(vec2 q, float R, float aa, float seed) {
    float d = 1e3;
    for (int i = 0; i < 3; i++) {
        float t = fract(seed * 13.7 + float(i) * 0.33) * 6.28318530718;
        vec2 c = vec2(cos(t), sin(t)) * 0.35 * R;
        float rr = R * (0.4 + 0.25 * fract(seed * 41.0 + float(i) * 0.71));
        d = min(d, length(q - c) - rr);
    }
    return 1.0 - smoothstep(-aa, aa, d);
}

// The scene colour with the flakes between the camera and dist laid over
// it. ro is the camera, rd the view direction, camRight and camUp the
// screen axes, all in world space.
vec3 snowfall(vec3 color, vec3 ro, vec3 rd, vec3 camRight, vec3 camUp, float dist, float day, float farPlane, int frame) {
    float density = SNOW_DENSITY * snowStrength();
    if (density <= 0.02) return color;
    float tEnd = min(dist, SNOW_RANGE);
    if (tEnd <= SNOW_NEAR) return color;
    int perCell = int(ceil(min(density, float(SNOW_PER_CELL_MAX))));

    float time = frameTimeCounter;
    // World size of a pixel at unit distance
    float pxScale = 2.0 / (gbufferProjection[1][1] * viewHeight);
    int set = skySet(frame);
    vec3 hemi = mix(GROUND_BOUNCE, SKY_ZENITH, 0.75) * ambientScale(day);
    vec3 fogc = fogColor(rd, day);
    vec3 veilc = snowVeilColor(rd, day);
    float largeR = SNOW_SIZE * SNOW_LARGE_SCALE;

    vec3 acc = vec3(0.0);
    float T = 1.0;
    for (int k = 0; k < SNOW_LEVELS && T > 0.02; k++) {
        float cellSize = SNOW_CELL[k];
        float tB = SNOW_RANGE * SNOW_BAND[k];
        float tA = k == 0 ? SNOW_NEAR : SNOW_RANGE * SNOW_BAND[k - 1] * 0.8;
        if (tA >= tEnd) break;
        float tStop = min(tB, tEnd);
        vec3 drift = snowDrift(time, SNOW_LEVEL_FALL[k]);
        vec3 streak = snowVelocity(time, SNOW_LEVEL_FALL[k]) * (0.5 * SNOW_STREAK);
        // A flake's sway stays inside its cell, so the ray of a neighbouring
        // cell does not clip it; a streak may reach over, which is invisible
        float margin = min((largeR + SNOW_SWAY) / cellSize, 0.3);

        vec3 q0 = (ro + rd * tA - drift) / cellSize;
        ivec3 cell = ivec3(floor(q0));
        ivec3 stp = ivec3(sign(rd));
        vec3 inv = cellSize / max(abs(rd), vec3(1e-5));
        vec3 tMax = tA + abs(vec3(cell) + max(vec3(stp), vec3(0.0)) - q0) * inv;
        for (int i = 0; i < 48; i++) {
            bool litKnown = false;
            float sky = 1.0;
            vec3 light = vec3(0.0);
            for (int j = 0; j < perCell; j++) {
                vec4 h = snowHash(cell, k * 8 + j);
                if (float(j) + h.w >= density) continue;
                float u = fract(h.w * 37.0);
                bool large = u < SNOW_LARGE;
                float R = large ? largeR * (0.7 + 0.6 * fract(u * 53.0)) : SNOW_SIZE * (0.5 + 1.0 * u * u);
                vec3 off = margin + (1.0 - 2.0 * margin) * h.xyz;
                vec3 P = (vec3(cell) + off) * cellSize + drift;
                float ph = h.x * 6.28318530718;
                P.xz += SNOW_SWAY * vec2(sin(time * 1.7 + ph), cos(time * 1.3 + ph * 0.7));
                float tc;
                float d = raySegmentDistance(ro, rd, P - streak, P + streak, tc);
                if (tc <= tA || tc >= tStop) continue;
                float px = pxScale * tc;
                float Rt = max(R, 0.5 * px);
                if (d >= Rt) continue;

                if (!litKnown) {
                    litKnown = true;
                    vec3 Pc = (vec3(cell) + 0.5) * cellSize + drift;
#if SKY_GRID_ENABLED
                    ivec3 gc = ivec3(floor(Pc)) - voxelOrigin(cameraPosition);
                    if (voxelInside(gc)) sky = skyMoments(set, gc).a;
#endif
                    light = SNOW_ALBEDO * (hemi * sky + fogIrradiance(Pc) * gridCoverage(Pc) * BLOCKLIGHT_STRENGTH);
                }

                float a;
                if (large && R > 3.0 * px) {
                    vec3 perp = (P - ro) - rd * tc;
                    vec2 q = vec2(dot(perp, camRight), dot(perp, camUp));
                    float kind = fract(u * 29.0);
                    if (kind < SNOW_BREAK * 0.4) {
                        a = snowClump(q, R, 0.5 * px, h.y);
                    } else {
                        float rot = ph + time * 0.5 * (h.y - 0.5);
                        a = snowStar(q, R, rot, 0.5 * px, h.z, kind < SNOW_BREAK ? 0.6 : 0.0);
                    }
                } else {
                    float cover = (R * R) / (Rt * Rt);
                    a = max(cover, SNOW_GRAIN) * (1.0 - smoothstep(0.4 * Rt, Rt, d));
                }
                a *= smoothstep(tB, tB * 0.8, tc);
                a *= k == 0 ? smoothstep(SNOW_NEAR, SNOW_NEAR_FADE, tc) : smoothstep(tA, tA * 1.25, tc);
                a *= smoothstep(0.02, 0.25, sky);
                if (a <= 0.001) continue;

                vec3 lit = light;
                float od = heightFogDepth(ro, rd, tc) + distanceFogDepth(tc, farPlane);
                lit = mix(lit, fogc, 1.0 - exp(-od));
                lit = mix(lit, veilc, 1.0 - exp(-snowVeilDepth(tc, time)));
                acc += T * a * lit;
                T *= 1.0 - a;
            }
            int ax = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
            if (tMax[ax] > tStop) break;
            cell[ax] += stp[ax];
            tMax[ax] += inv[ax];
        }
    }
    return color * T + acc;
}

#endif