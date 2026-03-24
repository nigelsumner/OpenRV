//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// Chromatic waveform kernel — 16k local memory variant (NBANKS=4).
//
#define WAVEFORM_BIN_NO 256
#define NBANKS 4
#define CHANNEL 4

__kernel
void waveform256_float4(read_only image2d_t image,
                        __global uint* waveform,
                        uint imageWidth,
                        uint imageHeight,
                        uint mode)
{
    uint col       = get_group_id(0);
    uint localID   = get_local_id(0);
    uint localSize = get_local_size(0);

    __local uint subWaveform[CHANNEL * NBANKS * WAVEFORM_BIN_NO];

    for (uint i = localID; i < CHANNEL * NBANKS * WAVEFORM_BIN_NO; i += localSize)
    {
        subWaveform[i] = 0;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    if (col >= imageWidth) return;

    const sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_NEAREST;
    uint bankOffset = localID % NBANKS;

    for (uint row = localID; row < imageHeight; row += localSize)
    {
        float4 c = read_imagef(image, sampler, (int2)(col, row));

        if (mode == 1u)
        {
            float channels[3] = {max(0.0f, min(1.0f, c.x)),
                                 max(0.0f, min(1.0f, c.y)),
                                 max(0.0f, min(1.0f, c.z))};

            for (int ch = 0; ch < 3; ch++)
            {
                float fbin = channels[ch] * 255.0f;
                uint bin0 = min((uint)fbin, (uint)255);
                uint bin1 = min(bin0 + 1u, (uint)255);
                float frac = fbin - (float)bin0;
                float w0 = 1.0f - frac;
                float w1 = frac;

                // Count-based: accumulate pixel count, not value.
                // The Y-bin already encodes the intensity.
                uint loc0 = (bin0 * CHANNEL + ch) * NBANKS + bankOffset;
                (void)atomic_add(subWaveform + loc0, (uint)(w0 * 1024.0f));

                if (bin1 != bin0)
                {
                    uint loc1 = (bin1 * CHANNEL + ch) * NBANKS + bankOffset;
                    (void)atomic_add(subWaveform + loc1, (uint)(w1 * 1024.0f));
                }
            }
        }
        else
        {
        float luma = 0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z;
        luma = max(0.0f, min(1.0f, luma));

        float fbin = luma * 255.0f;
        uint bin0 = min((uint)fbin, (uint)255);
        uint bin1 = min(bin0 + 1u, (uint)255);
        float frac = fbin - (float)bin0;
        float w0 = 1.0f - frac;
        float w1 = frac;

        uint rVal = (uint)(max(0.0f, min(1.0f, c.x)) * 1024.0f);
        uint gVal = (uint)(max(0.0f, min(1.0f, c.y)) * 1024.0f);
        uint bVal = (uint)(max(0.0f, min(1.0f, c.z)) * 1024.0f);

        uint rLoc0 = (bin0 * CHANNEL + 0) * NBANKS + bankOffset;
        uint gLoc0 = (bin0 * CHANNEL + 1) * NBANKS + bankOffset;
        uint bLoc0 = (bin0 * CHANNEL + 2) * NBANKS + bankOffset;
        uint cLoc0 = (bin0 * CHANNEL + 3) * NBANKS + bankOffset;

        (void)atomic_add(subWaveform + cLoc0, (uint)(w0 * 1024.0f));
        (void)atomic_add(subWaveform + rLoc0, (uint)(w0 * (float)rVal));
        (void)atomic_add(subWaveform + gLoc0, (uint)(w0 * (float)gVal));
        (void)atomic_add(subWaveform + bLoc0, (uint)(w0 * (float)bVal));

        if (bin1 != bin0)
        {
            uint rLoc1 = (bin1 * CHANNEL + 0) * NBANKS + bankOffset;
            uint gLoc1 = (bin1 * CHANNEL + 1) * NBANKS + bankOffset;
            uint bLoc1 = (bin1 * CHANNEL + 2) * NBANKS + bankOffset;
            uint cLoc1 = (bin1 * CHANNEL + 3) * NBANKS + bankOffset;

            (void)atomic_add(subWaveform + cLoc1, (uint)(w1 * 1024.0f));
            (void)atomic_add(subWaveform + rLoc1, (uint)(w1 * (float)rVal));
            (void)atomic_add(subWaveform + gLoc1, (uint)(w1 * (float)gVal));
            (void)atomic_add(subWaveform + bLoc1, (uint)(w1 * (float)bVal));
        }
        }
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    for (uint bin = localID; bin < WAVEFORM_BIN_NO; bin += localSize)
    {
        uint rSum = 0, gSum = 0, bSum = 0, cnt = 0;
        for (uint i = 0; i < NBANKS; i++)
        {
            rSum += subWaveform[(bin * CHANNEL + 0) * NBANKS + i];
            gSum += subWaveform[(bin * CHANNEL + 1) * NBANKS + i];
            bSum += subWaveform[(bin * CHANNEL + 2) * NBANKS + i];
            cnt  += subWaveform[(bin * CHANNEL + 3) * NBANKS + i];
        }

        uint baseIdx = (col * WAVEFORM_BIN_NO + bin) * CHANNEL;
        waveform[baseIdx + 0] = rSum;
        waveform[baseIdx + 1] = gSum;
        waveform[baseIdx + 2] = bSum;
        waveform[baseIdx + 3] = cnt;
    }
}

__kernel
void mergeWaveform256_float4(__global const uint* waveform,
                             write_only image2d_t output,
                             uint imageWidth,
                             float imgSize)
{
    uint col = get_global_id(0);
    uint bin = get_global_id(1);

    if (col >= imageWidth || bin >= WAVEFORM_BIN_NO) return;

    uint baseIdx = (col * WAVEFORM_BIN_NO + bin) * CHANNEL;
    uint rSum = waveform[baseIdx + 0];
    uint gSum = waveform[baseIdx + 1];
    uint bSum = waveform[baseIdx + 2];

    float scale = 1.0f / (imgSize * 1024.0f);
    float r = (float)rSum * scale;
    float g = (float)gSum * scale;
    float b = (float)bSum * scale;

    write_imagef(output, (int2)(col, bin), (float4)(r, g, b, 1.0f));
}
