-- 技能激活高亮 + Buff 增益高亮特效
local _, ns = ...

local Style = ns.Style
local LCG
local GLOW_COLOR = { 0.95, 0.95, 0.32, 1 }
local GLOW_KEY = "CDFlow"
local GLOW_KEY_BUFF = "CDFlowBuff"
local activeGlowFrames = {}
local activeBuffGlowFrames = {}

function Style:HideOriginalGlow(button)
    if button.SpellActivationAlert then
        button.SpellActivationAlert:Hide()
    end
end

function Style:ShowHighlight(button)
    local cfg = ns.db and ns.db.highlight
    if not cfg or not button then return end

    activeGlowFrames[button] = true

    if cfg.style == "NONE" then
        self:HideOriginalGlow(button)
        self:StopGlow(button)
        return
    end

    if cfg.style == "DEFAULT" then
        self:StopGlow(button)
        return
    end

    self:HideOriginalGlow(button)

    if not LCG then
        LCG = LibStub("LibCustomGlow-1.0", true)
        if not LCG then return end
    end

    if button._cdf_glowType and button._cdf_glowType ~= cfg.style then
        self:StopGlow(button)
    end

    if cfg.style == "PIXEL" then
        LCG.PixelGlow_Start(button, GLOW_COLOR, cfg.lines, cfg.frequency,
            nil, cfg.thickness, 0, 0, false, GLOW_KEY, 1)
    elseif cfg.style == "AUTOCAST" then
        LCG.AutoCastGlow_Start(button, GLOW_COLOR, nil, cfg.frequency,
            cfg.scale, 0, 0, GLOW_KEY, 1)
    elseif cfg.style == "PROC" then
        LCG.ProcGlow_Start(button, {
            color = GLOW_COLOR, key = GLOW_KEY, frameLevel = 1,
            startAnim = true, duration = 1,
        })
    elseif cfg.style == "BUTTON" then
        LCG.ButtonGlow_Start(button, GLOW_COLOR, cfg.frequency, 1)
    end

    button._cdf_glowType = cfg.style
    button._cdf_glowActive = true
end

function Style:StopGlow(button)
    if not LCG or not button._cdf_glowType then return end

    if button._cdf_glowType == "PIXEL" then
        LCG.PixelGlow_Stop(button, GLOW_KEY)
    elseif button._cdf_glowType == "AUTOCAST" then
        LCG.AutoCastGlow_Stop(button, GLOW_KEY)
    elseif button._cdf_glowType == "PROC" then
        LCG.ProcGlow_Stop(button, GLOW_KEY)
    elseif button._cdf_glowType == "BUTTON" then
        LCG.ButtonGlow_Stop(button)
    end

    button._cdf_glowType = nil
    button._cdf_glowActive = nil
end

function Style:HideHighlight(button)
    if not button then return end
    activeGlowFrames[button] = nil
    self:StopGlow(button)
end

function Style:RefreshAllGlows()
    local frames = {}
    for frame in pairs(activeGlowFrames) do
        frames[#frames + 1] = frame
    end
    for _, frame in ipairs(frames) do
        self:StopGlow(frame)
        self:ShowHighlight(frame)
    end
end

------------------------------------------------------
-- Buff 增益高亮
------------------------------------------------------

function Style:ShowBuffGlow(button)
    local cfg = ns.db and ns.db.buffGlow
    if not cfg or not cfg.enabled or not button then return end

    activeBuffGlowFrames[button] = true

    if cfg.style == "NONE" then
        self:StopBuffGlow(button)
        return
    end

    if cfg.style == "DEFAULT" then
        self:StopBuffGlow(button)
        return
    end

    if not LCG then
        LCG = LibStub("LibCustomGlow-1.0", true)
        if not LCG then return end
    end

    if button._cdf_buffGlowType and button._cdf_buffGlowType ~= cfg.style then
        self:StopBuffGlow(button)
    end

    if cfg.style == "PIXEL" then
        LCG.PixelGlow_Start(button, GLOW_COLOR, cfg.lines, cfg.frequency,
            nil, cfg.thickness, 0, 0, false, GLOW_KEY_BUFF, 1)
    elseif cfg.style == "AUTOCAST" then
        LCG.AutoCastGlow_Start(button, GLOW_COLOR, nil, cfg.frequency,
            cfg.scale, 0, 0, GLOW_KEY_BUFF, 1)
    elseif cfg.style == "PROC" then
        LCG.ProcGlow_Start(button, {
            color = GLOW_COLOR, key = GLOW_KEY_BUFF, frameLevel = 1,
            startAnim = true, duration = 1,
        })
    elseif cfg.style == "BUTTON" then
        LCG.ButtonGlow_Start(button, GLOW_COLOR, cfg.frequency, 1)
    end

    button._cdf_buffGlowType = cfg.style
    button._cdf_buffGlowActive = true
end

function Style:StopBuffGlow(button)
    if not LCG or not button._cdf_buffGlowType then return end

    if button._cdf_buffGlowType == "PIXEL" then
        LCG.PixelGlow_Stop(button, GLOW_KEY_BUFF)
    elseif button._cdf_buffGlowType == "AUTOCAST" then
        LCG.AutoCastGlow_Stop(button, GLOW_KEY_BUFF)
    elseif button._cdf_buffGlowType == "PROC" then
        LCG.ProcGlow_Stop(button, GLOW_KEY_BUFF)
    elseif button._cdf_buffGlowType == "BUTTON" then
        LCG.ButtonGlow_Stop(button)
    end

    button._cdf_buffGlowType = nil
    button._cdf_buffGlowActive = nil
end

function Style:HideBuffGlow(button)
    if not button then return end
    activeBuffGlowFrames[button] = nil
    self:StopBuffGlow(button)
end

function Style:RefreshAllBuffGlows()
    local frames = {}
    for frame in pairs(activeBuffGlowFrames) do
        frames[#frames + 1] = frame
    end
    for _, frame in ipairs(frames) do
        self:StopBuffGlow(frame)
        self:ShowBuffGlow(frame)
    end
end

------------------------------------------------------
-- 技能可用高亮（冷却完毕时高亮）
------------------------------------------------------

local GLOW_KEY_AVAIL = "CDFlowAvail"
local activeAvailGlowFrames = {}

-- Arc Detector：将 DurationObject 的剩余时间（secret 值）喂给隐藏 StatusBar 的
-- SetValue()，由 C++ 引擎内部完成比较，再通过 GetStatusBarTexture():IsShown()
-- 读回非 secret bool。不使用 CooldownFrameTemplate，避免 swipe/bling 动画渲染。
local _arcDetector

local function IsSpellAvailable(spellID)
    -- GCD 期间仍视为可用：通过 C_Spell.GetSpellCooldown 的 isOnGCD 字段判断
    local isOnGCD = false
    pcall(function()
        local cdInfo = C_Spell.GetSpellCooldown(spellID)
        if cdInfo and cdInfo.isOnGCD == true then isOnGCD = true end
    end)
    if isOnGCD then return true end

    local durObj = C_Spell.GetSpellCooldownDuration(spellID)
    if not durObj then return true end

    local ok, remaining = pcall(function() return durObj:GetRemainingDuration() end)
    if not ok then return true end
    if remaining == nil then return true end

    if not _arcDetector then
        _arcDetector = CreateFrame("StatusBar", nil, UIParent)
        _arcDetector:SetSize(200, 20)
        _arcDetector:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -5000, 0)
        _arcDetector:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        -- max=1：任何正值都让贴图显示；0 让贴图隐藏
        _arcDetector:SetMinMaxValues(0, 1)
        _arcDetector:Show()
    end

    _arcDetector:SetValue(remaining)
    local tex = _arcDetector:GetStatusBarTexture()
    -- 贴图显示 → remaining > 0 → 还在 CD 中
    -- 贴图不显示 → remaining == 0 → 技能可用
    return not (tex and tex:IsShown())
end

function Style:ShowAvailGlow(button)
    local cfg = ns.db and ns.db.spellHighlight
    if not cfg or not cfg.enabled or not button then return end

    activeAvailGlowFrames[button] = true

    if cfg.style == "NONE" then
        self:StopAvailGlow(button)
        return
    end

    if cfg.style == "DEFAULT" then
        self:StopAvailGlow(button)
        return
    end

    if not LCG then
        LCG = LibStub("LibCustomGlow-1.0", true)
        if not LCG then return end
    end

    if button._cdf_availGlowType and button._cdf_availGlowType ~= cfg.style then
        self:StopAvailGlow(button)
    end

    if cfg.style == "PIXEL" then
        LCG.PixelGlow_Start(button, GLOW_COLOR, cfg.lines, cfg.frequency,
            nil, cfg.thickness, 0, 0, false, GLOW_KEY_AVAIL, 1)
    elseif cfg.style == "AUTOCAST" then
        LCG.AutoCastGlow_Start(button, GLOW_COLOR, nil, cfg.frequency,
            cfg.scale, 0, 0, GLOW_KEY_AVAIL, 1)
    elseif cfg.style == "PROC" then
        LCG.ProcGlow_Start(button, {
            color = GLOW_COLOR, key = GLOW_KEY_AVAIL, frameLevel = 1,
            startAnim = true, duration = 1,
        })
    elseif cfg.style == "BUTTON" then
        LCG.ButtonGlow_Start(button, GLOW_COLOR, cfg.frequency, 1)
    end

    button._cdf_availGlowType   = cfg.style
    button._cdf_availGlowActive = true
end

function Style:StopAvailGlow(button)
    if not LCG or not button._cdf_availGlowType then return end

    if button._cdf_availGlowType == "PIXEL" then
        LCG.PixelGlow_Stop(button, GLOW_KEY_AVAIL)
    elseif button._cdf_availGlowType == "AUTOCAST" then
        LCG.AutoCastGlow_Stop(button, GLOW_KEY_AVAIL)
    elseif button._cdf_availGlowType == "PROC" then
        LCG.ProcGlow_Stop(button, GLOW_KEY_AVAIL)
    elseif button._cdf_availGlowType == "BUTTON" then
        LCG.ButtonGlow_Stop(button)
    end

    button._cdf_availGlowType   = nil
    button._cdf_availGlowActive = nil
end

function Style:HideAvailGlow(button)
    if not button then return end
    activeAvailGlowFrames[button] = nil
    self:StopAvailGlow(button)
end

function Style:RefreshAvailHighlights(allIcons)
    local cfg = ns.db and ns.db.spellHighlight
    if not cfg or not cfg.enabled or not next(cfg.spellFilter) then
        -- 功能关闭或列表为空时，清除所有可用高亮
        for _, icon in ipairs(allIcons) do
            if icon._cdf_availGlowActive then
                self:HideAvailGlow(icon)
            end
        end
        return
    end

    if cfg.combatOnly and not InCombatLockdown() then
        for _, icon in ipairs(allIcons) do
            if icon._cdf_availGlowActive then
                self:HideAvailGlow(icon)
            end
        end
        return
    end

    for _, icon in ipairs(allIcons) do
        local spellID = Style.GetSpellIDFromIcon(icon)
        if spellID and cfg.spellFilter[spellID] then
            local available = IsSpellAvailable(spellID)
            local hasGlow   = icon._cdf_availGlowActive
            local styleMatch = hasGlow and icon._cdf_availGlowType == cfg.style

            if not available then
                if hasGlow then self:HideAvailGlow(icon) end
            elseif not hasGlow or not styleMatch then
                if hasGlow then self:StopAvailGlow(icon) end
                self:ShowAvailGlow(icon)
            end
        else
            if icon._cdf_availGlowActive then
                self:HideAvailGlow(icon)
            end
        end
    end
end
