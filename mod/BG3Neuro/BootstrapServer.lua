-- BG3Neuro bootstrap (server context)
local ok, err = pcall(Ext.Require, "BG3Neuro.lua")
if ok then
    _P("[BG3Neuro] v0.8.27 loaded (server)")
else
    _P("[BG3Neuro] bootstrap failed: " .. tostring(err))
end