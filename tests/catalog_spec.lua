local managerPath, zipPath, standalonePath, secondFamilyPath = ...
assert(managerPath and zipPath and standalonePath, "usage: lua catalog_spec.lua <manager> <zip> <ttf>")

function readfile(path)
    local file = assert(io.open(path, "rb"))
    local data = assert(file:read("a"))
    file:close()
    return data
end

function writefile(path, data)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    file:close()
end

function makefolder(path)
    os.execute(("mkdir -p %q"):format(path))
end

local function rendererFactory(config)
    local renderer = { DataLength = #config.Data }
    function renderer:Measure(text, size)
        return #text * size
    end
    function renderer:Clear() end
    function renderer:Destroy() end
    function renderer:Stats()
        return { DataLength = self.DataLength }
    end
    return renderer
end

local createFamily = assert(loadfile(managerPath))()
local fonts = createFamily({
    Renderer = rendererFactory,
    FontDir = "/tmp/rbxttf-test-cache",
    Sources = {
        { Path = zipPath },
        { Path = standalonePath },
    },
})

local families = fonts:Families()
assert(#families == 1, "expected one discovered family")
assert(families[1].Name == "Geist", "expected internal family name, got " .. tostring(families[1].Name))

local faces = fonts:Faces()
assert(#faces >= 9, "expected all ZIP weights to be discovered, got " .. #faces .. ": " .. table.concat(fonts:Errors(), " | "))
assert(fonts:ResolveFace(700).Weight == 700, "numeric weight did not resolve exactly")
assert(fonts:ResolveFace("SemiBold").Weight == 600, "named weight did not resolve")
assert(fonts:ResolveFace("Book").Weight == 300, "nearest-weight tie should prefer the lighter face below 500")
assert(fonts:ResolveFace(650).Weight == 700, "nearest-weight tie should prefer the heavier face above 500")

local bold = fonts:Get(700)
assert(bold.Family == "Geist" and bold.Weight == 700, "renderer metadata was not attached")
assert(bold.DataLength > 1000, "renderer did not receive raw TTF bytes")
assert(fonts:Measure("RBXTTF", 12, { Weight = 500 }) == 72, "manager did not delegate to the chosen renderer")

print(("catalog ok: %d faces across %d family"):format(#fonts:List(), #families))

if secondFamilyPath then
    local mixed = createFamily({
        Renderer = rendererFactory,
        FontDir = "/tmp/rbxttf-test-cache",
        Sources = {
            { Path = zipPath },
            { Path = secondFamilyPath },
        },
    })
    local mixedFamilies = mixed:Families()
    assert(#mixedFamilies >= 2, "expected a mixed archive and standalone font to retain separate families")

    local secondFamily
    for _, family in ipairs(mixedFamilies) do
        if family.Name ~= "Geist" then secondFamily = family.Name break end
    end
    assert(secondFamily, "second family metadata was not discovered")
    mixed:SetFamily(secondFamily)
    assert(mixed:GetFamily() == secondFamily, "SetFamily did not switch families")
    assert(#mixed:Faces() >= 1, "second family has no selectable faces")
    print("mixed family ok: " .. secondFamily)
end
