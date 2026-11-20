local Story = {}

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Imports
local Modules = script.Parent
local Packages = Modules.Packages
local Seam = require(Packages.Seam)
local SeamStoryUtils = require(Packages.SeamStoryUtils)

Story.controls = {}

function Story.render(props)
	local Scope = Seam.Scope(Seam)
	local Controls = SeamStoryUtils.GetValuesFromControls(Scope, props)

	return SeamStoryUtils.WrappedScopeCleanup(Scope)
end

return Story