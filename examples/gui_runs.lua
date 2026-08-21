local function mountRuns(parent, raster, color)
    local root = Instance.new("Frame")
    root.Name = "RBXTTFText"
    root.BackgroundTransparency = 1
    root.Size = UDim2.fromOffset(raster.Width, raster.Height)
    root.ClipsDescendants = true
    root.Parent = parent

    for _, run in ipairs(raster.Runs) do
        local pixel = Instance.new("Frame")
        pixel.BorderSizePixel = 0
        pixel.BackgroundColor3 = color
        pixel.BackgroundTransparency = 1 - run.Alpha
        pixel.Position = UDim2.fromOffset(run.X, run.Y)
        pixel.Size = UDim2.fromOffset(run.Width, run.Height)
        pixel.Parent = root
    end

    return root
end

local Fonts = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/TwisstedToast/RBXTTF/main/dist/RBXTTF.lua"
))()({
    Sources = { "https://example.com/family.zip" },
})

local raster = Fonts:RasterizeRuns("Custom TTF", 16, 180, 24, {
    Weight = 600,
    XAlign = "Left",
    VAlign = "Center",
})

local textRoot = mountRuns(screenGui, raster, Color3.new(1, 1, 1))
textRoot.Position = UDim2.fromOffset(20, 20)
