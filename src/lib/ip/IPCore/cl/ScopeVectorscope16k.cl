//
// Copyright (C) 2023  Autodesk, Inc. All Rights Reserved. 
// 
// SPDX-License-Identifier: Apache-2.0 
//
// Vectorscope: scatter each pixel's chrominance (Cb, Cr) into a 256x256 grid.
// Accumulated values are RGB colour + count in fixed-point (x1024).
//
// This variant is for devices with <= 16k local memory.
// (All variants are identical since vectorscope uses global-memory atomics.)
//
#define VSCOPE_BIN 256
#define CHANNEL 4

__kernel
void vectorscope256_float4(read_only image2d_t image,
                           __global uint* vscope,
                           uint imageWidth,
                           uint imageHeight)
{
    uint gx = get_global_id(0);
    uint gy = get_global_id(1);

    if (gx >= imageWidth || gy >= imageHeight) return;

    const sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_NEAREST;
    float4 c = read_imagef(image, sampler, (int2)(gx, gy));

    float r = max(0.0f, min(1.0f, c.x));
    float g = max(0.0f, min(1.0f, c.y));
    float b = max(0.0f, min(1.0f, c.z));

    float cb = -0.168736f * r - 0.331264f * g + 0.5f * b + 0.5f;
    float cr =  0.5f * r - 0.418688f * g - 0.081312f * b + 0.5f;

    cb = max(0.0f, min(1.0f, cb));
    cr = max(0.0f, min(1.0f, cr));

    uint cbBin = min((uint)(cb * 255.0f), (uint)255);
    uint crBin = min((uint)(cr * 255.0f), (uint)255);

    uint rVal = (uint)(r * 1024.0f);
    uint gVal = (uint)(g * 1024.0f);
    uint bVal = (uint)(b * 1024.0f);

    uint idx = (crBin * VSCOPE_BIN + cbBin) * CHANNEL;
    (void)atomic_add(vscope + idx + 0, rVal);
    (void)atomic_add(vscope + idx + 1, gVal);
    (void)atomic_add(vscope + idx + 2, bVal);
    (void)atomic_add(vscope + idx + 3, 1024u);
}

__kernel
void mergeVectorscope256_float4(__global const uint* vscope,
                                write_only image2d_t output,
                                uint binSize,
                                float imgSize)
{
    uint cb = get_global_id(0);
    uint cr = get_global_id(1);

    if (cb >= binSize || cr >= binSize) return;

    uint idx = (cr * binSize + cb) * CHANNEL;
    uint rSum = vscope[idx + 0];
    uint gSum = vscope[idx + 1];
    uint bSum = vscope[idx + 2];

    float scale = 1.0f / (imgSize * 1024.0f);
    float rf = (float)rSum * scale;
    float gf = (float)gSum * scale;
    float bf = (float)bSum * scale;

    write_imagef(output, (int2)(cb, cr), (float4)(rf, gf, bf, 1.0f));
}
