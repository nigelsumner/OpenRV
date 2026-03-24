//
// Copyright (c) 2025 Contributors to the OpenRV project.
// SPDX-License-Identifier: Apache-2.0
//
// Composite scope overlay over background image.
// i0 = background (original input), i1 = scope visualization.
// opacity 1.0 = full scope, 0.0 = full input image.
// useAlpha: when 1.0, use i1's alpha to mask the scope region
// (needed for corner positioning where CLAMP_TO_EDGE would
// otherwise bleed the scope's edge texels across the frame).
//
vec4 ScopeComposite(const in vec4 i0, const in vec4 i1, const in float opacity, const in float useAlpha)
{
    float blend = mix(opacity, i1.a * opacity, useAlpha);
    return mix(i0, vec4(i1.rgb, 1.0), blend);
}
