//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// DaVinci Resolve-style 3-panel parade histogram (R / G / B stacked)
//
vec4 Histogram (const in inputImage in0,
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

    // Black background — alpha 1.0 so the overlay darkens the source
    vec4 bg = vec4(0.0, 0.0, 0.0, 1.0);

    // Vertical grid lines (10 evenly spaced, muted gold)
    // Distance to nearest grid line in FBO pixels — always catches exactly 1 pixel
    float gridCount = 10.0;
    float distToLine = abs(fract(normX * gridCount + 0.5) - 0.5) * winSize.x / gridCount;
    if (distToLine < 0.7)
        return vec4(0.18, 0.16, 0.06, 1.0);

    // 3 panels in normalized Y: bottom=Blue, middle=Green, top=Red
    float panelF = normY * 3.0;
    float panel  = clamp(floor(panelF), 0.0, 2.0);
    float localY = panelF - panel;

    // Panel separator lines (~1px)
    float sepW = 1.5 / winSize.y;
    float atSep1 = step(1.0 / 3.0 - sepW, normY) * step(normY, 1.0 / 3.0 + sepW);
    float atSep2 = step(2.0 / 3.0 - sepW, normY) * step(normY, 2.0 / 3.0 + sepW);
    if (atSep1 + atSep2 > 0.0)
        return vec4(0.15, 0.15, 0.15, 1.0);

    // Normalize bin values; sqrt compresses range for visibility
    vec3 nh = sqrt(h) * 2.0;

    // Select channel for this panel
    float isB = step(panel, 0.5);
    float isG = step(0.5, panel) * step(panel, 1.5);
    float isR = step(1.5, panel);

    float val = nh.r * isR + nh.g * isG + nh.b * isB;

    if (localY < val)
    {
        // Edge glow near the curve top
        float edge = smoothstep(val - 0.02, val, localY);

        // Dark semi-transparent fill (blended over black)
        vec3 fill = vec3(0.14 * isR, 0.07 * isG, 0.11 * isB) * 0.2;
        // Bright edge / outline colour
        vec3 bright = vec3(0.42 * isR, 0.27 * isG, 0.35 * isB);

        vec3 col = mix(fill, bright, edge);
        return vec4(col, 1.0);
    }

    return bg;
}

