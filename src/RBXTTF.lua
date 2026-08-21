return function(config)
    config = config or {}
    local readSource = config.ReadFile or readfile
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
        assert(body, "RBXTTF: no HTTP adapter is available for " .. tostring(url))
        return body
    end

    local function looksLikeFont(data)
        if type(data) ~= "string" or #data < 4 then return false end
        local signature = string.sub(data, 1, 4)
        return signature == "\0\1\0\0" or signature == "true" or signature == "typ1" or signature == "OTTO"
    end

    local function resolveFontData()
        if config.Data then return config.Data, config.Path or "font data" end
        local source = config.Source
        if type(source) == "table" then
            if source.Data then return source.Data, source.Name or "font data" end
            if source.Url then return download(source.Url), source.Url end
            if source.Path then
                assert(readSource, "RBXTTF: Path sources require ReadFile or executor readfile")
                return readSource(source.Path), source.Path
            end
            source = source[1]
        end
        if type(source) == "string" then
            if looksLikeFont(source) then return source, "font data" end
            if source:match("^https?://") then return download(source), source end
            assert(readSource, "RBXTTF: path sources require ReadFile or executor readfile")
            return readSource(source), source
        end
        local fontPath = config.Path or "font.ttf"
        assert(readSource, "RBXTTF: Path sources require ReadFile or executor readfile")
        return readSource(fontPath), fontPath
    end

    local fontData, fontLabel = resolveFontData()
    assert(fontData and #fontData > 0, "RBXTTF: failed to read " .. tostring(fontLabel))
    -- Center-alignment bias (fraction of size, positive = lower): the font ascender (1005/1000) exceeds capHeight (710/1000), so full line-box centering sits too high
    local centerBias = config.CenterBias or 0
    -- Global Y correction (device px, positive = move text DOWN): compensates for
    -- executor coordinate-space mismatches between Drawing and GUI AbsolutePosition
    local yOffset = config.YOffset or 0
    -- Linear Y correction for scale mismatches: correctedY = originY * yScale + yScaleB
    local yScale = config.YScale or 1
    local yScaleB = config.YScaleB or 0

    -- ---------- binary readers (big-endian, 0-based file offsets) ----------
    local function u8(fo) return string.byte(fontData, fo + 1) or 0 end
    local function u16(fo) return u8(fo) * 256 + u8(fo + 1) end
    local function i16(fo) local v = u16(fo) if v >= 0x8000 then v = v - 0x10000 end return v end
    local function u32(fo) return u16(fo) * 65536 + u16(fo + 2) end

    -- ---------- table directory ----------
    local numTables = u16(4)
    local tables = {}
    for i = 0, numTables - 1 do
        local rec = 12 + i * 16
        local tag = string.sub(fontData, rec + 1, rec + 4)
        tables[tag] = { off = u32(rec + 8) }
    end

    assert(tables["head"] and tables["maxp"] and tables["hhea"] and tables["hmtx"] and tables["loca"] and tables["glyf"] and tables["cmap"], "missing required TTF tables")

    local unitsPerEm = u16(tables["head"].off + 18)
    local indexToLocFormat = i16(tables["head"].off + 50)
    local numGlyphs = u16(tables["maxp"].off + 4)
    local ascender = i16(tables["hhea"].off + 4)
    local descender = i16(tables["hhea"].off + 6)
    local numberOfHMetrics = u16(tables["hhea"].off + 34)

    -- hmtx
    local hmtxOff = tables["hmtx"].off
    local advances, lsbs = {}, {}
    for i = 0, numberOfHMetrics - 1 do
        advances[i] = u16(hmtxOff + i * 4)
        lsbs[i] = i16(hmtxOff + i * 4 + 2)
    end
    local lastAdv = advances[numberOfHMetrics - 1] or 0
    for i = numberOfHMetrics, numGlyphs - 1 do
        advances[i] = lastAdv
        lsbs[i] = i16(hmtxOff + numberOfHMetrics * 4 + (i - numberOfHMetrics) * 2)
    end

    -- loca
    local locaOff = tables["loca"].off
    local glyphOff = {}
    for i = 0, numGlyphs do
        if indexToLocFormat == 0 then
            glyphOff[i] = u16(locaOff + i * 2) * 2
        else
            glyphOff[i] = u32(locaOff + i * 4)
        end
    end

    -- ---------- Unicode cmap (format 4 + format 12) ----------
    local cmapOff = tables["cmap"].off
    local nCmaps = u16(cmapOff + 2)
    local cmap4Off, cmap12Off = nil, nil
    for i = 0, nCmaps - 1 do
        local base = cmapOff + 4 + i * 8
        local plat, enc = u16(base), u16(base + 2)
        local o = cmapOff + u32(base + 4)
        local format = u16(o)
        if format == 12 and (plat == 0 or (plat == 3 and enc == 10)) then
            cmap12Off = cmap12Off or o
        elseif format == 4 and (plat == 0 or (plat == 3 and (enc == 1 or enc == 0))) then
            cmap4Off = cmap4Off or o
        end
    end
    if not cmap4Off or not cmap12Off then
        for i = 0, nCmaps - 1 do
            local base = cmapOff + 4 + i * 8
            local o = cmapOff + u32(base + 4)
            local format = u16(o)
            if format == 4 and not cmap4Off then cmap4Off = o end
            if format == 12 and not cmap12Off then cmap12Off = o end
        end
    end
    assert(cmap4Off or cmap12Off, "RBXTTF: no supported Unicode cmap found")

    local cmap4Segments = {}
    if cmap4Off then
        local segX2 = u16(cmap4Off + 6)
        local segCount = math.floor(segX2 / 2)
        local endCodes = cmap4Off + 14
        local startCodes = endCodes + segX2 + 2
        local deltas = startCodes + segX2
        local rangeOffsets = deltas + segX2
        for index = 0, segCount - 1 do
            cmap4Segments[index + 1] = {
                first = u16(startCodes + index * 2),
                last = u16(endCodes + index * 2),
                delta = i16(deltas + index * 2),
                rangeAddress = rangeOffsets + index * 2,
                rangeOffset = u16(rangeOffsets + index * 2),
            }
        end
    end

    local cmap12Groups = {}
    if cmap12Off then
        local groupCount = u32(cmap12Off + 12)
        for index = 0, groupCount - 1 do
            local groupOffset = cmap12Off + 16 + index * 12
            cmap12Groups[index + 1] = {
                first = u32(groupOffset),
                last = u32(groupOffset + 4),
                glyph = u32(groupOffset + 8),
            }
        end
    end

    local cmapCache = {}
    local function mapCodepoint(codepoint)
        local cached = cmapCache[codepoint]
        if cached ~= nil then return cached end

        local glyph = 0
        if codepoint > 0xFFFF and #cmap12Groups > 0 then
            local low, high = 1, #cmap12Groups
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local group = cmap12Groups[middle]
                if codepoint < group.first then
                    high = middle - 1
                elseif codepoint > group.last then
                    low = middle + 1
                else
                    glyph = group.glyph + codepoint - group.first
                    break
                end
            end
        elseif codepoint <= 0xFFFF and #cmap4Segments > 0 then
            local low, high = 1, #cmap4Segments
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local segment = cmap4Segments[middle]
                if codepoint < segment.first then
                    high = middle - 1
                elseif codepoint > segment.last then
                    low = middle + 1
                else
                    if segment.rangeOffset == 0 then
                        glyph = (codepoint + segment.delta) % 65536
                    else
                        local glyphAddress = segment.rangeAddress + segment.rangeOffset + (codepoint - segment.first) * 2
                        glyph = u16(glyphAddress)
                        if glyph ~= 0 then glyph = (glyph + segment.delta) % 65536 end
                    end
                    break
                end
            end
        end

        if glyph == 0 and codepoint <= 0x10FFFF and #cmap12Groups > 0 then
            local low, high = 1, #cmap12Groups
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local group = cmap12Groups[middle]
                if codepoint < group.first then
                    high = middle - 1
                elseif codepoint > group.last then
                    low = middle + 1
                else
                    glyph = group.glyph + codepoint - group.first
                    break
                end
            end
        end

        if glyph < 0 or glyph >= numGlyphs then glyph = 0 end
        cmapCache[codepoint] = glyph
        return glyph
    end

    local function decodeUtf8(str)
        local codepoints, byteEnds = {}, {}
        local index, length = 1, #str
        while index <= length do
            local first = string.byte(str, index)
            local codepoint, count = first, 1
            if first >= 0xC2 and first <= 0xDF and index + 1 <= length then
                local second = string.byte(str, index + 1)
                if second >= 0x80 and second <= 0xBF then
                    codepoint = (first - 0xC0) * 0x40 + second - 0x80
                    count = 2
                end
            elseif first >= 0xE0 and first <= 0xEF and index + 2 <= length then
                local second, third = string.byte(str, index + 1), string.byte(str, index + 2)
                if second >= 0x80 and second <= 0xBF and third >= 0x80 and third <= 0xBF then
                    local candidate = (first - 0xE0) * 0x1000 + (second - 0x80) * 0x40 + third - 0x80
                    if candidate >= 0x800 and not (candidate >= 0xD800 and candidate <= 0xDFFF) then
                        codepoint, count = candidate, 3
                    end
                end
            elseif first >= 0xF0 and first <= 0xF4 and index + 3 <= length then
                local second, third, fourth = string.byte(str, index + 1), string.byte(str, index + 2), string.byte(str, index + 3)
                if second >= 0x80 and second <= 0xBF and third >= 0x80 and third <= 0xBF and fourth >= 0x80 and fourth <= 0xBF then
                    local candidate = (first - 0xF0) * 0x40000 + (second - 0x80) * 0x1000 + (third - 0x80) * 0x40 + fourth - 0x80
                    if candidate >= 0x10000 and candidate <= 0x10FFFF then
                        codepoint, count = candidate, 4
                    end
                end
            end
            codepoints[#codepoints + 1] = codepoint
            byteEnds[#byteEnds + 1] = index + count - 1
            index = index + count
        end
        return codepoints, byteEnds
    end

    -- ---------- legacy TrueType kerning ----------
    local kernPairs = {}
    if tables["kern"] then
        local kernOffset = tables["kern"].off
        if u16(kernOffset) == 0 then
            local subtableCount = u16(kernOffset + 2)
            local subtableOffset = kernOffset + 4
            for _ = 1, subtableCount do
                local length = u16(subtableOffset + 2)
                local coverage = u16(subtableOffset + 4)
                local format = math.floor(coverage / 256)
                if format == 0 and bit32.band(coverage, 1) ~= 0 then
                    local pairCount = u16(subtableOffset + 6)
                    for pairIndex = 0, pairCount - 1 do
                        local pairOffset = subtableOffset + 14 + pairIndex * 6
                        local left = u16(pairOffset)
                        local right = u16(pairOffset + 2)
                        kernPairs[left * 65536 + right] = i16(pairOffset + 4)
                    end
                end
                if length <= 0 then break end
                subtableOffset = subtableOffset + length
            end
        end
    end

    local gposPairs, gposClassRules = {}, {}
    local coverageContains, glyphClass
    if tables["GPOS"] then
        local gposOffset = tables["GPOS"].off

        local function valueRecordSize(format)
            local size = 0
            for bit = 0, 7 do
                if bit32.band(format, 2 ^ bit) ~= 0 then size = size + 2 end
            end
            return size
        end

        local function valueXAdvance(offset, format)
            local cursor, xAdvance = offset, 0
            for bit = 0, 7 do
                local mask = 2 ^ bit
                if bit32.band(format, mask) ~= 0 then
                    if mask == 4 then xAdvance = i16(cursor) end
                    cursor = cursor + 2
                end
            end
            return xAdvance
        end

        local function parseCoverage(base, relativeOffset)
            local offset = base + relativeOffset
            local format = u16(offset)
            if format == 1 then
                local count, glyphs = u16(offset + 2), {}
                for index = 0, count - 1 do glyphs[index + 1] = u16(offset + 4 + index * 2) end
                return { format = 1, glyphs = glyphs }
            elseif format == 2 then
                local count, ranges = u16(offset + 2), {}
                for index = 0, count - 1 do
                    local rangeOffset = offset + 4 + index * 6
                    ranges[index + 1] = {
                        first = u16(rangeOffset),
                        last = u16(rangeOffset + 2),
                        index = u16(rangeOffset + 4),
                    }
                end
                return { format = 2, ranges = ranges }
            end
            return nil
        end

        local function coverageGlyph(coverage, coverageIndex)
            if not coverage then return nil end
            if coverage.format == 1 then return coverage.glyphs[coverageIndex + 1] end
            for _, range in ipairs(coverage.ranges) do
                local rangeLength = range.last - range.first
                if coverageIndex >= range.index and coverageIndex <= range.index + rangeLength then
                    return range.first + coverageIndex - range.index
                end
            end
            return nil
        end

        coverageContains = function(coverage, glyph)
            if not coverage then return false end
            if coverage.format == 1 then
                local low, high = 1, #coverage.glyphs
                while low <= high do
                    local middle = math.floor((low + high) / 2)
                    local candidate = coverage.glyphs[middle]
                    if glyph < candidate then high = middle - 1
                    elseif glyph > candidate then low = middle + 1
                    else return true end
                end
                return false
            end
            local low, high = 1, #coverage.ranges
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local range = coverage.ranges[middle]
                if glyph < range.first then high = middle - 1
                elseif glyph > range.last then low = middle + 1
                else return true end
            end
            return false
        end

        local function parseClassDefinition(base, relativeOffset)
            local offset = base + relativeOffset
            local format = u16(offset)
            if format == 1 then
                local first, count = u16(offset + 2), u16(offset + 4)
                local classes = {}
                for index = 0, count - 1 do classes[index] = u16(offset + 6 + index * 2) end
                return { format = 1, first = first, count = count, classes = classes }
            elseif format == 2 then
                local count, ranges = u16(offset + 2), {}
                for index = 0, count - 1 do
                    local rangeOffset = offset + 4 + index * 6
                    ranges[index + 1] = {
                        first = u16(rangeOffset),
                        last = u16(rangeOffset + 2),
                        class = u16(rangeOffset + 4),
                    }
                end
                return { format = 2, ranges = ranges }
            end
            return nil
        end

        glyphClass = function(definition, glyph)
            if not definition then return 0 end
            if definition.format == 1 then
                local index = glyph - definition.first
                if index >= 0 and index < definition.count then return definition.classes[index] or 0 end
                return 0
            end
            local low, high = 1, #definition.ranges
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local range = definition.ranges[middle]
                if glyph < range.first then high = middle - 1
                elseif glyph > range.last then low = middle + 1
                else return range.class end
            end
            return 0
        end

        local function parsePairPositioning(subtableOffset)
            local format = u16(subtableOffset)
            local coverage = parseCoverage(subtableOffset, u16(subtableOffset + 2))
            local valueFormat1, valueFormat2 = u16(subtableOffset + 4), u16(subtableOffset + 6)
            local valueSize1, valueSize2 = valueRecordSize(valueFormat1), valueRecordSize(valueFormat2)
            if format == 1 then
                local pairSetCount = u16(subtableOffset + 8)
                for coverageIndex = 0, pairSetCount - 1 do
                    local firstGlyph = coverageGlyph(coverage, coverageIndex)
                    local pairSetOffset = subtableOffset + u16(subtableOffset + 10 + coverageIndex * 2)
                    local pairValueCount = u16(pairSetOffset)
                    local recordOffset = pairSetOffset + 2
                    for _ = 1, pairValueCount do
                        local secondGlyph = u16(recordOffset)
                        local adjustment = valueXAdvance(recordOffset + 2, valueFormat1)
                        if firstGlyph and adjustment ~= 0 then
                            local pairKey = firstGlyph * 65536 + secondGlyph
                            gposPairs[pairKey] = (gposPairs[pairKey] or 0) + adjustment
                        end
                        recordOffset = recordOffset + 2 + valueSize1 + valueSize2
                    end
                end
            elseif format == 2 then
                local class1 = parseClassDefinition(subtableOffset, u16(subtableOffset + 8))
                local class2 = parseClassDefinition(subtableOffset, u16(subtableOffset + 10))
                local class1Count, class2Count = u16(subtableOffset + 12), u16(subtableOffset + 14)
                local matrix, recordOffset = {}, subtableOffset + 16
                for firstClass = 0, class1Count - 1 do
                    local row = {}
                    for secondClass = 0, class2Count - 1 do
                        local adjustment = valueXAdvance(recordOffset, valueFormat1)
                        if adjustment ~= 0 then row[secondClass] = adjustment end
                        recordOffset = recordOffset + valueSize1 + valueSize2
                    end
                    matrix[firstClass] = row
                end
                gposClassRules[#gposClassRules + 1] = {
                    coverage = coverage,
                    class1 = class1,
                    class2 = class2,
                    matrix = matrix,
                }
            end
        end

        local featureListOffset = gposOffset + u16(gposOffset + 6)
        local featureCount = u16(featureListOffset)
        local lookupIndices = {}
        for featureIndex = 0, featureCount - 1 do
            local recordOffset = featureListOffset + 2 + featureIndex * 6
            local tag = string.sub(fontData, recordOffset + 1, recordOffset + 4)
            if tag == "kern" or tag == "dist" then
                local featureOffset = featureListOffset + u16(recordOffset + 4)
                local lookupCount = u16(featureOffset + 2)
                for index = 0, lookupCount - 1 do lookupIndices[u16(featureOffset + 4 + index * 2)] = true end
            end
        end

        local lookupListOffset = gposOffset + u16(gposOffset + 8)
        for lookupIndex in pairs(lookupIndices) do
            local lookupOffset = lookupListOffset + u16(lookupListOffset + 2 + lookupIndex * 2)
            local lookupType, subtableCount = u16(lookupOffset), u16(lookupOffset + 4)
            for subtableIndex = 0, subtableCount - 1 do
                local subtableOffset = lookupOffset + u16(lookupOffset + 6 + subtableIndex * 2)
                if lookupType == 2 then
                    parsePairPositioning(subtableOffset)
                elseif lookupType == 9 and u16(subtableOffset) == 1 and u16(subtableOffset + 2) == 2 then
                    parsePairPositioning(subtableOffset + u32(subtableOffset + 4))
                end
            end
        end
    end

    local function kerning(left, right)
        if not left or config.Kerning == false then return 0 end
        local pairKey = left * 65536 + right
        local adjustment = gposPairs[pairKey]
        local matched = adjustment ~= nil
        adjustment = adjustment or 0
        for _, rule in ipairs(gposClassRules) do
            if coverageContains(rule.coverage, left) then
                matched = true
                local firstClass = glyphClass(rule.class1, left)
                local secondClass = glyphClass(rule.class2, right)
                adjustment = adjustment + ((rule.matrix[firstClass] and rule.matrix[firstClass][secondClass]) or 0)
            end
        end
        if matched then return adjustment end
        return kernPairs[pairKey] or 0
    end

    -- ---------- glyf outline parser (simple + compound) ----------
    local glyfTable = tables["glyf"].off

    local parseGlyphRec
    local outlineCache = {}
    local outlineParsing = {}
    parseGlyphRec = function(gid)
        local cached = outlineCache[gid]
        if cached ~= nil then return cached or nil end
        if outlineParsing[gid] then return nil end
        outlineParsing[gid] = true
        local start = glyphOff[gid]
        local len = (glyphOff[gid + 1] or start) - start
        if len <= 0 then
            outlineParsing[gid] = nil
            outlineCache[gid] = false
            return nil
        end
        local off = glyfTable + start
        local nc = i16(off)
        local contours = {}
        if nc >= 0 then
            local endPts = {}
            for i = 0, nc - 1 do endPts[i] = u16(off + 10 + i * 2) end
            local insLen = u16(off + 10 + nc * 2)
            local flagsBase = off + 12 + nc * 2 + insLen
            local numPts = endPts[nc - 1] + 1
            local flags = {}
            local p = flagsBase
            local i = 0
            while i < numPts do
                local f = u8(p) p = p + 1
                flags[i] = f
                if bit32.band(f, 8) ~= 0 then
                    local rep = u8(p) p = p + 1
                    for r = 1, rep do i = i + 1 flags[i] = f end
                end
                i = i + 1
            end
            local xs, ys = {}, {}
            local x = 0
            for ptIdx = 0, numPts - 1 do
                local f = flags[ptIdx]
                if bit32.band(f, 2) ~= 0 then
                    local v = u8(p) p = p + 1
                    if bit32.band(f, 16) ~= 0 then x = x + v else x = x - v end
                elseif bit32.band(f, 16) == 0 then
                    x = x + i16(p) p = p + 2
                end
                xs[ptIdx] = x
            end
            local y = 0
            for ptIdx = 0, numPts - 1 do
                local f = flags[ptIdx]
                if bit32.band(f, 4) ~= 0 then
                    local v = u8(p) p = p + 1
                    if bit32.band(f, 32) ~= 0 then y = y + v else y = y - v end
                elseif bit32.band(f, 32) == 0 then
                    y = y + i16(p) p = p + 2
                end
                ys[ptIdx] = y
            end
            local si = 0
            for c = 0, nc - 1 do
                local e = endPts[c]
                local contour = {}
                for j = si, e do
                    contour[#contour + 1] = { x = xs[j], y = ys[j], on = bit32.band(flags[j], 1) ~= 0 }
                end
                contours[#contours + 1] = contour
                si = e + 1
            end
        else
            local p = off + 10
            while true do
                local f = u16(p)
                local cgid = u16(p + 2)
                p = p + 4
                local a1, a2 = 0, 0
                if bit32.band(f, 1) ~= 0 then
                    a1, a2 = i16(p), i16(p + 2)
                    p = p + 4
                else
                    local v1, v2 = u8(p), u8(p + 1)
                    p = p + 2
                    if v1 >= 128 then v1 = v1 - 256 end
                    if v2 >= 128 then v2 = v2 - 256 end
                    a1, a2 = v1, v2
                end
                local s1, s2, s3, s4 = 1, 0, 0, 1
                if bit32.band(f, 8) ~= 0 then
                    s1 = i16(p) / 16384 p = p + 2 s4 = s1
                elseif bit32.band(f, 64) ~= 0 then
                    s1 = i16(p) / 16384 s4 = i16(p + 2) / 16384 p = p + 4
                elseif bit32.band(f, 128) ~= 0 then
                    s1 = i16(p) / 16384 s2 = i16(p + 2) / 16384
                    s3 = i16(p + 4) / 16384 s4 = i16(p + 6) / 16384
                    p = p + 8
                end
                local sub = parseGlyphRec(cgid)
                if sub then
                    for _, sc in ipairs(sub) do
                        local tc = {}
                        for _, pt in ipairs(sc) do
                            local tx = s1 * pt.x + s2 * pt.y
                            local ty = s3 * pt.x + s4 * pt.y
                            if bit32.band(f, 2) ~= 0 then
                                tx = tx + a1
                                ty = ty + a2
                            end
                            tc[#tc + 1] = { x = tx, y = ty, on = pt.on }
                        end
                        contours[#contours + 1] = tc
                    end
                end
                if bit32.band(f, 32) == 0 then break end
            end
        end
        outlineParsing[gid] = nil
        outlineCache[gid] = contours
        return contours
    end

    -- ---------- TrueType contour -> flattened polygon ----------
    local function contourToPolygon(contour, steps)
        steps = steps or 6
        local n = #contour
        if n < 2 then return {} end
        local aug = {}
        for i = 1, n do
            local p = contour[i]
            local q = contour[i % n + 1]
            aug[#aug + 1] = { x = p.x, y = p.y, on = p.on }
            if not p.on and not q.on then
                aug[#aug + 1] = { x = (p.x + q.x) / 2, y = (p.y + q.y) / 2, on = true }
            end
        end
        local m = #aug
        local out = {}
        local startIdx = 1
        for i = 1, m do
            if aug[i].on then startIdx = i break end
        end
        local function quad(p0x, p0y, cx, cy, p1x, p1y)
            for s = 1, steps do
                local t = s / steps
                local u = 1 - t
                out[#out + 1] = { u * u * p0x + 2 * u * t * cx + t * t * p1x, u * u * p0y + 2 * u * t * cy + t * t * p1y }
            end
        end
        local i = startIdx
        local count = 0
        while count < m do
            count = count + 1
            local p = aug[i]
            local j = i % m + 1
            local q = aug[j]
            if p.on and q.on then
                out[#out + 1] = { q.x, q.y }
                i = j
            elseif p.on then
                local r = aug[j % m + 1]
                quad(p.x, p.y, q.x, q.y, r.x, r.y)
                i = j % m + 1
                count = count + 1
            else
                local pi = (i - 2) % m + 1
                local pp = aug[pi]
                local p0x, p0y = pp.x, pp.y
                if not pp.on then p0x, p0y = (pp.x + p.x) / 2, (pp.y + p.y) / 2 end
                if q.on then
                    quad(p0x, p0y, p.x, p.y, q.x, q.y)
                    i = j
                else
                    local mx, my = (p.x + q.x) / 2, (p.y + q.y) / 2
                    quad(p0x, p0y, p.x, p.y, mx, my)
                    i = j
                    count = count + 1
                end
            end
        end
        return out
    end

    -- ---------- outline embolden (Fixed vector normal inflation) ----------
    local function emboldenPoly(poly, amount)
        local n = #poly
        if n < 3 or amount == 0 then return end
        local offsets = {}
        for i = 1, n do
            local p = poly[i]
            local prev = poly[(i - 2) % n + 1]
            local next = poly[i % n + 1]
            local e1x, e1y = p[1] - prev[1], p[2] - prev[2]
            local e2x, e2y = next[1] - p[1], next[2] - p[2]
            local l1 = math.sqrt(e1x * e1x + e1y * e1y)
            local l2 = math.sqrt(e2x * e2x + e2y * e2y)

            if l1 < 1e-6 and l2 < 1e-6 then
                offsets[i] = { 0, 0 }
            elseif l1 < 1e-6 then
                offsets[i] = { (-e2y / l2) * amount, (e2x / l2) * amount }
            elseif l2 < 1e-6 then
                offsets[i] = { (-e1y / l1) * amount, (e1x / l1) * amount }
            else
                local n1x, n1y = -e1y / l1, e1x / l1
                local n2x, n2y = -e2y / l2, e2x / l2
                local nx, ny = n1x + n2x, n1y + n2y
                local ln = math.sqrt(nx * nx + ny * ny)
                if ln > 1e-6 then
                    local miter = math.min(1.8, 2.0 / ln)
                    offsets[i] = { (nx / ln) * amount * miter, (ny / ln) * amount * miter }
                else
                    offsets[i] = { n1x * amount, n1y * amount }
                end
            end
        end
        for i = 1, n do
            poly[i][1] = poly[i][1] + offsets[i][1]
            poly[i][2] = poly[i][2] + offsets[i][2]
        end
    end

    -- ---------- cached supersampled raster runs ----------
    local SS = math.max(2, math.floor(config.Supersample or 4))
    local MIN_ALPHA = config.MinAlpha or 0.12
    local CURVE_STEPS = math.max(4, math.floor(config.CurveSteps or 6))
    local SCALE_QUANTIZATION = config.ScaleQuantization
    if SCALE_QUANTIZATION == nil then SCALE_QUANTIZATION = 64 end
    if SCALE_QUANTIZATION and SCALE_QUANTIZATION > 0 then
        SCALE_QUANTIZATION = math.max(1, SCALE_QUANTIZATION)
    else
        SCALE_QUANTIZATION = nil
    end
    local MAX_GLYPH_CACHE = config.MaxGlyphCacheEntries or 4096
    local glyphCache, glyphCacheQueue = {}, {}
    local polygonCache = {}
    local stats = {
        GlyphCacheHits = 0,
        GlyphCacheMisses = 0,
        GlyphsRasterized = 0,
        BitmapCacheHits = 0,
        BitmapCacheMisses = 0,
        BitmapsEncoded = 0,
        DrawingsCreated = 0,
        DrawingsReused = 0,
        HandleMoves = 0,
    }

    local function basePolygons(gid)
        local cached = polygonCache[gid]
        if cached ~= nil then return cached or nil end
        local contours = parseGlyphRec(gid)
        if not contours or #contours == 0 then
            polygonCache[gid] = false
            return nil
        end
        local polygons = {}
        for _, contour in ipairs(contours) do
            local polygon = contourToPolygon(contour, CURVE_STEPS)
            if #polygon >= 3 then polygons[#polygons + 1] = polygon end
        end
        polygonCache[gid] = #polygons > 0 and polygons or false
        return #polygons > 0 and polygons or nil
    end

    local function copyPolygons(polygons)
        local copy = {}
        for polygonIndex, polygon in ipairs(polygons) do
            local nextPolygon = {}
            for pointIndex, point in ipairs(polygon) do
                nextPolygon[pointIndex] = { point[1], point[2] }
            end
            copy[polygonIndex] = nextPolygon
        end
        return copy
    end

    local function cacheGlyph(key, entry)
        glyphCache[key] = entry
        glyphCacheQueue[#glyphCacheQueue + 1] = key
        if MAX_GLYPH_CACHE > 0 and #glyphCacheQueue > MAX_GLYPH_CACHE then
            local oldest = table.remove(glyphCacheQueue, 1)
            glyphCache[oldest] = nil
        end
    end

    local function rasterizeGlyph(gid, requestedScale, emboldenUnits)
        local quantizedScale = requestedScale
        if SCALE_QUANTIZATION then
            quantizedScale = math.floor(requestedScale * SCALE_QUANTIZATION + 0.5) / SCALE_QUANTIZATION
        end
        local boldKey = math.floor((emboldenUnits or 0) * 16 + 0.5)
        local cacheKey = tostring(gid) .. ":" .. tostring(quantizedScale) .. ":" .. tostring(boldKey)
        local cached = glyphCache[cacheKey]
        if cached ~= nil then
            stats.GlyphCacheHits = stats.GlyphCacheHits + 1
            return cached or nil
        end
        stats.GlyphCacheMisses = stats.GlyphCacheMisses + 1

        local base = basePolygons(gid)
        if not base then
            cacheGlyph(cacheKey, false)
            return nil
        end

        local polygons = base
        local quantizedBold = boldKey / 16
        if quantizedBold > 0 then
            polygons = copyPolygons(base)
            for _, polygon in ipairs(polygons) do emboldenPoly(polygon, quantizedBold) end
        end

        local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
        for _, polygon in ipairs(polygons) do
            for _, point in ipairs(polygon) do
                if point[1] < minX then minX = point[1] end
                if point[1] > maxX then maxX = point[1] end
                if point[2] < minY then minY = point[2] end
                if point[2] > maxY then maxY = point[2] end
            end
        end

        local gridMinX = math.floor((minX * quantizedScale) / SS) * SS
        local gridMaxX = math.ceil((maxX * quantizedScale) / SS) * SS
        local gridMinY = math.floor((minY * quantizedScale) / SS) * SS
        local gridMaxY = math.ceil((maxY * quantizedScale) / SS) * SS
        local width, height = gridMaxX - gridMinX, gridMaxY - gridMinY
        if width <= 0 or height <= 0 then
            cacheGlyph(cacheKey, false)
            return nil
        end

        local edges = {}
        for _, polygon in ipairs(polygons) do
            for pointIndex = 1, #polygon do
                local nextIndex = pointIndex % #polygon + 1
                edges[#edges + 1] = {
                    polygon[pointIndex][1] * quantizedScale - gridMinX,
                    polygon[pointIndex][2] * quantizedScale - gridMinY,
                    polygon[nextIndex][1] * quantizedScale - gridMinX,
                    polygon[nextIndex][2] * quantizedScale - gridMinY,
                }
            end
        end

        local supersampleArea = SS * SS
        local outputWidth, outputHeight = width / SS, height / SS
        local sampleRows = {}
        for sampleY = 0, height - 1 do
            local scanY = sampleY + 0.5
            local crossings = {}
            for _, edge in ipairs(edges) do
                local y1, y2 = edge[2], edge[4]
                local low, high = math.min(y1, y2), math.max(y1, y2)
                if scanY > low and scanY <= high then
                    local ratio = (scanY - y1) / (y2 - y1)
                    crossings[#crossings + 1] = edge[1] + (edge[3] - edge[1]) * ratio
                end
            end
            if #crossings >= 2 then
                table.sort(crossings)
                local row = {}
                for crossingIndex = 1, #crossings - 1, 2 do
                    local firstX = math.max(0, math.floor(crossings[crossingIndex] + 0.0001))
                    local lastX = math.min(width - 1, math.ceil(crossings[crossingIndex + 1] - 0.0001))
                    for sampleX = firstX, lastX do row[sampleX] = true end
                end
                sampleRows[sampleY + 1] = row
            end
        end

        local runs = {}
        local verticalRuns = {}
        local function appendRowRun(rowRuns, firstX, lastX, coverage)
            if firstX then
                rowRuns[#rowRuns + 1] = {
                    x = firstX,
                    width = lastX - firstX + 1,
                    coverage = coverage,
                }
            end
        end

        for pixelY = 0, outputHeight - 1 do
            local rowRuns = {}
            local runX, runLastX, runCoverage = nil, nil, nil
            for pixelX = 0, outputWidth - 1 do
                local coverage = 0
                for sampleOffsetY = 1, SS do
                    local row = sampleRows[pixelY * SS + sampleOffsetY]
                    if row then
                        for sampleOffsetX = 0, SS - 1 do
                            if row[pixelX * SS + sampleOffsetX] then coverage = coverage + 1 end
                        end
                    end
                end

                if coverage / supersampleArea >= MIN_ALPHA then
                    if runX and pixelX == runLastX + 1 and coverage == runCoverage then
                        runLastX = pixelX
                    else
                        appendRowRun(rowRuns, runX, runLastX, runCoverage)
                        runX, runLastX, runCoverage = pixelX, pixelX, coverage
                    end
                else
                    appendRowRun(rowRuns, runX, runLastX, runCoverage)
                    runX, runLastX, runCoverage = nil, nil, nil
                end
            end
            appendRowRun(rowRuns, runX, runLastX, runCoverage)

            local nextVerticalRuns = {}
            for _, rowRun in ipairs(rowRuns) do
                local key = rowRun.x .. ":" .. rowRun.width .. ":" .. rowRun.coverage
                local run = verticalRuns[key]
                if run and run.y + run.height == pixelY then
                    run.height = run.height + 1
                else
                    run = {
                        x = rowRun.x,
                        y = pixelY,
                        width = rowRun.width,
                        height = 1,
                        alpha = rowRun.coverage / supersampleArea,
                    }
                    runs[#runs + 1] = run
                end
                nextVerticalRuns[key] = run
            end
            verticalRuns = nextVerticalRuns
        end

        local entry = {
            runs = runs,
            gridMinX = gridMinX,
            gridMinY = gridMinY,
        }
        stats.GlyphsRasterized = stats.GlyphsRasterized + 1
        cacheGlyph(cacheKey, entry)
        return entry
    end

    -- ---------- font object ----------
    local Font = {}
    Font.UnitsPerEm = unitsPerEm
    Font.Ascender = ascender
    Font.Descender = descender
    Font.NumGlyphs = numGlyphs
    Font.Supersample = SS
    Font.SupportsUnicode = #cmap12Groups > 0
    Font.SupportsGPOS = tables["GPOS"] ~= nil
    Font.SupportsKerning = tables["GPOS"] ~= nil or tables["kern"] ~= nil
    Font.Source = fontLabel

    local draws, drawIndices = {}, {}
    local handles = {}
    local layoutCache, layoutCacheQueue = {}, {}
    local MAX_LAYOUT_CACHE = config.MaxLayoutCacheEntries or 2048
    local bitmapCache, bitmapCacheQueue = {}, {}
    local MAX_BITMAP_CACHE = config.MaxBitmapCacheEntries or 512
    local runCache, runCacheQueue = {}, {}
    local MAX_RUN_CACHE = config.MaxRunCacheEntries or 1024

    local function newSquare()
        local sq = Drawing.new("Square")
        sq.Visible = false
        sq.Filled = true
        sq.Thickness = 1
        draws[#draws + 1] = sq
        drawIndices[sq] = #draws
        stats.DrawingsCreated = stats.DrawingsCreated + 1
        return sq
    end

    local function removeSquare(square)
        local index = drawIndices[square]
        if not index then return end
        pcall(function() square:Remove() end)
        local last = draws[#draws]
        draws[index] = last
        draws[#draws] = nil
        drawIndices[square] = nil
        if last and last ~= square then drawIndices[last] = index end
    end

    local function setSquare(square, px, py, width, height, color, alpha, visible)
        square.Position = Vector2.new(px, py)
        square.Size = Vector2.new(width, height)
        square.Color = color
        square.Transparency = alpha
        square.Visible = visible
    end

    local function resolveBaseline(originY, size, vAlign, boxHeight)
        local scale = size / unitsPerEm
        if vAlign == "Top" then
            return originY + ascender * scale + yOffset
        elseif vAlign == "Center" then
            local lineH = (ascender - descender) * scale
            return originY + (boxHeight or lineH) / 2 + ascender * scale - lineH / 2 + centerBias * size + yOffset
        elseif vAlign == "Bottom" then
            return originY + (boxHeight or (ascender - descender) * scale) + descender * scale + yOffset
        end
        return originY + yOffset
    end

    local function cacheLayout(key, layout)
        layoutCache[key] = layout
        layoutCacheQueue[#layoutCacheQueue + 1] = key
        if MAX_LAYOUT_CACHE > 0 and #layoutCacheQueue > MAX_LAYOUT_CACHE then
            local oldest = table.remove(layoutCacheQueue, 1)
            layoutCache[oldest] = nil
        end
    end

    local function buildLayout(str, size, opts)
        local weight = opts.Embolden or opts.Weight or 0
        local letterSpacing = tonumber(opts.LetterSpacing) or 0
        local cacheKey = str .. "\0" .. tostring(size) .. "\0" .. tostring(weight) .. "\0" .. tostring(letterSpacing)
        local cached = layoutCache[cacheKey]
        if cached then
            stats.LayoutCacheHits = (stats.LayoutCacheHits or 0) + 1
            return cached
        end
        stats.LayoutCacheMisses = (stats.LayoutCacheMisses or 0) + 1

        local scale = size / unitsPerEm
        local emboldenUnits = (weight * 0.5) * (unitsPerEm / size)
        local codepoints, byteEnds = decodeUtf8(str)
        local glyphs, advanceEnds = {}, {}
        local penX = 0
        local previousGlyph = nil
        for index, codepoint in ipairs(codepoints) do
            local gid = mapCodepoint(codepoint)
            if previousGlyph then penX = penX + letterSpacing end
            penX = penX + kerning(previousGlyph, gid) * scale
            glyphs[index] = { gid = gid, x = penX }
            penX = penX + ((advances[gid] or 0) + emboldenUnits * 1.5) * scale
            advanceEnds[index] = penX
            previousGlyph = gid
        end
        local layout = {
            glyphs = glyphs,
            byteEnds = byteEnds,
            advanceEnds = advanceEnds,
            width = penX,
            scale = scale,
            supersampleScale = scale * SS,
            emboldenUnits = emboldenUnits,
            letterSpacing = letterSpacing,
        }
        cacheLayout(cacheKey, layout)
        return layout
    end

    -- ---------- cached RGBA PNG text bitmaps ----------
    local crcTable
    local alphaPixels = {}
    for alpha = 0, 255 do
        alphaPixels[alpha] = string.char(255, 255, 255, alpha)
    end

    local function unsigned32(value)
        return value % 4294967296
    end

    local function u32be(value)
        value = unsigned32(value)
        return string.char(
            math.floor(value / 16777216) % 256,
            math.floor(value / 65536) % 256,
            math.floor(value / 256) % 256,
            value % 256
        )
    end

    local function crc32(data)
        if not crcTable then
            assert(bit32, "RBXTTF: bit32 is required for PNG encoding")
            crcTable = {}
            for value = 0, 255 do
                local crc = value
                for _ = 1, 8 do
                    if bit32.band(crc, 1) == 1 then
                        crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
                    else
                        crc = bit32.rshift(crc, 1)
                    end
                end
                crcTable[value] = crc
            end
        end

        local crc = 0xFFFFFFFF
        for index = 1, #data do
            local lookup = bit32.band(bit32.bxor(crc, string.byte(data, index)), 0xFF)
            crc = bit32.bxor(bit32.rshift(crc, 8), crcTable[lookup])
        end
        return unsigned32(bit32.bxor(crc, 0xFFFFFFFF))
    end

    local function adler32(data)
        local first, second = 1, 0
        for index = 1, #data do
            first = (first + string.byte(data, index)) % 65521
            second = (second + first) % 65521
        end
        return second * 65536 + first
    end

    local function pngChunk(kind, data)
        return u32be(#data) .. kind .. data .. u32be(crc32(kind .. data))
    end

    local function storeDeflate(data)
        local chunks = { string.char(0x78, 0x01) }
        local offset = 1
        while offset <= #data do
            local length = math.min(65535, #data - offset + 1)
            local inverse = 65535 - length
            local final = offset + length > #data and 1 or 0
            chunks[#chunks + 1] = string.char(
                final,
                length % 256,
                math.floor(length / 256),
                inverse % 256,
                math.floor(inverse / 256)
            )
            chunks[#chunks + 1] = string.sub(data, offset, offset + length - 1)
            offset = offset + length
        end
        chunks[#chunks + 1] = u32be(adler32(data))
        return table.concat(chunks)
    end

    local function encodeAlphaPng(width, height, rows)
        local scanlines = {}
        for y = 1, height do
            local row = rows[y]
            local pixels = { string.char(0) }
            for x = 1, width do
                pixels[#pixels + 1] = alphaPixels[row and row[x] or 0]
            end
            scanlines[#scanlines + 1] = table.concat(pixels)
        end
        local raw = table.concat(scanlines)
        local header = u32be(width) .. u32be(height) .. string.char(8, 6, 0, 0, 0)
        return "\137PNG\13\10\26\10"
            .. pngChunk("IHDR", header)
            .. pngChunk("IDAT", storeDeflate(raw))
            .. pngChunk("IEND", "")
    end

    local function cacheBitmap(key, bitmap)
        bitmapCache[key] = bitmap
        bitmapCacheQueue[#bitmapCacheQueue + 1] = key
        if MAX_BITMAP_CACHE > 0 and #bitmapCacheQueue > MAX_BITMAP_CACHE then
            local oldest = table.remove(bitmapCacheQueue, 1)
            bitmapCache[oldest] = nil
        end
    end

    local function rasterCacheKey(str, size, width, height, opts)
        return table.concat({
            str,
            tostring(size),
            tostring(width),
            tostring(height),
            opts.XAlign or "Left",
            opts.VAlign or "Center",
            tostring(tonumber(opts.LetterSpacing) or 0),
            tostring(tonumber(opts.Embolden or opts.Weight) or 0),
        }, "\0")
    end

    local function cacheRuns(key, raster)
        runCache[key] = raster
        runCacheQueue[#runCacheQueue + 1] = key
        if MAX_RUN_CACHE > 0 and #runCacheQueue > MAX_RUN_CACHE then
            local oldest = table.remove(runCacheQueue, 1)
            runCache[oldest] = nil
        end
    end

    function Font:RasterizeRuns(str, size, width, height, opts)
        str = tostring(str or "")
        opts = opts or {}
        width = math.max(1, math.floor((width or 1) + 0.5))
        height = math.max(1, math.floor((height or size or 1) + 0.5))

        local xAlign = opts.XAlign or "Left"
        local vAlign = opts.VAlign or "Center"
        local letterSpacing = tonumber(opts.LetterSpacing) or 0
        local weight = tonumber(opts.Embolden or opts.Weight) or 0
        local cacheKey = rasterCacheKey(str, size, width, height, opts)
        local cached = runCache[cacheKey]
        if cached then
            stats.RunCacheHits = (stats.RunCacheHits or 0) + 1
            return cached
        end
        stats.RunCacheMisses = (stats.RunCacheMisses or 0) + 1

        local layout = buildLayout(str, size, {
            LetterSpacing = letterSpacing,
            Weight = weight,
        })
        local originX = 0
        if xAlign == "Center" then
            originX = (width - layout.width) / 2
        elseif xAlign == "Right" then
            originX = width - layout.width
        end

        local lineHeight = (ascender - descender) * layout.scale
        local baseline
        if vAlign == "Top" then
            baseline = ascender * layout.scale
        elseif vAlign == "Bottom" then
            baseline = height + descender * layout.scale
        else
            baseline = height / 2 + ascender * layout.scale - lineHeight / 2 + centerBias * size
        end

        local runs = {}
        for _, glyph in ipairs(layout.glyphs) do
            local raster = rasterizeGlyph(glyph.gid, layout.supersampleScale, layout.emboldenUnits)
            if raster then
                local left = math.floor(originX + glyph.x + raster.gridMinX / SS + 0.5)
                local basePixelY = math.floor(baseline - raster.gridMinY / SS + 0.5)
                for _, run in ipairs(raster.runs) do
                    local firstX = math.max(0, left + run.x)
                    local lastX = math.min(width - 1, left + run.x + run.width - 1)
                    local top = basePixelY - run.y - run.height
                    local firstY = math.max(0, top)
                    local lastY = math.min(height - 1, top + run.height - 1)
                    if firstX <= lastX and firstY <= lastY and run.alpha > 0 then
                        runs[#runs + 1] = {
                            X = firstX,
                            Y = firstY,
                            Width = lastX - firstX + 1,
                            Height = lastY - firstY + 1,
                            Alpha = run.alpha,
                        }
                    end
                end
            end
        end

        local result = {
            Runs = runs,
            Width = width,
            Height = height,
            TextWidth = layout.width,
            Key = cacheKey,
        }
        cacheRuns(cacheKey, result)
        return result
    end

    function Font:RasterizeText(str, size, width, height, opts)
        opts = opts or {}
        local raster = self:RasterizeRuns(str, size, width, height, opts)
        local padding = math.max(0, math.floor(tonumber(opts.Padding) or 0))
        local cacheKey = "png\0" .. raster.Key .. "\0" .. tostring(padding)
        local cached = bitmapCache[cacheKey]
        if cached then
            stats.BitmapCacheHits = stats.BitmapCacheHits + 1
            return cached
        end
        stats.BitmapCacheMisses = stats.BitmapCacheMisses + 1

        local rows = {}
        for _, run in ipairs(raster.Runs) do
            local alpha = math.clamp(math.floor(run.Alpha * 255 + 0.5), 0, 255)
            for y = run.Y + padding, run.Y + padding + run.Height - 1 do
                local row = rows[y + 1]
                if not row then
                    row = {}
                    rows[y + 1] = row
                end
                for x = run.X + padding, run.X + padding + run.Width - 1 do
                    local index = x + 1
                    if alpha > (row[index] or 0) then row[index] = alpha end
                end
            end
        end

        local bitmap = {
            Data = encodeAlphaPng(raster.Width + padding * 2, raster.Height + padding * 2, rows),
            Width = raster.Width + padding * 2,
            Height = raster.Height + padding * 2,
            TextWidth = raster.TextWidth,
            Key = raster.Key,
            Padding = padding,
        }
        stats.BitmapsEncoded = stats.BitmapsEncoded + 1
        cacheBitmap(cacheKey, bitmap)
        return bitmap
    end

    local function emitText(str, size, originX, originY, opts, emit)
        local layout = buildLayout(str, size, opts)
        local color = opts.Color or Color3.new(1, 1, 1)
        local alpha = opts.Alpha ~= nil and opts.Alpha or 1
        originY = originY * yScale + yScaleB
        local baseY = resolveBaseline(originY, size, opts.VAlign, opts.BoxHeight)

        for _, glyph in ipairs(layout.glyphs) do
            local raster = rasterizeGlyph(glyph.gid, layout.supersampleScale, layout.emboldenUnits)
            if raster then
                local left = math.floor(originX + glyph.x + raster.gridMinX / SS + 0.5)
                local basePixelY = math.floor(baseY - raster.gridMinY / SS + 0.5)
                for _, run in ipairs(raster.runs) do
                    emit(
                        left + run.x,
                        basePixelY - run.y - run.height,
                        run.width,
                        run.height,
                        color,
                        run.alpha * alpha,
                        run.alpha
                    )
                end
            end
        end
        return layout.width
    end

    function Font:Measure(str, size, opts)
        return buildLayout(tostring(str or ""), size, opts or {}).width
    end

    function Font:GetGlyphIndex(value)
        local codepoint = tonumber(value)
        if not codepoint then
            local decoded = decodeUtf8(tostring(value or ""))
            codepoint = decoded[1]
        end
        return codepoint and mapCodepoint(codepoint) or 0
    end

    function Font:HasGlyph(value)
        return self:GetGlyphIndex(value) ~= 0
    end

    function Font:GetMetrics()
        return {
            UnitsPerEm = unitsPerEm,
            Ascender = ascender,
            Descender = descender,
            NumGlyphs = numGlyphs,
            Supersample = SS,
            SupportsUnicode = self.SupportsUnicode,
            SupportsGPOS = self.SupportsGPOS,
            SupportsKerning = self.SupportsKerning,
        }
    end

    function Font:Truncate(str, size, maxWidth, opts, ellipsis)
        str = tostring(str or "")
        opts = opts or {}
        ellipsis = ellipsis or "..."
        local layout = buildLayout(str, size, opts)
        if layout.width <= maxWidth then return str, layout.width end

        local ellipsisLayout = buildLayout(ellipsis, size, opts)
        if ellipsisLayout.width > maxWidth then return "", 0 end
        local firstEllipsisGlyph = ellipsisLayout.glyphs[1] and ellipsisLayout.glyphs[1].gid
        for index = #layout.glyphs, 1, -1 do
            local endWidth = layout.advanceEnds[index]
            if firstEllipsisGlyph then
                endWidth = endWidth + layout.letterSpacing
                    + kerning(layout.glyphs[index].gid, firstEllipsisGlyph) * layout.scale
            end
            local width = endWidth + ellipsisLayout.width
            if width <= maxWidth then
                return string.sub(str, 1, layout.byteEnds[index]) .. ellipsis, width
            end
        end
        return ellipsis, ellipsisLayout.width
    end

    function Font:Draw(str, size, originX, originY, opts)
        opts = opts or {}
        return emitText(tostring(str or ""), size, originX, originY, opts, function(px, py, width, height, color, alpha)
            local square = newSquare()
            setSquare(square, px, py, width, height, color, alpha, true)
        end)
    end

    local TextHandle = {}
    TextHandle.__index = TextHandle

    local function applyHandleSquare(handle, index)
        local square = handle._squares[index]
        local px = handle._runX[index]
        local py = handle._runY[index]
        local width = handle._runWidth[index]
        local height = handle._runHeight[index]
        local clip = handle._clipRect
        if clip then
            local right = math.min(px + width, clip.MaxX)
            local bottom = math.min(py + height, clip.MaxY)
            px = math.max(px, clip.MinX)
            py = math.max(py, clip.MinY)
            width = right - px
            height = bottom - py
        end
        if width <= 0 or height <= 0 then
            square.Visible = false
            return
        end
        square.Position = Vector2.new(px, py)
        square.Size = Vector2.new(width, height)
        square.Visible = handle._visible
    end

    function TextHandle:Update(str, size, originX, originY, opts)
        assert(not self._destroyed, "RBXTTF: text handle is destroyed")
        opts = opts or self._options or {}
        self._options = opts
        self._originX, self._originY = originX, originY
        self._color = opts.Color or Color3.new(1, 1, 1)
        self._alpha = opts.Alpha ~= nil and opts.Alpha or 1
        local activeCount = 0
        local width = emitText(tostring(str or ""), size, originX, originY, opts, function(px, py, runWidth, runHeight, color, alpha, coverage)
            activeCount = activeCount + 1
            local square = self._squares[activeCount]
            if not square then
                square = newSquare()
                self._squares[activeCount] = square
            else
                stats.DrawingsReused = stats.DrawingsReused + 1
            end
            self._coverage[activeCount] = coverage
            self._runX[activeCount] = px
            self._runY[activeCount] = py
            self._runWidth[activeCount] = runWidth
            self._runHeight[activeCount] = runHeight
            square.Color = color
            square.Transparency = alpha
            applyHandleSquare(self, activeCount)
        end)
        for index = activeCount + 1, self._activeCount do
            self._squares[index].Visible = false
        end
        self._activeCount = activeCount
        self.Width = width
        return width
    end

    function TextHandle:MoveTo(originX, originY)
        assert(not self._destroyed, "RBXTTF: text handle is destroyed")
        local deltaX = originX - self._originX
        local deltaY = (originY - self._originY) * yScale
        self._originX, self._originY = originX, originY
        if deltaX == 0 and deltaY == 0 then return end
        local delta = Vector2.new(deltaX, deltaY)
        for index = 1, self._activeCount do
            self._runX[index] = self._runX[index] + deltaX
            self._runY[index] = self._runY[index] + deltaY
            if self._clipRect then
                applyHandleSquare(self, index)
            else
                local square = self._squares[index]
                square.Position = square.Position + delta
            end
        end
        stats.HandleMoves = stats.HandleMoves + 1
    end

    function TextHandle:Translate(deltaX, deltaY)
        local sourceDeltaY = yScale ~= 0 and deltaY / yScale or 0
        self:MoveTo(self._originX + deltaX, self._originY + sourceDeltaY)
    end

    function TextHandle:SetColor(color)
        assert(not self._destroyed, "RBXTTF: text handle is destroyed")
        self._color = color
        self._options.Color = color
        for index = 1, self._activeCount do self._squares[index].Color = color end
    end

    function TextHandle:SetAlpha(alpha)
        assert(not self._destroyed, "RBXTTF: text handle is destroyed")
        self._alpha = alpha
        self._options.Alpha = alpha
        for index = 1, self._activeCount do
            self._squares[index].Transparency = self._coverage[index] * alpha
        end
    end

    function TextHandle:SetVisible(visible)
        assert(not self._destroyed, "RBXTTF: text handle is destroyed")
        self._visible = visible ~= false
        for index = 1, self._activeCount do
            if self._visible and self._clipRect then
                applyHandleSquare(self, index)
            else
                self._squares[index].Visible = self._visible
            end
        end
    end

    function TextHandle:SetClipRect(minX, minY, maxX, maxY)
        assert(not self._destroyed, "RBXTTF: text handle is destroyed")
        local nextMinY
        local nextMaxY
        if minX ~= nil and minY ~= nil and maxX ~= nil and maxY ~= nil then
            nextMinY = minY * yScale + yScaleB + yOffset
            nextMaxY = maxY * yScale + yScaleB + yOffset
        end
        local current = self._clipRect
        if current == nil and nextMinY == nil then return end
        if current and nextMinY
            and current.MinX == minX
            and current.MinY == nextMinY
            and current.MaxX == maxX
            and current.MaxY == nextMaxY then
            return
        end
        self._clipRect = nextMinY and {
            MinX = minX,
            MinY = nextMinY,
            MaxX = maxX,
            MaxY = nextMaxY,
        } or nil
        for index = 1, self._activeCount do
            applyHandleSquare(self, index)
        end
    end

    function TextHandle:GetDraws()
        return self._squares, self._activeCount
    end

    function TextHandle:Destroy()
        if self._destroyed then return end
        self._destroyed = true
        handles[self] = nil
        for _, square in ipairs(self._squares) do removeSquare(square) end
        self._squares, self._coverage, self._activeCount = {}, {}, 0
        self._runX, self._runY, self._runWidth, self._runHeight = {}, {}, {}, {}
    end

    function Font:CreateText(str, size, originX, originY, opts)
        local handle = setmetatable({
            _squares = {},
            _coverage = {},
			_runX = {},
			_runY = {},
			_runWidth = {},
			_runHeight = {},
            _activeCount = 0,
            _originX = originX,
            _originY = originY,
            _options = opts or {},
            _visible = true,
            _destroyed = false,
            Width = 0,
        }, TextHandle)
        handles[handle] = true
        handle:Update(str, size, originX, originY, opts or {})
        return handle
    end

    function Font:Draws()
        return draws
    end

    function Font:Clear()
        local activeHandles = {}
        for handle in pairs(handles) do activeHandles[#activeHandles + 1] = handle end
        for _, handle in ipairs(activeHandles) do handle:Destroy() end
        while #draws > 0 do removeSquare(draws[#draws]) end
    end

    function Font:ClearCache()
        glyphCache, glyphCacheQueue = {}, {}
        layoutCache, layoutCacheQueue = {}, {}
        bitmapCache, bitmapCacheQueue = {}, {}
        runCache, runCacheQueue = {}, {}
        polygonCache = {}
    end

    function Font:Stats()
        local snapshot = {}
        for key, value in pairs(stats) do snapshot[key] = value end
        local handleCount = 0
        for _ in pairs(handles) do handleCount = handleCount + 1 end
        snapshot.ActiveHandles = handleCount
        snapshot.GlyphCacheEntries = #glyphCacheQueue
        snapshot.LayoutCacheEntries = #layoutCacheQueue
        snapshot.BitmapCacheEntries = #bitmapCacheQueue
        snapshot.RunCacheEntries = #runCacheQueue
        snapshot.TrackedDrawings = #draws
        return snapshot
    end

    function Font:Destroy()
        self:Clear()
    end

    return Font
end
