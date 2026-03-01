-- 物品监控模块（Group A）：追踪物品/技能冷却，显示为可拖拽图标容器
local _, ns = ...

local IM = {}
ns.ItemMonitor = IM

local Style = ns.Style

------------------------------------------------------
-- 模块状态
------------------------------------------------------

local container   = nil   -- 可拖拽容器帧（UIParent 子帧）
local iconFrames  = {}    -- entryKey → frame（entryKey = type..":"..id）
local itemOrder   = {}    -- 有序 entry 列表（{type, id}）

-- 名称/图标缓存
local itemDataCache  = {}  -- itemID → { name, icon }
local spellDataCache = {}  -- spellID → { name, icon }

------------------------------------------------------
-- 工具函数
------------------------------------------------------

local function RoundToPixel(v)
    return math.floor(v + 0.5)
end

local function GetCfg()
    return ns.db and ns.db.itemMonitor
end

local function IsLocked()
    local cfg = GetCfg()
    return cfg and cfg.locked or false
end

-- 将 cfg.items 元素规范化为 { type, id }，兼容旧格式裸 number
local function NormalizeEntry(e)
    if type(e) == "number" then
        return { type = "item", id = e }
    end
    return e
end

local function EntryKey(entry)
    return (entry.type or "item") .. ":" .. tostring(entry.id)
end

------------------------------------------------------
-- 数据获取（名称 + 图标）
------------------------------------------------------

local function GetItemData(itemID)
    if itemDataCache[itemID] then return itemDataCache[itemID] end
    local name = C_Item.GetItemNameByID(itemID)
    local icon = C_Item.GetItemIconByID(itemID)
    if name then
        itemDataCache[itemID] = { name = name, icon = icon }
        return itemDataCache[itemID]
    end
    C_Item.RequestLoadItemDataByID(itemID)
    return nil
end

local function GetSpellData(spellID)
    if spellDataCache[spellID] then return spellDataCache[spellID] end
    local name = C_Spell.GetSpellName(spellID)
    local icon = C_Spell.GetSpellTexture(spellID)
    if name then
        spellDataCache[spellID] = { name = name, icon = icon }
        return spellDataCache[spellID]
    end
    return nil
end

-- 返回条目的显示名称和图标（UI 列表用）
function IM.GetEntryDisplay(entry)
    entry = NormalizeEntry(entry)
    if entry.type == "spell" then
        local d = GetSpellData(entry.id)
        return d and d.name or ("Spell:" .. entry.id),
               d and d.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
    else
        local d = GetItemData(entry.id)
        return d and d.name or ("Item:" .. entry.id),
               d and d.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
    end
end

------------------------------------------------------
-- 冷却更新
------------------------------------------------------

local function UpdateItemCooldown(frame)
    if not frame or not frame._im_entry then return end
    local entry = frame._im_entry

    if entry.type == "spell" then
        local durObj = C_Spell.GetSpellCooldownDuration and
                       C_Spell.GetSpellCooldownDuration(entry.id)
        if durObj and frame.Cooldown.SetCooldownFromDurationObject then
            frame.Cooldown:SetCooldownFromDurationObject(durObj)
        else
            local spellCD = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(entry.id)
            if spellCD and spellCD.startTime and spellCD.duration and spellCD.duration > 1.5 then
                frame.Cooldown:SetCooldown(spellCD.startTime, spellCD.duration)
            else
                frame.Cooldown:Clear()
            end
        end
    else
        local start, duration = C_Container.GetItemCooldown(entry.id)

        if not (start and duration and duration > 1.5) then
            for _, slotID in ipairs({ 13, 14 }) do
                local equippedID = GetInventoryItemID("player", slotID)
                if equippedID and equippedID == entry.id then
                    start, duration = GetInventoryItemCooldown("player", slotID)
                    break
                end
            end
        end

        if start and duration and duration > 1.5 then
            frame.Cooldown:SetCooldown(start, duration)
        else
            frame.Cooldown:Clear()
        end
    end
end

------------------------------------------------------
-- 容器定位
--
-- posX 的含义随 rowAnchor 变化：
--   LEFT   → 容器左边缘 到 UIParent 中心的距离
--   RIGHT  → 容器右边缘 到 UIParent 中心的距离
--   CENTER → 容器中心   到 UIParent 中心的距离（原有行为）
------------------------------------------------------

local function PositionContainer()
    if not container then return end
    local cfg = GetCfg()
    if not cfg then return end

    container:ClearAllPoints()
    local ra = cfg.rowAnchor or "CENTER"
    if ra == "LEFT" then
        container:SetPoint("LEFT",   UIParent, "CENTER", cfg.posX or 0, cfg.posY or -340)
    elseif ra == "RIGHT" then
        container:SetPoint("RIGHT",  UIParent, "CENTER", cfg.posX or 0, cfg.posY or -340)
    else
        container:SetPoint("CENTER", UIParent, "CENTER", cfg.posX or 0, cfg.posY or -340)
    end
end

-- 从当前容器位置读取对应 anchor 边的坐标
local function ReadContainerEdgePos()
    if not container then return 0, 0 end
    local scx, scy = UIParent:GetCenter()
    local cfg = GetCfg()
    local ra = cfg and cfg.rowAnchor or "CENTER"
    local px, py
    if ra == "LEFT" then
        px = RoundToPixel((container:GetLeft() or 0) - scx)
    elseif ra == "RIGHT" then
        px = RoundToPixel((container:GetRight() or 0) - scx)
    else
        local cx = (container:GetLeft() or 0) + (container:GetWidth() or 0) / 2
        px = RoundToPixel(cx - scx)
    end
    local cy = (container:GetBottom() or 0) + (container:GetHeight() or 0) / 2
    py = RoundToPixel(cy - scy)
    return px, py
end

------------------------------------------------------
-- 布局
------------------------------------------------------

local function LayoutIcons()
    local cfg = GetCfg()
    if not cfg or not container then return end
    if #itemOrder == 0 then
        container:Hide()
        return
    end
    container:Show()

    local w, h        = cfg.iconWidth, cfg.iconHeight
    local spacingX    = cfg.spacingX or 2
    local spacingY    = cfg.spacingY or 2
    local iconsPerRow = cfg.iconsPerRow or 6
    local growDir     = cfg.growDir or "TOP"
    local rowAnchor   = cfg.rowAnchor or "CENTER"

    if iconsPerRow <= 0 then iconsPerRow = #itemOrder end

    local rows = {}
    local visibleCount = 0
    for _, entry in ipairs(itemOrder) do
        local key   = EntryKey(entry)
        local frame = iconFrames[key]
        if frame and frame:IsShown() then
            visibleCount = visibleCount + 1
            local ri = math.floor((visibleCount - 1) / iconsPerRow) + 1
            rows[ri] = rows[ri] or {}
            rows[ri][#rows[ri] + 1] = frame
        end
    end

    local numRows = #rows
    if visibleCount == 0 then
        container:Hide()
        return
    end

    local maxCols = 0
    for _, row in ipairs(rows) do
        if #row > maxCols then maxCols = #row end
    end
    local containerW = maxCols * w + (maxCols - 1) * spacingX
    local containerH = numRows * h + (numRows - 1) * spacingY
    container:SetSize(math.max(containerW, w), math.max(containerH, h))

    -- growDir 决定行增长方向
    local rowDirMult = (growDir == "BOTTOM") and 1 or -1
    local firstRowY  = (growDir == "BOTTOM") and (containerH / 2 - h / 2)
                                               or -(containerH / 2 - h / 2)

    for ri, row in ipairs(rows) do
        local rowCount = #row
        local rowW = rowCount * w + (rowCount - 1) * spacingX

        -- 行内锚点：LEFT/RIGHT 从对应边开始，CENTER 居中
        local startX
        if rowAnchor == "LEFT" then
            startX = -containerW / 2 + w / 2
        elseif rowAnchor == "RIGHT" then
            startX = containerW / 2 - rowW + w / 2
        else
            startX = -rowW / 2 + w / 2
        end

        local rowY = firstRowY + (ri - 1) * rowDirMult * (-(h + spacingY))

        for ci, frame in ipairs(row) do
            local x = startX + (ci - 1) * (w + spacingX)
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", container, "CENTER", x, rowY)
            frame:Show()
        end
    end
end

------------------------------------------------------
-- 物品数量显示
------------------------------------------------------

local DEFAULT_FONT = ns._styleConst and ns._styleConst.DEFAULT_FONT or (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
local ResolveFontPath = ns.ResolveFontPath or function() return DEFAULT_FONT end

local function UpdateItemCount(frame)
    if not frame or not frame._im_entry then return end
    local cfg   = GetCfg()
    local entry = frame._im_entry

    -- 技能条目不显示数量
    if entry.type == "spell" then
        if frame._cdf_itemCount then frame._cdf_itemCount:Hide() end
        frame:Show()
        if frame.Icon then frame.Icon:SetVertexColor(1, 1, 1, 1) end
        return
    end

    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(entry.id) or 0

    if not cfg or not cfg.itemCount then
        if frame._cdf_itemCount then frame._cdf_itemCount:Hide() end
        frame:Show()
        if frame.Icon then frame.Icon:SetVertexColor(1, 1, 1, 1) end
        return
    end

    local ic       = cfg.itemCount
    local whenZero = ic.whenZero or "gray"

    if count == 0 and whenZero == "hide" then
        if frame._cdf_itemCount then frame._cdf_itemCount:Hide() end
        frame:Hide()
        return
    end

    frame:Show()
    if frame.Icon then
        if count == 0 and whenZero == "gray" then
            frame.Icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        else
            frame.Icon:SetVertexColor(1, 1, 1, 1)
        end
    end

    if not frame._cdf_itemCount then
        local fs = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
        frame._cdf_itemCount = fs
    end
    local fs = frame._cdf_itemCount
    if not ic.enabled or count == 1 then
        fs:Hide()
    else
        local ox = ic.offsetX or -2
        local oy = ic.offsetY or 2
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", ox, oy)
        local fontSize = ic.fontSize or 12
        local fontPath = ResolveFontPath("默认")
        if not fs:SetFont(fontPath, fontSize, "OUTLINE") then
            fs:SetFont(DEFAULT_FONT, fontSize, "OUTLINE")
        end
        fs:SetText(tostring(count))
        fs:SetTextColor(1, 1, 1, 1)
        fs:Show()
    end
end

------------------------------------------------------
-- 样式应用
------------------------------------------------------

local function ApplyStyleToFrame(frame)
    local cfg = GetCfg()
    if not cfg then return end

    if Style and Style.ApplyIcon then
        Style:ApplyIcon(frame, cfg.iconWidth, cfg.iconHeight,
            ns.db.iconZoom or 0.08, ns.db.borderSize or 1)
    end
    UpdateItemCount(frame)
    if Style and Style.ApplyCooldownText then
        Style:ApplyCooldownText(frame, cfg)
    end
    if Style and Style.ApplyKeybind then
        Style:ApplyKeybind(frame, cfg)
    end
end

------------------------------------------------------
-- 图标帧管理
------------------------------------------------------

local function CreateIconFrame(entry)
    local cfg = GetCfg()
    local w   = cfg and cfg.iconWidth  or 40
    local h   = cfg and cfg.iconHeight or 40

    local frame = CreateFrame("Frame", nil, container)
    frame:SetSize(w, h)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(frame)
    frame.Icon = icon

    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints(frame)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    frame.Cooldown = cooldown

    frame._im_entry = entry
    frame.itemID = (entry.type == "item") and entry.id or nil
    frame:Hide()

    if entry.type == "spell" then
        local d = GetSpellData(entry.id)
        icon:SetTexture(d and d.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    else
        local d = GetItemData(entry.id)
        icon:SetTexture(d and d.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    end

    return frame
end

local function RebuildIconFrames()
    local cfg = GetCfg()
    if not cfg then return end

    local newKeys = {}
    local normalizedItems = {}
    for _, raw in ipairs(cfg.items) do
        local entry = NormalizeEntry(raw)
        local key   = EntryKey(entry)
        newKeys[key] = entry
        normalizedItems[#normalizedItems + 1] = entry
    end

    for key, frame in pairs(iconFrames) do
        if not newKeys[key] then
            frame:Hide()
            frame:SetParent(nil)
            iconFrames[key] = nil
        end
    end

    itemOrder = {}
    for _, entry in ipairs(normalizedItems) do
        local key = EntryKey(entry)
        itemOrder[#itemOrder + 1] = entry
        if not iconFrames[key] then
            iconFrames[key] = CreateIconFrame(entry)
        end
    end

    for _, entry in ipairs(itemOrder) do
        ApplyStyleToFrame(iconFrames[EntryKey(entry)])
    end
end

------------------------------------------------------
-- 容器拖拽/锁定
------------------------------------------------------

local function SetupContainerDrag()
    if not container then return end

    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:RegisterForDrag("LeftButton")
    container:EnableMouseWheel(true)

    if not container._imPosLabel then
        local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOP", container, "BOTTOM", 0, -4)
        lbl:SetTextColor(1, 0.82, 0, 1)
        lbl:Hide()
        container._imPosLabel = lbl
    end

    if not container._imHintText then
        local txt = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        txt:SetPoint("BOTTOM", container, "TOP", 0, 6)
        txt:SetText(ns.L and ns.L.imNudgeHint or "Drag or scroll | Shift=H | Ctrl=10px")
        txt:SetTextColor(0.8, 0.8, 0.8, 1)
        txt:Hide()
        container._imHintText = txt
    end

    container:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        if IsLocked() then return end
        self:StartMoving()
        self:SetScript("OnUpdate", function(s)
            local px, py = ReadContainerEdgePos()
            if s._imPosLabel then
                s._imPosLabel:SetFormattedText("X: %.0f  Y: %.0f", px, py)
            end
        end)
    end)

    container:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        local cfg = GetCfg()
        if not cfg then return end
        local px, py = ReadContainerEdgePos()
        cfg.posX = px
        cfg.posY = py
        -- 重新锚定到保存的边，避免浮动锚点残留
        PositionContainer()
        if self._imPosLabel then
            self._imPosLabel:SetFormattedText("X: %.0f  Y: %.0f", px, py)
        end
    end)

    container:SetScript("OnMouseWheel", function(self, delta)
        if InCombatLockdown() then return end
        if IsLocked() then return end
        local cfg = GetCfg()
        if not cfg then return end
        local step = IsControlKeyDown() and 10 or 1
        if IsShiftKeyDown() then
            cfg.posX = (cfg.posX or 0) + delta * step
        else
            cfg.posY = (cfg.posY or 0) + delta * step
        end
        PositionContainer()
        if self._imPosLabel then
            self._imPosLabel:SetFormattedText("X: %.0f  Y: %.0f", cfg.posX, cfg.posY)
        end
    end)

    container:SetScript("OnEnter", function(self)
        if not IsLocked() then
            if self._imHintText then self._imHintText:Show() end
            if self._imPosLabel then
                local cfg = GetCfg()
                if cfg then
                    self._imPosLabel:SetFormattedText("X: %.0f  Y: %.0f",
                        cfg.posX or 0, cfg.posY or 0)
                end
                self._imPosLabel:Show()
            end
        end
    end)

    container:SetScript("OnLeave", function(self)
        if self._imHintText then self._imHintText:Hide() end
        if self._imPosLabel then self._imPosLabel:Hide() end
    end)
end

local function ApplyLockToContainer()
    if not container then return end
    local locked = IsLocked()
    container:EnableMouse(not locked)
    container:EnableMouseWheel(not locked)
end

------------------------------------------------------
-- 公开接口
------------------------------------------------------

function IM:Init()
    local cfg = GetCfg()
    if not cfg then return end

    if not container then
        container = CreateFrame("Frame", "CDFlow_ItemMonitorContainer", UIParent)
        container:SetFrameStrata("MEDIUM")
        container:SetFrameLevel(10)
        SetupContainerDrag()
    end

    PositionContainer()
    ApplyLockToContainer()
    RebuildIconFrames()
    LayoutIcons()
    self:UpdateAllCooldowns()
end

function IM:UpdateAllCooldowns()
    for _, entry in ipairs(itemOrder) do
        local frame = iconFrames[EntryKey(entry)]
        if frame then UpdateItemCooldown(frame) end
    end
end

function IM:SetLocked(locked)
    local cfg = GetCfg()
    if cfg then cfg.locked = locked end
    ApplyLockToContainer()
end

-- 切换行内锚点：转换 posX 到新锚点坐标系，保持容器视觉位置不变
function IM:SetRowAnchor(newAnchor)
    local cfg = GetCfg()
    if not cfg then return end

    local old = cfg.rowAnchor or "CENTER"
    if old == newAnchor then return end

    -- 转换 posX：当前边 → 新边
    if container then
        local w = container:GetWidth() or 0
        local hw = w / 2
        if old == "CENTER" and newAnchor == "LEFT" then
            cfg.posX = (cfg.posX or 0) - hw
        elseif old == "CENTER" and newAnchor == "RIGHT" then
            cfg.posX = (cfg.posX or 0) + hw
        elseif old == "LEFT" and newAnchor == "CENTER" then
            cfg.posX = (cfg.posX or 0) + hw
        elseif old == "LEFT" and newAnchor == "RIGHT" then
            cfg.posX = (cfg.posX or 0) + w
        elseif old == "RIGHT" and newAnchor == "CENTER" then
            cfg.posX = (cfg.posX or 0) - hw
        elseif old == "RIGHT" and newAnchor == "LEFT" then
            cfg.posX = (cfg.posX or 0) - w
        end
    end

    cfg.rowAnchor = newAnchor
    PositionContainer()
    LayoutIcons()
end

-- 添加条目（entry = { type="item"|"spell", id=N } 或裸 number）
function IM:AddEntry(entry)
    local cfg = GetCfg()
    if not cfg then return end
    entry = NormalizeEntry(entry)
    local key = EntryKey(entry)
    for _, e in ipairs(cfg.items) do
        if EntryKey(NormalizeEntry(e)) == key then return end
    end
    cfg.items[#cfg.items + 1] = entry
    self:Init()
end

function IM:AddItem(itemID)
    self:AddEntry({ type = "item", id = itemID })
end

function IM:RemoveEntry(key)
    local cfg = GetCfg()
    if not cfg then return end
    for i, raw in ipairs(cfg.items) do
        if EntryKey(NormalizeEntry(raw)) == key then
            table.remove(cfg.items, i)
            break
        end
    end
    self:Init()
end

function IM:RemoveItem(itemID)
    self:RemoveEntry("item:" .. tostring(itemID))
end

function IM:RefreshItemNames()
    for _, entry in ipairs(itemOrder) do
        local frame = iconFrames[EntryKey(entry)]
        if frame and frame.Icon then
            if entry.type == "spell" then
                local d = GetSpellData(entry.id)
                if d and d.icon then frame.Icon:SetTexture(d.icon) end
            else
                local d = GetItemData(entry.id)
                if d and d.icon then frame.Icon:SetTexture(d.icon) end
            end
        end
    end
end

function IM:Refresh()
    if not container then self:Init(); return end
    local cfg = GetCfg()
    if not cfg then return end
    PositionContainer()
    for _, entry in ipairs(itemOrder) do
        local frame = iconFrames[EntryKey(entry)]
        if frame then ApplyStyleToFrame(frame) end
    end
    LayoutIcons()
end

function IM:RefreshItemCounts()
    for _, entry in ipairs(itemOrder) do
        local frame = iconFrames[EntryKey(entry)]
        if frame then UpdateItemCount(frame) end
    end
    LayoutIcons()
end
