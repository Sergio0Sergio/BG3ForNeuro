# Quick Start

Get BG3Neuro running in 5 minutes.

## Prerequisites

1. **Baldur's Gate 3** installed and up to date
2. **BG3 Script Extender** — download from [norbyte/bg3se](https://github.com/norbyte/bg3se/releases), run `ScriptExtenderSetup.exe`
3. **.NET 9 SDK** — download from [dotnet.microsoft.com](https://dotnet.microsoft.com/download/dotnet/9.0)
4. **Neuro** or **Randy** — from [VedalAI/neuro-sdk](https://github.com/VedalAI/neuro-sdk)

## Step 1: Install the Mod

Copy the PAK file to the BG3 Mods folder:

```
%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\BG3Neuro.pak
```

Verify the mod is listed in `modsettings.lsx` (same folder's parent):

```xml
<!-- In <ModuleOrder> section: -->
<node id="Module" UUID="...BG3Neuro..." />

<!-- In <Modules> section: -->
<node id="Module" UUID="...BG3Neuro..." Version4="..." />
```

If not listed, add both entries manually. The mod MUST appear in both `<ModuleOrder>` and `<Modules>`.

## Step 2: Configure

Create a `config.json` file (in the repo root or any directory):

```json
{
  "neuro": {
    "ws_url": "ws://localhost:8000"
  },
  "game": {
    "controlledPartySize": 1
  }
}
```

Minimal config — all other values use defaults. See [README.md](README.md#configuration) for full options.

## Step 3: Start BG3

Launch Baldur's Gate 3 normally. Load a save (use **Continue** from the main menu for best results — this ensures the mod's server-side logic loads correctly).

Wait for the mod to initialize. The IPC directory is created at:

```
%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro\
```

You should see `heartbeat.json` appearing there every ~2 seconds.

## Step 4: Start the C# Process

Open a terminal in the repo directory and run:

```powershell
dotnet run --project src\BG3Neuro.App -- config.json
```

Or use the compiled executable:

```powershell
src\BG3Neuro.App\bin\Debug\net9.0\BG3Neuro.App.exe config.json
```

Expected output:
```
[ipc] mod: Unknown → Alive
[neuro] connected
[neuro] session: <session_id>
```

## Step 5: Start Neuro (or Randy)

**Neuro:** Follow the instructions from [neuro-sdk](https://github.com/VedalAI/neuro-sdk).

**Randy (local emulator):**

```powershell
cd neuro-sdk\neuro-sdk\Randy
npm install
npx tsx src/index.ts
```

Randy listens on `ws://localhost:8000` by default.

## Verification

Once all three are running:

1. **Heartbeat** — `heartbeat.json` updates every ~2s in the IPC directory
2. **State** — `bg3_to_neuro.json` appears when the game enters combat/dialog/exploration
3. **Actions** — Neuro receives state, makes decisions, writes `action_*.json`
4. **Results** — `result_*.json` appears with success/failure after each action

Enter combat in BG3 — Neuro should receive the combat state and start making decisions.

## Troubleshooting

### Mod not loading

- Check `modsettings.lsx` — BG3Neuro must be in both `<ModuleOrder>` and `<Modules>`
- Verify `BG3Neuro.pak` is in the Mods folder
- Check SE logs at `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\`

### Heartbeat not appearing

- The mod only writes heartbeat after the game fully loads (wait for the main menu or a save to load)
- Make sure Script Extender is installed correctly

### C# process can't connect

- Check that `ws_url` in `config.json` matches your Neuro/Randy address
- Verify Neuro/Randy is running and listening on the expected port
- The process will auto-reconnect every 3 seconds

### Actions failing

- Check the SE log for mod-side errors
- Ensure the game is in English (the mod expects English game text)
- Check `result_*.json` for error details

## Next Steps

- [Developer Guide](DEVELOPER.md) — architecture, IPC protocol, adding actions
- [Full Specification](BG3_Neuro_Spec.md) — detailed architecture and protocol docs
