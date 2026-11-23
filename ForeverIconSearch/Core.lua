-- ForeverIconSearch: adds a search box to every Blizzard icon picker that is
-- built on IconSelectorPopupFrameTemplate (macros, equipment sets, guild bank
-- tabs, and any addon that reuses the template).
--
-- How it works: each picker reads its icons through three frame methods
-- (GetIconByIndex / GetNumIcons / GetIndexOfIcon). We wrap those on the frame
-- instance so that, while a search is active, they serve a filtered list
-- instead of the full one. Blizzard's own code (selection, OK button, the
-- Spell/Item dropdown) keeps working unchanged on top of that.

local ADDON_NAME, ns = ...

if not IconSelectorPopupFrameTemplateMixin then
	-- Client without the shared icon picker template; nothing to do.
	return
end

local L = {
	SEARCH = SEARCH or "Search",
	NO_MATCHES = "No icons match your search",
	TOOLTIP = "Search by icon file name (e.g. |cffffffffsword|r, |cffffffffinv_misc|r), by the name of a spell, mount or item you have, or by file ID.\n\nSeparate words to require all of them; prefix a word with |cffffffff-|r to exclude it.",
}

local DEBOUNCE_SECONDS = 0.15
local QUESTION_MARK_FILE_ID = 134400

--------------------------------------------------------------------------------
-- Icon file name database (generated, parsed lazily on first search)
--------------------------------------------------------------------------------

local nameByFileID

local function GetFileNameDB()
	if not nameByFileID then
		nameByFileID = {}
		local data = ns.ICON_NAME_DATA
		if data then
			for id, name in data:gmatch("(%d+)=([^\n]+)") do
				nameByFileID[tonumber(id)] = name
			end
		end
		ns.ICON_NAME_DATA = nil -- let the big string be collected
	end
	return nameByFileID
end

--------------------------------------------------------------------------------
-- In-game names (spells, mounts, items you own) keyed by icon, rebuilt each
-- time a picker opens so it reflects your current character.
--------------------------------------------------------------------------------

local gameNames -- [icon] = "lowercased names separated by spaces"
local haystackCache -- [icon] = full searchable string

local function AddGameName(icon, name)
	if icon == nil or name == nil or name == "" then
		return
	end
	icon = tonumber(icon) or icon
	local existing = gameNames[icon]
	name = name:lower()
	if existing then
		if not existing:find(name, 1, true) then
			gameNames[icon] = existing .. " | " .. name
		end
	else
		gameNames[icon] = name
	end
end

local function NameFromLink(link)
	return link and link:match("%[(.-)%]")
end

local function CollectSpellbook()
	if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank) then
		return
	end
	local bank = Enum.SpellBookSpellBank.Player
	for lineIndex = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local line = C_SpellBook.GetSpellBookSkillLineInfo(lineIndex)
		if line and line.itemIndexOffset and line.numSpellBookItems then
			for slot = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
				local info = C_SpellBook.GetSpellBookItemInfo(slot, bank)
				if info then
					AddGameName(info.iconID, info.name)
				end
			end
		end
	end
end

local function CollectEquipment()
	local first = INVSLOT_FIRST_EQUIPPED or 1
	local last = INVSLOT_LAST_EQUIPPED or 19
	for slot = first, last do
		local texture = GetInventoryItemTexture("player", slot)
		if texture then
			AddGameName(texture, NameFromLink(GetInventoryItemLink("player", slot)))
		end
	end
end

local function CollectBags()
	if not (C_Container and C_Container.GetContainerNumSlots) then
		return
	end
	local lastBag = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
	for bag = 0, lastBag do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info then
				AddGameName(info.iconFileID, info.itemName or NameFromLink(info.hyperlink))
			end
		end
	end
end

local function CollectMounts()
	if not (C_MountJournal and C_MountJournal.GetMountIDs) then
		return
	end
	for _, mountID in ipairs(C_MountJournal.GetMountIDs()) do
		local name, _, icon, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
		if isCollected then
			AddGameName(icon, name)
		end
	end
end

local function RebuildGameNames()
	gameNames = {}
	haystackCache = {}
	-- Each source is isolated so an API change in one can't break the others.
	for _, collector in ipairs({ CollectSpellbook, CollectEquipment, CollectBags, CollectMounts }) do
		local ok, err = pcall(collector)
		if not ok and ns.debug then
			print(ADDON_NAME, "collector failed:", err)
		end
	end
end

--------------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------------

local function GetHaystack(icon)
	local cached = haystackCache[icon]
	if cached then
		return cached
	end

	local parts = {}
	local fileID = tonumber(icon)
	if fileID then
		parts[#parts + 1] = GetFileNameDB()[fileID] or ""
		parts[#parts + 1] = tostring(fileID)
		if fileID == QUESTION_MARK_FILE_ID then
			parts[#parts + 1] = "inv_misc_questionmark"
		end
	else
		-- String paths like "INTERFACE\ICONS\INV_MISC_QUESTIONMARK".
		local path = tostring(icon):lower()
		parts[#parts + 1] = path:match("([^\\/]+)$") or path
	end

	local extra = gameNames and gameNames[fileID or icon]
	if extra then
		parts[#parts + 1] = extra
	end

	local haystack = table.concat(parts, " ")
	haystackCache[icon] = haystack
	return haystack
end

-- Turns "Sword  -fire" into { include = {"sword"}, exclude = {"fire"} }.
local function ParseQuery(text)
	local include, exclude = {}, {}
	for word in text:lower():gmatch("%S+") do
		if word:sub(1, 1) == "-" and #word > 1 then
			exclude[#exclude + 1] = word:sub(2)
		elseif word ~= "-" then
			include[#include + 1] = word
		end
	end
	if #include == 0 and #exclude == 0 then
		return nil
	end
	return { include = include, exclude = exclude }
end

local function Matches(icon, query)
	local haystack = GetHaystack(icon)
	for _, term in ipairs(query.include) do
		if not haystack:find(term, 1, true) then
			return false
		end
	end
	for _, term in ipairs(query.exclude) do
		if haystack:find(term, 1, true) then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Per-picker hooking
--------------------------------------------------------------------------------

local states = {} -- [frame] = state

local function RefreshSelector(frame)
	local selector = frame.IconSelector
	selector:SetSelectionsDataProvider(GenerateClosure(frame.GetIconByIndex, frame), GenerateClosure(frame.GetNumIcons, frame))
	if frame.ReevaluateSelectedIcon then
		frame:ReevaluateSelectedIcon()
	end
	if states[frame].filtered then
		if selector.ScrollToElementDataIndex and #states[frame].filtered > 0 then
			selector:ScrollToElementDataIndex(1)
		end
	elseif selector.ScrollToSelectedIndex then
		selector:ScrollToSelectedIndex()
	end
end

local function ApplyFilter(frame)
	local state = states[frame]
	if not state then
		return
	end

	-- The picker's data provider only exists while it is shown.
	if not frame:IsShown() or not frame.iconDataProvider then
		state.filtered = nil
		state.emptyText:Hide()
		return
	end

	local query = ParseQuery(state.searchBox:GetText() or "")
	if not query then
		state.filtered = nil
	else
		if not gameNames then
			RebuildGameNames()
		end
		local results, seen = {}, {}
		for i = 1, state.origGetNumIcons(frame) do
			local icon = state.origGetIconByIndex(frame, i)
			-- Blizzard's list contains duplicates (loose icons + full list); show each once.
			if icon ~= nil and not seen[icon] then
				seen[icon] = true
				if Matches(icon, query) then
					results[#results + 1] = icon
				end
			end
		end
		state.filtered = results
	end

	state.emptyText:SetShown(state.filtered ~= nil and #state.filtered == 0)
	RefreshSelector(frame)
end

local function ScheduleFilter(frame)
	local state = states[frame]
	if state.timer then
		state.timer:Cancel()
	end
	state.timer = C_Timer.NewTimer(DEBOUNCE_SECONDS, function()
		state.timer = nil
		ApplyFilter(frame)
	end)
end

local function CreateSearchBox(frame)
	local borderBox = frame.BorderBox
	local box = CreateFrame("EditBox", nil, borderBox, "SearchBoxTemplate")
	box:SetSize(180, 20)
	box:SetFrameLevel(borderBox:GetFrameLevel() + 5)
	if borderBox.IconTypeDropdown then
		box:SetPoint("RIGHT", borderBox.IconTypeDropdown, "LEFT", -12, 0)
	elseif borderBox.IconSelectionText then
		box:SetPoint("LEFT", borderBox.IconSelectionText, "RIGHT", 16, 0)
	else
		box:SetPoint("TOPRIGHT", borderBox, "TOPRIGHT", -40, -70)
	end
	box:SetAutoFocus(false)
	box:SetMaxLetters(64)
	if box.Instructions then
		box.Instructions:SetText(L.SEARCH)
	end

	box:HookScript("OnTextChanged", function(_, userInput)
		ScheduleFilter(frame)
	end)
	box:HookScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	box:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L.SEARCH, 1, 1, 1)
		GameTooltip:AddLine(L.TOOLTIP, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	box:HookScript("OnLeave", GameTooltip_Hide)

	return box
end

local function HookPicker(frame)
	if states[frame] then
		return states[frame]
	end
	if type(frame) ~= "table" or not frame.IconSelector or not frame.BorderBox
		or type(frame.GetIconByIndex) ~= "function" or type(frame.GetNumIcons) ~= "function" then
		return nil
	end

	local state = {
		origGetIconByIndex = frame.GetIconByIndex,
		origGetNumIcons = frame.GetNumIcons,
		origGetIndexOfIcon = frame.GetIndexOfIcon,
	}
	states[frame] = state

	-- Instance overrides. Blizzard's Update() builds its selector closures from
	-- these methods, so they pick up our versions automatically.
	frame.GetIconByIndex = function(self, index)
		if state.filtered then
			return state.filtered[index]
		end
		return state.origGetIconByIndex(self, index)
	end
	frame.GetNumIcons = function(self)
		if state.filtered then
			return #state.filtered
		end
		return state.origGetNumIcons(self)
	end
	frame.GetIndexOfIcon = function(self, icon)
		if state.filtered then
			for i, candidate in ipairs(state.filtered) do
				if candidate == icon then
					return i
				end
			end
			return nil
		end
		return state.origGetIndexOfIcon(self, icon)
	end

	state.searchBox = CreateSearchBox(frame)

	state.emptyText = frame.IconSelector:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
	state.emptyText:SetPoint("CENTER")
	state.emptyText:SetText(L.NO_MATCHES)
	state.emptyText:Hide()

	-- Spell/Item/All dropdown changes the underlying list: re-run the search.
	if frame.SetIconFilterInternal then
		hooksecurefunc(frame, "SetIconFilterInternal", function(self)
			if state.filtered then
				ApplyFilter(self)
			end
		end)
	end

	-- While dragging a spell/item onto the picker Blizzard hides the grid and
	-- dropdown; hide the search box with them.
	if frame.UpdateStateFromCursorType then
		hooksecurefunc(frame, "UpdateStateFromCursorType", function(self)
			state.searchBox:SetShown(self.IconSelector:IsShown())
		end)
	end

	frame:HookScript("OnHide", function()
		if state.timer then
			state.timer:Cancel()
			state.timer = nil
		end
		state.filtered = nil
		state.emptyText:Hide()
		state.searchBox:SetText("")
		state.searchBox:ClearFocus()
		gameNames = nil
		haystackCache = nil
	end)

	return state
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

-- Every picker built on the template calls the base OnShow explicitly
-- (IconSelectorPopupFrameTemplateMixin.OnShow(self)), so hooking it here
-- catches all of them, including load-on-demand and third-party ones, before
-- their Update() runs.
hooksecurefunc(IconSelectorPopupFrameTemplateMixin, "OnShow", function(frame)
	local state = HookPicker(frame)
	if state then
		state.filtered = nil
		RebuildGameNames()
	end
end)

-- Also hook the known pickers directly as soon as they exist, in case a
-- future version stops calling the base OnShow.
local KNOWN_PICKERS = {
	"MacroPopupFrame",
	"GearManagerPopupFrame",
	"GuildBankPopupFrame",
}

local function HookKnownPickers()
	for _, name in ipairs(KNOWN_PICKERS) do
		local frame = _G[name]
		if frame and not states[frame] then
			HookPicker(frame)
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
	HookKnownPickers()
end)

-- Optional: /iconsearch debug
SLASH_FOREVERICONSEARCH1 = "/iconsearch"
SlashCmdList.FOREVERICONSEARCH = function(msg)
	msg = (msg or ""):lower()
	if msg == "debug" then
		ns.debug = not ns.debug
		print(ADDON_NAME .. ": debug " .. (ns.debug and "on" or "off"))
	else
		local count = 0
		for _ in pairs(states) do
			count = count + 1
		end
		print(("%s: %d icon names loaded, %d picker(s) hooked."):format(
			ADDON_NAME, ns.ICON_NAME_COUNT or 0, count))
	end
end
