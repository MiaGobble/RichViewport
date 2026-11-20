--[=[
	Maps 3D ParticleEmitters onto ParticleEmitter2D instances for ViewportFrame overlays.

	@class ViewportParticles
]=]

local ViewportParticles = {}

export type MimicBinding = {
	Emitter3D : ParticleEmitter,
	Emitter2D : ParticleEmitter2D,
	Part : BasePart,
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

function ViewportParticles.CreateMimic(Scope : any, Emitter3D : ParticleEmitter, Parent : GuiObject, PixelsPerStud : number) : ParticleEmitter2D
	local Emitter2D = Scope:New("ParticleEmitter2D", {
		Name = Emitter3D.Name,
		Parent = Parent,
		Enabled = Emitter3D.Enabled,
		TextureContent = Emitter3D.TextureContent,
		Color = Emitter3D.Color,
		Transparency = Emitter3D.Transparency,
		Lifetime = Emitter3D.Lifetime,
		Rate = Emitter3D.Rate,
		Drag = Emitter3D.Drag,
		Brightness = Emitter3D.Brightness,
		TimeScale = Emitter3D.TimeScale,
		Rotation = Emitter3D.Rotation,
		RotSpeed = Emitter3D.RotSpeed,
		Squash = Emitter3D.Squash,
		Blend = Emitter3D.LightEmission,
		LockedToParent = Emitter3D.LockedToPart,
		EmissionMode = Enum.ParticleEmitter2DEmissionMode.BoundingBox,
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
	Emitter3D.Enabled = false

	return Emitter2D
end

function ViewportParticles.AttachToBoundsFrames(Scope : any, Root : Instance, FramesByPart : {[BasePart] : Frame}, PixelsPerStud : number) : {MimicBinding}
	local Bindings = {}

	for _, Emitter3D in Root:QueryDescendants("ParticleEmitter") do
		local Part = Emitter3D:FindFirstAncestorWhichIsA("BasePart")
		if not Part then
			continue
		end

		local Frame = FramesByPart[Part]
		if not Frame then
			continue
		end

		local Emitter2D = ViewportParticles.CreateMimic(Scope, Emitter3D, Frame, PixelsPerStud)

		table.insert(Bindings, {
			Emitter3D = Emitter3D,
			Emitter2D = Emitter2D,
			Part = Part,
		})
	end

	return Bindings
end

function ViewportParticles.UpdateMimicScales(Bindings : {MimicBinding}, Camera : Camera, PixelSize : Vector2, DepthByPart : {[BasePart] : number})
	for _, Binding in Bindings do
		local Depth = DepthByPart[Binding.Part]
		if not Depth then
			continue
		end

		local PixelsPerStud = ViewportParticles.GetPixelsPerStud(Camera, Depth, PixelSize)
		ViewportParticles.ApplyScale(Binding.Emitter2D, Binding.Emitter3D, PixelsPerStud)
	end
end

return ViewportParticles
