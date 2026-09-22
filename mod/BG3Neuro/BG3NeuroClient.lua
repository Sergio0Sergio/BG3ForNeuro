-- BG3NeuroClient.lua v0.8.68 — клиентская половина мода (тикеты bg3-neuro-dialogue-click, 25, 26).
-- Живёт в клиентском контексте (Ext.UI / Noesis), грузится через BootstrapClient.lua.
-- Задачи:
--   1) снапшот вариантов диалога (line + options) для сервера по NetChannel
--      "BG3NeuroDialogue" (тот же module+channel, что в серверном BG3Neuro.lua);
--   2) реальный клик по выбранному варианту через Noesis (ICommand:Execute()).
--   v0.8.68: убран мёртвый fast-travel через waypoint-UI (ticket 26, серверный
--      TeleportPartiesWithMovie теперь делает travel напрямую): executeTravelViaUi,
--      performTravelClick, канал BG3NeuroTravel.
--   v0.8.61 (тикет 25): честный ShortRest напрямую — команда на DataContext виджета
--      HotBar/ScreenFade (ui::DCWidget) с полями ShortRest/CampTravel, executeShortRestViaDc();
--      рест-панель вне MainCanvas (слой PopupPanels), GetStateMachine()==nil.
--   v0.8.60 (тикет 25): полный dump дерева от RootVisual — виджеты (ls.UIWidget:HotBar
--      и др.) с DataContext DCWidget держат ShortRest/CampTravel на глубине d5.
--   v0.8.59 (тикет 25): диагностика rest-меню — ancestors-цепочки, sm.States,
--      Find по именам рест-панели, DataContext (команда ShortRest — VM-команда, не кнопка).
--   v0.8.58 (тикет 25): лёгкий отдых — канал "BG3NeuroRest": скан UI (rest_probe)
--      и клик по кнопке Take Short Rest (меню лагеря открываем программно).
-- Клик-механика (research 01 + UI.inl): вариант — Button-подобный элемент с Command
-- (Noesis::BaseCommand:CanExecute/Execute). Порядок candidates = порядок обхода
-- UI-дерева = UI-порядок (option_index 1-based). Поиск по option_index, при
-- расхождении текста — фолбэк по option_text (тикет 02, Q2=б).
-- Никакой записи в IPC-файлы: состояние пишет только серверная половина (Q3=а).

local DIALOGUE_CHANNEL = "BG3NeuroDialogue"
local OPTION_DEPTH_CAP = 12
_G["BG3Neuro_VERSION"] = "0.8.68" -- экспорт для BootstrapClient.lua (правдивый лог загрузки)
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

-- Общие UI-хелперы, используемые executeShortRestViaDc (должны стоять до него).
local SHORTREST_SCAN_DEPTH = 14
local function uiPropName(el)
    return tostring(elProp(el, "Name") or "")
end
local function uiTreeTop(el)
    local top = el
    for _ = 1, SHORTREST_SCAN_DEPTH do
        local p = safe(function() return top:TreeParent() end)
        if p == nil then
            break
        end
        top = p
    end
    return top
end

-- Выполнение короткого отдыха напрямую: команда ShortRest живёт на DataContext
-- (ui::DCWidget) виджетов HUD-слоя (HotBar, ScreenFade, TargetInfo, ...), которые НЕ
-- являются детьми MainCanvas и не имеют CLI без UIWidget. Берём верхушку Noesis-дерева,
-- спускаемся по слоям, находим виджет с DC-командой ShortRest и вызываем Execute —
-- это эквивалент клика по MenuItem "ShortRest"/горячей клавише (bench-proven v0.8.61).
local function executeShortRestViaDc()
    local roots = collectRoots()
    if #roots == 0 then
        return false, "no ui roots"
    end
    local top = uiTreeTop(roots[1])
    if top == nil then
        return false, "no tree top"
    end
    local candidates = {}
    local visited = {}
    local function scan(node, depth)
        if node == nil or depth > SHORTREST_SCAN_DEPTH or visited[node] then
            return
        end
        visited[node] = true
        local typ = tostring(elType(node) or "")
        local name = uiPropName(node)
        local dc = safe(function() return node.DataContext end)
        if dc ~= nil then
            local cmd = safe(function() return dc:GetProperty("ShortRest") end)
            if cmd ~= nil then
                candidates[#candidates + 1] = {
                    node = node, cmd = cmd, typ = typ, name = name,
                    dc_type = tostring(safe(function() return tostring(dc) end) or ""),
                    priority = (string.find(string.lower(name), "hotbar") ~= nil or
                        string.find(string.lower(typ), "hotbar") ~= nil or
                        string.find(string.lower(name), "rest") ~= nil) and 0 or 1,
                }
            end
        end
        local cc = safe(function() return tonumber(node.ChildrenCount) end) or 0
        local vc = safe(function() return tonumber(node.VisualChildrenCount) end) or 0
        local cnt = math.max(cc, vc)
        for j = 1, cnt do
            local ch = safe(function() return node:Child(j) end)
            if ch == nil and j <= vc then
                ch = safe(function() return node:VisualChild(j) end)
            end
            if ch ~= nil then
                scan(ch, depth + 1)
            end
        end
        if cnt == 0 then
            local content = safe(function() return node.Content end)
            if content ~= nil and content ~= node then
                scan(content, depth + 1)
            end
        end
    end
    scan(top, 0)

    if #candidates == 0 then
        return false, "no ShortRest DC command found in ui tree"
    end
    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.dc_type < b.dc_type
    end)

    for _, c in ipairs(candidates) do
        local can = safe(function() return c.cmd:CanExecute(nil) end)
        log("rest: cmd candidate %s:%s (%s) can=%s", tostring(c.typ), tostring(c.name),
            tostring(c.dc_type), tostring(can))
    end

    local lastErr = nil
    for _, c in ipairs(candidates) do
        local can = safe(function() return c.cmd:CanExecute(nil) end)
        if can == false then
            lastErr = "CanExecute=false on " .. c.typ .. ":" .. c.name
            -- ищем следующий кандидат (другой виджет может быть готов к отдыху)
        else
            local ok = pcall(function() c.cmd:Execute(nil) end)
            if ok then
                log("rest: ShortRest executed via DC %s:%s (%s)",
                    tostring(c.typ), tostring(c.name), tostring(c.dc_type))
                return true, c.typ .. ":" .. c.name
            end
            lastErr = "Execute threw on " .. c.typ .. ":" .. c.name
        end
    end
    return false, "ShortRest DC execute failed: " .. tostring(lastErr)
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

    -- v0.8.61: прямой путь — команда ShortRest на DataContext виджета HotBar (DCWidget).
    -- Рест-панель вне MainCanvas и через scanUiButtons недостижима; этот вызов —
    -- эквивалент клика по MenuItem/HotKey (работает даже без открытой панели).
    local ok, where = executeShortRestViaDc()
    if ok then
        log("rest: ShortRest clicked via DC (action=%s): %s", tostring(actionId or ""), tostring(where))
        return { kind = "bg3neuro_rest_click_result", action_id = actionId, ok = true, via = where }
    end
    log("rest: direct DC ShortRest unavailable (%s), fallback to UI click", tostring(where))

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

local MAX_ANCESTORS = 12
local FIND_NAMES = { "RestOptionsList", "ShortRestItem", "CampItem", "LongRestItem",
    "AcceptButton", "ShortRest", "CampTravel", "RestPanel", "RestControl",
    "HotBar", "RestMenu", "ShortRestShortcut", "ShortRestItem" }
local function propName(el)
    return tostring(elProp(el, "Name") or "")
end

-- Диагностика ancestors: от корня вверх до верхушки Noesis-дерева.
local function ancestorsChain(roots)
    local out = {}
    local seen = {}
    for _, start in ipairs(roots) do
        local chain = {}
        local el = start
        for _ = 1, MAX_ANCESTORS do
            if el == nil or seen[el] then
                break
            end
            seen[el] = true
            chain[#chain + 1] = {
                type = tostring(elType(el) or ""),
                name = propName(el),
                file = tostring(fileName(el) or ""),
                cc = safe(function() return tonumber(el.ChildrenCount) end) or 0,
                vc = safe(function() return tonumber(el.VisualChildrenCount) end) or 0,
            }
            local p = safe(function() return el:TreeParent() end)
            if p == nil then
                p = safe(function() return el.Parent end)
            end
            if p == nil then
                p = safe(function() return el.VisualParent end)
            end
            el = p
        end
        out[#out + 1] = chain
    end
    return out
end

-- Поиск узла по имени в поддереве (FrameworkElement:Find = FindNodeName).
local function findNodeInSubtree(root, name)
    local hit = safe(function() return root:Find(name) end)
    if hit == nil then
        return nil
    end
    return {
        type = tostring(elType(hit) or ""),
        name = propName(hit),
        file = tostring(fileName(hit) or ""),
    }
end

-- Данные state machine: активное состояние, корень, коллекция состояний.
local function stateMachineInfo()
    local sm = safe(function() return Ext.UI.GetStateMachine() end)
    if sm == nil then
        return nil, "no GetStateMachine"
    end
    local info = {
        root_state = tostring(safe(function() return sm.RootState end) or ""),
        state = tostring(safe(function() return sm.State end) or ""),
        states_count = arrLen(safe(function() return sm.States end)),
        states = {},
    }
    local sts = safe(function() return sm.States end)
    local n = arrLen(sts)
    for i = 1, math.min(n, 40) do
        local inst = arrGet(sts, i)
        if inst ~= nil then
            local st = safe(function() return inst.State end)
            local sw = safe(function() return inst.StateWidgets end)
            info.states[#info.states + 1] = {
                tostring = tostring(safe(function() return tostring(inst) end) or ""),
                state_name = tostring(safe(function() return tostring(st) end) or ""),
                widgets = arrLen(safe(function() return inst.Widgets end)),
                statewidgets = arrLen(sw),
            }
        end
    end
    return info, nil
end

-- Поиск рест/лагерных узлов по имени среди активных корней и их ancestors.
local function findRestNodes(roots)
    local scanned = {}
    local hits = {}
    local nodes = {}
    for _, root in ipairs(roots) do
        local pool = { root }
        -- добавляем ancestors корня — там может жить слой с рест-панелью/HotBar
        local el = root
        for _ = 1, MAX_ANCESTORS do
            local p = safe(function() return el:TreeParent() end)
            if p == nil then
                p = safe(function() return el.Parent end)
            end
            if p == nil or p == el or scanned[p] then
                break
            end
            scanned[p] = true
            pool[#pool + 1] = p
            el = p
        end
        for _, cand in ipairs(pool) do
            if cand ~= nil then
                for _, name in ipairs(FIND_NAMES) do
                    if not hits[name] then
                        local hit = findNodeInSubtree(cand, name)
                        if hit ~= nil then
                            hit.via = tostring(elType(cand) or "") .. ":" .. propName(cand)
                            hits[name] = hit
                        end
                    end
                end
            end
        end
    end
    return hits
end

-- DataContext активных корней и их ближайших ancestors: есть ли команда ShortRest.
local function dataContextInfo(roots)
    local out = {}
    local seen = {}
    for _, root in ipairs(roots) do
        local el = root
        for _ = 1, 6 do
            if el == nil or el == false or seen[el] then
                break
            end
            seen[el] = true
            local dc = safe(function() return el.DataContext end)
            if dc ~= nil then
                local hasShortRest = safe(function() return dc:GetProperty("ShortRest") end) ~= nil
                local hasCamp = safe(function() return dc:GetProperty("CampTravel") end) ~= nil
                if hasShortRest or hasCamp or true then
                    out[#out + 1] = {
                        node = tostring(elType(el) or "") .. ":" .. propName(el),
                        dc_type = tostring(safe(function() return tostring(dc) end) or ""),
                        has_shortrest_prop = hasShortRest,
                        has_camp_prop = hasCamp,
                    }
                end
                break
            end
            local p = safe(function() return el:TreeParent() end)
            if p == nil then
                p = safe(function() return el.Parent end)
            end
            if p == nil then
                p = safe(function() return el.VisualParent end)
            end
            el = p
        end
    end
    return out
end

-- Поднимаемся от el до самого верхнего предка (RootVisual) и возвращаем его.
local function topOfTree(el)
    local cur = el
    for _ = 1, MAX_ANCESTORS do
        local p = safe(function() return cur:TreeParent() end)
        if p == nil then
            p = safe(function() return cur.Parent end)
        end
        if p == nil then
            p = safe(function() return cur.VisualParent end)
        end
        if p == nil or p == cur then
            return cur
        end
        cur = p
    end
    return cur
end

-- Описание одного узла для дампа.
local function describeNode(el, depth)
    return {
        d = depth,
        type = tostring(elType(el) or ""),
        name = propName(el),
        file = tostring(fileName(el) or ""),
        cc = safe(function() return tonumber(el.ChildrenCount) end) or 0,
        vc = safe(function() return tonumber(el.VisualChildrenCount) end) or 0,
        action = tostring(safe(function() return tostring(elProp(el, "Action")) end) or ""),
    }
end

-- Полный дамп дерева от RootVisual вниз: все слои (HUD, PopupPanels, оверлеи),
-- которые не видны из MainCanvas. Лимит узлов/глубины защищает от циклов.
local FULL_DUMP_MAX = 600
local FULL_DUMP_DEPTH = 14

local function collectLayerChildren(el, layerDump, visited)
    local nodes = {}
    local function walkNode(node, depth)
        if node == nil or depth > FULL_DUMP_DEPTH or visited[node] or #nodes >= FULL_DUMP_MAX then
            return
        end
        visited[node] = true
        nodes[#nodes + 1] = describeNode(node, depth)
        local cc = safe(function() return tonumber(node.ChildrenCount) end) or 0
        local vc = safe(function() return tonumber(node.VisualChildrenCount) end) or 0
        local cnt = math.max(cc, vc)
        for j = 1, cnt do
            local ch = safe(function() return node:Child(j) end)
            if ch == nil and j <= vc then
                ch = safe(function() return node:VisualChild(j) end)
            end
            if ch ~= nil then
                walkNode(ch, depth + 1)
            end
        end
        if cnt == 0 then
            local content = safe(function() return node.Content end)
            if content ~= nil and content ~= node then
                walkNode(content, depth + 1)
            end
        end
    end
    walkNode(el, 0)
    return nodes
end

local function fullTreeDump()
    local out = {}
    local visited = {}
    local roots = collectRoots()
    for _, root in ipairs(roots) do
        local top = topOfTree(root)
        if not visited[top] then
            local children = collectLayerChildren(top, out, visited)
            out[#out + 1] = {
                top_type = tostring(elType(top) or ""),
                top_name = propName(top),
                nodes = children,
            }
        end
    end
    return out
end

-- Find по всем FIND_NAMES по ВЕРХУШКЕ дерева (каждый слой отдельно) — рест-панель
-- и HotBar лежат в оверлейном слое, недоступном из MainCanvas.
local function fullFindRestNodes()
    local hits = {}
    local seenTops = {}
    local roots = collectRoots()
    for _, root in ipairs(roots) do
        local top = topOfTree(root)
        if not seenTops[top] then
            seenTops[top] = true
            for _, name in ipairs(FIND_NAMES) do
                if not hits[name] then
                    local hit = findNodeInSubtree(top, name)
                    if hit ~= nil then
                        hit.via = "top:" .. tostring(elType(top) or "") .. ":" .. propName(top)
                        hits[name] = hit
                    end
                end
            end
        end
    end
    return hits
end

-- DataContext с командой ShortRest/CampTravel по всему дереву от верхушки каждого слоя.
local function fullDataContextInfo()
    local out = {}
    local rootTop = nil
    local roots = collectRoots()
    for _, root in ipairs(roots) do
        rootTop = topOfTree(root)
        break
    end
    if rootTop ~= nil then
        local seen = {}
        local function probe(node, depth)
            if node == nil or seen[node] or #out >= 40 then
                return
            end
            seen[node] = true
            local dc = safe(function() return node.DataContext end)
if dc ~= nil then
                local sr = safe(function() return dc:GetProperty("ShortRest") end)
                local camp = safe(function() return dc:GetProperty("CampTravel") end)
                local gtw = safe(function() return dc:GetProperty("GotoWaypoint") end)
                local entry = {
                    path = tostring(elType(node) .. ":" .. propName(node) .. " @d" .. tostring(depth)),
                    dc_type = tostring(safe(function() return tostring(dc) end) or ""),
                    has_shortrest = sr ~= nil,
                    has_camp = camp ~= nil,
                    has_gotowaypoint = gtw ~= nil,
                }
                local dupe = false
                for _, e in ipairs(out) do
                    if e.path == entry.path and e.dc_type == entry.dc_type then
                        dupe = true
                        break
                    end
                end
                if not dupe then
                    out[#out + 1] = entry
                end
            end
            local cc = safe(function() return tonumber(node.ChildrenCount) end) or 0
            local vc = safe(function() return tonumber(node.VisualChildrenCount) end) or 0
            local cnt = math.max(cc, vc)
            for j = 1, cnt do
                local ch = safe(function() return node:Child(j) end)
                if ch == nil and j <= vc then
                    ch = safe(function() return node:VisualChild(j) end)
                end
                if ch ~= nil then
                    probe(ch, depth + 1)
                end
            end
        end
        probe(rootTop, 0)
    end
    return out
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
    local smInfo, smErr = stateMachineInfo()
    return {
        kind = "bg3neuro_rest_probe_reply",
        state = state,
        sm = smInfo,
        sm_err = smErr,
        roots = rootsInfo,
        ancestors = ancestorsChain(roots),
        -- полный дамп дерева от верхушки Noesis (все слои, включая оверлеи)
        full_dump = fullTreeDump(),
        find_hits = findRestNodes(roots),
        full_find_hits = fullFindRestNodes(),
        data_contexts = dataContextInfo(roots),
        full_dc = fullDataContextInfo(),
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
