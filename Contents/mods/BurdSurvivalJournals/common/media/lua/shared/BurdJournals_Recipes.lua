
require "BurdJournals_Shared"

-- Build 42 OnTest signature: function(sourceItem, result)
-- We don't need the parameters, just checking sandbox option
function BurdJournals_CanCraftPlayerJournal(sourceItem, result)
    if BurdJournals and BurdJournals.isPlayerJournalsEnabled then
        return BurdJournals.isPlayerJournalsEnabled()
    end
    return true
end

local function getItemFromArgs(arg1, arg2, arg3, arg4)

    if arg1 and type(arg1) == "userdata" then
        if arg1.getAllCreatedItems and arg1.getAllConsumedItems then

            local createdItems = arg1:getAllCreatedItems()
            local resultItem = createdItems and createdItems:size() > 0 and createdItems:get(0) or nil
            local consumedItems = arg1:getAllConsumedItems()
            return resultItem, arg2, consumedItems
        end
    end

    if arg2 and type(arg2) ~= "nil" then

        if arg2.getModData then
            return arg2, arg3, arg1
        end
    end

    if arg1 and arg1.getModData then
        return arg1, nil, nil
    end

    return nil, nil, nil
end

local function safeGenerateRandomSkills(minSkills, maxSkills, minXP, maxXP)
    if BurdJournals and BurdJournals.generateRandomSkills then
        return BurdJournals.generateRandomSkills(minSkills, maxSkills, minXP, maxXP)
    end

    local skills = {}
    local fallbackSkills = {"Carpentry", "Cooking", "Farming", "Foraging", "Fishing"}
    local numSkills = ZombRand(minSkills or 1, (maxSkills or 2) + 1)
    for i = 1, numSkills do
        local skill = fallbackSkills[ZombRand(#fallbackSkills) + 1]
        skills[skill] = {
            xp = ZombRand(minXP or 25, (maxXP or 75) + 1),
            level = 0
        }
    end
    return skills
end

local function safeGenerateSurvivorName()
    if BurdJournals and BurdJournals.generateRandomSurvivorName then
        return BurdJournals.generateRandomSurvivorName()
    end
    local names = {"John", "Jane", "Mike", "Sarah", "David", "Lisa", "Tom", "Emily"}
    return names[ZombRand(#names) + 1] .. " Survivor"
end

local function safeGenerateUUID()
    if BurdJournals and BurdJournals.generateUUID then
        return BurdJournals.generateUUID()
    end
    return tostring(ZombRand(100000, 999999))
end

function BurdJournals_OnCreateBlankClean(arg1, arg2, arg3, arg4)
    local item, player, _ = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not item then return end

    local modData = item:getModData()
    modData.BurdJournals = {
        uuid = safeGenerateUUID(),
        condition = 10,
        isWorn = false,
        isBloody = false,
        isWritten = false,
        timestamp = getGameTime():getWorldAgeHours()
    }

    if BurdJournals and BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(item)
    end
    if BurdJournals and BurdJournals.updateJournalIcon then
        BurdJournals.updateJournalIcon(item)
    end
end

function BurdJournals_OnCreateBlankWorn(arg1, arg2, arg3, arg4)
    local item, player, _ = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not item then return end

    local modData = item:getModData()
    modData.BurdJournals = {
        uuid = safeGenerateUUID(),
        condition = ZombRand(3, 7),
        isWorn = true,
        isBloody = false,
        isWritten = false,
        timestamp = getGameTime():getWorldAgeHours()
    }

    if BurdJournals and BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(item)
    end
    if BurdJournals and BurdJournals.updateJournalIcon then
        BurdJournals.updateJournalIcon(item)
    end
end

function BurdJournals_OnCreateBlankBloody(arg1, arg2, arg3, arg4)
    local item, player, _ = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not item then return end

    local modData = item:getModData()
    modData.BurdJournals = {
        uuid = safeGenerateUUID(),
        condition = ZombRand(1, 5),
        isWorn = false,
        isBloody = true,
        isWritten = false,
        timestamp = getGameTime():getWorldAgeHours()
    }

    if BurdJournals and BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(item)
    end
    if BurdJournals and BurdJournals.updateJournalIcon then
        BurdJournals.updateJournalIcon(item)
    end
end

function BurdJournals_OnCreateFilledClean(arg1, arg2, arg3, arg4)
    local item, player, _ = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not item then return end

    local modData = item:getModData()

    if modData and modData.BurdJournals and modData.BurdJournals.uuid then

        return
    end

    if player then

        modData.BurdJournals = {
            uuid = safeGenerateUUID(),
            condition = 10,
            isWorn = false,
            isBloody = false,
            isWritten = true,
            wasFromBloody = false,
            isPlayerCreated = true,
            author = player:getUsername(),
            timestamp = getGameTime():getWorldAgeHours(),
            readCount = 0,
            readSessionCount = 0,
            currentSessionReadCount = 0,
            skillReadCounts = {},
            skills = safeGenerateRandomSkills(2, 4, 50, 150),
            claimedSkills = {},
            claimedTraits = {}
        }
    else

        local survivorName = safeGenerateSurvivorName()
        modData.BurdJournals = {
            uuid = safeGenerateUUID(),
            condition = 10,
            isWorn = false,
            isBloody = false,
            isWritten = true,
            wasFromBloody = false,
            wasRestored = true,
            isPlayerCreated = false,
            author = survivorName,
            timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
            readCount = 0,
            readSessionCount = 0,
            currentSessionReadCount = 0,
            skillReadCounts = {},
            skills = safeGenerateRandomSkills(2, 4, 50, 150),
            claimedSkills = {},
            claimedTraits = {}
        }
    end

    if BurdJournals and BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(item)
    end
    if BurdJournals and BurdJournals.updateJournalIcon then
        BurdJournals.updateJournalIcon(item)
    end

    if isServer() and item.transmitModData then
        item:transmitModData()
    end
end

function BurdJournals_OnCreateFilledWorn(arg1, arg2, arg3, arg4)
    local item, player, _ = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not item then
        return
    end

    local existingData = item:getModData()
    if existingData and existingData.BurdJournals and existingData.BurdJournals.uuid then

        return
    end

    local minSkills = 1
    local maxSkills = 2
    local minXP = 25
    local maxXP = 75
    local recipeChance = 15
    local maxRecipes = 1

    if BurdJournals and BurdJournals.getSandboxOption then
        minSkills = BurdJournals.getSandboxOption("WornJournalMinSkills") or minSkills
        maxSkills = BurdJournals.getSandboxOption("WornJournalMaxSkills") or maxSkills
        minXP = BurdJournals.getSandboxOption("WornJournalMinXP") or minXP
        maxXP = BurdJournals.getSandboxOption("WornJournalMaxXP") or maxXP
        recipeChance = BurdJournals.getSandboxOption("WornJournalRecipeChance") or recipeChance
        maxRecipes = BurdJournals.getSandboxOption("WornJournalMaxRecipes") or maxRecipes
    end

    local professionId, professionName, flavorKey = "unemployed", "Survivor", nil
    if BurdJournals and BurdJournals.getRandomProfession then
        professionId, professionName, flavorKey = BurdJournals.getRandomProfession()
    end

    local recipes = nil
    if ZombRand(100) < recipeChance then
        local numRecipes = ZombRand(1, maxRecipes + 1)
        if BurdJournals and BurdJournals.generateRandomRecipes then
            recipes = BurdJournals.generateRandomRecipes(numRecipes)
        end
    end

    local modData = item:getModData()
    modData.BurdJournals = {
        uuid = safeGenerateUUID(),
        condition = ZombRand(3, 7),
        isWorn = true,
        isBloody = false,
        isWritten = true,
        wasFromBloody = false,
        isPlayerCreated = false,
        author = safeGenerateSurvivorName(),
        profession = professionId,
        professionName = professionName,
        flavorKey = flavorKey,
        timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
        readCount = 0,
        readSessionCount = 0,
        currentSessionReadCount = 0,
        skillReadCounts = {},
        skills = safeGenerateRandomSkills(minSkills, maxSkills, minXP, maxXP),
        recipes = recipes,
        traits = {},
        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {}
    }

    if BurdJournals and BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(item)
    end
    if BurdJournals and BurdJournals.updateJournalIcon then
        BurdJournals.updateJournalIcon(item)
    end

    if isServer() and item.transmitModData then
        item:transmitModData()
    end

    local skillCount = 0
    for _ in pairs(modData.BurdJournals.skills or {}) do skillCount = skillCount + 1 end
end

function BurdJournals_OnCreateFilledBloody(arg1, arg2, arg3, arg4)
    local item, player, _ = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not item then return end

    local existingData = item:getModData()
    if existingData and existingData.BurdJournals and existingData.BurdJournals.uuid then

        return
    end

    local minSkills = 2
    local maxSkills = 4
    local minXP = 50
    local maxXP = 150
    local traitChance = 15
    local recipeChance = 35
    local maxRecipes = 2

    if BurdJournals and BurdJournals.getSandboxOption then
        minSkills = BurdJournals.getSandboxOption("BloodyJournalMinSkills") or minSkills
        maxSkills = BurdJournals.getSandboxOption("BloodyJournalMaxSkills") or maxSkills
        minXP = BurdJournals.getSandboxOption("BloodyJournalMinXP") or minXP
        maxXP = BurdJournals.getSandboxOption("BloodyJournalMaxXP") or maxXP
        traitChance = BurdJournals.getSandboxOption("BloodyJournalTraitChance") or traitChance
        recipeChance = BurdJournals.getSandboxOption("BloodyJournalRecipeChance") or recipeChance
        maxRecipes = BurdJournals.getSandboxOption("BloodyJournalMaxRecipes") or maxRecipes
    end

    local professionId, professionName, flavorKey = "unemployed", "Survivor", nil
    if BurdJournals and BurdJournals.getRandomProfession then
        professionId, professionName, flavorKey = BurdJournals.getRandomProfession()
    end

    local traits = {}
    if ZombRand(100) < traitChance then
        local grantableTraits = (BurdJournals and BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or
                                (BurdJournals and BurdJournals.GRANTABLE_TRAITS) or {
            "brave", "organized", "fastlearner", "needslesssleep",
            "lighteater", "dextrous", "graceful", "inconspicuous", "lowthirst"
        }
        if #grantableTraits > 0 then

            local numTraits = ZombRand(1, 5)
            local availableTraits = {}
            for _, t in ipairs(grantableTraits) do
                table.insert(availableTraits, t)
            end

            for i = 1, numTraits do
                if #availableTraits == 0 then break end
                local idx = ZombRand(#availableTraits) + 1
                local randomTrait = availableTraits[idx]
                if randomTrait then
                    traits[randomTrait] = true

                    table.remove(availableTraits, idx)
                end
            end
        end
    end

    -- Generate recipes for bloody journals
    local recipes = nil
    if ZombRand(100) < recipeChance then
        local numRecipes = ZombRand(1, maxRecipes + 1)
        if BurdJournals and BurdJournals.generateRandomRecipes then
            recipes = BurdJournals.generateRandomRecipes(numRecipes)
            -- If empty table returned, set to nil
            if recipes then
                local count = 0
                for _ in pairs(recipes) do count = count + 1 end
                if count == 0 then recipes = nil end
            end
        end
    end

    local modData = item:getModData()
    modData.BurdJournals = {
        uuid = safeGenerateUUID(),
        condition = ZombRand(1, 4),
        isWorn = false,
        isBloody = true,
        isWritten = true,
        wasFromBloody = true,
        isPlayerCreated = false,
        author = safeGenerateSurvivorName(),
        profession = professionId,
        professionName = professionName,
        flavorKey = flavorKey,
        timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
        readCount = 0,
        readSessionCount = 0,
        currentSessionReadCount = 0,
        skillReadCounts = {},
        skills = safeGenerateRandomSkills(minSkills, maxSkills, minXP, maxXP),
        traits = traits,
        recipes = recipes,
        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {}
    }

    if BurdJournals and BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(item)
    end
    if BurdJournals and BurdJournals.updateJournalIcon then
        BurdJournals.updateJournalIcon(item)
    end

    if isServer() and item.transmitModData then
        item:transmitModData()
    end
end

function BurdJournals_OnCreateBlankJournal(arg1, arg2, arg3, arg4)
    BurdJournals_OnCreateBlankClean(arg1, arg2, arg3, arg4)
end

function BurdJournals_OnCleanWornJournal(arg1, arg2, arg3, arg4)
    local result, player, inputItems = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not result then return end

    local wornJournal = nil
    if inputItems and inputItems.size then
        for i = 0, inputItems:size() - 1 do
            local item = inputItems:get(i)
            if item and BurdJournals and BurdJournals.isWorn and BurdJournals.isWorn(item) then
                wornJournal = item
                break
            end
        end
    end

    if not wornJournal then
        return
    end

    local wornModData = wornJournal:getModData()
    local journalData = wornModData.BurdJournals

    if journalData then
        local resultModData = result:getModData()
        resultModData.BurdJournals = {
            uuid = safeGenerateUUID(),
            author = journalData.author,
            flavorKey = journalData.flavorKey,
            timestamp = journalData.timestamp,
            readCount = journalData.readCount or 0,
            readSessionCount = journalData.readSessionCount or 0,
            currentSessionId = journalData.currentSessionId,
            currentSessionReadCount = journalData.currentSessionReadCount or 0,
            skillReadCounts = journalData.skillReadCounts or {},
            skills = journalData.skills,
            traits = journalData.traits,
            isWritten = true,
            isWorn = false,
            isBloody = false,
            condition = 10,
            wasRestored = true,
            wasFromBloody = journalData.wasFromBloody or journalData.isBloody,
            restoredBy = player and player:getUsername() or "Unknown",
            claimedSkills = journalData.claimedSkills or {},
            claimedTraits = journalData.claimedTraits or {}
        }

        if BurdJournals and BurdJournals.updateJournalName then
            BurdJournals.updateJournalName(result)
        end
        if BurdJournals and BurdJournals.updateJournalIcon then
            BurdJournals.updateJournalIcon(result)
        end
    end
end

function BurdJournals_OnCreateFilledCleanFromWorn(arg1, arg2, arg3, arg4)
    local result, player, inputItems = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not result then return end

    local wornJournal = nil
    if inputItems and inputItems.size then
        for i = 0, inputItems:size() - 1 do
            local item = inputItems:get(i)
            if item and string.find(item:getFullType(), "FilledSurvivalJournal_Worn") then
                wornJournal = item
                break
            end
        end
    end

    if wornJournal then
        local wornModData = wornJournal:getModData()
        local journalData = wornModData.BurdJournals

        if journalData then
            local resultModData = result:getModData()
            resultModData.BurdJournals = {
                uuid = journalData.uuid or safeGenerateUUID(),
                author = journalData.author,
                flavorKey = journalData.flavorKey,
                timestamp = journalData.timestamp,
                readCount = journalData.readCount or 0,
                readSessionCount = journalData.readSessionCount or 0,
                currentSessionId = journalData.currentSessionId,
                currentSessionReadCount = journalData.currentSessionReadCount or 0,
                skillReadCounts = journalData.skillReadCounts or {},
                skills = journalData.skills or {},
                traits = journalData.traits or {},
                isWritten = true,
                isWorn = false,
                isBloody = false,
                wasFromBloody = journalData.wasFromBloody or journalData.isBloody,
                isPlayerCreated = journalData.isPlayerCreated,
                claimedSkills = journalData.claimedSkills or {},
                claimedTraits = journalData.claimedTraits or {},
                wasRestored = true,
                restoredBy = player and player:getUsername() or "Unknown",
            }

            if BurdJournals and BurdJournals.updateJournalName then
                BurdJournals.updateJournalName(result)
            end
            if BurdJournals and BurdJournals.updateJournalIcon then
                BurdJournals.updateJournalIcon(result)
            end
        end
    else

        local modData = result:getModData()
        modData.BurdJournals = {
            uuid = safeGenerateUUID(),
            isWritten = false,
            isWorn = false,
            isBloody = false,
            isPlayerCreated = true,
        }
    end
end

function BurdJournals_OnCreateFilledWornFromBloody(arg1, arg2, arg3, arg4)
    local result, player, inputItems = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not result then return end

    local bloodyJournal = nil
    if inputItems and inputItems.size then
        for i = 0, inputItems:size() - 1 do
            local item = inputItems:get(i)
            if item and string.find(item:getFullType(), "FilledSurvivalJournal_Bloody") then
                bloodyJournal = item
                break
            end
        end
    end

    if bloodyJournal then
        local bloodyModData = bloodyJournal:getModData()
        local journalData = bloodyModData.BurdJournals

        if journalData then
            local resultModData = result:getModData()
            resultModData.BurdJournals = {
                uuid = journalData.uuid or safeGenerateUUID(),
                author = journalData.author,
                flavorKey = journalData.flavorKey,
                timestamp = journalData.timestamp,
                readCount = journalData.readCount or 0,
                readSessionCount = journalData.readSessionCount or 0,
                currentSessionId = journalData.currentSessionId,
                currentSessionReadCount = journalData.currentSessionReadCount or 0,
                skillReadCounts = journalData.skillReadCounts or {},
                skills = journalData.skills or {},
                traits = journalData.traits or {},
                isWritten = true,
                isWorn = true,
                isBloody = false,
                wasFromBloody = true,
                isPlayerCreated = false,
                claimedSkills = journalData.claimedSkills or {},
                claimedTraits = journalData.claimedTraits or {},
                wasCleaned = true,
                cleanedBy = player and player:getUsername() or "Unknown",
            }

            if BurdJournals and BurdJournals.updateJournalName then
                BurdJournals.updateJournalName(result)
            end
            if BurdJournals and BurdJournals.updateJournalIcon then
                BurdJournals.updateJournalIcon(result)
            end
        end
    else

        BurdJournals_OnCreateFilledWorn(arg1, arg2, arg3, arg4)
    end
end

function BurdJournals_OnCreateFilledCleanFromWornOrBloody(arg1, arg2, arg3, arg4)
    local result, player, inputItems = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not result then return end

    local sourceJournal = nil
    if inputItems and inputItems.size then
        for i = 0, inputItems:size() - 1 do
            local item = inputItems:get(i)
            if item then
                local itemType = item:getFullType()
                if string.find(itemType, "FilledSurvivalJournal_Worn") or
                   string.find(itemType, "FilledSurvivalJournal_Bloody") then
                    sourceJournal = item
                    break
                end
            end
        end
    end

    if sourceJournal then
        local sourceModData = sourceJournal:getModData()
        local journalData = sourceModData.BurdJournals
        local wasBloodySouce = string.find(sourceJournal:getFullType(), "_Bloody") ~= nil

        if journalData then
            local resultModData = result:getModData()
            resultModData.BurdJournals = {
                uuid = journalData.uuid or safeGenerateUUID(),
                author = journalData.author,
                flavorKey = journalData.flavorKey,
                timestamp = journalData.timestamp,
                readCount = journalData.readCount or 0,
                readSessionCount = journalData.readSessionCount or 0,
                currentSessionId = journalData.currentSessionId,
                currentSessionReadCount = journalData.currentSessionReadCount or 0,
                skillReadCounts = journalData.skillReadCounts or {},
                skills = journalData.skills or {},
                traits = journalData.traits or {},
                isWritten = true,
                isWorn = false,
                isBloody = false,
                wasFromBloody = wasBloodySouce or journalData.wasFromBloody or journalData.isBloody,
                isPlayerCreated = journalData.isPlayerCreated,
                claimedSkills = journalData.claimedSkills or {},
                claimedTraits = journalData.claimedTraits or {},
                wasRestored = true,
                restoredBy = player and player:getUsername() or "Unknown",
            }

            if BurdJournals and BurdJournals.updateJournalName then
                BurdJournals.updateJournalName(result)
            end
            if BurdJournals and BurdJournals.updateJournalIcon then
                BurdJournals.updateJournalIcon(result)
            end
        end
    else

        local modData = result:getModData()
        modData.BurdJournals = {
            uuid = safeGenerateUUID(),
            isWritten = false,
            isWorn = false,
            isBloody = false,
            isPlayerCreated = true,
        }
    end
end

function BurdJournals_OnCreateFilledCleanFromBloody(arg1, arg2, arg3, arg4)
    local result, player, inputItems = getItemFromArgs(arg1, arg2, arg3, arg4)
    if not result then return end

    local bloodyJournal = nil
    if inputItems and inputItems.size then
        for i = 0, inputItems:size() - 1 do
            local item = inputItems:get(i)
            if item and string.find(item:getFullType(), "FilledSurvivalJournal_Bloody") then
                bloodyJournal = item
                break
            end
        end
    end

    if bloodyJournal then
        local bloodyModData = bloodyJournal:getModData()
        local journalData = bloodyModData.BurdJournals

        if journalData then
            local resultModData = result:getModData()
            resultModData.BurdJournals = {
                uuid = journalData.uuid or safeGenerateUUID(),
                author = journalData.author,
                flavorKey = journalData.flavorKey,
                timestamp = journalData.timestamp,
                readCount = journalData.readCount or 0,
                readSessionCount = journalData.readSessionCount or 0,
                currentSessionId = journalData.currentSessionId,
                currentSessionReadCount = journalData.currentSessionReadCount or 0,
                skillReadCounts = journalData.skillReadCounts or {},
                skills = journalData.skills or {},
                traits = journalData.traits or {},
                isWritten = true,
                isWorn = false,
                isBloody = false,
                wasFromBloody = true,
                isPlayerCreated = false,
                claimedSkills = journalData.claimedSkills or {},
                claimedTraits = journalData.claimedTraits or {},
                wasRestored = true,
                wasCleaned = true,
                restoredBy = player and player:getUsername() or "Unknown",
            }

            if BurdJournals and BurdJournals.updateJournalName then
                BurdJournals.updateJournalName(result)
            end
            if BurdJournals and BurdJournals.updateJournalIcon then
                BurdJournals.updateJournalIcon(result)
            end
        end
    else

        local modData = result:getModData()
        modData.BurdJournals = {
            uuid = safeGenerateUUID(),
            isWritten = false,
            isWorn = false,
            isBloody = false,
            isPlayerCreated = true,
        }
    end
end

BurdJournals.OnCreateBlankClean = BurdJournals_OnCreateBlankClean
BurdJournals.OnCreateBlankWorn = BurdJournals_OnCreateBlankWorn
BurdJournals.OnCreateBlankBloody = BurdJournals_OnCreateBlankBloody
BurdJournals.OnCreateFilledClean = BurdJournals_OnCreateFilledClean
BurdJournals.OnCreateFilledWorn = BurdJournals_OnCreateFilledWorn
BurdJournals.OnCreateFilledBloody = BurdJournals_OnCreateFilledBloody
BurdJournals.OnCreateBlankJournal = BurdJournals_OnCreateBlankJournal
BurdJournals.OnCleanWornJournal = BurdJournals_OnCleanWornJournal
BurdJournals.OnCreateFilledCleanFromWorn = BurdJournals_OnCreateFilledCleanFromWorn
BurdJournals.OnCreateFilledWornFromBloody = BurdJournals_OnCreateFilledWornFromBloody
BurdJournals.OnCreateFilledCleanFromWornOrBloody = BurdJournals_OnCreateFilledCleanFromWornOrBloody
BurdJournals.OnCreateFilledCleanFromBloody = BurdJournals_OnCreateFilledCleanFromBloody
