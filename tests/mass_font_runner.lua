local rendererPath, familyPath, fontPath = ...
assert(rendererPath and familyPath and fontPath, "missing runner arguments")

function readfile(path)
    local file = assert(io.open(path, "rb"))
    local data = assert(file:read("a"))
    file:close()
    return data
end

math.clamp = math.clamp or function(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function bitPair(left, right, xor)
    left, right = left % 4294967296, right % 4294967296
    local value, place = 0, 1
    for _ = 1, 32 do
        local leftBit, rightBit = left % 2, right % 2
        if xor and leftBit ~= rightBit or not xor and leftBit == 1 and rightBit == 1 then
            value = value + place
        end
        left, right, place = math.floor(left / 2), math.floor(right / 2), place * 2
    end
    return value
end

bit32 = bit32 or {
    band = function(left, right) return bitPair(left, right, false) end,
    bxor = function(left, right) return bitPair(left, right, true) end,
    rshift = function(value, amount) return math.floor(value % 4294967296 / (2 ^ amount)) end,
}

local vectorMeta = {}
vectorMeta.__index = vectorMeta
vectorMeta.__add = function(left, right)
    return setmetatable({ X = left.X + right.X, Y = left.Y + right.Y }, vectorMeta)
end

Vector2 = {
    new = function(x, y) return setmetatable({ X = x, Y = y }, vectorMeta) end,
}

Color3 = {
    new = function(r, g, b) return { R = r, G = g, B = b } end,
    fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end,
}

Drawing = {
    new = function(kind)
        assert(kind == "Square")
        local square = {}
        function square:Remove() self.Removed = true end
        return square
    end,
}

local function u16(data, offset)
    return (string.byte(data, offset + 1) or 0) * 256 + (string.byte(data, offset + 2) or 0)
end

local function u32(data, offset)
    return u16(data, offset) * 65536 + u16(data, offset + 2)
end

local function hasTable(data, wanted)
    if #data < 12 then return false end
    local count = u16(data, 4)
    for index = 0, count - 1 do
        local record = 12 + index * 16
        if string.sub(data, record + 1, record + 4) == wanted then return true end
    end
    return false
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validateRuns(raster)
    assert(raster.Width > 0 and raster.Height > 0)
    assert(finite(raster.TextWidth))
    for _, run in ipairs(raster.Runs) do
        assert(run.X >= 0 and run.Y >= 0, "negative run position")
        assert(run.Width > 0 and run.Height > 0, "empty run")
        assert(run.X + run.Width <= raster.Width, "run exceeds width")
        assert(run.Y + run.Height <= raster.Height, "run exceeds height")
        assert(run.Alpha > 0 and run.Alpha <= 1, "invalid coverage")
    end
end

local raw = readfile(fontPath)
if not hasTable(raw, "glyf") or not hasTable(raw, "loca") then
    print("SKIP\tunsupported outlines")
    os.exit(0)
end

local started = os.clock()
local ok, result = pcall(function()
    local createRenderer = assert(loadfile(rendererPath))()
    local createFamily = assert(loadfile(familyPath))()
    local Fonts = createFamily({
        Renderer = createRenderer,
        Sources = { { Data = raw, Name = fontPath } },
        Supersample = 2,
        MaxGlyphCacheEntries = 256,
        MaxLayoutCacheEntries = 64,
        MaxBitmapCacheEntries = 16,
        MaxRunCacheEntries = 32,
    })

    local faces = Fonts:List()
    assert(#faces == 1, "standalone file should produce one face")
    local face = faces[1]
    assert(face.Family and face.Family ~= "", "missing family")
    assert(face.Weight >= 1 and face.Weight <= 1000, "invalid weight")

    local Font = Fonts:Get(face.Weight, {
        Italic = face.Italic,
        Oblique = face.Oblique,
    })
    local metrics = Font:GetMetrics()
    assert(metrics.UnitsPerEm > 0, "invalid units per em")
    assert(metrics.NumGlyphs > 0, "font has no glyphs")
    assert(Font:HasGlyph("A") == (Font:GetGlyphIndex("A") ~= 0))

    local latin = "Hamburgefontsiv AVATAR 0123456789"
    local unicode = "Café Ångström Ω Ж 中 😀"
    for _, size in ipairs({ 9, 16, 32 }) do
        assert(finite(Font:Measure(latin, size)), "invalid Latin measurement")
        assert(finite(Font:Measure(unicode, size)), "invalid Unicode measurement")
    end

    local truncated, truncatedWidth = Font:Truncate(latin, 16, 120, {}, "...")
    assert(type(truncated) == "string" and truncatedWidth <= 120.001, "truncate exceeded its width")

    local raster = Font:RasterizeRuns(latin .. " " .. unicode, 16, 640, 48, {
        XAlign = "Center",
        VAlign = "Center",
    })
    validateRuns(raster)
    if raster.TextWidth == 0 and #raster.Runs == 0 then
        Fonts:Destroy()
        return { Skip = "no visible sample glyphs" }
    end
    assert(Font:RasterizeRuns(latin .. " " .. unicode, 16, 640, 48, {
        XAlign = "Center",
        VAlign = "Center",
    }) == raster, "run cache miss for identical input")

    local bitmap = Font:RasterizeText("Ag AV", 18, 160, 40, { Padding = 2 })
    assert(string.sub(bitmap.Data, 1, 8) == "\137PNG\13\10\26\10", "bad PNG signature")
    assert(bitmap.Width == 164 and bitmap.Height == 44, "bad PNG dimensions")

    local handle = Font:CreateText("Move", 16, 10, 10, { Color = Color3.new(1, 1, 1) })
    handle:MoveTo(20, 30)
    handle:Translate(4, -2)
    handle:SetClipRect(0, 0, 200, 80)
    handle:SetColor(Color3.fromRGB(200, 210, 220))
    handle:SetAlpha(0.5)
    handle:SetVisible(false)
    handle:SetVisible(true)
    handle:Update("Moved", 16, 24, 28, { Color = Color3.new(1, 1, 1) })
    handle:Destroy()

    local stats = Font:Stats()
    assert(stats.GlyphsRasterized > 0, "nothing was rasterized")
    Fonts:Destroy()

    return {
        Family = face.Family,
        FullName = face.FullName,
        Weight = face.Weight,
        Style = face.Style,
        Glyphs = metrics.NumGlyphs,
    }
end)

if not ok then
    io.stderr:write(tostring(result), "\n")
    print("FAIL\t" .. tostring(result):gsub("[\r\n\t]", " "))
    os.exit(1)
end

if result.Skip then
    print("SKIP\t" .. result.Skip)
    os.exit(0)
end

print(table.concat({
    "PASS",
    tostring(result.Family),
    tostring(result.FullName),
    tostring(result.Weight),
    tostring(result.Style),
    tostring(result.Glyphs),
    string.format("%.4f", os.clock() - started),
}, "\t"))
