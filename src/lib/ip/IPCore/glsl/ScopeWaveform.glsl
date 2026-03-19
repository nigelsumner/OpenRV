//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// Chromatic waveform display -- intensity (Y) vs horizontal position (X).
// Input: 2D waveform data texture (sourceWidth x 256), each texel holds
// accumulated RGB colour for that (column, intensity_bin).
//
vec4 ScopeWaveform (const in inputImage in0,
               const in outputImage win)
{
    vec2 winSize  = win.size();
    vec2 dataSize = in0.size();
    float normX   = win.st.x / winSize.x;
    float normY   = win.st.y / winSize.y;

    // Map normalised output coords to data texture coords.
    float targetX = normX * dataSize.x;
    float targetY = normY * dataSize.y;

    // Sample the waveform accumulation at this (column, intensity)
    vec4 acc = in0(vec2(targetX - in0.st.x, targetY - in0.st.y));

    // Black background
    vec4 bg = vec4(0.0, 0.0, 0.0, 1.0);

    // Horizontal grid lines (10 evenly spaced, antialiased, semi-transparent amber)
    float gridCount = 10.0;
    float gridPitch = winSize.y / gridCount;
    float distToLine = abs(fract(normY * gridCount + 0.5) - 0.5) * gridPitch;
    float lineAlpha = (1.0 - smoothstep(0.0, 1.0, distToLine)) * 0.25;
    vec3 lineCol = vec3(0.35, 0.35, 0.20);

    // Tone-map the accumulated colour
    float gain = 8.0;
    vec3 mapped = vec3(1.0) - exp(-gain * acc.rgb);

    // Threshold: skip very dim bins for a cleaner look
    float lum = dot(mapped, vec3(0.2126, 0.7152, 0.0722));
    if (lum < 0.01)
        return vec4(mix(bg.rgb, lineCol, lineAlpha), 1.0);

    // Chromatic colouring with slight saturation boost
    vec3 col = mapped * 1.2;
    col = clamp(col, 0.0, 1.0);

    // Blend grid lines
    col = mix(col, lineCol, lineAlpha);

    return vec4(col, 1.0);
}
