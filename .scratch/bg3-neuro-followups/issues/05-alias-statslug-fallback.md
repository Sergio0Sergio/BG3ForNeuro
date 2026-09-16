# 05 — Alias edge: empty StatsId produces "entity_N"

Type: follow-up (code-review)
Status: resolved
Blocked by:

## Finding

The new language-independent alias source `statSlug` (BG3Neuro.lua:1785-1800) falls back to `slug(id)`; for an entity whose StatsId is empty (or where every candidate is non-ASCII), `slug("")` returns its built-in fallback `"entity"`, so `registerAlias` can mint aliases like `entity_1`, `entity_2` — English but meaningless, and indistinguishable from a real name collision.

For reference: `slug` returns `"entity"` only when the transliterated input is empty; an empty `StatsId` is exactly that case. The intended chain is: Cyrillic display name → English template name → transliterated display as last resort; `"entity"` is NOT a display name.

## Fix proposal

- In `statSlug`, treat an empty `slug(id)` result (`"entity"` from the pure-empty case, or `nil`) as "no usable stat id" and return `nil`, so `registerAlias` falls back to `slug(rawName)` (the transliterated display) instead of minting `entity_N`.
- Keep the `"entity"` default only for the genuinely nameless case (a character with neither display name nor stat id).

## Answer

Resolved-diff: already fixed in committed code (no changes this session).

`statSlug` (BG3Neuro.lua:1004-1025, present since commit 7697f11, an ancestor of HEAD) already rejects the phantom paths:
- `vs ~= ""` (line 1013) — empty StatsId candidate is skipped;
- `not hasNonAscii(vs)` — non-ASCII candidates skipped;
- `s ~= "entity"` (line 1015) — `slug`'s empty-input fallback is treated as "no usable stat id", NOT returned;
- otherwise returns `nil`.

`registerAlias` (line 1041) already implements the intended chain: `base = statSlug(guid) or slug(rawName)` for non-ASCII display names (Cyrillic display → English stat id → transliterated display as last resort); ASCII display names go straight to `slug(rawName)` (line 1043), which for a real entity is non-empty (displayName falls back to the guid, never to "").

`"entity"` is only reachable through `slug` itself (line 851), i.e. the genuinely nameless input — exactly the case the proposal wants to keep.

Verification: `git diff HEAD -- mod/BG3Neuro/BG3Neuro.lua` shows no working-tree deviation in the statSlug/registerAlias/slug area (my session's edits touched only executeCast/executeAttack/executeBonusAction/enqueueCastRequest). No PAK rebuild needed — behavior already correct.