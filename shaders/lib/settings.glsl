#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL

// --- Look ---
#define SKY_BRIGHTNESS 1.0      // [0.6 0.7 0.8 0.9 1.0 1.1 1.2 1.3 1.5]
#define BLOCKLIGHT_STRENGTH 1.0 // [0.5 0.75 1.0 1.25 1.5 2.0 3.0]
#define NIGHT_FLOOR 0.03        // [0.0 0.01 0.02 0.03 0.05 0.08 0.12]
#define EMISSION_STRENGTH 1.5   // [0.5 1.0 1.5 2.0 3.0]
#define BASE_WETNESS 0.8        // [0.0 0.2 0.4 0.6 0.8 1.0]
#define ALBEDO_DESAT 0.25       // [0.0 0.1 0.25 0.4 0.6]

// --- Fog ---
#define FOG_DENSITY 1.0         // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0]
#define FOG_HEIGHT 64.0         // [32.0 48.0 56.0 64.0 72.0 80.0 96.0 128.0]
#define FOG_FALLOFF 0.035       // [0.01 0.02 0.035 0.05 0.08 0.12]
#define FOG_DISTANCE 1.0        // [0.4 0.6 0.8 1.0 1.25 1.5 2.0]
#define FOG_COOL 0.0            // [0.0 0.25 0.5 0.75 1.0] how far the fog and the horizon are pulled towards a steel blue; the sky, the haze and the snow veil follow
#define VOLUMETRIC_STRENGTH 4.0 // [0.0 1.0 2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0]
#define VOLUMETRIC_DENSITY 0.0  // [0.0 0.01 0.02 0.04 0.08 0.15 0.3] medium the block light scatters in, per block, on top of the fog; it does not dim the view, so the beams thicken while the distance stays clear
#define VOLUMETRIC_ANISOTROPY 0.65 // [0.0 0.3 0.5 0.65 0.8] forward scattering of the air; higher throws the light towards a viewer facing the lamp and away from one beside it
#define VOLUMETRIC_STEPS 12     // [6 8 12 16 24]
#define VOLUMETRIC_RANGE 48.0   // [24.0 32.0 48.0 64.0]
#define VOLUMETRIC_RAYS 2       // [1 2 4 8]
#define FOG_TEMPORAL 0.15       // [0.05 0.1 0.15 0.3 1.0] floor of the frame weight, see lib/history.glsl

// --- Snow, see lib/snow.glsl ---
#define SNOW_ENABLED 1          // [0 1] falling snow marched through the air of cold biomes; off shows the game's own
#define SNOW_DENSITY 2.0        // [0.25 0.5 1.0 1.5 2.0 3.0 4.0] flakes per cell of the near grid, half a block wide, times the rain strength
#define SNOW_SIZE 0.009         // [0.003 0.004 0.006 0.009 0.012 0.016] radius of a flake in blocks; a real one is two to five millimetres
#define SNOW_GRAIN 0.3          // [0.0 0.15 0.3 0.5 0.7 1.0] opacity floor of a flake smaller than a pixel; by its area alone the far flakes vanish, at 1 every one is a full dot
#define SNOW_LARGE 0.25         // [0.0 0.05 0.1 0.25 0.4] share of the flakes drawn four times the size, as stars or clumps
#define SNOW_BREAK 0.6          // [0.0 0.3 0.6 0.8 1.0] share of the large flakes that are broken: stars with arms lost or clumps of stuck flakes
#define SNOW_FALL 0.9           // [0.4 0.6 0.9 1.2 1.6 2.2 3.0] blocks per second downwards
#define SNOW_WIND 0.2           // [0.0 0.2 0.4 0.8 1.5 3.0 5.0] blocks per second sideways
#define SNOW_WIND_ANGLE 30.0    // [0.0 30.0 60.0 90.0 120.0 150.0 180.0 210.0 240.0 270.0 300.0 330.0] direction of the wind in degrees
#define SNOW_GUST 0.3           // [0.0 0.15 0.3 0.5 0.75 1.0] swell of the wind and the veil about their mean
#define SNOW_SWAY 0.15          // [0.0 0.05 0.1 0.15 0.25] width of a flake's wobble, in blocks
#define SNOW_STREAK 0.0         // [0.0 0.008 0.015 0.03 0.05] seconds of travel a flake is drawn over; a flake falls its own size in a frame, so 0 is snow and anything above is sleet
#define SNOW_RANGE 20.0         // [12.0 16.0 20.0 24.0 32.0] blocks the flakes are marched to; the veil covers the rest
#define SNOW_VEIL 0.01          // [0.0 0.005 0.01 0.015 0.02 0.03 0.05 0.08] extinction of the far snow per block at full strength; 0.03 is a hundred blocks of sight

// --- Grade ---
#define EXPOSURE 0.8            // [0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6]
#define DESATURATION 0.45       // [0.0 0.1 0.2 0.3 0.4 0.45 0.5 0.6 0.7]
#define SHADOW_LIFT 0.2         // [0.0 0.1 0.15 0.2 0.25 0.3 0.4 0.5]
#define GRAIN_AMOUNT 0.03       // [0.0 0.01 0.02 0.03 0.05 0.08]
#define BLOOM_STRENGTH 0.15     // [0.0 0.05 0.1 0.15 0.25 0.4]
#define BLOOM_THRESHOLD 1.0     // [0.5 0.75 1.0 1.5 2.0 3.0]
#define COLD_TINT 0.0           // [0.0 0.1 0.2 0.3 0.4 0.5 0.7 1.0] white balance of the whole image towards blue, brightness kept

// --- Ambient occlusion (GTAO) ---
#define AO_ENABLED 1            // [0 1]
#define AO_RADIUS 0.75          // [0.4 0.5 0.75 1.0 1.5]
#define AO_STRENGTH 1.2         // [0.6 0.8 1.0 1.2 1.5 2.0]
#define AO_SLICES 2             // [1 2 3 4]
#define AO_STEPS 6              // [4 6 8 12]
#define AO_RADIUS_PX 64         // [32 48 64 96 128 160]
#define AO_BLOCKLIGHT 0.5       // [0.0 0.25 0.5 0.75 1.0] share of the occlusion applied to block light; the sky term takes it whole
#define AO_SKY_RELIEF 0.7       // [0.0 0.3 0.5 0.7 1.0] how far the screen-space term relaxes on the sky term where the grid already hides the sky, so a corner is not darkened twice

// --- Block light: reach of a lamp and the global scale of its emission ---
#define LPV_RANGE 15.0          // [8.0 12.0 15.0 20.0 24.0 32.0]
#define LPV_EMISSION 4.0        // [1.0 2.0 3.0 4.0 6.0 8.0 12.0]

// --- Direct block light, traced shadows ---
#define DIRECT_STRENGTH 1.0     // [0.0 0.5 1.0 1.5 2.0 3.0]
#define DIRECT_SOFTNESS 1.0     // [0.25 0.5 1.0 2.0 4.0]
#define DIRECT_LAMPS 4          // [1 2 4 6 8]
#define DIRECT_MINOR 0.08       // [0.0 0.04 0.08 0.15 0.25]
#define LAMP_RADIUS 0.35        // [0.15 0.25 0.35 0.45]
#define LIGHTMAP_MATCH 1.3      // [0.6 0.8 1.0 1.15 1.3 1.5 1.8 2.2]
#define LEAVES_TRANSMIT 0.5     // [0.2 0.35 0.5 0.65 0.8]
#define LAMP_BIN_SLOTS 64       // [32 64 128 256] lamps a 16-block bin keeps, the strongest and nearest first; every pixel walks its bin
#define LAMP_CLUSTER 2          // [1 2] emitters of one colour within a world-aligned cell this wide merge into one lamp of their summed strength
#define FLOOD_STRENGTH 8.0      // [2.0 4.0 8.0 12.0 16.0 24.0] radiant strength of a floodlight, block id 10011, against a torch at 1; its reach is still LPV_RANGE

// --- Bounced block light ---
#define BOUNCE_STRENGTH 1.0     // [0.0 0.5 1.0 1.5 2.0 3.0]
#define BOUNCE_TEMPORAL 0.08    // [0.02 0.04 0.08 0.15 0.3 1.0] floor of the frame weight, see lib/history.glsl
#define BOUNCE_RAYS 131072      // [8192 16384 32768 65536 131072 262144] rays per frame, split between the lamps
#define BOUNCE_MAX_RAYS 32768   // [8192 16384 32768 65536 131072] rays one lamp may take of them; a lone torch given the whole budget spends it on atomics into the same few cells
#define BOUNCE_DEPTH 2          // [1 2 3] surfaces a ray deposits on after the one it first hits

// --- Sky visibility from the grid, see shadowcomp_e.csh ---
#define SKY_GRID_ENABLED 1      // [0 1] off reads the lightmap alone
#define SKY_RAYS 1              // [1 2 4] rays a cell shoots upwards per frame once it holds SKY_SETTLE of them
#define SKY_BURST 64            // [1 4 8 16 32 64 128] rays a cell shoots per frame while it holds fewer than SKY_SETTLE; equal to it, a reset cell settles in one frame
#define SKY_SETTLE 64           // [16 32 64 128] rays a cell holds before it slows to SKY_RAYS; below this a new ray still moves the mean visibly
#define SKY_HISTORY 255         // [32 64 128 255] rays a cell's mean runs over; a new ray weighs at least one over this
#define SKY_GRID_GATE 0.08      // [0.02 0.04 0.08 0.15 0.3] lightmap sky level below which the grid's estimate fades out; a cave below the grid's top would otherwise read as open

// --- Adjoint-driven Russian roulette and splitting of the bounce rays, see shadowcomp_b.csh ---
#define ADRRS_ENABLED 1         // [0 1] off falls back to roulette on the albedo
#define ADRRS_FOCUS 16.0        // [8.0 12.0 16.0 24.0 32.0 48.0] blocks from the camera at which a deposit is worth half
#define ADRRS_BEHIND 0.3        // [0.1 0.2 0.3 0.5 0.7 1.0] worth of a deposit behind the camera, relative to one in front
#define ADRRS_GAIN 0.5          // [0.25 0.5 0.75 1.0 1.5 2.0] scale of the expected contribution; higher splits more and kills less
#define ADRRS_MAX_SPLIT 4       // [2 3 4 6 8] copies a ray may split into
#define ADRRS_MIN_SURVIVE 0.05  // [0.02 0.05 0.1 0.2] floor of the survival chance, which caps the weight of a survivor

// --- Path guiding of the bounce rays, see lib/guide.glsl ---
#define GUIDE_ENABLED 1         // [0 1]
#define GUIDE_MODEL 0           // [0 1] 0 an adaptive quadtree over the sphere, 1 six von Mises-Fisher lobes by cube face, fitted in closed form
#define GUIDE_VMF_KAPPA_MAX 32.0 // [8.0 16.0 32.0 64.0 128.0] sharpest lobe the vMF model may fit
#define GUIDE_UNIFORM 0.4       // [0.2 0.3 0.4 0.5 0.6 0.8 1.0] share of the uniform sphere in the mixture, the floor of any direction's chance; 1.0 is plain stratified
#define GUIDE_LEARN 0.15        // [0.02 0.05 0.1 0.15 0.25 0.5 1.0] weight of a frame's deposits in a lamp's tree
#define GUIDE_MAX_DEPTH 5       // [2 3 4 5 6 7] a leaf at depth d covers 4^-d of the sphere
#define GUIDE_SPLIT 0.02        // [0.005 0.01 0.02 0.04 0.08] a leaf above this share of the lamp's flux splits
#define GUIDE_MERGE 0.005       // [0.001 0.0025 0.005 0.01 0.02] a node below this share collapses; keep it under GUIDE_SPLIT
#define GUIDE_FORGET 120        // [30 60 120 300 1200] frames a lamp's tree survives without its lamp
#define GUIDE_FOCUS 0.0         // [0.0 8.0 16.0 32.0] blocks; a deposit this far from the camera teaches half as much, 0 off

// --- Debug: 0 off, 4 voxel behind the surface, 5 voxel in front of it
// (what the volume taps read), leaves green in both, 6 captured entity
// triangles, 8 bounce only,
// 10 visibility of the strongest lamp: grey is the fraction seen through
// the voxels, blue is blocked by the entity triangles, dark blue is no lamp
// in range, 13 the voxel grid along the view ray and behind the visible
// surface: white full, grey partial, purple entity box known to the near
// mask, red entity box the near mask lacks, coloured emitter, dark blue a
// surface with no voxel behind it, 14 cost of the direct trace per pixel:
// grid cells visited and terrain or entity triangles tested over all
// rays, blue cheap, red dear, white 256 and above, 15 the light list: the
// upper half is a white bar as wide as the list is long, the whole screen
// being 512 lamps, the lower half paints the block behind the surface red
// by its emission level and tints the ground cyan where its lamp bin has
// more lamps in reach than it keeps, 16 the material id the shadow pass read for the
// block behind the surface against the one the G-buffer holds: white
// equal, red the shadow pass sees a lamp, yellow it sees an unmapped
// block, green another mismatch, blue no triangle reached the cell, 17 the
// density with which the strongest lamp of the pixel's bin shoots towards
// the pixel: dark green uniform, red above, blue below, purple no tree,
// 18 the sky visibility the surface is shaded with, as grey, 19 the rays
// the sky cells at the surface have accumulated, white at SKY_HISTORY,
// 20 the sky cell under the heaviest tap: red one sixth per reset it has
// been through, green its accumulated rays, 21 the visibility of the
// strongest lamp by estimator: red the rectangle coverage, green the
// centre ray against unpaired and alpha triangles and full faces, blue
// the cube cone, so a shadow one estimator casts alone shows in the
// complementary colour; on a partial block the kinds of its records
// instead, red rectangle leaders, green unpaired opaque, blue alpha,
// each over 32, 22 the rectangle of the strongest lamp's segment with the
// largest coverage: red a normal along X, green along Y, blue along Z,
// pastel when the rectangle was extended by a join, brightness the
// coverage itself; grey on a partial block, dark where no rectangle
// covers anything, 23 the analytic visibility of the strongest lamp
// against a brute force reference of 32 hard rays over the lamp disc:
// grey the reference itself, red where the analytic estimate is darker
// than it, green where lighter, 24 whether the vertex order of a partial
// block's axis triangles agrees with gl_Normal in the shadow pass: green
// all agree, red all disagree, yellow mixed, blue nothing recorded ---
#define DEBUG_VIEW 0            // [0 4 5 6 8 10 13 14 15 16 17 18 19 20 21 22 23 24]
// --- Profiling: each value skips one stage so its cost shows in the frame
// time. 1 the shadow pass voxelizes nothing, 2 every shadowcomp returns at
// once, 3 the deferred pass takes block light from the lightmap alone,
// 4 no ambient occlusion and no volumetric fog, 5 all of these at once,
// 6 no direct light while the bounce volume is still read, 7 direct light
// with every lamp fully visible: the grid walk is compiled out, the lamp
// loop and the entity test stay, 8 direct light without the entity test,
// 9 as 7 with the grid walk compiled in behind a branch that never runs,
// so its register footprint stays and its loads do not, 10 the bounce and
// fog deposit pass returns at once while the lamp list stays, 11 the sky
// pass returns at once, 12 the walk without the cone against cube
// interiors, 13 without the alpha triangle tests, 14 without the
// rectangle coverage ---
#define PROFILE_SKIP 0          // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14]
#define SKIP_CONE_CUBE (PROFILE_SKIP == 12)
#define SKIP_ALPHA     (PROFILE_SKIP == 13)
#define SKIP_RECT      (PROFILE_SKIP == 14)
#define SKIP_BOUNCE   (PROFILE_SKIP == 10)
#define SKIP_SKY      (PROFILE_SKIP == 11)
#define SKIP_SHADOW   (PROFILE_SKIP == 1 || PROFILE_SKIP == 5)
#define SKIP_COMPUTE  (PROFILE_SKIP == 2 || PROFILE_SKIP == 5)
#define SKIP_TRACE    (PROFILE_SKIP == 3 || PROFILE_SKIP == 5)
#define SKIP_SCREEN   (PROFILE_SKIP == 4 || PROFILE_SKIP == 5)
#define SKIP_DIRECT   (PROFILE_SKIP == 6)
#define SKIP_WALK     (PROFILE_SKIP == 7 || PROFILE_SKIP == 9)
#define SKIP_ENTITY   (PROFILE_SKIP == 8)
#define DEAD_WALK     (PROFILE_SKIP == 9)

// --- Palette. Linear light. Deliberately dark: the reference reads like a
// heavy overcast dusk, not a bright cloudy day. EXPOSURE is the user knob. ---
const vec3 SKY_ZENITH       = vec3(0.10, 0.13, 0.17);
const vec3 SKY_HORIZON      = mix(vec3(0.17, 0.20, 0.24), vec3(0.13, 0.17, 0.27), FOG_COOL);
const vec3 FOG_COLOR        = mix(vec3(0.14, 0.17, 0.21), vec3(0.10, 0.14, 0.24), FOG_COOL);
const vec3 GROUND_BOUNCE    = vec3(0.030, 0.033, 0.037);
const vec3 SHADOW_TINT      = vec3(0.16, 0.20, 0.27); // cool lifted blacks (sRGB)

#endif

