--[[
    SPECTRA shared definitions (ModuleScript: ReplicatedStorage.SpectraShared)

    Single source of truth for the settings schema, defaults and limits.
    The server validates every saved value against this schema; the client
    uses it for defaults, the command center (`set`/`get`/`toggle`) and the
    "settings" listing.
]]

local Shared = {}

Shared.VERSION = "2.0.0-studio"
Shared.REMOTE_FOLDER = "SpectraRemotes"
Shared.AUTH_ATTRIBUTE = "SpectraAuthorized"      -- set on Player by the server
Shared.ASSIST_ATTRIBUTE = "SpectraAimAssistDemo" -- set on Workspace by the server

Shared.COLOR_MODES = {
    Cyan = Color3.fromRGB(82, 209, 227),
    Coral = Color3.fromRGB(250, 126, 132),
    Lime = Color3.fromRGB(127, 219, 147),
    White = Color3.fromRGB(228, 233, 239),
}
Shared.COLOR_ORDER = {"Cyan", "Coral", "Lime", "White"}

-- kind: "boolean" | "number" (min, max, step) | "enum" (options)
Shared.SCHEMA = {
    highlights      = {kind="boolean", default=true,  label="Player highlights"},
    teammates       = {kind="boolean", default=true,  label="Highlight teammates"},
    opponents       = {kind="boolean", default=true,  label="Highlight opponents (line of sight only)"},
    nameTags        = {kind="boolean", default=true,  label="Name and team tags"},
    distances       = {kind="boolean", default=true,  label="Distance in tags"},
    maxDistance     = {kind="number",  default=400, min=50, max=2000, step=25, unit=" st", label="Max tag distance"},
    fillTransparency= {kind="number",  default=70,  min=0,  max=100,  step=5,  unit="%",  label="Highlight fill transparency"},
    teamColors      = {kind="boolean", default=true,  label="Use Team colors"},
    color           = {kind="enum",    default="Cyan", options=Shared.COLOR_ORDER, label="Accent color"},
    assistEnabled   = {kind="boolean", default=false, label="Aim-assist demo"},
    assistStrength  = {kind="number",  default=35,  min=0,  max=80,   step=5,  unit="%",  label="Assist slowdown"},
    assistRadius    = {kind="number",  default=90,  min=20, max=250,  step=5,  unit=" px", label="Assist radius"},
    assistRingVisible = {kind="boolean", default=true, label="Show assist radius"},
}

function Shared.defaults()
    local out = {}
    for key, spec in pairs(Shared.SCHEMA) do out[key] = spec.default end
    return out
end

-- Returns (true, cleanValue) or (false, reason). Used by both sides.
function Shared.validate(key, value)
    local spec = Shared.SCHEMA[key]
    if not spec then return false, "unknown setting " .. tostring(key) end
    if spec.kind == "boolean" then
        if type(value) ~= "boolean" then return false, key .. " must be on/off" end
        return true, value
    elseif spec.kind == "number" then
        if type(value) ~= "number" or value ~= value then return false, key .. " must be a number" end
        local stepped = spec.min + math.floor((value - spec.min) / spec.step + 0.5) * spec.step
        return true, math.clamp(stepped, spec.min, spec.max)
    elseif spec.kind == "enum" then
        for _, option in ipairs(spec.options) do
            if option == value then return true, value end
        end
        return false, key .. " must be one of " .. table.concat(spec.options, "/")
    end
    return false, "bad schema for " .. key
end

-- Takes an untrusted table, returns a fully valid settings table.
function Shared.sanitize(raw)
    local out = Shared.defaults()
    if type(raw) ~= "table" then return out end
    for key in pairs(Shared.SCHEMA) do
        if raw[key] ~= nil then
            local ok, clean = Shared.validate(key, raw[key])
            if ok then out[key] = clean end
        end
    end
    return out
end

return Shared
