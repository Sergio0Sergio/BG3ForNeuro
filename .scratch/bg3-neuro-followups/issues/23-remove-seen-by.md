# 23 — Remove the hardcoded `seen_by` field (perception contract rev 2)

Type: bug (spec/contract debt — perception)
Status: verified (v0.8.62, PAK v093 installed + live 2026-09-21)
Blocked by: —

## Finding

Perception contract rev 2 (`.scratch/bg3-neuro-perception/spec.md` §2/§3, ticket 03) decided the
emission gate is **binary**: an entity is either on screen (emitted, `perception="visible"`) or
absent from the state entirely. The legacy `seen_by` field was therefore **removed** by contract —
it was the old "lie" (`seen_by = "player"` hardcoded for every object).

The mod still emitted it:

- `mod/BG3Neuro/BG3Neuro.lua:2842` — `seen_by = "player",` for every `scanNearbyObjects` entry.

The acceptance note (`issues/05-acceptance-and-bench.md:153-154`) recorded this as a non-critical
deviation "to be filed as a follow-up" — this ticket. The C# side, contrary to the spec's assumption
that "production C# does not read it", **did** read it: `StateSerializer` grouped objects by
`SeenBy` and rendered `## Objects (seen by player, N)` headers (plus a `shadowheart` viewer case in
tests). So removal touches the mod, the core model, the serializer and tests.

## Fix

1. **Mod** — delete the `seen_by = "player",` emission (`BG3Neuro.lua`). Version bump to **0.8.62**.
2. **Core** — remove `ExplorationObject.SeenBy` (`src/BG3Neuro.Core/State/CombatState.cs`).
3. **Serializer** — drop the `GroupBy(o => o.SeenBy)` grouping; emit a single
   `## Objects (N)` header (the `MaxVisibleObjects` cap + "… and N more" logic is preserved, now
   applied to the whole list instead of per-group).
4. **Tests** — remove the `"seen_by": "shadowheart"` fixture member and the `SeenBy` assertion;
   update the two header assertions to `## Objects (N)`; the capped-case assertion becomes
   `## Objects (4)` / `- … and 2 more` (the whole list is now one group).
5. **Docs** — `BG3_Neuro_Spec.md` §3.5 example updated to the single-header form + a pointer to the
   perception contract; `docs/manual-regression-checklist.md` P6 note no longer cites `seen_by`.

## Verification

- `luaparse` on the mod: **PARSE_OK** (237 nodes).
- `dotnet test tests/BG3Neuro.Core.Tests` → **166/166** passed.
- `dotnet build BG3Neuro.sln` → 0 warnings / 0 errors.
- PAK **v093** staged (`%TEMP%\opencode\BG3Neuro_v093.pak`, 88437 bytes, MD5
  `16caabb149309eb6387971d8f0eb5d57`), `paktool2 list` → entries start with `Mods/BG3Neuro/`,
  staged lua contains **0** `seen_by`, `MOD_VERSION = "0.8.62"`.
- **Install pending**: the game is running, so the PAK/`modsettings.lsx` swap is deferred until it
  is closed (AGENTS.md). On install: update MD5 in both `ModuleShortDesc` nodes and re-check the
  emitted exploration state has no `seen_by` and a single `## Objects (N)` header.

### Live verification (2026-09-21, v0.8.62 / PAK v093)

- Game closed → installed `BG3Neuro_v093.pak` to `...\Mods\BG3Neuro.pak` (88437 B, MD5
  `16caabb149309eb6387971d8f0eb5d57`); updated the MD5 in **both** `ModuleShortDesc` nodes of
  `modsettings.lsx` (backup `%TEMP%\opencode\modsettings.backup.20260921_180540.lsx`; BOM/size
  preserved).
- Game launched: `heartbeat.json` → **`version 0.8.62`**, fresh (age ≈ 2 s) — mod v093 loaded.
- `bg3_to_neuro.json` (exploration, 18 objects) → **`seen_by` absent** (string search = false).
- App-bin `BG3Neuro.Core.dll` (18:00:43) → contains `## Objects (`, no `seen by` / `SeenBy`
  (UTF-16 metadata search) — the App serves the new serializer. The exact single-header render is
  asserted by `StateSerializerTests` (166/166).

## Answer

`seen_by` is gone from the protocol and the renderer: mod emission removed, `ExplorationObject.SeenBy`
deleted, serializer emits one `## Objects (N)` header, tests/docs updated. Note the spec's premise was
wrong — the field was a live, tested feature (`StateSerializerTests.cs:343-344`), so the removal was
implemented as a format change (single header), not a dead-code delete. PAK v093 was installed and
live-verified (heartbeat `0.8.62`, no `seen_by` in the emitted state).

## Evidence

- `mod/BG3Neuro/BG3Neuro.lua` (was `:2842`).
- `src/BG3Neuro.Core/State/CombatState.cs`, `src/BG3Neuro.Core/State/StateSerializer.cs:221-268`.
- `tests/BG3Neuro.Core.Tests/State/StateSerializerTests.cs:241,327,343-344,397-398`.
- `.scratch/bg3-neuro-perception/spec.md` §2–§3; `issues/05-acceptance-and-bench.md:153-154`.
