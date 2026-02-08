--[[
    Burd's Survival Journals - Zombie Corpse Loot & World Spawns
    Build 42 - Version 2.0
    
    Handles:
    1. Bloody journal spawns on zombie corpses (OnZombieDead)
    2. Worn journal spawns in world containers (OnFillContainer)
    
    Bloody journals (zombie corpses):
    - 2-4 skills, 50-150 XP each
    - Rare trait chance (15%)
    - Must be cleaned before use
    
    Worn journals (world containers):
    - 1-2 skills, 25-75 XP each
    - Ready to use immediately
]]

require "BurdJournals_Shared"

BurdJournals = BurdJournals or {}
BurdJournals.ZombieLoot = BurdJournals.ZombieLoot or {}

-- ==================== ZOMBIE PROFESSIONS ====================

BurdJournals.ZombieLoot.Professions = {
    {
        name = "Former Farmer",
        nameKey = "UI_BurdJournals_ProfFormerFarmer",
        skills = {"Farming", "Cooking", "Foraging", "Trapping"},
        flavorKey = "UI_BurdJournals_FlavorFarmer"
    },
    {
        name = "Former Mechanic",
        nameKey = "UI_BurdJournals_ProfFormerMechanic",
        skills = {"Mechanics", "Electricity", "MetalWelding"},
        flavorKey = "UI_BurdJournals_FlavorMechanic"
    },
    {
        name = "Former Doctor",
        nameKey = "UI_BurdJournals_ProfFormerDoctor",
        skills = {"Doctor", "Cooking"},
        flavorKey = "UI_BurdJournals_FlavorDoctor"
    },
    {
        name = "Former Carpenter",
        nameKey = "UI_BurdJournals_ProfFormerCarpenter",
        skills = {"Carpentry", "Maintenance"},
        flavorKey = "UI_BurdJournals_FlavorCarpenter"
    },
    {
        name = "Former Hunter",
        nameKey = "UI_BurdJournals_ProfFormerHunter",
        skills = {"Aiming", "Reloading", "Sneak", "Trapping", "Foraging"},
        flavorKey = "UI_BurdJournals_FlavorHunter"
    },
    {
        name = "Former Soldier",
        nameKey = "UI_BurdJournals_ProfFormerSoldier",
        skills = {"Aiming", "Reloading", "Fitness", "Strength", "Sneak"},
        flavorKey = "UI_BurdJournals_FlavorSoldier"
    },
    {
        name = "Former Chef",
        nameKey = "UI_BurdJournals_ProfFormerChef",
        skills = {"Cooking", "Farming", "Foraging"},
        flavorKey = "UI_BurdJournals_FlavorChef"
    },
    {
        name = "Former Athlete",
        nameKey = "UI_BurdJournals_ProfFormerAthlete",
        skills = {"Fitness", "Strength", "Sprinting", "Nimble"},
        flavorKey = "UI_BurdJournals_FlavorAthlete"
    },
    {
        name = "Former Burglar",
        nameKey = "UI_BurdJournals_ProfFormerBurglar",
        skills = {"Lightfoot", "Sneak", "Nimble", "SmallBlade"},
        flavorKey = "UI_BurdJournals_FlavorBurglar"
    },
    {
        name = "Former Lumberjack",
        nameKey = "UI_BurdJournals_ProfFormerLumberjack",
        skills = {"Axe", "Strength", "Fitness", "Carpentry"},
        flavorKey = "UI_BurdJournals_FlavorLumberjack"
    },
    {
        name = "Former Fisherman",
        nameKey = "UI_BurdJournals_ProfFormerFisherman",
        skills = {"Fishing", "Cooking", "Trapping"},
        flavorKey = "UI_BurdJournals_FlavorFisherman"
    },
    {
        name = "Former Tailor",
        nameKey = "UI_BurdJournals_ProfFormerTailor",
        skills = {"Tailoring"},
        flavorKey = "UI_BurdJournals_FlavorTailor"
    },
    {
        name = "Former Electrician",
        nameKey = "UI_BurdJournals_ProfFormerElectrician",
        skills = {"Electricity", "Mechanics"},
        flavorKey = "UI_BurdJournals_FlavorElectrician"
    },
    {
        name = "Former Metalworker",
        nameKey = "UI_BurdJournals_ProfFormerMetalworker",
        skills = {"MetalWelding", "Mechanics", "Strength"},
        flavorKey = "UI_BurdJournals_FlavorMetalworker"
    },
    {
        name = "Former Survivalist",
        nameKey = "UI_BurdJournals_ProfFormerSurvivalist",
        skills = {"Foraging", "Trapping", "Fishing", "Carpentry", "Farming"},
        flavorKey = "UI_BurdJournals_FlavorSurvivalist"
    },
    {
        name = "Former Fighter",
        nameKey = "UI_BurdJournals_ProfFormerFighter",
        skills = {"Axe", "Blunt", "SmallBlunt", "LongBlade", "SmallBlade", "Spear", "Maintenance"},
        flavorKey = "UI_BurdJournals_FlavorFighter"
    },
}

-- ==================== GENERATE BLOODY JOURNAL DATA ====================

function BurdJournals.ZombieLoot.generateBloodyJournalData()
    -- Pick random profession for thematic skills
    local profession = BurdJournals.ZombieLoot.Professions[ZombRand(#BurdJournals.ZombieLoot.Professions) + 1]

    -- Generate a random survivor name for the author
    local survivorName = BurdJournals.generateRandomSurvivorName()

    -- Get sandbox settings for bloody journals (better rewards)
    local minXP = BurdJournals.getSandboxOption("BloodyJournalMinXP") or 50
    local maxXP = BurdJournals.getSandboxOption("BloodyJournalMaxXP") or 150
    local minSkills = BurdJournals.getSandboxOption("BloodyJournalMinSkills") or 2
    local maxSkills = BurdJournals.getSandboxOption("BloodyJournalMaxSkills") or 4
    local traitChance = BurdJournals.getSandboxOption("BloodyJournalTraitChance") or 15

    -- Determine number of skills
    local numSkills = ZombRand(minSkills, maxSkills + 1)

    -- Build available skills from profession first (thematic skills)
    local availableSkills = {}
    local usedSkills = {}
    for _, skill in ipairs(profession.skills) do
        table.insert(availableSkills, skill)
        usedSkills[skill] = true
    end

    -- If profession has fewer skills than needed, fill with random skills (uses dynamic discovery)
    if #availableSkills < numSkills then
        local allSkills = BurdJournals.getAllowedSkills()
        local extraSkills = {}

        -- Collect skills not already in profession
        for _, skill in ipairs(allSkills) do
            if not usedSkills[skill] then
                table.insert(extraSkills, skill)
            end
        end

        -- Shuffle extra skills
        for i = #extraSkills, 2, -1 do
            local j = ZombRand(i) + 1
            extraSkills[i], extraSkills[j] = extraSkills[j], extraSkills[i]
        end

        -- Add extra skills to fill the gap
        local needed = numSkills - #availableSkills
        for i = 1, math.min(needed, #extraSkills) do
            table.insert(availableSkills, extraSkills[i])
        end
    end

    if #availableSkills == 0 then
        return nil
    end

    -- Shuffle all available skills
    for i = #availableSkills, 2, -1 do
        local j = ZombRand(i) + 1
        availableSkills[i], availableSkills[j] = availableSkills[j], availableSkills[i]
    end

    -- Build skills table with better XP values
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
    
    -- Maybe include rare trait rewards (1 to maxTraits based on sandbox setting)
    -- IMPORTANT: During OnZombieDead callbacks, many functions behave unexpectedly
    -- We use the simplest possible approach - pick traits by index based on world age
    local traits = nil
    if ZombRand(100) < traitChance then
        local traitList = BurdJournals.GRANTABLE_TRAITS
        if traitList and type(traitList) == "table" then
            local listSize = #traitList
            if listSize > 0 then
                -- Get max traits from sandbox (default 2)
                local maxTraits = BurdJournals.getSandboxOption("BloodyJournalMaxTraits") or 2
                if maxTraits < 1 then maxTraits = 1 end
                if maxTraits > listSize then maxTraits = listSize end

                -- Determine how many traits (1 to maxTraits) using world age
                local worldAge = 12345  -- fallback
                if getGameTime and getGameTime().getWorldAgeHours then
                    local ageResult = getGameTime():getWorldAgeHours()
                    if type(ageResult) == "number" then
                        worldAge = ageResult
                    end
                end

                -- Calculate number of traits (varies based on world age)
                local numTraits = (math.floor(worldAge * 777) % maxTraits) + 1

                -- Select unique traits using different multipliers for each slot
                traits = {}
                local usedIndices = {}
                local multipliers = {1000, 1337, 2718, 3141, 4242}  -- Different multipliers for variety

                for i = 1, numTraits do
                    local mult = multipliers[i] or (1000 + i * 137)
                    local idx = (math.floor(worldAge * mult) % listSize) + 1

                    -- Find unused index (simple linear probe)
                    local attempts = 0
                    while usedIndices[idx] and attempts < listSize do
                        idx = (idx % listSize) + 1
                        attempts = attempts + 1
                    end

                    if not usedIndices[idx] and idx >= 1 and idx <= listSize then
                        usedIndices[idx] = true
                        local traitId = traitList[idx]
                        if traitId and type(traitId) == "string" then
                            traits[traitId] = true  -- Simplified: just mark trait as present
                        end
                    end
                end

                -- If no traits were added, set to nil
                -- Use a simple count check instead of next() which can behave unexpectedly in OnZombieDead
                local traitCount = 0
                for _ in pairs(traits) do
                    traitCount = traitCount + 1
                    break  -- Just need to know if there's at least one
                end
                if traitCount == 0 then
                    traits = nil
                end
            end
        end
    end

    -- Generate recipes (higher chance for bloody journals - uses sandbox setting)
    -- Use ZombRand for proper randomness per zombie (same as trait chance above)
    local recipes = nil
    local recipeChance = BurdJournals.getSandboxOption("BloodyJournalRecipeChance") or 35
    if ZombRand(100) < recipeChance then
        local maxRecipes = BurdJournals.getSandboxOption("BloodyJournalMaxRecipes") or 2
        local numRecipes = ZombRand(1, maxRecipes + 1)
        local worldAge = getGameTime():getWorldAgeHours()
        recipes = BurdJournals.generateRandomRecipesSeeded(numRecipes, worldAge)
    end

    -- Build journal data structure (consistent with WorldSpawn format)
    -- Use translated profession name if available, fallback to English
    local professionName = profession.nameKey and getText(profession.nameKey) or profession.name
    local journalData = {
        author = survivorName,
        professionName = professionName,  -- e.g., "Former Farmer" (translated)
        flavorKey = profession.flavorKey,  -- Translation key for flavor text
        timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
        skills = skills,
        traits = traits, -- May be nil or contain one trait
        recipes = recipes,
        -- Bloody journal state
        isBloody = true,
        isWorn = false,
        wasFromBloody = true, -- Will be true after cleaning
        isPlayerCreated = false,
        isZombieJournal = true,
        condition = ZombRand(1, 4),
        -- Claim tracking (starts empty)
        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {},
    }

    return journalData
end

-- ==================== ZOMBIE DEATH HANDLER ====================

function BurdJournals.ZombieLoot.onZombieDead(zombie)
    -- Only run on server in multiplayer
    if isClient() and not isServer() then return end
    if not zombie then return end
    if not BurdJournals.isEnabled() then return end

    local spawnsEnabled = BurdJournals.getSandboxOption("EnableBloodyJournalSpawns")
    if spawnsEnabled == false then return end

    -- Roll for drop chance
    local dropChance = BurdJournals.getSandboxOption("BloodyJournalSpawnChance") or 0.5
    local roll = ZombRandFloat(0, 100)
    if roll > dropChance then return end

    -- Generate journal data
    local journalData = BurdJournals.ZombieLoot.generateBloodyJournalData()
    if not journalData then return end

    -- Get zombie's position
    local square = zombie:getSquare()
    if not square then return end

    -- Try to add to zombie inventory first
    local container = zombie:getInventory()
    local journal = nil

    if container then
        journal = container:AddItem("BurdJournals.FilledSurvivalJournal_Bloody")
    end

    -- If inventory add failed, drop on ground
    if not journal then
        journal = InventoryItemFactory.CreateItem("BurdJournals.FilledSurvivalJournal_Bloody")
        if journal then
            square:AddWorldInventoryItem(journal, ZombRandFloat(0, 0.8), ZombRandFloat(0, 0.8), 0)
        end
    end

    if journal then
        -- Set the mod data
        local modData = journal:getModData()
        modData.BurdJournals = {}
        for key, value in pairs(journalData) do
            modData.BurdJournals[key] = value
        end

        -- Ensure bloody state is explicitly set
        modData.BurdJournals.isBloody = true
        modData.BurdJournals.isWorn = false
        modData.BurdJournals.wasFromBloody = true
        modData.BurdJournals.isZombieJournal = true

        -- Update visuals
        BurdJournals.updateJournalName(journal)
        BurdJournals.updateJournalIcon(journal)

        -- Force sync in multiplayer
        if isServer() and journal.transmitModData then
            journal:transmitModData()
        end
    end
end

-- ==================== EVENT REGISTRATION ====================

Events.OnZombieDead.Add(BurdJournals.ZombieLoot.onZombieDead)

-- ==================== WORN JOURNAL CONTAINER SPAWNING ====================
-- OnFillContainer handler for spawning worn journals in world containers
-- This runs when containers are first generated and adds journals based on sandbox settings

-- Container types that can spawn worn journals (with base weight for spawn chance scaling)
-- NOTE: These are the ACTUAL container type names from OnFillContainer (lowercase!)
local WORN_JOURNAL_CONTAINERS = {
    -- Shelves (literature likely)
    ["shelves"] = 2.0,
    ["metal_shelves"] = 1.5,
    -- Desks and tables
    ["desk"] = 1.5,
    ["sidetable"] = 0.8,
    ["endtable"] = 0.6,
    ["nightstand"] = 0.6,
    -- Dressers
    ["dresser"] = 0.5,
    -- Storage containers
    ["wardrobe"] = 0.3,
    ["locker"] = 0.5,
    ["filingcabinet"] = 1.0,
    -- Boxes
    ["smallbox"] = 0.4,
    ["cardboardbox"] = 0.4,
    ["crate"] = 0.5,
    -- Counters (low chance)
    ["counter"] = 0.2,
    -- Mailbox
    ["postbox"] = 0.3,
}

-- Track containers we've already processed
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
    -- Only run on server/single player
    if isClient() and not isServer() then return end
    
    -- Check if mod is enabled
    if not BurdJournals or not BurdJournals.isEnabled or not BurdJournals.isEnabled() then return end
    
    -- Check if worn journal spawns are enabled
    local spawnsEnabled = BurdJournals.getSandboxOption("EnableWornJournalSpawns")
    if spawnsEnabled == false then return end
    
    -- Check if this container type can spawn journals
    local baseWeight = WORN_JOURNAL_CONTAINERS[containerType]
    if not baseWeight then return end
    
    -- Avoid processing the same container twice
    local containerKey = getContainerKey(itemContainer)
    if containerKey then
        if processedContainers[containerKey] then
            return
        end
        processedContainers[containerKey] = true
    end
    
    -- Get spawn chance from sandbox (0.1 to 100.0, default 2.0)
    local spawnChance = BurdJournals.getSandboxOption("WornJournalSpawnChance") or 2.0
    
    -- Calculate final spawn chance: (sandbox % * base weight) / 100
    local finalChance = (spawnChance * baseWeight) / 100.0
    
    -- Roll for spawn
    local roll = ZombRandFloat(0, 1)
    if roll > finalChance then
        return
    end
    
    -- Spawn a worn journal
    local journal = itemContainer:AddItem("BurdJournals.FilledSurvivalJournal_Worn")
    if journal then
        -- Initialize if OnCreate didn't run
        local modData = journal:getModData()
        if not modData.BurdJournals or not modData.BurdJournals.skills then
            if BurdJournals.WorldSpawn and BurdJournals.WorldSpawn.initializeJournalIfNeeded then
                BurdJournals.WorldSpawn.initializeJournalIfNeeded(journal)
            else
                -- Fallback initialization if WorldSpawn isn't loaded
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
                    claimedSkills = {},
                    claimedTraits = {},
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

-- Register OnFillContainer event for worn journal spawning
if Events.OnFillContainer then
    Events.OnFillContainer.Add(onFillContainerWornJournals)
end


