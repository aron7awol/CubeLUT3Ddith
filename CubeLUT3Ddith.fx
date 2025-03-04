// LUT shader loading a custom .cube 1D LUT with Advanced Dithering
// Author: BarricadeMKXX (Original), Modified by Claude
// 2024-03-04
// License: MIT
// Credits to Marty McFly's LUT shader!

#include "ReShade.fxh"

#if __RESHADE__ < 60000
    #error "This ReShade version does not support .cube LUT files. Please update to at least ReShade 6.0.0."
#endif

uniform bool bDither_Enable <
    ui_type = "checkbox";
    ui_label = "Enable Dithering";
    ui_tooltip = "Enables ordered dithering to reduce color banding.";
> = true;

uniform float fDither_Gamma <
    ui_type = "slider";
    ui_min = 1.0; 
    ui_max = 6.0;
    ui_step = 0.1;
    ui_label = "Dither Gamma";
    ui_tooltip = "Gamma curve used for dithering. Higher values increase contrast.";
> = 2.2;

// Rest of the existing uniforms remain the same
uniform int iSample_Mode<
    ui_type = "combo";
    ui_label = "Sampling Mode";
    ui_items = "ReShade Internal\0Trilinear\0Tetrahedral\0";
> = 1;

uniform float fLUT_Intensity <
    ui_type = "slider";
    ui_min = 0.00; ui_max = 1.00;
    ui_label = "LUT Intensity";
    ui_tooltip = "Overall intensity of the LUT effect.";
> = 1.00;

uniform float fLUT_AmountChroma <
	ui_type = "slider";
	ui_min = 0.00; ui_max = 1.00;
	ui_label = "LUT Chroma Amount";
	ui_tooltip = "Intensity of color/chroma change of the LUT.";
> = 1.00;

uniform float fLUT_AmountLuma <
	ui_type = "slider";
	ui_min = 0.00; ui_max = 1.00;
	ui_label = "LUT Luma Amount";
	ui_tooltip = "Intensity of luma change of the LUT.";
> = 1.00;

#ifndef SOURCE_CUBELUT3D_FILE
    #define SOURCE_CUBELUT3D_FILE "Neutral33-3D.cube"
#endif

#ifndef CUBE_3D_SIZE
    #define CUBE_3D_SIZE 33
#endif

texture3D texCube3D < source = SOURCE_CUBELUT3D_FILE; >
{
    Width = CUBE_3D_SIZE;
    Height = CUBE_3D_SIZE;
    Depth = CUBE_3D_SIZE;
    Format = RGBA32F;
};

sampler3D sampCube3D
{
    Texture = texCube3D;
    AddressU = CLAMP;
    AddressV = CLAMP;
    AddressW = CLAMP;
    MinFilter = LINEAR; MagFilter = LINEAR; MipFilter = LINEAR;
};

// Noise texture for dithering
texture2D noisetex < source = "LDR_LLL1_0.png"; >
{
    Width = 64;
    Height = 64;
    Format = R8;
};

sampler2D noiseSmp
{
    Texture = noisetex;
    AddressU = REPEAT;
    AddressV = REPEAT;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
};

// Previous LUT sampling functions remain the same
float3 Cube3D_Triliniar(sampler3D cube, float3 in_color, int cube_size)
{
    in_color = saturate(in_color) * (cube_size - 1);
    int3 indices[2] = { int3(floor(in_color).xyz), int3(ceil(in_color).xyz) };
    float3 q = in_color - indices[0];

    float3 p[8];
    for(int i = 0; i < 8; ++i)
    {
        p[i] = tex3Dfetch(cube, int3(indices[(i>>2)&1].x, indices[(i>>1)&1].y, indices[i&1].z)).xyz;
    }
    return lerp(
                lerp(lerp(p[0], p[1], q.z), lerp(p[2], p[3], q.z), q.y),
                lerp(lerp(p[4], p[5], q.z), lerp(p[6], p[7], q.z), q.y),
            q.x);
}

float3 Cube3D_Tetrahedral(sampler3D cube, float3 in_color, int cube_size)
{
    in_color = saturate(in_color) * (cube_size - 1);
    int3 indices[2] = { int3(floor(in_color).xyz), int3(ceil(in_color).xyz) };
    float3 q = in_color - indices[0];
    int3 comp1 = q.xyz > q.yzx;
    int3 comp2 = (1 - comp1).zxy;

    const float3 p_max = tex3Dfetch(cube, indices[0] + comp1).xyz;
    const float3 p_min = tex3Dfetch(cube, indices[0] + comp2).xyz;
    const float3 p_000 = tex3Dfetch(cube, indices[0]).xyz;
    const float3 p_111 = tex3Dfetch(cube, indices[1]).xyz;

    const float3 v_111 = q - float3(1,1,1);
    const float3 v_max = q - comp1;
    const float3 v_min = q - comp2;
    const float3 v_000 = q;

    float4 weight = float4(
        1,
        abs(dot(cross(v_000, v_min), v_111)),
        abs(dot(cross(v_000, v_max), v_111)),
        abs(dot(cross(v_min, v_max), v_111))
    );

    weight.x -= dot(weight.yzw, 1);
    return p_111 * weight.x + p_max * weight.y + p_min * weight.z + p_000 * weight.w;
}

// Advanced Ordered Dithering Function
float3 OrderedDither(float3 rgb, float2 pos)
{
    // If dithering is disabled, return original color
    if (!bDither_Enable) return rgb;

    // Compute floor and ceiling of color values
    float3 low = floor(rgb * 255.0) / 255.0;
    float3 high = low + 1.0 / 255.0;

    // Convert to linear space using adjustable gamma
    float3 rgb_linear = pow(rgb, fDither_Gamma);
    float3 low_linear = pow(low, fDither_Gamma);
    float3 high_linear = pow(high, fDither_Gamma);

    // Sample noise 
    float noise = tex2D(noiseSmp, pos / 64.0).x;

    // Compute threshold and apply dithering
    float3 threshold = lerp(low_linear, high_linear, noise);
    
    return lerp(low, high, rgb_linear > threshold);
}

void PS_CubeLUT3D_Apply(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 res : SV_TARGET0)
{
    // Sample original color
    float3 color = tex2D(ReShade::BackBuffer, texcoord.xy).xyz;
    
    float3 lutcolor;
    switch(iSample_Mode)
    {
        case 1:
        {
            lutcolor = Cube3D_Triliniar(sampCube3D, color.xyz, CUBE_3D_SIZE);
            break;
        }
        case 2:
        {
            lutcolor = Cube3D_Tetrahedral(sampCube3D, color.xyz, CUBE_3D_SIZE);
            break;
        }
        default:
        {
            color = (color - 0.5) *((CUBE_3D_SIZE - 1.0) / CUBE_3D_SIZE) + 0.5;
            lutcolor = tex3D(sampCube3D, color.xyz).xyz;
            break;
        }
    }

    lutcolor = lerp(color.xyz, lutcolor, fLUT_Intensity);

    color.xyz = lerp(normalize(color.xyz), normalize(lutcolor.xyz), fLUT_AmountChroma) *
	            lerp(length(color.xyz),    length(lutcolor.xyz),    fLUT_AmountLuma);

    // Apply advanced dithering after LUT processing
    color.xyz = OrderedDither(color.xyz, vpos.xy);

    res.xyz = color.xyz;
    res.w = 1.0;
}

technique CubeLUT3D<
    ui_label = "Cube LUT 3D with Advanced Dithering";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CubeLUT3D_Apply;
    }
}