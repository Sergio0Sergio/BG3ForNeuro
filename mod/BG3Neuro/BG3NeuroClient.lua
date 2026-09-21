-- BG3NeuroClient.lua v0.8.58 — клиентская половина мода (тикеты bg3-neuro-dialogue-click, 25).
-- Живёт в клиентском контексте (Ext.UI / Noesis), грузится через BootstrapClient.lua.
-- Задачи:
--   1) снапшот вариантов диалога (line + options) для сервера по NetChannel
--      "BG3NeuroDialogue" (тот же module+channel, что в серверном BG3Neuro.lua);
--   2) реальный клик по выбранному варианту через Noesis (ICommand:Execute()).
--   v0.8.58 (тикет 25): лёгкий отдых — канал "BG3NeuroRest": скан UI (rest_probe)
--      и клик по кнопке Take Short Rest (меню лагеря открываем программно).
-- Клик-механика (research 01 + UI.inl): вариант — Button-подобный элемент с Command
-- (Noesis::BaseCommand:CanExecute/Execute). Порядок candidates = порядок обхода
-- UI-дерева = UI-порядок (option_index 1-based). Поиск по option_index, при
-- расхождении текста — фолбэк по option_text (тикет 02, Q2=б).
-- Никакой записи в IPC-файлы: состояние пишет только серверная половина (Q3=а).

local DIALOGUE_CHANNEL = "BG3NeuroDialogue"
local OPTION_DEPTH_CAP = 12
_G["BG3Neuro_VERSION"] = "0.8.58" -- экспорт для BootstrapClient.lua (правдивый лог загрузки)
local MAX_VISITED = 3000
local DIALOGUE_HINTS = { "dialog", "dialogue", "conversation" }
local NON_DIALOGUE_HINTS = { "hotbar", "actionbar", "toolbar", "minimap", "tooltip",
    "inventory", "container", "charactersheet", "journal", "book", "radial", "map" }

local bridge = nil
local bridgeReady = false
local lastClickFrame = nil        -- защита от повторных кликов по одному сообщению

local function log(...)
    _P("[BG3NeuroClient] " .. string.format(...))
end

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then
        return r
    end
    return nil
end

local function elType(el)
    if el == nil or (type(el) ~= "userdata" and type(el) ~= "table") then
        return nil
    end
    return safe(function() return tostring(el.Type) end)
end

local function elProp(el, name)
    if el == nil then
        return nil
    end
    return safe(function() return el:GetProperty(name) end)
end

local function elText(el)
    local t = elProp(el, "Text")
    if t == nil then
        return nil
    end
    local s = tostring(t)
    if s == "" then
        return nil
    end
    return s
end

local function hasCommand(el)
    return elProp(el, "Command") ~= nil
end

local function isButtonish(typ)
    return typ ~= nil and string.find(string.lower(typ), "button") ~= nil
end

local function hintsMatch(hay, hints)
    hay = string.lower(hay or "")
    for _, hint in ipairs(hints) do
        if string.find(hay, hint) ~= nil then
            return true
        end
    end
    return false
end

-- SE Array (ArrayProxy): userdata с __len и 1-based __index.
local function arrLen(a)
    if a == nil then
        return 0
    end
    if type(a) == "table" then
        return #a
    end
    return safe(function() return tonumber(#a) end) or 0
end

local function arrGet(a, i)
    if a == nil then
        return nil
    end
    return safe(function() return a[i] end)
end

local function fileName(el)
    return safe(function() return tostring(el.FileName) end)
end

-- Обход поддерева в глубину (pre-order = визуальный порядок, верх→низ).
-- Использует FrameworkElement.Child; при пустом — фолбэк Visual.VisualChild.
local function walk(el, depth, visited, cb)
    if el == nil or depth > OPTION_DEPTH_CAP or visited[el] then
        return
    end
    visited[el] = true
    cb(el, depth)

    local cnt = nil
    if (type(el) == "userdata" or type(el) == "table") then
        -- Логические дети (XAML tree) и визуальные дети (виджеты/оверлеи) —
        -- оба являются валидными детьми, берём максимум.
        cnt = safe(function() return tonumber(el.ChildrenCount) end) or 0
        local vcnt = safe(function() return tonumber(el.VisualChildrenCount) end) or 0
        if vcnt > cnt then
            cnt = vcnt
        end
    else
        cnt = 0
    end

    -- Child/VisualChild принимают 1-based индекс (используем 1-based j)
    for j = 1, cnt do
        local ch = safe(function() return el:Child(j) end)
        if ch == nil and j <= (safe(function() return tonumber(el.VisualChildrenCount) end) or 0) then
            ch = safe(function() return el:VisualChild(j) end)
        end
        if ch ~= nil then
            if #visited > MAX_VISITED then
                return
            end
            walk(ch, depth + 1, visited, cb)
        end
    end

    -- ContentControl/UserControl прячет контент в свойстве Content (не в детях).
    if cnt == 0 then
        local content = safe(function() return el.Content end)
        if content ~= nil and content ~= el then
            if #visited > MAX_VISITED then
                return
            end
            walk(content, depth + 1, visited, cb)
        end
        -- ItemsControl — варианты во Items
        local items = safe(function() return el.Items end)
        local n = arrLen(items)
        if n > 0 then
            for i = 1, n do
                local it = arrGet(items, i)
                if it ~= nil then
                    if #visited > MAX_VISITED then
                        return
                    end
                    walk(it, depth + 1, visited, cb)
                end
            end
        end
    end
end

-- Кандидаты-корни: активные виджеты UI (со state machine) или корень всего дерева.
local function collectRoots()
    local roots = {}

    local sm = safe(function() return Ext.UI.GetStateMachine() end)
    if sm ~= nil then
        local state = safe(function() return sm.State end)
        if state ~= nil then
            local widgets = safe(function() return state.Widgets end)
            local n = arrLen(widgets)
            for i = 1, n do
                local w = arrGet(widgets, i)
                if w ~= nil then
                    roots[#roots + 1] = w
                end
            end
            -- StateWidgets — коллекция UIElement'ов активного состояния, тоже валидные корни
            local stateWidgets = safe(function() return state.StateWidgets end)
            local m = arrLen(stateWidgets)
            for i = 1, m do
                local w = arrGet(stateWidgets, i)
                if w ~= nil then
                    roots[#roots + 1] = w
                end
            end
        end
    end

    if #roots == 0 then
        local root = safe(function() return Ext.UI.GetRoot() end)
        if root ~= nil then
            roots[1] = root
        end
    end
    return roots
end

-- Извлечение вариантов из виджета DCDialogue: активный диалог — тот, у которого
-- Answers непустой. line = текст текущей фразы NPC (BodyText активного диалога).
-- Возвращает (candidates, line), candidates[i].el = элемент ответа (BaseComponent).
local function extractFromDialogueWidget(w)
    local data = safe(function() return w.Data end)
    if data == nil then
        return {}, nil
    end
    local dialogues = safe(function() return data.Dialogues end)
    local dn = arrLen(dialogues)
    for i = 1, dn do
        local d = arrGet(dialogues, i)
        if d ~= nil then
            local answers = safe(function() return d.Answers end)
            local an = arrLen(answers)
            if an > 0 then
                local line = safe(function() return tostring(d.BodyText) end)
                if line == nil or line == "" then
                    line = nil
                end
                local cands = {}
                for j = 1, an do
                    local a = arrGet(answers, j)
                    if a ~= nil then
                        local text = safe(function() return tostring(a.BodyText) end)
                        cands[#cands + 1] = { el = a, widget = w, text = text }
                    end
                end
                return cands, line
            end
        end
    end
    return {}, nil
end

-- Собирает candidates и line внутри root. Приоритет — DCDialogue (Data.Dialogues);
-- фолбэк для прочих виджетов — кнопки Button+Command в дереве.
local function collectFromRoot(root)
    local candidates = {}
    local line = nil
    local dcd = {}
    local visited = {}
    walk(root, 0, visited, function(el, depth)
        local typ = elType(el)
        if typ ~= nil and string.find(string.lower(typ), "dcdialogue") ~= nil then
            dcd[#dcd + 1] = el
        end
        if isButtonish(typ) and hasCommand(el) then
            candidates[#candidates + 1] = { el = el, text = elText(el) }
        end
        if line == nil and depth <= 1 and elText(el) ~= nil
            and string.find(string.lower(typ or ""), "textblock") ~= nil then
            line = elText(el)
        end
    end)

    -- Если нашли DCDialogue — берём его варианты вместо кнопок-фолбэка.
    for _, w in ipairs(dcd) do
        local cands, dline = extractFromDialogueWidget(w)
        if #cands > 0 then
            candidates = cands
            line = dline
            break
        end
    end

    -- line не должен совпадать с текстом варианта
    for _, c in ipairs(candidates) do
        if c.text ~= nil and line ~= nil and c.text == line then
            line = nil
            break
        end
    end
    return candidates, line
end

-- Выбор «диалогового» корня: сначала виджет с диалоговым FileName/типом, иначе —
-- корень с максимальным числом вариантов, исключая явно недиалоговые виджеты.
local function collectDialogue()
    local roots = collectRoots()
    if #roots == 0 then
        return {}, nil, "no ui roots"
    end

    local scored = {}  -- { root, candidates, line, dialogish, dirty }
    for _, root in ipairs(roots) do
        local candidates, line = collectFromRoot(root)
        if #candidates > 0 then
            local f = fileName(root)
            local entry = {
                root = root,
                candidates = candidates,
                line = line,
                dialogish = hintsMatch(tostring(elType(root)) .. " " .. tostring(f), DIALOGUE_HINTS),
                dirty = hintsMatch(tostring(f), NON_DIALOGUE_HINTS),
            }
            scored[#scored + 1] = entry
        end
    end

    table.sort(scored, function(a, b)
        if a.dialogish ~= b.dialogish then
            return a.dialogish
        end
        if a.dirty ~= b.dirty then
            return not a.dirty
        end
        return #a.candidates > #b.candidates
    end)

    if #scored == 0 then
        return {}, nil, "no dialog widget with options found"
    end

    local best = scored[1]
    return best.candidates, best.line, nil
end

-- SDL-сканкоды верхнего ряда цифр: "1"=30 ... "9"=38. В BG3 опции диалога
-- выбираются этими клавишами (BoundEvent=UISelectSlotN у вариантов).
local SDL_DIGIT_SCANCODES = {
    [1] = 30, [2] = 31, [3] = 32, [4] = 33, [5] = 34,
    [6] = 35, [7] = 36, [8] = 37, [9] = 38, [10] = 39,
}

-- Клик по варианту диалога (index 1-based). Приоритет — инъекция нажатия
-- цифровой клавиши слота (настоящий пользовательский ввод). Фолбэк —
-- SelectAnswerCommand:Execute(CtxAnswer) виджета DCDialogue.
-- Вернёт (true, nil) или (false, reason).
local function clickElement(c, index)
    if c == nil or c.el == nil then
        return false, "element is nil"
    end

    -- 1) Клавиша цифры (как если бы игрок нажал 1..9)
    if index ~= nil then
        local sc = SDL_DIGIT_SCANCODES[index]
        if sc ~= nil then
            local okKey = pcall(function() Ext.Input.InjectKeyPress(sc) end)
            if okKey then
                return true, nil
            else
                log("key-inject failed: scancode=%d", sc)
            end
        end
    end

    -- 2) SelectAnswerCommand виджета DCDialogue (прямой вызов команды)
    local w = c.widget
    if w == nil then
        return false, "widget is nil"
    end
    local cmd = elProp(w, "SelectAnswerCommand")
    if cmd == nil then
        return false, "widget has no SelectAnswerCommand"
    end
    local param = elProp(c.el, "CtxAnswer")
    if param == nil then
        param = c.el
    end
    local ok = pcall(function() cmd:Execute(param) end)
    if not ok then
        return false, "SelectAnswerCommand:Execute() threw"
    end
    return true, nil
end

local function buildSnapshotReply()
    local candidates, line, reason = collectDialogue()
    local options = {}
    for i, c in ipairs(candidates) do
        if c.text ~= nil then
            options[#options + 1] = { index = i, text = c.text }
        end
    end
    if reason ~= nil then
        log("snapshot: %s", reason)
    else
        log("snapshot: options=%d line=%q", #options, tostring(line or ""))
    end
    -- speaker нигде не считываем: серверная speakerForDialog лучше (спотлайт по guid),
    -- а по сети нельзя получить display name чужой локации.
    return { kind = "bg3neuro_dialogue_snapshot_reply", ok = true, line = line, options = options }
end

-- Выполнение клика по сообщению сервера. Возвращает click_result для сервера.
local function performClick(msg)
    local index = type(msg.index) == "number" and msg.index or nil
    local expected = msg.text
    local actionId = msg.action_id

    local candidates, _, reason = collectDialogue()
    if #candidates == 0 then
        return { kind = "bg3neuro_dialogue_click_result", action_id = actionId, ok = false,
            reason = "no dialog options in UI (" .. tostring(reason) .. ")" }
    end

    local target = nil

    -- Q2=б: сначала по option_index (порядок UI), сверка текста при option_text.
    if index ~= nil and index >= 1 and index <= #candidates then
        local byIndex = candidates[index]
        if expected == nil or tostring(byIndex.text) == tostring(expected) then
            target = byIndex
        else
            log("index %d text mismatch (expected %q, got %q) — falling back to text",
                index, tostring(expected), tostring(byIndex.text or ""))
        end
    end

    -- Фолбэк по option_text.
    if target == nil and expected ~= nil then
        for _, c in ipairs(candidates) do
            if tostring(c.text) == tostring(expected) then
                target = c
                break
            end
        end
    end

    if target == nil or target.el == nil then
        return { kind = "bg3neuro_dialogue_click_result", action_id = actionId, ok = false,
            reason = "option not found (index=" .. tostring(index) .. ", text=" .. tostring(expected or "nil") .. ")" }
    end

    local ok, clickReason = clickElement(target, index)
    if not ok then
        log("click failed: %s", tostring(clickReason))
        return { kind = "bg3neuro_dialogue_click_result", action_id = actionId, ok = false,
            reason = "click failed: " .. tostring(clickReason) }
    end
    -- Q3=а: клик fire-only, без подтверждения обратно — успех сервер видит по
    -- следующему состоянию диалога (смена fingerprint снапшота). Ничего не шлём.
    log("click fired (index=%d text=%q)", index or -1, tostring(target.text or ""))
    return nil
end

-- -----------------------------------------------------------
-- NetChannel: тот же module+channel, что в серверной половине.
-- -----------------------------------------------------------
local function initBridge()
    local okC, channel = pcall(function()
        return Ext.Net.CreateChannel((ModuleUUID or "BG3Neuro"), DIALOGUE_CHANNEL)
    end)
    if not okC or channel == nil then
        log("NetChannel create failed: %s", tostring(channel))
        return
    end
    bridge = channel

    -- запрос снапшота от сервера → возвращаем варианты диалога.
    local okReq = pcall(function()
        bridge:SetRequestHandler(function(msg)
            if type(msg) ~= "table" or msg.kind ~= "bg3neuro_dialogue_snapshot" then
                return nil
            end
            return buildSnapshotReply()
        end)
    end)
    -- сообщение-клик от сервера → кликаем и отвечаем результатом.
    local okMsg = pcall(function()
        bridge:SetHandler(function(msg, user)
            if type(msg) ~= "table" or msg.kind ~= "bg3neuro_dialogue_click" then
                return
            end
            bridge:SendToServer(performClick(msg))
        end)
    end)

    if okReq and okMsg then
        bridgeReady = true
        log("bridge ready (channel=%s)", DIALOGUE_CHANNEL)
    else
        log("bridge handlers failed: req=%s msg=%s", tostring(okReq), tostring(okMsg))
    end
end

initBridge()

-- ======================================================================
-- v0.8.58 (тикет 25): лёгкий отдых через UI-клик.
-- Отдельный канал "BG3NeuroRest": сервер шлёт bg3neuro_rest_click, клиент
-- открывает меню лагеря (кнопка с командой; если не открыто — retry-причины,
-- сервер переспрашивает с паузой) и кликает Take Short Rest. Сервер шлёт
-- bg3neuro_rest_probe — клиент возвращает скан UI (подбор селекторов).
-- ======================================================================
local REST_CHANNEL = "BG3NeuroRest"
local restBridge = nil
local REST_OPEN_HINTS = { "camp", "rest", "fire", "tent", "endtheday", "gather" }
local BUTTON_REPORT_CAP = 250

local function textLooksLikeShortRest(s)
    local t = string.lower(s or "")
    if t == "" then
        return false
    end
    if string.find(t, "short") == nil or string.find(t, "rest") == nil then
        return false
    end
    if string.find(t, "long") ~= nil then
        return false
    end
    return true
end

local function hintMatch(s)
    s = string.lower(s or "")
    for _, h in ipairs(REST_OPEN_HINTS) do
        if string.find(s, h) ~= nil then
            return true
        end
    end
    return false
end

-- Первый непустой текст в поддереве el (глубина <= 3) — у кнопок текст часто
-- лежит в дочернем TextBlock, а не в свойстве Button.Text.
local function firstChildText(el)
    local function probe(e, d)
        if e == nil or d > 3 then
            return nil
        end
        local t = elText(e)
        if t ~= nil then
            return t
        end
        local cnt = safe(function() return tonumber(e.ChildrenCount) end) or 0
        for i = 1, cnt do
            local ch = safe(function() return e:Child(i) end)
            local got = probe(ch, d + 1)
            if got ~= nil then
                return got
            end
        end
        return nil
    end
    return probe(el, 0)
end

-- Все Button/Command-элементы во всех активных корнях (primitive-профили).
local function scanUiButtons()
    local out = {}
    local seen = {}
    for _, root in ipairs(collectRoots()) do
        local visited = {}
        walk(root, 0, visited, function(el, depth)
            if seen[el] then
                return
            end
            seen[el] = true
            local typ = elType(el)
            if isButtonish(typ) and hasCommand(el) then
                out[#out + 1] = {
                    el = el,
                    text = elText(el),
                    child = firstChildText(el),
                    typ = tostring(typ or ""),
                    name = tostring(elProp(el, "Name") or ""),
                    file = tostring(fileName(el) or ""),
                }
            end
        end)
    end
    return out
end

local function findShortRestButton(buttons)
    for _, b in ipairs(buttons) do
        if textLooksLikeShortRest(b.text) or textLooksLikeShortRest(b.child)
            or string.find(string.lower(b.typ .. " " .. b.name .. " " .. b.file), "shortrest") ~= nil
            or string.find(string.lower(b.name .. " " .. b.file), "short.rest") ~= nil then
            return b
        end
    end
    return nil
end

local function uiStateName()
    local sm = safe(function() return Ext.UI.GetStateMachine() end)
    if sm == nil then
        return nil
    end
    return safe(function() return tostring(sm.State) end)
end

local function restMenuOpen()
    local st = string.lower(uiStateName() or "")
    if string.find(st, "rest") ~= nil or string.find(st, "camp") ~= nil then
        return true
    end
    return findShortRestButton(scanUiButtons()) ~= nil
end

-- Клик по кнопке через её ICommand (параметр: CommandParameter > DataContext > сам элемент).
local function clickButton(el)
    local cmd = elProp(el, "Command")
    if cmd == nil then
        return false, "no Command"
    end
    local param = elProp(el, "CommandParameter")
    if param == nil then
        param = elProp(el, "DataContext")
    end
    if param == nil then
        param = el
    end
    local ok = pcall(function() cmd:Execute(param) end)
    if not ok then
        return false, "Command:Execute threw"
    end
    return true, nil
end

-- Открыть меню отдыха: если кнопка Take Short Rest уже видна — уже открыто.
-- Иначе ищем кнопку-«открывалку» (имя/файл/тип по REST_OPEN_HINTS) и кликаем.
local function openCampMenu()
    if restMenuOpen() then
        return true, nil
    end
    local buttons = scanUiButtons()
    for _, b in ipairs(buttons) do
        local hay = b.typ .. " " .. b.name .. " " .. b.file
        if hintMatch(hay) and not textLooksLikeShortRest(b.text) and not textLooksLikeShortRest(b.child) then
            local ok, reason = clickButton(b)
            if ok then
                log("rest: camp opener clicked (%s)", tostring(b.name ~= "" and b.name or b.file or b.typ))
                return true, nil
            end
        end
    end
    return false, "no camp/rest opener button (" .. table.concat(REST_OPEN_HINTS, ",") .. ")"
end

local function performRestClick(msg)
    local actionId = msg.action_id

    if not restMenuOpen() then
        local opened, reason = openCampMenu()
        if not opened then
            return { kind = "bg3neuro_rest_click_result", action_id = actionId, ok = false,
                reason = "retry:menu_not_open: " .. tostring(reason) }
        end
        -- открылка кликнута в этом же кадре; кнопка Take Short Rest появится через пару UI-фреймов
        return { kind = "bg3neuro_rest_click_result", action_id = actionId, ok = false,
            reason = "retry:menu_opened_await_button" }
    end

    local target = findShortRestButton(scanUiButtons())
    if target == nil then
        return { kind = "bg3neuro_rest_click_result", action_id = actionId, ok = false,
            reason = "fatal:no_short_rest_button_in_ui" }
    end

    local ok, reason = clickButton(target)
    if not ok then
        return { kind = "bg3neuro_rest_click_result", action_id = actionId, ok = false,
            reason = "fatal:click_failed: " .. tostring(reason) }
    end
    log("rest: Take Short Rest clicked (action=%s)", tostring(actionId or ""))
    return { kind = "bg3neuro_rest_click_result", action_id = actionId, ok = true }
end

local function buildRestProbeReply()
    local state = uiStateName()
    local roots = collectRoots()
    local rootsInfo = {}
    for i = 1, math.min(#roots, 40) do
        local root = roots[i]
        rootsInfo[#rootsInfo + 1] = {
            i = i,
            type = tostring(elType(root) or ""),
            name = tostring(elProp(root, "Name") or ""),
            file = tostring(fileName(root) or ""),
        }
    end
    local buttons = scanUiButtons()
    local btnInfo = {}
    for i = 1, math.min(#buttons, BUTTON_REPORT_CAP) do
        local b = buttons[i]
        btnInfo[#btnInfo + 1] = {
            typ = b.typ,
            name = b.name,
            file = b.file,
            text = tostring(b.text or ""),
            child = tostring(b.child or ""),
        }
    end
    return {
        kind = "bg3neuro_rest_probe_reply",
        state = state,
        roots = rootsInfo,
        ui_buttons = btnInfo,
        rest_menu_open = restMenuOpen(),
    }
end

local function initRestBridge()
    local okC, channel = pcall(function()
        return Ext.Net.CreateChannel((ModuleUUID or "BG3Neuro"), REST_CHANNEL)
    end)
    if not okC or channel == nil then
        log("rest: NetChannel create failed: %s", tostring(channel))
        return
    end
    restBridge = channel

    local okReq = pcall(function()
        restBridge:SetRequestHandler(function(msg)
            if type(msg) ~= "table" or msg.kind ~= "bg3neuro_rest_probe" then
                return nil
            end
            return buildRestProbeReply()
        end)
    end)
    local okMsg = pcall(function()
        restBridge:SetHandler(function(msg, user)
            if type(msg) ~= "table" or msg.kind ~= "bg3neuro_rest_click" then
                return
            end
            log("rest: click (action=%s)", tostring(msg.action_id or ""))
            restBridge:SendToServer(performRestClick(msg))
        end)
    end)

    if okReq and okMsg then
        log("rest: bridge ready (channel=%s)", REST_CHANNEL)
    else
        log("rest: bridge handlers failed: req=%s msg=%s", tostring(okReq), tostring(okMsg))
    end
end

initRestBridge()