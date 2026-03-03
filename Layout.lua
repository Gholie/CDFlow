local _, ns = ...

------------------------------------------------------
-- 布局模块
--
-- 技能查看器（Essential/Utility）：多行布局 + 行内始终水平居中
-- growDir:
--   "TOP"    → 从顶部向下增长（默认）
--   "BOTTOM" → 从底部向上增长
--
-- 增益查看器（Buffs）：单行/列 + 固定槽位或动态居中
-- growDir:
--   "CENTER"  → 从中间增长（动态居中）
--   "DEFAULT" → 固定位置（系统默认）
------------------------------------------------------

local Layout = {}
ns.Layout = Layout

local Style = ns.Style
local floor = math.floor
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local VIEWER_KEY = {
    EssentialCooldownViewer = "essential",
    UtilityCooldownViewer   = "utility",
    BuffIconCooldownViewer  = "buffs",
}

------------------------------------------------------
-- 工具函数
------------------------------------------------------

local function IsReady(viewer)
    if not viewer or not viewer.IsInitialized then return false end
    if not EditModeManagerFrame then return false end
    if EditModeManagerFrame.layoutApplyInProgress then return false end
    return viewer:IsInitialized()
end

-- 收集所有图标帧（含隐藏），按 layoutIndex 排序。
-- 使用 GetChildren() 收集（图标始终为 viewer 子帧，不 re-parent）。
-- itemFramePool 作为 fallback（兼容自定义分组 re-parent 到 group container 的帧）。
local function CollectAllIcons(viewer)
    local all  = {}
    local seen = {}

    for _, child in ipairs({ viewer:GetChildren() }) do
        if child and child.Icon then
            seen[child] = true
            all[#all + 1] = child
        end
    end

    -- fallback：itemFramePool 补充已被分组 re-parent 的帧
    if viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame and frame.Icon and not seen[frame] then
                all[#all + 1] = frame
            end
        end
    end

    table.sort(all, function(a, b)
        return (a.layoutIndex or 0) < (b.layoutIndex or 0)
    end)
    return all
end

-- 从全量列表中筛选可见图标，同时记录每个图标的固定槽位索引
-- 跳过被监控条隐藏（hideFromCDM）的图标：alpha 置 0、移出布局区
-- 有 suppressed 时使用紧凑槽位，避免占据空位
local function SplitVisible(allIcons)
    local visible = {}
    local slotOf = {}
    local suppressed = ns.cdmSuppressedCooldownIDs
    local hasSuppressed = false
    for slot, icon in ipairs(allIcons) do
        if icon:IsShown() then
            local iconTex = icon.Icon and icon.Icon:GetTexture()
            if iconTex == nil then
                icon:SetAlpha(0)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
            elseif suppressed and suppressed[icon.cooldownID] then
                hasSuppressed = true
                icon:SetAlpha(0)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
            else
                icon:SetAlpha(1)
                visible[#visible + 1] = icon
                slotOf[icon] = slot - 1   -- 0-based 槽位
            end
        end
    end
    if hasSuppressed then
        for i, icon in ipairs(visible) do
            slotOf[icon] = i - 1
        end
    end
    return visible, slotOf
end

-- 按每行上限分组
local function BuildRows(limit, children)
    local rows = {}
    if limit <= 0 then
        rows[1] = children
        return rows
    end
    for i = 1, #children do
        local ri = floor((i - 1) / limit) + 1
        rows[ri] = rows[ri] or {}
        rows[ri][#rows[ri] + 1] = children[i]
    end
    return rows
end

local function SetPointCached(icon, anchor, viewer, x, y)
    local num = icon:GetNumPoints()
    if num == 1 then
        local p, relTo, relPoint, curX, curY = icon:GetPoint(1)
        if p == anchor and relTo == viewer and relPoint == anchor
            and curX == x and curY == y then
            return
        end
    end
    icon:ClearAllPoints()
    icon:SetPoint(anchor, viewer, anchor, x, y)
end
-- 供 Layout/TrackedBars.lua 使用
Layout._SetPointCached = SetPointCached

local function EnsureSingleLineStableFrameSize(viewer, cfg, isH, baseW, baseH)
    if not (viewer and cfg and baseW and baseH) then return end
    local reserveSlots = viewer.iconLimit or 20
    if reserveSlots < 1 then reserveSlots = 20 end

    local targetW, targetH
    if isH then
        targetW = reserveSlots * (baseW + cfg.spacingX) - cfg.spacingX
        targetH = baseH
    else
        targetW = baseW
        targetH = reserveSlots * (baseH + cfg.spacingY) - cfg.spacingY
    end

    targetW = math.max(targetW, baseW)
    targetH = math.max(targetH, baseH)

    local curW, curH = viewer:GetWidth(), viewer:GetHeight()
    if not curW or not curH or math.abs(curW - targetW) >= 1 or math.abs(curH - targetH) >= 1 then
        viewer:SetSize(targetW, targetH)
    end
end

------------------------------------------------------
-- 同步 viewer 尺寸与实际图标边界框
-- 使编辑模式的圈选区域与实际显示区域一致
------------------------------------------------------
local function UpdateViewerSizeToMatchIcons(viewer, icons)
    if not viewer or not icons or #icons == 0 then return end
    local vScale = viewer:GetEffectiveScale()
    if not vScale or vScale == 0 then return end

    local left, right, top, bottom = 999999, 0, 0, 999999
    for _, icon in ipairs(icons) do
        if icon and icon:IsShown() then
            local scale = icon:GetEffectiveScale() / vScale
            local l = (icon:GetLeft() or 0) * scale
            local r = (icon:GetRight() or 0) * scale
            local t = (icon:GetTop() or 0) * scale
            local b = (icon:GetBottom() or 0) * scale
            if l < left then left = l end
            if r > right then right = r end
            if t > top then top = t end
            if b < bottom then bottom = b end
        end
    end

    if left >= right or bottom >= top then return end

    -- 已转换为 viewer 本地单位，直接使用
    local targetW = right - left
    local targetH = top - bottom
    local curW = viewer:GetWidth()
    local curH = viewer:GetHeight()
    if curW and curH and (math.abs(curW - targetW) >= 1 or math.abs(curH - targetH) >= 1) then
        -- 延迟执行 SetSize 以避免在受保护的调用链中触发 ADDON_ACTION_BLOCKED 错误
        -- 这个错误可能发生在某些事件（如 SPELLS_CHANGED）触发 RefreshLayout 时
        C_Timer.After(0, function()
            if viewer and viewer.SetSize then
                viewer:SetSize(targetW, targetH)
            end
        end)
    end
end

------------------------------------------------------
-- 入口：根据查看器类型分发
------------------------------------------------------
function Layout:RefreshViewer(viewerName)
    local viewer = _G[viewerName]
    if not viewer or not IsReady(viewer) then return end

    local cfgKey = VIEWER_KEY[viewerName]
    if not cfgKey then return end
    local cfg = ns.db[cfgKey]
    if not cfg then return end
    viewer._cdf_disabledApplied = nil

    if viewerName == "BuffIconCooldownViewer" then
        self:RefreshBuffViewer(viewer, cfg)
        if self.RefreshTrackedBars then self:RefreshTrackedBars() end
    else
        self:RefreshCDViewer(viewer, cfg)
    end
end

------------------------------------------------------
-- 增益图标查看器
-- DEFAULT = 固定槽位（紧凑排列，排除 suppressed/grouped 后重编号）
-- CENTER  = 动态居中（图标保持为 viewer 子帧）
------------------------------------------------------
function Layout:RefreshBuffViewer(viewer, cfg)
    -- 防重入：SetSize → RefreshLayout → RefreshViewer 循环
    if viewer._cdf_buffRefreshing then return end
    viewer._cdf_buffRefreshing = true

    local db = ns.db
    local w, h = cfg.iconWidth, cfg.iconHeight

    if ns.Visibility and ns.Visibility.IsViewerVisible
        and not ns.Visibility:IsViewerVisible(viewer) then
        viewer._cdf_buffRefreshing = false
        return
    end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local doCenter = (cfg.growDir == "CENTER")
    local iconLimit = viewer.iconLimit or 20

    -- 固定 viewer 尺寸：至少 400px，确保编辑模式预览区域足够大
    local BUFF_VIEWER_MIN_SIZE = 400
    if isH then
        local blockW = iconLimit * (w + cfg.spacingX) - cfg.spacingX
        local targetW = math.max(BUFF_VIEWER_MIN_SIZE, blockW)
        local curW = viewer:GetWidth()
        if not curW or math.abs(curW - targetW) >= 1 then
            viewer:SetSize(targetW, h)
        end
    else
        local blockH = iconLimit * (h + cfg.spacingY) - cfg.spacingY
        local targetH = math.max(BUFF_VIEWER_MIN_SIZE, blockH)
        local curH = viewer:GetHeight()
        if not curH or math.abs(curH - targetH) >= 1 then
            viewer:SetSize(w, targetH)
        end
    end

    -- 用户 X/Y 偏移（替代编辑模式拖拽）
    local userOffX = cfg.buffOffsetX or 0
    local userOffY = cfg.buffOffsetY or 0
    viewer._cdf_userOffX = userOffX
    viewer._cdf_userOffY = userOffY

    local allIcons = CollectAllIcons(viewer)

    -- 统一分类：suppressed / grouped / main（含 hidden）
    local suppressed = ns.cdmSuppressedCooldownIDs
    local hasGroups = self.GetGroupIdxForIcon ~= nil
        and ns.db and ns.db.buffGroups and #ns.db.buffGroups > 0

    local mainAll     = {}   -- 主组全部帧（含 hidden）
    local mainVisible = {}   -- 主组可见帧
    local groupBuckets = {}  -- {[groupIdx] = {icons}}
    local visibleSet   = {}  -- 所有可见帧（含分组），用于高亮判断
    local hasNilTex    = false -- 有帧显示但贴图未加载，需要延迟重试

    for idx, icon in ipairs(allIcons) do
        icon._cdf_buffViewer = true
        local iconTex = icon.Icon and icon.Icon:GetTexture()
        local isShown = icon:IsShown()

        -- suppressed: 无论是否显示都排除（不计入任何组，不影响 mainAll 槽位计数）
        if suppressed and suppressed[icon.cooldownID] then
            icon._cdf_positioned = nil
            if isShown then
                icon:SetAlpha(0)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
            end
        -- 分组: 无论是否显示都归入分组（不计入主组）
        elseif hasGroups and self:GetGroupIdxForIcon(icon) then
            local gIdx = self:GetGroupIdxForIcon(icon)
            if icon:GetParent() ~= viewer then
                icon:SetParent(viewer)
            end
            if isShown and iconTex then
                icon:SetAlpha(1)
                icon._cdf_positioned = true
                groupBuckets[gIdx] = groupBuckets[gIdx] or {}
                groupBuckets[gIdx][#groupBuckets[gIdx] + 1] = icon
                visibleSet[icon] = true
            elseif isShown then
                hasNilTex = true
                icon._cdf_positioned = nil
                icon:SetAlpha(0)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
            end
        else
            if icon:GetParent() ~= viewer then
                icon:SetParent(viewer)
            end
            mainAll[#mainAll + 1] = icon
            icon._cdf_slot = #mainAll - 1

            if isShown and iconTex == nil then
                hasNilTex = true
                icon._cdf_positioned = nil
                icon:SetAlpha(0)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
            elseif isShown and iconTex ~= nil then
                icon:SetAlpha(1)
                icon._cdf_positioned = true
                mainVisible[#mainVisible + 1] = icon
                visibleSet[icon] = true
            end
        end
    end

    viewer._cdf_mainSlotCount = #mainAll

    -- 有帧已显示但贴图尚未加载（reload 后首次出现），递减延迟重试
    if hasNilTex then
        viewer._cdf_nilTexRetry = (viewer._cdf_nilTexRetry or 0) + 1
        if viewer._cdf_nilTexRetry <= 5 and Layout.RequestBuffRefreshFromMB then
            C_Timer.After(0.05 * viewer._cdf_nilTexRetry, Layout.RequestBuffRefreshFromMB)
        end
    else
        viewer._cdf_nilTexRetry = 0
    end

    -- 帧就绪重试：有显示帧但数据未就绪时，短延迟后重新触发居中
    local hasNotReady = false
    for _, icon in ipairs(allIcons) do
        if icon:IsShown() and not (icon.Icon and icon.Icon:GetTexture()) then
            hasNotReady = true
            break
        end
        if icon._cdf_provisionalUntil and icon._cdf_provisionalUntil > GetTime()
            and not icon:IsShown() then
            hasNotReady = true
            break
        end
    end
    if hasNotReady then
        Layout.ScheduleBuffReadinessRetry()
    else
        Layout.ResetBuffReadinessRetry()
    end

    -- 无可见 buff 时清理高亮
    if #mainVisible == 0 and not next(groupBuckets) then
        for _, icon in ipairs(allIcons) do
            if icon._cdf_buffGlowActive then
                Style:HideBuffGlow(icon)
            end
        end
        viewer._cdf_buffRefreshing = false
        return
    end

    local buffGlowCfg = db.buffGlow

    -- 增益高亮：仅在状态变化时更新，避免频繁 Stop/Start 导致闪烁
    if buffGlowCfg then
        local hasFilter = buffGlowCfg.spellFilter and next(buffGlowCfg.spellFilter)
        for _, icon in ipairs(allIcons) do
            local shouldGlow = visibleSet[icon] and buffGlowCfg.enabled
            if shouldGlow and hasFilter then
                local spellID = Style.GetSpellIDFromIcon(icon)
                shouldGlow = spellID and buffGlowCfg.spellFilter[spellID] or false
            end
            local hasGlow = icon._cdf_buffGlowActive
            local styleMatch = hasGlow and icon._cdf_buffGlowType == buffGlowCfg.style

            if not shouldGlow then
                if hasGlow then Style:HideBuffGlow(icon) end
            elseif not hasGlow or not styleMatch then
                if hasGlow then Style:StopBuffGlow(icon) end
                Style:ShowBuffGlow(icon)
            end
        end
    end

    -- 技能可用高亮
    Style:RefreshAvailHighlights(allIcons)

    -- 应用样式（主组 + 分组所有可见图标）
    for icon in pairs(visibleSet) do
        icon._cdf_viewerKey = "buffs"
        Style:ApplyIcon(icon, w, h, db.iconZoom, db.borderSize)
        Style:ApplyStack(icon, cfg.stack)
        Style:ApplyKeybind(icon, cfg)
        Style:ApplyCooldownText(icon, cfg)
        Style:ApplySwipeOverlay(icon)
    end

    -- 主组定位（同步，不 re-parent，不 OnUpdate）
    local mainCount = #mainAll
    if #mainVisible > 0 then
        if doCenter then
            -- CENTER: 在 iconLimit 槽位内动态居中（与 viewer 物理宽度匹配）
            if isH then
                self:LayoutBuffCenterH(viewer, mainVisible, iconLimit, w, h, cfg, iconDir)
            else
                self:LayoutBuffCenterV(viewer, mainVisible, iconLimit, w, h, cfg, iconDir)
            end
        else
            -- DEFAULT: 在 mainAll 槽位内固定定位（排除 suppressed/grouped）
            if isH then
                self:LayoutBuffDefaultH(viewer, mainVisible, mainCount, w, h, cfg, iconDir)
            else
                self:LayoutBuffDefaultV(viewer, mainVisible, mainCount, w, h, cfg, iconDir)
            end
        end
    end
    -- 自定义分组定位（无论哪种模式，分组总是独立定位）
    if hasGroups and next(groupBuckets) then
        self:RefreshBuffGroups(groupBuckets, w, h, cfg)
    end

    -- 启动 OnUpdate 居中监控，持续检测 buff 可见性变化并自动修正位置
    if #mainVisible > 0 or next(groupBuckets) then
        Layout.EnableBuffCentering()
    end

    viewer._cdf_buffRefreshing = false
end

------------------------------------------------------
-- Buff 水平居中布局（CENTER 模式）
-- 以 viewer CENTER 为锚点，可见图标在 iconLimit 槽位内动态居中
------------------------------------------------------
function Layout:LayoutBuffCenterH(viewer, visible, totalSlots, w, h, cfg, iconDir)
    local count = #visible
    local step = w + (cfg.spacingX or 2)
    local offset = (totalSlots - count) / 2
    local ox = viewer._cdf_userOffX or 0
    local oy = viewer._cdf_userOffY or 0
    for i, icon in ipairs(visible) do
        local slot = offset + (i - 1)
        local x = (2 * slot - totalSlots + 1) * step / 2 * iconDir
        SetPointCached(icon, "CENTER", viewer, x + ox, oy)
    end
end

------------------------------------------------------
-- Buff 垂直居中布局（CENTER 模式）
------------------------------------------------------
function Layout:LayoutBuffCenterV(viewer, visible, totalSlots, w, h, cfg, iconDir)
    local count = #visible
    local step = h + (cfg.spacingY or 2)
    local offset = (totalSlots - count) / 2
    local ox = viewer._cdf_userOffX or 0
    local oy = viewer._cdf_userOffY or 0
    for i, icon in ipairs(visible) do
        local slot = offset + (i - 1)
        local y = (2 * slot - totalSlots + 1) * step / 2 * iconDir
        SetPointCached(icon, "CENTER", viewer, ox, y + oy)
    end
end

------------------------------------------------------
-- Buff 水平固定布局（DEFAULT 模式：固定槽位，以 viewer CENTER 居中）
-- 每个 buff 保持在系统分配的位置，buff 消失后槽位空出不自动补位
------------------------------------------------------
function Layout:LayoutBuffDefaultH(viewer, visible, totalSlots, w, h, cfg, iconDir)
    local step = w + (cfg.spacingX or 2)
    local ox = viewer._cdf_userOffX or 0
    local oy = viewer._cdf_userOffY or 0
    for _, icon in ipairs(visible) do
        local slot = icon._cdf_slot or 0
        local x = (2 * slot - totalSlots + 1) * step / 2 * iconDir
        SetPointCached(icon, "CENTER", viewer, x + ox, oy)
    end
end

------------------------------------------------------
-- Buff 垂直固定布局（DEFAULT 模式：固定槽位，以 viewer CENTER 居中）
------------------------------------------------------
function Layout:LayoutBuffDefaultV(viewer, visible, totalSlots, w, h, cfg, iconDir)
    local step = h + (cfg.spacingY or 2)
    local ox = viewer._cdf_userOffX or 0
    local oy = viewer._cdf_userOffY or 0
    for _, icon in ipairs(visible) do
        local slot = icon._cdf_slot or 0
        local y = (2 * slot - totalSlots + 1) * step / 2 * iconDir
        SetPointCached(icon, "CENTER", viewer, ox, y + oy)
    end
end

------------------------------------------------------
-- 技能查看器（Essential / Utility）
-- 多行布局 + 行尺寸覆盖 + 行内始终水平居中
-- growDir:
--   "TOP"    → 从顶部向下增长（anchor = TOPLEFT/TOPRIGHT）
--   "BOTTOM" → 从底部向上增长（anchor = BOTTOMLEFT/BOTTOMRIGHT）
------------------------------------------------------
function Layout:RefreshCDViewer(viewer, cfg)
    local allIcons = CollectAllIcons(viewer)
    local visible, _ = SplitVisible(allIcons)

    local db = ns.db
    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1

    local singleLineAdaptive = (cfg.iconsPerRow ~= nil and cfg.iconsPerRow <= 0)
    local limit = cfg.iconsPerRow
    if singleLineAdaptive then
        limit = #visible
    elseif not limit or limit <= 0 then
        limit = viewer.iconLimit or #allIcons
        if limit <= 0 then limit = #visible end
    end

    local viewerKey = VIEWER_KEY[viewer:GetName()]
    if #visible == 0 then return end

    local rows = BuildRows(limit, visible)
    if #rows == 0 then return end

    -- 行尺寸（支持覆盖）
    local rowInfos = {}
    for ri = 1, #rows do
        local ov = cfg.rowOverrides[ri]
        rowInfos[ri] = {
            w = (ov and ov.width)  or cfg.iconWidth,
            h = (ov and ov.height) or cfg.iconHeight,
        }
    end

    if singleLineAdaptive and rowInfos[1] then
        EnsureSingleLineStableFrameSize(viewer, cfg, isH, rowInfos[1].w, rowInfos[1].h)
    end

    -- 应用样式：注入帧与原生图标完全相同的样式流程
    for ri, row in ipairs(rows) do
        local info = rowInfos[ri]
        for _, icon in ipairs(row) do
            icon._cdf_viewerKey = viewerKey
            Style:ApplyIcon(icon, info.w, info.h, db.iconZoom, db.borderSize)
            Style:ApplyStack(icon, cfg.stack)
            Style:ApplyKeybind(icon, cfg)
            Style:ApplySwipeOverlay(icon)
            Style:ApplyCooldownText(icon, cfg)
        end
    end

    -- 技能可用高亮
    Style:RefreshAvailHighlights(allIcons)

    local growDir = cfg.growDir or "TOP"

    if isH then
        self:LayoutCDH(viewer, rows, rowInfos, cfg, iconDir, limit, growDir)
    else
        self:LayoutCDV(viewer, rows, rowInfos, cfg, iconDir, limit, growDir)
    end

    if not singleLineAdaptive then
        UpdateViewerSizeToMatchIcons(viewer, visible)
    end
end

------------------------------------------------------
-- 技能水平布局
-- growDir "TOP"    → 行从上往下叠（yOffset 递减）
-- growDir "BOTTOM" → 行从下往上叠（yOffset 递增）
-- rowAnchor:
--   LEFT   → 左侧固定，向右增长
--   RIGHT  → 右侧固定，向左增长
--   CENTER → 保持原有居中布局（受 iconDir 影响）
------------------------------------------------------
function Layout:LayoutCDH(viewer, rows, rowInfos, cfg, iconDir, limit, growDir)
    local fromBottom = (growDir == "BOTTOM")
    local rowOffsetMod = fromBottom and 1 or -1
    local baseVert = fromBottom and "BOTTOM" or "TOP"

    -- 参考宽度：按当前布局中“最大行实际图标数”计算。
    -- 这样当总图标数 < iconsPerRow 时，CENTER 仍按实际内容宽度居中。
    local refW = rowInfos[1].w
    local refCount = 0
    for i = 1, #rows do
        local count = #rows[i]
        if count > refCount then
            refCount = count
        end
    end
    if refCount <= 0 then
        refCount = limit
    end
    local refTotalW = refCount * (refW + cfg.spacingX) - cfg.spacingX

    local anchorMode = (cfg.rowAnchor == "LEFT" or cfg.rowAnchor == "RIGHT") and cfg.rowAnchor or "CENTER"

    local yAccum = 0
    for ri, row in ipairs(rows) do
        local w, h = rowInfos[ri].w, rowInfos[ri].h
        local count = #row
        local rowContentW = count * (w + cfg.spacingX) - cfg.spacingX

        -- 行内水平锚点：左 / 中 / 右
        -- LEFT/RIGHT 使用固定边作为锚点，确保增减图标时锚点边不漂移
        local rowAnchor, startX, stepDir
        if anchorMode == "LEFT" then
            rowAnchor = baseVert .. "LEFT"
            startX = 0
            stepDir = 1
        elseif anchorMode == "RIGHT" then
            rowAnchor = baseVert .. "RIGHT"
            startX = 0
            stepDir = -1
        else
            rowAnchor = baseVert .. ((iconDir == 1) and "LEFT" or "RIGHT")
            startX = ((refTotalW - rowContentW) / 2) * iconDir
            stepDir = iconDir
        end

        local yOffset = yAccum * rowOffsetMod
        for i, icon in ipairs(row) do
            local x = startX + (i - 1) * (w + cfg.spacingX) * stepDir
            SetPointCached(icon, rowAnchor, viewer, x, yOffset)
        end

        yAccum = yAccum + h + cfg.spacingY
    end
end

------------------------------------------------------
-- 技能垂直布局
-- growDir "TOP"    → anchor=BOTTOMLEFT, 列从左往右叠（xOffset 递增）
-- growDir "BOTTOM" → anchor=BOTTOMRIGHT, 列从右往左叠（xOffset 递减）
-- 列内垂直：始终以满列高度为基准居中
------------------------------------------------------
function Layout:LayoutCDV(viewer, rows, rowInfos, cfg, iconDir, limit, growDir)
    local fromBottom = (growDir == "BOTTOM")
    local colOffsetMod = fromBottom and -1 or 1
    local iconVertDir = -iconDir

    local vertPart = (iconDir == 1) and "BOTTOM" or "TOP"
    local horizPart = fromBottom and "RIGHT" or "LEFT"
    local colAnchor = vertPart .. horizPart

    local refH = rowInfos[1].h
    local refCount = 0
    for i = 1, #rows do
        local count = #rows[i]
        if count > refCount then
            refCount = count
        end
    end
    if refCount <= 0 then
        refCount = limit
    end
    local refTotalH = refCount * (refH + cfg.spacingY) - cfg.spacingY

    local xAccum = 0
    for ri, row in ipairs(rows) do
        local w, h = rowInfos[ri].w, rowInfos[ri].h
        local count = #row
        local colContentH = count * (h + cfg.spacingY) - cfg.spacingY

        local startY = -((refTotalH - colContentH) / 2) * iconVertDir

        local xOffset = xAccum * colOffsetMod
        for i, icon in ipairs(row) do
            local y = startY - (i - 1) * (h + cfg.spacingY) * iconVertDir
            SetPointCached(icon, colAnchor, viewer, xOffset, y)
        end

        xAccum = xAccum + w + cfg.spacingX
    end
end

------------------------------------------------------
-- 刷新全部布局
------------------------------------------------------
function Layout:RefreshAll()
    if not ns.db then return end
    self:RefreshViewer("EssentialCooldownViewer")
    self:RefreshViewer("UtilityCooldownViewer")
    self:RefreshViewer("BuffIconCooldownViewer")
end

