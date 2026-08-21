local RBXTTF_URL = "https://raw.githubusercontent.com/TwisstedToast/RBXTTF/main/dist/RBXTTF.lua"

local Fonts = loadstring(game:HttpGet(RBXTTF_URL))()({
    Sources = {
        "https://example.com/complete-family.zip",
        { Url = "https://example.com/missing-italic.ttf" },
        { Path = "fonts/local-475.ttf", Weight = 475 },
    },
})

for _, family in ipairs(Fonts:Families()) do
    print(family.Name, family.Count)
end

for _, face in ipairs(Fonts:Faces()) do
    print(face.Weight, face.Style, face.Entry)
end

local text = Fonts:CreateText("RBXTTF", 18, 24, 24, {
    Weight = 550,
    Color = Color3.fromRGB(245, 245, 245),
})

text:MoveTo(80, 40)
