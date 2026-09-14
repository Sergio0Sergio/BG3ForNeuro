# 03 — Design of the force_legacy flag and the fate of the fallback paths

Type: grilling
Status: resolved
Blocked by:

## Answer

Owner's decisions (grill 2026-09-13):

- **Switching rule — HYBRID.** The honest path (ServerCastRequest) is the default. On a failure, the mod automatically picks up legacy for that call; after **N consecutive failures** it switches to **persistent legacy until restart** (combat doesn't break, and the breakage isn't masked forever).
- **Scope — ONE kill-switch.** `force_legacy=true` moves ALL combat actions to legacy (attacks, casts, bonuses). The per-action `data.use_osi_spell` remains the precise command "this call goes through Osi.UseSpell" on top of the global flag.
- **Counter — SHARED (not per path), threshold N=3.** Any honest-path failure increments the single counter; once 3 is reached — persistent legacy for everything until restart.
- **Storage — Config.json + Ext.Mod.GetConfig.** The flag is read once at startup; the failure counter lives **in memory** (after a restart the fallback resets and the honest path is back; this is a deliberate trade-off: resilience per session, not forever). Currently there is NO config mechanism in the mod — `use_osi_spell` came per-action from the neuro; the ticket requires introducing `Ext.Mod.GetConfig`.
- **Documentation — BG3_Neuro_Spec.md** (the force_legacy section): when to set it manually, what happens during a hybrid fallback, the N=3 threshold. The source of truth for all sessions.

Unblocks: 04 (fallback rule for executeCast), implementation in executeCast/executeAttack.

## Question

Q2=b: after the honest path is proven, the fallback paths (`use_osi_spell`, manual `AddActionPoints(-1)`, `Osi.Attack`) stay alive under the `force_legacy` flag. What does this mean for code and configuration?

Clarifying:
- Where the flag goes: `Ext.Mod.GetConfig`/`config.json` (as is already done for diagnostic blocks)?
- What exactly does `force_legacy` enable — only casts (as `use_osi_spell` per action now) or the whole attack/cast/bonus paths?
- Interaction with the new honest code (correctness): if the honest path fails at runtime, do we fall back to legacy automatically or only via the flag?
- Fallback in the field: is the "enable force_legacy" criterion documented in a config comment?

Output: a `force_legacy` config spec section + an explicit switching rule, ready for implementation.