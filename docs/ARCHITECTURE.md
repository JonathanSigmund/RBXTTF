# Architecture

## Source pipeline

`RBXTTFFamily` normalizes every configured source, detects ZIP or SFNT signatures, and caches remote bytes when filesystem functions are available. ZIP extraction is implemented in Lua and supports stored entries and DEFLATE blocks with fixed or dynamic Huffman trees.

Every `.ttf` or `.otf` entry is inspected. The loader reads:

- the `name` table for typographic family, subfamily, full name, and PostScript name
- `OS/2.usWeightClass` for numeric weight
- `OS/2.fsSelection` and `head.macStyle` for italic or oblique state

Fonts without `glyf` and `loca` are skipped because the renderer does not implement CFF outlines. A bad face does not prevent other faces in the same archive from loading.

## Face selection

Families are grouped by normalized internal family names. Requests are scored by family, slant, explicit style, and distance from the requested numeric weight. Equal distances prefer lighter faces at 500 and below, and heavier faces above 500.

Renderer instances are lazy. Inspecting families or faces parses metadata but does not build glyph caches.

## Font parser

`RBXTTF` reads the SFNT table directory and uses `head`, `maxp`, `hhea`, `hmtx`, `loca`, `glyf`, and `cmap`. It supports simple contours, compound components, transforms, implied on-curve points, and Unicode lookup through cmap formats 4 and 12.

Kerning comes from GPOS pair-positioning lookups when available, with legacy `kern` format 0 as fallback.

## Rasterizer

Quadratic contours are flattened into line segments. Glyphs are scan-converted at a configurable supersampling level and downsampled into coverage values. Adjacent coverage pixels are merged horizontally and vertically into reusable runs.

The renderer keeps bounded caches for glyph rasters, text layouts, coverage runs, and PNG bitmaps. Moving a retained text handle repositions cached runs without parsing or rasterizing glyphs again.

## Outputs

- `Draw` emits Drawing squares immediately.
- `CreateText` owns reusable Drawing squares and supports movement, clipping, recoloring, and updates.
- `RasterizeRuns` returns rectangular coverage runs suitable for GUI Frames or another compositor.
- `RasterizeText` encodes a transparent RGBA PNG in memory.

The parser and rasterizer do not depend on a specific UI library.
