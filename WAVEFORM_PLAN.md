# Chromatic Waveform Implementation Plan

## Overview

Implement a DaVinci Resolve-style **chromatic waveform monitor** in OpenRV, following
the same architecture as the existing histogram feature. The waveform displays luminance
(or per-channel intensity) on the Y-axis against horizontal pixel position on the X-axis,
with each pixel's contribution tinted by its original colour.

### Histogram vs Waveform — Key Differences

| Aspect | Histogram | Waveform |
| --- | --- | --- |
| **X-axis** | Intensity bin (0–255) | Source pixel column |
| **Y-axis** | Count of pixels in that bin | Intensity value (0–100 IRE) |
| **Data shape** | 256 × 1 (bins × 1 row) | W × 256 (columns × intensity bins) |
| **OpenCL output** | 256-wide × 1-tall texture | Source-width × 256-tall texture |
| **Colour** | Per-channel parade (3 panels) | Each pixel contributes its own RGB colour (chromatic / additive) |
| **GLSL display** | Reads 1D bin data, draws 3 stacked bar panels | Reads 2D accumulation texture, applies tone-mapping / gain |

---

## Architecture

```
Source Image
     │
     ▼
┌────────────────┐
│  WaveformIPNode │  (IPNode subclass — mirrors HistogramIPNode)
│  evaluate()     │
└───────┬────────┘
        │  builds IPImage tree:
        │
        ├─► bgImage (second evaluate, clean source for composite)
        │
        ├─► scaled-down source → IntermediateBuffer
        │       │
        │       ▼
        │   DataBuffer (W × 256, FloatDataType)
        │       isWaveform = true
        │       │
        │       │  ◄── OpenCL kernel writes waveform accumulation
        │       ▼
        │   MergeRenderType result (outW × outH)
        │       mergeExpr = Shader::newWaveform(...)
        │       │
        │       ▼
        │   Apply Shader::newOpacity(opacity)
        │
        └─► composite (BlendRenderType, Over)
                children: [result, bg]
```

---

## Files to Create

### 1. `src/lib/ip/IPCore/cl/Waveform48k.cl` (+ 32k, 16k variants)

**OpenCL kernel — the core computation.**

Unlike the histogram (which bins by intensity, losing spatial info), the waveform kernel must:

- For each source pixel at column `x` with intensity `v` (per channel or luma):
  - Map `v` to a Y-bin (0–255)
  - Atomically accumulate the pixel's **actual RGB colour** into `output[x][y_bin]`
- Output texture: `sourceWidth × 256` (or configurable height), float4 RGBA
- Two-pass: per-workgroup sub-waveforms → merge (same pattern as histogram)

**Kernel signature sketch:**

```c
__kernel void waveform256_float4(
    read_only image2d_t image,       // source
    __global float4* waveform,       // per-workgroup partial results
    uint noRowsPerWorkItem,
    uint imageWidth,
    uint imageHeight)
```

**Key difference from histogram:** The output is 2D (`width × 256`) not 1D (`256 × 1`).
Each bin accumulates RGB colour values, not just counts. This means:

- Atomic float adds (`atom_add` on int-encoded floats, or use `atomic_add` on uint
  with float-to-uint reinterpretation) — or use local memory uint accumulators and
  normalize in the merge pass.
- The merge kernel writes to a 2D output texture.

**Variants** (16k, 32k, 48k) differ only in `NBANKS` / local memory sizing, same as histogram.

### 2. `src/lib/ip/IPCore/glsl/Waveform.glsl`

**Display shader — reads the 2D waveform texture and renders it.**

```glsl
vec4 Waveform(const in inputImage in0,    // waveform data texture (W × 256)
              const in outputImage win)    // output window
```

The shader:

- Maps normalized X to source column
- Maps normalized Y to intensity bin row
- Reads accumulated RGB colour from the waveform data texture
- Applies gain / tone-mapping (the raw accumulation can be very bright in dense areas)
- Draws horizontal grid lines at 10% IRE intervals (0, 10, 20, ... 100)
- Draws Y-axis labels area (optional — can be overlaid by Mu/UI)
- Black background with alpha 1.0 (for overlay compositing)

### 3. `src/lib/ip/IPCore/WaveformIPNode.cpp`

**Node implementation — mirrors HistogramIPNode.cpp.**

```cpp
class WaveformIPNode : public IPNode {
    IntProperty*   m_active;
    FloatProperty* m_opacity;
    FloatProperty* m_gain;      // brightness multiplier for dense images

    IPImage* evaluate(const Context& context) override;
};
```

`evaluate()` builds the same image tree as histogram:

1. First `IPNode::evaluate()` → source image for waveform computation
2. Second `IPNode::evaluate()` → clean background for compositing
3. Scale down source if large (max 300px as histogram does)
4. Create `DataBuffer` of size `sourceWidth × 256` with `setWaveform(true)`
5. Create `MergeRenderType` result with `Shader::newWaveform()` merge expression
6. Composite over background at configurable opacity

### 4. `src/lib/ip/IPCore/IPCore/WaveformIPNode.h`

**Header — mirrors HistogramIPNode.h.**

---

## Files to Modify

### 5. `src/lib/ip/IPCore/IPCore/IPImage.h`

Add waveform flag alongside histogram:

```cpp
bool isHistogram : 1;
bool isWaveform  : 1;   // ← NEW
```

Add setter:

```cpp
void setWaveform(bool w) { isWaveform = w; }
```

Ensure `isWaveform` is initialized to `false` in the constructor.

### 6. `src/lib/ip/IPCore/ImageRenderer.h`

Add declarations:

```cpp
void computeWaveform(const ConstFBOVector& childrenFBO, const GLFBO* resultFBO) const;
void waveformOCL(cl_mem& image, cl_mem& waveform, const size_t w, const size_t h) const;
void compileCLWaveform();
```

### 7. `src/lib/ip/IPCore/ImageRenderer.cpp`

Multiple additions mirroring the histogram code:

1. **Add `extern` declarations** for `Waveform48k_cl`, `Waveform32k_cl`, `Waveform16k_cl`
2. **`compileCLWaveform()`** — select kernel source based on local memory, compile program,
   create `waveform256_float4` and `mergeWaveform256_float4` kernels
3. **`waveformOCL()`** — dispatch the two CL kernels (scatter pass + merge pass)
4. **`computeWaveform()`** — acquire GL textures as CL objects, call `waveformOCL()`, release
5. **Render dispatch** — add `isWaveform` check next to the existing `isHistogram` check:

   ```cpp
   if (!baseContext.norender && root->isWaveform)
   {
       // ... same pattern as histogram
       computeWaveform(childrenFBO, fbo);
   }
   ```

### 8. `src/lib/ip/IPCore/IPCore/ShaderCommon.h`

Add declarations:

```cpp
Function* waveform();
Expression* newWaveform(const IPImage*, const std::vector<Expression*>&);
```

### 9. `src/lib/ip/IPCore/ShaderCommon.cpp`

Add implementations:

```cpp
extern const char* Waveform_glsl;

static Function* Shader_Waveform = 0;

Function* waveform() {
    if (!Shader_Waveform) {
        SymbolVector params, globals;
        params.push_back(in0());
        params.push_back(new Symbol(Symbol::ParameterConstIn, "win", Symbol::OutputImageType));
        Shader_Waveform = new Function("Waveform", Waveform_glsl,
                                        Function::Filter, params, globals);
    }
    return Shader_Waveform;
}

Expression* newWaveform(const IPImage* image, const std::vector<Expression*>& FA1) {
    // Same pattern as newHistogram
}
```

### 10. `src/lib/ip/IPCore/CMakeLists.txt`

Add to shader list:

```cmake
    Waveform
```

Add to CL kernel list:

```cmake
    Waveform48k Waveform32k Waveform16k
```

### 11. `src/lib/app/RvApp/RvNodeDefinitions.cpp`

Register the node definition:

```cpp
m->addDefinition(new NodeDefinition("RVWaveform", 1, false, "RVWaveform",
    newIPNode<WaveformIPNode>, "", "", emptyIcon, false));
```

Add to `RVColorPipelineGroup` defaults alongside `RVHistogram`:

```cpp
colorDefaults.push_back("RVWaveform");
```

### 12. `src/lib/app/mu_rvui/rvui.mu`

Add a "Waveform" menu item next to "Histogram":

```mu
menuItem("Histogram", "", "source_category", toggleNormalizeColor, isNormalizingColor),
menuItem("Waveform", "", "source_category", toggleWaveform, isWaveformActive),
```

This requires implementing `toggleWaveform` and `isWaveformActive` Mu functions
(toggle `#RVWaveform.node.active` property on/off).

### 13. `src/lib/ip/IPCore/IPImage.cpp` (constructor)

Ensure `isWaveform` is initialized to `false` alongside `isHistogram`.

---

## Implementation Order

### Phase 1 — Scaffolding (no GPU compute yet)

1. Create `WaveformIPNode.h` / `.cpp` with `evaluate()` that produces a solid-colour
   test image (verify node registration and pipeline plumbing)
2. Register `RVWaveform` in `RvNodeDefinitions.cpp`
3. Add to color pipeline defaults
4. Add menu item in `rvui.mu`
5. **Test:** Toggle waveform → see placeholder overlay

### Phase 2 — OpenCL Kernel

6. Create `Waveform48k.cl` (start with 48k only)
7. Add `isWaveform` flag to `IPImage.h`
8. Add `compileCLWaveform()`, `waveformOCL()`, `computeWaveform()` to ImageRenderer
9. Wire up the render dispatch (`isWaveform` check)
10. **Test:** Verify CL kernel produces correct accumulation data

### Phase 3 — GLSL Display Shader

11. Create `Waveform.glsl` with tone-mapping, grid lines, chromatic display
12. Register shader in `ShaderCommon.h/.cpp`
13. Add to CMakeLists.txt shader list
14. Wire `Shader::newWaveform()` into `WaveformIPNode::evaluate()`
15. **Test:** Full waveform rendering with chromatic colours

### Phase 4 — Polish

16. Add 16k/32k CL kernel variants
17. Tune gain/tone-mapping for various content
18. Add `m_gain` property for user control
19. Horizontal grid lines at 10% IRE intervals
20. Performance profiling (waveform data texture is much larger than histogram)

---

## Key Technical Challenges

### 1. OpenCL 2D Output

The histogram outputs a tiny 256×1 texture. The waveform outputs a `sourceWidth × 256`
texture — potentially thousands of pixels wide. This changes:

- **Memory:** Sub-waveform buffers are `width × 256 × 3 channels × sizeof(uint)` per workgroup
- **Atomics:** Still need atomic increments but now indexed by `(column, intensity_bin)`
- **Merge kernel:** Must iterate over all `width × 256` bins, not just 256

**Mitigation:** Downsample the source before computing (as histogram already does with
`max(width/300, height/300)` scale factor). A 300px-wide source → 300×256 waveform texture
is very manageable.

### 2. Chromatic Accumulation

Unlike histogram (which counts pixels per bin), chromatic waveform accumulates actual RGB
values. Options:

- **Option A:** Accumulate RGB as float4 (requires atomic float operations — not available
  in OpenCL 1.x). Use int-reinterpretation trick or local memory.
- **Option B:** Accumulate counts per channel separately (like histogram), then tint in
  the display shader. Loses true chromatic mixing but much simpler.
- **Option C:** Use `atomic_add` on uint-encoded fixed-point values in local memory, then
  convert to float in merge pass. Best balance of correctness and compatibility.

**Recommendation:** Start with Option B (per-channel counts tinted in shader) as it reuses
the histogram kernel pattern almost directly. Upgrade to true chromatic (Option C) later.

### 3. Performance

The data texture is ~300× larger than histogram. But the CL compute is similar complexity.
The main cost is the merge pass and the texture upload. Profile before optimizing.

### 4. Platform Support

Like histogram, this is macOS-only due to CGL↔OpenCL interop (`PLATFORM_DARWIN` guards
in ImageRenderer.cpp). Future work could add Metal compute or CPU fallback.

---

## File Summary

| File | Action | Effort |
| --- | --- | --- |
| `WaveformIPNode.h` | **Create** | Small |
| `WaveformIPNode.cpp` | **Create** | Medium |
| `Waveform.glsl` | **Create** | Medium |
| `Waveform48k.cl` | **Create** | Large — core algorithm |
| `Waveform32k.cl` | **Create** | Small (variant of 48k) |
| `Waveform16k.cl` | **Create** | Small (variant of 48k) |
| `IPImage.h` | **Modify** — add `isWaveform` flag | Small |
| `IPImage.cpp` | **Modify** — init `isWaveform` | Small |
| `ImageRenderer.h` | **Modify** — add declarations | Small |
| `ImageRenderer.cpp` | **Modify** — add CL compile/dispatch | Large |
| `ShaderCommon.h` | **Modify** — add `newWaveform` decl | Small |
| `ShaderCommon.cpp` | **Modify** — add shader registration | Small |
| `CMakeLists.txt` (IPCore) | **Modify** — add to build lists | Small |
| `RvNodeDefinitions.cpp` | **Modify** — register node | Small |
| `rvui.mu` | **Modify** — add menu item + toggle | Medium |
