----------------------------------------------------------------------
-- Helpers & services
----------------------------------------------------------------------

-- Use cloneref when the executor has it, otherwise return the object as is
local safeClone = (type(cloneref) == "function") and cloneref or function(...)
    return ...
end

local Services = setmetatable({}, {
    __index = function(_, name)
        return safeClone(game:GetService(name))
    end,
})

local Players = Services.Players
local RunService = Services.RunService
local UserInputService = Services.UserInputService
local TweenService = Services.TweenService
local AvatarEditorService = Services.AvatarEditorService
local HttpService = Services.HttpService
local CoreGui = Services.CoreGui

local viewport = workspace.CurrentCamera.ViewportSize

-- Scales a pixel size designed for 1920x1080 to the current screen
local function scale(axis, value)
    local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    local boost = isMobile and 2 or 1.5
    if axis == "X" then
        return value * (viewport.X / 1920) * boost
    elseif axis == "Y" then
        return value * (viewport.Y / 1080) * boost
    end
end

----------------------------------------------------------------------
-- Player / character state
----------------------------------------------------------------------

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local isR6 = humanoid.RigType == Enum.HumanoidRigType.R6
local lastPosition = character.PrimaryPart and character.PrimaryPart.Position or Vector3.new()

-- UI references that need to be updated when the character respawns
local titleLabel, catalogTab, savedTab, catalogPage, savedPage

player.CharacterAdded:Connect(function(newCharacter)
    character = newCharacter
    humanoid = newCharacter:WaitForChild("Humanoid")
    isR6 = humanoid.RigType == Enum.HumanoidRigType.R6

    if titleLabel then
        titleLabel.Text = isR6 and "Asuka Emotes (R6)" or "Asuka Emotes"
    end
    if catalogTab then
        catalogTab.Text = isR6 and "Animation" or "Catalog"
    end
    if savedTab then
        savedTab.Visible = not isR6
    end

    -- R6 has no catalog emotes: force the catalog page and reset tab colors
    if isR6 and catalogPage and savedPage then
        catalogPage.Visible = true
        savedPage.Visible = false
        catalogTab.BackgroundColor3 = Color3.fromRGB(30, 30, 80)
        savedTab.BackgroundColor3 = Color3.fromRGB(20, 50, 20)
    end

    lastPosition = character.PrimaryPart and character.PrimaryPart.Position or Vector3.new()
end)

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------

local config = {
    ["Stop Emote When Moving"] = true,
    ["Fade In"] = 0.1,
    ["Fade Out"] = 0.1,
    ["Weight"] = 1,
    ["Speed"] = 1,
    ["Time Position"] = 0,
    ["Freeze On Finish"] = false,
    ["Looped"] = true,
    ["Stop Other Animations On Play"] = true,
    ["High Priority"] = true,
    ["Grey Rain"] = true, -- Added Grey Rain setting
}

-- Functions that set a slider / toggle (and update its UI), filled in by addSlider / addToggle
local sliderSetters = {}
local toggleSetters = {}

local function setSlider(name, value)
    local setter = sliderSetters[name]
    if setter then
        setter(value)
    end
end

local function setToggle(name, value)
    local setter = toggleSetters[name]
    if setter then
        config[name] = value
        setter(value)
    end
end

----------------------------------------------------------------------
-- Grey Rain Effect (Client-Side)
----------------------------------------------------------------------

local rainPart = Instance.new("Part")
rainPart.Name = "AsukaGreyRainEmitter"
rainPart.Size = Vector3.new(90, 1, 90)
rainPart.Transparency = 1
rainPart.Anchored = true
rainPart.CanCollide = false
rainPart.CanQuery = false
rainPart.CanTouch = false
rainPart.CastShadow = false
rainPart.Parent = workspace

local rainEmitter = Instance.new("ParticleEmitter")
rainEmitter.Name = "GreyRainParticles"
rainEmitter.Texture = "rbxassetid://241876428" -- Clean rain streak texture
rainEmitter.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(165, 170, 175)), -- Soft light grey
    ColorSequenceKeypoint.new(1, Color3.fromRGB(115, 120, 125)), -- Deeper slate grey
})
rainEmitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.35),
    NumberSequenceKeypoint.new(0.8, 0.45),
    NumberSequenceKeypoint.new(1, 1),
})
rainEmitter.Size = NumberSequence.new(0.18)
rainEmitter.Squash = NumberSequence.new(1.8) -- Stretches droplets into rain streaks
rainEmitter.Lifetime = NumberRange.new(1.2, 1.8)
rainEmitter.Rate = 450
rainEmitter.Speed = NumberRange.new(45, 65)
rainEmitter.EmissionDirection = Enum.NormalId.Bottom
rainEmitter.Acceleration = Vector3.new(0, -35, 0)
rainEmitter.Orientation = Enum.ParticleOrientation.VelocityParallel
rainEmitter.LockedToPart = false
rainEmitter.Enabled = config["Grey Rain"]
rainEmitter.Parent = rainPart

-- Keep the rain cloud centered above the player
RunService.RenderStepped:Connect(function()
    rainEmitter.Enabled = config["Grey Rain"]
    if config["Grey Rain"] and character then
        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if rootPart then
            rainPart.Position = rootPart.Position + Vector3.new(0, 35, 0)
        end
    end
end)

----------------------------------------------------------------------
-- Saved emotes (stored in a JSON file in the executor workspace)
----------------------------------------------------------------------

local SAVE_FILE = "AsukaEmotes_NewNEWN3WSaved.json"
local savedEmotes = {}

local function loadSavedEmotes()
    local ok, result = pcall(function()
        if readfile and isfile and isfile(SAVE_FILE) then
            return HttpService:JSONDecode(readfile(SAVE_FILE))
        end
        return {}
    end)

    if ok and type(result) == "table" then
        savedEmotes = result
    else
        savedEmotes = {}
    end

    -- Make sure every entry has an AnimationId and a Favorite flag
    for _, entry in ipairs(savedEmotes) do
        if not entry.AnimationId then
            if entry.AssetId then
                entry.AnimationId = "rbxassetid://" .. tostring(entry.AssetId)
            else
                entry.AnimationId = "rbxassetid://" .. tostring(entry.Id)
            end
        end
        if entry.Favorite == nil then
            entry.Favorite = false
        end
    end
end

local function saveSavedEmotes()
    pcall(function()
        if writefile then
            writefile(SAVE_FILE, HttpService:JSONEncode(savedEmotes))
        end
    end)
end

loadSavedEmotes()

----------------------------------------------------------------------
-- Playing emotes
----------------------------------------------------------------------

local currentTrack = nil

-- Catalog emotes are often a model that contains an Animation; this finds the real animation id.
function GetReal(assetId)
    local ok, objects = pcall(function()
        return game:GetObjects("rbxassetid://" .. tostring(assetId))
    end)

    if ok and objects and #objects > 0 then
        local first = objects[1]
        if first:IsA("Animation") and first.AnimationId ~= "" then
            return tonumber(first.AnimationId:match("%d+"))
        elseif first:FindFirstChildOfClass("Animation") then
            local animation = first:FindFirstChildOfClass("Animation")
            return tonumber(animation.AnimationId:match("%d+"))
        end
    end
end

local function playEmote(assetId)
    if currentTrack then
        currentTrack:Stop(config["Fade Out"])
    end

    -- Work out the animation id (unwrap it if the asset is a model with an Animation inside)
    local animationId
    local ok, objects = pcall(function()
        return game:GetObjects("rbxassetid://" .. tostring(assetId))
    end)

    if ok and objects and #objects > 0 then
        local first = objects[1]
        if first:IsA("Animation") then
            animationId = first.AnimationId
        else
            animationId = "rbxassetid://" .. tostring(assetId)
        end
    else
        animationId = "rbxassetid://" .. tostring(assetId)
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = animationId

    local track = humanoid:LoadAnimation(animation)
    local priority = config["High Priority"] and Enum.AnimationPriority.Action4 or Enum.AnimationPriority.Action
    track.Priority = priority

    local weight = config["Weight"]
    if weight == 0 then
        weight = 0.001 -- weight 0 would make the animation invisible
    end

    if config["Stop Other Animations On Play"] then
        for _, playing in pairs(humanoid.Animator:GetPlayingAnimationTracks()) do
            if playing.Priority ~= priority then
                playing:Stop()
            end
        end
    end

    track:Play(config["Fade In"], weight, config["Speed"])
    currentTrack = track
    currentTrack.TimePosition = math.clamp(config["Time Position"], 0, 1) * (currentTrack.Length or 1)
    currentTrack.Priority = priority
    currentTrack.Looped = config["Looped"]

    return track
end

-- Every frame: keep looping in sync, and stop the emote when the player moves or jumps
RunService.RenderStepped:Connect(function()
    if config["Looped"] and currentTrack and currentTrack.IsPlaying then
        currentTrack.Looped = config["Looped"]
    end

    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if rootPart then
        if config["Stop Emote When Moving"] and currentTrack and currentTrack.IsPlaying then
            local moved = (rootPart.Position - lastPosition).Magnitude > 0.1
            local jumping = humanoid and humanoid:GetState() == Enum.HumanoidStateType.Jumping
            if moved or jumping then
                currentTrack:Stop(config["Fade Out"])
                currentTrack = nil
            end
        end
        lastPosition = rootPart.Position
    end
end)

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ASUKA EMOTE"
screenGui.Parent = CoreGui
screenGui.Enabled = false
screenGui.DisplayOrder = 999

local function addCorner(object, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 6)
    corner.Parent = object
    return corner
end

local function addStroke(object, color, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or Color3.fromRGB(60, 120, 200)
    stroke.Thickness = thickness or 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = object
    return stroke
end

-- Small "pop in" animation for new cards
local function popIn(object)
    local uiScale = Instance.new("UIScale")
    uiScale.Scale = 0.5
    uiScale.Parent = object
    TweenService:Create(uiScale, TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Creates a TextButton with the common styling used everywhere
local function makeButton(parent, text, color, size, position)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = color
    button.BackgroundTransparency = 0.2
    button.Text = text
    button.Font = Enum.Font.GothamBold
    button.TextScaled = true
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Parent = parent
    addCorner(button, 4)
    return button
end

----------------------------------------------------------------------
-- Main window
----------------------------------------------------------------------

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, scale("X", 470), 0, scale("Y", 450))
mainFrame.Position = UDim2.new(0.5, -scale("X", 325), 0.5, -scale("Y", 225))
mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
mainFrame.BackgroundTransparency = 0.15
mainFrame.Active = true
mainFrame.Draggable = true
mainFrame.Parent = screenGui
addCorner(mainFrame, 8)
addStroke(mainFrame, Color3.fromRGB(80, 80, 120), 1.5)

-- Resize handle (bottom right corner)
local resizeHandle = Instance.new("TextButton")
resizeHandle.Size = UDim2.new(0, 24, 0, 24)
resizeHandle.Position = UDim2.new(1, -24, 1, -24)
resizeHandle.BackgroundTransparency = 1
resizeHandle.Text = "◢"
resizeHandle.TextColor3 = Color3.fromRGB(100, 100, 140)
resizeHandle.TextSize = 18
resizeHandle.ZIndex = 10
resizeHandle.Parent = mainFrame

local isResizing = false
local resizeStartPosition
local resizeStartSize

resizeHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        isResizing = true
        resizeStartPosition = input.Position
        resizeStartSize = mainFrame.AbsoluteSize
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if isResizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - resizeStartPosition
        local newWidth = math.max(150, resizeStartSize.X + delta.X)
        local newHeight = math.max(100, resizeStartSize.Y + delta.Y)
        mainFrame.Size = UDim2.new(0, newWidth, 0, newHeight)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        isResizing = false
    end
end)

-- Title
titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, scale("Y", 36))
titleLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
titleLabel.BackgroundTransparency = 0.5
titleLabel.Text = isR6 and "Asuka Emotes (R6)" or "Asuka Emotes"
titleLabel.TextColor3 = Color3.new(1, 1, 1)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextScaled = true
titleLabel.Parent = mainFrame
addCorner(titleLabel, 8)

-- Tabs
catalogTab = Instance.new("TextButton")
catalogTab.Size = UDim2.new(0.3, 0, 0, scale("Y", 24))
catalogTab.Position = UDim2.new(0.05, 0, 0, scale("Y", 40))
catalogTab.BackgroundColor3 = Color3.fromRGB(30, 30, 80)
catalogTab.BackgroundTransparency = 0.2
catalogTab.Text = isR6 and "Animation" or "Catalog"
catalogTab.TextColor3 = Color3.new(1, 1, 1)
catalogTab.Font = Enum.Font.GothamBold
catalogTab.TextScaled = true
catalogTab.Parent = mainFrame
addCorner(catalogTab, 4)

savedTab = Instance.new("TextButton")
savedTab.Size = UDim2.new(0.3, 0, 0, scale("Y", 24))
savedTab.Position = UDim2.new(0.35, 0, 0, scale("Y", 40))
savedTab.BackgroundColor3 = Color3.fromRGB(30, 80, 30)
savedTab.BackgroundTransparency = 0.2
savedTab.Text = "Saved"
savedTab.TextColor3 = Color3.new(1, 1, 1)
savedTab.Font = Enum.Font.GothamBold
savedTab.TextScaled = true
savedTab.Visible = not isR6
savedTab.Parent = mainFrame
addCorner(savedTab, 4)

-- Thin vertical line between the emote area and the settings panel
local divider = Instance.new("Frame")
divider.Size = UDim2.new(0, scale("X", 2), 1, -scale("Y", 70))
divider.Position = UDim2.new(0.6, -scale("X", 1), 0, scale("Y", 70))
divider.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
divider.BackgroundTransparency = 0.5
divider.Parent = mainFrame

----------------------------------------------------------------------
-- Catalog page (left side, first tab)
----------------------------------------------------------------------

catalogPage = Instance.new("Frame")
catalogPage.Size = UDim2.new(0.6, -scale("X", 10), 1, -scale("Y", 70))
catalogPage.Position = UDim2.new(0, scale("X", 5), 0, scale("Y", 70))
catalogPage.BackgroundTransparency = 1
catalogPage.Visible = true
catalogPage.Parent = mainFrame

local searchBox = Instance.new("TextBox")
searchBox.Size = UDim2.new(0.6, -scale("X", 8), 0, scale("Y", 28))
searchBox.Position = UDim2.new(0, scale("X", 8), 0, 0)
searchBox.PlaceholderText = "Search..."
searchBox.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
searchBox.BackgroundTransparency = 0.3
searchBox.TextColor3 = Color3.new(1, 1, 1)
searchBox.Font = Enum.Font.Gotham
searchBox.TextScaled = true
searchBox.ClearTextOnFocus = false
searchBox.Text = ""
searchBox.Parent = catalogPage
addCorner(searchBox, 4)
addStroke(searchBox, Color3.fromRGB(50, 50, 70), 1)

local refreshButton = makeButton(
    catalogPage, "Refresh", Color3.fromRGB(0, 60, 150),
    UDim2.new(0.2, -scale("X", 4), 0, scale("Y", 28)),
    UDim2.new(0.6, scale("X", 4), 0, 0)
)

local sortButton = makeButton(
    catalogPage, "Sort: Relevance", Color3.fromRGB(40, 40, 80),
    UDim2.new(0.2, -scale("X", 8), 0, scale("Y", 28)),
    UDim2.new(0.8, scale("X", 4), 0, 0)
)

local catalogScroll = Instance.new("ScrollingFrame")
catalogScroll.Size = UDim2.new(1, -scale("X", 16), 1, -scale("Y", 100))
catalogScroll.Position = UDim2.new(0, scale("X", 8), 0, scale("Y", 36))
catalogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
catalogScroll.ScrollBarThickness = 6
catalogScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 140)
catalogScroll.BackgroundTransparency = 1
catalogScroll.Parent = catalogPage

local catalogGrid = Instance.new("UIGridLayout", catalogScroll)
catalogGrid.CellSize = UDim2.new(0, scale("X", 120), 0, scale("Y", 180))
catalogGrid.CellPadding = UDim2.new(0, scale("X", 8), 0, scale("Y", 8))

local catalogEmptyLabel = Instance.new("TextLabel", catalogScroll)
catalogEmptyLabel.Size = UDim2.new(1, 0, 0, scale("Y", 36))
catalogEmptyLabel.Position = UDim2.new(0, 0, 0.5, -scale("Y", 18))
catalogEmptyLabel.BackgroundTransparency = 1
catalogEmptyLabel.Text = "Nothing Silly Here :3 (except me)"
catalogEmptyLabel.TextColor3 = Color3.new(1, 1, 1)
catalogEmptyLabel.Font = Enum.Font.GothamBold
catalogEmptyLabel.TextScaled = true
catalogEmptyLabel.Visible = false

-- Page navigation (bottom of the catalog page)
local prevButton = Instance.new("TextButton", catalogPage)
prevButton.Size = UDim2.new(0.4, -scale("X", 6), 0, scale("Y", 32))
prevButton.Position = UDim2.new(0, scale("X", 4), 1, -scale("Y", 36))
prevButton.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
prevButton.BackgroundTransparency = 0.2
prevButton.Text = "< Prev"
prevButton.Font = Enum.Font.GothamBold
prevButton.TextScaled = true
prevButton.TextColor3 = Color3.new(1, 1, 1)
addCorner(prevButton, 6)

local nextButton = Instance.new("TextButton", catalogPage)
nextButton.Size = UDim2.new(0.4, -scale("X", 6), 0, scale("Y", 32))
nextButton.Position = UDim2.new(0.6, scale("X", 2), 1, -scale("Y", 36))
nextButton.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
nextButton.BackgroundTransparency = 0.2
nextButton.Text = "Next >"
nextButton.Font = Enum.Font.GothamBold
nextButton.TextScaled = true
nextButton.TextColor3 = Color3.new(1, 1, 1)
addCorner(nextButton, 6)

local pageBox = Instance.new("TextBox", catalogPage)
pageBox.Size = UDim2.new(0.2, 0, 0, scale("Y", 32))
pageBox.Position = UDim2.new(0.4, scale("X", 2), 1, -scale("Y", 36))
pageBox.BackgroundTransparency = 1
pageBox.Font = Enum.Font.Gotham
pageBox.TextScaled = true
pageBox.TextColor3 = Color3.new(1, 1, 1)
pageBox.Text = "1 / Enter page"

local pageErrorLabel = Instance.new("TextLabel", catalogPage)
pageErrorLabel.Size = UDim2.new(0.3, 0, 0, scale("Y", 24))
pageErrorLabel.Position = UDim2.new(0.35, 0, 1, -scale("Y", 68))
pageErrorLabel.BackgroundTransparency = 1
pageErrorLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
pageErrorLabel.Font = Enum.Font.Gotham
pageErrorLabel.TextScaled = true
pageErrorLabel.Text = ""
pageErrorLabel.Visible = false

----------------------------------------------------------------------
-- Saved page (left side, second tab)
----------------------------------------------------------------------

savedPage = Instance.new("Frame")
savedPage.Size = UDim2.new(0.6, -scale("X", 10), 1, -scale("Y", 70))
savedPage.Position = UDim2.new(0, scale("X", 5), 0, scale("Y", 70))
savedPage.BackgroundTransparency = 1
savedPage.Visible = false
savedPage.Parent = mainFrame

local savedSearchBox = Instance.new("TextBox")
savedSearchBox.Size = UDim2.new(0.7, -scale("X", 16), 0, scale("Y", 28))
savedSearchBox.Position = UDim2.new(0, scale("X", 8), 0, 0)
savedSearchBox.PlaceholderText = "Search Saved..."
savedSearchBox.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
savedSearchBox.BackgroundTransparency = 0.3
savedSearchBox.TextColor3 = Color3.new(1, 1, 1)
savedSearchBox.Font = Enum.Font.Gotham
savedSearchBox.TextScaled = true
savedSearchBox.ClearTextOnFocus = false
savedSearchBox.Text = ""
savedSearchBox.Parent = savedPage
addCorner(savedSearchBox, 4)
addStroke(savedSearchBox, Color3.fromRGB(50, 50, 70), 1)

local emoteIdBox = Instance.new("TextBox")
emoteIdBox.Size = UDim2.new(0.2, 0, 0, scale("Y", 28))
emoteIdBox.Position = UDim2.new(0.7, -scale("X", 4), 0, 0)
emoteIdBox.PlaceholderText = "Emote ID"
emoteIdBox.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
emoteIdBox.BackgroundTransparency = 0.3
emoteIdBox.TextColor3 = Color3.new(1, 1, 1)
emoteIdBox.Font = Enum.Font.Gotham
emoteIdBox.TextScaled = true
emoteIdBox.ClearTextOnFocus = false
emoteIdBox.Text = ""
emoteIdBox.Parent = savedPage
addCorner(emoteIdBox, 4)
addStroke(emoteIdBox, Color3.fromRGB(50, 50, 70), 1)

local addIdButton = makeButton(
    savedPage, "+", Color3.fromRGB(40, 100, 160),
    UDim2.new(0.1, 0, 0, scale("Y", 28)),
    UDim2.new(0.9, 0, 0, 0)
)

local savedScroll = Instance.new("ScrollingFrame")
savedScroll.Size = UDim2.new(1, -scale("X", 16), 1, -scale("Y", 40))
savedScroll.Position = UDim2.new(0, scale("X", 8), 0, scale("Y", 36))
savedScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
savedScroll.ScrollBarThickness = 0
savedScroll.BackgroundTransparency = 1
savedScroll.Parent = savedPage

local savedEmptyLabel = Instance.new("TextLabel")
savedEmptyLabel.Size = UDim2.new(1, 0, 0, scale("Y", 36))
savedEmptyLabel.Position = UDim2.new(0, 0, 0.5, -scale("Y", 18))
savedEmptyLabel.BackgroundTransparency = 1
savedEmptyLabel.Text = "Sorry I Was Changing Save Files Again"
savedEmptyLabel.TextColor3 = Color3.new(1, 1, 1)
savedEmptyLabel.Font = Enum.Font.GothamBold
savedEmptyLabel.TextScaled = true
savedEmptyLabel.Visible = false
savedEmptyLabel.Parent = savedScroll

local savedGrid = Instance.new("UIGridLayout")
savedGrid.CellSize = UDim2.new(0, scale("X", 120), 0, scale("Y", 200))
savedGrid.CellPadding = UDim2.new(0, scale("X", 8), 0, scale("Y", 8))
savedGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
savedGrid.Parent = savedScroll

----------------------------------------------------------------------
-- Settings panel (right side)
----------------------------------------------------------------------

local settingsPanel = Instance.new("Frame")
settingsPanel.Size = UDim2.new(0.4, -scale("X", 10), 1, -scale("Y", 70))
settingsPanel.Position = UDim2.new(0.6, scale("X", 5), 0, scale("Y", 70))
settingsPanel.BackgroundTransparency = 1
settingsPanel.Parent = mainFrame

local settingsTitle = Instance.new("TextLabel")
settingsTitle.Size = UDim2.new(1, 0, 0, scale("Y", 28))
settingsTitle.BackgroundTransparency = 1
settingsTitle.Text = "Settings"
settingsTitle.TextColor3 = Color3.new(1, 1, 1)
settingsTitle.Font = Enum.Font.GothamBold
settingsTitle.TextScaled = true
settingsTitle.Parent = settingsPanel

local settingsScroll = Instance.new("ScrollingFrame")
settingsScroll.Size = UDim2.new(1, -scale("X", 20), 1, -scale("Y", 40))
settingsScroll.Position = UDim2.new(0, scale("X", 10), 0, scale("Y", 30))
settingsScroll.BackgroundTransparency = 1
settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsScroll.ScrollBarThickness = 4
settingsScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 140)
settingsScroll.Parent = settingsPanel

-- Only allow vertical scrolling
settingsScroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    settingsScroll.CanvasPosition = Vector2.new(0, settingsScroll.CanvasPosition.Y)
end)

local settingsList = Instance.new("UIListLayout", settingsScroll)
settingsList.Padding = UDim.new(0, 8)
settingsList.FillDirection = Enum.FillDirection.Vertical
settingsList.SortOrder = Enum.SortOrder.LayoutOrder

settingsList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    settingsScroll.CanvasSize = UDim2.new(0, 0, 0, settingsList.AbsoluteContentSize.Y + 10)
end)

-- Slider with a label, a number box and a draggable knob
local function addSlider(name, min, max, default)
    config[name] = default or min

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, scale("Y", 65))
    row.BackgroundTransparency = 1
    row.Parent = settingsScroll

    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 1, 0)
    card.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    card.BackgroundTransparency = 0.4
    card.Parent = row
    addCorner(card, 6)
    addStroke(card, Color3.fromRGB(60, 60, 90), 1)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.5, -scale("X", 10), 0, scale("Y", 20))
    label.Position = UDim2.new(0, 10, 0, 5)
    label.BackgroundTransparency = 1
    label.Text = string.format("%s: %.2f", name, config[name])
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Font = Enum.Font.Gotham
    label.TextScaled = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = card

    local valueBox = Instance.new("TextBox")
    valueBox.Size = UDim2.new(0.5, -scale("X", 20), 0, scale("Y", 20))
    valueBox.Position = UDim2.new(0.5, scale("X", 10), 0, scale("Y", 5))
    valueBox.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    valueBox.Text = tostring(config[name])
    valueBox.TextColor3 = Color3.new(1, 1, 1)
    valueBox.Font = Enum.Font.Gotham
    valueBox.TextScaled = true
    valueBox.ClearTextOnFocus = false
    valueBox.Parent = card
    addCorner(valueBox, 4)

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -scale("X", 40), 0, scale("Y", 12))
    track.Position = UDim2.new(0, scale("X", 20), 0, scale("Y", 35))
    track.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    track.Parent = card
    addCorner(track, 6)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(0, 140, 255)
    fill.Parent = track
    addCorner(fill, 6)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, scale("X", 20), 0, scale("Y", 20))
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0, 0, 0.5, 0)
    knob.BackgroundColor3 = Color3.fromRGB(220, 220, 255)
    knob.Parent = track
    addCorner(knob, 10)
    addStroke(knob, Color3.fromRGB(0, 0, 0), 1)

    -- Move the fill bar and knob to a 0..1 position
    local function setVisual(fraction)
        local f = math.clamp(fraction, 0, 1)
        TweenService:Create(fill, TweenInfo.new(0.15), { Size = UDim2.new(f, 0, 1, 0) }):Play()
        TweenService:Create(knob, TweenInfo.new(0.15), { Position = UDim2.new(f, 0, 0.5, 0) }):Play()
    end

    -- Set the value, update the UI, and apply it live to the playing emote
    local function applyValue(value)
        config[name] = math.clamp(value, min, max)
        label.Text = string.format("%s: %.2f", name, config[name])
        valueBox.Text = tostring(config[name])
        setVisual((config[name] - min) / (max - min))

        if currentTrack and currentTrack.IsPlaying then
            if name == "Speed" then
                currentTrack:AdjustSpeed(config["Speed"])
            elseif name == "Weight" then
                local weight = config["Weight"]
                if weight == 0 then
                    weight = 0.001
                end
                currentTrack:AdjustWeight(weight)
            elseif name == "Time Position" then
                if currentTrack.Length > 0 then
                    currentTrack.TimePosition = config["Time Position"] * currentTrack.Length
                end
            end
        end
    end

    local dragging = false

    local function updateFromInput(input)
        local fraction = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        applyValue(math.floor((min + (max - min) * fraction) * 100) / 100)
    end

    local function isPress(input)
        return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
    end

    track.InputBegan:Connect(function(input)
        if isPress(input) then
            dragging = true
            updateFromInput(input)
        end
    end)

    knob.InputBegan:Connect(function(input)
        if isPress(input) then
            dragging = true
            updateFromInput(input)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromInput(input)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if dragging and isPress(input) then
            dragging = false
        end
    end)

    valueBox.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            local typed = tonumber(valueBox.Text)
            if typed then
                applyValue(typed)
            else
                valueBox.Text = tostring(config[name])
            end
        end
    end)

    sliderSetters[name] = applyValue
    applyValue(config[name])
end

-- ON / OFF toggle
local function addToggle(name)
    config[name] = config[name] or false

    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, scale("Y", 40))
    card.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    card.BackgroundTransparency = 0.4
    card.Parent = settingsScroll
    addCorner(card, 6)
    addStroke(card, Color3.fromRGB(60, 60, 90), 1)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -scale("X", 90), 1, 0)
    label.Position = UDim2.new(0, scale("X", 10), 0, 0)
    label.BackgroundTransparency = 1
    label.Text = name
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Font = Enum.Font.Gotham
    label.TextScaled = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = card

    local button = Instance.new("TextButton")
    button.Size = UDim2.new(0, scale("X", 60), 0, scale("Y", 24))
    button.Position = UDim2.new(1, -scale("X", 70), 0.5, -scale("Y", 12))
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Font = Enum.Font.GothamBold
    button.TextScaled = true
    button.Parent = card
    addCorner(button, 4)

    local function updateVisual(on)
        button.Text = on and "ON" or "OFF"
        button.BackgroundColor3 = on and Color3.fromRGB(0, 150, 100) or Color3.fromRGB(150, 40, 40)
        button.BackgroundTransparency = 0.2
    end

    button.MouseButton1Click:Connect(function()
        config[name] = not config[name]
        updateVisual(config[name])
    end)

    updateVisual(config[name])
    toggleSetters[name] = updateVisual
end

-- Plain action button inside the settings list
local function addActionButton(text, callback)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, scale("Y", 45))
    card.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    card.BackgroundTransparency = 0.4
    card.Parent = settingsScroll
    addCorner(card, 6)

    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, -scale("X", 20), 1, -scale("Y", 10))
    button.Position = UDim2.new(0, scale("X", 10), 0, scale("Y", 5))
    button.BackgroundColor3 = Color3.fromRGB(30, 90, 180)
    button.BackgroundTransparency = 0.2
    button.Text = text
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Font = Enum.Font.GothamBold
    button.TextScaled = true
    button.Parent = card
    addCorner(button, 6)

    button.MouseButton1Click:Connect(function()
        if typeof(callback) == "function" then
            callback()
        end
    end)

    return button
end

-- Build the settings list (order = order on screen)
local resetButton = addActionButton("Reset Settings", function() end)
addToggle("Grey Rain")
addToggle("Stop Emote When Moving")
addToggle("Looped")
addSlider("Speed", 0, 5, config["Speed"])
addSlider("Time Position", 0, 1, config["Time Position"])
addSlider("Weight", 0, 1, config["Weight"])
addSlider("Fade In", 0, 2, config["Fade In"])
addSlider("Fade Out", 0, 2, config["Fade Out"])
addToggle("Stop Other Animations On Play")
addToggle("High Priority")

resetButton.MouseButton1Click:Connect(function()
    setToggle("Grey Rain", true)
    setToggle("Stop Emote When Moving", true)
    setToggle("Stop Other Animations On Play", true)
    setToggle("High Priority", true)
    setSlider("Fade In", 0.1)
    setSlider("Fade Out", 0.1)
    setSlider("Weight", 1)
    setSlider("Speed", 1)
    setSlider("Time Position", 0)
    setToggle("Looped", true)
end)

----------------------------------------------------------------------
-- Catalog search & paging
----------------------------------------------------------------------

local SORT_OPTIONS = {
    { Enum.CatalogSortType.Relevance, "Relevance" },
    { Enum.CatalogSortType.PriceHighToLow, "Price High→Low" },
    { Enum.CatalogSortType.PriceLowToHigh, "Price Low→High" },
    { Enum.CatalogSortType.MostFavorited, "Most Favorited" },
    { Enum.CatalogSortType.RecentlyCreated, "Recently Created" },
    { Enum.CatalogSortType.Bestselling, "Bestselling" },
}

local sortIndex = 1
local currentKeyword = ""
local currentPages = nil -- CatalogPages object (or the fake R6 one)
local pageNumber = 1
local tabToken = 1 -- increases on every tab switch so old render loops can stop

local refreshSavedList -- defined further down (used by several functions)

-- Returns a CatalogPages object for the keyword (or a fake single-emote page on R6)
local function searchCatalog(keyword)
    if isR6 then
        return {
            IsFinished = true,
            GetCurrentPage = function()
                return { { Id = 115314801778772, Name = "Dance If Youre The Best", AssetId = 115314801778772 } }
            end,
            AdvanceToNextPageAsync = function() end,
        }
    end

    local params = CatalogSearchParams.new()
    params.SearchKeyword = keyword or ""
    params.CategoryFilter = Enum.CatalogCategoryFilter.None
    params.SalesTypeFilter = Enum.SalesTypeFilter.All
    params.AssetTypes = { Enum.AvatarAssetType.EmoteAnimation }
    params.IncludeOffSale = true
    params.SortType = SORT_OPTIONS[sortIndex][1]
    params.Limit = 10

    local ok, pages = pcall(function()
        return AvatarEditorService:SearchCatalog(params)
    end)
    if not ok then
        return nil
    end
    return pages
end

-- One emote card in the catalog grid
local function createCatalogCard(item)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(0, scale("X", 120), 0, scale("Y", 180))
    card.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    card.BackgroundTransparency = 0.2
    addCorner(card, 8)
    addStroke(card, Color3.fromRGB(60, 60, 90), 1)

    local assetId = item.AssetId or item.Id

    local thumbnail = Instance.new("ImageLabel")
    thumbnail.Size = UDim2.new(1, -scale("X", 10), 0, scale("Y", 90))
    thumbnail.Position = UDim2.new(0, scale("X", 5), 0, scale("Y", 5))
    thumbnail.BackgroundTransparency = 1
    thumbnail.ScaleType = Enum.ScaleType.Fit
    pcall(function()
        thumbnail.Image = "rbxthumb://type=Asset&id=" .. tonumber(assetId) .. "&w=150&h=150"
    end)
    thumbnail.Parent = card
    addCorner(thumbnail, 4)

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -scale("X", 10), 0, scale("Y", 28))
    nameLabel.Position = UDim2.new(0, scale("X", 5), 0, scale("Y", 100))
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = item.Name or "Unknown"
    nameLabel.TextScaled = true
    nameLabel.TextWrapped = true
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.Parent = card

    -- Copy catalog link button
    local catalogLink = "https://www.roblox.com/catalog/" .. tonumber(item.Id)
    local linkButton = Instance.new("TextButton")
    linkButton.Parent = card
    linkButton.Size = UDim2.new(0, scale("X", 36), 0, scale("Y", 36))
    linkButton.Position = UDim2.new(1, -scale("X", 42), 0, scale("Y", 5))
    linkButton.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    linkButton.BackgroundTransparency = 0.2
    linkButton.Text = "🛒🔗"
    linkButton.Font = Enum.Font.GothamBold
    linkButton.TextScaled = true
    linkButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    linkButton.AutoButtonColor = false
    addCorner(linkButton, 6)

    linkButton.MouseButton1Click:Connect(function()
        setclipboard(catalogLink)
        linkButton.Text = "✅"
        linkButton.BackgroundColor3 = Color3.fromRGB(0, 150, 100)
        task.wait(0.7)
        linkButton.Text = "🛒🔗"
        linkButton.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    end)

    -- Play button
    local playButton = makeButton(
        card, "Play", Color3.fromRGB(40, 140, 80),
        UDim2.new(0.45, -scale("X", 5), 0, scale("Y", 24)),
        UDim2.new(0, scale("X", 5), 1, -scale("Y", 29))
    )
    playButton.MouseButton1Click:Connect(function()
        playEmote(assetId)
    end)

    -- Save button
    local saveButton = makeButton(
        card, "Save", Color3.fromRGB(40, 100, 160),
        UDim2.new(0.45, -scale("X", 5), 0, scale("Y", 24)),
        UDim2.new(0.55, 0, 1, -scale("Y", 29))
    )
    saveButton.MouseButton1Click:Connect(function()
        local alreadySaved = false
        for _, entry in ipairs(savedEmotes) do
            if entry.Id == item.Id then
                alreadySaved = true
                break
            end
        end

        if not alreadySaved then
            local realId = GetReal(assetId)
            table.insert(savedEmotes, {
                Id = item.Id,
                AssetId = assetId,
                Name = item.Name or "Unknown",
                AnimationId = "rbxassetid://" .. tostring(realId or assetId),
                Favorite = false,
            })
            saveSavedEmotes()
            saveButton.Text = "Saved!"
            saveButton.BackgroundColor3 = Color3.fromRGB(0, 160, 100)
            task.wait(1)
            saveButton.Text = "Save"
            saveButton.BackgroundColor3 = Color3.fromRGB(40, 100, 160)
        else
            saveButton.Text = "Already"
            task.wait(0.7)
            saveButton.Text = "Save"
        end
    end)

    popIn(card)
    return card
end

-- Show / hide the Prev and Next buttons depending on the current page
local function updateNavButtons()
    prevButton.Visible = pageNumber > 1
    if currentPages and typeof(currentPages.IsFinished) == "boolean" then
        nextButton.Visible = not currentPages.IsFinished
    else
        nextButton.Visible = true
    end
end

local renderId = 0

-- Draws the current page of a CatalogPages object into the grid
local function renderCatalogPage(pages)
    renderId = renderId + 1
    local myRenderId = renderId

    pageBox.Text = "Loading..."

    for _, child in ipairs(catalogScroll:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    local items
    local ok, result = pcall(function()
        return pages:GetCurrentPage()
    end)
    if ok then
        items = result
    else
        pageBox.Text = "ERROR"
        return
    end

    if myRenderId ~= renderId then
        return
    end

    if items and #items > 0 then
        catalogEmptyLabel.Visible = false
        local myTab = tabToken
        local count = 0
        for _, item in ipairs(items) do
            -- stop if the user switched tabs or started another render
            if tabToken ~= myTab or myRenderId ~= renderId then
                break
            end
            createCatalogCard(item).Parent = catalogScroll
            count = count + 1
            if count % 2 == 0 then
                RunService.RenderStepped:Wait() -- spread the work over frames to avoid lag
            end
        end
    else
        catalogEmptyLabel.Visible = true
    end

    if myRenderId == renderId then
        catalogScroll.CanvasSize = UDim2.new(0, 0, 0, catalogGrid.AbsoluteContentSize.Y + 8)
        pageBox.Text = tostring(pageNumber) .. " / Enter page"
        updateNavButtons()
    end
end

-- Starts a fresh search and advances it to page `targetPage`
local function fetchPage(targetPage)
    local pages = searchCatalog(currentKeyword)
    if not pages then
        return nil
    end

    for _ = 2, targetPage do
        if pages.IsFinished then
            break
        end
        local ok = pcall(function()
            pages:AdvanceToNextPageAsync()
        end)
        if not ok then
            break
        end
    end

    return pages
end

local function runSearch(keyword)
    currentKeyword = keyword or ""
    pageNumber = 1
    pageBox.Text = "Loading..."
    currentPages = searchCatalog(currentKeyword)
    if currentPages then
        renderCatalogPage(currentPages)
    end
end

local function goToNextPage()
    if not currentPages or currentPages.IsFinished then
        return
    end

    local ok = pcall(function()
        currentPages:AdvanceToNextPageAsync()
    end)

    if ok then
        pageNumber = pageNumber + 1
        renderCatalogPage(currentPages)
    else
        -- fallback: rebuild the search and jump to the page
        local target = pageNumber + 1
        local pages = fetchPage(target)
        if pages then
            currentPages = pages
            pageNumber = math.min(target, pageNumber + 1)
            renderCatalogPage(currentPages)
        end
    end
end

local function goToPreviousPage()
    if not currentPages or pageNumber <= 1 then
        return
    end

    local ok = pcall(function()
        currentPages:AdvanceToPreviousPageAsync()
    end)

    if ok then
        pageNumber = math.max(1, pageNumber - 1)
        renderCatalogPage(currentPages)
    else
        local target = math.max(1, pageNumber - 1)
        local pages = fetchPage(target)
        if pages then
            currentPages = pages
            pageNumber = target
            renderCatalogPage(currentPages)
        end
    end
end

refreshButton.MouseButton1Click:Connect(function()
    runSearch(searchBox.Text)
end)

searchBox.FocusLost:Connect(function(enterPressed)
    if enterPressed then
        runSearch(searchBox.Text)
    end
end)

sortButton.MouseButton1Click:Connect(function()
    sortIndex = sortIndex % #SORT_OPTIONS + 1
    sortButton.Text = "Sort: " .. SORT_OPTIONS[sortIndex][2]
    runSearch(currentKeyword)
end)

nextButton.MouseButton1Click:Connect(goToNextPage)
prevButton.MouseButton1Click:Connect(goToPreviousPage)

-- Left / Right arrow keys change page
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Right then
        goToNextPage()
    elseif input.KeyCode == Enum.KeyCode.Left then
        goToPreviousPage()
    end
end)

-- Type a page number and press Enter to jump to it
local function showPageError(message)
    pageErrorLabel.Text = message
    pageErrorLabel.Visible = true
    task.delay(2, function()
        if pageErrorLabel then
            pageErrorLabel.Visible = false
        end
    end)
end

pageBox.FocusLost:Connect(function(enterPressed)
    if not enterPressed then
        return
    end

    local cleaned = pageBox.Text:gsub("%s+", "")
    local typedPage = tonumber(cleaned:match("%d+"))

    if not typedPage or typedPage < 1 then
        showPageError("Invalid page number")
        pageBox.Text = "Page " .. tostring(pageNumber)
        return
    end

    local target = math.floor(typedPage)
    if target == pageNumber then
        pageBox.Text = "Page " .. tostring(pageNumber)
        return
    end

    pageBox.Text = "Loading..."
    local ok, pages = pcall(function()
        return fetchPage(target)
    end)

    if not ok or not pages then
        showPageError("Unable to fetch page")
        pageBox.Text = "Page " .. tostring(pageNumber)
        return
    end

    currentPages = pages
    pageNumber = math.max(1, target)
    renderCatalogPage(currentPages)
end)

----------------------------------------------------------------------
-- Saved emotes list
----------------------------------------------------------------------

-- One card in the saved list
local function createSavedCard(entry)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(0, scale("X", 120), 0, scale("Y", 200))
    card.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    card.BackgroundTransparency = 0.2
    addCorner(card, 8)
    addStroke(card, Color3.fromRGB(60, 60, 90), 1)

    local thumbnail = Instance.new("ImageLabel")
    thumbnail.Size = UDim2.new(1, -scale("X", 10), 0, scale("Y", 90))
    thumbnail.Position = UDim2.new(0, scale("X", 5), 0, scale("Y", 5))
    thumbnail.BackgroundTransparency = 1
    thumbnail.ScaleType = Enum.ScaleType.Fit
    thumbnail.Image = "rbxthumb://type=Asset&id=11768914234&w=150&h=150"
    thumbnail.Parent = card
    addCorner(thumbnail, 4)

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -scale("X", 10), 0, scale("Y", 28))
    nameLabel.Position = UDim2.new(0, scale("X", 5), 0, scale("Y", 100))
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = entry.Name or "Unknown"
    nameLabel.TextScaled = true
    nameLabel.TextWrapped = true
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.Parent = card

    -- Play
    local playButton = makeButton(
        card, "Play", Color3.fromRGB(40, 140, 80),
        UDim2.new(0.45, -scale("X", 5), 0, scale("Y", 24)),
        UDim2.new(0, scale("X", 5), 1, -scale("Y", 29))
    )
    playButton.MouseButton1Click:Connect(function()
        playEmote(entry.Id)
    end)

    -- Remove
    local removeButton = makeButton(
        card, "Remove", Color3.fromRGB(160, 50, 50),
        UDim2.new(0.45, -scale("X", 5), 0, scale("Y", 24)),
        UDim2.new(0.55, 0, 1, -scale("Y", 29))
    )
    removeButton.MouseButton1Click:Connect(function()
        for index, saved in ipairs(savedEmotes) do
            if saved.Id == entry.Id then
                table.remove(savedEmotes, index)
                saveSavedEmotes()
                refreshSavedList()
                break
            end
        end
    end)

    -- Copy animation id
    local copyButton = Instance.new("TextButton")
    copyButton.Size = UDim2.new(0, scale("X", 40), 0, scale("Y", 24))
    copyButton.Position = UDim2.new(0.5, -scale("X", 20), 0, scale("Y", 5))
    copyButton.BackgroundColor3 = Color3.fromRGB(50, 50, 80)
    copyButton.BackgroundTransparency = 0.2
    copyButton.Text = "Copy AnimId"
    copyButton.Font = Enum.Font.GothamBold
    copyButton.TextScaled = true
    copyButton.TextColor3 = Color3.new(1, 1, 1)
    copyButton.Parent = card
    addCorner(copyButton, 4)

    copyButton.MouseButton1Click:Connect(function()
        if setclipboard then
            setclipboard((entry.AnimationId:gsub("rbxassetid://", "")))
        end
        copyButton.Text = "Copied!"
        task.wait(0.7)
        copyButton.Text = "Copy AnimId"
    end)

    -- Favorite star
    local starButton = Instance.new("TextButton")
    starButton.Size = UDim2.new(0, scale("X", 24), 0, scale("Y", 24))
    starButton.Position = UDim2.new(1, -scale("X", 30), 0, scale("Y", 5))
    starButton.Text = entry.Favorite and "★" or "☆"
    starButton.Font = Enum.Font.GothamBold
    starButton.TextScaled = true
    starButton.TextColor3 = Color3.fromRGB(255, 220, 50)
    starButton.BackgroundTransparency = 1
    starButton.Parent = card

    starButton.MouseButton1Click:Connect(function()
        entry.Favorite = not entry.Favorite
        starButton.Text = entry.Favorite and "★" or "☆"
        saveSavedEmotes()
        refreshSavedList()
    end)

    popIn(card)
    return card
end

local savedRenderId = 0

-- Rebuilds the saved list (filtered by the search box, favorites first)
function refreshSavedList()
    savedRenderId = savedRenderId + 1
    local myRenderId = savedRenderId

    for _, child in ipairs(savedScroll:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    local filter = (savedSearchBox.Text or ""):lower()
    local visibleEntries = {}
    for _, entry in ipairs(savedEmotes) do
        if filter == "" or (entry.Name and entry.Name:lower():find(filter)) then
            table.insert(visibleEntries, entry)
        end
    end

    table.sort(visibleEntries, function(a, b)
        if a.Favorite ~= b.Favorite then
            return a.Favorite
        end
        return false
    end)

    if #visibleEntries > 0 then
        savedEmptyLabel.Visible = false
        local myTab = tabToken
        local count = 0
        for _, entry in ipairs(visibleEntries) do
            if tabToken ~= myTab or myRenderId ~= savedRenderId then
                break
            end
            createSavedCard(entry).Parent = savedScroll
            count = count + 1
            if count % 25 == 0 then
                RunService.RenderStepped:Wait()
            end
        end
    else
        savedEmptyLabel.Visible = true
    end

    if myRenderId == savedRenderId then
        savedScroll.CanvasSize = UDim2.new(0, 0, 0, savedGrid.AbsoluteContentSize.Y + 8)
    end
end

-- Add an emote by typing its id
addIdButton.MouseButton1Click:Connect(function()
    local id = tonumber(emoteIdBox.Text)
    if not id then
        return
    end

    for _, entry in ipairs(savedEmotes) do
        if entry.Id == id then
            return -- already saved
        end
    end

    local realId = GetReal(id)
    table.insert(savedEmotes, {
        Id = id,
        AssetId = id,
        Name = "Custom ID: " .. id,
        AnimationId = "rbxassetid://" .. tostring(realId or id),
        Favorite = false,
    })
    saveSavedEmotes()
    refreshSavedList()
end)

savedSearchBox:GetPropertyChangedSignal("Text"):Connect(refreshSavedList)

----------------------------------------------------------------------
-- Tab switching
----------------------------------------------------------------------

catalogTab.MouseButton1Click:Connect(function()
    tabToken = tabToken + 1
    catalogPage.Visible = true
    savedPage.Visible = false
    catalogTab.BackgroundColor3 = Color3.fromRGB(30, 30, 80)
    savedTab.BackgroundColor3 = Color3.fromRGB(20, 50, 20)
end)

savedTab.MouseButton1Click:Connect(function()
    tabToken = tabToken + 1
    catalogPage.Visible = false
    savedPage.Visible = true
    catalogTab.BackgroundColor3 = Color3.fromRGB(20, 20, 40)
    savedTab.BackgroundColor3 = Color3.fromRGB(30, 80, 30)
    refreshSavedList()
end)

----------------------------------------------------------------------
-- Open / close button and G key
----------------------------------------------------------------------

local function toggleMenu()
    screenGui.Enabled = not screenGui.Enabled
end

local toggleGui = Instance.new("ScreenGui")
toggleGui.Name = "ToggleButtonGui"
toggleGui.ResetOnSpawn = false
toggleGui.Parent = CoreGui
toggleGui.Enabled = true

local toggleButton = Instance.new("TextButton")
toggleButton.Parent = toggleGui
toggleButton.Text = "VX"
toggleButton.Font = Enum.Font.GothamSemibold
toggleButton.TextScaled = true
toggleButton.Size = UDim2.new(0, 50, 0, 50)
toggleButton.Position = UDim2.new(0, 20, 0.5, -50)
toggleButton.AnchorPoint = Vector2.new(0, 0.5)
toggleButton.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
toggleButton.BackgroundTransparency = 0.2
toggleButton.TextColor3 = Color3.new(1, 1, 1)
toggleButton.Active = true
pcall(function()
    toggleButton.Draggable = true
end)
addCorner(toggleButton, 12)
addStroke(toggleButton, Color3.fromRGB(60, 60, 100), 2)

local aspectRatio = Instance.new("UIAspectRatioConstraint")
aspectRatio.Parent = toggleButton
aspectRatio.AspectRatio = 1

toggleButton.MouseButton1Click:Connect(toggleMenu)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.G then
        toggleMenu()
    end
end)

-- Start: show the menu and load the first catalog page + saved list
screenGui.Enabled = true
runSearch("")
refreshSavedList()

----------------------------------------------------------------------
-- Welcome notifications + Discord invite
----------------------------------------------------------------------

local DISCORD_INVITE = "https://discord.gg/rQ4Sv2x7"
local StarterGui = Services.StarterGui

if setclipboard then
    pcall(setclipboard, DISCORD_INVITE)
end

task.spawn(function()
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "ASUKA",
            Text = "welcome to AsukaReign !!, Join discord to get more VIP title",
            Duration = 30,
        })
        StarterGui:SetCore("SendNotification", {
            Title = "ASUKA",
            Text = "BY Yadsan_GodVerse",
            Icon = "rbxthumb://type=Asset&id=5107182114&w=150&h=150",
            Duration = 25,
        })
    end)
end)

local req = (syn and syn.request) or http_request or request

-- APNA FIREBASE URL YAHAN DAALO (end me /users rehne do)
local DB = "https://YOUR-PROJECT-default-rtdb.firebaseio.com/users"

local OWNER_NAME = "N0T_Z0RO100"

-- NOTE: ADMINS aur VIPS me naam hamesha lowercase me likhna
local ADMINS = {}
local VIPS = {}

local function getPlayerRank(player)
    local username = string.lower(player.Name)

    if username == string.lower(OWNER_NAME) then
        return "OWNER"
    elseif ADMINS[username] then
        return "ADMIN"
    elseif VIPS[username] then
        return "VIP"
    end

    return "USER"
end

local function makeHexagonTag(playerName, rankname)
    local player = Players:FindFirstChild(playerName)
    if not player then return true end
    local head = player.Character and player.Character:FindFirstChild("Head")
    if not head or head:FindFirstChild("HexagonNametag") then return true end

    local billboard = Instance.new("BillboardGui")
    billboard.Name, billboard.Size, billboard.StudsOffset, billboard.AlwaysOnTop, billboard.MaxDistance = "HexagonNametag", UDim2.new(0, 180, 0, 70), Vector3.new(0, 4.5, 0), true, 100
    billboard.Parent = head

    local thumbnail = Instance.new("ImageLabel")
    thumbnail.Name, thumbnail.Size, thumbnail.Position, thumbnail.AnchorPoint, thumbnail.BackgroundTransparency, thumbnail.Image = "Thumbnail", UDim2.new(0.187, 0, 0.44, 0), UDim2.new(0.5, 0, 0.22, 0), Vector2.new(0.5, 0.5), 1, "rbxthumb://type=AvatarHeadShot&id=" .. player.UserId .. "&w=150&h=150"
    thumbnail.Parent = billboard

    local imgCorner = Instance.new("UICorner")
    imgCorner.CornerRadius, imgCorner.Parent = UDim.new(1, 0), thumbnail

    local nameTxt = Instance.new("TextLabel")
    nameTxt.Name, nameTxt.Size, nameTxt.Position, nameTxt.BackgroundTransparency, nameTxt.Text, nameTxt.TextColor3, nameTxt.TextScaled, nameTxt.Font, nameTxt.TextWrapped = "NameTxt", UDim2.new(1, 0, 0.273, 0), UDim2.new(0, 0, 0.446, 0), 1, player.DisplayName .. " (@" .. player.Name .. ")", Color3.fromRGB(255, 255, 255), true, Enum.Font.FredokaOne, true
    nameTxt.Parent = billboard

    local textConstraint = Instance.new("UITextSizeConstraint")
    textConstraint.MaxTextSize, textConstraint.Parent = 98, nameTxt

    local nameStroke = Instance.new("UIStroke")
    nameStroke.Thickness, nameStroke.Parent = 1.5, nameTxt

    local tag = Instance.new("TextLabel")
    tag.Name, tag.Size, tag.Position, tag.BackgroundTransparency, tag.Text, tag.TextColor3, tag.TextScaled, tag.Font, tag.TextWrapped = "Tag", UDim2.new(1, 0, 0.246, 0), UDim2.new(0, 0, 0.8, 0), 1, rankname or "USER", Color3.fromRGB(255, 255, 255), true, Enum.Font.FredokaOne, true
    tag.Parent = billboard

    local tagConstraint = Instance.new("UITextSizeConstraint")
    tagConstraint.MaxTextSize, tagConstraint.Parent = 74, tag

    local tagStroke = Instance.new("UIStroke")
    tagStroke.Color, tagStroke.Thickness, tagStroke.Parent = Color3.fromRGB(99, 99, 99), 1.5, tag

    local gradient = Instance.new("UIGradient")
    gradient.Name, gradient.Rotation, gradient.Color = "NametagGradient", 60, ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 200, 200)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(113, 113, 113))
    }
    gradient.Parent = tag

    return true
end

-- apna naam database me register karo
local function heartbeat()
    pcall(function()
        req({
            Url = DB .. "/" .. Players.LocalPlayer.Name .. ".json",
            Method = "PUT",
            Headers = {["Content-Type"] = "application/json"},
            Body = tostring(os.time())
        })
    end)
end

-- jo script users abhi active hain unki list lao
local function getUsers()
    local active = {}
    -- apna naam hamesha list me rahega (Firebase fail ho tab bhi)
    active[string.lower(Players.LocalPlayer.Name)] = true

    local ok, res = pcall(function()
        return req({Url = DB .. ".json", Method = "GET"})
    end)
    if not ok or not res or not res.Body then return active end

    local ok2, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)
    if not ok2 or type(data) ~= "table" then return active end

    for name, t in pairs(data) do
        if type(t) == "number" and os.time() - t < 60 then
            active[string.lower(name)] = true
        end
    end
    return active
end

local function tagPlayer(plr)
    if plr.Character then
        makeHexagonTag(plr.Name, getPlayerRank(plr))
    end
end

-- har 20 sec: heartbeat bhejo, list lao, sabko tag lagao
task.spawn(function()
    while true do
        heartbeat()
        local users = getUsers()
        for _, plr in ipairs(Players:GetPlayers()) do
            if users[string.lower(plr.Name)] then
                tagPlayer(plr)
            end
        end
        task.wait(20)
    end
end)

-- respawn hone par dobara tag lagao
local function hook(plr)
    plr.CharacterAdded:Connect(function()
        local char = plr.Character
        if char then char:WaitForChild("Head", 10) end
        task.wait(1)
        if getUsers()[string.lower(plr.Name)] then
            tagPlayer(plr)
        end
    end)
end

for _, p in ipairs(Players:GetPlayers()) do hook(p) end
Players.PlayerAdded:Connect(hook)

----------------------------------------------------------------------
-- Character collision: only the HumanoidRootPart collides, so you
-- don't get pushed around / stuck by your own limbs while emoting
----------------------------------------------------------------------

task.spawn(function()
    local function setupCollision(char)
        local rootPart = char:WaitForChild("HumanoidRootPart")
        local bodyParts = {}

        rootPart.CanCollide = true

        local function trackPart(part)
            if part:IsA("BasePart") and part ~= rootPart then
                table.insert(bodyParts, part)
            end
        end

        for _, part in pairs(char:GetDescendants()) do
            trackPart(part)
        end

        local descendantConnection = char.DescendantAdded:Connect(trackPart)

        local heartbeatConnection
        heartbeatConnection = RunService.Heartbeat:Connect(function()
            -- character was removed: clean up
            if not char or not char.Parent then
                heartbeatConnection:Disconnect()
                descendantConnection:Disconnect()
                return
            end

            for i = 1, #bodyParts do
                local part = bodyParts[i]
                if part and part.Parent then
                    part.CanCollide = false
                end
            end
        end)
    end

    if player.Character then
        setupCollision(player.Character)
    end
    player.CharacterAdded:Connect(setupCollision)
end)
