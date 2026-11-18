--[[
    SPECTRA / STUDIO EDITION                      v2.0.0-studio
    Developer overlay for a Roblox experience you own.
    LocalScript: StarterPlayer.StarterPlayerScripts.SpectraClient

    Requires ReplicatedStorage.SpectraShared and
    ServerScriptService.SpectraServer. Opens only for players the server
    authorizes (owner / group owner / allow-list / anyone in Studio).

    RSHIFT: hide/show menu | F8: command center | HOME: center | Ctrl+End: unload

    Ported from SPECTRA Phase 1 v1.27.1. Kept: theme, window layout, tab
    navigation, toggles/sliders/actions, command center with history,
    event log, COPY FULL LOG, diagnostics, keybinds, drag, clamp, shutdown.
    Uses only standard Roblox APIs (no executor functions).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Teams = game:GetService("Teams")

local LocalPlayer = Players.LocalPlayer
local Shared = require(ReplicatedStorage:WaitForChild("SpectraShared"))
local VERSION = Shared.VERSION
local SCHEMA = Shared.SCHEMA

-- Authorization ---------------------------------------------------------------
-- The server sets this attribute. A missing attribute means the server script
-- has not run yet, so wait briefly instead of failing open.
local function waitForAuthorization(timeout)
    local deadline = os.clock() + timeout
    while LocalPlayer:GetAttribute(Shared.AUTH_ATTRIBUTE) == nil and os.clock() < deadline do
        task.wait(0.1)
    end
    return LocalPlayer:GetAttribute(Shared.AUTH_ATTRIBUTE) == true
end
if not waitForAuthorization(10) then
    return
end

-- Duplicate-instance prevention ----------------------------------------------
-- A previous copy (e.g. the script was re-enabled) is unloaded first; if it
-- left UI behind without a handle, that UI is destroyed.
if type(_G.SPECTRA_UNLOAD) == "function" then
    local ok, err = pcall(_G.SPECTRA_UNLOAD)
    if not ok then warn("[SPECTRA] Previous instance cleanup failed: " .. tostring(err)) end
end
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
for _, name in ipairs({"SPECTRA_UI", "SPECTRA_Overlay", "SPECTRA_Tags"}) do
    local leftover = PlayerGui:FindFirstChild(name)
    if leftover then leftover:Destroy() end
end

local alive = true
local connections = {}
local logs = {}
local state = Shared.defaults()
local persisted = false
local configRemote

local overlayGui, menuGui, tagFolder, window, statusText, logBox, debugSummary, assistRing
local tabs, toggleRefreshers = {}, {}
local markers = {}          -- [Player] = {highlight=Highlight?, tag=BillboardGui?, label=TextLabel?}
local playerRows = {}       -- latest diagnostics snapshot
local commandHistory, commandHistoryCursor = {}, 1
local stats = {fps=0, highlighted=0, tagged=0, teammates=0, opponents=0, neutral=0}
local assist = {active=false, target=nil, original=nil, supported=nil, frames=0, engagedFrames=0, lastError=nil}

local MAX_HIGHLIGHTS = 31 -- Roblox renders at most 31 Highlight instances at once

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
    orange = Color3.fromRGB(231, 182, 112),
}

local function refreshAllToggles()
    for _, refresh in ipairs(toggleRefreshers) do pcall(refresh) end
end
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections + 1] = connection
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
        BorderSizePixel=0,
    }, parent)
end
local function log(level, message)
    local entry = string.format("[%s] [%-5s] %s", os.date("%H:%M:%S"), level, tostring(message))
    logs[#logs + 1] = entry
    if #logs > 140 then table.remove(logs, 1) end
    if logBox and logBox.Parent then logBox.Text = table.concat(logs, "\n") end
    if level == "ERROR" then warn("[SPECTRA] " .. tostring(message)) end
end
local function safeCall(label, callback, ...)
    local ok, err = pcall(callback, ...)
    if not ok then log("ERROR", label .. ": " .. tostring(err)) end
    return ok
end

-- Team identification ---------------------------------------------------------
-- Uses the experience's own Team objects. With no Teams, everyone else is an
-- opponent (free-for-all). Neutral players are never treated as teammates.
local function hasTeams()
    return #Teams:GetTeams() > 0
end
local function getRelation(player)
    if player == LocalPlayer then return "self" end
    if not hasTeams() then return "opponent" end
    if player.Neutral or not player.Team then return "neutral" end
    if not LocalPlayer.Neutral and LocalPlayer.Team == player.Team then return "teammate" end
    return "opponent"
end
local function relationColor(player, relation)
    if state.teamColors and player.Team and not player.Neutral then
        return player.TeamColor.Color
    end
    if relation == "teammate" then return C.green end
    if relation == "opponent" then return Shared.COLOR_MODES[state.color] or C.accent end
    return C.muted
end
local function getCharacterParts(player)
    local character = player.Character
    if not character or not character.Parent then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    local head = character:FindFirstChild("Head")
    if not humanoid or not root then return nil end
    return character, humanoid, root, head
end

-- Player markers --------------------------------------------------------------
local function destroyMarker(player)
    local m = markers[player]
    if not m then return end
    if m.highlight then m.highlight:Destroy() end
    if m.tag then m.tag:Destroy() end
    markers[player] = nil
end
local function clearMarkers()
    for player in pairs(markers) do destroyMarker(player) end
end

local function updateMarkers()
    local myCharacter = LocalPlayer.Character
    local myRoot = myCharacter and (myCharacter:FindFirstChild("HumanoidRootPart") or myCharacter.PrimaryPart)
    local highlightCount, tagCount = 0, 0
    local counts = {teammate=0, opponent=0, neutral=0}
    local snapshot = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local relation = getRelation(player)
            counts[relation] = (counts[relation] or 0) + 1
            local character, humanoid, root, head = getCharacterParts(player)
            local distance = (character and myRoot) and (root.Position - myRoot.Position).Magnitude or nil
            snapshot[#snapshot + 1] = {
                name = player.Name, team = player.Team and player.Team.Name or "None",
                relation = relation, health = humanoid and math.floor(humanoid.Health + 0.5) or nil,
                distance = distance and math.floor(distance + 0.5) or nil,
            }
            local wantsHighlight = state.highlights and character and humanoid.Health > 0
                and ((relation == "teammate" and state.teammates) or (relation ~= "teammate" and state.opponents))
            local wantsTag = state.nameTags and character and head and humanoid.Health > 0
                and (distance == nil or distance <= state.maxDistance)
                and ((relation == "teammate" and state.teammates) or (relation ~= "teammate" and state.opponents))
            if wantsHighlight and highlightCount >= MAX_HIGHLIGHTS then wantsHighlight = false end

            local m = markers[player]
            if not m then m = {}; markers[player] = m end
            local color = relationColor(player, relation)
            -- Teammates are visible through walls (standard squad UI).
            -- Opponents use Occluded depth, so they are only outlined where
            -- the local player can already see them.
            local depth = relation == "teammate" and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded

            if wantsHighlight then
                if not m.highlight or m.highlight.Adornee ~= character or not m.highlight.Parent then
                    if m.highlight then m.highlight:Destroy() end
                    m.highlight = create("Highlight", {Name="SPECTRA_Highlight", Adornee=character}, character)
                end
                m.highlight.DepthMode = depth
                m.highlight.FillColor = color
                m.highlight.OutlineColor = color
                m.highlight.FillTransparency = state.fillTransparency / 100
                m.highlight.OutlineTransparency = 0.1
                highlightCount += 1
            elseif m.highlight then
                m.highlight:Destroy(); m.highlight = nil
            end

            if wantsTag then
                if not m.tag or m.tag.Adornee ~= head or not m.tag.Parent then
                    if m.tag then m.tag:Destroy() end
                    m.tag = create("BillboardGui", {
                        Name="SPECTRA_Tag_" .. player.Name, Adornee=head, Size=UDim2.fromOffset(160, 34),
                        StudsOffsetWorldSpace=Vector3.new(0, 2.6, 0), LightInfluence=0, ResetOnSpawn=false,
                    }, tagFolder)
                    m.label = create("TextLabel", {
                        BackgroundTransparency=1, Size=UDim2.fromScale(1, 1), Font=Enum.Font.GothamMedium,
                        TextSize=12, TextStrokeTransparency=0.4, TextWrapped=true,
                    }, m.tag)
                end
                m.tag.AlwaysOnTop = relation == "teammate"
                local text = player.DisplayName
                if hasTeams() then text ..= "  ·  " .. (player.Team and player.Team.Name or "No team") end
                if state.distances and distance then text ..= "\n" .. math.floor(distance + 0.5) .. " studs" end
                m.label.Text = text
                m.label.TextColor3 = color
                tagCount += 1
            elseif m.tag then
                m.tag:Destroy(); m.tag = nil; m.label = nil
            end
        end
    end
    for player in pairs(markers) do
        if player.Parent ~= Players then destroyMarker(player) end
    end
    stats.highlighted, stats.tagged = highlightCount, tagCount
    stats.teammates, stats.opponents, stats.neutral = counts.teammate, counts.opponent, counts.neutral
    playerRows = snapshot
end

-- Aim-assist demonstration ------------------------------------------------------
-- Friction-style assist (as used by console shooters): while the reticle is
-- over a visible opponent, mouse sensitivity is reduced. It never rotates the
-- camera toward anyone. Requires the server's Workspace master switch.
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function assistAllowed()
    return state.assistEnabled and Workspace:GetAttribute(Shared.ASSIST_ATTRIBUTE) == true
end
local function setSensitivityScale(scale)
    if assist.original == nil then
        local ok, value = pcall(function() return UserInputService.MouseDeltaSensitivity end)
        if not ok then
            assist.supported = false
            assist.lastError = tostring(value)
            return false
        end
        assist.original = value
    end
    local ok, err = pcall(function() UserInputService.MouseDeltaSensitivity = assist.original * scale end)
    assist.supported = ok
    if not ok then assist.lastError = tostring(err) end
    return ok
end
local function releaseAssist()
    if assist.original ~= nil then
        pcall(function() UserInputService.MouseDeltaSensitivity = assist.original end)
        assist.original = nil
    end
    assist.active = false
    assist.target = nil
end
local function reticlePosition(camera)
    if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return camera.ViewportSize / 2
    end
    return UserInputService:GetMouseLocation()
end
local function updateAssist()
    assist.frames += 1
    local camera = Workspace.CurrentCamera
    if not alive or not camera or not assistAllowed() or (window and window.Visible)
        or UserInputService:GetFocusedTextBox() then
        if assist.active or assist.original ~= nil then releaseAssist() end
        if assistRing then assistRing.Visible = false end
        return
    end
    local reticle = reticlePosition(camera)
    if assistRing then
        assistRing.Visible = state.assistRingVisible
        assistRing.Size = UDim2.fromOffset(state.assistRadius * 2, state.assistRadius * 2)
        assistRing.Position = UDim2.fromOffset(reticle.X - state.assistRadius, reticle.Y - state.assistRadius)
    end
    raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
    local best, bestDistance
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and getRelation(player) ~= "teammate" then
            local character, humanoid, root, head = getCharacterParts(player)
            if character and humanoid.Health > 0 then
                local aimPart = head or root
                local screen, onScreen = camera:WorldToViewportPoint(aimPart.Position)
                if onScreen and screen.Z > 0 then
                    local d = (Vector2.new(screen.X, screen.Y) - reticle).Magnitude
                    if d <= state.assistRadius and (not bestDistance or d < bestDistance) then
                        local origin = camera.CFrame.Position
                        local hit = Workspace:Raycast(origin, aimPart.Position - origin, raycastParams)
                        if not hit or hit.Instance:IsDescendantOf(character) then
                            best, bestDistance = player, d
                        end
                    end
                end
            end
        end
    end
    if best then
        local scale = 1 - state.assistStrength / 100
        if setSensitivityScale(scale) then
            assist.active = true
            assist.target = best
            assist.engagedFrames += 1
        end
    elseif assist.active then
        releaseAssist()
    end
    if assistRing then
        local stroke = assistRing:FindFirstChildOfClass("UIStroke")
        if stroke then stroke.Color = best and C.green or C.accent end
    end
end

-- Configuration storage -----------------------------------------------------------
local function applySettings(settings)
    state = Shared.sanitize(settings)
    refreshAllToggles()
end
local function requestConfig(action, payload)
    if not configRemote then return {ok=false, error="config remote unavailable"} end
    local ok, result = pcall(configRemote.InvokeServer, configRemote, action, payload)
    if not ok then return {ok=false, error=tostring(result)} end
    if type(result) ~= "table" then return {ok=false, error="malformed server response"} end
    return result
end
local function loadSettings()
    local result = requestConfig("load")
    if result.ok then
        applySettings(result.settings)
        persisted = result.persisted == true
        log("INFO", persisted and "Settings loaded from DataStore"
            or ("Using default settings (" .. tostring(result.error or "not persisted") .. ")"))
    else
        log("WARN", "Settings load failed: " .. tostring(result.error))
    end
end
local function saveSettings()
    local result = requestConfig("save", state)
    if result.ok then
        persisted = true
        log("INFO", "Settings saved")
    else
        log("WARN", "Settings not saved: " .. tostring(result.error))
    end
    return result.ok
end
local function resetSettings()
    local result = requestConfig("reset")
    applySettings(result.ok and result.settings or Shared.defaults())
    log("INFO", result.ok and "Settings reset to defaults" or ("Reset locally; server: " .. tostring(result.error)))
end

-- Diagnostics -------------------------------------------------------------------------
local function playerLines()
    local lines = {}
    for _, row in ipairs(playerRows) do
        lines[#lines + 1] = string.format("%-20s %-12s %-9s hp %-4s %s",
            row.name, row.team, row.relation, tostring(row.health or "-"),
            row.distance and (row.distance .. " st") or "no character")
    end
    if #lines == 0 then lines[1] = "(no other players)" end
    return lines
end
local function report()
    local camera = Workspace.CurrentCamera
    local lines = {
        "SPECTRA " .. VERSION .. " diagnostic report  " .. os.date("%Y-%m-%d %H:%M:%S"),
        "Place " .. game.PlaceId .. " | Studio " .. tostring(RunService:IsStudio()) .. " | players " .. #Players:GetPlayers(),
        "Teams: " .. (hasTeams() and (#Teams:GetTeams() .. " (" .. (LocalPlayer.Team and LocalPlayer.Team.Name or "you: none") .. ")") or "none - free-for-all"),
        string.format("Relations: %d teammates, %d opponents, %d neutral", stats.teammates, stats.opponents, stats.neutral),
        string.format("Markers: %d highlights (max %d), %d tags", stats.highlighted, MAX_HIGHLIGHTS, stats.tagged),
        string.format("Aim-assist demo: setting %s, server switch %s, sensitivity write %s, engaged %d/%d frames",
            tostring(state.assistEnabled), tostring(Workspace:GetAttribute(Shared.ASSIST_ATTRIBUTE)),
            assist.supported == nil and "untested" or tostring(assist.supported), assist.engagedFrames, assist.frames),
        assist.lastError and ("Assist error: " .. assist.lastError) or "Assist error: none",
        "Camera: " .. (camera and (camera.CameraType.Name .. " " .. tostring(camera.ViewportSize)) or "none")
            .. " | MouseBehavior " .. UserInputService.MouseBehavior.Name,
        string.format("FPS %d | connections %d | settings persisted %s", math.floor(stats.fps + 0.5), #connections, tostring(persisted)),
        "-- players --",
    }
    for _, line in ipairs(playerLines()) do lines[#lines + 1] = line end
    lines[#lines + 1] = "-- settings --"
    local keys = {}
    for key in pairs(SCHEMA) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do lines[#lines + 1] = key .. " = " .. tostring(state[key]) end
    return table.concat(lines, "\n")
end

-- Copy dialog: standard Luau has no clipboard API, so text is placed in a
-- focused, fully selected TextBox for Ctrl+C (Cmd+C on Mac). It is also
-- printed to the Output window. Touch/console devices can only read it.
local copyDialog, copyBox, copyTitle
local function showCopyDialog(title, text)
    if not copyDialog then
        log("WARN", "Copy dialog not ready")
        return
    end
    copyTitle.Text = title .. "  ·  Ctrl+C to copy, Esc or Close to dismiss"
    copyBox.Text = text
    copyDialog.Visible = true
    print("[SPECTRA] " .. title .. "\n" .. text)
    task.defer(function()
        if not copyBox.Parent then return end
        copyBox:CaptureFocus()
        copyBox.SelectionStart = 1
        copyBox.CursorPosition = #copyBox.Text + 1
    end)
end
local function exportReport() showCopyDialog("Diagnostic report", report()) end
local function copyFullLog()
    if #logs == 0 then log("WARN", "Event log is empty"); return end
    showCopyDialog("Event log (" .. #logs .. " entries)", table.concat(logs, "\n"))
end

-- Shutdown ---------------------------------------------------------------------------
local function shutdown()
    if not alive then return true end
    alive = false
    local errors = {}
    local function cleanup(label, callback)
        local ok, err = pcall(callback)
        if not ok then errors[#errors + 1] = label .. ": " .. tostring(err) end
    end
    cleanup("Restore mouse sensitivity", releaseAssist)
    cleanup("Remove markers", clearMarkers)
    for _, conn in ipairs(connections) do
        cleanup("Disconnect event", function() conn:Disconnect() end)
    end
    table.clear(connections)
    if overlayGui then cleanup("Destroy overlay", function() overlayGui:Destroy() end); overlayGui = nil end
    if tagFolder then cleanup("Destroy tags", function() tagFolder:Destroy() end); tagFolder = nil end
    if menuGui then cleanup("Destroy menu", function() menuGui:Destroy() end); menuGui = nil end
    if _G.SPECTRA_UNLOAD == shutdown then _G.SPECTRA_UNLOAD = nil end
    if #errors > 0 then
        for _, err in ipairs(errors) do warn("[SPECTRA] Cleanup: " .. err) end
        return false, table.concat(errors, "; ")
    end
    print("[SPECTRA] Unloaded cleanly; connections released.")
    return true
end
_G.SPECTRA_UNLOAD = shutdown

-- UI ---------------------------------------------------------------------------------
local function launchSpectraUI()
    overlayGui = create("ScreenGui", {Name="SPECTRA_Overlay", IgnoreGuiInset=true, ResetOnSpawn=false, DisplayOrder=160, ZIndexBehavior=Enum.ZIndexBehavior.Sibling}, PlayerGui)
    tagFolder = create("Folder", {Name="SPECTRA_Tags"}, PlayerGui)
    menuGui = create("ScreenGui", {Name="SPECTRA_UI", IgnoreGuiInset=true, ResetOnSpawn=false, DisplayOrder=161, ZIndexBehavior=Enum.ZIndexBehavior.Sibling}, PlayerGui)
    assistRing = create("Frame", {Name="AssistRadius", BackgroundTransparency=1, Visible=false, BorderSizePixel=0, Size=UDim2.fromOffset(180, 180), ZIndex=5}, overlayGui)
    create("UICorner", {CornerRadius=UDim.new(1, 0)}, assistRing)
    create("UIStroke", {Color=C.accent, Transparency=0.35, Thickness=1}, assistRing)

    window = create("Frame", {
        Name="MainWindow", Size=UDim2.fromOffset(660, 445), Position=UDim2.new(0.5, -330, 0.5, -223),
        BackgroundColor3=C.base, BorderSizePixel=0, ClipsDescendants=true, Active=true,
    }, menuGui)
    round(window, 9); outline(window)

    local function clampWindow(center)
        local camera = Workspace.CurrentCamera
        if not camera or not window then return end
        local vp = camera.ViewportSize
        local size = window.AbsoluteSize
        if center then
            window.Position = UDim2.fromOffset(math.floor((vp.X - size.X) / 2), math.floor((vp.Y - size.Y) / 2))
            return
        end
        local pos = window.AbsolutePosition
        local x = math.clamp(pos.X, 0, math.max(0, vp.X - size.X))
        local y = math.clamp(pos.Y, 0, math.max(0, vp.Y - size.Y))
        if x ~= pos.X or y ~= pos.Y then window.Position = UDim2.fromOffset(x, y) end
    end

    local top = create("Frame", {Size=UDim2.new(1, 0, 0, 53), BackgroundColor3=C.base, BorderSizePixel=0, Active=true}, window)
    local title = textLabel(top, "SPECTRA", 16, C.white, true)
    title.Position = UDim2.fromOffset(21, 11); title.Size = UDim2.fromOffset(130, 22)
    local sub = textLabel(top, "PLAYER VISUALS  /  " .. VERSION, 10, C.muted)
    sub.Position = UDim2.fromOffset(110, 12); sub.Size = UDim2.fromOffset(220, 22)
    local hideButton = create("TextButton", {Text="Hide", Font=Enum.Font.GothamMedium, TextSize=11, TextColor3=C.muted,
        BackgroundColor3=C.panel, Size=UDim2.fromOffset(56, 26), Position=UDim2.new(1, -166, 0, 13), BorderSizePixel=0}, top)
    round(hideButton, 5)
    connect(hideButton.MouseButton1Click, function() window.Visible = false end)
    local unloadButton = create("TextButton", {Text="Unload", Font=Enum.Font.GothamMedium, TextSize=11, TextColor3=C.white,
        BackgroundColor3=C.panel2, Size=UDim2.fromOffset(88, 26), Position=UDim2.new(1, -103, 0, 13), BorderSizePixel=0}, top)
    round(unloadButton, 5)
    connect(unloadButton.MouseButton1Click, shutdown)
    create("Frame", {BackgroundColor3=C.border, BorderSizePixel=0, Size=UDim2.new(1, 0, 0, 1), Position=UDim2.fromOffset(0, 53)}, window)
    local left = create("Frame", {Position=UDim2.fromOffset(0, 54), Size=UDim2.new(0, 145, 1, -54), BackgroundColor3=C.sidebar, BorderSizePixel=0}, window)
    create("Frame", {BackgroundColor3=C.border, BorderSizePixel=0, Size=UDim2.new(0, 1, 1, 0), Position=UDim2.new(1, -1, 0, 0)}, left)
    local content = create("Frame", {Position=UDim2.fromOffset(145, 54), Size=UDim2.new(1, -145, 1, -54), BackgroundTransparency=1, BorderSizePixel=0}, window)
    local footer = create("Frame", {BackgroundColor3=C.base, BorderSizePixel=0, Position=UDim2.new(0, 145, 1, -32), Size=UDim2.new(1, -145, 0, 32)}, window)
    create("Frame", {BackgroundColor3=C.border, BorderSizePixel=0, Size=UDim2.new(1, 0, 0, 1)}, footer)
    statusText = textLabel(footer, "Initializing...", 10, C.muted)
    statusText.Position = UDim2.fromOffset(17, 4); statusText.Size = UDim2.new(1, -34, 1, -8)

    local pages, tabButtons = {}, {}
    local TAB_ORDER = {"Players", "Visuals", "Assist", "Settings", "Debug"}
    for index, name in ipairs(TAB_ORDER) do
        local b = create("TextButton", {
            Text=name, TextSize=12, Font=Enum.Font.GothamMedium, TextColor3=C.muted, TextXAlignment=Enum.TextXAlignment.Left,
            BackgroundColor3=C.sidebar, Size=UDim2.fromOffset(123, 35), Position=UDim2.fromOffset(11, 18 + (index - 1) * 42), BorderSizePixel=0,
        }, left)
        create("UIPadding", {PaddingLeft=UDim.new(0, 11)}, b)
        round(b, 5)
        tabButtons[name] = b
        pages[name] = create("ScrollingFrame", {
            Name=name .. "Page", Size=UDim2.new(1, 0, 1, -32), BackgroundTransparency=1, BorderSizePixel=0,
            ScrollBarThickness=3, ScrollBarImageColor3=C.border, CanvasSize=UDim2.fromOffset(0, 0),
            AutomaticCanvasSize=Enum.AutomaticSize.Y, ScrollingDirection=Enum.ScrollingDirection.Y, Visible=false,
        }, content)
        create("UIPadding", {PaddingTop=UDim.new(0, 18), PaddingLeft=UDim.new(0, 18), PaddingRight=UDim.new(0, 22), PaddingBottom=UDim.new(0, 18)}, pages[name])
        create("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0, 8)}, pages[name])
    end
    tabs = pages
    local function selectTab(name)
        if not pages[name] then return false end
        for key, page in pairs(pages) do
            local selected = key == name
            page.Visible = selected
            tabButtons[key].BackgroundColor3 = selected and C.panel2 or C.sidebar
            tabButtons[key].TextColor3 = selected and C.accent or C.muted
        end
        return true
    end
    for name, b in pairs(tabButtons) do connect(b.MouseButton1Click, function() selectTab(name) end) end

    -- Widget builders (layout order is assigned so UIListLayout keeps creation order).
    local order = 0
    local function nextOrder() order += 1; return order end
    local function header(page, name, description)
        local f = create("Frame", {Size=UDim2.new(1, -3, 0, 53), BackgroundTransparency=1, BorderSizePixel=0, LayoutOrder=nextOrder()}, page)
        local h = textLabel(f, name, 16, C.white, true); h.Size = UDim2.new(1, 0, 0, 23)
        local d = textLabel(f, description, 10, C.muted); d.Position = UDim2.fromOffset(0, 24); d.Size = UDim2.new(1, 0, 0, 17)
    end
    local function groupLabel(page, text)
        local f = create("Frame", {Size=UDim2.new(1, -3, 0, 22), BackgroundTransparency=1, LayoutOrder=nextOrder()}, page)
        local t = textLabel(f, text, 10, C.muted, true)
        t.Size = UDim2.new(1, 0, 1, 0)
    end
    local function row(page, name, description)
        local f = create("Frame", {Size=UDim2.new(1, -3, 0, 51), BackgroundColor3=C.panel, BorderSizePixel=0, LayoutOrder=nextOrder()}, page)
        round(f, 6)
        local t = textLabel(f, name, 12, C.white, true); t.Position = UDim2.fromOffset(13, 6); t.Size = UDim2.new(1, -105, 0, 19)
        local d = textLabel(f, description, 10, C.muted); d.Position = UDim2.fromOffset(13, 25); d.Size = UDim2.new(1, -100, 0, 17)
        return f
    end
    local function toggle(page, label, help, key)
        local f = row(page, label, help)
        local track = create("TextButton", {Text="", BackgroundColor3=C.border, BorderSizePixel=0,
            Size=UDim2.fromOffset(38, 20), Position=UDim2.new(1, -52, 0, 15)}, f)
        round(track, 10)
        local knob = create("Frame", {Size=UDim2.fromOffset(14, 14), Position=UDim2.fromOffset(3, 3), BackgroundColor3=C.white, BorderSizePixel=0}, track)
        round(knob, 8)
        local function refresh()
            track.BackgroundColor3 = state[key] and C.accent or C.border
            knob.Position = state[key] and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
        end
        connect(track.MouseButton1Click, function()
            state[key] = not state[key]
            refresh()
            log("INFO", label .. " = " .. tostring(state[key]))
        end)
        toggleRefreshers[#toggleRefreshers + 1] = refresh
        refresh()
    end
    local function action(page, label, callback)
        local b = create("TextButton", {Text=label, Font=Enum.Font.GothamMedium, TextSize=12, TextColor3=C.white,
            BackgroundColor3=C.panel2, BorderSizePixel=0, Size=UDim2.new(1, -3, 0, 34), LayoutOrder=nextOrder()}, page)
        round(b, 5)
        connect(b.MouseButton1Click, function() safeCall(label, callback) end)
        return b
    end
    local function settingSlider(page, description, key)
        local spec = SCHEMA[key]
        local f = create("Frame", {Size=UDim2.new(1, -3, 0, 77), BackgroundColor3=C.panel, BorderSizePixel=0, LayoutOrder=nextOrder()}, page)
        round(f, 6)
        local caption = textLabel(f, spec.label, 12, C.white, true)
        caption.Position = UDim2.fromOffset(13, 6); caption.Size = UDim2.new(1, -115, 0, 19)
        local hint = textLabel(f, description, 10, C.muted)
        hint.Position = UDim2.fromOffset(13, 26); hint.Size = UDim2.new(1, -26, 0, 15)
        local valueText = textLabel(f, "", 11, C.accent, true)
        valueText.Position = UDim2.new(1, -99, 0, 7); valueText.Size = UDim2.fromOffset(85, 18)
        valueText.TextXAlignment = Enum.TextXAlignment.Right
        local rail = create("Frame", {Position=UDim2.new(0, 14, 1, -20), Size=UDim2.new(1, -28, 0, 5), BackgroundColor3=C.border, BorderSizePixel=0}, f)
        round(rail, 3)
        local fill = create("Frame", {Size=UDim2.fromScale(0, 1), BackgroundColor3=C.accent, BorderSizePixel=0}, rail)
        round(fill, 3)
        local hitbox = create("TextButton", {Text="", BackgroundTransparency=1, Position=UDim2.new(0, 8, 1, -30), Size=UDim2.new(1, -16, 0, 27), BorderSizePixel=0}, f)
        local dragging = false
        local function refresh()
            local value = state[key]
            fill.Size = UDim2.fromScale(math.clamp((value - spec.min) / (spec.max - spec.min), 0, 1), 1)
            valueText.Text = tostring(value) .. (spec.unit or "")
        end
        local function adjust(x)
            local width = math.max(1, rail.AbsoluteSize.X)
            local fraction = math.clamp((x - rail.AbsolutePosition.X) / width, 0, 1)
            local _, clean = Shared.validate(key, spec.min + (spec.max - spec.min) * fraction)
            state[key] = clean
            refresh()
        end
        connect(hitbox.InputBegan, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                adjust(input.Position.X)
            end
        end)
        connect(UserInputService.InputChanged, function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                adjust(input.Position.X)
            end
        end)
        connect(UserInputService.InputEnded, function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
                dragging = false
                log("INFO", spec.label .. " = " .. tostring(state[key]))
            end
        end)
        toggleRefreshers[#toggleRefreshers + 1] = refresh
        refresh()
    end
    local function liveText(page, height)
        local panel = create("Frame", {Size=UDim2.new(1, -3, 0, height), BackgroundColor3=C.panel, BorderSizePixel=0, LayoutOrder=nextOrder()}, page)
        round(panel, 6)
        return create("TextLabel", {
            Position=UDim2.fromOffset(10, 8), Size=UDim2.new(1, -20, 1, -16), BackgroundTransparency=1, Text="",
            TextWrapped=true, TextYAlignment=Enum.TextYAlignment.Top, TextXAlignment=Enum.TextXAlignment.Left,
            TextSize=10, Font=Enum.Font.Code, TextColor3=C.white, BorderSizePixel=0,
        }, panel)
    end

    -- Players ------------------------------------------------------------------
    local playersPage = pages.Players
    header(playersPage, "Players", "Live diagnostics from the experience's own Players and Teams")
    groupLabel(playersPage, "SUMMARY")
    local playerSummary = liveText(playersPage, 52)
    groupLabel(playersPage, "ROSTER  (name · team · relation · health · distance)")
    local rosterText = liveText(playersPage, 230)
    action(playersPage, "Copy diagnostic report", exportReport)

    -- Visuals -------------------------------------------------------------------
    local visualsPage = pages.Visuals
    header(visualsPage, "Visuals", "Highlights and tags. Opponents are only outlined in line of sight")
    groupLabel(visualsPage, "HIGHLIGHTS")
    toggle(visualsPage, SCHEMA.highlights.label, "Master switch for player outlines", "highlights")
    toggle(visualsPage, SCHEMA.teammates.label, "Squad outline, visible through walls", "teammates")
    toggle(visualsPage, SCHEMA.opponents.label, "Occluded depth: hidden behind geometry", "opponents")
    toggle(visualsPage, SCHEMA.teamColors.label, "Color by Team; otherwise accent/green", "teamColors")
    settingSlider(visualsPage, "Higher is more see-through", "fillTransparency")
    groupLabel(visualsPage, "TAGS")
    toggle(visualsPage, SCHEMA.nameTags.label, "Display name and team above heads", "nameTags")
    toggle(visualsPage, SCHEMA.distances.label, "Append distance in studs", "distances")
    settingSlider(visualsPage, "Tags beyond this distance are hidden", "maxDistance")

    -- Assist -----------------------------------------------------------------------
    local assistPage = pages.Assist
    header(assistPage, "Aim-Assist Demo", "Developer demonstration: slowdown over visible opponents, no camera pull")
    groupLabel(assistPage, "ASSIST")
    toggle(assistPage, SCHEMA.assistEnabled.label, "Also requires the server master switch", "assistEnabled")
    settingSlider(assistPage, "How much mouse sensitivity drops over a target", "assistStrength")
    settingSlider(assistPage, "Screen-space radius around the reticle", "assistRadius")
    toggle(assistPage, SCHEMA.assistRingVisible.label, "Draw the assist radius around the reticle", "assistRingVisible")
    groupLabel(assistPage, "STATUS")
    local assistStatus = liveText(assistPage, 70)

    -- Settings ------------------------------------------------------------------------
    local settingsPage = pages.Settings
    header(settingsPage, "Settings", "Interface preferences, saved per user with DataStoreService")
    groupLabel(settingsPage, "APPEARANCE")
    local colorButton
    colorButton = action(settingsPage, "Accent color: Cyan  (click to cycle)", function()
        local options = SCHEMA.color.options
        local n = 1
        for i, v in ipairs(options) do if v == state.color then n = i % #options + 1; break end end
        state.color = options[n]
        colorButton.Text = "Accent color: " .. state.color .. "  (click to cycle)"
        log("INFO", "Accent color: " .. state.color)
    end)
    toggleRefreshers[#toggleRefreshers + 1] = function()
        colorButton.Text = "Accent color: " .. state.color .. "  (click to cycle)"
    end
    groupLabel(settingsPage, "CONFIGURATION")
    action(settingsPage, "Save settings", saveSettings)
    action(settingsPage, "Reload saved settings", loadSettings)
    action(settingsPage, "Reset to defaults", resetSettings)
    groupLabel(settingsPage, "KEYBINDS")
    row(settingsPage, "Right Shift", "Show or hide the menu")
    row(settingsPage, "F8", "Open the command center")
    row(settingsPage, "Home", "Recenter the menu if it moves off-screen")
    row(settingsPage, "Ctrl + End", "Unload SPECTRA for this session")
    groupLabel(settingsPage, "CONTROL")
    action(settingsPage, "Center menu on screen", function() clampWindow(true); log("INFO", "Menu recentered") end)
    action(settingsPage, "Unload SPECTRA completely", shutdown)

    -- Debug / Command Center -------------------------------------------------------------
    local debugPage = pages.Debug
    header(debugPage, "Command Center", "Inspect, configure and troubleshoot SPECTRA · logs limited to 140 entries")
    debugSummary = textLabel(debugPage, "", 11, C.muted)
    debugSummary.Size = UDim2.new(1, -3, 0, 39); debugSummary.TextWrapped = true
    debugSummary.TextYAlignment = Enum.TextYAlignment.Top; debugSummary.LayoutOrder = nextOrder()
    local buttons = create("Frame", {Size=UDim2.new(1, -3, 0, 32), BackgroundTransparency=1, LayoutOrder=nextOrder()}, debugPage)
    local function debugButton(text, x, callback)
        local b = create("TextButton", {Text=text, TextSize=11, Font=Enum.Font.GothamMedium, TextColor3=C.white,
            BackgroundColor3=C.panel2, BorderSizePixel=0, Position=UDim2.new(x, 0, 0, 0), Size=UDim2.new(0.32, -3, 1, 0)}, buttons)
        round(b, 5)
        connect(b.MouseButton1Click, function() safeCall(text, callback) end)
    end
    local runCommand -- forward declaration
    debugButton("Run diagnose", 0, function() runCommand("diagnose") end)
    debugButton("Copy report", 0.335, exportReport)
    debugButton("Clear logs", 0.67, function() table.clear(logs); if logBox then logBox.Text = "" end end)

    local cmdRow = create("Frame", {Size=UDim2.new(1, -3, 0, 32), BackgroundTransparency=1, LayoutOrder=nextOrder()}, debugPage)
    local cmd = create("TextBox", {Text="", PlaceholderText="Type a command (help) · Up/Down for history", ClearTextOnFocus=false,
        Font=Enum.Font.Code, TextSize=11, TextColor3=C.white, PlaceholderColor3=C.muted, TextXAlignment=Enum.TextXAlignment.Left,
        BackgroundColor3=C.panel, BorderSizePixel=0, Size=UDim2.new(1, -70, 1, 0)}, cmdRow)
    round(cmd, 5)
    create("UIPadding", {PaddingLeft=UDim.new(0, 9)}, cmd)
    local run = create("TextButton", {Text="Run", Font=Enum.Font.GothamMedium, TextSize=11, TextColor3=C.white,
        BackgroundColor3=C.panel2, BorderSizePixel=0, Size=UDim2.fromOffset(64, 32), Position=UDim2.new(1, -64, 0, 0)}, cmdRow)
    round(run, 5)

    local logHeader = create("Frame", {Size=UDim2.new(1, -3, 0, 24), BackgroundTransparency=1, LayoutOrder=nextOrder()}, debugPage)
    local logTitle = textLabel(logHeader, "EVENT LOG", 10, C.muted, true)
    logTitle.Size = UDim2.new(1, -112, 1, 0)
    local copyLogButton = create("TextButton", {Text="COPY FULL LOG", TextSize=10, Font=Enum.Font.GothamMedium, TextColor3=C.white,
        BackgroundColor3=C.panel2, BorderSizePixel=0, Size=UDim2.fromOffset(108, 22), Position=UDim2.new(1, -108, 0, 1)}, logHeader)
    round(copyLogButton, 5)
    connect(copyLogButton.MouseButton1Click, function() safeCall("Copy full log", copyFullLog) end)
    local logPanel = create("Frame", {Size=UDim2.new(1, -3, 0, 210), BackgroundColor3=C.panel, BorderSizePixel=0, LayoutOrder=nextOrder()}, debugPage)
    round(logPanel, 6)
    local logScroll = create("ScrollingFrame", {Position=UDim2.fromOffset(8, 8), Size=UDim2.new(1, -16, 1, -16), BackgroundTransparency=1,
        BorderSizePixel=0, ScrollBarThickness=3, CanvasSize=UDim2.fromOffset(0, 0), AutomaticCanvasSize=Enum.AutomaticSize.Y}, logPanel)
    logBox = create("TextBox", {BackgroundTransparency=1, ClearTextOnFocus=false, MultiLine=true, TextEditable=false,
        Font=Enum.Font.Code, TextSize=11, TextColor3=C.white, TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top,
        TextWrapped=true, Text=table.concat(logs, "\n"), Size=UDim2.new(1, -4, 0, 0), AutomaticSize=Enum.AutomaticSize.Y, BorderSizePixel=0}, logScroll)
    groupLabel(debugPage, "CONSOLE QUICK REFERENCE")
    row(debugPage, "Menu settings", "settings · get assistRadius · set radius 120 · toggle tags")
    row(debugPage, "Navigation", "tab Players · tab Visuals · tab Assist · tab Settings · tab Debug")
    row(debugPage, "Config", "save · load · resetsettings")
    row(debugPage, "Troubleshooting", "diagnose · players · team · assiststatus · copylogs")

    -- Copy dialog (shared by COPY FULL LOG, Copy report, copylogs) ----------------------
    copyDialog = create("Frame", {Name="CopyDialog", Visible=false, BackgroundColor3=C.base, BorderSizePixel=0,
        Size=UDim2.new(1, -40, 1, -40), Position=UDim2.fromOffset(20, 20), ZIndex=20, Active=true}, window)
    round(copyDialog, 8); outline(copyDialog, C.accent, 0.4)
    copyTitle = textLabel(copyDialog, "", 11, C.white, true)
    copyTitle.Position = UDim2.fromOffset(14, 8); copyTitle.Size = UDim2.new(1, -110, 0, 22); copyTitle.ZIndex = 21
    local closeCopy = create("TextButton", {Text="Close", Font=Enum.Font.GothamMedium, TextSize=11, TextColor3=C.white, ZIndex=21,
        BackgroundColor3=C.panel2, BorderSizePixel=0, Size=UDim2.fromOffset(72, 24), Position=UDim2.new(1, -84, 0, 7)}, copyDialog)
    round(closeCopy, 5)
    local copyScroll = create("ScrollingFrame", {Position=UDim2.fromOffset(10, 38), Size=UDim2.new(1, -20, 1, -48), BackgroundColor3=C.panel,
        BorderSizePixel=0, ScrollBarThickness=3, CanvasSize=UDim2.fromOffset(0, 0), AutomaticCanvasSize=Enum.AutomaticSize.Y, ZIndex=21}, copyDialog)
    round(copyScroll, 6)
    copyBox = create("TextBox", {BackgroundTransparency=1, ClearTextOnFocus=false, MultiLine=true, TextEditable=true, ZIndex=22,
        Font=Enum.Font.Code, TextSize=11, TextColor3=C.white, TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top,
        TextWrapped=true, Text="", Size=UDim2.new(1, -8, 0, 0), Position=UDim2.fromOffset(4, 4), AutomaticSize=Enum.AutomaticSize.Y, BorderSizePixel=0}, copyScroll)
    local function closeCopyDialog()
        copyDialog.Visible = false
        if copyBox:IsFocused() then copyBox:ReleaseFocus() end
    end
    connect(closeCopy.MouseButton1Click, closeCopyDialog)

    -- Command center ---------------------------------------------------------------------
    local aliases = {
        highlight="highlights", outlines="highlights", team="teammates", allies="teammates",
        enemies="opponents", tags="nameTags", names="nameTags", distance="distances",
        range="maxDistance", fill="fillTransparency", assist="assistEnabled", aimassist="assistEnabled",
        strength="assistStrength", radius="assistRadius", fov="assistRadius", ring="assistRingVisible",
        colors="teamColors", accent="color",
    }
    local function resolveKey(raw)
        local needle = tostring(raw or ""):lower():gsub("[^%w]", "")
        for key in pairs(SCHEMA) do
            if key:lower() == needle then return key end
        end
        return aliases[needle]
    end
    local function parseValue(key, text)
        local spec = SCHEMA[key]
        text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if spec.kind == "boolean" then
            local lower = text:lower()
            if lower == "on" or lower == "true" or lower == "1" or lower == "yes" then return true end
            if lower == "off" or lower == "false" or lower == "0" or lower == "no" then return false end
            return nil
        elseif spec.kind == "number" then
            return tonumber((text:gsub("[^%d%.%-]", "")))
        elseif spec.kind == "enum" then
            for _, option in ipairs(spec.options) do
                if option:lower() == text:lower() then return option end
            end
        end
        return nil
    end
    local function settingsList()
        local keys = {}
        for key in pairs(SCHEMA) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local spec = SCHEMA[key]
            local range = spec.kind == "number" and string.format(" [%s..%s]", spec.min, spec.max)
                or spec.kind == "enum" and (" [" .. table.concat(spec.options, "/") .. "]") or " [on/off]"
            log("INFO", key .. " = " .. tostring(state[key]) .. range)
        end
    end
    runCommand = function(raw)
        local input = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if input == "" then return end
        if #input > 220 then log("WARN", "Command exceeds 220 characters"); return end
        if commandHistory[#commandHistory] ~= input then
            commandHistory[#commandHistory + 1] = input
            if #commandHistory > 40 then table.remove(commandHistory, 1) end
        end
        commandHistoryCursor = #commandHistory + 1
        log("INFO", "> " .. input)
        local verb, tail = input:match("^(%S+)%s*(.-)%s*$")
        verb = (verb or ""):lower()
        if verb == "help" then
            log("INFO", "-- CONSOLE COMMAND CENTER / v" .. VERSION .. " --")
            log("INFO", "settings | get KEY | set KEY VALUE | toggle KEY")
            log("INFO", "save | load | resetsettings")
            log("INFO", "tab Players/Visuals/Assist/Settings/Debug")
            log("INFO", "diagnose | status | players | team | assiststatus")
            log("INFO", "copyreport | copylogs | find TEXT | history")
            log("INFO", "recenter | highlights on/off | assist on/off | clear | unload")
            log("INFO", "Examples: set radius 120 ; toggle tags ; set color Lime")
        elseif verb == "settings" then
            settingsList()
        elseif verb == "get" then
            local key = resolveKey(tail)
            if not key then log("WARN", "Unknown setting: " .. tail); return end
            log("INFO", key .. " = " .. tostring(state[key]))
        elseif verb == "set" then
            local name, value = tail:match("^(%S+)%s+(.+)$")
            local key = resolveKey(name)
            if not key then log("WARN", "Usage: set KEY VALUE (see settings)"); return end
            local parsed = parseValue(key, value)
            local ok, clean = Shared.validate(key, parsed)
            if parsed == nil or not ok then log("WARN", "Invalid value for " .. key .. ": " .. tostring(value)); return end
            state[key] = clean
            refreshAllToggles()
            log("INFO", key .. " = " .. tostring(clean))
        elseif verb == "toggle" then
            local key = resolveKey(tail)
            if not key or SCHEMA[key].kind ~= "boolean" then log("WARN", "toggle needs an on/off setting"); return end
            state[key] = not state[key]
            refreshAllToggles()
            log("INFO", key .. " = " .. tostring(state[key]))
        elseif verb == "highlights" or verb == "assist" or verb == "tags" then
            local key = resolveKey(verb)
            local parsed = parseValue(key, tail)
            if parsed == nil then parsed = not state[key] end
            state[key] = parsed
            refreshAllToggles()
            log("INFO", key .. " = " .. tostring(parsed))
        elseif verb == "save" then saveSettings()
        elseif verb == "load" then loadSettings()
        elseif verb == "resetsettings" then resetSettings()
        elseif verb == "tab" then
            local wanted
            for name in pairs(pages) do if name:lower() == tail:lower() then wanted = name end end
            if not wanted or not selectTab(wanted) then log("WARN", "Unknown tab: " .. tail) end
        elseif verb == "diagnose" or verb == "healthcheck" then
            local stages = {}
            local function stage(label, fn)
                local ok, err = pcall(fn)
                stages[#stages + 1] = label .. ": " .. (ok and "OK" or ("ERROR " .. tostring(err)))
            end
            stage("Marker update", updateMarkers)
            stage("Config remote", function() assert(configRemote and configRemote.Parent, "missing") end)
            stage("Camera", function() assert(Workspace.CurrentCamera, "no CurrentCamera") end)
            stage("Character", function() assert(LocalPlayer.Character, "no character spawned") end)
            for _, line in ipairs(stages) do log("INFO", line) end
            showCopyDialog("Diagnostics bundle", table.concat(stages, "\n") .. "\n\n" .. report())
        elseif verb == "status" then
            log("INFO", statusText and statusText.Text or "no status")
        elseif verb == "players" then
            for _, line in ipairs(playerLines()) do log("INFO", line) end
        elseif verb == "team" then
            if not hasTeams() then
                log("INFO", "No Teams in this experience: everyone else is an opponent")
            else
                log("INFO", "You: " .. (LocalPlayer.Team and LocalPlayer.Team.Name or "no team") .. (LocalPlayer.Neutral and " (neutral)" or ""))
                for _, team in ipairs(Teams:GetTeams()) do
                    log("INFO", string.format("%s: %d players, AutoAssignable %s", team.Name, #team:GetPlayers(), tostring(team.AutoAssignable)))
                end
            end
        elseif verb == "assiststatus" then
            log("INFO", assistStatus.Text:gsub("\n", " | "))
        elseif verb == "copyreport" then exportReport()
        elseif verb == "copylogs" then copyFullLog()
        elseif verb == "find" then
            local needle = tail:lower()
            if needle == "" then log("WARN", "Usage: find TEXT"); return end
            local hits = 0
            for _, entry in ipairs(table.clone(logs)) do
                if entry:lower():find(needle, 1, true) and not entry:find("> find", 1, true) then
                    hits += 1
                    log("INFO", "  " .. entry)
                end
            end
            log("INFO", hits .. " matching entries")
        elseif verb == "history" then
            for i, entry in ipairs(commandHistory) do log("INFO", i .. ". " .. entry) end
        elseif verb == "recenter" then clampWindow(true)
        elseif verb == "clear" then
            table.clear(logs)
            if logBox then logBox.Text = "" end
        elseif verb == "unload" then shutdown()
        else
            log("WARN", "Unknown command: " .. input .. " (type help)")
        end
    end
    local function submitCommand()
        local raw = cmd.Text
        cmd.Text = ""
        safeCall("Console command", runCommand, raw)
    end
    connect(run.MouseButton1Click, submitCommand)
    connect(cmd.FocusLost, function(enterPressed)
        if enterPressed then submitCommand() end
    end)
    connect(UserInputService.InputBegan, function(input)
        if not cmd:IsFocused() then return end
        if input.KeyCode == Enum.KeyCode.Up then
            commandHistoryCursor = math.max(1, commandHistoryCursor - 1)
            cmd.Text = commandHistory[commandHistoryCursor] or cmd.Text
            cmd.CursorPosition = #cmd.Text + 1
        elseif input.KeyCode == Enum.KeyCode.Down then
            commandHistoryCursor = math.min(#commandHistory + 1, commandHistoryCursor + 1)
            cmd.Text = commandHistory[commandHistoryCursor] or ""
            cmd.CursorPosition = #cmd.Text + 1
        end
    end)

    -- Drag, keybinds, loops ---------------------------------------------------------------
    local dragging, dragStart, windowStart = false, nil, nil
    connect(top.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; windowStart = window.Position
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            window.Position = UDim2.new(windowStart.X.Scale, windowStart.X.Offset + d.X, windowStart.Y.Scale, windowStart.Y.Offset + d.Y)
            clampWindow(false)
        end
    end)
    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    connect(UserInputService.InputBegan, function(input, gameProcessed)
        if input.KeyCode == Enum.KeyCode.Escape and copyDialog.Visible then closeCopyDialog(); return end
        if gameProcessed or UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode == Enum.KeyCode.End and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
            shutdown()
        elseif input.KeyCode == Enum.KeyCode.RightShift then
            window.Visible = not window.Visible
            if window.Visible then clampWindow(false) end
        elseif input.KeyCode == Enum.KeyCode.Home then
            clampWindow(true)
        elseif input.KeyCode == Enum.KeyCode.F8 then
            window.Visible = true; selectTab("Debug"); clampWindow(false)
        end
    end)
    connect(Players.PlayerAdded, function(p) log("INFO", "Player joined: " .. p.Name) end)
    connect(Players.PlayerRemoving, function(p) destroyMarker(p); log("INFO", "Player left: " .. p.Name) end)
    connect(LocalPlayer:GetPropertyChangedSignal("Team"), function()
        log("INFO", "Your team: " .. (LocalPlayer.Team and LocalPlayer.Team.Name or "none"))
    end)
    connect(Workspace:GetAttributeChangedSignal(Shared.ASSIST_ATTRIBUTE), function()
        log("INFO", "Server aim-assist switch: " .. tostring(Workspace:GetAttribute(Shared.ASSIST_ATTRIBUTE)))
    end)
    connect(LocalPlayer:GetAttributeChangedSignal(Shared.AUTH_ATTRIBUTE), function()
        if LocalPlayer:GetAttribute(Shared.AUTH_ATTRIBUTE) ~= true then
            log("WARN", "Authorization revoked by server")
            shutdown()
        end
    end)

    local markerAccumulator, statAccumulator = 1, 1
    connect(RunService.RenderStepped, function(dt)
        if not alive then return end
        stats.fps = stats.fps == 0 and (1 / math.max(0.001, dt)) or (stats.fps * 0.92 + (1 / math.max(0.001, dt)) * 0.08)
        local ok, err = pcall(updateAssist)
        if not ok then
            assist.lastError = tostring(err)
            releaseAssist()
        end
        markerAccumulator += dt
        statAccumulator += dt
        if markerAccumulator >= 0.1 then
            markerAccumulator = 0
            safeCall("Markers", updateMarkers)
        end
        if statAccumulator >= 0.5 then
            statAccumulator = 0
            if statusText and statusText.Parent then
                statusText.Text = string.format("v%s · %d teammates · %d opponents · %d highlighted · %d FPS%s",
                    VERSION, stats.teammates, stats.opponents, stats.highlighted, math.floor(stats.fps + 0.5),
                    persisted and "" or " · unsaved")
            end
            playerSummary.Text = string.format("Teams: %s\nYou: %s  ·  %d teammates · %d opponents · %d neutral",
                hasTeams() and tostring(#Teams:GetTeams()) or "none (free-for-all)",
                LocalPlayer.Team and LocalPlayer.Team.Name or "no team",
                stats.teammates, stats.opponents, stats.neutral)
            rosterText.Text = table.concat(playerLines(), "\n")
            assistStatus.Text = string.format("Setting: %s  ·  server switch: %s\nSensitivity write: %s  ·  %s\n%s",
                state.assistEnabled and "ON" or "OFF",
                Workspace:GetAttribute(Shared.ASSIST_ATTRIBUTE) and "ON" or "OFF",
                assist.supported == nil and "not yet tested" or (assist.supported and "supported" or "BLOCKED"),
                assist.active and ("engaged on " .. (assist.target and assist.target.Name or "?")) or "idle",
                assist.lastError and ("Last error: " .. assist.lastError) or "Menu must be hidden for assist to run")
            if debugSummary and debugSummary.Parent then
                debugSummary.Text = string.format("%d players · %d highlights · %d tags · %d connections\nConfig %s",
                    #Players:GetPlayers(), stats.highlighted, stats.tagged, #connections,
                    persisted and "saved in DataStore" or "session-only (not saved)")
            end
            clampWindow(false)
        end
    end)

    selectTab("Players")
    clampWindow(true)
end

-- Startup ------------------------------------------------------------------------------
local remotes = ReplicatedStorage:WaitForChild(Shared.REMOTE_FOLDER, 10)
configRemote = remotes and remotes:WaitForChild("Config", 5)
local startOk, startError = pcall(launchSpectraUI)
if not startOk then
    warn("[SPECTRA] Startup failure: " .. tostring(startError))
    shutdown()
    return
end
log("INFO", "SPECTRA " .. VERSION .. " loaded (Studio edition). RShift menu · F8 command center")
if not configRemote then log("WARN", "SpectraRemotes.Config not found; settings are session-only") end
task.spawn(loadSettings)
