-- Offline smoke test: stubs just enough of the WoW API and Blizzard's
-- IconSelectorPopupFrameTemplate to exercise IconPickerSearch's hook and
-- filter logic. Run from the repo root:  lua5.1 tools/test_harness.lua
-- This does NOT replace testing in the game client.

local function noop() end

-- Minimal frame object -------------------------------------------------------
local Frame = {}
Frame.__index = Frame
local function NewFrame()
	local f = setmetatable({ scripts = {}, shown = false, text = "" }, Frame)
	return f
end
function Frame:SetSize() end
function Frame:SetPoint() end
function Frame:SetFrameLevel() end
function Frame:GetFrameLevel() return 1 end
function Frame:SetAutoFocus() end
function Frame:SetMaxLetters() end
function Frame:ClearFocus() end
function Frame:SetText(t) self.text = t; if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end end
function Frame:GetText() return self.text end
function Frame:Show() self.shown = true end
function Frame:Hide() self.shown = false end
function Frame:SetShown(s) self.shown = not not s end
function Frame:IsShown() return self.shown end
function Frame:CreateFontString() return NewFrame() end
function Frame:HookScript(name, fn)
	local prev = self.scripts[name]
	self.scripts[name] = function(...) if prev then prev(...) end fn(...) end
end
function Frame:RegisterEvent() end
function Frame:SetScript(name, fn) self.scripts[name] = fn end

_G.CreateFrame = function() return NewFrame() end
_G.hooksecurefunc = function(tbl, name, fn)
	local orig = tbl[name]
	tbl[name] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
end
_G.GenerateClosure = function(fn, a) return function(...) return fn(a, ...) end end
_G.GameTooltip = NewFrame()
_G.GameTooltip_Hide = noop
_G.SlashCmdList = {}
_G.SEARCH = "Search"

local pendingTimers = {}
_G.C_Timer = { NewTimer = function(_, cb)
	local t = { cb = cb, Cancel = function(self) self.cancelled = true end }
	pendingTimers[#pendingTimers + 1] = t
	return t
end }
local function FlushTimers()
	local list = pendingTimers; pendingTimers = {}
	for _, t in ipairs(list) do if not t.cancelled then t.cb() end end
end

-- Game data: one spell "Fireball" using icon 135812, one equipped sword.
_G.Enum = { SpellBookSpellBank = { Player = 0 } }
_G.C_SpellBook = {
	GetNumSpellBookSkillLines = function() return 1 end,
	GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = 1 } end,
	GetSpellBookItemInfo = function() return { iconID = 135812, name = "Fireball" } end,
}
_G.GetInventoryItemTexture = function(_, slot) if slot == 16 then return 135274 end end
_G.GetInventoryItemLink = function(_, slot) if slot == 16 then return "|cff|Hitem:1|h[Ashkandi, Greatsword of the Brotherhood]|h|r" end end

-- Blizzard template stand-in --------------------------------------------------
local ALL_ICONS = { "INTERFACE\\ICONS\\INV_MISC_QUESTIONMARK", 135812, 135274, 132089, 132090, 135812 }
_G.IconSelectorPopupFrameTemplateMixin = {
	OnShow = noop,
	GetIconByIndex = function(self, i) return self.iconDataProvider.icons[i] end,
	GetNumIcons = function(self) return #self.iconDataProvider.icons end,
	GetIndexOfIcon = function(self, icon)
		for i = 1, self:GetNumIcons() do if self:GetIconByIndex(i) == icon then return i end end
	end,
	ReevaluateSelectedIcon = noop,
	SetIconFilterInternal = noop,
	UpdateStateFromCursorType = noop,
}

local picker = NewFrame()
for k, v in pairs(IconSelectorPopupFrameTemplateMixin) do picker[k] = v end
picker.BorderBox = NewFrame()
picker.BorderBox.IconTypeDropdown = NewFrame()
picker.IconSelector = NewFrame()
function picker.IconSelector:SetSelectionsDataProvider(get, num) self.get, self.num = get, num end
function picker.IconSelector:ScrollToElementDataIndex() end
function picker.IconSelector:ScrollToSelectedIndex() end
local function Visible()
	local out = {}
	for i = 1, picker.IconSelector.num() do out[#out + 1] = tostring(picker.IconSelector.get(i)) end
	return table.concat(out, ",")
end

-- Load the addon -------------------------------------------------------------
local ns = {}
local function load(path)
	local chunk = assert(loadfile(path))
	chunk("IconPickerSearch", ns)
end
load("IconPickerSearch/IconNames.lua")
load("IconPickerSearch/Core.lua")

-- Simulate Blizzard's subclass OnShow: base OnShow, create provider, Update().
local function ShowPicker()
	picker.shown = true
	IconSelectorPopupFrameTemplateMixin.OnShow(picker)
	picker.iconDataProvider = { icons = ALL_ICONS }
	picker.IconSelector:SetSelectionsDataProvider(GenerateClosure(picker.GetIconByIndex, picker), GenerateClosure(picker.GetNumIcons, picker))
end

local failures = 0
local function check(label, query, expected)
	_G.__searchBox:SetText(query)
	FlushTimers()
	local got = Visible()
	local ok = got == expected
	if not ok then failures = failures + 1 end
	print(("%s %-28s %-14q -> %s%s"):format(ok and "PASS" or "FAIL", label, query, got, ok and "" or ("   (expected " .. expected .. ")")))
end

-- Capture the search box the addon creates.
local realCreate = CreateFrame
_G.CreateFrame = function(...) local f = realCreate(...); _G.__searchBox = f; return f end

ShowPicker()
assert(_G.__searchBox, "search box was not created on show")

check("no query shows everything", "", table.concat({ "INTERFACE\\ICONS\\INV_MISC_QUESTIONMARK", 135812, 135274, 132089, 132090, 135812 }, ","))
check("file name", "ambush", "132089")
check("multi-word AND", "ability back", "132090")
check("exclusion", "ability -ambush", "132090")
check("spell name (dedup)", "fireball", "135812")
check("equipped item name", "ashkandi", "135274")
check("file id", "132090", "132090")
check("string path icon", "questionmark", "INTERFACE\\ICONS\\INV_MISC_QUESTIONMARK")
check("no matches", "zzzznotathing", "")

-- GetIndexOfIcon must agree with the filtered list (used for highlighting).
_G.__searchBox:SetText("ability"); FlushTimers()
assert(picker:GetIndexOfIcon(132090) == 2, "GetIndexOfIcon filtered")

-- Hiding resets the filter.
picker.shown = false
picker.scripts.OnHide(picker)
FlushTimers()
assert(picker:GetNumIcons() == #ALL_ICONS, "filter cleared on hide")
print("PASS hide clears filter")

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all checks passed")
