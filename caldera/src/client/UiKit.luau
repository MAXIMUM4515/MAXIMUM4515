--[[
	UiKit
	Small helpers and the shared palette for the code-built interfaces (HUD, guide pop-up).
]]

local UiKit = {}

UiKit.Panel = Color3.fromRGB(22, 18, 18)
UiKit.Text = Color3.fromRGB(245, 238, 230)
UiKit.Muted = Color3.fromRGB(190, 178, 168)
UiKit.Accent = Color3.fromRGB(255, 176, 74)

export type Props = { [string]: any }

-- Creates an instance, sets its properties, parents the given children to it, and parents it
-- last (to props.Parent) so nothing is rendered half-built.
function UiKit.create(className: string, props: Props, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	instance.Parent = props.Parent
	return instance
end

function UiKit.corner(radius: number): UICorner
	return UiKit.create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

function UiKit.padding(pixels: number): UIPadding
	local offset = UDim.new(0, pixels)
	return UiKit.create("UIPadding", {
		PaddingTop = offset,
		PaddingBottom = offset,
		PaddingLeft = offset,
		PaddingRight = offset,
	})
end

return UiKit
