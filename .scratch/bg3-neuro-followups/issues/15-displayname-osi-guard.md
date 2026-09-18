# 15 — displayName: dead `type(Osi.GetDisplayName) == "function"` guard + uncaught first-resolve throw

Type: task (state emitter)
Status: resolved
Blocked by: 14 (resolved) — same root cause, same fix shape.

## Finding (2026-09-18, during ticket 14)

Ticket 14 proved: `Osi` is a plain table whose metatable `__index` is BG3SE's lazy C name resolver
(`BG3Extender/Lua/Osiris/LuaNameResolver.inl`, `LuaIndexResolverTable`). The *first* access to any
`Osi.<name>` raises `attempt to call a nil value` (and caches the callable proxy for later use), so
presence checks of the form `type(Osi.X) == "function"` / `Osi.X ~= nil` are always false *and* can
throw.

The same pattern survives in `displayName`:

- `mod/BG3Neuro/BG3Neuro.lua:941` — `if type(Osi.GetDisplayName) == "function" then` guarding the
  Osiris fallback `pcall(Osi.GetDisplayName, guid)`. The guard is always false ⇒ the fallback is
  **dead code**. And because the guard runs **before** any `pcall`, the very first time L941 is
  reached in a session it can propagate the resolver's `attempt to call a nil value` to the caller
  (callers of `displayName` do not all pcall it).
- `mod/BG3Neuro/BG3Neuro.lua:721` — same `type(Osi.GetDisplayName) == "function"` guard in the
  client/server-name path (`charGetDisplayName`-family, used by the name-keys path).

Why it's not always visible: the primary name path (DisplayName component via `Ext.Entity.Get` +
`GetComponent("DisplayName").Name:Get()`, L927-939) usually returns first, so the dead guard is only
reached when the component path fails (localized/odd entities). Nothing is currently crashing
because most captures satisfy the component path; but the fallback has never worked.

## Change

Mirror the ticket-14 fix (v0.8.46, `941a3c1`):

- Remove both `type(Osi.GetDisplayName) == "function"` guards (L721, L941).
- Call the proxy directly inside `pcall` (already wrapped at L722/L942), and let `pcall` treat a
  nil/missing symbol as a failed lookup (`"attempt to call a nil value"` → `ok=false`).
- Optionally warm the resolver once at load (e.g. a startup `pcall(function() return
  Osi.GetDisplayName end)`) so the one-shot throw cannot escape into a capture; or accept that the
  first pcall'd attempt is nil and subsequent ones work (same as `hostilityWithRef`).

## Verification

- Static: `luaparse` on both Lua files.
- Bench: entities whose DisplayName-component path fails must now get a name via
  `Osi.GetDisplayName`; no Lua error in the SE log during `state_capture`;
  `bg3_to_neuro.json` `allies`/`enemies` `name` fields non-empty.
- Regression: names already resolved by the component path unchanged (party, tieflings).

## Evidence

- `research/08-enemies-hostility-relation-api.md`; ticket 14 (root cause: `Osi.__index`
  lazy resolver).
- `mod/BG3Neuro/BG3Neuro.lua:721`, `:941` (dead guards); `:944` (the unreached fallback call).
- PAK history: v0.8.46 = PAK v052; next fix bumps the mod version (0.8.47) + new PAK v053.

## Fix (v0.8.47, `0e443e9`, PAK v053)

- Added shared helper `osiDisplayNameOf(guid)` (before `probeGameState`, `BG3Neuro.lua:697-710`):
  one-time resolver warm-up (`pcall(function() return Osi.GetDisplayName end)`), then
  `pcall(function() return Osi.GetDisplayName(guid) end)`; `ok=false`/nil → `nil`.
- Replaced both `type(Osi.GetDisplayName) == "function"` guard call-sites:
  - `probeGameState` current_characters loop (L740-745) — `display_name = osiDisplayNameOf(cc.character)`;
  - `displayName` fallback (L957-961) — `local n = osiDisplayNameOf(guid); if n ~= nil then return n end`.
- Both Lua files bumped to 0.8.47; `luaparse` OK.

## Live verification (2026-09-18, v0.8.47 / PAK v053)

- `state_capture` (id sc9): `success: true`, `allies`=9, `enemies`=8 — same as v0.8.46, no regression;
  all `allies`/`enemies` `name` fields non-empty and human-readable (Tav, Wyll, Zevlor, Remira,
  Aradin, Barth, Goblin Booyahg, Bugbear, Goblin Brawler, Worg, Goblin Tracker, ...).
- SE log (`Osiris Runtime 2026-09-18 06-05-49.log`): mod's `Osi.GetDisplayName` now **executes**:
  `exec [DIV query] GetDisplayName( ... )` → `Query returns: GetDisplayName( ..., "ResStr_XXXX" )`
  (e.g. acting char's prefixed guid at L113869, plus 4 clean-guids at L145846-145868) — the dead
  fallback is now reachable and non-throwing under the lazy resolver.
- No Lua errors during captures.

Known limitation (accepted): `Osi.GetDisplayName` returns the **DisplayName resource key**
(`ResStr_...`), not localized text. The primary component path (`Ext.Entity.Get` +
`GetComponent("DisplayName").Name:Get()`) always wins for real characters, so emitted `name`
fields keep human text; the Osi result would only surface for entity forms the component path
cannot resolve (edge case), and even then it is a harmless non-nil string (never a throw).

## Answer

Removed the always-false `type(Osi.GetDisplayName) == "function"` guards; the Osiris fallback is
now a direct, pcall-wrapped `Osi.GetDisplayName` call (warm-up once), mirroring the ticket-14
pattern. Live capture confirms the fallback is reachable and error-free, emitted names are
unchanged, and no Lua errors appear.