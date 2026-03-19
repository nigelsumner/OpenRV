//******************************************************************************
// Copyright (c) 2005 Tweak Inc.
// All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
//******************************************************************************
#ifndef __IPCore__ScopeIPNode__h__
#define __IPCore__ScopeIPNode__h__
#include <IPCore/IPNode.h>
#include <TwkFB/FrameBuffer.h>

namespace IPCore
{

    //
    //  Unified video scopes node — histogram, histogram parade,
    //  waveform, waveform parade, and future scope types.
    //
    //  node.scope values:
    //    0 = off
    //    1 = histogram (combined overlay)
    //    2 = histogram parade (R/G/B stacked)
    //    3 = waveform (chromatic composite)
    //    4 = waveform parade (R/G/B side-by-side)
    //

    class ScopeIPNode : public IPNode
    {
    public:
        ScopeIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group = 0);

        virtual ~ScopeIPNode();

        virtual IPImage* evaluate(const Context&);

    private:
        IPImage* evaluateHistogram(const Context&, IPImage* image, int scope);
        IPImage* evaluateWaveform(const Context&, IPImage* image, int scope);

        IntProperty* m_scope;
        FloatProperty* m_opacity;
    };

} // namespace IPCore
#endif // __IPCore__ScopeIPNode__h__
