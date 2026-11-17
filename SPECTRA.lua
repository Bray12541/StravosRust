--[[
    SPECTRA / PHASE 1                         v1.3.1
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

local VERSION = "1.3.1"
local alive = true
local connections = {}
local tracked = {}
local widgets = {}
local logs = {}
local targets = {}
local lastSource = "Not scanned"
local lastScanDetails = "Not scanned"
local stats = {discovered=0, matched=0, anonymous=0, enemyGroups=0, unknownTeams=0, teammates=0, skeletonRigs=0, rejected=0, rendered=0, fps=0, scans=0, drawn=0, sample=0, frameMs=0}
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
    boxes = true,
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
local function getGroupRelation(model)
    local mine = LocalPlayer.Team
    if not mine then return "unknown" end
    local group = model
    for _ = 1, 4 do
        if not group or group == Workspace then break end
        -- Test each candidate separately; ipairs({nil, ...}) would skip
        -- later metadata and miss otherwise valid team folder names.
        local function matchTeam(candidate)
            if typeof(candidate) ~= "string" or candidate == "" then return nil end
            local team = TeamsService:FindFirstChild(candidate)
            if team and team:IsA("Team") then
                return team == mine and "ally" or "enemy"
            end
            return nil
        end
        for _, field in ipairs({"Team", "TeamName", "TeamId"}) do
            local relation = matchTeam(group:GetAttribute(field))
            if relation then return relation end
        end
        local relation = matchTeam(group.Name)
        if relation then return relation end
        group = group.Parent
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
    }, overlayLayer), edges={}, skeleton={}}
    for i=1,4 do w.edges[i] = makeLine(w.root) end
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
local function discoverTargets()
    if not alive then return end
    local seen, nextTargets = {}, {}
    local verified, unverified, checked, rejected, excluded, skeletonRigs, groupEnemies, unknownTeam = 0, 0, 0, 0, 0, 0, 0, 0
    local samples = {}
    local function admit(model, player, source)
        if seen[model] or #nextTargets >= 72 then return end
        seen[model] = true
        if player == LocalPlayer then return end
        local ok, root = validModel(model)
        if not ok then rejected += 1; return end

        local relation = player and getPlayerRelation(player) or getGroupRelation(model)
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
    for _, t in ipairs(targets) do
        local model = t.model
        local w = widgets[model]
        local shouldShow = model.Parent ~= nil and t.root and t.root.Parent ~= nil
            and t.relation == "enemy" and (not t.player or getPlayerRelation(t.player) == "enemy")
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
            local edges = w.edges
            for i=1,4 do edges[i].Visible = state.boxes end
            if state.boxes then
                put(edges[1],left,top,right,top,clr,1)
                put(edges[2],right,top,right,bottom,clr,1)
                put(edges[3],right,bottom,left,bottom,clr,1)
                put(edges[4],left,bottom,left,top,clr,1)
            end
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
            updateSkeleton(w,t,camera,clr)
            updateHighlight(w,model,camera,clr)
        else
            hideWidget(w)
        end
    end
    stats.rendered = done
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
        "Options: boxes="..tostring(state.boxes).." skeleton="..tostring(state.skeleton).." highlights="..tostring(state.highlights),
        "Enemy-only tracking: "..tostring(stats.teammates).." allies excluded; unknown teams: "..tostring(stats.unknownTeams),
        "Group-matched enemy rigs: "..tostring(stats.enemyGroups).." (only when Roblox Team names match)",
        "Fixed limits: 1000 studs / 50 Hz target",
        "Skeleton rigs with joints: "..tostring(stats.skeletonRigs).."/"..tostring(stats.matched),
        "No getgc, hooks, remote scripts, or writes to other character models.",
        "-- RECENT LOGS --"
    }
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
    for key in pairs(widgets) do destroyWidget(key) end
    for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
    table.clear(connections)
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
local sub=textLabel(top,"PLAYER VISUALS  /  1.3.1",10,C.muted)
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
local tag=textLabel(left,"WORKSPACE",10,C.muted,true)
tag.Position=UDim2.fromOffset(16,19);tag.Size=UDim2.fromOffset(115,18)
local content=create("Frame",{Position=UDim2.fromOffset(145,54),Size=UDim2.new(1,-145,1,-54),BackgroundTransparency=1,BorderSizePixel=0},window)
local footer=create("Frame",{BackgroundColor3=C.base,BorderSizePixel=0,Position=UDim2.new(0,145,1,-32),Size=UDim2.new(1,-145,0,32)},window)
create("Frame",{BackgroundColor3=C.border,BorderSizePixel=0,Size=UDim2.new(1,0,0,1)},footer)
statusText=textLabel(footer,"Initializing...",10,C.muted)
statusText.Position=UDim2.fromOffset(17,4);statusText.Size=UDim2.new(1,-34,1,-8)
local pages={}
local tabButtons={}
for index,name in ipairs({"ESP","Settings","Debug"}) do
    local b=create("TextButton",{
        Text=string.format("%02d    %s",index,name),TextSize=12,Font=Enum.Font.GothamMedium,
        TextColor3=C.muted,TextXAlignment=Enum.TextXAlignment.Left,
        BackgroundColor3=C.sidebar,Size=UDim2.fromOffset(123,35),Position=UDim2.fromOffset(11,46+(index-1)*42),BorderSizePixel=0
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
header(espPage,"Player visuals","Enemy team only · missing team data never renders")
groupLabel(espPage,"DISPLAY")
toggle(espPage,"Enable ESP","Master switch for visual markers","enabled")
toggle(espPage,"2D boxes","Screen-space rectangles around verified characters","boxes")
toggle(espPage,"Distance","Camera distance in Roblox studs","distances")
toggle(espPage,"Tracers","Lines from screen bottom to target boxes","tracers")
toggle(espPage,"Skeleton","Uses rig Motor6D joints, Bones, or standard limbs where present","skeleton")
toggle(espPage,"3D highlight","Client-only camera-owned highlight, not target-owned","highlights")
groupLabel(espPage,"FIXED RULES")
row(espPage,"Teammates excluded","Unknown-team models hidden until team can be verified")
row(espPage,"1000 studs · 50 Hz","Hardcoded range and marker refresh target")

local colorButton
colorButton=action(espPage,"Marker color: Cyan  (click to cycle)",function()
    local order={"Cyan","Coral","Lime","White"}
    local n=1
    for i,v in ipairs(order) do if v==state.color then n=i%#order+1 end end
    state.color=order[n]
    colorButton.Text="Marker color: "..state.color.."  (click to cycle)"
    log("INFO","Marker color: "..state.color)
end)


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
header(settingsPage,"Settings","Runtime behavior and clean shutdown")
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
    if input=="help" then log("INFO","Commands: help, status, probe, targets, recenter, esp on, esp off, clear, unload")
    elseif input=="status" then log("INFO","ESP="..tostring(state.enabled).." visible="..stats.rendered.." targets="..#targets.." verified="..stats.matched.." enemyGroups="..stats.enemyGroups.." unidentified="..stats.anonymous.." unknownTeams="..stats.unknownTeams.." excluded="..stats.teammates.." fps="..math.floor(stats.fps).." connections="..#connections)
    elseif input=="probe" then discoverTargets();log("INFO",lastSource.." / "..lastScanDetails)
    elseif input=="recenter" then clampWindow(true);log("INFO","Window centered")
    elseif input=="targets" then
        log("INFO","Candidates: "..#targets.."  verified="..stats.matched.." unverified="..stats.anonymous)
        for i=1,math.min(12,#targets) do
            local t=targets[i]
            log("INFO",string.format("%d) %s [%s, %s]",i,t.label,t.source,t.player and "verified" or "unverified"))
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
    if scanAccumulator >= 2.2 then
        scanAccumulator = 0
        safeCall("Discover",discoverTargets)
    end
    if renderAccumulator >= UPDATE_PERIOD then
        renderAccumulator = renderAccumulator % UPDATE_PERIOD
        safeCall("Render",render)
    end
    if statAccumulator>=0.7 then
        statAccumulator=0
        if statusText and statusText.Parent then
            statusText.Text=string.format("ESP %s  ·  %d targets / %d unknown  ·  %d shown  ·  %d FPS",state.enabled and "ON" or "OFF",#targets,stats.anonymous+stats.unknownTeams,stats.rendered,math.floor(stats.fps+0.5))
        end
        clampWindow(false)
        if debugSummary and debugSummary.Parent then
            debugSummary.Text=string.format("%s\n%s   |   render target %d Hz",lastSource,lastScanDetails,UPDATE_HZ)
        end
    end
end)
connect(Players.PlayerAdded,function(p) log("INFO","Player joined: "..p.Name);scanAccumulator=10 end)
connect(Players.PlayerRemoving,function(p) log("INFO","Player left: "..p.Name);scanAccumulator=10 end)
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"),function()
    for _,w in pairs(widgets) do if w.highlight then w.highlight:Destroy();w.highlight=nil end end
    clampWindow(false)
    log("INFO","Camera changed; optional highlights reset")
end)

log("INFO","SPECTRA Phase 1 v1.3.1 loaded. Right Shift: hide/show | F8: debug | Ctrl+End: unload")
log("INFO","Enemy-only tracking; unknown team/owner models are excluded, diagnostics show the reason")
safeCall("Initial scan",discoverTargets)
log("INFO","Initial discovery: "..lastSource.." / "..lastScanDetails)