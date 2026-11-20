--[=[
	Maps 3D ParticleEmitters onto ParticleEmitter2D instances for ViewportFrame overlays.

	@class ViewportParticles
]=]

local ViewportParticles = {}

export type PartFrames = {
	Front : Frame, -- unrotated emission host (screen AABB)
	Behind : Frame, -- unrotated emission host (screen AABB)
	Guide : Frame, -- oriented ShowBounds stroke only (no emitters)
}

-- Emission hosts stay Rotation=0. Guide may use Rotation for an oriented debug stroke.
export type ScreenBounds = {
	CenterX : number,
	CenterY : number,
	Width : number,
	Height : number,
	Depth : number,
}

export type OrientedScreenBounds = {
	CenterX : number,
	CenterY : number,
	Width : number,
	Height : number,
	Rotation : number, -- degrees
	Depth : number,
}

export type PartScreenBounds = {
	Emit : ScreenBounds,
	Guide : OrientedScreenBounds,
}

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

local CORNER_OFFSETS = {
	Vector3.new(-1, -1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, 1, 1),
}

-- ParticleEmitter Size/Speed are studs; ParticleEmitter2D are pixels.
-- Squash is unitless with the same semantics on both — copy 1:1, do not rescale.
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

local function FitOrientedBounds(Points : {Vector2}, AngleRadians : number) : (number, number, number, number)
	local Cos = math.cos(AngleRadians)
	local Sin = math.sin(AngleRadians)

	local MinX = math.huge
	local MinY = math.huge
	local MaxX = -math.huge
	local MaxY = -math.huge

	for _, Point in Points do
		-- Rotate by -Angle into the candidate frame's local axes.
		local LocalX = Point.X * Cos + Point.Y * Sin
		local LocalY = -Point.X * Sin + Point.Y * Cos

		MinX = math.min(MinX, LocalX)
		MinY = math.min(MinY, LocalY)
		MaxX = math.max(MaxX, LocalX)
		MaxY = math.max(MaxY, LocalY)
	end

	local Width = MaxX - MinX
	local Height = MaxY - MinY
	local LocalCenterX = (MinX + MaxX) * 0.5
	local LocalCenterY = (MinY + MaxY) * 0.5

	-- Rotate local center back into screen space.
	local CenterX = LocalCenterX * Cos - LocalCenterY * Sin
	local CenterY = LocalCenterX * Sin + LocalCenterY * Cos

	return Width, Height, CenterX, CenterY
end

local function ScreenAngleOfWorldAxis(Camera : Camera, Origin : Vector3, Axis : Vector3, PixelSize : Vector2) : number?
	local OriginX, OriginY = ViewportParticles.WorldToViewportPixels(Camera, Origin, PixelSize)
	local TipX, TipY = ViewportParticles.WorldToViewportPixels(Camera, Origin + Axis, PixelSize)

	if not OriginX or not TipX then
		return nil
	end

	local DeltaX = (TipX :: number) - (OriginX :: number)
	local DeltaY = (TipY :: number) - (OriginY :: number)

	if DeltaX * DeltaX + DeltaY * DeltaY <= 1e-6 then
		return nil
	end

	return math.atan2(DeltaY, DeltaX)
end

-- Projected part corners → unrotated emission AABB + oriented guide OBB for ShowBounds.
-- Emitters must not parent under a rotating GuiObject: ParticleEmitter2D / LockedToParent
-- inherit Frame.Rotation, and min-area OBB angle snaps mid-drag cause particle glitches.
function ViewportParticles.GetPartScreenBounds(Camera : Camera, Part : BasePart, PixelSize : Vector2) : PartScreenBounds?
	if PixelSize.X <= 0 or PixelSize.Y <= 0 then
		return nil
	end

	local HalfSize = Part.Size * 0.5
	local PartCFrame = Part.CFrame
	local Points = {}
	local DepthSum = 0
	local SampleCount = 0

	local MinX = math.huge
	local MinY = math.huge
	local MaxX = -math.huge
	local MaxY = -math.huge

	for _, Offset in CORNER_OFFSETS do
		local WorldPoint = PartCFrame:PointToWorldSpace(Offset * HalfSize)
		local PixelX, PixelY, Depth = ViewportParticles.WorldToViewportPixels(Camera, WorldPoint, PixelSize)

		if not PixelX then
			continue
		end

		local Point = Vector2.new(PixelX, PixelY)
		table.insert(Points, Point)
		MinX = math.min(MinX, Point.X)
		MinY = math.min(MinY, Point.Y)
		MaxX = math.max(MaxX, Point.X)
		MaxY = math.max(MaxY, Point.Y)
		DepthSum += Depth :: number
		SampleCount += 1
	end

	if SampleCount == 0 then
		return nil
	end

	local Depth = DepthSum / SampleCount
	local EmitWidth = math.max(MaxX - MinX, 1)
	local EmitHeight = math.max(MaxY - MinY, 1)
	local EmitCenterX = (MinX + MaxX) * 0.5
	local EmitCenterY = (MinY + MaxY) * 0.5

	local CandidateAngles = {0}
	local Origin = PartCFrame.Position

	for _, Axis in {PartCFrame.RightVector, PartCFrame.UpVector, PartCFrame.LookVector} do
		local Angle = ScreenAngleOfWorldAxis(Camera, Origin, Axis, PixelSize)
		if Angle then
			table.insert(CandidateAngles, Angle)
		end
	end

	local BestArea = math.huge
	local BestWidth = EmitWidth
	local BestHeight = EmitHeight
	local BestCenterX = EmitCenterX
	local BestCenterY = EmitCenterY
	local BestAngle = 0

	for _, Angle in CandidateAngles do
		local Width, Height, CenterX, CenterY = FitOrientedBounds(Points, Angle)
		local Area = Width * Height

		if Area < BestArea then
			BestArea = Area
			BestWidth = Width
			BestHeight = Height
			BestCenterX = CenterX
			BestCenterY = CenterY
			BestAngle = Angle
		end
	end

	return {
		Emit = {
			CenterX = EmitCenterX,
			CenterY = EmitCenterY,
			Width = EmitWidth,
			Height = EmitHeight,
			Depth = Depth,
		},
		Guide = {
			CenterX = BestCenterX,
			CenterY = BestCenterY,
			Width = math.max(BestWidth, 1),
			Height = math.max(BestHeight, 1),
			Rotation = math.deg(BestAngle),
			Depth = Depth,
		},
	}
end

function ViewportParticles.ApplyMotionAndPerspective(Emitter2D : ParticleEmitter2D, Emitter3D : ParticleEmitter, Camera : Camera, PixelsPerStud : number, Part : BasePart, Attachment : Attachment?)
	local CameraCFrame = Camera.CFrame
	local EmissionDirection = GetEmissionWorldDirection(Emitter3D, Part, Attachment)

	-- Same geometric scale for Size and Speed keeps their authored ratio (studs → pixels).
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

	-- ParticleEmitter2D squash stretches local Y. For VelocityParallel, aim local Y along emission.
	if Emitter3D.Orientation == Enum.ParticleOrientation.VelocityParallel then
		local AlignedRotation = EmissionAngleDegrees - 90
		Emitter2D.Rotation = NumberRange.new(AlignedRotation, AlignedRotation)
	else
		Emitter2D.Rotation = Emitter3D.Rotation
	end
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

	-- Camera is not available at create time for full perspective; depth scale only.
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

	local Emitter2D = ViewportParticles.CreateMimic(Scope, Emitter3D, Parent, PixelsPerStud, RateScale, EmissionMode)

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

-- Volume emitters fill projected part bounds (BoundingBox). Most rate goes Behind the
-- ViewportFrame so other 3D parts can occlude them (inter-object depth). A small Front
-- shell keeps near-camera surface sparkle. ZOffset only biases that split.
local function GetVolumeLayerWeights(ZOffset : number) : (number, number)
	if ZOffset < 0 then
		return 0.92, 0.08
	elseif ZOffset > 0 then
		return 0.7, 0.3
	end

	return 0.85, 0.15
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
			-- Surface-style: spawn across the silhouette on a single depth layer.
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

function ViewportParticles.UpdateMimics(Scope : any, Bindings : {MimicBinding}, Camera : Camera, PixelSize : Vector2, DepthByPart : {[BasePart] : number}, BoundsByPart : {[BasePart] : ScreenBounds}, ShowParticles : boolean)
	-- Nearer parts get higher ZIndex so Front-shell particles from close parts cover far ones.
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

		local PixelsPerStud = ViewportParticles.GetPixelsPerStud(Camera, Depth, PixelSize)

		if Binding.Attachment and Binding.HostFrame then
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
			end

			Scope:New(Binding.HostFrame, {
				Visible = true,
				Position = UDim2.fromOffset(
					(ScreenX :: number) - Bounds.CenterX + Bounds.Width * 0.5,
					(ScreenY :: number) - Bounds.CenterY + Bounds.Height * 0.5
				),
			})
		end

		ViewportParticles.ApplyMotionAndPerspective(
			Binding.Emitter2D,
			Binding.Emitter3D,
			Camera,
			PixelsPerStud,
			Binding.Part,
			Binding.Attachment
		)
	end
end

return ViewportParticles
