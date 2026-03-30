//
// Copyright (c) 2025 Contributors to the OpenRV project.
// SPDX-License-Identifier: Apache-2.0
//

//
//  Map scene-linear values to [0,1] via log2 normalization.
//
//  logMin: log2 of the lowest value to map (e.g. log2(0.005625) ≈ -7.47
//          for -5 stops from 18% grey)
//  logMax: log2 of the highest value to map (e.g. log2(11.52) ≈ 3.53
//          for +6 stops from 18% grey)
//
//  Values below 2^logMin clamp to 0, above 2^logMax clamp to 1.
//

vec4 ColorSceneLinearToNorm (const in vec4 P,
                             const in float logMin,
                             const in float logMax)
{
    vec3 c = max(P.rgb, vec3(0.000001));
    vec3 norm = (log2(c) - vec3(logMin)) / vec3(logMax - logMin);
    return vec4(clamp(norm, 0.0, 1.0), P.a);
}
