#version 330 compatibility
#include "/lib/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/atmosphere.glsl"

// Rain and snow. Drawn after deferred; without this program the fallback
// would paint the raw white texture over the lit scene.

uniform sampler2D gtexture;
uniform float sunAngle;

in vec2 texcoord;
in vec4 vcolor;

/* DRAWBUFFERS:0 */
void main() {
    vec4 albedo = texture(gtexture, texcoord) * vcolor;
    if (albedo.a < 0.01) discard;
#if SNOW_ENABLED
    // Snow is marched through the air by the composite pass, see lib/snow.glsl
    if (snowing()) discard;
#endif

    float day = daylight(sunAngle);
    vec3 col = mix(FOG_COLOR, SKY_HORIZON, 0.5) * ambientScale(day) * 1.1;
    gl_FragData[0] = vec4(col, albedo.a * 0.45);
}

