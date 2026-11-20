local Story = {}

-- Constants
local BOUNDS_BACKGROUND_TRANSPARENCY = 0.85
local BOUNDS_STROKE_TRANSPARENCY = 0
local VIEWPORT_BACKGROUND_COLOR = Color3.fromRGB(20, 20, 24)

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Imports
local Modules = script.Parent
local Packages = Modules.Packages
local Seam = require(Packages.Seam)
local SeamStoryUtils = require(Packages.SeamStoryUtils)
local UILabs = require(Packages.UILabs)
local ViewportParticles = require(Modules.ViewportParticles)

Story.controls = {
	FieldOfView = UILabs.Slider(70, 1, 120),
	CameraDistance = UILabs.Slider(8, 0.5, 50),
	ViewportScale = UILabs.Slider(1, 0.1, 1),
	RotationX = UILabs.Slider(0, -180, 180),
	RotationY = UILabs.Slider(0, -180, 180),
	RotationZ = UILabs.Slider(0, -180, 180),
	ShowBounds = true,
	ShowParticles = true,
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

local function UpdateEmitFrame(Scope : any, Frame : Frame, Bounds : ViewportParticles.ScreenBounds)
	Scope:New(Frame, {
		Visible = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(Bounds.CenterX, Bounds.CenterY),
		Size = UDim2.fromOffset(Bounds.Width, Bounds.Height),
		Rotation = 0,
		BackgroundTransparency = 1,
		ClipsDescendants = false,
	})
end

local function UpdateGuideFrame(Scope : any, Frame : Frame, Stroke : UIStroke?, Bounds : ViewportParticles.OrientedScreenBounds, ShowBounds : boolean)
	local BackgroundTransparency = if ShowBounds then BOUNDS_BACKGROUND_TRANSPARENCY else 1
	local StrokeTransparency = if ShowBounds then BOUNDS_STROKE_TRANSPARENCY else 1

	Scope:New(Frame, {
		Visible = ShowBounds,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(Bounds.CenterX, Bounds.CenterY),
		Size = UDim2.fromOffset(Bounds.Width, Bounds.Height),
		Rotation = Bounds.Rotation,
		BackgroundTransparency = BackgroundTransparency,
		ClipsDescendants = false,
	})

	if not Stroke then
		return
	end

	Scope:New(Stroke, {
		Transparency = StrokeTransparency,
	})
end

local function UpdatePartBoundsFrames(Scope : any, Viewport : ViewportFrame, Camera : Camera, Parts : {BasePart}, FramesByPart : {[BasePart] : ViewportParticles.PartFrames}, MimicBindings : {ViewportParticles.MimicBinding}, ShowBounds : boolean, ShowParticles : boolean)
	local PixelSize = Viewport.AbsoluteSize
	if PixelSize.X <= 0 or PixelSize.Y <= 0 then
		return
	end

	local DepthByPart : {[BasePart] : number} = {}
	local BoundsByPart : {[BasePart] : ViewportParticles.ScreenBounds} = {}
	local Ranked = {}

	for _, Part in Parts do
		local Frames = FramesByPart[Part]
		local GuideStroke = Frames.Guide:FindFirstChildWhichIsA("UIStroke")
		local PartBounds = ViewportParticles.GetPartScreenBounds(Camera, Part, PixelSize)

		if not PartBounds then
			Scope:New(Frames.Front, {Visible = false})
			Scope:New(Frames.Behind, {Visible = false})
			Scope:New(Frames.Guide, {Visible = false})
			continue
		end

		DepthByPart[Part] = PartBounds.Emit.Depth
		BoundsByPart[Part] = PartBounds.Emit

		UpdateEmitFrame(Scope, Frames.Front, PartBounds.Emit)
		UpdateEmitFrame(Scope, Frames.Behind, PartBounds.Emit)
		UpdateGuideFrame(Scope, Frames.Guide, GuideStroke, PartBounds.Guide, ShowBounds)

		table.insert(Ranked, {
			Front = Frames.Front,
			Behind = Frames.Behind,
			Guide = Frames.Guide,
			Depth = PartBounds.Emit.Depth,
		})
	end

	-- Farthest parts first (low ZIndex); nearest last (high ZIndex) within each overlay.
	table.sort(Ranked, function(A, B)
		return A.Depth > B.Depth
	end)

	for Index, Entry in Ranked do
		Scope:New(Entry.Behind, {ZIndex = Index})
		Scope:New(Entry.Front, {ZIndex = Index})
		Scope:New(Entry.Guide, {ZIndex = Index})
	end

	ViewportParticles.UpdateMimics(Scope, MimicBindings, Camera, PixelSize, DepthByPart, BoundsByPart, ShowParticles)
end

function Story.render(props)
	local Scope = Seam.Scope(Seam)
	local Controls = SeamStoryUtils.GetValuesFromControls(Scope, props)

	local TestAssets = ReplicatedStorage:WaitForChild("TestAsset")
	local SourceAsset = TestAssets:GetChildren()[1]
	assert(SourceAsset, "ReplicatedStorage.TestAsset has no children")

	local Asset = SourceAsset:Clone()
	local Parts = CollectParts(Asset)
	local FramesByPart : {[BasePart] : ViewportParticles.PartFrames} = {}

	local Camera = Scope:New("Camera", {
		Name = "ViewportCamera",
		FieldOfView = Controls.FieldOfView.Value,
	})

	local BehindOverlay = Scope:New("Frame", {
		Name = "BehindOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1,
	})

	local Viewport = Scope:New("ViewportFrame", {
		Name = "AssetViewport",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CurrentCamera = Camera,
		ZIndex = 2,

		[Seam.Children] = {
			Camera,
			Asset,
		},
	})

	local FrontOverlay = Scope:New("Frame", {
		Name = "FrontOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 3,
	})

	for _, Part in Parts do
		local Behind = Scope:New("Frame", {
			Name = `{Part.Name}_Behind`,
			Parent = BehindOverlay,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = false,
			Visible = false,
		})

		local Front = Scope:New("Frame", {
			Name = `{Part.Name}_Front`,
			Parent = FrontOverlay,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = false,
			Visible = false,
		})

		local Guide = Scope:New("Frame", {
			Name = `{Part.Name}_Guide`,
			Parent = FrontOverlay,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(0, 255, 140),
			BackgroundTransparency = 0.85,
			BorderSizePixel = 0,
			ClipsDescendants = false,
			Visible = false,

			[Seam.Children] = {
				Scope:New("UIStroke", {
					Thickness = 1,
					Color = Color3.fromRGB(0, 255, 140),
				}),
			},
		})

		FramesByPart[Part] = {
			Front = Front,
			Behind = Behind,
			Guide = Guide,
		}
	end

	local MimicBindings = ViewportParticles.AttachToBoundsFrames(Scope, Asset, FramesByPart, 40)

	Scope:New("Frame", {
		Name = "ViewportRoot",
		Parent = props.target,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = VIEWPORT_BACKGROUND_COLOR,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,

		Size = Scope:Computed(function(use)
			local Scale = use(Controls.ViewportScale)
			return UDim2.fromScale(Scale, Scale)
		end),

		[Seam.Children] = {
			BehindOverlay,
			Viewport,
			FrontOverlay,
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

		UpdatePartBoundsFrames(
			Scope,
			Viewport,
			Camera,
			Parts,
			FramesByPart,
			MimicBindings,
			Controls.ShowBounds.Value,
			Controls.ShowParticles.Value
		)
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
