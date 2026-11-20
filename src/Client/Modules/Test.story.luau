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

local BOUNDS_BACKGROUND_TRANSPARENCY = 0.85
local BOUNDS_STROKE_TRANSPARENCY = 0

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
	ShowBounds = true,
}

local function CollectParts(Root : Instance) : {BasePart}
	local Parts = {}

	if Root:IsA("BasePart") then
		table.insert(Parts, Root)
	end

	for _, Descendant in Root:QueryDescendants("BasePart") do
		table.insert(Parts, Descendant)
	end

	return Parts
end

-- ViewportFrame cameras keep ViewportSize at (1, 1), so WorldToViewportPoint
-- projects with a wrong aspect ratio. Project manually against AbsoluteSize instead.
local function WorldToViewportPixels(Camera : Camera, WorldPoint : Vector3, PixelSize : Vector2) : (number?, number?, number?)
	local Relative = Camera.CFrame:PointToObjectSpace(WorldPoint)
	local Depth = -Relative.Z

	if Depth <= 0 then
		return nil
	end

	local AspectRatio = PixelSize.X / PixelSize.Y
	local HalfHeight = math.tan(math.rad(Camera.FieldOfView) * 0.5) * Depth
	local HalfWidth = HalfHeight * AspectRatio

	local ScreenX = (Relative.X / HalfWidth * 0.5 + 0.5) * PixelSize.X
	local ScreenY = (-Relative.Y / HalfHeight * 0.5 + 0.5) * PixelSize.Y

	return ScreenX, ScreenY, Depth
end

local function GetPartScreenBounds(Camera : Camera, Part : BasePart, PixelSize : Vector2) : (number?, number?, number?, number?, number?)
	if PixelSize.X <= 0 or PixelSize.Y <= 0 then
		return nil
	end

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
		local PixelX, PixelY, Depth = WorldToViewportPixels(Camera, WorldPoint, PixelSize)

		if not PixelX then
			continue
		end

		MinX = math.min(MinX, PixelX)
		MinY = math.min(MinY, PixelY)
		MaxX = math.max(MaxX, PixelX)
		MaxY = math.max(MaxY, PixelY)
		DepthSum += Depth :: number
		SampleCount += 1
	end

	if SampleCount == 0 then
		return nil
	end

	return MinX, MinY, MaxX - MinX, MaxY - MinY, DepthSum / SampleCount
end

local function UpdatePartBoundsFrames(Scope : any, Viewport : ViewportFrame, Camera : Camera, Parts : {BasePart}, FramesByPart : {[BasePart] : Frame}, ShowBounds : boolean)
	local PixelSize = Viewport.AbsoluteSize
	if PixelSize.X <= 0 or PixelSize.Y <= 0 then
		return
	end

	local BackgroundTransparency = if ShowBounds then BOUNDS_BACKGROUND_TRANSPARENCY else 1
	local StrokeTransparency = if ShowBounds then BOUNDS_STROKE_TRANSPARENCY else 1
	local Ranked = {}

	for _, Part in Parts do
		local Frame = FramesByPart[Part]
		local Stroke = Frame:FindFirstChildWhichIsA("UIStroke")
		local X, Y, Width, Height, Depth = GetPartScreenBounds(Camera, Part, PixelSize)

		if not X then
			Scope:New(Frame, {
				Visible = false,
			})
			continue
		end

		Scope:New(Frame, {
			Visible = true,
			Position = UDim2.fromOffset(X, Y),
			Size = UDim2.fromOffset(math.max(Width, 1), math.max(Height, 1)),
			BackgroundTransparency = BackgroundTransparency,
		})

		if Stroke then
			Scope:New(Stroke, {
				Transparency = StrokeTransparency,
			})
		end

		table.insert(Ranked, {
			Frame = Frame,
			Depth = Depth :: number,
		})
	end

	table.sort(Ranked, function(A, B)
		return A.Depth > B.Depth
	end)

	for Index, Entry in Ranked do
		Scope:New(Entry.Frame, {
			ZIndex = Index,
		})
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
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(20, 20, 24),
		BorderSizePixel = 0,
		CurrentCamera = Camera,
		ZIndex = 1,

		[Seam.Children] = {
			Camera,
			Asset,
		},
	})

	local Overlay = Scope:New("Frame", {
		Name = "BoundsOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 2,
	})

	for _, Part in Parts do
		FramesByPart[Part] = Scope:New("Frame", {
			Name = `{Part.Name}_Bounds`,
			Parent = Overlay,
			BackgroundColor3 = Color3.fromRGB(0, 255, 140),
			BackgroundTransparency = 0.85,
			BorderSizePixel = 0,
			Visible = false,

			[Seam.Children] = {
				Scope:New("UIStroke", {
					Thickness = 1,
					Color = Color3.fromRGB(0, 255, 140),
				}),
			},
		})
	end

	Scope:New("Frame", {
		Name = "ViewportRoot",
		Parent = props.target,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		Size = Scope:Computed(function(use)
			local Scale = use(Controls.ViewportScale)
			return UDim2.fromScale(Scale, Scale)
		end),

		[Seam.Children] = {
			Viewport,
			Overlay,
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

		UpdatePartBoundsFrames(Scope, Viewport, Camera, Parts, FramesByPart, Controls.ShowBounds.Value)
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
	task.defer(RefreshViewport)

	return SeamStoryUtils.WrappedScopeCleanup(Scope)
end

return Story
