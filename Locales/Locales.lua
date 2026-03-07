local _, ns = ...

------------------------------------------------------
-- 本地化模块：中英文双语支持
------------------------------------------------------

local L = {}
ns.L = L

local locale = GetLocale()
local data = ns.LocaleData[locale] or ns.LocaleData["enUS"] or {}

setmetatable(L, {
    __index = function(t, key)
        return data[key] or key
    end
})
