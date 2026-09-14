# 02 — BG3SE IPC Protocol

Type: research
Status: resolved
Blocked by: 01
Depended by: 07

## Answer

Research completed. **BG3SE has no native named pipe support.** Report: [ipc-named-pipes.md](../research/ipc-named-pipes.md).

### Key facts

1. **BG3SE has no native named pipe API.** The `Ext.IO` module only provides `SaveFile`/`LoadFile`. `Ext.Net` — only in-game connections, not external.
2. **LuaSocket unavailable.** `require("socket.http")` does not work — BG3SE does not include LuaSocket.
3. **Best path: file-based IPC via `Ext.IO` + JSON.**
   - BG3SE Lua writes JSON via `Ext.IO.SaveFile()`
   - The C# process reads/writes files
   - Non-blocking polling via `Ext.Timer.WaitForRealtime()` on the BG3SE side
4. **Format: JSON** — BG3SE has `Ext.Json.Stringify()`/`Ext.Json.Parse()` (fast C++ implementation), matches Neuro's JSON WebSocket.
5. **No ready-made BG3→Neuro integrations found** — this is new work.
6. **Thread safety:** use `Ext.Timer.WaitForRealtime()` for polling (not `Ext.OnNextTick`). C# process on separate threads.
7. **Upgrade path (optional):** if file-based IPC is too slow (~50–100ms), Phase 2 — a C# mod with `System.IO.Pipes` directly inside BG3SE.

### Follow-up

Formalize the channel/file name, message structure, and handshake in the final specification (ticket 01), based on file-based IPC. Document the named pipe as an upgrade path in the "Phase 2" section.

## Question

Research and define the IPC protocol over Named Pipe between the BG3SE Mod (Lua/C#) and the C# process:

1. **How does BG3SE provide Named Pipe?** Which API is used to create the named pipe server inside the BG3 Script Extender? Are there ready-made wrappers?
2. **Message format**: JSON? MsgPack? Which serialization?
3. **Message structure**: Request/Response? Event-driven? Are there correlation identifiers for matching requests and responses?
4. **Handshaking**: How does the C# process discover the BG3SE Mod? How does the session begin?
5. **Thread safety**: BG3SE Lua runs on the game's main thread. How to ensure safe access to data from the named pipe?
6. **Examples**: Are there open-source projects using named pipes in BG3SE?

Research: BG3SE documentation, GitHub repos with named pipe examples, Lua socket API in BG3SE.