-- BG3Neuro bootstrap (client context) — тикет bg3-neuro-dialogue-click.
-- Авто-загрузка клиентской половины мода: Ext.UI (Noesis) доступен только здесь.
local ok, err = pcall(Ext.Require, "BG3NeuroClient.lua")
if ok then
    _P("[BG3Neuro] v0.8.27 loaded (client)")
else
    _P("[BG3Neuro] client bootstrap failed: " .. tostring(err))
end