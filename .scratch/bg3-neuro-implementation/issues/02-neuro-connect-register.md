# 02: Neuro connection + registration of 17 actions

**What to build:** The C# process connects to the Neuro server (WebSocket SDK, wired to Randy in tests), performs the startup handshake, and registers a fixed set of 17 actions once (schemas §5.4: 8 combat, 1 dialogue, 8 exploration). Registration does not change at runtime (decision B): an incoming `actions/reregister_all` merely re-registers the same set. WS reconnect on drop with the correct startup → register sequence.

**Blocked by:** 01 (config: server address/port, action group name).

**Status:** done

- [x] `NeuroWebSocketClient`: connect with auto-reconnect; startup message sent and acknowledged.
- [x] All 17 actions registered with exact §5.4 schemas (JSON schemas pinned in code as a static registry).
- [x] Behavior on `actions/reregister_all`: re-registration of the same set, no duplicates.
- [x] No dynamic registration at runtime (in v1 the set is immutable); a test verifies that registration is stable across reconnects.
- [x] Integration test: connect to Randy, register, re-register.

## Summary
- `ActionRegistry` + static registry of 17 schemas from `action_schemas.json` (embedded resource).
- `NeuroWebSocketClient`: startup handshake, `actions/register`, auto-respond to `actions/reregister_all`, incoming `action` handling, camelCase serialization.
- Unit tests against FakeNeuroServer — 38/38 green.
- Integration test against real Randy (`RandyIntegrationTests`): 17 actions registered without duplicates, re-registration after `reregister_all`, an incoming `action end_turn` arrives and is answered with `actions/result` (fake action via HTTP POST `/` on a random port) — **the Randy integration suite 37/37 green** (38 unit + 37 integration, per `issues/map.md`).
- Randy patched for tests: WS/HTTP ports from env (`RANDY_WS_PORT`/`RANDY_HTTP_PORT`, default 8000/1337).