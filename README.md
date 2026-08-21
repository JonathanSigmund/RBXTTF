# RBXTTF

RBXTTF parses and renders TrueType fonts in Luau. It accepts individual TTF files or whole ZIP archives and discovers families, weights, and styles from the fonts themselves.

The library started as the custom text renderer used by Atmosphere UI. It is now packaged independently for executor UIs, Roblox tooling, and any Luau environment that can provide raw font bytes.

## Features

- TrueType `glyf` outlines with simple and compound glyphs
- Unicode `cmap` formats 4 and 12
- Legacy `kern` and GPOS pair positioning
- Supersampled antialiasing and cached raster output
- Stored and DEFLATE-compressed ZIP archives
- Automatic family, weight, italic, and oblique discovery
- Arbitrary OpenType weights from 1 through 1000
- Mixed ZIP, URL, file, and raw-data sources
- Retained Drawing handles, GUI coverage runs, and transparent PNG output
- One-file loadstring build

## Quick Start

```lua
local Fonts = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/TwisstedToast/RBXTTF/main/dist/RBXTTF.lua"
))()({
    Sources = {
        "https://example.com/MyFontFamily.zip",
        "https://example.com/MyFontFamily-Italic.ttf",
    },
})

print(Fonts:GetFamily())

local title = Fonts:CreateText("Hello", 18, 40, 40, {
    Weight = 650,
    Color = Color3.fromRGB(255, 255, 255),
})

title:MoveTo(80, 60)
```

No archive path, filename prefix, or exact font filename is required. `650` selects the nearest discovered face.

## Selecting Families

Some archives contain more than one family. Set `Family`, or switch later:

```lua
local Fonts = loadstring(game:HttpGet(RBXTTF_URL))()({
    Sources = { "https://example.com/collection.zip" },
    Family = "Inter Display",
})

for _, family in ipairs(Fonts:Families()) do
    print(family.Name, family.Count)
end

Fonts:SetFamily("Inter")
```

When `Family` is omitted, RBXTTF chooses the family with the most discovered faces.

## Source Formats

```lua
Sources = {
    "https://example.com/family.zip",
    { Url = "https://example.com/standalone.ttf" },
    { Path = "fonts/local-face.ttf" },
    { Data = rawTtfBytes },

    -- Optional overrides for incomplete or unusual metadata.
    { Path = "custom.ttf", Family = "Custom", Weight = 475, Italic = true },
}
```

Use `Fetch`, `ReadFile`, `WriteFile`, and `MakeFolder` adapters outside executor environments. Raw `Data` sources do not need filesystem or HTTP functions.

## Files

- `dist/RBXTTF.lua` — bundled build for one loadstring
- `src/RBXTTF.lua` — one-face parser and renderer
- `src/RBXTTFFamily.lua` — ZIP loading, metadata discovery, and face selection
- `docs/API.md` — complete public API
- `docs/ARCHITECTURE.md` — parser, cache, and source pipeline
- `examples/` — Drawing and GUI-run examples

## Compatibility

RBXTTF supports TrueType-flavored fonts containing `glyf` and `loca` tables. CFF/CFF2 outlines, WOFF/WOFF2, variable-axis interpolation, hinting, GSUB substitutions, and complex-script shaping are not currently implemented.

## License

MIT
