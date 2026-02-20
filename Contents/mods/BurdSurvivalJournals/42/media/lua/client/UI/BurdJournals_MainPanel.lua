
require "BurdJournals_Shared"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "TimedActions/ISInventoryTransferUtil"

BurdJournals = BurdJournals or {}
BurdJournals.UI = BurdJournals.UI or {}

BurdJournals.Sounds = {

    PAGE_TURN = {ui = "UISelectListItem", world = "PageFlipBook"},
    LEARN_COMPLETE = {ui = "UIActivateButton", world = "CloseBook"},
    OPEN_JOURNAL = {ui = "UIActivateTab", world = "OpenBook"},
    QUEUE_ADD = {ui = "UISelectListItem", world = "PageFlipMagazine"},

    DISSOLVE = {world = "BreakWoodItem"},
    ERASE = {world = "RummageInInventory"},

    RECORD = {ui = "UIActivateButton"},
}

local traitDefCache = {}

local function getTraitDefinition(traitId)
    if not traitId then return nil end

    if traitDefCache[traitId] then
        return traitDefCache[traitId]
    end

    local traitIdLower = string.lower(traitId)
    local traitIdNorm = traitIdLower:gsub("%s", "")

    local function createCacheEntry(def)
        local defLabel = def:getLabel() or ""
        local defType = def:getType()
        local defName = ""
        if defType then
            if defType.getName then
                defName = defType:getName() or tostring(defType)
            else
                defName = tostring(defType)
            end
        end
        local cached = {
            def = def,
            label = defLabel,
            name = defName,
            type = defType
        }
        if def.getTexture then
            cached.texture = def:getTexture()
        end
        traitDefCache[traitId] = cached
        return cached
    end

    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()

        for i = 0, allTraits:size() - 1 do
            local def = allTraits:get(i)
            local defLabel = def:getLabel() or ""
            local defType = def:getType()
            local defName = ""
            if defType then
                if defType.getName then
                    defName = defType:getName() or tostring(defType)
                else
                    defName = tostring(defType)
                end
            end

            local defLabelLower = string.lower(defLabel)
            local defNameLower = string.lower(defName)

            if (defLabel == traitId) or (defName == traitId) or
               (defLabelLower == traitIdLower) or (defNameLower == traitIdLower) then
                return createCacheEntry(def)
            end
        end

        for i = 0, allTraits:size() - 1 do
            local def = allTraits:get(i)
            local defLabel = def:getLabel() or ""
            local defType = def:getType()
            local defName = ""
            if defType then
                if defType.getName then
                    defName = defType:getName() or tostring(defType)
                else
                    defName = tostring(defType)
                end
            end

            local defLabelNorm = string.lower(defLabel):gsub("%s", "")
            local defNameNorm = string.lower(defName):gsub("%s", "")

            if (defLabelNorm == traitIdNorm) or (defNameNorm == traitIdNorm) then
                return createCacheEntry(def)
            end
        end

        for i = 0, allTraits:size() - 1 do
            local def = allTraits:get(i)
            local defLabel = def:getLabel() or ""
            local defType = def:getType()
            local defName = ""
            if defType then
                if defType.getName then
                    defName = defType:getName() or tostring(defType)
                else
                    defName = tostring(defType)
                end
            end

            local defLabelLower = string.lower(defLabel)
            local defNameLower = string.lower(defName)

            if defLabelLower:find(traitIdLower, 1, true) or defNameLower:find(traitIdLower, 1, true) then
                return createCacheEntry(def)
            end
        end
    end

    return nil
end

local function safeGetTraitName(traitId)
    if not traitId then return getText("UI_BurdJournals_UnknownTrait") or "Unknown Trait" end

    local traitDef = getTraitDefinition(traitId)
    if traitDef and traitDef.label then
        return traitDef.label
    end

    if TraitFactory and TraitFactory.getTrait then
        local traitObj = TraitFactory.getTrait(traitId)
        if traitObj and traitObj.getLabel then
            return traitObj:getLabel()
        end
    end

    return traitId:gsub("(%l)(%u)", "%1 %2")
end

local function getTraitTexture(traitId)
    if not traitId then return nil end

    local traitDef = getTraitDefinition(traitId)
    if traitDef and traitDef.texture then
        return traitDef.texture
    end

    return nil
end

local traitPositiveCache = {}
local traitCostLookup = nil

local function getTraitCost(traitId)
    if not traitId then return nil end

    if not traitCostLookup then
        traitCostLookup = BurdJournals.buildTraitCostLookup() or {}
    end

    local cost = traitCostLookup[string.lower(traitId)]
    if cost ~= nil then
        return cost
    end

    local traitCache = getTraitDefinition(traitId)
    if traitCache and traitCache.def and traitCache.def.getCost then
        return traitCache.def:getCost()
    end

    if TraitFactory and TraitFactory.getTrait then
        local traitObj = TraitFactory.getTrait(traitId)
        if traitObj and traitObj.getCost then
            return traitObj:getCost()
        end
    end

    return nil
end

local function isTraitPositive(traitId)
    if not traitId then return nil end

    if traitPositiveCache[traitId] ~= nil then
        local cached = traitPositiveCache[traitId]
        if cached == "nil" then return nil end
        return cached
    end

    local result = nil

    local cost = getTraitCost(traitId)
    if cost ~= nil then
        if cost > 0 then
            result = true
        elseif cost < 0 then
            result = false
        else
            result = nil
        end
    end

    traitPositiveCache[traitId] = (result == nil) and "nil" or result
    return result
end

local function getMagazineTexture(magazineSource)
    if not magazineSource or not getScriptManager then return nil end
    local scriptMgr = getScriptManager()
    if not scriptMgr or not scriptMgr.getItem then return nil end
    local script = scriptMgr:getItem(magazineSource)
    if not script or not script.getIcon then return nil end
    local iconName = script:getIcon()
    if not iconName then return nil end
    return getTexture("Item_" .. iconName)
end

local function showTooDarkFeedback(player)
    local message = (getText and getText("ContextMenu_TooDark")) or "Too dark to read."
    if message == "ContextMenu_TooDark" then
        message = "Too dark to read."
    end

    if HaloTextHelper and HaloTextHelper.addBadText and player then
        HaloTextHelper.addBadText(player, message)
    elseif player and player.Say then
        player:Say(message)
    end
end

local function resolveHeaderIconTexture(iconName)
    if not iconName or iconName == "" then
        return nil
    end

    local lookupKeys = {
        "Item_" .. iconName,
        iconName,
        "media/textures/Item_" .. iconName .. ".png",
        "media/textures/" .. iconName .. ".png"
    }
    for _, key in ipairs(lookupKeys) do
        local texture = getTexture(key)
        if texture then
            return texture
        end
    end

    return nil
end

local function resolveHeaderIconFromScript(fullType)
    if not fullType or fullType == "" or not getScriptManager then
        return nil
    end
    local scriptMgr = getScriptManager()
    if not scriptMgr or not scriptMgr.getItem then
        return nil
    end
    local script = scriptMgr:getItem(fullType)
    if not script or not script.getIcon then
        return nil
    end
    return resolveHeaderIconTexture(script:getIcon())
end

local function getHeaderJournalIconTexture(mode, journal, journalData, isBloodyHint)
    local fullType = journal and journal.getFullType and tostring(journal:getFullType() or "") or ""
    local isWornType = fullType ~= "" and string.find(fullType, "_Worn", 1, true) ~= nil
    local isBloodyType = fullType ~= "" and string.find(fullType, "_Bloody", 1, true) ~= nil
    local isCursedState = (journalData and (journalData.isCursedReward == true or journalData.isCursedJournal == true))
        or (journal and BurdJournals.isCursedJournalItem and BurdJournals.isCursedJournalItem(journal))
    local isWornState = isWornType or (journalData and journalData.isWorn == true) or (journal and BurdJournals.isWorn and BurdJournals.isWorn(journal))
    local isBloodyState = isBloodyHint == true or isBloodyType or (journalData and journalData.isBloody == true) or (journal and BurdJournals.isBloody and BurdJournals.isBloody(journal))

    local iconName = "FilledJournalClean"
    if isCursedState then
        iconName = "CursedJournal"
    elseif isBloodyState then
        iconName = "FilledJournalBloody"
    elseif isWornState then
        iconName = "FilledJournalWorn"
    end

    local resolved = resolveHeaderIconTexture(iconName)
    if resolved then
        return resolved
    end

    resolved = resolveHeaderIconFromScript(fullType)
    if resolved then
        return resolved
    end

    return resolveHeaderIconTexture("FilledJournalClean")
end

-- Standard (non-passive) skill XP thresholds from PZ wiki
-- These are CUMULATIVE totals to reach each level
-- Per-level: 75, 150, 300, 750, 1500, 3000, 4500, 6000, 7500, 9000
local STANDARD_XP_THRESHOLDS = {
    [0] = 0,
    [1] = 75,       -- 75
    [2] = 225,      -- 75 + 150
    [3] = 525,      -- 225 + 300
    [4] = 1275,     -- 525 + 750
    [5] = 2775,     -- 1275 + 1500
    [6] = 5775,     -- 2775 + 3000
    [7] = 10275,    -- 5775 + 4500
    [8] = 16275,    -- 10275 + 6000
    [9] = 23775,    -- 16275 + 7500
    [10] = 32775    -- 23775 + 9000
}

-- Exact passive skill (Fitness/Strength) XP thresholds from PZ wiki
-- These are CUMULATIVE totals to reach each level
local PASSIVE_XP_THRESHOLDS = {
    [0] = 0,
    [1] = 1500,
    [2] = 4500,    -- 1500 + 3000
    [3] = 10500,   -- 4500 + 6000
    [4] = 19500,   -- 10500 + 9000
    [5] = 37500,   -- 19500 + 18000
    [6] = 67500,   -- 37500 + 30000
    [7] = 127500,  -- 67500 + 60000
    [8] = 217500,  -- 127500 + 90000
    [9] = 337500,  -- 217500 + 120000
    [10] = 487500  -- 337500 + 150000
}

local function getXPForLevel(skillName, level)
    if level <= 0 then return 0 end
    if level > 10 then level = 10 end

    -- For passive skills (Fitness/Strength), use our verified thresholds
    if skillName == "Fitness" or skillName == "Strength" then
        return PASSIVE_XP_THRESHOLDS[level] or 0
    end

    -- For standard skills, use our verified thresholds first
    -- This is more reliable than perk:getTotalXpForLevel() which can be inconsistent
    return STANDARD_XP_THRESHOLDS[level] or 0
end

-- Helper function to get XP with baseline added for passive skills (Fitness/Strength)
-- Player journals recorded in baseline mode store passive XP as earned delta above
-- level-5 baseline. Loot journals store absolute XP and must NOT be baseline-shifted.
local function shouldAddPassiveBaselineForDisplay(journalData, player)
    if type(journalData) ~= "table" or journalData.isPlayerCreated ~= true then
        return false
    end

    local useBaselineMode = BurdJournals.getJournalSkillRecordingMode
        and BurdJournals.getJournalSkillRecordingMode(journalData, player)
        or (journalData.recordedWithBaseline == true)
    if not useBaselineMode then
        return false
    end

    local playerModData = player and player.getModData and player:getModData() or nil
    if playerModData and playerModData.BurdJournals and playerModData.BurdJournals.debugModified == true then
        return false
    end

    return true
end

local function getXPWithBaselineForDisplay(skillName, recordedXP, journalData, player)
    if (skillName == "Fitness" or skillName == "Strength")
        and shouldAddPassiveBaselineForDisplay(journalData, player) then
        -- Use our verified baseline XP for level 5 (37500)
        local baselineXP = PASSIVE_XP_THRESHOLDS[5] or 37500
        return baselineXP + (recordedXP or 0)
    end
    return recordedXP or 0
end

local function isSkillVisibleForJournal(journalData, skillName)
    if not skillName then return false end
    if not BurdJournals.isSkillEnabledForJournal then return true end
    return BurdJournals.isSkillEnabledForJournal(journalData, skillName)
end

local function isSkillRecordableInPlayerJournal(skillName)
    if not skillName then return false end
    if not BurdJournals.isSkillEnabledForJournal then return true end
    return BurdJournals.isSkillEnabledForJournal({isPlayerCreated = true}, skillName)
end

local function createClaimSessionId()
    local now = getTimestampMs and getTimestampMs() or 0
    local rand = ZombRand and ZombRand(1000000) or math.floor(math.random() * 1000000)
    return tostring(now) .. "-" .. tostring(rand)
end

local function getClaimSessionIdForPanel(panel, createIfMissing)
    if not panel then
        return nil
    end
    if panel.learningState and panel.learningState.active then
        if createIfMissing and not panel.learningState.claimSessionId then
            panel.learningState.claimSessionId = createClaimSessionId()
        end
        return panel.learningState.claimSessionId
    end
    if createIfMissing then
        return createClaimSessionId()
    end
    return nil
end

-- Returns preview data for the NEXT claim read (or an offset read) so UI mirrors server-side diminishing returns.
local function getClaimPreviewForSkill(journalData, player, skillName, recordedXP, readOffset, claimSessionId)
    local sourceXP = math.max(0, tonumber(recordedXP) or 0)
    local claimMultiplier, readCount = 1.0, tonumber(journalData and journalData.readCount) or 0

    if BurdJournals.getJournalClaimMultiplier then
        claimMultiplier, readCount = BurdJournals.getJournalClaimMultiplier(journalData, readOffset or 0, skillName, claimSessionId)
    end

    local effectiveXP = math.max(0, math.floor(sourceXP * claimMultiplier))
    local claimPercent = math.floor((claimMultiplier * 100) + 0.5)

    local effectiveLevel = 0
    if effectiveXP > 0 and BurdJournals.getSkillLevelFromXP then
        local xpForLevelCalc = getXPWithBaselineForDisplay(skillName, effectiveXP, journalData, player)
        effectiveLevel = BurdJournals.getSkillLevelFromXP(xpForLevelCalc, skillName) or 0
    end

    return {
        sourceXP = sourceXP,
        effectiveXP = effectiveXP,
        multiplier = claimMultiplier,
        percent = claimPercent,
        readCount = readCount,
        level = effectiveLevel,
    }
end

local function resolveJournalRecordingModeForPlayer(journalData, player)
    local useBaseline = BurdJournals.getJournalSkillRecordingMode
        and BurdJournals.getJournalSkillRecordingMode(journalData, player)
        or BurdJournals.shouldEnforceBaseline(player)
    local autoRepaired = false

    if useBaseline
        and type(journalData) == "table"
        and journalData.recordedWithBaseline == true
        and type(journalData.skills) == "table"
        and player
        and player.getXp
    then
        local sampledSkills = 0
        local suspiciousAbsoluteSkills = 0
        for skillName, storedData in pairs(journalData.skills) do
            local storedXP = tonumber(type(storedData) == "table" and storedData.xp or storedData)
            if storedXP and storedXP > 0 then
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
                if perk then
                    sampledSkills = sampledSkills + 1
                    local actualXP = player:getXp():getXP(perk)
                    local baselineXP = math.max(0, tonumber(BurdJournals.getSkillBaseline and BurdJournals.getSkillBaseline(player, skillName) or 0) or 0)
                    local earnedXP = math.max(0, actualXP - baselineXP)
                    if storedXP > (earnedXP + 0.001) and storedXP <= (actualXP + 0.001) then
                        suspiciousAbsoluteSkills = suspiciousAbsoluteSkills + 1
                    end
                end
            end
        end

        if sampledSkills > 0 and suspiciousAbsoluteSkills >= math.max(1, math.floor(sampledSkills * 0.5)) then
            useBaseline = false
            autoRepaired = true
        end
    end

    return useBaseline, autoRepaired
end

local function isLikelyNewCharacterForBaseline(player)
    if not player then
        return false
    end

    local hoursAlive = player.getHoursSurvived and (player:getHoursSurvived() or 0) or 0
    if hoursAlive < 0.1 then
        return true
    end

    if BurdJournals.Client and BurdJournals.Client._pendingNewCharacterBaseline then
        return true
    end

    return false
end

local function queueNewCharacterBaselineCapture(panel)
    if not panel or not panel.player then
        return
    end
    if not (BurdJournals.Client and BurdJournals.Client.captureBaseline) then
        return
    end

    local ticksWaited = 0
    local delayedCapture
    delayedCapture = function()
        ticksWaited = ticksWaited + 1
        if ticksWaited >= 5 then
            Events.OnTick.Remove(delayedCapture)
            BurdJournals.Client.captureBaseline(panel.player, true)
            if panel.populateRecordList then
                panel:populateRecordList()
            end
        end
    end
    Events.OnTick.Add(delayedCapture)
end

local function ensureBaselineReadyForRecording(panel, useBaseline, contextTag)
    if not useBaseline then
        return true, false
    end
    if not panel or not panel.player then
        return false, true
    end
    if BurdJournals.hasBaselineCaptured(panel.player) then
        return true, true
    end

    if isLikelyNewCharacterForBaseline(panel.player) then
        queueNewCharacterBaselineCapture(panel)
        return false, true
    end

    BurdJournals.debugPrint("[BurdJournals] " .. tostring(contextTag)
        .. ": baseline missing for existing character; skipping auto-capture and continuing without baseline enforcement")
    if BurdJournals.Client
        and BurdJournals.Client.requestServerBaseline
        and not BurdJournals.Client._awaitingServerBaseline then
        BurdJournals.Client.requestServerBaseline()
    end
    return true, false
end

local function getClaimTargetXPForPlayer(journalData, player, skillName, effectiveXP)
    local targetXP = math.max(0, tonumber(effectiveXP) or 0)
    local baselineXP = 0
    local baselineSuppressed = false
    local useBaselineForJournal = resolveJournalRecordingModeForPlayer(journalData, player)

    local playerModData = player and player.getModData and player:getModData() or nil
    if playerModData and playerModData.BurdJournals and playerModData.BurdJournals.debugModified == true then
        baselineSuppressed = true
    end

    if journalData
        and journalData.isPlayerCreated
        and useBaselineForJournal
        and BurdJournals.getSkillBaseline
        and not baselineSuppressed
    then
        baselineXP = math.max(0, tonumber(BurdJournals.getSkillBaseline(player, skillName)) or 0)
        targetXP = targetXP + baselineXP
    end

    return targetXP, baselineXP, baselineSuppressed
end

local function getSkillVhsBreakdown(skillData, fallbackNetXP)
    local netXP = math.max(0, tonumber((skillData and skillData.xp) or fallbackNetXP) or 0)
    local rawXP = tonumber(skillData and skillData.rawXP)
    if rawXP == nil then
        rawXP = netXP
    else
        rawXP = math.max(netXP, rawXP)
    end
    local excludedXP = tonumber(skillData and skillData.vhsExcludedXP)
    if excludedXP == nil then
        excludedXP = math.max(0, rawXP - netXP)
    else
        excludedXP = math.max(0, excludedXP)
    end
    if excludedXP > rawXP then
        excludedXP = rawXP
    end
    if rawXP < (netXP + excludedXP) then
        rawXP = netXP + excludedXP
    end
    return netXP, rawXP, excludedXP
end

local function formatXPWithVhsBreakdown(netXP, rawXP, excludedXP)
    local fmtNet = BurdJournals.formatXP(math.max(0, tonumber(netXP) or 0))
    local fmtRaw = BurdJournals.formatXP(math.max(0, tonumber(rawXP) or 0))
    local fmtExcluded = BurdJournals.formatXP(math.max(0, tonumber(excludedXP) or 0))
    if (tonumber(excludedXP) or 0) > 0 and (tonumber(rawXP) or 0) > (tonumber(netXP) or 0) then
        return fmtNet .. "/" .. fmtRaw .. " XP (VHS -" .. fmtExcluded .. ")"
    end
    return fmtNet .. " XP"
end

local function buildSkillVhsTooltip(skillData, claimableXP, claimPercent)
    local netXP, rawXP, excludedXP = getSkillVhsBreakdown(skillData)
    local hasVhsDelta = excludedXP > 0 and rawXP > netXP
    local hasClaimDelta = claimableXP ~= nil and netXP > 0 and math.max(0, tonumber(claimableXP) or 0) < netXP
    if not hasVhsDelta and not hasClaimDelta then
        return nil
    end

    local lines = {
        "Recorded net XP: " .. BurdJournals.formatXP(netXP)
    }
    if hasVhsDelta then
        table.insert(lines, "Recorded raw XP: " .. BurdJournals.formatXP(rawXP))
        table.insert(lines, "VHS excluded at record: -" .. BurdJournals.formatXP(excludedXP))
    end
    if hasClaimDelta then
        local claimable = math.max(0, tonumber(claimableXP) or 0)
        local line = "Current claimable: " .. BurdJournals.formatXP(claimable)
        if claimPercent and claimPercent < 100 then
            line = line .. " (" .. tostring(claimPercent) .. "%)"
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

local function calculateLevelProgress(skillName, totalXP)
    local currentLevel = 0
    local xpForCurrentLevel = 0
    local xpForNextLevel = getXPForLevel(skillName, 1)

    for level = 1, 10 do
        local xpNeeded = getXPForLevel(skillName, level)
        if totalXP >= xpNeeded then
            currentLevel = level
            xpForCurrentLevel = xpNeeded
            xpForNextLevel = getXPForLevel(skillName, level + 1)
        else
            break
        end
    end

    local progressToNext = 0
    if currentLevel < 10 then
        local xpInThisLevel = totalXP - xpForCurrentLevel
        local xpRangeForLevel = xpForNextLevel - xpForCurrentLevel
        if xpRangeForLevel > 0 then
            progressToNext = math.min(1, math.max(0, xpInThisLevel / xpRangeForLevel))
        end
    else
        progressToNext = 1
    end

    return currentLevel, progressToNext, totalXP - xpForCurrentLevel, xpForNextLevel - xpForCurrentLevel
end

-- Helper to calculate level with override support (for when stored level is more accurate)
local function calculateLevelProgressWithOverride(skillName, totalXP, storedLevel)
    local level, progress, xpInLevel, xpRange = calculateLevelProgress(skillName, totalXP)
    -- If stored level is provided and higher than calculated (can happen with passive skills),
    -- use stored level but don't show phantom progress (set to 0, not 1.0)
    if storedLevel and storedLevel > 0 and storedLevel > level then
        return storedLevel, 0, 0, 0
    end
    return level, progress, xpInLevel, xpRange
end

local function drawLevelSquares(self, x, y, level, progress, squareSize, spacing, filledColor, emptyColor, progressColor)
    squareSize = squareSize or 12
    spacing = spacing or 2
    filledColor = filledColor or {r=0.85, g=0.75, b=0.2}
    emptyColor = emptyColor or {r=0.15, g=0.15, b=0.15}
    progressColor = progressColor or {r=0.5, g=0.45, b=0.15}

    for i = 1, 10 do
        local sqX = x + (i - 1) * (squareSize + spacing)

        if i <= level then

            self:drawRect(sqX, y, squareSize, squareSize, 0.9, filledColor.r, filledColor.g, filledColor.b)
        elseif i == level + 1 and progress > 0 then

            self:drawRect(sqX, y, squareSize, squareSize, 0.6, emptyColor.r, emptyColor.g, emptyColor.b)

            local fillHeight = squareSize * progress
            self:drawRect(sqX, y + squareSize - fillHeight, squareSize, fillHeight, 0.8, progressColor.r, progressColor.g, progressColor.b)
        else

            self:drawRect(sqX, y, squareSize, squareSize, 0.5, emptyColor.r, emptyColor.g, emptyColor.b)
        end

        self:drawRectBorder(sqX, y, squareSize, squareSize, 0.3, 0.3, 0.3, 0.3)
    end

    return 10 * squareSize + 9 * spacing
end

-- Draw level squares with baseline distinction
-- Shows baseline levels as dimmed, earned levels as bright, giving accurate visual representation
-- Parameters:
--   baselineLevel, baselineProgress: Level/progress from baseline XP (restricted, shown dimmed)
--   totalLevel, totalProgress: Level/progress from total XP (baseline + earned)
--   baselineColor: Color for baseline portion (dimmed)
--   earnedColor: Color for earned portion (bright)
--   emptyColor: Color for empty squares
--   progressColor: Color for partial progress square
local function drawLevelSquaresWithBaseline(self, x, y, baselineLevel, baselineProgress, totalLevel, totalProgress, squareSize, spacing, baselineColor, earnedColor, emptyColor, progressColor)
    squareSize = squareSize or 12
    spacing = spacing or 2
    baselineColor = baselineColor or {r=0.35, g=0.28, b=0.22}
    earnedColor = earnedColor or {r=0.3, g=0.65, b=0.55}
    emptyColor = emptyColor or {r=0.1, g=0.1, b=0.1}
    progressColor = progressColor or {r=0.2, g=0.4, b=0.35}

    for i = 1, 10 do
        local sqX = x + (i - 1) * (squareSize + spacing)

        if i <= baselineLevel then
            -- Fully filled baseline level (dimmed/greyed)
            self:drawRect(sqX, y, squareSize, squareSize, 0.7, baselineColor.r, baselineColor.g, baselineColor.b)
        elseif i == baselineLevel + 1 and i <= totalLevel then
            -- This square transitions from baseline progress to earned
            -- First draw the baseline portion (bottom part, dimmed)
            if baselineProgress > 0 then
                local baselineFillHeight = squareSize * baselineProgress
                self:drawRect(sqX, y + squareSize - baselineFillHeight, squareSize, baselineFillHeight, 0.6, baselineColor.r, baselineColor.g, baselineColor.b)
            end
            -- Then draw the earned portion on top (remaining to fill the square)
            local earnedPortion = 1.0 - baselineProgress
            if earnedPortion > 0 then
                local earnedFillHeight = squareSize * earnedPortion
                self:drawRect(sqX, y, squareSize, earnedFillHeight, 0.9, earnedColor.r, earnedColor.g, earnedColor.b)
            end
        elseif i == baselineLevel + 1 and baselineProgress > 0 and i > totalLevel then
            -- Baseline has partial progress in this square but no earned XP beyond it
            self:drawRect(sqX, y, squareSize, squareSize, 0.5, emptyColor.r, emptyColor.g, emptyColor.b)
            local fillHeight = squareSize * baselineProgress
            self:drawRect(sqX, y + squareSize - fillHeight, squareSize, fillHeight, 0.6, baselineColor.r, baselineColor.g, baselineColor.b)
        elseif i <= totalLevel then
            -- Fully earned level (bright) - beyond baseline
            self:drawRect(sqX, y, squareSize, squareSize, 0.9, earnedColor.r, earnedColor.g, earnedColor.b)
        elseif i == totalLevel + 1 and totalProgress > 0 then
            -- Partial progress on current earned level
            self:drawRect(sqX, y, squareSize, squareSize, 0.5, emptyColor.r, emptyColor.g, emptyColor.b)
            local fillHeight = squareSize * totalProgress
            self:drawRect(sqX, y + squareSize - fillHeight, squareSize, fillHeight, 0.8, progressColor.r, progressColor.g, progressColor.b)
        else
            -- Empty square
            self:drawRect(sqX, y, squareSize, squareSize, 0.5, emptyColor.r, emptyColor.g, emptyColor.b)
        end

        self:drawRectBorder(sqX, y, squareSize, squareSize, 0.3, 0.3, 0.3, 0.3)
    end

    return 10 * squareSize + 9 * spacing
end

-- Helper function to check if an item is in the current batch being recorded
local function isInCurrentBatch(recordingState, itemType, itemName)
    if not recordingState or not recordingState.active or not recordingState.isRecordAll then
        return false
    end
    if not recordingState.pendingRecords then
        return false
    end
    for _, record in ipairs(recordingState.pendingRecords) do
        if record.type == itemType and record.name == itemName then
            return true
        end
    end
    return false
end

-- Helper function to check if an item is in the current batch being absorbed/claimed
local function isInCurrentAbsorbBatch(learningState, itemType, itemName)
    if not learningState or not learningState.active or not learningState.isAbsorbAll then
        return false
    end
    if not learningState.pendingRewards then
        return false
    end
    for _, reward in ipairs(learningState.pendingRewards) do
        if reward.type == itemType and reward.name == itemName then
            return true
        end
    end
    return false
end

local function isEligibleJournalReturnContainer(player, container)
    if not player or not container then return false end
    if container.getType and container:getType() == "floor" then
        return false
    end
    if container.isInCharacterInventory and container:isInCharacterInventory(player) then
        return false
    end
    return true
end

BurdJournals.UI.MainPanel = ISPanel:derive("BurdJournals.UI.MainPanel")
BurdJournals.UI.MainPanel.instance = nil

function BurdJournals.UI.MainPanel:new(x, y, width, height, player, journal, mode)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.playerNum = player and player:getPlayerNum() or 0
    o.journal = journal
    o.mode = mode or "view"
    o.backgroundColor = {r=0.1, g=0.1, b=0.1, a=0.95}
    o.borderColor = {r=0.3, g=0.3, b=0.3, a=1}
    o.moveWithMouse = true

    o.learningState = {
        active = false,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        statId = nil,
        isAbsorbAll = false,
        progress = 0,
        totalTime = 0,
        startTime = 0,
        pendingRewards = {},
        currentIndex = 0,
        queue = {},
    }
    o.learningCompleted = false
    o.processingQueue = false
    o.confirmDialog = nil
    o.borrowReturnContainer = nil

    return o
end

function BurdJournals.UI.MainPanel:initialise()
    ISPanel.initialise(self)
end

function BurdJournals.UI.MainPanel:createTabs(tabs, startY, themeColors)
    local padding = 16
    local tabHeight = 28
    local tabSpacing = 4
    local tabY = startY

    self.tabs = tabs
    self.currentTab = tabs[1] and tabs[1].id or "skills"
    self.tabButtons = {}
    self.tabDefinitions = {}

    local totalWidth = self.width - padding * 2
    local tabCount = #tabs
    local tabWidth = math.floor((totalWidth - (tabSpacing * (tabCount - 1))) / tabCount)

    local tabX = padding
    for i, tab in ipairs(tabs) do
        local isActive = (tab.id == self.currentTab)
        self.tabDefinitions[tab.id] = tab

        local btn = ISButton:new(tabX, tabY, tabWidth, tabHeight, tab.label, self, BurdJournals.UI.MainPanel.onTabClick)
        btn:initialise()
        btn:instantiate()
        btn.internal = tab.id
        btn.tabIndex = i

        self:applyTabButtonStyle(btn, tab.id, isActive)

        self:addChild(btn)
        self.tabButtons[tab.id] = btn

        tabX = tabX + tabWidth + tabSpacing
    end

    self.tabBarY = tabY + tabHeight + 8
    return self.tabBarY
end

function BurdJournals.UI.MainPanel:applyTabButtonStyle(btn, tabId, isActive)
    if not btn then
        return
    end

    local baseTheme = self.tabThemeColors or {
        active = {r=0.35, g=0.28, b=0.18},
        inactive = {r=0.18, g=0.15, b=0.12},
        accent = {r=0.5, g=0.4, b=0.25},
    }
    local tabDef = self.tabDefinitions and self.tabDefinitions[tabId] or nil
    local tabTheme = (tabDef and tabDef.themeColors) or baseTheme

    local activeBg = tabTheme.active or baseTheme.active
    local inactiveBg = tabTheme.inactive or baseTheme.inactive
    local accent = tabTheme.accent or baseTheme.accent
    local activeText = tabTheme.textActive or {r=1, g=1, b=1}
    local inactiveText = tabTheme.textInactive or {r=0.7, g=0.7, b=0.7}

    if isActive then
        btn.backgroundColor = {r=activeBg.r, g=activeBg.g, b=activeBg.b, a=0.9}
        btn.borderColor = {r=accent.r, g=accent.g, b=accent.b, a=1}
        btn.textColor = {r=activeText.r, g=activeText.g, b=activeText.b, a=1}
    else
        btn.backgroundColor = {r=inactiveBg.r, g=inactiveBg.g, b=inactiveBg.b, a=0.62}
        if tabDef and tabDef.themeColors then
            btn.borderColor = {r=math.min(1, accent.r * 0.75), g=math.min(1, accent.g * 0.75), b=math.min(1, accent.b * 0.75), a=0.8}
        else
            btn.borderColor = {r=0.3, g=0.3, b=0.3, a=0.8}
        end
        btn.textColor = {r=inactiveText.r, g=inactiveText.g, b=inactiveText.b, a=1}
    end
end

function BurdJournals.UI.MainPanel:onTabClick(button)
    local tabId = button.internal
    if tabId == self.currentTab then return end

    self.currentTab = tabId

    self:clearSearch()

    self:updateTabStyles()

    self:rebuildFilterTabBar()

    self:refreshCurrentList()
end

function BurdJournals.UI.MainPanel:rebuildFilterTabBar()

    self:cleanupFilterTabBar()

    local filterBarY = self.filterBaseY or self.filterBarY
    if not filterBarY and self.tabBarY then
        filterBarY = self.tabBarY + 32
    elseif not filterBarY then
        filterBarY = 150
    end

    if self.tabThemeColors then
        local newY = self:createFilterTabBar(filterBarY, self.tabThemeColors)
        self:updateTopControlsLayout(newY)
    end
end

function BurdJournals.UI.MainPanel:updateTopControlsLayout(filterEndY)
    if not self.skillList then return end

    local y = filterEndY
    if not y then
        y = self.filterBaseY or self.filterBarY or self.skillList:getY()
        if self.filterBarVisible then
            local filterHeight = BurdJournals.UI.FILTER_TAB_HEIGHT or 22
            y = y + filterHeight + 4
        end
    end

    local searchHeight = 24
    if self.searchEntry then
        self.searchBarY = y
        self.searchEntry:setY(y)
        if self.searchClearBtn then
            local clearSize = self.searchClearBtn:getHeight() or 16
            self.searchClearBtn:setY(y + (searchHeight - clearSize) / 2)
        end
        y = y + searchHeight + 6
    else
        self.searchBarY = nil
    end

    local bottomY = self.listBottomY
    if not bottomY then
        bottomY = self.skillList:getY() + self.skillList:getHeight()
        self.listBottomY = bottomY
    end

    self.skillList:setY(y)
    self.skillList:setHeight(math.max(80, bottomY - y))
end

function BurdJournals.UI.MainPanel:updateTabStyles()
    if not self.tabButtons or not self.tabThemeColors then return end

    for tabId, btn in pairs(self.tabButtons) do
        local isActive = (tabId == self.currentTab)
        self:applyTabButtonStyle(btn, tabId, isActive)
    end
end

function BurdJournals.UI.MainPanel:createSearchBar(startY, themeColors, itemCount)
    local padding = 16
    local searchHeight = 24
    local minItemsForSearch = 5
    local clearButtonSize = 16

    self.searchQuery = ""

    if itemCount < minItemsForSearch then
        self.searchEntry = nil
        self.searchBarY = nil
        self.searchClearBtn = nil
        return startY
    end

    self.searchBarY = startY

    local entryWidth = self.width - padding * 2 - clearButtonSize - 4
    self.searchEntry = ISTextEntryBox:new("", padding, startY, entryWidth, searchHeight)
    self.searchEntry.font = UIFont.Small
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self.searchEntry.backgroundColor = {r=0.08, g=0.08, b=0.1, a=0.9}
    self.searchEntry.borderColor = {r=themeColors.accent.r * 0.7, g=themeColors.accent.g * 0.7, b=themeColors.accent.b * 0.7, a=0.8}

    self.searchEntry.mainPanel = self

    local placeholder = getText("UI_BurdJournals_SearchPlaceholder") or "Search..."
    self.searchEntry:setTooltip(placeholder)

    self.searchEntry.lastSearchText = ""

    self.searchPendingRefresh = false

    self.searchEntry.onTextChange = function()
        local entry = self.searchEntry
        if entry and entry.mainPanel then
            entry.mainPanel.searchPendingRefresh = true
        end
    end

    local origOnOtherKey = self.searchEntry.onOtherKey
    self.searchEntry.onOtherKey = function(entry, key)
        if origOnOtherKey then
            origOnOtherKey(entry, key)
        end
        if entry.mainPanel then
            entry.mainPanel.searchPendingRefresh = true
        end
    end

    self:addChild(self.searchEntry)

    local clearBtnX = padding + entryWidth + 2
    local clearBtnY = startY + (searchHeight - clearButtonSize) / 2
    self.searchClearBtn = ISButton:new(clearBtnX, clearBtnY, clearButtonSize, clearButtonSize, "X", self, BurdJournals.UI.MainPanel.onSearchClearClick)
    self.searchClearBtn:initialise()
    self.searchClearBtn:instantiate()
    self.searchClearBtn.backgroundColor = {r=0.15, g=0.15, b=0.18, a=0.9}
    self.searchClearBtn.backgroundColorMouseOver = {r=0.5, g=0.2, b=0.2, a=0.9}
    self.searchClearBtn.borderColor = {r=0.4, g=0.4, b=0.45, a=0.8}
    self.searchClearBtn.textColor = {r=0.7, g=0.7, b=0.7, a=1}
    self.searchClearBtn:setTooltip(getText("UI_BurdJournals_ClearSearch") or "Clear search")
    self:addChild(self.searchClearBtn)

    return startY + searchHeight + 6
end

function BurdJournals.UI.MainPanel:onSearchClearClick()
    self:clearSearch()
    self:refreshCurrentList()

    if self.searchEntry then
        self.searchEntry:focus()
    end
end

function BurdJournals.UI.MainPanel:clearSearch()
    self.searchQuery = ""
    if self.searchEntry then
        self.searchEntry:setText("")
        self.searchEntry.lastSearchText = ""
    end
end

function BurdJournals.UI.MainPanel:matchesSearch(displayName)
    if not self.searchQuery or self.searchQuery == "" then
        return true
    end
    local query = string.lower(self.searchQuery)
    local name = string.lower(displayName or "")
    return string.find(name, query, 1, true) ~= nil
end

function BurdJournals.UI.MainPanel:initFilterState()
    if not self.filterState then
        self.filterState = {
            skills = {current = "all", sources = {}},
            traits = {current = "all", sources = {}},
            forget = {current = "all", sources = {}},
            recipes = {current = "all", sources = {}},
            stats = {current = "all", sources = {}},
            charinfo = {current = "all", sources = {}},
        }
    end
    self.filterTabButtons = {}
    self.filterScrollOffset = 0
    self.filterBarVisible = false
end

function BurdJournals.UI.MainPanel:createFilterTabBar(startY, themeColors)
    local padding = 16
    local filterHeight = BurdJournals.UI.FILTER_TAB_HEIGHT or 22
    local filterSpacing = BurdJournals.UI.FILTER_TAB_SPACING or 2
    local filterPadding = BurdJournals.UI.FILTER_TAB_PADDING or 8
    local arrowWidth = BurdJournals.UI.FILTER_ARROW_WIDTH or 20

    self:initFilterState()

    local journalData = BurdJournals.getJournalData(self.journal)
    local currentTab = self.currentTab or "skills"
    self.filterState[currentTab] = self.filterState[currentTab] or {current = "all", sources = {}}
    local sources = BurdJournals.collectModSources(currentTab, journalData, self.player, self.mode)
    if type(sources) ~= "table" then
        sources = {}
    end

    self.filterState[currentTab].sources = sources

    if #sources <= 2 then

        self.filterBarVisible = false
        self.filterTotalTabWidth = 0
        self.filterAvailableWidth = 0
        self.filterScrollMax = 0
        self:cleanupFilterTabBar()
        return startY
    end

    self.filterBarVisible = true
    self.filterBarY = startY

    local availableWidth = self.width - padding * 2 - arrowWidth * 2

    local tabX = padding + arrowWidth
    local totalTabWidth = 0

    for _, sourceData in ipairs(sources) do
        local label = sourceData.source
        if sourceData.source ~= "All" then
            label = sourceData.source .. " (" .. sourceData.count .. ")"
        end
        local textWidth = getTextManager():MeasureStringX(UIFont.Small, label)
        totalTabWidth = totalTabWidth + textWidth + filterPadding * 2 + filterSpacing
    end
    totalTabWidth = totalTabWidth - filterSpacing

    local needsScrolling = totalTabWidth > availableWidth
    self.filterNeedsScrolling = needsScrolling
    self.filterTotalTabWidth = totalTabWidth
    self.filterAvailableWidth = availableWidth
    self.filterScrollMax = math.max(0, totalTabWidth - availableWidth)
    self.filterScrollOffset = math.max(0, math.min(tonumber(self.filterScrollOffset) or 0, self.filterScrollMax))

    if needsScrolling then

        if not self.filterScrollLeftBtn then
            self.filterScrollLeftBtn = ISButton:new(padding, startY, arrowWidth, filterHeight, "<", self, BurdJournals.UI.MainPanel.onFilterScrollLeft)
            self.filterScrollLeftBtn:initialise()
            self.filterScrollLeftBtn:instantiate()
            self.filterScrollLeftBtn.backgroundColor = {r=0.15, g=0.15, b=0.18, a=0.8}
            self.filterScrollLeftBtn.borderColor = {r=0.3, g=0.3, b=0.35, a=0.8}
            self.filterScrollLeftBtn.textColor = {r=0.7, g=0.7, b=0.7, a=1}
            self:addChild(self.filterScrollLeftBtn)
        else
            self.filterScrollLeftBtn:setVisible(true)
            self.filterScrollLeftBtn:setY(startY)
        end

        if not self.filterScrollRightBtn then
            self.filterScrollRightBtn = ISButton:new(self.width - padding - arrowWidth, startY, arrowWidth, filterHeight, ">", self, BurdJournals.UI.MainPanel.onFilterScrollRight)
            self.filterScrollRightBtn:initialise()
            self.filterScrollRightBtn:instantiate()
            self.filterScrollRightBtn.backgroundColor = {r=0.15, g=0.15, b=0.18, a=0.8}
            self.filterScrollRightBtn.borderColor = {r=0.3, g=0.3, b=0.35, a=0.8}
            self.filterScrollRightBtn.textColor = {r=0.7, g=0.7, b=0.7, a=1}
            self:addChild(self.filterScrollRightBtn)
        else
            self.filterScrollRightBtn:setVisible(true)
            self.filterScrollRightBtn:setY(startY)
        end
    else

        if self.filterScrollLeftBtn then
            self.filterScrollLeftBtn:setVisible(false)
        end
        if self.filterScrollRightBtn then
            self.filterScrollRightBtn:setVisible(false)
        end

        tabX = padding + (self.width - padding * 2 - totalTabWidth) / 2
    end

    local currentFilter = self.filterState[currentTab].current or "all"
    local filterExists = (currentFilter == "all")
    if not filterExists then
        for _, sourceData in ipairs(sources) do
            local sourceId = sourceData.sourceId or string.lower(sourceData.source or "")
            if sourceId == currentFilter then
                filterExists = true
                break
            end
        end
    end
    if not filterExists then
        currentFilter = "all"
        self.filterState[currentTab].current = "all"
    end
    local btnX = tabX - self.filterScrollOffset

    for i, sourceData in ipairs(sources) do
        local label = sourceData.source
        if sourceData.source ~= "All" then
            label = sourceData.source .. " (" .. sourceData.count .. ")"
        end
        local textWidth = getTextManager():MeasureStringX(UIFont.Small, label)
        local btnWidth = textWidth + filterPadding * 2

        local sourceId = sourceData.sourceId or string.lower(sourceData.source or "")
        local isActive = sourceId == currentFilter

        local btn = ISButton:new(btnX, startY, btnWidth, filterHeight, label, self, BurdJournals.UI.MainPanel.onFilterTabClick)
        btn:initialise()
        btn:instantiate()
        btn.internal = sourceId
        btn.filterIndex = i
        btn.font = UIFont.Small

        if isActive then
            btn.backgroundColor = {r=themeColors.active.r, g=themeColors.active.g, b=themeColors.active.b, a=0.85}
            btn.borderColor = {r=themeColors.accent.r, g=themeColors.accent.g, b=themeColors.accent.b, a=1}
            btn.textColor = {r=1, g=1, b=1, a=1}
        else
            btn.backgroundColor = {r=themeColors.inactive.r, g=themeColors.inactive.g, b=themeColors.inactive.b, a=0.5}
            btn.borderColor = {r=0.25, g=0.25, b=0.25, a=0.6}
            btn.textColor = {r=0.6, g=0.6, b=0.6, a=1}
        end

        self:addChild(btn)
        table.insert(self.filterTabButtons, btn)

        btnX = btnX + btnWidth + filterSpacing
    end

    self:updateFilterTabPositions()
    return startY + filterHeight + 4
end

function BurdJournals.UI.MainPanel:onFilterTabClick(button)
    local filterId = button.internal
    local currentTab = self.currentTab or "skills"

    if filterId == self.filterState[currentTab].current then
        return
    end

    self.filterState[currentTab].current = filterId

    self:updateFilterTabStyles()

    self:refreshCurrentList()
end

function BurdJournals.UI.MainPanel:updateFilterTabStyles()
    if not self.filterTabButtons or not self.tabThemeColors then return end

    local themeColors = self.tabThemeColors
    local currentTab = self.currentTab or "skills"
    local currentFilter = self.filterState[currentTab].current or "all"

    for _, btn in ipairs(self.filterTabButtons) do
        local isActive = btn.internal == currentFilter
        if isActive then
            btn.backgroundColor = {r=themeColors.active.r, g=themeColors.active.g, b=themeColors.active.b, a=0.85}
            btn.borderColor = {r=themeColors.accent.r, g=themeColors.accent.g, b=themeColors.accent.b, a=1}
            btn.textColor = {r=1, g=1, b=1, a=1}
        else
            btn.backgroundColor = {r=themeColors.inactive.r, g=themeColors.inactive.g, b=themeColors.inactive.b, a=0.5}
            btn.borderColor = {r=0.25, g=0.25, b=0.25, a=0.6}
            btn.textColor = {r=0.6, g=0.6, b=0.6, a=1}
        end
    end
end

function BurdJournals.UI.MainPanel:onFilterScrollLeft()
    local maxOffset = math.max(0, tonumber(self.filterScrollMax) or 0)
    self.filterScrollOffset = math.max(0, math.min(maxOffset, (tonumber(self.filterScrollOffset) or 0) - 50))
    self:updateFilterTabPositions()
end

function BurdJournals.UI.MainPanel:onFilterScrollRight()
    local maxOffset = math.max(0, tonumber(self.filterScrollMax) or 0)
    self.filterScrollOffset = math.max(0, math.min(maxOffset, (tonumber(self.filterScrollOffset) or 0) + 50))
    self:updateFilterTabPositions()
end

function BurdJournals.UI.MainPanel:updateFilterTabPositions()
    if not self.filterTabButtons then return end

    local padding = 16
    local arrowWidth = BurdJournals.UI.FILTER_ARROW_WIDTH or 20
    local filterSpacing = BurdJournals.UI.FILTER_TAB_SPACING or 2

    local needsScrolling = self.filterNeedsScrolling == true
    local leftEdge = padding + (needsScrolling and arrowWidth or 0)
    local rightEdge = self.width - padding - (needsScrolling and arrowWidth or 0)
    local tabX = leftEdge - (tonumber(self.filterScrollOffset) or 0)

    for _, btn in ipairs(self.filterTabButtons) do
        btn:setX(tabX)
        if needsScrolling then
            local btnRight = tabX + btn:getWidth()
            -- Hide partially-clipped tabs so they never overlap nav arrows.
            btn:setVisible(tabX >= leftEdge and btnRight <= rightEdge)
        else
            btn:setVisible(true)
        end
        tabX = tabX + btn:getWidth() + filterSpacing
    end

    local maxOffset = math.max(0, tonumber(self.filterScrollMax) or 0)
    self.filterScrollOffset = math.max(0, math.min(maxOffset, tonumber(self.filterScrollOffset) or 0))
end

function BurdJournals.UI.MainPanel:cleanupFilterTabBar()
    if self.filterTabButtons then
        for _, btn in ipairs(self.filterTabButtons) do
            self:removeChild(btn)
        end
        self.filterTabButtons = {}
    end

    if self.filterScrollLeftBtn then
        self.filterScrollLeftBtn:setVisible(false)
    end
    if self.filterScrollRightBtn then
        self.filterScrollRightBtn:setVisible(false)
    end

    self.filterScrollOffset = 0
end

function BurdJournals.UI.MainPanel:passesFilter(modSource)
    local currentTab = self.currentTab or "skills"
    if not self.filterState or not self.filterState[currentTab] then
        return true
    end

    local currentFilter = self.filterState[currentTab].current or "all"
    if currentFilter == "all" then
        return true
    end

    local normalizedSource = nil
    if BurdJournals.normalizeFilterSourceId then
        normalizedSource = BurdJournals.normalizeFilterSourceId(modSource)
    else
        normalizedSource = string.lower(modSource or "Vanilla")
    end
    return normalizedSource == currentFilter
end

function BurdJournals.UI.MainPanel:refreshCurrentList()
    if self.mode == "log" then
        self:populateRecordList()
    elseif self.mode == "view" then
        self:populateViewList()
    elseif self.mode == "absorb" then
        self:populateAbsorptionList()
    end
end

function BurdJournals.UI.MainPanel:getHeaderJournalUUID()
    if self.mode ~= "log" and self.mode ~= "view" and self.mode ~= "absorb" then
        return nil
    end
    if not self.journal then
        return nil
    end

    local journalData = BurdJournals.getJournalData and BurdJournals.getJournalData(self.journal) or nil
    if type(journalData) ~= "table" then
        return nil
    end

    local uuid = tostring(journalData.uuid or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if uuid == "" then
        return nil
    end
    return uuid
end

local function getLocalizedHeaderText(key, fallback)
    local value = getText and getText(key) or nil
    if not value or value == key then
        return fallback
    end
    return value
end

function BurdJournals.UI.MainPanel:updateHeaderUUIDTooltip()
    local uuid = self:getHeaderJournalUUID()
    self.headerJournalUUID = uuid

    local tooltipTemplate = getText("UI_BurdJournals_UUIDTooltip") or "Journal UUID: %s"
    local tooltip = uuid and string.format(tooltipTemplate, uuid) or nil

    if self.headerUuidBadgeBtn then
        self.headerUuidBadgeBtn.tooltip = tooltip
        self.headerUuidBadgeBtn:setVisible(uuid ~= nil)
    end
end

function BurdJournals.UI.MainPanel:onHeaderCopyUUID()
    local uuid = self.headerJournalUUID or self:getHeaderJournalUUID()
    if not uuid then
        self:showFeedback(getText("UI_BurdJournals_UUIDMissing") or "No journal UUID available", {r=1, g=0.6, b=0.3})
        return
    end

    local copied = false
    uuid = tostring(uuid)
    if Clipboard and Clipboard.setClipboard then
        Clipboard.setClipboard(uuid)
        copied = true
    end

    if not copied then
        local core = getCore and getCore() or nil
        if core and core.setClipboard then
            core:setClipboard(uuid)
            copied = true
        end
    end

    if copied then
        self:showFeedback(getText("UI_BurdJournals_UUIDCopied") or "Journal UUID copied", {r=0.3, g=1, b=0.5})
    else
        local fallbackTemplate = getText("UI_BurdJournals_UUIDCopyUnavailable") or "Clipboard unavailable. UUID: %s"
        self:showFeedback(string.format(fallbackTemplate, uuid), {r=0.95, g=0.8, b=0.35})
    end
end

function BurdJournals.UI.MainPanel:getHeaderJournalStateInfo()
    if self.mode ~= "log" and self.mode ~= "view" then
        return nil
    end
    if not self.journal then
        return nil
    end

    local journalData = BurdJournals.getJournalData and BurdJournals.getJournalData(self.journal) or nil
    if type(journalData) ~= "table" then
        return nil
    end

    local isPlayerJournal = journalData.isPlayerCreated == true
    if not isPlayerJournal and journalData.isPlayerCreated == nil then
        local hasOwner = journalData.ownerUsername or journalData.ownerSteamId or journalData.ownerCharacterName
        if hasOwner and journalData.isWorn ~= true and journalData.isBloody ~= true then
            isPlayerJournal = true
        end
    end

    if not isPlayerJournal then
        return nil
    end

    local isRestored = BurdJournals.isRestoredJournalData and BurdJournals.isRestoredJournalData(journalData) or false
    local allowDissolution = BurdJournals.getSandboxOption and BurdJournals.getSandboxOption("AllowPlayerJournalDissolution") == true

    if isRestored then
        local tooltipKey = allowDissolution
            and "UI_BurdJournals_BadgeStateTooltipRestoredDissolveOn"
            or "UI_BurdJournals_BadgeStateTooltipRestoredDissolveOff"
        local tooltipFallback = allowDissolution
            and "Restored journal: One-time claims are enabled and this journal auto-dissolves after all rewards are claimed."
            or "Restored journal (persistent mode): 'Allow Player Journal Dissolution' is OFF, so rewards are reusable and this journal does not auto-dissolve."
        return {
            label = getLocalizedHeaderText("UI_BurdJournals_BadgeRestored", "RESTORED"),
            tooltip = getLocalizedHeaderText(tooltipKey, tooltipFallback),
            borderColor = {r=0.60, g=0.45, b=0.22, a=1},
            backgroundColor = {r=0.36, g=0.26, b=0.10, a=0.85},
            textColor = {r=1, g=0.93, b=0.78, a=1},
        }
    end

    return {
        label = getLocalizedHeaderText("UI_BurdJournals_BadgePersistent", "PERSISTENT"),
        tooltip = getLocalizedHeaderText(
            "UI_BurdJournals_BadgeStateTooltipPersistent",
            "Persistent journal: Rewards are reusable and this journal does not auto-dissolve."
        ),
        borderColor = {r=0.22, g=0.58, b=0.70, a=1},
        backgroundColor = {r=0.10, g=0.27, b=0.35, a=0.85},
        textColor = {r=0.86, g=0.98, b=1, a=1},
    }
end

function BurdJournals.UI.MainPanel:onHeaderStateBadge()
    -- Intentionally no-op: badge exists for quick status and tooltip visibility.
end

function BurdJournals.UI.MainPanel:createHeaderRefreshButton(rightMargin, y)
    local function removeControl(control)
        if not control then return end
        if self.removeChild then
            self:removeChild(control)
        end
        if control.removeFromUIManager then
            control:removeFromUIManager()
        end
    end

    removeControl(self.headerRefreshBtn)
    removeControl(self.headerCopyUuidBtn)
    removeControl(self.headerUuidBadgeBtn)
    removeControl(self.headerStateBadgeBtn)
    self.headerRefreshBtn = nil
    self.headerCopyUuidBtn = nil
    self.headerUuidBadgeBtn = nil
    self.headerStateBadgeBtn = nil

    -- Backward cleanup for any stale controls left behind by older UI builds.
    if self.children and type(self.children) == "table" then
        for i = #self.children, 1, -1 do
            local child = self.children[i]
            if child and child.bsjHeaderControl then
                removeControl(child)
            end
        end
    end

    local margin = tonumber(rightMargin) or 10
    local btnY = tonumber(y) or 15
    local refreshText = getText("UI_BurdJournals_BtnRefresh") or "Refresh"
    local refreshW = math.max(64, getTextManager():MeasureStringX(UIFont.Small, refreshText) + 14)
    local refreshH = 22
    local refreshX = self.width - margin - refreshW

    -- Derive button colors from the journal's header theme so Worn & Bloody panels
    -- get colors that match their red/brown identity instead of the default blue.
    local accent = self.headerAccent
    local btnColors
    if accent then
        -- Scale the accent color: border uses full accent, bg is darker, text is near-white tinted
        btnColors = {
            border      = {r=accent.r,           g=accent.g,           b=accent.b,           a=1},
            background  = {r=accent.r * 0.35,    g=accent.g * 0.35,    b=accent.b * 0.35,    a=0.85},
            text        = {r=0.95 + accent.r * 0.05, g=0.9 + accent.g * 0.05, b=0.9 + accent.b * 0.05, a=1},
        }
    else
        -- Default blue theme (player journals)
        btnColors = {
            border      = {r=0.35, g=0.55, b=0.7,  a=1},
            background  = {r=0.12, g=0.26, b=0.34, a=0.85},
            text        = {r=0.9,  g=0.98, b=1,    a=1},
        }
    end

    self.headerRefreshBtn = ISButton:new(refreshX, btnY, refreshW, refreshH, refreshText, self, BurdJournals.UI.MainPanel.onHeaderRefresh)
    self.headerRefreshBtn:initialise()
    self.headerRefreshBtn:instantiate()
    self.headerRefreshBtn.font = UIFont.Small
    self.headerRefreshBtn.borderColor = btnColors.border
    self.headerRefreshBtn.backgroundColor = btnColors.background
    self.headerRefreshBtn.textColor = btnColors.text
    self.headerRefreshBtn.tooltip = getText("UI_BurdJournals_RefreshTooltip") or "Refresh journal data"
    self.headerRefreshBtn.bsjHeaderControl = true
    self:addChild(self.headerRefreshBtn)

    local spacing = 6
    local cursorX = refreshX - spacing
    local consumed = refreshW + 12

    local uuid = self:getHeaderJournalUUID()
    if uuid then
        local badgeText = getText("UI_BurdJournals_UUIDBadge") or "UUID"

        local badgeW = math.max(42, getTextManager():MeasureStringX(UIFont.Small, badgeText) + 16)
        local badgeX = cursorX - badgeW
        self.headerUuidBadgeBtn = ISButton:new(badgeX, btnY, badgeW, refreshH, badgeText, self, BurdJournals.UI.MainPanel.onHeaderCopyUUID)
        self.headerUuidBadgeBtn:initialise()
        self.headerUuidBadgeBtn:instantiate()
        self.headerUuidBadgeBtn.font = UIFont.Small
        self.headerUuidBadgeBtn.borderColor = btnColors.border
        self.headerUuidBadgeBtn.backgroundColor = btnColors.background
        self.headerUuidBadgeBtn.textColor = btnColors.text
        self.headerUuidBadgeBtn.bsjHeaderControl = true
        self:addChild(self.headerUuidBadgeBtn)

        cursorX = badgeX - spacing
        consumed = consumed + badgeW + spacing
    end

    local stateInfo = self:getHeaderJournalStateInfo()
    if stateInfo and stateInfo.label then
        local stateW = math.max(78, getTextManager():MeasureStringX(UIFont.Small, stateInfo.label) + 18)
        local stateX = cursorX - stateW
        self.headerStateBadgeBtn = ISButton:new(stateX, btnY, stateW, refreshH, stateInfo.label, self, BurdJournals.UI.MainPanel.onHeaderStateBadge)
        self.headerStateBadgeBtn:initialise()
        self.headerStateBadgeBtn:instantiate()
        self.headerStateBadgeBtn.font = UIFont.Small
        self.headerStateBadgeBtn.borderColor = stateInfo.borderColor or {r=0.25, g=0.55, b=0.7, a=1}
        self.headerStateBadgeBtn.backgroundColor = stateInfo.backgroundColor or {r=0.10, g=0.26, b=0.34, a=0.85}
        self.headerStateBadgeBtn.textColor = stateInfo.textColor or {r=0.9, g=0.98, b=1, a=1}
        self.headerStateBadgeBtn.tooltip = stateInfo.tooltip
        self.headerStateBadgeBtn.bsjHeaderControl = true
        self:addChild(self.headerStateBadgeBtn)

        consumed = consumed + stateW + spacing
    end

    local inset = consumed + 8
    self.headerRightInset = inset
    self:updateHeaderUUIDTooltip()
    return margin + inset
end

function BurdJournals.UI.MainPanel:onHeaderRefresh()
    self:refreshPlayer()

    -- Match close/reopen behavior: clear transient UI session state.
    self.pendingClaims = {skills = {}, traits = {}, recipes = {}}
    self.sessionClaimedSkills = {}
    self.sessionClaimedTraits = {}
    if self.learningState then
        self.learningState.claimSessionId = nil
    end

    if self.journal then
        if isClient() and not isServer() then
            if BurdJournals.Client and BurdJournals.Client.sendToServer then
                BurdJournals.Client.sendToServer("sanitizeJournal", {
                    journalId = self.journal:getID()
                })
                BurdJournals.Client.sendToServer("requestXpSync", {})
            end
        else
            if BurdJournals.sanitizeJournalData then
                BurdJournals.sanitizeJournalData(self.journal, self.player)
            end
            if BurdJournals.migrateJournalIfNeeded then
                BurdJournals.migrateJournalIfNeeded(self.journal, self.player)
            end
            if BurdJournals.compactJournalData then
                BurdJournals.compactJournalData(self.journal)
            end
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end
    end

    if self.refreshJournalData then
        self:refreshJournalData()
    else
        self:refreshCurrentList()
    end
    if self.forceCurrentTabRebuild then
        self:forceCurrentTabRebuild()
    end

    -- MP refresh is async; schedule a few follow-up refresh passes so UI updates
    -- after server sanitize/xp-sync responses land.
    if self._headerRefreshTickHandler then
        BurdJournals.safeRemoveEvent(Events.OnTick, self._headerRefreshTickHandler)
        self._headerRefreshTickHandler = nil
    end
    local panelRef = self
    local ticks = 0
    local nextCheckpointIndex = 1
    local checkpoints = {6, 18, 36}
    local function delayedRefresh()
        ticks = ticks + 1
        if not panelRef or not panelRef:getIsVisible() then
            BurdJournals.safeRemoveEvent(Events.OnTick, delayedRefresh)
            if panelRef then panelRef._headerRefreshTickHandler = nil end
            return
        end
        if ticks >= checkpoints[nextCheckpointIndex] then
            if panelRef.refreshJournalData then
                panelRef:refreshJournalData()
            else
                panelRef:refreshCurrentList()
            end
            if panelRef.forceCurrentTabRebuild then
                panelRef:forceCurrentTabRebuild()
            end
            nextCheckpointIndex = nextCheckpointIndex + 1
            if nextCheckpointIndex > #checkpoints then
                BurdJournals.safeRemoveEvent(Events.OnTick, delayedRefresh)
                panelRef._headerRefreshTickHandler = nil
            end
        end
    end
    self._headerRefreshTickHandler = delayedRefresh
    Events.OnTick.Add(delayedRefresh)

    self:showFeedback(getText("UI_BurdJournals_JournalRefreshed") or "Journal refreshed", {r=0.5, g=0.8, b=1})
end

-- Force a full list rebuild by cycling tabs the same way manual tab switching does.
-- This mirrors the user-discovered "switch tabs to refresh correctly" behavior.
function BurdJournals.UI.MainPanel:forceCurrentTabRebuild()
    if not self.tabs or #self.tabs <= 1 then
        if self.refreshCurrentList then
            self:refreshCurrentList()
        end
        return
    end

    local originalTab = self.currentTab or (self.tabs[1] and self.tabs[1].id)
    if not originalTab then
        return
    end

    local altTab = nil
    for _, tab in ipairs(self.tabs) do
        if tab.id ~= originalTab then
            altTab = tab.id
            break
        end
    end

    if not altTab then
        if self.refreshCurrentList then
            self:refreshCurrentList()
        end
        return
    end

    self.currentTab = altTab
    if self.updateTabStyles then self:updateTabStyles() end
    if self.rebuildFilterTabBar then self:rebuildFilterTabBar() end
    if self.refreshCurrentList then self:refreshCurrentList() end

    self.currentTab = originalTab
    if self.updateTabStyles then self:updateTabStyles() end
    if self.rebuildFilterTabBar then self:rebuildFilterTabBar() end
    if self.refreshCurrentList then self:refreshCurrentList() end
end

function BurdJournals.UI.MainPanel:createChildren()
    ISPanel.createChildren(self)
    
    -- Register this panel for baseline change notifications
    self:registerOpenPanel()

    -- In MP, request server to sanitize the journal (server-authoritative)
    -- In SP/host, sanitize directly
    if self.journal then
        if isClient() and not isServer() then
            -- MP: Request server to sanitize and check dissolution
            if BurdJournals.Client and BurdJournals.Client.sendToServer then
                local journalId = self.journal:getID()
                BurdJournals.Client.sendToServer("sanitizeJournal", {
                    journalId = journalId
                })
                -- Keep any filled-journal open in sync with deferred UUID edits and update server UUID index/cache.
                local shouldSync = journalId and BurdJournals.isFilledJournal and BurdJournals.isFilledJournal(self.journal)
                if shouldSync then
                    BurdJournals.Client.sendToServer("syncJournalData", {
                        journalId = journalId
                    })
                end
            end
            -- Server will send back result if journal was dissolved
        else
            -- SP/host: Sanitize directly
            if BurdJournals.sanitizeJournalData then
                local sanitizeResult = BurdJournals.sanitizeJournalData(self.journal, self.player)
                if sanitizeResult and sanitizeResult.cleaned then
                    BurdJournals.debugPrint("[BurdJournals] MainPanel: Journal sanitized on open")
                    -- Transmit changes in SP/host
                    if self.journal.transmitModData then
                        self.journal:transmitModData()
                    end
                end
            end
        end

        -- Run migration if needed
        if BurdJournals.migrateJournalIfNeeded then
            -- In MP, migration should also go through server
            if isClient() and not isServer() then
                -- Server handles migration during sanitize command
            else
                BurdJournals.migrateJournalIfNeeded(self.journal, self.player)
            end
        end

        -- SP/host patch safety: restore DR counters if item ModData lost them during update.
        if not (isClient() and not isServer()) and BurdJournals.restoreJournalDRStateIfMissing then
            BurdJournals.restoreJournalDRStateIfMissing(self.journal, "mainPanelCreate", self.player)
        end
        if not (isClient() and not isServer()) and BurdJournals.captureJournalDRState then
            BurdJournals.captureJournalDRState(self.journal, "mainPanelCreateSeed", self.player)
        end
    end

    self:playSound(BurdJournals.Sounds.OPEN_JOURNAL)

    if self.mode == "absorb" then
        self:createAbsorptionUI()
    elseif self.mode == "log" then
        self:createLogUI()
    else
        self:createViewUI()
    end
end

function BurdJournals.UI.MainPanel:refreshPlayer()

    local freshPlayer = getSpecificPlayer(self.playerNum)
    if freshPlayer then
        self.player = freshPlayer
    end
end

function BurdJournals.UI.MainPanel:ensureDebugJournalDataRestored()
    if not self.journal then return end

    local journalData = BurdJournals.getJournalData(self.journal)
    if not journalData then return end

    local isDebugJournal = journalData.isDebugSpawned or journalData.isDebugEdited
    if not isDebugJournal then
        self._pendingDebugRestoreKey = nil
        return
    end

    local hasData = BurdJournals.hasAnyEntries(journalData.skills)
        or BurdJournals.hasAnyEntries(journalData.traits)
        or BurdJournals.hasAnyEntries(journalData.recipes)
        or BurdJournals.hasAnyEntries(journalData.stats)

    if hasData then
        self._pendingDebugRestoreKey = nil
        return
    end

    local journalKey = journalData.uuid or tostring(self.journal:getID())
    if not journalKey then return end

    if self._pendingDebugRestoreKey and BurdJournals.Client and not BurdJournals.Client._pendingDebugJournalRestore then
        self._pendingDebugRestoreKey = nil
    end
    if self._pendingDebugRestoreKey == journalKey then return end

    if BurdJournals.Client and BurdJournals.Client.requestDebugJournalBackup then
        self._pendingDebugRestoreKey = journalKey
        BurdJournals.Client.requestDebugJournalBackup(self.journal, journalKey)
        BurdJournals.debugPrint("[BurdJournals] MainPanel: requested debug journal restore for key=" .. tostring(journalKey))
    end
end

function BurdJournals.UI.MainPanel:refreshJournalData()

    self:refreshPlayer()
    self:ensureDebugJournalDataRestored()

    if self.pendingNewJournalId then
        BurdJournals.debugPrint("[BurdJournals] refreshJournalData: Checking for pending journal ID " .. tostring(self.pendingNewJournalId))
        local newJournal = BurdJournals.findItemById(self.player, self.pendingNewJournalId)
        if newJournal then
            BurdJournals.debugPrint("[BurdJournals] refreshJournalData: Found pending journal! Updating reference.")
            self.journal = newJournal
            self.pendingNewJournalId = nil
        else
            BurdJournals.debugPrint("[BurdJournals] refreshJournalData: Pending journal still not found")
        end
    end

    if not self.journal or not self.journal:getContainer() then
        BurdJournals.debugPrint("[BurdJournals] refreshJournalData: Journal invalid, trying to find by ID")

        if self.pendingNewJournalId then
            local journal = BurdJournals.findItemById(self.player, self.pendingNewJournalId)
            if journal then
                self.journal = journal
                self.pendingNewJournalId = nil
            end
        end
    end

    if self.mode == "log" then

        if self.skillList then
            if self.populateRecordList then
                self:populateRecordList()
            end
        end
    elseif self.mode == "view" then

        if self.skillList then
            if self.populateViewList then
                self:populateViewList()
            end
        end
    elseif self.mode == "absorb" then
        -- Note: the list is called skillList, not absorbList
        if self.skillList then
            if self.refreshAbsorptionList then
                self:refreshAbsorptionList()
            end
        end
    end

    self:updateHeaderUUIDTooltip()
end

function BurdJournals.UI.MainPanel:createAbsorptionUI()

    self:refreshPlayer()

    local padding = 16
    local y = 0
    local btnHeight = 32

    local isBloody = BurdJournals.isBloody(self.journal)
    local hasBloodyOrigin = BurdJournals.hasBloodyOrigin(self.journal)
    local journalData = BurdJournals.getJournalData(self.journal)
    local isCursedReward = journalData and journalData.isCursedReward == true

    self.isBloody = isBloody
    self.hasBloodyOrigin = hasBloodyOrigin
    self.isCursedReward = isCursedReward

    local headerHeight = 52
    self.headerRightInset = 0

    local function getFlavorText(data, fallbackKey)
        if data and data.flavorKey then
            local translated = getText(data.flavorKey)
            if translated and translated ~= data.flavorKey then
                return translated
            end
        end

        if data and data.flavorText then
            return data.flavorText
        end

        return getText(fallbackKey)
    end

    if isCursedReward then
        self.headerColor = {r=0.40, g=0.18, b=0.38}
        self.headerAccent = {r=0.78, g=0.42, b=0.68}
        self.typeText = getText("UI_BurdJournals_CursedJournalHeader")
        self.rarityText = getText("UI_BurdJournals_RarityCursed")
        self.flavorText = getFlavorText(journalData, "UI_BurdJournals_CursedFlavor")
    elseif isBloody then
        self.headerColor = {r=0.45, g=0.08, b=0.08}
        self.headerAccent = {r=0.7, g=0.15, b=0.15}
        self.typeText = getText("UI_BurdJournals_BloodyJournalHeader")
        self.rarityText = getText("UI_BurdJournals_RarityRare")
        self.flavorText = getFlavorText(journalData, "UI_BurdJournals_BloodyFlavor")
    elseif hasBloodyOrigin then
        self.headerColor = {r=0.30, g=0.22, b=0.12}
        self.headerAccent = {r=0.5, g=0.35, b=0.2}
        self.typeText = getText("UI_BurdJournals_WornJournalHeader")
        self.rarityText = getText("UI_BurdJournals_RarityUncommon")
        self.flavorText = getFlavorText(journalData, "UI_BurdJournals_WornBloodyFlavor")
    else
        self.headerColor = {r=0.22, g=0.20, b=0.15}
        self.headerAccent = {r=0.4, g=0.35, b=0.25}
        self.typeText = getText("UI_BurdJournals_WornJournalHeader")
        self.rarityText = nil
        self.flavorText = getFlavorText(journalData, "UI_BurdJournals_WornFlavor")
    end
    self.headerIconTexture = getHeaderJournalIconTexture("absorb", self.journal, journalData, isBloody)
    self.headerIconSize = 20
    self.headerHeight = headerHeight
    self:createHeaderRefreshButton(10, 15)
    y = headerHeight + 6

    local authorName = journalData and journalData.author or getText("UI_BurdJournals_UnknownSurvivor")
    self.authorName = authorName
    self.authorBoxY = y
    self.authorBoxHeight = 44
    y = y + self.authorBoxHeight + 10

    local skillCount = 0
    local totalSkillCount = 0
    local traitCount = 0
    local totalTraitCount = 0
    local forgetCount = 0
    local totalForgetCount = 0
    local recipeCount = 0
    local totalRecipeCount = 0
    local totalXP = 0

    if journalData and journalData.skills then
        for skillName, skillData in pairs(journalData.skills) do
            if isSkillVisibleForJournal(journalData, skillName) then
                totalSkillCount = totalSkillCount + 1
                if not BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName) then
                    skillCount = skillCount + 1
                    totalXP = totalXP + (skillData.xp or 0)
                end
            end
        end
    end
    -- Count traits if journal is from bloody origin OR debug spawned
    local isDebugJournal = journalData and journalData.isDebugSpawned
    if (hasBloodyOrigin or isDebugJournal) and journalData and journalData.traits then
        for traitId, _ in pairs(journalData.traits) do
            totalTraitCount = totalTraitCount + 1
            if not BurdJournals.hasCharacterClaimedTrait(journalData, self.player, traitId) then
                traitCount = traitCount + 1
            end
        end
    end
    local hasForgetSlot = journalData and journalData.forgetSlot == true
        and BurdJournals.isForgetSlotEnabledForJournal
        and BurdJournals.isForgetSlotEnabledForJournal(journalData)
    local forgetClaimed = hasForgetSlot
        and BurdJournals.hasCharacterClaimedForgetSlot
        and BurdJournals.hasCharacterClaimedForgetSlot(journalData, self.player)
    if hasForgetSlot and not forgetClaimed then
        local removableTraits = BurdJournals.getPlayerRemovableTraits and BurdJournals.getPlayerRemovableTraits(self.player) or {}
        totalForgetCount = #removableTraits
        forgetCount = #removableTraits
    end
    if journalData and journalData.recipes then
        for recipeName, _ in pairs(journalData.recipes) do
            totalRecipeCount = totalRecipeCount + 1
            if not BurdJournals.hasCharacterClaimedRecipe(journalData, self.player, recipeName) then
                recipeCount = recipeCount + 1
            end
        end
    end

    self.skillCount = skillCount
    self.traitCount = traitCount
    self.forgetCount = forgetCount
    self.recipeCount = recipeCount
    self.totalXP = totalXP

    local tabs = {{id = "skills", label = getText("UI_BurdJournals_TabSkills")}}
    -- Check if this is a debug-spawned journal (bypasses origin restrictions)
    local isDebugSpawned = journalData and journalData.isDebugSpawned
    -- Only show traits tab if enabled and journal has traits (or debug spawned)
    if (hasBloodyOrigin or isDebugSpawned) and totalTraitCount > 0 and BurdJournals.areTraitsEnabledForJournal(journalData) then
        table.insert(tabs, {id = "traits", label = getText("UI_BurdJournals_TabTraits")})
    end
    if hasForgetSlot and not forgetClaimed then
        table.insert(tabs, {
            id = "forget",
            label = getText("UI_BurdJournals_TabForget") or "Forget",
            themeColors = {
                active = {r=0.52, g=0.20, b=0.56},
                inactive = {r=0.22, g=0.10, b=0.26},
                accent = {r=0.93, g=0.60, b=0.28},
                textInactive = {r=0.88, g=0.72, b=0.84},
            }
        })
    end
    -- Only show recipes tab if enabled and journal has recipes
    if totalRecipeCount > 0 and BurdJournals.areRecipesEnabledForJournal(journalData) then
        table.insert(tabs, {id = "recipes", label = getText("UI_BurdJournals_TabRecipes")})
    end

    local tabThemeColors
    if isCursedReward then
        tabThemeColors = {
            active = {r=0.45, g=0.21, b=0.44},
            inactive = {r=0.22, g=0.12, b=0.24},
            accent = {r=0.78, g=0.42, b=0.68}
        }
    elseif isBloody then
        tabThemeColors = {
            active = {r=0.5, g=0.15, b=0.15},
            inactive = {r=0.2, g=0.1, b=0.1},
            accent = {r=0.7, g=0.2, b=0.2}
        }
    else
        tabThemeColors = {
            active = {r=0.35, g=0.28, b=0.18},
            inactive = {r=0.18, g=0.15, b=0.12},
            accent = {r=0.5, g=0.4, b=0.25}
        }
    end
    self.tabThemeColors = tabThemeColors

    if #tabs > 1 then
        y = self:createTabs(tabs, y, tabThemeColors)
    end

    self.filterBaseY = y
    y = self:createFilterTabBar(y, tabThemeColors)

    local maxItemCount = math.max(totalSkillCount, totalTraitCount, totalForgetCount, totalRecipeCount)
    y = self:createSearchBar(y, tabThemeColors, maxItemCount)

    local footerHeight = 85
    local listHeight = self.height - y - footerHeight - padding

    self.skillList = ISScrollingListBox:new(padding, y, self.width - padding * 2, listHeight)
    self.skillList:initialise()
    self.skillList:instantiate()
    self.skillList.drawBorder = false
    self.skillList.backgroundColor = {r=0, g=0, b=0, a=0}
    self.skillList:setFont(UIFont.Small, 2)
    self.skillList.itemheight = 52
    self.skillList.doDrawItem = BurdJournals.UI.MainPanel.doDrawAbsorptionItem
    self.skillList.mainPanel = self
    self.listBottomY = self.skillList:getY() + self.skillList:getHeight()

    self.skillList.onMouseUp = function(listbox, x, y)
        if listbox.vscroll then
            listbox.vscroll.scrolling = false
        end
        local row = listbox:rowAt(x, y)
        if row and row >= 1 and row <= #listbox.items then
            local item = listbox.items[row] and listbox.items[row].item
            if item and not item.isHeader and not item.isEmpty then

                local btnW = 55
                local margin = 10
                local claimBtnStart = listbox:getWidth() - btnW - margin

                if x >= claimBtnStart and not item.isClaimed then

                    if item.isSkill then
                        listbox.mainPanel:absorbSkill(item.skillName, item.xp)
                    elseif item.isForgetSlot then
                        listbox.mainPanel:claimForgetTrait(item.traitId)
                    elseif item.isTrait and not item.alreadyKnown then
                        listbox.mainPanel:absorbTrait(item.traitId)
                    elseif item.isRecipe and not item.alreadyKnown then
                        listbox.mainPanel:absorbRecipe(item.recipeName)
                    end
                end
            end
        end
        return true
    end
    self:addChild(self.skillList)
    y = y + listHeight

    self.footerY = y + 4
    self.footerHeight = footerHeight

    self.feedbackLabel = ISLabel:new(padding, self.footerY + 4, 18, "", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self:addChild(self.feedbackLabel)
    self.feedbackLabel:setVisible(false)
    self.feedbackTicks = 0

    local tabName = self:getTabDisplayName(self.currentTab or "skills")
    local absorbTabText = string.format(getText("UI_BurdJournals_BtnAbsorbTab") or "Absorb %s", tabName)
    local absorbAllText = getText("UI_BurdJournals_BtnAbsorbAll") or "Absorb All"
    local dissolveText = getText("UI_BurdJournals_BtnDissolve") or "Dissolve"
    local closeText = getText("UI_BurdJournals_BtnClose") or "Close"

    local allTabNames = {
        getText("UI_BurdJournals_TabSkills") or "Skills",
        getText("UI_BurdJournals_TabTraits") or "Traits",
        getText("UI_BurdJournals_TabForget") or "Forget",
        getText("UI_BurdJournals_TabRecipes") or "Recipes",
        getText("UI_BurdJournals_TabStats") or "Stats"
    }
    local btnPrefix = getText("UI_BurdJournals_BtnAbsorbTab") or "Absorb %s"
    local maxAbsorbTabW = 90
    for _, name in ipairs(allTabNames) do
        local text = string.format(btnPrefix, name)
        local w = getTextManager():MeasureStringX(UIFont.Small, text) + 20
        maxAbsorbTabW = math.max(maxAbsorbTabW, w)
    end
    local absorbAllW = getTextManager():MeasureStringX(UIFont.Small, absorbAllText) + 20
    local dissolveW = getTextManager():MeasureStringX(UIFont.Small, dissolveText) + 20
    local closeW = getTextManager():MeasureStringX(UIFont.Small, closeText) + 20
    local btnWidth = math.max(90, maxAbsorbTabW, absorbAllW, dissolveW, closeW)

    -- Show dissolve button only for worn/bloody journals that can dissolve
    local isWorn = BurdJournals.isWorn and BurdJournals.isWorn(self.journal) or false
    local showDissolveBtn = (isWorn or isBloody or isCursedReward) and BurdJournals.shouldDissolve and true or false

    local btnSpacing = 6
    local numButtons = showDissolveBtn and 4 or 3
    local totalBtnWidth = btnWidth * numButtons + btnSpacing * (numButtons - 1)
    local btnStartX = (self.width - totalBtnWidth) / 2
    local btnY = self.footerY + 32

    self.absorbTabBtn = ISButton:new(btnStartX, btnY, btnWidth, btnHeight, absorbTabText, self, BurdJournals.UI.MainPanel.onAbsorbTab)
    self.absorbTabBtn:initialise()
    self.absorbTabBtn:instantiate()
    if isCursedReward then
        self.absorbTabBtn.borderColor = {r=0.58, g=0.32, b=0.58, a=1}
        self.absorbTabBtn.backgroundColor = {r=0.24, g=0.12, b=0.26, a=0.86}
    elseif isBloody then
        self.absorbTabBtn.borderColor = {r=0.5, g=0.2, b=0.2, a=1}
        self.absorbTabBtn.backgroundColor = {r=0.3, g=0.1, b=0.1, a=0.8}
    else
        self.absorbTabBtn.borderColor = {r=0.35, g=0.45, b=0.3, a=1}
        self.absorbTabBtn.backgroundColor = {r=0.18, g=0.22, b=0.14, a=0.8}
    end
    self.absorbTabBtn.textColor = {r=1, g=1, b=1, a=1}
    self:addChild(self.absorbTabBtn)

    self.absorbAllBtn = ISButton:new(btnStartX + (btnWidth + btnSpacing) * 1, btnY, btnWidth, btnHeight, absorbAllText, self, BurdJournals.UI.MainPanel.onAbsorbAll)
    self.absorbAllBtn:initialise()
    self.absorbAllBtn:instantiate()
    if isCursedReward then
        self.absorbAllBtn.borderColor = {r=0.68, g=0.38, b=0.68, a=1}
        self.absorbAllBtn.backgroundColor = {r=0.30, g=0.14, b=0.33, a=0.86}
    elseif isBloody then
        self.absorbAllBtn.borderColor = {r=0.6, g=0.2, b=0.2, a=1}
        self.absorbAllBtn.backgroundColor = {r=0.35, g=0.1, b=0.1, a=0.8}
    else
        self.absorbAllBtn.borderColor = {r=0.4, g=0.5, b=0.3, a=1}
        self.absorbAllBtn.backgroundColor = {r=0.2, g=0.25, b=0.15, a=0.8}
    end
    self.absorbAllBtn.textColor = {r=1, g=1, b=1, a=1}
    self:addChild(self.absorbAllBtn)

    local nextBtnIndex = 2  -- Next button position

    -- Add dissolve button for worn/bloody journals
    if showDissolveBtn then
        self.dissolveBtn = ISButton:new(btnStartX + (btnWidth + btnSpacing) * nextBtnIndex, btnY, btnWidth, btnHeight, dissolveText, self, BurdJournals.UI.MainPanel.onDissolveJournal)
        self.dissolveBtn:initialise()
        self.dissolveBtn:instantiate()
        self.dissolveBtn.borderColor = {r=0.6, g=0.3, b=0.3, a=1}
        self.dissolveBtn.backgroundColor = {r=0.4, g=0.15, b=0.15, a=0.8}
        self.dissolveBtn.textColor = {r=1, g=0.9, b=0.9, a=1}
        self:addChild(self.dissolveBtn)
        nextBtnIndex = nextBtnIndex + 1
    end

    self.closeBottomBtn = ISButton:new(btnStartX + (btnWidth + btnSpacing) * nextBtnIndex, btnY, btnWidth, btnHeight, closeText, self, BurdJournals.UI.MainPanel.onClose)
    self.closeBottomBtn:initialise()
    self.closeBottomBtn:instantiate()
    self.closeBottomBtn.borderColor = {r=0.4, g=0.35, b=0.3, a=1}
    self.closeBottomBtn.backgroundColor = {r=0.15, g=0.13, b=0.12, a=0.8}
    self.closeBottomBtn.textColor = {r=0.9, g=0.85, b=0.8, a=1}
    self:addChild(self.closeBottomBtn)

    self:populateAbsorptionList()
end

-- Manual dissolve button handler for worn/bloody journals
function BurdJournals.UI.MainPanel:onDissolveJournal()
    if not self.journal then return end

    -- Show confirmation dialog
    local confirmText = getText("UI_BurdJournals_ConfirmDissolve") or "Are you sure you want to dissolve this journal? This cannot be undone."
    local titleText = getText("UI_BurdJournals_DissolveTitle") or "Dissolve Journal"

    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 150,
        getCore():getScreenHeight() / 2 - 50,
        300, 100,
        confirmText,
        true,
        self,
        BurdJournals.UI.MainPanel.onDissolveConfirm
    )
    modal:initialise()
    modal:addToUIManager()
end

function BurdJournals.UI.MainPanel:onDissolveConfirm(button)
    if button.internal ~= "YES" then return end
    if not self.journal then return end

    local player = self.player
    local journal = self.journal
    local journalData = BurdJournals.getJournalData(journal)
    local isDebugSpawned = journalData and journalData.isDebugSpawned

    -- Remove the journal
    local message = BurdJournals.getRandomDissolutionMessage and BurdJournals.getRandomDissolutionMessage() or "The journal crumbles to dust..."

    if isClient() and not isServer() then
        -- In MP, send command to server to remove
        -- Use debug dissolve for debug-spawned journals (bypasses restrictions)
        local command = isDebugSpawned and "debugDissolveJournal" or "dissolveJournal"
        BurdJournals.debugPrint("[BurdJournals] Dissolving via " .. command .. " (debug=" .. tostring(isDebugSpawned) .. ")")
        sendClientCommand(player, "BurdJournals", command, {
            journalId = journal:getID()
        })
    else
        -- In SP, remove directly and show message
        local container = journal:getContainer()
        if container then
            container:Remove(journal)
        end
        -- Show speaking bubble for SP (MP gets this from server response)
        if player and player.Say then
            player:Say(message)
        end
    end

    -- Close the panel
    self:close()
end

function BurdJournals.UI.MainPanel:onAbsorbAll()

    self:startLearningAll()
end

function BurdJournals.UI.MainPanel:onAbsorbTab()
    if (self.currentTab or "skills") == "forget" then
        self:showFeedback(
            getText("UI_BurdJournals_ForgetTabHint") or "Choose a trait in this tab to forget.",
            {r=0.9, g=0.72, b=0.45}
        )
        return
    end
    self:startLearningTab(self.currentTab or "skills")
end

function BurdJournals.UI.MainPanel:prerender()
    ISPanel.prerender(self)

    if self.searchPendingRefresh and self.searchEntry then
        self.searchPendingRefresh = false
        local currentText = self.searchEntry:getText() or ""
        if currentText ~= self.searchEntry.lastSearchText then
            self.searchEntry.lastSearchText = currentText
            self.searchQuery = currentText
            self:refreshCurrentList()
        end
    end

    if self.mode == "absorb" or self.mode == "view" or self.mode == "log" then
        self:prerenderJournalUI()
    end
end

function BurdJournals.UI.MainPanel:prerenderJournalUI()
    local padding = 16

    local isProgressActive = false
    if self.mode == "log" then
        isProgressActive = self.recordingState and self.recordingState.active and self.recordingState.isRecordAll
    else
        isProgressActive = self.learningState and self.learningState.active and self.learningState.isAbsorbAll
    end

    local normalBtnY = self.footerY + 32
    local progressBtnY = self.footerY + 48

    local targetBtnY = isProgressActive and progressBtnY or normalBtnY

    if self.absorbTabBtn then
        self.absorbTabBtn:setY(targetBtnY)
    end
    if self.absorbAllBtn then
        self.absorbAllBtn:setY(targetBtnY)
    end
    if self.recordTabBtn then
        self.recordTabBtn:setY(targetBtnY)
    end
    if self.recordAllBtn then
        self.recordAllBtn:setY(targetBtnY)
    end
    if self.closeBottomBtn then
        self.closeBottomBtn:setY(targetBtnY)
    end
    if self.dissolveBtn then
        self.dissolveBtn:setY(targetBtnY)
    end

    -- Hide feedback label when progress bar is active (they overlap at footerY + 4/8)
    if self.feedbackLabel then
        if isProgressActive then
            self.feedbackLabel:setVisible(false)
        end
        -- Note: feedbackLabel visibility is set by showFeedback() when not in progress
    end

    -- Admin buttons are now in the header, no repositioning needed

    if self.mode == "absorb" or self.mode == "view" then
        local isLearning = self.learningState and self.learningState.active

        if self.absorbTabBtn then
            self.absorbTabBtn:setEnable(not isLearning)
            local tabName = self:getTabDisplayName(self.currentTab or "skills")
            if isLearning then
                self.absorbTabBtn.title = getText("UI_BurdJournals_StateReading")
            else
                local btnTextKey = (self.mode == "view") and "UI_BurdJournals_BtnClaimTab" or "UI_BurdJournals_BtnAbsorbTab"
                self.absorbTabBtn.title = string.format(getText(btnTextKey) or "%s Tab", tabName)
            end
        end

        if self.absorbAllBtn then
            self.absorbAllBtn:setEnable(not isLearning)
            if isLearning then
                self.absorbAllBtn.title = getText("UI_BurdJournals_StateReading")
            else
                self.absorbAllBtn.title = (self.mode == "view") and getText("UI_BurdJournals_BtnClaimAll") or getText("UI_BurdJournals_BtnAbsorbAll")
            end
        end
    elseif self.mode == "log" then
        local isRecording = self.recordingState and self.recordingState.active

        if self.recordTabBtn then
            self.recordTabBtn:setEnable(not isRecording)
            local tabName = self:getTabDisplayName(self.currentTab or "skills")
            if isRecording then
                self.recordTabBtn.title = getText("UI_BurdJournals_StateRecording")
            else
                self.recordTabBtn.title = string.format(getText("UI_BurdJournals_BtnRecordTab") or "Record %s", tabName)
            end
        end

        if self.recordAllBtn then
            self.recordAllBtn:setEnable(not isRecording)
            if isRecording then
                self.recordAllBtn.title = getText("UI_BurdJournals_StateRecording")
            else
                self.recordAllBtn.title = getText("UI_BurdJournals_BtnRecordAll")
            end
        end
    end

    if self.headerColor then

        self:drawRect(0, 0, self.width, self.headerHeight, 0.95, self.headerColor.r, self.headerColor.g, self.headerColor.b)

        if self.headerAccent then
            self:drawRect(0, self.headerHeight - 3, self.width, 3, 1, self.headerAccent.r, self.headerAccent.g, self.headerAccent.b)
        end

        local titleX = padding
        if self.headerIconTexture then
            local iconSize = self.headerIconSize or 20
            local iconY = math.floor((self.headerHeight - iconSize) / 2)
            self:drawTextureScaledAspect(self.headerIconTexture, padding, iconY, iconSize, iconSize, 1, 1, 1, 1)
            titleX = padding + iconSize + 8
        end

        local headerCenterY = math.floor(self.headerHeight / 2)
        if self.typeText then
            local typeTextH = getTextManager():MeasureStringY(UIFont.Medium, self.typeText)
            local typeTextY = math.floor(headerCenterY - (typeTextH / 2)) + 1
            self:drawText(self.typeText, titleX, typeTextY, 1, 0.9, 0.85, 1, UIFont.Medium)
        end

        if self.rarityText and self.mode == "absorb" then
            local reservedRight = self.headerRightInset or 0
            local rarityW = getTextManager():MeasureStringX(UIFont.Small, self.rarityText) + 12
            local rarityX = self.width - padding - reservedRight - rarityW
            local rarityTextH = getTextManager():MeasureStringY(UIFont.Small, self.rarityText)
            local rarityH = math.max(18, rarityTextH + 6)
            local rarityY = math.floor(headerCenterY - (rarityH / 2)) + 1
            local rarityTextY = math.floor(rarityY + ((rarityH - rarityTextH) / 2))
            if self.isCursedReward then
                self:drawRect(rarityX - 6, rarityY, rarityW, rarityH, 0.82, 0.52, 0.28, 0.50)
            elseif self.isBloody then
                self:drawRect(rarityX - 6, rarityY, rarityW, rarityH, 0.8, 0.6, 0.15, 0.15)
            else
                self:drawRect(rarityX - 6, rarityY, rarityW, rarityH, 0.8, 0.5, 0.4, 0.2)
            end
            self:drawText(self.rarityText, rarityX, rarityTextY, 1, 0.95, 0.85, 1, UIFont.Small)
        end
    end

    if self.authorBoxY then

        local boxBg = nil
        local boxBorder = nil
        if self.mode == "log" or self.mode == "view" then
            boxBg = {r=0.10, g=0.14, b=0.18}
            boxBorder = {r=0.20, g=0.30, b=0.38}
        elseif self.isCursedReward then
            boxBg = {r=0.18, g=0.10, b=0.18}
            boxBorder = {r=0.48, g=0.26, b=0.46}
        else
            boxBg = {r=0.12, g=0.11, b=0.10}
            boxBorder = {r=0.30, g=0.28, b=0.25}
        end

        self:drawRect(padding, self.authorBoxY, self.width - padding * 2, self.authorBoxHeight, 0.6, boxBg.r, boxBg.g, boxBg.b)
        self:drawRectBorder(padding, self.authorBoxY, self.width - padding * 2, self.authorBoxHeight, 0.5, boxBorder.r, boxBorder.g, boxBorder.b)

        local authorText
        local authorNameDisplay = self.authorName or getText("UI_BurdJournals_Unknown")
        if self.mode == "log" then
            authorText = string.format(getText("UI_BurdJournals_RecordingFor"), authorNameDisplay)
        else
            authorText = string.format(getText("UI_BurdJournals_FromNotesOf"), authorNameDisplay)
        end
        self:drawText(authorText, padding + 10, self.authorBoxY + 8, 0.8, 0.85, 0.9, 1, UIFont.Small)

        if self.flavorText then
            if self.isCursedReward then
                self:drawText(self.flavorText, padding + 10, self.authorBoxY + 24, 0.85, 0.62, 0.84, 1, UIFont.Small)
            else
                self:drawText(self.flavorText, padding + 10, self.authorBoxY + 24, 0.5, 0.55, 0.6, 1, UIFont.Small)
            end
        end
    end

    if self.footerY then

        self:drawRect(padding, self.footerY, self.width - padding * 2, 1, 0.3, 0.25, 0.35, 0.45)

        if self.mode == "log" then

            if self.recordingState and self.recordingState.active and self.recordingState.isRecordAll then
                local barX = padding
                local barY = self.footerY + 8
                local barW = self.width - padding * 2
                local barH = 16
                local progress = self.recordingState.progress
                local totalRecords = #self.recordingState.pendingRecords

                local elapsed = (getTimestampMs() - self.recordingState.startTime) / 1000.0
                local remaining = math.max(0, self.recordingState.totalTime - elapsed)
                local remainingText = string.format("%.1fs", remaining)

                self:drawRect(barX, barY, barW, barH, 0.7, 0.12, 0.12, 0.12)
                self:drawRect(barX, barY, barW * progress, barH, 0.85, 0.25, 0.55, 0.45)
                self:drawRectBorder(barX, barY, barW, barH, 0.8, 0.4, 0.6, 0.7)

                local progressFormat = getText("UI_BurdJournals_RecordingAllProgress") or "Recording All: %d%% (%s remaining)"
                local progressText = string.format(progressFormat, math.floor(progress * 100), remainingText)
                local textWidth = getTextManager():MeasureStringX(UIFont.Small, progressText)
                self:drawText(progressText, (self.width - textWidth) / 2, barY + 1, 1, 1, 1, 1, UIFont.Small)

                local countFormat = totalRecords > 1 and (getText("UI_BurdJournals_ItemCountPlural") or "%d items") or (getText("UI_BurdJournals_ItemCount") or "%d item")
                local countText = string.format(countFormat, totalRecords)
                local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
                self:drawText(countText, (self.width - countWidth) / 2, barY + barH + 4, 0.6, 0.7, 0.75, 1, UIFont.Small)
            end
        elseif self.learningState and self.learningState.active and self.learningState.isAbsorbAll then

            local barX = padding
            local barY = self.footerY + 8
            local barW = self.width - padding * 2
            local barH = 16
            local progress = self.learningState.progress
            local totalRewards = #self.learningState.pendingRewards

            local elapsed = (getTimestampMs() - self.learningState.startTime) / 1000.0
            local remaining = math.max(0, self.learningState.totalTime - elapsed)
            local remainingText = string.format("%.1fs", remaining)

            self:drawRect(barX, barY, barW, barH, 0.7, 0.12, 0.12, 0.12)
            local fillW = barW * progress
            if self.isCursedReward then
                self:drawRect(barX, barY, fillW, barH, 0.88, 0.56, 0.28, 0.56)
            elseif self.isBloody then
                self:drawRect(barX, barY, fillW, barH, 0.85, 0.6, 0.2, 0.15)
            elseif self.mode == "view" then
                self:drawRect(barX, barY, fillW, barH, 0.85, 0.25, 0.50, 0.60)
            else
                self:drawRect(barX, barY, fillW, barH, 0.85, 0.35, 0.55, 0.25)
            end
            self:drawRectBorder(barX, barY, barW, barH, 0.8, 0.5, 0.5, 0.5)

            local progressFormat
            if self.mode == "view" then
                progressFormat = getText("UI_BurdJournals_ClaimingAllProgress") or "Claiming All: %d%% (%s remaining)"
            else
                progressFormat = getText("UI_BurdJournals_AbsorbingAllProgress") or "Absorbing All: %d%% (%s remaining)"
            end
            local progressText = string.format(progressFormat, math.floor(progress * 100), remainingText)
            local textWidth = getTextManager():MeasureStringX(UIFont.Small, progressText)
            self:drawText(progressText, (self.width - textWidth) / 2, barY + 1, 1, 1, 1, 1, UIFont.Small)

            local countFormat = totalRewards > 1 and (getText("UI_BurdJournals_RewardsQueued") or "%d rewards queued") or (getText("UI_BurdJournals_RewardQueued") or "%d reward queued")
            local countText = string.format(countFormat, totalRewards)
            local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
            self:drawText(countText, (self.width - countWidth) / 2, barY + barH + 4, 0.6, 0.6, 0.55, 1, UIFont.Small)
        else

            if self.mode == "absorb" or self.mode == "view" then
        local summaryText = ""
        if self.totalXP and self.totalXP > 0 then
            local xpFormat = getText("UI_BurdJournals_SummaryTotalXP") or "Total: +%s XP"
            summaryText = string.format(xpFormat, BurdJournals.formatXP(self.totalXP))
        end
        if self.traitCount and self.traitCount > 0 then
            if summaryText ~= "" then
                summaryText = summaryText .. (getText("UI_BurdJournals_SummarySeparator") or "  |  ")
            end
            local traitFormat = self.traitCount > 1 and (getText("UI_BurdJournals_SummaryTraits") or "%d traits") or (getText("UI_BurdJournals_SummaryTrait") or "%d trait")
            summaryText = summaryText .. string.format(traitFormat, self.traitCount)
        end
        if summaryText ~= "" then
            local textWidth = getTextManager():MeasureStringX(UIFont.Small, summaryText)
                    self:drawText(summaryText, (self.width - textWidth) / 2, self.footerY + 10, 0.7, 0.75, 0.8, 1, UIFont.Small)
                end
            end
        end
    end
end

function BurdJournals.UI.MainPanel.doDrawAbsorptionItem(self, y, item, alt)
    local mainPanel = self.mainPanel
    if not mainPanel then return y + self.itemheight end

    local data = item.item or {}
    local journalData = (mainPanel.journal and BurdJournals.getJournalData and BurdJournals.getJournalData(mainPanel.journal)) or nil

    local x = 0

    local scrollBarWidth = 13
    local w = self:getWidth() - scrollBarWidth
    local h = self.itemheight
    local padding = 12

    local isBloody = mainPanel.isBloody
    local isCursedReward = mainPanel.isCursedReward
    local cardBg, cardBorder, accentColor
    if isCursedReward then
        cardBg = {r=0.17, g=0.10, b=0.18}
        cardBorder = {r=0.46, g=0.24, b=0.48}
        accentColor = {r=0.76, g=0.40, b=0.68}
    elseif isBloody then
        cardBg = {r=0.18, g=0.12, b=0.12}
        cardBorder = {r=0.4, g=0.2, b=0.2}
        accentColor = {r=0.7, g=0.25, b=0.25}
    else
        cardBg = {r=0.14, g=0.13, b=0.11}
        cardBorder = {r=0.35, g=0.32, b=0.28}
        accentColor = {r=0.5, g=0.6, b=0.4}
    end

    if data.isHeader then
        self:drawRect(x, y + 2, w, h - 4, 0.4, 0.15, 0.14, 0.12)
        self:drawText(data.text or getText("UI_BurdJournals_Skills") or "SKILLS", x + padding, y + (h - 18) / 2, 0.9, 0.8, 0.6, 1, UIFont.Medium)
        if data.count then
            local countText = string.format(getText("UI_BurdJournals_Available") or "(%d available)", data.count)
            local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
            self:drawText(countText, w - padding - countWidth, y + (h - 14) / 2, 0.5, 0.5, 0.45, 1, UIFont.Small)
        end
        return y + h
    end

    if data.isEmpty then
        self:drawText(data.text or getText("UI_BurdJournals_NoRewardsAvailable") or "No rewards available", x + padding, y + (h - 14) / 2, 0.4, 0.4, 0.4, 1, UIFont.Small)
        return y + h
    end

    local cardMargin = 4
    local cardX = x + cardMargin
    local cardY = y + cardMargin
    local cardW = w - cardMargin * 2
    local cardH = h - cardMargin * 2

    local bgColor = cardBg
    local borderColor = cardBorder
    local accent = accentColor
    if data.isTrait and not data.isClaimed then
        if data.isForgetSlot then
            bgColor = {r=0.20, g=0.08, b=0.10}
            borderColor = {r=0.6, g=0.25, b=0.3}
            accent = {r=0.9, g=0.35, b=0.4}
        elseif data.isPositive == true then

            bgColor = {r=0.08, g=0.20, b=0.10}
            borderColor = {r=0.2, g=0.5, b=0.25}
            accent = {r=0.3, g=0.8, b=0.35}
        elseif data.isPositive == false then

            bgColor = {r=0.22, g=0.08, b=0.08}
            borderColor = {r=0.5, g=0.2, b=0.2}
            accent = {r=0.8, g=0.3, b=0.3}
        end

    end

    if data.isClaimed then
        self:drawRect(cardX, cardY, cardW, cardH, 0.3, 0.1, 0.1, 0.1)
    else
        self:drawRect(cardX, cardY, cardW, cardH, 0.7, bgColor.r, bgColor.g, bgColor.b)
    end

    self:drawRectBorder(cardX, cardY, cardW, cardH, 0.6, borderColor.r, borderColor.g, borderColor.b)

    self:drawRect(cardX, cardY, 4, cardH, 0.9, accent.r, accent.g, accent.b)

    local textX = cardX + padding + 4
    local textColor = data.isClaimed and {r=0.4, g=0.4, b=0.4} or {r=0.95, g=0.9, b=0.85}

    if data.isSkill then

        local learningState = mainPanel.learningState
        local isLearningThis = learningState.active and not learningState.isAbsorbAll
                              and learningState.skillName == data.skillName
        local isQueuedInAbsorbAll = learningState.active and learningState.isAbsorbAll
                                   and not data.isClaimed

        local queuePosition = mainPanel:getQueuePosition(data.skillName)
        local isQueued = queuePosition ~= nil

        local displayName = data.displayName or data.skillName or "Unknown Skill"
        self:drawText(displayName, textX, cardY + 6, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)

        if isLearningThis then

            local progressFormat = getText("UI_BurdJournals_ReadingProgress") or "Reading... %d%%"
            local progressText = string.format(progressFormat, math.floor(learningState.progress * 100))
            self:drawText(progressText, textX, cardY + 24, 0.9, 0.8, 0.3, 1, UIFont.Small)

            local barX = textX + 90
            local barY = cardY + 27
            local barW = cardW - 120 - padding
            local barH = 10
            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)
            self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.3, 0.7, 0.4)
            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.4, 0.8, 0.5)

        elseif isQueued then

            local squaresX = textX
            local squaresY = cardY + 26
            local squareSize = 10
            local squareSpacing = 2
            -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
            local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, data.xp or 0, journalData, mainPanel.player)
            local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)

            drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
                {r=0.4, g=0.5, b=0.6},
                {r=0.1, g=0.1, b=0.1},
                {r=0.25, g=0.3, b=0.4}
            )
            local squaresWidth = 10 * squareSize + 9 * squareSpacing
            local displayXP = data.effectiveXP or data.xp
            local xpText = "+" .. BurdJournals.formatXP(displayXP) .. " XP"
            if data.hasBookBoost then
                xpText = xpText .. " " .. (getText("UI_BurdJournals_XPBoosted") or "(boosted)")
            end
            xpText = xpText .. "  #" .. queuePosition
            local xpColor = data.hasBookBoost and {r=1.0, g=0.85, b=0.3} or {r=0.6, g=0.75, b=0.9}
            self:drawText(xpText, squaresX + squaresWidth + 8, squaresY, xpColor.r, xpColor.g, xpColor.b, 1, UIFont.Small)

        elseif isQueuedInAbsorbAll then

            local squaresX = textX
            local squaresY = cardY + 26
            local squareSize = 10
            local squareSpacing = 2
            -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
            local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, data.xp or 0, journalData, mainPanel.player)
            local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)

            drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
                {r=0.45, g=0.55, b=0.35},
                {r=0.1, g=0.1, b=0.1},
                {r=0.3, g=0.38, b=0.22}
            )
            local squaresWidth = 10 * squareSize + 9 * squareSpacing
            local displayXP = data.effectiveXP or data.xp
            local xpText = "+" .. BurdJournals.formatXP(displayXP) .. " XP"
            if data.hasBookBoost then
                xpText = xpText .. " " .. (getText("UI_BurdJournals_XPBoosted") or "(boosted)")
            end
            xpText = xpText .. "  Queued"
            local xpColor = data.hasBookBoost and {r=1.0, g=0.85, b=0.3} or {r=0.5, g=0.6, b=0.4}
            self:drawText(xpText, squaresX + squaresWidth + 8, squaresY, xpColor.r, xpColor.g, xpColor.b, 1, UIFont.Small)

        elseif data.xp and not data.isClaimed then

            local squaresX = textX
            local squaresY = cardY + 26
            local squareSize = 10
            local squareSpacing = 2
            -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
            local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, data.xp or 0, journalData, mainPanel.player)
            local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)

            local filledColor, progressColor
            if isCursedReward then
                filledColor = {r=0.68, g=0.34, b=0.70}
                progressColor = {r=0.45, g=0.20, b=0.46}
            elseif isBloody then
                filledColor = {r=0.65, g=0.25, b=0.25}
                progressColor = {r=0.45, g=0.18, b=0.18}
            else
                filledColor = {r=0.5, g=0.6, b=0.4}
                progressColor = {r=0.35, g=0.42, b=0.28}
            end

            drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
                filledColor,
                {r=0.1, g=0.1, b=0.1},
                progressColor
            )
            local squaresWidth = 10 * squareSize + 9 * squareSpacing
            local displayXP = data.effectiveXP or data.xp
            local xpText = "+" .. BurdJournals.formatXP(displayXP) .. " XP"
            if data.hasBookBoost then
                xpText = xpText .. " " .. (getText("UI_BurdJournals_XPBoosted") or "(boosted)")
            end
            -- Use golden color for boosted XP, normal green otherwise
            local xpColor = data.hasBookBoost and {r=1.0, g=0.85, b=0.3} or {r=0.6, g=0.8, b=0.5}
            self:drawText(xpText, squaresX + squaresWidth + 8, squaresY, xpColor.r, xpColor.g, xpColor.b, 1, UIFont.Small)

        elseif data.isClaimed then

            local squaresX = textX
            local squaresY = cardY + 26
            local squareSize = 10
            local squareSpacing = 2
            -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
            local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, data.xp or 0, journalData, mainPanel.player)
            local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)

            drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
                {r=0.2, g=0.2, b=0.2},
                {r=0.08, g=0.08, b=0.08},
                {r=0.15, g=0.15, b=0.15}
            )
            local squaresWidth = 10 * squareSize + 9 * squareSpacing
            self:drawText(getText("UI_BurdJournals_StatusClaimed") or "Claimed", squaresX + squaresWidth + 8, squaresY, 0.35, 0.35, 0.35, 1, UIFont.Small)
        end

        if not data.isClaimed and not isLearningThis then
            local btnW = 60
            local btnH = 24
            local btnX = cardX + cardW - btnW - 10
            local btnY = cardY + (cardH - btnH) / 2
            local isInBatch = isInCurrentAbsorbBatch(learningState, "skill", data.skillName)

            if isQueued then

                self:drawRect(btnX, btnY, btnW, btnH, 0.5, 0.3, 0.4, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.6, 0.4, 0.5, 0.6)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.8, 0.9, 1, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being absorbed
                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.45, 0.55, 0.45)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.6, 0.7, 0.6)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
            elseif learningState.active and not learningState.isAbsorbAll then

                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.25, 0.35, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.4, 0.55, 0.7)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.95, 1, 1, UIFont.Small)
            elseif not learningState.active then

                self:drawRect(btnX, btnY, btnW, btnH, 0.7, accentColor.r * 0.6, accentColor.g * 0.6, accentColor.b * 0.6)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, accentColor.r, accentColor.g, accentColor.b)
                local btnText = getText("UI_BurdJournals_Absorb")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end

    if data.isTrait then

        local learningState = mainPanel.learningState
        local isLearningThis = learningState.active and not learningState.isAbsorbAll
                              and learningState.traitId == data.traitId
        local isQueuedInAbsorbAll = learningState.active and learningState.isAbsorbAll
                                   and not data.isClaimed and not data.alreadyKnown and not data.isForgetSlot

        local queuePosition = mainPanel:getQueuePosition(data.traitId)
        local isQueued = queuePosition ~= nil

        local traitName = data.traitName or data.traitId or getText("UI_BurdJournals_UnknownTrait") or "Unknown Trait"
        local traitTextX = textX

        if data.traitTexture then
            local iconSize = 24
            local iconX = textX
            local iconY = cardY + (cardH - iconSize) / 2
            local iconAlpha = data.isClaimed and 0.4 or 1.0
            self:drawTextureScaledAspect(data.traitTexture, iconX, iconY, iconSize, iconSize, iconAlpha, 1, 1, 1)
            traitTextX = textX + iconSize + 6
        end

        local traitColor
        if data.isClaimed then
            traitColor = {r=0.4, g=0.4, b=0.4}
        elseif data.isForgetSlot then
            traitColor = {r=0.95, g=0.65, b=0.72}
        elseif data.isPositive == true then
            traitColor = {r=0.5, g=0.9, b=0.5}
        elseif data.isPositive == false then
            traitColor = {r=0.9, g=0.5, b=0.5}
        else
            traitColor = {r=0.9, g=0.75, b=0.5}
        end
        self:drawText(traitName, traitTextX, cardY + 6, traitColor.r, traitColor.g, traitColor.b, 1, UIFont.Small)

        if isLearningThis then
            local progressText = string.format(getText("UI_BurdJournals_AbsorbingProgress") or "Absorbing... %d%%", math.floor(learningState.progress * 100))
            self:drawText(progressText, traitTextX, cardY + 22, 0.9, 0.7, 0.3, 1, UIFont.Small)

            local barX = traitTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.8, 0.6, 0.2)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.9, 0.7, 0.3)

        elseif isQueued then

            if data.isPositive == false then
                local queueText = string.format(getText("UI_BurdJournals_NegativeTraitQueued") or "Cursed trait - Queued #%d", queuePosition)
                self:drawText(queueText, traitTextX, cardY + 22, 0.7, 0.4, 0.4, 1, UIFont.Small)
            else
                local queueText = string.format(getText("UI_BurdJournals_RareTraitQueued") or "Rare trait - Queued #%d", queuePosition)
                self:drawText(queueText, traitTextX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)
            end

        elseif isQueuedInAbsorbAll then

            if data.isPositive == false then
                local curseText = getText("UI_BurdJournals_NegativeTraitCurseQueued") or "Cursed knowledge... - Queued"
                self:drawText(curseText, traitTextX, cardY + 22, 0.5, 0.35, 0.35, 1, UIFont.Small)
            else
                local bonusText = getText("UI_BurdJournals_RareTraitBonusQueued") or "Rare trait bonus! - Queued"
                self:drawText(bonusText, traitTextX, cardY + 22, 0.5, 0.45, 0.25, 1, UIFont.Small)
            end

        elseif data.isClaimed then
            self:drawText(getText("UI_BurdJournals_StatusClaimed") or "Claimed", traitTextX, cardY + 22, 0.35, 0.35, 0.35, 1, UIFont.Small)
        elseif data.isForgetSlot then
            self:drawText(getText("UI_BurdJournals_ForgetTraitHint") or "Remove this negative trait", traitTextX, cardY + 22, 0.8, 0.55, 0.6, 1, UIFont.Small)
        elseif data.alreadyKnown then
            self:drawText(getText("UI_BurdJournals_StatusAlreadyKnown") or "Already known", traitTextX, cardY + 22, 0.5, 0.4, 0.3, 1, UIFont.Small)
        else

            if data.isPositive == false then
                local curseText = getText("UI_BurdJournals_NegativeTraitCurse") or "Cursed knowledge..."
                self:drawText(curseText, traitTextX, cardY + 22, 0.7, 0.4, 0.4, 1, UIFont.Small)
            else
                local bonusText = getText("UI_BurdJournals_RareTraitBonus") or "Rare trait bonus!"
                self:drawText(bonusText, traitTextX, cardY + 22, 0.7, 0.55, 0.3, 1, UIFont.Small)
            end
        end

        if not data.isClaimed and not data.alreadyKnown and not isLearningThis then
            local btnW = 60
            local btnH = 24
            local btnX = cardX + cardW - btnW - 10
            local btnY = cardY + (cardH - btnH) / 2
            local isInBatch = isInCurrentAbsorbBatch(learningState, "trait", data.traitId)

            if isQueued then

                self:drawRect(btnX, btnY, btnW, btnH, 0.5, 0.4, 0.35, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.6, 0.5, 0.45, 0.6)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.85, 0.7, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being absorbed
                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.5, 0.45, 0.45)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.65, 0.55, 0.6)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.85, 1, UIFont.Small)
            elseif learningState.active and not learningState.isAbsorbAll and not data.isForgetSlot then

                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.4, 0.35, 0.25)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.6, 0.5, 0.35)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.85, 1, UIFont.Small)
            elseif not learningState.active then

                if data.isForgetSlot then
                    self:drawRect(btnX, btnY, btnW, btnH, 0.8, 0.6, 0.2, 0.28)
                    self:drawRectBorder(btnX, btnY, btnW, btnH, 0.9, 0.85, 0.4, 0.45)
                else
                    self:drawRect(btnX, btnY, btnW, btnH, 0.7, 0.5, 0.35, 0.15)
                    self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.7, 0.5, 0.25)
                end
                local btnText = data.isForgetSlot and (getText("UI_BurdJournals_BtnForget") or "FORGET") or getText("UI_BurdJournals_BtnClaim")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.85, 1, UIFont.Small)
            end
        end
    end

    if data.isRecipe then

        local learningState = mainPanel.learningState
        local isLearningThis = learningState.active and not learningState.isAbsorbAll
                              and learningState.recipeName == data.recipeName
        local isQueuedInAbsorbAll = learningState.active and learningState.isAbsorbAll
                                   and not data.isClaimed and not data.alreadyKnown

        local queuePosition = mainPanel:getQueuePosition(data.recipeName)
        local isQueued = queuePosition ~= nil

        local recipeName = data.displayName or data.recipeName or "Unknown Recipe"
        local recipeTextX = textX

        local magazineTexture = getMagazineTexture(data.magazineSource)

        if magazineTexture then
            local iconSize = 24
            local iconX = textX
            local iconY = cardY + (cardH - iconSize) / 2
            local iconAlpha = (data.isClaimed or data.alreadyKnown) and 0.4 or 1.0
            self:drawTextureScaledAspect(magazineTexture, iconX, iconY, iconSize, iconSize, iconAlpha, 1, 1, 1)
            recipeTextX = textX + iconSize + 6
        end

        local recipeColor
        if data.isClaimed then
            recipeColor = {r=0.4, g=0.4, b=0.4}
        elseif data.alreadyKnown then
            recipeColor = {r=0.5, g=0.5, b=0.45}
        else
            recipeColor = {r=0.5, g=0.85, b=0.9}
        end
        self:drawText(recipeName, recipeTextX, cardY + 6, recipeColor.r, recipeColor.g, recipeColor.b, 1, UIFont.Small)

        if isLearningThis then
            local progressText = string.format("Learning... %d%%", math.floor(learningState.progress * 100))
            self:drawText(progressText, recipeTextX, cardY + 22, 0.5, 0.8, 0.9, 1, UIFont.Small)

            local barX = recipeTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.3, 0.7, 0.8)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.4, 0.8, 0.9)

        elseif isQueued then

            local queueText = string.format(getText("UI_BurdJournals_RecipeKnowledgeQueuedNum") or "Recipe knowledge - Queued #%d", queuePosition)
            self:drawText(queueText, recipeTextX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)

        elseif isQueuedInAbsorbAll then

            local bonusText = getText("UI_BurdJournals_RecipeKnowledgeQueued") or "Recipe knowledge - Queued"
            self:drawText(bonusText, recipeTextX, cardY + 22, 0.4, 0.6, 0.65, 1, UIFont.Small)

        elseif data.isClaimed then
            self:drawText(getText("UI_BurdJournals_RecipeClaimed") or "Claimed", recipeTextX, cardY + 22, 0.35, 0.35, 0.35, 1, UIFont.Small)
        elseif data.alreadyKnown then
            self:drawText(getText("UI_BurdJournals_RecipeAlreadyKnown") or "Already known", recipeTextX, cardY + 22, 0.5, 0.4, 0.3, 1, UIFont.Small)
        else

            local sourceText = getText("UI_BurdJournals_RecipeKnowledge") or "Recipe knowledge"
            if data.magazineSource then
                local magazineName = BurdJournals.getMagazineDisplayName(data.magazineSource)
                sourceText = string.format(getText("UI_BurdJournals_RecipeFromMagazine") or "From: %s", magazineName)
            end
            self:drawText(sourceText, recipeTextX, cardY + 22, 0.5, 0.7, 0.75, 1, UIFont.Small)
        end

        if not data.isClaimed and not data.alreadyKnown and not isLearningThis then
            local btnW = 55
            local btnH = 24

            local btnX = cardX + cardW - btnW - 10
            local btnY = cardY + (cardH - btnH) / 2
            local isInBatch = isInCurrentAbsorbBatch(learningState, "recipe", data.recipeName)

            if isQueued then

                self:drawRect(btnX, btnY, btnW, btnH, 0.5, 0.3, 0.5, 0.55)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.6, 0.4, 0.6, 0.7)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.8, 0.9, 1, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being absorbed
                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.45, 0.55, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.55, 0.7, 0.7)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
            elseif learningState.active and not learningState.isAbsorbAll then

                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.25, 0.45, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.35, 0.6, 0.7)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.95, 1, 1, UIFont.Small)
            elseif not learningState.active then

                self:drawRect(btnX, btnY, btnW, btnH, 0.7, 0.2, 0.45, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.3, 0.6, 0.7)
                local btnText = getText("UI_BurdJournals_BtnClaim")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 1, 1, 1, UIFont.Small)
            end
        end
    end

    return y + h
end

function BurdJournals.UI.MainPanel:populateAbsorptionList()
    self.skillList:clear()

    local journalData = BurdJournals.getJournalData(self.journal)
    local hasBloodyOrigin = BurdJournals.hasBloodyOrigin(self.journal)
    local isDebugSpawned = journalData and journalData.isDebugSpawned
    local currentTab = self.currentTab or "skills"

    if currentTab == "skills" then

        local skillCount = 0
        if journalData and journalData.skills then
            for skillName, _ in pairs(journalData.skills) do
                if isSkillVisibleForJournal(journalData, skillName) then
                    if not BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName) then
                        skillCount = skillCount + 1
                    end
                end
            end
        end

        if journalData and journalData.skills then
            local hasSkills = false
            local matchCount = 0
            for skillName, skillData in pairs(journalData.skills) do
                if isSkillVisibleForJournal(journalData, skillName) then
                    hasSkills = true
                    local isClaimed = BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName)
                    local displayName = BurdJournals.getPerkDisplayName(skillName)
                    local modSource = BurdJournals.getSkillModId(skillName)

                    if self:matchesSearch(displayName) and self:passesFilter(modSource) then
                        matchCount = matchCount + 1
                        -- Calculate skill book multiplier for this player (only for unclaimed skills)
                        local baseXP = skillData.xp or 0
                        local effectiveXP = baseXP
                        local hasBookBoost = false
                        if not isClaimed then
                            effectiveXP, hasBookBoost = BurdJournals.getEffectiveXP(self.player, skillName, baseXP)
                        end
                        self.skillList:addItem(skillName, {
                            isSkill = true,
                            skillName = skillName,
                            displayName = displayName,
                            xp = baseXP,
                            effectiveXP = effectiveXP,
                            hasBookBoost = hasBookBoost,
                            level = skillData.level or 0,
                            isClaimed = isClaimed,
                            modSource = modSource
                        })
                    end
                end
            end
            if not hasSkills then
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSkillsRecorded")})
            elseif matchCount == 0 then
                self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSkillsRecorded")})
        end

    elseif currentTab == "traits" then
        local hasTraitEntries = false
        local matchCount = 0

        if (hasBloodyOrigin or isDebugSpawned) and journalData and journalData.traits then
            for traitId, traitData in pairs(journalData.traits) do
                hasTraitEntries = true
                local isClaimed = BurdJournals.hasCharacterClaimedTrait(journalData, self.player, traitId)
                local alreadyKnown = BurdJournals.playerHasTrait(self.player, traitId)
                local traitName = safeGetTraitName(traitId)
                local traitTexture = getTraitTexture(traitId)
                local isPositive = isTraitPositive(traitId)
                local modSource = BurdJournals.getTraitModId(traitId)

                if self:matchesSearch(traitName) and self:passesFilter(modSource) then
                    matchCount = matchCount + 1
                    self.skillList:addItem(traitId, {
                        isTrait = true,
                        traitId = traitId,
                        traitName = traitName,
                        traitTexture = traitTexture,
                        isClaimed = isClaimed,
                        alreadyKnown = alreadyKnown,
                        isPositive = isPositive,
                        modSource = modSource
                    })
                end
            end
        end

        if not hasTraitEntries then
            self.skillList:addItem("empty_traits", {isEmpty = true, text = getText("UI_BurdJournals_NoTraitsAvailable")})
        elseif matchCount == 0 then
            self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
        end

    elseif currentTab == "forget" then
        local hasForgetSlot = journalData and journalData.forgetSlot == true
            and BurdJournals.isForgetSlotEnabledForJournal
            and BurdJournals.isForgetSlotEnabledForJournal(journalData)
        local forgetClaimed = hasForgetSlot
            and BurdJournals.hasCharacterClaimedForgetSlot
            and BurdJournals.hasCharacterClaimedForgetSlot(journalData, self.player)

        if not hasForgetSlot then
            self.skillList:addItem("no_forget_slot", {
                isEmpty = true,
                text = getText("UI_BurdJournals_NoForgetSlot") or "No trait-removal reward available",
            })
        elseif forgetClaimed then
            self.skillList:addItem("forget_claimed", {
                isEmpty = true,
                text = getText("UI_BurdJournals_ForgetTraitUsed") or "Forget slot already used",
            })
        else
            local removableTraits = BurdJournals.getPlayerRemovableTraits and BurdJournals.getPlayerRemovableTraits(self.player) or {}
            local matchCount = 0
            for _, removableTraitId in ipairs(removableTraits) do
                local removableName = safeGetTraitName(removableTraitId)
                local rowName = string.format(getText("UI_BurdJournals_ForgetTraitPrefix") or "FORGET: %s", removableName)
                if self:matchesSearch(rowName) and self:passesFilter("vanilla") then
                    matchCount = matchCount + 1
                    self.skillList:addItem("forget_" .. tostring(removableTraitId), {
                        isForgetSlot = true,
                        isTrait = true,
                        traitId = removableTraitId,
                        traitName = rowName,
                        baseTraitName = removableName,
                        isClaimed = false,
                        alreadyKnown = false,
                        isPositive = false,
                        modSource = "vanilla",
                    })
                end
            end

            if #removableTraits == 0 then
                self.skillList:addItem("no_forget_traits", {
                    isEmpty = true,
                    text = getText("UI_BurdJournals_NoForgetableTraits") or "No removable traits available",
                })
            elseif matchCount == 0 then
                self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        end

    elseif currentTab == "recipes" then
        if journalData and journalData.recipes then
            local hasRecipes = false
            local matchCount = 0
            for recipeName, recipeData in pairs(journalData.recipes) do
                hasRecipes = true
                local isClaimed = BurdJournals.hasCharacterClaimedRecipe(journalData, self.player, recipeName)
                local alreadyKnown = BurdJournals.playerKnowsRecipe(self.player, recipeName)
                local displayName = BurdJournals.getRecipeDisplayName(recipeName)
                local magazineSource = (type(recipeData) == "table" and recipeData.source) or BurdJournals.getMagazineForRecipe(recipeName)
                local modSource = BurdJournals.getRecipeModId(recipeName, magazineSource)

                if self:matchesSearch(displayName) and self:passesFilter(modSource) then
                    matchCount = matchCount + 1
                    self.skillList:addItem(recipeName, {
                        isRecipe = true,
                        recipeName = recipeName,
                        displayName = displayName,
                        magazineSource = magazineSource,
                        isClaimed = isClaimed,
                        alreadyKnown = alreadyKnown,
                        modSource = modSource
                    })
                end
            end
            if not hasRecipes then
                self.skillList:addItem("empty_recipes", {isEmpty = true, text = getText("UI_BurdJournals_NoRecipesRecorded")})
            elseif matchCount == 0 then
                self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        else
            self.skillList:addItem("empty_recipes", {isEmpty = true, text = getText("UI_BurdJournals_NoRecipesAvailable")})
        end
    end
end

function BurdJournals.UI.MainPanel:refreshAbsorptionList()
    BurdJournals.debugPrint("[BurdJournals] UI: refreshAbsorptionList called")

    local journalData = BurdJournals.getJournalData(self.journal)
    local hasBloodyOrigin = BurdJournals.hasBloodyOrigin(self.journal)
    local isDebugSpawned = journalData and journalData.isDebugSpawned

    local claimedCount = journalData and journalData.claimedSkills and BurdJournals.countTable(journalData.claimedSkills) or 0
    BurdJournals.debugPrint("[BurdJournals] UI: refreshAbsorptionList sees claimedSkills count: " .. tostring(claimedCount))

    local skillCount = 0
    local traitCount = 0
    local forgetCount = 0
    local recipeCount = 0
    local totalXP = 0

    if journalData and journalData.skills then
        for skillName, skillData in pairs(journalData.skills) do
            if isSkillVisibleForJournal(journalData, skillName) then
                if not BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName) then
                    skillCount = skillCount + 1
                    -- Calculate effective XP with skill book multiplier
                    local effectiveXP = BurdJournals.getEffectiveXP(self.player, skillName, skillData.xp or 0)
                    totalXP = totalXP + effectiveXP
                end
            end
        end
    end
    if (hasBloodyOrigin or isDebugSpawned) and journalData and journalData.traits then
        for traitId, _ in pairs(journalData.traits) do
            if not BurdJournals.hasCharacterClaimedTrait(journalData, self.player, traitId) then
                traitCount = traitCount + 1
            end
        end
    end
    if journalData and journalData.forgetSlot == true
        and BurdJournals.isForgetSlotEnabledForJournal
        and BurdJournals.isForgetSlotEnabledForJournal(journalData)
        and BurdJournals.hasCharacterClaimedForgetSlot
        and not BurdJournals.hasCharacterClaimedForgetSlot(journalData, self.player)
        and BurdJournals.getPlayerRemovableTraits then
        local removableTraits = BurdJournals.getPlayerRemovableTraits(self.player)
        forgetCount = #removableTraits
    end
    if journalData and journalData.recipes then
        for recipeName, _ in pairs(journalData.recipes) do
            if not BurdJournals.hasCharacterClaimedRecipe(journalData, self.player, recipeName) then
                recipeCount = recipeCount + 1
            end
        end
    end

    self.skillCount = skillCount
    self.traitCount = traitCount
    self.forgetCount = forgetCount
    self.recipeCount = recipeCount
    self.totalXP = totalXP

    if self.mode == "view" then
        self:populateViewList()
    else
        self:populateAbsorptionList()
    end
end

function BurdJournals.UI.MainPanel:getReadingSpeedMultiplier()
    if not BurdJournals.getSandboxOption("ReadingSkillAffectsSpeed") then
        return 1.0
    end

    local bonusPerLevel = BurdJournals.getSandboxOption("ReadingSpeedBonus") or 0.1
    local readingLevel = 0

    if self.player then
        if self.player.getReadingLevel then
            readingLevel = self.player:getReadingLevel() or 0
        end
    end

    local speedBonus = readingLevel * bonusPerLevel
    local speedMultiplier = math.max(0.1, 1.0 - speedBonus)

    return speedMultiplier
end

function BurdJournals.UI.MainPanel:getTabDisplayName(tabId)
    local tabNames = {
        skills = getText("UI_BurdJournals_TabSkills") or "Skills",
        traits = getText("UI_BurdJournals_TabTraits") or "Traits",
        forget = getText("UI_BurdJournals_TabForget") or "Forget",
        recipes = getText("UI_BurdJournals_TabRecipes") or "Recipes",
        stats = getText("UI_BurdJournals_TabStats") or "Stats",
        charinfo = getText("UI_BurdJournals_TabStats") or "Stats",
    }
    return tabNames[tabId] or "Items"
end

function BurdJournals.UI.MainPanel:getSkillLearningTime()
    local baseTime = BurdJournals.getSandboxOption("LearningTimePerSkill") or 3.0
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    local readingMultiplier = self:getReadingSpeedMultiplier()
    return baseTime * multiplier * readingMultiplier
end

function BurdJournals.UI.MainPanel:getTraitLearningTime()
    local baseTime = BurdJournals.getSandboxOption("LearningTimePerTrait") or 5.0
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    local readingMultiplier = self:getReadingSpeedMultiplier()
    return baseTime * multiplier * readingMultiplier
end

function BurdJournals.UI.MainPanel:getStatLearningTime()
    -- Stats use the same timing as traits (5 seconds base)
    local baseTime = BurdJournals.getSandboxOption("LearningTimePerTrait") or 5.0
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    local readingMultiplier = self:getReadingSpeedMultiplier()
    return baseTime * multiplier * readingMultiplier
end

function BurdJournals.UI.MainPanel:startLearningSkill(skillName, xp)
    if self.learningState.active then

        return false
    end

    local rewards = {{type = "skill", name = skillName, xp = xp}}

    if BurdJournals.queueLearnAction then
        return BurdJournals.queueLearnAction(self.player, self.journal, rewards, false, self)
    end

    self.learningState = {
        active = true,
        skillName = skillName,
        traitId = nil,
        isAbsorbAll = false,
        progress = 0,
        totalTime = self:getSkillLearningTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRewards = rewards,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self:playSound(BurdJournals.Sounds.PAGE_TURN)

    return true
end

function BurdJournals.UI.MainPanel:startLearningTrait(traitId)
    if self.learningState.active then
        return false
    end

    if BurdJournals.playerHasTrait(self.player, traitId) then
        return false
    end

    local rewards = {{type = "trait", name = traitId}}

    if BurdJournals.queueLearnAction then
        return BurdJournals.queueLearnAction(self.player, self.journal, rewards, false, self)
    end

    self.learningState = {
        active = true,
        skillName = nil,
        traitId = traitId,
        isAbsorbAll = false,
        progress = 0,
        totalTime = self:getTraitLearningTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRewards = rewards,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self:playSound(BurdJournals.Sounds.PAGE_TURN)

    return true
end

function BurdJournals.UI.MainPanel:startLearningRecipe(recipeName)
    if self.learningState.active then
        return false
    end

    local rewards = {{type = "recipe", name = recipeName}}

    if BurdJournals.queueLearnAction then
        return BurdJournals.queueLearnAction(self.player, self.journal, rewards, false, self)
    end

    self.learningState = {
        active = true,
        skillName = nil,
        traitId = nil,
        recipeName = recipeName,
        isAbsorbAll = false,
        progress = 0,
        totalTime = self:getRecipeLearningTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRewards = rewards,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self:playSound(BurdJournals.Sounds.PAGE_TURN)

    return true
end

function BurdJournals.UI.MainPanel:startLearningStat(statId, value)
    if self.learningState.active then
        return false
    end

    -- Validate the stat can be absorbed
    local journalData = BurdJournals.getJournalData(self.journal)
    if not journalData then return false end

    local canAbsorb, recValue, curValue, reason = BurdJournals.canAbsorbStat(journalData, self.player, statId)
    if not canAbsorb then
        -- Convert reason codes to user-friendly messages
        local message = "Cannot absorb this stat"
        if reason == "not_absorbable" then
            message = "This stat cannot be absorbed"
        elseif reason == "already_claimed" then
            message = "Already claimed from this journal"
        elseif reason == "no_benefit" then
            message = "Your current value is already higher or equal"
        end
        self:showFeedback(message, {r=0.9, g=0.7, b=0.3})
        return false
    end

    local rewards = {{type = "stat", name = statId, value = value}}

    if BurdJournals.queueLearnAction then
        return BurdJournals.queueLearnAction(self.player, self.journal, rewards, false, self)
    end

    self.learningState = {
        active = true,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        statId = statId,
        isAbsorbAll = false,
        progress = 0,
        totalTime = self:getStatLearningTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRewards = rewards,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self:playSound(BurdJournals.Sounds.PAGE_TURN)

    return true
end

function BurdJournals.UI.MainPanel:getRecipeLearningTime()

    local baseTime = (BurdJournals.getSandboxOption("LearningTimePerRecipe") or 2.0) * 0.35
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    local readingMultiplier = self:getReadingSpeedMultiplier()
    return baseTime * multiplier * readingMultiplier
end

function BurdJournals.UI.MainPanel:startLearningAll()
    if self.learningState.active then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
        return false
    end

    local journalData = BurdJournals.getJournalData(self.journal)
    if not journalData then return false end

    local isPlayerJournal = self.isPlayerJournal or self.mode == "view"
    local hasBloodyOrigin = BurdJournals.hasBloodyOrigin(self.journal)
    local isDebugSpawned = journalData and journalData.isDebugSpawned
    local pendingRewards = {}

    if journalData.skills then
        for skillName, skillData in pairs(journalData.skills) do
            if isSkillVisibleForJournal(journalData, skillName) then
                local shouldInclude = false
                local recordedXP = skillData.xp or 0
                local preview = getClaimPreviewForSkill(journalData, self.player, skillName, recordedXP, 0, getClaimSessionIdForPanel(self, false))

                if isPlayerJournal then
                    local perk = BurdJournals.getPerkByName(skillName)
                    if perk then
                        local playerXP = self.player:getXp():getXP(perk)
                        local claimTargetXP = getClaimTargetXPForPlayer(journalData, self.player, skillName, preview.effectiveXP)
                        shouldInclude = playerXP < claimTargetXP
                    end
                else
                    -- For non-player journals, check per-character claim status
                    if not BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName) then
                        shouldInclude = true
                    end
                end

                if shouldInclude then
                    table.insert(pendingRewards, {type = "skill", name = skillName, xp = recordedXP})
                end
            end
        end
    end

    local hasTraits = (isPlayerJournal and journalData.traits) or (hasBloodyOrigin and journalData.traits) or (isDebugSpawned and journalData.traits)
    if hasTraits then
        for traitId, _ in pairs(journalData.traits) do
            local shouldInclude = false

            if isPlayerJournal then

                if not BurdJournals.playerHasTrait(self.player, traitId) then
                    shouldInclude = true
                end
            else

                if not BurdJournals.hasCharacterClaimedTrait(journalData, self.player, traitId) and
                   not BurdJournals.playerHasTrait(self.player, traitId) then
                    shouldInclude = true
                end
            end

            if shouldInclude then
                table.insert(pendingRewards, {type = "trait", name = traitId})
            end
        end
    end

    if journalData.recipes then
        for recipeName, _ in pairs(journalData.recipes) do
            local shouldInclude = false

            if isPlayerJournal then

                if not BurdJournals.playerKnowsRecipe(self.player, recipeName) then
                    shouldInclude = true
                end
            else

                if not BurdJournals.hasCharacterClaimedRecipe(journalData, self.player, recipeName) and
                   not BurdJournals.playerKnowsRecipe(self.player, recipeName) then
                    shouldInclude = true
                end
            end

            if shouldInclude then
                table.insert(pendingRewards, {type = "recipe", name = recipeName})
            end
        end
    end

    -- Add stats to the queue with timed action like other rewards
    if journalData.stats and BurdJournals.ABSORBABLE_STATS then
        for statId, statData in pairs(journalData.stats) do
            local canAbsorb, recValue, curValue, reason = BurdJournals.canAbsorbStat(journalData, self.player, statId)
            if canAbsorb and recValue then
                table.insert(pendingRewards, {type = "stat", name = statId, value = recValue})
            end
        end
    end

    if #pendingRewards == 0 then
        self:showFeedback(getText("UI_BurdJournals_NoNewRewards") or "No new rewards to claim", {r=0.7, g=0.7, b=0.5})
        return false
    end

    if BurdJournals.queueLearnAction then
        return BurdJournals.queueLearnAction(self.player, self.journal, pendingRewards, true, self)
    end

    local totalTime = 0
    for _, reward in ipairs(pendingRewards) do
        if reward.type == "skill" then
            totalTime = totalTime + self:getSkillLearningTime()
        elseif reward.type == "trait" then
            totalTime = totalTime + self:getTraitLearningTime()
        elseif reward.type == "recipe" then
            totalTime = totalTime + self:getRecipeLearningTime()
        elseif reward.type == "stat" then
            totalTime = totalTime + self:getStatLearningTime()
        end
    end

    self.learningState = {
        active = true,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        statId = nil,
        isAbsorbAll = true,
        progress = 0,
        totalTime = totalTime,
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRewards = pendingRewards,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self:playSound(BurdJournals.Sounds.PAGE_TURN)

    return true
end

function BurdJournals.UI.MainPanel:startLearningTab(tabId)
    if self.learningState.active then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
        return false
    end

    local journalData = BurdJournals.getJournalData(self.journal)
    if not journalData then return false end

    local isPlayerJournal = self.isPlayerJournal or self.mode == "view"
    local hasBloodyOrigin = BurdJournals.hasBloodyOrigin(self.journal)
    local isDebugSpawned = journalData and journalData.isDebugSpawned
    local pendingRewards = {}

    if tabId == "skills" then

        if journalData.skills then
            for skillName, skillData in pairs(journalData.skills) do
                if isSkillVisibleForJournal(journalData, skillName) then
                    local shouldInclude = false
                    local recordedXP = skillData.xp or 0
                    local preview = getClaimPreviewForSkill(journalData, self.player, skillName, recordedXP, 0, getClaimSessionIdForPanel(self, false))

                    if isPlayerJournal then
                        local perk = BurdJournals.getPerkByName(skillName)
                        if perk then
                            local playerXP = self.player:getXp():getXP(perk)
                            local claimTargetXP = getClaimTargetXPForPlayer(journalData, self.player, skillName, preview.effectiveXP)
                            if playerXP < claimTargetXP then
                                shouldInclude = true
                            end
                        end
                    else
                        if not BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName) then
                            shouldInclude = true
                        end
                    end

                    if shouldInclude then
                        table.insert(pendingRewards, {type = "skill", name = skillName, xp = recordedXP})
                    end
                end
            end
        end

    elseif tabId == "traits" then

        local hasTraits = (isPlayerJournal and journalData.traits) or (hasBloodyOrigin and journalData.traits) or (isDebugSpawned and journalData.traits)
        if hasTraits then
            for traitId, _ in pairs(journalData.traits) do
                local shouldInclude = false

                if isPlayerJournal then
                    if not BurdJournals.playerHasTrait(self.player, traitId) then
                        shouldInclude = true
                    end
                else

                    if not BurdJournals.hasCharacterClaimedTrait(journalData, self.player, traitId) and
                       not BurdJournals.playerHasTrait(self.player, traitId) then
                        shouldInclude = true
                    end
                end

                if shouldInclude then
                    table.insert(pendingRewards, {type = "trait", name = traitId})
                end
            end
        end

    elseif tabId == "recipes" then

        if journalData.recipes then
            for recipeName, _ in pairs(journalData.recipes) do
                local shouldInclude = false

                if isPlayerJournal then

                    if not BurdJournals.playerKnowsRecipe(self.player, recipeName) then
                        shouldInclude = true
                    end
                else

                    if not BurdJournals.hasCharacterClaimedRecipe(journalData, self.player, recipeName) and
                       not BurdJournals.playerKnowsRecipe(self.player, recipeName) then
                        shouldInclude = true
                    end
                end

                if shouldInclude then
                    table.insert(pendingRewards, {type = "recipe", name = recipeName})
                end
            end
        end

    elseif tabId == "stats" then
        -- Stats use the timed action queue like other rewards
        if journalData.stats and BurdJournals.ABSORBABLE_STATS then
            for statId, statData in pairs(journalData.stats) do
                local canAbsorb, recValue, curValue, reason = BurdJournals.canAbsorbStat(journalData, self.player, statId)
                if canAbsorb and recValue then
                    table.insert(pendingRewards, {type = "stat", name = statId, value = recValue})
                end
            end
        end
    end

    if #pendingRewards == 0 then
        local tabName = self:getTabDisplayName(tabId)
        self:showFeedback(getText("UI_BurdJournals_NoNewRewards") or "No new rewards", {r=0.7, g=0.7, b=0.5})
        return false
    end

    if BurdJournals.queueLearnAction then
        return BurdJournals.queueLearnAction(self.player, self.journal, pendingRewards, true, self)
    end

    local totalTime = 0
    for _, reward in ipairs(pendingRewards) do
        if reward.type == "skill" then
            totalTime = totalTime + self:getSkillLearningTime()
        elseif reward.type == "trait" then
            totalTime = totalTime + self:getTraitLearningTime()
        elseif reward.type == "recipe" then
            totalTime = totalTime + self:getRecipeLearningTime()
        elseif reward.type == "stat" then
            totalTime = totalTime + self:getStatLearningTime()
        end
    end

    self.learningState = {
        active = true,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        statId = nil,
        isAbsorbAll = true,
        progress = 0,
        totalTime = totalTime,
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRewards = pendingRewards,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self:playSound(BurdJournals.Sounds.PAGE_TURN)

    return true
end

function BurdJournals.UI.MainPanel:cancelLearning()
    if self.learningState.active then
        self.learningState.active = false
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onLearningTickStatic)

        if self.learningState.timedAction and ISTimedActionQueue then
            ISTimedActionQueue.clear(self.player)
        end
    end
    self.learningState = {
        active = false,
        skillName = nil,
        traitId = nil,
        isAbsorbAll = false,
        progress = 0,
        totalTime = 0,
        startTime = 0,
        pendingRewards = {},
        currentIndex = 0,
        queue = {},
    }
    self.learningCompleted = false
    self.processingQueue = false
end

function BurdJournals.UI.MainPanel:getSkillRecordingTime()
    local baseTime = (BurdJournals.getSandboxOption("LearningTimePerSkill") or 3.0) * 0.5
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    return baseTime * multiplier
end

function BurdJournals.UI.MainPanel:getTraitRecordingTime()
    local baseTime = (BurdJournals.getSandboxOption("LearningTimePerTrait") or 5.0) * 0.5
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    return baseTime * multiplier
end

function BurdJournals.UI.MainPanel:startRecordingSkill(skillName, xp, level)
    if self.recordingState and self.recordingState.active then
        return false
    end

    if not self.recordingState then
        self.recordingState = {}
    end

    local records = {{type = "skill", name = skillName, xp = xp, level = level}}

    if BurdJournals.queueRecordAction then
        return BurdJournals.queueRecordAction(self.player, self.journal, records, false, self)
    end

    self.recordingState = {
        active = true,
        skillName = skillName,
        traitId = nil,
        isRecordAll = false,
        progress = 0,
        totalTime = self:getSkillRecordingTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRecords = records,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    return true
end

function BurdJournals.UI.MainPanel:startRecordingTrait(traitId)
    if self.recordingState and self.recordingState.active then
        return false
    end

    if not self.recordingState then
        self.recordingState = {}
    end

    local records = {{type = "trait", name = traitId}}

    if BurdJournals.queueRecordAction then
        return BurdJournals.queueRecordAction(self.player, self.journal, records, false, self)
    end

    self.recordingState = {
        active = true,
        skillName = nil,
        traitId = traitId,
        isRecordAll = false,
        progress = 0,
        totalTime = self:getTraitRecordingTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRecords = records,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    return true
end

function BurdJournals.UI.MainPanel:startRecordingStat(statId, value)
    if self.recordingState and self.recordingState.active then
        return false
    end

    if not self.recordingState then
        self.recordingState = {}
    end

    local records = {{type = "stat", name = statId, value = value}}

    if BurdJournals.queueRecordAction then
        return BurdJournals.queueRecordAction(self.player, self.journal, records, false, self)
    end

    self.recordingState = {
        active = true,
        skillName = nil,
        traitId = nil,
        statId = statId,
        isRecordAll = false,
        progress = 0,
        totalTime = self:getStatRecordingTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRecords = records,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    return true
end

function BurdJournals.UI.MainPanel:getStatRecordingTime()
    return self:getSkillRecordingTime()
end

function BurdJournals.UI.MainPanel:getRecipeRecordingTime()
    local baseTime = (BurdJournals.getSandboxOption("LearningTimePerRecipe") or 5.0) * 0.16
    local multiplier = BurdJournals.getSandboxOption("LearningTimeMultiplier") or 1.0
    return baseTime * multiplier
end

function BurdJournals.UI.MainPanel:startRecordingRecipe(recipeName)
    if self.recordingState and self.recordingState.active then
        return false
    end

    if not self.recordingState then
        self.recordingState = {}
    end

    local records = {{type = "recipe", name = recipeName}}

    if BurdJournals.queueRecordAction then
        return BurdJournals.queueRecordAction(self.player, self.journal, records, false, self)
    end

    self.recordingState = {
        active = true,
        skillName = nil,
        traitId = nil,
        statId = nil,
        recipeName = recipeName,
        isRecordAll = false,
        progress = 0,
        totalTime = self:getRecipeRecordingTime(),
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRecords = records,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    return true
end

function BurdJournals.UI.MainPanel:checkJournalCapacity(pendingSkillCount, pendingTraitCount, pendingRecipeCount)
    local limits = BurdJournals.Limits or {}
    local warnings = {}

    local currentSkills = 0
    local currentTraits = 0
    local currentRecipes = 0

    if self.recordedSkills then
        for _ in pairs(self.recordedSkills) do currentSkills = currentSkills + 1 end
    end
    if self.recordedTraits then
        for _ in pairs(self.recordedTraits) do currentTraits = currentTraits + 1 end
    end
    if self.recordedRecipes then
        for _ in pairs(self.recordedRecipes) do currentRecipes = currentRecipes + 1 end
    end

    local maxSkills = limits.MAX_SKILLS or 50
    local maxTraits = limits.MAX_TRAITS or 100
    local maxRecipes = limits.MAX_RECIPES or 200
    local warnSkills = limits.WARN_SKILLS or 25
    local warnTraits = limits.WARN_TRAITS or 40
    local warnRecipes = limits.WARN_RECIPES or 80

    local newSkillTotal = currentSkills + (pendingSkillCount or 0)
    local newTraitTotal = currentTraits + (pendingTraitCount or 0)
    local newRecipeTotal = currentRecipes + (pendingRecipeCount or 0)

    if newSkillTotal > maxSkills then
        return false, string.format("Too many skills! Journal limit is %d (would have %d)", maxSkills, newSkillTotal)
    end
    if newTraitTotal > maxTraits then
        return false, string.format("Too many traits! Journal limit is %d (would have %d)", maxTraits, newTraitTotal)
    end
    if newRecipeTotal > maxRecipes then
        return false, string.format("Too many recipes! Journal limit is %d (would have %d)", maxRecipes, newRecipeTotal)
    end

    if newSkillTotal >= warnSkills and pendingSkillCount > 0 then
        table.insert(warnings, string.format(getText("UI_BurdJournals_CapacitySkills") or "Skills: %d/%d", newSkillTotal, maxSkills))
    end
    if newTraitTotal >= warnTraits and pendingTraitCount > 0 then
        table.insert(warnings, string.format(getText("UI_BurdJournals_CapacityTraits") or "Traits: %d/%d", newTraitTotal, maxTraits))
    end
    if newRecipeTotal >= warnRecipes and pendingRecipeCount > 0 then
        table.insert(warnings, string.format(getText("UI_BurdJournals_CapacityRecipes") or "Recipes: %d/%d", newRecipeTotal, maxRecipes))
    end

    if #warnings > 0 then
        return true, string.format(getText("UI_BurdJournals_ApproachingCapacity") or "Journal approaching capacity: %s", table.concat(warnings, ", "))
    end

    return true, nil
end

function BurdJournals.UI.MainPanel:startRecordingAll()
    if self.recordingState and self.recordingState.active then
        BurdJournals.debugPrint("[BurdJournals] startRecordingAll: BLOCKED - recordingState.active is true")
        return false
    end
    BurdJournals.debugPrint("[BurdJournals] startRecordingAll: Starting...")

    local journalData = BurdJournals.getJournalData(self.journal) or {}
    local useBaseline, autoRepairedMode = resolveJournalRecordingModeForPlayer(journalData, self.player)
    if autoRepairedMode then
        BurdJournals.debugPrint("[BurdJournals] startRecordingAll: detected legacy absolute journal entries while baseline flag was set; using absolute mode for this pass")
    end

    local baselineReady, normalizedUseBaseline = ensureBaselineReadyForRecording(self, useBaseline, "startRecordingAll")
    useBaseline = normalizedUseBaseline
    if not baselineReady then
        self:showFeedback(getText("UI_BurdJournals_BaselineInitializing") or "Please wait - character data initializing...", {r=1, g=0.8, b=0.3})
        return false
    end

    if not self.recordingState then
        self.recordingState = {}
    end

    local pendingRecords = {}

    local allowedSkills = BurdJournals.getAllowedSkills()
    local recordedSkills = self.recordedSkills or {}
    local recordedTraits = self.recordedTraits or {}

    for _, skillName in ipairs(allowedSkills) do
        if isSkillRecordableInPlayerJournal(skillName) then
            local perk = BurdJournals.getPerkByName(skillName)
            if perk then
                local currentXP = self.player:getXp():getXP(perk)
                local currentLevel = self.player:getPerkLevel(perk)
                local recordedData = recordedSkills[skillName]
                local recordedXP = recordedData and recordedData.xp or 0

                local baselineXP = 0
                if useBaseline then
                    baselineXP = BurdJournals.getSkillBaseline(self.player, skillName)
                end

                local earnedXP = math.max(0, currentXP - baselineXP)

                if earnedXP > 0 and earnedXP > recordedXP then
                    table.insert(pendingRecords, {type = "skill", name = skillName, xp = earnedXP, level = currentLevel})
                end
            end
        end
    end

    local playerTraits = BurdJournals.collectPlayerTraits(self.player)
    local traitBaseline = BurdJournals.getTraitBaseline(self.player) or {}
    local grantableTraits = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or BurdJournals.GRANTABLE_TRAITS or {}
    local traitDebug = getDebug()
    for traitId, _ in pairs(playerTraits) do

        local isGrantable = BurdJournals.isTraitGrantable(traitId, grantableTraits)

        local isStartingTrait = traitBaseline[traitId] or traitBaseline[string.lower(traitId)]

        local isRecorded = recordedTraits[traitId] or recordedTraits[string.lower(traitId)]

        if traitDebug then
            BurdJournals.debugPrint("[BurdJournals] Trait check: " .. traitId .. " | grantable=" .. tostring(isGrantable) ..
                  " | starting=" .. tostring(isStartingTrait) .. " | recorded=" .. tostring(isRecorded))
        end

        if isGrantable and not isStartingTrait and not isRecorded then
            table.insert(pendingRecords, {type = "trait", name = traitId})
        end
    end

    if BurdJournals.getSandboxOption("EnableStatRecording") then
        for _, stat in ipairs(BurdJournals.RECORDABLE_STATS) do
            if BurdJournals.isStatEnabled(stat.id) then
                local canUpdate, currentVal, _ = BurdJournals.canUpdateStat(self.journal, stat.id, self.player)
                if canUpdate then
                    table.insert(pendingRecords, {type = "stat", name = stat.id, value = currentVal})
                end
            end
        end
    end

    if BurdJournals.isRecipeRecordingEnabled() then
        local recordedRecipes = self.recordedRecipes or {}
        local playerRecipes = BurdJournals.collectPlayerMagazineRecipes(self.player)
        for recipeName, recipeData in pairs(playerRecipes) do
            if not recordedRecipes[recipeName] then
                table.insert(pendingRecords, {type = "recipe", name = recipeName})
            end
        end
    end

    if #pendingRecords == 0 then
        self:showFeedback(getText("UI_BurdJournals_NothingNewToRecord") or "Nothing new to record", {r=0.7, g=0.7, b=0.5})
        return false
    end

    local pendingSkillCount, pendingTraitCount, pendingRecipeCount = 0, 0, 0
    for _, record in ipairs(pendingRecords) do
        if record.type == "skill" then pendingSkillCount = pendingSkillCount + 1
        elseif record.type == "trait" then pendingTraitCount = pendingTraitCount + 1
        elseif record.type == "recipe" then pendingRecipeCount = pendingRecipeCount + 1
        end
    end

    local canRecord, capacityMsg = self:checkJournalCapacity(pendingSkillCount, pendingTraitCount, pendingRecipeCount)
    if not canRecord then
        self:showFeedback(capacityMsg, {r=1, g=0.4, b=0.4})
        return false
    end
    if capacityMsg then

        self:showFeedback(capacityMsg, {r=1, g=0.8, b=0.3})
    end

    if BurdJournals.queueRecordAction then
        return BurdJournals.queueRecordAction(self.player, self.journal, pendingRecords, true, self)
    end

    local totalTime = 0
    for _, record in ipairs(pendingRecords) do
        if record.type == "skill" then
            totalTime = totalTime + self:getSkillRecordingTime()
        elseif record.type == "trait" then
            totalTime = totalTime + self:getTraitRecordingTime()
        elseif record.type == "recipe" then
            totalTime = totalTime + self:getRecipeRecordingTime()
        else
            totalTime = totalTime + self:getStatRecordingTime()
        end
    end

    self.recordingState = {
        active = true,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        isRecordAll = true,
        progress = 0,
        totalTime = totalTime,
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRecords = pendingRecords,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    return true
end

function BurdJournals.UI.MainPanel:startRecordingTab(tabId)
    if self.recordingState and self.recordingState.active then
        return false
    end

    local journalData = BurdJournals.getJournalData(self.journal) or {}
    local useBaseline, autoRepairedMode = resolveJournalRecordingModeForPlayer(journalData, self.player)
    if autoRepairedMode then
        BurdJournals.debugPrint("[BurdJournals] startRecordingTab: detected legacy absolute journal entries while baseline flag was set; using absolute mode for this pass")
    end

    local baselineReady, normalizedUseBaseline = ensureBaselineReadyForRecording(self, useBaseline, "startRecordingTab")
    useBaseline = normalizedUseBaseline
    if not baselineReady then
        self:showFeedback(getText("UI_BurdJournals_BaselineInitializing") or "Please wait - character data initializing...", {r=1, g=0.8, b=0.3})
        return false
    end

    if not self.recordingState then
        self.recordingState = {}
    end

    local pendingRecords = {}

    local recordedSkills = self.recordedSkills or {}
    local recordedTraits = self.recordedTraits or {}

    if tabId == "skills" then

        local allowedSkills = BurdJournals.getAllowedSkills()
        for _, skillName in ipairs(allowedSkills) do
            if isSkillRecordableInPlayerJournal(skillName) then
                local perk = BurdJournals.getPerkByName(skillName)
                if perk then
                    local currentXP = self.player:getXp():getXP(perk)
                    local currentLevel = self.player:getPerkLevel(perk)
                    local recordedData = recordedSkills[skillName]
                    local recordedXP = recordedData and recordedData.xp or 0

                    local baselineXP = 0
                    if useBaseline then
                        baselineXP = BurdJournals.getSkillBaseline(self.player, skillName)
                    end

                    local earnedXP = math.max(0, currentXP - baselineXP)

                    if earnedXP > 0 and earnedXP > recordedXP then
                        table.insert(pendingRecords, {type = "skill", name = skillName, xp = earnedXP, level = currentLevel})
                    end
                end
            end
        end

    elseif tabId == "traits" then

        local playerTraits = BurdJournals.collectPlayerTraits(self.player)
        local traitBaseline = BurdJournals.getTraitBaseline(self.player) or {}
        local grantableTraits = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or BurdJournals.GRANTABLE_TRAITS or {}
        for traitId, _ in pairs(playerTraits) do

            local isGrantable = BurdJournals.isTraitGrantable(traitId, grantableTraits)
            local isStartingTrait = traitBaseline[traitId] or traitBaseline[string.lower(traitId)]

            local isRecorded = recordedTraits[traitId] or recordedTraits[string.lower(traitId)]

            if isGrantable and not isStartingTrait and not isRecorded then
                table.insert(pendingRecords, {type = "trait", name = traitId})
            end
        end

    elseif tabId == "recipes" then

        if BurdJournals.isRecipeRecordingEnabled() then
            local recordedRecipes = self.recordedRecipes or {}
            local playerRecipes = BurdJournals.collectPlayerMagazineRecipes(self.player)
            for recipeName, recipeData in pairs(playerRecipes) do
                if not recordedRecipes[recipeName] then
                    table.insert(pendingRecords, {type = "recipe", name = recipeName})
                end
            end
        end

    elseif tabId == "stats" then

        if BurdJournals.getSandboxOption("EnableStatRecording") then
            for _, stat in ipairs(BurdJournals.RECORDABLE_STATS) do
                if BurdJournals.isStatEnabled(stat.id) then
                    local canUpdate, currentVal, _ = BurdJournals.canUpdateStat(self.journal, stat.id, self.player)
                    if canUpdate then
                        table.insert(pendingRecords, {type = "stat", name = stat.id, value = currentVal})
                    end
                end
            end
        end
    end

    if #pendingRecords == 0 then
        self:showFeedback(getText("UI_BurdJournals_NothingNewToRecord") or "Nothing new to record", {r=0.7, g=0.7, b=0.5})
        return false
    end

    local pendingSkillCount, pendingTraitCount, pendingRecipeCount = 0, 0, 0
    for _, record in ipairs(pendingRecords) do
        if record.type == "skill" then pendingSkillCount = pendingSkillCount + 1
        elseif record.type == "trait" then pendingTraitCount = pendingTraitCount + 1
        elseif record.type == "recipe" then pendingRecipeCount = pendingRecipeCount + 1
        end
    end

    local canRecord, capacityMsg = self:checkJournalCapacity(pendingSkillCount, pendingTraitCount, pendingRecipeCount)
    if not canRecord then
        self:showFeedback(capacityMsg, {r=1, g=0.4, b=0.4})
        return false
    end
    if capacityMsg then

        self:showFeedback(capacityMsg, {r=1, g=0.8, b=0.3})
    end

    if BurdJournals.queueRecordAction then
        return BurdJournals.queueRecordAction(self.player, self.journal, pendingRecords, true, self)
    end

    local totalTime = 0
    for _, record in ipairs(pendingRecords) do
        if record.type == "skill" then
            totalTime = totalTime + self:getSkillRecordingTime()
        elseif record.type == "trait" then
            totalTime = totalTime + self:getTraitRecordingTime()
        elseif record.type == "recipe" then
            totalTime = totalTime + self:getRecipeRecordingTime()
        else
            totalTime = totalTime + self:getStatRecordingTime()
        end
    end

    self.recordingState = {
        active = true,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        isRecordAll = true,
        progress = 0,
        totalTime = totalTime,
        startTime = getTimestampMs and getTimestampMs() or 0,
        pendingRecords = pendingRecords,
        currentIndex = 1,
        queue = {},
    }

    Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    return true
end

function BurdJournals.UI.MainPanel:cancelRecording()
    if self.recordingState and self.recordingState.active then
        self.recordingState.active = false
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onRecordingTickStatic)

        if self.recordingState.timedAction and ISTimedActionQueue then
            ISTimedActionQueue.clear(self.player)
        end
    end
    if self.recordingState then
        self.recordingState = {
            active = false,
            skillName = nil,
            traitId = nil,
            isRecordAll = false,
            progress = 0,
            totalTime = 0,
            startTime = 0,
            pendingRecords = {},
            currentIndex = 0,
            queue = {},
        }
    end
    self.recordingCompleted = false
    self.processingRecordQueue = false
end

function BurdJournals.UI.MainPanel.onRecordingTickStatic()
    local instance = BurdJournals.UI.MainPanel.instance
    if instance and instance.recordingState and instance.recordingState.active then
        instance:onRecordingTick()
    else
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onRecordingTickStatic)
    end
end

BurdJournals.UI.MainPanel._pendingJournalRetryActive = false

function BurdJournals.UI.MainPanel.onPendingJournalRetryStatic()
    local instance = BurdJournals.UI.MainPanel.instance
    if not instance or not instance.pendingNewJournalId then
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onPendingJournalRetryStatic)
        BurdJournals.UI.MainPanel._pendingJournalRetryActive = false
        return
    end

    local newJournal = BurdJournals.findItemById(instance.player, instance.pendingNewJournalId)
    if newJournal then
        BurdJournals.debugPrint("[BurdJournals] onPendingJournalRetryStatic: Found pending journal!")
        instance.journal = newJournal
        instance.pendingNewJournalId = nil
        instance.pendingRecordingRetryCount = 0
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onPendingJournalRetryStatic)
        BurdJournals.UI.MainPanel._pendingJournalRetryActive = false

        if instance.pendingRecordingData then
            instance.recordingState = {
                active = false,
                pendingRecords = instance.pendingRecordingData.pendingRecords,
                queue = instance.pendingRecordingData.queue,
                isRecordAll = instance.pendingRecordingData.isRecordAll
            }
            instance.pendingRecordingData = nil
            instance:completeRecording()
        end
    else

        instance.pendingRecordingRetryCount = (instance.pendingRecordingRetryCount or 0) + 1
        if instance.pendingRecordingRetryCount >= 20 then
            BurdJournals.debugPrint("[BurdJournals] onPendingJournalRetryStatic: Max retries, giving up")
            Events.OnTick.Remove(BurdJournals.UI.MainPanel.onPendingJournalRetryStatic)
            BurdJournals.UI.MainPanel._pendingJournalRetryActive = false
            instance.pendingRecordingRetryCount = 0
            instance.pendingNewJournalId = nil

            if instance.showFeedback then
                instance:showFeedback(getText("UI_BurdJournals_JournalSyncFailed") or "Error: Journal sync failed", {r=0.8, g=0.3, b=0.3})
            end
        end
    end
end

function BurdJournals.UI.MainPanel:onRecordingTick()
    if not self.recordingState or not self.recordingState.active then
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onRecordingTickStatic)
        return
    end

    local now = getTimestampMs and getTimestampMs() or 0
    if now == 0 or self.recordingState.startTime == 0 then
        -- Fallback: complete immediately if no timestamp available
        self:completeRecording()
        return
    end
    local elapsed = (now - self.recordingState.startTime) / 1000.0
    self.recordingState.progress = math.min(1.0, elapsed / self.recordingState.totalTime)

    if self.recordingState.progress >= 1.0 then
        self:completeRecording()
    end
end

function BurdJournals.UI.MainPanel:completeRecording()
    Events.OnTick.Remove(BurdJournals.UI.MainPanel.onRecordingTickStatic)

    self.processingRecordQueue = true

    if self.pendingNewJournalId then
        BurdJournals.debugPrint("[BurdJournals] completeRecording: Checking for pending journal ID " .. tostring(self.pendingNewJournalId))
        local newJournal = BurdJournals.findItemById(self.player, self.pendingNewJournalId)
        if newJournal then
            BurdJournals.debugPrint("[BurdJournals] completeRecording: Found pending journal, updating reference")
            self.journal = newJournal
            self.pendingNewJournalId = nil
        else

            BurdJournals.debugPrint("[BurdJournals] completeRecording: Pending journal not found yet, scheduling retry...")
            self.pendingRecordingRetryCount = (self.pendingRecordingRetryCount or 0) + 1
            if self.pendingRecordingRetryCount < 20 then

                self.pendingRecordingData = {
                    pendingRecords = self.recordingState.pendingRecords,
                    queue = self.recordingState.queue,
                    isRecordAll = self.recordingState.isRecordAll
                }

                if not BurdJournals.UI.MainPanel._pendingJournalRetryActive then
                    BurdJournals.UI.MainPanel._pendingJournalRetryActive = true
                    Events.OnTick.Add(BurdJournals.UI.MainPanel.onPendingJournalRetryStatic)
                end
                return
            else
                BurdJournals.debugPrint("[BurdJournals] completeRecording: Max retries reached, proceeding anyway")
                self.pendingRecordingRetryCount = 0
            end
        end
    end

    local skillsToRecord = {}
    local traitsToRecord = {}
    local statsToRecord = {}
    local recipesToRecord = {}
    local skillCount = 0
    local traitCount = 0
    local statCount = 0
    local recipeCount = 0

    for _, record in ipairs(self.recordingState.pendingRecords) do
        if record.type == "skill" then
            skillsToRecord[record.name] = {
                xp = record.xp,
                level = record.level
            }
            skillCount = skillCount + 1
        elseif record.type == "trait" then
            traitsToRecord[record.name] = {
                name = record.name,
                isPositive = true
            }
            traitCount = traitCount + 1
        elseif record.type == "stat" then
            statsToRecord[record.name] = {
                value = record.value
            }
            statCount = statCount + 1
        elseif record.type == "recipe" then
            recipesToRecord[record.name] = {
                name = record.name
            }
            recipeCount = recipeCount + 1
        end
    end

    self.pendingRecordFeedback = {
        skills = skillCount,
        traits = traitCount,
        stats = statCount,
        recipes = recipeCount
    }

    sendClientCommand(self.player, "BurdJournals", "recordProgress", {
        journalId = self.journal:getID(),
        skills = skillsToRecord,
        traits = traitsToRecord,
        stats = statsToRecord,
        recipes = recipesToRecord
    })

    self:showFeedback(getText("UI_BurdJournals_SavingProgress") or "Saving progress...", {r=0.7, g=0.7, b=0.7})

    local savedQueue = {}
    if not self.recordingState.isRecordAll then
        savedQueue = self.recordingState.queue or {}
    end

    if #savedQueue > 0 then
        local nextRecord = table.remove(savedQueue, 1)

        if nextRecord.type == "skill" then
            self.recordingState = {
                active = true,
                skillName = nextRecord.name,
                traitId = nil,
                statId = nil,
                recipeName = nil,
                isRecordAll = false,
                progress = 0,
                totalTime = self:getSkillRecordingTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRecords = {{type = "skill", name = nextRecord.name, xp = nextRecord.xp, level = nextRecord.level}},
                currentIndex = 1,
                queue = savedQueue,
            }
        elseif nextRecord.type == "trait" then
            self.recordingState = {
                active = true,
                skillName = nil,
                traitId = nextRecord.name,
                statId = nil,
                recipeName = nil,
                isRecordAll = false,
                progress = 0,
                totalTime = self:getTraitRecordingTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRecords = {{type = "trait", name = nextRecord.name}},
                currentIndex = 1,
                queue = savedQueue,
            }
        elseif nextRecord.type == "stat" then
            self.recordingState = {
                active = true,
                skillName = nil,
                traitId = nil,
                statId = nextRecord.name,
                recipeName = nil,
                isRecordAll = false,
                progress = 0,
                totalTime = self:getStatRecordingTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRecords = {{type = "stat", name = nextRecord.name, value = nextRecord.value or nextRecord.xp}},
                currentIndex = 1,
                queue = savedQueue,
            }
        elseif nextRecord.type == "recipe" then
            self.recordingState = {
                active = true,
                skillName = nil,
                traitId = nil,
                statId = nil,
                recipeName = nextRecord.name,
                isRecordAll = false,
                progress = 0,
                totalTime = self:getRecipeRecordingTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRecords = {{type = "recipe", name = nextRecord.name}},
                currentIndex = 1,
                queue = savedQueue,
            }
        end

        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onRecordingTickStatic)
        Events.OnTick.Add(BurdJournals.UI.MainPanel.onRecordingTickStatic)

        self.processingRecordQueue = false
        return
    end

    self.recordingCompleted = true
    self.processingRecordQueue = false

    self:playSound(BurdJournals.Sounds.RECORD)

    self.recordingState = {
        active = false,
        skillName = nil,
        traitId = nil,
        statId = nil,
        recipeName = nil,
        isRecordAll = false,
        progress = 0,
        totalTime = 0,
        startTime = 0,
        pendingRecords = {},
        currentIndex = 0,
        queue = {},
    }

end

function BurdJournals.UI.MainPanel:recordSkill(skillName, xp, level)

    if self.recordingState and self.recordingState.active and not self.recordingState.isRecordAll then
        if self:addToRecordQueue("skill", skillName, xp, level) then
            local displayName = BurdJournals.getPerkDisplayName(skillName) or skillName
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", displayName), {r=0.5, g=0.7, b=0.8})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startRecordingSkill(skillName, xp, level) then
        self:showFeedback(getText("UI_BurdJournals_CannotRecord") or "Cannot record", {r=0.9, g=0.5, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:recordTrait(traitId)

    if self.recordingState and self.recordingState.active and not self.recordingState.isRecordAll then
        if self:addToRecordQueue("trait", traitId) then
            local traitName = safeGetTraitName(traitId)
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", traitName), {r=0.5, g=0.7, b=0.8})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startRecordingTrait(traitId) then
        self:showFeedback(getText("UI_BurdJournals_CannotRecord") or "Cannot record", {r=0.9, g=0.5, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:recordStat(statId, value)

    if self.recordingState and self.recordingState.active and not self.recordingState.isRecordAll then
        if self:addToRecordQueue("stat", statId, value) then
            local stat = BurdJournals.getStatById(statId)
            local statName = stat and BurdJournals.getStatName(stat) or statId
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", statName), {r=0.5, g=0.7, b=0.8})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startRecordingStat(statId, value) then
        self:showFeedback(getText("UI_BurdJournals_CannotRecord") or "Cannot record", {r=0.9, g=0.5, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:recordRecipe(recipeName)

    if self.recordingState and self.recordingState.active and not self.recordingState.isRecordAll then
        if self:addToRecordQueue("recipe", recipeName) then
            local displayName = BurdJournals.getRecipeDisplayName(recipeName) or recipeName
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", displayName), {r=0.5, g=0.7, b=0.8})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startRecordingRecipe(recipeName) then
        self:showFeedback(getText("UI_BurdJournals_CannotRecord") or "Cannot record", {r=0.9, g=0.5, b=0.3})
    end
end

function BurdJournals.UI.MainPanel.onLearningTickStatic()
    local instance = BurdJournals.UI.MainPanel.instance
    if instance and instance.learningState and instance.learningState.active then
        instance:onLearningTick()
    else

        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onLearningTickStatic)
    end
end

function BurdJournals.UI.MainPanel:onLearningTick()
    if not self.learningState.active then
        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onLearningTickStatic)
        return
    end

    local now = getTimestampMs and getTimestampMs() or 0
    if now == 0 or self.learningState.startTime == 0 then
        -- Fallback: complete immediately if no timestamp available
        self:completeLearning()
        return
    end
    local elapsed = (now - self.learningState.startTime) / 1000.0
    self.learningState.progress = math.min(1.0, elapsed / self.learningState.totalTime)

    if self.learningState.progress >= 1.0 then
        self:completeLearning()
    end
end

function BurdJournals.UI.MainPanel:completeLearning()
    Events.OnTick.Remove(BurdJournals.UI.MainPanel.onLearningTickStatic)

    self.processingQueue = true

    if self.confirmDialog then
        if self.confirmDialog.setVisible then
            self.confirmDialog:setVisible(false)
        end
        if self.confirmDialog.removeFromUIManager then
            self.confirmDialog:removeFromUIManager()
        end
        self.confirmDialog = nil
    end

    local isPlayerJournal = self.isPlayerJournal or self.mode == "view"

    local skipRefresh = true

    -- Queue rewards for tick-based pacing instead of sending all at once
    -- This prevents server rate-limiting from dropping commands in MP
    if not self.rewardProcessingQueue then
        self.rewardProcessingQueue = {}
    end

    for _, reward in ipairs(self.learningState.pendingRewards) do
        table.insert(self.rewardProcessingQueue, {
            type = reward.type,
            name = reward.name,
            xp = reward.xp,
            isPlayerJournal = isPlayerJournal
        })
    end

    -- Start tick-based processor if not already running
    if not self.isProcessingRewards and #self.rewardProcessingQueue > 0 then
        self.isProcessingRewards = true
        self:startRewardProcessor()
    elseif #self.rewardProcessingQueue == 0 then
        -- No rewards to process, continue with refresh
        self:refreshPlayer()
    else
        -- Processor already running, it will handle refresh when done
        return
    end

    -- Note: refreshPlayer moved to reward processor completion
    if #self.rewardProcessingQueue > 0 then
        return  -- Let the processor handle the rest
    end

    self:refreshPlayer()
    if isPlayerJournal then
        if self.refreshJournalData then
            self:refreshJournalData()
        end
    else
        if self.refreshAbsorptionList then
            self:refreshAbsorptionList()
        end
    end

    if self.checkDissolution then
        self:checkDissolution(true)
    end

    local savedQueue = {}
    if not self.learningState.isAbsorbAll then
        savedQueue = self.learningState.queue or {}
    end

    if #savedQueue > 0 then
        local nextReward = table.remove(savedQueue, 1)

        if nextReward.type == "skill" then
            self.learningState = {
                active = true,
                skillName = nextReward.name,
                traitId = nil,
                recipeName = nil,
                statId = nil,
                isAbsorbAll = false,
                progress = 0,
                totalTime = self:getSkillLearningTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRewards = {{type = "skill", name = nextReward.name, xp = nextReward.xp}},
                currentIndex = 1,
                queue = savedQueue,
            }
        elseif nextReward.type == "trait" then
            self.learningState = {
                active = true,
                skillName = nil,
                traitId = nextReward.name,
                recipeName = nil,
                statId = nil,
                isAbsorbAll = false,
                progress = 0,
                totalTime = self:getTraitLearningTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRewards = {{type = "trait", name = nextReward.name}},
                currentIndex = 1,
                queue = savedQueue,
            }
        elseif nextReward.type == "recipe" then
            self.learningState = {
                active = true,
                skillName = nil,
                traitId = nil,
                recipeName = nextReward.name,
                statId = nil,
                isAbsorbAll = false,
                progress = 0,
                totalTime = self:getRecipeLearningTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRewards = {{type = "recipe", name = nextReward.name}},
                currentIndex = 1,
                queue = savedQueue,
            }
        elseif nextReward.type == "stat" then
            self.learningState = {
                active = true,
                skillName = nil,
                traitId = nil,
                recipeName = nil,
                statId = nextReward.name,
                isAbsorbAll = false,
                progress = 0,
                totalTime = self:getStatLearningTime(),
                startTime = getTimestampMs and getTimestampMs() or 0,
                pendingRewards = {{type = "stat", name = nextReward.name, value = nextReward.value}},
                currentIndex = 1,
                queue = savedQueue,
            }
        end

        Events.OnTick.Remove(BurdJournals.UI.MainPanel.onLearningTickStatic)
        Events.OnTick.Add(BurdJournals.UI.MainPanel.onLearningTickStatic)

        if self.skillList and self.journal then
            if self.populateAbsorptionList then
                self:populateAbsorptionList()
            end
        end

        self.processingQueue = false
        return
    end

    self.learningCompleted = true
    self.processingQueue = false

    self:playSound(BurdJournals.Sounds.LEARN_COMPLETE)

    self.learningState = {
        active = false,
        skillName = nil,
        traitId = nil,
        recipeName = nil,
        statId = nil,
        isAbsorbAll = false,
        progress = 0,
        totalTime = 0,
        startTime = 0,
        pendingRewards = {},
        currentIndex = 0,
        queue = {},
    }

    if self.skillList and self.journal then
        self:refreshPlayer()
        if self.mode == "view" or self.isPlayerJournal then
            if self.populateViewList then
                self:populateViewList()
            end
        else
            if self.populateAbsorptionList then
                self:populateAbsorptionList()
            end
        end
    end
end

-- Time-gated reward processor to avoid server rate-limiting in MP
-- Server rate-limits at 100ms, so we send one command every 120ms to be safe
-- Uses index-based iteration instead of table.remove(1) to avoid O(n^2) behavior
function BurdJournals.UI.MainPanel:startRewardProcessor()
    local panel = self
    local skipRefresh = true
    local lastSendTime = 0
    local ticksSinceLastSend = 0 -- Fallback for builds without getTimestampMs
    local SEND_INTERVAL_MS = 120 -- Server rate-limits at 100ms, use 120ms to be safe
    local SEND_INTERVAL_TICKS = 4 -- ~120ms at 30 FPS as fallback
    local idx = 1 -- Use index instead of table.remove for O(1) access

    local processNextReward
    processNextReward = function()
        -- Check if panel still exists and has queue
        if not panel or not panel.rewardProcessingQueue or idx > #panel.rewardProcessingQueue then
            if panel then
                panel.isProcessingRewards = false
                panel.rewardProcessingQueue = nil -- Clear queue when done
                -- All rewards processed, now refresh
                panel:refreshPlayer()
                if panel.isPlayerJournal or panel.mode == "view" then
                    if panel.refreshJournalData then
                        panel:refreshJournalData()
                    end
                else
                    if panel.refreshAbsorptionList then
                        panel:refreshAbsorptionList()
                    end
                end
                if panel.checkDissolution then
                    panel:checkDissolution(true)
                end
            end
            Events.OnTick.Remove(processNextReward)
            return
        end

        -- Check if enough time has passed since last send (120ms minimum)
        local now = getTimestampMs and getTimestampMs() or 0
        if now > 0 and lastSendTime > 0 then
            -- Use millisecond timing when available
            if (now - lastSendTime) < SEND_INTERVAL_MS then
                return -- Wait for next tick, not enough time elapsed
            end
        else
            -- Fallback: use tick counting when getTimestampMs unavailable
            ticksSinceLastSend = ticksSinceLastSend + 1
            if ticksSinceLastSend < SEND_INTERVAL_TICKS then
                return -- Wait for more ticks
            end
            ticksSinceLastSend = 0
        end

        -- Process one reward with time-gating (O(1) index access)
        local reward = panel.rewardProcessingQueue[idx]
        BurdJournals.debugPrint("[BurdJournals BATCH] Processing reward " .. idx .. "/" .. #panel.rewardProcessingQueue .. ": " .. tostring(reward.type) .. " - " .. tostring(reward.name))
        idx = idx + 1
        lastSendTime = now

        if reward.type == "skill" then
            if reward.isPlayerJournal then
                BurdJournals.debugPrint("[BurdJournals BATCH] Calling sendClaimSkill for " .. tostring(reward.name) .. " with XP " .. tostring(reward.xp))
                panel:sendClaimSkill(reward.name, reward.xp, skipRefresh)
            else
                panel:sendAbsorbSkill(reward.name, reward.xp, skipRefresh)
            end
        elseif reward.type == "trait" then
            if reward.isPlayerJournal then
                panel:sendClaimTrait(reward.name, skipRefresh)
            else
                panel:sendAbsorbTrait(reward.name, skipRefresh)
            end
        elseif reward.type == "recipe" then
            if reward.isPlayerJournal then
                panel:sendClaimRecipe(reward.name, skipRefresh)
            else
                panel:sendAbsorbRecipe(reward.name, skipRefresh)
            end
        elseif reward.type == "stat" then
            -- Stats use sendClaimStat for both player and non-player journals
            panel:sendClaimStat(reward.name, reward.value)
        end
    end

    Events.OnTick.Add(processNextReward)
end

function BurdJournals.UI.MainPanel:sendAbsorbSkill(skillName, xp, skipDissolutionCheck)
    local journalId = self.journal:getID()
    local journalData = BurdJournals.getJournalData(self.journal)

    -- Calculate skill book multiplier on the client (where the state is known)
    local skillBookMultiplier, hasBoost = BurdJournals.getSkillBookMultiplier(self.player, skillName)
    BurdJournals.debugPrint("[BurdJournals] Client sendAbsorbSkill: skill=" .. tostring(skillName) .. ", skillBookMultiplier=" .. tostring(skillBookMultiplier) .. ", hasBoost=" .. tostring(hasBoost))

    -- For debug-spawned journals in MP, use the debug command to add XP
    if journalData and journalData.isDebugSpawned and isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals] Debug journal (absorb) - using debug XP add for " .. skillName)
        sendClientCommand(self.player, "BurdJournals", "debugAddXP", {
            skillName = skillName,
            xp = xp or 0
        })
        -- Mark as claimed locally
        BurdJournals.markSkillClaimedByCharacter(journalData, self.player, skillName)
        if self.journal.transmitModData then
            self.journal:transmitModData()
        end
        return
    end

    if isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals] Client: Sending to server with multiplier=" .. tostring(skillBookMultiplier))
        sendClientCommand(self.player, "BurdJournals", "absorbSkill", {
            journalId = journalId,
            skillName = skillName,
            skillBookMultiplier = skillBookMultiplier  -- Send the multiplier to the server
        })
    else
        BurdJournals.debugPrint("[BurdJournals] Client: SP/host path - applySkillXPDirectly")
        self:applySkillXPDirectly(skillName, xp, skipDissolutionCheck)
    end
end

function BurdJournals.UI.MainPanel:sendAbsorbTrait(traitId, skipDissolutionCheck)
    local journalId = self.journal:getID()
    local journalData = BurdJournals.getJournalData(self.journal)

    -- For debug-spawned journals in MP, use the debug command to add trait
    if journalData and journalData.isDebugSpawned and isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals] Debug journal (absorb) - using debug trait add for " .. tostring(traitId))
        sendClientCommand(self.player, "BurdJournals", "debugAddTrait", {
            traitId = traitId
        })
        -- Mark as claimed locally
        BurdJournals.markTraitClaimedByCharacter(journalData, self.player, traitId)
        if self.journal.transmitModData then
            self.journal:transmitModData()
        end
        return
    end

    if isClient() and not isServer() then
        sendClientCommand(self.player, "BurdJournals", "absorbTrait", {
            journalId = journalId,
            traitId = traitId
        })
    else
        self:applyTraitDirectly(traitId, skipDissolutionCheck)
    end
end

function BurdJournals.UI.MainPanel:sendClaimSkill(skillName, recordedXP, skipDissolutionCheck)
    local journalId = self.journal:getID()
    local journalData = BurdJournals.getJournalData(self.journal)
    if not isSkillVisibleForJournal(journalData, skillName) then
        self:showFeedback(getText("UI_BurdJournals_CantClaimSkill") or "That skill cannot be claimed right now", {r=0.9, g=0.5, b=0.3})
        return
    end
    local claimSessionId = nil
    if BurdJournals.getXPRecoveryMode and BurdJournals.getXPRecoveryMode() == 2
        and BurdJournals.getDiminishingTrackingMode and BurdJournals.getDiminishingTrackingMode() == 2 then
        claimSessionId = getClaimSessionIdForPanel(self, true)
    end

    if not self.pendingClaims then self.pendingClaims = {skills = {}, traits = {}} end
    self.pendingClaims.skills[skillName] = true

    -- Get current player state for debug logging
    local perk = BurdJournals.getPerkByName(skillName)
    local playerLevelBefore = 0
    local playerXPBefore = 0
    if perk then
        playerLevelBefore = self.player:getPerkLevel(perk)
        playerXPBefore = self.player:getXp():getXP(perk)
    end
    
    -- Get recorded level from journal
    local recordedLevel = 0
    if journalData and isSkillVisibleForJournal(journalData, skillName) and journalData.skills and journalData.skills[skillName] then
        recordedLevel = journalData.skills[skillName].level or 0
        -- Fallback: calculate level from XP if not stored
        if recordedLevel == 0 and recordedXP and recordedXP > 0 and BurdJournals.getSkillLevelFromXP then
            local xpForLevelCalc = getXPWithBaselineForDisplay(skillName, recordedXP, journalData, self.player)
            recordedLevel = BurdJournals.getSkillLevelFromXP(xpForLevelCalc, skillName)
        end
    end
    
    -- Debug logging: what we expect vs current state
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG] Skill: " .. tostring(skillName))
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   JOURNAL EXPECTS: Level " .. tostring(recordedLevel) .. ", XP " .. tostring(recordedXP))
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   PLAYER BEFORE:   Level " .. tostring(playerLevelBefore) .. ", XP " .. tostring(playerXPBefore))
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   isDebugSpawned: " .. tostring(journalData and journalData.isDebugSpawned))
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   isPlayerJournal: " .. tostring(journalData and journalData.isPlayerCreated))
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   skipDissolutionCheck: " .. tostring(skipDissolutionCheck))
    BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   claimSessionId: " .. tostring(claimSessionId))
    BurdJournals.debugPrint("================================================================================")

    -- For debug-spawned journals in MP, use the debug command to SET to target XP
    -- (normal claim flow fails because server can't find client-spawned items)
    -- IMPORTANT: Send the actual recorded XP, not just the level, for exact XP restoration
    if journalData and journalData.isDebugSpawned and isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG] Using debugSetSkillXP path (debug-spawned journal)")
        local claimMultiplier = 1.0
        if BurdJournals.consumeJournalClaimRead
            and BurdJournals.getXPRecoveryMode and BurdJournals.getXPRecoveryMode() == 2 then
            claimMultiplier = BurdJournals.consumeJournalClaimRead(journalData, skillName, claimSessionId)
        end
        local effectiveRecordedXP = math.max(0, math.floor((tonumber(recordedXP) or 0) * claimMultiplier))
        local claimTargetXP, baselineXP = getClaimTargetXPForPlayer(journalData, self.player, skillName, effectiveRecordedXP)
        local effectiveRecordedLevel = recordedLevel
        if BurdJournals.getSkillLevelFromXP then
            effectiveRecordedLevel = BurdJournals.getSkillLevelFromXP(claimTargetXP, skillName) or recordedLevel
        end
        local journalSnapshot = journalData
        if BurdJournals.normalizeJournalData then
            journalSnapshot = BurdJournals.normalizeJournalData(journalData) or journalData
        end
        BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG]   Sending effectiveXP=" .. tostring(effectiveRecordedXP) .. ", targetXP=" .. tostring(claimTargetXP) .. ", baselineXP=" .. tostring(baselineXP) .. ", effectiveLevel=" .. tostring(effectiveRecordedLevel) .. ", claimMultiplier=" .. tostring(claimMultiplier))
        sendClientCommand(self.player, "BurdJournals", "debugSetSkillXP", {
            skillName = skillName,
            targetXP = claimTargetXP,
            targetLevel = effectiveRecordedLevel,
            journalId = journalId,
            journalUUID = journalData and journalData.uuid,
            claimSessionId = claimSessionId,
            journalData = journalSnapshot
        })
        -- Mark as claimed locally since server can't access debug-spawned journal
        -- This ensures the UI updates correctly and the skill isn't double-claimed
        BurdJournals.markSkillClaimedByCharacter(journalData, self.player, skillName)
        if self.journal.transmitModData then
            self.journal:transmitModData()
        end
        -- Keep dedicated-server persistence in sync with debug claims.
        -- This mirrors the debug edit flow that already survives reconnects/patch updates.
        if BurdJournals.UI
            and BurdJournals.UI.DebugPanel
            and BurdJournals.UI.DebugPanel.backupJournalToGlobalCache then
            BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(self.journal)
        end
        -- Don't refresh here - let the server response or batch completion handle it
        return
    end

    if isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG] Using claimSkill server command path")
        sendClientCommand(self.player, "BurdJournals", "claimSkill", {
            journalId = journalId,
            skillName = skillName,
            claimSessionId = claimSessionId
        })
    else
        BurdJournals.debugPrint("[BurdJournals CLAIM DEBUG] Using local applySkillXPSetMode path (SP/host)")
        self:applySkillXPSetMode(skillName, recordedXP, skipDissolutionCheck, claimSessionId)
    end
end

function BurdJournals.UI.MainPanel:sendClaimTrait(traitId, skipDissolutionCheck)
    local journalId = self.journal:getID()
    local journalData = BurdJournals.getJournalData(self.journal)

    -- Debug logging
    BurdJournals.debugPrint("[BurdJournals] sendClaimTrait called for trait: " .. tostring(traitId))
    BurdJournals.debugPrint("[BurdJournals] journalData exists: " .. tostring(journalData ~= nil))
    if journalData then
        BurdJournals.debugPrint("[BurdJournals] journalData.isDebugSpawned: " .. tostring(journalData.isDebugSpawned))
    end
    BurdJournals.debugPrint("[BurdJournals] isClient(): " .. tostring(isClient()) .. ", isServer(): " .. tostring(isServer()))
    BurdJournals.debugPrint("[BurdJournals] skipDissolutionCheck: " .. tostring(skipDissolutionCheck))

    if not self.pendingClaims then self.pendingClaims = {skills = {}, traits = {}} end
    local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(traitId) or traitId
    local traitSessionKey = string.lower(tostring(normalizedTraitId or traitId))
    self.pendingClaims.traits[traitId] = true
    self.pendingClaims.traits[traitSessionKey] = true

    -- For debug-spawned journals in MP, use the debug command to add trait
    -- (normal claim flow fails because server can't find client-spawned items)
    if journalData and journalData.isDebugSpawned and isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals] Debug journal detected - using debug trait add")
        sendClientCommand(self.player, "BurdJournals", "debugAddTrait", {
            traitId = traitId
        })
        -- Mark as claimed locally since server can't access debug-spawned journal
        BurdJournals.markTraitClaimedByCharacter(journalData, self.player, traitId)
        if self.journal.transmitModData then
            self.journal:transmitModData()
        end
        -- Don't refresh here - let the server response or batch completion handle it
        return
    end

    BurdJournals.debugPrint("[BurdJournals] Using normal claimTrait flow")
    if isClient() and not isServer() then
        sendClientCommand(self.player, "BurdJournals", "claimTrait", {
            journalId = journalId,
            traitId = traitId
        })
    else
        self:applyTraitDirectly(traitId, skipDissolutionCheck)
    end
end

function BurdJournals.UI.MainPanel:sendAbsorbRecipe(recipeName, skipRefresh)
    local journalId = self.journal:getID()

    if isClient() and not isServer() then
        sendClientCommand(self.player, "BurdJournals", "absorbRecipe", {
            journalId = journalId,
            recipeName = recipeName
        })
    else
        self:applyRecipeDirectly(recipeName)

        -- Use per-character claims for SP/host path to match server behavior
        local journalData = self.journal:getModData().BurdJournals
        if journalData then
            BurdJournals.markRecipeClaimedByCharacter(journalData, self.player, recipeName)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end

        if not skipRefresh then
            self:refreshAbsorptionList()
            self:checkDissolution(true)
        end
    end
end

function BurdJournals.UI.MainPanel:sendClaimRecipe(recipeName, skipDissolutionCheck)
    local journalId = self.journal:getID()

    if not self.pendingClaims then self.pendingClaims = {skills = {}, traits = {}, recipes = {}} end
    if not self.pendingClaims.recipes then self.pendingClaims.recipes = {} end
    self.pendingClaims.recipes[recipeName] = true

    if isClient() and not isServer() then
        sendClientCommand(self.player, "BurdJournals", "claimRecipe", {
            journalId = journalId,
            recipeName = recipeName
        })
    else
        self:applyRecipeDirectly(recipeName)

        -- Use per-character claims for SP/host path to match server behavior
        local journalData = self.journal:getModData().BurdJournals
        if journalData then
            BurdJournals.markRecipeClaimedByCharacter(journalData, self.player, recipeName)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end

        -- Skip refresh/dissolution during batch operations
        if not skipDissolutionCheck then
            self:refreshAbsorptionList()
            self:checkDissolution(true)
        end
    end
end

function BurdJournals.UI.MainPanel:applyRecipeDirectly(recipeName)
    if not self.player or not recipeName then return false end

    local displayName = BurdJournals.getRecipeDisplayName(recipeName) or recipeName

    if BurdJournals.playerKnowsRecipe(self.player, recipeName) then
        self:showFeedback(string.format(getText("UI_BurdJournals_AlreadyKnowRecipe") or "Already know: %s", displayName), {r=0.7, g=0.7, b=0.5})
        return false
    end

    local learned = BurdJournals.learnRecipeWithVerification(self.player, recipeName, "[BurdJournals Client]")

    if learned then
        self:showFeedback(string.format(getText("UI_BurdJournals_LearnedRecipe") or "Learned: %s", displayName), {r=0.5, g=0.9, b=0.95})
        BurdJournals.Client.showHaloMessage(self.player, "+" .. displayName, BurdJournals.Client.HaloColors.RECIPE_GAIN)
        return true
    else
        self:showFeedback(string.format(getText("UI_BurdJournals_RecipeNotAvailable") or "Recipe not available: %s", displayName), {r=0.9, g=0.7, b=0.5})
        return false
    end
end

function BurdJournals.UI.MainPanel:applySkillXPSetMode(skillName, recordedXP, skipDissolutionCheck, claimSessionId)
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG] applySkillXPSetMode called")
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   skillName: " .. tostring(skillName))
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   recordedXP: " .. tostring(recordedXP) .. " (type: " .. type(recordedXP) .. ")")
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   skipDissolutionCheck: " .. tostring(skipDissolutionCheck))

    self:refreshPlayer()

    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        print("[BurdJournals BATCH DEBUG]   ERROR: perk is nil for " .. tostring(skillName))
        return
    end
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   perk found: " .. tostring(perk))

    -- Use per-character claims for SP/host path to match server behavior
    local journalData = self.journal:getModData().BurdJournals
    local claimMultiplier = 1.0
    if journalData and BurdJournals.consumeJournalClaimRead then
        claimMultiplier = BurdJournals.consumeJournalClaimRead(journalData, skillName, claimSessionId)
    end
    local effectiveRecordedXP = math.max(0, math.floor((tonumber(recordedXP) or 0) * claimMultiplier))
    local claimTargetXP, baselineXP = getClaimTargetXPForPlayer(journalData, self.player, skillName, effectiveRecordedXP)

    local playerXP = self.player:getXp():getXP(perk)
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   playerXP (current): " .. tostring(playerXP))
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   claimMultiplier: " .. tostring(claimMultiplier))
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   effectiveRecordedXP: " .. tostring(effectiveRecordedXP))
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   baselineXP: " .. tostring(baselineXP))
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   claimTargetXP: " .. tostring(claimTargetXP))
    BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   Comparison: claimTargetXP (" .. tostring(claimTargetXP) .. ") > playerXP (" .. tostring(playerXP) .. ") = " .. tostring(claimTargetXP > playerXP))
    
    if claimTargetXP > playerXP then

        local xpDiff = claimTargetXP - playerXP
        BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   XP to add: " .. tostring(xpDiff))

        local xpObj = self.player:getXp()
        local beforeXP = xpObj:getXP(perk)
        
        if sendAddXp then
            BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   Using sendAddXp")
            sendAddXp(self.player, perk, xpDiff, true)
        else
            BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   Using direct AddXP")
            -- Use proper AddXP signature with checkLevelUp=true
            xpObj:AddXP(perk, xpDiff, false, false, false, true)
        end

        local afterXP = xpObj:getXP(perk)
        BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   XP before: " .. tostring(beforeXP) .. ", after: " .. tostring(afterXP) .. ", gained: " .. tostring(afterXP - beforeXP))

        if journalData then
            BurdJournals.markSkillClaimedByCharacter(journalData, self.player, skillName)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end

        local displayName = BurdJournals.getPerkDisplayName(skillName)
        self:showFeedback(string.format(getText("UI_BurdJournals_SetSkillToLevel") or "Set %s to recorded level", displayName), {r=0.5, g=0.8, b=0.9})
    else
        BurdJournals.debugPrint("[BurdJournals BATCH DEBUG]   SKIPPING XP add - already at or above level (or recordedXP is nil/0)")
        -- Still mark as claimed even if already at level (allows dissolution)
        if journalData then
            BurdJournals.markSkillClaimedByCharacter(journalData, self.player, skillName)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end
        self:showFeedback(getText("UI_BurdJournals_AlreadyAtLevel") or "Already at or above this level", {r=0.7, g=0.7, b=0.5})
    end
    if journalData and BurdJournals.captureJournalDRState then
        BurdJournals.captureJournalDRState(self.journal, "applySkillXPSetMode", self.player)
    end
    BurdJournals.debugPrint("================================================================================")

    -- Skip refresh/dissolution during batch operations - will be done at end of batch
    if not skipDissolutionCheck then
        self:refreshJournalData()
        self:checkDissolution(true)
    end
end

function BurdJournals.UI.MainPanel:absorbSkill(skillName, xp)

    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("skill", skillName, xp) then
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", BurdJournals.getPerkDisplayName(skillName) or skillName), {r=0.7, g=0.8, b=0.9})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startLearningSkill(skillName, xp) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:absorbTrait(traitId)

    if BurdJournals.playerHasTrait(self.player, traitId) then
        self:showFeedback(getText("UI_BurdJournals_TraitAlreadyKnownFeedback") or "Trait already known!", {r=0.7, g=0.5, b=0.3})
        return
    end

    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("trait", traitId) then
            local traitName = safeGetTraitName(traitId)
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", traitName), {r=0.9, g=0.8, b=0.6})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startLearningTrait(traitId) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:absorbRecipe(recipeName)

    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("recipe", recipeName) then
            local displayName = BurdJournals.getRecipeDisplayName(recipeName)
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", displayName), {r=0.5, g=0.85, b=0.9})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startLearningRecipe(recipeName) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:eraseSkillEntry(skillName)
    if not self.journal or not skillName then return end

    if not BurdJournals.hasEraser(self.player) then
        self:showFeedback(getText("UI_BurdJournals_NeedEraser") or "Need eraser", {r=0.9, g=0.5, b=0.5})
        return
    end

    -- Initialize erasingState if needed
    if not self.erasingState then
        self.erasingState = { active = false, queue = {} }
    end

    -- If already erasing something, add to queue
    if self.erasingState.active then
        self:addToEraseQueue("skill", skillName)
    else
        -- Start erasing directly
        BurdJournals.queueEraseAction(self.player, self.journal, "skill", skillName, self)
    end
end

function BurdJournals.UI.MainPanel:eraseTraitEntry(traitId)
    if not self.journal or not traitId then return end

    if not BurdJournals.hasEraser(self.player) then
        self:showFeedback(getText("UI_BurdJournals_NeedEraser") or "Need eraser", {r=0.9, g=0.5, b=0.5})
        return
    end

    -- Initialize erasingState if needed
    if not self.erasingState then
        self.erasingState = { active = false, queue = {} }
    end

    -- If already erasing something, add to queue
    if self.erasingState.active then
        self:addToEraseQueue("trait", traitId)
    else
        -- Start erasing directly
        BurdJournals.queueEraseAction(self.player, self.journal, "trait", traitId, self)
    end
end

function BurdJournals.UI.MainPanel:eraseRecipeEntry(recipeName)
    if not self.journal or not recipeName then return end

    if not BurdJournals.hasEraser(self.player) then
        self:showFeedback(getText("UI_BurdJournals_NeedEraser") or "Need eraser", {r=0.9, g=0.5, b=0.5})
        return
    end

    -- Initialize erasingState if needed
    if not self.erasingState then
        self.erasingState = { active = false, queue = {} }
    end

    -- If already erasing something, add to queue
    if self.erasingState.active then
        self:addToEraseQueue("recipe", recipeName)
    else
        -- Start erasing directly
        BurdJournals.queueEraseAction(self.player, self.journal, "recipe", recipeName, self)
    end
end

function BurdJournals.UI.MainPanel:eraseStatEntry(statId)
    if not self.journal or not statId then return end

    if not BurdJournals.hasEraser(self.player) then
        self:showFeedback(getText("UI_BurdJournals_NeedEraser") or "Need eraser", {r=0.9, g=0.5, b=0.5})
        return
    end

    -- Initialize erasingState if needed
    if not self.erasingState then
        self.erasingState = { active = false, queue = {} }
    end

    -- If already erasing something, add to queue
    if self.erasingState.active then
        self:addToEraseQueue("stat", statId)
    else
        -- Start erasing directly
        BurdJournals.queueEraseAction(self.player, self.journal, "stat", statId, self)
    end
end

function BurdJournals.UI.MainPanel:eraseEntryDirectly(entryType, entryName)
    if not self.journal or not entryType or not entryName then return end

    local modData = self.journal:getModData()
    local journalData = modData.BurdJournals
    if not journalData then return end

    -- Get display name safely (wrap lookups in pcall to handle missing factories)
    local displayName = entryName
    if entryType == "skill" then
        if Perks and Perks.FromString and PerkFactory and PerkFactory.getPerkName then
            local perk = Perks.FromString(entryName)
            if perk then
                displayName = PerkFactory.getPerkName(perk) or entryName
            end
        end
    elseif entryType == "trait" then
        if TraitFactory and TraitFactory.getTrait then
            local trait = TraitFactory.getTrait(entryName)
            if trait and trait.getLabel then
                local label = trait:getLabel()
                displayName = (label and getText(label)) or entryName
            end
        end
    elseif entryType == "recipe" then
        if getScriptManager then
            local scriptMgr = getScriptManager()
            if scriptMgr and scriptMgr.getRecipe then
                local recipe = scriptMgr:getRecipe(entryName)
                if recipe and recipe.getName then
                    displayName = recipe:getName() or entryName
                end
            end
        end
    elseif entryType == "stat" then
        displayName = getText("UI_BurdJournals_Stat_" .. entryName) or entryName
    end

    local erased = false

    if entryType == "skill" then
        if journalData.skills and journalData.skills[entryName] then
            journalData.skills[entryName] = nil
            erased = true
        end
        if journalData.claimedSkills then
            journalData.claimedSkills[entryName] = nil
        end
    elseif entryType == "trait" then
        if journalData.traits and journalData.traits[entryName] then
            journalData.traits[entryName] = nil
            erased = true
        end
        if journalData.claimedTraits then
            journalData.claimedTraits[entryName] = nil
        end
    elseif entryType == "recipe" then
        if journalData.recipes and journalData.recipes[entryName] then
            journalData.recipes[entryName] = nil
            erased = true
        end
        if journalData.claimedRecipes then
            journalData.claimedRecipes[entryName] = nil
        end
    elseif entryType == "stat" then
        if journalData.stats and journalData.stats[entryName] then
            journalData.stats[entryName] = nil
            erased = true
        end
        if journalData.claimedStats then
            journalData.claimedStats[entryName] = nil
        end
    end

    if erased then

        if self.journal.transmitModData then
            self.journal:transmitModData()
        end

        self:showFeedback(string.format(getText("UI_BurdJournals_EntryErased") or "Erased: %s", displayName), {r=0.9, g=0.6, b=0.6})

        if self.mode == "view" then
            self:refreshCurrentList()
        else
            self:refreshAbsorptionList()
        end

        self:playSound(BurdJournals.Sounds.PAGE_TURN)

        -- Notify Debug Panel to refresh if it's open and editing this journal
        -- Use deferred update to avoid refresh during render cycle which can cause draw crashes
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            local debugPanel = BurdJournals.UI.DebugPanel.instance
            if debugPanel.editingJournal and debugPanel.editingJournal == self.journal then
                -- Mark for deferred refresh instead of immediate refresh
                debugPanel.needsJournalRefresh = true
            end
        end
    end
end

function BurdJournals.UI.MainPanel:addToQueue(rewardType, name, xpOrValue)

    if rewardType == "trait" and BurdJournals.playerHasTrait(self.player, name) then
        return false
    end

    -- Check if already being learned
    if self.learningState.skillName == name or self.learningState.traitId == name or
       self.learningState.recipeName == name or self.learningState.statId == name then
        return false
    end

    for _, queued in ipairs(self.learningState.queue) do
        if queued.name == name then
            return false
        end
    end

    local queueItem = {
        type = rewardType,
        name = name,
    }

    -- Stats use 'value' instead of 'xp'
    if rewardType == "stat" then
        queueItem.value = xpOrValue
    else
        queueItem.xp = xpOrValue
    end

    table.insert(self.learningState.queue, queueItem)

    self:playSound(BurdJournals.Sounds.QUEUE_ADD)

    return true
end

function BurdJournals.UI.MainPanel:getQueuePosition(name)
    for i, queued in ipairs(self.learningState.queue) do
        if queued.name == name then
            return i
        end
    end
    return nil
end

function BurdJournals.UI.MainPanel:removeFromQueue(name)
    for i, queued in ipairs(self.learningState.queue) do
        if queued.name == name then
            table.remove(self.learningState.queue, i)
            return true
        end
    end
    return false
end

function BurdJournals.UI.MainPanel:addToRecordQueue(recordType, name, xp, level)
    if not self.recordingState then return false end
    if not self.recordingState.queue then
        self.recordingState.queue = {}
    end

    if self.recordingState.skillName == name or self.recordingState.traitId == name or self.recordingState.statId == name or self.recordingState.recipeName == name then
        return false
    end

    for _, queued in ipairs(self.recordingState.queue) do
        if queued.name == name then
            return false
        end
    end

    table.insert(self.recordingState.queue, {
        type = recordType,
        name = name,
        xp = xp,
        level = level,
        value = xp
    })

    self:playSound(BurdJournals.Sounds.QUEUE_ADD)

    return true
end

function BurdJournals.UI.MainPanel:getRecordQueuePosition(name)
    if not self.recordingState or not self.recordingState.queue then return nil end
    for i, queued in ipairs(self.recordingState.queue) do
        if queued.name == name then
            return i
        end
    end
    return nil
end

-- Erase queue management functions
function BurdJournals.UI.MainPanel:addToEraseQueue(entryType, entryName)
    if not self.erasingState then
        self.erasingState = { active = false, queue = {} }
    end
    if not self.erasingState.queue then
        self.erasingState.queue = {}
    end

    -- Check if already being erased
    if self.erasingState.active and self.erasingState.entryName == entryName then
        return false
    end

    -- Check if already in queue
    for _, queued in ipairs(self.erasingState.queue) do
        if queued.name == entryName then
            return false
        end
    end

    table.insert(self.erasingState.queue, {
        type = entryType,
        name = entryName
    })

    self:playSound(BurdJournals.Sounds.QUEUE_ADD)
    return true
end

function BurdJournals.UI.MainPanel:getEraseQueuePosition(name)
    if not self.erasingState or not self.erasingState.queue then return nil end
    for i, queued in ipairs(self.erasingState.queue) do
        if queued.name == name then
            return i
        end
    end
    return nil
end

function BurdJournals.UI.MainPanel:removeFromEraseQueue(name)
    if not self.erasingState or not self.erasingState.queue then return false end
    for i, queued in ipairs(self.erasingState.queue) do
        if queued.name == name then
            table.remove(self.erasingState.queue, i)
            return true
        end
    end
    return false
end

function BurdJournals.UI.MainPanel:processNextEraseInQueue()
    if not self.erasingState or not self.erasingState.queue then return end
    if self.erasingState.active then return end -- Still erasing something

    if #self.erasingState.queue > 0 then
        local nextItem = table.remove(self.erasingState.queue, 1)
        if nextItem then
            BurdJournals.queueEraseAction(self.player, self.journal, nextItem.type, nextItem.name, self)
        end
    end
end

function BurdJournals.UI.MainPanel:applySkillXPDirectly(skillName, xp, skipDissolutionCheck)

    self:refreshPlayer()

    local perk = BurdJournals.getPerkByName(skillName)
    if perk and xp and xp > 0 then
        local journalMultiplier = BurdJournals.getSandboxOption("JournalXPMultiplier") or 1.0
        local skillBookMultiplier = BurdJournals.getSkillBookMultiplier(self.player, skillName)
        local xpToApply = xp * journalMultiplier * skillBookMultiplier

        local isPassiveSkill = (skillName == "Fitness" or skillName == "Strength")
        if isPassiveSkill then
            xpToApply = xpToApply * 5
        end

        -- AddXP adds the specified amount directly for all skills
        local xpObj = self.player:getXp()
        local beforeXP = xpObj:getXP(perk)

        -- Use AddXP with useMultipliers=false since we already applied journal/skillbook multipliers
        -- Signature: AddXP(perk, amount, addToKnownRecipes, useMultipliers, isPassive, checkLevelUp)
        -- Setting useMultipliers=false bypasses PZ's sandbox XP multipliers to give exact amount
        if sendAddXp then
            -- MP client path - use sendAddXp but we'll handle server-side properly
            sendAddXp(self.player, perk, xpToApply, false)
        else
            -- SP/host path - directly add XP with no game multipliers
            xpObj:AddXP(perk, xpToApply, true, false, false, false)
        end

        local afterXP = xpObj:getXP(perk)
        local actualGain = afterXP - beforeXP

        -- Use per-character claims for SP/host path to match server behavior
        local journalData = self.journal:getModData().BurdJournals
        if journalData then
            BurdJournals.markSkillClaimedByCharacter(journalData, self.player, skillName)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end

        if actualGain > 0 then
            self:showFeedback(string.format(getText("UI_BurdJournals_GainedXP") or "+%s %s", BurdJournals.formatXP(actualGain), BurdJournals.getPerkDisplayName(skillName)), {r=0.5, g=0.8, b=0.5})
        else
            self:showFeedback(getText("UI_BurdJournals_SkillMaxed") or "Skill already maxed!", {r=0.7, g=0.5, b=0.3})
        end

        -- Skip refresh/dissolution during batch operations
        if not skipDissolutionCheck then
            self:refreshAbsorptionList()
            self:checkDissolution(true)
        end
    end
end

function BurdJournals.UI.MainPanel:applyTraitDirectly(traitId, skipDissolutionCheck)

    local player = self.player

    if not player then
        self:showFeedback(getText("UI_BurdJournals_NoPlayer") or "No player!", {r=0.8, g=0.3, b=0.3})
        return
    end

    -- Use per-character claims for SP/host path to match server behavior
    local journalData = self.journal:getModData().BurdJournals

    if BurdJournals.playerHasTrait(player, traitId) then
        -- Still mark as claimed even if already known (allows dissolution)
        if journalData then
            BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end
        self:showFeedback(getText("UI_BurdJournals_TraitAlreadyKnownFeedback") or "Trait already known!", {r=0.7, g=0.5, b=0.3})
        -- Skip refresh/dissolution during batch operations
        if not skipDissolutionCheck then
            self:refreshAbsorptionList()
            self:checkDissolution(true)
        end
        return
    end

    if BurdJournals.safeAddTrait(player, traitId) then
        local allowCancellation = BurdJournals.getSandboxOption("AllowMutualExclusionCancellation")
        if allowCancellation == nil then allowCancellation = true end
        if allowCancellation and BurdJournals.getConflictingTraits and BurdJournals.safeRemoveTrait then
            local conflicts = BurdJournals.getConflictingTraits(player, traitId)
            for _, conflictId in ipairs(conflicts) do
                BurdJournals.safeRemoveTrait(player, conflictId)
            end
        end

        if journalData then
            BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)
            if self.journal.transmitModData then
                self.journal:transmitModData()
            end
        end
        local traitName = safeGetTraitName(traitId)
        self:showFeedback(string.format(getText("UI_BurdJournals_GainedTrait") or "Gained trait: %s", traitName), {r=0.9, g=0.75, b=0.5})
    else
        self:showFeedback(getText("UI_BurdJournals_FailedToAddTrait") or "Failed to add trait!", {r=0.8, g=0.3, b=0.3})
    end

    -- Skip refresh/dissolution during batch operations
    if not skipDissolutionCheck then
        self:refreshAbsorptionList()
        self:checkDissolution(true)
    end
end

function BurdJournals.UI.MainPanel:showFeedback(text, color)
    if self.feedbackLabel then
        self.feedbackLabel:setName(text)
        self.feedbackLabel:setColor(color.r, color.g, color.b)
        self.feedbackLabel:setVisible(true)
        self.feedbackTicks = 120
    end
end

function BurdJournals.UI.MainPanel:playSound(soundData)
    if not soundData then return end

    local uiSound, worldSound
    if type(soundData) == "string" then
        worldSound = soundData
    elseif type(soundData) == "table" then
        uiSound = soundData.ui
        worldSound = soundData.world
    else
        return
    end

    if uiSound and getSoundManager then
        local soundMgr = getSoundManager()
        if soundMgr and soundMgr.playUISound then
            soundMgr:playUISound(uiSound)
        end
    end

    if worldSound and self.player and self.player.playSound then
        self.player:playSound(worldSound)
    end
end

function BurdJournals.UI.MainPanel:checkDissolution(forceAutoDissolve)
    if forceAutoDissolve ~= true then
        return
    end

    -- Guard against invalid/zombie journal objects
    if not self.journal or not BurdJournals.isValidItem(self.journal) then return end
    if not self.journal.getModData then return end
    self.journal:getModData()

    -- Pass player for per-character dissolution check
    if BurdJournals.shouldDissolve(self.journal, self.player) then
        local dissolveMsg = BurdJournals.getRandomDissolutionMessage()

        -- In MP, route dissolution through server to avoid desync
        -- Server response will trigger the Say message via handleJournalDissolved
        if isClient() and not isServer() and BurdJournals.Client and BurdJournals.Client.sendToServer then
            BurdJournals.Client.sendToServer("dissolveJournal", {
                journalId = self.journal:getID()
            })
        else
            -- SP/host: Remove directly and show message
            local container = self.journal:getContainer()
            if container then container:Remove(self.journal) end
            self.player:getInventory():Remove(self.journal)
            -- Show speaking bubble for SP (MP gets this from server response)
            if self.player and self.player.Say then
                self.player:Say(dissolveMsg)
            end
        end

        self:playSound(BurdJournals.Sounds.DISSOLVE)

        self:onClose()
    end
end

function BurdJournals.UI.MainPanel:update()
    ISPanel.update(self)

    if self.feedbackTicks and self.feedbackTicks > 0 then
        self.feedbackTicks = self.feedbackTicks - 1
        if self.feedbackTicks <= 0 and self.feedbackLabel then
            self.feedbackLabel:setVisible(false)
        end
    end

    if self.pendingNewJournalId then

        self.pendingJournalCheckCounter = (self.pendingJournalCheckCounter or 0) + 1
        if self.pendingJournalCheckCounter >= 30 then
            self.pendingJournalCheckCounter = 0
            local newJournal = BurdJournals.findItemById(self.player, self.pendingNewJournalId)
            if newJournal then
                BurdJournals.debugPrint("[BurdJournals] update: Found pending new journal! Updating reference.")
                self.journal = newJournal
                self.pendingNewJournalId = nil

                self:refreshJournalData()
            end
        end
    end
end

function BurdJournals.UI.MainPanel:onClose()

    if self.learningCompleted then
        self:doClose()
        return
    end

    if self.processingQueue then
        self:doClose()
        return
    end

    if self.learningState and self.learningState.active then

        self:showCloseConfirmDialog()
        return
    end

    self:doClose()
end

function BurdJournals.UI.MainPanel:setBorrowReturnContainer(returnContainer)
    if isEligibleJournalReturnContainer(self.player, returnContainer) then
        self.borrowReturnContainer = returnContainer
    else
        self.borrowReturnContainer = nil
    end
end

function BurdJournals.UI.MainPanel:tryReturnBorrowedJournal()
    local returnContainer = self.borrowReturnContainer
    if not returnContainer then return end
    self.borrowReturnContainer = nil

    if self.learningState and self.learningState.active then return end
    if self.processingQueue then return end
    if self.recordingState and self.recordingState.active then return end
    if not self.player or not self.journal then return end
    if not BurdJournals.isValidItem(self.journal) then return end
    if not isEligibleJournalReturnContainer(self.player, returnContainer) then return end

    local currentContainer = self.journal:getContainer()
    if not currentContainer or currentContainer == returnContainer then return end
    if not currentContainer.isInCharacterInventory or not currentContainer:isInCharacterInventory(self.player) then
        return
    end

    local action = ISInventoryTransferUtil.newInventoryTransferAction(
        self.player,
        self.journal,
        currentContainer,
        returnContainer,
        nil
    )
    if not action then return end
    if action.setAllowMissingItems then
        action:setAllowMissingItems(true)
    end
    ISTimedActionQueue.add(action)
end

function BurdJournals.UI.MainPanel:doClose()

    BurdJournals.safeRemoveEvent(Events.OnTick, BurdJournals.UI.MainPanel.onLearningTickStatic)
    BurdJournals.safeRemoveEvent(Events.OnTick, BurdJournals.UI.MainPanel.onRecordingTickStatic)
    BurdJournals.safeRemoveEvent(Events.OnTick, BurdJournals.UI.MainPanel.onPendingJournalRetryStatic)
    if self._headerRefreshTickHandler then
        BurdJournals.safeRemoveEvent(Events.OnTick, self._headerRefreshTickHandler)
        self._headerRefreshTickHandler = nil
    end

    if self.learningState and self.learningState.active then
        self:cancelLearning()
    end

    if self.confirmDialog then
        if self.confirmDialog.setVisible then
            self.confirmDialog:setVisible(false)
        end
        if self.confirmDialog.removeFromUIManager then
            self.confirmDialog:removeFromUIManager()
        end
        self.confirmDialog = nil
    end

    -- Unregister from baseline change notifications
    self:unregisterOpenPanel()

    self:tryReturnBorrowedJournal()

    self:setVisible(false)
    self:removeFromUIManager()
    BurdJournals.UI.MainPanel.instance = nil
end

function BurdJournals.UI.MainPanel:showCloseConfirmDialog()

    if self.confirmDialog then
        return
    end

    local dialogW = 280
    local dialogH = 120
    local dialogX = (getCore():getScreenWidth() - dialogW) / 2
    local dialogY = (getCore():getScreenHeight() - dialogH) / 2

    local dialog = ISPanel:new(dialogX, dialogY, dialogW, dialogH)
    dialog:initialise()
    dialog:instantiate()
    dialog.backgroundColor = {r=0.15, g=0.15, b=0.15, a=0.98}
    dialog.borderColor = {r=0.6, g=0.5, b=0.3, a=1}
    dialog.moveWithMouse = true
    dialog.mainPanel = self

    self.confirmDialog = dialog

    local warningText = getText("UI_BurdJournals_StateReading") or "You are still reading!"
    local warningLabel = ISLabel:new(dialogW/2, 20, 20, warningText, 1, 0.9, 0.7, 1, UIFont.Medium, true)
    dialog:addChild(warningLabel)

    local subText = getText("UI_BurdJournals_ConfirmCancelLearning") or "Cancel learning and close?"
    local subLabel = ISLabel:new(dialogW/2, 44, 16, subText, 0.8, 0.75, 0.65, 1, UIFont.Small, true)
    dialog:addChild(subLabel)

    local keepText = getText("UI_BurdJournals_BtnKeepReading") or "Keep Reading"
    local closeText = getText("UI_BurdJournals_BtnCancelClose") or "Cancel & Close"
    local keepTextW = getTextManager():MeasureStringX(UIFont.Small, keepText) + 20
    local closeTextW = getTextManager():MeasureStringX(UIFont.Small, closeText) + 20
    local btnW = math.max(100, keepTextW, closeTextW)
    local btnH = 28
    local btnSpacing = 20
    local btnStartX = (dialogW - btnW * 2 - btnSpacing) / 2
    local btnY = 75

    local dialogRef = dialog
    local mainPanelRef = self

    local keepBtn = ISButton:new(btnStartX, btnY, btnW, btnH, keepText, dialog, function(btn)

        if mainPanelRef then
            mainPanelRef.confirmDialog = nil
        end
        if dialogRef then
            dialogRef:setVisible(false)
            dialogRef:removeFromUIManager()
        end
    end)
    keepBtn:initialise()
    keepBtn:instantiate()
    keepBtn.borderColor = {r=0.4, g=0.6, b=0.4, a=1}
    keepBtn.backgroundColor = {r=0.2, g=0.3, b=0.2, a=0.9}
    keepBtn.textColor = {r=0.9, g=1, b=0.9, a=1}
    dialog:addChild(keepBtn)

    local closeBtn = ISButton:new(btnStartX + btnW + btnSpacing, btnY, btnW, btnH, closeText, dialog, function(btn)

        if mainPanelRef then
            mainPanelRef.confirmDialog = nil
        end

        if dialogRef then
            dialogRef:setVisible(false)
            dialogRef:removeFromUIManager()
        end

        if mainPanelRef then
            mainPanelRef:doClose()
        end
    end)
    closeBtn:initialise()
    closeBtn:instantiate()
    closeBtn.borderColor = {r=0.6, g=0.3, b=0.3, a=1}
    closeBtn.backgroundColor = {r=0.35, g=0.15, b=0.15, a=0.9}
    closeBtn.textColor = {r=1, g=0.85, b=0.85, a=1}
    dialog:addChild(closeBtn)

    dialog:addToUIManager()
    dialog:bringToTop()
end

function BurdJournals.UI.MainPanel.show(player, journal, mode, returnContainer)
    if BurdJournals.canUseJournalInCurrentLight then
        local canUse = BurdJournals.canUseJournalInCurrentLight(player)
        if not canUse then
            showTooDarkFeedback(player)
            return nil
        end
    end

    if BurdJournals.UI.MainPanel.instance then
        BurdJournals.UI.MainPanel.instance:onClose()
    end

    local baseWidth = 410
    local btnPadding = 20
    local btnSpacing = 8
    local minBtnWidth = 90

    local allTabNames = {
        getText("UI_BurdJournals_TabSkills") or "Skills",
        getText("UI_BurdJournals_TabTraits") or "Traits",
        getText("UI_BurdJournals_TabForget") or "Forget",
        getText("UI_BurdJournals_TabRecipes") or "Recipes",
        getText("UI_BurdJournals_TabStats") or "Stats"
    }

    local maxBtn1W = minBtnWidth
    local btn2Text, btn3Text
    local btnPrefix
    if mode == "log" then
        btnPrefix = getText("UI_BurdJournals_BtnRecordTab") or "Record %s"
        btn2Text = getText("UI_BurdJournals_BtnRecordAll") or "Record All"
    else
        btnPrefix = getText("UI_BurdJournals_BtnAbsorbTab") or "Absorb %s"
        btn2Text = getText("UI_BurdJournals_BtnAbsorbAll") or "Absorb All"
    end
    btn3Text = getText("UI_BurdJournals_BtnClose") or "Close"

    for _, tabName in ipairs(allTabNames) do
        local btn1Text = string.format(btnPrefix, tabName)
        local btn1W = getTextManager():MeasureStringX(UIFont.Small, btn1Text) + btnPadding
        maxBtn1W = math.max(maxBtn1W, btn1W)
    end

    local btn2W = math.max(minBtnWidth, getTextManager():MeasureStringX(UIFont.Small, btn2Text) + btnPadding)
    local btn3W = math.max(minBtnWidth, getTextManager():MeasureStringX(UIFont.Small, btn3Text) + btnPadding)

    -- Check if dissolve button will be shown (worn/bloody journals in absorb mode)
    local journalData = BurdJournals.getJournalData(journal)
    local hasBloodyOrigin = BurdJournals.hasBloodyOrigin(journal)
    local isBloody = BurdJournals.isBloody(journal)
    local isWorn = BurdJournals.isWorn and BurdJournals.isWorn(journal) or false
    local showDissolveBtn = mode ~= "log" and (isWorn or isBloody or hasBloodyOrigin)

    local btn4Text = getText("UI_BurdJournals_BtnDissolve") or "Dissolve"
    local btn4W = math.max(minBtnWidth, getTextManager():MeasureStringX(UIFont.Small, btn4Text) + btnPadding)

    local maxBtnW = math.max(maxBtn1W, btn2W, btn3W, btn4W)
    local numButtons = showDissolveBtn and 4 or 3
    local totalBtnWidth = maxBtnW * numButtons + btnSpacing * (numButtons - 1) + 48

    local width = math.max(baseWidth, totalBtnWidth)
    if journalData and journalData.isPlayerCreated == true and (mode == "log" or mode == "view") then
        -- Widen Player Journal record/claim panels by ~1.5x erase-button width for extra row text room.
        local eraseBtnWidth = 55
        local playerJournalWidthBonus = math.floor(((eraseBtnWidth * 3) / 2) + 0.5)
        local maxAllowedWidth = math.max(baseWidth, getCore():getScreenWidth() - 40)
        width = math.min(maxAllowedWidth, width + playerJournalWidthBonus)
    end

    local baseHeight = 180
    local itemHeight = 52
    local headerRowHeight = 52
    local minHeight = 420
    -- Max height is screen-aware: leave 100px margin top/bottom
    local screenHeight = getCore():getScreenHeight()
    local maxHeight = math.min(750, screenHeight - 100)
    local skillCount = 0
    local traitCount = 0
    local statCount = 0
    local recipeCount = 0

    if mode == "log" then
        local allowedSkills = BurdJournals.getAllowedSkills()
        if allowedSkills then
            for _, skillName in ipairs(allowedSkills) do
                if isSkillRecordableInPlayerJournal(skillName) then
                    local perk = BurdJournals.getPerkByName(skillName)
                    if perk then
                        local currentXP = player:getXp():getXP(perk)
                        local currentLevel = player:getPerkLevel(perk)
                        if currentXP > 0 or currentLevel > 0 then
                            skillCount = skillCount + 1
                        end
                    end
                end
            end
        end

        if BurdJournals.RECORDABLE_STATS then
            for _, stat in ipairs(BurdJournals.RECORDABLE_STATS) do
                if BurdJournals.isStatEnabled(stat.id) then
                    statCount = statCount + 1
                end
            end
        end

        -- Count recordable recipes for log mode
        if BurdJournals.isRecipeRecordingEnabled and BurdJournals.isRecipeRecordingEnabled() then
            local playerRecipes = BurdJournals.collectPlayerMagazineRecipes and BurdJournals.collectPlayerMagazineRecipes(player)
            if playerRecipes then
                for _ in pairs(playerRecipes) do
                    recipeCount = recipeCount + 1
                end
            end
        end
    else
        -- View/absorb mode - count from journal data
        if journalData and journalData.skills then
            for skillName, _ in pairs(journalData.skills) do
                if isSkillVisibleForJournal(journalData, skillName) then
                    skillCount = skillCount + 1
                end
            end
        end

        if journalData and journalData.traits then
            for _ in pairs(journalData.traits) do
                traitCount = traitCount + 1
            end
        end

        if journalData and journalData.recipes then
            for _ in pairs(journalData.recipes) do
                recipeCount = recipeCount + 1
            end
        end

        if journalData and journalData.stats then
            for _ in pairs(journalData.stats) do
                statCount = statCount + 1
            end
        end
    end

    -- Calculate content height based on the largest tab's content
    -- We use the max of different tab contents since only one tab shows at a time
    local skillsTabHeight = baseHeight + headerRowHeight + (skillCount * itemHeight)
    local traitsTabHeight = baseHeight + headerRowHeight + (traitCount * itemHeight)
    local recipesTabHeight = baseHeight + headerRowHeight + (recipeCount * itemHeight)
    local statsTabHeight = baseHeight + headerRowHeight + (statCount * itemHeight)

    local contentHeight = math.max(skillsTabHeight, traitsTabHeight, recipesTabHeight, statsTabHeight)

    local height = math.max(minHeight, math.min(maxHeight, contentHeight))

    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2

    local panel = BurdJournals.UI.MainPanel:new(x, y, width, height, player, journal, mode)
    panel:setBorrowReturnContainer(returnContainer)
    panel:initialise()
    panel:addToUIManager()
    BurdJournals.UI.MainPanel.instance = panel

    return panel
end

function BurdJournals.UI.MainPanel:createLogUI()
    self:refreshPlayer()

    local padding = 16
    local y = 0
    local btnHeight = 32

    self.recordingState = {
        active = false,
        skillName = nil,
        traitId = nil,
        isRecordAll = false,
        progress = 0,
        totalTime = 0,
        startTime = 0,
        pendingRecords = {},
        currentIndex = 0,
        queue = {},
    }
    self.recordingCompleted = false
    self.processingRecordQueue = false

    local journalData = BurdJournals.getJournalData(self.journal) or {}
    local recordedSkills = journalData.skills or {}
    local recordedTraits = journalData.traits or {}
    local recordedRecipes = journalData.recipes or {}

    self.isRecordMode = true
    self.recordedSkills = recordedSkills
    self.recordedTraits = recordedTraits
    self.recordedRecipes = recordedRecipes

    local headerHeight = 52
    self.headerRightInset = 0
    self.headerColor = {r=0.12, g=0.25, b=0.35}
    self.headerAccent = {r=0.2, g=0.45, b=0.55}
    self.typeText = getText("UI_BurdJournals_RecordProgressHeader")
    self.headerIconTexture = getHeaderJournalIconTexture("log", self.journal, journalData, false)
    self.headerIconSize = 20
    self.rarityText = nil
    self.flavorText = getText("UI_BurdJournals_RecordFlavor")
    self.headerHeight = headerHeight
    self:createHeaderRefreshButton(10, 15)
    y = headerHeight + 6

    local playerName = self.player:getDescriptor():getForename() .. " " .. self.player:getDescriptor():getSurname()
    self.authorName = playerName
    self.authorBoxY = y
    self.authorBoxHeight = 44
    y = y + self.authorBoxHeight + 10

    local tabs = {
        {id = "skills", label = getText("UI_BurdJournals_TabSkills")},
    }

    -- Only show traits tab if enabled for player journals
    if BurdJournals.getSandboxOption("EnableTraitRecordingPlayer") ~= false then
        table.insert(tabs, {id = "traits", label = getText("UI_BurdJournals_TabTraits")})
    end

    -- Only show recipes tab if enabled for player journals
    if BurdJournals.getSandboxOption("EnableRecipeRecordingPlayer") ~= false then
        table.insert(tabs, {id = "recipes", label = getText("UI_BurdJournals_TabRecipes")})
    end

    if BurdJournals.getSandboxOption("EnableStatRecording") then
        table.insert(tabs, {id = "charinfo", label = getText("UI_BurdJournals_TabStats")})
    end

    local tabThemeColors = {
        active = {r=0.18, g=0.32, b=0.42},
        inactive = {r=0.1, g=0.15, b=0.18},
        accent = {r=0.3, g=0.55, b=0.65}
    }
    self.tabThemeColors = tabThemeColors

    y = self:createTabs(tabs, y, tabThemeColors)

    self.filterBaseY = y
    y = self:createFilterTabBar(y, tabThemeColors)

    local skillItemCount = 24
    y = self:createSearchBar(y, tabThemeColors, skillItemCount)

    local footerHeight = 85
    local listHeight = self.height - y - footerHeight - padding

    self.skillList = ISScrollingListBox:new(padding, y, self.width - padding * 2, listHeight)
    self.skillList:initialise()
    self.skillList:instantiate()
    self.skillList.drawBorder = false
    self.skillList.backgroundColor = {r=0, g=0, b=0, a=0}
    self.skillList:setFont(UIFont.Small, 2)
    self.skillList.itemheight = 52
    self.skillList.doDrawItem = BurdJournals.UI.MainPanel.doDrawRecordItem
    self.skillList.mainPanel = self
    self.listBottomY = self.skillList:getY() + self.skillList:getHeight()

    self.skillList.onMouseUp = function(listbox, x, y)
        if listbox.vscroll then
            listbox.vscroll.scrolling = false
        end
        local row = listbox:rowAt(x, y)
        if row and row >= 1 and row <= #listbox.items then
            local item = listbox.items[row] and listbox.items[row].item
            if item and not item.isHeader and not item.isEmpty then

                local btnW = 55
                local margin = 10
                local mainBtnStart = listbox:getWidth() - btnW - margin

                if x >= mainBtnStart then

                    if not item.canRecord then

                        if item.isAtBaseline then
                            listbox.mainPanel:showFeedback(getText("UI_BurdJournals_CantRecordStartingSkills") or "Can't record starting skills", {r=0.7, g=0.5, b=0.3})
                        elseif item.isStartingTrait then
                            listbox.mainPanel:showFeedback(getText("UI_BurdJournals_CantRecordStartingTraits") or "Can't record starting traits", {r=0.7, g=0.5, b=0.3})
                        end
                        return
                    end
                    if item.isSkill then
                        listbox.mainPanel:recordSkill(item.skillName, item.xp, item.level)
                    elseif item.isTrait then
                        listbox.mainPanel:recordTrait(item.traitId)
                    elseif item.isStat then
                        listbox.mainPanel:recordStat(item.statId, item.currentValue)
                    elseif item.isRecipe then
                        listbox.mainPanel:recordRecipe(item.recipeName)
                    end
                end
            end
        end
        return true
    end
    self:addChild(self.skillList)
    y = y + listHeight

    self.footerY = y + 4
    self.footerHeight = footerHeight

    self.feedbackLabel = ISLabel:new(padding, self.footerY + 4, 18, "", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self:addChild(self.feedbackLabel)
    self.feedbackLabel:setVisible(false)
    self.feedbackTicks = 0

    local tabName = self:getTabDisplayName(self.currentTab or "skills")
    local recordTabText = string.format(getText("UI_BurdJournals_BtnRecordTab") or "Record %s", tabName)
    local recordAllText = getText("UI_BurdJournals_BtnRecordAll") or "Record All"
    local closeText = getText("UI_BurdJournals_BtnClose") or "Close"

    local allTabNames = {
        getText("UI_BurdJournals_TabSkills") or "Skills",
        getText("UI_BurdJournals_TabTraits") or "Traits",
        getText("UI_BurdJournals_TabForget") or "Forget",
        getText("UI_BurdJournals_TabRecipes") or "Recipes",
        getText("UI_BurdJournals_TabStats") or "Stats"
    }
    local btnPrefix = getText("UI_BurdJournals_BtnRecordTab") or "Record %s"
    local maxRecordTabW = 90
    for _, name in ipairs(allTabNames) do
        local text = string.format(btnPrefix, name)
        local w = getTextManager():MeasureStringX(UIFont.Small, text) + 20
        maxRecordTabW = math.max(maxRecordTabW, w)
    end
    local recordAllW = getTextManager():MeasureStringX(UIFont.Small, recordAllText) + 20
    local closeW = getTextManager():MeasureStringX(UIFont.Small, closeText) + 20
    local btnWidth = math.max(90, maxRecordTabW, recordAllW, closeW)

    local btnSpacing = 8
    local totalBtnWidth = btnWidth * 3 + btnSpacing * 2
    local btnStartX = (self.width - totalBtnWidth) / 2
    local btnY = self.footerY + 32

    self.recordTabBtn = ISButton:new(btnStartX, btnY, btnWidth, btnHeight, recordTabText, self, BurdJournals.UI.MainPanel.onRecordTab)
    self.recordTabBtn:initialise()
    self.recordTabBtn:instantiate()
    self.recordTabBtn.borderColor = {r=0.25, g=0.45, b=0.55, a=1}
    self.recordTabBtn.backgroundColor = {r=0.12, g=0.24, b=0.30, a=0.8}
    self.recordTabBtn.textColor = {r=1, g=1, b=1, a=1}
    self:addChild(self.recordTabBtn)

    self.recordAllBtn = ISButton:new(btnStartX + btnWidth + btnSpacing, btnY, btnWidth, btnHeight, recordAllText, self, BurdJournals.UI.MainPanel.onRecordAll)
    self.recordAllBtn:initialise()
    self.recordAllBtn:instantiate()
    self.recordAllBtn.borderColor = {r=0.3, g=0.5, b=0.6, a=1}
    self.recordAllBtn.backgroundColor = {r=0.15, g=0.28, b=0.35, a=0.8}
    self.recordAllBtn.textColor = {r=1, g=1, b=1, a=1}
    self:addChild(self.recordAllBtn)

    self.closeBottomBtn = ISButton:new(btnStartX + (btnWidth + btnSpacing) * 2, btnY, btnWidth, btnHeight, closeText, self, BurdJournals.UI.MainPanel.onClose)
    self.closeBottomBtn:initialise()
    self.closeBottomBtn:instantiate()
    self.closeBottomBtn.borderColor = {r=0.4, g=0.35, b=0.3, a=1}
    self.closeBottomBtn.backgroundColor = {r=0.15, g=0.13, b=0.12, a=0.8}
    self.closeBottomBtn.textColor = {r=0.9, g=0.85, b=0.8, a=1}
    self:addChild(self.closeBottomBtn)

    -- Legacy baseline debug buttons removed - use BSJ Debug Center (Baseline tab) instead
    
    self:populateRecordList()
end

-- Legacy baseline debug functions removed - use BSJ Debug Center (Baseline tab) instead

function BurdJournals.UI.MainPanel:populateRecordList(overrideData)
    self.skillList:clear()

    local journalData
    if overrideData then
        journalData = overrideData
        BurdJournals.debugPrint("[BurdJournals] populateRecordList: Using override data from server response")
    else
        journalData = BurdJournals.getJournalData(self.journal) or {}
    end

    local useBaselineForJournal, autoRepairedMode = resolveJournalRecordingModeForPlayer(journalData, self.player)
    if autoRepairedMode then
        BurdJournals.debugPrint("[BurdJournals] populateRecordList: detected legacy absolute journal entries while baseline flag was set; using absolute mode for display")
    end

    -- Only enforce baseline capture when this journal is recording in baseline mode.
    local baselineReady, normalizedUseBaseline = ensureBaselineReadyForRecording(self, useBaselineForJournal, "populateRecordList")
    useBaselineForJournal = normalizedUseBaseline
    if not baselineReady then
        self.skillList:addItem("initializing", {
            isEmpty = true,
            text = getText("UI_BurdJournals_BaselineInitializing") or "Please wait - character data initializing..."
        })
        return
    end

    self.recordedSkills = journalData.skills or {}
    self.recordedTraits = journalData.traits or {}
    self.recordedRecipes = journalData.recipes or {}

    local allowedSkills = BurdJournals.getAllowedSkills()
    local recordedSkills = self.recordedSkills
    local recordedTraits = self.recordedTraits
    local currentTab = self.currentTab or "skills"

    if currentTab == "skills" then

        local matchCount = 0
        local totalSkills = 0
        local useBaseline = useBaselineForJournal

        for _, skillName in ipairs(allowedSkills) do
            if isSkillRecordableInPlayerJournal(skillName) then
                local perk = BurdJournals.getPerkByName(skillName)
                if perk then
                    local currentXP = self.player:getXp():getXP(perk)
                    local currentLevel = self.player:getPerkLevel(perk)

                    if currentXP > 0 or currentLevel > 0 then
                        totalSkills = totalSkills + 1
                        local displayName = BurdJournals.getPerkDisplayName(skillName)
                        local modSource = BurdJournals.getSkillModId(skillName)

                        if self:matchesSearch(displayName) and self:passesFilter(modSource) then
                            matchCount = matchCount + 1
                            local recordedData = recordedSkills[skillName]
                            local recordedXP = recordedData and recordedData.xp or 0
                            local _, recordedRawXP, recordedVhsExcludedXP = getSkillVhsBreakdown(recordedData, recordedXP)
                            local recordedLevel = recordedData and recordedData.level or 0

                            local baselineXP = 0
                            if useBaseline then
                                baselineXP = BurdJournals.getSkillBaseline(self.player, skillName)
                            end

                            local earnedXP = math.max(0, currentXP - baselineXP)

                            local canRecord = earnedXP > recordedXP

                            -- For passive skills (Fitness/Strength), use level-based check since XP can be tricky
                            local isPassiveSkill = (skillName == "Fitness" or skillName == "Strength")
                            local baselineLevel = BurdJournals.getSkillBaselineLevel(self.player, skillName) or 0
                            local isAtBaseline = false
                            if useBaseline and baselineXP > 0 then
                                if isPassiveSkill then
                                    -- Passive skills: at baseline if still at or below their baseline level
                                    isAtBaseline = currentLevel <= baselineLevel
                                else
                                    -- Regular skills: at baseline if no earned XP
                                    isAtBaseline = earnedXP == 0
                                end
                            end

                            local skillTooltip = buildSkillVhsTooltip({
                                xp = recordedXP,
                                rawXP = recordedRawXP,
                                vhsExcludedXP = recordedVhsExcludedXP
                            }, nil, nil)

                            self.skillList:addItem(skillName, {
                                isSkill = true,
                                skillName = skillName,
                                displayName = displayName,
                                xp = earnedXP,
                                currentXP = currentXP,
                                level = currentLevel,
                                recordedXP = recordedXP,
                                recordedRawXP = recordedRawXP,
                                recordedVhsExcludedXP = recordedVhsExcludedXP,
                                recordedLevel = recordedLevel,
                                isRecorded = recordedXP > 0,
                                canRecord = canRecord,
                                baselineXP = baselineXP,
                                baselineLevel = baselineLevel,
                                earnedXP = earnedXP,
                                isAtBaseline = isAtBaseline,
                                isPassiveSkill = isPassiveSkill,
                                modSource = modSource,
                            }, skillTooltip)
                        end
                    end
                end
            end
        end

        if matchCount == 0 then
            if totalSkills == 0 then
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSkillsToRecord") or "No skills to record yet"})
            else
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        end

    elseif currentTab == "traits" then

        local playerTraits = BurdJournals.collectPlayerTraits(self.player, false)
        local grantableTraitList = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or BurdJournals.GRANTABLE_TRAITS or {}
        local positiveTraits = {}
        for traitId, traitData in pairs(playerTraits) do

            if BurdJournals.isTraitGrantable(traitId, grantableTraitList) then
                positiveTraits[traitId] = traitData
            end
        end

        local matchCount = 0
        local totalTraits = 0
        for traitId, traitData in pairs(positiveTraits) do
            totalTraits = totalTraits + 1
            local traitName = safeGetTraitName(traitId)
            local modSource = BurdJournals.getTraitModId(traitId)

            if self:matchesSearch(traitName) and self:passesFilter(modSource) then
                matchCount = matchCount + 1
                local traitTexture = getTraitTexture(traitId)

                local isRecorded = recordedTraits[traitId] ~= nil or recordedTraits[string.lower(traitId)] ~= nil
                local isStartingTrait = BurdJournals.isStartingTrait(self.player, traitId)
                local isPositive = isTraitPositive(traitId)

                self.skillList:addItem(traitId, {
                    isTrait = true,
                    traitId = traitId,
                    traitName = traitName,
                    traitTexture = traitTexture,
                    isRecorded = isRecorded,
                    isStartingTrait = isStartingTrait,
                    canRecord = not isRecorded and not isStartingTrait,
                    isPositive = isPositive,
                    modSource = modSource,
                })
            end
        end

        if matchCount == 0 then
            if totalTraits == 0 then
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoTraitsToRecord") or "No traits to record"})
            else
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        end

    elseif currentTab == "charinfo" then
        if BurdJournals.getSandboxOption("EnableStatRecording") then
            local recordedStats = journalData.stats or {}
            local matchCount = 0
            local totalStats = 0

            for _, stat in ipairs(BurdJournals.RECORDABLE_STATS) do
                if BurdJournals.isStatEnabled(stat.id) then
                    totalStats = totalStats + 1
                    local localizedName = BurdJournals.getStatName(stat)
                    local localizedDesc = BurdJournals.getStatDescription(stat)

                    if self:matchesSearch(localizedName) then
                        matchCount = matchCount + 1
                        local currentValue = BurdJournals.getStatValue(self.player, stat.id)
                        local recorded = recordedStats[stat.id]
                        -- Stats are stored as tables with {value = X, timestamp = Y, recordedBy = Z}
                        local recordedValue = nil
                        if recorded then
                            recordedValue = type(recorded) == "table" and recorded.value or recorded
                            if type(recordedValue) ~= "number" then recordedValue = nil end
                        end
                        local canUpdate, _, _ = BurdJournals.canUpdateStat(self.journal, stat.id, self.player)

                        local currentFormatted = BurdJournals.formatStatValue(stat.id, currentValue)
                        local recordedFormatted = recordedValue and BurdJournals.formatStatValue(stat.id, recordedValue) or nil

                        self.skillList:addItem(stat.id, {
                            isStat = true,
                            statId = stat.id,
                            statName = localizedName,
                            statCategory = stat.category,
                            statDescription = localizedDesc,
                            currentValue = currentValue,
                            currentFormatted = currentFormatted,
                            recordedValue = recordedValue,
                            recordedFormatted = recordedFormatted,
                            isRecorded = recordedValue ~= nil,
                            canRecord = canUpdate,
                            isText = stat.isText,
                        })
                    end
                end
            end

            if matchCount == 0 then
                if totalStats == 0 then
                    self.skillList:addItem("empty", {isEmpty = true, text = "No stats enabled"})
                else
                    self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
                end
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = "Stat recording is disabled"})
        end

    elseif currentTab == "recipes" then
        if BurdJournals.isRecipeRecordingEnabled() then
            local recordedRecipes = journalData.recipes or {}

            local playerRecipes = BurdJournals.collectPlayerMagazineRecipes(self.player)
            local matchCount = 0
            local totalRecipes = 0

            for recipeName, recipeData in pairs(playerRecipes) do
                totalRecipes = totalRecipes + 1
                local displayName = BurdJournals.getRecipeDisplayName(recipeName)
                local magazineSource = (type(recipeData) == "table" and recipeData.source) or BurdJournals.getMagazineForRecipe(recipeName)
                local modSource = BurdJournals.getRecipeModId(recipeName, magazineSource)

                if self:matchesSearch(displayName) and self:passesFilter(modSource) then
                    matchCount = matchCount + 1
                    local isRecorded = recordedRecipes[recipeName] ~= nil

                    self.skillList:addItem(recipeName, {
                        isRecipe = true,
                        recipeName = recipeName,
                        displayName = displayName,
                        magazineSource = magazineSource,
                        isRecorded = isRecorded,
                        canRecord = not isRecorded,
                        modSource = modSource,
                    })
                end
            end

            if matchCount == 0 then
                if totalRecipes == 0 then
                    self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoRecipesToRecord") or "No magazine recipes learned"})
                else
                    self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
                end
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = "Recipe recording is disabled"})
        end
    end
end

function BurdJournals.UI.MainPanel.doDrawRecordItem(self, y, item, alt)
    local mainPanel = self.mainPanel
    if not mainPanel then return y + self.itemheight end

    local data = item.item or {}
    local x = 0

    local scrollBarWidth = 13
    local w = self:getWidth() - scrollBarWidth
    local h = self.itemheight
    local padding = 12

    local cardBg = {r=0.12, g=0.16, b=0.20}
    local cardBorder = {r=0.25, g=0.38, b=0.45}
    local accentColor = {r=0.3, g=0.55, b=0.65}

    if data.isHeader then
        self:drawRect(x, y + 2, w, h - 4, 0.4, 0.12, 0.18, 0.22)
        self:drawText(data.text or getText("UI_BurdJournals_YourSkills") or "YOUR SKILLS", x + padding, y + (h - 18) / 2, 0.7, 0.9, 1.0, 1, UIFont.Medium)
        if data.count then
            local countText = string.format(getText("UI_BurdJournals_Recordable") or "(%d recordable)", data.count)
            local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
            self:drawText(countText, w - padding - countWidth, y + (h - 14) / 2, 0.4, 0.6, 0.7, 1, UIFont.Small)
        end
        return y + h
    end

    if data.isEmpty then
        self:drawText(data.text or getText("UI_BurdJournals_NothingToRecord") or "Nothing to record", x + padding, y + (h - 14) / 2, 0.4, 0.5, 0.55, 1, UIFont.Small)
        return y + h
    end

    local cardMargin = 4
    local cardX = x + cardMargin
    local cardY = y + cardMargin
    local cardW = w - cardMargin * 2
    local cardH = h - cardMargin * 2

    local bgColor = cardBg
    local borderColor = cardBorder
    local accentGreen = {r=0.3, g=0.7, b=0.4}
    if data.isTrait then
        if data.isPositive == true then

            bgColor = {r=0.08, g=0.20, b=0.10}
            borderColor = {r=0.2, g=0.5, b=0.25}
            accentGreen = {r=0.3, g=0.8, b=0.35}
        elseif data.isPositive == false then

            bgColor = {r=0.22, g=0.08, b=0.08}
            borderColor = {r=0.5, g=0.2, b=0.2}
            accentGreen = {r=0.8, g=0.3, b=0.3}
        end

    end

    if data.isRecorded and not data.canRecord then
        self:drawRect(cardX, cardY, cardW, cardH, 0.4, 0.12, 0.15, 0.12)
    else
        self:drawRect(cardX, cardY, cardW, cardH, 0.7, bgColor.r, bgColor.g, bgColor.b)
    end

    self:drawRectBorder(cardX, cardY, cardW, cardH, 0.6, borderColor.r, borderColor.g, borderColor.b)

    if data.canRecord then
        self:drawRect(cardX, cardY, 4, cardH, 0.9, accentGreen.r, accentGreen.g, accentGreen.b)
    else
        self:drawRect(cardX, cardY, 4, cardH, 0.5, 0.3, 0.35, 0.3)
    end

    local textX = cardX + padding + 4
    local textColor = data.canRecord and {r=0.95, g=0.95, b=1.0} or {r=0.5, g=0.55, b=0.5}

    if data.isSkill then

        local recordingState = mainPanel.recordingState
        local isRecordingThis = recordingState and recordingState.active and not recordingState.isRecordAll
                               and recordingState.skillName == data.skillName

        local baselineXP = data.baselineXP or 0
        local baselineLevel = data.baselineLevel or 0
        local earnedXP = data.earnedXP or data.xp
        -- For passive skills (Fitness/Strength), use level-based check
        local isPassiveSkill = data.isPassiveSkill or (data.skillName == "Fitness" or data.skillName == "Strength")
        local isStartingSkill = data.isAtBaseline
        if not isStartingSkill and baselineXP > 0 then
            if isPassiveSkill then
                -- Passive skills: at baseline if level <= their baseline level
                isStartingSkill = (data.level or 0) <= baselineLevel
            else
                isStartingSkill = earnedXP == 0
            end
        end

        local displayName = data.displayName or data.skillName or "Unknown Skill"
        self:drawText(displayName .. " (Lv." .. data.level .. ")", textX, cardY + 6, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)

        if isRecordingThis then

            local progressFormat = getText("UI_BurdJournals_RecordingProgress") or "Recording... %d%%"
            local progressText = string.format(progressFormat, math.floor(recordingState.progress * 100))
            self:drawText(progressText, textX, cardY + 24, 0.3, 0.8, 0.5, 1, UIFont.Small)

            local barX = textX + 100
            local barY = cardY + 27
            local barW = cardW - 130 - padding
            local barH = 10
            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)
            self:drawRect(barX, barY, barW * recordingState.progress, barH, 0.9, 0.3, 0.7, 0.4)
            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.4, 0.8, 0.5)
        elseif isStartingSkill then

            local squaresX = textX
            local squaresY = cardY + 26
            local squareSize = 10
            local squareSpacing = 2
            
            -- Use stored level from game (data.level) as the authoritative level
            -- Then calculate progress within that level based on XP
            local currentLevel = data.level or 0
            local currentXP = data.currentXP or 0
            
            -- Calculate progress within the current level
            local progress = 0
            if currentLevel < 10 and currentLevel > 0 then
                local xpForCurrentLevel = getXPForLevel(data.skillName, currentLevel)
                local xpForNextLevel = getXPForLevel(data.skillName, currentLevel + 1)
                local xpInThisLevel = currentXP - xpForCurrentLevel
                local xpRangeForLevel = xpForNextLevel - xpForCurrentLevel
                if xpRangeForLevel > 0 then
                    progress = math.min(1, math.max(0, xpInThisLevel / xpRangeForLevel))
                end
            end
            
            -- Draw squares showing current level, progress, and baseline indication
            for i = 1, 10 do
                local sqX = squaresX + (i - 1) * (squareSize + squareSpacing)
                if i <= currentLevel then
                    -- Completed level squares (dimmed brown - at baseline)
                    self:drawRect(sqX, squaresY, squareSize, squareSize, 0.7, 0.35, 0.28, 0.22)
                elseif i == currentLevel + 1 and progress > 0 then
                    -- Progress square - show partial fill from bottom
                    self:drawRect(sqX, squaresY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.1)
                    local fillHeight = squareSize * progress
                    self:drawRect(sqX, squaresY + squareSize - fillHeight, squareSize, fillHeight, 0.6, 0.3, 0.24, 0.18)
                elseif i <= baselineLevel then
                    -- Baseline above current (even more dimmed - shows what's restricted)
                    self:drawRect(sqX, squaresY, squareSize, squareSize, 0.3, 0.2, 0.18, 0.15)
                else
                    -- Empty squares
                    self:drawRect(sqX, squaresY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.1)
                end
                self:drawRectBorder(sqX, squaresY, squareSize, squareSize, 0.3, 0.3, 0.3, 0.3)
            end

            local squaresWidth = 10 * squareSize + 9 * squareSpacing
            -- Show current level vs baseline level in text
            local baselineText
            if baselineLevel > 0 and baselineLevel > currentLevel then
                baselineText = string.format("Lv.%d (Baseline: %d)", currentLevel, baselineLevel)
            else
                baselineText = string.format(getText("UI_BurdJournals_StartingXP"), BurdJournals.formatXP(baselineXP))
            end
            self:drawText(baselineText, squaresX + squaresWidth + 8, squaresY, 0.5, 0.4, 0.35, 1, UIFont.Small)
        else

            local squaresX = textX
            local squaresY = cardY + 26
            local squareSize = 10
            local squareSpacing = 2

            -- Use the game's reported level as authoritative, calculate progress from XP
            local totalLevel = data.level or 0
            local totalProgress = 0
            
            -- Calculate progress within the current level using XP
            local currentXP = data.currentXP or 0
            if totalLevel < 10 and totalLevel >= 0 then
                local xpForCurrentLevel = getXPForLevel(data.skillName, totalLevel)
                local xpForNextLevel = getXPForLevel(data.skillName, totalLevel + 1)
                local xpInThisLevel = currentXP - xpForCurrentLevel
                local xpRangeForLevel = xpForNextLevel - xpForCurrentLevel
                if xpRangeForLevel > 0 and xpInThisLevel > 0 then
                    totalProgress = math.min(1, math.max(0, xpInThisLevel / xpRangeForLevel))
                end
            end

            if baselineXP > 0 then
                -- Has baseline - use the enhanced function to show baseline vs earned distinction
                local calcBaselineLevel, baselineProgress = calculateLevelProgress(data.skillName, baselineXP)
                
                -- For passive skills, use stored baseline level but keep progress
                if isPassiveSkill then
                    local storedBaseline = baselineLevel or 5
                    if storedBaseline > calcBaselineLevel then
                        calcBaselineLevel = storedBaseline
                        baselineProgress = 0
                    end
                end

                local baselineColor, earnedColor, emptyColor, progressColor
                if data.isRecorded and not data.canRecord then
                    -- Already recorded, greyed out
                    baselineColor = {r=0.2, g=0.22, b=0.2}
                    earnedColor = {r=0.25, g=0.4, b=0.3}
                    emptyColor = {r=0.1, g=0.1, b=0.1}
                    progressColor = {r=0.2, g=0.3, b=0.25}
                else
                    -- Recordable - baseline dimmed, earned bright
                    baselineColor = {r=0.35, g=0.28, b=0.22}  -- Brownish/dimmed for baseline
                    earnedColor = {r=0.3, g=0.65, b=0.55}     -- Bright teal for earned
                    emptyColor = {r=0.12, g=0.12, b=0.12}
                    progressColor = {r=0.2, g=0.4, b=0.35}
                end

                drawLevelSquaresWithBaseline(self, squaresX, squaresY,
                    calcBaselineLevel, baselineProgress,
                    totalLevel, totalProgress,
                    squareSize, squareSpacing,
                    baselineColor, earnedColor, emptyColor, progressColor
                )
            else
                -- No baseline - use standard drawing
                local filledColor, emptyColor, progressColor
                if data.isRecorded and not data.canRecord then
                    filledColor = {r=0.25, g=0.4, b=0.3}
                    emptyColor = {r=0.1, g=0.1, b=0.1}
                    progressColor = {r=0.2, g=0.3, b=0.25}
                else
                    filledColor = {r=0.3, g=0.65, b=0.55}
                    emptyColor = {r=0.12, g=0.12, b=0.12}
                    progressColor = {r=0.2, g=0.4, b=0.35}
                end

                drawLevelSquares(self, squaresX, squaresY, totalLevel, totalProgress, squareSize, squareSpacing,
                    filledColor, emptyColor, progressColor
                )
            end

            local squaresWidth = 10 * squareSize + 9 * squareSpacing
            local xpText
            local xpColor
            local recordedSummary = formatXPWithVhsBreakdown(
                data.recordedXP or 0,
                data.recordedRawXP or data.recordedXP or 0,
                data.recordedVhsExcludedXP or 0
            )

            if data.isRecorded and not data.canRecord then

                xpText = "Recorded: " .. recordedSummary
                xpColor = {r=0.4, g=0.5, b=0.45}
            elseif data.isRecorded and data.canRecord then

                if baselineXP > 0 then
                    xpText = string.format(getText("UI_BurdJournals_XPWithBaseline"),
                        BurdJournals.formatXP(earnedXP), BurdJournals.formatXP(baselineXP))
                    xpText = xpText .. " (was " .. recordedSummary .. ")"
                else
                    xpText = BurdJournals.formatXP(earnedXP) .. " XP (was " .. recordedSummary .. ")"
                end
                xpColor = {r=0.5, g=0.8, b=0.6}
            else

                if baselineXP > 0 then
                    xpText = string.format(getText("UI_BurdJournals_XPWithBaseline"),
                        BurdJournals.formatXP(earnedXP), BurdJournals.formatXP(baselineXP))
                else
                    xpText = BurdJournals.formatXP(earnedXP) .. " XP"
                end
                xpColor = {r=0.5, g=0.75, b=0.7}
            end

            self:drawText(xpText, squaresX + squaresWidth + 8, squaresY, xpColor.r, xpColor.g, xpColor.b, 1, UIFont.Small)
        end

        local btnW = 55
        local btnH = 24

        local mainBtnX = cardX + cardW - btnW - 10
        local btnY = cardY + (cardH - btnH) / 2

        if data.canRecord and not isRecordingThis then

            local queuePosition = mainPanel:getRecordQueuePosition(data.skillName)
            local isQueued = queuePosition ~= nil

            local isInBatch = isInCurrentBatch(recordingState, "skill", data.skillName)

            if isQueued then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.5, 0.3, 0.4, 0.5)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.6, 0.4, 0.5, 0.6)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.8, 0.9, 1, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being processed
                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.45, 0.55, 0.45)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.6, 0.7, 0.6)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
            elseif recordingState and recordingState.active and not recordingState.isRecordAll then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.25, 0.35, 0.5)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.4, 0.55, 0.7)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.95, 1, 1, UIFont.Small)
            else

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.7, 0.2, 0.45, 0.35)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.3, 0.6, 0.5)
                local btnText = getText("UI_BurdJournals_BtnRecord")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end

    if data.isTrait then
        local recordingState = mainPanel.recordingState
        local isRecordingThis = recordingState and recordingState.active and not recordingState.isRecordAll
                               and recordingState.traitId == data.traitId

        local traitName = data.traitName or data.traitId or getText("UI_BurdJournals_UnknownTrait") or "Unknown Trait"
        local traitTextX = textX

        if data.traitTexture then
            local iconSize = 24
            local iconX = textX
            local iconY = cardY + (cardH - iconSize) / 2
            local iconAlpha = data.canRecord and 1.0 or 0.5
            self:drawTextureScaledAspect(data.traitTexture, iconX, iconY, iconSize, iconSize, iconAlpha, 1, 1, 1)
            traitTextX = textX + iconSize + 6
        end

        local traitColor
        if not data.canRecord then
            traitColor = {r=0.5, g=0.55, b=0.5}
        elseif data.isPositive == true then
            traitColor = {r=0.5, g=0.9, b=0.5}
        elseif data.isPositive == false then
            traitColor = {r=0.9, g=0.5, b=0.5}
        else
            traitColor = {r=0.8, g=0.9, b=1.0}
        end
        self:drawText(traitName, traitTextX, cardY + 6, traitColor.r, traitColor.g, traitColor.b, 1, UIFont.Small)

        local queuePosition = mainPanel:getRecordQueuePosition(data.traitId)
        local isQueued = queuePosition ~= nil

        if isRecordingThis then
            local progressFormat = getText("UI_BurdJournals_RecordingProgress") or "Recording... %d%%"
            local progressText = string.format(progressFormat, math.floor(recordingState.progress * 100))
            self:drawText(progressText, traitTextX, cardY + 22, 0.3, 0.8, 0.5, 1, UIFont.Small)

            local barX = traitTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * recordingState.progress, barH, 0.9, 0.2, 0.6, 0.5)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.3, 0.7, 0.6)
        elseif isQueued then
            local queuedText = string.format(getText("UI_BurdJournals_QueuedNumber") or "Queued #%d", queuePosition)
            self:drawText(queuedText, traitTextX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)
        elseif data.isStartingTrait then

            self:drawText(getText("UI_BurdJournals_SpawnedWith") or "Spawned with", traitTextX, cardY + 22, 0.5, 0.45, 0.4, 1, UIFont.Small)
        elseif data.isRecorded then
            self:drawText(getText("UI_BurdJournals_StatusAlreadyRecorded") or "Already recorded", traitTextX, cardY + 22, 0.4, 0.5, 0.4, 1, UIFont.Small)
        else
            self:drawText(getText("UI_BurdJournals_YourTrait") or "Your trait", traitTextX, cardY + 22, 0.5, 0.7, 0.8, 1, UIFont.Small)
        end

        local btnW = 55
        local btnH = 24

        local mainBtnX = cardX + cardW - btnW - 10
        local btnY = cardY + (cardH - btnH) / 2

        if data.canRecord and not isRecordingThis then
            local isInBatch = isInCurrentBatch(recordingState, "trait", data.traitId)

            if isQueued then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.35, 0.5)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.6, 0.5, 0.45, 0.6)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.85, 0.7, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being processed
                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.5, 0.45, 0.45)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.65, 0.55, 0.6)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.85, 1, UIFont.Small)
            elseif recordingState and recordingState.active and not recordingState.isRecordAll then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.4, 0.35, 0.25)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.6, 0.5, 0.35)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.85, 1, UIFont.Small)
            else

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.7, 0.35, 0.45, 0.25)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.5, 0.6, 0.4)
                local btnText = getText("UI_BurdJournals_BtnRecord")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 0.9, 1, UIFont.Small)
            end
        end
    end

    if data.isStat then
        local recordingState = mainPanel.recordingState
        local isRecordingThis = recordingState and recordingState.active and not recordingState.isRecordAll
                               and recordingState.statId == data.statId

        local statName = data.statName or data.statId or "Unknown Stat"
        self:drawText(statName, textX, cardY + 6, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)

        local queuePosition = mainPanel:getRecordQueuePosition(data.statId)
        local isQueued = queuePosition ~= nil

        if isRecordingThis then
            local progressFormat = getText("UI_BurdJournals_RecordingProgress") or "Recording... %d%%"
            local progressText = string.format(progressFormat, math.floor(recordingState.progress * 100))
            self:drawText(progressText, textX, cardY + 22, 0.3, 0.8, 0.5, 1, UIFont.Small)

            local barX = textX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * recordingState.progress, barH, 0.9, 0.2, 0.6, 0.5)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.3, 0.7, 0.6)
        elseif isQueued then
            local valueText = string.format(getText("UI_BurdJournals_CurrentQueued") or "Current: %s - Queued #%d", data.currentFormatted or "?", queuePosition)
            self:drawText(valueText, textX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)
        elseif data.isRecorded then
            if data.canRecord then

                local valueText = string.format(getText("UI_BurdJournals_NowWas") or "Now: %s (was %s)", data.currentFormatted or "?", data.recordedFormatted or "?")
                self:drawText(valueText, textX, cardY + 22, 0.5, 0.8, 0.5, 1, UIFont.Small)
            else

                local valueText = string.format(getText("UI_BurdJournals_RecordedValue") or "Recorded: %s", data.recordedFormatted or "?")
                self:drawText(valueText, textX, cardY + 22, 0.4, 0.5, 0.4, 1, UIFont.Small)
            end
        else

            local valueText = string.format(getText("UI_BurdJournals_CurrentValue") or "Current: %s", data.currentFormatted or "?")
            self:drawText(valueText, textX, cardY + 22, 0.5, 0.7, 0.8, 1, UIFont.Small)
        end

        if data.canRecord and not isRecordingThis then
            local btnW = 65
            local btnH = 24
            local btnX = cardX + cardW - btnW - 10
            local btnY = cardY + (cardH - btnH) / 2
            local isInBatch = isInCurrentBatch(recordingState, "stat", data.statId)

            if isQueued then

                self:drawRect(btnX, btnY, btnW, btnH, 0.5, 0.35, 0.45, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.6, 0.45, 0.55, 0.6)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.8, 0.9, 1, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being processed
                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.4, 0.5, 0.45)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.55, 0.65, 0.6)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
            elseif recordingState and recordingState.active and not recordingState.isRecordAll then

                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.3, 0.4, 0.5)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.45, 0.55, 0.65)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.95, 1, 1, UIFont.Small)
            else

                self:drawRect(btnX, btnY, btnW, btnH, 0.7, 0.2, 0.4, 0.45)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.35, 0.55, 0.6)
                local btnText = getText("UI_BurdJournals_BtnRecord")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end

    if data.isRecipe then
        local recordingState = mainPanel.recordingState
        local isRecordingThis = recordingState and recordingState.active and not recordingState.isRecordAll
                               and recordingState.recipeName == data.recipeName

        local displayName = data.displayName or data.recipeName or "Unknown Recipe"
        local recipeTextX = textX

        local magazineTexture = getMagazineTexture(data.magazineSource)

        if magazineTexture then
            local iconSize = 24
            local iconX = textX
            local iconY = cardY + (cardH - iconSize) / 2
            local iconAlpha = data.canRecord and 1.0 or 0.5
            self:drawTextureScaledAspect(magazineTexture, iconX, iconY, iconSize, iconSize, iconAlpha, 1, 1, 1)
            recipeTextX = textX + iconSize + 6
        end

        self:drawText(displayName, recipeTextX, cardY + 6, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)

        local queuePosition = mainPanel:getRecordQueuePosition(data.recipeName)
        local isQueued = queuePosition ~= nil

        if isRecordingThis then
            local progressFormat = getText("UI_BurdJournals_RecordingProgress") or "Recording... %d%%"
            local progressText = string.format(progressFormat, math.floor(recordingState.progress * 100))
            self:drawText(progressText, recipeTextX, cardY + 22, 0.3, 0.8, 0.5, 1, UIFont.Small)

            local barX = recipeTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)
            self:drawRect(barX, barY, barW * recordingState.progress, barH, 0.9, 0.5, 0.85, 0.9)
            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.5, 0.85, 0.9)
        elseif isQueued then
            local queuedText = string.format(getText("UI_BurdJournals_QueuedNumber") or "Queued #%d", queuePosition)
            self:drawText(queuedText, recipeTextX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)
        elseif data.isRecorded then
            self:drawText(getText("UI_BurdJournals_StatusAlreadyRecorded") or "Already recorded", recipeTextX, cardY + 22, 0.4, 0.5, 0.4, 1, UIFont.Small)
        else

            local magazineName = data.magazineSource and BurdJournals.getMagazineDisplayName(data.magazineSource) or nil
            local sourceText = magazineName and string.format(getText("UI_BurdJournals_RecipeFromMagazine") or "From: %s", magazineName) or "Learned from magazine"
            self:drawText(sourceText, recipeTextX, cardY + 22, 0.5, 0.7, 0.8, 1, UIFont.Small)
        end

        if data.canRecord and not isRecordingThis then
            local btnW = 65
            local btnH = 24
            local btnX = cardX + cardW - btnW - 10
            local btnY = cardY + (cardH - btnH) / 2
            local isInBatch = isInCurrentBatch(recordingState, "recipe", data.recipeName)

            if isQueued then

                self:drawRect(btnX, btnY, btnW, btnH, 0.5, 0.4, 0.7, 0.7)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.6, 0.5, 0.85, 0.9)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.95, 1, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being processed
                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.45, 0.65, 0.6)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.6, 0.8, 0.8)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
            elseif recordingState and recordingState.active and not recordingState.isRecordAll then

                self:drawRect(btnX, btnY, btnW, btnH, 0.6, 0.35, 0.55, 0.6)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.5, 0.75, 0.8)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
            else

                self:drawRect(btnX, btnY, btnW, btnH, 0.7, 0.3, 0.55, 0.6)
                self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.5, 0.75, 0.8)
                local btnText = getText("UI_BurdJournals_BtnRecord")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, btnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end

    return y + h
end

function BurdJournals.UI.MainPanel:onRecordAll()
    if not self:startRecordingAll() then
        if self.recordingState and self.recordingState.active then
            self:showFeedback(getText("UI_BurdJournals_AlreadyRecording") or "Already recording...", {r=0.9, g=0.7, b=0.3})
        end
    end
end

function BurdJournals.UI.MainPanel:onRecordTab()
    if not self:startRecordingTab(self.currentTab or "skills") then
        if self.recordingState and self.recordingState.active then
            self:showFeedback(getText("UI_BurdJournals_AlreadyRecording") or "Already recording...", {r=0.9, g=0.7, b=0.3})
        end
    end
end

function BurdJournals.UI.MainPanel:createViewUI()

    self:refreshPlayer()

    local padding = 16
    local y = 0
    local btnHeight = 32

    local journalData = BurdJournals.getJournalData(self.journal)

    self.isPlayerJournal = true
    self.isSetMode = true

    self.pendingClaims = self.pendingClaims or {skills = {}, traits = {}}
    self.sessionClaimedSkills = self.sessionClaimedSkills or {}
    self.sessionClaimedTraits = self.sessionClaimedTraits or {}

    local headerHeight = 52
    self.headerRightInset = 0
    local isRestored = BurdJournals.isRestoredJournal(self.journal)
    if isRestored then
        -- Restored journal (converted from worn/bloody blank)
        -- Dissolution controlled by sandbox option, but always displays as "Restored"
        self.headerColor = {r=0.35, g=0.28, b=0.12}
        self.headerAccent = {r=0.55, g=0.45, b=0.2}
        self.typeText = getText("UI_BurdJournals_RestoredJournalHeader")
        self.rarityText = nil
        self.flavorText = getText("UI_BurdJournals_RestoredFlavor")
    else
        -- Clean personal journal (crafted from fresh blank)
        self.headerColor = {r=0.12, g=0.25, b=0.35}
        self.headerAccent = {r=0.2, g=0.45, b=0.55}
        self.typeText = getText("UI_BurdJournals_PersonalJournalHeader")
        self.rarityText = nil
        self.flavorText = getText("UI_BurdJournals_PersonalFlavor")
    end
    self.headerIconTexture = getHeaderJournalIconTexture("view", self.journal, journalData, false)
    self.headerIconSize = 20
    self.headerHeight = headerHeight
    self:createHeaderRefreshButton(10, 15)
    y = headerHeight + 6

    local authorName = journalData and journalData.author or getText("UI_BurdJournals_Unknown")
    self.authorName = authorName
    self.authorBoxY = y
    self.authorBoxHeight = 44
    y = y + self.authorBoxHeight + 10

    local skillCount = 0
    local totalSkillCount = 0
    local traitCount = 0
    local totalTraitCount = 0
    local statCount = 0
    local totalStatCount = 0
    local totalXP = 0

    if journalData and journalData.skills then
        for skillName, skillData in pairs(journalData.skills) do
            if isSkillVisibleForJournal(journalData, skillName) then
                totalSkillCount = totalSkillCount + 1

                local perk = BurdJournals.getPerkByName(skillName)
                local playerXP = 0
                if perk then
                    playerXP = self.player:getXp():getXP(perk)
                end
                local preview = getClaimPreviewForSkill(journalData, self.player, skillName, skillData.xp or 0, 0, getClaimSessionIdForPanel(self, false))
                local claimTargetXP = getClaimTargetXPForPlayer(journalData, self.player, skillName, preview.effectiveXP)
                if playerXP < claimTargetXP then
                    skillCount = skillCount + 1
                    totalXP = totalXP + (claimTargetXP - playerXP)
                end
            end
        end
    end
    if journalData and journalData.traits then
        for traitId, _ in pairs(journalData.traits) do
            totalTraitCount = totalTraitCount + 1
            if not BurdJournals.playerHasTrait(self.player, traitId) then
                traitCount = traitCount + 1
            end
        end
    end
    if journalData and journalData.stats then
        for statId, statData in pairs(journalData.stats) do
            totalStatCount = totalStatCount + 1

            local currentValue = BurdJournals.getStatValue(self.player, statId)
            if currentValue < (statData.value or 0) then
                statCount = statCount + 1
            end
        end
    end

    local recipeCount = 0
    local totalRecipeCount = 0
    if journalData and journalData.recipes then
        for recipeName, _ in pairs(journalData.recipes) do
            totalRecipeCount = totalRecipeCount + 1

            if not BurdJournals.playerKnowsRecipe(self.player, recipeName) then
                recipeCount = recipeCount + 1
            end
        end
    end

    self.skillCount = skillCount
    self.traitCount = traitCount
    self.statCount = statCount
    self.recipeCount = recipeCount
    self.totalXP = totalXP

    local tabs = {{id = "skills", label = getText("UI_BurdJournals_TabSkills")}}
    -- Only show traits tab if enabled and journal has traits
    if totalTraitCount > 0 and BurdJournals.areTraitsEnabledForJournal(journalData) then
        table.insert(tabs, {id = "traits", label = getText("UI_BurdJournals_TabTraits")})
    end
    -- Only show recipes tab if enabled and journal has recipes
    if totalRecipeCount > 0 and BurdJournals.areRecipesEnabledForJournal(journalData) then
        table.insert(tabs, {id = "recipes", label = getText("UI_BurdJournals_TabRecipes")})
    end
    if totalStatCount > 0 then
        table.insert(tabs, {id = "stats", label = getText("UI_BurdJournals_TabStats")})
    end

    local tabThemeColors = {
        active = {r=0.15, g=0.30, b=0.40},
        inactive = {r=0.08, g=0.15, b=0.20},
        accent = {r=0.25, g=0.50, b=0.60}
    }
    self.tabThemeColors = tabThemeColors

    if #tabs > 1 then
        y = self:createTabs(tabs, y, tabThemeColors)
    end

    self.filterBaseY = y
    y = self:createFilterTabBar(y, tabThemeColors)

    local maxItemCount = math.max(totalSkillCount, totalTraitCount, totalRecipeCount, totalStatCount)
    y = self:createSearchBar(y, tabThemeColors, maxItemCount)

    local footerHeight = 85
    local listHeight = self.height - y - footerHeight - padding

    self.skillList = ISScrollingListBox:new(padding, y, self.width - padding * 2, listHeight)
    self.skillList:initialise()
    self.skillList:instantiate()
    self.skillList.drawBorder = false
    self.skillList.backgroundColor = {r=0, g=0, b=0, a=0}
    self.skillList:setFont(UIFont.Small, 2)
    self.skillList.itemheight = 52
    self.skillList.doDrawItem = BurdJournals.UI.MainPanel.doDrawViewItem
    self.skillList.mainPanel = self
    self.listBottomY = self.skillList:getY() + self.skillList:getHeight()

    self.skillList.onMouseUp = function(listbox, x, y)
        if listbox.vscroll then
            listbox.vscroll.scrolling = false
        end
        local row = listbox:rowAt(x, y)
        if row and row >= 1 and row <= #listbox.items then
            local item = listbox.items[row] and listbox.items[row].item
            if item and not item.isHeader and not item.isEmpty then

                local hasEraser = BurdJournals.hasEraser(listbox.mainPanel.player)
                local btnW = 55
                local btnGap = 4
                local margin = 10
                local rightmostBtnStart = listbox:getWidth() - btnW - margin

                local showClaimBtn = false
                if item.isSkill then
                    showClaimBtn = item.canClaim
                elseif item.isTrait then
                    showClaimBtn = not item.alreadyKnown and not item.isClaimed
                elseif item.isRecipe then
                    showClaimBtn = not item.alreadyKnown and not item.isClaimed
                elseif item.isStat then
                    showClaimBtn = item.canClaim and not item.alreadyClaimed
                end

                local claimBtnStart = rightmostBtnStart
                local eraseBtnStart = showClaimBtn and (rightmostBtnStart - btnW - btnGap) or rightmostBtnStart

                if x >= eraseBtnStart then
                    if hasEraser and x >= eraseBtnStart and x < eraseBtnStart + btnW then

                        if item.isSkill then
                            listbox.mainPanel:eraseSkillEntry(item.skillName)
                        elseif item.isTrait then
                            listbox.mainPanel:eraseTraitEntry(item.traitId)
                        elseif item.isRecipe then
                            listbox.mainPanel:eraseRecipeEntry(item.recipeName)
                        elseif item.isStat then
                            listbox.mainPanel:eraseStatEntry(item.statId)
                        end
                    elseif showClaimBtn and x >= claimBtnStart then

                        if item.isSkill and item.canClaim then
                            listbox.mainPanel:claimSkill(item.skillName, item.xp)
                        elseif item.isTrait and not item.alreadyKnown and not item.isClaimed then
                            listbox.mainPanel:claimTrait(item.traitId)
                        elseif item.isRecipe and not item.alreadyKnown and not item.isClaimed then
                            listbox.mainPanel:claimRecipe(item.recipeName)
                        elseif item.isStat and item.canClaim and not item.alreadyClaimed then
                            listbox.mainPanel:claimStat(item.statId, item.recordedValue)
                        end
                    end
                end
            end
        end
        return true
    end
    self:addChild(self.skillList)
    y = y + listHeight

    self.footerY = y + 4
    self.footerHeight = footerHeight

    self.feedbackLabel = ISLabel:new(padding, self.footerY + 4, 18, "", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self:addChild(self.feedbackLabel)
    self.feedbackLabel:setVisible(false)
    self.feedbackTicks = 0

    local tabName = self:getTabDisplayName(self.currentTab or "skills")
    local claimTabText = string.format(getText("UI_BurdJournals_BtnClaimTab") or "Claim %s", tabName)
    local claimAllText = getText("UI_BurdJournals_BtnClaimAll") or "Claim All"
    local closeText = getText("UI_BurdJournals_BtnClose") or "Close"

    local allTabNames = {
        getText("UI_BurdJournals_TabSkills") or "Skills",
        getText("UI_BurdJournals_TabTraits") or "Traits",
        getText("UI_BurdJournals_TabForget") or "Forget",
        getText("UI_BurdJournals_TabRecipes") or "Recipes",
        getText("UI_BurdJournals_TabStats") or "Stats"
    }
    local btnPrefix = getText("UI_BurdJournals_BtnClaimTab") or "Claim %s"
    local maxClaimTabW = 90
    for _, name in ipairs(allTabNames) do
        local text = string.format(btnPrefix, name)
        local w = getTextManager():MeasureStringX(UIFont.Small, text) + 20
        maxClaimTabW = math.max(maxClaimTabW, w)
    end
    local claimAllW = getTextManager():MeasureStringX(UIFont.Small, claimAllText) + 20
    local closeW = getTextManager():MeasureStringX(UIFont.Small, closeText) + 20
    local btnWidth = math.max(90, maxClaimTabW, claimAllW, closeW)

    local btnSpacing = 8
    local totalBtnWidth = btnWidth * 3 + btnSpacing * 2
    local btnStartX = (self.width - totalBtnWidth) / 2
    local btnY = self.footerY + 32

    self.absorbTabBtn = ISButton:new(btnStartX, btnY, btnWidth, btnHeight, claimTabText, self, BurdJournals.UI.MainPanel.onClaimTab)
    self.absorbTabBtn:initialise()
    self.absorbTabBtn:instantiate()
    self.absorbTabBtn.borderColor = {r=0.3, g=0.5, b=0.6, a=1}
    self.absorbTabBtn.backgroundColor = {r=0.12, g=0.22, b=0.28, a=0.8}
    self.absorbTabBtn.textColor = {r=0.9, g=0.95, b=1, a=1}
    self:addChild(self.absorbTabBtn)

    self.absorbAllBtn = ISButton:new(btnStartX + btnWidth + btnSpacing, btnY, btnWidth, btnHeight, claimAllText, self, BurdJournals.UI.MainPanel.onClaimAll)
    self.absorbAllBtn:initialise()
    self.absorbAllBtn:instantiate()
    self.absorbAllBtn.borderColor = {r=0.3, g=0.5, b=0.6, a=1}
    self.absorbAllBtn.backgroundColor = {r=0.15, g=0.28, b=0.35, a=0.8}
    self.absorbAllBtn.textColor = {r=1, g=1, b=1, a=1}
    self:addChild(self.absorbAllBtn)

    self.closeBottomBtn = ISButton:new(btnStartX + (btnWidth + btnSpacing) * 2, btnY, btnWidth, btnHeight, closeText, self, BurdJournals.UI.MainPanel.onClose)
    self.closeBottomBtn:initialise()
    self.closeBottomBtn:instantiate()
    self.closeBottomBtn.borderColor = {r=0.4, g=0.35, b=0.3, a=1}
    self.closeBottomBtn.backgroundColor = {r=0.15, g=0.13, b=0.12, a=0.8}
    self.closeBottomBtn.textColor = {r=0.9, g=0.85, b=0.8, a=1}
    self:addChild(self.closeBottomBtn)

    self:populateViewList()
end

function BurdJournals.UI.MainPanel:populateViewList()
    self.skillList:clear()

    local journalData = BurdJournals.getJournalData(self.journal)
    local currentTab = self.currentTab or "skills"

    if not self.pendingClaims then self.pendingClaims = {skills = {}, traits = {}} end

    if currentTab == "skills" then

        if journalData and journalData.skills then
            local hasSkills = false
            local matchCount = 0
            for skillName, skillData in pairs(journalData.skills) do
                if isSkillVisibleForJournal(journalData, skillName) then
                    hasSkills = true
                    local displayName = BurdJournals.getPerkDisplayName(skillName)
                    local modSource = BurdJournals.getSkillModId(skillName)

                if self:matchesSearch(displayName) and self:passesFilter(modSource) then
                    matchCount = matchCount + 1
                    local perk = BurdJournals.getPerkByName(skillName)
                    local playerXP = 0
                    local playerLevel = 0
                    if perk then
                        playerXP = self.player:getXp():getXP(perk)
                        playerLevel = self.player:getPerkLevel(perk)
                    end

                        local recordedXP = skillData.xp or 0
                        local _, recordedRawXP, recordedVhsExcludedXP = getSkillVhsBreakdown(skillData, recordedXP)
                        local preview = getClaimPreviewForSkill(journalData, self.player, skillName, recordedXP, 0, getClaimSessionIdForPanel(self, false))
                        local effectiveClaimXP = preview.effectiveXP
                        local claimTargetXP = getClaimTargetXPForPlayer(journalData, self.player, skillName, effectiveClaimXP)
                        local recordedLevel = skillData.level or 0
                        if preview.level and preview.level > 0 then
                            recordedLevel = preview.level
                        elseif recordedLevel == 0 and recordedXP > 0 and BurdJournals.getSkillLevelFromXP then
                            local xpForLevelCalc = getXPWithBaselineForDisplay(skillName, recordedXP, journalData, self.player)
                            recordedLevel = BurdJournals.getSkillLevelFromXP(xpForLevelCalc, skillName)
                        end

                        local isPending = self.pendingClaims.skills[skillName]
                        local isClaimed = BurdJournals.hasCharacterClaimedSkill(journalData, self.player, skillName)

                        -- Check if already claimed this session (before XP sync might have arrived)
                        local claimedThisSession = self.sessionClaimedSkills and self.sessionClaimedSkills[skillName]

                        -- Track if player already has sufficient skill level/XP
                        -- Player can claim if:
                        -- 1. Player level < recorded level, OR
                        -- 2. Player level == recorded level BUT player XP < recorded XP (journal has more XP at same level)
                        -- This allows claiming journals at level 0 with extra XP when player has 0 XP
                        local alreadyAtLevel = claimedThisSession or (playerXP >= claimTargetXP)

                        -- Clear pending if player has sufficient level or claimed this session
                        if isPending and (alreadyAtLevel or isClaimed) then
                            self.pendingClaims.skills[skillName] = nil
                            isPending = false
                        end

                        -- Clear session claim tracking once XP sync confirms player has sufficient XP
                        if claimedThisSession and playerXP >= claimTargetXP then
                            self.sessionClaimedSkills[skillName] = nil
                        end

                        -- For player journals, can claim if player's level is less than recorded
                        -- This allows re-claiming if a previous claim failed or gave insufficient XP
                        local canClaim = not alreadyAtLevel and not isPending and not isClaimed
                        local skillTooltip = buildSkillVhsTooltip({
                            xp = recordedXP,
                            rawXP = recordedRawXP,
                            vhsExcludedXP = recordedVhsExcludedXP
                        }, effectiveClaimXP, preview.percent)

                        self.skillList:addItem(skillName, {
                            isSkill = true,
                            skillName = skillName,
                            displayName = displayName,
                            xp = recordedXP,
                            rawXP = recordedRawXP,
                            vhsExcludedXP = recordedVhsExcludedXP,
                            effectiveXP = effectiveClaimXP,
                            claimMultiplier = preview.multiplier,
                            claimPercent = preview.percent,
                        claimReadCount = preview.readCount,
                        level = recordedLevel,
                        playerXP = playerXP,
                        playerLevel = playerLevel,
                        canClaim = canClaim,
                            isClaimed = isClaimed,
                            isPending = isPending,
                            alreadyAtLevel = alreadyAtLevel,
                            modSource = modSource,
                        }, skillTooltip)
                    end
                end
            end
            if not hasSkills then
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSkillsRecorded")})
            elseif matchCount == 0 then
                self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoSkillsRecorded")})
        end

    elseif currentTab == "traits" then
        if journalData and journalData.traits and BurdJournals.countTable(journalData.traits) > 0 then
            local hasTraits = false
            local matchCount = 0
            for traitId, traitData in pairs(journalData.traits) do
                hasTraits = true
                local traitName = safeGetTraitName(traitId)
                local modSource = BurdJournals.getTraitModId(traitId)

                if self:matchesSearch(traitName) and self:passesFilter(modSource) then
                    matchCount = matchCount + 1
                    local traitTexture = getTraitTexture(traitId)
                    local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(traitId) or traitId
                    local traitSessionKey = string.lower(tostring(normalizedTraitId or traitId))
                    local alreadyKnownActual = BurdJournals.playerHasTrait(self.player, traitId)
                    local claimedThisSession = self.sessionClaimedTraits and (self.sessionClaimedTraits[traitId] or self.sessionClaimedTraits[traitSessionKey])
                    local alreadyKnown = alreadyKnownActual or claimedThisSession
                    local isClaimed = BurdJournals.hasCharacterClaimedTrait(journalData, self.player, traitId)
                    local isPending = self.pendingClaims.traits[traitId] or self.pendingClaims.traits[traitSessionKey]
                    local isPositive = isTraitPositive(traitId)

                    -- Clear pending if claimed OR already known
                    if isPending and (isClaimed or alreadyKnown) then
                        self.pendingClaims.traits[traitId] = nil
                        self.pendingClaims.traits[traitSessionKey] = nil
                        isPending = false
                    end
                    if claimedThisSession and alreadyKnownActual and self.sessionClaimedTraits then
                        self.sessionClaimedTraits[traitId] = nil
                        self.sessionClaimedTraits[traitSessionKey] = nil
                    end

                    self.skillList:addItem(traitId, {
                        isTrait = true,
                        traitId = traitId,
                        traitName = traitName,
                        traitTexture = traitTexture,
                        alreadyKnown = alreadyKnown,
                        isClaimed = isClaimed,
                        isPending = isPending,
                        isPositive = isPositive,
                        modSource = modSource,
                    })
                end
            end
            if not hasTraits then
                self.skillList:addItem("empty", {isEmpty = true, text = "No traits recorded"})
            elseif matchCount == 0 then
                self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = "No traits recorded"})
        end

    elseif currentTab == "recipes" then
        if journalData and journalData.recipes and BurdJournals.countTable(journalData.recipes) > 0 then
            local hasRecipes = false
            local matchCount = 0
            for recipeName, recipeData in pairs(journalData.recipes) do
                hasRecipes = true
                local displayName = BurdJournals.getRecipeDisplayName(recipeName)
                local magazineSource = (type(recipeData) == "table" and recipeData.source) or BurdJournals.getMagazineForRecipe(recipeName)
                local modSource = BurdJournals.getRecipeModId(recipeName, magazineSource)

                if self:matchesSearch(displayName) and self:passesFilter(modSource) then
                    matchCount = matchCount + 1
                    local alreadyKnown = BurdJournals.playerKnowsRecipe(self.player, recipeName)
                    local isClaimed = BurdJournals.hasCharacterClaimedRecipe(journalData, self.player, recipeName)
                    local isPending = self.pendingClaims.recipes and self.pendingClaims.recipes[recipeName]

                    -- Clear pending if claimed OR already known (claimed takes priority since server confirmed it)
                    if isPending and (isClaimed or alreadyKnown) then
                        if self.pendingClaims.recipes then
                            self.pendingClaims.recipes[recipeName] = nil
                        end
                        isPending = false
                    end

                    self.skillList:addItem(recipeName, {
                        isRecipe = true,
                        recipeName = recipeName,
                        displayName = displayName,
                        magazineSource = magazineSource,
                        alreadyKnown = alreadyKnown,
                        isClaimed = isClaimed,
                        isPending = isPending,
                        modSource = modSource,
                    })
                end
            end
            if not hasRecipes then
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoRecipesRecorded")})
            elseif matchCount == 0 then
                self.skillList:addItem("no_results", {isEmpty = true, text = getText("UI_BurdJournals_NoSearchResults") or "No results found"})
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoRecipesRecorded")})
        end

    elseif currentTab == "stats" then
        if journalData and journalData.stats and BurdJournals.countTable(journalData.stats) > 0 then
            local hasStats = false
            local matchCount = 0
            for statId, statData in pairs(journalData.stats) do
                hasStats = true
                local stat = BurdJournals.getStatById(statId)
                local statName = stat and BurdJournals.getStatName(stat) or statId

                if self:matchesSearch(statName) then
                    matchCount = matchCount + 1
                    local currentValue = BurdJournals.getStatValue(self.player, statId)
                    -- Stats are stored as tables with {value = X, timestamp = Y, recordedBy = Z}
                    local recordedValue = type(statData) == "table" and statData.value or statData
                    if type(recordedValue) ~= "number" then recordedValue = 0 end
                    local currentFormatted = BurdJournals.formatStatValue(statId, currentValue)
                    local recordedFormatted = BurdJournals.formatStatValue(statId, recordedValue)

                    -- Check if this stat can be absorbed (only for worn/bloody journals)
                    local canClaim, recVal, curVal, claimReason = false, nil, nil, nil
                    if BurdJournals.canAbsorbStat then
                        canClaim, recVal, curVal, claimReason = BurdJournals.canAbsorbStat(journalData, self.player, statId)
                    end
                    local isAbsorbable = BurdJournals.ABSORBABLE_STATS and BurdJournals.ABSORBABLE_STATS[statId] ~= nil

                    self.skillList:addItem(statId, {
                        isStat = true,
                        statId = statId,
                        statName = statName,
                        currentValue = currentValue,
                        recordedValue = recordedValue,
                        currentFormatted = currentFormatted,
                        recordedFormatted = recordedFormatted,
                        canClaim = canClaim,
                        isAbsorbable = isAbsorbable,
                        claimReason = claimReason,
                    })
                end
            end
            if not hasStats then
                self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoStatsRecorded") or "No stats recorded"})
            end
        else
            self.skillList:addItem("empty", {isEmpty = true, text = getText("UI_BurdJournals_NoStatsRecorded") or "No stats recorded"})
        end
    end
end

-- Helper function for drawing skill items in view mode (extracted to reduce local count)
local function doDrawViewSkillItem(self, mainPanel, data, textX, textColor, cardX, cardY, cardW, cardH, padding)
    local learningState = mainPanel.learningState
    local viewJournalData = (mainPanel.journal and BurdJournals.getJournalData and BurdJournals.getJournalData(mainPanel.journal)) or nil
    local isLearningThis = learningState and learningState.active and not learningState.isAbsorbAll
                          and learningState.skillName == data.skillName
    local erasingState = mainPanel.erasingState
    local isErasingThis = erasingState and erasingState.active
                          and erasingState.entryType == "skill" and erasingState.entryName == data.skillName
    local displayName = data.displayName or data.skillName or "Unknown Skill"
    self:drawText(displayName, textX, cardY + 6, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)
    local queuePosition = mainPanel:getQueuePosition(data.skillName)
    local isQueued = queuePosition ~= nil

    if isErasingThis then
        local progressFormat = getText("UI_BurdJournals_ErasingProgress") or "Erasing... %d%%"
        local progressText = string.format(progressFormat, math.floor((erasingState.progress or 0) * 100))
        self:drawText(progressText, textX, cardY + 24, 0.9, 0.5, 0.5, 1, UIFont.Small)
        local barX, barY, barW, barH = textX + 90, cardY + 27, cardW - 120 - padding, 10
        self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)
        self:drawRect(barX, barY, barW * (erasingState.progress or 0), barH, 0.9, 0.7, 0.3, 0.3)
        self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.6, 0.3, 0.3)
    elseif isLearningThis then
        local progressFormat = getText("UI_BurdJournals_ReadingProgress") or "Reading... %d%%"
        local progressText = string.format(progressFormat, math.floor(learningState.progress * 100))
        self:drawText(progressText, textX, cardY + 24, 0.3, 0.7, 0.9, 1, UIFont.Small)
        local barX, barY, barW, barH = textX + 90, cardY + 27, cardW - 120 - padding, 10
        self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)
        self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.3, 0.6, 0.8)
        self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.4, 0.6, 0.8)
    elseif isQueued then
        local squaresX, squaresY, squareSize, squareSpacing = textX, cardY + 26, 10, 2
        local displayXP = data.effectiveXP or data.xp or 0
        -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
        -- Use stored level as override for accurate display (important for passive skills)
        local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, displayXP, viewJournalData, mainPanel.player)
        local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)
        drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
            {r=0.4, g=0.5, b=0.6}, {r=0.12, g=0.12, b=0.12}, {r=0.25, g=0.3, b=0.4})
        local squaresWidth = 10 * squareSize + 9 * squareSpacing
        local queuedText = string.format(getText("UI_BurdJournals_QueuedNumber") or "Queued #%d", queuePosition)
        local sourceXP = math.max(0, tonumber(data.xp) or displayXP)
        local _, rawSourceXP, vhsExcludedXP = getSkillVhsBreakdown(data, sourceXP)
        local xpText = queuedText .. "  " .. BurdJournals.formatXP(displayXP) .. " XP"
        if data.claimPercent and data.claimPercent < 100 and sourceXP > 0 then
            local reducedXP = math.max(0, sourceXP - displayXP)
            xpText = queuedText .. "  " .. BurdJournals.formatXP(displayXP) .. "/" .. BurdJournals.formatXP(sourceXP) .. " XP (" .. tostring(data.claimPercent) .. "%, -" .. BurdJournals.formatXP(reducedXP) .. ")"
            if vhsExcludedXP > 0 and rawSourceXP > sourceXP then
                xpText = xpText .. " | VHS -" .. BurdJournals.formatXP(vhsExcludedXP)
            end
        else
            xpText = queuedText .. "  " .. formatXPWithVhsBreakdown(displayXP, rawSourceXP, vhsExcludedXP)
        end
        self:drawText(xpText, squaresX + squaresWidth + 8, squaresY, 0.6, 0.75, 0.9, 1, UIFont.Small)
    elseif data.canClaim then
        local squaresX, squaresY, squareSize, squareSpacing = textX, cardY + 26, 10, 2
        local displayXP = data.effectiveXP or data.xp or 0
        -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
        -- Use stored level as override for accurate display (important for passive skills)
        local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, displayXP, viewJournalData, mainPanel.player)
        local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)
        drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
            {r=0.3, g=0.55, b=0.65}, {r=0.12, g=0.12, b=0.12}, {r=0.2, g=0.35, b=0.4})
        local squaresWidth = 10 * squareSize + 9 * squareSpacing
        local sourceXP = math.max(0, tonumber(data.xp) or displayXP)
        local _, rawSourceXP, vhsExcludedXP = getSkillVhsBreakdown(data, sourceXP)
        local xpText = formatXPWithVhsBreakdown(displayXP, rawSourceXP, vhsExcludedXP)
        if data.claimPercent and data.claimPercent < 100 and sourceXP > 0 then
            local reducedXP = math.max(0, sourceXP - displayXP)
            xpText = BurdJournals.formatXP(displayXP) .. "/" .. BurdJournals.formatXP(sourceXP) .. " XP (" .. tostring(data.claimPercent) .. "%, -" .. BurdJournals.formatXP(reducedXP) .. ")"
            if vhsExcludedXP > 0 and rawSourceXP > sourceXP then
                xpText = xpText .. " | VHS -" .. BurdJournals.formatXP(vhsExcludedXP)
            end
        end
        self:drawText(xpText, squaresX + squaresWidth + 8, squaresY, 0.5, 0.75, 0.7, 1, UIFont.Small)
    else
        local squaresX, squaresY, squareSize, squareSpacing = textX, cardY + 26, 10, 2
        local displayXP = data.effectiveXP or data.xp or 0
        -- For passive skills (Fitness/Strength), add baseline XP for accurate level display
        -- Use stored level as override for accurate display (important for passive skills)
        local xpForDisplay = getXPWithBaselineForDisplay(data.skillName, displayXP, viewJournalData, mainPanel.player)
        local level, progress = calculateLevelProgressWithOverride(data.skillName, xpForDisplay, data.level)
        drawLevelSquares(self, squaresX, squaresY, level, progress, squareSize, squareSpacing,
            {r=0.25, g=0.3, b=0.3}, {r=0.1, g=0.1, b=0.1}, {r=0.18, g=0.22, b=0.22})
        local squaresWidth = 10 * squareSize + 9 * squareSpacing
        -- Show appropriate status: "Already at this level" if they have sufficient XP
        local statusText = data.alreadyAtLevel 
            and (getText("UI_BurdJournals_StatusAlreadyAtLevel") or "Already at this level")
            or (getText("UI_BurdJournals_StatusAlreadyClaimed") or "Already claimed")
        self:drawText(statusText, squaresX + squaresWidth + 8, squaresY, 0.4, 0.45, 0.45, 1, UIFont.Small)
    end

    local btnW, btnH, btnGap = 55, 24, 4
    local hasEraser = BurdJournals.hasEraser(mainPanel.player)
    local rightmostBtnX = cardX + cardW - btnW - 10
    local btnY = cardY + (cardH - btnH) / 2
    local showClaimBtn = data.canClaim and not isLearningThis
    local eraseBtnX = showClaimBtn and (rightmostBtnX - btnW - btnGap) or rightmostBtnX

    -- Check if this item is in erase queue
    local eraseQueuePos = mainPanel:getEraseQueuePosition(data.skillName)
    local isEraseQueued = eraseQueuePos ~= nil

    if hasEraser and not isErasingThis then
        if isEraseQueued then
            -- Show queued state with position number
            self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.25, 0.25)
            self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.6, 0.6, 0.35, 0.35)
            local queueText = "#" .. eraseQueuePos
            local queueTextW = getTextManager():MeasureStringX(UIFont.Small, queueText)
            self:drawText(queueText, eraseBtnX + (btnW - queueTextW) / 2, btnY + 4, 0.9, 0.7, 0.5, 1, UIFont.Small)
        else
            self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.7, 0.5, 0.15, 0.15)
            self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.8, 0.7, 0.25, 0.25)
            local eraseText = getText("UI_BurdJournals_BtnErase") or "Erase"
            local eraseTextW = getTextManager():MeasureStringX(UIFont.Small, eraseText)
            self:drawText(eraseText, eraseBtnX + (btnW - eraseTextW) / 2, btnY + 4, 1, 0.9, 0.9, 1, UIFont.Small)
        end
    end

    if showClaimBtn then
        local mainBtnX = rightmostBtnX
        local isInBatch = isInCurrentAbsorbBatch(learningState, "skill", data.skillName)
        if isQueued then
            self:drawRect(mainBtnX, btnY, btnW, btnH, 0.5, 0.3, 0.4, 0.5)
            self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.6, 0.4, 0.5, 0.6)
            local btnText = "#" .. queuePosition
            local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
            self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.8, 0.9, 1, 1, UIFont.Small)
        elseif isInBatch then
            self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.45, 0.55, 0.45)
            self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.6, 0.7, 0.6)
            local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
            local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
            self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
        elseif learningState and learningState.active and not learningState.isAbsorbAll then
            self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.25, 0.35, 0.5)
            self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.4, 0.55, 0.7)
            local btnText = getText("UI_BurdJournals_BtnQueue")
            local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
            self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.95, 1, 1, UIFont.Small)
        else
            self:drawRect(mainBtnX, btnY, btnW, btnH, 0.7, 0.2, 0.4, 0.5)
            self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.3, 0.55, 0.65)
            local btnText = getText("UI_BurdJournals_BtnClaim")
            local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
            self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
        end
    end
end

function BurdJournals.UI.MainPanel.doDrawViewItem(self, y, item, alt)
    local mainPanel = self.mainPanel
    if not mainPanel then return y + self.itemheight end

    local data = item.item or {}
    local x = 0

    local scrollBarWidth = 13
    local w = self:getWidth() - scrollBarWidth
    local h = self.itemheight
    local padding = 12

    local cardBg = {r=0.12, g=0.16, b=0.20}
    local cardBorder = {r=0.25, g=0.38, b=0.45}
    local accentColor = {r=0.3, g=0.55, b=0.65}

    if data.isHeader then
        self:drawRect(x, y + 2, w, h - 4, 0.4, 0.12, 0.18, 0.22)
        self:drawText(data.text or getText("UI_BurdJournals_Skills") or "SKILLS", x + padding, y + (h - 18) / 2, 0.7, 0.9, 1.0, 1, UIFont.Medium)
        if data.count then
            local countText = string.format(getText("UI_BurdJournals_Claimable") or "(%d claimable)", data.count)
            local countWidth = getTextManager():MeasureStringX(UIFont.Small, countText)
            self:drawText(countText, w - padding - countWidth, y + (h - 14) / 2, 0.4, 0.6, 0.7, 1, UIFont.Small)
        end
        return y + h
    end

    if data.isEmpty then
        self:drawText(data.text or getText("UI_BurdJournals_NoContent") or "No content", x + padding, y + (h - 14) / 2, 0.4, 0.5, 0.55, 1, UIFont.Small)
        return y + h
    end

    local cardMargin = 4
    local cardX = x + cardMargin
    local cardY = y + cardMargin
    local cardW = w - cardMargin * 2
    local cardH = h - cardMargin * 2

    local canInteract = (data.isSkill and data.canClaim) or (data.isTrait and not data.alreadyKnown and not data.isClaimed and not data.isPending)

    local bgColor = cardBg
    local borderColor = cardBorder
    local accent = accentColor
    if data.isTrait then
        if data.isPositive == true then

            bgColor = {r=0.08, g=0.20, b=0.10}
            borderColor = {r=0.2, g=0.5, b=0.25}
            accent = {r=0.3, g=0.8, b=0.35}
        elseif data.isPositive == false then

            bgColor = {r=0.22, g=0.08, b=0.08}
            borderColor = {r=0.5, g=0.2, b=0.2}
            accent = {r=0.8, g=0.3, b=0.3}
        end

    end

    if not canInteract then
        self:drawRect(cardX, cardY, cardW, cardH, 0.4, 0.12, 0.12, 0.12)
    else
        self:drawRect(cardX, cardY, cardW, cardH, 0.7, bgColor.r, bgColor.g, bgColor.b)
    end

    self:drawRectBorder(cardX, cardY, cardW, cardH, 0.6, borderColor.r, borderColor.g, borderColor.b)

    if canInteract then
        self:drawRect(cardX, cardY, 4, cardH, 0.9, accent.r, accent.g, accent.b)
    else
        self:drawRect(cardX, cardY, 4, cardH, 0.5, 0.3, 0.3, 0.3)
    end

    local textX = cardX + padding + 4
    local textColor = canInteract and {r=0.95, g=0.95, b=1.0} or {r=0.5, g=0.5, b=0.5}

    if data.isSkill then
        doDrawViewSkillItem(self, mainPanel, data, textX, textColor, cardX, cardY, cardW, cardH, padding)
    end

    if data.isTrait then
        local learningState = mainPanel.learningState
        local isLearningThis = learningState and learningState.active and not learningState.isAbsorbAll
                              and learningState.traitId == data.traitId

        local erasingState = mainPanel.erasingState
        local isErasingThis = erasingState and erasingState.active
                              and erasingState.entryType == "trait" and erasingState.entryName == data.traitId

        local traitName = data.traitName or data.traitId or getText("UI_BurdJournals_UnknownTrait") or "Unknown Trait"
        local traitTextX = textX

        if data.traitTexture then
            local iconSize = 24
            local iconX = textX
            local iconY = cardY + (cardH - iconSize) / 2
            local iconAlpha = data.alreadyKnown and 0.4 or 1.0
            self:drawTextureScaledAspect(data.traitTexture, iconX, iconY, iconSize, iconSize, iconAlpha, 1, 1, 1)
            traitTextX = textX + iconSize + 6
        end

        local queuePosition = mainPanel:getQueuePosition(data.traitId)
        local isQueued = queuePosition ~= nil

        local traitColor
        if data.alreadyKnown then
            traitColor = {r=0.5, g=0.5, b=0.5}
        elseif data.isPositive == true then
            traitColor = {r=0.5, g=0.9, b=0.5}
        elseif data.isPositive == false then
            traitColor = {r=0.9, g=0.5, b=0.5}
        else
            traitColor = {r=0.8, g=0.9, b=1.0}
        end
        self:drawText(traitName, traitTextX, cardY + 6, traitColor.r, traitColor.g, traitColor.b, 1, UIFont.Small)

        if isErasingThis then

            local progressFormat = getText("UI_BurdJournals_ErasingProgress") or "Erasing... %d%%"
            local progressText = string.format(progressFormat, math.floor((erasingState.progress or 0) * 100))
            self:drawText(progressText, traitTextX, cardY + 22, 0.9, 0.5, 0.5, 1, UIFont.Small)

            local barX = traitTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * (erasingState.progress or 0), barH, 0.9, 0.7, 0.3, 0.3)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.6, 0.3, 0.3)
        elseif isLearningThis then
            local progressText = string.format("Learning... %d%%", math.floor(learningState.progress * 100))
            self:drawText(progressText, traitTextX, cardY + 22, 0.3, 0.7, 0.9, 1, UIFont.Small)

            local barX = traitTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.25, 0.5, 0.7)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.35, 0.6, 0.8)
        elseif isQueued then
            local queuedText = string.format(getText("UI_BurdJournals_QueuedNumber") or "Queued #%d", queuePosition)
            self:drawText(queuedText, traitTextX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)
        elseif data.alreadyKnown then
            self:drawText(getText("UI_BurdJournals_StatusAlreadyKnown") or "Already known", traitTextX, cardY + 22, 0.4, 0.45, 0.45, 1, UIFont.Small)
        elseif data.isClaimed then
            -- Trait was claimed from this journal by this character
            self:drawText(getText("UI_BurdJournals_StatusAlreadyClaimed") or "Already claimed", traitTextX, cardY + 22, 0.4, 0.45, 0.45, 1, UIFont.Small)
        else
            self:drawText(getText("UI_BurdJournals_RecordedTrait") or "Recorded trait", traitTextX, cardY + 22, 0.5, 0.7, 0.8, 1, UIFont.Small)
        end

        local btnW = 55
        local btnH = 24
        local btnGap = 4
        local hasEraser = BurdJournals.hasEraser(mainPanel.player)

        local rightmostBtnX = cardX + cardW - btnW - 10
        local btnY = cardY + (cardH - btnH) / 2

        -- Check if trait can be claimed (not already known, not already claimed, not pending)
        local canClaimTrait = not data.alreadyKnown and not data.isClaimed and not data.isPending
        local showClaimBtn = canClaimTrait and not isLearningThis

        local eraseBtnX = showClaimBtn and (rightmostBtnX - btnW - btnGap) or rightmostBtnX

        -- Check if this trait is in erase queue
        local eraseQueuePos = mainPanel:getEraseQueuePosition(data.traitId)
        local isEraseQueued = eraseQueuePos ~= nil

        if hasEraser and not isErasingThis then
            if isEraseQueued then
                -- Show queued state with position number
                self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.25, 0.25)
                self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.6, 0.6, 0.35, 0.35)
                local queueText = "#" .. eraseQueuePos
                local queueTextW = getTextManager():MeasureStringX(UIFont.Small, queueText)
                self:drawText(queueText, eraseBtnX + (btnW - queueTextW) / 2, btnY + 4, 0.9, 0.7, 0.5, 1, UIFont.Small)
            else
                self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.7, 0.5, 0.15, 0.15)
                self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.8, 0.7, 0.25, 0.25)
                local eraseText = getText("UI_BurdJournals_BtnErase") or "Erase"
                local eraseTextW = getTextManager():MeasureStringX(UIFont.Small, eraseText)
                self:drawText(eraseText, eraseBtnX + (btnW - eraseTextW) / 2, btnY + 4, 1, 0.9, 0.9, 1, UIFont.Small)
            end
        end

        if showClaimBtn then
            local mainBtnX = rightmostBtnX
            local isInBatch = isInCurrentAbsorbBatch(learningState, "trait", data.traitId)

            if isQueued then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.35, 0.5)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.6, 0.5, 0.45, 0.6)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 0.85, 0.7, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being claimed
                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.5, 0.45, 0.45)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.65, 0.55, 0.6)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.85, 1, UIFont.Small)
            elseif learningState and learningState.active and not learningState.isAbsorbAll then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.35, 0.4, 0.5)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.5, 0.55, 0.65)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 0.95, 0.9, 1, UIFont.Small)
            else
                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.7, 0.35, 0.45, 0.55)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.5, 0.6, 0.7)
                local btnText = getText("UI_BurdJournals_BtnClaim")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 1, 1, 1, 1, UIFont.Small)
            end
        end
    end

    if data.isRecipe then
        local learningState = mainPanel.learningState
        local isLearningThis = learningState and learningState.active and not learningState.isAbsorbAll
                              and learningState.recipeName == data.recipeName

        local erasingState = mainPanel.erasingState
        local isErasingThis = erasingState and erasingState.active
                              and erasingState.entryType == "recipe" and erasingState.entryName == data.recipeName

        local recipeName = data.displayName or data.recipeName or "Unknown Recipe"
        local recipeTextX = textX

        local magazineTexture = getMagazineTexture(data.magazineSource)

        if magazineTexture then
            local iconSize = 24
            local iconX = textX
            local iconY = cardY + (cardH - iconSize) / 2
            local iconAlpha = (data.alreadyKnown or data.isClaimed) and 0.4 or 1.0
            self:drawTextureScaledAspect(magazineTexture, iconX, iconY, iconSize, iconSize, iconAlpha, 1, 1, 1)
            recipeTextX = textX + iconSize + 6
        end

        local queuePosition = mainPanel:getQueuePosition(data.recipeName)
        local isQueued = queuePosition ~= nil

        local recipeColor
        if data.alreadyKnown or data.isClaimed then
            recipeColor = {r=0.5, g=0.5, b=0.5}
        else
            recipeColor = {r=0.5, g=0.9, b=0.95}
        end
        self:drawText(recipeName, recipeTextX, cardY + 6, recipeColor.r, recipeColor.g, recipeColor.b, 1, UIFont.Small)

        if isErasingThis then

            local progressFormat = getText("UI_BurdJournals_ErasingProgress") or "Erasing... %d%%"
            local progressText = string.format(progressFormat, math.floor((erasingState.progress or 0) * 100))
            self:drawText(progressText, recipeTextX, cardY + 22, 0.9, 0.5, 0.5, 1, UIFont.Small)

            local barX = recipeTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * (erasingState.progress or 0), barH, 0.9, 0.7, 0.3, 0.3)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.6, 0.3, 0.3)
        elseif isLearningThis then
            local progressText = string.format("Learning... %d%%", math.floor(learningState.progress * 100))
            self:drawText(progressText, recipeTextX, cardY + 22, 0.3, 0.8, 0.85, 1, UIFont.Small)

            local barX = recipeTextX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)

            self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.25, 0.65, 0.75)

            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.35, 0.75, 0.85)
        elseif isQueued then
            local queuedText = string.format(getText("UI_BurdJournals_QueuedNumber") or "Queued #%d", queuePosition)
            self:drawText(queuedText, recipeTextX, cardY + 22, 0.5, 0.8, 0.9, 1, UIFont.Small)
        elseif data.alreadyKnown then
            self:drawText(getText("UI_BurdJournals_RecipeAlreadyKnown") or "Already known", recipeTextX, cardY + 22, 0.4, 0.45, 0.45, 1, UIFont.Small)
        elseif data.isClaimed then
            -- Recipe was claimed from this journal by this character
            self:drawText(getText("UI_BurdJournals_StatusAlreadyClaimed") or "Already claimed", recipeTextX, cardY + 22, 0.4, 0.45, 0.45, 1, UIFont.Small)
        else

            local sourceText = getText("UI_BurdJournals_RecordedRecipe") or "Recorded recipe"
            if data.magazineSource then
                local magazineName = BurdJournals.getMagazineDisplayName(data.magazineSource)
                sourceText = string.format(getText("UI_BurdJournals_RecipeFromMagazine") or "From: %s", magazineName)
            end
            self:drawText(sourceText, recipeTextX, cardY + 22, 0.4, 0.65, 0.7, 1, UIFont.Small)
        end

        local btnW = 55
        local btnH = 24
        local btnGap = 4
        local hasEraser = BurdJournals.hasEraser(mainPanel.player)

        local rightmostBtnX = cardX + cardW - btnW - 10
        local btnY = cardY + (cardH - btnH) / 2

        -- Check if recipe can be claimed (not already known, not already claimed, not pending)
        local canClaimRecipe = not data.alreadyKnown and not data.isClaimed and not data.isPending
        local showClaimBtn = canClaimRecipe and not isLearningThis

        local eraseBtnX = showClaimBtn and (rightmostBtnX - btnW - btnGap) or rightmostBtnX

        -- Check if this recipe is in erase queue
        local eraseQueuePos = mainPanel:getEraseQueuePosition(data.recipeName)
        local isEraseQueued = eraseQueuePos ~= nil

        if hasEraser and not isErasingThis then
            if isEraseQueued then
                -- Show queued state with position number
                self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.25, 0.25)
                self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.6, 0.6, 0.35, 0.35)
                local queueText = "#" .. eraseQueuePos
                local queueTextW = getTextManager():MeasureStringX(UIFont.Small, queueText)
                self:drawText(queueText, eraseBtnX + (btnW - queueTextW) / 2, btnY + 4, 0.9, 0.7, 0.5, 1, UIFont.Small)
            else
                self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.7, 0.5, 0.15, 0.15)
                self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.8, 0.7, 0.25, 0.25)
                local eraseText = getText("UI_BurdJournals_BtnErase") or "Erase"
                local eraseTextW = getTextManager():MeasureStringX(UIFont.Small, eraseText)
                self:drawText(eraseText, eraseBtnX + (btnW - eraseTextW) / 2, btnY + 4, 1, 0.9, 0.9, 1, UIFont.Small)
            end
        end

        if showClaimBtn then
            local mainBtnX = rightmostBtnX
            local isInBatch = isInCurrentAbsorbBatch(learningState, "recipe", data.recipeName)

            if isQueued then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.5, 0.3, 0.5, 0.55)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.6, 0.4, 0.6, 0.7)
                local btnText = "#" .. queuePosition
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.8, 0.95, 1, 1, UIFont.Small)
            elseif isInBatch then
                -- Item is part of current batch being claimed
                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.45, 0.55, 0.5)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.55, 0.7, 0.7)
                local btnText = getText("UI_BurdJournals_BtnBatching") or "BATCH"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.95, 1, 0.95, 1, UIFont.Small)
            elseif learningState and learningState.active and not learningState.isAbsorbAll then

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.6, 0.25, 0.45, 0.55)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.35, 0.6, 0.7)
                local btnText = getText("UI_BurdJournals_BtnQueue")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 1, 1, 1, UIFont.Small)
            else

                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.7, 0.2, 0.45, 0.55)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.8, 0.3, 0.6, 0.7)
                local btnText = getText("UI_BurdJournals_BtnClaim")
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 1, 1, 1, UIFont.Small)
            end
        end
    end

    if data.isStat then
        local learningState = mainPanel.learningState
        -- Check if currently learning this stat
        local isLearningThis = learningState and learningState.active and not learningState.isAbsorbAll
                              and learningState.statId == data.statId

        local queuePosition = mainPanel:getQueuePosition(data.statId)
        local isQueued = queuePosition ~= nil

        local statName = data.statName or data.statId or "Unknown Stat"
        self:drawText(statName, textX, cardY + 6, textColor.r, textColor.g, textColor.b, 1, UIFont.Small)

        if isLearningThis then
            -- Show progress bar while learning
            local progressText = string.format(getText("UI_BurdJournals_AbsorbingProgress") or "Absorbing... %d%%", math.floor(learningState.progress * 100))
            self:drawText(progressText, textX, cardY + 22, 0.3, 0.8, 0.7, 1, UIFont.Small)

            local barX = textX + 100
            local barY = cardY + 25
            local barW = cardW - barX - 20
            local barH = 10

            self:drawRect(barX, barY, barW, barH, 0.6, 0.1, 0.1, 0.1)
            self:drawRect(barX, barY, barW * learningState.progress, barH, 0.9, 0.2, 0.7, 0.6)
            self:drawRectBorder(barX, barY, barW, barH, 0.7, 0.4, 0.8, 0.7)
        elseif isQueued then
            -- Show queued status
            local queuedText = string.format(getText("UI_BurdJournals_QueuedPosition") or "Queued #%d", queuePosition)
            self:drawText(queuedText, textX, cardY + 22, 0.6, 0.75, 0.9, 1, UIFont.Small)
        elseif data.claimReason == "already_claimed" then
            -- Already claimed this stat
            local claimedText = getText("UI_BurdJournals_StatusAlreadyClaimed") or "Already claimed"
            self:drawText(claimedText, textX, cardY + 22, 0.5, 0.5, 0.5, 1, UIFont.Small)
        elseif data.claimReason == "not_absorbable" or not data.isAbsorbable then
            -- Stat cannot be absorbed (like hours survived in production)
            local recordedText = string.format(getText("UI_BurdJournals_RecordedValue") or "Recorded: %s", data.recordedFormatted or "?")
            self:drawText(recordedText, textX, cardY + 22, 0.5, 0.5, 0.5, 1, UIFont.Small)
        else
            local currentValue = tonumber(data.currentValue) or 0
            local recordedValue = tonumber(data.recordedValue) or 0
            if currentValue < recordedValue then
                local notReachedText = string.format(
                    getText("UI_BurdJournals_RecordedNotReached") or "Recorded: %s | Current: %s (not there yet)",
                    data.recordedFormatted or "?",
                    data.currentFormatted or "?"
                )
                self:drawText(notReachedText, textX, cardY + 22, 0.55, 0.55, 0.55, 1, UIFont.Small)
            elseif currentValue == recordedValue then
                local atPointText = string.format(
                    getText("UI_BurdJournals_RecordedAtPoint") or "Recorded: %s | Current: %s (at this point)",
                    data.recordedFormatted or "?",
                    data.currentFormatted or "?"
                )
                self:drawText(atPointText, textX, cardY + 22, 0.75, 0.72, 0.55, 1, UIFont.Small)
            else
                local surpassedText = string.format(
                    getText("UI_BurdJournals_RecordedSurpassed") or "Recorded: %s | Current: %s (surpassed)",
                    data.recordedFormatted or "?",
                    data.currentFormatted or "?"
                )
                self:drawText(surpassedText, textX, cardY + 22, 0.4, 0.6, 0.4, 1, UIFont.Small)
            end
        end

        -- Check if there's an erasing state for this stat
        local erasingState = mainPanel.erasingState
        local isErasingThis = erasingState and erasingState.active
                              and erasingState.entryType == "stat" and erasingState.entryName == data.statId

        local hasEraser = BurdJournals.hasEraser(mainPanel.player)
        local btnW = 55
        local btnH = 22
        local btnGap = 4
        local rightmostBtnX = cardX + cardW - btnW - padding
        local btnY = cardY + (cardH - btnH) / 2
        local showClaimBtn = data.canClaim and not isLearningThis
        local eraseBtnX = showClaimBtn and (rightmostBtnX - btnW - btnGap) or rightmostBtnX

        -- Check if this stat is in erase queue
        local eraseQueuePos = mainPanel:getEraseQueuePosition(data.statId)
        local isEraseQueued = eraseQueuePos ~= nil

        -- Draw erase button
        if hasEraser and not isErasingThis then
            if isEraseQueued then
                -- Show queued state with position number
                self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.25, 0.25)
                self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.6, 0.6, 0.35, 0.35)
                local queueText = "#" .. eraseQueuePos
                local queueTextW = getTextManager():MeasureStringX(UIFont.Small, queueText)
                self:drawText(queueText, eraseBtnX + (btnW - queueTextW) / 2, btnY + 4, 0.9, 0.7, 0.5, 1, UIFont.Small)
            else
                self:drawRect(eraseBtnX, btnY, btnW, btnH, 0.7, 0.5, 0.15, 0.15)
                self:drawRectBorder(eraseBtnX, btnY, btnW, btnH, 0.8, 0.7, 0.25, 0.25)
                local eraseText = getText("UI_BurdJournals_BtnErase") or "Erase"
                local eraseTextW = getTextManager():MeasureStringX(UIFont.Small, eraseText)
                self:drawText(eraseText, eraseBtnX + (btnW - eraseTextW) / 2, btnY + 4, 1, 0.9, 0.9, 1, UIFont.Small)
            end
        end

        -- Draw CLAIM button if this stat can be absorbed and not currently learning
        if showClaimBtn then
            local mainBtnX = rightmostBtnX

            if isQueued then
                -- Show "Queued" button style
                self:drawRect(mainBtnX, btnY, btnW, btnH, 0.5, 0.4, 0.5, 0.55)
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 0.6, 0.5, 0.6, 0.65)
                local queueText = string.format("#%d", queuePosition)
                local queueTextW = getTextManager():MeasureStringX(UIFont.Small, queueText)
                self:drawText(queueText, mainBtnX + (btnW - queueTextW) / 2, btnY + 4, 0.8, 0.9, 1, 1, UIFont.Small)
            else
                -- Button background
                local mx = self:getMouseX()
                local my = self:getMouseY()
                local isHover = mx >= mainBtnX and mx <= mainBtnX + btnW and my >= y + cardMargin + (cardH - btnH) / 2 and my <= y + cardMargin + (cardH - btnH) / 2 + btnH

                if isHover then
                    self:drawRect(mainBtnX, btnY, btnW, btnH, 0.9, 0.3, 0.6, 0.4)
                else
                    self:drawRect(mainBtnX, btnY, btnW, btnH, 0.7, 0.25, 0.45, 0.35)
                end
                self:drawRectBorder(mainBtnX, btnY, btnW, btnH, 1, 0.4, 0.7, 0.55)

                local btnText = getText("UI_BurdJournals_Absorb") or "CLAIM"
                local btnTextW = getTextManager():MeasureStringX(UIFont.Small, btnText)
                self:drawText(btnText, mainBtnX + (btnW - btnTextW) / 2, btnY + 4, 0.9, 1, 1, 1, UIFont.Small)
            end
        end

    end

    return y + h
end

function BurdJournals.UI.MainPanel:onClaimAll()
    if not self:startLearningAll() then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:onClaimTab()
    if (self.currentTab or "skills") == "forget" then
        self:showFeedback(
            getText("UI_BurdJournals_ForgetTabHint") or "Choose a trait in this tab to forget.",
            {r=0.9, g=0.72, b=0.45}
        )
        return
    end
    if not self:startLearningTab(self.currentTab or "skills") then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:claimSkill(skillName, recordedXP)
    local journalData = BurdJournals.getJournalData(self.journal)
    if not isSkillVisibleForJournal(journalData, skillName) then
        self:showFeedback(getText("UI_BurdJournals_CantClaimSkill") or "That skill cannot be claimed right now", {r=0.9, g=0.5, b=0.3})
        return
    end

    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("skill", skillName, recordedXP) then
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", BurdJournals.getPerkDisplayName(skillName) or skillName), {r=0.7, g=0.8, b=0.9})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startLearningSkill(skillName, recordedXP) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:claimTrait(traitId)

    if BurdJournals.playerHasTrait(self.player, traitId) then
        self:showFeedback(getText("UI_BurdJournals_TraitAlreadyKnownFeedback") or "Trait already known!", {r=0.7, g=0.5, b=0.3})
        return
    end

    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("trait", traitId) then
            local traitName = safeGetTraitName(traitId)
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", traitName), {r=0.7, g=0.8, b=0.9})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startLearningTrait(traitId) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

function BurdJournals.UI.MainPanel:claimForgetTrait(traitId)
    if not traitId then return end
    if not (BurdJournals.playerHasTrait and BurdJournals.playerHasTrait(self.player, traitId)) then
        self:showFeedback(getText("UI_BurdJournals_NoForgetableTraits") or "No removable traits available", {r=0.9, g=0.7, b=0.3})
        return
    end

    if self.learningState and self.learningState.active then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
        return
    end

    self:sendClaimForgetSlot(traitId)
end

function BurdJournals.UI.MainPanel:sendClaimForgetSlot(traitId)
    if not self.journal or not self.player or not traitId then return end
    local journalId = self.journal:getID()

    if isClient() and not isServer() then
        sendClientCommand(self.player, "BurdJournals", "claimForgetSlot", {
            journalId = journalId,
            traitId = traitId,
        })
        return
    end

    local journalData = BurdJournals.getJournalData(self.journal)
    if not journalData
        or journalData.forgetSlot ~= true
        or not BurdJournals.isForgetSlotEnabledForJournal
        or not BurdJournals.isForgetSlotEnabledForJournal(journalData) then
        self:showFeedback(getText("UI_BurdJournals_NoTraitsAvailable") or "No traits available", {r=0.9, g=0.7, b=0.3})
        return
    end

    if BurdJournals.hasCharacterClaimedForgetSlot and BurdJournals.hasCharacterClaimedForgetSlot(journalData, self.player) then
        self:showFeedback(getText("UI_BurdJournals_ForgetTraitUsed") or "Forget slot already used", {r=0.9, g=0.7, b=0.3})
        return
    end

    local removed = BurdJournals.safeRemoveTrait and BurdJournals.safeRemoveTrait(self.player, traitId)
    if not removed then
        self:showFeedback(getText("UI_BurdJournals_ForgetTraitFailed") or "Could not forget trait", {r=0.9, g=0.4, b=0.4})
        return
    end

    if BurdJournals.markForgetSlotClaimedByCharacter then
        BurdJournals.markForgetSlotClaimedByCharacter(journalData, self.player, traitId)
    end

    if self.journal.transmitModData then
        self.journal:transmitModData()
    end

    local traitName = safeGetTraitName(traitId)
    self:showFeedback(string.format(getText("UI_BurdJournals_ForgetSlotClaimed") or "Forgot trait: %s", traitName), {r=0.9, g=0.75, b=0.75})
    self:refreshAbsorptionList()
    if self.checkDissolution then
        self:checkDissolution(true)
    end
end

function BurdJournals.UI.MainPanel:claimRecipe(recipeName)

    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("recipe", recipeName) then
            local displayName = BurdJournals.getRecipeDisplayName(recipeName) or recipeName
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", displayName), {r=0.5, g=0.85, b=0.9})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    if not self:startLearningRecipe(recipeName) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

-- Claim a stat (zombie kills, hours survived) from a journal - starts timed action
function BurdJournals.UI.MainPanel:claimStat(statId, recordedValue)
    if not self.journal or not self.player then return end

    local modData = self.journal:getModData()
    local journalData = modData and modData.BurdJournals
    if not journalData then
        self:showFeedback("Journal has no data", {r=0.9, g=0.4, b=0.4})
        return
    end

    -- Determine the value to apply
    -- Stats are stored as tables with {value = X, timestamp = Y, recordedBy = Z}
    local valueToApply = recordedValue
    if not valueToApply and journalData.stats then
        local statData = journalData.stats[statId]
        valueToApply = type(statData) == "table" and statData.value or statData
    end

    if not valueToApply or type(valueToApply) ~= "number" then
        self:showFeedback("Stat value not found", {r=0.9, g=0.4, b=0.4})
        return
    end

    -- If already learning something (and not absorb all), queue this stat
    if self.learningState.active and not self.learningState.isAbsorbAll then
        if self:addToQueue("stat", statId, valueToApply) then
            local statName = BurdJournals.getStatDisplayName(statId) or statId
            self:showFeedback(string.format(getText("UI_BurdJournals_Queued") or "Queued: %s", statName), {r=0.7, g=0.8, b=0.9})
        else
            self:showFeedback(getText("UI_BurdJournals_AlreadyQueued") or "Already queued", {r=0.9, g=0.7, b=0.3})
        end
        return
    end

    -- Start the timed learning action
    if not self:startLearningStat(statId, valueToApply) then
        self:showFeedback(getText("UI_BurdJournals_AlreadyReading") or "Already reading...", {r=0.9, g=0.7, b=0.3})
    end
end

-- Send stat claim to server (called after timed action completes)
function BurdJournals.UI.MainPanel:sendClaimStat(statId, value)
    if not self.journal or not self.player then return end

    local statName = BurdJournals.getStatDisplayName(statId)

    -- In multiplayer, route through the server
    if isClient() and not isServer() then
        sendClientCommand(self.player, "BurdJournals", "claimStat", {
            journalId = self.journal:getID(),
            statId = statId,
            value = value,
        })
        return
    end

    -- Single player: apply directly
    local journalData = BurdJournals.getJournalData(self.journal)
    if BurdJournals.applyStatAbsorption(self.player, statId, value) then
        if journalData then
            BurdJournals.markStatClaimedByCharacter(journalData, self.player, statId)
        end

        if self.journal.transmitModData then
            self.journal:transmitModData()
        end
    end
end

-- Track open MainPanel instances for baseline change notifications
BurdJournals.openMainPanels = BurdJournals.openMainPanels or {}

-- Register this panel when created
function BurdJournals.UI.MainPanel:registerOpenPanel()
    BurdJournals.openMainPanels[self] = true
end

-- Unregister when closed
function BurdJournals.UI.MainPanel:unregisterOpenPanel()
    BurdJournals.openMainPanels[self] = nil
end

-- Notification handler for baseline changes
-- Called from BurdJournals.setSkillBaseline, setTraitBaseline, etc.
function BurdJournals.notifyBaselineChanged(player, changeType, itemName)
    if not BurdJournals.openMainPanels then return end
    
    for panel, _ in pairs(BurdJournals.openMainPanels) do
        if panel and panel.player then
            -- Check if this panel is for the affected player
            local panelPlayerId = 0
            if panel.player.getOnlineID then
                panelPlayerId = panel.player:getOnlineID() or 0
            end
            local affectedPlayerId = 0
            if player and player.getOnlineID then
                affectedPlayerId = player:getOnlineID() or 0
            end
            
            -- Refresh if same player or if we can't determine (SP)
            if panelPlayerId == affectedPlayerId or panelPlayerId == 0 or affectedPlayerId == 0 then
                -- Refresh the current list if we're in recording mode
                if panel.mode == "log" and panel.refreshCurrentList then
                    panel:refreshCurrentList()
                    BurdJournals.debugPrint("[BurdJournals] Refreshed MainPanel due to baseline change: " .. tostring(changeType) .. " " .. tostring(itemName))
                end
            end
        end
    end
end
