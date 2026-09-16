-- BG3Neuro bootstrap (server context)
local ok, err = pcall(Ext.Require, "BG3Neuro.lua")
if ok then
    _P("[BG3Neuro] v" .. tostring(_G["BG3Neuro_VERSION"] or "?") .. " loaded (server)")
else
    _P("[BG3Neuro] bootstrap failed: " .. tostring(err))
end