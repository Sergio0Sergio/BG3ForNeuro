-- BG3Neuro v0.7.0 — файловый IPC-мост (тикеты 01 + 03-09)
-- Задача: heartbeat 2s + стартовый state-файл + исполнение действий из action_*.json.
-- Действия: end_turn (03), move_to_target / attack_entity (04), cast_spell (05),
--           select_dialogue_option (07, client-контекст), exploration (08:
--           move_to_entity / interact_with / loot / rest / travel_to /
--           open_map / open_inventory / toggle_mode) — длинные действия
-- с двухфазным running:true (промежуточный ack) и финалом по игровому событию.
-- Dumb-модуль: только состояние и исполнение, без логики решений (решение — в C#).
-- Директория IPC: <BG3ScriptExtender appdata>/BG3Neuro (Ext.IO пишет относительно Script Extender).

local MOD_NAME = "BG3Neuro"
local MOD_VERSION = "0.7.0"
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

local function writeResult(actionId, success, running, errorCode, errorDetail)
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
    local path = RESULT_DIR .. "/result_" .. actionId .. ".json"
    local ok, err = pcall(Ext.IO.SaveFile, path, Ext.Json.Stringify(payload))
    if not ok then
        _P("[BG3Neuro] write result " .. actionId .. ": " .. tostring(err))
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

-- ============================================================
-- Совместный пайплайн каста/атаки (§6.4): ServerCastRequest.
-- Для игроков CastOptions {"FromClient", ...} → ресурсы/кулдауны
-- считает сама игра. Fallback — Osi.UseSpell(AtPosition).
-- ============================================================

local pendingCasts = {} -- { id = action.id, spell = name, caster = uuid }

local function enqueueCastRequest(actorUuid, spellName, targetUuid, posX, posY, posZ, spellType)
    if Ext == nil or Ext.System == nil or Ext.System.ServerCastRequest == nil then
        return nil, "ServerCastRequest недоступен на этой сборке BG3SE"
    end

    local casterEntity = Ext.Entity.Get(actorUuid)
    if casterEntity == nil then
        return nil, "Не удалось получить сущность кастера"
    end

    local targets = {}
    if targetUuid and targetUuid ~= "" then
        local targetEntity = Ext.Entity.Get(targetUuid)
        if targetEntity == nil then
            return nil, "Не удалось получить сущность цели"
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

-- Финал каста по игровым событиям (долгие/канальные заклинания): running:false.
-- Если событие не пришло — правда всё равно уходит через следующий state (Канал B).
local function finalizeCast(caster, spellName, cancelled)
    for i = 1, #pendingCasts do
        local pc = pendingCasts[i]
        if pc.caster == caster and pc.spell == spellName then
            table.remove(pendingCasts, i)
            writeResult(pc.id, true, false, cancelled and "cast_failed" or nil,
                cancelled and "Каст прерван/провален" or nil)
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
        return false, nil, "action_failed", "Не удалось определить исполнителя каста"
    end
    if spellName == nil or spellName == "" then
        return false, nil, "action_failed", "spell_name обязателен"
    end

    -- Прерываем активное движение (каст и движение не пересекаются)
    cancelActiveMove("Движение прервано кастом", action.id)

    local stats = Ext.Stats.Get(spellName) -- prototype-имя (X5-нормализация в StateExtractor)
    local spellType = stats and stats.SpellType or "Object"
    local target = resolveEntity(data.target_id or "")
    local pos = data.position

    local ok, err = enqueueCastRequest(actor, spellName, target, pos and pos.x, pos and pos.y, pos and pos.z, spellType)
    if not ok then
        -- Fallback: копьё подальше от pipeline, честных AP не гарантирует
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
    return true, true, nil, nil -- success, running (финал — событие CastedSpell/CastSpellFailed)
end

-- ============================================================
-- Диалог (тикет 07): select_dialogue_option через client-клик.
-- Server не умеет публично выбирать вариант (research §7.2, нет PickDialogNode);
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
end)

Ext.Osiris.RegisterListener("DialogEnded", 2, "after", function(dialog, instanceID)
    finalizeDialogueOption(dialog)
end)

local function executeDialogueOption(action)
    local data = action.data
    local index = data.option_index
    if index == nil then
        return false, nil, "not_supported", "option_index обязателен"
    end

    -- Кнопка диалога находится в клиентском UI (Noesis); клик — только из client-контекста.
    if Ext == nil or Ext.UI == nil then
        return false, nil, "not_supported",
            "ClientAutoselectExecutor недоступен: нет client-контекста для подсветки и клика варианта"
    end

    -- Долгий ход: клик происходит в UI, итог — событие DialogEnded/DialogClosed.
    pendingDialogue[#pendingDialogue + 1] = { id = action.id, dialog = "(unknown)" }
    -- TODO(client): Ext.UI.NeedMouse / эмуляция клика по UI-элементу option_index, подсветка перед кликом;
    -- сюда — реальный диалоговый дескриптор для матчинга DialogEnded.
    return true, true, nil, nil -- success, running (финал — DialogEnded)
end

local function executeMoveToTarget(action)
    local data = action.data
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Не удалось определить исполнителя движения"
    end
    if target == nil and not data.position then
        return false, nil, "action_failed", "Цель движения не найдена"
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
    local actor = resolveEntity(data.actor or "")
    local target = resolveEntity(data.target_id or "")
    if actor == nil then
        return false, nil, "action_failed", "Не удалось определить исполнителя атаки"
    end
    if target == nil then
        return false, nil, "action_failed", "Цель атаки не найдена"
    end

    -- Прерываем активное движение (движение и атака не пересекаются)
    cancelActiveMove("Движение прервано атакой", action.id)

    -- §6.4: party-атаки через ServerCastRequest с оружейным заклинанием уровня
    -- Target_WeaponRange внедряется вместе с каст-машинерией (следующий такт);
    -- здесь — документированный fallback Osi.Attack (one-shot). alwaysHit=0 → бросок.
    local ok, err = pcall(Osi.Attack, actor, target, 0)
    if not ok then
        return false, nil, "action_failed", tostring(err)
    end

    return true, true, nil, nil -- success, running (финал — событие атаки/следующий state)
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
        return false, nil, "action_failed", "Не удалось определить исполнителя взаимодействия"
    end
    if target == nil then
        return false, nil, "action_failed", "Цель взаимодействия не найдена"
    end

    -- Мирное взаимодействие с объектом (§8 research): useItem=0, isInteraction=1.
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
        return false, nil, "action_failed", "Не удалось определить исполнителя лута"
    end
    if target == nil then
        return false, nil, "action_failed", "Цель лута не найдена"
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
        return false, nil, "action_failed", "Не удалось определить исполнителя отдыха"
    end

    -- Полный отдых — Osi.RequestLongRest (research §9) + гейт CanAllPartiesLongRest (C#-валидатор).
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
        return false, nil, "action_failed", "Не удалось определить исполнителя путешествия"
    end

    -- Публичного fast-travel Osiris-вызова в research нет (§0/§15): структурный ack.
    -- TODO(game): кандидат — телепорт к waypoint-маркеру региона (Osi.TeleportTo/Position);
    -- фактический переезд области придёт отдельным state от mod-генератора (Канал B).
    return true, true, nil, nil -- success, running (перенос региона — следующий state)
end

local function executeOpenScreen(action)
    -- open_map / open_inventory — только просмотр (UI), движок сам откроет экран.
    -- TODO(client): открытие экрана через клиентский ввод; state экрана даёт mod-генератор.
    cancelActiveMove("Движение прервано открытием экрана", action.id)
    return true, true, nil, nil -- success, running (экран — следующий state)
end

local function executeToggleMode(action)
    -- toggle_mode: v1 принимает только "normal" (X3, stealth убран) — C# уже отсек иное.
    -- Режим normal — подтверждение без игрового вызова, мгновенный финал.
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
        -- Ход завершается у текущего активного персонажа (следующий ход продвигает движок)
        local ok, err = pcall(Osi.EndTurn, data.actor or "")
        if not ok then
            return false, nil, "action_failed", tostring(err)
        end
        -- Результат исполнения BG3 покажет в обновлённом state; для end_turn нет ошибки валидации.
        return true, nil, nil, nil
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
    return false, nil, "not_supported", "Действие '" .. name .. "' не поддерживается модом в v1"
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

    local success, running, errorCode, errorDetail = executeAction(action)
    writeResult(action.id, success, running, errorCode, errorDetail)
    Ext.Timer.WaitForRealtime(ACTION_POLL_MS, pollActions)
end

clearInFlight()
writeInitialState()
startHeartbeatLoop()
pollActions()
_P("[BG3Neuro] файловый IPC-мост поднят: " .. HEARTBEAT_FILE)