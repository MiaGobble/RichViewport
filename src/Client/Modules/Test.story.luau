local Story = {}

-- Constants
local CORNER_OFFSETS = {
	Vector3.new(-1, -1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, 1, 1),
}

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Imports
local Modules = script.Parent
local Packages = Modules.Packages
local Seam = require(Packages.Seam)
local SeamStoryUtils = require(Packages.SeamStoryUtils)
local UILabs = require(Packages.UILabs)

Story.controls = {
	FieldOfView = UILabs.Slider(70, 1, 120),
	CameraDistance = UILabs.Slider(8, 0.5, 50),
	ViewportScale = UILabs.Slider(1, 0.1, 1),
	RotationX = UILabs.Slider(0, -180, 180),
	RotationY = UILabs.Slider(0, -180, 180),
	RotationZ = UILabs.Slider(0, -180, 180),
}

local function CollectParts(Root : Instance) : {BasePart}
	local Parts = {}

	if Root:IsA("BasePart") then
		table.insert(Parts, Root)
	end

	for _, Descendant in Root:GetDescendants() do
		if Descendant:IsA("BasePart") then
			table.insert(Parts, Descendant)
		end
	end

	return Parts
end

local function GetPartScreenBounds(Camera : Camera, Part : BasePart) : (number?, number?, number?, number?, number?)
	local HalfSize = Part.Size * 0.5
	local PartCFrame = Part.CFrame

	local MinX = math.huge
	local MinY = math.huge
	local MaxX = -math.huge
	local MaxY = -math.huge
	local DepthSum = 0
	local SampleCount = 0

	for _, Offset in CORNER_OFFSETS do
		local WorldPoint = PartCFrame:PointToWorldSpace(Offset * HalfSize)
		local ScreenPoint = Camera:WorldToViewportPoint(WorldPoint)

		if ScreenPoint.Z <= 0 then
			continue
		end

		MinX = math.min(MinX, ScreenPoint.X)
		MinY = math.min(MinY, ScreenPoint.Y)
		MaxX = math.max(MaxX, ScreenPoint.X)
		MaxY = math.max(MaxY, ScreenPoint.Y)
		DepthSum += ScreenPoint.Z
		SampleCount += 1
	end

	if SampleCount == 0 then
		return nil
	end

	return MinX, MinY, MaxX - MinX, MaxY - MinY, DepthSum / SampleCount
end

local function UpdatePartBoundsFrames(Viewport : ViewportFrame, Camera : Camera, Parts : {BasePart}, FramesByPart : {[BasePart] : Frame})
	local AbsoluteSize = Viewport.AbsoluteSize
	if AbsoluteSize.X <= 0 or AbsoluteSize.Y <= 0 then
		return
	end

	local Ranked = {}

	for _, Part in Parts do
		local Frame = FramesByPart[Part]
		if not Frame then
			Frame = Instance.new("Frame")
			Frame.Name = `{Part.Name}_Bounds`
			Frame.BackgroundTransparency = 1
			Frame.BorderSizePixel = 0
			Frame.Parent = Viewport

			local Stroke = Instance.new("UIStroke")
			Stroke.Thickness = 1
			Stroke.Color = Color3.fromRGB(0, 255, 140)
			Stroke.Parent = Frame

			FramesByPart[Part] = Frame
		end

		local X, Y, Width, Height, Depth = GetPartScreenBounds(Camera, Part)
		if not X then
			Frame.Visible = false
			continue
		end

		Frame.Visible = true
		Frame.Position = UDim2.fromOffset(X, Y)
		Frame.Size = UDim2.fromOffset(Width, Height)

		table.insert(Ranked, {
			Frame = Frame,
			Depth = Depth :: number,
		})
	end

	table.sort(Ranked, function(A, B)
		return A.Depth > B.Depth
	end)

	for Index, Entry in Ranked do
		Entry.Frame.ZIndex = Index
	end
end

function Story.render(props)
	local Scope = Seam.Scope(Seam)
	local Controls = SeamStoryUtils.GetValuesFromControls(Scope, props)

	local TestAssets = ReplicatedStorage:WaitForChild("TestAsset")
	local SourceAsset = TestAssets:GetChildren()[1]
	assert(SourceAsset, "ReplicatedStorage.TestAsset has no children")

	local Asset = SourceAsset:Clone()
	local Parts = CollectParts(Asset)
	local FramesByPart : {[BasePart] : Frame} = {}

	local Camera = Scope:New("Camera", {
		Name = "ViewportCamera",
		FieldOfView = Controls.FieldOfView.Value,
	})

	local Viewport = Scope:New("ViewportFrame", {
		Name = "AssetViewport",
		Parent = props.target,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(20, 20, 24),
		BorderSizePixel = 0,
		CurrentCamera = Camera,

		Size = Scope:Computed(function(use)
			local Scale = use(Controls.ViewportScale)
			return UDim2.fromScale(Scale, Scale)
		end),

		[Seam.Children] = {
			Camera,
			Asset,
		},
	})

	local function RefreshViewport()
		Asset:PivotTo(CFrame.fromEulerAnglesXYZ(
            math.rad(Controls.RotationX.Value),
            math.rad(Controls.RotationY.Value),
            math.rad(Controls.RotationZ.Value)
		))

		local BoundsCFrame = if Asset:IsA("Model")
			then select(1, Asset:GetBoundingBox())
			elseif Asset:IsA("BasePart") then Asset.CFrame
			else CFrame.new()

		local Focus = BoundsCFrame.Position

		Camera.FieldOfView = Controls.FieldOfView.Value
		Camera.CFrame = CFrame.lookAt(Focus + Vector3.new(0, 0, Controls.CameraDistance.Value), Focus)

		UpdatePartBoundsFrames(Viewport, Camera, Parts, FramesByPart)
	end

	Scope:OnChanged(Viewport, function(Property)
		if Property ~= "AbsoluteSize" then
			return
		end

		RefreshViewport()
	end)

	for _, Control in Controls do
		Scope:OnChanged(Control, RefreshViewport)
	end

	RefreshViewport()

	return SeamStoryUtils.WrappedScopeCleanup(Scope)
end

return Story
