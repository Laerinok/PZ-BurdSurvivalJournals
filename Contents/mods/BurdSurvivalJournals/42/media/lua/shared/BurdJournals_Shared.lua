-- CRITICAL: Capture Lua builtins at module load time BEFORE any other mod can overwrite them
-- Some mods overwrite global functions, causing "Object tried to call nil" errors
-- We use rawget to access the original builtins from _G to avoid any metatable shenanigans
local _G = _G or getfenv(0)
local _safePcall = rawget(_G, "pcall") or pcall
local _safeNext = rawget(_G, "next") or next
local _safePairs = rawget(_G, "pairs") or pairs
local _safeType = rawget(_G, "type") or type
local _safeTostring = rawget(_G, "tostring") or tostring
local _safeIpairs = rawget(_G, "ipairs") or ipairs

-- Verify captures worked (fallback to direct reference if rawget failed)
if not _safePcall then _safePcall = pcall end
if not _safeNext then _safeNext = next end
if not _safePairs then _safePairs = pairs end
if not _safeType then _safeType = type end

-- Safe wrapper that handles pcall being nil (returns false, nil if pcall unavailable)
local function safePcall(func, ...)
    if _safePcall then
        return _safePcall(func, ...)
    end
    -- Last resort: direct call (may throw)
    return true, func(...)
end

BurdJournals = BurdJournals or {}

BurdJournals.VERSION = "2.4.6"
BurdJournals.MOD_ID = "BurdSurvivalJournals"

-- Expose safePcall for use throughout the mod
BurdJournals.safePcall = safePcall

-- Safe event removal helper (avoids pcall spam and stale handler tracking)
function BurdJournals.safeRemoveEvent(eventTable, handlerFunc)
    if not eventTable or not handlerFunc then return false end
    if not eventTable.Remove then return false end
    local ok = safePcall(function() eventTable.Remove(handlerFunc) end)
    return ok == true
end

-- Normalize Java-backed tables/lists into plain Lua tables for safe iteration
function BurdJournals.normalizeTable(tbl)
    if not tbl then return nil end
    local pairsFn = (_safeType and _safeType(_safePairs) == "function") and _safePairs or nil

    -- Fast path: standard Lua table
    if _safeType and _safeType(tbl) == "table" then
        if not pairsFn then return nil end
        local ok, result = safePcall(function()
            local t = {}
            for k, v in pairsFn(tbl) do
                t[k] = v
            end
            return t
        end)
        if ok and result then return result end
    end

    -- Java/Kahlua map style (iterable via pairs but not a Lua table type)
    -- Keep list handling below for size/get-only objects.
    if pairsFn then
        local ok, result, hadEntries = safePcall(function()
            local t = {}
            local seen = false
            for k, v in pairsFn(tbl) do
                seen = true
                t[k] = v
            end
            return t, seen
        end)
        if ok and result then
            if hadEntries or not (tbl.size and tbl.get) then
                return result
            end
        end
    end

    -- Java list/array style (size/get)
    if tbl.size and tbl.get then
        local t = {}
        local size = tbl:size()
        for i = 0, size - 1 do
            t[i + 1] = tbl:get(i)
        end
        return t
    end

    return nil
end

-- Check if a table-like object has any entries (safe for Java-backed ModData)
function BurdJournals.hasAnyEntries(tbl)
    local normalized = BurdJournals.normalizeTable(tbl)
    if not normalized then return false end
    if _safeType and _safeType(normalized) ~= "table" then
        if normalized.size and normalized.get then
            return (normalized:size() or 0) > 0
        end
        return false
    end

    -- Guard against environments/mods where global next()/pairs() may be missing/overridden.
    if _safeType and _safeType(_safeNext) == "function" then
        local ok, firstKey = safePcall(function() return _safeNext(normalized) end)
        if ok then
            return firstKey ~= nil
        end
    end

    -- Fallback iteration path.
    if _safeType and _safeType(_safePairs) == "function" then
        local ok, hasEntries = safePcall(function()
            for _, _ in _safePairs(normalized) do
                return true
            end
            return false
        end)
        if ok then
            return hasEntries == true
        end
    end

    return false
end

-- Normalize journal data (shallow) so UI can safely iterate without pcall
function BurdJournals.normalizeJournalData(journalData)
    if not journalData or (_safeType and _safeType(journalData) ~= "table") then return nil end

    local pairsFn = (_safeType and _safeType(_safePairs) == "function") and _safePairs or nil
    if not pairsFn then return nil end

    local normalized = {}
    for k, v in pairsFn(journalData) do
        normalized[k] = v
    end

    normalized.skills = BurdJournals.normalizeTable(journalData.skills) or {}
    normalized.traits = BurdJournals.normalizeTable(journalData.traits) or {}
    normalized.recipes = BurdJournals.normalizeTable(journalData.recipes) or {}
    normalized.stats = BurdJournals.normalizeTable(journalData.stats) or {}
    normalized.claims = BurdJournals.normalizeTable(journalData.claims) or {}
    normalized.claimedForgetSlot = BurdJournals.normalizeTable(journalData.claimedForgetSlot) or {}
    normalized.forgetSlot = journalData.forgetSlot == true
    normalized.isCursedJournal = journalData.isCursedJournal == true
    normalized.isCursedReward = journalData.isCursedReward == true
    if normalized.isCursedJournal or normalized.isCursedReward then
        normalized.cursedState = (journalData.cursedState == "unleashed") and "unleashed" or "dormant"
    else
        normalized.cursedState = nil
    end
    normalized.cursedEffectType = journalData.cursedEffectType
    normalized.cursedUnleashedByCharacterId = journalData.cursedUnleashedByCharacterId
    normalized.cursedUnleashedByUsername = journalData.cursedUnleashedByUsername
    normalized.cursedUnleashedAtHours = tonumber(journalData.cursedUnleashedAtHours) or nil
    normalized.cursedSealSoundEvent = journalData.cursedSealSoundEvent
    normalized.cursedForcedEffectType = journalData.cursedForcedEffectType
    normalized.cursedForcedTraitId = journalData.cursedForcedTraitId
    normalized.cursedForcedSkillName = journalData.cursedForcedSkillName
    normalized.cursedPendingRewards = BurdJournals.normalizeTable(journalData.cursedPendingRewards)

    return normalized
end

-- ============================================================================
-- Shared Skill/Trait Helpers (centralized for UI + server usage)
-- ============================================================================

function BurdJournals.normalizeTraitId(traitId)
    if not traitId then return nil end
    local id = tostring(traitId)
    id = string.gsub(id, "^base:", "")
    id = string.gsub(id, "^Base%.", "")
    return id
end

function BurdJournals.buildTraitLookup(traitsTable)
    local lookup = {}
    if not traitsTable then return lookup end

    local tableToScan = BurdJournals.normalizeTable(traitsTable) or traitsTable
    for traitId, _ in pairs(tableToScan) do
        if traitId then
            local normalized = BurdJournals.normalizeTraitId(traitId) or traitId
            lookup[normalized] = true
            lookup[string.lower(tostring(normalized))] = true

            if BurdJournals.getTraitAliases then
                for _, alias in ipairs(BurdJournals.getTraitAliases(normalized)) do
                    if alias then
                        local aliasNorm = BurdJournals.normalizeTraitId(alias) or alias
                        lookup[aliasNorm] = true
                        lookup[string.lower(tostring(aliasNorm))] = true
                    end
                end
            end
        end
    end

    return lookup
end

function BurdJournals.isTraitInLookup(lookup, traitId)
    if not lookup or not traitId then return false end
    local normalized = BurdJournals.normalizeTraitId(traitId) or traitId
    if lookup[normalized] or lookup[string.lower(tostring(normalized))] then
        return true
    end
    if BurdJournals.getTraitAliases then
        for _, alias in ipairs(BurdJournals.getTraitAliases(normalized)) do
            local aliasNorm = BurdJournals.normalizeTraitId(alias) or alias
            if lookup[aliasNorm] or lookup[string.lower(tostring(aliasNorm))] then
                return true
            end
        end
    end
    return false
end

function BurdJournals.removeTraitFromTable(traitsTable, traitId)
    if not traitsTable or not traitId then return false end
    local removed = false
    local normalized = BurdJournals.normalizeTraitId(traitId) or traitId
    local normalizedLower = string.lower(tostring(normalized))

    local tableToScan = BurdJournals.normalizeTable(traitsTable) or traitsTable
    for key, _ in pairs(tableToScan) do
        local keyNorm = BurdJournals.normalizeTraitId(key) or key
        if (BurdJournals.traitIdsMatch and BurdJournals.traitIdsMatch(keyNorm, normalized))
            or string.lower(tostring(keyNorm)) == normalizedLower then
            traitsTable[key] = nil
            removed = true
        end
    end

    return removed
end

function BurdJournals.resolveSkillKey(skillsTable, skillName)
    if not skillsTable or not skillName then return skillName end

    if skillsTable[skillName] ~= nil then
        return skillName
    end

    local tableToScan = BurdJournals.normalizeTable(skillsTable) or skillsTable
    local skillLower = string.lower(tostring(skillName))
    for key, _ in pairs(tableToScan) do
        if string.lower(tostring(key)) == skillLower then
            return key
        end
    end

    -- Try mapping perkId -> skill name (e.g., Woodwork -> Carpentry)
    if BurdJournals.mapPerkIdToSkillName then
        local mapped = BurdJournals.mapPerkIdToSkillName(skillName)
        if mapped and skillsTable[mapped] ~= nil then
            return mapped
        end
    end

    -- Try mapping skill name -> perkId (e.g., Carpentry -> Woodwork)
    if BurdJournals.SKILL_TO_PERK then
        local perkId = BurdJournals.SKILL_TO_PERK[skillName]
        if perkId and skillsTable[perkId] ~= nil then
            return perkId
        end
        for skillKey, perkKey in pairs(BurdJournals.SKILL_TO_PERK) do
            if string.lower(skillKey) == skillLower and skillsTable[perkKey] ~= nil then
                return perkKey
            end
        end
    end

    return skillName
end

function BurdJournals.buildTraitCostLookup()
    local lookup = {}
    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allDefs = CharacterTraitDefinition.getTraits()
        if allDefs then
            for i = 0, allDefs:size() - 1 do
                local def = allDefs:get(i)
                if def then
                    local defTraitId = nil
                    local traitType = def.getType and def:getType() or nil
                    if traitType and traitType.getName then
                        defTraitId = traitType:getName()
                    elseif traitType then
                        defTraitId = tostring(traitType):gsub("^base:", "")
                    end
                    if defTraitId then
                        local cost = def.getCost and def:getCost() or 0
                        lookup[string.lower(defTraitId)] = cost
                    end
                end
            end
        end
    end
    return lookup
end

-- Sanitization version - increment to force re-sanitization of all journals
BurdJournals.SANITIZE_VERSION = 1
-- Migration schema version - increment when persistent journal migration logic changes
BurdJournals.MIGRATION_SCHEMA_VERSION = 3

-- Check if an item reference is still valid (not a zombie/invalid Java object)
-- This check uses instanceof which does NOT trigger error logging for zombie objects
function BurdJournals.isValidItem(item)
    if not item then return false end
    -- instanceof returns false for zombie/invalid Java objects without triggering errors
    if instanceof and not instanceof(item, "InventoryItem") then
        return false
    end
    return true
end

BurdJournals.Limits = {

    CHUNK_SKILLS = 10,
    CHUNK_TRAITS = 10,
    CHUNK_RECIPES = 20,
    CHUNK_STATS = 10,

    CHUNK_DELAY_MS = 50,

}

BurdJournals.ModCompat = BurdJournals.ModCompat or {
    registeredRecipes = {},
    excludedRecipes = {},
    registeredMagazines = {},
    registeredTraits = {},
    excludedTraits = {},
    registeredAddons = {},
}

function BurdJournals.registerRecipe(recipeName, magazineType)
    if not recipeName then return false end
    BurdJournals.ModCompat.registeredRecipes[recipeName] = magazineType or "CustomRecipe"

    BurdJournals._magazineRecipeCache = nil
    BurdJournals._magazineToRecipesCache = nil
    BurdJournals.debugPrint("[BurdJournals] Registered recipe: " .. recipeName .. (magazineType and (" from " .. magazineType) or ""))
    return true
end

function BurdJournals.excludeRecipe(recipeName)
    if not recipeName then return false end
    BurdJournals.ModCompat.excludedRecipes[recipeName] = true

    BurdJournals._magazineRecipeCache = nil
    BurdJournals._magazineToRecipesCache = nil
    BurdJournals.debugPrint("[BurdJournals] Excluded recipe: " .. recipeName)
    return true
end

function BurdJournals.registerMagazine(magazineType, recipes)
    if not magazineType or not recipes then return false end
    BurdJournals.ModCompat.registeredMagazines[magazineType] = recipes

    for _, recipeName in ipairs(recipes) do
        BurdJournals.ModCompat.registeredRecipes[recipeName] = magazineType
    end

    BurdJournals._magazineRecipeCache = nil
    BurdJournals._magazineToRecipesCache = nil
    BurdJournals.debugPrint("[BurdJournals] Registered magazine: " .. magazineType .. " with " .. #recipes .. " recipes")
    return true
end

function BurdJournals.registerTrait(traitId)
    if not traitId then return false end
    BurdJournals.ModCompat.registeredTraits[string.lower(traitId)] = true

    BurdJournals._cachedGrantableTraits = nil
    BurdJournals._cachedAllTraits = nil
    BurdJournals.debugPrint("[BurdJournals] Registered trait: " .. traitId)
    return true
end

function BurdJournals.excludeTrait(traitId)
    if not traitId then return false end
    BurdJournals.ModCompat.excludedTraits[string.lower(traitId)] = true

    table.insert(BurdJournals.EXCLUDED_TRAITS, string.lower(traitId))

    BurdJournals._cachedGrantableTraits = nil
    BurdJournals._cachedAllTraits = nil
    BurdJournals.debugPrint("[BurdJournals] Excluded trait: " .. traitId)
    return true
end

function BurdJournals.isRecipeExcluded(recipeName)
    if not recipeName then return false end
    return BurdJournals.ModCompat.excludedRecipes[recipeName] == true
end

function BurdJournals.isTraitExcludedByMod(traitId)
    if not traitId then return false end
    return BurdJournals.ModCompat.excludedTraits[string.lower(traitId)] == true
end

function BurdJournals.getModRegisteredRecipes()
    return BurdJournals.ModCompat.registeredRecipes
end

function BurdJournals.getModRegisteredMagazines()
    return BurdJournals.ModCompat.registeredMagazines
end

function BurdJournals.getModRegisteredTraits()
    return BurdJournals.ModCompat.registeredTraits
end

function BurdJournals.registerAddon(addonId, version)
    if not addonId or addonId == "" then return false end
    BurdJournals.ModCompat.registeredAddons[addonId] = version or true
    BurdJournals.debugPrint("[BurdJournals] Registered addon: " .. tostring(addonId) .. " (" .. tostring(version or "unknown") .. ")")
    return true
end

function BurdJournals.isAddonRegistered(addonId)
    if not addonId or addonId == "" then return false end
    return BurdJournals.ModCompat.registeredAddons[addonId] ~= nil
end

function BurdJournals.generateUUID()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    local uuid = string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and ZombRand(0, 16) or ZombRand(8, 12)
        return string.format("%x", v)
    end)
    return uuid
end

function BurdJournals.findJournalByUUID(player, uuid)
    if not player or not uuid then return nil end

    local inventory = player:getInventory()
    if inventory then
        local found = BurdJournals.findJournalByUUIDInContainer(inventory, uuid)
        if found then return found end
    end

    if getPlayerLoot and not isServer() then
        local playerNum = player:getPlayerNum()
        if playerNum then
            local lootInventory = getPlayerLoot(playerNum)
            if lootInventory and lootInventory.inventoryPane then
                local inventoryPane = lootInventory.inventoryPane
                if inventoryPane.inventories then
                    for i = 1, #inventoryPane.inventories do
                        local containerInfo = inventoryPane.inventories[i]
                        if containerInfo and containerInfo.inventory then
                            local found = BurdJournals.findJournalByUUIDInContainer(containerInfo.inventory, uuid)
                            if found then return found end
                        end
                    end
                end
            end
        end
    end

    local square = player:getCurrentSquare()
    if square then
        for dx = -1, 1 do
            for dy = -1, 1 do
                local nearSquare = getCell():getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ())
                if nearSquare then
                    local objects = nearSquare:getObjects()
                    if objects then
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if obj and obj.getContainer then
                                local container = obj:getContainer()
                                if container then
                                    local found = BurdJournals.findJournalByUUIDInContainer(container, uuid)
                                    if found then return found end
                                end
                            end
                            if obj and obj.getInventory then
                                local container = obj:getInventory()
                                if container then
                                    local found = BurdJournals.findJournalByUUIDInContainer(container, uuid)
                                    if found then return found end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

function BurdJournals.findJournalByUUIDInContainer(container, uuid)
    if not container then return nil end

    local items = container:getItems()
    if not items then return nil end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local fullType = item:getFullType()

            if fullType and fullType:find("^BurdJournals%.") then
                local modData = item:getModData()
                if modData and modData.BurdJournals and modData.BurdJournals.uuid == uuid then
                    return item
                end
            end

            if item.getInventory then
                local itemInventory = item:getInventory()
                if itemInventory then
                    local found = BurdJournals.findJournalByUUIDInContainer(itemInventory, uuid)
                    if found then return found end
                end
            end
        end
    end
    return nil
end

BurdJournals.SKILL_CATEGORIES = {
    -- Physical/Passive skills (special XP handling)
    Passive = {
        "Fitness",
        "Strength"
    },
    -- Combat - Firearms
    Firearm = {
        "Aiming",
        "Reloading"
    },
    -- Combat - Melee
    Melee = {
        "Axe",
        "Blunt",          -- Long Blunt
        "SmallBlunt",     -- Short Blunt
        "LongBlade",
        "SmallBlade",     -- Short Blade (also maps via ShortBlade)
        "Spear",
        "Maintenance"
    },
    -- Crafting skills (B42 expanded)
    Crafting = {
        "Woodwork",       -- Carpentry
        "Cooking",
        "Electricity",    -- Electrical
        "MetalWelding",   -- Welding/Metalworking
        "Mechanics",
        "Tailoring",
        "Blacksmith",     -- Blacksmithing
        "Glassmaking",
        "Pottery",
        "Masonry",
        "Carving",
        "FlintKnapping"   -- Knapping
    },
    -- Farming skills (B42)
    Farming = {
        "Farming",        -- Agriculture
        "Husbandry",      -- Animal Care
        "Butchering"
    },
    -- Survival skills
    Survival = {
        "Fishing",
        "Trapping",
        "PlantScavenging", -- Foraging
        "Tracking",
        "Doctor"          -- First Aid
    },
    -- Agility skills
    Agility = {
        "Sprinting",      -- Running
        "Lightfoot",      -- Lightfooted (will try mapping)
        "Nimble",
        "Sneak"           -- Sneaking (will try mapping)
    }
}

-- Extended mappings for skill name variations (display name -> perk ID)
-- This helps handle cases where UI names differ from internal perk names

-- Skill name to internal perk ID mappings
-- Maps common/display names to actual perk IDs
BurdJournals.SKILL_TO_PERK = {
    -- Survival
    Foraging = "PlantScavenging",
    ["First Aid"] = "Doctor",
    FirstAid = "Doctor",
    -- Crafting
    Carpentry = "Woodwork",
    Electrical = "Electricity",
    Electric = "Electricity",
    Welding = "MetalWelding",
    Metalworking = "MetalWelding",
    Blacksmithing = "Blacksmith",
    Knapping = "FlintKnapping",
    -- Farming
    Agriculture = "Farming",
    ["Animal Care"] = "Husbandry",
    AnimalCare = "Husbandry",
    -- Melee
    ["Long Blade"] = "LongBlade",
    ["Short Blade"] = "SmallBlade",
    ShortBlade = "SmallBlade",
    ["Long Blunt"] = "Blunt",
    LongBlunt = "Blunt",
    ["Short Blunt"] = "SmallBlunt",
    ShortBlunt = "SmallBlunt",
    -- Agility
    Lightfooted = "Lightfoot",
    Sneaking = "Sneak",
    Running = "Sprinting",
}

BurdJournals.ALL_SKILLS = {}
for category, skills in pairs(BurdJournals.SKILL_CATEGORIES) do
    for _, skill in ipairs(skills) do
        table.insert(BurdJournals.ALL_SKILLS, skill)
    end
end

BurdJournals._cachedDiscoveredSkills = nil

-- NOTE: Category/parent perks are now filtered using isTrainableSkill() which checks
-- perk:getParent():getId() ~= "None". This is more reliable than name-based exclusion.
-- The list below is kept for any edge cases or explicit exclusions.
BurdJournals.EXCLUDED_SKILLS = {
    -- System perks that should never appear
    "None",
    "MAX",
}

-- Helper: Check if a skill is a passive skill (Fitness/Strength type)
-- These skills have special XP handling (5x multiplier) and start at level 5
-- Uses dynamic detection via parent category when possible
function BurdJournals.isPassiveSkill(skillName)
    if not skillName then return false end
    
    -- Try to detect via perk parent category
    local perk = (Perks and BurdJournals.getPerkByName) and BurdJournals.getPerkByName(skillName)
    if perk then
        local parent = perk.getParent and perk:getParent() or nil
        if parent then
            local parentId = parent.getId and parent:getId() or nil
            -- "Passive" is the parent category for Fitness/Strength
            if parentId == "Passive" then
                return true
            end
        end
    end
    
    -- Fallback: check known passive skill names
    local name = tostring(skillName):lower()
    return name == "fitness" or name == "strength"
end

-- Cache for passive skills list
BurdJournals._passiveSkillsCache = nil

-- Get all passive skills dynamically
function BurdJournals.getPassiveSkills()
    if BurdJournals._passiveSkillsCache then
        return BurdJournals._passiveSkillsCache
    end
    
    local passiveSkills = {}
    
    -- Try to discover from PerkFactory
    if PerkFactory and PerkFactory.PerkList then
        local perkList = PerkFactory.PerkList
        for i = 0, perkList:size() - 1 do
            local perk = perkList:get(i)
            if perk then
                local parent = perk.getParent and perk:getParent() or nil
                if parent then
                    local parentId = parent.getId and parent:getId() or nil
                    if parentId == "Passive" then
                        local perkId = perk.getId and perk:getId() or nil
                        if perkId then
                            table.insert(passiveSkills, perkId)
                        end
                    end
                end
            end
        end
    end
    
    -- Fallback if discovery fails
    if #passiveSkills == 0 then
        passiveSkills = {"Fitness", "Strength"}
    end
    
    BurdJournals._passiveSkillsCache = passiveSkills
    return passiveSkills
end

-- Helper: Check if a perk is an actual trainable skill (not a category/parent perk)
-- Parent perks have getParent():getId() == "None", trainable skills have a real parent
function BurdJournals.isTrainableSkill(perk)
    if not perk then return false end

    local isTrainable = false
    local parent = perk.getParent and perk:getParent() or nil
    if parent then
        local parentId = parent.getId and parent:getId() or nil
        -- If parent ID is "None", this IS a category perk, not trainable
        isTrainable = parentId ~= "None"
    end
    return isTrainable
end

-- ============================================================================
-- ENHANCED SKILL/TRAIT DISCOVERY SYSTEM
-- Automatically discovers all skills (vanilla + modded) with full metadata
-- ============================================================================

-- Cache for skill metadata (richer than just names)
BurdJournals._cachedSkillMetadata = nil

-- Discover all skills with full metadata from PerkFactory
-- Returns: { [perkId] = { id, displayName, category, isVanilla, isPassive, maxLevel } }
function BurdJournals.discoverSkillMetadata(forceRefresh)
    if not forceRefresh and BurdJournals._cachedSkillMetadata then
        return BurdJournals._cachedSkillMetadata
    end
    
    local metadata = {}
    
    -- Build vanilla skill set for detection
    local vanillaSkillSet = BurdJournals.getVanillaSkillSet and BurdJournals.getVanillaSkillSet() or {}
    
    -- Discover ALL skills from PerkFactory
    if PerkFactory and PerkFactory.PerkList then
        local perkList = PerkFactory.PerkList
        if perkList and perkList.size then
            for i = 0, perkList:size() - 1 do
                local perk = perkList.get and perkList:get(i) or nil
                if perk then
                    -- Only process trainable skills (not category perks)
                    if BurdJournals.isTrainableSkill(perk) then
                        local skillData = BurdJournals.extractSkillMetadata(perk, vanillaSkillSet)
                        if skillData and skillData.id
                            and not (BurdJournals.isSkillBlockedByModCompat and BurdJournals.isSkillBlockedByModCompat(skillData.id)) then
                            metadata[skillData.id] = skillData
                        end
                    end
                end
            end
        end
    end
    
    -- Count stats
    local vanillaCount, modCount = 0, 0
    for _, data in pairs(metadata) do
        if data.isVanilla then vanillaCount = vanillaCount + 1
        else modCount = modCount + 1 end
    end
    
    BurdJournals.debugPrint(string.format("[BurdJournals] Discovered %d skills (%d vanilla, %d modded)", 
        vanillaCount + modCount, vanillaCount, modCount))
    
    BurdJournals._cachedSkillMetadata = metadata
    return metadata
end

-- Extract metadata from a single perk object
function BurdJournals.extractSkillMetadata(perk, vanillaSkillSet)
    local data = {
        id = nil,
        displayName = nil,
        category = nil,
        categoryDisplayName = nil,
        isVanilla = true,
        isPassive = false,
        maxLevel = 10,
        description = nil
    }
    
    -- Get perk ID
    local perkId = nil
    if perk.getId then perkId = tostring(perk:getId()) end
    if (not perkId or perkId == "") and perk.name then
        perkId = tostring(perk.name())
    end
    if not perkId or perkId == "" then
        local str = tostring(perk)
        str = str:gsub("^zombie%.characters%.skills%.PerkFactory%$Perk%.", "")
        str = str:gsub("^Perks%.", "")
        perkId = str
    end
    if not perkId or perkId == "" then return nil end
    data.id = perkId
    
    -- Get display name from PerkFactory
    if PerkFactory and Perks and PerkFactory.getPerk then
        local perkDef = PerkFactory.getPerk(Perks[perkId])
        if perkDef and perkDef.getName then
            data.displayName = perkDef:getName()
        end
    end
    if not data.displayName then data.displayName = perkId end
    
    -- Get category (parent perk)
    local parent = perk.getParent and perk:getParent() or nil
    if parent then
        data.category = parent.getId and parent:getId() or nil
        -- Try to get category display name
        if PerkFactory and PerkFactory.getPerk then
            local parentDef = PerkFactory.getPerk(parent)
            if parentDef and parentDef.getName then
                data.categoryDisplayName = parentDef:getName()
            end
        end
    end
    if not data.categoryDisplayName then data.categoryDisplayName = data.category end
    
    -- Check if vanilla or modded
    if vanillaSkillSet then
        if BurdJournals.isVanillaSkillName then
            data.isVanilla = BurdJournals.isVanillaSkillName(perkId, vanillaSkillSet)
        else
            data.isVanilla = vanillaSkillSet[string.lower(perkId)] or false
        end
    end
    
    -- Check if passive skill
    data.isPassive = (data.category == "Passive")
    
    -- Get description if available
    if PerkFactory and Perks and PerkFactory.getPerk then
        local perkDef = PerkFactory.getPerk(Perks[perkId])
        if perkDef and perkDef.getDescription then
            data.description = perkDef:getDescription()
        end
    end
    
    -- Log modded skills for debugging
    if not data.isVanilla then
        BurdJournals.debugPrint(string.format("[BurdJournals] Found modded skill: %s (%s) in category %s", 
            data.id, data.displayName, data.category or "Unknown"))
    end
    
    return data
end

-- Get skills organized by category (for UI tabs)
function BurdJournals.getSkillsByCategory(forceRefresh)
    local metadata = BurdJournals.discoverSkillMetadata(forceRefresh)
    local byCategory = {}
    
    for perkId, data in pairs(metadata) do
        local cat = data.category or "Other"
        if not byCategory[cat] then
            byCategory[cat] = {
                id = cat,
                displayName = data.categoryDisplayName or cat,
                skills = {}
            }
        end
        table.insert(byCategory[cat].skills, data)
    end
    
    -- Sort skills within each category by display name
    for _, catData in pairs(byCategory) do
        table.sort(catData.skills, function(a, b)
            return (a.displayName or a.id) < (b.displayName or b.id)
        end)
    end
    
    return byCategory
end

-- Get list of modded skills only
function BurdJournals.getModdedSkills(forceRefresh)
    local metadata = BurdJournals.discoverSkillMetadata(forceRefresh)
    local modded = {}
    
    for perkId, data in pairs(metadata) do
        if not data.isVanilla then
            table.insert(modded, data)
        end
    end
    
    table.sort(modded, function(a, b)
        return (a.displayName or a.id) < (b.displayName or b.id)
    end)
    
    return modded
end

-- Legacy function: returns simple list of skill names (backward compatible)
function BurdJournals.discoverAllSkills(forceRefresh)
    if not forceRefresh and BurdJournals._cachedDiscoveredSkills then
        return BurdJournals._cachedDiscoveredSkills
    end

    local discoveredSkills = {}
    local addedSkillSet = {}

    -- Build vanilla skill set
    local vanillaSkillSet = BurdJournals.getVanillaSkillSet and BurdJournals.getVanillaSkillSet() or {}

    -- First add built-in skills from our known list (preserves order).
    -- Only include skills currently registered in Perks when registry is available.
    -- This prevents optional mod skills from being treated as globally available.
    local canValidateRegistration = (Perks ~= nil) and (BurdJournals.getPerkByName ~= nil)
    for _, skill in ipairs(BurdJournals.ALL_SKILLS) do
        local includeSkill = true
        if canValidateRegistration and not BurdJournals.getPerkByName(skill) then
            includeSkill = false
        end
        if includeSkill then
            table.insert(discoveredSkills, skill)
            addedSkillSet[string.lower(skill)] = true
        end
    end

    -- Mark perk ID mappings as added
    if BurdJournals.SKILL_TO_PERK then
        for skillName, perkId in pairs(BurdJournals.SKILL_TO_PERK) do
            addedSkillSet[string.lower(perkId)] = true
        end
    end

    -- Discover mod-added skills from PerkFactory
    local modSkillsFound = 0
    if PerkFactory and PerkFactory.PerkList then
        local perkList = PerkFactory.PerkList
        if perkList and perkList.size then
            for i = 0, perkList:size() - 1 do
                local perk = perkList.get and perkList:get(i) or nil
                if perk and BurdJournals.isTrainableSkill(perk) then
                    local perkName = nil
                    if perk.getId then
                        perkName = perk:getId() and tostring(perk:getId())
                    end

                    if perkName and perkName ~= "" then
                        local perkNameLower = string.lower(perkName)
                        if not addedSkillSet[perkNameLower]
                            and not (BurdJournals.isSkillBlockedByModCompat and BurdJournals.isSkillBlockedByModCompat(perkName)) then
                            table.insert(discoveredSkills, perkName)
                            addedSkillSet[perkNameLower] = true
                            if not vanillaSkillSet[perkNameLower] then
                                modSkillsFound = modSkillsFound + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if modSkillsFound > 0 then
        BurdJournals.debugPrint("[BurdJournals] Discovered " .. modSkillsFound .. " mod-added skills")
    end

    BurdJournals._cachedDiscoveredSkills = discoveredSkills
    return discoveredSkills
end

function BurdJournals.refreshSkillCache()
    BurdJournals._cachedDiscoveredSkills = nil
    BurdJournals._cachedSkillMetadata = nil
    BurdJournals._cachedTraitMetadata = nil
    BurdJournals.debugPrint("[BurdJournals] Skill/trait cache cleared - will rediscover on next access")
end

-- ============================================================================
-- TRAIT DISCOVERY SYSTEM
-- ============================================================================

BurdJournals._cachedTraitMetadata = nil

-- Discover all traits with metadata from TraitFactory
function BurdJournals.discoverTraitMetadata(forceRefresh)
    if not forceRefresh and BurdJournals._cachedTraitMetadata then
        return BurdJournals._cachedTraitMetadata
    end
    
    local metadata = {}
    
    -- Build known trait sets
    local knownPositive = {}
    local knownNegative = {}
    if BurdJournals.GRANTABLE_TRAITS then
        for _, t in ipairs(BurdJournals.GRANTABLE_TRAITS) do
            knownPositive[string.lower(t)] = true
        end
    end
    if BurdJournals.REMOVABLE_TRAITS then
        for _, t in ipairs(BurdJournals.REMOVABLE_TRAITS) do
            knownNegative[string.lower(t)] = true
        end
    end
    
    -- Discover from TraitFactory
    if TraitFactory then
        local traitsList = TraitFactory.getTraits and TraitFactory.getTraits() or nil
        if traitsList and traitsList.size then
            for i = 0, traitsList:size() - 1 do
                local trait = traitsList.get and traitsList:get(i) or nil
                if trait then
                    local traitData = BurdJournals.extractTraitMetadata(trait, knownPositive, knownNegative)
                    if traitData and traitData.id then
                        metadata[traitData.id] = traitData
                    end
                end
            end
        end
    end
    
    -- Count stats
    local posCount, negCount, modCount = 0, 0, 0
    for _, data in pairs(metadata) do
        if data.isPositive then posCount = posCount + 1
        else negCount = negCount + 1 end
        if not data.isVanilla then modCount = modCount + 1 end
    end
    
    BurdJournals.debugPrint(string.format("[BurdJournals] Discovered %d traits (%d positive, %d negative, %d modded)", 
        posCount + negCount, posCount, negCount, modCount))
    
    BurdJournals._cachedTraitMetadata = metadata
    return metadata
end

-- Extract metadata from a single trait object
function BurdJournals.extractTraitMetadata(trait, knownPositive, knownNegative)
    local data = {
        id = nil,
        displayName = nil,
        description = nil,
        isPositive = true,
        isVanilla = true,
        cost = 0,
        isRemovable = true,
        isFree = false,
        exclusives = {}
    }
    
    -- Get trait ID
    if trait.getType then data.id = trait:getType() end
    if not data.id then return nil end
    
    -- Get display name
    if trait.getLabel then data.displayName = trait:getLabel() end
    if not data.displayName then data.displayName = data.id end
    
    -- Get description
    if trait.getDescription then data.description = trait:getDescription() end
    
    -- Get cost
    -- In PZ trait definitions:
    -- cost > 0 = Positive trait (benefits, player pays points to get)
    -- cost < 0 = Negative trait (drawbacks, player gains points by taking)
    -- cost = 0 = Neutral/profession traits
    if trait.getCost then data.cost = trait:getCost() end
    -- Use polarity function for accurate detection (handles zero-cost fallback)
    local polarity = BurdJournals.determineTraitPolarity(data.id, data.cost)
    data.isPositive = (polarity == true)
    
    -- Check if free trait
    if trait.isFree then data.isFree = trait:isFree() end
    
    -- Check removability
    if trait.isRemovable then data.isRemovable = trait:isRemovable() end
    
    -- Get mutually exclusive traits
    if trait.getMutuallyExclusiveTraits then
        local exclusives = trait:getMutuallyExclusiveTraits()
        if exclusives and exclusives.size then
            for i = 0, exclusives:size() - 1 do
                local ex = exclusives:get(i)
                if ex then table.insert(data.exclusives, tostring(ex)) end
            end
        end
    end
    
    -- Determine if vanilla based on known lists
    local idLower = string.lower(data.id)
    if knownPositive and knownPositive[idLower] then
        data.isVanilla = true
    elseif knownNegative and knownNegative[idLower] then
        data.isVanilla = true
    else
        -- Assume modded if not in our known lists (conservative approach)
        -- This will flag some vanilla traits as modded, which is fine
        data.isVanilla = false
    end
    
    -- Log modded traits
    if not data.isVanilla then
        BurdJournals.debugPrint(string.format("[BurdJournals] Found modded trait: %s (%s) cost=%d", 
            data.id, data.displayName, data.cost))
    end
    
    return data
end

-- Get traits organized by type (positive/negative)
function BurdJournals.getTraitsByType(forceRefresh)
    local metadata = BurdJournals.discoverTraitMetadata(forceRefresh)
    local byType = {
        positive = {},
        negative = {}
    }
    
    for traitId, data in pairs(metadata) do
        if data.isPositive then
            table.insert(byType.positive, data)
        else
            table.insert(byType.negative, data)
        end
    end
    
    -- Sort by display name
    table.sort(byType.positive, function(a, b) return a.displayName < b.displayName end)
    table.sort(byType.negative, function(a, b) return a.displayName < b.displayName end)
    
    return byType
end

-- Get modded traits only
function BurdJournals.getModdedTraits(forceRefresh)
    local metadata = BurdJournals.discoverTraitMetadata(forceRefresh)
    local modded = {}
    
    for traitId, data in pairs(metadata) do
        if not data.isVanilla then
            table.insert(modded, data)
        end
    end
    
    table.sort(modded, function(a, b) return a.displayName < b.displayName end)
    return modded
end

-- Positive traits from PZ wiki that can be granted through journals
-- Comprehensive list including B42 additions
-- NOTE: Excludes passive skill traits (athletic, strong, stout, fit) as they are auto-granted based on skill levels
BurdJournals.GRANTABLE_TRAITS = {
    -- Combat/Survival
    "adrenalinejunkie",     -- Adrenaline Junkie
    "brave",                -- Brave
    "brawler",              -- Brawler
    "desensitized",         -- Desensitized
    "resilient",            -- Resilient
    "thickskinned",         -- Thick Skinned
    
    -- Health/Recovery
    "fasthealer",           -- Fast Healer
    
    -- Stealth/Movement
    "graceful",             -- Graceful
    "inconspicuous",        -- Inconspicuous
    "nightvision",          -- Cat's Eyes
    "nightowl",             -- Night Owl
    "runner",               -- Runner (B42+)
    
    -- Perception
    "keenhearing",          -- Keen Hearing
    "eagleeyed",            -- Eagle Eyed
    
    -- Learning
    "fastlearner",          -- Fast Learner
    "fastreader",           -- Fast Reader
    "inventive",            -- Inventive
    "crafty",               -- Crafty
    
    -- Consumption/Metabolism
    "lighteater",           -- Light Eater
    "lowthirst",            -- Low Thirst
    "needslesssleep",       -- Wakeful (Needs Less Sleep)
    "wakeful",              -- Wakeful (alias)
    "irongut",              -- Iron Gut
    "slowmetabolism",       -- Slow Metabolism (technically positive - burn calories slower)
    
    -- Organization
    "organized",            -- Organized
    "dextrous",             -- Dextrous
    
    -- Outdoor/Survival
    "outdoorsman",          -- Outdoorsman
    "nutritionist",         -- Nutritionist
    "wildernessknowledge",  -- Wilderness Knowledge
    
    -- Driving
    "speeddemon",           -- Speed Demon
    
    -- Occupation/Hobby Traits
    -- NOTE: Use INTERNAL IDs, not display names!
    -- From PZ wiki research: Display Name -> Internal ID
    "Fishing",              -- Angler (INTERNAL ID is "Fishing")
    "artisan",              -- Artisan
    "BaseballPlayer",       -- Baseball Player
    "blacksmith",           -- Blacksmith
    "Cook",                 -- Cook trait (6 pts, "Know cooking recipes")
    "Cook2",                -- Cook profession trait (0 pts, "Know cooking")
    "FirstAid",             -- First Aider (INTERNAL ID is "FirstAid")
    "Formerscout",          -- Former Scout
    "Gardener",             -- Gardener
    "Gymnast",              -- Gymnast
    "Handy",                -- Handy
    "Herbalist",            -- Herbalist
    "Hiker",                -- Hiker
    "Hunter",               -- Hunter
    "Jogger",               -- Runner (INTERNAL ID is "Jogger")
    "mason",                -- Mason
    "Mechanics",            -- Amateur Mechanic / Vehicle Knowledge (INTERNAL ID is "Mechanics")
    "Tailor",               -- Sewer (INTERNAL ID is "Tailor")
    "whittler",             -- Whittler
}

BurdJournals.EXCLUDED_TRAITS = {
    -- Passive skill traits (automatically granted/removed based on skill levels)
    -- NOTE: "out of shape" has a space in its CharacterTrait ID (base:"out of shape")
    "athletic", "strong", "stout", "fit", "feeble", "unfit", "out of shape", "weak",
    -- Weight/body-condition traits (dynamically applied by the game based on character weight)
    -- NOTE: "very underweight" also has a space (base:"very underweight")
    "overweight", "obese", "underweight", "very underweight", "emaciated",
    -- Metabolism traits (passive body condition, not learnable skills)
    "weightgain", "weightloss",
    -- Permanent physical traits that shouldn't be grantable
    -- CharacterTrait IDs confirmed from character_traits.txt: base:hardofhearing, base:shortsighted
    "asthmatic", "deaf", "hardofhearing", "shortsighted",
    -- Illiterate is a special case
    "illiterate",
}

-- Negative traits that can be removed through gameplay or journal claims
-- Excludes permanent traits (deaf, weight traits, etc.) and passive skill traits
BurdJournals.REMOVABLE_TRAITS = {
    -- Phobias
    "agoraphobic",
    "claustrophobic",   -- CharacterTrait ID: base:claustrophobic
    "hemophobic",       -- Fear of Blood

    -- Physical drawbacks (non-permanent)
    "allthumbs",
    "clumsy",
    "conspicuous",
    "thinskinned",
    "slowhealer",
    "pronetoillness",   -- Prone to Illness (CharacterTrait ID: base:pronetoillness)
    "weakstomach",

    -- Mental/Behavioral
    "cowardly",
    "pacifist",         -- Reluctant Fighter
    "smoker",
    "insomniac",
    "needsmoresleep",   -- Restless Sleeper (CharacterTrait ID: base:needsmoresleep)

    -- Learning/Perception
    "slowlearner",
    "slowreader",

    -- Consumption
    "heartyappetite",
    "highthirst",

    -- Organization
    "disorganized",

    -- Driving
    "sundaydriver",
    -- Note: "poorpassenger" (Motion Sensitive) does not exist in B42; removed
}

-- Trait ID aliases for handling variant IDs between different game APIs
-- Maps a trait ID to all its known aliases (bidirectional lookup)
-- KEY INSIGHT from PZ wiki research: Display names often differ from internal IDs!
-- Internal IDs (from undeniable.info/pzwiki):
--   "Angler" display -> "Fishing" internal ID
--   "Keen Cook" display -> "Cook" internal ID
--   "Runner" display -> "Jogger" internal ID
--   "Sewer" display -> "Tailor" internal ID
--   "Amateur Mechanic" display -> "Mechanics" internal ID
--   "Cat's Eyes" display -> "NightVision" internal ID
--   "Wakeful" display -> "NeedsLessSleep" internal ID
--   "First Aider" display -> "FirstAid" internal ID
BurdJournals.TRAIT_ALIASES = {
    -- Angler/Fishing - CRITICAL: Internal ID is "Fishing", NOT "Angler"!
    angler = {"fishing", "Fishing"},
    fishing = {"angler", "Angler"},
    
    -- Cook variants - TWO different traits in PZ:
    --   "Cook" (internal: Cook, 6 pts) - "Know cooking recipes"
    --   "Cook" (internal: Cook2, 0 pts) - profession trait "Know cooking"
    -- "Keen Cook" is NOT an official trait name, but users often confuse it with "Cook"
    cook = {"cook2", "keencook", "keen cook", "Cook", "Cook2", "KeenCook"},
    cook2 = {"cook", "keencook", "keen cook", "Cook", "Cook2", "KeenCook"},
    keencook = {"cook", "cook2", "keen cook", "Cook", "Cook2", "KeenCook"},
    ["keen cook"] = {"cook", "cook2", "keencook", "Cook", "Cook2", "KeenCook"},
    
    -- Wakeful / Restless Sleeper - CharacterTrait IDs confirmed from character_traits.txt
    -- Wakeful = base:needslesssleep, Restless Sleeper = base:needsmoresleep
    wakeful = {"needslesssleep", "NeedsLessSleep"},
    needslesssleep = {"wakeful", "Wakeful"},
    sleepyhead = {"needsmoresleep", "NeedsMoreSleep"},   -- old alias for Restless Sleeper
    needsmoresleep = {"sleepyhead", "moresleep", "MoreSleep"},
    
    -- Sewer/Tailor - Internal ID is "Tailor"
    tailor = {"sewer", "Tailor", "Sewer"},
    sewer = {"tailor", "Tailor", "Sewer"},
    
    -- Vehicle Knowledge / Amateur Mechanic - Internal ID is "Mechanics"
    mechanics = {"vehicleknowledge", "mechanics2", "Mechanics", "Mechanics2"},
    mechanics2 = {"mechanics", "vehicleknowledge", "Mechanics", "Mechanics2"},
    vehicleknowledge = {"mechanics", "mechanics2", "Mechanics", "Mechanics2"},
    
    -- Runner - Internal ID is "Jogger"
    runner = {"jogger", "Runner", "Jogger"},
    jogger = {"runner", "Runner", "Jogger"},
    
    -- Cat's Eyes - Internal ID is "NightVision"  
    catseyes = {"nightvision", "NightVision"},
    nightvision = {"catseyes", "NightVision"},
    
    -- First Aider - Internal ID is "FirstAid"
    firstaider = {"firstaid", "FirstAid"},
    firstaid = {"firstaider", "FirstAid"},
    
    -- Gardener - Internal ID is "Gardener"
    gardener = {"Gardener"},
    
    -- Prone to Illness - CharacterTrait ID confirmed: base:pronetoillness
    -- "hypercondriac"/"hypochondriac" were old/misspelled aliases used in B41 and early mods
    pronetoillness = {"hypercondriac", "hypochondriac", "Hypercondriac"},
    hypercondriac = {"pronetoillness", "hypochondriac", "ProneToIllness"},
    hypochondriac = {"pronetoillness", "hypercondriac", "ProneToIllness"},
    
    -- Iron Gut variants
    irongut = {"irongut2", "IronGut"},
    irongut2 = {"irongut", "IronGut"},
    
    -- Outdoorsy (Build 42 display name) -> Outdoorsman (internal ID)
    outdoorsy = {"outdoorsman", "Outdoorsman"},
    outdoorsman = {"outdoorsy", "Outdoorsy"},

    -- Claustrophobic - CharacterTrait ID: base:claustrophobic
    -- "claustro" is only the UI translation key suffix, not the real ID, but alias for safety
    claustrophobic = {"claustro"},
    claustro = {"claustrophobic"},

    -- Out of Shape / Very Underweight - IDs have spaces in game scripts
    -- Alias space-free variants that older code or mods might use
    outofshape = {"out of shape"},
    ["out of shape"] = {"outofshape"},
    veryunderweight = {"very underweight"},
    ["very underweight"] = {"veryunderweight"},
}

-- Helper function to get all aliases for a trait ID (including the ID itself)
function BurdJournals.getTraitAliases(traitId)
    if not traitId then return {} end
    local result = {traitId, string.lower(traitId)}
    local aliases = BurdJournals.TRAIT_ALIASES[string.lower(traitId)]
    if aliases then
        for _, alias in ipairs(aliases) do
            table.insert(result, alias)
            table.insert(result, string.lower(alias))
        end
    end
    -- Also add numeric suffix variants
    local baseId = string.gsub(traitId, "%d+$", "")
    if baseId ~= traitId then
        table.insert(result, baseId)
        table.insert(result, string.lower(baseId))
    end
    -- Add with "2" suffix if not already numeric
    if not string.match(traitId, "%d$") then
        table.insert(result, traitId .. "2")
        table.insert(result, string.lower(traitId) .. "2")
    end
    return result
end

-- Helper function to check if two trait IDs refer to the same trait
function BurdJournals.traitIdsMatch(id1, id2)
    if not id1 or not id2 then return false end
    local lower1 = string.lower(id1)
    local lower2 = string.lower(id2)
    if lower1 == lower2 then return true end
    
    -- Check base IDs (without numeric suffix)
    local base1 = string.gsub(lower1, "%d+$", "")
    local base2 = string.gsub(lower2, "%d+$", "")
    if base1 == base2 then return true end
    
    -- Check aliases
    local aliases1 = BurdJournals.TRAIT_ALIASES[lower1]
    if aliases1 then
        for _, alias in ipairs(aliases1) do
            if string.lower(alias) == lower2 then return true end
        end
    end
    
    return false
end

-- Known positive traits lookup table (for zero-cost fallback)
BurdJournals._knownPositiveTraitsSet = nil
BurdJournals._knownNegativeTraitsSet = nil

-- Build lookup sets from the hardcoded lists
function BurdJournals.buildKnownTraitSets()
    if not BurdJournals._knownPositiveTraitsSet then
        BurdJournals._knownPositiveTraitsSet = {}
        for _, traitId in ipairs(BurdJournals.GRANTABLE_TRAITS) do
            BurdJournals._knownPositiveTraitsSet[string.lower(traitId)] = true
        end
    end
    if not BurdJournals._knownNegativeTraitsSet then
        BurdJournals._knownNegativeTraitsSet = {}
        for _, traitId in ipairs(BurdJournals.REMOVABLE_TRAITS) do
            BurdJournals._knownNegativeTraitsSet[string.lower(traitId)] = true
        end
    end
end

-- Determine trait polarity with fallback for zero-cost traits
-- Returns: true = positive, false = negative, nil = unknown
function BurdJournals.determineTraitPolarity(traitId, cost)
    if not traitId then return nil end
    
    -- Primary: use cost
    -- cost > 0 = positive trait (player pays points)
    -- cost < 0 = negative trait (player gains points)
    if cost and cost > 0 then return true end
    if cost and cost < 0 then return false end
    
    -- Fallback for cost == 0: check known lists
    BurdJournals.buildKnownTraitSets()
    local lowerTraitId = string.lower(traitId)
    
    if BurdJournals._knownPositiveTraitsSet[lowerTraitId] then 
        return true 
    end
    if BurdJournals._knownNegativeTraitsSet[lowerTraitId] then 
        return false 
    end
    
    -- Check aliases too
    local aliases = BurdJournals.getTraitAliases(traitId)
    for _, alias in ipairs(aliases) do
        local aliasLower = string.lower(alias)
        if BurdJournals._knownPositiveTraitsSet[aliasLower] then 
            return true 
        end
        if BurdJournals._knownNegativeTraitsSet[aliasLower] then 
            return false 
        end
    end
    
    -- Default: assume positive for occupation/neutral traits (cost = 0)
    return true
end

BurdJournals._cachedGrantableTraits = nil
BurdJournals._cachedAllTraits = nil

BurdJournals._traitDisplayNameCache = {}

local function normalizeTraitIdRaw(traitId)
    if traitId == nil then return nil end
    local out = tostring(traitId)
    out = string.gsub(out, "^base:", "")
    out = string.gsub(out, "^Base%.", "")
    return out
end

local function getTraitIdFromDefinition(def)
    if not (def and def.getType) then return nil end
    local traitType = def:getType()
    if not traitType then return nil end
    if traitType.getName then
        return normalizeTraitIdRaw(traitType:getName())
    end
    return normalizeTraitIdRaw(traitType)
end

local function getTraitCostFromDefinition(def)
    if def and def.getCost then
        return def:getCost() or 0
    end
    return 0
end

local function getTraitLabelFromDefinition(def, fallback)
    if def and def.getLabel then
        return def:getLabel() or fallback
    end
    return fallback
end

function BurdJournals.getTraitDisplayName(traitId)
    if not traitId then return "Unknown Trait" end

    if BurdJournals._traitDisplayNameCache[traitId] then
        return BurdJournals._traitDisplayNameCache[traitId]
    end

    local displayName = nil

    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits and allTraits.size and allTraits.get then
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def then
                    local thisTraitId = getTraitIdFromDefinition(def)
                    if thisTraitId and string.lower(thisTraitId) == string.lower(traitId) then
                        displayName = getTraitLabelFromDefinition(def, displayName)
                        break
                    end
                end
            end
        end
    end

    if not displayName and TraitFactory and TraitFactory.getTrait then
        local trait = TraitFactory.getTrait(traitId)
        if trait and trait.getLabel then
            displayName = trait:getLabel()
        end
    end

    if not displayName then
        displayName = traitId:gsub("(%l)(%u)", "%1 %2")
    end

    BurdJournals._traitDisplayNameCache[traitId] = displayName

    return displayName
end

function BurdJournals.discoverGrantableTraits(includeNegative, forceRefresh)

    if includeNegative == nil then
        includeNegative = BurdJournals.getSandboxOption("AllowNegativeTraits") or false
    end

    local cacheKey = includeNegative and "_cachedAllTraits" or "_cachedGrantableTraits"
    if not forceRefresh and BurdJournals[cacheKey] then
        return BurdJournals[cacheKey]
    end

    local discoveredTraits = {}
    local addedTraitsLower = {}  -- Track lowercase IDs to prevent duplicates
    local excludedSet = {}

    for _, traitId in ipairs(BurdJournals.EXCLUDED_TRAITS) do
        excludedSet[string.lower(traitId)] = true
    end

    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits then
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def then
                    local traitId = nil
                    local cost = 0
                    local isPositive = true

                    traitId = getTraitIdFromDefinition(def)
                    cost = getTraitCostFromDefinition(def)

                    -- In PZ trait definitions:
                    -- cost > 0 = Positive trait (benefits, player pays points to get)
                    -- cost < 0 = Negative trait (drawbacks, player gains points by taking)
                    -- cost = 0 = Neutral/profession traits (no point cost)
                    isPositive = cost > 0

                    if traitId then
                        local traitIdLower = string.lower(traitId)

                        -- Skip if already added (case-insensitive deduplication)
                        if addedTraitsLower[traitIdLower] then
                            -- DEBUG: Log duplicate detection
                            print("[BurdJournals] DUPLICATE SKIPPED: '" .. traitId .. "' (already have '" .. (addedTraitsLower[traitIdLower] or "?") .. "')")
                        elseif excludedSet[traitIdLower] then
                            -- Skip excluded traits (passive skill traits, etc.)
                        elseif isPositive then
                            -- Positive trait (costs points = beneficial)
                            table.insert(discoveredTraits, traitId)
                            addedTraitsLower[traitIdLower] = traitId  -- Store original ID for debug
                        elseif cost == 0 then
                            -- Neutral/profession traits with 0 cost - include them
                            -- These are often profession-specific or hobby traits
                            table.insert(discoveredTraits, traitId)
                            addedTraitsLower[traitIdLower] = traitId  -- Store original ID for debug
                        elseif includeNegative and cost < 0 then
                            -- Negative trait (gives points = drawback) - only if allowed
                            table.insert(discoveredTraits, traitId)
                            addedTraitsLower[traitIdLower] = traitId  -- Store original ID for debug
                        end
                    end
                end
            end
        end
    end

    local modTraits = BurdJournals.getModRegisteredTraits()
    local addedModTraits = 0
    for traitId, _ in pairs(modTraits) do
        local traitIdLower = string.lower(traitId)
        if not addedTraitsLower[traitIdLower] and not excludedSet[traitIdLower] then
            table.insert(discoveredTraits, traitId)
            addedTraitsLower[traitIdLower] = true
            addedModTraits = addedModTraits + 1
        end
    end

    if #discoveredTraits > 0 then
        BurdJournals.debugPrint("[BurdJournals] Discovered " .. #discoveredTraits .. " grantable traits dynamically (includeNegative=" .. tostring(includeNegative) .. ", modAdded=" .. addedModTraits .. ")")
        BurdJournals[cacheKey] = discoveredTraits
        return discoveredTraits
    else
        BurdJournals.debugPrint("[BurdJournals] Using fallback hardcoded trait list (" .. #BurdJournals.GRANTABLE_TRAITS .. " traits)")
        return BurdJournals.GRANTABLE_TRAITS
    end
end

function BurdJournals.getGrantableTraits(includeNegative)
    return BurdJournals.discoverGrantableTraits(includeNegative, false)
end

-- Get only positive traits (cost > 0 = beneficial traits)
function BurdJournals.getPositiveTraits(forceRefresh)
    if not forceRefresh and BurdJournals._cachedPositiveTraits then
        return BurdJournals._cachedPositiveTraits
    end
    
    local positiveTraits = {}
    local excludedSet = {}
    
    for _, traitId in ipairs(BurdJournals.EXCLUDED_TRAITS or {}) do
        excludedSet[string.lower(traitId)] = true
    end
    
    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits then
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def then
                    local traitId = nil
                    local cost = 0
                    traitId = getTraitIdFromDefinition(def)
                    cost = getTraitCostFromDefinition(def)
                    
                    -- cost > 0 = positive trait (beneficial)
                    if traitId and cost > 0 and not excludedSet[string.lower(traitId)] then
                        table.insert(positiveTraits, traitId)
                    end
                end
            end
        end
    end
    
    -- Fallback
    if #positiveTraits == 0 then
        positiveTraits = {"Athletic", "Strong", "FastLearner", "Organized", "Lucky", "Brave", "Outdoorsman", "LightEater", "FastReader", "ThickSkinned"}
    end
    
    BurdJournals._cachedPositiveTraits = positiveTraits
    return positiveTraits
end

-- Get only negative traits (cost < 0 = drawback traits)
function BurdJournals.getNegativeTraits(forceRefresh)
    if not forceRefresh and BurdJournals._cachedNegativeTraits then
        return BurdJournals._cachedNegativeTraits
    end
    
    local negativeTraits = {}
    local excludedSet = {}
    
    for _, traitId in ipairs(BurdJournals.EXCLUDED_TRAITS or {}) do
        excludedSet[string.lower(traitId)] = true
    end
    
    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits then
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def then
                    local traitId = nil
                    local cost = 0
                    traitId = getTraitIdFromDefinition(def)
                    cost = getTraitCostFromDefinition(def)
                    
                    -- cost < 0 = negative trait (drawback)
                    if traitId and cost < 0 and not excludedSet[string.lower(traitId)] then
                        table.insert(negativeTraits, traitId)
                    end
                end
            end
        end
    end
    
    -- Fallback
    if #negativeTraits == 0 then
        negativeTraits = {"Conspicuous", "Clumsy", "SlowLearner", "SlowReader", "Cowardly", "Weak", "Overweight", "Underweight", "HighThirst", "Pacifist"}
    end
    
    BurdJournals._cachedNegativeTraits = negativeTraits
    return negativeTraits
end

function BurdJournals.isTraitGrantable(traitId, grantableList)
    if not traitId then return false end
    if not grantableList then
        grantableList = BurdJournals.getGrantableTraits()
    end

    local traitIdLower = string.lower(traitId)

    for _, grantable in ipairs(grantableList) do
        local grantableLower = string.lower(grantable)
        if traitIdLower == grantableLower then
            return true
        end
    end

    local baseTraitId = traitId:gsub("2$", "")
    if baseTraitId ~= traitId then
        local baseTraitIdLower = string.lower(baseTraitId)
        for _, grantable in ipairs(grantableList) do
            local grantableLower = string.lower(grantable)
            if baseTraitIdLower == grantableLower then
                return true
            end
        end
    end

    return false
end

function BurdJournals.refreshTraitCache()
    BurdJournals._cachedGrantableTraits = nil
    BurdJournals._cachedAllTraits = nil
    BurdJournals.debugPrint("[BurdJournals] Trait cache cleared - will rediscover on next access")
end

function BurdJournals.debugDumpTraits()
    if not BurdJournals.isDebug() then
        print("[BurdJournals] debugDumpTraits requires -debug mode")
        return
    end

    print("==================== BURD JOURNALS: TRAIT DISCOVERY DEBUG ====================")

    if not CharacterTraitDefinition or not CharacterTraitDefinition.getTraits then
        print("[BurdJournals] ERROR: CharacterTraitDefinition API not available!")
        return
    end

    local allTraits = CharacterTraitDefinition.getTraits()
    if not allTraits then
        print("[BurdJournals] ERROR: getTraits() returned nil!")
        return
    end

    local totalCount = allTraits:size()
    print("[BurdJournals] Total traits found in game: " .. totalCount)
    print("")

    local positiveTraits = {}
    local negativeTraits = {}
    local professionTraits = {}
    local excludedTraits = {}
    local unknownTraits = {}

    local excludedSet = {}
    for _, traitId in ipairs(BurdJournals.EXCLUDED_TRAITS) do
        excludedSet[string.lower(traitId)] = true
    end

    for i = 0, totalCount - 1 do
        local def = allTraits:get(i)
        if def then
            local traitId = nil
            local traitLabel = "?"
            local cost = 0
            local modSource = "vanilla"

            traitId = getTraitIdFromDefinition(def)
            traitLabel = getTraitLabelFromDefinition(def, traitId or "?")
            cost = getTraitCostFromDefinition(def)

            if traitId then
                if string.find(traitId, "SOTO") or string.find(traitId, "soto") then
                    modSource = "SOTO"
                elseif string.find(traitId, "MT_") or string.find(traitId, "MoreTraits") then
                    modSource = "More Traits"
                elseif string.find(traitId, "_") and not string.find(traitId, "^[a-z]+$") then
                    modSource = "modded?"
                end
            end

            local entry = {
                id = traitId or "nil",
                label = traitLabel,
                cost = cost,
                source = modSource
            }

            if traitId then
                local traitIdLower = string.lower(traitId)
                if excludedSet[traitIdLower] then
                    table.insert(excludedTraits, entry)
                elseif cost == 0 then
                    table.insert(professionTraits, entry)
                elseif cost > 0 then
                    table.insert(positiveTraits, entry)
                else
                    table.insert(negativeTraits, entry)
                end
            else
                table.insert(unknownTraits, entry)
            end
        end
    end

    print("=== POSITIVE TRAITS (grantable, cost > 0): " .. #positiveTraits .. " ===")
    for _, t in ipairs(positiveTraits) do
        print("  [+] " .. t.id .. " (" .. t.label .. ") cost=" .. t.cost .. " [" .. t.source .. "]")
    end
    print("")

    print("=== NEGATIVE TRAITS (cost < 0): " .. #negativeTraits .. " ===")
    for _, t in ipairs(negativeTraits) do
        print("  [-] " .. t.id .. " (" .. t.label .. ") cost=" .. t.cost .. " [" .. t.source .. "]")
    end
    print("")

    print("=== PROFESSION-ONLY TRAITS (cost = 0): " .. #professionTraits .. " ===")
    for _, t in ipairs(professionTraits) do
        print("  [0] " .. t.id .. " (" .. t.label .. ") [" .. t.source .. "]")
    end
    print("")

    print("=== EXCLUDED TRAITS (physical/body): " .. #excludedTraits .. " ===")
    for _, t in ipairs(excludedTraits) do
        print("  [X] " .. t.id .. " (" .. t.label .. ") cost=" .. t.cost .. " [" .. t.source .. "]")
    end
    print("")

    if #unknownTraits > 0 then
        print("=== UNKNOWN/ERROR TRAITS: " .. #unknownTraits .. " ===")
        for _, t in ipairs(unknownTraits) do
            print("  [?] " .. t.id .. " (" .. t.label .. ")")
        end
        print("")
    end

    print("=== SUMMARY ===")
    print("  Positive (grantable): " .. #positiveTraits)
    print("  Negative (with AllowNegativeTraits): " .. #negativeTraits)
    print("  Profession-only (excluded): " .. #professionTraits)
    print("  Physical/excluded: " .. #excludedTraits)
    print("  Total discoverable: " .. (#positiveTraits + #negativeTraits))
    print("")

    local allowNeg = BurdJournals.getSandboxOption("AllowNegativeTraits") or false
    print("  Sandbox 'AllowNegativeTraits': " .. tostring(allowNeg))
    print("  Current getGrantableTraits() would return: " .. #BurdJournals.getGrantableTraits() .. " traits")

    BurdJournals.debugPrint("==================== END TRAIT DISCOVERY DEBUG ==")
end

function BurdJournals.debugDumpSkills()
    if not BurdJournals.isDebug() then
        print("[BurdJournals] debugDumpSkills requires -debug mode")
        return
    end

    print("==================== BURD JOURNALS: SKILL DISCOVERY DEBUG ====================")

    -- Force refresh all caches
    BurdJournals.refreshSkillCache()
    
    -- Use enhanced metadata discovery
    local skillMetadata = BurdJournals.discoverSkillMetadata(true)
    
    -- Organize by category and vanilla/mod status
    local byCategory = {}
    local vanillaCount, modCount = 0, 0
    
    for perkId, data in pairs(skillMetadata) do
        local cat = data.category or "Other"
        if not byCategory[cat] then
            byCategory[cat] = { vanilla = {}, modded = {} }
        end
        
        if data.isVanilla then
            table.insert(byCategory[cat].vanilla, data)
            vanillaCount = vanillaCount + 1
        else
            table.insert(byCategory[cat].modded, data)
            modCount = modCount + 1
        end
    end
    
    print("[BurdJournals] Total skills discovered: " .. (vanillaCount + modCount))
    print("  Vanilla: " .. vanillaCount .. ", Modded: " .. modCount)
    print("")
    
    -- Print by category
    local sortedCategories = {}
    for cat, _ in pairs(byCategory) do
        table.insert(sortedCategories, cat)
    end
    table.sort(sortedCategories)
    
    for _, cat in ipairs(sortedCategories) do
        local catData = byCategory[cat]
        local catDisplayName = cat
        
        -- Try to get category display name from first skill
        if #catData.vanilla > 0 and catData.vanilla[1].categoryDisplayName then
            catDisplayName = catData.vanilla[1].categoryDisplayName
        elseif #catData.modded > 0 and catData.modded[1].categoryDisplayName then
            catDisplayName = catData.modded[1].categoryDisplayName
        end
        
        local total = #catData.vanilla + #catData.modded
        print("=== " .. catDisplayName .. " (" .. cat .. ") - " .. total .. " skills ===")
        
        -- Sort skills by display name
        table.sort(catData.vanilla, function(a, b) return a.displayName < b.displayName end)
        table.sort(catData.modded, function(a, b) return a.displayName < b.displayName end)
        
        -- Print vanilla skills
        for _, s in ipairs(catData.vanilla) do
            local passive = s.isPassive and " [PASSIVE]" or ""
            print(string.format("  [OK] %s -> \"%s\"%s", s.id, s.displayName, passive))
        end
        
        -- Print modded skills with [MOD] prefix
        for _, s in ipairs(catData.modded) do
            local passive = s.isPassive and " [PASSIVE]" or ""
            print(string.format("  [MOD] %s -> \"%s\"%s", s.id, s.displayName, passive))
        end
        print("")
    end
    
    print("=== SUMMARY ===")
    print("  Total categories: " .. #sortedCategories)
    print("  Vanilla skills: " .. vanillaCount)
    print("  Mod-added skills: " .. modCount)
    print("  Total available: " .. (vanillaCount + modCount))
    print("")
    print("  Note: Mod skills may only appear after game has fully loaded.")
    print("  If skills are missing, try running this command again in-game.")

    BurdJournals.debugPrint("==================== END SKILL DISCOVERY DEBUG ==")
end

-- Enhanced debug function to dump trait metadata
function BurdJournals.debugDumpTraitMetadata()
    if not BurdJournals.isDebug() then
        print("[BurdJournals] debugDumpTraitMetadata requires -debug mode")
        return
    end

    print("==================== BURD JOURNALS: TRAIT METADATA DEBUG ====================")

    -- Force refresh
    BurdJournals._cachedTraitMetadata = nil
    local traitMetadata = BurdJournals.discoverTraitMetadata(true)
    
    local positive, negative = {}, {}
    local moddedCount = 0
    
    for traitId, data in pairs(traitMetadata) do
        if data.isPositive then
            table.insert(positive, data)
        else
            table.insert(negative, data)
        end
        if not data.isVanilla then
            moddedCount = moddedCount + 1
        end
    end
    
    table.sort(positive, function(a, b) return a.displayName < b.displayName end)
    table.sort(negative, function(a, b) return a.displayName < b.displayName end)
    
    print("[BurdJournals] Total traits discovered: " .. (#positive + #negative))
    print("  Positive: " .. #positive .. ", Negative: " .. #negative .. ", Modded: " .. moddedCount)
    print("")
    
    print("=== POSITIVE TRAITS ===")
    for _, t in ipairs(positive) do
        local mod = t.isVanilla and "" or " [MOD]"
        local cost = t.cost ~= 0 and string.format(" (cost: %d)", t.cost) or ""
        print(string.format("  %s -> \"%s\"%s%s", t.id, t.displayName, cost, mod))
    end
    print("")
    
    print("=== NEGATIVE TRAITS ===")
    for _, t in ipairs(negative) do
        local mod = t.isVanilla and "" or " [MOD]"
        local cost = t.cost ~= 0 and string.format(" (cost: %d)", t.cost) or ""
        print(string.format("  %s -> \"%s\"%s%s", t.id, t.displayName, cost, mod))
    end
    print("")

    print("==================== END TRAIT METADATA DEBUG ====================")
end

BurdJournals.RECORDABLE_STATS = {

    {
        id = "zombieKills",
        nameKey = "UI_BurdJournals_StatZombieKills",
        nameFallback = "Zombie Kills",
        category = "Combat",
        descriptionKey = "UI_BurdJournals_StatZombieKillsDesc",
        descriptionFallback = "Total zombies killed",
        icon = "media/ui/zombie.png",
        getValue = function(player)
            if not player then return 0 end
            return player:getZombieKills() or 0
        end,
        format = function(value)
            return tostring(value)
        end,
    },
    {
        id = "hoursSurvived",
        nameKey = "UI_BurdJournals_StatHoursSurvived",
        nameFallback = "Hours Survived",
        category = "Survival",
        descriptionKey = "UI_BurdJournals_StatHoursSurvivedDesc",
        descriptionFallback = "Total hours alive in the apocalypse",
        icon = "media/ui/clock.png",
        getValue = function(player)
            if not player then return 0 end
            return math.floor(player:getHoursSurvived() or 0)
        end,
        format = function(value)
            local days = math.floor(value / 24)
            local hours = value % 24
            if days > 0 then
                local daysHoursText = getText("UI_BurdJournals_StatDaysHours")
                if daysHoursText and daysHoursText ~= "UI_BurdJournals_StatDaysHours" then
                    return string.format(daysHoursText, days, hours)
                end
                return days .. " days, " .. hours .. " hours"
            end
            local hoursText = getText("UI_BurdJournals_StatHours")
            if hoursText and hoursText ~= "UI_BurdJournals_StatHours" then
                return string.format(hoursText, hours)
            end
            return hours .. " hours"
        end,
    },
}

function BurdJournals.getStatName(stat)
    if not stat then return "Unknown" end
    if stat.nameKey and getText then
        local localized = getText(stat.nameKey)
        if localized and localized ~= stat.nameKey then
            return localized
        end
    end
    return stat.nameFallback or stat.name or "Unknown"
end

function BurdJournals.getStatDescription(stat)
    if not stat then return "" end
    if stat.descriptionKey and getText then
        local localized = getText(stat.descriptionKey)
        if localized and localized ~= stat.descriptionKey then
            return localized
        end
    end
    return stat.descriptionFallback or stat.description or ""
end

function BurdJournals.getStatById(statId)
    for _, stat in ipairs(BurdJournals.RECORDABLE_STATS) do
        if stat.id == statId then
            return stat
        end
    end
    return nil
end

function BurdJournals.getStatValue(player, statId)
    local stat = BurdJournals.getStatById(statId)
    if stat and stat.getValue and player then
        return stat.getValue(player)
    end
    return nil
end

function BurdJournals.formatStatValue(statId, value)
    local stat = BurdJournals.getStatById(statId)
    if stat and stat.format then
        return stat.format(value)
    end
    return tostring(value)
end

function BurdJournals.getStatsByCategory()
    local categories = {}
    for _, stat in ipairs(BurdJournals.RECORDABLE_STATS) do
        local cat = stat.category or "Other"
        if not categories[cat] then
            categories[cat] = {}
        end
        table.insert(categories[cat], stat)
    end
    return categories
end

function BurdJournals.recordStat(journal, statId, value, player)
    if not journal then return false end

    local modData = journal:getModData()
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    if not modData.BurdJournals.stats then
        modData.BurdJournals.stats = {}
    end

    local stat = BurdJournals.getStatById(statId)
    if not stat then return false end

    modData.BurdJournals.stats[statId] = {
        value = value,
        timestamp = getGameTime():getWorldAgeHours(),
        recordedBy = player and (player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname()) or "Unknown",
    }

    return true
end

function BurdJournals.getRecordedStat(journal, statId)
    if not journal then return nil end

    local modData = journal:getModData()
    if modData.BurdJournals and modData.BurdJournals.stats then
        return modData.BurdJournals.stats[statId]
    end
    return nil
end

function BurdJournals.getAllRecordedStats(journal)
    if not journal then return {} end

    local modData = journal:getModData()
    if modData.BurdJournals and modData.BurdJournals.stats then
        return modData.BurdJournals.stats
    end
    return {}
end

function BurdJournals.canUpdateStat(journal, statId, player)
    if not journal or not player then return false, nil, nil end

    local stat = BurdJournals.getStatById(statId)
    if not stat then return false, nil, nil end

    local currentValue = BurdJournals.getStatValue(player, statId)
    local recorded = BurdJournals.getRecordedStat(journal, statId)
    local recordedValue = recorded and recorded.value or nil

    if stat.isText then
        if recordedValue == nil or recordedValue ~= currentValue then
            return true, currentValue, recordedValue
        end
    else
        if recordedValue == nil or currentValue > recordedValue then
            return true, currentValue, recordedValue
        end
    end

    return false, currentValue, recordedValue
end

function BurdJournals.isStatEnabled(statId)

    if not BurdJournals.getSandboxOption("EnableStatRecording") then
        return false
    end

    local statToggleMap = {
        zombieKills = "RecordZombieKills",
        hoursSurvived = "RecordHoursSurvived",
    }

    local toggleOption = statToggleMap[statId]
    if toggleOption then
        local enabled = BurdJournals.getSandboxOption(toggleOption)

        if enabled == nil then
            return true
        end
        return enabled
    end

    return true
end

BurdJournals.DissolutionMessageKeys = {
    "UI_BurdJournals_Dissolve1",
    "UI_BurdJournals_Dissolve2",
    "UI_BurdJournals_Dissolve3",
    "UI_BurdJournals_Dissolve4",
    "UI_BurdJournals_Dissolve5",
    "UI_BurdJournals_Dissolve6",
    "UI_BurdJournals_Dissolve7",
    "UI_BurdJournals_Dissolve8",
    "UI_BurdJournals_Dissolve9",
    "UI_BurdJournals_Dissolve10",
}

BurdJournals.DissolutionFallbacks = {
    "Looks like that journal was on its last read...",
    "The pages crumble to dust in your hands...",
    "That was all it had left to give...",
    "The journal falls apart as you close it...",
    "Nothing but scraps remain...",
    "The binding finally gives way...",
    "It served its purpose...",
    "The ink fades completely as you finish reading...",
    "The worn pages disintegrate...",
    "Knowledge absorbed, the journal fades away...",
}

BurdJournals.CURSED_ITEM_TYPE = "BurdJournals.CursedJournal"
-- Cursed seal-break sound pool.
-- Add new custom sound event names here (or via registerCursedSealSoundEvent)
-- to include them in random selection when no explicit override is set.
BurdJournals.CURSED_SEAL_SOUND_EVENTS = BurdJournals.CURSED_SEAL_SOUND_EVENTS or {
    "BSJ_CursedBloody_SealBreak1",
    "BSJ_CursedBloody_SealBreak2",
    "BSJ_CursedBloody_SealBreak3",
}
BurdJournals.CURSED_DEFAULT_SOUND_EVENT = BurdJournals.CURSED_SEAL_SOUND_EVENTS[1] or "PaperRip"
BurdJournals.CURSE_EFFECT_TYPES = {
    "gain_negative_trait",
    "lose_positive_trait",
    "lose_skill_level",
    "panic",
}

local function normalizeCursedSealSoundName(soundEvent)
    if type(soundEvent) ~= "string" then
        return nil
    end
    local trimmed = string.gsub(soundEvent, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

function BurdJournals.getCursedSealSoundPool()
    local out = {}
    local seen = {}
    local pool = BurdJournals.CURSED_SEAL_SOUND_EVENTS or {}

    for _, soundEvent in ipairs(pool) do
        local normalized = normalizeCursedSealSoundName(soundEvent)
        local key = normalized and string.lower(normalized) or nil
        if normalized and normalized ~= "none" and key and not seen[key] then
            seen[key] = true
            out[#out + 1] = normalized
        end
    end

    if #out == 0 then
        local fallback = normalizeCursedSealSoundName(BurdJournals.CURSED_DEFAULT_SOUND_EVENT)
        if fallback then
            out[1] = fallback
        end
    end

    return out
end

function BurdJournals.registerCursedSealSoundEvent(soundEvent)
    local normalized = normalizeCursedSealSoundName(soundEvent)
    if not normalized then
        return nil
    end

    BurdJournals.CURSED_SEAL_SOUND_EVENTS = BurdJournals.CURSED_SEAL_SOUND_EVENTS or {}
    local key = string.lower(normalized)
    for _, existing in ipairs(BurdJournals.CURSED_SEAL_SOUND_EVENTS) do
        local existingNormalized = normalizeCursedSealSoundName(existing)
        if existingNormalized and string.lower(existingNormalized) == key then
            return existingNormalized
        end
    end

    BurdJournals.CURSED_SEAL_SOUND_EVENTS[#BurdJournals.CURSED_SEAL_SOUND_EVENTS + 1] = normalized
    return normalized
end

function BurdJournals.getRandomCursedSealSoundEvent()
    local pool = BurdJournals.getCursedSealSoundPool()
    if #pool == 0 then
        return BurdJournals.CURSED_DEFAULT_SOUND_EVENT or "PaperRip"
    end

    local index = nil
    if ZombRand then
        index = ZombRand(#pool) + 1
    else
        index = math.random(#pool)
    end
    return pool[index]
end

function BurdJournals.getRandomDissolutionMessage()
    local index = ZombRand(#BurdJournals.DissolutionMessageKeys) + 1
    local key = BurdJournals.DissolutionMessageKeys[index]
    local translated = getText(key)

    if translated == key then
        return BurdJournals.DissolutionFallbacks[index]
    end
    return translated
end

function BurdJournals.getSandboxOption(optionName)
    local sandboxVars = SandboxVars or {}
    local opts = sandboxVars.BurdJournals
    if opts and opts[optionName] ~= nil then
        return opts[optionName]
    end
    local defaults = {
        EnableJournals = true,

        XPRecoveryMode = 1,
        DiminishingFirstRead = 100,
        DiminishingDecayRate = 10,
        DiminishingMinimum = 10,
        DiminishingTrackingMode = 3,

        RequirePenToWrite = true,
        PenUsesPerLog = 1,
        RequireEraserToErase = true,

        LearningTimePerSkill = 3.0,
        LearningTimePerTrait = 5.0,
        LearningTimePerRecipe = 2.0,
        LearningTimeMultiplier = 1.0,

        EnableStatRecording = true,
        RecordZombieKills = true,
        RecordHoursSurvived = true,

        -- Player Journal trait/recipe recording toggles
        EnableTraitRecordingPlayer = true,
        EnableRecipeRecordingPlayer = true,
        EnablePassiveSkillsPlayer = true,
        EnablePassiveSkillsLoot = true,
        AllowTraitPurchaseSkillRecording = false,
        AllowAdaptiveTraitsManagedTraitRecording = false,
        AllowVhsSkillRecording = false,

        -- Loot journal trait/recipe display toggles (hides but preserves data)
        EnableWornJournalRecipes = true,
        EnableWornJournalTraits = true,
        EnableWornJournalForgetSlot = true,
        EnableBloodyJournalTraits = true,
        EnableBloodyJournalRecipes = true,
        EnableBloodyJournalForgetSlot = true,
        EnableCursedJournalTraits = true,
        EnableCursedJournalRecipes = true,
        EnableCursedJournalForgetSlot = true,

        -- 0 = unlimited (must match sandbox-options.txt defaults)
        MaxSkillsPerJournal = 0,
        MaxTraitsPerJournal = 0,
        MaxRecipesPerJournal = 0,

        EnableWornJournalSpawns = true,
        WornJournalSpawnChance = 2.0,
        WornJournalMinSkills = 1,
        WornJournalMaxSkills = 2,
        WornJournalMinXP = 25,
        WornJournalMaxXP = 75,
        WornJournalRecipeChance = 15,
        WornJournalMaxRecipes = 1,
        WornJournalTraitChance = 0,  -- Default 0% - traits disabled on worn journals by default
        WornJournalMinTraits = 1,
        WornJournalMaxTraits = 1,
        WornJournalForgetChance = 5,

        EnableBloodyJournalSpawns = true,
        BloodyJournalSpawnChance = 0.5,
        BloodyJournalMinSkills = 2,
        BloodyJournalMaxSkills = 4,
        BloodyJournalMinXP = 50,
        BloodyJournalMaxXP = 150,
        BloodyJournalTraitChance = 15,
        BloodyJournalMaxTraits = 2,
        BloodyJournalForgetChance = 5,
        EnableCursedJournalSpawns = true,
        CursedJournalSpawnChance = 0.2,
        CursedJournalMinSkills = 2,
        CursedJournalMaxSkills = 5,
        CursedJournalMinXP = 75,
        CursedJournalMaxXP = 300,
        CursedJournalTraitChance = 40,
        CursedJournalMinTraits = 1,
        CursedJournalMaxTraits = 3,
        CursedJournalRecipeChance = 60,
        CursedJournalMaxRecipes = 3,
        CursedJournalForgetChance = 25,

        EnablePlayerJournals = true,
        ReadingSkillAffectsSpeed = true,
        ReadingSpeedBonus = 0.1,
        EraseTime = 10.0,
        ConvertTime = 15.0,

        JournalXPMultiplier = 1.0,

        SkillBookMultiplierForJournals = true,
        SkillBookMultiplierCap = 2.0,
        RequireLightForJournalUse = false,

        AllowOthersToOpenJournals = true,
        AllowOthersToClaimFromJournals = true,
        AllowMutualExclusionCancellation = true,

        EnableBaselineRestriction = true,

        AllowPlayerJournalDissolution = false,
    }
    return defaults[optionName]
end

function BurdJournals.getJournalForgetSlotType(journalData)
    if type(journalData) ~= "table" then return nil end
    if journalData.isCursedReward == true or journalData.isCursedJournal == true then
        return "cursed"
    end
    if journalData.isBloody or journalData.wasFromBloody then
        return "bloody"
    end
    if journalData.isWorn then
        return "worn"
    end
    return nil
end

function BurdJournals.isForgetSlotEnabledForType(journalType)
    if journalType == "cursed" then
        return BurdJournals.getSandboxOption("EnableCursedJournalForgetSlot") ~= false
    end
    if journalType == "bloody" then
        return BurdJournals.getSandboxOption("EnableBloodyJournalForgetSlot") ~= false
    end
    if journalType == "worn" then
        return BurdJournals.getSandboxOption("EnableWornJournalForgetSlot") ~= false
    end
    return false
end

function BurdJournals.getForgetSlotChanceForType(journalType)
    if journalType == "cursed" then
        return tonumber(BurdJournals.getSandboxOption("CursedJournalForgetChance")) or 25
    end
    if journalType == "bloody" then
        return tonumber(BurdJournals.getSandboxOption("BloodyJournalForgetChance")) or 5
    end
    if journalType == "worn" then
        return tonumber(BurdJournals.getSandboxOption("WornJournalForgetChance")) or 5
    end
    return 0
end

function BurdJournals.rollForgetSlotForType(journalType, forcedValue)
    if forcedValue == false then
        return nil
    end
    if not BurdJournals.isForgetSlotEnabledForType(journalType) then
        return nil
    end
    if forcedValue == true then
        return true
    end

    local chance = BurdJournals.getForgetSlotChanceForType(journalType)
    if chance > 0 and ZombRand(100) < chance then
        return true
    end
    return nil
end

function BurdJournals.isForgetSlotEnabledForJournal(journalData)
    local journalType = BurdJournals.getJournalForgetSlotType(journalData)
    if not journalType then return false end
    return BurdJournals.isForgetSlotEnabledForType(journalType)
end

function BurdJournals.isEnabled()
    return BurdJournals.getSandboxOption("EnableJournals")
end

function BurdJournals.isPlayerJournalsEnabled()
    return BurdJournals.getSandboxOption("EnablePlayerJournals") ~= false
end

function BurdJournals.requiresLightForJournalUse()
    return BurdJournals.getSandboxOption("RequireLightForJournalUse") == true
end

function BurdJournals.canUseJournalInCurrentLight(player)
    if not BurdJournals.requiresLightForJournalUse() then
        return true, nil
    end

    local tooDarkText = (getText and getText("ContextMenu_TooDark")) or "Too dark to read."
    if tooDarkText == "ContextMenu_TooDark" then
        tooDarkText = "Too dark to read."
    end

    if not player then
        return false, tooDarkText
    end

    if player.tooDarkToRead and player:tooDarkToRead() then
        return false, tooDarkText
    end

    return true, nil
end

-- Check if passive skills (Fitness/Strength) are enabled for this journal context
function BurdJournals.arePassiveSkillsEnabledForJournal(journalData)
    if not journalData then return true end

    if journalData.isPlayerCreated then
        return BurdJournals.getSandboxOption("EnablePassiveSkillsPlayer") ~= false
    end

    return BurdJournals.getSandboxOption("EnablePassiveSkillsLoot") ~= false
end

-- Compatibility toggle for Traits Purchase System mod perk tree.
-- Default OFF because this "skill" is trait currency and can be exploited via journals.
function BurdJournals.isTraitPurchaseSkillRecordingEnabled()
    return BurdJournals.getSandboxOption("AllowTraitPurchaseSkillRecording") == true
end

function BurdJournals.isTraitPurchaseSkill(skillName)
    if not skillName then return false end

    local normalized = string.lower(tostring(skillName))
    if normalized == "traits" or normalized == "traits1" or normalized == "traits2" or normalized == "traits3" then
        return true
    end

    -- Also detect by parent category to support naming changes in the same mod family.
    if Perks and PerkFactory and PerkFactory.getPerk then
        local perk = Perks[tostring(skillName)]
        if perk then
            local perkDef = PerkFactory.getPerk(perk)
            local parent = perkDef and perkDef.getParent and perkDef:getParent() or nil
            local parentId = parent and parent.getId and tostring(parent:getId()) or nil
            if parentId and string.lower(parentId) == "traitspurchasesystem" then
                return true
            end
        end
    end

    return false
end

-- Compatibility toggle for Adaptive Traits managed traits.
-- Default OFF to prevent adaptive progression traits from being journal-looped.
function BurdJournals.isAdaptiveTraitsManagedTraitRecordingEnabled()
    return BurdJournals.getSandboxOption("AllowAdaptiveTraitsManagedTraitRecording") == true
end

-- Compatibility toggle for VHS/media-derived skill XP.
-- Default OFF to prevent media grinding from being journaled and looped.
function BurdJournals.isVhsSkillRecordingEnabled()
    -- VHS flow temporarily disabled: treat VHS XP like normal XP for journals.
    return true
end

local function normalizePositiveNumberMap(inputMap)
    local output = {}
    if not inputMap then
        return output
    end

    local normalized = BurdJournals.normalizeTable and BurdJournals.normalizeTable(inputMap) or inputMap
    if type(normalized) ~= "table" then
        return output
    end

    for key, value in pairs(normalized) do
        if key then
            local numberValue = tonumber(value)
            if numberValue and numberValue > 0 then
                output[tostring(key)] = numberValue
            end
        end
    end

    return output
end

function BurdJournals.rebuildVhsMediaLineCache()
    local cache = {}
    local mediaTable = RecMedia

    if type(mediaTable) ~= "table" then
        BurdJournals._vhsMediaLineCache = cache
        return cache
    end

    for _, mediaData in pairs(mediaTable) do
        if type(mediaData) == "table" then
            local category = tostring(mediaData.category or "")
            if category == "Retail-VHS" or category == "Home-VHS" then
                local lines = mediaData.lines
                if type(lines) == "table" then
                    for _, lineData in pairs(lines) do
                        if type(lineData) == "table" then
                            local lineGuid = lineData.text
                            if type(lineGuid) == "string" and lineGuid ~= "" then
                                cache[lineGuid] = category
                            end
                        end
                    end
                end
            end
        end
    end

    BurdJournals._vhsMediaLineCache = cache
    BurdJournals._vhsMediaLineCacheRefreshed = true
    return cache
end

function BurdJournals.getVhsMediaLineCategory(lineGuid)
    if type(lineGuid) ~= "string" or lineGuid == "" then
        return nil
    end

    local cache = BurdJournals._vhsMediaLineCache
    if not cache then
        cache = BurdJournals.rebuildVhsMediaLineCache()
    end

    local category = cache and cache[lineGuid] or nil
    if not category and not BurdJournals._vhsMediaLineCacheRefreshed then
        cache = BurdJournals.rebuildVhsMediaLineCache()
        category = cache and cache[lineGuid] or nil
    end
    return category
end

function BurdJournals.getPlayerVhsSkillXPMap(player, createIfMissing)
    if not player then
        return nil
    end

    local modData = player:getModData()
    if not modData then
        return nil
    end

    if createIfMissing and not modData.BurdJournals then
        modData.BurdJournals = {}
    end

    local bj = modData.BurdJournals
    if not bj then
        return nil
    end

    if createIfMissing and not bj.vhsSkillXP then
        bj.vhsSkillXP = {}
    end

    if not bj.vhsSkillXP then
        return nil
    end

    local normalized = normalizePositiveNumberMap(bj.vhsSkillXP)
    bj.vhsSkillXP = normalized
    return bj.vhsSkillXP
end

function BurdJournals.getPlayerVhsSkillXP(player, skillName)
    if not player or type(skillName) ~= "string" or skillName == "" then
        return 0
    end

    local skillMap = BurdJournals.getPlayerVhsSkillXPMap(player, false)
    if not skillMap then
        return 0
    end

    return math.max(0, tonumber(skillMap[skillName]) or 0)
end

function BurdJournals.getPlayerVhsSkillXPMapCopy(player)
    local source = BurdJournals.getPlayerVhsSkillXPMap(player, false)
    if not source then
        return {}
    end
    return normalizePositiveNumberMap(source)
end

function BurdJournals.recordVhsSkillXP(player, skillDeltas, lineGuid, category, sourceTag)
    -- VHS tracking flow disabled (temporary rollback).
    if true then return 0 end
    if not player or type(skillDeltas) ~= "table" then
        return 0
    end

    local modData = player:getModData()
    if not modData then
        return 0
    end

    modData.BurdJournals = modData.BurdJournals or {}
    local bj = modData.BurdJournals

    if type(lineGuid) ~= "string" or lineGuid == "" then
        lineGuid = nil
    end

    local normalizedDeltas = normalizePositiveNumberMap(skillDeltas)
    if not BurdJournals.hasAnyEntries(normalizedDeltas) then
        return 0
    end

    local skillMap = BurdJournals.getPlayerVhsSkillXPMap(player, true)
    if not skillMap then
        return 0
    end

    local skillCount = 0
    local xpAddedTotal = 0
    for skillName, delta in pairs(normalizedDeltas) do
        local nextValue = (tonumber(skillMap[skillName]) or 0) + delta
        skillMap[skillName] = nextValue
        skillCount = skillCount + 1
        xpAddedTotal = xpAddedTotal + delta
    end

    if lineGuid then
        bj.vhsLastLine = lineGuid
    end
    if type(category) == "string" and category ~= "" then
        bj.vhsLastCategory = category
    end

    if player.transmitModData then
        player:transmitModData()
    end

    BurdJournals.debugPrint("[BurdJournals] VHS XP tracked for "
        .. tostring(player.getUsername and player:getUsername() or "unknown")
        .. ": line=" .. tostring(lineGuid)
        .. ", skills=" .. tostring(skillCount)
        .. ", totalXP=" .. tostring(xpAddedTotal)
        .. ", source=" .. tostring(sourceTag or "unknown"))

    return xpAddedTotal
end

function BurdJournals.sendVhsSkillXPToServer(player, skillDeltas, lineGuid, category)
    -- VHS tracking flow disabled (temporary rollback).
    if true then return false end
    if not (isClient and isClient()) then
        return false
    end
    if isServer and isServer() then
        return false
    end
    if not sendClientCommand then
        return false
    end
    if not player then
        return false
    end

    local normalizedDeltas = normalizePositiveNumberMap(skillDeltas)
    if not BurdJournals.hasAnyEntries(normalizedDeltas) then
        return false
    end

    sendClientCommand(player, "BurdJournals", "trackVhsSkillXP", {
        lineGuid = lineGuid,
        category = category,
        skills = normalizedDeltas
    })
    return true
end

function BurdJournals.ensureVhsMediaTrackingHook()
    -- VHS tracking flow disabled (temporary rollback).
    if true then return false end
    if BurdJournals._vhsMediaTrackingHookInstalled then
        return true
    end

    if isServer and isServer() and not (isClient and isClient()) then
        return false
    end

    if not ISRadioInteractions or not ISRadioInteractions.getInstance then
        return false
    end

    local interactions = ISRadioInteractions:getInstance()
    if not interactions or type(interactions.checkPlayer) ~= "function" then
        return false
    end

    if interactions._burdVhsOriginalCheckPlayer then
        BurdJournals._vhsMediaTrackingHookInstalled = true
        return true
    end

    local originalCheckPlayer = interactions.checkPlayer
    interactions._burdVhsOriginalCheckPlayer = originalCheckPlayer

    interactions.checkPlayer = function(player, lineGuid, interactCodes, x, y, z, line, source)
        local category = BurdJournals.getVhsMediaLineCategory and BurdJournals.getVhsMediaLineCategory(lineGuid) or nil
        if not category or not player then
            return originalCheckPlayer(player, lineGuid, interactCodes, x, y, z, line, source)
        end

        if player.isKnownMediaLine and lineGuid and lineGuid ~= "" and player:isKnownMediaLine(lineGuid) then
            return originalCheckPlayer(player, lineGuid, interactCodes, x, y, z, line, source)
        end

        local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
        local xpBeforeBySkill = {}
        local xpObj = player.getXp and player:getXp() or nil

        if xpObj then
            for _, skillName in ipairs(allowedSkills) do
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName) or nil
                if perk then
                    xpBeforeBySkill[skillName] = xpObj:getXP(perk) or 0
                end
            end
        end

        local result = originalCheckPlayer(player, lineGuid, interactCodes, x, y, z, line, source)

        local gainedSkillXP = {}
        local gainedAny = false
        xpObj = player.getXp and player:getXp() or nil
        if xpObj then
            for skillName, xpBefore in pairs(xpBeforeBySkill) do
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName) or nil
                if perk then
                    local xpAfter = xpObj:getXP(perk) or 0
                    local delta = xpAfter - (xpBefore or 0)
                    if delta > 0 then
                        gainedSkillXP[skillName] = delta
                        gainedAny = true
                    end
                end
            end
        end

        if gainedAny then
            BurdJournals.recordVhsSkillXP(player, gainedSkillXP, lineGuid, category, (isServer and isServer()) and "server" or "client")
            BurdJournals.sendVhsSkillXPToServer(player, gainedSkillXP, lineGuid, category)
        end

        return result
    end

    BurdJournals._vhsMediaTrackingHookInstalled = true
    if BurdJournals.debugPrint then
        BurdJournals.debugPrint("[BurdJournals] Installed VHS media tracking hook")
    end
    return true
end

if false and not BurdJournals._vhsHookOnGameStartRegistered and Events and Events.OnGameStart and Events.OnGameStart.Add then
    Events.OnGameStart.Add(BurdJournals.ensureVhsMediaTrackingHook)
    BurdJournals._vhsHookOnGameStartRegistered = true
end

local hookOk, hookErr = true, nil
if not hookOk and hookErr then
    if BurdJournals.debugPrint then
        BurdJournals.debugPrint("[BurdJournals] VHS media tracking hook deferred after load error: " .. tostring(hookErr))
    elseif print then
        print("[BurdJournals] VHS media tracking hook deferred after load error: " .. tostring(hookErr))
    end
end

BurdJournals.ADAPTIVE_TRAITS_MANAGED = {
    adrenalinejunkie = true,
    agoraphobic = true,
    allthumbs = true,
    axeman = true,
    brave = true,
    claustrophobic = true,
    clumsy = true,
    conspicuous = true,
    cowardly = true,
    desensitized = true,
    dextrous = true,
    disorganized = true,
    fasthealer = true,
    fastreader = true,
    graceful = true,
    hemophobic = true,
    highthirst = true,
    hiker = true,
    inconspicuous = true,
    jogger = true,
    lowthirst = true,
    motionsensitive = true,
    nightowl = true,
    nightvision = true,
    organized = true,
    outdoorsman = true,
    slowhealer = true,
    slowreader = true,
    smoker = true,
    sundaydriver = true,
}

local function normalizeTraitCompatId(traitId)
    if traitId == nil then return nil end
    local out = string.lower(tostring(traitId))
    out = string.gsub(out, "^base:", "")
    out = string.gsub(out, "^base%.", "")
    out = string.gsub(out, "[^%w]", "")
    return out
end

BurdJournals._adaptiveTraitsActive = nil

function BurdJournals.isAdaptiveTraitsModActive()
    if BurdJournals._adaptiveTraitsActive ~= nil then
        return BurdJournals._adaptiveTraitsActive
    end

    local isActive = false
    if getActivatedMods then
        local activeMods = getActivatedMods()
        if activeMods then
            if activeMods.contains then
                isActive = activeMods:contains("AdaptiveTraits")
            end

            if not isActive and activeMods.size and activeMods.get then
                for i = 0, activeMods:size() - 1 do
                    local modId = activeMods:get(i)
                    if modId and string.lower(tostring(modId)) == "adaptivetraits" then
                        isActive = true
                        break
                    end
                end
            end
        end
    end

    if not isActive and getModInfoByID then
        isActive = getModInfoByID("AdaptiveTraits") ~= nil
    end

    BurdJournals._adaptiveTraitsActive = isActive
    return isActive
end

function BurdJournals.isAdaptiveManagedTrait(traitId)
    if not traitId then return false end
    if not BurdJournals.isAdaptiveTraitsModActive() then return false end

    local normalized = normalizeTraitCompatId(traitId)
    if normalized and BurdJournals.ADAPTIVE_TRAITS_MANAGED[normalized] then
        return true
    end

    if BurdJournals.getTraitAliases then
        local aliases = BurdJournals.getTraitAliases(tostring(traitId))
        for _, alias in ipairs(aliases) do
            local aliasNorm = normalizeTraitCompatId(alias)
            if aliasNorm and BurdJournals.ADAPTIVE_TRAITS_MANAGED[aliasNorm] then
                return true
            end
        end
    end

    return false
end

function BurdJournals.isLifestyleManagedTrait(traitId)
    if not traitId then return false end

    local normalizedTrait = normalizeTraitCompatId(traitId)
    if normalizedTrait == "ftbad"
        or normalizedTrait == "ftgood"
        or normalizedTrait == "eldoradobad"
        or normalizedTrait == "eldoradogood" then
        return true
    end

    if BurdJournals.getTraitModId then
        local sourceId = BurdJournals.getTraitModId(traitId)
        local normalizedSource = sourceId and string.lower(tostring(sourceId)) or ""
        if normalizedSource == "lifestyle" or normalizedSource == "lifestylehobbies" then
            if normalizedTrait and (string.match(normalizedTrait, "good$") or string.match(normalizedTrait, "bad$")) then
                return true
            end
        end
    end

    return false
end

function BurdJournals.isTraitBlockedByModCompat(journalData, traitId)
    if not traitId then return false end

    local isPlayerJournal = journalData and journalData.isPlayerCreated == true
    if isPlayerJournal and BurdJournals.isAdaptiveManagedTrait and BurdJournals.isAdaptiveManagedTrait(traitId) then
        return not BurdJournals.isAdaptiveTraitsManagedTraitRecordingEnabled()
    end
    if isPlayerJournal and BurdJournals.isLifestyleManagedTrait and BurdJournals.isLifestyleManagedTrait(traitId) then
        return true
    end

    return false
end

function BurdJournals.isSkillBlockedByModCompat(skillName)
    if BurdJournals.isTraitPurchaseSkill and BurdJournals.isTraitPurchaseSkill(skillName) then
        return not BurdJournals.isTraitPurchaseSkillRecordingEnabled()
    end
    return false
end

-- Check if a specific skill is enabled for this journal context
function BurdJournals.isSkillEnabledForJournal(journalData, skillName)
    if not skillName then return false end

    if BurdJournals.isSkillBlockedByModCompat and BurdJournals.isSkillBlockedByModCompat(skillName) then
        return false
    end

    -- Hide skills that are not currently registered in Perks.
    -- This prevents optional-mod skills from showing up in vanilla sessions.
    local canValidateRegistration = (Perks ~= nil) and (BurdJournals.getPerkByName ~= nil)
    if canValidateRegistration and not BurdJournals.getPerkByName(skillName) then
        return false
    end

    local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillName)
    if isPassive == nil then
        isPassive = (skillName == "Fitness" or skillName == "Strength")
    end
    if not isPassive then
        return true
    end

    return BurdJournals.arePassiveSkillsEnabledForJournal(journalData)
end

-- Check if traits are enabled for a specific journal type
-- journalType: "player", "worn", "bloody"
function BurdJournals.areTraitsEnabledForJournal(journalData)
    if not journalData then return false end

    -- Debug-spawned journals ALWAYS allow traits (bypass all restrictions)
    if journalData.isDebugSpawned then
        return true
    end

    -- Player journals check EnableTraitRecordingPlayer
    if journalData.isPlayerCreated then
        return BurdJournals.getSandboxOption("EnableTraitRecordingPlayer") ~= false
    end

    if journalData.isCursedReward == true or journalData.isCursedJournal == true then
        return BurdJournals.getSandboxOption("EnableCursedJournalTraits") ~= false
    end

    -- Bloody journals (or restored from bloody) check EnableBloodyJournalTraits
    if journalData.isBloody or journalData.wasFromBloody then
        return BurdJournals.getSandboxOption("EnableBloodyJournalTraits") ~= false
    end

    -- Worn journals check EnableWornJournalTraits
    if journalData.isWorn then
        return BurdJournals.getSandboxOption("EnableWornJournalTraits") ~= false
    end

    return false
end

function BurdJournals.isTraitEnabledForJournal(journalData, traitId)
    if not traitId then return false end
    if not BurdJournals.areTraitsEnabledForJournal(journalData) then
        return false
    end
    if BurdJournals.isTraitBlockedByModCompat and BurdJournals.isTraitBlockedByModCompat(journalData, traitId) then
        return false
    end
    return true
end

-- Check if recipes are enabled for a specific journal type
function BurdJournals.areRecipesEnabledForJournal(journalData)
    if not journalData then return false end

    -- Debug-spawned journals ALWAYS allow recipes (bypass all restrictions)
    if journalData.isDebugSpawned then
        return true
    end

    -- Player journals check EnableRecipeRecordingPlayer
    if journalData.isPlayerCreated then
        return BurdJournals.getSandboxOption("EnableRecipeRecordingPlayer") ~= false
    end

    if journalData.isCursedReward == true or journalData.isCursedJournal == true then
        return BurdJournals.getSandboxOption("EnableCursedJournalRecipes") ~= false
    end

    -- Bloody journals check EnableBloodyJournalRecipes
    if journalData.isBloody or journalData.wasFromBloody then
        return BurdJournals.getSandboxOption("EnableBloodyJournalRecipes") ~= false
    end

    -- Worn journals check EnableWornJournalRecipes
    if journalData.isWorn then
        return BurdJournals.getSandboxOption("EnableWornJournalRecipes") ~= false
    end

    return true -- Default to enabled for unknown types
end

-- Unified helper: Check if recipe recording is enabled globally
-- This is the correct sandbox option key - there is NO "EnableRecipeRecording" option
-- Only "EnableRecipeRecordingPlayer" exists in sandbox-options.txt
function BurdJournals.isRecipeRecordingEnabled()
    local v = BurdJournals.getSandboxOption("EnableRecipeRecordingPlayer")
    return v ~= false
end

setmetatable(BurdJournals.Limits, {
    __index = function(t, key)

        if key == "MAX_SKILLS" then
            -- 0 = unlimited (sandbox option comment says "0 = unlimited")
            local val = BurdJournals.getSandboxOption("MaxSkillsPerJournal")
            if val == nil or val == 0 then return 999999 end
            return val
        elseif key == "MAX_TRAITS" then
            -- 0 = unlimited
            local val = BurdJournals.getSandboxOption("MaxTraitsPerJournal")
            if val == nil or val == 0 then return 999999 end
            return val
        elseif key == "MAX_RECIPES" then
            -- 0 = unlimited
            local val = BurdJournals.getSandboxOption("MaxRecipesPerJournal")
            if val == nil or val == 0 then return 999999 end
            return val

        elseif key == "WARN_SKILLS" then
            local val = BurdJournals.getSandboxOption("MaxSkillsPerJournal")
            if val == nil or val == 0 then return 999999 end
            return math.floor(val * 0.5)
        elseif key == "WARN_TRAITS" then
            local val = BurdJournals.getSandboxOption("MaxTraitsPerJournal")
            if val == nil or val == 0 then return 999999 end
            return math.floor(val * 0.4)
        elseif key == "WARN_RECIPES" then
            local val = BurdJournals.getSandboxOption("MaxRecipesPerJournal")
            if val == nil or val == 0 then return 999999 end
            return math.floor(val * 0.4)
        end
        return rawget(t, key)
    end
})

function BurdJournals.getPlayerSteamId(player)
    if not player then return nil end

    if player.getSteamID then
        local steamId = player:getSteamID()

        if steamId and steamId ~= "" and steamId ~= 0 and tostring(steamId) ~= "0" then
            return tostring(steamId)
        end
    end

    local username = player:getUsername()
    if username and username ~= "" then
        return "local_" .. username
    end

    return "local_unknown"
end

function BurdJournals.getPlayerCharacterId(player)
    if not player then return nil end

    local steamId = BurdJournals.getPlayerSteamId(player)
    if not steamId then return nil end

    local descriptor = player:getDescriptor()
    if not descriptor then return steamId .. "_Unknown" end

    local forename = descriptor:getForename() or "Unknown"
    local surname = descriptor:getSurname() or ""
    local charName = forename .. "_" .. surname

    charName = string.gsub(charName, " ", "_")

    return steamId .. "_" .. charName
end

function BurdJournals.getJournalOwnerSteamId(item)
    if not item then return nil end
    local modData = item:getModData()
    if modData.BurdJournals and modData.BurdJournals.ownerSteamId then
        return modData.BurdJournals.ownerSteamId
    end
    return nil
end

function BurdJournals.getJournalOwnerUsername(item)
    if not item then return nil end
    local modData = item:getModData()
    if modData.BurdJournals and modData.BurdJournals.ownerUsername then
        return modData.BurdJournals.ownerUsername
    end
    return nil
end

function BurdJournals.getJournalAuthorUsername(item)
    if not item then return nil end
    local modData = item:getModData()
    if modData.BurdJournals and modData.BurdJournals.author then
        return modData.BurdJournals.author
    end
    return nil
end

function BurdJournals.isJournalOwner(player, item)
    if not player or not item then return false end

    local modData = item:getModData()
    if not modData.BurdJournals then return true end

    local journalData = modData.BurdJournals

    local ownerSteamId = journalData.ownerSteamId
    if ownerSteamId then
        local playerSteamId = BurdJournals.getPlayerSteamId(player)
        if playerSteamId then

            if ownerSteamId == playerSteamId then
                return true
            end

        end
    end

    local ownerUsername = journalData.ownerUsername
    if ownerUsername then
        local playerUsername = player:getUsername()
        if playerUsername and ownerUsername == playerUsername then
            return true
        end
    end

    local author = journalData.author
    if author then
        local playerFullName = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname()
        if author == playerFullName then
            return true
        end

        local playerUsername = player:getUsername()
        if playerUsername and author == playerUsername then
            return true
        end
    end

    if not ownerSteamId and not ownerUsername and not author then
        return true
    end

    return false
end

function BurdJournals.canPlayerOpenJournal(player, item)
    if not player or not item then return false, "Invalid player or item" end

    if not BurdJournals.isPlayerJournal(item) then
        return true, nil
    end

    if BurdJournals.isWorn(item) or BurdJournals.isBloody(item) then
        return true, nil
    end

    if BurdJournals.isJournalOwner(player, item) then
        return true, nil
    end

    local allowOthersToOpen = BurdJournals.getSandboxOption("AllowOthersToOpenJournals")
    if allowOthersToOpen == false then
        return false, "You cannot open another player's personal journal."
    end

    return true, nil
end

function BurdJournals.canPlayerClaimFromJournal(player, item)
    if not player or not item then return false, "Invalid player or item" end

    if not BurdJournals.isPlayerJournal(item) then
        return true, nil
    end

    if BurdJournals.isWorn(item) or BurdJournals.isBloody(item) then
        return true, nil
    end

    if BurdJournals.isJournalOwner(player, item) then
        return true, nil
    end

    local allowOthersToOpen = BurdJournals.getSandboxOption("AllowOthersToOpenJournals")
    if allowOthersToOpen == false then
        return false, "You cannot access another player's personal journal."
    end

    local allowOthersToClaim = BurdJournals.getSandboxOption("AllowOthersToClaimFromJournals")
    if allowOthersToClaim == false then
        return false, "You cannot claim from another player's personal journal."
    end

    return true, nil
end

function BurdJournals.initClaimsStructure(journalData)
    if not journalData then return end

    if not journalData.claims or type(journalData.claims) ~= "table" then
        journalData.claims = {}
    end
end

function BurdJournals.getCharacterClaims(journalData, player, createIfMissing)
    if not journalData or not player then return nil end

    local characterId = BurdJournals.getPlayerCharacterId(player)
    if not characterId then return nil end

    if createIfMissing == nil then
        createIfMissing = true
    end

    -- Strict MP server path: persist runtime claims in sharded global ModData.
    if BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
        and BurdJournals.getOrCreateJournalRuntimeEntryForData then
        local runtimeEntry, runtimeShardKey = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, createIfMissing)
        if runtimeEntry then
            runtimeEntry.claims = runtimeEntry.claims or {}
            local charClaims = runtimeEntry.claims[characterId]
            if type(charClaims) ~= "table" then
                if not createIfMissing then
                    return nil
                end
                charClaims = {}
                runtimeEntry.claims[characterId] = charClaims
            end

            if BurdJournals.ensureRuntimeCharacterClaimsShape then
                BurdJournals.ensureRuntimeCharacterClaimsShape(charClaims)
            else
                if type(charClaims.skills) ~= "table" then charClaims.skills = {} end
                if type(charClaims.traits) ~= "table" then charClaims.traits = {} end
                if type(charClaims.recipes) ~= "table" then charClaims.recipes = {} end
                if type(charClaims.forgetSlots) ~= "table" then charClaims.forgetSlots = {} end
                if type(charClaims.stats) ~= "table" then charClaims.stats = {} end
                if type(charClaims.drSkillReadCounts) ~= "table" then charClaims.drSkillReadCounts = {} end
            end

            if createIfMissing and BurdJournals.runtimeTouchJournalEntry then
                BurdJournals.runtimeTouchJournalEntry(runtimeEntry, runtimeShardKey, "getCharacterClaims")
            end
            return charClaims
        end
    end

    BurdJournals.initClaimsStructure(journalData)

    local charClaims = journalData.claims[characterId]

    if not charClaims or type(charClaims) ~= "table" then
        if not createIfMissing then
            return nil
        end
        charClaims = { skills = {}, traits = {}, recipes = {}, forgetSlots = {} }
        journalData.claims[characterId] = charClaims
    else

        if not charClaims.skills or type(charClaims.skills) ~= "table" then
            if createIfMissing == false then return nil end
            charClaims.skills = {}
        end
        if not charClaims.traits or type(charClaims.traits) ~= "table" then
            if createIfMissing == false then return nil end
            charClaims.traits = {}
        end
        if not charClaims.recipes or type(charClaims.recipes) ~= "table" then
            if createIfMissing == false then return nil end
            charClaims.recipes = {}
        end
        if not charClaims.forgetSlots or type(charClaims.forgetSlots) ~= "table" then
            if createIfMissing == false then return nil end
            charClaims.forgetSlots = {}
        end
    end

    return charClaims
end

local function hasLegacyUnknownClaim(journalData, claimType, claimId)
    if not journalData or type(claimType) ~= "string" or claimType == "" or claimId == nil then
        return false
    end

    local claims = journalData.claims
    if BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
        and BurdJournals.getOrCreateJournalRuntimeEntryForData then
        local runtimeEntry = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, false)
        claims = runtimeEntry and runtimeEntry.claims or claims
    end
    if type(claims) ~= "table" and BurdJournals.normalizeTable then
        claims = BurdJournals.normalizeTable(claims)
    end
    if type(claims) ~= "table" then
        return false
    end

    local legacyClaims = claims["legacy_unknown"]
    if type(legacyClaims) ~= "table" and BurdJournals.normalizeTable then
        legacyClaims = BurdJournals.normalizeTable(legacyClaims)
    end
    if type(legacyClaims) ~= "table" then
        return false
    end

    local claimBucket = legacyClaims[claimType]
    if type(claimBucket) ~= "table" and BurdJournals.normalizeTable then
        claimBucket = BurdJournals.normalizeTable(claimBucket)
    end
    if type(claimBucket) ~= "table" then
        return false
    end

    local value = claimBucket[claimId]
    return value ~= nil and value ~= false
end

function BurdJournals.isRestoredJournalData(journalData)
    if type(journalData) ~= "table" then
        return false
    end
    return journalData.wasFromWorn == true
        or journalData.wasFromBloody == true
        or journalData.wasRestored == true
        or journalData.wasCleaned == true
        or (type(journalData.restoredBy) == "string" and journalData.restoredBy ~= "")
        or journalData.isWorn == true
        or journalData.isBloody == true
end

-- Claim tracking policy:
-- - Non-player journals always track claims.
-- - Player journals stay reusable by default.
-- - Restored player journals only track claims when restored-journal dissolution is enabled.
function BurdJournals.shouldTrackCharacterClaims(journalData, claimType)
    if type(journalData) ~= "table" then
        return true
    end

    local isPlayerJournal = journalData.isPlayerCreated == true
    if not isPlayerJournal and journalData.isPlayerCreated == nil then
        local hasOwner = journalData.ownerUsername or journalData.ownerSteamId or journalData.ownerCharacterName
        if hasOwner and journalData.isWorn ~= true and journalData.isBloody ~= true then
            isPlayerJournal = true
        end
    end
    local isRestored = BurdJournals.isRestoredJournalData(journalData)

    local isBinaryClaimType = (claimType and claimType ~= "skills")
    if not isBinaryClaimType then
        if not isPlayerJournal then
            return true
        end

        if not isRestored then
            return false
        end

        return BurdJournals.getSandboxOption("AllowPlayerJournalDissolution") == true
    end

    -- Traits/recipes/stats:
    -- - Non-player journals keep anti-reclaim behavior.
    -- - Player journals only track claims when restored+journal dissolution is enabled.
    if not isPlayerJournal then
        -- Legacy safety for ambiguous clean journals.
        if not isRestored then
            return false
        end
        return true
    end

    local allowDissolution = BurdJournals.getSandboxOption("AllowPlayerJournalDissolution") == true
    if not allowDissolution then
        return false
    end

    return isRestored
end

function BurdJournals.hasCharacterClaimedSkill(journalData, player, skillName)
    if not journalData or not player or not skillName then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "skills") then return false end

    local claims = BurdJournals.getCharacterClaims(journalData, player, false)
    if claims and type(claims.skills) == "table" and claims.skills[skillName] then
        return true
    end

    if hasLegacyUnknownClaim(journalData, "skills", skillName) then
        return true
    end

    return false
end

function BurdJournals.hasCharacterClaimedTrait(journalData, player, traitId)
    if not journalData or not player or not traitId then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "traits") then return false end

    local claims = BurdJournals.getCharacterClaims(journalData, player, false)
    if claims and type(claims.traits) == "table" and claims.traits[traitId] then
        return true
    end

    if hasLegacyUnknownClaim(journalData, "traits", traitId) then
        return true
    end

    return false
end

function BurdJournals.hasCharacterClaimedRecipe(journalData, player, recipeName)
    if not journalData or not player or not recipeName then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "recipes") then return false end

    local claims = BurdJournals.getCharacterClaims(journalData, player, false)
    if claims and type(claims.recipes) == "table" and claims.recipes[recipeName] then
        return true
    end

    if hasLegacyUnknownClaim(journalData, "recipes", recipeName) then
        return true
    end

    return false
end

function BurdJournals.markSkillClaimedByCharacter(journalData, player, skillName)
    if not journalData or not player or not skillName then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "skills") then return true end

    local claims = BurdJournals.getCharacterClaims(journalData, player, true)
    if not claims then return false end

    claims.skills[skillName] = true

    -- Keep legacy mirror only when it already exists to avoid duplicate growth.
    if type(journalData.claimedSkills) == "table" then
        journalData.claimedSkills[skillName] = true
    end

    return true
end

function BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)
    if not journalData or not player or not traitId then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "traits") then return true end

    local claims = BurdJournals.getCharacterClaims(journalData, player, true)
    if not claims then return false end

    claims.traits[traitId] = true

    -- Keep legacy mirror only when it already exists to avoid duplicate growth.
    if type(journalData.claimedTraits) == "table" then
        journalData.claimedTraits[traitId] = true
    end

    return true
end

function BurdJournals.markRecipeClaimedByCharacter(journalData, player, recipeName)
    if not journalData or not player or not recipeName then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "recipes") then return true end

    local claims = BurdJournals.getCharacterClaims(journalData, player, true)
    if not claims then return false end

    claims.recipes[recipeName] = true

    -- Keep legacy mirror only when it already exists to avoid duplicate growth.
    if type(journalData.claimedRecipes) == "table" then
        journalData.claimedRecipes[recipeName] = true
    end

    return true
end

function BurdJournals.hasCharacterClaimedForgetSlot(journalData, player)
    if not journalData or not player then return false end
    if journalData.forgetSlot ~= true then return false end

    local claims = BurdJournals.getCharacterClaims(journalData, player, false)
    if claims and type(claims.forgetSlots) == "table" and claims.forgetSlots.default then
        return true
    end

    local characterId = BurdJournals.getPlayerCharacterId(player)
    if characterId and type(journalData.claimedForgetSlot) == "table" and journalData.claimedForgetSlot[characterId] then
        return true
    end

    return false
end

function BurdJournals.markForgetSlotClaimedByCharacter(journalData, player, forgottenTraitId)
    if not journalData or not player then return false end

    local claims = BurdJournals.getCharacterClaims(journalData, player, true)
    if not claims then return false end

    if type(claims.forgetSlots) ~= "table" then
        claims.forgetSlots = {}
    end
    claims.forgetSlots.default = forgottenTraitId or true

    local strictMPServer = BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
    if not strictMPServer then
        local characterId = BurdJournals.getPlayerCharacterId(player)
        if characterId then
            if type(journalData.claimedForgetSlot) ~= "table" then
                journalData.claimedForgetSlot = {}
            end
            journalData.claimedForgetSlot[characterId] = forgottenTraitId or true
        end
    end

    return true
end

-- =============================================================================
-- STAT ABSORPTION SYSTEM
-- =============================================================================
-- Allows players to claim recorded stats (zombie kills, hours survived) from
-- worn/bloody journals. Only stats where the journal value exceeds the player's
-- current value can be absorbed.
-- =============================================================================

-- Define which stats can be absorbed and how to apply them
BurdJournals.ABSORBABLE_STATS = {
    zombieKills = {
        canAbsorb = true,
        displayName = "Zombie Kills",
        -- Apply the stat value to the player
        apply = function(player, value)
            if player and player.setZombieKills then
                local oldValue = player:getZombieKills()
                player:setZombieKills(value)
                local newValue = player:getZombieKills()
                print("[BurdJournals] Applied zombieKills: " .. tostring(oldValue) .. " -> " .. tostring(value) .. " (now: " .. tostring(newValue) .. ")")
                return true
            end
            print("[BurdJournals] ERROR: Cannot apply zombieKills - method not available")
            return false
        end,
        -- Get current player value for comparison
        getCurrentValue = function(player)
            if player and player.getZombieKills then
                return player:getZombieKills()
            end
            return 0
        end,
    },
    hoursSurvived = {
        canAbsorb = true,
        displayName = "Hours Survived",
        -- Apply the stat value to the player
        apply = function(player, value)
            if player and player.setHoursSurvived then
                local oldValue = player:getHoursSurvived()
                player:setHoursSurvived(value)
                local newValue = player:getHoursSurvived()
                print("[BurdJournals] Applied hoursSurvived: " .. tostring(oldValue) .. " -> " .. tostring(value) .. " (now: " .. tostring(newValue) .. ")")
                return true
            end
            print("[BurdJournals] ERROR: Cannot apply hoursSurvived - method not available")
            return false
        end,
        -- Get current player value for comparison
        getCurrentValue = function(player)
            if player and player.getHoursSurvived then
                return player:getHoursSurvived()
            end
            return 0
        end,
    },
}

-- Check if a stat can be absorbed from a journal by a player
-- Returns: canAbsorb (boolean), recordedValue (number), currentValue (number), reason (string)
function BurdJournals.canAbsorbStat(journalData, player, statId)
    if not journalData or not player or not statId then
        return false, nil, nil, "invalid_params"
    end

    -- Check if stat absorption is defined for this stat
    local statDef = BurdJournals.ABSORBABLE_STATS[statId]
    if not statDef or not statDef.canAbsorb then
        return false, nil, nil, "not_absorbable"
    end

    -- Check if journal has this stat recorded
    if not journalData.stats or not journalData.stats[statId] then
        return false, nil, nil, "not_recorded"
    end

    -- Get recorded and current values
    -- Stats are stored as tables with {value = X, timestamp = Y, recordedBy = Z}
    local statData = journalData.stats[statId]
    local recordedValue = type(statData) == "table" and statData.value or statData
    local currentValue = statDef.getCurrentValue(player)

    -- Safety check: ensure both values are numbers
    if type(recordedValue) ~= "number" then
        return false, nil, nil, "invalid_value"
    end
    if type(currentValue) ~= "number" then
        currentValue = 0
    end

    -- Check if already claimed by this character
    if BurdJournals.hasCharacterClaimedStat(journalData, player, statId) then
        return false, recordedValue, currentValue, "already_claimed"
    end

    -- Can only absorb if recorded value is higher than current
    if currentValue >= recordedValue then
        return false, recordedValue, currentValue, "no_benefit"
    end

    return true, recordedValue, currentValue, nil
end

-- Check if a character has claimed a specific stat from a journal
function BurdJournals.hasCharacterClaimedStat(journalData, player, statId)
    if not journalData or not player or not statId then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "stats") then return false end

    local strictMPServer = BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()

    -- Non-strict contexts may still use legacy global claimedStats.
    if not strictMPServer and not journalData.isPlayerCreated and journalData.claimedStats and journalData.claimedStats[statId] then
        return true
    end

    -- Legacy migration fallback: claimedStats may have been migrated to claims.legacy_unknown.stats
    if hasLegacyUnknownClaim(journalData, "stats", statId) then
        return true
    end

    -- Check per-character claims
    local claims = BurdJournals.getCharacterClaims(journalData, player, false)
    if not claims then return false end

    return type(claims.stats) == "table" and claims.stats[statId] == true
end

-- Mark a stat as claimed by a specific character
function BurdJournals.markStatClaimedByCharacter(journalData, player, statId)
    if not journalData or not player or not statId then return false end
    if not BurdJournals.shouldTrackCharacterClaims(journalData, "stats") then return true end

    local claims = BurdJournals.getCharacterClaims(journalData, player, true)
    if not claims then return false end

    -- Ensure stats table exists
    if not claims.stats then
        claims.stats = {}
    end

    claims.stats[statId] = true

    -- Preserve legacy behavior outside strict MP server mode.
    local strictMPServer = BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
    if not strictMPServer then
        if not journalData.claimedStats then
            journalData.claimedStats = {}
        end
        journalData.claimedStats[statId] = true
    end

    return true
end

-- Apply a stat absorption to the player
function BurdJournals.applyStatAbsorption(player, statId, value)
    if not player or not statId or not value then return false end

    local statDef = BurdJournals.ABSORBABLE_STATS[statId]
    if not statDef or not statDef.apply then
        return false
    end

    return statDef.apply(player, value)
end

-- Get display name for a stat
function BurdJournals.getStatDisplayName(statId)
    local statDef = BurdJournals.ABSORBABLE_STATS[statId]
    if statDef and statDef.displayName then
        return statDef.displayName
    end
    -- Fallback: convert camelCase to Title Case
    if statId then
        return statId:gsub("(%u)", " %1"):gsub("^%s", ""):gsub("^%l", string.upper)
    end
    return "Unknown"
end

-- Current compact version - increment when adding new optimizations
BurdJournals.COMPACT_VERSION = 1

-- Compact journal data by removing redundant fields to reduce ModData size
-- This helps prevent hitting the 64KB player data limit that can cause save corruption
-- All removed fields are either derivable from other data or unused
function BurdJournals.compactJournalData(item)
    if not item then return end
    
    -- Ensure item has getModData method (defensive check)
    if not item.getModData then
        BurdJournals.debugPrint("[BurdJournals] WARNING: compactJournalData called with invalid item (no getModData)")
        return
    end
    
    local modData = item:getModData()
    if not modData or not modData.BurdJournals then return end
    local data = modData.BurdJournals
    
    -- Ensure data is a table
    if type(data) ~= "table" then return end
    
    -- Check if already compacted at current version
    if data.compactVersion and data.compactVersion >= BurdJournals.COMPACT_VERSION then
        return
    end
    
    local fieldsRemoved = 0
    
    -- Preserve ownership semantics for legacy journals:
    -- some old entries only had `author`, so migrate that into ownerCharacterName
    -- before removing the redundant author field.
    if data.author then
        local authorText = tostring(data.author or "")
        if authorText ~= "" and (not data.ownerCharacterName or tostring(data.ownerCharacterName or "") == "") then
            data.ownerCharacterName = authorText
        end
        if data.ownerCharacterName and tostring(data.ownerCharacterName or "") ~= "" then
            data.author = nil
            fieldsRemoved = fieldsRemoved + 1
        end
    end
    
    -- Remove empty contributors table (never used)
    if data.contributors then
        data.contributors = nil
        fieldsRemoved = fieldsRemoved + 1
    end
    
    -- Keep restored-origin flags. They drive runtime behavior (claim tracking and dissolution).
    -- Legacy journals may only have wasRestored, so preserve it for compatibility.
    if data.wasRestored == true and data.wasFromWorn ~= true and data.wasFromBloody ~= true then
        -- Legacy compatibility: treat generic restored as worn-origin when source is unknown.
        if data.isBloody == true then
            data.wasFromBloody = true
        else
            data.wasFromWorn = true
        end
    end
    
    -- Remove professionName (derivable from profession)
    if data.professionName then
        data.professionName = nil
        fieldsRemoved = fieldsRemoved + 1
    end
    
    -- NOTE: We no longer remove skill.level during compaction
    -- For passive skills (Fitness/Strength), the stored XP is "earned XP" (after baseline)
    -- but the level is the ABSOLUTE level at recording time. These cannot be derived from
    -- each other for passive skills due to different XP thresholds.
    -- Keeping level adds minimal overhead (one integer per skill) but ensures correct display.
    
    -- Simplify stats (remove verbose metadata - timestamp and recordedBy)
    if data.stats then
        for statName, statData in pairs(data.stats) do
            if type(statData) == "table" then
                if statData.timestamp ~= nil then
                    statData.timestamp = nil
                    fieldsRemoved = fieldsRemoved + 1
                end
                if statData.recordedBy ~= nil then
                    statData.recordedBy = nil
                    fieldsRemoved = fieldsRemoved + 1
                end
            end
        end
    end
    
    -- Remove legacy claim fields if per-character claims structure exists
    -- The migration system already copies these to the claims structure
    local hasClaimsTable = data.claims and type(data.claims) == "table"
    local claimsHasEntries = false
    if hasClaimsTable then
        -- Safely check if claims table has any entries
        for _ in pairs(data.claims) do
            claimsHasEntries = true
            break
        end
    end
    
    if claimsHasEntries then
        if data.claimedSkills then
            data.claimedSkills = nil
            fieldsRemoved = fieldsRemoved + 1
        end
        if data.claimedTraits then
            data.claimedTraits = nil
            fieldsRemoved = fieldsRemoved + 1
        end
        if data.claimedRecipes then
            data.claimedRecipes = nil
            fieldsRemoved = fieldsRemoved + 1
        end
        if data.claimedStats then
            data.claimedStats = nil
            fieldsRemoved = fieldsRemoved + 1
        end
    end
    
    -- Mark as compacted at current version
    data.compactVersion = BurdJournals.COMPACT_VERSION
    
    if fieldsRemoved > 0 then
        BurdJournals.debugPrint("[BurdJournals] Compacted journal data: removed " .. fieldsRemoved .. " redundant fields")
    end
end

-- Standard (non-passive) skill XP thresholds from PZ wiki
-- These are CUMULATIVE totals to reach each level
-- Per-level: 75, 150, 300, 750, 1500, 3000, 4500, 6000, 7500, 9000
BurdJournals.STANDARD_XP_THRESHOLDS = {
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
-- PZ's getTotalXpForLevel() returns incorrect values for passive skills
BurdJournals.PASSIVE_XP_THRESHOLDS = {
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

-- Helper function to get XP threshold for a skill at a given level
-- Uses our verified tables instead of potentially unreliable PZ API
function BurdJournals.getXPThresholdForLevel(skillName, level)
    if level <= 0 then return 0 end
    if level > 10 then level = 10 end
    
    if skillName == "Fitness" or skillName == "Strength" then
        return BurdJournals.PASSIVE_XP_THRESHOLDS[level] or 0
    else
        return BurdJournals.STANDARD_XP_THRESHOLDS[level] or 0
    end
end

-- Helper function to get skill level from XP (for backward compatibility with optimized journals)
-- Uses our verified XP threshold tables for reliability
-- Optional skillName parameter determines which threshold table to use
function BurdJournals.getSkillLevelFromXP(xp, skillName)
    if not xp or xp <= 0 then return 0 end
    
    -- Select the appropriate threshold table
    local thresholds
    if skillName == "Fitness" or skillName == "Strength" then
        thresholds = BurdJournals.PASSIVE_XP_THRESHOLDS
    else
        thresholds = BurdJournals.STANDARD_XP_THRESHOLDS
    end
    
    -- Find the highest level where XP meets the threshold
    local level = 0
    for i = 1, 10 do
        local threshold = thresholds[i]
        if threshold and xp >= threshold then
            level = i
        else
            break
        end
    end
    
    return level
end

-- Normalize legacy skill entries where level/xp are inconsistent (older patches).
-- For non-baseline journals (SET mode), if XP is missing/too low for the declared
-- level, upgrade XP to the exact threshold for that level.
function BurdJournals.normalizeLegacySkillEntry(skillName, skillData, recordedWithBaseline)
    if not skillData or type(skillData) ~= "table" then
        return 0, 0, false
    end

    local level = tonumber(skillData.level) or 0
    if level < 0 then level = 0 end
    if level > 10 then level = 10 end

    local xp = tonumber(skillData.xp) or 0
    local changed = false

    -- Baseline journals intentionally store earned/delta XP.
    if recordedWithBaseline ~= true and level > 0 then
        local thresholdXP = BurdJournals.getXPThresholdForLevel and BurdJournals.getXPThresholdForLevel(skillName, level) or 0

        if xp <= 0 and thresholdXP > 0 then
            xp = thresholdXP
            changed = true
        elseif BurdJournals.getSkillLevelFromXP and thresholdXP > 0 then
            local computed = BurdJournals.getSkillLevelFromXP(xp, skillName)
            if computed < level and xp < thresholdXP then
                xp = thresholdXP
                changed = true
            end
        end
    end

    return xp, level, changed
end

function BurdJournals.normalizeSkillVhsBreakdown(skillData)
    if not skillData or type(skillData) ~= "table" then
        return 0, 0, false
    end

    local netXP = math.max(0, tonumber(skillData.xp) or 0)
    local rawXP = tonumber(skillData.rawXP)
    if rawXP == nil then
        rawXP = netXP
    else
        rawXP = math.max(netXP, rawXP)
    end

    local vhsExcludedXP = tonumber(skillData.vhsExcludedXP)
    if vhsExcludedXP == nil then
        vhsExcludedXP = math.max(0, rawXP - netXP)
    else
        vhsExcludedXP = math.max(0, vhsExcludedXP)
    end
    if vhsExcludedXP > rawXP then
        vhsExcludedXP = rawXP
    end
    if rawXP < (netXP + vhsExcludedXP) then
        rawXP = netXP + vhsExcludedXP
    end

    local changed = false
    if tonumber(skillData.rawXP) ~= rawXP then
        skillData.rawXP = rawXP
        changed = true
    end
    if tonumber(skillData.vhsExcludedXP) ~= vhsExcludedXP then
        skillData.vhsExcludedXP = vhsExcludedXP
        changed = true
    end

    return rawXP, vhsExcludedXP, changed
end

function BurdJournals.migrateJournalIfNeeded(item, player)
    if not item then return end

    local modData = item:getModData()
    if not modData.BurdJournals then return end

    local journalData = modData.BurdJournals
    local migrated = false
    local targetMigrationSchemaVersion = tonumber(BurdJournals.MIGRATION_SCHEMA_VERSION) or 1
    local currentMigrationSchemaVersion = math.max(0, tonumber(journalData.migrationSchemaVersion) or 0)
    
    -- Keep legacy claim fields normalized even when schema stamp is already up to date.
    local function migrateLegacyClaimTablesToFallback()
        local hasLegacyClaimTable = type(journalData.claimedSkills) == "table"
            or type(journalData.claimedTraits) == "table"
            or type(journalData.claimedRecipes) == "table"
            or type(journalData.claimedStats) == "table"
        if not hasLegacyClaimTable then
            return false, false
        end

        if type(journalData.claims) ~= "table" then
            journalData.claims = {}
        end

        local legacyClaims = journalData.claims["legacy_unknown"]
        if type(legacyClaims) ~= "table" then
            legacyClaims = {}
            journalData.claims["legacy_unknown"] = legacyClaims
        end

        local changed = false
        local mergedAny = false
        local function mergeLegacyClaimTable(targetKey, sourceTable)
            if type(sourceTable) ~= "table" then
                return
            end
            if type(legacyClaims[targetKey]) ~= "table" then
                legacyClaims[targetKey] = {}
                changed = true
            end
            local targetTable = legacyClaims[targetKey]
            for claimKey, claimValue in pairs(sourceTable) do
                if claimKey ~= nil and claimValue and targetTable[claimKey] ~= true then
                    targetTable[claimKey] = true
                    changed = true
                    mergedAny = true
                end
            end
        end

        mergeLegacyClaimTable("skills", journalData.claimedSkills)
        mergeLegacyClaimTable("traits", journalData.claimedTraits)
        mergeLegacyClaimTable("recipes", journalData.claimedRecipes)
        mergeLegacyClaimTable("stats", journalData.claimedStats)

        -- Remove redundant legacy fields once fallback claims are guaranteed.
        if journalData.claimedSkills ~= nil then
            journalData.claimedSkills = nil
            changed = true
        end
        if journalData.claimedTraits ~= nil then
            journalData.claimedTraits = nil
            changed = true
        end
        if journalData.claimedRecipes ~= nil then
            journalData.claimedRecipes = nil
            changed = true
        end
        if journalData.claimedStats ~= nil then
            journalData.claimedStats = nil
            changed = true
        end

        return changed, mergedAny
    end
    
    local legacyClaimsMigrated, mergedLegacyClaims = migrateLegacyClaimTablesToFallback()
    if legacyClaimsMigrated then
        migrated = true
        if mergedLegacyClaims then
            BurdJournals.debugPrint("[BurdJournals] Migrated legacy claims to per-character structure (skills/traits/recipes/stats)")
        end
    end

    -- Migration step v1: ownership normalization, claim structure merge, debug flags, inferred journal origin.
    if currentMigrationSchemaVersion < 1 then
        if not journalData.ownerSteamId and journalData.ownerUsername and player then
            local playerUsername = player:getUsername()
            if playerUsername and journalData.ownerUsername == playerUsername then
                journalData.ownerSteamId = BurdJournals.getPlayerSteamId(player)
                migrated = true
                BurdJournals.debugPrint("[BurdJournals] Migrated journal ownership: added Steam ID " .. tostring(journalData.ownerSteamId))
            end
        end

        if not journalData.ownerSteamId and journalData.ownerUsername then

            journalData.ownerSteamId = "legacy_" .. journalData.ownerUsername
            migrated = true
            BurdJournals.debugPrint("[BurdJournals] Marked legacy journal with placeholder Steam ID: " .. journalData.ownerSteamId)
        end

        -- Legacy debug-edited journals from older patches may have isDebugEdited but no isDebugSpawned.
        -- Promote them so sanitization stays lenient across future updates.
        if journalData.isDebugEdited and not journalData.isDebugSpawned then
            journalData.isDebugSpawned = true
            migrated = true
            BurdJournals.debugPrint("[BurdJournals] Migrated debug-edited journal: set isDebugSpawned=true for update safety")
        end

        -- Ensure debug journals have stable UUID for backup/restore keying.
        if journalData.isDebugSpawned and not journalData.uuid then
            journalData.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
                or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(item:getID()))
            migrated = true
        end

        -- Legacy compatibility: some restored journals only used wasRestored.
        -- Normalize to canonical origin flags so runtime claim/dissolution policy stays stable.
        if BurdJournals.isRestoredJournalData(journalData)
            and journalData.wasFromWorn ~= true
            and journalData.wasFromBloody ~= true then
            if journalData.isBloody == true then
                journalData.wasFromBloody = true
            else
                journalData.wasFromWorn = true
            end
            migrated = true
        end

        -- Repair legacy restored/player-owned journals that were incorrectly stamped non-player.
        if journalData.isPlayerCreated == false
            and not journalData.isWorn
            and not journalData.isBloody
            and (journalData.ownerUsername or journalData.ownerSteamId or journalData.ownerCharacterName) then
            journalData.isPlayerCreated = true
            migrated = true
            BurdJournals.debugPrint("[BurdJournals] Migrated journal: corrected isPlayerCreated=true from owner fields")
        end

        -- Infer isPlayerCreated for legacy journals that have owner fields
        -- Without this, legacy player-created journals may be treated as looted and dissolve incorrectly
        if journalData.isPlayerCreated == nil then
            -- If journal has owner fields, it was likely player-created
            if journalData.ownerUsername or journalData.ownerSteamId or journalData.author then
                -- Check it's not a world-spawned journal (which might have author set)
                if not journalData.isWorn and not journalData.isBloody then
                    journalData.isPlayerCreated = true
                    migrated = true
                    BurdJournals.debugPrint("[BurdJournals] Migrated legacy journal: inferred isPlayerCreated=true from owner fields")
                else
                    journalData.isPlayerCreated = false
                    migrated = true
                    BurdJournals.debugPrint("[BurdJournals] Migrated legacy journal: inferred isPlayerCreated=false (worn/bloody)")
                end
            else
                -- No owner info - assume it's a world-spawned journal
                journalData.isPlayerCreated = false
                migrated = true
                BurdJournals.debugPrint("[BurdJournals] Migrated legacy journal: inferred isPlayerCreated=false (no owner)")
            end
        end

        currentMigrationSchemaVersion = 1
        journalData.migrationSchemaVersion = currentMigrationSchemaVersion
        migrated = true
    end

    -- Migration step v2: mode-3 per-skill diminishing counters from legacy global read counters.
    if currentMigrationSchemaVersion < 2 then
        local legacyReadSeed = math.max(
            math.max(0, tonumber(journalData.readCount) or 0),
            math.max(0, tonumber(journalData.readSessionCount) or 0),
            math.max(0, tonumber(journalData.currentSessionReadCount) or 0)
        )
        if legacyReadSeed > 0 and journalData.drLegacyMode3Migrated ~= true then
            local skillReadCounts = journalData.skillReadCounts
            if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
                skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
                if type(skillReadCounts) == "table" then
                    journalData.skillReadCounts = skillReadCounts
                end
            end
            if type(skillReadCounts) ~= "table" then
                skillReadCounts = {}
                journalData.skillReadCounts = skillReadCounts
            end

            local hasPositiveSkillCount = false
            for _, count in pairs(skillReadCounts) do
                if (tonumber(count) or 0) > 0 then
                    hasPositiveSkillCount = true
                    break
                end
            end

            local seededAny = false
            if not hasPositiveSkillCount then
                local skills = journalData.skills
                if type(skills) ~= "table" and BurdJournals.normalizeTable then
                    skills = BurdJournals.normalizeTable(skills)
                    if type(skills) == "table" then
                        journalData.skills = skills
                    end
                end

                if type(skills) == "table" then
                    for skillName, _ in pairs(skills) do
                        if type(skillName) == "string" and skillName ~= "" then
                            skillReadCounts[skillName] = legacyReadSeed
                            seededAny = true
                        end
                    end
                end
            end

            -- Mark complete after first migration attempt so deliberate debug resets to 0 do not reseed.
            journalData.drLegacyMode3Migrated = true
            migrated = true
            if seededAny then
                BurdJournals.debugPrint("[BurdJournals] Migrated legacy DR counters to per-skill seed=" .. tostring(legacyReadSeed))
            end
        end

        currentMigrationSchemaVersion = 2
        journalData.migrationSchemaVersion = currentMigrationSchemaVersion
        migrated = true
    end

    -- Migration step v3: ensure every skill has normalized VHS breakdown fields.
    if currentMigrationSchemaVersion < 3 then
        local skills = journalData.skills
        if type(skills) ~= "table" and BurdJournals.normalizeTable then
            skills = BurdJournals.normalizeTable(skills)
            if type(skills) == "table" then
                journalData.skills = skills
            end
        end

        if type(skills) == "table" then
            for _, skillData in pairs(skills) do
                if type(skillData) == "table" and BurdJournals.normalizeSkillVhsBreakdown then
                    local _, _, changed = BurdJournals.normalizeSkillVhsBreakdown(skillData)
                    if changed then
                        migrated = true
                    end
                end
            end
        end

        currentMigrationSchemaVersion = 3
        journalData.migrationSchemaVersion = currentMigrationSchemaVersion
        migrated = true
    end

    -- Forward compatibility: if schema target is bumped later, stamp journals once.
    if currentMigrationSchemaVersion < targetMigrationSchemaVersion then
        journalData.migrationSchemaVersion = targetMigrationSchemaVersion
        migrated = true
    end

    -- Run sanitization if needed (checks version internally)
    local currentSanitizeVersion = BurdJournals.SANITIZE_VERSION or 1
    local journalSanitizeVersion = journalData.sanitizedVersion or 0
    if journalSanitizeVersion < currentSanitizeVersion then
        -- Note: sanitizeJournalData handles its own transmitModData
        local sanitizeResult = BurdJournals.sanitizeJournalData(item, player)
        if sanitizeResult and sanitizeResult.cleaned then
            migrated = true
        end
    end

    if migrated then
        -- Safety check: ensure transmitModData exists (in case item became invalid)
        if item.transmitModData then
            item:transmitModData()
        end
    end
    
    -- Compact journal data after migration to reduce ModData size
    -- This helps prevent hitting the 64KB player data limit
    if BurdJournals.compactJournalData then
        BurdJournals.compactJournalData(item)
    end
end

-- Sanitize journal data by removing/auto-claiming invalid entries
-- Invalid entries include: removed mod content, skill category names, corrupted data
-- Returns a result table with what was cleaned
function BurdJournals.sanitizeJournalData(item, player)
    if not item then return { cleaned = false } end

    local modData = item:getModData()
    if not modData.BurdJournals then return { cleaned = false } end

    local data = modData.BurdJournals

    -- Check if already sanitized at current version
    local currentVersion = BurdJournals.SANITIZE_VERSION or 1
    if data.sanitizedVersion and data.sanitizedVersion >= currentVersion then
        return { cleaned = false, alreadySanitized = true }
    end
    
    -- DEBUG-SPAWNED JOURNALS: More lenient sanitization to preserve data across restarts
    -- These journals may have data that was valid at spawn time but might fail lookup
    -- after a mod update or server restart (e.g., skill perks not loaded yet)
    if data.isDebugSpawned or data.isDebugEdited then
        BurdJournals.debugPrint("[BurdJournals] Sanitizing debug-spawned journal - using lenient mode")
        -- Only mark as sanitized, don't remove any data
        -- This preserves all skills/traits/recipes that were valid when spawned
        data.isDebugSpawned = true
        data.isDebugEdited = true
        data.isPlayerCreated = true
        if not data.uuid then
            data.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
                or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(item:getID()))
        end
        data.sanitizedVersion = currentVersion
        if item.transmitModData then
            item:transmitModData()
        end
        return { cleaned = false, debugSpawnedPreserved = true }
    end

    local result = {
        cleaned = false,
        removedSkills = {},
        removedTraits = {},
        removedRecipes = {},
        autoClaimedSkills = {},
        autoClaimedTraits = {},
        autoClaimedRecipes = {}
    }

    -- Build set of known skill IDs (both name and lowercase for comparison)
    local validSkillSet = {}
    local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
    for _, skill in ipairs(allowedSkills) do
        validSkillSet[skill] = true
        validSkillSet[string.lower(skill)] = true
    end
    -- If perk registry is unavailable at sanitize time, avoid destructive false negatives.
    local validationHasPerkRegistry = (Perks ~= nil) and (PerkFactory ~= nil) and (PerkFactory.getPerk ~= nil)

    -- Helper: Check if skill is valid.
    -- Prefer runtime perk lookup; fall back to known IDs; fail-open if registry is unavailable.
    local function isValidSkill(skillName)
        if type(skillName) ~= "string" or skillName == "" then
            return false
        end
        local perk = (Perks and BurdJournals.getPerkByName) and BurdJournals.getPerkByName(skillName) or nil
        if perk ~= nil then
            return true
        end
        local lowerName = string.lower(skillName)
        if validSkillSet[skillName] or validSkillSet[lowerName] then
            return true
        end
        if not validationHasPerkRegistry then
            return true
        end
        return false
    end

    -- Helper: Check if trait exists in game
    local function isValidTrait(traitId)
        if not traitId then return false end
        -- Check TraitFactory (works for both Build 41 and 42)
        if TraitFactory and TraitFactory.getTrait then
            local trait = TraitFactory.getTrait(traitId)
            if trait then return true end
        end
        -- Build 42: iterate CharacterTraitDefinition.getTraits() to find by name
        -- Note: CharacterTraitDefinition.getCharacterTraitDefinition() expects a CharacterTrait enum,
        -- not a string, and throws a Java exception that pcall cannot catch
        if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
            local allTraits = CharacterTraitDefinition.getTraits()
            if allTraits and allTraits.size and allTraits.get then
                local traitIdLower = string.lower(traitId)
                for i = 0, allTraits:size() - 1 do
                    local def = allTraits:get(i)
                    if def then
                        local defType = def:getType()
                        if defType then
                            local defName = defType:getName()
                            if defName and string.lower(defName) == traitIdLower then
                                return true
                            end
                        end
                    end
                end
            end
        end
        return false
    end

    -- Build recipe name cache using the mod's magazine recipe system (which actually works!)
    -- getAllRecipes() returns 0 in some contexts, but BurdJournals.buildMagazineRecipeCache() works
    local validRecipeSet = {}
    local recipeCacheBuilt = false
    local recipeCacheCount = 0
    local function buildRecipeCache()
        if recipeCacheBuilt then return end  -- Already built
        recipeCacheBuilt = true  -- Mark as built before iteration to prevent re-entry
        
        -- Use the mod's own magazine recipe cache which is reliable
        if BurdJournals.buildMagazineRecipeCache then
            local magazineCache = BurdJournals.buildMagazineRecipeCache()
            if magazineCache then
                for recipeName, _ in pairs(magazineCache) do
                    validRecipeSet[recipeName] = true
                    validRecipeSet[string.lower(recipeName)] = true
                    recipeCacheCount = recipeCacheCount + 1
                end
            end
        end
        
        -- Also check getAllRecipes() as fallback for non-magazine recipes
        local recipes = getAllRecipes and getAllRecipes() or nil
        if recipes and recipes.size and recipes.get then
            local size = recipes:size()
            for i = 0, size - 1 do
                local recipe = recipes:get(i)
                if recipe and recipe.getName then
                    local name = recipe:getName()
                    if name and type(name) == "string" then
                        if not validRecipeSet[name] then
                            validRecipeSet[name] = true
                            validRecipeSet[string.lower(name)] = true
                            recipeCacheCount = recipeCacheCount + 1
                        end
                    end
                end
            end
        end
        
        print("[BurdJournals] Recipe cache built with " .. tostring(recipeCacheCount) .. " entries")
    end

    -- Helper: Check if recipe exists in game (uses cached set)
    local function isValidRecipe(recipeName)
        if not recipeName then return false end
        buildRecipeCache()
        local found = validRecipeSet[recipeName] or validRecipeSet[string.lower(recipeName)] or false
        return found
    end

    -- Sanitize skills
    if type(data.skills) == "table" then
        local cleanedSkills = {}
        for skillName, skillData in pairs(data.skills) do
            if isValidSkill(skillName) then
                cleanedSkills[skillName] = skillData
            else
                -- Invalid skill - remove from skills and auto-claim so it doesn't block dissolution
                table.insert(result.removedSkills, skillName)
                if not data.claimedSkills then data.claimedSkills = {} end
                data.claimedSkills[skillName] = true
                table.insert(result.autoClaimedSkills, skillName)
                result.cleaned = true
            end
        end
        data.skills = cleanedSkills
    end

    -- Sanitize traits
    if type(data.traits) == "table" then
        local cleanedTraits = {}
        for traitId, traitData in pairs(data.traits) do
            if isValidTrait(traitId) then
                cleanedTraits[traitId] = traitData
            else
                -- Invalid trait - remove and auto-claim
                table.insert(result.removedTraits, traitId)
                if not data.claimedTraits then data.claimedTraits = {} end
                data.claimedTraits[traitId] = true
                table.insert(result.autoClaimedTraits, traitId)
                result.cleaned = true
            end
        end
        data.traits = cleanedTraits
    end

    -- Sanitize recipes
    if type(data.recipes) == "table" then
        local cleanedRecipes = {}
        for recipeName, recipeData in pairs(data.recipes) do
            if isValidRecipe(recipeName) then
                cleanedRecipes[recipeName] = recipeData
            else
                -- Invalid recipe - remove and auto-claim
                table.insert(result.removedRecipes, recipeName)
                if not data.claimedRecipes then data.claimedRecipes = {} end
                data.claimedRecipes[recipeName] = true
                table.insert(result.autoClaimedRecipes, recipeName)
                result.cleaned = true
            end
        end
        data.recipes = cleanedRecipes
    end

    -- Mark as sanitized at current version
    data.sanitizedVersion = currentVersion

    -- Transmit changes if anything was cleaned
    if result.cleaned then
        if item.transmitModData then
            item:transmitModData()
        end

        -- Helper to safely convert entries to strings for logging
        local function safeConcat(tbl)
            local strs = {}
            for _, v in ipairs(tbl) do
                table.insert(strs, tostring(v))
            end
            return table.concat(strs, ", ")
        end

        -- Log what was cleaned (only in debug mode)
        if #result.removedSkills > 0 then
            BurdJournals.debugPrint("[BurdJournals] Sanitized: Removed " .. #result.removedSkills .. " invalid skills: " .. safeConcat(result.removedSkills))
        end
        if #result.removedTraits > 0 then
            BurdJournals.debugPrint("[BurdJournals] Sanitized: Removed " .. #result.removedTraits .. " invalid traits: " .. safeConcat(result.removedTraits))
        end
        if #result.removedRecipes > 0 then
            BurdJournals.debugPrint("[BurdJournals] Sanitized: Removed " .. #result.removedRecipes .. " invalid recipes: " .. safeConcat(result.removedRecipes))
        end

        local totalRemoved = #result.removedSkills + #result.removedTraits + #result.removedRecipes
        BurdJournals.debugPrint("[BurdJournals] Sanitized journal: removed " .. totalRemoved .. " invalid entries")
    else
        -- Even if nothing was cleaned, update sanitizedVersion to avoid re-checking
        if item.transmitModData then
            item:transmitModData()
        end
    end

    return result
end

function BurdJournals.isDebug()
    return isDebugEnabled and isDebugEnabled() or false
end

-- Debug logging helper - only prints when running with -debug flag
-- Use for verbose operational logs. Keep print() for errors/warnings.
function BurdJournals.debugPrint(msg)
    if BurdJournals.isDebug() or BurdJournals.verboseLogging then
        print(msg)
    end
end

function BurdJournals.runSelfTests()
    local results = {
        total = 0,
        passed = 0,
        failed = 0,
        skipped = 0,
        failures = {}
    }

    local function run(name, fn)
        results.total = results.total + 1
        local ok, err = safePcall(fn)
        if ok then
            results.passed = results.passed + 1
            return
        end

        results.failed = results.failed + 1
        table.insert(results.failures, {
            name = name,
            err = tostring(err)
        })
    end

    local function skip(name, reason)
        results.total = results.total + 1
        results.skipped = results.skipped + 1
        print("[BSJ SELFTEST] SKIP " .. tostring(name) .. ": " .. tostring(reason))
    end

    run("normalizeTraitId strips base prefix", function()
        if BurdJournals.normalizeTraitId("base:Strong") ~= "Strong" then
            error("Expected base:Strong -> Strong")
        end
        if BurdJournals.normalizeTraitId("Base.Strong") ~= "Strong" then
            error("Expected Base.Strong -> Strong")
        end
    end)

    run("resolveSkillKey is case-insensitive", function()
        local skills = {Aiming = {xp = 0, level = 0}}
        local key = BurdJournals.resolveSkillKey(skills, "aiming")
        if key ~= "Aiming" then
            error("Expected key Aiming, got " .. tostring(key))
        end
    end)

    run("buildTraitLookup recognizes prefixed IDs", function()
        local lookup = BurdJournals.buildTraitLookup({
            ["Strong"] = true,
            ["base:Athletic"] = true
        })
        if not BurdJournals.isTraitInLookup(lookup, "Strong") then
            error("Strong should be present")
        end
        if not BurdJournals.isTraitInLookup(lookup, "Athletic") then
            error("Athletic should be present via base: prefix")
        end
    end)

    run("normalizeTable clones Lua tables", function()
        local input = {A = 1, B = 2}
        local output = BurdJournals.normalizeTable(input)
        if type(output) ~= "table" then
            error("normalizeTable should return a table")
        end
        if output.A ~= 1 or output.B ~= 2 then
            error("normalizeTable should preserve key/value pairs")
        end
        if output == input then
            error("normalizeTable should return a clone, not same reference")
        end
    end)

    run("normalizeJournalData initializes required containers", function()
        local normalized = BurdJournals.normalizeJournalData({foo = "bar"})
        if type(normalized) ~= "table" then
            error("normalizeJournalData should return table")
        end
        if type(normalized.skills) ~= "table" then
            error("normalized.skills should be table")
        end
        if type(normalized.traits) ~= "table" then
            error("normalized.traits should be table")
        end
        if type(normalized.recipes) ~= "table" then
            error("normalized.recipes should be table")
        end
        if type(normalized.stats) ~= "table" then
            error("normalized.stats should be table")
        end
        if type(normalized.claims) ~= "table" then
            error("normalized.claims should be table")
        end
    end)

    if type(getText) == "function" then
        run("safeGetText falls back on missing key", function()
            local missing = BurdJournals.safeGetText("UI_BSJ_MISSING_KEY", "FallbackValue")
            if missing ~= "FallbackValue" then
                error("Expected fallback for missing key, got " .. tostring(missing))
            end
        end)
    else
        skip("safeGetText falls back on missing key", "getText() unavailable")
    end

    results.ok = results.failed == 0
    results.summary = string.format("BSJ self-tests: %d passed, %d failed, %d skipped", results.passed, results.failed, results.skipped)

    print("[BSJ SELFTEST] " .. results.summary)
    if results.failed > 0 then
        for _, failure in ipairs(results.failures) do
            print("[BSJ SELFTEST] FAIL " .. tostring(failure.name) .. ": " .. tostring(failure.err))
        end
    end

    return results
end

-- Debug helper to print actual XP thresholds from getTotalXpForLevel(N) for N=0 through 10
-- Use this to verify XP threshold values and debug level calculation issues
-- Always prints (not gated by isDebug) since this is explicitly called for diagnostics
function BurdJournals.debugPrintXPThresholds(skillName)
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk or not perk.getTotalXpForLevel then
        print("[BurdJournals] Cannot get XP thresholds for: " .. tostring(skillName))
        return
    end
    print("================================================================================")
    print("[BurdJournals] XP Thresholds for " .. tostring(skillName) .. ":")
    print("  getTotalXpForLevel(N) returns the XP threshold to BE AT level N")
    print("--------------------------------------------------------------------------------")
    for i = 0, 10 do
        local xp = perk:getTotalXpForLevel(i)
        print(string.format("  Level %2d: %s XP", i, tostring(xp)))
    end
    print("================================================================================")
end

function BurdJournals.isSkillAllowed(skillName)
    local allowedSkills = BurdJournals.getAllowedSkills()
    for _, skill in ipairs(allowedSkills) do
        if skill == skillName or string.lower(skill) == string.lower(skillName) then
            return true
        end
    end
    return false
end

function BurdJournals.getAllowedSkills()

    return BurdJournals.discoverAllSkills()
end

function BurdJournals.getPerkByName(perkName, allowCategories)
    local actualPerkName = BurdJournals.SKILL_TO_PERK[perkName] or perkName
    local perk = Perks[actualPerkName]
    if perk then
        -- By default, only return trainable skills (not category perks)
        -- Use allowCategories=true if you need to look up category perks
        if not allowCategories then
            -- Check if this is a trainable skill using PerkFactory
            local perkDef = PerkFactory and PerkFactory.getPerk and PerkFactory.getPerk(perk)
            if perkDef then
                -- Use isTrainableSkill to check parent - trainable skills have parent != "None"
                if BurdJournals.isTrainableSkill(perkDef) then
                    return perk
                else
                    -- This is a category perk, not trainable
                    return nil
                end
            end
            -- PerkFactory not available yet (early loading) - fall back to known category list
            -- Only exclude things that are DEFINITELY categories and NOT also skills
            local pureCategories = {
                None = true, MAX = true, Combat = true, Firearm = true,
                Agility = true, Crafting = true, Passive = true,
                Melee = true, Physical = true
                -- NOTE: "Farming" and "Survival" are NOT here because they are ALSO skill names
            }
            if pureCategories[actualPerkName] then
                return nil
            end
            -- Assume it's a valid skill if we can't verify
            return perk
        end
        return perk
    end
    return nil
end

function BurdJournals.getPerkDisplayName(perkName)
    local perk = BurdJournals.getPerkByName(perkName)
    if perk and PerkFactory and PerkFactory.getPerk then
        local perkDef = PerkFactory.getPerk(perk)
        if perkDef and perkDef.getName then
            return perkDef:getName()
        end
    end
    return perkName
end

function BurdJournals.getSkillNameFromPerk(perk)
    if not perk then return nil end

    local perkName = nil

    if type(perk) == "string" then
        perkName = perk
    end

    if not perkName and PerkFactory and PerkFactory.getPerk then
        local perkDef = PerkFactory.getPerk(perk)
        if perkDef then
            if perkDef.getId then
                perkName = tostring(perkDef:getId())
            elseif perkDef.getName then
                perkName = perkDef:getName()
            end
        end
    end

    if not perkName and perk.name then
        perkName = tostring(perk.name)
    end

    if not perkName then
        perkName = tostring(perk)

        perkName = perkName:gsub("^Perks%.", "")
        perkName = perkName:gsub("^zombie%.characters%.skills%.PerkFactory%$Perk%.", "")
        perkName = perkName:gsub("^zombie%.characters%.skills%.PerkFactory%$", "")
    end

    if not perkName or perkName == "" then return nil end

    local reverseMap = {
        PlantScavenging = "Foraging",
        Woodwork = "Carpentry"
    }
    if reverseMap[perkName] then
        return reverseMap[perkName]
    end

    local allowedSkills = BurdJournals.getAllowedSkills()
    for _, skillName in ipairs(allowedSkills) do
        if skillName == perkName then
            return skillName
        end
    end

    local lowerPerkName = string.lower(perkName)
    for _, skillName in ipairs(allowedSkills) do
        if string.lower(skillName) == lowerPerkName then
            return skillName
        end
    end

    for _, skillName in ipairs(allowedSkills) do
        local displayName = BurdJournals.getPerkDisplayName(skillName)
        if displayName == perkName or string.lower(displayName) == lowerPerkName then
            return skillName
        end
    end

    return nil
end

function BurdJournals.findItemByIdInContainer(container, itemId)
    if not container then return nil end

    local items = container:getItems()
    if not items then return nil end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then

            if item:getID() == itemId then
                return item
            end

            if item.getInventory then
                local itemInventory = item:getInventory()
                if itemInventory then
                    local found = BurdJournals.findItemByIdInContainer(itemInventory, itemId)
                    if found then return found end
                end
            end
        end
    end
    return nil
end

function BurdJournals.findItemById(player, itemId)
    if not player then return nil end

    local inventory = player:getInventory()
    if inventory then
        local found = BurdJournals.findItemByIdInContainer(inventory, itemId)
        if found then return found end
    end

    if getPlayerLoot and not isServer() then
        local playerNum = player:getPlayerNum()
        if playerNum then
            local lootInventory = getPlayerLoot(playerNum)
            if lootInventory and lootInventory.inventoryPane then
                local inventoryPane = lootInventory.inventoryPane
                if inventoryPane.inventories then
                    for i = 1, #inventoryPane.inventories do
                        local containerInfo = inventoryPane.inventories[i]
                        if containerInfo and containerInfo.inventory then
                            local found = BurdJournals.findItemByIdInContainer(containerInfo.inventory, itemId)
                            if found then return found end
                        end
                    end
                end
            end
        end
    end

    local square = player:getCurrentSquare()
    if square then

        for dx = -1, 1 do
            for dy = -1, 1 do
                local nearSquare = getCell():getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ())
                if nearSquare then

                    local objects = nearSquare:getObjects()
                    if objects then
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if obj and obj.getContainer then
                                local container = obj:getContainer()
                                if container then
                                    local found = BurdJournals.findItemByIdInContainer(container, itemId)
                                    if found then return found end
                                end
                            end

                            if obj and obj.getInventory then
                                local container = obj:getInventory()
                                if container then
                                    local found = BurdJournals.findItemByIdInContainer(container, itemId)
                                    if found then return found end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

BurdJournals.WRITING_TOOLS = {
    "Base.Pen",
    "Base.BluePen",
    "Base.GreenPen",
    "Base.RedPen",
    "Base.Pencil",
    "Base.PencilSpiffo",
    "Base.PenFancy",
    "Base.PenMultiColor",
    "Base.PenSpiffo",
    "Base.PenLight",
}

function BurdJournals.findWritingTool(player)
    if not player then return nil end
    local inventory = player:getInventory()
    if not inventory then return nil end

    for _, toolType in ipairs(BurdJournals.WRITING_TOOLS) do
        local tool = inventory:getFirstTypeRecurse(toolType)
        if tool then return tool end
    end

    return nil
end

function BurdJournals.findEraser(player)
    if not player then return nil end
    local inventory = player:getInventory()
    if not inventory then return nil end

    return inventory:getFirstTypeRecurse("Base.Eraser")
end

function BurdJournals.hasWritingTool(player)
    return BurdJournals.findWritingTool(player) ~= nil
end

function BurdJournals.hasEraser(player)
    return BurdJournals.findEraser(player) ~= nil
end

BurdJournals.CLEANING_ITEMS = {
    soap = {"Base.Soap2"},
    cloth = {"Base.RippedSheets", "Base.RippedSheetsBundle", "Base.DishCloth"},
}

BurdJournals.REPAIR_ITEMS = {
    leather = {"Base.LeatherStrips", "Base.LeatherStripsDirty"},
    thread = {"Base.Thread", "Base.Thread_Sinew", "Base.Thread_Aramid"},
    needle = {"Base.Needle", "Base.Needle_Bone", "Base.Needle_Brass", "Base.Needle_Forged", "Base.SutureNeedle"},
}

function BurdJournals.findCleaningItem(player, category)
    if not player then return nil end
    local inventory = player:getInventory()
    if not inventory then return nil end

    local items = BurdJournals.CLEANING_ITEMS[category]
    if not items then return nil end

    for _, itemType in ipairs(items) do
        local item = inventory:getFirstTypeRecurse(itemType)
        if item then return item end
    end
    return nil
end

function BurdJournals.findRepairItem(player, category)
    if not player then return nil end
    local inventory = player:getInventory()
    if not inventory then return nil end

    local items = BurdJournals.REPAIR_ITEMS[category]
    if not items then return nil end

    for _, itemType in ipairs(items) do
        local item = inventory:getFirstTypeRecurse(itemType)
        if item then return item end
    end
    return nil
end

function BurdJournals.canConvertToClean(player)
    local hasLeather = BurdJournals.findRepairItem(player, "leather") ~= nil
    local hasThread = BurdJournals.findRepairItem(player, "thread") ~= nil
    local hasNeedle = BurdJournals.findRepairItem(player, "needle") ~= nil
    local hasTailoring = player:getPerkLevel(Perks.Tailoring) >= 1
    return hasLeather and hasThread and hasNeedle and hasTailoring
end

function BurdJournals.consumeItemUses(item, uses, player)
    if not item then return end
    if not uses or uses <= 0 then return end
    if not player then
        player = getPlayer()
    end
    if not player then return end

    local inventory = player:getInventory()
    if not inventory then return end

    if item.getUsedDelta and item.setUsedDelta then
        local currentDelta = item:getUsedDelta()
        if currentDelta == nil then currentDelta = 1 end

        local perUse = 0.1
        if item.getUseDelta then
            local d = item:getUseDelta()
            if d and d > 0 then
                perUse = d
            end
        end

        local newDelta = currentDelta - (uses * perUse)
        if newDelta <= 0 then
            inventory:Remove(item)
        else
            item:setUsedDelta(newDelta)
        end
        return
    end

    if item.getDrainableUsesFloat and item.setDrainableUsesFloat then
        local currentUses = item:getDrainableUsesFloat()
        if currentUses == nil then currentUses = 1 end

        local newUses = currentUses - uses
        if newUses <= 0 then
            inventory:Remove(item)
        else
            item:setDrainableUsesFloat(newUses)
        end
        return
    end
end

BurdJournals.BLANK_JOURNAL_TYPES = {
    "BurdJournals.BlankSurvivalJournal",
    "BurdJournals.BlankSurvivalJournal_Worn",
    "BurdJournals.BlankSurvivalJournal_Bloody",
}

BurdJournals.FILLED_JOURNAL_TYPES = {
    "BurdJournals.FilledSurvivalJournal",
    "BurdJournals.FilledSurvivalJournal_Worn",
    "BurdJournals.FilledSurvivalJournal_Bloody",
}

BurdJournals.SPECIAL_JOURNAL_TYPES = {
    [BurdJournals.CURSED_ITEM_TYPE] = true,
}

local function getItemModData(item)
    if not (item and item.getModData) then return nil end
    return item:getModData()
end

local function getItemFullType(item)
    if not (item and item.getFullType) then return nil end
    local fullType = item:getFullType()
    return fullType and tostring(fullType) or nil
end

local function fullTypeContainsToken(fullType, token)
    return type(fullType) == "string"
        and type(token) == "string"
        and token ~= ""
        and string.find(fullType, token, 1, true) ~= nil
end

local function isWornFullType(fullType)
    return fullTypeContainsToken(fullType, "_Worn")
        or fullTypeContainsToken(fullType, ".Worn")
        or fullTypeContainsToken(fullType, "WornSurvivalJournal")
end

local function isBloodyFullType(fullType)
    return fullTypeContainsToken(fullType, "_Bloody")
        or fullTypeContainsToken(fullType, ".Bloody")
        or fullTypeContainsToken(fullType, "BloodySurvivalJournal")
end

local function getItemJournalModData(item)
    local modData = getItemModData(item)
    if not modData then return nil end
    return modData.BurdJournals
end

function BurdJournals.isBlankJournal(item)
    if not item then return false end
    local fullType = getItemFullType(item)
    if not fullType then return false end
    for _, jType in ipairs(BurdJournals.BLANK_JOURNAL_TYPES) do
        if fullType == jType then return true end
    end
    return false
end

function BurdJournals.isFilledJournal(item)
    if not item then return false end
    local fullType = getItemFullType(item)
    if not fullType then return false end
    for _, jType in ipairs(BurdJournals.FILLED_JOURNAL_TYPES) do
        if fullType == jType then return true end
    end
    return false
end

function BurdJournals.isAnyJournal(item)
    if not item then return false end

    if BurdJournals.isBlankJournal(item) or BurdJournals.isFilledJournal(item) then
        return true
    end

    local fullType = getItemFullType(item)
    if fullType and BurdJournals.SPECIAL_JOURNAL_TYPES[fullType] then
        return true
    end
    if fullType and fullType:find("BurdJournals") and fullType:find("SurvivalJournal") then
        return true
    end

    return false
end

function BurdJournals.isCursedJournalItem(item)
    if not item then return false end
    local fullType = getItemFullType(item)
    local data = getItemJournalModData(item)
    local isUnleashedReward = data and (data.isCursedReward == true or data.cursedState == "unleashed")

    if fullType and fullType == BurdJournals.CURSED_ITEM_TYPE then
        return not isUnleashedReward
    end

    return data and data.isCursedJournal == true and data.cursedState ~= "unleashed"
end

function BurdJournals.isWorn(item)
    if not item then return false end

    local data = getItemJournalModData(item)
    if data and data.isWorn == true then
        return true
    end

    local fullType = getItemFullType(item)
    if isWornFullType(fullType) then
        return true
    end

    return false
end

function BurdJournals.isBloody(item)
    if not item then return false end

    local data = getItemJournalModData(item)
    if data and data.isBloody == true then
        return true
    end

    local fullType = getItemFullType(item)
    if isBloodyFullType(fullType) then
        return true
    end

    return false
end

function BurdJournals.isCursedReward(item)
    if not item then return false end
    local data = getItemJournalModData(item)
    return data and data.isCursedReward == true
end

function BurdJournals.isClean(item)
    if not item then return false end
    return not BurdJournals.isWorn(item) and not BurdJournals.isBloody(item)
end

function BurdJournals.wasFromBloody(item)
    if not item then return false end
    local data = getItemJournalModData(item)
    return data and data.wasFromBloody == true
end

function BurdJournals.hasBloodyOrigin(item)
    return BurdJournals.isBloody(item) or BurdJournals.wasFromBloody(item)
end

function BurdJournals.isPlayerJournal(item)
    if not item then return false end
    local data = getItemJournalModData(item)
    return data and data.isPlayerCreated == true
end

function BurdJournals.isRestoredJournal(item)
    if not item then return false end
    local data = BurdJournals.getJournalData(item)
    if not data then return false end
    if not data.isPlayerCreated then return false end
    return BurdJournals.isRestoredJournalData(data)
end

function BurdJournals.setWorn(item, worn)
    if not item then return end
    local modData = getItemModData(item)
    if not modData then return end
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    modData.BurdJournals.isWorn = worn
    modData.BurdJournals.isBloody = false
    BurdJournals.updateJournalIcon(item)
    BurdJournals.updateJournalName(item)
end

function BurdJournals.setBloody(item, bloody)
    if not item then return end
    local modData = getItemModData(item)
    if not modData then return end
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    modData.BurdJournals.isBloody = bloody
    modData.BurdJournals.isWorn = false
    BurdJournals.updateJournalIcon(item)
    BurdJournals.updateJournalName(item)
end

function BurdJournals.setClean(item)
    if not item then return end
    local modData = getItemModData(item)
    if not modData then return end
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    modData.BurdJournals.isWorn = false
    modData.BurdJournals.isBloody = false
    modData.BurdJournals.wasFromBloody = false
    modData.BurdJournals.isPlayerCreated = true
    BurdJournals.updateJournalIcon(item)
    BurdJournals.updateJournalName(item)
end

function BurdJournals.isReadable(item)
    if not item then return false end

    if BurdJournals.isBlankJournal(item) then return false end

    if BurdJournals.isFilledJournal(item) then return true end
    return false
end

function BurdJournals.canAbsorbXP(item)
    if not item then return false end
    if not BurdJournals.isFilledJournal(item) then return false end

    return BurdJournals.isWorn(item) or BurdJournals.isBloody(item)
end

function BurdJournals.canSetXP(item)
    if not item then return false end
    if not BurdJournals.isFilledJournal(item) then return false end
    return BurdJournals.isClean(item)
end

function BurdJournals.getClaimedSkills(item)
    if not item then return {} end
    local data = getItemJournalModData(item)
    if data and data.claimedSkills then
        return data.claimedSkills
    end
    return {}
end

function BurdJournals.isSkillClaimed(item, skillName)
    local claimed = BurdJournals.getClaimedSkills(item)
    return claimed[skillName] == true
end

function BurdJournals.claimSkill(item, skillName)
    if not item then return false end
    local modData = getItemModData(item)
    if not modData then return false end
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    if not modData.BurdJournals.claimedSkills then
        modData.BurdJournals.claimedSkills = {}
    end
    modData.BurdJournals.claimedSkills[skillName] = true
    return true
end

function BurdJournals.getUnclaimedSkills(item, player)
    if not item then return {} end
    local data = BurdJournals.getJournalData(item)
    if not data or not data.skills then return {} end

    local unclaimed = {}

    for skillName, skillData in pairs(data.skills) do
        local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(data, skillName)
        if enabledForJournal then
            -- Use per-character claims if player provided, otherwise global
            local isClaimed = false
            if player then
                isClaimed = BurdJournals.hasCharacterClaimedSkill(data, player, skillName)
            else
                local claimed = BurdJournals.getClaimedSkills(item)
                isClaimed = claimed[skillName]
            end
            if not isClaimed then
                unclaimed[skillName] = skillData
            end
        end
    end

    return unclaimed
end

function BurdJournals.getUnclaimedSkillCount(item, player)
    local unclaimed = BurdJournals.getUnclaimedSkills(item, player)
    return BurdJournals.countTable(unclaimed)
end

function BurdJournals.getTotalSkillCount(item)
    if not item then return 0 end
    local data = BurdJournals.getJournalData(item)
    if not data or not data.skills then return 0 end
    local count = 0
    for skillName, _ in pairs(data.skills) do
        local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(data, skillName)
        if enabledForJournal then
            count = count + 1
        end
    end
    return count
end

function BurdJournals.getClaimedTraits(item)
    if not item then return {} end
    local data = getItemJournalModData(item)
    if data and data.claimedTraits then
        return data.claimedTraits
    end
    return {}
end

function BurdJournals.isTraitClaimed(item, traitId)
    local claimed = BurdJournals.getClaimedTraits(item)
    return claimed[traitId] == true
end

function BurdJournals.claimTrait(item, traitId)
    if not item then return false end
    local modData = getItemModData(item)
    if not modData then return false end
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    if not modData.BurdJournals.claimedTraits then
        modData.BurdJournals.claimedTraits = {}
    end
    modData.BurdJournals.claimedTraits[traitId] = true
    return true
end

function BurdJournals.getUnclaimedTraits(item, player)
    if not item then return {} end
    local data = BurdJournals.getJournalData(item)
    if not data or not data.traits then return {} end

    local unclaimed = {}

    for traitId, traitData in pairs(data.traits) do
        local enabledForJournal = true
        if BurdJournals.isTraitEnabledForJournal then
            enabledForJournal = BurdJournals.isTraitEnabledForJournal(data, traitId)
        end
        if enabledForJournal then
        -- Use per-character claims if player provided, otherwise global
            local isClaimed = false
            if player then
                isClaimed = BurdJournals.hasCharacterClaimedTrait(data, player, traitId)
            else
                local claimed = BurdJournals.getClaimedTraits(item)
                isClaimed = claimed[traitId]
            end
            if not isClaimed then
                unclaimed[traitId] = traitData
            end
        end
    end

    return unclaimed
end

function BurdJournals.getUnclaimedTraitCount(item, player)
    local unclaimed = BurdJournals.getUnclaimedTraits(item, player)
    return BurdJournals.countTable(unclaimed)
end

-- Helper function to check if a table has any entries (avoids using next() which can fail on PZ server)
local function tableHasEntries(t)
    if type(t) ~= "table" then return false end
    for _ in pairs(t) do
        return true
    end
    return false
end

-- Helper function to count unclaimed entries for a specific player
-- Checks BOTH legacy claims (claimedSkills) AND per-character claims (claims[characterId].skills)
local function countUnclaimedEntriesForPlayer(dataTable, legacyClaimedTable, journalData, player, entryType)
    if type(dataTable) ~= "table" then return 0 end
    local count = 0

    -- Legacy migration fallback claims bucket.
    local legacyUnknownClaims = nil
    if journalData and type(journalData.claims) == "table" and type(journalData.claims["legacy_unknown"]) == "table" then
        legacyUnknownClaims = journalData.claims["legacy_unknown"][entryType]
    end
    
    for key, _ in pairs(dataTable) do
        local enabledForJournal = true
        if entryType == "skills" and BurdJournals.isSkillEnabledForJournal then
            enabledForJournal = BurdJournals.isSkillEnabledForJournal(journalData, key)
        elseif entryType == "traits" and BurdJournals.isTraitEnabledForJournal then
            enabledForJournal = BurdJournals.isTraitEnabledForJournal(journalData, key)
        end
        if enabledForJournal then
            local isClaimed = false
            if player then
                if entryType == "skills" and BurdJournals.hasCharacterClaimedSkill then
                    isClaimed = BurdJournals.hasCharacterClaimedSkill(journalData, player, key)
                elseif entryType == "traits" and BurdJournals.hasCharacterClaimedTrait then
                    isClaimed = BurdJournals.hasCharacterClaimedTrait(journalData, player, key)
                elseif entryType == "recipes" and BurdJournals.hasCharacterClaimedRecipe then
                    isClaimed = BurdJournals.hasCharacterClaimedRecipe(journalData, player, key)
                elseif entryType == "stats" and BurdJournals.hasCharacterClaimedStat then
                    isClaimed = BurdJournals.hasCharacterClaimedStat(journalData, player, key)
                end
            else
                -- No player context: retain legacy/global fallback behavior.
                local isClaimedLegacy = legacyClaimedTable and legacyClaimedTable[key]
                local isClaimedLegacyUnknown = legacyUnknownClaims and legacyUnknownClaims[key]
                isClaimed = isClaimedLegacy or isClaimedLegacyUnknown
            end

            if not isClaimed then
                count = count + 1
            end
        end
    end
    return count
end

function BurdJournals.shouldDissolve(item, player)
    -- Bail if item is nil
    if not item then
        print("[BurdJournals] shouldDissolve: item is nil")
        return false
    end

    local data = getItemJournalModData(item)
    if not data then
        print("[BurdJournals] shouldDissolve: No BurdJournals modData")
        return false
    end

    -- Get item type for worn/bloody detection
    local fullType = getItemFullType(item)
    local isWornFromType = fullType and string.find(fullType, "_Worn") ~= nil
    local isBloodyFromType = fullType and string.find(fullType, "_Bloody") ~= nil
    local isWorn = data.isWorn or isWornFromType
    local isBloody = data.isBloody or isBloodyFromType

    print("[BurdJournals] shouldDissolve: fullType=" .. tostring(fullType) .. ", isWorn=" .. tostring(isWorn) .. ", isBloody=" .. tostring(isBloody))

    -- Player-created journals: check sandbox option for "Restored" dissolution
    if data.isPlayerCreated then
        local isRestored = BurdJournals.isRestoredJournalData(data)
            or data.isWorn == true
            or data.isBloody == true

        print("[BurdJournals] shouldDissolve: Player-created, isRestored=" .. tostring(isRestored))

        if not isRestored then
            print("[BurdJournals] shouldDissolve: Clean player journal, never dissolves")
            return false  -- Clean player journals never dissolve
        end

        local allowDissolution = BurdJournals.getSandboxOption("AllowPlayerJournalDissolution")
        print("[BurdJournals] shouldDissolve: AllowPlayerJournalDissolution=" .. tostring(allowDissolution))
        if not allowDissolution then
            return false
        end
    else
        -- Looted journals: must be worn or bloody to dissolve
        if not isWorn and not isBloody then
            print("[BurdJournals] shouldDissolve: Looted journal but not worn/bloody, cannot dissolve")
            return false
        end
    end

    -- Check if journal has any content (using helper to avoid next())
    local hasSkills = false
    if type(data.skills) == "table" then
        for skillName, _ in pairs(data.skills) do
            local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(data, skillName)
            if enabledForJournal then
                hasSkills = true
                break
            end
        end
    end
    local hasTraits = tableHasEntries(data.traits)
    local hasRecipes = tableHasEntries(data.recipes)
    local hasStats = tableHasEntries(data.stats)
    local hasForgetSlot = data.forgetSlot == true
        and (not BurdJournals.isForgetSlotEnabledForJournal or BurdJournals.isForgetSlotEnabledForJournal(data))
    local forgetClaimed = hasForgetSlot
        and player
        and BurdJournals.hasCharacterClaimedForgetSlot
        and BurdJournals.hasCharacterClaimedForgetSlot(data, player)

    -- Check claims (both legacy and per-character)
    local wasSanitized = data.sanitizedVersion and data.sanitizedVersion > 0
    local hasLegacyClaims = tableHasEntries(data.claimedSkills)
        or tableHasEntries(data.claimedTraits)
        or tableHasEntries(data.claimedRecipes)
        or tableHasEntries(data.claimedStats)
        or tableHasEntries(data.claimedForgetSlot)
    local hasPerCharClaims = tableHasEntries(data.claims)
    local hasClaims = hasLegacyClaims or hasPerCharClaims

    print("[BurdJournals] shouldDissolve: hasSkills=" .. tostring(hasSkills) .. ", hasTraits=" .. tostring(hasTraits) .. ", hasRecipes=" .. tostring(hasRecipes)
        .. ", hasStats=" .. tostring(hasStats) .. ", hasForgetSlot=" .. tostring(hasForgetSlot) .. ", forgetClaimed=" .. tostring(forgetClaimed))

    -- Don't dissolve empty journals unless sanitized with claims
    if not hasSkills and not hasTraits and not hasRecipes and not hasStats and not hasForgetSlot then
        if wasSanitized and hasClaims then
            print("[BurdJournals] shouldDissolve: Empty but sanitized with claims, dissolving")
            return true
        end
        print("[BurdJournals] shouldDissolve: Empty journal, not dissolving")
        return false
    end

    -- Count unclaimed items - checks BOTH legacy AND per-character claims
    local unclaimedSkills = countUnclaimedEntriesForPlayer(data.skills, data.claimedSkills, data, player, "skills")
    local unclaimedTraits = countUnclaimedEntriesForPlayer(data.traits, data.claimedTraits, data, player, "traits")
    local unclaimedRecipes = countUnclaimedEntriesForPlayer(data.recipes, data.claimedRecipes, data, player, "recipes")
    local unclaimedStats = countUnclaimedEntriesForPlayer(data.stats, data.claimedStats, data, player, "stats")
    local unclaimedForgetSlot = (hasForgetSlot and not forgetClaimed) and 1 or 0

    print("[BurdJournals] shouldDissolve: unclaimedSkills=" .. tostring(unclaimedSkills)
        .. ", unclaimedTraits=" .. tostring(unclaimedTraits)
        .. ", unclaimedRecipes=" .. tostring(unclaimedRecipes)
        .. ", unclaimedStats=" .. tostring(unclaimedStats)
        .. ", unclaimedForgetSlot=" .. tostring(unclaimedForgetSlot))

    local shouldDis = unclaimedSkills == 0
        and unclaimedTraits == 0
        and unclaimedRecipes == 0
        and unclaimedStats == 0
        and unclaimedForgetSlot == 0
    print("[BurdJournals] shouldDissolve: RESULT=" .. tostring(shouldDis))
    return shouldDis
end

function BurdJournals.getRemainingRewards(item, player)
    local data = BurdJournals.getJournalData(item)
    local skills = BurdJournals.getUnclaimedSkillCount(item, player)
    local traits = BurdJournals.getUnclaimedTraitCount(item, player)
    local recipes = BurdJournals.getUnclaimedRecipeCount(item, player)
    local stats = countUnclaimedEntriesForPlayer(
        data and data.stats,
        data and data.claimedStats,
        data,
        player,
        "stats"
    )
    local forget = 0
    if data
        and data.forgetSlot == true
        and (not BurdJournals.isForgetSlotEnabledForJournal or BurdJournals.isForgetSlotEnabledForJournal(data))
        and player
        and BurdJournals.hasCharacterClaimedForgetSlot
        and not BurdJournals.hasCharacterClaimedForgetSlot(data, player) then
        forget = 1
    end
    return skills + traits + recipes + stats + forget
end

function BurdJournals.getTotalRewards(item)
    local skills = BurdJournals.getTotalSkillCount(item)
    local data = BurdJournals.getJournalData(item)
    local traits = data and data.traits and BurdJournals.countTable(data.traits) or 0
    local recipes = data and data.recipes and BurdJournals.countTable(data.recipes) or 0
    local stats = data and data.stats and BurdJournals.countTable(data.stats) or 0
    local forget = 0
    if data
        and data.forgetSlot == true
        and (not BurdJournals.isForgetSlotEnabledForJournal or BurdJournals.isForgetSlotEnabledForJournal(data)) then
        forget = 1
    end
    return skills + traits + recipes + stats + forget
end

function BurdJournals.updateJournalIcon(item)
    if not item then return end
    if not BurdJournals.isAnyJournal(item) then return end

    local fullType = getItemFullType(item)
    if not fullType then return end
    if fullType == BurdJournals.CURSED_ITEM_TYPE then
        if item.setTexture then
            local data = getItemJournalModData(item) or {}
            local useBloodyFallback = data.isCursedReward == true or data.cursedState == "unleashed"
            local texture = nil
            if useBloodyFallback then
                texture = getTexture("Item_FilledJournalBloody") or getTexture("Item_CursedJournal")
            else
                texture = getTexture("Item_CursedJournal") or getTexture("Item_FilledJournalBloody")
            end
            if texture then
                item:setTexture(texture)
            end
        end
        return
    end
    if fullType:find("_Worn") or fullType:find("_Bloody") then

        return
    end

    local isBlank = BurdJournals.isBlankJournal(item)
    local isWornState = BurdJournals.isWorn(item)
    local isBloodyState = BurdJournals.isBloody(item)

    local iconPrefix = isBlank and "BlankJournal" or "FilledJournal"
    local iconSuffix

    if isBloodyState then
        iconSuffix = "Bloody"
    elseif isWornState then
        iconSuffix = "Worn"
    else
        iconSuffix = "Clean"
    end

    local iconName = iconPrefix .. iconSuffix

    if item.setTexture then
        local texture = getTexture("Item_" .. iconName)
        if texture then
            item:setTexture(texture)
        end
    end
end

function BurdJournals.getJournalStateString(item)
    if not item then return "Unknown" end

    if BurdJournals.isCursedJournalItem(item) then
        return "Cursed"
    end
    if BurdJournals.isBloody(item) then
        return "Bloody"
    elseif BurdJournals.isWorn(item) then
        return "Worn"
    else
        return "Clean"
    end
end

function BurdJournals.getJournalData(item)
    if not item then return nil end
    return getItemJournalModData(item)
end

function BurdJournals.safeGetText(key, fallback)
    if not key then return fallback end
    local result = getText(key)

    if result == key then
        return fallback
    end
    return result or fallback
end

-- Helper function to resolve profession name from stored data
-- Handles cases where server stored translation key instead of translated text
function BurdJournals.resolveProfessionName(data)
    if not data then return nil end
    
    local professionName = data.professionName
    local professionId = data.profession
    
    -- First, check if professionName looks like a translation key (UI_...)
    if professionName and string.find(professionName, "^UI_") then
        -- It's a translation key - try to translate it (only works on client)
        local translated = getText(professionName)
        if translated and translated ~= professionName then
            return translated
        end
        -- If getText didn't translate (server side), try lookup by ID
    end
    
    -- If we have a valid non-key professionName, use it
    if professionName and not string.find(professionName, "^UI_") then
        return professionName
    end
    
    -- Try to look up by profession ID in PROFESSIONS table
    if professionId and BurdJournals.PROFESSIONS then
        for _, prof in ipairs(BurdJournals.PROFESSIONS) do
            if prof.id == professionId then
                -- Try to translate, fall back to plain name
                if prof.nameKey then
                    local translated = getText(prof.nameKey)
                    if translated and translated ~= prof.nameKey then
                        return translated
                    end
                end
                return prof.name  -- Fallback to plain English name
            end
        end
    end
    
    -- Last resort: return the professionName as-is or nil
    return professionName
end

-- Helper function to resolve flavor text from flavorKey
function BurdJournals.resolveFlavorText(data)
    if not data or not data.flavorKey then return nil end
    
    local flavorKey = data.flavorKey
    
    -- flavorKey is always a translation key - try to translate it
    local translated = getText(flavorKey)
    if translated and translated ~= flavorKey then
        return translated
    end
    
    return nil  -- Could not translate
end

function BurdJournals.computeLocalizedName(item)
    if not item then return nil end

    local data = getItemJournalModData(item) or {}
    local fullType = getItemFullType(item)
    local isUnleashedCursedReward = fullType == BurdJournals.CURSED_ITEM_TYPE
        and (data.isCursedReward == true or data.cursedState == "unleashed")
    local isCursedItem = BurdJournals.isCursedJournalItem and BurdJournals.isCursedJournalItem(item)
    if isCursedItem then
        return BurdJournals.safeGetText("UI_BurdJournals_CursedJournal", "Cursed Survival Journal")
    end

    local isWornState = data.isWorn
    local isBloodyState = data.isBloody
    local author = data.author
    local professionName = BurdJournals.resolveProfessionName(data)  -- Use resolver
    local isPlayerCreated = data.isPlayerCreated

    local stateSuffix = ""
    if isBloodyState then
        stateSuffix = BurdJournals.safeGetText("UI_BurdJournals_StateBloody", "Bloody")
    elseif isWornState then
        stateSuffix = BurdJournals.safeGetText("UI_BurdJournals_StateWorn", "Worn")
    end

    local baseName
    if BurdJournals.isBlankJournal(item) then
        baseName = BurdJournals.safeGetText("UI_BurdJournals_BlankJournal", "Blank Survival Journal")
        if stateSuffix ~= "" then
            baseName = baseName .. " (" .. stateSuffix .. ")"
        end
    elseif BurdJournals.isFilledJournal(item) or isUnleashedCursedReward then
        baseName = BurdJournals.safeGetText("UI_BurdJournals_FilledJournal", "Filled Survival Journal")
        local suffixParts = {}

        if stateSuffix ~= "" then
            table.insert(suffixParts, stateSuffix)
        end

        if isPlayerCreated and author then

            table.insert(suffixParts, author)
        elseif not isPlayerCreated and professionName then

            if string.find(professionName, "^Former") or string.find(professionName, "^Previous") then
                table.insert(suffixParts, professionName)
            else
                local prevFormat = BurdJournals.safeGetText("UI_BurdJournals_PreviousProfession", "Previous %s")
                table.insert(suffixParts, string.format(prevFormat, professionName))
            end
        elseif author then

            table.insert(suffixParts, author)
        end

        if #suffixParts > 0 then
            baseName = baseName .. " (" .. table.concat(suffixParts, " - ") .. ")"
        end
    end

    return baseName
end

BurdJournals._localizedItems = BurdJournals._localizedItems or {}

function BurdJournals.clearLocalizedItemsCache()
    BurdJournals._localizedItems = {}
end

function BurdJournals.updateJournalName(item, forceUpdate)
    if not item then return end

    local modData = getItemModData(item)
    if not modData then return end
    local data = modData.BurdJournals or {}

    if data.customName then
        if item:getName() ~= data.customName then
            item:setName(data.customName)
            -- Mark as custom name so PZ preserves it during item serialization (MP transfers)
            if item.setCustomName then
                item:setCustomName(true)
            end
        end
        return
    end

    local itemId = item:getID()
    if not forceUpdate and BurdJournals._localizedItems[itemId] then

        return
    end

    local currentName = item:getName()
    local needsLocalization = not currentName
        or currentName == ""
        or currentName:find("UI_BurdJournals_")
        or currentName:find("^Item_")
        or currentName:find("^BurdJournals%.")
        or currentName:find("BlankSurvivalJournal")
        or currentName:find("FilledSurvivalJournal")

    local isNonPlayerJournal = not data.isPlayerCreated and (data.isWorn or data.isBloody or data.wasFromBloody)
    if isNonPlayerJournal then
        needsLocalization = true
    end

    if not needsLocalization and not forceUpdate then
        BurdJournals._localizedItems[itemId] = true
        return
    end

    local baseName = BurdJournals.computeLocalizedName(item)

    if baseName and item.setName then
        item:setName(baseName)

        BurdJournals._localizedItems[itemId] = true
    end
end

function BurdJournals.getAuthorFromJournal(item)
    local data = BurdJournals.getJournalData(item)
    if data and data.author then
        return data.author
    end
    return "Unknown"
end

function BurdJournals.countTable(tbl)
    if not tbl then return 0 end
    local normalized = BurdJournals.normalizeTable(tbl)
    if not normalized then return 0 end

    local count = 0
    for _ in pairs(normalized) do
        count = count + 1
    end
    return count
end

function BurdJournals.tableContains(tbl, value)
    for _, v in pairs(tbl) do
        if v == value then return true end
    end
    return false
end

function BurdJournals.formatXP(xp)
    if xp >= 1000 then
        return string.format("%.1fk", xp / 1000)
    end
    return tostring(math.floor(xp))
end

-- Get skill book multiplier for a player's skill (capped by sandbox setting)
-- Only applies to Worn/Bloody journal absorption, not Player Journal claims
-- Returns: cappedMultiplier, hasBookBoost (boolean)
function BurdJournals.getSkillBookMultiplier(player, skillName)
    -- Check if feature is enabled
    local featureEnabled = BurdJournals.getSandboxOption("SkillBookMultiplierForJournals")
    if not featureEnabled then
        return 1.0, false
    end
    
    if not player then 
        return 1.0, false 
    end
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then 
        return 1.0, false 
    end
    
    local xpObj = player:getXp()
    if not xpObj or not xpObj.getMultiplier then 
        return 1.0, false 
    end
    
    local rawMultiplier = tonumber(xpObj:getMultiplier(perk)) or 1.0
    if rawMultiplier <= 1.0 then 
        return 1.0, false 
    end
    
    -- Apply sandbox cap (default 2.0)
    local cap = tonumber(BurdJournals.getSandboxOption("SkillBookMultiplierCap")) or 2.0
    if cap < 1.0 then cap = 1.0 end
    local cappedMultiplier = math.max(1.0, math.min(rawMultiplier, cap))
    
    return cappedMultiplier, cappedMultiplier > 1.0
end

-- Calculate effective XP with capped skill book multiplier
-- Returns: effectiveXP, hasBookBoost (boolean)
function BurdJournals.getEffectiveXP(player, skillName, baseXP)
    local multiplier, hasBoost = BurdJournals.getSkillBookMultiplier(player, skillName)
    return baseXP * multiplier, hasBoost
end

function BurdJournals.getXPRecoveryMode()
    return tonumber(BurdJournals.getSandboxOption("XPRecoveryMode")) or 1
end

function BurdJournals.getDiminishingTrackingMode()
    local mode = tonumber(BurdJournals.getSandboxOption("DiminishingTrackingMode")) or 3
    if mode < 1 or mode > 3 then
        mode = 3
    end
    return mode
end

function BurdJournals.getDiminishingConfig()
    local firstRead = (tonumber(BurdJournals.getSandboxOption("DiminishingFirstRead")) or 100) / 100
    local decayRate = (tonumber(BurdJournals.getSandboxOption("DiminishingDecayRate")) or 10) / 100
    local minimum = (tonumber(BurdJournals.getSandboxOption("DiminishingMinimum")) or 10) / 100

    firstRead = math.max(0, math.min(1, firstRead))
    decayRate = math.max(0, decayRate)
    minimum = math.max(0, math.min(1, minimum))
    if minimum > firstRead then
        minimum = firstRead
    end

    return firstRead, decayRate, minimum
end

function BurdJournals.getDiminishingMultiplierForReadCount(readCount)
    if BurdJournals.getXPRecoveryMode() ~= 2 then
        return 1.0
    end

    local normalizedReadCount = math.max(0, tonumber(readCount) or 0)
    local firstRead, decayRate, minimum = BurdJournals.getDiminishingConfig()

    local multiplier
    if normalizedReadCount == 0 then
        multiplier = firstRead
    else
        multiplier = firstRead - (decayRate * normalizedReadCount)
    end

    return math.max(minimum, multiplier)
end

local function sanitizeClaimSessionId(claimSessionId)
    if type(claimSessionId) ~= "string" or claimSessionId == "" then
        return nil
    end
    return claimSessionId
end

local function addSkillKeyCandidate(candidates, seen, key)
    if type(key) ~= "string" or key == "" then
        return
    end
    local lowered = string.lower(key)
    if seen[lowered] then
        return
    end
    seen[lowered] = true
    candidates[#candidates + 1] = key
end

local function getCanonicalSkillReadKey(skillName)
    if type(skillName) ~= "string" or skillName == "" then
        return nil
    end

    local map = BurdJournals.SKILL_TO_PERK
    if map then
        local direct = map[skillName]
        if type(direct) == "string" and direct ~= "" then
            return direct
        end

        local skillLower = string.lower(skillName)
        for alias, perkId in pairs(map) do
            if type(alias) == "string" and type(perkId) == "string" and string.lower(alias) == skillLower then
                return perkId
            end
        end
    end

    return skillName
end

local function resolveSkillReadCounterKey(skillReadCounts, skillName)
    if type(skillReadCounts) ~= "table" or type(skillName) ~= "string" or skillName == "" then
        return nil, skillName
    end

    local candidates, seen = {}, {}
    local canonicalKey = getCanonicalSkillReadKey(skillName) or skillName

    addSkillKeyCandidate(candidates, seen, skillName)
    addSkillKeyCandidate(candidates, seen, canonicalKey)

    if BurdJournals.mapPerkIdToSkillName then
        local mappedSkill = BurdJournals.mapPerkIdToSkillName(skillName)
        addSkillKeyCandidate(candidates, seen, mappedSkill)
        addSkillKeyCandidate(candidates, seen, getCanonicalSkillReadKey(mappedSkill))
    end

    if BurdJournals.resolveSkillKey then
        local resolvedLegacy = BurdJournals.resolveSkillKey(skillReadCounts, skillName)
        addSkillKeyCandidate(candidates, seen, resolvedLegacy)
        addSkillKeyCandidate(candidates, seen, getCanonicalSkillReadKey(resolvedLegacy))
    end

    for _, candidate in ipairs(candidates) do
        if skillReadCounts[candidate] ~= nil then
            return candidate, canonicalKey
        end
    end

    for existingKey, _ in pairs(skillReadCounts) do
        local existingLower = string.lower(tostring(existingKey))
        for _, candidate in ipairs(candidates) do
            if existingLower == string.lower(candidate) then
                return existingKey, canonicalKey
            end
        end
    end

    return nil, canonicalKey
end

local function mirrorLegacySkillReadCountAliases(skillReadCounts, skillName, nextCount, preferredKey)
    if type(skillReadCounts) ~= "table" or type(skillName) ~= "string" or skillName == "" then
        return
    end
    local skillLower = string.lower(skillName)
    for existingKey, _ in pairs(skillReadCounts) do
        if existingKey ~= preferredKey and string.lower(tostring(existingKey)) == skillLower then
            skillReadCounts[existingKey] = nextCount
        end
    end
end

local function readSkillReadCountField(container, key)
    if not container or type(key) ~= "string" or key == "" then
        return nil
    end
    local ok, value = safePcall(function()
        return container[key]
    end)
    if ok then
        return value
    end
    return nil
end

local function writeSkillReadCountField(container, key, value)
    if not container or type(key) ~= "string" or key == "" then
        return false
    end
    local ok = safePcall(function()
        container[key] = value
    end)
    return ok == true
end

local function getDRCharacterSkillReadCounts(journalData, player, createIfMissing)
    if not journalData or not player then
        return nil
    end

    local charClaims = BurdJournals.getCharacterClaims(journalData, player, createIfMissing ~= false)
    if type(charClaims) ~= "table" then
        return nil
    end

    local drSkillReadCounts = charClaims.drSkillReadCounts
    if type(drSkillReadCounts) ~= "table" and BurdJournals.normalizeTable then
        drSkillReadCounts = BurdJournals.normalizeTable(drSkillReadCounts)
    end
    if type(drSkillReadCounts) ~= "table" then
        if not createIfMissing then
            return nil
        end
        drSkillReadCounts = {}
    end
    charClaims.drSkillReadCounts = drSkillReadCounts
    return drSkillReadCounts
end

local function mirrorDRSkillReadCountToCharacterClaims(journalData, player, skillName, nextCount)
    if not journalData or not player or type(skillName) ~= "string" or skillName == "" then
        return
    end
    local drSkillReadCounts = getDRCharacterSkillReadCounts(journalData, player, true)
    if type(drSkillReadCounts) ~= "table" then
        return
    end

    local resolvedKey, canonicalKey = resolveSkillReadCounterKey(drSkillReadCounts, skillName)
    local targetKey = canonicalKey or resolvedKey or skillName
    local count = math.max(0, tonumber(nextCount) or 0)
    local existing = math.max(0, tonumber(drSkillReadCounts[targetKey]) or 0)
    if count < existing then
        count = existing
    end
    drSkillReadCounts[targetKey] = count
    if resolvedKey and resolvedKey ~= targetKey then
        drSkillReadCounts[resolvedKey] = count
    end
end

local function getSkillReadCount(journalData, skillName, player)
    if not journalData or type(skillName) ~= "string" or skillName == "" then
        return 0
    end
    local runtimeEntry, runtimeShardKey = nil, nil
    if BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
        and BurdJournals.getOrCreateJournalRuntimeEntryForData then
        runtimeEntry, runtimeShardKey = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, false)
    end

    local skillReadCounts = runtimeEntry and runtimeEntry.skillReadCounts or journalData.skillReadCounts
    if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
        skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
        if type(skillReadCounts) == "table" then
            if runtimeEntry then
                runtimeEntry.skillReadCounts = skillReadCounts
                if BurdJournals.runtimeTouchJournalEntry then
                    BurdJournals.runtimeTouchJournalEntry(runtimeEntry, runtimeShardKey, "getSkillReadCountNormalize")
                end
            else
                journalData.skillReadCounts = skillReadCounts
            end
        end
    end
    if type(skillReadCounts) ~= "table" then
        local candidates, seen = {}, {}
        local canonicalKey = getCanonicalSkillReadKey(skillName) or skillName
        addSkillKeyCandidate(candidates, seen, skillName)
        addSkillKeyCandidate(candidates, seen, canonicalKey)
        if BurdJournals.mapPerkIdToSkillName then
            local mappedSkill = BurdJournals.mapPerkIdToSkillName(skillName)
            addSkillKeyCandidate(candidates, seen, mappedSkill)
            addSkillKeyCandidate(candidates, seen, getCanonicalSkillReadKey(mappedSkill))
        end
        if BurdJournals.SKILL_TO_PERK then
            local perkId = BurdJournals.SKILL_TO_PERK[skillName]
            addSkillKeyCandidate(candidates, seen, perkId)
        end

        local claimCount = 0
        for _, candidate in ipairs(candidates) do
            local candidateCount = math.max(0, tonumber(readSkillReadCountField(skillReadCounts, candidate)) or 0)
            if candidateCount > claimCount then
                claimCount = candidateCount
            end
        end
        if claimCount > 0 then
            BurdJournals.debugPrint("[BurdJournals] DR: Recovered non-table skillReadCounts for " .. tostring(skillName) .. " = " .. tostring(claimCount))
            writeSkillReadCountField(skillReadCounts, canonicalKey, claimCount)
            mirrorDRSkillReadCountToCharacterClaims(journalData, player, canonicalKey, claimCount)
            return claimCount
        end

        local claimSkillReadCounts = getDRCharacterSkillReadCounts(journalData, player, false)
        if type(claimSkillReadCounts) ~= "table" then
            return 0
        end
        local resolvedKey, canonicalKey = resolveSkillReadCounterKey(claimSkillReadCounts, skillName)
        local activeKey = resolvedKey or canonicalKey or skillName
        local claimCount = math.max(0, tonumber(claimSkillReadCounts[activeKey]) or 0)
        if claimCount > 0 then
            local restored = {}
            restored[canonicalKey or activeKey] = claimCount
            if runtimeEntry then
                runtimeEntry.skillReadCounts = restored
                if BurdJournals.runtimeTouchJournalEntry then
                    BurdJournals.runtimeTouchJournalEntry(runtimeEntry, runtimeShardKey, "getSkillReadCountRestore")
                end
            else
                journalData.skillReadCounts = restored
            end
        end
        return claimCount
    end

    local resolvedKey, canonicalKey = resolveSkillReadCounterKey(skillReadCounts, skillName)
    local activeKey = resolvedKey or canonicalKey or skillName
    local count = math.max(0, tonumber(skillReadCounts[activeKey]) or 0)

    -- Migrate legacy key variants to canonical key so counters survive key/mapping changes between patches.
    if canonicalKey and canonicalKey ~= activeKey then
        local canonicalCount = math.max(0, tonumber(skillReadCounts[canonicalKey]) or 0)
        local merged = math.max(count, canonicalCount)
        skillReadCounts[canonicalKey] = merged
        count = merged
    end

    if count > 0 then
        mirrorDRSkillReadCountToCharacterClaims(journalData, player, canonicalKey or activeKey, count)
    end

    return count
end

-- Returns: multiplier, readCountUsed
function BurdJournals.getJournalClaimMultiplier(journalData, readOffset, skillName, claimSessionId, player)
    local readCount = 0
    local offset = tonumber(readOffset) or 0
    local trackingMode = BurdJournals.getDiminishingTrackingMode()
    local runtimeEntry = nil
    if BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
        and BurdJournals.getOrCreateJournalRuntimeEntryForData then
        runtimeEntry = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, false)
    end

    if trackingMode == 2 then
        local baseSessionCount = tonumber(runtimeEntry and runtimeEntry.readSessionCount) or tonumber(journalData and journalData.readSessionCount) or 0
        local normalizedSessionId = sanitizeClaimSessionId(claimSessionId)
        local currentSessionId = sanitizeClaimSessionId((runtimeEntry and runtimeEntry.currentSessionId) or (journalData and journalData.currentSessionId))
        if normalizedSessionId and currentSessionId and normalizedSessionId == currentSessionId then
            -- This read belongs to the session already counted in readSessionCount.
            readCount = math.max(0, baseSessionCount - 1)
        else
            readCount = baseSessionCount
        end
    elseif trackingMode == 3 then
        readCount = getSkillReadCount(journalData, skillName, player)
    else
        readCount = math.max(0, tonumber(runtimeEntry and runtimeEntry.readCount) or tonumber(journalData and journalData.readCount) or 0)
    end

    readCount = math.max(0, readCount + offset)
    local multiplier = BurdJournals.getDiminishingMultiplierForReadCount(readCount)
    return multiplier, readCount
end

-- Applies diminishing-returns read consumption to this journal and returns:
-- multiplier used for this read, readCount prior to increment
function BurdJournals.consumeJournalClaimRead(journalData, skillName, claimSessionId, player)
    local multiplier, readCount = BurdJournals.getJournalClaimMultiplier(journalData, 0, skillName, claimSessionId, player)
    local runtimeEntry, runtimeShardKey = nil, nil
    if BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()
        and BurdJournals.getOrCreateJournalRuntimeEntryForData then
        runtimeEntry, runtimeShardKey = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, true)
    end
    local targetData = runtimeEntry or journalData
    if journalData and BurdJournals.getXPRecoveryMode() == 2 then
        local trackingMode = BurdJournals.getDiminishingTrackingMode()
        if trackingMode == 2 then
            local normalizedSessionId = sanitizeClaimSessionId(claimSessionId)
            local currentSessionId = sanitizeClaimSessionId(targetData.currentSessionId)
            if normalizedSessionId and currentSessionId and normalizedSessionId == currentSessionId then
                targetData.currentSessionReadCount = math.max(1, tonumber(targetData.currentSessionReadCount) or 1)
            elseif normalizedSessionId then
                targetData.readSessionCount = math.max(0, tonumber(targetData.readSessionCount) or 0) + 1
                targetData.currentSessionId = normalizedSessionId
                targetData.currentSessionReadCount = 1
            else
                -- Fallback: treat as one-shot session if no session token is supplied
                targetData.readSessionCount = math.max(0, tonumber(targetData.readSessionCount) or 0) + 1
                targetData.currentSessionId = nil
                targetData.currentSessionReadCount = 0
            end
        elseif trackingMode == 3 then
            if type(skillName) == "string" and skillName ~= "" then
                local skillReadCounts = targetData.skillReadCounts
                if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
                    skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
                end
                if not skillReadCounts then
                    skillReadCounts = {}
                end
                if type(skillReadCounts) ~= "table" and type(skillReadCounts) ~= "userdata" then
                    skillReadCounts = {}
                end
                targetData.skillReadCounts = skillReadCounts

                if type(skillReadCounts) == "table" then
                    local resolvedKey, canonicalKey = resolveSkillReadCounterKey(skillReadCounts, skillName)
                    local targetKey = canonicalKey or resolvedKey or skillName
                    local currentSkillCount = math.max(0, tonumber(skillReadCounts[targetKey]) or 0)
                    if resolvedKey and resolvedKey ~= targetKey then
                        currentSkillCount = math.max(currentSkillCount, math.max(0, tonumber(skillReadCounts[resolvedKey]) or 0))
                    end
                    local nextCount = currentSkillCount + 1
                    skillReadCounts[targetKey] = nextCount
                    mirrorLegacySkillReadCountAliases(skillReadCounts, skillName, nextCount, targetKey)
                    -- Mirror the legacy key when present so pre-patch readers still see accurate counters.
                    if resolvedKey and resolvedKey ~= targetKey then
                        skillReadCounts[resolvedKey] = nextCount
                    end
                    mirrorDRSkillReadCountToCharacterClaims(journalData, player, targetKey, nextCount)
                else
                    local canonicalKey = getCanonicalSkillReadKey(skillName) or skillName
                    local currentSkillCount = math.max(0, tonumber(readSkillReadCountField(skillReadCounts, canonicalKey)) or 0)
                    local directSkillCount = math.max(0, tonumber(readSkillReadCountField(skillReadCounts, skillName)) or 0)
                    local nextCount = math.max(currentSkillCount, directSkillCount) + 1
                    BurdJournals.debugPrint("[BurdJournals] DR: Incrementing non-table skillReadCounts for " .. tostring(skillName) .. " to " .. tostring(nextCount))
                    writeSkillReadCountField(skillReadCounts, canonicalKey, nextCount)
                    if canonicalKey ~= skillName then
                        writeSkillReadCountField(skillReadCounts, skillName, nextCount)
                    end
                    mirrorDRSkillReadCountToCharacterClaims(journalData, player, canonicalKey, nextCount)
                end
            else
                targetData.readCount = readCount + 1
            end
        else
            targetData.readCount = readCount + 1
        end
        if runtimeEntry and BurdJournals.runtimeTouchJournalEntry then
            BurdJournals.runtimeTouchJournalEntry(runtimeEntry, runtimeShardKey, "consumeJournalClaimRead")
        end
    end
    return multiplier, readCount
end

local function hasPositiveDRSkillReadCounts(skillReadCounts)
    local counts = skillReadCounts
    if type(counts) ~= "table" and BurdJournals.normalizeTable then
        counts = BurdJournals.normalizeTable(counts)
    end
    if type(counts) ~= "table" then
        return false
    end
    for _, value in pairs(counts) do
        if (tonumber(value) or 0) > 0 then
            return true
        end
    end
    return false
end

local function copyDRSkillReadCounts(skillReadCounts)
    local counts = skillReadCounts
    if type(counts) ~= "table" and BurdJournals.normalizeTable then
        counts = BurdJournals.normalizeTable(counts)
    end
    local copied = {}
    if type(counts) == "table" then
        for skillName, count in pairs(counts) do
            if skillName ~= nil then
                copied[tostring(skillName)] = math.max(0, tonumber(count) or 0)
            end
        end
    end
    return copied
end

local function drReadField(tbl, key)
    if not tbl then
        return nil
    end
    local ok, value = safePcall(function()
        return tbl[key]
    end)
    if ok then
        return value
    end
    return nil
end

local function drWriteField(tbl, key, value)
    if not tbl then
        return false
    end
    local ok = safePcall(function()
        tbl[key] = value
    end)
    return ok == true
end

function BurdJournals.hasJournalDRData(journalData)
    if not journalData then
        return false
    end
    if (tonumber(drReadField(journalData, "readCount")) or 0) > 0 then return true end
    if (tonumber(drReadField(journalData, "readSessionCount")) or 0) > 0 then return true end
    if (tonumber(drReadField(journalData, "currentSessionReadCount")) or 0) > 0 then return true end
    return hasPositiveDRSkillReadCounts(drReadField(journalData, "skillReadCounts"))
end

local function ensureDRCacheMap(cache, key)
    if not cache then
        return nil
    end

    local map = cache[key]
    if type(map) ~= "table" and BurdJournals.normalizeTable then
        map = BurdJournals.normalizeTable(map)
    end
    if type(map) ~= "table" then
        map = {}
    end
    cache[key] = map
    return map
end

BurdJournals.DR_PLAYER_CACHE_MAX_JOURNALS = 24
BurdJournals.DR_PLAYER_CACHE_MAX_ALIASES = 96
BurdJournals.PLAYER_BASELINE_MAX_SKILLS = 128
BurdJournals.PLAYER_BASELINE_MAX_TRAITS = 512
BurdJournals.PLAYER_BASELINE_MAX_RECIPES = 2048
BurdJournals.BASELINE_SNAPSHOT_MAX_HOURS = 1
BurdJournals.RUNTIME_SHARD_COUNT = 16
BurdJournals.RUNTIME_MAX_CHARACTERS_PER_JOURNAL = 128
BurdJournals.RUNTIME_MAX_CLAIMS_PER_BUCKET = 1024
BurdJournals.RUNTIME_MAX_SKILL_READ_KEYS = 256
BurdJournals.RUNTIME_MAX_SESSION_ID_LEN = 64
BurdJournals.RUNTIME_TRANSMIT_DEBOUNCE_MS = 500
BurdJournals.FULL_SYNC_SOFT_LIMIT_BYTES = 48000
BurdJournals.RUNTIME_MODDATA_PREFIX = "BurdJournals_JournalRuntime_"
BurdJournals.RUNTIME_SCHEMA_VERSION = 1

local function getRuntimeNowMs()
    if getTimestampMs then
        local ts = tonumber(getTimestampMs())
        if ts and ts > 0 then
            return ts
        end
    end
    return (os.time() or 0) * 1000
end

function BurdJournals.isStrictMPContext()
    local client = isClient and isClient() or false
    local server = isServer and isServer() or false
    return (client and not server) or (server and not client)
end

function BurdJournals.isStrictMPServerContext()
    local client = isClient and isClient() or false
    local server = isServer and isServer() or false
    return server and not client
end

local function countTableEntriesSafe(tbl)
    if type(tbl) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function collectSortedStringKeys(tbl)
    local keys = {}
    if type(tbl) ~= "table" then
        return keys
    end
    for key in pairs(tbl) do
        if type(key) == "string" and key ~= "" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

local function sanitizeRuntimeSessionId(value)
    if value == nil then
        return nil
    end
    local s = tostring(value)
    if s == "" then
        return nil
    end
    local maxLen = math.max(8, tonumber(BurdJournals.RUNTIME_MAX_SESSION_ID_LEN) or 64)
    if string.len(s) > maxLen then
        s = string.sub(s, 1, maxLen)
    end
    return s
end

local function ensureRuntimeBooleanMap(source, limit)
    local cleaned = {}
    local removed = 0
    local maxEntries = math.max(1, tonumber(limit) or 1024)
    local keys = collectSortedStringKeys(source)
    local kept = 0
    for _, key in ipairs(keys) do
        if source[key] == true then
            if kept < maxEntries then
                cleaned[key] = true
                kept = kept + 1
            else
                removed = removed + 1
            end
        else
            removed = removed + 1
        end
    end
    return cleaned, removed
end

local function ensureRuntimeNumericMap(source, limit)
    local cleaned = {}
    local removed = 0
    local maxEntries = math.max(1, tonumber(limit) or 1024)
    local keys = collectSortedStringKeys(source)
    local kept = 0
    for _, key in ipairs(keys) do
        local value = math.max(0, tonumber(source[key]) or -1)
        if value >= 0 then
            if kept < maxEntries then
                cleaned[key] = value
                kept = kept + 1
            else
                removed = removed + 1
            end
        else
            removed = removed + 1
        end
    end
    return cleaned, removed
end

local function computeRuntimeShardIndex(uuid)
    local s = tostring(uuid or "")
    if s == "" then
        return 0
    end
    local hash = 0
    for i = 1, string.len(s) do
        hash = (hash * 131 + string.byte(s, i)) % 2147483647
    end
    local shardCount = math.max(1, tonumber(BurdJournals.RUNTIME_SHARD_COUNT) or 16)
    return hash % shardCount
end

function BurdJournals.getJournalRuntimeShardKeyForUUID(uuid)
    local idx = computeRuntimeShardIndex(uuid)
    return string.format("%s%02X", BurdJournals.RUNTIME_MODDATA_PREFIX, idx)
end

local function getOrCreateRuntimeShard(shardKey)
    if not shardKey or not ModData or not ModData.getOrCreate then
        return nil
    end
    local shard = ModData.getOrCreate(shardKey)
    if type(shard) ~= "table" then
        return nil
    end
    if type(shard.journals) ~= "table" then
        shard.journals = {}
    end
    shard.version = tonumber(shard.version) or BurdJournals.RUNTIME_SCHEMA_VERSION
    return shard
end

function BurdJournals.ensureRuntimeCharacterClaimsShape(charClaims)
    if type(charClaims) ~= "table" then
        charClaims = {}
    end
    if type(charClaims.skills) ~= "table" then charClaims.skills = {} end
    if type(charClaims.traits) ~= "table" then charClaims.traits = {} end
    if type(charClaims.recipes) ~= "table" then charClaims.recipes = {} end
    if type(charClaims.forgetSlots) ~= "table" then charClaims.forgetSlots = {} end
    if type(charClaims.stats) ~= "table" then charClaims.stats = {} end
    if type(charClaims.drSkillReadCounts) ~= "table" then charClaims.drSkillReadCounts = {} end

    local maxBucket = math.max(1, tonumber(BurdJournals.RUNTIME_MAX_CLAIMS_PER_BUCKET) or 1024)
    local cleanedSkills, removedSkills = ensureRuntimeBooleanMap(charClaims.skills, maxBucket)
    local cleanedTraits, removedTraits = ensureRuntimeBooleanMap(charClaims.traits, maxBucket)
    local cleanedRecipes, removedRecipes = ensureRuntimeBooleanMap(charClaims.recipes, maxBucket)
    local cleanedStats, removedStats = ensureRuntimeBooleanMap(charClaims.stats, maxBucket)
    local cleanedDR, removedDR = ensureRuntimeNumericMap(charClaims.drSkillReadCounts, maxBucket)
    charClaims.skills = cleanedSkills
    charClaims.traits = cleanedTraits
    charClaims.recipes = cleanedRecipes
    charClaims.stats = cleanedStats
    charClaims.drSkillReadCounts = cleanedDR

    local totalRemoved = (removedSkills or 0) + (removedTraits or 0) + (removedRecipes or 0) + (removedStats or 0) + (removedDR or 0)
    if totalRemoved > 0 then
        BurdJournals.debugPrint("[BurdJournals] Runtime character claim caps pruned entries: "
            .. tostring(totalRemoved) .. " (skills=" .. tostring(removedSkills or 0)
            .. ", traits=" .. tostring(removedTraits or 0)
            .. ", recipes=" .. tostring(removedRecipes or 0)
            .. ", stats=" .. tostring(removedStats or 0)
            .. ", dr=" .. tostring(removedDR or 0) .. ")")
    end

    local defaultForget = charClaims.forgetSlots.default
    if defaultForget ~= nil and defaultForget ~= true and type(defaultForget) ~= "string" then
        charClaims.forgetSlots.default = tostring(defaultForget)
    end
    return charClaims
end

function BurdJournals.enforceJournalRuntimeEntryCaps(runtimeEntry)
    if type(runtimeEntry) ~= "table" then
        return false
    end

    local changed = false
    runtimeEntry.claims = type(runtimeEntry.claims) == "table" and runtimeEntry.claims or {}
    runtimeEntry.readCount = math.max(0, tonumber(runtimeEntry.readCount) or 0)
    runtimeEntry.readSessionCount = math.max(0, tonumber(runtimeEntry.readSessionCount) or 0)
    runtimeEntry.currentSessionReadCount = math.max(0, tonumber(runtimeEntry.currentSessionReadCount) or 0)
    runtimeEntry.currentSessionId = sanitizeRuntimeSessionId(runtimeEntry.currentSessionId)
    runtimeEntry.drLegacyMode3Migrated = runtimeEntry.drLegacyMode3Migrated == true

    local maxChars = math.max(1, tonumber(BurdJournals.RUNTIME_MAX_CHARACTERS_PER_JOURNAL) or 128)
    local claimKeys = collectSortedStringKeys(runtimeEntry.claims)
    local removedCharacters = 0
    if #claimKeys > maxChars then
        for i = maxChars + 1, #claimKeys do
            runtimeEntry.claims[claimKeys[i]] = nil
            changed = true
            removedCharacters = removedCharacters + 1
        end
    end
    if removedCharacters > 0 then
        BurdJournals.debugPrint("[BurdJournals] Runtime cap pruned character buckets: " .. tostring(removedCharacters))
    end

    for _, characterId in ipairs(claimKeys) do
        local existing = runtimeEntry.claims[characterId]
        local shaped = BurdJournals.ensureRuntimeCharacterClaimsShape(existing)
        if shaped ~= existing then
            runtimeEntry.claims[characterId] = shaped
            changed = true
        end
    end

    local cleanedSkillReads, removedSkillReadEntries = ensureRuntimeNumericMap(
        runtimeEntry.skillReadCounts,
        math.max(1, tonumber(BurdJournals.RUNTIME_MAX_SKILL_READ_KEYS) or 256)
    )
    if removedSkillReadEntries > 0 or runtimeEntry.skillReadCounts ~= cleanedSkillReads then
        runtimeEntry.skillReadCounts = cleanedSkillReads
        changed = true
        if removedSkillReadEntries > 0 then
            BurdJournals.debugPrint("[BurdJournals] Runtime cap pruned skillReadCounts keys: " .. tostring(removedSkillReadEntries))
        end
    end

    return changed
end

BurdJournals._runtimeShardLastTransmitAt = BurdJournals._runtimeShardLastTransmitAt or {}
BurdJournals._runtimeShardPendingTransmit = BurdJournals._runtimeShardPendingTransmit or {}

function BurdJournals.flushPendingRuntimeShardTransmits(force)
    if not (ModData and ModData.transmit) then
        return
    end
    local now = getRuntimeNowMs()
    local debounceMs = math.max(0, tonumber(BurdJournals.RUNTIME_TRANSMIT_DEBOUNCE_MS) or 500)
    for shardKey, pendingAt in pairs(BurdJournals._runtimeShardPendingTransmit) do
        local lastAt = tonumber(BurdJournals._runtimeShardLastTransmitAt[shardKey]) or 0
        if force or ((now - lastAt) >= debounceMs and (now - tonumber(pendingAt or 0)) >= debounceMs) then
            ModData.transmit(shardKey)
            BurdJournals._runtimeShardLastTransmitAt[shardKey] = now
            BurdJournals._runtimeShardPendingTransmit[shardKey] = nil
            BurdJournals.debugPrint("[BurdJournals] Runtime shard transmit: " .. tostring(shardKey))
        end
    end
end

function BurdJournals.markRuntimeShardDirty(shardKey, forceTransmit)
    if not shardKey or not BurdJournals.isStrictMPServerContext or not BurdJournals.isStrictMPServerContext() then
        return false
    end
    local now = getRuntimeNowMs()
    BurdJournals._runtimeShardPendingTransmit[shardKey] = now
    local debounceMs = math.max(0, tonumber(BurdJournals.RUNTIME_TRANSMIT_DEBOUNCE_MS) or 500)
    local lastAt = tonumber(BurdJournals._runtimeShardLastTransmitAt[shardKey]) or 0
    if forceTransmit or (now - lastAt) >= debounceMs then
        BurdJournals.flushPendingRuntimeShardTransmits(forceTransmit == true)
        return true
    end
    return false
end

function BurdJournals.runtimeTouchJournalEntry(runtimeEntry, shardKey, sourceTag, forceTransmit)
    if type(runtimeEntry) ~= "table" then
        return false
    end
    runtimeEntry.updatedAt = getRuntimeNowMs()
    local changedByCaps = BurdJournals.enforceJournalRuntimeEntryCaps(runtimeEntry)
    if changedByCaps then
        BurdJournals.debugPrint("[BurdJournals] Runtime caps trimmed during " .. tostring(sourceTag or "unknown"))
    end
    return BurdJournals.markRuntimeShardDirty(shardKey, forceTransmit)
end

function BurdJournals.resolveJournalUUIDForRuntime(journalData, journal, createIfMissing)
    if type(journalData) ~= "table" then
        return nil
    end
    local uuid = journalData.uuid
    if type(uuid) == "string" and uuid ~= "" then
        return uuid
    end

    if journal and BurdJournals.getJournalDRCacheKey then
        uuid = BurdJournals.getJournalDRCacheKey(journal, createIfMissing ~= false)
    end
    if type(uuid) ~= "string" or uuid == "" then
        uuid = journalData.uuid
    end
    if (type(uuid) ~= "string" or uuid == "") and createIfMissing ~= false then
        uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
            or ("journal-" .. tostring(getRuntimeNowMs()))
    end
    if type(uuid) ~= "string" or uuid == "" then
        return nil
    end

    if journalData.uuid ~= uuid then
        journalData.uuid = uuid
        if journal and journal.transmitModData then
            journal:transmitModData()
        end
    end
    return uuid
end

function BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, createIfMissing, journal, sourceTag)
    if not BurdJournals.isStrictMPServerContext or not BurdJournals.isStrictMPServerContext() then
        return nil, nil, nil
    end
    if type(journalData) ~= "table" then
        return nil, nil, nil
    end

    local shouldCreate = createIfMissing ~= false
    local uuid = BurdJournals.resolveJournalUUIDForRuntime(journalData, journal, shouldCreate)
    if type(uuid) ~= "string" or uuid == "" then
        return nil, nil, nil
    end

    local shardKey = BurdJournals.getJournalRuntimeShardKeyForUUID(uuid)
    local shard = getOrCreateRuntimeShard(shardKey)
    if type(shard) ~= "table" then
        return nil, nil, uuid
    end

    local journals = shard.journals
    local runtimeEntry = journals[uuid]
    if type(runtimeEntry) ~= "table" then
        if not shouldCreate then
            return nil, shardKey, uuid
        end
        runtimeEntry = {
            claims = {},
            readCount = 0,
            readSessionCount = 0,
            currentSessionId = nil,
            currentSessionReadCount = 0,
            skillReadCounts = {},
            drLegacyMode3Migrated = false,
            updatedAt = getRuntimeNowMs(),
        }
        journals[uuid] = runtimeEntry
    end

    if BurdJournals.enforceJournalRuntimeEntryCaps(runtimeEntry) then
        journals[uuid] = runtimeEntry
        BurdJournals.markRuntimeShardDirty(shardKey, false)
    end

    if sourceTag then
        BurdJournals.debugPrint("[BurdJournals] Runtime entry resolved: uuid=" .. tostring(uuid) .. " source=" .. tostring(sourceTag))
    end
    return runtimeEntry, shardKey, uuid
end

function BurdJournals.buildRuntimeDeltaForPlayer(journalData, player)
    if not journalData or type(journalData) ~= "table" or not player then
        return nil
    end
    if not BurdJournals.isStrictMPServerContext or not BurdJournals.isStrictMPServerContext() then
        return nil
    end
    local runtimeEntry = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, false)
    if type(runtimeEntry) ~= "table" then
        return nil
    end

    local characterId = BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player) or nil
    local charClaims = characterId and runtimeEntry.claims and runtimeEntry.claims[characterId] or nil
    if type(charClaims) ~= "table" then
        charClaims = nil
    end

    local claimsProjection = {}
    if characterId and charClaims then
        claimsProjection[characterId] = BurdJournals.normalizeTable(charClaims) or charClaims
    end

    local skillReads = BurdJournals.normalizeTable(runtimeEntry.skillReadCounts) or runtimeEntry.skillReadCounts or {}
    local delta = {
        version = 1,
        characterId = characterId,
        claims = claimsProjection,
        readCount = math.max(0, tonumber(runtimeEntry.readCount) or 0),
        readSessionCount = math.max(0, tonumber(runtimeEntry.readSessionCount) or 0),
        currentSessionId = runtimeEntry.currentSessionId,
        currentSessionReadCount = math.max(0, tonumber(runtimeEntry.currentSessionReadCount) or 0),
        skillReadCounts = skillReads,
        drLegacyMode3Migrated = runtimeEntry.drLegacyMode3Migrated == true,
    }
    return delta
end

function BurdJournals.applyRuntimeProjectionToJournalData(journalData, player)
    local delta = BurdJournals.buildRuntimeDeltaForPlayer and BurdJournals.buildRuntimeDeltaForPlayer(journalData, player) or nil
    if type(delta) ~= "table" then
        return nil
    end
    journalData.claims = delta.claims or {}
    journalData.readCount = delta.readCount or 0
    journalData.readSessionCount = delta.readSessionCount or 0
    journalData.currentSessionId = delta.currentSessionId
    journalData.currentSessionReadCount = delta.currentSessionReadCount or 0
    journalData.skillReadCounts = delta.skillReadCounts or {}
    journalData.drLegacyMode3Migrated = delta.drLegacyMode3Migrated == true
    return delta
end

local function mergeLegacyRuntimeClaimsIntoEntry(runtimeEntry, journalData)
    if type(runtimeEntry) ~= "table" or type(journalData) ~= "table" then
        return false
    end
    local changed = false
    runtimeEntry.claims = type(runtimeEntry.claims) == "table" and runtimeEntry.claims or {}

    local claims = journalData.claims
    if type(claims) == "table" then
        for characterId, claimData in pairs(claims) do
            if type(characterId) == "string" and characterId ~= "" and type(claimData) == "table" then
                local existing = runtimeEntry.claims[characterId]
                if type(existing) ~= "table" then
                    existing = {}
                end
                for key, value in pairs(claimData) do
                    if existing[key] == nil then
                        existing[key] = value
                        changed = true
                    end
                end
                runtimeEntry.claims[characterId] = existing
            end
        end
    end

    local function mergeLegacyFallback(targetType, sourceMap)
        if type(sourceMap) ~= "table" then
            return
        end
        local legacyBucket = runtimeEntry.claims["legacy_unknown"]
        if type(legacyBucket) ~= "table" then
            legacyBucket = {}
            runtimeEntry.claims["legacy_unknown"] = legacyBucket
            changed = true
        end
        if type(legacyBucket[targetType]) ~= "table" then
            legacyBucket[targetType] = {}
            changed = true
        end
        for key, value in pairs(sourceMap) do
            if key ~= nil and value and legacyBucket[targetType][key] ~= true then
                legacyBucket[targetType][key] = true
                changed = true
            end
        end
    end

    mergeLegacyFallback("skills", journalData.claimedSkills)
    mergeLegacyFallback("traits", journalData.claimedTraits)
    mergeLegacyFallback("recipes", journalData.claimedRecipes)
    mergeLegacyFallback("stats", journalData.claimedStats)

    if type(journalData.claimedForgetSlot) == "table" then
        for characterId, value in pairs(journalData.claimedForgetSlot) do
            if type(characterId) == "string" and characterId ~= "" and value then
                local existing = runtimeEntry.claims[characterId]
                if type(existing) ~= "table" then
                    existing = {}
                    runtimeEntry.claims[characterId] = existing
                end
                if type(existing.forgetSlots) ~= "table" then
                    existing.forgetSlots = {}
                end
                if existing.forgetSlots.default == nil then
                    existing.forgetSlots.default = value
                    changed = true
                end
            end
        end
    end

    local skillReads = journalData.skillReadCounts
    if type(skillReads) == "table" then
        local merged, removed = ensureRuntimeNumericMap(skillReads, math.max(1, tonumber(BurdJournals.RUNTIME_MAX_SKILL_READ_KEYS) or 256))
        if removed > 0 or countTableEntriesSafe(merged) > 0 then
            runtimeEntry.skillReadCounts = merged
            changed = true
        end
    end

    runtimeEntry.readCount = math.max(runtimeEntry.readCount or 0, math.max(0, tonumber(journalData.readCount) or 0))
    runtimeEntry.readSessionCount = math.max(runtimeEntry.readSessionCount or 0, math.max(0, tonumber(journalData.readSessionCount) or 0))
    runtimeEntry.currentSessionReadCount = math.max(runtimeEntry.currentSessionReadCount or 0, math.max(0, tonumber(journalData.currentSessionReadCount) or 0))
    if journalData.currentSessionId ~= nil then
        runtimeEntry.currentSessionId = sanitizeRuntimeSessionId(journalData.currentSessionId)
    end
    if journalData.drLegacyMode3Migrated == true then
        runtimeEntry.drLegacyMode3Migrated = true
    end

    return changed
end

function BurdJournals.migrateJournalRuntimeToGlobalIfNeeded(journal, player, sourceTag)
    if not (BurdJournals.isStrictMPServerContext and BurdJournals.isStrictMPServerContext()) then
        return false
    end
    if not (journal and journal.getModData) then
        return false
    end

    local modData = journal:getModData()
    local journalData = modData and modData.BurdJournals
    if type(journalData) ~= "table" then
        return false
    end

    local runtimeEntry, shardKey = BurdJournals.getOrCreateJournalRuntimeEntryForData(journalData, true, journal, sourceTag or "migrateRuntime")
    if type(runtimeEntry) ~= "table" then
        return false
    end

    local hadEntryData = countTableEntriesSafe(runtimeEntry.claims) > 0
        or (tonumber(runtimeEntry.readCount) or 0) > 0
        or (tonumber(runtimeEntry.readSessionCount) or 0) > 0
        or (tonumber(runtimeEntry.currentSessionReadCount) or 0) > 0
        or countTableEntriesSafe(runtimeEntry.skillReadCounts) > 0

    local mergedLegacy = false
    if not hadEntryData then
        mergedLegacy = mergeLegacyRuntimeClaimsIntoEntry(runtimeEntry, journalData)
    end

    local stripped = false
    local legacyRuntimeKeys = {
        "claims",
        "claimedSkills",
        "claimedTraits",
        "claimedRecipes",
        "claimedStats",
        "claimedForgetSlot",
        "readCount",
        "readSessionCount",
        "currentSessionId",
        "currentSessionReadCount",
        "skillReadCounts",
        "drLegacyMode3Migrated",
    }
    for _, key in ipairs(legacyRuntimeKeys) do
        if journalData[key] ~= nil then
            journalData[key] = nil
            stripped = true
        end
    end

    if mergedLegacy then
        BurdJournals.runtimeTouchJournalEntry(runtimeEntry, shardKey, sourceTag or "migrateRuntime", false)
        BurdJournals.debugPrint("[BurdJournals] Runtime migration merged legacy fields for uuid=" .. tostring(journalData.uuid))
    end

    if stripped and journal.transmitModData then
        journal:transmitModData()
    end
    return mergedLegacy or stripped
end

function BurdJournals.getBaselineSnapshotMaxHours()
    local configured = tonumber(BurdJournals.BASELINE_SNAPSHOT_MAX_HOURS)
    if not configured or configured <= 0 then
        return 1
    end
    return configured
end

function BurdJournals.isWithinBaselineSnapshotWindow(player)
    if not player then
        return false
    end
    local hoursAlive = player.getHoursSurvived and tonumber(player:getHoursSurvived()) or 0
    return hoursAlive <= BurdJournals.getBaselineSnapshotMaxHours()
end

function BurdJournals.shouldPersistPlayerBaselineModData()
    -- Strict MP contexts (dedicated server + remote clients) should avoid player ModData baseline payloads.
    if BurdJournals.isStrictMPContext and BurdJournals.isStrictMPContext() then
        return false
    end
    return true
end

function BurdJournals.shouldPersistPlayerDRCache()
    -- In strict MP, DR runtime is persisted server-side in global ModData.
    if BurdJournals.isStrictMPContext and BurdJournals.isStrictMPContext() then
        return false
    end
    return true
end

local function trimJournalDRCache(cache, maxJournals, maxAliases)
    if type(cache) ~= "table" then
        return false, 0, 0
    end

    local journals = ensureDRCacheMap(cache, "journals")
    local aliases = ensureDRCacheMap(cache, "aliases")
    if type(journals) ~= "table" or type(aliases) ~= "table" then
        return false, 0, 0
    end

    local changed = false
    local removedJournals = 0
    local removedAliases = 0
    local maxJ = math.max(1, tonumber(maxJournals) or 24)
    local maxA = math.max(1, tonumber(maxAliases) or (maxJ * 4))

    local journalEntries = {}
    for key, snapshot in pairs(journals) do
        if type(key) == "string" and key ~= "" then
            table.insert(journalEntries, {
                key = key,
                updatedAt = tonumber(snapshot and snapshot.updatedAt) or 0
            })
        else
            journals[key] = nil
            changed = true
            removedJournals = removedJournals + 1
        end
    end

    if #journalEntries > maxJ then
        table.sort(journalEntries, function(a, b)
            return (a.updatedAt or 0) > (b.updatedAt or 0)
        end)

        local keep = {}
        for i = 1, math.min(maxJ, #journalEntries) do
            keep[journalEntries[i].key] = true
        end

        for _, entry in ipairs(journalEntries) do
            if not keep[entry.key] then
                journals[entry.key] = nil
                changed = true
                removedJournals = removedJournals + 1
            end
        end
    end

    local aliasEntries = {}
    for alias, mappedKey in pairs(aliases) do
        if type(alias) == "string" and alias ~= ""
            and type(mappedKey) == "string" and mappedKey ~= ""
            and type(journals[mappedKey]) == "table" then
            table.insert(aliasEntries, {
                alias = alias,
                updatedAt = tonumber(journals[mappedKey].updatedAt) or 0
            })
        else
            aliases[alias] = nil
            changed = true
            removedAliases = removedAliases + 1
        end
    end

    if #aliasEntries > maxA then
        table.sort(aliasEntries, function(a, b)
            return (a.updatedAt or 0) > (b.updatedAt or 0)
        end)

        local keepAlias = {}
        for i = 1, math.min(maxA, #aliasEntries) do
            keepAlias[aliasEntries[i].alias] = true
        end

        for _, entry in ipairs(aliasEntries) do
            if not keepAlias[entry.alias] then
                aliases[entry.alias] = nil
                changed = true
                removedAliases = removedAliases + 1
            end
        end
    end

    return changed, removedJournals, removedAliases
end

local function sanitizeNumericBaselineMap(source, maxEntries)
    if type(source) ~= "table" and BurdJournals.normalizeTable then
        source = BurdJournals.normalizeTable(source)
    end
    if type(source) ~= "table" then
        return nil, 0
    end

    local cleaned = {}
    local kept = 0
    local removed = 0
    local limit = math.max(1, tonumber(maxEntries) or 512)

    local keys = collectSortedStringKeys(source)
    for _, key in ipairs(keys) do
        local value = source[key]
        local keyStr = type(key) == "string" and key or nil
        local numValue = tonumber(value)
        if keyStr and keyStr ~= "" and numValue and numValue >= 0 then
            if kept < limit then
                cleaned[keyStr] = math.floor(numValue + 0.000001)
                kept = kept + 1
            else
                removed = removed + 1
            end
        else
            removed = removed + 1
        end
    end

    return cleaned, removed
end

local function sanitizeBooleanBaselineMap(source, maxEntries)
    if type(source) ~= "table" and BurdJournals.normalizeTable then
        source = BurdJournals.normalizeTable(source)
    end
    if type(source) ~= "table" then
        return nil, 0
    end

    local cleaned = {}
    local kept = 0
    local removed = 0
    local limit = math.max(1, tonumber(maxEntries) or 1024)

    local keys = collectSortedStringKeys(source)
    for _, key in ipairs(keys) do
        local value = source[key]
        local keyStr = type(key) == "string" and key or nil
        if keyStr and keyStr ~= "" and value == true then
            if kept < limit then
                cleaned[keyStr] = true
                kept = kept + 1
            else
                removed = removed + 1
            end
        elseif value ~= nil then
            removed = removed + 1
        end
    end

    return cleaned, removed
end

function BurdJournals.getOrCreateJournalDRCache()
    if not ModData or not ModData.getOrCreate then
        return nil
    end
    local cache = ModData.getOrCreate("BurdJournals_JournalDRCache")
    ensureDRCacheMap(cache, "journals")
    ensureDRCacheMap(cache, "aliases")
    return cache
end

local function normalizeDRAliasComponent(value)
    if value == nil then
        return ""
    end
    local s = tostring(value)
    s = string.lower(s)
    s = string.gsub(s, "|", "_")
    return s
end

local function buildJournalDRAliasKeys(data, journal)
    local aliases = {}
    local seen = {}
    local function addAlias(alias)
        if type(alias) ~= "string" or alias == "" then
            return
        end
        if seen[alias] then
            return
        end
        seen[alias] = true
        aliases[#aliases + 1] = alias
    end

    if not data then
        return aliases
    end

    local itemType = normalizeDRAliasComponent(drReadField(data, "itemType") or (journal and journal.getFullType and journal:getFullType()) or "")
    local ts = tonumber(drReadField(data, "timestamp"))
    local tsKey = ts and tostring(math.floor(ts * 1000) / 1000) or ""
    local steam = normalizeDRAliasComponent(drReadField(data, "ownerSteamId"))
    local user = normalizeDRAliasComponent(drReadField(data, "ownerUsername"))
    local charName = normalizeDRAliasComponent(drReadField(data, "ownerCharacterName"))
    local author = normalizeDRAliasComponent(drReadField(data, "author"))

    if drReadField(data, "isPlayerCreated") == true and (steam ~= "" or user ~= "") then
        addAlias("player|" .. steam .. "|" .. user .. "|" .. tsKey .. "|" .. itemType)
        addAlias("playerchar|" .. steam .. "|" .. charName .. "|" .. tsKey .. "|" .. itemType)
    end
    if author ~= "" and tsKey ~= "" then
        addAlias("author|" .. author .. "|" .. tsKey .. "|" .. itemType)
    end

    return aliases
end

local function makeJournalDRSnapshot(data, journal, sourceTag)
    return {
        readCount = math.max(0, tonumber(drReadField(data, "readCount")) or 0),
        readSessionCount = math.max(0, tonumber(drReadField(data, "readSessionCount")) or 0),
        currentSessionId = drReadField(data, "currentSessionId"),
        currentSessionReadCount = math.max(0, tonumber(drReadField(data, "currentSessionReadCount")) or 0),
        skillReadCounts = copyDRSkillReadCounts(drReadField(data, "skillReadCounts")),
        drLegacyMode3Migrated = drReadField(data, "drLegacyMode3Migrated") == true,
        itemType = (journal and journal.getFullType and journal:getFullType()) or drReadField(data, "itemType") or nil,
        updatedAt = getTimestampMs and getTimestampMs() or os.time(),
        source = sourceTag
    }
end

local function getOrCreatePlayerJournalDRCache(player)
    if BurdJournals.shouldPersistPlayerDRCache and not BurdJournals.shouldPersistPlayerDRCache() then
        return nil
    end
    if not player or not player.getModData then
        return nil
    end
    local playerModData = player:getModData()
    if type(playerModData) ~= "table" then
        return nil
    end
    playerModData.BurdJournals = playerModData.BurdJournals or {}
    if type(playerModData.BurdJournals.journalDRCache) ~= "table" then
        playerModData.BurdJournals.journalDRCache = {}
    end
    local cache = playerModData.BurdJournals.journalDRCache
    ensureDRCacheMap(cache, "journals")
    ensureDRCacheMap(cache, "aliases")
    return cache
end

function BurdJournals.compactPlayerJournalDRCache(player, forceTransmit)
    if not player or not player.getModData then
        return false, 0, 0
    end

    local playerModData = player:getModData()
    local bj = type(playerModData) == "table" and playerModData.BurdJournals or nil
    local cache = type(bj) == "table" and bj.journalDRCache or nil
    if type(cache) ~= "table" then
        return false, 0, 0
    end

    ensureDRCacheMap(cache, "journals")
    ensureDRCacheMap(cache, "aliases")

    local changed, removedJournals, removedAliases = trimJournalDRCache(
        cache,
        BurdJournals.DR_PLAYER_CACHE_MAX_JOURNALS,
        BurdJournals.DR_PLAYER_CACHE_MAX_ALIASES
    )

    if changed and forceTransmit and player and player.transmitModData then
        player:transmitModData()
    end

    return changed, removedJournals, removedAliases
end

function BurdJournals.compactPlayerBurdJournalsData(player, forceTransmit)
    if not player or not player.getModData then
        return false, 0, 0, 0, 0, 0
    end

    local playerModData = player:getModData()
    if type(playerModData) ~= "table" then
        return false, 0, 0, 0, 0, 0
    end

    local changed = false
    local removedLegacyBaseline = 0
    local removedTransient = 0
    local removedSkills = 0
    local removedTraits = 0
    local removedRecipes = 0

    if playerModData.BurdJournals_Baseline ~= nil then
        playerModData.BurdJournals_Baseline = nil
        changed = true
        removedLegacyBaseline = 1
    end

    local bj = playerModData.BurdJournals
    if type(bj) ~= "table" then
        if changed and forceTransmit and player.transmitModData then
            player:transmitModData()
        end
        return changed, removedLegacyBaseline, removedTransient, removedSkills, removedTraits, removedRecipes
    end

    local isAuthoritativeServer = isServer and isServer()
    local preserveDebugBaseline = bj.debugModified == true

    local transientKeys = { "steamId", "characterId", "fromServerCache" }
    for _, key in ipairs(transientKeys) do
        if bj[key] ~= nil then
            bj[key] = nil
            changed = true
            removedTransient = removedTransient + 1
        end
    end

    local cleanedSkills, removedSkillEntries = sanitizeNumericBaselineMap(
        bj.skillBaseline,
        BurdJournals.PLAYER_BASELINE_MAX_SKILLS
    )
    removedSkills = removedSkills + removedSkillEntries
    if cleanedSkills then
        if bj.skillBaseline ~= cleanedSkills then
            bj.skillBaseline = cleanedSkills
            changed = true
        end
    elseif bj.skillBaseline ~= nil then
        bj.skillBaseline = nil
        changed = true
    end

    local cleanedTraits, removedTraitEntries = sanitizeBooleanBaselineMap(
        bj.traitBaseline,
        BurdJournals.PLAYER_BASELINE_MAX_TRAITS
    )
    removedTraits = removedTraits + removedTraitEntries
    if cleanedTraits then
        if bj.traitBaseline ~= cleanedTraits then
            bj.traitBaseline = cleanedTraits
            changed = true
        end
    elseif bj.traitBaseline ~= nil then
        bj.traitBaseline = nil
        changed = true
    end

    local cleanedRecipes, removedRecipeEntries = sanitizeBooleanBaselineMap(
        bj.recipeBaseline,
        BurdJournals.PLAYER_BASELINE_MAX_RECIPES
    )
    removedRecipes = removedRecipes + removedRecipeEntries
    if cleanedRecipes then
        if bj.recipeBaseline ~= cleanedRecipes then
            bj.recipeBaseline = cleanedRecipes
            changed = true
        end
    elseif bj.recipeBaseline ~= nil then
        bj.recipeBaseline = nil
        changed = true
    end

    if bj.baselineCaptured ~= true and bj.debugModified ~= true then
        if bj.baselineVersion ~= nil then
            bj.baselineVersion = nil
            changed = true
            removedTransient = removedTransient + 1
        end
    end

    -- Keep a compact player-level baseline backup even on server contexts.
    -- This protects baseline persistence across cache resets/mod updates by
    -- allowing recovery from player ModData when global cache is unavailable.
    local keepServerBaselineBackup = true
    if BurdJournals.shouldPersistPlayerBaselineModData then
        keepServerBaselineBackup = BurdJournals.shouldPersistPlayerBaselineModData()
    end
    if isAuthoritativeServer and not preserveDebugBaseline and not keepServerBaselineBackup then
        local function countEntries(tbl)
            if type(tbl) ~= "table" then
                return 0
            end
            local c = 0
            for _ in pairs(tbl) do
                c = c + 1
            end
            return c
        end

        if bj.skillBaseline ~= nil then
            removedSkills = removedSkills + countEntries(bj.skillBaseline)
            bj.skillBaseline = nil
            changed = true
        end
        if bj.traitBaseline ~= nil then
            removedTraits = removedTraits + countEntries(bj.traitBaseline)
            bj.traitBaseline = nil
            changed = true
        end
        if bj.recipeBaseline ~= nil then
            removedRecipes = removedRecipes + countEntries(bj.recipeBaseline)
            bj.recipeBaseline = nil
            changed = true
        end
        if bj.baselineCaptured ~= nil then
            bj.baselineCaptured = nil
            changed = true
            removedTransient = removedTransient + 1
        end
        if bj.baselineVersion ~= nil then
            bj.baselineVersion = nil
            changed = true
            removedTransient = removedTransient + 1
        end
    end

    if isAuthoritativeServer and bj.journalDRCache ~= nil then
        bj.journalDRCache = nil
        changed = true
        removedTransient = removedTransient + 1
    end

    if bj.journalDRCache ~= nil and type(bj.journalDRCache) ~= "table" then
        bj.journalDRCache = nil
        changed = true
    end

    if type(bj.journalDRCache) == "table" then
        local drChanged = trimJournalDRCache(
            bj.journalDRCache,
            BurdJournals.DR_PLAYER_CACHE_MAX_JOURNALS,
            BurdJournals.DR_PLAYER_CACHE_MAX_ALIASES
        )
        if drChanged then
            changed = true
        end
        local journals = ensureDRCacheMap(bj.journalDRCache, "journals")
        local aliases = ensureDRCacheMap(bj.journalDRCache, "aliases")
        local function mapHasEntries(tbl)
            if BurdJournals.hasAnyEntries then
                return BurdJournals.hasAnyEntries(tbl)
            end
            if type(tbl) ~= "table" then
                return false
            end
            local pairsFn = (_safeType and _safeType(_safePairs) == "function") and _safePairs or nil
            if not pairsFn then
                return false
            end
            local ok, hasEntries = safePcall(function()
                for _, _ in pairsFn(tbl) do
                    return true
                end
                return false
            end)
            if ok then
                return hasEntries == true
            end
            return false
        end
        if not mapHasEntries(journals) and not mapHasEntries(aliases) then
            bj.journalDRCache = nil
            changed = true
        end
    end

    if changed and forceTransmit and player.transmitModData then
        player:transmitModData()
    end

    return changed, removedLegacyBaseline, removedTransient, removedSkills, removedTraits, removedRecipes
end

local function findJournalDRSnapshot(cache, journalKey, aliases)
    if not cache then
        return nil, nil
    end
    local journals = ensureDRCacheMap(cache, "journals")
    local aliasMap = ensureDRCacheMap(cache, "aliases")
    if type(journals) ~= "table" then
        return nil, nil
    end

    if journalKey and type(journals[journalKey]) == "table" then
        return journals[journalKey], journalKey
    end

    if type(aliasMap) == "table" and type(aliases) == "table" then
        for _, alias in ipairs(aliases) do
            local mappedKey = aliasMap[alias]
            if mappedKey and type(journals[mappedKey]) == "table" then
                return journals[mappedKey], mappedKey
            end
        end
    end

    return nil, nil
end

function BurdJournals.getJournalDRCacheKey(journal, allowCreate)
    if not journal or not journal.getModData then
        return nil
    end
    local createWhenMissing = allowCreate ~= false
    local modData = journal:getModData()
    if not modData then
        return nil
    end
    local data = modData.BurdJournals
    if not data then
        return nil
    end

    local currentUuid = drReadField(data, "uuid")
    if type(currentUuid) == "string" and currentUuid ~= "" then
        return currentUuid
    end
    if not createWhenMissing then
        return nil
    end

    local generatedUuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
        or ("journal-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
    if drWriteField(data, "uuid", generatedUuid) then
        if journal.transmitModData then
            journal:transmitModData()
        end
        return generatedUuid
    end

    return nil
end

local function getFallbackJournalDRCacheKey(data, journal)
    local aliases = buildJournalDRAliasKeys(data, journal)
    if #aliases > 0 then
        return "alias:" .. aliases[1]
    end

    local fullType = ""
    if journal and journal.getFullType then
        fullType = tostring(journal:getFullType() or "")
    end
    local itemId = ""
    if journal and journal.getID then
        itemId = tostring(journal:getID() or "")
    end
    if fullType ~= "" or itemId ~= "" then
        return "item:" .. fullType .. "|" .. itemId
    end

    return nil
end

function BurdJournals.captureJournalDRState(journal, sourceTag, player)
    if not journal or not journal.getModData then
        return false
    end
    local modData = journal:getModData()
    local data = modData and modData.BurdJournals
    if not data then
        return false
    end

    local cache = BurdJournals.getOrCreateJournalDRCache()
    local journalKey = BurdJournals.getJournalDRCacheKey(journal)
    if not journalKey then
        journalKey = getFallbackJournalDRCacheKey(data, journal)
    end
    if not cache or not journalKey then
        return false
    end

    local aliases = buildJournalDRAliasKeys(data, journal)
    local journals = ensureDRCacheMap(cache, "journals")
    local aliasMap = ensureDRCacheMap(cache, "aliases")
    if type(journals) ~= "table" or type(aliasMap) ~= "table" then
        return false
    end

    local snapshot = makeJournalDRSnapshot(data, journal, sourceTag)
    local snapshotHasData = BurdJournals.hasJournalDRData(snapshot)
    local existingSnapshot, existingKey = findJournalDRSnapshot(cache, journalKey, aliases)
    if type(existingSnapshot) == "table"
        and BurdJournals.hasJournalDRData(existingSnapshot)
        and not snapshotHasData then
        snapshot = existingSnapshot
        snapshotHasData = true
        if existingKey and type(existingKey) == "string" and existingKey ~= "" then
            journalKey = existingKey
        end
    end

    -- Avoid persisting empty DR snapshots; they create player ModData bloat and
    -- don't preserve any meaningful state.
    if not snapshotHasData then
        return false
    end

    journals[journalKey] = snapshot
    for _, alias in ipairs(aliases) do
        aliasMap[alias] = journalKey
    end

    if ModData and ModData.transmit then
        ModData.transmit("BurdJournals_JournalDRCache")
    end

    local playerCache = getOrCreatePlayerJournalDRCache(player)
    if playerCache then
        local playerJournals = ensureDRCacheMap(playerCache, "journals")
        local playerAliases = ensureDRCacheMap(playerCache, "aliases")
        if type(playerJournals) == "table" then
            playerJournals[journalKey] = snapshot
        end
        for _, alias in ipairs(aliases) do
            if type(playerAliases) == "table" then
                playerAliases[alias] = journalKey
            end
        end
        trimJournalDRCache(
            playerCache,
            BurdJournals.DR_PLAYER_CACHE_MAX_JOURNALS,
            BurdJournals.DR_PLAYER_CACHE_MAX_ALIASES
        )
        if player.transmitModData then
            player:transmitModData()
        end
    end
    BurdJournals.debugPrint(
        "[BurdJournals] Captured DR cache key="
        .. tostring(journalKey)
        .. " source="
        .. tostring(sourceTag or "unknown")
        .. " readCount="
        .. tostring(snapshot.readCount)
        .. " readSessionCount="
        .. tostring(snapshot.readSessionCount)
    )
    return true
end

function BurdJournals.restoreJournalDRStateIfMissing(journal, sourceTag, player)
    if not journal or not journal.getModData then
        return false
    end
    local modData = journal:getModData()
    local data = modData and modData.BurdJournals
    if not data then
        return false
    end

    local cache = BurdJournals.getOrCreateJournalDRCache()
    if not cache then
        return false
    end

    local journalKey = BurdJournals.getJournalDRCacheKey(journal, false)
    if not journalKey then
        journalKey = getFallbackJournalDRCacheKey(data, journal)
    end
    local aliases = buildJournalDRAliasKeys(data, journal)
    local backup, resolvedKey = findJournalDRSnapshot(cache, journalKey, aliases)

    if type(backup) ~= "table" then
        local playerCache = getOrCreatePlayerJournalDRCache(player)
        backup, resolvedKey = findJournalDRSnapshot(playerCache, journalKey, aliases)
    end

    if type(backup) ~= "table" then
        BurdJournals.debugPrint(
            "[BurdJournals] DR restore miss (no backup) key="
            .. tostring(journalKey)
            .. " aliases="
            .. tostring(#aliases)
            .. " source="
            .. tostring(sourceTag or "unknown")
        )
        return false
    end

    if (not journalKey)
        and resolvedKey
        and type(resolvedKey) == "string"
        and resolvedKey ~= ""
        and not string.find(resolvedKey, "^alias:", 1, true)
        and not string.find(resolvedKey, "^item:", 1, true) then
        drWriteField(data, "uuid", resolvedKey)
        journalKey = resolvedKey
    end

    local hasCurrent = BurdJournals.hasJournalDRData(data)
    local hasBackup = BurdJournals.hasJournalDRData(backup)
    if hasCurrent or not hasBackup then
        return false
    end

    drWriteField(data, "readCount", math.max(0, tonumber(backup.readCount) or 0))
    drWriteField(data, "readSessionCount", math.max(0, tonumber(backup.readSessionCount) or 0))
    drWriteField(data, "currentSessionId", backup.currentSessionId)
    drWriteField(data, "currentSessionReadCount", math.max(0, tonumber(backup.currentSessionReadCount) or 0))
    drWriteField(data, "skillReadCounts", copyDRSkillReadCounts(backup.skillReadCounts))
    drWriteField(data, "drLegacyMode3Migrated", backup.drLegacyMode3Migrated == true)

    if journal.transmitModData then
        journal:transmitModData()
    end
    BurdJournals.captureJournalDRState(journal, "restore:" .. tostring(sourceTag or "unknown"), player)

    BurdJournals.debugPrint(
        "[BurdJournals] Restored DR counters from cache for journal "
        .. tostring(journalKey or resolvedKey)
        .. " (source="
        .. tostring(sourceTag or "unknown")
        .. ")"
    )
    return true
end

function BurdJournals.formatTimestamp(hours)
    local days = math.floor(hours / 24)
    local remainingHours = math.floor(hours % 24)
    return string.format("Day %d, Hour %d", days, remainingHours)
end

BurdJournals.RANDOM_FIRST_NAMES = {
    "James", "John", "Michael", "David", "Robert", "William", "Thomas", "Richard",
    "Mary", "Patricia", "Jennifer", "Linda", "Elizabeth", "Barbara", "Susan", "Jessica",
    "Daniel", "Matthew", "Anthony", "Mark", "Donald", "Steven", "Paul", "Andrew",
    "Sarah", "Karen", "Nancy", "Lisa", "Betty", "Margaret", "Sandra", "Ashley",
    "Joshua", "Kenneth", "Kevin", "Brian", "George", "Timothy", "Ronald", "Edward",
    "Kimberly", "Emily", "Donna", "Michelle", "Dorothy", "Carol", "Amanda", "Melissa",
}

BurdJournals.RANDOM_LAST_NAMES = {
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis",
    "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson", "Thomas",
    "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson", "White",
    "Harris", "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson", "Walker", "Young",
    "Allen", "King", "Wright", "Scott", "Torres", "Nguyen", "Hill", "Flores",
    "Green", "Adams", "Nelson", "Baker", "Hall", "Rivera", "Campbell", "Mitchell",
}

function BurdJournals.generateRandomSurvivorName()
    local firstName = BurdJournals.RANDOM_FIRST_NAMES[ZombRand(#BurdJournals.RANDOM_FIRST_NAMES) + 1]
    local lastName = BurdJournals.RANDOM_LAST_NAMES[ZombRand(#BurdJournals.RANDOM_LAST_NAMES) + 1]
    return firstName .. " " .. lastName
end

BurdJournals.PROFESSIONS = {
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

function BurdJournals.getRandomProfession()
    local professions = BurdJournals.PROFESSIONS
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

function BurdJournals.generateRandomSkills(minSkills, maxSkills, minXP, maxXP)
    minSkills = minSkills or 1
    maxSkills = maxSkills or 2
    minXP = minXP or 25
    maxXP = maxXP or 75

    local skillCount = ZombRand(minSkills, maxSkills + 1)
    local allSkills = BurdJournals.getAllowedSkills()
    local availableSkills = {}

    for _, skill in ipairs(allSkills) do
        table.insert(availableSkills, skill)
    end

    local skills = {}
    for i = 1, skillCount do
        if #availableSkills == 0 then break end

        local index = ZombRand(#availableSkills) + 1
        local skillName = availableSkills[index]

        table.remove(availableSkills, index)

        local xp = ZombRand(minXP, maxXP + 1)

        skills[skillName] = {
            xp = xp,
            level = math.floor(xp / 75)
        }
    end

    return skills
end

function BurdJournals.mapPerkIdToSkillName(perkId)
    if not perkId then return nil end

    local mappings = {
        Woodwork = "Carpentry",
        PlantScavenging = "Foraging",
    }

    if mappings[perkId] then
        return mappings[perkId]
    end

    local allowedSkills = BurdJournals.getAllowedSkills()
    for _, skillName in ipairs(allowedSkills) do
        if skillName == perkId then
            return skillName
        end

        if string.lower(skillName) == string.lower(perkId) then
            return skillName
        end
    end

    return nil
end

local function getCachedBaselineFromServer(player)
    if not player then
        return nil
    end
    if not (isServer and isServer()) then
        return nil
    end
    if not BurdJournals.Server or not BurdJournals.Server.getCachedBaseline then
        return nil
    end
    if not BurdJournals.getPlayerCharacterId then
        return nil
    end
    local characterId = BurdJournals.getPlayerCharacterId(player)
    if not characterId then
        return nil
    end
    return BurdJournals.Server.getCachedBaseline(characterId, player)
end

function BurdJournals.getSkillBaseline(player, skillName)
    if not player then return 0 end

    local cachedBaseline = getCachedBaselineFromServer(player)
    if cachedBaseline and type(cachedBaseline.skillBaseline) == "table" then
        local cached = tonumber(cachedBaseline.skillBaseline[skillName]) or 0
        if cached > 0 then
            return cached
        end
    end
    
    -- Check for stored baseline first (allows manual adjustment via debug panel)
    local modData = player:getModData()
    if modData.BurdJournals and modData.BurdJournals.skillBaseline then
        local storedBaseline = modData.BurdJournals.skillBaseline[skillName]
        if storedBaseline and storedBaseline > 0 then
            return storedBaseline
        end
    end
    
    -- For passive skills (Fitness/Strength), only use the fallback Level 5 baseline
    -- when a baseline snapshot actually exists for this character.
    -- Passive skill traits (Athletic, Strong, etc.) are dynamically granted/removed
    -- based on skill level - they're not true "starting" traits.
    -- This prevents partial/passive-only baseline enforcement when snapshot capture failed.
    if skillName == "Fitness" or skillName == "Strength" then
        local hasBaseline = BurdJournals.hasBaselineCaptured and BurdJournals.hasBaselineCaptured(player)
        if not hasBaseline then
            return 0
        end
        local perk = BurdJournals.getPerkByName(skillName)
        if perk and perk.getTotalXpForLevel then
            -- Entry to Level 5 = getTotalXpForLevel(4) (XP to complete level 4)
            return perk:getTotalXpForLevel(4) or 0
        end
        return BurdJournals.PASSIVE_XP_THRESHOLDS[5] or 37500
    end
    
    -- For non-passive skills with no stored baseline, return 0
    return 0
end

-- Set skill baseline for a specific skill (level-based, converts to XP internally)
-- This allows admins/debuggers to manually adjust individual skill baselines
function BurdJournals.setSkillBaseline(player, skillName, level)
    if not player or not skillName then return false end
    
    -- Get the perk to calculate XP for the level
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then return false end
    
    -- For passive skills, handle specially
    local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillName)
    if isPassive == nil then isPassive = (skillName == "Fitness" or skillName == "Strength") end
    
    -- Calculate XP required for the specified level
    -- Use our verified threshold tables for consistent values
    local baselineXP = 0
    if level > 0 then
        if isPassive then
            baselineXP = BurdJournals.PASSIVE_XP_THRESHOLDS[level] or 0
        else
            baselineXP = BurdJournals.STANDARD_XP_THRESHOLDS[level] or 0
        end
    end
    
    -- Store in mod data
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    modData.BurdJournals.skillBaseline = modData.BurdJournals.skillBaseline or {}
    modData.BurdJournals.skillBaseline[skillName] = baselineXP
    
    BurdJournals.debugPrint("[BurdJournals] Set skill baseline: " .. skillName .. " = Level " .. level .. " (" .. baselineXP .. " XP)")
    
    -- Notify any open UI panels that baseline has changed
    if BurdJournals.notifyBaselineChanged then
        BurdJournals.notifyBaselineChanged(player, "skill", skillName)
    end
    
    return true
end

-- Get skill baseline as a level (for display purposes)
function BurdJournals.getSkillBaselineLevel(player, skillName)
    if not player or not skillName then return 0 end
    
    local baselineXP = BurdJournals.getSkillBaseline(player, skillName)
    if baselineXP <= 0 then return 0 end
    
    -- Convert XP to level using our verified threshold tables
    local isPassive = (skillName == "Fitness" or skillName == "Strength")
    local thresholds = isPassive and BurdJournals.PASSIVE_XP_THRESHOLDS or BurdJournals.STANDARD_XP_THRESHOLDS
    
    local level = 0
    for lvl = 1, 10 do
        local threshold = thresholds[lvl] or 0
        if baselineXP >= threshold then
            level = lvl
        else
            break
        end
    end
    
    return level
end

-- Set trait baseline (whether the trait is considered a "starting" trait)
function BurdJournals.setTraitBaseline(player, traitId, isBaseline)
    if not player or not traitId then return false end
    
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    modData.BurdJournals.traitBaseline = modData.BurdJournals.traitBaseline or {}
    
    -- Use alias system to store all variations for reliable lookup
    local allAliases = BurdJournals.getTraitAliases(traitId)
    
    if isBaseline then
        -- Store all variations as baseline
        for _, alias in ipairs(allAliases) do
            modData.BurdJournals.traitBaseline[alias] = true
        end
    else
        -- Clear all variations
        for _, alias in ipairs(allAliases) do
            modData.BurdJournals.traitBaseline[alias] = nil
        end
    end
    
    BurdJournals.debugPrint("[BurdJournals] Set trait baseline: " .. traitId .. " = " .. tostring(isBaseline) .. " (aliases: " .. #allAliases .. ")")
    
    -- Notify any open UI panels that baseline has changed
    if BurdJournals.notifyBaselineChanged then
        BurdJournals.notifyBaselineChanged(player, "trait", traitId)
    end
    
    return true
end

-- Set recipe baseline (whether the recipe is considered a "starting" recipe)
function BurdJournals.setRecipeBaseline(player, recipeName, isBaseline)
    if not player or not recipeName then return false end
    
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    modData.BurdJournals.recipeBaseline = modData.BurdJournals.recipeBaseline or {}
    
    if isBaseline then
        modData.BurdJournals.recipeBaseline[recipeName] = true
    else
        modData.BurdJournals.recipeBaseline[recipeName] = nil
    end

    BurdJournals.debugPrint("[BurdJournals] Set recipe baseline: " .. recipeName .. " = " .. tostring(isBaseline))
    return true
end

-- Get comprehensive baseline data for a player (for UI display)
function BurdJournals.getPlayerBaselineData(player)
    if not player then return nil end
    
    local data = {
        skills = {},
        traits = {},
        recipes = {},
        username = player:getUsername()
    }
    
    -- Get all skills with their baselines
    local allSkills = BurdJournals.discoverAllSkills and BurdJournals.discoverAllSkills() or {}
    for _, skillInfo in ipairs(allSkills) do
        local skillName = type(skillInfo) == "table" and skillInfo.id or skillInfo
        local perk = BurdJournals.getPerkByName(skillName)
        if perk then
            local currentLevel = player:getPerkLevel(perk)
            local baselineLevel = BurdJournals.getSkillBaselineLevel(player, skillName)
            local baselineXP = BurdJournals.getSkillBaseline(player, skillName)
            local currentXP = player:getXp():getXP(perk)
            
            table.insert(data.skills, {
                name = skillName,
                displayName = BurdJournals.getSkillDisplayName and BurdJournals.getSkillDisplayName(skillName) or skillName,
                currentLevel = currentLevel,
                currentXP = currentXP,
                baselineLevel = baselineLevel,
                baselineXP = baselineXP,
                isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillName) or false
            })
        end
    end
    
    -- Get all traits with their baselines
    local traitBaseline = BurdJournals.getTraitBaseline(player)
    local playerTraits = player:getTraits()
    if playerTraits then
        for i = 0, playerTraits:size() - 1 do
            local trait = playerTraits:get(i)
            if trait then
                local traitId = tostring(trait)
                table.insert(data.traits, {
                    id = traitId,
                    displayName = BurdJournals.getTraitDisplayName and BurdJournals.getTraitDisplayName(traitId) or traitId,
                    hasTrait = true,
                    isBaseline = traitBaseline[traitId] == true or traitBaseline[string.lower(traitId)] == true,
                    isPassiveSkillTrait = BurdJournals.isPassiveSkillTrait and BurdJournals.isPassiveSkillTrait(traitId) or false
                })
            end
        end
    end
    
    -- Get recipes - simplified for now
    local recipeBaseline = BurdJournals.getRecipeBaseline(player)
    data.recipeCount = 0
    for _ in pairs(recipeBaseline) do
        data.recipeCount = data.recipeCount + 1
    end
    
    return data
end

-- Passive skill traits that are automatically granted/removed based on skill levels
-- These should NEVER be considered "starting" traits because they're earned through gameplay
BurdJournals.PASSIVE_SKILL_TRAITS = {
    -- Fitness-based traits (granted at certain fitness levels)
    ["Athletic"] = true,      -- Granted at Fitness 4+
    ["Fit"] = true,           -- Alternative name
    ["Unfit"] = true,         -- Low fitness
    ["OutOfShape"] = true,    -- Very low fitness
    -- Strength-based traits (granted at certain strength levels)
    ["Strong"] = true,        -- Granted at Strength 4+
    ["Stout"] = true,         -- Alternative name for Strong
    ["Weak"] = true,          -- Low strength
    ["Feeble"] = true,        -- Very low strength
    ["Puny"] = true,          -- Very very low strength (lowest)
    -- Weight-based traits (can change during gameplay)
    ["Overweight"] = true,
    ["Obese"] = true,
    ["Underweight"] = true,
    ["VeryUnderweight"] = true,
    ["Emaciated"] = true,
}

function BurdJournals.isPassiveSkillTrait(traitId)
    if not traitId then return false end
    -- Check both original and normalized (without "base:" prefix)
    local normalized = string.gsub(traitId, "^base:", "")
    return BurdJournals.PASSIVE_SKILL_TRAITS[traitId] == true 
        or BurdJournals.PASSIVE_SKILL_TRAITS[normalized] == true
end

function BurdJournals.isStartingTrait(player, traitId)
    if not player then return false end
    if not traitId then return false end
    
    -- Passive skill traits (Athletic, Strong, etc.) are NEVER starting traits
    -- They are earned through gameplay progression, not selected at character creation
    if BurdJournals.isPassiveSkillTrait(traitId) then
        return false
    end
    
    local baseline = BurdJournals.getTraitBaseline(player)
    if type(baseline) ~= "table" then
        return false
    end
    
    -- Use alias system for comprehensive matching
    -- Check if any alias of the input trait is in the baseline
    local allAliases = BurdJournals.getTraitAliases(traitId)
    for _, alias in ipairs(allAliases) do
        if baseline[alias] == true then
            return true
        end
    end
    
    -- Also use traitIdsMatch for any baseline entries (catches edge cases)
    for storedTraitId, isBaseline in pairs(baseline) do
        if isBaseline and BurdJournals.traitIdsMatch(traitId, storedTraitId) then
            return true
        end
    end
    
    return false
end

function BurdJournals.getTraitBaseline(player)
    if not player then return {} end
    local cachedBaseline = getCachedBaselineFromServer(player)
    if cachedBaseline and type(cachedBaseline.traitBaseline) == "table" then
        return cachedBaseline.traitBaseline
    end
    local modData = player:getModData()
    if not modData.BurdJournals then return {} end
    return modData.BurdJournals.traitBaseline or {}
end

function BurdJournals.isStartingRecipe(player, recipeName)
    if not player then return false end
    if not recipeName then return false end
    local baseline = BurdJournals.getRecipeBaseline(player)
    if type(baseline) ~= "table" then return false end
    return baseline[recipeName] == true
end

function BurdJournals.getRecipeBaseline(player)
    if not player then return {} end
    local cachedBaseline = getCachedBaselineFromServer(player)
    if cachedBaseline and type(cachedBaseline.recipeBaseline) == "table" then
        return cachedBaseline.recipeBaseline
    end
    local modData = player:getModData()
    if not modData.BurdJournals then return {} end
    return modData.BurdJournals.recipeBaseline or {}
end

function BurdJournals.getEarnedXP(player, skillName)
    if not player then return 0 end
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then return 0 end

    local currentXP = player:getXp():getXP(perk)
    local baselineXP = BurdJournals.getSkillBaseline(player, skillName)

    return math.max(0, currentXP - baselineXP)
end

function BurdJournals.isBaselineRestrictionEnabled()
    return BurdJournals.getSandboxOption("EnableBaselineRestriction") ~= false
end

-- Check if baseline has been bypassed for this specific player (admin cleared it)
function BurdJournals.isBaselineBypassed(player)
    if not player then return false end
    local modData = player:getModData()
    if not modData.BurdJournals then return false end
    return modData.BurdJournals.baselineBypassed == true
end

-- Check if baseline restriction should be enforced for this specific player
-- Returns false if globally disabled OR if bypassed for this player
function BurdJournals.shouldEnforceBaseline(player)
    if not BurdJournals.isBaselineRestrictionEnabled() then
        return false
    end
    if BurdJournals.isBaselineBypassed(player) then
        return false
    end
    if player and BurdJournals.hasBaselineCaptured and not BurdJournals.hasBaselineCaptured(player) then
        return false
    end
    -- Debug baseline edits are synthetic test scaffolding and should not block
    -- recording/claiming flows with baseline restrictions.
    if player and player.getModData then
        local modData = player:getModData()
        if modData and modData.BurdJournals and modData.BurdJournals.debugModified == true then
            return false
        end
    end
    return true
end

-- Resolve which XP mode should be used when recording into a specific journal.
-- `true`  = baseline/delta mode (earned XP only)
-- `false` = absolute/set mode (total XP)
function BurdJournals.getJournalSkillRecordingMode(journalData, player)
    local defaultMode = BurdJournals.shouldEnforceBaseline and BurdJournals.shouldEnforceBaseline(player) or false
    if type(journalData) ~= "table" then
        return defaultMode
    end

    if journalData.recordedWithBaseline == true then
        return true
    end
    if journalData.recordedWithBaseline == false then
        return false
    end

    local hasSkills = BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(journalData.skills) or false
    local hasTraits = BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(journalData.traits) or false
    local hasRecipes = BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(journalData.recipes) or false

    -- Legacy journals created before `recordedWithBaseline` existed stored absolute XP.
    if hasSkills or hasTraits or hasRecipes then
        return false
    end

    return defaultMode
end

function BurdJournals.hasBaselineCaptured(player)
    if not player then return false end
    local cachedBaseline = getCachedBaselineFromServer(player)
    if cachedBaseline then
        return true
    end
    local modData = player:getModData()
    if not modData.BurdJournals then return false end
    return modData.BurdJournals.baselineCaptured == true
end

function BurdJournals.collectPlayerSkills(player)
    if not player then return {} end

    local skills = {}
    local allowedSkills = BurdJournals.getAllowedSkills()
    local useBaseline = BurdJournals.shouldEnforceBaseline(player)
    local playerJournalContext = { isPlayerCreated = true }

    for _, skillName in ipairs(allowedSkills) do
        local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(playerJournalContext, skillName)
        if enabledForJournal then
            local perk = BurdJournals.getPerkByName(skillName)
            if perk then
                local currentXP = player:getXp():getXP(perk)
                local level = player:getPerkLevel(perk)

                local recordXP = currentXP
                if useBaseline then
                    local baseline = BurdJournals.getSkillBaseline(player, skillName)
                    recordXP = math.max(0, currentXP - baseline)
                    
                    -- Fix for floating-point precision: If player is AT a level, ensure recorded XP
                    -- represents at least that many levels of progress from baseline.
                    -- This prevents "Level 9.999" situations when admin'ing exact levels.
                    if perk.getTotalXpForLevel and level > 0 then
                        local baselineLevel = BurdJournals.getSkillLevelFromXP(baseline, skillName)
                        local earnedLevels = level - baselineLevel
                        if earnedLevels > 0 then
                            -- Calculate minimum XP needed to go from baselineLevel to current level
                            -- This is (XP for target level) - (XP for baseline level)
                            local xpForTargetLevel = perk:getTotalXpForLevel(level) or 0
                            local xpForBaselineLevel = perk:getTotalXpForLevel(baselineLevel) or 0
                            local minEarnedXP = xpForTargetLevel - xpForBaselineLevel
                            if minEarnedXP > 0 and recordXP < minEarnedXP then
                                -- Bump up to exactly the threshold to avoid "almost Level X" display
                                recordXP = minEarnedXP
                            end
                        end
                    end
                end

                if recordXP > 0 then
                    skills[skillName] = {
                        xp = recordXP,
                        level = level
                    }
                end
            end
        end
    end

    return skills
end

local function traitTypeToName(traitType)
    if not traitType then return nil end
    if traitType.getName then
        local name = traitType:getName()
        if name and name ~= "" then
            return tostring(name)
        end
    end
    return tostring(traitType)
end

function BurdJournals.collectPlayerTraits(player, excludeStarting)
    if not player then return {} end

    if excludeStarting == nil then
        excludeStarting = BurdJournals.shouldEnforceBaseline(player)
    end

    local traits = {}

    local discoveredTraits = {}
    local discoveredTraitTypes = {}
    local discoveredLower = {}

    local function addDiscoveredTrait(rawTrait)
        if not rawTrait then
            return
        end

        local traitId = traitTypeToName(rawTrait)
        if not traitId then
            return
        end

        traitId = string.gsub(traitId, "^base:", "")
        if traitId == "" then
            return
        end

        local lower = string.lower(traitId)
        if discoveredLower[lower] then
            return
        end

        discoveredLower[lower] = true
        table.insert(discoveredTraits, traitId)
        discoveredTraitTypes[traitId] = rawTrait
    end

    local charTraits = player.getCharacterTraits and player:getCharacterTraits() or nil
    local knownTraits = charTraits and charTraits.getKnownTraits and charTraits:getKnownTraits() or nil
    if knownTraits and knownTraits.size and knownTraits.get then
        for i = 0, knownTraits:size() - 1 do
            addDiscoveredTrait(knownTraits:get(i))
        end
    end

    local runtimeTraits = player.getTraits and player:getTraits() or nil
    if runtimeTraits then
        if runtimeTraits.size and runtimeTraits.get then
            for i = 0, runtimeTraits:size() - 1 do
                addDiscoveredTrait(runtimeTraits:get(i))
            end
        elseif type(runtimeTraits) == "table" then
            for _, value in pairs(runtimeTraits) do
                addDiscoveredTrait(value)
            end
        end
    end

    if #discoveredTraits == 0 then
        return traits
    end

    local playerJournalContext = { isPlayerCreated = true }

    for i = 1, #discoveredTraits do
        local traitId = discoveredTraits[i]
        local traitType = discoveredTraitTypes[traitId]
        local traitDef = CharacterTraitDefinition
            and CharacterTraitDefinition.getCharacterTraitDefinition
            and traitType
            and CharacterTraitDefinition.getCharacterTraitDefinition(traitType)
            or nil

        if not (excludeStarting and BurdJournals.isStartingTrait(player, traitId))
            and (not BurdJournals.isTraitEnabledForJournal or BurdJournals.isTraitEnabledForJournal(playerJournalContext, traitId)) then
            local traitData = {
                name = traitId,
                cost = 0,
                isPositive = false
            }

            if traitDef then
                traitData.name = (traitDef.getLabel and traitDef:getLabel()) or traitId
                local cost = (traitDef.getCost and traitDef:getCost()) or 0
                traitData.cost = cost
                -- cost > 0 = positive trait, cost < 0 = negative trait
                traitData.isPositive = cost > 0
            end

            traits[traitId] = traitData
        end
    end

    return traits
end

function BurdJournals.collectCharacterInfo(player)
    if not player then return {} end

    local info = {}

    info.name = player:getUsername() or "Unknown"
    info.fullName = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname()

    local profession = player:getDescriptor():getProfession()
    if profession then
        info.profession = profession
        local professionData = ProfessionFactory.getProfession(profession)
        if professionData then
            info.professionName = professionData:getLabel() or profession
        else
            info.professionName = profession
        end
    end

    return info
end

function BurdJournals.collectAllPlayerData(player)
    if not player then return {} end

    return {
        skills = BurdJournals.collectPlayerSkills(player),
        traits = BurdJournals.collectPlayerTraits(player),
        recipes = BurdJournals.collectPlayerMagazineRecipes(player),
        character = BurdJournals.collectCharacterInfo(player),
        timestamp = getGameTime():getWorldAgeHours(),
        isPlayerCreated = true,
    }
end

function BurdJournals.playerHasTrait(player, traitIdOrObj)
    if not player then return false end
    if not traitIdOrObj then return false end

    local traitObj = nil
    local traitId = nil

    if type(traitIdOrObj) == "string" then
        traitId = traitIdOrObj
    else
        traitObj = traitIdOrObj
        -- Ensure we pass a CharacterTrait object when possible
        if instanceof and traitObj and not instanceof(traitObj, "CharacterTrait") then
            local name = nil
            if traitObj.getName then
                name = traitObj:getName()
            else
                name = tostring(traitObj)
            end
            if name and CharacterTrait and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
                traitObj = CharacterTrait.get(ResourceLocation.of(name))
            else
                traitObj = nil
            end
        end
    end

    if not traitObj and traitId then
        local traitIdLower = string.lower(traitId)
        local traitIdNorm = string.lower(traitId:gsub("%s", ""))

        if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
            local allTraits = CharacterTraitDefinition.getTraits()
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                local defType = def:getType()
                local defLabel = def:getLabel() or ""
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
                local defLabelNorm = defLabelLower:gsub("%s", "")
                local defNameNorm = defNameLower:gsub("%s", "")

                local exactMatch = (defLabel == traitId) or (defName == traitId)
                local lowerMatch = (defLabelLower == traitIdLower) or (defNameLower == traitIdLower)
                local normalizedMatch = (defLabelNorm == traitIdNorm) or (defNameNorm == traitIdNorm)

                if exactMatch or lowerMatch or normalizedMatch then
                    if defType and (not instanceof or instanceof(defType, "CharacterTrait")) then
                        traitObj = defType
                    elseif defName and CharacterTrait and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
                        traitObj = CharacterTrait.get(ResourceLocation.of(defName))
                    end
                    break
                end
            end
        end
    end

    if not traitObj and traitId and CharacterTrait then
        local lookups = {
            string.upper(traitId),
            traitId:gsub("(%u)", "_%1"):sub(2):upper(),
            traitId,
        }
        for _, key in ipairs(lookups) do
            if CharacterTrait[key] then
                local ct = CharacterTrait[key]
                if type(ct) == "string" and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
                    traitObj = CharacterTrait.get(ResourceLocation.of(ct))
                else
                    traitObj = ct
                end
                if traitObj then break end
            end
        end
    end

    if traitObj and player.hasTrait then
        return player:hasTrait(traitObj) == true
    end

    if traitId and type(player.HasTrait) == "function" then
        return player:HasTrait(traitId) == true
    end

    return false
end

function BurdJournals.isPlayerIlliterate(player)
    if not player then return false end
    return BurdJournals.playerHasTrait(player, "illiterate")
end

function BurdJournals.dumpAllTraits()

    if not CharacterTraitDefinition or not CharacterTraitDefinition.getTraits then

        return
    end

    local allTraits = CharacterTraitDefinition.getTraits()

    for i = 0, allTraits:size() - 1 do
        local def = allTraits:get(i)
        local defType = def:getType()
        local defLabel = def:getLabel() or "?"
        local defName = "?"

        if defType then
            defName = traitTypeToName(defType) or "?"
        end

        print(string.format("[BurdJournals] [%d] Label='%s' Name='%s' Type=%s", i, defLabel, defName, tostring(defType)))
    end

end

function BurdJournals.safeAddTrait(player, traitId)
    if not player or not traitId then return false end

    if BurdJournals.playerHasTrait(player, traitId) then

        return true
    end

    local traitObj = nil
    local traitDef = nil
    local traitIdLower = string.lower(traitId)

    local traitIdNorm = string.lower(traitId:gsub("%s", ""))

    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()

        for i = 0, allTraits:size() - 1 do
            local def = allTraits:get(i)
            local defType = def:getType()
            local defLabel = def:getLabel() or ""
            local defName = ""

            if defType then
                defName = traitTypeToName(defType) or ""
            end

            local defLabelLower = string.lower(defLabel)
            local defNameLower = string.lower(defName)

            local defLabelNorm = defLabelLower:gsub("%s", "")
            local defNameNorm = defNameLower:gsub("%s", "")

            local labelMatch = (defLabel == traitId)
            local nameMatch = (defName == traitId)
            local labelLowerMatch = (defLabelLower == traitIdLower)
            local nameLowerMatch = (defNameLower == traitIdLower)

            local normalizedMatch = (defLabelNorm == traitIdNorm) or (defNameNorm == traitIdNorm)

            if labelMatch or nameMatch or labelLowerMatch or nameLowerMatch or normalizedMatch then
                traitDef = def
                traitObj = defType
                break
            end
        end

    else

    end

    if not traitObj and CharacterTrait and CharacterTrait.get and ResourceLocation and ResourceLocation.of then

        local formats = {
            "base:" .. string.lower(traitId),
            "base:" .. string.lower(traitId:gsub("(%u)", "_%1"):sub(2)),
            "base:" .. string.lower(traitId:gsub("%s+", "")),
        }

        for _, resourceLoc in ipairs(formats) do
            local result = CharacterTrait.get(ResourceLocation.of(resourceLoc))
            if result then
                traitObj = result
                break
            end
        end
    end

    if not traitObj and CharacterTrait then
        local lookups = {
            string.upper(traitId),
            traitId:gsub("(%u)", "_%1"):sub(2):upper(),
            traitId,
        }

        for _, key in ipairs(lookups) do
            local ct = CharacterTrait[key]
            if ct then
                if type(ct) == "string" and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
                    local result = CharacterTrait.get(ResourceLocation.of(ct))
                    if result then
                        traitObj = result
                        break
                    end
                else
                    traitObj = ct
                    break
                end
            end
        end
    end

    if traitObj then
        local charTraits = player.getCharacterTraits and player:getCharacterTraits() or nil
        if not (charTraits and charTraits.add) then
            return false
        end

        charTraits:add(traitObj)

        local traitForBoost = traitDef and traitDef:getType() or traitObj
        if player.modifyTraitXPBoost then
            player:modifyTraitXPBoost(traitForBoost, false)
        end

        if traitDef and traitDef.getXpBoosts and transformIntoKahluaTable then
            local xpBoosts = transformIntoKahluaTable(traitDef:getXpBoosts())
            if type(xpBoosts) == "table" then
                for perk, level in pairs(xpBoosts) do
                    local perkId = tostring(perk)
                    local levelNum = tonumber(tostring(level))
                    if levelNum and levelNum > 0 then
                        local perkObj = Perks and Perks[perkId]
                        if perkObj and perkObj.getTotalXpForLevel then
                            local currentLevel = 0
                            if player.getPerkLevel then
                                currentLevel = player:getPerkLevel(perkObj) or 0
                            end

                            local targetLevel = math.min(currentLevel + levelNum, 10)
                            local targetXp = perkObj:getTotalXpForLevel(targetLevel)
                            local currentXp = player:getXp():getXP(perkObj) or 0
                            local xpToAdd = targetXp - currentXp
                            if xpToAdd > 0 then
                                player:getXp():AddXP(perkObj, xpToAdd, true, false, false)
                                print("[BurdJournals] Trait " .. traitId .. " granted +" .. levelNum .. " " .. perkId .. " (+" .. math.floor(xpToAdd) .. " XP)")
                            end
                        end
                    end
                end
            end
        end

        if SyncXp then
            SyncXp(player)
        end

        return true
    end

    return false
end

-- Safe trait removal for Build 42 (mirrors safeAddTrait approach)
function BurdJournals.safeRemoveTrait(player, traitId)
    if not player or not traitId then return false end

    if not BurdJournals.playerHasTrait(player, traitId) then
        -- Player doesn't have this trait
        return true
    end

    local traitObj = nil
    local traitDef = nil
    
    -- Build list of IDs to try (including aliases)
    local traitIdsToTry = {traitId, string.lower(traitId)}
    if BurdJournals.getTraitAliases then
        local aliases = BurdJournals.getTraitAliases(traitId)
        for _, alias in ipairs(aliases) do
            table.insert(traitIdsToTry, alias)
        end
    end

    -- First, try to find the trait through CharacterTraitDefinition
    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        for i = 0, allTraits:size() - 1 do
            if traitObj then break end
            local def = allTraits:get(i)
            local defType = def:getType()
            local defLabel = def:getLabel() or ""
            local defName = ""

            if defType then
                defName = traitTypeToName(defType) or ""
            end

            local defLabelLower = string.lower(defLabel)
            local defNameLower = string.lower(defName)
            local defLabelNorm = defLabelLower:gsub("%s", "")
            local defNameNorm = defNameLower:gsub("%s", "")

            -- Check all IDs including aliases
            for _, tryId in ipairs(traitIdsToTry) do
                local tryIdLower = string.lower(tryId)
                local tryIdNorm = tryIdLower:gsub("%s", "")
                
                local labelMatch = (defLabel == tryId)
                local nameMatch = (defName == tryId)
                local labelLowerMatch = (defLabelLower == tryIdLower)
                local nameLowerMatch = (defNameLower == tryIdLower)
                local normalizedMatch = (defLabelNorm == tryIdNorm) or (defNameNorm == tryIdNorm)

                if labelMatch or nameMatch or labelLowerMatch or nameLowerMatch or normalizedMatch then
                    -- Found a match - now verify player actually has THIS trait object
                    if BurdJournals.playerHasTrait(player, defType) then
                        traitDef = def
                        traitObj = defType
                        print("[BurdJournals] safeRemoveTrait: Found matching trait - label='" .. defLabel .. "' name='" .. defName .. "' (matched '" .. tryId .. "')")
                        break
                    end
                end
            end
        end
    end

    -- Try ResourceLocation approach (Build 42+)
    if not traitObj and CharacterTrait and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
        for _, tryId in ipairs(traitIdsToTry) do
            if traitObj then break end
            local formats = {
                "base:" .. string.lower(tryId),
                "base:" .. string.lower(tryId:gsub("(%u)", "_%1"):sub(2)),
                "base:" .. string.lower(tryId:gsub("%s+", "")),
            }
            for _, resourceLoc in ipairs(formats) do
                local result = CharacterTrait.get(ResourceLocation.of(resourceLoc))
                if result then
                    -- Verify player has this trait
                    if BurdJournals.playerHasTrait(player, result) then
                        traitObj = result
                        print("[BurdJournals] safeRemoveTrait: Found via ResourceLocation: " .. resourceLoc)
                        break
                    end
                end
            end
        end
    end

    -- Try CharacterTrait enum lookup
    if not traitObj and CharacterTrait then
        for _, tryId in ipairs(traitIdsToTry) do
            if traitObj then break end
            local lookups = {
                string.upper(tryId),
                tryId:gsub("(%u)", "_%1"):sub(2):upper(),
                tryId,
            }
            for _, key in ipairs(lookups) do
                local ct = CharacterTrait[key]
                if ct then
                    local resolvedTrait = ct
                    if type(ct) == "string" and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
                        local result = CharacterTrait.get(ResourceLocation.of(ct))
                        if result then
                            resolvedTrait = result
                        end
                    end
                    -- Verify player has this trait
                    if BurdJournals.playerHasTrait(player, resolvedTrait) then
                        traitObj = resolvedTrait
                        print("[BurdJournals] safeRemoveTrait: Found via enum: " .. key)
                        break
                    end
                end
            end
        end
    end

    if traitObj then
        local charTraits = player.getCharacterTraits and player:getCharacterTraits() or nil
        if not charTraits then
            print("[BurdJournals] safeRemoveTrait: Failed to remove trait " .. traitId .. " (characterTraits unavailable)")
            return false
        end

        if charTraits.remove then
            pcall(function()
                charTraits:remove(traitObj)
            end)
        end
        if charTraits.set then
            pcall(function()
                charTraits:set(traitObj, false)
            end)
        end

        local removed = not BurdJournals.playerHasTrait(player, traitObj)
        if removed and BurdJournals.playerHasTrait(player, traitId) then
            removed = false
        end

        if removed then
            local traitForBoost = traitDef and traitDef.getType and traitDef:getType() or traitObj
            if player.modifyTraitXPBoost and traitForBoost then
                pcall(function()
                    player:modifyTraitXPBoost(traitForBoost, true)
                end)
            end
            if SyncXp then
                pcall(function()
                    SyncXp(player)
                end)
            end
            print("[BurdJournals] safeRemoveTrait: Successfully removed trait " .. traitId)
            return true
        end

        print("[BurdJournals] safeRemoveTrait: Trait removal verification failed for " .. traitId)
        return false
    end

    print("[BurdJournals] safeRemoveTrait: Could not resolve trait object for " .. traitId .. " (tried " .. #traitIdsToTry .. " variants)")
    return false
end

function BurdJournals.isTraitRemovable(traitId)
    if not traitId then return false end
    local candidate = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(traitId) or tostring(traitId)
    local candidateLower = string.lower(tostring(candidate))

    local removableTraits = BurdJournals.REMOVABLE_TRAITS or {}
    for _, listedTrait in ipairs(removableTraits) do
        local listedId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(listedTrait) or tostring(listedTrait)
        if string.lower(tostring(listedId)) == candidateLower then
            return true
        end
    end
    return false
end

function BurdJournals.getPlayerRemovableTraits(player)
    local removable = {}
    if not player then return removable end

    local removableTraits = BurdJournals.REMOVABLE_TRAITS or {}
    for _, traitId in ipairs(removableTraits) do
        if BurdJournals.playerHasTrait(player, traitId) then
            removable[#removable + 1] = traitId
        end
    end

    return removable
end

-- Returns trait IDs that conflict with traitId and are currently on the player.
function BurdJournals.getConflictingTraits(player, traitId)
    local conflicts = {}
    if not player or not traitId then return conflicts end

    if not (CharacterTraitDefinition and CharacterTraitDefinition.getTraits) then
        return conflicts
    end

    local traitIdNorm = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(traitId) or tostring(traitId)
    local traitIdLower = string.lower(tostring(traitIdNorm))

    local function tryResolveDefinition()
        local allTraits = CharacterTraitDefinition.getTraits()
        if not allTraits or not allTraits.size or not allTraits.get then
            return nil
        end

        for i = 0, allTraits:size() - 1 do
            local def = allTraits:get(i)
            if def then
                local defType = def:getType()
                local defName = defType and (traitTypeToName(defType) or tostring(defType)) or ""
                local defNameNorm = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(defName) or defName
                local defLabelNorm = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(def:getLabel() or "") or (def:getLabel() or "")
                if string.lower(tostring(defNameNorm)) == traitIdLower
                    or string.lower(tostring(defLabelNorm)) == traitIdLower then
                    return def
                end
            end
        end
        return nil
    end

    local traitDef = tryResolveDefinition()
    if not traitDef then
        return conflicts
    end

    local exclusives = traitDef.getMutuallyExclusiveTraits and traitDef:getMutuallyExclusiveTraits() or nil
    if not (exclusives and exclusives.size and exclusives.get) then
        return conflicts
    end

    local seen = {}
    for i = 0, exclusives:size() - 1 do
        local exTrait = exclusives:get(i)
        if exTrait then
            local exId = traitTypeToName(exTrait) or tostring(exTrait)
            exId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(exId) or exId
            local exLower = string.lower(tostring(exId))
            if not seen[exLower] and BurdJournals.playerHasTrait(player, exId) then
                seen[exLower] = true
                conflicts[#conflicts + 1] = exId
            end
        end
    end

    return conflicts
end

BurdJournals._magazineRecipeCache = nil

local function hasLearnedRecipes(learnedRecipes)
    if not learnedRecipes then return false end
    if learnedRecipes.isEmpty then
        return not learnedRecipes:isEmpty()
    end
    if learnedRecipes.size then
        return learnedRecipes:size() > 0
    end
    return false
end

function BurdJournals.buildMagazineRecipeCache(forceRefresh)
    if not forceRefresh and BurdJournals._magazineRecipeCache then
        return BurdJournals._magazineRecipeCache
    end

    local cache = {}

    local modRecipes = BurdJournals.getModRegisteredRecipes()
    for recipeName, magazineType in pairs(modRecipes) do
        if not BurdJournals.isRecipeExcluded(recipeName) then
            cache[recipeName] = magazineType
            print("[BurdJournals] Added mod-registered recipe: " .. recipeName)
        end
    end

    local scriptManager = getScriptManager and getScriptManager() or nil
    if not scriptManager then
        print("[BurdJournals] buildMagazineRecipeCache: no scriptManager")
    else
        local allItems = scriptManager:getAllItems()
        if not (allItems and allItems.size and allItems.get) then
            print("[BurdJournals] buildMagazineRecipeCache: no allItems")
        else
            print("[BurdJournals] buildMagazineRecipeCache: scanning " .. allItems:size() .. " items (including mods)")

            for i = 0, allItems:size() - 1 do
                local script = allItems:get(i)
                if script and script.getLearnedRecipes and script.getFullName then
                    local learnedRecipes = script:getLearnedRecipes()
                    if hasLearnedRecipes(learnedRecipes) and learnedRecipes.size and learnedRecipes.get then
                        local fullType = script:getFullName()
                        print("[BurdJournals] Found magazine with recipes: " .. tostring(fullType))
                        for j = 0, learnedRecipes:size() - 1 do
                            local recipeName = learnedRecipes:get(j)
                            if recipeName then
                                if BurdJournals.isRecipeExcluded(recipeName) then
                                    print("[BurdJournals]   - Recipe (EXCLUDED): " .. tostring(recipeName))
                                else
                                    print("[BurdJournals]   - Recipe: " .. tostring(recipeName))
                                    if not cache[recipeName] then
                                        cache[recipeName] = fullType
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    BurdJournals._magazineRecipeCache = cache
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    print("[BurdJournals] Cached " .. count .. " magazine recipes (including mod-registered)")

    return cache
end

function BurdJournals.isMagazineRecipe(recipeName)
    local cache = BurdJournals.buildMagazineRecipeCache()
    return cache[recipeName] ~= nil
end

function BurdJournals.getMagazineForRecipe(recipeName)
    local cache = BurdJournals.buildMagazineRecipeCache()
    return cache[recipeName]
end

function BurdJournals.buildMagazineToRecipesCache(forceRefresh)
    if not forceRefresh and BurdJournals._magazineToRecipesCache then
        return BurdJournals._magazineToRecipesCache
    end

    local cache = {}

    local modMagazines = BurdJournals.getModRegisteredMagazines()
    for magazineType, recipes in pairs(modMagazines) do
        local recipeList = {}
        for _, recipeName in ipairs(recipes) do
            if not BurdJournals.isRecipeExcluded(recipeName) then
                table.insert(recipeList, recipeName)
            end
        end
        if #recipeList > 0 then
            cache[magazineType] = recipeList
        end
    end

    local scriptManager = getScriptManager and getScriptManager() or nil
    if scriptManager then
        local allItems = scriptManager:getAllItems()
        if allItems and allItems.size and allItems.get then
            for i = 0, allItems:size() - 1 do
                local script = allItems:get(i)
                if script and script.getLearnedRecipes and script.getFullName then
                    local learnedRecipes = script:getLearnedRecipes()
                    if hasLearnedRecipes(learnedRecipes) and learnedRecipes.size and learnedRecipes.get then
                        local fullType = script:getFullName()
                        local recipeList = cache[fullType] or {}
                        for j = 0, learnedRecipes:size() - 1 do
                            local recipeName = learnedRecipes:get(j)
                            if recipeName and not BurdJournals.isRecipeExcluded(recipeName) then
                                local isDupe = false
                                for _, existing in ipairs(recipeList) do
                                    if existing == recipeName then
                                        isDupe = true
                                        break
                                    end
                                end
                                if not isDupe then
                                    table.insert(recipeList, recipeName)
                                end
                            end
                        end
                        if #recipeList > 0 then
                            cache[fullType] = recipeList
                        end
                    end
                end
            end
        end
    end

    BurdJournals._magazineToRecipesCache = cache
    return cache
end

-- Normalize Java/Lua list-like object to string array for recipe checks.
local function listToStringArray(listObj)
    if not listObj then return nil end

    if type(listObj) == "table" then
        local out = {}
        if listObj[1] ~= nil then
            for i = 1, #listObj do
                local value = listObj[i]
                if value ~= nil then
                    table.insert(out, tostring(value))
                end
            end
        else
            for _, value in pairs(listObj) do
                if value ~= nil then
                    table.insert(out, tostring(value))
                end
            end
        end
        return out
    end

    if listObj.size and listObj.get then
        local out = {}
        local count = listObj:size()
        for i = 0, count - 1 do
            local value = listObj:get(i)
            if value ~= nil then
                table.insert(out, tostring(value))
            end
        end
        return out
    end

    return nil
end

local function arrayToSet(arr)
    local set = {}
    if not arr then return set end
    for i = 1, #arr do
        set[arr[i]] = true
    end
    return set
end

local function listContainsString(listObj, value)
    if not listObj or value == nil then return false end

    if listObj.contains and listObj:contains(value) then
        return true
    end

    local arr = listToStringArray(listObj)
    if not arr then return false end

    local wanted = tostring(value)
    for i = 1, #arr do
        if arr[i] == wanted then
            return true
        end
    end
    return false
end

function BurdJournals.collectPlayerMagazineRecipes(player, excludeStarting, includeAllKnownWhenCapture)
    if not player then
        BurdJournals.debugPrint("[BurdJournals] collectPlayerMagazineRecipes: no player")
        return {}
    end

    if not BurdJournals.isRecipeRecordingEnabled() then
        BurdJournals.debugPrint("[BurdJournals] collectPlayerMagazineRecipes: recipe recording disabled")
        return {}
    end

    if excludeStarting == nil then
        excludeStarting = BurdJournals.shouldEnforceBaseline(player)
    end

    local recipes = {}

    local magToRecipes = BurdJournals.buildMagazineToRecipesCache()
    local recipeToMag = BurdJournals.buildMagazineRecipeCache()

    local magCount = 0
    for _ in pairs(magToRecipes) do magCount = magCount + 1 end
    BurdJournals.debugPrint("[BurdJournals] collectPlayerMagazineRecipes: checking " .. magCount .. " magazine types")

    local seeNotLearnt = (SandboxVars and SandboxVars.SeeNotLearntRecipe) and true or false

    local knownRecipesList = player.getKnownRecipes and player:getKnownRecipes() or nil
    local knownRecipesArray = listToStringArray(knownRecipesList) or {}
    local knownRecipesSet = arrayToSet(knownRecipesArray)

    local readBooksList = player.getAlreadyReadBook and player:getAlreadyReadBook() or nil
    local readBooksArray = listToStringArray(readBooksList) or {}
    local readBooksSet = arrayToSet(readBooksArray)

    -- Method 1: Using isRecipeKnown() - SKIP if SeeNotLearntRecipe is enabled
    -- because it will return true for ALL recipes, not just learned ones
    BurdJournals.debugPrint("[BurdJournals] Method 1: Using isRecipeKnown() for each magazine recipe...")
    local method1Count = 0

    if seeNotLearnt then
        BurdJournals.debugPrint("[BurdJournals] Method 1: SKIPPED - SeeNotLearntRecipe is enabled (returns true for all recipes)")
    elseif player.isRecipeKnown then
        for _, recipeList in pairs(magToRecipes) do
            for _, recipeName in ipairs(recipeList) do
                if not recipes[recipeName] and player:isRecipeKnown(recipeName) then
                    method1Count = method1Count + 1
                    recipes[recipeName] = true
                end
            end
        end
        BurdJournals.debugPrint("[BurdJournals] Method 1 (isRecipeKnown): found " .. method1Count .. " known recipes")
    else
        BurdJournals.debugPrint("[BurdJournals] Method 1: isRecipeKnown not available, skipping")
    end

    -- Method 2: getAlreadyReadPages per magazine
    BurdJournals.debugPrint("[BurdJournals] Method 2: Checking getAlreadyReadPages for each magazine...")
    local method2Count = 0
    if player.getAlreadyReadPages then
        for magazineType, recipeList in pairs(magToRecipes) do
            local pagesRead = player:getAlreadyReadPages(magazineType) or 0
            if pagesRead > 0 then
                for _, recipeName in ipairs(recipeList) do
                    if not recipes[recipeName] then
                        method2Count = method2Count + 1
                        recipes[recipeName] = true
                    end
                end
            end
        end
    end
    BurdJournals.debugPrint("[BurdJournals] Method 2 (getAlreadyReadPages): found " .. method2Count .. " additional recipes")

    -- Method 3: already-read books list
    BurdJournals.debugPrint("[BurdJournals] Method 3: Checking getAlreadyReadBook list...")
    local method3Count = 0
    if #readBooksArray > 0 then
        BurdJournals.debugPrint("[BurdJournals] Method 3: player has " .. #readBooksArray .. " items in getAlreadyReadBook")
        for i = 1, #readBooksArray do
            local recipeList = magToRecipes[readBooksArray[i]]
            if recipeList then
                for _, recipeName in ipairs(recipeList) do
                    if not recipes[recipeName] then
                        method3Count = method3Count + 1
                        recipes[recipeName] = true
                    end
                end
            end
        end
    else
        BurdJournals.debugPrint("[BurdJournals] Method 3: getAlreadyReadBook returned nil/empty")
    end
    BurdJournals.debugPrint("[BurdJournals] Method 3 (getAlreadyReadBook): found " .. method3Count .. " additional recipes")

    -- Method 4: known recipes list
    BurdJournals.debugPrint("[BurdJournals] Method 4: Checking getKnownRecipes...")
    local method4Count = 0
    if #knownRecipesArray > 0 then
        BurdJournals.debugPrint("[BurdJournals] Method 4: player has " .. #knownRecipesArray .. " items in getKnownRecipes")
        local debugLimit = math.min(#knownRecipesArray, 5)
        for i = 1, debugLimit do
            BurdJournals.debugPrint("[BurdJournals] Method 4 sample[" .. tostring(i - 1) .. "]: " .. tostring(knownRecipesArray[i]))
        end
        for i = 1, #knownRecipesArray do
            local recipeName = knownRecipesArray[i]
            local magazineType = recipeToMag[recipeName]
            if magazineType and not recipes[recipeName] then
                method4Count = method4Count + 1
                recipes[recipeName] = true
            end
        end
    else
        BurdJournals.debugPrint("[BurdJournals] Method 4: getKnownRecipes returned nil/empty")
    end
    BurdJournals.debugPrint("[BurdJournals] Method 4 (getKnownRecipes): found " .. method4Count .. " additional recipes")

    -- Method 5: Catch modded recipes not in our cache by checking needToBeLearn flag
    BurdJournals.debugPrint("[BurdJournals] Method 5: Checking needToBeLearn recipes not in cache...")
    local method5Count = 0
    local scriptManager = getScriptManager and getScriptManager() or nil
    if scriptManager and #knownRecipesArray > 0 then
        for i = 1, #knownRecipesArray do
            local recipeName = knownRecipesArray[i]
            if not recipes[recipeName] then
                local recipeScript = scriptManager:getRecipe(recipeName)
                local needsLearning = recipeScript and recipeScript.needToBeLearn and recipeScript:needToBeLearn()
                if needsLearning then
                    method5Count = method5Count + 1
                    recipes[recipeName] = true
                    BurdJournals.debugPrint("[BurdJournals] Method 5: Added '" .. recipeName .. "' (needToBeLearn but not in magazine cache)")
                end
            end
        end
    end
    BurdJournals.debugPrint("[BurdJournals] Method 5 (needToBeLearn fallback): found " .. method5Count .. " additional recipes")

    -- Method 6: Baseline snapshot mode - include any remaining known recipes.
    -- This catches custom-trait/profession recipes that may not appear in
    -- magazine caches or script metadata at spawn time.
    local method6Count = 0
    if includeAllKnownWhenCapture and not excludeStarting and #knownRecipesArray > 0 then
        for i = 1, #knownRecipesArray do
            local recipeName = knownRecipesArray[i]
            if recipeName and recipeName ~= "" and not recipes[recipeName] then
                recipes[recipeName] = true
                method6Count = method6Count + 1
            end
        end
    end
    BurdJournals.debugPrint("[BurdJournals] Method 6 (baseline include known recipes): found " .. method6Count .. " additional recipes")

    local foundCount = 0
    for _ in pairs(recipes) do foundCount = foundCount + 1 end
    BurdJournals.debugPrint("[BurdJournals] collectPlayerMagazineRecipes: TOTAL found " .. foundCount .. " magazine recipes known by player")

    -- Diagnostic output (always print if zero recipes found to help debug)
    if foundCount == 0 then
        print("[BurdJournals] WARNING: No magazine recipes detected! magCount=" .. magCount .. " excludeStarting=" .. tostring(excludeStarting))
        -- Check getKnownRecipes directly
        local knownCount = 0
        if player and player.getKnownRecipes then
            local known = player:getKnownRecipes()
            if known and known.size then
                knownCount = known:size()
            end
        end
        print("[BurdJournals] Player has " .. knownCount .. " total known recipes (from getKnownRecipes)")
    end

    if excludeStarting then
        local filteredRecipes = {}
        local excludedCount = 0
        for recipeName, _ in pairs(recipes) do
            if BurdJournals.isStartingRecipe(player, recipeName) then
                excludedCount = excludedCount + 1
            else
                filteredRecipes[recipeName] = true
            end
        end
        if excludedCount > 0 then
            BurdJournals.debugPrint("[BurdJournals] collectPlayerMagazineRecipes: Excluded " .. excludedCount .. " starting recipes from baseline")
        end
        -- Also warn if all recipes were excluded
        local resultCount = 0
        for _ in pairs(filteredRecipes) do resultCount = resultCount + 1 end
        if foundCount > 0 and resultCount == 0 then
            print("[BurdJournals] WARNING: All " .. foundCount .. " recipes were excluded by baseline! Check recipeBaseline data.")
        end
        return filteredRecipes
    end

    return recipes
end

function BurdJournals.playerKnowsRecipe(player, recipeName)
    if not player or not recipeName then return false end

    local DEBUG_RECIPE_CHECK = false

    -- Check if SeeNotLearntRecipe sandbox option is enabled
    -- When enabled, isRecipeKnown() returns true for ALL recipes, making it useless.
    local seeNotLearnt = (SandboxVars and SandboxVars.SeeNotLearntRecipe) and true or false

    -- Skip isRecipeKnown() if SeeNotLearntRecipe is enabled - it returns true for everything.
    if not seeNotLearnt and player.isRecipeKnown then
        if player:isRecipeKnown(recipeName) then
            if DEBUG_RECIPE_CHECK then
                print("[BurdJournals DEBUG] playerKnowsRecipe(" .. recipeName .. ") -> TRUE via isRecipeKnown()")
            end
            return true
        end
    end

    local knownRecipes = player.getKnownRecipes and player:getKnownRecipes() or nil
    if knownRecipes then
        if knownRecipes.contains and knownRecipes:contains(recipeName) then
            if DEBUG_RECIPE_CHECK then
                print("[BurdJournals DEBUG] playerKnowsRecipe(" .. recipeName .. ") -> TRUE via getKnownRecipes():contains()")
            end
            return true
        end

        local knownRecipesArray = listToStringArray(knownRecipes)
        if knownRecipesArray then
            for i = 1, #knownRecipesArray do
                if knownRecipesArray[i] == recipeName then
                    if DEBUG_RECIPE_CHECK then
                        print("[BurdJournals DEBUG] playerKnowsRecipe(" .. recipeName .. ") -> TRUE via getKnownRecipes() iteration")
                    end
                    return true
                end
            end
        end
    end

    local magazineType = BurdJournals.getMagazineForRecipe(recipeName)
    if magazineType then
        if player.getAlreadyReadPages then
            local pagesRead = player:getAlreadyReadPages(magazineType) or 0
            if pagesRead > 0 then
                if DEBUG_RECIPE_CHECK then
                    print("[BurdJournals DEBUG] playerKnowsRecipe(" .. recipeName .. ") -> TRUE via getAlreadyReadPages(" .. magazineType .. ")=" .. pagesRead)
                end
                return true
            end
        end

        local readBooks = player.getAlreadyReadBook and player:getAlreadyReadBook() or nil
        if listContainsString(readBooks, magazineType) then
            if DEBUG_RECIPE_CHECK then
                print("[BurdJournals DEBUG] playerKnowsRecipe(" .. recipeName .. ") -> TRUE via getAlreadyReadBook contains " .. magazineType)
            end
            return true
        end
    end

    if DEBUG_RECIPE_CHECK then
        print("[BurdJournals DEBUG] playerKnowsRecipe(" .. recipeName .. ") -> FALSE (no method returned true)")
    end
    return false
end

local function getAllRecipesList()
    local recipes = getAllRecipes and getAllRecipes() or nil
    if not recipes or not recipes.size or not recipes.get then
        return nil, 0
    end
    return recipes, recipes:size() or 0
end

function BurdJournals.validateRecipeName(recipeName)
    if type(recipeName) ~= "string" or recipeName == "" then return nil end

    local recipes, recipeCount = getAllRecipesList()
    if not recipes or recipeCount <= 0 then return nil end

    for i = 0, recipeCount - 1 do
        local recipe = recipes:get(i)
        if recipe and recipe.getName then
            local name = recipe:getName()
            if name == recipeName then
                return name
            end
        end
    end

    local recipeNameLower = string.lower(recipeName)
    for i = 0, recipeCount - 1 do
        local recipe = recipes:get(i)
        if recipe and recipe.getName then
            local name = recipe:getName()
            if name and string.lower(name) == recipeNameLower then
                return name
            end
        end
    end

    return nil
end

function BurdJournals.getRecipeByName(recipeName)
    if type(recipeName) ~= "string" or recipeName == "" then return nil end

    local recipes, recipeCount = getAllRecipesList()
    if not recipes or recipeCount <= 0 then return nil end

    for i = 0, recipeCount - 1 do
        local recipe = recipes:get(i)
        if recipe and recipe.getName and recipe:getName() == recipeName then
            return recipe
        end
    end
    return nil
end

function BurdJournals.learnRecipeWithVerification(player, recipeName, logPrefix)
    if not player or not recipeName then return false end
    logPrefix = logPrefix or "[BurdJournals]"

    if BurdJournals.playerKnowsRecipe(player, recipeName) then
        print(logPrefix .. " Recipe already known: " .. recipeName)
        return true
    end

    local validatedName = BurdJournals.validateRecipeName(recipeName)
    if not validatedName then
        print(logPrefix .. " WARNING: Recipe '" .. recipeName .. "' not found in game recipes!")
    elseif validatedName ~= recipeName then
        print(logPrefix .. " Recipe name corrected: '" .. recipeName .. "' -> '" .. validatedName .. "'")
        recipeName = validatedName
    end

    local learned = false

    if validatedName and player.learnRecipe then
        player:learnRecipe(recipeName)
        if BurdJournals.playerKnowsRecipe(player, recipeName) then
            print(logPrefix .. " Learned recipe via learnRecipe(): " .. recipeName)
            learned = true
        end
    end

    if not learned then
        local magazineType = BurdJournals.getMagazineForRecipe(recipeName)
        if magazineType then
            print(logPrefix .. " Trying magazine method for: " .. recipeName .. " (magazine: " .. magazineType .. ")")

            local pageCount = 1
            local scriptManager = getScriptManager and getScriptManager() or nil
            if scriptManager and scriptManager.getItem then
                local script = scriptManager:getItem(magazineType)
                if script and script.getPageToLearn then
                    pageCount = script:getPageToLearn() or 1
                end
            end

            if player.setAlreadyReadPages then
                player:setAlreadyReadPages(magazineType, pageCount)
                print(logPrefix .. " Set " .. pageCount .. " pages read for magazine: " .. magazineType)
            end

            local readBooks = player.getAlreadyReadBook and player:getAlreadyReadBook() or nil
            if readBooks and readBooks.add and not listContainsString(readBooks, magazineType) then
                readBooks:add(magazineType)
                print(logPrefix .. " Added magazine to read books: " .. magazineType)
            end

            if BurdJournals.playerKnowsRecipe(player, recipeName) then
                print(logPrefix .. " Learned recipe via magazine system: " .. recipeName)
                learned = true
            end
        end
    end

    if not learned then
        print(logPrefix .. " FAILED to learn recipe: " .. recipeName)
    end

    return learned
end

function BurdJournals.debugRecipeSystem(player)
    if not player then
        print("[BurdJournals DEBUG] No player provided")
        return
    end

    BurdJournals.debugPrint("==================== RECIPE SYSTEM DEBUG ====================")

    print("\n[API Availability]")
    print("  player.isRecipeKnown: " .. tostring(player.isRecipeKnown ~= nil))
    print("  player.learnRecipe: " .. tostring(player.learnRecipe ~= nil))
    print("  player.getKnownRecipes: " .. tostring(player.getKnownRecipes ~= nil))
    print("  player.getAlreadyReadPages: " .. tostring(player.getAlreadyReadPages ~= nil))
    print("  player.setAlreadyReadPages: " .. tostring(player.setAlreadyReadPages ~= nil))
    print("  player.getAlreadyReadBook: " .. tostring(player.getAlreadyReadBook ~= nil))

    print("\n[getKnownRecipes Test]")
    local knownRecipes = player.getKnownRecipes and player:getKnownRecipes() or nil
    local knownRecipeArray = listToStringArray(knownRecipes) or {}
    print("  Count: " .. tostring(#knownRecipeArray))
    if #knownRecipeArray > 0 and #knownRecipeArray <= 10 then
        print("  First few recipes:")
        for i = 1, math.min(#knownRecipeArray, 5) do
            print("    - " .. tostring(knownRecipeArray[i]))
        end
    elseif #knownRecipeArray > 10 then
        print("  (Showing first 5 of " .. #knownRecipeArray .. " recipes)")
        for i = 1, 5 do
            print("    - " .. tostring(knownRecipeArray[i]))
        end
    end

    print("\n[getAlreadyReadBook Test]")
    local readBooks = player.getAlreadyReadBook and player:getAlreadyReadBook() or nil
    local readBookArray = listToStringArray(readBooks) or {}
    print("  Count: " .. tostring(#readBookArray))
    if #readBookArray > 0 and #readBookArray <= 20 then
        print("  Read books/magazines:")
        for i = 1, #readBookArray do
            print("    - " .. tostring(readBookArray[i]))
        end
    elseif #readBookArray > 20 then
        print("  (Showing first 10 of " .. #readBookArray .. " items)")
        for i = 1, 10 do
            print("    - " .. tostring(readBookArray[i]))
        end
    end

    print("\n[Magazine Recipe Cache]")
    local magToRecipes = BurdJournals.buildMagazineToRecipesCache()
    local magCount = 0
    for _ in pairs(magToRecipes) do magCount = magCount + 1 end
    print("  Total magazine types: " .. magCount)

    local sampleCount = 0
    for magType, recipes in pairs(magToRecipes) do
        if sampleCount < 3 then
            print("  " .. magType .. ": " .. #recipes .. " recipes")
            sampleCount = sampleCount + 1
        end
    end

    print("\n[Testing Sample Recipe Check]")

    for magType, recipes in pairs(magToRecipes) do
        if #recipes > 0 then
            local testRecipe = recipes[1]
            print("  Testing: " .. testRecipe .. " (from " .. magType .. ")")

            if player.isRecipeKnown then
                print("    isRecipeKnown: " .. tostring(player:isRecipeKnown(testRecipe)))
            end

            local ourCheck = BurdJournals.playerKnowsRecipe(player, testRecipe)
            print("    playerKnowsRecipe: " .. tostring(ourCheck))

            local pagesRead = 0
            if player.getAlreadyReadPages then
                pagesRead = player:getAlreadyReadPages(magType) or 0
            end
            print("    getAlreadyReadPages(" .. magType .. "): " .. pagesRead)

            break
        end
    end

    print("\n[Recipe Recording Status]")
    local enableRecording = BurdJournals.isRecipeRecordingEnabled()
    print("  EnableRecipeRecordingPlayer sandbox option: " .. tostring(enableRecording))

    local collectedRecipes = BurdJournals.collectPlayerMagazineRecipes(player)
    local collectedCount = 0
    for _ in pairs(collectedRecipes) do collectedCount = collectedCount + 1 end
    print("  Total magazine recipes player knows: " .. collectedCount)

    BurdJournals.debugPrint("==================== END DEBUG ====================")
end

function BurdJournals.getRecipeDisplayName(recipeName)
    if not recipeName then return "Unknown Recipe" end

    local recipes, recipeCount = getAllRecipesList()
    if recipes and recipeCount > 0 then
        for i = 0, recipeCount - 1 do
            local recipe = recipes:get(i)
            if recipe and recipe.getName and recipe:getName() == recipeName then
                if recipe.getOriginalname then
                    local origName = recipe:getOriginalname()
                    if origName and origName ~= "" and origName ~= recipeName then
                        return origName
                    end
                end
                break
            end
        end
    end

    return BurdJournals.normalizeRecipeName(recipeName)
end

function BurdJournals.normalizeRecipeName(recipeName)
    if not recipeName then return "Unknown Recipe" end

    local displayName = recipeName

    displayName = displayName:gsub("_", " ")

    displayName = displayName:gsub("(%l)(%u)", "%1 %2")

    displayName = displayName:gsub("([%a])(%d)", "%1 %2")

    displayName = displayName:gsub("([Vv]) (%d+)", "%1%2")
    displayName = displayName:gsub("([Vv]ol) (%d+)", "%1%2")
    displayName = displayName:gsub("([Vv]ol)(%d+)", "Vol.%2")

    displayName = displayName:gsub(" To ", " to ")
    displayName = displayName:gsub(" From ", " from ")
    displayName = displayName:gsub(" With ", " with ")
    displayName = displayName:gsub(" And ", " and ")
    displayName = displayName:gsub(" Or ", " or ")
    displayName = displayName:gsub(" For ", " for ")
    displayName = displayName:gsub(" Of ", " of ")
    displayName = displayName:gsub(" In ", " in ")
    displayName = displayName:gsub(" On ", " on ")
    displayName = displayName:gsub(" At ", " at ")
    displayName = displayName:gsub(" By ", " by ")
    displayName = displayName:gsub(" The ", " the ")
    displayName = displayName:gsub(" A ", " a ")
    displayName = displayName:gsub(" An ", " an ")

    displayName = displayName:gsub("^%l", string.upper)

    displayName = displayName:gsub("%s+", " ")

    displayName = displayName:match("^%s*(.-)%s*$")

    return displayName
end

function BurdJournals.getMagazineDisplayName(magazineType)
    if not magazineType then return "Unknown Magazine" end

    local scriptManager = getScriptManager and getScriptManager() or nil
    if scriptManager and scriptManager.getItem then
        local script = scriptManager:getItem(magazineType)
        if script and script.getDisplayName then
            local displayName = script:getDisplayName()
            if displayName and displayName ~= "" then
                return displayName
            end
        end
    end

    local fallback = magazineType

    if fallback:find("%.") then
        fallback = fallback:match("%.(.+)") or fallback
    end

    fallback = fallback:gsub("(%l)(%u)", "%1 %2")
    fallback = fallback:gsub("(%a)(%d)", "%1 %2")
    return fallback
end

function BurdJournals.getClaimedRecipes(item)
    if not item then return {} end
    local data = getItemJournalModData(item)
    if data and data.claimedRecipes then
        return data.claimedRecipes
    end
    return {}
end

function BurdJournals.isRecipeClaimed(item, recipeName)
    local claimed = BurdJournals.getClaimedRecipes(item)
    return claimed[recipeName] == true
end

function BurdJournals.claimRecipe(item, recipeName)
    if not item then return false end
    local modData = getItemModData(item)
    if not modData then return false end
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    if not modData.BurdJournals.claimedRecipes then
        modData.BurdJournals.claimedRecipes = {}
    end
    modData.BurdJournals.claimedRecipes[recipeName] = true
    return true
end

function BurdJournals.getUnclaimedRecipes(item, player)
    if not item then return {} end
    local data = BurdJournals.getJournalData(item)
    if not data or not data.recipes then return {} end

    local unclaimed = {}

    for recipeName, recipeData in pairs(data.recipes) do
        -- Use per-character claims if player provided, otherwise global
        local isClaimed = false
        if player then
            isClaimed = BurdJournals.hasCharacterClaimedRecipe(data, player, recipeName)
        else
            local claimed = BurdJournals.getClaimedRecipes(item)
            isClaimed = claimed[recipeName]
        end
        if not isClaimed then
            unclaimed[recipeName] = recipeData
        end
    end

    return unclaimed
end

function BurdJournals.getUnclaimedRecipeCount(item, player)
    local unclaimed = BurdJournals.getUnclaimedRecipes(item, player)
    return BurdJournals.countTable(unclaimed)
end

function BurdJournals.getTotalRecipeCount(item)
    if not item then return 0 end
    local data = BurdJournals.getJournalData(item)
    if not data or not data.recipes then return 0 end
    return BurdJournals.countTable(data.recipes)
end

function BurdJournals.getAllMagazineRecipes()
    BurdJournals.debugPrint("[BurdJournals] getAllMagazineRecipes called (isServer=" .. tostring(isServer()) .. ", isClient=" .. tostring(isClient()) .. ")")
    local cache = BurdJournals.buildMagazineRecipeCache()
    local recipes = {}
    for recipeName, _ in pairs(cache) do
        table.insert(recipes, recipeName)
    end
    BurdJournals.debugPrint("[BurdJournals] getAllMagazineRecipes returning " .. #recipes .. " recipes")
    return recipes
end

function BurdJournals.generateRandomRecipes(count)
    if not count or count <= 0 then return {} end

    local recipes = {}

    local available = BurdJournals.getAllMagazineRecipes()
    BurdJournals.debugPrint("[BurdJournals] generateRandomRecipes: Requested " .. count .. " recipes, " .. #available .. " available in cache")

    if #available == 0 then
        print("[BurdJournals] WARNING: No magazine recipes found in cache!")
        -- Debug: Check if cache was even built
        local cacheExists = BurdJournals._magazineRecipeCache ~= nil
        local cacheCount = 0
        if BurdJournals._magazineRecipeCache then
            for _ in pairs(BurdJournals._magazineRecipeCache) do cacheCount = cacheCount + 1 end
        end
        print("[BurdJournals] DEBUG: Cache exists=" .. tostring(cacheExists) .. ", cacheCount=" .. cacheCount)
        return {}
    end

    for i = #available, 2, -1 do
        local j = ZombRand(i) + 1
        available[i], available[j] = available[j], available[i]
    end

    for i = 1, math.min(count, #available) do
        local recipeName = available[i]
        recipes[recipeName] = true
    end

    return recipes
end

function BurdJournals.generateRandomRecipesSeeded(count, seed)
    if not count or count <= 0 then return {} end

    local recipes = {}

    local available = BurdJournals.getAllMagazineRecipes()

    if #available == 0 then
        print("[BurdJournals] WARNING: No magazine recipes found in cache for seeded generation!")
        return {}
    end

    local seedVal = math.floor(seed * 31) % 1000
    for i = 1, math.min(count, #available) do

        local idx = ((seedVal * (i + 7)) % #available) + 1
        local recipeName = available[idx]
        if recipeName and not recipes[recipeName] then
            recipes[recipeName] = true

            table.remove(available, idx)
        end
    end

    return recipes
end

BurdJournals.UI = BurdJournals.UI or {}
BurdJournals.UI.FILTER_TAB_HEIGHT = 22
BurdJournals.UI.FILTER_TAB_SPACING = 2
BurdJournals.UI.FILTER_TAB_PADDING = 8
BurdJournals.UI.FILTER_ARROW_WIDTH = 20

BurdJournals._vanillaSkillSet = nil

local function addVanillaSkillIdentifier(set, value)
    if type(value) ~= "string" or value == "" then
        return
    end
    local lower = string.lower(value)
    set[lower] = true

    -- Also store a punctuation/space-normalized form to handle legacy keys.
    local compact = lower:gsub("[^%w]", "")
    if compact ~= "" then
        set[compact] = true
    end
end

function BurdJournals.isVanillaSkillName(skillName, vanillaSet)
    if type(skillName) ~= "string" or skillName == "" then
        return false
    end

    local set = vanillaSet or (BurdJournals.getVanillaSkillSet and BurdJournals.getVanillaSkillSet()) or {}
    local lower = string.lower(skillName)
    local compact = lower:gsub("[^%w]", "")
    if set[lower] or (compact ~= "" and set[compact]) then
        return true
    end

    -- Resolve aliases/perk IDs in both directions.
    local mappedPerkId = BurdJournals.SKILL_TO_PERK and BurdJournals.SKILL_TO_PERK[skillName] or nil
    if mappedPerkId then
        addVanillaSkillIdentifier(set, mappedPerkId)
        if set[string.lower(mappedPerkId)] then
            return true
        end
    end

    if BurdJournals.mapPerkIdToSkillName then
        local mappedSkill = BurdJournals.mapPerkIdToSkillName(skillName)
        -- Only trust explicit alias conversions, not identity echoes from dynamic lookups.
        if mappedSkill and string.lower(mappedSkill) ~= lower then
            addVanillaSkillIdentifier(set, mappedSkill)
            if set[string.lower(mappedSkill)] then
                return true
            end
        end
    end

    if BurdJournals.SKILL_TO_PERK then
        for alias, perkId in pairs(BurdJournals.SKILL_TO_PERK) do
            if type(alias) == "string" and string.lower(alias) == lower then
                addVanillaSkillIdentifier(set, alias)
                addVanillaSkillIdentifier(set, perkId)
                return true
            end
        end
    end

    return false
end

function BurdJournals.getVanillaSkillSet()
    if BurdJournals._vanillaSkillSet then
        return BurdJournals._vanillaSkillSet
    end

    local set = {}

    for _, skills in pairs(BurdJournals.SKILL_CATEGORIES) do
        for _, skill in ipairs(skills) do
            addVanillaSkillIdentifier(set, skill)
        end
    end

    if BurdJournals.SKILL_TO_PERK then
        for skillName, perkId in pairs(BurdJournals.SKILL_TO_PERK) do
            addVanillaSkillIdentifier(set, skillName)
            addVanillaSkillIdentifier(set, perkId)
        end
    end
    BurdJournals._vanillaSkillSet = set
    return set
end

function BurdJournals.getModSourceFromFullType(fullType)
    if not fullType or fullType == "" then
        return "Vanilla"
    end

    local dotPos = string.find(fullType, "%.")
    local colonPos = string.find(fullType, ":")

    local splitPos = nil
    if dotPos and colonPos then
        splitPos = math.min(dotPos, colonPos)
    else
        splitPos = dotPos or colonPos
    end

    if not splitPos then
        return "Vanilla"
    end

    local modulePrefix = string.sub(fullType, 1, splitPos - 1)

    if modulePrefix == "Base" or modulePrefix == "base" then
        return "Vanilla"
    end

    return BurdJournals.getModNameFromPrefix(modulePrefix) or modulePrefix
end

function BurdJournals.getModSourceFromPrefix(prefix)
    if not prefix or prefix == "" then
        return nil
    end

    local lower = string.lower(tostring(prefix))
    if lower == "base" then
        return "Vanilla"
    end

    return BurdJournals.getModNameFromPrefix(prefix) or tostring(prefix)
end

-- Cache for active mod info (maps mod ID patterns to display names)
BurdJournals._modInfoCache = nil

-- Build a cache of active mods with their display names
-- This helps us identify which mod added a skill/trait
function BurdJournals.getModInfoCache()
    if BurdJournals._modInfoCache then
        return BurdJournals._modInfoCache
    end

    local cache = {
        -- Map lowercase prefixes/patterns to display names
        prefixToName = {},
        -- Map lowercase prefixes/patterns to canonical mod IDs
        prefixToId = {},
        -- Map lowercase display names back to canonical mod IDs
        nameToId = {},
        -- List of mod IDs for pattern matching
        modIds = {},
    }

    -- Try to get active mods (only available in-game, not during load)
    if getActivatedMods then
        local activeMods = getActivatedMods()
        if activeMods and activeMods.size and activeMods.get then
            for i = 0, activeMods:size() - 1 do
                local modId = activeMods:get(i)
                if modId then
                    modId = tostring(modId)
                    table.insert(cache.modIds, modId)
                    local modIdLower = string.lower(modId)

                    -- Try to get the mod's display name
                    local modInfo = getModInfoByID and getModInfoByID(modId)
                    local displayName = modId
                    if modInfo and modInfo.getName then
                        displayName = modInfo:getName() or modId
                    end

                    -- Map various patterns to this mod
                    cache.prefixToName[modIdLower] = displayName
                    cache.prefixToId[modIdLower] = modId
                    cache.nameToId[string.lower(displayName)] = modId

                    -- Also map common abbreviations/prefixes
                    -- e.g., "SoulFilchers_Traits" -> "SF" prefix
                    local underscorePos = string.find(modId, "_")
                    if underscorePos and underscorePos > 1 then
                        local prefix = string.sub(modId, 1, underscorePos - 1)
                        local prefixLower = string.lower(prefix)
                        if not cache.prefixToName[prefixLower] then
                            cache.prefixToName[prefixLower] = displayName
                        end
                        if not cache.prefixToId[prefixLower] then
                            cache.prefixToId[prefixLower] = modId
                        end
                    end

                    -- Handle mod IDs with capital letters as prefixes
                    -- e.g., "SOTOTraits" -> "SOTO"
                    local capsPrefix = string.match(modId, "^(%u+)")
                    if capsPrefix and #capsPrefix >= 2 then
                        local capsLower = string.lower(capsPrefix)
                        if not cache.prefixToName[capsLower] then
                            cache.prefixToName[capsLower] = displayName
                        end
                        if not cache.prefixToId[capsLower] then
                            cache.prefixToId[capsLower] = modId
                        end
                    end
                end
            end
        end
    end

    -- Add some well-known mod mappings as fallbacks
    local knownMods = {
        ["soto"] = "Soul's Trait Overhaul",
        ["mt"] = "More Traits",
        ["tbp"] = "The Only Cure",
        ["ss"] = "Simple Survivors",
        ["hc"] = "Hydrocraft",
        ["org"] = "Orgorealis",
        ["braven"] = "Braven's Mods",
        ["dyn"] = "Dynamic Traits",
        ["zre"] = "Zombie Re-Evolution",
        ["lifestyle"] = "Lifestyle: Hobbies",
        ["lifestylehobbies"] = "Lifestyle: Hobbies",
        ["adaptivetraits"] = "Adaptive Traits",
        ["traitspurchasesystem"] = "Trait Purchase System",
    }
    local knownModIds = {
        ["soto"] = "SOTO",
        ["mt"] = "MT",
        ["tbp"] = "TBP",
        ["ss"] = "SS",
        ["hc"] = "HC",
        ["org"] = "ORG",
        ["braven"] = "Braven",
        ["dyn"] = "DYN",
        ["zre"] = "ZRE",
        ["lifestyle"] = "Lifestyle",
        ["lifestylehobbies"] = "Lifestyle",
        ["adaptivetraits"] = "AdaptiveTraits",
        ["traitspurchasesystem"] = "TraitPurchaseSystem",
    }
    for prefix, name in pairs(knownMods) do
        if not cache.prefixToName[prefix] then
            cache.prefixToName[prefix] = name
        end
        if not cache.prefixToId[prefix] then
            cache.prefixToId[prefix] = knownModIds[prefix] or prefix
        end
        local nameLower = string.lower(name)
        if not cache.nameToId[nameLower] then
            cache.nameToId[nameLower] = cache.prefixToId[prefix]
        end
    end

    BurdJournals._modInfoCache = cache
    return cache
end

-- Try to find a mod name from a prefix
function BurdJournals.getModNameFromPrefix(prefix)
    if not prefix or prefix == "" then
        return nil
    end

    local cache = BurdJournals.getModInfoCache()
    local prefixLower = string.lower(prefix)

    -- Direct match
    if cache.prefixToName[prefixLower] then
        return cache.prefixToName[prefixLower]
    end

    -- Try partial match against mod IDs
    for _, modId in ipairs(cache.modIds) do
        if string.find(string.lower(modId), prefixLower, 1, true) then
            return cache.prefixToName[string.lower(modId)] or modId
        end
    end

    -- Return the prefix itself (capitalized nicely) if no match found
    return prefix
end

function BurdJournals.getModIdFromPrefix(prefix)
    if not prefix or prefix == "" then
        return nil
    end

    local source = tostring(prefix)
    local sourceLower = string.lower(source)
    if sourceLower == "base" or sourceLower == "vanilla" then
        return "Vanilla"
    end

    local cache = BurdJournals.getModInfoCache()

    if cache.prefixToId and cache.prefixToId[sourceLower] then
        return cache.prefixToId[sourceLower]
    end

    if cache.nameToId and cache.nameToId[sourceLower] then
        return cache.nameToId[sourceLower]
    end

    for _, modId in ipairs(cache.modIds) do
        local modIdLower = string.lower(modId)
        if string.find(modIdLower, sourceLower, 1, true) or string.find(sourceLower, modIdLower, 1, true) then
            return modId
        end
    end

    return source
end

function BurdJournals.getModIdFromFullType(fullType)
    if not fullType or fullType == "" then
        return "Vanilla"
    end

    local dotPos = string.find(fullType, "%.")
    local colonPos = string.find(fullType, ":")

    local splitPos = nil
    if dotPos and colonPos then
        splitPos = math.min(dotPos, colonPos)
    else
        splitPos = dotPos or colonPos
    end

    if not splitPos then
        return "Vanilla"
    end

    local modulePrefix = string.sub(fullType, 1, splitPos - 1)
    return BurdJournals.getModIdFromPrefix(modulePrefix) or modulePrefix
end

function BurdJournals.normalizeFilterSourceId(source)
    local sourceText = tostring(source or "")
    local sourceLower = string.lower(sourceText)

    if sourceLower == "" then
        return "modded"
    end
    if sourceLower == "all" then
        return "all"
    end
    if sourceLower == "vanilla" or sourceLower == "base" then
        return "vanilla"
    end
    if sourceLower == "modded" then
        return "modded"
    end

    local cache = BurdJournals.getModInfoCache and BurdJournals.getModInfoCache() or nil
    if cache and cache.nameToId and cache.nameToId[sourceLower] then
        return string.lower(tostring(cache.nameToId[sourceLower]))
    end

    local resolvedId = BurdJournals.getModIdFromPrefix(sourceText)
    if resolvedId and resolvedId ~= "" then
        local resolvedLower = string.lower(tostring(resolvedId))
        if resolvedLower == "vanilla" or resolvedLower == "base" then
            return "vanilla"
        end
        if resolvedLower == "modded" then
            return "modded"
        end
        return resolvedLower
    end

    return sourceLower
end

function BurdJournals.getSkillModSource(skillName)
    if not skillName then
        return "Vanilla"
    end

    local vanillaSet = BurdJournals.getVanillaSkillSet()
    local skillLower = string.lower(skillName)

    if BurdJournals.isVanillaSkillName and BurdJournals.isVanillaSkillName(skillName, vanillaSet) then
        return "Vanilla"
    end

    -- Check for colon separator (e.g., "ModName:SkillName")
    local explicitSource = BurdJournals.getModSourceFromFullType(skillName)
    if explicitSource ~= "Vanilla" then
        return explicitSource
    end

    -- Check for underscore separator (e.g., "SOTO_Blacksmith" or "ModName_Skill")
    local underscorePos = string.find(skillName, "_")
    if underscorePos and underscorePos > 1 then
        local prefix = string.sub(skillName, 1, underscorePos - 1)
        -- Accept prefixes that are all caps, or mixed case with 2+ chars
        if string.match(prefix, "^%u+$") or (string.match(prefix, "^%u") and #prefix >= 2) then
            return BurdJournals.getModNameFromPrefix(prefix) or prefix
        end
    end

    -- Check for CamelCase mod prefix (e.g., "SOTOBlacksmith")
    local capsPrefix = string.match(skillName, "^(%u%u+)")
    if capsPrefix and #capsPrefix >= 2 and #capsPrefix < #skillName then
        -- Make sure there's more after the prefix
        local remainder = string.sub(skillName, #capsPrefix + 1)
        if string.match(remainder, "^%u") then  -- Next char is also uppercase (like "SOTOBlacksmith")
            local modName = BurdJournals.getModNameFromPrefix(capsPrefix)
            if modName then
                return modName
            end
        end
    end

    -- Infer source from perk parent/category when available (e.g., Lifestyle parent)
    local perk = (Perks and BurdJournals.getPerkByName) and BurdJournals.getPerkByName(skillName)
    if perk and PerkFactory and PerkFactory.getPerk then
        local perkDef = PerkFactory.getPerk(perk)
        local parent = perkDef and perkDef.getParent and perkDef:getParent() or nil
        local parentId = nil
        if parent then
            if parent.getId then
                parentId = tostring(parent:getId())
            else
                parentId = tostring(parent)
                parentId = parentId:gsub("^Perks%.", "")
            end
        end

        if parentId and parentId ~= "" then
            local vanillaParents = {
                none = true,
                combat = true,
                firearm = true,
                agility = true,
                crafting = true,
                passive = true,
                melee = true,
                physical = true,
                farming = true,
                survival = true,
            }
            local parentLower = string.lower(parentId)
            if not vanillaParents[parentLower] then
                return BurdJournals.getModSourceFromPrefix(parentId) or "Modded"
            end
        end
    end

    -- If we get here, it's modded but we can't identify the source
    return "Modded"
end

function BurdJournals.getSkillModId(skillName)
    if not skillName then
        return "Vanilla"
    end

    local vanillaSet = BurdJournals.getVanillaSkillSet()
    if BurdJournals.isVanillaSkillName and BurdJournals.isVanillaSkillName(skillName, vanillaSet) then
        return "Vanilla"
    end

    local explicitId = BurdJournals.getModIdFromFullType(skillName)
    if explicitId ~= "Vanilla" then
        return explicitId
    end

    local underscorePos = string.find(skillName, "_")
    if underscorePos and underscorePos > 1 then
        local prefix = string.sub(skillName, 1, underscorePos - 1)
        if string.match(prefix, "^%u+$") or (string.match(prefix, "^%u") and #prefix >= 2) then
            return BurdJournals.getModIdFromPrefix(prefix) or prefix
        end
    end

    local capsPrefix = string.match(skillName, "^(%u%u+)")
    if capsPrefix and #capsPrefix >= 2 and #capsPrefix < #skillName then
        local remainder = string.sub(skillName, #capsPrefix + 1)
        if string.match(remainder, "^%u") then
            local modId = BurdJournals.getModIdFromPrefix(capsPrefix)
            if modId then
                return modId
            end
        end
    end

    local perk = (Perks and BurdJournals.getPerkByName) and BurdJournals.getPerkByName(skillName)
    if perk and PerkFactory and PerkFactory.getPerk then
        local perkDef = PerkFactory.getPerk(perk)
        local parent = perkDef and perkDef.getParent and perkDef:getParent() or nil
        local parentId = nil
        if parent then
            if parent.getId then
                parentId = tostring(parent:getId())
            else
                parentId = tostring(parent):gsub("^Perks%.", "")
            end
        end

        if parentId and parentId ~= "" then
            local vanillaParents = {
                none = true,
                combat = true,
                firearm = true,
                agility = true,
                crafting = true,
                passive = true,
                melee = true,
                physical = true,
                farming = true,
                survival = true,
            }
            local parentLower = string.lower(parentId)
            if not vanillaParents[parentLower] then
                return BurdJournals.getModIdFromPrefix(parentId) or parentId
            end
        end
    end

    return "Modded"
end

-- Cache for vanilla trait IDs
BurdJournals._vanillaTraitSet = nil
BurdJournals._traitSourceCache = nil
BurdJournals._traitSourceIdCache = nil

-- Build a set of known vanilla trait IDs
function BurdJournals.getVanillaTraitSet()
    if BurdJournals._vanillaTraitSet then
        return BurdJournals._vanillaTraitSet
    end

    -- Known vanilla trait IDs (lowercase for comparison)
    local vanillaTraits = {
        -- Positive traits
        "adrenalinejunkie", "athletic", "axeman", "baseballer", "biker",
        "brave", "burglar", "cat", "chef", "dextrous",
        "eagle", "empath", "fastlearner", "fasthealer", "fastshover",
        "firefighter", "fisherman", "fit", "forager", "gardener",
        "graceful", "gymnast", "hardheaded", "hothead", "hunter",
        "inconspicuous", "inventive", "iron", "juggler", "keen",
        "light", "lowprofile", "lucky", "marksman", "nightowl",
        "nutritionist", "organized", "outdoorsman", "pathfinder", "resilient",
        "runner", "stout", "strong", "thickskinned", "tough",
        "tracker", "veteran", "wakeful",
        -- Negative traits
        "addictive", "agoraphobic", "allergic", "asthmatic", "clumsy",
        "conspicuous", "cowardly", "deaf", "disorganized", "fear",
        "feeble", "hardofhearing", "heavysleeper", "heartyappetite", "hemophobic",
        "highthirst", "illiterate", "outofshape", "overweight", "obese",
        "pacifist", "prone", "restless", "short", "slowhealer",
        "slowlearner", "slowreader", "smoker", "sunday", "thin",
        "underweight", "unfit", "unlucky", "weak", "weakstomach",
        -- Hobby/occupation related
        "amateur", "axe", "angler", "baseball", "blade",
        "blunt", "electrical", "firstaid", "fishing", "handy",
        "herbalist", "hiker", "hunter2", "mechanics", "mechanics2",
        "metalwork", "nutritionist2", "runner2", "sewer", "sprinter",
        "swimmer", "tailoring", "tailor",
    }

    local set = {}
    for _, trait in ipairs(vanillaTraits) do
        set[trait] = true
    end

    BurdJournals._vanillaTraitSet = set
    return set
end

function BurdJournals.getTraitSourceCache(forceRefresh)
    if not forceRefresh and BurdJournals._traitSourceCache then
        return BurdJournals._traitSourceCache
    end

    local cache = {}

    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits and allTraits.size and allTraits.get then
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def and def.getType then
                    local traitType = def:getType()
                    local traitId = nil
                    if traitType and traitType.getName then
                        traitId = tostring(traitType:getName())
                    elseif traitType then
                        traitId = tostring(traitType):gsub("^base:", "")
                    end

                    if traitId and traitId ~= "" then
                        local rawType = traitType and tostring(traitType) or nil
                        local source = BurdJournals.getModSourceFromFullType(rawType)
                        cache[string.lower(traitId)] = source
                    end
                end
            end
        end
    end

    BurdJournals._traitSourceCache = cache
    return cache
end

function BurdJournals.getTraitSourceIdCache(forceRefresh)
    if not forceRefresh and BurdJournals._traitSourceIdCache then
        return BurdJournals._traitSourceIdCache
    end

    local cache = {}

    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits and allTraits.size and allTraits.get then
            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def and def.getType then
                    local traitType = def:getType()
                    local traitId = nil
                    if traitType and traitType.getName then
                        traitId = tostring(traitType:getName())
                    elseif traitType then
                        traitId = tostring(traitType):gsub("^base:", "")
                    end

                    if traitId and traitId ~= "" then
                        local rawType = traitType and tostring(traitType) or nil
                        local sourceId = BurdJournals.getModIdFromFullType(rawType)
                        cache[string.lower(traitId)] = sourceId
                    end
                end
            end
        end
    end

    BurdJournals._traitSourceIdCache = cache
    return cache
end

function BurdJournals.getTraitModSource(traitId)
    if not traitId then
        return "Vanilla"
    end

    local traitIdLower = string.lower(traitId)

    -- Prefer explicit source metadata from trait definitions when available.
    local sourceCache = BurdJournals.getTraitSourceCache and BurdJournals.getTraitSourceCache() or nil
    if sourceCache and sourceCache[traitIdLower] then
        return sourceCache[traitIdLower]
    end

    -- Check against known vanilla traits first
    local vanillaSet = BurdJournals.getVanillaTraitSet()
    if vanillaSet[traitIdLower] then
        return "Vanilla"
    end

    -- Check explicit module/type prefix first (e.g., "ModName:TraitName").
    local explicitSource = BurdJournals.getModSourceFromFullType(traitId)
    if explicitSource ~= "Vanilla" then
        return explicitSource
    end

    -- Check for underscore separator (e.g., "SOTO_Brave" or "MT_FastLearner")
    local underscorePos = string.find(traitId, "_")
    if underscorePos and underscorePos > 1 then
        local prefix = string.sub(traitId, 1, underscorePos - 1)
        -- Accept prefixes that look like mod identifiers
        if string.match(prefix, "^%u") and #prefix >= 2 then
            return BurdJournals.getModNameFromPrefix(prefix) or prefix
        end
    end

    -- Check for CamelCase mod prefix (e.g., "SOTOBrave")
    local capsPrefix = string.match(traitId, "^(%u%u+)")
    if capsPrefix and #capsPrefix >= 2 and #capsPrefix < #traitId then
        local remainder = string.sub(traitId, #capsPrefix + 1)
        if string.match(remainder, "^%u") then
            local modName = BurdJournals.getModNameFromPrefix(capsPrefix)
            if modName then
                return modName
            end
        end
    end

    -- Unknown IDs should default to Modded to avoid mislabeling third-party content as vanilla.
    return "Modded"
end

function BurdJournals.getTraitModId(traitId)
    if not traitId then
        return "Vanilla"
    end

    local traitIdLower = string.lower(traitId)

    local sourceIdCache = BurdJournals.getTraitSourceIdCache and BurdJournals.getTraitSourceIdCache() or nil
    if sourceIdCache and sourceIdCache[traitIdLower] then
        return sourceIdCache[traitIdLower]
    end

    local vanillaSet = BurdJournals.getVanillaTraitSet()
    if vanillaSet[traitIdLower] then
        return "Vanilla"
    end

    local explicitId = BurdJournals.getModIdFromFullType(traitId)
    if explicitId ~= "Vanilla" then
        return explicitId
    end

    local underscorePos = string.find(traitId, "_")
    if underscorePos and underscorePos > 1 then
        local prefix = string.sub(traitId, 1, underscorePos - 1)
        if string.match(prefix, "^%u") and #prefix >= 2 then
            return BurdJournals.getModIdFromPrefix(prefix) or prefix
        end
    end

    local capsPrefix = string.match(traitId, "^(%u%u+)")
    if capsPrefix and #capsPrefix >= 2 and #capsPrefix < #traitId then
        local remainder = string.sub(traitId, #capsPrefix + 1)
        if string.match(remainder, "^%u") then
            local modId = BurdJournals.getModIdFromPrefix(capsPrefix)
            if modId then
                return modId
            end
        end
    end

    return "Modded"
end

function BurdJournals.getRecipeModSource(recipeName, magazineSource)

    if magazineSource and magazineSource ~= "" then
        return BurdJournals.getModSourceFromFullType(magazineSource)
    end

    if recipeName then
        local magazine = BurdJournals.getMagazineForRecipe(recipeName)
        if magazine then
            return BurdJournals.getModSourceFromFullType(magazine)
        end

        local recipe = BurdJournals.getRecipeByName and BurdJournals.getRecipeByName(recipeName) or nil
        if recipe then
            local moduleValue = nil
            if recipe.getModule then
                moduleValue = recipe:getModule()
            elseif recipe.getModuleName then
                moduleValue = recipe:getModuleName()
            end

            local moduleName = nil
            if type(moduleValue) == "string" then
                moduleName = moduleValue
            elseif moduleValue then
                if moduleValue.getName then
                    moduleName = moduleValue:getName()
                else
                    moduleName = tostring(moduleValue)
                end
            end

            if moduleName and moduleName ~= "" then
                local source = BurdJournals.getModSourceFromPrefix(moduleName)
                if source then
                    return source
                end
            end
        end
    end

    return "Modded"
end

function BurdJournals.getRecipeModId(recipeName, magazineSource)
    if magazineSource and magazineSource ~= "" then
        return BurdJournals.getModIdFromFullType(magazineSource)
    end

    if recipeName then
        local magazine = BurdJournals.getMagazineForRecipe(recipeName)
        if magazine then
            return BurdJournals.getModIdFromFullType(magazine)
        end

        local recipe = BurdJournals.getRecipeByName and BurdJournals.getRecipeByName(recipeName) or nil
        if recipe then
            local moduleValue = nil
            if recipe.getModule then
                moduleValue = recipe:getModule()
            elseif recipe.getModuleName then
                moduleValue = recipe:getModuleName()
            end

            local moduleName = nil
            if type(moduleValue) == "string" then
                moduleName = moduleValue
            elseif moduleValue then
                if moduleValue.getName then
                    moduleName = moduleValue:getName()
                else
                    moduleName = tostring(moduleValue)
                end
            end

            if moduleName and moduleName ~= "" then
                local sourceId = BurdJournals.getModIdFromPrefix(moduleName)
                if sourceId then
                    return sourceId
                end
            end
        end
    end

    return "Modded"
end

function BurdJournals.diagnoseModSource(itemType, name, context)
    local result = {
        itemType = itemType or "unknown",
        name = name or "unknown",
        source = "Vanilla",
        reason = "default_vanilla",
        details = {}
    }

    if itemType == "skills" then
        local skillName = name
        if not skillName or skillName == "" then
            result.source = "Modded"
            result.reason = "missing_skill_name"
            return result
        end

        local vanillaSet = BurdJournals.getVanillaSkillSet and BurdJournals.getVanillaSkillSet() or {}
        local lower = string.lower(skillName)
        local compact = lower:gsub("[^%w]", "")
        if vanillaSet[lower] or (compact ~= "" and vanillaSet[compact]) then
            result.source = "Vanilla"
            result.reason = "matched_vanilla_skill_set"
            return result
        end

        if BurdJournals.SKILL_TO_PERK then
            local mappedPerkId = BurdJournals.SKILL_TO_PERK[skillName]
            if mappedPerkId and vanillaSet[string.lower(tostring(mappedPerkId))] then
                result.source = "Vanilla"
                result.reason = "matched_skill_to_perk_alias"
                return result
            end
        end

        local explicitSource = BurdJournals.getModSourceFromFullType(skillName)
        if explicitSource ~= "Vanilla" then
            result.source = explicitSource
            result.reason = "module_or_type_prefix"
            result.details.fullType = skillName
            return result
        end

        local underscorePos = string.find(skillName, "_")
        if underscorePos and underscorePos > 1 then
            local prefix = string.sub(skillName, 1, underscorePos - 1)
            if string.match(prefix, "^%u+$") or (string.match(prefix, "^%u") and #prefix >= 2) then
                result.source = BurdJournals.getModNameFromPrefix(prefix) or prefix
                result.reason = "underscore_prefix"
                result.details.prefix = prefix
                return result
            end
        end

        local capsPrefix = string.match(skillName, "^(%u%u+)")
        if capsPrefix and #capsPrefix >= 2 and #capsPrefix < #skillName then
            local remainder = string.sub(skillName, #capsPrefix + 1)
            if string.match(remainder, "^%u") then
                result.source = BurdJournals.getModNameFromPrefix(capsPrefix) or capsPrefix
                result.reason = "camelcase_prefix"
                result.details.prefix = capsPrefix
                return result
            end
        end

        local perk = (Perks and BurdJournals.getPerkByName) and BurdJournals.getPerkByName(skillName) or nil
        if perk and PerkFactory and PerkFactory.getPerk then
            local perkDef = PerkFactory.getPerk(perk)
            local parent = perkDef and perkDef.getParent and perkDef:getParent() or nil
            local parentId = nil
            if parent then
                parentId = parent.getId and tostring(parent:getId()) or tostring(parent):gsub("^Perks%.", "")
            end
            if parentId and parentId ~= "" then
                local parentLower = string.lower(parentId)
                local vanillaParents = {
                    none = true, combat = true, firearm = true, agility = true,
                    crafting = true, passive = true, melee = true, physical = true,
                    farming = true, survival = true,
                }
                if not vanillaParents[parentLower] then
                    result.source = BurdJournals.getModSourceFromPrefix(parentId) or "Modded"
                    result.reason = "non_vanilla_parent_category"
                    result.details.parent = parentId
                    return result
                end
            end
        end

        result.source = "Modded"
        result.reason = "no_source_pattern_match"
        return result
    end

    if itemType == "traits" then
        local traitId = name
        if not traitId or traitId == "" then
            result.source = "Modded"
            result.reason = "missing_trait_id"
            return result
        end

        local traitLower = string.lower(traitId)
        local sourceCache = BurdJournals.getTraitSourceCache and BurdJournals.getTraitSourceCache() or nil
        if sourceCache and sourceCache[traitLower] then
            result.source = sourceCache[traitLower]
            result.reason = "trait_definition_source_cache"
            return result
        end

        local vanillaSet = BurdJournals.getVanillaTraitSet and BurdJournals.getVanillaTraitSet() or {}
        if vanillaSet[traitLower] then
            result.source = "Vanilla"
            result.reason = "matched_vanilla_trait_set"
            return result
        end

        local explicitSource = BurdJournals.getModSourceFromFullType(traitId)
        if explicitSource ~= "Vanilla" then
            result.source = explicitSource
            result.reason = "module_or_type_prefix"
            result.details.fullType = traitId
            return result
        end

        local underscorePos = string.find(traitId, "_")
        if underscorePos and underscorePos > 1 then
            local prefix = string.sub(traitId, 1, underscorePos - 1)
            if string.match(prefix, "^%u") and #prefix >= 2 then
                result.source = BurdJournals.getModNameFromPrefix(prefix) or prefix
                result.reason = "underscore_prefix"
                result.details.prefix = prefix
                return result
            end
        end

        local capsPrefix = string.match(traitId, "^(%u%u+)")
        if capsPrefix and #capsPrefix >= 2 and #capsPrefix < #traitId then
            local remainder = string.sub(traitId, #capsPrefix + 1)
            if string.match(remainder, "^%u") then
                result.source = BurdJournals.getModNameFromPrefix(capsPrefix) or capsPrefix
                result.reason = "camelcase_prefix"
                result.details.prefix = capsPrefix
                return result
            end
        end

        result.source = "Modded"
        result.reason = "no_source_pattern_match"
        return result
    end

    if itemType == "recipes" then
        local recipeName = name
        local magazineSource = context and context.magazineSource or nil

        if magazineSource and magazineSource ~= "" then
            result.source = BurdJournals.getModSourceFromFullType(magazineSource)
            result.reason = "explicit_magazine_source"
            result.details.magazine = magazineSource
            return result
        end

        if recipeName and recipeName ~= "" then
            local cachedMagazine = BurdJournals.getMagazineForRecipe and BurdJournals.getMagazineForRecipe(recipeName) or nil
            if cachedMagazine then
                result.source = BurdJournals.getModSourceFromFullType(cachedMagazine)
                result.reason = "recipe_magazine_cache"
                result.details.magazine = cachedMagazine
                return result
            end

            local recipe = BurdJournals.getRecipeByName and BurdJournals.getRecipeByName(recipeName) or nil
            if recipe then
                local moduleValue = recipe.getModule and recipe:getModule() or (recipe.getModuleName and recipe:getModuleName() or nil)
                local moduleName = nil
                if type(moduleValue) == "string" then
                    moduleName = moduleValue
                elseif moduleValue then
                    moduleName = moduleValue.getName and moduleValue:getName() or tostring(moduleValue)
                end

                if moduleName and moduleName ~= "" then
                    result.source = BurdJournals.getModSourceFromPrefix(moduleName) or "Modded"
                    result.reason = "recipe_module_name"
                    result.details.module = moduleName
                    return result
                end
            end
        end

        result.source = "Modded"
        result.reason = "no_magazine_or_module_source"
        return result
    end

    result.source = "Modded"
    result.reason = "unknown_item_type"
    return result
end

function BurdJournals.collectModSources(itemType, journalData, player, mode)
    local sourceBuckets = {}

    local function addSource(sourceId)
        local normalizedId = BurdJournals.normalizeFilterSourceId and BurdJournals.normalizeFilterSourceId(sourceId) or string.lower(tostring(sourceId or "modded"))
        local bucket = sourceBuckets[normalizedId]
        if not bucket then
            local label = tostring(sourceId or "Modded")
            if normalizedId == "vanilla" then
                label = "Vanilla"
            elseif normalizedId == "modded" then
                label = "Modded"
            end
            bucket = {
                source = label,
                sourceId = normalizedId,
                count = 0,
            }
            sourceBuckets[normalizedId] = bucket
        end
        bucket.count = bucket.count + 1
    end

    if itemType == "skills" then
        if mode == "log" then

            local allowedSkills = BurdJournals.getAllowedSkills()
            for _, skillName in ipairs(allowedSkills) do
                local perk = BurdJournals.getPerkByName(skillName)
                if perk and player then
                    local currentXP = player:getXp():getXP(perk)
                    local currentLevel = player:getPerkLevel(perk)
                    if currentXP > 0 or currentLevel > 0 then
                        addSource(BurdJournals.getSkillModId(skillName))
                    end
                end
            end
        else

            if journalData and journalData.skills then
                for skillName, _ in pairs(journalData.skills) do
                    local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(journalData, skillName)
                    if enabledForJournal then
                        addSource(BurdJournals.getSkillModId(skillName))
                    end
                end
            end
        end

    elseif itemType == "traits" then
        if mode == "log" then

            if player then
                local playerTraits = BurdJournals.collectPlayerTraits(player, false)
                for traitId, _ in pairs(playerTraits) do
                    addSource(BurdJournals.getTraitModId(traitId))
                end
            end
        else

            if journalData and journalData.traits then
                for traitId, _ in pairs(journalData.traits) do
                    addSource(BurdJournals.getTraitModId(traitId))
                end
            end
        end

    elseif itemType == "recipes" then
        if mode == "log" then

            if player then
                local playerRecipes = BurdJournals.collectPlayerMagazineRecipes(player)
                for recipeName, recipeData in pairs(playerRecipes) do
                    local magazineSource = (type(recipeData) == "table" and recipeData.source) or BurdJournals.getMagazineForRecipe(recipeName)
                    addSource(BurdJournals.getRecipeModId(recipeName, magazineSource))
                end
            end
        else

            if journalData and journalData.recipes then
                for recipeName, recipeData in pairs(journalData.recipes) do
                    local magazineSource = (type(recipeData) == "table" and recipeData.source) or BurdJournals.getMagazineForRecipe(recipeName)
                    addSource(BurdJournals.getRecipeModId(recipeName, magazineSource))
                end
            end
        end
    end

    local result = {}
    local totalCount = 0
    for sourceId, bucket in pairs(sourceBuckets) do
        totalCount = totalCount + bucket.count
        if sourceId ~= "vanilla" then
            table.insert(result, {source = bucket.source, sourceId = bucket.sourceId, count = bucket.count})
        end
    end

    table.sort(result, function(a, b) return string.lower(a.source) < string.lower(b.source) end)

    if sourceBuckets["vanilla"] then
        table.insert(result, 1, {source = "Vanilla", sourceId = "vanilla", count = sourceBuckets["vanilla"].count})
    end

    table.insert(result, 1, {source = "All", sourceId = "all", count = totalCount})

    return result
end
