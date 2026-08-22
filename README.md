<div align="center">

# RBXTTF

**TrueType font loading and rendering for Roblox Luau.**

Load complete font families from ZIP archives or standalone font files without hardcoding internal filenames.

![Luau](https://img.shields.io/badge/Luau-23272f?style=flat-square&logo=lua&logoColor=7d78ff)
![Roblox](https://img.shields.io/badge/Roblox-23272f?style=flat-square&logo=roblox&logoColor=white)
![TrueType](https://img.shields.io/badge/TrueType-glyf-23272f?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-23272f?style=flat-square)

</div>

---

## What it does

- Loads standalone `.ttf` files and ZIP archives from URLs, files, or raw data.
- Finds font files anywhere inside an archive; filenames and folders do not matter.
- Reads family, subfamily, weight, italic, and oblique metadata from each font.
- Resolves numeric or named weights and falls back to the nearest available face.
- Supports retained text handles that move without rerasterizing their glyphs.
- Produces Drawing objects, GUI-friendly coverage runs, or transparent PNG data.

Mass-tested against 500 fonts from Google Fonts. All of them rendered perfectly. So I doubt you'll have issues.

## Load

```lua
local createFonts = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/jonathansigmund/RBXTTF/main/dist/RBXTTF.lua"
))()

local Fonts = createFonts({
    Sources = {
        "https://example.com/family.zip",
        "https://example.com/extra-face.ttf",
    },
})
```

## Render

```lua
local title = Fonts:CreateText("Hello, world", 18, 40, 40, {
    Weight = 600,
    Color = Color3.new(1, 1, 1),
})

title:MoveTo(80, 60)
title:SetAlpha(0.5)
title:Destroy()
```

`CreateText` retains its rendered Drawing objects. Moving the handle updates their positions instead of rebuilding the text.

## Select faces

```lua
Fonts:Get(475)
Fonts:Get("SemiBold")
Fonts:Get(700, { Italic = true })

Fonts:SetFamily("Inter")
local faces = Fonts:Faces()
```

If an exact weight or style is unavailable, RBXTTF selects the closest face.

## Sources

```lua
local Fonts = createFonts({
    Sources = {
        "https://example.com/family.zip",
        { Url = "https://example.com/font.ttf" },
        { Path = "fonts/font.ttf" },
        { Data = rawTtf },
        {
            Path = "unknown-name.ttf",
            Family = "My Font",
            Weight = 475,
            Italic = true,
        },
    },
    Family = "My Font",
})
```

Custom environments can provide `Fetch`, `ReadFile`, `WriteFile`, and `MakeFolder` adapters.

## API

```lua
Fonts:Measure(text, size, options)
Fonts:Draw(text, size, x, y, options)
Fonts:CreateText(text, size, x, y, options)
Fonts:RasterizeRuns(text, size, width, height, options)
Fonts:RasterizeText(text, size, width, height, options)
Fonts:Truncate(text, size, maxWidth, options, ellipsis)
```

See [`docs/API.md`](docs/API.md) for the complete API and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for implementation details.

## Font support

**Supported:** TrueType `glyf` outlines, simple and compound glyphs, `cmap` formats 4 and 12, legacy `kern`, GPOS pair positioning, stored ZIP entries, and DEFLATE ZIP entries.

**Not supported:** CFF/CFF2 outlines, WOFF/WOFF2, variable-axis interpolation, hinting, GSUB, or complex-script shaping.

## Repository

| Path | Purpose |
| --- | --- |
| `dist/RBXTTF.lua` | Bundled loadstring build |
| `src/RBXTTF.lua` | TrueType parser and renderer |
| `src/RBXTTFFamily.lua` | ZIP loading and face selection |
| `examples/` | Usage examples |
| `tests/` | Compatibility and regression tests |

## Testing

```bash
python3 tests/mass_test.py /path/to/fonts
python3 tests/mass_test.py --google 500
```

Each font runs in an isolated process with a timeout. Results are written to `tests/mass-results.json`.

## License

[MIT](LICENSE)

Competing with @runtimelul's font renderer because why not
