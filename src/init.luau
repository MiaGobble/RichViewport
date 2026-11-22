--[=[
	ViewportFrame wrapper with depth-aware particle mimics and optional debug bounds.

	Clones the given object into a transparent viewport, watches camera / object /
	size changes, and keeps overlay emission hosts in sync.

	```lua
	local View = RichViewport.new(sourceModel, camera, parentFrame)
	View:ShowDebug()
	View.Object:PivotTo(CFrame.Angles(0, math.rad(45), 0))
	View:Destroy()
	```

	@class RichViewport
]=]

local RichViewport = {}
RichViewport.__index = RichViewport

-- Imports
local Packages = script.Parent
local Seam = require(Packages.Seam)
local Spatial = require(script.Spatial)
local Overlays = require(script.Overlays)
local Particles = require(script.Particles)

-- Types extended
type Fields = {
	Object : Instance,
	Camera : Camera,
	Parent : GuiObject,
	ViewportFrame : ViewportFrame,
	Scope : any,
	Destroyed : RBXScriptSignal,
	Refreshed : RBXScriptSignal,

	_Root : Frame,
	_BehindOverlay : Frame,
	_FrontOverlay : Frame,
	_LayerStack : Frame,
	_SourceHolder : Folder,
	_ContentScope : any?,
	_FramesByPart : {[BasePart] : Overlays.PartFrames},
	_MimicBindings : {Particles.MimicBinding},
	_IsDebugVisible : boolean,
	_IsParticlesVisible : boolean,
	_BasePartLayeringCount : number,
	_IsDestroyed : boolean,
	_DestroyedEvent : BindableEvent,
	_RefreshedEvent : BindableEvent,
	_ObjectWatchScope : any?,
	_CameraWatchScope : any?,
	_IsStructureDirty : boolean,
	_IsStructureWatchSuppressed : boolean,
	_LayerRotationByPart : {[BasePart] : number},
}

export type RichViewport = setmetatable<Fields, typeof(RichViewport)>

local function ShouldWatchStructure(instance : Instance) : boolean
	return instance:IsA("BasePart")
		or instance:IsA("Attachment")
		or instance:IsA("ParticleEmitter")
end

--[=[
	Creates a RichViewport. `Object` is **cloned** into the viewport; the live clone
	is exposed as `RichViewport.Object`.

	@param object Instance -- Source instance to clone into the viewport
	@param camera Camera -- Camera driving the ViewportFrame
	@param parent GuiObject -- Parent for the overlay root
	@return RichViewport
	@within RichViewport
]=]

function RichViewport.new(object : Instance, camera : Camera, parent : GuiObject) : RichViewport
	assert(typeof(object) == "Instance", "Object must be an Instance")
	assert(camera:IsA("Camera"), "Camera must be a Camera")
	assert(parent:IsA("GuiObject"), "Parent must be a GuiObject")

	local Scope = Seam.Scope(Seam)
	local DestroyedEvent = Scope:AddObject(Instance.new("BindableEvent"))
	local RefreshedEvent = Scope:AddObject(Instance.new("BindableEvent"))
	DestroyedEvent.Name = "Destroyed"
	RefreshedEvent.Name = "Refreshed"

	local Stack = Overlays.CreateStack(Scope, parent, camera)

	local self : Fields = {
		Object = nil :: any,
		Camera = camera,
		Parent = parent,
		ViewportFrame = Stack.Viewport,
		Scope = Scope,
		Destroyed = DestroyedEvent.Event,
		Refreshed = RefreshedEvent.Event,

		_Root = Stack.Root,
		_BehindOverlay = Stack.Behind,
		_FrontOverlay = Stack.Front,
		_LayerStack = Stack.LayerStack,
		_SourceHolder = Stack.SourceHolder,
		_ContentScope = nil,
		_FramesByPart = {},
		_MimicBindings = {},
		_IsDebugVisible = false,
		_IsParticlesVisible = true,
		_BasePartLayeringCount = 0,
		_IsDestroyed = false,
		_DestroyedEvent = DestroyedEvent,
		_RefreshedEvent = RefreshedEvent,
		_ObjectWatchScope = nil,
		_CameraWatchScope = nil,
		_IsStructureDirty = false,
		_IsStructureWatchSuppressed = false,
		_LayerRotationByPart = {},
	}

	setmetatable(self, RichViewport)
	self:Init(object)

	return self
end

function RichViewport.Init(self : RichViewport, object : Instance)
	self.Scope:OnChanged(self._Root, function(property)
		if property ~= "AbsoluteSize" then
			return
		end

		self:Refresh()
	end)

	RichViewport._BindCameraWatchers(self)
	self:SetObject(object)
	task.defer(function()
		if not self._IsDestroyed then
			self:Refresh()
		end
	end)
end

--[=[
	Forces a bounds + particle mimic update and fires `Refreshed`.

	@within RichViewport
]=]

function RichViewport.Refresh(self : RichViewport)
	if self._IsDestroyed then
		return
	end

	-- Project in root pixel space so Behind/Front overlays share the same origin as the viewport.
	local PixelSize = self._Root.AbsoluteSize

	if PixelSize.X <= 0 or PixelSize.Y <= 0 then
		return
	end

	local DepthByPart : {[BasePart] : number} = {}
	local BoundsByPart : {[BasePart] : Spatial.LayerBounds} = {}
	local Ranked = {}
	local LayeredRanked = {}
	local NextRotations : {[BasePart] : number} = {}
	local Layered = RichViewport.IsBasePartLayeringEnabled(self)

	for part, frames in self._FramesByPart do
		if not part.Parent then
			Overlays.HidePartFrames(self.Scope, frames)
			continue
		end

		local LayerBounds = Spatial.GetPartLayerBounds(
			self.Camera,
			part,
			PixelSize,
			self._LayerRotationByPart[part]
		)

		if not LayerBounds then
			Overlays.HidePartFrames(self.Scope, frames)
			continue
		end

		NextRotations[part] = LayerBounds.Rotation
		DepthByPart[part] = LayerBounds.Depth
		BoundsByPart[part] = LayerBounds

		if frames.Visual and frames.Viewport then
			Overlays.SyncPartVisual(frames.Visual, part)
			frames.Viewport.CurrentCamera = self.Camera
		end

		Overlays.UpdatePartFrames(self.Scope, frames, LayerBounds, self._IsDebugVisible)

		table.insert(Ranked, {
			Front = frames.Front,
			Behind = frames.Behind,
			Depth = LayerBounds.Depth,
		})

		if frames.Viewport then
			table.insert(LayeredRanked, {
				Front = frames.Front,
				Behind = frames.Behind,
				Viewport = frames.Viewport,
				Depth = LayerBounds.Depth,
			})
		end
	end

	self._LayerRotationByPart = NextRotations

	if Layered then
		Overlays.ApplyLayeredDepthRanking(self.Scope, LayeredRanked)
	else
		Overlays.ApplyDepthRanking(self.Scope, Ranked)
	end

	Particles.UpdateMimics(
		self.Scope,
		self._MimicBindings,
		self.Camera,
		PixelSize,
		DepthByPart,
		BoundsByPart,
		self._IsParticlesVisible
	)

	self._RefreshedEvent:Fire()
end

--[=[
	Shows oriented debug bound guides.

	@within RichViewport
]=]

function RichViewport.ShowDebug(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._IsDebugVisible = true
	self:Refresh()
end

--[=[
	Hides oriented debug bound guides.

	@within RichViewport
]=]

function RichViewport.HideDebug(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._IsDebugVisible = false
	self:Refresh()
end

--[=[
	Enables particle mimics (default).

	@within RichViewport
]=]

function RichViewport.ShowParticles(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._IsParticlesVisible = true
	self:Refresh()
end

--[=[
	Disables and clears particle mimics.

	@within RichViewport
]=]

function RichViewport.HideParticles(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._IsParticlesVisible = false
	self:Refresh()
end

--[=[
	Increments the base-part layering counter. While the count is above zero, each
	part renders in its own ViewportFrame interleaved with particle hosts for
	correct mesh occlusion.

	@within RichViewport
]=]

function RichViewport.EnableBasePartLayering(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)

	local IsLayeringActive = RichViewport.IsBasePartLayeringEnabled(self)
	self._BasePartLayeringCount += 1

	if not IsLayeringActive then
		RichViewport._RebuildContent(self)
		self:Refresh()
	end
end

--[=[
	Decrements the base-part layering counter. When the count returns to zero,
	shared single-viewport mode is restored.

	@within RichViewport
]=]

function RichViewport.DisableBasePartLayering(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)

	if self._BasePartLayeringCount <= 0 then
		return
	end

	self._BasePartLayeringCount -= 1

	if not RichViewport.IsBasePartLayeringEnabled(self) then
		RichViewport._RebuildContent(self)
		self:Refresh()
	end
end

--[=[
	Whether base-part layering is currently active (refcount above zero).

	@within RichViewport
]=]

function RichViewport.IsBasePartLayeringEnabled(self : RichViewport) : boolean
	return self._BasePartLayeringCount > 0
end

--[=[
	Rebinds the viewport object. Clones `object` into the viewport and rebuilds content.

	@param object Instance -- Source instance to clone into the viewport
	@within RichViewport
]=]

function RichViewport.SetObject(self : RichViewport, object : Instance)
	RichViewport._AssertNotDestroyed(self)
	assert(typeof(object) == "Instance", "Object must be an Instance")

	self._IsStructureWatchSuppressed = true

	local Previous = self.Object
	local Clone = object:Clone()
	Clone.Parent = RichViewport._GetObjectParent(self)

	self.Object = Clone

	if Previous then
		Previous:Destroy()
	end

	self._IsStructureWatchSuppressed = false

	RichViewport._BindObjectWatchers(self)
	RichViewport._RebuildContent(self)
	self:Refresh()
end

--[=[
	Rebinds the camera driving the ViewportFrame(s).

	@param camera Camera
	@within RichViewport
]=]

function RichViewport.SetCamera(self : RichViewport, camera : Camera)
	RichViewport._AssertNotDestroyed(self)
	assert(camera:IsA("Camera"), "Camera must be a Camera")

	self.Camera = camera
	self.ViewportFrame.CurrentCamera = camera

	for _, frames in self._FramesByPart do
		if frames.Viewport then
			frames.Viewport.CurrentCamera = camera
		end
	end

	RichViewport._BindCameraWatchers(self)
	self:Refresh()
end

--[=[
	Reparents the overlay root.

	@param parent GuiObject
	@within RichViewport
]=]

function RichViewport.SetParent(self : RichViewport, parent : GuiObject)
	RichViewport._AssertNotDestroyed(self)
	assert(parent:IsA("GuiObject"), "Parent must be a GuiObject")

	self.Parent = parent
	self._Root.Parent = parent
	self:Refresh()
end

--[=[
	Destroys the Seam scope, overlays, watchers, and fires `Destroyed`.

	@within RichViewport
]=]

function RichViewport.Destroy(self : RichViewport)
	if self._IsDestroyed then
		return
	end

	self._IsDestroyed = true
	self._DestroyedEvent:Fire()
	self.Scope:Destroy()
end

function RichViewport._AssertNotDestroyed(self : RichViewport)
	assert(not self._IsDestroyed, "RichViewport has been destroyed")
end

function RichViewport._BindCameraWatchers(self : RichViewport)
	if self._CameraWatchScope then
		self._CameraWatchScope:Destroy()
		self._CameraWatchScope = nil
	end

	local WatchScope = self.Scope:InnerScope()
	self._CameraWatchScope = WatchScope

	WatchScope:OnChanged(self.Camera, function(property)
		if property ~= "CFrame" and property ~= "FieldOfView" then
			return
		end

		self:Refresh()
	end)
end

function RichViewport._WatchTransforms(self : RichViewport, watchScope : any, instance : Instance)
	if instance:IsA("BasePart") then
		watchScope:OnChanged(instance, function(property)
			if property ~= "CFrame" and property ~= "Size" and property ~= "Orientation" and property ~= "Position" then
				return
			end

			self:Refresh()
		end)
		return
	end

	if instance:IsA("Attachment") then
		watchScope:OnChanged(instance, function(property)
			if property ~= "CFrame" and property ~= "Position" and property ~= "Orientation" then
				return
			end

			self:Refresh()
		end)
	end
end

function RichViewport._ScheduleStructureRebuild(self : RichViewport)
	if self._IsStructureWatchSuppressed or self._IsStructureDirty or self._IsDestroyed then
		return
	end

	self._IsStructureDirty = true

	task.defer(function()
		self._IsStructureDirty = false

		if self._IsDestroyed or self._IsStructureWatchSuppressed then
			return
		end

		RichViewport._BindObjectWatchers(self)
		RichViewport._RebuildContent(self)
		self:Refresh()
	end)
end

function RichViewport._BindObjectWatchers(self : RichViewport)
	if self._ObjectWatchScope then
		self._ObjectWatchScope:Destroy()
		self._ObjectWatchScope = nil
	end

	local WatchScope = self.Scope:InnerScope()
	self._ObjectWatchScope = WatchScope

	WatchScope:AddObject(self.Object.DescendantAdded:Connect(function(descendant)
		if self._IsStructureWatchSuppressed then
			return
		end

		RichViewport._WatchTransforms(self, WatchScope, descendant)

		if ShouldWatchStructure(descendant) then
			RichViewport._ScheduleStructureRebuild(self)
		end
	end))

	WatchScope:AddObject(self.Object.DescendantRemoving:Connect(function(descendant)
		if self._IsStructureWatchSuppressed then
			return
		end

		if ShouldWatchStructure(descendant) then
			RichViewport._ScheduleStructureRebuild(self)
		end
	end))

	if self.Object:IsA("BasePart") or self.Object:IsA("Attachment") then
		RichViewport._WatchTransforms(self, WatchScope, self.Object)
	end

	for _, descendant in self.Object:GetDescendants() do
		RichViewport._WatchTransforms(self, WatchScope, descendant)
	end
end

function RichViewport._GetObjectParent(self : RichViewport) : Instance
	if RichViewport.IsBasePartLayeringEnabled(self) then
		return self._SourceHolder
	end

	return self.ViewportFrame
end

function RichViewport._RebuildContent(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)

	self._IsStructureWatchSuppressed = true

	if self._ContentScope then
		self._ContentScope:Destroy()
		self._ContentScope = nil
	end

	local ContentScope = self.Scope:InnerScope()
	self._ContentScope = ContentScope
	self._FramesByPart = {}
	self._MimicBindings = {}
	self._LayerRotationByPart = {}

	local Layered = RichViewport.IsBasePartLayeringEnabled(self)

	self._LayerStack.Visible = Layered
	self._BehindOverlay.Visible = not Layered
	self.ViewportFrame.Visible = not Layered
	self._FrontOverlay.Visible = not Layered

	local Object = self.Object

	if Object then
		Object.Parent = RichViewport._GetObjectParent(self)
	end

	local Parts = Spatial.CollectParts(self.Object)

	for _, part in Parts do
		if Layered then
			self._FramesByPart[part] = Overlays.CreatePartLayerSlice(
				ContentScope,
				part,
				self._LayerStack,
				self.Camera
			)
		else
			self._FramesByPart[part] = Overlays.CreatePartFrames(
				ContentScope,
				part,
				self._BehindOverlay,
				self._FrontOverlay
			)
		end
	end

	self._MimicBindings = Particles.AttachToBoundsFrames(
		ContentScope,
		self.Object,
		self._FramesByPart,
		40
	)

	self._IsStructureWatchSuppressed = false
end

--[=[
	@prop Object Instance
	@within RichViewport
	Live clone inside the ViewportFrame. Rebind with `SetObject`.
]=]

--[=[
	@prop Camera Camera
	@within RichViewport
	Rebind with `SetCamera`.
]=]

--[=[
	@prop Parent GuiObject
	@within RichViewport
	Rebind with `SetParent`.
]=]

--[=[
	@prop ViewportFrame ViewportFrame
	@within RichViewport
]=]

--[=[
	@prop Scope Scope
	@within RichViewport
]=]

--[=[
	@prop Destroyed RBXScriptSignal
	@within RichViewport
]=]

--[=[
	@prop Refreshed RBXScriptSignal
	@within RichViewport
]=]

RichViewport.Spatial = Spatial
RichViewport.Overlays = Overlays
RichViewport.Particles = Particles

return RichViewport