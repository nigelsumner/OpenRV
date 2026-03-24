//
//  Copyright (c) 2025 Contributors to the OpenRV project.
//  SPDX-License-Identifier: Apache-2.0
//
#ifndef __IPGraph__ScopeGroupIPNode__h__
#define __IPGraph__ScopeGroupIPNode__h__
#include <iostream>
#include <IPCore/GroupIPNode.h>

namespace IPCore
{
    class ScopeIPNode;
    class PaintIPNode;

    /// ScopeGroupIPNode is a top-level viewable that wraps a ScopeIPNode
    ///
    /// The sub-graph contains one scope node and a paint node per input.

    class ScopeGroupIPNode : public GroupIPNode
    {
    public:
        ScopeGroupIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group = 0);

        virtual ~ScopeGroupIPNode();

        virtual void setInputs(const IPNodes&);
        virtual IPNode* newSubGraphForInput(size_t, const IPNodes&);

        ScopeIPNode* scopeNode() const { return m_scopeNode; }

    private:
        std::string scopeType();
        std::string paintType();

    private:
        ScopeIPNode* m_scopeNode;
    };

} // namespace IPCore

#endif // __IPGraph__ScopeGroupIPNode__h__
