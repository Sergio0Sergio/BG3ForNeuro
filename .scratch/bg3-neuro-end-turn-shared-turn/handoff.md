# Handoff — end_turn shared-turn fix (v0.8.34)

## What this is

Continuation of the BG3Neuro live-combat bench. The blocker "`end_turn` does not switch the
turn" is diagnosed, fixed in code and built into a PAK. **The only remaining step is
install + live verify**, which needs the game closed.

## State at handoff

- Code fix committed: `mod/BG3Neuro/BG3Neuro.lua` + `BG3NeuroClient.lua`, version 0.8.33 → **0.8.34**.
- Built PAK: `C:\Users\2serg\AppData\Local\Temp\opencode\v040_pak\BG3Neuro.pak`
  - MD5 **`84FCF350CDC770BE135BA4944BC351AB`**, entries start with `Mods/BG3Neuro/` (correct).
- Currently installed PAK is still v0.8.33 (`FCF3C92DAB0681224AB6A0626D2E7BBF`).
- Game (`bg3`) was running → PAK locked → **not installed yet**.

## Root cause (one line)

A BG3 active turn can be shared by several allies; the engine ends it only when
`TurnBased.RequestedEndTurn` is set on **all** co-active characters. The mod set it on one
(`acting`) only → `ended=false` forever. Fix: also set it on every entity with
`TurnBased.IsActiveCombatTurn == true` (`!sailor_endturn` semantics).

Full write-up: `.scratch/bg3-neuro-end-turn-shared-turn/issues/01-end-turn-shared-turn.md`.

## Next steps

1. Ask the user to close BG3 **gracefully** (never `Stop-Process -Force` — see `AGENTS.md`).
2. Install:
   - `Copy-Item` `v040_pak\BG3Neuro.pak` → `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\BG3Neuro.pak`
     (keep a `.bak` copy of the current one).
   - Update the two MD5 entries in
     `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\PlayerProfiles\Public\modsettings.lsx`
     from `FCF3C92DAB0681224AB6A0626D2E7BBF` → `84FCF350CDC770BE135BA4944BC351AB`.
3. Relaunch, load the combat save, confirm `23 actions registered` / version `0.8.34` in the SE log.
4. Verify: on a **shared** turn, a single `end_turn {"actor":"<one ally>"}` must advance
   (`ended:true`, `acting_after` = next actor). Driver: `drive_action.ps1`.
5. Re-run the blocked §9.5 combat items against the full stack.

## Key paths / commands

- IPC dir: `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\`
  (`neuro_to_bg3.json` in, `result_<id>.json` out, `bg3_to_neuro.json` state, `heartbeat.json`).
  `data` MUST be a JSON **string** (`"{}"`), not an object.
- Driver: `C:\Users\2serg\AppData\Local\Temp\opencode\drive_action.ps1`
- Paktool: `C:\Users\2serg\AppData\Local\Temp\opencode\paktool2\bin\Debug\net9.0\paktool2.exe`
- Lua parse check: luaparse 0.3.1 with `luaVersion: "5.3"`.
- SE logs: `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\`.

## Git

Committed fix: see the latest commit on `master`. Uncommitted working-tree noise at handoff:
untracked `neuro-sdk/neuro-sdk` (submodule-ish), unrelated to this work.
