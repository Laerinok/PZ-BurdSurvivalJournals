
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

        if hoursAlive < 0.1 then
            BurdJournals.debugPrint("[BurdJournals] init: New character detected (" .. hoursAlive .. " hours), deferring to OnCreatePlayer")
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

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            panel:refreshPlayer()
            if (panel.mode == "view" or panel.isPlayerJournal) and panel.populateViewList then
                panel:populateViewList()
            elseif panel.refreshAbsorptionList then
                panel:refreshAbsorptionList()
            elseif panel.refreshJournalData then
                panel:refreshJournalData()
            end
            if panel.checkDissolution then
                panel:checkDissolution()
            end
        end

    elseif command == "xpSyncComplete" then
        -- XP sync completed (fallback path)
        BurdJournals.debugPrint("[BurdJournals] Client: XP sync complete")
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            panel:refreshPlayer()
            if panel.refreshJournalData then
                panel:refreshJournalData()
            end
        end

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
    
    elseif command == "recalculateBaseline" then
        -- Server requested client to recalculate baseline (client has profession info)
        if BurdJournals.Client and BurdJournals.Client.calculateProfessionBaseline then
            BurdJournals.Client.calculateProfessionBaseline(player)
            BurdJournals.Client.showHaloMessage(player, "Baseline recalculated", BurdJournals.Client.HaloColors.INFO)
        end

    -- Debug journal backup responses (for MP dedicated server persistence)
    elseif command == "debugJournalBackupSaved" then
        local journalKey = args and args.journalKey or "unknown"
        BurdJournals.debugPrint("[BurdJournals] Client: Server confirmed debug journal backup saved for key=" .. tostring(journalKey))
        if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance then
            BurdJournals.UI.DebugPanel.instance:setStatus("Journal backup saved", {r=0.3, g=1, b=0.5})
        end

    elseif command == "debugJournalBackupResponse" then
        BurdJournals.Client.handleDebugJournalBackupResponse(player, args)

    elseif command == "debugJournalUUIDLookupResult" then
        BurdJournals.Client.handleDebugJournalUUIDLookupResult(player, args)

    elseif command == "debugJournalUUIDRepairResult" then
        BurdJournals.Client.handleDebugJournalUUIDRepairResult(player, args)

    elseif command == "debugJournalUUIDIndexList" then
        BurdJournals.Client.handleDebugJournalUUIDIndexList(player, args)

    elseif command == "debugJournalUUIDDeleteResult" then
        BurdJournals.Client.handleDebugJournalUUIDDeleteResult(player, args)
    end
end

function BurdJournals.Client.handleDebugJournalBackupResponse(player, args)
    if not args then return end

    local journalKey = args.journalKey
    if not journalKey then
        print("[BurdJournals] ERROR: No journalKey in debugJournalBackupResponse")
        return
    end

    if args.found and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Received debug journal backup from server for key=" .. tostring(journalKey))

        local cache = ModData.getOrCreate("BurdJournals_DebugJournalCache")
        if not cache.journals then cache.journals = {} end
        cache.journals[journalKey] = args.journalData

        if BurdJournals.Client._pendingDebugJournalRestore then
            local pending = BurdJournals.Client._pendingDebugJournalRestore
            if pending.journalKey == journalKey and pending.journal then
                if BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache then
                    BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache(pending.journal)
                end
            end
            BurdJournals.Client._pendingDebugJournalRestore = nil
        end
    else
        BurdJournals.debugPrint("[BurdJournals] Client: No debug journal backup found on server for key=" .. tostring(journalKey))
        BurdJournals.Client._pendingDebugJournalRestore = nil
    end
end

function BurdJournals.Client.requestDebugJournalBackup(journal, journalKey)
    if not journal or not journalKey then return end
    local player = getPlayer()
    if not player then return end

    if isClient and isClient() then
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
    if #recordedItems == 0 then
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
    
    -- Apply journal data if provided
    if journalId and args.journalData then
        local journal = BurdJournals.findItemById(player, journalId)
        if journal then
            local modData = journal:getModData()
            modData.BurdJournals = args.journalData
            BurdJournals.debugPrint("[BurdJournals] Client: Sync - Applied journalData to journal " .. tostring(journalId))
        end
    end
    
    -- Update the UI panel if it exists
    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        BurdJournals.debugPrint("[BurdJournals] Client: Sync - Refreshing UI panel")
        
        -- If the panel's journal matches, update its reference's data too
        if panel.journal and journalId and panel.journal:getID() == journalId and args.journalData then
            local panelModData = panel.journal:getModData()
            panelModData.BurdJournals = args.journalData
        end
        
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

        if BurdJournals.safeAddTrait then
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

    if args.journalId and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Applying journal data from server for absorb")

        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            local modData = journal:getModData()

            local claimedBefore = modData.BurdJournals and modData.BurdJournals.claimedSkills or {}
            BurdJournals.debugPrint("[BurdJournals] Client: claimedSkills BEFORE: " .. tostring(BurdJournals.countTable(claimedBefore)))

            modData.BurdJournals = args.journalData

            local claimedAfter = modData.BurdJournals and modData.BurdJournals.claimedSkills or {}
            BurdJournals.debugPrint("[BurdJournals] Client: claimedSkills AFTER: " .. tostring(BurdJournals.countTable(claimedAfter)))
            BurdJournals.debugPrint("[BurdJournals] Client: Journal data applied successfully for absorb")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Could not find journal to apply absorb data")
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelModData = panel.journal:getModData()
                BurdJournals.debugPrint("[BurdJournals] Client: Also updating panel.journal modData directly")
                panelModData.BurdJournals = args.journalData
            end
        end
    elseif args.journalId then

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

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                if args.skillName then
                    BurdJournals.claimSkill(panel.journal, args.skillName)
                end
                if args.traitId then
                    BurdJournals.claimTrait(panel.journal, args.traitId)
                end
                if args.recipeName then
                    BurdJournals.claimRecipe(panel.journal, args.recipeName)
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

        if BurdJournals.safeAddTrait then
            BurdJournals.safeAddTrait(player, args.traitId)
        end

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

    if args.journalId and args.journalData then
        BurdJournals.debugPrint("[BurdJournals] Client: Applying journal data from server for claimSuccess")
        local journal = BurdJournals.findItemById(player, args.journalId)
        if journal then
            local modData = journal:getModData()
            modData.BurdJournals = args.journalData
            BurdJournals.debugPrint("[BurdJournals] Client: Journal data applied successfully for claimSuccess")
        else
            BurdJournals.debugPrint("[BurdJournals] Client: Could not find journal to apply claimSuccess data")
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelModData = panel.journal:getModData()
                BurdJournals.debugPrint("[BurdJournals] Client: Also updating panel.journal modData directly for claimSuccess")
                panelModData.BurdJournals = args.journalData
            end
        end

        if args.journalData.isDebugSpawned
            and BurdJournals.UI
            and BurdJournals.UI.DebugPanel
            and BurdJournals.UI.DebugPanel.backupJournalToGlobalCache then
            local backupJournal = journal
            if (not backupJournal)
                and BurdJournals.UI.MainPanel
                and BurdJournals.UI.MainPanel.instance
                and BurdJournals.UI.MainPanel.instance.journal then
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

function BurdJournals.Client.handleEraseSuccess(player, args)
    if not args then return end

    BurdJournals.debugPrint("[BurdJournals] Client: handleEraseSuccess received, journalId=" .. tostring(args.journalId))

    -- Show the halo message
    BurdJournals.Client.showHaloMessage(player, getText("UI_BurdJournals_JournalErased") or "Entry erased", BurdJournals.Client.HaloColors.INFO)

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

        -- Also update the panel's journal if it matches
        if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
            local panel = BurdJournals.UI.MainPanel.instance
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelModData = panel.journal:getModData()
                BurdJournals.debugPrint("[BurdJournals] Client: Also updating panel.journal modData directly for eraseSuccess")
                panelModData.BurdJournals = args.journalData
            end
        end
    end

    -- Refresh the UI to reflect the erased entry
    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance

        BurdJournals.debugPrint("[BurdJournals] Client: Refreshing UI for eraseSuccess")
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

function BurdJournals.Client.handleGrantTrait(player, args)
    if not args or not args.traitId then return end

    local traitId = args.traitId

    local traitName = BurdJournals.getTraitDisplayName(traitId)
    if BurdJournals.safeAddTrait then
        local added = BurdJournals.safeAddTrait(player, traitId)
        if not added then
            BurdJournals.debugPrint("[BurdJournals] Client: Failed to grant trait '" .. tostring(traitId) .. "'")
        end
    end

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

    if BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance then
        local panel = BurdJournals.UI.MainPanel.instance
        
        -- Clear this skill from pending claims
        if panel.pendingClaims and panel.pendingClaims.skills then
            panel.pendingClaims.skills[skillName] = nil
        end
        
        -- Update journal data if provided
        if args.journalId and args.journalData then
            if panel.journal and panel.journal:getID() == args.journalId then
                local panelModData = panel.journal:getModData()
                panelModData.BurdJournals = args.journalData
            end
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
        ["Athletic"] = true,      -- Granted at Fitness 4+
        ["Fit"] = true,           -- Alternative name
        ["Unfit"] = true,         -- Low fitness
        ["OutOfShape"] = true,    -- Very low fitness
        -- Strength-based traits (granted at certain strength levels)
        ["Strong"] = true,        -- Granted at Strength 4+
        ["Stout"] = true,         -- Alternative name for Strong
        ["Weak"] = true,          -- Low strength
        ["Feeble"] = true,        -- Very low strength
        -- Weight-based traits (can change during gameplay)
        ["Overweight"] = true,
        ["Obese"] = true,
        ["Underweight"] = true,
        ["VeryUnderweight"] = true,
        ["Emaciated"] = true,
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

                    -- To get entry point to level N, use getTotalXpForLevel(N-1)
                    -- For level 0, baseline is 0 XP
                    local xp = finalLevel > 0 and perk:getTotalXpForLevel(finalLevel - 1) or 0
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
    for skillName, _ in pairs(passiveSkills) do
        local perkId = BurdJournals.SKILL_TO_PERK and BurdJournals.SKILL_TO_PERK[skillName] or skillName
        local perk = Perks[perkId]
        if perk then
            -- Entry to Level 5 = getTotalXpForLevel(4)
            local xp = perk:getTotalXpForLevel(BASE_PASSIVE_LEVEL - 1)
            if xp and xp > 0 then
                skillBaseline[skillName] = xp
                BurdJournals.debugPrint("[BurdJournals] Baseline: " .. skillName .. " = " .. xp .. " XP (fixed Level 5 baseline)")
            end
        end
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
            local hoursAlive = player:getHoursSurvived() or 0
            if hoursAlive > 1 then
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

    if isNewCharacter then
        local hoursAlive = player:getHoursSurvived() or 0
        if hoursAlive > 1 then
            print("[BurdJournals] WARNING: isNewCharacter=true but player has " .. hoursAlive .. " hours survived!")
            BurdJournals.debugPrint("[BurdJournals] Treating as existing save to avoid incorrect baseline capture")
            isNewCharacter = false
        end
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
        local recipes = BurdJournals.collectPlayerMagazineRecipes(player, false)
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
        skillBaseline = modData.BurdJournals.skillBaseline or {},
        mediaSkillBaseline = modData.BurdJournals.mediaSkillBaseline or {},
        traitBaseline = modData.BurdJournals.traitBaseline or {},
        recipeBaseline = modData.BurdJournals.recipeBaseline or {}
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
    else

        BurdJournals.debugPrint("[BurdJournals] No cached baseline on server for: " .. tostring(args.characterId))

        local hoursAlive = player:getHoursSurvived() or 0
        local isNewCharacter = hoursAlive < 0.1

        if isNewCharacter then

            BurdJournals.debugPrint("[BurdJournals] New character without server cache - OnCreatePlayer will handle")
        else

            BurdJournals.debugPrint("[BurdJournals] Existing character (" .. hoursAlive .. " hours) has no server cache")
            BurdJournals.debugPrint("[BurdJournals] NOT migrating baseline - character will have no baseline restrictions")
            BurdJournals.debugPrint("[BurdJournals] Baseline restrictions will apply to new characters only")

            local modData = player:getModData()
            if modData.BurdJournals then
                modData.BurdJournals.baselineCaptured = false
                modData.BurdJournals.skillBaseline = nil
                modData.BurdJournals.traitBaseline = nil
                modData.BurdJournals.recipeBaseline = nil
            end
        end
    end
end

function BurdJournals.Client.handleBaselineRegistered(player, args)
    if not args then return end

    if args.success then
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

function BurdJournals.Client.onCreatePlayer(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    if player then

        local hoursAlive = player:getHoursSurvived() or 0
        if hoursAlive > 0.1 then

            BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: Skipping (existing character with " .. hoursAlive .. " hours)")
            return
        end

        BurdJournals.Client._pendingNewCharacterBaseline = true
        BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: Set pending flag, will capture baseline for new character")

        if BurdJournals.getPlayerCharacterId then
            BurdJournals.Client._lastKnownCharacterId = BurdJournals.getPlayerCharacterId(player)
        end

        local modData = player:getModData()
        if modData then
            if not modData.BurdJournals then
                modData.BurdJournals = {}
            end

            modData.BurdJournals.baselineCaptured = false
            modData.BurdJournals.skillBaseline = nil
            modData.BurdJournals.traitBaseline = nil
            modData.BurdJournals.recipeBaseline = nil
            -- Clear bypass flag on new character - baseline will be enforced normally
            modData.BurdJournals.baselineBypassed = nil
        end

        local handlerId = nil
        local captureAfterDelay
        local ticksWaited = 0
        local maxWaitTicks = 300
        local minWaitTicks = 30

        captureAfterDelay = function()
            ticksWaited = ticksWaited + 1

            local currentPlayer = getSpecificPlayer(playerIndex)
            if not currentPlayer then
                BurdJournals.debugPrint("[BurdJournals] onCreatePlayer: Player became invalid during wait, aborting baseline capture")
                BurdJournals.Client.unregisterTickHandler(handlerId)
                BurdJournals.Client._pendingNewCharacterBaseline = false
                return
            end

            if ticksWaited >= minWaitTicks then

                local hasTraits = false
                local charTraits = currentPlayer.getCharacterTraits and currentPlayer:getCharacterTraits() or nil
                if charTraits and charTraits.getKnownTraits then
                    local knownTraits = charTraits:getKnownTraits()
                    if knownTraits and knownTraits.size and knownTraits:size() > 0 then
                        hasTraits = true
                    end
                end

                if hasTraits or ticksWaited >= maxWaitTicks then
                    BurdJournals.Client.unregisterTickHandler(handlerId)

                    BurdJournals.Client._pendingNewCharacterBaseline = false
                    if not hasTraits then
                        print("[BurdJournals] WARNING: Max wait reached (" .. ticksWaited .. " ticks), capturing baseline without full traits")
                    else
                        BurdJournals.debugPrint("[BurdJournals] Traits loaded after " .. ticksWaited .. " ticks, capturing baseline")
                    end

                    BurdJournals.Client.captureBaseline(currentPlayer, true)
                end
            end
        end
        handlerId = BurdJournals.Client.registerTickHandler(captureAfterDelay, "onCreatePlayer_baseline")
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
        
        -- Check equipped bags
        local backpack = player:getClothingItem_Back()
        if backpack and backpack:getInventory() then
            BurdJournals.Client.restoreJournalNamesInContainer(backpack:getInventory())
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
    if data then
        local parts = {}
        for k, v in pairs(data) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        dataStr = " {" .. table.concat(parts, ", ") .. "}"
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
-- Commands for testing and development (/bsjgive, /bsjdump, /bsjtest, etc.)
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
function BurdJournals.Client.Debug.xpToLevel(skillName, xp)
    local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
    if not perk or not perk.getTotalXpForLevel then return 0 end
    
    for level = 10, 0, -1 do
        local levelXp = level > 0 and perk:getTotalXpForLevel(level - 1) or 0
        if xp >= levelXp then
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
        preset = nil
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
        if lowerPart == "blank" or lowerPart == "filled" or lowerPart == "worn" or lowerPart == "bloody" or lowerPart == "all" then
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

-- Calculate XP for a skill level
-- Returns the XP needed to BE at that level (threshold + small buffer)
-- IMPORTANT: getTotalXpForLevel(N) returns the XP threshold to BE AT level N
function BurdJournals.Client.Debug.getXPForLevel(skillName, level)
    if not level or level <= 0 then return 0 end
    if level > 10 then level = 10 end
    
    local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
    if perk and perk.getTotalXpForLevel then
        -- getTotalXpForLevel(N) = XP threshold to BE at level N
        -- To guarantee level N, we need XP >= getTotalXpForLevel(N)
        -- Example: Level 3 requires XP >= getTotalXpForLevel(3) = 500
        local baseXP = perk:getTotalXpForLevel(level) or 0
        -- Add small buffer to be safely above threshold (but NOT enough to reach next level)
        local nextLevelXP = perk:getTotalXpForLevel(level + 1) or (baseXP * 1.5)
        local buffer = math.max(1, math.floor((nextLevelXP - baseXP) * 0.1))
        local xp = baseXP + buffer
        BurdJournals.debugPrint("[BurdJournals] DEBUG getXPForLevel: " .. tostring(skillName) .. " level " .. level .. " = " .. xp .. " (base=" .. baseXP .. " + buffer=" .. buffer .. ")")
        return xp
    end
    
    -- Fallback XP table - XP to BE at each level
    -- Level N requires xp >= xpTable[N]
    -- We add a small buffer to be safely above threshold but NOT reach next level
    local xpTable = {
        [1] = 80,       -- Level 1: need >= 75, add ~5 buffer
        [2] = 240,      -- Level 2: need >= 225, add ~15 buffer
        [3] = 540,      -- Level 3: need >= 500, add ~40 buffer
        [4] = 940,      -- Level 4: need >= 900, add ~40 buffer
        [5] = 1475,     -- Level 5: need >= 1425, add ~50 buffer
        [6] = 2130,     -- Level 6: need >= 2075, add ~55 buffer
        [7] = 2920,     -- Level 7: need >= 2850, add ~70 buffer
        [8] = 3840,     -- Level 8: need >= 3750, add ~90 buffer
        [9] = 4890,     -- Level 9: need >= 4775, add ~115 buffer
        [10] = 6050     -- Level 10: need >= 5925, add ~125 buffer
    }
    local xp = xpTable[level] or 0
    BurdJournals.debugPrint("[BurdJournals] DEBUG getXPForLevel: " .. tostring(skillName) .. " level " .. level .. " = " .. xp .. " (via fallback table)")
    return xp
end

-- Spawn a journal with specified content
function BurdJournals.Client.Debug.spawnJournal(player, params)
    if not player then return false end
    
    local journalType = params.journalType or "filled"
    
    -- In dedicated server MP mode, create journal SERVER-SIDE for proper persistence
    -- Server-created items survive restarts and mod updates
    if isClient() and not isServer() then
        BurdJournals.debugPrint("[BurdJournals] DEBUG: MP mode detected - creating journal server-side for persistence")
        
        -- Convert params.skills from array to table format expected by server
        local skillsTable = {}
        for _, skillData in ipairs(params.skills or {}) do
            local xp = skillData.xp
            if not xp then
                xp = BurdJournals.Client.Debug.getXPForLevel(skillData.name, skillData.level)
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
            owner = params.owner or params.ownerCharacterName or "Debug Spawn",
            skills = skillsTable,
            traits = traitsTable,
            recipes = recipesTable,
            stats = statsTable,
            isPlayerJournal = params.isPlayerCreated,  -- Pass this flag for proper claim handling
            ownerSteamId = params.ownerSteamId,
            ownerUsername = params.ownerUsername,
            ownerCharacterName = params.ownerCharacterName,
            ageHours = params.ageHours,
            conditionOverride = params.conditionOverride,
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
        
        -- CRITICAL: Persistence fields - same as server-side handler
        data.isDebugSpawned = true  -- Flag to bypass origin restrictions
        data.isWritten = true       -- Mark as properly initialized
        data.journalVersion = BurdJournals.VERSION or "dev"  -- Version tracking
        data.sanitizedVersion = BurdJournals.SANITIZE_VERSION or 1  -- Prevent re-sanitization
        
        -- Initialize data containers
        data.skills = {}
        data.traits = {}
        data.recipes = {}
        data.stats = {}
        data.claims = {}  -- Per-character claims tracking
        
        -- Handle owner assignment
        if params.ownerSteamId and params.ownerUsername then
            data.ownerSteamId = params.ownerSteamId
            data.ownerUsername = params.ownerUsername
            data.ownerCharacterName = params.ownerCharacterName or params.owner or "Debug Spawn"
            data.author = data.ownerCharacterName
            
            if journalType == "filled" and params.isPlayerCreated then
                data.isPlayerCreated = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: Created player journal assigned to: " .. data.ownerCharacterName .. " (SteamID: " .. data.ownerSteamId .. ")")
            end
        else
            data.ownerCharacterName = params.owner or "Debug Spawn"
            data.author = data.ownerCharacterName
            data.ownerSteamId = "debug_local_" .. tostring((getTimestampMs and getTimestampMs()) or os.time())  -- Placeholder for SP
        end
        
        -- Mark origin for worn/bloody
        if journalType == "worn" then
            data.isWorn = true
            data.wasFromWorn = true
        elseif journalType == "bloody" then
            data.isBloody = true
            data.wasFromBloody = true
            data.hasBloodyOrigin = true
        end

        if params.conditionOverride and item.setCondition then
            local cond = math.max(1, math.min(10, math.floor(params.conditionOverride)))
            item:setCondition(cond)
            data.condition = cond
        elseif item.getCondition then
            data.condition = item:getCondition()
        end
        
        -- Add specified skills
        for _, skillData in ipairs(params.skills) do
            local xp = skillData.xp
            if not xp then
                -- Calculate XP from level
                xp = BurdJournals.Client.Debug.getXPForLevel(skillData.name, skillData.level)
                -- For passive skills, subtract baseline
                local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillData.name)
                if isPassive == nil then isPassive = (skillData.name == "Fitness" or skillData.name == "Strength") end
                if isPassive then
                    local baselineXP = BurdJournals.Client.Debug.getXPForLevel(skillData.name, 5)
                    xp = xp - baselineXP
                end
            end
            data.skills[skillData.name] = {
                xp = math.max(0, xp),
                level = skillData.level
            }
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
        local types = {"blank", "filled", "worn", "bloody"}
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
-- /bsjtest - Run automated tests
-- ============================================================================

BurdJournals.Client.Debug.Tests = {}

-- Test: Passive skill baseline calculation
function BurdJournals.Client.Debug.Tests.passive(player)
    local results = {
        name = "Passive Skills",
        passed = true,
        details = {}
    }
    
    -- Check Fitness baseline
    local fitnessBaseline = BurdJournals.getSkillBaseline and BurdJournals.getSkillBaseline(player, "Fitness") or 0
    local fitnessPerk = BurdJournals.getPerkByName and BurdJournals.getPerkByName("Fitness")
    local expectedBaseline = fitnessPerk and fitnessPerk:getTotalXpForLevel(4) or 0
    
    table.insert(results.details, string.format("Fitness baseline: %.0f (expected: %.0f)", fitnessBaseline, expectedBaseline))
    
    if math.abs(fitnessBaseline - expectedBaseline) > 100 then
        results.passed = false
        table.insert(results.details, "FAIL: Fitness baseline mismatch!")
    end
    
    -- Check Strength baseline
    local strengthBaseline = BurdJournals.getSkillBaseline and BurdJournals.getSkillBaseline(player, "Strength") or 0
    local strengthPerk = BurdJournals.getPerkByName and BurdJournals.getPerkByName("Strength")
    local expectedStrength = strengthPerk and strengthPerk:getTotalXpForLevel(4) or 0
    
    table.insert(results.details, string.format("Strength baseline: %.0f (expected: %.0f)", strengthBaseline, expectedStrength))
    
    if math.abs(strengthBaseline - expectedStrength) > 100 then
        results.passed = false
        table.insert(results.details, "FAIL: Strength baseline mismatch!")
    end
    
    return results
end

-- Test: Baseline calculation
function BurdJournals.Client.Debug.Tests.baseline(player)
    local results = {
        name = "Baseline Calculation",
        passed = true,
        details = {}
    }
    
    local modData = player:getModData()
    if not modData.BurdJournals then
        table.insert(results.details, "No BurdJournals modData found")
        results.passed = false
        return results
    end
    
    local bj = modData.BurdJournals
    table.insert(results.details, string.format("Baseline captured: %s", bj.baselineCaptured and "Yes" or "No"))
    table.insert(results.details, string.format("Baseline version: %s", tostring(bj.baselineVersion or "N/A")))
    table.insert(results.details, string.format("Baseline bypassed: %s", bj.baselineBypassed and "Yes" or "No"))
    
    if bj.skillBaseline then
        local count = 0
        for _ in pairs(bj.skillBaseline) do count = count + 1 end
        table.insert(results.details, string.format("Skill baselines: %d entries", count))
    else
        table.insert(results.details, "No skill baselines found")
    end
    
    return results
end

function BurdJournals.Client.Debug.cmdTest(player, args)
    if not args or args == "" then
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjtest [passive|baseline|all]", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local arg = string.lower(args)
    local testsToRun = {}
    
    if arg == "passive" then
        table.insert(testsToRun, "passive")
    elseif arg == "baseline" then
        table.insert(testsToRun, "baseline")
    elseif arg == "all" then
        testsToRun = {"passive", "baseline"}
    else
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Unknown test: " .. arg, {r=1, g=0.5, b=0.3}, true)
        return true
    end
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("[BSJ-DEBUG] RUNNING TESTS")
    BurdJournals.debugPrint("================================================================================")
    
    local allPassed = true
    
    for _, testName in ipairs(testsToRun) do
        local testFunc = BurdJournals.Client.Debug.Tests[testName]
        if testFunc then
            BurdJournals.debugPrint("")
            BurdJournals.debugPrint("--- TEST: " .. testName .. " ---")
            
            local results = testFunc(player)
            
            for _, detail in ipairs(results.details) do
                BurdJournals.debugPrint("  " .. detail)
            end
            
            local status = results.passed and "PASSED" or "FAILED"
            BurdJournals.debugPrint(string.format("  Result: %s", status))
            
            if not results.passed then
                allPassed = false
            end
        end
    end
    
    BurdJournals.debugPrint("")
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint(string.format("[BSJ-DEBUG] TESTS COMPLETE - %s", allPassed and "ALL PASSED" or "SOME FAILED"))
    BurdJournals.debugPrint("================================================================================")
    BurdJournals.debugPrint("")
    
    local color = allPassed and {r=0.3, g=1, b=0.5} or {r=1, g=0.5, b=0.3}
    local msg = allPassed and "[BSJ] All tests passed!" or "[BSJ] Some tests failed - check console"
    BurdJournals.Client.Debug.feedback(player, msg, color, false)
    
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
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Usage: /bsjadmin [listcache|playerstats|forcesync]", {r=1, g=0.7, b=0.3}, true)
        return true
    end
    
    local parts = {}
    for part in string.gmatch(args, "%S+") do
        table.insert(parts, part)
    end
    
    local subCmd = parts[1] and string.lower(parts[1]) or ""
    
    if subCmd == "listcache" then
        BurdJournals.debugPrint("")
        BurdJournals.debugPrint("[BSJ-DEBUG] Baseline cache listing requested - check server logs")
        BurdJournals.Client.Debug.feedback(player, "[BSJ] Baseline cache info in server logs", {r=0.5, g=0.8, b=1}, true)
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
            {cmd = "/bsjhelp [topic]", desc = "Show this help. Topics: general, debug, give, journal, admin"},
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
            {cmd = "/bsjtest [test]", desc = "Run tests. Tests: passive, baseline, all"},
            {cmd = "/bsjdebug", desc = "Open Debug Center UI (coming soon)"},
        }
    },
    
    -- Give/spawn commands
    give = {
        title = "Journal Spawning Commands",
        commands = {
            {cmd = "/bsjgive [type]", desc = "Spawn journal. Types: blank, filled, worn, bloody, all"},
            {cmd = "/bsjgive [type] skill:[name]:[level]", desc = "Spawn with specific skill"},
            {cmd = "/bsjgive [type] trait:[name]", desc = "Spawn with specific trait"},
            {cmd = "/bsjgive [type] traits:[n1],[n2]", desc = "Spawn with multiple traits"},
            {cmd = "/bsjgive [type] skills:[n]:[l],[n]:[l]", desc = "Spawn with multiple skills"},
            {cmd = "/bsjgive [type] recipe:[name]", desc = "Spawn with specific recipe"},
            {cmd = "/bsjgive [type] stat:[name]:[value]", desc = "Spawn with stat (zombieKills, hoursSurvived)"},
            {cmd = "/bsjgive [type] owner:[name]", desc = "Set journal owner name"},
            {cmd = "/bsjgive [type] empty", desc = "Spawn without random content"},
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
            {cmd = "/bsjadmin listcache", desc = "List cached baselines (server logs)"},
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
        ["/bsjtest"] = BurdJournals.Client.Debug.cmdTest,
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
        debugMenu:addOption("Dump Journal Data", player, BurdJournals.Client.DebugContextMenu.onDumpJournal)
    end
    
    -- Player debug options
    debugMenu:addOption("Open Debug Panel", player, BurdJournals.Client.DebugContextMenu.onOpenDebugPanel)
    debugMenu:addOption("Dump Player Skills", player, BurdJournals.Client.DebugContextMenu.onDumpSkills)
    debugMenu:addOption("Dump Baseline", player, BurdJournals.Client.DebugContextMenu.onDumpBaseline)
    debugMenu:addOption("View Baseline", player, BurdJournals.Client.DebugContextMenu.onViewBaseline)
    
    -- Spawn submenu
    local spawnOption = debugMenu:addOption("Spawn Journal...")
    local spawnMenu = context:getNew(debugMenu)
    debugMenu:addSubMenu(spawnOption, spawnMenu)
    
    spawnMenu:addOption("Blank Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnBlank)
    spawnMenu:addOption("Filled Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnFilled)
    spawnMenu:addOption("Worn Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnWorn)
    spawnMenu:addOption("Bloody Journal", player, BurdJournals.Client.DebugContextMenu.onSpawnBloody)
    spawnMenu:addOption("Preset: Max Passive", player, BurdJournals.Client.DebugContextMenu.onSpawnMaxPassive)
    spawnMenu:addOption("Preset: All Positive", player, BurdJournals.Client.DebugContextMenu.onSpawnAllPositive)
    spawnMenu:addOption("Preset: All Negative", player, BurdJournals.Client.DebugContextMenu.onSpawnAllNegative)
    
    -- Utility options
    local verboseStatus = BurdJournals.Client.Debug and BurdJournals.Client.Debug.verboseEnabled and "ON" or "OFF"
    debugMenu:addOption("Toggle Verbose (" .. verboseStatus .. ")", player, BurdJournals.Client.DebugContextMenu.onToggleVerbose)
    debugMenu:addOption("Run Diagnostics", player, BurdJournals.Client.DebugContextMenu.onRunDiagnostics)
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
