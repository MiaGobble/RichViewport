--[=[
	Maps 3D ParticleEmitters onto ParticleEmitter2D instances for ViewportFrame overlays.

	@class ViewportParticles
]=]

local ViewportParticles = {}

export type PartFrames = {
	Front : Frame,
	Behind : Frame,
}

export type MimicBinding = {
	Emitter3D : ParticleEmitter,
	Emitter2D : ParticleEmitter2D,
	Part : BasePart,
	Layer : "Front" | "Behind",
	Attachment : Attachment?,
	HostFrame : Frame?,
	WasEnabled : boolean,
}

local function ScaleNumberSequence(Sequence : NumberSequence, Scale : number) : NumberSequence
	local Keypoints = table.create(#Sequence.Keypoints)

	for Index, Keypoint in Sequence.Keypoints do
		Keypoints[Index] = NumberSequenceKeypoint.new(
			Keypoint.Time,
			Keypoint.Value * Scale,
			Keypoint.Envelope * Scale
		)
	end

	return NumberSequence.new(Keypoints)
end

local function ScaleNumberRange(Range : NumberRange, Scale : number) : NumberRange
	return NumberRange.new(Range.Min * Scale, Range.Max * Scale)
end

function ViewportParticles.WorldToViewportPixels(Camera : Camera, WorldPoint : Vector3, PixelSize : Vector2) : (number?, number?, number?)
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

function ViewportParticles.GetPixelsPerStud(Camera : Camera, Depth : number, PixelSize : Vector2) : number
	if Depth <= 0 or PixelSize.Y <= 0 then
		return 1
	end

	local HalfHeight = math.tan(math.rad(Camera.FieldOfView) * 0.5) * Depth
	return PixelSize.Y / (2 * HalfHeight)
end

function ViewportParticles.ApplyScale(Emitter2D : ParticleEmitter2D, Emitter3D : ParticleEmitter, PixelsPerStud : number)
	local Acceleration = Emitter3D.Acceleration

	Emitter2D.Size = ScaleNumberSequence(Emitter3D.Size, PixelsPerStud)
	Emitter2D.Speed = ScaleNumberRange(Emitter3D.Speed, PixelsPerStud)

	-- Screen Y grows downward; Roblox world Y grows upward.
	Emitter2D.Acceleration = Vector2.new(Acceleration.X, -Acceleration.Y) * PixelsPerStud
end

function ViewportParticles.CreateMimic(Scope : any, Emitter3D : ParticleEmitter, Parent : GuiObject, PixelsPerStud : number, RateScale : number?, EmissionMode : Enum.ParticleEmitter2DEmissionMode?) : ParticleEmitter2D
	local ResolvedRateScale = RateScale or 1

	local Emitter2D = Scope:New("ParticleEmitter2D", {
		Name = Emitter3D.Name,
		Parent = Parent,
		Enabled = Emitter3D.Enabled,
		TextureContent = Emitter3D.TextureContent,
		Color = Emitter3D.Color,
		Transparency = Emitter3D.Transparency,
		Lifetime = Emitter3D.Lifetime,
		Rate = Emitter3D.Rate * ResolvedRateScale,
		Drag = Emitter3D.Drag,
		Brightness = Emitter3D.Brightness,
		TimeScale = Emitter3D.TimeScale,
		Rotation = Emitter3D.Rotation,
		RotSpeed = Emitter3D.RotSpeed,
		Squash = Emitter3D.Squash,
		Blend = Emitter3D.LightEmission,
		LockedToParent = Emitter3D.LockedToPart,
		EmissionMode = EmissionMode or Enum.ParticleEmitter2DEmissionMode.BoundingBox,
		SpreadAngle = math.max(math.abs(Emitter3D.SpreadAngle.X), math.abs(Emitter3D.SpreadAngle.Y)),
		FlipbookLayout = Emitter3D.FlipbookLayout,
		FlipbookMode = Emitter3D.FlipbookMode,
		FlipbookFramerate = Emitter3D.FlipbookFramerate,
		FlipbookStartRandom = Emitter3D.FlipbookStartRandom,
		FlipbookBlendFrames = Emitter3D.FlipbookBlendFrames,
		FlipbookSizeX = Emitter3D.FlipbookSizeX,
		FlipbookSizeY = Emitter3D.FlipbookSizeY,
	})

	ViewportParticles.ApplyScale(Emitter2D, Emitter3D, PixelsPerStud)

	return Emitter2D
end

local function CreateAttachmentHost(Scope : any, Parent : Frame, Name : string) : Frame
	return Scope:New("Frame", {
		Name = Name,
		Parent = Parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
	})
end

local function AddBinding(Bindings : {MimicBinding}, Scope : any, Emitter3D : ParticleEmitter, Part : BasePart, BoundsFrame : Frame, Layer : "Front" | "Behind", PixelsPerStud : number, RateScale : number, Attachment : Attachment?)
	local HostFrame = nil
	local Parent = BoundsFrame

	if Attachment then
		HostFrame = CreateAttachmentHost(Scope, BoundsFrame, `{Emitter3D.Name}_Point`)
		Parent = HostFrame
	end

	local EmissionMode = if Attachment
		then Enum.ParticleEmitter2DEmissionMode.Point
		else Enum.ParticleEmitter2DEmissionMode.BoundingBox

	local Emitter2D = ViewportParticles.CreateMimic(Scope, Emitter3D, Parent, PixelsPerStud, RateScale, EmissionMode)

	table.insert(Bindings, {
		Emitter3D = Emitter3D,
		Emitter2D = Emitter2D,
		Part = Part,
		Layer = Layer,
		Attachment = Attachment,
		HostFrame = HostFrame,
		WasEnabled = Emitter3D.Enabled,
	})
end

function ViewportParticles.AttachToBoundsFrames(Scope : any, Root : Instance, FramesByPart : {[BasePart] : PartFrames}, PixelsPerStud : number) : {MimicBinding}
	local Bindings = {}

	for _, Emitter3D in Root:QueryDescendants("ParticleEmitter") do
		local Part = Emitter3D:FindFirstAncestorWhichIsA("BasePart")
		if not Part then
			continue
		end

		local Frames = FramesByPart[Part]
		if not Frames then
			continue
		end

		local Attachment = if Emitter3D.Parent and Emitter3D.Parent:IsA("Attachment")
			then Emitter3D.Parent
			else nil

		local ZOffset = Emitter3D.ZOffset

		if ZOffset < 0 then
			AddBinding(Bindings, Scope, Emitter3D, Part, Frames.Behind, "Behind", PixelsPerStud, 1, Attachment)
		elseif ZOffset > 0 then
			AddBinding(Bindings, Scope, Emitter3D, Part, Frames.Front, "Front", PixelsPerStud, 1, Attachment)
		else
			-- No authored offset: approximate volume depth by splitting across both layers.
			AddBinding(Bindings, Scope, Emitter3D, Part, Frames.Behind, "Behind", PixelsPerStud, 0.5, Attachment)
			AddBinding(Bindings, Scope, Emitter3D, Part, Frames.Front, "Front", PixelsPerStud, 0.5, Attachment)
		end

		Emitter3D.Enabled = false
	end

	return Bindings
end

function ViewportParticles.UpdateMimics(Scope : any, Bindings : {MimicBinding}, Camera : Camera, PixelSize : Vector2, DepthByPart : {[BasePart] : number}, BoundsByPart : {[BasePart] : Rect}, ShowParticles : boolean)
	for _, Binding in Bindings do
		local ShouldEnable = ShowParticles and Binding.WasEnabled

		Scope:New(Binding.Emitter2D, {
			Enabled = ShouldEnable,
		})

		if not ShouldEnable then
			Binding.Emitter2D:Clear()
		end

		local Depth = DepthByPart[Binding.Part]
		local Bounds = BoundsByPart[Binding.Part]
		if not Depth or not Bounds then
			continue
		end

		local PixelsPerStud = ViewportParticles.GetPixelsPerStud(Camera, Depth, PixelSize)
		ViewportParticles.ApplyScale(Binding.Emitter2D, Binding.Emitter3D, PixelsPerStud)

		if not Binding.Attachment or not Binding.HostFrame then
			continue
		end

		local ScreenX, ScreenY, AttachmentDepth = ViewportParticles.WorldToViewportPixels(
			Camera,
			Binding.Attachment.WorldPosition,
			PixelSize
		)

		if not ScreenX then
			Scope:New(Binding.HostFrame, {Visible = false})
			continue
		end

		if AttachmentDepth then
			PixelsPerStud = ViewportParticles.GetPixelsPerStud(Camera, AttachmentDepth, PixelSize)
			ViewportParticles.ApplyScale(Binding.Emitter2D, Binding.Emitter3D, PixelsPerStud)
		end

		Scope:New(Binding.HostFrame, {
			Visible = true,
			Position = UDim2.fromOffset(ScreenX - Bounds.Min.X, ScreenY - Bounds.Min.Y),
		})
	end
end

return ViewportParticles
