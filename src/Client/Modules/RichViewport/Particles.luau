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

local function OffsetRotationRange(Range : NumberRange, Degrees : number) : NumberRange
	return NumberRange.new(Range.Min - Degrees, Range.Max - Degrees)
end

local function AddRotationOffset(BaseDegrees : number, Range : NumberRange) : NumberRange
	return NumberRange.new(BaseDegrees + Range.Min, BaseDegrees + Range.Max)
end

local function NegateNumberSequence(Sequence : NumberSequence) : NumberSequence
	local Keypoints = table.create(#Sequence.Keypoints)

	for Index, Keypoint in Sequence.Keypoints do
		Keypoints[Index] = NumberSequenceKeypoint.new(
			Keypoint.Time,
			-Keypoint.Value,
			Keypoint.Envelope
		)
	end

	return NumberSequence.new(Keypoints)
end

-- Keep angles in a PE2D-friendly range (OBB unwrap can accumulate past ±360).
local function NormalizeDegrees(Degrees : number) : number
	local Wrapped = ((Degrees + 180) % 360 + 360) % 360 - 180
	return Wrapped
end

-- Wrap the center only — normalizing Min/Max independently can invert the range
-- (e.g. 170..190 → 170..-170) which NumberRange rejects.
local function NormalizeRotationRange(Range : NumberRange) : NumberRange
	local Center = NormalizeDegrees((Range.Min + Range.Max) * 0.5)
	local HalfSpan = math.abs(Range.Max - Range.Min) * 0.5
	return NumberRange.new(Center - HalfSpan, Center + HalfSpan)
end

-- Screen-space projection of a world direction: angle, and how much of the vector
-- lies in the screen plane (0 = pure depth, 1 = pure lateral).
local function ProjectWorldDirectionToScreen(CameraCFrame : CFrame, WorldDirection : Vector3) : (number?, number)
	local CameraVector = CameraCFrame:VectorToObjectSpace(WorldDirection)
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

-- Below this, the XY residual of a view-aligned axis is noise and can flip 180°.
local VIEW_ALIGNED_THRESHOLD = 0.22

-- ParticleEmitter2D.EmissionAngle: 0 = parent local up, 90 = right, 180 = down
-- (same zero as GuiObject.Rotation). Our atan2 uses 0 = screen right → convert +90.
local function ScreenAtan2ToPE2D(ScreenAtan2Degrees : number) : number
	return NormalizeDegrees(ScreenAtan2Degrees + 90)
end

local function HorizontalBias(ScreenAtan2Degrees : number) : number
	-- Prefer left/right over up/down when fallback axes tie (Circles face-on → left).
	local Normalized = ((ScreenAtan2Degrees % 180) + 180) % 180
	local DistFromHorizontal = math.min(Normalized, 180 - Normalized)
	return 1 - math.clamp(DistFromHorizontal / 90, 0, 1)
end

local function PerpendicularBasis(Axis : Vector3, EmitterCFrame : CFrame) : (Vector3, Vector3)
	local Normal = if Axis.Magnitude > 1e-8 then Axis.Unit else EmitterCFrame.LookVector
	local Hint = EmitterCFrame.RightVector
	if math.abs(Hint:Dot(Normal)) > 0.95 then
		Hint = EmitterCFrame.UpVector
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
local function ResolveLocalEmissionAngle(
	CameraCFrame : CFrame,
	EmissionDirection : Vector3,
	EmitterCFrame : CFrame,
	ParentRotation : number
) : (number, number)
	local ScreenAngle, ScreenFraction = ProjectWorldDirectionToScreen(CameraCFrame, EmissionDirection)

	if ScreenAngle and ScreenFraction >= VIEW_ALIGNED_THRESHOLD then
		return NormalizeDegrees(ScreenAtan2ToPE2D(ScreenAngle) - ParentRotation), ScreenFraction
	end

	local U, V = PerpendicularBasis(EmissionDirection, EmitterCFrame)
	local UAngle, UFraction = ProjectWorldDirectionToScreen(CameraCFrame, U)
	local VAngle, VFraction = ProjectWorldDirectionToScreen(CameraCFrame, V)

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
		return NormalizeDegrees(ScreenAtan2ToPE2D(BestAngle) - ParentRotation), math.max(ScreenFraction, BestFraction)
	end

	-- Parent-local up (PE2D 0).
	return NormalizeDegrees(-ParentRotation), 1
end

local function AuthoredSpreadDegrees(Emitter3D : ParticleEmitter) : number
	return math.clamp(
		math.max(math.abs(Emitter3D.SpreadAngle.X), math.abs(Emitter3D.SpreadAngle.Y)),
		0,
		360
	)
end

local function BlendNumberSequence(From : NumberSequence, To : NumberSequence, Alpha : number) : NumberSequence
	local Count = math.max(#From.Keypoints, #To.Keypoints)
	local Keypoints = table.create(Count)
	local Blended = math.clamp(Alpha, 0, 1)

	for Index = 1, Count do
		local A = From.Keypoints[math.min(Index, #From.Keypoints)]
		local B = To.Keypoints[math.min(Index, #To.Keypoints)]
		Keypoints[Index] = NumberSequenceKeypoint.new(
			A.Time + (B.Time - A.Time) * Blended,
			A.Value + (B.Value - A.Value) * Blended,
			A.Envelope + (B.Envelope - A.Envelope) * Blended
		)
	end

	return NumberSequence.new(Keypoints)
end

local function ScaleNumberRangeValues(Range : NumberRange, Scale : number) : NumberRange
	return NumberRange.new(Range.Min * Scale, Range.Max * Scale)
end

-- Palm foreshortening only for velocity-oriented particles (face along travel).
local EDGE_ON_SQUASH = NumberSequence.new(0.35)

local function GetPalmFacing(CameraCFrame : CFrame, PalmNormal : Vector3) : number
	if PalmNormal.Magnitude <= 1e-8 then
		return 1
	end

	return math.abs(PalmNormal.Unit:Dot(-CameraCFrame.LookVector))
end

local function ApplyOrientationAndPerspective(
	Emitter2D : ParticleEmitter2D,
	Emitter3D : ParticleEmitter,
	ParentRotation : number,
	LocalEmissionAngle : number?,
	Facing : number,
	CameraCFrame : CFrame
)
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

	@within Particles
]=]
function Particles.ApplyMotionAndPerspective(Emitter2D : ParticleEmitter2D, Emitter3D : ParticleEmitter, Camera : Camera, PixelsPerStud : number, Part : BasePart, Attachment : Attachment?, FrameRotation : number?)
	local CameraCFrame = Camera.CFrame
	local ParentRotation = FrameRotation or 0
	local EmitterCFrame = GetEmitterCFrame(Part, Attachment)
	local EmissionDirection = GetEmissionWorldDirection(Emitter3D, Part, Attachment)
	local Orientation = Emitter3D.Orientation

	local LocalEmissionAngle, ScreenFraction = ResolveLocalEmissionAngle(
		CameraCFrame,
		EmissionDirection,
		EmitterCFrame,
		ParentRotation
	)

	local UsePalm = Orientation == Enum.ParticleOrientation.VelocityParallel
		or Orientation == Enum.ParticleOrientation.VelocityPerpendicular
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

	ApplyOrientationAndPerspective(
		Emitter2D,
		Emitter3D,
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

local WAS_ENABLED_ATTRIBUTE = "RichViewportWasEnabled"

local function CaptureWasEnabled(Emitter3D : ParticleEmitter) : boolean
	local Stored = Emitter3D:GetAttribute(WAS_ENABLED_ATTRIBUTE)
	if typeof(Stored) == "boolean" then
		return Stored
	end

	local WasEnabled = Emitter3D.Enabled
	Emitter3D:SetAttribute(WAS_ENABLED_ATTRIBUTE, WasEnabled)
	return WasEnabled
end

local function AddBinding(Bindings : {MimicBinding}, Scope : any, Emitter3D : ParticleEmitter, Part : BasePart, BoundsFrame : Frame, Layer : "Front" | "Behind", PixelsPerStud : number, RateScale : number, Attachment : Attachment?, EmissionMode : Enum.ParticleEmitter2DEmissionMode, WasEnabled : boolean)
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
		WasEnabled = WasEnabled,
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
		-- Persist across rebuilds: we disable the 3D emitter after the first attach.
		local WasEnabled = CaptureWasEnabled(Emitter3D)

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
				Enum.ParticleEmitter2DEmissionMode.Point,
				WasEnabled
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
				Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				WasEnabled
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
				Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				WasEnabled
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
				Enum.ParticleEmitter2DEmissionMode.BoundingBox,
				WasEnabled
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
function Particles.UpdateMimics(Scope : any, Bindings : {MimicBinding}, Camera : Camera, PixelSize : Vector2, DepthByPart : {[BasePart] : number}, BoundsByPart : {[BasePart] : Spatial.LayerBounds}, ShowParticles : boolean)
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

			local DeltaX = (ScreenX :: number) - Bounds.CenterX
			local DeltaY = (ScreenY :: number) - Bounds.CenterY
			local RotationRadians = math.rad(Bounds.Rotation)
			local Cos = math.cos(RotationRadians)
			local Sin = math.sin(RotationRadians)
			local LocalX = DeltaX * Cos + DeltaY * Sin
			local LocalY = -DeltaX * Sin + DeltaY * Cos

			Scope:New(Binding.HostFrame, {
				Visible = true,
				Position = UDim2.fromOffset(LocalX + Bounds.Width * 0.5, LocalY + Bounds.Height * 0.5),
			})
		end

		Particles.ApplyMotionAndPerspective(
			Binding.Emitter2D,
			Binding.Emitter3D,
			Camera,
			PixelsPerStud,
			Binding.Part,
			Binding.Attachment,
			Bounds.Rotation
		)
	end
end

return Particles
