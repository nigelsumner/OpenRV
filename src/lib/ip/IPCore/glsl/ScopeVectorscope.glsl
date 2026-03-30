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

    // Maintain 1:1 aspect ratio (square) with pillarbox/letterbox
    float aspect = winSize.x / winSize.y;
    float cx, cy; // centered coordinates in [0,1] mapped to the square region
    if (aspect > 1.0)
    {
        // Wide: pillarbox — center horizontally
        float margin = (1.0 - 1.0 / aspect) * 0.5;
        cx = (normX - margin) * aspect;
        cy = normY;
        if (cx < 0.0 || cx > 1.0) return vec4(0.0, 0.0, 0.0, 1.0);
    }
    else
    {
        // Tall: letterbox — center vertically
        float margin = (1.0 - aspect) * 0.5;
        cx = normX;
        cy = (normY - margin) / aspect;
        if (cy < 0.0 || cy > 1.0) return vec4(0.0, 0.0, 0.0, 1.0);
    }

    // Map to data texture coordinates
    float dataX = cx * dataSize.x;
    float dataY = cy * dataSize.y;

    // Black background
    vec4 bg = vec4(0.0, 0.0, 0.0, 1.0);

    // Sample the vectorscope data
    vec4 acc = in0(vec2(dataX - in0.st.x, dataY - in0.st.y));

    // Density: how much total colour energy in this bin
    float density = dot(acc.rgb, vec3(0.2126, 0.7152, 0.0722));

    // Logarithmic compression for wide dynamic range.
    float gain = 200.0;
    float logScale = log(1.0 + density * gain) / log(1.0 + gain);
    logScale = clamp(logScale, 0.0, 1.0);

    // Derive chromatic colour from the accumulated RGB, normalised to unit
    // luminance so colour direction is preserved regardless of density.
    vec3 chromaCol = vec3(0.0);
    if (density > 0.0)
    {
        chromaCol = acc.rgb / (density + 1.0e-6);
        chromaCol = clamp(chromaCol * 0.5, 0.0, 1.0);
    }

    vec3 col = bg.rgb;

    // Layer data on top if visible
    if (logScale > 0.005)
    {
        vec3 dataCol = mix(chromaCol * 0.3, chromaCol, logScale);
        dataCol = clamp(dataCol, 0.0, 1.0);
        col = mix(col, dataCol, logScale);
    }

    return vec4(col, 1.0);
}
