//******************************************************************************
// Copyright (c) 2005 Tweak Inc.
// All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
//******************************************************************************
#include <IPCore/WaveformIPNode.h>
#include <IPCore/Exception.h>
#include <IPCore/ShaderCommon.h>
#include <TwkMath/Function.h>
#include <TwkMath/Vec3.h>
#include <TwkMath/Iostream.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <stl_ext/string_algo.h>
#include <TwkFB/FrameBuffer.h>

namespace IPCore
{
    using namespace std;
    using namespace TwkContainer;
    using namespace TwkMath;
    using namespace TwkFB;

    WaveformIPNode::WaveformIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group)
        : IPNode(name, def, graph, group)
    {
        m_active = declareProperty<IntProperty>("node.active", 0);
        m_mode = declareProperty<IntProperty>("node.mode", 0);
        m_opacity = declareProperty<FloatProperty>("node.opacity", 0.95f);
    }

    WaveformIPNode::~WaveformIPNode() {}

    IPImage* WaveformIPNode::evaluate(const Context& context)
    {
        int frame = context.frame;
        IPImage* image = IPNode::evaluate(context);
        if (!image)
            return IPImage::newNoImage(this, "No Input");
        if (m_active && !m_active->front())
            return image;

        // float opacity = m_opacity ? m_opacity->front() : 0.95f;
        float opacity = 1;
        int mode = m_mode ? m_mode->front() : 0;

        // Second evaluation for the clean background pass
        IPImage* bgImage = IPNode::evaluate(context);

        IPImage* newImage = image;
        if (!image->shaderExpr && !image->mergeExpr)
        {
            assert(image->children && !image->children->next);
            newImage = image->children;
            image->children = NULL;
            delete image;
            image = NULL;
        }
        newImage->shaderExpr = Shader::newColorLinearToSRGB(newImage->shaderExpr);

        // Wrap source in an intermediate for CL/GL interop (same dimensions, no
        // downscaling).  A height-only downscale would letterbox the content due
        // to BlendRenderType preserving aspect ratio, leaving black columns on
        // both sides of the FBO — which the per-column CL kernel sees as empty.
        IPImage* image2 = new IPImage(this, IPImage::BlendRenderType, newImage->width, newImage->height, 1.0, IPImage::IntermediateBuffer);
        image2->shaderExpr = Shader::newSourceRGBA(image2);
        image2->appendChild(newImage);

        // Waveform data buffer: sourceWidth × 256 (columns × intensity bins)
        // CL kernel writes accumulated RGB into this texture
        size_t dataWidth = image2->width;
        size_t dataHeight = 256;

        IPImage* waveData =
            new IPImage(this, IPImage::BlendRenderType, dataWidth, dataHeight, 1.0, IPImage::DataBuffer, IPImage::FloatDataType);
        waveData->setWaveform(true);
        waveData->waveformMode = mode;
        waveData->appendChild(image2);
        waveData->shaderExpr = Shader::newSourceRGBA(waveData);

        // Output at source image dimensions
        size_t outWidth = newImage->width;
        size_t outHeight = newImage->height;

        IPImage* result = new IPImage(this, IPImage::MergeRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);

        IPImageVector images;
        IPImageSet modifiedImages;
        images.push_back(waveData);
        convertBlendRenderTypeToIntermediate(images, modifiedImages);
        Shader::ExpressionVector inExpressions;
        assembleMergeExpressions(result, images, modifiedImages, false, inExpressions);

        result->shaderExpr = Shader::newSourceRGBA(result);
        if (mode == 1)
            result->mergeExpr = Shader::newWaveformParade(result, inExpressions);
        else
            result->mergeExpr = Shader::newWaveform(result, inExpressions);
        result->appendChild(waveData);

        // Composite: source as base, waveform overlaid at reduced opacity
        IPImage* composite = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        composite->blendMode = IPImage::Over;

        // Wrap bgImage in an intermediate to ensure it has a shaderExpr
        IPImage* bg = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        bg->shaderExpr = Shader::newSourceRGBA(bg);
        bg->appendChild(bgImage);

        // Apply opacity to waveform result
        result->shaderExpr = Shader::newOpacity(result, result->shaderExpr, opacity);

        composite->appendChild(result); // waveform at reduced opacity (on top)
        composite->appendChild(bg);     // source image (base)

        return composite;
    }

} // namespace IPCore
