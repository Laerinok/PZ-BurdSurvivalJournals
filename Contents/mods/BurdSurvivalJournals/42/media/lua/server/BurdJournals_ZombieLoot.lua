
require "BurdJournals_Shared"

BurdJournals = BurdJournals or {}
BurdJournals.ZombieLoot = BurdJournals.ZombieLoot or {}

BurdJournals.ZombieLoot.Professions = {
    {
        id = "formerfarmer",
        name = "Former Farmer",
        nameKey = "UI_BurdJournals_ProfFormerFarmer",
        skills = {"Farming", "Cooking", "Foraging", "Trapping"},
        flavorKey = "UI_BurdJournals_FlavorFarmer"
    },
    {
        id = "formermechanic",
        name = "Former Mechanic",
        nameKey = "UI_BurdJournals_ProfFormerMechanic",
        skills = {"Mechanics", "Electricity", "MetalWelding"},
        flavorKey = "UI_BurdJournals_FlavorMechanic"
    },
    {
        id = "formerdoctor",
        name = "Former Doctor",
        nameKey = "UI_BurdJournals_ProfFormerDoctor",
        skills = {"Doctor", "Cooking"},
        flavorKey = "UI_BurdJournals_FlavorDoctor"
    },
    {
        id = "formercarpenter",
        name = "Former Carpenter",
        nameKey = "UI_BurdJournals_ProfFormerCarpenter",
        skills = {"Carpentry", "Maintenance"},
        flavorKey = "UI_BurdJournals_FlavorCarpenter"
    },
    {
        id = "formerhunter",
        name = "Former Hunter",
        nameKey = "UI_BurdJournals_ProfFormerHunter",
        skills = {"Aiming", "Reloading", "Sneak", "Trapping", "Foraging"},
        flavorKey = "UI_BurdJournals_FlavorHunter"
    },
    {
        id = "formersoldier",
        name = "Former Soldier",
        nameKey = "UI_BurdJournals_ProfFormerSoldier",
        skills = {"Aiming", "Reloading", "Fitness", "Strength", "Sneak"},
        flavorKey = "UI_BurdJournals_FlavorSoldier"
    },
    {
        id = "formerchef",
        name = "Former Chef",
        nameKey = "UI_BurdJournals_ProfFormerChef",
        skills = {"Cooking", "Farming", "Foraging"},
        flavorKey = "UI_BurdJournals_FlavorChef"
    },
    {
        id = "formerathlete",
        name = "Former Athlete",
        nameKey = "UI_BurdJournals_ProfFormerAthlete",
        skills = {"Fitness", "Strength", "Sprinting", "Nimble"},
        flavorKey = "UI_BurdJournals_FlavorAthlete"
    },
    {
        id = "formerburglar",
        name = "Former Burglar",
        nameKey = "UI_BurdJournals_ProfFormerBurglar",
        skills = {"Lightfoot", "Sneak", "Nimble", "SmallBlade"},
        flavorKey = "UI_BurdJournals_FlavorBurglar"
    },
    {
        id = "formerlumberjack",
        name = "Former Lumberjack",
        nameKey = "UI_BurdJournals_ProfFormerLumberjack",
        skills = {"Axe", "Strength", "Fitness", "Carpentry"},
        flavorKey = "UI_BurdJournals_FlavorLumberjack"
    },
    {
        id = "formerfisherman",
        name = "Former Fisherman",
        nameKey = "UI_BurdJournals_ProfFormerFisherman",
        skills = {"Fishing", "Cooking", "Trapping"},
        flavorKey = "UI_BurdJournals_FlavorFisherman"
    },
    {
        id = "formertailor",
        name = "Former Tailor",
        nameKey = "UI_BurdJournals_ProfFormerTailor",
        skills = {"Tailoring"},
        flavorKey = "UI_BurdJournals_FlavorTailor"
    },
    {
        id = "formerelectrician",
        name = "Former Electrician",
        nameKey = "UI_BurdJournals_ProfFormerElectrician",
        skills = {"Electricity", "Mechanics"},
        flavorKey = "UI_BurdJournals_FlavorElectrician"
    },
    {
        id = "formermetalworker",
        name = "Former Metalworker",
        nameKey = "UI_BurdJournals_ProfFormerMetalworker",
        skills = {"MetalWelding", "Mechanics", "Strength"},
        flavorKey = "UI_BurdJournals_FlavorMetalworker"
    },
    {
        id = "formersurvivalist",
        name = "Former Survivalist",
        nameKey = "UI_BurdJournals_ProfFormerSurvivalist",
        skills = {"Foraging", "Trapping", "Fishing", "Carpentry", "Farming"},
        flavorKey = "UI_BurdJournals_FlavorSurvivalist"
    },
    {
        id = "formerfighter",
        name = "Former Fighter",
        nameKey = "UI_BurdJournals_ProfFormerFighter",
        skills = {"Axe", "Blunt", "SmallBlunt", "LongBlade", "SmallBlade", "Spear", "Maintenance"},
        flavorKey = "UI_BurdJournals_FlavorFighter"
    },
}

function BurdJournals.ZombieLoot.generateBloodyJournalData()

    local profession = BurdJournals.ZombieLoot.Professions[ZombRand(#BurdJournals.ZombieLoot.Professions) + 1]

    local survivorName = BurdJournals.generateRandomSurvivorName()

    local minXP = BurdJournals.getSandboxOption("BloodyJournalMinXP") or 50
    local maxXP = BurdJournals.getSandboxOption("BloodyJournalMaxXP") or 150
    local minSkills = BurdJournals.getSandboxOption("BloodyJournalMinSkills") or 2
    local maxSkills = BurdJournals.getSandboxOption("BloodyJournalMaxSkills") or 4
    local traitChance = BurdJournals.getSandboxOption("BloodyJournalTraitChance") or 15

    local numSkills = ZombRand(minSkills, maxSkills + 1)

    local availableSkills = {}
    local usedSkills = {}
    for _, skill in ipairs(profession.skills) do
        table.insert(availableSkills, skill)
        usedSkills[skill] = true
    end

    if #availableSkills < numSkills then
        local allSkills = BurdJournals.getAllowedSkills()
        local extraSkills = {}

        for _, skill in ipairs(allSkills) do
            if not usedSkills[skill] then
                table.insert(extraSkills, skill)
            end
        end

        for i = #extraSkills, 2, -1 do
            local j = ZombRand(i) + 1
            extraSkills[i], extraSkills[j] = extraSkills[j], extraSkills[i]
        end

        local needed = numSkills - #availableSkills
        for i = 1, math.min(needed, #extraSkills) do
            table.insert(availableSkills, extraSkills[i])
        end
    end

    if #availableSkills == 0 then
        return nil
    end

    for i = #availableSkills, 2, -1 do
        local j = ZombRand(i) + 1
        availableSkills[i], availableSkills[j] = availableSkills[j], availableSkills[i]
    end

    local skills = {}
    for i = 1, math.min(numSkills, #availableSkills) do
        local skillName = availableSkills[i]
        local skillXP = ZombRand(minXP, maxXP + 1)
        local level = BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(skillXP, skillName) or 0

        skills[skillName] = {
            xp = skillXP,
            level = level
        }
    end

    local traits = nil
    if ZombRand(100) < traitChance then
        -- Use getGrantableTraits() for proper trait discovery, with fallback
        local traitList = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or 
                          BurdJournals.GRANTABLE_TRAITS or {}
        local listSize = #traitList
        
        if listSize > 0 then
            local maxTraits = BurdJournals.getSandboxOption("BloodyJournalMaxTraits") or 2
            if maxTraits < 1 then maxTraits = 1 end
            if maxTraits > listSize then maxTraits = listSize end

            -- Use actual randomness instead of deterministic world-age based selection
            local numTraits = ZombRand(1, maxTraits + 1)
            
            traits = {}
            local availableTraits = {}
            for _, t in ipairs(traitList) do
                table.insert(availableTraits, t)
            end
            
            -- Shuffle for random selection
            for i = #availableTraits, 2, -1 do
                local j = ZombRand(i) + 1
                availableTraits[i], availableTraits[j] = availableTraits[j], availableTraits[i]
            end
            
            -- Pick traits
            for i = 1, numTraits do
                if #availableTraits == 0 then break end
                local idx = ZombRand(#availableTraits) + 1
                local traitId = availableTraits[idx]
                if traitId and type(traitId) == "string" then
                    traits[traitId] = true
                    table.remove(availableTraits, idx)
                end
            end
            
            -- Check if we got any traits
            local traitCount = 0
            for _ in pairs(traits) do
                traitCount = traitCount + 1
                break
            end
            if traitCount == 0 then
                traits = nil
            end
        end
    end

    local recipes = nil
    local recipeChance = BurdJournals.getSandboxOption("BloodyJournalRecipeChance") or 35
    if ZombRand(100) < recipeChance then
        local maxRecipes = BurdJournals.getSandboxOption("BloodyJournalMaxRecipes") or 2
        local numRecipes = ZombRand(1, maxRecipes + 1)
        local worldAge = getGameTime():getWorldAgeHours()
        recipes = BurdJournals.generateRandomRecipesSeeded(numRecipes, worldAge)
    end

    local forgetSlot = BurdJournals.rollForgetSlotForType and BurdJournals.rollForgetSlotForType("bloody")

    -- Get translated name, with robust fallback for server-side getText() issues
    local professionName = nil
    if profession.nameKey then
        local translated = getText(profession.nameKey)
        if translated and translated ~= "" and translated ~= profession.nameKey then
            professionName = translated
        end
    end
    if not professionName or professionName == "" then
        professionName = profession.name
    end
    
    local journalData = {
        author = survivorName,
        profession = profession.id,  -- Also store the profession ID for lookup
        professionName = professionName,
        flavorKey = profession.flavorKey,
        timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
        skills = skills,
        traits = traits,
        recipes = recipes,
        forgetSlot = forgetSlot,

        isBloody = true,
        isWorn = false,
        wasFromBloody = true,
        isPlayerCreated = false,
        isZombieJournal = true,
        condition = ZombRand(1, 4),

        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {},
        claimedForgetSlot = {},
    }

    return journalData
end

function BurdJournals.ZombieLoot.onZombieDead(zombie)

    if isClient() and not isServer() then return end
    if not zombie then return end
    if not BurdJournals.isEnabled() then return end

    local cursedSpawnsEnabled = BurdJournals.getSandboxOption("EnableCursedJournalSpawns")
    if cursedSpawnsEnabled ~= false then
        local cursedDropChance = tonumber(BurdJournals.getSandboxOption("CursedJournalSpawnChance")) or 0.2
        local cursedRoll = ZombRandFloat(0, 100)
        if cursedRoll <= cursedDropChance then
            local square = zombie:getSquare()
            if square then
                local container = zombie:getInventory()
                local cursedJournal = nil
                if container then
                    cursedJournal = container:AddItem(BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal")
                end
                if not cursedJournal and InventoryItemFactory then
                    cursedJournal = InventoryItemFactory.CreateItem(BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal")
                    if cursedJournal then
                        square:AddWorldInventoryItem(cursedJournal, ZombRandFloat(0, 0.8), ZombRandFloat(0, 0.8), 0)
                    end
                end

                if cursedJournal then
                    local modData = cursedJournal:getModData()
                    modData.BurdJournals = modData.BurdJournals or {}
                    local data = modData.BurdJournals
                    data.uuid = data.uuid or (BurdJournals.generateUUID and BurdJournals.generateUUID()) or ("cursed-" .. tostring(ZombRand(999999999)))
                    data.timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720)
                    data.author = data.author or (BurdJournals.generateRandomSurvivorName and BurdJournals.generateRandomSurvivorName()) or "Unknown Survivor"
                    data.isCursedJournal = true
                    data.cursedState = "dormant"
                    data.isCursedReward = false
                    data.cursedEffectType = nil
                    data.cursedUnleashedByCharacterId = nil
                    data.cursedUnleashedByUsername = nil
                    data.cursedUnleashedAtHours = nil
                    data.cursedSealSoundEvent = nil
                    data.cursedForcedEffectType = nil
                    data.cursedForcedTraitId = nil
                    data.cursedForcedSkillName = nil
                    data.cursedPendingRewards = nil
                    data.isBloody = false
                    data.isWorn = false
                    data.wasFromBloody = false
                    data.isPlayerCreated = false
                    data.isZombieJournal = true
                    data.claims = data.claims or {}
                    data.claimedSkills = data.claimedSkills or {}
                    data.claimedTraits = data.claimedTraits or {}
                    data.claimedRecipes = data.claimedRecipes or {}
                    data.claimedForgetSlot = data.claimedForgetSlot or {}

                    BurdJournals.updateJournalName(cursedJournal)
                    BurdJournals.updateJournalIcon(cursedJournal)
                    if isServer() and cursedJournal.transmitModData then
                        cursedJournal:transmitModData()
                    end
                    return
                end
            end
        end
    end

    local spawnsEnabled = BurdJournals.getSandboxOption("EnableBloodyJournalSpawns")
    if spawnsEnabled == false then return end

    local dropChance = BurdJournals.getSandboxOption("BloodyJournalSpawnChance") or 0.5
    local roll = ZombRandFloat(0, 100)
    if roll > dropChance then return end

    local journalData = BurdJournals.ZombieLoot.generateBloodyJournalData()
    if not journalData then return end

    local square = zombie:getSquare()
    if not square then return end

    local container = zombie:getInventory()
    local journal = nil

    if container then
        journal = container:AddItem("BurdJournals.FilledSurvivalJournal_Bloody")
    end

    if not journal then
        journal = InventoryItemFactory.CreateItem("BurdJournals.FilledSurvivalJournal_Bloody")
        if journal then
            square:AddWorldInventoryItem(journal, ZombRandFloat(0, 0.8), ZombRandFloat(0, 0.8), 0)
        end
    end

    if journal then

        local modData = journal:getModData()
        modData.BurdJournals = {}
        for key, value in pairs(journalData) do
            modData.BurdJournals[key] = value
        end

        modData.BurdJournals.isBloody = true
        modData.BurdJournals.isWorn = false
        modData.BurdJournals.wasFromBloody = true
        modData.BurdJournals.isZombieJournal = true

        BurdJournals.updateJournalName(journal)
        BurdJournals.updateJournalIcon(journal)

        if isServer() and journal.transmitModData then
            journal:transmitModData()
        end
    end
end

Events.OnZombieDead.Add(BurdJournals.ZombieLoot.onZombieDead)

local WORN_JOURNAL_CONTAINERS = {

    ["shelves"] = 2.0,
    ["metal_shelves"] = 1.5,

    ["desk"] = 1.5,
    ["sidetable"] = 0.8,
    ["endtable"] = 0.6,
    ["nightstand"] = 0.6,

    ["dresser"] = 0.5,

    ["wardrobe"] = 0.3,
    ["locker"] = 0.5,
    ["filingcabinet"] = 1.0,

    ["smallbox"] = 0.4,
    ["cardboardbox"] = 0.4,
    ["crate"] = 0.5,

    ["counter"] = 0.2,

    ["postbox"] = 0.3,
}

local processedContainers = {}

local function getContainerKey(container)
    if not container then return nil end
    local parent = container:getParent()
    if parent and parent.getSquare then
        local sq = parent:getSquare()
        if sq then
            return string.format("%d_%d_%d_%s", sq:getX(), sq:getY(), sq:getZ(), tostring(container:getType()))
        end
    end
    return nil
end

local function onFillContainerWornJournals(roomName, containerType, itemContainer)

    if isClient() and not isServer() then return end

    if not BurdJournals or not BurdJournals.isEnabled or not BurdJournals.isEnabled() then return end

    local spawnsEnabled = BurdJournals.getSandboxOption("EnableWornJournalSpawns")
    if spawnsEnabled == false then return end

    local baseWeight = WORN_JOURNAL_CONTAINERS[containerType]
    if not baseWeight then return end

    local containerKey = getContainerKey(itemContainer)
    if containerKey then
        if processedContainers[containerKey] then
            return
        end
        processedContainers[containerKey] = true
    end

    local spawnChance = BurdJournals.getSandboxOption("WornJournalSpawnChance") or 2.0

    local finalChance = (spawnChance * baseWeight) / 100.0

    local roll = ZombRandFloat(0, 1)
    if roll > finalChance then
        return
    end

    local journal = itemContainer:AddItem("BurdJournals.FilledSurvivalJournal_Worn")
    if journal then

        local modData = journal:getModData()
        if not modData.BurdJournals or not modData.BurdJournals.skills then
            if BurdJournals.WorldSpawn and BurdJournals.WorldSpawn.initializeJournalIfNeeded then
                BurdJournals.WorldSpawn.initializeJournalIfNeeded(journal)
            else

                modData.BurdJournals = {
                    uuid = BurdJournals.generateUUID and BurdJournals.generateUUID() or tostring(ZombRand(999999)),
                    author = getText("UI_BurdJournals_UnknownSurvivor") or "Unknown Survivor",
                    profession = "unemployed",
                    professionName = getText("UI_BurdJournals_ProfSurvivor") or "Survivor",
                    timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
                    skills = BurdJournals.generateRandomSkills and BurdJournals.generateRandomSkills(1, 2, 25, 75) or {},
                    isWorn = true,
                    isBloody = false,
                    wasFromBloody = false,
                    isPlayerCreated = false,
                    traits = nil,
                    forgetSlot = BurdJournals.rollForgetSlotForType and BurdJournals.rollForgetSlotForType("worn") or nil,
                    claimedSkills = {},
                    claimedTraits = {},
                    claimedForgetSlot = {},
                }
                if BurdJournals.updateJournalName then
                    BurdJournals.updateJournalName(journal)
                end
                if BurdJournals.updateJournalIcon then
                    BurdJournals.updateJournalIcon(journal)
                end
            end
        end
    end
end

if Events.OnFillContainer then
    Events.OnFillContainer.Add(onFillContainerWornJournals)
end
