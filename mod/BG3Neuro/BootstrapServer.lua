-- BG3Neuro bootstrap (server context) — тикеты 01 + 03-09
local ok, err = pcall(Ext.Require, "BG3Neuro.lua")
if ok then
    _P("[BG3Neuro] v0.7.0 loaded (server)")
else
    _P("[BG3Neuro] bootstrap failed: " .. tostring(err))
end