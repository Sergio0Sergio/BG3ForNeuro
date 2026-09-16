# AGENTS.md

## Operating rules

- **Always communicate in Russian.** All agent responses to the user must be in Russian. This applies to every model and every agent session in this repository. Never respond in English or any other language unless explicitly asked.

- **Never force-kill the game.** Do NOT use `Stop-Process -Force` (or `taskkill /F`) on `bg3`/`bg3_dx11`. Forced termination produces error dialogs on exit and leaves the save/session in a bad state. Ask the user to close the game normally, or use a graceful close (e.g. `CloseMainWindow()`), and wait for the process to exit on its own.

- **BG3 mod PAK must pack paths as `Mods/BG3Neuro/...`.** When building the mod PAK with `paktool2`, pass the directory that *contains* `Mods\` as the source, not the `Mods\BG3Neuro` folder itself. Verify with `paktool2 list <pak>` that entries start with `Mods/BG3Neuro/`. If the `Mods/` prefix is missing, the game does not find the module and silently rewrites `modsettings.lsx` back to vanilla (mod never loads, no error in the SE log). Correct pack source: `%TEMP%\opencode\vNNN_build` (its child `Mods\BG3Neuro\` holds the files); wrong source: `%TEMP%\opencode\vNNN_build\Mods`.

- **Neuro HTTP injects: `data` must be a JSON *string*, not an object.** The app's WS handler reads the action payload with `data["data"]?.GetValue<string>()` (`NeuroWebSocketClient.HandleAction`). Posting an object (e.g. `"data":{}`) throws, the WS receive loop dies, the app disconnects and reconnects, and the action is dropped (looks like "inject silently fails + `[neuro] disconnected/connected` blips"). Use `"data":"{}"` or `"data":"{\"actor\":...}"`. Autopilot no longer interferes: set `"autopilot": { "enabled": false }` in the app's `config.json` before bench work so only deterministic injects act.

- **The game runs in ENGLISH ONLY.** This app and mod are used with the English-language version of Baldur's Gate 3; everything must function and read correctly in English. Keep the mod's user-facing strings (action `error_detail`, status/log messages surfaced to the app user) in English — do not rely on game-locale quirks, and never parse/match game text in Russian. Engine errors come localized; prefer the mod's own English diagnostics over passing through engine strings verbatim.

## Agent skills

### Issue tracker

Local markdown: issues and specs live in `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles, each label equal to its name: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.