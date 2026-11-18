--[[
    SPECTRA server (Script: ServerScriptService.SpectraServer)

    - Decides who may open SPECTRA (owner, group owner, allow-list, or anyone
      while testing in Studio) and marks them with a Player attribute.
    - Publishes the aim-assist demo master switch as a Workspace attribute.
    - Loads/saves each authorized player's settings with DataStoreService,
      validating every value against ReplicatedStorage.SpectraShared.

    Studio: enable Game Settings > Security > "Enable Studio Access to API
    Services" for saving to work in Studio. Without it, settings still work
    for the session and the client reports that saving is unavailable.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = require(ReplicatedStorage:WaitForChild("SpectraShared"))

local CONFIG = {
    AllowedUserIds = {
        -- [123456789] = true,
    },
    AllowEveryoneInStudio = true,
    AimAssistDemoEnabled = true, -- master switch; client cannot enable it alone
    DataStoreName = "SPECTRA_Config_v2",
    SaveCooldown = 6,
}

Workspace:SetAttribute(Shared.ASSIST_ATTRIBUTE, CONFIG.AimAssistDemoEnabled)

local remotes = ReplicatedStorage:FindFirstChild(Shared.REMOTE_FOLDER)
if remotes then remotes:Destroy() end -- duplicate-instance prevention on script reload
remotes = Instance.new("Folder")
remotes.Name = Shared.REMOTE_FOLDER
local configRemote = Instance.new("RemoteFunction")
configRemote.Name = "Config"
configRemote.Parent = remotes
remotes.Parent = ReplicatedStorage

local store
do
    local ok, result = pcall(function()
        return DataStoreService:GetDataStore(CONFIG.DataStoreName)
    end)
    if ok then
        store = result
    else
        warn("[SPECTRA] DataStore unavailable: " .. tostring(result))
    end
end

local function isAuthorized(player)
    if RunService:IsStudio() and CONFIG.AllowEveryoneInStudio then return true end
    if CONFIG.AllowedUserIds[player.UserId] then return true end
    if game.CreatorType == Enum.CreatorType.User then
        return player.UserId == game.CreatorId
    elseif game.CreatorType == Enum.CreatorType.Group then
        local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
        return ok and rank == 255
    end
    return false
end

local lastSave = {}

local function handle(player, action, payload)
    if not player:GetAttribute(Shared.AUTH_ATTRIBUTE) then
        return {ok=false, error="not authorized"}
    end
    local key = "user_" .. player.UserId
    if action == "load" then
        if not store then return {ok=true, settings=Shared.defaults(), persisted=false, error="DataStore unavailable"} end
        local ok, data = pcall(store.GetAsync, store, key)
        if not ok then
            return {ok=true, settings=Shared.defaults(), persisted=false, error=tostring(data)}
        end
        return {ok=true, settings=Shared.sanitize(data), persisted=true}
    elseif action == "save" then
        if not store then return {ok=false, error="DataStore unavailable (enable Studio API access)"} end
        local now = os.clock()
        if lastSave[player] and now - lastSave[player] < CONFIG.SaveCooldown then
            return {ok=false, error=string.format("wait %.0fs before saving again", CONFIG.SaveCooldown - (now - lastSave[player]))}
        end
        lastSave[player] = now
        local clean = Shared.sanitize(payload)
        local ok, err = pcall(store.SetAsync, store, key, clean)
        if not ok then return {ok=false, error=tostring(err)} end
        return {ok=true, settings=clean}
    elseif action == "reset" then
        if store then
            local ok, err = pcall(store.RemoveAsync, store, key)
            if not ok then return {ok=false, error=tostring(err)} end
        end
        return {ok=true, settings=Shared.defaults()}
    end
    return {ok=false, error="unknown action"}
end

configRemote.OnServerInvoke = function(player, action, payload)
    if type(action) ~= "string" then return {ok=false, error="bad request"} end
    local ok, result = pcall(handle, player, action, payload)
    if not ok then
        warn("[SPECTRA] Config request failed: " .. tostring(result))
        return {ok=false, error="server error"}
    end
    return result
end

local function onPlayer(player)
    player:SetAttribute(Shared.AUTH_ATTRIBUTE, isAuthorized(player))
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in ipairs(Players:GetPlayers()) do onPlayer(player) end
Players.PlayerRemoving:Connect(function(player) lastSave[player] = nil end)
