//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// Vectorscope display -- chrominance scatter on a Cb (X) vs Cr (Y) grid.
// Input: 256x256 data texture, each texel holds accumulated RGB colour
// and pixel count for that (Cb, Cr) bin.
//
vec4 ScopeVectorscope (const in inputImage in0,
                       const in outputImage win)
{
    vec2 winSize  = win.size();
    vec2 dataSize = in0.size();
    float normX   = win.st.x / winSize.x;
    float normY   = win.st.y / winSize.y;

    // Edge fade for alpha — transparent at borders for corner positioning
    float borderFade = smoothstep(0.0, 3.0 / winSize.x, normX)
                     * smoothstep(0.0, 3.0 / winSize.x, 1.0 - normX)
                     * smoothstep(0.0, 3.0 / winSize.y, normY)
                     * smoothstep(0.0, 3.0 / winSize.y, 1.0 - normY);

    // Maintain 1:1 aspect ratio (square) with pillarbox/letterbox
    float aspect = winSize.x / winSize.y;
    float cx, cy; // centered coordinates in [0,1] mapped to the square region
    if (aspect > 1.0)
    {
        // Wide: pillarbox — center horizontally
        float margin = (1.0 - 1.0 / aspect) * 0.5;
        cx = (normX - margin) * aspect;
        cy = normY;
        if (cx < 0.0 || cx > 1.0) return vec4(0.0, 0.0, 0.0, borderFade);
    }
    else
    {
        // Tall: letterbox — center vertically
        float margin = (1.0 - aspect) * 0.5;
        cx = normX;
        cy = (normY - margin) / aspect;
        if (cy < 0.0 || cy > 1.0) return vec4(0.0, 0.0, 0.0, borderFade);
    }

    // Map to data texture coordinates
    float dataX = cx * dataSize.x;
    float dataY = cy * dataSize.y;

    // Distance from center (0.5, 0.5) in normalized coords
    float dx = cx - 0.5;
    float dy = cy - 0.5;
    float dist = sqrt(dx * dx + dy * dy);

    // Black background
    vec4 bg = vec4(0.0, 0.0, 0.0, 1.0);

    // Graticule: outer circle at radius 0.5 (full range)
    float circleOuter = abs(dist - 0.5) * min(winSize.x, winSize.y);
    float outerAlpha = (1.0 - smoothstep(0.0, 1.2, circleOuter)) * 0.35;

    // Graticule: 75% level circle at radius 0.375
    float circle75 = abs(dist - 0.375) * min(winSize.x, winSize.y);
    float c75Alpha = (1.0 - smoothstep(0.0, 1.2, circle75)) * 0.25;

    // Crosshair lines through center
    float crossH = abs(cy - 0.5) * min(winSize.x, winSize.y);
    float crossV = abs(cx - 0.5) * min(winSize.x, winSize.y);
    float crossAlpha = ((1.0 - smoothstep(0.0, 0.8, crossH))
                      + (1.0 - smoothstep(0.0, 0.8, crossV))) * 0.15;

    // Skin tone line: extends from center at ~123 degrees from +Cb axis
    // In (cx, cy) space: angle from center towards upper-left
    // BT.601 skin tone direction: approximately (Cb-0.5, Cr-0.5) = (-0.06, 0.07)
    // normalized direction: (-0.65, 0.76)
    float skinDirX = -0.65;
    float skinDirY =  0.76;
    // Project (dx, dy) onto perpendicular of skin direction
    float skinPerp = abs(dx * skinDirY - dy * skinDirX) * min(winSize.x, winSize.y);
    // Only draw where projection along skin direction is positive (outward from center)
    float skinProj = dx * skinDirX + dy * skinDirY;
    float skinAlpha = (1.0 - smoothstep(0.0, 1.0, skinPerp)) * step(0.01, skinProj) * 0.4;
    vec3 skinCol = vec3(0.6, 0.5, 0.3);

    // 75% color bar target positions in normalized [0,1] Cb/Cr space (BT.601)
    //   Red:     (0.373, 0.875)
    //   Green:   (0.252, 0.186)
    //   Blue:    (0.875, 0.439)
    //   Cyan:    (0.627, 0.125)
    //   Magenta: (0.748, 0.814)
    //   Yellow:  (0.125, 0.561)
    vec2 targets[6];
    targets[0] = vec2(0.373, 0.875); // Red
    targets[1] = vec2(0.252, 0.186); // Green
    targets[2] = vec2(0.875, 0.439); // Blue
    targets[3] = vec2(0.627, 0.125); // Cyan
    targets[4] = vec2(0.748, 0.814); // Magenta
    targets[5] = vec2(0.125, 0.561); // Yellow

    vec3 targetColors[6];
    targetColors[0] = vec3(0.6, 0.2, 0.2); // Red
    targetColors[1] = vec3(0.2, 0.5, 0.2); // Green
    targetColors[2] = vec3(0.2, 0.2, 0.6); // Blue
    targetColors[3] = vec3(0.2, 0.5, 0.5); // Cyan
    targetColors[4] = vec3(0.5, 0.2, 0.5); // Magenta
    targetColors[5] = vec3(0.5, 0.5, 0.2); // Yellow

    // Draw target boxes (small squares at each color bar position)
    float targetAlpha = 0.0;
    vec3 targetCol = vec3(0.0);
    float boxSize = 4.0 / min(winSize.x, winSize.y); // ~4 pixels
    for (int t = 0; t < 6; t++)
    {
        vec2 tp = targets[t];
        if (abs(cx - tp.x) < boxSize && abs(cy - tp.y) < boxSize)
        {
            // Box outline: draw only the border
            float innerSize = boxSize * 0.6;
            if (abs(cx - tp.x) > innerSize || abs(cy - tp.y) > innerSize)
            {
                targetAlpha = 0.7;
                targetCol = targetColors[t];
            }
        }
    }

    // Sample the vectorscope data
    vec4 acc = in0(vec2(dataX - in0.st.x, dataY - in0.st.y));

    // Density: how much total colour energy in this bin
    float density = dot(acc.rgb, vec3(0.2126, 0.7152, 0.0722));

    // Logarithmic compression for wide dynamic range.
    // Bin values from the CL kernel are normalized by total-pixel-count,
    // so popular bins might be ~0.01-0.05 while sparse bins are ~0.0001.
    float gain = 200.0;
    float logScale = log(1.0 + density * gain) / log(1.0 + gain);
    logScale = clamp(logScale, 0.0, 1.0);

    // Derive chromatic colour from the accumulated RGB, normalised to unit
    // luminance so colour direction is preserved regardless of density.
    vec3 chromaCol = vec3(0.0);
    if (density > 0.0)
    {
        chromaCol = acc.rgb / (density + 1.0e-6);
        // Slight boost for visibility
        chromaCol = clamp(chromaCol * 0.5, 0.0, 1.0);
    }

    vec3 col = bg.rgb;

    // Layer graticule
    vec3 lineCol = vec3(0.30, 0.30, 0.22);
    col = mix(col, lineCol, outerAlpha);
    col = mix(col, lineCol, c75Alpha);
    col = mix(col, lineCol, crossAlpha);

    // Layer skin tone line
    col = mix(col, skinCol, skinAlpha);

    // Layer target boxes
    col = mix(col, targetCol, targetAlpha);

    // Layer data on top if visible
    if (logScale > 0.005)
    {
        // Blend chromatic colour by density
        vec3 dataCol = mix(chromaCol * 0.3, chromaCol, logScale);
        dataCol = clamp(dataCol, 0.0, 1.0);
        col = mix(col, dataCol, logScale);
    }

    return vec4(col, borderFade);
}
