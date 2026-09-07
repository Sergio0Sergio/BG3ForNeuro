-- BG3Neuro v0.8.11 вЂ” С„Р°Р№Р»РѕРІС‹Р№ IPC-РјРѕСЃС‚ (С‚РёРєРµС‚С‹ 01 + 03-09)
-- Р—Р°РґР°С‡Р°: heartbeat 2s + СЃС‚Р°СЂС‚РѕРІС‹Р№ state-С„Р°Р№Р» + РёСЃРїРѕР»РЅРµРЅРёРµ РґРµР№СЃС‚РІРёР№ РёР· action_*.json.
-- Р”РµР№СЃС‚РІРёСЏ: end_turn (03), move_to_target / attack_entity (04), cast_spell (05),
--           select_dialogue_option (07, client-РєРѕРЅС‚РµРєСЃС‚), exploration (08:
--           move_to_entity / interact_with / loot / rest / travel_to /
--           open_map / open_inventory / toggle_mode) вЂ” РґР»РёРЅРЅС‹Рµ РґРµР№СЃС‚РІРёСЏ
-- СЃ РґРІСѓС…С„Р°Р·РЅС‹Рј running:true (РїСЂРѕРјРµР¶СѓС‚РѕС‡РЅС‹Р№ ack) Рё С„РёРЅР°Р»РѕРј РїРѕ РёРіСЂРѕРІРѕРјСѓ СЃРѕР±С‹С‚РёСЋ.
-- Dumb-РјРѕРґСѓР»СЊ: С‚РѕР»СЊРєРѕ СЃРѕСЃС‚РѕСЏРЅРёРµ Рё РёСЃРїРѕР»РЅРµРЅРёРµ, Р±РµР· Р»РѕРіРёРєРё СЂРµС€РµРЅРёР№ (СЂРµС€РµРЅРёРµ вЂ” РІ C#).
-- Р”РёСЂРµРєС‚РѕСЂРёСЏ IPC: <BG3ScriptExtender appdata>/BG3Neuro (Ext.IO РїРёС€РµС‚ РѕС‚РЅРѕСЃРёС‚РµР»СЊРЅРѕ Script Extender).

local MOD_NAME = "BG3Neuro"
local MOD_VERSION = "0.8.11"
local IPC_DIR = "BG3Neuro"
local HEARTBEAT_INTERVAL_MS = 2000 -- config.ipc.heartbeat_interval_s * 1000
local ACTION_POLL_MS = 200          -- config.ipc.poll_interval_ms * 2 (СЂРµР°Р»СЊРЅС‹Р№ polling)
local STATE_FILE = IPC_DIR .. "/bg3_to_neuro.json"
local HEARTBEAT_FILE = IPC_DIR .. "/heartbeat.json"
local NEURO_TO_BG3_FILE = IPC_DIR .. "/neuro_to_bg3.json"
local RESULT_DIR = IPC_DIR

local seq = 0
local activeMove = nil -- { id, event, moveId } вЂ” РґРІРёР¶РµРЅРёРµ РІ РїРѕР»С‘С‚Рµ (interruption/cancel)

local function nowIso()
    -- UTC: Ext.Timer.ClockTime() РґР°С‘С‚ "YYYY-MM-DD HH:MM:SS.fffffff" (UTC);
    -- РЅРѕСЂРјРёСЂСѓРµРј РІ ISO-8601 РґР»СЏ СЃСЂР°РІРЅРµРЅРёСЏ СЃ DateTimeOffset.UtcNow РЅР° C#-СЃС‚РѕСЂРѕРЅРµ.
    -- (os РЅРµРґРѕСЃС‚СѓРїРµРЅ РІ РїРµСЃРѕС‡РЅРёС†Рµ SE вЂ” os.date РёСЃРїРѕР»СЊР·РѕРІР°С‚СЊ РЅРµР»СЊР·СЏ)
    return (Ext.Timer.ClockTime() or ""):gsub(" ", "T") .. "Z"
end

local function writeHeartbeat()
    seq = seq + 1
    local payload = {
        mod = MOD_NAME,
        version = MOD_VERSION,
        seq = seq,
        timestamp = nowIso(),
    }
    local ok, err = pcall(Ext.IO.SaveFile, HEARTBEAT_FILE, Ext.Json.Stringify(payload))
    if not ok then
        _P("[BG3Neuro] heartbeat: " .. tostring(err))
    end
end

local function startHeartbeatLoop()
    writeHeartbeat()
    Ext.Timer.WaitForRealtime(HEARTBEAT_INTERVAL_MS, startHeartbeatLoop)
end

local function writeInitialState()
    local state = {
        version = 1,
        mode = "loading",
        generated_at = nowIso(),
        entities = {},
        message = "РњРѕРґ РёРЅРёС†РёР°Р»РёР·РёСЂРѕРІР°РЅ, СЃРѕСЃС‚РѕСЏРЅРёРµ Р·Р°РіСЂСѓР¶Р°РµС‚СЃСЏ",
    }
    local ok, err = pcall(Ext.IO.SaveFile, STATE_FILE, Ext.Json.Stringify(state))
    if not ok then
        _P("[BG3Neuro] initial state: " .. tostring(err))
    end
end

-- ============================================================
-- ActionExecutor (С‚РёРєРµС‚С‹ 03 + 04): reading actions served by C#
-- ============================================================

local function readInFlightAction()
    -- C# РїРёС€РµС‚ РµРґРёРЅСЃС‚РІРµРЅРЅС‹Р№ current action РІ neuro_to_bg3.json:
    -- { "id": "...", "name": "...", "data": "{\"...\":...}" }
    local ok, content = pcall(Ext.IO.LoadFile, NEURO_TO_BG3_FILE)
    if not ok or content == nil or content == "" then
        return nil
    end
    local okParse, action = pcall(Ext.Json.Parse, content)
    if not okParse or type(action) ~= "table" then
        return nil
    end
    return action
end

local function writeResult(actionId, success, running, errorCode, errorDetail, extra)
    local payload = { id = actionId, success = success }
    if running then
        payload.running = true
    end
    if errorCode then
        payload.error_code = errorCode
    end
    if errorDetail then
        payload.error_detail = errorDetail
    end
    if extra ~= nil and type(extra) == "table" then
        for k, v in pairs(extra) do
            payload[k] = v
        end
    end
    local path = RESULT_DIR .. "/result_" .. actionId .. ".json"
    local ok, err = pcall(Ext.IO.SaveFile, path, Ext.Json.Stringify(payload))
    if not ok then
        _P("[BG3Neuro] write result " .. actionId .. ": " .. tostring(err))
    end
    return ok
end

-- РњР°РїРїРёРЅРі РїСЃРµРІРґРѕРЅРёРјРѕРІ state в†’ GUID, РїСЂРёС…РѕРґРёС‚ РёР· StateExtractor/СЂРµРіРёСЃС‚СЂР°С†РёРё Р±РѕСЏ.
-- Р’ v0.3 Р·Р°РїРѕР»РЅСЏРµС‚СЃСЏ РІ РјРѕРјРµРЅС‚ РґРёСЃРїР°С‚С‡Р° РёР· РґР°РЅРЅС‹С… РґРµР№СЃС‚РІРёСЏ; РґР»СЏ move/attack С„РёРЅР°Р»СЊРЅС‹Р№
-- GUID-РїСѓС‚СЊ (Р±РѕРµРІРѕР№ СЂРµРµСЃС‚СЂ СЃСѓС‰РЅРѕСЃС‚РµР№) РїРѕРґРєР»СЋС‡Р°РµС‚СЃСЏ РІ С‚РёРєРµС‚Рµ state-generator.
local ENTITY_BY_ALIAS = {}

local function isGuid(v)
    return type(v) == "string" and v:find("[0-9a-fA-F]%-") ~= nil
end

local function resolveEntity(alias)
    if alias == nil or alias == "" then
        return nil
    end
    if isGuid(alias) then
        return alias
    end
    return ENTITY_BY_ALIAS[alias]
end

-- ============================================================
-- Turn intelligence (probe + end_turn): С‚РµРєСѓС‰РёР№ РґРµР№СЃС‚РІСѓСЋС‰РёР№ РїРµСЂСЃРѕРЅР°Р¶
-- РѕРїСЂРµРґРµР»СЏРµС‚СЃСЏ РІ РјРѕРґРµ (GetCurrentCharacter РїРѕ reserved user id),
-- Р° РЅРµ РёР· СЃР»РµРїРѕ Р·Р°РїРѕРјРЅРµРЅРЅРѕРіРѕ App-РѕРј GUID. Р­С‚Рѕ СѓР±РёСЂР°РµС‚ СЂР°СЃСЃРёРЅС…СЂРѕРЅ
-- "РєС‚Рѕ С…РѕРґРёС‚" РїСЂРё Р¶РёРІС‹С… combat-РїСЂРѕРІРµСЂРєР°С….
-- ============================================================

-- Story-Р»Р°С‚С‡ С…РѕРґР° (v0.7.3): RegisterListener РЅР° TurnStarted/TurnEnded РґР°С‘С‚
-- РµРґРёРЅСЃС‚РІРµРЅРЅСѓСЋ РїСЂР°РІРґСѓ "РєС‚Рѕ СЃРµР№С‡Р°СЃ С…РѕРґРёС‚" вЂ” РґРІРёР¶РєРѕРІС‹Р№ С…РѕРґ РґРІРёРіР°РµС‚СЃСЏ СЃР°Рј, Р° story
-- Р»РёС€СЊ РЅР°Р±Р»СЋРґР°РµС‚ (Osiris-Р»РѕРі: TurnEnded РїСЂРёС…РѕРґРёС‚ Р±РµР· РІС‹Р·РѕРІР° EndTurn). Р­С‚Рѕ Рё РµСЃС‚СЊ
-- Р±Р°Р·Р° Рё РґР»СЏ СЃР°РјРѕРїСЂРѕРІРµСЂРєРё СЌС„С„РµРєС‚Р° end_turn (ended: true/false).
local actingChar = nil
local turnLog = {}   -- { t = "S"|"E", g = guid } вЂ” Р»РµРЅС‚Р° РїРѕСЃР»РµРґРЅРёС… СЃРјРµРЅ С…РѕРґР°

Ext.Osiris.RegisterListener("TurnStarted", 1, "after", function(guid)
    actingChar = guid
    turnLog[#turnLog + 1] = { t = "S", g = tostring(guid) }
    if #turnLog > 32 then
        table.remove(turnLog, 1)
    end
    -- StateExtractor (v0.8.11): каждый сменённый ход — новый combat-state в bg3_to_neuro.json.
    captureCombatState("TurnStarted", false)
end)

Ext.Osiris.RegisterListener("TurnEnded", 1, "after", function(guid)
    turnLog[#turnLog + 1] = { t = "E", g = tostring(guid) }
    if #turnLog > 32 then
        table.remove(turnLog, 1)
    end
end)

local function turnLogSlice(marker, n)
    -- n РїРѕСЃР»РµРґРЅРёС… Р·Р°РїРёСЃРµР№ Р»РµРЅС‚С‹ РЅР°С‡РёРЅР°СЏ РїРѕСЃР»Рµ marker (РґР»СЏ СЃР°РјРѕРїСЂРѕРІРµСЂРєРё end_turn)
    local out = {}
    for i = marker + 1, math.min(#turnLog, marker + (n or 16)) do
        out[#out + 1] = { turnLog[i].t, turnLog[i].g }
    end
    return out
end

local function dbRowsRead(name, arity)
    -- Р‘РµР·РѕРїР°СЃРЅРѕРµ С‡С‚РµРЅРёРµ Osiris-DB РїРѕ РёРјРµРЅРё: Osi.DB_X:Get(nil,...); РІРѕР·РІСЂР°С‰Р°РµС‚
    -- РїР»РѕСЃРєРёР№ РјР°СЃСЃРёРІ СЃС‚СЂРѕРє РёР»Рё nil, РµСЃР»Рё Р‘Р” РЅРµС‚/РЅРµС‡РёС‚Р°РµРјР°. arity вЂ” С‡РёСЃР»Рѕ РєРѕР»РѕРЅРѕРє.
    local rows
    local function tryGet(obj)
        -- Get СЃ СЏРІРЅС‹Рј РєРѕР»РёС‡РµСЃС‚РІРѕРј РїСѓСЃС‚С‹С… С„РёР»СЊС‚СЂРѕРІ (Р°СЂРЅРѕСЃС‚СЊ 1..3), fallback Get().
        if arity == 1 then
            local ok, r = pcall(function() return obj:Get(nil) end)
            if ok and type(r) == "table" then return r end
        elseif arity == 2 then
            local ok, r = pcall(function() return obj:Get(nil, nil) end)
            if ok and type(r) == "table" then return r end
        elseif arity == 3 then
            local ok, r = pcall(function() return obj:Get(nil, nil, nil) end)
            if ok and type(r) == "table" then return r end
        end
        local ok, r = pcall(function() return obj:Get() end)
        if ok and type(r) == "table" then return r end
        return nil
    end
    local okO, o = pcall(function() return Osi["DB_" .. name] end)
    if okO and type(o) == "table" and type(o.Get) == "function" then
        rows = tryGet(o)
    end
    if rows == nil and Ext ~= nil and Ext.Osiris ~= nil and Ext.Osiris.GetDatabase ~= nil then
        local okG, gd = pcall(Ext.Osiris.GetDatabase, name)
        if okG and type(gd) == "table" and type(gd.Get) == "function" then
            rows = tryGet(gd)
        end
    end
    if rows == nil then
        return nil
    end
    local flat = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local parts = {}
            for j = 1, #row do
                parts[#parts + 1] = tostring(row[j])
            end
            flat[#flat + 1] = table.concat(parts, "|")
        else
            flat[#flat + 1] = tostring(row)
        end
    end
    return flat
end

local function dumpDb(name)
    -- РђРєРєСѓСЂР°С‚РЅС‹Р№ РґР°РјРї Osiris-DB (Avatars / CharacterSkipTurn / ...).
    -- Р›СЋР±Р°СЏ РѕРїРµСЂР°С†РёСЏ СЃ Osi/Ext.Osiris РІ pcall: РІ СЂР°Р·РЅС‹С… РєРѕРЅС‚РµРєСЃС‚Р°С…
    -- (client/server, story) Сѓ Р‘Р” РјРѕР¶РµС‚ РЅРµ Р±С‹С‚СЊ РјРµС‚РѕРґР° Get РёР»Рё РѕРЅР° РІРѕРѕР±С‰Рµ
    -- РїСЂРѕРєСЃРё-РѕР±СЉРµРєС‚ Р±РµР· С‚РёРїР° table вЂ” С‚Р°РєРёРµ СЃР»СѓС‡Р°Рё РЅРµ РґРѕР»Р¶РЅС‹ СЂРѕРЅСЏС‚СЊ action.
    local db
    local okIdx, o = pcall(function() return Osi["DB_" .. name] end)
    if okIdx and type(o) == "table" and type(o.Get) == "function" then
        db = o
    end
    if db == nil and Ext ~= nil and Ext.Osiris ~= nil and Ext.Osiris.GetDatabase ~= nil then
        local okGd, gd = pcall(Ext.Osiris.GetDatabase, name)
        if okGd and type(gd) == "table" then
            db = gd
        end
    end
    if db == nil then
        return nil
    end
    local rows
    local ok, r = pcall(function() return db:Get(nil) end)
    if ok and type(r) ~= "table" then
        ok, r = pcall(function() return db:Get() end)
    end
    if not ok or type(r) ~= "table" then
        return nil
    end
    rows = r
    local flat = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local parts = {}
            for j = 1, #row do
                parts[#parts + 1] = tostring(row[j])
            end
            flat[#flat + 1] = table.concat(parts, "|")
        else
            flat[#flat + 1] = tostring(row)
        end
    end
    return flat
end

local function pureGuid(s)
    -- Osi.GetCurrentCharacter returns prefixed ids (e.g. S_Player_Astarion_<uuid>),
    -- while HandleToUuid yields the clean uuid. Normalize to the trailing hex uuid.
    if s == nil then
        return nil
    end
    s = tostring(s)
    local m = s:match("([%x][%x][%x][%x][%x][%x][%x][%x]-[%x][%x][%x][%x]-[%x][%x][%x][%x]-[%x][%x][%x][%x]-[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x])$")
    return m or s
end

local function currentCharacters()
    -- РўРµРєСѓС‰РёР№ СѓРїСЂР°РІР»СЏРµРјС‹Р№(Рµ) РїРµСЂСЃРѕРЅР°Р¶(Рё): РґР»СЏ reserved user id. Р’ РѕРґРёРЅРѕС‡РєРµ host
    -- РјРѕР¶РµС‚ Р±С‹С‚СЊ user 1 (peer+1); РїРµСЂРµР±РёСЂР°РµРј С€РёСЂРµ, С‡РµРј 0..3 (v0.7.3).
    local users = { 1, 2, 3, 4, 0, 256, 65536 }
    local out = {}
    for _, user in ipairs(users) do
        local ok, ch = pcall(Osi.GetCurrentCharacter, user)
        if ok and ch ~= nil and ch ~= "" then
            out[#out + 1] = { user = user, character = ch }
        end
    end
    return out
end

local function partyAvatars()
    -- Party members (server-side, robust): DB_Avatars rows plus entities that
    -- carry the UserAvatar component. Keys are clean pure guids.
    local out = {}
    local ok, rows = pcall(dumpDb, "Avatars")
    if ok and type(rows) == "table" then
        for _, r in ipairs(rows) do
            local s = tostring(r or "")
            for tok in (s .. "|"):gmatch("(.-)|") do
                local p = pureGuid(tok)
                if p ~= nil and p ~= "" then
                    out[p] = true
                end
            end
        end
    end
    local ok2, hs = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("UserAvatar") end)
    if ok2 and hs ~= nil then
        for i = 1, #hs do
            local okH, g = pcall(Ext.Entity.HandleToUuid, hs[i])
            if okH and g ~= nil and g ~= "" then
                out[pureGuid(tostring(g))] = true
            end
        end
    end
    return out
end

local function characterPartyFlags(g)
    -- Серверный компонент Character (EsvCharacter) даёт InParty/IsPlayer/PartyFollower —
    -- надёжный признак членов партии, независимый от DB_Avatars/UserAvatar.
    local okE, ent = pcall(Ext.Entity.Get, g)
    if not okE or ent == nil then
        return nil
    end
    local okC, comp = pcall(function() return ent:GetComponent("ServerCharacter") end)
    if not okC or comp == nil then
        return nil
    end
    local raw = {}
    local function grabRaw(tag, f)
        local ok, v = pcall(function() return comp[f] end)
        if ok then
            raw[tag] = tostring(v) .. " (" .. type(v) .. ")"
        else
            raw[tag] = "ERR: " .. tostring(v)
        end
    end
    grabRaw("InParty", "InParty")
    grabRaw("IsPlayer", "IsPlayer")
    grabRaw("PartyFollower", "PartyFollower")
    local truthy = function(tag)
        return raw[tag] ~= nil and raw[tag] ~= "false (boolean)" and raw[tag] ~= "0 (number)" and raw[tag] ~= "ERR"
    end
    return {
        in_party = truthy("InParty"),
        is_player = truthy("IsPlayer"),
        party_follower = truthy("PartyFollower"),
        raw = raw,
    }
end

local function actingCleanOf(actor)
    -- Deterministic clean guid for the actor: same pipeline as participant guids
    -- (HandleToUuid on an EntityHandle), so string equality with participants
    -- is guaranteed regardless of prefixed id formats from Osiris.
    if actor == nil or actor == "" then
        return ""
    end
    local okU, h = pcall(Ext.Entity.UuidToHandle, actor)
    if okU and h ~= nil then
        local ok1, g = pcall(Ext.Entity.HandleToUuid, h)
        if ok1 and g ~= nil then
            return tostring(g)
        end
    end
    return pureGuid(actor) or ""
end

local function resolveActingCharacter(explicit)
    -- РЇРІРЅС‹Р№ actor (РѕС‚ C#) вЂ” РїСЂРёРѕСЂРёС‚РµС‚; Р·Р°С‚РµРј story-Р»Р°С‚С‡ (TurnStarted Р±РµР· TurnEnded);
    -- Р·Р°С‚РµРј РєРѕРЅС‚СЂРѕР»РёСЂСѓРµРјС‹Р№ СЃРµР№С‡Р°СЃ РїРµСЂСЃРѕРЅР°Р¶.
    if explicit ~= nil and explicit ~= "" then
        return explicit
    end
    if actingChar ~= nil and actingChar ~= "" then
        return actingChar
    end
    local cc = currentCharacters()
    if #cc > 0 then
        return cc[1].character
    end
    return ""
end

local entityTurnComponentDump

local function probeGameState()
    -- Р”РёР°РіРЅРѕСЃС‚РёРєР° РґР»СЏ StateExtractor-СЃРёРґР°: РєС‚Рѕ С…РѕРґРёС‚ СЃРµР№С‡Р°СЃ, РєС‚Рѕ РІ Р±РѕСЋ.
    -- РљР°Р¶РґС‹Р№ С€Р°Рі РЅРµР·Р°РІРёСЃРёРј: РїР°РґРµРЅРёРµ РѕРґРЅРѕРіРѕ РЅРµ Р»РёС€Р°РµС‚ РѕСЃС‚Р°Р»СЊРЅС‹С… РґР°РЅРЅС‹С….
    local out = { current_characters = {} }
    local okAv, av = pcall(dumpDb, "Avatars")
    out.avatars = okAv and av or nil
    local okSk, sk = pcall(dbRowsRead, "CharacterSkipTurn", 1)
    out.skip_turn = okSk and sk or nil
    local okGe, ge = pcall(dbRowsRead, "GEN_EndTurn", 2)
    out.gen_end_turn = okGe and ge or nil
    out.turn_acting = actingChar
    out.turn_log = turnLogSlice(0, 8)
    local actingResolved = resolveActingCharacter("")
    if actingResolved ~= nil and actingResolved ~= "" then
        local okTe, te = pcall(entityTurnComponentDump, actingResolved)
        out.turn_entity = okTe and te or { error = tostring(te) }
    end
    -- combat-state сущности: сколько боёв активно и участников (v0.8.11)
    local okCs, cs = pcall(function()
        local list = Ext.Entity.GetAllEntitiesWithComponent("CombatState") or {}
        local res = {}
        for i = 1, #list do
            local uuid = tostring(Ext.Entity.HandleToUuid(list[i]) or "")
            res[#res + 1] = { index = i, uuid = uuid }
        end
        return res
    end)
    out.combat_states = okCs and cs or nil
    for _, cc in ipairs(currentCharacters()) do
        local name = nil
        if type(Osi.GetDisplayName) == "function" then
            local okN, n = pcall(Osi.GetDisplayName, cc.character)
            name = okN and n or nil
        end
        out.current_characters[#out.current_characters + 1] = {
            user = cc.user,
            character = cc.character,
            display_name = name,
        }
    end
    return out
end

-- ============================================================
-- ECS-РґРёР°РіРЅРѕСЃС‚РёРєР° (v0.7.4): РґРІРёР¶РєРѕРІС‹Р№ turn-РјРµРЅРµРґР¶РµСЂ, РЅРµ story.
-- РљРѕРјРїРѕРЅРµРЅС‚ РїРµСЂСЃРѕРЅР°Р¶Р° EocCombatTurnBasedComponent (entity.TurnBased):
--   IsActiveCombatTurn / CanActInCombat / CanAct_M / ActedThisRoundInCombat /
--   HadTurnInCombat / RequestedEndTurn / EndTurnHoldTimer /
--   TurnActionsCompleted / Timeout / PauseTimer / Combat / CombatTeam.
-- CombatState (EocCombatStateComponent) Р»РµР¶РёС‚ РЅР° combat-СЃСѓС‰РЅРѕСЃС‚Рё:
--   MyGuid / Participants / Initiatives / IsInNarrativeCombat / Level.
-- ============================================================

local TURN_FIELDS = {
    "IsActiveCombatTurn", "CanActInCombat", "CanAct_M", "ActedThisRoundInCombat",
    "HadTurnInCombat", "RequestedEndTurn", "EndTurnHoldTimer",
    "TurnActionsCompleted", "Timeout", "PauseTimer", "Combat", "CombatTeam",
}

local COMBAT_FIELDS = {
    "MyGuid", "IsInNarrativeCombat", "Level", "Participants", "Initiatives",
}

local function readComponentFields(component, fields)
    -- РќР°РґС‘Р¶РЅРѕРµ С‡С‚РµРЅРёРµ СЃРєР°Р»СЏСЂРЅС‹С… РїРѕР»РµР№ РєРѕРјРїРѕРЅРµРЅС‚Р° (РєР°Р¶РґРѕРµ РІ pcall; РєР»Р°СЃСЃ/РїСЂРѕРєСЃРё:
    -- Р·РЅР°С‡РµРЅРёСЏ Р»СЋР±С‹С… С‚РёРїРѕРІ РЅРѕСЂРјРёСЂСѓСЋС‚СЃСЏ, С‡С‚РѕР±С‹ РЅРµ Р»РѕРјР°С‚СЊ Ext.Json.Stringify).
    local out = {}
    for _, f in ipairs(fields) do
        local ok, v = pcall(function() return component[f] end)
        if ok and v ~= nil then
            local tv = type(v)
            if tv == "number" or tv == "boolean" or tv == "string" then
                out[f] = v
            elseif tv == "table" then
                out[f] = { __count = #v }
            else
                out[f] = tostring(v)
            end
        else
            out[f] = nil
        end
    end
    return out
end

function entityTurnComponentDump(guid)
    -- Р”Р°РјРї turn-РєРѕРјРїРѕРЅРµРЅС‚Р° РїРµСЂСЃРѕРЅР°Р¶Р° + combat-СЃСѓС‰РЅРѕСЃС‚Рё (read-only).
    local out = {}
    if Ext == nil or Ext.Entity == nil then
        return { available = false }
    end
    local okE, ent = pcall(Ext.Entity.Get, guid)
    if not okE or ent == nil then
        return { available = false, error = "РЅРµС‚ СЃСѓС‰РЅРѕСЃС‚Рё" }
    end
    local okC, comp = pcall(function() return ent:GetComponent("TurnBased") end)
    if okC and comp ~= nil then
        out.turn_based = readComponentFields(comp, TURN_FIELDS)
    else
        out.turn_based = nil
    end
    if out.turn_based ~= nil and out.turn_based.Combat ~= nil then
        local okE2, combatEnt = pcall(Ext.Entity.Get, out.turn_based.Combat)
        if okE2 and combatEnt ~= nil then
            local okC2, combatComp = pcall(function() return combatEnt:GetComponent("CombatState") end)
            if okC2 and combatComp ~= nil then
                local d = readComponentFields(combatComp, COMBAT_FIELDS)
                if d.Participants ~= nil then
                    d.Participants = { __count = d.Participants.__count }
                end
                if d.Initiatives ~= nil then
                    d.Initiatives = { __count = d.Initiatives.__count }
                end
                out.combat_state = d
            end
            local okC3, torder = pcall(function() return combatEnt:GetComponent("TurnOrder") end)
            if okC3 and torder ~= nil then
                out.turn_order = readComponentFields(torder, { "TurnOrderParticipants", "Groups2" })
            end
        end
    end
    return out
end

-- ============================================================
-- StateExtractor (v0.8.11): Канал B — наблюдение.
-- На каждый TurnStarted (или по действию state_capture) строит combat-state
-- по схеме C# CombatState (snake_case) и пишет его в bg3_to_neuro.json:
--   turn_actor + инициатива, allies/enemies (alias, name, hp, max_hp, distance,
--   position_x/y, effects/status), available_actions.
-- Дополнительно регистрирует alias→guid в ENTITY_BY_ALIAS, чтобы
-- move_to_target/attack_entity/cast_spell резолвили цели по коротким именам;
-- псевдонимы стабильны в рамках одного боя (один и тот же враг — один и тот же alias).
-- Классификация команды: партийные (reserved user id) + участники с тем же
-- CombatTeam, что и у партии; все остальные участники — враги.
-- ============================================================

local STATE_VERSION = 2

local translitMap = {
    ["а"] = "a", ["б"] = "b", ["в"] = "v", ["г"] = "g", ["д"] = "d", ["е"] = "e",
    ["ё"] = "e", ["ж"] = "zh", ["з"] = "z", ["и"] = "i", ["й"] = "y", ["к"] = "k",
    ["л"] = "l", ["м"] = "m", ["н"] = "n", ["о"] = "o", ["п"] = "p", ["р"] = "r",
    ["с"] = "s", ["т"] = "t", ["у"] = "u", ["ф"] = "f", ["х"] = "h", ["ц"] = "ts",
    ["ч"] = "ch", ["ш"] = "sh", ["щ"] = "sch", ["ъ"] = "", ["ы"] = "y", ["ь"] = "",
    ["э"] = "e", ["ю"] = "yu", ["я"] = "ya",
}
do
    -- string.lower не обрабатывает многобайтовую кириллицу, поэтому заглавные
    -- ключи добавляем явно (код-поинт заглавной = строчная - 0x20).
    local function uchar(cp)
        if utf8 ~= nil and utf8.char ~= nil then
            return utf8.char(cp)
        end
        return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    end
    for k, v in pairs(translitMap) do
        local b1, b2 = k:byte(1, 2)
        if b1 and b2 and b1 >= 0xD0 then
            local cp = ((b1 & 0x1F) << 6) | (b2 & 0x3F)
            local up
            if cp >= 0x430 and cp <= 0x44F then
                up = cp - 0x20
            elseif cp == 0x451 then
                up = 0x401
            end
            if up ~= nil then
                translitMap[uchar(up)] = v
            end
        end
    end
end

local function translit(s)
    -- Побайтовый UTF-8-декодер: строки здесь всегда валидный UTF-8 (DisplayName),
    -- без зависимости от модуля utf8. Кириллица → латиница через translitMap.
    s = tostring(s or "")
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local b1 = s:byte(i)
        if b1 == nil then
            break
        end
        local c
        if b1 < 0x80 then
            c = string.char(b1)
            i = i + 1
        elseif b1 < 0xE0 then
            c = string.char(b1, s:byte(i + 1))
            i = i + 2
        elseif b1 < 0xF0 then
            c = string.char(b1, s:byte(i + 1), s:byte(i + 2))
            i = i + 3
        else
            c = string.char(b1, s:byte(i + 1), s:byte(i + 2), s:byte(i + 3))
            i = i + 4
        end
        out[#out + 1] = translitMap[c] or c
    end
    return table.concat(out):lower()
end

local function slug(s)
    s = translit(s)
    s = s:gsub("[^%a%d]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return (#s == 0) and "entity" or s
end

local function round1(v)
    if type(v) ~= "number" then
        return nil
    end
    local sign = v >= 0 and 0.5 or -0.5
    return math.floor(v * 10 + sign) / 10
end

local function positionOf(guid)
    local ok, x, y, z = pcall(Osi.GetPosition, guid)
    if not ok or x == nil then
        return nil, nil, nil
    end
    return x, y, z
end

local function distance3(x1, y1, z1, x2, y2, z2)
    if x1 == nil or x2 == nil then
        return nil
    end
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2 + (z1 - z2) ^ 2)
end

local function displayName(guid)
    -- Human-readable (localized) name from the DisplayName component, when present.
    if guid ~= nil and guid ~= "" then
        local okE, ent = pcall(Ext.Entity.Get, guid)
        if okE and ent ~= nil then
            local okC, dnc = pcall(function() return ent:GetComponent("DisplayName") end)
            if okC and dnc ~= nil then
                local okN, dname = pcall(function() return dnc.Name end)
                if okN and dname ~= nil and tostring(dname) ~= "" then
                    local okG, s = pcall(function() return dname:Get() end)
                    if okG and s ~= nil and tostring(s) ~= "" then
                        return tostring(s)
                    end
                end
            end
        end
    end
    if type(Osi.GetDisplayName) == "function" then
        local ok, n = pcall(Osi.GetDisplayName, guid)
        if ok and n ~= nil then
            return tostring(n)
        end
    end
    return tostring(guid)
end

local function fieldOf(comp, f)
    -- Чтение поля компонента без падения: отсутствующее поле бросает
    -- "Property does not exist" — pcall и nil.
    if comp == nil then
        return nil
    end
    local ok, v = pcall(function() return comp[f] end)
    if ok then
        return v
    end
    return nil
end

local function turnComponent(ent)
    if ent == nil then
        return nil
    end
    local ok, comp = pcall(function() return ent:GetComponent("TurnBased") end)
    if ok and comp ~= nil then
        return comp
    end
    return nil
end

local function healthOf(ent)
    if ent == nil then
        return 0, 0
    end
    local ok, comp = pcall(function() return ent:GetComponent("Health") end)
    if ok and comp ~= nil then
        return fieldOf(comp, "Hp") or 0, fieldOf(comp, "MaxHp") or 0
    end
    return 0, 0
end

-- guid → alias: устойчиво в рамках одного боя, чтобы Neuro и router работали с
-- одними и теми же короткими именами на каждом тике state.
local combatAliases = {}
local lastCombatGuid = nil

local function registerAlias(guid, isControlled, taken)
    local existing = combatAliases[guid]
    if existing then
        taken[existing] = true
        return existing
    end
    local base = slug(displayName(guid))
    local alias
    if isControlled then
        -- партийные: имя как есть (karlach / shadowheart / tav), при коллизии — суффикс
        alias = base
        local i = 1
        while taken[alias] do
            i = i + 1
            alias = base .. "_" .. i
        end
    else
        -- враги: имя с номером (goblin_1, goblin_2, ...)
        local i = 0
        repeat
            i = i + 1
            alias = base .. "_" .. i
        until not taken[alias]
    end
    taken[alias] = true
    combatAliases[guid] = alias
    ENTITY_BY_ALIAS[alias] = guid
    return alias
end

local function participantGuids(combatComp)
    -- CombatState.Participants — Array<EntityHandle> (SE array-like: userdata с #/ipairs);
    -- HandleToUuid → guid строкой.
    local out = {}
    if combatComp == nil then
        return out
    end
    local okP, parts = pcall(function() return combatComp.Participants end)
    if not okP or parts == nil then
        return out
    end
    local okN, n = pcall(function() return #parts end)
    local count = okN and n or 0
    for i = 1, count do
        local okH, guid = pcall(Ext.Entity.HandleToUuid, parts[i])
        if okH and guid ~= nil and guid ~= "" then
            out[#out + 1] = tostring(guid)
        end
    end
    return out
end

local function teamOf(guid, cache, covered)
    -- CombatTeam участника (Guid) с кэшем по закешированным в этом тике сущностям.
    if cache ~= nil and cache[guid] ~= nil then
        return cache[guid]
    end
    local okE, ent = pcall(Ext.Entity.Get, guid)
    if okE and ent ~= nil then
        local tb = turnComponent(ent)
        local tg = fieldOf(tb, "CombatTeam") or fieldOf(tb, "Combat")
        if cache ~= nil then
            cache[guid] = (tg ~= nil and tg ~= "") and tostring(tg) or nil
        end
        if covered ~= nil then
            covered[guid] = true
        end
        return cache ~= nil and cache[guid] or nil
    end
    return nil
end

local function writeStateFile(payload)
    local ok, err = pcall(Ext.IO.SaveFile, STATE_FILE, Ext.Json.Stringify(payload))
    if not ok then
        _P("[BG3Neuro] state: " .. tostring(err))
    end
    return ok
end

local function combatStateComponentOf(combatGuid, acting, diag)
    -- Достать CombatState для combat-сущности.
    -- Прямой путь (v0.7.7 end_turn): TurnBased.CombatTeam — Guid (объект) сущности боя,
    -- Ext.Entity.UuidToHandle(Guid) → EntityHandle. В некоторых боях этот guid не
    -- резолвится (UuidToHandle→nil, Ext.Entity.Get→nil), поэтому основной путь —
    -- сканирование: Ext.Entity.GetAllEntitiesWithComponent("CombatState") и выбор
    -- боя, в Participants которого есть ходящий персонаж.
    local foundComp = nil
    local scan = {}
    if diag ~= nil then
        diag.scans = scan
    end
    local okH, combatHandle = pcall(Ext.Entity.UuidToHandle, combatGuid)
    if diag ~= nil then
        diag.uuid_to_handle_ok = okH
        diag.uuid_to_handle_nil = not okH or combatHandle == nil
    end
    if okH and combatHandle ~= nil then
        local okS, comp = pcall(function() return combatHandle:GetComponent("CombatState") end)
        scan.direct_comp_ok = okS
        scan.direct_comp_nil = okS and comp == nil or not okS
        if okS and comp ~= nil then
            local parts = participantGuids(comp)
            scan.direct_participants = #parts
            if #parts > 0 then
                foundComp = comp
                if diag ~= nil then
                    diag.combat_path = "uuid_to_handle"
                end
            end
        end
    end

    local okAll, handles = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("CombatState") end)
    if diag ~= nil then
        scan.get_all_ok = okAll
    end
    if foundComp == nil and okAll and handles ~= nil then
        local n = #handles
        scan.candidates = n
        for i = 1, n do
            local okS, comp = pcall(function() return handles[i]:GetComponent("CombatState") end)
            local parts = okS and comp ~= nil and participantGuids(comp) or {}
            if diag ~= nil then
                -- uuid боевой сущности может отсутствовать (нет UuidComponent) —
                -- он нужен только для справки, участники берутся из Participants.
                local okU, hGuid = pcall(Ext.Entity.HandleToUuid, handles[i])
                scan["cand_" .. i .. "_uuid"] = okU and tostring(hGuid) or nil
                scan["cand_" .. i .. "_participants"] = #parts
            end
            if okS and comp ~= nil and #parts > 0 then
                if foundComp == nil then
                    foundComp = comp
                    if diag ~= nil then
                        diag.combat_path = "scan"
                        scan["chosen"] = "cand_" .. i
                    end
                end
                local hasActing = false
                for _, pGuid in ipairs(parts) do
                    if pGuid == acting then
                        hasActing = true
                        break
                    end
                end
                if hasActing then
                    foundComp = comp
                    if diag ~= nil then
                        diag.combat_path = "scan_has_acting"
                        scan["chosen"] = "cand_" .. i
                    end
                    break
                end
            end
        end
    end
    return foundComp
end

function captureCombatState(event, force)
    -- Полный combat-state: глобальная функция, чтобы её мог вызвать уже
    -- зарегистрированный listener TurnStarted (резолвится в runtime).
    local diag = { stage = "start", acting = "" }
    local state = {
        version = STATE_VERSION,
        mode = "combat",
        generated_at = nowIso(),
        trigger = event or "manual",
        turn_actor = "",
        turn_initiative_index = 0,
        turn_initiative_total = 0,
        allies = {},
        enemies = {},
        available_actions = {},
        events = {},
    }
    local acting = resolveActingCharacter("")
    local actingClean = actingCleanOf(acting)
    diag.acting = acting or ""
    diag.stage = "acting"
    if Ext == nil or Ext.Entity == nil or acting == nil or acting == "" then
        if force then writeStateFile(state) end
        return state, diag
    end
    diag.stage = "entity"
    local okE, actingEnt = pcall(Ext.Entity.Get, acting)
    if not okE or actingEnt == nil then
        if force then writeStateFile(state) end
        return state, diag
    end
    diag.stage = "turnbased"
    local actingTb = turnComponent(actingEnt)
    local combatGuid = fieldOf(actingTb, "CombatTeam") or fieldOf(actingTb, "Combat")
    diag.combat_guid = combatGuid ~= nil and tostring(combatGuid) or nil
    local combatGuidStr = combatGuid ~= nil and tostring(combatGuid) or ""
    if lastCombatGuid ~= nil and lastCombatGuid ~= combatGuidStr then
        -- смена боя: алиасы и их guid-маппинг сброс, чтобы не копились суффиксы
        combatAliases = {}
        ENTITY_BY_ALIAS = {}
    end
    lastCombatGuid = combatGuidStr
    if combatGuid == nil or combatGuid == "" then
        if force then writeStateFile(state) end
        return state, diag
    end
    -- CombatState живёт на combat-сущности. CombatTeam — Guid (userdata); для
    -- Ext.Entity.Get нужно строковое представление.
    local combatComp = combatStateComponentOf(combatGuid, actingClean, diag)
    if combatComp == nil then
        if force then writeStateFile(state) end
        return state, diag
    end
    diag.stage = "participants"
    local parts = participantGuids(combatComp)
    diag.participants = #parts
    if #parts == 0 then
        if force then writeStateFile(state) end
        return state, diag
    end
    diag.stage = "team"

    -- party from DB_Avatars + controlled (reserved user id)
    local avatars = partyAvatars()
    local controlled = {}
    for _, cc in ipairs(currentCharacters()) do
        local p = pureGuid(cc.character)
        if p ~= nil and p ~= "" then
            controlled[p] = true
        end
    end

    -- команда партии: CombatTeam первого партийца-участника, fallback — команда ходящего
    local teamCache = {}
    local alliesTeam = nil
    for _, g in ipairs(parts) do
        if avatars[g] or controlled[g] then
            alliesTeam = teamOf(g, teamCache)
            if alliesTeam ~= nil then
                break
            end
        end
    end
    if alliesTeam == nil then
        alliesTeam = teamOf(actingClean, teamCache)
    end
    if diag ~= nil then
        diag.acting_clean = actingClean
        diag.party_avatars = nil
        local nA = 0
        for _ in pairs(avatars) do
            nA = nA + 1
        end
        diag.party_avatars = nA
        local teams = {}
        for _, g in ipairs(parts) do
            local t = teamOf(g, teamCache)
            local k = t ~= nil and t or "nil"
            teams[k] = (teams[k] or 0) + 1
        end
        diag.teams = teams
        diag.allies_team = alliesTeam or nil
    end

    -- партия по серверному Character-компоненту (InParty/IsPlayer/PartyFollower)
    local partyFlag = {}
    local pfDiag = { in_party = 0, is_player = 0, party_follower = 0, total_party = 0 }
    for _, g in ipairs(parts) do
        local pf = characterPartyFlags(g)
        if pf ~= nil then
            if pf.in_party then pfDiag.in_party = pfDiag.in_party + 1 end
            if pf.is_player then pfDiag.is_player = pfDiag.is_player + 1 end
            if pf.party_follower then pfDiag.party_follower = pfDiag.party_follower + 1 end
            if pf.in_party or pf.is_player or pf.party_follower then
                partyFlag[g] = true
                pfDiag.total_party = pfDiag.total_party + 1
            end
        end
    end
    if diag ~= nil then
        diag.party_flags = pfDiag
        local rawPf = characterPartyFlags(actingClean)
        diag.party_flags_raw = rawPf ~= nil and rawPf.raw or { note = "no char component" }
    end

    state.turn_initiative_total = #parts
    local actingPosX, actingPosY, actingPosZ = positionOf(acting)
    local taken = {}
    for _, g in ipairs(parts) do
        local existing = combatAliases[g]
        if existing then
            taken[existing] = true
        end
    end

    for i, g in ipairs(parts) do
        local isControlled = controlled[g] or false
        local team = teamOf(g, teamCache)
        local isAlly = isControlled or avatars[g] or partyFlag[g] or (team ~= nil and team == alliesTeam)
        local alias = registerAlias(g, isControlled or avatars[g] or partyFlag[g], taken)
        local ent
        local okG, e = pcall(Ext.Entity.Get, g)
        ent = okG and e or nil
        local hp, maxHp = healthOf(ent)
        local tb = turnComponent(ent)
        local canAct = fieldOf(tb, "CanActInCombat")
        local px, py, pz = positionOf(g)
        local dist = nil
        if px ~= nil and actingPosX ~= nil then
            dist = round1(distance3(actingPosX, actingPosY, actingPosZ, px, py, pz))
        end
        local combatant = {
            alias = alias,
            name = displayName(g),
            hp = hp or 0,
            max_hp = maxHp or 0,
            distance = dist or 0,
            position_x = round1(px or 0),
            position_y = round1(py or 0),
        }
        if isAlly then
            local fx = {}
            if g == actingClean then
                fx[#fx + 1] = "ходит сейчас"
            end
            fx[#fx + 1] = canAct and "может действовать" or "не может действовать"
            combatant.effects = table.concat(fx, ", ")
        else
            if hp ~= nil and hp <= 0 then
                combatant.status = "повержен"
            elseif canAct == false then
                combatant.status = "не может действовать"
            end
        end
        if isAlly then
            state.allies[#state.allies + 1] = combatant
        else
            state.enemies[#state.enemies + 1] = combatant
        end
        if g == actingClean then
            state.turn_actor = alias
            state.turn_initiative_index = i
        end
    end

    state.available_actions[#state.available_actions + 1] = "end_turn"
    if #state.enemies > 0 then
        local enemyAliases = {}
        for _, e in ipairs(state.enemies) do
            enemyAliases[#enemyAliases + 1] = e.alias
        end
        state.available_actions[#state.available_actions + 1] =
            "attack_entity: [" .. table.concat(enemyAliases, ", ") .. "]"
    end
    local allAliases = {}
    for _, c in ipairs(state.allies) do
        allAliases[#allAliases + 1] = c.alias
    end
    for _, e in ipairs(state.enemies) do
        allAliases[#allAliases + 1] = e.alias
    end
    if #allAliases > 0 then
        state.available_actions[#state.available_actions + 1] =
            "move_to_target: [" .. table.concat(allAliases, ", ") .. "]"
    end

    writeStateFile(state)
    diag.stage = "done"
    return state, diag
end

-- ============================================================
-- Long actions: intermediate running:true + final by game event
-- ============================================================

Ext.Osiris.RegisterListener("CharacterMoveToCancelled", 2, "after", function(character, moveID)
    -- ack: С„РёРЅР°Р» cancel СѓР¶Рµ РїРёС€РµС‚ cancelActiveMove (interruption path)
end)

function cancelActiveMove(reason, detail)
    if activeMove == nil then
        return
    end
    local pending = activeMove
    activeMove = nil
    -- РРЅС‚РµСЂСЂСѓРїС‚: РґРІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ РЅРѕРІС‹Рј РґРµР№СЃС‚РІРёРµРј/РІРЅРµС€РЅРµР№ РїСЂРёС‡РёРЅРѕР№ в†’ С„РёРЅР°Р» cancel
    writeResult(pending.id, true, false, nil, reason .. (detail and (": " .. tostring(detail)) or ""))
end

-- ============================================================
-- РЎРѕРІРјРµСЃС‚РЅС‹Р№ РїР°Р№РїР»Р°Р№РЅ РєР°СЃС‚Р°/Р°С‚Р°РєРё (В§6.4): ServerCastRequest.
-- Р”Р»СЏ РёРіСЂРѕРєРѕРІ CastOptions {"FromClient", ...} в†’ СЂРµСЃСѓСЂСЃС‹/РєСѓР»РґР°СѓРЅС‹
-- СЃС‡РёС‚Р°РµС‚ СЃР°РјР° РёРіСЂР°. Fallback вЂ” Osi.UseSpell(AtPosition).
-- ============================================================

local pendingCasts = {} -- { id = action.id, spell = name, caster = uuid }

local function enqueueCastRequest(actorUuid, spellName, targetUuid, posX, posY, posZ, spellType)
    if Ext == nil or Ext.System == nil or Ext.System.ServerCastRequest == nil then
        return nil, "ServerCastRequest РЅРµРґРѕСЃС‚СѓРїРµРЅ РЅР° СЌС‚РѕР№ СЃР±РѕСЂРєРµ BG3SE"
    end

    local casterEntity = Ext.Entity.Get(actorUuid)
    if casterEntity == nil then
        return nil, "РќРµ СѓРґР°Р»РѕСЃСЊ РїРѕР»СѓС‡РёС‚СЊ СЃСѓС‰РЅРѕСЃС‚СЊ РєР°СЃС‚РµСЂР°"
    end

    local targets = {}
    if targetUuid and targetUuid ~= "" then
        local targetEntity = Ext.Entity.Get(targetUuid)
        if targetEntity == nil then
            return nil, "РќРµ СѓРґР°Р»РѕСЃСЊ РїРѕР»СѓС‡РёС‚СЊ СЃСѓС‰РЅРѕСЃС‚СЊ С†РµР»Рё"
        end
        targets[#targets + 1] = { Target = targetEntity, TargetingType = spellType }
    elseif posX then
        targets[#targets + 1] = {
            Position = { posX, posY, posZ },
            TargetingType = spellType,
        }
    end

    local request = {
        CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" },
        Caster = casterEntity,
        RequestGuid = math.random(1, 2147483647),
        Spell = {
            OriginatorPrototype = spellName,
            Prototype = spellName,
            SourceType = "Osiris",
        },
        Targets = targets,
        field_A8 = 1,
    }
    local queue = Ext.System.ServerCastRequest.OsirisCastRequests
    queue[#queue + 1] = request
    return true, nil
end

-- Р¤РёРЅР°Р» РєР°СЃС‚Р° РїРѕ РёРіСЂРѕРІС‹Рј СЃРѕР±С‹С‚РёСЏРј (РґРѕР»РіРёРµ/РєР°РЅР°Р»СЊРЅС‹Рµ Р·Р°РєР»РёРЅР°РЅРёСЏ): running:false.
-- Р•СЃР»Рё СЃРѕР±С‹С‚РёРµ РЅРµ РїСЂРёС€Р»Рѕ вЂ” РїСЂР°РІРґР° РІСЃС‘ СЂР°РІРЅРѕ СѓС…РѕРґРёС‚ С‡РµСЂРµР· СЃР»РµРґСѓСЋС‰РёР№ state (РљР°РЅР°Р» B).
local function finalizeCast(caster, spellName, cancelled)
    for i = 1, #pendingCasts do
        local pc = pendingCasts[i]
        if pc.caster == caster and pc.spell == spellName then
            table.remove(pendingCasts, i)
            writeResult(pc.id, true, false, cancelled and "cast_failed" or nil,
                cancelled and "РљР°СЃС‚ РїСЂРµСЂРІР°РЅ/РїСЂРѕРІР°Р»РµРЅ" or nil)
            return
        end
    end
end

Ext.Osiris.RegisterListener("CastSpell", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
end)

Ext.Osiris.RegisterListener("CastedSpell", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
    finalizeCast(caster, spell, false)
end)

Ext.Osiris.RegisterListener("CastSpellFailed", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
    finalizeCast(caster, spell, true)
end)

local function executeCast(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local spellName = data.spell_name
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ РєР°СЃС‚Р°"
    end
    if spellName == nil or spellName == "" then
        return false, nil, "action_failed", "spell_name РѕР±СЏР·Р°С‚РµР»РµРЅ"
    end

    -- РџСЂРµСЂС‹РІР°РµРј Р°РєС‚РёРІРЅРѕРµ РґРІРёР¶РµРЅРёРµ (РєР°СЃС‚ Рё РґРІРёР¶РµРЅРёРµ РЅРµ РїРµСЂРµСЃРµРєР°СЋС‚СЃСЏ)
    cancelActiveMove("Р”РІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ РєР°СЃС‚РѕРј", action.id)

    local stats = Ext.Stats.Get(spellName) -- prototype-РёРјСЏ (X5-РЅРѕСЂРјР°Р»РёР·Р°С†РёСЏ РІ StateExtractor)
    local spellType = stats and stats.SpellType or "Object"
    local target = resolveEntity(data.target_id or "")
    local pos = data.position

    local ok, err = enqueueCastRequest(actor, spellName, target, pos and pos.x, pos and pos.y, pos and pos.z, spellType)
    if not ok then
        -- Fallback: РєРѕРїСЊС‘ РїРѕРґР°Р»СЊС€Рµ РѕС‚ pipeline, С‡РµСЃС‚РЅС‹С… AP РЅРµ РіР°СЂР°РЅС‚РёСЂСѓРµС‚
        if pos then
            ok, err = pcall(Osi.UseSpellAtPosition, actor, spellName, pos.x, pos.y, pos.z, nil)
        elseif target then
            ok, err = pcall(Osi.UseSpell, actor, spellName, target, nil, nil)
        end
    end

    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    pendingCasts[#pendingCasts + 1] = { id = action.id, spell = spellName, caster = actor }
    return true, true, nil, nil -- success, running (С„РёРЅР°Р» вЂ” СЃРѕР±С‹С‚РёРµ CastedSpell/CastSpellFailed)
end

-- ============================================================
-- Р”РёР°Р»РѕРі (С‚РёРєРµС‚ 07): select_dialogue_option С‡РµСЂРµР· client-РєР»РёРє.
-- Server РЅРµ СѓРјРµРµС‚ РїСѓР±Р»РёС‡РЅРѕ РІС‹Р±РёСЂР°С‚СЊ РІР°СЂРёР°РЅС‚ (research В§7.2, РЅРµС‚ PickDialogNode);
-- Р·РЅР°С‡РёС‚ РёСЃРїРѕР»РЅРёС‚РµР»СЊ Р¶РёРІС‘С‚ РІ client-РєРѕРЅС‚РµРєСЃС‚Рµ (Ext.UI). Р•СЃР»Рё РєР»РёРµРЅС‚СЃРєРёР№
-- РєРѕРЅС‚РµРєСЃС‚ РЅРµРґРѕСЃС‚СѓРїРµРЅ вЂ” РѕС‚РєР°С‚ not_supported (РќР• СѓРІРѕРґРёС‚СЊ Neuro РІ С†РёРєР» Р±РµР· РєР°РЅР°Р»Р°).
-- Р’Р°СЂРёР°РЅС‚С‹ РІ state РґР°С‘С‚ С‚РѕС‚ Р¶Рµ client-РёСЃС‚РѕС‡РЅРёРє, С‡С‚Рѕ Рё СЂРµРЅРґРµСЂ UI (option_index == UI order).
-- ============================================================

local pendingDialogue = {} -- { id = action.id, dialog = guid }

local function finalizeDialogueOption(dialog)
    for i = 1, #pendingDialogue do
        local pd = pendingDialogue[i]
        if pd.dialog == dialog then
            table.remove(pendingDialogue, i)
            writeResult(pd.id, true, false, nil, nil)
            return
        end
    end
end

Ext.Osiris.RegisterListener("DialogStarted", 2, "after", function(dialog, instanceID)
end)

Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(dialog, instanceID)
    finalizeDialogueOption(dialog)
end)

local function executeDialogueOption(action)
    local data = action.data
    local index = data.option_index
    if index == nil then
        return false, nil, "not_supported", "option_index РѕР±СЏР·Р°С‚РµР»РµРЅ"
    end

    -- РљРЅРѕРїРєР° РґРёР°Р»РѕРіР° РЅР°С…РѕРґРёС‚СЃСЏ РІ РєР»РёРµРЅС‚СЃРєРѕРј UI (Noesis); РєР»РёРє вЂ” С‚РѕР»СЊРєРѕ РёР· client-РєРѕРЅС‚РµРєСЃС‚Р°.
    if Ext == nil or Ext.UI == nil then
        return false, nil, "not_supported",
            "ClientAutoselectExecutor РЅРµРґРѕСЃС‚СѓРїРµРЅ: РЅРµС‚ client-РєРѕРЅС‚РµРєСЃС‚Р° РґР»СЏ РїРѕРґСЃРІРµС‚РєРё Рё РєР»РёРєР° РІР°СЂРёР°РЅС‚Р°"
    end

    -- Р”РѕР»РіРёР№ С…РѕРґ: РєР»РёРє РїСЂРѕРёСЃС…РѕРґРёС‚ РІ UI, РёС‚РѕРі вЂ” СЃРѕР±С‹С‚РёРµ DialogEnded/DialogClosed.
    pendingDialogue[#pendingDialogue + 1] = { id = action.id, dialog = "(unknown)" }
    -- TODO(client): Ext.UI.NeedMouse / СЌРјСѓР»СЏС†РёСЏ РєР»РёРєР° РїРѕ UI-СЌР»РµРјРµРЅС‚Сѓ option_index, РїРѕРґСЃРІРµС‚РєР° РїРµСЂРµРґ РєР»РёРєРѕРј;
    -- СЃСЋРґР° вЂ” СЂРµР°Р»СЊРЅС‹Р№ РґРёР°Р»РѕРіРѕРІС‹Р№ РґРµСЃРєСЂРёРїС‚РѕСЂ РґР»СЏ РјР°С‚С‡РёРЅРіР° DialogEnded.
    return true, true, nil, nil -- success, running (С„РёРЅР°Р» вЂ” DialogEnded)
end

local function executeMoveToTarget(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ РґРІРёР¶РµРЅРёСЏ"
    end
    if target == nil and not data.position then
        return false, nil, "action_failed", "Р¦РµР»СЊ РґРІРёР¶РµРЅРёСЏ РЅРµ РЅР°Р№РґРµРЅР°"
    end

    -- РџСЂРµСЂС‹РІР°РµРј РїСЂРµРґС‹РґСѓС‰РµРµ РґРІРёР¶РµРЅРёРµ (interruption path, СЃРѕР±С‹С‚РёРµ cancel)
    cancelActiveMove("Р”РІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ РЅРѕРІС‹Рј РґРµР№СЃС‚РІРёРµРј", action.id)

    local moveEvent = "BG3NeuroMove_" .. action.id
    local moveId = math.random(1, 2147483647)
    local ok, err
    if data.position then
        ok, err = pcall(Osi.CharacterMoveToPosition, actor, data.position.x, data.position.y, data.position.z, "Run", moveEvent, moveId)
    elseif target then
        -- РїРµСЂРµРјРµСЃС‚РёС‚СЊСЃСЏ Рє СЃСѓС‰РЅРѕСЃС‚Рё: РєРѕРѕСЂРґРёРЅР°С‚Р° С†РµР»Рё С‡РµСЂРµР· Osi.GetPosition
        ok, err = pcall(Osi.CharacterMoveTo, actor, target, "Run", moveEvent, moveId)
    end

    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    activeMove = { id = action.id, event = moveEvent, moveId = moveId }
    return true, true, nil, nil -- success, running
end

local function executeAttack(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ Р°С‚Р°РєРё"
    end
    if target == nil then
        return false, nil, "action_failed", "Р¦РµР»СЊ Р°С‚Р°РєРё РЅРµ РЅР°Р№РґРµРЅР°"
    end

    -- РџСЂРµСЂС‹РІР°РµРј Р°РєС‚РёРІРЅРѕРµ РґРІРёР¶РµРЅРёРµ (РґРІРёР¶РµРЅРёРµ Рё Р°С‚Р°РєР° РЅРµ РїРµСЂРµСЃРµРєР°СЋС‚СЃСЏ)
    cancelActiveMove("Р”РІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ Р°С‚Р°РєРѕР№", action.id)

    -- В§6.4: party-Р°С‚Р°РєРё С‡РµСЂРµР· ServerCastRequest СЃ РѕСЂСѓР¶РµР№РЅС‹Рј Р·Р°РєР»РёРЅР°РЅРёРµРј СѓСЂРѕРІРЅСЏ
    -- Target_WeaponRange РІРЅРµРґСЂСЏРµС‚СЃСЏ РІРјРµСЃС‚Рµ СЃ РєР°СЃС‚-РјР°С€РёРЅРµСЂРёРµР№ (СЃР»РµРґСѓСЋС‰РёР№ С‚Р°РєС‚);
    -- Р·РґРµСЃСЊ вЂ” РґРѕРєСѓРјРµРЅС‚РёСЂРѕРІР°РЅРЅС‹Р№ fallback Osi.Attack (one-shot). alwaysHit=0 в†’ Р±СЂРѕСЃРѕРє.
    local ok, err = pcall(Osi.Attack, actor, target, 0)
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    return true, true, nil, nil -- success, running (С„РёРЅР°Р» вЂ” СЃРѕР±С‹С‚РёРµ Р°С‚Р°РєРё/СЃР»РµРґСѓСЋС‰РёР№ state)
end

-- ============================================================
-- Exploration (С‚РёРєРµС‚ 08): interact / loot / rest / travel / screen / mode.
-- Р”РѕР»РіРёРµ Р¶РµСЃС‚С‹ вЂ” running:true, С„РёРЅР°Р» С‡РµСЂРµР· СЃР»РµРґСѓСЋС‰РёР№ state (РљР°РЅР°Р» B) РёР»Рё
-- РёРіСЂРѕРІС‹Рµ СЃРѕР±С‹С‚РёСЏ (Rest). РўРѕС‡РЅС‹Р№ BG3-СЌС„С„РµРєС‚ РїСЂРёС…РѕРґРёС‚ РѕС‚РґРµР»СЊРЅС‹Рј state РѕС‚ РјРѕРґР°.
-- ============================================================

local activeRest = nil -- { id = ... }

local function finalizeRest(success, detail)
    if activeRest == nil then
        return
    end
    local pending = activeRest
    activeRest = nil
    writeResult(pending.id, success, false, success and nil or "action_failed", success and nil or detail)
end

Ext.Osiris.RegisterListener("LongRestFinished", 0, "after", function()
    finalizeRest(true, nil)
end)

Ext.Osiris.RegisterListener("LongRestCancelled", 0, "after", function()
    finalizeRest(false, "РћС‚РґС‹С… РїСЂРµСЂРІР°РЅ/РѕС‚РјРµРЅС‘РЅ")
end)

Ext.Osiris.RegisterListener("LongRestStartFailed", 0, "after", function()
    finalizeRest(false, "РћС‚РґС‹С… РЅРµ РЅР°С‡Р°Р»СЃСЏ (РЅРµС‚ Р»Р°РіРµСЂСЏ/РїСЂРёРїР°СЃРѕРІ)")
end)

local function executeInteract(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ РІР·Р°РёРјРѕРґРµР№СЃС‚РІРёСЏ"
    end
    if target == nil then
        return false, nil, "action_failed", "Р¦РµР»СЊ РІР·Р°РёРјРѕРґРµР№СЃС‚РІРёСЏ РЅРµ РЅР°Р№РґРµРЅР°"
    end

    -- РњРёСЂРЅРѕРµ РІР·Р°РёРјРѕРґРµР№СЃС‚РІРёРµ СЃ РѕР±СЉРµРєС‚РѕРј (В§8 research): useItem=0, isInteraction=1.
    cancelActiveMove("Р”РІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ РІР·Р°РёРјРѕРґРµР№СЃС‚РІРёРµРј", action.id)
    local ok, err = pcall(Osi.Use, actor, target, 0, 1, "")
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    return true, true, nil, nil -- success, running (РёСЃС…РѕРґ вЂ” СЃР»РµРґСѓСЋС‰РёР№ state)
end

local function executeLoot(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ Р»СѓС‚Р°"
    end
    if target == nil then
        return false, nil, "action_failed", "Р¦РµР»СЊ Р»СѓС‚Р° РЅРµ РЅР°Р№РґРµРЅР°"
    end

    -- РЎРµСЂРІРµСЂРЅС‹Р№ Р°РІС‚РѕРїРѕРґР±РѕСЂ: MoveAllLootableItemsTo(from, to, equipArmor=0, equipWeapons=0,
    -- clrOwner=1, vanityClothing=0). UI-РІР°СЂРёР°РЅС‚ (OpenCharacterLootUI) вЂ” client-С‡Р°СЃС‚СЊ.
    cancelActiveMove("Р”РІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ СЃР±РѕСЂРѕРј РґРѕР±С‹С‡Рё", action.id)
    local ok, err = pcall(Osi.MoveAllLootableItemsTo, target, actor, 0, 0, 1, 0)
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    return true, true, nil, nil -- success, running (СЃРѕСЃС‚Р°РІ РґРѕР±С‹С‡Рё вЂ” СЃР»РµРґСѓСЋС‰РёР№ state)
end

local function executeRest(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ РѕС‚РґС‹С…Р°"
    end

    -- РџРѕР»РЅС‹Р№ РѕС‚РґС‹С… вЂ” Osi.RequestLongRest (research В§9) + РіРµР№С‚ CanAllPartiesLongRest (C#-РІР°Р»РёРґР°С‚РѕСЂ).
    -- Р§Р°СЃС‚РёС‡РЅС‹Р№ (Р»С‘РіРєРёР№) РѕС‚РґС‹С… РїСѓР±Р»РёС‡РЅРѕР№ Osiris-С„СѓРЅРєС†РёРё РЅРµ РёРјРµРµС‚ (story-side).
    if data.rest_type ~= "full" then
        -- TODO(client): Р»С‘РіРєРёР№ РѕС‚РґС‹С… вЂ” UI-РєРЅРѕРїРєР° Take Short Rest; СЃС‚СЂСѓРєС‚СѓСЂРЅС‹Р№ ack, С„РёРЅР°Р» вЂ” state.
        return true, true, nil, nil
    end

    local ok, err = pcall(Osi.RequestLongRest, actor, 0)
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    activeRest = { id = action.id }
    return true, true, nil, nil -- success, running (С„РёРЅР°Р» вЂ” LongRestFinished/Cancelled/Failed)
end

local function executeTravel(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    if actor == nil then
        return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РёСЃРїРѕР»РЅРёС‚РµР»СЏ РїСѓС‚РµС€РµСЃС‚РІРёСЏ"
    end

    -- РџСѓР±Р»РёС‡РЅРѕРіРѕ fast-travel Osiris-РІС‹Р·РѕРІР° РІ research РЅРµС‚ (В§0/В§15): СЃС‚СЂСѓРєС‚СѓСЂРЅС‹Р№ ack.
    -- TODO(game): РєР°РЅРґРёРґР°С‚ вЂ” С‚РµР»РµРїРѕСЂС‚ Рє waypoint-РјР°СЂРєРµСЂСѓ СЂРµРіРёРѕРЅР° (Osi.TeleportTo/Position);
    -- С„Р°РєС‚РёС‡РµСЃРєРёР№ РїРµСЂРµРµР·Рґ РѕР±Р»Р°СЃС‚Рё РїСЂРёРґС‘С‚ РѕС‚РґРµР»СЊРЅС‹Рј state РѕС‚ mod-РіРµРЅРµСЂР°С‚РѕСЂР° (РљР°РЅР°Р» B).
    return true, true, nil, nil -- success, running (РїРµСЂРµРЅРѕСЃ СЂРµРіРёРѕРЅР° вЂ” СЃР»РµРґСѓСЋС‰РёР№ state)
end

local function executeOpenScreen(action)
    -- open_map / open_inventory вЂ” С‚РѕР»СЊРєРѕ РїСЂРѕСЃРјРѕС‚СЂ (UI), РґРІРёР¶РѕРє СЃР°Рј РѕС‚РєСЂРѕРµС‚ СЌРєСЂР°РЅ.
    -- TODO(client): РѕС‚РєСЂС‹С‚РёРµ СЌРєСЂР°РЅР° С‡РµСЂРµР· РєР»РёРµРЅС‚СЃРєРёР№ РІРІРѕРґ; state СЌРєСЂР°РЅР° РґР°С‘С‚ mod-РіРµРЅРµСЂР°С‚РѕСЂ.
    cancelActiveMove("Р”РІРёР¶РµРЅРёРµ РїСЂРµСЂРІР°РЅРѕ РѕС‚РєСЂС‹С‚РёРµРј СЌРєСЂР°РЅР°", action.id)
    return true, true, nil, nil -- success, running (СЌРєСЂР°РЅ вЂ” СЃР»РµРґСѓСЋС‰РёР№ state)
end

local function executeToggleMode(action)
    -- toggle_mode: v1 РїСЂРёРЅРёРјР°РµС‚ С‚РѕР»СЊРєРѕ "normal" (X3, stealth СѓР±СЂР°РЅ) вЂ” C# СѓР¶Рµ РѕС‚СЃРµРє РёРЅРѕРµ.
    -- Р РµР¶РёРј normal вЂ” РїРѕРґС‚РІРµСЂР¶РґРµРЅРёРµ Р±РµР· РёРіСЂРѕРІРѕРіРѕ РІС‹Р·РѕРІР°, РјРіРЅРѕРІРµРЅРЅС‹Р№ С„РёРЅР°Р».
    return true, nil, nil, nil
end

local function executeAction(action)
    local name = action.name
    local data = action.data
    if type(data) == "string" then
        local ok, parsed = pcall(Ext.Json.Parse, data)
        data = ok and parsed or {}
    end
    if data == nil then
        data = {}
    end

    if name == "end_turn" then
        -- v0.7.3: РґРІСѓС…С„Р°Р·РЅС‹Р№ end_turn СЃ СЃР°РјРѕРїСЂРѕРІРµСЂРєРѕР№ СЂРµР°Р»СЊРЅРѕРіРѕ СЌС„С„РµРєС‚Р°.
        -- РҐРѕРґ вЂ” РґРІРёР¶РєРѕРІС‹Р№ (story Р»РёС€СЊ РЅР°Р±Р»СЋРґР°РµС‚ TurnStarted/TurnEnded), РїРѕСЌС‚РѕРјСѓ
        -- success Р·РґРµСЃСЊ РќР• Р·РЅР°С‡РёС‚ "С…РѕРґ СЃРјРµРЅРёР»СЃСЏ": С„РёРЅР°Р» С‡РµСЂРµР· ~1.2СЃ СЃРѕРѕР±С‰Р°РµС‚
        -- ended:true/false РїРѕ С„Р°РєС‚Сѓ РЅР°СЃС‚СѓРїР»РµРЅРёСЏ TurnEnded(actor) РёР»Рё TurnStarted
        -- РґСЂСѓРіРѕРіРѕ РїРµСЂСЃРѕРЅР°Р¶Р°. Р•СЃР»Рё C# РЅРµ Р·РЅР°РµС‚ Р°РєС‚СѓР°Р»СЊРЅС‹Р№ GUID вЂ” story-Р»Р°С‚С‡.
        local acting = resolveActingCharacter(data.actor or "")
        _P("[BG3Neuro] end_turn: explicit=" .. tostring(data.actor or "")
            .. " resolved=" .. tostring(acting)
            .. " latch=" .. tostring(actingChar)
            .. " mode=" .. tostring(data.mode or "end"))
        if acting == nil or acting == "" then
            return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РґРµР№СЃС‚РІСѓСЋС‰РµРіРѕ РїРµСЂСЃРѕРЅР°Р¶Р°"
        end

        local marker = #turnLog
        local actingBefore = actingChar
        local ok, err = pcall(Osi.EndTurn, acting)
        if not ok then
            return false, nil, "action_failed", tostring(err)
        end

        -- Р¤РёРЅР°Р»: СЃР°РјРѕРїСЂРѕРІРµСЂРєР° РїРѕ story-Р»РµРЅС‚Рµ (TurnEnded/TurnStarted).
        local function verifyEndTurn()
            local ended = false
            for i = marker + 1, #turnLog do
                if turnLog[i].t == "E" and turnLog[i].g == acting then
                    ended = true
                end
                if turnLog[i].t == "S" and turnLog[i].g ~= acting then
                    ended = true
                end
            end
            writeResult(action.id, true, false, nil, nil, {
                ended = ended,
                acting_before = tostring(actingBefore),
                acting_after = tostring(actingChar),
                turn_delta = turnLogSlice(marker, 8),
            })
            _P("[BG3Neuro] end_turn verify: ended=" .. tostring(ended))
        end
        Ext.Timer.WaitForRealtime(1200, verifyEndTurn)

        return true, true, nil, nil -- success, running (С„РёРЅР°Р» вЂ” verifyEndTurn)
    end

    if name == "end_turn_ecs" then
        -- v0.7.5: РґРІРёР¶РєРѕРІРѕР№ РєР°РЅР°Р» РєРѕРЅС†Р° С…РѕРґР°.
        --  mode "probe"  вЂ” С‚РѕР»СЊРєРѕ С‡С‚РµРЅРёРµ;
        --  mode "ecs"    вЂ” С„Р»Р°Рі RequestedEndTurn (v0.7.4, РґРѕРєР°Р·Р°РЅ no-op);
        --  mode "system" (РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ) вЂ” РїСѓС€ combat-СЃСѓС‰РЅРѕСЃС‚Рё РІ РѕС‡РµСЂРµРґСЊ
        --    Ext.System.ServerTurnOrder.EndTurn (esv::TurnOrderSystem::EndTurn,
        --    Array<EntityHandle>) вЂ” С‚РѕС‚ Р¶Рµ РєР°РЅР°Р», С‡С‚Рѕ Рё РєР»РёРµРЅС‚СЃРєРѕРµ
        --    NETMSG_TURNBASED_ENDTURN_REQUEST; РѕР±СЂР°Р±Р°С‚С‹РІР°РµС‚СЃСЏ СЃРёСЃС‚РµРјРѕР№ РґРІРёР¶РєР°
        --    РєР°Р¶РґС‹Р№ РєР°РґСЂ. Р¤Р»Р°Рі С‚РѕР¶Рµ СЃС‚Р°РІРёРј (РІРµСЃСЊ СЃС‚РµРє РєР»РёРµРЅС‚Р°).
        local acting = resolveActingCharacter(data.actor or "")
        local mode = data.mode or "system"
        local onlyProbe = mode == "probe"
        if acting == nil or acting == "" then
            return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РґРµР№СЃС‚РІСѓСЋС‰РµРіРѕ РїРµСЂСЃРѕРЅР°Р¶Р°"
        end
        local before = entityTurnComponentDump(acting)
        local marker = #turnLog
        local actingBefore = actingChar
        local payload = { actor = acting, mode = mode, before = before }
        if not onlyProbe then
            local stepOk, stepErr = pcall(function()
                local okE, ent = pcall(Ext.Entity.Get, acting)
                if okE and ent ~= nil then
                    local okC, comp = pcall(function() return ent:GetComponent("TurnBased") end)
                    if okC and comp ~= nil then
                        -- С„Р»Р°Рі РєРѕРЅС†Р° С…РѕРґР° Р°РєС‚РёРІРЅРѕРіРѕ РїРµСЂСЃРѕРЅР°Р¶Р°
local okW1, errW1 = pcall(function() comp.RequestedEndTurn = true end)
                        payload.write_requested = okW1 and true or false
                        payload.write_error = okW1 and nil or tostring(errW1)
                        -- combat-сущность из компонента персонажа
                        local combatGuid = nil
                        pcall(function() combatGuid = comp.CombatTeam or comp.Combat end)
                        payload.combat_guid = combatGuid
                        if mode ~= "ecs" and combatGuid ~= nil then
                            -- РєР°РЅР°Р» turn-order system: РѕС‡РµСЂРµРґСЊ EndTurn (combat entity)
                            local okH, combatHandle = pcall(Ext.Entity.UuidToHandle, combatGuid)
                            payload.combat_handle = okH and tostring(combatHandle) or tostring(combatHandle)
                            local sys = Ext.System and Ext.System.ServerTurnOrder
                            if sys ~= nil and sys.EndTurn ~= nil then
                                local n0 = #sys.EndTurn
                                local okP, errP = pcall(function()
                                    sys.EndTurn[n0 + 1] = combatHandle
                                end)
                                payload.queue_push = okP and true or false
                                payload.queue_push_error = okP and nil or tostring(errP)
                                payload.queue_before = n0
                                payload.queue_after = #sys.EndTurn
                            else
                                payload.queue_push = false
                                payload.queue_push_error = "РЅРµС‚ Ext.System.ServerTurnOrder.EndTurn"
                            end
                        end
                    else
                        payload.write_requested = false
                        payload.write_error = "РЅРµС‚ РєРѕРјРїРѕРЅРµРЅС‚Р° TurnBased"
                    end
                else
                    payload.write_error = "РЅРµС‚ СЃСѓС‰РЅРѕСЃС‚Рё"
                end
                -- РґРѕРїРѕР»РЅРёС‚РµР»СЊРЅРѕ РїСЂРѕР±СѓРµРј story-РєР°РЅР°Р» (РІ BG3 РѕРЅ no-op, РЅРѕ РґС‘С€РµРІ)
                pcall(Osi.EndTurn, acting)
            end)
            if not stepOk then
                payload.step_error = tostring(stepErr)
            end
        end
        _P("[BG3Neuro] end_turn_ecs: actor=" .. tostring(acting)
            .. " mode=" .. tostring(mode))
        local function verifyEcsEndTurn()
            local ended = false
            for i = marker + 1, #turnLog do
                if turnLog[i].t == "E" and turnLog[i].g == acting then
                    ended = true
                end
                if turnLog[i].t == "S" and turnLog[i].g ~= acting then
                    ended = true
                end
            end
            payload.after = entityTurnComponentDump(acting)
            payload.ended = ended
            payload.acting_before = tostring(actingBefore)
            payload.acting_after = tostring(actingChar)
            payload.turn_delta = turnLogSlice(marker, 8)
            writeResult(action.id, true, false, nil, nil, { diag = payload })
            _P("[BG3Neuro] end_turn_ecs verify: ended=" .. tostring(ended))
        end
        Ext.Timer.WaitForRealtime(onlyProbe and 100 or 5000, verifyEcsEndTurn)
        return true, true, nil, nil -- С„РёРЅР°Р» вЂ” verifyEcsEndTurn
    end

    if name == "diag_skip" then
        -- Р”РёР°РіРЅРѕСЃС‚РёРєР° РјРµС…Р°РЅРёР·РјР° DB_CharacterSkipTurn (v0.7.3): РґРѕР±Р°РІРёС‚СЊ СЃС‚СЂРѕРєСѓ,
        -- РїРѕСЃРјРѕС‚СЂРµС‚СЊ, РІС‹Р·С‹РІР°РµС‚ Р»Рё story EndTurn РЅР° Р±Р»РёР¶Р°Р№С€РµРј TurnStarted, Рё СЃРЅСЏС‚СЊ
        -- СЃС‚СЂРѕРєСѓ РѕР±СЂР°С‚РЅРѕ (С‡С‚РѕР±С‹ РЅРµ Р»РѕРјР°С‚СЊ Р±СѓРґСѓС‰РёРµ С…РѕРґС‹ РёРіСЂРѕРєР°).
        local acting = resolveActingCharacter(data.actor or "")
        if acting == nil or acting == "" then
            return false, nil, "action_failed", "РќРµ СѓРґР°Р»РѕСЃСЊ РѕРїСЂРµРґРµР»РёС‚СЊ РґРµР№СЃС‚РІСѓСЋС‰РµРіРѕ РїРµСЂСЃРѕРЅР°Р¶Р°"
        end
        local payload = { actor = acting }
        local okAdd, errAdd = pcall(Osi.DB_CharacterSkipTurn, acting)
        payload.row_added = okAdd and true or false
        payload.row_add_error = okAdd and nil or tostring(errAdd)
        payload.rows_after_add = dbRowsRead("CharacterSkipTurn", 1)
        -- СЃРЅСЏС‚СЊ СЃС‚СЂРѕРєСѓ СЃСЂР°Р·Сѓ (РґРёР°РіРЅРѕСЃС‚РёРєР° РЅРµ РґРѕР»Р¶РЅР° РјРµРЅСЏС‚СЊ РіРµР№РјРїР»РµР№)
        local okDel, errDel = pcall(function() return Osi.DB_CharacterSkipTurn:Delete(acting) end)
        payload.row_deleted = okDel and true or false
        payload.row_del_error = okDel and nil or tostring(errDel)
        payload.rows_after_del = dbRowsRead("CharacterSkipTurn", 1)
        _P("[BG3Neuro] diag_skip: " .. Ext.Json.Stringify(payload))
        return true, nil, nil, nil, { diag = payload }
    end

    if name == "probe" then
        -- Р”РёР°РіРЅРѕСЃС‚РёРєР° (РЅРµ РґР»СЏ РїСЂРѕРґР°): РєС‚Рѕ С…РѕРґРёС‚, РєС‚Рѕ РІ Р±РѕСЋ, skip/GEN С„Р»Р°РіРё.
        local p
        local okProbe, errProbe = pcall(probeGameState)
        if okProbe then
            p = errProbe
        else
            p = { probe_error = tostring(errProbe) }
        end
        _P("[BG3Neuro] probe: avatars=" .. #(p.avatars or {})
            .. " current=" .. #p.current_characters
            .. (p.probe_error and (" error=" .. p.probe_error) or ""))
        return true, nil, nil, nil, { debug = p }
    end

    if name == "state_capture" then
        -- StateExtractor (v0.8.11): принудительный combat-state прямо сейчас
        -- (диагностика; полный state уже ушёл в bg3_to_neuro.json).
        local okC, p, diag = pcall(captureCombatState, "state_capture", true)
        if okC then
            _P("[BG3Neuro] state_capture: turn=" .. tostring(p.turn_actor)
                .. " allies=" .. #p.allies .. " enemies=" .. #p.enemies
                .. " stage=" .. tostring(diag and diag.stage or "?"))
            return true, nil, nil, nil, {
                version = p.version,
                trigger = p.trigger,
                turn_actor = p.turn_actor,
                turn_initiative_index = p.turn_initiative_index,
                turn_initiative_total = p.turn_initiative_total,
                allies = #p.allies,
                enemies = #p.enemies,
                diag = diag,
            }
        end
        return false, nil, "action_failed", tostring(p)
    end

    if name == "move_to_target" then
        return executeMoveToTarget(action)
    end

    if name == "attack_entity" then
        return executeAttack(action)
    end

    if name == "cast_spell" then
        return executeCast(action)
    end

    if name == "select_dialogue_option" then
        return executeDialogueOption(action)
    end

    if name == "move_to_entity" then
        -- РџРµСЂРµРјРµС‰РµРЅРёРµ Рє РѕР±СЉРµРєС‚Сѓ/СЃСѓС‰РµСЃС‚РІСѓ РІ РёСЃСЃР»РµРґРѕРІР°РЅРёРё вЂ” С‚РѕС‚ Р¶Рµ РјР°СЃСЃРѕРІС‹Р№ РїСѓС‚СЊ, С‡С‚Рѕ move_to_target
        return executeMoveToTarget(action)
    end

    if name == "interact_with" then
        return executeInteract(action)
    end

    if name == "loot" then
        return executeLoot(action)
    end

    if name == "rest" then
        return executeRest(action)
    end

    if name == "travel_to" then
        return executeTravel(action)
    end

    if name == "open_map" or name == "open_inventory" then
        return executeOpenScreen(action)
    end

    if name == "toggle_mode" then
        return executeToggleMode(action)
    end

    -- РћСЃС‚Р°Р»СЊРЅС‹Рµ РґРµР№СЃС‚РІРёСЏ С‚РёРєРµС‚С‹ 03/04 РЅРµ РёСЃРїРѕР»РЅСЏСЋС‚ (РІР°Р»РёРґР°С†РёСЏ СѓР¶Рµ РїСЂРѕС€Р»Р° РЅР° C#; РёСЃРїРѕР»РЅРµРЅРёРµ вЂ” РїРѕР·Р¶Рµ).
    return false, nil, "not_supported", "Р”РµР№СЃС‚РІРёРµ '" .. name .. "' РЅРµ РїРѕРґРґРµСЂР¶РёРІР°РµС‚СЃСЏ РјРѕРґРѕРј РІ v1"
end

local function clearInFlight()
    -- Р РµСЃС‚Р°СЂС‚ РјРѕРґР°/РёРіСЂС‹ (С‚РёРєРµС‚ 09, R7): РѕР±РЅСѓР»СЏРµРј neuro_to_bg3.json, С‡С‚РѕР±С‹ РЅРµ
    -- РёСЃРїРѕР»РЅРёС‚СЊ РґРµР№СЃС‚РІРёРµ РїРѕРіРёР±С€РµРіРѕ СЃС‚СЌРЅРґР°. SaveFile("") РІРјРµСЃС‚Рѕ СѓРґР°Р»РµРЅРёСЏ вЂ” LoadFile
    -- РІРµСЂРЅС‘С‚ "" Рё readInFlightAction() РѕС‚РєР»РѕРЅРёС‚ РµРіРѕ РєР°Рє РЅРµС‚ РґРµР№СЃС‚РІРёСЏ.
    local ok, err = pcall(Ext.IO.SaveFile, NEURO_TO_BG3_FILE, "")
    if not ok then
        _P("[BG3Neuro] clear in-flight: " .. tostring(err))
    end
end

local function pollActions()
    local action = readInFlightAction()
    if action == nil then
        Ext.Timer.WaitForRealtime(ACTION_POLL_MS, pollActions)
        return
    end

    local execOk, success, running, errorCode, errorDetail, extra = pcall(executeAction, action)
    if not execOk then
        -- РСЃРєР»СЋС‡РµРЅРёРµ Lua РІ РѕР±СЂР°Р±РѕС‚С‡РёРєРµ: СЃРѕС…СЂР°РЅСЏРµРј РќРђРЎРўРћРЇР©Р•Р• СЃРѕРѕР±С‰РµРЅРёРµ РѕС€РёР±РєРё,
        -- Р° РЅРµ tostring(false) (Р±Р°Рі v0.7.4 вЂ” С‚РµСЂСЏР» С‚РµРєСЃС‚ РѕС€РёР±РєРё).
        local errMsg = tostring(success)
        success = false
        running = nil
        errorCode = "action_failed"
        errorDetail = errMsg
        extra = nil
    end
    -- РћС‡РёС‰Р°РµРј in-flight РЎР РђР—РЈ РїРѕСЃР»Рµ С‡С‚РµРЅРёСЏ С‚РµРєСѓС‰РµРіРѕ РґРµР№СЃС‚РІРёСЏ: РѕРґРЅРѕС€Р°РіРѕРІС‹Рµ РґРµР№СЃС‚РІРёСЏ
    -- (success Р±РµР· running) Р±РѕР»СЊС€Рµ РЅРµ РґРѕР»Р¶РЅС‹ РїРµСЂРµРёСЃРїРѕР»РЅСЏС‚СЊСЃСЏ РєР°Р¶РґС‹Рµ 200 РјСЃ, Р° С„РёРЅР°Р»
    -- РґР»РёРЅРЅС‹С… РґРµР№СЃС‚РІРёР№ РїСЂРёС…РѕРґРёС‚ РїРѕ РёРіСЂРѕРІРѕРјСѓ СЃРѕР±С‹С‚РёСЋ, Р° РЅРµ РёР· С„Р°Р№Р»Р° (R7).
    clearInFlight()
    writeResult(action.id, success, running, errorCode, errorDetail, extra)
    Ext.Timer.WaitForRealtime(ACTION_POLL_MS, pollActions)
end

clearInFlight()
writeInitialState()
startHeartbeatLoop()
pollActions()
_P("[BG3Neuro] С„Р°Р№Р»РѕРІС‹Р№ IPC-РјРѕСЃС‚ РїРѕРґРЅСЏС‚: " .. HEARTBEAT_FILE)