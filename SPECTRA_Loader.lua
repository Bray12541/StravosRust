-- SPECTRA loader / current baseline v1.24.0
-- Live branch is used when it passes the version and compilation checks.
-- Recovery never runs an old build that can display unidentified teammates.
local BRANCH_URL = "https://raw.githubusercontent.com/Bray12541/StravosRust/spectra-loader/SPECTRA.lua"
local PINNED_URL = "https://raw.githubusercontent.com/Bray12541/StravosRust/1afbdc00dd711bd2b0bede46c05f7208adc0558a/SPECTRA.lua"
local MINIMUM_VERSION = "1.24.0"

if type(loadstring) ~= "function" then
    warn("[SPECTRA Loader] Your execution environment does not provide loadstring")
    return
end

local function parseVersion(source)
    if type(source) ~= "string" then return nil end
    return source:match('local%s+VERSION%s*=%s*"(%d+%.%d+%.%d+)"')
end

local function isAtLeast(version, required)
    local x,y,z = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    local a,b,c = required:match("^(%d+)%.(%d+)%.(%d+)$")
    if not (x and a) then return false end
    x,y,z=tonumber(x),tonumber(y),tonumber(z)
    a,b,c=tonumber(a),tonumber(b),tonumber(c)
    if x~=a then return x>a end
    if y~=b then return y>b end
    return z>=c
end

local function fetch(url)
    local ok,source=pcall(function() return game:HttpGet(url) end)
    if not ok or type(source)~="string" or #source<500 then
        return nil,tostring(source)
    end
    return source
end

local function getCompiledSource(url,origin)
    local source,fetchError=fetch(url)
    if not source then
        warn("[SPECTRA Loader] "..origin.." download failed: "..tostring(fetchError))
        return nil
    end
    local version=parseVersion(source)
    if not isAtLeast(version,MINIMUM_VERSION) then
        warn("[SPECTRA Loader] "..origin.." returned "..tostring(version or "no version")
            .."; minimum required is "..MINIMUM_VERSION)
        return nil
    end
    -- The third result matters: Luau's loadstring returns nil, compilerError.
    local ok,compiled,compileError=pcall(loadstring,source)
    if not ok or type(compiled)~="function" then
        local detail=not ok and compiled or (compileError or compiled)
        warn("[SPECTRA Loader] "..origin.." v"..version
            .." compilation failed: "..tostring(detail or "no compiler details"))
        return nil
    end
    return {run=compiled,version=version,origin=origin}
end

local nonce=tostring(os.time()).."-"..tostring(math.random(100000,999999))
local selected=getCompiledSource(BRANCH_URL.."?v="..nonce,"live branch")
if not selected then
    warn("[SPECTRA Loader] Live build unavailable; trying same-version pinned recovery v"..MINIMUM_VERSION)
    selected=getCompiledSource(PINNED_URL.."?v="..nonce,"pinned recovery")
end
if not selected then
    warn("[SPECTRA Loader] No valid build. Check your executor network access.")
    return
end

print("[SPECTRA Loader] Compiled v"..selected.version.." from "..selected.origin.."; starting UI")
local ok,err=pcall(selected.run)
if not ok then
    warn("[SPECTRA Loader] Startup failed in v"..selected.version..": "..tostring(err))
else
    print("[SPECTRA Loader] v"..selected.version.." finished startup without Lua exceptions")
end
