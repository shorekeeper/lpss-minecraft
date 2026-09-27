#ifndef GUIDE_GLSL
#define GUIDE_GLSL
#include "/lib/settings.glsl"
#include "/lib/voxel.glsl"

// Path guiding of the first leg of the bounce rays. Every lamp owns a
// quadtree over the unit square, onto which the sphere of directions is
// unfolded by the equal-area octahedral map (Clarberg 2008): equal areas
// in the square are equal solid angles, so a uniform point in the square
// is a uniform direction. Each node holds the share of the lamp's
// deposited flux that came back through its directions.
//
// Sampling warps a stratified point through the tree: at every node the
// point picks a quadrant by the children's weights and is rescaled into
// it. The weights are a mixture of flux and area, (1 - a) flux + a area
// with a = GUIDE_UNIFORM, so every ray samples the mixture exactly and no
// direction ever drops below a of the uniform chance. The pdf of a leaf
// is (1 - a) flux / area + a, and the ray's flux is divided by it.
//
// Learning: a ray adds the luminance it deposited, weight included, to the
// leaf of its direction. Since the weight already divides by the pdf, the
// sum over a leaf estimates the integral of the contribution over its
// solid angle whatever the sampling density was, and the tree cannot lock
// onto itself. The next frame folds the normalised deposits into the
// leaves by GUIDE_LEARN, sums the tree up and rebuilds it: a leaf above
// GUIDE_SPLIT of the total splits, a node below GUIDE_MERGE collapses.
//
// Trees are keyed by the lamp's world position in a hash table, since the
// light list is reordered every frame, and survive GUIDE_FORGET frames
// without their lamp. Two node arrays per slot alternate by frame parity:
// the rebuild reads the frame's old tree and writes the new one; the
// deposits of a frame index the leaves of the tree sampled that frame.
// The buffer starts as whatever memory held; a slot is only trusted while
// its frame stamp lies in the forget window.
//
// GUIDE_MODEL 1 keeps the slots and the table and replaces the tree by six
// von Mises-Fisher lobes, one per cube face. A ray adds its deposited
// luminance and that luminance times its direction to the sector of the
// direction; the rebuild normalises the sums, folds them in by GUIDE_LEARN
// and fits each lobe in closed form: the mean direction is the summed
// vector, the concentration follows from its length R as
// R (3 - R^2) / (1 - R^2), the mixture weight is the sector's share. No
// iteration, one atomic per ray, and a sector holding two windows fits
// one lobe between them, which the uniform share covers.

const int GUIDE_SLOTS = 1024;
const int GUIDE_NODES = 256;
const int GUIDE_HEADER = 8;         // world x y z, frame stamp, node count
const uint GUIDE_NONE = 0xFFFFFFFFu;
const float GUIDE_FIXED = 1048576.0;

layout(std430, binding = 6) buffer GuideTrees {
    uint header[GUIDE_SLOTS * GUIDE_HEADER];
    uint child[GUIDE_SLOTS * 2 * GUIDE_NODES];    // first of four children, 0 = leaf
    float weight[GUIDE_SLOTS * 2 * GUIDE_NODES];  // flux share, summed over children
    uint acc[GUIDE_SLOTS * GUIDE_NODES];          // this frame's deposits per leaf
} guide;

int guideTreeSet(int frame) { return frame & 1; }
int guideBase(int slot, int set) { return (slot * 2 + set) * GUIDE_NODES; }
int guideAccBase(int slot) { return slot * GUIDE_NODES; }

float csign(float x) { return x < 0.0 ? -1.0 : 1.0; }

// Equal-area octahedral map, square [0,1]^2 to the unit sphere
vec3 guideSquareToSphere(vec2 p) {
    vec2 q = p * 2.0 - 1.0;
    vec2 a = abs(q);
    float sd = 1.0 - (a.x + a.y);
    float r = 1.0 - abs(sd);
    float phi = (r == 0.0 ? 1.0 : (a.y - a.x) / r + 1.0) * 0.78539816339;
    float z = (1.0 - r * r) * csign(sd);
    float s = r * sqrt(max(2.0 - r * r, 0.0));
    return vec3(s * cos(phi) * csign(q.x), s * sin(phi) * csign(q.y), z);
}

vec2 guideSphereToSquare(vec3 d) {
    vec3 a = abs(d);
    float r = sqrt(max(1.0 - a.z, 0.0));
    float hi = max(a.x, a.y);
    float lo = min(a.x, a.y);
    float b = hi == 0.0 ? 0.0 : lo / hi;
    float phi = atan(b) * 0.63661977236;
    if (a.x < a.y) phi = 1.0 - phi;
    float v = phi * r;
    float u = r - v;
    if (d.z < 0.0) { float t = u; u = 1.0 - v; v = 1.0 - t; }
    u *= csign(d.x);
    v *= csign(d.y);
    return clamp(vec2(u, v) * 0.5 + 0.5, 0.0, 0.99999);
}

uint guideHash(ivec3 p) {
    return voxelHash(uint(p.x) * 73856093u ^ uint(p.y) * 19349663u ^ uint(p.z) * 83492791u);
}

bool guideSlotLive(uint last, uint frame) {
    return last <= frame && frame - last <= uint(GUIDE_FORGET);
}

// Leaf holding the point uv, and its depth
int guideLeaf(int nb, vec2 uv, out int depth) {
    int node = 0;
    vec2 o = vec2(0.0);
    float s = 1.0;
    depth = 0;
    for (int d = 0; d < 8; d++) {
        uint c = guide.child[nb + node];
        if (c == 0u) break;
        s *= 0.5;
        int col = uv.x >= o.x + s ? 1 : 0;
        int row = uv.y >= o.y + s ? 1 : 0;
        o += vec2(col, row) * s;
        node = int(c) + row * 2 + col;
        depth++;
    }
    return node;
}

// Mixture density at uv relative to uniform
float guidePdf(int slot, int set, vec2 uv) {
    int nb = guideBase(slot, set);
    int depth;
    int leaf = guideLeaf(nb, uv, depth);
    float area = exp2(-2.0 * float(depth));
    float total = max(guide.weight[nb], 1e-6);
    return (1.0 - GUIDE_UNIFORM) * guide.weight[nb + leaf] / total / area + GUIDE_UNIFORM;
}

// Warps a uniform point of the square through the tree; pdf is the
// mixture density at the result relative to uniform
vec2 guideWarp(int slot, int set, vec2 uv, out float pdf) {
    int nb = guideBase(slot, set);
    float total = max(guide.weight[nb], 1e-6);
    float a = GUIDE_UNIFORM;
    uv = clamp(uv, 0.0, 0.99999);
    vec2 o = vec2(0.0);
    float s = 1.0;
    float area = 1.0;
    int node = 0;
    for (int d = 0; d < 8; d++) {
        uint c = guide.child[nb + node];
        if (c == 0u) break;
        int cb = nb + int(c);
        float ca = area * 0.25;
        float w0 = max((1.0 - a) * guide.weight[cb] / total + a * ca, 1e-9);
        float w1 = max((1.0 - a) * guide.weight[cb + 1] / total + a * ca, 1e-9);
        float w2 = max((1.0 - a) * guide.weight[cb + 2] / total + a * ca, 1e-9);
        float w3 = max((1.0 - a) * guide.weight[cb + 3] / total + a * ca, 1e-9);
        float pl = (w0 + w2) / (w0 + w1 + w2 + w3);
        int col;
        if (uv.x < pl) { uv.x /= pl; col = 0; } else { uv.x = (uv.x - pl) / (1.0 - pl); col = 1; }
        float wb = col == 0 ? w0 : w1;
        float wt = col == 0 ? w2 : w3;
        float pb = wb / (wb + wt);
        int row;
        if (uv.y < pb) { uv.y /= pb; row = 0; } else { uv.y = (uv.y - pb) / (1.0 - pb); row = 1; }
        s *= 0.5;
        o += vec2(col, row) * s;
        node = int(c) + row * 2 + col;
        area = ca;
    }
    pdf = (1.0 - a) * guide.weight[nb + node] / total / area + a;
    return o + clamp(uv, 0.0, 0.99999) * s;
}

void guideLearn(int slot, int set, vec2 uv, float value) {
    uint q = uint(min(value * GUIDE_FIXED, 4.0e9));
    if (q == 0u) return;
    int depth;
    int leaf = guideLeaf(guideBase(slot, set), uv, depth);
    atomicAdd(guide.acc[guideAccBase(slot) + leaf], q);
}

// Sector vMF model. A slot's weight array holds the raw EMA state at
// VMF_RAW, four floats per sector (summed vector, summed weight), and the
// fitted lobes at VMF_LOBE, eight per sector (mean direction, kappa,
// mixture weight, cumulative weight). The acc array holds four signed
// fixed-point sums per sector.
const int VMF_SECTORS = 6;
const int VMF_RAW = 0;
const int VMF_LOBE = 32;
const int VMF_STRIDE = 8;
const vec3 VMF_FACE[6] = vec3[6](
    vec3( 1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0),
    vec3( 0.0, 1.0, 0.0), vec3( 0.0,-1.0, 0.0),
    vec3( 0.0, 0.0, 1.0), vec3( 0.0, 0.0,-1.0));

int vmfSector(vec3 d) {
    vec3 a = abs(d);
    if (a.x >= a.y && a.x >= a.z) return d.x >= 0.0 ? 0 : 1;
    if (a.y >= a.z) return d.y >= 0.0 ? 2 : 3;
    return d.z >= 0.0 ? 4 : 5;
}

// Density of vMF(mu, kappa) at d relative to the uniform sphere
float vmfRel(vec3 mu, float kappa, vec3 d) {
    if (kappa < 1e-3) return 1.0;
    return 2.0 * kappa / (1.0 - exp(-2.0 * kappa)) * exp(kappa * (dot(mu, d) - 1.0));
}

vec3 vmfMu(int lb) { return vec3(guide.weight[lb], guide.weight[lb + 1], guide.weight[lb + 2]); }

float guidePdfVmf(int nb, vec3 d) {
    float s = 0.0;
    for (int k = 0; k < VMF_SECTORS; k++) {
        int lb = nb + VMF_LOBE + k * VMF_STRIDE;
        s += guide.weight[lb + 4] * vmfRel(vmfMu(lb), guide.weight[lb + 3], d);
    }
    return GUIDE_UNIFORM + (1.0 - GUIDE_UNIFORM) * s;
}

// Draws a direction from the mixture: a GUIDE_UNIFORM share of the points
// goes to the uniform sphere through the equal-area map, the rest picks a
// sector by its cumulative weight and a direction from its lobe. The
// density is that of the whole mixture whichever branch was taken.
vec3 guideSampleVmf(int nb, vec2 uv, out float pdf) {
    float a = GUIDE_UNIFORM;
    vec3 d;
    if (uv.x < a) {
        d = guideSquareToSphere(vec2(uv.x / a, uv.y));
    } else {
        float x = (uv.x - a) / max(1.0 - a, 1e-6);
        int k = 0;
        float lo = 0.0;
        for (; k < VMF_SECTORS - 1; k++) {
            float c = guide.weight[nb + VMF_LOBE + k * VMF_STRIDE + 5];
            if (x < c) break;
            lo = c;
        }
        int lb = nb + VMF_LOBE + k * VMF_STRIDE;
        float w = max(guide.weight[lb + 4], 1e-6);
        float u = clamp((x - lo) / w, 0.0, 0.99999);
        vec3 mu = vmfMu(lb);
        float kappa = guide.weight[lb + 3];
        float W = kappa < 1e-3 ? 1.0 - 2.0 * u : 1.0 + log(u + (1.0 - u) * exp(-2.0 * kappa)) / kappa;
        W = clamp(W, -1.0, 1.0);
        float r = sqrt(max(1.0 - W * W, 0.0));
        float ph = 6.28318530718 * uv.y;
        vec3 t1 = normalize(cross(mu, abs(mu.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
        vec3 t2 = cross(mu, t1);
        d = t1 * (r * cos(ph)) + t2 * (r * sin(ph)) + mu * W;
    }
    pdf = guidePdfVmf(nb, d);
    return d;
}

// Signed sums through unsigned atomics: the wrap is the two's complement
void guideLearnVmf(int slot, vec3 d, float value) {
    float w = min(value * GUIDE_FIXED, 1.0e8);
    if (w < 0.5) return;
    vec3 v = clamp(d * w, -1.0e8, 1.0e8);
    int ab = guideAccBase(slot) + vmfSector(d) * 4;
    atomicAdd(guide.acc[ab], uint(int(v.x)));
    atomicAdd(guide.acc[ab + 1], uint(int(v.y)));
    atomicAdd(guide.acc[ab + 2], uint(int(v.z)));
    atomicAdd(guide.acc[ab + 3], uint(int(w)));
}

// Entry points shared by both models. uv is the stratified point in the
// square; the tree model replaces it by the warped point, which its
// learning indexes by.
vec3 guideSample(int slot, int set, inout vec2 uv, out float pdf) {
#if GUIDE_MODEL == 1
    return guideSampleVmf(guideBase(slot, set), uv, pdf);
#else
    uv = guideWarp(slot, set, uv, pdf);
    return guideSquareToSphere(uv);
#endif
}

float guidePdfDir(int slot, int set, vec3 d) {
#if GUIDE_MODEL == 1
    return guidePdfVmf(guideBase(slot, set), d);
#else
    return guidePdf(slot, set, guideSphereToSquare(d));
#endif
}

void guideDeposit(int slot, int set, vec2 uv, vec3 d, float value) {
#if GUIDE_MODEL == 1
    guideLearnVmf(slot, d, value);
#else
    guideLearn(slot, set, uv, value);
#endif
}

#ifdef GUIDE_WRITE
// Slot of the lamp at world position wp, claimed if it has none; -1 when
// the table is full around its hash. fresh is set when the slot was just
// claimed and holds no tree yet.
int guideSlotClaim(ivec3 wp, uint frame, out bool fresh) {
    fresh = false;
    uint h = guideHash(wp);
    for (int probe = 0; probe < 16; probe++) {
        int s = int((h + uint(probe)) & uint(GUIDE_SLOTS - 1));
        int hb = s * GUIDE_HEADER;
        uint last = guide.header[hb + 3];
        if (guideSlotLive(last, frame)) {
            ivec3 sp = ivec3(int(guide.header[hb]), int(guide.header[hb + 1]), int(guide.header[hb + 2]));
            if (all(equal(sp, wp))) return s;
            continue;
        }
        if (atomicCompSwap(guide.header[hb + 3], last, frame) == last) {
            guide.header[hb] = uint(wp.x);
            guide.header[hb + 1] = uint(wp.y);
            guide.header[hb + 2] = uint(wp.z);
            guide.header[hb + 4] = 0u;
            fresh = true;
            return s;
        }
    }
    return -1;
}

// Folds the sector sums into the slot's raw state and fits the six lobes
// for this frame. Everything is read into registers before anything is
// written, so the two sets may coincide.
void guideRebuildVmf(int slot, uint frame, bool fresh) {
    int hb = slot * GUIDE_HEADER;
    int set = guideTreeSet(int(frame));
    int nb = guideBase(slot, set);
    int ab = guideAccBase(slot);
    int ob = guideBase(slot, int(guide.header[hb + 3]) & 1);

    vec3 S[VMF_SECTORS];
    float Wt[VMF_SECTORS];
    float accTotal = 0.0;
    for (int k = 0; k < VMF_SECTORS; k++) accTotal += float(int(guide.acc[ab + k * 4 + 3]));
    for (int k = 0; k < VMF_SECTORS; k++) {
        if (fresh) {
            S[k] = vec3(0.0);
            Wt[k] = 1.0 / float(VMF_SECTORS);
        } else {
            int rb = ob + VMF_RAW + k * 4;
            S[k] = vec3(guide.weight[rb], guide.weight[rb + 1], guide.weight[rb + 2]);
            Wt[k] = guide.weight[rb + 3];
            if (any(isnan(S[k])) || any(isinf(S[k]))) S[k] = vec3(0.0);
            if (!(Wt[k] >= 0.0 && Wt[k] <= 1.0)) Wt[k] = 1.0 / float(VMF_SECTORS);
            if (accTotal > 0.0) {
                vec3 as = vec3(float(int(guide.acc[ab + k * 4])), float(int(guide.acc[ab + k * 4 + 1])), float(int(guide.acc[ab + k * 4 + 2]))) / accTotal;
                float aw = float(int(guide.acc[ab + k * 4 + 3])) / accTotal;
                S[k] = mix(S[k], as, GUIDE_LEARN);
                Wt[k] = mix(Wt[k], aw, GUIDE_LEARN);
            }
        }
        for (int j = 0; j < 4; j++) guide.acc[ab + k * 4 + j] = 0u;
    }

    float wsum = 0.0;
    for (int k = 0; k < VMF_SECTORS; k++) wsum += Wt[k];
    float cdf = 0.0;
    for (int k = 0; k < VMF_SECTORS; k++) {
        int rb = nb + VMF_RAW + k * 4;
        guide.weight[rb] = S[k].x;
        guide.weight[rb + 1] = S[k].y;
        guide.weight[rb + 2] = S[k].z;
        guide.weight[rb + 3] = Wt[k];

        float w = wsum > 1e-9 ? Wt[k] / wsum : 1.0 / float(VMF_SECTORS);
        float len = length(S[k]);
        float R = clamp(len / max(Wt[k], 1e-6), 0.0, 0.9999);
        float kappa = min(R * (3.0 - R * R) / (1.0 - R * R), GUIDE_VMF_KAPPA_MAX);
        vec3 mu = len > 1e-6 ? S[k] / len : VMF_FACE[k];
        cdf += w;
        int lb = nb + VMF_LOBE + k * VMF_STRIDE;
        guide.weight[lb] = mu.x;
        guide.weight[lb + 1] = mu.y;
        guide.weight[lb + 2] = mu.z;
        guide.weight[lb + 3] = kappa;
        guide.weight[lb + 4] = w;
        guide.weight[lb + 5] = k == VMF_SECTORS - 1 ? 1.0 : cdf;
    }
    guide.header[hb + 4] = uint(VMF_SECTORS);
    guide.header[hb + 3] = frame;
}

// Folds the deposits into the slot's tree and rebuilds it for this frame.
// Children are always allocated after their parent, so a descending pass
// sums the tree up.
void guideRebuild(int slot, uint frame, bool fresh) {
#if GUIDE_MODEL == 1
    guideRebuildVmf(slot, frame, fresh);
    return;
#endif
    int hb = slot * GUIDE_HEADER;
    int set = guideTreeSet(int(frame));
    int nb = guideBase(slot, set);
    int ab = guideAccBase(slot);
    if (fresh) {
        guide.child[nb] = 0u;
        guide.weight[nb] = 1.0;
        for (int i = 0; i < GUIDE_NODES; i++) guide.acc[ab + i] = 0u;
        guide.header[hb + 4] = 1u;
        return;
    }
    uint last = guide.header[hb + 3];
    int ob = guideBase(slot, int(last) & 1);
    int count = int(clamp(guide.header[hb + 4], 1u, uint(GUIDE_NODES)));
    if (ob == nb) {
        // The newest tree sits in this frame's set; rebuilding in place
        // would read what it writes, so it is moved over first
        int tb = guideBase(slot, 1 - set);
        for (int i = 0; i < count; i++) {
            guide.child[tb + i] = guide.child[ob + i];
            guide.weight[tb + i] = guide.weight[ob + i];
        }
        ob = tb;
    }

    float accTotal = 0.0;
    for (int i = 0; i < count; i++) {
        if (guide.child[ob + i] == 0u) accTotal += float(guide.acc[ab + i]);
    }
    for (int i = 0; i < GUIDE_NODES; i++) {
        if (i < count && guide.child[ob + i] == 0u && accTotal > 0.0) {
            float w = guide.weight[ob + i];
            if (!(w >= 0.0)) w = 0.0;
            guide.weight[ob + i] = mix(w, float(guide.acc[ab + i]) / accTotal, GUIDE_LEARN);
        }
        guide.acc[ab + i] = 0u;
    }
    for (int i = count - 1; i >= 0; i--) {
        uint c = guide.child[ob + i];
        if (c == 0u) continue;
        int cb = ob + int(c);
        guide.weight[ob + i] = guide.weight[cb] + guide.weight[cb + 1] + guide.weight[cb + 2] + guide.weight[cb + 3];
    }
    float total = max(guide.weight[ob], 1e-6);

    // Depth-first copy with splits and collapses; an entry packs the old
    // node, the new node and the depth
    uint stack[32];
    int sp = 0;
    stack[sp++] = 0u;
    int newCount = 1;
    while (sp > 0) {
        uint e = stack[--sp];
        int o = int(e & 0xFFu);
        int n = int((e >> 8) & 0xFFu);
        int d = int(e >> 16);
        float f = guide.weight[ob + o];
        uint oc = guide.child[ob + o];
        float share = f / total;
        bool split = d < GUIDE_MAX_DEPTH && newCount + 4 <= GUIDE_NODES
                  && (oc != 0u ? share > GUIDE_MERGE : share > GUIDE_SPLIT);
        if (!split) {
            guide.child[nb + n] = 0u;
            guide.weight[nb + n] = f;
            continue;
        }
        int base = newCount;
        newCount += 4;
        guide.child[nb + n] = uint(base);
        for (int k = 0; k < 4; k++) {
            if (oc != 0u && sp < 32) {
                stack[sp++] = (oc + uint(k)) | (uint(base + k) << 8) | (uint(d + 1) << 16);
            } else {
                guide.child[nb + base + k] = 0u;
                guide.weight[nb + base + k] = oc != 0u ? guide.weight[ob + int(oc) + k] : f * 0.25;
            }
        }
    }
    for (int i = newCount - 1; i >= 0; i--) {
        uint c = guide.child[nb + i];
        if (c == 0u) continue;
        int cb = nb + int(c);
        guide.weight[nb + i] = guide.weight[cb] + guide.weight[cb + 1] + guide.weight[cb + 2] + guide.weight[cb + 3];
    }
    guide.header[hb + 4] = uint(newCount);
    guide.header[hb + 3] = frame;
}
#endif

#endif
