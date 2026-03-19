//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// Combined histogram — R, G, B channels overlaid on a single panel.
//
vec4 ScopeHistogram (const in inputImage in0,
                const in outputImage win)
{
    vec2 winSize  = win.size();
    vec2 dataSize = in0.size();
    float normX   = win.st.x / winSize.x;
    float normY   = win.st.y / winSize.y;

    // Sample histogram data: map normalized x to data texel position
    float texX = in0.st.x;
    float texY = in0.st.y;
    float dataX = normX * dataSize.x;
    vec3 h = in0(vec2(dataX - texX, -texY)).rgb;

    // Black background
    vec4 bg = vec4(0.0, 0.0, 0.0, 1.0);

    // Vertical grid lines (10 evenly spaced, antialiased, semi-transparent)
    float gridCount = 10.0;
    float gridPitch = winSize.x / gridCount;
    float distToLine = abs(fract(normX * gridCount + 0.5) - 0.5) * gridPitch;
    float lineAlpha = (1.0 - smoothstep(0.0, 1.0, distToLine)) * 0.25;
    vec3 lineCol = vec3(0.35, 0.35, 0.20);

    // Normalize bin values; sqrt compresses range for visibility
    vec3 nh = sqrt(h) * 2.0;

    // Each channel fills from bottom (normY=0) upward
    float rFill = step(normY, nh.r);
    float gFill = step(normY, nh.g);
    float bFill = step(normY, nh.b);

    // If no channel reaches this height, draw background + grid
    if (rFill + gFill + bFill < 0.5)
        return vec4(mix(bg.rgb, lineCol, lineAlpha), 1.0);

    // Edge glow near the curve tops
    float rEdge = smoothstep(nh.r - 0.02, nh.r, normY) * rFill;
    float gEdge = smoothstep(nh.g - 0.02, nh.g, normY) * gFill;
    float bEdge = smoothstep(nh.b - 0.02, nh.b, normY) * bFill;

    // Additive colour blending — channels overlap and combine
    vec3 col = vec3(0.0);
    col.r += rFill * mix(0.06, 0.50, rEdge);
    col.g += gFill * mix(0.04, 0.35, gEdge);
    col.b += bFill * mix(0.05, 0.40, bEdge);

    // Where channels overlap, the additive blend creates secondary colours
    // (yellow where R+G overlap, cyan where G+B, magenta where R+B, white where all 3)
    col = clamp(col, 0.0, 1.0);

    // Blend grid lines
    col = mix(col, lineCol, lineAlpha);

    return vec4(col, 1.0);
}
