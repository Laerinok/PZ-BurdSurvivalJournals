
require "BurdJournals_Shared"
require "ISUI/ISToolTipInv"

BurdJournals = BurdJournals or {}
BurdJournals.Tooltips = BurdJournals.Tooltips or {}

local function getTooltipText(key, fallback)
    local text = getText(key)
    if text and text ~= "" and text ~= key then
        return text
    end
    return fallback
end

local CURSED_TAG_COLOR = {r=0.82, g=0.58, b=0.95}

local function formatAge(timestamp)
    if not timestamp then return nil end

    local currentTime = getGameTime():getWorldAgeHours()
    local ageHours = currentTime - timestamp

    if ageHours < 0 then ageHours = 0 end

    local ageDays = math.floor(ageHours / 24)

    if ageDays == 0 then
        return getText("Tooltip_BurdJournals_AgeToday") or "Today"
    elseif ageDays == 1 then
        return getText("Tooltip_BurdJournals_Age1Day") or "1 day ago"
    else
        return string.format(getText("Tooltip_BurdJournals_AgeDays") or "%d days ago", ageDays)
    end
end

local function isCurrentPlayerOwner(journalData)
    local player = getPlayer()
    if not player then return false end

    local playerUsername = player:getUsername()
    if not playerUsername then return false end

    if journalData.ownerUsername then
        return journalData.ownerUsername == playerUsername
    end

    if journalData.author then
        if journalData.author == playerUsername then
            return true
        end
        local playerFullName = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname()
        if journalData.author == playerFullName then
            return true
        end
    end

    return false
end

function BurdJournals.Tooltips.getExtraInfo(item)
    if not item then return nil end

    local fullType = item:getFullType()
    if not fullType or not string.find(fullType, "BurdJournals") then
        return nil
    end

    local modData = item:getModData()
    local journalData = modData and modData.BurdJournals

    if not journalData then
        return nil
    end

    local lines = {}

    if journalData.ownerUsername then
        local ownerText = journalData.ownerUsername
        if isCurrentPlayerOwner(journalData) then
            ownerText = ownerText .. " " .. (getText("Tooltip_BurdJournals_OwnerYou") or "(You)")
            local ownerLine = string.format(getText("Tooltip_BurdJournals_Owner") or "Owner: %s", ownerText)
            table.insert(lines, {text = ownerLine, color = {r=0.4, g=0.8, b=1.0}})
        else
            local ownerLine = string.format(getText("Tooltip_BurdJournals_Owner") or "Owner: %s", ownerText)
            table.insert(lines, {text = ownerLine, color = {r=0.7, g=0.7, b=0.9}})
        end
    end

    if journalData.author then

        local showAuthor = true
        if journalData.ownerUsername and journalData.author == journalData.ownerUsername then
            showAuthor = false
        end
        if showAuthor then
            local authorLine = string.format(getText("Tooltip_BurdJournals_Author") or "Author: %s", journalData.author)
            table.insert(lines, {text = authorLine, color = {r=0.8, g=0.8, b=0.6}})
        end
    end

    if journalData.contributors then
        local contributorNames = {}
        for steamId, contribData in pairs(journalData.contributors) do
            if contribData.characterName then
                table.insert(contributorNames, contribData.characterName)
            elseif contribData.username then
                table.insert(contributorNames, contribData.username)
            end
        end

        if #contributorNames > 0 then

            table.sort(contributorNames)

            local contributorList = table.concat(contributorNames, ", ")
            local contribLine = string.format(getText("Tooltip_BurdJournals_Contributors") or "Contributors: %s", contributorList)
            table.insert(lines, {text = contribLine, color = {r=0.6, g=0.8, b=0.6}})
        end
    end

    -- Resolve profession name (handles translation keys stored by server)
    local resolvedProfessionName = BurdJournals.resolveProfessionName(journalData)
    if resolvedProfessionName then
        local profLine = string.format(getText("Tooltip_BurdJournals_Profession") or "Profession: %s", resolvedProfessionName)
        table.insert(lines, {text = profLine, color = {r=0.7, g=0.7, b=0.7}})
    end

    local skillCount = 0
    local unclaimedSkills = 0
    local totalXP = 0
    if journalData.skills then
        for skillName, skillData in pairs(journalData.skills) do
            skillCount = skillCount + 1
            if not journalData.claimedSkills or not journalData.claimedSkills[skillName] then
                unclaimedSkills = unclaimedSkills + 1
                totalXP = totalXP + (skillData.xp or 0)
            end
        end
    end

    local traitCount = 0
    local unclaimedTraits = 0
    if journalData.traits then
        for traitId, _ in pairs(journalData.traits) do
            traitCount = traitCount + 1
            if not journalData.claimedTraits or not journalData.claimedTraits[traitId] then
                unclaimedTraits = unclaimedTraits + 1
            end
        end
    end

    if skillCount > 0 then
        local skillText
        if unclaimedSkills > 0 and BurdJournals.formatXP then
            skillText = string.format(getText("Tooltip_BurdJournals_SkillsLineXP") or "Skills: %d/%d (%s XP)", unclaimedSkills, skillCount, BurdJournals.formatXP(totalXP))
            table.insert(lines, {text = skillText, color = {r=0.4, g=0.9, b=0.4}})
        elseif unclaimedSkills > 0 then
            skillText = string.format(getText("Tooltip_BurdJournals_SkillsLine") or "Skills: %d/%d", unclaimedSkills, skillCount)
            table.insert(lines, {text = skillText, color = {r=0.4, g=0.9, b=0.4}})
        else
            skillText = string.format(getText("Tooltip_BurdJournals_SkillsLine") or "Skills: %d/%d", unclaimedSkills, skillCount)
            skillText = skillText .. " " .. (getText("Tooltip_BurdJournals_AllClaimed") or "(all claimed)")
            table.insert(lines, {text = skillText, color = {r=0.5, g=0.5, b=0.5}})
        end
    end

    if traitCount > 0 then
        local traitText = string.format(getText("Tooltip_BurdJournals_TraitsLine") or "Traits: %d/%d", unclaimedTraits, traitCount)
        if unclaimedTraits > 0 then
            table.insert(lines, {text = traitText, color = {r=0.9, g=0.7, b=0.3}})
        else
            traitText = traitText .. " " .. (getText("Tooltip_BurdJournals_AllClaimed") or "(all claimed)")
            table.insert(lines, {text = traitText, color = {r=0.5, g=0.5, b=0.5}})
        end
    end

    local recipeCount = 0
    local unclaimedRecipes = 0
    if journalData.recipes then
        for recipeName, _ in pairs(journalData.recipes) do
            recipeCount = recipeCount + 1
            if not journalData.claimedRecipes or not journalData.claimedRecipes[recipeName] then
                unclaimedRecipes = unclaimedRecipes + 1
            end
        end
    end

    if recipeCount > 0 then
        local recipeText = string.format(getText("Tooltip_BurdJournals_RecipesLine") or "Recipes: %d/%d", unclaimedRecipes, recipeCount)
        if unclaimedRecipes > 0 then
            table.insert(lines, {text = recipeText, color = {r=0.5, g=0.85, b=0.9}})
        else
            recipeText = recipeText .. " " .. (getText("Tooltip_BurdJournals_AllClaimed") or "(all claimed)")
            table.insert(lines, {text = recipeText, color = {r=0.5, g=0.5, b=0.5}})
        end
    end

    local conditionText = nil
    local conditionColor = nil
    local conditionSuffixText = nil
    local conditionSuffixColor = nil

    if journalData.isBloody then
        conditionText = getText("Tooltip_BurdJournals_ConditionBloody") or "Condition: Bloody"
        conditionColor = {r=0.8, g=0.2, b=0.2}
        if journalData.isCursedReward == true then
            conditionSuffixText = " " .. getTooltipText("Tooltip_BurdJournals_TagCursed", "[Cursed]")
            conditionSuffixColor = CURSED_TAG_COLOR
        end
    elseif journalData.isWorn then
        conditionText = getText("Tooltip_BurdJournals_ConditionWorn") or "Condition: Worn"
        conditionColor = {r=0.7, g=0.5, b=0.3}
    elseif journalData.wasRestored then
        conditionText = getText("Tooltip_BurdJournals_ConditionRestored") or "Condition: Restored"
        conditionColor = {r=0.6, g=0.7, b=0.5}
    else
        conditionText = getText("Tooltip_BurdJournals_ConditionClean") or "Condition: Clean"
        conditionColor = {r=0.5, g=0.8, b=0.5}
    end

    if conditionText then
        table.insert(lines, {
            text = conditionText,
            color = conditionColor,
            suffixText = conditionSuffixText,
            suffixColor = conditionSuffixColor,
        })
    end

    local originText = nil
    local originColor = {r=0.6, g=0.6, b=0.6}

    local sourceType = type(journalData.sourceType) == "string" and string.lower(journalData.sourceType) or nil

    if sourceType == "personal" then
        originText = getText("Tooltip_BurdJournals_OriginPersonal") or "Origin: Personal"
        originColor = {r=0.3, g=0.6, b=0.8}
    elseif sourceType == "zombie" then
        originText = getText("Tooltip_BurdJournals_OriginZombie") or "Origin: Recovered from zombie"
        originColor = {r=0.6, g=0.4, b=0.3}
    elseif sourceType == "world" then
        originText = getText("Tooltip_BurdJournals_OriginWorld") or "Origin: Found in world"
        originColor = {r=0.5, g=0.5, b=0.6}
    elseif sourceType == "crafted" then
        originText = getText("Tooltip_BurdJournals_OriginCrafted") or "Origin: Crafted"
        originColor = {r=0.5, g=0.6, b=0.5}
    elseif sourceType == "found" then
        originText = getText("Tooltip_BurdJournals_OriginFound") or "Origin: Found"
        originColor = {r=0.5, g=0.5, b=0.6}
    elseif journalData.wasFromBloody then
        originText = getText("Tooltip_BurdJournals_OriginZombie") or "Origin: Recovered from zombie"
        originColor = {r=0.6, g=0.4, b=0.3}
    elseif not journalData.ownerUsername and journalData.author then

        originText = getText("Tooltip_BurdJournals_OriginFound") or "Origin: Found"
        originColor = {r=0.5, g=0.5, b=0.6}
    elseif isCurrentPlayerOwner(journalData) then
        originText = getText("Tooltip_BurdJournals_OriginPersonal") or "Origin: Personal"
        originColor = {r=0.3, g=0.6, b=0.8}
    end

    if originText then
        table.insert(lines, {text = originText, color = originColor})
    end

    if journalData.timestamp then
        local ageText = formatAge(journalData.timestamp)
        if ageText then
            local createdLine = string.format(getText("Tooltip_BurdJournals_Created") or "Created: %s", ageText)
            table.insert(lines, {text = createdLine, color = {r=0.6, g=0.6, b=0.6}})
        end
    elseif journalData.lastUpdated then
        local ageText = formatAge(journalData.lastUpdated)
        if ageText then
            local updatedLine = string.format(getText("Tooltip_BurdJournals_LastUpdated") or "Last Updated: %s", ageText)
            table.insert(lines, {text = updatedLine, color = {r=0.6, g=0.6, b=0.6}})
        end
    end

    return lines
end

local originalRender = ISToolTipInv.render

ISToolTipInv.render = function(self)

    originalRender(self)

    if not self.item then return end
    if not self.item.getFullType then return end

    local fullType = self.item:getFullType()
    if not fullType or not string.find(fullType, "BurdJournals") then
        return
    end

    local extraLines = BurdJournals.Tooltips.getExtraInfo(self.item)
    if not extraLines or #extraLines == 0 then
        return
    end

    local font = UIFont.Small
    local lineHeight = getTextManager():getFontHeight(font) + 2

    local extraHeight = (#extraLines * lineHeight) + 12

    local originalHeight = self:getHeight()

    local bgColor = self.backgroundColor
    local borderColor = self.borderColor

    if not bgColor or not borderColor then
        return
    end

    self:drawRect(0, originalHeight, self:getWidth(), extraHeight, bgColor.a, bgColor.r, bgColor.g, bgColor.b)

    self:drawRect(0, originalHeight, 1, extraHeight, borderColor.a, borderColor.r, borderColor.g, borderColor.b)

    self:drawRect(self:getWidth() - 1, originalHeight, 1, extraHeight, borderColor.a, borderColor.r, borderColor.g, borderColor.b)

    self:drawRect(0, originalHeight + extraHeight - 1, self:getWidth(), 1, borderColor.a, borderColor.r, borderColor.g, borderColor.b)

    self:drawRect(1, originalHeight - 1, self:getWidth() - 2, 1, bgColor.a, bgColor.r, bgColor.g, bgColor.b)

    local startY = originalHeight + 5
    self:drawRect(10, startY - 3, self:getWidth() - 20, 1, 0.5, 0.6, 0.6, 0.6)

    for i, lineData in ipairs(extraLines) do
        local y = startY + (i - 1) * lineHeight
        local lineText = tostring(lineData.text or "")
        local lineColor = lineData.color or {r=1, g=1, b=1}
        self:drawText(lineText, 12, y, lineColor.r, lineColor.g, lineColor.b, 1.0, font)

        if lineData.suffixText and tostring(lineData.suffixText) ~= "" then
            local suffixColor = lineData.suffixColor or lineColor
            local baseWidth = getTextManager():MeasureStringX(font, lineText)
            self:drawText(tostring(lineData.suffixText), 12 + baseWidth, y, suffixColor.r, suffixColor.g, suffixColor.b, 1.0, font)
        end
    end

    self:setHeight(originalHeight + extraHeight)
end

BurdJournals.debugPrint("[BurdJournals] Tooltip hook installed")
