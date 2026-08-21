# RBXTTF

TTF rendering for Roblox Luau.

It reads standalone TTF files and ZIP archives.

## Load

```lua
local Fonts = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/JonathanSigmund/RBXTTF/main/dist/RBXTTF.lua"
))()({
    Sources = {
        "https://example.com/family.zip",
        "https://example.com/extra-face.ttf",
    },
})
```

## Use

```lua
local text = Fonts:CreateText("Hello", 18, 40, 40, {
    Weight = 600,
    Color = Color3.new(1, 1, 1),
})

text:MoveTo(80, 60)
text:SetAlpha(0.5)
text:Destroy()
```

Weights can be numeric or named. If the exact weight is missing, the closest face is used.

```lua
Fonts:Get(475)
Fonts:Get("SemiBold")
Fonts:Get(700, { Italic = true })
```

## Sources

```lua
Sources = {
    "https://example.com/family.zip",
    { Url = "https://example.com/font.ttf" },
    { Path = "fonts/font.ttf" },
    { Data = rawTtf },
    { Path = "odd-font.ttf", Family = "My Font", Weight = 475 },
}
```

Use `Family` when a ZIP contains multiple families.

```lua
local Fonts = createFonts({
    Sources = { "collection.zip" },
    Family = "Inter",
})
```

## Files

- `dist/RBXTTF.lua`: bundled version
- `src/RBXTTF.lua`: TTF parser and renderer
- `src/RBXTTFFamily.lua`: ZIP loader and family selection
- `docs/API.md`: API
- `docs/ARCHITECTURE.md`: internals

## Limits

Supported: TrueType `glyf` outlines, cmap 4/12, compound glyphs, legacy kern, GPOS pair positioning, stored ZIP entries, and DEFLATE ZIP entries.

Not supported: CFF/CFF2, WOFF/WOFF2, variable-axis interpolation, hinting, GSUB, or complex-script shaping.

## Test

```bash
python3 tests/mass_test.py /path/to/fonts
python3 tests/mass_test.py --google 500
```

Results are written to `tests/mass-results.json`. Each font runs in its own process with a timeout.

MIT license.
