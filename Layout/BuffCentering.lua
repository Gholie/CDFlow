local _, ns = ...

------------------------------------------------------
-- Buff 居中系统
--
-- OnUpdate 驱动，持续监控 buff 可见性变化并自动居中。
-- burst 阶段 33ms 快速轮询，稳定后 250ms 看门狗，空闲 2 秒后关闭。
-- 图标始终保持为 viewer 子帧，仅通过 SetPoint 重定位。
------------------------------------------------------

local Layout = ns.Layout
local Style  = ns.Style
local floor  = math.floor

local BURST_THROTTLE      = 0.033
local WATCHDOG_THROTTLE   = 0.25
local BURST_TICKS         = 5
local IDLE_DISABLE_SEC    = 2.0
local PROVISIONAL_WINDOW  = 0.25

local centeringFrame        = CreateFrame("Frame")
local centeringEnabled      = false
local centeringDirty        = true
local burstTicksRemaining   = 0
local lastActivityTime      = 0
local nextUpdateTime        = 0

local lastVisibleSet        = {}
local lastVisibleCount      = 0
local lastLayoutIndex       = setmetatable({}, { __mode = "k" })
local lastSlotMap           = setmetatable({}, { __mode = "k" })

------------------------------------------------------
-- 偏移计算（保留原有公开接口，供其他模块使用）
------------------------------------------------------
function Layout.CenteredRowXOffsets(count, itemWidth, padding, dir, totalSlots)
    if not count or count <= 0 then return {} end
    dir = dir or 1
    local iconsMissing = (totalSlots or count) - count
    local startX = ((itemWidth + padding) * iconsMissing / 2) * dir
    local offsets = {}
    for i = 1, count do
        offsets[i] = startX + (i - 1) * (itemWidth + padding) * dir
    end
    return offsets
end

function Layout.CenteredColYOffsets(count, itemHeight, padding, dir, totalSlots)
    if not count or count <= 0 then return {} end
    dir = dir or 1
    local iconsMissing = (totalSlots or count) - count
    local startY = -((itemHeight + padding) * iconsMissing / 2) * dir
    local offsets = {}
    for i = 1, count do
        offsets[i] = startY - (i - 1) * (itemHeight + padding) * dir
    end
    return offsets
end

------------------------------------------------------
-- 可见集合变化检测
------------------------------------------------------
local function HasVisibleSetChanged(currentList)
    local count = #currentList
    if count ~= lastVisibleCount then return true end
    for i = 1, count do
        if not lastVisibleSet[currentList[i]] then return true end
    end
    return false
end

local function HasLayoutStateChanged(currentList)
    for i = 1, #currentList do
        local icon = currentList[i]
        local li = icon.layoutIndex or 0
        if lastLayoutIndex[icon] ~= li then return true end
        local sl = icon._cdf_slot or 0
        if lastSlotMap[icon] ~= sl then return true end
    end
    return false
end

local function CacheVisibleState(currentList)
    wipe(lastVisibleSet)
    wipe(lastLayoutIndex)
    wipe(lastSlotMap)
    lastVisibleCount = #currentList
    for i = 1, lastVisibleCount do
        local icon = currentList[i]
        lastVisibleSet[icon] = true
        lastLayoutIndex[icon] = icon.layoutIndex or 0
        lastSlotMap[icon] = icon._cdf_slot or 0
    end
end

------------------------------------------------------
-- 收集当前可见的主组 buff 帧
------------------------------------------------------
local function CollectVisibleMainBuffs(viewer)
    local result = {}
    if not viewer or not viewer.itemFramePool then return result end

    local suppressed = ns.cdmSuppressedCooldownIDs
    local hasGroups = Layout.GetGroupIdxForIcon ~= nil
        and ns.db and ns.db.buffGroups and #ns.db.buffGroups > 0

    for frame in viewer.itemFramePool:EnumerateActive() do
        if frame and frame:IsShown() then
            local iconTex = frame.Icon and frame.Icon:GetTexture()
            if iconTex then
                local isSuppressed = suppressed and suppressed[frame.cooldownID]
                local isGrouped = hasGroups and Layout.GetGroupIdxForIcon
                    and Layout:GetGroupIdxForIcon(frame)
                if not isSuppressed and not isGrouped then
                    result[#result + 1] = frame
                end
            end
        end
    end

    table.sort(result, function(a, b)
        return (a.layoutIndex or 0) < (b.layoutIndex or 0)
    end)
    return result
end

------------------------------------------------------
-- 排除帧辅助
------------------------------------------------------
local function HideExcludedFrame(frame)
    frame._cdf_positioned = nil
    frame:SetAlpha(0)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
end

local function IsFrameExcluded(frame)
    local suppressed = ns.cdmSuppressedCooldownIDs
    if suppressed and suppressed[frame.cooldownID] then
        return "suppressed"
    end
    local hasGroups = Layout.GetGroupIdxForIcon ~= nil
        and ns.db and ns.db.buffGroups and #ns.db.buffGroups > 0
    if hasGroups then
        local gIdx = Layout:GetGroupIdxForIcon(frame)
        if gIdx then
            return "grouped", gIdx
        end
    end
    return nil
end

------------------------------------------------------
-- 排除帧处理：suppressed 隐藏 + grouped 收集并定位到分组容器
-- 替代原安全网，在一次 pool 遍历中完成两种逻辑
------------------------------------------------------
local function ProcessExcludedFrames(viewer, visibleLookup, w, h, cfg)
    if not viewer or not viewer.itemFramePool then return false end
    local groupBuckets = {}
    local hasGrouped = false
    for frame in viewer.itemFramePool:EnumerateActive() do
        if frame and not visibleLookup[frame] and frame:IsShown() then
            local iconTex = frame.Icon and frame.Icon:GetTexture()
            if iconTex then
                local excludeType, gIdx = IsFrameExcluded(frame)
                if excludeType == "suppressed" then
                    if frame:GetAlpha() > 0 and frame._cdf_positioned then
                        HideExcludedFrame(frame)
                    end
                elseif excludeType == "grouped" and gIdx then
                    groupBuckets[gIdx] = groupBuckets[gIdx] or {}
                    groupBuckets[gIdx][#groupBuckets[gIdx] + 1] = frame
                    hasGrouped = true
                    if frame:GetAlpha() < 1 then frame:SetAlpha(1) end
                    frame._cdf_positioned = true
                end
            end
        end
    end
    if hasGrouped then
        Layout:RefreshBuffGroups(groupBuckets, w, h, cfg)
    end
    return hasGrouped
end

------------------------------------------------------
-- 快速居中定位（OnUpdate 回调核心）
------------------------------------------------------
local function CenterBuffsImmediate()
    local now = GetTime()
    local throttle = (centeringDirty or burstTicksRemaining > 0)
        and BURST_THROTTLE or WATCHDOG_THROTTLE
    if now < nextUpdateTime then return end
    nextUpdateTime = now + throttle

    local viewer = _G.BuffIconCooldownViewer
    if not viewer or not viewer:IsShown() then return end

    local cfg = ns.db and ns.db.buffs
    if not cfg then return end
    local doCenter = (cfg.growDir == "CENTER")
    local w, h = cfg.iconWidth, cfg.iconHeight

    local visible = CollectVisibleMainBuffs(viewer)
    if #visible == 0 then
        if lastVisibleCount > 0 then
            CacheVisibleState(visible)
        end
        ProcessExcludedFrames(viewer, {}, w, h, cfg)
        if burstTicksRemaining > 0 then
            burstTicksRemaining = burstTicksRemaining - 1
        elseif (now - lastActivityTime) >= IDLE_DISABLE_SEC then
            Layout.DisableBuffCentering()
        end
        return
    end

    local changed = centeringDirty
        or HasVisibleSetChanged(visible)
        or HasLayoutStateChanged(visible)

    if not changed then
        if burstTicksRemaining > 0 then
            burstTicksRemaining = burstTicksRemaining - 1
        elseif (now - lastActivityTime) >= IDLE_DISABLE_SEC then
            Layout.DisableBuffCentering()
        end
        return
    end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local iconLimit = viewer.iconLimit or 20

    if doCenter then
        for i, icon in ipairs(visible) do
            icon._cdf_slot = i - 1
        end
        if isH then
            Layout:LayoutBuffCenterH(viewer, visible, iconLimit, w, h, cfg, iconDir)
        else
            Layout:LayoutBuffCenterV(viewer, visible, iconLimit, w, h, cfg, iconDir)
        end
    else
        local totalSlots = viewer._cdf_mainSlotCount or #visible
        if isH then
            Layout:LayoutBuffDefaultH(viewer, visible, totalSlots, w, h, cfg, iconDir)
        else
            Layout:LayoutBuffDefaultV(viewer, visible, totalSlots, w, h, cfg, iconDir)
        end
    end

    local visibleLookup = {}
    for _, icon in ipairs(visible) do
        if icon:GetAlpha() < 1 then
            icon:SetAlpha(1)
        end
        icon._cdf_positioned = true
        visibleLookup[icon] = true
    end

    ProcessExcludedFrames(viewer, visibleLookup, w, h, cfg)

    CacheVisibleState(visible)
    centeringDirty = false
    burstTicksRemaining = BURST_TICKS
    lastActivityTime = now
end

------------------------------------------------------
-- Enable / Disable / MarkDirty
------------------------------------------------------
function Layout.MarkBuffCenteringDirty()
    centeringDirty = true
    burstTicksRemaining = BURST_TICKS
    lastActivityTime = GetTime()
    nextUpdateTime = 0
end

function Layout.EnableBuffCentering()
    Layout.MarkBuffCenteringDirty()
    if not centeringEnabled then
        centeringFrame:SetScript("OnUpdate", CenterBuffsImmediate)
        centeringEnabled = true
    end
end

function Layout.DisableBuffCentering()
    if centeringEnabled then
        centeringFrame:SetScript("OnUpdate", nil)
        centeringEnabled = false
    end
    centeringDirty = true
    burstTicksRemaining = 0
    lastActivityTime = 0
    nextUpdateTime = 0
    lastVisibleCount = 0
    wipe(lastVisibleSet)
    wipe(lastLayoutIndex)
    wipe(lastSlotMap)
end

------------------------------------------------------
-- 临时放置：在 mixin hook 中立即计算近似位置
-- 避免帧在等待完整刷新期间不可见
------------------------------------------------------
function Layout.ProvisionalPlaceBuffFrame(frame)
    if not frame then return end
    local viewer = _G.BuffIconCooldownViewer
    if not viewer then return end

    local cfg = ns.db and ns.db.buffs
    if not cfg then return end

    frame._cdf_provisionalUntil = GetTime() + PROVISIONAL_WINDOW

    local excludeType, groupIdx = IsFrameExcluded(frame)
    if excludeType == "suppressed" then
        HideExcludedFrame(frame)
        Layout.EnableBuffCentering()
        return
    end
    if excludeType == "grouped" then
        local container = Layout.buffGroupContainers and Layout.buffGroupContainers[groupIdx]
        if container then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", container, "CENTER", 0, 0)
            frame:SetAlpha(1)
            frame._cdf_positioned = true
        else
            HideExcludedFrame(frame)
        end
        Layout.EnableBuffCentering()
        return
    end

    local doCenter = (cfg.growDir == "CENTER")
    if not doCenter then
        frame:SetAlpha(1)
        frame._cdf_positioned = true
        Layout.EnableBuffCentering()
        return
    end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local iconLimit = viewer.iconLimit or 20
    local w, h = cfg.iconWidth, cfg.iconHeight
    local ox = viewer._cdf_userOffX or (cfg.buffOffsetX or 0)
    local oy = viewer._cdf_userOffY or (cfg.buffOffsetY or 0)

    local visible = CollectVisibleMainBuffs(viewer)
    local alreadyInList = false
    for _, v in ipairs(visible) do
        if v == frame then alreadyInList = true; break end
    end
    if not alreadyInList then
        visible[#visible + 1] = frame
        table.sort(visible, function(a, b)
            return (a.layoutIndex or 0) < (b.layoutIndex or 0)
        end)
    end

    local count = #visible
    if count == 0 then return end

    local frameIdx
    for i, v in ipairs(visible) do
        if v == frame then frameIdx = i; break end
    end
    if not frameIdx then return end

    if isH then
        local step = w + (cfg.spacingX or 2)
        local offset = (iconLimit - count) / 2
        local slot = offset + (frameIdx - 1)
        local x = (2 * slot - iconLimit + 1) * step / 2 * iconDir
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", viewer, "CENTER", x + ox, oy)
    else
        local step = h + (cfg.spacingY or 2)
        local offset = (iconLimit - count) / 2
        local slot = offset + (frameIdx - 1)
        local y = (2 * slot - iconLimit + 1) * step / 2 * iconDir
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", viewer, "CENTER", ox, y + oy)
    end

    frame:SetAlpha(1)
    frame._cdf_positioned = true
    Layout.EnableBuffCentering()
end

------------------------------------------------------
-- 帧就绪重试：帧未准备好时短延迟后重新触发居中
------------------------------------------------------
local retryCount = 0
local MAX_RETRIES = 3
local RETRY_DELAY = 0.01

function Layout.ScheduleBuffReadinessRetry()
    if retryCount >= MAX_RETRIES then
        retryCount = 0
        return
    end
    retryCount = retryCount + 1
    C_Timer.After(RETRY_DELAY, function()
        Layout.EnableBuffCentering()
    end)
end

function Layout.ResetBuffReadinessRetry()
    retryCount = 0
end
