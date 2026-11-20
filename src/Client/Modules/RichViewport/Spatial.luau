--[=[
	Screen-space projection and part bounds for viewport overlays.

	@class Spatial
]=]

local Spatial = {}

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
	Rotation : number,
	Depth : number,
}

export type PartScreenBounds = {
	Emit : ScreenBounds,
	Guide : OrientedScreenBounds,
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

--[=[
	Projects a part to an unrotated emission AABB plus an oriented debug guide OBB.

	Emitters must use the AABB (`Emit`). Guide frames may use `Guide.Rotation`.

	@within Spatial
]=]
function Spatial.GetPartScreenBounds(Camera : Camera, Part : BasePart, PixelSize : Vector2) : PartScreenBounds?
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
		local PixelX, PixelY, Depth = Spatial.WorldToViewportPixels(Camera, WorldPoint, PixelSize)

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

return Spatial
