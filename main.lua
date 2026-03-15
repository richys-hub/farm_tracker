local api = require("api")

local addon = {
    name    = "Farm Tracker",
    author  = "Patricia",
    desc    = "Track entity timers gathered from mouseover.",
    version = "1.0.0",
}

-- ============================================================
-- CONSTANTS
-- ============================================================

local SETTINGS_FILE     = "farm_tracker/settings.lua"
local ALL_FARMS_FILE    = "farm_tracker/farms_data.lua"

local MAIN_W, MAIN_H     = 600, 450
local DETAIL_W, DETAIL_H = 600, 420
local POPUP_W, POPUP_H   = 280, 130

-- Detail window layout
local DETAIL_LIST_Y        = 66   -- top of doodad list content
local DETAIL_ROWS_PER_PAGE = 10

-- ============================================================
-- STATE
-- ============================================================

local farms    = {}
local settings = { whitelist = {}, groupBy = "name" }

-- Main window
local mainWin
local addFarmPopup
local mainListContent
local mainListRows      = {}
local mainListRebuildId = 0
local currentPage       = 1
local ROWS_PER_PAGE     = 7
local filterText        = ""
local filterDebounce    = false

-- Detail window
local detailWin
local detailFarmId    = nil
local detailPage      = 1
local detailRebuildId = 0
local detailTimeLbls  = {}
local expandedGroups  = {}  -- keyed by group key, bool
local lastDoodadInfo  = nil
local doodadListener  = nil

-- Filter window (per-farm)
local filterWin       = nil
local filterRebuildId = 0
local filterPlayerPage = 1
local filterEntityPage = 1

-- Settings window
local settingsWin     = nil
local floatingBtn     = nil
local floatingBtnSeq  = 0


-- ============================================================
-- UTILITY
-- ============================================================

local zone_name_list = (function()
    local ok, z = pcall(require, "farm_tracker/zone_name_list")
    return (ok and z) or {}
end)()

local function zoneName(id)
    local n = tonumber(id)
    if not n then return "Unknown" end
    local name = zone_name_list[n]
    if type(name) == "string" and name ~= "" then return name end
    return "Zone " .. tostring(n)
end

local function newId()
    return "farm_" .. tostring(api.Time:GetUiMsec()):gsub("%.", "")
end

local function log(msg)
    if api and api.Log and api.Log.Info then
        api.Log:Info("[FarmTracker] " .. tostring(msg))
    end
end

-- ============================================================
-- SEXTANT PARSING
-- ============================================================

local function parsePlayerSextants()
    local ok, r1, r2, r3, r4, r5, r6, r7, r8 = pcall(api.Map.GetPlayerSextants, api.Map)
    if not ok then return nil end
    if type(r1) == "table" and r2 == nil then
        local t = r1
        if t.longitude or t.deg_long then
            return t.longitude or "E", tonumber(t.deg_long) or 0, tonumber(t.min_long) or 0, tonumber(t.sec_long) or 0,
                   t.latitude  or "N", tonumber(t.deg_lat)  or 0, tonumber(t.min_lat)  or 0, tonumber(t.sec_lat)  or 0
        end
        if type(t.longitude) == "table" and type(t.latitude) == "table" then
            local L, A = t.longitude, t.latitude
            return L.dir or "E", tonumber(L.deg) or 0, tonumber(L.min) or 0, tonumber(L.sec) or 0,
                   A.dir or "N", tonumber(A.deg) or 0, tonumber(A.min) or 0, tonumber(A.sec) or 0
        end
        if t.longitudeDir then
            return t.longitudeDir or "E", tonumber(t.longitudeDeg) or 0, tonumber(t.longitudeMin) or 0, tonumber(t.longitudeSec) or 0,
                   t.latitudeDir  or "N", tonumber(t.latitudeDeg)  or 0, tonumber(t.latitudeMin)  or 0, tonumber(t.latitudeSec)  or 0
        end
        if type(t[1]) == "string" and type(t[2]) == "number" then
            return t[1], tonumber(t[2]) or 0, tonumber(t[3]) or 0, tonumber(t[4]) or 0,
                   t[5], tonumber(t[6]) or 0, tonumber(t[7]) or 0, tonumber(t[8]) or 0
        end
        return nil
    end
    if type(r1) == "string" and type(r2) == "number" and type(r5) == "string" and type(r6) == "number" then
        return r1, tonumber(r2) or 0, tonumber(r3) or 0, tonumber(r4) or 0,
               r5, tonumber(r6) or 0, tonumber(r7) or 0, tonumber(r8) or 0
    end
    return nil
end

local function dmsToSigned(dir, d, m, s)
    local val = (tonumber(d) or 0) + ((tonumber(m) or 0) / 60) + ((tonumber(s) or 0) / 3600)
    if dir == "W" or dir == "S" then val = -val end
    return val
end

local _coef = 0.00097657363894522145695357130138029
local function lonLatToWorldXY(lon, lat)
    return (lon + 21) / _coef, (lat + 28) / _coef
end

local function capturePlayerPosition()
    local ew, ld, lm, ls, ns, pd, pm, ps = parsePlayerSextants()
    if not ew then return nil end
    local lon = dmsToSigned(ew, ld, lm, ls)
    local lat = dmsToSigned(ns, pd, pm, ps)
    local wx, wy = lonLatToWorldXY(lon, lat)
    local ok, ax, ay, az = pcall(api.Unit.UnitWorldPosition, api.Unit, "player")
    if not ok then ax, ay, az = 0, 0, 0 end
    if type(ax) == "table" then ax, ay, az = ax.x or ax[1] or 0, ax.y or ax[2] or 0, ax.z or ax[3] or 0 end
    local wz = (tonumber(az) or 0) - 1.4
    local zoneGroup = (pcall(api.Unit.GetCurrentZoneGroup, api.Unit) and api.Unit:GetCurrentZoneGroup()) or 0
    local sext = string.format("%s %d° %d' %d\", %s %d° %d' %d\"", ew, ld, lm, ls, ns, pd, pm, ps)
    return { sextants=sext, worldX=wx, worldY=wy, worldZ=wz, zone=zoneGroup }
end

-- ============================================================
-- FILE I/O
-- ============================================================

local function loadSettings()
    local s = api.File:Read(SETTINGS_FILE)
    if type(s) == "table" then
        settings = s
        if not settings.groupBy         then settings.groupBy = "name" end
        if not settings.scanModifier    then settings.scanModifier = "any" end
        if settings.showFloatingBtn == nil then settings.showFloatingBtn = false end
        if not settings.floatingBtnX    then settings.floatingBtnX = 200 end
        if not settings.floatingBtnY    then settings.floatingBtnY = 200 end
    end
end

local function saveSettings()
    api.File:Write(SETTINGS_FILE, settings)
end

local function saveAllFarmsData()
    api.File:Write(ALL_FARMS_FILE, farms)
end

local function saveFarm(farm)
    local found = false
    for i, f in ipairs(farms) do
        if f.id == farm.id then farms[i] = farm; found = true; break end
    end
    if not found then table.insert(farms, farm) end
    saveAllFarmsData()
end

local function loadAllFarms()
    farms = {}
    local data = api.File:Read(ALL_FARMS_FILE)
    if type(data) == "table" then
        for i = #data, 1, -1 do
            local f = data[i]
            if type(f) == "table" and f.id then
                table.insert(farms, f)
            end
        end
    end
end

local function createFarm(name, posData)
    local id = newId()
    local farm = {
        id=id, name=name,
        zone     = posData and posData.zone     or 0,
        sextants = posData and posData.sextants or "",
        worldX   = posData and posData.worldX   or 0,
        worldY   = posData and posData.worldY   or 0,
        worldZ   = posData and posData.worldZ   or 0,
        needsPost=false, doodads={},
    }
    table.insert(farms, 1, farm)
    saveAllFarmsData()
    return farm
end

local function deleteFarm(farmId)
    for i, f in ipairs(farms) do
        if f.id == farmId then table.remove(farms, i); break end
    end
    saveAllFarmsData()
end

local function getFarmById(farmId)
    for _, f in ipairs(farms) do
        if f.id == farmId then return f end
    end
    return nil
end

-- ============================================================
-- DOODAD HELPERS
-- ============================================================

local function formatTime(secs)
    if secs <= 0 then
        local ago = math.abs(secs)
        if ago < 60 then return string.format("Done - %ds ago", ago) end
        local d = math.floor(ago / 86400)
        local h = math.floor((ago % 86400) / 3600)
        local m = math.floor((ago % 3600) / 60)
        if d > 0 then return string.format("Done - %dd %dh ago", d, h) end
        if h > 0 then return string.format("Done - %dh %dm ago", h, m) end
        return string.format("Done - %dm ago", m)
    end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if d > 0 then return string.format("%dd %dh %dm %ds", d, h, m, s) end
    if h > 0 then return string.format("%dh %dm %ds", h, m, s) end
    if m > 0 then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

-- Convert a calendar date to Unix timestamp (seconds since 1970-01-01 UTC)
local function dateToUnix(year, month, day, hour, min, sec)
    -- Days in each month (non-leap)
    local days_in_month = {31,28,31,30,31,30,31,31,30,31,30,31}
    local function isLeap(y)
        return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
    end
    -- Count days from epoch to start of year
    local days = 0
    for y = 1970, year - 1 do
        days = days + (isLeap(y) and 366 or 365)
    end
    -- Add days for months in current year
    for m = 1, month - 1 do
        days = days + days_in_month[m]
        if m == 2 and isLeap(year) then days = days + 1 end
    end
    -- Add days in current month
    days = days + (day - 1)
    return days * 86400 + hour * 3600 + min * 60 + sec
end

-- UTC offset hardcoded to -4 (EDT). TimeToDate returns local time.
local utcOffset = 5 * 3600

local function nowUnix()
    local t = api.Time:TimeToDate(api.Time:GetLocalTime())
    return dateToUnix(t.year, t.month, t.day, t.hour, t.minute, t.second) + utcOffset
end

-- Convert a TimeToDate table to total seconds (day*86400 + h*3600 + m*60 + s)
local function timeToSecs(t)
    return (t.day or 0)*86400 + (t.hour or 0)*3600 + (t.minute or 0)*60 + (t.second or 0)
end

-- Add displayTime seconds to a {day,hour,min,sec} table, returns new components
local function addSeconds(t, secs)
    local s = t.sec + secs
    local m = t.min + math.floor(s / 60)
    s = s % 60
    local h = t.hour + math.floor(m / 60)
    m = m % 60
    local d = t.day + math.floor(h / 24)
    h = h % 24
    return { day=d, hour=h, min=m, sec=math.floor(s) }
end

local adjustedTime  -- forward declaration

-- Convert expiry components to Unix timestamp using current time as anchor
-- adjustedTime() tells us seconds until expiry; add that to current Unix time
local function expiryToUnix(entry)
    if entry.expiryUnix then
        return tonumber(entry.expiryUnix)
    end
    -- Legacy fallback
    local remaining = adjustedTime and adjustedTime(entry) or 0
    return math.floor(nowUnix() + remaining)
end

-- Write a share file for the discord bot
local function writeShareFile(farm)
    local groupOrder, groups = {}, {}
    for _, d in ipairs(farm.doodads or {}) do
        local k = d.name
        if not groups[k] then
            groups[k] = { name=d.name, entries={} }
            table.insert(groupOrder, k)
        end
        table.insert(groups[k].entries, d)
    end

    local playerName = api.Unit:GetUnitNameById(api.Unit:GetUnitId("player")) or "Unknown"
    local lines = {}
    table.insert(lines, string.format("🌿 **%s** | %s", farm.name or "Farm", zoneName(farm.zone)))
    table.insert(lines, string.format("📍 %s", farm.sextants or ""))
    table.insert(lines, string.format("Posted by: %s", playerName))
    table.insert(lines, "")

    -- Helper: format an expiry component table as a date tag for the bot to convert
    local function expiryTag(e)
        return string.format("[expiry:%04d-%02d-%02d %02d:%02d:%02d EDT]",
            e.year or 2026, e.month or 1, e.day or 1,
            e.hour or 0,    e.min  or 0,  e.sec  or 0)
    end

    for idx, k in ipairs(groupOrder) do
        local g = groups[k]
        local earliest, latest
        local owners = {}
        local ownerSet = {}
        for _, d in ipairs(g.entries) do
            local ex = d.expiry
            local secs = (ex.day or 0)*86400 + (ex.hour or 0)*3600 + (ex.min or 0)*60 + (ex.sec or 0)
            if not earliest or secs < earliest.secs then earliest = { secs=secs, expiry=ex } end
            if not latest   or secs > latest.secs   then latest   = { secs=secs, expiry=ex } end
            local o = (d.owner and d.owner ~= "") and d.owner or "No Owner"
            if not ownerSet[o] then ownerSet[o] = true; table.insert(owners, o) end
        end
        local ownerStr = table.concat(owners, ", ")

        if expandedGroups[k] and #g.entries > 1 then
            -- Post individual timers inline, sorted by time ascending
            local sorted = {}
            for _, d in ipairs(g.entries) do
                local ex = d.expiry
                local secs = (ex.day or 0)*86400 + (ex.hour or 0)*3600 + (ex.min or 0)*60 + (ex.sec or 0)
                table.insert(sorted, { d=d, secs=secs })
            end
            table.sort(sorted, function(a, b) return a.secs < b.secs end)
            local timeTags = {}
            for _, s in ipairs(sorted) do
                table.insert(timeTags, expiryTag(s.d.expiry))
            end
            table.insert(lines, string.format("%d. **%s** x%d (%s) — %s",
                idx, g.name, #g.entries, ownerStr, table.concat(timeTags, ", ")))
        elseif #g.entries == 1 then
            table.insert(lines, string.format("%d. **%s** (%s) — %s",
                idx, g.name, ownerStr, expiryTag(earliest.expiry)))
        else
            table.insert(lines, string.format("%d. **%s** x%d (%s) — earliest %s, latest %s",
                idx, g.name, #g.entries, ownerStr,
                expiryTag(earliest.expiry), expiryTag(latest.expiry)))
        end
    end



    local filename = string.format("farm_tracker/share/%s.lua", farm.id or "farm")
    local payload  = { content = table.concat(lines, "\n") }
    local ok, err  = pcall(api.File.Write, api.File, filename, payload)
    if ok then
        log("Share file written: " .. filename)
    else
        log("Failed to write share file: " .. tostring(err))
    end
end

adjustedTime = function(entry)
    if not entry.expiry then return 0 end

    -- UiMsec-based path: sub-second accurate, no drift, valid within a session
    if entry.captureUiMsec and entry.displayTime then
        local nowMs = api.Time:GetUiMsec()
        if nowMs >= entry.captureUiMsec then
            local remainingMs = (entry.captureUiMsec + entry.displayTime * 1000) - nowMs
            return math.ceil(remainingMs / 1000)
        end
        -- UiMsec reset (relog): fall through to expiryUnix path below
    end

    -- Post-relog path: expiryUnix minus current time, 1-second resolution but no drift
    if entry.expiryUnix then
        return tonumber(entry.expiryUnix) - nowUnix()
    end

    -- Legacy entries without expiryUnix: component-based fallback
    local now     = api.Time:TimeToDate(api.Time:GetLocalTime())
    local nowSecs = (now.day or 0)*86400 + (now.hour or 0)*3600
                  + (now.minute or 0)*60  + (now.second or 0)
    local expSecs = (entry.expiry.day or 0)*86400 + (entry.expiry.hour or 0)*3600
                  + (entry.expiry.min or 0)*60    + (entry.expiry.sec or 0)
    return math.floor(expSecs - nowSecs)
end

-- Flat render list: header rows interleaved with their entry rows, grouped
local function buildRenderList(farm)
    local function groupKey(d)
        if settings.groupBy == "name_owner" then
            return d.name .. "\0" .. (d.owner or "")
        end
        return d.name
    end

    local groupOrder = {}
    local groups = {}
    for idx, d in ipairs(farm.doodads or {}) do
        local k = groupKey(d)
        if not groups[k] then
            groups[k] = { name=d.name, owner=d.owner, entries={}, key=k }
            table.insert(groupOrder, k)
        end
        table.insert(groups[k].entries, { entry=d, idx=idx })
    end

    local flat = {}
    for _, k in ipairs(groupOrder) do
        local g = groups[k]
        local earliest, latest
        for _, e in ipairs(g.entries) do
            local t = adjustedTime(e.entry)
            if not earliest or t < earliest then earliest = t end
            if not latest   or t > latest   then latest   = t end
        end
        table.insert(flat, {
            type="header", name=g.name, owner=g.owner,
            qty=#g.entries, earliest=earliest or 0, latest=latest or 0,
            key=k, entries=g.entries,
        })
        -- If expanded, insert individual entry rows sorted by time ascending
        if expandedGroups[k] then
            local sorted = {}
            for _, e in ipairs(g.entries) do
                table.insert(sorted, { entry=e.entry, idx=e.idx, t=adjustedTime(e.entry) })
            end
            table.sort(sorted, function(a, b) return a.t < b.t end)
            for _, s in ipairs(sorted) do
                table.insert(flat, {
                    type="entry", entry=s.entry, t=s.t,
                    owner=s.entry.owner or "", groupKey=k,
                })
            end
        end
    end
    return flat
end

-- Try to add a doodad; returns true if added.
local function tryAddDoodad(farm, info)
    if not info or not info.name then return false end
    local t       = api.Time:TimeToDate(api.Time:GetLocalTime())
    local newTime = info.displayTime or 0
    if newTime <= 0 then return false end

    -- Normalize name: strip everything from the first symbol character onwards
    local function normalizeName(n)
        return (n:match("^([^%(%)%[%]%{%}%:%,%;%/%\\%.%!%?]+)") or n):match("^%s*(.-)%s*$")
    end

    local owner = info.owner or ""
    local name  = normalizeName(info.name)

    -- Ensure per-farm filter lists exist
    if not farm.scanPlayers  then farm.scanPlayers  = {} end
    if not farm.scanEntities then farm.scanEntities = {} end

    local defaultEnabled = farm.scanDefaultEnabled
    if defaultEnabled == nil then defaultEnabled = true end

    local populateFilter = farm.populateFilter
    if populateFilter == nil then populateFilter = true end

    -- Auto-register owner in scanPlayers if new (only if filter is not locked)
    local playerEntry = nil
    for _, e in ipairs(farm.scanPlayers) do
        if e.name:lower() == owner:lower() then playerEntry = e; break end
    end
    if not playerEntry then
        if not populateFilter then return false end
        playerEntry = { name = owner, enabled = true }
        table.insert(farm.scanPlayers, playerEntry)
    end

    -- Auto-register entity name in scanEntities if new (only if filter is not locked)
    local entityEntry = nil
    for _, e in ipairs(farm.scanEntities) do
        if e.name:lower() == name:lower() then entityEntry = e; break end
    end
    if not entityEntry then
        if not populateFilter then return false end
        entityEntry = { name = name, enabled = true }
        table.insert(farm.scanEntities, entityEntry)
    end

    -- Reject if either filter is enabled and the entry is disabled
    local filterPlayers  = farm.filterPlayersEnabled;  if filterPlayers  == nil then filterPlayers  = true end
    local filterEntities = farm.filterEntitiesEnabled; if filterEntities == nil then filterEntities = true end
    if filterPlayers  and not playerEntry.enabled then return false end
    if filterEntities and not entityEntry.enabled then return false end

    -- Dedup
    for _, d in ipairs(farm.doodads or {}) do
        if d.name == name and (d.owner or "") == owner then
            if math.abs(adjustedTime(d) - newTime) < 2 then
                return false
            end
        end
    end

    local expiry = addSeconds({ day=t.day, hour=t.hour, min=t.minute, sec=t.second }, newTime)
    expiry.year  = t.year
    expiry.month = t.month

    -- Build expiryUnix: nowUnix() is accurate, just add the remaining seconds
    local expiryUnixStr = string.format("%d", nowUnix() + newTime)

    local captureMs = api.Time:GetUiMsec() - 500 - 500
    table.insert(farm.doodads, {
        name           = name,
        owner          = owner,
        displayTime    = newTime,
        captureUiMsec  = captureMs,
        expiryUnix     = expiryUnixStr,
        expiry         = expiry,
    })
    saveFarm(farm)
    return true
end

-- ============================================================
-- DETAIL WINDOW
-- ============================================================

local rebuildDoodadList  -- forward declaration
local openFilterWindow   -- forward declaration
local toggleMainWindow   -- forward declaration

local function closeDetailWindow()
    lastDoodadInfo = nil
    if detailWin then detailWin:Show(false) end
    if filterWin then filterWin:Show(false) end
    detailFarmId = nil
end

local detailRebuilding = false
rebuildDoodadList = function()
    if detailRebuilding then return end
    detailRebuilding = true
    local ok, err = pcall(function()
    local farm = detailFarmId and getFarmById(detailFarmId)
    if not farm or not detailWin then return end

    detailRebuildId = detailRebuildId + 1
    local rid = detailRebuildId
    detailTimeLbls = {}

    if detailWin._listContent then detailWin._listContent:Show(false) end

    -- Update Clear button label
    if detailWin._btnReset then
        local hasDone = false
        for _, d in ipairs(farm.doodads or {}) do
            if adjustedTime(d) <= 0 then hasDone = true; break end
        end
        detailWin._btnReset._clearDoneMode = hasDone
        detailWin._btnReset:SetText(hasDone and "Clear 'Done'" or "Clear All")
    end

    local flat       = buildRenderList(farm)
    local totalPages = math.max(1, math.ceil(#flat / DETAIL_ROWS_PER_PAGE))
    if detailPage > totalPages then detailPage = totalPages end
    if detailPage < 1          then detailPage = 1          end

    if detailWin._dPageCtrl then
        detailWin._dPageCtrl:SetPageCount(totalPages, DETAIL_ROWS_PER_PAGE, false)
        detailWin._dPageCtrl:SetCurrentPage(detailPage, false)
    end

    local startIdx = (detailPage - 1) * DETAIL_ROWS_PER_PAGE + 1
    local endIdx   = math.min(startIdx + DETAIL_ROWS_PER_PAGE - 1, #flat)
    local rowCount = math.max(1, endIdx - startIdx + 1)

    local listContent = detailWin:CreateChildWidget("emptywidget", "ft_dl_content_"..rid, 0, true)
    listContent:SetExtent(DETAIL_W - 16, rowCount * 28)
    listContent:RemoveAllAnchors()
    listContent:AddAnchor("TOPLEFT", detailWin, 8, DETAIL_LIST_Y)
    listContent:Show(true)
    detailWin._listContent = listContent

    if #flat == 0 then
        local emptyLbl1 = listContent:CreateChildWidget("label", "ft_dl_empty1_"..rid, 0, true)
        emptyLbl1:SetText("No entities scanned yet.")
        emptyLbl1:AddAnchor("TOPLEFT", listContent, 4, 8)
        emptyLbl1:SetAutoResize(true)
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl1, FONT_COLOR.DEFAULT) end
        emptyLbl1:Show(true)
        local emptyLbl2 = listContent:CreateChildWidget("label", "ft_dl_empty2_"..rid, 0, true)
        emptyLbl2:SetText("Entities will be scanned on mouseover when holding the modifier key selected in the settings page for this addon.")
        emptyLbl2:AddAnchor("TOPLEFT", listContent, 4, 28)
        emptyLbl2:SetAutoResize(true)
        if emptyLbl2.style then emptyLbl2.style:SetFontSize(FONT_SIZE.SMALL or 14) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl2, FONT_COLOR.DEFAULT) end
        emptyLbl2:Show(true)
        return
    end

    for i = startIdx, endIdx do
        local item = flat[i]
        local yOff = (i - startIdx) * 28

        if item.type == "header" then
            local hdr = listContent:CreateChildWidget("emptywidget", "ft_dl_hdr_"..rid.."_"..i, 0, true)
            hdr:SetExtent(DETAIL_W - 16, 27)
            hdr:RemoveAllAnchors()
            hdr:AddAnchor("TOPLEFT", listContent, 0, yOff)
            hdr:Show(true)

            -- Expand checkbox (only show if qty > 1)
            if item.qty > 1 then
                local capturedKey = item.key
                local chk = hdr:CreateChildWidget("checkbutton", "ft_dl_exp_"..rid.."_"..i, 0, true)
                chk:SetExtent(18, 17)
                chk:AddAnchor("LEFT", hdr, 4, 0)
                local bgs = {}
                local coords = {
                    {0,0,18,17},{0,0,18,17},{0,0,18,17},
                    {0,17,18,17},{18,0,18,17},{18,17,18,17}
                }
                for j = 1, 6 do
                    bgs[j] = chk:CreateImageDrawable("ui/button/check_button.dds", "background")
                    bgs[j]:SetExtent(16, 16)
                    bgs[j]:AddAnchor("CENTER", chk, 0, 0)
                    bgs[j]:SetTexture("ui/button/check_button.dds")
                    local c = coords[j]
                    bgs[j]:SetCoords(c[1], c[2], c[3], c[4])
                end
                chk:SetNormalBackground(bgs[1])
                chk:SetHighlightBackground(bgs[2])
                chk:SetPushedBackground(bgs[3])
                chk:SetDisabledBackground(bgs[4])
                chk:SetCheckedBackground(bgs[5])
                chk:SetDisabledCheckedBackground(bgs[6])
                chk:SetChecked(expandedGroups[capturedKey] and true or false)
                function chk:OnCheckChanged()
                    expandedGroups[capturedKey] = self:GetChecked()
                    rebuildDoodadList()
                end
                chk:SetHandler("OnCheckChanged", chk.OnCheckChanged)
                chk:Show(true)
            end

            local nameLbl = hdr:CreateChildWidget("label", "ft_dl_hn_"..rid.."_"..i, 0, true)
            nameLbl:SetExtent(280, 27)
            nameLbl:AddAnchor("LEFT", hdr, 26, 0)
            nameLbl:SetText(item.name or "")
            nameLbl:SetAutoResize(false)
            if nameLbl.style then nameLbl.style:SetAlign(ALIGN.LEFT); nameLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(nameLbl, FONT_COLOR.DEFAULT) end
            nameLbl:Show(true)

            local qtyLbl = hdr:CreateChildWidget("label", "ft_dl_hq_"..rid.."_"..i, 0, true)
            qtyLbl:SetExtent(36, 27)
            qtyLbl:AddAnchor("LEFT", hdr, 272, 0)
            qtyLbl:SetText("x" .. item.qty)
            qtyLbl:SetAutoResize(false)
            if qtyLbl.style then qtyLbl.style:SetAlign(ALIGN.CENTER) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(qtyLbl, FONT_COLOR.DEFAULT) end
            qtyLbl:Show(true)

            local eLbl = hdr:CreateChildWidget("label", "ft_dl_he_"..rid.."_"..i, 0, true)
            eLbl:SetExtent(100, 27)
            eLbl:AddAnchor("LEFT", hdr, 312, 0)
            eLbl:SetText(formatTime(item.earliest))
            eLbl:SetAutoResize(false)
            if eLbl.style then eLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(eLbl, FONT_COLOR.DEFAULT) end
            eLbl:Show(true)
            table.insert(detailTimeLbls, { kind="earliest", lbl=eLbl, groupName=item.name, groupOwner=item.owner })

            local lLbl = hdr:CreateChildWidget("label", "ft_dl_hl_"..rid.."_"..i, 0, true)
            lLbl:SetExtent(100, 27)
            lLbl:AddAnchor("LEFT", hdr, 436, 0)
            lLbl:SetText(formatTime(item.latest))
            lLbl:SetAutoResize(false)
            if lLbl.style then lLbl.style:SetAlign(ALIGN.LEFT) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lLbl, FONT_COLOR.DEFAULT) end
            lLbl:Show(true)
            table.insert(detailTimeLbls, { kind="latest", lbl=lLbl, groupName=item.name, groupOwner=item.owner })

            -- Delete button for this group
            local delBtn = hdr:CreateChildWidget("button", "ft_dl_hdel_"..rid.."_"..i, 0, true)
            api.Interface:ApplyButtonSkin(delBtn, BUTTON_CONTENTS.SKILL_ABILITY_DELETE)
            delBtn:SetExtent(22, 22)
            delBtn:AddAnchor("RIGHT", hdr, -2, 0)
            local capturedName  = item.name
            local capturedOwner = item.owner
            function delBtn:OnClick()
                local f = detailFarmId and getFarmById(detailFarmId)
                if not f then return end
                local remaining = {}
                for _, d in ipairs(f.doodads or {}) do
                    local nameMatch  = d.name == capturedName
                    local ownerMatch = settings.groupBy ~= "name_owner"
                                    or (d.owner or "") == (capturedOwner or "")
                    if not (nameMatch and ownerMatch) then
                        table.insert(remaining, d)
                    end
                end
                f.doodads = remaining
                expandedGroups[item.key] = nil
                saveFarm(f)
                detailPage = 1
                rebuildDoodadList()
            end
            delBtn:SetHandler("OnClick", delBtn.OnClick)
            delBtn:Show(true)

        elseif item.type == "entry" then
            local row = listContent:CreateChildWidget("emptywidget", "ft_dl_ent_"..rid.."_"..i, 0, true)
            row:SetExtent(DETAIL_W - 16, 27)
            row:RemoveAllAnchors()
            row:AddAnchor("TOPLEFT", listContent, 0, yOff)
            row:Show(true)

            -- Indent + owner label
            local ownerLbl = row:CreateChildWidget("label", "ft_dl_eo_"..rid.."_"..i, 0, true)
            ownerLbl:SetExtent(260, 27)
            ownerLbl:AddAnchor("LEFT", row, 36, 0)
            ownerLbl:SetText("  " .. (item.owner ~= "" and item.owner or "No Owner"))
            ownerLbl:SetAutoResize(false)
            if ownerLbl.style then ownerLbl.style:SetAlign(ALIGN.LEFT); ownerLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(ownerLbl, FONT_COLOR.SOFT_BROWN or FONT_COLOR.DEFAULT) end
            ownerLbl:Show(true)

            -- Time label in Earliest column
            local tLbl = row:CreateChildWidget("label", "ft_dl_et_"..rid.."_"..i, 0, true)
            tLbl:SetExtent(200, 27)
            tLbl:AddAnchor("LEFT", row, 312, 0)
            tLbl:SetText(formatTime(item.t))
            tLbl:SetAutoResize(false)
            if tLbl.style then tLbl.style:SetAlign(ALIGN.LEFT); tLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(tLbl, FONT_COLOR.DEFAULT) end
            tLbl:Show(true)
            table.insert(detailTimeLbls, { kind="entry", lbl=tLbl, entry=item.entry })
        end
    end
    end) -- end pcall
    if not ok then log("rebuildDoodadList error: " .. tostring(err)) end
    detailRebuilding = false
end

local function openDetailWindow(farmId)
    local farm = getFarmById(farmId)
    if not farm then
        log("openDetailWindow: farm not found: " .. tostring(farmId))
        return
    end
    detailFarmId = farmId
    detailPage   = 1

    if mainWin      then mainWin:Show(false)     end
    if addFarmPopup then addFarmPopup:Show(false) end

    if not detailWin then
        detailWin = api.Interface:CreateWindow("farm_tracker_detail", "Farm Detail", DETAIL_W, DETAIL_H)
        detailWin:RemoveAllAnchors()
        detailWin:AddAnchor("CENTER", "UIParent", 0, 0)
        detailWin:Show(false)

        function detailWin:OnHide() lastDoodadInfo = nil end
        detailWin:SetHandler("OnHide", detailWin.OnHide)

        -- Farm info: zone on left, coords on right
        detailWin._zoneLbl = detailWin:CreateChildWidget("label", "ft_detail_zone", 0, true)
        detailWin._zoneLbl:SetExtent(200, 22)
        detailWin._zoneLbl:SetAutoResize(false)
        detailWin._zoneLbl:AddAnchor("TOPLEFT", detailWin, 10, 10)
        if detailWin._zoneLbl.style then
            detailWin._zoneLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
            detailWin._zoneLbl.style:SetAlign(ALIGN.LEFT)
        end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(detailWin._zoneLbl, FONT_COLOR.DEFAULT) end
        detailWin._zoneLbl:Show(true)

        detailWin._sextLbl = detailWin:CreateChildWidget("label", "ft_detail_sext", 0, true)
        detailWin._sextLbl:SetExtent(220, 22)
        detailWin._sextLbl:SetAutoResize(false)
        detailWin._sextLbl:AddAnchor("TOPRIGHT", detailWin, -20, 10)
        if detailWin._sextLbl.style then
            detailWin._sextLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16)
            detailWin._sextLbl.style:SetAlign(ALIGN.RIGHT)
        end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(detailWin._sextLbl, FONT_COLOR.DEFAULT) end
        detailWin._sextLbl:Show(true)

        -- Separator below info
        local sep1 = detailWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep1:SetExtent(DETAIL_W - 20, 1)
        sep1:RemoveAllAnchors()
        sep1:AddAnchor("TOPLEFT", detailWin, 10, 38)
        sep1:Show(true)

        -- Doodad list column headers
        local function makeDHdr(name, txt, x, w)
            local lbl = detailWin:CreateChildWidget("label", name, 0, true)
            lbl:SetExtent(w, 22)
            lbl:RemoveAllAnchors()
            lbl:AddAnchor("TOPLEFT", detailWin, x, 42)
            lbl:SetText(txt)
            lbl:SetAutoResize(false)
            if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.LARGE or 18) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
            lbl:Show(true)
        end
        makeDHdr("ft_dh_expand",   "{",           13,   24)
        makeDHdr("ft_dh_name",     "Entity Name", 37,  280)
        makeDHdr("ft_dh_qty",      "Qty",         281,  36)
        makeDHdr("ft_dh_earliest", "Earliest",    321, 100)
        makeDHdr("ft_dh_latest",   "Latest",      445, 100)

        -- Separator below column headers
        local sep3 = detailWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep3:SetExtent(DETAIL_W - 20, 1)
        sep3:RemoveAllAnchors()
        sep3:AddAnchor("TOPLEFT", detailWin, 10, 66)
        sep3:Show(true)

        -- Doodad list page controls (centered at bottom)
        local dPageCtrl = W_CTRL.CreatePageControl("ft_d_pagectrl", detailWin, "tutorial")
        dPageCtrl:RemoveAllAnchors()
        dPageCtrl:AddAnchor("BOTTOM", detailWin, 0, -14)
        function dPageCtrl:ProcOnPageChanged(pageIndex)
            detailPage = pageIndex
            rebuildDoodadList()
        end
        dPageCtrl:Show(true)
        detailWin._dPageCtrl = dPageCtrl

        -- Bottom separator
        local sep4 = detailWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep4:SetExtent(DETAIL_W - 20, 1)
        sep4:RemoveAllAnchors()
        sep4:AddAnchor("BOTTOMLEFT", detailWin, 10, -46)
        sep4:Show(true)

        -- "Populate Filter List" checkbox (above Back button)
        local cbPopulate = detailWin:CreateChildWidget("checkbutton", "ft_detail_cb_populate", 0, true)
        cbPopulate:SetExtent(18, 17)
        cbPopulate:RemoveAllAnchors()
        cbPopulate:AddAnchor("BOTTOMLEFT", detailWin, 10, -48)
        local cbpBgs = {}
        local cbpCoords = {
            {0,0,18,17},{0,0,18,17},{0,0,18,17},
            {0,17,18,17},{18,0,18,17},{18,17,18,17}
        }
        for j = 1, 6 do
            cbpBgs[j] = cbPopulate:CreateImageDrawable("ui/button/check_button.dds", "background")
            cbpBgs[j]:SetExtent(16, 16)
            cbpBgs[j]:AddAnchor("CENTER", cbPopulate, 0, 0)
            cbpBgs[j]:SetTexture("ui/button/check_button.dds")
            local c = cbpCoords[j]
            cbpBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
        end
        cbPopulate:SetNormalBackground(cbpBgs[1])
        cbPopulate:SetHighlightBackground(cbpBgs[2])
        cbPopulate:SetPushedBackground(cbpBgs[3])
        cbPopulate:SetDisabledBackground(cbpBgs[4])
        cbPopulate:SetCheckedBackground(cbpBgs[5])
        cbPopulate:SetDisabledCheckedBackground(cbpBgs[6])
        cbPopulate:SetChecked(false)
        function cbPopulate:OnCheckChanged()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then f.populateFilter = not self:GetChecked(); saveFarm(f) end
        end
        cbPopulate:SetHandler("OnCheckChanged", cbPopulate.OnCheckChanged)
        cbPopulate:Show(true)
        detailWin._cbPopulate = cbPopulate

        local cbPopulateLbl = detailWin:CreateChildWidget("label", "ft_detail_populate_lbl", 0, true)
        cbPopulateLbl:SetText("Lock Filter")
        cbPopulateLbl:SetAutoResize(true)
        cbPopulateLbl:AddAnchor("LEFT", cbPopulate, "RIGHT", 4, 0)
        if cbPopulateLbl.style then cbPopulateLbl.style:SetAlign(ALIGN.LEFT); cbPopulateLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbPopulateLbl, FONT_COLOR.DEFAULT) end
        cbPopulateLbl:Show(true)

        -- "Scan only when holding [modifier]" checkbox
        local cbModOnly = detailWin:CreateChildWidget("checkbutton", "ft_detail_cb_modonly", 0, true)
        cbModOnly:SetExtent(18, 17)
        cbModOnly:RemoveAllAnchors()
        cbModOnly:AddAnchor("BOTTOMLEFT", detailWin, 210, -48)
        local cbmBgs = {}
        local cbmCoords = {
            {0,0,18,17},{0,0,18,17},{0,0,18,17},
            {0,17,18,17},{18,0,18,17},{18,17,18,17}
        }
        for j = 1, 6 do
            cbmBgs[j] = cbModOnly:CreateImageDrawable("ui/button/check_button.dds", "background")
            cbmBgs[j]:SetExtent(16, 16)
            cbmBgs[j]:AddAnchor("CENTER", cbModOnly, 0, 0)
            cbmBgs[j]:SetTexture("ui/button/check_button.dds")
            local c = cbmCoords[j]
            cbmBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
        end
        cbModOnly:SetNormalBackground(cbmBgs[1])
        cbModOnly:SetHighlightBackground(cbmBgs[2])
        cbModOnly:SetPushedBackground(cbmBgs[3])
        cbModOnly:SetDisabledBackground(cbmBgs[4])
        cbModOnly:SetCheckedBackground(cbmBgs[5])
        cbModOnly:SetDisabledCheckedBackground(cbmBgs[6])
        cbModOnly:SetChecked(true)
        function cbModOnly:OnCheckChanged()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then f.requireModifier = self:GetChecked(); saveFarm(f) end
        end
        cbModOnly:SetHandler("OnCheckChanged", cbModOnly.OnCheckChanged)
        cbModOnly:Show(true)
        detailWin._cbModOnly = cbModOnly

        local cbModOnlyLbl = detailWin:CreateChildWidget("label", "ft_detail_modonly_lbl", 0, true)
        cbModOnlyLbl:SetText("Scan only when holding modifier")
        cbModOnlyLbl:SetAutoResize(true)
        cbModOnlyLbl:AddAnchor("LEFT", cbModOnly, "RIGHT", 4, 0)
        if cbModOnlyLbl.style then cbModOnlyLbl.style:SetAlign(ALIGN.LEFT); cbModOnlyLbl.style:SetFontSize(FONT_SIZE.SMALL or 14) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbModOnlyLbl, FONT_COLOR.DEFAULT) end
        cbModOnlyLbl:Show(true)
        detailWin._cbModOnlyLbl = cbModOnlyLbl

        -- Back button (bottom-left)
        local btnBack = detailWin:CreateChildWidget("button", "ft_detail_back", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnBack, BUTTON_BASIC.DEFAULT) end
        btnBack:SetExtent(70, 28)
        btnBack:AddAnchor("BOTTOMLEFT", detailWin, 10, -10)
        btnBack:SetText("< Back")
        function btnBack:OnClick()
            closeDetailWindow()
            if mainWin then mainWin:Show(true) end
        end
        btnBack:SetHandler("OnClick", btnBack.OnClick)
        btnBack:Show(true)

        -- Filters button (right of Back)
        local btnFiltersBottom = detailWin:CreateChildWidget("button", "ft_detail_filters_btm", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnFiltersBottom, BUTTON_BASIC.DEFAULT) end
        btnFiltersBottom:SetExtent(80, 28)
        btnFiltersBottom:AddAnchor("BOTTOMLEFT", detailWin, 88, -10)
        btnFiltersBottom:SetText("Filters")
        function btnFiltersBottom:OnClick()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then openFilterWindow(f) end
        end
        btnFiltersBottom:SetHandler("OnClick", btnFiltersBottom.OnClick)
        btnFiltersBottom:Show(true)

        -- Share to Discord button (bottom-right)
        local btnShare = detailWin:CreateChildWidget("button", "ft_detail_share", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnShare, BUTTON_BASIC.DEFAULT) end
        btnShare:SetExtent(80, 28)
        btnShare:AddAnchor("BOTTOMRIGHT", detailWin, -10, -10)
        btnShare:SetText("Share")
        function btnShare:OnClick()
            local f = detailFarmId and getFarmById(detailFarmId)
            if f then
                writeShareFile(f)
                log("Farm \"" .. (f.name or "") .. "\" shared.")
            end
        end
        btnShare:SetHandler("OnClick", btnShare.OnClick)
        btnShare:Show(true)
        detailWin._btnShare = btnShare

        -- Clear button (left of Share to Discord)
        local btnReset = detailWin:CreateChildWidget("button", "ft_detail_reset", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnReset, BUTTON_BASIC.DEFAULT) end
        btnReset:SetExtent(100, 28)
        btnReset:AddAnchor("BOTTOMRIGHT", detailWin, -98, -10)
        btnReset:SetText("Clear All")
        if btnReset.style then btnReset.style:SetColor(1, 0.5, 0.2, 1) end
        function btnReset:OnClick()
            local f = detailFarmId and getFarmById(detailFarmId)
            if not f then return end
            if self._clearDoneMode then
                local remaining = {}
                for _, d in ipairs(f.doodads or {}) do
                    if adjustedTime(d) > 0 then
                        table.insert(remaining, d)
                    end
                end
                f.doodads = remaining
            else
                f.doodads = {}
            end
            saveFarm(f); detailPage = 1; rebuildDoodadList()
        end
        btnReset:SetHandler("OnClick", btnReset.OnClick)
        btnReset:Show(true)
        detailWin._btnReset = btnReset
    end

    -- Populate static labels
    detailWin._zoneLbl:SetText(zoneName(farm.zone))
    detailWin._sextLbl:SetText(farm.sextants or "")
    if detailWin.SetTitle then detailWin:SetTitle(farm.name or "Farm Detail") end
    if detailWin._cbPopulate then
        local pop = farm.populateFilter
        if pop == nil then pop = true end
        detailWin._cbPopulate:SetChecked(not pop)
    end
    if detailWin._cbModOnly then
        local req = farm.requireModifier
        if req == nil then req = true end
        detailWin._cbModOnly:SetChecked(req)
    end
    if detailWin._cbModOnlyLbl then
        local mod = settings.scanModifier or "any"
        local modLabel
        if     mod == "ctrl"  then modLabel = "Ctrl"
        elseif mod == "alt"   then modLabel = "Alt"
        elseif mod == "shift" then modLabel = "Shift"
        elseif mod == "none"  then modLabel = "any key"
        else                       modLabel = "Alt/Shift/Ctrl"
        end
        detailWin._cbModOnlyLbl:SetText("Scan only when holding " .. modLabel)
    end

    rebuildDoodadList()
    detailWin:Show(true)
end

-- ============================================================
-- DOODAD EVENT LISTENER
-- Uses its own window + RegisterEvent. Must NOT be hidden —
-- hidden windows don't receive events in this engine.
-- ============================================================

local function createDoodadListener()
    if doodadListener then return end
    doodadListener = api.Interface:CreateEmptyWindow("ft_doodad_listener")
    -- Do NOT call Show(false) — hidden windows don't receive events

    function doodadListener:OnEvent(event, ...)
        if event == "DRAW_DOODAD_TOOLTIP" then
            local info = unpack(arg)
            if type(info) == "table" then lastDoodadInfo = info end
        elseif event == "DRAW_DOODAD_SIGN_TAG" then
            local tag = unpack(arg)
            if tag == nil or tag == "" then lastDoodadInfo = nil end
        end
    end
    doodadListener:SetHandler("OnEvent", doodadListener.OnEvent)
    doodadListener:RegisterEvent("DRAW_DOODAD_TOOLTIP")
    doodadListener:RegisterEvent("DRAW_DOODAD_SIGN_TAG")
end

-- ============================================================
-- UPDATE LOOP  — scan capture + live time refresh
-- ============================================================

local function OnUpdate(dt)
    -- Scan capture: detail window open + modifier held + doodad hovered
    if detailWin and detailWin:IsVisible() and lastDoodadInfo then
        local mod = settings.scanModifier or "any"
        local farm = detailFarmId and getFarmById(detailFarmId)
        local requireMod = farm and farm.requireModifier
        if requireMod == nil then requireMod = true end
        local effectiveMod = requireMod and mod or "none"
        local modDown =
            (effectiveMod == "any"   and (api.Input:IsControlKeyDown() or api.Input:IsAltKeyDown() or api.Input:IsShiftKeyDown())) or
            (effectiveMod == "ctrl"  and api.Input:IsControlKeyDown()) or
            (effectiveMod == "alt"   and api.Input:IsAltKeyDown()) or
            (effectiveMod == "shift" and api.Input:IsShiftKeyDown()) or
            (effectiveMod == "none"  and true)
        if modDown then
            if farm and tryAddDoodad(farm, lastDoodadInfo) then
                rebuildDoodadList()
            end
        end
    end

    -- Live time label refresh (only when detail window is open)
    if not (detailWin and detailWin:IsVisible()) then return end
    if #detailTimeLbls == 0 then return end

    local farm = detailFarmId and getFarmById(detailFarmId)
    if not farm then return end

    for _, item in ipairs(detailTimeLbls) do
        if item.lbl then
            if item.kind == "entry" then
                -- Individual entry row: update directly from entry
                if item.entry then
                    item.lbl:SetText(formatTime(adjustedTime(item.entry)))
                end
            else
                -- Header earliest/latest
                local val = nil
                for _, d in ipairs(farm.doodads or {}) do
                    local nameMatch  = d.name == item.groupName
                    local ownerMatch = settings.groupBy ~= "name_owner"
                                    or (d.owner or "") == (item.groupOwner or "")
                    if nameMatch and ownerMatch then
                        local t = adjustedTime(d)
                        if item.kind == "earliest" then
                            if val == nil or t < val then val = t end
                        else
                            if val == nil or t > val then val = t end
                        end
                    end
                end
                if val ~= nil then item.lbl:SetText(formatTime(val)) end
            end
        end
    end
end

-- ============================================================
-- PER-FARM FILTER WINDOW
-- ============================================================

local FW_W           = 600
local FW_H           = 420
local FW_COL_W       = 270   -- width of each column
local FW_ROW_H       = 26
local FW_ROWS_PER_PAGE = 10
local fwSeq     = 0
local function fwId() fwSeq = fwSeq + 1; return fwSeq end

local function makeFilterCheckbox(parent, id, x, y, checked, onToggle)
    local cb = parent:CreateChildWidget("checkbutton", "ft_fw_cb_"..id, 0, true)
    cb:SetExtent(18, 17)
    cb:AddAnchor("TOPLEFT", parent, x, y)
    local bgs = {}
    local coords = {
        {0,0,18,17},{0,0,18,17},{0,0,18,17},
        {0,17,18,17},{18,0,18,17},{18,17,18,17}
    }
    for i = 1, 6 do
        bgs[i] = cb:CreateImageDrawable("ui/button/check_button.dds", "background")
        bgs[i]:SetExtent(16,16)
        bgs[i]:AddAnchor("CENTER", cb, 0, 0)
        bgs[i]:SetTexture("ui/button/check_button.dds")
        local c = coords[i]
        bgs[i]:SetCoords(c[1],c[2],c[3],c[4])
    end
    cb:SetNormalBackground(bgs[1])
    cb:SetHighlightBackground(bgs[2])
    cb:SetPushedBackground(bgs[3])
    cb:SetDisabledBackground(bgs[4])
    cb:SetCheckedBackground(bgs[5])
    cb:SetDisabledCheckedBackground(bgs[6])
    cb:SetChecked(checked)
    function cb:OnCheckChanged() onToggle(self:GetChecked()) end
    cb:SetHandler("OnCheckChanged", cb.OnCheckChanged)
    cb:Show(true)
    return cb
end

local function rebuildFilterLists(farm)
    if not filterWin then return end
    filterRebuildId = filterRebuildId + 1
    local rid = filterRebuildId

    -- Hide old containers
    if filterWin._playerContainer then filterWin._playerContainer:Show(false) end
    if filterWin._entityContainer then filterWin._entityContainer:Show(false) end

    local players  = farm.scanPlayers  or {}
    local entities = farm.scanEntities or {}

    -- Clamp pages
    local pTotalPages = math.max(1, math.ceil(#players  / FW_ROWS_PER_PAGE))
    local eTotalPages = math.max(1, math.ceil(#entities / FW_ROWS_PER_PAGE))
    if filterPlayerPage > pTotalPages then filterPlayerPage = pTotalPages end
    if filterEntityPage > eTotalPages then filterEntityPage = eTotalPages end

    -- Update pagination controls
    if filterWin._pPageCtrl then
        filterWin._pPageCtrl:SetPageCount(pTotalPages, FW_ROWS_PER_PAGE, false)
        filterWin._pPageCtrl:SetCurrentPage(filterPlayerPage, false)
    end
    if filterWin._ePageCtrl then
        filterWin._ePageCtrl:SetPageCount(eTotalPages, FW_ROWS_PER_PAGE, false)
        filterWin._ePageCtrl:SetCurrentPage(filterEntityPage, false)
    end

    local function buildColumn(list, page, containerName, xOff)
        local startIdx = (page - 1) * FW_ROWS_PER_PAGE + 1
        local endIdx   = math.min(startIdx + FW_ROWS_PER_PAGE - 1, #list)
        local rowCount = math.max(1, endIdx - startIdx + 1)

        local c = filterWin:CreateChildWidget("emptywidget", containerName.."_"..rid, 0, true)
        c:SetExtent(FW_COL_W, rowCount * FW_ROW_H)
        c:RemoveAllAnchors()
        c:AddAnchor("TOPLEFT", filterWin, xOff, 90)
        c:Show(true)

        if #list == 0 then
            local lbl = c:CreateChildWidget("label", containerName.."_empty_"..rid, 0, true)
            lbl:SetText(xOff < 200 and "No players scanned yet." or "No entities scanned yet.")
            lbl:AddAnchor("TOPLEFT", c, 0, 4)
            lbl:SetAutoResize(true)
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.MIDDLE_GRAY or FONT_COLOR.DEFAULT) end
            lbl:Show(true)
        else
            for i = startIdx, endIdx do
                local entry = list[i]
                local y     = (i - startIdx) * FW_ROW_H
                local uid   = fwId()
                local captured = entry
                makeFilterCheckbox(c, uid, 0, y+1, entry.enabled, function(val)
                    captured.enabled = val
                    saveFarm(farm)
                end)
                local lbl = c:CreateChildWidget("label", containerName.."_lbl_"..uid, 0, true)
                lbl:SetExtent(FW_COL_W - 26, FW_ROW_H)
                lbl:AddAnchor("TOPLEFT", c, 24, y-6)
                lbl:SetText(entry.name ~= "" and entry.name or "(no owner)")
                lbl:SetAutoResize(false)
                if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
                if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
                lbl:Show(true)
            end
        end
        return c
    end

    filterWin._playerContainer = buildColumn(players,  filterPlayerPage, "ft_fw_pc", 10)
    filterWin._entityContainer = buildColumn(entities, filterEntityPage, "ft_fw_ec", 320)
end

openFilterWindow = function(farm)
    if not filterWin then
        filterWin = api.Interface:CreateWindow("farm_tracker_filters", "Scan Filters", FW_W, FW_H)
        filterWin:RemoveAllAnchors()
        filterWin:AddAnchor("CENTER", "UIParent", 0, 0)

        -- Column headers
        local hdrPlayers = filterWin:CreateChildWidget("label", "ft_fw_hdr_p", 0, true)
        hdrPlayers:SetExtent(FW_COL_W - 28, 24)
        hdrPlayers:AddAnchor("TOPLEFT", filterWin, 36, 44)
        hdrPlayers:SetText("Scan only from these players:")
        if hdrPlayers.style then hdrPlayers.style:SetFontSize(FONT_SIZE.LARGE or 18); hdrPlayers.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(hdrPlayers, FONT_COLOR.DEFAULT) end
        hdrPlayers:Show(true)

        -- Player filter enable checkbox
        local function makeInlineCb(widgetId, xOff, yOff, onChanged)
            local cb = filterWin:CreateChildWidget("checkbutton", widgetId, 0, true)
            cb:SetExtent(18, 17)
            cb:RemoveAllAnchors()
            cb:AddAnchor("TOPLEFT", filterWin, xOff, yOff)
            local bgs = {}
            local coords = { {0,0,18,17},{0,0,18,17},{0,0,18,17},{0,17,18,17},{18,0,18,17},{18,17,18,17} }
            for j = 1, 6 do
                bgs[j] = cb:CreateImageDrawable("ui/button/check_button.dds", "background")
                bgs[j]:SetExtent(16, 16); bgs[j]:AddAnchor("CENTER", cb, 0, 0)
                bgs[j]:SetTexture("ui/button/check_button.dds")
                local c = coords[j]; bgs[j]:SetCoords(c[1], c[2], c[3], c[4])
            end
            cb:SetNormalBackground(bgs[1]); cb:SetHighlightBackground(bgs[2])
            cb:SetPushedBackground(bgs[3]); cb:SetDisabledBackground(bgs[4])
            cb:SetCheckedBackground(bgs[5]); cb:SetDisabledCheckedBackground(bgs[6])
            cb:SetChecked(true)
            function cb:OnCheckChanged() onChanged(self:GetChecked()) end
            cb:SetHandler("OnCheckChanged", cb.OnCheckChanged)
            cb:Show(true)
            return cb
        end

        filterWin._cbPlayerFilter = makeInlineCb("ft_fw_cb_pfilter", 10, 46, function(val)
            if filterWin._currentFarm then
                filterWin._currentFarm.filterPlayersEnabled = val
                saveFarm(filterWin._currentFarm)
                rebuildFilterLists(filterWin._currentFarm)
            end
        end)

        local hdrEntities = filterWin:CreateChildWidget("label", "ft_fw_hdr_e", 0, true)
        hdrEntities:SetExtent(FW_COL_W - 28, 24)
        hdrEntities:AddAnchor("TOPLEFT", filterWin, 346, 44)
        hdrEntities:SetText("Scan only these entities:")
        if hdrEntities.style then hdrEntities.style:SetFontSize(FONT_SIZE.LARGE or 18); hdrEntities.style:SetAlign(ALIGN.LEFT) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(hdrEntities, FONT_COLOR.DEFAULT) end
        hdrEntities:Show(true)

        filterWin._cbEntityFilter = makeInlineCb("ft_fw_cb_efilter", 320, 46, function(val)
            if filterWin._currentFarm then
                filterWin._currentFarm.filterEntitiesEnabled = val
                saveFarm(filterWin._currentFarm)
                rebuildFilterLists(filterWin._currentFarm)
            end
        end)

        -- Column divider
        local div = filterWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        div:SetExtent(1, FW_H - 80)
        div:RemoveAllAnchors()
        div:AddAnchor("TOPLEFT", filterWin, 308, 44)
        div:Show(true)

        -- Separator below headers
        local sep = filterWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sep:SetExtent(FW_W - 20, 1)
        sep:RemoveAllAnchors()
        sep:AddAnchor("TOPLEFT", filterWin, 10, 76)
        sep:Show(true)

        -- Bottom separator
        local sepBot = filterWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
        sepBot:SetExtent(FW_W - 20, 1)
        sepBot:RemoveAllAnchors()
        sepBot:AddAnchor("BOTTOMLEFT", filterWin, 10, -46)
        sepBot:Show(true)

        -- Reset button (bottom-right)
        local btnReset = filterWin:CreateChildWidget("button", "ft_fw_reset", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnReset, BUTTON_BASIC.DEFAULT) end
        btnReset:SetExtent(70, 28)
        btnReset:AddAnchor("BOTTOMRIGHT", filterWin, -10, -10)
        btnReset:SetText("Reset")
        if btnReset.style then btnReset.style:SetColor(1, 0.5, 0.2, 1) end
        filterWin._btnReset = btnReset
        btnReset:Show(true)

        filterWin._playerContainer = filterWin:CreateChildWidget("emptywidget", "ft_fw_pc_init", 0, true)
        filterWin._playerContainer:SetExtent(FW_COL_W, 10)
        filterWin._playerContainer:AddAnchor("TOPLEFT", filterWin, 10, 90)
        filterWin._entityContainer = filterWin:CreateChildWidget("emptywidget", "ft_fw_ec_init", 0, true)
        filterWin._entityContainer:SetExtent(FW_COL_W, 10)
        filterWin._entityContainer:AddAnchor("TOPLEFT", filterWin, 320, 90)

        -- Pagination for player column
        local pPageCtrl = W_CTRL.CreatePageControl("ft_fw_p_pagectrl", filterWin, "tutorial")
        pPageCtrl:RemoveAllAnchors()
        pPageCtrl:AddAnchor("BOTTOMLEFT", filterWin, 10, -10)
        function pPageCtrl:ProcOnPageChanged(pageIndex)
            filterPlayerPage = pageIndex
            rebuildFilterLists(filterWin._currentFarm)
        end
        pPageCtrl:Show(true)
        filterWin._pPageCtrl = pPageCtrl

        -- Pagination for entity column
        local ePageCtrl = W_CTRL.CreatePageControl("ft_fw_e_pagectrl", filterWin, "tutorial")
        ePageCtrl:RemoveAllAnchors()
        ePageCtrl:AddAnchor("BOTTOM", filterWin, 90, -10)
        function ePageCtrl:ProcOnPageChanged(pageIndex)
            filterEntityPage = pageIndex
            rebuildFilterLists(filterWin._currentFarm)
        end
        ePageCtrl:Show(true)
        filterWin._ePageCtrl = ePageCtrl
    end

    -- Wire reset button to current farm
    filterWin._currentFarm = farm
    filterPlayerPage = 1
    filterEntityPage = 1
    filterWin._btnReset:SetHandler("OnClick", function()
        farm.scanPlayers  = {}
        farm.scanEntities = {}
        saveFarm(farm)
        rebuildFilterLists(farm)
    end)

    -- Sync default checkbox to farm setting
    if filterWin._cbPlayerFilter then
        local v = farm.filterPlayersEnabled; if v == nil then v = true end
        filterWin._cbPlayerFilter:SetChecked(v)
    end
    if filterWin._cbEntityFilter then
        local v = farm.filterEntitiesEnabled; if v == nil then v = true end
        filterWin._cbEntityFilter:SetChecked(v)
    end

    rebuildFilterLists(farm)
    filterWin:Show(true)
end

-- ============================================================
-- FLOATING BUTTON
-- ============================================================

local function destroyFloatingBtn()
    if floatingBtn then
        floatingBtn:Show(false)
        floatingBtn = nil
    end
end

local function createFloatingBtn()
    if floatingBtn then return end

    floatingBtnSeq = floatingBtnSeq + 1
    floatingBtn = api.Interface:CreateEmptyWindow("ft_floating_btn_"..floatingBtnSeq, "UIParent")
    floatingBtn.background = floatingBtn:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
    floatingBtn.background:SetTextureInfo("bg_quest")
    floatingBtn.background:SetColor(0, 0, 0, 0.6)
    floatingBtn.background:AddAnchor("TOPLEFT", floatingBtn, 0, 0)
    floatingBtn.background:AddAnchor("BOTTOMRIGHT", floatingBtn, 0, 0)
    floatingBtn:AddAnchor("TOPLEFT", "UIParent", settings.floatingBtnX or 200, settings.floatingBtnY or 200)
    settings.floatingBtnX = settings.floatingBtnX or 200
    settings.floatingBtnY = settings.floatingBtnY or 200
    saveSettings()
    floatingBtn:SetExtent(120, 40)

    function floatingBtn:OnDragStart()
        if api.Input:IsShiftKeyDown() then
            floatingBtn:StartMoving()
            api.Cursor:ClearCursor()
            api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
        end
    end
    floatingBtn:SetHandler("OnDragStart", floatingBtn.OnDragStart)

    function floatingBtn:OnDragStop()
        local x, y = floatingBtn:GetEffectiveOffset()
        settings.floatingBtnX = x
        settings.floatingBtnY = y
        saveSettings()
        floatingBtn:StopMovingOrSizing()
        api.Cursor:ClearCursor()
    end
    floatingBtn:SetHandler("OnDragStop", floatingBtn.OnDragStop)

    local btn = api.Interface:CreateWidget("button", "ft_floating_inner_btn_"..floatingBtnSeq, floatingBtn)
    api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
    btn:SetExtent(110, 28)
    btn:RemoveAllAnchors()
    btn:AddAnchor("TOPLEFT", floatingBtn, 5, 6)
    btn:SetText("Farm Tracker")
    btn.OnClick = function(self)
        toggleMainWindow()
    end
    btn:SetHandler("OnClick", btn.OnClick)
    btn:Show(true)

    floatingBtn:Show(true)
    floatingBtn:EnableDrag(true)
end

-- ============================================================
-- SETTINGS WINDOW
-- ============================================================

local SETTINGS_W = 300
local SETTINGS_H = 170

local function openSettingsWindow()
    if settingsWin then
        settingsWin:Show(true)
        return
    end

    settingsWin = api.Interface:CreateWindow("farm_tracker_settings", "FarmTracker Settings", SETTINGS_W, SETTINGS_H)
    settingsWin:RemoveAllAnchors()
    settingsWin:AddAnchor("CENTER", "UIParent", 0, 0)

    -- Modifier key label
    local modLbl = settingsWin:CreateChildWidget("label", "ft_sw_mod_lbl", 0, true)
    modLbl:SetExtent(200, 24)
    modLbl:AddAnchor("TOPLEFT", settingsWin, 10, 44)
    modLbl:SetText("Scan trigger key:")
    if modLbl.style then modLbl.style:SetFontSize(FONT_SIZE.LARGE or 18); modLbl.style:SetAlign(ALIGN.LEFT) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(modLbl, FONT_COLOR.DEFAULT) end
    modLbl:Show(true)

    local MOD_OPTIONS = { "Any modifier", "Ctrl", "Alt", "Shift", "None required" }
    local MOD_VALUES  = { "any", "ctrl", "alt", "shift", "none" }
    local function modIndexFromValue(v)
        for i, val in ipairs(MOD_VALUES) do if val == v then return i end end
        return 1
    end

    local ok, combo = pcall(function() return api.Interface:CreateComboBox(settingsWin) end)
    if ok and combo then
        combo:RemoveAllAnchors()
        combo:AddAnchor("TOPLEFT", settingsWin, 130, 44)
        combo:SetWidth(160)
        combo.dropdownItem = MOD_OPTIONS
        combo:Select(modIndexFromValue(settings.scanModifier or "any"))
        function combo:SelectedProc()
            settings.scanModifier = MOD_VALUES[self:GetSelectedIndex()] or "any"
            saveSettings()
        end
    else
        local cycleBtn = settingsWin:CreateChildWidget("button", "ft_sw_mod_cycle", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(cycleBtn, BUTTON_BASIC.DEFAULT) end
        cycleBtn:SetExtent(160, 24)
        cycleBtn:AddAnchor("TOPLEFT", settingsWin, 130, 44)
        local function updateCycleBtn()
            cycleBtn:SetText(MOD_OPTIONS[modIndexFromValue(settings.scanModifier or "any")] or "Any modifier")
        end
        updateCycleBtn()
        function cycleBtn:OnClick()
            local idx = (modIndexFromValue(settings.scanModifier or "any") % #MOD_VALUES) + 1
            settings.scanModifier = MOD_VALUES[idx]
            saveSettings()
            updateCycleBtn()
        end
        cycleBtn:SetHandler("OnClick", cycleBtn.OnClick)
        cycleBtn:Show(true)
    end

    -- "Show Farm Tracker button" checkbox
    local cbFloat = settingsWin:CreateChildWidget("checkbutton", "ft_sw_cb_float", 0, true)
    cbFloat:SetExtent(18, 17)
    cbFloat:RemoveAllAnchors()
    cbFloat:AddAnchor("TOPLEFT", settingsWin, 10, 84)
    local cbfBgs = {}
    local cbfCoords = { {0,0,18,17},{0,0,18,17},{0,0,18,17},{0,17,18,17},{18,0,18,17},{18,17,18,17} }
    for j = 1, 6 do
        cbfBgs[j] = cbFloat:CreateImageDrawable("ui/button/check_button.dds", "background")
        cbfBgs[j]:SetExtent(16, 16); cbfBgs[j]:AddAnchor("CENTER", cbFloat, 0, 0)
        cbfBgs[j]:SetTexture("ui/button/check_button.dds")
        local c = cbfCoords[j]; cbfBgs[j]:SetCoords(c[1], c[2], c[3], c[4])
    end
    cbFloat:SetNormalBackground(cbfBgs[1]); cbFloat:SetHighlightBackground(cbfBgs[2])
    cbFloat:SetPushedBackground(cbfBgs[3]); cbFloat:SetDisabledBackground(cbfBgs[4])
    cbFloat:SetCheckedBackground(cbfBgs[5]); cbFloat:SetDisabledCheckedBackground(cbfBgs[6])
    cbFloat:SetChecked(settings.showFloatingBtn and true or false)
    function cbFloat:OnCheckChanged()
        settings.showFloatingBtn = self:GetChecked()
        saveSettings()
        if settings.showFloatingBtn then
            createFloatingBtn()
        else
            destroyFloatingBtn()
        end
    end
    cbFloat:SetHandler("OnCheckChanged", cbFloat.OnCheckChanged)
    cbFloat:Show(true)
    settingsWin._cbFloat = cbFloat

    local cbFloatLbl = settingsWin:CreateChildWidget("label", "ft_sw_float_lbl", 0, true)
    cbFloatLbl:SetText("Show Farm Tracker button")
    cbFloatLbl:SetAutoResize(true)
    cbFloatLbl:AddAnchor("LEFT", cbFloat, "RIGHT", 4, 0)
    if cbFloatLbl.style then cbFloatLbl.style:SetAlign(ALIGN.LEFT); cbFloatLbl.style:SetFontSize(FONT_SIZE.MIDDLE or 16) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(cbFloatLbl, FONT_COLOR.DEFAULT) end
    cbFloatLbl:Show(true)

    settingsWin:Show(true)
end

-- ============================================================
-- MAIN WINDOW — farm list
-- ============================================================

local ROW_H          = 42
local NAME_W         = 150
local ZONE_W         = 130
local SEXT_W         = 150
local BTN_W          = 52
local GAP            = 8
local SCROLL_Y_START = 72

local COL_NAME_X = 6
local COL_ZONE_X = COL_NAME_X + NAME_W + GAP - 10 + 45
local COL_SEXT_X = COL_ZONE_X + ZONE_W + GAP - 40 + 15
local BTN_Y_OFF  = -math.floor(ROW_H / 2) + 23

local function rebuildFarmList()
    if not mainWin then return end

    mainListRebuildId = mainListRebuildId + 1
    local rid = mainListRebuildId

    -- Apply filter
    local filtered = {}
    if filterText == "" then
        filtered = farms
    else
        for _, f in ipairs(farms) do
            local nm = f.name and f.name:lower():find(filterText, 1, true)
            local zm = zoneName(f.zone):lower():find(filterText, 1, true)
            if nm or zm then table.insert(filtered, f) end
        end
    end

    local totalPages = math.max(1, math.ceil(#filtered / ROWS_PER_PAGE))
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1          then currentPage = 1          end

    if mainWin._pageCtrl then
        mainWin._pageCtrl:SetPageCount(totalPages, ROWS_PER_PAGE, false)
        mainWin._pageCtrl:SetCurrentPage(currentPage, false)
    end

    for _, row in ipairs(mainListRows) do
        if row and row.Show then row:Show(false) end
    end
    mainListRows = {}

    if mainListContent and mainListContent.Show then mainListContent:Show(false) end

    local startIdx = (currentPage - 1) * ROWS_PER_PAGE + 1
    local endIdx   = math.min(startIdx + ROWS_PER_PAGE - 1, #filtered)
    local pageRows = {}
    for i = startIdx, endIdx do table.insert(pageRows, filtered[i]) end

    local contentH = math.max(1, #pageRows) * ROW_H
    mainListContent = mainWin:CreateChildWidget("emptywidget", "ft_list_content_"..rid, 0, true)
    mainListContent:SetExtent(MAIN_W - 24, contentH)
    mainListContent:RemoveAllAnchors()
    mainListContent:AddAnchor("TOPLEFT", mainWin, 4, SCROLL_Y_START)
    mainListContent:Show(true)

    if #filtered == 0 then
        local emptyLbl = mainListContent:CreateChildWidget("label", "ft_empty_lbl", 0, true)
        emptyLbl:SetText(#farms == 0
            and "No farms yet. Click [+ Add Farm] to create one."
            or  "No farms match \"" .. filterText .. "\".")
        emptyLbl:AddAnchor("TOPLEFT", mainListContent, 10, 10)
        emptyLbl:SetAutoResize(true)
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(emptyLbl, FONT_COLOR.DEFAULT) end
        emptyLbl:Show(true)
        return
    end

    for i, farm in ipairs(pageRows) do
        local yOff = (i - 1) * ROW_H

        local rowBg = mainListContent:CreateChildWidget("emptywidget", "ft_row_bg_"..rid.."_"..i, 0, true)
        rowBg:SetExtent(MAIN_W - 24, ROW_H - 2)
        rowBg:RemoveAllAnchors()
        rowBg:AddAnchor("TOPLEFT", mainListContent, 0, yOff)
        if i % 2 == 0 then
            local shade = rowBg:CreateColorDrawable(0.1, 0.1, 0.15, 0.4, "background")
            shade:AddAnchor("TOPLEFT",     rowBg, 0, 0)
            shade:AddAnchor("BOTTOMRIGHT", rowBg, 0, 0)
            shade:Show(true)
        end
        rowBg:Show(true)
        table.insert(mainListRows, rowBg)

        local function makeRowLbl(name, txt, x, w, sz)
            local lbl = rowBg:CreateChildWidget("label", name, 0, true)
            lbl:SetExtent(w, ROW_H)
            lbl:RemoveAllAnchors()
            lbl:AddAnchor("LEFT", rowBg, x, 0)
            lbl:SetText(txt)
            lbl:SetAutoResize(false)
            if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(sz) end
            if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
            lbl:Show(true)
        end
        makeRowLbl("ft_row_name_"..rid.."_"..i, farm.name or "",     COL_NAME_X, NAME_W, FONT_SIZE.MIDDLE or 16)
        makeRowLbl("ft_row_zone_"..rid.."_"..i, zoneName(farm.zone), COL_ZONE_X, ZONE_W, FONT_SIZE.MIDDLE or 16)
        makeRowLbl("ft_row_sext_"..rid.."_"..i, farm.sextants or "", COL_SEXT_X, SEXT_W, FONT_SIZE.SMALL  or 14)

        local btnOpen = rowBg:CreateChildWidget("button", "ft_row_open_"..rid.."_"..i, 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnOpen, BUTTON_BASIC.DEFAULT) end
        btnOpen:SetExtent(BTN_W, 26); btnOpen:RemoveAllAnchors()
        btnOpen:AddAnchor("RIGHT", rowBg, -4, BTN_Y_OFF)
        btnOpen:SetText("Open")
        local capturedId = farm.id
        function btnOpen:OnClick() openDetailWindow(capturedId) end
        btnOpen:SetHandler("OnClick", btnOpen.OnClick); btnOpen:Show(true)

        local btnMap = rowBg:CreateChildWidget("button", "ft_row_map_"..rid.."_"..i, 0, true)
        api.Interface:ApplyButtonSkin(btnMap, BUTTON_CONTENTS.MAP_OPEN)
        btnMap:RemoveAllAnchors()
        btnMap:AddAnchor("RIGHT", rowBg, -(30 + GAP + 24), BTN_Y_OFF)
        local capturedFarm = farm
        function btnMap:OnClick()
            pcall(function() api.Map:ToggleMapWithPortal(323, capturedFarm.worldX, capturedFarm.worldY, 100) end)
        end
        btnMap:SetHandler("OnClick", btnMap.OnClick); btnMap:Show(true)

        local btnDel = rowBg:CreateChildWidget("button", "ft_row_del_"..rid.."_"..i, 0, true)
        api.Interface:ApplyButtonSkin(btnDel, BUTTON_CONTENTS.SKILL_ABILITY_DELETE)
        btnDel:SetExtent(30, 30); btnDel:RemoveAllAnchors()
        btnDel:AddAnchor("RIGHT", rowBg, -((30 + GAP) * 2 + 24), BTN_Y_OFF)
        local capturedIdDel = farm.id
        function btnDel:OnClick() deleteFarm(capturedIdDel); rebuildFarmList() end
        btnDel:SetHandler("OnClick", btnDel.OnClick); btnDel:Show(true)
    end
end

-- ============================================================
-- ADD FARM POPUP
-- ============================================================

local function closeAddFarmPopup()
    if addFarmPopup then addFarmPopup:Show(false) end
end

local function openAddFarmPopup()
    if not addFarmPopup then
        addFarmPopup = api.Interface:CreateEmptyWindow("farm_tracker_add_popup")
        addFarmPopup:SetExtent(POPUP_W, POPUP_H)
        addFarmPopup:RemoveAllAnchors()

        local bg = addFarmPopup:CreateColorDrawable(0.05, 0.05, 0.12, 0.96, "background")
        bg:AddAnchor("TOPLEFT", addFarmPopup, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", addFarmPopup, 0, 0)
        bg:Show(true)

        local titleLbl = addFarmPopup:CreateChildWidget("label", "ft_popup_title", 0, true)
        titleLbl:SetText("New Farm")
        titleLbl:AddAnchor("TOP", addFarmPopup, 0, 10)
        titleLbl:SetAutoResize(true)
        if titleLbl.style then titleLbl.style:SetFontSize(FONT_SIZE.LARGE or 18); titleLbl.style:SetAlign(ALIGN.CENTER) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(titleLbl, FONT_COLOR.DEFAULT) end
        titleLbl:Show(true)

        local nameLbl = addFarmPopup:CreateChildWidget("label", "ft_popup_name_lbl", 0, true)
        nameLbl:SetText("Farm name:")
        nameLbl:AddAnchor("TOPLEFT", addFarmPopup, 12, 40)
        nameLbl:SetAutoResize(true)
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(nameLbl, FONT_COLOR.DEFAULT) end
        nameLbl:Show(true)

        local edit
        if W_CTRL and W_CTRL.CreateEdit then
            edit = W_CTRL.CreateEdit("ft_popup_edit", addFarmPopup)
        else
            edit = addFarmPopup:CreateChildWidget("edit", "ft_popup_edit", 0, true)
        end
        edit:SetExtent(POPUP_W - 24, 28)
        edit:AddAnchor("TOPLEFT", addFarmPopup, 12, 58)
        edit:SetText("My Farm")
        edit:Show(true)
        addFarmPopup._edit = edit

        local btnSave = addFarmPopup:CreateChildWidget("button", "ft_popup_save", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnSave, BUTTON_BASIC.DEFAULT) end
        btnSave:SetExtent(80, 28)
        btnSave:AddAnchor("BOTTOMRIGHT", addFarmPopup, -12, -10)
        btnSave:SetText("Save")
        function btnSave:OnClick()
            local ok, err = pcall(function()
                local name = addFarmPopup._edit:GetText()
                if not name or name == "" then name = "Unnamed Farm" end
                local pos = capturePlayerPosition()
                if not pos then
                    pos = { sextants="", worldX=0, worldY=0, worldZ=0, zone=0 }
                    log("Could not read player sextants — farm saved without coords.")
                end
                local farm = createFarm(name, pos)
                closeAddFarmPopup()
                rebuildFarmList()
                openDetailWindow(farm.id)
            end)
            if not ok then log("Save error: " .. tostring(err)) end
        end
        btnSave:SetHandler("OnClick", btnSave.OnClick)
        btnSave:Show(true)

        local btnCancel = addFarmPopup:CreateChildWidget("button", "ft_popup_cancel", 0, true)
        if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnCancel, BUTTON_BASIC.DEFAULT) end
        btnCancel:SetExtent(80, 28)
        btnCancel:AddAnchor("BOTTOMRIGHT", addFarmPopup, -12 - 80 - GAP, -10)
        btnCancel:SetText("Cancel")
        function btnCancel:OnClick() closeAddFarmPopup() end
        btnCancel:SetHandler("OnClick", btnCancel.OnClick)
        btnCancel:Show(true)
    end

    addFarmPopup:RemoveAllAnchors()
    if mainWin then
        addFarmPopup:AddAnchor("TOPLEFT", mainWin, MAIN_W + 8, 0)
    else
        addFarmPopup:AddAnchor("CENTER", "UIParent", 200, 0)
    end
    if addFarmPopup._edit then addFarmPopup._edit:SetText("My Farm") end
    addFarmPopup:Show(true)
end

-- ============================================================
-- MAIN WINDOW SETUP
-- ============================================================

local function ensureMainWindow()
    if mainWin then return end

    mainWin = api.Interface:CreateWindow("farm_tracker_main", "Farm Tracker", MAIN_W, MAIN_H)
    mainWin:RemoveAllAnchors()
    mainWin:AddAnchor("CENTER", "UIParent", 0, 0)
    mainWin:Show(false)

    function mainWin:OnHide() closeAddFarmPopup() end
    mainWin:SetHandler("OnHide", mainWin.OnHide)

    local hdrBar = mainWin:CreateChildWidget("emptywidget", "ft_hdr_bar", 0, true)
    hdrBar:SetExtent(MAIN_W - 20, 28)
    hdrBar:RemoveAllAnchors()
    hdrBar:AddAnchor("TOPLEFT", mainWin, 4, 36)
    hdrBar:Show(true)

    local function makeHdrLabel(name, txt, xOff, w)
        local lbl = hdrBar:CreateChildWidget("textbox", name, 0, true)
        lbl:SetExtent(w, 28)
        lbl:RemoveAllAnchors()
        lbl:AddAnchor("LEFT", hdrBar, xOff, 0)
        lbl:SetText(txt)
        if lbl.style then lbl.style:SetAlign(ALIGN.LEFT); lbl.style:SetFontSize(FONT_SIZE.LARGE or 18) end
        if ApplyTextColor and FONT_COLOR then ApplyTextColor(lbl, FONT_COLOR.DEFAULT) end
        lbl:Show(true)
    end
    makeHdrLabel("ft_hdr_name", "Farm Name",   COL_NAME_X, NAME_W)
    makeHdrLabel("ft_hdr_zone", "Zone",        COL_ZONE_X, ZONE_W)
    makeHdrLabel("ft_hdr_sext", "Coordinates", COL_SEXT_X, SEXT_W)

    -- Filter
    local filterLbl = mainWin:CreateChildWidget("label", "ft_filter_lbl", 0, true)
    filterLbl:SetText("Filter:")
    filterLbl:SetAutoResize(true)
    filterLbl:RemoveAllAnchors()
    filterLbl:AddAnchor("BOTTOMLEFT", mainWin, 10, -28)
    if filterLbl.style then filterLbl.style:SetAlign(ALIGN.LEFT); filterLbl.style:SetFontSize(FONT_SIZE.LARGE or 18) end
    if ApplyTextColor and FONT_COLOR then ApplyTextColor(filterLbl, FONT_COLOR.DEFAULT) end
    filterLbl:Show(true)

    local filterEdit
    if W_CTRL and W_CTRL.CreateEdit then
        filterEdit = W_CTRL.CreateEdit("ft_filter_edit", mainWin)
    else
        filterEdit = mainWin:CreateChildWidget("edit", "ft_filter_edit", 0, true)
    end
    filterEdit:SetExtent(180, 28)
    filterEdit:RemoveAllAnchors()
    filterEdit:AddAnchor("BOTTOMLEFT", mainWin, 56, -10)
    filterEdit:SetText("")
    filterEdit:Show(true)
    function filterEdit:OnTextChanged()
        local txt = self:GetText() or ""
        filterText = txt:lower()
        if filterDebounce then return end
        filterDebounce = true
        api:DoIn(300, function()
            filterDebounce = false
            currentPage = 1
            rebuildFarmList()
        end)
    end
    filterEdit:SetHandler("OnTextChanged", filterEdit.OnTextChanged)
    mainWin._filterEdit = filterEdit

    -- Add Farm button
    local btnAdd = mainWin:CreateChildWidget("button", "ft_btn_add_farm", 0, true)
    if ApplyButtonSkin and BUTTON_BASIC then ApplyButtonSkin(btnAdd, BUTTON_BASIC.DEFAULT) end
    btnAdd:SetExtent(90, 28); btnAdd:RemoveAllAnchors()
    btnAdd:AddAnchor("BOTTOMRIGHT", mainWin, -10, -10)
    btnAdd:SetText("+ Add Farm")
    function btnAdd:OnClick() openAddFarmPopup() end
    btnAdd:SetHandler("OnClick", btnAdd.OnClick); btnAdd:Show(true)

    -- Pagination
    local pageCtrl = W_CTRL.CreatePageControl("ft_pagectrl", mainWin, "tutorial")
    pageCtrl:RemoveAllAnchors()
    pageCtrl:AddAnchor("BOTTOM", mainWin, 0, -10)
    function pageCtrl:ProcOnPageChanged(pageIndex)
        currentPage = pageIndex
        rebuildFarmList()
    end
    pageCtrl:Show(true)
    mainWin._pageCtrl = pageCtrl

    local sep = mainWin:CreateColorDrawable(0.3, 0.3, 0.5, 0.5, "background")
    sep:SetExtent(MAIN_W - 20, 1); sep:RemoveAllAnchors()
    sep:AddAnchor("BOTTOMLEFT", mainWin, 10, -46); sep:Show(true)
end

local function openMainWindow()
    ensureMainWindow()
    currentPage    = 1
    filterText     = ""
    filterDebounce = false
    if mainWin._filterEdit then mainWin._filterEdit:SetText("") end
    loadAllFarms()
    rebuildFarmList()
    mainWin:Show(true)
end

toggleMainWindow = function()
    ensureMainWindow()
    if mainWin:IsVisible() then
        mainWin:Show(false)
        closeAddFarmPopup()
    else
        openMainWindow()
    end
end

-- ============================================================
-- LAUNCHER BUTTON (System Config Frame)
-- ============================================================

local function createLauncherButton()
    local ok, configMenu = pcall(function() return ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME) end)
    if not ok or not configMenu then return end

    local btn = configMenu:CreateChildWidget("button", "farm_tracker_config_btn", 0, true)
    btn:SetExtent(110, 28)
    btn:RemoveAllAnchors()
    btn:AddAnchor("TOP", configMenu, "BOTTOM", 0, 5)
    btn:SetText("Farm Tracker")
    btn.bg = btn:CreateNinePartDrawable("ui/common/tab_list.dds", "background")
    btn.bg:SetTextureInfo("bg_quest")
    btn.bg:SetColor(0, 0, 0, 0.5)
    btn.bg:AddAnchor("TOPLEFT", btn, 0, 0)
    btn.bg:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
    function btn:OnClick() toggleMainWindow() end
    btn:SetHandler("OnClick", btn.OnClick)
    btn:Show(true)
end



local function OnLoad()
    -- Unix time derived from TimeToDate via dateToUnix() — no GetLocalTime() needed

    local ok, err
    ok, err = pcall(loadSettings)
    if not ok then log("Failed to load settings: " .. tostring(err)) end

    ok, err = pcall(createDoodadListener)
    if not ok then log("Failed to create doodad listener: " .. tostring(err)) end

    ok, err = pcall(createLauncherButton)
    if not ok then log("Failed to create launcher button: " .. tostring(err)) end

    if settings.showFloatingBtn then
        api:DoIn(200, function() pcall(createFloatingBtn) end)
    end

    api.On("UPDATE", OnUpdate)
end

local function OnUnload()
    if floatingBtn   then floatingBtn:Show(false)     end
    if mainWin      then mainWin:Show(false)       end
    if detailWin    then detailWin:Show(false)     end
    if filterWin    then filterWin:Show(false)     end
    if settingsWin  then settingsWin:Show(false)   end
    if addFarmPopup then addFarmPopup:Show(false)  end
    saveSettings()
end

local function OnSettingToggle()
    openSettingsWindow()
end

addon.OnLoad          = OnLoad
addon.OnUnload        = OnUnload
addon.OnSettingToggle = OnSettingToggle

return addon
