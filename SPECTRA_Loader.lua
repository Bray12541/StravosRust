-- SPECTRA loader: reject stale GitHub/raw cache responses.
-- The pinned source is a guaranteed minimum build, not a separate update channel.
local BRANCH_RAW_URL = "https://raw.githubusercontent.com/Bray12541/StravosRust/spectra-loader/SPECTRA.lua"
local PINNED_RAW_URL = "https://raw.githubusercontent.com/Bray12541/StravosRust/2f4b30315544a3ccc739d1523d183cc9f5ae5e80/SPECTRA.lua"
local MINIMUM_VERSION = "1.9.2"

if type(loadstring) ~= "function" then
    warn("[SPECTRA Loader] loadstring is unavailable")
    return
end

local function sourceVersion(source)
    if type(source) ~= "string" then return nil end
    return source:match('local%s+VERSION%s*=%s*"(%d+%.%d+%.%d+)"')
end

local function versionAtLeast(version, minimum)
    local x,y,z = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    local a,b,c = tostring(minimum):match("^(%d+)%.(%d+)%.(%d+)$")
    if not (x and a) then return false end
    x,y,z = tonumber(x),tonumber(y),tonumber(z)
    a,b,c = tonumber(a),tonumber(b),tonumber(c)
    if x~=a then return x>a end
    if y~=b then return y>b end
    return z>=c
end

local function fetch(url)
    local ok, source = pcall(function() return game:HttpGet(url) end)
    if ok and type(source)=="string" and #source>500 then
        return source
    end
    return nil, tostring(source)
end

local nonce = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999))
local source, errorMessage = fetch(BRANCH_RAW_URL .. "?v=" .. nonce)
local version = sourceVersion(source)
local origin = "live branch"

if not versionAtLeast(version, MINIMUM_VERSION) then
    warn("[SPECTRA Loader] Branch response was " .. tostring(version or "missing")
        .. " (minimum " .. MINIMUM_VERSION .. "); trying pinned source")
    source, errorMessage = fetch(PINNED_RAW_URL .. "?v=" .. nonce)
    version = sourceVersion(source)
    origin = "pinned recovery"
end

if not source or not versionAtLeast(version, MINIMUM_VERSION) then
    warn("[SPECTRA Loader] No valid current build fetched. "
        .. "Last source=" .. tostring(version) .. " | fetch error=" .. tostring(errorMessage))
    return
end

print("[SPECTRA Loader] Executing v" .. version .. " via " .. origin)

-- Luau loadstring returns (nil, compileError) for syntax errors.
-- pcall preserves both values; earlier loaders discarded compileError and
-- misleadingly displayed "Compilation failed: nil".
local compileOk, compiled, compileError = pcall(loadstring, source)
if not compileOk or type(compiled)~="function" then
    local reason = not compileOk and compiled or (compileError or compiled)
    warn("[SPECTRA Loader] Compilation failed in v" .. tostring(version)
        .. ": " .. tostring(reason or "executor did not provide an error"))
    return
end
local runOk, runError = pcall(compiled)
if not runOk then
    warn("[SPECTRA Loader] Runtime error: " .. tostring(runError))
end
