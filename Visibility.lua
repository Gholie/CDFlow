-- Smart Visibility — 基于游戏状态控制冷却管理器查看器的透明度
local _, ns = ...

local Visibility = {}
ns.Visibility = Visibility

local VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

-- 本地状态缓存，避免战斗中频繁查询 API
local inCombat = InCombatLockdown()
local clientSceneActive = false
local viewerVisibleState = {}

-- 读取查看器原始 alpha（由编辑模式 Opacity 设置决定）
local function GetViewerAlpha(viewer)
    if viewer.settingMap and viewer.settingMap[Enum.EditModeCooldownViewerSetting.Opacity] then
        return (viewer.settingMap[Enum.EditModeCooldownViewerSetting.Opacity].value + 50) / 100
    end
    return 1
end

local function UpdateViewer(viewer)
    if not viewer then return end
    local shouldShow = true

    local cfg = ns.db and ns.db.visibility
    -- 未配置或等效于"始终显示且无附加过滤"时直接还原
    if not cfg or (cfg.mode == "ALWAYS" and not cfg.hideWhenMounted and not cfg.hideInVehicles) then
        viewer:SetAlpha(GetViewerAlpha(viewer))
    else
        -- 附加过滤（高优先级，触发即隐藏）
        if cfg.hideInVehicles then
            if clientSceneActive or C_ActionBar.HasOverrideActionBar() or UnitInVehicle("player") then
                shouldShow = false
            end
        end

        if shouldShow and cfg.hideWhenMounted then
            local sfid = GetShapeshiftFormID()
            -- 3=骑乘形态(德鲁伊), 27=雨燕形态, 29=树形态(此处用于覆盖飞行形)
            if IsMounted() or sfid == 3 or sfid == 27 or sfid == 29 then
                shouldShow = false
            end
        end

        -- 主模式判断
        if shouldShow then
            local mode = cfg.mode
            if mode == "ALWAYS" then
                shouldShow = true
            elseif mode == "COMBAT_ONLY" then
                shouldShow = inCombat
            elseif mode == "TARGET_ONLY" then
                shouldShow = UnitExists("target")
            elseif mode == "COMBAT_OR_TARGET" then
                shouldShow = inCombat or UnitExists("target")
            else
                shouldShow = true
            end
        end

        viewer:SetAlpha(shouldShow and GetViewerAlpha(viewer) or 0)
    end

    local name = viewer.GetName and viewer:GetName()
    if name then
        local changed = (viewerVisibleState[name] ~= shouldShow)
        viewerVisibleState[name] = shouldShow
        if changed and name == "BuffIconCooldownViewer" then
            if ns.Layout and ns.Layout.RequestBuffRefreshFromMB then
                ns.Layout.RequestBuffRefreshFromMB()
            elseif ns.Layout and ns.Layout.RefreshViewer then
                C_Timer.After(0, function()
                    if _G.BuffIconCooldownViewer then
                        ns.Layout:RefreshViewer("BuffIconCooldownViewer")
                    end
                end)
            end
        end
    end
end

function Visibility:UpdateAll()
    for _, name in ipairs(VIEWERS) do
        UpdateViewer(_G[name])
    end
end

-- 停用时还原所有查看器至原始 alpha
function Visibility:RestoreAll()
    for _, name in ipairs(VIEWERS) do
        local v = _G[name]
        if v then
            v:SetAlpha(GetViewerAlpha(v))
            viewerVisibleState[name] = true
        end
    end
end

function Visibility:IsViewerVisible(viewerOrName)
    local name = type(viewerOrName) == "string"
        and viewerOrName
        or (viewerOrName and viewerOrName.GetName and viewerOrName:GetName())
    if not name then return true end
    local state = viewerVisibleState[name]
    if state == nil then
        return true
    end
    return state
end

local EventFrame = CreateFrame("Frame")
EventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
    elseif event == "CLIENT_SCENE_OPENED" then
        clientSceneActive = (select(1, ...) == 1)
    elseif event == "CLIENT_SCENE_CLOSED" then
        clientSceneActive = false
    end
    Visibility:UpdateAll()
end)

local isInit = false

function Visibility:Initialize()
    local cfg = ns.db and ns.db.visibility
    local needsEvents = cfg and (
        cfg.mode ~= "ALWAYS"
        or cfg.hideWhenMounted
        or cfg.hideInVehicles
    )

    if needsEvents then
        if not isInit then
            EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
            EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
            EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
            EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
            EventFrame:RegisterEvent("MOUNT_JOURNAL_USABILITY_CHANGED")
            EventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
            EventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
            EventFrame:RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR")
            EventFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
            EventFrame:RegisterEvent("CLIENT_SCENE_OPENED")
            EventFrame:RegisterEvent("CLIENT_SCENE_CLOSED")
            isInit = true
        end
        self:UpdateAll()
    else
        EventFrame:UnregisterAllEvents()
        isInit = false
        self:RestoreAll()
    end
end
