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

type ApplyOrientationAndPerspectiveProps = {
	Emitter2D : ParticleEmitter2D,
	Emitter3D : ParticleEmitter,
	ParentRotation : number,
	LocalEmissionAngle : number?,
	Facing : number,
	CameraCFrame : CFrame,
}

export type CreateMimicProps = {
	Scope : any,
	Emitter3D : ParticleEmitter,
	Parent : GuiObject,
	PixelsPerStud : number,
	RateScale : number?,
	EmissionMode : Enum.ParticleEmitter2DEmissionMode?,
}

export type ApplyMotionAndPerspectiveProps = {
	Emitter2D : ParticleEmitter2D,
	Emitter3D : ParticleEmitter,
	Camera : Camera,
	PixelsPerStud : number,
	Part : BasePart,
	Attachment : Attachment?,
	FrameRotation : number?,
}

type AddBindingProps = {
	Bindings : {MimicBinding},
	Scope : any,
	Emitter3D : ParticleEmitter,
	Part : BasePart,
	BoundsFrame : Frame,
	Layer : "Front" | "Behind",
	PixelsPerStud : number,
	RateScale : number,
	Attachment : Attachment?,
	EmissionMode : Enum.ParticleEmitter2DEmissionMode,
	IsEmitterEnabled : boolean,
}

-- Constants
const VIEW_ALIGNED_THRESHOLD = 0.22
const WAS_ENABLED_ATTRIBUTE = "RichViewportWasEnabled"
const EDGE_ON_SQUASH = NumberSequence.new(0.35)

-- Imports
local Spatial = require(script.Parent.Spatial)
local Overlays = require(script.Parent.Overlays)

export type UpdateMimicsProps = {
	Scope : any,
	Bindings : {MimicBinding},
	Camera : Camera,
	PixelSize : Vector2,
	DepthByPart : {[BasePart] : number},
	BoundsByPart : {[BasePart] : Spatial.LayerBounds},
	IsParticlesVisible : boolean,
}

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

local function ApplyOrientationAndPerspective(props : ApplyOrientationAndPerspectiveProps)
	local Emitter2D = props.Emitter2D
	local Emitter3D = props.Emitter3D
	local ParentRotation = props.ParentRotation
	local LocalEmissionAngle = props.LocalEmissionAngle
	local Facing = props.Facing
	local CameraCFrame = props.CameraCFrame

	local Orientation = Emitter3D.Orientation
	local Squash = Emitter3D.Squash
	local EdgeOn = (1 - Facing) ^ 2
	local SpinScale = Facing * Facing

	if Orientation == Enum.ParticleOrientation.FacingCamera then
		-- Billboard: exact authored appearance, parent-local spin only.
		Emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(Emitter3D.Rotation, ParentRotation))
		Emitter2D.Squash = Squash
		Emitter2D.RotSpeed = Emitter3D.RotSpeed
		return
	end

	if Orientation == Enum.ParticleOrientation.FacingCameraWorldUp then
		-- PE2D / GuiObject zero = local up; keep local Y on projected world up.
		local ScreenUpAngle = select(1, ProjectWorldDirectionToScreen(CameraCFrame, Vector3.yAxis))

		if ScreenUpAngle then
			local LocalUpAlign = NormalizeDegrees(ScreenAtan2ToPE2D(ScreenUpAngle) - ParentRotation)
			Emitter2D.Rotation = NormalizeRotationRange(AddRotationOffset(LocalUpAlign, Emitter3D.Rotation))
		else
			Emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(Emitter3D.Rotation, ParentRotation))
		end
		Emitter2D.Squash = Squash
		Emitter2D.RotSpeed = Emitter3D.RotSpeed
		return
	end

	if Orientation == Enum.ParticleOrientation.VelocityParallel then
		if LocalEmissionAngle then
			-- Local Y along travel: Rotation = EmissionAngle when both use 0 = local up.
			Emitter2D.Rotation = NormalizeRotationRange(
				AddRotationOffset(LocalEmissionAngle, ScaleNumberRangeValues(Emitter3D.Rotation, SpinScale))
			)
			Emitter2D.Squash = BlendNumberSequence(NegateNumberSequence(Squash), EDGE_ON_SQUASH, EdgeOn)
			Emitter2D.RotSpeed = ScaleNumberRangeValues(Emitter3D.RotSpeed, SpinScale)
		else
			Emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(Emitter3D.Rotation, ParentRotation))
			Emitter2D.Squash = Squash
			Emitter2D.RotSpeed = Emitter3D.RotSpeed
		end
		return
	end

	if Orientation == Enum.ParticleOrientation.VelocityPerpendicular then
		-- Face-on: billboard. Edge-on: soft squash + damp spin; bias local Y across travel.
		local BillboardRotation = OffsetRotationRange(Emitter3D.Rotation, ParentRotation)

		if LocalEmissionAngle and EdgeOn > 0.05 then
			local AlignedRotation = AddRotationOffset(
				LocalEmissionAngle + 90,
				ScaleNumberRangeValues(Emitter3D.Rotation, SpinScale)
			)
			local BillboardCenter = (BillboardRotation.Min + BillboardRotation.Max) * 0.5
			local AlignedCenter = (AlignedRotation.Min + AlignedRotation.Max) * 0.5
			local Center = BillboardCenter + (AlignedCenter - BillboardCenter) * EdgeOn
			local HalfSpan = math.abs(BillboardRotation.Max - BillboardRotation.Min) * 0.5
			Emitter2D.Rotation = NormalizeRotationRange(NumberRange.new(Center - HalfSpan, Center + HalfSpan))
			Emitter2D.Squash = BlendNumberSequence(Squash, EDGE_ON_SQUASH, EdgeOn)
			Emitter2D.RotSpeed = ScaleNumberRangeValues(Emitter3D.RotSpeed, SpinScale)
		else
			Emitter2D.Rotation = NormalizeRotationRange(BillboardRotation)
			Emitter2D.Squash = Squash
			Emitter2D.RotSpeed = Emitter3D.RotSpeed
		end
		return
	end

	Emitter2D.Rotation = NormalizeRotationRange(OffsetRotationRange(Emitter3D.Rotation, ParentRotation))
	Emitter2D.Squash = Squash
	Emitter2D.RotSpeed = Emitter3D.RotSpeed
end

--[=[
	Copies motion/appearance scales into a mimic for the current camera depth.

	`FrameRotation` is the emit host's GuiObject.Rotation. EmissionAngle / Acceleration /
	sprite Rotation are converted into parent-local space so AbsoluteRotation does not
	yaw particles relative to the screen.

	FacingCamera copies Squash/RotSpeed/Rotation (parent-local) with no palm foreshortening.
	Velocity* modes get soft palm squash + spin damping.

	@param props ApplyMotionAndPerspectiveProps
	@within Particles
]=]

function Particles.ApplyMotionAndPerspective(props : ApplyMotionAndPerspectiveProps)
	local Emitter2D = props.Emitter2D
	local Emitter3D = props.Emitter3D
	local CameraCFrame = props.Camera.CFrame
	local ParentRotation = props.FrameRotation or 0
	local EmitterCFrame = GetEmitterCFrame(props.Part, props.Attachment)
	local EmissionDirection = GetEmissionWorldDirection(Emitter3D, props.Part, props.Attachment)
	local Orientation = Emitter3D.Orientation
	local PixelsPerStud = props.PixelsPerStud

	local LocalEmissionAngle, ScreenFraction = ResolveLocalEmissionAngle(
		CameraCFrame,
		EmissionDirection,
		EmitterCFrame,
		ParentRotation
	)

	local UsePalm = if Orientation == Enum.ParticleOrientation.VelocityParallel or Orientation == Enum.ParticleOrientation.VelocityPerpendicular then true else false
	local Facing = if UsePalm then GetPalmFacing(CameraCFrame, EmissionDirection) else 1
	local SpeedFraction = if UsePalm then math.max(ScreenFraction, 0.35) else 1

	Emitter2D.Size = ScaleNumberSequence(Emitter3D.Size, PixelsPerStud)
	Emitter2D.Speed = ScaleNumberRange(Emitter3D.Speed, PixelsPerStud * SpeedFraction)
	-- SpreadAngle alone; EmissionSpread left at default — dual-writing 360/360 broke FacingCamera bursts.
	Emitter2D.SpreadAngle = AuthoredSpreadDegrees(Emitter3D)
	Emitter2D.EmissionSpread = Vector2.zero
	-- Always refresh — skipping left a stale angle when the axis swept through view-aligned.
	Emitter2D.EmissionAngle = LocalEmissionAngle

	local AccelerationCamera = CameraCFrame:VectorToObjectSpace(Emitter3D.Acceleration)
	local ScreenAcceleration = Vector2.new(AccelerationCamera.X, -AccelerationCamera.Y) * PixelsPerStud
	local RotationRadians = math.rad(ParentRotation)
	local Cos = math.cos(RotationRadians)
	local Sin = math.sin(RotationRadians)

	Emitter2D.Acceleration = Vector2.new(
		ScreenAcceleration.X * Cos + ScreenAcceleration.Y * Sin,
		-ScreenAcceleration.X * Sin + ScreenAcceleration.Y * Cos
	)

	ApplyOrientationAndPerspective({
		Emitter2D = Emitter2D,
		Emitter3D = Emitter3D,
		ParentRotation = ParentRotation,
		LocalEmissionAngle = LocalEmissionAngle,
		Facing = Facing,
		CameraCFrame = CameraCFrame,
	})
end

--[=[
	Creates a `ParticleEmitter2D` mimic under `Parent`.

	@param props CreateMimicProps
	@within Particles
]=]

function Particles.CreateMimic(props : CreateMimicProps) : ParticleEmitter2D
	local Emitter3D = props.Emitter3D
	local PixelsPerStud = props.PixelsPerStud
	local ResolvedRateScale = props.RateScale or 1

	local Emitter2D = props.Scope:New("ParticleEmitter2D", {
		Name = Emitter3D.Name,
		Parent = props.Parent,
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
		EmissionMode = props.EmissionMode or Enum.ParticleEmitter2DEmissionMode.BoundingBox,
		SpreadAngle = AuthoredSpreadDegrees(Emitter3D),
		EmissionSpread = Vector2.zero,
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

local function AddBinding(props : AddBindingProps)
	local Emitter3D = props.Emitter3D
	local HostFrame = nil
	local Parent = props.BoundsFrame

	if props.Attachment then
		HostFrame = CreateAttachmentHost(props.Scope, props.BoundsFrame, `{Emitter3D.Name}_Point`)
		Parent = HostFrame
	end

	local Emitter2D = Particles.CreateMimic({
		Scope = props.Scope,
		Emitter3D = Emitter3D,
		Parent = Parent,
		PixelsPerStud = props.PixelsPerStud,
		RateScale = props.RateScale,
		EmissionMode = props.EmissionMode,
	})

	table.insert(props.Bindings, {
		Emitter3D = Emitter3D,
		Emitter2D = Emitter2D,
		Part = props.Part,
		Layer = props.Layer,
		Attachment = props.Attachment,
		HostFrame = HostFrame,
		IsEmitterEnabled = props.IsEmitterEnabled,
		IsLockedToPart = Emitter3D.LockedToPart,
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
			AddBinding({
				Bindings = Bindings,
				Scope = scope,
				Emitter3D = emitter3D,
				Part = Part,
				BoundsFrame = LayerFrame,
				Layer = LayerName,
				PixelsPerStud = pixelsPerStud,
				RateScale = 1,
				Attachment = Attachment,
				EmissionMode = Enum.ParticleEmitter2DEmissionMode.Point,
				IsEmitterEnabled = IsEmitterEnabled,
			})
		elseif IsVolume then
			local BehindWeight, FrontWeight = GetVolumeLayerWeights(ZOffset)

			AddBinding({
				Bindings = Bindings,
				Scope = scope,
				Emitter3D = emitter3D,
				Part = Part,
				BoundsFrame = Frames.Behind,
				Layer = "Behind",
				PixelsPerStud = pixelsPerStud,
				RateScale = BehindWeight,
				Attachment = nil,
				EmissionMode = Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				IsEmitterEnabled = IsEmitterEnabled,
			})
			AddBinding({
				Bindings = Bindings,
				Scope = scope,
				Emitter3D = emitter3D,
				Part = Part,
				BoundsFrame = Frames.Front,
				Layer = "Front",
				PixelsPerStud = pixelsPerStud,
				RateScale = FrontWeight,
				Attachment = nil,
				EmissionMode = Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				IsEmitterEnabled = IsEmitterEnabled,
			})
		else
			local LayerFrame = if ZOffset < 0 then Frames.Behind else Frames.Front
			local LayerName : "Front" | "Behind" = if ZOffset < 0 then "Behind" else "Front"
			AddBinding({
				Bindings = Bindings,
				Scope = scope,
				Emitter3D = emitter3D,
				Part = Part,
				BoundsFrame = LayerFrame,
				Layer = LayerName,
				PixelsPerStud = pixelsPerStud,
				RateScale = 1,
				Attachment = nil,
				EmissionMode = Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				IsEmitterEnabled = IsEmitterEnabled,
			})
		end

		emitter3D.Enabled = false
	end

	return Bindings
end

--[=[
	Updates enable state, attachment hosts, depth ZIndex, and perspective each frame refresh.

	@param props UpdateMimicsProps
	@within Particles
]=]

function Particles.UpdateMimics(props : UpdateMimicsProps)
	local Scope = props.Scope
	local Camera = props.Camera
	local PixelSize = props.PixelSize
	local BoundsByPart = props.BoundsByPart
	local IsParticlesVisible = props.IsParticlesVisible

	local PartsByDepth = {}
	for part, depth in props.DepthByPart do
		table.insert(PartsByDepth, {Part = part, Depth = depth})
	end

	table.sort(PartsByDepth, function(a, b)
		return a.Depth > b.Depth
	end)

	local DepthRankByPart : {[BasePart] : number} = {}
	for index, entry in PartsByDepth do
		DepthRankByPart[entry.Part] = index
	end

	for _, binding in props.Bindings do
		local ShouldEnable = IsParticlesVisible and binding.IsEmitterEnabled
		local DepthRank = DepthRankByPart[binding.Part] or 1

		Scope:New(binding.Emitter2D, {
			Enabled = ShouldEnable,
			LockedToParent = binding.IsLockedToPart,
			ZIndex = DepthRank,
		})

		if not ShouldEnable then
			binding.Emitter2D:Clear()
		end

		local Depth = props.DepthByPart[binding.Part]
		local Bounds = BoundsByPart[binding.Part]

		if not Depth or not Bounds then
			continue
		end

		local PixelsPerStud = Spatial.GetPixelsPerStud(Camera, Depth, PixelSize)

		if binding.Attachment and binding.HostFrame then
			local ScreenX, ScreenY, AttachmentDepth = Spatial.WorldToViewportPixels(
				Camera,
				binding.Attachment.WorldPosition,
				PixelSize
			)

			if not ScreenX then
				Scope:New(binding.HostFrame, {Visible = false,})
				continue
			end

			if AttachmentDepth then
				PixelsPerStud = Spatial.GetPixelsPerStud(Camera, AttachmentDepth, PixelSize)
			end

			local DeltaX = (ScreenX :: number) - Bounds.CenterX
			local DeltaY = (ScreenY :: number) - Bounds.CenterY
			local RotationRadians = math.rad(Bounds.Rotation)
			local Cos = math.cos(RotationRadians)
			local Sin = math.sin(RotationRadians)
			local LocalX = DeltaX * Cos + DeltaY * Sin
			local LocalY = -DeltaX * Sin + DeltaY * Cos

			Scope:New(binding.HostFrame, {
				Visible = true,
				Position = UDim2.fromOffset(LocalX + Bounds.Width * 0.5, LocalY + Bounds.Height * 0.5),
			})
		end

		Particles.ApplyMotionAndPerspective({
			Emitter2D = binding.Emitter2D,
			Emitter3D = binding.Emitter3D,
			Camera = Camera,
			PixelsPerStud = PixelsPerStud,
			Part = binding.Part,
			Attachment = binding.Attachment,
			FrameRotation = Bounds.Rotation,
		})
	end
end

return Particles