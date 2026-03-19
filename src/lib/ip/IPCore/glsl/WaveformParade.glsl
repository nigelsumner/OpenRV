//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// Waveform parade display -- R, G, B channels side by side.
// Input: 2D waveform data texture (sourceWidth x 256), each texel holds
// accumulated RGB colour for that (column, intensity_bin).
//
vec4 WaveformParade (const in inputImage in0,
                     const in outputImage win)
{
    vec2 winSize  = win.size();
    vec2 dataSize = in0.size();
    float normX   = win.st.x / winSize.x;
    float normY   = win.st.y / winSize.y;

    // Black background
    vec4 bg = vec4(0.0, 0.0, 0.0, 1.0);

    // 3 panels side by side: left=Red, centre=Green, right=Blue
    float panelF  = normX * 3.0;
    float panel   = clamp(floor(panelF), 0.0, 2.0);
    float localX  = panelF - panel;

    // Panel separator lines (~1px vertical)
    float sepW = 1.5 / winSize.x;
    float atSep1 = step(1.0 / 3.0 - sepW, normX) * step(normX, 1.0 / 3.0 + sepW);
    float atSep2 = step(2.0 / 3.0 - sepW, normX) * step(normX, 2.0 / 3.0 + sepW);
    if (atSep1 + atSep2 > 0.0)
        return vec4(0.15, 0.15, 0.15, 1.0);

    // Map local panel X to data texture column
    float targetX = localX * dataSize.x;
    float targetY = normY * dataSize.y;

    // Sample the waveform accumulation at this (column, intensity)
    vec4 acc = in0(vec2(targetX - in0.st.x, targetY - in0.st.y));

    // Tone-map the accumulated colour
    float gain = 8.0;
    vec3 mapped = vec3(1.0) - exp(-gain * acc.rgb);

    // Select channel for this panel
    float isR = step(panel, 0.5);
    float isG = step(0.5, panel) * step(panel, 1.5);
    float isB = step(1.5, panel);

    float val = mapped.r * isR + mapped.g * isG + mapped.b * isB;

    // Threshold: skip very dim bins for a cleaner look
    if (val < 0.01)
        return bg;

    // Monochrome channel colouring
    vec3 col = vec3(val * isR, val * isG, val * isB);
    col = clamp(col * 1.2, 0.0, 1.0);

    return vec4(col, 1.0);
}
