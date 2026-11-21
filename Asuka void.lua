-- YADSAN RANDOM CIRCLE + VOID TP GUI 👑 (MINIMIZE + DRAG FIXED)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local hrp = character:WaitForChild("HumanoidRootPart")

-------------------------------------------------
-- DRAG SYSTEM (PC + MOBILE)
-------------------------------------------------

local function makeDraggable(frame)
	local dragging = false
	local dragInput
	local dragStart
	local startPos

	frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 
		or input.UserInputType == Enum.UserInputType.Touch then

			dragging = true
			dragStart = input.Position
			startPos = frame.Position

			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)

	frame.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement 
		or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)
end

-------------------------------------------------
-- VARIABLES
-------------------------------------------------

local running = false
local savedPosition = nil
local angle = 0
local minimized = false

-------------------------------------------------
-- GUI
-------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "LDVoidTP"
gui.Parent = game.CoreGui

local frame = Instance.new("Frame")
frame.Parent = gui
frame.Size = UDim2.new(0, 260, 0, 230)
frame.Position = UDim2.new(0.35, 0, 0.3, 0)
frame.BackgroundColor3 = Color3.fromRGB(20,20,20)
frame.BorderSizePixel = 0
frame.Active = true

makeDraggable(frame)

Instance.new("UICorner", frame).CornerRadius = UDim.new(0,12)

-------------------------------------------------
-- TITLE
-------------------------------------------------

local title = Instance.new("TextLabel")
title.Parent = frame
title.Size = UDim2.new(1,0,0,35)
title.BackgroundTransparency = 1
title.Text = "Asuka Void Teleport👑"
title.TextColor3 = Color3.new(1,1,1)
title.Font = Enum.Font.GothamBold
title.TextSize = 18

-------------------------------------------------
-- MINIMIZE BUTTON
-------------------------------------------------

local miniBtn = Instance.new("TextButton")
miniBtn.Parent = frame
miniBtn.Size = UDim2.new(0,30,0,30)
miniBtn.Position = UDim2.new(1,-35,0,5)
miniBtn.Text = "–"
miniBtn.TextSize = 20
miniBtn.TextColor3 = Color3.new(1,1,1)
miniBtn.BackgroundColor3 = Color3.fromRGB(50,50,50)
Instance.new("UICorner", miniBtn)

-------------------------------------------------
-- CONTENT HOLDER
-------------------------------------------------

local content = Instance.new("Frame")
content.Parent = frame
content.Size = UDim2.new(1,0,1,-35)
content.Position = UDim2.new(0,0,0,35)
content.BackgroundTransparency = 1

-------------------------------------------------
-- BOX FUNCTION
-------------------------------------------------

local function makeBox(text, pos, placeholder)
	local box = Instance.new("TextBox")
	box.Parent = content
	box.Size = UDim2.new(0.8,0,0,35)
	box.Position = pos
	box.PlaceholderText = placeholder
	box.Text = text
	box.Font = Enum.Font.Gotham
	box.TextSize = 16
	box.TextColor3 = Color3.new(1,1,1)
	box.BackgroundColor3 = Color3.fromRGB(35,35,35)
	Instance.new("UICorner", box)
	return box
end

local distanceBox = makeBox("15", UDim2.new(0.1,0,0.1,0), "Circle Distance")
local speedBox = makeBox("0.08", UDim2.new(0.1,0,0.35,0), "Teleport Speed")
local voidBox = makeBox("25", UDim2.new(0.1,0,0.6,0), "Void Chance %")

-------------------------------------------------
-- START BUTTON
-------------------------------------------------

local button = Instance.new("TextButton")
button.Parent = content
button.Size = UDim2.new(0.8,0,0,40)
button.Position = UDim2.new(0.1,0,0.85,0)
button.Text = "START"
button.Font = Enum.Font.GothamBold
button.TextSize = 18
button.TextColor3 = Color3.new(1,1,1)
button.BackgroundColor3 = Color3.fromRGB(0,170,0)
Instance.new("UICorner", button)

-------------------------------------------------
-- MINIMIZE LOGIC
-------------------------------------------------

miniBtn.MouseButton1Click:Connect(function()
	minimized = not minimized

	if minimized then
		content.Visible = false
		frame.Size = UDim2.new(0,260,0,40)
		miniBtn.Text = "+"
	else
		content.Visible = true
		frame.Size = UDim2.new(0,260,0,230)
		miniBtn.Text = "–"
	end
end)

-------------------------------------------------
-- TELEPORT LOGIC
-------------------------------------------------

local function startTP()
	savedPosition = hrp.Position
	running = true

	task.spawn(function()
		while running do

			local radius = tonumber(distanceBox.Text) or 15
			local speed = tonumber(speedBox.Text) or 0.08
			local voidChance = tonumber(voidBox.Text) or 25

			angle += math.rad(25)

			local x = math.cos(angle) * radius
			local z = math.sin(angle) * radius

			if math.random(1,100) <= voidChance then

				local original = hrp.CFrame
				hrp.CFrame = CFrame.new(original.Position.X, -400, original.Position.Z)
				task.wait(math.random(1,3)/10)
				hrp.CFrame = original

			else
				local newPos = savedPosition + Vector3.new(x,0,z)
				hrp.CFrame = CFrame.new(newPos)
			end

			task.wait(speed)
		end
	end)
end

local function stopTP()
	running = false
	if savedPosition then
		hrp.CFrame = CFrame.new(savedPosition)
	end
	button.Text = "START"
	button.BackgroundColor3 = Color3.fromRGB(0,170,0)
end

button.MouseButton1Click:Connect(function()
	if not running then
		button.Text = "STOP"
		button.BackgroundColor3 = Color3.fromRGB(170,0,0)
		startTP()
	else
		stopTP()
	end
end)
