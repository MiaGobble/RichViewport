--[=[
	Behind / viewport / front overlay stack and per-part emit + debug guide frames.

	@class Overlays
]=]

local Overlays = {}

local Packages = script.Parent.Parent
local Seam = require(Packages.Seam)
local Spatial = require(script.Parent.Spatial)

export type PartFrames = {
	Front : Frame,
	Behind : Frame,
	Guide : Frame,
	Viewport : ViewportFrame?,
	Visual : BasePart?,
}

export type OverlayStack = {
	Root : Frame,
	Behind : Frame,
	Viewport : ViewportFrame,
	Front : Frame,
	LayerStack : Frame,
	SourceHolder : Folder,
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

	local LayerStack = Scope:New("Frame", {
		Name = "LayerStack",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 1,
	})

	local SourceHolder = Scope:New("Folder", {
		Name = "SourceHolder",
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
			LayerStack,
			SourceHolder,
		},
	})

	return {
		Root = Root,
		Behind = Behind,
		Viewport = Viewport,
		Front = Front,
		LayerStack = LayerStack,
		SourceHolder = SourceHolder,
	}
end

local function StripParticleEmitters(Root : Instance)
	if Root:IsA("ParticleEmitter") then
		Root:Destroy()
		return
	end

	for _, Emitter in Root:QueryDescendants("ParticleEmitter") do
		Emitter:Destroy()
	end
end

local function CreateGuide(Scope : any, Parent : Frame, Name : string) : Frame
	return Scope:New("Frame", {
		Name = Name,
		Parent = Parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
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
end

--[=[
	Creates Front/Behind emission hosts for shared (non-layered) mode.

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

	return {
		Front = Front,
		Behind = Behind,
		Guide = CreateGuide(Scope, Front, `{Part.Name}_Guide`),
	}
end

--[=[
	Creates Behind → Viewport → Front siblings for one part (base-part layering mode).

	The viewport holds a particle-free visual clone of `Part`. All siblings share one
	parent so ZIndex can interleave meshes and particles by depth.

	@within Overlays
]=]
function Overlays.CreatePartLayerSlice(Scope : any, Part : BasePart, Parent : GuiObject, Camera : Camera) : PartFrames
	local Behind = Scope:New("Frame", {
		Name = `{Part.Name}_Behind`,
		Parent = Parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,
	})

	local Viewport = Scope:New("ViewportFrame", {
		Name = `{Part.Name}_Viewport`,
		Parent = Parent,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CurrentCamera = Camera,
	})

	local Front = Scope:New("Frame", {
		Name = `{Part.Name}_Front`,
		Parent = Parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,
	})

	local Visual = Part:Clone()
	StripParticleEmitters(Visual)
	Visual.Parent = Viewport

	return {
		Front = Front,
		Behind = Behind,
		Guide = CreateGuide(Scope, Front, `{Part.Name}_Guide`),
		Viewport = Viewport,
		Visual = Visual,
	}
end

--[=[
	Copies transform / appearance from the source part onto its layer visual.

	@within Overlays
]=]
function Overlays.SyncPartVisual(Visual : BasePart, Source : BasePart)
	Visual.CFrame = Source.CFrame
	Visual.Size = Source.Size
	Visual.Color = Source.Color
	Visual.Transparency = Source.Transparency
	Visual.Material = Source.Material
	Visual.MaterialVariant = Source.MaterialVariant
	Visual.Reflectance = Source.Reflectance
	Visual.CastShadow = Source.CastShadow

	if Visual:IsA("MeshPart") and Source:IsA("MeshPart") then
		Visual.TextureID = Source.TextureID
	end
end

local function ApplyLayerTransform(Scope : any, Frame : Frame, Bounds : Spatial.LayerBounds)
	Scope:New(Frame, {
		Visible = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(Bounds.CenterX, Bounds.CenterY),
		Size = UDim2.fromOffset(Bounds.Width, Bounds.Height),
		Rotation = Bounds.Rotation,
		BackgroundTransparency = 1,
		ClipsDescendants = false,
	})
end

--[=[
	Applies the same layer bounds to Front and Behind. Guide stays nested full-size on Front.

	@within Overlays
]=]
function Overlays.UpdatePartFrames(Scope : any, Frames : PartFrames, Bounds : Spatial.LayerBounds, ShowDebug : boolean)
	ApplyLayerTransform(Scope, Frames.Front, Bounds)
	ApplyLayerTransform(Scope, Frames.Behind, Bounds)

	local BackgroundTransparency = if ShowDebug then BOUNDS_BACKGROUND_TRANSPARENCY else 1
	local StrokeTransparency = if ShowDebug then BOUNDS_STROKE_TRANSPARENCY else 1
	local Stroke = Frames.Guide:FindFirstChildWhichIsA("UIStroke")

	Scope:New(Frames.Guide, {
		Visible = ShowDebug,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Rotation = 0,
		BackgroundColor3 = GUIDE_COLOR,
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
	Assigns ZIndex by depth for shared mode (emit hosts only).

	@within Overlays
]=]
function Overlays.ApplyDepthRanking(Scope : any, Ranked : {{Front : Frame, Behind : Frame, Depth : number}})
	table.sort(Ranked, function(A, B)
		return A.Depth > B.Depth
	end)

	for Index, Entry in Ranked do
		Scope:New(Entry.Behind, {ZIndex = Index})
		Scope:New(Entry.Front, {ZIndex = Index})
	end
end

--[=[
	Interleaves Behind / Viewport / Front ZIndex per part (farthest first).

	@within Overlays
]=]
function Overlays.ApplyLayeredDepthRanking(Scope : any, Ranked : {{Front : Frame, Behind : Frame, Viewport : ViewportFrame, Depth : number}})
	table.sort(Ranked, function(A, B)
		return A.Depth > B.Depth
	end)

	for Index, Entry in Ranked do
		local Base = (Index - 1) * 3

		Scope:New(Entry.Behind, {ZIndex = Base + 1})
		Scope:New(Entry.Viewport, {ZIndex = Base + 2})
		Scope:New(Entry.Front, {ZIndex = Base + 3})
	end
end

return Overlays
