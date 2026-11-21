local Story = {}

-- Constants
local VIEWPORT_BACKGROUND_COLOR = Color3.fromRGB(20, 20, 24)

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Imports
local Modules = script.Parent
local Packages = Modules.Packages
local Seam = require(Packages.Seam)
local SeamStoryUtils = require(Packages.SeamStoryUtils)
local UILabs = require(Packages.UILabs)
local RichViewport = require(Modules.RichViewport)
local Spatial = RichViewport.Spatial

Story.controls = {
	FieldOfView = UILabs.Slider(70, 1, 120),
	CameraDistance = UILabs.Slider(8, 0.5, 50),
	ViewportScale = UILabs.Slider(1, 0.1, 1),
	RotationX = UILabs.Slider(0, -180, 180),
	RotationY = UILabs.Slider(0, -180, 180),
	RotationZ = UILabs.Slider(0, -180, 180),
	ShowBounds = false,
	ShowParticles = true,
	BasePartLayering = false,
}

function Story.render(props)
	local Scope = Seam.Scope(Seam)
	local Controls = SeamStoryUtils.GetValuesFromControls(Scope, props)

	local TestAssets = ReplicatedStorage:WaitForChild("TestAsset")
	local SourceAsset = TestAssets:GetChildren()[1]
	assert(SourceAsset, "ReplicatedStorage.TestAsset has no children")

	local Camera = Scope:New("Camera", {
		Name = "ViewportCamera",
		FieldOfView = Controls.FieldOfView.Value,
	})

	local Host = Scope:New("Frame", {
		Name = "ViewportHost",
		Parent = props.target,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = VIEWPORT_BACKGROUND_COLOR,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,

		Size = Scope:Computed(function(use)
			local Scale = use(Controls.ViewportScale)
			return UDim2.fromScale(Scale, Scale)
		end),
	})

	local View = RichViewport.new(SourceAsset, Camera, Host)
	Scope:AddObject(View)

	local BasePartLayeringEnabled = false

	local function ApplyControls()
		local Object = View.Object

		Object:PivotTo(CFrame.fromEulerAnglesXYZ(
			math.rad(Controls.RotationX.Value),
			math.rad(Controls.RotationY.Value),
			math.rad(Controls.RotationZ.Value)
		))

		local Focus = Spatial.GetFocusCFrame(Object).Position
		Camera.FieldOfView = Controls.FieldOfView.Value
		Camera.CFrame = CFrame.lookAt(Focus + Vector3.new(0, 0, Controls.CameraDistance.Value), Focus)

		if Controls.ShowBounds.Value then
			View:ShowDebug()
		else
			View:HideDebug()
		end

		if Controls.ShowParticles.Value then
			View:ShowParticles()
		else
			View:HideParticles()
		end

		if Controls.BasePartLayering.Value and not BasePartLayeringEnabled then
			View:EnableBasePartLayering()
			BasePartLayeringEnabled = true
		elseif not Controls.BasePartLayering.Value and BasePartLayeringEnabled then
			View:DisableBasePartLayering()
			BasePartLayeringEnabled = false
		end

		View:Refresh()
	end

	for _, Control in Controls do
		Scope:OnChanged(Control, ApplyControls)
	end

	ApplyControls()
	task.defer(ApplyControls)

	return SeamStoryUtils.WrappedScopeCleanup(Scope)
end

return Story
