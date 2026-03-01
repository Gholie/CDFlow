-- AceDB-3.0 初始化、配置文件管理
local _, ns = ...

local AceDB3 = LibStub("AceDB-3.0")
local LibDualSpec = LibStub("LibDualSpec-1.0", true)
local DeepCopy = ns.DeepCopy
local MigrateOldData = ns.MigrateOldData

-- 所有启用"使用共享配置"的角色都切换到此 Profile 名称
ns.SHARED_PROFILE_NAME = "Default"

function ns:InitDB()
    local charKey = UnitName("player") .. " - " .. GetRealmName()
    ns._charKey = charKey

    local oldCharConfig = CDFlowDB_Char and CDFlowDB_Char.config and DeepCopy(CDFlowDB_Char.config)
    local oldProfiles = CDFlowDB_Profiles and next(CDFlowDB_Profiles) and DeepCopy(CDFlowDB_Profiles)
    local oldAccountConfig = nil
    if CDFlowDB and CDFlowDB.essential and not CDFlowDB.profiles then
        oldAccountConfig = DeepCopy(CDFlowDB)
        wipe(CDFlowDB)
    end

    local db = AceDB3:New("CDFlowDB", {
        profile = ns.defaults,
        char    = { useSharedProfile = false },
    }, charKey)

    if LibDualSpec then
        LibDualSpec:EnhanceDatabase(db, "CDFlow")
    end

    ns.acedb = db

    local migrated = false
    if oldCharConfig then
        MigrateOldData(oldCharConfig)
        for k, v in pairs(oldCharConfig) do
            if type(v) == "table" then
                db.profile[k] = DeepCopy(v)
            else
                db.profile[k] = v
            end
        end
        migrated = true
    elseif oldAccountConfig then
        MigrateOldData(oldAccountConfig)
        for k, v in pairs(oldAccountConfig) do
            if type(v) == "table" then
                db.profile[k] = DeepCopy(v)
            else
                db.profile[k] = v
            end
        end
        migrated = true
    end

    if oldProfiles then
        for name, cfg in pairs(oldProfiles) do
            MigrateOldData(cfg)
            db.sv.profiles[name] = cfg
        end
    end

    if migrated or oldProfiles then
        CDFlowDB_Char = nil
        CDFlowDB_Profiles = nil
    end

    -- 若此角色勾选了"使用共享配置"，在迁移完成后再切换到共享 Profile，
    -- 避免把迁移数据写入共享 Profile。
    if db.char.useSharedProfile then
        db:SetProfile(ns.SHARED_PROFILE_NAME)
    end

    ns.db = db.profile
end

function ns:OnProfileChanged()
    ns.db = ns.acedb.profile
end

--- 返回当前角色是否启用了共享配置。
function ns:GetUseSharedProfile()
    return ns.acedb.char.useSharedProfile == true
end

--- 切换当前角色的共享配置状态。
--- enabled=true 切换到共享 Profile；false 切回角色专属 Profile。
function ns:SetUseSharedProfile(enabled)
    ns.acedb.char.useSharedProfile = enabled
    if enabled then
        ns.acedb:SetProfile(ns.SHARED_PROFILE_NAME)
    else
        -- 切回角色专属 Profile（不存在时 AceDB 会自动以默认值创建）
        ns.acedb:SetProfile(ns._charKey)
    end
    ns.db = ns.acedb.profile
end
