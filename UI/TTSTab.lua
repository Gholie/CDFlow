-- TTS 自定义播报 Tab
local _, ns = ...

local L  = ns.L
local UI = ns.UI

local function NormalizeEntry(entry)
    if type(entry) ~= "table" or not entry.mode then return nil end
    return {
        mode         = entry.mode,
        text         = entry.text  or "",
        sound        = entry.sound or "",
        soundChannel = entry.soundChannel or "Master",
    }
end

function ns.BuildTTSTab(scroll)
    local AceGUI = LibStub("AceGUI-3.0")

    if type(ns.db.ttsAliases) ~= "table" then
        ns.db.ttsAliases = {}
    end

    -- ── 说明 ──────────────────────────────────────────────────
    local hintGroup = AceGUI:Create("InlineGroup")
    hintGroup:SetTitle(L.ttsAliases)
    hintGroup:SetFullWidth(true)
    hintGroup:SetLayout("Flow")
    scroll:AddChild(hintGroup)

    local hint = AceGUI:Create("Label")
    hint:SetText("|cffaaaaaa" .. L.ttsAliasHint .. "|r")
    hint:SetFullWidth(true)
    hint:SetFontObject(GameFontHighlightSmall)
    hintGroup:AddChild(hint)

    -- ── 表单状态 ──────────────────────────────────────────────
    local inputSpellID      = nil
    local inputMode         = "text"
    local inputText         = nil
    local inputSound        = nil
    local inputSoundChannel = "Master"

    -- 前向声明（回调跨引用）
    local boxID, ddMode, dynGroup, listLabel

    -- ── 列表重建 ──────────────────────────────────────────────
    local function RebuildList()
        local aliases = ns.db.ttsAliases
        local keys = {}
        for id in pairs(aliases) do
            keys[#keys + 1] = tonumber(id) or id
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

        local lines = { "|cff88ccff" .. L.ttsAliasListTitle .. "|r" }
        for _, id in ipairs(keys) do
            local entry  = aliases[id] or aliases[tostring(id)]
            local norm   = NormalizeEntry(entry)
            if norm then
                local spellName = C_Spell.GetSpellName(id) or "?"
                local modeTag   = (norm.mode == "sound")
                    and "|cff00ccff[♪]|r"
                    or  "|cffaaaaaa[T]|r"
                local detail = (norm.mode == "sound") and norm.sound or norm.text
                local line = modeTag .. " " .. id .. " |cffaaaaaa(" .. spellName .. ")|r"
                if detail ~= "" then
                    line = line .. "  →  |cffffffff" .. detail .. "|r"
                end
                lines[#lines + 1] = line
            end
        end
        if #keys == 0 then
            lines[#lines + 1] = "|cff888888" .. L.ttsAliasPreviewErr .. "|r"
        end
        listLabel:SetText(table.concat(lines, "\n"))
    end

    -- ── 动态输入区域重建 ──────────────────────────────────────
    local function RebuildDynamic()
        dynGroup:ReleaseChildren()

        if inputMode == "text" then
            -- 文字覆盖模式：单行文字输入
            local box = AceGUI:Create("EditBox")
            box:SetLabel(L.ttsAliasCustomText)
            box:SetFullWidth(true)
            box:SetText(inputText or "")
            box:SetCallback("OnTextChanged", function(_, _, val)
                inputText = val ~= "" and val or nil
            end)
            dynGroup:AddChild(box)
        else
            -- 自定义音效模式：路径 + 频道
            local box = AceGUI:Create("EditBox")
            box:SetLabel(L.ttsFilePath)
            box:SetFullWidth(true)
            box:SetText(inputSound or "")
            box:SetCallback("OnTextChanged", function(_, _, val)
                inputSound = val ~= "" and val or nil
            end)
            dynGroup:AddChild(box)

            local dd = AceGUI:Create("Dropdown")
            dd:SetLabel(L.ttsSoundChannel)
            dd:SetWidth(200)
            dd:SetList(
                { Master   = L.ttsChanMaster,
                  SFX      = L.ttsChanSFX,
                  Ambience = L.ttsChanAmbience,
                  Music    = L.ttsChanMusic,
                  Dialog   = L.ttsChanDialog },
                { "Master", "SFX", "Ambience", "Music", "Dialog" }
            )
            dd:SetValue(inputSoundChannel)
            dd:SetCallback("OnValueChanged", function(_, _, val)
                inputSoundChannel = val
            end)
            dynGroup:AddChild(dd)

            local ph = AceGUI:Create("Label")
            ph:SetText("|cffaaaaaa" .. L.ttsSoundHint .. "|r")
            ph:SetFullWidth(true)
            ph:SetFontObject(GameFontHighlightSmall)
            dynGroup:AddChild(ph)
        end

        C_Timer.After(0, function()
            if scroll and scroll.DoLayout then scroll:DoLayout() end
        end)
    end

    -- ── 读取已有条目填充表单 ──────────────────────────────────
    local function LoadEntry(n)
        local norm = NormalizeEntry(n and ns.db.ttsAliases[n])
        if not norm then return end

        inputMode         = norm.mode
        inputText         = norm.text  ~= "" and norm.text  or nil
        inputSound        = norm.sound ~= "" and norm.sound or nil
        inputSoundChannel = norm.soundChannel

        ddMode:SetValue(inputMode)
        RebuildDynamic()
    end

    -- ── 表单区域 ──────────────────────────────────────────────
    local formGroup = AceGUI:Create("InlineGroup")
    formGroup:SetTitle(L.ttsFormTitle)
    formGroup:SetFullWidth(true)
    formGroup:SetLayout("Flow")
    scroll:AddChild(formGroup)

    -- 技能 ID（实时预览名称，已有条目自动回填）
    boxID = AceGUI:Create("EditBox")
    boxID:SetLabel(L.ttsAliasSpellID)
    boxID:SetWidth(140)
    boxID:SetCallback("OnTextChanged", function(_, _, val)
        local n = tonumber(val)
        inputSpellID = n and n > 0 and n or nil
        if n and n > 0 then
            local name = C_Spell.GetSpellName(n)
            boxID:SetLabel(
                name and (L.ttsAliasSpellID .. "  |cff00ff88" .. name .. "|r")
                      or (L.ttsAliasSpellID .. "  |cffff4444" .. L.ttsAliasPreviewErr .. "|r")
            )
            LoadEntry(n)
        else
            boxID:SetLabel(L.ttsAliasSpellID)
        end
    end)
    formGroup:AddChild(boxID)

    -- 播报方式选择
    ddMode = AceGUI:Create("Dropdown")
    ddMode:SetLabel(L.ttsMode)
    ddMode:SetWidth(280)
    ddMode:SetList(
        { text = L.ttsModeText, sound = L.ttsModeSound },
        { "text", "sound" }
    )
    ddMode:SetValue("text")
    ddMode:SetCallback("OnValueChanged", function(_, _, val)
        inputMode = val
        RebuildDynamic()
    end)
    formGroup:AddChild(ddMode)

    -- 动态输入容器（根据播报方式切换内容）
    dynGroup = AceGUI:Create("SimpleGroup")
    dynGroup:SetFullWidth(true)
    dynGroup:SetLayout("Flow")
    formGroup:AddChild(dynGroup)

    -- 操作按钮
    local btnAdd = AceGUI:Create("Button")
    btnAdd:SetText(L.ttsAliasAdd)
    btnAdd:SetWidth(120)
    btnAdd:SetCallback("OnClick", function()
        if not (inputSpellID and inputSpellID > 0) then return end
        ns.db.ttsAliases[inputSpellID] = {
            mode         = inputMode,
            text         = inputText  or "",
            sound        = inputSound or "",
            soundChannel = inputSoundChannel,
        }
        RebuildList()
    end)
    formGroup:AddChild(btnAdd)

    local btnRemove = AceGUI:Create("Button")
    btnRemove:SetText(L.ttsAliasRemove)
    btnRemove:SetWidth(80)
    btnRemove:SetCallback("OnClick", function()
        if inputSpellID and inputSpellID > 0 then
            ns.db.ttsAliases[inputSpellID] = nil
            ns.db.ttsAliases[tostring(inputSpellID)] = nil
            RebuildList()
        end
    end)
    formGroup:AddChild(btnRemove)

    -- ── 当前列表 ──────────────────────────────────────────────
    UI.AddHeading(scroll, L.ttsAliasListTitle)

    listLabel = AceGUI:Create("Label")
    listLabel:SetFullWidth(true)
    listLabel:SetFontObject(GameFontHighlightSmall)
    scroll:AddChild(listLabel)

    -- 初始化
    RebuildDynamic()
    RebuildList()
end
