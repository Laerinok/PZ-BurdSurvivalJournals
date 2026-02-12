
require "BurdJournals_Shared"

BurdJournals.debugPrint("[BurdJournals] SERVER MODULE LOADING... (require completed)")

BurdJournals = BurdJournals or {}
BurdJournals.Server = BurdJournals.Server or {}

BurdJournals.Server._rateLimitCache = {}

function BurdJournals.Server.cleanupRateLimitCache()
    local now = getTimestampMs and getTimestampMs() or 0
    local staleThreshold = 60000
    for playerId, timestamp in pairs(BurdJournals.Server._rateLimitCache) do
        if now - timestamp > staleThreshold then
            BurdJournals.Server._rateLimitCache[playerId] = nil
        end
    end
end

function BurdJournals.Server.deepCopy(orig, copies)
    copies = copies or {}
    local origType = type(orig)
    local copy

    if origType == 'table' then

        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for origKey, origValue in pairs(orig) do

                local keyCopy = BurdJournals.Server.deepCopy(origKey, copies)
                local valueCopy = BurdJournals.Server.deepCopy(origValue, copies)
                copy[keyCopy] = valueCopy
            end

        end
    else

        copy = orig
    end
    return copy
end

-- Safe wrapper for shouldDissolve that re-fetches the journal by ID to avoid zombie object errors
-- This prevents "Object tried to call nil" crashes when the journal becomes invalid during processing
function BurdJournals.Server.safeShouldDissolve(player, journalId)
    if not player or not journalId then return false end

    -- Re-fetch the journal by ID to get a fresh reference
    local freshJournal = BurdJournals.findItemById(player, journalId)
    if not freshJournal then
        -- Journal no longer exists - treat as dissolved
        return false
    end

    -- Validate the item is still valid (not a zombie object) before calling shouldDissolve
    -- isValidItem uses instanceof which doesn't trigger error logging
    if not BurdJournals.isValidItem(freshJournal) then
        BurdJournals.debugPrint("[BurdJournals] safeShouldDissolve: Item is invalid/zombie, skipping dissolution check")
        return false
    end

    -- Call shouldDissolve with the validated reference
    if BurdJournals.shouldDissolve then
        return BurdJournals.shouldDissolve(freshJournal, player)
    end
    return false
end

function BurdJournals.Server.copyJournalData(journal)
    if not journal then return nil end
    local modData = journal:getModData()
    if not modData or not modData.BurdJournals then return nil end

    return BurdJournals.Server.deepCopy(modData.BurdJournals)
end

-- Server-side function to get skill baseline - checks server cache first, then player modData
function BurdJournals.Server.getSkillBaselineForPlayer(player, skillName)
    if not player or not skillName then return 0 end

    -- First, try to get baseline from server cache (more reliable on dedicated servers)
    local characterId = BurdJournals.getPlayerCharacterId(player)
    if characterId then
        local cachedBaseline = BurdJournals.Server.getCachedBaseline(characterId)
        if cachedBaseline and cachedBaseline.skillBaseline then
            local xp = cachedBaseline.skillBaseline[skillName]
            if xp then
                BurdJournals.debugPrint("[BurdJournals] Server: Got baseline for " .. skillName .. " from SERVER CACHE: " .. tostring(xp))
                return xp
            end
        end
    end

    -- Fallback to player modData (may not be synced on dedicated servers)
    local baselineXP = BurdJournals.getSkillBaseline(player, skillName) or 0
    if baselineXP > 0 then
        BurdJournals.debugPrint("[BurdJournals] Server: Got baseline for " .. skillName .. " from player modData: " .. tostring(baselineXP))
    end
    return baselineXP
end

function BurdJournals.Server.getMediaSkillBaselineForPlayer(player, skillName)
    if not player or not skillName then return 0 end

    local characterId = BurdJournals.getPlayerCharacterId(player)
    if characterId then
        local cachedBaseline = BurdJournals.Server.getCachedBaseline(characterId)
        if cachedBaseline then
            if type(cachedBaseline.mediaSkillBaseline) ~= "table" then
                cachedBaseline.mediaSkillBaseline = BurdJournals.getPlayerVhsSkillXPMapCopy
                    and BurdJournals.getPlayerVhsSkillXPMapCopy(player)
                    or {}
                if ModData.transmit then
                    ModData.transmit("BurdJournals_PlayerBaselines")
                end
            end

            local xp = tonumber(cachedBaseline.mediaSkillBaseline[skillName]) or 0
            if xp > 0 then
                return xp
            end
        end
    end

    local modData = player:getModData()
    if modData and modData.BurdJournals and modData.BurdJournals.mediaSkillBaseline then
        local xp = tonumber(modData.BurdJournals.mediaSkillBaseline[skillName]) or 0
        if xp > 0 then
            return xp
        end
    end

    return 0
end

function BurdJournals.Server.getTrackedVhsSkillXPForPlayer(player, skillName)
    if not player or not skillName then
        return 0
    end

    if BurdJournals.getPlayerVhsSkillXP then
        return math.max(0, tonumber(BurdJournals.getPlayerVhsSkillXP(player, skillName)) or 0)
    end

    local modData = player:getModData()
    local xpMap = modData and modData.BurdJournals and modData.BurdJournals.vhsSkillXP
    if type(xpMap) == "table" then
        return math.max(0, tonumber(xpMap[skillName]) or 0)
    end

    return 0
end

function BurdJournals.Server.getTrackedVhsSkillXPDeltaForPlayer(player, skillName, useBaseline)
    local trackedTotal = BurdJournals.Server.getTrackedVhsSkillXPForPlayer(player, skillName)
    if trackedTotal <= 0 then
        return 0, trackedTotal, 0
    end

    if not useBaseline then
        return trackedTotal, trackedTotal, 0
    end

    local trackedBaseline = BurdJournals.Server.getMediaSkillBaselineForPlayer(player, skillName)
    local trackedDelta = math.max(0, trackedTotal - trackedBaseline)
    return trackedDelta, trackedTotal, trackedBaseline
end

-- Debug baseline edits are intentionally synthetic and should not force
-- minimum claim XP floors for player journals.
function BurdJournals.Server.isBaselineDebugModifiedForPlayer(player)
    if not player then return false end

    local characterId = BurdJournals.getPlayerCharacterId(player)
    if characterId then
        local cachedBaseline = BurdJournals.Server.getCachedBaseline(characterId)
        if cachedBaseline and cachedBaseline.debugModified ~= nil then
            return cachedBaseline.debugModified == true
        end
    end

    local modData = player:getModData()
    if modData and modData.BurdJournals and modData.BurdJournals.debugModified == true then
        return true
    end

    return false
end

-- Resolve the absolute XP target for a journal claim.
-- Player journals recorded with baseline store earned/delta XP and must be
-- converted back to absolute XP at claim time (baseline + recorded delta).
function BurdJournals.Server.getSkillClaimTargetXP(player, journalData, skillName, recordedXP)
    local targetXP = math.max(0, tonumber(recordedXP) or 0)
    local baselineXP = 0
    local baselineSuppressed = false

    if player
        and type(journalData) == "table"
        and journalData.isPlayerCreated == true
        and journalData.recordedWithBaseline == true
    then
        baselineSuppressed = BurdJournals.Server.isBaselineDebugModifiedForPlayer
            and BurdJournals.Server.isBaselineDebugModifiedForPlayer(player)
            or false
        if not baselineSuppressed then
            baselineXP = math.max(0, tonumber(BurdJournals.Server.getSkillBaselineForPlayer(player, skillName)) or 0)
            targetXP = targetXP + baselineXP
        end
    end

    return targetXP, baselineXP, baselineSuppressed
end

function BurdJournals.Server.validateSkillPayload(skills, player)
    if skills == nil then return nil end
    if type(skills) ~= "table" then
        print("[BurdJournals] WARNING: Invalid skills payload (not a table) from " .. tostring(player and player:getUsername() or "unknown"))
        return nil
    end

    local validSkills = {}
    local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
    local allowedSet = {}
    for _, name in ipairs(allowedSkills) do allowedSet[name] = true end
    local playerJournalContext = {isPlayerCreated = true}

    -- Get baseline using the correct accessor
    local useBaseline = BurdJournals.shouldEnforceBaseline and BurdJournals.shouldEnforceBaseline(player) or false
    local allowVhsSkillRecording = BurdJournals.isVhsSkillRecordingEnabled and BurdJournals.isVhsSkillRecordingEnabled() or false

    -- Debug: Check if we have cached baseline for this player
    local characterId = BurdJournals.getPlayerCharacterId(player)
    local hasCachedBaseline = false
    local hasModDataBaseline = false
    local cachedBaseline = nil

    if characterId then
        cachedBaseline = BurdJournals.Server.getCachedBaseline(characterId)
        hasCachedBaseline = cachedBaseline ~= nil and cachedBaseline.skillBaseline ~= nil
    end

    -- Also check player modData
    local modData = player:getModData()
    if modData and modData.BurdJournals and modData.BurdJournals.skillBaseline then
        hasModDataBaseline = true
    end

    BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: useBaseline=" .. tostring(useBaseline) .. ", characterId=" .. tostring(characterId) .. ", hasCachedBaseline=" .. tostring(hasCachedBaseline) .. ", hasModDataBaseline=" .. tostring(hasModDataBaseline))

    -- WARNING: If baseline restriction is enabled but we have NO baseline data, log a warning
    -- This could cause skills to be rejected incorrectly
    if useBaseline and not hasCachedBaseline and not hasModDataBaseline then
        print("[BurdJournals] WARNING: Baseline restriction enabled but NO baseline data found for player " .. tostring(player:getUsername()) .. "! This may cause skills to be rejected incorrectly.")
        BurdJournals.debugPrint("[BurdJournals] The player's baseline may not have been captured. Consider asking them to close and reopen the journal, or disable 'Only Record Earned Progress' sandbox option.")
    end

    for skillName, skillData in pairs(skills) do

        if type(skillName) ~= "string" then
            print("[BurdJournals] WARNING: Invalid skill name type: " .. type(skillName))

        elseif not allowedSet[skillName] then
            print("[BurdJournals] WARNING: Unknown skill name: " .. skillName)

        elseif BurdJournals.isSkillEnabledForJournal and not BurdJournals.isSkillEnabledForJournal(playerJournalContext, skillName) then
            BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: Skipping disabled skill for player journals: " .. tostring(skillName))

        elseif type(skillData) ~= "table" then
            print("[BurdJournals] WARNING: Invalid skill data type for " .. skillName .. ": " .. type(skillData))
        else
            -- SERVER-SIDE VALIDATION: Get actual player XP, don't trust client values
            local perk = BurdJournals.getPerkByName(skillName)
            if perk then
                local actualXP = player:getXp():getXP(perk)
                local actualLevel = player:getPerkLevel(perk)

                -- Apply baseline if enabled (Only Record Earned Progress)
                local earnedXP = actualXP
                local baselineXP = 0
                if useBaseline then
                    -- Use server-side baseline retrieval (checks cache first)
                    baselineXP = BurdJournals.Server.getSkillBaselineForPlayer(player, skillName) or 0
                    earnedXP = math.max(0, actualXP - baselineXP)
                    BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: " .. skillName .. " actualXP=" .. tostring(actualXP) .. ", baselineXP=" .. tostring(baselineXP) .. ", earnedXP=" .. tostring(earnedXP))
                else
                    BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: " .. skillName .. " actualXP=" .. tostring(actualXP) .. " (baseline disabled)")
                end

                local rawEarnedXP = math.max(0, tonumber(earnedXP) or 0)
                local vhsExcludedXP = 0
                if not allowVhsSkillRecording then
                    local trackedDelta, trackedTotal, trackedBaseline = BurdJournals.Server.getTrackedVhsSkillXPDeltaForPlayer(player, skillName, useBaseline)
                    if trackedDelta > 0 then
                        local earnedBeforeVhs = earnedXP
                        earnedXP = math.max(0, earnedXP - trackedDelta)
                        vhsExcludedXP = math.max(0, (tonumber(earnedBeforeVhs) or 0) - earnedXP)
                        BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: " .. skillName
                            .. " subtracting VHS XP delta=" .. tostring(trackedDelta)
                            .. " (total=" .. tostring(trackedTotal)
                            .. ", baseline=" .. tostring(trackedBaseline)
                            .. "), finalEarned=" .. tostring(earnedXP))
                    end
                end

                -- Only record if there's actual earned XP
                if earnedXP > 0 then
                    validSkills[skillName] = {
                        xp = earnedXP,
                        level = actualLevel,
                        rawXP = rawEarnedXP,
                        vhsExcludedXP = vhsExcludedXP
                    }
                    BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: " .. skillName .. " ACCEPTED")
                else
                    BurdJournals.debugPrint("[BurdJournals] validateSkillPayload: " .. skillName .. " REJECTED (no earned XP)")
                end
            else
                print("[BurdJournals] WARNING: Could not find perk for skill: " .. skillName)
            end
        end
    end

    return validSkills
end

function BurdJournals.Server.validateTraitPayload(traits, player)
    if traits == nil then return nil end

    -- Check if trait recording is enabled for player journals
    if BurdJournals.getSandboxOption("EnableTraitRecordingPlayer") == false then
        BurdJournals.debugPrint("[BurdJournals] Trait recording disabled for player journals")
        return nil
    end

    if type(traits) ~= "table" then
        print("[BurdJournals] WARNING: Invalid traits payload (not a table) from " .. tostring(player and player:getUsername() or "unknown"))
        return nil
    end

    local validTraits = {}

    -- Check if baseline restriction is enabled
    local useBaseline = BurdJournals.shouldEnforceBaseline and BurdJournals.shouldEnforceBaseline(player) or false

    local playerJournalContext = { isPlayerCreated = true }

    for traitId, _ in pairs(traits) do

        if type(traitId) ~= "string" then
            print("[BurdJournals] WARNING: Invalid trait ID type: " .. type(traitId))

        elseif string.len(traitId) > 100 then
            print("[BurdJournals] WARNING: Trait ID too long: " .. string.sub(traitId, 1, 50) .. "...")
        else
            if BurdJournals.isTraitEnabledForJournal and not BurdJournals.isTraitEnabledForJournal(playerJournalContext, traitId) then
                BurdJournals.debugPrint("[BurdJournals] validateTraitPayload: Rejected trait " .. traitId .. " - blocked by compatibility settings")
            -- SERVER-SIDE VALIDATION: Verify player actually has this trait
            elseif BurdJournals.playerHasTrait(player, traitId) then
            -- SERVER-SIDE VALIDATION: Verify player actually has this trait
                -- Check if trait was in baseline (shouldn't record starting traits if enabled)
                local isBaselineTrait = useBaseline and BurdJournals.isStartingTrait(player, traitId)
                if not isBaselineTrait then
                    validTraits[traitId] = true
                end
            else
                BurdJournals.debugPrint("[BurdJournals] Rejected trait " .. traitId .. " - player doesn't have it")
            end
        end
    end

    return validTraits
end

function BurdJournals.Server.validateStatsPayload(stats, player)
    if stats == nil then return nil end
    if type(stats) ~= "table" then
        print("[BurdJournals] WARNING: Invalid stats payload (not a table) from " .. tostring(player and player:getUsername() or "unknown"))
        return nil
    end

    local validStats = {}

    for statId, statData in pairs(stats) do

        if type(statId) ~= "string" then
            print("[BurdJournals] WARNING: Invalid stat ID type: " .. type(statId))

        elseif string.len(statId) > 100 then
            print("[BurdJournals] WARNING: Stat ID too long: " .. string.sub(statId, 1, 50) .. "...")

        elseif type(statData) ~= "table" then
            print("[BurdJournals] WARNING: Invalid stat data type for " .. statId .. ": " .. type(statData))
        else

            -- Server-authoritative stat value (do not trust client)
            local value = nil
            if BurdJournals.getStatValue then
                value = BurdJournals.getStatValue(player, statId)
            end
            if value == nil then
                value = statData.value
                if type(value) ~= "number" and type(value) ~= "string" then
                    value = tostring(value)
                end
            end
            validStats[statId] = { value = value }
        end
    end

    return validStats
end

function BurdJournals.Server.validateRecipePayload(recipes, player)
    if recipes == nil then return nil end

    -- Check if recipe recording is enabled for player journals
    if BurdJournals.getSandboxOption("EnableRecipeRecordingPlayer") == false then
        BurdJournals.debugPrint("[BurdJournals] Recipe recording disabled for player journals")
        return nil
    end

    if type(recipes) ~= "table" then
        print("[BurdJournals] WARNING: Invalid recipes payload (not a table) from " .. tostring(player and player:getUsername() or "unknown"))
        return nil
    end

    local validRecipes = {}

    -- Check if baseline restriction is enabled
    local useBaseline = BurdJournals.shouldEnforceBaseline and BurdJournals.shouldEnforceBaseline(player) or false

    for recipeName, _ in pairs(recipes) do

        if type(recipeName) ~= "string" then
            print("[BurdJournals] WARNING: Invalid recipe name type: " .. type(recipeName))

        elseif string.len(recipeName) > 200 then
            print("[BurdJournals] WARNING: Recipe name too long: " .. string.sub(recipeName, 1, 50) .. "...")
        else
            -- SERVER-SIDE VALIDATION: Verify player actually knows this recipe
            if BurdJournals.playerKnowsRecipe(player, recipeName) then
                -- Check if recipe was in baseline (shouldn't record starting recipes if enabled)
                local isBaselineRecipe = useBaseline and BurdJournals.isStartingRecipe(player, recipeName)
                if not isBaselineRecipe then
                    validRecipes[recipeName] = true
                end
            else
                BurdJournals.debugPrint("[BurdJournals] Rejected recipe " .. recipeName .. " - player doesn't know it")
            end
        end
    end

    return validRecipes
end

function BurdJournals.Server.sendToClient(player, command, args)
    -- Validate player before sending command (prevents crashes with mods that wrap sendServerCommand)
    if not player then
        print("[BurdJournals] WARNING: sendToClient called with nil player for command: " .. tostring(command))
        return
    end

    -- Check if player is fully initialized (Username can be null during connection)
    if player.getUsername and player:getUsername() == nil then
        print("[BurdJournals] WARNING: sendToClient called with uninitialized player for command: " .. tostring(command))
        return
    end

    if not sendServerCommand then
        print("[BurdJournals] ERROR: sendServerCommand is not available for command '" .. tostring(command) .. "'")
        return
    end

    sendServerCommand(player, "BurdJournals", command, args)

    local localPlayer = getPlayer and getPlayer()
    local isTrueSinglePlayer = localPlayer ~= nil and not isClient()

    if isTrueSinglePlayer then
        local ticksToWait = 1
        local ticksWaited = 0
        local invokeClient
        invokeClient = function()
            ticksWaited = ticksWaited + 1
            if ticksWaited >= ticksToWait then
                Events.OnTick.Remove(invokeClient)
                if BurdJournals.Client and BurdJournals.Client.onServerCommand then
                    BurdJournals.Client.onServerCommand("BurdJournals", command, args)
                end
            end
        end
        Events.OnTick.Add(invokeClient)
    end
end

function BurdJournals.Server.init()
    -- Server started - verify baseline cache is properly loaded
    BurdJournals.debugPrint("[BurdJournals] Server.init() called - checking baseline cache...")
    
    -- Reset the logged flag so we report cache state on next access
    BurdJournals.Server._baselineCacheLogged = false
    
    -- Trigger a cache access to log current state
    local cache = BurdJournals.Server.getBaselineCache()
    local playerCount = 0
    for _ in pairs(cache.players or {}) do playerCount = playerCount + 1 end
    BurdJournals.debugPrint("[BurdJournals] Server init complete. Baseline cache has " .. playerCount .. " player baseline(s)")
end

-- Called when global ModData is initialized/loaded from disk
function BurdJournals.Server.onInitGlobalModData(isNewGame)
    BurdJournals.debugPrint("[BurdJournals] OnInitGlobalModData called (isNewGame=" .. tostring(isNewGame) .. ")")
    
    -- CRITICAL: Invalidate cached instance so we re-fetch from ModData
    -- This ensures we get the properly loaded data from disk
    BurdJournals.Server._baselineCacheInstance = nil
    
    -- Mark that ModData has been initialized - this is critical for knowing when it's safe to trust cache state
    BurdJournals.Server._modDataInitialized = true
    
    -- Reset flag to ensure we log the loaded cache state
    BurdJournals.Server._baselineCacheLogged = false
    
    -- Access the cache to ensure it's properly loaded and logged
    local cache = BurdJournals.Server.getBaselineCache()
    local playerCount = 0
    local debugModifiedCount = 0
    for id, data in pairs(cache.players or {}) do 
        playerCount = playerCount + 1
        if data and data.debugModified then
            debugModifiedCount = debugModifiedCount + 1
            BurdJournals.debugPrint("[BurdJournals]   - Player " .. tostring(id) .. " has debug-modified baseline")
        end
    end
    
    if isNewGame then
        BurdJournals.debugPrint("[BurdJournals] New game detected - baseline cache is fresh")
    else
        BurdJournals.debugPrint("[BurdJournals] Existing game loaded - baseline cache has " .. playerCount .. " player(s), " .. debugModifiedCount .. " debug-modified")
        
        -- Ensure data persists by triggering a transmit (belt and suspenders approach)
        if playerCount > 0 and ModData.transmit then
            ModData.transmit("BurdJournals_PlayerBaselines")
            BurdJournals.debugPrint("[BurdJournals] Triggered ModData.transmit to ensure persistence")
        end
    end
end

function BurdJournals.Server.onClientCommand(module, command, player, args)
    -- Only process BurdJournals commands (return early for other mods)
    if module ~= "BurdJournals" then return end

    BurdJournals.debugPrint("[BurdJournals] Server received command: " .. tostring(command) .. " from player: " .. tostring(player and player.getUsername and player:getUsername() or "unknown"))

    if not player then
        print("[BurdJournals] ERROR: No player in command")
        return
    end

    if BurdJournals.compactPlayerBurdJournalsData then
        local changed, removedLegacy, removedTransient, removedSkills, removedTraits, removedRecipes =
            BurdJournals.compactPlayerBurdJournalsData(player, true)
        if changed then
            BurdJournals.debugPrint("[BurdJournals] Server compacted player BurdJournals data for "
                .. tostring(player:getUsername())
                .. ": legacy=" .. tostring(removedLegacy)
                .. ", transient=" .. tostring(removedTransient)
                .. ", skills=" .. tostring(removedSkills)
                .. ", traits=" .. tostring(removedTraits)
                .. ", recipes=" .. tostring(removedRecipes))
        end
    end

    if BurdJournals.compactPlayerJournalDRCache then
        local changed, removedJournals, removedAliases = BurdJournals.compactPlayerJournalDRCache(player, true)
        if changed then
            BurdJournals.debugPrint("[BurdJournals] Server compacted player DR cache for "
                .. tostring(player:getUsername()) .. ": removed "
                .. tostring(removedJournals) .. " journals, "
                .. tostring(removedAliases) .. " aliases")
        end
    end

    -- Get player ID safely - getOnlineID may not exist on older builds
    local playerId
    if player.getOnlineID then
        playerId = tostring(player:getOnlineID())
    elseif player.getUsername then
        playerId = tostring(player:getUsername())
    else
        playerId = "unknown"
    end

    -- Rate limiting - only enforce when timestamp function exists
    -- IMPORTANT: Don't rate-limit timed-action-based commands (recordProgress, claim*, absorb*)
    -- These commands can be sent in rapid batches from LearnFromJournalAction and RecordToJournalAction
    local rateLimitExempt = {
        recordProgress = true,
        sanitizeJournal = true,
        requestXpSync = true,
        trackVhsSkillXP = true,
        batchClaimSkills = true,
        batchClaimRewards = true,
        batchAbsorbRewards = true,
        claimSkill = true,
        claimTrait = true,
        claimRecipe = true,
        claimStat = true,
        absorbSkill = true,
        absorbTrait = true,
        absorbRecipe = true,
        saveDebugJournalBackup = true,
        requestDebugJournalBackup = true,
        debugApplyJournalEdits = true,
        debugMigrateOnlineJournals = true,
        debugLookupJournalByUUID = true,
        debugRepairJournalByUUID = true,
        debugListJournalUUIDIndex = true,
        debugDeleteJournalByUUID = true,
    }
    local isDebugCommand = type(command) == "string" and string.sub(command, 1, 5) == "debug"
    if getTimestampMs and not rateLimitExempt[command] and not isDebugCommand then
        local now = getTimestampMs()
        local lastCmd = BurdJournals.Server._rateLimitCache[playerId] or 0
        if now - lastCmd < 100 then
            BurdJournals.debugPrint("[BurdJournals] Server: RATE LIMITED command " .. tostring(command) .. " (only " .. tostring(now - lastCmd) .. "ms since last)")
            return
        end
        BurdJournals.Server._rateLimitCache[playerId] = now

        -- Periodic cleanup (1% chance per command) - use ZombRand for PZ compatibility
        local rand = ZombRand and ZombRand(100) or 1
        if rand == 0 then
            BurdJournals.Server.cleanupRateLimitCache()
        end
    end

    local isEnabled = BurdJournals.isEnabled()
    BurdJournals.debugPrint("[BurdJournals] onClientCommand: isEnabled=" .. tostring(isEnabled))
    if not isEnabled then
        print("[BurdJournals] onClientCommand ERROR: Journals disabled!")
        BurdJournals.Server.sendToClient(player, "error", {message = "Journals are disabled on this server."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] onClientCommand: Routing command '" .. tostring(command) .. "'")
    if command == "logSkills" then
        BurdJournals.Server.handleLogSkills(player, args)
    elseif command == "learnSkills" then
        BurdJournals.Server.handleLearnSkills(player, args)
    elseif command == "absorbSkill" then
        BurdJournals.Server.handleAbsorbSkill(player, args)
    elseif command == "absorbTrait" then
        BurdJournals.Server.handleAbsorbTrait(player, args)
    elseif command == "claimSkill" then
        BurdJournals.Server.handleClaimSkill(player, args)
    elseif command == "claimTrait" then
        BurdJournals.Server.handleClaimTrait(player, args)
    elseif command == "eraseJournal" then
        BurdJournals.Server.handleEraseJournal(player, args)
    elseif command == "cleanBloody" then
        BurdJournals.Server.handleCleanBloody(player, args)
    elseif command == "convertToClean" then
        BurdJournals.Server.handleConvertToClean(player, args)
    elseif command == "initializeJournal" then
        BurdJournals.Server.handleInitializeJournal(player, args)
    elseif command == "recordProgress" then
        BurdJournals.debugPrint("[BurdJournals] ROUTING recordProgress to handler NOW")
        BurdJournals.Server.handleRecordProgress(player, args)
    elseif command == "syncJournalData" then
        BurdJournals.Server.handleSyncJournalData(player, args)
    elseif command == "claimRecipe" then
        BurdJournals.Server.handleClaimRecipe(player, args)
    elseif command == "claimStat" then
        BurdJournals.Server.handleClaimStat(player, args)
    elseif command == "absorbRecipe" then
        BurdJournals.Server.handleAbsorbRecipe(player, args)
    elseif command == "eraseEntry" then
        BurdJournals.Server.handleEraseEntry(player, args)
    elseif command == "registerBaseline" then
        BurdJournals.Server.handleRegisterBaseline(player, args)
    elseif command == "requestBaseline" then
        BurdJournals.Server.handleRequestBaseline(player, args)
    elseif command == "trackVhsSkillXP" then
        BurdJournals.Server.handleTrackVhsSkillXP(player, args)
    elseif command == "deleteBaseline" then
        BurdJournals.Server.handleDeleteBaseline(player, args)
    elseif command == "dissolveJournal" then
        BurdJournals.Server.handleDissolveJournal(player, args)
    elseif command == "sanitizeJournal" then
        BurdJournals.Server.handleSanitizeJournal(player, args)
    elseif command == "clearAllBaselines" then
        BurdJournals.Server.handleClearAllBaselines(player, args)
    elseif command == "renameJournal" then
        BurdJournals.Server.handleRenameJournal(player, args)
    -- Debug commands (require debug permission)
    elseif command == "debugSetSkill" then
        BurdJournals.Server.handleDebugSetSkill(player, args)
    elseif command == "debugSetAllSkills" then
        BurdJournals.Server.handleDebugSetAllSkills(player, args)
    elseif command == "debugAddXP" then
        BurdJournals.Server.handleDebugAddXP(player, args)
    elseif command == "debugSetSkillToLevel" then
        BurdJournals.Server.handleDebugSetSkillToLevel(player, args)
    elseif command == "debugSetSkillXP" then
        BurdJournals.Server.handleDebugSetSkillXP(player, args)
    elseif command == "debugAddSkillXP" then
        BurdJournals.Server.handleDebugAddSkillXP(player, args)
    elseif command == "debugAddTrait" then
        BurdJournals.Server.handleDebugAddTrait(player, args)
    elseif command == "debugRemoveTrait" then
        BurdJournals.Server.handleDebugRemoveTrait(player, args)
    elseif command == "debugRemoveAllTraits" then
        BurdJournals.Server.handleDebugRemoveAllTraits(player, args)
    elseif command == "debugClearBaseline" then
        BurdJournals.Server.handleDebugClearBaseline(player, args)
    elseif command == "debugRecalcBaseline" then
        BurdJournals.Server.handleDebugRecalcBaseline(player, args)
    elseif command == "debugUpdateSkillBaseline" then
        BurdJournals.Server.handleDebugUpdateSkillBaseline(player, args)
    elseif command == "debugUpdateTraitBaseline" then
        BurdJournals.Server.handleDebugUpdateTraitBaseline(player, args)
    elseif command == "debugSpawnJournal" then
        BurdJournals.Server.handleDebugSpawnJournal(player, args)
    elseif command == "debugDissolveJournal" then
        BurdJournals.Server.handleDebugDissolveJournal(player, args)
    elseif command == "debugJournalCreated" then
        -- Client notifying server about a debug-spawned journal (for tracking)
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Client created debug journal ID=" .. tostring(args.journalId) .. " type=" .. tostring(args.journalType))
    elseif command == "requestXpSync" then
        -- Client requesting XP sync after batch operations
        BurdJournals.Server.handleRequestXpSync(player, args)
    elseif command == "batchClaimSkills" then
        -- Process multiple skill claims in one server-side call
        BurdJournals.Server.handleBatchClaimSkills(player, args)
    elseif command == "batchClaimRewards" then
        -- Process mixed claim rewards (skills/traits/recipes/stats) in one server-side call
        BurdJournals.Server.handleBatchClaimRewards(player, args)
    elseif command == "batchAbsorbRewards" then
        -- Process mixed absorb rewards (skills/traits/recipes/stats) in one server-side call
        BurdJournals.Server.handleBatchAbsorbRewards(player, args)
    elseif command == "saveDebugJournalBackup" then
        -- Save debug journal data to server-side global ModData for persistence
        BurdJournals.Server.handleSaveDebugJournalBackup(player, args)
    elseif command == "requestDebugJournalBackup" then
        -- Client requesting backup data for a debug journal
        BurdJournals.Server.handleRequestDebugJournalBackup(player, args)
    elseif command == "debugApplyJournalEdits" then
        -- Apply debug-edited journal data directly to server-side item ModData
        BurdJournals.Server.handleDebugApplyJournalEdits(player, args)
    elseif command == "debugMigrateOnlineJournals" then
        -- Admin one-shot migration for online players' journal data
        BurdJournals.Server.handleDebugMigrateOnlineJournals(player, args)
    elseif command == "debugLookupJournalByUUID" then
        -- Admin/debug lookup of live journal item by UUID
        BurdJournals.Server.handleDebugLookupJournalByUUID(player, args)
    elseif command == "debugRepairJournalByUUID" then
        -- Admin/debug repair pass for a live journal by UUID
        BurdJournals.Server.handleDebugRepairJournalByUUID(player, args)
    elseif command == "debugListJournalUUIDIndex" then
        -- Admin/debug fetch of UUID index metadata
        BurdJournals.Server.handleDebugListJournalUUIDIndex(player, args)
    elseif command == "debugDeleteJournalByUUID" then
        -- Admin/debug delete live journal item by UUID and purge cache/index entries
        BurdJournals.Server.handleDebugDeleteJournalByUUID(player, args)
    end
end

-- Handle client request to sync XP (called at end of batch claiming)
function BurdJournals.Server.handleRequestXpSync(player, args)
    BurdJournals.debugPrint("[BurdJournals] Server: XP sync requested by " .. tostring(player:getUsername()))
    -- Try both sync methods - SyncXp (global) and player:syncXp (method)
    if SyncXp then
        SyncXp(player)
        BurdJournals.debugPrint("[BurdJournals] Server: XP synced via SyncXp global function")
    elseif player.syncXp then
        player:syncXp()
        BurdJournals.debugPrint("[BurdJournals] Server: XP synced via player:syncXp method")
    else
        print("[BurdJournals] Server: WARNING - No sync method available!")
    end
    BurdJournals.Server.sendToClient(player, "xpSyncComplete", {})
end

function BurdJournals.Server.handleTrackVhsSkillXP(player, args)
    if not player or type(args) ~= "table" then
        return
    end

    local skillPayload = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.skills) or args.skills
    if type(skillPayload) ~= "table" then
        return
    end

    local normalized = {}
    for skillName, xpDelta in pairs(skillPayload) do
        if type(skillName) == "string" and skillName ~= "" then
            local parsed = tonumber(xpDelta) or 0
            if parsed > 0 then
                normalized[skillName] = parsed
            end
        end
    end

    if not BurdJournals.hasAnyEntries(normalized) then
        return
    end

    if BurdJournals.recordVhsSkillXP then
        BurdJournals.recordVhsSkillXP(player, normalized, args.lineGuid, args.category, "clientCommand")
    end
end

-- Handle batch skill claims in ONE server call.
-- Security note: client-provided XP targets are ignored; server derives claimable XP from journal data.
function BurdJournals.Server.handleBatchClaimSkills(player, args)
    local skills = args and (BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.skills) or args.skills) or nil
    local skillsTotal = 0
    if type(skills) == "table" then
        for _, _ in pairs(skills) do
            skillsTotal = skillsTotal + 1
        end
    end
    if not args or not args.journalId or type(skills) ~= "table" or skillsTotal == 0 then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid batch claim request."})
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = 0})
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = skillsTotal})
        return
    end

    local canClaim, reason = BurdJournals.canPlayerClaimFromJournal(player, journal)
    if not canClaim then
        BurdJournals.Server.sendToClient(player, "error", {message = reason or "Permission denied."})
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = skillsTotal})
        return
    end

    if not BurdJournals.canSetXP(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Batch claim only supports clean player journals."})
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = skillsTotal})
        return
    end

    local processed = 0
    local batchClaimSessionId = args and args.claimSessionId
    local total = 0
    for _, skillData in pairs(skills) do
        local skillName = skillData and skillData.skillName
        if type(skillName) == "string" and skillName ~= "" then
            total = total + 1
            BurdJournals.Server.handleClaimSkill(player, {
                journalId = args.journalId,
                skillName = skillName,
                claimSessionId = batchClaimSessionId
            })
            processed = processed + 1
        end
    end

    if SyncXp then
        SyncXp(player)
    elseif player.syncXp then
        player:syncXp()
    end

    BurdJournals.Server.sendToClient(player, "batchClaimComplete", {
        count = processed,
        total = total
    })
end

local function countBatchEntries(entries)
    if type(entries) ~= "table" then
        return 0
    end
    local count = 0
    for _, _ in pairs(entries) do
        count = count + 1
    end
    return count
end

function BurdJournals.Server.handleBatchClaimRewards(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid batch claim request."})
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = 0, mode = "claim"})
        return
    end

    local skills = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.skills) or (args.skills or {})
    local traits = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.traits) or (args.traits or {})
    local recipes = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.recipes) or (args.recipes or {})
    local stats = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.stats) or (args.stats or {})
    local total = countBatchEntries(skills) + countBatchEntries(traits) + countBatchEntries(recipes) + countBatchEntries(stats)
    if total == 0 then
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = 0, mode = "claim"})
        return
    end

    local processedSkills = 0
    local processedTraits = 0
    local processedRecipes = 0
    local processedStats = 0
    local claimSessionId = args.claimSessionId

    for _, skillData in pairs(skills) do
        local skillName = skillData and skillData.skillName
        if type(skillName) == "string" and skillName ~= "" then
            BurdJournals.Server.handleClaimSkill(player, {
                journalId = args.journalId,
                skillName = skillName,
                claimSessionId = claimSessionId,
            })
            processedSkills = processedSkills + 1
        end
    end

    for _, traitId in pairs(traits) do
        if type(traitId) == "string" and traitId ~= "" then
            BurdJournals.Server.handleClaimTrait(player, {
                journalId = args.journalId,
                traitId = traitId,
            })
            processedTraits = processedTraits + 1
        end
    end

    for _, recipeName in pairs(recipes) do
        if type(recipeName) == "string" and recipeName ~= "" then
            BurdJournals.Server.handleClaimRecipe(player, {
                journalId = args.journalId,
                recipeName = recipeName,
            })
            processedRecipes = processedRecipes + 1
        end
    end

    for _, statEntry in pairs(stats) do
        local statId = statEntry and statEntry.statId
        if type(statId) == "string" and statId ~= "" then
            BurdJournals.Server.handleClaimStat(player, {
                journalId = args.journalId,
                statId = statId,
                value = statEntry.value,
            })
            processedStats = processedStats + 1
        end
    end

    if SyncXp then
        SyncXp(player)
    elseif player.syncXp then
        player:syncXp()
    end

    BurdJournals.Server.sendToClient(player, "batchClaimComplete", {
        mode = "claim",
        count = processedSkills + processedTraits + processedRecipes + processedStats,
        total = total,
        skillsProcessed = processedSkills,
        traitsProcessed = processedTraits,
        recipesProcessed = processedRecipes,
        statsProcessed = processedStats,
    })
end

function BurdJournals.Server.handleBatchAbsorbRewards(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid batch absorb request."})
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = 0, mode = "absorb"})
        return
    end

    local skills = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.skills) or (args.skills or {})
    local traits = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.traits) or (args.traits or {})
    local recipes = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.recipes) or (args.recipes or {})
    local stats = BurdJournals.normalizeTable and BurdJournals.normalizeTable(args.stats) or (args.stats or {})
    local total = countBatchEntries(skills) + countBatchEntries(traits) + countBatchEntries(recipes) + countBatchEntries(stats)
    if total == 0 then
        BurdJournals.Server.sendToClient(player, "batchClaimComplete", {count = 0, total = 0, mode = "absorb"})
        return
    end

    local processedSkills = 0
    local processedTraits = 0
    local processedRecipes = 0
    local processedStats = 0

    for _, skillData in pairs(skills) do
        local skillName = skillData and skillData.skillName
        if type(skillName) == "string" and skillName ~= "" then
            BurdJournals.Server.handleAbsorbSkill(player, {
                journalId = args.journalId,
                skillName = skillName,
            })
            processedSkills = processedSkills + 1
        end
    end

    for _, traitId in pairs(traits) do
        if type(traitId) == "string" and traitId ~= "" then
            BurdJournals.Server.handleAbsorbTrait(player, {
                journalId = args.journalId,
                traitId = traitId,
            })
            processedTraits = processedTraits + 1
        end
    end

    for _, recipeName in pairs(recipes) do
        if type(recipeName) == "string" and recipeName ~= "" then
            BurdJournals.Server.handleAbsorbRecipe(player, {
                journalId = args.journalId,
                recipeName = recipeName,
            })
            processedRecipes = processedRecipes + 1
        end
    end

    for _, statEntry in pairs(stats) do
        local statId = statEntry and statEntry.statId
        if type(statId) == "string" and statId ~= "" then
            BurdJournals.Server.handleClaimStat(player, {
                journalId = args.journalId,
                statId = statId,
                value = statEntry.value,
            })
            processedStats = processedStats + 1
        end
    end

    if SyncXp then
        SyncXp(player)
    elseif player.syncXp then
        player:syncXp()
    end

    BurdJournals.Server.sendToClient(player, "batchClaimComplete", {
        mode = "absorb",
        count = processedSkills + processedTraits + processedRecipes + processedStats,
        total = total,
        skillsProcessed = processedSkills,
        traitsProcessed = processedTraits,
        recipesProcessed = processedRecipes,
        statsProcessed = processedStats,
    })
end

-- Server-side sanitization handler (called when client opens journal in MP)
function BurdJournals.Server.handleSanitizeJournal(player, args)
    if not args or not args.journalId then
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        return
    end

    -- Sanitize the journal data (server-side, authoritative)
    if BurdJournals.sanitizeJournalData then
        local sanitizeResult = BurdJournals.sanitizeJournalData(journal, player)
        if sanitizeResult and sanitizeResult.cleaned then
            BurdJournals.debugPrint("[BurdJournals] Server: Sanitized journal " .. tostring(args.journalId))
            -- Transmit sanitized data to all clients
            if journal.transmitModData then
                journal:transmitModData()
            end

            -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
            local freshJournal = BurdJournals.findItemById(player, args.journalId)
            if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve and BurdJournals.shouldDissolve(freshJournal, player) then
                BurdJournals.Server.dissolveJournal(player, freshJournal)
                BurdJournals.Server.sendToClient(player, "journalDissolved", {
                    journalId = args.journalId,
                    reason = "sanitized"
                })
                return
            end
        end
    end

    -- Also run migration if needed
    if BurdJournals.migrateJournalIfNeeded then
        BurdJournals.migrateJournalIfNeeded(journal, player)
        if journal.transmitModData then
            journal:transmitModData()
        end
    end

    -- Patch/update safety: if DR counters were dropped from item ModData, restore from cache.
    if BurdJournals.restoreJournalDRStateIfMissing then
        BurdJournals.restoreJournalDRStateIfMissing(journal, "sanitizeJournal", player)
    end
    if BurdJournals.captureJournalDRState then
        BurdJournals.captureJournalDRState(journal, "sanitizeJournalSeed", player)
    end
    
    -- Compact journal data to reduce ModData size (helps prevent 64KB player data limit issues)
    if BurdJournals.compactJournalData then
        BurdJournals.compactJournalData(journal)
        if journal.transmitModData then
            journal:transmitModData()
        end
    end

    BurdJournals.Server.updateJournalUUIDIndex(journal, player, "sanitizeJournal")
    if BurdJournals.Server.seedDebugSnapshotFromLiveJournal then
        BurdJournals.Server.seedDebugSnapshotFromLiveJournal(journal, player, "sanitizeJournal")
    end
    
    -- Always check dissolution when journal is opened (handles bugged journals from previous versions)
    local freshJournal = BurdJournals.findItemById(player, args.journalId)
    if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve and BurdJournals.shouldDissolve(freshJournal, player) then
        BurdJournals.Server.dissolveJournal(player, freshJournal)
        BurdJournals.Server.sendToClient(player, "journalDissolved", {
            journalId = args.journalId,
            reason = "fully_claimed"
        })
    end
end

-- Dissolution handler - manual dissolve from UI button (no shouldDissolve check - user confirmed action)
function BurdJournals.Server.handleDissolveJournal(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] Server: Dissolve requested for journal ID " .. tostring(args.journalId))

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        -- Try searching more broadly for debug-spawned journals
        BurdJournals.debugPrint("[BurdJournals] Server: Journal not found via findItemById, searching inventory directly...")
        local inv = player:getInventory()
        if inv then
            local items = inv:getItems()
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                if item and item:getID() == args.journalId then
                    journal = item
                    BurdJournals.debugPrint("[BurdJournals] Server: Found journal in main inventory")
                    break
                end
            end
        end
    end
    
    if not journal then
        BurdJournals.debugPrint("[BurdJournals] Server: Journal " .. tostring(args.journalId) .. " not found anywhere")
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    -- Validate item is not a zombie object
    if not BurdJournals.isValidItem(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal is no longer valid."})
        return
    end

    -- Check journal data for debug-spawned or worn/bloody status
    local modData = journal:getModData()
    local data = modData and modData.BurdJournals
    local fullType = journal:getFullType()
    local isWornFromType = fullType and string.find(fullType, "_Worn") ~= nil
    local isBloodyFromType = fullType and string.find(fullType, "_Bloody") ~= nil
    local isWorn = (data and data.isWorn) or isWornFromType
    local isBloody = (data and data.isBloody) or isBloodyFromType
    local hasWornBloodyOrigin = data and (data.wasFromWorn or data.wasFromBloody)
    local isDebugSpawned = data and data.isDebugSpawned

    -- Allow debug-spawned journals to always be dissolved
    if not isDebugSpawned and not isWorn and not isBloody and not hasWornBloodyOrigin then
        BurdJournals.Server.sendToClient(player, "error", {message = "Only worn or bloody journals can be manually dissolved."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] Server: Manual dissolve requested for journal " .. tostring(args.journalId) .. " (debug=" .. tostring(isDebugSpawned) .. ")")

    -- Remove the journal using the complete removal path
    BurdJournals.Server.dissolveJournal(player, journal)

    -- Send dissolution notification
    local message = BurdJournals.getRandomDissolutionMessage and BurdJournals.getRandomDissolutionMessage() or "The journal crumbles to dust..."
    BurdJournals.Server.sendToClient(player, "journalDissolved", {
        message = message,
        journalId = args.journalId
    })
end

local function removeJournalCompletely(player, journal)

    if not journal then
        return false
    end

    local journalType = journal:getFullType()
    local journalID = journal:getID()

    BurdJournals.safePcall(function()
        if player:getPrimaryHandItem() == journal then
            player:setPrimaryHandItem(nil)

        end
        if player:getSecondaryHandItem() == journal then
            player:setSecondaryHandItem(nil)

        end
    end)

    local container = journal:getContainer()
    if container then
        container:Remove(journal)
        container:setDrawDirty(true)

    end

    local mainInv = player:getInventory()
    if mainInv then
        if mainInv:contains(journal) then
            mainInv:Remove(journal)
            mainInv:setDrawDirty(true)

        end

        local items = mainInv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            -- Only check containers (bags, backpacks, etc.) - regular items don't have getInventory
            if item and item.getInventory then
                BurdJournals.safePcall(function()
                    local subInv = item:getInventory()
                    if subInv and subInv:contains(journal) then
                        subInv:Remove(journal)
                        subInv:setDrawDirty(true)
                    end
                end)
            end
        end
    end

    local stillExists = mainInv and mainInv:contains(journal)

    return not stillExists
end

-- Public dissolve function that uses complete removal
function BurdJournals.Server.dissolveJournal(player, journal)
    if not player or not journal then return false end
    return removeJournalCompletely(player, journal)
end

function BurdJournals.Server.handleInitializeJournal(player, args)
    if not args or not args.itemType then

        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local itemType = args.itemType
    local clientUUID = args.clientUUID

    local sourceJournalData = nil
    do
        local sourceModData = journal:getModData()
        sourceJournalData = sourceModData and sourceModData.BurdJournals or nil
    end

    local inheritedWasFromWorn = false
    local inheritedWasFromBloody = false
    local inheritedWasRestored = false
    local inheritedRestoredBy = nil
    if type(sourceJournalData) == "table" then
        inheritedWasFromWorn = sourceJournalData.wasFromWorn == true or sourceJournalData.isWorn == true
        inheritedWasFromBloody = sourceJournalData.wasFromBloody == true or sourceJournalData.isBloody == true
        if BurdJournals.isRestoredJournalData then
            inheritedWasRestored = BurdJournals.isRestoredJournalData(sourceJournalData)
        else
            inheritedWasRestored = sourceJournalData.wasRestored == true
                or sourceJournalData.wasCleaned == true
                or inheritedWasFromWorn
                or inheritedWasFromBloody
        end
        inheritedRestoredBy = sourceJournalData.restoredBy
    end

    if inheritedWasRestored and (type(inheritedRestoredBy) ~= "string" or inheritedRestoredBy == "") then
        inheritedRestoredBy = player and player:getUsername() or "Unknown"
    end

    local inventory = player:getInventory()
    if not inventory then
        BurdJournals.Server.sendToClient(player, "error", {message = "Inventory not found."})
        return
    end

    local journal = nil
    local allItems = inventory:getItems()

    if clientUUID then
        for i = 0, allItems:size() - 1 do
            local item = allItems:get(i)
            if item then
                local modData = item:getModData()
                if modData and modData.BurdJournals and modData.BurdJournals.uuid == clientUUID then
                    journal = item

                    break
                end
            end
        end
    end

    if not journal then
        for i = 0, allItems:size() - 1 do
            local item = allItems:get(i)
            if item and item:getFullType() == itemType then
                local modData = item:getModData()
                local needsInit = not modData.BurdJournals or
                                  not modData.BurdJournals.uuid or
                                  not modData.BurdJournals.skills
                if needsInit then
                    journal = item
                    break
                end
            end
        end
    end

    if not journal then
        for i = 0, allItems:size() - 1 do
            local item = allItems:get(i)
            if item and item.getInventory then
                local bagInv = item:getInventory()
                if bagInv then
                    local bagItems = bagInv:getItems()
                    for j = 0, bagItems:size() - 1 do
                        local bagItem = bagItems:get(j)
                        if bagItem and bagItem:getFullType() == itemType then
                            local modData = bagItem:getModData()
                            local needsInit = not modData.BurdJournals or
                                              not modData.BurdJournals.uuid or
                                              not modData.BurdJournals.skills
                            if needsInit then
                                journal = bagItem

                                break
                            end
                        end
                    end
                    if journal then break end
                end
            end
        end
    end

    if not journal then

        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found for initialization."})
        return
    end

    local modData = journal:getModData()
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end

    local uuid = clientUUID or BurdJournals.generateUUID()
    modData.BurdJournals.uuid = uuid

    local journalType = journal:getFullType()
    local isWorn = string.find(journalType, "_Worn") ~= nil
    local isBloody = string.find(journalType, "_Bloody") ~= nil
    local isFilled = string.find(journalType, "Filled") ~= nil

    if isFilled and not modData.BurdJournals.skills then

        local minSkills, maxSkills, minXP, maxXP

        if isBloody then
            minSkills = BurdJournals.getSandboxOption("BloodyJournalMinSkills") or 2
            maxSkills = BurdJournals.getSandboxOption("BloodyJournalMaxSkills") or 4
            minXP = BurdJournals.getSandboxOption("BloodyJournalMinXP") or 50
            maxXP = BurdJournals.getSandboxOption("BloodyJournalMaxXP") or 150
        else
            minSkills = BurdJournals.getSandboxOption("WornJournalMinSkills") or 1
            maxSkills = BurdJournals.getSandboxOption("WornJournalMaxSkills") or 2
            minXP = BurdJournals.getSandboxOption("WornJournalMinXP") or 25
            maxXP = BurdJournals.getSandboxOption("WornJournalMaxXP") or 75
        end

        local numSkills = ZombRand(minSkills, maxSkills + 1)
        local skills = {}
        local availableSkills = BurdJournals.getAvailableSkills and BurdJournals.getAvailableSkills() or
                                {"Carpentry", "Cooking", "Farming", "Fishing", "Foraging", "Mechanics", "Electricity"}

        for i = 1, numSkills do
            if #availableSkills > 0 then
                local idx = ZombRand(1, #availableSkills + 1)
                local skill = availableSkills[idx]
                table.remove(availableSkills, idx)
                skills[skill] = {
                    xp = ZombRand(minXP, maxXP + 1),
                    level = 0
                }
            end
        end

        modData.BurdJournals.skills = skills
        modData.BurdJournals.claimedSkills = {}

        if isBloody then
            local traitChance = BurdJournals.getSandboxOption("BloodyJournalTraitChance") or 15
            if ZombRand(100) < traitChance then
                local grantableTraits = (BurdJournals.getGrantableTraits and BurdJournals.getGrantableTraits()) or
                                        BurdJournals.GRANTABLE_TRAITS or {
                    "Brave", "Organized", "FastLearner", "Wakeful", "Lucky",
                    "LightEater", "Dextrous", "Graceful", "Inconspicuous", "LowThirst"
                }
                local traits = {}
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
                modData.BurdJournals.traits = traits
                modData.BurdJournals.claimedTraits = {}

            end

            -- Generate recipes for bloody journals
            local recipeChance = BurdJournals.getSandboxOption("BloodyJournalRecipeChance") or 35
            local recipeRoll = ZombRand(100)
            BurdJournals.debugPrint("[BurdJournals] Server init Bloody: recipeChance=" .. recipeChance .. ", roll=" .. recipeRoll)
            if recipeRoll < recipeChance then
                local maxRecipes = BurdJournals.getSandboxOption("BloodyJournalMaxRecipes") or 2
                local numRecipes = ZombRand(1, maxRecipes + 1)
                BurdJournals.debugPrint("[BurdJournals] Server init Bloody: Generating " .. numRecipes .. " recipes")
                local recipes = BurdJournals.generateRandomRecipes(numRecipes)
                local recipeCount = 0
                if recipes then
                    for _ in pairs(recipes) do recipeCount = recipeCount + 1 end
                end
                BurdJournals.debugPrint("[BurdJournals] Server init Bloody: Generated " .. recipeCount .. " recipes")
                if recipeCount > 0 then
                    modData.BurdJournals.recipes = recipes
                    modData.BurdJournals.claimedRecipes = {}
                end
            end
        elseif isWorn then
            -- Generate recipes for worn journals too
            local recipeChance = BurdJournals.getSandboxOption("WornJournalRecipeChance") or 20
            local recipeRoll = ZombRand(100)
            BurdJournals.debugPrint("[BurdJournals] Server init Worn: recipeChance=" .. recipeChance .. ", roll=" .. recipeRoll)
            if recipeRoll < recipeChance then
                local maxRecipes = BurdJournals.getSandboxOption("WornJournalMaxRecipes") or 1
                local numRecipes = ZombRand(1, maxRecipes + 1)
                BurdJournals.debugPrint("[BurdJournals] Server init Worn: Generating " .. numRecipes .. " recipes")
                local recipes = BurdJournals.generateRandomRecipes(numRecipes)
                local recipeCount = 0
                if recipes then
                    for _ in pairs(recipes) do recipeCount = recipeCount + 1 end
                end
                BurdJournals.debugPrint("[BurdJournals] Server init Worn: Generated " .. recipeCount .. " recipes")
                if recipeCount > 0 then
                    modData.BurdJournals.recipes = recipes
                    modData.BurdJournals.claimedRecipes = {}
                end
            end
        end

        modData.BurdJournals.author = BurdJournals.generateRandomName and BurdJournals.generateRandomName() or "Unknown Survivor"
        modData.BurdJournals.isWritten = true
    end

    if journal.transmitModData then
        journal:transmitModData()

    end

    if BurdJournals.updateJournalName then
        BurdJournals.updateJournalName(journal)
    end

    BurdJournals.Server.sendToClient(player, "journalInitialized", {
        uuid = uuid,
        itemType = itemType,
        skillCount = modData.BurdJournals.skills and BurdJournals.countTable(modData.BurdJournals.skills) or 0,
        requestId = args.requestId
    })
end

function BurdJournals.Server.handleLogSkills(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.isBlankJournal(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal already has content."})
        return
    end

    if BurdJournals.getSandboxOption("RequirePenToWrite") then
        local pen = BurdJournals.findWritingTool(player)
        if not pen then
            BurdJournals.Server.sendToClient(player, "error", {message = "You need a pen or pencil to write."})
            return
        end
        local usesPerLog = BurdJournals.getSandboxOption("PenUsesPerLog") or 1
        BurdJournals.consumeItemUses(pen, usesPerLog, player)
    end

    local journalContent = BurdJournals.collectAllPlayerData(player)
    local playerJournalContext = {isPlayerCreated = true}

    local selectedSkills = args.skills
    if BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(selectedSkills) then
        local filteredSkills = {}
        for skillName, _ in pairs(selectedSkills) do
            local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(playerJournalContext, skillName)
            if enabledForJournal and journalContent.skills[skillName] then
                filteredSkills[skillName] = journalContent.skills[skillName]
            end
        end
        journalContent.skills = filteredSkills
    elseif journalContent.skills and BurdJournals.isSkillEnabledForJournal then
        for skillName, _ in pairs(journalContent.skills) do
            if not BurdJournals.isSkillEnabledForJournal(playerJournalContext, skillName) then
                journalContent.skills[skillName] = nil
            end
        end
    end

    if journalContent.skills then
        for _, skillData in pairs(journalContent.skills) do
            if type(skillData) == "table" then
                local netXP = math.max(0, tonumber(skillData.xp) or 0)
                local rawXP = math.max(netXP, tonumber(skillData.rawXP) or netXP)
                local vhsExcludedXP = tonumber(skillData.vhsExcludedXP)
                if vhsExcludedXP == nil then
                    vhsExcludedXP = math.max(0, rawXP - netXP)
                else
                    vhsExcludedXP = math.max(0, vhsExcludedXP)
                end
                if vhsExcludedXP > rawXP then
                    vhsExcludedXP = rawXP
                end
                skillData.xp = netXP
                skillData.rawXP = rawXP
                skillData.vhsExcludedXP = vhsExcludedXP
            end
        end
    end

    local inventory = player:getInventory()
    inventory:Remove(journal)
    sendRemoveItemFromContainer(inventory, journal)

    local filledJournal = inventory:AddItem("BurdJournals.FilledSurvivalJournal")
    if filledJournal then
        local modData = filledJournal:getModData()
        -- Track whether baseline was enforced when recording
        -- This affects how XP is applied on claim (add mode vs set mode)
        local baselineEnforced = BurdJournals.shouldEnforceBaseline and BurdJournals.shouldEnforceBaseline(player) or false

        modData.BurdJournals = {
            author = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname(),
            ownerUsername = player:getUsername(),
            ownerSteamId = BurdJournals.getPlayerSteamId(player),
            ownerCharacterName = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname(),
            timestamp = getGameTime():getWorldAgeHours(),
            uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
                or ("journal-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(filledJournal:getID())),
            readCount = 0,
            readSessionCount = 0,
            currentSessionReadCount = 0,
            skillReadCounts = {},
            migrationSchemaVersion = tonumber(BurdJournals.MIGRATION_SCHEMA_VERSION) or 0,

            isWorn = false,
            isBloody = false,
            wasFromWorn = inheritedWasFromWorn,
            wasFromBloody = inheritedWasFromBloody,
            wasRestored = inheritedWasRestored,
            restoredBy = inheritedRestoredBy,
            isPlayerCreated = true,

            -- XP mode tracking: if baseline was enforced, XP values are deltas (earned XP)
            -- If baseline was NOT enforced, XP values are absolute (total XP)
            recordedWithBaseline = baselineEnforced,

            contributors = {},

            skills = journalContent.skills,
            traits = journalContent.traits,
        }
        BurdJournals.updateJournalName(filledJournal)
        BurdJournals.updateJournalIcon(filledJournal)

        if filledJournal.transmitModData then
            filledJournal:transmitModData()
            BurdJournals.debugPrint("[BurdJournals] Server: transmitModData called for filled journal in handleLogSkills")
        end

        sendAddItemToContainer(inventory, filledJournal)
        BurdJournals.debugPrint("[BurdJournals] Server: sendAddItemToContainer called for filled journal in handleLogSkills")
    end

    BurdJournals.Server.sendToClient(player, "logSuccess", {})
end

function BurdJournals.Server.handleRecordProgress(player, args)
    BurdJournals.debugPrint("[BurdJournals] SERVER handleRecordProgress ENTRY")
    BurdJournals.debugPrint("[BurdJournals] Server: handleRecordProgress CALLED, player=" .. tostring(player and player:getUsername() or "nil"))

    if not args or not args.journalId then
        print("[BurdJournals] SERVER handleRecordProgress ERROR: no args or journalId")
        BurdJournals.debugPrint("[BurdJournals] Server: handleRecordProgress - Invalid request (no args or journalId)")
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] SERVER handleRecordProgress: journalId=" .. tostring(args.journalId))
    BurdJournals.debugPrint("[BurdJournals] Server: handleRecordProgress - journalId=" .. tostring(args.journalId))

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        print("[BurdJournals] SERVER handleRecordProgress ERROR: Journal not found for ID " .. tostring(args.journalId))
        BurdJournals.debugPrint("[BurdJournals] Server: handleRecordProgress - Journal not found for ID " .. tostring(args.journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] SERVER handleRecordProgress: Journal found OK")
    BurdJournals.debugPrint("[BurdJournals] Server: handleRecordProgress - Journal found: " .. tostring(journal:getFullType()))

    BurdJournals.debugPrint("[BurdJournals] SERVER handleRecordProgress: Processing payload...")

    local modData = journal:getModData()
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    if not modData.BurdJournals.skills then
        modData.BurdJournals.skills = {}
    end
    if not modData.BurdJournals.traits then
        modData.BurdJournals.traits = {}
    end
    if not modData.BurdJournals.stats then
        modData.BurdJournals.stats = {}
    end
    if not modData.BurdJournals.recipes then
        modData.BurdJournals.recipes = {}
    end
    if type(modData.BurdJournals.uuid) ~= "string" or modData.BurdJournals.uuid == "" then
        modData.BurdJournals.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
            or ("journal-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
    end

    local skillsRecorded = 0
    local traitsRecorded = 0
    local statsRecorded = 0
    local recipesRecorded = 0
    local skillNames = {}
    local traitNames = {}
    local recipeNames = {}

    -- Debug: Log baseline state
    local useBaseline = BurdJournals.shouldEnforceBaseline and BurdJournals.shouldEnforceBaseline(player) or false
    local hasBaselineCaptured = BurdJournals.hasBaselineCaptured and BurdJournals.hasBaselineCaptured(player) or false
    local isBaselineBypassed = BurdJournals.isBaselineBypassed and BurdJournals.isBaselineBypassed(player) or false
    BurdJournals.debugPrint("[BurdJournals] handleRecordProgress: useBaseline=" .. tostring(useBaseline) .. ", hasBaselineCaptured=" .. tostring(hasBaselineCaptured) .. ", isBaselineBypassed=" .. tostring(isBaselineBypassed))

    -- Persist recording mode for correct future claim semantics.
    -- If this is the first write (or the journal is still empty), bind mode to current baseline policy.
    if modData.BurdJournals.recordedWithBaseline == nil then
        modData.BurdJournals.recordedWithBaseline = useBaseline
    else
        local hasExistingSkills = BurdJournals.countTable(modData.BurdJournals.skills or {}) > 0
        if not hasExistingSkills then
            modData.BurdJournals.recordedWithBaseline = useBaseline
        end
    end

    -- Count incoming items (before validation)
    local debugInSkills = args.skills and BurdJournals.countTable(args.skills) or 0
    local debugInTraits = args.traits and BurdJournals.countTable(args.traits) or 0
    local debugInRecipes = args.recipes and BurdJournals.countTable(args.recipes) or 0
    BurdJournals.debugPrint("[BurdJournals] handleRecordProgress: Incoming skills=" .. debugInSkills .. ", traits=" .. debugInTraits .. ", recipes=" .. debugInRecipes)

    local validatedSkills = BurdJournals.Server.validateSkillPayload(args.skills, player)
    local validatedTraits = BurdJournals.Server.validateTraitPayload(args.traits, player)
    local validatedStats = BurdJournals.Server.validateStatsPayload(args.stats, player)
    local validatedRecipes = BurdJournals.Server.validateRecipePayload(args.recipes, player)

    -- Debug: Log validated counts
    local validSkillCount = validatedSkills and BurdJournals.countTable(validatedSkills) or 0
    local validTraitCount = validatedTraits and BurdJournals.countTable(validatedTraits) or 0
    local validStatCount = validatedStats and BurdJournals.countTable(validatedStats) or 0
    local validRecipeCount = validatedRecipes and BurdJournals.countTable(validatedRecipes) or 0
    BurdJournals.debugPrint("[BurdJournals] handleRecordProgress: Validated skills=" .. validSkillCount .. ", traits=" .. validTraitCount .. ", stats=" .. validStatCount .. ", recipes=" .. validRecipeCount)

    if BurdJournals.getSandboxOption("RequirePenToWrite") then
        local totalEntries = validSkillCount + validTraitCount + validStatCount + validRecipeCount
        if totalEntries > 0 then
            BurdJournals.debugPrint("[BurdJournals] SERVER handleRecordProgress: Pen required for " .. tostring(totalEntries) .. " entries")
            local pen = BurdJournals.findWritingTool(player)
            if not pen then
                print("[BurdJournals] SERVER handleRecordProgress ERROR: No pen found!")
                BurdJournals.Server.sendToClient(player, "error", {message = "You need a pen or pencil to write."})
                return
            end
            local usesPerLog = BurdJournals.getSandboxOption("PenUsesPerLog") or 1
            if usesPerLog < 1 then usesPerLog = 1 end
            BurdJournals.consumeItemUses(pen, usesPerLog * totalEntries, player)
        end
    end

    local limits = BurdJournals.Limits or {}
    local existingSkillCount = 0
    local existingTraitCount = 0
    local existingRecipeCount = 0
    for _ in pairs(modData.BurdJournals.skills) do existingSkillCount = existingSkillCount + 1 end
    for _ in pairs(modData.BurdJournals.traits) do existingTraitCount = existingTraitCount + 1 end
    for _ in pairs(modData.BurdJournals.recipes) do existingRecipeCount = existingRecipeCount + 1 end

    local incomingSkillCount = 0
    local incomingTraitCount = 0
    local incomingRecipeCount = 0
    if validatedSkills then for _ in pairs(validatedSkills) do incomingSkillCount = incomingSkillCount + 1 end end
    if validatedTraits then for _ in pairs(validatedTraits) do incomingTraitCount = incomingTraitCount + 1 end end
    if validatedRecipes then for _ in pairs(validatedRecipes) do incomingRecipeCount = incomingRecipeCount + 1 end end

    local maxSkills = limits.MAX_SKILLS or 50
    local maxTraits = limits.MAX_TRAITS or 100
    local maxRecipes = limits.MAX_RECIPES or 200

    if existingSkillCount + incomingSkillCount > maxSkills then
        print("[BurdJournals] SERVER handleRecordProgress ERROR: Skill limit reached")
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal skill limit reached (" .. maxSkills .. " max)."})
        return
    end
    if existingTraitCount + incomingTraitCount > maxTraits then
        print("[BurdJournals] SERVER handleRecordProgress ERROR: Trait limit reached")
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal trait limit reached (" .. maxTraits .. " max)."})
        return
    end
    if existingRecipeCount + incomingRecipeCount > maxRecipes then
        print("[BurdJournals] SERVER handleRecordProgress ERROR: Recipe limit reached")
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal recipe limit reached (" .. maxRecipes .. " max)."})
        return
    end
    BurdJournals.debugPrint("[BurdJournals] SERVER handleRecordProgress: Limits OK, recording data...")

    if validatedSkills then
        for skillName, skillData in pairs(validatedSkills) do
            local existingSkill = modData.BurdJournals.skills[skillName]
            local existingXP = existingSkill and tonumber(existingSkill.xp) or 0
            local incomingXP = math.max(0, tonumber(skillData.xp) or 0)
            local incomingRawXP = math.max(incomingXP, tonumber(skillData.rawXP) or incomingXP)
            local incomingVhsExcludedXP = tonumber(skillData.vhsExcludedXP)
            if incomingVhsExcludedXP == nil then
                incomingVhsExcludedXP = math.max(0, incomingRawXP - incomingXP)
            else
                incomingVhsExcludedXP = math.max(0, incomingVhsExcludedXP)
            end
            if incomingVhsExcludedXP > incomingRawXP then
                incomingVhsExcludedXP = incomingRawXP
            end

            local shouldUpdate = incomingXP > existingXP
            if not shouldUpdate and incomingXP == existingXP then
                local existingRawXP = math.max(existingXP, existingSkill and tonumber(existingSkill.rawXP) or existingXP)
                local existingVhsExcludedXP = existingSkill and tonumber(existingSkill.vhsExcludedXP)
                if existingVhsExcludedXP == nil then
                    existingVhsExcludedXP = math.max(0, existingRawXP - existingXP)
                else
                    existingVhsExcludedXP = math.max(0, existingVhsExcludedXP)
                end
                if existingVhsExcludedXP > existingRawXP then
                    existingVhsExcludedXP = existingRawXP
                end
                shouldUpdate = (incomingRawXP ~= existingRawXP) or (incomingVhsExcludedXP ~= existingVhsExcludedXP)
            end

            if shouldUpdate then
                modData.BurdJournals.skills[skillName] = {
                    xp = incomingXP,
                    level = skillData.level,
                    rawXP = incomingRawXP,
                    vhsExcludedXP = incomingVhsExcludedXP
                }
                skillsRecorded = skillsRecorded + 1
                table.insert(skillNames, skillName)
            end
        end
    end

    if validatedTraits then
        for traitId, _ in pairs(validatedTraits) do
            if not modData.BurdJournals.traits[traitId] then
                modData.BurdJournals.traits[traitId] = true
                traitsRecorded = traitsRecorded + 1
                table.insert(traitNames, traitId)
            end
        end
    end

    if validatedStats then
        for statId, statData in pairs(validatedStats) do

            modData.BurdJournals.stats[statId] = {
                value = statData.value
            }
            statsRecorded = statsRecorded + 1
        end
    end

    if validatedRecipes then
        for recipeName, _ in pairs(validatedRecipes) do
            if not modData.BurdJournals.recipes[recipeName] then
                modData.BurdJournals.recipes[recipeName] = true
                recipesRecorded = recipesRecorded + 1
                table.insert(recipeNames, recipeName)
            end
        end
    end

    local playerSteamId = BurdJournals.getPlayerSteamId(player)
    local playerCharName = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname()

    if not modData.BurdJournals.ownerSteamId then

        modData.BurdJournals.author = playerCharName
        modData.BurdJournals.ownerUsername = player:getUsername()
        modData.BurdJournals.ownerSteamId = playerSteamId
        modData.BurdJournals.ownerCharacterName = playerCharName
        modData.BurdJournals.contributors = {}
        BurdJournals.debugPrint("[BurdJournals] Journal owner set to: " .. playerCharName .. " (" .. playerSteamId .. ")")
    else

        if modData.BurdJournals.ownerSteamId ~= playerSteamId then

            if not modData.BurdJournals.contributors then
                modData.BurdJournals.contributors = {}
            end

            modData.BurdJournals.contributors[playerSteamId] = {
                characterName = playerCharName,
                username = player:getUsername(),
                addedAt = getGameTime():getWorldAgeHours()
            }
            BurdJournals.debugPrint("[BurdJournals] Added contributor: " .. playerCharName .. " (" .. playerSteamId .. ")")
        else

            if modData.BurdJournals.ownerCharacterName ~= playerCharName then
                local oldName = modData.BurdJournals.ownerCharacterName or "(none)"
                BurdJournals.debugPrint("[BurdJournals] Owner character name updated: " .. oldName .. " -> " .. playerCharName)
                modData.BurdJournals.ownerCharacterName = playerCharName
                modData.BurdJournals.author = playerCharName
            end
        end
    end

    modData.BurdJournals.lastModified = getGameTime():getWorldAgeHours()
    modData.BurdJournals.isPlayerCreated = true
    modData.BurdJournals.isWritten = true

    local journalType = journal:getFullType()
    local isBlank = string.find(journalType, "Blank") ~= nil
    local totalItems = BurdJournals.countTable(modData.BurdJournals.skills) + BurdJournals.countTable(modData.BurdJournals.traits) + BurdJournals.countTable(modData.BurdJournals.stats) + BurdJournals.countTable(modData.BurdJournals.recipes)

    BurdJournals.debugPrint("[BurdJournals] handleRecordProgress: journalType=" .. tostring(journalType) .. ", isBlank=" .. tostring(isBlank) .. ", totalItems=" .. tostring(totalItems))

    local newJournalId = nil

    if isBlank and totalItems > 0 then
        BurdJournals.debugPrint("[BurdJournals] Converting blank journal to filled...")

        local inventory = journal:getContainer()
        if inventory then
            BurdJournals.debugPrint("[BurdJournals] Got inventory container: " .. tostring(inventory))

            local savedData = BurdJournals.Server.deepCopy(modData.BurdJournals)
            if not savedData then
                print("[BurdJournals] ERROR: Failed to deep copy journal data!")
                savedData = {}
            end

            -- Reset worn/bloody flags - preserve origin for "Restored" status logic
            -- The sandbox option controls display and dissolution behavior at runtime
            if savedData.isWorn then
                savedData.wasFromWorn = true
                savedData.isWorn = false
                BurdJournals.debugPrint("[BurdJournals] Reset isWorn flag, set wasFromWorn=true")
            end
            if savedData.isBloody then
                savedData.wasFromBloody = true
                savedData.isBloody = false
                BurdJournals.debugPrint("[BurdJournals] Reset isBloody flag, set wasFromBloody=true")
            end

            inventory:Remove(journal)
            sendRemoveItemFromContainer(inventory, journal)
            BurdJournals.debugPrint("[BurdJournals] Removed blank journal and notified clients")

            local filledJournal = inventory:AddItem("BurdJournals.FilledSurvivalJournal")
            if filledJournal then
                BurdJournals.debugPrint("[BurdJournals] Created filled journal: " .. tostring(filledJournal:getID()))

                local newModData = filledJournal:getModData()
                newModData.BurdJournals = savedData

                BurdJournals.updateJournalName(filledJournal)
                BurdJournals.updateJournalIcon(filledJournal)

                -- Compact journal data to reduce ModData size
                if BurdJournals.compactJournalData then
                    BurdJournals.compactJournalData(filledJournal)
                end

                if filledJournal.transmitModData then
                    filledJournal:transmitModData()
                    BurdJournals.debugPrint("[BurdJournals] transmitModData called on filled journal")
                end

                sendAddItemToContainer(inventory, filledJournal)
                BurdJournals.debugPrint("[BurdJournals] sendAddItemToContainer called for filled journal")

                newJournalId = filledJournal:getID()
                BurdJournals.debugPrint("[BurdJournals] Conversion complete, newJournalId=" .. tostring(newJournalId))
            else
                print("[BurdJournals] ERROR: Failed to create filled journal!")
            end
        else
            print("[BurdJournals] ERROR: No inventory container found!")
        end
    else
        BurdJournals.debugPrint("[BurdJournals] Not converting (isBlank=" .. tostring(isBlank) .. ", totalItems=" .. tostring(totalItems) .. ")")

        BurdJournals.updateJournalName(journal)
        BurdJournals.updateJournalIcon(journal)

        -- Compact journal data to reduce ModData size
        if BurdJournals.compactJournalData then
            BurdJournals.compactJournalData(journal)
        end

        if journal.transmitModData then
            journal:transmitModData()
            BurdJournals.debugPrint("[BurdJournals] transmitModData called on existing journal")
        end
    end

    local finalJournal = newJournalId and BurdJournals.findItemById(player, newJournalId) or journal
    local journalData = nil
    local finalJournalId = newJournalId or (journal and journal:getID())

    local includeJournalData = true

    if includeJournalData and finalJournal then
        local modData = finalJournal:getModData()
        if modData and modData.BurdJournals then

            journalData = BurdJournals.Server.deepCopy(modData.BurdJournals)
        end
    end

    BurdJournals.debugPrint("[BurdJournals] Sending recordSuccess response, newJournalId=" .. tostring(newJournalId) .. ", journalId=" .. tostring(finalJournalId) .. ", includeJournalData=" .. tostring(includeJournalData))
    BurdJournals.Server.sendToClient(player, "recordSuccess", {
        skillsRecorded = skillsRecorded,
        traitsRecorded = traitsRecorded,
        statsRecorded = statsRecorded,
        recipesRecorded = recipesRecorded,
        skillNames = skillNames,
        traitNames = traitNames,
        recipeNames = recipeNames,
        newJournalId = newJournalId,
        journalId = finalJournalId,
        journalData = journalData
    })
end

function BurdJournals.Server.handleSyncJournalData(player, args)
    if not args or not args.journalId then
        BurdJournals.debugPrint("[BurdJournals] handleSyncJournalData: Invalid request (no journalId)")
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        BurdJournals.debugPrint("[BurdJournals] handleSyncJournalData: Journal not found: " .. tostring(args.journalId))
        return
    end

    BurdJournals.Server.updateJournalUUIDIndex(journal, player, "syncJournalData")
    if BurdJournals.Server.seedDebugSnapshotFromLiveJournal then
        BurdJournals.Server.seedDebugSnapshotFromLiveJournal(journal, player, "syncJournalData")
    end

    BurdJournals.debugPrint("[BurdJournals] handleSyncJournalData: Syncing journal " .. tostring(args.journalId))

    if journal.transmitModData then
        journal:transmitModData()
        BurdJournals.debugPrint("[BurdJournals] handleSyncJournalData: transmitModData called for journal " .. tostring(args.journalId))
    end

    -- Send back the journal data so client can update UI
    local modData = journal:getModData()
    if modData and modData.BurdJournals then
        local journalData = BurdJournals.Server.deepCopy(modData.BurdJournals)
        BurdJournals.Server.sendToClient(player, "syncSuccess", {
            journalId = args.journalId,
            journalData = journalData
        })
    end
end

function BurdJournals.Server.handleLearnSkills(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.canSetXP(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Cannot learn from this journal."})
        return
    end

    local modData = journal:getModData()
    if not modData.BurdJournals or not modData.BurdJournals.skills then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no skill data."})
        return
    end

    local selectedSkills = args.skills
    local journalSkills = modData.BurdJournals.skills

    local skillsToSet = {}
    local skillsApplied = 0
    local normalizedAny = false
    local consumedAny = false
    local claimSessionId = args and args.claimSessionId
    local hasSelectedSkills = BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(selectedSkills)
    for skillName, storedData in pairs(journalSkills) do

        if not hasSelectedSkills or selectedSkills[skillName] then
            local normalizedXP = tonumber(storedData.xp) or 0
            local normalizedLevel = tonumber(storedData.level) or 0
            local normalized = false
            if BurdJournals.normalizeLegacySkillEntry then
                normalizedXP, normalizedLevel, normalized = BurdJournals.normalizeLegacySkillEntry(skillName, storedData, modData.BurdJournals.recordedWithBaseline)
                if normalized then
                    storedData.xp = normalizedXP
                    storedData.level = normalizedLevel
                    normalizedAny = true
                end
            end

            local multiplier = 1.0
            if BurdJournals.consumeJournalClaimRead then
                multiplier = BurdJournals.consumeJournalClaimRead(modData.BurdJournals, skillName, claimSessionId, player)
                consumedAny = true
            end
            local effectiveRecordedXP = math.floor(normalizedXP * multiplier)
            local targetXP = effectiveRecordedXP
            if BurdJournals.Server.getSkillClaimTargetXP then
                targetXP = BurdJournals.Server.getSkillClaimTargetXP(player, modData.BurdJournals, skillName, effectiveRecordedXP)
            end
            -- Compute level from XP instead of reading stored level (for backward compatibility)
            -- Pass skillName for proper Fitness/Strength XP thresholds
            local computedLevel = normalizedLevel > 0 and normalizedLevel
                or (BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(targetXP, skillName))
                or math.floor(targetXP / 75)
            skillsToSet[skillName] = {
                xp = targetXP,
                level = computedLevel,
                mode = "set"
            }

            -- Apply XP directly on server using vanilla addXp function (42.13.2+ compatible)
            -- For "set" mode, we need to calculate the difference
            local perk = BurdJournals.getPerkByName(skillName)
            if perk and addXp then
                local currentXP = player:getXp():getXP(perk)
                if targetXP > currentXP then
                    local xpToAdd = targetXP - currentXP
                    -- AddXP adds the specified amount directly for all skills
                    BurdJournals.debugPrint("[BurdJournals] Server: LearnSkills - Applying " .. tostring(xpToAdd) .. " XP to " .. skillName .. " via addXp()")
                    addXp(player, perk, xpToAdd)
                    skillsApplied = skillsApplied + 1
                end
            end
        end
    end

    if (normalizedAny or consumedAny) and journal.transmitModData then
        journal:transmitModData()
    end
    if consumedAny and BurdJournals.captureJournalDRState then
        BurdJournals.captureJournalDRState(journal, "learnSkills", player)
    end

    -- Fallback: send to client if addXp not available (SP mode)
    if not addXp then
        BurdJournals.debugPrint("[BurdJournals] Server: LearnSkills fallback - sending applyXP to client")
        BurdJournals.Server.sendToClient(player, "applyXP", {skills = skillsToSet, mode = "set"})
    else
        -- Notify client of success (for UI update)
        BurdJournals.Server.sendToClient(player, "learnSuccess", {skillCount = skillsApplied})
    end
end

function BurdJournals.Server.handleClaimSkill(player, args)
    BurdJournals.debugPrint("[BurdJournals] Server: handleClaimSkill called - skillName=" .. tostring(args and args.skillName) .. ", journalId=" .. tostring(args and args.journalId))

    if not args or not args.skillName then

        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local skillName = args.skillName

    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.canSetXP(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Cannot claim set XP from this journal type."})
        return
    end

    local canClaim, reason = BurdJournals.canPlayerClaimFromJournal(player, journal)
    if not canClaim then
        BurdJournals.Server.sendToClient(player, "error", {message = reason or "Permission denied."})
        return
    end

    local modData = journal:getModData()
    local journalData = modData.BurdJournals

    if not journalData or not journalData.skills then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no skill data."})
        return
    end

    -- Patch/update safety: restore DR counters if item ModData lost them.
    if BurdJournals.restoreJournalDRStateIfMissing then
        BurdJournals.restoreJournalDRStateIfMissing(journal, "handleClaimSkill", player)
        journalData = modData.BurdJournals
    end

    if BurdJournals.isSkillEnabledForJournal and not BurdJournals.isSkillEnabledForJournal(journalData, skillName) then
        BurdJournals.Server.sendToClient(player, "error", {message = "That skill is disabled by sandbox settings for this journal."})
        return
    end

    if not journalData.skills[skillName] then
        print("[BurdJournals] Server ERROR: Skill '" .. skillName .. "' not found in journal")
        BurdJournals.Server.sendToClient(player, "error", {message = "Skill not found in journal."})
        return
    end

    -- Check if already claimed by this character (only for non-player journals)
    -- Player journals allow unlimited claims unless restricted by sandbox options
    local isPlayerJournal = journalData.isPlayerCreated == true
    if not isPlayerJournal and BurdJournals.hasCharacterClaimedSkill(journalData, player, skillName) then
        BurdJournals.debugPrint("[BurdJournals] Server: Skill '" .. skillName .. "' already claimed by this character from found journal, skipping")
        BurdJournals.Server.sendToClient(player, "claimSuccess", {
            skillName = skillName,
            xpAdded = 0,
            journalId = journalId,
            journalData = journalData,
            alreadyClaimed = true
        })
        return
    end

    local skillData = journalData.skills[skillName]
    local recordedXP = tonumber(skillData.xp) or 0
    local recordedLevel = tonumber(skillData.level) or 0
    local normalizedLegacy = false
    if BurdJournals.normalizeLegacySkillEntry then
        recordedXP, recordedLevel, normalizedLegacy = BurdJournals.normalizeLegacySkillEntry(skillName, skillData, journalData.recordedWithBaseline)
        if normalizedLegacy then
            skillData.xp = recordedXP
            skillData.level = recordedLevel
            journalData.skills[skillName] = skillData
            BurdJournals.debugPrint("[BurdJournals] Normalized legacy journal XP entry for " .. tostring(skillName) .. ": xp=" .. tostring(recordedXP) .. ", level=" .. tostring(recordedLevel))
        end
    end
    -- Compute level from XP instead of reading stored level (for backward compatibility)
    -- Pass skillName for proper Fitness/Strength XP thresholds
    if recordedLevel <= 0 then
        recordedLevel = (BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(recordedXP, skillName)) or math.floor(recordedXP / 75)
    end

    -- Diminishing returns are consumed on each claim read.
    local claimMultiplier, claimReadCount = 1.0, tonumber(journalData.readCount) or 0
    if BurdJournals.consumeJournalClaimRead then
        claimMultiplier, claimReadCount = BurdJournals.consumeJournalClaimRead(journalData, skillName, args and args.claimSessionId, player)
    else
        local recoveryMode = tonumber(BurdJournals.getSandboxOption("XPRecoveryMode")) or 1
        if recoveryMode == 2 then
            local firstRead = (tonumber(BurdJournals.getSandboxOption("DiminishingFirstRead")) or 100) / 100
            local decayRate = (tonumber(BurdJournals.getSandboxOption("DiminishingDecayRate")) or 10) / 100
            local minimum = (tonumber(BurdJournals.getSandboxOption("DiminishingMinimum")) or 10) / 100
            if claimReadCount == 0 then
                claimMultiplier = firstRead
            else
                claimMultiplier = math.max(minimum, firstRead - (decayRate * claimReadCount))
            end
            journalData.readCount = claimReadCount + 1
        end
    end
    local effectiveRecordedXP = math.max(0, math.floor(recordedXP * claimMultiplier))
    local claimTargetXP, baselineXPForClaim, baselineSuppressedForClaim = effectiveRecordedXP, 0, false
    if BurdJournals.Server.getSkillClaimTargetXP then
        claimTargetXP, baselineXPForClaim, baselineSuppressedForClaim = BurdJournals.Server.getSkillClaimTargetXP(player, journalData, skillName, effectiveRecordedXP)
    end
    local claimTargetLevel = recordedLevel
    if claimTargetXP > 0 then
        claimTargetLevel = (BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(claimTargetXP, skillName)) or claimTargetLevel
    end

    if journal.transmitModData then
        journal:transmitModData()
    end
    if BurdJournals.captureJournalDRState then
        BurdJournals.captureJournalDRState(journal, "claimSkill", player)
    end

    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        print("[BurdJournals] Server ERROR: Could not find perk for skill '" .. skillName .. "'")
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid skill: " .. skillName})
        return
    end

    -- Player journals always use SET mode (absolute target XP).
    -- For baseline-recorded journals, target XP is resolved as baseline + delta.
    local useAddMode = (not isPlayerJournal) and journalData.recordedWithBaseline == true
    -- isPlayerJournal already declared above

    -- Debug logging
    BurdJournals.debugPrint("[BurdJournals] Server ClaimSkill DEBUG:")
    BurdJournals.debugPrint("  - skillName: " .. tostring(skillName))
    BurdJournals.debugPrint("  - recordedXP: " .. tostring(recordedXP))
    BurdJournals.debugPrint("  - recordedLevel: " .. tostring(recordedLevel))
    BurdJournals.debugPrint("  - effectiveRecordedXP: " .. tostring(effectiveRecordedXP))
    BurdJournals.debugPrint("  - claimTargetXP: " .. tostring(claimTargetXP))
    BurdJournals.debugPrint("  - claimTargetLevel: " .. tostring(claimTargetLevel))
    BurdJournals.debugPrint("  - baselineXPForClaim: " .. tostring(baselineXPForClaim))
    BurdJournals.debugPrint("  - baselineSuppressedForClaim: " .. tostring(baselineSuppressedForClaim))
    BurdJournals.debugPrint("  - claimMultiplier: " .. tostring(claimMultiplier))
    BurdJournals.debugPrint("  - claimReadCount: " .. tostring(claimReadCount))
    BurdJournals.debugPrint("  - claimSessionId: " .. tostring(args and args.claimSessionId))
    BurdJournals.debugPrint("  - isPlayerCreated: " .. tostring(isPlayerJournal))
    BurdJournals.debugPrint("  - recordedWithBaseline: " .. tostring(journalData.recordedWithBaseline))
    BurdJournals.debugPrint("  - useAddMode: " .. tostring(useAddMode))

    if effectiveRecordedXP > 0 then
        local xpToApply = effectiveRecordedXP

        -- For "set" mode (absolute XP), cap at recorded value to prevent over-grant
        -- Player should end up with AT MOST the recorded XP, not more
        if not useAddMode then
            local currentXP = player:getXp():getXP(perk)
            local currentLevel = player:getPerkLevel(perk)
            BurdJournals.debugPrint("  - currentXP: " .. tostring(currentXP))
            BurdJournals.debugPrint("  - currentLevel: " .. tostring(currentLevel))
            if currentXP >= claimTargetXP then
                -- Player already has equal or more XP than recorded - nothing to grant
                -- Only mark as claimed for non-player journals (player journals allow unlimited claims)
                if not isPlayerJournal then
                    BurdJournals.markSkillClaimedByCharacter(journalData, player, skillName)
                end
                if journal.transmitModData then
                    journal:transmitModData()
                end
                BurdJournals.Server.sendToClient(player, "skillMaxed", {
                    skillName = skillName,
                    journalId = journalId,
                    journalData = journalData,
                    alreadyAtLevel = true,
                    message = "You already have this much XP in " .. skillName .. "."
                })
                -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
                -- Only dissolve non-player journals
                if not isPlayerJournal then
                    local freshJournal = BurdJournals.findItemById(player, journalId)
                    if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve and BurdJournals.shouldDissolve(freshJournal, player) then
                        BurdJournals.Server.dissolveJournal(player, freshJournal)
                    end
                end
                return
            end
            -- Only grant the difference to reach recorded XP
            xpToApply = claimTargetXP - currentXP
            BurdJournals.debugPrint("  - xpToApply (after SET calc): " .. tostring(xpToApply))
        end

        BurdJournals.debugPrint("  - FINAL xpToApply: " .. tostring(xpToApply))

        -- Apply XP directly using player:getXp():AddXP() with useMultipliers=false
        -- This bypasses sandbox XP multiplier settings to give exact recorded XP
        -- (Same approach as production version - no setXPToLevel, no passive multiplier)
        -- Signature: AddXP(perk, amount, addToKnownRecipes, useMultipliers, isPassive, checkLevelUp)
        -- IMPORTANT: checkLevelUp MUST be true to recalculate level from new XP!
        local xpObj = player:getXp()
        local success = false
        if xpObj and xpObj.AddXP then
            xpObj:AddXP(perk, xpToApply, false, false, false, true)
            success = true
        end
        if success then
            BurdJournals.debugPrint("[BurdJournals] Server: Applied " .. tostring(xpToApply) .. " XP to " .. skillName .. " via AddXP (no multipliers)")
        else
            -- Fallback to addXp if AddXP fails
            if addXp then
                BurdJournals.debugPrint("[BurdJournals] Server: Fallback to addXp() for " .. skillName)
                addXp(player, perk, xpToApply)
            else
                -- Last resort - send to client
                BurdJournals.debugPrint("[BurdJournals] Server: Fallback - sending applyXP to client for " .. skillName)
                BurdJournals.Server.sendToClient(player, "applyXP", {
                    skills = {
                        [skillName] = {
                            xp = xpToApply,
                            mode = "add"
                        }
                    },
                    mode = "add"
                })
            end
        end
        
        -- NOTE: Don't call syncXp here - it disrupts batch command processing
        -- Client will request sync at end of batch via requestXpSync command

        -- Get player state AFTER XP application for debug comparison
        local levelAfter = player:getPerkLevel(perk)
        local xpAfter = xpObj:getXP(perk)
        
        BurdJournals.debugPrint("================================================================================")
        BurdJournals.debugPrint("[BurdJournals CLAIM RESULT] Skill: " .. tostring(skillName))
        BurdJournals.debugPrint("[BurdJournals CLAIM RESULT]   JOURNAL EXPECTED: Level " .. tostring(claimTargetLevel) .. ", XP " .. tostring(claimTargetXP))
        BurdJournals.debugPrint("[BurdJournals CLAIM RESULT]   PLAYER AFTER:     Level " .. tostring(levelAfter) .. ", XP " .. tostring(xpAfter))
        BurdJournals.debugPrint("[BurdJournals CLAIM RESULT]   XP Applied: " .. tostring(xpToApply))
        if levelAfter < claimTargetLevel then
            print("[BurdJournals CLAIM RESULT]   WARNING: Player level (" .. levelAfter .. ") is LESS than recorded level (" .. claimTargetLevel .. ")!")
        elseif levelAfter > claimTargetLevel then
            BurdJournals.debugPrint("[BurdJournals CLAIM RESULT]   NOTE: Player level (" .. levelAfter .. ") exceeds recorded level (" .. claimTargetLevel .. ")")
        else
            BurdJournals.debugPrint("[BurdJournals CLAIM RESULT]   SUCCESS: Player reached recorded level " .. claimTargetLevel)
        end
        BurdJournals.debugPrint("================================================================================")

        BurdJournals.markSkillClaimedByCharacter(journalData, player, skillName)

        if journal.transmitModData then
            journal:transmitModData()
        end

        BurdJournals.Server.sendToClient(player, "claimSuccess", {
            skillName = skillName,
            xpAdded = xpToApply,  -- Send actual XP added for client-side instant feedback
            journalId = journalId,
            journalData = journalData,
            -- Include debug info for client
            debug_recordedLevel = recordedLevel,
            debug_recordedXP = recordedXP,
            debug_effectiveRecordedLevel = claimTargetLevel,
            debug_effectiveRecordedXP = effectiveRecordedXP,
            debug_targetXP = claimTargetXP,
            debug_baselineXP = baselineXPForClaim,
            debug_baselineSuppressed = baselineSuppressedForClaim,
            debug_claimMultiplier = claimMultiplier,
            debug_claimReadCount = claimReadCount,
            debug_levelAfter = levelAfter,
            debug_xpAfter = xpAfter,
        })
        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        BurdJournals.debugPrint("[BurdJournals] Server: Post-claim skill check - freshJournal=" .. tostring(freshJournal ~= nil) .. ", journalId=" .. tostring(journalId))
        if freshJournal then
            local isValid = BurdJournals.isValidItem(freshJournal)
            local hasShouldDissolve = BurdJournals.shouldDissolve ~= nil
            local shouldDis = hasShouldDissolve and BurdJournals.shouldDissolve(freshJournal, player)
            BurdJournals.debugPrint("[BurdJournals] Server: isValid=" .. tostring(isValid) .. ", hasShouldDissolve=" .. tostring(hasShouldDissolve) .. ", shouldDis=" .. tostring(shouldDis))
            if isValid and shouldDis then
                BurdJournals.debugPrint("[BurdJournals] Server: DISSOLVING JOURNAL after skill claim!")
                BurdJournals.Server.dissolveJournal(player, freshJournal)
            end
        end
    else
        -- Zero XP recorded - mark as claimed but no XP to add
        BurdJournals.markSkillClaimedByCharacter(journalData, player, skillName)
        if journal.transmitModData then
            journal:transmitModData()
        end
        BurdJournals.Server.sendToClient(player, "skillMaxed", {
            skillName = skillName,
            journalId = journalId,
            journalData = journalData,
            message = "No XP to claim from this skill."
        })
        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        BurdJournals.debugPrint("[BurdJournals] Server: Post-skillMaxed check - freshJournal=" .. tostring(freshJournal ~= nil) .. ", journalId=" .. tostring(journalId))
        if freshJournal then
            local isValid = BurdJournals.isValidItem(freshJournal)
            local hasShouldDissolve = BurdJournals.shouldDissolve ~= nil
            local shouldDis = hasShouldDissolve and BurdJournals.shouldDissolve(freshJournal, player)
            BurdJournals.debugPrint("[BurdJournals] Server: isValid=" .. tostring(isValid) .. ", hasShouldDissolve=" .. tostring(hasShouldDissolve) .. ", shouldDis=" .. tostring(shouldDis))
            if isValid and shouldDis then
                BurdJournals.debugPrint("[BurdJournals] Server: DISSOLVING JOURNAL after skillMaxed!")
                BurdJournals.Server.dissolveJournal(player, freshJournal)
            end
        end
    end
end

function BurdJournals.Server.handleClaimTrait(player, args)

    if not args or not args.traitId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local traitId = args.traitId
    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    local canClaim, reason = BurdJournals.canPlayerClaimFromJournal(player, journal)
    if not canClaim then
        BurdJournals.Server.sendToClient(player, "error", {message = reason or "Permission denied."})
        return
    end

    local modData = journal:getModData()
    local journalData = modData.BurdJournals

    if not journalData or not journalData.traits then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no trait data."})
        return
    end

    -- Check if traits are enabled for this journal type
    if not BurdJournals.isTraitEnabledForJournal(journalData, traitId) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Trait claiming is disabled for this journal type."})
        return
    end

    if not journalData.traits[traitId] then
        print("[BurdJournals] Server ERROR: Trait '" .. traitId .. "' not found in journal")
        BurdJournals.Server.sendToClient(player, "error", {message = "Trait not found in journal."})
        return
    end

    if BurdJournals.hasCharacterClaimedTrait(journalData, player, traitId) then
        BurdJournals.Server.sendToClient(player, "error", {message = "This trait has already been claimed."})
        return
    end

    if BurdJournals.playerHasTrait(player, traitId) then
        -- Mark as claimed even though player already has this trait (allows journal dissolution)
        BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)
        if journal.transmitModData then
            journal:transmitModData()
        end
        BurdJournals.Server.sendToClient(player, "traitAlreadyKnown", {
            traitId = traitId,
            journalId = journalId,
        })
        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve and BurdJournals.shouldDissolve(freshJournal, player) then
            BurdJournals.Server.dissolveJournal(player, freshJournal)
        end
        return
    end

    local traitWasAdded = BurdJournals.safeAddTrait(player, traitId)

    if traitWasAdded then

        BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)

        if journal.transmitModData then
            journal:transmitModData()
        end

        BurdJournals.Server.sendToClient(player, "claimSuccess", {
            traitId = traitId,
            journalId = journalId,
            journalData = journalData,
        })
        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        BurdJournals.debugPrint("[BurdJournals] Server: Post-trait claim check - freshJournal=" .. tostring(freshJournal ~= nil) .. ", journalId=" .. tostring(journalId))
        if freshJournal then
            local isValid = BurdJournals.isValidItem(freshJournal)
            local hasShouldDissolve = BurdJournals.shouldDissolve ~= nil
            local shouldDis = hasShouldDissolve and BurdJournals.shouldDissolve(freshJournal, player)
            BurdJournals.debugPrint("[BurdJournals] Server: isValid=" .. tostring(isValid) .. ", hasShouldDissolve=" .. tostring(hasShouldDissolve) .. ", shouldDis=" .. tostring(shouldDis))
            if isValid and shouldDis then
                BurdJournals.debugPrint("[BurdJournals] Server: DISSOLVING JOURNAL after trait claim!")
                BurdJournals.Server.dissolveJournal(player, freshJournal)
            end
        end
    else
        BurdJournals.Server.sendToClient(player, "error", {message = "Could not learn trait."})
    end
end

-- Server handler for claiming stats (zombie kills, hours survived) from journals
function BurdJournals.Server.handleClaimStat(player, args)
    if not args or not args.statId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local statId = args.statId
    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    local canClaim, reason = BurdJournals.canPlayerClaimFromJournal(player, journal)
    if not canClaim then
        BurdJournals.Server.sendToClient(player, "error", {message = reason or "Permission denied."})
        return
    end

    local modData = journal:getModData()
    local journalData = modData.BurdJournals

    if not journalData or not journalData.stats then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no stat data."})
        return
    end

    -- Validate that this stat can be absorbed
    if not BurdJournals.canAbsorbStat then
        BurdJournals.Server.sendToClient(player, "error", {message = "Stat absorption not available."})
        return
    end

    local canAbsorb, recordedValue, _, absorbReason = BurdJournals.canAbsorbStat(journalData, player, statId)
    if not canAbsorb then
        -- Convert reason codes to user-friendly messages
        local message = "Cannot absorb this stat."
        if absorbReason == "not_absorbable" then
            message = "This stat cannot be absorbed."
        elseif absorbReason == "already_claimed" then
            message = "Already claimed from this journal."
        elseif absorbReason == "no_benefit" then
            message = "Your current value is already higher or equal."
        end
        BurdJournals.Server.sendToClient(player, "error", {message = message})
        return
    end

    -- Server-authoritative value: always apply the recorded journal value.
    -- Never trust client-provided args.value for stat application.
    local statApplied = BurdJournals.applyStatAbsorption(player, statId, recordedValue)

    if statApplied then
        -- Mark the stat as claimed
        BurdJournals.markStatClaimedByCharacter(journalData, player, statId)

        if journal.transmitModData then
            journal:transmitModData()
        end

        BurdJournals.Server.sendToClient(player, "claimSuccess", {
            statId = statId,
            journalId = journalId,
            value = recordedValue,
            journalData = journalData,
        })

        -- Check for dissolution after claiming
        local freshJournal = BurdJournals.findItemById(player, journalId)
        BurdJournals.debugPrint("[BurdJournals] Server: Post-stat claim check - freshJournal=" .. tostring(freshJournal ~= nil) .. ", journalId=" .. tostring(journalId))
        if freshJournal then
            local isValid = BurdJournals.isValidItem(freshJournal)
            local hasShouldDissolve = BurdJournals.shouldDissolve ~= nil
            local shouldDis = hasShouldDissolve and BurdJournals.shouldDissolve(freshJournal, player)
            BurdJournals.debugPrint("[BurdJournals] Server: isValid=" .. tostring(isValid) .. ", hasShouldDissolve=" .. tostring(hasShouldDissolve) .. ", shouldDis=" .. tostring(shouldDis))
            if isValid and shouldDis then
                BurdJournals.debugPrint("[BurdJournals] Server: DISSOLVING JOURNAL after stat claim!")
                BurdJournals.Server.dissolveJournal(player, freshJournal)
            end
        end
    else
        BurdJournals.Server.sendToClient(player, "error", {message = "Could not apply stat."})
    end
end

function BurdJournals.Server.handleAbsorbSkill(player, args)
    if not args or not args.skillName then

        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local skillName = args.skillName

    local journal = BurdJournals.findItemById(player, journalId)

    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.canAbsorbXP(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Cannot absorb from this journal."})
        return
    end

    local modData = journal:getModData()

    if modData and BurdJournals.isDebug() then
        for k, v in pairs(modData) do
            BurdJournals.debugPrint("  - " .. tostring(k) .. " = " .. type(v))
        end
    end

    local journalData = modData.BurdJournals

    if not journalData then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no data."})
        return
    end

    if BurdJournals.isDebug() then
        for k, v in pairs(journalData) do
            local valueStr = tostring(v)
            if type(v) == "table" then
                valueStr = "table with " .. BurdJournals.countTable(v) .. " entries"
            end
            BurdJournals.debugPrint("  - " .. tostring(k) .. " = " .. valueStr)
        end
    end

    if not journalData.skills then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no skill data."})
        return
    end

    if BurdJournals.isSkillEnabledForJournal and not BurdJournals.isSkillEnabledForJournal(journalData, skillName) then
        BurdJournals.Server.sendToClient(player, "error", {message = "That skill is disabled by sandbox settings for this journal."})
        return
    end

    local skillCount = BurdJournals.countTable(journalData.skills)

    if BurdJournals.isDebug() then
        for skillKey, skillVal in pairs(journalData.skills) do
            if type(skillVal) == "table" then
                BurdJournals.debugPrint("  - '" .. tostring(skillKey) .. "': xp=" .. tostring(skillVal.xp) .. ", level=" .. tostring(skillVal.level))
            else
                BurdJournals.debugPrint("  - '" .. tostring(skillKey) .. "': INVALID (not a table, is " .. type(skillVal) .. ")")
            end
        end
    end

    if not journalData.skills[skillName] then
        print("[BurdJournals] Server ERROR: Skill '" .. tostring(skillName) .. "' not found in journal!")

        if BurdJournals.isDebug() then
            for k, _ in pairs(journalData.skills) do
                BurdJournals.debugPrint("  - '" .. tostring(k) .. "'")
            end
        end
        BurdJournals.Server.sendToClient(player, "error", {message = "Skill not found in journal."})
        return
    end

    if BurdJournals.hasCharacterClaimedSkill(journalData, player, skillName) then
        BurdJournals.Server.sendToClient(player, "error", {message = "This skill has already been claimed."})
        return
    end

    local skillData = journalData.skills[skillName]

    if type(skillData) ~= "table" then
        print("[BurdJournals] Server ERROR: skillData is not a table! It's: " .. type(skillData) .. " = " .. tostring(skillData))
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid skill data."})
        return
    end

    local baseXP = skillData.xp

    if baseXP == nil then
        if BurdJournals.isDebug() then
            for k, v in pairs(skillData) do
                BurdJournals.debugPrint("  - " .. tostring(k) .. " = " .. tostring(v))
            end
        end
        baseXP = 0
    end

    if type(baseXP) ~= "number" then

        baseXP = tonumber(baseXP) or 0
    end

    local journalMultiplier = tonumber(BurdJournals.getSandboxOption("JournalXPMultiplier")) or 1.0
    if journalMultiplier < 0 then
        journalMultiplier = 0
    end

    -- Resolve skill-book multiplier server-side for correctness/security.
    -- Keep a client multiplier fallback only if server cannot detect a boost.
    local skillBookMultiplier = 1.0
    local cap = tonumber(BurdJournals.getSandboxOption("SkillBookMultiplierCap")) or 2.0
    if cap < 1.0 then cap = 1.0 end
    local featureEnabled = BurdJournals.getSandboxOption("SkillBookMultiplierForJournals")
    local clientReportedMultiplier = tonumber(args and args.skillBookMultiplier)

    if featureEnabled and BurdJournals.getSkillBookMultiplier then
        local serverMultiplier, serverHasBoost = BurdJournals.getSkillBookMultiplier(player, skillName)
        serverMultiplier = tonumber(serverMultiplier) or 1.0
        serverMultiplier = math.max(1.0, math.min(serverMultiplier, cap))

        if serverHasBoost and serverMultiplier > 1.0 then
            skillBookMultiplier = serverMultiplier
        elseif clientReportedMultiplier and clientReportedMultiplier > 1.0 then
            -- Fallback for edge cases where server-side multiplier is unavailable.
            skillBookMultiplier = math.max(1.0, math.min(clientReportedMultiplier, cap))
        end
    end
    BurdJournals.debugPrint("[BurdJournals] Server: absorb skill multipliers - journal=" .. tostring(journalMultiplier) .. ", book=" .. tostring(skillBookMultiplier) .. ", clientReported=" .. tostring(clientReportedMultiplier))
    
    local xpToAdd = baseXP * journalMultiplier * skillBookMultiplier
    BurdJournals.debugPrint("[BurdJournals] Server: baseXP=" .. tostring(baseXP) .. ", journalMult=" .. tostring(journalMultiplier) .. ", bookMult=" .. tostring(skillBookMultiplier) .. ", xpToAdd=" .. tostring(xpToAdd))

    -- Fitness and Strength use different XP scaling in PZ.
    -- Compensate so journal rewards match configured values.
    local isPassiveSkill = (skillName == "Fitness" or skillName == "Strength")
    if isPassiveSkill then
        xpToAdd = xpToAdd * 5
        BurdJournals.debugPrint("[BurdJournals] Server: Applied 5x passive skill multiplier for " .. skillName .. ", new xpToAdd: " .. tostring(xpToAdd))
    end

    -- AddXP adds the specified amount directly for all skills
    local perk = BurdJournals.getPerkByName(skillName)

    if not perk then

        perk = Perks[skillName]

        if not perk and BurdJournals.SKILL_TO_PERK and BurdJournals.SKILL_TO_PERK[skillName] then
            local mappedName = BurdJournals.SKILL_TO_PERK[skillName]

            perk = Perks[mappedName]
        end
    end

    if not perk then
        print("[BurdJournals] Server ERROR: Could not find perk for skill '" .. skillName .. "'")
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid skill: " .. skillName})
        return
    end

    if xpToAdd > 0 then

        BurdJournals.markSkillClaimedByCharacter(journalData, player, skillName)

        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        local shouldDis = false
        if freshJournal and BurdJournals.isValidItem(freshJournal) then
            shouldDis = BurdJournals.shouldDissolve(freshJournal, player)
        end

        -- Apply XP directly on server - use AddXP with useMultipliers=false since we already applied our own
        if perk then
            BurdJournals.debugPrint("[BurdJournals] Server: Absorb - Applying " .. tostring(xpToAdd) .. " XP to " .. skillName .. " via AddXP (no game multipliers)")
            -- AddXP signature: (perk, amount, addToKnownRecipes, useMultipliers, isPassive, checkLevelUp)
            -- Set useMultipliers to false since we've already calculated with our skill book multiplier
            -- checkLevelUp = true to recalculate level!
            player:getXp():AddXP(perk, xpToAdd, true, false, false, true)
            -- NOTE: Don't call syncXp here - it disrupts batch command processing
            -- Client will request sync at end of batch via requestXpSync command
        elseif addXp then
            -- Fallback to vanilla addXp if AddXP not available
            BurdJournals.debugPrint("[BurdJournals] Server: Absorb - Fallback using addXp() for " .. skillName)
            addXp(player, perk, xpToAdd)
            -- NOTE: Don't call syncXp here - it disrupts batch command processing
        else
            -- Fallback for SP or if addXp unavailable
            BurdJournals.debugPrint("[BurdJournals] Server: Absorb fallback - sending applyXP to client for " .. skillName)
            BurdJournals.Server.sendToClient(player, "applyXP", {
                skills = {
                    [skillName] = {
                        xp = xpToAdd,
                        mode = "add"
                    }
                },
                mode = "add"
            })
        end

        if shouldDis and freshJournal then

            local container = freshJournal:getContainer()

            if container then
                container:Remove(freshJournal)
            end

            local inv = player:getInventory()
            if inv:contains(freshJournal) then
                inv:Remove(freshJournal)
            end

            BurdJournals.Server.sendToClient(player, "journalDissolved", {
                message = BurdJournals.getRandomDissolutionMessage(),
                journalId = journalId,
                -- Debug info for skill absorption before dissolution
                skillName = skillName,
                xpGained = xpToAdd,
                debug_baseXP = baseXP,
                debug_journalMult = journalMultiplier,
                debug_bookMult = skillBookMultiplier,
                debug_receivedMult = clientReportedMultiplier,
            })
        else

            if freshJournal and freshJournal.transmitModData then
                freshJournal:transmitModData()
            end

            -- Use per-character unclaimed counts (use freshJournal if available)
            local jnl = freshJournal or journal
            local remainingRewards = 0
            local totalRewards = 0
            if jnl then
                remainingRewards = BurdJournals.getUnclaimedSkillCount(jnl, player) +
                                   BurdJournals.getUnclaimedTraitCount(jnl, player) +
                                   BurdJournals.getUnclaimedRecipeCount(jnl, player)
                totalRewards = BurdJournals.getTotalRewards(jnl)
            end
            BurdJournals.Server.sendToClient(player, "absorbSuccess", {
                skillName = skillName,
                xpGained = xpToAdd,
                remaining = remainingRewards,
                total = totalRewards,
                journalId = journalId,
                journalData = journalData,
                -- Debug info
                debug_baseXP = baseXP,
                debug_journalMult = journalMultiplier,
                debug_bookMult = skillBookMultiplier,
                debug_receivedMult = clientReportedMultiplier,
                })
        end
    else
        -- Still mark as claimed even if no XP to add (allows journal dissolution)
        BurdJournals.markSkillClaimedByCharacter(journalData, player, skillName)

        -- Re-fetch journal by ID to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        if freshJournal and freshJournal.transmitModData then
            freshJournal:transmitModData()
        end
        BurdJournals.Server.sendToClient(player, "skillMaxed", {
            skillName = skillName,
            journalId = journalId,
            journalData = journalData,
        })
        -- Check if journal should dissolve after marking this claim
        if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve and BurdJournals.shouldDissolve(freshJournal, player) then
            BurdJournals.Server.dissolveJournal(player, freshJournal)
        end
    end

end

function BurdJournals.Server.handleAbsorbTrait(player, args)
    if not args or not args.traitId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local traitId = args.traitId

    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.canAbsorbXP(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Cannot absorb from this journal."})
        return
    end

    local modData = journal:getModData()
    local journalData = modData.BurdJournals
    if not journalData or not journalData.traits then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no trait data."})
        return
    end

    if not BurdJournals.isTraitEnabledForJournal(journalData, traitId) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Trait absorbing is disabled for this journal type."})
        return
    end

    if not journalData.traits[traitId] then
        BurdJournals.Server.sendToClient(player, "error", {message = "Trait not found in journal."})
        return
    end

    if BurdJournals.hasCharacterClaimedTrait(journalData, player, traitId) then
        BurdJournals.Server.sendToClient(player, "error", {message = "This trait has already been claimed."})
        return
    end

    if BurdJournals.playerHasTrait(player, traitId) then
        BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)

        local freshJournal = BurdJournals.findItemById(player, journalId)
        if freshJournal and freshJournal.transmitModData then
            freshJournal:transmitModData()
        end

        BurdJournals.Server.sendToClient(player, "traitAlreadyKnown", {
            traitId = traitId,
            journalId = journalId,
        })

        if BurdJournals.Server.safeShouldDissolve(player, journalId) then
            local jnl = BurdJournals.findItemById(player, journalId)
            if jnl then
                BurdJournals.Server.dissolveJournal(player, jnl)
                BurdJournals.Server.sendToClient(player, "journalDissolved", {
                    message = BurdJournals.getRandomDissolutionMessage(),
                    journalId = journalId,
                })
            end
        end
        return
    end

    local characterTrait, resolvedSource, traitIdsToTry = BurdJournals.Server.resolveCharacterTrait(traitId, player)
    if not characterTrait then
        print("[BurdJournals] Server: ERROR - Could not resolve CharacterTrait for '" .. tostring(traitId) .. "'")
        if traitIdsToTry and #traitIdsToTry > 0 then
            BurdJournals.debugPrint("[BurdJournals] Server: Tried IDs: " .. table.concat(traitIdsToTry, ", "))
        end
        BurdJournals.Server.sendToClient(player, "error", {message = "Could not learn trait."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] Server: Resolved trait '" .. tostring(traitId) .. "' via " .. tostring(resolvedSource))

    local charTraits = player.getCharacterTraits and player:getCharacterTraits() or nil
    if not charTraits or not charTraits.add then
        BurdJournals.Server.sendToClient(player, "error", {message = "Trait system unavailable."})
        return
    end

    local hadBefore = player.hasTrait and (player:hasTrait(characterTrait) == true) or false
    if hadBefore then
        BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)

        local freshJournal = BurdJournals.findItemById(player, journalId)
        if freshJournal and freshJournal.transmitModData then
            freshJournal:transmitModData()
        end

        BurdJournals.Server.sendToClient(player, "traitAlreadyKnown", {
            traitId = traitId,
            journalId = journalId,
        })

        if BurdJournals.Server.safeShouldDissolve(player, journalId) then
            local jnl = BurdJournals.findItemById(player, journalId)
            if jnl then
                BurdJournals.Server.dissolveJournal(player, jnl)
                BurdJournals.Server.sendToClient(player, "journalDissolved", {
                    message = BurdJournals.getRandomDissolutionMessage(),
                    journalId = journalId,
                })
            end
        end
        return
    end

    charTraits:add(characterTrait)

    if player.modifyTraitXPBoost then
        player:modifyTraitXPBoost(characterTrait, false)
    end
    if SyncXp then
        SyncXp(player)
    end

    local hasAfter = player.hasTrait and (player:hasTrait(characterTrait) == true) or false
    if not hasAfter then
        print("[BurdJournals] Server: ERROR - Trait add verification failed for '" .. tostring(traitId) .. "'")
        BurdJournals.Server.sendToClient(player, "error", {message = "Could not learn trait."})
        return
    end

    BurdJournals.markTraitClaimedByCharacter(journalData, player, traitId)

    local freshJournal = BurdJournals.findItemById(player, journalId)
    local shouldDis = false
    if freshJournal and BurdJournals.isValidItem(freshJournal) then
        shouldDis = BurdJournals.shouldDissolve(freshJournal, player)
    end

    BurdJournals.Server.sendToClient(player, "grantTrait", {
        traitId = traitId,
        journalId = journalId,
    })

    if shouldDis and freshJournal then
        BurdJournals.Server.dissolveJournal(player, freshJournal)
        BurdJournals.Server.sendToClient(player, "journalDissolved", {
            message = BurdJournals.getRandomDissolutionMessage(),
            journalId = journalId,
        })
        return
    end

    if freshJournal and freshJournal.transmitModData then
        freshJournal:transmitModData()
    end

    local jnl = freshJournal or journal
    local remainingRewards = 0
    local totalRewards = 0
    if jnl then
        remainingRewards = BurdJournals.getUnclaimedSkillCount(jnl, player) +
                           BurdJournals.getUnclaimedTraitCount(jnl, player) +
                           BurdJournals.getUnclaimedRecipeCount(jnl, player)
        totalRewards = BurdJournals.getTotalRewards(jnl)
    end

    BurdJournals.Server.sendToClient(player, "absorbSuccess", {
        traitId = traitId,
        remaining = remainingRewards,
        total = totalRewards,
        journalId = journalId,
        journalData = journalData,
    })
end

function BurdJournals.Server.handleEraseJournal(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.isClean(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Can only erase clean journals."})
        return
    end

    if BurdJournals.getSandboxOption("RequireEraserToErase") then
        local eraser = BurdJournals.findEraser(player)
        if not eraser then
            BurdJournals.Server.sendToClient(player, "error", {message = "You need an eraser to wipe the journal."})
            return
        end
    end

    local sourceJournalData = nil
    do
        local sourceModData = journal:getModData()
        sourceJournalData = sourceModData and sourceModData.BurdJournals or nil
    end

    local inheritedWasFromBloody = false
    local inheritedWasCleaned = false
    local inheritedRestoredBy = player and player:getUsername() or "Unknown"
    if type(sourceJournalData) == "table" then
        inheritedWasFromBloody = sourceJournalData.wasFromBloody == true or sourceJournalData.isBloody == true
        inheritedWasCleaned = sourceJournalData.wasCleaned == true
        if type(sourceJournalData.restoredBy) == "string" and sourceJournalData.restoredBy ~= "" then
            inheritedRestoredBy = sourceJournalData.restoredBy
        end
    end

    local inventory = player:getInventory()
    inventory:Remove(journal)
    sendRemoveItemFromContainer(inventory, journal)

    local blankJournal = inventory:AddItem("BurdJournals.BlankSurvivalJournal")
    if blankJournal then
        local modData = blankJournal:getModData()
        modData.BurdJournals = {
            isWorn = false,
            isBloody = false,
            isPlayerCreated = true,
        }
        BurdJournals.updateJournalName(blankJournal)
        BurdJournals.updateJournalIcon(blankJournal)

        if blankJournal.transmitModData then
            blankJournal:transmitModData()
            BurdJournals.debugPrint("[BurdJournals] Server: transmitModData called for blank journal in handleEraseJournal")
        end

        sendAddItemToContainer(inventory, blankJournal)
        BurdJournals.debugPrint("[BurdJournals] Server: sendAddItemToContainer called for blank journal in handleEraseJournal")
    end

    BurdJournals.Server.sendToClient(player, "eraseSuccess", {})
end

function BurdJournals.Server.handleCleanBloody(player, args)

    BurdJournals.Server.sendToClient(player, "error", {
        message = "Bloody journals can now be read directly. Right-click to open and absorb XP."
    })
end

function BurdJournals.Server.handleConvertToClean(player, args)
    if not args or not args.journalId then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journal = BurdJournals.findItemById(player, args.journalId)
    if not journal then
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.isWorn(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Only worn journals can be converted."})
        return
    end

    if not BurdJournals.canConvertToClean(player) then
        BurdJournals.Server.sendToClient(player, "error", {message = "You need leather, thread, needle, and Tailoring Lv1."})
        return
    end

    local leather = BurdJournals.findRepairItem(player, "leather")
    local thread = BurdJournals.findRepairItem(player, "thread")
    local needle = BurdJournals.findRepairItem(player, "needle")

    player:getInventory():Remove(leather)
    BurdJournals.consumeItemUses(thread, 1, player)
    BurdJournals.consumeItemUses(needle, 1, player)

    local inventory = player:getInventory()
    inventory:Remove(journal)
    sendRemoveItemFromContainer(inventory, journal)

    local cleanJournal = inventory:AddItem("BurdJournals.BlankSurvivalJournal")
    if cleanJournal then
        local modData = cleanJournal:getModData()
        modData.BurdJournals = {
            uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
                or ("journal-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(cleanJournal:getID())),
            isWorn = false,
            isBloody = false,
            wasFromWorn = true,
            wasFromBloody = inheritedWasFromBloody,
            wasRestored = true,
            wasCleaned = inheritedWasCleaned,
            restoredBy = inheritedRestoredBy,
            isPlayerCreated = true,
        }
        BurdJournals.updateJournalName(cleanJournal)
        BurdJournals.updateJournalIcon(cleanJournal)

        if cleanJournal.transmitModData then
            cleanJournal:transmitModData()
            BurdJournals.debugPrint("[BurdJournals] Server: transmitModData called for clean journal in handleConvertToClean")
        end

        sendAddItemToContainer(inventory, cleanJournal)
        BurdJournals.debugPrint("[BurdJournals] Server: sendAddItemToContainer called for clean journal in handleConvertToClean")
    end

    BurdJournals.Server.sendToClient(player, "convertSuccess", {
        message = "The worn journal has been restored to a clean blank journal."
    })
end

function BurdJournals.Server.handleClaimRecipe(player, args)
    if not args or not args.recipeName then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local recipeName = args.recipeName
    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    local canClaim, reason = BurdJournals.canPlayerClaimFromJournal(player, journal)
    if not canClaim then
        BurdJournals.Server.sendToClient(player, "error", {message = reason or "Permission denied."})
        return
    end

    local modData = journal:getModData()
    local journalData = modData.BurdJournals

    if not journalData or not journalData.recipes then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no recipe data."})
        return
    end

    -- Check if recipes are enabled for this journal type
    if not BurdJournals.areRecipesEnabledForJournal(journalData) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Recipe claiming is disabled for this journal type."})
        return
    end

    if not journalData.recipes[recipeName] then
        print("[BurdJournals] Server ERROR: Recipe '" .. recipeName .. "' not found in journal")
        BurdJournals.Server.sendToClient(player, "error", {message = "Recipe not found in journal."})
        return
    end

    if BurdJournals.hasCharacterClaimedRecipe(journalData, player, recipeName) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Recipe already claimed."})
        return
    end

    if BurdJournals.playerKnowsRecipe(player, recipeName) then
        -- Mark as claimed even though player already knows the recipe (allows journal dissolution)
        BurdJournals.markRecipeClaimedByCharacter(journalData, player, recipeName)
        if journal.transmitModData then
            journal:transmitModData()
        end
        BurdJournals.Server.sendToClient(player, "recipeAlreadyKnown", {
            recipeName = recipeName,
            journalId = journalId,
        })
        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve and BurdJournals.shouldDissolve(freshJournal, player) then
            BurdJournals.Server.dissolveJournal(player, freshJournal)
        end
        return
    end

    local recipeWasLearned = BurdJournals.learnRecipeWithVerification(player, recipeName, "[BurdJournals Server]")

    if recipeWasLearned then

        BurdJournals.markRecipeClaimedByCharacter(journalData, player, recipeName)

        if journal.transmitModData then
            journal:transmitModData()
        end

        if sendSyncPlayerFields then
            -- Only sync recipes (0x4), not skills/traits (0x7 would sync all three)
            sendSyncPlayerFields(player, 0x00000004)
        end

        BurdJournals.Server.sendToClient(player, "claimSuccess", {
            recipeName = recipeName,
            journalId = journalId,
            journalData = journalData,
        })
        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        BurdJournals.debugPrint("[BurdJournals] Server: Post-recipe claim check - freshJournal=" .. tostring(freshJournal ~= nil) .. ", journalId=" .. tostring(journalId))
        if freshJournal then
            local isValid = BurdJournals.isValidItem(freshJournal)
            local hasShouldDissolve = BurdJournals.shouldDissolve ~= nil
            local shouldDis = hasShouldDissolve and BurdJournals.shouldDissolve(freshJournal, player)
            BurdJournals.debugPrint("[BurdJournals] Server: isValid=" .. tostring(isValid) .. ", hasShouldDissolve=" .. tostring(hasShouldDissolve) .. ", shouldDis=" .. tostring(shouldDis))
            if isValid and shouldDis then
                BurdJournals.debugPrint("[BurdJournals] Server: DISSOLVING JOURNAL after recipe claim!")
                BurdJournals.Server.dissolveJournal(player, freshJournal)
            end
        end
    else
        BurdJournals.Server.sendToClient(player, "error", {message = "Could not learn recipe."})
    end
end

function BurdJournals.Server.handleAbsorbRecipe(player, args)
    if not args or not args.recipeName then
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid request."})
        return
    end

    local journalId = args.journalId
    local recipeName = args.recipeName

    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        print("[BurdJournals] Server ERROR: Journal not found by ID " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    if not BurdJournals.canAbsorbXP(journal) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Cannot absorb from this journal."})
        return
    end

    local modData = journal:getModData()
    local journalData = modData.BurdJournals

    if not journalData or not journalData.recipes then
        BurdJournals.Server.sendToClient(player, "error", {message = "This journal has no recipe data."})
        return
    end

    -- Check if recipes are enabled for this journal type
    if not BurdJournals.areRecipesEnabledForJournal(journalData) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Recipe absorbing is disabled for this journal type."})
        return
    end

    if not journalData.recipes[recipeName] then
        print("[BurdJournals] Server ERROR: Recipe '" .. recipeName .. "' not found in journal")
        BurdJournals.Server.sendToClient(player, "error", {message = "Recipe not found in journal."})
        return
    end

    if BurdJournals.hasCharacterClaimedRecipe(journalData, player, recipeName) then
        BurdJournals.Server.sendToClient(player, "error", {message = "Recipe already claimed."})
        return
    end

    if BurdJournals.playerKnowsRecipe(player, recipeName) then

        BurdJournals.markRecipeClaimedByCharacter(journalData, player, recipeName)

        if journal.transmitModData then
            journal:transmitModData()
        end

        BurdJournals.Server.sendToClient(player, "recipeAlreadyKnown", {
            recipeName = recipeName,
            journalId = journalId,
        })

        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        if freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve(freshJournal, player) then
            local dissolutionMessage = BurdJournals.getRandomDissolutionMessage()
            removeJournalCompletely(player, freshJournal)
            BurdJournals.Server.sendToClient(player, "journalDissolved", {
                message = dissolutionMessage
            })
        end
        return
    end

    local recipeWasLearned = BurdJournals.learnRecipeWithVerification(player, recipeName, "[BurdJournals Server]")

    if recipeWasLearned then

        BurdJournals.markRecipeClaimedByCharacter(journalData, player, recipeName)

        if journal.transmitModData then
            journal:transmitModData()
        end

        if sendSyncPlayerFields then
            -- Only sync recipes (0x4), not skills/traits (0x7 would sync all three)
            sendSyncPlayerFields(player, 0x00000004)
        end

        local updatedJournalData = BurdJournals.Server.copyJournalData(journal)

        -- Re-fetch journal by ID before calling shouldDissolve to avoid zombie object errors
        local freshJournal = BurdJournals.findItemById(player, journalId)
        local shouldDis = freshJournal and BurdJournals.isValidItem(freshJournal) and BurdJournals.shouldDissolve(freshJournal, player)

        if shouldDis then
            local dissolutionMessage = BurdJournals.getRandomDissolutionMessage()
            removeJournalCompletely(player, freshJournal)

            BurdJournals.Server.sendToClient(player, "absorbSuccess", {
                recipeName = recipeName,
                journalData = updatedJournalData,
                dissolved = true,
                dissolutionMessage = dissolutionMessage
            })
        else
            BurdJournals.Server.sendToClient(player, "absorbSuccess", {
                recipeName = recipeName,
                journalId = journalId,
                journalData = updatedJournalData,
                dissolved = false
            })
        end
    else
        BurdJournals.Server.sendToClient(player, "error", {message = "Could not learn recipe."})
    end
end

function BurdJournals.Server.handleEraseEntry(player, args)
    if not args then
        BurdJournals.debugPrint("[BurdJournals] Server: EraseEntry - No args provided")
        return
    end

    local journalId = args.journalId
    local entryType = args.entryType
    local entryName = args.entryName

    if not journalId or not entryType or not entryName then
        BurdJournals.debugPrint("[BurdJournals] Server: EraseEntry - Missing required args")
        BurdJournals.Server.sendToClient(player, "error", {message = "Invalid erase request."})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] Server: Processing erase request - type: " .. entryType .. ", name: " .. entryName)

    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        BurdJournals.debugPrint("[BurdJournals] Server: EraseEntry - Journal not found: " .. tostring(journalId))
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal not found."})
        return
    end

    local modData = journal:getModData()
    if not modData or not modData.BurdJournals then
        BurdJournals.debugPrint("[BurdJournals] Server: EraseEntry - No journal data")
        BurdJournals.Server.sendToClient(player, "error", {message = "Journal has no data."})
        return
    end

    local journalData = modData.BurdJournals
    local erased = false

    if entryType == "skill" then
        if journalData.skills and journalData.skills[entryName] then
            journalData.skills[entryName] = nil
            erased = true
            BurdJournals.debugPrint("[BurdJournals] Server: Erased skill entry: " .. entryName)
        end

        -- Clear legacy claims
        if journalData.claimedSkills and journalData.claimedSkills[entryName] then
            journalData.claimedSkills[entryName] = nil
        end
        -- Clear per-character claims structure for ALL characters
        if journalData.claims and type(journalData.claims) == "table" then
            for charId, charClaims in pairs(journalData.claims) do
                if charClaims and charClaims.skills and charClaims.skills[entryName] then
                    charClaims.skills[entryName] = nil
                    BurdJournals.debugPrint("[BurdJournals] Server: Cleared skill claim for character: " .. tostring(charId))
                end
            end
        end
    elseif entryType == "trait" then
        if journalData.traits and journalData.traits[entryName] then
            journalData.traits[entryName] = nil
            erased = true
            BurdJournals.debugPrint("[BurdJournals] Server: Erased trait entry: " .. entryName)
        end

        -- Clear legacy claims
        if journalData.claimedTraits and journalData.claimedTraits[entryName] then
            journalData.claimedTraits[entryName] = nil
        end
        -- Clear per-character claims structure for ALL characters
        if journalData.claims and type(journalData.claims) == "table" then
            for charId, charClaims in pairs(journalData.claims) do
                if charClaims and charClaims.traits and charClaims.traits[entryName] then
                    charClaims.traits[entryName] = nil
                    BurdJournals.debugPrint("[BurdJournals] Server: Cleared trait claim for character: " .. tostring(charId))
                end
            end
        end
    elseif entryType == "recipe" then
        if journalData.recipes and journalData.recipes[entryName] then
            journalData.recipes[entryName] = nil
            erased = true
            BurdJournals.debugPrint("[BurdJournals] Server: Erased recipe entry: " .. entryName)
        end

        -- Clear legacy claims
        if journalData.claimedRecipes and journalData.claimedRecipes[entryName] then
            journalData.claimedRecipes[entryName] = nil
        end
        -- Clear per-character claims structure for ALL characters
        if journalData.claims and type(journalData.claims) == "table" then
            for charId, charClaims in pairs(journalData.claims) do
                if charClaims and charClaims.recipes and charClaims.recipes[entryName] then
                    charClaims.recipes[entryName] = nil
                    BurdJournals.debugPrint("[BurdJournals] Server: Cleared recipe claim for character: " .. tostring(charId))
                end
            end
        end
    elseif entryType == "stat" then
        if journalData.stats and journalData.stats[entryName] then
            journalData.stats[entryName] = nil
            erased = true
            BurdJournals.debugPrint("[BurdJournals] Server: Erased stat entry: " .. entryName)
        end

        -- Clear legacy claims
        if journalData.claimedStats and journalData.claimedStats[entryName] then
            journalData.claimedStats[entryName] = nil
        end
        -- Clear per-character claims structure for ALL characters
        if journalData.claims and type(journalData.claims) == "table" then
            for charId, charClaims in pairs(journalData.claims) do
                if charClaims and charClaims.stats and charClaims.stats[entryName] then
                    charClaims.stats[entryName] = nil
                    BurdJournals.debugPrint("[BurdJournals] Server: Cleared stat claim for character: " .. tostring(charId))
                end
            end
        end
    end

    if erased then

        if journal.transmitModData then
            journal:transmitModData()
        end

        local updatedJournalData = BurdJournals.Server.copyJournalData(journal)

        BurdJournals.Server.sendToClient(player, "eraseSuccess", {
            entryType = entryType,
            entryName = entryName,
            journalId = journal:getID(),
            journalData = updatedJournalData
        })
        BurdJournals.debugPrint("[BurdJournals] Server: Erase successful, sent confirmation to client")
    else
        BurdJournals.debugPrint("[BurdJournals] Server: Entry not found to erase: " .. entryType .. " - " .. entryName)
        BurdJournals.Server.sendToClient(player, "error", {message = "Entry not found."})
    end
end

-- Server-side handler for renaming journals (MP custom name persistence fix)
-- This ensures the server has the correct name so it persists during item transfers
function BurdJournals.Server.handleRenameJournal(player, args)
    if not args then
        BurdJournals.debugPrint("[BurdJournals] Server: RenameJournal - No args provided")
        return
    end

    local journalId = args.journalId
    local newName = args.newName

    if not journalId or not newName then
        BurdJournals.debugPrint("[BurdJournals] Server: RenameJournal - Missing required args")
        return
    end

    -- Sanitize the name (basic protection)
    if type(newName) ~= "string" or #newName > 100 then
        BurdJournals.debugPrint("[BurdJournals] Server: RenameJournal - Invalid name")
        return
    end

    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        BurdJournals.debugPrint("[BurdJournals] Server: RenameJournal - Journal not found: " .. tostring(journalId))
        return
    end

    -- Update the item's display name on the server
    journal:setName(newName)
    
    -- Mark as custom name so PZ preserves it during serialization
    if journal.setCustomName then
        journal:setCustomName(true)
    end

    -- Store in ModData as backup
    local modData = journal:getModData()
    if not modData.BurdJournals then
        modData.BurdJournals = {}
    end
    modData.BurdJournals.customName = newName

    -- Transmit the updated data to all clients
    if journal.transmitModData then
        journal:transmitModData()
    end

    BurdJournals.debugPrint("[BurdJournals] Server: Journal renamed to: " .. newName)

    -- Send confirmation to client
    BurdJournals.Server.sendToClient(player, "renameSuccess", {
        journalId = journalId,
        newName = newName
    })
end

-- Track if we've already logged the cache state this session
BurdJournals.Server._baselineCacheLogged = false
BurdJournals.Server._modDataInitialized = false
BurdJournals.Server._baselineCacheInstance = nil  -- Cache the reference to avoid re-creating

function BurdJournals.Server.getBaselineCache()
    -- Return cached instance if we have one (prevents multiple getOrCreate calls)
    if BurdJournals.Server._baselineCacheInstance then
        return BurdJournals.Server._baselineCacheInstance
    end
    
    -- Try to get existing ModData first (may return nil if not yet loaded from disk)
    local cache = nil
    
    -- Use ModData.get first to check if data exists without creating empty table
    if ModData.get then
        cache = ModData.get("BurdJournals_PlayerBaselines")
        if cache then
            BurdJournals.debugPrint("[BurdJournals] ModData.get returned existing cache")
        end
    end
    
    -- If no cache found, use getOrCreate
    if not cache then
        -- IMPORTANT: Only create new cache if ModData has been initialized
        -- This prevents creating an empty cache before save data is loaded
        if not BurdJournals.Server._modDataInitialized then
            print("[BurdJournals] WARNING: getBaselineCache called before ModData initialized - creating temporary empty cache")
        end
        cache = ModData.getOrCreate("BurdJournals_PlayerBaselines")
    end
    
    -- Initialize players table if missing (but preserve existing data)
    if not cache.players then
        cache.players = {}
        -- Mark this as a newly created cache
        cache._createdAt = getGameTime and getGameTime():getWorldAgeHours() or 0
        cache._version = 1
        BurdJournals.debugPrint("[BurdJournals] Created new baseline cache (no existing data found)")
    elseif not BurdJournals.Server._baselineCacheLogged then
        -- Log once per session to help debug persistence issues
        local playerCount = 0
        local debugModifiedCount = 0
        for id, data in pairs(cache.players) do 
            playerCount = playerCount + 1
            if data.debugModified then
                debugModifiedCount = debugModifiedCount + 1
            end
        end
        BurdJournals.debugPrint("[BurdJournals] Loaded existing baseline cache: " .. playerCount .. " player(s), " .. debugModifiedCount .. " debug-modified")
        BurdJournals.Server._baselineCacheLogged = true
    end
    
    -- Store reference to avoid re-creating
    BurdJournals.Server._baselineCacheInstance = cache
    
    return cache
end

function BurdJournals.Server.getCachedBaseline(characterId)
    if not characterId then return nil end
    local cache = BurdJournals.Server.getBaselineCache()
    return cache.players[characterId]
end

function BurdJournals.Server.storeCachedBaseline(characterId, baselineData, forceOverwrite)
    if not characterId or not baselineData then return false end

    local cache = BurdJournals.Server.getBaselineCache()
    local existingBaseline = cache.players[characterId]

    -- IMPORTANT: Never overwrite debug-modified baselines unless explicitly forced
    if existingBaseline then
        if existingBaseline.debugModified and not forceOverwrite then
            print("[BurdJournals] PROTECTED: Baseline for " .. characterId .. " was debug-modified, refusing automatic overwrite")
            return false
        end
        if not forceOverwrite then
            BurdJournals.debugPrint("[BurdJournals] Baseline already cached for " .. characterId .. ", ignoring new registration")
            return false
        end
    end

    -- Preserve the debugModified flag if it was set and we're force-overwriting
    local preserveDebugFlag = existingBaseline and existingBaseline.debugModified

    local debugFlag = baselineData.debugModified
    if debugFlag == nil then
        debugFlag = preserveDebugFlag
    end

    cache.players[characterId] = {
        skillBaseline = baselineData.skillBaseline or {},
        mediaSkillBaseline = baselineData.mediaSkillBaseline or {},
        traitBaseline = baselineData.traitBaseline or {},
        recipeBaseline = baselineData.recipeBaseline or {},
        capturedAt = getGameTime():getWorldAgeHours(),
        steamId = baselineData.steamId,
        characterName = baselineData.characterName,
        debugModified = debugFlag  -- Preserve unless explicitly overridden
    }

    -- Persist to disk so baseline survives server restart
    if ModData.transmit then
        ModData.transmit("BurdJournals_PlayerBaselines")
    end

    BurdJournals.debugPrint("[BurdJournals] Baseline cached and persisted for " .. characterId)
    return true
end

function BurdJournals.Server.handleRegisterBaseline(player, args)
    if not player or not args then return end

    local characterId = args.characterId
    if not characterId then
        print("[BurdJournals] ERROR: No characterId in registerBaseline")
        return
    end

    local serverCharacterId = BurdJournals.getPlayerCharacterId(player)
    if serverCharacterId ~= characterId then
        print("[BurdJournals] WARNING: Character ID mismatch! Client sent: " .. characterId .. ", Server computed: " .. tostring(serverCharacterId))

        characterId = serverCharacterId
    end

    -- Build baseline from authoritative server state (ignore client-provided baseline)
    local baselineData = BurdJournals.Server.buildBaselineForPlayer(player)
    baselineData.steamId = BurdJournals.getPlayerSteamId(player)
    local descriptor = player.getDescriptor and player:getDescriptor() or nil
    baselineData.characterName = BurdJournals.getPlayerCharacterName and BurdJournals.getPlayerCharacterName(player) or (descriptor and (descriptor:getForename() .. " " .. descriptor:getSurname()) or nil)

    local stored = BurdJournals.Server.storeCachedBaseline(characterId, baselineData, false)

    local playerModData = player:getModData()
    playerModData.BurdJournals = playerModData.BurdJournals or {}
    playerModData.BurdJournals.mediaSkillBaseline = baselineData.mediaSkillBaseline or {}
    if player.transmitModData then
        player:transmitModData()
    end

    BurdJournals.Server.sendToClient(player, "baselineRegistered", {
        success = stored,
        characterId = characterId,
        alreadyExisted = not stored
    })
end

-- Build baseline data from server-authoritative player state
function BurdJournals.Server.buildBaselineForPlayer(player)
    local baseline = {
        skillBaseline = {},
        mediaSkillBaseline = {},
        traitBaseline = {},
        recipeBaseline = {}
    }

    if not player then return baseline end

    -- Skills: capture current XP for all allowed skills
    local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
    local xpObj = player.getXp and player:getXp()
    if xpObj then
        for _, skillName in ipairs(allowedSkills) do
            local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
            if perk then
                local xp = xpObj:getXP(perk)
                if xp and xp > 0 then
                    baseline.skillBaseline[skillName] = xp
                end
            end
        end
    end

    -- Traits: record current traits as baseline
    local traits = BurdJournals.collectPlayerTraits and BurdJournals.collectPlayerTraits(player, false) or {}
    for traitId, _ in pairs(traits) do
        baseline.traitBaseline[traitId] = true
    end

    -- Recipes: only baseline for new characters (avoid baselining existing saves)
    local hoursAlive = player.getHoursSurvived and player:getHoursSurvived() or 0
    if hoursAlive <= 1 then
        local recipes = BurdJournals.collectPlayerMagazineRecipes and BurdJournals.collectPlayerMagazineRecipes(player, false) or {}
        for recipeName, _ in pairs(recipes) do
            baseline.recipeBaseline[recipeName] = true
        end
    end

    if BurdJournals.getPlayerVhsSkillXPMapCopy then
        baseline.mediaSkillBaseline = BurdJournals.getPlayerVhsSkillXPMapCopy(player)
    end

    return baseline
end

function BurdJournals.Server.handleDeleteBaseline(player, args)
    if not player then return end

    local characterId = args and args.characterId
    if not characterId then
        print("[BurdJournals] ERROR: No characterId in deleteBaseline")
        return
    end

    local reason = args and args.reason
    local serverCharacterId = BurdJournals.getPlayerCharacterId(player)
    if serverCharacterId ~= characterId then
        print("[BurdJournals] WARNING: Character ID mismatch in deleteBaseline! Client sent: " .. characterId .. ", Server computed: " .. tostring(serverCharacterId))
        characterId = serverCharacterId
    end

    -- Security:
    -- - Admins can always clear baselines (debug/tools)
    -- - Non-admins may only clear their own baseline during death cleanup
    local accessLevel = player:getAccessLevel()
    local isAdmin = accessLevel and accessLevel ~= "None"
    local isDeathCleanup = reason == "death"
    if not isAdmin then
        local isOwnDeathCleanup = isDeathCleanup and serverCharacterId and characterId and serverCharacterId == characterId
        if not isOwnDeathCleanup then
            print("[BurdJournals] WARNING: Non-admin player attempted deleteBaseline: " .. tostring(player.getUsername and player:getUsername() or "unknown"))
            BurdJournals.Server.sendToClient(player, "error", {message = "Admin access required."})
            return
        end
    end

    local cache = BurdJournals.Server.getBaselineCache()
    if cache.players[characterId] then
        cache.players[characterId] = nil
        -- Persist deletion to disk
        if ModData.transmit then
            ModData.transmit("BurdJournals_PlayerBaselines")
        end
        BurdJournals.debugPrint("[BurdJournals] Deleted cached baseline for: " .. characterId)
    else
        BurdJournals.debugPrint("[BurdJournals] No cached baseline to delete for: " .. characterId)
    end
end

-- Admin command to clear ALL baseline caches server-wide
-- This allows a fresh start for all players - baselines will be captured on next character creation
function BurdJournals.Server.handleClearAllBaselines(player, _args)
    if not player then return end

    -- Check if player is admin
    local accessLevel = player:getAccessLevel()
    if not accessLevel or accessLevel == "None" then
        print("[BurdJournals] WARNING: Non-admin player attempted clearAllBaselines: " .. tostring(player:getUsername()))
        BurdJournals.Server.sendToClient(player, "error", {message = "Admin access required."})
        return
    end

    local cache = BurdJournals.Server.getBaselineCache()
    local clearedCount = 0

    -- Count entries before clearing
    for _ in pairs(cache.players) do
        clearedCount = clearedCount + 1
    end

    -- Clear all cached baselines
    cache.players = {}

    -- Persist to disk
    if ModData.transmit then
        ModData.transmit("BurdJournals_PlayerBaselines")
    end

    print("[BurdJournals] ADMIN " .. tostring(player:getUsername()) .. " cleared ALL baseline caches (" .. clearedCount .. " entries)")

    -- Notify the admin
    BurdJournals.Server.sendToClient(player, "allBaselinesCleared", {
        clearedCount = clearedCount
    })
end

function BurdJournals.Server.handleRequestBaseline(player, args)
    if not player then return end

    local characterId = BurdJournals.getPlayerCharacterId(player)
    if not characterId then
        print("[BurdJournals] ERROR: Could not compute characterId for baseline request")
        BurdJournals.Server.sendToClient(player, "baselineResponse", {
            found = false,
            characterId = nil
        })
        return
    end

    local cachedBaseline = BurdJournals.Server.getCachedBaseline(characterId)

    if cachedBaseline then
        BurdJournals.debugPrint("[BurdJournals] Found cached baseline for " .. characterId)
        BurdJournals.Server.sendToClient(player, "baselineResponse", {
            found = true,
            characterId = characterId,
            skillBaseline = cachedBaseline.skillBaseline,
            mediaSkillBaseline = cachedBaseline.mediaSkillBaseline or {},
            traitBaseline = cachedBaseline.traitBaseline,
            recipeBaseline = cachedBaseline.recipeBaseline,
            debugModified = cachedBaseline.debugModified  -- Include debug flag
        })
    else
        -- CRITICAL: Server cache is empty, but player's own ModData might have baseline!
        -- This handles TWO scenarios:
        -- 1. MIGRATION: Old production version stored baseline in player ModData - migrate to new system
        -- 2. RECOVERY: After mod update, global ModData was lost but player ModData was preserved
        local playerModData = player:getModData()
        local playerBaseline = playerModData and playerModData.BurdJournals
        
        -- Log what we found for diagnostics
        local hasBaselineFlag = playerBaseline and playerBaseline.baselineCaptured
        local hasSkillData = playerBaseline and type(playerBaseline.skillBaseline) == "table"
        local hasTraitData = playerBaseline and type(playerBaseline.traitBaseline) == "table"
        local hasDebugFlag = playerBaseline and playerBaseline.debugModified
        
        BurdJournals.debugPrint("[BurdJournals] No server cache for " .. characterId .. " - checking player ModData...")
        BurdJournals.debugPrint("[BurdJournals]   baselineCaptured: " .. tostring(hasBaselineFlag))
        BurdJournals.debugPrint("[BurdJournals]   skillBaseline: " .. tostring(hasSkillData))
        BurdJournals.debugPrint("[BurdJournals]   traitBaseline: " .. tostring(hasTraitData))
        BurdJournals.debugPrint("[BurdJournals]   debugModified: " .. tostring(hasDebugFlag))
        
        if playerBaseline and playerBaseline.baselineCaptured then
            -- Player has baseline in their own ModData - restore it to server cache!
            -- Defensive: ensure these are actually tables before trying to use them
            local skillBaseline = playerBaseline.skillBaseline
            local mediaSkillBaseline = playerBaseline.mediaSkillBaseline
            local traitBaseline = playerBaseline.traitBaseline
            local recipeBaseline = playerBaseline.recipeBaseline
            if not mediaSkillBaseline and BurdJournals.getPlayerVhsSkillXPMapCopy then
                mediaSkillBaseline = BurdJournals.getPlayerVhsSkillXPMapCopy(player)
            end
            
            -- Check if data exists by counting keys (more reliable than next() for Java objects)
            local hasSkillData = false
            local hasMediaData = false
            local hasTraitData = false
            
            -- Count skill baseline entries (handles Java object serialization issues)
            if skillBaseline then
                for k, v in pairs(skillBaseline) do
                    if k and v then
                        hasSkillData = true
                        break
                    end
                end
            end
            
            -- Count trait baseline entries
            if traitBaseline then
                for k, v in pairs(traitBaseline) do
                    if k and v then
                        hasTraitData = true
                        break
                    end
                end
            end

            -- Count media-skill baseline entries
            if mediaSkillBaseline then
                for k, v in pairs(mediaSkillBaseline) do
                    if k and v then
                        hasMediaData = true
                        break
                    end
                end
            end
            
            local hasData = hasSkillData or hasMediaData or hasTraitData
            
            if hasData then
                -- Determine if this is migration from old version or recovery from mod update
                local recoveryType = hasDebugFlag and "RECOVERY (debug-modified baseline)" or "MIGRATION (from player ModData)"
                
                -- Deep copy the baseline data to pure Lua tables (handles Java object serialization issues)
                local copiedSkillBaseline = {}
                local copiedMediaSkillBaseline = {}
                local copiedTraitBaseline = {}
                local copiedRecipeBaseline = {}
                
                if skillBaseline then
                    for k, v in pairs(skillBaseline) do
                        if k then copiedSkillBaseline[k] = v end
                    end
                end
                if traitBaseline then
                    for k, v in pairs(traitBaseline) do
                        if k then copiedTraitBaseline[k] = v end
                    end
                end
                if mediaSkillBaseline then
                    for k, v in pairs(mediaSkillBaseline) do
                        if k then copiedMediaSkillBaseline[k] = v end
                    end
                end
                if recipeBaseline then
                    for k, v in pairs(recipeBaseline) do
                        if k then copiedRecipeBaseline[k] = v end
                    end
                end
                
                local skillCount = BurdJournals.countTable(copiedSkillBaseline)
                local mediaSkillCount = BurdJournals.countTable(copiedMediaSkillBaseline)
                local traitCount = BurdJournals.countTable(copiedTraitBaseline)
                
                BurdJournals.debugPrint("[BurdJournals] " .. recoveryType .. " for " .. characterId)
                BurdJournals.debugPrint("[BurdJournals]   Restoring " .. skillCount .. " skill baselines, "
                    .. mediaSkillCount .. " media skill baselines, " .. traitCount .. " trait baselines")
                
                -- Restore to server cache for future requests (using copied Lua tables)
                local restoredBaseline = {
                    skillBaseline = copiedSkillBaseline,
                    mediaSkillBaseline = copiedMediaSkillBaseline,
                    traitBaseline = copiedTraitBaseline,
                    recipeBaseline = copiedRecipeBaseline,
                    debugModified = playerBaseline.debugModified or false,
                    steamId = BurdJournals.getPlayerSteamId(player),
                    characterName = player:getDescriptor():getForename() .. " " .. player:getDescriptor():getSurname(),
                    capturedAt = getGameTime():getWorldAgeHours(),
                    recoveredFromPlayerModData = true,  -- Flag that this was recovered/migrated
                    migrationSource = hasDebugFlag and "recovery" or "migration"
                }
                
                -- Store in server cache (force overwrite since cache is empty)
                local cache = BurdJournals.Server.getBaselineCache()
                cache.players[characterId] = restoredBaseline
                
                -- Persist the recovered data
                if ModData.transmit then
                    ModData.transmit("BurdJournals_PlayerBaselines")
                end
                
                BurdJournals.debugPrint("[BurdJournals] SUCCESS: Baseline restored to server cache for " .. characterId)
                
                -- Return the recovered baseline
                BurdJournals.Server.sendToClient(player, "baselineResponse", {
                    found = true,
                    characterId = characterId,
                    skillBaseline = restoredBaseline.skillBaseline,
                    mediaSkillBaseline = restoredBaseline.mediaSkillBaseline or {},
                    traitBaseline = restoredBaseline.traitBaseline,
                    recipeBaseline = restoredBaseline.recipeBaseline,
                    debugModified = restoredBaseline.debugModified,
                    recovered = true  -- Let client know this was recovered
                })
                return
            else
                BurdJournals.debugPrint("[BurdJournals] Player has baselineCaptured=true but no actual data (empty baselines)")
            end
        elseif playerBaseline then
            -- Player has BurdJournals data but no baselineCaptured flag - might be very old version
            BurdJournals.debugPrint("[BurdJournals] Player has BurdJournals data but no baselineCaptured flag - cannot migrate")
        else
            BurdJournals.debugPrint("[BurdJournals] No BurdJournals data in player ModData")
        end
        
        BurdJournals.debugPrint("[BurdJournals] No baseline found for " .. characterId .. " (new player)")
        BurdJournals.Server.sendToClient(player, "baselineResponse", {
            found = false,
            characterId = characterId
        })
    end
end

BurdJournals.Server.BASELINE_CACHE_TTL_HOURS = 720

BurdJournals.Server._lastBaselineCleanup = 0

BurdJournals.Server.BASELINE_CLEANUP_INTERVAL = 24

function BurdJournals.Server.pruneBaselineCache()
    local cache = BurdJournals.Server.getBaselineCache()
    if not cache.players then return 0 end

    local currentHours = getGameTime():getWorldAgeHours()
    local ttl = BurdJournals.Server.BASELINE_CACHE_TTL_HOURS
    local prunedCount = 0
    local toRemove = {}

    for characterId, baseline in pairs(cache.players) do
        local capturedAt = baseline.capturedAt or 0
        local age = currentHours - capturedAt

        if age > ttl then
            table.insert(toRemove, characterId)
        end
    end

    for _, characterId in ipairs(toRemove) do
        cache.players[characterId] = nil
        prunedCount = prunedCount + 1
        BurdJournals.debugPrint("[BurdJournals] Pruned stale baseline for: " .. characterId)
    end

    if prunedCount > 0 then
        -- Persist pruned cache to disk
        if ModData.transmit then
            ModData.transmit("BurdJournals_PlayerBaselines")
        end
        BurdJournals.debugPrint("[BurdJournals] Baseline cache cleanup: removed " .. prunedCount .. " stale entries")
    end

    return prunedCount
end

function BurdJournals.Server.checkBaselineCleanup()
    local currentHours = getGameTime():getWorldAgeHours()
    local timeSinceCleanup = currentHours - BurdJournals.Server._lastBaselineCleanup

    if timeSinceCleanup >= BurdJournals.Server.BASELINE_CLEANUP_INTERVAL then
        BurdJournals.Server._lastBaselineCleanup = currentHours
        BurdJournals.Server.pruneBaselineCache()
    end
end

function BurdJournals.Server.forceBaselineCleanup()
    BurdJournals.debugPrint("[BurdJournals] Admin: Forcing baseline cache cleanup...")
    local pruned = BurdJournals.Server.pruneBaselineCache()
    BurdJournals.debugPrint("[BurdJournals] Admin: Cleanup complete, removed " .. pruned .. " entries")
    return pruned
end

-- One-shot admin migration: proactively migrate all online players' journals.
local function forEachInventoryItemRecursive(container, visitor)
    if not container or not visitor or not container.getItems then
        return
    end
    local items = container:getItems()
    if not items then
        return
    end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            visitor(item)
            if item.getInventory then
                local subInventory = item:getInventory()
                if subInventory then
                    forEachInventoryItemRecursive(subInventory, visitor)
                end
            end
        end
    end
end

function BurdJournals.Server.handleDebugMigrateOnlineJournals(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local stats = {
        players = 0,
        journalsScanned = 0,
        journalsUpdated = 0,
    }

    local function processPlayer(targetPlayer)
        if not targetPlayer or not targetPlayer.getInventory then
            return
        end
        local inventory = targetPlayer:getInventory()
        if not inventory then
            return
        end

        stats.players = stats.players + 1
        forEachInventoryItemRecursive(inventory, function(item)
            if not item or not item.getModData then
                return
            end
            local modData = item:getModData()
            local data = modData and modData.BurdJournals
            if type(data) ~= "table" then
                return
            end

            stats.journalsScanned = stats.journalsScanned + 1
            local beforeSchema = tonumber(data.migrationSchemaVersion) or 0
            local beforeSanitize = tonumber(data.sanitizedVersion) or 0
            local beforeCompact = tonumber(data.compactVersion) or 0
            local beforeDrLegacy = data.drLegacyMode3Migrated == true

            BurdJournals.migrateJournalIfNeeded(item, targetPlayer)

            local afterData = modData.BurdJournals or data
            local afterSchema = tonumber(afterData.migrationSchemaVersion) or 0
            local afterSanitize = tonumber(afterData.sanitizedVersion) or 0
            local afterCompact = tonumber(afterData.compactVersion) or 0
            local afterDrLegacy = afterData.drLegacyMode3Migrated == true
            if afterSchema > beforeSchema
                or afterSanitize > beforeSanitize
                or afterCompact > beforeCompact
                or (afterDrLegacy and not beforeDrLegacy) then
                stats.journalsUpdated = stats.journalsUpdated + 1
            end
        end)
    end

    local onlinePlayers = getOnlinePlayers and getOnlinePlayers() or nil
    if onlinePlayers and onlinePlayers.size then
        for i = 0, onlinePlayers:size() - 1 do
            processPlayer(onlinePlayers:get(i))
        end
    else
        processPlayer(player)
    end

    local message = "Journal migration complete: "
        .. tostring(stats.journalsUpdated)
        .. " updated / "
        .. tostring(stats.journalsScanned)
        .. " scanned across "
        .. tostring(stats.players)
        .. " player(s)."
    BurdJournals.debugPrint("[BurdJournals] " .. message)
    BurdJournals.Server.sendToClient(player, "debugSuccess", {message = message, stats = stats})
end

-- ============================================================================
-- Debug Journal Backup System (Server-side persistence for MP)
-- ============================================================================
-- These functions mirror the baseline system to provide server-side persistence
-- for debug-edited journals on dedicated servers where client ModData.transmit
-- doesn't persist to the global ModData cache.

-- Get or create the debug journal backup cache (server-side global ModData)
function BurdJournals.Server.getDebugJournalCache()
    local cache = ModData.getOrCreate("BurdJournals_DebugJournalCache")
    if not cache.journals then
        cache.journals = {}
    end
    return cache
end

function BurdJournals.Server.getJournalUUIDIndex()
    local cache = ModData.getOrCreate("BurdJournals_JournalUUIDIndex")
    if type(cache.journals) ~= "table" then
        cache.journals = {}
    end
    return cache
end

local function trimUUID(value)
    if value == nil then return nil end
    local uuid = tostring(value)
    uuid = uuid:gsub("^%s+", "")
    uuid = uuid:gsub("%s+$", "")
    if uuid == "" then
        return nil
    end
    return uuid
end

local function normalizeIdentityValue(value)
    return trimUUID(value)
end

local function safeLower(value)
    if value == nil then
        return nil
    end
    return string.lower(tostring(value))
end

local function getPlayerJournalIdentity(player)
    if not player then
        return nil, nil
    end

    local username = player.getUsername and normalizeIdentityValue(player:getUsername()) or nil
    local steamId = nil
    if BurdJournals.getPlayerSteamId then
        steamId = normalizeIdentityValue(BurdJournals.getPlayerSteamId(player))
    end

    return username, steamId
end

local function isServerJournalScopeAdmin(player)
    if not player then
        return false
    end
    if player.isAccessLevel and player:isAccessLevel("admin") then
        return true
    end
    local accessLevel = player.getAccessLevel and player:getAccessLevel() or nil
    return type(accessLevel) == "string" and string.lower(accessLevel) == "admin"
end

local function canPlayerAccessJournalSnapshot(player, ownerUsername, ownerSteamId, cachedPlayerUsername, cachedPlayerSteamId)
    if isServerJournalScopeAdmin(player) then
        return true
    end

    local playerUsername = cachedPlayerUsername
    local playerSteamId = cachedPlayerSteamId
    if not playerUsername and not playerSteamId then
        playerUsername, playerSteamId = getPlayerJournalIdentity(player)
    end

    local normalizedOwnerSteamId = normalizeIdentityValue(ownerSteamId)
    if normalizedOwnerSteamId and playerSteamId and normalizedOwnerSteamId == playerSteamId then
        return true
    end

    local normalizedOwnerUsername = normalizeIdentityValue(ownerUsername)
    if normalizedOwnerUsername and playerUsername and safeLower(normalizedOwnerUsername) == safeLower(playerUsername) then
        return true
    end

    return false
end

local function sendJournalScopeDenied(player, actionLabel)
    BurdJournals.Server.sendToClient(player, "debugError", {
        message = tostring(actionLabel or "Journal action") .. " denied: admin scope required or journal ownership mismatch."
    })
end

local applyNormalizedDebugJournalDataToItem = nil

local function persistDebugJournalSnapshot(player, journalKey, sourceData, journalRef, options)
    options = options or {}
    if type(sourceData) ~= "table" then
        return nil, nil
    end

    local normalized = BurdJournals.normalizeJournalData and BurdJournals.normalizeJournalData(sourceData) or sourceData
    if type(normalized) ~= "table" then
        return nil, nil
    end

    local nowTs = getTimestampMs and getTimestampMs() or os.time()
    local backupUUID = trimUUID(normalized.uuid or journalKey)
    local backupKey = trimUUID(journalKey) or backupUUID
    if not backupKey then
        return nil, nil
    end

    local existingKey, existingBackup = BurdJournals.Server.findDebugBackupByUUID(backupUUID or backupKey)
    local existingRevision = tonumber(existingBackup and (existingBackup.revision or existingBackup.debugRevision)) or 0
    local incomingRevision = tonumber(normalized.debugRevision) or tonumber(normalized.revision) or 0
    local nextRevision = math.max(existingRevision, incomingRevision) + 1
    normalized.debugRevision = nextRevision

    local cache = BurdJournals.Server.getDebugJournalCache()
    local snapshot = {
        skills = {},
        traits = {},
        recipes = {},
        stats = {},
        skillReadCounts = {},
        drLegacyMode3Migrated = normalized.drLegacyMode3Migrated == true,
        migrationSchemaVersion = tonumber(normalized.migrationSchemaVersion) or 0,
        isDebugSpawned = true,
        isDebugEdited = normalized.isDebugEdited or true,
        isPlayerCreated = normalized.isPlayerCreated or true,
        sanitizedVersion = normalized.sanitizedVersion,
        uuid = backupUUID or normalized.uuid,
        itemType = normalized.itemType or (journalRef and journalRef.getFullType and journalRef:getFullType() or nil),
        itemID = normalized.itemID or normalized.itemId or (journalRef and journalRef.getID and journalRef:getID() or nil),
        itemName = normalized.itemName or (journalRef and journalRef.getName and journalRef:getName() or nil),
        ownerUsername = normalized.ownerUsername,
        ownerSteamId = normalized.ownerSteamId,
        ownerCharacterName = normalized.ownerCharacterName,
        wasFromWorn = normalized.wasFromWorn == true,
        wasFromBloody = normalized.wasFromBloody == true,
        wasRestored = normalized.wasRestored == true,
        readCount = tonumber(normalized.readCount) or 0,
        readSessionCount = tonumber(normalized.readSessionCount) or 0,
        currentSessionId = normalized.currentSessionId,
        currentSessionReadCount = tonumber(normalized.currentSessionReadCount) or 0,
        timestamp = nowTs,
        savedBy = options.savedBy or (player and player.getUsername and player:getUsername() or nil),
        revision = nextRevision,
        debugRevision = nextRevision,
        pendingApply = options.pendingApply == true,
        pendingReason = options.pendingReason,
        pendingRequestedBy = options.pendingApply == true and (options.pendingRequestedBy or (player and player.getUsername and player:getUsername() or nil)) or nil,
        pendingRequestedTs = options.pendingApply == true and nowTs or nil,
        lastAppliedTs = options.lastAppliedTs,
        sourceTag = options.sourceTag or "debugBackup",
    }

    if normalized.skills then
        for skillName, skillData in pairs(normalized.skills) do
            if skillName and skillData then
                snapshot.skills[skillName] = {
                    xp = tonumber(type(skillData) == "table" and skillData.xp or skillData) or 0,
                    level = tonumber(type(skillData) == "table" and skillData.level) or 0
                }
            end
        end
    end

    if normalized.traits then
        for traitId, value in pairs(normalized.traits) do
            if traitId then
                snapshot.traits[traitId] = value
            end
        end
    end

    if normalized.recipes then
        for recipeName, value in pairs(normalized.recipes) do
            if recipeName then
                snapshot.recipes[recipeName] = value
            end
        end
    end

    if normalized.stats then
        for statId, statData in pairs(normalized.stats) do
            if statId then
                snapshot.stats[statId] = statData
            end
        end
    end

    local normalizedSkillReadCounts = normalized.skillReadCounts
    if type(normalizedSkillReadCounts) ~= "table" and BurdJournals.normalizeTable then
        normalizedSkillReadCounts = BurdJournals.normalizeTable(normalizedSkillReadCounts)
    end
    if type(normalizedSkillReadCounts) == "table" then
        for skillName, count in pairs(normalizedSkillReadCounts) do
            if skillName then
                snapshot.skillReadCounts[skillName] = tonumber(count) or 0
            end
        end
    end

    cache.journals[backupKey] = snapshot
    if backupUUID then
        cache.journals[backupUUID] = snapshot
    end
    if existingKey and existingKey ~= backupKey and existingKey ~= backupUUID then
        cache.journals[existingKey] = nil
    end

    if backupUUID then
        local uuidIndex = BurdJournals.Server.getJournalUUIDIndex()
        local existingIndex = type(uuidIndex.journals[backupUUID]) == "table" and uuidIndex.journals[backupUUID] or nil
        uuidIndex.journals[backupUUID] = {
            uuid = backupUUID,
            itemName = snapshot.itemName or (existingIndex and existingIndex.itemName) or nil,
            itemType = snapshot.itemType or (existingIndex and existingIndex.itemType) or nil,
            itemId = snapshot.itemID or (existingIndex and existingIndex.itemId) or nil,
            ownerUsername = snapshot.ownerUsername or (existingIndex and existingIndex.ownerUsername) or nil,
            ownerSteamId = snapshot.ownerSteamId or (existingIndex and existingIndex.ownerSteamId) or nil,
            ownerCharacterName = snapshot.ownerCharacterName or (existingIndex and existingIndex.ownerCharacterName) or nil,
            isPlayerCreated = snapshot.isPlayerCreated == true,
            wasFromWorn = snapshot.wasFromWorn == true,
            wasFromBloody = snapshot.wasFromBloody == true,
            wasRestored = snapshot.wasRestored == true,
            skillCount = BurdJournals.countTable and BurdJournals.countTable(snapshot.skills) or 0,
            traitCount = BurdJournals.countTable and BurdJournals.countTable(snapshot.traits) or 0,
            recipeCount = BurdJournals.countTable and BurdJournals.countTable(snapshot.recipes) or 0,
            statCount = BurdJournals.countTable and BurdJournals.countTable(snapshot.stats) or 0,
            sourceTag = options.sourceTag or (snapshot.pendingApply and "deferredDebugEdit" or "debugBackup"),
            lastSeenTs = nowTs,
            pendingApply = snapshot.pendingApply == true,
            revision = nextRevision,
        }
    end

    return backupUUID or backupKey, snapshot
end

function BurdJournals.Server.findLiveJournalByUUID(uuid)
    local targetUUID = trimUUID(uuid)
    if not targetUUID then
        return nil, nil
    end

    local onlinePlayers = getOnlinePlayers and getOnlinePlayers() or nil
    if onlinePlayers and onlinePlayers.size then
        for i = 0, onlinePlayers:size() - 1 do
            local targetPlayer = onlinePlayers:get(i)
            if targetPlayer then
                local found = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(targetPlayer, targetUUID)
                if found then
                    return found, targetPlayer
                end
            end
        end
    end

    return nil, nil
end

function BurdJournals.Server.findDebugBackupByUUID(uuid)
    local targetUUID = trimUUID(uuid)
    if not targetUUID then
        return nil, nil
    end

    local cache = BurdJournals.Server.getDebugJournalCache()
    local journals = cache and cache.journals
    if type(journals) ~= "table" then
        return nil, nil
    end

    local direct = journals[targetUUID]
    if type(direct) == "table" then
        return targetUUID, direct
    end

    for journalKey, backup in pairs(journals) do
        if type(backup) == "table" and tostring(backup.uuid or "") == targetUUID then
            return journalKey, backup
        end
    end

    return nil, nil
end

function BurdJournals.Server.seedDebugSnapshotFromLiveJournal(journal, ownerPlayer, sourceTag)
    if not journal or not journal.getModData then
        return nil
    end

    local modData = journal:getModData()
    local data = modData and modData.BurdJournals or nil
    if type(data) ~= "table" then
        return nil
    end

    local uuid = trimUUID(data.uuid)
    if not uuid then
        return nil
    end

    local _, existingBackup = BurdJournals.Server.findDebugBackupByUUID(uuid)
    if type(existingBackup) == "table" then
        return uuid
    end

    local storedUUID, snapshot = persistDebugJournalSnapshot(ownerPlayer, uuid, data, journal, {
        savedBy = "__autoOpen",
        pendingApply = false,
        sourceTag = sourceTag or "autoOpenSnapshot",
    })

    if storedUUID and type(snapshot) == "table" then
        local revision = tonumber(snapshot.revision or snapshot.debugRevision)
        if revision and revision > (tonumber(data.debugRevision) or 0) then
            data.debugRevision = revision
            if journal.transmitModData then
                journal:transmitModData()
            end
        end
        if ModData.transmit then
            ModData.transmit("BurdJournals_DebugJournalCache")
            ModData.transmit("BurdJournals_JournalUUIDIndex")
        end
    end

    return storedUUID
end

function BurdJournals.Server.updateJournalUUIDIndex(journal, ownerPlayer, sourceTag)
    if not journal or not journal.getModData then
        return nil
    end

    local modData = journal:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    local data = modData.BurdJournals

    if not data.uuid then
        data.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
            or ("journal-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
        if journal.transmitModData then
            journal:transmitModData()
        end
    end

    local uuid = trimUUID(data.uuid)
    if not uuid then
        return nil
    end

    local nowTs = getTimestampMs and getTimestampMs() or os.time()
    local backupDirty = false
    local backupKey, backup = BurdJournals.Server.findDebugBackupByUUID(uuid)
    local pendingApplied = false
    if type(backup) == "table" and backup.pendingApply == true and applyNormalizedDebugJournalDataToItem then
        local liveRevision = tonumber(data.debugRevision) or 0
        local pendingRevision = tonumber(backup.revision or backup.debugRevision) or 0
        local shouldApplyPending = pendingRevision > liveRevision

        if shouldApplyPending then
            local normalizedBackup = BurdJournals.normalizeJournalData and BurdJournals.normalizeJournalData(backup) or backup
            local appliedData = applyNormalizedDebugJournalDataToItem(journal, normalizedBackup, uuid)
            if type(appliedData) == "table" then
                appliedData.debugRevision = math.max(tonumber(appliedData.debugRevision) or 0, pendingRevision)
                data = appliedData
                pendingApplied = true
                if journal.transmitModData then
                    journal:transmitModData()
                end
            end
        end

        backup.pendingApply = false
        backup.pendingReason = nil
        backup.pendingRequestedBy = nil
        backup.pendingRequestedTs = nil
        backup.lastAppliedTs = nowTs
        backup.appliedBy = pendingApplied and "__autoSync" or (backup.appliedBy or "__autoSync")
        backup.itemID = journal.getID and journal:getID() or backup.itemID
        backup.itemType = journal.getFullType and journal:getFullType() or backup.itemType
        backup.itemName = journal.getName and journal:getName() or backup.itemName
        local effectiveRevision = math.max(tonumber(backup.revision or backup.debugRevision) or 0, tonumber(data.debugRevision) or 0)
        backup.revision = effectiveRevision
        backup.debugRevision = effectiveRevision
        backup.timestamp = nowTs
        backup.sourceTag = pendingApplied and "autoApplied" or (backup.sourceTag or "debugBackup")
        backupDirty = true
    end

    local indexCache = BurdJournals.Server.getJournalUUIDIndex()
    indexCache.journals[uuid] = {
        uuid = uuid,
        itemName = journal.getName and journal:getName() or nil,
        itemType = journal.getFullType and journal:getFullType() or nil,
        itemId = journal.getID and journal:getID() or nil,
        ownerUsername = (type(data.ownerUsername) == "string" and data.ownerUsername ~= "") and data.ownerUsername or (ownerPlayer and ownerPlayer:getUsername() or nil),
        ownerSteamId = data.ownerSteamId,
        ownerCharacterName = data.ownerCharacterName,
        isPlayerCreated = data.isPlayerCreated == true,
        wasFromWorn = data.wasFromWorn == true,
        wasFromBloody = data.wasFromBloody == true,
        wasRestored = BurdJournals.isRestoredJournalData and BurdJournals.isRestoredJournalData(data) or (data.wasRestored == true),
        skillCount = BurdJournals.countTable and BurdJournals.countTable(data.skills) or 0,
        traitCount = BurdJournals.countTable and BurdJournals.countTable(data.traits) or 0,
        recipeCount = BurdJournals.countTable and BurdJournals.countTable(data.recipes) or 0,
        statCount = BurdJournals.countTable and BurdJournals.countTable(data.stats) or 0,
        sourceTag = pendingApplied and ("autoApplied:" .. tostring(sourceTag or "unknown")) or (sourceTag or "unknown"),
        lastSeenTs = nowTs,
        pendingApply = false,
        revision = tonumber(data.debugRevision) or tonumber(backup and backup.revision) or 0,
    }

    if ModData.transmit then
        ModData.transmit("BurdJournals_JournalUUIDIndex")
        if backupDirty then
            ModData.transmit("BurdJournals_DebugJournalCache")
        end
    end

    return uuid
end

function BurdJournals.Server.refreshJournalUUIDIndexFromOnlineInventories()
    local stats = {
        playersScanned = 0,
        journalsScanned = 0,
        journalsIndexed = 0,
    }

    local function scanPlayer(targetPlayer)
        if not targetPlayer or not targetPlayer.getInventory then
            return
        end

        local inventory = targetPlayer:getInventory()
        if not inventory then
            return
        end

        stats.playersScanned = stats.playersScanned + 1

        forEachInventoryItemRecursive(inventory, function(item)
            if not item or not item.getModData then
                return
            end
            if not BurdJournals.isFilledJournal or not BurdJournals.isFilledJournal(item) then
                return
            end

            stats.journalsScanned = stats.journalsScanned + 1

            local modData = item:getModData()
            local journalData = modData and modData.BurdJournals or nil
            if type(journalData) ~= "table" then
                return
            end

            local indexedUUID = BurdJournals.Server.updateJournalUUIDIndex(item, targetPlayer, "inventoryScan")
            if indexedUUID then
                stats.journalsIndexed = stats.journalsIndexed + 1
            end
        end)
    end

    local onlinePlayers = getOnlinePlayers and getOnlinePlayers() or nil
    if onlinePlayers and onlinePlayers.size then
        for i = 0, onlinePlayers:size() - 1 do
            scanPlayer(onlinePlayers:get(i))
        end
    end

    return stats
end

-- Handle client request to save debug journal backup to server-side storage
function BurdJournals.Server.handleSaveDebugJournalBackup(player, args)
    if not player or not args then
        print("[BurdJournals] ERROR: handleSaveDebugJournalBackup - missing player or args")
        return
    end
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local journalKey = args.journalKey
    if not journalKey then
        print("[BurdJournals] ERROR: handleSaveDebugJournalBackup - no journalKey")
        return
    end

    local journalData = args.journalData
    if not journalData then
        print("[BurdJournals] ERROR: handleSaveDebugJournalBackup - no journalData")
        return
    end
    local normalizedJournalData = BurdJournals.normalizeJournalData and BurdJournals.normalizeJournalData(journalData) or journalData
    local storedUUID = persistDebugJournalSnapshot(player, journalKey, normalizedJournalData, nil, {
        savedBy = player:getUsername(),
        pendingApply = false,
        sourceTag = "debugBackup",
    })
    if not storedUUID then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Failed to save debug journal backup"})
        return
    end

    -- Persist to disk (server-side ModData.transmit works on dedicated servers)
    if ModData.transmit then
        ModData.transmit("BurdJournals_DebugJournalCache")
        ModData.transmit("BurdJournals_JournalUUIDIndex")
    end

    BurdJournals.debugPrint("[BurdJournals] Server: Saved debug journal backup for key=" .. tostring(journalKey) .. " by " .. tostring(player:getUsername()))

    -- Notify client of success
    BurdJournals.Server.sendToClient(player, "debugJournalBackupSaved", {
        journalKey = journalKey,
        success = true
    })
end

-- Handle client request for debug journal backup data (for restoration)
function BurdJournals.Server.handleRequestDebugJournalBackup(player, args)
    if not player or not args then return end
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local journalKey = args.journalKey
    if not journalKey then
        print("[BurdJournals] ERROR: handleRequestDebugJournalBackup - no journalKey")
        return
    end

    local cache = BurdJournals.Server.getDebugJournalCache()
    local backup = cache.journals and cache.journals[journalKey]

    if backup then
        BurdJournals.debugPrint("[BurdJournals] Server: Found debug journal backup for key=" .. tostring(journalKey))
        BurdJournals.Server.sendToClient(player, "debugJournalBackupResponse", {
            journalKey = journalKey,
            found = true,
            journalData = backup
        })
    else
        BurdJournals.debugPrint("[BurdJournals] Server: No debug journal backup found for key=" .. tostring(journalKey))
        BurdJournals.Server.sendToClient(player, "debugJournalBackupResponse", {
            journalKey = journalKey,
            found = false
        })
    end
end

function BurdJournals.Server.handleDebugLookupJournalByUUID(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local uuid = trimUUID(args and args.uuid)
    if not uuid then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "UUID is required"})
        return
    end

    local journal, ownerPlayer = BurdJournals.Server.findLiveJournalByUUID(uuid)
    if journal then
        local modData = journal:getModData()
        local data = modData and modData.BurdJournals or {}
        local ownerUsername = data.ownerUsername or (ownerPlayer and ownerPlayer:getUsername()) or nil
        local ownerSteamId = data.ownerSteamId or (ownerPlayer and BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(ownerPlayer)) or nil
        if not canPlayerAccessJournalSnapshot(player, ownerUsername, ownerSteamId) then
            sendJournalScopeDenied(player, "Journal lookup")
            return
        end

        local appliedCachedEdits = false
        local backupKey, backup = BurdJournals.Server.findDebugBackupByUUID(uuid)
        if backup then
            local normalizedBackup = BurdJournals.normalizeJournalData(backup) or backup
            if type(normalizedBackup) == "table" and applyNormalizedDebugJournalDataToItem(journal, normalizedBackup, uuid) then
                if journal.transmitModData then
                    journal:transmitModData()
                end
                appliedCachedEdits = true
            end
        end

        local liveSnapshot = BurdJournals.Server.copyJournalData and BurdJournals.Server.copyJournalData(journal) or nil
        if type(liveSnapshot) == "table" and BurdJournals.normalizeJournalData then
            liveSnapshot = BurdJournals.normalizeJournalData(liveSnapshot) or liveSnapshot
        end

        BurdJournals.Server.updateJournalUUIDIndex(journal, ownerPlayer, "lookup")
        local indexCache = BurdJournals.Server.getJournalUUIDIndex()
        local indexEntry = indexCache and indexCache.journals and indexCache.journals[uuid] or nil

        BurdJournals.Server.sendToClient(player, "debugJournalUUIDLookupResult", {
            uuid = uuid,
            found = true,
            live = true,
            journalId = journal:getID(),
            itemType = journal:getFullType(),
            itemName = journal.getName and journal:getName() or nil,
            ownerUsername = ownerUsername or "Unknown",
            ownerSteamId = ownerSteamId,
            ownerCharacterName = data.ownerCharacterName,
            isPlayerCreated = data.isPlayerCreated == true,
            isRestored = BurdJournals.isRestoredJournalData and BurdJournals.isRestoredJournalData(data) or (data.wasRestored == true),
            wasFromWorn = data.wasFromWorn == true,
            wasFromBloody = data.wasFromBloody == true,
            skillCount = BurdJournals.countTable and BurdJournals.countTable(data.skills) or 0,
            traitCount = BurdJournals.countTable and BurdJournals.countTable(data.traits) or 0,
            recipeCount = BurdJournals.countTable and BurdJournals.countTable(data.recipes) or 0,
            statCount = BurdJournals.countTable and BurdJournals.countTable(data.stats) or 0,
            hasIndex = indexEntry ~= nil,
            indexEntry = indexEntry,
            hasBackup = backup ~= nil,
            appliedCachedEdits = appliedCachedEdits,
            backupKey = backupKey,
            backupData = backup,
            backupSavedBy = backup and backup.savedBy or nil,
            snapshotData = liveSnapshot,
            message = appliedCachedEdits and "Found live journal by UUID (applied cached edits)." or "Found live journal by UUID."
        })
        return
    end

    local indexCache = BurdJournals.Server.getJournalUUIDIndex()
    local indexEntry = indexCache and indexCache.journals and indexCache.journals[uuid] or nil
    local backupKey, backup = BurdJournals.Server.findDebugBackupByUUID(uuid)
    if not isServerJournalScopeAdmin(player) and (indexEntry or backup) then
        local cachedOwnerUsername = (type(indexEntry) == "table" and indexEntry.ownerUsername) or (type(backup) == "table" and backup.ownerUsername) or nil
        local cachedOwnerSteamId = (type(indexEntry) == "table" and indexEntry.ownerSteamId) or (type(backup) == "table" and backup.ownerSteamId) or nil
        if not canPlayerAccessJournalSnapshot(player, cachedOwnerUsername, cachedOwnerSteamId) then
            sendJournalScopeDenied(player, "Journal lookup")
            return
        end
    end

    BurdJournals.Server.sendToClient(player, "debugJournalUUIDLookupResult", {
        uuid = uuid,
        found = false,
        live = false,
        hasIndex = indexEntry ~= nil,
        indexEntry = indexEntry,
        hasBackup = backup ~= nil,
        backupKey = backupKey,
        backupData = backup,
        backupSavedBy = backup and backup.savedBy or nil,
        message = (indexEntry or backup) and "No live journal found. Cached metadata available." or "UUID not found in live items or cache."
    })
end

function BurdJournals.Server.handleDebugRepairJournalByUUID(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    if not isServerJournalScopeAdmin(player) then
        sendJournalScopeDenied(player, "Journal repair")
        return
    end

    local uuid = trimUUID(args and args.uuid)
    if not uuid then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "UUID is required"})
        return
    end

    local journal, ownerPlayer = BurdJournals.Server.findLiveJournalByUUID(uuid)
    if not journal then
        BurdJournals.Server.sendToClient(player, "debugJournalUUIDRepairResult", {
            uuid = uuid,
            found = false,
            message = "No live journal found for UUID. Move near the container or have owner online."
        })
        return
    end

    local targetPlayer = ownerPlayer or player
    local modData = journal:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    local data = modData.BurdJournals
    local changed = 0

    if data.uuid ~= uuid then
        data.uuid = uuid
        changed = changed + 1
    end

    if args and args.markRestored then
        if data.isPlayerCreated ~= true then
            data.isPlayerCreated = true
            changed = changed + 1
        end
        if data.wasRestored ~= true then
            data.wasRestored = true
            changed = changed + 1
        end
        if data.wasFromWorn ~= true and data.wasFromBloody ~= true then
            data.wasFromWorn = true
            changed = changed + 1
        end
        if type(data.restoredBy) ~= "string" or data.restoredBy == "" then
            data.restoredBy = player and player:getUsername() or "Admin"
            changed = changed + 1
        end
        if data.isWorn == true then
            data.isWorn = false
            changed = changed + 1
        end
        if data.isBloody == true then
            data.isBloody = false
            changed = changed + 1
        end
    end

    if BurdJournals.migrateJournalIfNeeded then
        BurdJournals.migrateJournalIfNeeded(journal, targetPlayer)
    end
    local sanitizeResult = nil
    if BurdJournals.sanitizeJournalData then
        sanitizeResult = BurdJournals.sanitizeJournalData(journal, targetPlayer)
    end
    if BurdJournals.compactJournalData then
        BurdJournals.compactJournalData(journal)
    end

    if journal.transmitModData then
        journal:transmitModData()
    end
    BurdJournals.Server.updateJournalUUIDIndex(journal, ownerPlayer, "repair")

    local cleaned = sanitizeResult and sanitizeResult.cleaned == true
    local message = "UUID repair complete"
        .. " (changed=" .. tostring(changed)
        .. ", sanitized=" .. tostring(cleaned) .. ")"

    BurdJournals.Server.sendToClient(player, "debugJournalUUIDRepairResult", {
        uuid = uuid,
        found = true,
        journalId = journal:getID(),
        ownerUsername = data.ownerUsername or (ownerPlayer and ownerPlayer:getUsername()) or "Unknown",
        changed = changed,
        sanitized = cleaned,
        markRestored = args and args.markRestored == true,
        message = message,
    })
end

function BurdJournals.Server.handleDebugListJournalUUIDIndex(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local isAdminScope = isServerJournalScopeAdmin(player)
    local requesterUsername, requesterSteamId = nil, nil
    if not isAdminScope then
        requesterUsername, requesterSteamId = getPlayerJournalIdentity(player)
    end

    local scanStats = nil
    if BurdJournals.Server.refreshJournalUUIDIndexFromOnlineInventories then
        scanStats = BurdJournals.Server.refreshJournalUUIDIndexFromOnlineInventories()
    end

    local indexCache = BurdJournals.Server.getJournalUUIDIndex()
    local indexTable = indexCache and indexCache.journals or {}

    local maxEntries = tonumber(args and args.maxEntries) or 400
    if maxEntries < 25 then maxEntries = 25 end
    if maxEntries > 1000 then maxEntries = 1000 end

    local query = trimUUID(args and args.query)
    if query then
        query = string.lower(query)
    end

    local entries = {}
    for keyUuid, entry in pairs(indexTable) do
        if type(entry) == "table" then
            local uuid = trimUUID(entry.uuid or keyUuid)
            if uuid then
                local itemName = tostring(entry.itemName or "")
                local ownerCharacterName = tostring(entry.ownerCharacterName or "")
                local ownerUsername = tostring(entry.ownerUsername or "")
                local itemType = tostring(entry.itemType or "")

                local include = true
                if query then
                    local haystack = string.lower(itemName .. " " .. ownerCharacterName .. " " .. ownerUsername .. " " .. itemType .. " " .. uuid)
                    include = string.find(haystack, query, 1, true) ~= nil
                end
                if include and not isAdminScope then
                    include = canPlayerAccessJournalSnapshot(player, entry.ownerUsername, entry.ownerSteamId, requesterUsername, requesterSteamId)
                end

                if include then
                    table.insert(entries, {
                        uuid = uuid,
                        itemName = entry.itemName,
                        itemType = entry.itemType,
                        itemId = entry.itemId,
                        ownerUsername = entry.ownerUsername,
                        ownerCharacterName = entry.ownerCharacterName,
                        ownerSteamId = entry.ownerSteamId,
                        isPlayerCreated = entry.isPlayerCreated == true,
                        wasRestored = entry.wasRestored == true,
                        wasFromWorn = entry.wasFromWorn == true,
                        wasFromBloody = entry.wasFromBloody == true,
                        skillCount = tonumber(entry.skillCount) or 0,
                        traitCount = tonumber(entry.traitCount) or 0,
                        recipeCount = tonumber(entry.recipeCount) or 0,
                        statCount = tonumber(entry.statCount) or 0,
                        sourceTag = entry.sourceTag,
                        lastSeenTs = tonumber(entry.lastSeenTs) or 0,
                    })
                end
            end
        end
    end

    table.sort(entries, function(a, b)
        local ats = tonumber(a.lastSeenTs) or 0
        local bts = tonumber(b.lastSeenTs) or 0
        if ats ~= bts then
            return ats > bts
        end
        return tostring(a.uuid or "") < tostring(b.uuid or "")
    end)

    local total = #entries
    local truncated = false
    if total > maxEntries then
        for i = total, maxEntries + 1, -1 do
            entries[i] = nil
        end
        truncated = true
    end

    BurdJournals.Server.sendToClient(player, "debugJournalUUIDIndexList", {
        entries = entries,
        total = total,
        count = #entries,
        truncated = truncated,
        maxEntries = maxEntries,
        query = query,
        scope = isAdminScope and "admin" or "self",
        scanStats = scanStats,
    })
end

function BurdJournals.Server.handleDebugDeleteJournalByUUID(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    if not isServerJournalScopeAdmin(player) then
        sendJournalScopeDenied(player, "Journal delete")
        return
    end

    local uuid = trimUUID(args and args.uuid)
    if not uuid then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "UUID is required"})
        return
    end

    local deletedLive = false
    local deletedLiveOwner = nil
    local liveJournal, ownerPlayer = BurdJournals.Server.findLiveJournalByUUID(uuid)
    if liveJournal then
        local container = liveJournal.getContainer and liveJournal:getContainer() or nil
        if container then
            container:Remove(liveJournal)
            sendRemoveItemFromContainer(container, liveJournal)
            deletedLive = true
            deletedLiveOwner = ownerPlayer and ownerPlayer:getUsername() or nil
        end
    end

    local removedIndexEntries = 0
    local indexCache = BurdJournals.Server.getJournalUUIDIndex()
    local indexTable = indexCache and indexCache.journals or {}
    for key, entry in pairs(indexTable) do
        local entryUUID = trimUUID((type(entry) == "table" and entry.uuid) or key)
        if entryUUID == uuid then
            indexTable[key] = nil
            removedIndexEntries = removedIndexEntries + 1
        end
    end

    local removedBackupEntries = 0
    local backupCache = BurdJournals.Server.getDebugJournalCache()
    local backupTable = backupCache and backupCache.journals or {}
    for key, entry in pairs(backupTable) do
        local entryUUID = trimUUID((type(entry) == "table" and entry.uuid) or key)
        if entryUUID == uuid then
            backupTable[key] = nil
            removedBackupEntries = removedBackupEntries + 1
        end
    end

    if ModData.transmit then
        ModData.transmit("BurdJournals_JournalUUIDIndex")
        ModData.transmit("BurdJournals_DebugJournalCache")
    end

    local foundAny = deletedLive or removedIndexEntries > 0 or removedBackupEntries > 0
    local message = nil
    if foundAny then
        message = "UUID delete complete (live=" .. tostring(deletedLive)
            .. ", index=" .. tostring(removedIndexEntries)
            .. ", backup=" .. tostring(removedBackupEntries) .. ")"
    else
        message = "UUID not found in live items or cache."
    end

    BurdJournals.Server.sendToClient(player, "debugJournalUUIDDeleteResult", {
        uuid = uuid,
        found = foundAny,
        deletedLive = deletedLive,
        deletedLiveOwner = deletedLiveOwner,
        removedIndexEntries = removedIndexEntries,
        removedBackupEntries = removedBackupEntries,
        message = message,
    })
end

local function resolveDebugApplyJournalTarget(requestingPlayer, args)
    if not requestingPlayer or not args then
        return nil, nil, nil, nil, "invalidPayload", nil, nil
    end

    local requestedId = tonumber(args.journalId) or args.journalId
    local requestedUUID = trimUUID(args.journalUUID)
    if not requestedUUID and type(args.journalData) == "table" then
        requestedUUID = trimUUID(args.journalData.uuid)
    end
    if not requestedUUID then
        requestedUUID = trimUUID(args.journalKey)
    end

    local function resolveOwnerFromJournal(journalRef, fallbackOwnerPlayer)
        if not journalRef then
            return nil, nil
        end
        local modData = journalRef.getModData and journalRef:getModData() or nil
        local data = modData and modData.BurdJournals or nil
        local ownerUsername = type(data) == "table" and data.ownerUsername or nil
        local ownerSteamId = type(data) == "table" and data.ownerSteamId or nil
        if not ownerUsername and fallbackOwnerPlayer and fallbackOwnerPlayer.getUsername then
            ownerUsername = fallbackOwnerPlayer:getUsername()
        end
        if not ownerSteamId and fallbackOwnerPlayer and BurdJournals.getPlayerSteamId then
            ownerSteamId = BurdJournals.getPlayerSteamId(fallbackOwnerPlayer)
        end
        return ownerUsername, ownerSteamId
    end

    local ownerPlayer = requestingPlayer
    local journal = nil
    local resolvePath = "unresolved"
    local ownerUsername = nil
    local ownerSteamId = nil

    if requestedId then
        journal = BurdJournals.findItemById(requestingPlayer, requestedId)
        if journal then
            resolvePath = "requesterById"
            ownerUsername, ownerSteamId = resolveOwnerFromJournal(journal, ownerPlayer)
            return journal, ownerPlayer, requestedUUID, requestedId, resolvePath, ownerUsername, ownerSteamId
        end
    end

    if requestedUUID and BurdJournals.findJournalByUUID then
        journal = BurdJournals.findJournalByUUID(requestingPlayer, requestedUUID)
        if journal then
            resolvePath = "requesterByUUID"
            ownerUsername, ownerSteamId = resolveOwnerFromJournal(journal, ownerPlayer)
            return journal, ownerPlayer, requestedUUID, requestedId, resolvePath, ownerUsername, ownerSteamId
        end
    end

    if requestedUUID and BurdJournals.Server.findLiveJournalByUUID then
        journal, ownerPlayer = BurdJournals.Server.findLiveJournalByUUID(requestedUUID)
        if journal then
            resolvePath = "liveByUUID"
            ownerPlayer = ownerPlayer or requestingPlayer
            ownerUsername, ownerSteamId = resolveOwnerFromJournal(journal, ownerPlayer)
            return journal, ownerPlayer, requestedUUID, requestedId, resolvePath, ownerUsername, ownerSteamId
        end
    end

    if requestedUUID and BurdJournals.Server.getJournalUUIDIndex then
        local indexCache = BurdJournals.Server.getJournalUUIDIndex()
        local entry = indexCache and indexCache.journals and indexCache.journals[requestedUUID] or nil
        if type(entry) == "table" then
            ownerUsername = entry.ownerUsername or ownerUsername
            ownerSteamId = entry.ownerSteamId or ownerSteamId
            local indexedOwner = nil
            if entry.ownerUsername and BurdJournals.Server.findPlayerByUsername then
                indexedOwner = BurdJournals.Server.findPlayerByUsername(entry.ownerUsername)
            end
            local indexedId = tonumber(entry.itemId) or entry.itemId
            if indexedOwner and indexedId then
                journal = BurdJournals.findItemById(indexedOwner, indexedId)
                if journal then
                    resolvePath = "indexOwnerById"
                    ownerPlayer = indexedOwner
                    local liveOwnerUsername, liveOwnerSteamId = resolveOwnerFromJournal(journal, ownerPlayer)
                    return journal, ownerPlayer, requestedUUID, requestedId, resolvePath, liveOwnerUsername, liveOwnerSteamId
                end
            end
        end
    end

    if requestedUUID and BurdJournals.Server.findDebugBackupByUUID then
        local _, backup = BurdJournals.Server.findDebugBackupByUUID(requestedUUID)
        if type(backup) == "table" then
            ownerUsername = ownerUsername or backup.ownerUsername
            ownerSteamId = ownerSteamId or backup.ownerSteamId
        end
    end

    return nil, nil, requestedUUID, requestedId, resolvePath, ownerUsername, ownerSteamId
end

applyNormalizedDebugJournalDataToItem = function(journal, normalized, requestedUUID)
    if not journal or type(normalized) ~= "table" then
        return nil
    end

    local modData = journal:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    local bj = modData.BurdJournals

    if not bj.uuid then
        bj.uuid = normalized.uuid
            or requestedUUID
            or ((BurdJournals.generateUUID and BurdJournals.generateUUID()) or ("debug-" .. tostring(journal:getID())))
    end

    bj.skills = {}
    for skillName, skillData in pairs(normalized.skills or {}) do
        if skillName and type(skillData) == "table" then
            bj.skills[skillName] = {
                xp = tonumber(skillData.xp) or 0,
                level = tonumber(skillData.level) or 0
            }
        end
    end

    bj.traits = {}
    for traitId, value in pairs(normalized.traits or {}) do
        if traitId then
            bj.traits[traitId] = value
        end
    end

    bj.recipes = {}
    for recipeName, value in pairs(normalized.recipes or {}) do
        if recipeName then
            bj.recipes[recipeName] = value
        end
    end

    bj.stats = {}
    for statId, statData in pairs(normalized.stats or {}) do
        if statId then
            bj.stats[statId] = statData
        end
    end

    bj.readCount = tonumber(normalized.readCount) or 0
    bj.readSessionCount = tonumber(normalized.readSessionCount) or 0
    bj.currentSessionId = normalized.currentSessionId
    bj.currentSessionReadCount = tonumber(normalized.currentSessionReadCount) or 0
    bj.skillReadCounts = {}
    bj.drLegacyMode3Migrated = normalized.drLegacyMode3Migrated == true
    bj.migrationSchemaVersion = tonumber(normalized.migrationSchemaVersion) or (tonumber(BurdJournals.MIGRATION_SCHEMA_VERSION) or 0)
    local normalizedSkillReadCounts = normalized.skillReadCounts
    if type(normalizedSkillReadCounts) ~= "table" and BurdJournals.normalizeTable then
        normalizedSkillReadCounts = BurdJournals.normalizeTable(normalizedSkillReadCounts)
    end
    if type(normalizedSkillReadCounts) == "table" then
        for skillName, count in pairs(normalizedSkillReadCounts) do
            if skillName then
                bj.skillReadCounts[skillName] = tonumber(count) or 0
            end
        end
    end

    bj.isDebugSpawned = true
    bj.isDebugEdited = true
    bj.isPlayerCreated = true
    bj.isWritten = true
    bj.sanitizedVersion = BurdJournals.SANITIZE_VERSION or 1
    bj.debugRevision = tonumber(normalized.debugRevision) or tonumber(normalized.revision) or tonumber(bj.debugRevision) or 0
    if normalized.uuid then
        bj.uuid = normalized.uuid
    elseif requestedUUID and not bj.uuid then
        bj.uuid = requestedUUID
    end

    return bj
end

-- Apply debug-edited journal payload to server-side item ModData (authoritative MP persistence)
function BurdJournals.Server.handleDebugApplyJournalEdits(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    if not args or not args.journalData then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid debug journal edit payload"})
        return
    end
    if not args.journalId and not args.journalUUID and not args.journalKey and not (type(args.journalData) == "table" and args.journalData.uuid) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug journal edit payload missing journal identity"})
        return
    end

    local normalized = BurdJournals.normalizeJournalData(args.journalData) or args.journalData
    if type(normalized) ~= "table" then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid normalized debug journal data"})
        return
    end

    local journal, ownerPlayer, requestedUUID, requestedId, resolvePath, targetOwnerUsername, targetOwnerSteamId = resolveDebugApplyJournalTarget(player, args)
    if journal then
        local modData = journal.getModData and journal:getModData() or nil
        local data = modData and modData.BurdJournals or nil
        local ownerUsername = (type(data) == "table" and data.ownerUsername) or targetOwnerUsername or (ownerPlayer and ownerPlayer.getUsername and ownerPlayer:getUsername()) or nil
        local ownerSteamId = (type(data) == "table" and data.ownerSteamId) or targetOwnerSteamId or (ownerPlayer and BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(ownerPlayer)) or nil
        if not canPlayerAccessJournalSnapshot(player, ownerUsername, ownerSteamId) then
            sendJournalScopeDenied(player, "Journal edit")
            return
        end
    end

    if not journal then
        if not isServerJournalScopeAdmin(player) then
            if not requestedUUID or not canPlayerAccessJournalSnapshot(player, targetOwnerUsername, targetOwnerSteamId) then
                sendJournalScopeDenied(player, "Deferred journal edit")
                return
            end
        end

        local fallbackUUID = trimUUID(requestedUUID or args.journalKey or (type(normalized) == "table" and normalized.uuid))
        local fallbackKey = fallbackUUID or (requestedId and tostring(requestedId))
        if not fallbackKey then
            BurdJournals.Server.sendToClient(player, "debugError", {message = "Journal not found for debug apply (missing UUID/key)"})
            return
        end

        if targetOwnerUsername and not normalized.ownerUsername then
            normalized.ownerUsername = targetOwnerUsername
        end
        if targetOwnerSteamId and not normalized.ownerSteamId then
            normalized.ownerSteamId = targetOwnerSteamId
        end

        local deferredUUID = persistDebugJournalSnapshot(player, fallbackKey, normalized, nil, {
            savedBy = player:getUsername(),
            pendingApply = true,
            pendingReason = "missingLiveItem:" .. tostring(resolvePath or "unknown"),
            pendingRequestedBy = player:getUsername(),
            sourceTag = "debugApplyDeferred",
        })
        if not deferredUUID then
            BurdJournals.Server.sendToClient(player, "debugError", {message = "Failed to queue deferred debug journal edits"})
            return
        end

        if ModData.transmit then
            ModData.transmit("BurdJournals_DebugJournalCache")
            ModData.transmit("BurdJournals_JournalUUIDIndex")
        end

        BurdJournals.Server.sendToClient(player, "debugSuccess", {
            message = "Deferred debug edits saved for UUID " .. tostring(deferredUUID) .. ". Changes will apply when the journal loads."
        })
        return
    end

    local bj = applyNormalizedDebugJournalDataToItem(journal, normalized, requestedUUID)
    if not bj then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Failed applying normalized debug journal data"})
        return
    end

    -- Also persist an authoritative backup entry so debug edits survive future patch/update edge cases.
    local journalKey = args.journalKey or bj.uuid or tostring(args.journalId)
    local liveUUID = persistDebugJournalSnapshot(player, journalKey, bj, journal, {
        savedBy = player:getUsername(),
        pendingApply = false,
        sourceTag = "debugApplyJournalEdits:" .. tostring(resolvePath),
    })
    if liveUUID then
        bj.debugRevision = tonumber(bj.debugRevision) or 0
    end

    if journal.transmitModData then
        journal:transmitModData()
    end
    if ModData.transmit then
        ModData.transmit("BurdJournals_DebugJournalCache")
        ModData.transmit("BurdJournals_JournalUUIDIndex")
    end
    BurdJournals.Server.updateJournalUUIDIndex(journal, ownerPlayer or player, "debugApplyJournalEdits:" .. tostring(resolvePath))
    if BurdJournals.captureJournalDRState then
        BurdJournals.captureJournalDRState(journal, "debugApplyJournalEdits", player)
    end
end

-- ============================================================================
-- Debug Command Handlers (Server-side)
-- ============================================================================

-- Check if player is allowed to use debug commands
function BurdJournals.Server.isDebugAllowed(player)
    if not player then 
        BurdJournals.debugPrint("[BurdJournals] DEBUG: isDebugAllowed - no player")
        return false 
    end
    
    local username = player:getUsername() or "unknown"
    local isMultiplayerServer = isServer and isServer()
    local isAdmin = false
    if BurdJournals.Server.isDebugAdmin then
        isAdmin = BurdJournals.Server.isDebugAdmin(player)
    else
        isAdmin = player.isAccessLevel and player:isAccessLevel("admin") == true
    end
    
    -- Check sandbox option
    local sandboxEnabled = SandboxVars and SandboxVars.BurdJournals and SandboxVars.BurdJournals.AllowDebugCommands
    BurdJournals.debugPrint("[BurdJournals] DEBUG: isDebugAllowed for " .. username
        .. " - sandboxEnabled=" .. tostring(sandboxEnabled)
        .. ", isAdmin=" .. tostring(isAdmin)
        .. ", isMultiplayerServer=" .. tostring(isMultiplayerServer))

    -- Multiplayer safety: only admins may use debug commands.
    if isMultiplayerServer then
        if isAdmin then
            return true
        end
        BurdJournals.debugPrint("[BurdJournals] DEBUG: isDebugAllowed - DENIED (admin required in MP) for " .. username)
        return false
    end

    -- Single-player/local fallback behavior.
    if sandboxEnabled then return true end
    if isAdmin then return true end
    
    -- Check global debug mode
    local debugMode = getDebug and getDebug()
    BurdJournals.debugPrint("[BurdJournals] DEBUG: isDebugAllowed - debugMode=" .. tostring(debugMode))
    if debugMode then return true end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: isDebugAllowed - DENIED for " .. username)
    return false
end

-- Helper: Find player by username
function BurdJournals.Server.findPlayerByUsername(username)
    if not username then return nil end
    local onlinePlayers = getOnlinePlayers()
    if onlinePlayers then
        for i = 0, onlinePlayers:size() - 1 do
            local p = onlinePlayers:get(i)
            if p and p:getUsername() == username then
                return p
            end
        end
    end
    return nil
end

function BurdJournals.Server.isDebugAdmin(player)
    if not player then return false end
    if player.isAccessLevel and player:isAccessLevel("admin") then
        return true
    end
    local accessLevel = player.getAccessLevel and player:getAccessLevel() or nil
    return type(accessLevel) == "string" and string.lower(accessLevel) == "admin"
end

-- Resolve target player for debug character/baseline edits.
-- Non-admin callers may only target themselves.
function BurdJournals.Server.resolveDebugTargetPlayer(requestingPlayer, targetUsername)
    if not requestingPlayer then
        return nil, "Invalid requesting player"
    end

    local requesterUsername = requestingPlayer.getUsername and requestingPlayer:getUsername() or nil
    if not targetUsername or targetUsername == "" or targetUsername == requesterUsername then
        return requestingPlayer, nil
    end

    if not BurdJournals.Server.isDebugAdmin(requestingPlayer) then
        return nil, "Admin access required to modify another player's data."
    end

    local targetPlayer = BurdJournals.Server.findPlayerByUsername(targetUsername)
    if not targetPlayer then
        return nil, "Player not found: " .. tostring(targetUsername)
    end

    return targetPlayer, nil
end

-- Passive skill traits that need to be removed before setting skill level
-- These traits are auto-granted by PZ based on skill level, but having them
-- while trying to set a different level can cause conflicts
BurdJournals.Server.PASSIVE_SKILL_TRAITS = {
    Strength = {"puny", "weak", "feeble", "stout", "strong"},
    Fitness = {"unfit", "outofshape", "fit", "athletic"}
}

-- Remove all passive skill traits for a specific skill before setting its level
-- This prevents the trait system from bouncing the skill back
function BurdJournals.Server.removePassiveSkillTraits(targetPlayer, skillName)
    local traits = BurdJournals.Server.PASSIVE_SKILL_TRAITS[skillName]
    if not traits then return end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Removing passive skill traits for " .. skillName)
    
    for _, traitId in ipairs(traits) do
        local removed = false
        
        -- Try multiple methods to remove the trait
        -- Method 1: Use safeRemoveTrait if available
        if BurdJournals.safeRemoveTrait then
            removed = BurdJournals.safeRemoveTrait(targetPlayer, traitId) == true
            if removed then
                BurdJournals.debugPrint("[BurdJournals] DEBUG: Removed trait '" .. traitId .. "' via safeRemoveTrait")
            end
        end
        
        -- Method 2: Direct trait removal if safeRemoveTrait didn't work
        if not removed and targetPlayer and targetPlayer.getCharacterTraits then
            local charTraits = targetPlayer:getCharacterTraits()
            if charTraits and charTraits.size and charTraits.get then
                for i = charTraits:size() - 1, 0, -1 do
                    local traitObj = charTraits:get(i)
                    if traitObj then
                        local traitName = traitObj.getName and traitObj:getName() or tostring(traitObj)
                        if string.lower(traitName) == string.lower(traitId) then
                            if charTraits.remove then
                                charTraits:remove(traitObj)
                                removed = true
                                BurdJournals.debugPrint("[BurdJournals] DEBUG: Removed trait '" .. traitId .. "' via direct removal")
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

function BurdJournals.Server.buildTraitIdsToTry(traitId)
    local traitIdsToTry = {}
    local seen = {}

    local function addTraitId(id)
        if not id then return end
        id = tostring(id)
        if id == "" then return end
        local key = string.lower(id)
        if seen[key] then return end
        seen[key] = true
        table.insert(traitIdsToTry, id)
    end

    addTraitId(traitId)
    addTraitId(string.lower(traitId))

    if BurdJournals and BurdJournals.TRAIT_ALIASES then
        local aliases = BurdJournals.TRAIT_ALIASES[string.lower(traitId)]
        if aliases then
            for _, alias in ipairs(aliases) do
                addTraitId(alias)
                addTraitId(string.lower(alias))
            end
        end
    end

    return traitIdsToTry
end

-- Resolve trait ID/alias into a Build 42 CharacterTrait object.
-- Returns: traitObj, sourceLabel, traitIdsToTry, foundTraits
function BurdJournals.Server.resolveCharacterTrait(traitId, targetPlayer)
    if not traitId then
        return nil, nil, {}, {}
    end

    local traitIdsToTry = BurdJournals.Server.buildTraitIdsToTry(traitId)
    local foundTraits = {}
    local seenTraits = {}

    local function addFoundTrait(traitObj, sourceLabel)
        if not traitObj then return end
        if seenTraits[traitObj] then return end
        seenTraits[traitObj] = true
        table.insert(foundTraits, { trait = traitObj, source = sourceLabel or "unknown" })
    end

    local function tryResourceLookup(resourceLoc)
        if not (CharacterTrait and CharacterTrait.get and ResourceLocation and ResourceLocation.of) then
            return
        end
        local ok, result = BurdJournals.safePcall(function()
            return CharacterTrait.get(ResourceLocation.of(resourceLoc))
        end)
        if ok and result then
            addFoundTrait(result, "ResourceLocation:" .. tostring(resourceLoc))
        end
    end

    -- 1) ResourceLocation lookups
    if CharacterTrait and CharacterTrait.get and ResourceLocation and ResourceLocation.of then
        for _, tryId in ipairs(traitIdsToTry) do
            local original = "base:" .. tostring(tryId)
            local lower = "base:" .. string.lower(tostring(tryId))
            local spaced = "base:" .. string.lower(tostring(tryId):gsub("(%u)", " %1"):sub(2))

            tryResourceLookup(original)
            if lower ~= original then
                tryResourceLookup(lower)
            end
            if spaced ~= original and spaced ~= lower then
                tryResourceLookup(spaced)
            end
        end
    end

    -- 2) CharacterTrait enum style lookups
    if CharacterTrait then
        for _, tryId in ipairs(traitIdsToTry) do
            local underscored = tostring(tryId):gsub("(%u)", "_%1"):sub(2):upper()
            local ct = CharacterTrait[underscored]
            if ct then
                if type(ct) == "string" then
                    tryResourceLookup(ct)
                else
                    addFoundTrait(ct, "Enum:" .. underscored)
                end
            end
        end
    end

    -- 3) CharacterTraitDefinition scan
    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allTraits = CharacterTraitDefinition.getTraits()
        if allTraits then
            local wanted = {}
            for _, tryId in ipairs(traitIdsToTry) do
                wanted[string.lower(tostring(tryId))] = true
            end

            for i = 0, allTraits:size() - 1 do
                local def = allTraits:get(i)
                if def then
                    local defType = def.getType and def:getType() or nil
                    local defLabel = def.getLabel and def:getLabel() or nil
                    local defName = nil

                    if defType and defType.getName then
                        local okName, nameResult = BurdJournals.safePcall(function()
                            return defType:getName()
                        end)
                        if okName and nameResult then
                            defName = tostring(nameResult)
                        end
                    end
                    if not defName and defType then
                        defName = tostring(defType)
                    end

                    local nameMatches = defName and wanted[string.lower(defName)] == true
                    local labelMatches = defLabel and wanted[string.lower(tostring(defLabel))] == true
                    if defType and (nameMatches or labelMatches) then
                        addFoundTrait(defType, "Definition:" .. tostring(defName or defLabel or "?"))
                    end
                end
            end
        end
    end

    -- Prefer trait object the target currently has (important for removal)
    local resolvedTrait = nil
    local resolvedSource = nil
    if targetPlayer and targetPlayer.hasTrait then
        for _, entry in ipairs(foundTraits) do
            if targetPlayer:hasTrait(entry.trait) == true then
                resolvedTrait = entry.trait
                resolvedSource = entry.source
                break
            end
        end
    end

    if not resolvedTrait and #foundTraits > 0 then
        resolvedTrait = foundTraits[1].trait
        resolvedSource = foundTraits[1].source
    end

    return resolvedTrait, resolvedSource, traitIdsToTry, foundTraits
end


-- Handle debug: Set skill level
function BurdJournals.Server.handleDebugSetSkill(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local skillName = args.skillName
    local level = args.level or 10
    
    -- Support targeting other players (admin-only for cross-player edits)
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid skill: " .. tostring(skillName)})
        return
    end
    
    local xpObj = targetPlayer:getXp()
    local isPassive = (skillName == "Fitness" or skillName == "Strength")
    
    -- For passive skills, remove existing passive traits BEFORE setting level
    -- This prevents the trait system from bouncing the skill back
    if isPassive then
        BurdJournals.Server.removePassiveSkillTraits(targetPlayer, skillName)
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Setting " .. skillName .. " (passive=" .. tostring(isPassive) .. ") to level " .. level .. " for " .. targetPlayer:getUsername())
    
    if isPassive then
        -- For passive skills, use setPerkLevelDebug which directly sets level
        -- This bypasses XP scaling issues that affect Strength specifically
        targetPlayer:setPerkLevelDebug(perk, level)
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Set " .. skillName .. " to level " .. level .. " via setPerkLevelDebug")
    else
        -- For non-passive skills, use XP-based approach
        local currentXP = xpObj:getXP(perk)
        local targetXP = 0
        
        if level > 0 then
            targetXP = perk:getTotalXpForLevel(level)
        end
        
        local xpDiff = targetXP - currentXP
        BurdJournals.debugPrint("[BurdJournals] DEBUG: " .. skillName .. " currentXP=" .. currentXP .. " targetXP=" .. targetXP .. " diff=" .. xpDiff)
        
        if xpDiff ~= 0 then
            xpObj:AddXP(perk, xpDiff, false, false, false, true)  -- checkLevelUp = true!
        end
    end
    
    -- Sync after changes
    if SyncXp then
        SyncXp(targetPlayer)
    end
    
    local finalLevel = level
    BurdJournals.debugPrint("[BurdJournals] DEBUG: " .. skillName .. " final level = " .. finalLevel .. " for " .. targetPlayer:getUsername())
    
    -- Send specific response so client can refresh the appropriate tab
    BurdJournals.Server.sendToClient(player, "debugSkillSet", {
        skillName = skillName,
        level = finalLevel,
        targetUsername = targetPlayer:getUsername()
    })
end

-- Handle debug: Set all skills
function BurdJournals.Server.handleDebugSetAllSkills(player, args)
    BurdJournals.debugPrint("[BurdJournals] SERVER: handleDebugSetAllSkills called for " .. (player and player:getUsername() or "nil"))
    BurdJournals.debugPrint("[BurdJournals] SERVER: args.level = " .. tostring(args and args.level))
    
    if not BurdJournals.Server.isDebugAllowed(player) then
        print("[BurdJournals] SERVER: Debug not allowed, sending error")
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    -- Support targeting other players (admin-only for cross-player edits)
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    local level = args.level or 10
    local count = 0
    local xpObj = targetPlayer:getXp()
    
    BurdJournals.debugPrint("[BurdJournals] SERVER: Setting all skills to level " .. level .. " for " .. targetPlayer:getUsername())
    
    -- Remove ALL passive skill traits FIRST before setting any levels
    -- This prevents the trait system from bouncing Fitness/Strength back
    BurdJournals.Server.removePassiveSkillTraits(targetPlayer, "Strength")
    BurdJournals.Server.removePassiveSkillTraits(targetPlayer, "Fitness")
    
    -- For passive skills, use setPerkLevelDebug which directly sets level
    -- This bypasses XP scaling issues that affect Strength specifically
    local strengthPerk = Perks.Strength
    local fitnessPerk = Perks.Fitness
    
    if strengthPerk then
        targetPlayer:setPerkLevelDebug(strengthPerk, level)
        -- For level 0, also reset XP directly and remove traits again
        -- PZ auto-applies "Weak" trait which bounces Strength back up
        if level == 0 then
            xpObj:AddXP(strengthPerk, -xpObj:getXP(strengthPerk), false, false, false, false)
            BurdJournals.Server.removePassiveSkillTraits(targetPlayer, "Strength")
            targetPlayer:setPerkLevelDebug(strengthPerk, 0)
        end
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Set Strength to level " .. level .. " via setPerkLevelDebug")
        count = count + 1
    end
    
    if fitnessPerk then
        targetPlayer:setPerkLevelDebug(fitnessPerk, level)
        -- Same treatment for Fitness just in case
        if level == 0 then
            xpObj:AddXP(fitnessPerk, -xpObj:getXP(fitnessPerk), false, false, false, false)
            BurdJournals.Server.removePassiveSkillTraits(targetPlayer, "Fitness")
            targetPlayer:setPerkLevelDebug(fitnessPerk, 0)
        end
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Set Fitness to level " .. level .. " via setPerkLevelDebug")
        count = count + 1
    end
    
    -- For all other skills, use XP-based approach
    for i = 0, Perks.getMaxIndex() - 1 do
        local perk = Perks.fromIndex(i)
        if perk and perk:getParent() ~= Perks.None then
            local perkName = tostring(perk)
            -- Skip passive skills - already handled above
            if perkName ~= "Fitness" and perkName ~= "Strength" then
                local currentXP = xpObj:getXP(perk)
                local targetXP = 0
                
                if level > 0 then
                    targetXP = perk:getTotalXpForLevel(level)
                end
                
                local xpDiff = targetXP - currentXP
                if xpDiff ~= 0 then
                    xpObj:AddXP(perk, xpDiff, false, false, false, true)
                end
                
                count = count + 1
            end
        end
    end
    
    -- Sync after all changes
    if SyncXp then
        SyncXp(targetPlayer)
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Set all " .. count .. " skills to level " .. level .. " for " .. targetPlayer:getUsername())
    
    -- Send specific response so client can refresh UI after changes are applied
    BurdJournals.Server.sendToClient(player, "debugAllSkillsSet", {
        level = level,
        count = count,
        targetUsername = targetPlayer:getUsername()
    })
end

-- Handle debug: Add XP to skill
function BurdJournals.Server.handleDebugAddXP(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local skillName = args.skillName
    local xp = args.xp or 1000
    
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid skill: " .. tostring(skillName)})
        return
    end
    
    -- AddXP adds the specified amount directly for all skills
    local xpToAdd = xp
    
    -- Use sendAddXp for proper MP sync, fall back to direct AddXP
    -- NOTE: Don't call syncXp here - it disrupts batch command processing
    -- Client will request sync at end of batch via requestXpSync command
    if sendAddXp then
        sendAddXp(player, perk, xpToAdd, false)
    else
        player:getXp():AddXP(perk, xpToAdd, false, false, false, true)
    end
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Added " .. xp .. " XP to " .. skillName .. " for " .. player:getUsername())
    
    BurdJournals.Server.sendToClient(player, "debugSuccess", {message = "Added " .. xp .. " XP to " .. skillName})
end

-- Handle debug: Add XP to skill (supports targeting other players)
function BurdJournals.Server.handleDebugAddSkillXP(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local skillName = args.skillName
    local xpToAdd = args.xpToAdd or 100
    local targetUsername = args and args.targetUsername
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid skill: " .. tostring(skillName)})
        return
    end
    
    -- Add XP directly using AddXP (handles level-up automatically)
    -- AddXP adds the specified amount directly for all skills
    targetPlayer:getXp():AddXP(perk, xpToAdd, false, false, false, true)
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Added " .. xpToAdd .. " XP to " .. skillName .. " for " .. targetPlayer:getUsername())
    
    BurdJournals.Server.sendToClient(player, "debugSuccess", {message = "Added " .. xpToAdd .. " XP to " .. skillName})
end

-- Handle debug: Set skill to specific level (for player journal claims from debug-spawned journals)
-- Uses XP-based approach like production version (NOT setXPToLevel which is unreliable)
function BurdJournals.Server.handleDebugSetSkillToLevel(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local skillName = args.skillName
    local targetLevel = args.level or 0
    
    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid skill: " .. tostring(skillName)})
        return
    end
    
    local xpObj = player:getXp()
    local levelBefore = player:getPerkLevel(perk)
    local xpBefore = xpObj:getXP(perk)
    
    -- Calculate target XP needed for the target level
    -- getTotalXpForLevel(N) = XP threshold to BE AT level N
    -- This matches how the game engine and getSkillLevelFromXP determine level
    local targetXP = 0
    
    -- Standard skill XP thresholds - exact values to BE at each level (no buffer)
    -- Level N requires XP >= xpTable[N] (cumulative totals from PZ wiki)
    -- Per-level: 75, 150, 300, 750, 1500, 3000, 4500, 6000, 7500, 9000
    local xpTable = {
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
    
    -- Try PZ API first: getTotalXpForLevel(N) = XP threshold to BE AT level N
    -- Use exact threshold value (no buffer) for precise level control
    if perk.getTotalXpForLevel and targetLevel >= 0 then
        local apiXP = perk:getTotalXpForLevel(targetLevel)
        if apiXP and apiXP >= 0 then
            targetXP = apiXP
            BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   Using PZ API: getTotalXpForLevel(" .. targetLevel .. ") = " .. tostring(targetXP) .. " (exact threshold)")
        else
            -- API returned nil, use fallback
            targetXP = xpTable[targetLevel] or 0
            BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   PZ API returned nil, using fallback XP table: " .. tostring(targetXP))
        end
    else
        -- Use fallback XP table
        targetXP = xpTable[targetLevel] or 0
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   Using fallback XP table: " .. tostring(targetXP))
    end
    
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM] Skill: " .. tostring(skillName))
    BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   TARGET LEVEL: " .. tostring(targetLevel))
    BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   TARGET XP (for level " .. targetLevel .. "): " .. tostring(targetXP))
    BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   PLAYER BEFORE: Level " .. tostring(levelBefore) .. ", XP " .. tostring(xpBefore))
    BurdJournals.debugPrint("================================================================================")
    
    -- Only set if target level is higher than current
    if targetLevel > levelBefore and targetXP > xpBefore then
        -- Calculate XP difference needed
        local xpToAdd = targetXP - xpBefore
        
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM]   XP to add: " .. tostring(xpToAdd))
        
        -- Apply XP directly using AddXP (same as production version)
        -- AddXP signature: AddXP(perk, amount, addToKnownRecipes, useMultipliers, isPassive, checkLevelUp)
        -- IMPORTANT: checkLevelUp MUST be true to recalculate level from new XP!
        local success = false
        if xpObj and xpObj.AddXP then
            xpObj:AddXP(perk, xpToAdd, false, false, false, true)
            success = true
        end
        
        local levelAfter = player:getPerkLevel(perk)
        local xpAfter = xpObj:getXP(perk)
        
        BurdJournals.debugPrint("================================================================================")
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT] Skill: " .. tostring(skillName))
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT]   TARGET: Level " .. tostring(targetLevel) .. ", XP " .. tostring(targetXP))
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT]   XP ADDED: " .. tostring(xpToAdd))
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT]   PLAYER AFTER: Level " .. tostring(levelAfter) .. ", XP " .. tostring(xpAfter))
        if levelAfter < targetLevel then
            print("[BurdJournals DEBUG CLAIM RESULT]   WARNING: Player level (" .. levelAfter .. ") is LESS than target (" .. targetLevel .. ")!")
            BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT]   This may indicate a PZ XP scaling issue or passive skill behavior")
        elseif levelAfter == targetLevel then
            BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT]   SUCCESS: Player reached target level " .. targetLevel)
        else
            BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM RESULT]   NOTE: Player exceeded target level (" .. levelAfter .. " > " .. targetLevel .. ")")
        end
        BurdJournals.debugPrint("================================================================================")
        
        if success then
            BurdJournals.Server.sendToClient(player, "claimSuccess", {
                skillName = skillName,
                xpAdded = xpToAdd,
                message = "Set " .. skillName .. " to level " .. targetLevel,
                debug_targetLevel = targetLevel,
                debug_targetXP = targetXP,
                debug_xpAdded = xpToAdd,
                debug_levelAfter = levelAfter,
                debug_xpAfter = xpAfter,
            })
        else
            -- Fallback to addXp global function
            if addXp then
                BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM] AddXP failed, trying addXp() global")
                addXp(player, perk, xpToAdd)
                levelAfter = player:getPerkLevel(perk)
                xpAfter = xpObj:getXP(perk)
            end
            BurdJournals.Server.sendToClient(player, "claimSuccess", {
                skillName = skillName,
                xpAdded = xpToAdd,
                message = "Set " .. skillName .. " to level " .. targetLevel .. " (via fallback)",
                debug_targetLevel = targetLevel,
                debug_levelAfter = levelAfter,
                debug_xpAfter = xpAfter,
            })
        end
    else
        BurdJournals.debugPrint("[BurdJournals DEBUG CLAIM] Player already at or above target - levelBefore=" .. levelBefore .. ", xpBefore=" .. xpBefore .. ", targetLevel=" .. targetLevel .. ", targetXP=" .. targetXP)
        BurdJournals.Server.sendToClient(player, "skillMaxed", {
            skillName = skillName,
            alreadyAtLevel = true,
            message = "Already at level " .. levelBefore .. " for " .. skillName
        })
    end
end

-- Handle debug: Set skill to specific XP value (for player journal claims from debug-spawned journals)
-- This uses the actual recorded XP from the journal, not calculated from level
-- This is the correct way to restore Player Journal skills - SET to exact XP, not ADD
-- IMPORTANT: Uses XP-based approach with AddXP, NOT setXPToLevel which is unreliable
function BurdJournals.Server.handleDebugSetSkillXP(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    if not args or not args.skillName then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid debugSetSkillXP payload"})
        return
    end

    local skillName = args.skillName
    local targetXP = args.targetXP or 0
    local targetLevel = args.targetLevel or 0  -- Target level from journal (for logging only)

    local perk = BurdJournals.getPerkByName(skillName)
    if not perk then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid skill: " .. tostring(skillName)})
        return
    end

    local function normalizeToTable(value)
        if type(value) == "table" then
            return value
        end
        if BurdJournals.normalizeTable then
            local normalized = BurdJournals.normalizeTable(value)
            if type(normalized) == "table" then
                return normalized
            end
        end
        return nil
    end

    local function mergeMaxNumberMap(targetMap, sourceMap)
        local source = normalizeToTable(sourceMap)
        local target = normalizeToTable(targetMap)
        if type(target) ~= "table" then
            target = {}
        end
        if type(source) ~= "table" then
            return target, false
        end
        local changed = false
        for key, value in pairs(source) do
            if key ~= nil then
                local mapKey = tostring(key)
                local incoming = math.max(0, tonumber(value) or 0)
                local existing = math.max(0, tonumber(target[mapKey]) or 0)
                if incoming > existing then
                    target[mapKey] = incoming
                    changed = true
                end
            end
        end
        return target, changed
    end

    local resolvedJournal = nil
    local requestedJournalId = tonumber(args.journalId) or args.journalId
    if requestedJournalId then
        resolvedJournal = BurdJournals.findItemById(player, requestedJournalId)
    end
    if (not resolvedJournal) and args.journalUUID and BurdJournals.findJournalByUUID then
        resolvedJournal = BurdJournals.findJournalByUUID(player, args.journalUUID)
    end

    local responseJournalId = nil
    local responseJournalData = nil

    if resolvedJournal then
        local modData = resolvedJournal:getModData()
        modData.BurdJournals = modData.BurdJournals or {}
        local journalData = modData.BurdJournals

        if BurdJournals.restoreJournalDRStateIfMissing then
            BurdJournals.restoreJournalDRStateIfMissing(resolvedJournal, "debugSetSkillXP", player)
            journalData = modData.BurdJournals or journalData
        end

        local didMergeDR = false
        local sourceData = args.journalData
        if type(sourceData) == "table" and BurdJournals.normalizeJournalData then
            sourceData = BurdJournals.normalizeJournalData(sourceData) or sourceData
        end

        if type(sourceData) == "table" then
            local sourceReadCount = math.max(0, tonumber(sourceData.readCount) or 0)
            if sourceReadCount > math.max(0, tonumber(journalData.readCount) or 0) then
                journalData.readCount = sourceReadCount
                didMergeDR = true
            end

            local sourceSessionCount = math.max(0, tonumber(sourceData.readSessionCount) or 0)
            if sourceSessionCount > math.max(0, tonumber(journalData.readSessionCount) or 0) then
                journalData.readSessionCount = sourceSessionCount
                didMergeDR = true
            end

            local sourceSessionReads = math.max(0, tonumber(sourceData.currentSessionReadCount) or 0)
            if sourceSessionReads > math.max(0, tonumber(journalData.currentSessionReadCount) or 0) then
                journalData.currentSessionReadCount = sourceSessionReads
                didMergeDR = true
            end

            if sourceData.currentSessionId and sourceData.currentSessionId ~= journalData.currentSessionId then
                journalData.currentSessionId = sourceData.currentSessionId
                didMergeDR = true
            end

            local mergedSkillReadCounts, skillCountsChanged = mergeMaxNumberMap(journalData.skillReadCounts, sourceData.skillReadCounts)
            journalData.skillReadCounts = mergedSkillReadCounts
            if skillCountsChanged then
                didMergeDR = true
            end
            if sourceData.drLegacyMode3Migrated == true and journalData.drLegacyMode3Migrated ~= true then
                journalData.drLegacyMode3Migrated = true
                didMergeDR = true
            end
            local sourceMigrationSchemaVersion = tonumber(sourceData.migrationSchemaVersion) or 0
            local targetMigrationSchemaVersion = tonumber(journalData.migrationSchemaVersion) or 0
            if sourceMigrationSchemaVersion > targetMigrationSchemaVersion then
                journalData.migrationSchemaVersion = sourceMigrationSchemaVersion
                didMergeDR = true
            end

            local sourceClaims = normalizeToTable(sourceData.claims)
            if type(sourceClaims) == "table" then
                local targetClaims = normalizeToTable(journalData.claims)
                if type(targetClaims) ~= "table" then
                    targetClaims = {}
                end
                for characterId, sourceClaimData in pairs(sourceClaims) do
                    if characterId ~= nil then
                        local sourceClaimTable = normalizeToTable(sourceClaimData)
                        if type(sourceClaimTable) == "table" then
                            local targetClaimTable = normalizeToTable(targetClaims[characterId])
                            if type(targetClaimTable) ~= "table" then
                                targetClaimTable = {}
                            end
                            local mergedDrClaims, drClaimsChanged = mergeMaxNumberMap(targetClaimTable.drSkillReadCounts, sourceClaimTable.drSkillReadCounts)
                            targetClaimTable.drSkillReadCounts = mergedDrClaims
                            targetClaims[characterId] = targetClaimTable
                            if drClaimsChanged then
                                didMergeDR = true
                            end
                        end
                    end
                end
                journalData.claims = targetClaims
            end
        end

        -- Fallback for legacy clients that didn't send DR fields.
        if (not didMergeDR) and BurdJournals.consumeJournalClaimRead then
            BurdJournals.consumeJournalClaimRead(journalData, skillName, args.claimSessionId, player)
            didMergeDR = true
        end

        if didMergeDR and resolvedJournal.transmitModData then
            resolvedJournal:transmitModData()
        end
        if didMergeDR and BurdJournals.captureJournalDRState then
            BurdJournals.captureJournalDRState(resolvedJournal, "debugSetSkillXP", player)
        end

        responseJournalId = resolvedJournal:getID()
        responseJournalData = journalData
    end

    local xpObj = player:getXp()
    local levelBefore = player:getPerkLevel(perk)
    local xpBefore = xpObj:getXP(perk)

    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BurdJournals DEBUG SET XP] Skill: " .. tostring(skillName))
    BurdJournals.debugPrint("[BurdJournals DEBUG SET XP]   TARGET LEVEL: " .. tostring(targetLevel) .. ", TARGET XP: " .. tostring(targetXP))
    BurdJournals.debugPrint("[BurdJournals DEBUG SET XP]   PLAYER BEFORE: Level " .. tostring(levelBefore) .. ", XP " .. tostring(xpBefore))
    BurdJournals.debugPrint("================================================================================")

    -- Use XP-based comparison (more accurate than level comparison)
    -- Only apply XP if target XP is higher than current XP
    if targetXP > xpBefore then
        -- Calculate XP difference needed
        local xpToAdd = targetXP - xpBefore

        -- AddXP adds the specified amount directly for all skills
        BurdJournals.debugPrint("[BurdJournals DEBUG SET XP]   XP to add: " .. tostring(xpToAdd))

        -- Use sendAddXp if available (MP-safe, handles client sync automatically)
        -- Fall back to direct AddXP + syncXp if not
        local success = false
        if sendAddXp then
            BurdJournals.debugPrint("[BurdJournals DEBUG SET XP]   Using sendAddXp (MP-safe)")
            sendAddXp(player, perk, xpToAdd, false)  -- false = don't use multipliers
            success = true
        end
        
        if not success then
            -- Fallback: Apply XP directly using AddXP
            -- AddXP signature: AddXP(perk, amount, addToKnownRecipes, useMultipliers, isPassive, checkLevelUp)
            BurdJournals.debugPrint("[BurdJournals DEBUG SET XP]   Using direct AddXP (no immediate sync)")
            if xpObj and xpObj.AddXP then
                xpObj:AddXP(perk, xpToAdd, false, false, false, true)
                success = true
            end
            -- NOTE: Don't call syncXp here - it disrupts batch command processing
            -- Client will request sync at end of batch via requestXpSync command
        end
        
        local levelAfter = player:getPerkLevel(perk)
        local xpAfter = xpObj:getXP(perk)
        
        BurdJournals.debugPrint("================================================================================")
        BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT] Skill: " .. tostring(skillName))
        BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT]   TARGET: Level " .. tostring(targetLevel) .. ", XP " .. tostring(targetXP))
        BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT]   XP ADDED: " .. tostring(xpToAdd))
        BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT]   PLAYER AFTER: Level " .. tostring(levelAfter) .. ", XP " .. tostring(xpAfter))
        if levelAfter < targetLevel then
            print("[BurdJournals DEBUG SET XP RESULT]   WARNING: Player level (" .. levelAfter .. ") is LESS than target (" .. targetLevel .. ")!")
            BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT]   This may indicate a PZ XP scaling issue or passive skill behavior")
        elseif levelAfter == targetLevel then
            BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT]   SUCCESS: Player reached target level " .. targetLevel)
        else
            BurdJournals.debugPrint("[BurdJournals DEBUG SET XP RESULT]   NOTE: Player exceeded target level (" .. levelAfter .. " > " .. targetLevel .. ")")
        end
        BurdJournals.debugPrint("================================================================================")
        
        if success then
            BurdJournals.Server.sendToClient(player, "claimSuccess", {
                skillName = skillName,
                xpAdded = xpToAdd,
                message = "Set " .. skillName .. " to level " .. levelAfter,
                journalId = responseJournalId,
                journalData = responseJournalData,
                debug_targetLevel = targetLevel,
                debug_targetXP = targetXP,
                debug_xpAdded = xpToAdd,
                debug_levelAfter = levelAfter,
                debug_xpAfter = xpAfter,
            })
        else
            -- Fallback to addXp global function
            if addXp then
                BurdJournals.debugPrint("[BurdJournals DEBUG SET XP] AddXP failed, trying addXp() global")
                addXp(player, perk, xpToAdd)
                levelAfter = player:getPerkLevel(perk)
                xpAfter = xpObj:getXP(perk)
            end
            BurdJournals.Server.sendToClient(player, "claimSuccess", {
                skillName = skillName,
                xpAdded = xpToAdd,
                message = "Set " .. skillName .. " to level " .. levelAfter .. " (via fallback)",
                journalId = responseJournalId,
                journalData = responseJournalData,
                debug_targetLevel = targetLevel,
                debug_levelAfter = levelAfter,
                debug_xpAfter = xpAfter,
            })
        end
    else
        BurdJournals.debugPrint("[BurdJournals DEBUG SET XP] Player already at or above target XP - xpBefore=" .. xpBefore .. ", targetXP=" .. targetXP)
        BurdJournals.Server.sendToClient(player, "skillMaxed", {
            skillName = skillName,
            journalId = responseJournalId,
            journalData = responseJournalData,
            alreadyAtLevel = true,
            message = "Already at level " .. levelBefore .. " for " .. skillName .. " (target was level " .. targetLevel .. ")"
        })
    end
end

-- Handle debug: Add trait
function BurdJournals.Server.handleDebugAddTrait(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local traitId = args.traitId
    if not traitId then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "No trait specified"})
        return
    end

    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] DEBUG handleDebugAddTrait: traitId=" .. tostring(traitId) .. " for " .. targetPlayer:getUsername())

    local characterTrait, resolvedSource, traitIdsToTry = BurdJournals.Server.resolveCharacterTrait(traitId, nil)
    if not characterTrait then
        print("[BurdJournals] DEBUG ERROR: Could not find CharacterTrait for: " .. tostring(traitId))
        if traitIdsToTry and #traitIdsToTry > 0 then
            BurdJournals.debugPrint("[BurdJournals] DEBUG: Tried IDs: " .. table.concat(traitIdsToTry, ", "))
        end
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid trait: " .. traitId})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] DEBUG: Resolved trait via " .. tostring(resolvedSource))

    local charTraits = targetPlayer.getCharacterTraits and targetPlayer:getCharacterTraits() or nil
    if not charTraits or not charTraits.add then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Trait system unavailable"})
        return
    end

    local hadBefore = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false

    -- Keep debug behavior: allow add attempts even if already present.
    charTraits:add(characterTrait)

    if targetPlayer.modifyTraitXPBoost then
        targetPlayer:modifyTraitXPBoost(characterTrait, false)
    end
    if SyncXp then
        SyncXp(targetPlayer)
    end

    local hasAfter = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false
    if hasAfter then
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Trait add success=" .. tostring(not hadBefore) .. " (hadBefore=" .. tostring(hadBefore) .. ")")
        BurdJournals.Server.sendToClient(player, "debugTraitAdded", {
            traitId = traitId,
            targetUsername = targetPlayer:getUsername(),
            alreadyHad = hadBefore,
        })
    else
        print("[BurdJournals] DEBUG ERROR: Failed to add trait " .. traitId .. " - hasTrait returned false after add")
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Failed to add trait: " .. traitId})
    end
end

-- Handle debug: Remove trait (supports removeAll flag for duplicate traits)
function BurdJournals.Server.handleDebugRemoveTrait(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local traitId = args.traitId
    local removeAll = args.removeAll or false
    if not traitId then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "No trait specified"})
        return
    end

    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] DEBUG handleDebugRemoveTrait: traitId=" .. tostring(traitId) .. " removeAll=" .. tostring(removeAll) .. " for " .. targetPlayer:getUsername())

    local removeCount = 0
    local success = false

    local characterTrait, resolvedSource, traitIdsToTry, foundTraits = BurdJournals.Server.resolveCharacterTrait(traitId, targetPlayer)
    if not characterTrait then
        print("[BurdJournals] DEBUG ERROR: Could not resolve CharacterTrait object for: " .. tostring(traitId))
        if traitIdsToTry and #traitIdsToTry > 0 then
            BurdJournals.debugPrint("[BurdJournals] DEBUG: Tried IDs: " .. table.concat(traitIdsToTry, ", "))
        end
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Invalid/unknown trait: " .. traitId})
        return
    end

    BurdJournals.debugPrint("[BurdJournals] DEBUG: Resolved trait via " .. tostring(resolvedSource))

    local hadTraitBefore = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false
    if not hadTraitBefore then
        BurdJournals.Server.sendToClient(player, "debugTraitRemoved", {
            traitId = traitId,
            removeCount = 0,
            stillHasTrait = false,
            success = true,
            targetUsername = targetPlayer:getUsername(),
            message = "Player doesn't have trait: " .. traitId,
        })
        return
    end

    local charTraits = targetPlayer.getCharacterTraits and targetPlayer:getCharacterTraits() or nil
    if not charTraits then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Trait system unavailable"})
        return
    end

    local maxAttempts = removeAll and 100 or 1
    for attempt = 1, maxAttempts do
        local removed = false

        if charTraits.remove then
            local result = charTraits:remove(characterTrait) == true
            if result then
                removed = true
                removeCount = removeCount + 1
                success = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: SUCCESS via remove(CharacterTrait) attempt #" .. attempt)
            end
        end

        if not removed and charTraits.set then
            charTraits:set(characterTrait, false)
            local stillHas = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false
            if not stillHas then
                removed = true
                removeCount = removeCount + 1
                success = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: SUCCESS via set(CharacterTrait, false) attempt #" .. attempt)
            end
        end

        if not removed and foundTraits and #foundTraits > 0 then
            for _, entry in ipairs(foundTraits) do
                local aliasTrait = entry.trait
                if aliasTrait then
                    if charTraits.remove then
                        charTraits:remove(aliasTrait)
                    end
                    if charTraits.set then
                        charTraits:set(aliasTrait, false)
                    end
                end
            end

            local stillHas = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false
            if not stillHas then
                removed = true
                removeCount = removeCount + 1
                success = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: SUCCESS via alias object removal attempt #" .. attempt)
            end
        end

        if not removed then
            BurdJournals.debugPrint("[BurdJournals] DEBUG: No removal method worked on attempt #" .. attempt)
            break
        end

        if removeAll then
            local stillHas = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false
            if not stillHas then
                break
            end
        else
            break
        end
    end

    if success and targetPlayer.modifyTraitXPBoost then
        targetPlayer:modifyTraitXPBoost(characterTrait, true)
    end

    if SyncXp then
        SyncXp(targetPlayer)
    end

    local stillHasTrait = targetPlayer.hasTrait and (targetPlayer:hasTrait(characterTrait) == true) or false
    local finalSuccess = not stillHasTrait

    BurdJournals.Server.sendToClient(player, "debugTraitRemoved", {
        traitId = traitId,
        removeCount = removeCount,
        stillHasTrait = stillHasTrait,
        success = finalSuccess,
        targetUsername = targetPlayer:getUsername(),
    })
end

-- Handle debug: Remove ALL traits from player
function BurdJournals.Server.handleDebugRemoveAllTraits(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    -- Support targeting other players (admin-only for cross-player edits)
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG handleDebugRemoveAllTraits for " .. targetPlayer:getUsername())
    
    local removeCount = 0
    
    -- Get CharacterTraits collection for removal (Build 42 API)
    local charTraits = nil
    if targetPlayer.getCharacterTraits then
        charTraits = targetPlayer:getCharacterTraits()
    end
    
    -- Collect all traits the player has using CharacterTraitDefinition iteration (Build 42)
    local traitsToRemove = {}
    
    if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
        local allDefs = CharacterTraitDefinition.getTraits()
        if allDefs then
            BurdJournals.debugPrint("[BurdJournals] DEBUG: Scanning " .. allDefs:size() .. " trait definitions...")
            for i = 0, allDefs:size() - 1 do
                local def = allDefs:get(i)
                if def then
                    -- Build 42 uses getType(), not getTrait()
                    local traitObj = def.getType and def:getType() or nil
                    if traitObj then
                        local hasIt = targetPlayer.hasTrait and targetPlayer:hasTrait(traitObj) or false
                        if hasIt then
                            -- Skip passive skill traits
                            local isPassiveSkillTrait = false
                            if BurdJournals.isPassiveSkillTrait then
                                local traitName = traitObj.getName and traitObj:getName() or ""
                                isPassiveSkillTrait = BurdJournals.isPassiveSkillTrait(traitName)
                            end
                            
                            if not isPassiveSkillTrait then
                                local traitId = "unknown"
                                traitId = (traitObj.getName and traitObj:getName()) or tostring(traitObj)
                                table.insert(traitsToRemove, {trait = traitObj, id = traitId})
                                BurdJournals.debugPrint("[BurdJournals] DEBUG: Player has trait: " .. traitId)
                            end
                        end
                    end
                end
            end
        end
    else
        BurdJournals.debugPrint("[BurdJournals] DEBUG: CharacterTraitDefinition not available")
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Found " .. #traitsToRemove .. " traits to remove")
    
    -- Remove each trait individually (Build 42 approach)
    for _, traitData in ipairs(traitsToRemove) do
        local traitObj = traitData.trait
        local traitId = traitData.id
        local removed = false
        
        -- Try remove method
        if charTraits and charTraits.remove then
            charTraits:remove(traitObj)
            BurdJournals.debugPrint("[BurdJournals] DEBUG: charTraits:remove(" .. traitId .. ") called")
        end
        
        -- Try set(trait, false) method
        if charTraits and charTraits.set then
            charTraits:set(traitObj, false)
            -- Verify removal
            local stillHas = targetPlayer.hasTrait and targetPlayer:hasTrait(traitObj) or false
            if not stillHas then
                removed = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: Successfully removed " .. traitId)
            end
        end
        
        if removed then
            removeCount = removeCount + 1
        else
            BurdJournals.debugPrint("[BurdJournals] DEBUG: Failed to remove " .. traitId)
        end
    end
    
    -- Fallback: try old API if Build 42 approach found no traits
    if #traitsToRemove == 0 then
        local oldTraits = nil
        if targetPlayer.getTraits then
            oldTraits = targetPlayer:getTraits()
        end
        if oldTraits and oldTraits.size then
            local size = oldTraits:size()
            if size > 0 then
                BurdJournals.debugPrint("[BurdJournals] DEBUG: Falling back to old API, clearing " .. size .. " traits")
                if oldTraits.clear then
                    oldTraits:clear()
                    removeCount = size
                end
            end
        end
    end
    
    -- Sync changes
    if SyncXp then
        SyncXp(targetPlayer)
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Removed " .. removeCount .. " traits from " .. targetPlayer:getUsername())
    
    -- Send specific response so client can refresh UI after changes are applied
    BurdJournals.Server.sendToClient(player, "debugAllTraitsRemoved", {
        count = removeCount,
        targetUsername = targetPlayer:getUsername()
    })
end

-- Handle debug: Clear baseline
function BurdJournals.Server.handleDebugClearBaseline(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    -- Support targeting other players (admin-only for cross-player edits)
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    local category = args.category or "all"  -- all, skills, traits, recipes
    local modData = targetPlayer:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    
    if category == "all" then
        modData.BurdJournals.skillBaseline = {}
        modData.BurdJournals.mediaSkillBaseline = {}
        modData.BurdJournals.traitBaseline = {}
        modData.BurdJournals.recipeBaseline = {}
    elseif category == "skills" then
        modData.BurdJournals.skillBaseline = {}
        modData.BurdJournals.mediaSkillBaseline = {}
    elseif category == "traits" then
        modData.BurdJournals.traitBaseline = {}
    elseif category == "recipes" then
        modData.BurdJournals.recipeBaseline = {}
    end
    
    -- Mark as debug-modified for persistence
    modData.BurdJournals.debugModified = true
    
    -- Transmit changes
    if targetPlayer.transmitModData then
        targetPlayer:transmitModData()
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Cleared " .. category .. " baseline for " .. targetPlayer:getUsername())
    BurdJournals.Server.sendToClient(player, "debugSuccess", {message = "Cleared " .. category .. " baseline for " .. targetPlayer:getUsername()})
end

-- Handle debug: Recalculate baseline
function BurdJournals.Server.handleDebugRecalcBaseline(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end

    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, args and args.targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end

    local characterId = BurdJournals.getPlayerCharacterId(targetPlayer)
    if not characterId then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Could not get character ID"})
        return
    end

    -- Rebuild baseline from authoritative server state
    local baselineData = BurdJournals.Server.buildBaselineForPlayer(targetPlayer)
    baselineData.steamId = BurdJournals.getPlayerSteamId(targetPlayer)
    local descriptor = targetPlayer.getDescriptor and targetPlayer:getDescriptor() or nil
    baselineData.characterName = BurdJournals.getPlayerCharacterName and BurdJournals.getPlayerCharacterName(targetPlayer)
        or (descriptor and (descriptor:getForename() .. " " .. descriptor:getSurname()) or nil)
    baselineData.debugModified = false

    BurdJournals.Server.storeCachedBaseline(characterId, baselineData, true)

    -- Update player's modData baseline tables
    local modData = targetPlayer:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    modData.BurdJournals.skillBaseline = baselineData.skillBaseline or {}
    modData.BurdJournals.mediaSkillBaseline = baselineData.mediaSkillBaseline or {}
    modData.BurdJournals.traitBaseline = baselineData.traitBaseline or {}
    modData.BurdJournals.recipeBaseline = baselineData.recipeBaseline or {}
    modData.BurdJournals.debugModified = false
    modData.BurdJournals.baselineCaptured = true
    modData.BurdJournals_Baseline = nil

    if targetPlayer.transmitModData then
        targetPlayer:transmitModData()
    end

    local msg = "Baseline recalculated for " .. targetPlayer:getUsername()
    BurdJournals.Server.sendToClient(player, "recalculateBaseline", {message = msg, targetUsername = targetPlayer:getUsername()})
end

-- Handle debug: Update skill baseline (syncs to server cache for MP persistence)
function BurdJournals.Server.handleDebugUpdateSkillBaseline(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local skillName = args.skillName
    local baselineXP = args.baselineXP
    local targetUsername = args.targetUsername
    
    if not skillName then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Missing skill name"})
        return
    end
    
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    -- Update player's modData
    local modData = targetPlayer:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    modData.BurdJournals.skillBaseline = modData.BurdJournals.skillBaseline or {}
    modData.BurdJournals.skillBaseline[skillName] = baselineXP
    
    -- Update server cache for persistence across logout/rejoin
    local characterId = BurdJournals.getPlayerCharacterId(targetPlayer)
    if characterId then
        local cache = BurdJournals.Server.getBaselineCache()
        if not cache.players[characterId] then
            cache.players[characterId] = {
                skillBaseline = {},
                mediaSkillBaseline = {},
                traitBaseline = {},
                recipeBaseline = {},
                capturedAt = getGameTime():getWorldAgeHours(),
                steamId = BurdJournals.getPlayerSteamId(targetPlayer),
                characterName = targetPlayer:getDescriptor():getForename() .. " " .. targetPlayer:getDescriptor():getSurname()
            }
        end
        cache.players[characterId].skillBaseline[skillName] = baselineXP
        cache.players[characterId].debugModified = true  -- Mark as debug-modified
        
        -- Also update the player's local modData (this is the key backup that survives mod updates!)
        local playerModData = targetPlayer:getModData()
        if not playerModData.BurdJournals then
            playerModData.BurdJournals = {}
        end
        playerModData.BurdJournals.debugModified = true
        playerModData.BurdJournals.baselineCaptured = true  -- Ensure this flag is set
        playerModData.BurdJournals.skillBaseline = playerModData.BurdJournals.skillBaseline or {}
        playerModData.BurdJournals.skillBaseline[skillName] = baselineXP
        
        -- Persist server cache to global ModData
        if ModData.transmit then
            ModData.transmit("BurdJournals_PlayerBaselines")
        end
        
        -- CRITICAL: Also transmit player's own ModData to ensure it's saved with their character
        -- This is the fallback that allows recovery after mod updates!
        if targetPlayer.transmitModData then
            targetPlayer:transmitModData()
        end
        
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Updated skill baseline for " .. targetPlayer:getUsername() .. ": " .. skillName .. " = " .. tostring(baselineXP))
        
        -- Send specific response so client can refresh the Baseline tab
        BurdJournals.Server.sendToClient(player, "debugBaselineSkillSet", {
            skillName = skillName,
            baselineXP = baselineXP,
            targetUsername = targetPlayer:getUsername()
        })
    else
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Could not get character ID"})
    end
end

-- Handle debug: Update trait baseline (syncs to server cache for MP persistence)
function BurdJournals.Server.handleDebugUpdateTraitBaseline(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local traitId = args.traitId
    local isBaseline = args.isBaseline
    local targetUsername = args.targetUsername
    
    if not traitId then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Missing trait ID"})
        return
    end
    
    local targetPlayer, targetErr = BurdJournals.Server.resolveDebugTargetPlayer(player, targetUsername)
    if not targetPlayer then
        BurdJournals.Server.sendToClient(player, "debugError", {message = targetErr or "Target player not found"})
        return
    end
    
    -- Update player's modData using the shared function (handles aliases)
    if BurdJournals.setTraitBaseline then
        BurdJournals.setTraitBaseline(targetPlayer, traitId, isBaseline)
    end
    
    -- Update server cache for persistence across logout/rejoin
    local characterId = BurdJournals.getPlayerCharacterId(targetPlayer)
    if characterId then
        local cache = BurdJournals.Server.getBaselineCache()
        if not cache.players[characterId] then
            cache.players[characterId] = {
                skillBaseline = {},
                mediaSkillBaseline = {},
                traitBaseline = {},
                recipeBaseline = {},
                capturedAt = getGameTime():getWorldAgeHours(),
                steamId = BurdJournals.getPlayerSteamId(targetPlayer),
                characterName = targetPlayer:getDescriptor():getForename() .. " " .. targetPlayer:getDescriptor():getSurname()
            }
        end
        
        -- Get all aliases and store them
        local aliases = BurdJournals.getTraitAliases and BurdJournals.getTraitAliases(traitId) or {traitId, string.lower(traitId)}
        for _, alias in ipairs(aliases) do
            if isBaseline then
                cache.players[characterId].traitBaseline[alias] = true
            else
                cache.players[characterId].traitBaseline[alias] = nil
            end
        end
        cache.players[characterId].debugModified = true  -- Mark as debug-modified
        
        -- Also update the player's local modData (this is the key backup that survives mod updates!)
        local playerModData = targetPlayer:getModData()
        if not playerModData.BurdJournals then
            playerModData.BurdJournals = {}
        end
        playerModData.BurdJournals.debugModified = true
        playerModData.BurdJournals.baselineCaptured = true  -- Ensure this flag is set
        -- Also sync trait baseline to player ModData
        playerModData.BurdJournals.traitBaseline = playerModData.BurdJournals.traitBaseline or {}
        for _, alias in ipairs(aliases) do
            if isBaseline then
                playerModData.BurdJournals.traitBaseline[alias] = true
            else
                playerModData.BurdJournals.traitBaseline[alias] = nil
            end
        end
        
        -- Persist server cache to global ModData
        if ModData.transmit then
            ModData.transmit("BurdJournals_PlayerBaselines")
        end
        
        -- CRITICAL: Also transmit player's own ModData to ensure it's saved with their character
        -- This is the fallback that allows recovery after mod updates!
        if targetPlayer.transmitModData then
            targetPlayer:transmitModData()
        end
        
        local status = isBaseline and "added to" or "removed from"
        BurdJournals.debugPrint("[BurdJournals] DEBUG: Trait " .. traitId .. " " .. status .. " baseline for " .. targetPlayer:getUsername())
        
        -- Send specific response so client can refresh the Baseline tab
        BurdJournals.Server.sendToClient(player, "debugBaselineTraitSet", {
            traitId = traitId,
            isBaseline = isBaseline,
            targetUsername = targetPlayer:getUsername()
        })
    else
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Could not get character ID"})
    end
end

-- Handle debug: Spawn journal (server-side for MP persistence)
function BurdJournals.Server.handleDebugSpawnJournal(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local inventory = player:getInventory()
    if not inventory then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "No inventory"})
        return
    end
    
    -- Determine item type
    local itemType
    local journalType = args.journalType or "filled"
    
    if journalType == "blank" then
        itemType = "BurdJournals.BlankSurvivalJournal"
    elseif journalType == "worn" then
        itemType = "BurdJournals.FilledSurvivalJournal_Worn"
    elseif journalType == "bloody" then
        itemType = "BurdJournals.FilledSurvivalJournal_Bloody"
    else
        itemType = "BurdJournals.FilledSurvivalJournal"
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Server spawning journal type=" .. itemType)
    
    -- Create the item server-side (authoritative)
    local item = inventory:AddItem(itemType)
    if not item then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Failed to create journal"})
        return
    end
    
    -- Initialize ModData for non-blank journals
    if journalType ~= "blank" then
        local modData = item:getModData()
        modData.BurdJournals = modData.BurdJournals or {}
        local data = modData.BurdJournals
        
        -- Core identification
        data.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID()) or tostring((getTimestampMs and getTimestampMs()) or os.time())
        local worldAge = getGameTime() and getGameTime():getWorldAgeHours() or 0
        data.timestamp = worldAge
        local requestedAge = tonumber(args.ageHours or 0) or 0
        if requestedAge > 0 then
            data.timestamp = math.max(0, worldAge - requestedAge)
        end
        data.lastModified = worldAge
        
        -- CRITICAL: These fields are required for persistence across server restarts/mod updates
        data.isDebugSpawned = true  -- Flag to bypass origin restrictions
        data.isWritten = true       -- Mark as properly initialized (prevents re-initialization)
        data.journalVersion = BurdJournals.VERSION or "dev"  -- Version tracking for migration
        data.sanitizedVersion = BurdJournals.SANITIZE_VERSION or 1  -- Prevent re-sanitization
        
        -- Owner information - required for validation and permissions
        data.ownerCharacterName = args.owner or "Debug Spawn"
        data.author = args.owner or "Debug Spawn"
        data.ownerSteamId = BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(player) or "debug_" .. player:getUsername()
        data.ownerUsername = player:getUsername()
        
        -- Journal type flags - important for claim logic
        -- If marked as player journal OR has full player ownership info, treat as player-created
        if args.isPlayerJournal or (args.ownerSteamId and args.ownerUsername) then
            data.isPlayerCreated = true
        else
            data.isPlayerCreated = false
        end
        
        -- Override owner info if explicitly provided
        if args.ownerSteamId then
            data.ownerSteamId = args.ownerSteamId
        end
        if args.ownerUsername then
            data.ownerUsername = args.ownerUsername
        end
        if args.ownerCharacterName then
            data.ownerCharacterName = args.ownerCharacterName
            data.author = args.ownerCharacterName
        end
        
        -- Initialize data containers
        data.skills = {}
        data.traits = {}
        data.recipes = {}
        data.stats = {}
        data.claims = {}  -- Per-character claims tracking
        
        -- Mark origin for worn/bloody
        if journalType == "worn" then
            data.isWorn = true
            data.wasFromWorn = true
        elseif journalType == "bloody" then
            data.isBloody = true
            data.wasFromBloody = true
            data.hasBloodyOrigin = true
        end
        
        -- Handle profession for worn/bloody journals
        if (journalType == "worn" or journalType == "bloody") and not args.noProfession then
            if args.profession and args.professionName then
                -- Specific or custom profession selected
                data.profession = args.profession
                data.professionName = args.professionName
                if args.professionFlavorKey then
                    data.flavorKey = args.professionFlavorKey
                end
                local profType = args.isCustomProfession and "Custom" or "Set"
                BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: " .. profType .. " profession: " .. args.professionName)
            elseif args.randomProfession ~= false then
                -- Random profession (default for worn/bloody)
                local profId, profName, flavorKey = BurdJournals.getRandomProfession()
                if profId then
                    data.profession = profId
                    data.professionName = profName
                    data.flavorKey = flavorKey
                    BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: Random profession: " .. profName)
                end
            end
        end
        
        -- Handle custom flavor text (overrides profession flavor)
        if args.flavorText and args.flavorText ~= "" then
            data.flavorText = args.flavorText
            data.flavorKey = nil  -- Clear the key so custom text is used
            BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: Custom flavor text: " .. args.flavorText)
        end
        local skillJournalContext = data
        if journalType == "filled" then
            skillJournalContext = {isPlayerCreated = true}
        end
        
        -- Add specified skills
        if args.skills then
            BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: Processing " .. tostring(BurdJournals.tableCount and BurdJournals.tableCount(args.skills) or "?") .. " skills")
            for skillName, skillData in pairs(args.skills) do
                local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(skillJournalContext, skillName)
                if enabledForJournal then
                    local xp = skillData.xp or 0
                    local level = skillData.level or 0
                    BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: Skill " .. tostring(skillName) .. " received xp=" .. tostring(xp) .. ", level=" .. tostring(level))
                    data.skills[skillName] = {
                        xp = xp,
                        level = level
                    }
                else
                    BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: Skipping disabled passive skill for journal type: " .. tostring(skillName))
                end
            end
        else
            BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: No skills in args")
        end
        
        -- Add specified traits
        if args.traits then
            for traitName, _ in pairs(args.traits) do
                data.traits[traitName] = true
            end
        end
        
        -- Add specified recipes
        if args.recipes then
            for recipeName, _ in pairs(args.recipes) do
                data.recipes[recipeName] = true
            end
        end

        -- Add specified stats
        if args.stats then
            for statName, value in pairs(args.stats) do
                local numValue = tonumber(value)
                if numValue then
                    data.stats[statName] = { value = numValue }
                end
            end
        end

        local requestedCondition = tonumber(args.conditionOverride or 0) or 0
        if requestedCondition > 0 then
            local cond = math.max(1, math.min(10, math.floor(requestedCondition)))
            if item.setCondition then
                item:setCondition(cond)
            end
            data.condition = cond
        elseif item.getCondition then
            data.condition = item:getCondition()
        end
        
        BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn: Final journal data initialized with persistence fields")
        BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn:   isWritten=" .. tostring(data.isWritten))
        BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn:   sanitizedVersion=" .. tostring(data.sanitizedVersion))
        BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn:   isPlayerCreated=" .. tostring(data.isPlayerCreated))
        BurdJournals.debugPrint("[BurdJournals] DEBUG Server spawn:   ownerSteamId=" .. tostring(data.ownerSteamId))
        
        -- Update journal name and icon
        if BurdJournals.updateJournalName then
            BurdJournals.updateJournalName(item)
        end
        if BurdJournals.updateJournalIcon then
            BurdJournals.updateJournalIcon(item)
        end
        
        -- Transmit changes to ensure persistence
        if item.transmitModData then
            item:transmitModData()
        end
    end
    
    -- Sync inventory to client (required for MP)
    if inventory.sync then
        inventory:sync()
    end
    
    -- Also try setDrawDirty to force UI update
    if inventory.setDrawDirty then
        inventory:setDrawDirty(true)
    end
    
    -- Send inventory packet to client (various methods for compatibility)
    if isServer() and player then
        -- Try various inventory sync methods - not all exist in all PZ versions
        if player.syncInventory then
            player:syncInventory()
        end
        -- sendAddItemToContainer is more reliable
        if sendAddItemToContainer then
            sendAddItemToContainer(inventory, item)
        end
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Server spawned journal ID=" .. tostring(item:getID()) .. " type=" .. journalType)
    BurdJournals.Server.sendToClient(player, "debugSuccess", {message = "Spawned " .. journalType .. " journal (check inventory)"})
end

-- Handle debug: Force dissolve any journal
function BurdJournals.Server.handleDebugDissolveJournal(player, args)
    if not BurdJournals.Server.isDebugAllowed(player) then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Debug commands not allowed"})
        return
    end
    
    local journalId = args.journalId
    if not journalId then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "No journal ID specified"})
        return
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Force dissolve requested for ID=" .. tostring(journalId))
    
    -- Search for the journal
    local journal = BurdJournals.findItemById(player, journalId)
    if not journal then
        -- Try direct inventory search
        local inv = player:getInventory()
        if inv then
            local items = inv:getItems()
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                if item and item:getID() == journalId then
                    journal = item
                    break
                end
            end
        end
    end
    
    if not journal then
        BurdJournals.Server.sendToClient(player, "debugError", {message = "Journal not found"})
        return
    end
    
    -- Force remove the journal (no restrictions)
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Force dissolving journal " .. tostring(journalId))
    BurdJournals.Server.dissolveJournal(player, journal)
    
    BurdJournals.Server.sendToClient(player, "debugSuccess", {message = "Journal dissolved"})
    BurdJournals.Server.sendToClient(player, "journalDissolved", {
        message = "Debug dissolved",
        journalId = journalId
    })
end

BurdJournals.debugPrint("[BurdJournals] Registering OnClientCommand handler...")
BurdJournals.debugPrint("[BurdJournals] Events table exists: " .. tostring(Events ~= nil))
BurdJournals.debugPrint("[BurdJournals] Events.OnClientCommand exists: " .. tostring(Events and Events.OnClientCommand ~= nil))
BurdJournals.debugPrint("[BurdJournals] BurdJournals.Server.onClientCommand exists: " .. tostring(BurdJournals.Server.onClientCommand ~= nil))

if Events and Events.OnClientCommand and Events.OnClientCommand.Add then
    Events.OnClientCommand.Add(BurdJournals.Server.onClientCommand)
    BurdJournals.debugPrint("[BurdJournals] OnClientCommand handler registered SUCCESSFULLY")
else
    print("[BurdJournals] ERROR registering OnClientCommand: Events.OnClientCommand.Add not available")
end

Events.OnServerStarted.Add(BurdJournals.Server.init)
Events.EveryHours.Add(BurdJournals.Server.checkBaselineCleanup)

-- Register for ModData initialization to ensure baseline cache is properly loaded
if Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(BurdJournals.Server.onInitGlobalModData)
    BurdJournals.debugPrint("[BurdJournals] OnInitGlobalModData handler registered")
else
    print("[BurdJournals] WARNING: OnInitGlobalModData event not available")
end

BurdJournals.debugPrint("[BurdJournals] Server module fully loaded!")
