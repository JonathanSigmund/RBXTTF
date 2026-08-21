# API

## Setup

```lua
local Fonts = createFonts({
    Sources = { "family.zip", "face.ttf" },
    Family = "Optional family name",
    DefaultWeight = 400,
    Supersample = 4,
})
```

`Sources` accepts URLs, paths, raw font data, and descriptor tables.

Optional source fields:

- `Url`
- `Path`
- `Data`
- `Type`
- `Family`
- `Weight`
- `Italic`
- `Oblique`

Optional loader settings:

- `Family`
- `DefaultWeight`
- `FontDir`
- `Include`
- `Exclude`
- `Supersample`
- `CurveSteps`
- `Kerning`
- `ScaleQuantization`
- `MaxGlyphCacheEntries`
- `MaxLayoutCacheEntries`
- `MaxBitmapCacheEntries`
- `MaxRunCacheEntries`

Custom environments can provide `Fetch`, `ReadFile`, `WriteFile`, and `MakeFolder`.

## Families

```lua
Fonts:Families()
Fonts:Faces(family)
Fonts:List()
Fonts:GetFamily()
Fonts:SetFamily(name)
Fonts:ResolveFace(weight, options)
Fonts:Get(weight, options)
```

`Families()` returns `{ Name, Count }` entries.

`Faces()`, `List()`, and `ResolveFace()` return:

```lua
{
    Family = "Geist",
    Subfamily = "SemiBold",
    FullName = "Geist SemiBold",
    PostScriptName = "Geist-SemiBold",
    Weight = 600,
    Style = "Normal",
    Italic = false,
    Oblique = false,
    Source = "family.zip",
    Entry = "any/path/font.ttf",
}
```

## Rendering

```lua
Fonts:Measure(text, size, options)
Fonts:Draw(text, size, x, y, options)
Fonts:CreateText(text, size, x, y, options)
Fonts:RasterizeRuns(text, size, width, height, options)
Fonts:RasterizeText(text, size, width, height, options)
Fonts:Truncate(text, size, maxWidth, options, ellipsis)
```

Face options:

- `Weight`
- `Family`
- `Style`
- `Italic`
- `Oblique`

Render options:

- `Color`
- `Alpha`
- `LetterSpacing`
- `XAlign`
- `VAlign`
- `BoxHeight`
- `Padding`
- `Embolden`

## Text handles

```lua
handle:Update(text, size, x, y, options)
handle:MoveTo(x, y)
handle:Translate(dx, dy)
handle:SetColor(color)
handle:SetAlpha(alpha)
handle:SetVisible(visible)
handle:SetClipRect(minX, minY, maxX, maxY)
handle:GetDraws()
handle:Destroy()
```

## Direct renderer

```lua
local createRenderer = loadstring(readfile("RBXTTF.lua"))()
local Font = createRenderer({ Source = "font.ttf" })
```

```lua
Font:Measure(text, size, options)
Font:Truncate(text, size, maxWidth, options, ellipsis)
Font:Draw(text, size, x, y, options)
Font:CreateText(text, size, x, y, options)
Font:RasterizeRuns(text, size, width, height, options)
Font:RasterizeText(text, size, width, height, options)
Font:GetGlyphIndex(codepointOrCharacter)
Font:HasGlyph(codepointOrCharacter)
Font:GetMetrics()
Font:Stats()
Font:Clear()
Font:ClearCache()
Font:Destroy()
```

## Cleanup

```lua
Fonts:Errors()
Fonts:Stats()
Fonts:Clear()
Fonts:Destroy()
```
