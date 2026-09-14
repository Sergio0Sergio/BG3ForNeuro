# 05 — Alias edge: empty StatsId produces "entity_N"

Type: follow-up (code-review)
Status: open
Blocked by:

## Finding

The new language-independent alias source `statSlug` (BG3Neuro.lua:1785-1800) falls back to `slug(id)`; for an entity whose StatsId is empty (or where every candidate is non-ASCII), `slug("")` returns its built-in fallback `"entity"`, so `registerAlias` can mint aliases like `entity_1`, `entity_2` — English but meaningless, and indistinguishable from a real name collision.

For reference: `slug` returns `"entity"` only when the transliterated input is empty; an empty `StatsId` is exactly that case. The intended chain is: Cyrillic display name → English template name → transliterated display as last resort; `"entity"` is NOT a display name.

## Fix proposal

- In `statSlug`, treat an empty `slug(id)` result (`"entity"` from the pure-empty case, or `nil`) as "no usable stat id" and return `nil`, so `registerAlias` falls back to `slug(rawName)` (the transliterated display) instead of minting `entity_N`.
- Keep the `"entity"` default only for the genuinely nameless case (a character with neither display name nor stat id).