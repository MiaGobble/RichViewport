--[=[
	ViewportFrame wrapper with depth-aware particle mimics and optional debug bounds.

	Clones the given object into a transparent viewport, watches camera / object /
	size changes, and keeps overlay emission hosts in sync.

	```lua
	local View = RichViewport.new(SourceModel, Camera, ParentFrame)
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

-- Types
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
	_DebugVisible : boolean,
	_ParticlesVisible : boolean,
	_BasePartLayeringCount : number,
	_Destroyed : boolean,
	_DestroyedEvent : BindableEvent,
	_RefreshedEvent : BindableEvent,
	_ObjectWatchScope : any?,
	_CameraWatchScope : any?,
	_Assigning : boolean,
	_StructureDirty : boolean,
	_SuppressStructureWatch : boolean,
	_LayerRotationByPart : {[BasePart] : number},
}

export type RichViewport = setmetatable<Fields, typeof(RichViewport)>

-- Constants
local ASSIGNABLE = {
	Object = true,
	Camera = true,
	Parent = true,
}

--[=[
	Creates a RichViewport. `Object` is **cloned** into the viewport; the live clone
	is exposed as `RichViewport.Object`.

	@param Object Instance -- Source instance to clone into the viewport
	@param Camera Camera -- Camera driving the ViewportFrame
	@param Parent GuiObject -- Parent for the overlay root
	@return RichViewport
	@within RichViewport
]=]
function RichViewport.new(Object : Instance, Camera : Camera, Parent : GuiObject) : RichViewport
	assert(typeof(Object) == "Instance", "Object must be an Instance")
	assert(Camera:IsA("Camera"), "Camera must be a Camera")
	assert(Parent:IsA("GuiObject"), "Parent must be a GuiObject")

	local Scope = Seam.Scope(Seam)
	local DestroyedEvent = Scope:AddObject(Instance.new("BindableEvent"))
	local RefreshedEvent = Scope:AddObject(Instance.new("BindableEvent"))
	DestroyedEvent.Name = "Destroyed"
	RefreshedEvent.Name = "Refreshed"

	local Stack = Overlays.CreateStack(Scope, Parent, Camera)

	local Self : Fields = {
		Object = nil :: any,
		Camera = Camera,
		Parent = Parent,
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
		_DebugVisible = false,
		_ParticlesVisible = true,
		_BasePartLayeringCount = 0,
		_Destroyed = false,
		_DestroyedEvent = DestroyedEvent,
		_RefreshedEvent = RefreshedEvent,
		_ObjectWatchScope = nil,
		_CameraWatchScope = nil,
		_Assigning = false,
		_StructureDirty = false,
		_SuppressStructureWatch = false,
		_LayerRotationByPart = {},
	}

	local InstanceObject = setmetatable(Self, RichViewport)

	Scope:OnChanged(Stack.Root, function(Property)
		if Property ~= "AbsoluteSize" then
			return
		end

		InstanceObject:Refresh()
	end)

	RichViewport._BindCameraWatchers(InstanceObject)
	RichViewport._SetObject(InstanceObject, Object)
	InstanceObject:Refresh()
	task.defer(function()
		if not InstanceObject._Destroyed then
			InstanceObject:Refresh()
		end
	end)

	return InstanceObject
end

--[=[
	Forces a bounds + particle mimic update and fires `Refreshed`.

	@within RichViewport
]=]
function RichViewport.Refresh(self : RichViewport)
	if self._Destroyed then
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

	for Part, Frames in self._FramesByPart do
		if not Part.Parent then
			Overlays.HidePartFrames(self.Scope, Frames)
			continue
		end

		local LayerBounds = Spatial.GetPartLayerBounds(
			self.Camera,
			Part,
			PixelSize,
			self._LayerRotationByPart[Part]
		)

		if not LayerBounds then
			Overlays.HidePartFrames(self.Scope, Frames)
			continue
		end

		NextRotations[Part] = LayerBounds.Rotation
		DepthByPart[Part] = LayerBounds.Depth
		BoundsByPart[Part] = LayerBounds

		if Frames.Visual and Frames.Viewport then
			Overlays.SyncPartVisual(Frames.Visual, Part)
			Frames.Viewport.CurrentCamera = self.Camera
		end

		Overlays.UpdatePartFrames(self.Scope, Frames, LayerBounds, self._DebugVisible)

		table.insert(Ranked, {
			Front = Frames.Front,
			Behind = Frames.Behind,
			Depth = LayerBounds.Depth,
		})

		if Frames.Viewport then
			table.insert(LayeredRanked, {
				Front = Frames.Front,
				Behind = Frames.Behind,
				Viewport = Frames.Viewport,
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
		self._ParticlesVisible
	)

	self._RefreshedEvent:Fire()
end

--[=[
	Shows oriented debug bound guides.

	@within RichViewport
]=]
function RichViewport.ShowDebug(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._DebugVisible = true
	self:Refresh()
end

--[=[
	Hides oriented debug bound guides.

	@within RichViewport
]=]
function RichViewport.HideDebug(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._DebugVisible = false
	self:Refresh()
end

--[=[
	Enables particle mimics (default).

	@within RichViewport
]=]
function RichViewport.ShowParticles(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._ParticlesVisible = true
	self:Refresh()
end

--[=[
	Disables and clears particle mimics.

	@within RichViewport
]=]
function RichViewport.HideParticles(self : RichViewport)
	RichViewport._AssertNotDestroyed(self)
	self._ParticlesVisible = false
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

	local WasEnabled = RichViewport.IsBasePartLayeringEnabled(self)
	self._BasePartLayeringCount += 1

	if not WasEnabled then
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
	Destroys the Seam scope, overlays, watchers, and fires `Destroyed`.

	@within RichViewport
]=]
function RichViewport.Destroy(self : RichViewport)
	if self._Destroyed then
		return
	end

	self._Destroyed = true
	self._DestroyedEvent:Fire()
	self.Scope:Destroy()
end

function RichViewport.__newindex(self : RichViewport, Key : string, Value : any)
	if rawget(self, "_Assigning") or rawget(self, "_Destroyed") then
		rawset(self, Key, Value)
		return
	end

	if not ASSIGNABLE[Key] then
		rawset(self, Key, Value)
		return
	end

	rawset(self, "_Assigning", true)

	if Key == "Object" then
		RichViewport._SetObject(self, Value)
	elseif Key == "Camera" then
		RichViewport._SetCamera(self, Value)
	elseif Key == "Parent" then
		RichViewport._SetParent(self, Value)
	end

	rawset(self, "_Assigning", false)
	self:Refresh()
end

function RichViewport._AssertNotDestroyed(self : RichViewport)
	assert(not self._Destroyed, "RichViewport has been destroyed")
end

function RichViewport._BindCameraWatchers(self : RichViewport)
	if self._CameraWatchScope then
		self._CameraWatchScope:Destroy()
		self._CameraWatchScope = nil
	end

	local WatchScope = self.Scope:InnerScope()
	self._CameraWatchScope = WatchScope

	WatchScope:OnChanged(self.Camera, function(Property)
		if Property ~= "CFrame" and Property ~= "FieldOfView" then
			return
		end

		self:Refresh()
	end)
end

function RichViewport._WatchTransforms(self : RichViewport, WatchScope : any, InstanceObject : Instance)
	if InstanceObject:IsA("BasePart") then
		WatchScope:OnChanged(InstanceObject, function(Property)
			if Property ~= "CFrame" and Property ~= "Size" and Property ~= "Orientation" and Property ~= "Position" then
				return
			end

			self:Refresh()
		end)
		return
	end

	if InstanceObject:IsA("Attachment") then
		WatchScope:OnChanged(InstanceObject, function(Property)
			if Property ~= "CFrame" and Property ~= "Position" and Property ~= "Orientation" then
				return
			end

			self:Refresh()
		end)
	end
end

local function ShouldWatchStructure(InstanceObject : Instance) : boolean
	return InstanceObject:IsA("BasePart")
		or InstanceObject:IsA("Attachment")
		or InstanceObject:IsA("ParticleEmitter")
end

function RichViewport._ScheduleStructureRebuild(self : RichViewport)
	if self._SuppressStructureWatch or self._StructureDirty or self._Destroyed then
		return
	end

	self._StructureDirty = true

	task.defer(function()
		self._StructureDirty = false

		if self._Destroyed or self._SuppressStructureWatch then
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

	WatchScope:AddObject(self.Object.DescendantAdded:Connect(function(Descendant)
		if self._SuppressStructureWatch then
			return
		end

		RichViewport._WatchTransforms(self, WatchScope, Descendant)

		if ShouldWatchStructure(Descendant) then
			RichViewport._ScheduleStructureRebuild(self)
		end
	end))

	WatchScope:AddObject(self.Object.DescendantRemoving:Connect(function(Descendant)
		if self._SuppressStructureWatch then
			return
		end

		if ShouldWatchStructure(Descendant) then
			RichViewport._ScheduleStructureRebuild(self)
		end
	end))

	if self.Object:IsA("BasePart") or self.Object:IsA("Attachment") then
		RichViewport._WatchTransforms(self, WatchScope, self.Object)
	end

	for _, Descendant in self.Object:GetDescendants() do
		RichViewport._WatchTransforms(self, WatchScope, Descendant)
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

	self._SuppressStructureWatch = true

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

	local Object = rawget(self, "Object")
	if Object then
		Object.Parent = RichViewport._GetObjectParent(self)
	end

	local Parts = Spatial.CollectParts(self.Object)

	for _, Part in Parts do
		if Layered then
			self._FramesByPart[Part] = Overlays.CreatePartLayerSlice(
				ContentScope,
				Part,
				self._LayerStack,
				self.Camera
			)
		else
			self._FramesByPart[Part] = Overlays.CreatePartFrames(
				ContentScope,
				Part,
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

	self._SuppressStructureWatch = false
end

function RichViewport._SetObject(self : RichViewport, Source : Instance)
	RichViewport._AssertNotDestroyed(self)
	assert(typeof(Source) == "Instance", "Object must be an Instance")

	self._SuppressStructureWatch = true

	local Previous = rawget(self, "Object")
	local Clone = Source:Clone()
	Clone.Parent = RichViewport._GetObjectParent(self)

	rawset(self, "Object", Clone)

	if Previous then
		Previous:Destroy()
	end

	self._SuppressStructureWatch = false

	RichViewport._BindObjectWatchers(self)
	RichViewport._RebuildContent(self)
end

function RichViewport._SetCamera(self : RichViewport, Camera : Camera)
	RichViewport._AssertNotDestroyed(self)
	assert(Camera:IsA("Camera"), "Camera must be a Camera")

	rawset(self, "Camera", Camera)
	self.ViewportFrame.CurrentCamera = Camera

	for _, Frames in self._FramesByPart do
		if Frames.Viewport then
			Frames.Viewport.CurrentCamera = Camera
		end
	end

	RichViewport._BindCameraWatchers(self)
end

function RichViewport._SetParent(self : RichViewport, Parent : GuiObject)
	RichViewport._AssertNotDestroyed(self)
	assert(Parent:IsA("GuiObject"), "Parent must be a GuiObject")

	rawset(self, "Parent", Parent)
	self._Root.Parent = Parent
end

--[=[
	@prop Object Instance
	@within RichViewport
	Live clone inside the ViewportFrame. Assigning a new Instance clones it in.
]=]
--[=[
	@prop Camera Camera
	@within RichViewport
]=]
--[=[
	@prop Parent GuiObject
	@within RichViewport
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
