# 10: CI and smoke: Randy + mock files + manual checklist

**What to build:** A ready-to-run test bench for the project. Integration tests (A/B from §9.3) run against Randy (the Neuro simulator) and mock files instead of the real BG3SE channel, so the verticals are verifiable without the game. The smoke scenario "connected → state arrived → end_turn executed → state updated" runs in a single command/step. The §9.5 manual regression checklist is formatted as markup in the repository (not just spec text).

**Blocked by:** 03 (combat loop — core of the smoke scenario).

**Status:** done

- [x] Test bench: the Randy simulator + mock harness for the file bridge start with one command, documented in the README. (`README.md`: layout, build, `dotnet test` with auto-start of Randy (env `RANDY_WS_PORT`/`RANDY_HTTP_PORT`, node required), `tests\smoke.ps1` in one command; layers A/B/C per §9.3)
- [x] The A/B integration tests are standalone (CI, no game), green on the 03 vertical. (A: FakeNeuroServer + mock files — combat/dialogue/exploration/resilience; B: Randy over a real WS; run 2× **139/139**, 0 node after the run)
- [x] The smoke scenario (connect → state → end_turn → new state) is scripted and runs in one step. (`tests\smoke.ps1` + `FullLoopSmokeTests` (no Randy/game): startup+register+force → end_turn success+action file → updated state → new force; exit code 0/≠0)
- [x] The §9.5 manual regression checklist is committed to the repository as executable-ish markup and covers in-game scenarios. (`docs\manual-regression-checklist.md`: combat 1v1/1v many/AoE/healing, rejection codes, dialogue simple/quest/closed, exploration move/interact/loot/rest/travel, resilience reconnect/restart/broken file; buying and stealth — out of scope)
- [x] The step-by-step manual "install the mod → start C# → connect Neuro" is current. (README "Starting the C# process and connecting Neuro": BG3SE server context + pointer to research, config.json with defaults, startup commands, log reference lines)