# API

## Creating a family collection

The bundled file returns a factory:

```lua
local createFonts = loadstring(game:HttpGet(RBXTTF_URL))()
local Fonts = createFonts({ Sources = { FONT_ZIP_URL } })
```

### Family options

| Option | Default | Purpose |
| --- | --- | --- |
| `Sources` | required | ZIP and TTF descriptors, URLs, paths, or raw strings |
| `Family` | largest family | Initial family name |
| `DefaultWeight` | `400` | Weight used when none is supplied |
| `FontDir` | `fonts` | Where downloaded and extracted fonts are cached |
| `Include` | `nil` | Only scan matching files inside a ZIP |
| `Exclude` | `nil` | Skip matching files inside a ZIP |
| `Supersample` | `4` | Raster supersampling level |
| `CurveSteps` | `6` | Minimum quadratic-curve subdivision |
| `Kerning` | `true` | Set to `false` to disable kerning |
| `ScaleQuantization` | automatic | Glyph scale cache quantization |
| `MaxGlyphCacheEntries` | `4096` | Glyph cache limit |
| `MaxLayoutCacheEntries` | `2048` | Layout cache limit |
| `MaxBitmapCacheEntries` | `512` | PNG cache limit |
| `MaxRunCacheEntries` | `1024` | Coverage-run cache limit |

`Source`, `ZipUrl`, and `ZipPath` are accepted as shortcuts.

Most executors work without any extra setup. If yours uses different names for HTTP or file functions, you can pass `Fetch`, `ReadFile`, `WriteFile`, and `MakeFolder` yourself.

## Family methods

### `Fonts:Families()`

Returns sorted `{ Name, Count }` records.

### `Fonts:Faces(family?)`

Returns the discovered faces for a family. Each record contains `Family`, `Subfamily`, `FullName`, `PostScriptName`, `Weight`, `Style`, `Italic`, `Oblique`, `Source`, and `Entry`.

### `Fonts:List()`

Returns every discovered face from every source.

### `Fonts:GetFamily()` / `Fonts:SetFamily(name)`

Reads or changes the active family.

### `Fonts:ResolveFace(weight?, options?)`

Returns metadata for the face that would be selected without constructing its renderer.

### `Fonts:Get(weight?, options?)`

Returns a lazily created renderer for the nearest matching face. Weight may be numeric or named: `Book`, `DemiBold`, `Heavy`, `650`, and other common forms are supported.

```lua
local face = Fonts:Get(575, { Italic = true })
local otherFamily = Fonts:Get(400, { Family = "Inter Display" })
```

### Rendering shortcuts

These methods select a face and forward to it:

- `Fonts:Measure(text, size, options?)`
- `Fonts:Draw(text, size, x, y, options?)`
- `Fonts:CreateText(text, size, x, y, options?)`
- `Fonts:RasterizeRuns(text, size, width, height, options?)`
- `Fonts:RasterizeText(text, size, width, height, options?)`
- `Fonts:Truncate(text, size, maxWidth, options?, ellipsis?)`

Face selection uses `Weight`, `Italic`, `Oblique`, `Style`, and `Family`. Remaining options are forwarded to the renderer.

### Lifecycle and diagnostics

- `Fonts:Errors()` returns skipped archive-entry and source errors.
- `Fonts:Stats()` returns cache statistics for loaded faces.
- `Fonts:Clear()` destroys active drawing handles while preserving caches.
- `Fonts:Destroy()` destroys all loaded face renderers.

## One-face renderer

Use `src/RBXTTF.lua` directly when family discovery is unnecessary:

```lua
local createRenderer = loadstring(readfile("RBXTTF.lua"))()
local Font = createRenderer({ Source = "font.ttf" })
```

Sources may use `Data`, `Path`, `Url`, or `Source`. `Fetch` and `ReadFile` adapters are also accepted.

### Renderer methods

- `Font:Measure(text, size, options?) -> width`
- `Font:Truncate(text, size, maxWidth, options?, ellipsis?) -> text, width`
- `Font:Draw(text, size, x, y, options?)`
- `Font:CreateText(text, size, x, y, options?) -> TextHandle`
- `Font:RasterizeRuns(text, size, width, height, options?) -> raster`
- `Font:RasterizeText(text, size, width, height, options?) -> bitmap`
- `Font:GetGlyphIndex(codepointOrCharacter) -> glyphId`
- `Font:HasGlyph(codepointOrCharacter) -> boolean`
- `Font:GetMetrics() -> metrics`
- `Font:Stats() -> stats`
- `Font:Clear()`, `Font:ClearCache()`, `Font:Destroy()`

### Text options

| Option | Purpose |
| --- | --- |
| `Color` | Drawing output color |
| `Alpha` | Drawing output opacity |
| `LetterSpacing` | Additional pixel spacing between glyphs |
| `XAlign` | `Left`, `Center`, or `Right` for raster output |
| `VAlign` | `Top`, `Center`, `Bottom`, or baseline behavior |
| `BoxHeight` | Drawing alignment box height |
| `Padding` | PNG padding |
| `Embolden` | Optional synthetic outline expansion |

### Text handles

- `handle:Update(text, size, x, y, options?)`
- `handle:MoveTo(x, y)`
- `handle:Translate(dx, dy)`
- `handle:SetColor(color)`
- `handle:SetAlpha(alpha)`
- `handle:SetVisible(visible)`
- `handle:SetClipRect(minX, minY, maxX, maxY)`
- `handle:GetDraws()`
- `handle:Destroy()`
