-- BG3Neuro v0.8.26 — файловой IPC-мост (тикеты 01 + 03-09)
-- Задача: heartbeat 2s + стартовый state-файл + исполнение действий из action_*.json.
-- Действия: end_turn (03), move_to_target / attack_entity (04), cast_spell (05),
--           select_dialogue_option (07, client-контекст), exploration (08:
--           move_to_entity / interact_with / loot / rest / travel_to /
--           open_map / open_inventory / toggle_mode) — длинные действия
-- с двухфазным running:true (промежуточный ack) и финалом по игровому событию.
-- Dumb-модуль: только состояние и исполнение, без логики решений (решение — в C#).
-- Состояние (v0.8.26): combat (TurnStarted) + exploration (free-roam loop) + dialogue
-- (DialogStarted), все блоки эмитятся в bg3_to_neuro.json (spells/objects/regions/
-- inventory/can_rest/screen); selection/клик диалога остаются client-контекстом (TODO(client)).
-- Директория IPC: <BG3ScriptExtender appdata>/BG3Neuro (Ext.IO пишет относительно Script Extender).

local MOD_NAME = "BG3Neuro"
local MOD_VERSION = "0.8.26"
local IPC_DIR = "BG3Neuro"
local HEARTBEAT_INTERVAL_MS = 2000 -- config.ipc.heartbeat_interval_s * 1000
local ACTION_POLL_MS = 200          -- config.ipc.poll_interval_ms * 2 (реальный polling)
local STATE_FILE = IPC_DIR .. "/bg3_to_neuro.json"
local HEARTBEAT_FILE = IPC_DIR .. "/heartbeat.json"
local NEURO_TO_BG3_FILE = IPC_DIR .. "/neuro_to_bg3.json"
local RESULT_DIR = IPC_DIR

local seq = 0
local activeMove = nil -- { id, event, moveId } — движение в полёте (interruption/cancel)

local function nowIso()
    -- UTC: Ext.Timer.ClockTime() даёт "YYYY-MM-DD HH:MM:SS.fffffff" (UTC);
    -- нормируем в ISO-8601 для сравнения с DateTimeOffset.UtcNow на C#-стороне.
    -- (os недоступен в песочнице SE — os.date использовать нельзя)
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
        message = "Мод инициализирован, состояние загружается",
    }
    local ok, err = pcall(Ext.IO.SaveFile, STATE_FILE, Ext.Json.Stringify(state))
    if not ok then
        _P("[BG3Neuro] initial state: " .. tostring(err))
    end
end

-- ============================================================
-- ActionExecutor (тикеты 03 + 04): reading actions served by C#
-- ============================================================

local function readInFlightAction()
    -- C# пишет единственный current action в neuro_to_bg3.json:
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
    local path = RESULT_DIR .. "/result_" .. (actionId or "unknown") .. ".json"
    local ok, err = pcall(Ext.IO.SaveFile, path, Ext.Json.Stringify(payload))
    if not ok then
        _P("[BG3Neuro] write result " .. actionId .. ": " .. tostring(err))
    end
    return ok
end

-- v0.8.24 (тикет 02): снапшот боевых ресурсов кастера до/после действия.
-- Снимает персональные ресурсы (AP/BA/Reaction/Movement/WeaponActionPoint) и
-- кулдауны. Каждый вызов в pcall — GetActionResourceValuePersonal с
-- невалидным именем возвращает nil; resourceLevel=0 для неслотовых.
local SNAPSHOT_RESOURCES = { "ActionPoint", "BonusActionPoint", "ReactionActionPoint", "Movement", "WeaponActionPoint" }

-- Для JSON: компоненты (SpellBookCooldowns и т.п.) — userdata/cdata, их
-- Ext.Json.Stringify не переваривает. Распаковываем рекурсивно в примитивы
-- (числа/строки/булевы/вложенные таблицы), всё прочее — в tostring. depth
-- ограничивает вложенность против циклов.
local function unwrapField(v, depth)
    local tv = type(v)
    if tv == "number" or tv == "string" or tv == "boolean" or v == nil then
        return v
    end
    if tv ~= "table" then
        local ok, s = pcall(tostring, v)
        return ok and tostring(s) or "<unprintable>"
    end
    if depth == nil then depth = 6 end
    if depth <= 0 then return "<depth>" end
    local isArr = false
    local okLen, len = pcall(function() return #v end)
    if okLen and type(len) == "number" then
        isArr = len > 0
    end
    if isArr then
        local out = {}
        for i = 1, len do
            local o, e = pcall(function() return v[i] end)
            out[i] = o and unwrapField(e, depth - 1) or nil
        end
        return out
    end
    local out = {}
    local okPairs, iter = pcall(function() return pairs(v) end)
    if okPairs and iter then
        for k, val in iter do
            local key = type(k) == "string" and k or tostring(k)
            local o, e = pcall(function() return val end)
            out[key] = o and unwrapField(e, depth - 1) or nil
        end
    end
    return out
end

local function readResourceSnapshot(actor)
    local out = {}
    for _, name in ipairs(SNAPSHOT_RESOURCES) do
        local ok, v = pcall(Osi.GetActionResourceValuePersonal, actor, name, 0)
        out[name] = ((ok and v ~= nil) and v) or nil
    end
    local cdOk, cdVal = pcall(function() return Ext.Entity.Get(actor) end)
    if cdOk and cdVal ~= nil then
        local sbcOk, sbc = pcall(function()
            return cdVal.SpellBookCooldowns
        end)
        if sbcOk and sbc ~= nil then
            out.cooldowns = unwrapField(sbc)
        end
    end
    return out
end

local function writeResourceSnapshot(actionId, actor, phase)
    local payload = {
        action_id = actionId,
        actor = tostring(actor),
        phase = phase,
        timestamp = nowIso(),
    }
    local res = readResourceSnapshot(actor)
    for k, v in pairs(res) do
        payload[k] = v
    end
    local path = RESULT_DIR .. "/resource_snapshot_" .. (actionId or "unknown") .. "_" .. phase .. ".json"
    local jsonOk, json = pcall(Ext.Json.Stringify, payload)
    if not jsonOk then
        _P("[BG3Neuro] resource snapshot stringify " .. (actionId or "unknown") .. "/" .. phase .. ": " .. tostring(json))
        return false
    end
    local ok, err = pcall(Ext.IO.SaveFile, path, json)
    if not ok then
        _P("[BG3Neuro] resource snapshot " .. (actionId or "unknown") .. "/" .. phase .. ": " .. tostring(err))
    end
    return ok
end

-- Маппинг псевдонимов state → GUID, приходит из StateExtractor/регистрации боя.
-- В v0.3 заполняется в момент диспатча из данных действия; для move/attack финальный
-- GUID-путь (боевой реестр сущностей) подключается в тикете state-generator.
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
-- v0.8.25 (тикет 03): конфиг force_legacy + гибридный откат честного пути.
-- BG3SE игнорирует произвольные ключи ScriptExtender/Config.json и не имеет
-- Ext.Mod.GetConfig (в Ext.Mod есть только GetBaseMod/GetLoadOrder/GetMod/
-- GetModManager/IsModLoaded). Поэтому читаем свой Config.json руками из VFS
-- (путь внутри pak: /Mods/<Folder>/ScriptExtender/Config.json) и парсим.
-- Поля:
--   force_legacy: true  — ВСЕ боевые действия (атаки/касты/бонусы) идут по legacy
--                    путям (Osi.UseSpell + ручной AddActionPoints, Osi.Attack).
--   legacy_fail_limit: N (default 3) — после N сбоев ЧЕСТНОГО пути подряд
--                    включается устойчивый legacy-режим до перезапуска (гибрид).
-- Счётчик — в памяти (после рестарта снова честный путь).
-- ============================================================
local forceLegacy = false
local legacyFailLimit = 3
local legacyFailCount = 0
local legacyStable = false

local CONFIG_PATH = "Mods/" .. MOD_NAME .. "/ScriptExtender/Config.json"

local function readModConfig()
    if Ext == nil or Ext.IO == nil or Ext.IO.LoadFile == nil then
        _P("[BG3Neuro] Ext.IO unavailable, config defaults apply")
        return
    end
    -- context "data" => читаем через игровой VFS (в т.ч. файлы внутри pak)
    local okLoad, raw = pcall(Ext.IO.LoadFile, CONFIG_PATH, "data")
    if not okLoad or raw == nil or type(raw) ~= "string" then
        _P("[BG3Neuro] mod config load failed (Config.json not found at " .. CONFIG_PATH .. ")")
        return
    end
    local ok, cfg = pcall(Ext.Json.Parse, raw)
    if not ok or type(cfg) ~= "table" then
        _P("[BG3Neuro] mod config parse failed")
        return
    end
    if cfg.force_legacy == true then
        forceLegacy = true
    end
    if type(cfg.legacy_fail_limit) == "number" and cfg.legacy_fail_limit > 0 then
        legacyFailLimit = cfg.legacy_fail_limit
    end
    _P("[BG3Neuro] config: force_legacy=" .. tostring(forceLegacy)
        .. " legacy_fail_limit=" .. tostring(legacyFailLimit))
end
readModConfig()

-- Гибрид (03): сбой честного пути — инкрементируем счётчик; после N сбоев
-- подряд (legacyFailLimit) — устойчивый legacy до перезапуска.
-- Возвращает true, если на ЭТОТ вызов нужно подхватить legacy (fallback на сбой).
local function pipelineFailed(where)
    if not forceLegacy and not legacyStable then
        legacyFailCount = legacyFailCount + 1
        _P("[BG3Neuro] honest path failed (" .. tostring(where)
            .. "): " .. legacyFailCount .. "/" .. legacyFailLimit)
        if legacyFailCount >= legacyFailLimit then
            legacyStable = true
            _P("[BG3Neuro] stable legacy ON (честный путь отключён до перезапуска)")
        end
    end
    return true
end

-- Сброс счётчика при успешном честном пути (возврат к честному после сбоев).
local function pipelineSucceeded()
    if legacyFailCount > 0 then
        _P("[BG3Neuro] honest path ok, legacyFailCount reset "
            .. legacyFailCount .. " -> 0")
        legacyFailCount = 0
    end
end

-- Стоит ли сейчас использовать legacy-путь (флаг из конфига ИЛИ устойчивый откат).
local function useLegacyNow()
    return forceLegacy or legacyStable
end

-- Story-латч хода (v0.7.3): RegisterListener на TurnStarted/TurnEnded даёт
-- единственную правду "кто сейчас ходит" — движковый ход двигается сам, а story
-- лишь наблюдает (Osiris-лог: TurnEnded приходит без вызова EndTurn). Это и есть
-- база и для самопроверки эффекта end_turn (ended: true/false).
local actingChar = nil
local turnLog = {}   -- { t = "S"|"E", g = clean_guid } — лента последних смен хода

-- end_turn verification (v0.8.12): the result is written only when the engine
-- actually confirms the turn change (TurnStarted of another combatant or
-- TurnEnded of the requested actor), not on a fixed timer. Timers misreport
-- ended:false when the engine moves the turn slower than the old 1.2s window.
local pendingEndTurn = nil -- { id, acting, actingBefore, marker }

local function finalizeEndTurn(p, ended)
    if pendingEndTurn ~= p then
        return
    end
    pendingEndTurn = nil
    local result = {
        ended = ended,
        acting_before = tostring(p.actingBefore),
        acting_after = tostring(actingChar),
        turn_delta = turnLogSlice(p.marker, 8),
    }
    if not ended then
        writeResult(p.id, false, false, "action_failed",
            "Turn did not change within the deadline (30 s)", result)
    else
        writeResult(p.id, true, false, nil, nil, result)
    end
    _P("[BG3Neuro] end_turn verify: ended=" .. tostring(ended))
end

local function turnLogShowsEnded(p)
    for i = p.marker + 1, #turnLog do
        if turnLog[i].t == "E" and turnLog[i].g == p.acting then
            return true
        end
        if turnLog[i].t == "S" and turnLog[i].g ~= p.acting then
            return true
        end
    end
    return false
end

local function armEndTurn(p)
    pendingEndTurn = p
    -- The engine may have already moved the turn between Osi.EndTurn and arming:
    -- re-scan the log before relying on the event listeners.
    if turnLogShowsEnded(p) then
        finalizeEndTurn(p, true)
        return
    end
    Ext.Timer.WaitForRealtime(30000, function()
        finalizeEndTurn(p, turnLogShowsEnded(p))
    end)
end

Ext.Osiris.RegisterListener("TurnStarted", 1, "after", function(guid)
    actingChar = guid
    turnLog[#turnLog + 1] = { t = "S", g = pureGuid(tostring(guid)) }
    if #turnLog > 32 then
        table.remove(turnLog, 1)
    end
    if pendingEndTurn ~= nil and pureGuid(tostring(guid)) ~= pendingEndTurn.acting then
        finalizeEndTurn(pendingEndTurn, true)
    end
    -- StateExtractor (v0.8.11): каждый сменённый ход — новый combat-state в bg3_to_neuro.json.
    captureCombatState("TurnStarted", false)
end)

Ext.Osiris.RegisterListener("TurnEnded", 1, "after", function(guid)
    turnLog[#turnLog + 1] = { t = "E", g = pureGuid(tostring(guid)) }
    if #turnLog > 32 then
        table.remove(turnLog, 1)
    end
    if pendingEndTurn ~= nil and pureGuid(tostring(guid)) == pendingEndTurn.acting then
        finalizeEndTurn(pendingEndTurn, true)
    end
end)

function turnLogSlice(marker, n)
    -- n последних записей ленты начиная после marker (для самопроверки end_turn)
    local out = {}
    for i = marker + 1, math.min(#turnLog, marker + (n or 16)) do
        out[#out + 1] = { turnLog[i].t, turnLog[i].g }
    end
    return out
end

local function dbRowsRead(name, arity)
    -- Безопасное чтение Osiris-DB по имени: Osi.DB_X:Get(nil,...); возвращает
    -- плоский массив строк или nil, если БД нет/нечитаема. arity — число колонок.
    local rows
    local function tryGet(obj)
        -- Get с явным количеством пустых фильтров (арность 1..3), fallback Get().
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
    -- Аккуратный дамп Osiris-DB (Avatars / CharacterSkipTurn / ...).
    -- Любая операция с Osi/Ext.Osiris в pcall: в разных контекстах
    -- (client/server, story) у БД может не быть метода Get или она вообще
    -- прокси-объект без типа table — такие случаи не должны ронять action.
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

function pureGuid(s)
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
    -- Текущий управляемый(е) персонаж(и): для reserved user id. В одиночке host
    -- может быть user 1 (peer+1); перебираем шире, чем 0..3 (v0.7.3).
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
    -- Явный actor (от C#) — приоритет; затем story-латч (TurnStarted без TurnEnded);
    -- затем контролируемый сейчас персонаж.
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

-- Normalize the actor for end_turn: alias -> entity guid -> clean uuid, so the
-- id given to Osi.EndTurn and the id stored in turnLog (pureGuid) are comparable.
local function resolveEndTurnActor(explicit)
    local raw = resolveActingCharacter(explicit or "")
    if raw == nil or raw == "" then
        return ""
    end
    local viaAlias = resolveEntity(raw)
    return actingCleanOf(viaAlias or raw)
end

-- v0.8.13: Find the id that Ext.Entity.Get actually resolves. It does NOT
-- resolve clean uuids ("c7c13742-...") returned by actingCleanOf — only the
-- prefixed Osiris form ("S_Player_Astarion_c7c13742-..."). Prefer raw if it
-- already resolves, else map the clean guid onto the acting latch or onto a
-- controlled character (GetCurrentCharacter returns prefixed ids).
local function endTurnEntityId(raw, acting)
    if raw ~= nil and raw ~= "" then
        local okE, ent = pcall(Ext.Entity.Get, raw)
        if okE and ent ~= nil then
            return raw
        end
    end
    local clean = pureGuid(acting or "") or ""
    if clean ~= "" then
        if actingChar ~= nil and pureGuid(actingChar) == clean then
            return actingChar
        end
        for _, cc in ipairs(currentCharacters()) do
            if pureGuid(tostring(cc.character)) == clean then
                return tostring(cc.character)
            end
        end
    end
    return acting or raw or ""
end

local entityTurnComponentDump

local function probeGameState()
    -- Диагностика для StateExtractor-сида: кто ходит сейчас, кто в бою.
    -- Каждый шаг независим: падение одного не лишает остальных данных.
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
-- ECS-диагностика (v0.7.4): движковый turn-менеджер, не story.
-- Компонент персонажа EocCombatTurnBasedComponent (entity.TurnBased):
--   IsActiveCombatTurn / CanActInCombat / CanAct_M / ActedThisRoundInCombat /
--   HadTurnInCombat / RequestedEndTurn / EndTurnHoldTimer /
--   TurnActionsCompleted / Timeout / PauseTimer / Combat / CombatTeam.
-- CombatState (EocCombatStateComponent) лежит на combat-сущности:
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
    -- Надёжное чтение скалярных полей компонента (каждое в pcall; класс/прокси:
    -- значения любых типов нормируются, чтобы не ломать Ext.Json.Stringify).
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
    -- Дамп turn-компонента персонажа + combat-сущности (read-only).
    local out = {}
    if Ext == nil or Ext.Entity == nil then
        return { available = false }
    end
    local okE, ent = pcall(Ext.Entity.Get, guid)
    if not okE or ent == nil then
        return { available = false, error = "нет сущности" }
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

local function firstAttempt(attempts, accept)
    -- Первый успешный pcall из перечня (fallback-ladder): НЕ-пустой результат,
    -- опционально прошедший accept-фильтр. Общий механизм для
    -- currentRegionName / ownerCleanOf / itemStatsId / speakerForDialog.
    for _, f in ipairs(attempts) do
        local ok, v = pcall(f)
        if ok and v ~= nil and tostring(v) ~= "" then
            if accept == nil or accept(v) then
                return v
            end
        end
    end
    return nil
end

local function allEntityGuids(compName)
    -- clean guid'ы всех сущностей с компонентом (HandleToUuid).
    -- Общий скелет сканирования для scanNearbyObjects / scanRegions / scanPartyInventory.
    local out = {}
    local okAll, handles = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent(compName) end)
    if not okAll or handles == nil then
        return out
    end
    for i = 1, #handles do
        local okH, guid = pcall(Ext.Entity.HandleToUuid, handles[i])
        if okH and guid ~= nil and tostring(guid) ~= "" then
            out[#out + 1] = tostring(guid)
        end
    end
    return out
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

local function hasNonAscii(s)
    s = tostring(s or "")
    for i = 1, #s do
        if s:byte(i) > 0x7F then
            return true
        end
    end
    return false
end

local statSlugSource = {} -- guid -> "accessor=value" (для stats_probe)

-- SE v32: stats id персонажа лежит в esv::Character (алиас "ServerCharacter") ->
-- CharacterTemplate.Stats (FixedString); резерв - eoc::DataComponent.StatsId
-- (ExtIdeHelpers: EsvCharacter:BaseComponent и StatsComponent прямых полей
-- Stats/StatsId не имеют; Osiris CharacterGetStatsId/DB_CharacterStatsId в v32
-- отсутствуют - проверено runtime'ом).
local STAT_ID_CANDIDATES = {
    { name = "ServerCharacter", path = { "Template", "Stats" }, tag = "ServerCharacter.Template.Stats" },
    { name = "ServerCharacter", path = { "OriginalTemplate", "Stats" }, tag = "ServerCharacter.OriginalTemplate.Stats" },
    { name = "Data", path = { "StatsId" }, tag = "Data.StatsId" },
}

local function resolvePath(comp, path)
    for _, step in ipairs(path) do
        local okS, cur = pcall(function() return comp[step] end)
        if not okS or cur == nil then
            return nil, false
        end
        comp = cur
    end
    return comp, true
end

local function statSlug(guid)
    local okE, ent = pcall(Ext.Entity.Get, guid)
    if okE and ent ~= nil then
        for _, cand in ipairs(STAT_ID_CANDIDATES) do
            local okC, comp = pcall(function() return ent:GetComponent(cand.name) end)
            if okC and comp ~= nil then
                local v, okV = resolvePath(comp, cand.path)
                if okV and v ~= nil then
                    local okT, vs = pcall(tostring, v)
                    if okT and type(vs) == "string" and vs ~= "" and not hasNonAscii(vs) then
                        local s = slug(vs)
                        if s ~= nil and s ~= "" and s ~= "entity" then
                            statSlugSource[guid] = cand.tag .. "='" .. vs .. "'"
                            return s
                        end
                    end
                end
            end
        end
    end
    return nil
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
    local rawName = displayName(guid)
    local base
    if hasNonAscii(rawName) then
        base = statSlug(guid) or slug(rawName)
    else
        base = slug(rawName)
    end
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

local function probeCombatStats()
    -- Диагностика statSlug: участники текущего боя + их компоненты/поля,
    -- а также какой accessor был реально использован для каждого guid.
    local out = { source_map = {}, entries = {} }
    local guids = {}
    local okAll, handles = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("CombatState") end)
    if okAll and handles ~= nil then
        for i = 1, #handles do
            local okC, comp = pcall(function() return handles[i]:GetComponent("CombatState") end)
            if okC and comp ~= nil then
                local parts = participantGuids(comp)
                for _, g in ipairs(parts) do
                    if #guids < 12 then
                        guids[#guids + 1] = g
                    end
                end
                if #guids > 0 then
                    break
                end
            end
        end
    end
    out.guids = guids
    for _, g in ipairs(guids) do
        local entry = { guid = g }
        local okO1, sid1 = pcall(Osi.CharacterGetStatsId, g)
        entry.osi_CharacterGetStatsId = okO1 and tostring(sid1) or "<err: " .. tostring(sid1) .. ">"
        local okO2, rows2 = pcall(Osi.DB_CharacterStatsId, g)
        if okO2 and type(rows2) == "table" and rows2[1] ~= nil then
            local shown = {}
            for _, r in ipairs(rows2) do
                local parts = {}
                for _, v in ipairs(r) do
                    parts[#parts + 1] = tostring(v)
                end
                shown[#shown + 1] = table.concat(parts, "|")
                if #shown >= 2 then break end
            end
            entry.osi_DB_CharacterStatsId = shown
        else
            entry.osi_DB_CharacterStatsId = "<none>"
        end
        local okE, ent = pcall(Ext.Entity.Get, g)
        if okE and ent ~= nil then
            entry.entity = "ok"
            local okN, names = pcall(function() return ent:GetAllComponentNames() end)
            entry.component_names = okN and names or nil
            for _, cand in ipairs(STAT_ID_CANDIDATES) do
                local okCn, comp = pcall(function() return ent:GetComponent(cand.name) end)
                entry["has_" .. cand.name] = okCn and (comp ~= nil) or false
                if okCn and comp ~= nil then
                    local v, okV = resolvePath(comp, cand.path)
                    entry[cand.tag] = (okV and v ~= nil) and tostring(v) or "<nil/err>"
                    local okPairs, keys = pcall(function()
                        local ks = {}
                        for k in pairs(comp) do
                            ks[#ks + 1] = tostring(k)
                            if #ks >= 40 then break end
                        end
                        return ks
                    end)
                    entry[cand.name .. "_keys"] = okPairs and keys or "<pairs/err>"
                end
            end
        else
            entry.entity = "missing"
        end
        out.entries[#out.entries + 1] = entry
        if statSlugSource[g] ~= nil then
            out.source_map[g] = statSlugSource[g]
        end
    end
    return out
end

-- v0.7.7 proven channel: Osi.EndTurn (story) and the RequestedEndTurn flag alone are
-- no-ops (the engine does not move the turn outside a client net message). The working
-- route in live combat: RequestedEndTurn=true on the actor's TurnBased component plus
-- pushing the combat entity into Ext.System.ServerTurnOrder.EndTurn (the same queue
-- the client NETMSG_TURNBASED_ENDTURN_REQUEST feeds). Osi.EndTurn is kept as a cheap
-- extra attempt.
--
-- v0.8.12+ (Tav fix): combatGuid = TurnBased.CombatTeam is a Guid userdata that, for
-- some combat entities (notably the player's own combat via Tav), does NOT resolve via
-- Ext.Entity.UuidToHandle -> nil. The old code then silently skipped the queue push, so
-- end_turn did nothing on the controlled character. Now: resolve the combat handle
-- directly (UuidToHandle) first, else scan all CombatState entities and pick the one
-- that has the acting character among its Participants (same fallback as StateExtractor).
local function combatHandleForEndTurn(acting)
    if acting == nil or acting == "" then
        return nil
    end
    local okE, ent = pcall(Ext.Entity.Get, acting)
    if not okE or ent == nil then
        return nil
    end
    local tb = turnComponent(ent)
    local combatGuid = fieldOf(tb, "CombatTeam") or fieldOf(tb, "Combat")
    if combatGuid ~= nil then
        local okH, h = pcall(Ext.Entity.UuidToHandle, combatGuid)
        if okH and h ~= nil then
            return h
        end
    end
    local actingClean = actingCleanOf(acting)
    local okAll, handles = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("CombatState") end)
    if okAll and handles ~= nil then
        for i = 1, #handles do
            local okS, comp = pcall(function() return handles[i]:GetComponent("CombatState") end)
            local parts = okS and comp ~= nil and participantGuids(comp) or {}
            for _, pGuid in ipairs(parts) do
                if pGuid == actingClean then
                    return handles[i]
                end
            end
        end
    end
    return nil
end

local function requestEngineEndTurn(acting)
    local ok, err = pcall(function()
        local combatHandle = combatHandleForEndTurn(acting)
        local okE, ent = pcall(Ext.Entity.Get, acting)
        if okE and ent ~= nil then
            local okC, comp = pcall(function() return ent:GetComponent("TurnBased") end)
            if okC and comp ~= nil then
                pcall(function() comp.RequestedEndTurn = true end)
            end
        end
        if combatHandle ~= nil then
            local sys = Ext.System and Ext.System.ServerTurnOrder
            if sys ~= nil and sys.EndTurn ~= nil then
                sys.EndTurn[#sys.EndTurn + 1] = combatHandle
            else
                error("Ext.System.ServerTurnOrder.EndTurn not found")
            end
        end
    end)
    if not ok then
        return false, tostring(err)
    end
    local okS, errS = pcall(Osi.EndTurn, acting)
    return true, (not okS) and tostring(errS) or nil
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

-- ============================================================
-- Spells emitter (v0.8.26, тикет 05): PreparedSpells кастера -> state.spells
-- Диапазон/радиус AoE — поля SpellData (TargetRadius/AreaRadius, метры).
-- spell_name отдаётся полным stat-именем (Target_CureWounds / Projectile_FireBolt):
-- executeCast принимает его и как Ext.Stats.Get(spell), и как префиксный матч книги.
-- ============================================================

local function spellRangeAndAoe(statId)
    local range, aoe = 0, 0
    local okS, stats = pcall(Ext.Stats.Get, statId)
    if okS and stats ~= nil then
        local r = fieldOf(stats, "TargetRadius")
        if type(r) == "number" and r > 0 then
            range = r
        end
        local a = fieldOf(stats, "AreaRadius")
        if type(a) == "number" and a > 0 then
            aoe = a
        end
        if range <= 0 then
            -- Touch/Utility без TargetRadius: melee по умолчанию (1.5 м)
            local spellType = tostring(fieldOf(stats, "SpellType") or "")
            if spellType == "Target" or spellType == "Shout" then
                range = 1.5
            end
        end
    end
    return range, aoe
end

local function levelSlotOf(stats)
    -- У заклинаний без SpellSlotsGroup (кантипы/атис) слот = SpellData.Level.
    local lvl = fieldOf(stats, "Level")
    if lvl ~= nil and tostring(lvl) ~= "" then
        return tostring(lvl)
    end
    return nil
end

local function spellSlotFromUseCosts(useCosts)
    -- Real UseCosts: "ActionPoint:1;SpellSlotsGroup:1:1:3" -> "3". Проверено по игре:
    -- Bless(lvl1)="...:1:1:1", ScorchingRay/HoldPerson(lvl2)="...:1:1:2",
    -- Fireball/Counterspell(lvl3)="...:1:1:3" — УРОВЕНЬ слота = ПОСЛЕДНЕЕ число.
    if type(useCosts) ~= "string" then
        return nil
    end
    local seg = useCosts:match("SpellSlotsGroup:[^;]*")
    if seg == nil then
        return nil
    end
    return seg:match(":(%d+)$")
end

local function buildCombatSpellsBlock(state, casterId, casterPosX, casterPosY)
    -- casterId — raw acting (префиксный/датч id). Ext.Entity.Get НЕ резолвит чистые
    -- guid'ы (ревизия v0.8.13): при неудаче маппим id как в endTurnEntityId.
    local id = casterId
    if casterId ~= nil and casterId ~= "" then
        local okTry, entTry = pcall(Ext.Entity.Get, casterId)
        if not okTry or entTry == nil then
            id = endTurnEntityId(casterId, casterId)
        end
    end
    local okE, ent = pcall(Ext.Entity.Get, id)
    local prepared = {}
    if okE and ent ~= nil then
        local okP, ps = pcall(function()
            if ent.SpellBookPrepares and ent.SpellBookPrepares.PreparedSpells then
                return ent.SpellBookPrepares.PreparedSpells
            end
            return {}
        end)
        if okP and ps ~= nil then
            prepared = ps
        end
    end

    local seen = {}
    local list = {}
    for i = 1, #prepared do
        local ps = prepared[i]
        local statId
        local okO, origin = pcall(function() return ps.OriginatorPrototype end)
        if okO and origin ~= nil and tostring(origin) ~= "" then
            statId = tostring(origin)
        else
            local okT, proto = pcall(function() return ps.Prototype end)
            if okT and proto ~= nil and tostring(proto) ~= "" then
                statId = tostring(proto)
            end
        end
        if statId ~= nil and not seen[statId] then
            seen[statId] = true
            local range, aoe = spellRangeAndAoe(statId)
            local slot
            local okG, statsG = pcall(Ext.Stats.Get, statId)
            if okG and statsG ~= nil then
                slot = spellSlotFromUseCosts(fieldOf(statsG, "UseCosts")) or levelSlotOf(statsG)
            end

            local targets = {}
            if range > 0 and casterPosX ~= nil and casterPosY ~= nil then
                for _, e in ipairs(state.enemies or {}) do
                    if type(e.position_x) == "number" and type(e.position_y) == "number" then
                        -- z у врагов не хранится в state: дистанция 2D (как CoverageAuto на C#)
                        local d = math.sqrt((casterPosX - e.position_x) ^ 2 + (casterPosY - e.position_y) ^ 2)
                        if d <= range then
                            targets[#targets + 1] = e.alias
                        end
                    end
                end
            end
            list[#list + 1] = {
                spell_name = statId,
                slot = slot,
                range = round1(range) or 0,
                aoe = round1(aoe) or 0,
                on_cooldown = false,
                targets_in_range = targets,
            }
        end
    end
    state.spells = list
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
                fx[#fx + 1] = "acting now"
            end
            fx[#fx + 1] = canAct and "can act" or "cannot act"
            combatant.effects = table.concat(fx, ", ")
        else
            if hp ~= nil and hp <= 0 then
                combatant.status = "defeated"
            elseif canAct == false then
                combatant.status = "cannot act"
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

    -- v0.8.26 (тикет 05): подготовленные заклинания активного кастера -> state.spells.
    -- Передаём raw acting: buildCombatSpellsBlock сам резолвит id (как endTurnEntityId).
    buildCombatSpellsBlock(state, acting, actingPosX, actingPosY)

    writeStateFile(state)
    diag.stage = "done"
    return state, diag
end

-- ============================================================
-- StateExtractor free-roam (v0.8.26, тикет 08 + 07): exploration / dialogue
-- blocks в bg3_to_neuro.json. Комбат-состояние по-прежнему пишет TurnStarted;
-- свободный режим — периодический тик exploreLoop; диалог — DialogStarted.
-- ============================================================

local EXPLORE_PERIOD_MS = 2000
local EXPLORE_MAX_DISTANCE = 60
local EXPLORE_MAX_OBJECTS = 60
local EXPLORE_OBJECT_TYPES = { "ServerCharacter", "Item", "Useable", "Usable", "Interactable", "Lock", "Loot" }

local dialogActive = false            -- диалог открыт (DialogStarted -> DialogEnded)
local currentScreen = "exploration"   -- "exploration" | "map" | "inventory"

local function currentMode(acting)
    -- Единый приоритет режимов для всех эмиттеров: диалог > комбат > экран > свободный режим.
    if dialogActive then
        return "dialogue"
    end
    if inTurnBasedCombat(acting) then
        return "combat"
    end
    if currentScreen == "map" then
        return "map"
    end
    if currentScreen == "inventory" then
        return "inventory"
    end
    return "exploration"
end

local function inTurnBasedCombat(actor)
    -- Зеркало гейта captureCombatState: у ходящего есть TurnBased.CombatTeam/Combat,
    -- т.е. вне боя возвращает false и тик свободного режима пишет exploration.
    local clean = actingCleanOf(actor)
    if clean == nil or clean == "" then
        return false
    end
    local okE, ent = pcall(Ext.Entity.Get, clean)
    if not okE or ent == nil then
        return false
    end
    local tb = turnComponent(ent)
    return tb ~= nil and (fieldOf(tb, "CombatTeam") ~= nil or fieldOf(tb, "Combat") ~= nil)
end

local function currentRegionName()
    local v = firstAttempt({
        function() return Osi.GetCurrentMap() end,
        function() return Osi.GetCurrentRegion() end,
        function() return Ext.World.GetCurrentMap() end,
    })
    if v ~= nil then
        return tostring(v)
    end
    return nil
end

local function hasComponentSafe(ent, name)
    if ent == nil then
        return false
    end
    local okC, comp = pcall(function() return ent:GetComponent(name) end)
    return okC and comp ~= nil
end

local function classifyObject(guid)
    local okE, ent = pcall(Ext.Entity.Get, guid)
    if not okE then
        ent = nil
    end
    local isChar = hasComponentSafe(ent, "ServerCharacter")
    local isItem = hasComponentSafe(ent, "Item")
    local isLoot = hasComponentSafe(ent, "Loot")
    local isLock = hasComponentSafe(ent, "Lock")
    local isUseable = hasComponentSafe(ent, "Useable") or hasComponentSafe(ent, "Usable")
    local isInteractable = hasComponentSafe(ent, "Interactable")

    local typ = "object"
    local interactions = {}
    local lootable = false
    if isChar then
        typ = "character"
        interactions[#interactions + 1] = "talk"
        if isLoot then
            lootable = true
            interactions[#interactions + 1] = "loot"
        end
    elseif isItem then
        typ = "item"
        interactions[#interactions + 1] = "inspect"
        interactions[#interactions + 1] = "take"
        lootable = true
    else
        if isLock then
            typ = "door"
            interactions[#interactions + 1] = "open"
            interactions[#interactions + 1] = "lockpick"
        elseif isUseable then
            typ = "useable"
            interactions[#interactions + 1] = "use"
        end
        if isLoot then
            lootable = true
            if #interactions == 0 then
                interactions[#interactions + 1] = "loot"
            end
        end
        if isInteractable and #interactions == 0 then
            interactions[#interactions + 1] = "interact"
        end
    end
    return { type = typ, interactions = interactions, lootable = lootable }
end

local function scanNearbyObjects(ax, ay, az, partySet, ownedAliases)
    local out = {}
    local added = {}
    for _, compName in ipairs(EXPLORE_OBJECT_TYPES) do
        local guids = allEntityGuids(compName)
        for _, g in ipairs(guids) do
            if #out >= EXPLORE_MAX_OBJECTS then
                break
            end
            if not partySet[g] and not added[g] then
                local px, py, pz = positionOf(g)
                if px ~= nil and ax ~= nil then
                    local d = distance3(ax, ay, az, px, py, pz)
                    if d ~= nil and d <= EXPLORE_MAX_DISTANCE then
                        added[g] = true
                        local cls = classifyObject(g)
                        out[#out + 1] = {
                            alias = registerAlias(g, false, ownedAliases),
                            name = displayName(g),
                            distance = round1(d) or 0,
                            region = currentRegionName(),
                            seen_by = "player",
                            type = cls.type,
                            status = nil,
                            interactions = cls.interactions,
                            lootable = cls.lootable,
                        }
                    end
                end
            end
        end
    end
    return out
end

local function scanRegions(ax, ay, az)
    local out = {}
    local region = currentRegionName()
    local guids = allEntityGuids("Waypoint")
    for i, g in ipairs(guids) do
        local d = nil
        local px, py, pz = positionOf(g)
        if px ~= nil and ax ~= nil then
            d = distance3(ax, ay, az, px, py, pz)
        end
        local name = displayName(g)
        if name == g or name == "" then
            name = "Waypoint_" .. tostring(i)
        end
        out[#out + 1] = {
            name = name,
            region_id = "wp_" .. tostring(i),
            distance = round1(d or 0) or 0,
            region = region,
        }
    end
    return out
end

local function ownerCleanOf(comp)
    if comp == nil then
        return nil
    end
    local v = firstAttempt({
        function() return comp.ItemData.Owner end,
        function() return comp.Owner end,
        function() return comp.ItemData.Parent end,
        function() return comp.Parent end,
    }, function(raw)
        local p = pureGuid(tostring(raw))
        return p ~= nil and p ~= ""
    end)
    if v == nil then
        return nil
    end
    return pureGuid(tostring(v))
end

local function itemStatsId(comp)
    if comp == nil then
        return nil
    end
    local v = firstAttempt({
        function() return comp.ItemData.StatsId end,
        function() return comp.ItemData.Stats end,
        function() return comp.StatsId end,
    })
    if v ~= nil then
        return tostring(v)
    end
    return nil
end

local function itemQuantity(comp, statsId)
    local okS, s = pcall(function() return comp.Stack end)
    if okS and type(s) == "number" and s > 1 then
        return s
    end
    if statsId ~= nil then
        local okT, t = pcall(function() return Ext.Stats.Get(statsId).Stack end)
        if okT and type(t) == "number" and t > 1 then
            return t
        end
    end
    return 1
end

local function itemCategory(statsId)
    if statsId == nil then
        return nil
    end
    local okS, stats = pcall(Ext.Stats.Get, statsId)
    if not okS or stats == nil then
        return nil
    end
    local okT, t = pcall(function() return stats.Type end)
    local t2 = okT and tostring(t) or ""
    if t2 == "Armor" or t2 == "Weapon" or t2 == "Shield" then
        return "equipment"
    end
    if t2 == "Consumable" or t2 == "Potion" then
        return "consumable"
    end
    return "item"
end

local function scanPartyInventory(partySet)
    local out = {}
    local guids = allEntityGuids("Item")
    for i, itemGuid in ipairs(guids) do
        local okE, ent = pcall(Ext.Entity.Get, itemGuid)
        if okE and ent ~= nil then
            local okC, comp = pcall(function() return ent:GetComponent("Item") end)
            if okC and comp ~= nil then
                local owner = ownerCleanOf(comp)
                if owner ~= nil and partySet[owner] then
                    local statsId = itemStatsId(comp)
                    local name = displayName(itemGuid)
                    if name == itemGuid or name == "" then
                        name = "item_" .. tostring(i)
                    end
                    out[#out + 1] = {
                        alias = "inv_" .. tostring(#out + 1),
                        name = name,
                        quantity = itemQuantity(comp, statsId),
                        category = itemCategory(statsId) or "item",
                    }
                end
            end
        end
    end
    return out
end

local function partySetOf()
    local out = {}
    local avatars = partyAvatars()
    for g in pairs(avatars) do
        out[g] = true
    end
    for _, cc in ipairs(currentCharacters()) do
        local p = pureGuid(cc.character)
        if p ~= nil and p ~= "" then
            out[p] = true
        end
    end
    return out
end

function buildExplorationState(trigger)
    local mode = currentScreen == "map" and "map"
        or currentScreen == "inventory" and "inventory"
        or "exploration"
    local state = {
        version = STATE_VERSION,
        mode = mode,
        generated_at = nowIso(),
        trigger = trigger or "free_roam",
        turn_actor = "",
        allies = {},
        enemies = {},
        objects = {},
        regions = {},
        inventory = {},
        can_rest = false,
        screen = currentScreen,
        available_actions = {},
        events = {},
    }
    local acting = resolveActingCharacter("")
    if acting == nil or acting == "" then
        return state
    end
    local ax, ay, az = positionOf(acting)
    local party = partySetOf()

    local taken = {}
    for g in pairs(party) do
        local alias = registerAlias(g, true, taken)
        local okE, ent = pcall(Ext.Entity.Get, g)
        if not okE then
            ent = nil
        end
        local hp, maxHp = healthOf(ent)
        local px, py, pz = positionOf(g)
        local dist = nil
        if px ~= nil and ax ~= nil then
            dist = round1(distance3(ax, ay, az, px, py, pz))
        end
        state.allies[#state.allies + 1] = {
            alias = alias,
            name = displayName(g),
            hp = hp or 0,
            max_hp = maxHp or 0,
            distance = dist or 0,
            position_x = round1(px or 0),
            position_y = round1(py or 0),
        }
    end

    state.objects = scanNearbyObjects(ax, ay, az, party, taken)
    state.regions = scanRegions(ax, ay, az)
    state.inventory = scanPartyInventory(party)
    local okRest, canRest = pcall(Osi.CanAllPartiesLongRest)
    state.can_rest = okRest and (canRest == true or tostring(canRest) == "1") or false

    return state
end

function captureExplorationState(trigger)
    local state = buildExplorationState(trigger)
    writeStateFile(state)
    return state
end

local function speakerForDialog(dialogId)
    if dialogId == nil then
        return nil
    end
    local v = firstAttempt({
        function() return Osi.DialogGetSpeaker(dialogId) end,
        function() return Osi.DialogGetHostCharacter(dialogId) end,
        function() return Osi.DialogGetActiveCharacter(dialogId) end,
    }, function(raw)
        local clean = pureGuid(tostring(raw)) or tostring(raw)
        local name = displayName(clean)
        return name ~= nil and name ~= ""
    end)
    if v == nil then
        return nil
    end
    local clean = pureGuid(tostring(v)) or tostring(v)
    return displayName(clean)
end

function captureDialogueState(trigger, dialogId)
    local state = {
        version = STATE_VERSION,
        mode = "dialogue",
        generated_at = nowIso(),
        trigger = trigger or "dialog",
        turn_actor = "",
        allies = {},
        enemies = {},
        dialogue = {
            speaker_name = nil,
            line = nil,
            options = {},
        },
        available_actions = { "select_dialogue_option" },
        events = { "Диалог открыт. Варианты ответа живут в клиентском UI (клик по option — TODO(client))." },
    }
    local speaker = speakerForDialog(dialogId)
    if speaker ~= nil then
        state.dialogue.speaker_name = speaker
    end
    writeStateFile(state)
    return state
end

function captureCurrentState(trigger, force)
    -- Единая точка захвата: диалог > комбат > свободный режим. Не затирает
    -- состояние диалога следующими тиками (exploreLoop между DialogStarted/Ended — no-op).
    local acting = resolveActingCharacter("")
    local mode = currentMode(acting)
    if mode == "dialogue" then
        return captureDialogueState(trigger, nil)
    end
    if mode == "combat" then
        return captureCombatState(trigger, force)
    end
    return captureExplorationState(trigger)
end

-- ============================================================
-- Long actions: intermediate running:true + final by game event
-- ============================================================

Ext.Osiris.RegisterListener("CharacterMoveToCancelled", 2, "after", function(character, moveID)
    -- ack: финал cancel уже пишет cancelActiveMove (interruption path)
end)

function cancelActiveMove(reason, detail)
    if activeMove == nil then
        return
    end
    local pending = activeMove
    activeMove = nil
    -- Интеррупт: движение прервано новым действием/внешней причиной → финал cancel
    writeResult(pending.id, true, false, nil, reason .. (detail and (": " .. tostring(detail)) or ""))
end

-- v0.8.19: финал движения. Osi.CharacterMoveTo(..., event, moveID) бросает
-- EntityEvent(character, event) по завершении перемещения — ловим и закрываем
-- running. Раньше листенера не было: move успешно стартовал, но running висел вечно.
Ext.Osiris.RegisterListener("EntityEvent", 2, "after", function(character, event)
    if activeMove ~= nil and tostring(event) == tostring(activeMove.event) then
        local pending = activeMove
        activeMove = nil
        writeResult(pending.id, true, false, nil, nil)
    end
end)

-- ============================================================
-- РЎРѕРІРјРµСЃС‚РЅС‹Р№ РїР°Р№РїР»Р°Р№РЅ РєР°СЃС‚Р°/Р°С‚Р°РєРё (§6.4): ServerCastRequest.
-- Для игроков CastOptions {"FromClient", ...} → ресурсы/кулдауны
-- считает сама игра. Fallback — Osi.UseSpell(AtPosition).
-- ============================================================

local pendingCasts = {} -- { id = action.id, spell = name, caster = uuid }

-- v0.8.18: полный снимок очередей CastRequestSystem (общий для q_cast/q_sys и автоснимков).
local CAST_QUEUE_NAMES = {
    "OsirisCastRequests", "NetworkStartRequests", "AnubisCastRequests",
    "ReactionStartRequests", "ItemStartRequests", "ActiveRollNodeStartRequests",
    "JumpStartRequests", "CommandProtocolStartRequests", "PlanCancelRequests",
    "field_A8", "OsirisCancelRequests", "NetworkCancelRequests",
    "AnubisCancelRequests", "field_E8", "GameplayControllerCancelRequests",
    "ReactionCancelRequests", "CharacterCancelRequests", "TeleportCancelRequests",
    "NetworkPreviewUpdateRequests", "ConfirmRequests",
}

local function readCastQueues()
    local sys
    local sysOk, sysErr = pcall(function() return Ext.System.ServerCastRequest end)
    if not sysOk or sysErr == nil then
        return { error = "ServerCastRequest недоступен (" .. tostring(sysErr) .. ")" }
    end
    sys = sysErr
    local queues = {}
    for _, n in ipairs(CAST_QUEUE_NAMES) do
        local entry = { size = -1, error = nil, entries = nil }
        local ok, arr = pcall(function() return sys[n] end)
        if ok and arr ~= nil then
            local lenOk, len = pcall(function() return #arr end)
            if lenOk then
                entry.size = len
                if len > 0 then
                    local list = {}
                    local maxRead = math.min(len, 8)
                    for i = 1, maxRead do
                        local fOk, f = pcall(function() return arr[i] end)
                        if fOk and f ~= nil then
                            local it = {}
                            local cOk, caster = pcall(function() return f.Caster end)
                            if cOk and caster ~= nil then
                                it.caster = tostring(caster)
                            end
                            local sOk, spell = pcall(function()
                                return f.Spell and f.Spell.Prototype
                            end)
                            if sOk then it.spell = tostring(spell) end
                            local gOk, guid = pcall(function() return f.RequestGuid end)
                            if gOk then it.requestGuid = tostring(guid) end
                            local foOk, forced = pcall(function() return f.Forced end)
                            if foOk then it.forced = forced end
                            local sgOk, sg = pcall(function() return f.SpellCastGuid end)
                            if sgOk then it.spellCastGuid = tostring(sg) end
                            -- v0.8.18+: полные поля реального CastStartRequest (NetGuid, CastOptions,
                            -- Targets, Originator, Item, CastPosition, StoryActionId, field_A8).
                            local ngOk, ng = pcall(function() return f.NetGuid end)
                            if ngOk then it.netGuid = tostring(ng) end
                            local fA8Ok, fA8 = pcall(function() return f.field_A8 end)
                            if fA8Ok then it.field_A8 = fA8 end
                            local saOk, sa = pcall(function() return f.StoryActionId end)
                            if saOk then it.storyActionId = sa end
                            local orOk, ori = pcall(function() return f.Originator end)
                            if orOk and ori ~= nil then
                                it.originator = tostring(ori)
                            end
                            local imOk, im = pcall(function() return f.Item end)
                            if imOk and im ~= nil then it.item = tostring(im) end
                            local cpOk, cp = pcall(function() return f.CastPosition end)
                            if cpOk and cp then it.castPosition = { cp[1], cp[2], cp[3] } end
                            local coOk2, co = pcall(function() return f.CastOptions end)
                            if coOk2 and co ~= nil then it.castOptions = co end
                            local tgOk2, tg = pcall(function() return f.Targets end)
                            if tgOk2 and tg then
                                local tl = {}
                                for _, t in ipairs(tg) do
                                    local ti = { TargetingType = t.TargetingType }
                                    local tOk, th = pcall(function() return t.Target end)
                                    if tOk then ti.targetHandle = tostring(th) end
                                    local pOk2, tp = pcall(function() return t.Position end)
                                    if pOk2 and tp then ti.position = { tp[1], tp[2], tp[3] } end
                                    tl[#tl + 1] = ti
                                end
                                it.targets = tl
                            end
                            list[#list + 1] = it
                        end
                    end
                    entry.entries = list
                end
            else
                entry.error = tostring(len)
            end
        else
            entry.error = ok and "nil" or tostring(arr)
        end
        queues[n] = entry
    end
    return queues
end

-- v0.8.17: диагностика доступности каст-API на текущей сборке BG3SE.
-- В v0.8.16 cast падал с "attempt to call a nil value" — вероятная причина:
-- Ext.System.ServerCastRequest / Ext.Entity.Get / Osi.UseSpell недоступны.
local function castApiDiag()
    local function present(f)
        local ok, v = pcall(f)
        return ok and v == true
    end
    local function typeSummary(typeName)
        local ok, ti = pcall(function() return Ext.Types.GetTypeInfo(typeName) end)
        if not ok or ti == nil then
            return nil
        end
        local members = {}
        if ti.Members ~= nil then
            for memberName, memberInfo in pairs(ti.Members) do
                local t = type(memberInfo) == "table" and memberInfo.NativeName or tostring(memberInfo)
                members[#members + 1] = { name = memberName, type = t }
            end
            table.sort(members, function(a, b) return a.name < b.name end)
        end
        return { name = ti.NativeName, kind = ti.Kind, members = members }
    end
    local queueType
    local qOk, q = pcall(function()
        local s = Ext.System.ServerCastRequest
        return s and s.OsirisCastRequests
    end)
    if qOk and q ~= nil then
        local tOk, t = pcall(function() return Ext.Types.TypeOf(q) end)
        if tOk and t ~= nil then
            queueType = { name = t.NativeName, kind = t.Kind }
            if t.ElementType ~= nil then
                queueType.element = (type(t.ElementType) == "table" and t.ElementType.NativeName)
                    or tostring(t.ElementType)
            end
        end
    end
    local castStartRequest
    if qOk and q ~= nil then
        local tOk, t = pcall(function() return Ext.Types.TypeOf(q) end)
        if tOk and t ~= nil and t.ElementType ~= nil and type(t.ElementType) == "table" then
            local ti = t.ElementType
            local members = {}
            if ti.Members ~= nil then
                for memberName, memberInfo in pairs(ti.Members) do
                    local mt = type(memberInfo) == "table" and memberInfo.NativeName or tostring(memberInfo)
                    members[#members + 1] = { name = memberName, type = mt }
                end
                table.sort(members, function(a, b) return a.name < b.name end)
            end
            castStartRequest = { name = ti.NativeName, kind = ti.Kind, members = members }
        end
    end
    return {
        serverCastRequest = present(function() return Ext.System.ServerCastRequest ~= nil end),
        osiUseSpell = present(function() return Osi.UseSpell ~= nil end),
        osiUseSpellAtPosition = present(function() return Osi.UseSpellAtPosition ~= nil end),
        extEntityGet = present(function() return Ext.Entity ~= nil and type(Ext.Entity.Get) == "function" end),
        extStats = present(function() return Ext.Stats ~= nil end),
        extTypes = present(function() return Ext.Types ~= nil and Ext.Types.GetTypeInfo ~= nil end),
        osiIsPlayer = { present = present(function() return Ext.Osi ~= nil and Ext.Osi.IsPlayer ~= nil end), type = type(Ext.Osi and Ext.Osi.IsPlayer) },
        queueType = queueType,
        castStartRequest = castStartRequest or typeSummary("EsvSpellCastCastStartRequest"),
        spellId = typeSummary("spell_cast::SpellId"),
        initialTarget = typeSummary("spell_cast::InitialTarget"),
    }
end

-- v0.8.18: бисекция — на каком поле падает маппинг `request` в CastStartRequest.
local function newGuidString()
    -- v0.8.17: RequestGuid требует строку в формате GUID (не число!). math.random
    -- возвращал number -> "String expected for argument 5". Генерируем RFC4122-подобный.
    local function h4()
        return string.format("%04x", math.random(0, 0xffff))
    end
    local r = math.random(0, 0x0fff)
    local r2 = math.random(0, 0x0fff)
    return h4() .. h4() .. "-" .. h4() .. "-4" .. string.format("%03x", r) .. "-"
        .. string.format("%x", 8 + math.random(0, 3)) .. string.format("%03x", r2) .. "-"
        .. h4() .. h4() .. h4()
end

local NULL_UUID = "00000000-0000-0000-0000-000000000000"

-- Поля добавляются по одному; первый вариант, у которого push кинул ошибку, и
-- есть виновник. Возвращает таблицу { variant => { ok = bool, err = string? } }.
local function probeCastVariants(actorUuid, spellName, targetUuid)
    local out = {}
    local casterEntity
    local getOk, getErr = pcall(function() return Ext.Entity.Get(actorUuid) end)
    if getOk and getErr then
        casterEntity = getErr
    end
    local targetEntity
    if targetUuid and targetUuid ~= "" then
        local tOk, tErr = pcall(function() return Ext.Entity.Get(targetUuid) end)
        if tOk and tErr then
            targetEntity = tErr
        end
    end
    if casterEntity == nil then
        out.getCaster = { ok = false, err = "caster entity nil" }
        return out
    end

    local spellType = "Target"
    local sOk, stats = pcall(function() return Ext.Stats.Get(spellName) end)
    if sOk and stats ~= nil then
        spellType = stats.SpellType or "Target"
    end

    -- v0.8.18: реальный OriginatorPrototype (как в brawl getOriginatorPrototype):
    -- "Fire Bolt" -> "Projectile_FireBolt", "Piercing Thrust" -> "Target_PiercingThrust".
    -- Игра НЕ резолвит голое имя заклинания в originator - каст молча отбрасывается.
    local originatorPrototype
    if stats and stats.SpellType ~= nil and stats.SpellType ~= "" then
        originatorPrototype = stats.SpellType .. "_" .. spellName:gsub("%s+", "")
    else
        originatorPrototype = spellName
    end
    -- Уточнение по книге кастера: берём реальный OriginatorPrototype, если префиксная
    -- форма не совпала с книгой (rare прототипы, например "Projectile_FireBolt").
    local opsOk, opExtra = pcall(function()
        if casterEntity.SpellBookPrepares and casterEntity.SpellBookPrepares.PreparedSpells then
            local suffix = spellName:gsub("%s+", "")
            for _, ps in ipairs(casterEntity.SpellBookPrepares.PreparedSpells) do
                local o = ps.OriginatorPrototype
                if o then
                    if o == originatorPrototype then
                        return nil
                    end
                    if o:sub(-#suffix) == suffix then
                        return o
                    end
                end
            end
        end
        return nil
    end)
    if opsOk and opExtra then
        originatorPrototype = opExtra
    end

    local spell = {
        OriginatorPrototype = originatorPrototype,
        ProgressionSource = NULL_UUID,
        Prototype = spellName,
        Source = NULL_UUID,
        SourceType = "Osiris",
    }
    local targets = {}
    if targetEntity then
        targets[#targets + 1] = { Target = targetEntity, TargetingType = spellType }
    end

    -- v0.8.18: варианты, повторяющие ют-запрос enqueueCastRequest побайтово.
    -- (1) spell из PreparedSpells без Position; (2) osiris-spell с Position;
    -- (3) prepared-spell + Position — виновник виден по первому появившемуся err.
    local preparedSpell
    local preparedErr
    local pOk2, pErr2 = pcall(function()
        if casterEntity.SpellBookPrepares and casterEntity.SpellBookPrepares.PreparedSpells then
            local suffix = spellName:gsub("%s+", "")
            for _, ps in ipairs(casterEntity.SpellBookPrepares.PreparedSpells) do
                local o = ps.OriginatorPrototype
                if o and o:sub(-#suffix) == suffix then
                    preparedSpell = {
                        OriginatorPrototype = o,
                        ProgressionSource = ps.ProgressionSource,
                        Prototype = spellName,
                        Source = ps.Source,
                        SourceType = ps.SourceType,
                    }
                    break
                end
            end
        end
    end)
    if not pOk2 then
        preparedErr = tostring(pErr2)
    end
    local preparedTargets = {}
    if targetEntity then
        local t2 = { Target = targetEntity, TargetingType = spellType }
        if targetEntity.Transform and targetEntity.Transform.Transform and targetEntity.Transform.Transform.Translate then
            local tp = targetEntity.Transform.Transform.Translate
            t2.Position = { tp[1], tp[2], tp[3] }
        end
        preparedTargets[#preparedTargets + 1] = t2
    end

    local variants = {
        step_1_caster_only = { Caster = casterEntity },
        step_2_castoptions = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity },
        step_3_guid = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString() },
        step_4_spell = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = spell },
        step_5_targets = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = spell, Targets = targets },
        step_6_full = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = spell, Targets = targets, field_A8 = 1 },
        step_7_prepared_spell = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = preparedSpell or spell, Targets = targets, field_A8 = 1 },
        step_8_position = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = spell, Targets = preparedTargets, field_A8 = 1 },
        step_9_prepared_position = { CastOptions = { "FromClient", "ShowPrepareAnimation", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = preparedSpell or spell, Targets = preparedTargets, field_A8 = 1 },
        -- v0.8.18: зеркала NPC-ветки из enqueueCastRequest (IgnoreHasSpell + Osiris Fallback,
        -- как для ShadowHeart при isPlayer=false). Probe раньше не тестировал NPC-набор.
        step_10_npc_osiris = { CastOptions = { "IgnoreHasSpell", "ShowPrepareAnimation", "AvoidDangerousAuras", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = spell, Targets = targets, field_A8 = 1 },
        step_11_npc_prepared = { CastOptions = { "IgnoreHasSpell", "ShowPrepareAnimation", "AvoidDangerousAuras", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = preparedSpell or spell, Targets = targets, field_A8 = 1 },
        step_12_npc_prepared_pos = { CastOptions = { "IgnoreHasSpell", "ShowPrepareAnimation", "AvoidDangerousAuras", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = preparedSpell or spell, Targets = preparedTargets, field_A8 = 1 },
        -- v0.8.18: точное зеркало enqueue для NPC: Osiris-fallback Spell + Position.
        step_13_npc_osiris_pos = { CastOptions = { "IgnoreHasSpell", "ShowPrepareAnimation", "AvoidDangerousAuras", "NoMovement" }, Caster = casterEntity, RequestGuid = newGuidString(), Spell = spell, Targets = preparedTargets, field_A8 = 1 },
    }

    local queue
    local qOk, qErr = pcall(function() return Ext.System.ServerCastRequest.OsirisCastRequests end)
    if qOk and qErr then
        queue = qErr
    end
    for label, request in pairs(variants) do
        if queue then
            local ok, err = pcall(function() queue[#queue + 1] = request end)
            if ok then
                pcall(function() if #queue > 0 then queue[#queue] = nil end end)
                out[label] = { ok = true }
            else
                out[label] = { ok = false, err = tostring(err) }
            end
        else
            out[label] = { ok = false, err = "queue nil" }
        end
    end
    if preparedErr then
        out.preparedErr = preparedErr
    end
    return out
end

local function detectIsPlayer(actorUuid)
    -- v0.8.18: Osi.IsPlayer (Ext.Osi и глобальный Osi) в рантайме — userdata-заглушка,
    -- вызов даёт "attempt to call a nil value" (проверено на стенде), поэтому API
    -- не вызываем вовсе. v0.8.25: надёжный признак «контролируемый персонаж» —
    -- компонент ServerCharacter (InParty/IsPlayer/PartyFollower). Детект по "Player"
    -- в имени — только запасной путь: у чистых GUID его нет (S_Player_Astarion_...
    -- приходит как c7c13742-...), а без isPlayer честный путь уходит NPC-вариантом
    -- (двойной префикс OriginatorPrototype + NULL-Source) и молча игнорится движком.
    local pf = characterPartyFlags(actorUuid)
    if pf and (pf.in_party or pf.is_player or pf.party_follower) then
        return true, "serverCharacter"
    elseif actorUuid and actorUuid:find("Player") then
        return true, "name:Player"
    end
    return false, "non-player"
end

local function enqueueCastRequest(actorUuid, spellName, targetUuid, posX, posY, posZ, spellType, insertAtFront, queueName, forceFlags, bonusAction)
    local apiOk, serverCastRequest = pcall(function() return Ext.System.ServerCastRequest end)
    if not apiOk or serverCastRequest == nil then
        return nil, "ServerCastRequest недоступен на этой сборке BG3SE"
    end

    local casterEntity
    local getOk, getErr = pcall(function() return Ext.Entity.Get(actorUuid) end)
    if getOk and getErr then
        casterEntity = getErr
    end
    if casterEntity == nil then
        return nil, "Не удалось получить сущность кастера"
    end

    -- v0.8.18: buildSpell как в brawl — для игроков берём источник из
    -- SpellBookPrepares.PreparedSpells (ресурсы/кулдауны нативно), для NPC —
    -- Osiris Source. Иначе каст ставится в очередь, но молча не происходит.
    -- OriginatorPrototype - реальный прототип (SpellType_SpellName), иначе игра
-- не резолвит голое имя ("Fire Bolt" vs "Projectile_FireBolt").
    local isPlayer, ipDetail = detectIsPlayer(actorUuid)
    local originatorPrototype = spellType .. "_" .. spellName:gsub("%s+", "")
    local bookPrefix = originatorPrototype
    -- v0.8.18: реальный прототип из книги кастера (суффикс имени) — префиксная формула
    -- (SpellType_Name) НЕТОЧНА: у Fire Bolt SpellType=="Target", реальный прототип
    -- "Projectile_FireBolt". Берём книжный прототип, но только для Speller'а — для NPC
    -- brawl всё равно использует Osiris-Spell (SRC/OSIRIS) и NULL_UUID.
    if casterEntity.SpellBookPrepares and casterEntity.SpellBookPrepares.PreparedSpells then
        local sOk, sRes = pcall(function()
            local suffix = spellName:gsub("%s+", "")
            for _, ps in ipairs(casterEntity.SpellBookPrepares.PreparedSpells) do
                local o = ps.OriginatorPrototype
                if o and o:sub(-#suffix) == suffix then
                    return o
                end
            end
        end)
        if sOk and sRes then
            originatorPrototype = sRes
        end
    end

    local spell
    -- v0.8.18: buildSpell как в brawl — для игроков источник из PreparedSpells
    -- (ресурсы/кулдауны нативно), для NPC — Osiris Source (NULL_UUID).
    if isPlayer and casterEntity.SpellBookPrepares and casterEntity.SpellBookPrepares.PreparedSpells then
        local pbOk, pbErr = pcall(function()
            local suffix = spellName:gsub("%s+", "")
            for _, preparedSpell in ipairs(casterEntity.SpellBookPrepares.PreparedSpells) do
                local o = preparedSpell.OriginatorPrototype
                if o and o:sub(-#suffix) == suffix then
                    spell = {
                        OriginatorPrototype = o,
                        ProgressionSource = preparedSpell.ProgressionSource,
                        Prototype = spellName,
                        Source = preparedSpell.Source,
                        SourceType = preparedSpell.SourceType,
                    }
                    break
                end
            end
        end)
        if not pbOk then
            _P("[BG3Neuro] PreparedSpells read failed: " .. tostring(pbErr))
        end
    end
    if spell == nil then
        spell = {
            OriginatorPrototype = originatorPrototype or bookPrefix,
            ProgressionSource = NULL_UUID,
            Prototype = spellName,
            Source = NULL_UUID,
            SourceType = "Osiris",
        }
    end

    local targets = {}
    if targetUuid and targetUuid ~= "" then
        local targetEntity
        local tOk, tErr = pcall(function() return Ext.Entity.Get(targetUuid) end)
        if tOk and tErr then
            targetEntity = tErr
        end
        if targetEntity == nil then
            return nil, "Не удалось получить сущность цели"
        end
        -- v0.8.18: как brawl — позиция цели всегда добавляется в Target.
        local target = { Target = targetEntity, TargetingType = spellType }
        if targetEntity.Transform and targetEntity.Transform.Transform and targetEntity.Transform.Transform.Translate then
            local tp = targetEntity.Transform.Transform.Translate
            target.Position = { tp[1], tp[2], tp[3] }
        end
        targets[#targets + 1] = target
    elseif posX then
        targets[#targets + 1] = {
            Position = { posX, posY, posZ },
            TargetingType = spellType,
        }
    end

    -- v0.8.18+: выбор очереди. "network" -> NetworkStartRequests (канал, через который
    -- игра принимает каст игрока в его ход), иначе OsirisCastRequests.
    local queueId = queueName or "osiris"
    local queue
    local qOk, qErr = pcall(function() return serverCastRequest[queueId == "network" and "NetworkStartRequests" or "OsirisCastRequests"] end)
    if qOk and qErr then
        queue = qErr
    end
    if queue == nil then
        return nil, (queueId == "network" and "NetworkStartRequests" or "OsirisCastRequests") .. " недоступен"
    end

    local castOptions
    if isPlayer then
        castOptions = { "FromClient", "ShowPrepareAnimation", "AvoidDangerousAuras", "NoMovement" }
    else
        castOptions = { "IgnoreHasSpell", "ShowPrepareAnimation", "AvoidDangerousAuras", "NoMovement" }
    end
    -- v0.8.18+: hogwild force-флаги (диагностика FTB-паузы, когда движок молча глотает
    -- запрос из OsirisCastRequests). Не ставим "Immediate" для сетевой очереди.
    if forceFlags then
        local add = {}
        for _, f in ipairs({ "IgnoreHasSpell", "IgnoreCastChecks", "IgnoreSpellRolls", "IgnoreTargetChecks", "Forced", "Immediate" }) do
            if not (queueId == "network" and f == "Immediate") then
                add[#add + 1] = f
            end
        end
        castOptions = add
    end
    -- v0.8.25 (тикет 05, фикс): оффхенд-атака — отдельный стат OffhandAttack,
    -- опция CastOffhand в SpellCastOptions НЕ существует в этой версии игры
    -- (валидный список см. выше), поэтому доп. флаг не добавляем. NoMovement же
    -- блокирует ПОДХОД к цели в радиус (CastSpellFailed/BlockedRequiredMove) —
    -- для бонусной атаки движение разрешаем.
    if bonusAction then
        for i = #castOptions, 1, -1 do
            if castOptions[i] == "NoMovement" then
                table.remove(castOptions, i)
            end
        end
    end
    local request = {
        CastOptions = castOptions,
        Caster = casterEntity,
        RequestGuid = newGuidString(),
        Spell = spell,
        Targets = targets,
        field_A8 = 1,
    }

    -- v0.8.18: debug-дамп ДО push — что собираемся пушить (отладка "молча игнорится" стр. ниже).
    local preparedList = {}
    if casterEntity.SpellBookPrepares and casterEntity.SpellBookPrepares.PreparedSpells then
        local plOk, plErr = pcall(function()
            for _, ps in ipairs(casterEntity.SpellBookPrepares.PreparedSpells) do
                preparedList[#preparedList + 1] = {
                    OriginatorPrototype = ps.OriginatorPrototype,
                    ProgressionSource = ps.ProgressionSource,
                    Source = ps.Source,
                    SourceType = ps.SourceType,
                }
            end
        end)
        if not plOk then
            _P("[BG3Neuro] PreparedSpells dump failed: " .. tostring(plErr))
        end
    end
    local debugInfo = {
        actor = actorUuid,
        actorHandle = tostring(casterEntity),
        isPlayer = isPlayer,
        isPlayerDetail = ipDetail or "<unset>",
        osiPlayerApi = { ext = type(Ext.Osi and Ext.Osi.IsPlayer), global = type(Osi and Osi.IsPlayer) },
        spellName = spellName,
        spell = {
            OriginatorPrototype = request.Spell.OriginatorPrototype,
            ProgressionSource = request.Spell.ProgressionSource,
            Prototype = request.Spell.Prototype,
            Source = request.Spell.Source,
            SourceType = request.Spell.SourceType,
        },
        castOptions = request.CastOptions,
        queue = queueId,
        forceFlags = forceFlags == true,
        bonusAction = bonusAction == true,
        targetUuid = targetUuid,
        targetPos = targets[1] and targets[1].Position or nil,
        preparedSpells = preparedList,
        queueSize = queue and #queue or -1,
        requestGuid = request.RequestGuid,
    }
    local saveOk, saveErr = pcall(Ext.IO.SaveFile, RESULT_DIR .. "/cast_debug.json", Ext.Json.Stringify(debugInfo))
    if not saveOk then
        _P("[BG3Neuro] cast_debug save failed: " .. tostring(saveErr))
    end

    -- v0.8.18: pcall на само присвоение в очередь — "String expected for argument 5, got nil"
    -- бросается маппингом Lua-таблицы в CastStartRequest, а не нашими return-внутренностями.
    local failTrace = {}
    local enqPushOk, enqPushErr
    if insertAtFront then
        -- v0.8.18: brawl вставляет НАЧАЛО при TruePause+isInFTB (пошаговый бой на паузе).
        enqPushOk, enqPushErr = pcall(function()
            for i = #queue, 1, -1 do
                queue[i + 1] = queue[i]
            end
            queue[1] = request
        end)
    else
        enqPushOk, enqPushErr = pcall(function() queue[#queue + 1] = request end)
    end
    if enqPushOk then
        -- v0.8.18: мгновенный снимок очередей СРАЗУ после пуша (до того, как движок
        -- разберёт запрос в том же кадре) — видим запрос в OsirisCastRequests и его поля.
        local snap = readCastQueues()
        if not snap.error then
            pcall(Ext.IO.SaveFile, RESULT_DIR .. "/cast_queues_" .. tostring(request.RequestGuid or "x") .. "_0ms.json",
                Ext.Json.Stringify({ tag = "post-push-0ms", queues = snap }))
        end
        return true, nil
    end
    -- Локализация: если полный request упал, пробуем урезанные варианты (как probe),
    -- чтобы понять, какое поле триггерит ошибку маппера.
    local function pushVariant(label, v)
        local ok, e = pcall(function() queue[#queue + 1] = v end)
        if ok then
            pcall(function() queue[#queue] = nil end)
            failTrace[label] = "ok"
        else
            failTrace[label] = tostring(e)
        end
    end
    pushVariant("spell_only", { Spell = request.Spell })
    pushVariant("targets_only", { Targets = request.Targets })
    pushVariant("spell_targets", { Spell = request.Spell, Targets = request.Targets })
    pushVariant("options_cast", { CastOptions = request.CastOptions, Caster = request.Caster, RequestGuid = request.RequestGuid, Spell = request.Spell, Targets = request.Targets })
    pushVariant("full_no_a8", { CastOptions = request.CastOptions, Caster = request.Caster, RequestGuid = request.RequestGuid, Spell = request.Spell, Targets = request.Targets, field_A8 = nil })
    local traceInfo = { enqueue_error = tostring(enqPushErr), fail_trace = failTrace }
    pcall(Ext.IO.SaveFile, RESULT_DIR .. "/cast_trace.json", Ext.Json.Stringify(traceInfo))
    return nil, tostring(enqPushErr)
end

-- Финал каста по игровым событиям (долгие/канальные заклинания): running:false.
-- Если событие не пришло — правда всё равно уходит через следующий state (Канал B).
local function finalizeCast(caster, spellName, cancelled)
    for i = 1, #pendingCasts do
        local pc = pendingCasts[i]
        -- v0.8.19: событие CastedSpell приходит с прототипным именем
        -- ("Projectile_FireBolt"), а в pendingCasts записано "FireBolt" — матчим все три.
        local spellMatch = pc.spell == spellName
            or pc.spell == "Projectile_" .. spellName
            or pc.spell == "Target_" .. spellName
            or spellName == "Projectile_" .. pc.spell
            or spellName == "Target_" .. pc.spell
        -- v0.8.19: CastedSpell приходит с префиксом имени ("HalfElves_..._e6090219-…"),
        -- в pendingCasts храним голый GUID e6090219-… — сравниваем по GUID-суффиксу.
        local casterMatch = pc.caster == caster
            or (type(caster) == "string" and caster:sub(-36) == pc.caster)
            or (type(pc.caster) == "string" and pc.caster:sub(-36) == caster)
        if casterMatch and spellMatch then
            table.remove(pendingCasts, i)
            -- v0.8.24: снапшот ресурсов после действия (тикет 02) — каст/атака завершились.
            pcall(writeResourceSnapshot, pc.id, caster, "after")
            writeResult(pc.id, true, false, cancelled and "cast_failed" or nil,
                cancelled and "Каст прерван/провален" or nil)
            return
        end
    end
end

-- v0.8.18+: дамп ЖИВЫХ каст-сущностей (ServerSpellCastState) — ground truth для
-- сравнения с нашим синтетическим запросом: NetGuid, CastOptions, Targets,
-- SpellCastGuid, CasterStartPosition. Собирает список кастов; файл пишется
-- только если касты реально существуют (иначе поллинг затирал бы захват пустотой).
local function collectCastEntities()
    local casts = {}
    local allOk, handles = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerSpellCastState") end)
    if allOk and handles then
        for _, h in ipairs(handles) do
            local eOk, e = pcall(function() return Ext.Entity.Get(h) end)
            if eOk and e then
                local st
                local sOk, s = pcall(function() return e.ServerSpellCastState end)
                if sOk then st = s end
                if st then
                    local it = {}
                    -- eoc::spell_cast::StateComponent: здесь Caster/SpellId/CastOptions/Targets/NetGuid/SpellCastGuid.
                    local eocOk, eoc = pcall(function() return e.SpellCastState end)
                    if eocOk and eoc then
                        local cOk, caster = pcall(function() return eoc.Caster end)
                        if cOk then it.casterHandle = tostring(caster) end
                        local eOk2, casterEnt = pcall(function() return eoc.Caster:Get() end)
                        if eOk2 and casterEnt then
                            it.casterUuid = tostring(casterEnt.Uuid and casterEnt.Uuid.EntityUuid or nil)
                        end
                        local entOk, ent = pcall(function() return eoc.Entity end)
                        if entOk then it.entityHandle = tostring(ent) end
                        local spOk, sp = pcall(function() return eoc.SpellId end)
                        if spOk then
                            local spd = {}
                            local p1, v1 = pcall(function() return sp.Prototype end)
                            if p1 then spd.Prototype = tostring(v1) end
                            local p2, v2 = pcall(function() return sp.OriginatorPrototype end)
                            if p2 then spd.OriginatorPrototype = tostring(v2) end
                            local p3, v3 = pcall(function() return sp.Source end)
                            if p3 then spd.Source = tostring(v3) end
                            local p4, v4 = pcall(function() return sp.ProgressionSource end)
                            if p4 then spd.ProgressionSource = tostring(v4) end
                            local p5, v5 = pcall(function() return sp.SourceType end)
                            if p5 then spd.SourceType = tostring(v5) end
                            local p6, v6 = pcall(function() return sp.SpellId end)
                            if p6 then spd.SpellId = tostring(v6) end
                            it.spell = spd
                        end
                        local coOk, co = pcall(function() return eoc.CastOptions end)
                        if coOk then it.castOptions = co end
                        local tgOk, tg = pcall(function() return eoc.Targets end)
                        if tgOk and tg then
                            local tl = {}
                            for _, t in ipairs(tg) do
                                local ti = { TargetingType = t.TargetingType }
                                local tOk, th = pcall(function() return t.Target end)
                                if tOk then ti.targetHandle = tostring(th) end
                                local pOk, tp = pcall(function() return t.Position end)
                                if pOk and tp then ti.position = { tp[1], tp[2], tp[3] } end
                                tl[#tl + 1] = ti
                            end
                            it.targets = tl
                        end
                        local cgOk, cg = pcall(function() return eoc.SpellCastGuid end)
                        if cgOk then it.spellCastGuid = tostring(cg) end
                        local ngOk, ng = pcall(function() return eoc.NetGuid end)
                        if ngOk then it.netGuid = tostring(ng) end
                        local cpOk, cp = pcall(function() return eoc.CastPosition end)
                        if cpOk and cp then it.castPosition = { cp[1], cp[2], cp[3] } end
                        local ceOk, ce = pcall(function() return eoc.CastEndPosition end)
                        if ceOk and ce then it.castEndPosition = { ce[1], ce[2], ce[3] } end
                        local csOk, cs = pcall(function() return eoc.CasterStartPosition end)
                        if csOk and cs then it.casterStartPosition = { cs[1], cs[2], cs[3] } end
                        local srOk, sr = pcall(function() return eoc.Source end)
                        if srOk then it.sourceHandle = tostring(sr) end
                        local rOk, r = pcall(function() return eoc.Random end)
                        if rOk then it.random = r end
                    end
                    local phOk, ph = pcall(function() return st.Phase end)
                    if phOk then it.phase = tostring(ph) end
                    local syOk, sy = pcall(function() return st.StoryActionId end)
                    if syOk then it.storyActionId = sy end
                    -- v0.8.18+: тег-компонент "клиент инициировал каст" (настоящий клик игрока).
                    local ciOk, ci = pcall(function() return e.ServerSpellClientInitiated ~= nil end)
                    if ciOk then it.clientInitiated = ci end
                    casts[#casts + 1] = it
                end
            end
        end
    end
    return casts
end

local function dumpCastEntities(tag)
    local out = { tag = tag, timestamp = os and os.time and os.time() or nil, casts = collectCastEntities() }
    if #out.casts > 0 then
        pcall(Ext.IO.SaveFile, RESULT_DIR .. "/cast_capture.json", Ext.Json.Stringify(out))
        _P("[BG3Neuro] cast_capture: " .. tostring(#out.casts) .. " live cast(s), tag=" .. tostring(tag))
    end
    return out
end

Ext.Osiris.RegisterListener("CastedSpell", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
    finalizeCast(caster, spell, false)
end)

Ext.Osiris.RegisterListener("CastSpellFailed", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
    finalizeCast(caster, spell, true)
end)

-- v0.8.14: actor для move/attack/cast без explicit — story-лэтч (resolveActingCharacter),
-- как в end_turn: пустой actor резолвился в nil (resolveEntity("") = nil) и действия
-- падали с "Could not resolve the movement/attacker/caster actor".
-- Объявлена ДО executeCast (v0.8.16): Lua видит локальные только после объявления.
local function resolveCombatActor(explicit)
    if explicit ~= nil and explicit ~= "" then
        local via = resolveEntity(explicit)
        if via ~= nil then
            return via
        end
        return explicit
    end
    local raw = resolveActingCharacter("")
    if raw ~= nil and raw ~= "" then
        return raw
    end
    return nil
end

local function executeCast(action)
    local data = action.data
    local actor = resolveCombatActor(data.actor)
    local spellName = data.spell_name
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the caster"
    end
    if spellName == nil or spellName == "" then
        return false, nil, "action_failed", "spell_name is required"
    end

    -- v0.8.19: "только в свой ход" по CanActInCombat кастера, а не по actingChar:
    -- у BG3 бывают групповые ходы (несколько персонажей действуют в одном окне),
    -- strict-матч actingChar заблокировал бы Тава в общий ход с Гейлом.
    -- CanActInCombat -- признак "может действовать сейчас" из TurnBased-компонента
    -- (как и в снапшоте state.canAct). Известен nil (компонент не читается) --
    -- fallback на прошлый actingChar-матч.
    local entOk, entVal = pcall(Ext.Entity.Get, actor)
    local canAct = nil
    if entOk and entVal ~= nil then
        canAct = fieldOf(turnComponent(entVal), "CanActInCombat")
    end
    canAct = (canAct == true) or (tostring(canAct) == "true")
    local acting = pureGuid(actingChar)
    local okToCast = canAct or (acting ~= nil and pureGuid(actor) == acting)
    if not okToCast then
        return false, nil, "action_failed", "not_caster_turn: " .. tostring(actor) .. " canAct=" .. tostring(canAct)
    end

    -- Прерываем активное движение (каст и движение не пересекаются)
    cancelActiveMove("Движение прервано кастом", action.id)

    -- v0.8.24: снапшот ресурсов до действия (тикет 02, критерий честной экономики).
    pcall(writeResourceSnapshot, action.id, actor, "before")

    local stats = Ext.Stats.Get(spellName) -- prototype-имя (X5-нормализация в StateExtractor)
    local spellType = stats and stats.SpellType or "Target"
    local target = resolveEntity(data.target_id or "")
    local pos = data.position

    -- v0.8.17: pcall-обёртка enqueueCastRequest — ловим точную ошибку API вместо всплытия.
    local ok, err
    -- v0.8.25 (тикет 04): авто insertAtFront в свой ход игрока — каст резолвится
    -- сейчас, а не после чужих запросов. Явный data.insert_at_front остаётся override.
    local insertAtFront = data.insert_at_front == true
    if data.insert_at_front == nil and canAct then
        local isPl, _ = detectIsPlayer(actor)
        insertAtFront = isPl
    end
    -- v0.8.25 (тикет 03): useOsiSpell явно ИЛИ force_legacy / устойчивый откат.
    local useOsiSpell = data.use_osi_spell == true or useLegacyNow()
    local queueName = data.queue
    local forceFlags = data.force_flags == true
    local oseiOk, oseiRes, oseiEntry
    if useOsiSpell then
        -- Реальный игровой каст (v0.8.19, доказано вживую) — прямой Osi.UseSpell.
        -- Стабильное знание из экспериментов:
        --  * голое имя ("FireBolt") даёт story-запись без игрового каста;
        --  * реальный каст идёт по прототипному имени ОСЕЙ (Projectile_FireBolt),
        --    которое у актора есть в книге (Osi.HasSpell(actor, sid) == 1);
        --  * рабочий вари�ант — 3-арг. overload UseSpell(actor, sid, target)
        --    (без withoutMove: строка в нём давала "Number expected for argument 6").
        -- Пробуем кандидатов, приоритет у имён из книги кастера.
        local spellCandidates = { spellName, "Projectile_" .. spellName, "Target_" .. spellName }
        local knownNames = {}
        local knownAdded = {}
        for _, sid in ipairs(spellCandidates) do
            if Osi and Osi.HasSpell then
                local hOK, hRes = pcall(Osi.HasSpell, actor, sid)
                if hOK and tostring(hRes) == "1" and not knownAdded[sid] then
                    knownNames[#knownNames + 1] = sid
                    knownAdded[sid] = true
                end
            end
        end
        for _, sid in ipairs(spellCandidates) do
            if not knownAdded[sid] then
                knownNames[#knownNames + 1] = sid
            end
        end
        if target then
            for _, sid in ipairs(knownNames) do
                if not oseiOk then
                    oseiOk, oseiRes = pcall(Osi.UseSpell, actor, sid, target)
                end
            end
        elseif pos then
            oseiOk, oseiRes = pcall(Osi.UseSpellAtPosition, actor, spellName, pos.x, pos.y, pos.z)
            if not oseiOk then
                oseiOk, oseiRes = pcall(Osi.UseSpellAtPosition, actor, spellName, pos.x, pos.y, pos.z, 0)
            end
        else
            ok = false
            err = "use_osi_spell: no target or position"
        end
        if target or pos then
            ok = oseiOk
            err = oseiOk and nil or tostring(oseiRes)
        end
    else
        local enqOk, enqRes, enqErr = pcall(function()
            return enqueueCastRequest(actor, spellName, target, pos and pos.x, pos and pos.y, pos and pos.z, spellType, insertAtFront, queueName, forceFlags)
        end)
        if enqOk and enqRes == true then
            ok, err = true, nil
            pipelineSucceeded()
        else
            ok = false
            err = enqOk and enqErr or tostring(enqRes)
        end
    end
    if not ok and not useOsiSpell then
        -- v0.8.25 (тикеты 03/04): гибрид — на сбой ЧЕСТНОГО пути (ошибка enqueue)
        -- инкрементим счётчик, на этот вызов подхватываем legacy. CastSpellFailed
        -- сюда не попадает (это валидный исход каста, не сбой машин�ерии).
        pipelineFailed("cast")
        -- Fallback: копьё подальше от pipeline, честных AP не гарантирует.
        if pos then
            ok, err = pcall(Osi.UseSpellAtPosition, actor, spellName, pos.x, pos.y, pos.z, 0)
        elseif target then
            ok, err = pcall(Osi.UseSpell, actor, spellName, target, "", 1)
        end
    end

    if not ok then
        -- v0.8.17: прикладываем диагноз доступности каст-API к результату, чтобы
        -- не приходилось гадать по "attempt to call a nil value": какой именно API nil.
        local diag = castApiDiag()
        diag.enqueue_error = tostring(err)
        diag.probe = probeCastVariants(actor, spellName, target)
        _P("[BG3Neuro] cast '" .. spellName .. "' failed: " .. tostring(err))
        return false, nil, "action_failed", tostring(err), diag
    end

    pendingCasts[#pendingCasts + 1] = { id = action.id, spell = spellName, caster = actor }
    return true, true, nil, nil -- success, running (финал — событие CastedSpell/CastSpellFailed)
end

-- ============================================================
-- Диалог (тикет 07): select_dialogue_option через client-клик.
-- Server РЅРµ СѓРјРµРµС‚ РїСѓР±Р»РёС‡РЅРѕ РІС‹Р±РёСЂР°С‚СЊ РІР°СЂРёР°РЅС‚ (research §7.2, РЅРµС‚ PickDialogNode);
-- значит исполнитель живёт в client-контексте (Ext.UI). Если клиентский
-- контекст недоступен — откат not_supported (НЕ уводить Neuro в цикл без канала).
-- Варианты в state даёт тот же client-источник, что и рендер UI (option_index == UI order).
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
    -- v0.8.26: диалог открыт — пишем dialogue-состояние в bg3_to_neuro.json и
    -- держим флаг, чтобы exploreLoop не затирал его exploration-тиками.
    dialogActive = true
    local okD = pcall(captureDialogueState, "dialog_started", dialog)
    if okD then
        _P("[BG3Neuro] dialogue: opened")
    end
end)

Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(dialog, instanceID)
    dialogActive = false
    finalizeDialogueOption(dialog)
    -- следующий тик exploreLoop вернёт exploration (или TurnStarted — комбат)
    _P("[BG3Neuro] dialogue: closed")
end)

local function executeDialogueOption(action)
    local data = action.data
    local index = data.option_index
    if index == nil then
        return false, nil, "not_supported", "option_index is required"
    end

    -- Кнопка диалога находится в клиентском UI (Noesis); клик — только из client-контекста.
    if Ext == nil or Ext.UI == nil then
        return false, nil, "not_supported",
            "ClientAutoselectExecutor unavailable: no client context for option highlight/click"
    end

    -- Долгий ход: клик происходит в UI, итог — событие DialogEnded/DialogClosed.
    pendingDialogue[#pendingDialogue + 1] = { id = action.id, dialog = "(unknown)" }
    -- TODO(client): Ext.UI.NeedMouse / эмуляция клика по UI-элементу option_index, подсветка перед кликом;
    -- сюда — реальный диалоговый дескриптор для матчинга DialogEnded.
    return true, true, nil, nil -- success, running (финал — DialogEnded)
end

local function executeMoveToTarget(action)
    local data = action.data
    local actor = resolveCombatActor(data.actor)
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the movement actor"
    end
    if target == nil and not data.position then
        return false, nil, "action_failed", "Movement target not found"
    end

    -- Прерываем предыдущее движение (interruption path, событие cancel)
    cancelActiveMove("Движение прервано новым действием", action.id)

    local moveEvent = "BG3NeuroMove_" .. action.id
    local moveId = math.random(1, 2147483647)
    local ok, err
    if data.position then
        ok, err = pcall(Osi.CharacterMoveToPosition, actor, data.position.x, data.position.y, data.position.z, "Run", moveEvent, moveId)
    elseif target then
        -- переместиться к сущности: координата цели через Osi.GetPosition
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
    local actor = resolveCombatActor(data.actor)
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the attacker"
    end
    if target == nil then
        return false, nil, "action_failed", "Attack target not found"
    end

    -- Прерываем активное движение (движение и атака не пересекаются)
    cancelActiveMove("Движение прервано атакой", action.id)

    -- v0.8.24: снапшот ресурсов до действия (тикет 02, критерий честной экономики).
    pcall(writeResourceSnapshot, action.id, actor, "before")

    -- §6.4: атаки игроков — через ServerCastRequest (честная каст-машинерия).
    -- v0.8.23 (приоритет): enqueueCastRequest в OsirisCastRequests — spell строится
    -- из SpellBookPrepares.PreparedSpells кастера (валидный Source/ProgressionSource),
    -- поэтому AP, bonus actions и cooldowns списываются нативно, FromClient для игрока.
    -- v0.8.22 (fallback 1, доказан вживую): Osi.UseSpell по прототипному имени ОСЕЙ
    -- оружейной атаки + ручное списание 1 AP (Osiris игнорирует ресурсы сам).
    -- (fallback 2, NPC): Osi.Attack (one-shot, без ресурсов).
    local attackCandidates = {
        "MainHandAttack", "Projectile_MainHandAttack", "Target_MainHandAttack",
        "MainHandRangedAttack", "Projectile_MainHandRangedAttack", "Target_MainHandRangedAttack",
    }
    local knownNames = {}
    local knownAdded = {}
    for _, sid in ipairs(attackCandidates) do
        if Osi and Osi.HasSpell then
            local hOK, hRes = pcall(Osi.HasSpell, actor, sid)
            if hOK and tostring(hRes) == "1" and not knownAdded[sid] then
                knownNames[#knownNames + 1] = sid
                knownAdded[sid] = true
            end
        end
    end
    for _, sid in ipairs(attackCandidates) do
        if not knownAdded[sid] then
            knownNames[#knownNames + 1] = sid
        end
    end

    local ok, err
    local usedWeaponSpell = false
    local honestUsed = false
    local usedSid

    -- v0.8.25 (тикет 03): force_legacy/устойчивый откат → честный путь пропускаем.
    local legacyNow = useLegacyNow()

    -- Честный путь (§6.4): ServerCastRequest.OsirisCastRequests, spell из книги
    -- кастера (нативные ресурсы/кулдауны). Пробуем кандидатов из книги сначала.
    if not legacyNow then
        for _, sid in ipairs(knownNames) do
            if not honestUsed then
                local stOK, stRes = pcall(function() return Ext.Stats.Get(sid) end)
                local sType = "Target"
                if stOK and stRes and stRes.SpellType then
                    sType = stRes.SpellType
                end
                local enqOK, enqRes, enqErr = pcall(function()
                    return enqueueCastRequest(actor, sid, target, nil, nil, nil, sType, false, nil, false)
                end)
                if enqOK and enqRes == true then
                    honestUsed = true
                    usedWeaponSpell = true
                    usedSid = sid
                    ok = true
                    -- v0.8.25 (03): успех честного пути сбрасывает счётчик сбоев.
                    pipelineSucceeded()
                end
            end
        end
    end

    -- Fallback 1: Osi.UseSpell (v0.8.22, доказан вживую) — реальный боевой удар,
    -- резолв + броски + журнал идут в игре. 3-арг. UseSpell(actor, sid, target).
    -- v0.8.25 (03): это НЕ честный путь → инкрементим счётчик гибрида.
    if not honestUsed then
        if not legacyNow then
            pipelineFailed("attack")
        end
        for _, sid in ipairs(knownNames) do
            if not ok then
                ok, err = pcall(Osi.UseSpell, actor, sid, target)
                if ok then
                    usedWeaponSpell = true
                    usedSid = sid
                end
            end
        end
    end

    if not ok then
        -- Fallback 2: документированный fallback для NPC — Osi.Attack (one-shot, alwaysHit=0).
        ok, err = pcall(Osi.Attack, actor, target, 0)
    end
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    -- Списание ресурса: честный путь (enqueueCastRequest) списывает AP/кулдауны
    -- нативно через Source из PreparedSpells. Для fallback Osi.UseSpell осiris
    -- игнорирует ресурсы — списываем 1 AP вручную (проверено вживую v0.8.22).
    if usedWeaponSpell and not honestUsed then
        local apOk, apErr = pcall(Osi.AddActionPoints, actor, -1)
        if not apOk then
            _P("[BG3Neuro] attack AP spend failed: " .. tostring(apErr))
        end
    end

    -- Финализация (running -> результат после броска) через CastedSpell/CastSpellFailed,
    -- как у каста: запись в pendingCasts матчится finalizeCast по списку-префиксам.
    pendingCasts[#pendingCasts + 1] = { id = action.id, spell = usedSid or "MainHandAttack", caster = actor }
    -- Если сработал fallback Osi.Attack — событий CastedSpell/CastSpellFailed может
    -- не быть; финализируем результат сразу (one-shot завершился).
    if not usedWeaponSpell then
        pcall(writeResourceSnapshot, action.id, actor, "after")
        writeResult(action.id, true, false, nil, nil)
        return true, false, nil, nil
    end
    return true, true, nil, nil -- success, running (финал — событие оружейной атаки)
end

-- ============================================================
-- v0.8.25 (тикет 05): bonus_action через честный каст-пайплайн.
    -- v1 = ТОЛЬКО offhand_attack: отдельный оружейный стат OffhandAttack
    -- (опции CastOffhand в SpellCastOptions этой версии игры не существует), игра
    -- списывает BonusActionPoint НАЦИВНО (стенд: снапшот BA −1). Остальные
    -- action_type из enum схемы — not_supported (drink_potion/help/shove/
    -- disengage/dash/dodge — реализация позже).
-- ============================================================
local BONUS_ACTIONS_V1 = {
    offhand_attack = true,
}

local function executeBonusAction(action)
    local data = action.data
    local actionType = data.action_type
    if actionType == nil or actionType == "" then
        return false, nil, "action_failed", "bonus_action requires action_type"
    end
    if not BONUS_ACTIONS_V1[actionType] then
        return false, nil, "not_supported",
            "bonus_action '" .. tostring(actionType)
            .. "' не реализован в v0.8.25 (доступно: offhand_attack)"
    end

    local actor = resolveCombatActor(data.actor)
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the bonus action actor"
    end
    if target == nil then
        return false, nil, "action_failed", "Bonus attack target not found"
    end

    -- v0.8.25: оффхенд-атака возможна ТОЛЬКО с оружием во второй руке — без него
    -- игры не выдаёт спелл OffhandAttack, а честный каст «подвисает» на running
    -- без события финализации (стенд: Tav без оффхенда). Проверяем заранее.
    local offhandKnown = false
    for _, sid in ipairs({ "OffhandAttack", "Projectile_OffhandAttack", "Target_OffhandAttack" }) do
        local hOK, hRes = pcall(Osi.HasSpell, actor, sid)
        if hOK and tostring(hRes) == "1" then
            offhandKnown = true
            break
        end
    end
    if not offhandKnown then
        return false, nil, "action_failed",
            "offhand_attack requires a light weapon in the off-hand (no OffhandAttack spell known)"
    end

    -- Прерываем активное движение (бонусная атака и движение не пересекаются).
    cancelActiveMove("Движение прервано bonus_action", action.id)
    -- v0.8.24: снапшот ресурсов до действия (критерий честной экономики 05).
    pcall(writeResourceSnapshot, action.id, actor, "before")

    -- Оффхенд-атака: ОТДЕЛЬНЫЙ оружейный стат OffhandAttack (Target_/Projectile_),
    -- а не MainHandAttack с флагом. Опции CastOffhand в SpellCastOptions этой версии
    -- игры НЕТ (валидные: IgnoreHasSpell..AvoidDangerousAuras) — попытка вставить её
    -- валит весь маппинг запроса ("not a valid 'SpellCastOptions' bitfield value").
    local bonusCandidates = {
        "OffhandAttack", "Projectile_OffhandAttack", "Target_OffhandAttack",
        "MeleeOffHandWeaponAttack", "RangedOffHandWeaponAttack",
    }
    local knownNames = {}
    local knownAdded = {}
    for _, sid in ipairs(bonusCandidates) do
        if Osi and Osi.HasSpell then
            local hOK, hRes = pcall(Osi.HasSpell, actor, sid)
            if hOK and tostring(hRes) == "1" and not knownAdded[sid] then
                knownNames[#knownNames + 1] = sid
                knownAdded[sid] = true
            end
        end
    end
    for _, sid in ipairs(bonusCandidates) do
        if not knownAdded[sid] then
            knownNames[#knownNames + 1] = sid
        end
    end

    local ok, err
    local honestUsed = false
    local usedSid
    local legacyNow = useLegacyNow()

    -- Честный путь: ServerCastRequest + bonusAction=true ("CastOffhand" в CastOptions).
    if not legacyNow then
        for _, sid in ipairs(knownNames) do
            if not honestUsed then
                local stOK, stRes = pcall(function() return Ext.Stats.Get(sid) end)
                local sType = "Target"
                if stOK and stRes and stRes.SpellType then
                    sType = stRes.SpellType
                end
                local enqOK, enqRes, enqErr = pcall(function()
                    return enqueueCastRequest(actor, sid, target, nil, nil, nil, sType, false, nil, false, true)
                end)
                if enqOK and enqRes == true then
                    honestUsed = true
                    usedSid = sid
                    ok = true
                    pipelineSucceeded()
                end
            end
        end
    end

    -- Fallback 1: Osi.UseSpell (гибрид 03 — сбой честного пути инкрементит счётчик).
    if not honestUsed then
        if not legacyNow then
            pipelineFailed("bonus_offhand")
        end
        for _, sid in ipairs(knownNames) do
            if not ok then
                ok, err = pcall(Osi.UseSpell, actor, sid, target)
                if ok then
                    usedSid = sid
                end
            end
        end
    end

    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    -- Финализация: pendingCasts → событие CastedSpell/CastSpellFailed (как у атаки).
    pendingCasts[#pendingCasts + 1] = { id = action.id, spell = usedSid or "MainHandAttack", caster = actor }
    return true, true, nil, nil -- success, running (финал — событие оружейной атаки)
end

-- ============================================================
-- Exploration (тикет 08): interact / loot / rest / travel / screen / mode.
-- Долгие жесты — running:true, финал через следующий state (Канал B) или
-- игровые события (Rest). Точный BG3-эффект приходит отдельным state от мода.
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
    finalizeRest(false, "Отдых прерван/отменён")
end)

Ext.Osiris.RegisterListener("LongRestStartFailed", 0, "after", function()
    finalizeRest(false, "Отдых не начался (нет лагеря/припасов)")
end)

local function executeInteract(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the interaction actor"
    end
    if target == nil then
        return false, nil, "action_failed", "Interaction target not found"
    end

    -- РњРёСЂРЅРѕРµ РІР·Р°РёРјРѕРґРµР№СЃС‚РІРёРµ СЃ РѕР±СЉРµРєС‚РѕРј (§8 research): useItem=0, isInteraction=1.
    cancelActiveMove("Движение прервано взаимодействием", action.id)
    local ok, err = pcall(Osi.Use, actor, target, 0, 1, "")
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    return true, true, nil, nil -- success, running (исход — следующий state)
end

local function executeLoot(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the looter"
    end
    if target == nil then
        return false, nil, "action_failed", "Loot target not found"
    end

    -- Серверный автоподбор: MoveAllLootableItemsTo(from, to, equipArmor=0, equipWeapons=0,
    -- clrOwner=1, vanityClothing=0). UI-вариант (OpenCharacterLootUI) — client-часть.
    cancelActiveMove("Движение прервано сбором добычи", action.id)
    local ok, err = pcall(Osi.MoveAllLootableItemsTo, target, actor, 0, 0, 1, 0)
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    return true, true, nil, nil -- success, running (состав добычи — следующий state)
end

local function executeRest(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the resting actor"
    end

    -- РџРѕР»РЅС‹Р№ РѕС‚РґС‹С… вЂ” Osi.RequestLongRest (research §9) + РіРµР№С‚ CanAllPartiesLongRest (C#-РІР°Р»РёРґР°С‚РѕСЂ).
    -- Частичный (лёгкий) отдых публичной Osiris-функции не имеет (story-side).
    if data.rest_type ~= "full" then
        -- TODO(client): лёгкий отдых — UI-кнопка Take Short Rest; структурный ack, финал — state.
        return true, true, nil, nil
    end

    local ok, err = pcall(Osi.RequestLongRest, actor, 0)
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    activeRest = { id = action.id }
    return true, true, nil, nil -- success, running (финал — LongRestFinished/Cancelled/Failed)
end

local function executeTravel(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    if actor == nil then
        return false, nil, "action_failed", "Could not resolve the traveler"
    end

    -- РџСѓР±Р»РёС‡РЅРѕРіРѕ fast-travel Osiris-РІС‹Р·РѕРІР° РІ research РЅРµС‚ (§0/§15): СЃС‚СЂСѓРєС‚СѓСЂРЅС‹Р№ ack.
    -- TODO(game): кандидат — телепорт к waypoint-маркеру региона (Osi.TeleportTo/Position);
    -- фактический переезд области придёт отдельным state от mod-генератора (Канал B).
    return true, true, nil, nil -- success, running (перенос региона — следующий state)
end

local function executeOpenScreen(action)
    -- open_map / open_inventory — только просмотр (UI), движок сам откроет экран.
    -- v0.8.26: переключаем currentScreen и сразу отдаём состояние экрана мод-генератором.
    if action.name == "open_map" then
        currentScreen = "map"
    elseif action.name == "open_inventory" then
        currentScreen = "inventory"
    end
    cancelActiveMove("Движение прервано открытием экрана", action.id)
    pcall(captureCurrentState, "screen_" .. tostring(currentScreen), true)
    return true, true, nil, nil -- success, running (экран — следующий state)
end

local function executeToggleMode(action)
    -- toggle_mode: v1 принимает только "normal" (X3, stealth убран) — C# уже отсек иное.
    -- Р РµР¶РёРј normal вЂ” РїРѕРґС‚РІРµСЂР¶РґРµРЅРёРµ Р±РµР· РёРіСЂРѕРІРѕРіРѕ РІС‹Р·РѕРІР°, РјРіРЅРѕРІРµРЅРЅС‹Р№ С„РёРЅР°Р».
    -- v0.8.26: режим normal возвращает экран exploration в состоянии
    currentScreen = "exploration"
    pcall(captureCurrentState, "toggle_normal", true)
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
    -- Действия-делегаты (attack_entity/cast_spell/move_to_target и пр.) читают
    -- action.data как таблицу; раньше здесь оставалась строка JSON, и
    -- data.actor/... давал nil. Подменяем action.data распарсенной таблицей.
    action.data = data

    -- v0.8.26: любой экшн кроме открытия экрана возвращает currentScreen из
    -- map/inventory в exploration (закрытие экранов сервер не наблюдает —
    -- состояние режима держит только открытие через open_map/open_inventory).
    if name ~= "open_map" and name ~= "open_inventory" then
        currentScreen = "exploration"
    end

    if name == "end_turn" then
        -- v0.7.3: двухфазный end_turn с самопроверкой реального эффекта.
        -- Ход — движковый (story лишь наблюдает TurnStarted/TurnEnded), поэтому
        -- success здесь НЕ значит "ход сменился": финал через ~1.2с сообщает
        -- ended:true/false по факту наступления TurnEnded(actor) или TurnStarted
        -- другого персонажа. Если C# не знает актуальный GUID — story-латч.
        local raw = resolveActingCharacter(data.actor or "")
        local acting = resolveEndTurnActor(data.actor or "")
        _P("[BG3Neuro] end_turn: explicit=" .. tostring(data.actor or "")
            .. " resolved=" .. tostring(acting)
            .. " raw=" .. tostring(raw)
            .. " latch=" .. tostring(actingChar)
            .. " mode=" .. tostring(data.mode or "end"))
        if acting == nil or acting == "" then
            return false, nil, "action_failed", "Could not determine the acting character"
        end

        local marker = #turnLog
        local actingBefore = actingChar
        -- end_turn прерывает незавершённое движение: иначе EndTurn ждёт
        -- движения и ход не переключается (ended=false). Движение уже
        -- завершилось событием CharacterMoveToFinished — activeMove null, no-op.
        cancelActiveMove("Ход завершён, движение прервано", action.id)
        -- v0.8.13: передаём id, который Ext.Entity.Get находит (prefixed), а не
        -- чистый guid: чистый ("c7c13742-...") Ext.Entity.Get НЕ находит, и тогда
        -- флаг RequestedEndTurn не выставится и очередь EndTurn не пушится.
        local okE, errE = requestEngineEndTurn(endTurnEntityId(raw, acting))
        if not okE then
            return false, nil, "action_failed", tostring(errE)
        end

        -- Финал — событийная самопроверка (TurnEnded/TurnStarted) + fallback-таймер.
        armEndTurn({ id = action.id, acting = acting, actingBefore = actingBefore, marker = marker })

        return true, true, nil, nil -- success, running (финал — verifyEndTurn)
    end

    if name == "end_turn_ecs" then
        -- v0.7.5: движковый канал конца хода.
        --  mode "probe"  — только чтение;
        --  mode "ecs"    — флаг RequestedEndTurn (v0.7.4, доказан no-op);
        --  mode "system" (по умолчанию) — пуш combat-сущности в очередь
        --    Ext.System.ServerTurnOrder.EndTurn (esv::TurnOrderSystem::EndTurn,
        --    Array<EntityHandle>) — тот же канал, что и клиентское
        --    NETMSG_TURNBASED_ENDTURN_REQUEST; обрабатывается системой движка
        --    каждый кадр. Флаг тоже ставим (весь стек клиента).
        local raw = resolveActingCharacter(data.actor or "")
        local acting = resolveEndTurnActor(data.actor or "")
        local mode = data.mode or "system"
        local onlyProbe = mode == "probe"
        if acting == nil or acting == "" then
            return false, nil, "action_failed", "Could not determine the acting character"
        end
        local before = entityTurnComponentDump(raw)
        local marker = #turnLog
        local actingBefore = actingChar
        local payload = { actor = acting, mode = mode, before = before }
        if not onlyProbe then
            local stepOk, stepErr = pcall(function()
                local okE, ent = pcall(Ext.Entity.Get, raw)
                if okE and ent ~= nil then
                    local okC, comp = pcall(function() return ent:GetComponent("TurnBased") end)
                    if okC and comp ~= nil then
                        -- флаг конца хода активного персонажа
local okW1, errW1 = pcall(function() comp.RequestedEndTurn = true end)
                        payload.write_requested = okW1 and true or false
                        payload.write_error = okW1 and nil or tostring(errW1)
                        -- combat-сущность из компонента персонажа
                        local combatGuid = nil
                        pcall(function() combatGuid = comp.CombatTeam or comp.Combat end)
                        payload.combat_guid = combatGuid
                        if mode ~= "ecs" and combatGuid ~= nil then
                            -- канал turn-order system: очередь EndTurn (combat entity)
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
                                payload.queue_push_error = "Ext.System.ServerTurnOrder.EndTurn not found"
                            end
                        end
                    else
                        payload.write_requested = false
                        payload.write_error = "no TurnBased component"
                    end
                else
                    payload.write_error = "entity not found"
                end
                -- дополнительно пробуем story-канал (в BG3 он no-op, но дёшев)
                pcall(Osi.EndTurn, raw)
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
        return true, true, nil, nil -- финал — verifyEcsEndTurn
    end

    if name == "diag_skip" then
        -- Диагностика механизма DB_CharacterSkipTurn (v0.7.3): добавить строку,
        -- посмотреть, вызывает ли story EndTurn на ближайшем TurnStarted, и снять
        -- строку обратно (чтобы не ломать будущие ходы игрока).
        local acting = resolveActingCharacter(data.actor or "")
        if acting == nil or acting == "" then
            return false, nil, "action_failed", "Could not determine the acting character"
        end
        local payload = { actor = acting }
        local okAdd, errAdd = pcall(Osi.DB_CharacterSkipTurn, acting)
        payload.row_added = okAdd and true or false
        payload.row_add_error = okAdd and nil or tostring(errAdd)
        payload.rows_after_add = dbRowsRead("CharacterSkipTurn", 1)
        -- снять строку сразу (диагностика не должна менять геймплей)
        local okDel, errDel = pcall(function() return Osi.DB_CharacterSkipTurn:Delete(acting) end)
        payload.row_deleted = okDel and true or false
        payload.row_del_error = okDel and nil or tostring(errDel)
        payload.rows_after_del = dbRowsRead("CharacterSkipTurn", 1)
        _P("[BG3Neuro] diag_skip: " .. Ext.Json.Stringify(payload))
        return true, nil, nil, nil, { diag = payload }
    end

    if name == "probe" then
        -- Диагностика (не для прода): кто ходит, кто в бою, skip/GEN флаги.
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

    if name == "stats_probe" then
        -- Диагностика (не для прода): интроспекция компонентов участников боя
        -- для проверки пути statSlug. Дёргается через neuro_to_bg3.json:
        --   { "id": "stats_probe", "name": "stats_probe", "data": "{}" }
        local okP, p = pcall(probeCombatStats)
        if not okP then
            p = { probe_error = tostring(p) }
        end
        _P("[BG3Neuro] stats_probe: guids=" .. #(p.guids or {}))
        return true, nil, nil, nil, { debug = p }
    end

    if name == "state_capture" then
        -- StateExtractor (v0.8.26): принудительный state прямо сейчас; режим выбирает
        -- captureCurrentState (диалог > комбат > exploration), результат — в bg3_to_neuro.json.
        local okC, p = pcall(captureCurrentState, "state_capture", true)
        if okC then
            _P("[BG3Neuro] state_capture: mode=" .. tostring(p.mode)
                .. " allies=" .. #(p.allies or {}) .. " enemies=" .. #(p.enemies or {})
                .. " objects=" .. #(p.objects or {}) .. " spells=" .. #(p.spells or {}))
            return true, nil, nil, nil, {
                version = p.version,
                mode = p.mode,
                trigger = p.trigger,
                turn_actor = p.turn_actor or "",
                allies = #(p.allies or {}),
                enemies = #(p.enemies or {}),
                objects = #(p.objects or {}),
                regions = #(p.regions or {}),
                inventory = #(p.inventory or {}),
                spells = #(p.spells or {}),
                dialogue = (p.dialogue ~= nil and #(p.dialogue.options or {})) or -1,
                can_rest = p.can_rest == true,
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

    if name == "bonus_action" then
        -- v0.8.25 (тикет 05): bonus_action → offhand_attack (v1), остальные — позже.
        return executeBonusAction(action)
    end

    if name == "q_cast" or name == "q_sys" then
        -- v0.8.18: снимок ВСЕХ очередей CastRequestSystem.
        local qInfo = { id = action.id or name }
        local queues = readCastQueues()
        if queues.error then
            return { id = qInfo.id, running = false, success = false, error_detail = queues.error }
        end
        qInfo.queues = queues
        local resp = { id = qInfo.id, running = false, success = true, info = qInfo }
        return resp
    end

    if name == "q_capture" then
        -- v0.8.18+: дамп живых каст-сущностей (ground truth для сравнения с синтетикой).
        local cap = dumpCastEntities(action.id or "q_capture")
        return { id = action.id or name, running = false, success = true, captures = cap }
    end

    if name == "select_dialogue_option" then
        return executeDialogueOption(action)
    end

    if name == "move_to_entity" then
        -- Перемещение к объекту/существу в исследовании — тот же массовый путь, что move_to_target
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

    -- Остальные действия тикеты 03/04 не исполняют (валидация уже прошла на C#; исполнение — позже).
    return false, nil, "not_supported", "Action '" .. name .. "' is not supported by the mod in v1"
end

local function clearInFlight()
    -- Рестарт мода/игры (тикет 09, R7): обнуляем neuro_to_bg3.json, чтобы не
    -- исполнить действие погибшего стэнда. SaveFile("") вместо удаления — LoadFile
    -- вернёт "" и readInFlightAction() отклонит его как нет действия.
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
        -- Исключение Lua в обработчике: сохраняем НАСТОЯЩЕЕ сообщение ошибки,
        -- а не tostring(false) (баг v0.7.4 — терял текст ошибки).
        local errMsg = tostring(success)
        success = false
        running = nil
        errorCode = "action_failed"
        errorDetail = errMsg
        extra = nil
    end
    -- Очищаем in-flight СРАЗУ после чтения текущего действия: одношаговые действия
    -- (success без running) больше не должны переисполняться каждые 200 мс, а финал
    -- длинных действий приходит по игровому событию, а не из файла (R7).
    clearInFlight()
    writeResult(action.id, success, running, errorCode, errorDetail, extra)
    Ext.Timer.WaitForRealtime(ACTION_POLL_MS, pollActions)
end

local lastExploreMode = nil
local lastExploreJson = nil

local function stripGeneratedAt(state)
    -- Фингерпринт без метки времени: иначе каждый тик (nowIso в buildExplorationState)
    -- даёт новый JSON и дедуп никогда не срабатывает.
    local res = {}
    for k, v in pairs(state) do
        if k ~= "generated_at" then
            res[k] = v
        end
    end
    return res
end

local function exploreLoop()
    -- v0.8.26: тик состояния вне боя. Комбат пишет TurnStarted, диалог — DialogStarted;
    -- здесь — exploration (и наблюдение за сменой режима). Запись обязательна при СМЕНЕ
    -- режима (иначе выход из combat/dialogue с неизменным содержимым застрял бы на
    -- старом mode в файле), в остальном — только при изменении содержимого (фингерпринт).
    local acting = resolveActingCharacter("")
    local mode = currentMode(acting)
    local modeChanged = lastExploreMode ~= mode
    if modeChanged then
        _P("[BG3Neuro] state: mode=" .. tostring(mode))
        lastExploreMode = mode
    end
    if mode ~= "combat" and mode ~= "dialogue" then
        local okB, state = pcall(buildExplorationState, "free_roam")
        if okB and state ~= nil then
            local okJ, json = pcall(function() return Ext.Json.Stringify(stripGeneratedAt(state)) end)
            if okJ and (modeChanged or json ~= lastExploreJson) then
                writeStateFile(state)
                lastExploreJson = json
            end
        end
    end
    Ext.Timer.WaitForRealtime(EXPLORE_PERIOD_MS, exploreLoop)
end

clearInFlight()
writeInitialState()
startHeartbeatLoop()
pollActions()
exploreLoop()
_P("[BG3Neuro] file IPC bridge up: " .. HEARTBEAT_FILE)