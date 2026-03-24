//
//  Copyright (c) 2025 Contributors to the OpenRV project.
//  SPDX-License-Identifier: Apache-2.0
//
#include <IPBaseNodes/PaintIPNode.h>
#include <IPBaseNodes/ScopeGroupIPNode.h>
#include <IPCore/AdaptorIPNode.h>
#include <IPCore/IPGraph.h>
#include <IPCore/NodeDefinition.h>
#include <IPCore/ScopeIPNode.h>
#include <TwkContainer/Properties.h>

namespace IPCore
{
    using namespace std;
    using namespace TwkContainer;

    ScopeGroupIPNode::ScopeGroupIPNode(const std::string& name, const NodeDefinition* def, IPGraph* graph, GroupIPNode* group)
        : GroupIPNode(name, def, graph, group)
    {
        declareProperty<StringProperty>("ui.name", name);
        m_scopeNode = newMemberNodeOfType<ScopeIPNode>(scopeType(), "scope");
        setMaxInputs(1);
        setMinInputs(1);
        setRoot(m_scopeNode);

        // Default to histogram when used as a standalone viewable
        if (IntProperty* scopeProp = m_scopeNode->property<IntProperty>("node.scope"))
            scopeProp->front() = 1;
    }

    ScopeGroupIPNode::~ScopeGroupIPNode()
    {
        //
        //  The GroupIPNode will delete the root
        //
    }

    string ScopeGroupIPNode::scopeType() { return definition()->stringValue("defaults.scopeType", "RVScope"); }

    string ScopeGroupIPNode::paintType() { return definition()->stringValue("defaults.paintType", "Paint"); }

    IPNode* ScopeGroupIPNode::newSubGraphForInput(size_t index, const IPNodes& newInputs)
    {
        IPNode* innode = newInputs[index];
        AdaptorIPNode* anode = newAdaptorForInput(innode);
        PaintIPNode* paintNode = newMemberNodeOfTypeForInput<PaintIPNode>(paintType(), innode, "p");

        paintNode->setInputs1(anode);
        return paintNode;
    }

    void ScopeGroupIPNode::setInputs(const IPNodes& newInputs)
    {
        if (isDeleting())
        {
            IPNode::setInputs(newInputs);
        }
        else
        {
            setInputsWithReordering(newInputs, m_scopeNode);
        }
    }

} // namespace IPCore
