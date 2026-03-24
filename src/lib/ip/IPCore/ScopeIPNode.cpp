//******************************************************************************
// Copyright (c) 2005 Tweak Inc.
// All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
//******************************************************************************
#include <IPCore/ScopeIPNode.h>
#include <IPCore/NodeDefinition.h>
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
        int defaultScope = def->intValue("defaults.scope", 0);
        m_scope = declareProperty<IntProperty>("node.scope", defaultScope);
        m_position = declareProperty<IntProperty>("node.position", 0);
        m_opacity = declareProperty<FloatProperty>("node.opacity", 0.95f);
        m_manualScale = declareProperty<FloatProperty>("node.manualScale", 0.33f);
        m_manualTranslateX = declareProperty<FloatProperty>("node.manualTranslateX", 0.0f);
        m_manualTranslateY = declareProperty<FloatProperty>("node.manualTranslateY", 0.0f);
    }

    ScopeIPNode::~ScopeIPNode() {}

    IPImage* ScopeIPNode::evaluate(const Context& context)
    {
        const IPNodes& ins = inputs();
        if (ins.empty())
            return IPImage::newNoImage(this, "No Input");

        // Only use the first input even if multiple are connected.
        IPImage* image = ins.front()->evaluate(context);
        if (!image)
            return IPImage::newNoImage(this, "No Input");

        int scope = m_scope ? m_scope->front() : 0;
        if (scope == 0)
            return image;

        //
        // Build the pure scope data (MergeRenderType result).
        // This is used by both the pipeline node and the viewable.
        //
        IPImage* scopeResult = nullptr;
        if (scope == 1 || scope == 2)
            scopeResult = buildHistogramData(context, image, scope);
        else if (scope == 3 || scope == 4)
            scopeResult = buildWaveformData(context, image, scope);

        if (!scopeResult)
            return image;

        //
        // Blend scope over the original input following the ClarityIPNode
        // pattern — both the original input and the scope result participate
        // in a merge. The result renders to an IntermediateBuffer so it is
        // self-contained when used inside layouts/stacks.
        //
        float opacity = m_opacity ? m_opacity->front() : 0.95f;
        int position = m_position ? m_position->front() : 0;

        IPImage* bgImage = ins.front()->evaluate(context);

        size_t outWidth = scopeResult->width;
        size_t outHeight = scopeResult->height;

        //
        // Position the scope for corner modes.
        // 0 = Full (no transform), 1 = Bottom Left, 2 = Bottom Right.
        // The transform is applied to the scope child so that
        // computeMergeMatrix positions it within the composite.
        //
        float useAlpha = 0.0f;
        if (position != 0)
        {
            float s = 0.33f;
            float aspect = float(outWidth) / float(outHeight);
            float tx = 0.0f;
            float ty = (s - 1.0f) / 2.0f; // shift down to bottom

            if (position == 1) // Bottom Left
                tx = aspect * (s - 1.0f) / 2.0f;
            else if (position == 2) // Bottom Right
                tx = aspect * (1.0f - s) / 2.0f;
            else if (position == 3 || position == 4) // Manual / Static
            {
                s = m_manualScale ? m_manualScale->front() : 0.33f;
                tx = m_manualTranslateX ? m_manualTranslateX->front() : 0.0f;
                ty = m_manualTranslateY ? m_manualTranslateY->front() : 0.0f;
            }

            Mat44f T, S;
            T.makeTranslation(Vec3f(tx, ty, 0.0f));
            S.makeScale(Vec3f(s, s, 1.0f));
            scopeResult->transformMatrix = T * S;
            useAlpha = 1.0f;
        }

        IPImage* mergeResult = new IPImage(this, IPImage::MergeRenderType, outWidth, outHeight, 1.0, IPImage::IntermediateBuffer);

        IPImageVector images;
        IPImageSet modifiedImages;
        images.push_back(bgImage);
        images.push_back(scopeResult);

        convertBlendRenderTypeToIntermediate(images, modifiedImages);
        Shader::ExpressionVector inExpressions;
        assembleMergeExpressions(mergeResult, images, modifiedImages, false, inExpressions);

        mergeResult->mergeExpr = Shader::newScopeComposite(mergeResult, inExpressions, opacity, useAlpha);
        mergeResult->shaderExpr = Shader::newSourceRGBA(mergeResult);
        mergeResult->appendChildren(images);
        mergeResult->recordResourceUsage();

        //
        // Wrap the merge in a BlendRenderType shell. Transform2DIPNode
        // applies layout transforms to the children of an IntermediateBuffer,
        // which would break the merge shader's texture coordinate sampling.
        // Using CurrentFrameBuffer ensures the layout transform is applied to
        // this shell's root (correct for imageGeometryByIndex / manipulator),
        // while the inner mergeResult IntermediateBuffer keeps the merge
        // shader's children isolated.
        //
        IPImage* result = new IPImage(this, IPImage::BlendRenderType, outWidth, outHeight, 1.0, IPImage::CurrentFrameBuffer);
        result->appendChild(mergeResult);
        result->shaderExpr = Shader::newSourceRGBA(result);

        return result;
    }

    //
    // Build pure histogram scope image (no background compositing).
    // Returns a MergeRenderType IPImage with the histogram visualization.
    //
    IPImage* ScopeIPNode::buildHistogramData(const Context& context, IPImage* image, int scope)
    {
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

        result->mergeExpr =
            (scope == 2) ? Shader::newScopeHistogramParade(result, inExpressions) : Shader::newScopeHistogram(result, inExpressions);
        result->shaderExpr = Shader::newSourceRGBA(result);
        result->appendChild(histo);
        result->recordResourceUsage();

        return result;
    }

    //
    // Build pure waveform scope image (no background compositing).
    // Returns a MergeRenderType IPImage with the waveform visualization.
    //
    IPImage* ScopeIPNode::buildWaveformData(const Context& context, IPImage* image, int scope)
    {
        int waveMode = (scope == 4) ? 1 : 0;

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

        result->mergeExpr =
            (scope == 4) ? Shader::newScopeWaveformParade(result, inExpressions) : Shader::newScopeWaveform(result, inExpressions);
        result->shaderExpr = Shader::newSourceRGBA(result);
        result->appendChild(waveData);
        result->recordResourceUsage();

        return result;
    }

} // namespace IPCore
