# 01: File bridge + heartbeat

**What to build:** A working file channel between the Lua BG3SE mod and the C# process with a liveness signal. C# starts, reads the config (paths, timings), watches the BG3→Neuro files; the in-game Lua mod connects, writes a heartbeat (2s) and the first state; when the heartbeat goes stale (threshold 10s), C# marks the mod as unavailable (`mod_unavailable`) and keeps listening. On both sides — resilience to missed/partial writes (file window ~100–250ms polling, atomic file replacement).

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] C# `ConfigLoader` reads `config.json`, applies defaults from §4 of the spec (`heartbeat_interval_s: 2`, `heartbeat_stale_s: 10`).
- [ ] C# `IpcClient` polls the heartbeat file; if it stops updating for >10s → transition to `mod_unavailable`, log + event upward, keep polling.
- [ ] Lua mod starts under BG3SE, writes a heartbeat every 2s and the initial state file.
- [ ] End-to-end indicator: a running in-game mod is seen as "alive" by the C# process; mod unload/stop is detected as `mod_unavailable` within a ~10s threshold.
- [ ] Unit tests: config defaults; staleness computation (10s boundaries); discarding partial/empty writes.