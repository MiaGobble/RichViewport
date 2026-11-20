--[=[
	Maps 3D `ParticleEmitter`s onto `ParticleEmitter2D` mimics for viewport overlays.

	Requires Studio beta **UI Particles**.

	@class Particles
]=]

local Particles = {}

local Spatial = require(script.Parent.Spatial)
local Overlays = require(script.Parent.Overlays)

export type MimicBinding = {
	Emitter3D : ParticleEmitter,
	Emitter2D : ParticleEmitter2D,
	Part : BasePart,
	Layer : "Front" | "Behind",
	Attachment : Attachment?,
	HostFrame : Frame?,
	WasEnabled : boolean,
	LockedToPart : boolean,
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

local function GetEmitterCFrame(Part : BasePart, Attachment : Attachment?) : CFrame
	if Attachment then
		return Attachment.WorldCFrame
	end

	return Part.CFrame
end

local function GetEmissionWorldDirection(Emitter3D : ParticleEmitter, Part : BasePart, Attachment : Attachment?) : Vector3
	local LocalDirection = Vector3.FromNormalId(Emitter3D.EmissionDirection)
	return GetEmitterCFrame(Part, Attachment):VectorToWorldSpace(LocalDirection)
end

--[=[
	Copies motion/appearance scales into a mimic for the current camera depth.

	@within Particles
]=]
function Particles.ApplyMotionAndPerspective(Emitter2D : ParticleEmitter2D, Emitter3D : ParticleEmitter, Camera : Camera, PixelsPerStud : number, Part : BasePart, Attachment : Attachment?)
	local CameraCFrame = Camera.CFrame
	local EmissionDirection = GetEmissionWorldDirection(Emitter3D, Part, Attachment)

	Emitter2D.Size = ScaleNumberSequence(Emitter3D.Size, PixelsPerStud)
	Emitter2D.Speed = ScaleNumberRange(Emitter3D.Speed, PixelsPerStud)
	Emitter2D.Squash = Emitter3D.Squash

	local AccelerationCamera = CameraCFrame:VectorToObjectSpace(Emitter3D.Acceleration)
	Emitter2D.Acceleration = Vector2.new(AccelerationCamera.X, -AccelerationCamera.Y) * PixelsPerStud

	local EmissionCamera = CameraCFrame:VectorToObjectSpace(EmissionDirection)
	local ScreenEmission = Vector2.new(EmissionCamera.X, -EmissionCamera.Y)

	if ScreenEmission.Magnitude <= 1e-4 then
		Emitter2D.Rotation = Emitter3D.Rotation
		return
	end

	local EmissionAngleDegrees = math.deg(math.atan2(ScreenEmission.Y, ScreenEmission.X))
	Emitter2D.EmissionAngle = EmissionAngleDegrees

	if Emitter3D.Orientation == Enum.ParticleOrientation.VelocityParallel then
		local AlignedRotation = EmissionAngleDegrees - 90
		Emitter2D.Rotation = NumberRange.new(AlignedRotation, AlignedRotation)
	else
		Emitter2D.Rotation = Emitter3D.Rotation
	end
end

--[=[
	Creates a `ParticleEmitter2D` mimic under `Parent`.

	@within Particles
]=]
function Particles.CreateMimic(Scope : any, Emitter3D : ParticleEmitter, Parent : GuiObject, PixelsPerStud : number, RateScale : number?, EmissionMode : Enum.ParticleEmitter2DEmissionMode?) : ParticleEmitter2D
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

	Emitter2D.Size = ScaleNumberSequence(Emitter3D.Size, PixelsPerStud)
	Emitter2D.Speed = ScaleNumberRange(Emitter3D.Speed, PixelsPerStud)
	Emitter2D.Acceleration = Vector2.new(Emitter3D.Acceleration.X, -Emitter3D.Acceleration.Y) * PixelsPerStud

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

local function AddBinding(Bindings : {MimicBinding}, Scope : any, Emitter3D : ParticleEmitter, Part : BasePart, BoundsFrame : Frame, Layer : "Front" | "Behind", PixelsPerStud : number, RateScale : number, Attachment : Attachment?, EmissionMode : Enum.ParticleEmitter2DEmissionMode)
	local HostFrame = nil
	local Parent = BoundsFrame

	if Attachment then
		HostFrame = CreateAttachmentHost(Scope, BoundsFrame, `{Emitter3D.Name}_Point`)
		Parent = HostFrame
	end

	local Emitter2D = Particles.CreateMimic(Scope, Emitter3D, Parent, PixelsPerStud, RateScale, EmissionMode)

	table.insert(Bindings, {
		Emitter3D = Emitter3D,
		Emitter2D = Emitter2D,
		Part = Part,
		Layer = Layer,
		Attachment = Attachment,
		HostFrame = HostFrame,
		WasEnabled = Emitter3D.Enabled,
		LockedToPart = Emitter3D.LockedToPart,
	})
end

local function GetVolumeLayerWeights(ZOffset : number) : (number, number)
	if ZOffset < 0 then
		return 0.92, 0.08
	elseif ZOffset > 0 then
		return 0.7, 0.3
	end

	return 0.85, 0.15
end

--[=[
	Attaches 2D mimics for every `ParticleEmitter` under `Root`, disabling the 3D sources.

	Volume emitters split rate behind/front so ViewportFrame meshes can occlude.

	@within Particles
]=]
function Particles.AttachToBoundsFrames(Scope : any, Root : Instance, FramesByPart : {[BasePart] : Overlays.PartFrames}, PixelsPerStud : number) : {MimicBinding}
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
		local IsVolume = Emitter3D.ShapeStyle == Enum.ParticleEmitterShapeStyle.Volume

		if Attachment then
			local LayerFrame = if ZOffset < 0 then Frames.Behind else Frames.Front
			local LayerName : "Front" | "Behind" = if ZOffset < 0 then "Behind" else "Front"
			AddBinding(
				Bindings,
				Scope,
				Emitter3D,
				Part,
				LayerFrame,
				LayerName,
				PixelsPerStud,
				1,
				Attachment,
				Enum.ParticleEmitter2DEmissionMode.Point
			)
		elseif IsVolume then
			local BehindWeight, FrontWeight = GetVolumeLayerWeights(ZOffset)

			AddBinding(
				Bindings,
				Scope,
				Emitter3D,
				Part,
				Frames.Behind,
				"Behind",
				PixelsPerStud,
				BehindWeight,
				nil,
				Enum.ParticleEmitter2DEmissionMode.BoundingBox
			)
			AddBinding(
				Bindings,
				Scope,
				Emitter3D,
				Part,
				Frames.Front,
				"Front",
				PixelsPerStud,
				FrontWeight,
				nil,
				Enum.ParticleEmitter2DEmissionMode.BoundingBox
			)
		else
			local LayerFrame = if ZOffset < 0 then Frames.Behind else Frames.Front
			local LayerName : "Front" | "Behind" = if ZOffset < 0 then "Behind" else "Front"
			AddBinding(
				Bindings,
				Scope,
				Emitter3D,
				Part,
				LayerFrame,
				LayerName,
				PixelsPerStud,
				1,
				nil,
				Enum.ParticleEmitter2DEmissionMode.BoundingBox
			)
		end

		Emitter3D.Enabled = false
	end

	return Bindings
end

--[=[
	Updates enable state, attachment hosts, depth ZIndex, and perspective each frame refresh.

	@within Particles
]=]
function Particles.UpdateMimics(Scope : any, Bindings : {MimicBinding}, Camera : Camera, PixelSize : Vector2, DepthByPart : {[BasePart] : number}, BoundsByPart : {[BasePart] : Spatial.ScreenBounds}, ShowParticles : boolean)
	local PartsByDepth = {}
	for Part, Depth in DepthByPart do
		table.insert(PartsByDepth, {Part = Part, Depth = Depth})
	end

	table.sort(PartsByDepth, function(A, B)
		return A.Depth > B.Depth
	end)

	local DepthRankByPart : {[BasePart] : number} = {}
	for Index, Entry in PartsByDepth do
		DepthRankByPart[Entry.Part] = Index
	end

	for _, Binding in Bindings do
		local ShouldEnable = ShowParticles and Binding.WasEnabled
		local DepthRank = DepthRankByPart[Binding.Part] or 1

		Scope:New(Binding.Emitter2D, {
			Enabled = ShouldEnable,
			LockedToParent = Binding.LockedToPart,
			ZIndex = DepthRank,
		})

		if not ShouldEnable then
			Binding.Emitter2D:Clear()
		end

		local Depth = DepthByPart[Binding.Part]
		local Bounds = BoundsByPart[Binding.Part]
		if not Depth or not Bounds then
			continue
		end

		local PixelsPerStud = Spatial.GetPixelsPerStud(Camera, Depth, PixelSize)

		if Binding.Attachment and Binding.HostFrame then
			local ScreenX, ScreenY, AttachmentDepth = Spatial.WorldToViewportPixels(
				Camera,
				Binding.Attachment.WorldPosition,
				PixelSize
			)

			if not ScreenX then
				Scope:New(Binding.HostFrame, {Visible = false})
				continue
			end

			if AttachmentDepth then
				PixelsPerStud = Spatial.GetPixelsPerStud(Camera, AttachmentDepth, PixelSize)
			end

			Scope:New(Binding.HostFrame, {
				Visible = true,
				Position = UDim2.fromOffset(
					(ScreenX :: number) - Bounds.CenterX + Bounds.Width * 0.5,
					(ScreenY :: number) - Bounds.CenterY + Bounds.Height * 0.5
				),
			})
		end

		Particles.ApplyMotionAndPerspective(
			Binding.Emitter2D,
			Binding.Emitter3D,
			Camera,
			PixelsPerStud,
			Binding.Part,
			Binding.Attachment
		)
	end
end

return Particles
