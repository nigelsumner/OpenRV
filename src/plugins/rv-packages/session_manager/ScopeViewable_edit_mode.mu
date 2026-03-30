//
// Copyright (c) 2025 Contributors to the OpenRV project.
// SPDX-License-Identifier: Apache-2.0
//

module: ScopeViewable_edit_mode
{
use rvtypes;
use commands;
use rvui;
use qt;
use session_manager;
use extra_commands;
use gl;
use glyph;
use app_utils;
use io;
use system;
use math;
use math_util;
use math_linear;
require gltext;

class: ScopeViewableEditMode : MinorMode
{
    QWidget   _ui;
    QComboBox _scopeTypeCombo;
    QComboBox _positionCombo;
    QComboBox _signalTypeCombo;
    QSlider   _opacitySlider;
    QLineEdit _opacityLineEdit;
    QLineEdit   _refLine1ValueEdit;
    QLineEdit   _refLine1LabelEdit;
    QToolButton _refLine1ClearBtn;
    QLineEdit   _refLine2ValueEdit;
    QLineEdit   _refLine2LabelEdit;
    QToolButton _refLine2ClearBtn;

    union: ManipControl
    {
          NoControl
        | FreeTranslation
        | TopLeftCorner
        | TopRightCorner
        | BotLeftCorner
        | BotRightCorner
    }

    use ManipControl;

    ManipControl _control;
    Point        _downPoint;
    Vec2         _gc;
    Vec2         _corner;
    bool         _dragging;
    bool         _hovering;
    bool         _updatingUI;

    method: auxFilePath (string; string name)
    {
        io.path.join(supportPath("session_manager", "session_manager"), name);
    }

    method: setScopeType (void; int index)
    {
        set("#RVScopeViewable.node.scope", index);
        redraw();
    }

    method: setPosition (void; int index)
    {
        int oldPos = getIntProperty("#RVScopeViewable.node.position").front();
        set("#RVScopeViewable.node.position", index);

        if ((index == 3 || index == 4) && (oldPos == 0 || oldPos == 1 || oldPos == 2))
        {
            float s  = 1.0;
            float tx = 0.0;
            float ty = 0.0;

            if (oldPos == 1 || oldPos == 2)
            {
                float aspect = 1.0;
                int idx = scopeImageIndex();
                if (idx != -1)
                {
                    let corners = imageGeometryByIndex(idx);
                    if (corners.size() >= 4)
                    {
                        float ba = mag(corners[1] - corners[0]);
                        float da = mag(corners[3] - corners[0]);
                        if (ba > 1.0 && da > 1.0) aspect = ba / da;
                    }
                }

                s  = 0.33;
                ty = (s - 1.0) / 2.0;

                if (oldPos == 1)
                    tx = aspect * (s - 1.0) / 2.0;
                else
                    tx = aspect * (1.0 - s) / 2.0;
            }

            set("#RVScopeViewable.node.manualScale", s);
            set("#RVScopeViewable.node.manualTranslateX", tx);
            set("#RVScopeViewable.node.manualTranslateY", ty);
        }

        redraw();
    }

    method: setScopeTypeEvent (void; Event event, int index)
    {
        setScopeType(index);
    }

    method: setSignalType (void; int comboIndex)
    {
        // Combo: 0=Auto, 1=Linear sRGB, 2=Scene Linear, 3=PQ, 4=HLG
        if (comboIndex == 0)
        {
            set("#RVScopeViewable.node.signalAutoDetect", 1);
            // Resolve now and push to signalType so C++ shader matches
            int detected = detectSignalTypeFromOCIO();
            set("#RVScopeViewable.node.signalType", detected);
        }
        else
        {
            set("#RVScopeViewable.node.signalAutoDetect", 0);
            set("#RVScopeViewable.node.signalType", comboIndex - 1);
        }
        refreshRefLinesList();
        redraw();
    }

    method: setSignalTypeEvent (void; Event event, int index)
    {
        setSignalType(index);
    }

    method: signalTypeState ((int;); int comboVal)
    {
        \: (int;)
        {
            // comboVal 0=Auto, 1-4=manual
            int autoMode = 0;
            try { autoMode = getIntProperty("#RVScopeViewable.node.signalAutoDetect").front(); }
            catch (...) { ; }

            if (comboVal == 0)
            {
                if autoMode == 1 then CheckedMenuState else UncheckedMenuState;
            }
            else
            {
                if (autoMode == 1) return UncheckedMenuState;
                int v = 0;
                try { v = getIntProperty("#RVScopeViewable.node.signalType").front(); }
                catch (...) { ; }
                if v == (comboVal - 1) then CheckedMenuState else UncheckedMenuState;
            };
        };
    }

    method: setOpacityFromSlider (void; int value)
    {
        float opacity = float(value) / 100.0;
        _opacityLineEdit.setText("%g" % opacity);
        set("#RVScopeViewable.node.opacity", opacity);
        redraw();
    }

    // ── Reference Lines ──────────────────────────────────────────

    method: refLinePropBase (string; int sigType)
    {
        "#RVScopeViewable.refLines.sig%d" % sigType;
    }

    method: ensureRefLineProps (void; int sigType)
    {
        string base = refLinePropBase(sigType);
        string vProp = base + "_values";
        string lProp = base + "_labels";
        if (!propertyExists(vProp))
            newProperty(vProp, FloatType, 1);
        if (!propertyExists(lProp))
            newProperty(lProp, StringType, 1);
    }

    method: getRefLineValues (float[]; int sigType)
    {
        ensureRefLineProps(sigType);
        try { return getFloatProperty(refLinePropBase(sigType) + "_values"); }
        catch (...) { return float[](); }
    }

    method: getRefLineLabels (string[]; int sigType)
    {
        ensureRefLineProps(sigType);
        try { return getStringProperty(refLinePropBase(sigType) + "_labels"); }
        catch (...) { return string[](); }
    }

    method: setRefLineData (void; int sigType, float[] values, string[] labels)
    {
        ensureRefLineProps(sigType);
        setFloatProperty(refLinePropBase(sigType) + "_values", values, true);
        setStringProperty(refLinePropBase(sigType) + "_labels", labels, true);
    }

    method: displayValueToNorm (float; float displayVal, int sigType)
    {
        //  Convert a user-entered display value to normalised 0-1 scope position.
        //  sRGB (0):      pass-through (already 0-1)
        //  Scene Lin (1):  stops → (stop - minStop) / (maxStop - minStop)
        //  PQ (2):         nits → PQ code value via ST.2084 inverse EOTF
        //  HLG (3):        percentage → / 100
        if (sigType == 1)
        {
            // stops: -5..+6 maps to 0..1
            return (displayVal - (-5.0)) / (6.0 - (-5.0));
        }
        if (sigType == 2)
        {
            // nits to PQ code value (ST.2084 inverse EOTF)
            float Y = displayVal / 10000.0;
            if (Y <= 0.0) return 0.0;
            float m1 = 0.1593017578125;
            float m2 = 78.84375;
            float c1 = 0.8359375;
            float c2 = 18.8515625;
            float c3 = 18.6875;
            float Ym1 = math.pow(Y, m1);
            return math.pow((c1 + c2 * Ym1) / (1.0 + c3 * Ym1), m2);
        }
        if (sigType == 3)
        {
            return displayVal / 100.0;
        }
        return displayVal;  // sRGB: 0-1 direct
    }

    method: normToDisplayValue (float; float norm, int sigType)
    {
        //  Reverse of displayValueToNorm for list display.
        if (sigType == 1)
            return norm * 11.0 + (-5.0);
        if (sigType == 2)
        {
            // PQ code value → nits
            float m1 = 0.1593017578125;
            float m2 = 78.84375;
            float c1 = 0.8359375;
            float c2 = 18.8515625;
            float c3 = 18.6875;
            float Nm = math.pow(norm, 1.0 / m2);
            float num = Nm - c1;
            if (num < 0.0) num = 0.0;
            float Y = math.pow(num / (c2 - c3 * Nm), 1.0 / m1);
            return Y * 10000.0;
        }
        if (sigType == 3)
            return norm * 100.0;
        return norm;
    }

    method: clearRefLine (void; int slot, bool checked)
    {
        int sig = currentSignalType();
        let vals = getRefLineValues(sig);
        let labs = getRefLineLabels(sig);

        float[] newVals = float[]();
        string[] newLabs = string[]();
        for (int i = 0; i < vals.size(); i++)
        {
            if (i != slot)
            {
                newVals.push_back(vals[i]);
                if (i < labs.size()) newLabs.push_back(labs[i]);
            }
        }
        setRefLineData(sig, newVals, newLabs);
        refreshRefLinesList();
        redraw();
    }

    method: roundSigFigs (float; float val, int n)
    {
        if (val == 0.0) return 0.0;
        float av = math.abs(val);
        float mag = math.floor(math.log(av) / math.log(10.0));
        float scale = math.pow(10.0, float(n) - 1.0 - mag);
        return math.floor(val * scale + 0.5) / scale;
    }

    method: refreshRefLinesList (void;)
    {
        if (_refLine1ValueEdit eq nil) return;

        int sig = currentSignalType();
        let vals = getRefLineValues(sig);
        let labs = getRefLineLabels(sig);

        // Slot 1
        if (vals.size() > 0)
        {
            float dv = normToDisplayValue(vals[0], sig);
            // Round to 4 significant figures to avoid float round-trip artifacts
            dv = roundSigFigs(dv, 4);
            string valStr = "%g" % dv;
            _refLine1ValueEdit.setText(valStr);
            _refLine1LabelEdit.setText(if (labs.size() > 0) then labs[0] else "");
        }
        else
        {
            _refLine1ValueEdit.setText("");
            _refLine1LabelEdit.setText("");
        }

        // Slot 2
        if (vals.size() > 1)
        {
            float dv = normToDisplayValue(vals[1], sig);
            // Round to 4 significant figures to avoid float round-trip artifacts
            dv = roundSigFigs(dv, 4);
            string valStr = "%g" % dv;
            _refLine2ValueEdit.setText(valStr);
            _refLine2LabelEdit.setText(if (labs.size() > 1) then labs[1] else "");
        }
        else
        {
            _refLine2ValueEdit.setText("");
            _refLine2LabelEdit.setText("");
        }
    }

    method: commitRefLines (void;)
    {
        int sig = currentSignalType();
        float[] newVals = float[]();
        string[] newLabs = string[]();

        // Slot 1
        string v1 = _refLine1ValueEdit.text();
        if (v1 != "")
        {
            try
            {
                float dv = float(v1);
                float norm = displayValueToNorm(dv, sig);
                newVals.push_back(norm);
                newLabs.push_back(_refLine1LabelEdit.text());
            }
            catch (...) { ; }
        }

        // Slot 2
        string v2 = _refLine2ValueEdit.text();
        if (v2 != "")
        {
            try
            {
                float dv = float(v2);
                float norm = displayValueToNorm(dv, sig);
                newVals.push_back(norm);
                newLabs.push_back(_refLine2LabelEdit.text());
            }
            catch (...) { ; }
        }

        setRefLineData(sig, newVals, newLabs);
        redraw();
    }

    method: setOpacityFromText (void;)
    {
        try
        {
            float opacity = float(_opacityLineEdit.text());
            if (opacity < 0.0) opacity = 0.0;
            if (opacity > 1.0) opacity = 1.0;
            _opacitySlider.setValue(int(opacity * 100.0));
            set("#RVScopeViewable.node.opacity", opacity);
            redraw();
        }
        catch (...)
        {
            _opacityLineEdit.setText("0.75");
            _opacitySlider.setValue(75);
            set("#RVScopeViewable.node.opacity", 0.75);
            redraw();
        }
    }

    method: updateUI (void;)
    {
        if (_ui eq nil) return;
        if (_updatingUI) return;
        _updatingUI = true;

        try
        {
            int scopeVal = getIntProperty("#RVScopeViewable.node.scope").front();
            _scopeTypeCombo.setCurrentIndex(scopeVal);
        }
        catch (...)
        {
            _scopeTypeCombo.setCurrentIndex(0);
        }

        try
        {
            int posVal = getIntProperty("#RVScopeViewable.node.position").front();
            _positionCombo.setCurrentIndex(posVal);
        }
        catch (...)
        {
            _positionCombo.setCurrentIndex(0);
        }

        try
        {
            int autoMode = 0;
            try { autoMode = getIntProperty("#RVScopeViewable.node.signalAutoDetect").front(); }
            catch (...) { ; }

            if (autoMode == 1)
                _signalTypeCombo.setCurrentIndex(0);
            else
            {
                int sigVal = getIntProperty("#RVScopeViewable.node.signalType").front();
                _signalTypeCombo.setCurrentIndex(sigVal + 1);
            }
        }
        catch (...)
        {
            _signalTypeCombo.setCurrentIndex(0);
        }

        try
        {
            float opacity = getFloatProperty("#RVScopeViewable.node.opacity").front();
            _opacityLineEdit.setText("%g" % opacity);
            _opacitySlider.setValue(int(opacity * 100.0));
        }
        catch (...)
        {
            _opacityLineEdit.setText("0.75");
            _opacitySlider.setValue(75);
        }

        refreshRefLinesList();
        _updatingUI = false;
    }

    method: propertyChanged (void; Event event)
    {
        let prop  = event.contents(),
            parts = prop.split("."),
            node  = parts[0],
            comp  = parts[1],
            name  = parts[2];

        if (nodeType(node) == "RVScopeViewable") updateUI();

        // Deactivate if view changed away from a scope viewable
        if (comp == "graph" || name == "viewNode")
        {
            try
            {
                bool hasScopeViewable = false;
                for_each (i; renderedImages())
                {
                    try { if (nodeType(i.node) == "RVScopeViewable") hasScopeViewable = true; }
                    catch (...) { ; }
                }
                if (!hasScopeViewable && _active) toggle();
            }
            catch (...) { ; }
        }

        event.reject();
    }

    method: loadUI (void; Event event)
    {
        State state = data();

        if (state.sessionManager neq nil)
        {
            SessionManagerMode manager = state.sessionManager;
            let m = mainWindowWidget();

            if (_ui eq nil)
            {
                _ui              = loadUIFile(manager.auxFilePath("scope.ui"), m);
                _scopeTypeCombo  = _ui.findChild("scopeTypeCombo");
                _positionCombo   = _ui.findChild("positionCombo");
                _signalTypeCombo = _ui.findChild("signalTypeCombo");
                _opacitySlider   = _ui.findChild("opacitySlider");
                _opacityLineEdit = _ui.findChild("opacityLineEdit");
                // Fixed ref line slot widgets
                _refLine1ValueEdit = _ui.findChild("refLine1ValueEdit");
                _refLine1LabelEdit = _ui.findChild("refLine1LabelEdit");
                _refLine1ClearBtn  = _ui.findChild("refLine1ClearBtn");
                _refLine2ValueEdit = _ui.findChild("refLine2ValueEdit");
                _refLine2LabelEdit = _ui.findChild("refLine2LabelEdit");
                _refLine2ClearBtn  = _ui.findChild("refLine2ClearBtn");

                manager.addEditor("Scope", _ui);
                connect(_scopeTypeCombo, QComboBox.currentIndexChanged, setScopeType);
                connect(_positionCombo, QComboBox.currentIndexChanged, setPosition);
                connect(_signalTypeCombo, QComboBox.currentIndexChanged, setSignalType);
                connect(_opacitySlider, QSlider.valueChanged, setOpacityFromSlider);
                connect(_opacityLineEdit, QLineEdit.editingFinished, setOpacityFromText);
                connect(_refLine1ValueEdit, QLineEdit.editingFinished, commitRefLines);
                connect(_refLine1LabelEdit, QLineEdit.editingFinished, commitRefLines);
                connect(_refLine2ValueEdit, QLineEdit.editingFinished, commitRefLines);
                connect(_refLine2LabelEdit, QLineEdit.editingFinished, commitRefLines);
                connect(_refLine1ClearBtn, QToolButton.clicked, clearRefLine(0, ));
                connect(_refLine2ClearBtn, QToolButton.clicked, clearRefLine(1, ));
            }

            updateUI();
            manager.useEditor("Scope");
        }

        // Activate local events when a ScopeViewable is in view
        if (!_active) toggle();

        event.reject();
    }

    method: scopeState ((int;); int scopeVal)
    {
        \: (int;)
        {
            let v = getIntProperty("#RVScopeViewable.node.scope").front();
            if v == scopeVal then CheckedMenuState else UncheckedMenuState;
        };
    }

    //
    //  Manual mode interactive manipulator
    //

    method: isManualMode (bool;)
    {
        try
        {
            return getIntProperty("#RVScopeViewable.node.position").front() == 3;
        }
        catch (...) { return false; }
    }

    method: isStaticMode (bool;)
    {
        try
        {
            return getIntProperty("#RVScopeViewable.node.position").front() == 4;
        }
        catch (...) { return false; }
    }

    method: scopeImageIndex (int;)
    {
        let _ri = renderedImages();
        int foundIdx = -1;
        for_each (i; _ri)
        {
            try
            {
                if (nodeType(i.node) == "RVScopeViewable" && foundIdx == -1) foundIdx = i.index;
            }
            catch (...) { ; }
        }

        if (foundIdx != -1) return foundIdx;

        try
        {
            if (nodeType(viewNode()) == "RVScopeViewable") return 0;
        }
        catch (...) { ; }

        if (_ri.size() > 0) return _ri[0].index;

        return -1;
    }

    method: scopeSubCorners (Point[];)
    {
        //
        // Compute the scope overlay sub-rectangle in screen pixels.
        // The full image corners give us the composited image extent.
        // The scope occupies a sub-region based on manual properties.
        //
        // In aspect-space, the full image spans [-aspect/2, aspect/2] x [-0.5, 0.5].
        // The scope center is at (tx, ty) with uniform scale s, covering:
        //   X: [tx - s*aspect/2, tx + s*aspect/2]
        //   Y: [ty - s/2, ty + s/2]
        // In normalized [0,1] space:
        //   nx: [0.5 + tx/aspect - s/2, 0.5 + tx/aspect + s/2]
        //   ny: [0.5 + ty - s/2, 0.5 + ty + s/2]
        //
        let idx = scopeImageIndex();
        if (idx == -1) return Point[]();

        try
        {
            let corners = imageGeometryByIndex(idx);
            if (corners.size() < 4) return Point[]();

            float s  = getFloatProperty("#RVScopeViewable.node.manualScale").front();
            float tx = getFloatProperty("#RVScopeViewable.node.manualTranslateX").front();
            float ty = getFloatProperty("#RVScopeViewable.node.manualTranslateY").front();

            let a = corners[0],
                b = corners[1],
                c = corners[2],
                d = corners[3];

            // Image axes in screen space
            let right = b - a,
                up    = d - a,
                ba    = mag(right),
                da    = mag(up);

            if (ba < 1.0 || da < 1.0) return Point[]();

            float aspect = ba / da;

            // Normalized scope bounds [0,1] within image
            float nxMin = 0.5 + tx / aspect - s / 2.0;
            float nxMax = 0.5 + tx / aspect + s / 2.0;
            float nyMin = 0.5 + ty - s / 2.0;
            float nyMax = 0.5 + ty + s / 2.0;

            // Map normalized to screen pixel via image corners
            // P = a + nx * right + ny * up
            let s0 = a + nxMin * right + nyMin * up,  // BL
                s1 = a + nxMax * right + nyMin * up,  // BR
                s2 = a + nxMax * right + nyMax * up,  // TR
                s3 = a + nxMin * right + nyMax * up;  // TL

            return Point[] {s0, s1, s2, s3};
        }
        catch (...) { return Point[](); }
    }

    method: scopeActiveCorners (Point[];)
    {
        //
        // Returns the scope rectangle in screen pixels for ANY position mode.
        // Full: entire image.  Bottom Left / Right: preset sub-rect.
        // Manual / Static: reads manual properties (same as scopeSubCorners).
        //
        let idx = scopeImageIndex();
        if (idx == -1) return Point[]();

        try
        {
            let corners = imageGeometryByIndex(idx);
            if (corners.size() < 4) return Point[]();

            let a = corners[0],
                b = corners[1],
                c = corners[2],
                d = corners[3];

            let right = b - a,
                up    = d - a,
                ba    = mag(right),
                da    = mag(up);

            if (ba < 1.0 || da < 1.0) return Point[]();

            float aspect = ba / da;

            int position = 0;
            try { position = getIntProperty("#RVScopeViewable.node.position").front(); }
            catch (...) { ; }

            float s  = 1.0;
            float tx = 0.0;
            float ty = 0.0;

            if (position == 1) // Bottom Left
            {
                s  = 0.33;
                tx = aspect * (s - 1.0) / 2.0;
                ty = (s - 1.0) / 2.0;
            }
            else if (position == 2) // Bottom Right
            {
                s  = 0.33;
                tx = aspect * (1.0 - s) / 2.0;
                ty = (s - 1.0) / 2.0;
            }
            else if (position == 3 || position == 4) // Manual / Static
            {
                s  = getFloatProperty("#RVScopeViewable.node.manualScale").front();
                tx = getFloatProperty("#RVScopeViewable.node.manualTranslateX").front();
                ty = getFloatProperty("#RVScopeViewable.node.manualTranslateY").front();
            }

            float nxMin = 0.5 + tx / aspect - s / 2.0;
            float nxMax = 0.5 + tx / aspect + s / 2.0;
            float nyMin = 0.5 + ty - s / 2.0;
            float nyMax = 0.5 + ty + s / 2.0;

            let s0 = a + nxMin * right + nyMin * up,
                s1 = a + nxMax * right + nyMin * up,
                s2 = a + nxMax * right + nyMax * up,
                s3 = a + nxMin * right + nyMax * up;

            return Point[] {s0, s1, s2, s3};
        }
        catch (...) { return Point[](); }
    }

    \: computeGC (Vec2; Point[] corners)
    {
        Point gc;
        for_each (c; corners) gc += c;
        gc /= float(corners.size());
        gc;
    }

    method: hitTest ((ManipControl, Vec2, Vec2); Point[] corners, Point p)
    {
        if (corners.size() < 4) return (NoControl, Point(0,0), Point(0,0));

        let gc = computeGC(corners);

        for_each (c; corners)
        {
            let v = p - c;
            if (abs(v.x) < 25.0 && abs(v.y) < 25.0)
            {
                let ctrl = if c.x < gc.x
                    then (if c.y > gc.y then TopLeftCorner else BotLeftCorner)
                    else (if c.y > gc.y then TopRightCorner else BotRightCorner);
                return (ctrl, gc, c);
            }
        }

        return (FreeTranslation, gc, p);
    }

    method: pointInsideRect (bool; Point[] corners, Point p)
    {
        if (corners.size() < 4) return false;

        // Axis-aligned test using bounding box of the 4 corners
        float minX = corners[0].x, maxX = corners[0].x;
        float minY = corners[0].y, maxY = corners[0].y;
        for_index (i; corners)
        {
            if (corners[i].x < minX) minX = corners[i].x;
            if (corners[i].x > maxX) maxX = corners[i].x;
            if (corners[i].y < minY) minY = corners[i].y;
            if (corners[i].y > maxY) maxY = corners[i].y;
        }
        return p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY;
    }

    method: manipMove (void; Event event)
    {
        if (!isManualMode()) { event.reject(); return; }

        let p = event.pointer() * devicePixelRatio();

        let corners = scopeSubCorners();
        if (corners.size() < 4) { _hovering = false; event.reject(); return; }

        let inside = pointInsideRect(corners, p);

        if (inside)
        {
            _hovering = true;
            let (ctrl, gc, corner) = hitTest(corners, p);
            _gc = gc;
            _control = ctrl;
            _corner = corner;

            case (_control)
            {
                TopRightCorner  -> { setCursor(Qt.SizeBDiagCursor); }
                BotLeftCorner   -> { setCursor(Qt.SizeBDiagCursor); }
                TopLeftCorner   -> { setCursor(Qt.SizeFDiagCursor); }
                BotRightCorner  -> { setCursor(Qt.SizeFDiagCursor); }
                FreeTranslation -> { setCursor(Qt.OpenHandCursor); }
                _               -> { ; }
            }
            redraw();
        }
        else
        {
            if (_hovering)
            {
                _hovering = false;
                _control = NoControl;
                setCursor(Qt.ArrowCursor);
                redraw();
            }
        }

        event.reject();
    }

    method: manipPush (void; Event event)
    {
        if (!isManualMode()) { event.reject(); return; }

        let corners = scopeSubCorners();
        if (corners.size() < 4) { event.reject(); return; }

        let p = event.pointer() * devicePixelRatio();
        let inside = pointInsideRect(corners, p);
        if (!inside) { event.reject(); return; }
        _hovering = true;
        let (ctrl, gc, corner) = hitTest(corners, p);
        _gc = gc;
        _control = ctrl;
        _corner = corner;
        _downPoint = p;
        _dragging = true;
        setCursor(Qt.ClosedHandCursor);
        redraw();
    }

    method: manipDrag (void; Event event)
    {
        if (!_dragging) { event.reject(); return; }

        try
        {
            let idx = scopeImageIndex();
            if (idx == -1) return;

            let corners = imageGeometryByIndex(idx);
            if (corners.size() < 4) return;

            let a     = corners[0],
                b     = corners[1],
                d     = corners[3],
                ba    = mag(b - a),
                da    = mag(d - a),
                aspect = ba / da;

            float s  = getFloatProperty("#RVScopeViewable.node.manualScale").front();
            float tx = getFloatProperty("#RVScopeViewable.node.manualTranslateX").front();
            float ty = getFloatProperty("#RVScopeViewable.node.manualTranslateY").front();

            let pp = event.pointer() * devicePixelRatio(),
                dp = _downPoint,
                ip = pp - dp;

            case (_control)
            {
                FreeTranslation ->
                {
                    // Convert pixel delta to aspect-space delta
                    float dxAspect = ip.x / ba * aspect;
                    float dyAspect = ip.y / da;
                    set("#RVScopeViewable.node.manualTranslateX", tx + dxAspect);
                    set("#RVScopeViewable.node.manualTranslateY", ty + dyAspect);
                }
                _ ->
                {
                    // Corner drag → scale + translate
                    let sc = scopeSubCorners();
                    if (sc.size() >= 4)
                    {
                        let sgc     = computeGC(sc),
                            diagDir = normalize(_corner - sgc),
                            diagDist  = dot(pp - sgc, diagDir),
                            downDist  = dot(_downPoint - sgc, diagDir);

                        if (abs(downDist) > 1.0)
                        {
                            let diff = diagDist - downDist,
                                scl  = (diagDist - diff / 2.0) / downDist,
                                sv   = diff * diagDir;

                            float sdxAspect = sv.x / ba * aspect;
                            float sdyAspect = sv.y / da;

                            float newScale = max(s * scl, 0.05);
                            set("#RVScopeViewable.node.manualScale", newScale);
                            set("#RVScopeViewable.node.manualTranslateX", tx + sdxAspect / 2.0);
                            set("#RVScopeViewable.node.manualTranslateY", ty + sdyAspect / 2.0);
                        }
                    }
                }
            }

            _downPoint = pp;
            redraw();
        }
        catch (...) { ; }
    }

    method: manipRelease (void; Event event)
    {
        if (_dragging)
        {
            _dragging = false;
            if (_hovering)
                setCursor(Qt.OpenHandCursor);
            else
                setCursor(Qt.ArrowCursor);
            redraw();
        }
        event.reject();
    }

    //
    // ── Grid & Graticule Drawing ──────────────────────────────────
    //
    //  Scale model — data-driven tick positions and labels per signal type.
    //  Adding a new signal type = add one case to each method + the combo box.
    //
    //  signalType values (node.signalType property, always 0-3):
    //    0 = Linear sRGB (current default)
    //    1 = Scene Linear (log2 stops relative to 18% grey)
    //    2 = PQ ST.2084 (nits)
    //    3 = HLG BT.2100 (signal %)
    //
    //  node.signalAutoDetect: 1 = auto-detect from OCIO, 0 = manual
    //  Combo box indices: 0=Auto, 1=sRGB, 2=Scene Linear, 3=PQ, 4=HLG
    //

    method: scaleTicks (float[]; int signalType)
    {
        if (signalType == 1)
            return float[] {0.0, 0.091, 0.182, 0.273, 0.364, 0.455, 0.545, 0.636, 0.727, 0.818, 0.909, 1.0};
        if (signalType == 2)
            // PQ code values for 0, 50, 100, 200, 400, 1000, 2000, 4000, 10000 nits
            return float[] {0.0, 0.4435, 0.5081, 0.5791, 0.6526, 0.7518, 0.8274, 0.9026, 1.0};
        if (signalType == 3)
            return float[] {0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0};
        return float[] {0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0};
    }

    method: scaleLabels (string[]; int signalType)
    {
        if (signalType == 1)
            return string[] {"-5", "-4", "-3", "-2", "-1", "0", "+1", "+2", "+3", "+4", "+5", "+6"};
        if (signalType == 2)
            return string[] {"0", "50", "100", "200", "400", "1k", "2k", "4k", "10k"};
        if (signalType == 3)
            return string[] {"0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"};
        return string[] {"0.0", "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8", "0.9", "1.0"};
    }

    method: scaleGridTicks (float[]; int signalType)
    {
        // Grid lines including 0.0 and 1.0 boundary lines
        if (signalType == 1)
            return float[] {0.0, 0.091, 0.182, 0.273, 0.364, 0.455, 0.545, 0.636, 0.727, 0.818, 0.909, 1.0};
        if (signalType == 2)
            // PQ code values for 0, 50, 100, 200, 400, 1000, 2000, 4000, 10000 nits
            return float[] {0.0, 0.4435, 0.5081, 0.5791, 0.6526, 0.7518, 0.8274, 0.9026, 1.0};
        if (signalType == 3)
            return float[] {0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0};
        return float[] {0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0};
    }

    method: signalName (string; int signalType)
    {
        if (signalType == 1) return "SCENE LINEAR";
        if (signalType == 2) return "PQ";
        if (signalType == 3) return "HLG";
        return "LINEAR SRGB";
    }

    method: signalUnit (string; int signalType)
    {
        if (signalType == 1) return "Stops";
        if (signalType == 2) return "Nits";
        if (signalType == 3) return "%";
        return "";
    }

    method: detectSignalTypeFromOCIO (int;)
    {
        //
        //  Walk from the current sources to the OCIOFile linearize node
        //  and pattern-match the inColorSpace name to a signal type.
        //  Returns: 0=sRGB, 1=Scene Linear, 2=PQ, 3=HLG
        //
        try
        {
            let sources = sourcesAtFrame(frame());
            if (sources.empty()) return 0;

            // Find the parent source group
            let srcGroup = nodeGroup(sources.front());
            let groupMembers = nodesInGroup(srcGroup);

            // Find RVLinearizePipelineGroup
            string linPipeline = nil;
            for_each (n; groupMembers)
                if (nodeType(n) == "RVLinearizePipelineGroup") { linPipeline = n; break; }

            if (linPipeline eq nil) return 0;

            // Find OCIOFile node inside
            let pipeMembers = nodesInGroup(linPipeline);
            string ocioNode = nil;
            for_each (n; pipeMembers)
                if (nodeType(n) == "OCIOFile") { ocioNode = n; break; }

            if (ocioNode eq nil) return 0;

            // Check if OCIO is active
            int active = 0;
            try { active = getIntProperty(ocioNode + ".ocio.active").front(); }
            catch (...) { ; }
            if (active == 0) return 0;

            // Read the input colorspace name and lowercase it
            string cs = getStringProperty(ocioNode + ".ocio.inColorSpace").front();
            string lcs = "";
            for (int i = 0; i < cs.size(); i++)
            {
                byte ch = cs[i];
                if (ch >= 'A' && ch <= 'Z') lcs += (ch + ('a' - 'A'));
                else lcs += ch;
            }

            // Pattern match for PQ / ST.2084
            if (string.contains(lcs, "pq") >= 0
                || string.contains(lcs, "st2084") >= 0
                || string.contains(lcs, "st.2084") >= 0
                || string.contains(lcs, "st-2084") >= 0
                || string.contains(lcs, "st_2084") >= 0
                || string.contains(lcs, "smpte2084") >= 0
                || string.contains(lcs, "perceptual quantizer") >= 0)
                return 2;

            // Pattern match for HLG / BT.2100
            if (string.contains(lcs, "hlg") >= 0
                || string.contains(lcs, "hybrid log gamma") >= 0
                || string.contains(lcs, "bt2100") >= 0
                || string.contains(lcs, "bt.2100") >= 0
                || string.contains(lcs, "bt-2100") >= 0
                || string.contains(lcs, "bt_2100") >= 0)
                return 3;

            // Pattern match for scene-linear
            if (string.contains(lcs, "scene linear") >= 0
                || string.contains(lcs, "scene_linear") >= 0
                || string.contains(lcs, "scene-linear") >= 0
                || string.contains(lcs, "scenelinear") >= 0
                || string.contains(lcs, "linear scene") >= 0
                || string.contains(lcs, "acescg") >= 0
                || string.contains(lcs, "aces2065") >= 0
                || string.contains(lcs, "lin_") >= 0)
                return 1;

            return 0;
        }
        catch (...)
        {
            return 0;
        }
    }

    method: currentSignalType (int;)
    {
        // If auto-detect is on, re-resolve and push to the property
        // so the C++ GPU shader stays in sync.
        int autoMode = 0;
        try { autoMode = getIntProperty("#RVScopeViewable.node.signalAutoDetect").front(); }
        catch (...) { ; }

        if (autoMode == 1)
        {
            int detected = detectSignalTypeFromOCIO();
            int stored = 0;
            try { stored = getIntProperty("#RVScopeViewable.node.signalType").front(); }
            catch (...) { ; }
            if (stored != detected)
            {
                try { set("#RVScopeViewable.node.signalType", detected); }
                catch (...) { ; }
            }
            return detected;
        }

        int stored = 0;
        try { stored = getIntProperty("#RVScopeViewable.node.signalType").front(); }
        catch (...) { ; }
        return stored;
    }

    method: drawRefLinesHorizontal (void; Point a, Point b, Point d, int sig, int fontSize)
    {
        // Draw user reference lines as horizontal cyan lines across the scope.
        // For histogram: a=BL, b=BR, d=TL — value axis is horizontal (b-a)
        // For waveform:  a=BL, b=BR, d=TL — value axis is vertical (d-a)
        // This function draws horizontal lines (waveform orientation).
        let vals = getRefLineValues(sig);
        let labs = getRefLineLabels(sig);
        let right = b - a;
        let up = d - a;

        for (int i = 0; i < vals.size(); i++)
        {
            float t = vals[i];
            if (t < 0.0 || t > 1.0) continue;

            let left_pt = a + t * up;
            let right_pt = left_pt + right;

            // Cyan line, slightly transparent
            glColor(Color(0.2, 0.85, 0.85, 0.75));
            glLineWidth(1.5);
            glBegin(GL_LINES);
            glVertex(left_pt);
            glVertex(right_pt);
            glEnd();

            // Label on the right side
            if (i < labs.size() && labs[i] != "")
            {
                gltext.size(fontSize);
                gltext.color(0.2, 0.85, 0.85, 0.85);
                let tb = gltext.bounds(labs[i]);
                float tw = tb[2];
                float th = tb[3];
                gltext.writeAt(right_pt.x - tw - 3.0, left_pt.y - th - 1.0, labs[i]);
            }
        }
    }

    method: drawRefLinesVertical (void; Point a, Point b, Point d, int sig, int fontSize)
    {
        // Draw user reference lines as vertical lines across the scope (histogram orientation).
        // Value axis is horizontal (b-a).
        let vals = getRefLineValues(sig);
        let labs = getRefLineLabels(sig);
        let up = d - a;

        for (int i = 0; i < vals.size(); i++)
        {
            float t = vals[i];
            if (t < 0.0 || t > 1.0) continue;

            let bot = a + t * (b - a);
            let top = bot + up;

            // Cyan line, slightly transparent
            glColor(Color(0.2, 0.85, 0.85, 0.75));
            glLineWidth(1.5);
            glBegin(GL_LINES);
            glVertex(bot);
            glVertex(top);
            glEnd();

            // Label at the top
            if (i < labs.size() && labs[i] != "")
            {
                gltext.size(fontSize);
                gltext.color(0.2, 0.85, 0.85, 0.85);
                let tb = gltext.bounds(labs[i]);
                float tw = tb[2];
                float th = tb[3];
                gltext.writeAt(bot.x - tw / 2.0, top.y - th - 2.0, labs[i]);
            }
        }
    }

    method: drawHistogramGrid (void; Point[] corners)
    {
        let a = corners[0], b = corners[1], d = corners[3];
        let up = d - a;
        int sig = currentSignalType();

        // Vertical grid lines from scale model
        glColor(Color(0.35, 0.35, 0.20, 0.7));
        glLineWidth(2.0);

        let gridT = scaleGridTicks(sig);
        for_each (t; gridT)
        {
            let bot = a + t * (b - a);
            let top = bot + up;
            glBegin(GL_LINES);
            glVertex(bot);
            glVertex(top);
            glEnd();
        }

        // Labels along the bottom-inside edge from scale model
        float scopeW = mag(b - a);
        int fontSize = int(scopeW / 25.0);
        if (fontSize < 10) fontSize = 10;
        if (fontSize > 20) fontSize = 20;
        gltext.size(fontSize);
        gltext.color(0.55, 0.55, 0.40, 0.85);

        let labelT = scaleTicks(sig);
        let labelS = scaleLabels(sig);
        int nLabels = labelT.size();
        if (labelS.size() < nLabels) nLabels = labelS.size();
        for (int i = 0; i < nLabels; i++)
        {
            let pos = a + labelT[i] * (b - a);
            let tb = gltext.bounds(labelS[i]);
            float tw = tb[2];
            float th = tb[3];
            if (i == 0)
                gltext.writeAt(pos.x - tw / 2.0, pos.y + 3.0, labelS[i]);
            else
                gltext.writeAt(pos.x - tw / 2.0, pos.y - th - 1.0, labelS[i]);
        }

        // Signal name in CAPS at bottom centre (larger, faux-bold)
        int nameFontSize = fontSize + 4;
        if (nameFontSize > 24) nameFontSize = 24;
        gltext.size(nameFontSize);
        string sName = signalName(sig);
        let bnds = gltext.bounds(sName);
        float nameW = bnds[2];
        float midX = (a.x + b.x) / 2.0;
        float nameX = midX - nameW / 2.0;
        float nameY = a.y + 3.0;
        gltext.writeAt(nameX + 0.5, nameY, sName);
        gltext.writeAt(nameX, nameY, sName);

        // Unit label at bottom left, offset past the first scale label
        gltext.size(fontSize);
        string sUnit = signalUnit(sig);
        float firstLabelW = 0.0;
        if (nLabels > 0) { let fb = gltext.bounds(labelS[0]); firstLabelW = fb[2]; }
        float unitX = a.x + labelT[0] * (b.x - a.x) - firstLabelW / 2.0 + firstLabelW + 6.0;
        gltext.writeAt(unitX, a.y + 3.0, sUnit);

        // User reference lines (vertical for histogram — value axis is horizontal)
        drawRefLinesVertical(a, b, d, sig, fontSize);
    }

    method: drawWaveformGrid (void; Point[] corners)
    {
        let a = corners[0], b = corners[1], d = corners[3];
        let right = b - a;
        int sig = currentSignalType();

        // Horizontal grid lines from scale model
        glColor(Color(0.35, 0.35, 0.20, 0.7));
        glLineWidth(2.0);

        let gridT = scaleGridTicks(sig);
        for_each (t; gridT)
        {
            let left  = a + t * (d - a);
            let right_pt = left + right;
            glBegin(GL_LINES);
            glVertex(left);
            glVertex(right_pt);
            glEnd();
        }

        // Labels along the left-inside edge from scale model
        float scopeH = mag(d - a);
        int fontSize = int(scopeH / 25.0);
        if (fontSize < 10) fontSize = 10;
        if (fontSize > 20) fontSize = 20;
        gltext.size(fontSize);
        gltext.color(0.55, 0.55, 0.40, 0.85);

        let labelT = scaleTicks(sig);
        let labelS = scaleLabels(sig);
        int nLabels = labelT.size();
        if (labelS.size() < nLabels) nLabels = labelS.size();
        for (int i = 0; i < nLabels; i++)
        {
            let pos = a + labelT[i] * (d - a);
            let tb = gltext.bounds(labelS[i]);
            float th = tb[3];
            if (i == 0)
                gltext.writeAt(pos.x + 3.0, pos.y + 3.0, labelS[i]);
            else
                gltext.writeAt(pos.x + 3.0, pos.y - th - 1.0, labelS[i]);
        }

        // Signal name in CAPS at bottom centre (larger, faux-bold)
        int nameFontSize = fontSize + 4;
        if (nameFontSize > 24) nameFontSize = 24;
        gltext.size(nameFontSize);
        string sName = signalName(sig);
        let bnds = gltext.bounds(sName);
        float nameW = bnds[2];
        float midX = (a.x + b.x) / 2.0;
        float nameX = midX - nameW / 2.0;
        float nameY = a.y + 3.0;
        gltext.writeAt(nameX + 0.5, nameY, sName);
        gltext.writeAt(nameX, nameY, sName);

        // Unit label at bottom left, offset past the widest scale label
        gltext.size(fontSize);
        string sUnit = signalUnit(sig);
        float maxLabelW = 0.0;
        for (int li = 0; li < nLabels; li++)
        {
            let lb = gltext.bounds(labelS[li]);
            if (lb[2] > maxLabelW) maxLabelW = lb[2];
        }
        float unitX = a.x + maxLabelW + 8.0;
        gltext.writeAt(unitX, a.y + 3.0, sUnit);

        // User reference lines (horizontal for waveform — value axis is vertical)
        drawRefLinesHorizontal(a, b, d, sig, fontSize);
    }

    method: drawVectorscopeGraticule (void; Point[] corners)
    {
        let a = corners[0], b = corners[1], d = corners[3];
        let right = b - a, up = d - a;
        float w = mag(right), h = mag(up);
        float aspect = w / h;

        // Compute the 1:1 square sub-region (pillarbox or letterbox)
        Point sqBL = a;
        Vec2  sqRight = right;
        Vec2  sqUp    = up;

        if (aspect > 1.0)
        {
            // Wide: pillarbox — center horizontally
            float margin = (1.0 - 1.0 / aspect) / 2.0;
            sqBL    = a + margin * right;
            sqRight = (1.0 - 2.0 * margin) * right;
        }
        else if (aspect < 1.0)
        {
            // Tall: letterbox — center vertically
            float margin = (1.0 - aspect) / 2.0;
            sqBL  = a + margin * up;
            sqUp  = (1.0 - 2.0 * margin) * up;
        }

        let center = sqBL + 0.5 * sqRight + 0.5 * sqUp;

        int segments = 48;

        // Outer circle (radius 0.5 — full range)
        glColor(Color(0.30, 0.30, 0.22, 0.75));
        glLineWidth(2.0);
        glBegin(GL_LINE_LOOP);
        for (int i = 0; i < segments; i++)
        {
            float angle = float(i) / float(segments) * 6.28318530718;
            let p = center + 0.5 * cos(angle) * sqRight + 0.5 * sin(angle) * sqUp;
            glVertex(p);
        }
        glEnd();

        // 75% circle (radius 0.375)
        glColor(Color(0.30, 0.30, 0.22, 0.6));
        glBegin(GL_LINE_LOOP);
        for (int i = 0; i < segments; i++)
        {
            float angle = float(i) / float(segments) * 6.28318530718;
            let p = center + 0.375 * cos(angle) * sqRight + 0.375 * sin(angle) * sqUp;
            glVertex(p);
        }
        glEnd();

        // Crosshair through center
        glColor(Color(0.30, 0.30, 0.22, 0.4));
        glBegin(GL_LINES);
        // Horizontal
        glVertex(sqBL + 0.5 * sqUp);
        glVertex(sqBL + sqRight + 0.5 * sqUp);
        // Vertical
        glVertex(sqBL + 0.5 * sqRight);
        glVertex(sqBL + 0.5 * sqRight + sqUp);
        glEnd();

        // Skin tone line from center outward
        // Direction: (-0.65, 0.76) in (Cb, Cr) space → (cx, cy) offset
        float skinDirX = -0.65;
        float skinDirY =  0.76;
        glColor(Color(0.6, 0.5, 0.3, 0.75));
        glBegin(GL_LINES);
        glVertex(center);
        let skinEnd = center + (skinDirX * 0.5) * sqRight + (skinDirY * 0.5) * sqUp;
        glVertex(skinEnd);
        glEnd();

        // 75% color bar targets (small squares)
        float[] targetCbCr = {
            0.373, 0.875,   // Red
            0.252, 0.186,   // Green
            0.875, 0.439,   // Blue
            0.627, 0.125,   // Cyan
            0.748, 0.814,   // Magenta
            0.125, 0.561    // Yellow
        };
        float[] targetR = {0.6, 0.2, 0.2, 0.2, 0.5, 0.5};
        float[] targetG = {0.2, 0.5, 0.2, 0.5, 0.2, 0.5};
        float[] targetB = {0.2, 0.2, 0.6, 0.5, 0.5, 0.2};

        float sqSize = mag(sqRight);
        float boxHalf = 4.0 / sqSize; // ~4 pixels in normalized coords

        for (int t = 0; t < 6; t++)
        {
            float cx = targetCbCr[t * 2];
            float cy = targetCbCr[t * 2 + 1];

            glColor(Color(targetR[t], targetG[t], targetB[t], 0.7));
            glLineWidth(1.0);
            glBegin(GL_LINE_LOOP);
            glVertex(sqBL + (cx - boxHalf) * sqRight + (cy - boxHalf) * sqUp);
            glVertex(sqBL + (cx + boxHalf) * sqRight + (cy - boxHalf) * sqUp);
            glVertex(sqBL + (cx + boxHalf) * sqRight + (cy + boxHalf) * sqUp);
            glVertex(sqBL + (cx - boxHalf) * sqRight + (cy + boxHalf) * sqUp);
            glEnd();
        }

        // Color name labels at target positions
        int fontSize = int(sqSize / 25.0);
        if (fontSize < 10) fontSize = 10;
        if (fontSize > 18) fontSize = 18;
        gltext.size(fontSize);

        string[] targetNames = {"R", "G", "B", "C", "M", "Y"};
        for (int t = 0; t < 6; t++)
        {
            float cx = targetCbCr[t * 2];
            float cy = targetCbCr[t * 2 + 1];
            let pos = sqBL + cx * sqRight + cy * sqUp;
            let tb = gltext.bounds(targetNames[t]);
            float tw = tb[2];
            float th = tb[3];
            gltext.color(targetR[t], targetG[t], targetB[t], 0.9);
            gltext.writeAt(pos.x + boxHalf * sqSize + 2.0, pos.y - th / 2.0, targetNames[t]);
        }
    }

    //
    // Always-on scope overlay: grid lines, labels, graticules.
    // Registered on state.config.renderViewSpace so it fires regardless
    // of which edit mode is active (layout, source, etc.).
    //
    method: renderScopeOverlay (void; Event event)
    {
        int scope = 0;
        try { scope = getIntProperty("#RVScopeViewable.node.scope").front(); }
        catch (...) { ; }

        if (scope == 0) return;

        let ac = scopeActiveCorners();
        if (ac.size() < 4) return;

        setupProjectionFromEvent(event);

        glEnable(GL_BLEND);
        glEnable(GL_LINE_SMOOTH);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        if (scope == 1 || scope == 2) drawHistogramGrid(ac);
        else if (scope == 3 || scope == 4) drawWaveformGrid(ac);
        else if (scope == 5) drawVectorscopeGraticule(ac);

        glDisable(GL_LINE_SMOOTH);
        glDisable(GL_BLEND);
    }

    //
    // Edit-mode render: manipulator handles only.
    // Only called when ScopeViewable is the active view (edit mode active).
    //
    method: render (void; Event event)
    {
        if (!isManualMode()) return;
        if (!_hovering && !_dragging) return;

        let corners = scopeSubCorners();
        if (corners.size() < 4) return;

        State state = data();
        let bg     = state.config.bg,
            fg     = state.config.fg,
            gc     = computeGC(corners);

        float outlineAlpha = if _hovering then 0.7 else 0.35;
        float handleAlpha  = if _hovering then 0.5 else 0.25;

        setupProjectionFromEvent(event);

        try
        {
            glEnable(GL_BLEND);
            glEnable(GL_LINE_SMOOTH);
            glEnable(GL_POINT_SMOOTH);

            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

            // Outline
            glColor(Color(1, 1, 1, outlineAlpha));
            glLineWidth(2.0);
            glBegin(GL_LINE_LOOP);
            for_each (c; corners) glVertex(c);
            glEnd();

            // Corner handles (thick L-shapes)
            \: drawCorners (void; Point[] crs, float mult, float width)
            {
                for_index (i; crs)
                {
                    let i0   = if i == 0 then 3 else i - 1,
                        i1   = (i + 1) % 4,
                        c    = crs[i],
                        c0   = crs[i0],
                        c1   = crs[i1],
                        m0   = mag(c0 - c),
                        m1   = mag(c1 - c),
                        dir0 = (c0 - c) / m0,
                        dir1 = (c1 - c) / m1,
                        nmult = if m1 / 2.0 < mult || m0 / 2.0 < mult
                                    then 0.0 else mult;

                    glBegin(GL_LINES);
                    glVertex(c + dir0 * nmult);
                    glVertex(c - normalize(dir0) * width);
                    glVertex(c + dir1 * nmult);
                    glVertex(c - normalize(dir1) * width);
                    glEnd();
                }
            }

            glColor(Color(0, 0, 0, handleAlpha));
            glLineWidth(8.0);
            drawCorners(corners, 25.0, 0.0);
            glLineWidth(6.0);
            glColor(Color(1, 1, 1, handleAlpha));
            drawCorners(corners, 25.0, 0.0);

            // Center translate icon
            glLineWidth(1.5);
            glPushMatrix();
            glTranslate(gc.x, gc.y, 0.0);
            glScale(25.0, 25.0, 25.0);
            glColor(bg * Color(1, 1, 1, handleAlpha));
            circleGlyph(false);
            circleGlyph(true);
            glPopMatrix();

            glPushMatrix();
            glTranslate(gc.x, gc.y, 0.0);
            glScale(25.0, 25.0, 25.0);
            glColor(fg * Color(1, 1, 1, outlineAlpha));
            translateIconGlyph(false);
            glColor(fg * Color(1, 1, 1, handleAlpha));
            glLineWidth(1.0);
            translateIconGlyph(true);
            glPopMatrix();

            glDisable(GL_BLEND);
        }
        catch (...) { ; }
    }

    method: ScopeViewableEditMode (ScopeViewableEditMode; string name)
    {
        init(name,
             [("session-manager-load-ui", loadUI, "Load UI into Session Manager"),
              ("graph-state-change", propertyChanged, "Maybe update session UI")],
             [("pointer--move", manipMove, "Scope manip hover"),
              ("pointer-1--push", manipPush, "Scope manip grab"),
              ("pointer-1--drag", manipDrag, "Scope manip drag"),
              ("pointer-1--release", manipRelease, "Scope manip release")],
             newMenu(MenuItem[] {
                 subMenu("Scope", MenuItem[] {
                     menuText("Scope Type"),
                     menuItem("   Off",               "", "viewmode_category", setScopeTypeEvent(,0), scopeState(0)),
                     menuItem("   Histogram",          "", "viewmode_category", setScopeTypeEvent(,1), scopeState(1)),
                     menuItem("   Histogram Parade",   "", "viewmode_category", setScopeTypeEvent(,2), scopeState(2)),
                     menuItem("   Waveform",           "", "viewmode_category", setScopeTypeEvent(,3), scopeState(3)),
                     menuItem("   Waveform Parade",    "", "viewmode_category", setScopeTypeEvent(,4), scopeState(4)),
                     menuItem("   Vectorscope",         "", "viewmode_category", setScopeTypeEvent(,5), scopeState(5)),
                     menuSeparator(),
                     menuText("Signal Type"),
                     menuItem("   Auto (detect)",      "", "signal_category", setSignalTypeEvent(,0), signalTypeState(0)),
                     menuItem("   Linear sRGB",        "", "signal_category", setSignalTypeEvent(,1), signalTypeState(1)),
                     menuItem("   Scene Linear",       "", "signal_category", setSignalTypeEvent(,2), signalTypeState(2)),
                     menuItem("   PQ (ST.2084)",       "", "signal_category", setSignalTypeEvent(,3), signalTypeState(3)),
                     menuItem("   HLG (BT.2100)",      "", "signal_category", setSignalTypeEvent(,4), signalTypeState(4))
                 })
             }),
             "zz");

        _control  = NoControl;
        _dragging = false;
        _hovering = false;
        _updatingUI = false;

        // Register always-on overlay rendering (works in any view mode)
        State state = data();
        state.config.renderViewSpace = renderScopeOverlay : state.config.renderViewSpace;
    }
}

\: createMode (Mode;)
{
    return ScopeViewableEditMode("ScopeViewable_edit_mode");
}
}
