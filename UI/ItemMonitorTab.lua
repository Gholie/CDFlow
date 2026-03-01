-- 物品监控设置选项卡（Group A：独立监控组）
local _, ns = ...

local L      = ns.L
local UI     = ns.UI

local function GetAceGUI()
    return LibStub("AceGUI-3.0")
end

local function GetIM()
    return ns.ItemMonitor
end

------------------------------------------------------
-- 冷却读秒区块
------------------------------------------------------

local function BuildCooldownTextSection(scroll)
    local AceGUI = GetAceGUI()
    local cfg    = ns.db.itemMonitor

    UI.AddHeading(scroll, L.cooldownText)

    local container = AceGUI:Create("SimpleGroup")
    container:SetFullWidth(true)
    container:SetLayout("List")
    scroll:AddChild(container)

    local function RefreshLayout()
        C_Timer.After(0, function()
            if scroll and scroll.DoLayout then scroll:DoLayout() end
        end)
    end

    local function RebuildContent()
        container:ReleaseChildren()
        local cdCfg = cfg.cooldownText

        local cb = AceGUI:Create("CheckBox")
        cb:SetLabel(L.customizeStyle)
        cb:SetValue(cdCfg.enabled)
        cb:SetFullWidth(true)
        cb:SetCallback("OnValueChanged", function(_, _, val)
            cdCfg.enabled = val
            local im = GetIM()
            if im then im:Refresh() end
            RebuildContent()
        end)
        container:AddChild(cb)

        if not cdCfg.enabled then RefreshLayout(); return end

        UI.AddSlider(container, L.fontSize, 6, 48, 1,
            function() return cdCfg.fontSize end,
            function(v)
                cdCfg.fontSize = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        local fontItems, fontOrder = UI.GetFontItems()
        UI.AddDropdown(container, L.fontFamily, fontItems, fontOrder,
            function() return UI.GetEffectiveFontName(cdCfg.fontName) end,
            function(v)
                cdCfg.fontName = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        UI.AddDropdown(container, L.outline, UI.OUTLINE_ITEMS,
            { "NONE", "OUTLINE", "THICKOUTLINE" },
            function() return cdCfg.outline end,
            function(v)
                cdCfg.outline = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        if type(cdCfg.textColor) == "table" then
            UI.AddColorPicker(container, L.textColor,
                function() return cdCfg.textColor end,
                function(r, g, b, a)
                    cdCfg.textColor = { r, g, b, a }
                    local im = GetIM(); if im then im:Refresh() end
                end)
        end

        UI.AddDropdown(container, L.position, UI.POS_ITEMS,
            { "TOPLEFT", "TOPRIGHT", "TOP", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT", "CENTER" },
            function() return cdCfg.point end,
            function(v)
                cdCfg.point = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        UI.AddSlider(container, L.offsetX, -20, 20, 1,
            function() return cdCfg.offsetX end,
            function(v)
                cdCfg.offsetX = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        UI.AddSlider(container, L.offsetY, -20, 20, 1,
            function() return cdCfg.offsetY end,
            function(v)
                cdCfg.offsetY = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        RefreshLayout()
    end

    RebuildContent()
end

------------------------------------------------------
-- 键位显示区块
------------------------------------------------------

local function BuildKeybindSection(scroll)
    local AceGUI = GetAceGUI()
    local cfg    = ns.db.itemMonitor
    if not cfg.keybind then return end

    UI.AddHeading(scroll, L.keybindText)

    local container = AceGUI:Create("SimpleGroup")
    container:SetFullWidth(true)
    container:SetLayout("List")
    scroll:AddChild(container)

    local function RefreshLayout()
        C_Timer.After(0, function()
            if scroll and scroll.DoLayout then scroll:DoLayout() end
        end)
    end

    local function RebuildContent()
        container:ReleaseChildren()
        local kb = cfg.keybind

        local cb = AceGUI:Create("CheckBox")
        cb:SetLabel(L.enableDisplay)
        cb:SetValue(kb.enabled)
        cb:SetFullWidth(true)
        cb:SetCallback("OnValueChanged", function(_, _, val)
            kb.enabled = val
            local im = GetIM(); if im then im:Refresh() end
            RebuildContent()
        end)
        container:AddChild(cb)

        if not kb.enabled then RefreshLayout(); return end

        UI.AddSlider(container, L.fontSize, 6, 48, 1,
            function() return kb.fontSize end,
            function(v)
                kb.fontSize = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        local fontItems, fontOrder = UI.GetFontItems()
        UI.AddDropdown(container, L.fontFamily, fontItems, fontOrder,
            function() return UI.GetEffectiveFontName(kb.fontName) end,
            function(v)
                kb.fontName = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        UI.AddDropdown(container, L.outline, UI.OUTLINE_ITEMS,
            { "NONE", "OUTLINE", "THICKOUTLINE" },
            function() return kb.outline end,
            function(v)
                kb.outline = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        if type(kb.textColor) == "table" then
            UI.AddColorPicker(container, L.textColor,
                function() return kb.textColor end,
                function(r, g, b, a)
                    kb.textColor = { r, g, b, a }
                    local im = GetIM(); if im then im:Refresh() end
                end)
        end

        UI.AddDropdown(container, L.position, UI.POS_ITEMS,
            { "TOPLEFT", "TOPRIGHT", "TOP", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT", "CENTER" },
            function() return kb.point end,
            function(v)
                kb.point = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        UI.AddSlider(container, L.offsetX, -20, 20, 1,
            function() return kb.offsetX end,
            function(v)
                kb.offsetX = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        UI.AddSlider(container, L.offsetY, -20, 20, 1,
            function() return kb.offsetY end,
            function(v)
                kb.offsetY = v
                local im = GetIM(); if im then im:Refresh() end
            end)

        RefreshLayout()
    end

    RebuildContent()
end

------------------------------------------------------
-- 物品数量区块
------------------------------------------------------

local function BuildItemCountSection(scroll)
    local AceGUI = GetAceGUI()
    local cfg    = ns.db.itemMonitor
    if not cfg then return end
    if not cfg.itemCount then
        cfg.itemCount = { enabled = true, fontSize = 12, whenZero = "gray" }
    end

    UI.AddHeading(scroll, L.imItemCount)

    local container = AceGUI:Create("SimpleGroup")
    container:SetFullWidth(true)
    container:SetLayout("List")
    scroll:AddChild(container)

    local ic = cfg.itemCount

    local cb = AceGUI:Create("CheckBox")
    cb:SetLabel(L.enableDisplay)
    cb:SetValue(ic.enabled)
    cb:SetFullWidth(true)
    cb:SetCallback("OnValueChanged", function(_, _, val)
        ic.enabled = val
        local im = GetIM(); if im then im:Refresh() end
    end)
    container:AddChild(cb)

    UI.AddSlider(container, L.fontSize, 8, 32, 1,
        function() return ic.fontSize end,
        function(v)
            ic.fontSize = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    local whenZeroItems = { gray = L.imWhenZeroGray, hide = L.imWhenZeroHide }
    local whenZeroOrder = { "gray", "hide" }
    UI.AddDropdown(container, L.imWhenZero, whenZeroItems, whenZeroOrder,
        function() return ic.whenZero or "gray" end,
        function(v)
            ic.whenZero = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    UI.AddSlider(container, L.offsetX, -20, 20, 1,
        function() return ic.offsetX or -2 end,
        function(v)
            ic.offsetX = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    UI.AddSlider(container, L.offsetY, -20, 20, 1,
        function() return ic.offsetY or 2 end,
        function(v)
            ic.offsetY = v
            local im = GetIM(); if im then im:Refresh() end
        end)
end

------------------------------------------------------
-- 条目列表
------------------------------------------------------

local function BuildItemList(scroll, rebuildTab)
    local AceGUI = GetAceGUI()
    local cfg    = ns.db.itemMonitor
    if not cfg.keybind or type(cfg.keybind.manualByItem) ~= "table" then
        if cfg.keybind then cfg.keybind.manualByItem = {} end
    end
    if not cfg.keybind or type(cfg.keybind.manualBySpell) ~= "table" then
        if cfg.keybind then cfg.keybind.manualBySpell = {} end
    end

    if #cfg.items == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetText("|cffaaaaaa" .. L.imNoItems .. "|r")
        lbl:SetFullWidth(true)
        scroll:AddChild(lbl)
        return
    end

    local IM = GetIM()
    for idx, raw in ipairs(cfg.items) do
        local entry
        if type(raw) == "number" then
            entry = { type = "item", id = raw }
        else
            entry = raw
        end

        local entryType = entry.type or "item"
        local entryID   = entry.id

        local row = AceGUI:Create("SimpleGroup")
        row:SetFullWidth(true)
        row:SetLayout("Flow")
        scroll:AddChild(row)

        -- 图标
        local iconTex
        if entryType == "spell" then
            iconTex = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(entryID)
        else
            iconTex = C_Item.GetItemIconByID(entryID)
        end
        if iconTex then
            local iconWidget = AceGUI:Create("Icon")
            iconWidget:SetImage(iconTex)
            iconWidget:SetImageSize(20, 20)
            iconWidget:SetWidth(28)
            row:AddChild(iconWidget)
        end

        -- 名称（含类型标记）
        local displayName
        if entryType == "spell" then
            displayName = C_Spell.GetSpellName and C_Spell.GetSpellName(entryID) or ("Spell:" .. entryID)
        else
            displayName = C_Item.GetItemNameByID(entryID) or ("Item:" .. entryID)
        end
        local typeLabel = entryType == "spell" and "|cff88ddff[" .. L.imTypeSpell .. "]|r" or "|cffffcc88[" .. L.imTypeItem .. "]|r"
        local nameLbl = AceGUI:Create("Label")
        nameLbl:SetText(typeLabel .. " |cffffffff" .. displayName .. "|r  |cff888888(" .. entryID .. ")|r")
        nameLbl:SetWidth(200)
        row:AddChild(nameLbl)

        -- 键位输入框（物品与技能均显示）
        local kb = cfg.keybind and (entryType == "spell" and cfg.keybind.manualBySpell or cfg.keybind.manualByItem)
        local keyBox = AceGUI:Create("EditBox")
        keyBox:SetLabel(L.imKeyLabel)
        keyBox:SetWidth(72)
        keyBox:DisableButton(true)
        keyBox:SetText(kb and (kb[entryID] or kb[tostring(entryID)] or "") or "")
        local function SaveKey(text)
            if not cfg.keybind then return end
            local t = entryType == "spell" and cfg.keybind.manualBySpell or cfg.keybind.manualByItem
            if not t then
                if entryType == "spell" then cfg.keybind.manualBySpell = {}; t = cfg.keybind.manualBySpell
                else cfg.keybind.manualByItem = {}; t = cfg.keybind.manualByItem end
            end
            if text and text:match("%S") then
                t[entryID] = text
                t[tostring(entryID)] = text
            else
                t[entryID] = nil
                t[tostring(entryID)] = nil
            end
            local im = GetIM()
            if im then im:Refresh() end
        end
        keyBox:SetCallback("OnEnterPressed", function(_, _, text) SaveKey(text) end)
        keyBox:SetCallback("OnLeave", function() SaveKey(keyBox:GetText()) end)
        row:AddChild(keyBox)

        -- 移除按钮
        local removeBtn = AceGUI:Create("Button")
        removeBtn:SetText(L.imRemove)
        removeBtn:SetWidth(80)
        removeBtn:SetCallback("OnClick", function()
            table.remove(cfg.items, idx)
            local im = GetIM(); if im then im:Init() end
            rebuildTab()
        end)
        row:AddChild(removeBtn)
    end
end

------------------------------------------------------
-- 主入口
------------------------------------------------------

function ns.BuildItemMonitorTab(scroll)
    local AceGUI = GetAceGUI()
    local cfg    = ns.db.itemMonitor
    if not cfg then return end

    local function RebuildTab()
        scroll:ReleaseChildren()
        ns.BuildItemMonitorTab(scroll)
        C_Timer.After(0, function()
            if scroll and scroll.DoLayout then scroll:DoLayout() end
        end)
    end

    -- 锁定位置
    local lockCB = AceGUI:Create("CheckBox")
    lockCB:SetLabel(L.imLocked)
    lockCB:SetValue(cfg.locked or false)
    lockCB:SetFullWidth(true)
    lockCB:SetCallback("OnValueChanged", function(_, _, val)
        local im = GetIM(); if im then im:SetLocked(val) end
    end)
    scroll:AddChild(lockCB)

    -- 添加条目（支持物品和技能）
    local addGroup = AceGUI:Create("InlineGroup")
    addGroup:SetTitle(L.imAddItem)
    addGroup:SetFullWidth(true)
    addGroup:SetLayout("Flow")
    scroll:AddChild(addGroup)

    -- 类型选择（单选）
    local selectedType = "item"  -- 本地状态

    local typeGroup = AceGUI:Create("SimpleGroup")
    typeGroup:SetFullWidth(true)
    typeGroup:SetLayout("Flow")
    addGroup:AddChild(typeGroup)

    local typeLabel = AceGUI:Create("Label")
    typeLabel:SetText(L.imEntryType .. ": ")
    typeLabel:SetWidth(60)
    typeGroup:AddChild(typeLabel)

    local rbItem = AceGUI:Create("CheckBox")
    rbItem:SetLabel(L.imTypeItem)
    rbItem:SetValue(true)
    rbItem:SetWidth(80)
    typeGroup:AddChild(rbItem)

    local rbSpell = AceGUI:Create("CheckBox")
    rbSpell:SetLabel(L.imTypeSpell)
    rbSpell:SetValue(false)
    rbSpell:SetWidth(80)
    typeGroup:AddChild(rbSpell)

    rbItem:SetCallback("OnValueChanged", function(_, _, val)
        if val then
            selectedType = "item"
            rbSpell:SetValue(false)
        else
            if selectedType == "item" then rbItem:SetValue(true) end
        end
    end)
    rbSpell:SetCallback("OnValueChanged", function(_, _, val)
        if val then
            selectedType = "spell"
            rbItem:SetValue(false)
        else
            if selectedType == "spell" then rbSpell:SetValue(true) end
        end
    end)

    local idBox = AceGUI:Create("EditBox")
    idBox:SetLabel(L.imItemID)
    idBox:SetWidth(160)

    local previewLbl = AceGUI:Create("Label")
    previewLbl:SetWidth(200)
    previewLbl:SetText("")

    -- 实时预览
    idBox:SetCallback("OnTextChanged", function(_, _, text)
        local id = tonumber(text)
        if not id or id <= 0 then previewLbl:SetText(""); return end

        if selectedType == "spell" then
            local name = C_Spell.GetSpellName and C_Spell.GetSpellName(id)
            if name then
                previewLbl:SetText("|cff00ff88" .. string.format(L.imSpellPreviewOk, name) .. "|r")
            else
                previewLbl:SetText("|cffaaaaaa" .. L.imItemLoading .. "|r")
            end
        else
            local name = C_Item.GetItemNameByID(id)
            if name then
                previewLbl:SetText("|cff00ff88" .. string.format(L.imItemPreviewOk, name) .. "|r")
            else
                C_Item.RequestLoadItemDataByID(id)
                previewLbl:SetText("|cffaaaaaa" .. L.imItemLoading .. "|r")
            end
        end
    end)

    local function TryAdd(text)
        local id = tonumber(text)
        if not id or id <= 0 then return end

        -- 技能验证
        if selectedType == "spell" then
            local name = C_Spell.GetSpellName and C_Spell.GetSpellName(id)
            if not name then
                previewLbl:SetText("|cffff4444" .. L.imSpellPreviewErr .. "|r")
                return
            end
        else
            local name = C_Item.GetItemNameByID(id)
            if not name then
                previewLbl:SetText("|cffff4444" .. L.imItemPreviewErr .. "|r")
                return
            end
        end

        local im = GetIM()
        if im then im:AddEntry({ type = selectedType, id = id }) end
        idBox:SetText("")
        previewLbl:SetText("")
        RebuildTab()
    end

    idBox:SetCallback("OnEnterPressed", function(_, _, text) TryAdd(text) end)
    addGroup:AddChild(idBox)
    addGroup:AddChild(previewLbl)

    local addBtn = AceGUI:Create("Button")
    addBtn:SetText(L.imAddItem)
    addBtn:SetWidth(120)
    addBtn:SetCallback("OnClick", function() TryAdd(idBox:GetText()) end)
    addGroup:AddChild(addBtn)

    -- 条目列表
    BuildItemList(scroll, RebuildTab)

    -- 布局配置
    UI.AddHeading(scroll, L.imLayout)

    UI.AddDropdown(scroll, L.growDir, UI.CD_GROW_ITEMS,
        { "TOP", "BOTTOM" },
        function() return cfg.growDir end,
        function(v)
            cfg.growDir = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    UI.AddDropdown(scroll, L.rowAnchor, UI.ROW_ANCHOR_ITEMS,
        { "LEFT", "CENTER", "RIGHT" },
        function() return cfg.rowAnchor or "CENTER" end,
        function(v)
            local im = GetIM()
            if im then im:SetRowAnchor(v) end
        end)

    local iconsPerRowSlider = AceGUI:Create("Slider")
    iconsPerRowSlider:SetLabel(L.iconsPerRow)
    iconsPerRowSlider:SetSliderValues(0, 20, 1)
    iconsPerRowSlider:SetValue(cfg.iconsPerRow or 6)
    iconsPerRowSlider:SetIsPercent(false)
    iconsPerRowSlider:SetFullWidth(true)
    iconsPerRowSlider:SetCallback("OnValueChanged", function(_, _, v)
        cfg.iconsPerRow = math.floor(v)
        local im = GetIM(); if im then im:Refresh() end
    end)
    scroll:AddChild(iconsPerRowSlider)

    local tip = AceGUI:Create("Label")
    tip:SetText("|cffaaaaaa" .. L.iconsPerRowTip .. "|r")
    tip:SetFullWidth(true)
    tip:SetFontObject(GameFontHighlightSmall)
    scroll:AddChild(tip)

    UI.AddSlider(scroll, L.iconWidth, 16, 80, 1,
        function() return cfg.iconWidth end,
        function(v)
            cfg.iconWidth = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    UI.AddSlider(scroll, L.iconHeight, 16, 80, 1,
        function() return cfg.iconHeight end,
        function(v)
            cfg.iconHeight = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    UI.AddSlider(scroll, L.spacingX, 0, 500, 1,
        function() return cfg.spacingX end,
        function(v)
            cfg.spacingX = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    UI.AddSlider(scroll, L.spacingY, 0, 500, 1,
        function() return cfg.spacingY end,
        function(v)
            cfg.spacingY = v
            local im = GetIM(); if im then im:Refresh() end
        end)

    -- 键位显示
    BuildKeybindSection(scroll)

    -- 物品数量
    BuildItemCountSection(scroll)

    -- 冷却读秒
    BuildCooldownTextSection(scroll)
end
