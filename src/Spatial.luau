--[=[
	Screen-space projection and part bounds for viewport overlays.

	@class Spatial
]=]

local Spatial = {}

-- Single layer bounds used for Behind, Front, and Guide together.
export type LayerBounds = {
	CenterX : number,
	CenterY : number,
	Width : number,
	Height : number,
	Rotation : number, -- degrees
	Depth : number,
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

local AREA_KEEP_RATIO = 1.12

--[=[
	Collects every `BasePart` under `Root`, including `Root` itself when applicable.

	@within Spatial
]=]
function Spatial.CollectParts(Root : Instance) : {BasePart}
	local Parts = {}

	if Root:IsA("BasePart") then
		table.insert(Parts, Root)
	end

	for _, Descendant in Root:QueryDescendants("BasePart") do
		table.insert(Parts, Descendant)
	end

	return Parts
end

--[=[
	World point → viewport pixels using vertical FOV and `PixelSize` aspect.
	Returns `nil` when the point is behind the camera.

	@within Spatial
]=]
function Spatial.WorldToViewportPixels(Camera : Camera, WorldPoint : Vector3, PixelSize : Vector2) : (number?, number?, number?)
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

--[=[
	Pixels per stud at a given camera depth.

	@within Spatial
]=]
function Spatial.GetPixelsPerStud(Camera : Camera, Depth : number, PixelSize : Vector2) : number
	if Depth <= 0 or PixelSize.Y <= 0 then
		return 1
	end

	local HalfHeight = math.tan(math.rad(Camera.FieldOfView) * 0.5) * Depth
	return PixelSize.Y / (2 * HalfHeight)
end

--[=[
	Bounding focus CFrame for a model or part (used when framing a camera).

	@within Spatial
]=]
function Spatial.GetFocusCFrame(Root : Instance) : CFrame
	if Root:IsA("Model") then
		return select(1, Root:GetBoundingBox())
	end

	if Root:IsA("BasePart") then
		return Root.CFrame
	end

	return CFrame.new()
end

local function FitOrientedBounds(Points : {Vector2}, AngleRadians : number) : (number, number, number, number)
	local Cos = math.cos(AngleRadians)
	local Sin = math.sin(AngleRadians)

	local MinX = math.huge
	local MinY = math.huge
	local MaxX = -math.huge
	local MaxY = -math.huge

	for _, Point in Points do
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

	local CenterX = LocalCenterX * Cos - LocalCenterY * Sin
	local CenterY = LocalCenterX * Sin + LocalCenterY * Cos

	return Width, Height, CenterX, CenterY
end

local function ScreenAngleOfWorldAxis(Camera : Camera, Origin : Vector3, Axis : Vector3, PixelSize : Vector2) : number?
	local OriginX, OriginY = Spatial.WorldToViewportPixels(Camera, Origin, PixelSize)
	local TipX, TipY = Spatial.WorldToViewportPixels(Camera, Origin + Axis, PixelSize)

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

local function ShortestAngleDeltaDegrees(From : number, To : number) : number
	local Delta = (To - From + 180) % 360 - 180
	return Delta
end

--[=[
	Oriented screen bounds for a part (shared by emit + debug layers).

	`PreviousRotation` keeps the angle stable across refreshes so layers and
	`LockedToParent` particles do not snap when face-axis candidates trade places.

	@within Spatial
]=]
function Spatial.GetPartLayerBounds(Camera : Camera, Part : BasePart, PixelSize : Vector2, PreviousRotation : number?) : LayerBounds?
	if PixelSize.X <= 0 or PixelSize.Y <= 0 then
		return nil
	end

	local HalfSize = Part.Size * 0.5
	local PartCFrame = Part.CFrame
	local Points = {}
	local DepthSum = 0
	local SampleCount = 0

	for _, Offset in CORNER_OFFSETS do
		local WorldPoint = PartCFrame:PointToWorldSpace(Offset * HalfSize)
		local PixelX, PixelY, Depth = Spatial.WorldToViewportPixels(Camera, WorldPoint, PixelSize)

		if not PixelX then
			continue
		end

		table.insert(Points, Vector2.new(PixelX, PixelY))
		DepthSum += Depth :: number
		SampleCount += 1
	end

	if SampleCount == 0 then
		return nil
	end

	local Depth = DepthSum / SampleCount
	local Origin = PartCFrame.Position
	local CandidateAngles = {}

	if PreviousRotation ~= nil then
		table.insert(CandidateAngles, math.rad(PreviousRotation))
	end

	for _, Axis in {PartCFrame.RightVector, PartCFrame.UpVector, PartCFrame.LookVector} do
		local Angle = ScreenAngleOfWorldAxis(Camera, Origin, Axis, PixelSize)
		if Angle then
			table.insert(CandidateAngles, Angle)
		end
	end

	if #CandidateAngles == 0 then
		table.insert(CandidateAngles, 0)
	end

	local BestArea = math.huge
	local BestWidth = 1
	local BestHeight = 1
	local BestCenterX = Points[1].X
	local BestCenterY = Points[1].Y
	local BestAngle = CandidateAngles[1]

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

	-- Prefer the previous angle when it stays near-optimal (avoids 90° snaps).
	if PreviousRotation ~= nil then
		local PreviousRadians = math.rad(PreviousRotation)
		local Width, Height, CenterX, CenterY = FitOrientedBounds(Points, PreviousRadians)
		local PreviousArea = Width * Height

		if PreviousArea <= BestArea * AREA_KEEP_RATIO then
			BestArea = PreviousArea
			BestWidth = Width
			BestHeight = Height
			BestCenterX = CenterX
			BestCenterY = CenterY
			BestAngle = PreviousRadians
		else
			local BestDelta = math.huge
			local StableAngle = BestAngle
			local StableWidth = BestWidth
			local StableHeight = BestHeight
			local StableCenterX = BestCenterX
			local StableCenterY = BestCenterY

			for _, Angle in CandidateAngles do
				local WidthCandidate, HeightCandidate, CenterXCandidate, CenterYCandidate = FitOrientedBounds(Points, Angle)
				local Area = WidthCandidate * HeightCandidate

				if Area > BestArea * AREA_KEEP_RATIO then
					continue
				end

				local Degrees = math.deg(Angle)
				local Delta = math.abs(ShortestAngleDeltaDegrees(PreviousRotation, Degrees))

				if Delta < BestDelta then
					BestDelta = Delta
					StableAngle = Angle
					StableWidth = WidthCandidate
					StableHeight = HeightCandidate
					StableCenterX = CenterXCandidate
					StableCenterY = CenterYCandidate
				end
			end

			BestAngle = StableAngle
			BestWidth = StableWidth
			BestHeight = StableHeight
			BestCenterX = StableCenterX
			BestCenterY = StableCenterY
		end
	end

	local RotationDegrees = math.deg(BestAngle)

	if PreviousRotation ~= nil then
		-- Unwrap so Rotation is continuous for GuiObject + LockedToParent.
		RotationDegrees = PreviousRotation + ShortestAngleDeltaDegrees(PreviousRotation, RotationDegrees)
	end

	return {
		CenterX = BestCenterX,
		CenterY = BestCenterY,
		Width = math.max(BestWidth, 1),
		Height = math.max(BestHeight, 1),
		Rotation = RotationDegrees,
		Depth = Depth,
	}
end

return Spatial
