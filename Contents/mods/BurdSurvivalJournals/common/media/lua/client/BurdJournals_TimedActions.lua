
require "TimedActions/ISBaseTimedAction"
require "BurdJournals_Shared"

BurdJournals = BurdJournals or {}

local function getTooDarkMessage()
    local message = (getText and getText("ContextMenu_TooDark")) or "Too dark to read."
    if message == "ContextMenu_TooDark" then
        message = "Too dark to read."
    end
    return message
end

local function notifyTooDark(player, reason)
    local message = reason or getTooDarkMessage()
    if HaloTextHelper and HaloTextHelper.addBadText and player then
        HaloTextHelper.addBadText(player, message)
    elseif player and player.Say then
        player:Say(message)
    end
end

local function isJournalLightAllowed(player)
    if not BurdJournals.canUseJournalInCurrentLight then
        return true, nil
    end
    return BurdJournals.canUseJournalInCurrentLight(player)
end

BurdJournals.ConvertToCleanAction = ISBaseTimedAction:derive("BurdJournals_ConvertToCleanAction")

function BurdJournals.ConvertToCleanAction:new(character, journal)
    local o = ISBaseTimedAction.new(self, character)

    o.journal = journal
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local convertTime = BurdJournals.getSandboxOption("ConvertTime") or 15.0
    o.maxTime = math.floor(convertTime * 33)

    return o
end

function BurdJournals.ConvertToCleanAction:isValid()
    local player = self.character
    if not player then return false end

    local journal = BurdJournals.findItemById(player, self.journal:getID())
    if not journal then return false end

    if not BurdJournals.isWorn(journal) then return false end

    return BurdJournals.canConvertToClean(player)
end

function BurdJournals.ConvertToCleanAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function BurdJournals.ConvertToCleanAction:start()
    self:setActionAnim("Loot")
    self.character:reportEvent("EventCrafting")

    self.sound = self.character:getEmitter():playSound("Sewing")
end

function BurdJournals.ConvertToCleanAction:stop()

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function BurdJournals.ConvertToCleanAction:perform()

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end

    local player = self.character

    if isClient() and not isServer() then

        sendClientCommand(
            player,
            "BurdJournals",
            "convertToClean",
            {journalId = self.journal:getID()}
        )
    else

        local inventory = player:getInventory()

        local leather = BurdJournals.findRepairItem(player, "leather")
        if leather then
            inventory:Remove(leather)
        end

        local thread = BurdJournals.findRepairItem(player, "thread")
        if thread then
            BurdJournals.consumeItemUses(thread, 1, player)
        end

        local needle = BurdJournals.findRepairItem(player, "needle")
        if needle then
            BurdJournals.consumeItemUses(needle, 1, player)
        end

        local journal = BurdJournals.findItemById(player, self.journal:getID())
        if journal then
            inventory:Remove(journal)
            local cleanJournal = inventory:AddItem("BurdJournals.BlankSurvivalJournal")
            if cleanJournal then
                local modData = cleanJournal:getModData()
                modData.BurdJournals = {
                    isWorn = false,
                    isBloody = false,
                    wasFromBloody = false,
                    isPlayerCreated = true,
                }
                BurdJournals.updateJournalName(cleanJournal)
                BurdJournals.updateJournalIcon(cleanJournal)
            end
            player:Say(getText("UI_BurdJournals_JournalRestored") or "Journal restored!")
        end
    end

    ISBaseTimedAction.perform(self)
end

BurdJournals.EraseJournalAction = ISBaseTimedAction:derive("BurdJournals_EraseJournalAction")

function BurdJournals.EraseJournalAction:new(character, journal)
    local o = ISBaseTimedAction.new(self, character)

    o.journal = journal
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local eraseTime = BurdJournals.getSandboxOption("EraseTime") or 10.0
    o.maxTime = math.floor(eraseTime * 33)

    return o
end

function BurdJournals.EraseJournalAction:isValid()
    local player = self.character
    if not player then return false end

    local journal = BurdJournals.findItemById(player, self.journal:getID())
    if not journal then return false end

    return BurdJournals.hasEraser(player)
end

function BurdJournals.EraseJournalAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function BurdJournals.EraseJournalAction:start()
    self:setActionAnim("Loot")
    self.character:reportEvent("EventCrafting")

    self.sound = self.character:getEmitter():playSound("RummageInInventory")
end

function BurdJournals.EraseJournalAction:stop()

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function BurdJournals.EraseJournalAction:perform()

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end

    local player = self.character
    local journal = BurdJournals.findItemById(player, self.journal:getID())

    if not journal then
        ISBaseTimedAction.perform(self)
        return
    end

    if isClient() and not isServer() then
        sendClientCommand(
            player,
            "BurdJournals",
            "eraseJournal",
            {journalId = journal:getID()}
        )
    else

        local inventory = player:getInventory()
        local journalType = journal:getFullType()

        inventory:Remove(journal)

        local blankJournal = inventory:AddItem("BurdJournals.BlankSurvivalJournal")
        if blankJournal then
            local modData = blankJournal:getModData()
            modData.BurdJournals = {
                isWorn = false,
                isBloody = false,
                wasFromBloody = false,
                isPlayerCreated = true,
            }
            BurdJournals.updateJournalName(blankJournal)
            BurdJournals.updateJournalIcon(blankJournal)
        end

        player:Say(getText("UI_BurdJournals_JournalErased") or "Journal erased...")
    end

    ISBaseTimedAction.perform(self)
end

BurdJournals.BindJournalAction = ISBaseTimedAction:derive("BurdJournals_BindJournalAction")

function BurdJournals.BindJournalAction:new(character, sourceItem, actionType)
    local o = ISBaseTimedAction.new(self, character)

    o.sourceItem = sourceItem
    o.actionType = actionType or "BindJournal"
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local config = BurdJournals.ContextMenu and BurdJournals.ContextMenu.getCraftingConfig and
                   BurdJournals.ContextMenu.getCraftingConfig(o.actionType)
    local bindTime = config and config.time or 120
    o.maxTime = math.floor(bindTime * 33)
    o.xpAward = config and config.xpAward or 0

    return o
end

function BurdJournals.BindJournalAction:isValid()
    local player = self.character
    if not player then return false end

    local inventory = player:getInventory()
    if not inventory:contains(self.sourceItem) then return false end

    if BurdJournals.ContextMenu and BurdJournals.ContextMenu.hasRequiredMaterials then
        local hasMaterials = BurdJournals.ContextMenu.hasRequiredMaterials(player, self.actionType)
        if not hasMaterials then return false end
    end

    local config = BurdJournals.ContextMenu and BurdJournals.ContextMenu.getCraftingConfig and
                   BurdJournals.ContextMenu.getCraftingConfig(self.actionType)
    if config and config.tailoringRequired > 0 then
        if not BurdJournals.ContextMenu.hasTailoringLevel(player, config.tailoringRequired) then
            return false
        end
    end

    return true
end

function BurdJournals.BindJournalAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function BurdJournals.BindJournalAction:start()
    self:setActionAnim("Loot")
    self.character:reportEvent("EventCrafting")

    self.sound = self.character:getEmitter():playSound("Sewing")
end

function BurdJournals.BindJournalAction:stop()

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function BurdJournals.BindJournalAction:perform()

    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end

    local player = self.character
    local inventory = player:getInventory()

    local config = BurdJournals.ContextMenu and BurdJournals.ContextMenu.getCraftingConfig and
                   BurdJournals.ContextMenu.getCraftingConfig(self.actionType)
    if not config then
        print("[BurdJournals] ERROR: Invalid action type in BindJournalAction: " .. tostring(self.actionType))
        ISBaseTimedAction.perform(self)
        return
    end

    for _, mat in ipairs(config.materials) do
        for i = 1, mat.count do
            local item = BurdJournals.ContextMenu.findItemByTypeOrTag(player, mat)
            if item then
                if mat.keep then

                    if item:getCondition() then
                        item:setCondition(item:getCondition() - 1)
                    end
                else

                    inventory:Remove(item)
                end
            end
        end
    end

    inventory:Remove(self.sourceItem)

    local newJournal = inventory:AddItem("BurdJournals.BlankSurvivalJournal")
    if newJournal then
        local modData = newJournal:getModData()
        modData.BurdJournals = {
            isWorn = false,
            isBloody = false,
            wasFromBloody = false,
            isPlayerCreated = true,
            sourceType = "crafted",
        }
        BurdJournals.updateJournalName(newJournal)
        BurdJournals.updateJournalIcon(newJournal)
    end

    if config.xpAward and config.xpAward > 0 then
        if sendAddXp then
            sendAddXp(player, Perks.Tailoring, config.xpAward, true, true)
        else
            player:getXp():AddXP(Perks.Tailoring, config.xpAward)
        end
    end

    local boundMsg = getText("UI_BurdJournals_JournalBound") or "Journal bound!"
    if HaloTextHelper and HaloTextHelper.addTextWithArrow then
        HaloTextHelper.addTextWithArrow(player, boundMsg, true, HaloTextHelper.getColorGreen())
    else
        player:Say(boundMsg)
    end

    ISBaseTimedAction.perform(self)
end

BurdJournals.DisassembleJournalAction = ISBaseTimedAction:derive("BurdJournals_DisassembleJournalAction")

function BurdJournals.DisassembleJournalAction:new(character, journal)
    local o = ISBaseTimedAction.new(self, character)

    o.journal = journal
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local disassembleTime = BurdJournals.getSandboxOption("CraftingTime_DisassembleJournal") or 30.0
    o.maxTime = math.floor(disassembleTime * 33)

    return o
end

function BurdJournals.DisassembleJournalAction:isValid()
    local player = self.character
    if not player then return false end

    local journal = BurdJournals.findItemById(player, self.journal:getID())
    if not journal then return false end

    return BurdJournals.isBlankJournal(journal)
end

function BurdJournals.DisassembleJournalAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)
end

function BurdJournals.DisassembleJournalAction:start()
    self:setActionAnim("Loot")
    self.character:reportEvent("EventCrafting")

    self.sound = self.character:getEmitter():playSound("PaperRip")
end

function BurdJournals.DisassembleJournalAction:stop()
    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end
    ISBaseTimedAction.stop(self)
end

function BurdJournals.DisassembleJournalAction:perform()
    if self.sound and self.sound ~= 0 then
        self.character:getEmitter():stopSound(self.sound)
    end

    local player = self.character
    local inventory = player:getInventory()
    local journal = BurdJournals.findItemById(player, self.journal:getID())

    if not journal then
        ISBaseTimedAction.perform(self)
        return
    end

    inventory:Remove(journal)

    local outputStr = BurdJournals.getSandboxOption("Recipe_DisassembleOutput") or "Base.SheetPaper2:2|Base.LeatherStrips:1"
    local outputs = BurdJournals.ContextMenu and BurdJournals.ContextMenu.parseRecipeString and
                    BurdJournals.ContextMenu.parseRecipeString(outputStr) or {}

    local itemsGiven = {}
    for _, mat in ipairs(outputs) do

        if mat.type and not mat.type:match("^tag:") then
            for i = 1, mat.count do
                inventory:AddItem(mat.type)
            end
            table.insert(itemsGiven, mat.count .. "x " .. mat.name)
        end
    end

    if #itemsGiven > 0 then
        local msg = string.format(getText("UI_BurdJournals_Salvaged") or "Salvaged: %s", table.concat(itemsGiven, ", "))
        if HaloTextHelper and HaloTextHelper.addTextWithArrow then
            HaloTextHelper.addTextWithArrow(player, msg, true, HaloTextHelper.getColorGreen())
        else
            player:Say(msg)
        end
    else
        player:Say(getText("UI_BurdJournals_JournalDisassembled") or "Journal disassembled.")
    end

    ISBaseTimedAction.perform(self)
end

BurdJournals.LearnFromJournalAction = ISBaseTimedAction:derive("BurdJournals_LearnFromJournalAction")

function BurdJournals.LearnFromJournalAction:new(character, journal, rewards, isAbsorbAll, mainPanel, queuedRewards)
    local o = ISBaseTimedAction.new(self, character)

    o.journal = journal
    o.rewards = rewards or {}
    o.isAbsorbAll = isAbsorbAll or false
    o.mainPanel = mainPanel
    o.queuedRewards = queuedRewards or {}
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local totalTime = 0
    for _, reward in ipairs(rewards) do
        if reward.type == "skill" then
            totalTime = totalTime + (mainPanel and mainPanel:getSkillLearningTime() or 3.0)
        elseif reward.type == "trait" then
            totalTime = totalTime + (mainPanel and mainPanel:getTraitLearningTime() or 5.0)
        elseif reward.type == "recipe" then
            totalTime = totalTime + (mainPanel and mainPanel:getRecipeLearningTime() or 0.7)
        elseif reward.type == "stat" then
            totalTime = totalTime + (mainPanel and mainPanel:getStatLearningTime() or 5.0)
        end
    end

    -- Apply batch time multiplier for "Absorb All" operations with multiple items
    if isAbsorbAll and #rewards > 1 then
        local batchMultiplier = BurdJournals.getSandboxOption("BatchTimeMultiplier") or 0.25
        totalTime = totalTime * batchMultiplier
    end

    totalTime = math.max(1.0, totalTime)
    o.totalTimeSeconds = totalTime
    o.maxTime = math.floor(totalTime * 33)

    return o
end

function BurdJournals.LearnFromJournalAction:isValid()
    local player = self.character
    if not player then return false end

    local journal = BurdJournals.findItemById(player, self.journal:getID())
    if not journal then return false end

    local currentPanel = BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance
    if currentPanel then

        if self.mainPanel ~= currentPanel then
            self.mainPanel = currentPanel
        end

        if not currentPanel:isVisible() then
            return false
        end
    elseif self.mainPanel and not self.mainPanel:isVisible() then

        return false
    end

    local canUseLight, lightReason = isJournalLightAllowed(player)
    if not canUseLight then
        if not self._lightWarned then
            notifyTooDark(player, lightReason)
            self._lightWarned = true
        end
        return false
    end

    return true
end

function BurdJournals.LearnFromJournalAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)

    if self.mainPanel and self.mainPanel.learningState then
        local progress = self:getJobDelta()
        self.mainPanel.learningState.progress = progress
    end
end

function BurdJournals.LearnFromJournalAction:start()

    self:setAnimVariable("ReadType", "book")
    self:setActionAnim(CharacterActionAnims.Read)
    self:setOverrideHandModels(nil, self.journal)
    self.character:setReading(true)
    self.character:reportEvent("EventRead")

    self.character:playSound("OpenBook")

    if self.mainPanel then
        local firstReward = self.rewards[1]
        local existingClaimSessionId = self.mainPanel.learningState and self.mainPanel.learningState.claimSessionId or nil
        self.mainPanel.learningState = {
            active = true,
            skillName = firstReward and firstReward.type == "skill" and firstReward.name or nil,
            traitId = firstReward and firstReward.type == "trait" and firstReward.name or nil,
            recipeName = firstReward and firstReward.type == "recipe" and firstReward.name or nil,
            statId = firstReward and firstReward.type == "stat" and firstReward.name or nil,
            isAbsorbAll = self.isAbsorbAll,
            progress = 0,
            totalTime = self.totalTimeSeconds,
            startTime = getTimestampMs and getTimestampMs() or 0,
            pendingRewards = self.rewards,
            currentIndex = 1,
            queue = self.queuedRewards,
            timedAction = self,
            claimSessionId = existingClaimSessionId,
        }
    end
end

function BurdJournals.LearnFromJournalAction:stop()

    self.character:setReading(false)
    self.character:playSound("CloseBook")

    if self.mainPanel then
        self.mainPanel.learningState = {
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

        if self.mainPanel.refreshCurrentList then
            self.mainPanel:refreshCurrentList()
        end
    end

    ISBaseTimedAction.stop(self)
end

function BurdJournals.LearnFromJournalAction:perform()
    local player = self.character
    local panel = self.mainPanel

    if not player then
        BurdJournals.debugPrint("[BurdJournals] LearnFromJournalAction:perform - no player character, aborting")
        ISBaseTimedAction.perform(self)
        return
    end

    if player.setReading then
        player:setReading(false)
    end
    if player.playSound then
        player:playSound("CloseBook")
    end

    if not panel then
        ISBaseTimedAction.perform(self)
        return
    end

    local isPlayerJournal = panel.isPlayerJournal or panel.mode == "view"
    local claimSessionId = panel.learningState and panel.learningState.claimSessionId or nil
    if not claimSessionId
        and panel.learningState
        and panel.learningState.active
        and BurdJournals.getXPRecoveryMode
        and BurdJournals.getXPRecoveryMode() == 2
        and BurdJournals.getDiminishingTrackingMode
        and BurdJournals.getDiminishingTrackingMode() == 2 then
        local now = getTimestampMs and getTimestampMs() or 0
        local rand = ZombRand and ZombRand(1000000) or math.floor(math.random() * 1000000)
        claimSessionId = tostring(now) .. "-" .. tostring(rand)
        panel.learningState.claimSessionId = claimSessionId
    end

    local isMultiplayerClient = isClient and isClient() and not isServer()
    local journalData = BurdJournals.getJournalData and BurdJournals.getJournalData(self.journal) or nil
    local canUseBatchServerCommand = isMultiplayerClient and not (journalData and journalData.isDebugSpawned)

    if canUseBatchServerCommand then
        local batchPayload = {
            journalId = self.journal and self.journal:getID() or nil,
            claimSessionId = claimSessionId,
            skills = {},
            traits = {},
            recipes = {},
            stats = {},
        }

        for _, reward in ipairs(self.rewards) do
            if reward and reward.type == "skill" and reward.name then
                table.insert(batchPayload.skills, {skillName = reward.name})
            elseif reward and reward.type == "trait" and reward.name then
                table.insert(batchPayload.traits, reward.name)
            elseif reward and reward.type == "recipe" and reward.name then
                table.insert(batchPayload.recipes, reward.name)
            elseif reward and reward.type == "stat" and reward.name then
                table.insert(batchPayload.stats, {statId = reward.name, value = reward.value})
            end
        end

        local commandName = isPlayerJournal and "batchClaimRewards" or "batchAbsorbRewards"
        BurdJournals.debugPrint("[BurdJournals] TimedAction using " .. commandName
            .. " (skills=" .. tostring(#batchPayload.skills)
            .. ", traits=" .. tostring(#batchPayload.traits)
            .. ", recipes=" .. tostring(#batchPayload.recipes)
            .. ", stats=" .. tostring(#batchPayload.stats) .. ")")
        sendClientCommand(player, "BurdJournals", commandName, batchPayload)
    else
        for _, reward in ipairs(self.rewards) do
            BurdJournals.debugPrint("[BurdJournals] TimedAction processing reward: type=" .. tostring(reward.type) .. ", name=" .. tostring(reward.name) .. ", xp=" .. tostring(reward.xp))
            if reward.type == "skill" then
                BurdJournals.debugPrint("[BurdJournals] TimedAction: isPlayerJournal=" .. tostring(isPlayerJournal))
                if isPlayerJournal then
                    BurdJournals.debugPrint("[BurdJournals] TimedAction: Calling sendClaimSkill")
                    panel:sendClaimSkill(reward.name, reward.xp, true)
                else
                    BurdJournals.debugPrint("[BurdJournals] TimedAction: Calling sendAbsorbSkill for " .. tostring(reward.name))
                    panel:sendAbsorbSkill(reward.name, reward.xp, true)
                end
            elseif reward.type == "trait" then
                if isPlayerJournal then
                    panel:sendClaimTrait(reward.name, true)
                else
                    panel:sendAbsorbTrait(reward.name, true)
                end
            elseif reward.type == "recipe" then
                if isPlayerJournal then
                    panel:sendClaimRecipe(reward.name, true)
                else
                    panel:sendAbsorbRecipe(reward.name, true)
                end
            elseif reward.type == "stat" then
                -- Stats use sendClaimStat for both player and non-player journals
                panel:sendClaimStat(reward.name, reward.value)
            end
        end
    end

    if not panel:isVisible() or not panel.journal then

        ISBaseTimedAction.perform(self)
        return
    end

    panel:refreshPlayer()
    if isPlayerJournal then
        if panel.refreshJournalData then
            panel:refreshJournalData()
        end
    else
        if panel.refreshAbsorptionList then
            panel:refreshAbsorptionList()
        end
    end

    -- Get batch size for next batch (only matters for isAbsorbAll mode)
    local batchSize = BurdJournals.getSandboxOption("AbsorbBatchSize") or 15
    if batchSize < 1 then batchSize = 1 end

    local savedQueue = {}
    if not self.isAbsorbAll then
        -- For individual clicks, process one-at-a-time queue (legacy behavior)
        for _, item in ipairs(self.queuedRewards or {}) do
            table.insert(savedQueue, item)
        end

        if panel.learningState and panel.learningState.queue then
            for _, item in ipairs(panel.learningState.queue) do
                local isDupe = false
                for _, existing in ipairs(savedQueue) do
                    if existing.name == item.name then
                        isDupe = true
                        break
                    end
                end
                if not isDupe then
                    table.insert(savedQueue, item)
                end
            end
        end

        -- Process one item at a time for individual clicks
        if #savedQueue > 0 then
            local nextReward = table.remove(savedQueue, 1)

            panel.learningState = {
                active = true,
                skillName = nextReward.type == "skill" and nextReward.name or nil,
                traitId = nextReward.type == "trait" and nextReward.name or nil,
                recipeName = nextReward.type == "recipe" and nextReward.name or nil,
                isAbsorbAll = false,
                progress = 0,
                totalTime = 0,
                startTime = 0,
                pendingRewards = {nextReward},
                currentIndex = 1,
                queue = savedQueue,
                claimSessionId = claimSessionId,
            }

            if panel.skillList and panel.journal then
                panel:refreshPlayer()
                if panel.mode == "view" or panel.isPlayerJournal then
                    panel:populateViewList()
                else
                    panel:populateAbsorptionList()
                end
            end

            local nextRewards = {nextReward}
            local action = BurdJournals.LearnFromJournalAction:new(player, self.journal, nextRewards, false, panel, savedQueue)
            if action and action.character then
                ISTimedActionQueue.add(action)
            else
                BurdJournals.debugPrint("[BurdJournals] LearnFromJournalAction:perform - failed to queue next single reward action")
            end

            ISBaseTimedAction.perform(self)
            return
        end
    else
        -- For "Absorb All" mode, process in batches
        savedQueue = self.queuedRewards or {}

        if #savedQueue > 0 then
            -- Extract next batch
            local nextBatch = {}
            local remaining = {}

            for i, item in ipairs(savedQueue) do
                if i <= batchSize then
                    table.insert(nextBatch, item)
                else
                    table.insert(remaining, item)
                end
            end

            BurdJournals.debugPrint("[BurdJournals] LearnFromJournalAction:perform - Next batch: " .. #nextBatch .. " items, remaining: " .. #remaining)

            local firstReward = nextBatch[1]
            panel.learningState = {
                active = true,
                skillName = firstReward and firstReward.type == "skill" and firstReward.name or nil,
                traitId = firstReward and firstReward.type == "trait" and firstReward.name or nil,
                recipeName = firstReward and firstReward.type == "recipe" and firstReward.name or nil,
                isAbsorbAll = true,
                progress = 0,
                totalTime = 0,
                startTime = 0,
                pendingRewards = nextBatch,
                currentIndex = 1,
                queue = remaining,
                claimSessionId = claimSessionId,
            }

            if panel.skillList and panel.journal then
                panel:refreshPlayer()
                if panel.mode == "view" or panel.isPlayerJournal then
                    panel:populateViewList()
                else
                    panel:populateAbsorptionList()
                end
            end

            local action = BurdJournals.LearnFromJournalAction:new(player, self.journal, nextBatch, true, panel, remaining)
            if action and action.character then
                ISTimedActionQueue.add(action)
            else
                BurdJournals.debugPrint("[BurdJournals] LearnFromJournalAction:perform - failed to queue next absorb-all batch")
            end

            ISBaseTimedAction.perform(self)
            return
        end
    end

    panel.learningCompleted = true
    panel.learningState = {
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

    if panel.playSound and BurdJournals.Sounds then
        panel:playSound(BurdJournals.Sounds.LEARN_COMPLETE)
    end

    if panel.skillList and panel.journal then
        panel:refreshPlayer()
        if panel.mode == "view" or panel.isPlayerJournal then
            panel:populateViewList()
        else
            panel:populateAbsorptionList()
        end
    end

    if panel.refreshJournalData then
        panel:refreshJournalData()
    end
    if panel.checkDissolution then
        panel:checkDissolution()
    end

    ISBaseTimedAction.perform(self)
end

BurdJournals.RecordToJournalAction = ISBaseTimedAction:derive("BurdJournals_RecordToJournalAction")

function BurdJournals.RecordToJournalAction:new(character, journal, records, isRecordAll, mainPanel, queuedRecords)
    local o = ISBaseTimedAction.new(self, character)

    o.journal = journal
    o.records = records or {}
    o.isRecordAll = isRecordAll or false
    o.mainPanel = mainPanel
    o.queuedRecords = queuedRecords or {}
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local totalTime = 0
    for _, record in ipairs(records) do
        if record.type == "skill" then
            totalTime = totalTime + (mainPanel and mainPanel:getSkillRecordingTime() or 3.0)
        elseif record.type == "trait" then
            totalTime = totalTime + (mainPanel and mainPanel:getTraitRecordingTime() or 5.0)
        elseif record.type == "stat" then
            totalTime = totalTime + (mainPanel and mainPanel:getStatRecordingTime() or 2.0)
        elseif record.type == "recipe" then
            totalTime = totalTime + (mainPanel and mainPanel:getRecipeRecordingTime() or 0.8)
        end
    end

    -- Apply batch time multiplier for "Record All" operations with multiple items
    if isRecordAll and #records > 1 then
        local batchMultiplier = BurdJournals.getSandboxOption("BatchTimeMultiplier") or 0.25
        totalTime = totalTime * batchMultiplier
    end

    totalTime = math.max(1.0, totalTime)
    o.totalTimeSeconds = totalTime
    o.maxTime = math.floor(totalTime * 33)

    return o
end

function BurdJournals.RecordToJournalAction:isValid()
    local player = self.character
    if not player then
        BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid FAILED - no player")
        return false
    end

    local currentPanel = BurdJournals.UI and BurdJournals.UI.MainPanel and BurdJournals.UI.MainPanel.instance
    if currentPanel then

        if self.mainPanel ~= currentPanel then
            self.mainPanel = currentPanel
        end

        if not currentPanel:isVisible() then
            BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid FAILED - panel not visible")
            return false
        end
    elseif self.mainPanel and not self.mainPanel:isVisible() then

        BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid FAILED - panel not visible (no global instance)")
        return false
    end

    local journal = BurdJournals.findItemById(player, self.journal:getID())
    if not journal then

        if currentPanel and currentPanel.journal then
            local panelJournal = BurdJournals.findItemById(player, currentPanel.journal:getID())
            if panelJournal then

                BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid - Rebinding to panel journal (blank-to-filled conversion)")
                self.journal = panelJournal
                journal = panelJournal
            end
        end

        if not journal then
            BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid FAILED - journal not found in inventory")
            return false
        end
    end

    local requirePen = BurdJournals.getSandboxOption("RequirePenToWrite")
    if requirePen ~= false then
        if not BurdJournals.hasWritingTool(player) then
            BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid FAILED - no writing tool")
            return false
        end
    end

    local canUseLight, lightReason = isJournalLightAllowed(player)
    if not canUseLight then
        if not self._lightWarned then
            notifyTooDark(player, lightReason)
            self._lightWarned = true
        end
        BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid FAILED - too dark to read")
        return false
    end

    -- Only log periodically to avoid spam (every ~30 ticks = 1 second)
    if not self._lastValidLog or (getTimestampMs and (getTimestampMs() - self._lastValidLog > 1000)) then
        self._lastValidLog = getTimestampMs and getTimestampMs() or 0
        BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:isValid PASSED")
    end

    return true
end

function BurdJournals.RecordToJournalAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)

    if self.mainPanel and self.mainPanel.recordingState then
        local progress = self:getJobDelta()
        self.mainPanel.recordingState.progress = progress
    end
end

function BurdJournals.RecordToJournalAction:start()
    BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:start() called with " .. #self.records .. " records")

    self:setAnimVariable("ReadType", "book")
    self:setActionAnim(CharacterActionAnims.Read)
    self:setOverrideHandModels(nil, self.journal)
    self.character:setReading(true)
    self.character:reportEvent("EventRead")

    self.character:playSound("OpenBook")

    if self.mainPanel then
        local firstRecord = self.records[1]
        self.mainPanel.recordingState = {
            active = true,
            skillName = firstRecord and firstRecord.type == "skill" and firstRecord.name or nil,
            traitId = firstRecord and firstRecord.type == "trait" and firstRecord.name or nil,
            statId = firstRecord and firstRecord.type == "stat" and firstRecord.name or nil,
            recipeName = firstRecord and firstRecord.type == "recipe" and firstRecord.name or nil,
            isRecordAll = self.isRecordAll,
            progress = 0,
            totalTime = self.totalTimeSeconds,
            startTime = getTimestampMs and getTimestampMs() or 0,
            pendingRecords = self.records,
            currentIndex = 1,
            queue = self.queuedRecords,
            timedAction = self,
        }
    end
end

function BurdJournals.RecordToJournalAction:stop()
    BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:stop() called - ACTION CANCELLED")

    self.character:setReading(false)
    self.character:playSound("CloseBook")

    if self.mainPanel then
        self.mainPanel.recordingState = {
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

        if self.mainPanel.refreshCurrentList then
            self.mainPanel:refreshCurrentList()
        end
    end

    ISBaseTimedAction.stop(self)
end

function BurdJournals.RecordToJournalAction:perform()
    BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:perform() called with " .. #self.records .. " records")

    self.character:setReading(false)
    self.character:playSound("CloseBook")

    local player = self.character
    local panel = self.mainPanel

    if not panel then
        BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:perform() - no panel, returning early")
        ISBaseTimedAction.perform(self)
        return
    end

    local skillsToRecord = {}
    local traitsToRecord = {}
    local statsToRecord = {}
    local recipesToRecord = {}
    local skillCount = 0
    local traitCount = 0
    local statCount = 0
    local recipeCount = 0

    for _, record in ipairs(self.records) do
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

            local magazineType = BurdJournals.getMagazineForRecipe and BurdJournals.getMagazineForRecipe(record.name) or nil
            recipesToRecord[record.name] = {
                name = record.name,
                source = magazineType
            }
            recipeCount = recipeCount + 1
        end
    end

    panel.pendingRecordFeedback = {
        skills = skillCount,
        traits = traitCount,
        stats = statCount,
        recipes = recipeCount
    }

    local journalId = self.journal and self.journal:getID() or nil
    local journalType = self.journal and self.journal:getFullType() or "nil"
    BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:perform() - journalId=" .. tostring(journalId) .. ", type=" .. tostring(journalType) .. ", skills=" .. skillCount .. ", traits=" .. traitCount .. ", recipes=" .. recipeCount)

    if not journalId then
        print("[BurdJournals] ERROR: Cannot send recordProgress - journal ID is nil!")
        ISBaseTimedAction.perform(self)
        return
    end

    sendClientCommand(player, "BurdJournals", "recordProgress", {
        journalId = journalId,
        skills = skillsToRecord,
        traits = traitsToRecord,
        stats = statsToRecord,
        recipes = recipesToRecord
    })

    BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:perform() - sendClientCommand completed for journalId=" .. tostring(journalId))

    -- Get batch size for next batch (only matters for isRecordAll mode)
    local batchSize = BurdJournals.getSandboxOption("RecordBatchSize") or 15
    if batchSize < 1 then batchSize = 1 end

    local savedQueue = {}
    if not self.isRecordAll then
        -- For individual clicks, process one-at-a-time queue (legacy behavior)
        for _, item in ipairs(self.queuedRecords or {}) do
            table.insert(savedQueue, item)
        end

        if panel.recordingState and panel.recordingState.queue then
            for _, item in ipairs(panel.recordingState.queue) do
                local isDupe = false
                for _, existing in ipairs(savedQueue) do
                    if existing.name == item.name then
                        isDupe = true
                        break
                    end
                end
                if not isDupe then
                    table.insert(savedQueue, item)
                end
            end
        end

        -- Process one item at a time for individual clicks
        if #savedQueue > 0 then
            local nextRecord = table.remove(savedQueue, 1)

            panel.recordingState = {
                active = true,
                skillName = nextRecord.type == "skill" and nextRecord.name or nil,
                traitId = nextRecord.type == "trait" and nextRecord.name or nil,
                statId = nextRecord.type == "stat" and nextRecord.name or nil,
                recipeName = nextRecord.type == "recipe" and nextRecord.name or nil,
                isRecordAll = false,
                progress = 0,
                totalTime = 0,
                startTime = 0,
                pendingRecords = {nextRecord},
                currentIndex = 1,
                queue = savedQueue,
            }

            if panel.skillList and panel.journal then
                panel:refreshCurrentList()
            end

            local nextRecords = {nextRecord}
            local journalForNextAction = panel.journal or self.journal
            local action = BurdJournals.RecordToJournalAction:new(player, journalForNextAction, nextRecords, false, panel, savedQueue)
            ISTimedActionQueue.add(action)

            ISBaseTimedAction.perform(self)
            return
        end
    else
        -- For "Record All" mode, process in batches
        savedQueue = self.queuedRecords or {}

        if #savedQueue > 0 then
            -- Extract next batch
            local nextBatch = {}
            local remaining = {}

            for i, item in ipairs(savedQueue) do
                if i <= batchSize then
                    table.insert(nextBatch, item)
                else
                    table.insert(remaining, item)
                end
            end

            BurdJournals.debugPrint("[BurdJournals] RecordToJournalAction:perform - Next batch: " .. #nextBatch .. " items, remaining: " .. #remaining)

            local firstRecord = nextBatch[1]
            panel.recordingState = {
                active = true,
                skillName = firstRecord and firstRecord.type == "skill" and firstRecord.name or nil,
                traitId = firstRecord and firstRecord.type == "trait" and firstRecord.name or nil,
                statId = firstRecord and firstRecord.type == "stat" and firstRecord.name or nil,
                recipeName = firstRecord and firstRecord.type == "recipe" and firstRecord.name or nil,
                isRecordAll = true,
                progress = 0,
                totalTime = 0,
                startTime = 0,
                pendingRecords = nextBatch,
                currentIndex = 1,
                queue = remaining,
            }

            if panel.skillList and panel.journal then
                panel:refreshCurrentList()
            end

            local journalForNextAction = panel.journal or self.journal
            local action = BurdJournals.RecordToJournalAction:new(player, journalForNextAction, nextBatch, true, panel, remaining)
            ISTimedActionQueue.add(action)

            ISBaseTimedAction.perform(self)
            return
        end
    end

    panel.processingRecordQueue = false
    panel.recordingCompleted = true

    panel.recordingState = {
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

    ISBaseTimedAction.perform(self)
end

function BurdJournals.queueLearnAction(player, journal, rewards, isAbsorbAll, mainPanel)
    if not player or not journal then return false end
    if not rewards or #rewards == 0 then return false end

    local canUseLight, lightReason = isJournalLightAllowed(player)
    if not canUseLight then
        notifyTooDark(player, lightReason)
        -- Return true so callers don't show unrelated "already reading" errors.
        return true
    end

    -- Get batch size from sandbox option (default 15, min 1)
    local batchSize = BurdJournals.getSandboxOption("AbsorbBatchSize") or 15
    if batchSize < 1 then batchSize = 1 end

    if isAbsorbAll and #rewards > 1 then
        -- Extract first batch of rewards
        local batch = {}
        local remaining = {}

        for i, reward in ipairs(rewards) do
            if i <= batchSize then
                table.insert(batch, reward)
            else
                table.insert(remaining, reward)
            end
        end

        BurdJournals.debugPrint("[BurdJournals] queueLearnAction: Batching - batch size=" .. #batch .. ", remaining=" .. #remaining)
        local action = BurdJournals.LearnFromJournalAction:new(
            player, journal, batch, true, mainPanel, remaining
        )
        if action and action.character then
            ISTimedActionQueue.add(action)
        else
            BurdJournals.debugPrint("[BurdJournals] queueLearnAction: FAILED - invalid learn action (missing character)")
            return false
        end
    else
        -- Single item absorbing (individual clicks)
        local action = BurdJournals.LearnFromJournalAction:new(
            player, journal, rewards, isAbsorbAll, mainPanel
        )
        if action and action.character then
            ISTimedActionQueue.add(action)
        else
            BurdJournals.debugPrint("[BurdJournals] queueLearnAction: FAILED - invalid learn action (missing character)")
            return false
        end
    end
    return true
end

function BurdJournals.queueRecordAction(player, journal, records, isRecordAll, mainPanel)
    BurdJournals.debugPrint("[BurdJournals] queueRecordAction called with " .. #records .. " records, isRecordAll=" .. tostring(isRecordAll))
    if not player or not journal then
        BurdJournals.debugPrint("[BurdJournals] queueRecordAction: FAILED - player or journal is nil")
        return false
    end
    if not records or #records == 0 then
        BurdJournals.debugPrint("[BurdJournals] queueRecordAction: FAILED - no records to queue")
        return false
    end

    local canUseLight, lightReason = isJournalLightAllowed(player)
    if not canUseLight then
        notifyTooDark(player, lightReason)
        -- Return true so callers don't show unrelated "cannot record" errors.
        return true
    end

    -- Get batch size from sandbox option (default 15, min 1)
    local batchSize = BurdJournals.getSandboxOption("RecordBatchSize") or 15
    if batchSize < 1 then batchSize = 1 end

    if isRecordAll and #records > 1 then
        -- Extract first batch of records
        local batch = {}
        local remaining = {}

        for i, record in ipairs(records) do
            if i <= batchSize then
                table.insert(batch, record)
            else
                table.insert(remaining, record)
            end
        end

        BurdJournals.debugPrint("[BurdJournals] queueRecordAction: Batching - batch size=" .. #batch .. ", remaining=" .. #remaining)
        local action = BurdJournals.RecordToJournalAction:new(
            player, journal, batch, true, mainPanel, remaining
        )
        if action and action.character then
            ISTimedActionQueue.add(action)
        else
            BurdJournals.debugPrint("[BurdJournals] queueRecordAction: FAILED - invalid record action (missing character)")
            return false
        end
        BurdJournals.debugPrint("[BurdJournals] queueRecordAction: Batch action added to queue")
    else
        -- Single item recording (individual clicks)
        BurdJournals.debugPrint("[BurdJournals] queueRecordAction: Single item - " .. tostring(records[1] and records[1].name))
        local action = BurdJournals.RecordToJournalAction:new(
            player, journal, records, isRecordAll, mainPanel
        )
        if action and action.character then
            ISTimedActionQueue.add(action)
        else
            BurdJournals.debugPrint("[BurdJournals] queueRecordAction: FAILED - invalid record action (missing character)")
            return false
        end
        BurdJournals.debugPrint("[BurdJournals] queueRecordAction: Action added to queue")
    end
    return true
end

BurdJournals.EraseEntryAction = ISBaseTimedAction:derive("BurdJournals_EraseEntryAction")

function BurdJournals.EraseEntryAction:new(character, journal, entryType, entryName, mainPanel)
    local o = ISBaseTimedAction.new(self, character)

    o.journal = journal
    o.entryType = entryType
    o.entryName = entryName
    o.mainPanel = mainPanel
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local eraseTime = 2.0
    o.maxTime = math.floor(eraseTime * 33)

    return o
end

function BurdJournals.EraseEntryAction:isValid()
    local player = self.character
    if not player then return false end

    local journal = BurdJournals.findItemById(player, self.journal:getID())
    if not journal then return false end

    if not BurdJournals.hasEraser(player) then return false end

    if self.mainPanel and not self.mainPanel:isVisible() then
        return false
    end

    return true
end

function BurdJournals.EraseEntryAction:update()
    self.character:setMetabolicTarget(Metabolics.LightWork)

    if self.mainPanel and self.mainPanel.erasingState then
        local progress = self:getJobDelta()
        self.mainPanel.erasingState.progress = progress
    end
end

function BurdJournals.EraseEntryAction:start()

    self:setAnimVariable("ReadType", "book")
    self:setActionAnim(CharacterActionAnims.Read)
    self:setOverrideHandModels(nil, self.journal)
    self.character:setReading(true)
    self.character:reportEvent("EventRead")

    self.character:playSound("OpenBook")

    if self.mainPanel then
        -- Preserve the queue when setting erasingState
        local existingQueue = self.mainPanel.erasingState and self.mainPanel.erasingState.queue or {}
        self.mainPanel.erasingState = {
            active = true,
            entryType = self.entryType,
            entryName = self.entryName,
            progress = 0,
            queue = existingQueue,
        }
    end
end

function BurdJournals.EraseEntryAction:stop()

    self.character:setReading(false)
    self.character:playSound("CloseBook")

    if self.mainPanel then
        -- Preserve the queue when resetting erasingState
        local existingQueue = self.mainPanel.erasingState and self.mainPanel.erasingState.queue or {}
        self.mainPanel.erasingState = {
            active = false,
            entryType = nil,
            entryName = nil,
            queue = existingQueue,
        }
    end

    ISBaseTimedAction.stop(self)
end

function BurdJournals.EraseEntryAction:perform()

    self.character:setReading(false)
    self.character:playSound("CloseBook")

    local player = self.character
    local panel = self.mainPanel

    if panel then
        -- Preserve the queue when resetting erasingState
        local existingQueue = panel.erasingState and panel.erasingState.queue or {}
        panel.erasingState = {
            active = false,
            entryType = nil,
            entryName = nil,
            queue = existingQueue,
        }
    end

    if isClient() and not isServer() then
        sendClientCommand(player, "BurdJournals", "eraseEntry", {
            journalId = self.journal:getID(),
            entryType = self.entryType,
            entryName = self.entryName
        })
    else

        if panel and panel.eraseEntryDirectly then
            panel:eraseEntryDirectly(self.entryType, self.entryName)
        end
    end

    -- Process next item in erase queue
    if panel and panel.processNextEraseInQueue then
        panel:processNextEraseInQueue()
    end

    ISBaseTimedAction.perform(self)
end

function BurdJournals.queueEraseAction(player, journal, entryType, entryName, mainPanel)
    if not player or not journal then return false end
    if not entryType or not entryName then return false end

    local action = BurdJournals.EraseEntryAction:new(player, journal, entryType, entryName, mainPanel)
    ISTimedActionQueue.add(action)
    return true
end
