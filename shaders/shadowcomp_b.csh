#version 430
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"
#include "/lib/lights.glsl"
#include "/lib/fogvol.glsl"
#include "/lib/guide.glsl"

// Bounce and fog deposit, see lib/bounce.glsl and lib/fogvol.glsl. Runs
// after the grid steps: step 1 has folded last frame's bounce deposits into
// the volume and step 2 has zeroed the counters, split the ray budget
// between the lamps and rebuilt their guiding trees, so the bounce written
// here is read next frame; the fog deposits are folded by shadowcomp_c in
// this frame. The first leg of a ray is drawn from the lamp's tree and its
// flux divided by the density, and what the ray deposits is fed back into
// the tree, see lib/guide.glsl.
//
// Every bounce leg passes through adjoint-driven Russian roulette and
// splitting (Vorba and Krivanek 2016): the luminance the ray carries,
// relative to a fresh ray of its lamp, times the worth of its position to
// the viewer, is the expected contribution q. Below one the leg survives
// with chance q and its flux is divided by it; above one it splits into
// floor(q) copies sharing the flux. The estimate stays unbiased either way.
// A ray whose density was low carries more than average and is the one
// that splits, so the weights of guided sampling are evened out. The worth
// of a position falls with the distance to the camera and behind it, never
// to zero, since the volume is temporal and a turn must not open a hole.
//
// The dispatch covers the largest ray budget; threads past BOUNCE_RAYS
// find no lamp and exit. The loader reads the work group count from the
// text, so it has to stay a literal.
layout(local_size_x = 64) in;
const ivec3 workGroups = ivec3(4096, 1, 1);

layout(r32ui) uniform readonly uimage3D voxelImg;
layout(rgba8) uniform readonly image3D voxelColorImg;
layout(r32ui) uniform uimage3D bounceAccR;
layout(r32ui) uniform uimage3D bounceAccG;
layout(r32ui) uniform uimage3D bounceAccB;

uniform int frameCounter;
uniform vec3 cameraPosition;
uniform mat4 gbufferModelViewInverse;

#define BOUNCE_MARCH
#include "/lib/bounce.glsl"

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const float BOUNCE_REF_ALBEDO = 0.4;   // albedo a fresh ray is expected to pick up
const int LEG_STACK = 16;

// Flux and direction of the fog ray being traced
vec3 fogFlux;
vec3 fogDir;
// Luminance the ray has deposited, for its lamp's tree
float guideValue = 0.0;
// Random stream of the thread
uint rngSeed;
uint rngCount = 0u;
float rnd() { return bounceRand(rngSeed + rngCount++); }

void fogDeposit(ivec3 c, float len, float t) {
    vec3 e = fogFlux * len * lampWindow(t * t);
    uvec3 q = uvec3(e * BOUNCE_FIXED + 0.5);
    int b = fogIndex(c);
    if (q.r > 0u) atomicAdd(fogAcc.v[b], q.r);
    if (q.g > 0u) atomicAdd(fogAcc.v[b + 1], q.g);
    if (q.b > 0u) atomicAdd(fogAcc.v[b + 2], q.b);
    // Signed sums through unsigned atomics: the wrap is the two's complement
    ivec3 f = ivec3(fogDir * (dot(e, LUMA) * BOUNCE_FIXED));
    if (f.x != 0) atomicAdd(fogAcc.v[b + 3], uint(f.x));
    if (f.y != 0) atomicAdd(fogAcc.v[b + 4], uint(f.y));
    if (f.z != 0) atomicAdd(fogAcc.v[b + 5], uint(f.z));
}

// How much a deposit in cell c teaches the tree: all of it, or less the
// further the cell is from the camera
float guideFocus(ivec3 c) {
    if (GUIDE_FOCUS <= 0.0) return 1.0;
    vec3 d = vec3(c) + 0.5 - (cameraPosition - vec3(voxelOrigin(cameraPosition)));
    return 1.0 / (1.0 + dot(d, d) / (GUIDE_FOCUS * GUIDE_FOCUS));
}

// Worth of a deposit at grid point p to the viewer
float adjoint(vec3 p) {
    vec3 cam = cameraPosition - vec3(voxelOrigin(cameraPosition));
    vec3 d = p - cam;
    float d2 = dot(d, d);
    float near = 1.0 / (1.0 + d2 / (ADRRS_FOCUS * ADRRS_FOCUS));
    vec3 fwd = mat3(gbufferModelViewInverse) * vec3(0.0, 0.0, -1.0);
    float facing = d2 > 1.0 ? dot(d, fwd) * inversesqrt(d2) : 1.0;
    return near * mix(ADRRS_BEHIND, 1.0, smoothstep(-0.5, 0.5, facing));
}

void depositCell(ivec3 c, vec3 e) {
    guideValue += dot(e, LUMA) * guideFocus(c);
    uvec3 q = uvec3(e * BOUNCE_FIXED + 0.5);
    if (q.r > 0u) imageAtomicAdd(bounceAccR, c, q.r);
    if (q.g > 0u) imageAtomicAdd(bounceAccG, c, q.g);
    if (q.b > 0u) imageAtomicAdd(bounceAccB, c, q.b);
}

int dominantAxis(vec3 n) {
    vec3 an = abs(n);
    return (an.x >= an.y && an.x >= an.z) ? 0 : (an.y >= an.z ? 1 : 2);
}

// A cell takes a share of a deposit if the volumes read it as air and
// there is solid matter in it or behind it across the face
bool receives(ivec3 c, ivec3 toWall) {
    if (!voxelInside(c) || !voxelInside(c + toWall)) return false;
    uint v = imageLoad(voxelImg, c).r;
    if (voxelFillsCentre(v)) return false;
    return voxelOccluder(v) || voxelOccluder(imageLoad(voxelImg, c + toWall).r);
}

// Splats e over the cells in front of the surface hit at q with normal
// nrm, bilinearly by q. The centre cell is the one half a block off the
// surface, where the volumes are sampled, or the cell the ray came from
// when that one is filled by a block. Shares of cells that do not receive
// go to those that do; the centre cell always does.
void deposit(ivec3 before, vec3 q, vec3 nrm, vec3 e) {
    int ax = dominantAxis(nrm);
    ivec3 toWall = ivec3(0);
    toWall[ax] = nrm[ax] > 0.0 ? -1 : 1;
    ivec3 c0 = ivec3(floor(q + nrm * 0.5));
    if (!voxelInside(c0) || voxelFillsCentre(imageLoad(voxelImg, c0).r)) c0 = before;
    int u = ax == 0 ? 1 : 0;
    int v = ax == 2 ? 1 : 2;
    float fu = clamp(q[u] - (float(c0[u]) + 0.5), -0.5, 0.5);
    float fv = clamp(q[v] - (float(c0[v]) + 0.5), -0.5, 0.5);
    ivec3 du = ivec3(0); du[u] = fu < 0.0 ? -1 : 1;
    ivec3 dv = ivec3(0); dv[v] = fv < 0.0 ? -1 : 1;
    fu = abs(fu);
    fv = abs(fv);

    ivec3 cells[4] = ivec3[4](c0, c0 + du, c0 + dv, c0 + du + dv);
    float w[4] = float[4]((1.0 - fu) * (1.0 - fv), fu * (1.0 - fv), (1.0 - fu) * fv, fu * fv);
    float wsum = 0.0;
    for (int k = 0; k < 4; k++) {
        if (k > 0 && !receives(cells[k], toWall)) w[k] = 0.0;
        wsum += w[k];
    }
    for (int k = 0; k < 4; k++) {
        if (w[k] > 0.0) depositCell(cells[k], e * (w[k] / wsum));
    }
}

// A bounce leg waiting to be traced: start, surface normal, flux carried,
// distance travelled and the number of deposits made before it
struct Leg { vec3 p; vec3 n; vec3 flux; float travelled; int depth; };

// Traces the legs of a ray from its first hit. Each leg leaves the surface
// by a cosine-weighted direction and deposits at the next; ref is the
// luminance a fresh ray of the lamp carries. Legs are kept on a small
// stack so a split leg can queue its copies; a leg the stack cannot hold
// is dropped.
void bounce(vec3 p0, vec3 n0, vec3 flux0, float travelled0, float ref) {
    Leg stack[LEG_STACK];
    int sp = 0;
    stack[sp++] = Leg(p0, n0, flux0, travelled0, 0);
    for (int guard = 0; guard < 64 && sp > 0; guard++) {
        Leg leg = stack[--sp];
        if (max(leg.flux.r, max(leg.flux.g, leg.flux.b)) < 1e-5) continue;
        float remain = LPV_RANGE - leg.travelled;
        if (remain <= 0.5) continue;

        int copies = 1;
#if ADRRS_ENABLED
        float q = dot(leg.flux, LUMA) / ref * adjoint(leg.p) * ADRRS_GAIN;
        if (q < 1.0) {
            float s = max(q, ADRRS_MIN_SURVIVE);
            if (rnd() >= s) continue;
            leg.flux /= s;
        } else {
            copies = min(int(q), ADRRS_MAX_SPLIT);
            leg.flux /= float(copies);
        }
#endif
        for (int c = 0; c < copies; c++) {
            vec3 rd = cosineDir(leg.n, rnd(), rnd());
            ivec3 hit, before; vec3 nrm; float th;
            if (!marchVoxels(leg.p, rd, remain, false, hit, before, nrm, th)) continue;
            float travelled = leg.travelled + th;
            vec3 qp = leg.p + rd * th;
            deposit(before, qp, nrm, leg.flux * lampWindow(travelled * travelled) * abs(dot(rd, nrm)));
            if (leg.depth + 1 >= BOUNCE_DEPTH) continue;

            vec3 albedo = imageLoad(voxelColorImg, hit).rgb;
            vec3 next = leg.flux * albedo;
#if !ADRRS_ENABLED
            // Roulette on the albedo landed on: a dark surface ends most
            // paths and a bright one passes the full flux
            float pc = min(max(albedo.r, max(albedo.g, albedo.b)), 0.9);
            if (rnd() >= pc) continue;
            next = leg.flux * albedo / pc;
#endif
            if (sp < LEG_STACK) stack[sp++] = Leg(qp + nrm * 0.01, nrm, next, travelled, leg.depth + 1);
        }
    }
}

void main() {
#if SKIP_COMPUTE || SKIP_BOUNCE
    return;
#endif
    int set = lightSet(frameCounter);
    uint t = gl_GlobalInvocationID.x;
    int li = lightOfRay(set, t);
    if (li < 0) return;
    uint first = lightList.rayStart[li];
    uint rays = lightList.rayStart[li + 1] - first;
    uint ri = t - first;

    uvec4 L = lightList.lights[set * LIGHTS_MAX + li];
    uint lampSeed = bounceHash(uint(li) * 2654435761u ^ uint(frameCounter) * 2246822519u);
    rngSeed = (uint(li) * 7919u + ri) * 104729u + uint(frameCounter) * 15485863u;

    // One stratified point of the lamp's set per ray, the set shifted by
    // the lamp seed so every ray of the lamp shares the frame's shift;
    // warped through the lamp's tree when it has one
    vec2 uv = fibonacciSquare(ri, rays, lampSeed);
    float pdf = 1.0;
    uint gslot = GUIDE_NONE;
    int gset = guideTreeSet(frameCounter);
    vec3 rd;
#if GUIDE_ENABLED
    gslot = lightList.guideSlot[set * LIGHTS_MAX + li];
    if (gslot != GUIDE_NONE) rd = guideSample(int(gslot), gset, uv, pdf); else rd = guideSquareToSphere(uv);
#else
    rd = guideSquareToSphere(uv);
#endif
    vec3 p = lampPosition(L);

    // Intensity of an isotropic source matching the direct term, divided by
    // the density the direction was drawn with. Every ray carries its share
    // of the total flux; one ray in VOLUMETRIC_RAYS feeds the fog and
    // carries that many shares of it. Consecutive points of the set lie far
    // apart, so every k-th ray still covers the sphere.
    vec3 intensity = lampIntensity(L.w) / pdf;
    bool fogRay = (ri % uint(VOLUMETRIC_RAYS)) == 0u;
    fogFlux = intensity * (12.5663706144 * float(VOLUMETRIC_RAYS) / float(rays));
    float share = 12.5663706144 / float(rays);
    float ref = dot(lampIntensity(L.w), LUMA) * share * BOUNCE_REF_ALBEDO;

    ivec3 hit, before; vec3 nrm; float th;
    fogDir = rd;
    if (marchVoxels(p, rd, LPV_RANGE, fogRay, hit, before, nrm, th)) {
        // Flux per ray times the albedo of the surface it bounces off
        vec3 flux = intensity * share * imageLoad(voxelColorImg, hit).rgb;
        bounce(p + rd * th + nrm * 0.01, nrm, flux, th, ref);
    }

#if GUIDE_ENABLED
    if (gslot != GUIDE_NONE) guideDeposit(int(gslot), gset, uv, rd, guideValue);
#endif
}
