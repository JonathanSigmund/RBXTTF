return function(config)
    config = config or {}
    local fontDir = config.FontDir or "fonts"
    local zipCacheFile = config.ZipCacheFile or "rbxttf-source.dat"
    local libraryPath = config.LibraryPath or "RBXTTF.lua"
    local readSource = config.ReadFile or readfile
    local writeCache = config.WriteFile or writefile
    local createFolder = config.MakeFolder or makefolder

    local rendererLoader = config.Renderer
    if type(rendererLoader) == "string" then
        rendererLoader = assert(loadstring(rendererLoader), "RBXTTFFamily: invalid Renderer source")()
    end
    if rendererLoader == nil then
        assert(readSource, "RBXTTFFamily: provide Renderer or ReadFile")
        rendererLoader = assert(loadstring(readSource(libraryPath)), "RBXTTFFamily: failed to load " .. libraryPath)()
    end
    assert(type(rendererLoader) == "function", "RBXTTFFamily: Renderer must be the RBXTTF factory function")

    -- ---------- weighted font table ----------
    local WEIGHT_ORDER = {
        { name = "Thin",        num = 100 },
        { name = "ExtraLight",  num = 200 },
        { name = "Light",       num = 300 },
        { name = "Regular",     num = 400 },
        { name = "Medium",      num = 500 },
        { name = "SemiBold",    num = 600 },
        { name = "Bold",        num = 700 },
        { name = "ExtraBold",   num = 800 },
        { name = "Black",       num = 900 },
    }
    local function normalizeName(s)
        return (tostring(s or ""):gsub("[%s_%-%.]", ""):lower())
    end

    local WEIGHT_ALIASES = {
        hairline = 100, thin = 100,
        extralight = 200, ultralight = 200,
        light = 300, book = 350,
        normal = 400, regular = 400, roman = 400,
        medium = 500,
        semibold = 600, demibold = 600, demi = 600,
        bold = 700,
        extrabold = 800, ultrabold = 800,
        black = 900, heavy = 900,
        extrablack = 950, ultrablack = 950,
    }

    local function weightNumber(weight)
        if type(weight) == "number" then return math.max(1, math.min(1000, weight)) end
        local numeric = tonumber(weight)
        if numeric then return math.max(1, math.min(1000, numeric)) end
        return WEIGHT_ALIASES[normalizeName(weight)] or 400
    end

    local function weightFromKey(key)
        if type(key) ~= "string" then return nil, false end
        local normalized = normalizeName(key)
        local italic = normalized:sub(-6) == "italic"
        local oblique = normalized:sub(-7) == "oblique"
        if italic then normalized = normalized:sub(1, -7) end
        if oblique then normalized = normalized:sub(1, -8) end
        return WEIGHT_ALIASES[normalized], italic, oblique
    end

    local sources = {}
    local function addSource(value, key)
        local source
        if type(value) == "table" then
            source = {}
            for field, fieldValue in pairs(value) do source[field] = fieldValue end
        else
            source = { Value = value }
        end
        local keyedWeight, keyedItalic, keyedOblique = weightFromKey(key)
        if not source.Weight and keyedWeight then source.Weight = keyedWeight end
        if source.Italic == nil and keyedWeight then source.Italic = keyedItalic end
        if source.Oblique == nil and keyedWeight then source.Oblique = keyedOblique end
        if source.Weight then source.Weight = weightNumber(source.Weight) end
        source.Index = #sources + 1
        sources[#sources + 1] = source
    end

    local configuredSources = config.Sources or config.Source
    if configuredSources ~= nil then
        local isDescriptor = type(configuredSources) == "table"
            and (configuredSources.Url or configuredSources.Path or configuredSources.Data or configuredSources.Value or configuredSources.Type)
        if type(configuredSources) ~= "table" or isDescriptor then
            addSource(configuredSources)
        else
            local numericKeys = {}
            for index, value in ipairs(configuredSources) do
                numericKeys[index] = true
                addSource(value, index)
            end
            for key, value in pairs(configuredSources) do
                if not numericKeys[key] then addSource(value, key) end
            end
        end
    end
    if config.ZipUrl then addSource({ Url = config.ZipUrl, Type = "zip", CacheFile = zipCacheFile }) end
    if config.ZipPath then addSource({ Path = config.ZipPath, Type = "zip" }) end
    assert(#sources > 0, "RBXTTFFamily: provide Sources, Source, ZipUrl, or ZipPath")

    -- ---------- pure-Lua DEFLATE inflate (no bitwise ops -> portable) ----------
    local LEN_BASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
    local LEN_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
    local DIST_BASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
    local DIST_EXTRA = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

    local function buildHuff(lengths)
        local maxIdx = 0
        for k in pairs(lengths) do if k > maxIdx then maxIdx = k end end
        local maxBits = 0
        for i = 1, maxIdx do
            local l = lengths[i]
            if l and l > maxBits then maxBits = l end
        end
        if maxBits == 0 then return nil end
        local blCount = {}
        for i = 1, maxBits do blCount[i] = 0 end
        for i = 1, maxIdx do
            local l = lengths[i]
            if l and l > 0 then blCount[l] = blCount[l] + 1 end
        end
        local firstCode, firstIndex = {}, {}
        local code = 0
        local pos = 1
        for bits = 1, maxBits do
            firstIndex[bits] = pos
            pos = pos + (blCount[bits] or 0)
            code = (code + (blCount[bits - 1] or 0)) * 2
            firstCode[bits] = code
        end
        local symbols = {}
        local si = 1
        for bits = 1, maxBits do
            for i = 1, maxIdx do
                if lengths[i] == bits then
                    symbols[si] = i - 1
                    si = si + 1
                end
            end
        end
        return { maxBits = maxBits, blCount = blCount, firstCode = firstCode, firstIndex = firstIndex, symbols = symbols }
    end

    local function inflate(data, startPos)
        local p = startPos
        local bitBuf, bitCnt = 0, 0
        local out = {}
        local outLen = 0

        local function readBits(n)
            while bitCnt < n do
                bitBuf = bitBuf + string.byte(data, p) * (2 ^ bitCnt)
                p = p + 1
                bitCnt = bitCnt + 8
            end
            local v = bitBuf % (2 ^ n)
            bitBuf = math.floor(bitBuf / (2 ^ n))
            bitCnt = bitCnt - n
            return v
        end

        local function decodeSymbol(huff)
            local c = 0
            for bits = 1, huff.maxBits do
                c = c * 2 + readBits(1)
                local n = huff.blCount[bits] or 0
                if c - huff.firstCode[bits] < n then
                    return huff.symbols[huff.firstIndex[bits] + (c - huff.firstCode[bits])]
                end
            end
            error("invalid huffman code")
        end

        local function emitCopy(dist, len)
            for i = 1, len do
                out[outLen + 1] = out[outLen + 1 - dist]
                outLen = outLen + 1
            end
        end

        local function inflateBlock(litHuff, distHuff)
            while true do
                local sym = decodeSymbol(litHuff)
                if sym < 256 then
                    outLen = outLen + 1
                    out[outLen] = sym
                elseif sym == 256 then
                    return
                else
                    local li = sym - 257
                    local length = LEN_BASE[li + 1] + readBits(LEN_EXTRA[li + 1])
                    local dsym = decodeSymbol(distHuff)
                    local dist = DIST_BASE[dsym + 1] + readBits(DIST_EXTRA[dsym + 1])
                    emitCopy(dist, length)
                end
            end
        end

        local fixedLit, fixedDist = nil, nil

        while true do
            local bfinal = readBits(1)
            local btype = readBits(2)
            if btype == 0 then
                bitBuf, bitCnt = 0, 0
                local len = string.byte(data, p) + string.byte(data, p + 1) * 256
                p = p + 4
                for i = 1, len do
                    outLen = outLen + 1
                    out[outLen] = string.byte(data, p + i - 1)
                end
                p = p + len
            elseif btype == 1 then
                if not fixedLit then
                    local ll, dl = {}, {}
                    for i = 0, 143 do ll[i + 1] = 8 end
                    for i = 144, 255 do ll[i + 1] = 9 end
                    for i = 256, 279 do ll[i + 1] = 7 end
                    for i = 280, 287 do ll[i + 1] = 8 end
                    for i = 0, 29 do dl[i + 1] = 5 end
                    fixedLit = buildHuff(ll)
                    fixedDist = buildHuff(dl)
                end
                inflateBlock(fixedLit, fixedDist)
            elseif btype == 2 then
                local hlit = readBits(5) + 257
                local hdist = readBits(5) + 1
                local hclen = readBits(4) + 4
                local order = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
                local clLengths = {}
                for i = 1, hclen do
                    clLengths[order[i] + 1] = readBits(3)
                end
                local clHuff = buildHuff(clLengths)
                local lens = {}
                local i = 0
                local total = hlit + hdist
                while i < total do
                    local sym = decodeSymbol(clHuff)
                    if sym < 16 then
                        i = i + 1
                        lens[i] = sym
                    elseif sym == 16 then
                        local rep = readBits(2) + 3
                        local prev = lens[i] or 0
                        for r = 1, rep do i = i + 1 lens[i] = prev end
                    elseif sym == 17 then
                        local rep = readBits(3) + 3
                        for r = 1, rep do i = i + 1 lens[i] = 0 end
                    else
                        local rep = readBits(7) + 11
                        for r = 1, rep do i = i + 1 lens[i] = 0 end
                    end
                end
                local litLengths, distLengths = {}, {}
                for i = 1, hlit do litLengths[i] = lens[i] end
                for i = 1, hdist do distLengths[i] = lens[hlit + i] end
                local litHuff = buildHuff(litLengths)
                local distHuff = buildHuff(distLengths)
                inflateBlock(litHuff, distHuff)
            else
                error("invalid deflate block type")
            end
            if bfinal == 1 then break end
        end

        local parts = {}
        local cs = 256
        for i = 1, outLen, cs do
            local n = math.min(cs, outLen - i + 1)
            local chunk = {}
            for j = 1, n do chunk[j] = out[i + j - 1] end
            parts[#parts + 1] = string.char(table.unpack(chunk, 1, n))
        end
        return table.concat(parts), p
    end

    -- ---------- ZIP reader ----------
    local function u16le(data, off)
        return string.byte(data, off + 1) + string.byte(data, off + 2) * 256
    end
    local function u32le(data, off)
        return u16le(data, off) + u16le(data, off + 2) * 65536
    end

    local function findEOCD(data)
        local n = #data
        local scanStart = math.max(1, n - 65557)
        for i = n - 21, scanStart, -1 do
            if string.byte(data, i + 1) == 0x50 and string.byte(data, i + 2) == 0x4B
                and string.byte(data, i + 3) == 0x05 and string.byte(data, i + 4) == 0x06 then
                return i
            end
        end
        return nil
    end

    local function parseZip(data)
        local eocd = findEOCD(data)
        if not eocd then error("RBXTTFFamily: not a zip (no EOCD)") end
        local total = u16le(data, eocd + 10)
        local cdOff = u32le(data, eocd + 16)
        local o = cdOff
        local entries = {}
        for _ = 1, total do
            local sig = u32le(data, o)
            if sig ~= 0x02014B50 then break end
            local method = u16le(data, o + 10)
            local csize = u32le(data, o + 20)
            local usize = u32le(data, o + 24)
            local nameLen = u16le(data, o + 28)
            local extraLen = u16le(data, o + 30)
            local commentLen = u16le(data, o + 32)
            local lho = u32le(data, o + 42)
            local name = string.sub(data, o + 47, o + 46 + nameLen)
            entries[name] = { offset = lho, method = method, csize = csize, usize = usize }
            o = o + 46 + nameLen + extraLen + commentLen
        end
        return entries
    end

    -- ---------- source download / cache / extract ----------
    pcall(function() if createFolder then createFolder(fontDir) end end)

    local function download(url)
        local body = type(config.Fetch) == "function" and config.Fetch(url) or nil
        if not body and syn and syn.request then
            local response = syn.request({ Url = url, Method = "GET" })
            if response and response.StatusCode == 200 then body = response.Body end
        end
        if not body and http_request then
            local response = http_request({ Url = url, Method = "GET" })
            if response and response.StatusCode == 200 then body = response.Body end
        end
        if not body and game and game.HttpGet then body = game:HttpGet(url, true) end
        assert(body, "RBXTTFFamily: no HTTP adapter is available for " .. tostring(url))
        return body
    end

    local function detectType(source, data, label)
        if source.Type then return tostring(source.Type):lower() end
        if string.sub(data, 1, 4) == "PK\3\4" then return "zip" end
        local signature = string.sub(data, 1, 4)
        if signature == "\0\1\0\0" or signature == "true" or signature == "typ1" or signature == "OTTO" then return "ttf" end
        local cleanLabel = tostring(label or ""):lower():gsub("[?#].*$", "")
        if cleanLabel:sub(-4) == ".zip" then return "zip" end
        if cleanLabel:sub(-4) == ".ttf" or cleanLabel:sub(-4) == ".otf" then return "ttf" end
        error("RBXTTFFamily: cannot detect source type for " .. tostring(label))
    end

    local function prepareSource(source)
        if source.Prepared then return source end
        local data, label
        if source.Data then
            data, label = source.Data, source.Name or "raw source " .. source.Index
        else
            local value = source.Url or source.Path or source.Value or source[1]
            assert(type(value) == "string", "RBXTTFFamily: source " .. source.Index .. " has no Url, Path, Data, or string value")
            label = value
            local signature = string.sub(value, 1, 4)
            local rawValue = signature == "PK\3\4" or signature == "\0\1\0\0" or signature == "true" or signature == "typ1" or signature == "OTTO"
            if rawValue then
                data = value
            elseif source.Url or value:match("^https?://") then
                local cacheFile = source.CacheFile or (fontDir .. "/font-source-" .. source.Index .. ".dat")
                local cachedOk, cached = false, nil
                if readSource then cachedOk, cached = pcall(readSource, cacheFile) end
                if cachedOk and cached and #cached > 4 then data = cached end
                if not data then
                    data = download(value)
                    if data and #data > 4 and writeCache then pcall(writeCache, cacheFile, data) end
                end
            else
                assert(readSource, "RBXTTFFamily: Path sources require ReadFile or executor readfile")
                data = readSource(value)
            end
        end
        assert(data and #data > 4, "RBXTTFFamily: failed to load " .. tostring(label))
        source.Data = data
        source.Label = source.Name or label
        source.Kind = detectType(source, data, label)
        if source.Kind == "zip" then source.Entries = parseZip(data) end
        source.Prepared = true
        return source
    end

    local function extractFile(source, name)
        local entries = source.Entries
        local e = entries[name]
        if not e then
            for k, v in pairs(entries) do
                if k:sub(-#name) == name then e = v break end
            end
        end
        if not e then return nil end
        local lho = e.offset
        local zipData = source.Data
        local nameLen = u16le(zipData, lho + 26)
        local extraLen = u16le(zipData, lho + 28)
        local dataStart = lho + 30 + nameLen + extraLen
        local raw
        if e.method == 0 then
            raw = string.sub(zipData, dataStart + 1, dataStart + e.csize)
        elseif e.method == 8 then
            raw = inflate(zipData, dataStart + 1)
        else
            error("RBXTTFFamily: unsupported zip method " .. e.method .. " for " .. name)
        end
        return raw
    end

    -- ---------- OpenType metadata and family catalogue ----------
    local function beU8(data, offset)
        return string.byte(data, offset + 1) or 0
    end

    local function beU16(data, offset)
        return beU8(data, offset) * 256 + beU8(data, offset + 1)
    end

    local function beU32(data, offset)
        return beU16(data, offset) * 65536 + beU16(data, offset + 2)
    end

    local function fontTables(data)
        if type(data) ~= "string" or #data < 12 then return nil, "font data is truncated" end
        local signature = string.sub(data, 1, 4)
        if signature ~= "\0\1\0\0" and signature ~= "true" and signature ~= "typ1" and signature ~= "OTTO" then
            return nil, "unsupported SFNT signature"
        end

        local count = beU16(data, 4)
        if 12 + count * 16 > #data then return nil, "font table directory is truncated" end
        local tables = {}
        for index = 0, count - 1 do
            local record = 12 + index * 16
            local tag = string.sub(data, record + 1, record + 4)
            local offset = beU32(data, record + 8)
            local length = beU32(data, record + 12)
            if offset + length <= #data then
                tables[tag] = { Offset = offset, Length = length }
            end
        end
        if not tables.glyf or not tables.loca then
            return nil, "font uses unsupported CFF/CFF2 outlines"
        end
        return tables
    end

    local function utf8Character(codepoint)
        if utf8 and utf8.char then
            local ok, value = pcall(utf8.char, codepoint)
            if ok then return value end
        end
        if codepoint < 0x80 then
            return string.char(codepoint)
        elseif codepoint < 0x800 then
            return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
        elseif codepoint < 0x10000 then
            return string.char(
                0xE0 + math.floor(codepoint / 0x1000),
                0x80 + math.floor(codepoint / 0x40) % 0x40,
                0x80 + codepoint % 0x40
            )
        end
        return string.char(
            0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end

    local function decodeUtf16Be(value)
        local output = {}
        local index = 1
        while index + 1 <= #value do
            local first = string.byte(value, index) * 256 + string.byte(value, index + 1)
            index = index + 2
            local codepoint = first
            if first >= 0xD800 and first <= 0xDBFF and index + 1 <= #value then
                local second = string.byte(value, index) * 256 + string.byte(value, index + 1)
                if second >= 0xDC00 and second <= 0xDFFF then
                    codepoint = 0x10000 + (first - 0xD800) * 0x400 + second - 0xDC00
                    index = index + 2
                end
            end
            if codepoint ~= 0 then output[#output + 1] = utf8Character(codepoint) end
        end
        return table.concat(output)
    end

    local function cleanFontName(value)
        return tostring(value or ""):gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local function fontNames(data, tables)
        local nameTable = tables.name
        if not nameTable or nameTable.Length < 6 then return {} end
        local base = nameTable.Offset
        local count = beU16(data, base + 2)
        local storage = base + beU16(data, base + 4)
        local names, scores = {}, {}

        for index = 0, count - 1 do
            local record = base + 6 + index * 12
            if record + 12 > base + nameTable.Length then break end
            local platform = beU16(data, record)
            local language = beU16(data, record + 4)
            local nameId = beU16(data, record + 6)
            local length = beU16(data, record + 8)
            local offset = storage + beU16(data, record + 10)
            if offset + length <= #data and (nameId == 1 or nameId == 2 or nameId == 4 or nameId == 6 or nameId == 16 or nameId == 17) then
                local raw = string.sub(data, offset + 1, offset + length)
                local value = (platform == 0 or platform == 3) and decodeUtf16Be(raw) or raw
                value = cleanFontName(value)
                local score = (platform == 3 and 20 or platform == 0 and 15 or 5)
                    + (language == 0x0409 and 5 or language == 0 and 2 or 0)
                if value ~= "" and score > (scores[nameId] or -1) then
                    names[nameId], scores[nameId] = value, score
                end
            end
        end
        return names
    end

    local WEIGHT_PATTERNS = {
        { "extrablack", 950 }, { "ultrablack", 950 },
        { "extralight", 200 }, { "ultralight", 200 },
        { "extrabold", 800 }, { "ultrabold", 800 },
        { "semibold", 600 }, { "demibold", 600 },
        { "hairline", 100 }, { "thin", 100 },
        { "light", 300 }, { "book", 350 },
        { "medium", 500 }, { "bold", 700 },
        { "black", 900 }, { "heavy", 900 },
        { "regular", 400 }, { "normal", 400 }, { "roman", 400 },
    }

    local function inferredWeight(value)
        local normalized = normalizeName(value)
        for _, candidate in ipairs(WEIGHT_PATTERNS) do
            if normalized:find(candidate[1], 1, true) then return candidate[2] end
        end
        return 400
    end

    local function hasBit(value, bit)
        return math.floor(value / (2 ^ bit)) % 2 == 1
    end

    local function fallbackFamily(label)
        local base = tostring(label or "Unknown")
            :gsub("[?#].*$", "")
            :gsub("\\", "/")
            :match("([^/]+)$") or "Unknown"
        base = base:gsub("%.[Tt][Tt][Ff]$", ""):gsub("%.[Oo][Tt][Ff]$", "")
        local stripped = base:gsub("[_%- ]+[Ii]talic$", "")
            :gsub("[_%- ]+[Oo]blique$", "")
            :gsub("[_%- ]+[Rr]egular$", "")
            :gsub("[_%- ]+[Bb]old$", "")
        return cleanFontName(stripped ~= "" and stripped or base)
    end

    local function inspectFont(data, label, overrides)
        local tables, reason = fontTables(data)
        if not tables then return nil, reason end
        local names = fontNames(data, tables)
        local family = cleanFontName(overrides.Family or names[16] or names[1])
        if family == "" then family = fallbackFamily(label) end
        local subfamily = cleanFontName(overrides.Subfamily or names[17] or names[2] or "Regular")
        local styleText = normalizeName(subfamily .. " " .. tostring(label or ""))

        local weight
        if overrides.Weight ~= nil then
            weight = weightNumber(overrides.Weight)
        elseif tables["OS/2"] and tables["OS/2"].Length >= 6 then
            weight = beU16(data, tables["OS/2"].Offset + 4)
            if weight < 1 or weight > 1000 then weight = inferredWeight(styleText) end
        else
            weight = inferredWeight(styleText)
        end

        local italic = overrides.Italic
        local oblique = overrides.Oblique
        if italic == nil or oblique == nil then
            local fsSelection = 0
            if tables["OS/2"] and tables["OS/2"].Length >= 64 then
                fsSelection = beU16(data, tables["OS/2"].Offset + 62)
            end
            local macStyle = tables.head and tables.head.Length >= 46 and beU16(data, tables.head.Offset + 44) or 0
            if italic == nil then
                italic = hasBit(fsSelection, 0) or hasBit(macStyle, 1) or styleText:find("italic", 1, true) ~= nil
            end
            if oblique == nil then
                oblique = hasBit(fsSelection, 9) or styleText:find("oblique", 1, true) ~= nil
            end
        end

        local style = overrides.Style
        if not style then
            style = italic and "Italic" or oblique and "Oblique" or "Normal"
        end

        return {
            Family = family,
            Subfamily = subfamily,
            FullName = cleanFontName(names[4] or (family .. " " .. subfamily)),
            PostScriptName = cleanFontName(names[6]),
            Weight = weight,
            Style = style,
            Italic = italic == true,
            Oblique = oblique == true,
            Data = data,
            Entry = label,
        }
    end

    local function matchesFilter(filter, entry)
        if filter == nil then return true end
        if type(filter) == "function" then return filter(entry) ~= false end
        if type(filter) == "string" then return normalizeName(entry):find(normalizeName(filter), 1, true) ~= nil end
        if type(filter) == "table" then
            for _, value in ipairs(filter) do
                if matchesFilter(value, entry) then return true end
            end
            return false
        end
        return true
    end

    local faces = {}
    local catalogueErrors = {}
    local catalogueReady = false
    local selectedFamily
    local loaded = {}

    local function addFace(face, source)
        face.Source = source.Label
        face.SourceIndex = source.Index
        face.Id = #faces + 1
        faces[#faces + 1] = face
    end

    local function discover()
        if catalogueReady then return end
        catalogueReady = true

        for _, source in ipairs(sources) do
            local ok, prepared = pcall(prepareSource, source)
            if not ok then
                catalogueErrors[#catalogueErrors + 1] = tostring(prepared)
            elseif prepared.Kind == "ttf" then
                local face, reason = inspectFont(prepared.Data, prepared.Label, prepared)
                if face then addFace(face, prepared) else catalogueErrors[#catalogueErrors + 1] = tostring(prepared.Label) .. ": " .. reason end
            elseif prepared.Kind == "zip" then
                local entries = {}
                for entry in pairs(prepared.Entries) do
                    local clean = entry:lower():gsub("[?#].*$", "")
                    if (clean:sub(-4) == ".ttf" or clean:sub(-4) == ".otf")
                        and matchesFilter(config.Include, entry)
                        and (config.Exclude == nil or not matchesFilter(config.Exclude, entry)) then
                        entries[#entries + 1] = entry
                    end
                end
                table.sort(entries)
                for _, entry in ipairs(entries) do
                    local extractedOk, raw = pcall(extractFile, prepared, entry)
                    if extractedOk and raw then
                        local face, reason = inspectFont(raw, entry, {})
                        if face then addFace(face, prepared) else catalogueErrors[#catalogueErrors + 1] = entry .. ": " .. reason end
                    elseif not extractedOk then
                        catalogueErrors[#catalogueErrors + 1] = entry .. ": " .. tostring(raw)
                    end
                end
            end
        end

        assert(#faces > 0, "RBXTTFFamily: no compatible TrueType faces found"
            .. (#catalogueErrors > 0 and " (" .. table.concat(catalogueErrors, "; ") .. ")" or ""))

        local familyCounts, familyNames, familyOrder = {}, {}, {}
        for _, face in ipairs(faces) do
            local key = normalizeName(face.Family)
            if not familyCounts[key] then
                familyCounts[key] = 0
                familyNames[key] = face.Family
                familyOrder[#familyOrder + 1] = key
            end
            familyCounts[key] = familyCounts[key] + 1
        end

        local requested = normalizeName(config.Family)
        if requested ~= "" then
            for key, familyName in pairs(familyNames) do
                if key == requested or key:find(requested, 1, true) or requested:find(key, 1, true) then
                    selectedFamily = familyName
                    break
                end
            end
            assert(selectedFamily, "RBXTTFFamily: family '" .. tostring(config.Family) .. "' was not found")
        else
            local bestCount = -1
            for _, key in ipairs(familyOrder) do
                if familyCounts[key] > bestCount then
                    bestCount = familyCounts[key]
                    selectedFamily = familyNames[key]
                end
            end
        end
    end

    local function publicFace(face)
        return {
            Family = face.Family,
            Subfamily = face.Subfamily,
            FullName = face.FullName,
            PostScriptName = face.PostScriptName,
            Weight = face.Weight,
            Style = face.Style,
            Italic = face.Italic,
            Oblique = face.Oblique,
            Source = face.Source,
            Entry = face.Entry,
        }
    end

    local function familyMatches(face, requested)
        return normalizeName(face.Family) == normalizeName(requested)
    end

    local function selectFace(weight, opts)
        discover()
        opts = opts or {}
        local requestedFamily = opts.Family or selectedFamily
        local requestedWeight = weightNumber(weight or opts.Weight or config.DefaultWeight or 400)
        local requestedStyle = normalizeName(opts.Style)
        local wantsItalic = opts.Italic == true or requestedStyle == "italic"
        local wantsOblique = opts.Oblique == true or requestedStyle == "oblique"
        local wantsSlanted = wantsItalic or wantsOblique
        local literalWeight = type(weight) == "string" and normalizeName(weight) or nil
        local best, bestScore

        for _, face in ipairs(faces) do
            if familyMatches(face, requestedFamily) then
                local slanted = face.Italic or face.Oblique
                local stylePenalty = slanted == wantsSlanted and 0 or 10000
                if requestedStyle ~= "" and normalizeName(face.Style) ~= requestedStyle then
                    stylePenalty = stylePenalty + 100
                end
                local literalBonus = literalWeight
                    and (normalizeName(face.Subfamily) == literalWeight or normalizeName(face.FullName) == literalWeight)
                    and -5000 or 0
                local score = stylePenalty + math.abs(face.Weight - requestedWeight) + literalBonus
                if not best or score < bestScore
                    or score == bestScore and requestedWeight > 500 and face.Weight > best.Weight
                    or score == bestScore and requestedWeight <= 500 and face.Weight < best.Weight then
                    best, bestScore = face, score
                end
            end
        end

        assert(best, "RBXTTFFamily: no faces available for family '" .. tostring(requestedFamily) .. "'")
        return best
    end

    local function safeFilename(value)
        local cleaned = tostring(value or "font"):gsub("[^%w%-_]+", "-"):gsub("%-+", "-")
        cleaned = cleaned:gsub("^%-+", ""):gsub("%-+$", "")
        return cleaned ~= "" and cleaned or "font"
    end

    local function rendererConfig(raw)
        return {
            Data = raw,
            CenterBias = config.CenterBias,
            YOffset = config.YOffset,
            YScale = config.YScale,
            YScaleB = config.YScaleB,
            Supersample = config.Supersample,
            MinAlpha = config.MinAlpha,
            CurveSteps = config.CurveSteps,
            Kerning = config.Kerning,
            ScaleQuantization = config.ScaleQuantization,
            MaxGlyphCacheEntries = config.MaxGlyphCacheEntries,
            MaxLayoutCacheEntries = config.MaxLayoutCacheEntries,
            MaxBitmapCacheEntries = config.MaxBitmapCacheEntries,
            MaxRunCacheEntries = config.MaxRunCacheEntries,
        }
    end

    local function loadFace(face)
        if loaded[face.Id] then return loaded[face.Id] end
        local fileName = safeFilename(face.PostScriptName ~= "" and face.PostScriptName or face.FullName) .. ".ttf"
        local filePath = fontDir .. "/" .. fileName
        if writeCache then pcall(writeCache, filePath, face.Data) end

        local font = rendererLoader(rendererConfig(face.Data))
        font.Family = face.Family
        font.Subfamily = face.Subfamily
        font.FullName = face.FullName
        font.PostScriptName = face.PostScriptName
        font.Weight = face.Weight
        font.Style = face.Style
        font.Italic = face.Italic
        font.Oblique = face.Oblique
        font._DiskPath = filePath
        font._Source = face.Source
        font._Entry = face.Entry
        loaded[face.Id] = font
        return font
    end

    -- ---------- public API ----------
    local Manager = {}
    Manager.WeightOrder = WEIGHT_ORDER

    function Manager:Families()
        discover()
        local groups, order = {}, {}
        for _, face in ipairs(faces) do
            local key = normalizeName(face.Family)
            if not groups[key] then
                groups[key] = { Name = face.Family, Count = 0 }
                order[#order + 1] = groups[key]
            end
            groups[key].Count = groups[key].Count + 1
        end
        table.sort(order, function(left, right) return left.Name:lower() < right.Name:lower() end)
        return order
    end

    function Manager:Faces(family)
        discover()
        family = family or selectedFamily
        local result = {}
        for _, face in ipairs(faces) do
            if familyMatches(face, family) then result[#result + 1] = publicFace(face) end
        end
        table.sort(result, function(left, right)
            if left.Weight == right.Weight then return left.Style < right.Style end
            return left.Weight < right.Weight
        end)
        return result
    end

    function Manager:List()
        discover()
        local result = {}
        for _, face in ipairs(faces) do result[#result + 1] = publicFace(face) end
        return result
    end

    function Manager:GetFamily()
        discover()
        return selectedFamily
    end

    function Manager:SetFamily(family)
        discover()
        local requested = normalizeName(family)
        for _, face in ipairs(faces) do
            if normalizeName(face.Family) == requested then
                selectedFamily = face.Family
                return self
            end
        end
        error("RBXTTFFamily: family '" .. tostring(family) .. "' was not found")
    end

    function Manager:ResolveFace(weight, opts)
        return publicFace(selectFace(weight, opts))
    end

    function Manager:Get(weight, opts)
        if type(weight) == "table" and opts == nil then
            opts, weight = weight, weight.Weight
        end
        opts = opts or {}
        return loadFace(selectFace(weight, opts))
    end

    function Manager:Errors()
        discover()
        local result = {}
        for index, message in ipairs(catalogueErrors) do result[index] = message end
        return result
    end

    local function rendererOptions(opts)
        local clean = {}
        for key, value in pairs(opts or {}) do
            if key ~= "Weight" and key ~= "Italic" and key ~= "Oblique"
                and key ~= "Style" and key ~= "Family" then
                clean[key] = value
            end
        end
        return clean
    end

    function Manager:Measure(str, size, opts)
        opts = opts or {}
        return self:Get(opts.Weight, opts):Measure(str, size, rendererOptions(opts))
    end

    function Manager:Draw(str, size, originX, originY, opts)
        opts = opts or {}
        return self:Get(opts.Weight, opts):Draw(str, size, originX, originY, rendererOptions(opts))
    end

    function Manager:CreateText(str, size, originX, originY, opts)
        opts = opts or {}
        return self:Get(opts.Weight, opts):CreateText(str, size, originX, originY, rendererOptions(opts))
    end

    function Manager:RasterizeText(str, size, width, height, opts)
        opts = opts or {}
        return self:Get(opts.Weight, opts):RasterizeText(str, size, width, height, rendererOptions(opts))
    end

    function Manager:RasterizeRuns(str, size, width, height, opts)
        opts = opts or {}
        return self:Get(opts.Weight, opts):RasterizeRuns(str, size, width, height, rendererOptions(opts))
    end

    function Manager:Truncate(str, size, maxWidth, opts, ellipsis)
        opts = opts or {}
        return self:Get(opts.Weight, opts):Truncate(str, size, maxWidth, rendererOptions(opts), ellipsis)
    end

    function Manager:Stats()
        local result = {}
        for id, font in pairs(loaded) do
            result[id] = {
                Face = publicFace(faces[id]),
                Renderer = font:Stats(),
            }
        end
        return result
    end

    function Manager:Clear()
        for _, font in pairs(loaded) do font:Clear() end
    end

    function Manager:Destroy()
        for _, font in pairs(loaded) do font:Destroy() end
        loaded = {}
    end

    return Manager
end
