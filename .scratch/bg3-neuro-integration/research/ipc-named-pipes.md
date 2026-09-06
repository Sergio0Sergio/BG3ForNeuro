# Research: Named Pipes IPC between BG3SE and Standalone C# Process

Date: 2026-09-04

## 1. BG3SE Named Pipe API

### Finding: BG3SE does NOT have built-in named pipe support

BG3SE (Norbyte's Script Extender for BG3) does **not** provide any native Lua API for named pipes. After examining the full API documentation (`Docs/API.md`, 1936 lines), the IO module (`Ext.IO`) provides only:

```lua
-- Ext.IO Methods (Server + Client)
Ext.IO.LoadFile(path, [context])       -- Read file contents
Ext.IO.SaveFile(path, content)         -- Write file (creates parent dirs)
Ext.IO.AddPathOverride(original, new)  -- Redirect game file access
Ext.IO.GetPathOverride(path)           -- Query active override
```

There is **no** `Ext.IO.CreateNamedPipe`, `Ext.IO.ConnectPipe`, or any pipe-related API.

**Source:** [BG3SE API.md - IO Section](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#io---extio)

### Networking API: In-game only

BG3SE's networking (`Ext.Net`) is explicitly limited to server↔client communication within the game:

> "Note that there is no external networking capability in the Script Extender. SE mods cannot communicate with external servers or clients."

The `NetChannel` API and legacy `NetMessage` API both work only between the game's server and client(s) — not with external processes.

**Source:** [BG3SE API.md - Networking](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#networking)

### LuaSocket: NOT available

LuaSocket is **not** bundled with BG3SE. Issue [#479](https://github.com/Norbyte/bg3se/issues/479) confirms that `require("socket.http")` fails because BG3SE treats it as a mod script path rather than a Lua library. The extender does not ship with LuaSocket or any third-party networking libraries.

### Lua Debugger: Uses TCP, but hardcoded

The BG3SE Lua Debugger (`LuaDebugger/`) uses TCP sockets for the debugger connection, but this is internal C++ code, not exposed to Lua mods. It confirms that TCP networking is technically possible from within the extender's C++ layer, but there's no Lua-accessible socket API.

---

## 2. Alternatives if No Native Named Pipe Support

### 2.1 File-Based IPC (RECOMMENDED as primary approach)

**This is the most practical and battle-tested approach.** BG3SE provides synchronous file read/write via `Ext.IO`, and the game runs on Windows where file I/O is fast.

**Protocol:**
- Use a dedicated directory for IPC, e.g. `%localappdata%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\`
- Two files for bidirectional communication:
  - `bg3_to_neuro.json` — BG3SE writes, C# process reads
  - `neuro_to_bg3.json` — C# process writes, BG3SE reads
- Use file locks or atomic write patterns (write to `.tmp`, rename) to prevent partial reads

**Lua side (BG3SE):**
```lua
local IPC_DIR = "BG3Neuro"

-- Write state to file
local function sendState(state)
    local json = Ext.Json.Stringify(state)
    Ext.IO.SaveFile(IPC_DIR .. "/bg3_to_neuro.json", json)
end

-- Read command from file
local function readCommand()
    local content = Ext.IO.LoadFile(IPC_DIR .. "/neuro_to_bg3.json")
    if content and content ~= "" then
        -- Delete after reading to signal processed
        Ext.IO.SaveFile(IPC_DIR .. "/neuro_to_bg3.json", "")
        return Ext.Json.Parse(content)
    end
    return nil
end
```

**C# side:**
```csharp
using System.IO;

class FileBasedIpcClient
{
    private readonly string _ipcDir;
    private FileSystemWatcher _watcher;
    
    public FileBasedIpcClient(string ipcDir)
    {
        _ipcDir = ipcDir;
        Directory.CreateDirectory(ipcDir);
        
        // Watch for BG3 output
        _watcher = new FileSystemWatcher(ipcDir, "bg3_to_neuro.json");
        _watcher.Changed += OnBg3Output;
        _watcher.EnableRaisingEvents = true;
    }
    
    public void SendCommand(string commandJson)
    {
        File.WriteAllText(
            Path.Combine(_ipcDir, "neuro_to_bg3.json"),
            commandJson);
    }
}
```

**Pros:** No external dependencies, works in BG3SE sandbox, synchronous operations don't block game thread significantly for small files.
**Cons:** Not real-time (polling/watcher latency ~50-100ms), not suitable for high-frequency messages.

### 2.2 Named Pipe via C# (RECOMMENDED as primary approach)

Since BG3SE Lua doesn't support named pipes, **reverse the architecture**: make the **C# process** the named pipe server, and have BG3SE Lua write to files that trigger C# to read/send.

**Alternative: C# Named Pipe Server + BG3SE File Polling**

```
C# Process                    BG3SE Mod (Lua)
   │                              │
   ├─ NamedPipeServer (listens)   ├─ Ext.IO.SaveFile (writes state)
   │   │                          │
   │   ├─ Reads from file ◄───────┤
   │   │                          │
   │   └─ Writes to file ────────►├─ Ext.IO.LoadFile (reads commands)
   │                              │
   └─ WebSocket to Neuro          └─ Executes actions via Osi.*
```

### 2.3 HTTP Localhost

**Not possible** — BG3SE Lua cannot make HTTP requests (no LuaSocket, no HTTP API). The only networking is the in-game NetChannel/NetMessage API.

### 2.4 C# Thread Inside BG3SE

BG3SE supports C# mods via the Roslyn scripting API, but this is a separate, more complex integration path. The C# mod would run inside the game process and could use `System.IO.Pipes.NamedPipeClientStream` directly, but this requires:
- Writing a C# mod (not just Lua)
- Managing the C# mod lifecycle within BG3SE
- The C# code runs on the game thread (same threading concerns)

This is viable but adds significant complexity. **Recommend starting with file-based IPC and upgrading later.**

### 2.5 Summary of Alternatives

| Approach | Feasibility | Latency | Complexity |
|----------|-------------|---------|------------|
| **File-based IPC** | ✅ High | ~50-100ms | Low |
| **Named Pipe (C# server)** | ✅ High | ~1-5ms | Medium |
| **C# mod in BG3SE** | ⚠️ Medium | ~1-5ms | High |
| **LuaSocket** | ❌ Not available | N/A | N/A |
| **HTTP localhost** | ❌ Not available | N/A | N/A |

---

## 3. Message Format

### JSON is the best choice

BG3SE has **built-in JSON support** with fast C++ implementation:

```lua
-- Serialize Lua table to JSON
local json = Ext.Json.Stringify(state)

-- Parse JSON to Lua table
local state = Ext.Json.Parse(json)
```

**Source:** [BG3SE API.md - JSON Support](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#json-support---extjson)

The Neuro SDK specification also uses JSON over WebSocket:
```json
{
    "command": "context",
    "game": "Baldur's Gate 3",
    "data": { "message": "...", "silent": false }
}
```

**Recommendation:** Use JSON throughout the pipeline:
1. BG3SE Lua → `Ext.Json.Stringify()` → Write to file/pipe
2. C# reads, parses JSON, forwards to Neuro WebSocket (also JSON)
3. C# receives JSON from Neuro, writes to file/pipe
4. BG3SE Lua → `Ext.Json.Parse()` → Executes actions

JSON is human-readable (debuggable), has native support on both sides, and matches the Neuro SDK format.

---

## 4. Existing Projects

### 4.1 BG3SE Lua Debugger (Internal Reference)
- Uses TCP sockets for debugger ↔ extender communication
- C++ code, not accessible from Lua mods
- Confirms networking is possible from the C++ layer

### 4.2 SteelSeries Lights Mod (Issue #479)
- Attempted to use `socket.http` for HTTP requests to SteelSeries Game Engine
- Failed because LuaSocket is not available in BG3SE
- Confirms: no external networking from Lua

### 4.3 No Known Open-Source BG3 Neuro Integration
- GitHub search for "bg3 neuro websocket extender" returns **0 results**
- GitHub search for "baldurs gate 3 mod external process communication" returns **0 relevant results**
- This appears to be a novel integration effort

### 4.4 BG3SE Networking Mods
- Mods like MCM (Mod Configuration Menu) use `NetChannel` API for server↔client sync
- No mods found using named pipes or external IPC

---

## 5. Thread Safety

### Critical Constraint

BG3SE Lua runs on the **game's main thread**. Blocking operations will freeze the game.

### Safe Patterns

**1. Poll on timer, not on tick:**
```lua
-- BAD: Polls every tick (16ms), will lag the game
Ext.Events.SessionLoaded:Subscribe(function()
    Ext.OnNextTick(function()
        readCommand()  -- This blocks!
    end)
end)

-- GOOD: Poll every 500ms using real-time timer
Ext.Timer.WaitForRealtime(500, function()
    readCommand()  -- Brief block, acceptable
    Ext.Timer.WaitForRealtime(500, pollLoop)  -- Schedule next poll
end)

-- Or use a persistent polling loop
local function pollLoop()
    local cmd = readCommand()
    if cmd then
        executeCommand(cmd)
    end
    Ext.Timer.WaitForRealtime(100, pollLoop)  -- 100ms interval
end
Ext.Timer.WaitForRealtime(100, pollLoop)  -- Start polling
```

**2. Keep file operations small and atomic:**
```lua
-- Write state atomically (write to temp, then rename is not possible in BG3SE,
-- but SaveFile creates parent dirs and writes atomically for small files)
local function sendState(state)
    local json = Ext.Json.Stringify(state)
    -- Ext.IO.SaveFile is synchronous but fast for small payloads
    Ext.IO.SaveFile("BG3Neuro/bg3_to_neuro.json", json)
end
```

**3. Use non-blocking read patterns:**
```lua
-- Non-blocking: check if file exists and has content
local function tryReadCommand()
    local content = Ext.IO.LoadFile("BG3Neuro/neuro_to_bg3.json")
    if content and content ~= "" then
        Ext.IO.SaveFile("BG3Neuro/neuro_to_bg3.json", "")  -- Clear
        return Ext.Json.Parse(content)
    end
    return nil
end
```

**4. Background thread for C# named pipe (if upgrading from file-based):**
```csharp
// C# Named Pipe Server runs on background thread
var pipeServer = new NamedPipeServerStream(
    "BG3Neuro",
    PipeDirection.InOut,
    1,
    PipeTransmissionMode.Message);

await pipeServer.WaitForConnectionAsync();

// Read/write on background thread, never block game thread
var buffer = new byte[4096];
int bytesRead = await pipeServer.ReadAsync(buffer, 0, buffer.Length);
```

### Thread Safety Summary

| Operation | Thread | Safe? | Notes |
|-----------|--------|-------|-------|
| `Ext.IO.SaveFile()` | Game main | ✅ | Fast for small files, synchronous |
| `Ext.IO.LoadFile()` | Game main | ✅ | Fast for small files, synchronous |
| `Ext.Json.Stringify()` | Game main | ✅ | Fast C++ implementation |
| `Ext.Json.Parse()` | Game main | ✅ | Fast C++ implementation |
| `Ext.Timer.WaitForRealtime()` | Game main | ✅ | Non-blocking timer |
| `Ext.Events.*:Subscribe()` | Game main | ✅ | Event-driven, non-blocking |
| Named pipe server | Background | ✅ | C# process, separate from game |
| File watcher | Background | ✅ | C# FileSystemWatcher, separate thread |

---

## 6. Recommended Architecture

### Phase 1: File-Based IPC (Quick to implement)

```
┌─────────────────────────┐     File System     ┌─────────────────────────┐
│    BG3SE Mod (Lua)      │ ◄═════════════════► │   C# Standalone Process │
│                         │                     │                         │
│  BootstrapServer.lua    │  bg3_to_neuro.json  │   NeuroWebSocketClient  │
│  ├─ StateExtractor      │  neuro_to_bg3.json  │   ├─ FileWatcher        │
│  ├─ ActionExecutor      │                     │   ├─ StateSerializer    │
│  └─ IPC File Handler    │                     │   └─ ActionRouter       │
│                         │                     │                         │
│  Ext.IO.SaveFile()      │                     │   FileSystemWatcher     │
│  Ext.IO.LoadFile()      │                     │   File.ReadAllText()    │
│  Ext.Json.Stringify()   │                     │   File.WriteAllText()   │
│  Ext.Json.Parse()       │                     │   WebSocketClient       │
│  Ext.Timer.WaitForReal  │                     │                         │
└─────────────────────────┘                     └─────────────────────────┘
```

### Phase 2: Named Pipe IPC (If latency is too high)

```
┌─────────────────────────┐     Named Pipe      ┌─────────────────────────┐
│    BG3SE Mod (Lua)      │ ◄═════════════════► │   C# Standalone Process │
│                         │  "BG3Neuro"          │                         │
│  BootstrapServer.lua    │                     │   NeuroWebSocketClient  │
│  ├─ StateExtractor      │                     │   ├─ NamedPipeServer    │
│  ├─ ActionExecutor      │                     │   ├─ StateSerializer    │
│  └─ IPC Handler         │                     │   └─ ActionRouter       │
│                         │                     │                         │
│  Ext.IO.SaveFile()      │  (BG3SE writes to   │   NamedPipeServerStream │
│  Ext.IO.LoadFile()      │   file, C# reads    │   ReadAsync/WriteAsync  │
│                         │   pipe from file)   │                         │
└─────────────────────────┘                     └─────────────────────────┘
```

---

## 7. Key API References

| API | Purpose | Source |
|-----|---------|--------|
| `Ext.IO.SaveFile(path, content)` | Write files from BG3SE | [API.md#io](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#io---extio) |
| `Ext.IO.LoadFile(path, [context])` | Read files from BG3SE | [API.md#io](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#io---extio) |
| `Ext.Json.Stringify(obj)` | Lua table → JSON | [API.md#json](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#json-support---extjson) |
| `Ext.Json.Parse(json)` | JSON → Lua table | [API.md#json](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#json-support---extjson) |
| `Ext.Timer.WaitForRealtime(ms, cb)` | Non-blocking timer | [API.md#timers](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#timers---exttimer) |
| `Ext.Events.*` | Event subscriptions | [API.md#events](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#se-events) |
| `Osi.*` | Osiris game functions | [API.md#osiris](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#calling-osiris-from-lua) |

---

## 8. Open Questions

1. **File locking on Windows:** Can BG3SE Lua and C# process safely read/write the same file simultaneously? Use atomic patterns (write-empty-after-read) to avoid races.

2. **Polling frequency tradeoff:** 100ms polling = responsive but wastes CPU. 500ms = low CPU but sluggish. Consider event-driven file watching on C# side, polling on BG3SE side.

3. **State size:** BG3SE entities can have large component trees. Limit serialized state to essential fields to keep file I/O fast.

4. **C# mod alternative:** If file-based IPC proves too slow, consider writing a C# mod that uses `System.IO.Pipes` directly inside BG3SE. This requires the C# scripting feature flag and more complex mod setup.
