
require "BurdJournals_Shared"

if Events then

    if Events.OnFillContainer then

    else
    end
else
end

local DISTRIBUTION_LIST = {

    {"BookstoreBooks", 3}, {"BookstorePersonal", 2.5}, {"BookstoreMisc", 2},
    {"BookstoreStationery", 2}, {"BookStoreCounter", 1.5}, {"BookstoreHobbies", 1.5},
    {"BookstoreOutdoors", 1.5}, {"BookstoreCrafts", 1.5}, {"BookstoreFarming", 1.5},

    {"LibraryBooks", 3}, {"LibraryCounter", 2}, {"LibraryMagazines", 1.5},
    {"LibraryPersonal", 2}, {"LibraryOutdoors", 1.5},

    {"CrateBooks", 2.5}, {"CrateBooksSchool", 2},

    {"PostOfficeBooks", 2}, {"PostOfficeMagazines", 1},

    {"CampingStoreBooks", 2},

    {"SafehouseBookShelf", 3},

    {"MagazineRackMixed", 1}, {"MagazineRackPaperback", 1.5},

    {"SchoolDesk", 1.5}, {"SchoolLockers", 0.8},

    {"OfficeDesk", 1}, {"OfficeDeskHome", 1}, {"OfficeDeskHomeClassy", 1.2},
    {"OfficeDrawers", 0.8},

    {"BookShelf", 2}, {"ShelfGeneric", 1}, {"Desk", 1}, {"DeskGeneric", 1},
    {"FilingCabinet", 0.8}, {"ClosetShelfGeneric", 0.5},

    {"BedroomDresser", 0.3}, {"BedroomDresserClassy", 0.5},
    {"BedroomSidetable", 0.6}, {"BedroomSidetableClassy", 0.8},
    {"Nightstand", 0.5}, {"Dresser", 0.3}, {"EndTable", 0.4},

    {"MotelSideTable", 0.6},
}

local distributionsInitialized = false

local CONTAINER_SPAWN_WEIGHTS = {

    ["BookstoreBooks"] = 3.0,
    ["BookstorePersonal"] = 2.5,
    ["BookstoreMisc"] = 2.0,
    ["LibraryBooks"] = 3.0,
    ["LibraryCounter"] = 2.0,
    ["CrateBooks"] = 2.5,
    ["SafehouseBookShelf"] = 3.0,
    ["BookShelf"] = 2.0,

    ["SchoolDesk"] = 1.5,
    ["OfficeDesk"] = 1.0,
    ["OfficeDeskHome"] = 1.0,
    ["Desk"] = 1.0,
    ["DeskGeneric"] = 1.0,
    ["FilingCabinet"] = 0.8,

    ["BedroomDresser"] = 0.3,
    ["BedroomSidetable"] = 0.6,
    ["Nightstand"] = 0.5,
    ["Dresser"] = 0.3,
    ["EndTable"] = 0.4,
    ["MotelSideTable"] = 0.6,
    ["ClosetShelfGeneric"] = 0.5,
    ["ShelfGeneric"] = 0.5,
}

local processedContainers = {}

local lastCleanup = 0
local CLEANUP_INTERVAL = 300000

local function cleanupTracking()
    local now = getTimestampMs and getTimestampMs() or 0
    if now - lastCleanup > CLEANUP_INTERVAL then
        processedContainers = {}
        lastCleanup = now
    end
end

local function getContainerKey(container)
    if not container then return nil end
    local parent = container:getParent()
    if parent and parent:getSquare() then
        local sq = parent:getSquare()
        return string.format("%d_%d_%d_%s", sq:getX(), sq:getY(), sq:getZ(), tostring(container:getType()))
    end
    return nil
end

local function onFillContainer(roomName, containerType, itemContainer)

    if isClient() and not isServer() then return end

    if not BurdJournals.isEnabled() then return end

    local spawnsEnabled = BurdJournals.getSandboxOption("EnableWornJournalSpawns")
    if spawnsEnabled == false then return end

    local baseWeight = CONTAINER_SPAWN_WEIGHTS[containerType]
    if not baseWeight then return end

    local containerKey = getContainerKey(itemContainer)
    if containerKey then
        if processedContainers[containerKey] then
            return
        end
        processedContainers[containerKey] = true
    end

    cleanupTracking()

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

            BurdJournals.WorldSpawn.initializeJournalIfNeeded(journal)
        end

        if BurdJournals.isDebug() then
            local data = modData.BurdJournals

        end
    end
end

if Events and Events.OnFillContainer then
    Events.OnFillContainer.Add(onFillContainer)

end

BurdJournals = BurdJournals or {}
BurdJournals.WorldSpawn = BurdJournals.WorldSpawn or {}

BurdJournals.WorldSpawn.SurvivorNames = {

    "John", "Jane", "Mike", "Sarah", "David", "Lisa", "Tom", "Emily",
    "Chris", "Amanda", "James", "Jennifer", "Robert", "Michelle", "William", "Jessica",
    "Daniel", "Ashley", "Matthew", "Stephanie", "Anthony", "Nicole", "Mark", "Elizabeth",

    "Doc", "Sarge", "Coach", "Chief", "Gramps", "Pops", "Red",
    "Lucky", "Ace", "Shadow", "Ghost", "Hawk", "Wolf", "Bear", "Fox",
}

BurdJournals.WorldSpawn.Professions = {
    {id = "fireofficer", name = "Fire Officer", nameKey = "UI_BurdJournals_ProfFireOfficer", flavorKey = "UI_BurdJournals_FlavorFireOfficer"},
    {id = "policeofficer", name = "Police Officer", nameKey = "UI_BurdJournals_ProfPoliceOfficer", flavorKey = "UI_BurdJournals_FlavorPoliceOfficer"},
    {id = "parkranger", name = "Park Ranger", nameKey = "UI_BurdJournals_ProfParkRanger", flavorKey = "UI_BurdJournals_FlavorParkRanger"},
    {id = "constructionworker", name = "Construction Worker", nameKey = "UI_BurdJournals_ProfConstructionWorker", flavorKey = "UI_BurdJournals_FlavorConstructionWorker"},
    {id = "securityguard", name = "Security Guard", nameKey = "UI_BurdJournals_ProfSecurityGuard", flavorKey = "UI_BurdJournals_FlavorSecurityGuard"},
    {id = "carpenter", name = "Carpenter", nameKey = "UI_BurdJournals_ProfCarpenter", flavorKey = "UI_BurdJournals_FlavorCarpenter"},
    {id = "burglar", name = "Burglar", nameKey = "UI_BurdJournals_ProfBurglar", flavorKey = "UI_BurdJournals_FlavorBurglar"},
    {id = "chef", name = "Chef", nameKey = "UI_BurdJournals_ProfChef", flavorKey = "UI_BurdJournals_FlavorChef"},
    {id = "repairman", name = "Repairman", nameKey = "UI_BurdJournals_ProfRepairman", flavorKey = "UI_BurdJournals_FlavorMechanic"},
    {id = "farmer", name = "Farmer", nameKey = "UI_BurdJournals_ProfFarmer", flavorKey = "UI_BurdJournals_FlavorFarmer"},
    {id = "fisherman", name = "Fisherman", nameKey = "UI_BurdJournals_ProfFisherman", flavorKey = "UI_BurdJournals_FlavorFisherman"},
    {id = "doctor", name = "Doctor", nameKey = "UI_BurdJournals_ProfDoctor", flavorKey = "UI_BurdJournals_FlavorDoctor"},
    {id = "nurse", name = "Nurse", nameKey = "UI_BurdJournals_ProfNurse", flavorKey = "UI_BurdJournals_FlavorNurse"},
    {id = "lumberjack", name = "Lumberjack", nameKey = "UI_BurdJournals_ProfLumberjack", flavorKey = "UI_BurdJournals_FlavorLumberjack"},
    {id = "fitnessInstructor", name = "Fitness Instructor", nameKey = "UI_BurdJournals_ProfFitnessInstructor", flavorKey = "UI_BurdJournals_FlavorFitnessInstructor"},
    {id = "burgerflipper", name = "Burger Flipper", nameKey = "UI_BurdJournals_ProfBurgerFlipper", flavorKey = "UI_BurdJournals_FlavorBurgerFlipper"},
    {id = "electrician", name = "Electrician", nameKey = "UI_BurdJournals_ProfElectrician", flavorKey = "UI_BurdJournals_FlavorElectrician"},
    {id = "engineer", name = "Engineer", nameKey = "UI_BurdJournals_ProfEngineer", flavorKey = "UI_BurdJournals_FlavorEngineer"},
    {id = "metalworker", name = "Metalworker", nameKey = "UI_BurdJournals_ProfMetalworker", flavorKey = "UI_BurdJournals_FlavorMetalworker"},
    {id = "mechanics", name = "Mechanic", nameKey = "UI_BurdJournals_ProfMechanic", flavorKey = "UI_BurdJournals_FlavorMechanic"},
    {id = "veteran", name = "Veteran", nameKey = "UI_BurdJournals_ProfVeteran", flavorKey = "UI_BurdJournals_FlavorVeteran"},
    {id = "unemployed", name = "Unemployed", nameKey = "UI_BurdJournals_ProfUnemployed", flavorKey = "UI_BurdJournals_FlavorUnemployed"},
}

BurdJournals.WorldSpawn.SkillProfessionMap = {

    Aiming = {"policeofficer", "veteran", "securityguard", "parkranger"},
    Reloading = {"policeofficer", "veteran", "securityguard"},

    Axe = {"lumberjack", "fireofficer", "parkranger"},
    Blunt = {"constructionworker", "securityguard", "burglar"},
    SmallBlunt = {"burglar", "securityguard"},
    SmallBlade = {"chef", "burglar", "doctor"},
    LongBlade = {"veteran", "securityguard"},
    Spear = {"parkranger", "fisherman"},

    Carpentry = {"carpenter", "constructionworker", "lumberjack"},
    Woodwork = {"carpenter", "lumberjack"},
    Metalworking = {"metalworker", "engineer", "mechanics"},
    Electricity = {"electrician", "engineer"},
    Mechanics = {"mechanics", "repairman", "engineer"},

    Farming = {"farmer", "parkranger"},
    Fishing = {"fisherman", "parkranger"},
    Trapping = {"parkranger", "farmer"},
    Foraging = {"parkranger", "farmer", "fisherman"},
    PlantScavenging = {"farmer", "parkranger"},

    Doctor = {"doctor", "nurse", "fireofficer"},
    FirstAid = {"doctor", "nurse", "fireofficer", "policeofficer"},

    Cooking = {"chef", "burgerflipper", "farmer"},

    Fitness = {"fitnessInstructor", "fireofficer", "policeofficer", "veteran"},
    Strength = {"fitnessInstructor", "constructionworker", "lumberjack", "fireofficer"},
    Sprinting = {"fitnessInstructor", "burglar", "policeofficer"},

    Lightfoot = {"burglar", "parkranger"},
    Nimble = {"burglar", "fitnessInstructor"},
    Sneak = {"burglar", "parkranger", "veteran"},

    Tailoring = {"unemployed", "nurse"},

    Maintenance = {"repairman", "mechanics", "constructionworker"},
}

function BurdJournals.WorldSpawn.inferProfessionFromSkills(skills)
    if not skills then
        return BurdJournals.WorldSpawn.getRandomProfession()
    end

    local professionScores = {}

    for skillName, _ in pairs(skills) do
        local matchingProfessions = BurdJournals.WorldSpawn.SkillProfessionMap[skillName]
        if matchingProfessions then
            for i, profId in ipairs(matchingProfessions) do

                local weight = #matchingProfessions - i + 1
                professionScores[profId] = (professionScores[profId] or 0) + weight
            end
        end
    end

    local bestProfId = nil
    local bestScore = 0
    for profId, score in pairs(professionScores) do
        if score > bestScore then
            bestScore = score
            bestProfId = profId
        end
    end

    if bestProfId then
        for _, prof in ipairs(BurdJournals.WorldSpawn.Professions) do
            if prof.id == bestProfId then
                -- Get translated name, with robust fallback for server-side getText() issues
                local profName = nil
                if prof.nameKey then
                    local translated = getText(prof.nameKey)
                    if translated and translated ~= "" and translated ~= prof.nameKey then
                        profName = translated
                    end
                end
                if not profName or profName == "" then
                    profName = prof.name
                end
                return prof.id, profName, prof.flavorKey
            end
        end
    end

    return BurdJournals.WorldSpawn.getRandomProfession()
end

function BurdJournals.WorldSpawn.getRandomProfession()
    local professions = BurdJournals.WorldSpawn.Professions
    local prof = professions[ZombRand(#professions) + 1]

    -- Get translated name, with robust fallback for server-side getText() issues
    local profName = nil
    if prof.nameKey then
        local translated = getText(prof.nameKey)
        -- Check for valid translation (not nil, not empty, not the key itself)
        if translated and translated ~= "" and translated ~= prof.nameKey then
            profName = translated
        end
    end
    -- Fallback to plain name if translation failed
    if not profName or profName == "" then
        profName = prof.name
    end
    
    return prof.id, profName, prof.flavorKey
end

function BurdJournals.WorldSpawn.generateWornJournalData()
    local survivorName = BurdJournals.WorldSpawn.SurvivorNames[ZombRand(#BurdJournals.WorldSpawn.SurvivorNames) + 1]
    local professionId, professionName, flavorKey = BurdJournals.WorldSpawn.getRandomProfession()

    local minXP = BurdJournals.getSandboxOption("WornJournalMinXP") or 25
    local maxXP = BurdJournals.getSandboxOption("WornJournalMaxXP") or 75
    local minSkills = BurdJournals.getSandboxOption("WornJournalMinSkills") or 1
    local maxSkills = BurdJournals.getSandboxOption("WornJournalMaxSkills") or 2

    local numSkills = ZombRand(minSkills, maxSkills + 1)

    local availableSkills = {}
    local allSkills = BurdJournals.getAllowedSkills()
    for _, skill in ipairs(allSkills) do
        table.insert(availableSkills, skill)
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

        -- Validate skill has a real perk before adding to journal
        local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
        if not perk then
            BurdJournals.debugPrint("[BurdJournals] WorldSpawn: Skipped invalid skill '" .. tostring(skillName) .. "' (no perk found)")
        else
            local skillXP = ZombRand(minXP, maxXP + 1)

            local level = BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(skillXP, skillName) or 0

            skills[skillName] = {
                xp = skillXP,
                level = level
            }
        end
    end

    local recipes = nil
    local recipeChance = BurdJournals.getSandboxOption("WornJournalRecipeChance") or 15
    if ZombRand(100) < recipeChance then
        local maxRecipes = BurdJournals.getSandboxOption("WornJournalMaxRecipes") or 1
        local numRecipes = ZombRand(1, maxRecipes + 1)
        recipes = BurdJournals.generateRandomRecipes(numRecipes)
    end

    -- Optional trait generation for worn journals (default 0% chance)
    local traits = nil
    local traitChance = BurdJournals.getSandboxOption("WornJournalTraitChance") or 0
    if traitChance > 0 and ZombRand(100) < traitChance then
        local traitList = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or 
                          BurdJournals.GRANTABLE_TRAITS or {}
        local listSize = #traitList
        
        if listSize > 0 then
            local minTraits = BurdJournals.getSandboxOption("WornJournalMinTraits") or 1
            local maxTraits = BurdJournals.getSandboxOption("WornJournalMaxTraits") or 1
            if minTraits < 1 then minTraits = 1 end
            if maxTraits < minTraits then maxTraits = minTraits end
            if maxTraits > listSize then maxTraits = listSize end
            
            local numTraits = ZombRand(minTraits, maxTraits + 1)
            
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

    local journalData = {
        uuid = BurdJournals.generateUUID(),
        author = survivorName,
        profession = professionId,
        professionName = professionName,
        flavorKey = flavorKey,
        timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
        skills = skills,
        recipes = recipes,
        traits = traits,

        isWorn = true,
        isBloody = false,
        wasFromBloody = false,
        isPlayerCreated = false,

        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {},
    }

    return journalData
end

function BurdJournals.WorldSpawn.generateBloodyJournalData()
    local survivorName = BurdJournals.generateRandomSurvivorName()
    local professionId, professionName, flavorKey = BurdJournals.WorldSpawn.getRandomProfession()

    local minXP = BurdJournals.getSandboxOption("BloodyJournalMinXP") or 50
    local maxXP = BurdJournals.getSandboxOption("BloodyJournalMaxXP") or 150
    local minSkills = BurdJournals.getSandboxOption("BloodyJournalMinSkills") or 2
    local maxSkills = BurdJournals.getSandboxOption("BloodyJournalMaxSkills") or 4
    local traitChance = BurdJournals.getSandboxOption("BloodyJournalTraitChance") or 15

    local numSkills = ZombRand(minSkills, maxSkills + 1)

    local availableSkills = {}
    local allSkills = BurdJournals.getAllowedSkills()
    for _, skill in ipairs(allSkills) do
        table.insert(availableSkills, skill)
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

        -- Validate skill has a real perk before adding to journal
        local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
        if not perk then
            BurdJournals.debugPrint("[BurdJournals] WorldSpawn: Skipped invalid skill '" .. tostring(skillName) .. "' (no perk found)")
        else
            local skillXP = ZombRand(minXP, maxXP + 1)

            local level = BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(skillXP, skillName) or 0

            skills[skillName] = {
                xp = skillXP,
                level = level
            }
        end
    end

    local traits = {}
    if ZombRand(100) < traitChance then
        local grantableTraits = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or BurdJournals.GRANTABLE_TRAITS or {}
        if #grantableTraits > 0 then

            local maxTraits = SandboxVars.BurdJournals and SandboxVars.BurdJournals.BloodyJournalMaxTraits or 2
            local numTraits = ZombRand(1, maxTraits + 1)
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

    local recipes = nil
    local recipeChance = BurdJournals.getSandboxOption("BloodyJournalRecipeChance") or 35
    local recipeRoll = ZombRand(100)
    BurdJournals.debugPrint("[BurdJournals] WorldSpawn Bloody: recipeChance=" .. recipeChance .. ", roll=" .. recipeRoll)
    if recipeRoll < recipeChance then
        local maxRecipes = BurdJournals.getSandboxOption("BloodyJournalMaxRecipes") or 2
        local numRecipes = ZombRand(1, maxRecipes + 1)
        BurdJournals.debugPrint("[BurdJournals] WorldSpawn Bloody: Attempting to generate " .. numRecipes .. " recipes")
        recipes = BurdJournals.generateRandomRecipes(numRecipes)
        local recipeCount = 0
        if recipes then
            for _ in pairs(recipes) do recipeCount = recipeCount + 1 end
        end
        BurdJournals.debugPrint("[BurdJournals] WorldSpawn Bloody: Generated " .. recipeCount .. " recipes")
        -- If no recipes were found, set to nil so it doesn't appear as empty
        if recipeCount == 0 then
            recipes = nil
        end
    else
        BurdJournals.debugPrint("[BurdJournals] WorldSpawn Bloody: Recipe roll failed (" .. recipeRoll .. " >= " .. recipeChance .. ")")
    end

    local journalData = {
        uuid = BurdJournals.generateUUID(),
        author = survivorName,
        profession = professionId,
        professionName = professionName,
        flavorKey = flavorKey,
        timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
        skills = skills,
        traits = traits,
        recipes = recipes,

        isWorn = false,
        isBloody = true,
        wasFromBloody = true,
        isPlayerCreated = false,
        condition = ZombRand(1, 4),

        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {},
    }

    return journalData
end

function BurdJournals.WorldSpawn.initializeJournalIfNeeded(item)
    if not item then return false end

    local fullType = item:getFullType()
    local modData = item:getModData()

    if modData.BurdJournals then

        local hasData = modData.BurdJournals.uuid or
                        modData.BurdJournals.skills or
                        modData.BurdJournals.author or
                        modData.BurdJournals.isWritten ~= nil
        if hasData then
            local needsTransmit = false

            if not modData.BurdJournals.uuid then
                modData.BurdJournals.uuid = BurdJournals.generateUUID()
                needsTransmit = true
            end

            if not modData.BurdJournals.professionName and modData.BurdJournals.skills then

                if not modData.BurdJournals.isPlayerCreated then

                    local professionId, professionName, flavorKey = BurdJournals.WorldSpawn.inferProfessionFromSkills(modData.BurdJournals.skills)
                    modData.BurdJournals.profession = professionId
                    modData.BurdJournals.professionName = professionName
                    modData.BurdJournals.flavorKey = flavorKey
                    needsTransmit = true
                    BurdJournals.debugPrint("[BurdJournals] Migrated journal with inferred profession: " .. professionName)
                end
            end

            if needsTransmit and item.transmitModData then
                item:transmitModData()
            end
            return false
        end
    end

    local journalData = nil

    if fullType == "BurdJournals.FilledSurvivalJournal_Worn" then
        journalData = BurdJournals.WorldSpawn.generateWornJournalData()
        if BurdJournals.isDebug() then

        end

    elseif fullType == "BurdJournals.FilledSurvivalJournal_Bloody" then
        journalData = BurdJournals.WorldSpawn.generateBloodyJournalData()
        if BurdJournals.isDebug() then

        end

    elseif fullType == "BurdJournals.FilledSurvivalJournal" then

        local survivorName = BurdJournals.WorldSpawn.SurvivorNames[ZombRand(#BurdJournals.WorldSpawn.SurvivorNames) + 1]
        local professionId, professionName, flavorKey = BurdJournals.WorldSpawn.getRandomProfession()
        journalData = {
            uuid = BurdJournals.generateUUID(),
            author = survivorName,
            profession = professionId,
            professionName = professionName,
            flavorKey = flavorKey,
            timestamp = getGameTime():getWorldAgeHours() - ZombRand(24, 720),
            skills = BurdJournals.generateRandomSkills(2, 4, 50, 150),
            traits = {},
            isWorn = false,
            isBloody = false,
            wasFromBloody = false,
            wasRestored = true,
            isPlayerCreated = false,
            condition = 10,
            claimedSkills = {},
            claimedTraits = {},
        }
        if BurdJournals.isDebug() then

        end

    elseif fullType == "BurdJournals.BlankSurvivalJournal" then
        journalData = {
            uuid = BurdJournals.generateUUID(),
            condition = 10,
            isWorn = false,
            isBloody = false,
            isWritten = false,
        }

    elseif fullType == "BurdJournals.BlankSurvivalJournal_Worn" then
        journalData = {
            uuid = BurdJournals.generateUUID(),
            condition = ZombRand(3, 7),
            isWorn = true,
            isBloody = false,
            isWritten = false,
        }

    elseif fullType == "BurdJournals.BlankSurvivalJournal_Bloody" then
        journalData = {
            uuid = BurdJournals.generateUUID(),
            condition = ZombRand(1, 4),
            isWorn = false,
            isBloody = true,
            isWritten = false,
        }
    end

    if journalData then
        modData.BurdJournals = journalData
        BurdJournals.updateJournalName(item)
        BurdJournals.updateJournalIcon(item)

        if isServer() and item.transmitModData then
            item:transmitModData()
        end

        return true
    end

    return false
end

function BurdJournals.WorldSpawn.onItemCreated(item)
    if not item then return end
    if not BurdJournals.isEnabled() then return end

    BurdJournals.WorldSpawn.initializeJournalIfNeeded(item)
end

local function isUninitializedJournal(item)
    if not item then return false end
    local fullType = item:getFullType()
    if not fullType then return false end

    if not fullType:find("^BurdJournals%.") then
        return false
    end

    if fullType:find("FilledSurvivalJournal") then
        local modData = item:getModData()

        return not modData.BurdJournals or not modData.BurdJournals.skills
    end

    if fullType:find("BlankSurvivalJournal") then
        local modData = item:getModData()
        return not modData.BurdJournals
    end

    return false
end

local function safeGetContainerItems(container)
    if not container then return nil end

    if instanceof(container, "ItemContainer") then
        local items = container:getItems()
        return items
    end

    if container.getContainer then
        local actualContainer = container:getContainer()
        if actualContainer and instanceof(actualContainer, "ItemContainer") then
            local items = actualContainer:getItems()
            return items
        end
    end

    return nil
end

Events.LoadGridsquare.Add(function(square)

    if isClient() and not isServer() then return end

    if not square then return end
    if not BurdJournals.isEnabled() then return end

    local objects = square:getObjects()
    if not objects then return end

    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj then
            local container = obj:getContainer()
            if container then
                local items = safeGetContainerItems(container)
                if items then
                    for j = 0, items:size() - 1 do
                        local item = items:get(j)
                        if isUninitializedJournal(item) then
                            BurdJournals.WorldSpawn.initializeJournalIfNeeded(item)
                        end
                    end
                end
            end
        end
    end
end)

local lastInventoryCheck = {}

local function checkPlayerInventory(player)
    if not player then return end
    if not BurdJournals.isEnabled() then return end

    local inventory = player:getInventory()
    if not inventory then return end

    local allItems = nil
    if inventory.getAllRecursive then
        allItems = inventory:getAllRecursive()
    end
    if not allItems and inventory.getItems then
        allItems = inventory:getItems()
    end
    if not allItems or not allItems.size then return end

    for i = 0, allItems:size() - 1 do
        local item = allItems:get(i)
        if isUninitializedJournal(item) then
            BurdJournals.WorldSpawn.initializeJournalIfNeeded(item)
        end
    end
end

Events.OnPlayerUpdate.Add(function(player)

    if isClient() and not isServer() then return end

    if not player then return end
    local playerId = player:getOnlineID() or 0

    local tick = getTimestamp and getTimestamp() or 0
    if lastInventoryCheck[playerId] and (tick - lastInventoryCheck[playerId]) < 2000 then
        return
    end
    lastInventoryCheck[playerId] = tick

    checkPlayerInventory(player)
end)

-- Helper to check if item is a BurdJournals item (any type)
local function isBurdJournalItem(item)
    if not item then return false end
    local fullType = item:getFullType()
    return fullType and fullType:find("^BurdJournals%.") ~= nil
end

if Events.OnContainerUpdate then
    Events.OnContainerUpdate.Add(function(container)

        if isClient() and not isServer() then return end

        if not container then return end
        if not BurdJournals.isEnabled() then return end

        local items = safeGetContainerItems(container)
        if not items then return end

        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if isUninitializedJournal(item) then
                BurdJournals.WorldSpawn.initializeJournalIfNeeded(item)
            elseif isBurdJournalItem(item) then
                -- Check if this journal has a custom name that needs restoring
                -- This fixes the MP bug where custom names are lost on item transfer
                local modData = item:getModData()
                if modData.BurdJournals and modData.BurdJournals.customName then
                    local currentName = item:getName()
                    if currentName ~= modData.BurdJournals.customName then
                        BurdJournals.updateJournalName(item)
                        if item.transmitModData then
                            item:transmitModData()
                        end
                    end
                end
            end
        end
    end)
end
