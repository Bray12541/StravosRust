-- SPECTRA remote loader (version-independent)
-- Runs the latest SPECTRA source from the spectra-loader GitHub branch.
local RAW_URL = "https://raw.githubusercontent.com/Bray12541/StravosRust/spectra-loader/SPECTRA.lua"

if type(loadstring) ~= "function" then
    warn("[SPECTRA] loadstring is unavailable in this environment.")
    return
end

local fetched, source = pcall(function()
    return game:HttpGet(RAW_URL)
end)
if not fetched or type(source) ~= "string" or #source == 0 then
    warn("[SPECTRA] Could not fetch Lua source: " .. tostring(source))
    return
end

local compileOk, compiled = pcall(loadstring, source)
if not compileOk or type(compiled) ~= "function" then
    warn("[SPECTRA] Lua compilation failed: " .. tostring(compiled))
    return
end

local runOk, runError = pcall(compiled)
if not runOk then
    warn("[SPECTRA] Runtime error: " .. tostring(runError))
end
