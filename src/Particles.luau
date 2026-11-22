--[=[
	Maps 3D `ParticleEmitter`s onto `ParticleEmitter2D` mimics for viewport overlays.

	Requires Studio beta **UI Particles**.

	@class Particles
]=]

local Particles = {}

-- Types
export type MimicBinding = {
	Emitter3D : ParticleEmitter,
	Emitter2D : ParticleEmitter2D,
	Part : BasePart,
	Layer : "Front" | "Behind",
	Attachment : Attachment?,
	HostFrame : Frame?,
	IsEmitterEnabled : boolean,
	IsLockedToPart : boolean,
}

-- Constants
const VIEW_ALIGNED_THRESHOLD = 0.22
const WAS_ENABLED_ATTRIBUTE = "RichViewportWasEnabled"
const EDGE_ON_SQUASH = NumberSequence.new(0.35)

-- Imports
local Spatial = require(script.Parent.Spatial)
local Overlays = require(script.Parent.Overlays)

local function ScaleNumberSequence(sequence : NumberSequence, scale : number) : NumberSequence
	local Keypoints = table.create(#sequence.Keypoints)

	for index, keypoint in sequence.Keypoints do
		Keypoints[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			keypoint.Value * scale,
			keypoint.Envelope * scale
		)
	end

	return NumberSequence.new(Keypoints)
end

local function ScaleNumberRange(range : NumberRange, scale : number) : NumberRange
	return NumberRange.new(range.Min * scale, range.Max * scale)
end

local function GetEmitterCFrame(part : BasePart, attachment : Attachment?) : CFrame
	if attachment then
		return attachment.WorldCFrame
	end

	return part.CFrame
end

local function GetEmissionWorldDirection(emitter3D : ParticleEmitter, part : BasePart, attachment : Attachment?) : Vector3
	local LocalDirection = Vector3.FromNormalId(emitter3D.EmissionDirection)
	return GetEmitterCFrame(part, attachment):VectorToWorldSpace(LocalDirection)
end

local function OffsetRotationRange(range : NumberRange, degrees : number) : NumberRange
	return NumberRange.new(range.Min - degrees, range.Max - degrees)
end

local function AddRotationOffset(baseDegrees : number, range : NumberRange) : NumberRange
	return NumberRange.new(baseDegrees + range.Min, baseDegrees + range.Max)
end

local function NegateNumberSequence(sequence : NumberSequence) : NumberSequence
	local Keypoints = table.create(#sequence.Keypoints)

	for index, keypoint in sequence.Keypoints do
		Keypoints[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			-keypoint.Value,
			keypoint.Envelope
		)
	end

	return NumberSequence.new(Keypoints)
end

-- Keep angles in a PE2D-friendly range (OBB unwrap can accumulate past ±360).
local function NormalizeDegrees(degrees : number) : number
	local Wrapped = ((degrees + 180) % 360 + 360) % 360 - 180
	return Wrapped
end

-- Wrap the center only — normalizing Min/Max independently can invert the range
-- (e.g. 170..190 → 170..-170) which NumberRange rejects.
local function NormalizeRotationRange(range : NumberRange) : NumberRange
	local Center = NormalizeDegrees((range.Min + range.Max) * 0.5)
	local HalfSpan = math.abs(range.Max - range.Min) * 0.5
	return NumberRange.new(Center - HalfSpan, Center + HalfSpan)
end

-- Screen-space projection of a world direction: angle, and how much of the vector
-- lies in the screen plane (0 = pure depth, 1 = pure lateral).
local function ProjectWorldDirectionToScreen(cameraCFrame : CFrame, worldDirection : Vector3) : (number?, number)
	local CameraVector = cameraCFrame:VectorToObjectSpace(worldDirection)
	local Screen = Vector2.new(CameraVector.X, -CameraVector.Y)
	local ScreenMag = Screen.Magnitude
	local TotalMag = CameraVector.Magnitude

	if TotalMag <= 1e-8 then
		return nil, 0
	end

	local ScreenFraction = math.clamp(ScreenMag / TotalMag, 0, 1)

	if ScreenMag <= 1e-6 then
		return nil, ScreenFraction
	end

	return math.deg(math.atan2(Screen.Y, Screen.X)), ScreenFraction
end

-- ParticleEmitter2D.EmissionAngle: 0 = parent local up, 90 = right, 180 = down
-- (same zero as GuiObject.Rotation). Our atan2 uses 0 = screen right → convert +90.
local function ScreenAtan2ToPE2D(screenAtan2Degrees : number) : number
	return NormalizeDegrees(screenAtan2Degrees + 90)
end

local function HorizontalBias(screenAtan2Degrees : number) : number
	-- Prefer left/right over up/down when fallback axes tie (Circles face-on → left).
	local Normalized = ((screenAtan2Degrees % 180) + 180) % 180
	local DistFromHorizontal = math.min(Normalized, 180 - Normalized)
	return 1 - math.clamp(DistFromHorizontal / 90, 0, 1)
end

local function PerpendicularBasis(axis : Vector3, emitterCFrame : CFrame) : (Vector3, Vector3)
	local Normal = if axis.Magnitude > 1e-8 then axis.Unit else emitterCFrame.LookVector
	local Hint = emitterCFrame.RightVector

	if math.abs(Hint:Dot(Normal)) > 0.95 then
		Hint = emitterCFrame.UpVector
	end

	local U = Normal:Cross(Hint)

	if U.Magnitude <= 1e-8 then
		U = Normal:Cross(Vector3.yAxis)
	end
	if U.Magnitude <= 1e-8 then
		U = Normal:Cross(Vector3.xAxis)
	end
	U = U.Unit
	return U, Normal:Cross(U).Unit
end

-- Parent-local PE2D EmissionAngle (0 = local up). View-aligned axes use a stable
-- ⊥-plane fallback with horizontal bias — never the noisy view-axis residual.
local function ResolveLocalEmissionAngle(cameraCFrame : CFrame, emissionDirection : Vector3, emitterCFrame : CFrame, parentRotation : number) : (number, number)
	local ScreenAngle, ScreenFraction = ProjectWorldDirectionToScreen(cameraCFrame, emissionDirection)

	if ScreenAngle and ScreenFraction >= VIEW_ALIGNED_THRESHOLD then
		return NormalizeDegrees(ScreenAtan2ToPE2D(ScreenAngle) - parentRotation), ScreenFraction
	end

	local U, V = PerpendicularBasis(emissionDirection, emitterCFrame)
	local UAngle, UFraction = ProjectWorldDirectionToScreen(cameraCFrame, U)
	local VAngle, VFraction = ProjectWorldDirectionToScreen(cameraCFrame, V)

	local BestAngle = UAngle
	local BestFraction = UFraction

	if UAngle and VAngle then
		local UScore = UFraction + 0.08 * HorizontalBias(UAngle)
		local VScore = VFraction + 0.08 * HorizontalBias(VAngle)

		if VScore > UScore then
			BestAngle = VAngle
			BestFraction = VFraction
		end
	elseif VFraction > UFraction then
		BestAngle = VAngle
		BestFraction = VFraction
	end

	if BestAngle then
		return NormalizeDegrees(ScreenAtan2ToPE2D(BestAngle) - parentRotation), math.max(ScreenFraction, BestFraction)
	end

	-- Parent-local up (PE2D 0).
	return NormalizeDegrees(-parentRotation), 1
end

local function AuthoredSpreadDegrees(emitter3D : ParticleEmitter) : number
	return math.clamp(
		math.max(math.abs(emitter3D.SpreadAngle.X), math.abs(emitter3D.SpreadAngle.Y)),
		0,
		360
	)
end

local function BlendNumberSequence(from : NumberSequence, to : NumberSequence, alpha : number) : NumberSequence
	local Count = math.max(#from.Keypoints, #to.Keypoints)
	local Keypoints = table.create(Count)
	local Blended = math.clamp(alpha, 0, 1)

	for index = 1, Count do
		local A = from.Keypoints[math.min(index, #from.Keypoints)]
		local B = to.Keypoints[math.min(index, #to.Keypoints)]
		Keypoints[index] = NumberSequenceKeypoint.new(
			A.Time + (B.Time - A.Time) * Blended,
			A.Value + (B.Value - A.Value) * Blended,
			A.Envelope + (B.Envelope - A.Envelope) * Blended
		)
	end

	return NumberSequence.new(Keypoints)
end

local function ScaleNumberRangeValues(range : NumberRange, scale : number) : NumberRange
	return NumberRange.new(range.Min * scale, range.Max * scale)
end

local function GetPalmFacing(cameraCFrame : CFrame, palmNormal : Vector3) : number
	if palmNormal.Magnitude <= 1e-8 then
		return 1
	end

	return math.abs(palmNormal.Unit:Dot(-cameraCFrame.LookVector))
end

local function ApplyOrientationAndPerspective(emitter2D : ParticleEmitter2D, emitter3D : ParticleEmitter, parentRotation : number, localEmissionAngle : number?, facing : number, cameraCFrame : CFrame)
	local Orientation = emitter3D.Orientation
	local Squash = emitter3D.Squash
	local EdgeOn = (1 - facing) ^ 2
	local SpinScale = facing * facing

	if Orientation == Enum.ParticleOrientation.FacingCamera then
		-- Billboard: exact authored appearance, parent-local spin only.
		emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(emitter3D.Rotation, parentRotation))
		emitter2D.Squash = Squash
		emitter2D.RotSpeed = emitter3D.RotSpeed
		return
	end

	if Orientation == Enum.ParticleOrientation.FacingCameraWorldUp then
		-- PE2D / GuiObject zero = local up; keep local Y on projected world up.
		local ScreenUpAngle = select(1, ProjectWorldDirectionToScreen(cameraCFrame, Vector3.yAxis))

		if ScreenUpAngle then
			local LocalUpAlign = NormalizeDegrees(ScreenAtan2ToPE2D(ScreenUpAngle) - parentRotation)
			emitter2D.Rotation = NormalizeRotationRange(AddRotationOffset(LocalUpAlign, emitter3D.Rotation))
		else
			emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(emitter3D.Rotation, parentRotation))
		end
		emitter2D.Squash = Squash
		emitter2D.RotSpeed = emitter3D.RotSpeed
		return
	end

	if Orientation == Enum.ParticleOrientation.VelocityParallel then
		if localEmissionAngle then
			-- Local Y along travel: Rotation = EmissionAngle when both use 0 = local up.
			emitter2D.Rotation = NormalizeRotationRange(
				AddRotationOffset(localEmissionAngle, ScaleNumberRangeValues(emitter3D.Rotation, SpinScale))
			)
			emitter2D.Squash = BlendNumberSequence(NegateNumberSequence(Squash), EDGE_ON_SQUASH, EdgeOn)
			emitter2D.RotSpeed = ScaleNumberRangeValues(emitter3D.RotSpeed, SpinScale)
		else
			emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(emitter3D.Rotation, parentRotation))
			emitter2D.Squash = Squash
			emitter2D.RotSpeed = emitter3D.RotSpeed
		end
		return
	end

	if Orientation == Enum.ParticleOrientation.VelocityPerpendicular then
		-- Face-on: billboard. Edge-on: soft squash + damp spin; bias local Y across travel.
		local BillboardRotation = OffsetRotationRange(emitter3D.Rotation, parentRotation)

		if localEmissionAngle and EdgeOn > 0.05 then
			local AlignedRotation = AddRotationOffset(
				localEmissionAngle + 90,
				ScaleNumberRangeValues(emitter3D.Rotation, SpinScale)
			)
			local BillboardCenter = (BillboardRotation.Min + BillboardRotation.Max) * 0.5
			local AlignedCenter = (AlignedRotation.Min + AlignedRotation.Max) * 0.5
			local Center = BillboardCenter + (AlignedCenter - BillboardCenter) * EdgeOn
			local HalfSpan = math.abs(BillboardRotation.Max - BillboardRotation.Min) * 0.5
			emitter2D.Rotation = NormalizeRotationRange(NumberRange.new(Center - HalfSpan, Center + HalfSpan))
			emitter2D.Squash = BlendNumberSequence(Squash, EDGE_ON_SQUASH, EdgeOn)
			emitter2D.RotSpeed = ScaleNumberRangeValues(emitter3D.RotSpeed, SpinScale)
		else
			emitter2D.Rotation = NormalizeRotationRange(BillboardRotation)
			emitter2D.Squash = Squash
			emitter2D.RotSpeed = emitter3D.RotSpeed
		end
		return
	end

	emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(emitter3D.Rotation, parentRotation))
	emitter2D.Squash = Squash
	emitter2D.RotSpeed = emitter3D.RotSpeed
end

--[=[
	Copies motion/appearance scales into a mimic for the current camera depth.

	`FrameRotation` is the emit host's GuiObject.Rotation. EmissionAngle / Acceleration /
	sprite Rotation are converted into parent-local space so AbsoluteRotation does not
	yaw particles relative to the screen.

	FacingCamera copies Squash/RotSpeed/Rotation (parent-local) with no palm foreshortening.
	Velocity* modes get soft palm squash + spin damping.

	@within Particles
]=]

function Particles.ApplyMotionAndPerspective(emitter2D : ParticleEmitter2D, emitter3D : ParticleEmitter, camera : Camera, pixelsPerStud : number, part : BasePart, attachment : Attachment?, frameRotation : number?)
	local CameraCFrame = camera.CFrame
	local ParentRotation = frameRotation or 0
	local EmitterCFrame = GetEmitterCFrame(part, attachment)
	local EmissionDirection = GetEmissionWorldDirection(emitter3D, part, attachment)
	local Orientation = emitter3D.Orientation

	local LocalEmissionAngle, ScreenFraction = ResolveLocalEmissionAngle(
		CameraCFrame,
		EmissionDirection,
		EmitterCFrame,
		ParentRotation
	)

	local UsePalm = if Orientation == Enum.ParticleOrientation.VelocityParallel or Orientation == Enum.ParticleOrientation.VelocityPerpendicular then true else false
	local Facing = if UsePalm then GetPalmFacing(CameraCFrame, EmissionDirection) else 1
	local SpeedFraction = if UsePalm then math.max(ScreenFraction, 0.35) else 1

	emitter2D.Size = ScaleNumberSequence(emitter3D.Size, pixelsPerStud)
	emitter2D.Speed = ScaleNumberRange(emitter3D.Speed, pixelsPerStud * SpeedFraction)
	-- SpreadAngle alone; EmissionSpread left at default — dual-writing 360/360 broke FacingCamera bursts.
	emitter2D.SpreadAngle = AuthoredSpreadDegrees(emitter3D)
	emitter2D.EmissionSpread = Vector2.zero
	-- Always refresh — skipping left a stale angle when the axis swept through view-aligned.
	emitter2D.EmissionAngle = LocalEmissionAngle

	local AccelerationCamera = CameraCFrame:VectorToObjectSpace(emitter3D.Acceleration)
	local ScreenAcceleration = Vector2.new(AccelerationCamera.X, -AccelerationCamera.Y) * pixelsPerStud
	local RotationRadians = math.rad(ParentRotation)
	local Cos = math.cos(RotationRadians)
	local Sin = math.sin(RotationRadians)

	emitter2D.Acceleration = Vector2.new(
		ScreenAcceleration.X * Cos + ScreenAcceleration.Y * Sin,
		-ScreenAcceleration.X * Sin + ScreenAcceleration.Y * Cos
	)

	ApplyOrientationAndPerspective(
		emitter2D,
		emitter3D,
		ParentRotation,
		LocalEmissionAngle,
		Facing,
		CameraCFrame
	)
end

--[=[
	Creates a `ParticleEmitter2D` mimic under `Parent`.

	@within Particles
]=]

function Particles.CreateMimic(scope : any, emitter3D : ParticleEmitter, parent : GuiObject, pixelsPerStud : number, rateScale : number?, emissionMode : Enum.ParticleEmitter2DEmissionMode?) : ParticleEmitter2D
	local ResolvedRateScale = rateScale or 1

	local Emitter2D = scope:New("ParticleEmitter2D", {
		Name = emitter3D.Name,
		Parent = parent,
		Enabled = emitter3D.Enabled,
		TextureContent = emitter3D.TextureContent,
		Color = emitter3D.Color,
		Transparency = emitter3D.Transparency,
		Lifetime = emitter3D.Lifetime,
		Rate = emitter3D.Rate * ResolvedRateScale,
		Drag = emitter3D.Drag,
		Brightness = emitter3D.Brightness,
		TimeScale = emitter3D.TimeScale,
		Rotation = emitter3D.Rotation,
		RotSpeed = emitter3D.RotSpeed,
		Squash = emitter3D.Squash,
		Blend = emitter3D.LightEmission,
		LockedToParent = emitter3D.LockedToPart,
		EmissionMode = emissionMode or Enum.ParticleEmitter2DEmissionMode.BoundingBox,
		SpreadAngle = AuthoredSpreadDegrees(emitter3D),
		EmissionSpread = Vector2.zero,
		FlipbookLayout = emitter3D.FlipbookLayout,
		FlipbookMode = emitter3D.FlipbookMode,
		FlipbookFramerate = emitter3D.FlipbookFramerate,
		FlipbookStartRandom = emitter3D.FlipbookStartRandom,
		FlipbookBlendFrames = emitter3D.FlipbookBlendFrames,
		FlipbookSizeX = emitter3D.FlipbookSizeX,
		FlipbookSizeY = emitter3D.FlipbookSizeY,
	})

	Emitter2D.Size = ScaleNumberSequence(emitter3D.Size, pixelsPerStud)
	Emitter2D.Speed = ScaleNumberRange(emitter3D.Speed, pixelsPerStud)
	Emitter2D.Acceleration = Vector2.new(emitter3D.Acceleration.X, -emitter3D.Acceleration.Y) * pixelsPerStud

	return Emitter2D
end

local function CreateAttachmentHost(scope : any, parent : Frame, name : string) : Frame
	return scope:New("Frame", {
		Name = name,
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = false,
	})
end

local function CaptureEmitterEnabled(emitter3D : ParticleEmitter) : boolean
	local Stored = emitter3D:GetAttribute(WAS_ENABLED_ATTRIBUTE)

	if typeof(Stored) == "boolean" then
		return Stored
	end

	local IsEmitterEnabled = emitter3D.Enabled
	emitter3D:SetAttribute(WAS_ENABLED_ATTRIBUTE, IsEmitterEnabled)
	return IsEmitterEnabled
end

local function AddBinding(bindings : {MimicBinding}, scope : any, emitter3D : ParticleEmitter, part : BasePart, boundsFrame : Frame, layer : "Front" | "Behind", pixelsPerStud : number, rateScale : number, attachment : Attachment?, emissionMode : Enum.ParticleEmitter2DEmissionMode, isEmitterEnabled : boolean)
	local HostFrame = nil
	local Parent = boundsFrame

	if attachment then
		HostFrame = CreateAttachmentHost(scope, boundsFrame, `{emitter3D.Name}_Point`)
		Parent = HostFrame
	end

	local Emitter2D = Particles.CreateMimic(scope, emitter3D, Parent, pixelsPerStud, rateScale, emissionMode)

	table.insert(bindings, {
		Emitter3D = emitter3D,
		Emitter2D = Emitter2D,
		Part = part,
		Layer = layer,
		Attachment = attachment,
		HostFrame = HostFrame,
		IsEmitterEnabled = isEmitterEnabled,
		IsLockedToPart = emitter3D.LockedToPart,
	})
end

local function GetVolumeLayerWeights(zOffset : number) : (number, number)
	if zOffset < 0 then
		return 0.92, 0.08
	elseif zOffset > 0 then
		return 0.7, 0.3
	end

	return 0.85, 0.15
end

--[=[
	Attaches 2D mimics for every `ParticleEmitter` under `Root`, disabling the 3D sources.

	Volume emitters split rate behind/front so ViewportFrame meshes can occlude.

	@within Particles
]=]

function Particles.AttachToBoundsFrames(scope : any, root : Instance, framesByPart : {[BasePart] : Overlays.PartFrames}, pixelsPerStud : number) : {MimicBinding}
	local Bindings = {}

	for _, emitter3D in root:QueryDescendants("ParticleEmitter") do
		local Part = emitter3D:FindFirstAncestorWhichIsA("BasePart")

		if not Part then
			continue
		end

		local Frames = framesByPart[Part]

		if not Frames then
			continue
		end

		local Attachment = if emitter3D.Parent and emitter3D.Parent:IsA("Attachment")
			then emitter3D.Parent
			else nil

		local ZOffset = emitter3D.ZOffset
		local IsVolume = emitter3D.ShapeStyle == Enum.ParticleEmitterShapeStyle.Volume
		-- Persist across rebuilds: we disable the 3D emitter after the first attach.
		local IsEmitterEnabled = CaptureEmitterEnabled(emitter3D)

		if Attachment then
			local LayerFrame = if ZOffset < 0 then Frames.Behind else Frames.Front
			local LayerName : "Front" | "Behind" = if ZOffset < 0 then "Behind" else "Front"
			AddBinding(
				Bindings,
				scope,
				emitter3D,
				Part,
				LayerFrame,
				LayerName,
				pixelsPerStud,
				1,
				Attachment,
				Enum.ParticleEmitter2DEmissionMode.Point,
				IsEmitterEnabled
			)
		elseif IsVolume then
			local BehindWeight, FrontWeight = GetVolumeLayerWeights(ZOffset)

			AddBinding(
				Bindings,
				scope,
				emitter3D,
				Part,
				Frames.Behind,
				"Behind",
				pixelsPerStud,
				BehindWeight,
				nil,
				Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				IsEmitterEnabled
			)
			AddBinding(
				Bindings,
				scope,
				emitter3D,
				Part,
				Frames.Front,
				"Front",
				pixelsPerStud,
				FrontWeight,
				nil,
				Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				IsEmitterEnabled
			)
		else
			local LayerFrame = if ZOffset < 0 then Frames.Behind else Frames.Front
			local LayerName : "Front" | "Behind" = if ZOffset < 0 then "Behind" else "Front"
			AddBinding(
				Bindings,
				scope,
				emitter3D,
				Part,
				LayerFrame,
				LayerName,
				pixelsPerStud,
				1,
				nil,
				Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				IsEmitterEnabled
			)
		end

		emitter3D.Enabled = false
	end

	return Bindings
end

--[=[
	Updates enable state, attachment hosts, depth ZIndex, and perspective each frame refresh.

	@within Particles
]=]

function Particles.UpdateMimics(scope : any, bindings : {MimicBinding}, camera : Camera, pixelSize : Vector2, depthByPart : {[BasePart] : number}, boundsByPart : {[BasePart] : Spatial.LayerBounds}, isParticlesVisible : boolean)
	local PartsByDepth = {}
	for part, depth in depthByPart do
		table.insert(PartsByDepth, {Part = part, Depth = depth})
	end

	table.sort(PartsByDepth, function(a, b)
		return a.Depth > b.Depth
	end)

	local DepthRankByPart : {[BasePart] : number} = {}
	for index, entry in PartsByDepth do
		DepthRankByPart[entry.Part] = index
	end

	for _, binding in bindings do
		local ShouldEnable = isParticlesVisible and binding.IsEmitterEnabled
		local DepthRank = DepthRankByPart[binding.Part] or 1

		scope:New(binding.Emitter2D, {
			Enabled = ShouldEnable,
			LockedToParent = binding.IsLockedToPart,
			ZIndex = DepthRank,
		})

		if not ShouldEnable then
			binding.Emitter2D:Clear()
		end

		local Depth = depthByPart[binding.Part]
		local Bounds = boundsByPart[binding.Part]

		if not Depth or not Bounds then
			continue
		end

		local PixelsPerStud = Spatial.GetPixelsPerStud(camera, Depth, pixelSize)

		if binding.Attachment and binding.HostFrame then
			local ScreenX, ScreenY, AttachmentDepth = Spatial.WorldToViewportPixels(
				camera,
				binding.Attachment.WorldPosition,
				pixelSize
			)

			if not ScreenX then
				scope:New(binding.HostFrame, {Visible = false,})
				continue
			end

			if AttachmentDepth then
				PixelsPerStud = Spatial.GetPixelsPerStud(camera, AttachmentDepth, pixelSize)
			end

			local DeltaX = (ScreenX :: number) - Bounds.CenterX
			local DeltaY = (ScreenY :: number) - Bounds.CenterY
			local RotationRadians = math.rad(Bounds.Rotation)
			local Cos = math.cos(RotationRadians)
			local Sin = math.sin(RotationRadians)
			local LocalX = DeltaX * Cos + DeltaY * Sin
			local LocalY = -DeltaX * Sin + DeltaY * Cos

			scope:New(binding.HostFrame, {
				Visible = true,
				Position = UDim2.fromOffset(LocalX + Bounds.Width * 0.5, LocalY + Bounds.Height * 0.5),
			})
		end

		Particles.ApplyMotionAndPerspective(
			binding.Emitter2D,
			binding.Emitter3D,
			camera,
			PixelsPerStud,
			binding.Part,
			binding.Attachment,
			Bounds.Rotation
		)
	end
end

return Particles