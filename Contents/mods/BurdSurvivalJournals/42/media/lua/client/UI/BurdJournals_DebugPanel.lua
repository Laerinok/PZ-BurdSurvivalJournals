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

BurdJournals = BurdJournals or {}
BurdJournals.UI = BurdJournals.UI or {}

-- ============================================================================
-- Debug Panel Class
-- ============================================================================

BurdJournals.UI.DebugPanel = ISPanel:derive("BurdJournals_DebugPanel")

-- Singleton instance
BurdJournals.UI.DebugPanel.instance = nil

-- Panel dimensions
BurdJournals.UI.DebugPanel.WIDTH = 680
BurdJournals.UI.DebugPanel.HEIGHT = 660

-- Scrollbar offset for right-aligned elements in lists
BurdJournals.UI.DebugPanel.SCROLLBAR_WIDTH = 15

-- ============================================================================
-- Constructor
-- ============================================================================

function BurdJournals.UI.DebugPanel:new(x, y, player)
    local width = BurdJournals.UI.DebugPanel.WIDTH
    local height = BurdJournals.UI.DebugPanel.HEIGHT
    
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
    local tabs = {"Spawn", "Character", "Baseline", "Journal", "Diagnostics"}
    local tabX = 5
    
    for _, tabName in ipairs(tabs) do
        local btn = ISButton:new(tabX, tabY, tabBtnWidth, tabBtnHeight, tabName, self, BurdJournals.UI.DebugPanel.onTabClick)
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        btn.internal = string.lower(tabName)
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        btn.backgroundColor = {r=0.15, g=0.15, b=0.2, a=1}
        self:addChild(btn)
        self.tabButtons[string.lower(tabName)] = btn
        tabX = tabX + tabBtnWidth + 2
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

function BurdJournals.UI.DebugPanel:showTab(tabId)
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
    local types = {"Blank", "Filled", "Worn", "Bloody"}
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
    
    -- ====== Owner/Assignment Section ======
    -- This section changes based on journal type:
    -- - Blank: Hidden (no owner needed)
    -- - Filled: Player dropdown + Custom option (for editable journals)
    -- - Worn/Bloody: Name field for RP/lore purposes
    
    panel.ownerSectionY = y  -- Store base Y position for dynamic repositioning
    
    panel.ownerLabel = ISLabel:new(padding, y, 18, "Assign to Player:", 0.9, 0.9, 0.7, 1, UIFont.Small, true)
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
function BurdJournals.UI.DebugPanel:populateOwnerCombo(panel)
    panel.ownerCombo:clear()
    
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
    panel.ownerCombo:addOptionWithData("Custom...", {
        isCustom = true
    })
    
    -- Default to first player
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
    local showOwner = (isBlank == false)
    local showCustomName = (isBlank == false and isCustomOwner == true)
    local showProfession = (isWornOrBloody == true)
    local showCustomProf = (isWornOrBloody == true and isCustomProf == true)
    local showFlavor = (isBlank == false)
    local showSpawnMeta = (isBlank == false)
    local showContent = (isBlank == false)
    
    -- Set visibility (with nil guards)
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
    
    -- Update owner label text
    if panel.ownerLabel then
        if isFilled then
            panel.ownerLabel:setName("Assign to Player:")
        else
            panel.ownerLabel:setName("Journal Author:")
        end
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
    
    -- Update spawn button text
    if isBlank then
        panel.spawnBtn:setTitle("SPAWN BLANK JOURNAL")
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
        searchText = panel.spawnSkillSearch:getText():lower()
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
                local displayName = (item.item.displayName or item.item.name or ""):lower()
                local name = (item.item.name or ""):lower()
                item.item.hidden = not (displayName:find(searchText, 1, true) or name:find(searchText, 1, true))
            end
        end
    end
end

function BurdJournals.UI.DebugPanel.filterSpawnTraitList(self)
    local panel = self.spawnPanel
    if not panel or not panel.traitList then return end
    
    local searchText = ""
    if panel.spawnTraitSearch and panel.spawnTraitSearch.getText then
        searchText = panel.spawnTraitSearch:getText():lower()
    end
    
    for _, item in ipairs(panel.traitList.items) do
        if searchText == "" then
            item.item.hidden = false
        else
            local displayName = (item.item.displayName or item.item.name or ""):lower()
            local name = (item.item.name or ""):lower()
            item.item.hidden = not (displayName:find(searchText, 1, true) or name:find(searchText, 1, true))
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
    local parts = {}
    
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
    
    if #parts == 0 then
        panel.summaryText:setName("No items selected")
    else
        panel.summaryText:setName(table.concat(parts, ", "))
    end
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
        owner = "Debug Spawn"
    }
    
    -- Handle owner/assignment based on journal type
    if journalType ~= "blank" then
        local selectedData = panel.ownerCombo:getOptionData(panel.ownerCombo.selected)
        
        if selectedData and selectedData.isCustom then
            -- Custom name - just for display
            local customName = panel.customNameEntry:getText()
            if customName and customName ~= "" then
                params.owner = customName
            else
                params.owner = "Unknown Survivor"
            end
            params.isCustomOwner = true
        elseif selectedData and selectedData.isPlayer then
            -- Assign to a specific player
            params.owner = selectedData.characterName
            params.ownerSteamId = selectedData.steamId
            params.ownerUsername = selectedData.username
            params.ownerCharacterName = selectedData.characterName
            params.assignedPlayer = selectedData.player
            
            -- For Filled journals, this makes the journal editable by the assigned player
            if journalType == "filled" then
                params.isPlayerCreated = true
            end
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
    
    if params.ownerSteamId then
        BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Assigned to player: " .. tostring(params.ownerCharacterName) .. " (SteamID: " .. tostring(params.ownerSteamId) .. ")")
    elseif params.isCustomOwner then
        BurdJournals.debugPrint("[BurdJournals] DEBUG UI: Custom owner name: " .. tostring(params.owner))
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
            end
            self:setStatus("Spawned " .. journalType .. " journal!" .. ownerInfo, {r=0.3, g=1, b=0.5})
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
    
    -- In multiplayer, add other online players
    if isClient() then
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
        searchText = panel.skillSearchEntry:getText():lower()
    end
    
    -- If no search text, show all items
    if searchText == "" then
        for _, item in ipairs(panel.charSkillList.items) do
            item.item.hidden = false
        end
    else
        -- Filter items by name
        for _, item in ipairs(panel.charSkillList.items) do
            local displayName = (item.item.displayName or item.item.name or ""):lower()
            local name = (item.item.name or ""):lower()
            local category = (item.item.category or ""):lower()
            item.item.hidden = not (displayName:find(searchText, 1, true) or name:find(searchText, 1, true) or category:find(searchText, 1, true))
        end
    end
end

-- Filter trait list based on search text
function BurdJournals.UI.DebugPanel.filterCharacterTraitList(self)
    local panel = self.charPanel
    if not panel or not panel.charTraitList then return end
    
    local searchText = ""
    if panel.traitSearchEntry and panel.traitSearchEntry.getText then
        searchText = panel.traitSearchEntry:getText():lower()
    end
    
    -- If no search text, show all items
    if searchText == "" then
        for _, item in ipairs(panel.charTraitList.items) do
            item.item.hidden = false
        end
    else
        -- Filter items by name
        for _, item in ipairs(panel.charTraitList.items) do
            local displayName = (item.item.displayName or item.item.id or ""):lower()
            local id = (item.item.id or ""):lower()
            item.item.hidden = not (displayName:find(searchText, 1, true) or id:find(searchText, 1, true))
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
        
        -- Dump button only
        local dumpBtn = ISButton:new(padding, y, 150, btnHeight, "Dump Stats to Console", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
        dumpBtn:initialise()
        dumpBtn:instantiate()
        dumpBtn.font = UIFont.Small
        dumpBtn.internal = "dumpbaseline"
        dumpBtn.textColor = {r=1, g=1, b=1, a=1}
        dumpBtn.borderColor = {r=0.4, g=0.5, b=0.6, a=1}
        dumpBtn.backgroundColor = {r=0.2, g=0.25, b=0.3, a=1}
        panel:addChild(dumpBtn)
        
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
    
    -- Skill search field
    panel.baselineSkillSearch = ISTextEntryBox:new("", padding + 230, y - 2, 130, 20)
    panel.baselineSkillSearch:initialise()
    panel.baselineSkillSearch:instantiate()
    panel.baselineSkillSearch.font = UIFont.Small
    panel.baselineSkillSearch:setTooltip("Filter skills...")
    panel.baselineSkillSearch.onTextChange = function()
        BurdJournals.UI.DebugPanel.filterBaselineSkillList(self)
    end
    panel:addChild(panel.baselineSkillSearch)
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
    
    local recalcBtn = ISButton:new(btnX, y, btnWidth, btnHeight, "Recalc from Profession", self, BurdJournals.UI.DebugPanel.onBaselineCmd)
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
    
    -- Store reference
    self.baselinePanel = panel
    panel.targetPlayer = self.player  -- Default to current player
    
    -- Initial population
    self:populateBaselinePlayerList()
    self:refreshBaselineData()
end

-- Populate player dropdown with online players
function BurdJournals.UI.DebugPanel:populateBaselinePlayerList()
    local panel = self.baselinePanel
    if not panel or not panel.targetPlayerCombo then return end
    
    panel.targetPlayerCombo:clear()
    
    -- Always add current player first
    local currentName = self.player and self.player:getUsername() or "You"
    panel.targetPlayerCombo:addOptionWithData(currentName, self.player)
    
    -- Add other online players if in multiplayer
    if isClient() then
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
    
    panel.targetPlayerCombo:select(currentName)
end

-- Handler for player selection change
function BurdJournals.UI.DebugPanel:onBaselineTargetPlayerChange(combo)
    local panel = self.baselinePanel
    if not panel then return end
    
    local selected = combo:getSelectedIndex()
    local data = combo.options[selected + 1]
    if data and data.data then
        panel.targetPlayer = data.data
        self:refreshBaselineData()
        self:setStatus("Viewing baseline for: " .. (panel.targetPlayer:getUsername() or "Unknown"), {r=0.5, g=0.8, b=1})
    end
end

-- Refresh button handler (non-destructive - just refreshes display without modifying baseline)
function BurdJournals.UI.DebugPanel:onBaselineRefresh()
    -- Don't clear skill cache - that's for full rediscovery
    -- Just refresh the player list and current baseline data display
    self:populateBaselinePlayerList()
    self:refreshBaselineData()
    self:setStatus("Display refreshed (baseline unchanged)", {r=0.5, g=0.8, b=1})
end

-- Refresh baseline data for the target player
function BurdJournals.UI.DebugPanel:refreshBaselineData()
    local panel = self.baselinePanel
    if not panel then return end

    local targetPlayer = panel.targetPlayer or self.player
    if not targetPlayer then 
        -- No player yet, skip population
        return 
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
        searchText = panel.baselineSkillSearch:getText():lower()
    end
    
    for _, item in ipairs(panel.baselineSkillList.items) do
        if searchText == "" then
            item.item.hidden = false
        else
            local displayName = (item.item.displayName or item.item.name or ""):lower()
            local name = (item.item.name or ""):lower()
            local category = (item.item.category or ""):lower()
            item.item.hidden = not (displayName:find(searchText, 1, true) or name:find(searchText, 1, true) or category:find(searchText, 1, true))
        end
    end
end

function BurdJournals.UI.DebugPanel.filterBaselineTraitList(self)
    local panel = self.baselinePanel
    if not panel or not panel.baselineTraitList then return end
    
    local searchText = ""
    if panel.baselineTraitSearch and panel.baselineTraitSearch.getText then
        searchText = panel.baselineTraitSearch:getText():lower()
    end
    
    for _, item in ipairs(panel.baselineTraitList.items) do
        if searchText == "" then
            item.item.hidden = false
        else
            local displayName = (item.item.displayName or item.item.id or ""):lower()
            local id = (item.item.id or ""):lower()
            item.item.hidden = not (displayName:find(searchText, 1, true) or id:find(searchText, 1, true))
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
        
        -- Set the baseline for this skill
        if BurdJournals.setSkillBaseline then
            local success = BurdJournals.setSkillBaseline(targetPlayer, data.name, clickedLevel)
            if success then
                data.baselineLevel = clickedLevel
                parentPanel:setStatus("Set " .. data.displayName .. " baseline to level " .. clickedLevel, {r=0.3, g=1, b=0.5})
                
                -- Mark baseline as debug-modified to prevent auto-recalculation on mod reload
                local modData = targetPlayer:getModData()
                if modData.BurdJournals then
                    modData.BurdJournals.debugModified = true
                    BurdJournals.debugPrint("[BurdJournals] DEBUG: Set debugModified=true for skill baseline " .. data.name)
                end
                -- Persist to disk immediately so it survives mod reload/game restart
                targetPlayer:transmitModData()
                
                -- Sync to server for multiplayer persistence
                -- Calculate the XP value that was stored (server needs XP, not level)
                -- Use our verified threshold tables for consistent values
                local baselineXP = 0
                if clickedLevel > 0 then
                    local isPassive = (data.name == "Fitness" or data.name == "Strength")
                    if isPassive then
                        baselineXP = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[clickedLevel] or 37500
                    else
                        baselineXP = BurdJournals.STANDARD_XP_THRESHOLDS and BurdJournals.STANDARD_XP_THRESHOLDS[clickedLevel] or 0
                    end
                end
                
                -- Update local data
                data.baselineXP = baselineXP
                
                sendClientCommand("BurdJournals", "debugUpdateSkillBaseline", {
                    skillName = data.name,
                    baselineXP = baselineXP,
                    targetUsername = targetPlayer:getUsername()
                })
            end
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
    
    if BurdJournals.setTraitBaseline then
        local success = BurdJournals.setTraitBaseline(targetPlayer, data.id, newStatus)
        if success then
            data.isBaseline = newStatus
            local statusText = newStatus and "added to" or "removed from"
            parentPanel:setStatus(data.displayName .. " " .. statusText .. " baseline", {r=0.3, g=1, b=0.5})
            
            -- Mark baseline as debug-modified to prevent auto-recalculation on mod reload
            local modData = targetPlayer:getModData()
            if modData.BurdJournals then
                modData.BurdJournals.debugModified = true
                BurdJournals.debugPrint("[BurdJournals] DEBUG: Set debugModified=true for trait baseline " .. data.id)
            end
            -- Persist to disk immediately so it survives mod reload/game restart
            targetPlayer:transmitModData()
            
            -- Sync to server for multiplayer persistence
            sendClientCommand("BurdJournals", "debugUpdateTraitBaseline", {
                traitId = data.id,
                isBaseline = newStatus,
                targetUsername = targetPlayer:getUsername()
            })
        end
    end
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
    elseif cmd == "clearall" then
        if targetPlayer then
            if isClient() and not isServer() then
                sendClientCommand("BurdJournals", "debugClearBaseline", {
                    category = "all",
                    targetUsername = targetPlayer:getUsername()
                })
            else
                local modData = targetPlayer:getModData()
                modData.BurdJournals = modData.BurdJournals or {}
                modData.BurdJournals.skillBaseline = {}
                modData.BurdJournals.traitBaseline = {}
                modData.BurdJournals.recipeBaseline = {}
                modData.BurdJournals.debugModified = true  -- Mark as debug modified for persistence
                if targetPlayer.transmitModData then
                    targetPlayer:transmitModData()
                end
            end
            self:refreshBaselineData()
            self:setStatus("Baseline cleared for " .. (targetPlayer:getUsername() or "player"), {r=0.3, g=1, b=0.5})
        end
    elseif cmd == "recalculate" then
        if targetPlayer then
            if sendClientCommand then
                -- Server-authoritative recalculation
                sendClientCommand("BurdJournals", "debugRecalcBaseline", {
                    targetUsername = targetPlayer:getUsername()
                })
                self:setStatus("Requested baseline recalculation for " .. (targetPlayer:getUsername() or "player"), {r=0.5, g=0.8, b=1})
            elseif BurdJournals.Server and BurdJournals.Server.handleDebugRecalcBaseline then
                -- Fallback for environments where client command isn't available
                BurdJournals.Server.handleDebugRecalcBaseline(targetPlayer, {
                    targetUsername = targetPlayer:getUsername()
                })
                self:refreshBaselineData()
                self:setStatus("Baseline recalculated for " .. (targetPlayer:getUsername() or "player"), {r=0.3, g=1, b=0.5})
            else
                self:setStatus("Recalculate function not available", {r=1, g=0.5, b=0.3})
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
    
    -- Journal info line
    panel.journalInfoLabel = ISLabel:new(padding, y, 16, "", 0.6, 0.6, 0.7, 1, UIFont.Small, true)
    panel.journalInfoLabel:initialise()
    panel.journalInfoLabel:instantiate()
    panel:addChild(panel.journalInfoLabel)
    y = y + 22
    
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

    local previewDRBtn = ISButton:new(padding + 250, y - 2, 36, 20, "x3", self, BurdJournals.UI.DebugPanel.onJournalPreviewDRClaims)
    previewDRBtn:initialise()
    previewDRBtn:instantiate()
    previewDRBtn.font = UIFont.Small
    previewDRBtn.textColor = {r=1, g=1, b=1, a=1}
    previewDRBtn.borderColor = {r=0.3, g=0.45, b=0.4, a=1}
    previewDRBtn.backgroundColor = {r=0.18, g=0.28, b=0.22, a=1}
    panel:addChild(previewDRBtn)
    panel.journalDRPreviewBtn = previewDRBtn

    local resetDRBtn = ISButton:new(padding + 290, y - 2, 56, 20, "Reset", self, BurdJournals.UI.DebugPanel.onJournalResetDR)
    resetDRBtn:initialise()
    resetDRBtn:instantiate()
    resetDRBtn.font = UIFont.Small
    resetDRBtn.textColor = {r=1, g=1, b=1, a=1}
    resetDRBtn.borderColor = {r=0.5, g=0.35, b=0.25, a=1}
    resetDRBtn.backgroundColor = {r=0.3, g=0.2, b=0.12, a=1}
    panel:addChild(resetDRBtn)
    panel.journalDRResetBtn = resetDRBtn

    panel.journalDRHintLabel = ISLabel:new(padding + 352, y, 16, "", 0.55, 0.62, 0.72, 1, UIFont.Small, true)
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
end

-- Filter journal skill list by search text
function BurdJournals.UI.DebugPanel.filterJournalSkillList(self)
    local panel = self.journalPanel
    if not panel or not panel.journalSkillSearchEntry or not panel.journalSkillList then return end
    
    local searchText = string.lower(panel.journalSkillSearchEntry:getText() or "")
    
    for _, itemData in ipairs(panel.journalSkillList.items) do
        if itemData.item then
            local displayName = string.lower(itemData.item.displayName or "")
            local skillName = string.lower(itemData.item.name or "")
            itemData.item.hidden = searchText ~= "" and 
                not string.find(displayName, searchText, 1, true) and
                not string.find(skillName, searchText, 1, true)
        end
    end
end

-- Filter available trait list (left column) by search text
function BurdJournals.UI.DebugPanel.filterJournalAvailTraitList(self)
    local panel = self.journalPanel
    if not panel or not panel.journalAvailTraitSearchEntry or not panel.journalAvailTraitList then return end
    
    local searchText = string.lower(panel.journalAvailTraitSearchEntry:getText() or "")
    
    for _, itemData in ipairs(panel.journalAvailTraitList.items) do
        if itemData.item then
            local displayName = string.lower(itemData.item.displayName or "")
            local traitId = string.lower(itemData.item.id or "")
            itemData.item.hidden = searchText ~= "" and 
                not string.find(displayName, searchText, 1, true) and
                not string.find(traitId, searchText, 1, true)
        end
    end
end

-- Filter journal trait list (right column) by search text
function BurdJournals.UI.DebugPanel.filterJournalInTraitList(self)
    local panel = self.journalPanel
    if not panel or not panel.journalInTraitSearchEntry or not panel.journalInTraitList then return end
    
    local searchText = string.lower(panel.journalInTraitSearchEntry:getText() or "")
    
    for _, itemData in ipairs(panel.journalInTraitList.items) do
        if itemData.item then
            local displayName = string.lower(itemData.item.displayName or "")
            local traitId = string.lower(itemData.item.id or "")
            itemData.item.hidden = searchText ~= "" and 
                not string.find(displayName, searchText, 1, true) and
                not string.find(traitId, searchText, 1, true)
        end
    end
end

-- Select a journal from player inventory
function BurdJournals.UI.DebugPanel:onJournalSelectFromInventory()
    local player = self.player
    if not player then return end
    
    -- Find first filled journal in inventory
    local inventory = player:getInventory()
    if not inventory then 
        self:setStatus("No inventory found", {r=1, g=0.5, b=0.5})
        return 
    end
    
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.getFullType then
            local itemType = item:getFullType()
            if itemType and (string.find(itemType, "SurvivalJournal") or 
                             string.find(itemType, "BloodyJournal") or 
                             string.find(itemType, "WornJournal")) then
                local journalData = BurdJournals.getJournalData(item)
                if journalData then
                    -- Use safe countTable to check for filled journal (handles Java-backed ModData)
                    local hasSkills = journalData.skills and BurdJournals.countTable(journalData.skills) > 0
                    local hasTraits = journalData.traits and BurdJournals.countTable(journalData.traits) > 0
                    if hasSkills or hasTraits then
                        self.editingJournal = item
                        self:refreshJournalEditorData()
                        self:setStatus("Selected: " .. (item:getName() or "Journal"), {r=0.5, g=1, b=0.5})
                        return
                    end
                end
            end
        end
    end
    
    self:setStatus("No filled journals found in inventory", {r=1, g=0.5, b=0.5})
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
        panel.journalFocusedSkill = nil
        BurdJournals.UI.DebugPanel.updateJournalSkillLabel(self)
        return
    end

    -- Update header with journal name
    local journalName = journal:getName() or "Unknown Journal"
    panel.journalHeaderLabel:setName(journalName)

    -- Get journal data
    local journalData = BurdJournals.getJournalData(journal)
    if not journalData then
        panel.journalInfoLabel:setName("No data in journal")
        panel.journalFocusedSkill = nil
        BurdJournals.UI.DebugPanel.updateJournalSkillLabel(self)
        return
    end
    
    -- Update info line
    local skillCount = journalData.skills and BurdJournals.countTable(journalData.skills) or 0
    local traitCount = journalData.traits and BurdJournals.countTable(journalData.traits) or 0
    local recipeCount = journalData.recipes and BurdJournals.countTable(journalData.recipes) or 0
    local infoText = string.format("%s %d | %s %d | %s %d", getText("UI_BurdJournals_TabSkills"), skillCount, getText("UI_BurdJournals_TabTraits"), traitCount, getText("UI_BurdJournals_TabRecipes"), recipeCount)
    if journalData.isPlayerCreated then
        infoText = infoText .. " [Player Journal]"
    elseif journalData.isDebugSpawned then
        infoText = infoText .. " [Debug Spawned]"
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
    
    -- Ensure level and xp are valid numbers (ModData can have unexpected types)
    local currentLevel = tonumber(data.level) or 0
    local currentXP = tonumber(data.xp) or 0
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
    local squaresX = 185
    local squareSize = 12
    local squareSpacing = 2
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
        
        -- Toggle off if clicking current level
        if clickedLevel == data.level then
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
        panel.journalDRPreviewBtn,
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

-- Mark journal as debug-edited for persistence across restarts and mod updates
-- This sets the isDebugSpawned flag which tells sanitization to use lenient mode
-- Also sets isPlayerCreated so claims work properly (not treated as worn/bloody)
-- Also backs up journal data to global ModData for extra persistence (like baseline system)
function BurdJournals.UI.DebugPanel.markJournalAsDebugEdited(journal)
    if not journal then return end
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end

    local needsTransmit = false

    if not modData.BurdJournals.uuid then
        local generatedUUID = (BurdJournals.generateUUID and BurdJournals.generateUUID())
            or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
        modData.BurdJournals.uuid = generatedUUID
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Assigned UUID to debug-edited journal: " .. tostring(generatedUUID))
    end

    -- Set debug flag if not already set - this enables lenient sanitization
    if not modData.BurdJournals.isDebugSpawned then
        modData.BurdJournals.isDebugSpawned = true
        modData.BurdJournals.isDebugEdited = true  -- Additional flag for tracking
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Marked journal as debug-edited for persistence")
    end

    -- IMPORTANT: Set isPlayerCreated so claims work properly
    -- Without this, the journal is treated like a worn/bloody journal with per-character claim tracking
    if not modData.BurdJournals.isPlayerCreated then
        modData.BurdJournals.isPlayerCreated = true
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Set isPlayerCreated=true for proper claim handling")
    end

    -- Clear any worn/bloody flags that might interfere with claims
    if modData.BurdJournals.isWorn or modData.BurdJournals.isBloody then
        modData.BurdJournals.isWorn = nil
        modData.BurdJournals.isBloody = nil
        modData.BurdJournals.wasFromBloody = nil
        needsTransmit = true
        BurdJournals.debugPrint("[BurdJournals] Cleared worn/bloody flags for debug-edited journal")
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

    -- Always backup to global cache after marking (backup handles its own checks)
    -- This is called at the START of edits, backup will be updated again after edit completes
    BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(journal)
end

-- Finalize debug journal edit - transmit and backup after data modification
-- Call this AFTER modifying journal data to ensure persistence
function BurdJournals.UI.DebugPanel.finalizeJournalEdit(journal)
    if not journal then return end

    -- Ensure critical flags are set before transmitting
    local modData = journal:getModData()
    if modData and modData.BurdJournals then
        if not modData.BurdJournals.uuid then
            modData.BurdJournals.uuid = (BurdJournals.generateUUID and BurdJournals.generateUUID())
                or ("debug-" .. tostring(getTimestampMs and getTimestampMs() or os.time()) .. "-" .. tostring(journal:getID()))
        end

        -- Always ensure these flags are set for proper behavior
        modData.BurdJournals.isDebugSpawned = true
        modData.BurdJournals.isDebugEdited = true
        modData.BurdJournals.isPlayerCreated = true
        modData.BurdJournals.sanitizedVersion = BurdJournals.SANITIZE_VERSION or 1

        -- Mark as written so it's recognized as a valid filled journal
        modData.BurdJournals.isWritten = true
    end

    -- Transmit the item's ModData to server (critical for MP persistence)
    if journal.transmitModData then
        journal:transmitModData()
        BurdJournals.debugPrint("[BurdJournals] Transmitted journal ModData to server")
    end

    -- Backup to global cache for extra persistence (mainly helps in SP)
    local journalKey, backupData = BurdJournals.UI.DebugPanel.backupJournalToGlobalCache(journal)

    -- MP authoritative persist: push edited journal payload to server-side item modData.
    local player = getPlayer()
    if player and backupData and isClient and isClient() then
        sendClientCommand(player, "BurdJournals", "debugApplyJournalEdits", {
            journalId = journal:getID(),
            journalKey = journalKey,
            journalData = backupData
        })
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

    -- Build the backup data structure
    local backupData = {
        skills = {},
        traits = {},
        recipes = {},
        stats = {},
        skillReadCounts = {},
        isDebugSpawned = true,
        isDebugEdited = modData.BurdJournals.isDebugEdited,
        isPlayerCreated = modData.BurdJournals.isPlayerCreated,
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

    -- Copy data with normalized tables to avoid Java-backed iteration issues
    local normalized = BurdJournals.normalizeJournalData(modData.BurdJournals) or modData.BurdJournals

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

    -- Restore flags
    modData.BurdJournals.isDebugSpawned = true
    modData.BurdJournals.isDebugEdited = normalizedBackup.isDebugEdited
    modData.BurdJournals.isPlayerCreated = normalizedBackup.isPlayerCreated or true  -- Ensure this is set
    modData.BurdJournals.sanitizedVersion = normalizedBackup.sanitizedVersion or (BurdJournals.SANITIZE_VERSION or 1)
    modData.BurdJournals.uuid = normalizedBackup.uuid

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
    
    -- Calculate XP for level using thresholds
    local xp = 0
    local isPassive = BurdJournals.isPassiveSkill and BurdJournals.isPassiveSkill(skillKey) or false
    
    if level > 0 then
        if isPassive then
            xp = BurdJournals.PASSIVE_XP_THRESHOLDS and BurdJournals.PASSIVE_XP_THRESHOLDS[level] or (level * 7500)
        else
            xp = BurdJournals.STANDARD_XP_THRESHOLDS and BurdJournals.STANDARD_XP_THRESHOLDS[level] or (level * 150)
        end
    end
    
    -- Keep skill at level 0 with 0 XP (don't auto-remove)
    skillsTable[skillKey] = {
        xp = xp,
        level = level
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
    local xp = tonumber(xpText) or 0
    
    local modData = journal:getModData()
    if not modData.BurdJournals then modData.BurdJournals = {} end
    if not modData.BurdJournals.skills then modData.BurdJournals.skills = {} end
    if BurdJournals.normalizeTable then
        modData.BurdJournals.skills = BurdJournals.normalizeTable(modData.BurdJournals.skills) or modData.BurdJournals.skills
    end
    local skillsTable = modData.BurdJournals.skills
    local skillKey = BurdJournals.UI.DebugPanel.resolveSkillKey(skillsTable, focusedSkill)
    
    -- Calculate level from XP
    local level = 0
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
    local closeBtn = ISButton:new(popupWidth - 30, 5, 22, 22, "X", self, function(btn)
        btn.parent:close()
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
    
    local searchText = string.lower(popup.skillSearchEntry:getText() or "")
    
    for _, itemData in ipairs(popup.skillList.items) do
        if itemData.item then
            local displayName = string.lower(itemData.item.displayName or "")
            local skillName = string.lower(itemData.item.name or "")
            itemData.item.hidden = searchText ~= "" and 
                not string.find(displayName, searchText, 1, true) and
                not string.find(skillName, searchText, 1, true)
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
    
    self.diagPanel = panel
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

function BurdJournals.UI.DebugPanel:onClose()
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
    local x = (screenW - BurdJournals.UI.DebugPanel.WIDTH) / 2
    local y = (screenH - BurdJournals.UI.DebugPanel.HEIGHT) / 2
    
    local panel = BurdJournals.UI.DebugPanel:new(x, y, player)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    panel:setVisible(true)
    
    BurdJournals.UI.DebugPanel.instance = panel
    return panel
end

