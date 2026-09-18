# AGENTS.md

## Operating rules

- **Always communicate in Russian.** All agent responses to the user must be in Russian. This applies to every model and every agent session in this repository. Never respond in English or any other language unless explicitly asked.

- **Never force-kill the game.** Do NOT use `Stop-Process -Force` (or `taskkill /F`) on `bg3`/`bg3_dx11`. Forced termination produces error dialogs on exit and leaves the save/session in a bad state. Ask the user to close the game normally, or use a graceful close (e.g. `CloseMainWindow()`), and wait for the process to exit on its own.

- **BG3 mod PAK must pack paths as `Mods/BG3Neuro/...`.** When building the mod PAK with `paktool2`, pass the directory that *contains* `Mods\` as the source, not the `Mods\BG3Neuro` folder itself. Verify with `paktool2 list <pak>` that entries start with `Mods/BG3Neuro/`. If the `Mods/` prefix is missing, the game does not find the module and silently rewrites `modsettings.lsx` back to vanilla (mod never loads, no error in the SE log). Correct pack source: `%TEMP%\opencode\vNNN_build` (its child `Mods\BG3Neuro\` holds the files); wrong source: `%TEMP%\opencode\vNNN_build\Mods`.

- **Neuro HTTP injects: `data` must be a JSON *string*, not an object.** The app's WS handler reads the action payload with `data["data"]?.GetValue<string>()` (`NeuroWebSocketClient.HandleAction`). Posting an object (e.g. `"data":{}`) throws, the WS receive loop dies, the app disconnects and reconnects, and the action is dropped (looks like "inject silently fails + `[neuro] disconnected/connected` blips"). Use `"data":"{}"` or `"data":"{\"actor\":...}"`. Autopilot no longer interferes: set `"autopilot": { "enabled": false }` in the app's `config.json` before bench work so only deterministic injects act.

- **The game runs in ENGLISH ONLY.** This app and mod are used with the English-language version of Baldur's Gate 3; everything must function and read correctly in English. Keep the mod's user-facing strings (action `error_detail`, status/log messages surfaced to the app user) in English — do not rely on game-locale quirks, and never parse/match game text in Russian. Engine errors come localized; prefer the mod's own English diagnostics over passing through engine strings verbatim.

- **`Osi` is a lazy-resolver table: NEVER probe `Osi.X ~= nil` / `type(Osi.X)`, call it directly.** `Osi` is a plain Lua table whose metatable `__index` is BG3SE's C name resolver (`LuaIndexResolverTable` in `BG3Extender/Lua/Osiris/LuaNameResolver.inl`). The *first* access to any `Osi.<name>` raises `attempt to call a nil value` and caches the callable proxy; every later access/call works. Consequences proven on the bench (v0.8.43–46, ticket 14): (a) presence checks like `Osi.IsEnemy ~= nil` are always false *and* throw; (b) `type(Osi.X) == "function"` is always false because members are callable userdata proxies — guards like the one in `displayName` (`BG3Neuro.lua:721`, `:941`) are dead code worth a ticket, not a pattern to reuse. Correct idiom: `pcall(function() return Osi.IsEnemy(ref, g) end)` and treat `ok=false` as "unavailable"; warm the resolver once (e.g. `pcall(function() return Osi.IsEnemy end)`) so the one-shot throw cannot eat the first verdict.

- **Bench injects: do NOT pass JSON via child `powershell -File ... -Data '...'` — the child drops every `"`.** Bench-proven (ticket 17): `-Data '{"spell_name":"bless",...}'` arrives inside the script as `{spell_name:bless,...}`, the written file carries `"data":"{spell_name:bless,target_id:tav}"`, the mod's lenient `Ext.Json.Parse` produces a table without `spell_name`, and the cast fails with the misleading `spell_name is required` (3/3 via the subprocess vs 3/3 OK for identical payloads written inline). The data member must be a real JSON string. Pass data through an env var (`$env:BG3NEURO_DATA = '{"spell_name":"bless","target_id":"tav"}'; powershell -File drive_action.ps1 -Id x -Name cast_spell`) or write the file inline; `drive_action.ps1` self-validates the JSON and fails fast on malformed input.

## Agent skills

### Issue tracker

Local markdown: issues and specs live in `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles, each label equal to its name: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.