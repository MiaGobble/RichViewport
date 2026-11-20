--[=[
	Behind / viewport / front overlay stack and per-part emit + debug guide frames.

	@class Overlays
]=]

local Overlays = {}

local Packages = script.Parent.Parent.Packages
local Seam = require(Packages.Seam)
local Spatial = require(script.Parent.Spatial)

export type PartFrames = {
	Front : Frame,
	Behind : Frame,
	Guide : Frame,
}

export type OverlayStack = {
	Root : Frame,
	Behind : Frame,
	Viewport : ViewportFrame,
	Front : Frame,
}

local BOUNDS_BACKGROUND_TRANSPARENCY = 0.85
local BOUNDS_STROKE_TRANSPARENCY = 0
local GUIDE_COLOR = Color3.fromRGB(0, 255, 140)

--[=[
	Builds the transparent viewport sandwich under `Parent`.

	@within Overlays
]=]
function Overlays.CreateStack(Scope : any, Parent : GuiObject, Camera : Camera) : OverlayStack
	local Behind = Scope:New("Frame", {
		Name = "BehindOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1,
	})

	local Viewport = Scope:New("ViewportFrame", {
		Name = "Viewport",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CurrentCamera = Camera,
		ZIndex = 2,
	})

	local Front = Scope:New("Frame", {
		Name = "FrontOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 3,
	})

	local Root = Scope:New("Frame", {
		Name = "RichViewportRoot",
		Parent = Parent,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Seam.Children] = {
			Behind,
			Viewport,
			Front,
		},
	})

	return {
		Root = Root,
		Behind = Behind,
		Viewport = Viewport,
		Front = Front,
	}
end

--[=[
	Creates unrotated emission hosts plus an oriented debug guide for one part.

	@within Overlays
]=]
function Overlays.CreatePartFrames(Scope : any, Part : BasePart, BehindOverlay : Frame, FrontOverlay : Frame) : PartFrames
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
		BackgroundColor3 = GUIDE_COLOR,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,

		[Seam.Children] = {
			Scope:New("UIStroke", {
				Thickness = 1,
				Color = GUIDE_COLOR,
				Transparency = 1,
			}),
		},
	})

	return {
		Front = Front,
		Behind = Behind,
		Guide = Guide,
	}
end

--[=[
	Positions an unrotated emission host from screen AABB bounds.

	@within Overlays
]=]
function Overlays.UpdateEmitFrame(Scope : any, Frame : Frame, Bounds : Spatial.ScreenBounds)
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

--[=[
	Positions the oriented debug guide. Hidden when `ShowDebug` is false.

	@within Overlays
]=]
function Overlays.UpdateGuideFrame(Scope : any, Frame : Frame, Bounds : Spatial.OrientedScreenBounds, ShowDebug : boolean)
	local BackgroundTransparency = if ShowDebug then BOUNDS_BACKGROUND_TRANSPARENCY else 1
	local StrokeTransparency = if ShowDebug then BOUNDS_STROKE_TRANSPARENCY else 1
	local Stroke = Frame:FindFirstChildWhichIsA("UIStroke")

	Scope:New(Frame, {
		Visible = ShowDebug,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(Bounds.CenterX, Bounds.CenterY),
		Size = UDim2.fromOffset(Bounds.Width, Bounds.Height),
		Rotation = Bounds.Rotation,
		BackgroundTransparency = BackgroundTransparency,
		ClipsDescendants = false,
	})

	if Stroke then
		Scope:New(Stroke, {
			Transparency = StrokeTransparency,
		})
	end
end

--[=[
	Hides emit + guide frames for a part that is off-screen or unprojectable.

	@within Overlays
]=]
function Overlays.HidePartFrames(Scope : any, Frames : PartFrames)
	Scope:New(Frames.Front, {Visible = false})
	Scope:New(Frames.Behind, {Visible = false})
	Scope:New(Frames.Guide, {Visible = false})
end

--[=[
	Assigns ZIndex by depth (farthest first / lowest index).

	@within Overlays
]=]
function Overlays.ApplyDepthRanking(Scope : any, Ranked : {{Front : Frame, Behind : Frame, Guide : Frame, Depth : number}})
	table.sort(Ranked, function(A, B)
		return A.Depth > B.Depth
	end)

	for Index, Entry in Ranked do
		Scope:New(Entry.Behind, {ZIndex = Index})
		Scope:New(Entry.Front, {ZIndex = Index})
		Scope:New(Entry.Guide, {ZIndex = Index})
	end
end

return Overlays
