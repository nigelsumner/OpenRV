//******************************************************************************
// Copyright (c) 2005 Tweak Inc.
// All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
//******************************************************************************
#ifndef __IPCore__WaveformIPNode__h__
#define __IPCore__WaveformIPNode__h__
#include <IPCore/IPNode.h>
#include <TwkFB/FrameBuffer.h>

namespace IPCore
{

    //
    //  Chromatic Waveform — plots pixel intensity (Y) vs horizontal position (X).
    //  256 vertical bins. Uses OpenCL for GPU-accelerated accumulation.
    //

    class WaveformIPNode : public IPNode
    {
    public:
        WaveformIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group = 0);

        virtual ~WaveformIPNode();

        virtual IPImage* evaluate(const Context&);

    private:
        IntProperty* m_active;
        IntProperty* m_mode;
        FloatProperty* m_opacity;
    };

} // namespace IPCore
#endif // __IPCore__WaveformIPNode__h__
