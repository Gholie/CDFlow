-- 小地图按钮：LibDataBroker-1.1 + LibDBIcon-1.0
local _, ns = ...

local ICON_PATH = "Interface\\AddOns\\CDFlow\\Media\\logo"

function ns:InitMinimapButton()
    local ldb  = LibStub("LibDataBroker-1.1", true)
    local icon = LibStub("LibDBIcon-1.0", true)
    if not ldb or not icon then return end

    local L = ns.L

    local broker = ldb:NewDataObject("CDFlow", {
        type = "launcher",
        text = "CDFlow",
        icon = ICON_PATH,
        OnClick = function(_, btn)
            if btn == "LeftButton" then
                ns.ToggleSettings()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("|cff00ccffCDFlow|r")
            tooltip:AddLine("|cffaaaaaa" .. L.slashHelp .. "|r")
        end,
    })

    -- ns.db.minimap 由 AceDB 持久化，LibDBIcon 用它存 hide/minimapPos 等字段
    icon:Register("CDFlow", broker, ns.db.minimap)
    ns._minimapIcon = icon
end
