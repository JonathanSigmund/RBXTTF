# Architecture

## Loading

`RBXTTFFamily.lua` accepts TTF and ZIP sources.

ZIP support is implemented in Lua. Stored and DEFLATE entries are supported.

Each font is identified using:

- `name`: family, subfamily, full name, PostScript name
- `OS/2.usWeightClass`: numeric weight
- `OS/2.fsSelection`: italic and oblique flags
- `head.macStyle`: italic fallback

Archive paths and filenames do not affect face selection.

## Parsing

`RBXTTF.lua` reads:

- `head`
- `maxp`
- `hhea`
- `hmtx`
- `loca`
- `glyf`
- `cmap`
- `kern`
- `GPOS`

Cmap formats 4 and 12 are supported. Glyphs may be simple or compound.

## Rendering

Quadratic curves are flattened into line segments. Glyphs are scan-converted at the configured supersampling level and reduced to coverage runs.

Caches exist for glyphs, layouts, runs, and PNG output.

`CreateText` retains its Drawing squares. Moving it does not rerasterize the text.

Outputs:

- `Draw`: Drawing squares
- `CreateText`: retained Drawing handle
- `RasterizeRuns`: GUI-friendly coverage rectangles
- `RasterizeText`: transparent PNG bytes
