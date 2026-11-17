--[[
    SPECTRA / PHASE 1                         v1.6.2
    Standalone client-side Luau player-visualization overlay.
    No loadstring, getgc, memory scans, game hooks or remote scripts.
    RSHIFT: hide/show menu | F8: debug | HOME: center | Unload: header or Ctrl+End

    Character data must already be replicated to the client. Custom game
    replication stores that do not expose renderable Workspace models will
    not be resolved. No server authority is obtained by this script.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[SPECTRA] LocalPlayer unavailable")
    return
end

local ENV = _G
if type(getgenv) == "function" then
    local ok, e = pcall(getgenv)
    if ok and type(e) == "table" then ENV = e end
end
if type(ENV.SPECTRA_PHASE1_UNLOAD) == "function" then
    pcall(ENV.SPECTRA_PHASE1_UNLOAD)
end

local VERSION = "1.6.2"
local alive = true
local connections = {}
local tracked = {}
local widgets = {}
local logs = {}
local targets = {}
local lastSource = "Not scanned"
local lastScanDetails = "Not scanned"
local stats = {discovered=0, matched=0, anonymous=0, enemyGroups=0, unknownTeams=0, teammates=0, skeletonRigs=0, approxSkeletons=0, rejected=0, rendered=0, fps=0, scans=0, drawn=0, sample=0, frameMs=0}
local overlayGui, menuGui, overlayLayer, window, statusText, logBox, debugSummary, menu
local focusedTab = "ESP"
local tabs = {}
local toggleRefreshers = {}
local function refreshAllToggles()
    for _, refresh in ipairs(toggleRefreshers) do refresh() end
end
local scanAccumulator, renderAccumulator, statAccumulator = 10, 0, 0
local MAX_DISTANCE = 1000
local UPDATE_HZ = 50
local UPDATE_PERIOD = 1 / UPDATE_HZ

local C = {
    base = Color3.fromRGB(21, 24, 29),
    sidebar = Color3.fromRGB(25, 29, 35),
    panel = Color3.fromRGB(31, 35, 42),
    panel2 = Color3.fromRGB(37, 42, 50),
    border = Color3.fromRGB(54, 61, 71),
    muted = Color3.fromRGB(137, 149, 164),
    white = Color3.fromRGB(235, 239, 245),
    accent = Color3.fromRGB(73, 194, 216),
    green = Color3.fromRGB(94, 205, 151),
    red = Color3.fromRGB(242, 107, 113),
    orange = Color3.fromRGB(231, 182, 112)
}
local COLOR_MODES = {
    Cyan = Color3.fromRGB(82, 209, 227),
    Coral = Color3.fromRGB(250, 126, 132),
    Lime = Color3.fromRGB(127, 219, 147),
    White = Color3.fromRGB(228, 233, 239)
}
local state = {
    enabled = true,
    distances = true,
    tracers = false,
    skeleton = false,
    highlights = false,
    color = "Cyan"
}

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections+1] = connection
    return connection
end
local function create(className, properties, parent)
    local obj = Instance.new(className)
    for k, v in pairs(properties or {}) do obj[k] = v end
    if parent then obj.Parent = parent end
    return obj
end
local function round(parent, radius)
    create("UICorner", {CornerRadius=UDim.new(0, radius or 6)}, parent)
end
local function outline(parent, color, transparency)
    create("UIStroke", {Color=color or C.border, Transparency=transparency or 0, Thickness=1}, parent)
end
local function textLabel(parent, text, size, color, bold)
    return create("TextLabel", {
        BackgroundTransparency=1, Text=text or "", Font=bold and Enum.Font.GothamMedium or Enum.Font.Gotham,
        TextSize=size or 12, TextColor3=color or C.white, TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Center, TextTruncate=Enum.TextTruncate.AtEnd,
        BorderSizePixel=0
    }, parent)
end
local function log(level, message)
    local entry = string.format("[%s] [%-5s] %s", os.date("%H:%M:%S"), level, tostring(message))
    logs[#logs+1] = entry
    if #logs > 140 then table.remove(logs, 1) end
    if logBox and logBox.Parent then logBox.Text = table.concat(logs, "\n") end
    if level == "ERROR" then warn("[SPECTRA] " .. message) end
end
local function safeCall(label, callback)
    local ok, err = pcall(callback)
    if not ok then log("ERROR", label .. ": " .. tostring(err)) end
    return ok
end
local function safeParent(gui)
    if type(gethui) == "function" then
        local ok, obj = pcall(gethui)
        if ok and typeof(obj) == "Instance" then
            local worked = pcall(function() gui.Parent = obj end)
            if worked then return true end
        end
    end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then
        local ok, found = pcall(function() return LocalPlayer:WaitForChild("PlayerGui", 5) end)
        if ok then pg = found end
    end
    if pg then
        local worked = pcall(function() gui.Parent = pg end)
        if worked then return true end
    end
    local ok = pcall(function() gui.Parent = game:GetService("CoreGui") end)
    return ok
end
-- Never equate two default TeamColor values with confirmed teammates.
-- Use Team objects when available; fall back only to unique non-neutral team
-- colors that correspond to actual Team objects in the experience.
local TeamsService = game:GetService("Teams")
local function getPlayerRelation(player)
    if not player or player == LocalPlayer then return "ally" end
    local mine, theirs = LocalPlayer.Team, player.Team
    if mine and theirs then
        return mine == theirs and "ally" or "enemy"
    end
    if not LocalPlayer.Neutral and not player.Neutral then
        local mineColor, otherColor = LocalPlayer.TeamColor, player.TeamColor
        local knownMine, knownOther = false, false
        for _, team in ipairs(TeamsService:GetTeams()) do
            if team.TeamColor == mineColor then knownMine = true end
            if team.TeamColor == otherColor then knownOther = true end
        end
        if knownMine and knownOther then
            return mineColor == otherColor and "ally" or "enemy"
        end
    end
    return "unknown"
end
local function isTeammate(player)
    return getPlayerRelation(player) ~= "enemy"
end
-- Only treat an anonymous Workspace model as an enemy if its parent group
-- or its own metadata explicitly identifies a real opposing Roblox Team.
local calibratedEnemyGroup = nil
local calibrationMode = "none" -- none/manual/automatic
local calibrationMessage = "Automatic identification pending"
local watchedRoot = nil
local watcherConnections = {}
local scanDirty = false
local groupEvents = 0
local function getTeamGroup(object)
    local root = Workspace:FindFirstChild("Players")
    if not root or not object then return nil end
    local current = object
    while current and current ~= root do
        if current.Parent == root and current:IsA("Folder") then
            return current
        end
        current = current.Parent
    end
    return nil
end
local function clearCalibration()
    calibratedEnemyGroup = nil
    calibrationMode = "none"
    calibrationMessage = "Automatic identification pending"
    scanDirty = true
    scanAccumulator = 10
end
-- Native Player.Team is absent in this game. A manually confirmed opposing
-- Workspace.Players group can still be classified without trusting random rig names.
local function getGroupRelation(model)
    local group = getTeamGroup(model)
    local root = Workspace:FindFirstChild("Players")
    if calibratedEnemyGroup then
        if not root or calibratedEnemyGroup.Parent ~= root then
            clearCalibration()
            calibrationMessage = "Groups changed - calibrate again with F6"
        elseif group then
            return group == calibratedEnemyGroup and "enemy" or "ally"
        end
    end
    local mine = LocalPlayer.Team
    if not mine then return "unknown" end
    local current = model
    for _ = 1, 5 do
        if not current or current == Workspace then break end
        local function matchTeam(candidate)
            if typeof(candidate) ~= "string" or candidate == "" then return nil end
            local team = TeamsService:FindFirstChild(candidate)
            if team and team:IsA("Team") then
                return team == mine and "ally" or "enemy"
            end
            return nil
        end
        for _, field in ipairs({"Team", "TeamName", "TeamId"}) do
            local relation = matchTeam(current:GetAttribute(field))
            if relation then return relation end
        end
        local relation = matchTeam(current.Name)
        if relation then return relation end
        current = current.Parent
    end
    return "unknown"
end
local function markerColor()
    return COLOR_MODES[state.color] or C.accent
end
local function put(line, x1, y1, x2, y2, color, width)
    local dx, dy = x2-x1, y2-y1
    line.Visible = true
    line.AnchorPoint = Vector2.new(0.5,0.5)
    line.Position = UDim2.fromOffset((x1+x2)/2, (y1+y2)/2)
    line.Size = UDim2.fromOffset(math.sqrt(dx*dx+dy*dy), width or 1)
    line.Rotation = math.deg(math.atan2(dy, dx))
    line.BackgroundColor3 = color
end
local function hideWidget(w)
    if not w then return end
    w.root.Visible = false
    if w.highlight then w.highlight.Enabled = false end
end
local function destroyWidget(key)
    local w = widgets[key]
    if not w then return end
    if w.highlight then w.highlight:Destroy() end
    if w.root then w.root:Destroy() end
    widgets[key] = nil
end
local function makeLine(parent)
    return create("Frame", {Visible=false, BorderSizePixel=0, BackgroundColor3=C.accent, ZIndex=20}, parent)
end
local MAX_SKELETON_LINES = 32
local bonePairs = {
    {"Head","UpperTorso"}, {"UpperTorso","LowerTorso"},
    {"UpperTorso","LeftUpperArm"}, {"LeftUpperArm","LeftLowerArm"}, {"LeftLowerArm","LeftHand"},
    {"UpperTorso","RightUpperArm"}, {"RightUpperArm","RightLowerArm"}, {"RightLowerArm","RightHand"},
    {"LowerTorso","LeftUpperLeg"}, {"LeftUpperLeg","LeftLowerLeg"}, {"LeftLowerLeg","LeftFoot"},
    {"LowerTorso","RightUpperLeg"}, {"RightUpperLeg","RightLowerLeg"}, {"RightLowerLeg","RightFoot"},
    {"Head","Torso"}, {"Torso","Left Arm"}, {"Torso","Right Arm"},
    {"Torso","Left Leg"}, {"Torso","Right Leg"}
}
-- Built at discovery time, not every frame. Motor6D connections handle
-- renamed body parts; fallback pairs cover traditional R6/R15 rigs.
local function collectSkeletonSegments(model)
    local segments = {}
    local function add(a, b)
        if a and b and a ~= b and #segments < MAX_SKELETON_LINES then
            segments[#segments+1] = {a, b}
        end
    end
    for _, inst in ipairs(model:GetDescendants()) do
        if #segments >= MAX_SKELETON_LINES then break end
        if inst:IsA("Motor6D") then
            local a, b = inst.Part0, inst.Part1
            if a and b and a:IsDescendantOf(model) and b:IsDescendantOf(model)
                and not inst.Name:lower():find("root") then
                add(a, b)
            end
        elseif inst:IsA("Bone") and inst.Parent and inst.Parent:IsA("Bone") then
            add(inst.Parent, inst)
        end
    end
    if #segments == 0 then
        for _, pair in ipairs(bonePairs) do
            local a = model:FindFirstChild(pair[1], true)
            local b = model:FindFirstChild(pair[2], true)
            if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
                add(a, b)
            end
        end
    end
    return segments
end
local function newWidget(key)
    local w = {root = create("Frame", {
        Name="Marker", BackgroundTransparency=1, BorderSizePixel=0,
        Position=UDim2.fromOffset(0,0), Size=UDim2.fromScale(1,1), ZIndex=10
    }, overlayLayer), skeleton={}}
    w.tracer = makeLine(w.root)
    for i=1,MAX_SKELETON_LINES do w.skeleton[i] = makeLine(w.root) end
    w.distance = textLabel(w.root, "", 11, C.white)
    w.distance.TextXAlignment = Enum.TextXAlignment.Center
    w.distance.TextStrokeTransparency = 0.45
    w.distance.ZIndex = 22
    widgets[key] = w
    return w
end
local function getRoot(model)
    if not model or not model:IsA("Model") then return nil end
    if model.PrimaryPart and model.PrimaryPart.Parent then return model.PrimaryPart end
    for _, n in ipairs({"HumanoidRootPart", "Torso", "UpperTorso", "Head", "Root", "Main"}) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
    end
    local count = 0
    for _, p in ipairs(model:GetChildren()) do
        if p:IsA("BasePart") then
            count += 1
            if count >= 3 then return p end
        end
    end
    -- Some custom rigs store body pieces one or two levels below the model.
    -- Search only within this model; geometry validation rejects tiny props.
    local descendantPart = model:FindFirstChildWhichIsA("BasePart", true)
    return descendantPart
end
local function validModel(model)
    if not model or not model.Parent or not model:IsA("Model") then return false end
    local root = getRoot(model)
    if not root then return false end
    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    if not ok then return false end
    -- Reject common weapon and environmental models and implausible bounds.
    if size.X < 0.8 or size.Y < 2.2 or size.Z < 0.5 then return false end
    if size.X > 12 or size.Y > 14 or size.Z > 12 then return false end
    return true, root, cf, size
end
local function identifyPlayer(model)
    local all = Players:GetPlayers()
    local function resolve(value)
        if typeof(value) == "Instance" then
            if value:IsA("Player") then return value end
            if value:IsA("ObjectValue") then return resolve(value.Value) end
            if value:IsA("StringValue") or value:IsA("IntValue") or value:IsA("NumberValue") then
                value = value.Value
            else
                return nil
            end
        end
        if value == nil then return nil end
        local candidate = tostring(value)
        for _, player in ipairs(all) do
            if candidate == player.Name or candidate == tostring(player.UserId) then
                return player
            end
        end
        return nil
    end
    for _, player in ipairs(all) do
        if player.Character and (player.Character == model or model:IsDescendantOf(player.Character)) then
            return player
        end
    end
    local candidate = resolve(model.Name)
    if candidate then return candidate end
    for _, attributeName in ipairs({"PlayerName","Username","PlayerUserId","UserId","Owner","OwnerId","Player"}) do
        candidate = resolve(model:GetAttribute(attributeName))
        if candidate then return candidate end
    end
    -- Inspect only direct ownership values and immediate container attributes,
    -- not arbitrary deep descendants or expensive whole-workspace searches.
    local parent = model.Parent
    if parent and parent ~= Workspace then
        for _, attributeName in ipairs({"PlayerName","Username","PlayerUserId","UserId","OwnerId"}) do
            candidate = resolve(parent:GetAttribute(attributeName))
            if candidate then return candidate end
        end
    end
    for _, child in ipairs(model:GetChildren()) do
        if child:IsA("ObjectValue") or child:IsA("StringValue") or child:IsA("IntValue") then
            if child.Name == "Player" or child.Name == "Owner" or child.Name == "PlayerName"
                or child.Name == "UserId" or child.Name == "PlayerUserId" then
                candidate = resolve(child)
                if candidate then return candidate end
            end
        end
    end
    return nil
end
-- Automatic identification without F6 is safe only when one remote
-- character exists in a two-player server. Larger games expose no team
-- identities, so this never guesses which of two groups is hostile.
local function autoResolveEnemyGroup()
    local players = Players:GetPlayers()
    if calibrationMode == "manual" and calibratedEnemyGroup then return end
    if #players ~= 2 then
        if calibrationMode == "automatic" then
            calibratedEnemyGroup = nil
            calibrationMode = "none"
        end
        if calibrationMode == "none" then
            calibrationMessage = "Auto identification unavailable: teams are not exposed for larger lobbies"
        end
        return
    end
    local folder = Workspace:FindFirstChild("Players")
    if not folder then
        calibratedEnemyGroup = nil
        calibrationMode = "none"
        calibrationMessage = "Auto: waiting for replicated character groups"
        return
    end
    local candidateGroup, count = nil, 0
    local foundLocalModel = false
    local queue = {{folder,0}}
    local at, checked = 1,0
    local camera = Workspace.CurrentCamera
    while at <= #queue and checked < 650 do
        local item = queue[at]
        at += 1
        local node, depth = item[1], item[2]
        for _, child in ipairs(node:GetChildren()) do
            checked += 1
            if checked > 650 then break end
            if child:IsA("Folder") and depth < 3 then
                queue[#queue+1] = {child,depth+1}
            elseif child:IsA("Model") then
                local ok, modelRoot = validModel(child)
                if ok then
                    local owner = identifyPlayer(child)
                    if owner == LocalPlayer then
                        foundLocalModel = true
                    else
                        local group = getTeamGroup(child)
                        local distance = camera and (camera.CFrame.Position-modelRoot.Position).Magnitude or 50
                        if group and distance > 5 then
                            count += 1
                            if count == 1 then candidateGroup = group end
                            if group ~= candidateGroup then candidateGroup = nil end
                        end
                    end
                end
                if depth < 2 then queue[#queue+1] = {child,depth+1} end
            end
        end
    end
    if count == 1 and candidateGroup and not foundLocalModel then
        if calibrationMode ~= "automatic" or calibratedEnemyGroup ~= candidateGroup then
            calibratedEnemyGroup = candidateGroup
            calibrationMode = "automatic"
            calibrationMessage = "Auto: lone opponent identified (2-player server)"
            log("INFO","Automatic enemy-group detection succeeded; no F6 required.")
        end
    else
        if calibrationMode == "automatic" then
            calibratedEnemyGroup = nil
            calibrationMode = "none"
        end
        calibrationMessage = string.format("Auto: waiting for unique opponent (candidate rigs=%d)",count)
    end
end

local function discoverTargets()
    if not alive then return end
    autoResolveEnemyGroup()
    local seen, nextTargets = {}, {}
    local verified, unverified, checked, rejected, excluded, skeletonRigs, groupEnemies, unknownTeam = 0, 0, 0, 0, 0, 0, 0, 0
    local samples = {}
    local function admit(model, player, source)
        if seen[model] or #nextTargets >= 72 then return end
        seen[model] = true
        if player == LocalPlayer then return end
        local ok, root = validModel(model)
        if not ok then rejected += 1; return end

        local playerRelation = player and getPlayerRelation(player) or "unknown"
        local groupRelation = getGroupRelation(model)
        local relation = "unknown"
        if playerRelation == "ally" or groupRelation == "ally" then
            relation = "ally"
        elseif playerRelation == "enemy" or groupRelation == "enemy" then
            relation = "enemy"
        end
        if relation == "ally" then
            excluded += 1
            return
        end
        if relation == "unknown" then
            if not player then
                unverified += 1
            else
                unknownTeam += 1
            end
            if #samples < 4 then
                samples[#samples+1] = model.Name .. " (" .. source .. ")"
            end
            return
        end

        local segments = collectSkeletonSegments(model)
        if #segments > 0 then skeletonRigs += 1 end
        if player then verified += 1 else groupEnemies += 1 end
        nextTargets[#nextTargets+1] = {
            model=model, root=root, player=player,
            source=source, bones=segments, relation="enemy"
        }
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            admit(player.Character, player, "Player.Character")
        end
    end
    local rootFolder = Workspace:FindFirstChild("Players")
    if rootFolder then
        local queue = {{rootFolder,0}}
        local at = 1
        while at <= #queue and checked < 850 do
            local item = queue[at]; at += 1
            local node, depth = item[1], item[2]
            for _, child in ipairs(node:GetChildren()) do
                checked += 1
                if checked > 850 then break end
                if child:IsA("Model") then
                    admit(child, identifyPlayer(child), "Workspace.Players")
                    if depth < 2 then queue[#queue+1] = {child,depth+1} end
                elseif child:IsA("Folder") and depth < 3 then
                    queue[#queue+1] = {child,depth+1}
                end
            end
        end
        lastSource = "Workspace.Players present"
    else
        lastSource = "Workspace.Players absent"
    end
    local aliveKeys = {}
    for _, target in ipairs(nextTargets) do aliveKeys[target.model] = true end
    for key in pairs(widgets) do if not aliveKeys[key] then destroyWidget(key) end end
    targets = nextTargets
    stats.discovered = #targets
    stats.matched = verified
    stats.anonymous = unverified
    stats.enemyGroups = groupEnemies
    stats.unknownTeams = unknownTeam
    stats.teammates = excluded
    stats.skeletonRigs = skeletonRigs
    stats.rejected = rejected
    stats.scans += 1
    lastScanDetails = string.format(
        "targets=%d verified=%d enemy-group=%d unidentified=%d unknown-team=%d allies=%d rigged=%d rejected=%d checked=%d players=%d",
        #targets, verified, groupEnemies, unverified, unknownTeam, excluded, skeletonRigs, rejected, checked, #Players:GetPlayers()
    )
    if #targets == 0 and #samples > 0 then
        lastScanDetails ..= " samples: " .. table.concat(samples, ", ")
    end
end

-- Player folders may stream in/out or rebuild after a new round.
-- Coalesce descendant changes into a single bounded discovery pass.
local function watchPlayerFolder()
    local root = Workspace:FindFirstChild("Players")
    if watchedRoot == root then return end
    for _, connection in ipairs(watcherConnections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(watcherConnections)
    watchedRoot = root
    scanDirty = true
    scanAccumulator = 10
    if not root then return end
    local function invalidate(object)
        if object:IsA("Model") or object:IsA("Folder") or object:IsA("BasePart") then
            groupEvents += 1
            scanDirty = true
        end
    end
    watcherConnections[#watcherConnections+1] = root.DescendantAdded:Connect(invalidate)
    watcherConnections[#watcherConnections+1] = root.DescendantRemoving:Connect(invalidate)
end

-- Only the user can confirm the opposing team when native Team data is absent.
-- This calibration reads the visible object under the crosshair without
-- editing any gameplay instances.
local function calibrateEnemyFromCrosshair()
    local camera = Workspace.CurrentCamera
    if not camera then
        log("WARN","Cannot calibrate: no camera")
        return
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {camera}
    local size = camera.ViewportSize
    local ray = camera:ViewportPointToRay(size.X/2,size.Y/2)
    local result = Workspace:Raycast(ray.Origin,ray.Direction*MAX_DISTANCE,params)
    local group, foundRig = nil, false
    if result then
        group = getTeamGroup(result.Instance)
        if group then
            local current = result.Instance
            while current and current ~= group do
                if current:IsA("Model") and validModel(current) then
                    foundRig = true
                    break
                end
                current = current.Parent
            end
        end
    end
    if not foundRig then
        -- Some custom rigs do not receive raycasts. Look for a unique,
        -- queryable *visual position* near the crosshair instead, and never
        -- select an object located behind the raycast obstruction.
        group = nil
        local root = Workspace:FindFirstChild("Players")
        local bestScore, secondScore = math.huge, math.huge
        local bestGroup, secondGroup = nil, nil
        local checked = 0
        local obstructionDistance = result and (result.Position-ray.Origin).Magnitude or MAX_DISTANCE
        if root then
            local queue = {{root,0}}
            local index = 1
            while index <= #queue and checked < 700 do
                local item = queue[index]
                index += 1
                local node, depth = item[1], item[2]
                for _, object in ipairs(node:GetChildren()) do
                    checked += 1
                    if checked >= 700 then break end
                    if object:IsA("Folder") and depth < 3 then
                        queue[#queue+1] = {object,depth+1}
                    elseif object:IsA("Model") then
                        local ok, modelRoot = validModel(object)
                        if ok then
                            local distance = (modelRoot.Position-ray.Origin).Magnitude
                            if distance > 2 and distance < MAX_DISTANCE and distance <= obstructionDistance+5 then
                                local projected, onScreen = camera:WorldToViewportPoint(modelRoot.Position)
                                if onScreen and projected.Z > 0 then
                                    local pxDist = (Vector2.new(projected.X,projected.Y)-Vector2.new(size.X/2,size.Y/2)).Magnitude
                                    if pxDist <= 55 then
                                        local score = pxDist + distance*0.003
                                        local candidateGroup = getTeamGroup(object)
                                        if candidateGroup then
                                            if candidateGroup == bestGroup then
                                                bestScore = math.min(bestScore, score)
                                            elseif candidateGroup == secondGroup then
                                                secondScore = math.min(secondScore, score)
                                                if secondScore < bestScore then
                                                    bestScore, secondScore = secondScore, bestScore
                                                    bestGroup, secondGroup = secondGroup, bestGroup
                                                end
                                            elseif score < bestScore then
                                                secondScore, secondGroup = bestScore, bestGroup
                                                bestScore, bestGroup = score, candidateGroup
                                            elseif score < secondScore then
                                                secondScore, secondGroup = score, candidateGroup
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        if depth < 2 then queue[#queue+1] = {object,depth+1} end
                    end
                end
            end
        end
        if bestGroup and (secondScore == math.huge or secondScore > bestScore + 10) then
            group = bestGroup
            foundRig = true
        end
    end
    if not group or not foundRig then
        log("WARN","Could not identify a unique visible player under the crosshair. Aim closer at an enemy torso and press F6.")
        return
    end
    calibratedEnemyGroup = group
    calibrationMode = "manual"
    calibrationMessage = "Enemy group selected (F6); other groups excluded"
    scanDirty = true
    scanAccumulator = 10
    log("INFO","Calibrated opposing team group. Other groups are excluded. Recalibrate if teams change.")
    safeCall("Recheck calibrated player models", discoverTargets)
end

local function projectBox(camera, model)
    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    if not ok or size.Magnitude < 0.05 then return nil end
    local half = size * 0.5
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local inFront = 0
    for x=-1,1,2 do
        for y=-1,1,2 do
            for z=-1,1,2 do
                local world = cf:PointToWorldSpace(Vector3.new(half.X*x, half.Y*y, half.Z*z))
                local v = camera:WorldToViewportPoint(world)
                if v.Z > 0.5 then
                    inFront += 1
                    minX = math.min(minX,v.X); maxX = math.max(maxX,v.X)
                    minY = math.min(minY,v.Y); maxY = math.max(maxY,v.Y)
                end
            end
        end
    end
    if inFront < 4 then return nil end
    local viewport = camera.ViewportSize
    if maxX < 0 or minX > viewport.X or maxY < 0 or minY > viewport.Y then return nil end
    local w = maxX-minX; local h = maxY-minY
    if w < 2 or h < 4 or w > viewport.X*2 or h > viewport.Y*2 then return nil end
    return minX,minY,maxX,maxY,cf.Position
end

-- Screen click calibration uses the selected pixel instead of assuming that
-- Phantom Forces aims at the middle of the camera viewport.
local pickerGui, pickerClick, pickerCancel
local pickerActive = false

local function stopPicker(reopenMenu)
    if pickerClick then pickerClick:Disconnect(); pickerClick=nil end
    if pickerCancel then pickerCancel:Disconnect(); pickerCancel=nil end
    if pickerGui then pickerGui:Destroy(); pickerGui=nil end
    pickerActive=false
    if reopenMenu and window and window.Parent then window.Visible=true end
end

local function calibrateAtPixel(point)
    local camera=Workspace.CurrentCamera
    local root=Workspace:FindFirstChild("Players")
    if not camera or not root then
        calibrationMessage="Could not calibrate: camera or player groups missing"
        log("WARN",calibrationMessage)
        return
    end
    local ray=camera:ViewportPointToRay(point.X,point.Y)
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances={camera}
    local hit=Workspace:Raycast(ray.Origin,ray.Direction*MAX_DISTANCE,params)
    local selected=nil
    if hit then
        local group=getTeamGroup(hit.Instance)
        if group then
            local ancestor=hit.Instance
            while ancestor and ancestor~=group do
                if ancestor:IsA("Model") and validModel(ancestor) then
                    selected=group
                    break
                end
                ancestor=ancestor.Parent
            end
        end
    end
    if not selected then
        -- If a custom character is not raycast-queryable, find its projected
        -- bounding rectangle directly under the selected cursor location.
        local best,score,second=nil,math.huge,math.huge
        local queue={{root,0}}
        local index,checked=1,0
        while index<=#queue and checked<850 do
            local item=queue[index]
            index+=1
            local node,depth=item[1],item[2]
            for _,child in ipairs(node:GetChildren()) do
                checked+=1
                if checked>=850 then break end
                if child:IsA("Folder") and depth<3 then
                    queue[#queue+1]={child,depth+1}
                elseif child:IsA("Model") then
                    if validModel(child) then
                        local group=getTeamGroup(child)
                        local l,t,r,b=projectBox(camera,child)
                        if group and l and point.X>=l-8 and point.X<=r+8
                            and point.Y>=t-8 and point.Y<=b+8 then
                            local center=Vector2.new((l+r)/2,(t+b)/2)
                            local candidate=(point-center).Magnitude
                            if group==best then
                                score=math.min(score,candidate)
                            elseif candidate<score then
                                second=score
                                score=candidate
                                best=group
                            elseif candidate<second then
                                second=candidate
                            end
                        end
                    end
                    if depth<2 then queue[#queue+1]={child,depth+1} end
                end
            end
        end
        if best and (second==math.huge or second>score+16) then
            selected=best
        end
    end
    if not selected then
        calibrationMessage="No distinct player rig at click - try clicking their torso"
        log("WARN",calibrationMessage)
        return
    end
    calibratedEnemyGroup=selected
    calibrationMode="manual"
    calibrationMessage="Enemy group calibrated from selected character"
    scanDirty=true
    scanAccumulator=10
    safeCall("Calibrated group scan",discoverTargets)
    log("INFO","Enemy group selected by click; "..tostring(#targets).." targets. Other player groups excluded.")
end

local function beginPicker()
    if pickerActive or not alive or not menuGui or not menuGui.Parent then return end
    pickerGui=create("ScreenGui",{
        Name="SPECTRA_SelectEnemy",IgnoreGuiInset=true,ResetOnSpawn=false,
        DisplayOrder=10000,ZIndexBehavior=Enum.ZIndexBehavior.Sibling
    })
    local ok=pcall(function() pickerGui.Parent=menuGui.Parent end)
    if not ok then
        pickerGui:Destroy()
        pickerGui=nil
        log("ERROR","Could not open select-enemy overlay")
        return
    end
    pickerActive=true
    window.Visible=false
    local capture=create("TextButton",{
        Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Text="",
        Active=true,AutoButtonColor=false,BorderSizePixel=0
    },pickerGui)
    local tip=create("TextLabel",{
        Size=UDim2.fromOffset(560,38),Position=UDim2.new(0.5,-280,0,12),
        Text="SPECTRA  |  Click a visible enemy body  |  ESC to cancel",
        BackgroundColor3=C.base,TextColor3=C.white,
        TextSize=13,Font=Enum.Font.GothamMedium,BorderSizePixel=0,ZIndex=2
    },capture)
    round(tip,6)
    pickerClick=capture.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 then
            local point=Vector2.new(input.Position.X,input.Position.Y)
            stopPicker(true)
            safeCall("Select enemy",function() calibrateAtPixel(point) end)
        end
    end)
    pickerCancel=UserInputService.InputBegan:Connect(function(input)
        if input.KeyCode==Enum.KeyCode.Escape then
            stopPicker(true)
            log("INFO","Selection canceled")
        end
    end)
    log("INFO","Selection started: click enemy torso, or ESC to cancel")
end

local function updateSkeleton(w, target, camera, color)
    local segments = state.skeleton and target.bones or nil
    for i, line in ipairs(w.skeleton) do
        local segment = segments and segments[i]
        if segment then
            local a, b = segment[1], segment[2]
            if a and b and a.Parent and b.Parent then
                local p1 = a:IsA("Bone") and a.WorldPosition or a.Position
                local p2 = b:IsA("Bone") and b.WorldPosition or b.Position
                local va, vb = camera:WorldToViewportPoint(p1), camera:WorldToViewportPoint(p2)
                if va.Z > 0.5 and vb.Z > 0.5 then
                    put(line, va.X, va.Y, vb.X, vb.Y, color, 1)
                else
                    line.Visible = false
                end
            else
                line.Visible = false
            end
        else
            line.Visible = false
        end
    end
end

-- Custom Phantom Forces rigs may omit Motor6D joints and named limb parts.
-- When no actual joints are available, use an explicitly estimated stick figure
-- scaled to the screen-space body bounding box. This is not the true bone pose.
-- Normalized coordinates (x, y) within the visible character box.
local ESTIMATED_JOINTS = {
    {0.50,0.11}, -- 1  head
    {0.50,0.23}, -- 2  neck
    {0.50,0.43}, -- 3  chest
    {0.50,0.60}, -- 4  pelvis
    {0.26,0.27}, -- 5  left shoulder
    {0.13,0.43}, -- 6  left elbow
    {0.09,0.59}, -- 7  left hand
    {0.74,0.27}, -- 8  right shoulder
    {0.87,0.43}, -- 9  right elbow
    {0.91,0.59}, -- 10 right hand
    {0.37,0.62}, -- 11 left hip
    {0.34,0.79}, -- 12 left knee
    {0.32,0.96}, -- 13 left foot
    {0.63,0.62}, -- 14 right hip
    {0.66,0.79}, -- 15 right knee
    {0.68,0.96}, -- 16 right foot
}
local ESTIMATED_BONES = {
    {1,2}, {2,3}, {3,4},
    {2,5}, {5,6}, {6,7},
    {2,8}, {8,9}, {9,10},
    {4,11}, {11,12}, {12,13},
    {4,14}, {14,15}, {15,16}
}
local function updateEstimatedSkeleton(w,left,top,right,bottom,color)
    local width,height=right-left,bottom-top
    if width<=2 or height<=4 then
        for _,line in ipairs(w.skeleton) do line.Visible=false end
        return
    end
    for index,line in ipairs(w.skeleton) do
        local pair=ESTIMATED_BONES[index]
        if pair then
            local a=ESTIMATED_JOINTS[pair[1]]
            local b=ESTIMATED_JOINTS[pair[2]]
            put(line,
                left+width*a[1],top+height*a[2],
                left+width*b[1],top+height*b[2],
                color,1)
        else
            line.Visible=false
        end
    end
end

local function updateHighlight(w, model, camera, color)
    if not state.highlights then
        if w.highlight then w.highlight:Destroy(); w.highlight=nil end
        return
    end
    if not w.highlight then
        -- Camera-owned, client-only visual Instance. Never parent to target rigs.
        local h = Instance.new("Highlight")
        h.Name = "SPECTRA_LocalHighlight"
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.FillTransparency = 0.82
        h.OutlineTransparency = 0.1
        h.Adornee = model
        h.Parent = camera
        w.highlight = h
    end
    w.highlight.Adornee = model
    if w.highlight.Parent ~= camera then w.highlight.Parent = camera end
    w.highlight.FillColor=color
    w.highlight.OutlineColor=color
    w.highlight.Enabled=true
end
local function render()
    if not state.enabled or not overlayLayer then
        for _, w in pairs(widgets) do hideWidget(w) end
        stats.rendered = 0
        return
    end
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local done = 0
    local approximateCount=0
    for _, t in ipairs(targets) do
        local model = t.model
        local w = widgets[model]
        local playerRelation = t.player and getPlayerRelation(t.player) or "unknown"
        local groupRelation = getGroupRelation(model)
        local isEnemy = (playerRelation == "enemy" or groupRelation == "enemy")
            and playerRelation ~= "ally" and groupRelation ~= "ally"
        local shouldShow = model.Parent ~= nil and t.root and t.root.Parent ~= nil
            and isEnemy
        local distance = 0
        if shouldShow then
            distance = (camera.CFrame.Position - t.root.Position).Magnitude
            shouldShow = distance <= MAX_DISTANCE
        end
        local left, top, right, bottom
        if shouldShow then
            left, top, right, bottom = projectBox(camera, model)
            shouldShow = left ~= nil
        end
        if shouldShow then
            if not w then w = newWidget(model) end
            local clr = markerColor()
            done += 1
            w.root.Visible = true
            w.distance.Visible = state.distances
            if state.distances then
                w.distance.Text = string.format("%d studs", math.floor(distance+0.5))
                w.distance.Position = UDim2.fromOffset(left-30,bottom+3)
                w.distance.Size = UDim2.fromOffset(right-left+60,16)
            end
            w.tracer.Visible = state.tracers
            if state.tracers then
                local viewport = camera.ViewportSize
                put(w.tracer,viewport.X/2,viewport.Y-10,(left+right)/2,bottom,clr,1)
            end
            if state.skeleton and #t.bones == 0 then
                updateEstimatedSkeleton(w,left,top,right,bottom,clr)
                approximateCount += 1
            else
                updateSkeleton(w,t,camera,clr)
            end
            updateHighlight(w,model,camera,clr)
        else
            hideWidget(w)
        end
    end
    stats.rendered = done
    stats.approxSkeletons = approximateCount
end

-- Bounded source audit, run only when a report is requested.
-- Does not track or render objects: it exposes why candidate models are excluded.
local function inspectDataSources()
    local lines = {"-- REPLICATION / TEAM PROBE --"}
    local all = Players:GetPlayers()
    local counts = {enemy=0, ally=0, unknown=0, characters=0}
    local function teamLabel(team)
        return team and team.Name or "nil"
    end
    local teams = TeamsService:GetTeams()
    local teamNames = {}
    for _, team in ipairs(teams) do
        teamNames[#teamNames+1] = team.Name .. "(" .. team.TeamColor.Name .. ")"
    end
    lines[#lines+1] = "Roblox Teams: " .. #teams .. " | " .. (#teamNames > 0 and table.concat(teamNames, ", ") or "(none)")
    lines[#lines+1] = "Local team: " .. teamLabel(LocalPlayer.Team) .. " | neutral=" .. tostring(LocalPlayer.Neutral)
    for _, p in ipairs(all) do
        local relation = getPlayerRelation(p)
        counts[relation] += 1
        if p.Character and p.Character.Parent then counts.characters += 1 end
    end
    lines[#lines+1] = string.format(
        "Player relations: enemies=%d allies=%d unknown=%d | standard characters=%d/%d",
        counts.enemy, counts.ally, counts.unknown, counts.characters, #all
    )
    local folder = Workspace:FindFirstChild("Players")
    if not folder then
        lines[#lines+1] = "Workspace.Players: MISSING"
        return lines
    end
    local children = folder:GetChildren()
    lines[#lines+1] = "Workspace.Players: " .. #children .. " direct groups"
    for groupIndex=1,math.min(10,#children) do
        local group = children[groupIndex]
        local queue = {{group,0}}
        local index, checked, modelCount, validCount, namedCount, enemyCount, allyCount, unknownCount = 1, 0, 0, 0, 0, 0, 0, 0
        local samples = {}
        while index <= #queue and checked < 250 do
            local item = queue[index]
            index += 1
            local node, depth = item[1], item[2]
            for _, child in ipairs(node:GetChildren()) do
                checked += 1
                if checked > 250 then break end
                if child:IsA("Model") then
                    modelCount += 1
                    if validCount < 60 then
                        local valid = validModel(child)
                        if valid then
                            validCount += 1
                            local owner = identifyPlayer(child)
                            if owner then namedCount += 1 end
                            local relation = owner and getPlayerRelation(owner) or getGroupRelation(child)
                            if relation == "enemy" then enemyCount += 1
                            elseif relation == "ally" then allyCount += 1
                            else unknownCount += 1 end
                            if #samples < 3 then
                                samples[#samples+1] = child.Name .. ":" .. (owner and owner.Name or "?") .. "/" .. relation
                            end
                        end
                    end
                    if depth < 3 then queue[#queue+1] = {child,depth+1} end
                elseif child:IsA("Folder") and depth < 3 then
                    queue[#queue+1] = {child,depth+1}
                end
            end
        end
        lines[#lines+1] = string.format(
            "Group %d '%s': models=%d valid=%d owned=%d enemy=%d ally=%d unknown=%d checked=%d",
            groupIndex,group.Name,modelCount,validCount,namedCount,enemyCount,allyCount,unknownCount,checked
        )
        if #samples > 0 then lines[#lines+1] = "  Samples: " .. table.concat(samples,", ") end
    end
    return lines
end

local function report()
    local rows = {
        "SPECTRA PHASE 1 DIAGNOSTICS / "..VERSION,
        "PlaceId: "..tostring(game.PlaceId),
        "Mode: CLIENT-ONLY; no server-authoritative access",
        "Active: "..tostring(alive).." ESP: "..tostring(state.enabled),
        "Players listed: "..tostring(#Players:GetPlayers()),
        "LocalPlayer.Character: "..tostring(LocalPlayer.Character~=nil),
        "CurrentCamera: "..tostring(Workspace.CurrentCamera~=nil),
        "Folder: "..lastSource,
        "Discovery: "..lastScanDetails,
        "Visible targets: "..tostring(stats.rendered),
        "Identity status: "..(#targets>0 and "opposing-team models available" or "NO ENEMY MODELS: identities/team data missing or unavailable"),
        "FPS: "..string.format("%.0f",stats.fps).." / render target: 50 Hz (limited by FPS)",
        "Connections tracked: "..tostring(#connections),
        "Scans: "..tostring(stats.scans),
        "Options: skeleton="..tostring(state.skeleton).." highlights="..tostring(state.highlights),
        "Enemy-only tracking: "..tostring(stats.teammates).." allies excluded; unknown teams: "..tostring(stats.unknownTeams),
        "Group-matched enemy rigs: "..tostring(stats.enemyGroups).." (only when Roblox Team names match)",
        "Calibration: "..calibrationMessage,
        "Calibration mode: "..calibrationMode,
        "Group events observed: "..tostring(groupEvents),
        "Fixed limits: 1000 studs / 50 Hz target",
        "Skeleton rigs with joints: "..tostring(stats.skeletonRigs).."/"..tostring(stats.discovered),
        "Estimated 2D skeletons shown: "..tostring(stats.approxSkeletons).." (not actual bone poses)",
        "No getgc, hooks, remote scripts, or writes to other character models.",
        "-- RECENT LOGS --"
    }
    local sources = inspectDataSources()
    for _, entry in ipairs(sources) do rows[#rows+1] = entry end
    for i=math.max(1,#logs-28),#logs do rows[#rows+1]=logs[i] end
    return table.concat(rows,"\n")
end

local function exportReport()
    local r=report()
    if type(setclipboard)=="function" then
        local ok = pcall(setclipboard,r)
        if ok then log("INFO","Report copied to clipboard") return end
    end
    print(r)
    log("WARN","Clipboard unavailable; report printed to console")
end

local function shutdown()
    if not alive then return end
    log("INFO","Unloading SPECTRA and releasing UI/resources")
    alive=false
    stopPicker(false)
    for key in pairs(widgets) do destroyWidget(key) end
    for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
    for _, conn in ipairs(watcherConnections) do pcall(function() conn:Disconnect() end) end
    table.clear(watcherConnections)
    table.clear(connections)
    calibratedEnemyGroup = nil
    calibrationMode = "none"
    if overlayGui then overlayGui:Destroy(); overlayGui=nil end
    if menuGui then menuGui:Destroy(); menuGui=nil end
    targets={}
    if ENV.SPECTRA_PHASE1_UNLOAD == shutdown then ENV.SPECTRA_PHASE1_UNLOAD = nil end
end
ENV.SPECTRA_PHASE1_UNLOAD = shutdown

-- UI foundation --------------------------------------------------------------
overlayGui=create("ScreenGui",{Name="SPECTRA_Phase1_Overlay",IgnoreGuiInset=true,ResetOnSpawn=false,DisplayOrder=160,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
menuGui=create("ScreenGui",{Name="SPECTRA_Phase1_UI",IgnoreGuiInset=true,ResetOnSpawn=false,DisplayOrder=161,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
if not safeParent(overlayGui) or not safeParent(menuGui) then
    warn("[SPECTRA] Could not parent GUI to an accessible UI container")
    shutdown()
    return
end
overlayLayer=create("Frame",{Name="WorldMarkers",BackgroundTransparency=1,Size=UDim2.fromScale(1,1),Position=UDim2.fromScale(0,0),ClipsDescendants=true},overlayGui)
window=create("Frame",{
    Name="MainWindow",Size=UDim2.fromOffset(660,445),Position=UDim2.new(0.5,-330,0.5,-223),
    BackgroundColor3=C.base,BorderSizePixel=0,ClipsDescendants=true
},menuGui)
round(window,9); outline(window)
menu=window
local top=create("Frame",{Size=UDim2.new(1,0,0,53),BackgroundColor3=C.base,BorderSizePixel=0},window)
local title=textLabel(top,"SPECTRA",16,C.white,true)
title.Position=UDim2.fromOffset(21,11); title.Size=UDim2.fromOffset(130,22)
local sub=textLabel(top,"PLAYER VISUALS  /  1.6.2",10,C.muted)
sub.Position=UDim2.fromOffset(137,12); sub.Size=UDim2.fromOffset(180,22)
-- Hide only changes menu visibility; ESP keeps running.
local hideButton=create("TextButton",{Text="Hide",Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=C.muted,
    BackgroundColor3=C.panel,Size=UDim2.fromOffset(56,26),Position=UDim2.new(1,-166,0,13),BorderSizePixel=0},top)
round(hideButton,5)
connect(hideButton.MouseButton1Click,function()
    window.Visible=false
end)
-- Unload removes the entire overlay and all SPECTRA event connections.
local unloadButton=create("TextButton",{Text="Unload",Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=C.white,
    BackgroundColor3=C.panel2,Size=UDim2.fromOffset(88,26),Position=UDim2.new(1,-103,0,13),BorderSizePixel=0},top)
round(unloadButton,5)
connect(unloadButton.MouseButton1Click,shutdown)
create("Frame",{BackgroundColor3=C.border,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.fromOffset(0,53)},window)
local left=create("Frame",{Position=UDim2.fromOffset(0,54),Size=UDim2.new(0,145,1,-54),BackgroundColor3=C.sidebar,BorderSizePixel=0},window)
create("Frame",{BackgroundColor3=C.border,BorderSizePixel=0,Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0)},left)
local content=create("Frame",{Position=UDim2.fromOffset(145,54),Size=UDim2.new(1,-145,1,-54),BackgroundTransparency=1,BorderSizePixel=0},window)
local footer=create("Frame",{BackgroundColor3=C.base,BorderSizePixel=0,Position=UDim2.new(0,145,1,-32),Size=UDim2.new(1,-145,0,32)},window)
create("Frame",{BackgroundColor3=C.border,BorderSizePixel=0,Size=UDim2.new(1,0,0,1)},footer)
statusText=textLabel(footer,"Initializing...",10,C.muted)
statusText.Position=UDim2.fromOffset(17,4);statusText.Size=UDim2.new(1,-34,1,-8)
local pages={}
local tabButtons={}
for index,name in ipairs({"ESP","Settings","Debug"}) do
    local b=create("TextButton",{
        Text=name,TextSize=12,Font=Enum.Font.GothamMedium,
        TextColor3=C.muted,TextXAlignment=Enum.TextXAlignment.Left,
        BackgroundColor3=C.sidebar,Size=UDim2.fromOffset(123,35),Position=UDim2.fromOffset(11,18+(index-1)*42),BorderSizePixel=0
    },left)
    create("UIPadding",{PaddingLeft=UDim.new(0,11)},b)
    round(b,5)
    tabButtons[name]=b
    pages[name]=create("ScrollingFrame",{
        Name=name.."Page",Position=UDim2.fromOffset(0,0),Size=UDim2.new(1,0,1,-32),
        BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=C.border,
        CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollingDirection=Enum.ScrollingDirection.Y,Visible=false
    },content)
    create("UIPadding",{PaddingTop=UDim.new(0,18),PaddingLeft=UDim.new(0,18),PaddingRight=UDim.new(0,22),PaddingBottom=UDim.new(0,18)},pages[name])
    create("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,8)},pages[name])
end
local function selectTab(name)
    focusedTab=name
    for key,page in pairs(pages) do
        local selected=key==name
        page.Visible=selected
        tabButtons[key].BackgroundColor3=selected and C.panel2 or C.sidebar
        tabButtons[key].TextColor3=selected and C.accent or C.muted
    end
end
for name,b in pairs(tabButtons) do connect(b.MouseButton1Click,function() selectTab(name) end) end
local function header(page,name,description)
    local f=create("Frame",{Size=UDim2.new(1,-3,0,53),BackgroundTransparency=1,BorderSizePixel=0},page)
    local h=textLabel(f,name,16,C.white,true);h.Size=UDim2.new(1,0,0,23)
    local d=textLabel(f,description,10,C.muted);d.Position=UDim2.fromOffset(0,24);d.Size=UDim2.new(1,0,0,17)
end
local function groupLabel(page,text)
    local f=create("Frame",{Size=UDim2.new(1,-3,0,22),BackgroundTransparency=1},page)
    local t=textLabel(f,text,10,C.muted,true)
    t.Size=UDim2.new(1,0,1,0)
end
local function row(page,name,description)
    local f=create("Frame",{Size=UDim2.new(1,-3,0,51),BackgroundColor3=C.panel,BorderSizePixel=0},page)
    round(f,6)
    local t=textLabel(f,name,12,C.white,true);t.Position=UDim2.fromOffset(13,6);t.Size=UDim2.new(1,-105,0,19)
    local d=textLabel(f,description,10,C.muted);d.Position=UDim2.fromOffset(13,25);d.Size=UDim2.new(1,-100,0,17)
    return f
end
local function toggle(page,label,help,key)
    local f=row(page,label,help)
    local track=create("TextButton",{Text="",BackgroundColor3=C.border,BorderSizePixel=0,
        Size=UDim2.fromOffset(38,20),Position=UDim2.new(1,-52,0,15)},f)
    round(track,10)
    local knob=create("Frame",{Size=UDim2.fromOffset(14,14),Position=UDim2.fromOffset(3,3),BackgroundColor3=C.white,BorderSizePixel=0},track)
    round(knob,8)
    local function refresh()
        track.BackgroundColor3=state[key] and C.accent or C.border
        knob.Position=state[key] and UDim2.fromOffset(21,3) or UDim2.fromOffset(3,3)
    end
    connect(track.MouseButton1Click,function()
        state[key]=not state[key]
        refresh()
        if key=="enabled" and not state[key] then
            for _,w in pairs(widgets) do hideWidget(w) end
        elseif key=="enabled" and state[key] then
            scanAccumulator=10
        end
        log("INFO",label.." = "..tostring(state[key]))
    end)
    toggleRefreshers[#toggleRefreshers+1] = refresh
    refresh()
end
local function action(page,label,callback)
    local b=create("TextButton",{Text=label,Font=Enum.Font.GothamMedium,TextSize=12,TextColor3=C.white,
        BackgroundColor3=C.panel2,BorderSizePixel=0,Size=UDim2.new(1,-3,0,34)},page)
    round(b,5)
    connect(b.MouseButton1Click,function() safeCall(label,callback) end)
    return b
end

local espPage=pages.ESP
header(espPage,"Player visuals","Configure your in-game overlay")
groupLabel(espPage,"DISPLAY")
toggle(espPage,"Enable ESP","Master switch for visual markers","enabled")
toggle(espPage,"Distance","Camera distance in Roblox studs","distances")
toggle(espPage,"Tracers","Lines from the screen bottom toward players","tracers")
toggle(espPage,"Skeleton","Real rig joints where found; estimated shape otherwise","skeleton")
toggle(espPage,"3D highlight","Client-side character highlighting","highlights")

-- Keep the menu fully inside the viewport, including after user dragging,
-- display resolution changes, and inconsistent custom GUI parent sizes.
local function clampWindow(center)
    if not alive or not window or not window.Parent then return end
    local camera = Workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280,720)
    local margin = 12
    local width = math.floor(math.min(660, math.max(300,viewport.X - margin*2)))
    local height = math.floor(math.min(445, math.max(265,viewport.Y - margin*2)))
    window.Size = UDim2.fromOffset(width,height)
    local x = window.Position.X.Scale*viewport.X + window.Position.X.Offset
    local y = window.Position.Y.Scale*viewport.Y + window.Position.Y.Offset
    if center then
        x = (viewport.X-width)/2
        y = (viewport.Y-height)/2
    end
    x = math.clamp(x, margin, math.max(margin, viewport.X-width-margin))
    y = math.clamp(y, margin, math.max(margin, viewport.Y-height-margin))
    window.Position = UDim2.fromOffset(math.floor(x+0.5),math.floor(y+0.5))
end

local settingsPage=pages.Settings
header(settingsPage,"Settings","Interface preferences and runtime controls")
groupLabel(settingsPage,"APPEARANCE")
local colorButton
colorButton=action(settingsPage,"Marker color: Cyan  (click to cycle)",function()
    local order={"Cyan","Coral","Lime","White"}
    local n=1
    for i,v in ipairs(order) do
        if v==state.color then n=i%#order+1; break end
    end
    state.color=order[n]
    colorButton.Text="Marker color: "..state.color.."  (click to cycle)"
    log("INFO","Marker color: "..state.color)
end)
groupLabel(settingsPage,"KEYBINDS")
local keyText=row(settingsPage,"Right Shift","Show or hide the menu")
local debugText=row(settingsPage,"F8","Open the diagnostic console")
local homeText=row(settingsPage,"Home","Recenter the menu if it moves off-screen")
row(settingsPage,"Ctrl + End","Unload SPECTRA without leaving the game")
groupLabel(settingsPage,"CONTROL")
action(settingsPage,"Center menu on screen",function() clampWindow(true); log("INFO","Menu recentered") end)
action(settingsPage,"Rescan replicated models",function() discoverTargets();log("INFO","Manual scan: "..lastScanDetails) end)
action(settingsPage,"Disable ESP markers",function() state.enabled=false;refreshAllToggles();for _,w in pairs(widgets) do hideWidget(w) end; log("INFO","ESP disabled") end)
action(settingsPage,"Unload SPECTRA completely",shutdown)
groupLabel(settingsPage,"DESIGN NOTES")
local note=create("TextLabel",{Text="UI and markers are created on the local client. This build never writes to weapon state, other player characters, or Phantom Forces replication interfaces.",
    Size=UDim2.new(1,-10,0,64),TextWrapped=true,BackgroundTransparency=1,Font=Enum.Font.Gotham,TextColor3=C.muted,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,TextSize=11},settingsPage)

local debugPage=pages.Debug
header(debugPage,"Diagnostics","Read-only inspection  ·  Logs limited to 140 entries")
debugSummary=textLabel(debugPage,"Not scanned",11,C.muted)
debugSummary.Size=UDim2.new(1,-3,0,39)
debugSummary.TextWrapped=true
debugSummary.TextYAlignment=Enum.TextYAlignment.Top
local buttons=create("Frame",{Size=UDim2.new(1,-3,0,32),BackgroundTransparency=1},debugPage)
local function debugButton(text,x,callback)
    local b=create("TextButton",{Text=text,TextSize=11,Font=Enum.Font.GothamMedium,
        TextColor3=C.white,BackgroundColor3=C.panel2,BorderSizePixel=0,
        Position=UDim2.new(x,0,0,0),Size=UDim2.new(0.32,-3,1,0)},buttons)
    round(b,5);connect(b.MouseButton1Click,callback)
end
debugButton("Run probe",0,function() discoverTargets();log("INFO","Probe: "..lastSource.." / "..lastScanDetails) end)
debugButton("Copy report",0.335,exportReport)
debugButton("Clear logs",0.67,function() table.clear(logs);if logBox then logBox.Text="" end end)
local logPanel=create("Frame",{Size=UDim2.new(1,-3,0,210),BackgroundColor3=C.panel,BorderSizePixel=0},debugPage)
round(logPanel,6)
local logScroll=create("ScrollingFrame",{Position=UDim2.fromOffset(8,8),Size=UDim2.new(1,-16,1,-16),BackgroundTransparency=1,
    BorderSizePixel=0,ScrollBarThickness=3,CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y},logPanel)
logBox=create("TextBox",{BackgroundTransparency=1,ClearTextOnFocus=false,MultiLine=true,TextEditable=false,
    Font=Enum.Font.Code,TextSize=11,TextColor3=C.white,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
    TextWrapped=true,Text="",Size=UDim2.new(1,-4,0,0),AutomaticSize=Enum.AutomaticSize.Y,BorderSizePixel=0},logScroll)
local inputRow=create("Frame",{Size=UDim2.new(1,-3,0,32),BackgroundTransparency=1},debugPage)
local cmd=create("TextBox",{PlaceholderText="status, probe, targets, esp on/off, help, unload",Text="",ClearTextOnFocus=false,
    TextXAlignment=Enum.TextXAlignment.Left,Font=Enum.Font.Code,TextSize=11,TextColor3=C.white,
    PlaceholderColor3=C.muted,BackgroundColor3=C.panel,Size=UDim2.new(1,-76,1,0),BorderSizePixel=0},inputRow)
round(cmd,5);create("UIPadding",{PaddingLeft=UDim.new(0,9)},cmd)
local run=create("TextButton",{Text="Run",Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=C.white,
    BackgroundColor3=C.panel2,Size=UDim2.fromOffset(68,32),Position=UDim2.new(1,-68,0,0),BorderSizePixel=0},inputRow)
round(run,5)
local function runCommand(raw)
    local input=(raw or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if input=="help" then log("INFO","Commands: help, status, probe, sources, team, calibrate, clearteam, targets, recenter, esp on, esp off, clear, unload")
    elseif input=="status" then log("INFO","ESP="..tostring(state.enabled).." visible="..stats.rendered.." targets="..#targets.." verified="..stats.matched.." enemyGroups="..stats.enemyGroups.." unidentified="..stats.anonymous.." unknownTeams="..stats.unknownTeams.." excluded="..stats.teammates.." fps="..math.floor(stats.fps).." connections="..#connections)
    elseif input=="probe" then discoverTargets();log("INFO",lastSource.." / "..lastScanDetails)
    elseif input=="sources" then
        local sourceLines=inspectDataSources()
        for _, entry in ipairs(sourceLines) do log("INFO",entry) end
    elseif input=="team" then
        log("INFO","Calibration: "..calibrationMessage.." | events="..groupEvents)
    elseif input=="calibrate" then calibrateEnemyFromCrosshair()
    elseif input=="pick" then beginPicker()
    elseif input=="clearteam" then clearCalibration();discoverTargets();log("INFO","Calibration cleared")
    elseif input=="recenter" then clampWindow(true);log("INFO","Window centered")
    elseif input=="targets" then
        log("INFO","Candidates: "..#targets.."  verified="..stats.matched.." unverified="..stats.anonymous)
        for i=1,math.min(12,#targets) do
            local t=targets[i]
            log("INFO",string.format("%d) %s [%s, %s]",i,t.player and t.player.Name or "calibrated enemy rig",t.source,t.player and "verified" or "group-only"))
        end
    elseif input=="esp on" then state.enabled=true;refreshAllToggles();log("INFO","ESP enabled")
    elseif input=="esp off" then state.enabled=false;refreshAllToggles();for _,w in pairs(widgets) do hideWidget(w) end;log("INFO","ESP disabled")
    elseif input=="clear" then table.clear(logs);logBox.Text=""
    elseif input=="unload" then shutdown()
    else log("WARN","Unknown command: "..input) end
end
connect(run.MouseButton1Click,function() local raw=cmd.Text;cmd.Text="";runCommand(raw) end)
connect(cmd.FocusLost,function(enterPressed) if enterPressed then local raw=cmd.Text;cmd.Text="";runCommand(raw) end end)

selectTab("ESP")
clampWindow(true)
-- Dragging is limited to the header; no changes to Roblox input state.
local dragging=false
local dragStart, windowStart
connect(top.InputBegan,function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 then
        dragging=true;dragStart=input.Position;windowStart=window.Position
    end
end)
connect(UserInputService.InputChanged,function(input)
    if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then
        local d=input.Position-dragStart
        window.Position=UDim2.new(windowStart.X.Scale,windowStart.X.Offset+d.X,windowStart.Y.Scale,windowStart.Y.Offset+d.Y)
        clampWindow(false)
    end
end)
connect(UserInputService.InputEnded,function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
end)
connect(UserInputService.InputBegan,function(input,gameProcessed)
    if gameProcessed or UserInputService:GetFocusedTextBox() then return end
    if input.KeyCode==Enum.KeyCode.End and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
        shutdown()
        return
    elseif input.KeyCode==Enum.KeyCode.F6 then
        safeCall("Enemy calibration",calibrateEnemyFromCrosshair)
    elseif input.KeyCode==Enum.KeyCode.RightShift then
        window.Visible=not window.Visible
        if window.Visible then clampWindow(false) end
    elseif input.KeyCode==Enum.KeyCode.Home then
        clampWindow(true)
    elseif input.KeyCode==Enum.KeyCode.F8 then
        window.Visible=true;selectTab("Debug");clampWindow(false)
    end
end)

connect(RunService.RenderStepped,function(dt)
    if not alive then return end
    stats.fps=stats.fps==0 and (1/math.max(0.001,dt)) or (stats.fps*0.92 + (1/math.max(0.001,dt))*0.08)
    scanAccumulator += dt
    renderAccumulator += dt
    statAccumulator += dt
    if scanAccumulator >= 2.2 or (scanDirty and scanAccumulator >= 0.2) then
        scanAccumulator = 0
        scanDirty = false
        safeCall("Discover",discoverTargets)
    end
    if renderAccumulator >= UPDATE_PERIOD then
        renderAccumulator = renderAccumulator % UPDATE_PERIOD
        safeCall("Render",render)
    end
    if statAccumulator>=0.7 then
        statAccumulator=0
        if statusText and statusText.Parent then
            statusText.Text=string.format("v%s · ESP %s · %d targets / %d unknown · %d shown · %d FPS",VERSION,state.enabled and "ON" or "OFF",#targets,stats.anonymous+stats.unknownTeams,stats.rendered,math.floor(stats.fps+0.5))
        end
        clampWindow(false)
        if debugSummary and debugSummary.Parent then
            debugSummary.Text=string.format("%s\n%s   |   render target %d Hz",lastSource,lastScanDetails,UPDATE_HZ)
        end
    end
end)
connect(Players.PlayerAdded,function(p) log("INFO","Player joined: "..p.Name);scanDirty=true end)
connect(Players.PlayerRemoving,function(p) log("INFO","Player left: "..p.Name);scanDirty=true end)
connect(Workspace.ChildAdded,function(child)
    if child.Name == "Players" then watchPlayerFolder() end
end)
connect(Workspace.ChildRemoved,function(child)
    if child == watchedRoot then watchPlayerFolder() end
end)
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"),function()
    for _,w in pairs(widgets) do if w.highlight then w.highlight:Destroy();w.highlight=nil end end
    clampWindow(false)
    log("INFO","Camera changed; optional highlights reset")
end)

log("INFO","SPECTRA Phase 1 v1.6.2 loaded. 2D boxes removed | F8: debug | Ctrl+End: unload")
log("INFO","Automatic 1v1 opponent group identification enabled. Larger lobbies require reliable game team data.")
watchPlayerFolder()
safeCall("Initial scan",discoverTargets)
log("INFO","Initial discovery: "..lastSource.." / "..lastScanDetails)