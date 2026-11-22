--[=[
	Behind / viewport / front overlay stack and per-part emit + debug guide frames.

	@class Overlays
]=]

local Overlays = {}

-- Types
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

-- Constants
const BOUNDS_BACKGROUND_TRANSPARENCY = 0.85
const BOUNDS_STROKE_TRANSPARENCY = 0
const GUIDE_COLOR = Color3.fromRGB(0, 255, 140)

-- Imports
local Packages = script.Parent.Parent
local Seam = require(Packages.Seam)
local Spatial = require(script.Parent.Spatial)

local function StripParticleEmitters(root : Instance)
	if root:IsA("ParticleEmitter") then
		root:Destroy()
		return
	end

	for _, emitter in root:QueryDescendants("ParticleEmitter") do
		emitter:Destroy()
	end
end

local function CreateGuide(scope : any, parent : Frame, name : string) : Frame
	return scope:New("Frame", {
		Name = name,
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = GUIDE_COLOR,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,

		[Seam.Children] = {
			scope:New("UIStroke", {
				Thickness = 1,
				Color = GUIDE_COLOR,
				Transparency = 1,
			}),
		},
	})
end

local function ApplyLayerTransform(scope : any, frame : Frame, bounds : Spatial.LayerBounds)
	scope:New(frame, {
		Visible = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(bounds.CenterX, bounds.CenterY),
		Size = UDim2.fromOffset(bounds.Width, bounds.Height),
		Rotation = bounds.Rotation,
		BackgroundTransparency = 1,
		ClipsDescendants = false,
	})
end

--[=[
	Builds the transparent viewport sandwich under `Parent`.

	@within Overlays
]=]

function Overlays.CreateStack(scope : any, parent : GuiObject, camera : Camera) : OverlayStack
	local Behind = scope:New("Frame", {
		Name = "BehindOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1,
	})

	local Viewport = scope:New("ViewportFrame", {
		Name = "Viewport",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CurrentCamera = camera,
		ZIndex = 2,
	})

	local Front = scope:New("Frame", {
		Name = "FrontOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 3,
	})

	local LayerStack = scope:New("Frame", {
		Name = "LayerStack",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 1,
	})

	local SourceHolder = scope:New("Folder", {
		Name = "SourceHolder",
	})

	local Root = scope:New("Frame", {
		Name = "RichViewportRoot",
		Parent = parent,
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

--[=[
	Creates Front/Behind emission hosts for shared (non-layered) mode.

	@within Overlays
]=]

function Overlays.CreatePartFrames(scope : any, part : BasePart, behindOverlay : Frame, frontOverlay : Frame) : PartFrames
	local Behind = scope:New("Frame", {
		Name = `{part.Name}_Behind`,
		Parent = behindOverlay,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,
	})

	local Front = scope:New("Frame", {
		Name = `{part.Name}_Front`,
		Parent = frontOverlay,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,
	})

	return {
		Front = Front,
		Behind = Behind,
		Guide = CreateGuide(scope, Front, `{part.Name}_Guide`),
	}
end

--[=[
	Creates Behind → Viewport → Front siblings for one part (base-part layering mode).

	The viewport holds a particle-free visual clone of `Part`. All siblings share one
	parent so ZIndex can interleave meshes and particles by depth.

	@within Overlays
]=]

function Overlays.CreatePartLayerSlice(scope : any, part : BasePart, parent : GuiObject, camera : Camera) : PartFrames
	local Behind = scope:New("Frame", {
		Name = `{part.Name}_Behind`,
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,
	})

	local Viewport = scope:New("ViewportFrame", {
		Name = `{part.Name}_Viewport`,
		Parent = parent,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CurrentCamera = camera,
	})

	local Front = scope:New("Frame", {
		Name = `{part.Name}_Front`,
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
		Visible = false,
	})

	local Visual = part:Clone()
	StripParticleEmitters(Visual)
	Visual.Parent = Viewport

	return {
		Front = Front,
		Behind = Behind,
		Guide = CreateGuide(scope, Front, `{part.Name}_Guide`),
		Viewport = Viewport,
		Visual = Visual,
	}
end

--[=[
	Copies transform / appearance from the source part onto its layer visual.

	@within Overlays
]=]

function Overlays.SyncPartVisual(visual : BasePart, source : BasePart)
	visual.CFrame = source.CFrame
	visual.Size = source.Size
	visual.Color = source.Color
	visual.Transparency = source.Transparency
	visual.Material = source.Material
	visual.MaterialVariant = source.MaterialVariant
	visual.Reflectance = source.Reflectance
	visual.CastShadow = source.CastShadow

	if visual:IsA("MeshPart") and source:IsA("MeshPart") then
		visual.TextureID = source.TextureID
	end
end

--[=[
	Applies the same layer bounds to Front and Behind. Guide stays nested full-size on Front.

	@within Overlays
]=]

function Overlays.UpdatePartFrames(scope : any, frames : PartFrames, bounds : Spatial.LayerBounds, isDebugVisible : boolean)
	ApplyLayerTransform(scope, frames.Front, bounds)
	ApplyLayerTransform(scope, frames.Behind, bounds)

	local BackgroundTransparency = if isDebugVisible then BOUNDS_BACKGROUND_TRANSPARENCY else 1
	local StrokeTransparency = if isDebugVisible then BOUNDS_STROKE_TRANSPARENCY else 1
	local Stroke = frames.Guide:FindFirstChildWhichIsA("UIStroke")

	scope:New(frames.Guide, {
		Visible = isDebugVisible,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Rotation = 0,
		BackgroundColor3 = GUIDE_COLOR,
		BackgroundTransparency = BackgroundTransparency,
		ClipsDescendants = false,
	})

	if Stroke then
		scope:New(Stroke, {
			Transparency = StrokeTransparency,
		})
	end
end

--[=[
	Hides emit + guide frames for a part that is off-screen or unprojectable.

	@within Overlays
]=]

function Overlays.HidePartFrames(scope : any, frames : PartFrames)
	scope:New(frames.Front, {Visible = false,})
	scope:New(frames.Behind, {Visible = false,})
	scope:New(frames.Guide, {Visible = false,})
end

--[=[
	Assigns ZIndex by depth for shared mode (emit hosts only).

	@within Overlays
]=]

function Overlays.ApplyDepthRanking(scope : any, ranked : {{Front : Frame, Behind : Frame, Depth : number}})
	table.sort(ranked, function(a, b)
		return a.Depth > b.Depth
	end)

	for index, entry in ranked do
		scope:New(entry.Behind, {ZIndex = index,})
		scope:New(entry.Front, {ZIndex = index,})
	end
end

--[=[
	Interleaves Behind / Viewport / Front ZIndex per part (farthest first).

	@within Overlays
]=]

function Overlays.ApplyLayeredDepthRanking(scope : any, ranked : {{Front : Frame, Behind : Frame, Viewport : ViewportFrame, Depth : number}})
	table.sort(ranked, function(a, b)
		return a.Depth > b.Depth
	end)

	for index, entry in ranked do
		local Base = (index - 1) * 3

		scope:New(entry.Behind, {ZIndex = Base + 1,})
		scope:New(entry.Viewport, {ZIndex = Base + 2,})
		scope:New(entry.Front, {ZIndex = Base + 3,})
	end
end

return Overlays