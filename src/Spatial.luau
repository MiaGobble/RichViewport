--[=[
	Screen-space projection and part bounds for viewport overlays.

	@class Spatial
]=]

local Spatial = {}

-- Types
export type LayerBounds = {
	CenterX : number,
	CenterY : number,
	Width : number,
	Height : number,
	Rotation : number, -- degrees
	Depth : number,
}

-- Constants
const CORNER_OFFSETS = {
	Vector3.new(-1, -1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, 1, 1),
}

const AREA_KEEP_RATIO = 1.12

local function FitOrientedBounds(points : {Vector2}, angleRadians : number) : (number, number, number, number)
	local Cos = math.cos(angleRadians)
	local Sin = math.sin(angleRadians)

	local MinX = math.huge
	local MinY = math.huge
	local MaxX = -math.huge
	local MaxY = -math.huge

	for _, point in points do
		local LocalX = point.X * Cos + point.Y * Sin
		local LocalY = -point.X * Sin + point.Y * Cos

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

local function ScreenAngleOfWorldAxis(camera : Camera, origin : Vector3, axis : Vector3, pixelSize : Vector2) : number?
	local OriginX, OriginY = Spatial.WorldToViewportPixels(camera, origin, pixelSize)
	local TipX, TipY = Spatial.WorldToViewportPixels(camera, origin + axis, pixelSize)

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

local function ShortestAngleDeltaDegrees(from : number, to : number) : number
	local Delta = (to - from + 180) % 360 - 180
	return Delta
end

--[=[
	Collects every `BasePart` under `Root`, including `Root` itself when applicable.

	@within Spatial
]=]
function Spatial.CollectParts(root : Instance) : {BasePart}
	local Parts = {}

	if root:IsA("BasePart") then
		table.insert(Parts, root)
	end

	for _, descendant in root:QueryDescendants("BasePart") do
		table.insert(Parts, descendant)
	end

	return Parts
end

--[=[
	World point → viewport pixels using vertical FOV and `PixelSize` aspect.
	Returns `nil` when the point is behind the camera.

	@within Spatial
]=]
function Spatial.WorldToViewportPixels(camera : Camera, worldPoint : Vector3, pixelSize : Vector2) : (number?, number?, number?)
	local Relative = camera.CFrame:PointToObjectSpace(worldPoint)
	local Depth = -Relative.Z

	if Depth <= 0 then
		return nil
	end

	local AspectRatio = pixelSize.X / pixelSize.Y
	local HalfHeight = math.tan(math.rad(camera.FieldOfView) * 0.5) * Depth
	local HalfWidth = HalfHeight * AspectRatio

	local ScreenX = (Relative.X / HalfWidth * 0.5 + 0.5) * pixelSize.X
	local ScreenY = (-Relative.Y / HalfHeight * 0.5 + 0.5) * pixelSize.Y

	return ScreenX, ScreenY, Depth
end

--[=[
	Pixels per stud at a given camera depth.

	@within Spatial
]=]
function Spatial.GetPixelsPerStud(camera : Camera, depth : number, pixelSize : Vector2) : number
	if depth <= 0 or pixelSize.Y <= 0 then
		return 1
	end

	local HalfHeight = math.tan(math.rad(camera.FieldOfView) * 0.5) * depth
	return pixelSize.Y / (2 * HalfHeight)
end

--[=[
	Bounding focus CFrame for a model or part (used when framing a camera).

	@within Spatial
]=]
function Spatial.GetFocusCFrame(root : Instance) : CFrame
	if root:IsA("Model") then
		return select(1, root:GetBoundingBox())
	end

	if root:IsA("BasePart") then
		return root.CFrame
	end

	return CFrame.new()
end

--[=[
	Oriented screen bounds for a part (shared by emit + debug layers).

	`PreviousRotation` keeps the angle stable across refreshes so layers and
	`LockedToParent` particles do not snap when face-axis candidates trade places.

	@within Spatial
]=]
function Spatial.GetPartLayerBounds(camera : Camera, part : BasePart, pixelSize : Vector2, previousRotation : number?) : LayerBounds?
	if pixelSize.X <= 0 or pixelSize.Y <= 0 then
		return nil
	end

	local HalfSize = part.Size * 0.5
	local PartCFrame = part.CFrame
	local Points = {}
	local DepthSum = 0
	local SampleCount = 0

	for _, offset in CORNER_OFFSETS do
		local WorldPoint = PartCFrame:PointToWorldSpace(offset * HalfSize)
		local PixelX, PixelY, Depth = Spatial.WorldToViewportPixels(camera, WorldPoint, pixelSize)

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

	if previousRotation ~= nil then
		table.insert(CandidateAngles, math.rad(previousRotation))
	end

	for _, axis in {PartCFrame.RightVector, PartCFrame.UpVector, PartCFrame.LookVector} do
		local Angle = ScreenAngleOfWorldAxis(camera, Origin, axis, pixelSize)
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

	for _, angle in CandidateAngles do
		local Width, Height, CenterX, CenterY = FitOrientedBounds(Points, angle)
		local Area = Width * Height

		if Area < BestArea then
			BestArea = Area
			BestWidth = Width
			BestHeight = Height
			BestCenterX = CenterX
			BestCenterY = CenterY
			BestAngle = angle
		end
	end

	-- Prefer the previous angle when it stays near-optimal (avoids 90° snaps).
	if previousRotation ~= nil then
		local PreviousRadians = math.rad(previousRotation)
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

			for _, angle in CandidateAngles do
				local WidthCandidate, HeightCandidate, CenterXCandidate, CenterYCandidate = FitOrientedBounds(Points, angle)
				local Area = WidthCandidate * HeightCandidate

				if Area > BestArea * AREA_KEEP_RATIO then
					continue
				end

				local Degrees = math.deg(angle)
				local Delta = math.abs(ShortestAngleDeltaDegrees(previousRotation, Degrees))

				if Delta < BestDelta then
					BestDelta = Delta
					StableAngle = angle
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

	if previousRotation ~= nil then
		-- Unwrap so Rotation is continuous for GuiObject + LockedToParent.
		RotationDegrees = previousRotation + ShortestAngleDeltaDegrees(previousRotation, RotationDegrees)
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