-- ============================================================================
-- BurdJournals_DebugPanel.lua
-- Debug Center UI for testing and development
-- Uses custom tab system (not ISTabPanel) for reliable rendering
-- ============================================================================

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTickBox"
require "ISUI/ISComboBox"
require "ISUI/ISModalDialog"

BurdJournals = BurdJournals or {}
BurdJournals.UI = BurdJournals.UI or {}

-- ============================================================================
-- Debug Panel Class
-- ============================================================================

BurdJournals.UI.DebugPanel = ISPanel:derive("BurdJournals_DebugPanel")

-- Singleton instance
BurdJournals.UI.DebugPanel.instance = nil

-- Panel dimensions (runtime is clamped to screen)
BurdJournals.UI.DebugPanel.DEFAULT_WIDTH = 860
BurdJournals.UI.DebugPanel.DEFAULT_HEIGHT = 760
BurdJournals.UI.DebugPanel.MIN_WIDTH = 760
BurdJournals.UI.DebugPanel.MIN_HEIGHT = 680
BurdJournals.UI.DebugPanel.SCREEN_MARGIN = 24

-- Scrollbar offset for right-aligned elements in lists
BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH = 15

-- ============================================================================
-- Constructor
-- ============================================================================

function BurdJournals.UI.DebugPanel:new(x, y, player)
    local width, height = BurdJournals.UI.DebugPanel.getPanelDimensions()
    
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    o.backgroundColor = {r=0.1, g=0.1, b=0.12, a=0.98}
    o.borderColor = {r=0.3, g=0.5, b=0.7, a=1}
    o.moveWithMouse = true
    
    -- Drag state
    o.dragging = false
    o.dragOffsetX = 0
    o.dragOffsetY = 0
    
    -- Tab management
    o.currentTab = "spawn"
    o.tabPanels = {}
    o.tabButtons = {}
    
    -- Status message
    o.statusMessage = nil
    o.statusColor = {r=1, g=1, b=1}
    o.statusTime = 0
    
    return o
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

-- Passive skill traits that need to be removed before setting skill level
-- These traits are auto-granted by PZ based on skill level, but having them
-- while trying to set a different level can cause conflicts (skill bounces back)
BurdJournals.UI.DebugPanel.PASSIVE_SKILL_TRAITS = {
    Strength = {"puny", "weak", "feeble", "stout", "strong"},
    Fitness = {"unfit", "outofshape", "fit", "athletic"}
}

-- Remove all passive skill traits for a specific skill before setting its level
-- This prevents the trait system from bouncing the skill back (e.g., Feeble trait
-- forcing Strength to stay at level 2-4 when trying to set to 0)
function BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, skillName)
    local traits = BurdJournals.UI.DebugPanel.PASSIVE_SKILL_TRAITS[skillName]
    if not traits then return end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG (SP): Removing passive skill traits for " .. skillName)
    
    for _, traitId in ipairs(traits) do
        local removed = false
        
        -- Try safeRemoveTrait if available
        if BurdJournals.safeRemoveTrait then
            removed = BurdJournals.safeRemoveTrait(targetPlayer, traitId) == true
            if removed then
                BurdJournals.debugPrint("[BurdJournals] DEBUG (SP): Removed trait '" .. traitId .. "' via safeRemoveTrait")
            end
        end
        
        -- Direct trait removal fallback
        if not removed and targetPlayer and targetPlayer.getCharacterTraits then
            local charTraits = targetPlayer:getCharacterTraits()
            if charTraits and charTraits.size and charTraits.get then
                for i = charTraits:size() - 1, 0, -1 do
                    local traitObj = charTraits:get(i)
                    if traitObj then
                        local traitName = ""
                        if traitObj.getName then
                            traitName = traitObj:getName() or ""
                        else
                            traitName = tostring(traitObj)
                        end
                        if string.lower(traitName) == string.lower(traitId) then
                            if charTraits.remove then
                                charTraits:remove(traitObj)
                                removed = true
                                BurdJournals.debugPrint("[BurdJournals] DEBUG (SP): Removed trait '" .. traitId .. "' via direct removal")
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

function BurdJournals.UI.DebugPanel.isAdminPlayer(player)
    if not player then return false end
    if player.isAccessLevel and player:isAccessLevel("admin") then
        return true
    end
    local accessLevel = player.getAccessLevel and player:getAccessLevel() or nil
    return type(accessLevel) == "string" and string.lower(accessLevel) == "admin"
end

function BurdJournals.UI.DebugPanel:canTargetOtherPlayers()
    if not (isClient and isClient()) then
        return false
    end
    return BurdJournals.UI.DebugPanel.isAdminPlayer(self.player)
end

-- ============================================================================
-- Initialization
-- ============================================================================

function BurdJournals.UI.DebugPanel:initialise()
    ISPanel.initialise(self)
end

function BurdJournals.UI.DebugPanel:prerender()
    ISPanel.prerender(self)

    -- Handle deferred journal refresh (from MainPanel erase operations)
    -- This prevents refresh during render cycle which can cause draw crashes
    if self.needsJournalRefresh then
        self.needsJournalRefresh = false
        if self.refreshJournalEditorData then
            self:refreshJournalEditorData()
        end
    end

    -- Handle deferred text entry updates (fixes "one step behind" issue)
    if self.spawnPanel then
        if self.spawnPanel.extraXPPendingUpdate then
            self.spawnPanel.extraXPPendingUpdate = false
            BurdJournals.UI.DebugPanel.onExtraXPChange(self)
        end
    end
end

function BurdJournals.UI.DebugPanel:createChildren()
    ISPanel.createChildren(self)
    
    local padding = 10
    local labelHeight = 18
    
    -- Title bar with drag support
    self.titleBar = ISPanel:new(0, 0, self.width, 30)
    self.titleBar:initialise()
    self.titleBar:instantiate()
    self.titleBar.backgroundColor = {r=0.15, g=0.25, b=0.35, a=1}
    self.titleBar.parentPanel = self  -- Reference to parent for drag handling
    
    -- Override title bar mouse handlers for reliable drag support
    self.titleBar.onMouseDown = function(titleBar, x, y)
        if not titleBar.parentPanel then return true end
        -- Start dragging the parent panel
        titleBar.parentPanel.dragging = true
        titleBar.parentPanel.dragOffsetX = titleBar:getAbsoluteX() + x
        titleBar.parentPanel.dragOffsetY = titleBar:getAbsoluteY() + y
        return true
    end
    
    self.titleBar.onMouseUp = function(titleBar, x, y)
        if titleBar.parentPanel then
            titleBar.parentPanel.dragging = false
        end
        return true
    end
    
    self.titleBar.onMouseMove = function(titleBar, dx, dy)
        if titleBar.parentPanel and titleBar.parentPanel.dragging then
            local newX = titleBar.parentPanel:getX() + dx
            local newY = titleBar.parentPanel:getY() + dy
            titleBar.parentPanel:setX(newX)
            titleBar.parentPanel:setY(newY)
        end
        return true
    end
    
    self.titleBar.onMouseMoveOutside = function(titleBar, dx, dy)
        if titleBar.parentPanel and titleBar.parentPanel.dragging then
            local newX = titleBar.parentPanel:getX() + dx
            local newY = titleBar.parentPanel:getY() + dy
            titleBar.parentPanel:setX(newX)
            titleBar.parentPanel:setY(newY)
        end
        return true
    end
    
    self.titleBar.onMouseUpOutside = function(titleBar, x, y)
        if titleBar.parentPanel then
            titleBar.parentPanel.dragging = false
        end
        return true
    end
    
    self:addChild(self.titleBar)
    
    -- Title text
    self.titleLabel = ISLabel:new(padding, 6, labelHeight, "BSJ Debug Center", 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self.titleLabel:instantiate()
    self.titleBar:addChild(self.titleLabel)
    
    -- Close button
    self.closeBtn = ISButton:new(self.width - 30, 3, 24, 24, "X", self, BurdJournals.UI.DebugPanel.onClose)
    self.closeBtn:initialise()
    self.closeBtn:instantiate()
    self.closeBtn.font = UIFont.Small
    self.closeBtn.textColor = {r=1, g=1, b=1, a=1}
    self.closeBtn.borderColor = {r=0.7, g=0.3, b=0.3, a=1}
    self.closeBtn.backgroundColor = {r=0.5, g=0.15, b=0.15, a=0.8}
    self.titleBar:addChild(self.closeBtn)
    
    -- Tab bar (custom buttons instead of ISTabPanel)
    local tabY = 35
    local tabBtnWidth = 80
    local tabBtnHeight = 25
    local tabs = {
        {id = "spawn", label = "Spawn"},
        {id = "character", label = "Character"},
        {id = "baseline", label = "Baseline"},
        {id = "snapshots", label = getText("UI_BurdJournals_DebugTabSnapshots") or "Snapshots"},
        {id = "journal", label = "Journal"},
        {id = "diagnostics", label = "Diagnostics"},
    }
    local tabX = 5
    local availableW = math.max(420, self.width - 10)
    local minTabW = 72
    local spacing = 2
    local computedW = math.floor((availableW - ((#tabs - 1) * spacing)) / #tabs)
    tabBtnWidth = math.max(minTabW, computedW)
    
    for _, tab in ipairs(tabs) do
        local btn = ISButton:new(tabX, tabY, tabBtnWidth, tabBtnHeight, tab.label, self, BurdJournals.UI.DebugPanel.onTabClick)
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = tab.id
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        btn.backgroundColor = {r=0.15, g=0.15, b=0.2, a=1}
        self:addChild(btn)
        self.tabButtons[tab.id] = btn
        tabX = tabX + tabBtnWidth + spacing
    end
    
    -- Content area
    local contentY = tabY + tabBtnHeight + 5
    local contentHeight = self.height - contentY - 35  -- Room for status bar
    
    -- Clear trait caches before populating panels to ensure fresh discovery
    BurdJournals.UI.DebugPanel.clearTraitCaches()
    
    -- Create tab content panels
    self:createSpawnPanel(contentY, contentHeight)
    self:createCharacterPanel(contentY, contentHeight)
    self:createBaselinePanel(contentY, contentHeight)
    self:createSnapshotsPanel(contentY, contentHeight)
    self:createJournalPanel(contentY, contentHeight)
    self:createDiagnosticsPanel(contentY, contentHeight)
    
    -- Status bar
    self.statusBar = ISPanel:new(0, self.height - 30, self.width, 30)
    self.statusBar:initialise()
    self.statusBar:instantiate()
    self.statusBar.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    self:addChild(self.statusBar)
    
    self.statusLabel = ISLabel:new(padding, 6, labelHeight, "Ready", 0.6, 0.7, 0.8, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self.statusLabel:instantiate()
    self.statusBar:addChild(self.statusLabel)
    
    -- Show initial tab
    self:showTab("spawn")
end

-- ============================================================================
-- Tab Switching
-- ============================================================================

function BurdJournals.UI.DebugPanel:onTabClick(button)
    local tabId = button.internal
    self:showTab(tabId)
end

-- Forward declaration so earlier callbacks resolve the local helper.
local isAffirmativeDialogButton

function BurdJournals.UI.DebugPanel:hasUnsavedBaselineDraft()
    local panel = self.baselinePanel
    return panel and panel.baselineDraftDirty == true
end

function BurdJournals.UI.DebugPanel:resetBaselineDraftState()
    local panel = self.baselinePanel
    if not panel then
        return
    end
    panel.baselineDraftDirty = false
    panel.baselineDraftSkills = {}
    panel.baselineDraftTraits = {}
    if self.updateBaselineDraftButtons then
        self:updateBaselineDraftButtons()
    end
end

function BurdJournals.UI.DebugPanel:confirmDiscardBaselineDraft(actionText, onConfirm, onCancel)
    if not self:hasUnsavedBaselineDraft() then
        if onConfirm then
            onConfirm()
        end
        return true
    end

    if self.baselineDraftPromptOpen then
        return false
    end

    local actionLabel = tostring(actionText or "continue")
    local promptTemplate = getText("UI_BurdJournals_BaselineDraftUnsavedPrompt")
        or "You have unsaved changes that could be lost. Are you sure you want to %s?"
    local promptText = string.format(promptTemplate, actionLabel)

    if ISModalDialog then
        self.baselineDraftPromptOpen = true
        local selfRef = self
        local callback = function(_target, buttonObj)
            selfRef.baselineDraftPromptOpen = false
            if isAffirmativeDialogButton(buttonObj) then
                selfRef:resetBaselineDraftState()
                if onConfirm then
                    onConfirm()
                end
            else
                if onCancel then
                    onCancel()
                end
                selfRef:setStatus(
                    getText("UI_BurdJournals_BaselineDraftUnsavedCancelled") or "Unsaved baseline changes kept.",
                    {r=0.95, g=0.78, b=0.45}
                )
            end
        end
        if BurdJournals.createAdaptiveModalDialog then
            BurdJournals.createAdaptiveModalDialog({
                player = self.player,
                text = promptText,
                yesNo = true,
                onClick = callback,
                minWidth = 420,
                maxWidth = 820,
                minHeight = 175,
            })
        else
            local w, h = 520, 180
            local x = (getCore():getScreenWidth() - w) / 2
            local y = (getCore():getScreenHeight() - h) / 2
            local modal = ISModalDialog:new(x, y, w, h, promptText, true, nil, callback)
            modal:initialise()
            modal:addToUIManager()
        end
        return false
    end

    self:resetBaselineDraftState()
    if onConfirm then
        onConfirm()
    end
    return true
end

function BurdJournals.UI.DebugPanel:showTab(tabId, skipBaselineDraftConfirm)
    if not skipBaselineDraftConfirm
        and self.currentTab == "baseline"
        and tabId ~= "baseline"
        and self:hasUnsavedBaselineDraft()
    then
        self:confirmDiscardBaselineDraft(
            getText("UI_BurdJournals_BaselineDraftActionSwitchTabs") or "switch tabs",
            function()
                self:showTab(tabId, true)
            end
        )
        return
    end

    self.currentTab = tabId
    
    -- Hide all panels, show selected
    for id, panel in pairs(self.tabPanels) do
        panel:setVisible(id == tabId)
    end
    
    -- Update button styles
    for id, btn in pairs(self.tabButtons) do
        if id == tabId then
            btn.backgroundColor = {r=0.3, g=0.4, b=0.5, a=1}
            btn.borderColor = {r=0.5, g=0.7, b=0.9, a=1}
        else
            btn.backgroundColor = {r=0.15, g=0.15, b=0.2, a=1}
            btn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        end
    end

    if tabId == "journal" and self.refreshJournalPickerList then
        self:refreshJournalPickerList(true)
        if self.onJournalRefreshServerIndex then
            self:onJournalRefreshServerIndex()
        end
    elseif tabId == "baseline" then
        if self.populateBaselinePlayerList then
            self:populateBaselinePlayerList()
        end
        if self.refreshBaselineData then
            self:refreshBaselineData()
        end
    elseif tabId == "snapshots" then
        if self.populateSnapshotPlayerList then
            self:populateSnapshotPlayerList()
        end
        if self.refreshSnapshotPanelData then
            self:refreshSnapshotPanelData()
        end
    end
end

local function normalizeDebugSearchText(value)
    local text = string.lower(tostring(value or ""))
    if text == "" then
        return ""
    end

    -- Strip common rich-text style tags and normalize punctuation/spacing.
    text = string.gsub(text, "%[img=[^%]]-%]", " ")
    text = string.gsub(text, "%[col=[^%]]-%]", " ")
    text = string.gsub(text, "%[/col%]", " ")
    text = string.gsub(text, "[%p_]+", " ")
    text = string.gsub(text, "%s+", " ")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

isAffirmativeDialogButton = function(button)
    if not button then
        return false
    end
    local internal = string.upper(tostring(button.internal or ""))
    if internal == "YES" or internal == "OK" or internal == "TRUE" or internal == "1" then
        return true
    end
    local title = string.upper(tostring(button.title or button.name or ""))
    if title == "YES" or title == "OK" then
        return true
    end
    return false
end

local function debugSearchMatches(query, ...)
    local normalizedQuery = normalizeDebugSearchText(query)
    if normalizedQuery == "" then
        return true
    end

    local compactQuery = string.gsub(normalizedQuery, "%s+", "")
    for i = 1, select("#", ...) do
        local haystack = normalizeDebugSearchText(select(i, ...))
        if haystack ~= "" then
            if string.find(haystack, normalizedQuery, 1, true) then
                return true
            end
            if compactQuery ~= "" then
                local compactHaystack = string.gsub(haystack, "%s+", "")
                if string.find(compactHaystack, compactQuery, 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

-- Clear trait discovery caches to force fresh lookup
function BurdJournals.UI.DebugPanel.clearTraitCaches()
    if BurdJournals then
        BurdJournals._cachedAllTraits = nil
        BurdJournals._cachedGrantableTraits = nil
        BurdJournals._cachedPositiveTraits = nil
        BurdJournals._cachedNegativeTraits = nil
        BurdJournals.debugPrint("[BSJ DebugPanel] Cleared trait caches for fresh discovery")
    end
end

-- ============================================================================
-- Tab 1: Spawn Panel
-- ============================================================================

-- Dynamically discover skills from the game (includes modded skills)
function BurdJournals.UI.DebugPanel.getAvailableSkills()
    local skills = nil
    
    -- Use the mod's discovery function if available
    if BurdJournals and BurdJournals.discoverAllSkills then
        local result = BurdJournals.discoverAllSkills()
        if result and type(result) == "table" and #result > 0 then
            skills = result
        end
    end
    
    -- Fallback: try PerkFactory directly
    if not skills or #skills == 0 then
        skills = {}
        if PerkFactory and PerkFactory.PerkList then
            local perkList = PerkFactory.PerkList
            if perkList and perkList.size then
                for i = 0, perkList:size() - 1 do
                    local perk = perkList:get(i)
                    if perk then
                        -- Only include trainable skills (not categories)
                        local parent = perk.getParent and perk:getParent() or nil
                        if parent then
                            local parentId = parent.getId and parent:getId() or nil
                            if parentId ~= "None" then
                                local perkName = (perk.getId and perk:getId()) or tostring(perk)
                                if perkName then
                                    table.insert(skills, perkName)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Final fallback: hardcoded list
    if not skills or #skills == 0 then
        skills = {
            "Fitness", "Strength", "Cooking", "Farming", "FirstAid", "Fishing", 
            "PlantScavenging", "Woodwork", "Mechanics", "Electricity", "Metalworking", 
            "Tailoring", "Aiming", "Reloading", "Axe", "Blunt", "SmallBlunt", 
            "LongBlade", "ShortBlade", "Spear", "Maintenance", "Sprinting", 
            "Lightfooted", "Nimble", "Sneaking", "Trapping"
        }
    end
    
    return skills
end

-- Dynamically discover traits from the game (includes modded traits)
function BurdJournals.UI.DebugPanel.getAvailableTraits()
    local traits = {}
    local addedTraitsLower = {}  -- For case-insensitive deduplication
    
    -- Helper to add trait with deduplication
    local function addTrait(traitId)
        if traitId and type(traitId) == "string" then
            local lower = string.lower(traitId)
            if not addedTraitsLower[lower] then
                addedTraitsLower[lower] = true
                table.insert(traits, traitId)
            end
        end
    end
    
    -- Use the mod's discovery function if available (include negative traits for debug)
    if BurdJournals and BurdJournals.discoverGrantableTraits then
        local result = BurdJournals.discoverGrantableTraits(true)  -- true = include negative
        if result and type(result) == "table" then
            for _, traitId in ipairs(result) do
                addTrait(traitId)
            end
        end
    end
    
    -- Fallback: try TraitFactory directly (with deduplication)
    if #traits == 0 then
        if TraitFactory and TraitFactory.getTraits then
            local traitList = TraitFactory.getTraits()
            if traitList and traitList.size then
                for i = 0, traitList:size() - 1 do
                    local trait = traitList:get(i)
                    if trait then
                        local traitType = trait.getType and trait:getType() or nil
                        if traitType then
                            addTrait(traitType)
                        end
                    end
                end
            end
        end
    end
    
    -- Final fallback: hardcoded list
    if #traits == 0 then
        local fallback = {
            "Athletic", "Strong", "Brave", "Lucky", "FastLearner", "Dextrous", 
            "Graceful", "LightEater", "Organized", "Outdoorsman", "ThickSkinned", 
            "Inconspicuous", "Conspicuous", "Clumsy", "SlowLearner", "Cowardly", 
            "Weak", "Obese", "Overweight", "Underweight", "Pacifist"
        }
        for _, t in ipairs(fallback) do
            addTrait(t)
        end
    end
    
    return traits
end

-- Get display name for a skill
function BurdJournals.UI.DebugPanel.getSkillDisplayName(skillName)
    if BurdJournals.getPerkDisplayName then
        local display = BurdJournals.getPerkDisplayName(skillName)
        if display then return display end
    end
    -- Fallback: convert camelCase to Title Case
    return skillName:gsub("(%l)(%u)", "%1 %2")
end

-- Get display name for a trait
function BurdJournals.UI.DebugPanel.getTraitDisplayName(traitName)
    if BurdJournals.getTraitDisplayName then
        local display = BurdJournals.getTraitDisplayName(traitName)
        if display then return display end
    end
    -- Try TraitFactory
    if TraitFactory and TraitFactory.getTrait then
        local trait = TraitFactory.getTrait(traitName)
        if trait and trait.getLabel then
            return trait:getLabel()
        end
    end
    -- Fallback: convert camelCase to Title Case
    return traitName:gsub("(%l)(%u)", "%1 %2")
end

function BurdJournals.UI.DebugPanel:createSpawnPanel(startY, height)
    local panel = ISPanel:new(5, startY, self.width - 10, height)
    panel:initialise()
    panel:instantiate()
    panel.backgroundColor = {r=0.12, g=0.12, b=0.15, a=1}
    panel.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    self:addChild(panel)
    self.tabPanels["spawn"] = panel
    
    local padding = 10
    local y = padding
    local halfWidth = (panel.width - padding * 3) / 2
    
    -- Journal Type section
    local typeLabel = ISLabel:new(padding, y, 20, "Journal Type:", 1, 1, 1, 1, UIFont.Small, true)
    typeLabel:initialise()
    typeLabel:instantiate()
    panel:addChild(typeLabel)
    y = y + 22
    
    -- Type buttons
    local typeX = padding
    local btnWidth = 70
    local types = {"Blank", "Filled", "Worn", "Bloody", "Cursed"}
    panel.typeButtons = {}
    panel.selectedType = "filled"
    
    for _, typeName in ipairs(types) do
        local btn = ISButton:new(typeX, y, btnWidth, 22, typeName, self, BurdJournals.UI.DebugPanel.onTypeSelect)
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = string.lower(typeName)
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        btn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
        panel:addChild(btn)
        panel.typeButtons[typeName] = btn
        typeX = typeX + btnWidth + 3
    end
    self:updateTypeButtons(panel)
    y = y + 30

    -- Spawn profile: normal (natural behavior) vs debug (legacy debug flags)
    panel.spawnProfile = "normal"

    panel.spawnProfileLabel = ISLabel:new(
        padding,
        y,
        18,
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnProfile", "Spawn Profile:")
            or "Spawn Profile:",
        0.9, 0.9, 0.7, 1,
        UIFont.Small,
        true
    )
    panel.spawnProfileLabel:initialise()
    panel.spawnProfileLabel:instantiate()
    panel:addChild(panel.spawnProfileLabel)

    panel.spawnProfileCombo = ISComboBox:new(padding + 95, y - 2, 215, 22, self, BurdJournals.UI.DebugPanel.onSpawnProfileChange)
    panel.spawnProfileCombo:initialise()
    panel.spawnProfileCombo:instantiate()
    panel.spawnProfileCombo.font = UIFont.Small
    panel.spawnProfileCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnProfileNormal", "Normal (Natural)")
            or "Normal (Natural)",
        "normal"
    )
    panel.spawnProfileCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnProfileDebug", "Debug (Legacy)")
            or "Debug (Legacy)",
        "debug"
    )
    panel.spawnProfileCombo:setSelected(1)
    panel:addChild(panel.spawnProfileCombo)
    y = y + 24

    panel.spawnOriginMode = "auto"
    panel.spawnOriginLabel = ISLabel:new(
        padding,
        y,
        18,
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOrigin", "Origin:") or "Origin:",
        0.9, 0.9, 0.7, 1,
        UIFont.Small,
        true
    )
    panel.spawnOriginLabel:initialise()
    panel.spawnOriginLabel:instantiate()
    panel:addChild(panel.spawnOriginLabel)

    panel.spawnOriginCombo = ISComboBox:new(padding + 95, y - 2, 215, 22, self, BurdJournals.UI.DebugPanel.onSpawnOriginChange)
    panel.spawnOriginCombo:initialise()
    panel.spawnOriginCombo:instantiate()
    panel.spawnOriginCombo.font = UIFont.Small
    panel.spawnOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginAuto", "Auto (Type Default)")
            or "Auto (Type Default)",
        "auto"
    )
    panel.spawnOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginPersonal", "Personal")
            or "Personal",
        "personal"
    )
    panel.spawnOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginFound", "Found")
            or "Found",
        "found"
    )
    panel.spawnOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginWorld", "Found in World")
            or "Found in World",
        "world"
    )
    panel.spawnOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginZombie", "Recovered from Zombie")
            or "Recovered from Zombie",
        "zombie"
    )
    panel.spawnOriginCombo:setSelected(1)
    panel:addChild(panel.spawnOriginCombo)
    y = y + 24
    
    -- ====== Owner/Assignment Section ======
    -- This section changes based on journal type:
    -- - Blank: Hidden (no owner needed)
    -- - Filled: Player dropdown + Custom option (for editable journals)
    -- - Worn/Bloody: Name field for RP/lore purposes
    
    panel.ownerSectionY = y  -- Store base Y position for dynamic repositioning
    
    panel.ownerLabel = ISLabel:new(
        padding, y, 18,
        (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOwnerAssign", "Assign to Player:")) or "Assign to Player:",
        0.9, 0.9, 0.7, 1, UIFont.Small, true
    )
    panel.ownerLabel:initialise()
    panel.ownerLabel:instantiate()
    panel:addChild(panel.ownerLabel)
    
    -- Player dropdown (includes "Custom..." option at the end)
    panel.ownerCombo = ISComboBox:new(padding + 110, y - 2, 200, 22, self, BurdJournals.UI.DebugPanel.onOwnerComboChange)
    panel.ownerCombo:initialise()
    panel.ownerCombo:instantiate()
    panel.ownerCombo.font = UIFont.Small
    panel:addChild(panel.ownerCombo)
    
    -- Populate with online players + "Custom..." option
    self:populateOwnerCombo(panel)
    self:applySpawnOwnerDefault(panel, panel.selectedType or "filled")
    y = y + 24
    
    -- Custom name entry (shown when "Custom..." is selected)
    panel.customNameLabel = ISLabel:new(padding, y, 18, "Custom Name:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.customNameLabel:initialise()
    panel.customNameLabel:instantiate()
    panel.customNameLabel:setVisible(false)
    panel:addChild(panel.customNameLabel)
    
    panel.customNameEntry = ISTextEntryBox:new("Unknown Survivor", padding + 85, y - 2, 225, 20)
    panel.customNameEntry:initialise()
    panel.customNameEntry:instantiate()
    panel.customNameEntry.font = UIFont.Small
    panel.customNameEntry:setTooltip("Enter a custom owner name for the journal")
    panel.customNameEntry:setVisible(false)
    panel:addChild(panel.customNameEntry)
    y = y + 24
    
    -- ====== Profession Section (for Worn/Bloody journals) ======
    panel.professionLabel = ISLabel:new(padding, y, 18, "Profession:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.professionLabel:initialise()
    panel.professionLabel:instantiate()
    panel:addChild(panel.professionLabel)
    
    panel.professionCombo = ISComboBox:new(padding + 75, y - 2, 235, 22, self, BurdJournals.UI.DebugPanel.onProfessionComboChange)
    panel.professionCombo:initialise()
    panel.professionCombo:instantiate()
    panel.professionCombo.font = UIFont.Small
    panel:addChild(panel.professionCombo)
    
    -- Populate profession dropdown
    panel.professionCombo:addOption("(Random)")  -- Index 1
    panel.professionCombo:addOption("(None)")    -- Index 2
    panel.professionCombo:addOption("Custom...")  -- Index 3
    if BurdJournals.PROFESSIONS then
        for _, prof in ipairs(BurdJournals.PROFESSIONS) do
            local displayName = prof.nameKey and getText(prof.nameKey) or prof.name
            panel.professionCombo:addOption(displayName)  -- Index 4+
        end
    end
    panel.professionCombo:setSelected(1)  -- Default to (Random)
    
    panel.professionSectionY = y
    y = y + 24
    
    -- Custom profession entry (shown when "Custom..." is selected)
    panel.customProfLabel = ISLabel:new(padding, y, 18, "Custom Prof:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.customProfLabel:initialise()
    panel.customProfLabel:instantiate()
    panel.customProfLabel:setVisible(false)
    panel:addChild(panel.customProfLabel)
    
    panel.customProfEntry = ISTextEntryBox:new("Former Survivor", padding + 85, y - 2, 225, 20)
    panel.customProfEntry:initialise()
    panel.customProfEntry:instantiate()
    panel.customProfEntry.font = UIFont.Small
    panel.customProfEntry:setTooltip("Enter custom profession (e.g., 'Former Teacher', 'Ex-Mechanic')")
    panel.customProfEntry:setVisible(false)
    panel:addChild(panel.customProfEntry)
    
    panel.customProfSectionY = y
    y = y + 26
    
    -- ====== Flavor Text Section (custom subtitle) ======
    panel.flavorLabel = ISLabel:new(padding, y, 18, "Flavor Text:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.flavorLabel:initialise()
    panel.flavorLabel:instantiate()
    panel:addChild(panel.flavorLabel)
    
    panel.flavorEntry = ISTextEntryBox:new("", padding + 75, y - 2, 235, 20)
    panel.flavorEntry:initialise()
    panel.flavorEntry:instantiate()
    panel.flavorEntry.font = UIFont.Small
    panel.flavorEntry:setTooltip("Custom flavor text (leave empty for profession default)")
    panel:addChild(panel.flavorEntry)
    
    panel.flavorSectionY = y
    y = y + 28

    -- ====== Spawn Metadata Section ======
    panel.ageLabel = ISLabel:new(padding, y, 18, "Age (hours ago):", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.ageLabel:initialise()
    panel.ageLabel:instantiate()
    panel:addChild(panel.ageLabel)

    panel.ageEntry = ISTextEntryBox:new("72", padding + 95, y - 2, 70, 20)
    panel.ageEntry:initialise()
    panel.ageEntry:instantiate()
    panel.ageEntry.font = UIFont.Small
    panel.ageEntry:setOnlyNumbers(true)
    panel.ageEntry:setTooltip("How many in-game hours old this journal should appear")
    panel:addChild(panel.ageEntry)
    y = y + 24

    -- Cursed controls (shown only for cursed type)
    panel.cursedStateLabel = ISLabel:new(padding, y, 18, (getText("UI_BurdJournals_DebugCursedState") or "Cursed State:"), 0.8, 0.75, 0.9, 1, UIFont.Small, true)
    panel.cursedStateLabel:initialise()
    panel.cursedStateLabel:instantiate()
    panel:addChild(panel.cursedStateLabel)

    panel.cursedStateCombo = ISComboBox:new(padding + 95, y - 2, 215, 22, self, nil)
    panel.cursedStateCombo:initialise()
    panel.cursedStateCombo:instantiate()
    panel.cursedStateCombo.font = UIFont.Small
    panel.cursedStateCombo:addOption(getText("UI_BurdJournals_DebugCursedDormant") or "Dormant (Cursed Item)")
    panel.cursedStateCombo:addOption(getText("UI_BurdJournals_DebugCursedUnleashed") or "Unleashed (Bloody Reward)")
    panel.cursedStateCombo:setSelected(1)
    panel:addChild(panel.cursedStateCombo)
    y = y + 24

    panel.forceCurseLabel = ISLabel:new(padding, y, 18, (getText("UI_BurdJournals_DebugForceCurse") or "Force Curse:"), 0.8, 0.75, 0.9, 1, UIFont.Small, true)
    panel.forceCurseLabel:initialise()
    panel.forceCurseLabel:instantiate()
    panel:addChild(panel.forceCurseLabel)

    local forceComboX = padding + 95
    local forceComboTotalW = math.max(220, panel.width - forceComboX - padding)
    local forceComboPrimaryW = math.max(120, math.floor((forceComboTotalW - 6) * 0.5))
    local forceComboTargetW = math.max(95, forceComboTotalW - forceComboPrimaryW - 6)

    panel.forceCurseCombo = ISComboBox:new(forceComboX, y - 2, forceComboPrimaryW, 22, self, BurdJournals.UI.DebugPanel.onForceCurseComboChange)
    panel.forceCurseCombo:initialise()
    panel.forceCurseCombo:instantiate()
    panel.forceCurseCombo.font = UIFont.Small
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseRandom") or "Random", "random")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseBarbedSeal") or "Barbed Seal (Hand Laceration)", "barbed_seal")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseJammedBreath") or "Jammed Breath (Endurance Hit)", "jammed_breath")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseHexedTooling") or "Hexed Tooling (Item Condition Loss)", "hexed_tooling")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseTornGear") or "Torn Gear (3-5 Holes)", "torn_gear")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseSeasonalWave") or "Seasonal Wave (Heat/Cold Spike)", "seasonal_wave")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCursePantsed") or "Pants'd (Unequip Bottoms)", "pantsed")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseGainNegative") or "Gain Negative Trait", "gain_negative_trait")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseLosePositive") or "Lose Positive Trait", "lose_positive_trait")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseLoseSkill") or "Lose Skill Level", "lose_skill_level")
    panel.forceCurseCombo:addOptionWithData(getText("UI_BurdJournals_DebugCurseAmbush") or "Ambush (Panic + Horde)", "panic")
    panel.forceCurseCombo:setSelected(1)
    panel:addChild(panel.forceCurseCombo)

    panel.forceCurseTargetCombo = ISComboBox:new(forceComboX + forceComboPrimaryW + 6, y - 2, forceComboTargetW, 22, self, nil)
    panel.forceCurseTargetCombo:initialise()
    panel.forceCurseTargetCombo:instantiate()
    panel.forceCurseTargetCombo.font = UIFont.Small
    panel.forceCurseTargetCombo:setVisible(false)
    if panel.forceCurseTargetCombo.setTooltip then
        panel.forceCurseTargetCombo:setTooltip(getText("UI_BurdJournals_DebugForceCurseTargetTip")
            or "Optional specific target used by the selected curse type.")
    end
    panel:addChild(panel.forceCurseTargetCombo)

    panel.forceCurseTargetType = nil
    y = y + 24

    panel.forgetSlotTick = ISTickBox:new(padding, y - 2, panel.width - (padding * 2), 20, "", self, nil)
    panel.forgetSlotTick:initialise()
    panel.forgetSlotTick:instantiate()
    panel.forgetSlotTick:addOption(getText("UI_BurdJournals_DebugForgetSlot") or "Include forget slot")
    if panel.forgetSlotTick.setSelected then
        panel.forgetSlotTick:setSelected(1, false)
    else
        panel.forgetSlotTick.selected[1] = false
    end
    panel:addChild(panel.forgetSlotTick)
    y = y + 24

    -- Separator line
    panel.contentSeparatorY = y
    y = y + 5
    
    -- ====== Content Section (Skills/Traits) ======
    -- Hidden for Blank journals, shown for Filled/Worn/Bloody
    
    panel.contentStartY = y
    
    -- Left column: Skills
    panel.skillsLabel = ISLabel:new(padding, y, 18, "Skills (click to add):", 1, 1, 1, 1, UIFont.Small, true)
    panel.skillsLabel:initialise()
    panel.skillsLabel:instantiate()
    panel:addChild(panel.skillsLabel)
    
    -- Right column: Traits
    panel.traitsLabel = ISLabel:new(padding + halfWidth + padding, y, 18, "Traits (click to toggle):", 1, 1, 1, 1, UIFont.Small, true)
    panel.traitsLabel:initialise()
    panel.traitsLabel:instantiate()
    panel:addChild(panel.traitsLabel)
    y = y + 20
    
    -- Search fields for skills and traits
    panel.spawnSkillSearch = ISTextEntryBox:new("", padding, y, halfWidth - 10, 18)
    panel.spawnSkillSearch:initialise()
    panel.spawnSkillSearch:instantiate()
    panel.spawnSkillSearch.font = UIFont.Small
    panel.spawnSkillSearch:setTooltip("Filter skills...")
    panel.spawnSkillSearch.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterSpawnSkillList(self)
    end
    panel:addChild(panel.spawnSkillSearch)
    
    panel.spawnTraitSearch = ISTextEntryBox:new("", padding + halfWidth + padding, y, halfWidth - 10, 18)
    panel.spawnTraitSearch:initialise()
    panel.spawnTraitSearch:instantiate()
    panel.spawnTraitSearch.font = UIFont.Small
    panel.spawnTraitSearch:setTooltip("Filter traits...")
    panel.spawnTraitSearch.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterSpawnTraitList(self)
    end
    panel:addChild(panel.spawnTraitSearch)
    y = y + 22
    
    -- Skill selection list
    local listHeight = 100
    panel.skillList = ISScrollingListBox:new(padding, y, halfWidth, listHeight)
    panel.skillList:initialise()
    panel.skillList:instantiate()
    panel.skillList.backgroundColor = {r=0.1, g=0.1, b=0.12, a=1}
    panel.skillList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.skillList.doDrawItem = BurdJournals.UI.DebugPanel.drawSkillItem
    panel.skillList.onMouseDown = BurdJournals.UI.DebugPanel.onSkillListClick
    panel.skillList.parentPanel = self
    panel:addChild(panel.skillList)
    
    -- Populate skills dynamically
    panel.selectedSkills = {}  -- {skillName = {level = X, extraXP = Y}}
    panel.focusedSkill = nil   -- Currently focused skill for level editing
    local availableSkills = BurdJournals.UI.DebugPanel.getAvailableSkills()
    for _, skillName in ipairs(availableSkills) do
        local displayName = BurdJournals.UI.DebugPanel.getSkillDisplayName(skillName)
        panel.skillList:addItem(displayName, {name = skillName, displayName = displayName, selected = false, level = 10, extraXP = 0})
    end
    
    -- Trait selection list
    panel.traitList = ISScrollingListBox:new(padding + halfWidth + padding, y, halfWidth, listHeight)
    panel.traitList:initialise()
    panel.traitList:instantiate()
    panel.traitList.backgroundColor = {r=0.1, g=0.1, b=0.12, a=1}
    panel.traitList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.traitList.doDrawItem = BurdJournals.UI.DebugPanel.drawTraitItem
    panel.traitList.onMouseDown = BurdJournals.UI.DebugPanel.onTraitListClick
    panel.traitList.parentPanel = self
    panel:addChild(panel.traitList)
    
    -- Populate traits dynamically (deduplicate by display name for B42 trait variants)
    panel.selectedTraits = {}  -- {traitName = true}
    local availableTraits = BurdJournals.UI.DebugPanel.getAvailableTraits()
    local addedDisplayNames = {}  -- Track display names to prevent visual duplicates
    for _, traitName in ipairs(availableTraits) do
        local displayName = BurdJournals.UI.DebugPanel.getTraitDisplayName(traitName)
        local displayNameLower = string.lower(displayName)
        -- Skip if we already have a trait with this display name
        if not addedDisplayNames[displayNameLower] then
            addedDisplayNames[displayNameLower] = traitName
            panel.traitList:addItem(displayName, {name = traitName, displayName = displayName, selected = false})
        end
    end
    y = y + listHeight + 5
    
    -- Level selector under skills
    panel.levelLabel = ISLabel:new(padding, y, 18, "Level (default):", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.levelLabel:initialise()
    panel.levelLabel:instantiate()
    panel:addChild(panel.levelLabel)
    
    panel.levelButtons = {}
    local lvlX = padding + 80
    for lvl = 0, 10 do
        local btn = ISButton:new(lvlX, y - 2, 22, 20, tostring(lvl), self, BurdJournals.UI.DebugPanel.onLevelSelect)
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = lvl
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
        btn.backgroundColor = lvl == 10 and {r=0.3, g=0.5, b=0.4, a=1} or {r=0.2, g=0.2, b=0.25, a=1}
        panel:addChild(btn)
        panel.levelButtons[lvl] = btn
        lvlX = lvlX + 24
    end
    panel.defaultLevel = 10
    panel.defaultExtraXP = 0
    y = y + 25
    
    -- Extra XP input row
    panel.extraXPLabel = ISLabel:new(padding, y, 18, "Extra XP:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.extraXPLabel:initialise()
    panel.extraXPLabel:instantiate()
    panel:addChild(panel.extraXPLabel)
    
    panel.extraXPEntry = ISTextEntryBox:new("0", padding + 60, y - 2, 60, 20)
    panel.extraXPEntry:initialise()
    panel.extraXPEntry:instantiate()
    panel.extraXPEntry.font = UIFont.Small
    panel.extraXPEntry:setOnlyNumbers(true)
    panel.extraXPEntry.backgroundColor = {r=0.15, g=0.15, b=0.18, a=1}
    panel.extraXPEntry.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    -- Use deferred update to fix "one step behind" issue with onTextChange
    panel.extraXPEntry.onTextChange = function()
        -- Defer the update to next frame so getText() returns the updated value
        panel.extraXPPendingUpdate = true
    end
    panel:addChild(panel.extraXPEntry)
    
    panel.extraXPRange = ISLabel:new(padding + 125, y, 18, "(0-149)", 0.6, 0.7, 0.6, 1, UIFont.Small, true)
    panel.extraXPRange:initialise()
    panel.extraXPRange:instantiate()
    panel:addChild(panel.extraXPRange)
    y = y + 25
    
    -- Selected summary
    local summaryLabel = ISLabel:new(padding, y, 18, "Selected:", 0.7, 0.8, 0.9, 1, UIFont.Small, true)
    summaryLabel:initialise()
    summaryLabel:instantiate()
    panel:addChild(summaryLabel)
    panel.summaryLabelRef = summaryLabel
    y = y + 18
    
    panel.summaryText = ISLabel:new(padding, y, 18, "No items selected", 0.6, 0.7, 0.6, 1, UIFont.Small, true)
    panel.summaryText:initialise()
    panel.summaryText:instantiate()
    panel:addChild(panel.summaryText)
    y = y + 25
    
    -- Clear selections button
    panel.clearBtn = ISButton:new(padding, y, 100, 22, "Clear All", self, BurdJournals.UI.DebugPanel.onClearSelections)
    panel.clearBtn:initialise()
    panel.clearBtn:instantiate()
    panel.clearBtn.font = UIFont.Small
    panel.clearBtn.textColor = {r=1, g=0.8, b=0.8, a=1}
    panel.clearBtn.borderColor = {r=0.5, g=0.3, b=0.3, a=1}
    panel.clearBtn.backgroundColor = {r=0.3, g=0.15, b=0.15, a=1}
    panel:addChild(panel.clearBtn)
    
    -- Quick preset buttons
    local presetX = padding + 110
    panel.presetButtons = {}
    local presets = {
        {name = "Max Passive", preset = "maxpassive"},
        {name = "All + Traits", preset = "allpositive"},
        {name = "All - Traits", preset = "allnegative"},
    }
    for _, presetDef in ipairs(presets) do
        local btn = ISButton:new(presetX, y, 95, 22, presetDef.name, self, BurdJournals.UI.DebugPanel.onPresetClick)
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = presetDef.preset
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = {r=0.5, g=0.4, b=0.2, a=1}
        btn.backgroundColor = {r=0.3, g=0.25, b=0.15, a=1}
        panel:addChild(btn)
        table.insert(panel.presetButtons, btn)
        presetX = presetX + 100
    end
    y = y + 35
    
    panel.contentEndY = y
    
    -- ====== Spawn Button ======
    local spawnBtn = ISButton:new(padding, y, panel.width - padding * 2, 30, "SPAWN JOURNAL", self, BurdJournals.UI.DebugPanel.onSpawnClick)
    spawnBtn:initialise()
    spawnBtn:instantiate()
    spawnBtn.font = UIFont.Medium
    spawnBtn.textColor = {r=1, g=1, b=1, a=1}
    spawnBtn.borderColor = {r=0.3, g=0.7, b=0.4, a=1}
    spawnBtn.backgroundColor = {r=0.15, g=0.4, b=0.2, a=1}
    panel:addChild(spawnBtn)
    panel.spawnBtn = spawnBtn
    
    self.spawnPanel = panel
    
    -- Initial visibility update based on default type
    self:updateSpawnPanelVisibility()
end

-- Populate the owner dropdown with online players + "Custom..." option
local function findOwnerOptionIndex(panel, predicate)
    if not panel or not panel.ownerCombo or not predicate then
        return nil
    end
    local optionCount = #panel.ownerCombo.options
    for i = 1, optionCount do
        local data = panel.ownerCombo:getOptionData(i)
        if predicate(data, i) then
            return i
        end
    end
    return nil
end

function BurdJournals.UI.DebugPanel:applySpawnOwnerDefault(panel, journalType)
    if not panel or not panel.ownerCombo then
        return
    end
    local jType = tostring(journalType or panel.selectedType or "filled")
    local isFilled = jType == "filled"
    local selectedIndex = panel.ownerCombo.selected or 1
    local selectedData = panel.ownerCombo:getOptionData(selectedIndex)

    if isFilled then
        if selectedData and selectedData.isPlayer then
            return
        end
        local playerIndex = findOwnerOptionIndex(panel, function(data)
            return type(data) == "table" and data.isPlayer == true
        end)
        local noneIndex = findOwnerOptionIndex(panel, function(data)
            return type(data) == "table" and data.isNone == true
        end)
        panel.ownerCombo.selected = playerIndex or noneIndex or 1
        return
    end

    if selectedData and selectedData.isNone then
        return
    end
    local noneIndex = findOwnerOptionIndex(panel, function(data)
        return type(data) == "table" and data.isNone == true
    end)
    if noneIndex then
        panel.ownerCombo.selected = noneIndex
    end
end

function BurdJournals.UI.DebugPanel:populateOwnerCombo(panel)
    panel.ownerCombo:clear()

    local noneLabel = (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOwnerNone", "None")) or "None"
    panel.ownerCombo:addOptionWithData(noneLabel, {
        isNone = true
    })

    local addedCount = 0
    
    -- Add online players
    local onlinePlayers = getOnlinePlayers()
    if onlinePlayers then
        for i = 0, onlinePlayers:size() - 1 do
            local p = onlinePlayers:get(i)
            if p then
                local username = p:getUsername()
                local charName = p:getDescriptor():getForename() .. " " .. p:getDescriptor():getSurname()
                local displayText = charName .. " (" .. username .. ")"
                panel.ownerCombo:addOptionWithData(displayText, {
                    isPlayer = true,
                    username = username,
                    steamId = BurdJournals.getPlayerSteamId(p),
                    characterName = charName,
                    player = p
                })
                addedCount = addedCount + 1
            end
        end
    end
    
    -- Add single player if no online players (SP mode)
    if addedCount == 0 then
        local p = getPlayer()
        if p then
            local charName = p:getDescriptor():getForename() .. " " .. p:getDescriptor():getSurname()
            local username = p:getUsername()
            if not username then username = "Player" end
            panel.ownerCombo:addOptionWithData(charName, {
                isPlayer = true,
                username = username,
                steamId = BurdJournals.getPlayerSteamId(p),
                characterName = charName,
                player = p
            })
        end
    end
    
    -- Add "Custom..." option at the end
    panel.ownerCombo:addOptionWithData(
        (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOwnerCustom", "Custom...")) or "Custom...",
        {
        isCustom = true
    })

    panel.ownerCombo.selected = 1
end

-- Handle owner combo box change
function BurdJournals.UI.DebugPanel.onOwnerComboChange(self)
    -- Trigger full visibility/layout update
    self:updateSpawnPanelVisibility()
end

-- Handle profession combo box change
function BurdJournals.UI.DebugPanel.onProfessionComboChange(self)
    -- Trigger full visibility/layout update
    self:updateSpawnPanelVisibility()
end

local function buildPositiveTraitDebugTargets()
    local targets = {}
    local costLookup = BurdJournals.UI.DebugPanel.buildTraitCostLookup()
    local seen = {}
    local allTraits = BurdJournals.UI.DebugPanel.getAvailableTraits()
    for _, traitId in ipairs(allTraits or {}) do
        local id = tostring(traitId or "")
        local lower = string.lower(id)
        local cost = tonumber(costLookup[lower]) or 0
        if cost > 0 and not seen[lower] then
            seen[lower] = true
            targets[#targets + 1] = {
                id = id,
                label = BurdJournals.UI.DebugPanel.getTraitDisplayName(id)
            }
        end
    end
    table.sort(targets, function(a, b)
        return string.lower(a.label) < string.lower(b.label)
    end)
    return targets
end

local function buildNegativeTraitDebugTargets()
    local targets = {}
    local seen = {}
    for _, traitId in ipairs(BurdJournals.REMOVABLE_TRAITS or {}) do
        local id = tostring(traitId or "")
        local lower = string.lower(id)
        if id ~= "" and not seen[lower] then
            seen[lower] = true
            targets[#targets + 1] = {
                id = id,
                label = BurdJournals.UI.DebugPanel.getTraitDisplayName(id)
            }
        end
    end
    table.sort(targets, function(a, b)
        return string.lower(a.label) < string.lower(b.label)
    end)
    return targets
end

local function buildSkillDebugTargets()
    local targets = {}
    local seen = {}
    local skills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
    for _, skillName in ipairs(skills) do
        local id = tostring(skillName or "")
        local lower = string.lower(id)
        if id ~= "" and not seen[lower] then
            seen[lower] = true
            targets[#targets + 1] = {
                id = id,
                label = BurdJournals.UI.DebugPanel.getSkillDisplayName(id)
            }
        end
    end
    table.sort(targets, function(a, b)
        return string.lower(a.label) < string.lower(b.label)
    end)
    return targets
end

function BurdJournals.UI.DebugPanel.refreshForceCurseTargetCombo(panel)
    if not panel or not panel.forceCurseCombo or not panel.forceCurseTargetCombo then
        return
    end

    local curseType = panel.forceCurseCombo:getOptionData(panel.forceCurseCombo.selected)
        or panel.forceCurseCombo.options[panel.forceCurseCombo.selected]
    local targetCombo = panel.forceCurseTargetCombo
    targetCombo:clear()
    panel.forceCurseTargetType = nil

    if curseType == "gain_negative_trait" then
        panel.forceCurseTargetType = "trait"
        targetCombo:addOptionWithData("Contextual (Negative Trait)", nil)
        for _, entry in ipairs(buildNegativeTraitDebugTargets()) do
            targetCombo:addOptionWithData(entry.label, entry.id)
        end
    elseif curseType == "lose_positive_trait" then
        panel.forceCurseTargetType = "trait"
        targetCombo:addOptionWithData("Contextual (Positive Trait)", nil)
        for _, entry in ipairs(buildPositiveTraitDebugTargets()) do
            targetCombo:addOptionWithData(entry.label, entry.id)
        end
    elseif curseType == "lose_skill_level" then
        panel.forceCurseTargetType = "skill"
        targetCombo:addOptionWithData("Contextual (Skill)", nil)
        for _, entry in ipairs(buildSkillDebugTargets()) do
            targetCombo:addOptionWithData(entry.label, entry.id)
        end
    end

    if panel.forceCurseTargetType then
        targetCombo:setSelected(1)
        targetCombo:setVisible(true)
    else
        targetCombo:setVisible(false)
    end
end

function BurdJournals.UI.DebugPanel.onForceCurseComboChange(self)
    BurdJournals.UI.DebugPanel.refreshForceCurseTargetCombo(self.spawnPanel)
end

local function isSpawnSkillAllowedForType(journalType, skillName)
    if not skillName then
        return false
    end
    local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillName) or (skillName == "Fitness" or skillName == "Strength")
    if not isPassive then
        return true
    end
    if not BurdJournals.isSkillEnabledForJournal then
        return true
    end
    local context = {isPlayerCreated = (journalType == "filled")}
    return BurdJournals.isSkillEnabledForJournal(context, skillName)
end

local function sanitizeSpawnSkillSelections(panel, journalType)
    if not panel or not panel.skillList then
        return
    end
    local focusedStillValid = false
    for _, itemData in ipairs(panel.skillList.items) do
        local data = itemData and itemData.item
        if data and data.name then
            local allowed = isSpawnSkillAllowedForType(journalType, data.name)
            if not allowed then
                data.selected = false
                data.hiddenBySandbox = true
                panel.selectedSkills[data.name] = nil
                if panel.focusedSkill == data.name then
                    panel.focusedSkill = nil
                end
            else
                data.hiddenBySandbox = false
                if panel.focusedSkill == data.name and data.selected then
                    focusedStillValid = true
                end
            end
        end
    end
    if panel.focusedSkill and not focusedStillValid then
        panel.focusedSkill = nil
    end
end

local function normalizeDebugOriginMode(mode)
    local value = tostring(mode or "auto")
    if value == "personal" or value == "found" or value == "world" or value == "zombie" then
        return value
    end
    return "auto"
end

local function getDefaultDebugOriginModeForType(journalType)
    local t = tostring(journalType or "filled")
    if t == "worn" then
        return "found"
    end
    if t == "bloody" or t == "cursed" then
        return "zombie"
    end
    return "personal"
end

local function resolveSpawnOriginMode(panel, journalType)
    local selected = normalizeDebugOriginMode(panel and panel.spawnOriginMode or "auto")
    if selected == "auto" then
        return getDefaultDebugOriginModeForType(journalType or (panel and panel.selectedType))
    end
    return selected
end

local function getOriginModeLabel(mode)
    local value = normalizeDebugOriginMode(mode)
    if value == "personal" then
        return getText("Tooltip_BurdJournals_OriginPersonal") or "Origin: Personal"
    elseif value == "zombie" then
        return getText("Tooltip_BurdJournals_OriginZombie") or "Origin: Recovered from zombie"
    elseif value == "world" then
        return getText("Tooltip_BurdJournals_OriginWorld") or "Origin: Found in world"
    elseif value == "found" then
        return getText("Tooltip_BurdJournals_OriginFound") or "Origin: Found"
    end
    return getText("Tooltip_BurdJournals_OriginFound") or "Origin: Found"
end

local function inferJournalOriginMode(journalData)
    if type(journalData) ~= "table" then
        return "found"
    end
    local sourceType = type(journalData.sourceType) == "string" and string.lower(journalData.sourceType) or ""
    if sourceType == "personal" then
        return "personal"
    elseif sourceType == "zombie" then
        return "zombie"
    elseif sourceType == "world" then
        return "world"
    elseif sourceType == "found" then
        return "found"
    end
    if journalData.isPlayerCreated == true then
        return "personal"
    end
    if journalData.wasFromBloody == true or journalData.hasBloodyOrigin == true then
        return "zombie"
    end
    return "found"
end

local function applyOriginModeToJournalData(journalData, originMode)
    if type(journalData) ~= "table" then
        return
    end
    local mode = normalizeDebugOriginMode(originMode)
    if mode == "auto" then
        mode = "found"
    end
    journalData.originMode = mode
    if mode == "personal" then
        journalData.isPlayerCreated = true
        journalData.sourceType = "personal"
    elseif mode == "zombie" then
        journalData.isPlayerCreated = false
        journalData.sourceType = "zombie"
    elseif mode == "world" then
        journalData.isPlayerCreated = false
        journalData.sourceType = "world"
    else
        journalData.isPlayerCreated = false
        journalData.sourceType = "found"
    end
end

-- Update spawn panel visibility based on selected journal type
function BurdJournals.UI.DebugPanel:updateSpawnPanelVisibility()
    local panel = self.spawnPanel
    if not panel then return end
    
    -- Ensure all required elements exist before proceeding
    if not panel.ownerLabel or not panel.ownerCombo or not panel.customNameEntry then
        return  -- Panel not fully initialized yet
    end
    
    local journalType = panel.selectedType or "blank"
    local isBlank = (journalType == "blank")
    local isFilled = (journalType == "filled")
    local isCursed = (journalType == "cursed")
    local isWornOrBloody = (journalType == "worn" or journalType == "bloody")
    
    -- Check combo selections (with nil safety)
    local selectedData = nil
    if panel.ownerCombo and panel.ownerCombo.selected and panel.ownerCombo.selected > 0 then
        selectedData = panel.ownerCombo:getOptionData(panel.ownerCombo.selected)
    end
    local isCustomOwner = (selectedData ~= nil and selectedData.isCustom == true)
    local profSelected = 1
    if panel.professionCombo and panel.professionCombo.selected then
        profSelected = panel.professionCombo.selected
    end
    local isCustomProf = (profSelected == 3)  -- Index 3 is "Custom..."
    
    -- Determine visibility for each section (explicitly boolean)
    local showOrigin = (isBlank == false)
    local showOwner = (isFilled == true)
    local showCustomName = (showOwner == true and isCustomOwner == true)
    local showProfession = (isWornOrBloody == true)
    local showCustomProf = (isWornOrBloody == true and isCustomProf == true)
    local showFlavor = (isBlank == false)
    local showSpawnMeta = (isBlank == false)
    local showCursedControls = (isCursed == true)
    if showCursedControls then
        BurdJournals.UI.DebugPanel.refreshForceCurseTargetCombo(panel)
    end
    local showForceCurseTarget = showCursedControls and panel.forceCurseTargetType ~= nil
    local showForgetSlotToggle = (isBlank == false and (isWornOrBloody == true or isCursed == true))
    local showContent = (isBlank == false)
    
    -- Set visibility (with nil guards)
    if panel.spawnOriginLabel then panel.spawnOriginLabel:setVisible(showOrigin) end
    if panel.spawnOriginCombo then panel.spawnOriginCombo:setVisible(showOrigin) end
    if panel.ownerLabel then panel.ownerLabel:setVisible(showOwner) end
    if panel.ownerCombo then panel.ownerCombo:setVisible(showOwner) end
    if panel.customNameLabel then panel.customNameLabel:setVisible(showCustomName) end
    if panel.customNameEntry then panel.customNameEntry:setVisible(showCustomName) end
    if panel.professionLabel then panel.professionLabel:setVisible(showProfession) end
    if panel.professionCombo then panel.professionCombo:setVisible(showProfession) end
    if panel.customProfLabel then panel.customProfLabel:setVisible(showCustomProf) end
    if panel.customProfEntry then panel.customProfEntry:setVisible(showCustomProf) end
    if panel.flavorLabel then panel.flavorLabel:setVisible(showFlavor) end
    if panel.flavorEntry then panel.flavorEntry:setVisible(showFlavor) end
    if panel.ageLabel then panel.ageLabel:setVisible(showSpawnMeta) end
    if panel.ageEntry then panel.ageEntry:setVisible(showSpawnMeta) end
    if panel.cursedStateLabel then panel.cursedStateLabel:setVisible(showCursedControls) end
    if panel.cursedStateCombo then panel.cursedStateCombo:setVisible(showCursedControls) end
    if panel.forceCurseLabel then panel.forceCurseLabel:setVisible(showCursedControls) end
    if panel.forceCurseCombo then panel.forceCurseCombo:setVisible(showCursedControls) end
    if panel.forceCurseTargetCombo then panel.forceCurseTargetCombo:setVisible(showForceCurseTarget) end
    if panel.forgetSlotTick then panel.forgetSlotTick:setVisible(showForgetSlotToggle) end
    
    -- Update owner label text
    if panel.ownerLabel then
        panel.ownerLabel:setName((BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOwnerAssign", "Assign to Player:")) or "Assign to Player:")
    end
    
    -- Dynamic Y repositioning based on visibility
    local padding = 10
    local rowHeight = 24
    local y = panel.ownerSectionY or 100  -- Start from owner section base (fallback to 100 if not set)
    
    -- Owner row
    if showOwner then
        panel.ownerLabel:setY(y)
        panel.ownerCombo:setY(y - 2)
        y = y + rowHeight
    end
    
    -- Custom name row (conditional)
    if showCustomName then
        panel.customNameLabel:setY(y)
        panel.customNameEntry:setY(y - 2)
        y = y + rowHeight
    end
    
    -- Profession row (conditional)
    if showProfession then
        panel.professionLabel:setY(y)
        panel.professionCombo:setY(y - 2)
        y = y + rowHeight
    end
    
    -- Custom profession row (conditional)
    if showCustomProf then
        panel.customProfLabel:setY(y)
        panel.customProfEntry:setY(y - 2)
        y = y + rowHeight
    end
    
    -- Flavor text row
    if showFlavor then
        panel.flavorLabel:setY(y)
        panel.flavorEntry:setY(y - 2)
        y = y + rowHeight
    end

    if showSpawnMeta then
        if panel.ageLabel then panel.ageLabel:setY(y) end
        if panel.ageEntry then panel.ageEntry:setY(y - 2) end
        y = y + rowHeight
    end

    if showCursedControls then
        if panel.cursedStateLabel then panel.cursedStateLabel:setY(y) end
        if panel.cursedStateCombo then panel.cursedStateCombo:setY(y - 2) end
        y = y + rowHeight

        if panel.forceCurseLabel then panel.forceCurseLabel:setY(y) end
        if panel.forceCurseCombo then panel.forceCurseCombo:setY(y - 2) end
        if panel.forceCurseTargetCombo then panel.forceCurseTargetCombo:setY(y - 2) end
        y = y + rowHeight

    end

    if showForgetSlotToggle then
        if panel.forgetSlotTick then panel.forgetSlotTick:setY(y - 2) end
        y = y + rowHeight
    end
    
    -- Content section (skills/traits)
    y = y + rowHeight + 4  -- Small gap before content
    
    -- Set visibility for content elements (with nil guards)
    if panel.skillsLabel then panel.skillsLabel:setVisible(showContent) end
    if panel.traitsLabel then panel.traitsLabel:setVisible(showContent) end
    if panel.spawnSkillSearch then panel.spawnSkillSearch:setVisible(showContent) end
    if panel.spawnTraitSearch then panel.spawnTraitSearch:setVisible(showContent) end
    if panel.skillList then panel.skillList:setVisible(showContent) end
    if panel.traitList then panel.traitList:setVisible(showContent) end
    if panel.levelLabel then panel.levelLabel:setVisible(showContent) end
    if panel.levelButtons then
        for _, btn in pairs(panel.levelButtons) do
            if btn then btn:setVisible(showContent) end
        end
    end
    if panel.extraXPLabel then panel.extraXPLabel:setVisible(showContent) end
    if panel.extraXPEntry then panel.extraXPEntry:setVisible(showContent) end
    if panel.extraXPRange then panel.extraXPRange:setVisible(showContent) end
    if panel.summaryLabelRef then panel.summaryLabelRef:setVisible(showContent) end
    if panel.summaryText then panel.summaryText:setVisible(showContent) end
    if panel.clearBtn then panel.clearBtn:setVisible(showContent) end
    if panel.presetButtons then
        for _, btn in ipairs(panel.presetButtons) do
            if btn then btn:setVisible(showContent) end
        end
    end
    
    if showContent and panel.skillList then
        local halfWidth = (panel.width - padding * 3) / 2
        
        -- Skills/Traits labels
        if panel.skillsLabel then panel.skillsLabel:setY(y) end
        if panel.traitsLabel then panel.traitsLabel:setY(y) end
        y = y + 20
        
        -- Search fields
        if panel.spawnSkillSearch then panel.spawnSkillSearch:setY(y) end
        if panel.spawnTraitSearch then panel.spawnTraitSearch:setY(y) end
        y = y + 22
        
        -- Skill/Trait lists
        if panel.skillList then panel.skillList:setY(y) end
        if panel.traitList then panel.traitList:setY(y) end
        y = y + (panel.skillList and panel.skillList.height or 0) + 8
        
        -- Level controls
        if panel.levelLabel then panel.levelLabel:setY(y + 3) end
        if panel.levelButtons then
            for lvl = 0, 10 do
                local btn = panel.levelButtons[lvl]
                if btn then
                    btn:setY(y)
                end
            end
        end
        y = y + 28
        
        -- Extra XP row
        if panel.extraXPLabel then panel.extraXPLabel:setY(y + 3) end
        if panel.extraXPEntry then panel.extraXPEntry:setY(y) end
        if panel.extraXPRange then panel.extraXPRange:setY(y + 3) end
        y = y + 28
        
        -- Summary (label on one line, content below)
        if panel.summaryLabelRef then panel.summaryLabelRef:setY(y) end
        y = y + 18
        if panel.summaryText then panel.summaryText:setY(y) end
        y = y + 22
        
        -- Preset buttons and Clear button
        if panel.clearBtn then panel.clearBtn:setY(y) end
        if panel.presetButtons then
            for _, btn in ipairs(panel.presetButtons) do
                if btn then btn:setY(y) end
            end
        end
        y = y + 35
        
        -- Spawn button
        panel.spawnBtn:setY(y)
    else
        -- Blank journal - just show spawn button near the top
        y = y + 10
        panel.spawnBtn:setY(y)
    end

    if showContent then
        sanitizeSpawnSkillSelections(panel, journalType)
        BurdJournals.UI.DebugPanel.filterSpawnSkillList(self)
        BurdJournals.UI.DebugPanel.updateLevelButtons(self)
        BurdJournals.UI.DebugPanel.updateSpawnSummary(self)
    end
    BurdJournals.UI.DebugPanel.updateSpawnSummary(self)
    
    -- Update spawn button text
    if isBlank then
        panel.spawnBtn:setTitle("SPAWN BLANK JOURNAL")
    elseif isCursed and panel.cursedStateCombo and panel.cursedStateCombo.selected == 2 then
        panel.spawnBtn:setTitle("SPAWN CURSED REWARD")
    else
        panel.spawnBtn:setTitle("SPAWN " .. string.upper(journalType) .. " JOURNAL")
    end
end

-- Filter functions for Spawn tab
function BurdJournals.UI.DebugPanel.filterSpawnSkillList(self)
    local panel = self.spawnPanel
    if not panel or not panel.skillList then return end
    local journalType = panel.selectedType or "blank"
    
    local searchText = ""
    if panel.spawnSkillSearch and panel.spawnSkillSearch.getText then
        searchText = panel.spawnSkillSearch:getText()
    end
    
    for _, item in ipairs(panel.skillList.items) do
        local skillName = item.item and item.item.name
        local isAllowed = isSpawnSkillAllowedForType(journalType, skillName)
        if item.item then
            item.item.hiddenBySandbox = not isAllowed
        end
        if not isAllowed then
            item.item.hidden = true
        else
            if searchText == "" then
                item.item.hidden = false
            else
                item.item.hidden = not debugSearchMatches(searchText, item.item.displayName, item.item.name)
            end
        end
    end
end

function BurdJournals.UI.DebugPanel.filterSpawnTraitList(self)
    local panel = self.spawnPanel
    if not panel or not panel.traitList then return end
    
    local searchText = ""
    if panel.spawnTraitSearch and panel.spawnTraitSearch.getText then
        searchText = panel.spawnTraitSearch:getText()
    end
    
    for _, item in ipairs(panel.traitList.items) do
        if searchText == "" then
            item.item.hidden = false
        else
            item.item.hidden = not debugSearchMatches(searchText, item.item.displayName, item.item.name)
        end
    end
end

-- Custom draw function for skill list items
function BurdJournals.UI.DebugPanel.drawSkillItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    local isFocused = self.parentPanel and self.parentPanel.spawnPanel and 
                      self.parentPanel.spawnPanel.focusedSkill == data.name
    
    -- Background - highlight focused item more prominently
    if isFocused and data.selected then
        self:drawRect(0, y, self.width, h, 0.4, 0.3, 0.6, 0.5)  -- Bright highlight for focused+selected
    elseif data.selected then
        self:drawRect(0, y, self.width, h, 0.25, 0.2, 0.4, 0.3)  -- Dimmer for just selected
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.3)
    end
    
    -- Checkbox
    local checkX = 5
    if data.selected then
        self:drawText("[X]", checkX, y + 2, 0.3, 0.8, 0.3, 1, UIFont.Small)
    else
        self:drawText("[ ]", checkX, y + 2, 0.5, 0.5, 0.5, 1, UIFont.Small)
    end
    
    -- Skill name (use display name if available)
    local textX = 30
    local displayText = data.displayName or data.name
    local color = isFocused and {1, 1, 0.7} or (data.selected and {0.9, 1, 0.9} or {0.7, 0.7, 0.7})
    self:drawText(displayText, textX, y + 2, color[1], color[2], color[3], 1, UIFont.Small)
    
    -- Show level and extra XP for selected skills
    if data.selected then
        local lvlColor = isFocused and {1, 1, 0.5} or {0.5, 0.8, 1}
        local extraXP = data.extraXP or 0
        local lvlText = string.format(getText("UI_BurdJournals_LevelFormat"), data.level or 0)
        if extraXP > 0 then
            lvlText = lvlText .. "+" .. extraXP
        end
        -- Adjust position based on text length (account for scrollbar)
        local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH
        local textWidth = getTextManager():MeasureStringX(UIFont.Small, lvlText)
        self:drawText(lvlText, self.width - textWidth - 5 - scrollOffset, y + 2, lvlColor[1], lvlColor[2], lvlColor[3], 1, UIFont.Small)
    end
    
    return y + h
end

-- Custom draw function for trait list items
function BurdJournals.UI.DebugPanel.drawTraitItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    -- Background
    if data.selected then
        self:drawRect(0, y, self.width, h, 0.3, 0.3, 0.5, 0.2)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.3)
    end
    
    -- Checkbox
    local checkX = 5
    if data.selected then
        self:drawText("[X]", checkX, y + 2, 0.3, 0.8, 0.3, 1, UIFont.Small)
    else
        self:drawText("[ ]", checkX, y + 2, 0.5, 0.5, 0.5, 1, UIFont.Small)
    end
    
    -- Trait name (use display name if available)
    local textX = 30
    local displayText = data.displayName or data.name
    local color = data.selected and {0.9, 1, 0.9} or {0.7, 0.7, 0.7}
    self:drawText(displayText, textX, y + 2, color[1], color[2], color[3], 1, UIFont.Small)
    
    return y + h
end

-- Skill list click handler
function BurdJournals.UI.DebugPanel.onSkillListClick(self, x, y)
    ISScrollingListBox.onMouseDown(self, x, y)
    local row = self:rowAt(x, y)
    if row > 0 and row <= #self.items then
        local item = self.items[row]
        local data = item.item
        if not data or data.hidden or data.hiddenBySandbox then
            return
        end
        local panel = self.parentPanel.spawnPanel
        
        -- Check if clicking on checkbox area (left 25 pixels) or text area
        local isCheckboxClick = x < 25
        
        if data.selected and not isCheckboxClick then
            -- Already selected, just focus it (don't toggle)
            panel.focusedSkill = data.name
            self.parentPanel:setStatus("Editing level for " .. data.name, {r=1, g=1, b=0.6})
        else
            -- Toggle selection (checkbox click or clicking unselected item)
            data.selected = not data.selected
            
            if data.selected then
                -- New selection: set to default level/extraXP and focus it
                data.level = panel.defaultLevel
                data.extraXP = panel.defaultExtraXP or 0
                panel.selectedSkills[data.name] = {level = data.level, extraXP = data.extraXP}
                panel.focusedSkill = data.name
            else
                -- Deselected: remove from selections and clear focus if it was focused
                panel.selectedSkills[data.name] = nil
                if panel.focusedSkill == data.name then
                    panel.focusedSkill = nil
                end
            end
        end
        
        -- Update level buttons to show focused skill's level
        self.parentPanel:updateLevelButtons()
        self.parentPanel:updateSpawnSummary()
    end
end

-- Trait list click handler
function BurdJournals.UI.DebugPanel.onTraitListClick(self, x, y)
    ISScrollingListBox.onMouseDown(self, x, y)
    local row = self:rowAt(x, y)
    if row > 0 and row <= #self.items then
        local item = self.items[row]
        local data = item.item
        data.selected = not data.selected
        
        -- Update parent panel's selected traits
        local panel = self.parentPanel.spawnPanel
        if data.selected then
            panel.selectedTraits[data.name] = true
        else
            panel.selectedTraits[data.name] = nil
        end
        self.parentPanel:updateSpawnSummary()
    end
end

-- Level selector click - only affects focused skill, or sets default for new selections
function BurdJournals.UI.DebugPanel:onLevelSelect(button)
    local panel = self.spawnPanel
    local level = button.internal
    
    -- If a skill is focused, update only that skill's level
    if panel.focusedSkill then
        for _, itemData in ipairs(panel.skillList.items) do
            if itemData.item.name == panel.focusedSkill and itemData.item.selected then
                itemData.item.level = level
                
                -- Get valid range for new level and clamp extraXP if needed
                local range = BurdJournals.Client.Debug.getXPRangeForLevel and 
                              BurdJournals.Client.Debug.getXPRangeForLevel(itemData.item.name, level) or
                              {maxExtra = 999999}
                local currentExtraXP = itemData.item.extraXP or 0
                if currentExtraXP > range.maxExtra then
                    itemData.item.extraXP = range.maxExtra
                end
                
                panel.selectedSkills[itemData.item.name] = {level = level, extraXP = itemData.item.extraXP or 0}
                self:setStatus("Set " .. panel.focusedSkill .. " to level " .. level, {r=0.5, g=0.8, b=1})
                break
            end
        end
    else
        -- No skill focused - update default level for new selections
        panel.defaultLevel = level
        -- Reset default extraXP to 0 when level changes (to avoid exceeding new max)
        panel.defaultExtraXP = 0
        self:setStatus("Default level set to " .. level, {r=0.6, g=0.7, b=0.8})
    end
    
    self:updateLevelButtons()
    self:updateSpawnSummary()
end

-- Update level button visuals based on focused skill or default
function BurdJournals.UI.DebugPanel:updateLevelButtons()
    local panel = self.spawnPanel
    if not panel or not panel.levelButtons then return end
    
    -- Determine which level and extraXP to highlight
    local highlightLevel = panel.defaultLevel
    local currentExtraXP = panel.defaultExtraXP or 0
    local focusedSkillName = nil
    
    if panel.focusedSkill then
        -- Find the focused skill's level and extraXP
        for _, itemData in ipairs(panel.skillList.items) do
            if itemData.item.name == panel.focusedSkill and itemData.item.selected then
                highlightLevel = itemData.item.level
                currentExtraXP = itemData.item.extraXP or 0
                focusedSkillName = itemData.item.name
                break
            end
        end
    end
    
    -- Update label text
    if panel.levelLabel then
        if panel.focusedSkill then
            -- Find display name for focused skill
            local displayName = panel.focusedSkill
            for _, itemData in ipairs(panel.skillList.items) do
                if itemData.item.name == panel.focusedSkill then
                    displayName = itemData.item.displayName or panel.focusedSkill
                    break
                end
            end
            panel.levelLabel:setName("Level for " .. displayName .. ":")
            panel.levelLabel.r = 1
            panel.levelLabel.g = 1
            panel.levelLabel.b = 0.6
        else
            panel.levelLabel:setName("Level (default):")
            panel.levelLabel.r = 0.8
            panel.levelLabel.g = 0.8
            panel.levelLabel.b = 0.8
        end
    end
    
    -- Update extra XP entry and range
    if panel.extraXPEntry and panel.extraXPRange then
        -- Get XP range for current skill/level
        local skillName = focusedSkillName or "Carpentry"  -- Default skill for range calc
        local range = BurdJournals.Client.Debug.getXPRangeForLevel and 
                      BurdJournals.Client.Debug.getXPRangeForLevel(skillName, highlightLevel) or
                      {min = 0, max = 149, maxExtra = 149}
        
        -- Update extra XP entry to show current value
        panel.extraXPEntry:setText(tostring(currentExtraXP))
        
        -- Update range label
        panel.extraXPRange:setName("(0-" .. tostring(range.maxExtra) .. ")")
        
        -- Color coding based on focus state
        if panel.focusedSkill then
            panel.extraXPLabel.r = 1
            panel.extraXPLabel.g = 1
            panel.extraXPLabel.b = 0.6
        else
            panel.extraXPLabel.r = 0.8
            panel.extraXPLabel.g = 0.8
            panel.extraXPLabel.b = 0.8
        end
    end
    
    -- Update button visuals
    for lvl, btn in pairs(panel.levelButtons) do
        if lvl == highlightLevel then
            if panel.focusedSkill then
                -- Focused skill - yellow highlight
                btn.backgroundColor = {r=0.5, g=0.5, b=0.2, a=1}
                btn.borderColor = {r=0.7, g=0.7, b=0.3, a=1}
            else
                -- Default level - green highlight
                btn.backgroundColor = {r=0.3, g=0.5, b=0.4, a=1}
                btn.borderColor = {r=0.4, g=0.7, b=0.5, a=1}
            end
        else
            btn.backgroundColor = {r=0.2, g=0.2, b=0.25, a=1}
            btn.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
        end
    end
end

-- Handle extra XP input change
function BurdJournals.UI.DebugPanel.onExtraXPChange(self)
    local panel = self.spawnPanel
    if not panel or not panel.extraXPEntry then return end
    
    local inputText = panel.extraXPEntry:getText() or "0"
    local extraXP = tonumber(inputText) or 0
    
    -- Get current level to validate against
    local currentLevel = panel.defaultLevel
    local focusedSkillName = nil
    
    if panel.focusedSkill then
        for _, itemData in ipairs(panel.skillList.items) do
            if itemData.item.name == panel.focusedSkill and itemData.item.selected then
                currentLevel = itemData.item.level
                focusedSkillName = itemData.item.name
                break
            end
        end
    end
    
    -- Get valid range
    local skillName = focusedSkillName or "Carpentry"
    local range = BurdJournals.Client.Debug.getXPRangeForLevel and 
                  BurdJournals.Client.Debug.getXPRangeForLevel(skillName, currentLevel) or
                  {min = 0, max = 149, maxExtra = 149}
    
    -- Clamp to valid range
    extraXP = math.max(0, math.min(extraXP, range.maxExtra))
    
    -- Update focused skill's extraXP or default
    if panel.focusedSkill then
        for _, itemData in ipairs(panel.skillList.items) do
            if itemData.item.name == panel.focusedSkill and itemData.item.selected then
                itemData.item.extraXP = extraXP
                panel.selectedSkills[itemData.item.name] = {level = itemData.item.level, extraXP = extraXP}
                break
            end
        end
        self:setStatus("Set " .. panel.focusedSkill .. " extra XP to " .. extraXP, {r=0.5, g=0.8, b=1})
    else
        panel.defaultExtraXP = extraXP
        self:setStatus("Default extra XP set to " .. extraXP, {r=0.6, g=0.7, b=0.8})
    end
    
    self:updateSpawnSummary()
end

-- Clear all selections
function BurdJournals.UI.DebugPanel:onClearSelections()
    local panel = self.spawnPanel
    
    -- Clear skills
    for _, itemData in ipairs(panel.skillList.items) do
        itemData.item.selected = false
        itemData.item.extraXP = 0
    end
    panel.selectedSkills = {}
    panel.focusedSkill = nil
    panel.defaultExtraXP = 0
    
    -- Clear traits
    for _, itemData in ipairs(panel.traitList.items) do
        itemData.item.selected = false
    end
    panel.selectedTraits = {}
    
    self:updateLevelButtons()
    self:updateSpawnSummary()
    self:setStatus("Selections cleared", {r=0.8, g=0.8, b=0.5})
end

-- Update summary text
function BurdJournals.UI.DebugPanel:updateSpawnSummary()
    local panel = self.spawnPanel
    if not panel or not panel.summaryText then
        return
    end
    local parts = {}
    local profile = (panel and panel.spawnProfile == "debug") and "Debug Profile" or "Normal Profile"
    table.insert(parts, profile)

    local journalType = panel.selectedType or "filled"
    if journalType ~= "blank" then
        local selectedOriginMode = normalizeDebugOriginMode(panel.spawnOriginMode)
        local resolvedOriginMode = resolveSpawnOriginMode(panel, journalType)
        local originText = getOriginModeLabel(resolvedOriginMode)
        if selectedOriginMode == "auto" then
            originText = originText .. " (Auto)"
        end
        table.insert(parts, originText)
    end
    
    local skillCount = 0
    for name, level in pairs(panel.selectedSkills) do
        skillCount = skillCount + 1
    end
    if skillCount > 0 then
        table.insert(parts, skillCount .. " skill(s)")
    end
    
    local traitCount = 0
    for name, _ in pairs(panel.selectedTraits) do
        traitCount = traitCount + 1
    end
    if traitCount > 0 then
        table.insert(parts, traitCount .. " trait(s)")
    end
    
    panel.summaryText:setName(table.concat(parts, ", "))
end

function BurdJournals.UI.DebugPanel:updateTypeButtons(panel)
    if not panel or not panel.typeButtons then return end
    for typeName, btn in pairs(panel.typeButtons) do
        if string.lower(typeName) == panel.selectedType then
            btn.backgroundColor = {r=0.3, g=0.5, b=0.4, a=1}
            btn.borderColor = {r=0.4, g=0.8, b=0.5, a=1}
        else
            btn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
            btn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        end
    end
end

function BurdJournals.UI.DebugPanel:onTypeSelect(button)
    local panel = self.spawnPanel
    panel.selectedType = button.internal
    self:applySpawnOwnerDefault(panel, panel.selectedType)
    self:updateTypeButtons(panel)
    self:updateSpawnPanelVisibility()
end

function BurdJournals.UI.DebugPanel:onPresetClick(button)
    local preset = button.internal
    local panel = self.spawnPanel
    
    -- Clear current selections
    for _, itemData in ipairs(panel.skillList.items) do
        itemData.item.selected = false
        itemData.item.extraXP = 0
    end
    panel.selectedSkills = {}
    for _, itemData in ipairs(panel.traitList.items) do
        itemData.item.selected = false
    end
    panel.selectedTraits = {}
    
    if preset == "maxpassive" then
        panel.selectedType = "worn"
        if not isSpawnSkillAllowedForType(panel.selectedType, "Fitness") then
            self:updateTypeButtons(panel)
            self:updateSpawnPanelVisibility()
            self:setStatus("Passive skills are disabled for loot journals in sandbox settings", {r=1, g=0.7, b=0.3})
            return
        end
        -- Select all passive skills (Fitness, Strength, etc.) at level 10
        local passiveSkills = BurdJournals.getPassiveSkills and BurdJournals.getPassiveSkills() or {"Fitness", "Strength"}
        for _, itemData in ipairs(panel.skillList.items) do
            for _, passiveSkill in ipairs(passiveSkills) do
                if (itemData.item.name == passiveSkill or BurdJournals.isPassiveSkill(itemData.item.name))
                    and isSpawnSkillAllowedForType(panel.selectedType, itemData.item.name) then
                    itemData.item.selected = true
                    itemData.item.level = 10
                    itemData.item.extraXP = 0
                    panel.selectedSkills[itemData.item.name] = {level = 10, extraXP = 0}
                    break
                end
            end
        end
    elseif preset == "allpositive" then
        -- Select ALL positive traits from the list (use trait cost to determine polarity)
        -- Build a cost lookup from CharacterTraitDefinition for accurate polarity
        local traitCostLookup = BurdJournals.UI.DebugPanel.buildTraitCostLookup()
        
        -- Select all traits with cost >= 0 (positive or neutral)
        for _, itemData in ipairs(panel.traitList.items) do
            local traitName = itemData.item.name
            local cost = traitCostLookup[traitName:lower()] or 0
            if cost >= 0 then  -- Positive traits have cost > 0, neutral have cost = 0
                itemData.item.selected = true
                panel.selectedTraits[traitName] = true
            end
        end
        panel.selectedType = "bloody"
    elseif preset == "allnegative" then
        -- Select ALL negative traits from the list (use trait cost to determine polarity)
        -- Build a cost lookup from CharacterTraitDefinition for accurate polarity
        local traitCostLookup = BurdJournals.UI.DebugPanel.buildTraitCostLookup()
        
        -- Select all traits with cost < 0 (negative traits)
        for _, itemData in ipairs(panel.traitList.items) do
            local traitName = itemData.item.name
            local cost = traitCostLookup[traitName:lower()] or 0
            if cost < 0 then  -- Negative traits have cost < 0
                itemData.item.selected = true
                panel.selectedTraits[traitName] = true
            end
        end
        panel.selectedType = "bloody"
    end
    
    self:updateTypeButtons(panel)
    self:updateSpawnPanelVisibility()
    self:updateSpawnSummary()
    self:setStatus("Preset loaded: " .. preset, {r=0.5, g=0.8, b=1})
end

function BurdJournals.UI.DebugPanel:onSpawnClick()
    local panel = self.spawnPanel
    local journalType = panel.selectedType
    
    -- Build params from selections
    local params = {
        journalType = journalType,
        skills = {},
        traits = {},
        recipes = {},
        stats = {},
        owner = nil,
        ownerMode = "none",
        forceCurseType = nil,
        forceCurseTraitId = nil,
        forceCurseSkillName = nil,
        cursedUnleashed = false,
        forgetSlot = false,
        spawnProfile = (panel.spawnProfile or "normal"),
        originMode = resolveSpawnOriginMode(panel, journalType),
    }
    
    -- Handle owner/assignment based on journal type
    if journalType ~= "blank" then
        if journalType == "filled" then
            local selectedData = panel.ownerCombo:getOptionData(panel.ownerCombo.selected)
            if selectedData and selectedData.isNone then
                params.ownerMode = "none"
                params.owner = nil
            elseif selectedData and selectedData.isCustom then
                -- Custom name - display only.
                local customName = panel.customNameEntry:getText()
                if customName and customName ~= "" then
                    params.ownerMode = "custom"
                    params.owner = customName
                    params.isCustomOwner = true
                else
                    params.ownerMode = "none"
                    params.owner = nil
                end
            elseif selectedData and selectedData.isPlayer then
                -- Assign to a specific player (true ownership assignment).
                params.ownerMode = "player_assignment"
                params.owner = selectedData.characterName
                params.ownerSteamId = selectedData.steamId
                params.ownerUsername = selectedData.username
                params.ownerCharacterName = selectedData.characterName
                params.assignedPlayer = selectedData.player
                params.isPlayerCreated = true
            else
                params.ownerMode = "none"
                params.owner = nil
            end
        else
            -- Loot journal types always spawn without ownership metadata.
            params.ownerMode = "none"
            params.owner = nil
            params.ownerSteamId = nil
            params.ownerUsername = nil
            params.ownerCharacterName = nil
            params.assignedPlayer = nil
            params.isPlayerCreated = nil
        end

        -- Handle profession selection (for worn/bloody journals)
        if journalType == "worn" or journalType == "bloody" then
            local profSelected = panel.professionCombo.selected or 1
            if profSelected == 1 then
                -- (Random) - let spawn function pick random profession
                params.randomProfession = true
            elseif profSelected == 2 then
                -- (None) - no profession
                params.noProfession = true
            elseif profSelected == 3 then
                -- Custom profession - use the text entry value
                local customProf = panel.customProfEntry:getText()
                if customProf and customProf ~= "" then
                    params.profession = "custom"
                    params.professionName = customProf
                    params.isCustomProfession = true
                    -- No flavor key for custom - user can set flavor text separately
                else
                    -- Fallback to random if custom field is empty
                    params.randomProfession = true
                end
            elseif profSelected >= 4 and BurdJournals.PROFESSIONS then
                -- Specific profession selected (index 4+ maps to PROFESSIONS[index-3])
                local profIndex = profSelected - 3
                local prof = BurdJournals.PROFESSIONS[profIndex]
                if prof then
                    params.profession = prof.id
                    params.professionName = prof.nameKey and getText(prof.nameKey) or prof.name
                    params.professionFlavorKey = prof.flavorKey
                end
            end
        end
        
        -- Handle custom flavor text (for all non-blank journals)
        local flavorText = panel.flavorEntry:getText()
        if flavorText and flavorText ~= "" then
            params.flavorText = flavorText
        end

        -- Spawn metadata
        if panel.ageEntry and panel.ageEntry.getText then
            local ageHours = tonumber(panel.ageEntry:getText() or "0") or 0
            params.ageHours = math.max(0, ageHours)
        end

        if panel.forgetSlotTick and panel.forgetSlotTick.selected then
            params.forgetSlot = panel.forgetSlotTick.selected[1] == true
        end
        if journalType == "cursed" then
            if panel.cursedStateCombo then
                params.cursedUnleashed = (panel.cursedStateCombo.selected == 2)
            end
            if panel.forceCurseCombo and panel.forceCurseCombo.selected and panel.forceCurseCombo.selected > 0 then
                params.forceCurseType = panel.forceCurseCombo:getOptionData(panel.forceCurseCombo.selected)
                    or panel.forceCurseCombo.options[panel.forceCurseCombo.selected]
            end
            if panel.forceCurseTargetCombo and panel.forceCurseTargetCombo.selected and panel.forceCurseTargetCombo.selected > 0 then
                local targetValue = panel.forceCurseTargetCombo:getOptionData(panel.forceCurseTargetCombo.selected)
                if panel.forceCurseTargetType == "trait" then
                    params.forceCurseTraitId = targetValue
                elseif panel.forceCurseTargetType == "skill" then
                    params.forceCurseSkillName = targetValue
                end
            end
        end
    end
    
    -- Add selected skills (only for non-blank journals)
    if journalType ~= "blank" then
        -- Read extra XP directly from the text entry field
        local extraXPFromField = 0
        local extraXPFieldText = ""
        if panel.extraXPEntry and panel.extraXPEntry.getText then
            extraXPFieldText = panel.extraXPEntry:getText() or ""
            extraXPFromField = tonumber(extraXPFieldText) or 0
        end
        
        BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Extra XP field text = '" .. tostring(extraXPFieldText) .. "' -> number = " .. tostring(extraXPFromField))
        BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Focused skill = " .. tostring(panel.focusedSkill))
        
        for skillName, skillData in pairs(panel.selectedSkills) do
            if isSpawnSkillAllowedForType(journalType, skillName) then
                -- skillData is now {level = X, extraXP = Y}
                local level = skillData.level or skillData  -- Backward compat: might be just a number
                local storedExtraXP = skillData.extraXP or 0
                local extraXP = storedExtraXP
                
                BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Skill '" .. skillName .. "' stored extraXP = " .. tostring(storedExtraXP))
                
                -- For the focused skill, use the value directly from the text field
                -- This ensures we capture the latest typed value even if onTextChange didn't fire
                if panel.focusedSkill == skillName then
                    extraXP = extraXPFromField
                    BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Using field value " .. tostring(extraXPFromField) .. " for focused skill")
                end
                
                -- Also get extraXP from the item data directly as a fallback
                for _, itemData in ipairs(panel.skillList.items) do
                    if itemData.item.name == skillName and itemData.item.selected then
                        local itemExtraXP = itemData.item.extraXP or 0
                        BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Item data extraXP = " .. tostring(itemExtraXP))
                        -- If this is the focused skill, use field value; otherwise use stored value
                        if panel.focusedSkill == skillName then
                            extraXP = extraXPFromField
                        elseif itemExtraXP > 0 then
                            extraXP = itemExtraXP
                        end
                        break
                    end
                end
                
                BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Final - skill=" .. skillName .. " level=" .. tostring(level) .. " extraXP=" .. tostring(extraXP))
                table.insert(params.skills, {name = skillName, level = level, extraXP = extraXP})
            else
                BurdJournals.debugPrint("[BurdJournals] DEBUG SPAWN: Skipping disabled passive skill " .. tostring(skillName))
            end
        end
        
        -- Add selected traits
        for traitName, _ in pairs(panel.selectedTraits) do
            table.insert(params.traits, traitName)
        end
    end
    
    BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Spawning " .. journalType .. " journal" ..
          (journalType ~= "blank" and (" with " .. #params.skills .. " skills, " .. #params.traits .. " traits") or ""))
    BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Spawn profile = " .. tostring(params.spawnProfile))
    BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Origin mode = " .. tostring(params.originMode))
    
    if params.ownerSteamId then
        BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Assigned to player: " .. tostring(params.ownerCharacterName) .. " (SteamID: " .. tostring(params.ownerSteamId) .. ")")
    elseif params.ownerMode == "none" then
        BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Journal author set to None")
    elseif params.isCustomOwner then
        BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Custom owner name: " .. tostring(params.owner))
    elseif params.ownerMode == "player_author" then
        BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Lore author set from player: " .. tostring(params.owner))
    end
    
    -- Spawn
    if BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.spawnJournal then
        local success, item = BurdJournals.Client.Debug.spawnJournal(self.player, params)
        if success then
            local ownerInfo = ""
            if params.ownerSteamId then
                ownerInfo = " (assigned to " .. params.ownerCharacterName .. ")"
            elseif params.isCustomOwner then
                ownerInfo = " (author: " .. params.owner .. ")"
            elseif params.ownerMode == "player_author" and params.owner and params.owner ~= "" then
                ownerInfo = " (author: " .. params.owner .. ")"
            end
            local profileSuffix = (params.spawnProfile == "debug") and " [Debug]" or " [Normal]"
            local originSuffix = ""
            if journalType ~= "blank" then
                originSuffix = " [" .. tostring(getOriginModeLabel(params.originMode)) .. "]"
            end
            self:setStatus("Spawned " .. journalType .. " journal!" .. profileSuffix .. originSuffix .. ownerInfo, {r=0.3, g=1, b=0.5})
        else
            self:setStatus("Failed to spawn journal", {r=1, g=0.3, b=0.3})
        end
    else
        self:setStatus("Spawn function not available", {r=1, g=0.5, b=0.3})
    end
end

-- ============================================================================
-- Tab 2: Character Panel (Enhanced with interactive skill/trait management)
-- ============================================================================

function BurdJournals.UI.DebugPanel:createCharacterPanel(startY, height)
    local panel = ISPanel:new(5, startY, self.width - 10, height)
    panel:initialise()
    panel:instantiate()
    panel.backgroundColor = {r=0.12, g=0.12, b=0.15, a=1}
    panel.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    self:addChild(panel)
    self.tabPanels["character"] = panel
    
    local padding = 10
    local y = padding
    local fullWidth = panel.width - padding * 2
    local btnHeight = 24
    
    -- Player selector (for admins to select other players)
    local playerLabel = ISLabel:new(padding, y, 18, "Target Player:", 1, 1, 1, 1, UIFont.Small, true)
    playerLabel:initialise()
    playerLabel:instantiate()
    panel:addChild(playerLabel)
    
    panel.targetPlayerCombo = ISComboBox:new(padding + 90, y - 2, 200, 22, self, BurdJournals.UI.DebugPanel.onCharacterTargetPlayerChange)
    panel.targetPlayerCombo:initialise()
    panel.targetPlayerCombo:instantiate()
    panel.targetPlayerCombo.font = UIFont.Small
    panel:addChild(panel.targetPlayerCombo)
    
    local refreshBtn = ISButton:new(padding + 295, y - 2, 70, 22, "Refresh", self, BurdJournals.UI.DebugPanel.onCharacterRefresh)
    refreshBtn:initialise()
    refreshBtn:instantiate()
    refreshBtn.font = UIFont.Small
    refreshBtn.textColor = {r=1, g=1, b=1, a=1}
    refreshBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    refreshBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(refreshBtn)
    y = y + 28
    
    -- Skills section header with search field
    local skillsLabel = ISLabel:new(padding, y, 18, "Skills (Click squares to set level):", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    skillsLabel:initialise()
    skillsLabel:instantiate()
    panel:addChild(skillsLabel)
    
    -- Skill search field
    panel.skillSearchEntry = ISTextEntryBox:new("", padding + 200, y - 2, 150, 20)
    panel.skillSearchEntry:initialise()
    panel.skillSearchEntry:instantiate()
    panel.skillSearchEntry.font = UIFont.Small
    panel.skillSearchEntry:setTooltip("Type to filter skills...")
    panel.skillSearchEntry.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterCharacterSkillList(self)
    end
    panel:addChild(panel.skillSearchEntry)
    y = y + 22
    
    -- Skill list (scrollable) with interactive level visualizers
    local skillListHeight = 140
    panel.charSkillList = ISScrollingListBox:new(padding, y, fullWidth, skillListHeight)
    panel.charSkillList:initialise()
    panel.charSkillList:instantiate()
    panel.charSkillList.itemheight = 24
    panel.charSkillList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.charSkillList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.charSkillList.doDrawItem = BurdJournals.UI.DebugPanel.drawCharacterSkillItem
    panel.charSkillList.onMouseDown = BurdJournals.UI.DebugPanel.onCharacterSkillListClick
    panel.charSkillList.parentPanel = self
    panel:addChild(panel.charSkillList)
    y = y + skillListHeight + 5
    
    -- XP input row for focused skill
    panel.focusedSkill = nil  -- Track which skill is selected for XP addition
    
    panel.xpLabel = ISLabel:new(padding, y, 18, "Add XP:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.xpLabel:initialise()
    panel.xpLabel:instantiate()
    panel:addChild(panel.xpLabel)
    
    panel.xpEntry = ISTextEntryBox:new("100", padding + 50, y - 2, 60, 20)
    panel.xpEntry:initialise()
    panel.xpEntry:instantiate()
    panel.xpEntry.font = UIFont.Small
    panel.xpEntry:setOnlyNumbers(true)
    panel.xpEntry.backgroundColor = {r=0.15, g=0.15, b=0.18, a=1}
    panel.xpEntry.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel:addChild(panel.xpEntry)
    
    panel.xpSkillLabel = ISLabel:new(padding + 115, y, 18, "Click skill row to select", 0.5, 0.6, 0.7, 1, UIFont.Small, true)
    panel.xpSkillLabel:initialise()
    panel.xpSkillLabel:instantiate()
    panel:addChild(panel.xpSkillLabel)
    
    local addXpBtn = ISButton:new(fullWidth - 50, y - 2, 60, 20, "+Add", self, BurdJournals.UI.DebugPanel.onCharacterAddXP)
    addXpBtn:initialise()
    addXpBtn:instantiate()
    addXpBtn.font = UIFont.Small
    addXpBtn.textColor = {r=1, g=1, b=1, a=1}
    addXpBtn.borderColor = {r=0.3, g=0.5, b=0.4, a=1}
    addXpBtn.backgroundColor = {r=0.2, g=0.3, b=0.25, a=1}
    panel:addChild(addXpBtn)
    panel.addXpBtn = addXpBtn
    y = y + 25
    
    -- Traits section header with search field
    local traitsLabel = ISLabel:new(padding, y, 18, "Traits (Add/Remove):", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    traitsLabel:initialise()
    traitsLabel:instantiate()
    panel:addChild(traitsLabel)
    
    -- Trait search field
    panel.traitSearchEntry = ISTextEntryBox:new("", padding + 140, y - 2, 150, 20)
    panel.traitSearchEntry:initialise()
    panel.traitSearchEntry:instantiate()
    panel.traitSearchEntry.font = UIFont.Small
    panel.traitSearchEntry:setTooltip("Type to filter traits...")
    panel.traitSearchEntry.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterCharacterTraitList(self)
    end
    panel:addChild(panel.traitSearchEntry)
    y = y + 22
    
    -- Trait list (scrollable) with Add/Remove buttons
    local traitListHeight = 110
    panel.charTraitList = ISScrollingListBox:new(padding, y, fullWidth, traitListHeight)
    panel.charTraitList:initialise()
    panel.charTraitList:instantiate()
    panel.charTraitList.itemheight = 24
    panel.charTraitList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.charTraitList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.charTraitList.doDrawItem = BurdJournals.UI.DebugPanel.drawCharacterTraitItem
    panel.charTraitList.onMouseDown = BurdJournals.UI.DebugPanel.onCharacterTraitListClick
    panel.charTraitList.parentPanel = self
    panel:addChild(panel.charTraitList)
    y = y + traitListHeight + 10
    
    -- Action buttons row 1
    local btnWidth = 100
    local btnSpacing = 6
    local btnX = padding
    
    local allMaxBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "All Skills Max", self, BurdJournals.UI.DebugPanel.onCharCmd)
    allMaxBtn:initialise()
    allMaxBtn:instantiate()
    allMaxBtn.font = UIFont.Small
    allMaxBtn.internal = "setallmax"
    allMaxBtn.textColor = {r=1, g=1, b=1, a=1}
    allMaxBtn.borderColor = {r=0.3, g=0.6, b=0.3, a=1}
    allMaxBtn.backgroundColor = {r=0.15, g=0.3, b=0.15, a=1}
    panel:addChild(allMaxBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local allZeroBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "All Skills Zero", self, BurdJournals.UI.DebugPanel.onCharCmd)
    allZeroBtn:initialise()
    allZeroBtn:instantiate()
    allZeroBtn.font = UIFont.Small
    allZeroBtn.internal = "setallzero"
    allZeroBtn.textColor = {r=1, g=1, b=1, a=1}
    allZeroBtn.borderColor = {r=0.6, g=0.4, b=0.3, a=1}
    allZeroBtn.backgroundColor = {r=0.35, g=0.2, b=0.15, a=1}
    panel:addChild(allZeroBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local removeAllTraitsBtn = ISButton:new(btnX, y, btnWidth + 20, btnHeight, "Remove All Traits", self, BurdJournals.UI.DebugPanel.onCharCmd)
    removeAllTraitsBtn:initialise()
    removeAllTraitsBtn:instantiate()
    removeAllTraitsBtn.font = UIFont.Small
    removeAllTraitsBtn.internal = "removealltraits"
    removeAllTraitsBtn.textColor = {r=1, g=1, b=1, a=1}
    removeAllTraitsBtn.borderColor = {r=0.6, g=0.3, b=0.3, a=1}
    removeAllTraitsBtn.backgroundColor = {r=0.4, g=0.15, b=0.15, a=1}
    panel:addChild(removeAllTraitsBtn)
    y = y + btnHeight + 5
    
    -- Action buttons row 2
    btnX = padding
    
    local dumpSkillsBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Dump Skills", self, BurdJournals.UI.DebugPanel.onCharCmd)
    dumpSkillsBtn:initialise()
    dumpSkillsBtn:instantiate()
    dumpSkillsBtn.font = UIFont.Small
    dumpSkillsBtn.internal = "dumpskills"
    dumpSkillsBtn.textColor = {r=1, g=1, b=1, a=1}
    dumpSkillsBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    dumpSkillsBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(dumpSkillsBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local dumpTraitsBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Dump Traits", self, BurdJournals.UI.DebugPanel.onCharCmd)
    dumpTraitsBtn:initialise()
    dumpTraitsBtn:instantiate()
    dumpTraitsBtn.font = UIFont.Small
    dumpTraitsBtn.internal = "dumptraits"
    dumpTraitsBtn.textColor = {r=1, g=1, b=1, a=1}
    dumpTraitsBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    dumpTraitsBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(dumpTraitsBtn)
    
    -- Store reference
    self.charPanel = panel
    panel.targetPlayer = self.player  -- Default to current player
    
    -- Initial population
    self:populateCharacterPlayerList()
    self:refreshCharacterData()
end

-- Populate player dropdown with online players
function BurdJournals.UI.DebugPanel:populateCharacterPlayerList()
    local panel = self.charPanel
    if not panel or not panel.targetPlayerCombo then return end
    
    panel.targetPlayerCombo:clear()
    
    -- Add current player first (use addOptionWithData to store player reference)
    local currentName = self.player and self.player:getUsername() or "You"
    panel.targetPlayerCombo:addOptionWithData(currentName, self.player)
    
    -- In multiplayer, only admins can target other online players.
    if self:canTargetOtherPlayers() then
        local onlinePlayers = getOnlinePlayers()
        if onlinePlayers then
            for i = 0, onlinePlayers:size() - 1 do
                local p = onlinePlayers:get(i)
                if p and p ~= self.player then
                    local name = p:getUsername() or ("Player " .. i)
                    panel.targetPlayerCombo:addOptionWithData(name, p)
                end
            end
        end
    end
    
    panel.targetPlayerCombo:select(currentName)
    panel.targetPlayer = self.player
end

-- Handle player selection change
function BurdJournals.UI.DebugPanel:onCharacterTargetPlayerChange(combo)
    local panel = self.charPanel
    if not panel then return end
    
    local selected = combo:getSelectedIndex()
    local data = combo.options[selected + 1]
    if data and data.data then
        if data.data ~= self.player and not self:canTargetOtherPlayers() then
            local currentName = self.player and self.player:getUsername() or "You"
            combo:select(currentName)
            panel.targetPlayer = self.player
            self:setStatus(getText("UI_BurdJournals_AdminOnly") or "This command requires admin access.", {r=1, g=0.6, b=0.3})
            return
        end
        panel.targetPlayer = data.data
        self:refreshCharacterData()
        self:setStatus("Viewing: " .. (panel.targetPlayer:getUsername() or "Unknown"), {r=0.5, g=0.8, b=1})
    end
end

-- Refresh button handler
function BurdJournals.UI.DebugPanel:onCharacterRefresh()
    self:populateCharacterPlayerList()
    self:refreshCharacterData()
    self:setStatus("Character data refreshed", {r=0.5, g=0.8, b=1})
end

-- Refresh character skill/trait data
function BurdJournals.UI.DebugPanel:refreshCharacterData()
    local panel = self.charPanel
    if not panel then return end
    
    local targetPlayer = panel.targetPlayer or self.player
    if not targetPlayer then 
        -- No player yet, skip population
        return 
    end

    -- Clear existing lists safely
    if panel.charSkillList and panel.charSkillList.clear then 
        panel.charSkillList:clear()
    end
    if panel.charTraitList and panel.charTraitList.clear then 
        panel.charTraitList:clear()
    end
    
    -- Populate skills using dynamic discovery
    local skillMetadata = {}
    if BurdJournals.discoverSkillMetadata then
        skillMetadata = BurdJournals.discoverSkillMetadata(true) or {}
    end
    
    -- Get player's XP object safely
    local xpObj = nil
    if targetPlayer and targetPlayer.getXp then
        xpObj = targetPlayer:getXp()
    end
    
    -- If we still don't have xpObj, try refreshing targetPlayer reference
    if not xpObj and targetPlayer and targetPlayer.getUsername then
        -- Re-fetch player reference (in case it went stale)
        local username = targetPlayer:getUsername()
        if username then
            local onlinePlayers = getOnlinePlayers and getOnlinePlayers()
            if onlinePlayers then
                for i = 0, onlinePlayers:size() - 1 do
                    local p = onlinePlayers:get(i)
                    if p and p.getUsername and p:getUsername() == username then
                        targetPlayer = p
                        if p.getXp then
                            xpObj = p:getXp()
                        end
                        break
                    end
                end
            end
        end
    end
    
    -- Sort skills by category then name
    local sortedSkills = {}
    for skillName, metadata in pairs(skillMetadata) do
        table.insert(sortedSkills, {
            name = skillName,
            displayName = metadata.displayName or skillName,
            category = metadata.category or "Other",
            isVanilla = metadata.isVanilla,
            isPassive = metadata.isPassive,
            perkId = metadata.id
        })
    end
    table.sort(sortedSkills, function(a, b)
        if a.category ~= b.category then
            return a.category < b.category
        end
        return a.displayName < b.displayName
    end)
    
    -- Add skills to list
    for _, skill in ipairs(sortedSkills) do
        local level = 0
        local currentXP = 0
        
        -- Get perk object
        local perk = nil
        if BurdJournals.getPerkByName then
            perk = BurdJournals.getPerkByName(skill.name)
        end
        
        -- Fallback: try Perks directly
        if not perk and Perks then
            local perkId = skill.perkId or skill.name
            if Perks[perkId] then perk = Perks[perkId] end
        end
        
        if perk and targetPlayer then
            -- Method 1: getPerkLevel (most reliable)
            if targetPlayer.getPerkLevel then
                local result = targetPlayer:getPerkLevel(perk)
                if type(result) == "number" then
                    level = result
                end
            end
            
            -- Method 2: Get XP and calculate level (fallback)
            if level == 0 and xpObj and xpObj.getXP then
                local xp = xpObj:getXP(perk)
                if type(xp) == "number" and xp > 0 then
                    currentXP = xp
                    -- Calculate level from XP using corrected helper
                    if BurdJournals.Client.Debug.getLevelFromXP then
                        level = BurdJournals.Client.Debug.getLevelFromXP(skill.name, xp)
                    elseif perk.getTotalXpForLevel then
                        -- Fallback: getTotalXpForLevel(N) = XP to COMPLETE level N
                        -- So level N requires XP >= getTotalXpForLevel(N-1)
                        for l = 10, 1, -1 do
                            local threshold = perk:getTotalXpForLevel(l - 1) or 0
                            if xp >= threshold then
                                level = l
                                break
                            end
                        end
                    end
                end
            end
            
            -- Get current XP if we didn't already
            if currentXP == 0 and xpObj and xpObj.getXP then
                local xp = xpObj:getXP(perk)
                if type(xp) == "number" then
                    currentXP = xp
                end
            end
        end
        
        local prefix = skill.isVanilla == false and "[MOD] " or ""
        local itemText = prefix .. skill.displayName
        
        if panel.charSkillList then
            panel.charSkillList:addItem(itemText, {
                name = skill.name,
                displayName = skill.displayName,
                category = skill.category,
                level = level,
                currentXP = currentXP,
                isPassive = skill.isPassive,
                isVanilla = skill.isVanilla
            })
        end
    end
    
    -- Populate traits using the comprehensive discovery (same as Spawn panel)
    local allTraits = {}
    local addedTraits = {}  -- For deduplication
    
    -- Use discoverGrantableTraits (includes negative traits for debug panel)
    -- This discovers ALL traits including modded ones and neutral/profession traits
    local discoveredTraits = {}
    if BurdJournals and BurdJournals.discoverGrantableTraits then
        local result = BurdJournals.discoverGrantableTraits(true)  -- true = include negative
        if result and type(result) == "table" then
            discoveredTraits = result
        end
    end
    
    -- Fallback to older methods if discovery failed
    if #discoveredTraits == 0 then
        local positiveTraits = BurdJournals.getPositiveTraits and BurdJournals.getPositiveTraits() or {}
        local negativeTraits = BurdJournals.getNegativeTraits and BurdJournals.getNegativeTraits() or {}
        for _, t in ipairs(positiveTraits) do table.insert(discoveredTraits, t) end
        for _, t in ipairs(negativeTraits) do table.insert(discoveredTraits, t) end
    end
    
    -- Determine trait polarity from CharacterTraitDefinition
    -- Also deduplicate by display name to handle B42 trait variants
    local addedDisplayNames = {}  -- Track display names to prevent visual duplicates
    for _, traitId in ipairs(discoveredTraits) do
        local lowerTraitId = string.lower(traitId)
        if not addedTraits[lowerTraitId] then
            -- Get display name first to check for duplicates
            local displayName = traitId
            if BurdJournals.getTraitDisplayName then
                displayName = BurdJournals.getTraitDisplayName(traitId) or traitId
            end
            local displayNameLower = string.lower(displayName)
            
            -- Skip if we already have a trait with this display name (B42 variant handling)
            if not addedDisplayNames[displayNameLower] then
                addedTraits[lowerTraitId] = true
                addedDisplayNames[displayNameLower] = traitId
                
                -- Determine if positive or negative by cost
                local isPositive = true  -- Default to positive
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
                                if defTraitId and string.lower(defTraitId) == lowerTraitId then
                                    local cost = def.getCost and def:getCost() or 0
                                    isPositive = cost >= 0  -- positive or neutral
                                    break
                                end
                            end
                        end
                    end
                end
                
                table.insert(allTraits, {id = traitId, isPositive = isPositive})
            end
        end
    end
    
    -- Sort traits alphabetically
    table.sort(allTraits, function(a, b)
        return a.id < b.id
    end)
    
    -- Count how many times player has each trait
    -- Use multiple detection methods for reliability
    local playerTraitCounts = {}
    
    if targetPlayer then
        -- Method 1: player:getTraits() - runtime trait list (may have duplicates from debug)
        if targetPlayer.getTraits then
            local playerTraits = targetPlayer:getTraits()
            if playerTraits and playerTraits.size then
                for i = 0, playerTraits:size() - 1 do
                    local traitId = playerTraits:get(i)
                    if traitId then
                        local lower = string.lower(tostring(traitId))
                        playerTraitCounts[lower] = (playerTraitCounts[lower] or 0) + 1
                        playerTraitCounts[traitId] = (playerTraitCounts[traitId] or 0) + 1
                    end
                end
            end
        end
    end
    
    -- Store reference to target player for HasTrait checks below
    local traitCheckPlayer = targetPlayer
    
    -- Add traits to list
    for _, trait in ipairs(allTraits) do
        local displayName = trait.id
        if BurdJournals.getTraitDisplayName then
            displayName = BurdJournals.getTraitDisplayName(trait.id) or trait.id
        end
        
        -- Check if player has this trait (and how many)
        local count = playerTraitCounts[string.lower(trait.id)] or playerTraitCounts[trait.id] or 0
        
        -- Fallback: use the comprehensive BurdJournals.playerHasTrait function
        -- This properly checks hasTrait with trait object, HasTrait with string, etc.
        if count == 0 and traitCheckPlayer and BurdJournals.playerHasTrait then
            if BurdJournals.playerHasTrait(traitCheckPlayer, trait.id) then
                count = 1
            end
        end
        
        if panel.charTraitList then
            panel.charTraitList:addItem(displayName, {
                id = trait.id,
                displayName = displayName,
                isPositive = trait.isPositive,
                hasCount = count,
                isPassiveSkillTrait = BurdJournals.isPassiveSkillTrait and BurdJournals.isPassiveSkillTrait(trait.id)
            })
        end
    end
end

-- Draw function for character skill items with interactive level visualizer
function BurdJournals.UI.DebugPanel.drawCharacterSkillItem(self, y, item, alt)
    -- Safety checks for required values
    local h = self.itemheight or 24
    
    -- CRITICAL: Must always return y + h for ISScrollingListBox
    if not item or not item.item then return y + h end
    local data = item.item
    if not data then return y + h end
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    -- Ensure we have valid dimensions
    local w = self.width or 300
    
    -- Check if this skill is selected for XP addition
    local parentPanel = self.parentPanel
    local charPanel = parentPanel and parentPanel.charPanel
    local isSelected = charPanel and charPanel.focusedSkill == data.name
    
    -- Background - highlight if selected
    if isSelected then
        self:drawRect(0, y, w, h, 0.3, 0.2, 0.4, 0.3)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, w, h, 0.2, 0.2, 0.3, 0.3)
    elseif data.isPassive then
        self:drawRect(0, y, w, h, 0.1, 0.15, 0.2, 0.2)
    end
    
    -- Skill name (with category in dim text)
    local nameX = 8
    local nameColor = data.isVanilla == false and {0.6, 0.8, 1} or {1, 1, 1}
    if isSelected then nameColor = {1, 1, 0.6} end  -- Yellow when selected
    self:drawText(data.displayName, nameX, y + 4, nameColor[1], nameColor[2], nameColor[3], 1, UIFont.Small)
    
    -- Level text
    local levelText = string.format(getText("UI_BurdJournals_LevelFormat"), tonumber(data.level) or 0)
    local levelX = 140
    self:drawText(levelText, levelX, y + 4, 0.8, 0.8, 0.5, 1, UIFont.Small)
    
    -- Interactive level squares (0-10) with progress visualization
    local squaresX = 185
    local squareSize = 12
    local squareSpacing = 2
    local currentLevel = data.level or 0
    local currentXP = data.currentXP or 0
    
    -- Calculate progress within current level (0-1)
    local progress = 0
    if currentLevel < 10 then
        local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(data.name)
        if perk and perk.getTotalXpForLevel then
            -- XP needed to BE at current level (threshold for current level)
            local levelStartXP = currentLevel > 0 and (perk:getTotalXpForLevel(currentLevel - 1) or 0) or 0
            -- XP needed to reach next level
            local levelEndXP = perk:getTotalXpForLevel(currentLevel) or (levelStartXP + 150)
            local xpRange = levelEndXP - levelStartXP
            if xpRange > 0 then
                progress = math.max(0, math.min(1, (currentXP - levelStartXP) / xpRange))
            end
        end
    end
    
    for i = 1, 10 do
        local sqX = squaresX + (i - 1) * (squareSize + squareSpacing)
        local sqY = y + (h - squareSize) / 2
        
        if i <= currentLevel then
            -- Filled square (has this level)
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.9, 0.4, 0.7, 0.4)
        elseif i == currentLevel + 1 and progress > 0 then
            -- Partial progress square - show fill from bottom
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.6, 0.15, 0.15, 0.2)
            local fillHeight = squareSize * progress
            self:drawRect(sqX, sqY + squareSize - fillHeight, squareSize, fillHeight, 0.8, 0.3, 0.5, 0.35)
        else
            -- Empty square
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.15, 0.15, 0.2)
        end
        -- Border
        self:drawRectBorder(sqX, sqY, squareSize, squareSize, 0.8, 0.4, 0.5, 0.6)
    end
    
    -- XP display (simple text after squares)
    local squaresEndX = squaresX + 10 * (squareSize + squareSpacing)
    local xpDisplayX = squaresEndX + 8
    local currentXP = data.currentXP or 0
    
    -- Format XP display
    local xpText = tostring(math.floor(currentXP)) .. " XP"
    local xpColor = isSelected and {1, 1, 0.6} or {0.6, 0.8, 0.6}
    self:drawText(xpText, xpDisplayX, y + 4, xpColor[1], xpColor[2], xpColor[3], 1, UIFont.Small)
    
    -- Passive indicator (moved to accommodate XP display, account for scrollbar)
    if data.isPassive then
        local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH
        self:drawText("[P]", w - 25 - scrollOffset, y + 4, 0.5, 0.7, 0.9, 0.7, UIFont.Small)
    end
    
    -- CRITICAL: Must return y + h for ISScrollingListBox
    return y + h
end

-- Click handler for character skill list (set skill level)
function BurdJournals.UI.DebugPanel.onCharacterSkillListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    
    -- Safety checks
    if not self.items then return end
    local row = self:rowAt(x, y)
    if not row or row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    if not item or not item.item then return end
    local data = item.item
    if not data then return end
    
    local parentPanel = self.parentPanel
    if not parentPanel then return end
    local charPanel = parentPanel.charPanel
    local targetPlayer = charPanel and charPanel.targetPlayer or parentPanel.player
    if not targetPlayer then return end
    
    -- Check if click is in the squares area
    local squaresX = 185
    local squareSize = 12
    local squareSpacing = 2
    local squaresEndX = squaresX + 10 * (squareSize + squareSpacing)
    
    if x >= squaresX and x <= squaresEndX then
        -- Calculate which level was clicked
        local relX = x - squaresX
        local clickedLevel = math.floor(relX / (squareSize + squareSpacing)) + 1
        clickedLevel = math.max(0, math.min(10, clickedLevel))
        
        -- If clicking on current level, set to 0 (toggle off)
        if clickedLevel == data.level then
            clickedLevel = 0
        end
        
        -- Set the skill level - update UI immediately (optimistic)
        data.level = clickedLevel
        parentPanel:setStatus("Set " .. data.displayName .. " to level " .. clickedLevel, {r=0.3, g=1, b=0.5})
        
        if isClient() and not isServer() then
            -- Multiplayer: send to server
            sendClientCommand("BurdJournals", "debugSetSkill", {
                skillName = data.name,
                level = clickedLevel,
                targetUsername = targetPlayer:getUsername()
            })
        else
            -- Singleplayer: apply directly
            local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(data.name)
            if perk and targetPlayer then
                local perkName = tostring(perk)
                local isPassive = (perkName == "Fitness" or perkName == "Strength")
                
                -- For passive skills, remove existing passive traits FIRST
                -- This prevents the trait system from bouncing the skill back
                if isPassive then
                    BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, perkName)
                end
                
                if isPassive then
                    -- For passive skills, use setPerkLevelDebug which directly sets level
                    -- This bypasses XP scaling issues that affect Strength specifically
                    targetPlayer:setPerkLevelDebug(perk, clickedLevel)
                else
                    -- For non-passive skills, use XP-based approach
                    local xpObj = targetPlayer:getXp()
                    if xpObj then
                        local currentXP = xpObj:getXP(perk)
                        local targetXP = 0
                        
                        if clickedLevel > 0 then
                            targetXP = perk:getTotalXpForLevel(clickedLevel)
                        end
                        
                        local xpDiff = targetXP - currentXP
                        if xpDiff ~= 0 then
                            xpObj:AddXP(perk, xpDiff, false, false, false, true)
                        end
                    end
                end
            end
        end
    end
    
    -- Always select this skill for XP addition (clicking anywhere on the row)
    charPanel.focusedSkill = data.name
    BurdJournals.UI.DebugPanel.updateCharacterXPLabel(parentPanel)
end

-- Update skill name label when a skill is selected
function BurdJournals.UI.DebugPanel.updateCharacterXPLabel(self)
    local panel = self.charPanel
    if not panel then return end
    
    local focusedSkillName = panel.focusedSkill
    local focusedData = nil
    
    -- Find the focused skill data
    if focusedSkillName and panel.charSkillList then
        for _, itemData in ipairs(panel.charSkillList.items) do
            if itemData.item and itemData.item.name == focusedSkillName then
                focusedData = itemData.item
                break
            end
        end
    end
    
    if focusedData then
        -- Update skill name label to show selected skill
        if panel.xpSkillLabel then
            panel.xpSkillLabel:setName(focusedData.displayName .. " (" .. math.floor(focusedData.currentXP or 0) .. " XP)")
            panel.xpSkillLabel.r = 1
            panel.xpSkillLabel.g = 1
            panel.xpSkillLabel.b = 0.6
        end
    else
        -- No skill focused
        if panel.xpSkillLabel then
            panel.xpSkillLabel:setName("Click skill row to select")
            panel.xpSkillLabel.r = 0.5
            panel.xpSkillLabel.g = 0.6
            panel.xpSkillLabel.b = 0.7
        end
    end
end

-- Add XP to focused skill (simple addition to current XP)
function BurdJournals.UI.DebugPanel:onCharacterAddXP()
    local panel = self.charPanel
    if not panel then return end
    
    local focusedSkillName = panel.focusedSkill
    if not focusedSkillName then
        self:setStatus("No skill selected - click a skill row first", {r=1, g=0.5, b=0.5})
        return
    end
    
    local targetPlayer = panel.targetPlayer or self.player
    if not targetPlayer then return end
    
    -- Get XP amount to add from input
    local xpText = panel.xpEntry and panel.xpEntry:getText() or "0"
    local xpToAdd = tonumber(xpText) or 0
    xpToAdd = math.max(0, math.floor(xpToAdd))
    
    if xpToAdd <= 0 then
        self:setStatus("Enter a positive XP amount to add", {r=1, g=0.5, b=0.5})
        return
    end
    
    -- Find the focused skill data to update
    local focusedData = nil
    if panel.charSkillList then
        for _, itemData in ipairs(panel.charSkillList.items) do
            if itemData.item and itemData.item.name == focusedSkillName then
                focusedData = itemData.item
                break
            end
        end
    end
    
    if not focusedData then
        self:setStatus("Skill not found: " .. focusedSkillName, {r=1, g=0.5, b=0.5})
        return
    end
    
    -- Calculate new XP total
    local currentXP = focusedData.currentXP or 0
    local newXP = currentXP + xpToAdd
    
    -- Update local data optimistically
    focusedData.currentXP = newXP
    
    -- Get perk for level calculation and game API
    local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(focusedSkillName)
    
    self:setStatus("Added " .. xpToAdd .. " XP to " .. focusedData.displayName .. " (now " .. math.floor(newXP) .. " XP)", {r=0.3, g=1, b=0.5})
    
    -- Apply to game
    if isClient() and not isServer() then
        -- Multiplayer: send to server to add XP
        sendClientCommand("BurdJournals", "debugAddSkillXP", {
            skillName = focusedSkillName,
            xpToAdd = xpToAdd,
            targetUsername = targetPlayer:getUsername()
        })
    else
        -- Singleplayer: apply directly using AddXP
        if perk and targetPlayer then
            local xpObj = targetPlayer:getXp()
            if xpObj then
                -- AddXP adds the specified amount directly for all skills
                xpObj:AddXP(perk, xpToAdd, false, false, false, true)
            end
        end
    end
    
    -- Schedule a UI refresh after a short delay to show updated values
    local selfRef = self
    local skillName = focusedSkillName
    if Events and Events.OnTick then
        local tickCount = 0
        local refreshHandler = nil
        refreshHandler = function()
            tickCount = tickCount + 1
            if tickCount >= 10 then  -- ~166ms delay at 60 FPS
                Events.OnTick.Remove(refreshHandler)
                if selfRef and selfRef.refreshCharacterData then
                    selfRef:refreshCharacterData()
                    -- Re-select the skill and update label
                    if selfRef.charPanel then
                        selfRef.charPanel.focusedSkill = skillName
                        BurdJournals.UI.DebugPanel.updateCharacterXPLabel(selfRef)
                    end
                end
            end
        end
        Events.OnTick.Add(refreshHandler)
    end
end

-- Draw function for character trait items with Add/Remove buttons
function BurdJournals.UI.DebugPanel.drawCharacterTraitItem(self, y, item, alt)
    -- Safety checks for required values
    local h = self.itemheight or 24
    
    -- CRITICAL: Must always return y + h for ISScrollingListBox
    if not item or not item.item then return y + h end
    local data = item.item
    if not data then return y + h end
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    -- Ensure we have valid dimensions
    local w = self.width or 300
    
    -- Ensure hasCount is a number
    data.hasCount = data.hasCount or 0
    
    -- Background based on trait type and ownership
    if data.isPassiveSkillTrait then
        self:drawRect(0, y, w, h, 0.15, 0.15, 0.15, 0.15)
    elseif data.hasCount > 0 then
        self:drawRect(0, y, w, h, 0.12, 0.2, 0.12, 0.3)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, w, h, 0.2, 0.2, 0.3, 0.3)
    end
    
    local textX = 8
    
    -- [HAS] indicator with count if duplicates
    if data.hasCount > 0 then
        local hasText = "[HAS]"
        if data.hasCount > 1 then
            hasText = "[x" .. data.hasCount .. "]"
        end
        self:drawText(hasText, textX, y + 4, 0.4, 0.8, 0.4, 1, UIFont.Small)
        textX = textX + 40
    else
        textX = textX + 40  -- Keep alignment
    end
    
    -- Trait name
    local nameColor = data.isPositive and {0.5, 0.8, 0.5} or {0.8, 0.5, 0.5}
    if data.isPassiveSkillTrait then
        nameColor = {0.5, 0.5, 0.5}
    end
    self:drawText(data.displayName, textX, y + 4, nameColor[1], nameColor[2], nameColor[3], 1, UIFont.Small)
    
    -- Buttons (right side, account for scrollbar)
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH
    if not data.isPassiveSkillTrait then
        local btnWidth = 45
        local btnHeight = 18
        local btnY = y + (h - btnHeight) / 2
        
        -- [+Add] button
        local addBtnX = w - btnWidth * 2 - 12 - scrollOffset
        self:drawRect(addBtnX, btnY, btnWidth, btnHeight, 1, 0.15, 0.3, 0.15)
        self:drawRectBorder(addBtnX, btnY, btnWidth, btnHeight, 0.8, 0.3, 0.5, 0.3)
        self:drawTextCentre("+Add", addBtnX + btnWidth / 2, btnY + 2, 0.5, 1, 0.5, 1, UIFont.Small)
        
        -- [-Remove] button
        local removeBtnX = w - btnWidth - 6 - scrollOffset
        self:drawRect(removeBtnX, btnY, btnWidth, btnHeight, 1, 0.3, 0.15, 0.15)
        self:drawRectBorder(removeBtnX, btnY, btnWidth, btnHeight, 0.8, 0.5, 0.3, 0.3)
        self:drawTextCentre("-Rem", removeBtnX + btnWidth / 2, btnY + 2, 1, 0.5, 0.5, 1, UIFont.Small)
    else
        -- Show passive skill trait indicator
        self:drawText("[Passive]", w - 60 - scrollOffset, y + 4, 0.4, 0.4, 0.4, 0.7, UIFont.Small)
    end
    
    -- CRITICAL: Must return y + h for ISScrollingListBox
    return y + h
end

-- Click handler for character trait list (Add/Remove buttons)
function BurdJournals.UI.DebugPanel.onCharacterTraitListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    
    -- Safety checks
    if not self.items then return end
    local row = self:rowAt(x, y)
    if not row or row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    if not item or not item.item then return end
    local data = item.item
    if not data then return end
    
    local parentPanel = self.parentPanel
    if not parentPanel then return end
    local charPanel = parentPanel.charPanel
    local targetPlayer = charPanel and charPanel.targetPlayer or parentPanel.player
    if not targetPlayer then return end
    
    -- Don't allow modifying passive skill traits
    if data.isPassiveSkillTrait then
        parentPanel:setStatus("Passive skill traits cannot be modified", {r=1, g=0.6, b=0.3})
        return
    end
    
    -- Check button click areas (account for scrollbar offset)
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH
    local btnWidth = 45
    local addBtnX = self.width - btnWidth * 2 - 12 - scrollOffset
    local removeBtnX = self.width - btnWidth - 6 - scrollOffset
    
    if x >= addBtnX and x < addBtnX + btnWidth then
        -- Add button clicked - update UI immediately (optimistic)
        data.hasCount = (data.hasCount or 0) + 1
        parentPanel:setStatus("Added trait: " .. data.displayName, {r=0.3, g=1, b=0.5})
        
        if isClient() and not isServer() then
            -- Multiplayer: send to server
            sendClientCommand("BurdJournals", "debugAddTrait", {
                traitId = data.id,
                targetUsername = targetPlayer:getUsername()
            })
        else
            -- Singleplayer: apply directly
            if BurdJournals.safeAddTrait then
                BurdJournals.safeAddTrait(targetPlayer, data.id)
            end
        end
        
    elseif x >= removeBtnX and x < removeBtnX + btnWidth then
        -- Remove button clicked (removes ALL instances)
        if data.hasCount <= 0 then
            parentPanel:setStatus("Player doesn't have: " .. data.displayName, {r=1, g=0.6, b=0.3})
            return
        end
        
        -- Update UI immediately (optimistic)
        data.hasCount = 0
        parentPanel:setStatus("Removed: " .. data.displayName, {r=0.3, g=1, b=0.5})
        
        if isClient() and not isServer() then
            -- Multiplayer: send to server
            sendClientCommand("BurdJournals", "debugRemoveTrait", {
                traitId = data.id,
                removeAll = true,
                targetUsername = targetPlayer:getUsername()
            })
        else
            -- Singleplayer: remove all instances using safeRemoveTrait if available
            if BurdJournals.safeRemoveTrait then
                BurdJournals.safeRemoveTrait(targetPlayer, data.id)
            elseif targetPlayer and targetPlayer.getTraits then
                local traits = targetPlayer:getTraits()
                if traits and traits.size then
                    local toRemove = {}
                    for i = 0, traits:size() - 1 do
                        local t = traits:get(i)
                        if t then
                            local tNorm = BurdJournals.UI.DebugPanel.normalizeTraitId(t) or t
                            local idNorm = BurdJournals.UI.DebugPanel.normalizeTraitId(data.id) or data.id
                            if (BurdJournals.traitIdsMatch and BurdJournals.traitIdsMatch(tNorm, idNorm))
                                or string.lower(tostring(tNorm)) == string.lower(tostring(idNorm)) then
                                table.insert(toRemove, t)
                            end
                        end
                    end
                    for _, t in ipairs(toRemove) do
                        if traits.remove then
                            traits:remove(t)
                        end
                    end
                end
            end
        end
    end
end

-- Filter skill list based on search text
function BurdJournals.UI.DebugPanel.filterCharacterSkillList(self)
    local panel = self.charPanel
    if not panel or not panel.charSkillList then return end
    
    local searchText = ""
    if panel.skillSearchEntry and panel.skillSearchEntry.getText then
        searchText = panel.skillSearchEntry:getText()
    end
    
    -- If no search text, show all items
    if searchText == "" then
        for _, item in ipairs(panel.charSkillList.items) do
            item.item.hidden = false
        end
    else
        -- Filter items by name
        for _, item in ipairs(panel.charSkillList.items) do
            item.item.hidden = not debugSearchMatches(searchText, item.item.displayName, item.item.name, item.item.category)
        end
    end
end

-- Filter trait list based on search text
function BurdJournals.UI.DebugPanel.filterCharacterTraitList(self)
    local panel = self.charPanel
    if not panel or not panel.charTraitList then return end
    
    local searchText = ""
    if panel.traitSearchEntry and panel.traitSearchEntry.getText then
        searchText = panel.traitSearchEntry:getText()
    end
    
    -- If no search text, show all items
    if searchText == "" then
        for _, item in ipairs(panel.charTraitList.items) do
            item.item.hidden = false
        end
    else
        -- Filter items by name
        for _, item in ipairs(panel.charTraitList.items) do
            item.item.hidden = not debugSearchMatches(searchText, item.item.displayName, item.item.id)
        end
    end
end

-- Character command handler
function BurdJournals.UI.DebugPanel:onCharCmd(button)
    local cmd = button.internal
    local charPanel = self.charPanel
    local targetPlayer = charPanel and charPanel.targetPlayer or self.player
    
    if cmd == "setallmax" then
        self:setStatus("Setting all skills to max...", {r=0.5, g=0.8, b=1})
        if targetPlayer then
            if isClient() and not isServer() then
                -- Multiplayer: send to server, UI refresh will happen on server response
                sendClientCommand("BurdJournals", "debugSetAllSkills", {
                    level = 10,
                    targetUsername = targetPlayer:getUsername()
                })
                -- Optimistically update the list display while waiting for server
                if self.charPanel and self.charPanel.charSkillList then
                    for _, item in ipairs(self.charPanel.charSkillList.items) do
                        if item.item then
                            item.item.level = 10
                        end
                    end
                end
            else
                -- Singleplayer: apply directly
                local xpObj = targetPlayer:getXp()
                local count = 0
                
                -- Remove ALL passive skill traits FIRST to prevent bouncing
                BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, "Strength")
                BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, "Fitness")
                
                -- For passive skills, use setPerkLevelDebug which directly sets level
                -- This bypasses XP scaling issues that affect Strength specifically
                local strengthPerk = Perks.Strength
                local fitnessPerk = Perks.Fitness
                
                if strengthPerk then
                    targetPlayer:setPerkLevelDebug(strengthPerk, 10)
                    count = count + 1
                end
                
                if fitnessPerk then
                    targetPlayer:setPerkLevelDebug(fitnessPerk, 10)
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
                            local targetXP = perk:getTotalXpForLevel(10)
                            
                            local xpDiff = targetXP - currentXP
                            if xpDiff ~= 0 then
                                xpObj:AddXP(perk, xpDiff, false, false, false, true)
                            end
                            count = count + 1
                        end
                    end
                end
                self:setStatus("All " .. count .. " skills set to level 10!", {r=0.3, g=1, b=0.5})
                self:refreshCharacterData()
            end
        end
        
    elseif cmd == "setallzero" then
        -- Optimistically update the UI immediately
        if self.charPanel and self.charPanel.charSkillList then
            for _, item in ipairs(self.charPanel.charSkillList.items) do
                if item.item then
                    item.item.level = 0
                end
            end
        end
        self:setStatus("All skills set to level 0!", {r=1, g=0.8, b=0.3})
        
        if targetPlayer then
            if isClient() and not isServer() then
                -- Multiplayer: send to server
                sendClientCommand("BurdJournals", "debugSetAllSkills", {
                    level = 0,
                    targetUsername = targetPlayer:getUsername()
                })
            else
                -- Singleplayer: set all to 0
                local xpObj = targetPlayer:getXp()
                local count = 0
                
                -- Remove ALL passive skill traits FIRST to prevent bouncing
                -- (e.g., Feeble trait forcing Strength to stay at level 2)
                BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, "Strength")
                BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, "Fitness")
                
                -- For passive skills, use setPerkLevelDebug which directly sets level
                -- This bypasses XP scaling issues that affect Strength specifically
                local strengthPerk = Perks.Strength
                local fitnessPerk = Perks.Fitness
                
                if strengthPerk then
                    targetPlayer:setPerkLevelDebug(strengthPerk, 0)
                    -- Also reset XP directly and remove traits again
                    -- PZ auto-applies "Weak" trait which bounces Strength back up
                    xpObj:AddXP(strengthPerk, -xpObj:getXP(strengthPerk), false, false, false, false)
                    BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, "Strength")
                    targetPlayer:setPerkLevelDebug(strengthPerk, 0)
                    count = count + 1
                end
                
                if fitnessPerk then
                    targetPlayer:setPerkLevelDebug(fitnessPerk, 0)
                    -- Same treatment for Fitness just in case
                    xpObj:AddXP(fitnessPerk, -xpObj:getXP(fitnessPerk), false, false, false, false)
                    BurdJournals.UI.DebugPanel.removePassiveSkillTraits(targetPlayer, "Fitness")
                    targetPlayer:setPerkLevelDebug(fitnessPerk, 0)
                    count = count + 1
                end
                
                -- For all other skills, set to 0 XP
                for i = 0, Perks.getMaxIndex() - 1 do
                    local perk = Perks.fromIndex(i)
                    if perk and perk:getParent() ~= Perks.None then
                        local perkName = tostring(perk)
                        -- Skip passive skills - already handled above
                        if perkName ~= "Fitness" and perkName ~= "Strength" then
                            local currentXP = xpObj:getXP(perk)
                            if currentXP > 0 then
                                xpObj:AddXP(perk, -currentXP, false, false, false, false)
                            end
                            count = count + 1
                        end
                    end
                end
                self:setStatus("All " .. count .. " skills set to level 0!", {r=0.3, g=1, b=0.5})
                self:refreshCharacterData()
            end
        end
        
    elseif cmd == "removealltraits" then
        -- Optimistically update the UI immediately
        if self.charPanel and self.charPanel.charTraitList then
            for _, item in ipairs(self.charPanel.charTraitList.items) do
                if item.item then
                    item.item.hasCount = 0
                end
            end
        end
        self:setStatus("Removing all traits...", {r=1, g=0.8, b=0.3})
        
        if targetPlayer then
            if isClient() and not isServer() then
                -- Multiplayer: send to server
                sendClientCommand("BurdJournals", "debugRemoveAllTraits", {
                    targetUsername = targetPlayer:getUsername()
                })
            else
                -- Singleplayer: apply directly using Build 42 approach
                local removeCount = 0
                
                -- Get CharacterTraits collection for removal (Build 42 API)
                local charTraits = nil
                if targetPlayer.getCharacterTraits then
                    charTraits = targetPlayer:getCharacterTraits()
                end
                
                -- Collect all traits the player has using CharacterTraitDefinition iteration
                local traitsToRemove = {}
                
                if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
                    local allDefs = CharacterTraitDefinition.getTraits()
                    if allDefs then
                        for i = 0, allDefs:size() - 1 do
                            local def = allDefs:get(i)
                            if def then
                                -- Build 42 uses getType(), not getTrait()
                                local traitObj = def.getType and def:getType() or nil
                                if traitObj and targetPlayer.hasTrait and targetPlayer:hasTrait(traitObj) then
                                    -- Skip passive skill traits (Fitness/Strength related)
                                    local isPassiveSkillTrait = false
                                    if BurdJournals.isPassiveSkillTrait then
                                        local traitName = ""
                                        if traitObj.getName then traitName = traitObj:getName() or "" end
                                        isPassiveSkillTrait = BurdJournals.isPassiveSkillTrait(traitName)
                                    end
                                    if not isPassiveSkillTrait then
                                        table.insert(traitsToRemove, traitObj)
                                    end
                                end
                            end
                        end
                    end
                end
                
                BurdJournals.debugPrint("[BurdJournals] Remove All Traits: Found " .. #traitsToRemove .. " traits to remove")
                
                -- Remove each trait using getCharacterTraits():remove()
                for _, traitObj in ipairs(traitsToRemove) do
                    local removed = false
                    if charTraits and charTraits.remove then
                        charTraits:remove(traitObj)
                        removed = true
                    end
                    if removed then
                        removeCount = removeCount + 1
                        local traitName = traitObj.getName and traitObj:getName() or tostring(traitObj)
                        BurdJournals.debugPrint("[BurdJournals] Removed trait: " .. traitName)
                    end
                end
                
                self:setStatus("Removed " .. removeCount .. " traits!", {r=0.3, g=1, b=0.5})
                -- Refresh to show actual state
                self:refreshCharacterData()
            end
        end
        
    elseif cmd == "dumpskills" then
        BurdJournals.debugPrint("[BSJ DEBUG] Player Skills for: " .. (targetPlayer:getUsername() or "Unknown"))
        if targetPlayer then
            local xp = targetPlayer:getXp()
            for i = 0, Perks.getMaxIndex() - 1 do
                local perk = Perks.fromIndex(i)
                if perk and perk:getParent() ~= Perks.None then
                    local level = targetPlayer:getPerkLevel(perk)
                    local xpVal = xp:getXP(perk)
                    BurdJournals.debugPrint(string.format("  %s: Level %d (XP: %.0f)", tostring(perk), level, xpVal))
                end
            end
        end
        self:setStatus("Skills dumped to console", {r=0.5, g=0.8, b=1})
        
    elseif cmd == "dumptraits" then
        BurdJournals.debugPrint("[BSJ DEBUG] Player Traits for: " .. (targetPlayer:getUsername() or "Unknown"))
        if targetPlayer then
            local traitCounts = {}
            local totalCount = 0
            
            -- Build 42 approach: iterate through CharacterTraitDefinition and check which ones player has
            local CharacterTraitDefinition = CharacterTraitDefinition
            if CharacterTraitDefinition and CharacterTraitDefinition.getTraits then
                local allDefs = CharacterTraitDefinition.getTraits()
                if allDefs then
                    for i = 0, allDefs:size() - 1 do
                        local def = allDefs:get(i)
                        if def and def.getTrait then
                            local traitObj = def:getTrait()
                            if traitObj and targetPlayer.hasTrait and targetPlayer:hasTrait(traitObj) then
                                local traitId = "unknown"
                                if traitObj.getResourceLocation then
                                    local loc = traitObj:getResourceLocation()
                                    if loc then traitId = tostring(loc) end
                                end
                                -- Also try to get display name
                                local displayName = traitId
                                if def.getLabel then displayName = def:getLabel() or traitId end
                                traitCounts[traitId] = (traitCounts[traitId] or 0) + 1
                                totalCount = totalCount + 1
                            end
                        end
                    end
                end
            end
            
            -- Fallback: try old API if no traits found
            if totalCount == 0 and targetPlayer.getTraits then
                local traits = targetPlayer:getTraits()
                if traits and traits.size then
                    for i = 0, traits:size() - 1 do
                        local t = tostring(traits:get(i))
                        traitCounts[t] = (traitCounts[t] or 0) + 1
                        totalCount = totalCount + 1
                    end
                end
            end
            
            -- Print results
            if totalCount > 0 then
                for traitId, count in pairs(traitCounts) do
                    if count > 1 then
                        BurdJournals.debugPrint("  " .. traitId .. " (x" .. count .. ")")
                    else
                        BurdJournals.debugPrint("  " .. traitId)
                    end
                end
            else
                BurdJournals.debugPrint("  (no traits found)")
            end
            BurdJournals.debugPrint("[BSJ DEBUG] Total: " .. totalCount .. " traits")
        end
        self:setStatus("Traits dumped to console", {r=0.5, g=0.8, b=1})
    end
end

-- ============================================================================
-- Tab 3: Baseline Manager Panel
-- ============================================================================

function BurdJournals.UI.DebugPanel:createBaselinePanel(startY, height)
    local panel = ISPanel:new(5, startY, self.width - 10, height)
    panel:initialise()
    panel:instantiate()
    panel.backgroundColor = {r=0.12, g=0.12, b=0.15, a=1}
    panel.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    self:addChild(panel)
    self.tabPanels["baseline"] = panel
    
    local padding = 10
    local y = padding
    local fullWidth = panel.width - padding * 2
    local halfWidth = (fullWidth - padding) / 2
    local btnHeight = 24
    
    -- Check if baseline restriction is enabled
    local baselineEnabled = BurdJournals.isBaselineRestrictionEnabled and BurdJournals.isBaselineRestrictionEnabled()
    panel.baselineEnabled = baselineEnabled
    panel.baselineDraftDirty = false
    panel.baselineDraftSkills = {}
    panel.baselineDraftTraits = {}
    
    -- Status indicator for baseline setting
    local statusText = baselineEnabled and "Baseline Restriction: ENABLED" or "Baseline Restriction: DISABLED"
    local statusColor = baselineEnabled and {0.5, 0.8, 0.5} or {0.8, 0.6, 0.3}
    local statusLabel = ISLabel:new(padding, y, 18, statusText, statusColor[1], statusColor[2], statusColor[3], 1, UIFont.Small, true)
    statusLabel:initialise()
    statusLabel:instantiate()
    panel:addChild(statusLabel)
    panel.statusLabel = statusLabel
    y = y + 22

    -- Server-authoritative baseline note
    local authLabel = ISLabel:new(padding, y, 16, "Baseline is stored from server state (authoritative).", 0.6, 0.7, 0.9, 1, UIFont.Small, true)
    authLabel:initialise()
    authLabel:instantiate()
    panel:addChild(authLabel)
    y = y + 18
    
    -- If baseline is disabled, show explanation and limited controls
    if not baselineEnabled then
        local infoLabel1 = ISLabel:new(padding, y, 16, "The sandbox setting 'Only Record Earned Progress' is OFF.", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
        infoLabel1:initialise()
        infoLabel1:instantiate()
        panel:addChild(infoLabel1)
        y = y + 18
        
        local infoLabel2 = ISLabel:new(padding, y, 16, "Players can record ALL progress, not just earned XP.", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
        infoLabel2:initialise()
        infoLabel2:instantiate()
        panel:addChild(infoLabel2)
        y = y + 18
        
        local infoLabel3 = ISLabel:new(padding, y, 16, "Baseline management is not needed for this save.", 0.6, 0.6, 0.6, 1, UIFont.Small, true)
        infoLabel3:initialise()
        infoLabel3:instantiate()
        panel:addChild(infoLabel3)
        y = y + 30
        
        -- Still show view-only info
        local viewLabel = ISLabel:new(padding, y, 18, "Player Stats (View Only):", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
        viewLabel:initialise()
        viewLabel:instantiate()
        panel:addChild(viewLabel)
        y = y + 22
        
        -- Simplified skill view list (read-only)
        local skillListHeight = 200
        panel.baselineSkillList = ISScrollingListBox:new(padding, y, fullWidth, skillListHeight)
        panel.baselineSkillList:initialise()
        panel.baselineSkillList:instantiate()
        panel.baselineSkillList.itemheight = 24
        panel.baselineSkillList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
        panel.baselineSkillList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
        panel.baselineSkillList.doDrawItem = BurdJournals.UI.DebugPanel.drawBaselineSkillItemReadOnly
        panel.baselineSkillList.parentPanel = self
        panel:addChild(panel.baselineSkillList)
        y = y + skillListHeight + 10
        
        -- Dump buttons
        local dumpBtn = ISButton:new(padding, y, 150, btnHeight, "Dump Stats to Console", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
        dumpBtn:initialise()
        dumpBtn:instantiate()
        dumpBtn.font = UIFont.Small
        dumpBtn.internal = "dumpbaseline"
        dumpBtn.textColor = {r=1, g=1, b=1, a=1}
        dumpBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        dumpBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
        panel:addChild(dumpBtn)

        local spawnDumpBtn = ISButton:new(padding + 160, y, 200, btnHeight, "Dump Spawn Readiness", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
        spawnDumpBtn:initialise()
        spawnDumpBtn:instantiate()
        spawnDumpBtn.font = UIFont.Small
        spawnDumpBtn.internal = "dumpspawnstate"
        spawnDumpBtn.textColor = {r=1, g=1, b=1, a=1}
        spawnDumpBtn.borderColor = {r=0.35, g=0.55, b=0.65, a=1}
        spawnDumpBtn.backgroundColor = {r=0.16, g=0.28, b=0.34, a=1}
        panel:addChild(spawnDumpBtn)
        
        -- Store reference and populate
        self.baselinePanel = panel
        panel.targetPlayer = self.player
        self:refreshBaselineData()
        return
    end
    
    -- Full baseline management UI (when enabled)
    -- Player selector (for admins to select other players)
    local playerLabel = ISLabel:new(padding, y, 18, "Target Player:", 1, 1, 1, 1, UIFont.Small, true)
    playerLabel:initialise()
    playerLabel:instantiate()
    panel:addChild(playerLabel)
    
    panel.targetPlayerCombo = ISComboBox:new(padding + 90, y - 2, 200, 22, self, BurdJournals.UI.DebugPanel.onBaselineTargetPlayerChange)
    panel.targetPlayerCombo:initialise()
    panel.targetPlayerCombo:instantiate()
    panel.targetPlayerCombo.font = UIFont.Small
    panel:addChild(panel.targetPlayerCombo)
    
    local refreshBtn = ISButton:new(padding + 295, y - 2, 70, 22, "Refresh", self, BurdJournals.UI.DebugPanel.onBaselineRefresh)
    refreshBtn:initialise()
    refreshBtn:instantiate()
    refreshBtn.font = UIFont.Small
    refreshBtn.textColor = {r=1, g=1, b=1, a=1}
    refreshBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    refreshBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(refreshBtn)
    y = y + 28
    
    -- Skills section header with search
    local skillsLabel = ISLabel:new(padding, y, 18, "Skills (Click squares to set baseline):", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    skillsLabel:initialise()
    skillsLabel:instantiate()
    panel:addChild(skillsLabel)
    
    -- Skill search field + quick draft actions
    local skillSearchX = padding + 230
    local skillSearchWidth = 145
    panel.baselineSkillSearch = ISTextEntryBox:new("", skillSearchX, y - 2, skillSearchWidth, 20)
    panel.baselineSkillSearch:initialise()
    panel.baselineSkillSearch:instantiate()
    panel.baselineSkillSearch.font = UIFont.Small
    panel.baselineSkillSearch:setTooltip("Filter skills...")
    panel.baselineSkillSearch.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterBaselineSkillList(self)
    end
    panel:addChild(panel.baselineSkillSearch)

    local topActionSpacing = 6
    local saveDraftWidth = 158
    local discardDraftWidth = 88
    local openSnapshotsWidth = 96
    local topActionTotalWidth = saveDraftWidth + discardDraftWidth + openSnapshotsWidth + (topActionSpacing * 2)
    local topActionX = padding + fullWidth - topActionTotalWidth
    local minTopActionX = skillSearchX + skillSearchWidth + 8
    if topActionX < minTopActionX then
        topActionX = minTopActionX
    end

    local saveDraftBtn = ISButton:new(topActionX, y - 2, saveDraftWidth, btnHeight, getText("UI_BurdJournals_SaveBaselineSnapshot") or "Save Baseline Snapshot", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    saveDraftBtn:initialise()
    saveDraftBtn:instantiate()
    saveDraftBtn.font = UIFont.Small
    saveDraftBtn.internal = "savebaselinechanges"
    saveDraftBtn.textColor = {r=1, g=1, b=1, a=1}
    saveDraftBtn.borderColor = {r=0.45, g=0.72, b=0.5, a=1}
    saveDraftBtn.backgroundColor = {r=0.2, g=0.35, b=0.24, a=1}
    panel:addChild(saveDraftBtn)
    panel.saveBaselineChangesBtn = saveDraftBtn

    local discardDraftBtn = ISButton:new(topActionX + saveDraftWidth + topActionSpacing, y - 2, discardDraftWidth, btnHeight, getText("UI_BurdJournals_DiscardBaselineDraftShort") or "Discard", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    discardDraftBtn:initialise()
    discardDraftBtn:instantiate()
    discardDraftBtn.font = UIFont.Small
    discardDraftBtn.internal = "discardbaselinechanges"
    discardDraftBtn.textColor = {r=1, g=1, b=1, a=1}
    discardDraftBtn.borderColor = {r=0.68, g=0.5, b=0.4, a=1}
    discardDraftBtn.backgroundColor = {r=0.34, g=0.24, b=0.18, a=1}
    panel:addChild(discardDraftBtn)
    panel.discardBaselineChangesBtn = discardDraftBtn

    local openSnapshotsBtn = ISButton:new(topActionX + saveDraftWidth + discardDraftWidth + (topActionSpacing * 2), y - 2, openSnapshotsWidth, btnHeight, getText("UI_BurdJournals_OpenSnapshotsTabShort") or "Snapshots", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    openSnapshotsBtn:initialise()
    openSnapshotsBtn:instantiate()
    openSnapshotsBtn.font = UIFont.Small
    openSnapshotsBtn.internal = "opensnapshots"
    openSnapshotsBtn.textColor = {r=1, g=1, b=1, a=1}
    openSnapshotsBtn.borderColor = {r=0.55, g=0.5, b=0.75, a=1}
    openSnapshotsBtn.backgroundColor = {r=0.24, g=0.2, b=0.34, a=1}
    panel:addChild(openSnapshotsBtn)
    y = y + 22
    
    -- Skill baseline list (scrollable)
    local skillListHeight = 150
    panel.baselineSkillList = ISScrollingListBox:new(padding, y, fullWidth, skillListHeight)
    panel.baselineSkillList:initialise()
    panel.baselineSkillList:instantiate()
    panel.baselineSkillList.itemheight = 24
    panel.baselineSkillList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.baselineSkillList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.baselineSkillList.doDrawItem = BurdJournals.UI.DebugPanel.drawBaselineSkillItem
    panel.baselineSkillList.onMouseDown = BurdJournals.UI.DebugPanel.onBaselineSkillListClick
    panel.baselineSkillList.parentPanel = self
    panel:addChild(panel.baselineSkillList)
    y = y + skillListHeight + 5
    
    -- Traits section header with search
    local traitsLabel = ISLabel:new(padding, y, 18, "Traits (Check to include in baseline):", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    traitsLabel:initialise()
    traitsLabel:instantiate()
    panel:addChild(traitsLabel)
    
    -- Trait search field
    panel.baselineTraitSearch = ISTextEntryBox:new("", padding + 210, y - 2, 130, 20)
    panel.baselineTraitSearch:initialise()
    panel.baselineTraitSearch:instantiate()
    panel.baselineTraitSearch.font = UIFont.Small
    panel.baselineTraitSearch:setTooltip("Filter traits...")
    panel.baselineTraitSearch.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterBaselineTraitList(self)
    end
    panel:addChild(panel.baselineTraitSearch)
    y = y + 22
    
    -- Trait baseline list (scrollable)
    local traitListHeight = 90
    panel.baselineTraitList = ISScrollingListBox:new(padding, y, fullWidth, traitListHeight)
    panel.baselineTraitList:initialise()
    panel.baselineTraitList:instantiate()
    panel.baselineTraitList.itemheight = 22
    panel.baselineTraitList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.baselineTraitList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.baselineTraitList.doDrawItem = BurdJournals.UI.DebugPanel.drawBaselineTraitItem
    panel.baselineTraitList.onMouseDown = BurdJournals.UI.DebugPanel.onBaselineTraitListClick
    panel.baselineTraitList.parentPanel = self
    panel:addChild(panel.baselineTraitList)
    y = y + traitListHeight + 10
    
    -- Action buttons row
    local btnWidth = 140
    local btnSpacing = 8
    local btnX = padding
    
    local recalcBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Set to Current Skills", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    recalcBtn:initialise()
    recalcBtn:instantiate()
    recalcBtn.font = UIFont.Small
    recalcBtn.internal = "recalculate"
    recalcBtn.textColor = {r=1, g=1, b=1, a=1}
    recalcBtn.borderColor = {r=0.5, g=0.6, b=0.3, a=1}
    recalcBtn.backgroundColor = {r=0.25, g=0.35, b=0.15, a=1}
    panel:addChild(recalcBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local clearAllBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Clear All Baseline", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    clearAllBtn:initialise()
    clearAllBtn:instantiate()
    clearAllBtn.font = UIFont.Small
    clearAllBtn.internal = "clearall"
    clearAllBtn.textColor = {r=1, g=1, b=1, a=1}
    clearAllBtn.borderColor = {r=0.6, g=0.4, b=0.3, a=1}
    clearAllBtn.backgroundColor = {r=0.4, g=0.2, b=0.15, a=1}
    panel:addChild(clearAllBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local dumpBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Dump to Console", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    dumpBtn:initialise()
    dumpBtn:instantiate()
    dumpBtn.font = UIFont.Small
    dumpBtn.internal = "dumpbaseline"
    dumpBtn.textColor = {r=1, g=1, b=1, a=1}
    dumpBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    dumpBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(dumpBtn)
    btnX = btnX + btnWidth + btnSpacing

    local migrateBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Migrate Journals", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    migrateBtn:initialise()
    migrateBtn:instantiate()
    migrateBtn.font = UIFont.Small
    migrateBtn.internal = "migratejournals"
    migrateBtn.textColor = {r=1, g=1, b=1, a=1}
    migrateBtn.borderColor = {r=0.35, g=0.55, b=0.65, a=1}
    migrateBtn.backgroundColor = {r=0.16, g=0.26, b=0.32, a=1}
    panel:addChild(migrateBtn)

    y = y + btnHeight + 5

    local spawnDumpBtn = ISButton:new(padding, y, 190, btnHeight, "Dump Spawn Readiness", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
    spawnDumpBtn:initialise()
    spawnDumpBtn:instantiate()
    spawnDumpBtn.font = UIFont.Small
    spawnDumpBtn.internal = "dumpspawnstate"
    spawnDumpBtn.textColor = {r=1, g=1, b=1, a=1}
    spawnDumpBtn.borderColor = {r=0.35, g=0.55, b=0.65, a=1}
    spawnDumpBtn.backgroundColor = {r=0.16, g=0.28, b=0.34, a=1}
    panel:addChild(spawnDumpBtn)

    -- Store reference
    self.baselinePanel = panel
    panel.targetPlayer = self.player  -- Default to current player
    
    -- Initial population
    self:populateBaselinePlayerList()
    self:refreshBaselineData()
end

function BurdJournals.UI.DebugPanel.onSpawnProfileChange(self)
    local panel = self.spawnPanel
    if not panel or not panel.spawnProfileCombo then
        return
    end
    local value = panel.spawnProfileCombo:getOptionData(panel.spawnProfileCombo.selected)
        or panel.spawnProfileCombo.options[panel.spawnProfileCombo.selected]
        or "normal"
    value = tostring(value or "normal")
    if value ~= "debug" then
        value = "normal"
    end
    panel.spawnProfile = value
    self:updateSpawnSummary()
end

function BurdJournals.UI.DebugPanel.onSpawnOriginChange(self)
    local panel = self.spawnPanel
    if not panel or not panel.spawnOriginCombo then
        return
    end
    local value = panel.spawnOriginCombo:getOptionData(panel.spawnOriginCombo.selected)
        or panel.spawnOriginCombo.options[panel.spawnOriginCombo.selected]
        or "auto"
    panel.spawnOriginMode = normalizeDebugOriginMode(value)
    self:updateSpawnSummary()
end

function BurdJournals.UI.DebugPanel:createSnapshotsPanel(startY, height)
    local panel = ISPanel:new(5, startY, self.width - 10, height)
    panel:initialise()
    panel:instantiate()
    panel.backgroundColor = {r=0.12, g=0.12, b=0.15, a=1}
    panel.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    self:addChild(panel)
    self.tabPanels["snapshots"] = panel

    local padding = 10
    local y = padding
    local fullWidth = panel.width - padding * 2

    local heading = ISLabel:new(
        padding,
        y,
        18,
        getText("UI_BurdJournals_BaselineSnapshotManagerTitle") or "Baseline Backup Manager",
        0.88,
        0.84,
        0.96,
        1,
        UIFont.Small,
        true
    )
    heading:initialise()
    heading:instantiate()
    panel:addChild(heading)
    y = y + 22

    local targetLabel = ISLabel:new(
        padding,
        y + 2,
        16,
        getText("UI_BurdJournals_SnapshotTargetPlayer") or "Target Player:",
        1,
        1,
        1,
        1,
        UIFont.Small,
        true
    )
    targetLabel:initialise()
    targetLabel:instantiate()
    panel:addChild(targetLabel)

    panel.snapshotTargetCombo = ISComboBox:new(padding + 90, y - 2, math.max(190, math.min(260, math.floor(fullWidth * 0.34))), 22, self, BurdJournals.UI.DebugPanel.onSnapshotTargetPlayerChange)
    panel.snapshotTargetCombo:initialise()
    panel.snapshotTargetCombo:instantiate()
    panel.snapshotTargetCombo.font = UIFont.Small
    panel:addChild(panel.snapshotTargetCombo)

    y = y + 28

    local searchLabel = ISLabel:new(
        padding,
        y + 2,
        16,
        getText("UI_BurdJournals_BaselineSnapshotSearch") or "Search:",
        0.8,
        0.8,
        0.9,
        1,
        UIFont.Small,
        true
    )
    searchLabel:initialise()
    searchLabel:instantiate()
    panel:addChild(searchLabel)

    local searchW = math.max(150, math.min(270, math.floor(fullWidth * 0.30)))
    panel.snapshotSearch = ISTextEntryBox:new("", padding + 52, y - 1, searchW, 20)
    panel.snapshotSearch:initialise()
    panel.snapshotSearch:instantiate()
    panel.snapshotSearch.font = UIFont.Small
    panel.snapshotSearch.onTextChange = function()
        if BurdJournals.UI.DebugPanel.instance and BurdJournals.UI.DebugPanel.instance.requestBaselineSnapshots then
            BurdJournals.UI.DebugPanel.instance:requestBaselineSnapshots()
        end
    end
    panel:addChild(panel.snapshotSearch)

    local filterX = panel.snapshotSearch:getX() + panel.snapshotSearch:getWidth() + 10
    if filterX + 210 > (padding + fullWidth) then
        y = y + 24
        filterX = padding
    end

    local filterLabel = ISLabel:new(
        filterX,
        y + 2,
        16,
        getText("UI_BurdJournals_BaselineSnapshotFilter") or "Filter:",
        0.8,
        0.8,
        0.9,
        1,
        UIFont.Small,
        true
    )
    filterLabel:initialise()
    filterLabel:instantiate()
    panel:addChild(filterLabel)

    panel.snapshotFilterCombo = ISComboBox:new(filterX + 38, y - 2, 130, 22, self, BurdJournals.UI.DebugPanel.onBaselineSnapshotFilterChanged)
    panel.snapshotFilterCombo:initialise()
    panel.snapshotFilterCombo:instantiate()
    panel.snapshotFilterCombo.font = UIFont.Small
    panel.snapshotFilterCombo:addOptionWithData(getText("UI_BurdJournals_BaselineSnapshotFilterCurrentTarget") or "Current Target", "target")
    panel.snapshotFilterCombo:addOptionWithData(getText("UI_BurdJournals_BaselineSnapshotFilterSteamId") or "SteamID", "steam")
    panel.snapshotFilterCombo:addOptionWithData(getText("UI_BurdJournals_BaselineSnapshotFilterCharacterId") or "Character ID", "character")
    panel.snapshotFilterCombo.selected = 1
    panel:addChild(panel.snapshotFilterCombo)

    local refreshX = panel.snapshotFilterCombo:getX() + panel.snapshotFilterCombo:getWidth() + 6
    local topRefreshBtn = ISButton:new(
        refreshX,
        y - 2,
        76,
        22,
        getText("UI_BurdJournals_BaselineSnapshotRefresh") or "Refresh",
        self,
        BurdJournals.UI.DebugPanel.onSnapshotCmd
    )
    topRefreshBtn:initialise()
    topRefreshBtn:instantiate()
    topRefreshBtn.font = UIFont.Small
    topRefreshBtn.internal = "baselinesnapshot_refresh"
    topRefreshBtn.textColor = {r=1, g=1, b=1, a=1}
    topRefreshBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    topRefreshBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(topRefreshBtn)
    y = y + 26

    panel.snapshotListSummaryLabel = ISLabel:new(
        padding,
        y + 1,
        16,
        "Snapshots: 0",
        0.72,
        0.8,
        0.92,
        1,
        UIFont.Small,
        true
    )
    panel.snapshotListSummaryLabel:initialise()
    panel.snapshotListSummaryLabel:instantiate()
    panel:addChild(panel.snapshotListSummaryLabel)
    y = y + 18

    local contentBottom = panel.height - 56
    local contentHeight = math.max(220, contentBottom - y)
    local splitWide = fullWidth >= 800
    local gap = 8

    if splitWide then
        panel.snapshotListX = padding
        panel.snapshotListY = y
        panel.snapshotListW = math.max(260, math.floor(fullWidth * 0.42))
        panel.snapshotListH = contentHeight
        panel.snapshotPreviewX = panel.snapshotListX + panel.snapshotListW + gap
        panel.snapshotPreviewY = y
        panel.snapshotPreviewW = fullWidth - panel.snapshotListW - gap
        panel.snapshotPreviewH = contentHeight
    else
        panel.snapshotListX = padding
        panel.snapshotListY = y
        panel.snapshotListW = fullWidth
        panel.snapshotListH = math.max(120, math.floor(contentHeight * 0.34))
        panel.snapshotPreviewX = padding
        panel.snapshotPreviewY = panel.snapshotListY + panel.snapshotListH + gap
        panel.snapshotPreviewW = fullWidth
        panel.snapshotPreviewH = contentHeight - panel.snapshotListH - gap
    end

    panel.snapshotList = ISScrollingListBox:new(panel.snapshotListX, panel.snapshotListY, panel.snapshotListW, panel.snapshotListH)
    panel.snapshotList:initialise()
    panel.snapshotList:instantiate()
    panel.snapshotList.itemheight = 36
    panel.snapshotList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.snapshotList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.snapshotList.parentPanel = self
    panel.snapshotList.doDrawItem = BurdJournals.UI.DebugPanel.drawBaselineSnapshotItem
    panel.snapshotList.onMouseDown = BurdJournals.UI.DebugPanel.onBaselineSnapshotListClick
    panel:addChild(panel.snapshotList)

    local px = panel.snapshotPreviewX
    local py = panel.snapshotPreviewY
    local pw = panel.snapshotPreviewW
    local ph = panel.snapshotPreviewH

    panel.snapshotDetailLabel = ISLabel:new(
        px,
        py,
        16,
        getText("UI_BurdJournals_BaselineSnapshotDetailNone") or "Select a snapshot to preview details.",
        0.7,
        0.75,
        0.85,
        1,
        UIFont.Small,
        true
    )
    panel.snapshotDetailLabel:initialise()
    panel.snapshotDetailLabel:instantiate()
    panel:addChild(panel.snapshotDetailLabel)
    py = py + 18

    panel.snapshotDetailMetaLabel = ISLabel:new(
        px,
        py,
        16,
        "",
        0.72,
        0.78,
        0.88,
        1,
        UIFont.Small,
        true
    )
    panel.snapshotDetailMetaLabel:initialise()
    panel.snapshotDetailMetaLabel:instantiate()
    panel:addChild(panel.snapshotDetailMetaLabel)
    py = py + 16

    panel.snapshotCurrentLabel = ISLabel:new(
        px,
        py,
        16,
        getText("UI_BurdJournals_SnapshotCurrentBaselineLabel") or "Current baseline comparison: waiting for server...",
        0.62,
        0.78,
        0.92,
        1,
        UIFont.Small,
        true
    )
    panel.snapshotCurrentLabel:initialise()
    panel.snapshotCurrentLabel:instantiate()
    panel:addChild(panel.snapshotCurrentLabel)
    py = py + 18

    local skillH = math.max(90, math.floor(ph * 0.55))
    local remainingH = ph - (py - panel.snapshotPreviewY) - skillH - 8
    if remainingH < 66 then
        skillH = math.max(76, skillH + remainingH - 66)
        remainingH = 66
    end

    panel.snapshotSkillPreviewList = ISScrollingListBox:new(px, py, pw, skillH)
    panel.snapshotSkillPreviewList:initialise()
    panel.snapshotSkillPreviewList:instantiate()
    panel.snapshotSkillPreviewList.itemheight = 32
    panel.snapshotSkillPreviewList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.snapshotSkillPreviewList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.snapshotSkillPreviewList.parentPanel = self
    panel.snapshotSkillPreviewList.doDrawItem = BurdJournals.UI.DebugPanel.drawSnapshotSkillPreviewItem
    panel:addChild(panel.snapshotSkillPreviewList)
    py = py + skillH + 8

    local diffGap = 6
    local diffW = math.floor((pw - (diffGap * 2)) / 3)
    panel.snapshotTraitDiffList = ISScrollingListBox:new(px, py, diffW, remainingH)
    panel.snapshotTraitDiffList:initialise()
    panel.snapshotTraitDiffList:instantiate()
    panel.snapshotTraitDiffList.itemheight = 18
    panel.snapshotTraitDiffList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.snapshotTraitDiffList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.snapshotTraitDiffList.parentPanel = self
    panel.snapshotTraitDiffList.doDrawItem = BurdJournals.UI.DebugPanel.drawSnapshotDiffItem
    panel:addChild(panel.snapshotTraitDiffList)

    panel.snapshotRecipeDiffList = ISScrollingListBox:new(px + diffW + diffGap, py, diffW, remainingH)
    panel.snapshotRecipeDiffList:initialise()
    panel.snapshotRecipeDiffList:instantiate()
    panel.snapshotRecipeDiffList.itemheight = 18
    panel.snapshotRecipeDiffList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.snapshotRecipeDiffList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.snapshotRecipeDiffList.parentPanel = self
    panel.snapshotRecipeDiffList.doDrawItem = BurdJournals.UI.DebugPanel.drawSnapshotDiffItem
    panel:addChild(panel.snapshotRecipeDiffList)

    panel.snapshotMediaDiffList = ISScrollingListBox:new(px + ((diffW + diffGap) * 2), py, diffW, remainingH)
    panel.snapshotMediaDiffList:initialise()
    panel.snapshotMediaDiffList:instantiate()
    panel.snapshotMediaDiffList.itemheight = 18
    panel.snapshotMediaDiffList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.snapshotMediaDiffList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.snapshotMediaDiffList.parentPanel = self
    panel.snapshotMediaDiffList.doDrawItem = BurdJournals.UI.DebugPanel.drawSnapshotDiffItem
    panel:addChild(panel.snapshotMediaDiffList)

    local btnY = panel.height - 32
    local btnGap = 6
    local btnW = math.max(120, math.floor((fullWidth - (btnGap * 2)) / 3))
    local btnX = padding
    local function makeSnapshotButton(labelKey, fallback, internal, border, bg)
        local btn = ISButton:new(
            btnX,
            btnY,
            btnW,
            22,
            getText(labelKey) or fallback,
            self,
            BurdJournals.UI.DebugPanel.onSnapshotCmd
        )
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = internal
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = border
        btn.backgroundColor = bg
        panel:addChild(btn)
        btnX = btnX + btnW + btnGap
        return btn
    end

    makeSnapshotButton("UI_BurdJournals_BaselineSnapshotSave", "Save Snapshot", "baselinesnapshot_save", {r=0.35, g=0.55, b=0.4, a=1}, {r=0.18, g=0.3, b=0.22, a=1})
    makeSnapshotButton("UI_BurdJournals_BaselineSnapshotApply", "Apply Snapshot", "baselinesnapshot_apply", {r=0.55, g=0.52, b=0.75, a=1}, {r=0.22, g=0.18, b=0.32, a=1})
    makeSnapshotButton("UI_BurdJournals_BaselineSnapshotDelete", "Delete Snapshot", "baselinesnapshot_delete", {r=0.65, g=0.38, b=0.38, a=1}, {r=0.35, g=0.16, b=0.16, a=1})

    panel.snapshotItems = {}
    panel.snapshotSelectedId = nil
    panel.snapshotSelectedData = nil
    panel.snapshotCurrentPage = 1
    panel.snapshotPageSize = 20
    panel.snapshotLiveBaselinePayload = nil
    panel.snapshotPreviewRows = {}
    panel.snapshotTraitDiffRows = {}
    panel.snapshotRecipeDiffRows = {}
    panel.snapshotMediaDiffRows = {}

    self.snapshotPanel = panel
    panel.targetPlayer = self.player
    self:populateSnapshotPlayerList()
    self:refreshSnapshotPanelData()
end

-- Populate player dropdown with online players
function BurdJournals.UI.DebugPanel:populateBaselinePlayerList()
    local panel = self.baselinePanel
    if not panel or not panel.targetPlayerCombo then return end
    
    local selectedName = panel.targetPlayer and panel.targetPlayer.getUsername and panel.targetPlayer:getUsername() or nil
    panel.targetPlayerCombo:clear()
    
    -- Always add current player first
    local currentName = self.player and self.player:getUsername() or "You"
    panel.targetPlayerCombo:addOptionWithData(currentName, self.player)
    
    -- In multiplayer, only admins can target other online players.
    if self:canTargetOtherPlayers() then
        local onlinePlayers = getOnlinePlayers()
        if onlinePlayers then
            for i = 0, onlinePlayers:size() - 1 do
                local otherPlayer = onlinePlayers:get(i)
                if otherPlayer and otherPlayer ~= self.player then
                    local name = otherPlayer:getUsername() or "Unknown"
                    panel.targetPlayerCombo:addOptionWithData(name, otherPlayer)
                end
            end
        end
    end
    
    if selectedName and selectedName ~= "" then
        panel.targetPlayerCombo:select(selectedName)
    else
        panel.targetPlayerCombo:select(currentName)
    end
    if not panel.targetPlayer then
        panel.targetPlayer = self.player
    end
end

-- Handler for player selection change
function BurdJournals.UI.DebugPanel:onBaselineTargetPlayerChange(combo)
    local panel = self.baselinePanel
    if not panel then return end
    
    local selected = combo:getSelectedIndex()
    local data = combo.options[selected + 1]
    if data and data.data then
        if data.data ~= self.player and not self:canTargetOtherPlayers() then
            local currentName = self.player and self.player:getUsername() or "You"
            combo:select(currentName)
            panel.targetPlayer = self.player
            self:setStatus(getText("UI_BurdJournals_AdminOnly") or "This command requires admin access.", {r=1, g=0.6, b=0.3})
            return
        end
        local previousPlayer = panel.targetPlayer or self.player
        local function applyTargetSelection()
            panel.targetPlayer = data.data
            self:refreshBaselineData()
            self:setStatus("Viewing baseline for: " .. (panel.targetPlayer:getUsername() or "Unknown"), {r=0.5, g=0.8, b=1})
        end

        if previousPlayer ~= data.data and self:hasUnsavedBaselineDraft() then
            local previousName = previousPlayer and previousPlayer.getUsername and previousPlayer:getUsername()
            self:confirmDiscardBaselineDraft(
                getText("UI_BurdJournals_BaselineDraftActionChangeTarget") or "change target player",
                function()
                    applyTargetSelection()
                end,
                function()
                    if previousName and combo and combo.select then
                        combo:select(previousName)
                    end
                end
            )
            return
        end

        applyTargetSelection()
    end
end

-- Refresh button handler (non-destructive - just refreshes display without modifying baseline)
function BurdJournals.UI.DebugPanel:onBaselineRefresh()
    local function doRefresh()
        -- Don't clear skill cache - that's for full rediscovery
        -- Just refresh the player list and current baseline data display
        self:populateBaselinePlayerList()
        self:refreshBaselineData()
        self:setStatus("Display refreshed (baseline unchanged)", {r=0.5, g=0.8, b=1})
    end

    if self:hasUnsavedBaselineDraft() then
        self:confirmDiscardBaselineDraft(
            getText("UI_BurdJournals_BaselineDraftActionRefresh") or "refresh baseline data",
            doRefresh
        )
        return
    end

    doRefresh()
end

-- Refresh baseline data for the target player
function BurdJournals.UI.DebugPanel:refreshBaselineData()
    local panel = self.baselinePanel
    if not panel then return end
    panel.baselineDraftDirty = false
    panel.baselineDraftSkills = {}
    panel.baselineDraftTraits = {}
    if self.updateBaselineDraftButtons then
        self:updateBaselineDraftButtons()
    end

    local targetPlayer = panel.targetPlayer or self.player
    if not targetPlayer then 
        -- No player yet, skip population
        return 
    end

    local localPlayer = getPlayer and getPlayer() or self.player
    local isLocalTarget = targetPlayer == localPlayer
    if not isLocalTarget and targetPlayer and localPlayer then
        local targetName = targetPlayer.getUsername and targetPlayer:getUsername() or nil
        local localName = localPlayer.getUsername and localPlayer:getUsername() or nil
        if targetName and localName and targetName == localName then
            isLocalTarget = true
        end
    end

    local bootstrapPlayer = isLocalTarget and localPlayer or targetPlayer
    if isLocalTarget
        and bootstrapPlayer
        and BurdJournals
        and BurdJournals.Client
        and BurdJournals.Client.tryBootstrapPendingNewCharacterBaseline then
        BurdJournals.Client.tryBootstrapPendingNewCharacterBaseline(bootstrapPlayer, "debug_panel_refresh", true)
    end
    
    -- Get player's XP object safely (same logic as Character tab)
    local xpObj = nil
    if targetPlayer and targetPlayer.getXp then
        xpObj = targetPlayer:getXp()
    end
    
    -- If we still don't have xpObj, try refreshing targetPlayer reference
    if not xpObj and targetPlayer and targetPlayer.getUsername then
        local username = targetPlayer:getUsername()
        if username then
            local onlinePlayers = getOnlinePlayers and getOnlinePlayers()
            if onlinePlayers then
                for i = 0, onlinePlayers:size() - 1 do
                    local p = onlinePlayers:get(i)
                    if p and p.getUsername and p:getUsername() == username then
                        targetPlayer = p
                        panel.targetPlayer = p  -- Update panel reference too
                        if p.getXp then
                            xpObj = p:getXp()
                        end
                        break
                    end
                end
            end
        end
    end

    -- Refresh skills list using enhanced metadata discovery
    if panel.baselineSkillList and panel.baselineSkillList.clear then
        panel.baselineSkillList:clear()
        
        -- Use enhanced skill metadata (includes modded skills with full info)
        local skillMetadata = nil
        if BurdJournals and BurdJournals.discoverSkillMetadata then
            skillMetadata = BurdJournals.discoverSkillMetadata()
        end
        
        -- Fallback to simple discovery if metadata not available
        if not skillMetadata then
            skillMetadata = {}
            local skills = {}
            if BurdJournals and BurdJournals.getAllowedSkills then
                local result = BurdJournals.getAllowedSkills()
                if result then skills = result end
            end
            for _, skillName in ipairs(skills) do
                skillMetadata[skillName] = {
                    id = skillName,
                    displayName = skillName,
                    category = "Unknown",
                    isVanilla = true,
                    isPassive = (skillName == "Fitness" or skillName == "Strength")
                }
            end
        end
        
        -- Sort skills by category then by display name
        local sortedSkills = {}
        for perkId, data in pairs(skillMetadata) do
            table.insert(sortedSkills, data)
        end
        table.sort(sortedSkills, function(a, b)
            -- Sort by category first, then by display name
            if a.category ~= b.category then
                return (a.category or "ZZZ") < (b.category or "ZZZ")
            end
            return (a.displayName or a.id) < (b.displayName or b.id)
        end)

        for _, skillData in ipairs(sortedSkills) do
            local skillName = skillData.id
            local currentLevel = 0
            local baselineLevel = 0
            local displayName = skillData.displayName or skillName
            local isPassive = skillData.isPassive or false
            local category = skillData.category or "Other"
            local isModded = not skillData.isVanilla
            
            -- Get perk object with fallbacks
            local perk = nil
            if BurdJournals and BurdJournals.getPerkByName then
                perk = BurdJournals.getPerkByName(skillName)
            end
            -- Fallback: try Perks directly
            if not perk and Perks then
                local perkId = skillData.perkId or skillName
                if Perks[perkId] then perk = Perks[perkId] end
            end
            
            -- Get current level and XP with multiple methods
            local currentXP = 0
            if perk and targetPlayer then
                -- Method 1: getPerkLevel (most reliable)
                if targetPlayer.getPerkLevel then
                    local result = targetPlayer:getPerkLevel(perk)
                    if type(result) == "number" then
                        currentLevel = result
                    end
                end
                
                -- Get current XP
                if xpObj and xpObj.getXP then
                    local xp = xpObj:getXP(perk)
                    if type(xp) == "number" then
                        currentXP = xp
                    end
                end
                
                -- Method 2: Calculate level from XP if getPerkLevel didn't work
                if currentLevel == 0 and currentXP > 0 then
                    -- Calculate level from XP using corrected helper
                    if BurdJournals.Client.Debug.getLevelFromXP then
                        currentLevel = BurdJournals.Client.Debug.getLevelFromXP(skillName, currentXP)
                    elseif perk.getTotalXpForLevel then
                        -- Fallback: getTotalXpForLevel(N) = XP to COMPLETE level N
                        -- So level N requires XP >= getTotalXpForLevel(N-1)
                        for l = 10, 1, -1 do
                            local threshold = perk:getTotalXpForLevel(l - 1) or 0
                            if currentXP >= threshold then
                                currentLevel = l
                                break
                            end
                        end
                    end
                end
            end
            
            -- Get baseline level
            if BurdJournals and BurdJournals.getSkillBaselineLevel then
                local lvl = BurdJournals.getSkillBaselineLevel(targetPlayer, skillName)
                if lvl and type(lvl) == "number" then 
                    baselineLevel = lvl 
                end
            elseif isPassive then
                baselineLevel = 5  -- Default for passive skills
            end

            -- Calculate baseline XP from baseline level
            -- Use our verified threshold tables for consistent values
            local baselineXP = 0
            if baselineLevel > 0 then
                if isPassive then
                    baselineXP = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[baselineLevel] or 37500
                else
                    baselineXP = BurdJournals.STANDARD_XP_THRESHOLDS and BurdJournals.STANDARD_XP_THRESHOLDS[baselineLevel] or 0
                end
            end

            -- Format display: add [MOD] prefix for modded skills
            local itemLabel = displayName
            if isModded then
                itemLabel = "[MOD] " .. displayName
            end

            panel.baselineSkillList:addItem(itemLabel, {
                name = skillName,
                displayName = displayName,
                currentLevel = currentLevel,
                currentXP = currentXP,
                baselineLevel = baselineLevel,
                baselineXP = baselineXP,
                isPassive = isPassive,
                category = category,
                isModded = isModded
            })
        end
    end

    -- Refresh traits list - show ALL traits for baseline management
    -- Uses comprehensive discovery (same as Spawn panel - includes modded and neutral traits)
    if panel.baselineTraitList and panel.baselineTraitList.clear then
        panel.baselineTraitList:clear()
        
        -- Use discoverGrantableTraits (includes negative traits for debug/baseline panel)
        -- This discovers ALL traits including modded ones and neutral/profession traits
        local discoveredTraits = {}
        if BurdJournals and BurdJournals.discoverGrantableTraits then
            local result = BurdJournals.discoverGrantableTraits(true)  -- true = include negative
            if result and type(result) == "table" then
                discoveredTraits = result
            end
        end
        
        -- Fallback to older methods if discovery failed
        if #discoveredTraits == 0 then
            local posTraits = BurdJournals.getPositiveTraits and BurdJournals.getPositiveTraits() or {}
            local negTraits = BurdJournals.getNegativeTraits and BurdJournals.getNegativeTraits() or {}
            for _, t in ipairs(posTraits) do table.insert(discoveredTraits, t) end
            for _, t in ipairs(negTraits) do table.insert(discoveredTraits, t) end
        end
        
        -- Get trait baseline data for the target player (case-insensitive lookup)
        local traitBaseline = {}
        local traitBaselineLower = {}  -- For case-insensitive lookup
        if BurdJournals and BurdJournals.getTraitBaseline then
            local result = BurdJournals.getTraitBaseline(targetPlayer)
            if result then 
                traitBaseline = result
            end
            -- Build lowercase lookup table
            for traitId, isBaseline in pairs(traitBaseline) do
                if isBaseline then
                    traitBaselineLower[string.lower(traitId)] = true
                end
            end
        end
        
        -- Build combined list of all traits with deduplication and polarity detection
        local sortedTraits = {}
        local addedTraits = {}  -- lowercase keys for deduplication
        
        -- Build a cost lookup for polarity detection
        local traitCostLookup = BurdJournals.UI.DebugPanel.buildTraitCostLookup()
        
        -- Add all discovered traits, deduplicating by DISPLAY NAME (not just ID)
        -- This handles B42's trait variants (e.g., AdrenalineJunkie and adrenalinejunkie2 both show "Adrenaline Junkie")
        local addedDisplayNames = {}  -- Track display names to prevent visual duplicates
        for _, traitId in ipairs(discoveredTraits) do
            local traitIdLower = string.lower(traitId)
            if not addedTraits[traitIdLower] then
                local displayName = traitId
                if BurdJournals and BurdJournals.getTraitDisplayName then
                    local name = BurdJournals.getTraitDisplayName(traitId)
                    if name then displayName = name end
                end
                
                -- Skip if we already have a trait with this display name (B42 variant handling)
                local displayNameLower = string.lower(displayName)
                if addedDisplayNames[displayNameLower] then
                    -- Skip this variant - we already have one with the same display name
                    -- Prefer non-"2" variants (e.g., prefer AdrenalineJunkie over adrenalinejunkie2)
                else
                    -- Determine polarity from cost
                    local cost = traitCostLookup[traitIdLower] or 0
                    local isPositive = cost >= 0  -- positive or neutral
                    
                    table.insert(sortedTraits, {
                        id = traitId,
                        displayName = displayName,
                        isPositive = isPositive,
                        isModded = false  -- Will be refined if needed
                    })
                    addedTraits[traitIdLower] = true
                    addedDisplayNames[displayNameLower] = traitId  -- Track by display name
                end
            end
        end
        
        -- Sort: positive first, then by display name
        table.sort(sortedTraits, function(a, b)
            if a.isPositive ~= b.isPositive then
                return a.isPositive  -- Positive traits first
            end
            return (a.displayName or a.id) < (b.displayName or b.id)
        end)
        
        BurdJournals.debugPrint("[BSJ DebugPanel] Showing " .. #sortedTraits .. " traits for baseline management")
        
        -- Add all traits to list
        for _, traitData in ipairs(sortedTraits) do
            local traitId = traitData.id
            local displayName = traitData.displayName or traitId
            local isPassiveSkillTrait = false
            
            -- Check if passive skill trait
            if BurdJournals and BurdJournals.isPassiveSkillTrait then
                isPassiveSkillTrait = BurdJournals.isPassiveSkillTrait(traitId) == true
            end
            
            -- Format display: add markers for negative traits
            local itemLabel = displayName
            if not traitData.isPositive then
                itemLabel = itemLabel .. " (-)"
            end
            
            -- Check if this trait is in baseline (case-insensitive)
            local isInBaseline = traitBaseline[traitId] or traitBaselineLower[string.lower(traitId)] or false
            
            panel.baselineTraitList:addItem(itemLabel, {
                id = traitId,
                displayName = displayName,
                isBaseline = isInBaseline,
                isPassiveSkillTrait = isPassiveSkillTrait,
                isPositive = traitData.isPositive,
                isModded = traitData.isModded or false
            })
        end
    end

end

function BurdJournals.UI.DebugPanel:updateBaselineDraftButtons()
    local panel = self.baselinePanel
    if not panel then
        return
    end
    local dirty = panel.baselineDraftDirty == true
    if panel.saveBaselineChangesBtn then
        panel.saveBaselineChangesBtn.enable = dirty
        panel.saveBaselineChangesBtn.textColor = dirty and {r=1, g=1, b=1, a=1} or {r=0.65, g=0.65, b=0.65, a=1}
    end
    if panel.discardBaselineChangesBtn then
        panel.discardBaselineChangesBtn.enable = dirty
        panel.discardBaselineChangesBtn.textColor = dirty and {r=1, g=1, b=1, a=1} or {r=0.65, g=0.65, b=0.65, a=1}
    end
end

function BurdJournals.UI.DebugPanel:markBaselineDraftDirty(message)
    local panel = self.baselinePanel
    if not panel then
        return
    end
    panel.baselineDraftDirty = true
    self:updateBaselineDraftButtons()
    self:setStatus(message or (getText("UI_BurdJournals_BaselineDraftPending") or "Baseline draft pending. Save to apply."), {r=0.95, g=0.8, b=0.4})
end

function BurdJournals.UI.DebugPanel:buildBaselineDraftPayload()
    local panel = self.baselinePanel
    if not panel then
        return nil
    end

    local skillBaseline = {}
    if panel.baselineSkillList and panel.baselineSkillList.items then
        for _, row in ipairs(panel.baselineSkillList.items) do
            local data = row and row.item
            if data and data.name then
                skillBaseline[tostring(data.name)] = math.max(0, math.floor(tonumber(data.baselineXP) or 0))
            end
        end
    end

    local traitBaseline = {}
    if panel.baselineTraitList and panel.baselineTraitList.items then
        for _, row in ipairs(panel.baselineTraitList.items) do
            local data = row and row.item
            if data and data.id and data.isBaseline then
                local aliases = BurdJournals.getTraitAliases and BurdJournals.getTraitAliases(data.id) or {data.id, string.lower(tostring(data.id))}
                for _, alias in ipairs(aliases) do
                    if alias and alias ~= "" then
                        traitBaseline[tostring(alias)] = true
                    end
                end
            end
        end
    end

    return {
        skillBaseline = skillBaseline,
        traitBaseline = traitBaseline,
    }
end

function BurdJournals.UI.DebugPanel.getPanelDimensions()
    local core = getCore and getCore() or nil
    local screenW = core and core.getScreenWidth and core:getScreenWidth() or BurdJournals.UI.DebugPanel.DEFAULT_WIDTH
    local screenH = core and core.getScreenHeight and core:getScreenHeight() or BurdJournals.UI.DebugPanel.DEFAULT_HEIGHT
    local margin = tonumber(BurdJournals.UI.DebugPanel.SCREEN_MARGIN) or 24

    local maxW = math.max(420, screenW - (margin * 2))
    local maxH = math.max(420, screenH - (margin * 2))
    local minW = math.max(420, tonumber(BurdJournals.UI.DebugPanel.MIN_WIDTH) or 760)
    local minH = math.max(420, tonumber(BurdJournals.UI.DebugPanel.MIN_HEIGHT) or 680)
    local defaultW = math.max(minW, tonumber(BurdJournals.UI.DebugPanel.DEFAULT_WIDTH) or 860)
    local defaultH = math.max(minH, tonumber(BurdJournals.UI.DebugPanel.DEFAULT_HEIGHT) or 760)

    local width = math.floor(math.max(minW, math.min(maxW, defaultW)))
    local height = math.floor(math.max(minH, math.min(maxH, defaultH)))
    return width, height
end

-- Draw function for skill items (read-only mode when baseline is disabled)
function BurdJournals.UI.DebugPanel.drawBaselineSkillItemReadOnly(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    -- Background
    if self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.3)
    end
    
    -- Skill name
    local textX = 8
    self:drawText(data.displayName, textX, y + 4, 0.9, 0.9, 0.9, 1, UIFont.Small)
    
    -- Current level
    local levelText = string.format(getText("UI_BurdJournals_LevelFormat"), tonumber(data.currentLevel) or 0)
    self:drawText(levelText, 150, y + 4, 0.5, 0.8, 0.6, 1, UIFont.Small)
    
    -- Squares showing current level + partial progress
    local squaresX = 230
    local squareSize = 14
    local squareSpacing = 2
    local currentLevel = tonumber(data.currentLevel) or 0
    local currentXP = tonumber(data.currentXP) or 0

    local progress = 0
    if currentLevel < 10 then
        local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(data.name)
        if perk and perk.getTotalXpForLevel then
            local levelStartXP = currentLevel > 0 and (perk:getTotalXpForLevel(currentLevel - 1) or 0) or 0
            local levelEndXP = perk:getTotalXpForLevel(currentLevel) or (levelStartXP + 150)
            local xpRange = levelEndXP - levelStartXP
            if xpRange > 0 then
                progress = math.max(0, math.min(1, (currentXP - levelStartXP) / xpRange))
            end
        end
    end
    
    for lvl = 1, 10 do
        local sqX = squaresX + (lvl - 1) * (squareSize + squareSpacing)
        local sqY = y + (h - squareSize) / 2
        
        if lvl <= currentLevel then
            -- Current level (filled)
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.9, 0.3, 0.6, 0.5)
        elseif lvl == currentLevel + 1 and progress > 0 then
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.12)
            local fillHeight = squareSize * progress
            self:drawRect(sqX, sqY + squareSize - fillHeight, squareSize, fillHeight, 0.8, 0.2, 0.4, 0.35)
        else
            -- Empty
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.12)
        end
        self:drawRectBorder(sqX, sqY, squareSize, squareSize, 0.4, 0.3, 0.35, 0.4)
    end
    
    return y + h
end

-- Filter functions for Baseline tab
function BurdJournals.UI.DebugPanel.filterBaselineSkillList(self)
    local panel = self.baselinePanel
    if not panel or not panel.baselineSkillList then return end
    
    local searchText = ""
    if panel.baselineSkillSearch and panel.baselineSkillSearch.getText then
        searchText = panel.baselineSkillSearch:getText()
    end
    
    for _, item in ipairs(panel.baselineSkillList.items) do
        if searchText == "" then
            item.item.hidden = false
        else
            item.item.hidden = not debugSearchMatches(searchText, item.item.displayName, item.item.name, item.item.category)
        end
    end
end

function BurdJournals.UI.DebugPanel.filterBaselineTraitList(self)
    local panel = self.baselinePanel
    if not panel or not panel.baselineTraitList then return end
    
    local searchText = ""
    if panel.baselineTraitSearch and panel.baselineTraitSearch.getText then
        searchText = panel.baselineTraitSearch:getText()
    end
    
    for _, item in ipairs(panel.baselineTraitList.items) do
        if searchText == "" then
            item.item.hidden = false
        else
            item.item.hidden = not debugSearchMatches(searchText, item.item.displayName, item.item.id)
        end
    end
end

-- Draw function for baseline skill items with interactive squares
function BurdJournals.UI.DebugPanel.drawBaselineSkillItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    local parentPanel = self.parentPanel
    local baselinePanel = parentPanel and parentPanel.baselinePanel
    
    -- Background
    if data.isPassive then
        self:drawRect(0, y, self.width, h, 0.15, 0.25, 0.2, 0.25)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.3)
    end
    
    -- Skill name
    local textX = 8
    local nameColor = data.isPassive and {0.7, 0.9, 0.8} or {0.9, 0.9, 0.9}
    self:drawText(data.displayName, textX, y + 4, nameColor[1], nameColor[2], nameColor[3], 1, UIFont.Small)
    
    -- Current level indicator
    local currentText = string.format(getText("UI_BurdJournals_LevelFormat"), tonumber(data.currentLevel) or 0)
    self:drawText(currentText, 130, y + 4, 0.5, 0.7, 0.9, 1, UIFont.Small)
    
    -- Interactive squares for baseline (10 squares) with progress visualization
    local squaresX = 175
    local squareSize = 14
    local squareSpacing = 2
    
    -- Calculate progress within current level (0-1) for baseline
    -- Use our verified threshold tables for consistent values
    local baselineProgress = 0
    local baselineLevel = data.baselineLevel or 0
    local baselineXP = data.baselineXP or 0
    local isPassive = data.isPassive or (data.name == "Fitness" or data.name == "Strength")
    local thresholds = isPassive and BurdJournals.PASSIVE_XP_THRESHOLDS or BurdJournals.STANDARD_XP_THRESHOLDS
    
    if baselineLevel < 10 and thresholds then
        local levelStartXP = thresholds[baselineLevel] or 0
        local levelEndXP = thresholds[baselineLevel + 1] or (levelStartXP + 150)
        local xpRange = levelEndXP - levelStartXP
        if xpRange > 0 then
            baselineProgress = math.max(0, math.min(1, (baselineXP - levelStartXP) / xpRange))
        end
    end
    
    -- Calculate progress for current (earned) level
    local currentProgress = 0
    local currentLevel = data.currentLevel or 0
    local currentXP = data.currentXP or 0
    
    if currentLevel < 10 and thresholds then
        local levelStartXP = thresholds[currentLevel] or 0
        local levelEndXP = thresholds[currentLevel + 1] or (levelStartXP + 150)
        local xpRange = levelEndXP - levelStartXP
        if xpRange > 0 then
            currentProgress = math.max(0, math.min(1, (currentXP - levelStartXP) / xpRange))
        end
    end
    
    for lvl = 1, 10 do
        local sqX = squaresX + (lvl - 1) * (squareSize + squareSpacing)
        local sqY = y + (h - squareSize) / 2
        
        -- Determine square color based on level relationships
        if lvl <= baselineLevel then
            -- Baseline level (filled, darker tone)
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.9, 0.4, 0.3, 0.25)
        elseif lvl == baselineLevel + 1 and baselineProgress > 0 and lvl > currentLevel then
            -- Baseline has partial progress in this square but no earned XP beyond it
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.12)
            local fillHeight = squareSize * baselineProgress
            self:drawRect(sqX, sqY + squareSize - fillHeight, squareSize, fillHeight, 0.6, 0.35, 0.28, 0.22)
        elseif lvl == baselineLevel + 1 and lvl <= currentLevel then
            -- Transition square: baseline progress + earned portion
            if baselineProgress > 0 then
                local baselineFillHeight = squareSize * baselineProgress
                self:drawRect(sqX, sqY + squareSize - baselineFillHeight, squareSize, baselineFillHeight, 0.6, 0.35, 0.28, 0.22)
            end
            local earnedPortion = 1.0 - baselineProgress
            if earnedPortion > 0 then
                local earnedFillHeight = squareSize * earnedPortion
                self:drawRect(sqX, sqY, squareSize, earnedFillHeight, 0.9, 0.3, 0.6, 0.5)
            end
        elseif lvl <= currentLevel then
            -- Earned level beyond baseline (bright)
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.9, 0.3, 0.6, 0.5)
        elseif lvl == currentLevel + 1 and currentProgress > 0 then
            -- Partial progress on current earned level
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.12)
            local fillHeight = squareSize * currentProgress
            self:drawRect(sqX, sqY + squareSize - fillHeight, squareSize, fillHeight, 0.8, 0.2, 0.4, 0.35)
        else
            -- Empty (not reached)
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.1, 0.1, 0.12)
        end
        
        -- Border - highlight baseline square
        if lvl == baselineLevel and baselineLevel > 0 then
            self:drawRectBorder(sqX, sqY, squareSize, squareSize, 0.9, 0.9, 0.7, 0.4)
        else
            self:drawRectBorder(sqX, sqY, squareSize, squareSize, 0.4, 0.3, 0.35, 0.4)
        end
    end
    
    -- XP display (simple text after squares)
    local squaresEndX = squaresX + 10 * (squareSize + squareSpacing)
    local xpDisplayX = squaresEndX + 8
    local baselineXP = data.baselineXP or 0
    
    -- Format XP display
    local xpText = tostring(math.floor(baselineXP)) .. " XP"
    self:drawText(xpText, xpDisplayX, y + 4, 0.6, 0.5, 0.4, 1, UIFont.Small)
    
    return y + h
end

-- Click handler for baseline skill list (detects square clicks)
function BurdJournals.UI.DebugPanel.onBaselineSkillListClick(self, x, y)
    ISScrollingListBox.onMouseDown(self, x, y)
    
    local row = self:rowAt(x, y)
    if row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    local data = item.item
    local parentPanel = self.parentPanel
    local baselinePanel = parentPanel and parentPanel.baselinePanel
    local targetPlayer = baselinePanel and baselinePanel.targetPlayer or parentPanel.player
    
    -- Check if click is in the squares area
    local squaresX = 175
    local squareSize = 14
    local squareSpacing = 2
    local squaresEndX = squaresX + 10 * (squareSize + squareSpacing)
    
    if x >= squaresX and x < squaresEndX then
        -- Calculate which square was clicked
        local relX = x - squaresX
        local clickedLevel = math.floor(relX / (squareSize + squareSpacing)) + 1
        clickedLevel = math.max(0, math.min(10, clickedLevel))
        
        -- Handle click on same level = set to 0 (toggle off)
        if clickedLevel == data.baselineLevel then
            clickedLevel = 0
        end
        
        data.baselineLevel = clickedLevel

        local baselineXP = 0
        if clickedLevel > 0 then
            local isPassive = (data.name == "Fitness" or data.name == "Strength")
            if isPassive then
                baselineXP = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[clickedLevel] or 37500
            else
                baselineXP = BurdJournals.STANDARD_XP_THRESHOLDS and BurdJournals.STANDARD_XP_THRESHOLDS[clickedLevel] or 0
            end
        end
        data.baselineXP = baselineXP

        if baselinePanel then
            baselinePanel.baselineDraftSkills = baselinePanel.baselineDraftSkills or {}
            baselinePanel.baselineDraftSkills[data.name] = baselineXP
        end
        if parentPanel.markBaselineDraftDirty then
            parentPanel:markBaselineDraftDirty("Draft: " .. data.displayName .. " baseline set to level " .. clickedLevel .. ". Save to apply.")
        end
    end
end

-- Draw function for baseline trait items with checkbox
function BurdJournals.UI.DebugPanel.drawBaselineTraitItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    
    -- Skip hidden items (filtered by search)
    if data.hidden then return y + h end
    
    -- Background for passive skill traits (can't be toggled)
    if data.isPassiveSkillTrait then
        self:drawRect(0, y, self.width, h, 0.15, 0.2, 0.15, 0.15)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.3)
    end
    
    -- Checkbox
    local checkX = 8
    if data.isPassiveSkillTrait then
        -- Passive skill traits show as locked
        self:drawText("[~]", checkX, y + 2, 0.4, 0.4, 0.4, 1, UIFont.Small)
    elseif data.isBaseline then
        self:drawText("[X]", checkX, y + 2, 0.4, 0.7, 0.4, 1, UIFont.Small)
    else
        self:drawText("[ ]", checkX, y + 2, 0.5, 0.5, 0.5, 1, UIFont.Small)
    end
    
    -- Trait name
    local textX = 35
    local nameColor
    if data.isPassiveSkillTrait then
        nameColor = {0.5, 0.5, 0.5}  -- Dimmed for passive skill traits
    elseif data.isBaseline then
        nameColor = {0.8, 1, 0.8}
    else
        nameColor = {0.7, 0.7, 0.7}
    end
    self:drawText(data.displayName, textX, y + 2, nameColor[1], nameColor[2], nameColor[3], 1, UIFont.Small)
    
    -- Status indicator (account for scrollbar)
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH
    if data.isPassiveSkillTrait then
        self:drawText("(auto)", self.width - 50 - scrollOffset, y + 2, 0.4, 0.4, 0.4, 1, UIFont.Small)
    elseif data.isBaseline then
        self:drawText("Starting", self.width - 55 - scrollOffset, y + 2, 0.5, 0.65, 0.5, 1, UIFont.Small)
    end
    
    return y + h
end

-- Click handler for baseline trait list
function BurdJournals.UI.DebugPanel.onBaselineTraitListClick(self, x, y)
    ISScrollingListBox.onMouseDown(self, x, y)
    
    local row = self:rowAt(x, y)
    if row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    local data = item.item
    local parentPanel = self.parentPanel
    local baselinePanel = parentPanel and parentPanel.baselinePanel
    local targetPlayer = baselinePanel and baselinePanel.targetPlayer or parentPanel.player
    
    -- Don't allow toggling passive skill traits
    if data.isPassiveSkillTrait then
        parentPanel:setStatus("Passive skill traits cannot be modified", {r=1, g=0.6, b=0.3})
        return
    end
    
    -- Toggle baseline status
    local newStatus = not data.isBaseline
    
    data.isBaseline = newStatus
    if baselinePanel then
        baselinePanel.baselineDraftTraits = baselinePanel.baselineDraftTraits or {}
        baselinePanel.baselineDraftTraits[data.id] = newStatus == true
    end
    if parentPanel.markBaselineDraftDirty then
        local statusText = newStatus and "added to" or "removed from"
        parentPanel:markBaselineDraftDirty("Draft: " .. data.displayName .. " " .. statusText .. " baseline. Save to apply.")
    end
end

function BurdJournals.UI.DebugPanel.onBaselineSnapshotFilterChanged(self)
    if self and self.requestBaselineSnapshots then
        self:requestBaselineSnapshots()
    end
    if self and self.requestSnapshotLiveBaselinePayload then
        self:requestSnapshotLiveBaselinePayload()
    end
end

local function snapshotFormatEpochMsForUI(epochMs)
    local ms = tonumber(epochMs)
    if not ms or ms <= 0 or not (os and os.date) then
        return nil
    end
    local ok, value = pcall(os.date, "%Y-%m-%d %H:%M:%S", math.floor(ms / 1000))
    if ok and value and value ~= "" then
        return tostring(value)
    end
    return nil
end

local function snapshotGetRealStamp(snapshot, prefix)
    local key = tostring(prefix or "captured")
    local localField = tostring(key .. "AtLocal")
    local isoField = tostring(key .. "AtIsoUtc")
    local epochField = tostring(key .. "AtEpochMs")
    local localStamp = snapshot and snapshot[localField] or nil
    if localStamp and tostring(localStamp) ~= "" then
        return tostring(localStamp)
    end
    local isoStamp = snapshot and snapshot[isoField] or nil
    if isoStamp and tostring(isoStamp) ~= "" then
        return tostring(isoStamp)
    end
    return snapshotFormatEpochMsForUI(snapshot and snapshot[epochField] or nil)
end

local function formatSnapshotSummaryLine(snapshot)
    local counts = snapshot and snapshot.counts or {}
    local skills = tonumber(counts and counts.skills) or 0
    local media = tonumber(counts and counts.mediaSkills) or 0
    local traits = tonumber(counts and counts.traits) or 0
    local recipes = tonumber(counts and counts.recipes) or 0
    local source = tostring(snapshot and snapshot.source or "?")
    local who = tostring(snapshot and (snapshot.characterName or snapshot.username or snapshot.characterId) or "Unknown")
    local captured = tonumber(snapshot and snapshot.capturedAtHours) or 0
    local stamp = string.format("%.1fh", captured)
    local realStamp = snapshotGetRealStamp(snapshot, "captured")
    if snapshot and snapshot.endedReason and snapshot.endedReason ~= "" then
        source = source .. "/" .. tostring(snapshot.endedReason)
    end
    if realStamp and realStamp ~= "" then
        return string.format("[%s] %s @ %s | RL %s (%dS %dM %dT %dR)", source, who, stamp, realStamp, skills, media, traits, recipes)
    end
    return string.format("[%s] %s @ %s (%dS %dM %dT %dR)", source, who, stamp, skills, media, traits, recipes)
end

local function trimSnapshotText(text, maxChars)
    local value = tostring(text or "")
    local limit = math.max(8, tonumber(maxChars) or 64)
    if #value <= limit then
        return value
    end
    return string.sub(value, 1, limit - 3) .. "..."
end

local function getSnapshotPanel(self)
    if self and self.snapshotPanel and self.snapshotPanel.snapshotList then
        return self.snapshotPanel
    end
    if self and self.baselinePanel and self.baselinePanel.snapshotList then
        return self.baselinePanel
    end
    return nil
end

function BurdJournals.UI.DebugPanel:populateSnapshotPlayerList()
    local panel = getSnapshotPanel(self)
    if not panel or not panel.snapshotTargetCombo then
        return
    end

    local selectedName = panel.targetPlayer and panel.targetPlayer.getUsername and panel.targetPlayer:getUsername() or nil
    panel.snapshotTargetCombo:clear()
    local currentName = self.player and self.player:getUsername() or "You"
    panel.snapshotTargetCombo:addOptionWithData(currentName, self.player)

    if self:canTargetOtherPlayers() then
        local onlinePlayers = getOnlinePlayers()
        if onlinePlayers then
            for i = 0, onlinePlayers:size() - 1 do
                local otherPlayer = onlinePlayers:get(i)
                if otherPlayer and otherPlayer ~= self.player then
                    local name = otherPlayer:getUsername() or "Unknown"
                    panel.snapshotTargetCombo:addOptionWithData(name, otherPlayer)
                end
            end
        end
    end

    if selectedName and selectedName ~= "" then
        panel.snapshotTargetCombo:select(selectedName)
    else
        panel.snapshotTargetCombo:select(currentName)
    end
    if not panel.targetPlayer then
        panel.targetPlayer = self.player
    end
end

function BurdJournals.UI.DebugPanel:onSnapshotTargetPlayerChange(combo)
    local panel = getSnapshotPanel(self)
    if not panel then
        return
    end

    local selected = combo:getSelectedIndex()
    local data = combo.options[selected + 1]
    if data and data.data then
        if data.data ~= self.player and not self:canTargetOtherPlayers() then
            local currentName = self.player and self.player:getUsername() or "You"
            combo:select(currentName)
            panel.targetPlayer = self.player
            self:setStatus(getText("UI_BurdJournals_AdminOnly") or "This command requires admin access.", {r=1, g=0.6, b=0.3})
            return
        end
        panel.targetPlayer = data.data
        self:refreshSnapshotPanelData()
        self:setStatus("Viewing snapshots for: " .. (panel.targetPlayer:getUsername() or "Unknown"), {r=0.5, g=0.8, b=1})
    end
end

function BurdJournals.UI.DebugPanel:refreshSnapshotPanelData()
    local panel = getSnapshotPanel(self)
    if not panel then
        return
    end
    if not panel.targetPlayer then
        panel.targetPlayer = self.player
    end
    if self.requestBaselineSnapshots then
        self:requestBaselineSnapshots()
    end
    if self.requestSnapshotLiveBaselinePayload then
        self:requestSnapshotLiveBaselinePayload()
    end
end

function BurdJournals.UI.DebugPanel.drawBaselineSnapshotItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    if not data then
        return y + h
    end

    local isSelected = self.selected == item.index
    if isSelected then
        self:drawRect(0, y, self.width, h, 0.38, 0.28, 0.5, 0.34)
        self:drawRectBorder(0, y, self.width, h, 0.75, 0.62, 0.9, 0.6)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.25, 0.22, 0.3, 0.38)
    elseif item.index % 2 == 0 then
        self:drawRect(0, y, self.width, h, 0.08, 0.08, 0.1, 0.35)
    end

    local source = tostring(data.source or "?")
    local who = tostring(data.characterName or data.username or data.characterId or "Unknown")
    local captured = tonumber(data.capturedAtHours) or 0
    local counts = data.counts or {}
    local mode = data.isProtected and "protected" or "unlocked"
    local ended = data.endedReason and (" | ended:" .. tostring(data.endedReason)) or ""
    local realStamp = snapshotGetRealStamp(data, "captured")
    local line1 = string.format("[%s] %s @ %.1fh", source, who, captured)
    local line2 = string.format(
        "%dS %dM %dT %dR | %s%s",
        tonumber(counts.skills) or 0,
        tonumber(counts.mediaSkills) or 0,
        tonumber(counts.traits) or 0,
        tonumber(counts.recipes) or 0,
        mode,
        ended
    )
    if realStamp and realStamp ~= "" then
        line2 = line2 .. " | RL " .. tostring(realStamp)
    end
    local charsPerLine = math.max(34, math.floor((self.width - 14) / 6))
    self:drawText(trimSnapshotText(line1, charsPerLine), 6, y + 3, 0.92, 0.92, 0.97, 1, UIFont.Small)
    self:drawText(trimSnapshotText(line2, charsPerLine + 6), 6, y + 18, 0.72, 0.8, 0.92, 1, UIFont.Small)
    return y + h
end

function BurdJournals.UI.DebugPanel.onBaselineSnapshotListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    local parentPanel = self.parentPanel
    if not parentPanel then
        return
    end
    local panel = getSnapshotPanel(parentPanel)
    if not panel then
        return
    end
    local selected = self.items and self.items[self.selected]
    local selectedData = selected and selected.item or nil
    if not selectedData then
        return
    end
    panel.snapshotSelectedId = selectedData.snapshotId
    panel.snapshotSelectedData = selectedData
    if parentPanel.refreshBaselineSnapshotDetail then
        parentPanel:refreshBaselineSnapshotDetail()
    end
    if BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.getBaselineSnapshot then
        BurdJournals.Client.Debug.getBaselineSnapshot(selectedData.snapshotId, parentPanel.player)
    end
    if parentPanel.requestSnapshotLiveBaselinePayload then
        parentPanel:requestSnapshotLiveBaselinePayload()
    end
end

function BurdJournals.UI.DebugPanel:getBaselineSnapshotFilterPayload()
    local panel = getSnapshotPanel(self)
    if not panel then
        return nil
    end
    local payload = {
        includeDead = true,
        page = panel.snapshotCurrentPage or 1,
        pageSize = panel.snapshotPageSize or 20,
    }

    local query = panel.snapshotSearch and panel.snapshotSearch.getText and panel.snapshotSearch:getText() or ""
    if query and query ~= "" then
        payload.query = query
    end

    local filterMode = "target"
    if panel.snapshotFilterCombo and panel.snapshotFilterCombo.options and panel.snapshotFilterCombo.selected > 0 then
        local option = panel.snapshotFilterCombo.options[panel.snapshotFilterCombo.selected]
        if option and option.data then
            filterMode = tostring(option.data)
        end
    end

    local targetPlayer = panel.targetPlayer or self.player
    if filterMode == "steam" then
        local steamId = targetPlayer and BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(targetPlayer) or nil
        if steamId and steamId ~= "" then
            payload.steamId = tostring(steamId)
        else
            payload.targetUsername = targetPlayer and targetPlayer.getUsername and targetPlayer:getUsername() or nil
        end
    elseif filterMode == "character" then
        payload.useTargetCharacterId = true
        local characterId = targetPlayer and BurdJournals.getPlayerCharacterId and BurdJournals.getPlayerCharacterId(targetPlayer) or nil
        if characterId and characterId ~= "" then
            payload.characterId = tostring(characterId)
        else
            payload.targetUsername = targetPlayer and targetPlayer.getUsername and targetPlayer:getUsername() or nil
        end
    else
        local steamId = targetPlayer and BurdJournals.getPlayerSteamId and BurdJournals.getPlayerSteamId(targetPlayer) or nil
        if steamId and steamId ~= "" then
            payload.steamId = tostring(steamId)
        else
            payload.targetUsername = targetPlayer and targetPlayer.getUsername and targetPlayer:getUsername() or nil
        end
    end
    return payload
end

function BurdJournals.UI.DebugPanel:requestBaselineSnapshots()
    local payload = self:getBaselineSnapshotFilterPayload()
    if not payload then
        return
    end
    if BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.listBaselineSnapshots then
        BurdJournals.Client.Debug.listBaselineSnapshots(payload, self.player)
    elseif sendClientCommand then
        sendClientCommand("BurdJournals", "debugListBaselineSnapshots", payload)
    end
end

function BurdJournals.UI.DebugPanel:requestSnapshotLiveBaselinePayload()
    local panel = getSnapshotPanel(self)
    if not panel then
        return
    end
    local targetPlayer = panel.targetPlayer or self.player
    local targetUsername = targetPlayer and targetPlayer.getUsername and targetPlayer:getUsername() or nil
    if BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.getTargetBaselinePayload then
        BurdJournals.Client.Debug.getTargetBaselinePayload({
            targetUsername = targetUsername
        }, self.player)
    elseif sendClientCommand then
        sendClientCommand("BurdJournals", "debugGetTargetBaselinePayload", {
            targetUsername = targetUsername
        })
    end
end

local function snapshotGetSkillDisplayName(skillName)
    if BurdJournals and BurdJournals.getSkillDisplayName then
        local displayName = BurdJournals.getSkillDisplayName(skillName)
        if displayName and displayName ~= "" then
            return displayName
        end
    end
    return tostring(skillName or "Unknown")
end

local function snapshotGetThresholds(skillName)
    local isPassive = skillName == "Fitness" or skillName == "Strength"
    return isPassive and BurdJournals.PASSIVE_XP_THRESHOLDS or BurdJournals.STANDARD_XP_THRESHOLDS
end

local function snapshotLevelProgressFromXP(skillName, xp)
    local value = math.max(0, tonumber(xp) or 0)
    local thresholds = snapshotGetThresholds(skillName) or {}
    local level = 0
    for l = 10, 1, -1 do
        local threshold = tonumber(thresholds[l]) or 0
        if value >= threshold then
            level = l
            break
        end
    end
    local progress = 0
    if level < 10 then
        local levelStart = tonumber(thresholds[level]) or 0
        local levelEnd = tonumber(thresholds[level + 1]) or (levelStart + 150)
        local range = levelEnd - levelStart
        if range > 0 then
            progress = math.max(0, math.min(1, (value - levelStart) / range))
        end
    end
    return level, progress
end

local function snapshotBuildBooleanDiffRows(liveData, snapshotData, labelFn)
    local rows = {}
    local seen = {}
    local keys = {}

    liveData = type(liveData) == "table" and liveData or {}
    snapshotData = type(snapshotData) == "table" and snapshotData or {}

    for key, value in pairs(liveData) do
        if value == true then
            local id = tostring(key)
            if not seen[id] then
                seen[id] = true
                keys[#keys + 1] = id
            end
        end
    end
    for key, value in pairs(snapshotData) do
        if value == true then
            local id = tostring(key)
            if not seen[id] then
                seen[id] = true
                keys[#keys + 1] = id
            end
        end
    end

    table.sort(keys)
    for _, key in ipairs(keys) do
        local inLive = liveData[key] == true
        local inSnapshot = snapshotData[key] == true
        if inSnapshot and (not inLive) then
            rows[#rows + 1] = {kind = "added", text = (labelFn and labelFn(key) or key)}
        elseif inLive and (not inSnapshot) then
            rows[#rows + 1] = {kind = "removed", text = (labelFn and labelFn(key) or key)}
        end
    end
    return rows
end

local function snapshotBuildMediaDiffRows(liveData, snapshotData, labelFn)
    local rows = {}
    local seen = {}
    local keys = {}

    liveData = type(liveData) == "table" and liveData or {}
    snapshotData = type(snapshotData) == "table" and snapshotData or {}

    for key in pairs(liveData) do
        local id = tostring(key)
        if not seen[id] then
            seen[id] = true
            keys[#keys + 1] = id
        end
    end
    for key in pairs(snapshotData) do
        local id = tostring(key)
        if not seen[id] then
            seen[id] = true
            keys[#keys + 1] = id
        end
    end

    table.sort(keys)
    for _, key in ipairs(keys) do
        local liveXP = tonumber(liveData[key]) or 0
        local newXP = tonumber(snapshotData[key]) or 0
        local hasLive = liveData[key] ~= nil and liveXP > 0
        local hasNew = snapshotData[key] ~= nil and newXP > 0
        local label = (labelFn and labelFn(key) or key)
        if hasNew and (not hasLive) then
            rows[#rows + 1] = {kind = "added", text = string.format("%s (+%d XP)", label, newXP)}
        elseif hasLive and (not hasNew) then
            rows[#rows + 1] = {kind = "removed", text = string.format("%s (-%d XP)", label, liveXP)}
        elseif hasLive and hasNew and liveXP ~= newXP then
            local delta = newXP - liveXP
            rows[#rows + 1] = {kind = "changed", text = string.format("%s (%+d XP)", label, delta)}
        end
    end
    return rows
end

local function snapshotBuildSkillRows(liveSkills, snapshotSkills)
    local rows = {}
    local keys = {}
    local seen = {}

    liveSkills = type(liveSkills) == "table" and liveSkills or {}
    snapshotSkills = type(snapshotSkills) == "table" and snapshotSkills or {}

    for key in pairs(liveSkills) do
        local id = tostring(key)
        if not seen[id] then
            seen[id] = true
            keys[#keys + 1] = id
        end
    end
    for key in pairs(snapshotSkills) do
        local id = tostring(key)
        if not seen[id] then
            seen[id] = true
            keys[#keys + 1] = id
        end
    end

    table.sort(keys, function(a, b)
        return snapshotGetSkillDisplayName(a) < snapshotGetSkillDisplayName(b)
    end)

    for _, skillName in ipairs(keys) do
        local liveXP = tonumber(liveSkills[skillName]) or 0
        local newXP = tonumber(snapshotSkills[skillName]) or 0
        local liveLevel, liveProgress = snapshotLevelProgressFromXP(skillName, liveXP)
        local newLevel, newProgress = snapshotLevelProgressFromXP(skillName, newXP)
        rows[#rows + 1] = {
            name = skillName,
            displayName = snapshotGetSkillDisplayName(skillName),
            isPassive = (skillName == "Fitness" or skillName == "Strength"),
            liveXP = liveXP,
            snapshotXP = newXP,
            liveLevel = liveLevel,
            snapshotLevel = newLevel,
            liveProgress = liveProgress,
            snapshotProgress = newProgress,
            deltaXP = newXP - liveXP,
            deltaLevel = newLevel - liveLevel,
        }
    end
    return rows
end

function BurdJournals.UI.DebugPanel:refreshBaselineSnapshotPreview()
    local panel = getSnapshotPanel(self)
    if not panel then
        return
    end

    local snapshot = panel.snapshotSelectedData
    local livePayload = panel.snapshotLiveBaselinePayload or {}
    local snapshotPayload = snapshot or {}

    local liveSkills = type(livePayload.skillBaseline) == "table" and livePayload.skillBaseline or {}
    local newSkills = type(snapshotPayload.skillBaseline) == "table" and snapshotPayload.skillBaseline or {}
    local liveTraits = type(livePayload.traitBaseline) == "table" and livePayload.traitBaseline or {}
    local newTraits = type(snapshotPayload.traitBaseline) == "table" and snapshotPayload.traitBaseline or {}
    local liveRecipes = type(livePayload.recipeBaseline) == "table" and livePayload.recipeBaseline or {}
    local newRecipes = type(snapshotPayload.recipeBaseline) == "table" and snapshotPayload.recipeBaseline or {}
    local liveMedia = type(livePayload.mediaSkillBaseline) == "table" and livePayload.mediaSkillBaseline or {}
    local newMedia = type(snapshotPayload.mediaSkillBaseline) == "table" and snapshotPayload.mediaSkillBaseline or {}

    panel.snapshotPreviewRows = snapshotBuildSkillRows(liveSkills, newSkills)
    panel.snapshotTraitDiffRows = snapshotBuildBooleanDiffRows(liveTraits, newTraits, function(id) return BurdJournals.getTraitDisplayName and BurdJournals.getTraitDisplayName(id) or id end)
    panel.snapshotRecipeDiffRows = snapshotBuildBooleanDiffRows(liveRecipes, newRecipes, function(id) return id end)
    panel.snapshotMediaDiffRows = snapshotBuildMediaDiffRows(liveMedia, newMedia, snapshotGetSkillDisplayName)

    if panel.snapshotSkillPreviewList then
        panel.snapshotSkillPreviewList:clear()
        if #panel.snapshotPreviewRows == 0 then
            panel.snapshotSkillPreviewList:addItem(getText("UI_BurdJournals_SnapshotPreviewNoSkills") or "No skill baseline differences.", {isHeader = true, text = getText("UI_BurdJournals_SnapshotPreviewNoSkills") or "No skill baseline differences."})
        else
            for _, row in ipairs(panel.snapshotPreviewRows) do
                panel.snapshotSkillPreviewList:addItem(row.displayName, row)
            end
        end
    end

    if panel.snapshotTraitDiffList then
        panel.snapshotTraitDiffList:clear()
        panel.snapshotTraitDiffList:addItem(getText("UI_BurdJournals_SnapshotPreviewTraitsTitle") or "Traits", {isHeader = true, text = getText("UI_BurdJournals_SnapshotPreviewTraitsTitle") or "Traits"})
        if #panel.snapshotTraitDiffRows == 0 then
            panel.snapshotTraitDiffList:addItem(getText("UI_BurdJournals_SnapshotPreviewNoTraitDiff") or "No trait changes", {kind = "neutral", text = getText("UI_BurdJournals_SnapshotPreviewNoTraitDiff") or "No trait changes"})
        else
            for _, row in ipairs(panel.snapshotTraitDiffRows) do
                panel.snapshotTraitDiffList:addItem(row.text, row)
            end
        end
    end

    if panel.snapshotRecipeDiffList then
        panel.snapshotRecipeDiffList:clear()
        panel.snapshotRecipeDiffList:addItem(getText("UI_BurdJournals_SnapshotPreviewRecipesTitle") or "Recipes", {isHeader = true, text = getText("UI_BurdJournals_SnapshotPreviewRecipesTitle") or "Recipes"})
        if #panel.snapshotRecipeDiffRows == 0 then
            panel.snapshotRecipeDiffList:addItem(getText("UI_BurdJournals_SnapshotPreviewNoRecipeDiff") or "No recipe changes", {kind = "neutral", text = getText("UI_BurdJournals_SnapshotPreviewNoRecipeDiff") or "No recipe changes"})
        else
            for _, row in ipairs(panel.snapshotRecipeDiffRows) do
                panel.snapshotRecipeDiffList:addItem(row.text, row)
            end
        end
    end

    if panel.snapshotMediaDiffList then
        panel.snapshotMediaDiffList:clear()
        panel.snapshotMediaDiffList:addItem(getText("UI_BurdJournals_SnapshotPreviewMediaTitle") or "Media Skills", {isHeader = true, text = getText("UI_BurdJournals_SnapshotPreviewMediaTitle") or "Media Skills"})
        if #panel.snapshotMediaDiffRows == 0 then
            panel.snapshotMediaDiffList:addItem(getText("UI_BurdJournals_SnapshotPreviewNoMediaDiff") or "No media changes", {kind = "neutral", text = getText("UI_BurdJournals_SnapshotPreviewNoMediaDiff") or "No media changes"})
        else
            for _, row in ipairs(panel.snapshotMediaDiffRows) do
                panel.snapshotMediaDiffList:addItem(row.text, row)
            end
        end
    end
end

function BurdJournals.UI.DebugPanel:applySnapshotLiveBaselinePayload(payloadArgs)
    local panel = getSnapshotPanel(self)
    if not panel then
        return
    end

    local payload = payloadArgs and payloadArgs.baselinePayload or nil
    panel.snapshotLiveBaselinePayload = type(payload) == "table" and payload or nil

    local counts = payloadArgs and payloadArgs.counts or {}
    local currentLabel = getText("UI_BurdJournals_SnapshotCurrentBaselineLabel") or "Current baseline comparison: server payload loaded."
    if panel.snapshotLiveBaselinePayload then
        currentLabel = string.format(
            "%s %dS %dM %dT %dR",
            getText("UI_BurdJournals_SnapshotCurrentBaselineLoaded") or "Current baseline:",
            tonumber(counts.skills) or 0,
            tonumber(counts.mediaSkills) or 0,
            tonumber(counts.traits) or 0,
            tonumber(counts.recipes) or 0
        )
    else
        currentLabel = getText("UI_BurdJournals_SnapshotCurrentBaselineMissing") or "No authoritative baseline payload available for target."
    end
    if panel.snapshotCurrentLabel then
        panel.snapshotCurrentLabel:setName(currentLabel)
    end
    self:refreshBaselineSnapshotPreview()
end

function BurdJournals.UI.DebugPanel.drawSnapshotSkillPreviewItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    if not data then
        return y + h
    end
    if data.isHeader then
        self:drawText(tostring(data.text or ""), 6, y + 8, 0.7, 0.75, 0.85, 1, UIFont.Small)
        return y + h
    end

    if self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.3)
    elseif item.index % 2 == 0 then
        self:drawRect(0, y, self.width, h, 0.08, 0.08, 0.1, 0.35)
    end

    local name = tostring(data.displayName or data.name or "Unknown")
    local deltaXP = tonumber(data.deltaXP) or 0
    local liveLevel = tonumber(data.liveLevel) or 0
    local newLevel = tonumber(data.snapshotLevel) or 0
    local deltaColor = {0.75, 0.75, 0.8}
    if deltaXP > 0 then
        deltaColor = {0.4, 0.95, 0.5}
    elseif deltaXP < 0 then
        deltaColor = {0.95, 0.45, 0.45}
    end

    self:drawText(name, 6, y + 3, 0.9, 0.9, 0.95, 1, UIFont.Small)
    self:drawText(string.format("Now Lv %d -> After Lv %d | XP %+d", liveLevel, newLevel, deltaXP), 6, y + 16, deltaColor[1], deltaColor[2], deltaColor[3], 1, UIFont.Small)

    local squareSize = 10
    local squareGap = 2
    local scrollOffset = tonumber(BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH) or 15
    local squaresX = self.width - ((squareSize + squareGap) * 10) - scrollOffset - 6
    local squaresY = y + 5
    local newProgress = tonumber(data.snapshotProgress) or 0
    local liveProgress = tonumber(data.liveProgress) or 0

    for lvl = 1, 10 do
        local sx = squaresX + (lvl - 1) * (squareSize + squareGap)
        local sy = squaresY
        self:drawRect(sx, sy, squareSize, squareSize, 0.5, 0.1, 0.1, 0.12)

        if lvl <= newLevel then
            self:drawRect(sx, sy, squareSize, squareSize, 0.62, 0.34, 0.78, 0.55)
        elseif lvl == (newLevel + 1) and newProgress > 0 then
            local fillH = squareSize * newProgress
            self:drawRect(sx, sy + squareSize - fillH, squareSize, fillH, 0.62, 0.34, 0.78, 0.55)
        end

        if lvl <= liveLevel then
            self:drawRectBorder(sx + 1, sy + 1, squareSize - 2, squareSize - 2, 0.6, 0.82, 0.9, 0.45)
        elseif lvl == (liveLevel + 1) and liveProgress > 0 then
            local liveFill = math.max(1, math.floor(squareSize * liveProgress))
            self:drawRect(sx + 1, sy + 1, math.max(1, squareSize - 2), math.min(squareSize - 2, liveFill), 0.5, 0.8, 0.9, 0.4)
        end

        self:drawRectBorder(sx, sy, squareSize, squareSize, 0.42, 0.34, 0.46, 0.6)
    end
    return y + h
end

function BurdJournals.UI.DebugPanel.drawSnapshotDiffItem(self, y, item, alt)
    local h = self.itemheight
    local data = item.item
    if not data then
        return y + h
    end

    if data.isHeader then
        self:drawRect(0, y, self.width, h, 0.25, 0.22, 0.32, 0.45)
        self:drawText(tostring(data.text or ""), 6, y + 2, 0.92, 0.9, 0.98, 1, UIFont.Small)
        return y + h
    end

    local r, g, b = 0.82, 0.82, 0.86
    local prefix = "* "
    if data.kind == "added" then
        r, g, b = 0.45, 0.95, 0.55
        prefix = "+ "
    elseif data.kind == "removed" then
        r, g, b = 0.95, 0.45, 0.45
        prefix = "- "
    elseif data.kind == "changed" then
        r, g, b = 0.85, 0.75, 0.98
        prefix = "~ "
    end

    if self.mouseoverselected == item.index then
        self:drawRect(0, y, self.width, h, 0.2, 0.2, 0.3, 0.25)
    end
    self:drawText(prefix .. tostring(data.text or ""), 6, y + 2, r, g, b, 1, UIFont.Small)
    return y + h
end

function BurdJournals.UI.DebugPanel:refreshBaselineSnapshotDetail()
    local panel = getSnapshotPanel(self)
    if not panel or not panel.snapshotDetailLabel then
        return
    end
    local data = panel.snapshotSelectedData
    if not data then
        panel.snapshotDetailLabel:setName(getText("UI_BurdJournals_BaselineSnapshotDetailNone") or "Select a snapshot to preview details.")
        if panel.snapshotDetailMetaLabel then
            panel.snapshotDetailMetaLabel:setName("")
        end
        return
    end

    local counts = data.counts or {}
    local snapshotId = tostring(data.snapshotId or "?")
    local source = tostring(data.source or "?")
    local who = tostring(data.characterName or data.username or data.characterId or "Unknown")
    local mode = data.isProtected and "protected" or "unlocked"
    local ended = data.endedReason and (" | ended:" .. tostring(data.endedReason)) or ""
    local realCaptured = snapshotGetRealStamp(data, "captured")
    local realEnded = snapshotGetRealStamp(data, "ended")
    local compactId = snapshotId
    if #compactId > 48 then
        compactId = string.sub(compactId, 1, 20) .. "..." .. string.sub(compactId, -16)
    end
    local header = string.format("%s | %s | %s", compactId, source, who)
    local detail = string.format(
        "%dS %dM %dT %dR | %s%s",
        tonumber(counts.skills) or 0,
        tonumber(counts.mediaSkills) or 0,
        tonumber(counts.traits) or 0,
        tonumber(counts.recipes) or 0,
        mode,
        ended
    )
    if realCaptured and realCaptured ~= "" then
        detail = detail .. " | RL " .. tostring(realCaptured)
    end
    if realEnded and realEnded ~= "" then
        detail = detail .. " -> " .. tostring(realEnded)
    end
    panel.snapshotDetailLabel:setName(header)
    if panel.snapshotDetailMetaLabel then
        panel.snapshotDetailMetaLabel:setName(detail)
    end
    self:refreshBaselineSnapshotPreview()
end

function BurdJournals.UI.DebugPanel:applyBaselineSnapshotList(payload)
    local panel = getSnapshotPanel(self)
    if not panel or not panel.snapshotList then
        return
    end

    local previousSelection = panel.snapshotSelectedId
    panel.snapshotItems = type(payload and payload.items) == "table" and payload.items or {}
    if panel.snapshotListSummaryLabel then
        local shown = #panel.snapshotItems
        local total = tonumber(payload and payload.total) or shown
        if total > shown then
            panel.snapshotListSummaryLabel:setName(string.format("Snapshots: %d/%d", shown, total))
        else
            panel.snapshotListSummaryLabel:setName(string.format("Snapshots: %d", shown))
        end
    end
    panel.snapshotList:clear()

    for _, entry in ipairs(panel.snapshotItems) do
        entry.label = formatSnapshotSummaryLine(entry)
        panel.snapshotList:addItem(entry.label, entry)
    end

    panel.snapshotSelectedData = nil
    panel.snapshotSelectedId = nil
    if previousSelection then
        for i = 1, #panel.snapshotList.items do
            local row = panel.snapshotList.items[i]
            if row and row.item and row.item.snapshotId == previousSelection then
                panel.snapshotList.selected = i
                panel.snapshotSelectedId = previousSelection
                panel.snapshotSelectedData = row.item
                break
            end
        end
    end

    if (not panel.snapshotSelectedData) and #panel.snapshotList.items > 0 then
        panel.snapshotList.selected = 1
        panel.snapshotSelectedData = panel.snapshotList.items[1].item
        panel.snapshotSelectedId = panel.snapshotSelectedData and panel.snapshotSelectedData.snapshotId or nil
    end

    if #panel.snapshotList.items == 0 then
        panel.snapshotDetailLabel:setName(getText("UI_BurdJournals_BaselineSnapshotNoResults") or "No snapshots found.")
        if panel.snapshotDetailMetaLabel then
            panel.snapshotDetailMetaLabel:setName("")
        end
        if self.refreshBaselineSnapshotPreview then
            self:refreshBaselineSnapshotPreview()
        end
    else
        self:refreshBaselineSnapshotDetail()
        if panel.snapshotSelectedId and BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.getBaselineSnapshot then
            BurdJournals.Client.Debug.getBaselineSnapshot(panel.snapshotSelectedId, self.player)
        end
    end
end

function BurdJournals.UI.DebugPanel:applyBaselineSnapshotDetail(snapshot)
    local panel = getSnapshotPanel(self)
    if not panel then
        return
    end
    if type(snapshot) ~= "table" then
        return
    end
    if panel.snapshotSelectedId and snapshot.snapshotId and panel.snapshotSelectedId ~= snapshot.snapshotId then
        return
    end
    panel.snapshotSelectedData = snapshot
    panel.snapshotSelectedId = snapshot.snapshotId
    self:refreshBaselineSnapshotDetail()
end

function BurdJournals.UI.DebugPanel:runSnapshotCommand(cmd)
    local panel = getSnapshotPanel(self)
    local targetPlayer = panel and panel.targetPlayer or self.player

    if cmd == "baselinesnapshot_refresh" then
        self:refreshSnapshotPanelData()
        self:setStatus("Requested baseline snapshots...", {r=0.5, g=0.8, b=1})
        return true
    elseif cmd == "baselinesnapshot_save" then
        if targetPlayer and BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.saveBaselineSnapshot then
            BurdJournals.Client.Debug.saveBaselineSnapshot({
                targetUsername = targetPlayer:getUsername(),
                source = "debug_panel",
            }, self.player)
            self:setStatus("Saving baseline snapshot...", {r=0.5, g=0.8, b=1})
        else
            self:setStatus("Snapshot save unavailable", {r=1, g=0.5, b=0.3})
        end
        return true
    elseif cmd == "baselinesnapshot_apply" then
        local selectedSnapshot = panel and panel.snapshotSelectedData or nil
        if not selectedSnapshot or not selectedSnapshot.snapshotId then
            self:setStatus("Select a snapshot first", {r=1, g=0.6, b=0.3})
            return true
        end
        if not targetPlayer then
            self:setStatus("Target player unavailable", {r=1, g=0.6, b=0.3})
            return true
        end

        local snapshotId = tostring(selectedSnapshot.snapshotId)
        local targetName = targetPlayer:getUsername() or "Unknown"
        local promptFormat = getText("UI_BurdJournals_BaselineSnapshotConfirmApply")
            or "Apply snapshot %s to %s? Protected restore keeps debug lock until manually unlocked."
        local promptText = string.format(promptFormat, snapshotId, targetName)
        if ISModalDialog then
            local selfRef = self
            local callback = function(_target, buttonObj)
                if isAffirmativeDialogButton(buttonObj) and selfRef
                    and BurdJournals.Client and BurdJournals.Client.Debug
                    and BurdJournals.Client.Debug.applyBaselineSnapshot
                then
                    BurdJournals.Client.Debug.applyBaselineSnapshot({
                        targetUsername = targetName,
                        snapshotId = snapshotId,
                        restoreMode = BurdJournals.BASELINE_SNAPSHOT_RESTORE_UNLOCKED,
                    }, selfRef.player)
                    selfRef:setStatus("Applying snapshot " .. snapshotId .. "...", {r=0.5, g=0.8, b=1})
                end
            end
            if BurdJournals.createAdaptiveModalDialog then
                BurdJournals.createAdaptiveModalDialog({
                    player = self.player,
                    text = promptText,
                    yesNo = true,
                    onClick = callback,
                    minWidth = 420,
                    maxWidth = 840,
                    minHeight = 180,
                })
            else
                local w, h = 520, 180
                local x = (getCore():getScreenWidth() - w) / 2
                local y = (getCore():getScreenHeight() - h) / 2
                local modal = ISModalDialog:new(x, y, w, h, promptText, true, nil, callback)
                modal:initialise()
                modal:addToUIManager()
            end
        elseif BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.applyBaselineSnapshot then
            BurdJournals.Client.Debug.applyBaselineSnapshot({
                targetUsername = targetName,
                snapshotId = snapshotId,
                restoreMode = BurdJournals.BASELINE_SNAPSHOT_RESTORE_UNLOCKED,
            }, self.player)
            self:setStatus("Applying snapshot " .. snapshotId .. "...", {r=0.5, g=0.8, b=1})
        end
        return true
    elseif cmd == "baselinesnapshot_delete" then
        local selectedSnapshot = panel and panel.snapshotSelectedData or nil
        if not selectedSnapshot or not selectedSnapshot.snapshotId then
            self:setStatus("Select a snapshot first", {r=1, g=0.6, b=0.3})
            return true
        end
        local snapshotId = tostring(selectedSnapshot.snapshotId)
        local promptFormat = getText("UI_BurdJournals_BaselineSnapshotConfirmDelete")
            or "Delete snapshot %s permanently?"
        local promptText = string.format(promptFormat, snapshotId)
        if ISModalDialog then
            local selfRef = self
            local callback = function(_target, buttonObj)
                if isAffirmativeDialogButton(buttonObj) and selfRef
                    and BurdJournals.Client and BurdJournals.Client.Debug
                    and BurdJournals.Client.Debug.deleteBaselineSnapshot
                then
                    BurdJournals.Client.Debug.deleteBaselineSnapshot(snapshotId, selfRef.player)
                    selfRef:setStatus("Deleting snapshot " .. snapshotId .. "...", {r=0.5, g=0.8, b=1})
                end
            end
            if BurdJournals.createAdaptiveModalDialog then
                BurdJournals.createAdaptiveModalDialog({
                    player = self.player,
                    text = promptText,
                    yesNo = true,
                    onClick = callback,
                    minWidth = 400,
                    maxWidth = 760,
                    minHeight = 170,
                })
            else
                local w, h = 460, 170
                local x = (getCore():getScreenWidth() - w) / 2
                local y = (getCore():getScreenHeight() - h) / 2
                local modal = ISModalDialog:new(x, y, w, h, promptText, true, nil, callback)
                modal:initialise()
                modal:addToUIManager()
            end
        elseif BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.deleteBaselineSnapshot then
            BurdJournals.Client.Debug.deleteBaselineSnapshot(snapshotId, self.player)
            self:setStatus("Deleting snapshot " .. snapshotId .. "...", {r=0.5, g=0.8, b=1})
        end
        return true
    end
    return false
end

function BurdJournals.UI.DebugPanel:onSnapshotCmd(button)
    local cmd = button and button.internal or nil
    if not cmd then
        return
    end
    self:runSnapshotCommand(cmd)
end

-- Baseline command handler (for utility buttons)
function BurdJournals.UI.DebugPanel:onBaselineCmd(button)
    local cmd = button.internal
    local panel = self.baselinePanel
    local targetPlayer = panel and panel.targetPlayer or self.player
    
    if cmd == "dumpbaseline" then
        BurdJournals.debugPrint("[BSJ DEBUG] Player Baseline for: " .. (targetPlayer and targetPlayer:getUsername() or "Unknown"))
        local modData = targetPlayer and targetPlayer:getModData() or {}
        local skillBaseline = modData.BurdJournals and modData.BurdJournals.skillBaseline or {}
        local traitBaseline = modData.BurdJournals and modData.BurdJournals.traitBaseline or {}
        local recipeBaseline = modData.BurdJournals and modData.BurdJournals.recipeBaseline or {}
        BurdJournals.debugPrint("  Skills (XP):")
        for k, v in pairs(skillBaseline) do
            local level = BurdJournals.getSkillBaselineLevel and BurdJournals.getSkillBaselineLevel(targetPlayer, k) or "?"
            BurdJournals.debugPrint("    " .. k .. ": " .. tostring(v) .. " XP (Level " .. tostring(level) .. ")")
        end
        BurdJournals.debugPrint("  Traits:")
        for k, v in pairs(traitBaseline) do
            BurdJournals.debugPrint("    " .. k .. ": " .. tostring(v))
        end
        BurdJournals.debugPrint("  Recipes:")
        for k, v in pairs(recipeBaseline) do
            BurdJournals.debugPrint("    " .. k .. ": " .. tostring(v))
        end
        BurdJournals.debugPrint("  Debug Modified: " .. tostring(modData.BurdJournals and modData.BurdJournals.debugModified or false))
        self:setStatus("Baseline dumped to console", {r=0.5, g=0.8, b=1})
    elseif cmd == "dumpspawnstate" then
        if BurdJournals and BurdJournals.Client and BurdJournals.Client.dumpBaselineSpawnState then
            BurdJournals.Client.dumpBaselineSpawnState(targetPlayer, "DebugPanel")
            self:setStatus("Spawn readiness dumped to console", {r=0.5, g=0.8, b=1})
        else
            self:setStatus("Spawn readiness dump unavailable", {r=1, g=0.5, b=0.3})
        end
    elseif cmd == "savebaselinechanges" then
        if not panel or panel.baselineDraftDirty ~= true then
            self:setStatus(getText("UI_BurdJournals_BaselineDraftNoChanges") or "No pending baseline changes to save.", {r=0.9, g=0.75, b=0.4})
            return
        end
        local payload = self.buildBaselineDraftPayload and self:buildBaselineDraftPayload() or nil
        if not payload then
            self:setStatus("Could not build baseline draft payload", {r=1, g=0.5, b=0.3})
            return
        end
        if targetPlayer and BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.saveBaselineDraft then
            BurdJournals.Client.Debug.saveBaselineDraft({
                targetUsername = targetPlayer:getUsername(),
                skillBaseline = payload.skillBaseline,
                traitBaseline = payload.traitBaseline,
            }, self.player)
            self:setStatus(getText("UI_BurdJournals_BaselineDraftSaving") or "Saving baseline snapshot...", {r=0.5, g=0.8, b=1})
        else
            self:setStatus("Baseline draft save unavailable", {r=1, g=0.5, b=0.3})
        end
    elseif cmd == "discardbaselinechanges" then
        if not panel or panel.baselineDraftDirty ~= true then
            self:setStatus(getText("UI_BurdJournals_BaselineDraftNoChanges") or "No pending baseline changes to discard.", {r=0.9, g=0.75, b=0.4})
            return
        end
        self:refreshBaselineData()
        self:setStatus(getText("UI_BurdJournals_BaselineDraftDiscarded") or "Discarded baseline draft changes.", {r=0.95, g=0.78, b=0.45})
    elseif cmd == "opensnapshots" then
        self:showTab("snapshots")
    elseif cmd == "baselinesnapshot_refresh"
        or cmd == "baselinesnapshot_save"
        or cmd == "baselinesnapshot_apply"
        or cmd == "baselinesnapshot_delete"
    then
        self:runSnapshotCommand(cmd)
    elseif cmd == "clearall" then
        if panel then
            local changedSkillCount = 0
            local changedTraitCount = 0
            local changedAny = false

            panel.baselineDraftSkills = panel.baselineDraftSkills or {}
            panel.baselineDraftTraits = panel.baselineDraftTraits or {}

            if panel.baselineSkillList and panel.baselineSkillList.items then
                for _, row in ipairs(panel.baselineSkillList.items) do
                    local data = row and row.item
                    if data and data.name then
                        local oldXP = tonumber(data.baselineXP) or 0
                        local oldLevel = tonumber(data.baselineLevel) or 0
                        if oldXP > 0 or oldLevel > 0 then
                            changedAny = true
                            changedSkillCount = changedSkillCount + 1
                        end
                        data.baselineLevel = 0
                        data.baselineXP = 0
                        panel.baselineDraftSkills[tostring(data.name)] = 0
                    end
                end
            end

            if panel.baselineTraitList and panel.baselineTraitList.items then
                for _, row in ipairs(panel.baselineTraitList.items) do
                    local data = row and row.item
                    if data and data.id then
                        if data.isBaseline == true then
                            changedAny = true
                            changedTraitCount = changedTraitCount + 1
                        end
                        data.isBaseline = false
                        panel.baselineDraftTraits[tostring(data.id)] = false
                    end
                end
            end

            if changedAny then
                if self.markBaselineDraftDirty then
                    self:markBaselineDraftDirty(
                        string.format(
                            "Draft cleared: %d skills and %d traits reset. Save to apply.",
                            changedSkillCount,
                            changedTraitCount
                        )
                    )
                else
                    self:setStatus("Baseline draft cleared. Save to apply.", {r=0.95, g=0.8, b=0.4})
                end
            else
                self:setStatus("Baseline draft is already empty.", {r=0.9, g=0.75, b=0.4})
            end
        end
    elseif cmd == "recalculate" then
        if panel and panel.baselineSkillList and panel.baselineSkillList.items then
            panel.baselineDraftSkills = panel.baselineDraftSkills or {}
            local changedCount = 0
            local changedAny = false

            for _, row in ipairs(panel.baselineSkillList.items) do
                local data = row and row.item
                if data and data.name then
                    local targetXP = math.max(0, math.floor(tonumber(data.currentXP) or 0))
                    local currentLevel = math.max(0, math.min(10, math.floor(tonumber(data.currentLevel) or 0)))
                    if targetXP <= 0 and currentLevel > 0 then
                        local isPassive = data.isPassive or data.name == "Fitness" or data.name == "Strength"
                        if isPassive then
                            targetXP = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[currentLevel] or 0
                        else
                            targetXP = BurdJournals.STANDARD_XP_THRESHOLDS and BurdJournals.STANDARD_XP_THRESHOLDS[currentLevel] or 0
                        end
                        targetXP = math.max(0, math.floor(tonumber(targetXP) or 0))
                    end

                    local oldXP = math.max(0, math.floor(tonumber(data.baselineXP) or 0))
                    if oldXP ~= targetXP then
                        changedAny = true
                        changedCount = changedCount + 1
                    end

                    data.baselineXP = targetXP
                    if BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.getLevelFromXP then
                        data.baselineLevel = BurdJournals.Client.Debug.getLevelFromXP(data.name, targetXP)
                    else
                        data.baselineLevel = currentLevel
                    end
                    panel.baselineDraftSkills[tostring(data.name)] = targetXP
                end
            end

            if changedAny then
                if self.markBaselineDraftDirty then
                    self:markBaselineDraftDirty(
                        string.format(
                            "Draft set to current skills: %d skill baselines updated. Save to apply.",
                            changedCount
                        )
                    )
                else
                    self:setStatus("Draft set to current skills. Save to apply.", {r=0.95, g=0.8, b=0.4})
                end
            else
                self:setStatus("Baseline skill draft already matches current skills.", {r=0.9, g=0.75, b=0.4})
            end
        end
    elseif cmd == "migratejournals" then
        if sendClientCommand then
            sendClientCommand("BurdJournals", "debugMigrateOnlineJournals", {})
            self:setStatus("Requested online journal migration on server...", {r=0.5, g=0.8, b=1})
        else
            self:setStatus("Migration command unavailable in this context", {r=1, g=0.5, b=0.3})
        end
    end
end

-- ============================================================================
-- Tab 4: Journal Editor Panel
-- Allows editing skills and traits of a selected journal
-- ============================================================================

local function normalizeJournalEditProfile(profileValue)
    local value = tostring(profileValue or "normal")
    if value == "debug" then
        return "debug"
    end
    return "normal"
end

local function getJournalProfileFromCombo(panel)
    if not panel or not panel.journalProfileCombo then
        return "normal"
    end
    local selected = panel.journalProfileCombo.selected or 1
    local value = panel.journalProfileCombo:getOptionData(selected)
        or panel.journalProfileCombo.options[selected]
    return normalizeJournalEditProfile(value)
end

local function updateJournalProfileConvertButtons(panel, profileValue)
    if not panel then
        return
    end
    local profile = normalizeJournalEditProfile(profileValue or getJournalProfileFromCombo(panel))
    if panel.journalConvertNormalBtn then
        panel.journalConvertNormalBtn:setVisible(profile == "debug")
    end
    if panel.journalConvertDebugBtn then
        panel.journalConvertDebugBtn:setVisible(profile ~= "debug")
    end
end

local function setJournalProfileCombo(panel, profileValue)
    if not panel or not panel.journalProfileCombo then
        return
    end
    local profile = normalizeJournalEditProfile(profileValue)
    local selected = (profile == "debug") and 2 or 1
    panel.journalProfileCombo.selected = selected
    panel.journalProfile = profile
    updateJournalProfileConvertButtons(panel, profile)
end

local function resolveJournalEditProfileForItem(journal, explicitProfile)
    if explicitProfile ~= nil then
        return normalizeJournalEditProfile(explicitProfile)
    end

    local instance = BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.instance
    local panel = instance and instance.journalPanel or nil
    if panel and instance.editingJournal == journal then
        return getJournalProfileFromCombo(panel)
    end

    local modData = journal and journal.getModData and journal:getModData() or nil
    local data = modData and modData.BurdJournals or nil
    if type(data) == "table" and data.isDebugSpawned == true then
        return "debug"
    end
    return "normal"
end

local function normalizeJournalOriginMode(originValue)
    local value = tostring(originValue or "found")
    if value == "personal" or value == "found" or value == "world" or value == "zombie" then
        return value
    end
    return "found"
end

local function getJournalOriginFromCombo(panel)
    if not panel or not panel.journalOriginCombo then
        return "found"
    end
    local selected = panel.journalOriginCombo.selected or 1
    local value = panel.journalOriginCombo:getOptionData(selected)
        or panel.journalOriginCombo.options[selected]
    return normalizeJournalOriginMode(value)
end

local function setJournalOriginCombo(panel, originValue)
    if not panel or not panel.journalOriginCombo then
        return
    end
    local originMode = normalizeJournalOriginMode(originValue)
    local selectedIndex = 2
    if originMode == "personal" then
        selectedIndex = 1
    elseif originMode == "found" then
        selectedIndex = 2
    elseif originMode == "world" then
        selectedIndex = 3
    elseif originMode == "zombie" then
        selectedIndex = 4
    end
    panel.journalOriginCombo.selected = selectedIndex
    panel.journalOriginMode = originMode
end

local function normalizeJournalEditType(typeValue)
    local value = tostring(typeValue or "filled")
    if value == "blank" or value == "filled" or value == "worn" or value == "bloody" or value == "cursed" then
        return value
    end
    return "filled"
end

local function getJournalEditTypeFromCombo(panel)
    if not panel or not panel.journalTypeCombo then
        return "filled"
    end
    local selected = panel.journalTypeCombo.selected or 1
    local value = panel.journalTypeCombo:getOptionData(selected)
        or panel.journalTypeCombo.options[selected]
    return normalizeJournalEditType(value)
end

local function setJournalEditTypeCombo(panel, typeValue)
    if not panel or not panel.journalTypeCombo then
        return
    end
    local selectedType = normalizeJournalEditType(typeValue)
    local selected = 2
    if selectedType == "blank" then
        selected = 1
    elseif selectedType == "filled" then
        selected = 2
    elseif selectedType == "worn" then
        selected = 3
    elseif selectedType == "bloody" then
        selected = 4
    elseif selectedType == "cursed" then
        selected = 5
    end
    panel.journalTypeCombo.selected = selected
    panel.journalEditType = selectedType
end

local function inferJournalEditTypeFromItem(journal, journalData)
    local fullType = journal and journal.getFullType and journal:getFullType() or ""
    local cursedItemType = BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal"

    if type(fullType) == "string" and string.find(fullType, "BlankSurvivalJournal", 1, true) then
        return "blank"
    end
    if fullType == cursedItemType then
        return "cursed"
    end
    if type(fullType) == "string" and string.find(fullType, "_Worn", 1, true) then
        return "worn"
    end
    if type(fullType) == "string" and string.find(fullType, "_Bloody", 1, true) then
        return "bloody"
    end

    if type(journalData) == "table" then
        if journalData.isCursedJournal == true and journalData.cursedState ~= "unleashed" then
            return "cursed"
        end
        if journalData.isWorn == true or journalData.wasFromWorn == true then
            return "worn"
        end
        if journalData.isBloody == true or journalData.wasFromBloody == true or journalData.isCursedReward == true then
            return "bloody"
        end
    end
    return "filled"
end

local function getEditorItemTypeForJournalType(typeValue)
    local selectedType = normalizeJournalEditType(typeValue)
    if selectedType == "blank" then
        return "BurdJournals.BlankSurvivalJournal"
    elseif selectedType == "worn" then
        return "BurdJournals.FilledSurvivalJournal_Worn"
    elseif selectedType == "bloody" then
        return "BurdJournals.FilledSurvivalJournal_Bloody"
    elseif selectedType == "cursed" then
        return BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal"
    end
    return "BurdJournals.FilledSurvivalJournal"
end

local function findOwnerOptionIndexByCombo(ownerCombo, predicate)
    if not ownerCombo or not predicate then
        return nil
    end
    local optionCount = #ownerCombo.options
    for i = 1, optionCount do
        local data = ownerCombo:getOptionData(i)
        if predicate(data, i) then
            return i
        end
    end
    return nil
end

function BurdJournals.UI.DebugPanel:createJournalPanel(startY, height)
    local panel = ISPanel:new(5, startY, self.width - 10, height)
    panel:initialise()
    panel:instantiate()
    panel.backgroundColor = {r=0.12, g=0.12, b=0.15, a=1}
    panel.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    self:addChild(panel)
    self.tabPanels["journal"] = panel
    
    local padding = 10
    local y = padding
    local fullWidth = panel.width - padding * 2
    local halfWidth = (fullWidth - padding) / 2
    local btnHeight = 24
    
    -- Header - Journal name display
    panel.journalHeaderLabel = ISLabel:new(padding, y, 20, "No journal selected", 0.9, 0.7, 0.5, 1, UIFont.Medium, true)
    panel.journalHeaderLabel:initialise()
    panel.journalHeaderLabel:instantiate()
    panel:addChild(panel.journalHeaderLabel)
    
    -- Select Journal button (for when no journal is selected via context menu)
    local selectBtn = ISButton:new(fullWidth - 100, y - 2, 110, 22, "Select from Inv", self, BurdJournals.UI.DebugPanel.onJournalSelectFromInventory)
    selectBtn:initialise()
    selectBtn:instantiate()
    selectBtn.font = UIFont.Small
    selectBtn.textColor = {r=1, g=1, b=1, a=1}
    selectBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    selectBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(selectBtn)
    y = y + 28

    -- Journal picker dropdown: Name | Author | UUID
    local pickerLabel = ISLabel:new(padding, y + 2, 16, "Journal:", 0.8, 0.8, 0.9, 1, UIFont.Small, true)
    pickerLabel:initialise()
    pickerLabel:instantiate()
    panel:addChild(pickerLabel)

    local pickerX = padding + 52
    local pickerWidth = math.max(240, fullWidth - 185)
    panel.journalSelectCombo = ISComboBox:new(pickerX, y - 2, pickerWidth, 22, self, BurdJournals.UI.DebugPanel.onJournalPickerChanged)
    panel.journalSelectCombo:initialise()
    panel.journalSelectCombo:instantiate()
    panel.journalSelectCombo.font = UIFont.Small
    panel.journalSelectCombo.borderColor = {r=0.35, g=0.45, b=0.55, a=1}
    panel:addChild(panel.journalSelectCombo)

    local pickerBtnX = pickerX + pickerWidth + 5
    local refreshListBtn = ISButton:new(pickerBtnX, y - 2, 56, 22, "Refresh", self, BurdJournals.UI.DebugPanel.onJournalRefreshList)
    refreshListBtn:initialise()
    refreshListBtn:instantiate()
    refreshListBtn.font = UIFont.Small
    refreshListBtn.textColor = {r=1, g=1, b=1, a=1}
    refreshListBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    refreshListBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(refreshListBtn)

    local useSelectedBtn = ISButton:new(pickerBtnX + 60, y - 2, 52, 22, "Use", self, BurdJournals.UI.DebugPanel.onJournalUseDropdownSelection)
    useSelectedBtn:initialise()
    useSelectedBtn:instantiate()
    useSelectedBtn.font = UIFont.Small
    useSelectedBtn.textColor = {r=1, g=1, b=1, a=1}
    useSelectedBtn.borderColor = {r=0.35, g=0.55, b=0.4, a=1}
    useSelectedBtn.backgroundColor = {r=0.2, g=0.3, b=0.25, a=1}
    panel:addChild(useSelectedBtn)
    y = y + 26

    -- Server index picker (can include journals not currently nearby/open)
    local serverPickerLabel = ISLabel:new(padding, y + 2, 16, "Server:", 0.8, 0.8, 0.9, 1, UIFont.Small, true)
    serverPickerLabel:initialise()
    serverPickerLabel:instantiate()
    panel:addChild(serverPickerLabel)

    local serverPickerX = padding + 52
    local serverPickerWidth = math.max(240, fullWidth - 185)
    panel.journalServerIndexCombo = ISComboBox:new(serverPickerX, y - 2, serverPickerWidth, 22, self, BurdJournals.UI.DebugPanel.onJournalServerIndexChanged)
    panel.journalServerIndexCombo:initialise()
    panel.journalServerIndexCombo:instantiate()
    panel.journalServerIndexCombo.font = UIFont.Small
    panel.journalServerIndexCombo.borderColor = {r=0.35, g=0.45, b=0.55, a=1}
    panel:addChild(panel.journalServerIndexCombo)

    local serverBtnX = serverPickerX + serverPickerWidth + 5
    local refreshServerListBtn = ISButton:new(serverBtnX, y - 2, 56, 22, "Fetch", self, BurdJournals.UI.DebugPanel.onJournalRefreshServerIndex)
    refreshServerListBtn:initialise()
    refreshServerListBtn:instantiate()
    refreshServerListBtn.font = UIFont.Small
    refreshServerListBtn.textColor = {r=1, g=1, b=1, a=1}
    refreshServerListBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    refreshServerListBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(refreshServerListBtn)

    local useServerSelectedBtn = ISButton:new(serverBtnX + 60, y - 2, 52, 22, "Use", self, BurdJournals.UI.DebugPanel.onJournalUseServerIndexSelection)
    useServerSelectedBtn:initialise()
    useServerSelectedBtn:instantiate()
    useServerSelectedBtn.font = UIFont.Small
    useServerSelectedBtn.textColor = {r=1, g=1, b=1, a=1}
    useServerSelectedBtn.borderColor = {r=0.35, g=0.55, b=0.4, a=1}
    useServerSelectedBtn.backgroundColor = {r=0.2, g=0.3, b=0.25, a=1}
    panel:addChild(useServerSelectedBtn)
    y = y + 26
    
    -- Journal info line
    panel.journalInfoLabel = ISLabel:new(padding, y, 16, "", 0.6, 0.6, 0.7, 1, UIFont.Small, true)
    panel.journalInfoLabel:initialise()
    panel.journalInfoLabel:instantiate()
    panel:addChild(panel.journalInfoLabel)
    y = y + 22

    -- Metadata controls (type/profile/origin + author/flavor/age) in a compact block.
    panel.journalMetaLabel = ISLabel:new(padding, y, 16, "Journal Metadata", 0.75, 0.82, 0.95, 1, UIFont.Small, true)
    panel.journalMetaLabel:initialise()
    panel.journalMetaLabel:instantiate()
    panel:addChild(panel.journalMetaLabel)
    y = y + 18

    local row1Y = y
    panel.journalTypeLabel = ISLabel:new(padding, row1Y + 2, 16, "Type:", 0.8, 0.8, 0.9, 1, UIFont.Small, true)
    panel.journalTypeLabel:initialise()
    panel.journalTypeLabel:instantiate()
    panel:addChild(panel.journalTypeLabel)

    panel.journalTypeCombo = ISComboBox:new(padding + 46, row1Y - 2, 122, 22, self, BurdJournals.UI.DebugPanel.onJournalTypeChange)
    panel.journalTypeCombo:initialise()
    panel.journalTypeCombo:instantiate()
    panel.journalTypeCombo.font = UIFont.Small
    panel.journalTypeCombo:addOptionWithData("Blank", "blank")
    panel.journalTypeCombo:addOptionWithData("Filled", "filled")
    panel.journalTypeCombo:addOptionWithData("Worn", "worn")
    panel.journalTypeCombo:addOptionWithData("Bloody", "bloody")
    panel.journalTypeCombo:addOptionWithData("Cursed", "cursed")
    panel.journalTypeCombo:setSelected(2)
    panel:addChild(panel.journalTypeCombo)
    panel.journalEditType = "filled"

    panel.journalProfileLabel = ISLabel:new(
        padding + 176,
        row1Y + 2,
        16,
        (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnProfile", "Spawn Profile:"))
            or "Spawn Profile:",
        0.8, 0.8, 0.9, 1,
        UIFont.Small,
        true
    )
    panel.journalProfileLabel:initialise()
    panel.journalProfileLabel:instantiate()
    panel:addChild(panel.journalProfileLabel)

    panel.journalProfileCombo = ISComboBox:new(padding + 266, row1Y - 2, 170, 22, self, BurdJournals.UI.DebugPanel.onJournalProfileChange)
    panel.journalProfileCombo:initialise()
    panel.journalProfileCombo:instantiate()
    panel.journalProfileCombo.font = UIFont.Small
    panel.journalProfileCombo:addOptionWithData(
        (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnProfileNormal", "Normal (Natural)"))
            or "Normal (Natural)",
        "normal"
    )
    panel.journalProfileCombo:addOptionWithData(
        (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnProfileDebug", "Debug (Legacy)"))
            or "Debug (Legacy)",
        "debug"
    )
    panel.journalProfileCombo:setSelected(1)
    panel:addChild(panel.journalProfileCombo)
    panel.journalProfile = "normal"

    panel.journalOriginLabel = ISLabel:new(
        padding + 444,
        row1Y + 2,
        16,
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOrigin", "Origin:") or "Origin:",
        0.8, 0.8, 0.9, 1,
        UIFont.Small,
        true
    )
    panel.journalOriginLabel:initialise()
    panel.journalOriginLabel:instantiate()
    panel:addChild(panel.journalOriginLabel)

    panel.journalOriginCombo = ISComboBox:new(padding + 498, row1Y - 2, 180, 22, self, BurdJournals.UI.DebugPanel.onJournalOriginChange)
    panel.journalOriginCombo:initialise()
    panel.journalOriginCombo:instantiate()
    panel.journalOriginCombo.font = UIFont.Small
    panel.journalOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginPersonal", "Personal")
            or "Personal",
        "personal"
    )
    panel.journalOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginFound", "Found")
            or "Found",
        "found"
    )
    panel.journalOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginWorld", "Found in World")
            or "Found in World",
        "world"
    )
    panel.journalOriginCombo:addOptionWithData(
        BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOriginZombie", "Recovered from Zombie")
            or "Recovered from Zombie",
        "zombie"
    )
    panel.journalOriginCombo:setSelected(2)
    panel:addChild(panel.journalOriginCombo)
    panel.journalOriginMode = "found"
    y = row1Y + 26

    local row2Y = y
    panel.journalOwnerLabel = ISLabel:new(
        padding,
        row2Y + 2,
        16,
        (BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOwnerAssign", "Assign to Player:"))
            or "Assign to Player:",
        0.8, 0.8, 0.9, 1,
        UIFont.Small,
        true
    )
    panel.journalOwnerLabel:initialise()
    panel.journalOwnerLabel:instantiate()
    panel:addChild(panel.journalOwnerLabel)

    panel.journalOwnerCombo = ISComboBox:new(padding + 92, row2Y - 2, 190, 22, self, BurdJournals.UI.DebugPanel.onJournalOwnerChange)
    panel.journalOwnerCombo:initialise()
    panel.journalOwnerCombo:instantiate()
    panel.journalOwnerCombo.font = UIFont.Small
    panel:addChild(panel.journalOwnerCombo)

    panel.journalOwnerCustomEntry = ISTextEntryBox:new("", padding + 92, row2Y - 2, 190, 20)
    panel.journalOwnerCustomEntry:initialise()
    panel.journalOwnerCustomEntry:instantiate()
    panel.journalOwnerCustomEntry.font = UIFont.Small
    panel.journalOwnerCustomEntry:setTooltip("Custom author name")
    panel:addChild(panel.journalOwnerCustomEntry)

    panel.journalFlavorLabel = ISLabel:new(padding + 288, row2Y + 2, 16, "Flavor:", 0.8, 0.8, 0.9, 1, UIFont.Small, true)
    panel.journalFlavorLabel:initialise()
    panel.journalFlavorLabel:instantiate()
    panel:addChild(panel.journalFlavorLabel)

    panel.journalFlavorEntry = ISTextEntryBox:new("", padding + 336, row2Y - 2, 170, 20)
    panel.journalFlavorEntry:initialise()
    panel.journalFlavorEntry:instantiate()
    panel.journalFlavorEntry.font = UIFont.Small
    panel.journalFlavorEntry:setTooltip("Custom flavor text (leave empty for profession/default flavor)")
    panel:addChild(panel.journalFlavorEntry)

    panel.journalAgeLabel = ISLabel:new(padding + 512, row2Y + 2, 16, "Age h:", 0.8, 0.8, 0.9, 1, UIFont.Small, true)
    panel.journalAgeLabel:initialise()
    panel.journalAgeLabel:instantiate()
    panel:addChild(panel.journalAgeLabel)

    panel.journalAgeEntry = ISTextEntryBox:new("0", padding + 556, row2Y - 2, 64, 20)
    panel.journalAgeEntry:initialise()
    panel.journalAgeEntry:instantiate()
    panel.journalAgeEntry.font = UIFont.Small
    panel.journalAgeEntry:setOnlyNumbers(true)
    panel.journalAgeEntry:setTooltip("How many world-hours old the journal appears")
    panel:addChild(panel.journalAgeEntry)

    panel.journalApplyMetaBtn = ISButton:new(padding + 626, row2Y - 2, 138, 22, "Apply Metadata", self, BurdJournals.UI.DebugPanel.onJournalApplyMetadata)
    panel.journalApplyMetaBtn:initialise()
    panel.journalApplyMetaBtn:instantiate()
    panel.journalApplyMetaBtn.font = UIFont.Small
    panel.journalApplyMetaBtn.textColor = {r=1, g=1, b=1, a=1}
    panel.journalApplyMetaBtn.borderColor = {r=0.35, g=0.5, b=0.65, a=1}
    panel.journalApplyMetaBtn.backgroundColor = {r=0.2, g=0.27, b=0.35, a=1}
    panel.journalApplyMetaBtn:setTooltip("Apply type/origin/author/flavor/age/profile changes.")
    panel:addChild(panel.journalApplyMetaBtn)

    self:populateOwnerCombo({ownerCombo = panel.journalOwnerCombo})
    setJournalEditTypeCombo(panel, "filled")
    updateJournalProfileConvertButtons(panel, "normal")
    y = row2Y + 26

    -- UUID tools (target stale/exploited journals directly)
    local uuidLabel = ISLabel:new(padding, y, 16, "UUID:", 0.8, 0.8, 0.9, 1, UIFont.Small, true)
    uuidLabel:initialise()
    uuidLabel:instantiate()
    panel:addChild(uuidLabel)

    local uuidFieldX = padding + 42
    local findUuidW, repairUuidW, restoreUuidW = 56, 62, 92
    local uuidBtnGap = 4
    local uuidButtonsTotal = findUuidW + repairUuidW + restoreUuidW + (uuidBtnGap * 2)
    local uuidRowRight = padding + fullWidth
    local uuidBtnX = uuidRowRight - uuidButtonsTotal
    local uuidEntryWidth = math.max(150, uuidBtnX - uuidFieldX - 5)
    panel.journalUUIDEntry = ISTextEntryBox:new("", uuidFieldX, y - 2, uuidEntryWidth, 20)
    panel.journalUUIDEntry:initialise()
    panel.journalUUIDEntry:instantiate()
    panel.journalUUIDEntry.font = UIFont.Small
    panel.journalUUIDEntry:setTooltip("Paste a journal UUID to locate or repair it.")
    panel:addChild(panel.journalUUIDEntry)

    local findUuidBtn = ISButton:new(uuidBtnX, y - 2, findUuidW, 20, "Find", self, BurdJournals.UI.DebugPanel.onJournalFindByUUID)
    findUuidBtn:initialise()
    findUuidBtn:instantiate()
    findUuidBtn.font = UIFont.Small
    findUuidBtn.textColor = {r=1, g=1, b=1, a=1}
    findUuidBtn.borderColor = {r=0.35, g=0.5, b=0.65, a=1}
    findUuidBtn.backgroundColor = {r=0.18, g=0.27, b=0.35, a=1}
    panel:addChild(findUuidBtn)

    local repairUuidBtnX = uuidBtnX + findUuidW + uuidBtnGap
    local repairUuidBtn = ISButton:new(repairUuidBtnX, y - 2, repairUuidW, 20, "Repair", self, BurdJournals.UI.DebugPanel.onJournalRepairByUUID)
    repairUuidBtn:initialise()
    repairUuidBtn:instantiate()
    repairUuidBtn.font = UIFont.Small
    repairUuidBtn.textColor = {r=1, g=1, b=1, a=1}
    repairUuidBtn.borderColor = {r=0.35, g=0.55, b=0.4, a=1}
    repairUuidBtn.backgroundColor = {r=0.16, g=0.32, b=0.22, a=1}
    panel:addChild(repairUuidBtn)

    local restoreUuidBtnX = repairUuidBtnX + repairUuidW + uuidBtnGap
    local restoreUuidBtn = ISButton:new(restoreUuidBtnX, y - 2, restoreUuidW, 20, "Mark Restored", self, BurdJournals.UI.DebugPanel.onJournalMarkRestoredByUUID)
    restoreUuidBtn:initialise()
    restoreUuidBtn:instantiate()
    restoreUuidBtn.font = UIFont.Small
    restoreUuidBtn.textColor = {r=1, g=1, b=1, a=1}
    restoreUuidBtn.borderColor = {r=0.55, g=0.45, b=0.3, a=1}
    restoreUuidBtn.backgroundColor = {r=0.32, g=0.24, b=0.15, a=1}
    panel:addChild(restoreUuidBtn)

    local uuidSecondRowY = y + 22
    local deleteUuidW = 70
    local normalizeUuidW = 92
    local deleteUuidX = padding + fullWidth - deleteUuidW
    local normalizeUuidX = deleteUuidX - uuidBtnGap - normalizeUuidW

    local normalizeUuidBtn = ISButton:new(normalizeUuidX, uuidSecondRowY, normalizeUuidW, 20, "Normalize XP", self, BurdJournals.UI.DebugPanel.onJournalNormalizeXPModeByUUID)
    normalizeUuidBtn:initialise()
    normalizeUuidBtn:instantiate()
    normalizeUuidBtn.font = UIFont.Small
    normalizeUuidBtn.textColor = {r=1, g=1, b=1, a=1}
    normalizeUuidBtn.borderColor = {r=0.35, g=0.45, b=0.6, a=1}
    normalizeUuidBtn.backgroundColor = {r=0.2, g=0.24, b=0.35, a=1}
    normalizeUuidBtn:setTooltip("Normalize journal XP mode by UUID (auto-detect absolute vs baseline mode).")
    panel:addChild(normalizeUuidBtn)

    local deleteUuidBtn = ISButton:new(deleteUuidX, uuidSecondRowY, deleteUuidW, 20, "Delete", self, BurdJournals.UI.DebugPanel.onJournalDeleteByUUIDPrompt)
    deleteUuidBtn:initialise()
    deleteUuidBtn:instantiate()
    deleteUuidBtn.font = UIFont.Small
    deleteUuidBtn.textColor = {r=1, g=1, b=1, a=1}
    deleteUuidBtn.borderColor = {r=0.7, g=0.35, b=0.35, a=1}
    deleteUuidBtn.backgroundColor = {r=0.38, g=0.16, b=0.16, a=1}
    deleteUuidBtn:setTooltip("Delete live journal item by UUID and purge debug/index cache records.")
    panel:addChild(deleteUuidBtn)
    y = y + 48
    
    -- Skills section header with search field and Add Skill button
    local skillsLabel = ISLabel:new(padding, y, 18, "Skills (Click squares to set level):", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    skillsLabel:initialise()
    skillsLabel:instantiate()
    panel:addChild(skillsLabel)
    
    -- Skill search field
    panel.journalSkillSearchEntry = ISTextEntryBox:new("", padding + 200, y - 2, 120, 20)
    panel.journalSkillSearchEntry:initialise()
    panel.journalSkillSearchEntry:instantiate()
    panel.journalSkillSearchEntry.font = UIFont.Small
    panel.journalSkillSearchEntry:setTooltip("Type to filter skills...")
    panel.journalSkillSearchEntry.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterJournalSkillList(self)
    end
    panel:addChild(panel.journalSkillSearchEntry)
    
    -- Add Skill button
    local addSkillBtn = ISButton:new(padding + 325, y - 2, 70, 20, "+ Add Skill", self, BurdJournals.UI.DebugPanel.onJournalAddSkillPopup)
    addSkillBtn:initialise()
    addSkillBtn:instantiate()
    addSkillBtn.font = UIFont.Small
    addSkillBtn.textColor = {r=1, g=1, b=1, a=1}
    addSkillBtn.borderColor = {r=0.3, g=0.5, b=0.4, a=1}
    addSkillBtn.backgroundColor = {r=0.2, g=0.35, b=0.25, a=1}
    panel:addChild(addSkillBtn)
    y = y + 22
    
    -- Skill list (scrollable) with interactive level visualizers
    local skillListHeight = 120
    panel.journalSkillList = ISScrollingListBox:new(padding, y, fullWidth, skillListHeight)
    panel.journalSkillList:initialise()
    panel.journalSkillList:instantiate()
    panel.journalSkillList.itemheight = 24
    panel.journalSkillList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.journalSkillList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.journalSkillList.doDrawItem = BurdJournals.UI.DebugPanel.drawJournalSkillItem
    panel.journalSkillList.onMouseDown = BurdJournals.UI.DebugPanel.onJournalSkillListClick
    panel.journalSkillList.parentPanel = self
    panel:addChild(panel.journalSkillList)
    y = y + skillListHeight + 5
    
    -- XP input row for focused skill
    panel.journalFocusedSkill = nil  -- Track which skill is selected for XP modification
    
    panel.journalXPLabel = ISLabel:new(padding, y, 18, "Set XP:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    panel.journalXPLabel:initialise()
    panel.journalXPLabel:instantiate()
    panel:addChild(panel.journalXPLabel)
    
    panel.journalXPEntry = ISTextEntryBox:new("0", padding + 50, y - 2, 70, 20)
    panel.journalXPEntry:initialise()
    panel.journalXPEntry:instantiate()
    panel.journalXPEntry.font = UIFont.Small
    panel.journalXPEntry:setOnlyNumbers(true)
    panel.journalXPEntry.backgroundColor = {r=0.15, g=0.15, b=0.18, a=1}
    panel.journalXPEntry.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel:addChild(panel.journalXPEntry)
    
    panel.journalSkillNameLabel = ISLabel:new(padding + 125, y, 18, "Click skill row to select", 0.5, 0.6, 0.7, 1, UIFont.Small, true)
    panel.journalSkillNameLabel:initialise()
    panel.journalSkillNameLabel:instantiate()
    panel:addChild(panel.journalSkillNameLabel)

    panel.journalDRLabel = ISLabel:new(padding + 125, y + 12, 16, "DR: --", 0.55, 0.62, 0.72, 1, UIFont.Small, true)
    panel.journalDRLabel:initialise()
    panel.journalDRLabel:instantiate()
    panel:addChild(panel.journalDRLabel)
    
    local setXPBtn = ISButton:new(fullWidth - 100, y - 2, 50, 20, "Set", self, BurdJournals.UI.DebugPanel.onJournalSetXP)
    setXPBtn:initialise()
    setXPBtn:instantiate()
    setXPBtn.font = UIFont.Small
    setXPBtn.textColor = {r=1, g=1, b=1, a=1}
    setXPBtn.borderColor = {r=0.3, g=0.5, b=0.4, a=1}
    setXPBtn.backgroundColor = {r=0.2, g=0.3, b=0.25, a=1}
    panel:addChild(setXPBtn)
    
    local removeSkillBtn = ISButton:new(fullWidth - 45, y - 2, 55, 20, "Remove", self, BurdJournals.UI.DebugPanel.onJournalRemoveSkill)
    removeSkillBtn:initialise()
    removeSkillBtn:instantiate()
    removeSkillBtn.font = UIFont.Small
    removeSkillBtn.textColor = {r=1, g=1, b=1, a=1}
    removeSkillBtn.borderColor = {r=0.5, g=0.3, b=0.3, a=1}
    removeSkillBtn.backgroundColor = {r=0.35, g=0.15, b=0.15, a=1}
    panel:addChild(removeSkillBtn)
    y = y + 28

    -- Diminishing Returns inspector/edit controls
    panel.journalDRStepLabel = ISLabel:new(padding, y, 16, "DR Step:", 0.75, 0.8, 0.9, 1, UIFont.Small, true)
    panel.journalDRStepLabel:initialise()
    panel.journalDRStepLabel:instantiate()
    panel:addChild(panel.journalDRStepLabel)

    panel.journalDRStepEntry = ISTextEntryBox:new("0", padding + 58, y - 2, 60, 20)
    panel.journalDRStepEntry:initialise()
    panel.journalDRStepEntry:instantiate()
    panel.journalDRStepEntry.font = UIFont.Small
    panel.journalDRStepEntry:setOnlyNumbers(true)
    panel.journalDRStepEntry.backgroundColor = {r=0.15, g=0.15, b=0.18, a=1}
    panel.journalDRStepEntry.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel:addChild(panel.journalDRStepEntry)

    local setDRStepBtn = ISButton:new(padding + 122, y - 2, 44, 20, "Set", self, BurdJournals.UI.DebugPanel.onJournalSetDRStep)
    setDRStepBtn:initialise()
    setDRStepBtn:instantiate()
    setDRStepBtn.font = UIFont.Small
    setDRStepBtn.textColor = {r=1, g=1, b=1, a=1}
    setDRStepBtn.borderColor = {r=0.3, g=0.5, b=0.4, a=1}
    setDRStepBtn.backgroundColor = {r=0.2, g=0.3, b=0.25, a=1}
    panel:addChild(setDRStepBtn)
    panel.journalDRSetBtn = setDRStepBtn

    local decDRBtn = ISButton:new(padding + 170, y - 2, 36, 20, "-1", self, BurdJournals.UI.DebugPanel.onJournalDecrementDRStep)
    decDRBtn:initialise()
    decDRBtn:instantiate()
    decDRBtn.font = UIFont.Small
    decDRBtn.textColor = {r=1, g=1, b=1, a=1}
    decDRBtn.borderColor = {r=0.55, g=0.42, b=0.35, a=1}
    decDRBtn.backgroundColor = {r=0.34, g=0.23, b=0.2, a=1}
    panel:addChild(decDRBtn)
    panel.journalDRDecBtn = decDRBtn

    local incDRBtn = ISButton:new(padding + 210, y - 2, 36, 20, "+1", self, BurdJournals.UI.DebugPanel.onJournalIncrementDRStep)
    incDRBtn:initialise()
    incDRBtn:instantiate()
    incDRBtn.font = UIFont.Small
    incDRBtn.textColor = {r=1, g=1, b=1, a=1}
    incDRBtn.borderColor = {r=0.35, g=0.45, b=0.55, a=1}
    incDRBtn.backgroundColor = {r=0.2, g=0.26, b=0.34, a=1}
    panel:addChild(incDRBtn)
    panel.journalDRIncBtn = incDRBtn

    local resetDRBtn = ISButton:new(padding + 250, y - 2, 56, 20, "Reset", self, BurdJournals.UI.DebugPanel.onJournalResetDR)
    resetDRBtn:initialise()
    resetDRBtn:instantiate()
    resetDRBtn.font = UIFont.Small
    resetDRBtn.textColor = {r=1, g=1, b=1, a=1}
    resetDRBtn.borderColor = {r=0.5, g=0.35, b=0.25, a=1}
    resetDRBtn.backgroundColor = {r=0.3, g=0.2, b=0.12, a=1}
    panel:addChild(resetDRBtn)
    panel.journalDRResetBtn = resetDRBtn

    panel.journalDRHintLabel = ISLabel:new(padding + 312, y, 16, "", 0.55, 0.62, 0.72, 1, UIFont.Small, true)
    panel.journalDRHintLabel:initialise()
    panel.journalDRHintLabel:instantiate()
    panel:addChild(panel.journalDRHintLabel)
    y = y + 26

    panel.journalDRPreviewLabel = ISLabel:new(padding + 125, y - 2, 16, "N1 -- | N2 -- | N3 --", 0.65, 0.75, 0.85, 1, UIFont.Small, true)
    panel.journalDRPreviewLabel:initialise()
    panel.journalDRPreviewLabel:instantiate()
    panel:addChild(panel.journalDRPreviewLabel)
    y = y + 20
    
    -- =============================================
    -- TRAITS SECTION - Two columns
    -- =============================================
    
    -- Left column: Available Traits (to add)
    local availTraitsLabel = ISLabel:new(padding, y, 18, "Available Traits:", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    availTraitsLabel:initialise()
    availTraitsLabel:instantiate()
    panel:addChild(availTraitsLabel)
    
    -- Left column search field
    panel.journalAvailTraitSearchEntry = ISTextEntryBox:new("", padding + 105, y - 2, halfWidth - 115, 20)
    panel.journalAvailTraitSearchEntry:initialise()
    panel.journalAvailTraitSearchEntry:instantiate()
    panel.journalAvailTraitSearchEntry.font = UIFont.Small
    panel.journalAvailTraitSearchEntry:setTooltip("Filter available traits...")
    panel.journalAvailTraitSearchEntry.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterJournalAvailTraitList(self)
    end
    panel:addChild(panel.journalAvailTraitSearchEntry)
    
    -- Right column: Journal Traits (to remove)
    local journalTraitsLabel = ISLabel:new(padding + halfWidth + padding, y, 18, "In Journal:", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
    journalTraitsLabel:initialise()
    journalTraitsLabel:instantiate()
    panel:addChild(journalTraitsLabel)
    
    -- Right column search field
    panel.journalInTraitSearchEntry = ISTextEntryBox:new("", padding + halfWidth + padding + 70, y - 2, halfWidth - 80, 20)
    panel.journalInTraitSearchEntry:initialise()
    panel.journalInTraitSearchEntry:instantiate()
    panel.journalInTraitSearchEntry.font = UIFont.Small
    panel.journalInTraitSearchEntry:setTooltip("Filter journal traits...")
    panel.journalInTraitSearchEntry.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterJournalInTraitList(self)
    end
    panel:addChild(panel.journalInTraitSearchEntry)
    y = y + 22
    
    -- Trait lists - two columns
    local traitListHeight = 90
    
    -- Left column: Available traits list
    panel.journalAvailTraitList = ISScrollingListBox:new(padding, y, halfWidth, traitListHeight)
    panel.journalAvailTraitList:initialise()
    panel.journalAvailTraitList:instantiate()
    panel.journalAvailTraitList.itemheight = 22
    panel.journalAvailTraitList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.journalAvailTraitList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.journalAvailTraitList.doDrawItem = BurdJournals.UI.DebugPanel.drawJournalAvailTraitItem
    panel.journalAvailTraitList.onMouseDown = BurdJournals.UI.DebugPanel.onJournalAvailTraitListClick
    panel.journalAvailTraitList.parentPanel = self
    panel:addChild(panel.journalAvailTraitList)
    
    -- Right column: Journal traits list
    panel.journalInTraitList = ISScrollingListBox:new(padding + halfWidth + padding, y, halfWidth, traitListHeight)
    panel.journalInTraitList:initialise()
    panel.journalInTraitList:instantiate()
    panel.journalInTraitList.itemheight = 22
    panel.journalInTraitList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=1}
    panel.journalInTraitList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    panel.journalInTraitList.doDrawItem = BurdJournals.UI.DebugPanel.drawJournalInTraitItem
    panel.journalInTraitList.onMouseDown = BurdJournals.UI.DebugPanel.onJournalInTraitListClick
    panel.journalInTraitList.parentPanel = self
    panel:addChild(panel.journalInTraitList)
    y = y + traitListHeight + 10
    
    -- Action buttons row
    local btnWidth = 100
    local btnSpacing = 6
    local btnX = padding
    
    local clearSkillsBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Clear All Skills", self, BurdJournals.UI.DebugPanel.onJournalCmd)
    clearSkillsBtn:initialise()
    clearSkillsBtn:instantiate()
    clearSkillsBtn.font = UIFont.Small
    clearSkillsBtn.internal = "clearskills"
    clearSkillsBtn.textColor = {r=1, g=1, b=1, a=1}
    clearSkillsBtn.borderColor = {r=0.5, g=0.3, b=0.3, a=1}
    clearSkillsBtn.backgroundColor = {r=0.35, g=0.15, b=0.15, a=1}
    panel:addChild(clearSkillsBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local clearTraitsBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Clear All Traits", self, BurdJournals.UI.DebugPanel.onJournalCmd)
    clearTraitsBtn:initialise()
    clearTraitsBtn:instantiate()
    clearTraitsBtn.font = UIFont.Small
    clearTraitsBtn.internal = "cleartraits"
    clearTraitsBtn.textColor = {r=1, g=1, b=1, a=1}
    clearTraitsBtn.borderColor = {r=0.5, g=0.3, b=0.3, a=1}
    clearTraitsBtn.backgroundColor = {r=0.35, g=0.15, b=0.15, a=1}
    panel:addChild(clearTraitsBtn)
    btnX = btnX + btnWidth + btnSpacing
    
    local refreshBtn = ISButton:new(btnX, y, 70, btnHeight, "Refresh", self, BurdJournals.UI.DebugPanel.onJournalRefresh)
    refreshBtn:initialise()
    refreshBtn:instantiate()
    refreshBtn.font = UIFont.Small
    refreshBtn.textColor = {r=1, g=1, b=1, a=1}
    refreshBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    refreshBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
    panel:addChild(refreshBtn)

    -- Store reference
    self.journalPanel = panel
    self:updateJournalEditorMetaVisibility()
end

local function getSelectedJournalOwnerData(panel)
    if not panel or not panel.journalOwnerCombo then
        return nil
    end
    local selected = panel.journalOwnerCombo.selected or 1
    return panel.journalOwnerCombo:getOptionData(selected)
end

local function trimJournalEditorText(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

function BurdJournals.UI.DebugPanel:updateJournalEditorMetaVisibility()
    local panel = self.journalPanel
    if not panel then
        return
    end

    local selectedType = getJournalEditTypeFromCombo(panel)
    local isFilled = selectedType == "filled"
    local ownerSelection = getSelectedJournalOwnerData(panel)
    local useCustomAuthor = (not isFilled) or (ownerSelection and ownerSelection.isCustom == true)

    if panel.journalOwnerLabel then
        local labelText = isFilled
            and ((BurdJournals.safeGetText and BurdJournals.safeGetText("UI_BurdJournals_DebugSpawnOwnerAssign", "Assign to Player:")) or "Assign to Player:")
            or "Author:"
        panel.journalOwnerLabel:setName(labelText)
    end
    if panel.journalOwnerCombo then
        panel.journalOwnerCombo:setVisible(isFilled)
    end
    if panel.journalOwnerCustomEntry then
        panel.journalOwnerCustomEntry:setVisible(useCustomAuthor)
    end
end

function BurdJournals.UI.DebugPanel:onJournalTypeChange(combo)
    local panel = self.journalPanel
    if not panel then
        return
    end
    local selectedType = getJournalEditTypeFromCombo(panel)
    panel.journalEditType = selectedType
    self:updateJournalEditorMetaVisibility()
    self:setStatus("Journal type set to " .. tostring(selectedType) .. " (pending apply)", {r=0.88, g=0.78, b=0.42})
end

function BurdJournals.UI.DebugPanel:onJournalOwnerChange(combo)
    self:updateJournalEditorMetaVisibility()
end

function BurdJournals.UI.DebugPanel:onJournalProfileChange(combo)
    local panel = self.journalPanel
    if not panel then
        return
    end
    local profile = getJournalProfileFromCombo(panel)
    panel.journalProfile = profile
    local label = (profile == "debug") and "Debug" or "Normal"
    self:setStatus("Journal profile set to " .. label .. " (pending apply)", {r=0.88, g=0.78, b=0.42})
end

function BurdJournals.UI.DebugPanel:onJournalOriginChange(combo)
    local panel = self.journalPanel
    if not panel then
        return
    end
    local originMode = getJournalOriginFromCombo(panel)
    panel.journalOriginMode = originMode
    self:setStatus("Journal origin set to " .. getOriginModeLabel(originMode) .. " (pending apply)", {r=0.88, g=0.78, b=0.42})
end

function BurdJournals.UI.DebugPanel:onJournalApplyMetadata()
    local panel = self.journalPanel
    local journal = self.editingJournal
    if not panel or not journal then
        self:setStatus("No journal selected", {r=1, g=0.6, b=0.3})
        return
    end

    local selectedType = getJournalEditTypeFromCombo(panel)
    local profile = getJournalProfileFromCombo(panel)
    local originMode = getJournalOriginFromCombo(panel)
    local desiredItemType = getEditorItemTypeForJournalType(selectedType)
    local currentItemType = journal.getFullType and journal:getFullType() or nil
    local shouldConvertItemType = desiredItemType ~= nil and currentItemType ~= nil and desiredItemType ~= currentItemType
    local useDebugProfile = profile == "debug"

    if journal.__bsjServerProxy and shouldConvertItemType then
        self:setStatus("Type conversion requires a live journal item (not server snapshot).", {r=1, g=0.6, b=0.3})
        return
    end

    local modData = journal:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    local data = modData.BurdJournals

    data.isDebugSpawned = useDebugProfile
    data.isDebugEdited = useDebugProfile and true or nil
    applyOriginModeToJournalData(data, originMode)

    local preservedCursedReward = data.isCursedReward == true
    local preservedCursedEffectType = data.cursedEffectType
    local preservedCursedByCharacter = data.cursedUnleashedByCharacterId
    local preservedCursedByUsername = data.cursedUnleashedByUsername
    local preservedCursedAtHours = data.cursedUnleashedAtHours

    -- Normalize type markers before applying selected journal type.
    data.isWorn = nil
    data.isBloody = nil
    data.wasFromWorn = nil
    data.wasFromBloody = nil
    data.isCursedJournal = nil
    data.isCursedReward = nil
    data.cursedEffectType = nil
    data.cursedUnleashedByCharacterId = nil
    data.cursedUnleashedByUsername = nil
    data.cursedUnleashedAtHours = nil
    data.cursedPendingRewards = nil

    if selectedType == "worn" then
        data.isWorn = true
        data.wasFromWorn = true
    elseif selectedType == "bloody" then
        data.isBloody = true
        data.wasFromBloody = true
        if preservedCursedReward then
            data.isCursedReward = true
            data.cursedState = "unleashed"
            data.cursedEffectType = preservedCursedEffectType
            data.cursedUnleashedByCharacterId = preservedCursedByCharacter
            data.cursedUnleashedByUsername = preservedCursedByUsername
            data.cursedUnleashedAtHours = preservedCursedAtHours
        end
    elseif selectedType == "cursed" then
        data.isCursedJournal = true
        data.isCursedReward = false
        data.cursedState = (data.cursedState == "unleashed") and "unleashed" or "dormant"
    else
        if selectedType ~= "blank" then
            data.cursedState = nil
            data.cursedEffectType = nil
        end
    end

    if selectedType == "blank" then
        data.isWritten = nil
    else
        data.isWritten = true
    end

    -- Owner/author assignment is type-aware.
    data.ownerMode = "none"
    data.ownerSteamId = nil
    data.ownerUsername = nil
    data.ownerCharacterName = nil
    data.author = nil

    if selectedType == "filled" then
        local ownerData = getSelectedJournalOwnerData(panel)
        if ownerData and ownerData.isPlayer then
            data.ownerMode = "player_assignment"
            data.ownerSteamId = ownerData.steamId
            data.ownerUsername = ownerData.username
            data.ownerCharacterName = ownerData.characterName
            data.author = ownerData.characterName
        elseif ownerData and ownerData.isCustom then
            local customAuthor = trimJournalEditorText(panel.journalOwnerCustomEntry and panel.journalOwnerCustomEntry:getText() or "")
            if customAuthor ~= "" then
                data.ownerMode = "custom"
                data.ownerCharacterName = customAuthor
                data.author = customAuthor
            end
        end
    else
        local authorText = trimJournalEditorText(panel.journalOwnerCustomEntry and panel.journalOwnerCustomEntry:getText() or "")
        if authorText ~= "" then
            data.ownerMode = "player_author"
            data.ownerCharacterName = authorText
            data.author = authorText
        end
    end

    local flavorText = trimJournalEditorText(panel.journalFlavorEntry and panel.journalFlavorEntry:getText() or "")
    data.flavorText = (flavorText ~= "") and flavorText or nil

    if panel.journalAgeEntry and panel.journalAgeEntry.getText then
        local ageHours = math.max(0, tonumber(panel.journalAgeEntry:getText() or "0") or 0)
        local worldAge = (getGameTime and getGameTime() and getGameTime():getWorldAgeHours()) or 0
        data.timestamp = math.max(0, tonumber(worldAge) - ageHours)
    end

    local extraPayload = nil
    if shouldConvertItemType then
        extraPayload = {
            desiredJournalType = selectedType,
            desiredItemType = desiredItemType
        }
    end

    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal, {
        profile = profile,
        originMode = originMode,
        extraPayload = extraPayload
    })

    -- Rebind to live item by UUID in case server replaced item type.
    self:refreshJournalPickerList(true)
    if panel.journalSelectCombo and (panel.journalSelectCombo.selected or 0) > 1 then
        self:onJournalUseDropdownSelection()
    end
    self:refreshJournalEditorData()

    self:setStatus(
        "Applied metadata: "
            .. tostring(selectedType)
            .. " | "
            .. ((profile == "debug") and "Debug" or "Normal")
            .. " | "
            .. getOriginModeLabel(originMode),
        {r=0.3, g=1, b=0.5}
    )
end

function BurdJournals.UI.DebugPanel:onJournalApplyProfile()
    self:onJournalApplyMetadata()
end

function BurdJournals.UI.DebugPanel:onJournalConvertToNormal()
    local panel = self.journalPanel
    if not panel or not panel.journalProfileCombo then
        self:setStatus("Profile controls unavailable", {r=1, g=0.6, b=0.3})
        return
    end
    setJournalProfileCombo(panel, "normal")
    self:onJournalApplyMetadata()
end

function BurdJournals.UI.DebugPanel:onJournalConvertToDebug()
    local panel = self.journalPanel
    if not panel or not panel.journalProfileCombo then
        self:setStatus("Profile controls unavailable", {r=1, g=0.6, b=0.3})
        return
    end
    setJournalProfileCombo(panel, "debug")
    self:onJournalApplyMetadata()
end

-- Filter journal skill list by search text
function BurdJournals.UI.DebugPanel.filterJournalSkillList(self)
    local panel = self.journalPanel
    if not panel or not panel.journalSkillSearchEntry or not panel.journalSkillList then return end
    
    local searchText = panel.journalSkillSearchEntry:getText() or ""
    
    for _, itemData in ipairs(panel.journalSkillList.items) do
        if itemData.item then
            itemData.item.hidden = searchText ~= "" and
                not debugSearchMatches(searchText, itemData.item.displayName, itemData.item.name)
        end
    end
end

-- Filter available trait list (left column) by search text
function BurdJournals.UI.DebugPanel.filterJournalAvailTraitList(self)
    local panel = self.journalPanel
    if not panel or not panel.journalAvailTraitSearchEntry or not panel.journalAvailTraitList then return end
    
    local searchText = panel.journalAvailTraitSearchEntry:getText() or ""
    
    for _, itemData in ipairs(panel.journalAvailTraitList.items) do
        if itemData.item then
            itemData.item.hidden = searchText ~= "" and
                not debugSearchMatches(searchText, itemData.item.displayName, itemData.item.id)
        end
    end
end

-- Filter journal trait list (right column) by search text
function BurdJournals.UI.DebugPanel.filterJournalInTraitList(self)
    local panel = self.journalPanel
    if not panel or not panel.journalInTraitSearchEntry or not panel.journalInTraitList then return end
    
    local searchText = panel.journalInTraitSearchEntry:getText() or ""
    
    for _, itemData in ipairs(panel.journalInTraitList.items) do
        if itemData.item then
            itemData.item.hidden = searchText ~= "" and
                not debugSearchMatches(searchText, itemData.item.displayName, itemData.item.id)
        end
    end
end

local function getJournalAuthorForPicker(journalData)
    if not journalData or type(journalData) ~= "table" then
        return "Unknown"
    end
    return tostring(
        journalData.ownerCharacterName
        or journalData.author
        or journalData.ownerUsername
        or journalData.restoredBy
        or "Unknown"
    )
end

local function addJournalPickerEntry(entries, seenKeys, item)
    if not item or not item.getFullType then return end

    local fullType = item:getFullType()
    if not fullType then return end
    if not (
        string.find(fullType, "SurvivalJournal")
        or string.find(fullType, "BloodyJournal")
        or string.find(fullType, "WornJournal")
    ) then
        return
    end

    local journalData = BurdJournals.getJournalData and BurdJournals.getJournalData(item) or nil
    if type(journalData) ~= "table" then
        return
    end

    local uuid = tostring(journalData.uuid or "")
    local key
    if uuid ~= "" then
        key = "uuid:" .. uuid
    elseif item.getID then
        key = "id:" .. tostring(item:getID())
    else
        key = "item:" .. tostring(item)
    end
    if seenKeys[key] then
        return
    end
    seenKeys[key] = true

    local journalName = tostring((item.getName and item:getName()) or "Journal")
    local author = getJournalAuthorForPicker(journalData)
    local uuidDisplay = (uuid ~= "" and uuid) or "No UUID"
    local display = journalName .. " | " .. author .. " | " .. uuidDisplay

    table.insert(entries, {
        journal = item,
        uuid = uuid,
        name = journalName,
        author = author,
        display = display
    })
end

local function collectJournalsFromContainer(container, entries, seenKeys)
    if not container then return end
    local items = container.getItems and container:getItems() or nil
    if not items then return end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            addJournalPickerEntry(entries, seenKeys, item)
            if item.getInventory then
                local childInventory = item:getInventory()
                if childInventory then
                    collectJournalsFromContainer(childInventory, entries, seenKeys)
                end
            end
        end
    end
end

function BurdJournals.UI.DebugPanel.collectSelectableJournals(player)
    local entries = {}
    local seenKeys = {}
    if not player then
        return entries
    end

    local inventory = player:getInventory()
    if inventory then
        collectJournalsFromContainer(inventory, entries, seenKeys)
    end

    if getPlayerLoot and not isServer() then
        local playerNum = player:getPlayerNum()
        if playerNum then
            local lootPanel = getPlayerLoot(playerNum)
            if lootPanel and lootPanel.inventoryPane and lootPanel.inventoryPane.inventories then
                for i = 1, #lootPanel.inventoryPane.inventories do
                    local containerInfo = lootPanel.inventoryPane.inventories[i]
                    if containerInfo and containerInfo.inventory then
                        collectJournalsFromContainer(containerInfo.inventory, entries, seenKeys)
                    end
                end
            end
        end
    end

    local square = player:getCurrentSquare()
    if square and getCell then
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
                                    collectJournalsFromContainer(container, entries, seenKeys)
                                end
                            end
                            if obj and obj.getInventory then
                                local inv = obj:getInventory()
                                if inv then
                                    collectJournalsFromContainer(inv, entries, seenKeys)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(entries, function(a, b)
        return string.lower(a.display) < string.lower(b.display)
    end)
    return entries
end

function BurdJournals.UI.DebugPanel:refreshJournalPickerList(keepSelection)
    local panel = self.journalPanel
    if not panel or not panel.journalSelectCombo then return end

    local selectedUuid = nil
    if keepSelection and panel.journalSelectCombo.selected and panel.journalSelectCombo.selected > 1 then
        local selectedData = panel.journalSelectCombo:getOptionData(panel.journalSelectCombo.selected)
        selectedUuid = selectedData and selectedData.uuid or nil
    end
    if (not selectedUuid or selectedUuid == "") and self.editingJournal and BurdJournals.getJournalData then
        local currentData = BurdJournals.getJournalData(self.editingJournal)
        if currentData and currentData.uuid then
            selectedUuid = tostring(currentData.uuid)
        end
    end

    local entries = BurdJournals.UI.DebugPanel.collectSelectableJournals(self.player)
    panel.journalPickerEntries = entries

    panel.journalSelectCombo:clear()
    panel.journalSelectCombo:addOptionWithData("Select journal...", nil)

    local selectedIndex = 1
    for i, entry in ipairs(entries) do
        panel.journalSelectCombo:addOptionWithData(entry.display, entry)
        if selectedUuid and selectedUuid ~= "" and entry.uuid == selectedUuid then
            selectedIndex = i + 1
        end
    end
    panel.journalSelectCombo.selected = selectedIndex

    if panel.journalSelectCombo.selected and panel.journalSelectCombo.selected > 1 then
        BurdJournals.UI.DebugPanel.onJournalPickerChanged(self, panel.journalSelectCombo)
    end
end

function BurdJournals.UI.DebugPanel:onJournalRefreshList()
    self:refreshJournalPickerList(true)
    local panel = self.journalPanel
    local count = panel and panel.journalPickerEntries and #panel.journalPickerEntries or 0
    self:setStatus("Journal list refreshed (" .. tostring(count) .. " found)", {r=0.5, g=0.8, b=1})
end

function BurdJournals.UI.DebugPanel:onJournalPickerChanged(combo)
    local panel = self.journalPanel
    if not panel or not panel.journalUUIDEntry or not combo then return end
    local selectedData = combo.selected and combo.selected > 1 and combo:getOptionData(combo.selected) or nil
    panel.journalUUIDEntry:setText(selectedData and tostring(selectedData.uuid or "") or "")
end

function BurdJournals.UI.DebugPanel:onJournalUseDropdownSelection()
    local panel = self.journalPanel
    if not panel or not panel.journalSelectCombo then return end

    local selectedIndex = panel.journalSelectCombo.selected or 0
    if selectedIndex <= 1 then
        self:setStatus("Select a journal from the dropdown first", {r=1, g=0.6, b=0.3})
        return
    end

    local selectedData = panel.journalSelectCombo:getOptionData(selectedIndex)
    if not selectedData then
        self:setStatus("Selected journal entry is unavailable", {r=1, g=0.6, b=0.3})
        return
    end

    if selectedData.journal then
        self.editingJournal = selectedData.journal
        self:refreshJournalEditorData()
        self:setStatus("Selected: " .. tostring(selectedData.name or "Journal"), {r=0.3, g=1, b=0.5})
        return
    end

    if selectedData.uuid and selectedData.uuid ~= "" then
        panel.journalUUIDEntry:setText(selectedData.uuid)
        self:onJournalFindByUUID()
        return
    end

    self:setStatus("Selected entry cannot be resolved", {r=1, g=0.6, b=0.3})
end

local function getServerIndexDisplayName(entry)
    local itemName = entry and entry.itemName
    if type(itemName) == "string" and itemName ~= "" then
        return itemName
    end

    local itemType = tostring(entry and entry.itemType or "")
    if itemType:find("_Bloody") or entry.wasFromBloody then
        return "Bloody Journal"
    end
    if itemType:find("_Worn") or entry.wasFromWorn then
        return "Worn Journal"
    end
    if entry and entry.isPlayerCreated == true then
        return "Personal Journal"
    end
    if itemType ~= "" then
        local short = itemType:match("^.+%.(.+)$")
        if short and short ~= "" then
            return short
        end
    end
    return "Journal"
end

local function getServerIndexDisplayText(entry)
    local name = getServerIndexDisplayName(entry)
    local author = tostring((entry and (entry.ownerCharacterName or entry.ownerUsername)) or "Unknown")
    local uuid = tostring((entry and entry.uuid) or "No UUID")
    return name .. " | " .. author .. " | " .. uuid
end

function BurdJournals.UI.DebugPanel:applyServerJournalIndexList(entries, meta)
    local panel = self.journalPanel
    if not panel or not panel.journalServerIndexCombo then return end

    local selectedUuid = nil
    if panel.journalServerIndexCombo.selected and panel.journalServerIndexCombo.selected > 1 then
        local selectedData = panel.journalServerIndexCombo:getOptionData(panel.journalServerIndexCombo.selected)
        selectedUuid = selectedData and selectedData.uuid or nil
    end
    if (not selectedUuid or selectedUuid == "") and panel.journalUUIDEntry then
        selectedUuid = tostring(panel.journalUUIDEntry:getText() or "")
    end

    local normalizedEntries = entries
    if type(normalizedEntries) ~= "table" and BurdJournals.normalizeTable then
        normalizedEntries = BurdJournals.normalizeTable(normalizedEntries)
    end
    if type(normalizedEntries) ~= "table" then
        normalizedEntries = {}
    end

    panel.journalServerIndexEntries = {}
    for _, entry in pairs(normalizedEntries) do
        if type(entry) == "table" and entry.uuid then
            entry.display = getServerIndexDisplayText(entry)
            table.insert(panel.journalServerIndexEntries, entry)
        end
    end

    table.sort(panel.journalServerIndexEntries, function(a, b)
        local ats = tonumber(a.lastSeenTs) or 0
        local bts = tonumber(b.lastSeenTs) or 0
        if ats ~= bts then return ats > bts end
        return tostring(a.uuid or "") < tostring(b.uuid or "")
    end)

    panel.journalServerIndexCombo:clear()
    panel.journalServerIndexCombo:addOptionWithData("Server index...", nil)

    local selectedIndex = 1
    for i, entry in ipairs(panel.journalServerIndexEntries) do
        panel.journalServerIndexCombo:addOptionWithData(entry.display, entry)
        if selectedUuid and selectedUuid ~= "" and tostring(entry.uuid) == tostring(selectedUuid) then
            selectedIndex = i + 1
        end
    end
    panel.journalServerIndexCombo.selected = selectedIndex

    if meta then
        local count = tonumber(meta.count) or #panel.journalServerIndexEntries
        local total = tonumber(meta.total) or count
        if meta.truncated then
            self:setStatus("Server index loaded " .. tostring(count) .. "/" .. tostring(total) .. " (truncated)", {r=0.95, g=0.8, b=0.35})
        else
            self:setStatus("Server index loaded (" .. tostring(count) .. " entries)", {r=0.5, g=0.8, b=1})
        end
    end
end

function BurdJournals.UI.DebugPanel:onJournalRefreshServerIndex()
    if sendClientCommand and isClient and isClient() then
        sendClientCommand("BurdJournals", "debugListJournalUUIDIndex", {maxEntries = 500})
        self:setStatus("Fetching server journal index...", {r=0.5, g=0.8, b=1})
        return
    end

    local cache = ModData.getOrCreate and ModData.getOrCreate("BurdJournals_JournalUUIDIndex") or nil
    local journals = cache and cache.journals or {}
    if type(journals) ~= "table" and BurdJournals.normalizeTable then
        journals = BurdJournals.normalizeTable(journals) or {}
    end

    local entries = {}
    for uuid, entry in pairs(journals or {}) do
        if type(entry) == "table" then
            local normalized = {}
            for k, v in pairs(entry) do normalized[k] = v end
            normalized.uuid = normalized.uuid or uuid
            table.insert(entries, normalized)
        end
    end
    self:applyServerJournalIndexList(entries, {count = #entries, total = #entries, truncated = false})
end

function BurdJournals.UI.DebugPanel:onJournalServerIndexChanged(combo)
    local panel = self.journalPanel
    if not panel or not panel.journalUUIDEntry or not combo then return end
    local selectedData = combo.selected and combo.selected > 1 and combo:getOptionData(combo.selected) or nil
    panel.journalUUIDEntry:setText(selectedData and tostring(selectedData.uuid or "") or "")
end

local function getCachedDebugBackupByUUID(uuid)
    local trimmed = tostring(uuid or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return nil
    end

    local cache = ModData.getOrCreate and ModData.getOrCreate("BurdJournals_DebugJournalCache") or nil
    local journals = cache and cache.journals or nil
    if type(journals) ~= "table" and BurdJournals.normalizeTable then
        journals = BurdJournals.normalizeTable(journals)
    end
    if type(journals) ~= "table" then
        return nil
    end

    local direct = journals[trimmed]
    if type(direct) == "table" then
        return direct
    end

    for key, entry in pairs(journals) do
        if type(entry) == "table" then
            local entryUUID = tostring(entry.uuid or key or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if entryUUID == trimmed then
                return entry
            end
        end
    end

    return nil
end

function BurdJournals.UI.DebugPanel:onJournalUseServerIndexSelection()
    local panel = self.journalPanel
    if not panel or not panel.journalServerIndexCombo then return end
    local selectedIndex = panel.journalServerIndexCombo.selected or 0
    if selectedIndex <= 1 then
        self:setStatus("Select a server-index journal first", {r=1, g=0.6, b=0.3})
        return
    end

    local selectedData = panel.journalServerIndexCombo:getOptionData(selectedIndex)
    local uuid = selectedData and tostring(selectedData.uuid or "") or ""
    if uuid == "" then
        self:setStatus("Selected server-index entry has no UUID", {r=1, g=0.6, b=0.3})
        return
    end

    panel.journalUUIDEntry:setText(uuid)
    local localJournal = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(self.player, uuid) or nil
    if localJournal then
        self.editingJournal = localJournal
        self:refreshJournalEditorData()
        self:setStatus("Selected from server index", {r=0.3, g=1, b=0.5})
        return
    end

    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.createServerJournalProxy then
        local cachedBackup = getCachedDebugBackupByUUID(uuid)
        local proxy = BurdJournals.UI.DebugPanel.createServerJournalProxy(uuid, selectedData, cachedBackup)
        if proxy then
            self.editingJournal = proxy
            self:refreshJournalEditorData()
            self:setStatus("Loaded server-index snapshot; checking for live item...", {r=0.95, g=0.8, b=0.35})
        end
    end

    self:onJournalFindByUUID()
end

function BurdJournals.UI.DebugPanel.createServerJournalProxy(uuid, indexEntry, backupData)
    local resolvedUUID = tostring(uuid or "")
    if resolvedUUID == "" then
        return nil
    end

    local normalized = BurdJournals.normalizeJournalData and BurdJournals.normalizeJournalData(backupData) or backupData
    if type(normalized) ~= "table" then
        normalized = {}
    end

    normalized.skills = normalized.skills or {}
    normalized.traits = normalized.traits or {}
    normalized.recipes = normalized.recipes or {}
    normalized.stats = normalized.stats or {}
    normalized.skillReadCounts = normalized.skillReadCounts or {}

    normalized.uuid = normalized.uuid or resolvedUUID
    normalized.isDebugSpawned = normalized.isDebugSpawned == true
    normalized.isDebugEdited = normalized.isDebugSpawned and (normalized.isDebugEdited == true) or nil
    local normalizedItemType = normalized.itemType or (type(indexEntry) == "table" and indexEntry.itemType) or ""
    local isWornType = type(normalizedItemType) == "string" and string.find(normalizedItemType, "_Worn", 1, true) ~= nil
    local isBloodyType = type(normalizedItemType) == "string" and string.find(normalizedItemType, "_Bloody", 1, true) ~= nil
    local isCursedType = normalizedItemType == (BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal")
    local isFoundJournal = normalized.isWorn == true
        or normalized.isBloody == true
        or normalized.isCursedJournal == true
        or normalized.isCursedReward == true
        or isWornType
        or isBloodyType
        or isCursedType
        or (type(indexEntry) == "table" and indexEntry.isPlayerCreated == false)
    if isFoundJournal then
        normalized.isPlayerCreated = false
    elseif normalized.isPlayerCreated == nil then
        normalized.isPlayerCreated = true
    end
    normalized.sanitizedVersion = normalized.sanitizedVersion or (BurdJournals.SANITIZE_VERSION or 1)
    normalized.isWritten = true

    if indexEntry and type(indexEntry) == "table" then
        normalized.itemType = normalized.itemType or indexEntry.itemType
        normalized.itemName = normalized.itemName or indexEntry.itemName
        normalized.ownerUsername = normalized.ownerUsername or indexEntry.ownerUsername
        normalized.ownerSteamId = normalized.ownerSteamId or indexEntry.ownerSteamId
        normalized.ownerCharacterName = normalized.ownerCharacterName or indexEntry.ownerCharacterName
        normalized.wasFromWorn = normalized.wasFromWorn == true or indexEntry.wasFromWorn == true
        normalized.wasFromBloody = normalized.wasFromBloody == true or indexEntry.wasFromBloody == true
        normalized.wasRestored = normalized.wasRestored == true or indexEntry.wasRestored == true
    end

    local itemType = normalized.itemType or "BurdJournals.FilledSurvivalJournal"
    local itemName = normalized.itemName or "Server Journal"
    local itemId = tonumber(indexEntry and indexEntry.itemId) or -1

    local proxy = {
        __bsjServerProxy = true,
        __bsjUUID = resolvedUUID,
        __bsjIndexEntry = indexEntry,
        __bsjmodData = {BurdJournals = normalized},
        __bsjItemType = itemType,
        __bsjItemName = itemName,
        __bsjItemId = itemId,
        __bsjDirty = false,
    }

    function proxy:getModData()
        return self.__bsjmodData
    end

    function proxy:getID()
        return self.__bsjItemId
    end

    function proxy:getFullType()
        return self.__bsjItemType
    end

    function proxy:getName()
        return self.__bsjItemName
    end

    function proxy:transmitModData()
        return
    end

    return proxy
end

-- Select a journal from the dropdown list (fallback picks first match)
function BurdJournals.UI.DebugPanel:onJournalSelectFromInventory()
    self:refreshJournalPickerList(true)
    local panel = self.journalPanel
    if not panel or not panel.journalPickerEntries or #panel.journalPickerEntries == 0 then
        self:setStatus("No journals found nearby or in inventory", {r=1, g=0.5, b=0.5})
        return
    end

    if not panel.journalSelectCombo.selected or panel.journalSelectCombo.selected <= 1 then
        panel.journalSelectCombo.selected = 2
    end
    self:onJournalUseDropdownSelection()
end

local function getJournalUUIDInput(panel)
    if not panel or not panel.journalPanel or not panel.journalPanel.journalUUIDEntry then
        return nil
    end
    local raw = panel.journalPanel.journalUUIDEntry:getText()
    if not raw then return nil end
    local uuid = tostring(raw):gsub("^%s+", ""):gsub("%s+$", "")
    if uuid == "" then
        return nil
    end
    return uuid
end

local function getDebugXPModeLabel(mode)
    if mode == true then
        return "baseline"
    end
    if mode == false then
        return "absolute"
    end
    return "auto"
end

local function normalizeDebugJournalXPMode(data, player)
    if type(data) ~= "table" then
        return nil, nil, false, false
    end

    local modeBefore = data.recordedWithBaseline
    local modeAfter = BurdJournals.getJournalSkillRecordingMode
        and BurdJournals.getJournalSkillRecordingMode(data, player)
        or (modeBefore == true)
    local autoRepaired = false

    if modeAfter and data.recordedWithBaseline == true and type(data.skills) == "table" and player and player.getXp then
        local sampledSkills = 0
        local suspiciousAbsoluteSkills = 0
        for skillName, storedData in pairs(data.skills) do
            local storedXP = tonumber(type(storedData) == "table" and storedData.xp or storedData)
            if storedXP and storedXP > 0 then
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
                if perk then
                    sampledSkills = sampledSkills + 1
                    local actualXP = player:getXp():getXP(perk)
                    local baselineXP = math.max(0, tonumber(BurdJournals.getSkillBaseline and BurdJournals.getSkillBaseline(player, skillName) or 0) or 0)
                    local earnedXP = math.max(0, actualXP - baselineXP)
                    if storedXP > (earnedXP + 0.001) and storedXP <= (actualXP + 0.001) then
                        suspiciousAbsoluteSkills = suspiciousAbsoluteSkills + 1
                    end
                end
            end
        end
        if sampledSkills > 0 and suspiciousAbsoluteSkills >= math.max(1, math.floor(sampledSkills * 0.5)) then
            modeAfter = false
            autoRepaired = true
        end
    end

    if data.recordedWithBaseline ~= modeAfter then
        data.recordedWithBaseline = modeAfter
        return modeBefore, modeAfter, true, autoRepaired
    end

    return modeBefore, modeAfter, false, autoRepaired
end

function BurdJournals.UI.DebugPanel:onJournalFindByUUID()
    local uuid = getJournalUUIDInput(self)
    if not uuid then
        self:setStatus("Enter a journal UUID first", {r=1, g=0.6, b=0.3})
        return
    end

    local panel = self.journalPanel
    if panel and panel.journalServerIndexCombo and panel.journalServerIndexEntries then
        for i, entry in ipairs(panel.journalServerIndexEntries) do
            if tostring(entry.uuid or "") == tostring(uuid) then
                panel.journalServerIndexCombo.selected = i + 1
                break
            end
        end
    end

    if sendClientCommand and isClient and isClient() then
        sendClientCommand("BurdJournals", "debugLookupJournalByUUID", {uuid = uuid})
        self:setStatus("Looking up UUID on server...", {r=0.5, g=0.8, b=1})
        return
    end

    -- SP/local fallback
    local journal = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(self.player, uuid)
    if not journal then
        self:setStatus("UUID not found locally. Move closer to the container and retry.", {r=1, g=0.6, b=0.3})
        return
    end

    self.editingJournal = journal
    self:refreshJournalEditorData()
    self:setStatus("Selected journal by UUID", {r=0.3, g=1, b=0.5})
end

function BurdJournals.UI.DebugPanel:onJournalRepairByUUID()
    local uuid = getJournalUUIDInput(self)
    if not uuid then
        self:setStatus("Enter a journal UUID first", {r=1, g=0.6, b=0.3})
        return
    end

    if sendClientCommand and isClient and isClient() then
        sendClientCommand("BurdJournals", "debugRepairJournalByUUID", {uuid = uuid})
        self:setStatus("Repair request sent for UUID...", {r=0.5, g=0.8, b=1})
        return
    end

    -- SP/local fallback
    local journal = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(self.player, uuid)
    if not journal then
        self:setStatus("UUID not found locally. Move closer and retry.", {r=1, g=0.6, b=0.3})
        return
    end

    if BurdJournals.migrateJournalIfNeeded then
        BurdJournals.migrateJournalIfNeeded(journal, self.player)
    end
    if BurdJournals.sanitizeJournalData then
        BurdJournals.sanitizeJournalData(journal, self.player)
    end
    if BurdJournals.compactJournalData then
        BurdJournals.compactJournalData(journal)
    end
    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.finalizeJournalEdit then
        BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
    elseif journal.transmitModData then
        journal:transmitModData()
    end

    self.editingJournal = journal
    self:refreshJournalEditorData()
    self:setStatus("Local UUID repair complete", {r=0.3, g=1, b=0.5})
end

function BurdJournals.UI.DebugPanel:onJournalNormalizeXPModeByUUID()
    local uuid = getJournalUUIDInput(self)
    if not uuid then
        self:setStatus("Enter a journal UUID first", {r=1, g=0.6, b=0.3})
        return
    end

    if sendClientCommand and isClient and isClient() then
        sendClientCommand("BurdJournals", "debugRepairJournalByUUID", {uuid = uuid, normalizeXPMode = true})
        self:setStatus("Normalize-XP request sent...", {r=0.5, g=0.8, b=1})
        return
    end

    -- SP/local fallback
    local journal = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(self.player, uuid)
    if not journal then
        self:setStatus("UUID not found locally. Move closer and retry.", {r=1, g=0.6, b=0.3})
        return
    end

    local modData = journal:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    local data = modData.BurdJournals
    local modeBefore, modeAfter, modeChanged, autoRepaired = normalizeDebugJournalXPMode(data, self.player)

    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.finalizeJournalEdit then
        BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
    elseif journal.transmitModData then
        journal:transmitModData()
    end

    self.editingJournal = journal
    self:refreshJournalEditorData()

    local message = "XP mode already normalized (" .. getDebugXPModeLabel(modeAfter) .. ")"
    if modeChanged then
        message = "Normalized XP mode: " .. getDebugXPModeLabel(modeBefore) .. " -> " .. getDebugXPModeLabel(modeAfter)
    end
    if autoRepaired then
        message = message .. " [legacy mismatch repaired]"
    end
    self:setStatus(message, {r=0.3, g=1, b=0.5})
end

function BurdJournals.UI.DebugPanel:onJournalMarkRestoredByUUID()
    local uuid = getJournalUUIDInput(self)
    if not uuid then
        self:setStatus("Enter a journal UUID first", {r=1, g=0.6, b=0.3})
        return
    end

    if sendClientCommand and isClient and isClient() then
        sendClientCommand("BurdJournals", "debugRepairJournalByUUID", {uuid = uuid, markRestored = true})
        self:setStatus("Mark-restored request sent...", {r=0.5, g=0.8, b=1})
        return
    end

    -- SP/local fallback
    local journal = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(self.player, uuid)
    if not journal then
        self:setStatus("UUID not found locally. Move closer and retry.", {r=1, g=0.6, b=0.3})
        return
    end

    local modData = journal:getModData()
    modData.BurdJournals = modData.BurdJournals or {}
    local data = modData.BurdJournals
    data.isPlayerCreated = true
    data.wasRestored = true
    if data.wasFromWorn ~= true and data.wasFromBloody ~= true then
        data.wasFromWorn = true
    end
    data.restoredBy = data.restoredBy or (self.player and self.player:getUsername()) or "Admin"
    data.isWorn = false
    data.isBloody = false

    if BurdJournals.UI and BurdJournals.UI.DebugPanel and BurdJournals.UI.DebugPanel.finalizeJournalEdit then
        BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
    elseif journal.transmitModData then
        journal:transmitModData()
    end

    self.editingJournal = journal
    self:refreshJournalEditorData()
    self:setStatus("Marked journal as restored", {r=0.3, g=1, b=0.5})
end

function BurdJournals.UI.DebugPanel:onJournalDeleteByUUID()
    local uuid = getJournalUUIDInput(self)
    if not uuid then
        self:setStatus("Enter a journal UUID first", {r=1, g=0.6, b=0.3})
        return
    end

    if sendClientCommand and isClient and isClient() then
        sendClientCommand("BurdJournals", "debugDeleteJournalByUUID", {uuid = uuid})
        self:setStatus("Delete request sent for UUID...", {r=0.95, g=0.8, b=0.35})
        return
    end

    local removedLive = false
    local journal = BurdJournals.findJournalByUUID and BurdJournals.findJournalByUUID(self.player, uuid)
    if journal then
        local container = journal.getContainer and journal:getContainer() or nil
        if container then
            container:Remove(journal)
            removedLive = true
        end
    end

    local removedIndexEntries = 0
    local indexCache = ModData.getOrCreate and ModData.getOrCreate("BurdJournals_JournalUUIDIndex") or nil
    local indexTable = indexCache and indexCache.journals or nil
    if type(indexTable) ~= "table" and BurdJournals.normalizeTable then
        indexTable = BurdJournals.normalizeTable(indexTable)
        if indexCache then indexCache.journals = indexTable end
    end
    if type(indexTable) == "table" then
        for key, entry in pairs(indexTable) do
            local entryUUID = tostring((type(entry) == "table" and entry.uuid) or key or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if entryUUID == uuid then
                indexTable[key] = nil
                removedIndexEntries = removedIndexEntries + 1
            end
        end
    end

    local removedBackupEntries = 0
    local backupCache = ModData.getOrCreate and ModData.getOrCreate("BurdJournals_DebugJournalCache") or nil
    local backupTable = backupCache and backupCache.journals or nil
    if type(backupTable) ~= "table" and BurdJournals.normalizeTable then
        backupTable = BurdJournals.normalizeTable(backupTable)
        if backupCache then backupCache.journals = backupTable end
    end
    if type(backupTable) == "table" then
        for key, entry in pairs(backupTable) do
            local entryUUID = tostring((type(entry) == "table" and entry.uuid) or key or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if entryUUID == uuid then
                backupTable[key] = nil
                removedBackupEntries = removedBackupEntries + 1
            end
        end
    end

    if ModData.transmit then
        ModData.transmit("BurdJournals_JournalUUIDIndex")
        ModData.transmit("BurdJournals_DebugJournalCache")
    end

    self.editingJournal = nil
    self:refreshJournalEditorData()
    self:refreshJournalPickerList(true)
    self:onJournalRefreshServerIndex()

    if removedLive or removedIndexEntries > 0 or removedBackupEntries > 0 then
        self:setStatus("Deleted UUID data (live=" .. tostring(removedLive) .. ", index=" .. tostring(removedIndexEntries) .. ", backup=" .. tostring(removedBackupEntries) .. ")", {r=0.3, g=1, b=0.5})
    else
        self:setStatus("No live/cached journal data found for UUID", {r=1, g=0.6, b=0.3})
    end
end

function BurdJournals.UI.DebugPanel:onJournalDeleteByUUIDPrompt()
    local uuid = getJournalUUIDInput(self)
    if not uuid then
        self:setStatus("Enter a journal UUID first", {r=1, g=0.6, b=0.3})
        return
    end

    if not ISModalDialog then
        self:onJournalDeleteByUUID()
        return
    end

    local text = "Delete journal UUID:\n" .. tostring(uuid)
        .. "\n\nThis permanently removes the live journal item (if found) and purges cached UUID records."
        .. "\n\nAre you sure?"

    local panel = self
    local callback = function(_target, button)
        if isAffirmativeDialogButton(button) and panel and panel.onJournalDeleteByUUID then
            panel:onJournalDeleteByUUID()
        end
    end
    if BurdJournals.createAdaptiveModalDialog then
        BurdJournals.createAdaptiveModalDialog({
            player = self.player,
            text = text,
            yesNo = true,
            onClick = callback,
            minWidth = 430,
            maxWidth = 860,
            minHeight = 190,
        })
    else
        local w = 520
        local h = 190
        local x = (getCore():getScreenWidth() - w) / 2
        local y = (getCore():getScreenHeight() - h) / 2
        local modal = ISModalDialog:new(x, y, w, h, text, true, nil, callback)
        modal:initialise()
        modal:addToUIManager()
    end
end

-- Helper: normalize trait IDs for consistent comparisons (strip base prefixes)
function BurdJournals.UI.DebugPanel.normalizeTraitId(traitId)
    if BurdJournals.normalizeTraitId then
        return BurdJournals.normalizeTraitId(traitId)
    end
    return traitId
end

-- Helper: build a lookup of trait IDs (including aliases) from a traits table
function BurdJournals.UI.DebugPanel.buildTraitLookup(traitsTable)
    if BurdJournals.buildTraitLookup then
        return BurdJournals.buildTraitLookup(traitsTable)
    end
    return {}
end

-- Helper: check if a trait is already present in lookup (including aliases)
function BurdJournals.UI.DebugPanel.isTraitInLookup(lookup, traitId)
    if BurdJournals.isTraitInLookup then
        return BurdJournals.isTraitInLookup(lookup, traitId)
    end
    return false
end

-- Helper: remove a trait from table, including aliases and case variants
function BurdJournals.UI.DebugPanel.removeTraitFromTable(traitsTable, traitId)
    if BurdJournals.removeTraitFromTable then
        return BurdJournals.removeTraitFromTable(traitsTable, traitId)
    end
    return false
end

-- Helper: resolve the actual key used in a skills table (handles case/alias mismatches)
function BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, skillName)
    if BurdJournals.resolveSkillKey then
        return BurdJournals.resolveSkillKey(skillsTable, skillName)
    end
    return skillName
end

-- Helper: safely call base list mouse down without pcall
function BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    if ISScrollingListBox and ISScrollingListBox.onMouseDown then
        ISScrollingListBox.onMouseDown(self, x, y)
    end
end

-- Helper: build lookup of trait costs (positive/negative/neutral)
function BurdJournals.UI.DebugPanel.buildTraitCostLookup()
    if BurdJournals.buildTraitCostLookup then
        return BurdJournals.buildTraitCostLookup()
    end
    return {}
end

-- Refresh journal editor data
function BurdJournals.UI.DebugPanel:refreshJournalEditorData()
    local panel = self.journalPanel
    if not panel then return end
    local previousFocusedSkill = panel.journalFocusedSkill and tostring(panel.journalFocusedSkill) or nil

    -- Clear existing lists safely (ensure borderColor stays valid during clear)
    local function safeClearList(list)
        if not list then return end
        -- Ensure borderColor is valid before clear to prevent render crashes
        if not list.borderColor or type(list.borderColor) ~= "table" then
            list.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
        end
        if list.borderColor.b == nil then list.borderColor.b = 0.5 end
        if list.borderColor.r == nil then list.borderColor.r = 0.3 end
        if list.borderColor.g == nil then list.borderColor.g = 0.4 end
        if list.borderColor.a == nil then list.borderColor.a = 1 end
        list:clear()
    end

    safeClearList(panel.journalSkillList)
    safeClearList(panel.journalAvailTraitList)
    safeClearList(panel.journalInTraitList)
    
    local journal = self.editingJournal
    if not journal then
        panel.journalHeaderLabel:setName("No journal selected")
        panel.journalInfoLabel:setName("Right-click a filled journal and select 'Edit Journal'")
        setJournalEditTypeCombo(panel, "filled")
        setJournalProfileCombo(panel, "normal")
        setJournalOriginCombo(panel, "found")
        if panel.journalOwnerCustomEntry then panel.journalOwnerCustomEntry:setText("") end
        if panel.journalFlavorEntry then panel.journalFlavorEntry:setText("") end
        if panel.journalAgeEntry then panel.journalAgeEntry:setText("0") end
        self:updateJournalEditorMetaVisibility()
        panel.journalFocusedSkill = nil
        BurdJournals.UI.DebugPanel.updateJournalSkillLabel(self)
        return
    end

    -- Update header with journal name
    local journalName = journal:getName() or "Unknown Journal"
    if journal.__bsjServerProxy then
        journalName = journalName .. " [Server Snapshot]"
    end
    panel.journalHeaderLabel:setName(journalName)

    -- Get journal data
    local journalData = BurdJournals.getJournalData(journal)
    if not journalData then
        panel.journalInfoLabel:setName("No data in journal")
        setJournalEditTypeCombo(panel, inferJournalEditTypeFromItem(journal, nil))
        setJournalProfileCombo(panel, "normal")
        setJournalOriginCombo(panel, "found")
        if panel.journalOwnerCustomEntry then panel.journalOwnerCustomEntry:setText("") end
        if panel.journalFlavorEntry then panel.journalFlavorEntry:setText("") end
        if panel.journalAgeEntry then panel.journalAgeEntry:setText("0") end
        self:updateJournalEditorMetaVisibility()
        panel.journalFocusedSkill = nil
        BurdJournals.UI.DebugPanel.updateJournalSkillLabel(self)
        return
    end
    if panel.journalUUIDEntry then
        panel.journalUUIDEntry:setText(tostring(journalData.uuid or ""))
    end
    if panel.journalSelectCombo and panel.journalPickerEntries then
        local selectedIndex = panel.journalSelectCombo.selected or 1
        local targetUuid = tostring(journalData.uuid or "")
        for i, entry in ipairs(panel.journalPickerEntries) do
            if (entry.journal and entry.journal == journal) or (targetUuid ~= "" and entry.uuid == targetUuid) then
                selectedIndex = i + 1
                break
            end
        end
        panel.journalSelectCombo.selected = selectedIndex
    end
    if panel.journalServerIndexCombo and panel.journalServerIndexEntries then
        local selectedIndex = panel.journalServerIndexCombo.selected or 1
        local targetUuid = tostring(journalData.uuid or "")
        for i, entry in ipairs(panel.journalServerIndexEntries) do
            if targetUuid ~= "" and tostring(entry.uuid or "") == targetUuid then
                selectedIndex = i + 1
                break
            end
        end
        panel.journalServerIndexCombo.selected = selectedIndex
    end

    local journalProfile = (journalData.isDebugSpawned == true) and "debug" or "normal"
    setJournalProfileCombo(panel, journalProfile)
    local journalOriginMode = inferJournalOriginMode(journalData)
    setJournalOriginCombo(panel, journalOriginMode)
    local journalEditType = inferJournalEditTypeFromItem(journal, journalData)
    setJournalEditTypeCombo(panel, journalEditType)

    if panel.journalOwnerCombo then
        self:populateOwnerCombo({ownerCombo = panel.journalOwnerCombo})
    end
    local ownerAuthorText = trimJournalEditorText(journalData.ownerCharacterName or journalData.author or "")
    if panel.journalOwnerCustomEntry then
        panel.journalOwnerCustomEntry:setText(ownerAuthorText)
    end
    if panel.journalOwnerCombo then
        local noneIndex = findOwnerOptionIndexByCombo(panel.journalOwnerCombo, function(optionData)
            return type(optionData) == "table" and optionData.isNone == true
        end) or 1
        local customIndex = findOwnerOptionIndexByCombo(panel.journalOwnerCombo, function(optionData)
            return type(optionData) == "table" and optionData.isCustom == true
        end)

        local selectedOwnerIndex = noneIndex
        if journalEditType == "filled" then
            selectedOwnerIndex = findOwnerOptionIndexByCombo(panel.journalOwnerCombo, function(optionData)
                if type(optionData) ~= "table" or optionData.isPlayer ~= true then
                    return false
                end
                local optionSteam = tostring(optionData.steamId or "")
                local dataSteam = tostring(journalData.ownerSteamId or "")
                if optionSteam ~= "" and dataSteam ~= "" and optionSteam == dataSteam then
                    return true
                end
                local optionUser = tostring(optionData.username or "")
                local dataUser = tostring(journalData.ownerUsername or "")
                return optionUser ~= "" and dataUser ~= "" and optionUser == dataUser
            end)
            if not selectedOwnerIndex and ownerAuthorText ~= "" and customIndex then
                selectedOwnerIndex = customIndex
            end
            if not selectedOwnerIndex then
                selectedOwnerIndex = noneIndex
            end
        end
        panel.journalOwnerCombo.selected = selectedOwnerIndex
    end

    if panel.journalFlavorEntry then
        panel.journalFlavorEntry:setText(tostring(journalData.flavorText or ""))
    end
    if panel.journalAgeEntry then
        local nowHours = (getGameTime and getGameTime() and getGameTime():getWorldAgeHours()) or 0
        local tsHours = tonumber(journalData.timestamp) or tonumber(journalData.createdAtHours) or tonumber(nowHours) or 0
        local ageHours = math.max(0, math.floor((tonumber(nowHours) or 0) - tsHours))
        panel.journalAgeEntry:setText(tostring(ageHours))
    end
    self:updateJournalEditorMetaVisibility()
    
    -- Update info line
    local skillCount = journalData.skills and BurdJournals.countTable(journalData.skills) or 0
    local traitCount = journalData.traits and BurdJournals.countTable(journalData.traits) or 0
    local recipeCount = journalData.recipes and BurdJournals.countTable(journalData.recipes) or 0
    local infoText = string.format("%s %d | %s %d | %s %d", getText("UI_BurdJournals_TabSkills"), skillCount, getText("UI_BurdJournals_TabTraits"), traitCount, getText("UI_BurdJournals_TabRecipes"), recipeCount)
    if journalData.isPlayerCreated then
        infoText = infoText .. " [Player Journal]"
    end
    infoText = infoText .. " [Type: " .. tostring(journalEditType) .. "]"
    infoText = infoText .. ((journalProfile == "debug") and " [Profile: Debug]" or " [Profile: Normal]")
    infoText = infoText .. " [" .. getOriginModeLabel(journalOriginMode) .. "]"
    if journalData.forgetSlot == true then
        infoText = infoText .. " [Forget Slot]"
    end
    if journalData.isCursedJournal == true then
        infoText = infoText .. " [Cursed:" .. tostring(journalData.cursedState or "dormant") .. "]"
    elseif journalData.isCursedReward == true then
        infoText = infoText .. " [Cursed Reward]"
    end
    if journalData.cursedEffectType and journalData.cursedEffectType ~= "" then
        infoText = infoText .. " [Curse=" .. tostring(journalData.cursedEffectType) .. "]"
    end
    if journal.__bsjServerProxy then
        infoText = infoText .. " [No live item]"
    end

    -- Compatibility status note for Adaptive Traits filtering on player journals.
    if journalData.isPlayerCreated
        and BurdJournals.isAdaptiveTraitsModActive
        and BurdJournals.isAdaptiveTraitsModActive() then
        local adaptiveAllowed = BurdJournals.isAdaptiveTraitsManagedTraitRecordingEnabled
            and BurdJournals.isAdaptiveTraitsManagedTraitRecordingEnabled()
        if adaptiveAllowed then
            infoText = infoText .. " [AdaptiveTraits: Allowed]"
        else
            local filteredCount = 0
            if type(journalData.traits) == "table" and BurdJournals.isAdaptiveManagedTrait then
                for traitId, _ in pairs(journalData.traits) do
                    if BurdJournals.isAdaptiveManagedTrait(traitId) then
                        filteredCount = filteredCount + 1
                    end
                end
            end
            if filteredCount > 0 then
                infoText = infoText .. " [AdaptiveTraits: Filtered " .. tostring(filteredCount) .. "]"
            else
                infoText = infoText .. " [AdaptiveTraits: Filtered]"
            end
        end
    end

    panel.journalInfoLabel:setName(infoText)
    
    -- Populate skills from journal (normalized for Java-backed ModData safety)
    local normalized = BurdJournals.normalizeJournalData(journalData) or journalData
    local skillTable = normalized.skills or {}
    local focusedSkillFound = false
    if skillTable then
        local sortedSkills = {}
        for skillName, skillData in pairs(skillTable) do
            local enabledForJournal = not BurdJournals.isSkillEnabledForJournal or BurdJournals.isSkillEnabledForJournal(journalData, skillName)
            if skillName ~= nil and enabledForJournal then
                local displayName = BurdJournals.getPerkDisplayName and BurdJournals.getPerkDisplayName(skillName) or tostring(skillName)
                local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillName) or false
                local xp = (type(skillData) == "table" and tonumber(skillData.xp)) or 0
                local level = (type(skillData) == "table" and tonumber(skillData.level)) or 0

                table.insert(sortedSkills, {
                    name = skillName,
                    displayName = displayName,
                    xp = xp,
                    level = level,
                    isPassive = isPassive
                })
            end
        end
        
        -- Sort by display name
        table.sort(sortedSkills, function(a, b)
            return a.displayName < b.displayName
        end)
        
        for _, skill in ipairs(sortedSkills) do
            panel.journalSkillList:addItem(skill.displayName, skill)
            if previousFocusedSkill and string.lower(tostring(skill.name)) == string.lower(previousFocusedSkill) then
                panel.journalFocusedSkill = skill.name
                focusedSkillFound = true
            end
        end
    end
    
    -- Build a safe lookup table for journal traits (including aliases)
    local journalTraits = normalized.traits or {}
    local journalTraitLookup = BurdJournals.UI.DebugPanel.buildTraitLookup(journalTraits)
    
    -- Get all available traits
    local allTraits = BurdJournals.UI.DebugPanel.getAvailableTraits()
    
    -- Populate LEFT column: Available traits (NOT in journal) - for adding
    -- Deduplicate by display name to handle B42 trait variants (e.g., Outdoorsman vs Outdoorsman_B42)
    local availableTraits = {}
    local addedDisplayNames = {}  -- Track display names to prevent visual duplicates
    for _, traitId in ipairs(allTraits) do
        if not BurdJournals.UI.DebugPanel.isTraitInLookup(journalTraitLookup, traitId) then
            local displayName = BurdJournals.getTraitDisplayName and BurdJournals.getTraitDisplayName(traitId) or tostring(traitId)
            local displayNameLower = string.lower(displayName)

            -- Only add if we haven't already added a trait with this display name
            if not addedDisplayNames[displayNameLower] then
                addedDisplayNames[displayNameLower] = true
                table.insert(availableTraits, {
                    id = traitId,
                    displayName = displayName
                })
            end
        end
    end
    
    -- Sort available traits alphabetically
    table.sort(availableTraits, function(a, b)
        return a.displayName < b.displayName
    end)
    
    for _, trait in ipairs(availableTraits) do
        panel.journalAvailTraitList:addItem(trait.displayName, trait)
    end
    
    -- Populate RIGHT column: Journal traits (IN journal) - for removing
    local inJournalTraits = {}
    local addedTraitAliases = {}
    for traitId, _ in pairs(journalTraits) do
        local normalizedId = BurdJournals.UI.DebugPanel.normalizeTraitId(traitId) or traitId
        local normalizedLower = string.lower(tostring(normalizedId))
        if not addedTraitAliases[normalizedLower] then
            -- Mark all aliases as seen to prevent duplicates
            if BurdJournals.getTraitAliases then
                for _, alias in ipairs(BurdJournals.getTraitAliases(normalizedId)) do
                    local aliasNorm = BurdJournals.UI.DebugPanel.normalizeTraitId(alias) or alias
                    addedTraitAliases[string.lower(tostring(aliasNorm))] = true
                end
            end
            addedTraitAliases[normalizedLower] = true

            local displayName = BurdJournals.getTraitDisplayName and BurdJournals.getTraitDisplayName(normalizedId) or tostring(normalizedId)
            table.insert(inJournalTraits, {
                id = normalizedId,
                displayName = displayName
            })
        end
    end
    
    -- Sort journal traits alphabetically
    table.sort(inJournalTraits, function(a, b)
        return a.displayName < b.displayName
    end)
    
    for _, trait in ipairs(inJournalTraits) do
        panel.journalInTraitList:addItem(trait.displayName, trait)
    end
    
    if not focusedSkillFound then
        panel.journalFocusedSkill = nil
    end
    BurdJournals.UI.DebugPanel.updateJournalSkillLabel(self)
end

local function getDebugSkillDisplayLevel(skillName, storedLevel, xp)
    local currentXP = math.max(0, tonumber(xp) or 0)
    local normalizedStoredLevel = math.max(0, math.min(10, math.floor(tonumber(storedLevel) or 0)))
    local derivedLevel = normalizedStoredLevel

    if BurdJournals.getSkillLevelFromXP then
        local computed = BurdJournals.getSkillLevelFromXP(currentXP, skillName)
        if tonumber(computed) then
            derivedLevel = math.max(0, math.min(10, math.floor(tonumber(computed) or 0)))
        end
    end

    -- For baseline-recorded passive skills, stored level can be intentionally higher than
    -- XP-derived level (XP is delta, level is absolute). Preserve stored level in UI.
    if normalizedStoredLevel > derivedLevel then
        return normalizedStoredLevel, true
    end
    return derivedLevel, false
end

-- Draw function for journal skill items
function BurdJournals.UI.DebugPanel.drawJournalSkillItem(self, y, item, alt)
    local h = tonumber(self.itemheight) or 24

    -- CRITICAL: y must be a valid number for ISScrollingListBox to work correctly
    -- Return y + h (not just h) to maintain proper list positioning
    y = tonumber(y) or 0
    if y ~= y then y = 0 end  -- NaN check

    -- Item validation - return valid y + h even for invalid items
    if not item or not item.item then return y + h end
    local data = item.item
    if not data then return y + h end
    if data.hidden then return y + h end

    local w = tonumber(self.width) or 300
    if w <= 0 then w = 300 end
    local parentPanel = self.parentPanel
    local journalPanel = parentPanel and parentPanel.journalPanel
    local isSelected = journalPanel and journalPanel.journalFocusedSkill == data.name
    
    -- Resolve display level from XP, but preserve stored level when it is intentionally higher
    -- (e.g., passive skills recorded in baseline mode).
    local currentXP = math.max(0, tonumber(data.xp) or 0)
    local currentLevel, usedStoredOverride = getDebugSkillDisplayLevel(data.name, data.level, currentXP)
    local displayName = tostring(data.displayName or data.name or "Unknown")
    
    -- Background (check item.index exists)
    if isSelected then
        self:drawRect(0, y, w, h, 0.3, 0.2, 0.4, 0.3)
    elseif item.index and self.mouseoverselected == item.index then
        self:drawRect(0, y, w, h, 0.2, 0.2, 0.3, 0.3)
    elseif data.isPassive then
        self:drawRect(0, y, w, h, 0.1, 0.15, 0.2, 0.2)
    end

    -- Skill name
    local nameColor = isSelected and {1, 1, 0.6} or {1, 1, 1}
    self:drawText(displayName, 8, y + 4, nameColor[1], nameColor[2], nameColor[3], 1, UIFont.Small)

    -- Level text
    local levelText = string.format(getText("UI_BurdJournals_LevelFormat"), tonumber(currentLevel) or 0)
    self:drawText(levelText, 140, y + 4, 0.8, 0.8, 0.5, 1, UIFont.Small)

    -- Level squares (0-10) - show current level + partial progress
    -- Use shared threshold helpers so editor math matches set/get XP behavior.
    local squaresX = 185
    local squareSize = 12
    local squareSpacing = 2
    local progress = 0
    if currentLevel < 10 and not usedStoredOverride then
        local levelStartXP = 0
        local levelEndXP = 0
        if BurdJournals.getXPThresholdForLevel then
            levelStartXP = tonumber(BurdJournals.getXPThresholdForLevel(data.name, currentLevel)) or 0
            levelEndXP = tonumber(BurdJournals.getXPThresholdForLevel(data.name, currentLevel + 1)) or levelStartXP
        end
        if levelEndXP < levelStartXP then
            levelEndXP = levelStartXP
        end
        local xpRange = levelEndXP - levelStartXP
        if xpRange > 0 then
            progress = math.max(0, math.min(1, (currentXP - levelStartXP) / xpRange))
        elseif currentXP > levelStartXP then
            progress = 1
        end
    end

    for i = 1, 10 do
        local sqX = squaresX + (i - 1) * (squareSize + squareSpacing)
        local sqY = y + (h - squareSize) / 2

        if i <= currentLevel then
            -- Filled square
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.9, 0.4, 0.7, 0.4)
        elseif i == currentLevel + 1 and progress > 0 then
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.15, 0.15, 0.2)
            local fillHeight = squareSize * progress
            self:drawRect(sqX, sqY + squareSize - fillHeight, squareSize, fillHeight, 0.8, 0.3, 0.5, 0.35)
        else
            -- Empty square
            self:drawRect(sqX, sqY, squareSize, squareSize, 0.5, 0.15, 0.15, 0.2)
        end
        self:drawRectBorder(sqX, sqY, squareSize, squareSize, 0.8, 0.4, 0.5, 0.6)
    end

    -- XP display
    local squaresEndX = squaresX + 10 * (squareSize + squareSpacing)
    local xpText = tostring(math.floor(currentXP)) .. " XP"
    local xpColor = isSelected and {1, 1, 0.6} or {0.6, 0.8, 0.6}
    self:drawText(xpText, squaresEndX + 8, y + 4, xpColor[1], xpColor[2], xpColor[3], 1, UIFont.Small)

    -- Remove button
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH or 15
    local removeBtnW = 50
    local removeBtnH = h - 4
    local removeBtnX = w - removeBtnW - 5 - scrollOffset
    local removeBtnY = y + 2

    -- Store button coords for click detection
    item.removeBtnX = removeBtnX
    item.removeBtnW = removeBtnW

    -- Draw remove button with hover effect (check item.index exists)
    local isHover = item.index and self.mouseoverselected == item.index
    if removeBtnX > 0 and removeBtnW > 0 and removeBtnH > 0 then
        if isHover then
            self:drawRect(removeBtnX, removeBtnY, removeBtnW, removeBtnH, 0.6, 0.6, 0.2, 0.2)
        else
            self:drawRect(removeBtnX, removeBtnY, removeBtnW, removeBtnH, 0.4, 0.4, 0.15, 0.15)
        end
        self:drawRectBorder(removeBtnX, removeBtnY, removeBtnW, removeBtnH, 0.7, 0.5, 0.3, 0.3)

        local removeText = getText("UI_BurdJournals_BtnErase")
        local removeTextW = getTextManager():MeasureStringX(UIFont.Small, removeText)
        self:drawText(removeText, removeBtnX + (removeBtnW - removeTextW) / 2, y + 4, 1, 0.5, 0.5, 0.9, UIFont.Small)

        -- Passive indicator (moved left to make room for Remove button)
        if data.isPassive then
            self:drawText("[P]", removeBtnX - 25, y + 4, 0.5, 0.7, 0.9, 0.7, UIFont.Small)
        end
    end
    
    return y + h
end

-- Click handler for journal skill list
function BurdJournals.UI.DebugPanel.onJournalSkillListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    
    if not self.items then return end
    local row = self:rowAt(x, y)
    if not row or row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    if not item or not item.item then return end
    local data = item.item
    if not data then return end
    
    local parentPanel = self.parentPanel
    if not parentPanel then return end
    local journalPanel = parentPanel.journalPanel
    local journal = parentPanel.editingJournal
    if not journal then return end
    
    -- Check if click is on the Remove button
    local removeBtnX = item.removeBtnX
    local removeBtnW = item.removeBtnW or 50
    if removeBtnX and x >= removeBtnX and x <= removeBtnX + removeBtnW then
        -- Mark as debug-edited for persistence
        BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
        
        -- Remove skill from journal
        local modData = journal:getModData()
        if modData and modData.BurdJournals and modData.BurdJournals.skills then
            if BurdJournals.normalizeTable then
                modData.BurdJournals.skills = BurdJournals.normalizeTable(modData.BurdJournals.skills) or modData.BurdJournals.skills
            end
            local skillsTable = modData.BurdJournals.skills
            local skillKey = BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, data.name)
            if skillKey then
                skillsTable[skillKey] = nil
            end
            -- Remove case-variant duplicates if present
            local nameLower = string.lower(tostring(data.name))
            local tableToScan = skillsTable
            if BurdJournals.normalizeTable then
                tableToScan = BurdJournals.normalizeTable(skillsTable) or skillsTable
            end
            for key, _ in pairs(tableToScan) do
                if string.lower(tostring(key)) == nameLower then
                    skillsTable[key] = nil
                end
            end
            if journal.transmitModData then
                journal:transmitModData()
            end
            -- Finalize edit: transmit and backup to global cache
            BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
            parentPanel:refreshJournalEditorData()
            parentPanel:setStatus("Removed " .. data.displayName .. " from journal", {r=1, g=0.6, b=0.3})
        end
        return
    end
    
    -- Check if click is in the squares area
    local squaresX = 185
    local squareSize = 12
    local squareSpacing = 2
    local squaresEndX = squaresX + 10 * (squareSize + squareSpacing)
    
    if x >= squaresX and x <= squaresEndX then
        -- Calculate which level was clicked
        local relX = x - squaresX
        local clickedLevel = math.floor(relX / (squareSize + squareSpacing)) + 1
        clickedLevel = math.max(0, math.min(10, clickedLevel))
        
        local currentDisplayLevel = select(1, getDebugSkillDisplayLevel(data.name, data.level, data.xp))
        -- Toggle off if clicking current displayed level
        if clickedLevel == currentDisplayLevel then
            clickedLevel = 0
        end
        
        -- Update journal data
        BurdJournals.UI.DebugPanel.setJournalSkillLevel(parentPanel, data.name, clickedLevel)
        parentPanel:setStatus("Set " .. data.displayName .. " to level " .. clickedLevel, {r=0.3, g=1, b=0.5})
    end
    
    -- Select this skill for XP modification
    journalPanel.journalFocusedSkill = data.name
    
    -- Update XP entry with current XP
    if journalPanel.journalXPEntry then
        journalPanel.journalXPEntry:setText(tostring(math.floor(data.xp or 0)))
    end
    
    BurdJournals.UI.DebugPanel.updateJournalSkillLabel(parentPanel)
end

-- Update skill label when a skill is selected
function BurdJournals.UI.DebugPanel.updateJournalSkillLabel(self)
    local panel = self.journalPanel
    if not panel then return end
    
    local focusedSkill = panel.journalFocusedSkill
    if focusedSkill and panel.journalSkillList then
        for _, itemData in ipairs(panel.journalSkillList.items) do
            if itemData.item and itemData.item.name == focusedSkill then
                panel.journalSkillNameLabel:setName(itemData.item.displayName)
                panel.journalSkillNameLabel.r = 1
                panel.journalSkillNameLabel.g = 1
                panel.journalSkillNameLabel.b = 0.6
                BurdJournals.UI.DebugPanel.updateJournalDiminishingLabel(self)
                return
            end
        end
    end
    
    panel.journalSkillNameLabel:setName("Click skill row to select")
    panel.journalSkillNameLabel.r = 0.5
    panel.journalSkillNameLabel.g = 0.6
    panel.journalSkillNameLabel.b = 0.7
    BurdJournals.UI.DebugPanel.updateJournalDiminishingLabel(self)
end

function BurdJournals.UI.DebugPanel.getDiminishingModeName()
    local mode = BurdJournals.getDiminishingTrackingMode and BurdJournals.getDiminishingTrackingMode() or 3
    if mode == 1 then
        return getText("Sandbox_BurdJournals_DiminishingTrackingMode_option1")
    elseif mode == 2 then
        return getText("Sandbox_BurdJournals_DiminishingTrackingMode_option2")
    end
    return getText("Sandbox_BurdJournals_DiminishingTrackingMode_option3")
end

function BurdJournals.UI.DebugPanel.isDiminishingEnabled()
    return BurdJournals.getXPRecoveryMode and BurdJournals.getXPRecoveryMode() == 2
end

function BurdJournals.UI.DebugPanel.updateJournalDiminishingControlsVisibility(self, visible)
    local panel = self and self.journalPanel
    if not panel then return end

    local controls = {
        panel.journalDRStepLabel,
        panel.journalDRStepEntry,
        panel.journalDRSetBtn,
        panel.journalDRDecBtn,
        panel.journalDRIncBtn,
        panel.journalDRResetBtn,
        panel.journalDRHintLabel,
        panel.journalDRPreviewLabel,
    }
    for _, control in ipairs(controls) do
        if control and control.setVisible then
            control:setVisible(visible == true)
        end
    end
end

function BurdJournals.UI.DebugPanel.getJournalDRPreviewPercents(journalData, focusedSkill)
    if not journalData or not BurdJournals.getJournalClaimMultiplier then
        return nil
    end

    local percents = {}
    for readOffset = 0, 2 do
        local multiplier = BurdJournals.getJournalClaimMultiplier(journalData, readOffset, focusedSkill, nil)
        local percent = math.floor((math.max(0, tonumber(multiplier) or 0) * 100) + 0.5)
        percents[#percents + 1] = percent
    end

    return percents
end

function BurdJournals.UI.DebugPanel.updateJournalDiminishingLabel(self)
    local panel = self and self.journalPanel
    if not panel or not panel.journalDRLabel then return end

    local drEnabled = BurdJournals.UI.DebugPanel.isDiminishingEnabled()
    BurdJournals.UI.DebugPanel.updateJournalDiminishingControlsVisibility(self, drEnabled)
    if not drEnabled then
        panel.journalDRLabel:setName("DR: " .. tostring(getText("Sandbox_BurdJournals_XPRecoveryMode_option1")))
        panel.journalDRLabel.r = 0.55
        panel.journalDRLabel.g = 0.62
        panel.journalDRLabel.b = 0.72
        return
    end

    local modeName = BurdJournals.UI.DebugPanel.getDiminishingModeName()
    local mode = BurdJournals.getDiminishingTrackingMode and BurdJournals.getDiminishingTrackingMode() or 3
    local journal = self and self.editingJournal
    local journalData = journal and BurdJournals.getJournalData and BurdJournals.getJournalData(journal) or nil
    local focusedSkill = panel.journalFocusedSkill

    local suffix = "--"
    local previewText = "N1 -- | N2 -- | N3 --"
    local stepValue = 0
    local stepHint = "readCount"
    if mode == 1 then
        stepHint = "readCount"
        stepValue = tonumber(journalData and journalData.readCount) or 0
    elseif mode == 2 then
        stepHint = "readSessionCount"
        stepValue = tonumber(journalData and journalData.readSessionCount) or 0
    else
        stepHint = "skillReadCounts[skill]"
        stepValue = 0
        local skillReadCounts = journalData and journalData.skillReadCounts
        if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
            skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
        end
        if focusedSkill and type(skillReadCounts) == "table" then
            local resolvedKey = BurdJournals.resolveSkillKey and BurdJournals.resolveSkillKey(skillReadCounts, focusedSkill) or focusedSkill
            stepValue = tonumber(skillReadCounts[resolvedKey or focusedSkill]) or 0
        end
    end

    if panel.journalDRStepEntry then
        panel.journalDRStepEntry:setText(tostring(math.max(0, math.floor(stepValue))))
    end
    if panel.journalDRHintLabel then
        panel.journalDRHintLabel:setName(stepHint)
    end

    if mode == 3 and not focusedSkill then
        suffix = "(select skill)"
    end

    local claimPercent = nil
    local canPreview = journalData and BurdJournals.getJournalClaimMultiplier and (mode ~= 3 or focusedSkill ~= nil)
    if canPreview then
        local previewPercents = BurdJournals.UI.DebugPanel.getJournalDRPreviewPercents(journalData, focusedSkill)
        if previewPercents and #previewPercents >= 3 then
            claimPercent = previewPercents[1]
            previewText = "N1 " .. tostring(previewPercents[1]) .. "% | N2 " .. tostring(previewPercents[2]) .. "% | N3 " .. tostring(previewPercents[3]) .. "%"
        end
        claimPercent = claimPercent or 0
        suffix = tostring(claimPercent) .. "%"
        if mode == 1 then
            local readCount = tonumber(journalData.readCount) or 0
            suffix = suffix .. " [reads " .. tostring(readCount) .. "]"
        elseif mode == 2 then
            local sessionCount = tonumber(journalData.readSessionCount) or 0
            suffix = suffix .. " [session " .. tostring(sessionCount + 1) .. "]"
        else
            local skillReads = 0
            local skillReadCounts = journalData and journalData.skillReadCounts
            if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
                skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
            end
            if type(skillReadCounts) == "table" then
                local resolvedKey = BurdJournals.resolveSkillKey and BurdJournals.resolveSkillKey(skillReadCounts, focusedSkill) or focusedSkill
                skillReads = tonumber(skillReadCounts[resolvedKey or focusedSkill]) or 0
            end
            suffix = suffix .. " [skill reads " .. tostring(skillReads) .. "]"
        end
    elseif not journalData then
        suffix = "--"
    end

    if panel.journalDRPreviewLabel then
        panel.journalDRPreviewLabel:setName(previewText)
    end

    panel.journalDRLabel:setName("DR: " .. modeName .. " | Next: " .. suffix)
    if claimPercent and claimPercent < 100 then
        panel.journalDRLabel.r = 1
        panel.journalDRLabel.g = 0.85
        panel.journalDRLabel.b = 0.55
    else
        panel.journalDRLabel.r = 0.55
        panel.journalDRLabel.g = 0.62
        panel.journalDRLabel.b = 0.72
    end
end

-- Mark journal as debug-edited for persistence across restarts and mod updates.
-- Keeps worn/bloody journals in found-journal claim mode; only clean journals
-- are forced into player-journal mode.
function BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    if not journal then return end
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    local desiredProfile = resolveJournalEditProfileForItem(journal)
    local useDebugProfile = desiredProfile == "debug"

    local needsTransmit = false

    if not modData.BurdJournals.uuid then
        local generatedUUID = (BurdJournals.generateUUID and BurdJournals.generateUUID())
            or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
        modData.BurdJournals.uuid = generatedUUID
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Assigned UUID to debug-edited journal: " .. tostring(generatedUUID))
    end

    if useDebugProfile and not modData.BurdJournals.isDebugSpawned then
        modData.BurdJournals.isDebugSpawned = true
        modData.BurdJournals.isDebugEdited = true
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Marked journal as debug-edited for persistence")
    elseif not useDebugProfile and modData.BurdJournals.isDebugSpawned then
        modData.BurdJournals.isDebugSpawned = false
        modData.BurdJournals.isDebugEdited = nil
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Journal profile set to normal (debug flags cleared)")
    end

    local fullType = journal.getFullType and journal:getFullType() or ""
    local isWornType = type(fullType) == "string" and string.find(fullType, "_Worn", 1, true) ~= nil
    local isBloodyType = type(fullType) == "string" and string.find(fullType, "_Bloody", 1, true) ~= nil
    local isCursedType = fullType == (BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal")
    local isFoundJournal = isWornType or isBloodyType or isCursedType

    -- Keep type/origin flags on found journals so per-character claims remain correct.
    if isWornType and modData.BurdJournals.isWorn ~= true then
        modData.BurdJournals.isWorn = true
        modData.BurdJournals.wasFromWorn = true
        needsTransmit = true
    end
    if isBloodyType and modData.BurdJournals.isBloody ~= true then
        modData.BurdJournals.isBloody = true
        modData.BurdJournals.wasFromBloody = true
        needsTransmit = true
    end

    if isFoundJournal then
        if modData.BurdJournals.isPlayerCreated ~= false then
            modData.BurdJournals.isPlayerCreated = false
            needsTransmit = true
            BurdJournals.debugPrint("[BurdJournals] Preserved found-journal claim mode (isPlayerCreated=false)")
        end
    elseif modData.BurdJournals.isPlayerCreated ~= true then
        modData.BurdJournals.isPlayerCreated = true
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Ensured clean journal uses player-journal claim mode")
    end

    -- Update sanitized version to current to prevent data removal
    local currentVersion = BurdJournals.SANITIZE_VERSION or 1
    if modData.BurdJournals.sanitizedVersion ~= currentVersion then
        modData.BurdJournals.sanitizedVersion = currentVersion
        needsTransmit = true
    end

    -- Transmit changes to server for MP sync and persistence
    if needsTransmit and journal.transmitModData then
        journal:transmitModData()
    end

    -- Cache pre-edit state only when this journal is intentionally in Debug profile.
    if useDebugProfile then
        BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(journal)
    end
end

-- Finalize debug journal edit - transmit and backup after data modification
-- Call this AFTER modifying journal data to ensure persistence
function BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal, options)
    if not journal then return end
    options = options or {}
    local isServerProxy = journal.__bsjServerProxy == true
    local desiredProfile = resolveJournalEditProfileForItem(journal, options.profile)
    local useDebugProfile = desiredProfile == "debug"

    -- Ensure critical flags are set before transmitting
    local modData = journal:getModData()
    local journalUUID = nil
    if modData and modData.BurdJournals then
        if not modData.BurdJournals.uuid then
            modData.BurdJournals.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
                or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
        end
        journalUUID = modData.BurdJournals.uuid

        -- Always ensure these flags are set for proper behavior.
        -- Preserve found-journal claim semantics for worn/bloody item types.
        local fullType = journal.getFullType and journal:getFullType() or ""
        local isWornType = type(fullType) == "string" and string.find(fullType, "_Worn", 1, true) ~= nil
        local isBloodyType = type(fullType) == "string" and string.find(fullType, "_Bloody", 1, true) ~= nil
        local isCursedType = fullType == (BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal")
        modData.BurdJournals.isDebugSpawned = useDebugProfile
        modData.BurdJournals.isDebugEdited = useDebugProfile and true or nil
        if isWornType then
            modData.BurdJournals.isWorn = true
            modData.BurdJournals.wasFromWorn = true
        end
        if isBloodyType then
            modData.BurdJournals.isBloody = true
            modData.BurdJournals.wasFromBloody = true
        end
        if isWornType or isBloodyType or isCursedType then
            modData.BurdJournals.isPlayerCreated = false
        else
            modData.BurdJournals.isPlayerCreated = true
        end
        modData.BurdJournals.sanitizedVersion = BurdJournals.SANITIZE_VERSION or 1

        -- Mark as written so it's recognized as a valid filled journal
        modData.BurdJournals.isWritten = true
    end

    -- Transmit the item's ModData to server (critical for MP persistence)
    if journal.transmitModData and not isServerProxy then
        journal:transmitModData()
        BurdJournals.debugPrint("[BurdJournals] Transmitted journal ModData to server")
    end

    local journalKey = journalUUID or tostring((journal and journal.getID and journal:getID()) or "")
    local payloadData = BurdJournals.normalizeJournalData and BurdJournals.normalizeJournalData(modData and modData.BurdJournals) or (modData and modData.BurdJournals)

    -- Backup to global cache only for explicit Debug profile journals.
    if useDebugProfile then
        local cachedKey, backupData = BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(journal)
        if cachedKey then
            journalKey = cachedKey
        end
        if backupData then
            payloadData = backupData
        end
    end

    -- MP authoritative persist: push edited journal payload to server-side item modData.
    -- For server proxies, this queues deferred apply immediately (pendingApply=true on server)
    -- when the live journal is not currently loaded.
    local player = getPlayer()
    if player and payloadData and isClient and isClient() then
        local payload = {
            journalUUID = journalUUID,
            journalKey = journalKey,
            journalData = payloadData
        }
        if type(options.extraPayload) == "table" then
            for key, value in pairs(options.extraPayload) do
                payload[key] = value
            end
        end
        if not isServerProxy then
            payload.journalId = journal:getID()
        end

        sendClientCommand(player, "BurdJournals", "debugApplyJournalEdits", payload)
        if isServerProxy then
            journal.__bsjDirty = true
        end
    elseif isServerProxy then
        journal.__bsjDirty = true
    end
end

-- Backup debug-edited journal data to global ModData for persistence
-- This mirrors the baseline system approach - global ModData survives better than item ModData
-- IMPORTANT: On dedicated MP servers, client-side ModData.transmit() doesn't persist!
-- So we also send the data to the server via sendClientCommand for proper server-side storage
function BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(journal)
    if not journal then return end

    local modData = journal:getModData()
    if not modData.BurdJournals then return end
    if not modData.BurdJournals.isDebugSpawned then return end  -- Only backup debug journals

    if not modData.BurdJournals.uuid then
        modData.BurdJournals.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
            or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
    end

    -- Get or create global cache (similar to baseline cache)
    local cache = ModData.getOrCreate("BurdJournals_DebugJournalCache")
    if not cache.journals then cache.journals = {} end

    -- Use journal UUID as key for stable persistence across reconnects.
    local journalKey = modData.BurdJournals.uuid or tostring(journal:getID())
    local normalized = BurdJournals.normalizeJournalData(modData.BurdJournals) or modData.BurdJournals

    -- Build the backup data structure
    local backupData = {
        skills = {},
        traits = {},
        recipes = {},
        stats = {},
        claims = {},
        claimedSkills = {},
        claimedTraits = {},
        claimedRecipes = {},
        claimedStats = {},
        claimedForgetSlot = {},
        skillReadCounts = {},
        forgetSlot = normalized.forgetSlot == true,
        isCursedJournal = normalized.isCursedJournal == true,
        cursedState = normalized.cursedState,
        isCursedReward = normalized.isCursedReward == true,
        cursedEffectType = normalized.cursedEffectType,
        cursedUnleashedByCharacterId = normalized.cursedUnleashedByCharacterId,
        cursedUnleashedByUsername = normalized.cursedUnleashedByUsername,
        cursedUnleashedAtHours = tonumber(normalized.cursedUnleashedAtHours) or nil,
        cursedSealSoundEvent = normalized.cursedSealSoundEvent,
        cursedForcedEffectType = normalized.cursedForcedEffectType,
        cursedForcedTraitId = normalized.cursedForcedTraitId,
        cursedForcedSkillName = normalized.cursedForcedSkillName,
        cursedPendingRewards = nil,
        isDebugSpawned = normalized.isDebugSpawned == true,
        isDebugEdited = modData.BurdJournals.isDebugEdited,
        isPlayerCreated = modData.BurdJournals.isPlayerCreated,
        isWorn = modData.BurdJournals.isWorn,
        isBloody = modData.BurdJournals.isBloody,
        wasFromWorn = modData.BurdJournals.wasFromWorn,
        wasFromBloody = modData.BurdJournals.wasFromBloody,
        wasRestored = modData.BurdJournals.wasRestored,
        sanitizedVersion = modData.BurdJournals.sanitizedVersion,
        uuid = modData.BurdJournals.uuid,
        readCount = tonumber(modData.BurdJournals.readCount) or 0,
        readSessionCount = tonumber(modData.BurdJournals.readSessionCount) or 0,
        currentSessionId = modData.BurdJournals.currentSessionId,
        currentSessionReadCount = tonumber(modData.BurdJournals.currentSessionReadCount) or 0,
        timestamp = getTimestampMs and getTimestampMs() or os.time(),
        -- Store item info for restoration
        itemType = journal:getFullType(),
        itemID = journal:getID(),
    }

    -- Copy skills
    local skillsTable = normalized.skills or {}
    for skillName, skillData in pairs(skillsTable) do
        if skillName and skillData then
            backupData.skills[skillName] = {
                xp = skillData.xp,
                level = skillData.level
            }
        end
    end

    -- Copy traits
    local traitsTable = normalized.traits or {}
    for traitId, value in pairs(traitsTable) do
        if traitId then
            backupData.traits[traitId] = value
        end
    end

    -- Copy recipes
    local recipesTable = normalized.recipes or {}
    for recipeName, value in pairs(recipesTable) do
        if recipeName then
            backupData.recipes[recipeName] = value
        end
    end

    -- Copy stats
    local statsTable = normalized.stats or {}
    for statId, statData in pairs(statsTable) do
        if statId then
            backupData.stats[statId] = statData
        end
    end

    -- Copy claims and legacy claim maps
    local claimsTable = normalized.claims or {}
    for characterId, claimData in pairs(claimsTable) do
        if characterId then
            backupData.claims[characterId] = claimData
        end
    end

    local claimedSkillsTable = normalized.claimedSkills or {}
    for skillName, value in pairs(claimedSkillsTable) do
        if skillName then
            backupData.claimedSkills[skillName] = value
        end
    end

    local claimedTraitsTable = normalized.claimedTraits or {}
    for traitId, value in pairs(claimedTraitsTable) do
        if traitId then
            backupData.claimedTraits[traitId] = value
        end
    end

    local claimedRecipesTable = normalized.claimedRecipes or {}
    for recipeName, value in pairs(claimedRecipesTable) do
        if recipeName then
            backupData.claimedRecipes[recipeName] = value
        end
    end

    local claimedStatsTable = normalized.claimedStats or {}
    for statId, value in pairs(claimedStatsTable) do
        if statId then
            backupData.claimedStats[statId] = value
        end
    end

    local claimedForgetTable = normalized.claimedForgetSlot or {}
    for characterId, value in pairs(claimedForgetTable) do
        if characterId then
            backupData.claimedForgetSlot[characterId] = value
        end
    end

    if type(normalized.cursedPendingRewards) == "table" then
        backupData.cursedPendingRewards = BurdJournals.normalizeJournalData(normalized.cursedPendingRewards)
            or normalized.cursedPendingRewards
    end

    -- Copy diminishing-returns per-skill tracking.
    local skillReadCounts = normalized.skillReadCounts
    if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
        skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
    end
    if type(skillReadCounts) == "table" then
        for skillName, count in pairs(skillReadCounts) do
            if skillName then
                backupData.skillReadCounts[skillName] = tonumber(count) or 0
            end
        end
    end

    -- Keep DR counters in sync with normalized values when present.
    backupData.readCount = tonumber(normalized.readCount) or backupData.readCount
    backupData.readSessionCount = tonumber(normalized.readSessionCount) or backupData.readSessionCount
    backupData.currentSessionId = normalized.currentSessionId or backupData.currentSessionId
    backupData.currentSessionReadCount = tonumber(normalized.currentSessionReadCount) or backupData.currentSessionReadCount

    -- Store in local cache (works for SP and host player)
    cache.journals[journalKey] = backupData

    -- Transmit global cache (works for SP and host, but NOT for clients on dedicated servers)
    ModData.transmit("BurdJournals_DebugJournalCache")

    -- CRITICAL: On dedicated MP servers, also send to server via command for proper persistence
    -- This ensures the server stores the backup in its own global ModData
    local player = getPlayer()
    if player and isClient and isClient() then
        sendClientCommand(player, "BurdJournals", "saveDebugJournalBackup", {
            journalKey = journalKey,
            journalData = backupData
        })
        BurdJournals.debugPrint("[BurdJournals] Sent debug journal backup to server: " .. journalKey)
    end

    BurdJournals.debugPrint("[BurdJournals] Backed up debug journal to global cache: " .. journalKey)
    return journalKey, backupData
end

-- Restore journal data from global cache if item data was lost
-- Called during getJournalData or when opening a debug-spawned journal
-- On MP dedicated servers, will request backup from server if local cache is empty
function BurdJournals.UI.DebugPanel.restoreJournalFromGlobalCache(journal)
    if not journal then return false end

    local modData = journal:getModData()
    if not modData then return false end

    -- Initialize BurdJournals table if needed
    if not modData.BurdJournals then modData.BurdJournals = {} end

    local function hasCoreData(data)
        if not data then return false end
        if BurdJournals.hasAnyEntries(data.skills) then return true end
        if BurdJournals.hasAnyEntries(data.traits) then return true end
        if BurdJournals.hasAnyEntries(data.recipes) then return true end
        if BurdJournals.hasAnyEntries(data.stats) then return true end
        if data.forgetSlot == true then return true end
        if BurdJournals.hasAnyEntries(data.claims) then return true end
        if BurdJournals.hasAnyEntries(data.claimedForgetSlot) then return true end
        if data.isCursedJournal == true or data.isCursedReward == true then return true end
        if BurdJournals.hasAnyEntries(data.cursedPendingRewards) then return true end
        return false
    end

    local function hasDRData(data)
        if not data then return false end
        if (tonumber(data.readCount) or 0) > 0 then return true end
        if (tonumber(data.readSessionCount) or 0) > 0 then return true end
        if (tonumber(data.currentSessionReadCount) or 0) > 0 then return true end
        if data.currentSessionId then return true end
        if BurdJournals.hasAnyEntries(data.skillReadCounts) then return true end
        return false
    end

    -- Determine journal key for cache lookup
    local journalKey = modData.BurdJournals.uuid
    if not journalKey then
        journalKey = tostring(journal:getID())
    end

    -- Get global cache
    local cache = ModData.getOrCreate("BurdJournals_DebugJournalCache")
    if not cache.journals then cache.journals = {} end

    -- Check if we have a local backup
    local backup = cache.journals[journalKey]

    if not backup then
        -- No local backup found - on MP, request from server
        if isClient and isClient() then
            BurdJournals.debugPrint("[BurdJournals] No local cache for debug journal key=" .. tostring(journalKey) .. " - requesting from server")
            if BurdJournals.Client and BurdJournals.Client.requestDebugJournalBackup then
                BurdJournals.Client.requestDebugJournalBackup(journal, journalKey)
            end
        end
        return false
    end

    local normalizedBackup = BurdJournals.normalizeJournalData(backup) or backup

    local existingCore = hasCoreData(modData.BurdJournals)
    local existingDR = hasDRData(modData.BurdJournals)
    local backupCore = hasCoreData(normalizedBackup)
    local backupDR = hasDRData(normalizedBackup)
    local shouldRestoreCore = (not existingCore) and backupCore
    local shouldRestoreDR = (not existingDR) and backupDR

    if not shouldRestoreCore and not shouldRestoreDR then
        return false
    end

    BurdJournals.debugPrint("[BurdJournals] Restoring debug journal from global cache: " .. tostring(journalKey))

    local fullType = journal.getFullType and journal:getFullType() or ""
    local isWornType = type(fullType) == "string" and string.find(fullType, "_Worn", 1, true) ~= nil
    local isBloodyType = type(fullType) == "string" and string.find(fullType, "_Bloody", 1, true) ~= nil
    local isCursedType = fullType == (BurdJournals.CURSED_ITEM_TYPE or "BurdJournals.CursedJournal")
    local isFoundJournal = isWornType
        or isBloodyType
        or isCursedType
        or normalizedBackup.isWorn == true
        or normalizedBackup.isBloody == true
        or normalizedBackup.isCursedJournal == true
        or normalizedBackup.isCursedReward == true

    -- Restore flags
    modData.BurdJournals.isDebugSpawned = normalizedBackup.isDebugSpawned == true
    modData.BurdJournals.isDebugEdited = modData.BurdJournals.isDebugSpawned and (normalizedBackup.isDebugEdited == true) or nil
    if isFoundJournal then
        modData.BurdJournals.isPlayerCreated = false
    elseif normalizedBackup.isPlayerCreated ~= nil then
        modData.BurdJournals.isPlayerCreated = normalizedBackup.isPlayerCreated == true
    else
        modData.BurdJournals.isPlayerCreated = true
    end
    modData.BurdJournals.sanitizedVersion = normalizedBackup.sanitizedVersion or (BurdJournals.SANITIZE_VERSION or 1)
    modData.BurdJournals.uuid = normalizedBackup.uuid
    modData.BurdJournals.forgetSlot = normalizedBackup.forgetSlot == true
    modData.BurdJournals.claimedForgetSlot = BurdJournals.normalizeTable(normalizedBackup.claimedForgetSlot) or {}
    modData.BurdJournals.isCursedJournal = normalizedBackup.isCursedJournal == true
    modData.BurdJournals.cursedState = normalizedBackup.cursedState
    modData.BurdJournals.isCursedReward = normalizedBackup.isCursedReward == true
    modData.BurdJournals.cursedEffectType = normalizedBackup.cursedEffectType
    modData.BurdJournals.cursedUnleashedByCharacterId = normalizedBackup.cursedUnleashedByCharacterId
    modData.BurdJournals.cursedUnleashedByUsername = normalizedBackup.cursedUnleashedByUsername
    modData.BurdJournals.cursedUnleashedAtHours = tonumber(normalizedBackup.cursedUnleashedAtHours) or nil
    modData.BurdJournals.cursedSealSoundEvent = normalizedBackup.cursedSealSoundEvent
    modData.BurdJournals.cursedForcedEffectType = normalizedBackup.cursedForcedEffectType
    modData.BurdJournals.cursedForcedTraitId = normalizedBackup.cursedForcedTraitId
    modData.BurdJournals.cursedForcedSkillName = normalizedBackup.cursedForcedSkillName
    modData.BurdJournals.cursedPendingRewards = BurdJournals.normalizeTable(normalizedBackup.cursedPendingRewards)

    if shouldRestoreCore then
        -- Restore skills
        modData.BurdJournals.skills = modData.BurdJournals.skills or {}
        for skillName, skillData in pairs(normalizedBackup.skills or {}) do
            modData.BurdJournals.skills[skillName] = {
                xp = skillData.xp,
                level = skillData.level
            }
        end

        -- Restore traits
        modData.BurdJournals.traits = modData.BurdJournals.traits or {}
        for traitId, value in pairs(normalizedBackup.traits or {}) do
            modData.BurdJournals.traits[traitId] = value
        end

        -- Restore recipes
        modData.BurdJournals.recipes = modData.BurdJournals.recipes or {}
        for recipeName, value in pairs(normalizedBackup.recipes or {}) do
            modData.BurdJournals.recipes[recipeName] = value
        end

        -- Restore stats
        modData.BurdJournals.stats = modData.BurdJournals.stats or {}
        for statId, statData in pairs(normalizedBackup.stats or {}) do
            modData.BurdJournals.stats[statId] = statData
        end

        modData.BurdJournals.claims = BurdJournals.normalizeTable(normalizedBackup.claims) or {}
        modData.BurdJournals.claimedSkills = BurdJournals.normalizeTable(normalizedBackup.claimedSkills) or {}
        modData.BurdJournals.claimedTraits = BurdJournals.normalizeTable(normalizedBackup.claimedTraits) or {}
        modData.BurdJournals.claimedRecipes = BurdJournals.normalizeTable(normalizedBackup.claimedRecipes) or {}
        modData.BurdJournals.claimedStats = BurdJournals.normalizeTable(normalizedBackup.claimedStats) or {}
    end

    if shouldRestoreDR then
        modData.BurdJournals.readCount = tonumber(normalizedBackup.readCount) or 0
        modData.BurdJournals.readSessionCount = tonumber(normalizedBackup.readSessionCount) or 0
        modData.BurdJournals.currentSessionId = normalizedBackup.currentSessionId
        modData.BurdJournals.currentSessionReadCount = tonumber(normalizedBackup.currentSessionReadCount) or 0

        local backupSkillReadCounts = normalizedBackup.skillReadCounts
        if type(backupSkillReadCounts) ~= "table" and BurdJournals.normalizeTable then
            backupSkillReadCounts = BurdJournals.normalizeTable(backupSkillReadCounts)
        end
        modData.BurdJournals.skillReadCounts = {}
        if type(backupSkillReadCounts) == "table" then
            for skillName, count in pairs(backupSkillReadCounts) do
                if skillName then
                    modData.BurdJournals.skillReadCounts[skillName] = tonumber(count) or 0
                end
            end
        end
    end

    -- Transmit restored data back to server
    if journal.transmitModData then
        journal:transmitModData()
    end

    BurdJournals.debugPrint("[BurdJournals] Successfully restored debug journal data from global cache")
    return true
end

-- Set skill level in journal
function BurdJournals.UI.DebugPanel.setJournalSkillLevel(self, skillName, level)
    local journal = self.editingJournal
    if not journal then return end
    
    -- Mark as debug-edited for persistence
    BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    if not modData.BurdJournals.skills then modData.BurdJournals.skills = {} end
    if BurdJournals.normalizeTable then
        modData.BurdJournals.skills = BurdJournals.normalizeTable(modData.BurdJournals.skills) or modData.BurdJournals.skills
    end
    local skillsTable = modData.BurdJournals.skills
    local skillKey = BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, skillName)
    
    local targetLevel = math.floor(tonumber(level) or 0)
    if targetLevel < 0 then targetLevel = 0 end
    if targetLevel > 10 then targetLevel = 10 end

    -- Calculate XP for level using shared thresholds
    local xp = 0
    if targetLevel > 0 then
        if BurdJournals.getXPThresholdForLevel then
            xp = tonumber(BurdJournals.getXPThresholdForLevel(skillKey, targetLevel)) or 0
        else
            local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillKey) or false
            if isPassive then
                xp = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[targetLevel] or (targetLevel * 7500)
            else
                xp = BurdJournals.STANDARD_XP_THRESHOLDS and BurdJournals.STANDARD_XP_THRESHOLDS[targetLevel] or (targetLevel * 150)
            end
        end
    end
    
    -- Keep skill at level 0 with 0 XP (don't auto-remove)
    skillsTable[skillKey] = {
        xp = math.max(0, tonumber(xp) or 0),
        level = targetLevel
    }

    -- Finalize edit: transmit and backup to global cache
    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

    -- Refresh display
    self:refreshJournalEditorData()
end

-- Set skill XP directly in journal
function BurdJournals.UI.DebugPanel:onJournalSetXP()
    local panel = self.journalPanel
    if not panel then return end
    
    local focusedSkill = panel.journalFocusedSkill
    if not focusedSkill then
        self:setStatus("No skill selected", {r=1, g=0.5, b=0.5})
        return
    end
    
    local journal = self.editingJournal
    if not journal then
        self:setStatus("No journal selected", {r=1, g=0.5, b=0.5})
        return
    end
    
    -- Mark as debug-edited for persistence
    BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    
    local xpText = panel.journalXPEntry:getText() or "0"
    local xp = math.max(0, tonumber(xpText) or 0)
    
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    if not modData.BurdJournals.skills then modData.BurdJournals.skills = {} end
    if BurdJournals.normalizeTable then
        modData.BurdJournals.skills = BurdJournals.normalizeTable(modData.BurdJournals.skills) or modData.BurdJournals.skills
    end
    local skillsTable = modData.BurdJournals.skills
    local skillKey = BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, focusedSkill)
    
    -- Calculate level from XP using shared helper
    local level = 0
    if BurdJournals.getSkillLevelFromXP then
        level = tonumber(BurdJournals.getSkillLevelFromXP(xp, skillKey)) or 0
    else
        local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillKey) or false
        if isPassive then
            local thresholds = BurdJournals.PASSIVE_XP_THRESHOLDS or {}
            for l = 10, 1, -1 do
                if xp >= (thresholds[l] or (l * 7500)) then
                    level = l
                    break
                end
            end
        else
            local thresholds = BurdJournals.STANDARD_XP_THRESHOLDS or {}
            for l = 10, 1, -1 do
                if xp >= (thresholds[l] or (l * 150)) then
                    level = l
                    break
                end
            end
        end
    end
    level = math.max(0, math.min(10, math.floor(tonumber(level) or 0)))
    
    -- Keep skill even at 0 XP (don't auto-remove, use Remove button instead)
    skillsTable[skillKey] = {
        xp = xp,
        level = level
    }

    -- Finalize edit: transmit and backup to global cache
    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

    self:refreshJournalEditorData()
    self:setStatus("Set " .. tostring(focusedSkill) .. " to " .. xp .. " XP (Lv." .. level .. ")", {r=0.3, g=1, b=0.5})
end

function BurdJournals.UI.DebugPanel:onJournalSetDRStep()
    local panel = self.journalPanel
    if not panel or not panel.journalDRStepEntry then return end
    if not BurdJournals.UI.DebugPanel.isDiminishingEnabled() then return end

    local journal = self.editingJournal
    if not journal then
        self:setStatus("No journal selected", {r=1, g=0.5, b=0.5})
        return
    end

    local rawStep = tonumber(panel.journalDRStepEntry:getText() or "")
    if not rawStep then
        self:setStatus("Invalid DR step", {r=1, g=0.5, b=0.5})
        return
    end
    local stepValue = math.max(0, math.floor(rawStep))

    local mode = BurdJournals.getDiminishingTrackingMode and BurdJournals.getDiminishingTrackingMode() or 3
    local focusedSkill = panel.journalFocusedSkill
    if mode == 3 and not focusedSkill then
        self:setStatus("Select a skill first", {r=1, g=0.6, b=0.4})
        return
    end

    BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    local data = modData.BurdJournals

    if mode == 1 then
        data.readCount = stepValue
    elseif mode == 2 then
        data.readSessionCount = stepValue
        data.currentSessionId = nil
        data.currentSessionReadCount = 0
    else
        local skillReadCounts = data.skillReadCounts
        if type(skillReadCounts) ~= "table" and BurdJournals.normalizeTable then
            skillReadCounts = BurdJournals.normalizeTable(skillReadCounts)
        end
        if type(skillReadCounts) ~= "table" then
            skillReadCounts = {}
        end
        data.skillReadCounts = skillReadCounts
        local resolvedKey = BurdJournals.resolveSkillKey and BurdJournals.resolveSkillKey(skillReadCounts, focusedSkill) or nil
        skillReadCounts[resolvedKey or focusedSkill] = stepValue
    end

    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
    self:refreshJournalEditorData()
    self:setStatus("Updated DR step to " .. tostring(stepValue), {r=0.4, g=0.9, b=0.75})
end

function BurdJournals.UI.DebugPanel:onJournalDecrementDRStep()
    local panel = self.journalPanel
    if not panel or not panel.journalDRStepEntry then return end
    if not BurdJournals.UI.DebugPanel.isDiminishingEnabled() then return end

    local currentStep = math.max(0, math.floor(tonumber(panel.journalDRStepEntry:getText() or "") or 0))
    if currentStep <= 0 then
        self:setStatus("Already at DR step 0", {r=0.9, g=0.75, b=0.5})
        BurdJournals.UI.DebugPanel.updateJournalDiminishingLabel(self)
        return
    end

    panel.journalDRStepEntry:setText(tostring(currentStep - 1))
    self:onJournalSetDRStep()
end

function BurdJournals.UI.DebugPanel:onJournalIncrementDRStep()
    local panel = self.journalPanel
    if not panel or not panel.journalDRStepEntry then return end
    if not BurdJournals.UI.DebugPanel.isDiminishingEnabled() then return end

    local currentStep = tonumber(panel.journalDRStepEntry:getText() or "") or 0
    local nextStep = math.max(0, math.floor(currentStep)) + 1
    panel.journalDRStepEntry:setText(tostring(nextStep))

    self:onJournalSetDRStep()
end

function BurdJournals.UI.DebugPanel:onJournalPreviewDRClaims()
    local panel = self.journalPanel
    if not panel then return end
    if not BurdJournals.UI.DebugPanel.isDiminishingEnabled() then return end

    local journal = self.editingJournal
    if not journal then
        self:setStatus("No journal selected", {r=1, g=0.5, b=0.5})
        return
    end

    local mode = BurdJournals.getDiminishingTrackingMode and BurdJournals.getDiminishingTrackingMode() or 3
    local focusedSkill = panel.journalFocusedSkill
    if mode == 3 and not focusedSkill then
        self:setStatus("Select a skill first", {r=1, g=0.6, b=0.4})
        BurdJournals.UI.DebugPanel.updateJournalDiminishingLabel(self)
        return
    end

    local journalData = BurdJournals.getJournalData and BurdJournals.getJournalData(journal) or nil
    local previewPercents = BurdJournals.UI.DebugPanel.getJournalDRPreviewPercents(journalData, focusedSkill)
    BurdJournals.UI.DebugPanel.updateJournalDiminishingLabel(self)

    if not previewPercents or #previewPercents < 3 then
        self:setStatus("No DR data to preview", {r=0.9, g=0.75, b=0.5})
        return
    end

    self:setStatus(
        "Next claims: " .. tostring(previewPercents[1]) .. "% / " .. tostring(previewPercents[2]) .. "% / " .. tostring(previewPercents[3]) .. "%",
        {r=0.65, g=0.85, b=1}
    )
end

function BurdJournals.UI.DebugPanel:onJournalResetDR()
    if not BurdJournals.UI.DebugPanel.isDiminishingEnabled() then return end
    local journal = self.editingJournal
    if not journal then
        self:setStatus("No journal selected", {r=1, g=0.5, b=0.5})
        return
    end

    BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    local data = modData.BurdJournals

    data.readCount = 0
    data.readSessionCount = 0
    data.currentSessionId = nil
    data.currentSessionReadCount = 0
    data.skillReadCounts = {}

    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
    self:refreshJournalEditorData()
    self:setStatus("Reset journal DR tracking", {r=0.8, g=0.85, b=1})
end

-- Remove focused skill from journal
function BurdJournals.UI.DebugPanel:onJournalRemoveSkill()
    local panel = self.journalPanel
    if not panel then return end

    local focusedSkill = panel.journalFocusedSkill
    if not focusedSkill then
        self:setStatus("No skill selected", {r=1, g=0.5, b=0.5})
        return
    end

    local journal = self.editingJournal
    if not journal then
        self:setStatus("No journal selected", {r=1, g=0.5, b=0.5})
        return
    end

    -- Mark as debug-edited for persistence
    BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)

    local modData = journal:getModData()
    if modData.BurdJournals and modData.BurdJournals.skills then
        if BurdJournals.normalizeTable then
            modData.BurdJournals.skills = BurdJournals.normalizeTable(modData.BurdJournals.skills) or modData.BurdJournals.skills
        end
        local skillsTable = modData.BurdJournals.skills
        local skillKey = BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, focusedSkill)
        if skillKey then
            skillsTable[skillKey] = nil
        end
        local focusedLower = string.lower(tostring(focusedSkill))
        local tableToScan = skillsTable
        if BurdJournals.normalizeTable then
            tableToScan = BurdJournals.normalizeTable(skillsTable) or skillsTable
        end
        for key, _ in pairs(tableToScan) do
            if string.lower(tostring(key)) == focusedLower then
                skillsTable[key] = nil
            end
        end
    end

    -- Finalize edit: transmit and backup to global cache
    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

    panel.journalFocusedSkill = nil
    self:refreshJournalEditorData()
    self:setStatus("Removed " .. focusedSkill .. " from journal", {r=1, g=0.7, b=0.3})
end

-- Draw function for AVAILABLE traits (left column - traits to add)
function BurdJournals.UI.DebugPanel.drawJournalAvailTraitItem(self, y, item, alt)
    local h = tonumber(self.itemheight) or 22

    -- CRITICAL: y must be a valid number for ISScrollingListBox to work correctly
    -- Return y + h (not just h) to maintain proper list positioning
    y = tonumber(y) or 0
    if y ~= y then y = 0 end  -- NaN check

    -- Item validation - return valid y + h even for invalid items
    if not item or not item.item then return y + h end
    local data = item.item
    if not data then return y + h end
    if data.hidden then return y + h end

    local w = tonumber(self.width) or 200
    if w <= 0 then w = 200 end
    local scrollOffset = tonumber(BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH) or 15
    local displayName = tostring(data.displayName or data.id or "Unknown")

    -- Background on hover (check item.index exists)
    local itemIndex = tonumber(item.index)
    if itemIndex and self.mouseoverselected == itemIndex then
        self:drawRect(0, y, w, h, 0.15, 0.2, 0.15, 0.3)
    end

    -- Trait name
    self:drawText(displayName, 6, y + 3, 0.7, 0.7, 0.7, 1, UIFont.Small)

    -- Add button
    local btnX = w - 40 - scrollOffset
    local btnW = 35
    local btnY = y + 2
    local btnH = h - 4

    if btnX > 0 and btnW > 0 and btnH > 0 then
        self:drawRect(btnX, btnY, btnW, btnH, 0.5, 0.2, 0.4, 0.2)
        self:drawRectBorder(btnX, btnY, btnW, btnH, 0.5, 0.7, 0.5, 0.8)
        self:drawTextCentre("+", btnX + btnW / 2, y + 3, 0.4, 0.9, 0.4, 1, UIFont.Small)
    end

    return y + h
end

-- Draw function for IN JOURNAL traits (right column - traits to remove)
function BurdJournals.UI.DebugPanel.drawJournalInTraitItem(self, y, item, alt)
    local h = tonumber(self.itemheight) or 22

    -- CRITICAL: y must be a valid number for ISScrollingListBox to work correctly
    -- Return y + h (not just h) to maintain proper list positioning
    y = tonumber(y) or 0
    if y ~= y then y = 0 end  -- NaN check

    -- Item validation - return valid y + h even for invalid items
    if not item or not item.item then return y + h end
    local data = item.item
    if not data then return y + h end
    if data.hidden then return y + h end

    local w = tonumber(self.width) or 200
    if w <= 0 then w = 200 end
    local scrollOffset = tonumber(BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH) or 15
    local displayName = tostring(data.displayName or data.id or "Unknown")

    -- Green background to show it's in journal
    self:drawRect(0, y, w, h, 0.1, 0.2, 0.1, 0.4)

    -- Hover highlight (check item.index exists)
    local itemIndex = tonumber(item.index)
    if itemIndex and self.mouseoverselected == itemIndex then
        self:drawRect(0, y, w, h, 0.2, 0.15, 0.15, 0.3)
    end

    -- Trait name
    self:drawText(displayName, 6, y + 3, 0.9, 1, 0.9, 1, UIFont.Small)

    -- Remove button
    local btnX = w - 40 - scrollOffset
    local btnW = 35
    local btnY = y + 2
    local btnH = h - 4

    if btnX > 0 and btnW > 0 and btnH > 0 then
        self:drawRect(btnX, btnY, btnW, btnH, 0.7, 0.3, 0.2, 0.3)
        self:drawRectBorder(btnX, btnY, btnW, btnH, 0.8, 0.4, 0.3, 0.8)
        self:drawTextCentre("-", btnX + btnW / 2, y + 3, 1, 0.5, 0.4, 1, UIFont.Small)
    end

    return y + h
end

-- Click handler for AVAILABLE traits list (add trait to journal)
function BurdJournals.UI.DebugPanel.onJournalAvailTraitListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    
    if not self.items then return end
    local row = self:rowAt(x, y)
    if not row or row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    if not item or not item.item then return end
    local data = item.item
    if not data then return end
    
    local parentPanel = self.parentPanel
    if not parentPanel then return end
    local journal = parentPanel.editingJournal
    if not journal then return end
    
    -- Check if click is in button area
    local w = self.width or 200
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH or 15
    local btnX = w - 40 - scrollOffset
    
    if x >= btnX then
        -- Mark as debug-edited for persistence
        BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)

        local modData = journal:getModData()
        if not modData.BurdJournals then modData.BurdJournals = {} end
        if not modData.BurdJournals.traits then modData.BurdJournals.traits = {} end
        if BurdJournals.normalizeTable then
            modData.BurdJournals.traits = BurdJournals.normalizeTable(modData.BurdJournals.traits) or modData.BurdJournals.traits
        end

        local traitId = data.id or data.key or data.displayName
        if not traitId then return end
        traitId = BurdJournals.UI.DebugPanel.normalizeTraitId(traitId) or traitId

        -- Prevent adding duplicate trait (including aliases)
        local lookup = BurdJournals.UI.DebugPanel.buildTraitLookup(modData.BurdJournals.traits)
        if BurdJournals.UI.DebugPanel.isTraitInLookup(lookup, traitId) then
            parentPanel:setStatus("Trait already in journal: " .. (data.displayName or tostring(traitId)), {r=1, g=0.7, b=0.3})
            return
        end

        -- Add trait to journal
        modData.BurdJournals.traits[traitId] = true
        parentPanel:setStatus("Added trait: " .. (data.displayName or tostring(traitId)), {r=0.3, g=1, b=0.5})

        -- Finalize edit: transmit and backup to global cache
        BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

        parentPanel:refreshJournalEditorData()
    end
end

-- Click handler for IN JOURNAL traits list (remove trait from journal)
function BurdJournals.UI.DebugPanel.onJournalInTraitListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    
    if not self.items then return end
    local row = self:rowAt(x, y)
    if not row or row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    if not item or not item.item then return end
    local data = item.item
    if not data then return end
    
    local parentPanel = self.parentPanel
    if not parentPanel then return end
    local journal = parentPanel.editingJournal
    if not journal then return end
    
    -- Check if click is in button area
    local w = self.width or 200
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH or 15
    local btnX = w - 40 - scrollOffset
    
    if x >= btnX then
        -- Mark as debug-edited for persistence
        BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)

        local modData = journal:getModData()
        if modData.BurdJournals and modData.BurdJournals.traits then
            if BurdJournals.normalizeTable then
                modData.BurdJournals.traits = BurdJournals.normalizeTable(modData.BurdJournals.traits) or modData.BurdJournals.traits
            end
            local traitId = data.id or data.key or data.displayName
            if not traitId then return end
            traitId = BurdJournals.UI.DebugPanel.normalizeTraitId(traitId) or traitId

            -- Remove trait from journal (including aliases)
            BurdJournals.UI.DebugPanel.removeTraitFromTable(modData.BurdJournals.traits, traitId)
            parentPanel:setStatus("Removed trait: " .. (data.displayName or tostring(traitId)), {r=1, g=0.7, b=0.3})

            -- Finalize edit: transmit and backup to global cache
            BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

            parentPanel:refreshJournalEditorData()
        end
    end
end

-- Journal command handler (clear skills, clear traits)
function BurdJournals.UI.DebugPanel:onJournalCmd(button)
    local cmd = button.internal
    local journal = self.editingJournal
    
    if not journal then
        self:setStatus("No journal selected", {r=1, g=0.5, b=0.5})
        return
    end
    
    -- Mark as debug-edited for persistence
    BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    
    if cmd == "clearskills" then
        modData.BurdJournals.skills = {}
        self:setStatus("Cleared all skills from journal", {r=1, g=0.7, b=0.3})
    elseif cmd == "cleartraits" then
        modData.BurdJournals.traits = {}
        self:setStatus("Cleared all traits from journal", {r=1, g=0.7, b=0.3})
    end

    -- Finalize edit: transmit and backup to global cache
    BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

    self:refreshJournalEditorData()
end

-- Refresh button handler
function BurdJournals.UI.DebugPanel:onJournalRefresh()
    self:refreshJournalPickerList(true)
    self:onJournalRefreshServerIndex()
    self:refreshJournalEditorData()
    self:setStatus("Journal data refreshed", {r=0.5, g=0.8, b=1})
end

-- ============================================================================
-- Add Skill Popup for Journal Editor
-- ============================================================================

-- Open the Add Skill popup
function BurdJournals.UI.DebugPanel:onJournalAddSkillPopup()
    local journal = self.editingJournal
    if not journal then
        self:setStatus("Select a journal first", {r=1, g=0.5, b=0.5})
        return
    end
    
    -- Close existing popup if open
    if self.addSkillPopup and self.addSkillPopup:isVisible() then
        self.addSkillPopup:close()
    end
    
    -- Get skills already in journal
    local journalData = BurdJournals.getJournalData(journal)
    local existingSkills = {}
    if journalData then
        local normalized = BurdJournals.normalizeJournalData(journalData) or journalData
        local skillsTable = normalized.skills or {}
        for skillName, _ in pairs(skillsTable) do
            local skillLower = string.lower(tostring(skillName))
            existingSkills[skillLower] = true
            if BurdJournals.mapPerkIdToSkillName then
                local mapped = BurdJournals.mapPerkIdToSkillName(skillName)
                if mapped then
                    existingSkills[string.lower(mapped)] = true
                end
            end
            if BurdJournals.SKILL_TO_PERK and BurdJournals.SKILL_TO_PERK[skillName] then
                existingSkills[string.lower(BurdJournals.SKILL_TO_PERK[skillName])] = true
            end
        end
    end
    
    -- Create popup panel
    local popupWidth = 300
    local popupHeight = 350
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local popupX = (screenW - popupWidth) / 2
    local popupY = (screenH - popupHeight) / 2
    
    local popup = ISPanel:new(popupX, popupY, popupWidth, popupHeight)
    popup:initialise()
    popup:instantiate()
    popup.backgroundColor = {r=0.1, g=0.1, b=0.12, a=0.98}
    popup.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
    popup:setAlwaysOnTop(true)
    popup:addToUIManager()
    popup.parentPanel = self
    
    local padding = 10
    local y = padding
    
    -- Title
    local titleLabel = ISLabel:new(padding, y, 22, "Add Skill to Journal", 0.9, 0.8, 0.6, 1, UIFont.Medium, true)
    titleLabel:initialise()
    titleLabel:instantiate()
    popup:addChild(titleLabel)
    
    -- Close button (X)
    local closeBtn = ISButton:new(popupWidth - 30, 5, 22, 22, "X", self, function()
        if popup and popup.close then
            popup:close()
        end
    end)
    closeBtn:initialise()
    closeBtn:instantiate()
    closeBtn.font = UIFont.Small
    closeBtn.textColor = {r=1, g=0.5, b=0.5, a=1}
    closeBtn.borderColor = {r=0.5, g=0.3, b=0.3, a=1}
    closeBtn.backgroundColor = {r=0.3, g=0.1, b=0.1, a=0.8}
    closeBtn.parent = popup
    popup:addChild(closeBtn)
    y = y + 28
    
    -- Search field
    local searchLabel = ISLabel:new(padding, y, 18, "Search:", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    searchLabel:initialise()
    searchLabel:instantiate()
    popup:addChild(searchLabel)
    
    popup.skillSearchEntry = ISTextEntryBox:new("", padding + 50, y - 2, popupWidth - padding * 2 - 50, 20)
    popup.skillSearchEntry:initialise()
    popup.skillSearchEntry:instantiate()
    popup.skillSearchEntry.font = UIFont.Small
    popup.skillSearchEntry:setTooltip("Type to filter skills...")
    popup.skillSearchEntry.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterAddSkillPopupList(self, popup)
    end
    popup:addChild(popup.skillSearchEntry)
    y = y + 26
    
    -- Skill list
    local listHeight = popupHeight - y - 50
    popup.skillList = ISScrollingListBox:new(padding, y, popupWidth - padding * 2, listHeight)
    popup.skillList:initialise()
    popup.skillList:instantiate()
    popup.skillList.itemheight = 24
    popup.skillList.backgroundColor = {r=0.06, g=0.06, b=0.08, a=1}
    popup.skillList.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    popup.skillList.doDrawItem = BurdJournals.UI.DebugPanel.drawAddSkillPopupItem
    popup.skillList.onMouseDown = BurdJournals.UI.DebugPanel.onAddSkillPopupListClick
    popup.skillList.parentPanel = self
    popup.skillList.popup = popup
    popup:addChild(popup.skillList)
    y = y + listHeight + 8
    
    -- Populate with available skills (not already in journal)
    local allSkills = BurdJournals.UI.DebugPanel.getAvailableSkills()
    for _, skillName in ipairs(allSkills) do
        local skillLower = string.lower(tostring(skillName))
        local skip = existingSkills[skillLower]
        if not skip and BurdJournals.SKILL_TO_PERK and BurdJournals.SKILL_TO_PERK[skillName] then
            skip = existingSkills[string.lower(BurdJournals.SKILL_TO_PERK[skillName])] or skip
        end
        if not skip and BurdJournals.mapPerkIdToSkillName then
            local mapped = BurdJournals.mapPerkIdToSkillName(skillName)
            if mapped then
                skip = existingSkills[string.lower(mapped)] or skip
            end
        end
        if not skip and BurdJournals.isSkillEnabledForJournal and not BurdJournals.isSkillEnabledForJournal(journalData, skillName) then
            skip = true
        end

        if not skip then
            local displayName = BurdJournals.getPerkDisplayName and BurdJournals.getPerkDisplayName(skillName) or tostring(skillName)
            local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillName) or false

            popup.skillList:addItem(displayName, {
                name = skillName,
                displayName = displayName,
                isPassive = isPassive
            })
        end
    end
    
    -- Close function
    popup.close = function(self)
        self:setVisible(false)
        self:removeFromUIManager()
    end
    
    self.addSkillPopup = popup
end

-- Filter Add Skill popup list
function BurdJournals.UI.DebugPanel.filterAddSkillPopupList(self, popup)
    if not popup or not popup.skillSearchEntry or not popup.skillList then return end
    
    local searchText = popup.skillSearchEntry:getText() or ""
    
    for _, itemData in ipairs(popup.skillList.items) do
        if itemData.item then
            itemData.item.hidden = searchText ~= "" and
                not debugSearchMatches(searchText, itemData.item.displayName, itemData.item.name)
        end
    end
end

-- Draw item for Add Skill popup
function BurdJournals.UI.DebugPanel.drawAddSkillPopupItem(self, y, item, alt)
    local h = tonumber(self.itemheight) or 24

    -- Defensive checks for all parameters
    y = tonumber(y) or 0
    if y ~= y then y = 0 end  -- NaN check
    if not item then return y + h end
    if not item.item then return y + h end
    local data = item.item
    if not data then return y + h end
    if data.hidden then return y + h end
    
    local w = tonumber(self.width) or 280
    if w <= 0 then w = 280 end
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH or 15
    local displayName = tostring(data.displayName or data.name or "Unknown")
    
    -- Hover highlight (check item.index exists)
    if item.index and self.mouseoverselected == item.index then
        self:drawRect(0, y, w, h, 0.15, 0.2, 0.15, 0.4)
    end

    -- Skill name
    local nameColor = data.isPassive and {0.7, 0.8, 1} or {0.9, 0.9, 0.9}
    self:drawText(displayName, 8, y + 4, nameColor[1], nameColor[2], nameColor[3], 1, UIFont.Small)

    -- Passive indicator
    if data.isPassive then
        self:drawText("[P]", w - 50 - scrollOffset, y + 4, 0.5, 0.6, 0.8, 0.7, UIFont.Small)
    end

    -- Add button
    local btnX = w - 35 - scrollOffset
    local btnW = 30
    local btnY = y + 3
    local btnH = h - 6

    if btnX > 0 and btnW > 0 and btnH > 0 then
        self:drawRect(btnX, btnY, btnW, btnH, 0.2, 0.4, 0.2, 0.5)
        self:drawRectBorder(btnX, btnY, btnW, btnH, 0.4, 0.7, 0.4, 0.8)
        self:drawTextCentre("+", btnX + btnW / 2, y + 4, 0.5, 1, 0.5, 1, UIFont.Small)
    end
    
    return y + h
end

-- Click handler for Add Skill popup list
function BurdJournals.UI.DebugPanel.onAddSkillPopupListClick(self, x, y)
    BurdJournals.UI.DebugPanel.safeListMouseDown(self, x, y)
    
    if not self.items then return end
    local row = self:rowAt(x, y)
    if not row or row <= 0 or row > #self.items then return end
    
    local item = self.items[row]
    if not item or not item.item then return end
    local data = item.item
    if not data then return end
    
    local parentPanel = self.parentPanel
    if not parentPanel then return end
    local popup = self.popup
    local journal = parentPanel.editingJournal
    if not journal then return end
    
    -- Check if click is in button area
    local w = self.width or 280
    local scrollOffset = BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH or 15
    local btnX = w - 35 - scrollOffset
    
    if x >= btnX then
        local journalData = BurdJournals.getJournalData(journal)
        if BurdJournals.isSkillEnabledForJournal and not BurdJournals.isSkillEnabledForJournal(journalData, data.name) then
            parentPanel:setStatus("Passive skills are disabled for this journal type", {r=1, g=0.7, b=0.3})
            return
        end
        -- Mark as debug-edited for persistence
        BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
        
        local modData = journal:getModData()
        if not modData.BurdJournals then modData.BurdJournals = {} end
        if not modData.BurdJournals.skills then modData.BurdJournals.skills = {} end
        if BurdJournals.normalizeTable then
            modData.BurdJournals.skills = BurdJournals.normalizeTable(modData.BurdJournals.skills) or modData.BurdJournals.skills
        end

        local skillsTable = modData.BurdJournals.skills
        local skillKey = BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, data.name)
        if skillsTable[skillKey] then
            parentPanel:setStatus("Skill already in journal: " .. (data.displayName or data.name), {r=1, g=0.7, b=0.3})
            return
        end

        -- Add skill to journal with level 0 and 0 XP
        skillsTable[skillKey] = {
            xp = 0,
            level = 0
        }

        parentPanel:setStatus("Added skill: " .. (data.displayName or data.name), {r=0.3, g=1, b=0.5})

        -- Finalize edit: transmit and backup to global cache
        BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)

        -- Remove from popup list and refresh main panel
        for i, listItem in ipairs(self.items) do
            if listItem.item and listItem.item.name == data.name then
                table.remove(self.items, i)
                break
            end
        end
        
        parentPanel:refreshJournalEditorData()
    end
end

-- ============================================================================
-- Tab 5: Diagnostics Panel
-- ============================================================================

function BurdJournals.UI.DebugPanel:createDiagnosticsPanel(startY, height)
    local panel = ISPanel:new(5, startY, self.width - 10, height)
    panel:initialise()
    panel:instantiate()
    panel.backgroundColor = {r=0.12, g=0.12, b=0.15, a=1}
    panel.borderColor = {r=0.3, g=0.4, b=0.5, a=1}
    self:addChild(panel)
    self.tabPanels["diagnostics"] = panel
    
    local padding = 10
    local y = padding
    local btnWidth = 200
    local btnHeight = 28
    
    -- Diagnostic commands
    local diagLabel = ISLabel:new(padding, y, 20, "Diagnostic Commands:", 1, 1, 1, 1, UIFont.Small, true)
    diagLabel:initialise()
    diagLabel:instantiate()
    panel:addChild(diagLabel)
    y = y + 25
    
    local diagBtns = {
        {name = "Run Full Diagnostics", cmd = "fulldiag"},
        {name = "Run Self Tests", cmd = "runselftests"},
        {name = "Scan Inventory for Journals", cmd = "scanjournals"},
        {name = "Audit Unknown Mod Sources", cmd = "auditunknownsources"},
        {name = "Check Selected Journal Persistence", cmd = "journalpersist"},
        {name = "Check Sandbox Options", cmd = "checksandbox"},
        {name = "Check Mod State", cmd = "checkmodstate"},
    }
    
    for _, btnDef in ipairs(diagBtns) do
        local btn = ISButton:new(padding, y, btnWidth, btnHeight, btnDef.name, self, BurdJournals.UI.DebugPanel.onDiagCmd)
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = btnDef.cmd
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        btn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
        panel:addChild(btn)
        y = y + btnHeight + 5
    end
    
    y = y + 20
    
    -- Verbose logging toggle
    local verboseLabel = ISLabel:new(padding, y, 20, "Verbose Logging:", 1, 1, 1, 1, UIFont.Small, true)
    verboseLabel:initialise()
    verboseLabel:instantiate()
    panel:addChild(verboseLabel)
    y = y + 25
    
    local verboseOnBtn = ISButton:new(padding, y, 100, btnHeight, "Enable", self, BurdJournals.UI.DebugPanel.onVerboseOn)
    verboseOnBtn:initialise()
    verboseOnBtn:instantiate()
    verboseOnBtn.font = UIFont.Small
    verboseOnBtn.textColor = {r=1, g=1, b=1, a=1}
    verboseOnBtn.borderColor = {r=0.3, g=0.6, b=0.4, a=1}
    verboseOnBtn.backgroundColor = {r=0.15, g=0.35, b=0.2, a=1}
    panel:addChild(verboseOnBtn)
    
    local verboseOffBtn = ISButton:new(padding + 105, y, 100, btnHeight, "Disable", self, BurdJournals.UI.DebugPanel.onVerboseOff)
    verboseOffBtn:initialise()
    verboseOffBtn:instantiate()
    verboseOffBtn.font = UIFont.Small
    verboseOffBtn.textColor = {r=1, g=1, b=1, a=1}
    verboseOffBtn.borderColor = {r=0.6, g=0.4, b=0.3, a=1}
    verboseOffBtn.backgroundColor = {r=0.35, g=0.2, b=0.15, a=1}
    panel:addChild(verboseOffBtn)

    y = y + btnHeight + 12

    local unknownLabel = ISLabel:new(padding, y, 20, "Unknown Source Results:", 1, 1, 1, 1, UIFont.Small, true)
    unknownLabel:initialise()
    unknownLabel:instantiate()
    panel:addChild(unknownLabel)
    y = y + 20

    local listHeight = math.max(120, panel.height - y - 10)
    panel.unknownSourceList = ISScrollingListBox:new(padding, y, panel.width - padding * 2, listHeight)
    panel.unknownSourceList:initialise()
    panel.unknownSourceList:instantiate()
    panel.unknownSourceList.itemheight = 20
    panel.unknownSourceList.font = UIFont.Small
    panel.unknownSourceList.backgroundColor = {r=0.08, g=0.08, b=0.1, a=0.9}
    panel.unknownSourceList.borderColor = {r=0.35, g=0.42, b=0.5, a=0.9}
    panel:addChild(panel.unknownSourceList)
    panel.unknownSourceList:addItem("Run 'Audit Unknown Mod Sources' to populate results.", nil)
    
    self.diagPanel = panel
end

local function appendUnknownSourceDiagnostics(rows, category, name, context)
    if not BurdJournals or not BurdJournals.diagnoseModSource then
        return
    end
    local diag = BurdJournals.diagnoseModSource(category, name, context)
    if not diag or diag.source ~= "Modded" then
        return
    end

    local detailParts = {}
    if diag.details then
        for k, v in pairs(diag.details) do
            table.insert(detailParts, tostring(k) .. "=" .. tostring(v))
        end
    end
    table.sort(detailParts)

    local suffix = (#detailParts > 0) and (" | " .. table.concat(detailParts, ", ")) or ""
    table.insert(rows, "[" .. category .. "] " .. tostring(name) .. " -> reason=" .. tostring(diag.reason) .. suffix)
end

local function updateUnknownSourceDiagnosticsList(self, rows)
    local panel = self and self.diagPanel
    local list = panel and panel.unknownSourceList
    if not list then
        return
    end

    list:clear()

    if not rows or #rows == 0 then
        list:addItem("No unknown-source entries found.", nil)
        return
    end

    list:addItem("Unknown-source entries: " .. tostring(#rows), nil)
    for _, row in ipairs(rows) do
        list:addItem(row, nil)
    end
end

function BurdJournals.UI.DebugPanel:onDiagCmd(button)
    local cmd = button.internal
    
    if cmd == "fulldiag" then
        BurdJournals.debugPrint("[BSJ DEBUG] === FULL DIAGNOSTICS ===")
        BurdJournals.debugPrint("--- Environment ---")
        BurdJournals.debugPrint("  Player: " .. (self.player and self.player:getUsername() or "nil"))
        BurdJournals.debugPrint("  Is Client: " .. tostring(isClient()))
        BurdJournals.debugPrint("  Is Server: " .. tostring(isServer()))
        BurdJournals.debugPrint("  Game Mode: " .. (isClient() and not isServer() and "MP Client" or (isServer() and isClient() and "Listen Server" or (isServer() and "Dedicated Server" or "Singleplayer"))))
        
        BurdJournals.debugPrint("--- Mod Status ---")
        BurdJournals.debugPrint("  BurdJournals loaded: " .. tostring(BurdJournals ~= nil))
        BurdJournals.debugPrint("  BurdJournals.Client loaded: " .. tostring(BurdJournals.Client ~= nil))
        BurdJournals.debugPrint("  BurdJournals.Server loaded: " .. tostring(BurdJournals.Server ~= nil))
        BurdJournals.debugPrint("  Verbose Logging: " .. tostring(BurdJournals.verboseLogging or false))
        
        if self.player then
            BurdJournals.debugPrint("--- Player Baseline ---")
            local modData = self.player:getModData()
            local bj = modData.BurdJournals or {}
            BurdJournals.debugPrint("  Baseline Captured: " .. tostring(bj.baselineCaptured or false))
            BurdJournals.debugPrint("  Debug Modified: " .. tostring(bj.debugModified or false))
            BurdJournals.debugPrint("  Baseline Bypassed: " .. tostring(bj.baselineBypassed or false))
            BurdJournals.debugPrint("  Baseline Version: " .. tostring(bj.baselineVersion or "none"))
            local skillCount = 0
            for _ in pairs(bj.skillBaseline or {}) do skillCount = skillCount + 1 end
            local traitCount = 0
            for _ in pairs(bj.traitBaseline or {}) do traitCount = traitCount + 1 end
            local recipeCount = 0
            for _ in pairs(bj.recipeBaseline or {}) do recipeCount = recipeCount + 1 end
            BurdJournals.debugPrint("  Skill Baselines: " .. skillCount)
            BurdJournals.debugPrint("  Trait Baselines: " .. traitCount)
            BurdJournals.debugPrint("  Recipe Baselines: " .. recipeCount)
        end
        
        BurdJournals.debugPrint("=================================")
        self:setStatus("Diagnostics output to console", {r=0.5, g=0.8, b=1})
    elseif cmd == "runselftests" then
        if BurdJournals and BurdJournals.runSelfTests then
            local result = BurdJournals.runSelfTests()
            if result and result.failed == 0 then
                self:setStatus("Self-tests passed", {r=0.3, g=1, b=0.5})
            else
                local failCount = result and result.failed or "?"
                self:setStatus("Self-tests failed (" .. tostring(failCount) .. ")", {r=1, g=0.45, b=0.45})
            end
        else
            BurdJournals.debugPrint("[BSJ DEBUG] runSelfTests() is not available")
            self:setStatus("Self-tests unavailable", {r=1, g=0.6, b=0.3})
        end
    elseif cmd == "scanjournals" then
        BurdJournals.debugPrint("[BSJ DEBUG] === INVENTORY JOURNAL SCAN ===")
        if self.player then
            local inv = self.player:getInventory()
            local items = inv:getItems()
            local journalCount = 0
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local fullType = item:getFullType()
                if fullType and string.find(fullType, "BurdJournals") then
                    journalCount = journalCount + 1
                    BurdJournals.debugPrint("  Found: " .. fullType)
                    local modData = item:getModData()
                    if modData and modData.BurdJournals then
                        BurdJournals.debugPrint("    Has ModData: yes")
                        BurdJournals.debugPrint("    Skills: " .. tostring(BurdJournals.countTable and BurdJournals.countTable(modData.BurdJournals.skills or {}) or "?"))
                        BurdJournals.debugPrint("    Traits: " .. tostring(BurdJournals.countTable and BurdJournals.countTable(modData.BurdJournals.traits or {}) or "?"))
                        BurdJournals.debugPrint("    Recipes: " .. tostring(BurdJournals.countTable and BurdJournals.countTable(modData.BurdJournals.recipes or {}) or "?"))
                        if modData.BurdJournals.ownerName then
                            BurdJournals.debugPrint("    Owner: " .. modData.BurdJournals.ownerName)
                        end
                        if modData.BurdJournals.profession then
                            BurdJournals.debugPrint("    Profession: " .. tostring(modData.BurdJournals.professionName or modData.BurdJournals.profession))
                        end
                    end
                end
            end
            BurdJournals.debugPrint("Total journals found: " .. journalCount)
        end
        BurdJournals.debugPrint("=========================================")
        self:setStatus("Journal scan complete", {r=0.5, g=0.8, b=1})
    elseif cmd == "auditunknownsources" then
        local rows = {}

        -- Inspect selected journal payload first.
        local journal = self.editingJournal
        local journalData = journal and BurdJournals.getJournalData and BurdJournals.getJournalData(journal) or nil
        if journalData then
            for skillName, _ in pairs(journalData.skills or {}) do
                appendUnknownSourceDiagnostics(rows, "skills", skillName)
            end
            for traitId, _ in pairs(journalData.traits or {}) do
                appendUnknownSourceDiagnostics(rows, "traits", traitId)
            end
            for recipeName, recipeData in pairs(journalData.recipes or {}) do
                local magazineSource = (type(recipeData) == "table" and recipeData.source) or (BurdJournals.getMagazineForRecipe and BurdJournals.getMagazineForRecipe(recipeName))
                appendUnknownSourceDiagnostics(rows, "recipes", recipeName, {magazineSource = magazineSource})
            end
        end

        -- Inspect player's currently known/active data for unknown classification.
        if self.player then
            local allowedSkills = BurdJournals.getAllowedSkills and BurdJournals.getAllowedSkills() or {}
            for _, skillName in ipairs(allowedSkills) do
                local perk = BurdJournals.getPerkByName and BurdJournals.getPerkByName(skillName)
                if perk then
                    local xpObj = self.player.getXp and self.player:getXp() or nil
                    local currentXP = (xpObj and xpObj.getXP and xpObj:getXP(perk)) or 0
                    local currentLevel = (self.player.getPerkLevel and self.player:getPerkLevel(perk)) or 0
                    if currentXP > 0 or currentLevel > 0 then
                        appendUnknownSourceDiagnostics(rows, "skills", skillName)
                    end
                end
            end

            local playerTraits = BurdJournals.collectPlayerTraits and BurdJournals.collectPlayerTraits(self.player, false) or {}
            for traitId, _ in pairs(playerTraits or {}) do
                appendUnknownSourceDiagnostics(rows, "traits", traitId)
            end

            local playerRecipes = BurdJournals.collectPlayerMagazineRecipes and BurdJournals.collectPlayerMagazineRecipes(self.player) or {}
            for recipeName, recipeData in pairs(playerRecipes or {}) do
                local magazineSource = (type(recipeData) == "table" and recipeData.source) or (BurdJournals.getMagazineForRecipe and BurdJournals.getMagazineForRecipe(recipeName))
                appendUnknownSourceDiagnostics(rows, "recipes", recipeName, {magazineSource = magazineSource})
            end
        end

        local dedup = {}
        local uniqueRows = {}
        BurdJournals.debugPrint("[BSJ DEBUG] === UNKNOWN SOURCE DIAGNOSTICS ===")
        for _, row in ipairs(rows) do
            if not dedup[row] then
                dedup[row] = true
                table.insert(uniqueRows, row)
                BurdJournals.debugPrint("  " .. row)
            end
        end
        local count = #uniqueRows
        BurdJournals.debugPrint("Total unknown-source entries: " .. tostring(count))
        BurdJournals.debugPrint("========================================")
        updateUnknownSourceDiagnosticsList(self, uniqueRows)

        if count > 0 then
            self:setStatus("Unknown-source diagnostics dumped (" .. tostring(count) .. ")", {r=0.9, g=0.8, b=0.4})
        else
            self:setStatus("No unknown-source entries found", {r=0.3, g=1, b=0.5})
        end
    elseif cmd == "journalpersist" then
        local journal = self.editingJournal
        if not journal then
            self:setStatus("No journal selected in Journal tab", {r=1, g=0.6, b=0.3})
            BurdJournals.debugPrint("[BSJ DEBUG] Journal persistence check: no selected journal")
            return
        end

        local modData = journal.getModData and journal:getModData() or nil
        local data = modData and modData.BurdJournals or nil
        local journalId = journal.getID and journal:getID() or "nil"
        local fullType = journal.getFullType and journal:getFullType() or "unknown"

        BurdJournals.debugPrint("[BSJ DEBUG] === SELECTED JOURNAL PERSISTENCE ===")
        BurdJournals.debugPrint("  Journal ID: " .. tostring(journalId))
        BurdJournals.debugPrint("  Item Type: " .. tostring(fullType))
        BurdJournals.debugPrint("  Has ModData.BurdJournals: " .. tostring(data ~= nil))

        if data then
            local skillsCount = BurdJournals.countTable and BurdJournals.countTable(data.skills) or 0
            local traitsCount = BurdJournals.countTable and BurdJournals.countTable(data.traits) or 0
            local recipesCount = BurdJournals.countTable and BurdJournals.countTable(data.recipes) or 0
            local statsCount = BurdJournals.countTable and BurdJournals.countTable(data.stats) or 0
            local hasAnyData = (BurdJournals.hasAnyEntries and (
                BurdJournals.hasAnyEntries(data.skills) or
                BurdJournals.hasAnyEntries(data.traits) or
                BurdJournals.hasAnyEntries(data.recipes) or
                BurdJournals.hasAnyEntries(data.stats)
            )) or false

            BurdJournals.debugPrint("  UUID: " .. tostring(data.uuid))
            BurdJournals.debugPrint("  journalVersion: " .. tostring(data.journalVersion))
            BurdJournals.debugPrint("  sanitizedVersion: " .. tostring(data.sanitizedVersion))
            BurdJournals.debugPrint("  compactVersion: " .. tostring(data.compactVersion))
            BurdJournals.debugPrint("  isDebugSpawned: " .. tostring(data.isDebugSpawned))
            BurdJournals.debugPrint("  isDebugEdited: " .. tostring(data.isDebugEdited))
            BurdJournals.debugPrint("  isPlayerCreated: " .. tostring(data.isPlayerCreated))
            BurdJournals.debugPrint("  isWritten: " .. tostring(data.isWritten))
            BurdJournals.debugPrint("  skills count: " .. tostring(skillsCount))
            BurdJournals.debugPrint("  traits count: " .. tostring(traitsCount))
            BurdJournals.debugPrint("  recipes count: " .. tostring(recipesCount))
            BurdJournals.debugPrint("  stats count: " .. tostring(statsCount))
            BurdJournals.debugPrint("  hasAnyEntries: " .. tostring(hasAnyData))

            local journalKey = data.uuid or tostring(journalId)
            local cache = ModData.getOrCreate("BurdJournals_DebugJournalCache")
            local hasLocalCache = cache and cache.journals and cache.journals[journalKey] ~= nil
            BurdJournals.debugPrint("  backup key: " .. tostring(journalKey))
            BurdJournals.debugPrint("  local backup cache entry: " .. tostring(hasLocalCache))

            if isClient and isClient() and not isServer() then
                BurdJournals.debugPrint("  mode: MP client (requesting server backup check)")
                if BurdJournals.Client and BurdJournals.Client.requestDebugJournalBackup then
                    BurdJournals.Client.requestDebugJournalBackup(journal, journalKey)
                end
            else
                BurdJournals.debugPrint("  mode: SP/host/server")
            end

            self:setStatus("Journal persistence dumped (key: " .. tostring(journalKey) .. ")", {r=0.5, g=0.8, b=1})
        else
            self:setStatus("Selected item has no BurdJournals data", {r=1, g=0.6, b=0.3})
        end
        BurdJournals.debugPrint("=========================================")
    elseif cmd == "checksandbox" then
        BurdJournals.debugPrint("[BSJ DEBUG] === SANDBOX OPTIONS ===")
        BurdJournals.debugPrint("--- Core Settings ---")
        local coreOptions = {
            "EnableJournals",
            "EnablePlayerJournals",
            "EnablePlayerJournalCrafting",
            "EnableBaselineRestriction",
            "AllowDebugCommands",
        }
        for _, opt in ipairs(coreOptions) do
            local value = BurdJournals.getSandboxOption and BurdJournals.getSandboxOption(opt)
            BurdJournals.debugPrint("  " .. opt .. ": " .. tostring(value))
        end
        BurdJournals.debugPrint("--- Recording Settings ---")
        local recordOptions = {
            "EnableTraitRecordingPlayer",
            "EnableRecipeRecordingPlayer",
            "EnableStatRecording",
        }
        for _, opt in ipairs(recordOptions) do
            local value = BurdJournals.getSandboxOption and BurdJournals.getSandboxOption(opt)
            BurdJournals.debugPrint("  " .. opt .. ": " .. tostring(value))
        end
        BurdJournals.debugPrint("--- World Spawns ---")
        local spawnOptions = {
            "EnableWornJournalSpawns",
            "EnableBloodyJournalSpawns",
            "EnableCursedJournalSpawns",
            "WornJournalForgetChance",
            "BloodyJournalForgetChance",
            "CursedJournalForgetChance",
            "EnableWornJournalForgetSlot",
            "EnableBloodyJournalForgetSlot",
            "EnableCursedJournalForgetSlot",
            "CursedJournalMinSkills",
            "CursedJournalMaxSkills",
            "CursedJournalMinXP",
            "CursedJournalMaxXP",
            "EnableCursedJournalTraits",
            "CursedJournalTraitChance",
            "CursedJournalMinTraits",
            "CursedJournalMaxTraits",
            "EnableCursedJournalRecipes",
            "CursedJournalRecipeChance",
            "CursedJournalMaxRecipes",
            "CursedJournalSpawnChance",
        }
        for _, opt in ipairs(spawnOptions) do
            local value = BurdJournals.getSandboxOption and BurdJournals.getSandboxOption(opt)
            BurdJournals.debugPrint("  " .. opt .. ": " .. tostring(value))
        end
        BurdJournals.debugPrint("--- Permissions ---")
        local permOptions = {
            "AllowOthersToOpenJournals",
            "AllowOthersToClaimFromJournals",
            "AllowNegativeTraits",
            "AllowPlayerJournalDissolution",
        }
        for _, opt in ipairs(permOptions) do
            local value = BurdJournals.getSandboxOption and BurdJournals.getSandboxOption(opt)
            BurdJournals.debugPrint("  " .. opt .. ": " .. tostring(value))
        end
        BurdJournals.debugPrint("==================================")
        self:setStatus("Sandbox options dumped", {r=0.5, g=0.8, b=1})
    elseif cmd == "checkmodstate" then
        BurdJournals.debugPrint("[BSJ DEBUG] === MOD STATE ===")
        BurdJournals.debugPrint("--- Core Modules ---")
        BurdJournals.debugPrint("  BurdJournals: " .. tostring(BurdJournals ~= nil))
        BurdJournals.debugPrint("  BurdJournals.Client: " .. tostring(BurdJournals.Client ~= nil))
        BurdJournals.debugPrint("  BurdJournals.Server: " .. tostring(BurdJournals.Server ~= nil))
        BurdJournals.debugPrint("  BurdJournals.UI: " .. tostring(BurdJournals.UI ~= nil))
        BurdJournals.debugPrint("--- Key Functions ---")
        BurdJournals.debugPrint("  getJournalData: " .. tostring(BurdJournals.getJournalData ~= nil))
        BurdJournals.debugPrint("  getSkillBaselineLevel: " .. tostring(BurdJournals.getSkillBaselineLevel ~= nil))
        BurdJournals.debugPrint("  getSkillLevelFromXP: " .. tostring(BurdJournals.getSkillLevelFromXP ~= nil))
        BurdJournals.debugPrint("  isBaselineRestrictionEnabled: " .. tostring(BurdJournals.isBaselineRestrictionEnabled ~= nil))
        BurdJournals.debugPrint("  calculateProfessionBaseline: " .. tostring(BurdJournals.Client and BurdJournals.Client.calculateProfessionBaseline ~= nil))
        BurdJournals.debugPrint("--- Debug Functions ---")
        BurdJournals.debugPrint("  Client.Debug: " .. tostring(BurdJournals.Client and BurdJournals.Client.Debug ~= nil))
        BurdJournals.debugPrint("  Client.Debug.getXPForLevel: " .. tostring(BurdJournals.Client and BurdJournals.Client.Debug and BurdJournals.Client.Debug.getXPForLevel ~= nil))
        BurdJournals.debugPrint("=============================")
        self:setStatus("Mod state dumped", {r=0.5, g=0.8, b=1})
    end
end

function BurdJournals.UI.DebugPanel:onVerboseOn()
    BurdJournals.verboseLogging = true
    self:setStatus("Verbose logging enabled", {r=0.3, g=1, b=0.5})
end

function BurdJournals.UI.DebugPanel:onVerboseOff()
    BurdJournals.verboseLogging = false
    self:setStatus("Verbose logging disabled", {r=1, g=0.7, b=0.3})
end

-- ============================================================================
-- Status and Close
-- ============================================================================

function BurdJournals.UI.DebugPanel:setStatus(message, color)
    if self.statusLabel then
        self.statusLabel:setName(message)
        if color then
            self.statusLabel:setColor(color.r, color.g, color.b)
        end
    end
    self.statusTime = getTimestampMs and getTimestampMs() or os.time() * 1000
end

-- Safety handlers to ensure dragging state is always cleaned up
function BurdJournals.UI.DebugPanel:onMouseUp(x, y)
    self.dragging = false
    return ISPanel.onMouseUp(self, x, y)
end

function BurdJournals.UI.DebugPanel:onMouseUpOutside(x, y)
    self.dragging = false
    return ISPanel.onMouseUpOutside(self, x, y)
end

function BurdJournals.UI.DebugPanel:onClose(skipBaselineDraftConfirm)
    if not skipBaselineDraftConfirm and self:hasUnsavedBaselineDraft() then
        self:confirmDiscardBaselineDraft(
            getText("UI_BurdJournals_BaselineDraftActionCloseDebug") or "close the debug panel",
            function()
                self:onClose(true)
            end
        )
        return
    end

    self.dragging = false
    self:setVisible(false)
    self:removeFromUIManager()
    BurdJournals.UI.DebugPanel.instance = nil
end

function BurdJournals.UI.DebugPanel:close()
    self:onClose()
end

-- ============================================================================
-- Static: Open the debug panel
-- ============================================================================

function BurdJournals.UI.DebugPanel.Open(player)
    if BurdJournals.UI.DebugPanel.instance then
        BurdJournals.UI.DebugPanel.instance:setVisible(true)
        return BurdJournals.UI.DebugPanel.instance
    end
    
    player = player or getPlayer()
    if not player then return nil end
    
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local panelW, panelH = BurdJournals.UI.DebugPanel.getPanelDimensions()
    local x = (screenW - panelW) / 2
    local y = (screenH - panelH) / 2
    
    local panel = BurdJournals.UI.DebugPanel:new(x, y, player)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    panel:setVisible(true)
    
    BurdJournals.UI.DebugPanel.instance = panel
    return panel
end

