
require "BurdJournals_Shared"

BurdJournals = BurdJournals or {}
BurdJournals.Client = BurdJournals.Client or {}

-- Version 3: Fixed recipe baseline capture when SeeNotLearntRecipe sandbox option is enabled
BurdJournals.Client.BASELINE_VERSION = 4  -- v4: Clear recipe baseline for existing characters (fixes recipes not recordable bug)

BurdJournals.Client._activeTickHandlers = {}
BurdJournals.Client._tickHandlerIdCounter = 0

-- Shared client->server wrapper used by UI code paths (MainPanel, Debug UI, etc.).
function BurdJournals.Client.sendToServer(command, args, playerObj)
    if type(command) ~= "string" or command == "" then
        return false
    end
    if not sendClientCommand then
        return false
    end

    local player = playerObj or getPlayer() or getSpecificPlayer(0)
    if not player then
        return false
    end

    sendClientCommand(player, "BurdJournals", command, args or {})
    return true
end

local function shouldApplyTraitsLocally()
    local networkClient = isClient and isClient() and isServer and not isServer()
    return not networkClient
end

BurdJournals.Client._journalSyncDebounce = BurdJournals.Client._journalSyncDebounce or {}

local function mergeMapInto(target, source)
    if type(target) ~= "table" then
        target = {}
    end
    if type(source) ~= "table" then
        return target
    end
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

function BurdJournals.Client.requestJournalSync(journalId, reasonTag)
    if not journalId then
        return false
    end
    local player = getPlayer()
    if not player or not sendClientCommand then
        return false
    end
    local now = (getTimestampMs and getTimestampMs()) or ((os.time() or 0) * 1000)
    local key = tostring(journalId)
    local debounceMs = math.max(250, tonumber(BurdJournals.RUNTIME_TRANSMIT_DEBOUNCE_MS) or 500)
    local lastAt = tonumber(BurdJournals.Client._journalSyncDebounce[key]) or 0
    if (now - lastAt) < debounceMs then
        return false
    end
    BurdJournals.Client._journalSyncDebounce[key] = now
    sendClientCommand(player, "BurdJournals", "syncJournalData", {
        journalId = journalId,
        reason = reasonTag
    })
    return true
end

function BurdJournals.Client.applyRuntimeDeltaToJournalData(journalData, runtimeDelta)
    if type(journalData) ~= "table" or type(runtimeDelta) ~= "table" then
        return false
    end
    local changed = false

    if type(runtimeDelta.claims) == "table" then
        journalData.claims = type(journalData.claims) == "table" and journalData.claims or {}
        for characterId, claimData in pairs(runtimeDelta.claims) do
            if type(characterId) == "string" and type(claimData) == "table" then
                journalData.claims[characterId] = journalData.claims[characterId] or {}
                local targetClaims = journalData.claims[characterId]
                if type(claimData.skills) == "table" then
                    targetClaims.skills = mergeMapInto(type(targetClaims.skills) == "table" and targetClaims.skills or {}, claimData.skills)
                end
                if type(claimData.traits) == "table" then
                    targetClaims.traits = mergeMapInto(type(targetClaims.traits) == "table" and targetClaims.traits or {}, claimData.traits)
                end
                if type(claimData.recipes) == "table" then
                    targetClaims.recipes = mergeMapInto(type(targetClaims.recipes) == "table" and targetClaims.recipes or {}, claimData.recipes)
                end
                if type(claimData.stats) == "table" then
                    targetClaims.stats = mergeMapInto(type(targetClaims.stats) == "table" and targetClaims.stats or {}, claimData.stats)
                end
                if type(claimData.forgetSlots) == "table" then
                    targetClaims.forgetSlots = mergeMapInto(type(targetClaims.forgetSlots) == "table" and targetClaims.forgetSlots or {}, claimData.forgetSlots)
                end
                if type(claimData.drSkillReadCounts) == "table" then
                    targetClaims.drSkillReadCounts = mergeMapInto(type(targetClaims.drSkillReadCounts) == "table" and targetClaims.drSkillReadCounts or {}, claimData.drSkillReadCounts)
                end
                changed = true
            end
        end
    end

    if runtimeDelta.readCount ~= nil then
        journalData.readCount = math.max(0, tonumber(runtimeDelta.readCount) or 0)
        changed = true
    end
    if runtimeDelta.readSessionCount ~= nil then
        journalData.readSessionCount = math.max(0, tonumber(runtimeDelta.readSessionCount) or 0)
        changed = true
    end
    if runtimeDelta.currentSessionId ~= nil then
        journalData.currentSessionId = runtimeDelta.currentSessionId
        changed = true
    end
    if runtimeDelta.currentSessionReadCount ~= nil then
        journalData.currentSessionReadCount = math.max(0, tonumber(runtimeDelta.currentSessionReadCount) or 0)
        changed = true
    end
    if type(runtimeDelta.skillReadCounts) == "table" then
        journalData.skillReadCounts = mergeMapInto(type(journalData.skillReadCounts) == "table" and journalData.skillReadCounts or {}, runtimeDelta.skillReadCounts)
        changed = true
    end
    if runtimeDelta.drLegacyMode3Migrated ~= nil then
        journalData.drLegacyMode3Migrated = runtimeDelta.drLegacyMode3Migrated == true
        changed = true
    end

    return changed
end

local function journalIdsMatch(left, right)
    if left == nil or right == nil then
        return false
    end
    return tostring(left) == tostring(right)
end

local function applyServerJournalUpdate(player, journalId, args, sourceTag)
    if not journalId or type(args) ~= "table" then
        return false
    end

    local hasFullData = type(args.journalData) == "table"
    local hasRuntimeDelta = type(args.runtimeDelta) == "table"
    local applied = false

    local function applyToJournal(journal)
        if not journal then
            return false
        end
        local modData = journal:getModData()
        if hasFullData then
            modData.BurdJournals = args.journalData
            return true
        end
        if hasRuntimeDelta then
            if type(modData.BurdJournals) ~= "table" then
                modData.BurdJournals = {}
            end
            return BurdJournals.Client.applyRuntimeDeltaToJournalData(modData.BurdJournals, args.runtimeDelta)
        end
        return false
    end

    local inventoryJournal = BurdJournals.findItemById(player, journalId)
    if applyToJournal(inventoryJournal) then
        applied = true
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        if panel.journal and journalIdsMatch(panel.journal:getID(), journalId) then
            if applyToJournal(panel.journal) then
                applied = true
            end
        end
    end

    if (args.needsSync == true and not hasFullData) or (hasRuntimeDelta and not applied) then
        BurdJournals.Client.requestJournalSync(journalId, sourceTag or "runtimeUpdate")
    end

    return applied
end

local function markTraitClaimedLocally(player, journalId, traitId)
    if not player or not journalId or not traitId then
        return
    end

    local function applyClaimToJournal(journal)
        if not journal then
            return false
        end
        local data = BurdJournals.getJournalData and BurdJournals.getJournalData(journal) or nil
        if data then
            BurdJournals.markTraitClaimedByCharacter(data, player, traitId)
            if journal.transmitModData then
                journal:transmitModData()
            end
            return true
        end
        BurdJournals.claimTrait(journal, traitId)
        return true
    end

    local inventoryJournal = BurdJournals.findItemById(player, journalId)
    applyClaimToJournal(inventoryJournal)

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        if panel.journal and journalIdsMatch(panel.journal:getID(), journalId) then
            applyClaimToJournal(panel.journal)
        end
    end
end

local function markTraitSessionClaim(panel, traitId)
    if not panel or not traitId then
        return
    end
    local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(traitId) or traitId
    local traitSessionKey = string.lower(tostring(normalizedTraitId or traitId))
    if not panel.sessionClaimedTraits then panel.sessionClaimedTraits = {} end
    panel.sessionClaimedTraits[traitId] = true
    panel.sessionClaimedTraits[traitSessionKey] = true
    if panel.pendingClaims and panel.pendingClaims.traits then
        panel.pendingClaims.traits[traitId] = nil
        panel.pendingClaims.traits[traitSessionKey] = nil
    end
end

function BurdJournals.Client.registerTickHandler(handlerFunc, debugName)
    BurdJournals.Client._tickHandlerIdCounter = BurdJournals.Client._tickHandlerIdCounter + 1
    local handlerId = BurdJournals.Client._tickHandlerIdCounter

    local wrappedHandler = {
        id = handlerId,
        name = debugName or ("handler_" .. handlerId),
        func = handlerFunc,
        active = true,
        registered = getTimestampMs and getTimestampMs() or 0
    }

    BurdJournals.Client._activeTickHandlers[handlerId] = wrappedHandler
    Events.OnTick.Add(handlerFunc)

    return handlerId
end

function BurdJournals.Client.unregisterTickHandler(handlerId)
    local handler = BurdJournals.Client._activeTickHandlers[handlerId]
    if handler and handler.active then
        handler.active = false
        BurdJournals.safeRemoveEvent(Events.OnTick, handler.func)
        BurdJournals.Client._activeTickHandlers[handlerId] = nil
        return true
    end
    return false
end

function BurdJournals.Client.cleanupAllTickHandlers()
    local count = 0
    for handlerId, handler in pairs(BurdJournals.Client._activeTickHandlers) do
        if handler.active then
            handler.active = false
            BurdJournals.safeRemoveEvent(Events.OnTick, handler.func)
            count = count + 1
        end
    end
    BurdJournals.Client._activeTickHandlers = {}
    BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
    if count > 0 then
        BurdJournals.debugPrint("[BurdJournals] Cleaned up " .. count .. " orphaned tick handlers")
    end
end

BurdJournals.Client._lastKnownCharacterId = nil

BurdJournals.Client._currentLanguage = nil

function BurdJournals.Client.checkLanguageChange()
    local newLanguage = nil

    if Translator and Translator.getLanguage then
        newLanguage = Translator.getLanguage()
    elseif getCore and getCore().getLanguage then
        newLanguage = getCore():getLanguage()
    end

    if newLanguage and BurdJournals.Client._currentLanguage and newLanguage ~= BurdJournals.Client._currentLanguage then

        if BurdJournals.clearLocalizedItemsCache then
            BurdJournals.clearLocalizedItemsCache()
        end
    end

    BurdJournals.Client._currentLanguage = newLanguage
end

BurdJournals.Client._pendingNewCharacterBaseline = false
BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
BurdJournals.Client._baselineMissRetryCount = 0
BurdJournals.Client._baselineMissRetryHandlerId = nil
BurdJournals.Client._runtimeBaselineCache = BurdJournals.Client._runtimeBaselineCache or {}

local function copyBaselineMap(source)
    local out = {}
    if type(source) ~= "table" then
        return out
    end
    for key, value in pairs(source) do
        if key ~= nil and value ~= nil then
            out[key] = value
        end
    end
    return out
end

local function buildRuntimeBaselineRecord(characterId, payload)
    if not characterId then
        return nil
    end
    local key = tostring(characterId)
    if key == "" then
        return nil
    end
    local source = type(payload) == "table" and payload or {}
    return {
        characterId = key,
        skillBaseline = copyBaselineMap(source.skillBaseline),
        mediaSkillBaseline = copyBaselineMap(source.mediaSkillBaseline),
        traitBaseline = copyBaselineMap(source.traitBaseline),
        recipeBaseline = copyBaselineMap(source.recipeBaseline),
        debugModified = source.debugModified == true,
        cachedAtMs = getTimestampMs and getTimestampMs() or ((os.time() or 0) * 1000),
    }
end

function BurdJournals.Client.storeRuntimeBaseline(characterId, payload)
    local record = buildRuntimeBaselineRecord(characterId, payload)
    if not record then
        return false
    end
    BurdJournals.Client._runtimeBaselineCache[record.characterId] = record
    return true
end

function BurdJournals.Client.getCachedBaselineForPlayer(player)
    if not player or not BurdJournals.getPlayerCharacterId then
        return nil
    end
    local characterId = BurdJournals.getPlayerCharacterId(player)
    if not characterId then
        return nil
    end
    return BurdJournals.Client._runtimeBaselineCache[tostring(characterId)]
end

local function isLocalBaselineTarget(player, args)
    if not player then
        return false
    end
    local targetUsername = args and args.targetUsername or nil
    if targetUsername == nil or tostring(targetUsername) == "" then
        return true
    end
    local localUsername = player.getUsername and player:getUsername() or nil
    return localUsername ~= nil and tostring(localUsername) == tostring(targetUsername)
end

local function hasBaselinePayloadInCommandArgs(args)
    return type(args) == "table"
        and (
            type(args.skillBaseline) == "table"
            or type(args.mediaSkillBaseline) == "table"
            or type(args.traitBaseline) == "table"
            or type(args.recipeBaseline) == "table"
        )
end

function BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer(player, args)
    if not isLocalBaselineTarget(player, args) then
        return false
    end
    if not hasBaselinePayloadInCommandArgs(args) then
        return false
    end

    local modData = player and player.getModData and player:getModData() or nil
    if not modData then
        return false
    end
    modData.BurdJournals = modData.BurdJournals or {}
    modData.BurdJournals.skillBaseline = copyBaselineMap(args.skillBaseline)
    modData.BurdJournals.mediaSkillBaseline = copyBaselineMap(args.mediaSkillBaseline)
    modData.BurdJournals.traitBaseline = copyBaselineMap(args.traitBaseline)
    modData.BurdJournals.recipeBaseline = copyBaselineMap(args.recipeBaseline)
    modData.BurdJournals.debugModified = args.debugModified == true
    modData.BurdJournals.baselineCaptured = true
    modData.BurdJournals.baselineVersion = BurdJournals.Client.BASELINE_VERSION
    modData.BurdJournals.fromServerCache = true

    local runtimeCharacterId = args.characterId
        or (BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player))
        or nil
    if runtimeCharacterId and BurdJournals.Client.storeRuntimeBaseline then
        BurdJournals.Client.storeRuntimeBaseline(runtimeCharacterId, {
            characterId = runtimeCharacterId,
            skillBaseline = modData.BurdJournals.skillBaseline,
            mediaSkillBaseline = modData.BurdJournals.mediaSkillBaseline,
            traitBaseline = modData.BurdJournals.traitBaseline,
            recipeBaseline = modData.BurdJournals.recipeBaseline,
            debugModified = modData.BurdJournals.debugModified == true,
        })
    end

    return true
end

local function hasBaselineCapturedLocal(player)
    if not player then
        return false
    end
    if BurdJournals.hasBaselineCaptured then
        return BurdJournals.hasBaselineCaptured(player)
    end
    local modData = player.getModData and player:getModData() or nil
    return modData and modData.BurdJournals and modData.BurdJournals.baselineCaptured == true
end

local function hasCharacterTraitsLoadedForBaseline(player)
    if not player then
        return false
    end

    local charTraits = player.getCharacterTraits and player:getCharacterTraits() or nil
    if charTraits and charTraits.getKnownTraits then
        local knownTraits = charTraits:getKnownTraits()
        if knownTraits and knownTraits.size and knownTraits:size() > 0 then
            return true
        end
    end

    local runtimeTraits = player.getTraits and player:getTraits() or nil
    if runtimeTraits then
        if runtimeTraits.size and runtimeTraits:size() > 0 then
            return true
        end
        if type(runtimeTraits) == "table" then
            for _, value in pairs(runtimeTraits) do
                if value ~= nil then
                    return true
                end
            end
        end
    end

    return false
end

local function appendListEntriesToSet(listObj, outSet, normalizeFn)
    if not listObj or not outSet then
        return
    end

    local function addEntry(value)
        if value == nil then
            return
        end
        local entry = tostring(value)
        if normalizeFn then
            entry = normalizeFn(entry)
        end
        if entry and entry ~= "" then
            outSet[entry] = true
        end
    end

    if listObj.size and listObj.get then
        for i = 0, listObj:size() - 1 do
            addEntry(listObj:get(i))
        end
        return
    end

    if type(listObj) == "table" then
        for key, value in pairs(listObj) do
            if type(key) == "string" and value == true then
                addEntry(key)
            else
                addEntry(value)
            end
        end
    end
end

local function normalizeTraitIdForBaselineSnapshot(traitId)
    if not traitId then
        return nil
    end
    local normalized = tostring(traitId)
    normalized = string.gsub(normalized, "^base:", "")
    if normalized == "" then
        return nil
    end
    return normalized
end

local function getBaselineStateSnapshotToken(player)
    local traitSet = {}
    local recipeSet = {}

    if player then
        local charTraits = player.getCharacterTraits and player:getCharacterTraits() or nil
        local knownTraits = charTraits and charTraits.getKnownTraits and charTraits:getKnownTraits() or nil
        appendListEntriesToSet(knownTraits, traitSet, normalizeTraitIdForBaselineSnapshot)

        local runtimeTraits = player.getTraits and player:getTraits() or nil
        appendListEntriesToSet(runtimeTraits, traitSet, normalizeTraitIdForBaselineSnapshot)

        local knownRecipes = player.getKnownRecipes and player:getKnownRecipes() or nil
        appendListEntriesToSet(knownRecipes, recipeSet, nil)
    end

    local traitIds = {}
    for traitId, _ in pairs(traitSet) do
        table.insert(traitIds, traitId)
    end
    table.sort(traitIds)

    local recipeIds = {}
    for recipeId, _ in pairs(recipeSet) do
        table.insert(recipeIds, recipeId)
    end
    table.sort(recipeIds)

    local token = table.concat(traitIds, "\31") .. "\30" .. table.concat(recipeIds, "\31")
    return #traitIds, #recipeIds, token
end

local function countListEntries(listObj)
    if not listObj then
        return 0
    end
    if listObj.size then
        return tonumber(listObj:size()) or 0
    end
    if type(listObj) == "table" then
        local count = 0
        for _, value in pairs(listObj) do
            if value ~= nil then
                count = count + 1
            end
        end
        return count
    end
    return 0
end

local function sortedKeysFromSet(setObj)
    local out = {}
    if not setObj then
        return out
    end
    for key, value in pairs(setObj) do
        if value == true then
            table.insert(out, tostring(key))
        end
    end
    table.sort(out)
    return out
end

local function previewListEntries(listObj, limit)
    local maxItems = tonumber(limit) or 12
    if maxItems < 1 then
        maxItems = 1
    end
    local out = {}
    for i = 1, math.min(#listObj, maxItems) do
        out[#out + 1] = tostring(listObj[i])
    end
    return out
end

function BurdJournals.Client.dumpBaselineSpawnState(player, reasonTag)
    local targetPlayer = player or getPlayer()
    if not targetPlayer then
        BurdJournals.debugPrint("[BurdJournals] Spawn readiness dump aborted: no target player")
        return false
    end

    local charTraits = targetPlayer.getCharacterTraits and targetPlayer:getCharacterTraits() or nil
    local knownTraits = charTraits and charTraits.getKnownTraits and charTraits:getKnownTraits() or nil
    local runtimeTraits = targetPlayer.getTraits and targetPlayer:getTraits() or nil
    local knownRecipes = targetPlayer.getKnownRecipes and targetPlayer:getKnownRecipes() or nil

    local traitSet = {}
    appendListEntriesToSet(knownTraits, traitSet, normalizeTraitIdForBaselineSnapshot)
    appendListEntriesToSet(runtimeTraits, traitSet, normalizeTraitIdForBaselineSnapshot)
    local recipeSet = {}
    appendListEntriesToSet(knownRecipes, recipeSet, nil)

    local mergedTraitIds = sortedKeysFromSet(traitSet)
    local mergedRecipeIds = sortedKeysFromSet(recipeSet)
    local mergedTraitPreview = previewListEntries(mergedTraitIds, 12)
    local mergedRecipePreview = previewListEntries(mergedRecipeIds, 12)

    local collectedTraitCount = 0
    if BurdJournals.collectPlayerTraits then
        local collectedTraits = BurdJournals.collectPlayerTraits(targetPlayer, false) or {}
        collectedTraitCount = BurdJournals.countTable and BurdJournals.countTable(collectedTraits) or countListEntries(collectedTraits)
    end

    local collectedBaselineRecipeCount = 0
    if BurdJournals.collectPlayerMagazineRecipes then
        local collectedRecipes = BurdJournals.collectPlayerMagazineRecipes(targetPlayer, false, true) or {}
        collectedBaselineRecipeCount = BurdJournals.countTable and BurdJournals.countTable(collectedRecipes) or countListEntries(collectedRecipes)
    end

    local modData = targetPlayer.getModData and targetPlayer:getModData() or nil
    local bj = modData and modData.BurdJournals or nil
    local baselineSkillCount = bj and BurdJournals.countTable and BurdJournals.countTable(bj.skillBaseline or {}) or 0
    local baselineTraitCount = bj and BurdJournals.countTable and BurdJournals.countTable(bj.traitBaseline or {}) or 0
    local baselineRecipeCount = bj and BurdJournals.countTable and BurdJournals.countTable(bj.recipeBaseline or {}) or 0

    local username = targetPlayer.getUsername and targetPlayer:getUsername() or "Unknown"
    local hoursAlive = targetPlayer.getHoursSurvived and targetPlayer:getHoursSurvived() or 0
    local characterId = BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(targetPlayer) or "unknown"
    local steamId = BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(targetPlayer) or "unknown"

    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("=== BSJ Spawn Readiness Dump (" .. tostring(reasonTag or "manual") .. ") ===")
    BurdJournals.debugPrint("Player=" .. tostring(username)
        .. " | characterId=" .. tostring(characterId)
        .. " | steamId=" .. tostring(steamId)
        .. " | hoursAlive=" .. tostring(hoursAlive))
    BurdJournals.debugPrint("State flags: pendingNewCharacterBaseline=" .. tostring(BurdJournals.Client._pendingNewCharacterBaseline)
        .. ", awaitingServerBaseline=" .. tostring(BurdJournals.Client._awaitingServerBaseline))
    BurdJournals.debugPrint("Local baseline: captured=" .. tostring(bj and bj.baselineCaptured == true)
        .. ", version=" .. tostring(bj and bj.baselineVersion or "nil")
        .. ", skills=" .. tostring(baselineSkillCount)
        .. ", traits=" .. tostring(baselineTraitCount)
        .. ", recipes=" .. tostring(baselineRecipeCount)
        .. ", debugModified=" .. tostring(bj and bj.debugModified == true))
    BurdJournals.debugPrint("Trait sources: knownTraitsCount=" .. tostring(countListEntries(knownTraits))
        .. ", runtimeTraitsCount=" .. tostring(countListEntries(runtimeTraits))
        .. ", mergedUniqueTraits=" .. tostring(#mergedTraitIds)
        .. ", collectorCount=" .. tostring(collectedTraitCount))
    BurdJournals.debugPrint("Recipe sources: knownRecipesCount=" .. tostring(countListEntries(knownRecipes))
        .. ", mergedUniqueKnownRecipes=" .. tostring(#mergedRecipeIds)
        .. ", baselineCollectorCount=" .. tostring(collectedBaselineRecipeCount))

    if #mergedTraitPreview > 0 then
        BurdJournals.debugPrint("Trait preview: " .. table.concat(mergedTraitPreview, ", "))
    else
        BurdJournals.debugPrint("Trait preview: (none)")
    end

    if #mergedRecipePreview > 0 then
        BurdJournals.debugPrint("Recipe preview: " .. table.concat(mergedRecipePreview, ", "))
    else
        BurdJournals.debugPrint("Recipe preview: (none)")
    end

    BurdJournals.debugPrint("=== End BSJ Spawn Readiness Dump ===")
    BurdJournals.debugPrint("")
    return true
end

function BurdJournals.Client.tryBootstrapPendingNewCharacterBaseline(player, reasonTag, allowWithoutTraits)
    if not player then
        return false
    end
    if not BurdJournals.Client.captureBaseline then
        return false
    end
    if BurdJournals.Client._pendingNewCharacterBaseline ~= true then
        return false
    end

    if hasBaselineCapturedLocal(player) then
        BurdJournals.Client._pendingNewCharacterBaseline = false
        return false
    end

    local hoursAlive = player.getHoursSurvived and player:getHoursSurvived() or 0
    local snapshotWindowHours = BurdJournals.getBaselineSnapshotMaxHours and BurdJournals.getBaselineSnapshotMaxHours() or 1
    if hoursAlive > snapshotWindowHours then
        return false
    end

    local hasTraits = hasCharacterTraitsLoadedForBaseline(player)
    if not hasTraits and not allowWithoutTraits then
        return false
    end

    if hasTraits then
        BurdJournals.debugPrint("[BurdJournals] baseline bootstrap: immediate capture (" .. tostring(reasonTag or "manual") .. ")")
    else
        BurdJournals.debugPrint("[BurdJournals] baseline bootstrap: forcing immediate capture without full traits (" .. tostring(reasonTag or "manual") .. ")")
    end

    BurdJournals.Client.captureBaseline(player, true)

    if hasBaselineCapturedLocal(player) then
        local handlerId = BurdJournals.Client._newCharacterBaselineCaptureHandlerId
        if handlerId then
            BurdJournals.Client.unregisterTickHandler(handlerId)
            BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
        end
        BurdJournals.Client._pendingNewCharacterBaseline = false
        return true
    end

    return false
end

function BurdJournals.Client.queueNewCharacterBaselineCapture(player, playerIndex, reasonTag)
    if not player then
        return false
    end
    if not BurdJournals.Client.captureBaseline then
        return false
    end

    if hasBaselineCapturedLocal(player) then
        BurdJournals.Client._pendingNewCharacterBaseline = false
        return false
    end

    local existingHandlerId = BurdJournals.Client._newCharacterBaselineCaptureHandlerId
    if existingHandlerId and BurdJournals.Client._activeTickHandlers[existingHandlerId] then
        return false
    end
    BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
    BurdJournals.Client._pendingNewCharacterBaseline = true

    local resolvedIndex = nil
    if type(playerIndex) == "number" then
        resolvedIndex = playerIndex
    elseif player.getPlayerNum then
        resolvedIndex = player:getPlayerNum()
    end

    -- Give character creation systems time to apply profession/trait starting
    -- levels before freezing baseline for the run.
    local minWaitTicks = 45
    local maxWaitTicks = 300
    local stabilityRequiredTicks = 20
    local ticksWaited = 0
    local stableStateTicks = 0
    local lastStateToken = nil
    local firstTraitsSeenTick = nil
    local handlerId = nil

    local captureAfterDelay
    captureAfterDelay = function()
        ticksWaited = ticksWaited + 1

        local currentPlayer = nil
        if resolvedIndex ~= nil then
            currentPlayer = getSpecificPlayer(resolvedIndex)
        end
        if not currentPlayer then
            currentPlayer = getPlayer()
        end
        if not currentPlayer then
            if ticksWaited >= maxWaitTicks then
                BurdJournals.debugPrint("[BurdJournals] baseline bootstrap: player unavailable, aborting capture")
                BurdJournals.Client.unregisterTickHandler(handlerId)
                BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
                BurdJournals.Client._pendingNewCharacterBaseline = false
            end
            return
        end

        if ticksWaited < minWaitTicks then
            return
        end

        -- Wait for server baseline lookup so existing characters do not get
        -- misclassified as new before cached baseline data arrives.
        if BurdJournals.Client._awaitingServerBaseline then
            if ticksWaited < maxWaitTicks then
                return
            end
            BurdJournals.debugPrint("[BurdJournals] WARNING: Server baseline response timeout, proceeding with local baseline capture")
        end

        local hoursAliveNow = currentPlayer.getHoursSurvived and currentPlayer:getHoursSurvived() or 0
        local snapshotWindowHours = BurdJournals.getBaselineSnapshotMaxHours and BurdJournals.getBaselineSnapshotMaxHours() or 1
        if hoursAliveNow > snapshotWindowHours and not BurdJournals.Client._awaitingServerBaseline then
            BurdJournals.debugPrint("[BurdJournals] baseline bootstrap: player has " .. tostring(hoursAliveNow)
                .. " hours alive (> " .. tostring(snapshotWindowHours) .. "h snapshot window), treating as existing character and skipping new baseline capture")
            BurdJournals.Client.unregisterTickHandler(handlerId)
            BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
            BurdJournals.Client._pendingNewCharacterBaseline = false
            if not hasBaselineCapturedLocal(currentPlayer) and BurdJournals.Client.requestServerBaseline then
                BurdJournals.debugPrint("[BurdJournals] baseline bootstrap: no local baseline after existing-character detection, retrying server baseline request")
                BurdJournals.Client.requestServerBaseline()
            end
            return
        end

        local traitCount, recipeCount, stateToken = getBaselineStateSnapshotToken(currentPlayer)
        local hasTraits = traitCount > 0

        if hasTraits then
            if firstTraitsSeenTick == nil then
                firstTraitsSeenTick = ticksWaited
                lastStateToken = stateToken
                stableStateTicks = 0
                BurdJournals.debugPrint("[BurdJournals] baseline bootstrap: trait state detected (traits="
                    .. tostring(traitCount) .. ", recipes=" .. tostring(recipeCount)
                    .. "), waiting for stabilization before capture")
            elseif lastStateToken == stateToken then
                stableStateTicks = stableStateTicks + 1
            else
                lastStateToken = stateToken
                stableStateTicks = 0
            end
        else
            firstTraitsSeenTick = nil
            lastStateToken = nil
            stableStateTicks = 0
        end

        local shouldCapture = false
        if ticksWaited >= maxWaitTicks then
            shouldCapture = true
        elseif hasTraits and stableStateTicks >= stabilityRequiredTicks then
            shouldCapture = true
        end

        if shouldCapture then
            BurdJournals.Client.unregisterTickHandler(handlerId)
            BurdJournals.Client._newCharacterBaselineCaptureHandlerId = nil
            BurdJournals.Client._pendingNewCharacterBaseline = false

            if hasBaselineCapturedLocal(currentPlayer) then
                return
            end

            if not hasTraits then
                BurdJournals.debugPrint("[BurdJournals] WARNING: Max wait reached (" .. ticksWaited .. " ticks), capturing baseline without full traits")
            elseif ticksWaited >= maxWaitTicks then
                BurdJournals.debugPrint("[BurdJournals] WARNING: Max wait reached (" .. ticksWaited
                    .. " ticks) after trait detection (traits=" .. tostring(traitCount)
                    .. ", recipes=" .. tostring(recipeCount) .. "), capturing baseline")
            else
                BurdJournals.debugPrint("[BurdJournals] Trait/recipe state stabilized after " .. ticksWaited
                    .. " ticks (stableFor=" .. tostring(stableStateTicks)
                    .. ", traits=" .. tostring(traitCount)
                    .. ", recipes=" .. tostring(recipeCount) .. "), capturing baseline")
            end

            BurdJournals.Client.captureBaseline(currentPlayer, true)
        end
    end

    handlerId = BurdJournals.Client.registerTickHandler(
        captureAfterDelay,
        "new_character_baseline_" .. tostring(reasonTag or "bootstrap")
    )
    BurdJournals.Client._newCharacterBaselineCaptureHandlerId = handlerId
    BurdJournals.debugPrint("[BurdJournals] Queued new character baseline capture from " .. tostring(reasonTag or "unknown"))
    return true
end

function BurdJournals.Client.scheduleBaselineRetryAfterMiss(playerIndex, reasonTag)
    if not BurdJournals.Client.requestServerBaseline then
        return false
    end
    if (BurdJournals.Client._baselineMissRetryCount or 0) >= 2 then
        return false
    end

    local existingId = BurdJournals.Client._baselineMissRetryHandlerId
    if existingId and BurdJournals.Client._activeTickHandlers
        and BurdJournals.Client._activeTickHandlers[existingId] then
        return false
    end

    BurdJournals.Client._baselineMissRetryCount = (BurdJournals.Client._baselineMissRetryCount or 0) + 1

    local ticksWaited = 0
    local waitTicks = 120
    local resolvedIndex = type(playerIndex) == "number" and playerIndex or nil
    local handlerId = nil

    local retryFn
    retryFn = function()
        ticksWaited = ticksWaited + 1
        if ticksWaited < waitTicks then
            return
        end

        BurdJournals.Client.unregisterTickHandler(handlerId)
        BurdJournals.Client._baselineMissRetryHandlerId = nil

        local retryPlayer = nil
        if resolvedIndex ~= nil then
            retryPlayer = getSpecificPlayer(resolvedIndex)
        end
        if not retryPlayer then
            retryPlayer = getPlayer()
        end
        if not retryPlayer then
            return
        end

        local hoursAlive = retryPlayer.getHoursSurvived and retryPlayer:getHoursSurvived() or 0
        BurdJournals.debugPrint("[BurdJournals] Baseline retry #" .. tostring(BurdJournals.Client._baselineMissRetryCount)
            .. " (" .. tostring(reasonTag or "cache_miss") .. "), hoursAlive=" .. tostring(hoursAlive))
        BurdJournals.Client.requestServerBaseline()
    end

    handlerId = BurdJournals.Client.registerTickHandler(
        retryFn,
        "baseline_retry_" .. tostring(reasonTag or "cache_miss")
    )
    BurdJournals.Client._baselineMissRetryHandlerId = handlerId
    return true
end

function BurdJournals.Client.init()

    BurdJournals.Client.checkLanguageChange()

    local player = getPlayer()
    if player then
        if BurdJournals.compactPlayerBurdJournalsData then
            local changed, removedLegacy, removedTransient, removedSkills, removedTraits, removedRecipes =
                BurdJournals.compactPlayerBurdJournalsData(player, true)
            if changed then
                BurdJournals.debugPrint("[BurdJournals] Compacted player BurdJournals data on init: removed legacy="
                    .. tostring(removedLegacy)
                    .. ", transient=" .. tostring(removedTransient)
                    .. ", skills=" .. tostring(removedSkills)
                    .. ", traits=" .. tostring(removedTraits)
                    .. ", recipes=" .. tostring(removedRecipes))
            end
        end

        if BurdJournals.compactPlayerJournalDRCache then
            local changed, removedJournals, removedAliases = BurdJournals.compactPlayerJournalDRCache(player, true)
            if changed then
                BurdJournals.debugPrint("[BurdJournals] Compacted player DR cache on init: removed "
                    .. tostring(removedJournals) .. " journals, "
                    .. tostring(removedAliases) .. " aliases")
            end
        end

        local hoursAlive = player:getHoursSurvived() or 0

        if BurdJournals.getPlayerCharacterId then
            BurdJournals.Client._lastKnownCharacterId = BurdJournals.getPlayerCharacterId(player)
        end

        if BurdJournals.Client._pendingNewCharacterBaseline then
            BurdJournals.debugPrint("[BurdJournals] init: OnCreatePlayer is handling baseline, skipping")
            return
        end

        local snapshotWindowHours = BurdJournals.getBaselineSnapshotMaxHours
            and BurdJournals.getBaselineSnapshotMaxHours() or 1
        local withinSnapshotWindow = BurdJournals.isWithinBaselineSnapshotWindow
            and BurdJournals.isWithinBaselineSnapshotWindow(player)
            or (hoursAlive <= snapshotWindowHours)
        if withinSnapshotWindow then
            BurdJournals.debugPrint("[BurdJournals] init: Character within snapshot window (" .. hoursAlive .. " hours), queueing spawn baseline capture")
            BurdJournals.Client.queueNewCharacterBaselineCapture(player, player:getPlayerNum(), "OnGameStart")
            return
        end

        local handlerId = nil
        local requestAfterDelay
        local ticksWaited = 0
        local maxWaitTicks = 60
        requestAfterDelay = function()
            ticksWaited = ticksWaited + 1

            local currentPlayer = getPlayer()
            if not currentPlayer then
                BurdJournals.debugPrint("[BurdJournals] init delayed: Player became invalid, aborting")
                BurdJournals.Client.unregisterTickHandler(handlerId)
                return
            end

            if ticksWaited >= maxWaitTicks then
                BurdJournals.debugPrint("[BurdJournals] init delayed: Max wait reached, forcing baseline request")
                BurdJournals.Client.unregisterTickHandler(handlerId)
                BurdJournals.Client.requestServerBaseline()
                return
            end

            if ticksWaited >= 10 then
                BurdJournals.Client.unregisterTickHandler(handlerId)

                if BurdJournals.Client._pendingNewCharacterBaseline then
                    BurdJournals.debugPrint("[BurdJournals] init delayed: OnCreatePlayer took over, aborting")
                    return
                end

                BurdJournals.debugPrint("[BurdJournals] init: Existing character (" .. hoursAlive .. " hours), requesting baseline from server")
                BurdJournals.Client.requestServerBaseline()
            end
        end
        handlerId = BurdJournals.Client.registerTickHandler(requestAfterDelay, "init_baseline_request")
    end
end

BurdJournals.Client.HaloColors = {
    XP_GAIN = {r=0.3, g=0.9, b=0.3, a=1},
    TRAIT_GAIN = {r=0.9, g=0.7, b=0.2, a=1},
    RECIPE_GAIN = {r=0.4, g=0.85, b=0.95, a=1},
    DISSOLVE = {r=0.7, g=0.5, b=0.3, a=1},
    ERROR = {r=0.9, g=0.3, b=0.3, a=1},
    INFO = {r=1, g=1, b=1, a=1},
}

function BurdJournals.Client.showHaloMessage(player, message, color)
    if not player then return end
    color = color or BurdJournals.Client.HaloColors.INFO

    if HaloTextHelper then
        -- Use the correct HaloTextHelper methods based on color type
        -- Note: Only use addGoodText/addBadText - addText has internal issues in B42
        if color == BurdJournals.Client.HaloColors.ERROR then
            -- Bad/error messages (red)
            if HaloTextHelper.addBadText then
                HaloTextHelper.addBadText(player, message)
            else
                player:Say(message)
            end
        else
            -- All other messages use green (good) text for visibility
            if HaloTextHelper.addGoodText then
                HaloTextHelper.addGoodText(player, message)
            else
                player:Say(message)
            end
        end
    else
        player:Say(message)
    end
end

local function getCursedClientText(key, fallback)
    local text = getText(key)
    if text and text ~= "" and text ~= key then
        return text
    end
    return fallback
end

local function normalizeCursedLine(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    if text == "" then
        return nil
    end
    if string.gsub(text, "%s+", "") == "" then
        return nil
    end
    return text
end

local function buildFallbackCurseMessage(curseType, focusText, focusType)
    local focus = normalizeCursedLine(focusText)
    if curseType == "barbed_seal" then
        local template = getCursedClientText("UI_BurdJournals_CursedMsgBarbedSeal", "Barbed wire bites your %s as you tear the seal free.")
        if focus then
            return template:gsub("%%s", focus)
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgBarbedSealGeneric", "Barbed wire bites your hand as you tear the seal free.")
    end
    if curseType == "jammed_breath" then
        return getCursedClientText(
            "UI_BurdJournals_CursedMsgJammedBreath",
            "Your lungs seize as if something is gripping your chest."
        )
    end
    if curseType == "hexed_tooling" then
        local template = getCursedClientText("UI_BurdJournals_CursedMsgHexedTooling", "Your %s dulls and cracks under a sudden malignant strain.")
        if focus then
            return template:gsub("%%s", focus)
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgHexedToolingGeneric", "Your gear dulls and cracks under a sudden malignant strain.")
    end
    if curseType == "torn_gear" then
        local template = getCursedClientText("UI_BurdJournals_CursedMsgTornGear", "Something invisible rakes across your clothes, leaving %d fresh tears.")
        if focus and tonumber(focus) then
            local ok, formatted = pcall(string.format, template, math.floor(tonumber(focus)))
            if ok and normalizeCursedLine(formatted) then
                return formatted
            end
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgTornGearGeneric", "Something invisible rakes across your clothes.")
    end
    if curseType == "seasonal_wave" then
        if focusType == "seasonal_wave" and focus then
            local lowered = string.lower(focus)
            if string.find(lowered, "cold", 1, true) then
                return getCursedClientText("UI_BurdJournals_CursedMsgSeasonalCold", "The air turns hostile in an instant. Cold sinks into your bones.")
            end
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgSeasonalHeat", "The air turns hostile in an instant. Heat claws at your skin.")
    end
    if curseType == "pantsed" then
        return getCursedClientText("UI_BurdJournals_CursedMsgPantsed", "Caught you with your pants down.")
    end
    if curseType == "gain_negative_trait" then
        local template = getCursedClientText("UI_BurdJournals_CursedMsgGainNegative", "The curse brands you with: %s")
        if focus then
            return template:gsub("%%s", focus)
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgGainNegativeGeneric", "The curse brands you with a negative trait.")
    end
    if curseType == "lose_positive_trait" then
        local template = getCursedClientText("UI_BurdJournals_CursedMsgLosePositive", "The curse strips away: %s")
        if focus then
            return template:gsub("%%s", focus)
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgLosePositiveGeneric", "The curse strips away one of your positive traits.")
    end
    if curseType == "lose_skill_level" then
        local template = getCursedClientText("UI_BurdJournals_CursedMsgLoseSkill", "Your %s knowledge decays.")
        if focus then
            return template:gsub("%%s", focus)
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgLoseSkillGeneric", "A skill level withers away.")
    end
    if curseType == "panic" then
        if focusType == "horde_count" then
            local count = tonumber(focus)
            if count then
                local template = getCursedClientText(
                    "UI_BurdJournals_CursedMsgPanicHorde",
                    "Ambush! A wave of panic grips you as %d dead answer the broken seal."
                )
                local ok, formatted = pcall(string.format, template, math.floor(count))
                if ok and normalizeCursedLine(formatted) then
                    return formatted
                end
            end
        end
        return getCursedClientText("UI_BurdJournals_CursedMsgPanic", "Ambush! A wave of panic grips you.")
    end
    return getCursedClientText("UI_BurdJournals_CursedRevealFallback", "A curse takes hold...")
end

local CURSED_PROMPT_THEME = {
    panelBg = { r = 0.09, g = 0.05, b = 0.13, a = 0.95 },
    panelBorder = { r = 0.67, g = 0.48, b = 0.86, a = 1.0 },
    title = { r = 0.96, g = 0.88, b = 1.0 },
    text = { r = 0.86, g = 0.78, b = 0.95 },
    accent = { r = 0.77, g = 0.55, b = 0.94 },
    highlight = { r = 0.90, g = 0.66, b = 1.0 },
    btnAccept = { r = 0.30, g = 0.16, b = 0.44, a = 0.95 },
    btnAcceptHover = { r = 0.41, g = 0.23, b = 0.58, a = 1.0 },
    btnNo = { r = 0.48, g = 0.15, b = 0.15, a = 0.95 },
    btnNoHover = { r = 0.62, g = 0.20, b = 0.20, a = 1.0 },
    btnBorder = { r = 0.74, g = 0.55, b = 0.90, a = 1.0 },
    btnText = { r = 0.97, g = 0.91, b = 1.0, a = 1.0 },
}

local function ensureCursedRichTextPanelClass()
    if ISRichTextPanel then
        return true
    end
    local ok = pcall(function()
        require "ISUI/ISRichTextPanel"
    end)
    return ok == true and ISRichTextPanel ~= nil
end

local function escapeCursedRichText(text)
    local value = tostring(text or "")
    value = string.gsub(value, "<", "&lt;")
    value = string.gsub(value, ">", "&gt;")
    return value
end

local function buildCursedPromptRichText(loreLine, consequenceLine, confirmLine)
    local title = escapeCursedRichText(getCursedClientText("UI_BurdJournals_CursedPromptTitle", "Break the Seal?"))
    local lore = escapeCursedRichText(loreLine)
    local consequence = escapeCursedRichText(consequenceLine)
    local confirm = escapeCursedRichText(confirmLine)

    return string.format(
        "<CENTRE> <RGB:%.3f,%.3f,%.3f> %s <BR> <RGB:%.3f,%.3f,%.3f> %s <BR> <RGB:%.3f,%.3f,%.3f> %s <BR> <RGB:%.3f,%.3f,%.3f> %s",
        CURSED_PROMPT_THEME.title.r, CURSED_PROMPT_THEME.title.g, CURSED_PROMPT_THEME.title.b, title,
        CURSED_PROMPT_THEME.text.r, CURSED_PROMPT_THEME.text.g, CURSED_PROMPT_THEME.text.b, lore,
        CURSED_PROMPT_THEME.accent.r, CURSED_PROMPT_THEME.accent.g, CURSED_PROMPT_THEME.accent.b, consequence,
        CURSED_PROMPT_THEME.highlight.r, CURSED_PROMPT_THEME.highlight.g, CURSED_PROMPT_THEME.highlight.b, confirm
    )
end

local function buildCursedRevealRichText(revealLead, curseMessage, focusText)
    local title = escapeCursedRichText(getCursedClientText("UI_BurdJournals_CursedRevealTitle", "The Curse Unleashed"))
    local lead = escapeCursedRichText(revealLead)
    local body = escapeCursedRichText(curseMessage)
    local focus = normalizeCursedLine(focusText)
    local escapedFocus = focus and escapeCursedRichText(focus) or nil
    local focusLine = ""
    if escapedFocus and escapedFocus ~= "" then
        focusLine = string.format(
            " <BR> <RGB:%.3f,%.3f,%.3f> [ %s ]",
            CURSED_PROMPT_THEME.highlight.r,
            CURSED_PROMPT_THEME.highlight.g,
            CURSED_PROMPT_THEME.highlight.b,
            escapedFocus
        )
    end

    return string.format(
        "<CENTRE> <RGB:%.3f,%.3f,%.3f> %s <BR> <RGB:%.3f,%.3f,%.3f> %s <BR> <RGB:%.3f,%.3f,%.3f> %s%s",
        CURSED_PROMPT_THEME.title.r, CURSED_PROMPT_THEME.title.g, CURSED_PROMPT_THEME.title.b, title,
        CURSED_PROMPT_THEME.accent.r, CURSED_PROMPT_THEME.accent.g, CURSED_PROMPT_THEME.accent.b, lead,
        CURSED_PROMPT_THEME.text.r, CURSED_PROMPT_THEME.text.g, CURSED_PROMPT_THEME.text.b, body, focusLine
    )
end

local function styleCursedModalButton(button, keepRed)
    if not button then
        return
    end

    if keepRed then
        button.backgroundColor = {
            r = CURSED_PROMPT_THEME.btnNo.r,
            g = CURSED_PROMPT_THEME.btnNo.g,
            b = CURSED_PROMPT_THEME.btnNo.b,
            a = CURSED_PROMPT_THEME.btnNo.a
        }
        button.backgroundColorMouseOver = {
            r = CURSED_PROMPT_THEME.btnNoHover.r,
            g = CURSED_PROMPT_THEME.btnNoHover.g,
            b = CURSED_PROMPT_THEME.btnNoHover.b,
            a = CURSED_PROMPT_THEME.btnNoHover.a
        }
    else
        button.backgroundColor = {
            r = CURSED_PROMPT_THEME.btnAccept.r,
            g = CURSED_PROMPT_THEME.btnAccept.g,
            b = CURSED_PROMPT_THEME.btnAccept.b,
            a = CURSED_PROMPT_THEME.btnAccept.a
        }
        button.backgroundColorMouseOver = {
            r = CURSED_PROMPT_THEME.btnAcceptHover.r,
            g = CURSED_PROMPT_THEME.btnAcceptHover.g,
            b = CURSED_PROMPT_THEME.btnAcceptHover.b,
            a = CURSED_PROMPT_THEME.btnAcceptHover.a
        }
    end

    button.borderColor = {
        r = CURSED_PROMPT_THEME.btnBorder.r,
        g = CURSED_PROMPT_THEME.btnBorder.g,
        b = CURSED_PROMPT_THEME.btnBorder.b,
        a = CURSED_PROMPT_THEME.btnBorder.a
    }
    button.textColor = {
        r = CURSED_PROMPT_THEME.btnText.r,
        g = CURSED_PROMPT_THEME.btnText.g,
        b = CURSED_PROMPT_THEME.btnText.b,
        a = CURSED_PROMPT_THEME.btnText.a
    }
end

local function getCursedModalViewport(player)
    local core = getCore and getCore() or nil
    local left = 0
    local top = 0
    local width = (core and core.getScreenWidth and core:getScreenWidth()) or 1280
    local height = (core and core.getScreenHeight and core:getScreenHeight()) or 720

    if player and player.getPlayerNum and getPlayerScreenWidth and getPlayerScreenHeight and getPlayerScreenLeft and getPlayerScreenTop then
        local pnum = player:getPlayerNum()
        local pwidth = tonumber(getPlayerScreenWidth(pnum)) or 0
        local pheight = tonumber(getPlayerScreenHeight(pnum)) or 0
        if pwidth > 0 and pheight > 0 then
            width = pwidth
            height = pheight
            left = tonumber(getPlayerScreenLeft(pnum)) or 0
            top = tonumber(getPlayerScreenTop(pnum)) or 0
        end
    end

    return left, top, width, height
end

local function measureCursedRichTextHeight(richText, richWidth)
    if not ensureCursedRichTextPanelClass() then
        return nil
    end

    local probeWidth = math.max(140, tonumber(richWidth) or 140)
    local probe = ISRichTextPanel:new(0, 0, probeWidth, 2000)
    probe:initialise()
    probe:instantiate()
    probe.defaultFont = UIFont.Small
    probe.clip = true
    probe:setMargins(0, 0, 0, 0)
    probe:setText(richText or "")
    probe:paginate()

    local measured = tonumber((probe.getScrollHeight and probe:getScrollHeight()) or 0) or 0
    if measured <= 0 then
        measured = tonumber(probe.height) or 0
    end
    if measured <= 0 then
        return nil
    end
    return math.ceil(measured)
end

local function showCursedThemedModal(player, yesNo, richText, plainText, callback, journalId)
    if not ISModalDialog then
        return nil
    end

    local screenLeft, screenTop, screenWidth, screenHeight = getCursedModalViewport(player)

    local width = math.max(400, math.min(640, math.floor(screenWidth * 0.82)))
    if width > (screenWidth - 24) then
        width = math.max(280, screenWidth - 24)
    end

    local bodyX = 18
    local bodyY = 20
    local bodyWidth = math.max(220, width - 36)
    local footerHeight = 84 -- leave extra room for scaled/translated buttons
    local minBodyHeight = 108
    local maxBodyHeight = math.max(minBodyHeight, math.floor(screenHeight * 0.62))

    local measuredBodyHeight = measureCursedRichTextHeight(richText, bodyWidth) or minBodyHeight
    local bodyHeight = math.max(minBodyHeight, math.min(maxBodyHeight, measuredBodyHeight + 6))
    local height = bodyY + bodyHeight + footerHeight
    local maxHeight = math.max(180, screenHeight - 20)
    if height > maxHeight then
        height = maxHeight
        bodyHeight = math.max(84, height - bodyY - footerHeight)
    end

    local modalX = screenLeft + math.floor((screenWidth - width) / 2)
    local modalY = screenTop + math.floor((screenHeight - height) / 2)
    modalX = math.max(screenLeft + 4, modalX)
    modalY = math.max(screenTop + 4, modalY)

    local modal = ISModalDialog:new(
        modalX,
        modalY,
        width, height,
        "",
        yesNo,
        player,
        callback,
        nil,
        journalId
    )
    modal:initialise()
    modal.backgroundColor = {
        r = CURSED_PROMPT_THEME.panelBg.r,
        g = CURSED_PROMPT_THEME.panelBg.g,
        b = CURSED_PROMPT_THEME.panelBg.b,
        a = CURSED_PROMPT_THEME.panelBg.a
    }
    modal.borderColor = {
        r = CURSED_PROMPT_THEME.panelBorder.r,
        g = CURSED_PROMPT_THEME.panelBorder.g,
        b = CURSED_PROMPT_THEME.panelBorder.b,
        a = CURSED_PROMPT_THEME.panelBorder.a
    }
    modal.text = plainText or ""

    if modal.yes then
        styleCursedModalButton(modal.yes, false)
    end
    if modal.no then
        styleCursedModalButton(modal.no, true)
    end
    if modal.ok then
        styleCursedModalButton(modal.ok, false)
    end

    -- Final guard: ensure body region stays above the actual button row.
    local buttonTop = nil
    local function recordButtonTop(btn)
        if not btn then
            return
        end
        local y = tonumber((btn.getY and btn:getY()) or btn.y) or nil
        if y and y > 0 and (not buttonTop or y < buttonTop) then
            buttonTop = y
        end
    end
    recordButtonTop(modal.yes)
    recordButtonTop(modal.no)
    recordButtonTop(modal.ok)
    if buttonTop and buttonTop > (bodyY + 20) then
        local maxBodyFromButtons = math.floor(buttonTop - bodyY - 10)
        if maxBodyFromButtons > 80 then
            bodyHeight = math.min(bodyHeight, maxBodyFromButtons)
        end
    end

    if ensureCursedRichTextPanelClass() then
        local rich = ISRichTextPanel:new(bodyX, bodyY, bodyWidth, bodyHeight)
        rich:initialise()
        rich:instantiate()
        -- Keep the text panel fixed and clipped. This prevents long localized
        -- strings from expanding over button hitboxes.
        rich.autosetheight = false
        rich.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
        rich.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        rich.defaultFont = UIFont.Small
        rich.clip = true
        rich:setMargins(0, 0, 0, 0)
        rich:setText(richText or "")
        rich:paginate()
        modal.text = ""
        modal:addChild(rich)

        local scrollHeight = tonumber((rich.getScrollHeight and rich:getScrollHeight()) or 0) or 0
        if scrollHeight > (bodyHeight + 2) then
            local hintText = getCursedClientText("UI_BurdJournals_CursedScrollHint", "Scroll for more")
            local hintWidth = (getTextManager and getTextManager():MeasureStringX(UIFont.Small, hintText)) or 120
            local hintX = math.max(bodyX + 2, bodyX + bodyWidth - hintWidth)
            local hintY = bodyY + bodyHeight - (FONT_HGT_SMALL + 2)
            local hint = ISLabel:new(
                hintX,
                hintY,
                FONT_HGT_SMALL,
                hintText,
                CURSED_PROMPT_THEME.highlight.r,
                CURSED_PROMPT_THEME.highlight.g,
                CURSED_PROMPT_THEME.highlight.b,
                0.9,
                UIFont.Small,
                true
            )
            hint:initialise()
            hint:instantiate()
            modal:addChild(hint)
        end
    end

    modal:addToUIManager()
    return modal
end

local function playCursedSealSound(player, soundName)
    if not player or type(soundName) ~= "string" or soundName == "" or soundName == "none" then
        return false
    end

    local emitter = player.getEmitter and player:getEmitter() or nil
    if emitter and emitter.playSound then
        local ok, soundId = pcall(function()
            return emitter:playSound(soundName)
        end)
        if ok and (soundId == nil or soundId ~= 0) then
            return true
        end
    end

    if player.playSound then
        local ok, soundId = pcall(function()
            return player:playSound(soundName)
        end)
        if ok and (soundId == nil or soundId ~= 0) then
            return true
        end
    end

    if getSoundManager then
        local soundMgr = getSoundManager()
        if soundMgr and soundMgr.playUISound then
            local ok = pcall(function()
                soundMgr:playUISound(soundName)
            end)
            if ok then
                return true
            end
        end
    end

    return false
end

local function emitClientCursedAIPull(player, radius, volume)
    if not player or not addSound then
        return false
    end

    local soundRadius = math.max(0, tonumber(radius) or 0)
    local soundVolume = math.max(0, tonumber(volume) or 100)
    if soundRadius <= 0 or soundVolume <= 0 then
        return false
    end

    local square = player.getCurrentSquare and player:getCurrentSquare() or nil
    if not square then
        return false
    end

    addSound(player, square:getX(), square:getY(), square:getZ(), soundRadius, soundVolume)
    return true
end

local function emitClientCursedAIPullDelayed(player, radius, volume, delayMs)
    if not player then
        return
    end

    local delay = math.max(0, tonumber(delayMs) or 0)
    if delay <= 0 then
        emitClientCursedAIPull(player, radius, volume)
        return
    end

    local events = Events and Events.OnTick or nil
    if not events or not events.Add then
        emitClientCursedAIPull(player, radius, volume)
        return
    end

    local startedAt = getTimestampMs and getTimestampMs() or nil
    local waitedTicks = 0
    local onTickFn
    onTickFn = function()
        local ready = false
        if startedAt then
            local now = getTimestampMs and getTimestampMs() or startedAt
            ready = (now - startedAt) >= delay
        else
            waitedTicks = waitedTicks + 1
            ready = waitedTicks >= 60
        end
        if not ready then
            return
        end

        emitClientCursedAIPull(player, radius, volume)
        if BurdJournals.safeRemoveEvent then
            BurdJournals.safeRemoveEvent(events, onTickFn)
        elseif events.Remove then
            events.Remove(onTickFn)
        end
    end

    events.Add(onTickFn)
end

local CLIENT_CURSED_AMBUSH_BASE_RADIUS = 80

local function getClientCursedAmbushPull(args)
    local base = tonumber(args and args.ambushNoiseRadius)
    if base == nil then
        base = CLIENT_CURSED_AMBUSH_BASE_RADIUS
    end
    base = math.max(0, math.min(300, math.floor(base + 0.5)))
    if base <= 0 then
        return 0, 0
    end

    local radius = tonumber(args and args.ambushNoiseRadiusApplied) or math.max(1, math.min(300, base + 20))
    local volume = tonumber(args and args.ambushNoiseVolumeApplied) or math.max(radius, math.min(300, base + 40))
    radius = math.max(1, math.min(300, math.floor(radius + 0.5)))
    volume = math.max(1, math.min(300, math.floor(volume + 0.5)))
    return radius, volume
end

local function nudgeClientAmbushZombiesToward(player, radius)
    if not player or not getCell then
        return 0
    end

    local cell = getCell()
    if not cell then
        return 0
    end

    local zombies = cell.getZombieList and cell:getZombieList() or nil
    if not zombies or not zombies.size then
        return 0
    end

    local square = player.getCurrentSquare and player:getCurrentSquare() or nil
    if not square then
        return 0
    end

    local px = square:getX()
    local py = square:getY()
    local pz = square:getZ()
    local pullRadius = math.max(1, tonumber(radius) or 80)
    local pullRadiusSq = pullRadius * pullRadius
    local nudged = 0

    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and not zombie:isDead() and not zombie:isOnFloor() then
            local zx = tonumber(zombie.getX and zombie:getX()) or 0
            local zy = tonumber(zombie.getY and zombie:getY()) or 0
            local zz = math.floor((tonumber(zombie.getZ and zombie:getZ()) or 0) + 0.5)
            if zz == pz then
                local dx = zx - px
                local dy = zy - py
                if (dx * dx) + (dy * dy) <= pullRadiusSq then
                    local investigateX = px + ZombRand(-2, 3)
                    local investigateY = py + ZombRand(-2, 3)
                    local moved = false
                    if zombie.setUseless then
                        local ok = pcall(function() zombie:setUseless(false) end)
                        moved = moved or ok
                    end
                    if zombie.setCanWalk then
                        local ok = pcall(function() zombie:setCanWalk(true) end)
                        moved = moved or ok
                    end
                    if zombie.spotted then
                        local ok = pcall(function() zombie:spotted(player, true) end)
                        moved = moved or ok
                    end
                    if zombie.addAggro then
                        local ok = pcall(function() zombie:addAggro(player, 100.0) end)
                        moved = moved or ok
                    end
                    if zombie.setTurnAlertedValues then
                        local ok = pcall(function() zombie:setTurnAlertedValues(px, py) end)
                        moved = moved or ok
                    end
                    if zombie.pathToCharacter then
                        local ok = pcall(function() zombie:pathToCharacter(player) end)
                        moved = moved or ok
                    end
                    if zombie.setTarget then
                        local ok = pcall(function() zombie:setTarget(player) end)
                        moved = moved or ok
                    end
                    if zombie.setTargetSeenTime then
                        local ok = pcall(function() zombie:setTargetSeenTime(0) end)
                        moved = moved or ok
                    end
                    if zombie.pathToLocationF then
                        local ok = pcall(function() zombie:pathToLocationF(investigateX, investigateY, pz) end)
                        moved = moved or ok
                    end
                    if moved then
                        nudged = nudged + 1
                    end
                end
            end
        end
    end

    return nudged
end

local function nudgeClientAmbushZombiesTowardDelayed(player, radius, delayMs)
    if not player then
        return
    end

    local delay = math.max(0, tonumber(delayMs) or 0)
    if delay <= 0 then
        nudgeClientAmbushZombiesToward(player, radius)
        return
    end

    local events = Events and Events.OnTick or nil
    if not events or not events.Add then
        nudgeClientAmbushZombiesToward(player, radius)
        return
    end

    local startedAt = getTimestampMs and getTimestampMs() or nil
    local waitedTicks = 0
    local onTickFn
    onTickFn = function()
        local ready = false
        if startedAt then
            local now = getTimestampMs and getTimestampMs() or startedAt
            ready = (now - startedAt) >= delay
        else
            waitedTicks = waitedTicks + 1
            ready = waitedTicks >= 60
        end
        if not ready then
            return
        end

        nudgeClientAmbushZombiesToward(player, radius)
        if BurdJournals.safeRemoveEvent then
            BurdJournals.safeRemoveEvent(events, onTickFn)
        elseif events.Remove then
            events.Remove(onTickFn)
        end
    end

    events.Add(onTickFn)
end

local function shouldPlayCursedSealSound(journalId, soundName)
    if type(soundName) ~= "string" or soundName == "" then
        return false
    end

    local now = getTimestampMs and getTimestampMs() or (os.time() * 1000)
    local journalKey = tostring(journalId or "nil")
    local soundKey = string.lower(soundName)
    local historyByJournal = BurdJournals.Client._lastCursedSealSoundByJournal or {}
    local journalHistory = historyByJournal[journalKey] or {}
    local lastAt = tonumber(journalHistory[soundKey]) or 0
    if lastAt > 0 and (now - lastAt) <= 250 then
        return false
    end

    journalHistory[soundKey] = now
    historyByJournal[journalKey] = journalHistory
    BurdJournals.Client._lastCursedSealSoundByJournal = historyByJournal
    return true
end

function BurdJournals.Client.openJournalAfterCursedReveal(player, journalId)
    if not player or not journalId then
        return
    end

    local function tryOpenNow()
        local journal = BurdJournals.findItemById and BurdJournals.findItemById(player, journalId)
        if not journal then
            return false
        end
        if not BurdJournals.isFilledJournal or not BurdJournals.isFilledJournal(journal) then
            return false
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end
        if BurdJournals.UI and BurdJournals.UI.MainPanel then
            BurdJournals.UI.MainPanel.show(player, journal, "absorb")
            return true
        end
        return false
    end

    if tryOpenNow() then
        return
    end

    local waited = 0
    local maxTicks = 120
    local waitForJournal
    waitForJournal = function()
        waited = waited + 1
        if tryOpenNow() or waited >= maxTicks then
            Events.OnTick.Remove(waitForJournal)
        end
    end
    Events.OnTick.Add(waitForJournal)
end

function BurdJournals.Client.onConfirmCursedOpen(target, button, journalId)
    if button and button.internal == "YES" and target and journalId then
        sendClientCommand(target, "BurdJournals", "openCursedJournal", {
            journalId = journalId,
            confirm = true,
        })
    end
end

function BurdJournals.Client.onDismissCursedReveal(target, button, journalId)
    if button and button.internal == "OK" and target and journalId then
        BurdJournals.Client.openJournalAfterCursedReveal(target, journalId)
    end
end

function BurdJournals.Client.handleCursedOpenPrompt(player, args)
    if not player or type(args) ~= "table" then
        return
    end
    local journalId = tonumber(args.journalId)
    if not journalId then
        return
    end

    local loreLine = args.loreLine
        or getCursedClientText("UI_BurdJournals_CursedPromptLore", "Ink writhes across the page. Something waits beneath these words.")
    local consequenceLine = args.consequenceLine
        or getCursedClientText("UI_BurdJournals_CursedPromptConsequence", "The first soul to read it will be marked.")
    local confirmLine = getCursedClientText("UI_BurdJournals_CursedPromptConfirm", "Open it anyway?")
    local promptText = tostring(loreLine) .. "\n\n" .. tostring(consequenceLine) .. "\n\n" .. tostring(confirmLine)
    local promptRichText = buildCursedPromptRichText(loreLine, consequenceLine, confirmLine)

    if not ISModalDialog then
        BurdJournals.Client.showHaloMessage(player, consequenceLine, BurdJournals.Client.HaloColors.ERROR)
        sendClientCommand(player, "BurdJournals", "openCursedJournal", {
            journalId = journalId,
            confirm = true,
        })
        return
    end

    showCursedThemedModal(
        player,
        true,
        promptRichText,
        promptText,
        BurdJournals.Client.onConfirmCursedOpen,
        journalId
    )
end

function BurdJournals.Client.handleCursedOpened(player, args)
    if not player or type(args) ~= "table" then
        return
    end

    local journalId = tonumber(args.journalId)
    local curseType = normalizeCursedLine(args.curseType)
    local soundEvent = args.soundEvent
    local focusText = normalizeCursedLine(args.focusText)
    local curseMessage = normalizeCursedLine(args.curseMessage)
    if curseMessage then
        local lowerMsg = string.lower(curseMessage)
        if string.find(lowerMsg, "a curse takes hold", 1, true) then
            curseMessage = nil
        end
    end
    if not curseMessage then
        curseMessage = buildFallbackCurseMessage(curseType, focusText, args.focusType)
    end
    if not curseMessage then
        curseMessage = getCursedClientText("UI_BurdJournals_CursedRevealFallback", "A curse takes hold...")
    end
    local revealLead = getCursedClientText("UI_BurdJournals_CursedRevealLead", "The seal breaks. Something answers.")
    local revealBody = tostring(revealLead) .. "\n\n" .. tostring(curseMessage)
    local revealRichText = buildCursedRevealRichText(revealLead, curseMessage, focusText)

    if curseType == "panic" and player and player.getStats then
        local stats = player:getStats()
        if stats then
            local currentPanic = (stats.getPanic and tonumber(stats:getPanic())) or 0
            local targetPanic = math.min(100, math.max(80, currentPanic + 60))
            if stats.setPanic then
                pcall(function()
                    stats:setPanic(targetPanic)
                end)
            elseif CharacterStat and CharacterStat.PANIC and stats.set then
                pcall(function()
                    stats:set(CharacterStat.PANIC, targetPanic)
                end)
            end
        end
    end

    if curseType == "panic" then
        local pullRadius, pullVolume = getClientCursedAmbushPull(args)
        if pullRadius > 0 and pullVolume > 0 then
            emitClientCursedAIPull(player, pullRadius, pullVolume)
            nudgeClientAmbushZombiesToward(player, pullRadius + 10)
            nudgeClientAmbushZombiesTowardDelayed(player, pullRadius + 10, 900)
            nudgeClientAmbushZombiesTowardDelayed(player, pullRadius + 10, 1700)
            emitClientCursedAIPullDelayed(player, pullRadius, pullVolume, 700)
            emitClientCursedAIPullDelayed(player, pullRadius, pullVolume, 1400)
        end
    end

    local requestedSound = nil
    if type(soundEvent) == "string" and soundEvent ~= "" and soundEvent ~= "none" then
        requestedSound = soundEvent
    else
        if BurdJournals.getRandomCursedSealSoundEvent then
            requestedSound = BurdJournals.getRandomCursedSealSoundEvent()
        end
        if not requestedSound or requestedSound == "" then
            requestedSound = BurdJournals.CURSED_DEFAULT_SOUND_EVENT or "PaperRip"
        end
    end

    if shouldPlayCursedSealSound(journalId, requestedSound) then
        playCursedSealSound(player, requestedSound)
    end
    if curseType == "barbed_seal" then
        local barbedInjurySound = nil
        if BurdJournals.getRandomCursedBarbedInjurySoundEvent then
            barbedInjurySound = BurdJournals.getRandomCursedBarbedInjurySoundEvent()
        end
        if not barbedInjurySound or barbedInjurySound == "" then
            barbedInjurySound = "ZombieScratch"
        end
        if shouldPlayCursedSealSound(journalId, barbedInjurySound) then
            playCursedSealSound(player, barbedInjurySound)
        end
    end

    if not ISModalDialog then
        BurdJournals.Client.showHaloMessage(player, curseMessage, BurdJournals.Client.HaloColors.ERROR)
        BurdJournals.Client.openJournalAfterCursedReveal(player, journalId)
        return
    end

    showCursedThemedModal(
        player,
        false,
        revealRichText,
        revealBody,
        BurdJournals.Client.onDismissCursedReveal,
        journalId
    )
end

function BurdJournals.Client.onServerCommand(module, command, args)
    -- Debug: Log ALL incoming server commands
    if module == "BurdJournals" then
        local logMsg = "[BurdJournals] Client received server command: " .. tostring(command)
        if command == "error" and args and args.message then
            logMsg = logMsg .. " - MESSAGE: '" .. tostring(args.message) .. "'"
        end
        BurdJournals.debugPrint(logMsg)
    end

    if module ~= "BurdJournals" then return end

    local player = getPlayer()
    if not player then return end

    if command == "applyXP" then
        BurdJournals.Client.handleApplyXP(player, args)

    elseif command == "absorbSuccess" then
        BurdJournals.Client.handleAbsorbSuccess(player, args)

    elseif command == "journalDissolved" then
        BurdJournals.Client.handleJournalDissolved(player, args)

    elseif command == "grantTrait" then
        BurdJournals.Client.handleGrantTrait(player, args)

    elseif command == "traitAlreadyKnown" then
        BurdJournals.Client.handleTraitAlreadyKnown(player, args)

    elseif command == "skillMaxed" then
        BurdJournals.Client.handleSkillMaxed(player, args)

    elseif command == "claimSuccess" then
        BurdJournals.Client.handleClaimSuccess(player, args)
    elseif command == "forgetSlotClaimed" then
        BurdJournals.Client.handleForgetSlotClaimed(player, args)
    elseif command == "cursedOpenPrompt" then
        BurdJournals.Client.handleCursedOpenPrompt(player, args)
    elseif command == "cursedOpened" then
        BurdJournals.Client.handleCursedOpened(player, args)

    elseif command == "logSuccess" then
        BurdJournals.Client.showHaloMessage(player, getText("UI_BurdJournals_SkillsRecorded") or "Skills recorded!", BurdJournals.Client.HaloColors.INFO)

    elseif command == "recordSuccess" then
        BurdJournals.Client.handleRecordSuccess(player, args)

    elseif command == "eraseSuccess" then
        BurdJournals.Client.handleEraseSuccess(player, args)

    elseif command == "cleanSuccess" then
        local message = args and args.message or (getText("UI_BurdJournals_JournalCleaned") or "Journal cleaned")
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)

    elseif command == "convertSuccess" then
        local message = args and args.message or (getText("UI_BurdJournals_JournalRebound") or "Journal rebound")
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)

    elseif command == "removeJournal" then
        BurdJournals.Client.handleRemoveJournal(player, args)

    elseif command == "journalInitialized" then
        BurdJournals.Client.handleJournalInitialized(player, args)

    elseif command == "recipeAlreadyKnown" then
        BurdJournals.Client.handleRecipeAlreadyKnown(player, args)

    elseif command == "baselineResponse" then
        BurdJournals.Client.handleBaselineResponse(player, args)

    elseif command == "baselineRegistered" then
        BurdJournals.Client.handleBaselineRegistered(player, args)

    elseif command == "allBaselinesCleared" then
        BurdJournals.Client.handleAllBaselinesCleared(player, args)

    elseif command == "syncSuccess" then
        BurdJournals.Client.handleSyncSuccess(player, args)

    elseif command == "error" then
        if args and args.message then
            BurdJournals.Client.showHaloMessage(player, args.message, BurdJournals.Client.HaloColors.ERROR)
        end
    
    -- Debug command responses
    elseif command == "debugSuccess" then
        if args and args.message then
            BurdJournals.Client.showHaloMessage(player, args.message, BurdJournals.Client.HaloColors.INFO)
            BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. args.message)
        end
        -- Update debug panel status if open
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(args.message or "Done", {r=0.3, g=1, b=0.5})
        end
    
    elseif command == "debugError" then
        if args and args.message then
            BurdJournals.Client.showHaloMessage(player, args.message, BurdJournals.Client.HaloColors.ERROR)
            print("[BSJ DEBUG] Server Error: " .. args.message)
        end
        -- Update debug panel status if open
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(args.message or "Error", {r=1, g=0.3, b=0.3})
        end
    
    elseif command == "debugAllSkillsSet" then
        -- Server finished setting all skills
        local level = args and args.level or "?"
        local count = args and args.count or "?"
        local message = "Set " .. count .. " skills to level " .. level
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        -- Just update status, no auto-refresh (user can refresh manually)
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
    
    elseif command == "debugAllTraitsRemoved" then
        -- Server finished removing all traits
        local count = args and args.count or "?"
        local message = "Removed " .. count .. " traits"
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
    
    elseif command == "debugTraitAdded" then
        -- Server finished adding a trait
        local traitId = args and args.traitId or "?"
        local message = "Added trait: " .. traitId
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.TRAIT_GAIN)
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
        
        -- Also refresh main panel if open (for claiming traits from debug-spawned player journals)
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(traitId) or traitId
            local traitSessionKey = string.lower(tostring(normalizedTraitId or traitId))
            -- Track this trait as claimed in session
            if not panel.sessionClaimedTraits then panel.sessionClaimedTraits = {} end
            panel.sessionClaimedTraits[traitId] = true
            panel.sessionClaimedTraits[traitSessionKey] = true
            -- Clear pending
            if panel.pendingClaims and panel.pendingClaims.traits then
                panel.pendingClaims.traits[traitId] = nil
                panel.pendingClaims.traits[traitSessionKey] = nil
            end
            -- Refresh appropriate list
            if panel.refreshJournalData then
                panel:refreshJournalData()
            elseif panel.refreshAbsorptionList then
                panel:refreshAbsorptionList()
            end
        end
    
    elseif command == "debugTraitRemoved" then
        -- Server finished removing a specific trait
        local traitId = args and args.traitId or "?"
        local removeCount = args and args.removeCount or 1
        local message = removeCount > 1 and ("Removed " .. removeCount .. " instances of: " .. traitId) or ("Removed: " .. traitId)
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
    
    elseif command == "debugSkillSet" then
        -- Server finished setting a single skill level
        local skillName = args and args.skillName or "?"
        local level = args and args.level or "?"
        local message = "Set " .. skillName .. " to level " .. level
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
    
    elseif command == "debugBaselineSkillSet" then
        -- Server finished updating a skill baseline
        local skillName = args and args.skillName or "?"
        local message = "Updated " .. skillName .. " baseline"
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
        
        -- Notify any open journal UIs to refresh (baselines affect journals)
        if BurdJournals.notifyBaselineChanged then
            BurdJournals.notifyBaselineChanged()
        end
        if isLocalBaselineTarget(player, args)
            and BurdJournals.Client.requestServerBaseline
        then
            BurdJournals.Client.requestServerBaseline()
        end
    
    elseif command == "debugBaselineTraitSet" then
        -- Server finished updating a trait baseline
        local traitId = args and args.traitId or "?"
        local isBaseline = args and args.isBaseline
        local status = isBaseline and "added to" or "removed from"
        local message = traitId .. " " .. status .. " baseline"
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
        end
        
        -- Notify any open journal UIs to refresh (baselines affect journals)
        if BurdJournals.notifyBaselineChanged then
            BurdJournals.notifyBaselineChanged()
        end
        if isLocalBaselineTarget(player, args)
            and BurdJournals.Client.requestServerBaseline
        then
            BurdJournals.Client.requestServerBaseline()
        end

    elseif command == "debugBaselineDraftSaved" then
        local appliedLocalBaseline = BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer
            and BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer(player, args)
        if isLocalBaselineTarget(player, args)
            and not appliedLocalBaseline
            and BurdJournals.Client.requestServerBaseline
        then
            BurdJournals.Client.requestServerBaseline()
        end
        local message = getText("UI_BurdJournals_BaselineDraftSaved") or "Baseline draft saved."
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            local panel = BurdJournals.UI.DebugPanel.instance
            panel:setStatus(message, {r=0.3, g=1, b=0.5})
            if panel.refreshBaselineData then
                panel:refreshBaselineData()
            end
            if panel.refreshSnapshotPanelData then
                panel:refreshSnapshotPanelData()
            end
        end
        if BurdJournals.notifyBaselineChanged then
            BurdJournals.notifyBaselineChanged()
        end
    
    elseif command == "recalculateBaseline" then
        local message = args and args.message or "Baseline recalculated"
        local isLocalTarget = isLocalBaselineTarget(player, args)
        local appliedLocalBaseline = BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer
            and BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer(player, args)

        if isLocalTarget and not appliedLocalBaseline and BurdJournals.Client.requestServerBaseline then
            BurdJournals.Client.requestServerBaseline()
        end

        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)
        BurdJournals.debugPrint("[BSJ DEBUG] Server: " .. message)

        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(message, {r=0.3, g=1, b=0.5})
            BurdJournals.UI.DebugPanel.instance:refreshBaselineData()
        end

        if BurdJournals.notifyBaselineChanged then
            BurdJournals.notifyBaselineChanged()
        end
    
    elseif command == "batchClaimComplete" then
        -- Server finished processing batch claim/absorb rewards
        local count = args and args.count or 0
        local total = args and args.total or 0
        local mode = args and args.mode or "claim"
        local skillsProcessed = args and args.skillsProcessed or 0
        local traitsProcessed = args and args.traitsProcessed or 0
        local recipesProcessed = args and args.recipesProcessed or 0
        local statsProcessed = args and args.statsProcessed or 0
        local actionWord = (mode == "absorb") and "Absorbed" or "Claimed"
        local message = actionWord .. " " .. count .. "/" .. total .. " rewards"
        BurdJournals.debugPrint("[BurdJournals] Client: Batch claim complete - " .. message)
        BurdJournals.debugPrint("[BurdJournals] Client: Batch detail skills=" .. tostring(skillsProcessed)
            .. ", traits=" .. tostring(traitsProcessed)
            .. ", recipes=" .. tostring(recipesProcessed)
            .. ", stats=" .. tostring(statsProcessed))
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.XP_GAIN)
        
        -- Refresh the main panel if open
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            BurdJournals.debugPrint("[BurdJournals] Client: Refreshing panel after batch complete")
            
            -- Refresh player XP data
            panel:refreshPlayer()
            
            -- Force repopulate to show updated claimed/absorbed status
            if (panel.mode == "view" or panel.isPlayerJournal) and panel.populateViewList then
                BurdJournals.debugPrint("[BurdJournals] Client: Calling populateViewList")
                panel:populateViewList()
            elseif panel.refreshAbsorptionList then
                BurdJournals.debugPrint("[BurdJournals] Client: Calling refreshAbsorptionList")
                panel:refreshAbsorptionList()
            elseif panel.refreshJournalData then
                BurdJournals.debugPrint("[BurdJournals] Client: Calling refreshJournalData")
                panel:refreshJournalData()
            end
            
            -- Check for dissolution after batch complete
            if panel.checkDissolution then
                panel:checkDissolution(true)
            end
        end
    
    elseif command == "xpSyncComplete" then
        -- XP sync completed (fallback path)
        BurdJournals.debugPrint("[BurdJournals] Client: XP sync complete")
        -- Refresh UI to show updated XP values
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            panel:refreshPlayer()
            if panel.refreshJournalData then
                panel:refreshJournalData()
            end
        end

    -- Debug journal backup responses (for MP dedicated server persistence)
    elseif command == "debugJournalBackupSaved" then
        -- Server confirmed it saved the debug journal backup
        local journalKey = args and args.journalKey or "unknown"
        BurdJournals.debugPrint("[BurdJournals] Client: Server confirmed debug journal backup saved for key=" .. tostring(journalKey))
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus("Journal backup saved", {r=0.3, g=1, b=0.5})
        end

    elseif command == "debugJournalBackupResponse" then
        -- Server responded to our backup request (for restoration)
        BurdJournals.Client.handleDebugJournalBackupResponse(player, args)

    elseif command == "debugJournalUUIDLookupResult" then
        BurdJournals.Client.handleDebugJournalUUIDLookupResult(player, args)

    elseif command == "debugJournalUUIDRepairResult" then
        BurdJournals.Client.handleDebugJournalUUIDRepairResult(player, args)

    elseif command == "debugJournalUUIDIndexList" then
        BurdJournals.Client.handleDebugJournalUUIDIndexList(player, args)

    elseif command == "debugJournalUUIDDeleteResult" then
        BurdJournals.Client.handleDebugJournalUUIDDeleteResult(player, args)

    elseif command == "debugBaselineSnapshotList" then
        if BurdJournals.Client and BurdJournals.Client.Debug then
            BurdJournals.Client.Debug._baselineSnapshotLastList = args or {}
        end
        if args and args.items then
            BurdJournals.debugPrint("[BSJ] Baseline snapshot list: " .. tostring(args.total or #args.items)
                .. " total (page " .. tostring(args.page or 1) .. ")")
            for i, entry in ipairs(args.items) do
                local counts = entry.counts or {}
                BurdJournals.debugPrint(string.format(
                    "  %d) %s | %s | S:%d M:%d T:%d R:%d",
                    i,
                    tostring(entry.snapshotId or "?"),
                    tostring(entry.source or "unknown"),
                    tonumber(counts.skills) or 0,
                    tonumber(counts.mediaSkills) or 0,
                    tonumber(counts.traits) or 0,
                    tonumber(counts.recipes) or 0
                ))
            end
        end
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance
            and BurdJournals.UI.DebugPanel.instance.applyBaselineSnapshotList
        then
            BurdJournals.UI.DebugPanel.instance:applyBaselineSnapshotList(args or {})
        end

    elseif command == "debugBaselineSnapshotDetail" then
        if BurdJournals.Client and BurdJournals.Client.Debug then
            BurdJournals.Client.Debug._baselineSnapshotLastDetail = args and args.snapshot or nil
        end
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance
            and BurdJournals.UI.DebugPanel.instance.applyBaselineSnapshotDetail
        then
            BurdJournals.UI.DebugPanel.instance:applyBaselineSnapshotDetail(args and args.snapshot or nil)
        end

    elseif command == "debugTargetBaselinePayload" then
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance
            and BurdJournals.UI.DebugPanel.instance.applySnapshotLiveBaselinePayload
        then
            BurdJournals.UI.DebugPanel.instance:applySnapshotLiveBaselinePayload(args or {})
        end

    elseif command == "debugBaselineSnapshotSaved" then
        local msg = getText("UI_BurdJournals_BaselineSnapshotSaved") or "Baseline snapshot saved."
        BurdJournals.Client.showHaloMessage(player, msg, BurdJournals.Client.HaloColors.INFO)
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(msg, {r=0.3, g=1, b=0.5})
            if BurdJournals.UI.DebugPanel.instance.refreshSnapshotPanelData then
                BurdJournals.UI.DebugPanel.instance:refreshSnapshotPanelData()
            end
        end

    elseif command == "debugBaselineSnapshotApplied" then
        local appliedLocalBaseline = BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer
            and BurdJournals.Client.applyAuthoritativeBaselinePayloadToLocalPlayer(player, args)
        if isLocalBaselineTarget(player, args)
            and not appliedLocalBaseline
            and BurdJournals.Client.requestServerBaseline
        then
            BurdJournals.Client.requestServerBaseline()
        end
        local msg = getText("UI_BurdJournals_BaselineSnapshotApplied") or "Baseline snapshot applied."
        BurdJournals.Client.showHaloMessage(player, msg, BurdJournals.Client.HaloColors.INFO)
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(msg, {r=0.3, g=1, b=0.5})
            BurdJournals.UI.DebugPanel.instance:refreshBaselineData()
            if BurdJournals.UI.DebugPanel.instance.refreshSnapshotPanelData then
                BurdJournals.UI.DebugPanel.instance:refreshSnapshotPanelData()
            end
        end
        if BurdJournals.notifyBaselineChanged then
            BurdJournals.notifyBaselineChanged()
        end

    elseif command == "debugBaselineSnapshotDeleted" then
        local msg = getText("UI_BurdJournals_BaselineSnapshotDeleted") or "Baseline snapshot deleted."
        BurdJournals.Client.showHaloMessage(player, msg, BurdJournals.Client.HaloColors.INFO)
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus(msg, {r=0.3, g=1, b=0.5})
            if BurdJournals.UI.DebugPanel.instance.refreshSnapshotPanelData then
                BurdJournals.UI.DebugPanel.instance:refreshSnapshotPanelData()
            end
        end
    end
end

BurdJournals.Client._pendingInitCallbacks = {}
BurdJournals.Client._initRequestIdCounter = 0

function BurdJournals.Client.requestJournalInitialization(journal, callback)
    if not journal then return end

    local itemType = journal:getFullType()
    local modData = journal:getModData()
    local clientUUID = modData and modData.BurdJournals and modData.BurdJournals.uuid

    BurdJournals.Client._initRequestIdCounter = BurdJournals.Client._initRequestIdCounter + 1
    local requestId = BurdJournals.Client._initRequestIdCounter

    if callback then
        BurdJournals.Client._pendingInitCallbacks[requestId] = callback
    end

    sendClientCommand(getPlayer(), "BurdJournals", "initializeJournal", {
        itemType = itemType,
        clientUUID = clientUUID,
        requestId = requestId
    })
end

function BurdJournals.Client.handleJournalInitialized(player, args)
    if not args then return end

    local requestId = args.requestId
    if requestId and BurdJournals.Client._pendingInitCallbacks[requestId] then
        local callback = BurdJournals.Client._pendingInitCallbacks[requestId]
        BurdJournals.Client._pendingInitCallbacks[requestId] = nil
        callback(args.uuid)
    elseif BurdJournals.Client.pendingInitCallback then

        local callback = BurdJournals.Client.pendingInitCallback
        BurdJournals.Client.pendingInitCallback = nil
        callback(args.uuid)
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        BurdJournals.UI.MainPanel.instance:refreshJournalData()
    end
end

function BurdJournals.Client.handleRecordSuccess(player, args)
    if not args then return end

    BurdJournals.debugPrint("[BurdJournals] Client: handleRecordSuccess received, newJournalId=" .. tostring(args.newJournalId) .. ", journalId=" .. tostring(args.journalId))

    local recordedItems = {}

    if args.skillNames then
        for _, skillName in ipairs(args.skillNames) do
            local displayName = BurdJournals.getPerkDisplayName(skillName) or skillName
            table.insert(recordedItems, displayName)
        end
    end

    if args.traitNames then
        for _, traitId in ipairs(args.traitNames) do
            local traitName = BurdJournals.getTraitDisplayName(traitId)
            table.insert(recordedItems, traitName)
        end
    end

    if args.recipeNames then
        for _, recipeName in ipairs(args.recipeNames) do
            local displayName = BurdJournals.getRecipeDisplayName and BurdJournals.getRecipeDisplayName(recipeName) or recipeName
            table.insert(recordedItems, displayName)
        end
    end

    local message
    if args.noChanges then
        message = getText("UI_BurdJournals_NothingNewToRecord") or "Nothing new to record"
    elseif #recordedItems == 0 then
        message = getText("UI_BurdJournals_ProgressSaved") or "Progress saved!"
    elseif #recordedItems == 1 then
        message = string.format(getText("UI_BurdJournals_RecordedItem") or "Recorded %s", recordedItems[1])
    elseif #recordedItems <= 3 then
        message = string.format(getText("UI_BurdJournals_RecordedItems") or "Recorded %s", table.concat(recordedItems, ", "))
    else

        message = string.format(getText("UI_BurdJournals_RecordedItemsMore") or "Recorded %s, %s +%d more", recordedItems[1], recordedItems[2], #recordedItems - 2)
    end

    BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.XP_GAIN)

    local journalId = args.newJournalId or args.journalId
    BurdJournals.debugPrint("[BurdJournals] Client: handleRecordSuccess - journalId=" .. tostring(journalId) .. ", has journalData=" .. tostring(args.journalData ~= nil))
    if journalId and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Applying journal data from server for ID " .. tostring(journalId))

        if args.journalData.recipes then
            local recipeCount = 0
            for _ in pairs(args.journalData.recipes) do recipeCount = recipeCount + 1 end
            BurdJournals.debugPrint("[BurdJournals] Client: Server journalData contains " .. recipeCount .. " recipes")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Server journalData has NO recipes table")
        end
        local journal = BurdJournals.findItemById(player, journalId)
        if journal then
            local modData = journal:getModData()
            modData.BurdJournals = args.journalData
            BurdJournals.debugPrint("[BurdJournals] Client: Journal data applied successfully to found journal")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Could not find journal by ID to apply data")
        end
    elseif journalId and not args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: WARNING - No journalData in server response (journal too large?)")
        if args.needsSync then
            BurdJournals.Client.requestJournalSync(journalId, "recordSuccessNeedsSync")
        end
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        local panelJournalId = panel.journal and panel.journal:getID() or nil
        BurdJournals.debugPrint("[BurdJournals] Client: Panel exists, panel.journal ID=" .. tostring(panelJournalId) .. ", server journalId=" .. tostring(journalId))

        if args.newJournalId then
            BurdJournals.debugPrint("[BurdJournals] Client: Looking for new journal ID " .. tostring(args.newJournalId))
            local newJournal = BurdJournals.findItemById(player, args.newJournalId)
            if newJournal then
                BurdJournals.debugPrint("[BurdJournals] Client: Found new journal, updating panel reference")
                panel.journal = newJournal
                panel.pendingNewJournalId = nil

                if args.journalData then
                    local panelModData = panel.journal:getModData()
                    panelModData.BurdJournals = args.journalData
                    BurdJournals.debugPrint("[BurdJournals] Client: Applied journalData to new panel.journal")
                end
            else
                BurdJournals.debugPrint("[BurdJournals] Client: New journal NOT found in inventory yet!")

                panel.pendingNewJournalId = args.newJournalId
            end
        elseif journalId and panel.journal and panel.journal:getID() == journalId then

            if args.journalData then
                local panelModData = panel.journal:getModData()
                panelModData.BurdJournals = args.journalData
                BurdJournals.debugPrint("[BurdJournals] Client: Applied journalData to existing panel.journal (IDs match)")
            else
                BurdJournals.debugPrint("[BurdJournals] Client: IDs match but no journalData to apply")
            end
        else
            BurdJournals.debugPrint("[BurdJournals] Client: WARNING - Journal ID mismatch or missing! Panel has " .. tostring(panelJournalId) .. ", server sent " .. tostring(journalId))

            if journalId and args.journalData then
                local serverJournal = BurdJournals.findItemById(player, journalId)
                if serverJournal then
                    BurdJournals.debugPrint("[BurdJournals] Client: Found server's journal, updating panel reference")
                    panel.journal = serverJournal
                    local panelModData = panel.journal:getModData()
                    panelModData.BurdJournals = args.journalData
                end
            end
        end

        if panel.showFeedback then
            panel:showFeedback(message, {r=0.5, g=0.8, b=0.6})
        end

        if args.journalData then

            BurdJournals.debugPrint("[BurdJournals] Client: Calling populateRecordList with server journalData (skipping refreshJournalData)")
            if panel.populateRecordList then
                local normalized = BurdJournals.normalizeJournalData(args.journalData) or args.journalData
                panel:populateRecordList(normalized)
            end
        else

            BurdJournals.debugPrint("[BurdJournals] Client: No server journalData, delaying refresh for modData sync")
            local ticksWaited = 0
            local maxWaitTicks = 5
            local delayedRefresh
            delayedRefresh = function()
                ticksWaited = ticksWaited + 1
                if ticksWaited >= maxWaitTicks then
                    Events.OnTick.Remove(delayedRefresh)

                    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
                        local currentPanel = BurdJournals.UI.MainPanel.instance
                        if currentPanel.refreshJournalData then
                            BurdJournals.debugPrint("[BurdJournals] Client: Executing delayed refreshJournalData")
                            currentPanel:refreshJournalData()
                        end
                    end
                end
            end
            Events.OnTick.Add(delayedRefresh)
        end
    else
        BurdJournals.debugPrint("[BurdJournals] Client: No UI panel instance to update")
    end
end

function BurdJournals.Client.handleSyncSuccess(player, args)
    BurdJournals.debugPrint("[BurdJournals] Client: handleSyncSuccess received, journalId=" .. tostring(args and args.journalId))
    
    if not args then return end
    
    local journalId = args.journalId

    if journalId then
        applyServerJournalUpdate(player, journalId, args, "syncSuccess")
        if args.needsSync and not args.journalData then
            BurdJournals.debugPrint("[BurdJournals] Client: syncSuccess flagged needsSync without full payload for journalId=" .. tostring(journalId))
        end
    end
    
    -- Update the UI panel if it exists
    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        BurdJournals.debugPrint("[BurdJournals] Client: Sync - Refreshing UI panel")

        -- Refresh the UI
        if panel.refreshJournalData then
            panel:refreshJournalData()
        end
    end
end

function BurdJournals.Client.handleApplyXP(player, args)
    if not args or not args.skills then
        return
    end

    local mode = args.mode or "set"
    local totalXPGained = 0
    local skillsApplied = 0

    for skillName, data in pairs(args.skills) do

        local perk = BurdJournals.getPerkByName(skillName)

        if perk then
            local xpToApply = data.xp or 0
            local skillMode = data.mode or mode

            local beforeXP = player:getXp():getXP(perk)

            if skillMode == "add" then
                -- Use AddXP with useMultipliers=false since server already calculated the exact XP
                if sendAddXp then
                    sendAddXp(player, perk, xpToApply, false)
                    skillsApplied = skillsApplied + 1
                    totalXPGained = totalXPGained + xpToApply
                    BurdJournals.debugPrint("[BurdJournals] Applied +" .. tostring(xpToApply) .. " XP to " .. tostring(skillName))
                else
                    -- Fallback: use AddXP with no multipliers
                    player:getXp():AddXP(perk, xpToApply, true, false, false, false)
                    local afterXP = player:getXp():getXP(perk)
                    totalXPGained = totalXPGained + (afterXP - beforeXP)
                    skillsApplied = skillsApplied + 1
                    BurdJournals.debugPrint("[BurdJournals] Fallback: Applied XP to " .. tostring(skillName))
                end
            else
                -- Set mode - calculate difference
                if xpToApply > beforeXP then
                    local xpDiff = xpToApply - beforeXP
                    if sendAddXp then
                        sendAddXp(player, perk, xpDiff, false)
                        BurdJournals.debugPrint("[BurdJournals] Set " .. tostring(skillName) .. " to " .. tostring(xpToApply) .. " (added " .. tostring(xpDiff) .. ")")
                    else
                        player:getXp():AddXP(perk, xpDiff, true, false, false, false)
                    end
                    totalXPGained = totalXPGained + xpDiff
                    skillsApplied = skillsApplied + 1
                end
            end
        end
    end

    if skillsApplied > 0 then

    end
end

function BurdJournals.Client.handleAbsorbSuccess(player, args)
    if not args then return end

    BurdJournals.debugPrint("[BurdJournals] Client: handleAbsorbSuccess received, journalId=" .. tostring(args.journalId))

    if args.skillName and args.xpGained then
        local displayName = BurdJournals.getPerkDisplayName(args.skillName)
        local xpGained = args.xpGained or 0

        -- DEBUG: Print what the server sent back
        BurdJournals.debugPrint("[BurdJournals] Client: SERVER RETURNED xpGained=" .. tostring(xpGained) .. " for skill=" .. tostring(args.skillName))
        BurdJournals.debugPrint("[BurdJournals] Client: SERVER DEBUG - baseXP=" .. tostring(args.debug_baseXP) .. ", journalMult=" .. tostring(args.debug_journalMult) .. ", bookMult=" .. tostring(args.debug_bookMult) .. ", receivedMult=" .. tostring(args.debug_receivedMult))

        local message = "+" .. BurdJournals.formatXP(xpGained) .. " " .. displayName
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.XP_GAIN)

    elseif args.traitId then
        local traitName = BurdJournals.getTraitDisplayName(args.traitId)
        local message = string.format(getText("UI_BurdJournals_LearnedTrait") or "Learned: %s", traitName)
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.TRAIT_GAIN)

        if BurdJournals.safeAddTrait and shouldApplyTraitsLocally() then
            BurdJournals.safeAddTrait(player, args.traitId)
        end

        -- Mirror skill behavior: mark trait claimed in-session immediately so UI doesn't
        -- flicker back to claimable before player trait sync/journal sync is visible.
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(args.traitId) or args.traitId
            local traitSessionKey = string.lower(tostring(normalizedTraitId or args.traitId))
            if not panel.sessionClaimedTraits then panel.sessionClaimedTraits = {} end
            panel.sessionClaimedTraits[args.traitId] = true
            panel.sessionClaimedTraits[traitSessionKey] = true
            if panel.pendingClaims and panel.pendingClaims.traits then
                panel.pendingClaims.traits[args.traitId] = nil
                panel.pendingClaims.traits[traitSessionKey] = nil
            end
        end
    elseif args.recipeName then
        local displayName = BurdJournals.getRecipeDisplayName(args.recipeName)
        local message = "+" .. displayName
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.RECIPE_GAIN)

        if player and player.learnRecipe then
            player:learnRecipe(args.recipeName)
            BurdJournals.debugPrint("[BurdJournals] Client: Learned recipe '" .. args.recipeName .. "' on absorb")
        end
    end

    if args.journalId then
        local applied = applyServerJournalUpdate(player, args.journalId, args, "absorbSuccess")
        if not applied and not args.journalData and not args.runtimeDelta then
            -- Legacy fallback for older servers that don't send data/deltas.
            local journal = BurdJournals.findItemById(player, args.journalId)
            if journal then
                if args.skillName then
                    BurdJournals.claimSkill(journal, args.skillName)
                end
                if args.traitId then
                    BurdJournals.claimTrait(journal, args.traitId)
                end
                if args.recipeName then
                    BurdJournals.claimRecipe(journal, args.recipeName)
                end
            end
        end
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance

        local panelJournalId = panel.journal and panel.journal:getID() or "nil"
        BurdJournals.debugPrint("[BurdJournals] Client: UI panel journal ID = " .. tostring(panelJournalId) .. ", server response journalId = " .. tostring(args.journalId))

        if panel.journal then
            local panelModData = panel.journal:getModData()
            local panelClaimed = panelModData.BurdJournals and panelModData.BurdJournals.claimedSkills or {}
            BurdJournals.debugPrint("[BurdJournals] Client: Panel's journal claimedSkills count = " .. tostring(BurdJournals.countTable(panelClaimed)))
        end

        -- Skip UI refresh if batch processing is still active
        if panel.isProcessingRewards then
            BurdJournals.debugPrint("[BurdJournals] Client: Skipping UI refresh for absorbSuccess (batch processing active)")
        else
            panel:refreshAbsorptionList()
        end
    end

    -- Handle dissolution flag (sent by server when journal should dissolve after batch processing)
    if args.dissolved then
        local message = args.dissolutionMessage or BurdJournals.getRandomDissolutionMessage()
        
        if player and player.Say then
            player:Say(message)
        end

        if player and player.getEmitter then
            local emitter = player:getEmitter()
            if emitter and emitter.playSound then
                emitter:playSound("PaperRip")
            end
        end
        
        -- Remove the journal locally
        if args.journalId then
            local journal = BurdJournals.findItemById(player, args.journalId)
            if journal then
                local container = journal:getContainer()
                if container then
                    container:Remove(journal)
                end
                player:getInventory():Remove(journal)
            end
        end
        
        -- Close the panel
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            BurdJournals.UI.MainPanel.instance:onClose()
        end
    end
end

function BurdJournals.Client.handleClaimSuccess(player, args)
    if not args then return end

    BurdJournals.debugPrint("[BurdJournals] Client: handleClaimSuccess received, journalId=" .. tostring(args.journalId))

    -- Handle skill XP claims
    local xpAmount = args.xpAdded or args.xpGained  -- Support both field names
    if args.skillName and xpAmount then
        local displayName = BurdJournals.getPerkDisplayName(args.skillName)
        local message = string.format(getText("UI_BurdJournals_ClaimedSkill") or "Claimed: %s (+%s XP)", displayName, BurdJournals.formatXP(xpAmount))
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.XP_GAIN)
        
        -- Debug logging: show server response details
        if args.debug_recordedLevel or args.debug_targetLevel then
            BurdJournals.debugPrint("================================================================================")
            BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT] Skill: " .. tostring(args.skillName))
            if args.debug_recordedLevel then
                BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT]   Server reported recorded level: " .. tostring(args.debug_recordedLevel))
            end
            if args.debug_targetLevel then
                BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT]   Server target level: " .. tostring(args.debug_targetLevel))
            end
            if args.debug_levelAfter then
                BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT]   Server says player now at level: " .. tostring(args.debug_levelAfter))
            end
            if args.debug_xpAfter then
                BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT]   Server says player now has XP: " .. tostring(args.debug_xpAfter))
            end
            -- Also check client-side current state
            local perk = BurdJournals.getPerkByName(args.skillName)
            if perk then
                local clientLevel = player:getPerkLevel(perk)
                local clientXP = player:getXp():getXP(perk)
                BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT]   Client sees player at level: " .. tostring(clientLevel) .. ", XP: " .. tostring(clientXP))
                if args.debug_levelAfter and clientLevel ~= args.debug_levelAfter then
                    BurdJournals.debugPrint("[BurdJournals CLIENT CLAIM RESULT]   NOTE: Client level differs from server (sync pending)")
                end
            end
            BurdJournals.debugPrint("================================================================================")
        end
        
        -- Track this skill as successfully claimed in this session
        -- This helps the UI show "already at level" immediately without waiting for XP sync
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if not panel.sessionClaimedSkills then panel.sessionClaimedSkills = {} end
            panel.sessionClaimedSkills[args.skillName] = true
        end

    elseif args.traitId then
        local traitName = BurdJournals.getTraitDisplayName(args.traitId)
        local message = string.format(getText("UI_BurdJournals_LearnedTrait") or "Learned: %s", traitName)
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.TRAIT_GAIN)

        if BurdJournals.safeAddTrait and shouldApplyTraitsLocally() then
            BurdJournals.safeAddTrait(player, args.traitId)
        end
        BurdJournals.Client.handleCancelledTraits(player, args.cancelledTraits)

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(args.traitId) or args.traitId
            local traitSessionKey = string.lower(tostring(normalizedTraitId or args.traitId))
            if not panel.sessionClaimedTraits then panel.sessionClaimedTraits = {} end
            panel.sessionClaimedTraits[args.traitId] = true
            panel.sessionClaimedTraits[traitSessionKey] = true
            if panel.pendingClaims and panel.pendingClaims.traits then
                panel.pendingClaims.traits[args.traitId] = nil
                panel.pendingClaims.traits[traitSessionKey] = nil
            end
        end
    elseif args.recipeName then
        local displayName = BurdJournals.getRecipeDisplayName(args.recipeName)
        local message = "+" .. displayName
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.RECIPE_GAIN)

        if player and player.learnRecipe then
            player:learnRecipe(args.recipeName)
            BurdJournals.debugPrint("[BurdJournals] Client: Learned recipe '" .. args.recipeName .. "' on client")
        end

    elseif args.statId then
        -- Handle stat absorption (zombie kills, hours survived, etc.)
        local statName = BurdJournals.getStatDisplayName and BurdJournals.getStatDisplayName(args.statId) or args.statId
        local value = args.value or 0
        local message = string.format(getText("UI_BurdJournals_StatClaimed") or "%s claimed!", statName)
        BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.XP_GAIN)

        -- Apply the stat to the player on the client side
        if BurdJournals.applyStatAbsorption then
            local applied = BurdJournals.applyStatAbsorption(player, args.statId, value)
            if applied then
                BurdJournals.debugPrint("[BurdJournals] Client: Applied stat '" .. args.statId .. "' = " .. tostring(value))
            else
                BurdJournals.debugPrint("[BurdJournals] Client: Failed to apply stat '" .. args.statId .. "'")
            end
        end
    end

    if args.journalId then
        local applied = applyServerJournalUpdate(player, args.journalId, args, "claimSuccess")
        if not applied and not args.journalData and not args.runtimeDelta then
            BurdJournals.debugPrint("[BurdJournals] Client: claimSuccess had no journal payload and no runtime delta")
        end

        if type(args.journalData) == "table"
            and args.journalData.isDebugSpawned
            and BurdJournals.UI
            and BurdJournals.UI.DebugPanel
            and BurdJournals.UI.DebugPanel.backupJournalToGlobalCache then
            local backupJournal = BurdJournals.findItemById(player, args.journalId)
            if (not backupJournal)
                and BurdJournals.UI.MainPanel
                and BurdJournals.UI.MainPanel.instance
                and BurdJournals.UI.MainPanel.instance.journal
                and journalIdsMatch(BurdJournals.UI.MainPanel.instance.journal:getID(), args.journalId) then
                backupJournal = BurdJournals.UI.MainPanel.instance.journal
            end
            if backupJournal then
                BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(backupJournal)
            end
        end
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance

        -- Clear this skill from pending claims so UI shows updated state
        if args.skillName and panel.pendingClaims and panel.pendingClaims.skills then
            panel.pendingClaims.skills[args.skillName] = nil
        end
        if args.traitId and panel.pendingClaims and panel.pendingClaims.traits then
            local normalizedTraitId = BurdJournals.normalizeTraitId and BurdJournals.normalizeTraitId(args.traitId) or args.traitId
            local traitSessionKey = string.lower(tostring(normalizedTraitId or args.traitId))
            panel.pendingClaims.traits[args.traitId] = nil
            panel.pendingClaims.traits[traitSessionKey] = nil
        end

        -- Skip UI refresh if batch processing is still active - the processor will refresh when done
        -- This prevents the refresh from interfering with the batch processor's state
        if panel.isProcessingRewards then
            BurdJournals.debugPrint("[BurdJournals] Client: Skipping UI refresh for claimSuccess (batch processing active)")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Refreshing UI for claimSuccess")
            if panel.refreshJournalData then
                panel:refreshJournalData()
            elseif panel.refreshAbsorptionList then
                panel:refreshAbsorptionList()
            end
        end
    end
end

function BurdJournals.Client.handleForgetSlotClaimed(player, args)
    if not args or not args.traitId then return end

    local traitName = BurdJournals.getTraitDisplayName and BurdJournals.getTraitDisplayName(args.traitId) or tostring(args.traitId)
    local message = string.format(getText("UI_BurdJournals_ForgetSlotClaimed") or "Forgot trait: %s", traitName)
    BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)

    if BurdJournals.safeRemoveTrait and shouldApplyTraitsLocally() then
        BurdJournals.safeRemoveTrait(player, args.traitId)
    end

    if args.journalId then
        applyServerJournalUpdate(player, args.journalId, args, "forgetSlotClaimed")
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        if panel.refreshJournalData then
            panel:refreshJournalData()
        elseif panel.refreshAbsorptionList then
            panel:refreshAbsorptionList()
        end
    end
end

function BurdJournals.Client.handleEraseSuccess(player, args)
    if not args then return end

    BurdJournals.debugPrint("[BurdJournals] Client: handleEraseSuccess received, journalId=" .. tostring(args.journalId) .. ", entryType=" .. tostring(args.entryType) .. ", entryName=" .. tostring(args.entryName))

    -- Show the halo message
    BurdJournals.Client.showHaloMessage(player, getText("UI_BurdJournals_JournalErased") or "Entry erased", BurdJournals.Client.HaloColors.INFO)

    local panelUpdated = false

    -- Apply updated journal data from server
    if args.journalId and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Applying journal data from server for eraseSuccess")
        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            local modData = journal:getModData()
            modData.BurdJournals = args.journalData
            BurdJournals.debugPrint("[BurdJournals] Client: Journal data applied successfully for eraseSuccess")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Could not find journal to apply eraseSuccess data")
        end

        -- Also update the panel's journal if it matches (compare as strings to handle Java Long types)
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal then
                local panelJournalId = tostring(panel.journal:getID())
                local argsJournalId = tostring(args.journalId)
                BurdJournals.debugPrint("[BurdJournals] Client: Comparing panel journal ID '" .. panelJournalId .. "' with args ID '" .. argsJournalId .. "'")
                if panelJournalId == argsJournalId then
                    local panelModData = panel.journal:getModData()
                    BurdJournals.debugPrint("[BurdJournals] Client: Updating panel.journal modData directly for eraseSuccess")
                    panelModData.BurdJournals = args.journalData
                    panelUpdated = true
                    
                    -- Remove from erase queue if panel has the method
                    if args.entryName and panel.removeFromEraseQueue then
                        panel:removeFromEraseQueue(args.entryName)
                    end
                end
            end
        end
    end

    -- Refresh the UI to reflect the erased entry
    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance

        BurdJournals.debugPrint("[BurdJournals] Client: Refreshing UI for eraseSuccess (panelUpdated=" .. tostring(panelUpdated) .. ")")
        
        -- If panel wasn't updated but we have journal data, try updating the panel's journal directly
        -- (This handles the edge case where the item reference might differ but it's the same journal)
        if not panelUpdated and args.journalData and panel.journal then
            local panelModData = panel.journal:getModData()
            panelModData.BurdJournals = args.journalData
            BurdJournals.debugPrint("[BurdJournals] Client: Force-updated panel.journal modData as fallback")
        end
        
        if panel.refreshCurrentList then
            panel:refreshCurrentList()
        elseif panel.refreshJournalData then
            panel:refreshJournalData()
        end
    end
end

function BurdJournals.Client.handleJournalDissolved(player, args)
    -- Debug info from skill absorption before dissolution
    if args and args.skillName and args.xpGained then
        BurdJournals.debugPrint("[BurdJournals] Client: DISSOLVED - SERVER RETURNED xpGained=" .. tostring(args.xpGained) .. " for skill=" .. tostring(args.skillName))
        BurdJournals.debugPrint("[BurdJournals] Client: DISSOLVED - SERVER DEBUG - baseXP=" .. tostring(args.debug_baseXP) .. ", journalMult=" .. tostring(args.debug_journalMult) .. ", bookMult=" .. tostring(args.debug_bookMult) .. ", receivedMult=" .. tostring(args.debug_receivedMult))
    end

    local message = args and args.message or BurdJournals.getRandomDissolutionMessage()

    if player and player.Say then
        player:Say(message)
    end

    if player and player.getEmitter then
        local emitter = player:getEmitter()
        if emitter and emitter.playSound then
            emitter:playSound("PaperRip")
        end
    end

    if args and args.journalId then
        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then

            local container = journal:getContainer()
            if container then
                container:Remove(journal)
            end
            player:getInventory():Remove(journal)
        end
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        BurdJournals.UI.MainPanel.instance:onClose()
    end

end

function BurdJournals.Client.handleRemoveJournal(player, args)

    if not args or not args.journalUUID then

        return
    end

    local journalUUID = args.journalUUID

    local journal = BurdJournals.findJournalByUUID(player, journalUUID)
    if journal then

        player:getInventory():Remove(journal)

    else
    end
end

function BurdJournals.Client.handleCancelledTraits(player, cancelledTraits)
    if type(cancelledTraits) ~= "table" then return end

    local applyLocally = shouldApplyTraitsLocally()
    for _, cancelledId in ipairs(cancelledTraits) do
        if cancelledId then
            if applyLocally and BurdJournals.safeRemoveTrait then
                BurdJournals.safeRemoveTrait(player, cancelledId)
            end
            local cancelledName = BurdJournals.getTraitDisplayName and BurdJournals.getTraitDisplayName(cancelledId) or tostring(cancelledId)
            local message = string.format(getText("UI_BurdJournals_TraitCancelled") or "Cancelled conflicting trait: %s", cancelledName)
            BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.ERROR)
        end
    end
end

function BurdJournals.Client.handleGrantTrait(player, args)
    if not args or not args.traitId then return end

    local traitId = args.traitId

    local traitName = BurdJournals.getTraitDisplayName(traitId)
    if BurdJournals.safeAddTrait and shouldApplyTraitsLocally() then
        local added = BurdJournals.safeAddTrait(player, traitId)
        if not added then
            BurdJournals.debugPrint("[BurdJournals] Client: Failed to grant trait '" .. tostring(traitId) .. "'")
        end
    end
    BurdJournals.Client.handleCancelledTraits(player, args and args.cancelledTraits)

    local message = string.format(getText("UI_BurdJournals_LearnedTrait") or "Learned: %s", traitName)
    BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.TRAIT_GAIN)

    if args.journalId and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Applying journal data from server for grantTrait")
        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            local modData = journal:getModData()
            modData.BurdJournals = args.journalData
            BurdJournals.debugPrint("[BurdJournals] Client: Journal data applied successfully for grantTrait")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Could not find journal to apply grantTrait data")
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelModData = panel.journal:getModData()
                BurdJournals.debugPrint("[BurdJournals] Client: Also updating panel.journal modData directly for grantTrait")
                panelModData.BurdJournals = args.journalData
            end
        end
    elseif args.journalId then

        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            local data = BurdJournals.getJournalData and BurdJournals.getJournalData(journal)
            if data then
                BurdJournals.markTraitClaimedByCharacter(data, player, traitId)
            else
                BurdJournals.claimTrait(journal, traitId)
            end
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelData = BurdJournals.getJournalData and BurdJournals.getJournalData(panel.journal)
                if panelData then
                    BurdJournals.markTraitClaimedByCharacter(panelData, player, traitId)
                else
                    BurdJournals.claimTrait(panel.journal, traitId)
                end
            end
        end
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        BurdJournals.UI.MainPanel.instance:refreshAbsorptionList()
    end
end

function BurdJournals.Client.handleTraitAlreadyKnown(player, args)
    if not args or not args.traitId then return end

    local traitId = args.traitId

    local traitName = BurdJournals.getTraitDisplayName(traitId)

    player:Say(string.format(getText("UI_BurdJournals_AlreadyKnowTrait") or "Already know: %s", traitName))

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        BurdJournals.UI.MainPanel.instance:refreshAbsorptionList()
    end
end

function BurdJournals.Client.handleSkillMaxed(player, args)
    if not args or not args.skillName then return end

    local skillName = args.skillName
    local displayName = BurdJournals.getPerkDisplayName(skillName)

    -- Show "already at level" message
    local message = args.alreadyAtLevel 
        and string.format(getText("UI_BurdJournals_AlreadyAtLevel") or "Already at level: %s", displayName)
        or string.format(getText("UI_BurdJournals_SkillAlreadyMaxedMsg") or "%s is already maxed!", displayName)
    player:Say(message)

    if args.journalId then
        applyServerJournalUpdate(player, args.journalId, args, "skillMaxed")
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        
        -- Clear this skill from pending claims
        if panel.pendingClaims and panel.pendingClaims.skills then
            panel.pendingClaims.skills[skillName] = nil
        end
        
        -- Refresh appropriate list
        if panel.isPlayerJournal or panel.mode == "view" then
            if panel.refreshJournalData then
                panel:refreshJournalData()
            end
        else
            panel:refreshAbsorptionList()
        end
    end
end

function BurdJournals.Client.handleRecipeAlreadyKnown(player, args)
    if not args or not args.recipeName then return end

    local recipeName = args.recipeName
    local displayName = BurdJournals.getRecipeDisplayName(recipeName)

    player:Say(string.format(getText("UI_BurdJournals_AlreadyKnowRecipe") or "Already know: %s", displayName))

    if args.journalId and args.journalData then
        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            local modData = journal:getModData()
            modData.BurdJournals = args.journalData
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelModData = panel.journal:getModData()
                panelModData.BurdJournals = args.journalData
            end
        end
    end

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        if panel.refreshJournalData then
            panel:refreshJournalData()
        elseif panel.refreshAbsorptionList then
            panel:refreshAbsorptionList()
        end
    end
end

function BurdJournals.Client.calculateProfessionBaseline(player)
    if not player then return {}, {} end

    local skillBaseline = {}
    local traitBaseline = {}

    -- Track level ADJUSTMENTS (can be positive or negative)
    local levelAdjustments = {}
    
    -- Passive skill traits that are automatically granted/removed based on skill levels
    -- These should NOT be included in baseline calculation because they're earned through gameplay
    -- Reference: Fitness/Strength threshold traits in Project Zomboid
    local PASSIVE_SKILL_TRAITS = {
        -- Fitness-based traits (granted at certain fitness levels)
        -- CharacterTrait IDs confirmed from character_traits.txt
        ["athletic"] = true,
        ["fit"] = true,
        ["unfit"] = true,
        ["out of shape"] = true,  -- NOTE: game ID has a space (base:"out of shape")
        -- Strength-based traits
        ["strong"] = true,
        ["stout"] = true,
        ["weak"] = true,
        ["feeble"] = true,
        -- Weight-based traits (dynamically applied, can change during gameplay)
        ["overweight"] = true,
        ["obese"] = true,
        ["underweight"] = true,
        ["very underweight"] = true,  -- NOTE: game ID has a space (base:"very underweight")
        ["emaciated"] = true,
        ["weightgain"] = true,
        ["weightloss"] = true,
    }

    local desc = player:getDescriptor()
    if not desc then
        BurdJournals.debugPrint("[BurdJournals] calculateProfessionBaseline: No descriptor found!")
        return skillBaseline, traitBaseline
    end

    local playerProfessionID = desc:getCharacterProfession()
    BurdJournals.debugPrint("[BurdJournals] calculateProfessionBaseline: profession=" .. tostring(playerProfessionID))

    if playerProfessionID and CharacterProfessionDefinition then
        local profDef = CharacterProfessionDefinition.getCharacterProfessionDefinition(playerProfessionID)
        if profDef then

            local profXpBoost = transformIntoKahluaTable(profDef:getXpBoosts())
            if profXpBoost then
                for perk, level in pairs(profXpBoost) do

                    local perkId = tostring(perk)
                    local levelNum = tonumber(tostring(level))
                    if levelNum and levelNum ~= 0 then
                        levelAdjustments[perkId] = (levelAdjustments[perkId] or 0) + levelNum
                        BurdJournals.debugPrint("[BurdJournals] Profession grants " .. perkId .. " " .. (levelNum > 0 and "+" or "") .. levelNum .. " levels")
                    end
                end
            end

            local grantedTraits = profDef:getGrantedTraits()
            if grantedTraits then
                for i = 0, grantedTraits:size() - 1 do
                    local traitName = tostring(grantedTraits:get(i))
                    traitBaseline[traitName] = true
                    BurdJournals.debugPrint("[BurdJournals] Profession grants trait: " .. traitName)
                end
            end
        end
    end

    local playerTraits = player:getCharacterTraits()
    if playerTraits and playerTraits.getKnownTraits then
        local knownTraits = playerTraits:getKnownTraits()
        for i = 0, knownTraits:size() - 1 do
            local traitTrait = knownTraits:get(i)
            local traitId = tostring(traitTrait)
            
            -- Normalize trait ID (remove "base:" prefix if present)
            local normalizedTraitId = string.gsub(traitId, "^base:", "")
            
            -- Skip passive skill traits (earned through gameplay, not character creation)
            if PASSIVE_SKILL_TRAITS[traitId] or PASSIVE_SKILL_TRAITS[normalizedTraitId] then
                BurdJournals.debugPrint("[BurdJournals] Skipping passive skill trait (earned during gameplay): " .. traitId)
            elseif CharacterTraitDefinition then
                local traitDef = CharacterTraitDefinition.getCharacterTraitDefinition(traitTrait)
                if traitDef then
                    -- Check if this trait's label matches any passive skill trait
                    local traitLabel = traitDef.getLabel and traitDef:getLabel() or nil
                    
                    if traitLabel and PASSIVE_SKILL_TRAITS[traitLabel] then
                        BurdJournals.debugPrint("[BurdJournals] Skipping passive skill trait by label: " .. tostring(traitLabel))
                    else
                        local traitXpBoost = transformIntoKahluaTable(traitDef:getXpBoosts())
                        local hasSkillBonus = false
                        if traitXpBoost then
                            for perk, level in pairs(traitXpBoost) do
                                local perkId = tostring(perk)
                                local levelNum = tonumber(tostring(level))
                                if levelNum and levelNum ~= 0 then
                                    levelAdjustments[perkId] = (levelAdjustments[perkId] or 0) + levelNum
                                    BurdJournals.debugPrint("[BurdJournals] Trait " .. traitId .. " grants " .. perkId .. " " .. (levelNum > 0 and "+" or "") .. levelNum .. " levels")
                                    hasSkillBonus = true
                                end
                            end
                        end

                        if hasSkillBonus then
                            traitBaseline[traitId] = true
                            BurdJournals.debugPrint("[BurdJournals] Trait marked as baseline (has skill bonus): " .. traitId)
                        end
                    end
                end
            end
        end
    end

    -- IMPORTANT: Fitness and Strength ALWAYS have Level 5 baseline in PZ
    -- Passive skill traits (Athletic, Strong, etc.) are dynamically granted/removed
    -- based on skill level - they're not true "starting" traits.
    -- NOTE: getTotalXpForLevel(N) returns XP to COMPLETE level N (enter N+1)
    -- So for entry to level N, we use getTotalXpForLevel(N-1)
    local BASE_PASSIVE_LEVEL = 5  -- PZ default starting level for Fitness/Strength
    local passiveSkills = { Fitness = true, Strength = true }

    -- Process non-passive skill adjustments from traits/profession
    for perkId, adjustment in pairs(levelAdjustments) do
        local perk = Perks[perkId]
        if perk then
            local skillName = BurdJournals.mapPerkIdToSkillName(perkId)
            if skillName then
                -- Skip passive skills - they always use Level 5 baseline
                if passiveSkills[skillName] then
                    BurdJournals.debugPrint("[BurdJournals] Skipping adjustment for passive skill: " .. skillName .. " (always Level 5 baseline)")
                else
                    -- Calculate final starting level for non-passive skills
                    local finalLevel = math.max(0, math.min(10, adjustment))

                    -- getTotalXpForLevel(N) returns threshold to BE at level N
                    -- For level 0, baseline is 0 XP
                    local xp = finalLevel > 0 and perk:getTotalXpForLevel(finalLevel) or 0
                    if xp and xp > 0 then
                        skillBaseline[skillName] = xp
                        BurdJournals.debugPrint("[BurdJournals] Baseline: " .. skillName .. " = " .. xp .. " XP (adj " .. adjustment .. " = Lv" .. finalLevel .. ")")
                    end
                end
            end
        else
            print("[BurdJournals] WARNING: Unknown perk ID: " .. perkId)
        end
    end

    -- Always set passive skills to Level 5 baseline (no adjustments applied)
    -- Use our verified PASSIVE_XP_THRESHOLDS table for accurate values
    for skillName, _ in pairs(passiveSkills) do
        -- Use verified passive skill threshold for level 5 (37500 XP)
        local xp = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[BASE_PASSIVE_LEVEL] or 37500
        skillBaseline[skillName] = xp
        BurdJournals.debugPrint("[BurdJournals] Baseline: " .. skillName .. " = " .. xp .. " XP (fixed Level 5 baseline, from verified thresholds)")
    end

    BurdJournals.debugPrint("[BurdJournals] Final skill baseline:")
    for skill, xp in pairs(skillBaseline) do
        BurdJournals.debugPrint("[BurdJournals]   " .. skill .. " = " .. xp .. " XP")
    end

    return skillBaseline, traitBaseline
end

-- Track if we've already logged certain messages this session to avoid spam
BurdJournals.Client._baselineLogFlags = BurdJournals.Client._baselineLogFlags or {}

function BurdJournals.Client.captureBaseline(player, isNewCharacter)
    if not player then return end

    local modData = player:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end

    -- Check if baseline was manually modified via debug - never overwrite these
    if modData.BurdJournals.debugModified then
        -- Ensure baselineCaptured is also set (debug-modified implies baseline exists)
        if not modData.BurdJournals.baselineCaptured then
            modData.BurdJournals.baselineCaptured = true
        end
        -- Only log once per session to avoid spam
        if not BurdJournals.Client._baselineLogFlags.debugModifiedLogged then
            BurdJournals.debugPrint("[BurdJournals] Baseline was debug-modified, preserving custom settings")
            BurdJournals.Client._baselineLogFlags.debugModifiedLogged = true
        end
        return
    end
    
    if modData.BurdJournals.baselineCaptured then
        local storedVersion = modData.BurdJournals.baselineVersion or 0
        if storedVersion >= BurdJournals.Client.BASELINE_VERSION then
            -- Only log once per session
            if not BurdJournals.Client._baselineLogFlags.alreadyCapturedLogged then
                BurdJournals.debugPrint("[BurdJournals] Baseline already captured (v" .. storedVersion .. "), skipping")
                BurdJournals.Client._baselineLogFlags.alreadyCapturedLogged = true
            end
            return
        else

            BurdJournals.debugPrint("[BurdJournals] Baseline version mismatch: stored v" .. storedVersion .. " vs current v" .. BurdJournals.Client.BASELINE_VERSION)
            if not isNewCharacter then
                -- Existing character with outdated baseline - update version flag
                -- Also clear recipe baseline to fix issue where recipes were incorrectly baselined
                -- (recipes should never be baselined for existing characters)
                BurdJournals.debugPrint("[BurdJournals] Existing character - updating version flag and clearing recipe baseline")
                modData.BurdJournals.baselineVersion = BurdJournals.Client.BASELINE_VERSION
                modData.BurdJournals.recipeBaseline = {}  -- Clear incorrectly captured recipe baseline
                modData.BurdJournals.mediaSkillBaseline = BurdJournals.getPlayerVhsSkillXPMapCopy and BurdJournals.getPlayerVhsSkillXPMapCopy(player) or {}
                if player.transmitModData
                    and BurdJournals.shouldPersistPlayerBaselineModData
                    and BurdJournals.shouldPersistPlayerBaselineModData() then
                    player:transmitModData()
                end
                return
            end

            BurdJournals.debugPrint("[BurdJournals] New character with outdated baseline - recalculating")
            modData.BurdJournals.baselineCaptured = false
            modData.BurdJournals.skillBaseline = nil
            modData.BurdJournals.traitBaseline = nil
            modData.BurdJournals.recipeBaseline = nil
            modData.BurdJournals.mediaSkillBaseline = nil
        end
    end

    isNewCharacter = isNewCharacter == true
    local hoursAlive = player.getHoursSurvived and player:getHoursSurvived() or 0
    local snapshotWindowHours = BurdJournals.getBaselineSnapshotMaxHours and BurdJournals.getBaselineSnapshotMaxHours() or 1
    if isNewCharacter and hoursAlive > snapshotWindowHours then
        BurdJournals.debugPrint("[BurdJournals] Baseline capture safety: character has " .. tostring(hoursAlive)
            .. " hours alive (> " .. tostring(snapshotWindowHours)
            .. "h snapshot window). Falling back to profession baseline.")
        isNewCharacter = false
    end

    if isNewCharacter then

        BurdJournals.debugPrint("[BurdJournals] Capturing baseline for NEW character (direct capture)")
        modData.BurdJournals.skillBaseline = {}
        local allowedSkills = BurdJournals.getAllowedSkills()
        for _, skillName in ipairs(allowedSkills) do
            local perk = BurdJournals.getPerkByName(skillName)
            if perk then
                local xp = player:getXp():getXP(perk)
                if xp > 0 then
                    modData.BurdJournals.skillBaseline[skillName] = xp
                end
            end
        end

        modData.BurdJournals.traitBaseline = {}
        local traits = BurdJournals.collectPlayerTraits(player, false)
        for traitId, _ in pairs(traits) do
            modData.BurdJournals.traitBaseline[traitId] = true
        end

        modData.BurdJournals.recipeBaseline = {}
        local recipes = BurdJournals.collectPlayerMagazineRecipes(player, false, true)
        for recipeName, _ in pairs(recipes) do
            modData.BurdJournals.recipeBaseline[recipeName] = true
        end
        modData.BurdJournals.mediaSkillBaseline = BurdJournals.getPlayerVhsSkillXPMapCopy and BurdJournals.getPlayerVhsSkillXPMapCopy(player) or {}
    else

        BurdJournals.debugPrint("[BurdJournals] Calculating baseline for EXISTING save (retroactive)")
        local calcSkills, calcTraits = BurdJournals.Client.calculateProfessionBaseline(player)
        modData.BurdJournals.skillBaseline = calcSkills
        modData.BurdJournals.traitBaseline = calcTraits

        modData.BurdJournals.recipeBaseline = {}
        modData.BurdJournals.mediaSkillBaseline = BurdJournals.getPlayerVhsSkillXPMapCopy and BurdJournals.getPlayerVhsSkillXPMapCopy(player) or {}
    end

    modData.BurdJournals.baselineCaptured = true
    modData.BurdJournals.baselineVersion = BurdJournals.Client.BASELINE_VERSION

    modData.BurdJournals.steamId = BurdJournals.getPlayerSteamId(player)
    modData.BurdJournals.characterId = BurdJournals.getPlayerCharacterId(player)

    local method = isNewCharacter and "direct capture" or "calculated from profession/traits"
    local recipeCount = BurdJournals.countTable(modData.BurdJournals.recipeBaseline or {})
    BurdJournals.debugPrint("[BurdJournals] Baseline captured (" .. method .. "): " ..
          tostring(BurdJournals.countTable(modData.BurdJournals.skillBaseline)) .. " skills, " ..
          tostring(BurdJournals.countTable(modData.BurdJournals.traitBaseline)) .. " traits, " ..
          tostring(recipeCount) .. " recipes")

    for skillName, xp in pairs(modData.BurdJournals.skillBaseline) do
        BurdJournals.debugPrint("[BurdJournals]   Baseline skill: " .. skillName .. " = " .. tostring(xp) .. " XP")
    end
    for traitId, _ in pairs(modData.BurdJournals.traitBaseline) do
        BurdJournals.debugPrint("[BurdJournals]   Baseline trait: " .. traitId)
    end
    for recipeName, _ in pairs(modData.BurdJournals.recipeBaseline or {}) do
        BurdJournals.debugPrint("[BurdJournals]   Baseline recipe: " .. recipeName)
    end

    if player.transmitModData
        and BurdJournals.shouldPersistPlayerBaselineModData
        and BurdJournals.shouldPersistPlayerBaselineModData() then
        player:transmitModData()
        BurdJournals.debugPrint("[BurdJournals] Player modData transmitted for persistence")
    end

    BurdJournals.Client.registerBaselineWithServer(player)
end

function BurdJournals.Client.forceRecalculateBaseline()
    local player = getPlayer()
    if not player then
        BurdJournals.debugPrint("[BurdJournals] No player found")
        return
    end

    local modData = player:getModData()
    if modData.BurdJournals then
        modData.BurdJournals.baselineCaptured = nil
        modData.BurdJournals.skillBaseline = nil
        modData.BurdJournals.traitBaseline = nil
        modData.BurdJournals.mediaSkillBaseline = nil
    end

    BurdJournals.debugPrint("[BurdJournals] Baseline cleared, recalculating...")
    BurdJournals.Client.captureBaseline(player, false)
    BurdJournals.debugPrint("[BurdJournals] Baseline recalculated from profession/traits")
end

BurdJournals.Client._awaitingServerBaseline = false

function BurdJournals.Client.requestServerBaseline()
    local player = getPlayer()
    if not player then return end

    BurdJournals.Client._awaitingServerBaseline = true
    BurdJournals.debugPrint("[BurdJournals] Requesting cached baseline from server...")

    sendClientCommand(player, "BurdJournals", "requestBaseline", {})
end

function BurdJournals.Client.registerBaselineWithServer(player)
    if not player then return end

    local modData = player:getModData()
    if not modData.BurdJournals or not modData.BurdJournals.baselineCaptured then
        BurdJournals.debugPrint("[BurdJournals] No baseline to register with server")
        return
    end

    local characterId = BurdJournals.getPlayerCharacterId(player)
    local steamId = BurdJournals.getPlayerSteamId(player)

    local descriptor = player:getDescriptor()
    local characterName = "Unknown"
    if descriptor then
        local forename = descriptor:getForename() or "Unknown"
        local surname = descriptor:getSurname() or ""
        characterName = forename .. " " .. surname
    end

    BurdJournals.debugPrint("[BurdJournals] Registering baseline with server for: " .. characterId)

    sendClientCommand(player, "BurdJournals", "registerBaseline", {
        characterId = characterId,
        steamId = steamId,
        characterName = characterName,
        baselineVersion = tonumber(modData.BurdJournals.baselineVersion) or BurdJournals.Client.BASELINE_VERSION
    })
end

function BurdJournals.Client.handleBaselineResponse(player, args)
    BurdJournals.Client._awaitingServerBaseline = false

    if not args then
        print("[BurdJournals] ERROR: No args in baselineResponse")
        return
    end

    if args.found then

        BurdJournals.debugPrint("[BurdJournals] Received cached baseline from server for: " .. tostring(args.characterId))
        BurdJournals.Client._baselineMissRetryCount = 0
        if BurdJournals.Client._baselineMissRetryHandlerId then
            BurdJournals.Client.unregisterTickHandler(BurdJournals.Client._baselineMissRetryHandlerId)
            BurdJournals.Client._baselineMissRetryHandlerId = nil
        end

        local modData = player:getModData()
        if not modData.BurdJournals then modData.BurdJournals = {} end

        modData.BurdJournals.skillBaseline = args.skillBaseline or {}
        modData.BurdJournals.mediaSkillBaseline = args.mediaSkillBaseline or {}
        modData.BurdJournals.traitBaseline = args.traitBaseline or {}
        modData.BurdJournals.recipeBaseline = args.recipeBaseline or {}
        modData.BurdJournals.baselineCaptured = true
        modData.BurdJournals.baselineVersion = BurdJournals.Client.BASELINE_VERSION
        modData.BurdJournals.fromServerCache = true
        modData.BurdJournals.debugModified = args.debugModified or false  -- Preserve debug flag from server

        local runtimeCharacterId = args.characterId
            or (BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player))
        if runtimeCharacterId and BurdJournals.Client.storeRuntimeBaseline then
            BurdJournals.Client.storeRuntimeBaseline(runtimeCharacterId, {
                characterId = runtimeCharacterId,
                skillBaseline = args.skillBaseline or {},
                mediaSkillBaseline = args.mediaSkillBaseline or {},
                traitBaseline = args.traitBaseline or {},
                recipeBaseline = args.recipeBaseline or {},
                debugModified = args.debugModified == true,
            })
        end

        BurdJournals.debugPrint("[BurdJournals] Applied server-cached baseline: " ..
              tostring(BurdJournals.countTable(modData.BurdJournals.skillBaseline)) .. " skills, " ..
              tostring(BurdJournals.countTable(modData.BurdJournals.traitBaseline)) .. " traits, " ..
              tostring(BurdJournals.countTable(modData.BurdJournals.recipeBaseline or {})) .. " recipes")

        for skillName, xp in pairs(modData.BurdJournals.skillBaseline) do
            BurdJournals.debugPrint("[BurdJournals]   Cached skill: " .. skillName .. " = " .. tostring(xp) .. " XP")
        end
        for traitId, _ in pairs(modData.BurdJournals.traitBaseline) do
            BurdJournals.debugPrint("[BurdJournals]   Cached trait: " .. traitId)
        end

        if player.transmitModData
            and BurdJournals.shouldPersistPlayerBaselineModData
            and BurdJournals.shouldPersistPlayerBaselineModData() then
            player:transmitModData()
        end

        BurdJournals.Client._pendingNewCharacterBaseline = false
    else

        BurdJournals.debugPrint("[BurdJournals] No cached baseline on server for: " .. tostring(args.characterId))

        local isPendingNewCharacterCapture = BurdJournals.Client._pendingNewCharacterBaseline == true
        if isPendingNewCharacterCapture then

            BurdJournals.debugPrint("[BurdJournals] New character without server cache - OnCreatePlayer will handle")
            local capturedNow = BurdJournals.Client.tryBootstrapPendingNewCharacterBaseline
                and BurdJournals.Client.tryBootstrapPendingNewCharacterBaseline(player, "server_cache_miss", false)
            if capturedNow then
                BurdJournals.debugPrint("[BurdJournals] New-character baseline captured immediately after server cache miss")
            end
        else

            BurdJournals.debugPrint("[BurdJournals] Existing character has no server cache (no pending new-character baseline capture)")
            local modData = player:getModData()
            local bj = modData and modData.BurdJournals or nil
            local hasLocalBaseline = false
            if bj and bj.baselineCaptured == true then
                hasLocalBaseline = (BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(bj.skillBaseline))
                    or (BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(bj.traitBaseline))
                    or (BurdJournals.hasAnyEntries and BurdJournals.hasAnyEntries(bj.mediaSkillBaseline))
            end

            if hasLocalBaseline then
                BurdJournals.debugPrint("[BurdJournals] Preserving existing local baseline after server cache miss")
            else
                BurdJournals.debugPrint("[BurdJournals] No local baseline available - disabling baseline restrictions until capture/recovery")
                if bj then
                    bj.baselineCaptured = false
                    bj.skillBaseline = nil
                    bj.traitBaseline = nil
                    bj.recipeBaseline = nil
                    bj.mediaSkillBaseline = nil
                end
                local pIndex = player and player.getPlayerNum and player:getPlayerNum() or nil
                if BurdJournals.Client.scheduleBaselineRetryAfterMiss then
                    BurdJournals.Client.scheduleBaselineRetryAfterMiss(pIndex, "server_cache_miss")
                end
            end
        end
    end
end

function BurdJournals.Client.handleBaselineRegistered(player, args)
    if not args then return end

    if args.skippedEstablished then
        BurdJournals.debugPrint("[BurdJournals] Baseline registration skipped for established character (" .. tostring(args.hoursAlive) .. "h alive)")
    elseif args.success then
        BurdJournals.debugPrint("[BurdJournals] Baseline successfully registered with server for: " .. tostring(args.characterId))
    elseif args.alreadyExisted then
        BurdJournals.debugPrint("[BurdJournals] Server already had baseline for: " .. tostring(args.characterId) .. " (ignored our registration)")
    else
        BurdJournals.debugPrint("[BurdJournals] Failed to register baseline with server")
    end
end

-- Handler for server-wide baseline clear (admin command response)
function BurdJournals.Client.handleAllBaselinesCleared(player, args)
    if not args then return end

    local clearedCount = args.clearedCount or 0
    local message = getText("UI_BurdJournals_AllBaselinesCleared") or "Server baseline cache cleared!"
    message = message .. " (" .. clearedCount .. " entries)"

    print("[BurdJournals] ADMIN: Server confirmed all baselines cleared - " .. clearedCount .. " entries removed")

    -- Show feedback to admin
    BurdJournals.Client.showHaloMessage(player, message, BurdJournals.Client.HaloColors.INFO)

    -- Update any open panel - refresh the list and show feedback
    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        -- Refresh the skill/trait/recipe list to reflect cleared baselines
        if panel.populateRecordList then
            panel:populateRecordList()
        end
        if panel.showFeedback then
            panel:showFeedback(message, {r=0.3, g=1, b=0.5})
        end
    end
end

-- Handler for debug journal backup response from server (for MP dedicated server restoration)
-- This allows restoring debug-edited journals when the client's local ModData cache was lost
function BurdJournals.Client.handleDebugJournalBackupResponse(player, args)
    if not args then return end

    local journalKey = args.journalKey
    if not journalKey then
        print("[BurdJournals] ERROR: No journalKey in debugJournalBackupResponse")
        return
    end

    if args.found and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Received debug journal backup from server for key=" .. tostring(journalKey))

        -- Store in local cache for future use
        local cache = ModData.getOrCreate("BurdJournals_DebugJournalCache")
        if not cache.journals then cache.journals = {} end
        cache.journals[journalKey] = args.journalData

        -- If there's a pending journal restoration, apply it now
        if BurdJournals.Client._pendingDebugJournalRestore then
            local pending = BurdJournals.Client._pendingDebugJournalRestore
            if pending.journalKey == journalKey and pending.journal then
                BurdJournals.debugPrint("[BurdJournals] Client: Applying pending restoration for journal key=" .. tostring(journalKey))
                if BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache then
                    BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache(pending.journal)
                end
            end
            BurdJournals.Client._pendingDebugJournalRestore = nil
        end

        -- Refresh Debug Panel if open
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus("Backup restored from server", {r=0.3, g=1, b=0.5})
            if BurdJournals.UI.DebugPanel.instance.refreshJournalEditorData then
                BurdJournals.UI.DebugPanel.instance:refreshJournalEditorData()
            end
        end
    else
        BurdJournals.debugPrint("[BurdJournals] Client: No debug journal backup found on server for key=" .. tostring(journalKey))
        BurdJournals.Client._pendingDebugJournalRestore = nil
    end
end

-- Request debug journal backup from server (for restoration on MP dedicated servers)
function BurdJournals.Client.requestDebugJournalBackup(journal, journalKey)
    if not journal or not journalKey then return end

    local player = getPlayer()
    if not player then return end

    -- Only request from server if we're on a client (MP)
    if isClient and isClient() then
        -- Store pending restoration info so we can apply when server responds
        BurdJournals.Client._pendingDebugJournalRestore = {
            journal = journal,
            journalKey = journalKey
        }

        sendClientCommand(player, "BurdJournals", "requestDebugJournalBackup", {
            journalKey = journalKey
        })
        BurdJournals.debugPrint("[BurdJournals] Client: Requested debug journal backup from server for key=" .. tostring(journalKey))
    end
end

function BurdJournals.Client.handleDebugJournalUUIDLookupResult(player, args)
    if not args then return end

    local panel = BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance or nil
    local uuid = tostring(args.uuid or "")

    if args.found and args.live then
        local journal = nil
        if args.journalId then
            journal = BurdJournals.findItemById(player, args.journalId)
        end
        if not journal and uuid ~= "" and BurdJournals.findJournalByUUID then
            journal = BurdJournals.findJournalByUUID(player, uuid)
        end

        if panel and panel.journalPanel and panel.journalPanel.journalUUIDEntry then
            panel.journalPanel.journalUUIDEntry:setText(uuid)
        end

        local pendingProxy = panel and panel.editingJournal or nil
        local shouldApplyProxyEdits = pendingProxy
            and pendingProxy.__bsjServerProxy == true
            and pendingProxy.__bsjDirty == true
            and tostring(pendingProxy.__bsjUUID or "") == uuid
            and pendingProxy.getModData
            and pendingProxy:getModData()
            and pendingProxy:getModData().BurdJournals
        local pendingProxyData = shouldApplyProxyEdits and pendingProxy:getModData().BurdJournals or nil

        if panel and journal then
            if shouldApplyProxyEdits and pendingProxyData and isClient and isClient() then
                sendClientCommand(player, "BurdJournals", "debugApplyJournalEdits", {
                    journalId = journal:getID(),
                    journalUUID = uuid,
                    journalKey = uuid,
                    journalData = pendingProxyData
                })
                pendingProxy.__bsjDirty = false
            end
            panel.editingJournal = journal
            if panel.refreshJournalEditorData then
                panel:refreshJournalEditorData()
            end
            if shouldApplyProxyEdits then
                panel:setStatus("UUID found; applied cached edits to live journal", {r=0.3, g=1, b=0.5})
            else
                panel:setStatus("UUID found and selected", {r=0.3, g=1, b=0.5})
            end
        elseif panel then
            local owner = tostring(args.ownerUsername or "Unknown")
            local indexEntry = args.indexEntry
            if type(indexEntry) ~= "table" then
                indexEntry = {
                    uuid = uuid,
                    itemId = args.journalId,
                    itemType = args.itemType,
                    itemName = args.itemName,
                    ownerUsername = args.ownerUsername,
                    ownerSteamId = args.ownerSteamId,
                    ownerCharacterName = args.ownerCharacterName,
                    isPlayerCreated = args.isPlayerCreated == true,
                    wasRestored = args.isRestored == true,
                    wasFromWorn = args.wasFromWorn == true,
                    wasFromBloody = args.wasFromBloody == true,
                    skillCount = args.skillCount,
                    traitCount = args.traitCount,
                    recipeCount = args.recipeCount,
                    statCount = args.statCount,
                }
            end

            local snapshotData = args.snapshotData or args.backupData
            local proxy = nil
            if BurdJournals.UI
                and BurdJournals.UI.DebugPanel
                and BurdJournals.UI.DebugPanel.createServerJournalProxy then
                proxy = BurdJournals.UI.DebugPanel.createServerJournalProxy(uuid, indexEntry, snapshotData)
            end

            local appliedRemoteEdits = false
            if shouldApplyProxyEdits and pendingProxyData and isClient and isClient() then
                sendClientCommand(player, "BurdJournals", "debugApplyJournalEdits", {
                    journalId = args.journalId,
                    journalUUID = uuid,
                    journalKey = uuid,
                    journalData = pendingProxyData
                })
                pendingProxy.__bsjDirty = false
                appliedRemoteEdits = true
            end

            if proxy then
                panel.editingJournal = proxy
                if panel.refreshJournalEditorData then
                    panel:refreshJournalEditorData()
                end
                if appliedRemoteEdits then
                    panel:setStatus("UUID found on server; loaded remote snapshot and applied cached edits.", {r=0.3, g=1, b=0.5})
                else
                    panel:setStatus("UUID found on server; loaded remote snapshot.", {r=0.95, g=0.8, b=0.35})
                end
            elseif appliedRemoteEdits then
                panel:setStatus("UUID found on server (owner " .. owner .. "). Cached edits applied remotely.", {r=0.3, g=1, b=0.5})
            else
                panel:setStatus("UUID found on server (owner " .. owner .. "). Move closer to edit.", {r=0.95, g=0.8, b=0.35})
            end
        end
    else
        if panel then
            local hasCached = args.hasIndex or args.hasBackup
            if hasCached and BurdJournals.UI
                and BurdJournals.UI.DebugPanel
                and BurdJournals.UI.DebugPanel.createServerJournalProxy then
                local proxy = BurdJournals.UI.DebugPanel.createServerJournalProxy(uuid, args.indexEntry, args.snapshotData or args.backupData)
                if proxy then
                    panel.editingJournal = proxy
                    if panel.journalPanel and panel.journalPanel.journalUUIDEntry then
                        panel.journalPanel.journalUUIDEntry:setText(uuid)
                    end
                    if panel.refreshJournalEditorData then
                        panel:refreshJournalEditorData()
                    end
                    panel:setStatus("Loaded cached server snapshot (no live item). Edits will sync when journal is live.", {r=0.95, g=0.8, b=0.35})
                    return
                end
            end

            panel:setStatus(args.message or "UUID not found", {r=1, g=0.6, b=0.3})
        end
    end

    if args.message then
        BurdJournals.debugPrint("[BurdJournals] UUID lookup: " .. tostring(args.message))
    end
end

function BurdJournals.Client.handleDebugJournalUUIDRepairResult(player, args)
    if not args then return end

    local panel = BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance or nil
    local ok = args.found == true
    local message = args.message or (ok and "UUID repair complete" or "UUID repair failed")

    if panel then
        panel:setStatus(message, ok and {r=0.3, g=1, b=0.5} or {r=1, g=0.6, b=0.3})
    end

    if ok and panel and args.journalId then
        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            panel.editingJournal = journal
            if panel.refreshJournalEditorData then
                panel:refreshJournalEditorData()
            end
        end
    end

    BurdJournals.debugPrint("[BurdJournals] UUID repair: " .. tostring(message))
end

function BurdJournals.Client.handleDebugJournalUUIDIndexList(player, args)
    if not args then return end
    local panel = BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance or nil
    if panel and panel.applyServerJournalIndexList then
        panel:applyServerJournalIndexList(args.entries, args)
    end
    BurdJournals.debugPrint("[BurdJournals] UUID index list received: count=" .. tostring(args.count or 0) .. ", total=" .. tostring(args.total or 0))
end

function BurdJournals.Client.handleDebugJournalUUIDDeleteResult(player, args)
    if not args then return end

    local panel = BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance or nil
    local message = args.message or "UUID delete processed"
    local ok = args.found == true

    if panel then
        if ok then
            panel.editingJournal = nil
            if panel.refreshJournalEditorData then
                panel:refreshJournalEditorData()
            end
            if panel.refreshJournalPickerList then
                panel:refreshJournalPickerList(true)
            end
            if panel.onJournalRefreshServerIndex then
                panel:onJournalRefreshServerIndex()
            end
        end
        panel:setStatus(message, ok and {r=0.3, g=1, b=0.5} or {r=1, g=0.6, b=0.3})
    end

    BurdJournals.debugPrint("[BurdJournals] UUID delete: " .. tostring(message))
end

function BurdJournals.Client.onCreatePlayer(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    if player then
        BurdJournals.Client._baselineMissRetryCount = 0
        if BurdJournals.Client._baselineMissRetryHandlerId then
            BurdJournals.Client.unregisterTickHandler(BurdJournals.Client._baselineMissRetryHandlerId)
            BurdJournals.Client._baselineMissRetryHandlerId = nil
        end

        local hoursAlive = player.getHoursSurvived and player:getHoursSurvived() or 0
        local snapshotWindowHours = BurdJournals.getBaselineSnapshotMaxHours
            and BurdJournals.getBaselineSnapshotMaxHours() or 1
        local isLikelyNewCharacter = BurdJournals.isWithinBaselineSnapshotWindow
            and BurdJournals.isWithinBaselineSnapshotWindow(player)
            or (hoursAlive <= snapshotWindowHours)

        if BurdJournals.getPlayerCharacterId then
            BurdJournals.Client._lastKnownCharacterId = BurdJournals.getPlayerCharacterId(player)
        end

        if not isLikelyNewCharacter then
            BurdJournals.Client._pendingNewCharacterBaseline = false
            BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: existing character (" .. tostring(hoursAlive) .. " hours), requesting server baseline without resetting local data")
            BurdJournals.Client.requestServerBaseline()
            return
        end

        local modData = player:getModData()
        if modData and not modData.BurdJournals then
            modData.BurdJournals = {}
        end

        local bj = modData and modData.BurdJournals or nil
        local hasLocalBaseline = hasBaselineCapturedLocal(player)
        local currentCharacterId = BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player) or nil
        local storedCharacterId = bj and bj.characterId or nil
        local hasCharacterMismatch = currentCharacterId and storedCharacterId
            and tostring(currentCharacterId) ~= tostring(storedCharacterId)
        local shouldForceClearStale = hasLocalBaseline and hasCharacterMismatch and hoursAlive <= 0.1

        if hasLocalBaseline and not shouldForceClearStale then
            BurdJournals.Client._pendingNewCharacterBaseline = false
            BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: within snapshot window but local baseline exists, preserving and requesting server baseline")
            BurdJournals.Client.requestServerBaseline()
            return
        end

        BurdJournals.Client._pendingNewCharacterBaseline = true
        BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: new character detected, requesting server baseline before capture")

        if shouldForceClearStale and bj then
            BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: clearing stale local baseline due character mismatch before fresh capture")
            bj.baselineCaptured = false
            bj.skillBaseline = nil
            bj.traitBaseline = nil
            bj.recipeBaseline = nil
            bj.mediaSkillBaseline = nil
            bj.baselineBypassed = nil
            bj.characterId = nil
            bj.steamId = nil
        elseif bj and not hasLocalBaseline then
            bj.baselineCaptured = false
            bj.skillBaseline = nil
            bj.traitBaseline = nil
            bj.recipeBaseline = nil
            bj.mediaSkillBaseline = nil
            -- Clear bypass flag on new character - baseline will be enforced normally
            bj.baselineBypassed = nil
        end

        BurdJournals.Client.requestServerBaseline()
        BurdJournals.Client.queueNewCharacterBaselineCapture(player, playerIndex, "OnCreatePlayer")
    end
end

function BurdJournals.Client.onPlayerDeath(player)

    BurdJournals.Client.cleanupAllTickHandlers()

    if BurdJournals.UI and BurdJournals.UI.MainPanel then

        BurdJournals.safeRemoveEvent(Events.OnTick, BurdJournals.UI.MainPanel.onLearningTickStatic)
        BurdJournals.safeRemoveEvent(Events.OnTick, BurdJournals.UI.MainPanel.onRecordingTickStatic)
        BurdJournals.safeRemoveEvent(Events.OnTick, BurdJournals.UI.MainPanel.onPendingJournalRetryStatic)

        if BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.setVisible then
                panel:setVisible(false)
            end
            if panel.removeFromUIManager then
                panel:removeFromUIManager()
            end
            BurdJournals.UI.MainPanel.instance = nil
        end
    end

    if ISTimedActionQueue and player then
        if ISTimedActionQueue.clear then
            ISTimedActionQueue.clear(player)
        end
    end

    if player then

        local characterId = BurdJournals.Client._lastKnownCharacterId
        if not characterId then

            if BurdJournals.getPlayerCharacterId then
                characterId = BurdJournals.getPlayerCharacterId(player)
            end
        end

        if characterId then
            BurdJournals.debugPrint("[BurdJournals] Notifying server to delete cached baseline for: " .. characterId)
            if sendClientCommand then
                sendClientCommand(player, "BurdJournals", "deleteBaseline", {
                    characterId = characterId,
                    reason = "death"
                })
            end
        else
            print("[BurdJournals] WARNING: Could not determine character ID for baseline deletion")
        end

        local modData = player.getModData and player:getModData() or nil
        if modData and modData.BurdJournals then
            modData.BurdJournals.baselineCaptured = false
            modData.BurdJournals.skillBaseline = nil
            modData.BurdJournals.traitBaseline = nil
            modData.BurdJournals.recipeBaseline = nil
            BurdJournals.debugPrint("[BurdJournals] Local baseline cleared for respawn")
        end
    end

    BurdJournals.Client._lastKnownCharacterId = nil

    BurdJournals.Client._pendingNewCharacterBaseline = false

    BurdJournals.debugPrint("[BurdJournals] Player death cleanup completed")
end

Events.OnServerCommand.Add(BurdJournals.Client.onServerCommand)
Events.OnGameStart.Add(BurdJournals.Client.init)
Events.OnCreatePlayer.Add(BurdJournals.Client.onCreatePlayer)
Events.OnPlayerDeath.Add(BurdJournals.Client.onPlayerDeath)

if Events.EveryOneMinute then
    Events.EveryOneMinute.Add(BurdJournals.Client.checkLanguageChange)
end

-- Restore custom journal names when inventory UI refreshes (MP fix)
-- This catches cases where item display names reset during MP item transfers
BurdJournals.Client.restoreJournalNamesInContainer = function(container)
    if not container then return end
    
    local items = container:getItems()
    if not items then return end
    
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local fullType = item:getFullType()
            if fullType and fullType:find("^BurdJournals%.") then
                local modData = item:getModData()
                if modData.BurdJournals and modData.BurdJournals.customName then
                    if item:getName() ~= modData.BurdJournals.customName then
                        BurdJournals.updateJournalName(item)
                    end
                end
            end
        end
    end
end

if Events.OnRefreshInventoryWindowContainers then
    Events.OnRefreshInventoryWindowContainers.Add(function(inventoryUI, reason)
        local player = getPlayer()
        if not player then return end
        
        -- Check main inventory
        local inventory = player:getInventory()
        if inventory then
            BurdJournals.Client.restoreJournalNamesInContainer(inventory)
        end
        
        -- Check equipped bags (some back items like Backpack Sprayer don't have inventory)
        local backpack = player:getClothingItem_Back()
        if backpack then
            -- Skip items that aren't containers (e.g., Backpack Sprayer, Knapsack Sprayer)
            -- These items have "Sprayer" in their name or don't have the getInventory method
            local itemType = backpack:getFullType() or ""
            local isSprayer = itemType:find("Sprayer") ~= nil
            
            if not isSprayer and backpack.getInventory then
                local backpackInv = backpack:getInventory()
                if backpackInv then
                    BurdJournals.Client.restoreJournalNamesInContainer(backpackInv)
                end
            end
        end
    end)
end

-- Chat command handler for /clearbaseline
-- NOTE: This command requires admin access in MP to prevent exploit
function BurdJournals.Client.onChatCommand(command)
    if not command then return end

    local cmd = string.lower(command)
    if cmd == "/clearbaseline" or cmd == "/resetbaseline" or cmd == "/journalreset" then
        local player = getPlayer()
        if not player then return true end

        -- In MP, require admin access to prevent baseline bypass exploit
        -- In SP, allow freely since it's the player's own game
        if isClient() and not isCoopHost() then
            local accessLevel = player:getAccessLevel()
            if not accessLevel or accessLevel == "None" then
                player:Say(getText("UI_BurdJournals_AdminOnly") or "This command requires admin access.")
                return true
            end
        end

        BurdJournals.debugPrint("[BurdJournals] Command: Clearing baseline for player...")

        -- Clear local player baseline data AND set bypass flag
        local modData = player:getModData()
        if not modData.BurdJournals then
            modData.BurdJournals = {}
        end

        modData.BurdJournals.baselineCaptured = nil
        modData.BurdJournals.skillBaseline = nil
        modData.BurdJournals.traitBaseline = nil
        modData.BurdJournals.recipeBaseline = nil
        modData.BurdJournals.baselineVersion = nil

        -- Set bypass flag - this makes restrictions not apply to this character immediately
        modData.BurdJournals.baselineBypassed = true

        -- Send command to server to delete cached baseline
        if isClient() then
            local characterId = BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player) or nil
            sendClientCommand(player, "BurdJournals", "deleteBaseline", {
                characterId = characterId
            })
        end

        -- Do NOT recapture baseline - leave it cleared so player can record everything
        -- Baseline will be captured fresh on next character creation

        -- Refresh any open journal panel UI
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.populateRecordList then
                panel:populateRecordList()
            end
            if panel.showFeedback then
                local feedbackMsg = getText("UI_BurdJournals_BaselineBypassEnabled") or "Baseline cleared! All skills/traits/recipes now recordable."
                panel:showFeedback(feedbackMsg, {r=0.3, g=1, b=0.5})
            end
        end

        -- Show feedback to player via speech bubble
        local msg = getText("UI_BurdJournals_CmdBaselineBypassed") or "[Journals] Baseline cleared! All skills/traits/recipes now recordable for this character."
        player:Say(msg)

        BurdJournals.debugPrint("[BurdJournals] Command: Baseline clear complete - bypass active")
        return true  -- Command was handled
    end

    return false  -- Not our command
end

-- Note: Chat commands now handled via ISChat hook in BurdJournals.Client.ChatHook
-- The OnCustomCommand event is not standard in PZ - commands processed via ChatHook.processCommand()

-- ============================================================================
-- DIAGNOSTIC SYSTEM FOR MP DEBUGGING
-- These functions help track down data loss issues in multiplayer
-- ============================================================================

BurdJournals.Client.Diagnostics = {}

-- Track key events for diagnostic purposes
BurdJournals.Client.Diagnostics.eventLog = {}
BurdJournals.Client.Diagnostics.maxLogEntries = 100

function BurdJournals.Client.Diagnostics.log(category, message, data)
    local timestamp = getTimestampMs and getTimestampMs() or os.time()
    local entry = {
        time = timestamp,
        category = category,
        message = message,
        data = data
    }
    table.insert(BurdJournals.Client.Diagnostics.eventLog, entry)

    -- Trim old entries
    while #BurdJournals.Client.Diagnostics.eventLog > BurdJournals.Client.Diagnostics.maxLogEntries do
        table.remove(BurdJournals.Client.Diagnostics.eventLog, 1)
    end

    -- Always print diagnostic logs to console for debugging
    local dataStr = ""
    if type(data) == "table" then
        local parts = {}
        for k, v in pairs(data) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        dataStr = " {" .. table.concat(parts, ", ") .. "}"
    elseif data ~= nil then
        dataStr = " {value=" .. tostring(data) .. "}"
    end
    BurdJournals.debugPrint("[BurdJournals DIAG] [" .. category .. "] " .. message .. dataStr)
end

-- Scan all journals in player inventory and report their state
function BurdJournals.Client.Diagnostics.scanJournals(player)
    if not player then
        player = getPlayer()
    end
    if not player then
        print("[BurdJournals DIAG] ERROR: No player available")
        return nil
    end

    local results = {
        timestamp = getTimestampMs and getTimestampMs() or os.time(),
        journals = {},
        summary = {
            total = 0,
            withData = 0,
            withSkills = 0,
            withTraits = 0,
            withRecipes = 0,
            totalSkillEntries = 0,
            totalTraitEntries = 0,
            totalRecipeEntries = 0
        }
    }

    local inventory = player:getInventory()
    if not inventory then
        print("[BurdJournals DIAG] ERROR: Could not access player inventory")
        return results
    end

    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local itemType = item:getFullType()
            if itemType and (string.find(itemType, "SurvivalJournal") or string.find(itemType, "BurdJournal")) then
                results.summary.total = results.summary.total + 1

                local journalInfo = {
                    id = item:getID(),
                    type = itemType,
                    hasModData = false,
                    hasBurdData = false,
                    skills = {},
                    traits = {},
                    recipes = {},
                    skillCount = 0,
                    traitCount = 0,
                    recipeCount = 0
                }

                local modData = item:getModData()
                if modData then
                    journalInfo.hasModData = true
                    local burdData = modData.BurdJournals
                    if burdData then
                        journalInfo.hasBurdData = true
                        results.summary.withData = results.summary.withData + 1

                        if burdData.skills then
                            for skillName, skillData in pairs(burdData.skills) do
                                journalInfo.skillCount = journalInfo.skillCount + 1
                                local skillXP = skillData.xp or 0
                                -- Compute level from XP instead of reading stored level (for backward compatibility)
                                -- Pass skillName for proper Fitness/Strength XP thresholds
                                local computedLevel = skillData.level or (BurdJournals.getSkillLevelFromXP and BurdJournals.getSkillLevelFromXP(skillXP, skillName)) or math.floor(skillXP / 75)
                                journalInfo.skills[skillName] = {
                                    level = computedLevel,
                                    xp = skillXP
                                }
                            end
                            if journalInfo.skillCount > 0 then
                                results.summary.withSkills = results.summary.withSkills + 1
                                results.summary.totalSkillEntries = results.summary.totalSkillEntries + journalInfo.skillCount
                            end
                        end

                        if burdData.traits then
                            for traitId, _ in pairs(burdData.traits) do
                                journalInfo.traitCount = journalInfo.traitCount + 1
                                table.insert(journalInfo.traits, traitId)
                            end
                            if journalInfo.traitCount > 0 then
                                results.summary.withTraits = results.summary.withTraits + 1
                                results.summary.totalTraitEntries = results.summary.totalTraitEntries + journalInfo.traitCount
                            end
                        end

                        if burdData.recipes then
                            for recipeName, _ in pairs(burdData.recipes) do
                                journalInfo.recipeCount = journalInfo.recipeCount + 1
                                table.insert(journalInfo.recipes, recipeName)
                            end
                            if journalInfo.recipeCount > 0 then
                                results.summary.withRecipes = results.summary.withRecipes + 1
                                results.summary.totalRecipeEntries = results.summary.totalRecipeEntries + journalInfo.recipeCount
                            end
                        end
                    end
                end

                table.insert(results.journals, journalInfo)
            end
        end
    end

    return results
end

-- Get player state snapshot for comparison
function BurdJournals.Client.Diagnostics.getPlayerSnapshot(player)
    if not player then
        player = getPlayer()
    end
    if not player then
        return nil
    end

    local snapshot = {
        timestamp = getTimestampMs and getTimestampMs() or os.time(),
        username = player:getUsername(),
        steamId = BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(player) or "unknown",
        characterId = BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player) or "unknown",
        hoursAlive = player:getHoursSurvived(),
        skills = {},
        traits = {},
        knownRecipeCount = 0
    }

    -- Capture skill levels
    local allSkills = BurdJournals.getAllSkills and BurdJournals.getAllSkills() or {}
    for _, skillName in ipairs(allSkills) do
        local perk = BurdJournals.getPerkByName(skillName)
        if perk then
            local level = player:getPerkLevel(perk)
            local xp = player:getXp():getXP(perk)
            if level > 0 or xp > 0 then
                snapshot.skills[skillName] = {level = level, xp = math.floor(xp)}
            end
        end
    end

    -- Capture traits
    local traitList = player:getTraits()
    if traitList then
        for i = 0, traitList:size() - 1 do
            local trait = traitList:get(i)
            if trait then
                table.insert(snapshot.traits, tostring(trait))
            end
        end
    end

    -- Count known recipes
    local knownRecipes = player:getKnownRecipes()
    if knownRecipes then
        snapshot.knownRecipeCount = knownRecipes:size()
    end

    return snapshot
end

-- Print full diagnostic report
function BurdJournals.Client.Diagnostics.printReport()
    local player = getPlayer()
    if not player then
        print("[BurdJournals DIAG] ERROR: No player - cannot generate report")
        return
    end

    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("BURD'S SURVIVAL JOURNALS - DIAGNOSTIC REPORT")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("Generated: " .. (getTimestampMs and tostring(getTimestampMs()) or tostring(os.time())))
    BurdJournals.debugPrint("Game Version: " .. (getCore and getCore():getVersionNumber() or "unknown"))
    BurdJournals.debugPrint("Is Multiplayer: " .. tostring(isClient()))
    BurdJournals.debugPrint("Is Server: " .. tostring(isServer()))
    BurdJournals.debugPrint("Is Coop Host: " .. tostring(isCoopHost and isCoopHost() or false))
    BurdJournals.debugPrint("")

    -- Player info
    BurdJournals.debugPrint("--- PLAYER INFO ---")
    local snapshot = BurdJournals.Client.Diagnostics.getPlayerSnapshot(player)
    if snapshot then
        BurdJournals.debugPrint("Username: " .. tostring(snapshot.username))
        BurdJournals.debugPrint("Steam ID: " .. tostring(snapshot.steamId))
        BurdJournals.debugPrint("Character ID: " .. tostring(snapshot.characterId))
        BurdJournals.debugPrint("Hours Survived: " .. string.format("%.2f", snapshot.hoursAlive))

        local skillCount = 0
        for _ in pairs(snapshot.skills) do skillCount = skillCount + 1 end
        BurdJournals.debugPrint("Skills with XP: " .. skillCount)
        BurdJournals.debugPrint("TraitsCount=" .. #snapshot.traits)
        BurdJournals.debugPrint("Known Recipes: " .. snapshot.knownRecipeCount)
    end
    BurdJournals.debugPrint("")

    -- Player modData state
    BurdJournals.debugPrint("--- PLAYER MODDATA ---")
    local modData = player:getModData()
    if modData and modData.BurdJournals then
        local bd = modData.BurdJournals
        BurdJournals.debugPrint("baselineCaptured: " .. tostring(bd.baselineCaptured))
        BurdJournals.debugPrint("baselineVersion: " .. tostring(bd.baselineVersion))
        BurdJournals.debugPrint("baselineBypassed: " .. tostring(bd.baselineBypassed))
        if bd.skillBaseline then
            local count = 0
            for _ in pairs(bd.skillBaseline) do count = count + 1 end
            BurdJournals.debugPrint("skillBaseline entries: " .. count)
        else
            BurdJournals.debugPrint("skillBaseline: nil")
        end
        if bd.traitBaseline then
            BurdJournals.debugPrint("traitBaseline entries: " .. #bd.traitBaseline)
        else
            BurdJournals.debugPrint("traitBaseline: nil")
        end
        if bd.recipeBaseline then
            local count = 0
            for _ in pairs(bd.recipeBaseline) do count = count + 1 end
            BurdJournals.debugPrint("recipeBaseline entries: " .. count)
        else
            BurdJournals.debugPrint("recipeBaseline: nil")
        end
    else
        BurdJournals.debugPrint("No BurdJournals modData on player")
    end
    BurdJournals.debugPrint("")

    -- Journal scan
    BurdJournals.debugPrint("--- JOURNAL INVENTORY SCAN ---")
    local scanResults = BurdJournals.Client.Diagnostics.scanJournals(player)
    if scanResults then
        BurdJournals.debugPrint("Total journals found: " .. scanResults.summary.total)
        BurdJournals.debugPrint("Journals with data: " .. scanResults.summary.withData)
        BurdJournals.debugPrint("Journals with skills: " .. scanResults.summary.withSkills .. " (total entries: " .. scanResults.summary.totalSkillEntries .. ")")
        BurdJournals.debugPrint("Journals with traits: " .. scanResults.summary.withTraits .. " (total entries: " .. scanResults.summary.totalTraitEntries .. ")")
        BurdJournals.debugPrint("Journals with recipes: " .. scanResults.summary.withRecipes .. " (total entries: " .. scanResults.summary.totalRecipeEntries .. ")")
        BurdJournals.debugPrint("")

        for i, journal in ipairs(scanResults.journals) do
            BurdJournals.debugPrint("  Journal #" .. i .. " (ID: " .. tostring(journal.id) .. ")")
            BurdJournals.debugPrint("    Type: " .. tostring(journal.type))
            BurdJournals.debugPrint("    Has ModData: " .. tostring(journal.hasModData))
            BurdJournals.debugPrint("    Has BurdData: " .. tostring(journal.hasBurdData))
            BurdJournals.debugPrint("    Skills: " .. journal.skillCount .. ", Traits: " .. journal.traitCount .. ", Recipes: " .. journal.recipeCount)
        end
    end
    BurdJournals.debugPrint("")

    -- Recent event log
    BurdJournals.debugPrint("--- RECENT EVENT LOG (last 20) ---")
    local log = BurdJournals.Client.Diagnostics.eventLog
    local startIdx = math.max(1, #log - 19)
    for i = startIdx, #log do
        local entry = log[i]
        BurdJournals.debugPrint(string.format("  [%s] %s: %s", tostring(entry.time), entry.category, entry.message))
    end
    BurdJournals.debugPrint("")

    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("END OF DIAGNOSTIC REPORT")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
end

-- Chat command handler for /journaldiag
function BurdJournals.Client.Diagnostics.onChatCommand(command)
    if not command then return false end

    local cmd = string.lower(command)
    if cmd == "/journaldiag" or cmd == "/jdiag" or cmd == "/burdjournaldiag" then
        BurdJournals.Client.Diagnostics.printReport()

        local player = getPlayer()
        if player then
            player:Say("[Journals] Diagnostic report printed to console.txt")
        end
        return true
    end

    if cmd == "/journalscan" or cmd == "/jscan" then
        local player = getPlayer()
        local results = BurdJournals.Client.Diagnostics.scanJournals(player)
        if results and player then
            local msg = string.format("[Journals] Found %d journals: %d skills, %d traits, %d recipes",
                results.summary.total,
                results.summary.totalSkillEntries,
                results.summary.totalTraitEntries,
                results.summary.totalRecipeEntries)
            player:Say(msg)
        end
        return true
    end

    return false
end

-- Note: Diagnostic commands now handled via ISChat hook in BurdJournals.Client.ChatHook

-- Hook into key events to log them
local originalOnServerCommand = BurdJournals.Client.onServerCommand
BurdJournals.Client.onServerCommand = function(module, command, args)
    if module == "BurdJournals" then
        -- Log server commands for diagnostics
        local logData = {command = command}
        if args then
            if args.journalId then logData.journalId = args.journalId end
            if args.skillName then logData.skillName = args.skillName end
            if args.traitId then logData.traitId = args.traitId end
            if args.recipeName then logData.recipeName = args.recipeName end
            if args.journalData then
                local skillCount = args.journalData.skills and BurdJournals.countTable(args.journalData.skills) or 0
                local traitCount = args.journalData.traits and BurdJournals.countTable(args.journalData.traits) or 0
                local recipeCount = args.journalData.recipes and BurdJournals.countTable(args.journalData.recipes) or 0
                logData.dataSkills = skillCount
                logData.dataTraits = traitCount
                logData.dataRecipes = recipeCount
            end
        end
        BurdJournals.Client.Diagnostics.log("SERVER_CMD", "Received: " .. command, logData)
    end

    -- Call original handler
    return originalOnServerCommand(module, command, args)
end

-- Log on game start
local originalInit = BurdJournals.Client.init
BurdJournals.Client.init = function(player)
    BurdJournals.Client.Diagnostics.log("LIFECYCLE", "OnGameStart/init called", {
        username = player and player:getUsername() or "nil",
        hoursAlive = player and player:getHoursSurvived() or 0,
        isClient = isClient(),
        isServer = isServer()
    })
    return originalInit(player)
end

-- Log on player create
local originalOnCreatePlayer = BurdJournals.Client.onCreatePlayer
BurdJournals.Client.onCreatePlayer = function(playerIndex, player)
    BurdJournals.Client.Diagnostics.log("LIFECYCLE", "OnCreatePlayer called", {
        playerIndex = playerIndex,
        username = player and player:getUsername() or "nil",
        hoursAlive = player and player:getHoursSurvived() or 0
    })
    return originalOnCreatePlayer(playerIndex, player)
end

-- Log connection events if available
if Events.OnConnected then
    Events.OnConnected.Add(function()
        BurdJournals.Client.Diagnostics.log("NETWORK", "OnConnected fired", {})
    end)
end

if Events.OnDisconnect then
    Events.OnDisconnect.Add(function()
        BurdJournals.Client.Diagnostics.log("NETWORK", "OnDisconnect fired", {})
    end)
end

if Events.OnConnectionStateChanged then
    Events.OnConnectionStateChanged.Add(function(state, reason)
        BurdJournals.Client.Diagnostics.log("NETWORK", "ConnectionStateChanged", {
            state = tostring(state),
            reason = tostring(reason)
        })
    end)
end

BurdJournals.debugPrint("[BurdJournals] Diagnostic system loaded - use /journaldiag or /jdiag for report")

-- ============================================================================
-- DEBUG COMMANDS SYSTEM
-- Commands for testing and development (/bsjgive, /bsjdump, /bsjdebug, etc.)
-- Requires AllowDebugCommands sandbox option OR -debug launch flag
-- ============================================================================

BurdJournals.Client.Debug = {}

-- Runtime verbose toggle (can be enabled without -debug flag via /bsjverbose)
BurdJournals.Client.Debug.verboseEnabled = false

-- Check if debug commands are allowed
-- Returns true if: sandbox AllowDebugCommands is ON, OR game launched with -debug flag
-- In MP, also requires admin access when sandbox option is used
function BurdJournals.Client.Debug.isAllowed(player)
    -- Always allow if -debug flag is present
    if isDebugEnabled and isDebugEnabled() then
        return true
    end
    
    -- Check sandbox option
    local sandboxOption = SandboxVars.BurdJournals and SandboxVars.BurdJournals.AllowDebugCommands
    if sandboxOption then
        -- In MP, require admin access
        if isClient() and not isCoopHost() then
            if player then
                local accessLevel = player:getAccessLevel()
                if accessLevel and accessLevel ~= "None" then
                    return true
                end
            end
            return false
        end
        -- In SP or as host, allow
        return true
    end
    
    return false
end

-- Check if verbose logging is enabled (via /bsjverbose OR -debug flag)
function BurdJournals.Client.Debug.isVerbose()
    return BurdJournals.Client.Debug.verboseEnabled or (isDebugEnabled and isDebugEnabled())
end

-- Debug print that respects verbose mode
function BurdJournals.Client.Debug.print(msg)
    if BurdJournals.Client.Debug.isVerbose() then
        BurdJournals.debugPrint("[BSJ-DEBUG] " .. msg)
    end
end

-- Show feedback to player (toast + optional console)
function BurdJournals.Client.Debug.feedback(player, msg, color, alsoConsole)
    color = color or {r=0.5, g=0.8, b=1.0}
    
    -- Show via Say
    if player and player.Say then
        player:Say(msg)
    end
    
    -- Show in panel if open
    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        if panel.showFeedback then
            panel:showFeedback(msg, color)
        end
    end
    
    -- Also console if requested
    if alsoConsole then
        BurdJournals.debugPrint("[BSJ-DEBUG] " .. msg)
    end
end

BurdJournals.Client.Debug._baselineSnapshotLastList = BurdJournals.Client.Debug._baselineSnapshotLastList or nil
BurdJournals.Client.Debug._baselineSnapshotLastDetail = BurdJournals.Client.Debug._baselineSnapshotLastDetail or nil

function BurdJournals.Client.Debug.sendServer(command, args, player)
    if BurdJournals.Client and BurdJournals.Client.sendToServer then
        return BurdJournals.Client.sendToServer(command, args, player)
    end
    local target = player or getPlayer()
    if not target or not sendClientCommand then
        return false
    end
    sendClientCommand(target, "BurdJournals", command, args or {})
    return true
end

function BurdJournals.Client.Debug.listBaselineCache(player)
    return BurdJournals.Client.Debug.sendServer("debugListBaselineCache", {}, player)
end

function BurdJournals.Client.Debug.listBaselineSnapshots(args, player)
    return BurdJournals.Client.Debug.sendServer("debugListBaselineSnapshots", args or {}, player)
end

function BurdJournals.Client.Debug.getBaselineSnapshot(snapshotId, player)
    return BurdJournals.Client.Debug.sendServer("debugGetBaselineSnapshot", {
        snapshotId = snapshotId
    }, player)
end

function BurdJournals.Client.Debug.getTargetBaselinePayload(args, player)
    return BurdJournals.Client.Debug.sendServer("debugGetTargetBaselinePayload", args or {}, player)
end

function BurdJournals.Client.Debug.saveBaselineDraft(args, player)
    return BurdJournals.Client.Debug.sendServer("debugSaveBaselineDraft", args or {}, player)
end

function BurdJournals.Client.Debug.saveBaselineSnapshot(args, player)
    return BurdJournals.Client.Debug.sendServer("debugSaveBaselineSnapshot", args or {}, player)
end

function BurdJournals.Client.Debug.applyBaselineSnapshot(args, player)
    return BurdJournals.Client.Debug.sendServer("debugApplyBaselineSnapshot", args or {}, player)
end

function BurdJournals.Client.Debug.deleteBaselineSnapshot(snapshotId, player)
    return BurdJournals.Client.Debug.sendServer("debugDeleteBaselineSnapshot", {
        snapshotId = snapshotId
    }, player)
end

-- ============================================================================
-- /bsjverbose - Toggle verbose debug logging
-- ============================================================================

function BurdJournals.Client.Debug.cmdVerbose(player, args)
    if not args or args == "" then
        args = "status"
    end
    
    local arg = string.lower(args)
    
    if arg == "on" or arg == "true" or arg == "1" then
        BurdJournals.Client.Debug.verboseEnabled = true
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Verbose logging ENABLED", {r=0.3, g=1, b=0.5}, true)
    elseif arg == "off" or arg == "false" or arg == "0" then
        BurdJournals.Client.Debug.verboseEnabled = false
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Verbose logging DISABLED", {r=1, g=0.7, b=0.3}, true)
    else
        local status = BurdJournals.Client.Debug.verboseEnabled and "ON" or "OFF"
        local debugFlag = (isDebugEnabled and isDebugEnabled()) and "YES" or "NO"
        BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] Verbose: %s | -debug flag: %s", status, debugFlag), {r=0.5, g=0.8, b=1}, true)
    end
    
    return true
end

-- ============================================================================
-- /bsjdump - Dump debug information
-- ============================================================================

function BurdJournals.Client.Debug.cmdDump(player, args)
    if not args or args == "" then
        args = "all"
    end
    
    local arg = string.lower(args)
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BSJ-DEBUG] DUMP: " .. arg)
    BurdJournals.debugPrint("================================================================================")
    
    if arg == "skills" or arg == "all" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- PLAYER SKILLS ---")
        if player then
            local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
            for _, skillName in ipairs(allowedSkills) do
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
                if perk then
                    local level = player:getPerkLevel(perk)
                    local xp = player:getXp():getXP(perk)
                    local isPassive = (skillName == "Fitness" or skillName == "Strength") and " (passive)" or ""
                    BurdJournals.debugPrint(string.format("  %s: Level %d, XP %.0f%s", skillName, level, xp, isPassive))
                end
            end
        else
            print("  ERROR: No player available")
        end
    end
    
    if arg == "traits" or arg == "all" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- PLAYER TRAITS ---")
        if player then
            local modData = player:getModData()
            local startingTraits = modData.BurdJournals and modData.BurdJournals.traitBaseline or {}
            
            local playerTraits = player:getCharacterTraits()
            if playerTraits and playerTraits:size() > 0 then
                for i = 0, playerTraits:size() - 1 do
                    local trait = playerTraits:get(i)
                    local traitId = tostring(trait)
                    local isStarting = startingTraits[traitId] and " (starting)" or " (earned)"
                    BurdJournals.debugPrint(string.format("  %s%s", traitId, isStarting))
                end
            else
                BurdJournals.debugPrint("  No traits found")
            end
        else
            print("  ERROR: No player available")
        end
    end
    
    if arg == "baseline" or arg == "all" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- BASELINE DATA ---")
        if player then
            local modData = player:getModData()
            if modData.BurdJournals then
                local bj = modData.BurdJournals
                BurdJournals.debugPrint(string.format("  Captured: %s", bj.baselineCaptured and "Yes" or "No"))
                BurdJournals.debugPrint(string.format("  Version: %s", tostring(bj.baselineVersion or "N/A")))
                BurdJournals.debugPrint(string.format("  Bypassed: %s", bj.baselineBypassed and "Yes" or "No"))
                
                if bj.skillBaseline then
                    BurdJournals.debugPrint("  Skill Baselines:")
                    for skill, xp in pairs(bj.skillBaseline) do
                        BurdJournals.debugPrint(string.format("    %s: %.0f XP", skill, xp))
                    end
                end
                
                if bj.traitBaseline then
                    local traitCount = 0
                    for _ in pairs(bj.traitBaseline) do traitCount = traitCount + 1 end
                    BurdJournals.debugPrint(string.format("  Trait Baselines: %d entries", traitCount))
                end
                
                if bj.recipeBaseline then
                    local recipeCount = 0
                    for _ in pairs(bj.recipeBaseline) do recipeCount = recipeCount + 1 end
                    BurdJournals.debugPrint(string.format("  Recipe Baselines: %d entries", recipeCount))
                end

                if bj.journalDRCache then
                    local drJournalCount = 0
                    local drAliasCount = 0
                    local drJournals = bj.journalDRCache.journals
                    local drAliases = bj.journalDRCache.aliases
                    if type(drJournals) == "table" then
                        for _ in pairs(drJournals) do drJournalCount = drJournalCount + 1 end
                    end
                    if type(drAliases) == "table" then
                        for _ in pairs(drAliases) do drAliasCount = drAliasCount + 1 end
                    end
                    BurdJournals.debugPrint(string.format("  DR Cache: %d journals, %d aliases", drJournalCount, drAliasCount))
                end
            else
                BurdJournals.debugPrint("  No BurdJournals modData found")
            end
        else
            print("  ERROR: No player available")
        end
    end
    
    if arg == "journal" or arg == "all" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- HELD JOURNAL ---")
        if player then
            local heldItem = player:getPrimaryHandItem()
            if heldItem and BurdJournals.isJournal and BurdJournals.isJournal(heldItem) then
                local modData = heldItem:getModData()
                if modData.BurdJournals then
                    local data = modData.BurdJournals
                    BurdJournals.debugPrint(string.format("  Type: %s", heldItem:getFullType()))
                    BurdJournals.debugPrint(string.format("  ID: %s", tostring(heldItem:getID())))
                    BurdJournals.debugPrint(string.format("  UUID: %s", tostring(data.uuid or "N/A")))
                    BurdJournals.debugPrint(string.format("  Owner: %s", tostring(data.ownerCharacterName or "N/A")))
                    
                    local skillCount = data.skills and BurdJournals.countTable(data.skills) or 0
                    local traitCount = data.traits and BurdJournals.countTable(data.traits) or 0
                    local recipeCount = data.recipes and BurdJournals.countTable(data.recipes) or 0
                    BurdJournals.debugPrint(string.format("  Contents: %d skills, %d traits, %d recipes", skillCount, traitCount, recipeCount))
                    
                    if data.skills and skillCount > 0 then
                        BurdJournals.debugPrint("  Skills:")
                        for skillName, skillData in pairs(data.skills) do
                            local level = skillData.level or "?"
                            local xp = skillData.xp or 0
                            BurdJournals.debugPrint(string.format("    %s: Level %s, XP %.0f", skillName, tostring(level), xp))
                        end
                    end
                    
                    if data.traits and traitCount > 0 then
                        BurdJournals.debugPrint("  Traits:")
                        for traitId, _ in pairs(data.traits) do
                            BurdJournals.debugPrint(string.format("    %s", traitId))
                        end
                    end
                else
                    BurdJournals.debugPrint("  Journal has no BurdJournals data")
                end
            else
                BurdJournals.debugPrint("  No journal in primary hand")
            end
        else
            print("  ERROR: No player available")
        end
    end
    
    if arg == "config" or arg == "all" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- SANDBOX CONFIG ---")
        if SandboxVars.BurdJournals then
            for key, value in pairs(SandboxVars.BurdJournals) do
                BurdJournals.debugPrint(string.format("  %s = %s", key, tostring(value)))
            end
        else
            BurdJournals.debugPrint("  No BurdJournals sandbox vars found")
        end
    end
    
    if arg == "recipes" or arg == "all" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- RECIPE DEBUG ---")
        if BurdJournals.debugRecipeSystem then
            BurdJournals.debugRecipeSystem(player)
        else
            BurdJournals.debugPrint("  debugRecipeSystem function not available")
        end
    end
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BSJ-DEBUG] END DUMP")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Dump complete - check console.txt", {r=0.5, g=0.8, b=1}, false)
    
    return true
end

-- ============================================================================
-- /bsjreset - Reset various data
-- ============================================================================

function BurdJournals.Client.Debug.cmdReset(player, args)
    if not args or args == "" then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjreset [skills|traits|baseline|journal|all]", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local arg = string.lower(args)
    
    if string.sub(arg, 1, 8) == "baseline" then
        -- Redirect to /bsjbaseline command
        local baselineArgs = string.sub(args, 10) -- Skip "baseline " 
        if baselineArgs == "" then
            baselineArgs = "clear all"
        end
        return BurdJournals.Client.Debug.cmdBaseline(player, baselineArgs)
    end
    
    if arg == "skills" then
        if player then
            -- Reset skills to level 0 (or baseline for passive)
            local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
            for _, skillName in ipairs(allowedSkills) do
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
                if perk then
                    -- For passive skills, reset to level 5
                    local targetLevel = (skillName == "Fitness" or skillName == "Strength") and 5 or 0
                    player:setPerkLevelDebug(perk, targetLevel)
                end
            end
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Skills reset to baseline levels", {r=0.3, g=1, b=0.5}, true)
        end
        return true
    end
    
    if arg == "traits" then
        if player then
            local modData = player:getModData()
            local startingTraits = modData.BurdJournals and modData.BurdJournals.traitBaseline or {}
            
            local playerTraits = player:getCharacterTraits()
            if playerTraits then
                local toRemove = {}
                for i = 0, playerTraits:size() - 1 do
                    local trait = playerTraits:get(i)
                    local traitId = tostring(trait)
                    if not startingTraits[traitId] then
                        table.insert(toRemove, trait)
                    end
                end
                
                for _, trait in ipairs(toRemove) do
                    player:getCharacterTraits():remove(trait)
                end
                
                BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] Removed %d earned traits", #toRemove), {r=0.3, g=1, b=0.5}, true)
            end
        end
        return true
    end
    
    if arg == "journal" then
        if player then
            local heldItem = player:getPrimaryHandItem()
            if heldItem and BurdJournals.isJournal and BurdJournals.isJournal(heldItem) then
                local modData = heldItem:getModData()
                modData.BurdJournals = nil
                if heldItem.transmitModData then
                    heldItem:transmitModData()
                end
                BurdJournals.Client.Debug.feedback(player, "[BSJ] Held journal data cleared", {r=0.3, g=1, b=0.5}, true)
            else
                BurdJournals.Client.Debug.feedback(player, "[BSJ] No journal in primary hand", {r=1, g=0.5, b=0.3}, true)
            end
        end
        return true
    end
    
    if arg == "all" then
        BurdJournals.Client.Debug.cmdReset(player, "skills")
        BurdJournals.Client.Debug.cmdReset(player, "traits")
        BurdJournals.Client.Debug.cmdReset(player, "baseline")
        return true
    end
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown reset type: " .. arg, {r=1, g=0.5, b=0.3}, true)
    return true
end

-- ============================================================================
-- /bsjbaseline - Comprehensive baseline management
-- ============================================================================

function BurdJournals.Client.Debug.cmdBaseline(player, args)
    if not player then
        print("[BSJ] Error: No player for baseline command")
        return true
    end
    
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    
    -- Parse arguments
    if not args or args == "" then
        BurdJournals.Client.Debug.cmdBaselineHelp(player)
        return true
    end
    
    local parts = {}
    for part in string.gmatch(args, "%S+") do
        table.insert(parts, part)
    end
    
    local action = string.lower(parts[1] or "")
    local param = parts[2] or ""
    local value = parts[3] or ""
    
    -- Route to sub-commands
    if action == "view" or action == "show" or action == "dump" then
        return BurdJournals.Client.Debug.cmdBaselineView(player)
    elseif action == "clear" or action == "reset" then
        return BurdJournals.Client.Debug.cmdBaselineClear(player, param)
    elseif action == "set" then
        return BurdJournals.Client.Debug.cmdBaselineSet(player, param, value)
    elseif action == "remove" or action == "rm" then
        return BurdJournals.Client.Debug.cmdBaselineRemove(player, param)
    elseif action == "copy" or action == "snapshot" then
        return BurdJournals.Client.Debug.cmdBaselineCopy(player, param)
    elseif action == "recalculate" or action == "recalc" then
        return BurdJournals.Client.Debug.cmdBaselineRecalculate(player)
    elseif action == "help" then
        return BurdJournals.Client.Debug.cmdBaselineHelp(player)
    else
        -- Maybe it's a direct set: /bsjbaseline skill:Carpentry:3
        if string.find(action, ":") then
            return BurdJournals.Client.Debug.cmdBaselineSet(player, action, param)
        end
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown baseline action: " .. action .. ". Use /bsjbaseline help", {r=1, g=0.7, b=0.3}, true)
    end
    
    return true
end

-- View current baseline
function BurdJournals.Client.Debug.cmdBaselineView(player)
    local modData = player:getModData()
    local baseline = modData.BurdJournals or {}
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BSJ] BASELINE DATA FOR: " .. (player:getUsername() or "Unknown"))
    BurdJournals.debugPrint("================================================================================")
    
    -- Skill baselines
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("--- SKILL BASELINES ---")
    local skillBaseline = baseline.skillBaseline or {}
    local hasSkills = false
    for skillName, xp in pairs(skillBaseline) do
        if type(xp) == "number" then
            local level = BurdJournals.Client.Debug.xpToLevel and BurdJournals.Client.Debug.xpToLevel(skillName, xp) or "?"
            BurdJournals.debugPrint(string.format("  %-20s Level %s (%d XP)", skillName, tostring(level), xp))
            hasSkills = true
        end
    end
    if not hasSkills then
        BurdJournals.debugPrint("  (none set)")
    end
    
    -- Trait baselines
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("--- TRAIT BASELINES ---")
    local traitBaseline = baseline.traitBaseline or {}
    local hasTraits = false
    for traitId, _ in pairs(traitBaseline) do
        BurdJournals.debugPrint("  " .. traitId)
        hasTraits = true
    end
    if not hasTraits then
        BurdJournals.debugPrint("  (none set)")
    end
    
    -- Recipe baselines
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("--- RECIPE BASELINES ---")
    local recipeBaseline = baseline.recipeBaseline or {}
    local hasRecipes = false
    local recipeCount = 0
    for recipeName, _ in pairs(recipeBaseline) do
        recipeCount = recipeCount + 1
        if recipeCount <= 20 then
            BurdJournals.debugPrint("  " .. recipeName)
        end
        hasRecipes = true
    end
    if recipeCount > 20 then
        BurdJournals.debugPrint("  ... and " .. (recipeCount - 20) .. " more")
    end
    if not hasRecipes then
        BurdJournals.debugPrint("  (none set)")
    end
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline data printed to console.txt", {r=0.5, g=0.8, b=1}, false)
    return true
end

-- Clear baseline (all or specific type)
function BurdJournals.Client.Debug.cmdBaselineClear(player, param)
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    
    param = param and string.lower(param) or "all"
    
    if param == "all" or param == "" then
        modData.BurdJournals.skillBaseline = nil
        modData.BurdJournals.traitBaseline = nil
        modData.BurdJournals.recipeBaseline = nil
        BurdJournals.Client.Debug.feedback(player, "[BSJ] All baseline data cleared", {r=1, g=0.7, b=0.3}, true)
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline cleared for: " .. (player:getUsername() or "Unknown"))
    elseif param == "skills" then
        modData.BurdJournals.skillBaseline = nil
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Skill baseline cleared", {r=1, g=0.7, b=0.3}, true)
    elseif param == "traits" then
        modData.BurdJournals.traitBaseline = nil
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Trait baseline cleared", {r=1, g=0.7, b=0.3}, true)
    elseif param == "recipes" then
        modData.BurdJournals.recipeBaseline = nil
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Recipe baseline cleared", {r=1, g=0.7, b=0.3}, true)
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown clear type: " .. param .. ". Use: all, skills, traits, recipes", {r=1, g=0.5, b=0.3}, true)
    end
    
    return true
end

-- Set specific baseline value
function BurdJournals.Client.Debug.cmdBaselineSet(player, param, value)
    if not param or param == "" then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjbaseline set skill:Name:Level or trait:Name or recipe:Name", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    
    -- Parse param - could be "skill:Carpentry:3" or "skill:Carpentry" with value as "3"
    local paramParts = {}
    for part in string.gmatch(param, "[^:]+") do
        table.insert(paramParts, part)
    end
    
    local paramType = string.lower(paramParts[1] or "")
    local paramName = paramParts[2] or ""
    local paramValue = paramParts[3] or value or ""
    
    if paramType == "skill" then
        -- Set skill baseline
        if paramName == "" then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjbaseline set skill:SkillName:Level", {r=1, g=0.7, b=0.3}, true)
            return true
        end
        
        -- Normalize skill name
        local skillName = BurdJournals.Client.Debug.normalizeSkillName(paramName)
        if not skillName then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown skill: " .. paramName, {r=1, g=0.5, b=0.3}, true)
            return true
        end
        
        local level = tonumber(paramValue)
        if not level or level < 0 or level > 10 then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Level must be 0-10", {r=1, g=0.5, b=0.3}, true)
            return true
        end
        
        -- Calculate XP for level
        local xp = BurdJournals.Client.Debug.getXPForLevel(skillName, level)
        
        modData.BurdJournals.skillBaseline = modData.BurdJournals.skillBaseline or {}
        modData.BurdJournals.skillBaseline[skillName] = xp
        
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline " .. skillName .. " set to Level " .. level .. " (" .. xp .. " XP)", {r=0.3, g=1, b=0.5}, true)
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline set: " .. skillName .. " = Level " .. level .. " (" .. xp .. " XP)")
        
    elseif paramType == "trait" then
        -- Set trait baseline
        if paramName == "" then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjbaseline set trait:TraitName", {r=1, g=0.7, b=0.3}, true)
            return true
        end
        
        -- Check if trait exists
        local trait = TraitFactory.getTrait(paramName)
        if not trait then
            -- Try case-insensitive lookup
            local allTraits = TraitFactory.getTraits()
            if allTraits then
                for i = 0, allTraits:size() - 1 do
                    local t = allTraits:get(i)
                    if t and string.lower(t:getType()) == string.lower(paramName) then
                        trait = t
                        paramName = t:getType()
                        break
                    end
                end
            end
        end
        
        if not trait then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown trait: " .. paramName, {r=1, g=0.5, b=0.3}, true)
            return true
        end
        
        modData.BurdJournals.traitBaseline = modData.BurdJournals.traitBaseline or {}
        modData.BurdJournals.traitBaseline[paramName] = true
        
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline trait added: " .. paramName, {r=0.3, g=1, b=0.5}, true)
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline trait added: " .. paramName)
        
    elseif paramType == "recipe" then
        -- Set recipe baseline
        if paramName == "" then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjbaseline set recipe:RecipeName", {r=1, g=0.7, b=0.3}, true)
            return true
        end
        
        modData.BurdJournals.recipeBaseline = modData.BurdJournals.recipeBaseline or {}
        modData.BurdJournals.recipeBaseline[paramName] = true
        
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline recipe added: " .. paramName, {r=0.3, g=1, b=0.5}, true)
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline recipe added: " .. paramName)
        
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown type: " .. paramType .. ". Use: skill, trait, recipe", {r=1, g=0.5, b=0.3}, true)
    end
    
    return true
end

-- Remove specific baseline value
function BurdJournals.Client.Debug.cmdBaselineRemove(player, param)
    if not param or param == "" then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjbaseline remove skill:Name or trait:Name or recipe:Name", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local modData = player:getModData()
    if not modData.BurdJournals then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] No baseline data to modify", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    -- Parse param
    local paramParts = {}
    for part in string.gmatch(param, "[^:]+") do
        table.insert(paramParts, part)
    end
    
    local paramType = string.lower(paramParts[1] or "")
    local paramName = paramParts[2] or ""
    
    if paramType == "skill" then
        local skillName = BurdJournals.Client.Debug.normalizeSkillName(paramName)
        if skillName and modData.BurdJournals.skillBaseline then
            modData.BurdJournals.skillBaseline[skillName] = nil
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Removed skill baseline: " .. skillName, {r=1, g=0.7, b=0.3}, true)
        else
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Skill not found in baseline: " .. paramName, {r=1, g=0.5, b=0.3}, true)
        end
        
    elseif paramType == "trait" then
        if modData.BurdJournals.traitBaseline and modData.BurdJournals.traitBaseline[paramName] then
            modData.BurdJournals.traitBaseline[paramName] = nil
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Removed trait baseline: " .. paramName, {r=1, g=0.7, b=0.3}, true)
        else
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Trait not found in baseline: " .. paramName, {r=1, g=0.5, b=0.3}, true)
        end
        
    elseif paramType == "recipe" then
        if modData.BurdJournals.recipeBaseline and modData.BurdJournals.recipeBaseline[paramName] then
            modData.BurdJournals.recipeBaseline[paramName] = nil
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Removed recipe baseline: " .. paramName, {r=1, g=0.7, b=0.3}, true)
        else
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Recipe not found in baseline: " .. paramName, {r=1, g=0.5, b=0.3}, true)
        end
        
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown type: " .. paramType .. ". Use: skill, trait, recipe", {r=1, g=0.5, b=0.3}, true)
    end
    
    return true
end

-- Copy current character state as baseline
function BurdJournals.Client.Debug.cmdBaselineCopy(player, param)
    local modData = player:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    
    param = param and string.lower(param) or "all"
    
    local copied = {}
    
    if param == "all" or param == "skills" then
        -- Copy current skill levels as baseline
        modData.BurdJournals.skillBaseline = {}
        local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
        for _, skillName in ipairs(allowedSkills) do
            local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
            if perk then
                local xp = player:getXp():getXP(perk)
                if xp and xp > 0 then
                    modData.BurdJournals.skillBaseline[skillName] = xp
                end
            end
        end
        table.insert(copied, "skills")
    end
    
    if param == "all" or param == "traits" then
        -- Copy current traits as baseline
        modData.BurdJournals.traitBaseline = {}
        local playerTraits = player:getCharacterTraits()
        if playerTraits then
            for i = 0, playerTraits:size() - 1 do
                local trait = playerTraits:get(i)
                local traitId = tostring(trait)
                modData.BurdJournals.traitBaseline[traitId] = true
            end
        end
        table.insert(copied, "traits")
    end
    
    if param == "all" or param == "recipes" then
        -- Copy current known recipes as baseline
        modData.BurdJournals.recipeBaseline = {}
        local knownRecipes = player:getKnownRecipes()
        if knownRecipes then
            for i = 0, knownRecipes:size() - 1 do
                local recipe = knownRecipes:get(i)
                modData.BurdJournals.recipeBaseline[recipe] = true
            end
        end
        table.insert(copied, "recipes")
    end
    
    if #copied > 0 then
        local msg = "[BSJ] Current " .. table.concat(copied, ", ") .. " copied to baseline"
        BurdJournals.Client.Debug.feedback(player, msg, {r=0.3, g=1, b=0.5}, true)
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline snapshot created: " .. table.concat(copied, ", "))
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown copy type: " .. param .. ". Use: all, skills, traits, recipes", {r=1, g=0.5, b=0.3}, true)
    end
    
    return true
end

-- Recalculate baseline from profession/traits
function BurdJournals.Client.Debug.cmdBaselineRecalculate(player)
    if BurdJournals.Client.calculateProfessionBaseline then
        BurdJournals.Client.calculateProfessionBaseline(player)
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline recalculated from profession/traits", {r=0.3, g=1, b=0.5}, true)
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline recalculated for: " .. (player:getUsername() or "Unknown"))
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Cannot recalculate - function not available", {r=1, g=0.5, b=0.3}, true)
    end
    return true
end

-- Helper to normalize skill names
function BurdJournals.Client.Debug.normalizeSkillName(input)
    if not input or input == "" then return nil end
    
    local lowerInput = string.lower(input)
    local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
    
    for _, skillName in ipairs(allowedSkills) do
        if string.lower(skillName) == lowerInput then
            return skillName
        end
    end
    
    -- Common aliases
    local aliases = {
        ["carp"] = "Carpentry",
        ["carpentry"] = "Carpentry",
        ["cook"] = "Cooking",
        ["cooking"] = "Cooking",
        ["farm"] = "Farming",
        ["farming"] = "Farming",
        ["fish"] = "Fishing",
        ["fishing"] = "Fishing",
        ["forage"] = "Foraging",
        ["foraging"] = "Foraging",
        ["trap"] = "Trapping",
        ["trapping"] = "Trapping",
        ["first"] = "FirstAid",
        ["firstaid"] = "FirstAid",
        ["doctor"] = "Doctor",
        ["elec"] = "Electricity",
        ["electricity"] = "Electricity",
        ["metal"] = "MetalWelding",
        ["metalwelding"] = "MetalWelding",
        ["welding"] = "MetalWelding",
        ["mech"] = "Mechanics",
        ["mechanics"] = "Mechanics",
        ["tailor"] = "Tailoring",
        ["tailoring"] = "Tailoring",
        ["aim"] = "Aiming",
        ["aiming"] = "Aiming",
        ["reload"] = "Reloading",
        ["reloading"] = "Reloading",
        ["fit"] = "Fitness",
        ["fitness"] = "Fitness",
        ["str"] = "Strength",
        ["strength"] = "Strength",
        ["sprint"] = "Sprinting",
        ["sprinting"] = "Sprinting",
        ["light"] = "Lightfooted",
        ["lightfoot"] = "Lightfooted",
        ["lightfooted"] = "Lightfooted",
        ["nimble"] = "Nimble",
        ["sneak"] = "Sneak",
        ["axe"] = "Axe",
        ["long"] = "LongBlade",
        ["longblade"] = "LongBlade",
        ["short"] = "ShortBlade",
        ["shortblade"] = "ShortBlade",
        ["blunt"] = "Blunt",
        ["spear"] = "Spear",
        ["maint"] = "Maintenance",
        ["maintenance"] = "Maintenance",
        ["combat"] = "Combat",
    }
    
    if aliases[lowerInput] then
        return aliases[lowerInput]
    end
    
    return nil
end

-- Helper to convert XP back to level
-- Uses our verified threshold tables for passive skills (Fitness/Strength)
function BurdJournals.Client.Debug.xpToLevel(skillName, xp)
    if not xp or xp < 0 then return 0 end
    
    -- Use our verified threshold tables
    local isPassive = (skillName == "Fitness" or skillName == "Strength")
    local thresholds = isPassive and BurdJournals.Client.Debug.PASSIVE_XP_THRESHOLDS or BurdJournals.Client.Debug.XP_THRESHOLDS
    
    for level = 10, 1, -1 do
        local threshold = thresholds[level] or 0
        if xp >= threshold then
            return level
        end
    end
    return 0
end

-- Show help for baseline command
function BurdJournals.Client.Debug.cmdBaselineHelp(player)
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BSJ] BASELINE COMMAND HELP")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("VIEWING:")
    BurdJournals.debugPrint("  /bsjbaseline view              - Show all baseline data")
    BurdJournals.debugPrint("  /bsjbaseline dump              - Same as view")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("SETTING VALUES:")
    BurdJournals.debugPrint("  /bsjbaseline set skill:Name:Level   - Set skill baseline (e.g., skill:Carpentry:3)")
    BurdJournals.debugPrint("  /bsjbaseline set trait:Name         - Add trait to baseline (e.g., trait:Athletic)")
    BurdJournals.debugPrint("  /bsjbaseline set recipe:Name        - Add recipe to baseline")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("  Shorthand: /bsjbaseline skill:Carpentry:3")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("REMOVING VALUES:")
    BurdJournals.debugPrint("  /bsjbaseline remove skill:Name      - Remove skill from baseline")
    BurdJournals.debugPrint("  /bsjbaseline remove trait:Name      - Remove trait from baseline")
    BurdJournals.debugPrint("  /bsjbaseline remove recipe:Name     - Remove recipe from baseline")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("BULK OPERATIONS:")
    BurdJournals.debugPrint("  /bsjbaseline clear [type]           - Clear baseline (all, skills, traits, recipes)")
    BurdJournals.debugPrint("  /bsjbaseline copy [type]            - Copy current state as baseline")
    BurdJournals.debugPrint("  /bsjbaseline recalculate            - Recalc from profession/starting traits")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("SKILL ALIASES:")
    BurdJournals.debugPrint("  carp=Carpentry, fit=Fitness, str=Strength, elec=Electricity, etc.")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("EXAMPLES:")
    BurdJournals.debugPrint("  /bsjbaseline set skill:Carpentry:3  - Set Carpentry baseline to Level 3")
    BurdJournals.debugPrint("  /bsjbaseline set trait:Athletic     - Add Athletic to trait baseline")
    BurdJournals.debugPrint("  /bsjbaseline copy skills            - Copy current skill levels as baseline")
    BurdJournals.debugPrint("  /bsjbaseline clear all              - Clear entire baseline")
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline help printed to console.txt", {r=0.5, g=0.8, b=1}, false)
    return true
end

-- ============================================================================
-- /bsjsetskill - Set player skill levels
-- ============================================================================

function BurdJournals.Client.Debug.cmdSetSkill(player, args)
    if not args or args == "" then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjsetskill [skill] [level] or /bsjsetskill all [level]", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local parts = {}
    for part in string.gmatch(args, "%S+") do
        table.insert(parts, part)
    end
    
    local skillArg = parts[1] and string.lower(parts[1]) or ""
    local levelArg = tonumber(parts[2]) or 5
    
    -- Clamp level
    levelArg = math.max(0, math.min(10, levelArg))
    
    if not player then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] No player available", {r=1, g=0.5, b=0.3}, true)
        return true
    end
    
    if skillArg == "all" then
        local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
        for _, skillName in ipairs(allowedSkills) do
            local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
            if perk then
                player:setPerkLevelDebug(perk, levelArg)
            end
        end
        BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] All skills set to level %d", levelArg), {r=0.3, g=1, b=0.5}, true)
        return true
    end
    
    if skillArg == "passive" then
        local passiveSkills = {"Fitness", "Strength"}
        for _, skillName in ipairs(passiveSkills) do
            local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
            if perk then
                player:setPerkLevelDebug(perk, levelArg)
            end
        end
        BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] Passive skills set to level %d", levelArg), {r=0.3, g=1, b=0.5}, true)
        return true
    end
    
    if skillArg == "reset" then
        BurdJournals.Client.Debug.cmdReset(player, "skills")
        return true
    end
    
    -- Try to find specific skill
    local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
    for _, skillName in ipairs(allowedSkills) do
        if string.lower(skillName) == skillArg then
            local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
            if perk then
                player:setPerkLevelDebug(perk, levelArg)
                BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] %s set to level %d", skillName, levelArg), {r=0.3, g=1, b=0.5}, true)
                return true
            end
        end
    end
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown skill: " .. skillArg, {r=1, g=0.5, b=0.3}, true)
    return true
end

-- ============================================================================
-- /bsjgive - Spawn test journals
-- ============================================================================

-- Parse /bsjgive command modifiers
function BurdJournals.Client.Debug.parseGiveModifiers(argsStr)
    local result = {
        journalType = "filled",
        skills = {},
        traits = {},
        recipes = {},
        stats = {},
        owner = nil,
        empty = false,
        preset = nil,
        forceCurseType = nil,
        forceCurseTraitId = nil,
        forceCurseSkillName = nil,
        cursedUnleashed = false,
        forgetSlot = nil,
        cursedSealSoundEvent = nil,
    }
    
    if not argsStr or argsStr == "" then
        return result
    end
    
    -- Split by spaces (but respect that some values might have colons)
    local parts = {}
    for part in string.gmatch(argsStr, "%S+") do
        table.insert(parts, part)
    end
    
    for i, part in ipairs(parts) do
        local lowerPart = string.lower(part)
        
        -- Journal type
        if lowerPart == "blank" or lowerPart == "filled" or lowerPart == "worn" or lowerPart == "bloody" or lowerPart == "cursed" or lowerPart == "all" then
            result.journalType = lowerPart
        
        -- Empty flag
        elseif lowerPart == "empty" then
            result.empty = true
        
        -- Preset
        elseif string.match(lowerPart, "^preset:") then
            result.preset = string.sub(part, 8)
        
        -- Owner
        elseif string.match(lowerPart, "^owner:") then
            result.owner = string.sub(part, 7)

        -- Cursed controls
        elseif lowerPart == "unleashed" then
            result.cursedUnleashed = true
        elseif lowerPart == "dormant" then
            result.cursedUnleashed = false
        elseif lowerPart == "forgetslot" then
            result.forgetSlot = true
        elseif lowerPart == "noforgetslot" then
            result.forgetSlot = false
        elseif string.match(lowerPart, "^forcecurse:") then
            result.forceCurseType = string.lower(string.sub(part, 12))
        elseif string.match(lowerPart, "^curse:") then
            result.forceCurseType = string.lower(string.sub(part, 7))
        elseif string.match(lowerPart, "^forcetrait:") then
            local traitId = string.sub(part, 12)
            if traitId and traitId ~= "" then
                result.forceCurseTraitId = traitId
            end
        elseif string.match(lowerPart, "^forceskill:") then
            local skillName = string.sub(part, 12)
            if skillName and skillName ~= "" then
                result.forceCurseSkillName = skillName
            end
        elseif string.match(lowerPart, "^sealsound:") then
            local eventName = string.sub(part, 11)
            if eventName and eventName ~= "" then
                if string.lower(eventName) == "none" then
                    result.cursedSealSoundEvent = "none"
                elseif string.lower(eventName) == "default" then
                    result.cursedSealSoundEvent = nil
                else
                    result.cursedSealSoundEvent = eventName
                end
            end

        -- Single skill: skill:Name:Level or skill:Name:Level:XP
        elseif string.match(lowerPart, "^skill:") then
            local skillPart = string.sub(part, 7)
            local skillParts = {}
            for sp in string.gmatch(skillPart, "[^:]+") do
                table.insert(skillParts, sp)
            end
            if #skillParts >= 2 then
                local skillName = skillParts[1]
                local level = tonumber(skillParts[2]) or 5
                local xp = skillParts[3] and tonumber(skillParts[3]) or nil
                table.insert(result.skills, {name = skillName, level = level, xp = xp})
            end
        
        -- Multiple skills: skills:Name:Level,Name:Level
        elseif string.match(lowerPart, "^skills:") then
            local skillsPart = string.sub(part, 8)
            for entry in string.gmatch(skillsPart, "[^,]+") do
                local skillParts = {}
                for sp in string.gmatch(entry, "[^:]+") do
                    table.insert(skillParts, sp)
                end
                if #skillParts >= 2 then
                    local skillName = skillParts[1]
                    local level = tonumber(skillParts[2]) or 5
                    local xp = skillParts[3] and tonumber(skillParts[3]) or nil
                    table.insert(result.skills, {name = skillName, level = level, xp = xp})
                end
            end
        
        -- Single trait: trait:Name
        elseif string.match(lowerPart, "^trait:") then
            local traitName = string.sub(part, 7)
            table.insert(result.traits, traitName)
        
        -- Multiple traits: traits:Name,Name,Name
        elseif string.match(lowerPart, "^traits:") then
            local traitsPart = string.sub(part, 8)
            for entry in string.gmatch(traitsPart, "[^,]+") do
                table.insert(result.traits, entry)
            end
        
        -- Single recipe: recipe:Name
        elseif string.match(lowerPart, "^recipe:") then
            local recipeName = string.sub(part, 8)
            table.insert(result.recipes, recipeName)
        
        -- Multiple recipes: recipes:Name,Name
        elseif string.match(lowerPart, "^recipes:") then
            local recipesPart = string.sub(part, 9)
            for entry in string.gmatch(recipesPart, "[^,]+") do
                table.insert(result.recipes, entry)
            end
        
        -- Stat: stat:Name:Value
        elseif string.match(lowerPart, "^stat:") then
            local statPart = string.sub(part, 6)
            local statParts = {}
            for sp in string.gmatch(statPart, "[^:]+") do
                table.insert(statParts, sp)
            end
            if #statParts >= 2 then
                local statName = statParts[1]
                local value = tonumber(statParts[2]) or 0
                result.stats[statName] = value
            end
        end
    end
    
    return result
end

-- Apply preset configurations
function BurdJournals.Client.Debug.applyPreset(result, preset)
    local presetLower = string.lower(preset)
    
    if presetLower == "maxpassive" then
        result.journalType = "worn"
        result.skills = {
            {name = "Fitness", level = 10, xp = 450000},
            {name = "Strength", level = 10, xp = 450000}
        }
    elseif presetLower == "maxskills" then
        result.journalType = "filled"
        local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
        for _, skillName in ipairs(allowedSkills) do
            table.insert(result.skills, {name = skillName, level = 10})
        end
    elseif presetLower == "allpositive" or presetLower == "alltraits" then
        result.journalType = "bloody"
        -- Add common positive traits
        local positiveTraits = {"Athletic", "Strong", "FastLearner", "Organized", "Lucky", "Brave", "Outdoorsman", "LightEater", "FastReader", "ThickSkinned"}
        for _, trait in ipairs(positiveTraits) do
            table.insert(result.traits, trait)
        end
    elseif presetLower == "allnegative" or presetLower == "negative" then
        result.journalType = "bloody"
        -- Add common negative traits for testing
        local negativeTraits = {"Conspicuous", "Cowardly", "SlowLearner", "SlowReader", "Clumsy", "Disorganized", "Unlucky"}
        for _, trait in ipairs(negativeTraits) do
            table.insert(result.traits, trait)
        end
    end
    
    return result
end

-- Standard skill XP thresholds (exact values, no buffer)
-- These are the cumulative XP needed to BE AT each level
-- Standard (non-passive) skill XP thresholds from PZ wiki
-- Per-level: 75, 150, 300, 750, 1500, 3000, 4500, 6000, 7500, 9000
BurdJournals.Client.Debug.XP_THRESHOLDS = {
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

-- Passive skill (Fitness/Strength) XP thresholds from PZ wiki
-- These are CUMULATIVE totals to reach each level
-- PZ's getTotalXpForLevel() returns incorrect values for passive skills
BurdJournals.Client.Debug.PASSIVE_XP_THRESHOLDS = {
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

-- Calculate XP for a skill level with optional extra XP
-- Returns the minimum XP to BE at that level, plus any extra XP
-- Uses verified XP thresholds for passive skills (Fitness/Strength)
-- @param skillName: The skill name
-- @param level: The target level (0-10)
-- @param extraXP: Optional extra XP to add on top of the level threshold (default 0)
function BurdJournals.Client.Debug.getXPForLevel(skillName, level, extraXP)
    if not level or level < 0 then return 0 end
    if level > 10 then level = 10 end
    extraXP = extraXP or 0
    
    -- Use our verified threshold tables for consistent results
    local isPassive = (skillName == "Fitness" or skillName == "Strength")
    local thresholds = isPassive and BurdJournals.Client.Debug.PASSIVE_XP_THRESHOLDS or BurdJournals.Client.Debug.XP_THRESHOLDS
    
    local baseXP = thresholds[level] or 0
    local totalXP = baseXP + extraXP
    BurdJournals.debugPrint("[BurdJournals] DEBUG getXPForLevel: " .. tostring(skillName) .. " level " .. level .. " = " .. totalXP .. " (base=" .. baseXP .. " + extra=" .. extraXP .. ", passive=" .. tostring(isPassive) .. ")")
    return totalXP
end

-- Get the valid XP range for a skill at a given level
-- Returns {min = threshold, max = nextThreshold - 1, maxExtra = max - min}
-- This is used for validating extra XP input in the debug spawner UI
-- Uses verified XP thresholds for passive skills (Fitness/Strength)
-- @param skillName: The skill name
-- @param level: The target level (0-10)
function BurdJournals.Client.Debug.getXPRangeForLevel(skillName, level)
    if not level or level < 0 then return {min = 0, max = 0, maxExtra = 0} end
    if level > 10 then level = 10 end
    
    -- Use our verified threshold tables for consistent results
    local isPassive = (skillName == "Fitness" or skillName == "Strength")
    local thresholds = isPassive and BurdJournals.Client.Debug.PASSIVE_XP_THRESHOLDS or BurdJournals.Client.Debug.XP_THRESHOLDS
    
    local minXP = 0
    local maxXP = 0
    
    if level == 0 then
        minXP = 0
        maxXP = (thresholds[1] or 75) - 1
    elseif level < 10 then
        minXP = thresholds[level] or 0
        maxXP = (thresholds[level + 1] or (minXP + 150)) - 1
    else
        -- Level 10: min = threshold[10], max = some reasonable cap
        minXP = thresholds[10] or 0
        maxXP = math.floor(minXP * 1.5)  -- Allow up to 50% extra for flexibility
    end
    
    return {
        min = minXP,
        max = maxXP,
        maxExtra = math.max(0, maxXP - minXP)
    }
end

-- Calculate the skill level from XP amount
-- Uses verified XP thresholds for passive skills (Fitness/Strength)
function BurdJournals.Client.Debug.getLevelFromXP(skillName, xp)
    if not xp or xp < 0 then return 0 end
    
    -- Use our verified threshold tables for consistent results
    local isPassive = (skillName == "Fitness" or skillName == "Strength")
    local thresholds = isPassive and BurdJournals.Client.Debug.PASSIVE_XP_THRESHOLDS or BurdJournals.Client.Debug.XP_THRESHOLDS
    
    -- Check from level 10 down to 1
    for l = 10, 1, -1 do
        local threshold = thresholds[l] or 0
        if xp >= threshold then
            return l
        end
    end
    return 0
end

-- Spawn a journal with specified content
function BurdJournals.Client.Debug.spawnJournal(player, params)
    if not player then return false end
    
    local journalType = params.journalType or "filled"
    local cursedUnleashed = params.cursedUnleashed == true
    local spawnProfile = tostring(params.spawnProfile or "normal")
    if spawnProfile ~= "debug" then
        spawnProfile = "normal"
    end
    local isDebugProfile = spawnProfile == "debug"

    local function normalizeOriginMode(mode)
        local value = tostring(mode or "auto")
        if value == "personal" or value == "found" or value == "world" or value == "zombie" then
            return value
        end
        return "auto"
    end

    local function getDefaultOriginModeForType(t)
        local journalKind = tostring(t or "filled")
        if journalKind == "worn" then
            return "found"
        end
        if journalKind == "bloody" or journalKind == "cursed" then
            return "zombie"
        end
        return "personal"
    end

    local originMode = normalizeOriginMode(params.originMode)
    if originMode == "auto" then
        originMode = getDefaultOriginModeForType(journalType)
    end
    
    -- In dedicated server MP mode, create journal SERVER-SIDE for proper persistence
    -- Server-created items survive restarts and mod updates
    if isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals] DEBUG: MP mode detected - creating journal server-side for persistence")
        
        -- Convert params.skills from array to table format expected by server
        local skillsTable = {}
        for _, skillData in ipairs(params.skills or {}) do
            local xp = skillData.xp
            local extraXP = skillData.extraXP or 0
            BurdJournals.debugPrint("[BurdJournals] DEBUG spawnJournal: Processing skill " .. tostring(skillData.name) .. 
                  " level=" .. tostring(skillData.level) .. " extraXP=" .. tostring(extraXP) .. " xp=" .. tostring(xp))
            if not xp then
                -- Calculate XP with optional extraXP
                xp = BurdJournals.Client.Debug.getXPForLevel(skillData.name, skillData.level, extraXP)
                BurdJournals.debugPrint("[BurdJournals] DEBUG spawnJournal: Calculated XP = " .. tostring(xp))
            end
            skillsTable[skillData.name] = {
                xp = xp,
                level = skillData.level
            }
        end
        
        -- Convert params.traits from array to table
        local traitsTable = {}
        for _, traitName in ipairs(params.traits or {}) do
            traitsTable[traitName] = true
        end
        
        -- Convert params.recipes from array to table
        local recipesTable = {}
        for _, recipeName in ipairs(params.recipes or {}) do
            recipesTable[recipeName] = true
        end

        local statsTable = {}
        for statName, value in pairs(params.stats or {}) do
            statsTable[statName] = value
        end
        
        -- Send to server for authoritative creation
        sendClientCommand(player, "BurdJournals", "debugSpawnJournal", {
            journalType = journalType,
            spawnProfile = spawnProfile,
            originMode = originMode,
            ownerMode = tostring(params.ownerMode or "none"),
            owner = params.owner or params.ownerCharacterName,
            skills = skillsTable,
            traits = traitsTable,
            recipes = recipesTable,
            stats = statsTable,
            isPlayerJournal = params.isPlayerCreated,  -- Pass this flag for proper claim handling
            ownerSteamId = params.ownerSteamId,
            ownerUsername = params.ownerUsername,
            ownerCharacterName = params.ownerCharacterName,
            -- Profession and flavor text
            profession = params.profession,
            professionName = params.professionName,
            professionFlavorKey = params.professionFlavorKey,
            randomProfession = params.randomProfession,
            noProfession = params.noProfession,
            isCustomProfession = params.isCustomProfession,
            flavorText = params.flavorText,
            ageHours = params.ageHours,
            conditionOverride = params.conditionOverride,
            forceCurseType = params.forceCurseType,
            forceCurseTraitId = params.forceCurseTraitId,
            forceCurseSkillName = params.forceCurseSkillName,
            cursedUnleashed = cursedUnleashed,
            forgetSlot = params.forgetSlot,
            cursedSealSoundEvent = params.cursedSealSoundEvent,
        })
        
        -- Return true - actual item will appear when server responds
        return true
    end
    
    -- SP mode or Coop host: Create locally for immediate visibility
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Creating journal client-side (SP/host mode)")
    local inventory = player:getInventory()
    if not inventory then return false end
    
    -- Determine item type (correct item IDs from items_burdJournals.txt)
    local itemType
    if journalType == "blank" then
        itemType = "BurdJournals.BlankSurvivalJournal"
    elseif journalType == "worn" then
        itemType = "BurdJournals.FilledSurvivalJournal_Worn"
    elseif journalType == "bloody" then
        itemType = "BurdJournals.FilledSurvivalJournal_Bloody"
    elseif journalType == "cursed" then
        if cursedUnleashed then
            itemType = "BurdJournals.FilledSurvivalJournal_Bloody"
        else
            itemType = BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal"
        end
    else
        itemType = "BurdJournals.FilledSurvivalJournal"
    end
    
    -- Create the item
    local item = inventory:AddItem(itemType)
    if not item then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Failed to create journal", {r=1, g=0.5, b=0.3}, true)
        return false
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
        if params.ageHours and params.ageHours > 0 then
            data.timestamp = math.max(0, worldAge - params.ageHours)
        end
        data.lastModified = worldAge
        
        -- Spawn profile controls whether this behaves like a debug artifact or a natural journal.
        data.isDebugSpawned = isDebugProfile
        data.isDebugEdited = isDebugProfile and true or nil
        data.isWritten = true       -- Mark as properly initialized
        data.journalVersion = BurdJournals.VERSION or "dev"  -- Version tracking
        data.sanitizedVersion = BurdJournals.SANITIZE_VERSION or 1  -- Prevent re-sanitization
        
        -- Initialize data containers
        data.skills = {}
        data.traits = {}
        data.recipes = {}
        data.stats = {}
        data.claims = {}  -- Per-character claims tracking
        data.claimedSkills = {}
        data.claimedTraits = {}
        data.claimedRecipes = {}
        data.claimedStats = {}
        data.claimedForgetSlot = {}
        data.forgetSlot = params.forgetSlot == true and true or nil
        data.isCursedJournal = false
        data.cursedState = nil
        data.isCursedReward = false
        data.cursedEffectType = nil
        data.cursedUnleashedByCharacterId = nil
        data.cursedUnleashedByUsername = nil
        data.cursedUnleashedAtHours = nil
        data.cursedSealSoundEvent = params.cursedSealSoundEvent
        data.cursedPendingRewards = nil
        data.cursedForcedEffectType = params.forceCurseType
        data.cursedForcedTraitId = params.forceCurseTraitId
        data.cursedForcedSkillName = params.forceCurseSkillName
        
        -- Handle owner/author assignment.
        -- Only filled journals use player assignment metadata; loot journals can keep no author.
        local ownerMode = tostring(params.ownerMode or "none")
        data.ownerMode = ownerMode
        if ownerMode == "player_assignment" and journalType == "filled" and params.ownerSteamId and params.ownerUsername then
            data.ownerSteamId = params.ownerSteamId
            data.ownerUsername = params.ownerUsername
            data.ownerCharacterName = params.ownerCharacterName or params.owner or nil
            data.author = data.ownerCharacterName
            
            -- For filled player journals, mark as player-created so they can be edited
            if journalType == "filled" and params.isPlayerCreated then
                data.isPlayerCreated = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: Created player journal assigned to: " .. data.ownerCharacterName .. " (SteamID: " .. data.ownerSteamId .. ")")
            end
        elseif ownerMode == "player_author" or ownerMode == "custom" then
            local authorName = tostring(params.owner or params.ownerCharacterName or "")
            if authorName ~= "" then
                data.ownerCharacterName = authorName
                data.author = authorName
            else
                data.ownerCharacterName = nil
                data.author = nil
            end
            data.ownerSteamId = nil
            data.ownerUsername = nil
        else
            data.ownerCharacterName = nil
            data.author = nil
            data.ownerSteamId = nil
            data.ownerUsername = nil
        end
        
        -- Mark origin for worn/bloody
        if journalType == "worn" then
            data.isWorn = true
            data.wasFromWorn = true
        elseif journalType == "bloody" then
            data.isBloody = true
            data.wasFromBloody = true
            data.hasBloodyOrigin = true
        elseif journalType == "cursed" then
            if cursedUnleashed then
                data.isBloody = true
                data.wasFromBloody = true
                data.hasBloodyOrigin = true
                data.isPlayerCreated = false
                data.isCursedReward = true
                data.cursedState = "unleashed"
                data.cursedEffectType = params.forceCurseType or "panic"
                data.cursedUnleashedByCharacterId = BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(player) or nil
                data.cursedUnleashedByUsername = player:getUsername()
                data.cursedUnleashedAtHours = worldAge
            else
                data.isCursedJournal = true
                data.cursedState = "dormant"
                data.isPlayerCreated = false
                data.isZombieJournal = true
            end
        end

        data.originMode = originMode
        if originMode == "personal" then
            data.isPlayerCreated = true
            data.sourceType = "personal"
        elseif originMode == "zombie" then
            data.isPlayerCreated = false
            data.sourceType = "zombie"
        elseif originMode == "world" then
            data.isPlayerCreated = false
            data.sourceType = "world"
        else
            data.isPlayerCreated = false
            data.sourceType = "found"
        end

        if params.conditionOverride and item.setCondition then
            local cond = math.max(1, math.min(10, math.floor(params.conditionOverride)))
            item:setCondition(cond)
            data.condition = cond
        elseif item.getCondition then
            data.condition = item:getCondition()
        end
        
        -- Handle profession for worn/bloody journals
        if (journalType == "worn" or journalType == "bloody") and not params.noProfession then
            if params.profession and params.professionName then
                -- Specific or custom profession selected
                data.profession = params.profession
                data.professionName = params.professionName
                if params.professionFlavorKey then
                    data.flavorKey = params.professionFlavorKey
                end
                local profType = params.isCustomProfession and "Custom" or "Set"
                BurdJournals.debugPrint("[BurdJournals] DEBUG: " .. profType .. " profession: " .. params.professionName)
            elseif params.randomProfession ~= false then
                -- Random profession (default for worn/bloody)
                local profId, profName, flavorKey = BurdJournals.getRandomProfession()
                if profId then
                    data.profession = profId
                    data.professionName = profName
                    data.flavorKey = flavorKey
                    BurdJournals.debugPrint("[BurdJournals] DEBUG: Random profession: " .. profName)
                end
            end
        end
        
        -- Handle custom flavor text (overrides profession flavor)
        if params.flavorText then
            data.flavorText = params.flavorText
            data.flavorKey = nil  -- Clear the key so custom text is used
            BurdJournals.debugPrint("[BurdJournals] DEBUG: Custom flavor text: " .. params.flavorText)
        end
        
        -- Add specified skills
        -- For debug-spawned journals, store the TOTAL XP for the level (no baseline subtraction)
        -- This is consistent with MP path and ensures claiming works correctly for all levels
        for _, skillData in ipairs(params.skills) do
            local xp = skillData.xp
            if not xp then
                -- Calculate XP from level with optional extraXP
                xp = BurdJournals.Client.Debug.getXPForLevel(skillData.name, skillData.level, skillData.extraXP or 0)
            end
            data.skills[skillData.name] = {
                xp = math.max(0, xp),
                level = skillData.level
            }
            BurdJournals.debugPrint("[BurdJournals] DEBUG SP spawn: Skill " .. tostring(skillData.name) .. " level=" .. tostring(skillData.level) .. " xp=" .. tostring(xp))
        end
        
        -- Add specified traits
        for _, traitName in ipairs(params.traits) do
            data.traits[traitName] = true
        end
        
        -- Add specified recipes
        for _, recipeName in ipairs(params.recipes) do
            data.recipes[recipeName] = true
        end
        
        -- Add specified stats
        for statName, value in pairs(params.stats) do
            data.stats[statName] = {value = value}
        end

        if journalType == "cursed" and not cursedUnleashed then
            data.cursedPendingRewards = {
                uuid = data.uuid,
                author = data.author,
                profession = data.profession,
                professionName = data.professionName,
                flavorKey = data.flavorKey,
                timestamp = data.timestamp,
                skills = data.skills,
                traits = data.traits,
                recipes = data.recipes,
                stats = data.stats,
                claims = data.claims,
                claimedSkills = data.claimedSkills,
                claimedTraits = data.claimedTraits,
                claimedRecipes = data.claimedRecipes,
                claimedStats = data.claimedStats,
                forgetSlot = data.forgetSlot,
                claimedForgetSlot = data.claimedForgetSlot,
                condition = data.condition,
                cursedSealSoundEvent = data.cursedSealSoundEvent,
                cursedForcedEffectType = data.cursedForcedEffectType,
                cursedForcedTraitId = data.cursedForcedTraitId,
                cursedForcedSkillName = data.cursedForcedSkillName,
            }
            data.skills = {}
            data.traits = {}
            data.recipes = {}
            data.stats = {}
            data.forgetSlot = nil
            data.claimedForgetSlot = {}
        end
        
        -- Generate random content if not empty flag and no content specified
        if not params.empty and #params.skills == 0 and #params.traits == 0 and #params.recipes == 0 then
            -- Add some random content based on journal type
            if journalType == "worn" or journalType == "bloody" then
                -- Add 2-4 random skills
                local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
                local skillCount = ZombRand(2, 5)
                for i = 1, math.min(skillCount, #allowedSkills) do
                    local skillName = allowedSkills[ZombRand(#allowedSkills) + 1]
                    if not data.skills[skillName] then
                        local level = ZombRand(1, 6)
                        local xp = BurdJournals.Client.Debug.getXPForLevel(skillName, level)
                        data.skills[skillName] = {xp = xp, level = level}
                    end
                end
                
                -- For bloody, maybe add a trait
                if journalType == "bloody" and ZombRand(100) < 30 then
                    local randomTraits = {"Athletic", "Strong", "FastLearner", "Lucky", "Brave"}
                    local trait = randomTraits[ZombRand(#randomTraits) + 1]
                    data.traits[trait] = true
                end
            end
        end
        
        -- Update journal name and icon
        if BurdJournals.updateJournalName then
            BurdJournals.updateJournalName(item)
        end
        if BurdJournals.updateJournalIcon then
            BurdJournals.updateJournalIcon(item)
        end
        
        -- CRITICAL: Sync ModData to server for MP persistence
        if item.transmitModData then
            item:transmitModData()
            BurdJournals.debugPrint("[BurdJournals] DEBUG: Called transmitModData() for journal ID=" .. tostring(item:getID()))
        end
    end
    
    -- Force inventory UI refresh
    if inventory.setDrawDirty then
        inventory:setDrawDirty(true)
    end
    
    -- In MP, also notify server about the new item for tracking
    if isClient() and not isServer() then
        sendClientCommand(player, "BurdJournals", "debugJournalCreated", {
            journalId = item:getID(),
            journalType = journalType
        })
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG: Journal spawned successfully! ID=" .. tostring(item:getID()))
    return true, item
end

function BurdJournals.Client.Debug.cmdGive(player, args)
    local params = BurdJournals.Client.Debug.parseGiveModifiers(args)
    
    -- Apply preset if specified
    if params.preset then
        params = BurdJournals.Client.Debug.applyPreset(params, params.preset)
    end
    
    -- Handle "all" type - spawn one of each
    if params.journalType == "all" then
        local types = {"blank", "filled", "worn", "bloody", "cursed"}
        local count = 0
        for _, jtype in ipairs(types) do
            params.journalType = jtype
            local success = BurdJournals.Client.Debug.spawnJournal(player, params)
            if success then count = count + 1 end
        end
        BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] Spawned %d journals", count), {r=0.3, g=1, b=0.5}, true)
        return true
    end
    
    -- Spawn single journal
    local success, item = BurdJournals.Client.Debug.spawnJournal(player, params)
    if success then
        local skillCount = #params.skills
        local traitCount = #params.traits
        local recipeCount = #params.recipes
        local msg = string.format("[BSJ] Spawned %s journal", params.journalType)
        if skillCount > 0 or traitCount > 0 or recipeCount > 0 then
            msg = msg .. string.format(" (%d skills, %d traits, %d recipes)", skillCount, traitCount, recipeCount)
        end
        BurdJournals.Client.Debug.feedback(player, msg, {r=0.3, g=1, b=0.5}, true)
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Failed to spawn journal", {r=1, g=0.5, b=0.3}, true)
    end
    
    return true
end

-- ============================================================================
-- /bsjadmin - Admin utilities
-- ============================================================================

function BurdJournals.Client.Debug.cmdAdmin(player, args)
    -- Require admin access
    if isClient() and not isCoopHost() then
        if player then
            local accessLevel = player:getAccessLevel()
            if not accessLevel or accessLevel == "None" then
                BurdJournals.Client.Debug.feedback(player, "[BSJ] Admin access required", {r=1, g=0.5, b=0.3}, true)
                return true
            end
        end
    end
    
    if not args or args == "" then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjadmin [listcache|listsnapshots|savesnapshot|applysnapshot|playerstats|forcesync]", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local parts = {}
    for part in string.gmatch(args, "%S+") do
        table.insert(parts, part)
    end
    
    local subCmd = parts[1] and string.lower(parts[1]) or ""
    
    if subCmd == "listcache" then
        BurdJournals.Client.Debug.listBaselineCache(player)
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Requested baseline cache stats from server", {r=0.5, g=0.8, b=1}, true)
        return true
    end

    if subCmd == "listsnapshots" then
        local targetArg = parts[2]
        local payload = {
            includeDead = true,
            page = 1,
            pageSize = 50,
        }
        if targetArg and targetArg ~= "" then
            if string.find(targetArg, "^%d+$") then
                payload.steamId = targetArg
            else
                payload.targetUsername = targetArg
            end
        end
        BurdJournals.Client.Debug.listBaselineSnapshots(payload, player)
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Requested baseline snapshot list", {r=0.5, g=0.8, b=1}, true)
        return true
    end

    if subCmd == "savesnapshot" then
        local targetArg = parts[2]
        BurdJournals.Client.Debug.saveBaselineSnapshot({
            targetUsername = targetArg,
            source = "bsjadmin",
        }, player)
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Requested baseline snapshot save", {r=0.5, g=0.8, b=1}, true)
        return true
    end

    if subCmd == "applysnapshot" then
        local snapshotId = parts[2]
        local targetArg = parts[3]
        if not snapshotId or snapshotId == "" then
            BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjadmin applysnapshot <snapshotId> [target]", {r=1, g=0.7, b=0.3}, true)
            return true
        end
        BurdJournals.Client.Debug.applyBaselineSnapshot({
            snapshotId = snapshotId,
            targetUsername = targetArg,
            restoreMode = BurdJournals.BASELINE_SNAPSHOT_RESTORE_UNLOCKED,
        }, player)
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Requested baseline snapshot apply", {r=0.5, g=0.8, b=1}, true)
        return true
    end

    if subCmd == "playerstats" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("[BSJ-DEBUG] Player stats requested")
        -- This would need server-side implementation
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Player stats in console", {r=0.5, g=0.8, b=1}, true)
        return true
    end
    
    if subCmd == "forcesync" then
        -- Force sync all journals in inventory
        if player then
            local inventory = player:getInventory()
            if inventory then
                local items = inventory:getItems()
                local syncCount = 0
                for i = 0, items:size() - 1 do
                    local item = items:get(i)
                    if BurdJournals.isJournal and BurdJournals.isJournal(item) then
                        if item.transmitModData then
                            item:transmitModData()
                            syncCount = syncCount + 1
                        end
                    end
                end
                BurdJournals.Client.Debug.feedback(player, string.format("[BSJ] Force synced %d journals", syncCount), {r=0.3, g=1, b=0.5}, true)
            end
        end
        return true
    end
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown admin command: " .. subCmd, {r=1, g=0.5, b=0.3}, true)
    return true
end

-- ============================================================================
-- /bsjdebug - Open debug panel (placeholder for UI implementation)
-- ============================================================================

function BurdJournals.Client.Debug.cmdDebugPanel(player, args)
    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.Open then
        BurdJournals.UI.DebugPanel.Open(player)
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Debug panel opened", {r=0.3, g=1, b=0.5}, false)
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Debug panel not loaded", {r=1, g=0.5, b=0.3}, true)
    end
    return true
end

-- ============================================================================
-- /bsjhelp - Show available commands
-- ============================================================================

BurdJournals.Client.Debug.HelpTopics = {
    -- General commands
    general = {
        title = "General Commands",
        commands = {
            {cmd = "/bsjhelp [topic]", desc = "Show this help. Topics: general, debug, give, journal, cursed, admin"},
            {cmd = "/clearbaseline", desc = "Clear skill baseline (admin in MP). Aliases: /resetbaseline, /journalreset"},
            {cmd = "/journaldiag", desc = "Print diagnostic report to console. Aliases: /jdiag"},
            {cmd = "/journalscan", desc = "Scan journals in inventory. Aliases: /jscan"},
        }
    },
    
    -- Debug commands
    debug = {
        title = "Debug Commands (requires AllowDebugCommands or -debug flag)",
        commands = {
            {cmd = "/bsjverbose [on|off|status]", desc = "Toggle verbose debug logging"},
            {cmd = "/bsjdump [type]", desc = "Dump debug info. Types: skills, traits, baseline, journal, config, recipes, all"},
            {cmd = "/bsjdebug", desc = "Open Debug Center UI"},
        }
    },
    
    -- Give/spawn commands
    give = {
        title = "Journal Spawning Commands",
        commands = {
            {cmd = "/bsjgive [type]", desc = "Spawn journal. Types: blank, filled, worn, bloody, cursed, all"},
            {cmd = "/bsjgive [type] skill:[name]:[level]", desc = "Spawn with specific skill"},
            {cmd = "/bsjgive [type] trait:[name]", desc = "Spawn with specific trait"},
            {cmd = "/bsjgive [type] traits:[n1],[n2]", desc = "Spawn with multiple traits"},
            {cmd = "/bsjgive [type] skills:[n]:[l],[n]:[l]", desc = "Spawn with multiple skills"},
            {cmd = "/bsjgive [type] recipe:[name]", desc = "Spawn with specific recipe"},
            {cmd = "/bsjgive [type] stat:[name]:[value]", desc = "Spawn with stat (zombieKills, hoursSurvived)"},
            {cmd = "/bsjgive [type] owner:[name]", desc = "Set journal owner name"},
            {cmd = "/bsjgive [type] empty", desc = "Spawn without random content"},
            {cmd = "/bsjgive cursed [dormant|unleashed] [forcecurse:type] [forgetslot] [sealsound:event]", desc = "Spawn cursed journal variants"},
            {cmd = "/bsjgive preset:[name]", desc = "Use preset: maxpassive, maxskills, allpositive, allnegative"},
        }
    },
    
    -- Journal types
    journal = {
        title = "Journal Types",
        commands = {
            {cmd = "blank", desc = "Empty journal for recording your progress"},
            {cmd = "filled", desc = "Clean filled journal (player journal)"},
            {cmd = "worn", desc = "World-found journal with skills/recipes"},
            {cmd = "bloody", desc = "Zombie-drop journal with skills/traits/recipes"},
            {cmd = "cursed", desc = "Dormant cursed journal or unleashed cursed reward"},
        }
    },
    
    -- Bloody journal specific
    bloody = {
        title = "Bloody Journal Commands",
        commands = {
            {cmd = "/bsjgive bloody", desc = "Spawn bloody journal with random content"},
            {cmd = "/bsjgive bloody trait:Conspicuous", desc = "Spawn with specific trait"},
            {cmd = "/bsjgive bloody traits:Athletic,Strong", desc = "Spawn with multiple traits"},
            {cmd = "/bsjgive bloody skill:Fitness:10", desc = "Spawn with Level 10 Fitness"},
            {cmd = "/bsjgive preset:allnegative", desc = "Spawn bloody with all negative traits"},
            {cmd = "/bsjgive preset:allpositive", desc = "Spawn bloody with all positive traits"},
        }
    },
    
    -- Worn journal specific
    worn = {
        title = "Worn Journal Commands",
        commands = {
            {cmd = "/bsjgive worn", desc = "Spawn worn journal with random content"},
            {cmd = "/bsjgive worn skill:Carpentry:5", desc = "Spawn with specific skill"},
            {cmd = "/bsjgive worn recipe:MakeMetalWall", desc = "Spawn with specific recipe"},
            {cmd = "/bsjgive worn empty skill:Fitness:10 skill:Strength:10", desc = "Only specific skills"},
            {cmd = "/bsjgive preset:maxpassive", desc = "Spawn worn with max Fitness & Strength"},
        }
    },

    cursed = {
        title = "Cursed Journal Commands",
        commands = {
            {cmd = "/bsjgive cursed", desc = "Spawn dormant cursed journal"},
            {cmd = "/bsjgive cursed unleashed", desc = "Spawn unleashed cursed reward journal"},
            {cmd = "/bsjgive cursed forcecurse:panic", desc = "Force curse type to Ambush on first unleash"},
            {cmd = "/bsjgive cursed forcecurse:barbed_seal", desc = "Force Barbed Seal hand-laceration curse"},
            {cmd = "/bsjgive cursed forcecurse:jammed_breath", desc = "Force Jammed Breath endurance/panic spike curse"},
            {cmd = "/bsjgive cursed forcecurse:hexed_tooling", desc = "Force Hexed Tooling item-condition curse"},
            {cmd = "/bsjgive cursed forcecurse:torn_gear", desc = "Force Torn Gear clothing-hole curse"},
            {cmd = "/bsjgive cursed forcecurse:seasonal_wave", desc = "Force Seasonal Wave heat/cold spike curse"},
            {cmd = "/bsjgive cursed forcecurse:pantsed", desc = "Force Pants'd unequip-bottoms curse"},
            {cmd = "/bsjgive cursed forcecurse:gain_negative_trait forcetrait:Clumsy", desc = "Force specific trait target for trait curses"},
            {cmd = "/bsjgive cursed forcecurse:lose_skill_level forceskill:Carpentry", desc = "Force specific skill target for skill-down curse"},
            {cmd = "/bsjgive cursed sealsound:PaperRip", desc = "Set seal-break sound event (or sealsound:none)"},
            {cmd = "/bsjgive cursed forgetslot", desc = "Guarantee forget slot on cursed rewards"},
        }
    },
    
    -- Skill commands
    skills = {
        title = "Skill Commands",
        commands = {
            {cmd = "/bsjsetskill [skill] [level]", desc = "Set skill to level (0-10)"},
            {cmd = "/bsjsetskill all [level]", desc = "Set ALL skills to level"},
            {cmd = "/bsjsetskill passive [level]", desc = "Set Fitness & Strength to level"},
            {cmd = "/bsjsetskill reset", desc = "Reset skills to baseline"},
            {cmd = "/bsjreset skills", desc = "Reset all skills to baseline"},
        }
    },
    
    -- Reset commands  
    reset = {
        title = "Reset Commands",
        commands = {
            {cmd = "/bsjreset skills", desc = "Reset all skills to baseline levels"},
            {cmd = "/bsjreset traits", desc = "Remove all non-starting traits"},
            {cmd = "/bsjreset baseline", desc = "Clear baseline (redirects to /bsjbaseline clear)"},
            {cmd = "/bsjreset journal", desc = "Clear data from held journal"},
            {cmd = "/bsjreset all", desc = "Full character reset"},
        }
    },
    
    -- Baseline management
    baseline = {
        title = "Baseline Management Commands",
        commands = {
            {cmd = "/bsjbaseline view", desc = "Show all baseline data"},
            {cmd = "/bsjbaseline set skill:Name:Level", desc = "Set skill baseline (e.g., skill:Carp:3)"},
            {cmd = "/bsjbaseline set trait:Name", desc = "Add trait to baseline"},
            {cmd = "/bsjbaseline set recipe:Name", desc = "Add recipe to baseline"},
            {cmd = "/bsjbaseline remove skill:Name", desc = "Remove skill from baseline"},
            {cmd = "/bsjbaseline remove trait:Name", desc = "Remove trait from baseline"},
            {cmd = "/bsjbaseline clear [type]", desc = "Clear baseline (all/skills/traits/recipes)"},
            {cmd = "/bsjbaseline copy [type]", desc = "Copy current state as baseline"},
            {cmd = "/bsjbaseline recalculate", desc = "Recalc from profession/starting traits"},
        }
    },
    
    -- Admin commands
    admin = {
        title = "Admin Commands (requires admin access)",
        commands = {
            {cmd = "/bsjadmin listcache", desc = "Show server baseline cache/archive/snapshot counts"},
            {cmd = "/bsjadmin listsnapshots [target|steamid]", desc = "List baseline snapshots for a player/SteamID"},
            {cmd = "/bsjadmin savesnapshot [target]", desc = "Capture a baseline snapshot for target/current player"},
            {cmd = "/bsjadmin applysnapshot <snapshotId> [target]", desc = "Apply a baseline snapshot as active baseline for target/current player"},
            {cmd = "/bsjadmin playerstats", desc = "Show connected player journal stats"},
            {cmd = "/bsjadmin forcesync", desc = "Force sync all journals in inventory"},
        }
    },
    
    -- Presets
    presets = {
        title = "Available Presets",
        commands = {
            {cmd = "maxpassive", desc = "Worn journal with Fitness:10 + Strength:10"},
            {cmd = "maxskills", desc = "Filled journal with all skills at level 10"},
            {cmd = "allpositive", desc = "Bloody journal with common positive traits"},
            {cmd = "allnegative", desc = "Bloody journal with negative traits for testing"},
        }
    },
}

-- Aliases for help topics
BurdJournals.Client.Debug.HelpAliases = {
    ["spawn"] = "give",
    ["create"] = "give",
    ["journals"] = "journal",
    ["types"] = "journal",
    ["skill"] = "skills",
    ["trait"] = "bloody",
    ["traits"] = "bloody",
    ["recipe"] = "worn",
    ["recipes"] = "worn",
    ["curses"] = "cursed",
    ["preset"] = "presets",
    ["commands"] = "general",
    ["all"] = "general",
    [""] = "general",
    ["base"] = "baseline",
    ["baselines"] = "baseline",
}

function BurdJournals.Client.Debug.cmdHelp(player, args)
    local topic = args and string.lower(args) or ""
    
    -- Check for alias
    if BurdJournals.Client.Debug.HelpAliases[topic] then
        topic = BurdJournals.Client.Debug.HelpAliases[topic]
    end
    
    -- If no topic or unknown topic, show overview
    local helpData = BurdJournals.Client.Debug.HelpTopics[topic]
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BSJ] COMMAND HELP")
    BurdJournals.debugPrint("================================================================================")
    
    if helpData then
        -- Show specific topic
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("--- " .. helpData.title .. " ---")
        BurdJournals.debugPrint("")
        for _, cmd in ipairs(helpData.commands) do
            BurdJournals.debugPrint(string.format("  %-45s %s", cmd.cmd, cmd.desc))
        end
    else
        -- Show overview of all topics
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("Available help topics: /bsjhelp [topic]")
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("  general    - Basic commands (clearbaseline, journaldiag, etc.)")
        BurdJournals.debugPrint("  debug      - Debug commands (dump, test, verbose)")
        BurdJournals.debugPrint("  give       - Journal spawning syntax")
        BurdJournals.debugPrint("  journal    - Journal types explanation")
        BurdJournals.debugPrint("  bloody     - Bloody journal examples")
        BurdJournals.debugPrint("  worn       - Worn journal examples")
        BurdJournals.debugPrint("  cursed     - Cursed journal examples")
        BurdJournals.debugPrint("  skills     - Skill manipulation commands")
        BurdJournals.debugPrint("  baseline   - Baseline management (set, copy, clear)")
        BurdJournals.debugPrint("  reset      - Reset commands")
        print("  admin      - Admin-only commands")
        BurdJournals.debugPrint("  presets    - Available spawn presets")
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("Examples:")
        BurdJournals.debugPrint("  /bsjhelp give      - Show journal spawning help")
        BurdJournals.debugPrint("  /bsjhelp bloody    - Show bloody journal examples")
        BurdJournals.debugPrint("  /bsjhelp baseline  - Show baseline management help")
    end
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
    
    BurdJournals.Client.Debug.feedback(player, "[BSJ] Help printed to console.txt", {r=0.5, g=0.8, b=1}, false)
    
    return true
end

-- ============================================================================
-- Debug Command Router
-- ============================================================================

function BurdJournals.Client.Debug.onChatCommand(command)
    if not command then return false end
    
    local cmd = string.lower(command)
    local player = getPlayer()
    
    -- Extract command and args
    local cmdName, args = string.match(command, "^(/[%w]+)%s*(.*)")
    if not cmdName then
        cmdName = command
        args = ""
    end
    cmdName = string.lower(cmdName)
    
    -- /bsjhelp - always allow (it's just help)
    if cmdName == "/bsjhelp" then
        return BurdJournals.Client.Debug.cmdHelp(player, args)
    end
    
    -- /bsjverbose - always allow (it's just logging toggle)
    if cmdName == "/bsjverbose" then
        return BurdJournals.Client.Debug.cmdVerbose(player, args)
    end
    
    -- All other debug commands require permission check
    local debugCommands = {
        ["/bsjdump"] = BurdJournals.Client.Debug.cmdDump,
        ["/bsjreset"] = BurdJournals.Client.Debug.cmdReset,
        ["/bsjbaseline"] = BurdJournals.Client.Debug.cmdBaseline,
        ["/bsjsetskill"] = BurdJournals.Client.Debug.cmdSetSkill,
        ["/bsjgive"] = BurdJournals.Client.Debug.cmdGive,
        ["/bsjadmin"] = BurdJournals.Client.Debug.cmdAdmin,
        ["/bsjdebug"] = BurdJournals.Client.Debug.cmdDebugPanel,
    }
    
    local handler = debugCommands[cmdName]
    if handler then
        -- Check if debug commands are allowed
        if not BurdJournals.Client.Debug.isAllowed(player) then
            if player then
                player:Say("[BSJ] Debug commands disabled. Enable AllowDebugCommands in sandbox options or use -debug flag.")
            end
            return true
        end
        
        return handler(player, args)
    end
    
    return false
end

-- Hook debug commands (legacy - may not work in all PZ versions)
if Events.OnCustomCommand then
    Events.OnCustomCommand.Add(BurdJournals.Client.Debug.onChatCommand)
end

BurdJournals.debugPrint("[BurdJournals] Debug command system loaded - use /bsjverbose to enable logging")

-- ============================================================================
-- CHAT COMMAND HOOK (ISChat integration)
-- This properly hooks into PZ's chat system for /commands
-- ============================================================================

BurdJournals.Client.ChatHook = {}

-- Master command router for all BSJ commands
function BurdJournals.Client.ChatHook.processCommand(command)
    if not command or type(command) ~= "string" then return false end
    if string.sub(command, 1, 1) ~= "/" then return false end
    
    local cmdLower = string.lower(command)
    
    -- Check if it's a BSJ command
    local isBSJCommand = string.sub(cmdLower, 1, 4) == "/bsj" or
                         cmdLower == "/clearbaseline" or
                         cmdLower == "/resetbaseline" or
                         cmdLower == "/journalreset" or
                         cmdLower == "/journaldiag" or
                         cmdLower == "/jdiag" or
                         cmdLower == "/burdjournaldiag" or
                         cmdLower == "/journalscan" or
                         cmdLower == "/jscan"
    
    if not isBSJCommand then return false end
    
    -- Route to appropriate handler
    if BurdJournals.Client.onChatCommand and BurdJournals.Client.onChatCommand(command) then
        return true
    end
    
    if BurdJournals.Client.Diagnostics and BurdJournals.Client.Diagnostics.onChatCommand then
        if BurdJournals.Client.Diagnostics.onChatCommand(command) then
            return true
        end
    end
    
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.onChatCommand then
        if BurdJournals.Client.Debug.onChatCommand(command) then
            return true
        end
    end
    
    return false
end

-- Hook into ISChat.onCommandEntered
local function hookISChat()
    if not ISChat then
        BurdJournals.debugPrint("[BurdJournals] ISChat not available yet, deferring hook...")
        return false
    end
    
    -- Store original function
    local originalOnCommandEntered = ISChat.onCommandEntered
    
    ISChat.onCommandEntered = function(self)
        local command = ISChat.instance and ISChat.instance.textEntry and ISChat.instance.textEntry:getText()
        
        if command and BurdJournals.Client.ChatHook.processCommand(command) then
            -- Clear the text entry and don't send to chat
            if ISChat.instance and ISChat.instance.textEntry then
                ISChat.instance.textEntry:setText("")
            end
            -- Unfocus chat
            if ISChat.instance then
                ISChat.instance:unfocus()
            end
            return
        end
        
        -- Call original function for non-BSJ commands
        if originalOnCommandEntered then
            return originalOnCommandEntered(self)
        end
    end
    
    BurdJournals.debugPrint("[BurdJournals] ISChat command hook installed successfully")
    return true
end

-- Try to hook immediately, or defer to game start
if ISChat then
    hookISChat()
else
    Events.OnGameStart.Add(function()
        -- Delay slightly to ensure ISChat is fully loaded
        local tickCount = 0
        local function tryHook()
            tickCount = tickCount + 1
            if hookISChat() or tickCount > 100 then
                Events.OnTick.Remove(tryHook)
            end
        end
        Events.OnTick.Add(tryHook)
    end)
end

-- ============================================================================
-- DEBUG CONTEXT MENU
-- Right-click menu options for journals when debug is enabled
-- ============================================================================

BurdJournals.Client.DebugContextMenu = {}

-- Store journal reference for edit callbacks
BurdJournals.Client.DebugContextMenu.currentJournal = nil

function BurdJournals.Client.DebugContextMenu.isEnabled()
    -- Check if debug commands are allowed
    local debugEnabled = getDebug and getDebug() or false
    local sandboxEnabled = SandboxVars and SandboxVars.BurdJournals and SandboxVars.BurdJournals.AllowDebugCommands
    return debugEnabled or sandboxEnabled
end

-- Callback functions for context menu (PZ requires named functions, not inline)
BurdJournals.Client.DebugContextMenu.onOpenDebugPanel = function(playerObj)
    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.Open then
        BurdJournals.UI.DebugPanel.Open(playerObj)
    else
        BurdJournals.debugPrint("[BSJ] Debug Panel not loaded")
    end
end

BurdJournals.Client.DebugContextMenu.onDumpSkills = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdDump then
        BurdJournals.Client.Debug.cmdDump(playerObj, "skills")
    end
end

BurdJournals.Client.DebugContextMenu.onDumpBaseline = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdDump then
        BurdJournals.Client.Debug.cmdDump(playerObj, "baseline")
    end
end

BurdJournals.Client.DebugContextMenu.onViewBaseline = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdBaseline then
        BurdJournals.Client.Debug.cmdBaseline(playerObj, "view")
    end
end

BurdJournals.Client.DebugContextMenu.onDumpJournal = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdDump then
        BurdJournals.Client.Debug.cmdDump(playerObj, "journal")
    end
end

-- Edit Journal callback - opens the debug panel with Journal tab and the selected journal
BurdJournals.Client.DebugContextMenu.onEditJournal = function(playerObj)
    local journal = BurdJournals.Client.DebugContextMenu.currentJournal
    if not journal then
        BurdJournals.debugPrint("[BSJ] No journal selected for editing")
        return
    end
    
    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.Open then
        local panel = BurdJournals.UI.DebugPanel.Open(playerObj)
        if panel then
            -- Set the journal to edit and switch to journal tab
            panel.editingJournal = journal
            panel:showTab("journal")

            -- Try to restore journal data from global cache if it was lost
            -- This handles the case where item ModData didn't persist across mod updates
            -- Only do this ONCE when first opening the journal, not on every refresh
            if BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache then
                BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache(journal)
            end

            -- Refresh journal data in the tab
            if panel.refreshJournalEditorData then
                panel:refreshJournalEditorData()
            end
        end
    else
        BurdJournals.debugPrint("[BSJ] Debug Panel not loaded")
    end
end

BurdJournals.Client.DebugContextMenu.onToggleVerbose = function(playerObj)
    if BurdJournals.Client.Debug then
        BurdJournals.Client.Debug.verboseEnabled = not BurdJournals.Client.Debug.verboseEnabled
        local status = BurdJournals.Client.Debug.verboseEnabled and "ENABLED" or "DISABLED"
        BurdJournals.debugPrint("[BSJ] Verbose logging " .. status)
        if playerObj then playerObj:Say("[BSJ] Verbose " .. status) end
    end
end

BurdJournals.Client.DebugContextMenu.onRunDiagnostics = function(playerObj)
    if BurdJournals.Client.Diagnostics and BurdJournals.Client.Diagnostics.onChatCommand then
        BurdJournals.Client.Diagnostics.onChatCommand("/journaldiag")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnBlank = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "blank")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnFilled = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "filled")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnWorn = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "worn")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnBloody = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "bloody")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnCursed = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "cursed")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnMaxPassive = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "preset:maxpassive")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnAllPositive = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "preset:allpositive")
    end
end

BurdJournals.Client.DebugContextMenu.onSpawnAllNegative = function(playerObj)
    if BurdJournals.Client.Debug and BurdJournals.Client.Debug.cmdGive then
        BurdJournals.Client.Debug.cmdGive(playerObj, "preset:allnegative")
    end
end

function BurdJournals.Client.DebugContextMenu.createMenu(playerNum, context, items)
    if not BurdJournals.Client.DebugContextMenu.isEnabled() then return end
    
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    
    -- Find a journal in the selected items (handle PZ's item format)
    local journal = nil
    if items then
        for i = 1, #items do
            local itemOrStack = items[i]
            local item = nil
            
            -- Handle both direct items and inventory stacks
            if itemOrStack then
                if type(itemOrStack) == "table" and itemOrStack.items then
                    -- It's a stack, get first item
                    item = itemOrStack.items[1]
                elseif itemOrStack.getFullType then
                    -- It's a direct item
                    item = itemOrStack
                end
            end
            
            if item and item.getFullType then
                local itemType = item:getFullType()
                if itemType and (string.find(itemType, "SurvivalJournal") or 
                                 string.find(itemType, "BloodyJournal") or 
                                 string.find(itemType, "WornJournal")) then
                    journal = item
                    break
                end
            end
        end
    end
    
    -- Create BSJ Debug submenu
    local debugOption = context:addOption("[BSJ Debug]")
    local debugMenu = context:getNew(context)
    context:addSubMenu(debugOption, debugMenu)
    
    -- Journal-specific options
    if journal then
        -- Store journal reference for edit callback
        BurdJournals.Client.DebugContextMenu.currentJournal = journal
        
        -- Check if this is a filled journal (has skills, traits, or recipes)
        local isFilled = false
        local journalData = BurdJournals.getJournalData(journal)
        if journalData then
            local skillCount = BurdJournals.countTable and BurdJournals.countTable(journalData.skills) or 0
            local traitCount = BurdJournals.countTable and BurdJournals.countTable(journalData.traits) or 0
            local recipeCount = BurdJournals.countTable and BurdJournals.countTable(journalData.recipes) or 0
            isFilled = (skillCount > 0) or (traitCount > 0) or (recipeCount > 0)
        end
        
        -- Add Edit Journal option for filled journals
        if isFilled then
            debugMenu:addOption("Edit Journal", player, BurdJournals.Client.DebugContextMenu.onEditJournal)
        end
        
        debugMenu:addOption("Dump Journal Data", player, BurdJournals.Client.DebugContextMenu.onDumpJournal)
    end
    
    -- Player debug options
    debugMenu:addOption("Open Debug Panel", player, BurdJournals.Client.DebugContextMenu.onOpenDebugPanel)
    debugMenu:addOption("Dump Player Skills", player, BurdJournals.Client.DebugContextMenu.onDumpSkills)
    debugMenu:addOption("Dump Baseline", player, BurdJournals.Client.DebugContextMenu.onDumpBaseline)
    debugMenu:addOption("View Baseline", player, BurdJournals.Client.DebugContextMenu.onViewBaseline)
    debugMenu:addOption("Spawn Blank Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnBlank)
    debugMenu:addOption("Spawn Filled Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnFilled)
    debugMenu:addOption("Spawn Worn Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnWorn)
    debugMenu:addOption("Spawn Bloody Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnBloody)
    debugMenu:addOption("Spawn Cursed Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnCursed)
end

-- Hook into inventory context menu
Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
    BurdJournals.Client.DebugContextMenu.createMenu(playerNum, context, items)
end)

-- Also hook into world context menu (right-click on ground)
Events.OnPreFillWorldObjectContextMenu.Add(function(playerNum, context, worldObjects, test)
    if test then return end
    if not BurdJournals.Client.DebugContextMenu.isEnabled() then return end
    
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    
    context:addOption("[BSJ Debug Panel]", player, BurdJournals.Client.DebugContextMenu.onOpenDebugPanel)
end)

BurdJournals.debugPrint("[BurdJournals] Debug context menu system loaded")
