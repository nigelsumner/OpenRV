//******************************************************************************
// Copyright (c) 2005 Tweak Inc.
// All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
//******************************************************************************
#include <IPCore/ScopeIPNode.h>
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

    ScopeIPNode::ScopeIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group)
        : IPNode(name, def, graph, group)
    {
        m_scope = declareProperty<IntProperty>("node.scope", 0);
        m_opacity = declareProperty<FloatProperty>("node.opacity", 0.95f);
    }

    ScopeIPNode::~ScopeIPNode() {}

    IPImage* ScopeIPNode::evaluate(const Context& context)
    {
        IPImage* image = IPNode::evaluate(context);
        if (!image)
            return IPImage::newNoImage(this, "No Input");

        int scope = m_scope ? m_scope->front() : 0;
        if (scope == 0)
            return image;

        // scope 1 = histogram, 2 = histogram parade
        if (scope == 1 || scope == 2)
            return evaluateHistogram(context, image, scope);

        // scope 3 = waveform, 4 = waveform parade
        if (scope == 3 || scope == 4)
            return evaluateWaveform(context, image, scope);

        return image;
    }

    IPImage* ScopeIPNode::evaluateHistogram(const Context& context, IPImage* image, int scope)
    {
        float opacity = m_opacity ? m_opacity->front() : 0.95f;

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
        if (scope == 2)
            result->mergeExpr = Shader::newScopeHistogramParade(result, inExpressions);
        else
            result->mergeExpr = Shader::newScopeHistogram(result, inExpressions);
        result->appendChild(histo);

        IPImage* composite = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        composite->blendMode = IPImage::Over;

        IPImage* bg = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        bg->shaderExpr = Shader::newSourceRGBA(bg);
        bg->appendChild(bgImage);

        result->shaderExpr = Shader::newOpacity(result, result->shaderExpr, opacity);

        composite->appendChild(result);
        composite->appendChild(bg);

        return composite;
    }

    IPImage* ScopeIPNode::evaluateWaveform(const Context& context, IPImage* image, int scope)
    {
        float opacity = m_opacity ? m_opacity->front() : 0.95f;
        int waveMode = (scope == 4) ? 1 : 0;

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

        IPImage* image2 = new IPImage(this, IPImage::BlendRenderType, newImage->width, newImage->height, 1.0, IPImage::IntermediateBuffer);
        image2->shaderExpr = Shader::newSourceRGBA(image2);
        image2->appendChild(newImage);

        size_t dataWidth = image2->width;
        size_t dataHeight = 256;

        IPImage* waveData =
            new IPImage(this, IPImage::BlendRenderType, dataWidth, dataHeight, 1.0, IPImage::DataBuffer, IPImage::FloatDataType);
        waveData->setWaveform(true);
        waveData->waveformMode = waveMode;
        waveData->appendChild(image2);
        waveData->shaderExpr = Shader::newSourceRGBA(waveData);

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
        if (scope == 4)
            result->mergeExpr = Shader::newScopeWaveformParade(result, inExpressions);
        else
            result->mergeExpr = Shader::newScopeWaveform(result, inExpressions);
        result->appendChild(waveData);

        IPImage* composite = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        composite->blendMode = IPImage::Over;

        IPImage* bg = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);
        bg->shaderExpr = Shader::newSourceRGBA(bg);
        bg->appendChild(bgImage);

        result->shaderExpr = Shader::newOpacity(result, result->shaderExpr, opacity);

        composite->appendChild(result);
        composite->appendChild(bg);

        return composite;
    }

} // namespace IPCore
