setExtensionUnloadMode("modmenumain", "manual")
load("modmenumain")

-- Keybind category for the toggle action. core_input_categories is a plain table, so a missing one is skipped.
local categories = extensions.core_input_categories
if categories then
	categories.sslModMenu = {order = 1069, icon = "settings", title = "BeamMP Mod-Menu (SpiderSpeedLauncher)", desc = "Keybinds for the BeamMP/CaRP Mod-Menu"}
end
