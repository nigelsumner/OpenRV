//******************************************************************************
// Copyright (c) 2005 Tweak Inc.
// All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
//******************************************************************************
#include <IPCore/HistogramIPNode.h>
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

    HistogramIPNode::HistogramIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group)
        : IPNode(name, def, graph, group)
    {
        m_active = declareProperty<IntProperty>("node.active", 1);
        m_height = declareProperty<IntProperty>("node.height", 600);
        m_opacity = declareProperty<FloatProperty>("node.opacity", 0.95f);
    }

    HistogramIPNode::~HistogramIPNode() {}

    IPImage* HistogramIPNode::evaluate(const Context& context)
    {

        int frame = context.frame;
        IPImage* image = IPNode::evaluate(context);
        if (!image)
            return IPImage::newNoImage(this, "No Input");
        if (m_active && !m_active->front())
            return image;

        float opacity = m_opacity ? m_opacity->front() : 0.95f;

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

        IPImage* image2 = NULL;
        size_t scale = max(newImage->width / 300, newImage->height / 300);
        if (scale > 1)
        {
            const size_t newWidth = newImage->width / scale;
            const size_t newHeight = newImage->height / scale;

            IPImage* smallImage = new IPImage(this, IPImage::BlendRenderType, newWidth, newHeight, 1.0, IPImage::IntermediateBuffer);
            smallImage->shaderExpr = Shader::newSourceRGBA(smallImage);
            smallImage->appendChild(newImage);
            image2 = smallImage;
        }
        else
        {
            // this is the case where the image has a fb, and cannot be
            // converted by convertBlend func
            IPImage* insertImage =
                new IPImage(this, IPImage::BlendRenderType, newImage->width, newImage->height, 1.0, IPImage::IntermediateBuffer);
            insertImage->shaderExpr = Shader::newSourceRGBA(insertImage);
            insertImage->appendChild(newImage);
            image2 = insertImage;
        }

        size_t width = 256;

        IPImage* histo = new IPImage(this, IPImage::BlendRenderType, width, 1, 1.0, IPImage::DataBuffer, IPImage::FloatDataType);
        histo->setHistogram(true);
        histo->appendChild(image2);
        histo->shaderExpr = Shader::newSourceRGBA(histo);

        // this image will have a shaderExpr that uses the histogram result to
        // render a histogram — match the source image dimensions
        size_t outWidth = newImage->width;
        size_t outHeight = newImage->height;

        IPImage* result = new IPImage(this, IPImage::MergeRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);

        IPImageVector images;
        IPImageSet modifiedImages;
        images.push_back(histo);
        convertBlendRenderTypeToIntermediate(images, modifiedImages);
        Shader::ExpressionVector inExpressions;
        assembleMergeExpressions(result, images, modifiedImages, false, inExpressions);

        result->shaderExpr = Shader::newSourceRGBA(result);
        result->mergeExpr = Shader::newHistogram(result, inExpressions);
        result->appendChild(histo);

        // Composite: source as base, histogram overlaid at reduced opacity
        IPImage* composite = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        composite->blendMode = IPImage::Over;

        // Wrap bgImage in an intermediate to ensure it has a shaderExpr
        IPImage* bg = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        bg->shaderExpr = Shader::newSourceRGBA(bg);
        bg->appendChild(bgImage);

        // Apply opacity to histogram result
        result->shaderExpr = Shader::newOpacity(result, result->shaderExpr, opacity);

        composite->appendChild(result); // source image (base)
        composite->appendChild(bg);     // histogram at reduced opacity (on top)

        return composite;
    }

} // namespace IPCore
