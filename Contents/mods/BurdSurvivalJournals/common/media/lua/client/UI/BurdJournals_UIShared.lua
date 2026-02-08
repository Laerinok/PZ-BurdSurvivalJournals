--[[
    Burd's Survival Journals - UI Shared Utilities
    Burd's Survival Journals - Build 41
    
    Shared UI helper functions and styling
]]

require "BurdJournals_Shared"

BurdJournals = BurdJournals or {}
BurdJournals.UI = BurdJournals.UI or {}

-- ==================== UI COLORS ====================

BurdJournals.UI.Colors = {
    -- Panel backgrounds
    panelBg = {r=0.08, g=0.08, b=0.1, a=0.95},
    panelBorder = {r=0.4, g=0.35, b=0.3, a=1},
    
    -- Text colors
    titleText = {r=1, g=0.9, b=0.7, a=1},
    normalText = {r=0.9, g=0.9, b=0.9, a=1},
    dimText = {r=0.6, g=0.6, b=0.6, a=1},
    successText = {r=0.5, g=0.9, b=0.5, a=1},
    warningText = {r=0.9, g=0.7, b=0.3, a=1},
    errorText = {r=0.9, g=0.4, b=0.4, a=1},
    
    -- Button colors
    btnDefault = {r=0.4, g=0.4, b=0.4, a=1},
    btnSuccess = {r=0.3, g=0.5, b=0.3, a=1},
    btnDanger = {r=0.6, g=0.3, b=0.3, a=1},
    btnInfo = {r=0.3, g=0.4, b=0.6, a=1},
    btnWarning = {r=0.5, g=0.5, b=0.3, a=1},
    
    -- List colors
    listBg = {r=0.12, g=0.12, b=0.15, a=1},
    listAltBg = {r=0.15, g=0.15, b=0.18, a=1},
    listSelected = {r=0.2, g=0.3, b=0.2, a=1},
    listHover = {r=0.18, g=0.18, b=0.22, a=1},
    
    -- Checkbox colors
    checkboxBorder = {r=0.6, g=0.6, b=0.6, a=1},
    checkboxFill = {r=0.4, g=0.8, b=0.4, a=1},
}

-- ==================== UI HELPERS ====================

function BurdJournals.UI.drawRoundedRect(target, x, y, w, h, radius, a, r, g, b)
    -- Simplified rounded rect using regular rect for PZ
    target:drawRect(x, y, w, h, a, r, g, b)
end

function BurdJournals.UI.drawProgressBar(target, x, y, w, h, progress, bgColor, fillColor)
    -- Background
    target:drawRect(x, y, w, h, bgColor.a or 0.8, bgColor.r, bgColor.g, bgColor.b)
    
    -- Fill
    local fillWidth = math.max(0, math.min(1, progress)) * w
    if fillWidth > 0 then
        target:drawRect(x, y, fillWidth, h, fillColor.a or 1, fillColor.r, fillColor.g, fillColor.b)
    end
    
    -- Border
    target:drawRectBorder(x, y, w, h, 1, 0.5, 0.5, 0.5)
end

function BurdJournals.UI.truncateText(text, maxWidth, font)
    if not text then return "" end
    
    local textWidth = getTextManager():MeasureStringX(font or UIFont.Small, text)
    if textWidth <= maxWidth then
        return text
    end
    
    local ellipsis = "..."
    local ellipsisWidth = getTextManager():MeasureStringX(font or UIFont.Small, ellipsis)
    local targetWidth = maxWidth - ellipsisWidth
    
    local truncated = text
    while getTextManager():MeasureStringX(font or UIFont.Small, truncated) > targetWidth and #truncated > 0 do
        truncated = string.sub(truncated, 1, -2)
    end
    
    return truncated .. ellipsis
end

-- ==================== SKILL CATEGORY ICONS ====================

BurdJournals.UI.SkillIcons = {
    -- Map skill categories to texture names (using vanilla icons where possible)
    Passive = "media/ui/Moodles/Moodle_Icon_Endurance.png",
    Combat = "media/ui/Moodles/Moodle_Icon_Combat.png",
    Crafting = "media/ui/Moodles/Moodle_Icon_Unhappy.png",
    Survival = "media/ui/Moodles/Moodle_Icon_Hungry.png",
    Agility = "media/ui/Moodles/Moodle_Icon_Panic.png",
}

function BurdJournals.UI.getSkillCategory(skillName)
    for category, skills in pairs(BurdJournals.SKILL_CATEGORIES) do
        for _, skill in ipairs(skills) do
            if skill == skillName then
                return category
            end
        end
    end
    local fallback = "Other"
    local localized = getText and getText("UI_BurdJournals_OtherCategory")
    if localized and localized ~= "UI_BurdJournals_OtherCategory" then
        return localized
    end
    return fallback
end

-- ==================== NOTIFICATION HELPERS ====================

function BurdJournals.UI.showNotification(player, message, color)
    if player and player.Say then
        player:Say(message)
    end
end

function BurdJournals.UI.showSuccess(player, message)
    BurdJournals.UI.showNotification(player, message, BurdJournals.UI.Colors.successText)
end

function BurdJournals.UI.showError(player, message)
    BurdJournals.UI.showNotification(player, message, BurdJournals.UI.Colors.errorText)
end

function BurdJournals.UI.showWarning(player, message)
    BurdJournals.UI.showNotification(player, message, BurdJournals.UI.Colors.warningText)
end




