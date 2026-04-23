-- 监控条创建、样式应用、更新逻辑、事件处理
local _, ns = ...

local MB = ns.MonitorBars
local LSM = LibStub("LibSharedMedia-3.0", true)
local DEFAULT_FONT = ns._mbConst.DEFAULT_FONT
local BAR_TEXTURE  = ns._mbConst.BAR_TEXTURE
local SEGMENT_GAP  = ns._mbConst.SEGMENT_GAP
local UPDATE_INTERVAL = ns._mbConst.UPDATE_INTERVAL
local RING_TEXTURE_FMT = "Interface\\AddOns\\CDFlow\\Textures\\Ring\\Ring_%dpx.tga"

local ResolveFontPath    = MB.ResolveFontPath
local ConfigureStatusBar = MB.ConfigureStatusBar
local HasAuraInstanceID  = MB.HasAuraInstanceID
local FindCDMFrame       = MB.FindCDMFrame
local spellToCooldownID  = MB._spellToCooldownID
local cooldownIDToFrame  = MB._cooldownIDToFrame
local PLAYER_CLASS_TAG   = select(2, UnitClass("player"))

local activeFrames = {}
local elapsed = 0
local inCombat = false
local frameTick = 0

-- 前向声明，定义在生命周期区块，此处供 UpdateDurationBar 使用
local ShouldBarBeVisible

-- 分段条波形填充速度：每秒填充的格数（每格约 83ms）
local STACK_FILL_SPEED = 12

function MB.rounded(num, idp)
    if not num then return num end
    local mult = 10^(idp or 0)
    return math.floor(num * mult + 0.5) / mult
end

function MB.getPixelPerfectScale(customUIScale)
    local screenHeight = select(2, GetPhysicalScreenSize())
    local scale = customUIScale or UIParent:GetEffectiveScale()
    if scale == 0 or screenHeight == 0 then return 1 end
    return 768 / screenHeight / scale
end

function MB.getNearestPixel(value, customUIScale)
    if value == 0 then return 0 end
    local ppScale = MB.getPixelPerfectScale(customUIScale)
    return MB.rounded(value / ppScale) * ppScale
end

MB.MASK_AND_BORDER_STYLES = {
    ["1px"] = {
        type = "fixed",
        thickness = 1,
    },
    ["Thin"] = {
        type = "fixed",
        thickness = 2,
    },
    ["Medium"] = {
        type = "fixed",
        thickness = 3,
    },
    ["Thick"] = {
        type = "fixed",
        thickness = 5,
    },
    ["None"] = {},
}

-- 御龙术（Skyriding）检测
-- 主判断：御龙术动作条占据 BonusBar slot 11 / offset 5
-- 次判断：canGlide == true 说明玩家骑乘了御龙坐骑（不再要求 powerBar 非零，
--         因为地面停止时 UnitPowerBarID 可能为 0）
local function IsSkyriding()
    if GetBonusBarIndex() == 11 and GetBonusBarOffset() == 5 then
        return true
    end
    local _, canGlide = C_PlayerInfo.GetGlidingInfo()
    return canGlide == true
end

------------------------------------------------------
-- CDM 帧 Hook 管理
------------------------------------------------------

local hookedFrames = {}
local frameToBarIDs = {}
local auraKeyToBarIDs = {}
local barIDToAuraKey = {}
local UpdateStackBar

local function BuildAuraKey(unit, auraInstanceID)
    if not HasAuraInstanceID(auraInstanceID) then return nil end
    local unitToken = (type(unit) == "string" and unit ~= "") and unit or "player"
    return unitToken .. "#" .. tostring(auraInstanceID)
end

local function UnlinkBarFromAura(barID)
    local oldKey = barIDToAuraKey[barID]
    if not oldKey then return end
    local bars = auraKeyToBarIDs[oldKey]
    if bars then
        bars[barID] = nil
        if not next(bars) then
            auraKeyToBarIDs[oldKey] = nil
        end
    end
    barIDToAuraKey[barID] = nil
end

local function LinkBarToAura(barFrame, unit, auraInstanceID)
    if not barFrame or not barFrame._barID then return end
    local key = BuildAuraKey(unit, auraInstanceID)
    if not key then return end
    local barID = barFrame._barID
    local oldKey = barIDToAuraKey[barID]
    if oldKey ~= key then
        UnlinkBarFromAura(barID)
    end
    local bars = auraKeyToBarIDs[key]
    if not bars then
        bars = {}
        auraKeyToBarIDs[key] = bars
    end
    bars[barID] = true
    barIDToAuraKey[barID] = key
    barFrame._trackedAuraInstanceID = auraInstanceID
    barFrame._trackedUnit = unit
end

local function OnCDMFrameChanged(frame, ...)
    local auraInstanceID, auraUnit
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if not auraInstanceID and HasAuraInstanceID(v) then
            auraInstanceID = v
        end
        if not auraUnit and type(v) == "string" then
            auraUnit = v
        end
    end
    local ids = frameToBarIDs[frame]
    if not ids then return end
    for _, id in ipairs(ids) do
        local f = activeFrames[id]
        if f and f._cfg then
            if f._cfg.barType == "stack" then
                if auraInstanceID then
                    local trackedUnit = auraUnit or frame.auraDataUnit or f._cfg.unit or f._trackedUnit or "player"
                    LinkBarToAura(f, trackedUnit, auraInstanceID)
                end
                UpdateStackBar(f)
            elseif f._cfg.barType == "duration" then
                f._needsDurationRefresh = true
            end
        end
    end
end

local function HookCDMFrame(frame, barID)
    if not frame then return end
    if not hookedFrames[frame] then
        hookedFrames[frame] = { barIDs = {} }
        frameToBarIDs[frame] = {}
        if frame.RefreshData then
            hooksecurefunc(frame, "RefreshData", OnCDMFrameChanged)
        end
        if frame.RefreshApplications then
            hooksecurefunc(frame, "RefreshApplications", OnCDMFrameChanged)
        end
        if frame.SetAuraInstanceInfo then
            hooksecurefunc(frame, "SetAuraInstanceInfo", OnCDMFrameChanged)
        end
    end
    if not hookedFrames[frame].barIDs[barID] then
        hookedFrames[frame].barIDs[barID] = true
        table.insert(frameToBarIDs[frame], barID)
    end
end

local function ClearAllHookRegistrations()
    for frame in pairs(hookedFrames) do
        hookedFrames[frame].barIDs = {}
        frameToBarIDs[frame] = {}
    end
    wipe(auraKeyToBarIDs)
    wipe(barIDToAuraKey)
end

local function AutoHookStackBars()
    for _, f in pairs(activeFrames) do
        local cfg = f._cfg
        if cfg and cfg.barType == "stack" and cfg.spellID > 0 then
            local cdID = spellToCooldownID[cfg.spellID]
            if cdID then
                local cdmFrame = FindCDMFrame(cdID)
                if cdmFrame then
                    HookCDMFrame(cdmFrame, f._barID)
                    f._cdmFrame = cdmFrame
                end
            end
        end
    end
end

function MB:PostScanHook()
    ClearAllHookRegistrations()
    AutoHookStackBars()
end

------------------------------------------------------
-- 秘密值检测（Arc Detectors）
------------------------------------------------------

local function GetArcDetector(barFrame, threshold)
    barFrame._arcDetectors = barFrame._arcDetectors or {}
    local det = barFrame._arcDetectors[threshold]
    if det then return det end

    det = CreateFrame("StatusBar", nil, barFrame)
    det:SetSize(1, 1)
    det:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
    det:SetAlpha(0)
    det:SetStatusBarTexture(BAR_TEXTURE)
    det:SetMinMaxValues(threshold - 1, threshold)
    det:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透
    ConfigureStatusBar(det)
    barFrame._arcDetectors[threshold] = det
    return det
end

local function FeedArcDetectors(barFrame, secretValue, maxVal)
    for i = 1, maxVal do
        GetArcDetector(barFrame, i):SetValue(secretValue)
    end
end

local function GetExactCount(barFrame, maxVal)
    if not barFrame._arcDetectors then return 0 end
    local count = 0
    for i = 1, maxVal do
        local det = barFrame._arcDetectors[i]
        if det and det:GetStatusBarTexture():IsShown() then
            count = i
        else
            break
        end
    end
    return count
end

local function GetOrCreateShadowCooldown(barFrame)
    if barFrame._shadowCooldown then return barFrame._shadowCooldown end
    local cd = CreateFrame("Cooldown", nil, barFrame, "CooldownFrameTemplate")
    cd:SetAllPoints(barFrame)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetAlpha(0)
    cd:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透
    barFrame._shadowCooldown = cd
    return cd
end

------------------------------------------------------
-- 段条 / 边框
------------------------------------------------------

function MB.ApplyMaskAndBorderSettings(barFrame, cfg)
    local styleName = cfg.maskAndBorderStyle or "1px"
    local style = MB.MASK_AND_BORDER_STYLES[styleName] or MB.MASK_AND_BORDER_STYLES["1px"]
    
    local width, height = barFrame:GetSize()
    
    if barFrame._mask then
        barFrame._mask:SetTexture([[Interface\AddOns\CDFlow\Textures\Specials\white.png]])
        barFrame._mask:SetAllPoints(barFrame)
    end

    if style.type == "fixed" then
        if not barFrame._fixedBorders then
            barFrame._fixedBorders = {}
            barFrame._fixedBorders.top    = barFrame._borderFrame:CreateTexture(nil, "OVERLAY")
            barFrame._fixedBorders.bottom = barFrame._borderFrame:CreateTexture(nil, "OVERLAY")
            barFrame._fixedBorders.left   = barFrame._borderFrame:CreateTexture(nil, "OVERLAY")
            barFrame._fixedBorders.right  = barFrame._borderFrame:CreateTexture(nil, "OVERLAY")
        end

        barFrame._border:Hide()
        
        local thickness = (style.thickness or 1) * (cfg.scale or 1)
        local pThickness = MB.getNearestPixel(thickness)
        local borderColor = cfg.borderColor or { 0, 0, 0, 1 }

        for edge, t in pairs(barFrame._fixedBorders) do
            t:ClearAllPoints()
            if edge == "top" then
                t:SetPoint("TOPLEFT", barFrame._borderFrame, "TOPLEFT")
                t:SetPoint("TOPRIGHT", barFrame._borderFrame, "TOPRIGHT")
                t:SetHeight(pThickness)
            elseif edge == "bottom" then
                t:SetPoint("BOTTOMLEFT", barFrame._borderFrame, "BOTTOMLEFT")
                t:SetPoint("BOTTOMRIGHT", barFrame._borderFrame, "BOTTOMRIGHT")
                t:SetHeight(pThickness)
            elseif edge == "left" then
                t:SetPoint("TOPLEFT", barFrame._borderFrame, "TOPLEFT")
                t:SetPoint("BOTTOMLEFT", barFrame._borderFrame, "BOTTOMLEFT")
                t:SetWidth(pThickness)
            elseif edge == "right" then
                t:SetPoint("TOPRIGHT", barFrame._borderFrame, "TOPRIGHT")
                t:SetPoint("BOTTOMRIGHT", barFrame._borderFrame, "BOTTOMRIGHT")
                t:SetWidth(pThickness)
            end
            t:SetColorTexture(borderColor[1] or 0, borderColor[2] or 0, borderColor[3] or 0, borderColor[4] or 1)
            t:Show()
        end
    elseif style.type == "texture" then
        barFrame._border:Show()
        barFrame._border:SetTexture(style.border)
        barFrame._border:SetAllPoints(barFrame._borderFrame)
        local borderColor = cfg.borderColor or { 0, 0, 0, 1 }
        barFrame._border:SetVertexColor(borderColor[1] or 0, borderColor[2] or 0, borderColor[3] or 0, borderColor[4] or 1)

        if barFrame._fixedBorders then
            for _, t in pairs(barFrame._fixedBorders) do t:Hide() end
        end
    else
        barFrame._border:Hide()
        if barFrame._fixedBorders then
            for _, t in pairs(barFrame._fixedBorders) do t:Hide() end
        end
    end
end

-- 统一监控条层级基线，避免“BACKGROUND”仍因固定高 FrameLevel 覆盖其他 UI
local function GetBaseFrameLevelByStrata(strata)
    if strata == "BACKGROUND" then
        return 0
    end
    return 1
end

local function CreateSegments(barFrame, count, cfg)
    barFrame._segments = barFrame._segments or {}
    barFrame._segBGs = barFrame._segBGs or {}
    barFrame._segBorders = barFrame._segBorders or {}
    barFrame._thresholdOverlays = barFrame._thresholdOverlays or {}  -- 阈值覆盖层

    for _, seg in ipairs(barFrame._segments) do seg:Hide() end
    for _, bg in ipairs(barFrame._segBGs) do bg:Hide() end
    for _, b in ipairs(barFrame._segBorders) do b:Hide() end
    for _, overlay in ipairs(barFrame._thresholdOverlays) do overlay:Hide() end
    wipe(barFrame._segments)
    wipe(barFrame._segBGs)
    wipe(barFrame._segBorders)
    wipe(barFrame._thresholdOverlays)

    if count < 1 then return end

    local container = barFrame._segContainer
    local totalW, totalH = container:GetSize()
    
    -- 物理像素对齐计算
    local ppScale = MB.getPixelPerfectScale()
    local function ToPixel(v) return MB.rounded(v / ppScale) end
    local function ToLogical(px) return px * ppScale end
    
    local pxTotalW = ToPixel(totalW)
    local pxTotalH = ToPixel(totalH)
    
    local gap = cfg.segmentGap ~= nil and cfg.segmentGap or SEGMENT_GAP
    local pxGap = ToPixel(gap)
    
    local borderSize = cfg.borderSize or 1
    local pxBorder = ToPixel(borderSize)
    if borderSize > 0 and pxBorder == 0 then pxBorder = 1 end
    
    local perSegBorder = (cfg.borderStyle == "segment")
    
    -- 计算分段宽度（处理余数分配）
    local pxAvailableW = math.max(0, pxTotalW - (count - 1) * pxGap)
    local pxSegW_Base = math.floor(pxAvailableW / count)
    local pxRemainder = pxAvailableW % count
    
    local baseColor = cfg.barColor or { 0.2, 0.8, 0.2, 1 }
    local bgColor = cfg.bgColor or { 0.1, 0.1, 0.1, 0.6 }
    local borderColor = cfg.borderColor or { 0, 0, 0, 1 }
    local texPath = BAR_TEXTURE
    if LSM and LSM.Fetch and cfg.barTexture then
        texPath = LSM:Fetch("statusbar", cfg.barTexture) or BAR_TEXTURE
    end

    -- 阈值颜色配置（用于 stack 类型）
    local threshold1 = cfg.colorThreshold or 0
    local threshold2 = cfg.colorThreshold2 or 0
    local thresholdColor1 = cfg.thresholdColor or { 1, 0.5, 0, 1 }
    local thresholdColor2 = cfg.thresholdColor2 or { 1, 0, 0, 1 }

    -- 如果是圆环模式，使用 CooldownFrame 实现
    if cfg.barShape == "Ring" and cfg.barType == "duration" then
        local thickness = cfg.ringThickness or 20
        local ringTex = string.format(RING_TEXTURE_FMT, thickness)

        local bg = container:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(ringTex)
        bg:SetVertexColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
        bg:Show()
        barFrame._segBGs[1] = bg

        -- 使用 CooldownFrame 作为进度显示
        -- 技巧：将 SwipeTexture 设置为圆环纹理，并染色为 baseColor
        -- CooldownFrame 默认显示”冷却中”的黑色阴影，但我们可以通过 SetSwipeColor 改变它
        -- 并且利用冷却倒计时（从满到空）来模拟 buff 剩余时间（从满到空）
        local cd = CreateFrame("Cooldown", nil, container, "CooldownFrameTemplate")
        cd:SetAllPoints()
        cd:SetDrawEdge(false)
        cd:SetDrawBling(false)
        cd:SetSwipeTexture(ringTex)
        cd:SetSwipeColor(baseColor[1], baseColor[2], baseColor[3], baseColor[4])
        cd:SetHideCountdownNumbers(true)
        cd:SetUseCircularEdge(false) -- 关闭圆形边缘裁剪，确保纹理完整显示
        cd:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透
        cd:Show()
        
        -- 标记这是一个 Ring Segment，方便后续识别
        cd._isRing = true
        barFrame._segments[1] = cd
        
        -- 圆环模式下不需要 Border (由纹理决定) 或 Mask (纹理自带透明)
        if barFrame._mbBorder then barFrame._mbBorder:Hide() end
        if barFrame._borderFrame then barFrame._borderFrame:Hide() end
        
        return
    end

    local currentPxX = 0

    for i = 1, count do
        -- 将余数像素分配给前几个分段
        local thisPxSegW = pxSegW_Base
        if i <= pxRemainder then
            thisPxSegW = thisPxSegW + 1
        end

        local logX = ToLogical(currentPxX)
        local logSegW = ToLogical(thisPxSegW)
        local logTotalH = ToLogical(pxTotalH)

        local bg = container:CreateTexture(nil, "BACKGROUND")
        bg:ClearAllPoints()
        bg:SetPoint("TOPLEFT", container, "TOPLEFT", logX, 0)
        bg:SetSize(logSegW, logTotalH)
        bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
        if barFrame._mask then bg:AddMaskTexture(barFrame._mask) end
        bg:Show()
        barFrame._segBGs[i] = bg

        local bar = CreateFrame("StatusBar", nil, container)
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", logX, 0)
        bar:SetSize(logSegW, logTotalH)
        bar:SetStatusBarTexture(texPath)

        -- 基础颜色（所有分段统一使用基础颜色）
        bar:SetStatusBarColor(baseColor[1], baseColor[2], baseColor[3], baseColor[4])

        if cfg.barType == "stack" then
            bar:SetMinMaxValues(i - 1, i)
        else
            bar:SetMinMaxValues(0, 1)
        end
        bar:SetValue(0)
        bar:SetFrameLevel(container:GetFrameLevel() + 1)
        bar:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透
        ConfigureStatusBar(bar)

        if barFrame._mask then
            bar:GetStatusBarTexture():AddMaskTexture(barFrame._mask)
        end

        barFrame._segments[i] = bar

        -- 为 stack 类型的所有分段创建阈值覆盖层
        -- 关键：所有分段都需要覆盖层，这样达到阈值时整体变色
        if cfg.barType == "stack" then
            -- 第一阈值覆盖层
            if threshold1 > 0 then
                local overlay1 = CreateFrame("StatusBar", nil, container)
                overlay1:SetPoint("TOPLEFT", container, "TOPLEFT", logX, 0)
                overlay1:SetSize(logSegW, logTotalH)
                overlay1:SetStatusBarTexture(texPath)
                overlay1:SetStatusBarColor(thresholdColor1[1], thresholdColor1[2], thresholdColor1[3], thresholdColor1[4])
                -- 关键逻辑：
                -- 对于 i < threshold 的分段：SetMinMaxValues(threshold-1, threshold)
                --   只有当 value >= threshold 时才显示，且一旦显示就完全填满
                -- 对于 i >= threshold 的分段：SetMinMaxValues(i-1, i)
                --   和基础分段相同的显示逻辑
                if i < threshold1 then
                    overlay1:SetMinMaxValues(threshold1 - 1, threshold1)
                else
                    overlay1:SetMinMaxValues(i - 1, i)
                end
                overlay1:SetValue(0)
                overlay1:SetFrameLevel(container:GetFrameLevel() + 2)
                overlay1:EnableMouse(false)
                ConfigureStatusBar(overlay1)
                if barFrame._mask then
                    overlay1:GetStatusBarTexture():AddMaskTexture(barFrame._mask)
                end
                overlay1._isThresholdOverlay = 1
                overlay1._segmentIndex = i
                table.insert(barFrame._thresholdOverlays, overlay1)
            end

            -- 第二阈值覆盖层（优先级更高）
            if threshold2 > 0 then
                local overlay2 = CreateFrame("StatusBar", nil, container)
                overlay2:SetPoint("TOPLEFT", container, "TOPLEFT", logX, 0)
                overlay2:SetSize(logSegW, logTotalH)
                overlay2:SetStatusBarTexture(texPath)
                overlay2:SetStatusBarColor(thresholdColor2[1], thresholdColor2[2], thresholdColor2[3], thresholdColor2[4])
                -- 同样的逻辑
                if i < threshold2 then
                    overlay2:SetMinMaxValues(threshold2 - 1, threshold2)
                else
                    overlay2:SetMinMaxValues(i - 1, i)
                end
                overlay2:SetValue(0)
                overlay2:SetFrameLevel(container:GetFrameLevel() + 3)
                overlay2:EnableMouse(false)
                ConfigureStatusBar(overlay2)
                if barFrame._mask then
                    overlay2:GetStatusBarTexture():AddMaskTexture(barFrame._mask)
                end
                overlay2._isThresholdOverlay = 2
                overlay2._segmentIndex = i
                table.insert(barFrame._thresholdOverlays, overlay2)
            end
        end

        if perSegBorder and borderSize > 0 then
            local bFrame = CreateFrame("Frame", nil, container)
            bFrame:SetFrameLevel(bar:GetFrameLevel() + 2)
            bFrame:EnableMouse(false)
            bFrame:SetAllPoints(bar)
            
            local function CreateLine(point, rPoint, x, y, w, h)
                local t = bFrame:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
                t:SetPoint(point, bFrame, rPoint, x, y)
                t:SetSize(w, h)
                return t
            end
            
            local logBorder = ToLogical(pxBorder)
            
            local showRight = true
            if pxGap <= 0 and i < count then
                showRight = false
            end
            
            -- 左边框
            CreateLine("TOPRIGHT", "TOPLEFT", 0, logBorder, logBorder, logTotalH + 2 * logBorder)
            
            -- 右边框
            if showRight then
                CreateLine("TOPLEFT", "TOPRIGHT", 0, logBorder, logBorder, logTotalH + 2 * logBorder)
            end
            
            -- 上边框
            local hW = logSegW
            if not showRight then
                hW = math.max(0, hW - logBorder)
            end
            CreateLine("BOTTOMLEFT", "TOPLEFT", 0, 0, hW, logBorder)
            
            -- 下边框
            CreateLine("TOPLEFT", "BOTTOMLEFT", 0, 0, hW, logBorder)

            bFrame:Show()
            barFrame._segBorders[i] = bFrame
        end

        barFrame._segments[i] = bar
        
        -- 更新下一个分段的 X 坐标
        currentPxX = currentPxX + thisPxSegW + pxGap
    end

    if perSegBorder then
        if barFrame._mbBorder then barFrame._mbBorder:Hide() end
    else
        MB.ApplyMaskAndBorderSettings(barFrame, cfg)
    end
end

------------------------------------------------------
-- 文字锚点工具
------------------------------------------------------

-- 根据锚点推导 SetJustifyH 水平对齐方向
local function AnchorToJustifyH(anchor)
    if anchor == "LEFT" or anchor == "TOPLEFT" or anchor == "BOTTOMLEFT" then
        return "LEFT"
    elseif anchor == "CENTER" or anchor == "TOP" or anchor == "BOTTOM" then
        return "CENTER"
    else
        return "RIGHT"
    end
end

-- 将用户选择的锚点拆成 point / relativePoint / defaultOffsetX：
-- 顶部系列：文字底边对齐父帧顶边（文字在顶部）
-- 底部系列：文字顶边对齐父帧底边（文字在底部）
-- 其余：自对齐
local ANCHOR_POINT = {
    TOPLEFT     = "BOTTOMLEFT",  TOP     = "BOTTOM",  TOPRIGHT     = "BOTTOMRIGHT",
    LEFT        = "LEFT",        CENTER  = "CENTER",  RIGHT        = "RIGHT",
    BOTTOMLEFT  = "TOPLEFT",     BOTTOM  = "TOP",     BOTTOMRIGHT  = "TOPRIGHT",
}
local ANCHOR_REL = {
    TOPLEFT     = "TOPLEFT",     TOP     = "TOP",     TOPRIGHT     = "TOPRIGHT",
    LEFT        = "LEFT",        CENTER  = "CENTER",  RIGHT        = "RIGHT",
    BOTTOMLEFT  = "BOTTOMLEFT",  BOTTOM  = "BOTTOM",  BOTTOMRIGHT  = "BOTTOMRIGHT",
}

------------------------------------------------------
-- 条创建 / 样式
------------------------------------------------------

function MB:CreateBarFrame(barCfg)
    local id = barCfg.id
    if activeFrames[id] then return activeFrames[id] end

    local f = CreateFrame("Frame", "CDFlowMonitorBar" .. id, UIParent, "BackdropTemplate")
    local w, h = MB.getNearestPixel(barCfg.width, barCfg.scale), MB.getNearestPixel(barCfg.height, barCfg.scale)
    f:SetSize(w, h)
    local isFrameAnchored = barCfg.anchorFrame and barCfg.anchorFrame ~= "" and barCfg.anchorFrame ~= "__CUSTOM__"
    if isFrameAnchored then
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        f._frameAnchored = true
    else
        local pX = MB.getNearestPixel(barCfg.posX, barCfg.scale)
        local pY = MB.getNearestPixel(barCfg.posY, barCfg.scale)
        f:SetPoint("CENTER", UIParent, "CENTER", pX, pY)
    end
    local strata = barCfg.frameStrata or "MEDIUM"
    local baseLevel = GetBaseFrameLevelByStrata(strata)
    f:SetFrameStrata(strata)
    f:SetFrameLevel(baseLevel)
    f:SetClampedToScreen(true)
    f._barID = id

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    local bgc = barCfg.bgColor or { 0.1, 0.1, 0.1, 0.6 }
    f.bg:SetColorTexture(bgc[1], bgc[2], bgc[3], bgc[4])

    -- Mask
    f._mask = f:CreateMaskTexture()
    f._mask:SetAllPoints()
    f._mask:SetTexture([[Interface\AddOns\CDFlow\Textures\Specials\white.png]])
    f.bg:AddMaskTexture(f._mask)

    -- Border Frame
    f._borderFrame = CreateFrame("Frame", nil, f)
    f._borderFrame:SetAllPoints()
    f._borderFrame:SetFrameLevel(f:GetFrameLevel() + 5)
    f._borderFrame:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透
    f._border = f._borderFrame:CreateTexture(nil, "OVERLAY")
    f._border:SetAllPoints()
    f._border:SetBlendMode("BLEND")
    f._border:Hide()

    local iconSize = h
    f._icon = f:CreateTexture(nil, "ARTWORK")
    f._icon:SetSize(iconSize, iconSize)
    f._icon:SetPoint("LEFT", f, "LEFT", 0, 0)
    f._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local showIcon = barCfg.showIcon ~= false
    local segOffset = showIcon and (iconSize + 2) or 0
    f._segContainer = CreateFrame("Frame", nil, f)
    f._segContainer:SetPoint("TOPLEFT", f, "TOPLEFT", segOffset, 0)
    f._segContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f._segContainer:SetFrameLevel(f:GetFrameLevel() + 1)
    f._segContainer:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透

    f._textHolder = CreateFrame("Frame", nil, f)
    f._textHolder:SetAllPoints(f._segContainer)
    f._textHolder:SetFrameLevel(f:GetFrameLevel() + 6)
    f._textHolder:EnableMouse(false)  -- 禁用鼠标交互以支持点击穿透

    f._text = f._textHolder:CreateFontString(nil, "OVERLAY")
    local fontPath = ResolveFontPath(barCfg.fontName)
    f._text:SetFont(fontPath, barCfg.fontSize or 12, barCfg.outline or "OUTLINE")
    local anchor = barCfg.textAnchor or barCfg.textAlign or "RIGHT"
    local txOff = barCfg.textOffsetX or -4
    local tyOff = barCfg.textOffsetY or 0
    f._text:SetPoint(ANCHOR_POINT[anchor] or anchor, f._textHolder, ANCHOR_REL[anchor] or anchor, txOff, tyOff)
    f._text:SetTextColor(1, 1, 1, 1)
    f._text:SetJustifyH(AnchorToJustifyH(anchor))

    f._posLabel = f:CreateFontString(nil, "OVERLAY")
    f._posLabel:SetFont(STANDARD_TEXT_FONT or DEFAULT_FONT, 10, "OUTLINE")
    f._posLabel:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f._posLabel:SetTextColor(1, 1, 0, 0.8)
    f._posLabel:Hide()

    local function UpdatePosLabel(frame)
        if not frame._posLabel then return end
        local cfg = frame._cfg or barCfg
        frame._posLabel:SetFormattedText("X: %.1f  Y: %.1f", cfg.posX or 0, cfg.posY or 0)
    end

    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")

    -- 帧锚点模式下鼠标永久禁用（跟随帧移动，无法手动拖拽）
    local locked = ns.db and ns.db.monitorBars and ns.db.monitorBars.locked
    f:EnableMouse(not locked and not isFrameAnchored)
    f:SetScript("OnDragStart", function(self)
        if ns.db.monitorBars.locked then return end
        if self._frameAnchored then return end
        
        self:SetToplevel(true)
        local effScale = self:GetEffectiveScale()
        
        local sX, sY = GetCursorPosition()
        sX, sY = sX / effScale, sY / effScale
        
        local centerX, centerY = self:GetCenter()
        local xOffset = centerX - sX
        local yOffset = centerY - sY
        
        self:SetScript("OnUpdate", function(s)
            local currX, currY = GetCursorPosition()
            currX, currY = currX / effScale, currY / effScale
            
            local newCenterX = currX + xOffset
            local newCenterY = currY + yOffset
            
            local p = UIParent
            local pScale = p:GetEffectiveScale()
            local uCenterX, uCenterY = p:GetCenter()
            
            local worldX = newCenterX * effScale
            local worldY = newCenterY * effScale
            local pWorldX = uCenterX * pScale
            local pWorldY = uCenterY * pScale
            
            local worldDiffX = worldX - pWorldX
            local worldDiffY = worldY - pWorldY
            
            local valX = worldDiffX / pScale 
            local valY = worldDiffY / pScale
            
            local setX = valX * (pScale / effScale)
            local setY = valY * (pScale / effScale)
            
            setX = MB.getNearestPixel(setX, effScale)
            setY = MB.getNearestPixel(setY, effScale)
            
            s:ClearAllPoints()
            s:SetPoint("CENTER", p, "CENTER", setX, setY)
            
            if s._posLabel then
                local txt = string.format("X: %.1f  Y: %.1f", setX, setY)
                s._posLabel:SetText(txt)
            end
        end)
    end)
    f:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        
        local cx, cy = self:GetCenter()
        local p = UIParent
        local pScale = p:GetEffectiveScale()
        local effScale = self:GetEffectiveScale()
        
        local uCenterX, uCenterY = p:GetCenter()
        local worldX = cx * effScale
        local worldY = cy * effScale
        local pWorldX = uCenterX * pScale
        local pWorldY = uCenterY * pScale
        
        local worldDiffX = worldX - pWorldX
        local worldDiffY = worldY - pWorldY
        
        local valX = worldDiffX / pScale
        local valY = worldDiffY / pScale
        
        local setX = valX * (pScale / effScale)
        local setY = valY * (pScale / effScale)
        
        setX = MB.getNearestPixel(setX, effScale)
        setY = MB.getNearestPixel(setY, effScale)
        
        barCfg.posX = setX
        barCfg.posY = setY
        
        self:ClearAllPoints()
        self:SetPoint("CENTER", p, "CENTER", setX, setY)
        UpdatePosLabel(self)
    end)

    f:SetScript("OnMouseWheel", function(self, delta)
        if ns.db.monitorBars.locked then return end
        if self._frameAnchored then return end
        local effScale = self:GetEffectiveScale()
        local pp = MB.getPixelPerfectScale(effScale)
        
        local step = IsControlKeyDown() and (pp * 10) or pp
        
        if IsShiftKeyDown() then
            barCfg.posX = MB.getNearestPixel((barCfg.posX or 0) + delta * step, effScale)
        else
            barCfg.posY = MB.getNearestPixel((barCfg.posY or 0) + delta * step, effScale)
        end
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", barCfg.posX, barCfg.posY)
        UpdatePosLabel(self)
    end)

    f:SetScript("OnEnter", function(self)
        if ns.db.monitorBars.locked then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        local name = barCfg.spellName or ""
        if name ~= "" then
            GameTooltip:AddLine(name, 1, 1, 1)
        end
        GameTooltip:AddLine(ns.L.mbNudgeHint or "", 0.6, 0.8, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local locked = ns.db and ns.db.monitorBars and ns.db.monitorBars.locked
    f:EnableMouseWheel(not locked)
    if not locked then
        UpdatePosLabel(f)
        f._posLabel:Show()
    else
        f._posLabel:Hide()
    end

    f._cfg = barCfg
    f._cooldownID = nil
    f._cdmFrame = nil
    f._cachedMaxCharges = 0
    f._cachedChargeDuration = 0
    f._needsChargeRefresh = true
    f._cachedChargeInfo = nil
    f._needsDurationRefresh = true
    f._cachedChargeDurObj = nil
    f._lastRechargingSlot = nil
    f._trackedAuraInstanceID = nil
    f._lastKnownActive = false
    f._lastKnownStacks = 0
    f._nilCount = 0
    f._isChargeSpell = nil
    f._shadowCooldown = nil
    f._arcFeedFrame = 0

    activeFrames[id] = f
    return f
end

function MB:GetSize(barFrame)
    local cfg = barFrame._cfg
    if not cfg then return 200, 20 end
    
    local width = cfg.width
    local scale = cfg.scale or 1
    local height = cfg.height
    
    if cfg.barShape == "Ring" and cfg.barType == "duration" then
        height = width
    end
    
    return MB.getNearestPixel(width, scale), MB.getNearestPixel(height, scale)
end

function MB:ApplyStyle(barFrame)
    local cfg = barFrame._cfg
    if not cfg then return end

    local isRing = (cfg.barShape == "Ring" and cfg.barType == "duration")
    local width, height = self:GetSize(barFrame)
    barFrame:SetSize(width, height)

    local strata = cfg.frameStrata or "MEDIUM"
    local baseLevel = GetBaseFrameLevelByStrata(strata)
    barFrame:SetFrameStrata(strata)
    barFrame:SetFrameLevel(baseLevel)
    if barFrame._segContainer then barFrame._segContainer:SetFrameStrata(strata) end
    if barFrame._textHolder    then barFrame._textHolder:SetFrameStrata(strata) end
    if barFrame._borderFrame   then barFrame._borderFrame:SetFrameStrata(strata) end
    if barFrame._segContainer then barFrame._segContainer:SetFrameLevel(baseLevel + 1) end
    if barFrame._textHolder    then barFrame._textHolder:SetFrameLevel(baseLevel + 6) end
    if barFrame._borderFrame   then barFrame._borderFrame:SetFrameLevel(baseLevel + 5) end
    if barFrame._segments then
        for _, seg in ipairs(barFrame._segments) do
            seg:SetFrameStrata(strata)
            seg:SetFrameLevel(baseLevel + 2)
        end
    end
    if barFrame._segBorders then
        for _, border in ipairs(barFrame._segBorders) do
            border:SetFrameStrata(strata)
            border:SetFrameLevel(baseLevel + 4)
        end
    end

    local bgc = cfg.bgColor or { 0.1, 0.1, 0.1, 0.6 }
    barFrame.bg:SetColorTexture(bgc[1], bgc[2], bgc[3], bgc[4])

    local iconSize = height
    if isRing then iconSize = height * 0.7 end
    barFrame._icon:SetSize(iconSize, iconSize)
    
    local showIcon = cfg.showIcon ~= false
    if isRing then showIcon = false end
    barFrame._icon:SetShown(showIcon)

    -- Icon Mask for Ring
    if isRing and showIcon then
        if not barFrame._iconMask then
             barFrame._iconMask = barFrame:CreateMaskTexture()
             barFrame._iconMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
             barFrame._iconMask:SetAllPoints(barFrame._icon)
             barFrame._icon:AddMaskTexture(barFrame._iconMask)
        end
        barFrame._iconMask:Show()
    else
        if barFrame._iconMask then barFrame._iconMask:Hide() end
    end

    -- Spell Name for Ring
    if isRing and cfg.showSpellName then
        if not barFrame._nameText then
            barFrame._nameText = barFrame._textHolder:CreateFontString(nil, "OVERLAY")
        end
        local fontPath = ResolveFontPath(cfg.fontName)
        barFrame._nameText:SetFont(fontPath, cfg.nameFontSize or 12, cfg.outline or "OUTLINE")
        
        local nAnchor = cfg.nameAnchor or "CENTER"
        local nX = cfg.nameOffsetX or 0
        local nY = cfg.nameOffsetY or 0
        
        barFrame._nameText:ClearAllPoints()
        barFrame._nameText:SetPoint(ANCHOR_POINT[nAnchor] or nAnchor, barFrame, ANCHOR_REL[nAnchor] or nAnchor, nX, nY)
        barFrame._nameText:SetText(cfg.spellName or "")
        barFrame._nameText:Show()
    else
        if barFrame._nameText then barFrame._nameText:Hide() end
    end

    if isRing then
        barFrame._icon:ClearAllPoints()
        barFrame._icon:SetPoint("CENTER", barFrame, "CENTER", 0, 0)
        
        barFrame._segContainer:ClearAllPoints()
        barFrame._segContainer:SetAllPoints(barFrame)
        
        -- Ring mode handles its own background in CreateSegments, hide main bg
        barFrame.bg:Hide()
    else
        barFrame._icon:ClearAllPoints()
        barFrame._icon:SetPoint("LEFT", barFrame, "LEFT", 0, 0)
        barFrame.bg:Show()

        local segOffset = showIcon and (iconSize + 2) or 0
        barFrame._segContainer:ClearAllPoints()
        barFrame._segContainer:SetPoint("TOPLEFT", barFrame, "TOPLEFT", segOffset, 0)
        barFrame._segContainer:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
    end

    local count
    if cfg.barType == "charge" then
        count = (cfg.maxCharges > 0 and cfg.maxCharges or barFrame._cachedMaxCharges)
    elseif cfg.barType == "duration" then
        count = 1  -- duration 类型只需要一个分段
    else
        count = cfg.maxStacks
    end
    if count > 0 then
        C_Timer.After(0, function()
            if barFrame._segContainer then
                CreateSegments(barFrame, count, cfg)
            end
        end)
    end

    local fontPath = ResolveFontPath(cfg.fontName)
    barFrame._text:SetFont(fontPath, cfg.fontSize or 12, cfg.outline or "OUTLINE")
    barFrame._text:SetShown(cfg.showText ~= false)
    local anchor = cfg.textAnchor or cfg.textAlign or "RIGHT"
    barFrame._text:ClearAllPoints()
    barFrame._text:SetPoint(ANCHOR_POINT[anchor] or anchor, barFrame._textHolder, ANCHOR_REL[anchor] or anchor, cfg.textOffsetX or -4, cfg.textOffsetY or 0)
    barFrame._text:SetJustifyH(AnchorToJustifyH(anchor))

    if cfg.borderStyle ~= "segment" and not isRing then
        MB.ApplyMaskAndBorderSettings(barFrame, cfg)
    elseif barFrame._borderFrame then
        barFrame._borderFrame:Hide()
    end

    if cfg.spellID and cfg.spellID > 0 then
        local tex = C_Spell.GetSpellTexture(cfg.spellID)
        if tex then barFrame._icon:SetTexture(tex) end
    end
end

------------------------------------------------------
-- 更新逻辑
------------------------------------------------------

local function SetStackSegmentsValue(barFrame, value)
    local segs = barFrame._segments
    if not segs then return end
    for i = 1, #segs do
        segs[i]:SetValue(value)
    end
    -- 同时更新阈值覆盖层
    local overlays = barFrame._thresholdOverlays
    if overlays then
        for i = 1, #overlays do
            overlays[i]:SetValue(value)
        end
    end
end

local function GetAuraDataByInstanceID(auraInstanceID, preferredUnit, secondUnit)
    if not HasAuraInstanceID(auraInstanceID) then return nil, nil end
    local units, exists = {}, {}
    local function AddUnit(u)
        if type(u) == "string" and u ~= "" and not exists[u] then
            exists[u] = true
            units[#units + 1] = u
        end
    end
    AddUnit(preferredUnit)
    AddUnit(secondUnit)
    AddUnit("player")
    AddUnit("target")
    AddUnit("pet")
    AddUnit("vehicle")
    AddUnit("focus")
    for _, unit in ipairs(units) do
        local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
        if auraData then
            return auraData, unit
        end
    end
    return nil, nil
end

UpdateStackBar = function(barFrame)
    local cfg = barFrame._cfg
    if not cfg or cfg.barType ~= "stack" then return end

    local spellID = cfg.spellID
    if not spellID or spellID <= 0 then return end

    local stacks = 0
    local auraActive = false
    local cooldownID = spellToCooldownID[spellID]
    barFrame._cooldownID = cooldownID

    if cooldownID then
        local cdmFrame = FindCDMFrame(cooldownID)
        if cdmFrame then
            HookCDMFrame(cdmFrame, barFrame._barID)
            barFrame._cdmFrame = cdmFrame

            if HasAuraInstanceID(cdmFrame.auraInstanceID) then
                local baseUnit = cdmFrame.auraDataUnit or cfg.unit or barFrame._trackedUnit or "player"
                local auraData, trackedUnit = GetAuraDataByInstanceID(cdmFrame.auraInstanceID, baseUnit, barFrame._trackedUnit)
                if trackedUnit then
                    LinkBarToAura(barFrame, trackedUnit, cdmFrame.auraInstanceID)
                else
                    LinkBarToAura(barFrame, baseUnit, cdmFrame.auraInstanceID)
                end
                if auraData then
                    auraActive = true
                    stacks = auraData.applications or 0
                end
            end
        end
    end

    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local auraData, trackedUnit = GetAuraDataByInstanceID(barFrame._trackedAuraInstanceID, barFrame._trackedUnit, cfg.unit)
        if auraData then
            auraActive = true
            stacks = auraData.applications or 0
            if trackedUnit then
                LinkBarToAura(barFrame, trackedUnit, barFrame._trackedAuraInstanceID)
            end
        end
    end

    if not auraActive then
        if barFrame._lastKnownActive then
            stacks = barFrame._lastKnownStacks or 0
            barFrame._nilCount = (barFrame._nilCount or 0) + 1
            if barFrame._nilCount > 5 then
                barFrame._lastKnownActive = false
                barFrame._lastKnownStacks = 0
                barFrame._trackedAuraInstanceID = nil
                barFrame._trackedUnit = nil
                UnlinkBarFromAura(barFrame._barID)
                stacks = 0
            end
        end
    else
        barFrame._nilCount = 0
    end

    local isSecret = issecretvalue and issecretvalue(stacks)
    local rawStacks = stacks

    local stacksResolved = not isSecret
    local maxStacks = cfg.maxStacks or 5
    local stacksForColor = stacks
    local stacksForText = stacks
    local segs = barFrame._segments
    if segs then
        if isSecret then
            stacksForText = rawStacks
        else
            barFrame._arcFeedFrame = 0
            if barFrame._arcDetectors then
                for i = 1, maxStacks do
                    local det = barFrame._arcDetectors[i]
                    if det then det:SetValue(0) end
                end
            end
        end

        if isSecret then
            barFrame._displayStacks = nil
            barFrame._targetStacks = nil
            SetStackSegmentsValue(barFrame, rawStacks)
            FeedArcDetectors(barFrame, rawStacks, maxStacks)
            local resolved = GetExactCount(barFrame, maxStacks)
            if type(resolved) == "number" then
                stacksForColor = resolved
                stacksResolved = true
            else
                stacksResolved = false
            end
        elseif stacksResolved then
            local prevDisplay = barFrame._displayStacks
            local smooth = (cfg.smoothAnimation ~= false)
            if prevDisplay == nil or not smooth then
                barFrame._displayStacks = stacks
                barFrame._targetStacks  = stacks
                SetStackSegmentsValue(barFrame, stacks)
            else
                barFrame._targetStacks = stacks
                if stacks < prevDisplay then
                    barFrame._displayStacks = stacks
                    SetStackSegmentsValue(barFrame, stacks)
                end
            end
        end
    end

    if auraActive then
        barFrame._lastKnownActive = true
        if not isSecret and type(stacks) == "number" then
            barFrame._lastKnownStacks = stacks
        elseif stacksResolved and type(stacksForColor) == "number" then
            barFrame._lastKnownStacks = stacksForColor
        end
    end

    if cfg.showText ~= false and barFrame._text then
        if isSecret then
            barFrame._text:SetText(stacksForText)
        else
            barFrame._text:SetText(tostring(stacks))
        end
    end
end

local function UpdateRegularCooldownBar(barFrame)
    local cfg = barFrame._cfg
    local spellID = cfg.spellID

    local isOnGCD = false
    pcall(function()
        local cdInfo = C_Spell.GetSpellCooldown(spellID)
        if cdInfo and cdInfo.isOnGCD == true then isOnGCD = true end
    end)

    local shadowCD = GetOrCreateShadowCooldown(barFrame)
    local durObj = nil
    if isOnGCD then
        shadowCD:SetCooldown(0, 0)
    else
        pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
        if durObj then
            shadowCD:Clear()
            pcall(function() shadowCD:SetCooldownFromDurationObject(durObj, true) end)
        else
            shadowCD:SetCooldown(0, 0)
        end
    end

    local isOnCooldown = shadowCD:IsShown()

    local segs = barFrame._segments
    if not segs or #segs ~= 1 then
        CreateSegments(barFrame, 1, cfg)
        segs = barFrame._segments
    end
    if not segs or #segs < 1 then return end

    local seg = segs[1]
    local interpolation = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or 0
    local direction = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime or 0

    if isOnCooldown and not isOnGCD then
        if barFrame._needsDurationRefresh and durObj then
            seg:SetMinMaxValues(0, 1)
            if seg.SetTimerDuration then
                seg:SetTimerDuration(durObj, interpolation, direction)
                if seg.SetToTargetValue then
                    seg:SetToTargetValue()
                end
            else
                seg:SetMinMaxValues(0, 1)
                seg:SetValue(0)
            end
            barFrame._needsDurationRefresh = false
        end
    else
        seg:SetMinMaxValues(0, 1)
        seg:SetValue(1)
    end

    if cfg.showText ~= false and barFrame._text then
        -- 调整文字位置：如果是圆环且没有指定 offset，尝试居中
        -- 这里只做简单的文字更新，位置在 ApplyStyle 处理
        if isOnCooldown and not isOnGCD and durObj then
            local remaining = durObj:GetRemainingDuration()
            local ok, result = pcall(function()
                local num = tonumber(remaining)
                if num then return string.format("%.1f", num) end
                return remaining
            end)
            if ok and result then
                barFrame._text:SetText(result)
            else
                barFrame._text:SetText(remaining or "")
            end
        else
            barFrame._text:SetText("")
        end
    end
end

local function UpdateChargeBar(barFrame)
    local cfg = barFrame._cfg
    if not cfg or cfg.barType ~= "charge" then return end

    local spellID = cfg.spellID
    if not spellID or spellID <= 0 then return end

    local chargeJustRefreshed = false
    if barFrame._needsChargeRefresh then
        barFrame._cachedChargeInfo = C_Spell.GetSpellCharges(spellID)
        barFrame._needsChargeRefresh = false
        barFrame._isChargeSpell = barFrame._cachedChargeInfo ~= nil
        chargeJustRefreshed = true
    end

    if barFrame._isChargeSpell == false then
        UpdateRegularCooldownBar(barFrame)
        return
    end

    local chargeInfo = barFrame._cachedChargeInfo
    if not chargeInfo then return end

    local maxCharges = cfg.maxCharges
    if maxCharges <= 0 then
        if chargeInfo.maxCharges then
            if not issecretvalue or not issecretvalue(chargeInfo.maxCharges) then
                barFrame._cachedMaxCharges = chargeInfo.maxCharges
            end
        end
        maxCharges = barFrame._cachedMaxCharges
    end
    if maxCharges <= 0 then maxCharges = 2 end

    local segs = barFrame._segments
    if not segs or #segs ~= maxCharges then
        CreateSegments(barFrame, maxCharges, cfg)
        segs = barFrame._segments
    end
    if not segs then return end

    local currentCharges = chargeInfo.currentCharges
    local isSecret = issecretvalue and issecretvalue(currentCharges)
    local exactCharges = currentCharges

    if isSecret then
        FeedArcDetectors(barFrame, currentCharges, maxCharges)
        exactCharges = GetExactCount(barFrame, maxCharges)
    end

    local needApplyTimer = false
    if barFrame._needsDurationRefresh then
        if isSecret and chargeJustRefreshed then
            -- 秘密值需一帧渲染后才能解析
        else
            barFrame._cachedChargeDurObj = C_Spell.GetSpellChargeDuration(spellID)
            barFrame._needsDurationRefresh = false
            needApplyTimer = true
        end
    end

    local chargeDurObj = barFrame._cachedChargeDurObj
    local rechargingSlot = (type(exactCharges) == "number" and exactCharges < maxCharges) and (exactCharges + 1) or nil

    if barFrame._lastRechargingSlot ~= rechargingSlot then
        needApplyTimer = true
        barFrame._lastRechargingSlot = rechargingSlot
    end

    local interpolation = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or 0
    local direction = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime or 0

    for i = 1, maxCharges do
        local seg = segs[i]
        if not seg then break end

        if type(exactCharges) == "number" then
            if i <= exactCharges then
                seg:SetMinMaxValues(0, 1)
                seg:SetValue(1)
            elseif rechargingSlot and i == rechargingSlot then
                if needApplyTimer then
                    if chargeDurObj and seg.SetTimerDuration then
                        seg:SetMinMaxValues(0, 1)
                        seg:SetTimerDuration(chargeDurObj, interpolation, direction)
                        if seg.SetToTargetValue then
                            seg:SetToTargetValue()
                        end
                    else
                        local cd = chargeInfo.cooldownDuration or 0
                        local start = chargeInfo.cooldownStartTime or 0
                        if cd > 0 and start > 0 then
                            seg:SetMinMaxValues(0, 1)
                            local now = GetTime()
                            seg:SetValue(math.min(math.max((now - start) / cd, 0), 1))
                        else
                            seg:SetMinMaxValues(0, 1)
                            seg:SetValue(0)
                        end
                    end
                end
            else
                seg:SetMinMaxValues(0, 1)
                seg:SetValue(0)
            end
        end
    end

    if cfg.showText ~= false and barFrame._text then
        if type(exactCharges) == "number" and exactCharges >= maxCharges then
            barFrame._text:SetText("")
        elseif chargeDurObj then
            local remaining = chargeDurObj:GetRemainingDuration()
            local ok, result = pcall(function()
                local num = tonumber(remaining)
                if num then
                    return string.format("%.1f", num)
                end
                return remaining
            end)
            if ok and result then
                barFrame._text:SetText(result)
            else
                barFrame._text:SetText(remaining or "")
            end
        else
            barFrame._text:SetText("")
        end
    end
end

local function UpdateDurationBar(barFrame)
    local cfg = barFrame._cfg
    if not cfg or cfg.barType ~= "duration" then return end

    local spellID = cfg.spellID
    if not spellID or spellID <= 0 then return end

    local auraActive = false
    local cooldownID = spellToCooldownID[spellID]
    barFrame._cooldownID = cooldownID

    local cdmFrame = nil
    local auraInstanceID = nil
    local unit = nil

    if cooldownID then
        cdmFrame = FindCDMFrame(cooldownID)
        if cdmFrame then
            HookCDMFrame(cdmFrame, barFrame._barID)
            barFrame._cdmFrame = cdmFrame

            if HasAuraInstanceID(cdmFrame.auraInstanceID) then
                auraActive = true
                auraInstanceID = cdmFrame.auraInstanceID
                unit = cdmFrame.auraDataUnit or cfg.unit or "player"
                barFrame._trackedAuraInstanceID = auraInstanceID
                barFrame._trackedUnit = unit
            end
        end
    end

    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", barFrame._trackedAuraInstanceID)
        if not auraData then
            auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("target", barFrame._trackedAuraInstanceID)
            if auraData then
                unit = "target"
            end
        else
            unit = "player"
        end
        if auraData then
            auraActive = true
            auraInstanceID = barFrame._trackedAuraInstanceID
            barFrame._trackedUnit = unit
        end
    end

    -- 创建单个分段条
    local segs = barFrame._segments
    if not segs or #segs ~= 1 then
        CreateSegments(barFrame, 1, cfg)
        segs = barFrame._segments
    end
    if not segs or #segs < 1 then return end

    local seg = segs[1]

    if auraActive and auraInstanceID and unit then
        -- 使用 C_UnitAuras.GetAuraDuration 获取 DurationObject
        local timerOK = pcall(function()
            local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
            if durObj then
                -- 如果是圆环 (CooldownFrame)
                if seg._isRing then
                    -- 只在需要刷新时更新 CooldownFrame，避免重复 SetCooldown 导致动画重置
                    if barFrame._needsDurationRefresh then
                        -- CooldownFrame 可以直接 SetCooldownFromDurationObject
                        if seg.SetCooldownFromDurationObject then
                             seg:SetCooldownFromDurationObject(durObj)
                        else
                             -- Fallback: 尝试手动获取并设置
                             local start = durObj:GetCooldownStartTime()
                             local duration = durObj:GetCooldownDuration()
                             seg:SetCooldown(start, duration)
                        end
                        barFrame._needsDurationRefresh = false
                    end
                else
                    -- 使用 SetTimerDuration 让 StatusBar 自动处理 secret values
                    seg:SetMinMaxValues(0, 1)
                    local interpolation = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or 0
                    local direction = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime or 0

                    if seg.SetTimerDuration then
                        seg:SetTimerDuration(durObj, interpolation, direction)
                        if seg.SetToTargetValue then
                            seg:SetToTargetValue()
                        end
                    end
                end

                -- 应用颜色（基于剩余时间的阈值）
                -- 暂时使用默认颜色
                local c = cfg.barColor or { 0.2, 0.8, 0.2, 1 }
                if seg._isRing then
                    seg:SetSwipeColor(c[1], c[2], c[3], c[4])
                else
                    seg:SetStatusBarColor(c[1], c[2], c[3], c[4])
                end

                -- 更新文本显示
                if cfg.showText ~= false and barFrame._text then
                    local remaining = durObj:GetRemainingDuration()
                    -- 格式化为 1 位小数
                    local ok, remainingNum = pcall(tonumber, remaining)
                    if ok and remainingNum then
                        barFrame._text:SetText(string.format("%.1f", remainingNum))
                    else
                        barFrame._text:SetText(remaining)
                    end
                end
            end
        end)

        if not timerOK then
            -- 无法使用 SetTimerDuration，显示为满
            if seg._isRing then
                if barFrame._needsDurationRefresh then
                    -- 强制满显示
                    seg:SetCooldown(GetTime(), 3600) 
                    barFrame._needsDurationRefresh = false
                end
            else
                seg:SetMinMaxValues(0, 1)
                seg:SetValue(1)
            end

            if cfg.showText ~= false and barFrame._text then
                barFrame._text:SetText("")
            end
        end
    else
        -- Aura 不活跃
        barFrame._trackedAuraInstanceID = nil
        barFrame._trackedUnit = nil

        if seg._isRing then
            if barFrame._needsDurationRefresh then
                seg:SetCooldown(0, 0) -- 隐藏 Swipe
                barFrame._needsDurationRefresh = false
            end
        else
            seg:SetMinMaxValues(0, 1)
            seg:SetValue(0)
        end

        if cfg.showText ~= false and barFrame._text then
            barFrame._text:SetText("")
        end
    end

    -- 存储 aura 活跃状态，供 ShouldBarBeVisible 使用
    local wasActive = barFrame._isActive
    barFrame._isActive = auraActive

    -- 如果 aura 活跃状态发生变化，且显示条件为 "active_only"，立即更新可见性
    if wasActive ~= auraActive and cfg.showCondition == "active_only" then
        barFrame:SetShown(ShouldBarBeVisible(cfg, barFrame))
    end
end

------------------------------------------------------
-- 帧锚点（Frame Anchor）支持
------------------------------------------------------

-- 逻辑锚点键：映射到 CDM 查看器帧，自动适配 QUI / 原生
local LOGICAL_ANCHOR_FRAMES = {
    CDM_Essential = function()
        local fn = rawget(_G, "QUI_GetCDMViewerFrame")
        return fn and fn("essential") or rawget(_G, "EssentialCooldownViewer")
    end,
    CDM_Utility = function()
        local fn = rawget(_G, "QUI_GetCDMViewerFrame")
        return fn and fn("utility") or rawget(_G, "UtilityCooldownViewer")
    end,
    CDM_BuffIcon = function()
        local fn = rawget(_G, "QUI_GetCDMViewerFrame")
        return fn and fn("buffIcon") or rawget(_G, "BuffIconCooldownViewer")
    end,
}

local function ResolveAnchorFrame(name)
    if not name or name == "" or name == "__CUSTOM__" then return nil end
    local resolver = LOGICAL_ANCHOR_FRAMES[name]
    if resolver then return resolver() end
    return rawget(_G, name)
end

local function UpdateFrameAnchor(f, cfg)
    local anchorFr = ResolveAnchorFrame(cfg.anchorFrame)
    if not anchorFr or not anchorFr:IsShown() then
        if f:IsShown() then f:Hide() end
        return
    end
    if not ShouldBarBeVisible(cfg, f) then
        if f:IsShown() then f:Hide() end
        return
    end
    -- Auto-width: match anchor frame width, rebuild when it changes.
    -- Use cfg._lastAnchorWidth (not f._lastAnchorWidth) so it survives RebuildAllBars.
    if cfg.autoWidth and not f._autoWidthPending then
        local aw = anchorFr:GetWidth()
        if aw and aw > 1 and math.abs((cfg._lastAnchorWidth or 0) - aw) >= 2 then
            cfg._lastAnchorWidth = aw
            cfg.width = MB.getNearestPixel(aw)
            f._autoWidthPending = true
            C_Timer.After(0.1, function()
                f._autoWidthPending = nil
                MB:RebuildAllBars()
            end)
            return
        end
    end
    local ap = cfg.anchorPoint    or "TOP"
    local rp = cfg.anchorRelPoint or "BOTTOM"
    local ox = cfg.anchorOffX     or 0
    local oy = cfg.anchorOffY     or -2
    f:ClearAllPoints()
    f:SetPoint(ap, anchorFr, rp, ox, oy)
    if not f:IsShown() then f:Show() end
end

------------------------------------------------------
-- OnUpdate 循环
------------------------------------------------------

local function UpdateAllBars()
    local bars = ns.db and ns.db.monitorBars and ns.db.monitorBars.bars
    if not bars then return end

    for _, barCfg in ipairs(bars) do
        local f = activeFrames[barCfg.id]
        if f and barCfg.enabled and barCfg.spellID > 0 then
            if f._frameAnchored then
                UpdateFrameAnchor(f, barCfg)
            end
            if barCfg.barType == "stack" then
                UpdateStackBar(f)
            elseif barCfg.barType == "charge" then
                UpdateChargeBar(f)
            elseif barCfg.barType == "duration" then
                UpdateDurationBar(f)
            end
        end
    end
end

-- 每帧推进 stack 类型分段条的波形填充动画
local function AnimateStackBars(dt)
    for _, barFrame in pairs(activeFrames) do
        local cfg = barFrame._cfg
        if cfg and cfg.barType == "stack" and cfg.smoothAnimation ~= false then
            local target  = barFrame._targetStacks
            local display = barFrame._displayStacks
            if target ~= nil and display ~= nil and display < target then
                local diff = target - display
                local speed = STACK_FILL_SPEED
                if diff > 1 then
                    speed = speed * diff
                end
                display = math.min(target, display + speed * dt)
                barFrame._displayStacks = display

                local segs = barFrame._segments
                if segs then
                    SetStackSegmentsValue(barFrame, display)
                end
            end
        end
    end
end

local updateFrame = CreateFrame("Frame")
updateFrame:SetScript("OnUpdate", function(_, dt)
    frameTick = frameTick + 1

    -- 波形动画每帧驱动（不节流）
    AnimateStackBars(dt)

    elapsed = elapsed + dt
    if elapsed < UPDATE_INTERVAL then return end
    elapsed = 0
    UpdateAllBars()
end)
updateFrame:Hide()

------------------------------------------------------
-- 生命周期 / 事件
------------------------------------------------------

local hasTarget = false
local isDragonriding = false

local function IsClassMatchedForCurrentPlayer(classTag)
    if classTag == nil or classTag == "" or classTag == "ALL" then
        return true
    end
    return classTag == PLAYER_CLASS_TAG
end

ShouldBarBeVisible = function(barCfg, barFrame)
    if not IsClassMatchedForCurrentPlayer(barCfg.class) then
        return false
    end
    local cond = barCfg.showCondition or (barCfg.combatOnly and "combat") or "always"
    if cond == "combat"          then return inCombat end
    if cond == "target"          then return hasTarget end
    if cond == "dragonriding"    then return isDragonriding end
    if cond == "not_dragonriding" then return not isDragonriding end
    if cond == "active_only"     then return barFrame and barFrame._isActive end
    return true
end

local function IsBarVisibleForSpec(barCfg)
    local specs = barCfg.specs
    if not specs or #specs == 0 then return true end
    local cur = GetSpecialization() or 1
    for _, s in ipairs(specs) do
        if s == cur then return true end
    end
    return false
end

function MB:RebuildCDMSuppressedSet()
    local suppressed = ns.cdmSuppressedCooldownIDs
    wipe(suppressed)
    local bars = ns.db and ns.db.monitorBars and ns.db.monitorBars.bars
    if not bars then return end
    for _, barCfg in ipairs(bars) do
        if barCfg.enabled
            and IsClassMatchedForCurrentPlayer(barCfg.class)
            and barCfg.hideFromCDM
            and barCfg.spellID > 0 then
            local sid = barCfg.spellID
            local cdID = spellToCooldownID[sid]
            -- 若直接 spellID 未命中，尝试 base spell 变体（天赋替换/Override 时 ID 不同）
            if not cdID and C_Spell and C_Spell.GetBaseSpell then
                local baseID = C_Spell.GetBaseSpell(sid)
                if baseID and baseID ~= sid then
                    cdID = spellToCooldownID[baseID]
                end
            end
            if cdID then
                suppressed[cdID] = true
            end
        end
    end
    -- 触发完整 RefreshViewer，重新分类并隐藏 suppressed 帧
    if ns.Layout and ns.Layout.RequestBuffRefreshFromMB then
        ns.Layout.RequestBuffRefreshFromMB()
    end
end

-- 当 CDM buff 图标帧首次出现时（含战斗中），实时更新 spellID→cooldownID 映射并重建 suppressed 集合。
-- 解决 reload 后首次战斗中 hideFromCDM 未能及时生效的时序问题。
function MB:UpdateFrameMapping(frame)
    if not frame then return end
    local cdID = MB.GetCooldownIDFromFrame(frame)
    if not cdID then return end
    cooldownIDToFrame[cdID] = frame
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo and
        C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    if info then
        local sid = MB.ResolveSpellID(info)
        if sid and sid > 0 and not spellToCooldownID[sid] then
            spellToCooldownID[sid] = cdID
        end
        if info.linkedSpellIDs then
            for _, lid in ipairs(info.linkedSpellIDs) do
                if lid and lid > 0 and not spellToCooldownID[lid] then
                    spellToCooldownID[lid] = cdID
                end
            end
        end
        if info.spellID and info.spellID > 0 and not spellToCooldownID[info.spellID] then
            spellToCooldownID[info.spellID] = cdID
        end
    end
    self:RebuildCDMSuppressedSet()
end

function MB:InitAllBars()
    local bars = ns.db and ns.db.monitorBars and ns.db.monitorBars.bars
    if not bars then return end

    self:RebuildCDMSuppressedSet()

    for _, barCfg in ipairs(bars) do
        if barCfg.enabled
            and barCfg.spellID > 0
            and IsClassMatchedForCurrentPlayer(barCfg.class)
            and IsBarVisibleForSpec(barCfg) then
            local f = self:CreateBarFrame(barCfg)
            self:ApplyStyle(f)

            local count
            if barCfg.barType == "charge" then
                count = (barCfg.maxCharges > 0 and barCfg.maxCharges or 1)
            elseif barCfg.barType == "duration" then
                count = 1
            else
                count = barCfg.maxStacks
            end
            C_Timer.After(0, function()
                if f._segContainer and f._segContainer:GetWidth() > 0 then
                    CreateSegments(f, count, barCfg)
                end
            end)

            if f._frameAnchored then
                UpdateFrameAnchor(f, barCfg)
            elseif ShouldBarBeVisible(barCfg, f) then
                f:Show()
            else
                f:Hide()
            end
        end
    end

    updateFrame:Show()

    -- 初始化完成后，根据当前锁定状态设置所有框架的鼠标交互
    local locked = ns.db.monitorBars.locked
    if locked ~= nil then
        self:SetLocked(locked)
    end
end

function MB:DestroyBar(barID)
    local f = activeFrames[barID]
    if f then
        UnlinkBarFromAura(barID)
        f:Hide()
        f:SetParent(nil)
        activeFrames[barID] = nil
    end
end

function MB:DestroyAllBars()
    for id, f in pairs(activeFrames) do
        f:Hide()
        f:SetParent(nil)
    end
    wipe(activeFrames)
    wipe(auraKeyToBarIDs)
    wipe(barIDToAuraKey)
    wipe(ns.cdmSuppressedCooldownIDs)
    updateFrame:Hide()
end

function MB:RebuildAllBars()
    self:DestroyAllBars()
    self:InitAllBars()
end

local function RefreshBarVisibility()
    for _, f in pairs(activeFrames) do
        if f._cfg then
            if f._frameAnchored then
                UpdateFrameAnchor(f, f._cfg)
            else
                f:SetShown(ShouldBarBeVisible(f._cfg, f))
            end
        end
    end
end

function MB:OnCombatEnter()
    inCombat = true
    RefreshBarVisibility()
end

function MB:OnCombatLeave()
    inCombat = false
    RefreshBarVisibility()
    self:ScanCDMViewers()
    for _, f in pairs(activeFrames) do
        f._needsChargeRefresh = true
        f._needsDurationRefresh = true
        f._nilCount = 0
        f._isChargeSpell = nil
        if f._cfg and f._cfg.barType == "stack" then
            f._arcFeedFrame = 0
            if f._arcDetectors then
                for _, det in pairs(f._arcDetectors) do
                    det:SetValue(0)
                end
            end
        end
        if f._cfg and f._cfg.barType == "charge" and f._cfg.spellID > 0 then
            local chargeInfo = C_Spell.GetSpellCharges(f._cfg.spellID)
            if chargeInfo and chargeInfo.maxCharges then
                if not issecretvalue or not issecretvalue(chargeInfo.maxCharges) then
                    f._cachedMaxCharges = chargeInfo.maxCharges
                end
            end
        end
    end
end

function MB:OnChargeUpdate()
    for _, f in pairs(activeFrames) do
        f._needsChargeRefresh = true
        f._needsDurationRefresh = true
    end
end

function MB:OnCooldownUpdate()
    for _, f in pairs(activeFrames) do
        if f._cfg and f._cfg.barType == "charge" then
            f._needsDurationRefresh = true
        end
    end
end

function MB:OnAuraUpdate(unit, unitAuraUpdateInfo)
    local function UpdateDurationBars()
        for _, f in pairs(activeFrames) do
            if f._cfg and f._cfg.barType == "duration" then
                 if f._cfg.unit == unit or (f._cfg.unit == nil and unit == "player") then
                     f._needsDurationRefresh = true
                 end
            end
        end
    end

    if unit and unitAuraUpdateInfo and not unitAuraUpdateInfo.isFullUpdate then
        local touched = {}
        local function MarkAuraID(auraInstanceID)
            local key = BuildAuraKey(unit, auraInstanceID)
            if not key then return end
            local bars = auraKeyToBarIDs[key]
            if not bars then return end
            for barID in pairs(bars) do
                touched[barID] = true
            end
        end

        if unitAuraUpdateInfo.updatedAuraInstanceIDs then
            for _, aid in ipairs(unitAuraUpdateInfo.updatedAuraInstanceIDs) do
                MarkAuraID(aid)
            end
        end
        if unitAuraUpdateInfo.removedAuraInstanceIDs then
            for _, aid in ipairs(unitAuraUpdateInfo.removedAuraInstanceIDs) do
                MarkAuraID(aid)
            end
        end
        if unitAuraUpdateInfo.addedAuras then
            for _, aura in ipairs(unitAuraUpdateInfo.addedAuras) do
                if aura and aura.auraInstanceID then
                    MarkAuraID(aura.auraInstanceID)
                end
            end
        end

        if next(touched) then
            for barID in pairs(touched) do
                local f = activeFrames[barID]
                if f and f._cfg and f._cfg.barType == "stack" then
                    UpdateStackBar(f)
                end
            end
            UpdateDurationBars()
            return
        end
    end

    for _, f in pairs(activeFrames) do
        if f._cfg and f._cfg.barType == "stack" then
            local cfgUnit = f._cfg.unit or "player"
            if cfgUnit == unit or f._trackedUnit == unit or (cfgUnit == "target" and unit == "target") then
                UpdateStackBar(f)
            end
        end
    end
    UpdateDurationBars()
end

function MB:OnSkyridingChanged()
    local prev = isDragonriding
    isDragonriding = IsSkyriding()
    if isDragonriding ~= prev then
        RefreshBarVisibility()
    end
end

function MB:OnTargetChanged()
    hasTarget = UnitExists("target") == true
    for _, f in pairs(activeFrames) do
        if f._cfg then
            if f._cfg.unit == "target" then
                UnlinkBarFromAura(f._barID)
                f._trackedAuraInstanceID = nil
                f._trackedUnit = nil
            end
            f:SetShown(ShouldBarBeVisible(f._cfg, f))
        end
    end
end

function MB:SetLocked(locked)
    ns.db.monitorBars.locked = locked
    for _, f in pairs(activeFrames) do
        local anchored = f._frameAnchored
        f:EnableMouse(not locked and not anchored)
        f:EnableMouseWheel(not locked and not anchored)
        if f._posLabel then
            if locked or anchored then
                f._posLabel:Hide()
            else
                local cfg = f._cfg
                if cfg then
                    f._posLabel:SetFormattedText("X: %.1f  Y: %.1f", cfg.posX or 0, cfg.posY or 0)
                end
                f._posLabel:Show()
            end
        end
    end
end

function MB:GetActiveFrame(barID)
    return activeFrames[barID]
end
