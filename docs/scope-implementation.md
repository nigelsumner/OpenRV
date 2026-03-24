# Video Scopes for Open RV

GPU-accelerated histogram and waveform overlays for Open RV, inspired by DaVinci Resolve.

## Scope Modes

- **Histogram** — combined RGB overlay on a single panel
- **Histogram Parade** — stacked R, G, B panels
- **Waveform** — chromatic composite (binned by luminance, coloured by pixel RGB)
- **Waveform Parade** — side-by-side R, G, B with Resolve-style white-peaking at high density

Accessible via **View → Scopes** menu, with adjustable overlay opacity (25%–100%).

## How It Works

A single `ScopeIPNode` sits at the end of `RVColorPipelineGroup` (after `RVColor`), controlled by two properties:

- `node.scope` (int 0–4) — off / histogram / histogram parade / waveform / waveform parade
- `node.opacity` (float) — overlay transparency

**Data path:** OpenCL kernels bin the source image into a data texture (histogram: 256×1, waveform: sourceWidth×256) using local-memory atomics with soft binning. A GLSL merge shader then visualises the data as an overlay composited on top of the original image.

Three kernel variants per scope type (16k/32k/48k) adapt to the GPU's available local memory.

## Questions for the Community

1. **OpenCL dependency** — The bin accumulation uses OpenCL. Given Apple's deprecation, should we provide a Metal compute or GLSL compute shader alternative? Or a CPU fallback?
2. **Pipeline placement** — Scopes are in the colour pipeline (post colour-correction, pre display transform). Should they instead be in the display pipeline to show final display-referred values?
3. **Per-source vs global** — Each source gets its own scope. Should there be an option for a single scope on the final composited output?
4. **Waveform resolution** — Waveform data is sourceWidth × 256. For 4K+ sources, should we downsample the input first (as we do for histograms)?
5. **Additional scopes** — Vectorscope? False colour? Docked panel rendering vs overlay?
