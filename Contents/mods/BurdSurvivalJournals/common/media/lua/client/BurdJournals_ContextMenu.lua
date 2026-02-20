
require "BurdJournals_Shared"
require "BurdJournals_TimedActions"
require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISInventoryTransferAction"

BurdJournals = BurdJournals or {}
BurdJournals.ContextMenu = BurdJournals.ContextMenu or {}

function BurdJournals.ContextMenu.isInPlayerMainInventory(player, item)
    if not player or not item then return false end
    local mainInventory = player:getInventory()
    if not mainInventory then return false end

    local itemContainer = item:getContainer()
    return itemContainer == mainInventory
end

function BurdJournals.ContextMenu.isInPlayerContainers(player, item)
    if not player or not item then return false end

    local itemContainer = item:getContainer()
    if not itemContainer then return false end

    if itemContainer == player:getInventory() then
        return true
    end

    local wornItems = player:getWornItems()
    if wornItems then

        for i = 1, wornItems:size() do
            local wornItem = wornItems:get(i - 1)
            if wornItem then
                local actualItem = wornItem:getItem()
                if actualItem and actualItem:IsInventoryContainer() then
                    local bagContainer = actualItem:getItemContainer()
                    if bagContainer and itemContainer == bagContainer then
                        return true
                    end
                end
            end
        end
    end

    return false
end

function BurdJournals.ContextMenu.getExternalReturnContainer(player, sourceContainer)
    if not player or not sourceContainer then return nil end
    if sourceContainer.getType and sourceContainer:getType() == "floor" then
        return nil
    end
    if sourceContainer.isInCharacterInventory and sourceContainer:isInCharacterInventory(player) then
        return nil
    end
    return sourceContainer
end

function BurdJournals.ContextMenu.pickUpThenDo(player, item, callback)
    if not player or not item or not callback then return end

    -- Already in main inventory - just call callback immediately
    if BurdJournals.ContextMenu.isInPlayerMainInventory(player, item) then
        callback(player, item, nil)
        return
    end

    local sourceContainer = item:getContainer()
    if not sourceContainer then
        callback(player, item, nil)
        return
    end

    local returnContainer = BurdJournals.ContextMenu.getExternalReturnContainer(player, sourceContainer)

    -- Store item ID for lookup after transfer (item reference may become stale)
    local itemId = item:getID()
    local destContainer = player:getInventory()

    -- Queue transfer action
    ISTimedActionQueue.add(ISInventoryTransferAction:new(player, item, sourceContainer, destContainer))

    -- Wait for transfer to complete, using ID to find item
    local checkTicks = 0
    local maxTicks = 300
    local checkTransfer
    checkTransfer = function()
        checkTicks = checkTicks + 1

        -- Find item by ID in player's inventory (item reference may be stale after transfer)
        local foundItem = BurdJournals.findItemById(player, itemId)
        if foundItem and BurdJournals.ContextMenu.isInPlayerMainInventory(player, foundItem) then
            Events.OnTick.Remove(checkTransfer)
            callback(player, foundItem, returnContainer)  -- Use found item, not original reference
            return
        end

        if checkTicks >= maxTicks then
            Events.OnTick.Remove(checkTransfer)
            BurdJournals.debugPrint("[BurdJournals] pickUpThenDo: Transfer timed out for item ID " .. tostring(itemId))
            return
        end
    end
    Events.OnTick.Add(checkTransfer)
end

function BurdJournals.ContextMenu.getTooDarkMessage()
    local msg = (getText and getText("ContextMenu_TooDark")) or "Too dark to read."
    if msg == "ContextMenu_TooDark" then
        msg = "Too dark to read."
    end
    return msg
end

function BurdJournals.ContextMenu.requireLightOrNotify(player)
    if not BurdJournals.canUseJournalInCurrentLight then
        return true
    end

    local canUse, reason = BurdJournals.canUseJournalInCurrentLight(player)
    if canUse then
        return true
    end

    local message = reason or BurdJournals.ContextMenu.getTooDarkMessage()
    if HaloTextHelper and HaloTextHelper.addBadText and player then
        HaloTextHelper.addBadText(player, message)
    elseif player and player.Say then
        player:Say(message)
    end
    return false
end

function BurdJournals.ContextMenu.applyLightRequirement(option, player)
    if not option then return end
    if not BurdJournals.requiresLightForJournalUse or not BurdJournals.requiresLightForJournalUse() then
        return
    end

    local canUse, reason = BurdJournals.canUseJournalInCurrentLight(player)
    if canUse then
        return
    end

    local message = reason or BurdJournals.ContextMenu.getTooDarkMessage()
    option.notAvailable = true

    local tooltip = option.toolTip
    if not tooltip then
        tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("ContextMenu_TooDark") or "Too dark")
    end

    if tooltip.description and tooltip.description ~= "" then
        if not string.find(tooltip.description, message, 1, true) then
            tooltip.description = tooltip.description .. "\n\n" .. message
        end
    else
        tooltip.description = message
    end

    option.toolTip = tooltip
end

function BurdJournals.ContextMenu.onFillInventoryObjectContextMenu(playerNum, context, items)

    if not BurdJournals.isEnabled() then

        return
    end

    local player = getSpecificPlayer(playerNum)
    if not player then

        return
    end

    local itemList = {}
    for i, v in ipairs(items) do
        if instanceof(v, "InventoryItem") then

            table.insert(itemList, v)
        elseif type(v) == "table" and v.items then

            local stackItems = v.items
            if stackItems.size then

                for j = 0, stackItems:size() - 1 do
                    local item = stackItems:get(j)
                    table.insert(itemList, item)
                end
            else

                for j, item in ipairs(stackItems) do
                    table.insert(itemList, item)
                end
            end
        end
    end

    for _, item in ipairs(itemList) do
        local fullType = item:getFullType()
        local isJournal = BurdJournals.isAnyJournal(item)

        if isJournal then
            BurdJournals.ContextMenu.addJournalOptions(context, player, item)
            break
        end
    end
end

function BurdJournals.ContextMenu.removeVanillaReadOptions(context)

    local vanillaReadTexts = {
        getText("ContextMenu_Read") or "Read",
        getText("ContextMenu_ReRead") or "Re-read",
        getText("ContextMenu_Look_at_picture") or "Look at picture",
        getText("ContextMenu_Look_at_pictures") or "Look at pictures",
        getText("ContextMenu_ReLook_at_picture") or "Re-look at picture",
        getText("ContextMenu_ReLook_at_pictures") or "Re-look at pictures",
    }

    local optionsToRemove = {}
    if context.options then
        for i, option in ipairs(context.options) do
            if option.name then
                for _, vanillaText in ipairs(vanillaReadTexts) do
                    if option.name == vanillaText then
                        table.insert(optionsToRemove, i)
                        break
                    end
                end
            end
        end
    end

    for i = #optionsToRemove, 1, -1 do
        table.remove(context.options, optionsToRemove[i])
    end
end

function BurdJournals.ContextMenu.addJournalOptions(context, player, journal)

    if not context or not player or not journal then return end

    BurdJournals.ContextMenu.removeVanillaReadOptions(context)

    if BurdJournals.isPlayerIlliterate(player) then
        local illiterateOption = context:addOption(
            getText("ContextMenu_BurdJournals_CannotRead") or "Cannot Read (Illiterate)",
            nil, nil
        )
        illiterateOption.notAvailable = true
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_IlliterateName") or "Illiterate")
        tooltip.description = getText("Tooltip_BurdJournals_IlliterateDesc") or "You cannot read or write. Journals are useless to you."
        illiterateOption.toolTip = tooltip
        return
    end

    local isBloody = BurdJournals.isBloody(journal)
    local isWorn = BurdJournals.isWorn(journal)
    local isClean = BurdJournals.isClean(journal)
    local isBlank = BurdJournals.isBlankJournal(journal)
    local isFilled = BurdJournals.isFilledJournal(journal)
    local isCursedItem = BurdJournals.isCursedJournalItem and BurdJournals.isCursedJournalItem(journal)

    if isCursedItem then
        BurdJournals.ContextMenu.addCursedJournalOptions(context, player, journal)
        return
    end

    if isBloody then

        BurdJournals.ContextMenu.addBloodyJournalOptions(context, player, journal, isBlank)
    elseif isWorn then

        BurdJournals.ContextMenu.addWornJournalOptions(context, player, journal, isBlank)
    elseif isClean then

        if isFilled then
            BurdJournals.ContextMenu.addCleanFilledJournalOptions(context, player, journal)
        else
            BurdJournals.ContextMenu.addCleanBlankJournalOptions(context, player, journal)
        end
    else
    end
end

function BurdJournals.ContextMenu.addCursedJournalOptions(context, player, journal)
    local openOption = context:addOption(
        getText("ContextMenu_BurdJournals_OpenCursedJournal") or "Break the Seal...",
        player,
        BurdJournals.ContextMenu.onOpenCursedJournal,
        journal
    )
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip:setVisible(false)
    tooltip:setName(getText("Tooltip_BurdJournals_CursedJournalName") or "Cursed Journal")
    tooltip.description = getText("Tooltip_BurdJournals_CursedJournalDesc")
        or "An unsettling journal. The first reader will pay a price."
    openOption.toolTip = tooltip
    BurdJournals.ContextMenu.applyLightRequirement(openOption, player)
end

function BurdJournals.ContextMenu.addBloodyJournalOptions(context, player, journal, isBlank)
    local journalData = BurdJournals.getJournalData(journal)
    local isFilled = BurdJournals.isFilledJournal(journal)

    if isFilled and journalData then

        local skillCount = 0
        local totalSkills = 0
        local traitCount = 0
        local totalTraits = 0
        local recipeCount = 0
        local totalRecipes = 0

        if journalData.skills then
            for skillName, _ in pairs(journalData.skills) do
                totalSkills = totalSkills + 1
                if not BurdJournals.hasCharacterClaimedSkill(journalData, player, skillName) then
                    skillCount = skillCount + 1
                end
            end
        end
        if journalData.traits then
            for traitId, _ in pairs(journalData.traits) do
                totalTraits = totalTraits + 1
                if not BurdJournals.hasCharacterClaimedTrait(journalData, player, traitId) then
                    traitCount = traitCount + 1
                end
            end
        end
        if journalData.recipes then
            for recipeName, _ in pairs(journalData.recipes) do
                totalRecipes = totalRecipes + 1
                if not BurdJournals.hasCharacterClaimedRecipe(journalData, player, recipeName) then
                    recipeCount = recipeCount + 1
                end
            end
        end

        local remaining = skillCount + traitCount + recipeCount

        local openOption = context:addOption(
            getText("ContextMenu_BurdJournals_OpenJournal") or "Open Journal...",
            player,
            BurdJournals.ContextMenu.onOpenBloodyJournal,
            journal
        )
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_BloodyJournal") or "Bloody Journal")

        local tooltipDesc = ""
        if totalSkills > 0 then
            tooltipDesc = tooltipDesc .. (getText("Tooltip_BurdJournals_SkillsAvailable") or "Skills: %d/%d available"):gsub("%%d/%%d", skillCount .. "/" .. totalSkills) .. "\n"
        end
        if totalTraits > 0 then
            tooltipDesc = tooltipDesc .. (getText("Tooltip_BurdJournals_TraitsAvailable") or "Traits: %d/%d available"):gsub("%%d/%%d", traitCount .. "/" .. totalTraits) .. "\n"
        end
        if totalRecipes > 0 then
            tooltipDesc = tooltipDesc .. (getText("Tooltip_BurdJournals_RecipesAvailable") or "Recipes: %d/%d available"):gsub("%%d/%%d", recipeCount .. "/" .. totalRecipes) .. "\n"
        end
        if tooltipDesc == "" then
            tooltipDesc = (getText("Tooltip_BurdJournals_NoRewardsFound") or "No rewards found") .. "\n"
        end
        tooltipDesc = tooltipDesc .. "\n" .. (getText("Tooltip_BurdJournals_BloodyDesc") or "Rare find! May contain valuable traits.")
        tooltip.description = tooltipDesc
        openOption.toolTip = tooltip
        BurdJournals.ContextMenu.applyLightRequirement(openOption, player)

        if remaining > 0 then

            local parts = {}
            if skillCount > 0 then
                local skillKey = skillCount > 1 and "ContextMenu_BurdJournals_SkillsCount" or "ContextMenu_BurdJournals_SkillCount"
                table.insert(parts, string.format(getText(skillKey) or "%d skills", skillCount))
            end
            if traitCount > 0 then
                local traitKey = traitCount > 1 and "ContextMenu_BurdJournals_TraitsCount" or "ContextMenu_BurdJournals_TraitCount"
                table.insert(parts, string.format(getText(traitKey) or "%d traits", traitCount))
            end
            if recipeCount > 0 then
                local recipeKey = recipeCount > 1 and "ContextMenu_BurdJournals_RecipesCount" or "ContextMenu_BurdJournals_RecipeCount"
                table.insert(parts, string.format(getText(recipeKey) or "%d recipes", recipeCount))
            end

            local absorbLabel
            if #parts > 0 then
                local absorbAllBase = getText("ContextMenu_BurdJournals_AbsorbAllFormat") or "Absorb All (%s)"
                absorbLabel = string.format(absorbAllBase, table.concat(parts, ", "))
            else
                absorbLabel = getText("Tooltip_BurdJournals_AbsorbAllRewards") or "Absorb All Rewards"
            end

            local absorbAllOption = context:addOption(
                absorbLabel,
                player,
                BurdJournals.ContextMenu.onAbsorbAllConfirm,
                journal
            )
            local tooltip2 = ISToolTip:new()
            tooltip2:initialise()
            tooltip2:setVisible(false)
            tooltip2:setName(getText("Tooltip_BurdJournals_AbsorbAllRewards") or "Absorb All Rewards")
            tooltip2.description = getText("Tooltip_BurdJournals_AbsorbAllDesc") or "Opens the journal and begins reading all rewards.\nRequires time to absorb each skill, trait, and recipe.\nMaxed skills and known items will be skipped."
            absorbAllOption.toolTip = tooltip2
            BurdJournals.ContextMenu.applyLightRequirement(absorbAllOption, player)
        end
    else

        local infoOption = context:addOption(
            getText("ContextMenu_BurdJournals_BloodyBlank") or "Bloody Blank Journal",
            nil, nil
        )
        infoOption.notAvailable = true
    end

    if BurdJournals.isPlayerJournalsEnabled() then
        local craftOption = context:addOption(
            getText("ContextMenu_BurdJournals_ConvertViaCrafting") or "Convert to Personal Journal...",
            nil, nil
        )
        craftOption.notAvailable = true
        local tooltip3 = ISToolTip:new()
        tooltip3:initialise()
        tooltip3:setVisible(false)
        tooltip3:setName(getText("Tooltip_BurdJournals_CraftingRequired") or "Crafting Required")
        tooltip3.description = getText("Tooltip_BurdJournals_ConvertBloodyDesc") or "Open the crafting menu (B) to find 'Clean and Convert Bloody Journal'.\nRequires: Soap, Cloth, Leather, Thread, Needle, Tailoring Lv1.\nWARNING: Destroys any remaining rewards!"
        craftOption.toolTip = tooltip3
    end
end

function BurdJournals.ContextMenu.addWornJournalOptions(context, player, journal, isBlank)

    if not context or not player or not journal then return end

    local journalData = BurdJournals.getJournalData(journal)
        local isFilled = BurdJournals.isFilledJournal(journal)

        if isFilled and journalData then

            local skillCount = 0
            local totalSkills = 0
            local traitCount = 0
            local totalTraits = 0
            local recipeCount = 0
            local totalRecipes = 0

            if journalData.skills then
                for skillName, _ in pairs(journalData.skills) do
                    totalSkills = totalSkills + 1
                    if not BurdJournals.hasCharacterClaimedSkill(journalData, player, skillName) then
                        skillCount = skillCount + 1
                    end
                end
            end
            if journalData.traits then
                for traitId, _ in pairs(journalData.traits) do
                    totalTraits = totalTraits + 1
                    if not BurdJournals.hasCharacterClaimedTrait(journalData, player, traitId) then
                        traitCount = traitCount + 1
                    end
                end
            end
            if journalData.recipes then
                for recipeName, _ in pairs(journalData.recipes) do
                    totalRecipes = totalRecipes + 1
                    if not BurdJournals.hasCharacterClaimedRecipe(journalData, player, recipeName) then
                        recipeCount = recipeCount + 1
                    end
                end
            end

            local remaining = skillCount + traitCount + recipeCount

            local openText = getText("ContextMenu_BurdJournals_OpenJournal") or "Open Journal..."

            local openOption = context:addOption(
                openText,
                player,
                BurdJournals.ContextMenu.onOpenWornJournal,
                journal
            )
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_WornJournal") or "Worn Journal")

        local tooltipDesc = ""
        if totalSkills > 0 then
            tooltipDesc = (getText("Tooltip_BurdJournals_SkillsAvailable") or "Skills: %d/%d available"):gsub("%%d/%%d", skillCount .. "/" .. totalSkills) .. "\n"
        end
        if totalRecipes > 0 then
            tooltipDesc = tooltipDesc .. (getText("Tooltip_BurdJournals_RecipesAvailable") or "Recipes: %d/%d available"):gsub("%%d/%%d", recipeCount .. "/" .. totalRecipes) .. "\n"
        end
        if tooltipDesc == "" then
            tooltipDesc = getText("Tooltip_BurdJournals_NoRewardsFound") or "No rewards found"
        end
        tooltip.description = tooltipDesc
        openOption.toolTip = tooltip
        BurdJournals.ContextMenu.applyLightRequirement(openOption, player)

        if remaining > 0 then

            local parts = {}
            if skillCount > 0 then
                local skillKey = skillCount > 1 and "ContextMenu_BurdJournals_SkillsCount" or "ContextMenu_BurdJournals_SkillCount"
                table.insert(parts, string.format(getText(skillKey) or "%d skills", skillCount))
            end
            if traitCount > 0 then
                local traitKey = traitCount > 1 and "ContextMenu_BurdJournals_TraitsCount" or "ContextMenu_BurdJournals_TraitCount"
                table.insert(parts, string.format(getText(traitKey) or "%d traits", traitCount))
            end
            if recipeCount > 0 then
                local recipeKey = recipeCount > 1 and "ContextMenu_BurdJournals_RecipesCount" or "ContextMenu_BurdJournals_RecipeCount"
                table.insert(parts, string.format(getText(recipeKey) or "%d recipes", recipeCount))
            end

            local absorbLabel
            if #parts > 0 then
                local absorbAllBase = getText("ContextMenu_BurdJournals_AbsorbAllFormat") or "Absorb All (%s)"
                absorbLabel = string.format(absorbAllBase, table.concat(parts, ", "))
            else
                absorbLabel = getText("Tooltip_BurdJournals_AbsorbAllRewards") or "Absorb All Rewards"
            end

            local absorbAllOption = context:addOption(
                absorbLabel,
                player,
                BurdJournals.ContextMenu.onAbsorbAllConfirm,
                journal
            )
            local tooltip2 = ISToolTip:new()
            tooltip2:initialise()
            tooltip2:setVisible(false)
            tooltip2:setName(getText("Tooltip_BurdJournals_AbsorbAllRewards") or "Absorb All Rewards")
            tooltip2.description = getText("Tooltip_BurdJournals_AbsorbAllDesc") or "Opens the journal and begins reading all rewards.\nRequires time to absorb each skill, trait, and recipe.\nMaxed skills and known items will be skipped."
            absorbAllOption.toolTip = tooltip2
            BurdJournals.ContextMenu.applyLightRequirement(absorbAllOption, player)
        end
    else

        local infoOption = context:addOption(
            getText("ContextMenu_BurdJournals_WornBlank") or "Worn Blank Journal",
            nil, nil
        )
        infoOption.notAvailable = true
    end

    if BurdJournals.isPlayerJournalsEnabled() then
        local canConvert = BurdJournals.canConvertToClean(player)
        local convertOption = context:addOption(
            getText("ContextMenu_BurdJournals_ConvertToClean") or "Convert to Personal Journal",
            player,
            BurdJournals.ContextMenu.onConvertToClean,
            journal
        )
        if not canConvert then
            convertOption.notAvailable = true
            local tooltip3 = ISToolTip:new()
            tooltip3:initialise()
            tooltip3:setVisible(false)
            tooltip3:setName(getText("Tooltip_BurdJournals_CannotConvert") or "Cannot Convert")
            tooltip3.description = getText("Tooltip_BurdJournals_NeedsConvertMaterials") or "Requires: Leather + Thread + Needle + Tailoring Lv1"
            convertOption.toolTip = tooltip3
        else
            local tooltip3 = ISToolTip:new()
            tooltip3:initialise()
            tooltip3:setVisible(false)
            tooltip3:setName(getText("Tooltip_BurdJournals_ConvertToClean") or "Convert to Personal Journal")
            tooltip3.description = getText("Tooltip_BurdJournals_ConvertToCleanDesc") or "Restore this worn journal to a clean blank journal for personal use."
            convertOption.toolTip = tooltip3
        end
    end

end

function BurdJournals.ContextMenu.addCleanFilledJournalOptions(context, player, journal)
    local journalData = BurdJournals.getJournalData(journal)
    local hasPen = BurdJournals.hasWritingTool(player)
    local hasEraser = BurdJournals.hasEraser(player)

    local canOpen, openReason = BurdJournals.canPlayerOpenJournal(player, journal)
    local canClaim, claimReason = BurdJournals.canPlayerClaimFromJournal(player, journal)
    local isOwner = BurdJournals.isJournalOwner(player, journal)

    local claimableSkills = 0
    local claimableTraits = 0
    local totalRecorded = 0
    if journalData then
        if journalData.skills then
            for skillName, skillData in pairs(journalData.skills) do
                totalRecorded = totalRecorded + 1
                local perk = BurdJournals.getPerkByName(skillName)
                if perk then
                    local playerXP = player:getXp():getXP(perk)
                    if playerXP < (skillData.xp or 0) then
                        claimableSkills = claimableSkills + 1
                    end
                end
            end
        end
        if journalData.traits then
            for traitId, _ in pairs(journalData.traits) do
                totalRecorded = totalRecorded + 1
                if not BurdJournals.playerHasTrait(player, traitId) then
                    claimableTraits = claimableTraits + 1
                end
            end
        end
    end
    local totalClaimable = claimableSkills + claimableTraits

    local openOption = context:addOption(
        getText("ContextMenu_BurdJournals_OpenJournal") or "Open Journal...",
        player,
        BurdJournals.ContextMenu.onOpenCleanJournal,
        journal
    )
    if not canOpen then
        openOption.notAvailable = true
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_CannotOpen") or "Cannot Open")
        tooltip.description = openReason or "You don't have permission to open this journal."
        openOption.toolTip = tooltip
    elseif journalData then
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_PersonalJournal") or "Personal Survival Journal")
        local author = journalData.author or (getText("UI_BurdJournals_Unknown") or "Unknown")
        local desc = (getText("Tooltip_BurdJournals_WrittenBy") or "Written by: %s"):gsub("%%s", author) .. "\n"
        local itemText = totalRecorded > 1 and (getText("Tooltip_BurdJournals_RecordedItems") or "Contains %d recorded items") or (getText("Tooltip_BurdJournals_RecordedItem") or "Contains %d recorded item")
        desc = desc .. string.format(itemText, totalRecorded) .. "\n\n"
        if claimableSkills > 0 or claimableTraits > 0 then
            if canClaim then
                desc = desc .. (getText("Tooltip_BurdJournals_ClaimableRewards") or "Claimable rewards:") .. "\n"
                if claimableSkills > 0 then
                    local skillText = claimableSkills > 1 and (getText("Tooltip_BurdJournals_SkillsCount") or "  - %d skills") or (getText("Tooltip_BurdJournals_SkillCount") or "  - %d skill")
                    desc = desc .. string.format(skillText, claimableSkills) .. "\n"
                end
                if claimableTraits > 0 then
                    local traitText = claimableTraits > 1 and (getText("Tooltip_BurdJournals_TraitsCount") or "  - %d traits") or (getText("Tooltip_BurdJournals_TraitCount") or "  - %d trait")
                    desc = desc .. string.format(traitText, claimableTraits) .. "\n"
                end
            else
                desc = desc .. (getText("Tooltip_BurdJournals_ViewOnly") or "View only") .. " - " .. (claimReason or (getText("Tooltip_BurdJournals_CannotClaimDefault") or "Cannot claim from this journal.")) .. "\n"
            end
        else
            desc = desc .. (getText("Tooltip_BurdJournals_NoNewRewards") or "No new rewards available.") .. "\n"
        end
        desc = desc .. "\n" .. (getText("Tooltip_BurdJournals_ClaimingInfo") or "Claiming sets your XP to the recorded level (if higher).")
        tooltip.description = desc
        openOption.toolTip = tooltip
    end
    BurdJournals.ContextMenu.applyLightRequirement(openOption, player)

    if hasPen and isOwner then
        local recordOption = context:addOption(
            getText("ContextMenu_BurdJournals_UpdateRecords") or "Update Records",
            player,
            BurdJournals.ContextMenu.onRecordProgress,
            journal
        )
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_UpdateRecords") or "Update Journal Records")
        tooltip.description = getText("Tooltip_BurdJournals_UpdateRecordsDesc") or "Opens journal to update your recorded skills.\nRecorded values are only updated if your current level is higher."
        recordOption.toolTip = tooltip
        BurdJournals.ContextMenu.applyLightRequirement(recordOption, player)
    end

    if totalClaimable > 0 and canOpen then
        local claimAllOption = context:addOption(
            getText("ContextMenu_BurdJournals_ClaimAll") or "Claim All",
            player,
            BurdJournals.ContextMenu.onClaimAllConfirm,
            journal
        )
        if not canClaim then
            claimAllOption.notAvailable = true
            local tooltip = ISToolTip:new()
            tooltip:initialise()
            tooltip:setVisible(false)
            tooltip:setName(getText("Tooltip_BurdJournals_CannotClaim") or "Cannot Claim")
            tooltip.description = claimReason or (getText("Tooltip_BurdJournals_NoPermissionClaim") or "You don't have permission to claim from this journal.")
            claimAllOption.toolTip = tooltip
        else
            local tooltip = ISToolTip:new()
            tooltip:initialise()
            tooltip:setVisible(false)
            tooltip:setName(getText("Tooltip_BurdJournals_ClaimAll") or "Claim All Skills")
            local desc = (getText("Tooltip_BurdJournals_ClaimAllDesc") or "Opens journal and claims all available skills.") .. "\n\n"
            local skillText = claimableSkills > 1 and (getText("Tooltip_BurdJournals_AvailableSkills") or "Available: %d skills") or (getText("Tooltip_BurdJournals_AvailableSkill") or "Available: %d skill")
            desc = desc .. string.format(skillText, claimableSkills)
            if claimableTraits > 0 then
                local traitText = claimableTraits > 1 and (getText("Tooltip_BurdJournals_AndTraits") or ", %d traits") or (getText("Tooltip_BurdJournals_AndTrait") or ", %d trait")
                desc = desc .. string.format(traitText, claimableTraits)
            end
            desc = desc .. "\n\n" .. (getText("Tooltip_BurdJournals_ReadingSpeedNote") or "This will take time based on your reading speed.")
            tooltip.description = desc
            claimAllOption.toolTip = tooltip
        end
        BurdJournals.ContextMenu.applyLightRequirement(claimAllOption, player)
    end

    if isOwner then
        context:addOption(
            getText("ContextMenu_BurdJournals_Rename") or "Rename",
            player,
            BurdJournals.ContextMenu.onRenameJournal,
            journal
        )
    end

    if hasEraser and isOwner then
        local eraseOption = context:addOption(
            getText("ContextMenu_BurdJournals_EraseJournal") or "Erase Journal",
            player,
            BurdJournals.ContextMenu.onEraseJournal,
            journal
        )
        local tooltip = ISToolTip:new()
        tooltip:initialise()
        tooltip:setVisible(false)
        tooltip:setName(getText("Tooltip_BurdJournals_EraseContents") or "Erase All Contents")
        tooltip.description = getText("Tooltip_BurdJournals_EraseContentsDesc") or "Erases all recorded data, returning the journal to a blank state.\nRequires an eraser."
        eraseOption.toolTip = tooltip
    end
end

function BurdJournals.ContextMenu.addCleanBlankJournalOptions(context, player, journal)
    local hasPen = BurdJournals.hasWritingTool(player)

    local openOption = context:addOption(
        getText("ContextMenu_BurdJournals_OpenJournal") or "Open Journal...",
        player,
        BurdJournals.ContextMenu.onRecordProgress,
        journal
    )
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip:setVisible(false)
    tooltip:setName(getText("Tooltip_BurdJournals_BlankJournal") or "Blank Survival Journal")
    tooltip.description = getText("Tooltip_BurdJournals_BlankJournalDesc") or "Opens the journal to record your survival progress.\nRequires a writing tool."
    openOption.toolTip = tooltip
    BurdJournals.ContextMenu.applyLightRequirement(openOption, player)
    if not hasPen then
        openOption.notAvailable = true
    end

    context:addOption(
        getText("ContextMenu_BurdJournals_Rename") or "Rename",
        player,
        BurdJournals.ContextMenu.onRenameJournal,
        journal
    )

    local disassembleOption = context:addOption(
        getText("ContextMenu_BurdJournals_Disassemble") or "Disassemble Journal",
        player,
        BurdJournals.ContextMenu.onDisassembleJournal,
        journal
    )
    local tooltip2 = ISToolTip:new()
    tooltip2:initialise()
    tooltip2:setVisible(false)
    tooltip2:setName(getText("Tooltip_BurdJournals_Disassemble") or "Disassemble Journal")
    tooltip2.description = getText("Tooltip_BurdJournals_DisassembleDesc") or "Tear apart this journal for materials.\n\nYou will receive:\n  2x Paper\n  1x Leather Strips"
    disassembleOption.toolTip = tooltip2
end

function BurdJournals.ContextMenu.onAbsorbAllConfirm(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    local journalData = BurdJournals.getJournalData(journal)

    local skillCount = 0
    local traitCount = 0
    local recipeCount = 0
    if journalData and journalData.skills then
        for skillName, _ in pairs(journalData.skills) do
            if not BurdJournals.hasCharacterClaimedSkill(journalData, player, skillName) then
                skillCount = skillCount + 1
            end
        end
    end
    if journalData and journalData.traits then
        for traitId, _ in pairs(journalData.traits) do
            if not BurdJournals.hasCharacterClaimedTrait(journalData, player, traitId) then
                traitCount = traitCount + 1
            end
        end
    end
    if journalData and journalData.recipes then
        for recipeName, _ in pairs(journalData.recipes) do
            if not BurdJournals.hasCharacterClaimedRecipe(journalData, player, recipeName) then
                recipeCount = recipeCount + 1
            end
        end
    end

    local confirmText = (getText("UI_BurdJournals_ConfirmAbsorbAll") or "Absorb all remaining rewards?") .. "\n\n"
    if skillCount > 0 then
        local skillText = skillCount > 1 and (getText("UI_BurdJournals_SkillsCount") or "%d skills") or (getText("UI_BurdJournals_SkillCount") or "%d skill")
        confirmText = confirmText .. string.format(skillText, skillCount) .. "\n"
    end
    if traitCount > 0 then
        local traitText = traitCount > 1 and (getText("UI_BurdJournals_RareTraitsCount") or "%d rare traits") or (getText("UI_BurdJournals_RareTraitCount") or "%d rare trait")
        confirmText = confirmText .. string.format(traitText, traitCount) .. "\n"
    end
    if recipeCount > 0 then
        local recipeText = recipeCount > 1 and (getText("UI_BurdJournals_RecipesCount") or "%d recipes") or (getText("UI_BurdJournals_RecipeCount") or "%d recipe")
        confirmText = confirmText .. string.format(recipeText, recipeCount) .. "\n"
    end
    confirmText = confirmText .. "\n" .. (getText("UI_BurdJournals_MaxedSkillsSkipped") or "Maxed skills and known items will be skipped.")

    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 150,
        getCore():getScreenHeight() / 2 - 75,
        300, 150,
        confirmText,
        true,
        player,
        BurdJournals.ContextMenu.onConfirmAbsorbAll,
        nil,
        journal
    )
    modal:initialise()
    modal:addToUIManager()
end

function BurdJournals.ContextMenu.onConfirmAbsorbAll(target, button, journal)
    if button.internal == "YES" then
        if not BurdJournals.ContextMenu.requireLightOrNotify(target) then
            return
        end

        BurdJournals.ContextMenu.pickUpThenDo(target, journal, function(player, j, returnContainer)
            if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
                return
            end
            if not BurdJournals.UI.MainPanel then
                require "UI/BurdJournals_MainPanel"
            end

            if BurdJournals.UI and BurdJournals.UI.MainPanel then

                BurdJournals.UI.MainPanel.show(player, j, "absorb", returnContainer)

                local ticksWaited = 0
                local startLearning
                startLearning = function()
                    ticksWaited = ticksWaited + 1
                    if ticksWaited >= 2 then
                        Events.OnTick.Remove(startLearning)
                        if BurdJournals.UI.MainPanel.instance then
                            BurdJournals.UI.MainPanel.instance:startLearningAll()
                        end
                    end
                end
                Events.OnTick.Add(startLearning)
            end
        end)
    end
end

function BurdJournals.ContextMenu.onOpenWornJournal(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j, returnContainer)
        if not BurdJournals.ContextMenu.requireLightOrNotify(p) then
            return
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel then
            BurdJournals.UI.MainPanel.show(p, j, "absorb", returnContainer)
        end
    end)
end

function BurdJournals.ContextMenu.onOpenBloodyJournal(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j, returnContainer)
        if not BurdJournals.ContextMenu.requireLightOrNotify(p) then
            return
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel then
            BurdJournals.UI.MainPanel.show(p, j, "absorb", returnContainer)
        end
    end)
end

function BurdJournals.ContextMenu.onOpenCursedJournal(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)
        if not BurdJournals.ContextMenu.requireLightOrNotify(p) then
            return
        end
        if j and j.getID then
            sendClientCommand(p, "BurdJournals", "openCursedJournal", {
                journalId = j:getID(),
                confirm = false,
            })
        end
    end)
end

function BurdJournals.ContextMenu.onAbsorbAllFromJournal(player, journal)

    local playerNum = player and player:getPlayerNum() or 0
    player = getSpecificPlayer(playerNum) or getSpecificPlayer(0)
    if not player then

        return
    end

    local totalXP = 0
    local skillsAbsorbed = 0
    local skillsSkipped = 0
    local traitsAbsorbed = 0
    local traitsSkipped = 0
    local recipesAbsorbed = 0
    local recipesSkipped = 0

    -- Use per-character unclaimed for this player
    local unclaimed = BurdJournals.getUnclaimedSkills(journal, player)
    local journalData = BurdJournals.getJournalData(journal)

    if isClient() and not isServer() then
        -- Queue rewards for time-gated pacing instead of sending all at once
        -- This prevents server rate-limiting from dropping commands in MP
        -- Server rate-limits at 100ms, so we send one command every 120ms to be safe
        local rewardQueue = {}
        local journalId = journal:getID()

        for skillName, _ in pairs(unclaimed) do
            table.insert(rewardQueue, {type = "skill", name = skillName})
        end
        local unclaimedTraits = BurdJournals.getUnclaimedTraits(journal, player)
        for traitId, _ in pairs(unclaimedTraits) do
            table.insert(rewardQueue, {type = "trait", name = traitId})
        end
        local unclaimedRecipes = BurdJournals.getUnclaimedRecipes and BurdJournals.getUnclaimedRecipes(journal, player) or {}
        for recipeName, _ in pairs(unclaimedRecipes) do
            table.insert(rewardQueue, {type = "recipe", name = recipeName})
        end

        -- Process rewards with 120ms minimum spacing to respect server's 100ms rate limit
        local idx = 1
        local lastSendTime = 0
        local ticksSinceLastSend = 0  -- Fallback for builds without getTimestampMs
        local SEND_INTERVAL_MS = 120 -- Server rate-limits at 100ms, use 120ms to be safe
        local SEND_INTERVAL_TICKS = 4 -- ~120ms at 30 FPS as fallback
        local processNextReward
        processNextReward = function()
            if idx > #rewardQueue then
                Events.OnTick.Remove(processNextReward)
                return
            end

            -- Check if enough time has passed since last send
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

            local reward = rewardQueue[idx]
            idx = idx + 1
            lastSendTime = now

            if reward.type == "skill" then
                -- Calculate skill book multiplier on the client (where the state is known)
                local skillBookMultiplier = BurdJournals.getSkillBookMultiplier(player, reward.name)
                sendClientCommand(player, "BurdJournals", "absorbSkill",
                    {journalId = journalId, skillName = reward.name, skillBookMultiplier = skillBookMultiplier})
            elseif reward.type == "trait" then
                sendClientCommand(player, "BurdJournals", "absorbTrait",
                    {journalId = journalId, traitId = reward.name})
            elseif reward.type == "recipe" then
                sendClientCommand(player, "BurdJournals", "absorbRecipe",
                    {journalId = journalId, recipeName = reward.name})
            end
        end
        Events.OnTick.Add(processNextReward)
    else
        -- SP/host path - use per-character claims to match server behavior
        local journalMultiplier = BurdJournals.getSandboxOption("JournalXPMultiplier") or 1.0
        local modData = journal:getModData()
        local jData = modData and modData.BurdJournals

        for skillName, _ in pairs(unclaimed) do
            local skillData = journalData and journalData.skills and journalData.skills[skillName]
            local xp = skillData and skillData.xp or 0

            local perk = BurdJournals.getPerkByName(skillName)
            if perk and xp > 0 then
                local xpObj = player:getXp()
                local beforeXP = xpObj:getXP(perk)

                -- Apply skill book multiplier for Worn/Bloody journals
                local skillBookMultiplier = BurdJournals.getSkillBookMultiplier(player, skillName)
                local xpToApply = xp * journalMultiplier * skillBookMultiplier

                local isPassiveSkill = (skillName == "Fitness" or skillName == "Strength")
                if isPassiveSkill then
                    xpToApply = xpToApply * 5
                end

                -- Use AddXP with useMultipliers=false since we already applied journal/skillbook multipliers
                -- AddXP adds the specified amount directly for all skills
                -- Signature: AddXP(perk, amount, addToKnownRecipes, useMultipliers, isPassive, checkLevelUp)
                if sendAddXp then
                    sendAddXp(player, perk, xpToApply, false)
                else
                    xpObj:AddXP(perk, xpToApply, true, false, false, false)
                end

                local afterXP = xpObj:getXP(perk)
                local actualGain = afterXP - beforeXP

                -- Always mark as claimed (per-character) even if no gain
                if jData then
                    BurdJournals.markSkillClaimedByCharacter(jData, player, skillName)
                end

                if actualGain > 0 then
                    totalXP = totalXP + actualGain
                    skillsAbsorbed = skillsAbsorbed + 1
                else
                    skillsSkipped = skillsSkipped + 1
                end
            else
                -- Mark as claimed even if no XP (0 XP skill)
                if jData then
                    BurdJournals.markSkillClaimedByCharacter(jData, player, skillName)
                end
                skillsSkipped = skillsSkipped + 1
            end
        end

        local unclaimedTraits = BurdJournals.getUnclaimedTraits(journal, player)
        for traitId, _ in pairs(unclaimedTraits) do
            if BurdJournals.playerHasTrait(player, traitId) then
                -- Mark as claimed even if already known (allows dissolution)
                if jData then
                    BurdJournals.markTraitClaimedByCharacter(jData, player, traitId)
                end
                traitsSkipped = traitsSkipped + 1
            else
                local success = BurdJournals.safeAddTrait(player, traitId)
                if success then
                    local allowCancellation = BurdJournals.getSandboxOption("AllowMutualExclusionCancellation")
                    if allowCancellation == nil then
                        allowCancellation = true
                    end
                    if allowCancellation and BurdJournals.getConflictingTraits and BurdJournals.safeRemoveTrait then
                        local conflicts = BurdJournals.getConflictingTraits(player, traitId)
                        for _, conflictId in ipairs(conflicts) do
                            BurdJournals.safeRemoveTrait(player, conflictId)
                        end
                    end
                end
                if jData then
                    BurdJournals.markTraitClaimedByCharacter(jData, player, traitId)
                end
                if success then
                    traitsAbsorbed = traitsAbsorbed + 1
                else
                    traitsSkipped = traitsSkipped + 1
                end
            end
        end

        -- Process recipes for SP/host
        local unclaimedRecipes = BurdJournals.getUnclaimedRecipes and BurdJournals.getUnclaimedRecipes(journal, player) or {}
        for recipeName, _ in pairs(unclaimedRecipes) do
            if BurdJournals.playerKnowsRecipe(player, recipeName) then
                -- Mark as claimed even if already known (allows dissolution)
                if jData then
                    BurdJournals.markRecipeClaimedByCharacter(jData, player, recipeName)
                end
                recipesSkipped = recipesSkipped + 1
            else
                local success = BurdJournals.learnRecipeWithVerification(player, recipeName, "[BurdJournals SP]")
                if jData then
                    BurdJournals.markRecipeClaimedByCharacter(jData, player, recipeName)
                end
                if success then
                    recipesAbsorbed = recipesAbsorbed + 1
                else
                    recipesSkipped = recipesSkipped + 1
                end
            end
        end

        -- Transmit changes once after all claims
        if jData and journal.transmitModData then
            journal:transmitModData()
        end

        if totalXP > 0 or traitsAbsorbed > 0 or recipesAbsorbed > 0 then
            local message = "+" .. BurdJournals.formatXP(totalXP) .. " XP"
            if traitsAbsorbed > 0 then
                local traitText = traitsAbsorbed > 1 and (getText("UI_BurdJournals_PlusTraits") or ", +%d traits") or (getText("UI_BurdJournals_PlusTrait") or ", +%d trait")
                message = message .. string.format(traitText, traitsAbsorbed)
            end
            if recipesAbsorbed > 0 then
                local recipeText = recipesAbsorbed > 1 and (getText("UI_BurdJournals_PlusRecipes") or ", +%d recipes") or (getText("UI_BurdJournals_PlusRecipe") or ", +%d recipe")
                message = message .. string.format(recipeText, recipesAbsorbed)
            end
            if HaloTextHelper and HaloTextHelper.addTextWithArrow then
                HaloTextHelper.addTextWithArrow(player, message, true, HaloTextHelper.getColorGreen())
            else
                player:Say(message)
            end
        end

        if skillsSkipped > 0 or traitsSkipped > 0 or recipesSkipped > 0 then
            local skipMsg = ""
            if skillsSkipped > 0 then
                local skillText = skillsSkipped > 1 and (getText("UI_BurdJournals_SkillsAlreadyMaxed") or "%d skills already maxed") or (getText("UI_BurdJournals_SkillAlreadyMaxed") or "%d skill already maxed")
                skipMsg = string.format(skillText, skillsSkipped)
            end
            if traitsSkipped > 0 then
                if skipMsg ~= "" then skipMsg = skipMsg .. ", " end
                local traitText = traitsSkipped > 1 and (getText("UI_BurdJournals_TraitsAlreadyKnown") or "%d traits already known") or (getText("UI_BurdJournals_TraitAlreadyKnown") or "%d trait already known")
                skipMsg = skipMsg .. string.format(traitText, traitsSkipped)
            end
            if recipesSkipped > 0 then
                if skipMsg ~= "" then skipMsg = skipMsg .. ", " end
                local recipeText = recipesSkipped > 1 and (getText("UI_BurdJournals_RecipesAlreadyKnownCount") or "%d recipes already known") or (getText("UI_BurdJournals_RecipeAlreadyKnown") or "%d recipe already known")
                skipMsg = skipMsg .. string.format(recipeText, recipesSkipped)
            end
            if skipMsg ~= "" then
                player:Say(skipMsg)
            end
        end

        if BurdJournals.shouldDissolve(journal, player) then
            player:getInventory():Remove(journal)
            local dissolveMsg = BurdJournals.getRandomDissolutionMessage()
            player:Say(dissolveMsg)
            if player and player.getEmitter then
                local emitter = player:getEmitter()
                if emitter and emitter.playSound then
                    emitter:playSound("PaperRip")
                end
            end
        end
    end
end

function BurdJournals.ContextMenu.onConvertToClean(player, journal)

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j, returnContainer)
        local isFilled = BurdJournals.isFilledJournal(j)
        local remaining = BurdJournals.getRemainingRewards(j, p)

        if isFilled and remaining > 0 then

            local modal = ISModalDialog:new(
                getCore():getScreenWidth() / 2 - 150,
                getCore():getScreenHeight() / 2 - 50,
                300, 120,
                getText("UI_BurdJournals_ConfirmConvert") or "This will destroy the remaining rewards. Are you sure?",
                true,
                p,
                BurdJournals.ContextMenu.onConfirmConvert,
                nil,
                j
            )
            modal:initialise()
            modal:addToUIManager()
        else

            local action = BurdJournals.ConvertToCleanAction:new(p, j)
            ISTimedActionQueue.add(action)
        end
    end)
end

function BurdJournals.ContextMenu.onConfirmConvert(target, button, journal)
    if button.internal == "YES" then
        local action = BurdJournals.ConvertToCleanAction:new(target, journal)
        ISTimedActionQueue.add(action)
    end
end

function BurdJournals.ContextMenu.onOpenCleanJournal(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)
        if not BurdJournals.ContextMenu.requireLightOrNotify(p) then
            return
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel then
            BurdJournals.UI.MainPanel.show(p, j, "view", returnContainer)
        end
    end)
end

function BurdJournals.ContextMenu.onReadCleanJournal(player, journal)

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j, returnContainer)
        sendClientCommand(
            p,
            "BurdJournals",
            "learnSkills",
            {journalId = j:getID()}
        )
    end)
end

function BurdJournals.ContextMenu.onClaimAllConfirm(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)
        if not BurdJournals.ContextMenu.requireLightOrNotify(p) then
            return
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel then

            BurdJournals.UI.MainPanel.show(p, j, "view", returnContainer)

            local panel = BurdJournals.UI.MainPanel.instance
            if panel and panel.startLearningAll then
                local ticksWaited = 0
                local startLearning
                startLearning = function()
                    ticksWaited = ticksWaited + 1
                    if ticksWaited >= 2 then
                        Events.OnTick.Remove(startLearning)
                        if BurdJournals.UI.MainPanel.instance then
                            BurdJournals.UI.MainPanel.instance:startLearningAll()
                        end
                    end
                end
                Events.OnTick.Add(startLearning)
            end
        end
    end)
end

function BurdJournals.ContextMenu.onRenameJournal(player, journal)

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j, returnContainer)
        local currentName = j:getName() or ""
        local modal = ISTextBox:new(
            getCore():getScreenWidth() / 2 - 150,
            getCore():getScreenHeight() / 2 - 50,
            300, 100,
            getText("UI_BurdJournals_RenamePrompt") or "Enter new name:",
            currentName,
            p,
            BurdJournals.ContextMenu.onConfirmRename,
            nil,
            j
        )
        modal:initialise()
        modal:addToUIManager()
    end)
end

function BurdJournals.ContextMenu.onConfirmRename(target, button, journal)
    if button.internal == "OK" then
        local newName = button.parent.entry:getText()
        if newName and newName ~= "" then
            -- Set name locally first for immediate feedback
            journal:setName(newName)
            -- Mark as custom name so PZ preserves it during item serialization (MP transfers)
            if journal.setCustomName then
                journal:setCustomName(true)
            end

            local modData = journal:getModData()
            if modData.BurdJournals then
                modData.BurdJournals.customName = newName
            end

            -- In multiplayer, send command to server to update the name there too
            -- This is CRITICAL for MP name persistence - the server must have the correct name
            if isClient() and not isServer() then
                local player = getPlayer()
                if player then
                    sendClientCommand(player, "BurdJournals", "renameJournal", {
                        journalId = journal:getID(),
                        newName = newName
                    })
                end
            else
                -- Single player or listen server - just transmit locally
                if journal.transmitModData then
                    journal:transmitModData()
                end
            end
        end
    end
end

function BurdJournals.ContextMenu.onEraseJournal(player, journal)

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)
        local modal = ISModalDialog:new(
            getCore():getScreenWidth() / 2 - 150,
            getCore():getScreenHeight() / 2 - 50,
            300, 120,
            getText("UI_BurdJournals_ConfirmErase") or "Erase all content? This cannot be undone.",
            true,
            p,
            BurdJournals.ContextMenu.onConfirmErase,
            nil,
            j
        )
        modal:initialise()
        modal:addToUIManager()
    end)
end

function BurdJournals.ContextMenu.onConfirmErase(target, button, journal)
    if button.internal == "YES" then

        if BurdJournals.EraseJournalAction then
            ISTimedActionQueue.add(BurdJournals.EraseJournalAction:new(target, journal))
        else

            sendClientCommand(
                target,
                "BurdJournals",
                "eraseJournal",
                {journalId = journal:getID()}
            )
        end
    end
end

function BurdJournals.ContextMenu.onRecordProgress(player, journal)
    if not BurdJournals.ContextMenu.requireLightOrNotify(player) then
        return
    end

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)
        if not BurdJournals.ContextMenu.requireLightOrNotify(p) then
            return
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel then
            BurdJournals.UI.MainPanel.show(p, j, "log", returnContainer)
        end
    end)
end

function BurdJournals.ContextMenu.onRecordProgressOverwrite(player, journal)

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)
        local modal = ISModalDialog:new(
            getCore():getScreenWidth() / 2 - 150,
            getCore():getScreenHeight() / 2 - 50,
            300, 120,
            getText("UI_BurdJournals_ConfirmOverwrite") or "Overwrite existing content?",
            true,
            p,
            BurdJournals.ContextMenu.onConfirmOverwrite,
            nil,
            j
        )
        modal:initialise()
        modal:addToUIManager()
    end)
end

function BurdJournals.ContextMenu.onConfirmOverwrite(target, button, journal)
    if button.internal == "YES" then
        if not BurdJournals.ContextMenu.requireLightOrNotify(target) then
            return
        end
        if not BurdJournals.UI or not BurdJournals.UI.MainPanel then
            require "UI/BurdJournals_MainPanel"
        end

        if BurdJournals.UI and BurdJournals.UI.MainPanel then
            BurdJournals.UI.MainPanel.show(target, journal, "log")
        end
    end
end

function BurdJournals.ContextMenu.onDisassembleJournal(player, journal)

    BurdJournals.ContextMenu.pickUpThenDo(player, journal, function(p, j)

        local confirmText = getText("UI_BurdJournals_ConfirmDisassemble") or "Disassemble this journal?"
        confirmText = confirmText .. "\n\nYou will receive:\n2x Paper, 1x Leather Strips"

        local modal = ISModalDialog:new(
            getCore():getScreenWidth() / 2 - 150,
            getCore():getScreenHeight() / 2 - 75,
            300, 150,
            confirmText,
            true,
            p,
            BurdJournals.ContextMenu.onConfirmDisassemble,
            nil,
            j
        )
        modal:initialise()
        modal:addToUIManager()
    end)
end

function BurdJournals.ContextMenu.onConfirmDisassemble(target, button, journal)
    if button.internal == "YES" then
        if BurdJournals.DisassembleJournalAction then
            ISTimedActionQueue.add(BurdJournals.DisassembleJournalAction:new(target, journal))
        end
    end
end

function BurdJournals.ContextMenu.parseRecipeString(recipeStr)
    local materials = {}
    if not recipeStr or recipeStr == "" then return materials end

    for part in recipeStr:gmatch("[^|]+") do
        part = part:match("^%s*(.-)%s*$")
        if part and part ~= "" then
            local mat = {}

            mat.keep = part:match(":keep$") ~= nil
            if mat.keep then
                part = part:gsub(":keep$", "")
            end

            local itemType, qty = part:match("^(.+):(%d+)$")
            if itemType and qty then
                mat.type = itemType
                mat.count = tonumber(qty)

                mat.name = itemType:gsub("Base%.", ""):gsub("tag:", "")
                mat.name = mat.name:gsub("(%l)(%u)", "%1 %2")
                table.insert(materials, mat)
            end
        end
    end
    return materials
end

Events.OnFillInventoryObjectContextMenu.Add(BurdJournals.ContextMenu.onFillInventoryObjectContextMenu)
