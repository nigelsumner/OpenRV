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

class: ScopeViewableEditMode : MinorMode
{
    QWidget   _ui;
    QComboBox _scopeTypeCombo;
    QComboBox _positionCombo;
    QSlider   _opacitySlider;
    QLineEdit _opacityLineEdit;

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
        set("#RVScopeViewable.node.position", index);
        redraw();
    }

    method: setScopeTypeEvent (void; Event event, int index)
    {
        setScopeType(index);
    }

    method: setOpacityFromSlider (void; int value)
    {
        float opacity = float(value) / 100.0;
        _opacityLineEdit.setText("%g" % opacity);
        set("#RVScopeViewable.node.opacity", opacity);
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
            float opacity = getFloatProperty("#RVScopeViewable.node.opacity").front();
            _opacityLineEdit.setText("%g" % opacity);
            _opacitySlider.setValue(int(opacity * 100.0));
        }
        catch (...)
        {
            _opacityLineEdit.setText("0.75");
            _opacitySlider.setValue(75);
        }
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
                _opacitySlider   = _ui.findChild("opacitySlider");
                _opacityLineEdit = _ui.findChild("opacityLineEdit");

                manager.addEditor("Scope", _ui);
                connect(_scopeTypeCombo, QComboBox.currentIndexChanged, setScopeType);
                connect(_positionCombo, QComboBox.currentIndexChanged, setPosition);
                connect(_opacitySlider, QSlider.valueChanged, setOpacityFromSlider);
                connect(_opacityLineEdit, QLineEdit.editingFinished, setOpacityFromText);
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
        for_each (i; renderedImages())
        {
            try
            {
                if (nodeType(i.node) == "RVScopeViewable") return i.index;
            }
            catch (...) { ; }
        }

        try
        {
            if (nodeType(viewNode()) == "RVScopeViewable") return 0;
        }
        catch (...) { ; }

        let ri = renderedImages();
        if (ri.size() > 0) return ri[0].index;

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
                     menuItem("   Waveform Parade",    "", "viewmode_category", setScopeTypeEvent(,4), scopeState(4))
                 })
             }),
             "zz");

        _control  = NoControl;
        _dragging = false;
        _hovering = false;
    }
}

\: createMode (Mode;)
{
    return ScopeViewableEditMode("ScopeViewable_edit_mode");
}
}
