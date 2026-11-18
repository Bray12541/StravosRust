--[[
    SPECTRA / PHASE 1                         v1.26.1
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
-- Clean up the previous instance before installing new event callbacks.
-- Older builds returned nil even when unload succeeded, so only explicit
-- failure/exception is fatal; leftover UI is checked below independently.
local previousUnload = ENV.SPECTRA_PHASE1_UNLOAD
if type(previousUnload) ~= "function" then
    previousUnload = _G.SPECTRA_PHASE1_UNLOAD
end
if type(previousUnload) == "function" then
    local ok,clean,reason = pcall(previousUnload)
    if not ok or clean == false then
        warn("[SPECTRA] Previous cleanup failed: "..tostring(ok and reason or clean)
            ..". New instance blocked to avoid duplicate listeners.")
        return
    end
end

-- If a prior environment lost its cleanup handle, do not stack another
-- SPECTRA instance over an orphaned menu. The user can rejoin to reset it.
local function oldGuiExists()
    local containers={}
    local pg=LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then containers[#containers+1]=pg end
    local ok,core=pcall(function() return game:GetService("CoreGui") end)
    if ok and core then containers[#containers+1]=core end
    if type(gethui)=="function" then
        local success,hui=pcall(gethui)
        if success and typeof(hui)=="Instance" then
            containers[#containers+1]=hui
        end
    end
    for _,container in ipairs(containers) do
        local safe,existing=pcall(function()
            return container:FindFirstChild("SPECTRA_Phase1_UI")
                or container:FindFirstChild("SPECTRA_Phase1_Overlay")
        end)
        if safe and existing then return true end
    end
    return false
end
if oldGuiExists() then
    warn("[SPECTRA] Previous SPECTRA UI is still present after cleanup; "
        .."new instance blocked. Rejoin the game before retrying.")
    return
end

local VERSION = "1.26.1"
local alive = true
local connections = {}
local tracked = {}
local widgets = {}
local logs = {}
local targets = {}
local lastSource = "Not scanned"
local lastScanDetails = "Not scanned"
-- Alternate public Workspace discovery is cached and rate-limited. Never
-- assume an unknown humanoid/model belongs to an opposing player.
local fallbackModels={}
local fallbackNextScan=0
local fallbackSummary="not scanned"
local stats = {discovered=0, matched=0, anonymous=0, enemyGroups=0, unknownTeams=0, teammates=0, skeletonRigs=0, approxSkeletons=0, wideSkeletons=0, rejected=0, rendered=0, fps=0, scans=0, drawn=0, sample=0, frameMs=0}
local overlayGui, menuGui, overlayLayer, window, statusText, logBox, debugSummary, menu, aimFovFrame
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
    skeleton = true,
    highlights = false,
    aimEnabled = false,
    aimFovVisible = true,
    aimFovRadius = 150,
    aimSmoothing = 8,
    aimStyle = "Snap",
    aimSnapStrength = 100,
    aimPullStrength = 150,
    aimVisibleOnly = false,
    aimKey = "Always",
    aimSticky = true,
    aimLock = true,
    aimPoint = "Head",
    aimMethod = "Auto",
    speedHack = false, speedValue = 32,
    infiniteJump = false,
    noFallDamage = false,
    antiAim = false,
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
    -- An explicitly identified local-player group always remains friendly,
    -- even if manual calibration previously pointed at that group.
    local localGroup=getTeamGroup(LocalPlayer.Character)
    if localGroup and group and group==localGroup then return "ally" end
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
-- Use one conservative relation policy for ESP discovery, ESP rendering,
-- persistent target lock and initial target acquisition.
-- Any reliable ally evidence takes precedence over an enemy signal.
local function classifyTarget(model,player)
    if not model or model==LocalPlayer.Character
        or (LocalPlayer.Character and model:IsDescendantOf(LocalPlayer.Character))
        or player==LocalPlayer then
        return "ally"
    end
    local playerRelation=player and getPlayerRelation(player) or "unknown"
    local groupRelation=getGroupRelation(model)
    if playerRelation=="ally" or groupRelation=="ally" then return "ally" end
    if playerRelation=="enemy" or groupRelation=="enemy" then return "enemy" end
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
-- Reject a manually selected enemy group if it contains any positively
-- identified teammate or the local character. Unidentified players are not
-- used as proof that a group is friendly or hostile.
local function enemyGroupAllowed(group)
    if not group or not group.Parent then
        return false,"No valid team group selected"
    end
    if getTeamGroup(LocalPlayer.Character)==group then
        return false,"Selected group contains your own character"
    end
    local queue={{group,0}}
    local at,checked=1,0
    while at<=#queue and checked<350 do
        local node,depth=queue[at][1],queue[at][2]
        at+=1
        for _,child in ipairs(node:GetChildren()) do
            checked+=1
            if checked>350 then break end
            if child:IsA("Model") then
                local owner=identifyPlayer(child)
                if owner and getPlayerRelation(owner)=="ally" then
                    return false,"Selected group contains a confirmed teammate ("..owner.Name..")"
                end
                if depth<3 then queue[#queue+1]={child,depth+1} end
            elseif child:IsA("Folder") and depth<3 then
                queue[#queue+1]={child,depth+1}
            end
        end
    end
    return true,nil
end

-- Automatic identification without F6 is safe only when one remote
-- character exists in a two-player server. Larger games expose no team
-- identities, so this never guesses which of two groups is hostile.
-- Determine the opposing group only when the player's own group is
-- confirmed or a lone opponent is unambiguous. Unknown rigs remain displayable
-- in ESP but never become aim targets without team confirmation.
local function autoResolveEnemyGroup()
    if calibrationMode == "manual" and calibratedEnemyGroup then return end
    local root = Workspace:FindFirstChild("Players")
    if not root then
        if calibrationMode == "automatic" then
            calibratedEnemyGroup=nil
            calibrationMode="none"
        end
        calibrationMessage="Auto: waiting for replicated character groups"
        return
    end

    local groups={}
    for _,child in ipairs(root:GetChildren()) do
        if child:IsA("Folder") then groups[#groups+1]=child end
    end
    if #groups==2 then
        -- A reliable local Player.Character or an explicitly owned replicated
        -- model identifies the player's own side in a two-team lobby.
        local ownGroup=getTeamGroup(LocalPlayer.Character)
        if ownGroup~=groups[1] and ownGroup~=groups[2] then
            ownGroup=nil
            for _,group in ipairs(groups) do
                -- Bounded BFS avoids materializing every descendant in a
                -- large game replication folder each discovery interval.
                local queue={{group,0}}
                local at,examined=1,0
                while at<=#queue and examined<350 do
                    local item=queue[at]
                    at+=1
                    local node,depth=item[1],item[2]
                    for _,child in ipairs(node:GetChildren()) do
                        examined+=1
                        if examined>350 then break end
                        if child:IsA("Model") and validModel(child)
                            and identifyPlayer(child)==LocalPlayer then
                            ownGroup=group
                            break
                        end
                        if (child:IsA("Model") or child:IsA("Folder"))
                            and depth<3 then
                            queue[#queue+1]={child,depth+1}
                        end
                    end
                    if ownGroup then break end
                end
                if ownGroup then break end
            end
        end
        if ownGroup then
            local opposing=ownGroup==groups[1] and groups[2] or groups[1]
            local allowed,reason=enemyGroupAllowed(opposing)
            if not allowed then
                if calibrationMode=="automatic" then
                    calibratedEnemyGroup=nil
                    calibrationMode="none"
                end
                calibrationMessage="Auto team check rejected: "..tostring(reason)
                return
            end
            if calibratedEnemyGroup~=opposing or calibrationMode~="automatic" then
                calibratedEnemyGroup=opposing
                calibrationMode="automatic"
                log("INFO","Confirmed local group and opposing group; ESP opponent detection refreshed.")
            end
            calibrationMessage="Auto: identified opposing group using local character in two-team lobby"
            return
        end
    end

    -- Never assume that the only other player is hostile. A duo may be
    -- on the same team. Without an identified local group or public Team
    -- membership, leave this session uncalibrated until F6/manual selection.
    if calibrationMode=="automatic" then
        calibratedEnemyGroup=nil
        calibrationMode="none"
    end
    calibrationMessage="Auto: team unknown; confirm opponents via Team metadata or F6"

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

        local relation=classifyTarget(model,player)
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
            -- Unknown is never eligible for ESP or aiming. Keep counters
            -- for diagnostics without admitting the unclassified rig.
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
    -- Non-standard character renderers can place genuinely replicated
    -- Player-owned models outside Workspace.Players. Search only a bounded
    -- set of plausible public containers, every 6 seconds, and admit only
    -- models that can be explicitly matched to a Roblox Player. This does
    -- not read private replication stores or infer anonymous coordinates.
    if os.clock()>=fallbackNextScan then
        fallbackNextScan=os.clock()+6
        table.clear(fallbackModels)
        local queue,queued={},{}
        local function enqueue(node,depth)
            -- Bound both traversal and queue growth. Large map hierarchies
            -- must never allocate an unbounded list of candidate models.
            if not node or queued[node] or #queue>=1600 then return end
            queued[node]=true
            queue[#queue+1]={node,depth}
        end
        local rootNames={"Characters","PlayerCharacters","PlayerModels",
            "Actors","Entities","Client","Players","Render","Ignore",
            "ReplicatedCharacters","Game"}
        for _,name in ipairs(rootNames) do
            local container=Workspace:FindFirstChild(name)
            if container and container:IsA("Instance") then enqueue(container,0) end
        end
        -- Also inspect a bounded number of direct Workspace models without
        -- recursively traversing gigantic terrain or map structures.
        local directChecked=0
        for _,child in ipairs(Workspace:GetChildren()) do
            directChecked+=1
            if directChecked>350 then break end
            if child:IsA("Model") then enqueue(child,0) end
        end
        local at,visited,models,owned=1,0,0,0
        while at<=#queue and visited<1250 and owned<72 do
            local item=queue[at]
            at+=1
            local node,depth=item[1],item[2]
            visited+=1
            if node:IsA("Model") then
                models+=1
                local ok,owner=pcall(identifyPlayer,node)
                if ok and owner and owner~=LocalPlayer then
                    local valid=validModel(node)
                    if valid then
                        owned+=1
                        fallbackModels[#fallbackModels+1]=node
                    end
                end
            end
            if depth<3 and (node:IsA("Model") or node:IsA("Folder")) then
                local childrenChecked=0
                for _,child in ipairs(node:GetChildren()) do
                    childrenChecked+=1
                    if childrenChecked>220 or #queue>=1600 then break end
                    if child:IsA("Model") or child:IsA("Folder") then
                        enqueue(child,depth+1)
                    end
                end
            end
        end
        fallbackSummary=string.format("public fallback: %d nodes / %d models / %d player-owned (limit 1250)",
            visited,models,owned)
    end
    for _,model in ipairs(fallbackModels) do
        if model and model.Parent and not seen[model] then
            local ok,owner=pcall(identifyPlayer,model)
            if ok and owner and owner~=LocalPlayer then
                admit(model,owner,"Other Workspace container")
            end
        end
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
    lastScanDetails ..= " | "..fallbackSummary
    if #targets == 0 then
        if checked==0 and #fallbackModels==0 then
            lastScanDetails ..= " | no public player models in scanned paths"
        elseif unverified+unknownTeam>0 then
            lastScanDetails ..= " | public models exist but opposing team unverified"
        else
            lastScanDetails ..= " | no confirmed enemy positions available"
        end
    end
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
    local allowed,reason=enemyGroupAllowed(group)
    if not allowed then
        calibrationMessage="Enemy calibration rejected: "..tostring(reason)
        log("WARN",calibrationMessage)
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
    local allowed,reason=enemyGroupAllowed(selected)
    if not allowed then
        calibrationMessage="Enemy selection rejected: "..tostring(reason)
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
-- Fallback only: the game does not replicate standard joint links for
-- every character. Use two different screen-space proportions rather than
-- imposing an upright figure on a crouched/prone/ragdolled silhouette.
-- These lines are deliberately estimates, not measured bone joints.
local ESTIMATED_UPRIGHT_JOINTS = {
    {0.50,0.12}, -- head
    {0.50,0.24}, -- neck
    {0.50,0.43}, -- chest
    {0.50,0.57}, -- hips
    {0.37,0.27}, {0.25,0.39}, {0.22,0.57}, -- left arm
    {0.63,0.27}, {0.75,0.39}, {0.78,0.57}, -- right arm
    {0.43,0.59}, {0.40,0.76}, {0.39,0.91}, -- left leg
    {0.57,0.59}, {0.60,0.76}, {0.61,0.91}  -- right leg
}
local ESTIMATED_WIDE_JOINTS = {
    {0.40,0.26}, -- head (approximate on a broad horizontal silhouette)
    {0.45,0.43}, -- neck
    {0.53,0.52}, -- chest
    {0.67,0.60}, -- hips
    {0.35,0.45}, {0.23,0.49}, {0.13,0.61}, -- left arm
    {0.65,0.43}, {0.80,0.51}, {0.90,0.60}, -- right arm
}
local ESTIMATED_UPRIGHT_EDGES = {
    {1,2}, {2,3}, {3,4},
    {2,5}, {5,6}, {6,7},
    {2,8}, {8,9}, {9,10},
    {4,11}, {11,12}, {12,13},
    {4,14}, {14,15}, {15,16}
}
-- When the projected rig is broad and short, apparent knees and feet
-- cannot be inferred from bounds. Do not invent vertical leg lines.
local ESTIMATED_WIDE_EDGES = {
    {1,2}, {2,3}, {3,4},
    {2,5}, {5,6}, {6,7},
    {2,8}, {8,9}, {9,10}
}
local function updateEstimatedSkeleton(w,model,camera,left,top,right,bottom,color)
    local width,height=right-left,bottom-top
    if width<=3 or height<=6 then
        for _,line in ipairs(w.skeleton) do line.Visible=false end
        return false
    end
    -- The prone/ragdoll silhouette in Phantom Forces can be over twice as
    -- wide as it is tall. A standing rig is usually taller than it is wide.
    local isWide=(width/height)>=1.35
    local joints=isWide and ESTIMATED_WIDE_JOINTS or ESTIMATED_UPRIGHT_JOINTS
    local edges=isWide and ESTIMATED_WIDE_EDGES or ESTIMATED_UPRIGHT_EDGES

    -- Prefer an actual replicated head part when one exists. Unlike guessed
    -- geometry, this follows the real character while moving or animating.
    local headPart=model:FindFirstChild("Head",true)
    local headX,headY=nil,nil
    if headPart and headPart:IsA("BasePart") then
        local projected,visible=camera:WorldToViewportPoint(headPart.Position)
        if visible and projected.Z>0 then
            if projected.X>=left and projected.X<=right
                and projected.Y>=top and projected.Y<=bottom then
                headX,headY=projected.X,projected.Y
            end
        end
    end

    local function position(index)
        local v=joints[index]
        local x=left+width*v[1]
        local y=top+height*v[2]
        if index==1 and headX and headY then
            x,y=headX,headY
        elseif index==2 and headX and headY then
            -- Keep the neck near the actual head if its position is known.
            local neckX=headX+(isWide and width*0.05 or 0)
            local neckY=headY+height*(isWide and 0.14 or 0.12)
            x=math.clamp(neckX,left+width*0.08,right-width*0.08)
            y=math.clamp(neckY,top+height*0.08,bottom-height*0.08)
        end
        return x,y
    end
    for index,line in ipairs(w.skeleton) do
        local pair=edges[index]
        if pair then
            local ax,ay=position(pair[1])
            local bx,by=position(pair[2])
            put(line,ax,ay,bx,by,color,1)
        else
            line.Visible=false
        end
    end
    return isWide
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
    local wideCount=0
    for _, t in ipairs(targets) do
        -- A despawning or malformed model cannot suppress every ESP marker.
        local ok,err=pcall(function()
        local model = t.model
        local w = widgets[model]
        -- Re-check on every render frame so team switches immediately
        -- suppress stale markers before the next discovery refresh.
        local shouldShow = model.Parent ~= nil and t.root and t.root.Parent ~= nil
            and classifyTarget(model,t.player)=="enemy"
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
            w.root.Visible = true
            w.distance.Visible = state.distances
            if state.distances then
                w.distance.Text=string.format("%d studs",math.floor(distance+0.5))
                w.distance.Position = UDim2.fromOffset(left-30,bottom+3)
                w.distance.Size = UDim2.fromOffset(right-left+60,16)
            end
            w.tracer.Visible = state.tracers
            if state.tracers then
                local viewport = camera.ViewportSize
                put(w.tracer,viewport.X/2,viewport.Y-10,(left+right)/2,bottom,clr,1)
            end
            if state.skeleton and #t.bones == 0 then
                local wide=updateEstimatedSkeleton(w,model,camera,left,top,right,bottom,clr)
                approximateCount += 1
                if wide then wideCount += 1 end
            else
                updateSkeleton(w,t,camera,clr)
            end
            updateHighlight(w,model,camera,clr)
            done += 1
        else
            hideWidget(w)
        end
        end)
        if not ok then
            stats.espRenderErrors=(stats.espRenderErrors or 0)+1
            hideWidget(widgets[t.model])
            if stats.espRenderErrors<=4 then
                log("ERROR","ESP model render failed: "..tostring(err))
            end
        end
    end
    stats.rendered = done
    stats.approxSkeletons = approximateCount
    stats.wideSkeletons = wideCount
end


-- AIMBOT / PHASE 1 -------------------------------------------------------------
-- Uses the exact same enemy-only target list as ESP; no new scanning,
-- replication hooks, character writes, weapon modification, or remote calls.
-- Client camera control is game-dependent and must be confirmed in-game.
local AIM_RENDER_BIND = "SPECTRA_Aim_" .. tostring(LocalPlayer.UserId)
local aimMouseMove = type(mousemoverel)=="function" and mousemoverel or nil
local aimRmbHeld = false
local aimKeyHeld={["Left Alt"]=false,["X"]=false}
local aimStatus = "Disabled"
local aimSelected = nil
local aimSelectionCount = 0
local aimLockAcquisitions = 0
local aimLockRetainedFrames = 0
local aimLockReleases = 0
local aimMetrics={targetSwitches=0,mouseWrites=0,mouseErrors=0,
    lastMouseDX=0,lastMouseDY=0,lastMethod="None",
    snapFrames=0,screenErrorPx=0,cameraSnapWrites=0}
local aimBackend = "None"
local aimUpdates = 0
local aimErrors = 0
-- Distinguish accepted calls from observable camera movement.
local aimLastActiveStatus = "Never activated"
local aimMovementSamples = 0
local aimCameraMoved = 0
local aimLastMoveDegrees = 0
local aimLastAngularError = 0
local aimLastWrittenCamera = nil
local aimCameraResetEvents = 0
local aimLastTargetModel = nil
local aimLastWriteDegrees = 0
local aimLastResetDegrees = 0
local aimOverrideStreak = 0
local aimOverrideSamples = 0
local aimLastRetained = false
-- Aim gate diagnostics survive menu opening, unlike the live aimStatus.
local aimGateCounts = {
    disabled=0, menu=0, picker=0, noCamera=0, textFocus=0,
    activation=0, noTarget=0, tracking=0, renderErrors=0
}
local aimLastGameplayStatus = "No test with the menu hidden yet"
local aimLastGameplayTime = "never"
local aimTargetProbe = {enemies=0,onScreen=0,insideFov=0,eligible=0,blocked=0}
local aimLastActivationDetected = false
local function recordAimGate(reason, status, gameplay)
    aimGateCounts[reason]=(aimGateCounts[reason] or 0)+1
    aimStatus=status
    if gameplay then
        aimLastGameplayStatus=status
        aimLastGameplayTime=os.date("%H:%M:%S")
    end
end
-- Experimental camera stabilization for Scriptable camera controllers.
-- This listens for subsequent Camera.CFrame writes; it does not modify the
-- game's camera module, mouse APIs, weapon logic or remote interfaces.
local aimObservedCamera=nil
local aimObservedCameraConnection=nil
local aimCorrectionActive=false
local aimCorrectionPoint=nil
local aimCorrectionTarget=nil
local aimCorrectionGuard=false
local aimCorrectionsThisFrame=0
local aimCorrectionCount=0
local aimCorrectionErrors=0
local aimCorrectionObservations=0
local aimCorrectionAngle=0

local function angleBetween(a,b)
    return math.deg(math.acos(math.clamp(a:Dot(b),-1,1)))
end

local function disableAimCorrection()
    aimCorrectionActive=false
    aimCorrectionPoint=nil
    aimCorrectionTarget=nil
end

local function observeAimCamera(camera)
    if aimObservedCamera==camera then return end
    disableAimCorrection()
    if aimObservedCameraConnection then
        aimObservedCameraConnection:Disconnect()
        aimObservedCameraConnection=nil
    end
    aimObservedCamera=camera
    if not camera then return end
    aimObservedCameraConnection=connect(camera:GetPropertyChangedSignal("CFrame"),function()
        if not alive or not aimCorrectionActive or aimCorrectionGuard
            or not state.aimEnabled or (window and window.Visible)
            or pickerActive or UserInputService:GetFocusedTextBox() then return end
        if camera~=Workspace.CurrentCamera or not aimCorrectionPoint
            or not aimCorrectionTarget or not aimCorrectionTarget.Parent then return end
        if aimCorrectionsThisFrame>=2 then return end
        local before=camera.CFrame
        local targetVector=aimCorrectionPoint-before.Position
        if targetVector.Magnitude<0.5 then return end
        local targetDirection=targetVector.Unit
        local remaining=angleBetween(before.LookVector,targetDirection)
        aimCorrectionAngle=remaining
        if remaining<0.15 or remaining>45 then return end
        aimCorrectionObservations+=1
        -- Bounded reapplication only when another writer has changed CFrame.
        -- Guard and 2-corrections-per-frame cap prevent a recursive event storm.
        local alpha=state.aimStyle=="Snap" and 1
            or math.clamp(0.55/math.sqrt(math.max(1,state.aimSmoothing)),0.15,0.55)
        local desired=CFrame.lookAt(before.Position,aimCorrectionPoint)
        aimCorrectionGuard=true
        aimCorrectionsThisFrame+=1
        local ok,err=pcall(function()
            camera.CFrame=alpha>=1 and desired or before:Lerp(desired,alpha)
        end)
        aimCorrectionGuard=false
        if ok then
            aimCorrectionCount+=1
        else
            aimCorrectionErrors+=1
            if aimCorrectionErrors<=3 then
                log("ERROR","Camera correction failed: "..tostring(err))
            end
            disableAimCorrection()
        end
    end)
end

local function getAimPosition(target)
    local model = target.model
    if not model or not model.Parent then return nil end
    local point = state.aimPoint
    local names
    if point=="Head" then
        names={"Head","head"}
    elseif point=="Chest" then
        names={"UpperTorso","Torso","Chest","Body"}
    else
        names={}
    end
    for _,name in ipairs(names) do
        local part=model:FindFirstChild(name,true)
        if part and part:IsA("BasePart") then return part.Position end
    end
    local ok, cf, size=pcall(function() return model:GetBoundingBox() end)
    if not ok then
        return target.root and target.root.Position or nil
    end
    if point=="Head" then
        return cf.Position+Vector3.new(0,size.Y*0.31,0)
    elseif point=="Chest" then
        return cf.Position+Vector3.new(0,size.Y*0.12,0)
    end
    return cf.Position
end

local function getAimPositions(target)
    if state.aimPoint~="Nearest" then
        local p=getAimPosition(target)
        return p and {p} or {}
    end
    -- Use the nearest actual body part on-screen, not a generic box center.
    -- Bounding-box center remains a fallback for custom rigs.
    local points,seen={},{}
    local names={
        "Head","UpperTorso","Torso","Chest","Body","HumanoidRootPart",
        "LeftUpperArm","RightUpperArm","LeftLowerArm","RightLowerArm",
        "LeftHand","RightHand","Left Arm","Right Arm",
        "LowerTorso","LeftUpperLeg","RightUpperLeg","LeftLowerLeg","RightLowerLeg",
        "LeftFoot","RightFoot","Left Leg","Right Leg"
    }
    local model=target.model
    for _,name in ipairs(names) do
        local part=model:FindFirstChild(name,true)
        if part and part:IsA("BasePart") and not seen[part] then
            points[#points+1]=part.Position
            seen[part]=true
        end
    end
    if #points==0 then
        local point=getAimPosition(target)
        if point then points[1]=point end
    end
    return points
end

local function aimHasLineOfSight(camera,target,position)
    -- With the line-of-sight requirement disabled, target selection may
    -- follow replicated enemy models behind map geometry. This changes
    -- client targeting ONLY, not weapon collisions or bullet penetration.
    if not state.aimVisibleOnly then return true end
    local origin=camera.CFrame.Position
    local vector=position-origin
    if vector.Magnitude<0.5 then return false end
    local exclusions={camera}
    if LocalPlayer.Character then exclusions[#exclusions+1]=LocalPlayer.Character end
    -- FPS games may omit LocalPlayer.Character. The camera-followed
    -- body must not obstruct its own LOS raycast.
    local subject=camera.CameraSubject
    if subject then
        local followed=subject:IsA("Model") and subject
            or subject:FindFirstAncestorWhichIsA("Model")
        if followed and followed~=target.model then
            exclusions[#exclusions+1]=followed
        end
    end
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances=exclusions
    local hit=Workspace:Raycast(origin,vector,params)
    return not hit or hit.Instance:IsDescendantOf(target.model)
end

-- The FOV constrains first acquisition; after locking, a living eligible target
-- remains tracked even when mouse movement puts it outside the FOV circle.
-- This never discovers new entities or bypasses game-side replication.
local function getPersistentAimTarget(camera)
    if not state.aimLock or not aimSelected or not aimSelected.model then return nil,nil,nil end
    local lockedModel=aimSelected.model
    if not lockedModel:IsDescendantOf(Workspace) then return nil,nil,nil end
    -- Discovery refreshes target records; resolve against its newest snapshot.
    local trackedTarget=nil
    for _,candidate in ipairs(targets) do
        if candidate.model==lockedModel then
            trackedTarget=candidate
            break
        end
    end
    if not trackedTarget or not trackedTarget.root or not trackedTarget.root.Parent then
        return nil,nil,nil
    end
    local root=trackedTarget.root
    local origin=camera.CFrame.Position
    if (root.Position-origin).Magnitude>MAX_DISTANCE then return nil,nil,nil end
    if classifyTarget(lockedModel,trackedTarget.player)~="enemy" then
        return nil,nil,nil
    end
    local humanoid=lockedModel:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health<=0 then return nil,nil,nil end

    local bestPosition,bestAngle=nil,math.huge
    for _,position in ipairs(getAimPositions(trackedTarget)) do
        local difference=position-origin
        if difference.Magnitude>0.5 and aimHasLineOfSight(camera,trackedTarget,position) then
            local angle=angleBetween(camera.CFrame.LookVector,difference.Unit)
            if angle<bestAngle then
                bestPosition,bestAngle=position,angle
            end
        end
    end
    if not bestPosition then return nil,nil,nil end
    local projected=camera:WorldToViewportPoint(bestPosition)
    local viewport=camera.ViewportSize
    local delta=Vector2.new(projected.X-viewport.X*0.5,projected.Y-viewport.Y*0.5)
    return trackedTarget,bestPosition,delta
end

local function chooseAimTarget(camera)
    aimTargetProbe={enemies=0,onScreen=0,insideFov=0,eligible=0,blocked=0}
    local size=camera.ViewportSize
    if size.X<1 or size.Y<1 then return nil,nil end
    local center=Vector2.new(size.X*0.5,size.Y*0.5)
    local best,bestPoint,bestDelta,bestScore=nil,nil,nil,math.huge
    aimSelectionCount=0
    for _,t in ipairs(targets) do
        local model,root=t.model,t.root
        if model and model.Parent and root and root.Parent then
            local enemy=classifyTarget(model,t.player)=="enemy"
            local humanoid=model:FindFirstChildOfClass("Humanoid")
            if enemy and (not humanoid or humanoid.Health>0)
                and (root.Position-camera.CFrame.Position).Magnitude <= MAX_DISTANCE then
                aimTargetProbe.enemies+=1
                local onScreenAny,inFovAny,blockedAny=false,false,false
                local nearestPoint,nearestDelta,nearestDistance=nil,nil,math.huge
                for _,point in ipairs(getAimPositions(t)) do
                    local projected,onScreen=camera:WorldToViewportPoint(point)
                    if onScreen and projected.Z>0.5 then
                        onScreenAny=true
                        local delta=Vector2.new(projected.X,projected.Y)-center
                        local distance=delta.Magnitude
                        -- Every body part uses the same strict FOV boundary.
                        if distance<=state.aimFovRadius then
                            inFovAny=true
                            if aimHasLineOfSight(camera,t,point) then
                                if distance<nearestDistance then
                                    nearestPoint=point
                                    nearestDelta=delta
                                    nearestDistance=distance
                                end
                            else
                                blockedAny=true
                            end
                        end
                    end
                end
                if onScreenAny then aimTargetProbe.onScreen+=1 end
                if inFovAny then aimTargetProbe.insideFov+=1 end
                if nearestPoint then
                    aimTargetProbe.eligible+=1
                    aimSelectionCount+=1
                    local locked=state.aimSticky and aimSelected
                        and aimSelected.model==model
                    local bonus=locked and math.min(24,state.aimFovRadius*0.15) or 0
                    local score=nearestDistance-bonus
                    if score<bestScore then
                        best,bestPoint,bestDelta,bestScore=t,nearestPoint,nearestDelta,score
                    end
                elseif blockedAny then
                    aimTargetProbe.blocked+=1
                end
            end
        end
    end
    return best,bestPoint,bestDelta
end

local function updateAimVisual(camera)
    if not aimFovFrame or not aimFovFrame.Parent then return end
    local visible=state.aimEnabled and state.aimFovVisible and camera~=nil
    aimFovFrame.Visible=visible
    if visible then
        local radius=state.aimFovRadius
        local viewport=camera.ViewportSize
        aimFovFrame.Size=UDim2.fromOffset(radius*2,radius*2)
        aimFovFrame.Position=UDim2.fromOffset(viewport.X/2-radius,viewport.Y/2-radius)
    end
end

local function aimActivationHeld()
    local key=state.aimKey
    if key=="Always" then return true end
    if key=="Right Mouse" then
        local held=aimRmbHeld
        local ok,pressed=pcall(function()
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        end)
        if ok then held=pressed end
        return held
    end
    -- Support any valid keyboard key selected using the Aim Key binder.
    -- Preserve "Left Alt" from older configurations for compatibility.
    local name=key=="Left Alt" and "LeftAlt" or key
    local valid,code=pcall(function() return Enum.KeyCode[name] end)
    if not valid or not code then return false end
    local ok,pressed=pcall(function()
        return UserInputService:IsKeyDown(code)
    end)
    if ok then return pressed end
    return aimKeyHeld[key]==true
end

local function runAimbot(dt)
    aimCorrectionsThisFrame=0
    disableAimCorrection()
    if not alive or not state.aimEnabled then
        recordAimGate("disabled","Disabled",false)
        aimSelected=nil
        return
    end
    local camera=Workspace.CurrentCamera
    if not camera then
        recordAimGate("noCamera","No camera",true)
        aimSelected=nil
        return
    end
    if pickerActive then
        recordAimGate("picker","Calibration picker open",false)
        aimSelected=nil
        return
    end
    if window and window.Visible then
        recordAimGate("menu","Inactive (SPECTRA menu open)",false)
        aimSelected=nil
        return
    end
    if UserInputService:GetFocusedTextBox() then
        recordAimGate("textFocus","Inactive (text input focused)",true)
        aimSelected=nil
        return
    end
    -- The activation key may be RMB, a keyboard key, or Always.
    local active=aimActivationHeld()
    aimLastActivationDetected=active
    if not active then
        recordAimGate("activation","Hold Aim Key: "..state.aimKey,true)
        aimSelected=nil
        return
    end
    local previous=aimSelected
    local target,point,delta=getPersistentAimTarget(camera)
    if target then
        aimLockRetainedFrames+=1
    else
        if previous and state.aimLock then aimLockReleases+=1 end
        -- Acquire a new enemy only within FOV; keep it even after the
        -- player moves their mouse away or the target leaves that circle.
        target,point,delta=chooseAimTarget(camera)
    end
    if not target then
        recordAimGate("noTarget",state.aimVisibleOnly
            and "No eligible enemy inside FOV with clear line of sight"
            or "No eligible enemy inside FOV to lock",true)
        aimSelected=nil
        return
    end
    if previous and previous.model~=target.model then
        aimMetrics.targetSwitches+=1
    end
    if state.aimLock and (not previous or previous.model~=target.model) then
        aimLockAcquisitions+=1
    end
    aimSelected=target
    aimMetrics.screenErrorPx=delta.Magnitude
    if state.aimStyle=="Snap" then aimMetrics.snapFrames+=1 end
    -- Prefer relative mouse input on Scriptable cameras when exposed;
    -- fallback to bounded CFrame stabilization when unavailable.
    -- Neither backend proves that weapon aim follows the camera.
    local requested=state.aimMethod
    -- For game-controlled weapon aim, use the ordinary relative mouse path
    -- whenever available instead of forcing Camera.CFrame by default.
    -- Camera fallback remains visual-only and may not move weapon aim.
    local method=requested=="Auto"
        and (aimMouseMove and "Mouse" or "Stabilized")
        or requested
    aimMetrics.lastMethod=method
    if method=="Mouse" then
        if not aimMouseMove then
            aimStatus="Mouse aiming unavailable in executor"
            aimBackend="Unavailable"
            return
        end
        -- Aim moves through the input path so custom camera scripts can
        -- receive relative mouse movement. Sensitivity varies per game.
        -- Snap sends a stronger bounded correction along the game's
        -- input path; this cannot establish how the weapon is aimed.
        local snap=state.aimStyle=="Snap"
        local scale=snap and (0.65*state.aimSnapStrength/100)
            or (0.70/math.max(1,state.aimSmoothing))
        -- A target kept locked behind the camera has inverted projection
        -- coordinates. Use signed camera-space angles instead of the
        -- screen-space projection when a target is behind or off-screen.
        local projected,onScreen=camera:WorldToViewportPoint(point)
        local correction=delta
        if not onScreen or projected.Z<=0.5 then
            local direction=point-camera.CFrame.Position
            if direction.Magnitude>0.5 then
                local localDirection=camera.CFrame:VectorToObjectSpace(direction.Unit)
                local yaw=math.atan2(localDirection.X,-localDirection.Z)
                local pitch=math.atan2(
                    localDirection.Y,
                    math.sqrt(localDirection.X*localDirection.X
                        +localDirection.Z*localDirection.Z))
                local pixelsPerRadian=math.max(1,camera.ViewportSize.Y)
                    / math.rad(math.clamp(camera.FieldOfView,10,120))
                correction=Vector2.new(yaw*pixelsPerRadian,-pitch*pixelsPerRadian)
            end
        end
        -- Mouse-driven pull-back also moves the game-controlled weapon.
        -- Increase correction for an already acquired target, but taper it
        -- near the crosshair to avoid visible oscillation. No camera writes.
        local pull=state.aimLock and (state.aimPullStrength/100) or 1
        local taper=math.clamp(correction.Magnitude/18,0.45,1)
        local actualScale=scale*pull*taper
        local cap=snap and 260 or 65
        local dx=math.clamp(correction.X*actualScale,-cap,cap)
        local dy=math.clamp(correction.Y*actualScale,-cap,cap)
        local pixelX=dx>=0 and math.floor(dx+0.5) or math.ceil(dx-0.5)
        local pixelY=dy>=0 and math.floor(dy+0.5) or math.ceil(dy-0.5)
        aimMetrics.lastMouseDX=pixelX
        aimMetrics.lastMouseDY=pixelY
        if pixelX~=0 or pixelY~=0 then
            local ok,err=pcall(aimMouseMove,pixelX,pixelY)
            if not ok then
                aimErrors+=1
                aimMetrics.mouseErrors+=1
                aimBackend="Mouse error"
                aimStatus="Mouse move failed: "..tostring(err)
                return
            end
            aimMetrics.mouseWrites+=1
        end
        aimBackend=state.aimStyle.." relative mouse input (unverified)"
        aimLastActiveStatus=string.format(
            "%s mouse correction (%d,%d), screen error %.0f px; camera/weapon response unverified",
            state.aimStyle,pixelX,pixelY,aimMetrics.screenErrorPx)
    else
        -- Client camera interpolation: works visually only if the game's
        -- camera controller permits it. It does not guarantee bullet aiming.
        local before=camera.CFrame
        local desired=CFrame.lookAt(before.Position,point)
        local desiredDir=desired.LookVector
        aimLastAngularError=angleBetween(before.LookVector,desiredDir)
        if aimLastWrittenCamera and aimLastTargetModel==target.model then
            local reset=angleBetween(before.LookVector,aimLastWrittenCamera.LookVector)
            aimLastResetDegrees=reset
            -- The old 2.5 degree cutoff missed subtle per-frame resets.
            -- Compare lost rotation against the amount actually written.
            local wasReversed=aimLastWriteDegrees>0.08
                and reset>math.max(0.12,aimLastWriteDegrees*0.50)
            if wasReversed then
                aimCameraResetEvents+=1
                aimOverrideStreak+=1
                aimOverrideSamples+=1
                aimLastRetained=false
            else
                aimOverrideStreak=0
                aimLastRetained=true
            end
        end
        local snap=state.aimStyle=="Snap"
        local alpha=snap and 1
            or (1-math.exp(-dt*30/math.max(1,state.aimSmoothing)))
        local nextCF=snap and desired or before:Lerp(desired,math.clamp(alpha,0,1))
        camera.CFrame=nextCF
        if snap then aimMetrics.cameraSnapWrites+=1 end
        local after=camera.CFrame
        aimLastMoveDegrees=angleBetween(before.LookVector,after.LookVector)
        aimLastWriteDegrees=aimLastMoveDegrees
        aimMovementSamples+=1
        if aimLastMoveDegrees>0.01 then aimCameraMoved+=1 end
        aimLastWrittenCamera=after
        aimLastTargetModel=target.model
        aimBackend=state.aimStyle.." "
            ..(method=="Stabilized" and "camera stabilization (experimental)" or "camera")
        if method=="Stabilized" then
            -- Observe only the current camera and only while an enemy target is
            -- actively selected. Nothing persists when the UI is opened.
            observeAimCamera(camera)
            aimCorrectionPoint=point
            aimCorrectionTarget=target.model
            aimCorrectionActive=true
        end
        if aimOverrideStreak>=12 then
            aimLastActiveStatus=string.format(
                "Game appears to override camera: %.2f deg lost last frame (%d consecutive frames)",
                aimLastResetDegrees,aimOverrideStreak)
        else
            aimLastActiveStatus=string.format(
                "Camera wrote %.2f deg; aim error %.2f deg; lost last frame %.2f deg",
                aimLastMoveDegrees,aimLastAngularError,aimLastResetDegrees)
        end
    end
    aimUpdates+=1
    recordAimGate("tracking",
        (state.aimLock and "LOCKED " or "Tracking ")
        ..(target.player and target.player.Name or "enemy rig")
        .." ("..aimBackend..")",true)
end


-- SESSION-ONLY CHARACTER CALIBRATION ------------------------------------------
-- Automatic calibration after locally observed WASD and camera-followed rig
-- movement correlate over a bounded 3-second window; NOT ownership proof.
-- Session calibration is revoked when the camera or rig changes.
local SelfCalibration=(function()
    local cal={
        pending=nil,active=nil,status="Watching for first spawn",
        rearmRequested=false,initialCaptureArmed=true,retryAt=0
    }
    local function currentContext()
        local camera=Workspace.CurrentCamera
        local subject=camera and camera.CameraSubject
        local model=subject and (subject:IsA("Model") and subject
            or subject:FindFirstAncestorWhichIsA("Model")) or nil
        local root=model and getRoot(model) or nil
        return camera,subject,model,root
    end
    local function verifyContext(record)
        if not record then return false,"No candidate" end
        local camera,subject,model,root=currentContext()
        if camera~=record.camera or subject~=record.subject or model~=record.model
            or root~=record.root then
            return false,"Camera or character model changed (respawn/spectator possible)"
        end
        if not model or not model.Parent or not root or not root.Parent
            or not subject or not subject.Parent then
            return false,"Character model or camera subject was removed"
        end
        if root.Anchored then return false,"Root became anchored" end
        if LocalPlayer.Character and LocalPlayer.Character~=model then
            return false,"Player.Character points to a different character"
        end
        local known=identifyPlayer(model)
        if known and known~=LocalPlayer then
            return false,"Model identified as another player"
        end
        local ok,native=pcall(function() return Players:GetPlayerFromCharacter(model) end)
        if ok and native and native~=LocalPlayer then
            return false,"Native owner lookup identifies another player"
        end
        if subject:IsA("Humanoid") then
            local healthOK,health=pcall(function() return subject.Health end)
            if healthOK and type(health)=="number" and health<=0 then
                return false,"Humanoid has died"
            end
        end
        local distOk,dist=pcall(function()
            return (camera.CFrame.Position-root.Position).Magnitude
        end)
        if not distOk or dist>12 then return false,"Camera no longer near character root" end
        return true,"Camera/model match"
    end
    local function clear(reason)
        local wasActive=cal.active~=nil
        local hadPending=cal.pending~=nil
        cal.pending=nil
        cal.active=nil
        if reason=="Cleared by user" or reason=="SPECTRA unloaded"
            or reason=="New observation started" then
            cal.rearmRequested=false
            cal.initialCaptureArmed=false
        elseif wasActive then
            -- Previous confirmed model changed. Gather evidence again;
            -- never transfer its confirmation to a new model.
            cal.rearmRequested=true
        end
        cal.status=cal.rearmRequested
            and "Redeploy detected: walk for automatic 3s character check"
            or "Not calibrated: "..tostring(reason or "cleared")
        if wasActive or hadPending then
            print("[SPECTRA CAL] "..cal.status)
        end
    end
    local function offer(observation)
        cal.pending=nil
        if not observation or observation.changedSubject~=0
            or observation.samplesWithInput<10 or observation.motionAndInput<9
            or observation.humanoidMoveSamples<8
            or observation.secondsWithInput<1.5 or observation.rootPath<12
            or math.abs(observation.rootPath-observation.cameraPath)>8 then
            cal.status="No eligible candidate: insufficient stable input/motion evidence"
            return false
        end
        local camera,subject,model,root=currentContext()
        if camera~=observation.firstCamera or subject~=observation.firstSubject
            or model~=observation.firstModel or root~=observation.firstRoot then
            cal.status="No eligible candidate: camera/model changed since observation"
            return false
        end
        local candidate={camera=camera,subject=subject,model=model,root=root,time=os.clock()}
        local ok,reason=verifyContext(candidate)
        if not ok then
            cal.status="No eligible candidate: "..reason
            return false
        end
        if not subject:IsA("Humanoid") then
            cal.status="No eligible candidate: camera subject is not a Humanoid"
            return false
        end
        cal.pending=candidate
        cal.status="Movement-matched candidate: "..model.Name.." | ownership UNVERIFIED; validating"
        print("[SPECTRA CAL] "..cal.status)
        return true
    end
    local function confirm()
        local p=cal.pending
        if not p then
            log("WARN","No movement-matched candidate. Walk to start an automatic 3-second check.")
            return false
        end
        if os.clock()-p.time>60 then
            clear("Candidate expired; repeat the short movement observation")
            return false
        end
        local ok,reason=verifyContext(p)
        if not ok then clear(reason);return false end
        cal.active=p
        cal.pending=nil
        cal.rearmRequested=false
        cal.initialCaptureArmed=false
        cal.status="AUTO-CALIBRATED movement-matched model "..p.model.Name
            .." (owner UNVERIFIED; local modifiers only)"
        print("[SPECTRA CAL] "..cal.status)
        log("WARN","Automatic camera-rig calibration is input correlation, NOT ownership proof. Server acceptance remains unverified.")
        return true
    end
    local function validate()
        if not cal.active then return false end
        local ok,reason=verifyContext(cal.active)
        if not ok then clear(reason);return false end
        return true
    end
    local function isCurrent(model)
        return validate() and model~=nil and model==cal.active.model
    end
    local function readyForRearm()
        if not (cal.rearmRequested or cal.initialCaptureArmed)
            or cal.active or cal.pending or os.clock()<cal.retryAt then return false end
        local camera,subject,model,root=currentContext()
        if not camera or not subject or not subject:IsA("Humanoid")
            or not model or not root then return false end
        local eligible=verifyContext({camera=camera,subject=subject,model=model,root=root})
        return eligible
    end
    local function markRearmStarted()
        cal.rearmRequested=false
        cal.initialCaptureArmed=false
    end
    local function retry(reason)
        cal.pending=nil
        cal.active=nil
        cal.rearmRequested=true
        cal.initialCaptureArmed=false
        cal.retryAt=os.clock()+2
        cal.status="Calibration deferred: "..tostring(reason)
            ..". Keep walking after 2 seconds to retry."
    end
    local function status()
        if cal.active then validate() end
        if cal.pending then
            local ok,reason=verifyContext(cal.pending)
            if not ok then clear(reason) end
        end
        return cal.status
    end
    cal.offer=offer
    cal.retry=retry
    cal.readyForRearm=readyForRearm
    cal.markRearmStarted=markRearmStarted
    cal.confirm=confirm
    cal.clear=clear
    cal.validate=validate
    cal.isCurrent=isCurrent
    cal.statusText=status
    return cal
end)()

-- MOVEMENT MODIFIERS: verified or automatically movement-matched session rig only.
-- Private function scope avoids exhausting Luau main-chunk local registers.
local Movement = (function()
    -- A custom game controller
    -- can reject every local property write; never manipulate unidentified rigs.
    local movement={
        model=nil,root=nil,humanoid=nil,status="No verified local character",source="none",
        lastScan=0,lastJump=0,errors=0,
        lastProbe=nil,measuredSpeed=0,measuredVertical=0,
        spaceHeld=false,antiOffset=0,verifiedFrames=0,unavailableFrames=0,
        originalHum=nil,
        writes={speed=0,jump=0,fall=0,anti=0}
    }

    local function movementHasModes()
        return state.speedHack or state.infiniteJump
            or state.noFallDamage or state.antiAim
    end

    local function restoreMovement()
        -- Undo visual yaw jitter if it remains active when toggled off,
        -- the character changes, or SPECTRA is unloaded.
        if movement.antiOffset~=0 and movement.root and movement.root.Parent then
            pcall(function()
                movement.root.CFrame=movement.root.CFrame*CFrame.Angles(0,-movement.antiOffset,0)
            end)
        end
        local old=movement.originalHum
        if old and old.h and old.h.Parent then
            pcall(function()
                old.h.WalkSpeed=old.walk
            end)
        end
        movement.originalHum=nil
        movement.antiOffset=0
    end

    local function setMovementRig(model,source)
        if not model or not model.Parent or not model:IsA("Model") then return false end
        if model~=LocalPlayer.Character and identifyPlayer(model)~=LocalPlayer
            and not SelfCalibration.isCurrent(model) then return false end
        local root=getRoot(model)
        if not root or not root:IsA("BasePart") or not root.Parent then return false end
        if model~=movement.model or root~=movement.root then
            restoreMovement()
            movement.model=model
            movement.root=root
            movement.humanoid=model:FindFirstChildWhichIsA("Humanoid",true)
            movement.source=source
            movement.verifiedFrames=0
            movement.antiOffset=0
        end
        movement.status=(SelfCalibration.isCurrent(model)
            and "Movement-matched camera rig; ownership UNVERIFIED ("..source..")"
            or "Verified local character ("..source..")")
        return true
    end

    local function findMovementRig(force)
        if not force and movement.root and movement.root.Parent and movement.model and movement.model.Parent
            and (movement.model==LocalPlayer.Character or identifyPlayer(movement.model)==LocalPlayer
                or SelfCalibration.isCurrent(movement.model)) then
            return movement.model,movement.root,movement.humanoid
        end
        -- Auto-calibration of a new life must bypass the normal 0.8s
        -- polling throttle so movement effects do not wait for an old character scan.
        local newlyConfirmed=SelfCalibration.active
            and SelfCalibration.active.model~=movement.model
        if not force and not newlyConfirmed and os.clock()-movement.lastScan<0.8 then
            return nil,nil,nil
        end
        movement.lastScan=os.clock()
        if setMovementRig(LocalPlayer.Character,"Player.Character") then
            return movement.model,movement.root,movement.humanoid
        end
        local camera=Workspace.CurrentCamera
        local subject=camera and camera.CameraSubject
        if subject then
            local ancestor=subject:IsA("Model") and subject or subject:FindFirstAncestorWhichIsA("Model")
            if setMovementRig(ancestor,SelfCalibration.isCurrent(ancestor)
                and "automatic movement-match" or "identified CameraSubject") then
                return movement.model,movement.root,movement.humanoid
            end
        end
        local folder=Workspace:FindFirstChild("Players")
        if folder then
            local queue={{folder,0}}
            local i,examined=1,0
            while i<=#queue and examined<300 do
                local node,depth=queue[i][1],queue[i][2]
                i+=1
                for _,child in ipairs(node:GetChildren()) do
                    examined+=1
                    if examined>=300 then break end
                    if child:IsA("Model") then
                        if setMovementRig(child,"verified Workspace.Players") then
                            return movement.model,movement.root,movement.humanoid
                        end
                        if depth<2 then queue[#queue+1]={child,depth+1} end
                    elseif child:IsA("Folder") and depth<3 then
                        queue[#queue+1]={child,depth+1}
                    end
                end
            end
        end
        -- Some custom experiences store player-owned models outside
        -- Workspace.Players. Search bounded direct roots and likely character
        -- containers, but only accept an explicitly verified owner.
        local direct=Workspace:FindFirstChild(LocalPlayer.Name)
        if setMovementRig(direct,"Workspace local-name model") then
            return movement.model,movement.root,movement.humanoid
        end
        local checked=0
        for _,node in ipairs(Workspace:GetChildren()) do
            if checked>=350 then break end
            checked+=1
            if node:IsA("Model") and setMovementRig(node,"Workspace owned model") then
                return movement.model,movement.root,movement.humanoid
            elseif node:IsA("Folder") and node~=folder then
                local label=node.Name:lower()
                if label:find("character",1,true) or label:find("player",1,true)
                    or label:find("avatar",1,true) or label:find("rig",1,true) then
                    for _,child in ipairs(node:GetChildren()) do
                        checked+=1
                        if checked>=350 then break end
                        if child:IsA("Model") and setMovementRig(child,"Workspace owned container") then
                            return movement.model,movement.root,movement.humanoid
                        end
                    end
                end
            end
        end
        if movement.model or movement.originalHum then restoreMovement() end
        movement.model=nil;movement.root=nil;movement.humanoid=nil
        movement.source="none"
        movement.unavailableFrames+=1
        movement.status="Unavailable: no verified self-rig. Phantom Forces may keep movement in a custom controller"
        return nil,nil,nil
    end

    local function movementDirection()
        local c=Workspace.CurrentCamera
        if not c then return Vector3.zero end
        local front=Vector3.new(c.CFrame.LookVector.X,0,c.CFrame.LookVector.Z)
        local right=Vector3.new(c.CFrame.RightVector.X,0,c.CFrame.RightVector.Z)
        if front.Magnitude<0.01 or right.Magnitude<0.01 then return Vector3.zero end
        front=front.Unit;right=right.Unit
        local d=Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then d+=front end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then d-=front end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then d+=right end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then d-=right end
        return d.Magnitude>0 and d.Unit or Vector3.zero
    end

    local function movementGrounded(root,h,range)
        if h and h.FloorMaterial~=Enum.Material.Air then return true end
        local params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances=movement.model and {movement.model} or {}
        return Workspace:Raycast(root.Position,Vector3.new(0,-(range or 4.5),0),params)~=nil
    end

    local function movementJump()
        local _,root,h=findMovementRig(false)
        if not root then return end
        local v=root.AssemblyLinearVelocity
        if h then pcall(function() h.Jump=true;h:ChangeState(Enum.HumanoidStateType.Jumping) end) end
        root.AssemblyLinearVelocity=Vector3.new(v.X,math.max(v.Y,49),v.Z)
        movement.writes.jump+=1
    end

    local function movementJumpRequested()
        if not state.infiniteJump then return end
        if os.clock()-movement.lastJump<0.15 then return end
        local _,root,h=findMovementRig(false)
        if not root then return end
        if state.infiniteJump then
            movement.lastJump=os.clock()
            local ok=pcall(movementJump)
            if not ok then movement.errors+=1 end
        end
    end

    local function movementProbe()
        local camera=Workspace.CurrentCamera
        local subject=camera and camera.CameraSubject
        local subjectText=subject and (subject.ClassName.."/"..subject.Name) or "nil"
        local playerFolder=Workspace:FindFirstChild("Players")
        local models,identifiable,localModels=0,0,0
        local sample={}
        if playerFolder then
            local stack={{playerFolder,0}}
            local n,checked=1,0
            while n<=#stack and checked<350 do
                local node,depth=stack[n][1],stack[n][2]
                n+=1
                for _,child in ipairs(node:GetChildren()) do
                    checked+=1
                    if checked>=350 then break end
                    if child:IsA("Model") then
                        models+=1
                        local owner=identifyPlayer(child)
                        if owner then
                            identifiable+=1
                            if owner==LocalPlayer then localModels+=1 end
                        end
                        if #sample<3 then
                            sample[#sample+1]=child.Name.."/"..(owner and owner.Name or "anonymous")
                        end
                        if depth<2 then stack[#stack+1]={child,depth+1} end
                    elseif child:IsA("Folder") and depth<3 then
                        stack[#stack+1]={child,depth+1}
                    end
                end
            end
        end
        local rig,root,h=findMovementRig(true)
        local line=string.format(
            "Local character: %s | CameraSubject: %s | Workspace.Players models: %d (identified: %d, local: %d) | resolved root: %s | Humanoid: %s",
            tostring(LocalPlayer.Character~=nil),subjectText,models,identifiable,localModels,
            root and root.Name or "none",tostring(h~=nil))
        movement.lastProbe=line.." | samples="..(#sample>0 and table.concat(sample,", ") or "none")
        return movement.lastProbe
    end

    local function movementReport()
        local w=movement.writes
        local rigOK=movement.root and movement.root.Parent and movement.model and movement.model.Parent
        local function status(name,enabled,dependency)
            if not enabled then return name..": OFF" end
            if not rigOK then return name..": UNAVAILABLE (no verified local character)" end
            if dependency=="humanoid" and not movement.humanoid then
                return name..": CUSTOM RIG (physics only; Humanoid API unavailable)"
            end
            return name..": LOCAL ATTEMPT (server result unverified)"
        end
        return table.concat({
            "Movement: "..movement.status.." | source="..movement.source,
            "Session calibration: "..SelfCalibration.statusText(),
            status("Speed",state.speedHack),
            status("Infinite Jump",state.infiniteJump),
            status("No Fall Damage",state.noFallDamage),
            status("Anti Aim",state.antiAim),
            string.format("Measured root velocity: %.1f horizontal / %.1f vertical studs/s",movement.measuredSpeed,movement.measuredVertical),
            string.format("Frames with verified local rig: %d | unavailable checks: %d",movement.verifiedFrames,movement.unavailableFrames),
            string.format("Write attempts: speed=%d jump=%d fall=%d anti=%d | errors=%d",
                w.speed,w.jump,w.fall,w.anti,movement.errors),
            movement.lastProbe or "Probe: not run (use modprobe)",
            "Client camera movement cannot substitute for a missing local character.",
            "Client-only writes cannot guarantee server-side fall-damage immunity or anti-aim."
        },"\n")
    end

    local function updateMovement(dt)
        if not alive then return end
        -- Some FPS controllers consume JumpRequest, so detect Space's key
        -- transition as a second, debounced input path.
        local spaceDown=UserInputService:IsKeyDown(Enum.KeyCode.Space)
        local newSpacePress=spaceDown and not movement.spaceHeld
        movement.spaceHeld=spaceDown
        if not movementHasModes() then
            if movement.originalHum or movement.antiOffset~=0 then
                restoreMovement()
            end
            local verified=movement.root and movement.root.Parent and movement.model and movement.model.Parent
            movement.status=verified and "Movement modifiers off; verified local character"
                or "Unavailable: no verified local character (movement modifiers off)"
            return
        end
        if newSpacePress and state.infiniteJump then
            movementJumpRequested()
        end
        local model,root,h=findMovementRig(false)
        if not root then return end
        if root.Anchored then movement.status="Unavailable: local root anchored";return end
        movement.verifiedFrames+=1
        local measured=root.AssemblyLinearVelocity
        movement.measuredSpeed=Vector3.new(measured.X,0,measured.Z).Magnitude
        movement.measuredVertical=measured.Y
        if h and not movement.originalHum then
            movement.originalHum={h=h,walk=h.WalkSpeed}
        end
        local old=movement.originalHum
        if h and old then
            if state.speedHack then
                h.WalkSpeed=math.clamp(state.speedValue,16,50);movement.writes.speed+=1
            else h.WalkSpeed=old.walk end
        end
        local dir=movementDirection()
        local v=root.AssemblyLinearVelocity
        if state.speedHack and dir.Magnitude>0 then
            -- Custom rigs may expose a Humanoid while their movement speed is
            -- driven by another controller. Apply owned-body velocity too.
            root.AssemblyLinearVelocity=Vector3.new(dir.X*math.clamp(state.speedValue,16,50),v.Y,dir.Z*math.clamp(state.speedValue,16,50))
            movement.writes.speed+=1
        end
        if state.noFallDamage then
            local fall=root.AssemblyLinearVelocity
            if fall.Y < -32 and movementGrounded(root,nil,7) then
                root.AssemblyLinearVelocity=Vector3.new(fall.X,-12,fall.Z)
                movement.writes.fall+=1
            end
        end
        if state.antiAim then
            local wanted=math.sin(os.clock()*20)*math.rad(35)
            root.CFrame=root.CFrame*CFrame.Angles(0,wanted-movement.antiOffset,0)
            movement.antiOffset=wanted
            movement.writes.anti+=1
        elseif movement.antiOffset~=0 then
            root.CFrame=root.CFrame*CFrame.Angles(0,-movement.antiOffset,0)
            movement.antiOffset=0
        end
        movement.status="Local writes attempted on verified rig; server response unverified"
    end


    return {
        data=movement,
        restore=restoreMovement,
        report=movementReport,
        probe=movementProbe,
        find=findMovementRig,
        jumpRequested=movementJumpRequested,
        update=updateMovement,
    }
end)()


-- READ-ONLY ROBLOX COMPATIBILITY INSPECTOR -----------------------------------
-- Uses public, replicated objects only. Never modifies camera, character,
-- weapon, inputs, events or server state. No hooks, memory reads or injections.
-- Reports are explicitly labeled "unverified" where replication/server control
-- cannot be established from a client-side observation.
local Compat=(function()
    local compat={
        text="No snapshot yet",lastTime="never",view=nil,
        previousSubject=nil,previousRoot=nil,previousPosition=nil,
        previousCameraPosition=nil,previousClock=nil,
        observation=nil,lastObservation="Not run",lastEmit=""
    }
    local function readable(fn,fallback)
        local ok,value=pcall(fn)
        if ok and value~=nil then return value end
        return fallback
    end
    local function bool(value)
        return value and "yes" or "no"
    end
    local function readEnum(value)
        return readable(function() return value.Name end,"unavailable")
    end
    local function category(character,rig,humanoid)
        if not character then return "UNAVAILABLE: no positively identified local character" end
        if not rig or not rig.Parent then return "UNAVAILABLE: verified model has no usable BasePart" end
        if rig.Anchored then return "RESTRICTED: local root is anchored" end
        if humanoid then return "EXPOSED: local model and Humanoid (server effect unverified)" end
        return "PARTIAL: owned custom rig; no Humanoid exposed (server effect unverified)"
    end

    -- Short, opt-in, read-only capture. Measures public local input and
    -- replicated subject/camera movement, never writes character state.
    -- Correlation is useful for troubleshooting but is NOT ownership proof.
    local function observationKeyDown()
        if readable(function() return UserInputService:GetFocusedTextBox()~=nil end,false) then
            return false
        end
        for _,key in ipairs({Enum.KeyCode.W,Enum.KeyCode.A,Enum.KeyCode.S,Enum.KeyCode.D}) do
            if readable(function() return UserInputService:IsKeyDown(key) end,false) then return true end
        end
        return false
    end
    local function startObservation(mode)
        if compat.observation then
            log("INFO","A compatibility capture is already running")
            return
        end
        local automaticCheck=mode=="redeploy" or mode=="initial"
        -- Do not let an earlier, unverified candidate remain authorized
        -- while a fresh capture examines a potentially different model.
        if SelfCalibration.active or SelfCalibration.pending then
            Movement.restore()
            Movement.data.model=nil;Movement.data.root=nil
            Movement.data.humanoid=nil;Movement.data.source="none"
            SelfCalibration.clear("New observation started")
        end
        if automaticCheck then SelfCalibration.markRearmStarted() end
        compat.observation={
            duration=3,firstCaptured=false,
            firstCamera=nil,firstSubject=nil,firstModel=nil,firstRoot=nil,
            elapsed=0,accumulated=0,secondsWithInput=0,samples=0,
            samplesWithInput=0,samplesWithMotion=0,
            motionAndInput=0,changedSubject=0,
            rootPath=0,cameraPath=0,humanoidMoveSamples=0,
            previousRoot=nil,previousCamera=nil,subject=nil,
            previousSubject=nil
        }
        compat.lastObservation=(automaticCheck and "Automatic character recheck" or "Manual recheck")
            ..": recording 3 seconds of movement input and camera-followed model."
        log("INFO",automaticCheck
            and "Automatic 3s movement check started. Stable input-matched camera model will calibrate without a click."
            or "Read-only 3s observation started. Walk with WASD; eligible model auto-calibrates.")
    end
    local function sampleObservation(dt)
        local c=compat.observation
        if not c then
            -- Resume evidence collection on an actual moving new Humanoid,
            -- but only auto-calibrate after stable input and camera/model checks.
            if SelfCalibration.readyForRearm() and observationKeyDown() then
                startObservation(SelfCalibration.initialCaptureArmed and "initial" or "redeploy")
            end
            return
        end
        if type(dt)~="number" or dt<=0 then return end
        c.elapsed+=math.min(dt,0.5)
        c.accumulated+=math.min(dt,0.5)
        if c.accumulated>=0.15 then
            local elapsed=c.accumulated
            c.accumulated=0
            c.samples+=1
            local camera=Workspace.CurrentCamera
            local subject=camera and camera.CameraSubject
            local model=subject and readable(function()
                return subject:IsA("Model") and subject or subject:FindFirstAncestorWhichIsA("Model")
            end,nil)
            local root=model and readable(function() return getRoot(model) end,nil) or nil
            local rootPosition=root and readable(function() return root.Position end,nil) or nil
            local cameraPosition=camera and readable(function() return camera.CFrame.Position end,nil) or nil
            if not c.firstCaptured then
                c.firstCaptured=true
                c.firstCamera=camera
                c.firstSubject=subject
                c.firstModel=model
                c.firstRoot=root
            elseif camera~=c.firstCamera or subject~=c.firstSubject
                or model~=c.firstModel or root~=c.firstRoot then
                c.changedSubject+=1
            end
            local inputDown=observationKeyDown()
            if inputDown then
                c.samplesWithInput+=1
                c.secondsWithInput+=elapsed
            end
            if subject and readable(function() return subject:IsA("Humanoid") end,false) then
                local hasMove=readable(function() return subject.MoveDirection.Magnitude>0.1 end,false)
                if hasMove then c.humanoidMoveSamples+=1 end
            end
            if c.previousSubject and subject~=c.previousSubject then
                c.changedSubject+=1
                c.previousRoot=nil
                c.previousCamera=nil
            end
            if c.previousRoot and rootPosition then
                local dist=(rootPosition-c.previousRoot).Magnitude
                local camDist=c.previousCamera and cameraPosition
                    and (cameraPosition-c.previousCamera).Magnitude or 0
                c.rootPath+=dist
                c.cameraPath+=camDist
                if dist>0.05 then
                    c.samplesWithMotion+=1
                    if inputDown then c.motionAndInput+=1 end
                end
            end
            c.previousRoot=rootPosition
            c.previousCamera=cameraPosition
            c.previousSubject=subject
        end
        if c.elapsed>=c.duration then
            compat.observation=nil
            local status
            if c.changedSubject>0 then
                status="INCONCLUSIVE: CameraSubject changed during observation (respawn or spectating possible)"
            elseif c.samplesWithInput<2 then
                status="INCONCLUSIVE: little/no WASD input recorded (menu may have remained open)"
            elseif c.samplesWithMotion<2 then
                status="INCONCLUSIVE: subject root did not visibly move during sampling"
            elseif c.motionAndInput>=2 then
                status="CORRELATED: camera subject movement coincides with local WASD input (ownership still UNVERIFIED)"
            else
                status="UNCONFIRMED: subject motion and local WASD input did not sufficiently overlap"
            end
            compat.lastObservation=string.format(
                "%d s observation: %s\n%d samples; WASD held ~%.1f s; moving samples %d; movement+WASD samples %d; Humanoid MoveDirection samples %d; subject changes %d\nTotal root travel: %.1f studs; camera travel: %.1f studs. Spectating cannot be excluded.",
                c.duration,status,c.samples,c.secondsWithInput,c.samplesWithMotion,c.motionAndInput,
                c.humanoidMoveSamples,c.changedSubject,c.rootPath,c.cameraPath)
            print("[SPECTRA COMPAT MOTION] "..compat.lastObservation:gsub("\n"," | "))
            if SelfCalibration.offer(c) then
                if not SelfCalibration.confirm() then
                    SelfCalibration.retry("camera/model changed before activation")
                end
            else
                SelfCalibration.retry("insufficient stable, matching input and model movement")
            end
            log("INFO","Movement observation completed: "..SelfCalibration.statusText())
        end
    end

    local function snapshot()
        local rows={}
        local function line(text)
            rows[#rows+1]=text
        end
        line("SPECTRA COMPATIBILITY / v"..VERSION.." / "..os.date("%Y-%m-%d %H:%M:%S"))
        line("Inspector: READ-ONLY Roblox-exposed data. Eligible movement-matched camera models can AUTO-CALIBRATE for LOCAL modifier attempts; ownership/server effects UNVERIFIED.")
        line("Game PlaceId: "..tostring(readable(function() return game.PlaceId end,"unknown")))
        line("Player instances: "..tostring(readable(function() return #Players:GetPlayers() end,0)))
        line("")
        line("[LOCAL CHARACTER]")
        local direct=readable(function() return LocalPlayer.Character end,nil)
        line("Player.Character assigned: "..bool(direct~=nil))
        local camera=readable(function() return Workspace.CurrentCamera end,nil)
        local subject=camera and readable(function() return camera.CameraSubject end,nil) or nil
        local subjectType=subject and readable(function() return subject.ClassName end,"unknown") or "nil"
        line("CameraSubject class: "..subjectType)
        local subjectModel=nil
        local subjectOwner=nil
        if subject then
            line("CameraSubject name: "..tostring(readable(function() return subject.Name end,"unknown")))
            local fullPath=readable(function() return subject:GetFullName() end,"unavailable")
            line("CameraSubject path: "..tostring(fullPath):sub(1,180))
            -- Walk only the publicly replicated instance ancestry. A camera
            -- subject is NOT proof that its model belongs to LocalPlayer:
            -- spectator cameras may target another character.
            local node=subject
            local ancestry={}
            for i=1,6 do
                node=readable(function() return node.Parent end,nil)
                if not node then break end
                local nodeClass=readable(function() return node.ClassName end,"unknown")
                local nodeName=readable(function() return node.Name end,"unknown")
                ancestry[#ancestry+1]=nodeClass.."/"..tostring(nodeName):sub(1,45)
                if not subjectModel and readable(function() return node:IsA("Model") end,false) then
                    subjectModel=node
                end
            end
            line("CameraSubject ancestors: "..(#ancestry>0 and table.concat(ancestry," > ") or "none"))
            if subjectModel then
                subjectOwner=readable(function() return identifyPlayer(subjectModel) end,nil)
                local ownership="UNVERIFIED (camera subject alone is insufficient)"
                if subjectOwner==LocalPlayer then ownership="VERIFIED LOCAL PLAYER"
                elseif subjectOwner then ownership="another identified player" end
                line("CameraSubject model: "..tostring(subjectModel.Name):sub(1,60))
                line("CameraSubject model ownership: "..ownership)
                local nativeOwner=readable(function()
                    return Players:GetPlayerFromCharacter(subjectModel)
                end,nil)
                line("Roblox GetPlayerFromCharacter: "..(nativeOwner
                    and (nativeOwner==LocalPlayer and "LOCAL PLAYER" or "OTHER PLAYER")
                    or "nil / unsupported"))
                local subjectRoot=readable(function() return getRoot(subjectModel) end,nil)
                line("CameraSubject model root: "..(subjectRoot and subjectRoot.Name or "none"))
                if subjectRoot then
                    line("CameraSubject root anchored: "..bool(readable(function() return subjectRoot.Anchored end,false)))
                    local rootPosition=readable(function() return subjectRoot.Position end,nil)
                    local cameraPosition=camera and readable(function() return camera.CFrame.Position end,nil) or nil
                    if rootPosition and cameraPosition then
                        line(string.format("Camera-to-subject root distance: %.1f studs (not ownership proof)",
                            (cameraPosition-rootPosition).Magnitude))
                    end
                    local now=os.clock()
                    if compat.previousSubject==subject and compat.previousRoot==subjectRoot
                        and compat.previousPosition and compat.previousClock then
                        local elapsed=math.max(0,now-compat.previousClock)
                        local current=rootPosition
                        if current then
                            line(string.format("Same camera subject across snapshots: YES; %.1f s elapsed; root moved %.1f studs",
                                elapsed,(current-compat.previousPosition).Magnitude))
                            if compat.previousCameraPosition and cameraPosition then
                                line(string.format("Camera moved %.1f studs over same interval (correlation only)",
                                    (cameraPosition-compat.previousCameraPosition).Magnitude))
                            end
                        end
                    else
                        line("Same camera subject across snapshots: no prior matching sample")
                    end
                    compat.previousSubject=subject
                    compat.previousRoot=subjectRoot
                    compat.previousPosition=rootPosition
                    compat.previousCameraPosition=cameraPosition
                    compat.previousClock=now
                end
                local subjectChildren=readable(function() return subjectModel:GetChildren() end,{})
                local parts,humanoids,other=0,0,0
                for i=1,math.min(#subjectChildren,120) do
                    local child=subjectChildren[i]
                    if child:IsA("BasePart") then parts+=1
                    elseif child:IsA("Humanoid") then humanoids+=1
                    else other+=1 end
                end
                line(string.format("CameraSubject model immediate children (max 120): parts=%d humanoids=%d other=%d",parts,humanoids,other))
                if subject:IsA("Humanoid") then
                    line("CameraSubject Humanoid.MoveDirection magnitude: "..tostring(readable(function()
                        return string.format("%.2f",subject.MoveDirection.Magnitude)
                    end,"unavailable")))
                    line("CameraSubject Humanoid.WalkSpeed: "..tostring(readable(function()
                        return subject.WalkSpeed
                    end,"unavailable")))
                end
            else
                line("CameraSubject model: no Model ancestor exposed")
            end
        end
        local candidate=nil
        local candidateSource="none"
        if direct and direct:IsA("Model") then
            candidate=direct
            candidateSource="LocalPlayer.Character"
        end
        if not candidate and subjectModel and subjectOwner==LocalPlayer then
            candidate=subjectModel
            candidateSource="verified CameraSubject ancestor"
        end
        if not candidate and subjectModel and SelfCalibration.isCurrent(subjectModel) then
            candidate=subjectModel
            candidateSource="automatic movement-match; ownership UNVERIFIED"
        end

        -- Bounded read of replicated models, avoiding scanning the entire
        -- Workspace or assuming a nearby anonymous rig is the local player.
        local nodeCount,modelCount,ownedCount,anonymousCount=0,0,0,0
        local folder=Workspace:FindFirstChild("Players")
        line("Workspace.Players folder: "..bool(folder~=nil))
        if folder then
            local queue={{folder,0}}
            local at=1
            while at<=#queue and nodeCount<400 do
                local item=queue[at]
                at+=1
                for _,child in ipairs(item[1]:GetChildren()) do
                    nodeCount+=1
                    if nodeCount>400 then break end
                    if child:IsA("Model") then
                        modelCount+=1
                        local owner=readable(function() return identifyPlayer(child) end,nil)
                        if owner==LocalPlayer then
                            ownedCount+=1
                            if not candidate then
                                candidate=child
                                candidateSource="verified Workspace.Players model"
                            end
                        elseif not owner then
                            anonymousCount+=1
                        end
                        if item[2]<2 then queue[#queue+1]={child,item[2]+1} end
                    elseif child:IsA("Folder") and item[2]<3 then
                        queue[#queue+1]={child,item[2]+1}
                    end
                end
            end
        end
        line(string.format("Replicated model search (Workspace.Players only): %d visited / %d models / %d owned / %d anonymous",
            nodeCount,modelCount,ownedCount,anonymousCount))
        line("ESP alternate public-Workspace scan: "..fallbackSummary)
        if modelCount==0 and #fallbackModels==0 then
            line("ESP position data: no candidate character Models found in supported public paths")
        end
        if not candidate then
            local localNamed=Workspace:FindFirstChild(LocalPlayer.Name)
            if localNamed and localNamed:IsA("Model")
                and readable(function() return identifyPlayer(localNamed)==LocalPlayer end,false) then
                candidate=localNamed
                candidateSource="verified Workspace name model"
            end
        end
        if candidate and not readable(function() return candidate.Parent~=nil end,false) then candidate=nil end
        local root=candidate and readable(function() return getRoot(candidate) end,nil) or nil
        local hum=candidate and readable(function() return candidate:FindFirstChildWhichIsA("Humanoid",true) end,nil) or nil
        line("Self-model source: "..candidateSource)
        line("Self-model class: "..(candidate and candidate.ClassName or "none"))
        line("Root: "..(root and root.Name or "none"))
        line("Humanoid: "..bool(hum~=nil))
        if root then
            line("Root anchored: "..bool(readable(function() return root.Anchored end,false)))
            line("Root collision enabled: "..bool(readable(function() return root.CanCollide end,false)))
            local vel=readable(function() return root.AssemblyLinearVelocity end,nil)
            if vel then
                line(string.format("Root velocity: %.1f horizontal / %.1f vertical studs/s",
                    Vector3.new(vel.X,0,vel.Z).Magnitude,vel.Y))
            end
        end
        if hum then
            line("Humanoid WalkSpeed: "..tostring(readable(function() return hum.WalkSpeed end,"unknown")))
            line("Humanoid JumpPower: "..tostring(readable(function() return hum.JumpPower end,"unknown")))
            line("Humanoid FloorMaterial: "..readEnum(readable(function() return hum.FloorMaterial end,nil)))
        end
        local isCalibrated=candidate and SelfCalibration.isCurrent(candidate)
        local status=isCalibrated
            and "AUTO-CALIBRATED: camera-followed rig exposed; true ownership and server effects UNVERIFIED"
            or category(candidate,root,hum)
        line("Movement API: "..status)
        line("Session camera-model calibration: "..SelfCalibration.statusText())
        line("")
        line("[OPT-IN MOVEMENT OBSERVATION]")
        line(compat.lastObservation)
        line("An input/motion correlation does not establish identity or server-controlled abilities.")
        line("")
        line("[CAMERA & INPUT]")
        line("CurrentCamera exists: "..bool(camera~=nil))
        if camera then
            line("CameraType: "..readEnum(readable(function() return camera.CameraType end,nil)))
            local size=readable(function() return camera.ViewportSize end,nil)
            if size then line(string.format("Viewport: %.0f x %.0f",size.X,size.Y)) end
            line("Camera CFrame readable: "..bool(readable(function() return camera.CFrame end,nil)~=nil))
        end
        line("MouseBehavior: "..readEnum(readable(function() return UserInputService.MouseBehavior end,nil)))
        line("Text input focused: "..bool(readable(function() return UserInputService:GetFocusedTextBox()~=nil end,false)))
        line("Left-click polling API: "..bool(readable(function()
            return type(UserInputService.IsMouseButtonPressed)=="function"
        end,false)))
        line("JumpRequest event: "..bool(readable(function() return UserInputService.JumpRequest~=nil end,false)))
        line("")
        line("[FEATURE CAPABILITY / EVIDENCE ONLY]")
        if not root or not candidate then
            line("Speed / Jump / Anti Aim: UNAVAILABLE; no verified writable self-rig")
        elseif root.Anchored then
            line("Speed / Jump / Anti Aim: RESTRICTED; root anchored")
        else
            line("Movement modifiers: local BasePart exists; server-accepted effect NOT VERIFIED")
            line("Humanoid movement controls: "..(hum and "exposed" or "NOT EXPOSED"))
        end
        line("No Fall Damage: server authority not available from public client API")
        line("Aimbot: visible target data does not establish camera or weapon aim control")
        line("Anti Aim: client visual rotation does not establish server hitbox behavior")
        line("")
        line("NOTE: These observations cannot establish effective cheats or access to private game state.")
        compat.text=table.concat(rows,"\n")
        compat.lastTime=os.date("%H:%M:%S")
        compat.status=status
        if compat.view and compat.view.Parent then compat.view.Text=compat.text end
        return compat.text
    end
    local function emit()
        local report=snapshot()
        print("[SPECTRA COMPAT] BEGIN")
        for entry in report:gmatch("[^\n]+") do
            print("[SPECTRA COMPAT] "..entry)
        end
        print("[SPECTRA COMPAT] END")
        return report
    end
    local function copy()
        local report=snapshot()
        if type(setclipboard)=="function" then
            local ok=pcall(setclipboard,report)
            if ok then
                log("INFO","Read-only compatibility report copied")
                return
            end
        end
        emit()
        log("WARN","Clipboard unavailable; compatibility report printed to Roblox console")
    end
    compat.snapshot=snapshot
    compat.startObservation=startObservation
    compat.sampleObservation=sampleObservation
    compat.emit=emit
    compat.copy=copy
    return compat
end)()

-- CAMERA & INPUT DIAGNOSTICS ----------------------------------------------
-- Read-only observations. These measurements cannot tell us what direction
-- Phantom Forces uses for server-validated shots or prove source-code behavior.
local inputDiag = {
    seconds=0, mouseEvents=0, mousePixels=0, rotationDegrees=0,
    lastMouseEvents=0, lastMousePixels=0, lastRotationDegrees=0,
    lastWindowSeconds=0, totalMouseEvents=0, totalMousePixels=0,
    totalCameraDegrees=0, windowCount=0, camera=nil, lastLook=nil
}
local inputDiagLiveText = nil

local function resetInputDiagnostics()
    inputDiag.seconds=0
    inputDiag.mouseEvents=0
    inputDiag.mousePixels=0
    inputDiag.rotationDegrees=0
    inputDiag.lastMouseEvents=0
    inputDiag.lastMousePixels=0
    inputDiag.lastRotationDegrees=0
    inputDiag.lastWindowSeconds=0
    inputDiag.totalMouseEvents=0
    inputDiag.totalMousePixels=0
    inputDiag.totalCameraDegrees=0
    inputDiag.windowCount=0
    inputDiag.camera=nil
    inputDiag.lastLook=nil
end

local function updateInputDiagnostics(dt)
    local camera=Workspace.CurrentCamera
    if camera~=inputDiag.camera then
        inputDiag.lastLook=nil
        inputDiag.camera=camera
    end
    if camera then
        local currentLook=camera.CFrame.LookVector
        if inputDiag.lastLook then
            local degrees=angleBetween(inputDiag.lastLook,currentLook)
            if degrees==degrees and degrees<180 then
                inputDiag.rotationDegrees+=degrees
                inputDiag.totalCameraDegrees+=degrees
            end
        end
        inputDiag.lastLook=currentLook
    end
    inputDiag.seconds+=dt
    if inputDiag.seconds>=1 then
        inputDiag.lastWindowSeconds=inputDiag.seconds
        inputDiag.lastMouseEvents=inputDiag.mouseEvents
        inputDiag.lastMousePixels=inputDiag.mousePixels
        inputDiag.lastRotationDegrees=inputDiag.rotationDegrees
        inputDiag.windowCount+=1
        inputDiag.seconds=0
        inputDiag.mouseEvents=0
        inputDiag.mousePixels=0
        inputDiag.rotationDegrees=0
    end
end

local function getAimGateDiagnostics()
    return string.format("Aim gates: tracking=%d | activation=%d | no target=%d | menu=%d | focused=%d | errors=%d",
        aimGateCounts.tracking,aimGateCounts.activation,aimGateCounts.noTarget,
        aimGateCounts.menu,aimGateCounts.textFocus,aimGateCounts.renderErrors)
end

local function getInputDiagnosticsLines()
    local camera=Workspace.CurrentCamera
    local cameraType=camera and camera.CameraType.Name or "(none)"
    local mouseBehavior=UserInputService.MouseBehavior.Name
    local rmb="unknown"
    local ok,pressed=pcall(function()
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end)
    if ok then rmb=tostring(pressed) end
    local window=math.max(0.01,inputDiag.lastWindowSeconds)
    local ms=inputDiag.windowCount>0 and "last second" or "collecting"
    local lines={
        "-- CAMERA & INPUT DIAGNOSTICS (read-only) --",
        "CameraType: "..cameraType.." | MouseBehavior: "..mouseBehavior.." | RMB: "..rmb,
        string.format("Mouse (%s): %d events | %.1f px/s",
            ms,inputDiag.lastMouseEvents,inputDiag.lastMousePixels/window),
        string.format("Camera (%s): %.2f deg/s | total: %.1f deg",
            ms,inputDiag.lastRotationDegrees/window,inputDiag.totalCameraDegrees),
        "Aimbot: "..(state.aimEnabled and "enabled" or "disabled")
            .." | backend: "..aimBackend.." | status: "..aimStatus,
        "Last GAMEPLAY status: "..aimLastGameplayStatus.." ("..aimLastGameplayTime..")",
        "Aim Key: "..state.aimKey
            .." | last activation detected: "..tostring(aimLastActivationDetected),
        getAimGateDiagnostics(),
        string.format("Target checks: %d enemies | %d projected on screen | %d in FOV | %d eligible | %d blocked (LOS requirement %s)",
            aimTargetProbe.enemies,aimTargetProbe.onScreen,
            aimTargetProbe.insideFov,aimTargetProbe.eligible,
            aimTargetProbe.blocked,state.aimVisibleOnly and "ON" or "OFF"),
        string.format("Aim writes: %d | move samples: %d | override samples: %d",
            aimUpdates,aimMovementSamples,aimOverrideSamples),
        string.format("Aim chosen backend: %s | mouse API: %s | relative mouse writes: %d | failures: %d | last delta: (%d,%d)",
            aimMetrics.lastMethod,aimMouseMove and "available" or "unavailable",
            aimMetrics.mouseWrites,aimMetrics.mouseErrors,
            aimMetrics.lastMouseDX,aimMetrics.lastMouseDY),
        string.format("Aim style: %s | visible-only: %s | snap strength: %d%% | FOV gate: %d px",
            state.aimStyle,tostring(state.aimVisibleOnly),
            state.aimSnapStrength,state.aimFovRadius),
        string.format("Snap frames: %d | camera snap writes: %d | last screen error: %.1f px",
            aimMetrics.snapFrames,aimMetrics.cameraSnapWrites,
            aimMetrics.screenErrorPx),
        "Target switches: "..aimMetrics.targetSwitches
            .." | sticky targeting: "..tostring(state.aimSticky),
        string.format("Last camera write: %.2f deg | last reset: %.2f deg",
            aimLastMoveDegrees,aimLastResetDegrees),
        string.format("Camera stabilization: %s | corrections: %d | conflicts: %d | errors: %d",
            aimCorrectionActive and "active" or "inactive",
            aimCorrectionCount,aimCorrectionObservations,aimCorrectionErrors),
        Movement.report(),
        "Mouse reports and camera writes do not prove weapon-aim control."
    }
    return lines
end

local function getInputDiagnosticsReport()
    return table.concat(getInputDiagnosticsLines(),"\n")
end

local function copyInputDiagnostics()
    local data=getInputDiagnosticsReport()
    if type(setclipboard)=="function" then
        local ok=pcall(setclipboard,data)
        if ok then
            log("INFO","Camera & Input Diagnostics copied to clipboard")
            return
        end
    end
    print(data)
    log("WARN","Clipboard unavailable; input diagnostics printed to console")
end

-- Bounded source audit, run only when a report is requested.
-- Does not track or render objects: it exposes why candidate models are excluded.
local function inspectDataSources()
    local lines = {"-- REPLICATION / TEAM PROBE --",
        "ESP fallback: "..fallbackSummary}
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
        lines[#lines+1] = "Player "..p.Name.." | relation="..relation
            .." | Team="..teamLabel(p.Team)
            .." | Character="..tostring(p.Character and p.Character.Parent~=nil or false)
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
                            local relation=classifyTarget(child,owner)
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
        "Additional model scan: "..fallbackSummary,
        "Visible targets: "..tostring(stats.rendered),
        "Identity status: "..(#targets>0 and "opposing-team models available" or "NO ENEMY MODELS: identities/team data missing or unavailable"),
        "FPS: "..string.format("%.0f",stats.fps).." / render target: 50 Hz (limited by FPS)",
        "Connections tracked: "..tostring(#connections),
        "Scans: "..tostring(stats.scans),
        "Options: skeleton="..tostring(state.skeleton)
            .." highlights="..tostring(state.highlights)
            .." strictlyEnemyOnly=true",
        "Enemy-only tracking: "..tostring(stats.teammates).." allies excluded; unknown teams: "..tostring(stats.unknownTeams),
        "Group-matched enemy rigs: "..tostring(stats.enemyGroups).." (only when Roblox Team names match)",
        "Calibration: "..calibrationMessage,
        "Calibration mode: "..calibrationMode,
        "Group events observed: "..tostring(groupEvents),
        "Fixed limits: 1000 studs / 50 Hz target",
        "Aimbot: "..tostring(state.aimEnabled).." | "..aimStatus,
        "Aim method: "..state.aimMethod.." | backend: "..aimBackend,
        "Aim FOV: "..state.aimFovRadius.." px | style: "..state.aimStyle
            .." | smoothing: "..state.aimSmoothing.." | pull: "..state.aimPullStrength.."% | point: "..state.aimPoint,
        "Aim activation: "..state.aimKey,
        "Persistent target lock: "..tostring(state.aimLock)
            .." | acquisitions: "..aimLockAcquisitions
            .." | held frames: "..aimLockRetainedFrames
            .." | releases: "..aimLockReleases,
        "Aim requires line of sight: "..tostring(state.aimVisibleOnly)
            .." | eligible candidates: "..aimSelectionCount,
        "Aim last gameplay gate: "..aimLastGameplayStatus.." ("..aimLastGameplayTime..")",
        "Aim Key setting: "..state.aimKey.." | "..getAimGateDiagnostics(),
        "Aim updates: "..aimUpdates.." | errors: "..aimErrors,
        "Relative mouse writes: "..aimMetrics.mouseWrites
            .." | mouse API failures: "..aimMetrics.mouseErrors
            .." | target switches: "..aimMetrics.targetSwitches
            .." | snap frames: "..aimMetrics.snapFrames,
        Movement.report(),
        "Aim last active: "..aimLastActiveStatus,
        "Aim camera writes with movement: "..aimCameraMoved.."/"..aimMovementSamples
            .." | suspected overrides: "..aimCameraResetEvents,
        "Aim last reset delta: "..string.format("%.2f",aimLastResetDegrees)
            .." deg | override streak: "..aimOverrideStreak
            .." | override samples: "..aimOverrideSamples,
        "Camera stabilization: "..(aimCorrectionActive and "active" or "inactive")
            .." | corrective writes: "..aimCorrectionCount.." | observed conflicts: "..aimCorrectionObservations
            .." | errors: "..aimCorrectionErrors,
        "Skeleton rigs with joints: "..tostring(stats.skeletonRigs).."/"..tostring(stats.discovered),
        "Estimated 2D skeletons shown: "..tostring(stats.approxSkeletons).." (not actual bone poses)",
        "Low/wide fallback skeletons: "..tostring(stats.wideSkeletons).." (leg lines hidden)",
        "No getgc, hooks, remote scripts, or writes to other character models.",
        "-- RECENT LOGS --"
    }
    local inputLines=getInputDiagnosticsLines()
    for _,entry in ipairs(inputLines) do rows[#rows+1]=entry end
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
    if not alive then return true end
    -- Stop all frame work immediately, even if one cleanup step fails.
    alive=false
    local errors={}
    local function cleanup(label,callback)
        local ok,err=pcall(callback)
        if not ok then errors[#errors+1]=label..": "..tostring(err) end
    end
    cleanup("Unbind aim render step",function()
        RunService:UnbindFromRenderStep(AIM_RENDER_BIND)
    end)
    aimRmbHeld=false
    table.clear(aimKeyHeld)
    cleanup("Restore movement",Movement.restore)
    cleanup("Clear calibration",function() SelfCalibration.clear("SPECTRA unloaded") end)
    cleanup("Stop camera correction",disableAimCorrection)
    if aimObservedCameraConnection then
        cleanup("Disconnect camera observer",function()
            aimObservedCameraConnection:Disconnect()
        end)
        aimObservedCameraConnection=nil
    end
    aimObservedCamera=nil
    cleanup("Close picker",function() stopPicker(false) end)
    for key,w in pairs(widgets) do
        cleanup("Destroy ESP marker",function()
            if w.highlight then w.highlight:Destroy() end
            if w.root then w.root:Destroy() end
        end)
        widgets[key]=nil
    end
    for _,conn in ipairs(connections) do
        cleanup("Disconnect event",function() conn:Disconnect() end)
    end
    for _,conn in ipairs(watcherConnections) do
        cleanup("Disconnect folder watcher",function() conn:Disconnect() end)
    end
    table.clear(watcherConnections)
    table.clear(connections)
    calibratedEnemyGroup=nil
    calibrationMode="none"
    if overlayGui then
        cleanup("Destroy overlay",function() overlayGui:Destroy() end)
        overlayGui=nil
    end
    if menuGui then
        cleanup("Destroy menu",function() menuGui:Destroy() end)
        menuGui=nil
    end
    targets={}
    if ENV.SPECTRA_PHASE1_UNLOAD==shutdown then ENV.SPECTRA_PHASE1_UNLOAD=nil end
    if _G.SPECTRA_PHASE1_UNLOAD==shutdown then _G.SPECTRA_PHASE1_UNLOAD=nil end
    if #errors>0 then
        for _,err in ipairs(errors) do warn("[SPECTRA] Cleanup: "..err) end
        return false,table.concat(errors,"; ")
    end
    print("[SPECTRA] Unloaded cleanly; connections released.")
    return true
end
ENV.SPECTRA_PHASE1_UNLOAD = shutdown
_G.SPECTRA_PHASE1_UNLOAD = shutdown

-- UI startup is a separate function scope to avoid exhausting the
-- main script's Luau local-variable slots. UI setup still executes now.
local function launchSpectraUI()
    -- UI foundation --------------------------------------------------------------
    overlayGui=create("ScreenGui",{Name="SPECTRA_Phase1_Overlay",IgnoreGuiInset=true,ResetOnSpawn=false,DisplayOrder=160,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
    menuGui=create("ScreenGui",{Name="SPECTRA_Phase1_UI",IgnoreGuiInset=true,ResetOnSpawn=false,DisplayOrder=161,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
    if not safeParent(overlayGui) or not safeParent(menuGui) then
        warn("[SPECTRA] Could not parent GUI to an accessible UI container")
        shutdown()
        return
    end
    overlayLayer=create("Frame",{Name="WorldMarkers",BackgroundTransparency=1,Size=UDim2.fromScale(1,1),Position=UDim2.fromScale(0,0),ClipsDescendants=true},overlayGui)
    aimFovFrame=create("Frame",{
        Name="AimFOV",BackgroundTransparency=1,Visible=false,
        BorderSizePixel=0,Size=UDim2.fromOffset(300,300),ZIndex=5
    },overlayLayer)
    create("UICorner",{CornerRadius=UDim.new(1,0)},aimFovFrame)
    create("UIStroke",{Color=C.accent,Transparency=0.25,Thickness=1},aimFovFrame)
    window=create("Frame",{
        Name="MainWindow",Size=UDim2.fromOffset(660,445),Position=UDim2.new(0.5,-330,0.5,-223),
        BackgroundColor3=C.base,BorderSizePixel=0,ClipsDescendants=true
    },menuGui)
    round(window,9); outline(window)
    menu=window
    local top=create("Frame",{Size=UDim2.new(1,0,0,53),BackgroundColor3=C.base,BorderSizePixel=0},window)
    local title=textLabel(top,"SPECTRA",16,C.white,true)
    title.Position=UDim2.fromOffset(21,11); title.Size=UDim2.fromOffset(130,22)
    local sub=textLabel(top,"PLAYER VISUALS  /  1.26.1",10,C.muted)
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
    for index,name in ipairs({"Aimbot","ESP","Modifiers","Compat","Settings","Debug"}) do
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

    local function settingSlider(page,name,description,key,minimum,maximum,step,unit)
        local f=create("Frame",{Size=UDim2.new(1,-3,0,77),BackgroundColor3=C.panel,BorderSizePixel=0},page)
        round(f,6)
        local caption=textLabel(f,name,12,C.white,true)
        caption.Position=UDim2.fromOffset(13,6)
        caption.Size=UDim2.new(1,-115,0,19)
        local hint=textLabel(f,description,10,C.muted)
        hint.Position=UDim2.fromOffset(13,26)
        hint.Size=UDim2.new(1,-26,0,15)
        local valueText=textLabel(f,"",11,C.accent,true)
        valueText.Position=UDim2.new(1,-99,0,7)
        valueText.Size=UDim2.fromOffset(85,18)
        valueText.TextXAlignment=Enum.TextXAlignment.Right
        local rail=create("Frame",{
            Position=UDim2.new(0,14,1,-20),Size=UDim2.new(1,-28,0,5),
            BackgroundColor3=C.border,BorderSizePixel=0
        },f)
        round(rail,3)
        local fill=create("Frame",{Size=UDim2.fromScale(0,1),BackgroundColor3=C.accent,BorderSizePixel=0},rail)
        round(fill,3)
        local hitbox=create("TextButton",{
            Text="",BackgroundTransparency=1,Position=UDim2.new(0,8,1,-30),
            Size=UDim2.new(1,-16,0,27),BorderSizePixel=0
        },f)
        local active=false
        local function refresh()
            local value=state[key]
            local percent=math.clamp((value-minimum)/(maximum-minimum),0,1)
            fill.Size=UDim2.fromScale(percent,1)
            valueText.Text=tostring(value)..(unit or "")
        end
        local function adjust(x)
            local left=rail.AbsolutePosition.X
            local width=math.max(1,rail.AbsoluteSize.X)
            local fraction=math.clamp((x-left)/width,0,1)
            local value=minimum+math.floor((maximum-minimum)*fraction/step+0.5)*step
            state[key]=math.clamp(value,minimum,maximum)
            refresh()
        end
        connect(hitbox.InputBegan,function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then
                active=true
                adjust(input.Position.X)
            end
        end)
        connect(UserInputService.InputChanged,function(input)
            if active and input.UserInputType==Enum.UserInputType.MouseMovement then
                adjust(input.Position.X)
            end
        end)
        connect(UserInputService.InputEnded,function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then active=false end
        end)
        -- Refresh the slider fill and label when changed from console.
        toggleRefreshers[#toggleRefreshers+1]=refresh
        refresh()
    end

    local aimPage=pages.Aimbot
    header(aimPage,"Aimbot","Snap toward projected enemy targets inside the FOV circle")
    groupLabel(aimPage,"TARGETING")
    toggle(aimPage,"Enable aimbot","Off by default; changes client aim when activated","aimEnabled")
    -- A real input binder instead of cycling through a short fixed key list.
    -- MouseButton1 is deliberately not bindable because it confirms UI clicks.
    local aimKeyCapture=false
    local aimKeyButton
    local function applyAimKey(key)
        aimKeyCapture=false
        state.aimKey=key
        aimRmbHeld=false
        table.clear(aimKeyHeld)
        aimKeyButton.Text="Aim Key: "..key.." (click to rebind)"
        log("INFO","Aimbot activation key: "..key)
    end
    aimKeyButton=action(aimPage,"Aim Key: Always (click to rebind)",function()
        aimKeyCapture=true
        aimKeyButton.Text="Press keyboard key or RMB (Esc cancels)"
    end)
    toggleRefreshers[#toggleRefreshers+1]=function()
        if not aimKeyCapture then
            aimKeyButton.Text="Aim Key: "..state.aimKey.." (click to rebind)"
        end
    end
    action(aimPage,"Aim Key: Always active",function()
        applyAimKey("Always")
    end)
    connect(UserInputService.InputBegan,function(input)
        if not aimKeyCapture then return end
        if input.KeyCode==Enum.KeyCode.Escape then
            aimKeyCapture=false
            aimKeyButton.Text="Aim Key: "..state.aimKey.." (click to rebind)"
            return
        end
        if input.UserInputType==Enum.UserInputType.MouseButton2 then
            applyAimKey("Right Mouse")
            return
        end
        if input.UserInputType~=Enum.UserInputType.Keyboard
            or input.KeyCode==Enum.KeyCode.Unknown then return end
        -- Avoid capturing keys reserved for SPECTRA controls or unloading.
        local keyCode=input.KeyCode
        if keyCode==Enum.KeyCode.RightShift or keyCode==Enum.KeyCode.F8
            or keyCode==Enum.KeyCode.Home or keyCode==Enum.KeyCode.End then
            log("WARN","This key is reserved by SPECTRA; choose another")
            return
        end
        local key=keyCode==Enum.KeyCode.LeftAlt and "Left Alt" or keyCode.Name
        applyAimKey(key)
    end)
    toggle(aimPage,"Visibility Check","Require clear line of sight (off = track behind cover)","aimVisibleOnly")
    toggle(aimPage,"Persistent target lock","Keep the acquired character locked even outside FOV and pull aim back after mouse movement","aimLock")
    toggle(aimPage,"Sticky targets","Prefer the previous enemy when persistent lock is off","aimSticky")
    local aimPointButton
    aimPointButton=action(aimPage,"Target Bone: Head",function()
        local order={"Head","Chest","Nearest"}
        local nextIndex=1
        for i,value in ipairs(order) do
            if state.aimPoint==value then nextIndex=i%#order+1; break end
        end
        state.aimPoint=order[nextIndex]
        aimPointButton.Text="Target Bone: "..state.aimPoint
        log("INFO","Aimbot target bone: "..state.aimPoint)
    end)
    toggleRefreshers[#toggleRefreshers+1]=function()
        aimPointButton.Text="Target Bone: "..state.aimPoint
    end
    groupLabel(aimPage,"CONTROL")
    settingSlider(aimPage,"Aim FOV","Target selection radius around crosshair","aimFovRadius",40,400,10," px")
    local aimStyleButton
    aimStyleButton=action(aimPage,"Aim style: Snap",function()
        state.aimStyle=state.aimStyle=="Snap" and "Smooth" or "Snap"
        aimStyleButton.Text="Aim style: "..state.aimStyle
        log("INFO","Aimbot style: "..state.aimStyle)
    end)
    toggleRefreshers[#toggleRefreshers+1]=function()
        aimStyleButton.Text="Aim style: "..state.aimStyle
    end
    settingSlider(aimPage,"Snap strength","Fast mouse correction; tune to in-game sensitivity","aimSnapStrength",40,200,10,"%")
    settingSlider(aimPage,"Lock pull strength","Mouse-input correction toward a locked target (50% subtle, 250% aggressive)","aimPullStrength",50,250,10,"%")
    settingSlider(aimPage,"Smoothness","Only affects Smooth style (1 fast, 20 gradual)","aimSmoothing",1,20,1,"")
    toggle(aimPage,"Show FOV circle","Draw the target-selection boundary","aimFovVisible")
    local aimMethodButton
    aimMethodButton=action(aimPage,"Aim method: Auto",function()
        local modes={"Auto","Mouse","Camera","Stabilized"}
        local nextIndex=1
        for i,value in ipairs(modes) do
            if state.aimMethod==value then nextIndex=i%#modes+1; break end
        end
        state.aimMethod=modes[nextIndex]
        aimMethodButton.Text="Aim method: "..state.aimMethod
        log("INFO","Aimbot method: "..state.aimMethod)
    end)
    toggleRefreshers[#toggleRefreshers+1]=function()
        aimMethodButton.Text="Aim method: "..state.aimMethod
    end
    row(aimPage,"Lock behavior","First target must be inside FOV. A valid locked enemy stays selected outside FOV; it releases if lost, defeated or filtered.")
    row(aimPage,"Cover behavior","With Visibility Check off, a locked target can remain selected behind geometry. Bullets still obey game collisions.")
    row(aimPage,"Runtime compatibility","Auto prefers mouse movement for camera AND weapon; tune Lock pull strength if your gun lags or jitters. Stabilized only adjusts camera.")
    groupLabel(aimPage,"AIMBOT DIAGNOSTICS")
    action(aimPage,"Print Aimbot diagnostics to Roblox logs",function()
        local camera=Workspace.CurrentCamera
        print("[SPECTRA AIM] BEGIN")
        print("[SPECTRA AIM] SPECTRA v"..VERSION
            .." | PlaceId: "..tostring(game.PlaceId))
        print("[SPECTRA AIM] Camera: "..(camera and camera.CameraType.Name or "missing")
            .." | relative mouse API: "..(aimMouseMove and "available" or "unavailable")
            .." | selected method: "..state.aimMethod)
        print("[SPECTRA AIM] Discovery: "..lastSource
            .." | target models: "..#targets.." | "..lastScanDetails)
        print("[SPECTRA AIM] Team calibration: "..calibrationMode
            .." | "..calibrationMessage)
        print("[SPECTRA AIM] Aim Key: "..state.aimKey
            .." | Target Bone: "..state.aimPoint
            .." | Visibility Check: "..tostring(state.aimVisibleOnly)
            .." | Persistent Lock: "..tostring(state.aimLock)
            .." | Acquired: "..aimLockAcquisitions
            .." | Retained frames: "..aimLockRetainedFrames
            .." | Releases: "..aimLockReleases)
        for _,entry in ipairs(getInputDiagnosticsLines()) do
            if entry:find("Aimbot",1,true)
                or entry:find("Aim ",1,true)
                or entry:find("Aim:",1,true)
                or entry:find("Target checks",1,true)
                or entry:find("Last GAMEPLAY",1,true)
                or entry:find("CameraType:",1,true)
                or entry:find("Aim Key:",1,true)
                or entry:find("Target switches",1,true)
                or entry:find("Aim style:",1,true)
                or entry:find("Snap frames:",1,true)
                or entry:find("Camera stabilization",1,true) then
                print("[SPECTRA AIM] "..entry)
            end
        end
        print("[SPECTRA AIM] END")
        log("INFO","Aimbot report printed with [SPECTRA AIM] prefix")
    end)
    groupLabel(aimPage,"STATUS")
    local aimStatusText=textLabel(aimPage,"Disabled",11,C.muted)
    aimStatusText.Size=UDim2.new(1,-3,0,24)

    local modifiersPage=pages.Modifiers
    header(modifiersPage,"Modifiers","Local visual gameplay adjustments")
    groupLabel(modifiersPage,"GAME COMPATIBILITY")
    Movement.statusLabel=textLabel(modifiersPage,"Checking for an owned, controllable character...",11,C.orange)
    Movement.statusLabel.Size=UDim2.new(1,-3,0,64)
    Movement.statusLabel.TextWrapped=true
    action(modifiersPage,"Recheck character compatibility",function()
        log("INFO",Movement.probe())
        log("INFO",Movement.data.status)
    end)
    row(modifiersPage,"Availability","Auto-calibrates after ~3s walking; server results unverified")
    groupLabel(modifiersPage,"MOVEMENT")
    toggle(modifiersPage,"Speed Hack","Local speed changes; server can reset movement","speedHack")
    settingSlider(modifiersPage,"Speed","Limited to 50 studs/s to avoid observed choppiness","speedValue",16,50,2,"")
    toggle(modifiersPage,"Infinite Jump","Attempts jumping again while in the air","infiniteJump")
    toggle(modifiersPage,"No Fall Damage","Attempts to slow descent before landing","noFallDamage")
    toggle(modifiersPage,"Anti Aim (local visual)","Jitters local model; does NOT alter server hitbox","antiAim")
    groupLabel(modifiersPage,"SERVER LIMITATIONS")
    row(modifiersPage,"Local only","The game can reject speed or damage changes")
    action(modifiersPage,"Copy movement status",function()
        local text=Movement.report()
        if type(setclipboard)=="function" then
            local ok=pcall(setclipboard,text)
            if ok then log("INFO","Movement report copied");return end
        end
        print(text)
        log("WARN","Clipboard unavailable; report printed to console")
    end)
    local espPage=pages.ESP
    header(espPage,"Player visuals","Configure your in-game overlay")
    groupLabel(espPage,"DISPLAY")
    toggle(espPage,"Enable ESP","Master switch for confirmed-enemy visual markers","enabled")
    toggle(espPage,"Distance","Camera distance in Roblox studs","distances")
    toggle(espPage,"Tracers","Lines from the screen bottom toward players","tracers")
    toggle(espPage,"Skeleton","Real joints if available; posture-aware estimate otherwise","skeleton")
    toggle(espPage,"3D highlight","Client-side character highlighting","highlights")
    action(espPage,"Rescan ESP characters",function()
        fallbackNextScan=0
        discoverTargets()
        log("INFO","ESP rescan: "..lastScanDetails)
        if #targets==0 then
            log("WARN","ESP found no eligible character models. Open Debug for team/model diagnostics.")
        end
    end)
    row(espPage,"Verified enemies only","Unidentified characters and teammates are always hidden. If no enemies appear, calibrate an opponent with F6.")

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

    -- A read-only snapshot of what Roblox actually exposes in this session.
    local compatPage=pages.Compat
    header(compatPage,"Compatibility inspector","Roblox-exposed interfaces only; no memory or private hooks")
    groupLabel(compatPage,"LIVE SESSION SNAPSHOT")
    action(compatPage,"Refresh and print to Roblox logs",function()
        Compat.emit()
        log("INFO","Compatibility snapshot printed with [SPECTRA COMPAT] prefix")
    end)
    action(compatPage,"Start 3s WASD + camera motion observation",Compat.startObservation)
    action(compatPage,"Clear session character calibration",function()
        Movement.restore()
        Movement.data.model=nil;Movement.data.root=nil;Movement.data.humanoid=nil
        SelfCalibration.clear("Cleared by user")
    end)
    action(compatPage,"Copy compatibility report",Compat.copy)
    row(compatPage,"Safety note","Auto-calibration is not ownership proof; spectating cannot be ruled out")
    row(compatPage,"Redeploy recovery","Walk ~3s after every spawn; no Confirm button needed")
    row(compatPage,"How to use","Auto-check starts when walking; clears on camera/model change")
    local compatReportView=create("TextBox",{
        Text=Compat.text,TextEditable=false,MultiLine=true,ClearTextOnFocus=false,
        Font=Enum.Font.Code,TextSize=10,TextWrapped=true,
        TextColor3=C.white,TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Top,
        BackgroundColor3=C.panel,BorderSizePixel=0,
        Size=UDim2.new(1,-3,0,850),
    },compatPage)
    round(compatReportView,6)
    Compat.view=compatReportView

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
    toggleRefreshers[#toggleRefreshers+1]=function()
        colorButton.Text="Marker color: "..state.color.."  (click to cycle)"
    end
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
    header(debugPage,"Command Center","Inspect, configure and troubleshoot SPECTRA · logs limited to 140 entries")
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
    groupLabel(debugPage,"CAMERA & INPUT DIAGNOSTICS")
    local inputDiagPanel=create("Frame",{
        Size=UDim2.new(1,-3,0,255),BackgroundColor3=C.panel,BorderSizePixel=0
    },debugPage)
    round(inputDiagPanel,6)
    inputDiagLiveText=create("TextLabel",{
        Position=UDim2.fromOffset(10,8),Size=UDim2.new(1,-20,1,-16),
        BackgroundTransparency=1,Text="Collecting read-only input and camera samples...",
        TextWrapped=true,TextYAlignment=Enum.TextYAlignment.Top,
        TextXAlignment=Enum.TextXAlignment.Left,TextSize=10,Font=Enum.Font.Code,
        TextColor3=C.white,BorderSizePixel=0
    },inputDiagPanel)
    local diagActions=create("Frame",{Size=UDim2.new(1,-3,0,32),BackgroundTransparency=1},debugPage)
    local function diagAction(title,x,callback)
        local b=create("TextButton",{
            Text=title,TextSize=11,Font=Enum.Font.GothamMedium,
            TextColor3=C.white,BackgroundColor3=C.panel2,BorderSizePixel=0,
            Position=UDim2.new(x,0,0,0),Size=UDim2.new(0.48,-2,1,0)
        },diagActions)
        round(b,5)
        connect(b.MouseButton1Click,function() safeCall(title,callback) end)
    end
    diagAction("Copy input diagnostics",0,copyInputDiagnostics)
    diagAction("Reset input counters",0.52,function()
        resetInputDiagnostics()
        log("INFO","Camera & input counters reset")
    end)
    groupLabel(debugPage,"EVENT LOG")
    local logPanel=create("Frame",{Size=UDim2.new(1,-3,0,210),BackgroundColor3=C.panel,BorderSizePixel=0},debugPage)
    round(logPanel,6)
    local logScroll=create("ScrollingFrame",{Position=UDim2.fromOffset(8,8),Size=UDim2.new(1,-16,1,-16),BackgroundTransparency=1,
        BorderSizePixel=0,ScrollBarThickness=3,CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y},logPanel)
    logBox=create("TextBox",{BackgroundTransparency=1,ClearTextOnFocus=false,MultiLine=true,TextEditable=false,
        Font=Enum.Font.Code,TextSize=11,TextColor3=C.white,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
        TextWrapped=true,Text="",Size=UDim2.new(1,-4,0,0),AutomaticSize=Enum.AutomaticSize.Y,BorderSizePixel=0},logScroll)
    local inputRow=create("Frame",{Size=UDim2.new(1,-3,0,32),BackgroundTransparency=1},debugPage)
    local cmd=create("TextBox",{PlaceholderText="Type help, settings, get, set, toggle, tab...",Text="",ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,Font=Enum.Font.Code,TextSize=11,TextColor3=C.white,
        PlaceholderColor3=C.muted,BackgroundColor3=C.panel,Size=UDim2.new(1,-76,1,0),BorderSizePixel=0},inputRow)
    round(cmd,5);create("UIPadding",{PaddingLeft=UDim.new(0,9)},cmd)
    local run=create("TextButton",{Text="Run",Font=Enum.Font.GothamMedium,TextSize=11,TextColor3=C.white,
        BackgroundColor3=C.panel2,Size=UDim2.fromOffset(68,32),Position=UDim2.new(1,-68,0,0),BorderSizePixel=0},inputRow)
    round(run,5)
    -- The console shares the exact state table used by every visible menu
    -- control. Values are validated; this is NOT a general Luau evaluator.
    local consoleController=(function()
        local controlSchema={
            -- ESP
            enabled={"bool","ESP enabled"},
            distances={"bool","ESP distance"},
            tracers={"bool","ESP tracers"},
            skeleton={"bool","ESP skeleton"},
            highlights={"bool","ESP highlight"},
            -- Aiming
            aimEnabled={"bool","Aimbot enabled"},
            aimFovVisible={"bool","FOV circle"},
            aimVisibleOnly={"bool","Visibility check"},
            aimSticky={"bool","Sticky targets"},
            aimLock={"bool","Persistent lock"},
            aimFovRadius={"num","Aim FOV",40,400,10},
            aimSmoothing={"num","Smoothness",1,20,1},
            aimSnapStrength={"num","Snap strength",40,200,10},
            aimPullStrength={"num","Lock pull strength",50,250,10},
            aimStyle={"enum","Aim style",{"Snap","Smooth"}},
            aimPoint={"enum","Target bone",{"Head","Chest","Nearest"}},
            aimMethod={"enum","Aim method",{"Auto","Mouse","Camera","Stabilized"}},
            aimKey={"key","Aim activation key"},
            -- Modifiers
            speedHack={"bool","Speed modifier"},
            speedValue={"num","Movement speed",16,50,2},
            infiniteJump={"bool","Infinite jump"},
            noFallDamage={"bool","No fall damage"},
            antiAim={"bool","Anti aim visual"},
            -- Appearance
            color={"enum","ESP marker color",{"Cyan","Coral","Lime","White"}}
        }
        local aliases={
            esp="enabled",aimbot="aimEnabled",fov="aimFovRadius",
            aimfov="aimFovRadius",aimkey="aimKey",bone="aimPoint",
            target="aimPoint",method="aimMethod",style="aimStyle",
            pull="aimPullStrength",snap="aimSnapStrength",
            smooth="aimSmoothing",visibility="aimVisibleOnly",
            sticky="aimSticky",lock="aimLock",distance="distances",
            highlight="highlights",speed="speedValue"
        }
        local defaults={}
        local keys={}
        for key in pairs(controlSchema) do
            keys[#keys+1]=key
            defaults[key]=state[key]
        end
        table.sort(keys)
        local function canonical(raw)
            local needle=tostring(raw or ""):lower():gsub("[^%w]","")
            for key in pairs(controlSchema) do
                if key:lower()==needle then return key end
            end
            return aliases[needle]
        end
        local function parseBool(text)
            if text=="on" or text=="true" or text=="1" or text=="yes" then return true end
            if text=="off" or text=="false" or text=="0" or text=="no" then return false end
            return nil
        end
        local function parseKey(text)
            local canonicalText=text:lower():gsub("%s+","")
            if canonicalText=="always" then return "Always" end
            if canonicalText=="rightmouse" or canonicalText=="rmb" then return "Right Mouse" end
            if canonicalText=="leftalt" then return "Left Alt" end
            for _,item in ipairs(Enum.KeyCode:GetEnumItems()) do
                if item.Name:lower()==canonicalText and item~=Enum.KeyCode.Unknown
                    and item~=Enum.KeyCode.RightShift
                    and item~=Enum.KeyCode.F8 and item~=Enum.KeyCode.Home
                    and item~=Enum.KeyCode.End and item~=Enum.KeyCode.Escape then
                    return item.Name
                end
            end
            return nil
        end
        local function setSetting(key,raw)
            local spec=controlSchema[key]
            if not spec then return false,"Unknown setting: "..tostring(key) end
            local value
            local input=tostring(raw or ""):gsub("^%s+",""):gsub("%s+$","")
            input=input:gsub('^"(.*)"$',"%1")
            if spec[1]=="bool" then
                value=parseBool(input:lower())
                if value==nil then return false,"Use on/off for "..key end
            elseif spec[1]=="num" then
                local n=tonumber(input)
                if not n or n~=n or n==math.huge or n==-math.huge then
                    return false,"Expected a number for "..key
                end
                -- Use the identical bounds and steps as the menu sliders.
                if n<spec[3] or n>spec[4] then
                    return false,string.format("%s must be between %d and %d",
                        key,spec[3],spec[4])
                end
                value=spec[3]+math.floor((n-spec[3])/spec[5]+0.5)*spec[5]
                value=math.clamp(value,spec[3],spec[4])
            elseif spec[1]=="enum" then
                for _,option in ipairs(spec[3]) do
                    if option:lower()==input:lower() then value=option;break end
                end
                if not value then
                    return false,"Allowed "..key..": "..table.concat(spec[3],", ")
                end
            elseif spec[1]=="key" then
                value=parseKey(input)
                if not value then
                    return false,"Invalid Aim Key (try Always, Right Mouse, LeftAlt or X)"
                end
            end
            if key=="aimKey" then
                applyAimKey(value)
            else
                state[key]=value
                if key=="enabled" then
                    if not value then
                        for _,w in pairs(widgets) do hideWidget(w) end
                    else
                        scanAccumulator=10
                        scanDirty=true
                    end
                end
                if key=="aimEnabled" and not value then
                    aimSelected=nil
                    disableAimCorrection()
                end
            end
            refreshAllToggles()
            return true,key.." = "..tostring(value)
        end
        local function listSettings()
            log("INFO","-- MENU SETTINGS (get KEY / set KEY VALUE / toggle KEY) --")
            for _,key in ipairs(keys) do
                local spec=controlSchema[key]
                local suffix=spec[1]=="num"
                    and string.format(" [%s..%s step %s]",spec[3],spec[4],spec[5])
                    or spec[1]=="enum" and (" ["..table.concat(spec[3],"/").."]")
                    or ""
                log("INFO",key.." = "..tostring(state[key])..suffix)
            end
        end
        local tabMap={aimbot="Aimbot",esp="ESP",modifiers="Modifiers",
            compat="Compat",settings="Settings",debug="Debug"}
        local function run(input,verb,tail)
            if verb=="settings" then
                listSettings()
                return true
            elseif verb=="get" then
                local key=canonical(tail)
                if not key then log("WARN","Unknown menu setting. Use settings.");return true end
                log("INFO",key.." = "..tostring(state[key]))
                return true
            elseif verb=="set" then
                local target,value=tail:match("^(%S+)%s+(.+)$")
                local key=canonical(target)
                if not key or not value then
                    log("WARN","Usage: set <setting> <value>  (settings lists all keys)")
                    return true
                end
                local ok,message=setSetting(key,value)
                log(ok and "INFO" or "WARN",message)
                return true
            elseif verb=="toggle" then
                local key=canonical(tail)
                if not key or controlSchema[key][1]~="bool" then
                    log("WARN","Usage: toggle <boolean setting> (see settings)")
                    return true
                end
                local ok,message=setSetting(key,tostring(not state[key]))
                log(ok and "INFO" or "WARN",message)
                return true
            elseif verb=="resetsettings" then
                for _,key in ipairs(keys) do
                    local default=defaults[key]
                    if key=="aimKey" then applyAimKey(default)
                    else state[key]=default end
                end
                aimSelected=nil
                disableAimCorrection()
                scanDirty=true
                scanAccumulator=10
                refreshAllToggles()
                log("INFO","All menu options restored to startup defaults")
                return true
            elseif verb=="tab" then
                local page=tabMap[tail:lower()]
                if not page then
                    log("WARN","Tabs: Aimbot, ESP, Modifiers, Compat, Settings, Debug")
                    return true
                end
                window.Visible=true
                selectTab(page)
                clampWindow(false)
                log("INFO","Opened "..page.." tab")
                return true
            end
            return false
        end
        return {run=run, listSettings=listSettings}
    end)()

    local commandHistory={}
    local commandHistoryCursor=0
    local function runCommand(raw)
        local input=(raw or ""):gsub("^%s+",""):gsub("%s+$","")
        if input=="" then return end
        if #input>220 then log("WARN","Command exceeds 220 characters");return end
        if commandHistory[#commandHistory]~=input then
            commandHistory[#commandHistory+1]=input
            if #commandHistory>40 then table.remove(commandHistory,1) end
        end
        commandHistoryCursor=#commandHistory+1
        log("INFO","> "..input)
        local verb,tail=input:match("^(%S+)%s*(.-)%s*$")
        verb=(verb or ""):lower()
        if consoleController.run(input,verb,tail) then return end
        if verb=="help" then
            log("INFO","-- CONSOLE COMMAND CENTER / v"..VERSION.." --")
            log("INFO","settings | get KEY | set KEY VALUE | toggle KEY | resetsettings")
            log("INFO","tab Aimbot/ESP/Modifiers/Compat/Settings/Debug")
            log("INFO","diagnose (full snapshot to clipboard) | status | aimstatus")
            log("INFO","probe | sources | targets | team | calibrate | pick | clearteam | rescan")
            log("INFO","compat | compatmove | compatclear | copycompat")
            log("INFO","inputdiag | copyinput | resetinput | modprobe | modstatus")
            log("INFO","copyreport | copylogs | find TEXT | history")
            log("INFO","recenter | esp on/off | aimbot on/off | clear | unload")
            log("INFO","Examples: set fov 200 ; toggle skeleton ; set aimMethod Auto")
        elseif verb=="diagnose" or verb=="healthcheck" then
            -- A single reproducible capture of the exact client-visible
            -- state. Never guesses hidden player positions and never changes
            -- aim/ESP settings.
            local stages={}
            local function stage(label,fn)
                local ok,err=pcall(fn)
                stages[#stages+1]=label..": "..(ok and "OK" or ("ERROR "..tostring(err)))
                return ok
            end
            stage("Fresh ESP model discovery",function()
                fallbackNextScan=0
                discoverTargets()
            end)
            stage("Fresh compatibility snapshot",function()
                Compat.emit()
            end)
            local ok,details=pcall(report)
            if not ok then
                stages[#stages+1]="Full report generation: ERROR "..tostring(details)
                details="Report failed: "..tostring(details)
            end
            local camera=Workspace.CurrentCamera
            local summary={
                "SPECTRA ONE-STEP DIAGNOSTICS / v"..VERSION,
                "PlaceId: "..tostring(game.PlaceId),
                "Players: "..tostring(#Players:GetPlayers()),
                "Camera type: "..(camera and camera.CameraType.Name or "unavailable"),
                "ESP enabled: "..tostring(state.enabled)
                    .." | targets: "..tostring(#targets)
                    .." | displayed: "..tostring(stats.rendered),
                "Enemy/team calibration: "..calibrationMode.." | "..calibrationMessage,
                "Source: "..lastSource,
                "Discovery: "..lastScanDetails,
                "Fallback: "..fallbackSummary,
                "ESP rendering errors: "..tostring(stats.espRenderErrors or 0),
                "Aimbot enabled: "..tostring(state.aimEnabled)
                    .." | backend: "..aimBackend
                    .." | errors: "..tostring(aimErrors),
                "Connection counts: "..#connections.." tracked; "
                    ..#watcherConnections.." source watchers",
                "-- CAPTURE STAGES --"
            }
            for _,entry in ipairs(stages) do summary[#summary+1]=entry end
            summary[#summary+1]="-- COMPLETE REPORT --"
            summary[#summary+1]=details
            local bundle=table.concat(summary,"\n")
            log("INFO","DIAGNOSE: "..#targets.." targets / "..stats.rendered
                .." shown / "..(stats.espRenderErrors or 0).." render errors")
            log("INFO","DIAGNOSE: "..fallbackSummary)
            if type(setclipboard)=="function" and pcall(setclipboard,bundle) then
                log("INFO","Complete diagnostic bundle copied to clipboard; paste it into chat.")
            else
                print("[SPECTRA DIAGNOSE] BEGIN")
                print(bundle)
                print("[SPECTRA DIAGNOSE] END")
                log("WARN","Clipboard unavailable; full bundle printed to executor/Roblox log.")
            end
        elseif verb=="status" then
            log("INFO","v"..VERSION.." | Aimbot="..tostring(state.aimEnabled)
                .." | "..aimStatus.." | method="..state.aimMethod
                .." | backend="..aimBackend)
            log("INFO","ESP="..tostring(state.enabled).." | shown="..stats.rendered
                .." | targets="..#targets.." | enemies="..stats.matched
                .." | unknown="..(stats.anonymous+stats.unknownTeams)
                .." | allies excluded="..stats.teammates
                .." | FPS="..math.floor(stats.fps))
        elseif verb=="compat" then
            Compat.emit()
            log("INFO","Compatibility report printed to Roblox logs")
        elseif verb=="compatmove" then Compat.startObservation()
        elseif verb=="compatclear" then
            Movement.restore()
            Movement.data.model=nil;Movement.data.root=nil;Movement.data.humanoid=nil
            SelfCalibration.clear("Cleared by user")
            log("INFO","Session character calibration cleared")
        elseif verb=="copycompat" then Compat.copy()
        elseif verb=="inputdiag" then
            for _,entry in ipairs(getInputDiagnosticsLines()) do log("INFO",entry) end
        elseif verb=="copyinput" then copyInputDiagnostics()
        elseif verb=="resetinput" then
            resetInputDiagnostics()
            log("INFO","Camera and input counters reset")
        elseif verb=="modstatus" then
            for entry in Movement.report():gmatch("[^\n]+") do log("INFO",entry) end
        elseif verb=="modprobe" then
            log("INFO",Movement.probe())
            log("INFO",Movement.data.status)
        elseif verb=="probe" or verb=="rescan" then
            fallbackNextScan=0
            discoverTargets()
            log("INFO","ESP scan: "..lastSource.." / "..lastScanDetails)
        elseif verb=="sources" then
            for _,entry in ipairs(inspectDataSources()) do log("INFO",entry) end
        elseif verb=="team" then
            log("INFO","Team calibration: "..calibrationMessage
                .." | mode="..calibrationMode.." | events="..groupEvents)
        elseif verb=="calibrate" then calibrateEnemyFromCrosshair()
        elseif verb=="pick" then beginPicker()
        elseif verb=="clearteam" then
            clearCalibration()
            discoverTargets()
            log("INFO","Manual team calibration cleared")
        elseif verb=="recenter" then
            clampWindow(true)
            log("INFO","Window recentered")
        elseif verb=="targets" then
            log("INFO","Enemy targets="..#targets.." | player-owned="..stats.matched)
            for i=1,math.min(15,#targets) do
                local t=targets[i]
                log("INFO",string.format("%d) %s [%s]",i,
                    t.player and t.player.Name or "unidentified rig",t.source))
            end
        elseif verb=="aimstatus" then
            log("INFO","Aim: "..aimStatus.." | gameplay="..aimLastGameplayStatus
                .." | backend="..aimBackend
                .." | candidates="..aimSelectionCount
                .." | updates="..aimUpdates.." | errors="..aimErrors)
            log("INFO",getAimGateDiagnostics().." | aimKey="..state.aimKey)
        elseif input:lower()=="aimbot on" then
            local ok,msg=consoleController.run(input,"set","aimEnabled on")
            -- set command handles the value and refreshes controls.
        elseif input:lower()=="aimbot off" then
            consoleController.run(input,"set","aimEnabled off")
        elseif input:lower()=="esp on" then
            consoleController.run(input,"set","enabled on")
        elseif input:lower()=="esp off" then
            consoleController.run(input,"set","enabled off")
        elseif verb=="copyreport" or verb=="report" then
            exportReport()
        elseif verb=="copylogs" then
            local data=table.concat(logs,"\n")
            if type(setclipboard)=="function" and pcall(setclipboard,data) then
                log("INFO","Console logs copied")
            else
                print(data)
                log("WARN","Clipboard unavailable; console logs printed")
            end
        elseif verb=="find" then
            if tail=="" then
                log("WARN","Usage: find <text>")
                return
            end
            local matches={}
            for _,entry in ipairs(logs) do
                if entry:lower():find(tail:lower(),1,true) then
                    matches[#matches+1]=entry
                end
            end
            log("INFO","Found "..#matches.." matching log entries (showing up to 12)")
            for i=math.max(1,#matches-11),#matches do
                log("INFO",matches[i])
            end
        elseif verb=="history" then
            for i=math.max(1,#commandHistory-12),#commandHistory do
                log("INFO",i..": "..commandHistory[i])
            end
        elseif verb=="clear" then
            table.clear(logs)
            if logBox then logBox.Text="" end
        elseif verb=="unload" then shutdown()
        else
            log("WARN","Unknown command: "..input.." (type help)")
        end
    end
    local function submitCommand()
        local raw=cmd.Text
        cmd.Text=""
        safeCall("Console command",function() runCommand(raw) end)
    end
    connect(run.MouseButton1Click,submitCommand)
    connect(cmd.FocusLost,function(enterPressed)
        if enterPressed then submitCommand() end
    end)
    connect(cmd.InputBegan,function(input)
        if input.KeyCode==Enum.KeyCode.Up then
            commandHistoryCursor=math.max(1,commandHistoryCursor-1)
            cmd.Text=commandHistory[commandHistoryCursor] or cmd.Text
            cmd.CursorPosition=#cmd.Text+1
        elseif input.KeyCode==Enum.KeyCode.Down then
            commandHistoryCursor=math.min(#commandHistory+1,commandHistoryCursor+1)
            cmd.Text=commandHistory[commandHistoryCursor] or ""
            cmd.CursorPosition=#cmd.Text+1
        end
    end)
    groupLabel(debugPage,"CONSOLE QUICK REFERENCE")
    row(debugPage,"Menu settings","settings · get aimFovRadius · set fov 200 · toggle skeleton")
    row(debugPage,"Navigation","tab ESP · tab Aimbot · tab Settings · tab Debug")
    row(debugPage,"Troubleshooting","diagnose · probe · sources · aimstatus · copyreport")
    action(debugPage,"Run full diagnostics & copy bundle",function()
        runCommand("diagnose")
    end)
    action(debugPage,"Print full command help",function() runCommand("help") end)
    action(debugPage,"Show every menu setting",function() runCommand("settings") end)

    selectTab("ESP")
    clampWindow(true)
    local compatElapsed=0
    local compatAutoSamples=0
    -- Dragging is limited to the header; no changes to Roblox input state.
    local dragging=false
    local dragStart, windowStart
    connect(top.InputBegan,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 then
            dragging=true;dragStart=input.Position;windowStart=window.Position
        end
    end)
    connect(UserInputService.InputChanged,function(input)
        if input.UserInputType==Enum.UserInputType.MouseMovement then
            inputDiag.mouseEvents+=1
            inputDiag.totalMouseEvents+=1
            local pixels=input.Delta.Magnitude
            inputDiag.mousePixels+=pixels
            inputDiag.totalMousePixels+=pixels
        end
        if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then
            local d=input.Position-dragStart
            window.Position=UDim2.new(windowStart.X.Scale,windowStart.X.Offset+d.X,windowStart.Y.Scale,windowStart.Y.Offset+d.Y)
            clampWindow(false)
        end
    end)
    connect(UserInputService.InputEnded,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
        if input.UserInputType==Enum.UserInputType.MouseButton2 then aimRmbHeld=false end
        if input.UserInputType==Enum.UserInputType.Keyboard then
            local key=input.KeyCode==Enum.KeyCode.LeftAlt and "Left Alt" or input.KeyCode.Name
            aimKeyHeld[key]=false
        end
    end)
    connect(UserInputService.InputBegan,function(input,gameProcessed)
        if input.UserInputType==Enum.UserInputType.MouseButton2 then
            aimRmbHeld=not (window and window.Visible) and not UserInputService:GetFocusedTextBox()
        end
        if not gameProcessed and not UserInputService:GetFocusedTextBox() then
            if input.UserInputType==Enum.UserInputType.Keyboard then
                local key=input.KeyCode==Enum.KeyCode.LeftAlt and "Left Alt" or input.KeyCode.Name
                aimKeyHeld[key]=true
            end
        end
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
        compatElapsed+=dt
        -- Two bounded follow-up snapshots catch delayed character replication
        -- after the initial read-only startup snapshot. No continuous logging.
        if compatAutoSamples<2
            and compatElapsed >= (compatAutoSamples==0 and 6 or 20) then
            compatAutoSamples+=1
            safeCall("Compatibility follow-up snapshot",Compat.emit)
        end
        updateInputDiagnostics(dt)
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
        updateAimVisual(Workspace.CurrentCamera)
        if statAccumulator>=0.7 then
            statAccumulator=0
            if aimStatusText and aimStatusText.Parent then
                aimStatusText.Text=aimStatus
            end
            if Movement.statusLabel and Movement.statusLabel.Parent then
                Movement.statusLabel.Text=Movement.data.status.."\nSource: "..Movement.data.source
                    .." | errors: "..Movement.data.errors
                    .."\n"..SelfCalibration.statusText()
                Movement.statusLabel.TextColor3=(Movement.data.root and Movement.data.root.Parent)
                    and C.green or C.orange
            end
            if statusText and statusText.Parent then
                statusText.Text=string.format("v%s · ESP %s · %d targets / %d unknown · %d shown · %d FPS",VERSION,state.enabled and "ON" or "OFF",#targets,stats.anonymous+stats.unknownTeams,stats.rendered,math.floor(stats.fps+0.5))
            end
            clampWindow(false)
            if debugSummary and debugSummary.Parent then
                debugSummary.Text=string.format("%s\n%s   |   render target %d Hz",lastSource,lastScanDetails,UPDATE_HZ)
            end
            if inputDiagLiveText and inputDiagLiveText.Parent then
                inputDiagLiveText.Text=getInputDiagnosticsReport()
            end
        end
    end)
    connect(UserInputService.JumpRequest,Movement.jumpRequested)
    connect(RunService.Heartbeat,function(dt)
        if not alive then return end
        local observeOK,observeError=pcall(Compat.sampleObservation,dt)
        if not observeOK then
            log("ERROR","Read-only motion observation failed: "..tostring(observeError))
            Compat.observation=nil
        end
        local hadCalibration=SelfCalibration.active~=nil
        if hadCalibration and not SelfCalibration.validate() then
            -- Restore original properties before the next movement write.
            Movement.restore()
            Movement.data.model=nil;Movement.data.root=nil
            Movement.data.humanoid=nil;Movement.data.source="none"
        end
        local ok,err=pcall(Movement.update,dt)
        if not ok then
            Movement.data.errors+=1
            Movement.data.status="Modifier exception: "..tostring(err)
            if Movement.data.errors<=3 then log("ERROR","Movement modifier failed: "..tostring(err)) end
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
        if aimObservedCameraConnection then
            aimObservedCameraConnection:Disconnect()
            aimObservedCameraConnection=nil
        end
        aimObservedCamera=nil
        disableAimCorrection()
        for _,w in pairs(widgets) do if w.highlight then w.highlight:Destroy();w.highlight=nil end end
        clampWindow(false)
        log("INFO","Camera changed; optional highlights reset")
    end)

    local aimBindOk,aimBindError=pcall(function()
        -- The game's camera is custom-controlled; apply this optional client-only
        -- visual aim adjustment late in the render phase rather than just after
        -- Roblox's default camera priority.
        RunService:BindToRenderStep(AIM_RENDER_BIND,Enum.RenderPriority.Last.Value-1,function(dt)
            local ok,err=pcall(runAimbot,dt)
            if not ok then
                aimErrors+=1
                aimGateCounts.renderErrors+=1
                aimLastGameplayStatus="Aimbot runtime error: "..tostring(err)
                aimLastGameplayTime=os.date("%H:%M:%S")
                if aimErrors<=3 then log("ERROR","Aimbot update failed: "..tostring(err)) end
            end
        end)
    end)
    if not aimBindOk then
        log("ERROR","Aimbot render binding unavailable: "..tostring(aimBindError))
    end
    log("INFO","SPECTRA Phase 1 v1.26.1 loaded. One-command diagnostic bundle and verified-enemy ESP filtering")
    log("INFO","Strict ESP filter active: unknown and allied rigs are never shown. F6 can calibrate opponents.")
    watchPlayerFolder()
    safeCall("Initial compatibility snapshot",function()
        Compat.emit()
        log("INFO","Read-only compatibility snapshot written to console; open Compat tab or run compat")
    end)
    safeCall("Initial scan",discoverTargets)
    log("INFO","Initial discovery: "..lastSource.." / "..lastScanDetails)
    if #targets==0 then
        log("WARN","ESP has no confirmed enemy positions. "..fallbackSummary)
        log("WARN","If Roblox exposes no valid player-owned character models, this client-only script cannot draw reliable ESP.")
    end
end

local startOk,startError=pcall(launchSpectraUI)
if not startOk then
    warn("[SPECTRA] Startup failure: "..tostring(startError))
    shutdown()
end
