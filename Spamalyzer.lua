-------------------------------------------------------------------------------
-- Localized Lua globals.
-------------------------------------------------------------------------------
local _G = getfenv(0)

local math = _G.math
local string = _G.string
local table = _G.table

local pairs = _G.pairs
local ipairs = _G.ipairs

local tostring = _G.tostring

-------------------------------------------------------------------------------
-- Addon namespace.
-------------------------------------------------------------------------------
local ADDON_NAME, namespace	= ...

local KNOWN_PREFIXES		= namespace.prefixes

local LibStub		= _G.LibStub
local Spamalyzer	= LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0", "AceHook-3.0")
local LQT		= LibStub("LibQTip-1.0")
local LDB		= LibStub("LibDataBroker-1.1")
local LDBIcon		= LibStub("LibDBIcon-1.0")
local L			= LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)

-------------------------------------------------------------------------------
-- Constants.
-------------------------------------------------------------------------------
local defaults = {
	global = {
		datafeed = {
			display		= 1,	-- Output (in bytes)
			minimap_icon	= {
				hide	= false,
			},
		},
		general = {
			display_frame	= 1,	-- None
		},
		tracking = {
			battleground	= false,
			guild		= false,
			party		= true,
			raid		= true,
			whisper		= true,
		},
		tooltip = {
			hide_hint	= false,
			scale		= 1,
			sorting		= 1,	-- Name
			timer		= 0.25,
		},
	}
}

local SORT_VALUES = {
	[1]	= _G.NAME,
	[2]	= L["Bytes"],
	[3]	= L["Messages"],
}

local DISPLAY_NAMES = {
	[1]	= L["Output"],
	[2]	= L["Input"],
	[3]	= L["Bytes"],
	[4]	= L["Sent"],
	[5]	= L["Received"],
	[6]	= L["Messages"],
}

local DISPLAY_VALUES = {
	[1]	= "output",
	[2]	= "input",
	[3]	= "bytes",
	[4]	= "sent",
	[5]	= "received",
	[6]	= "messages",
}

local CHAT_FRAME_MAP = {
	[1]	= nil,
	[2]	= _G.ChatFrame1,
	[3]	= _G.ChatFrame2,
	[4]	= _G.ChatFrame3,
	[5]	= _G.ChatFrame4,
	[6]	= _G.ChatFrame5,
	[7]	= _G.ChatFrame6,
	[8]	= _G.ChatFrame7,
}

local MY_NAME		= UnitName("player")

local COLOR_GREEN	= "|cff00ff00"
local COLOR_PALE_GREEN	= "|cffa3feba"
local COLOR_PINK	= "|cffffbbbb"
local COLOR_RED		= "|cffff0000"
local COLOR_YELLOW	= "|cffffff00"

local COLOR_TABLE = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
local CLASS_COLORS = {}

for k, v in pairs(COLOR_TABLE) do
	CLASS_COLORS[k] = string.format("%2x%2x%2x", v.r * 255, v.g * 255, v.b * 255)
end

local SORT_FUNCS	-- Required for recursion, since the table is referenced within its own definition.

SORT_FUNCS = {
	[1]	= function(a, b)	-- Name
			  return a.name < b.name
		  end,
	[2]	= function(a, b)	-- Bytes
			  if a.output == b.output then
				  return SORT_FUNCS[1](a, b)
			  end
			  return a.output > b.output
		  end,
	[3]	= function(a, b)	-- Messages
			  if a.messages == b.messages then
				  return SORT_FUNCS[1](a, b)
			  end
			  return a.messages > b.messages
		  end
}

-------------------------------------------------------------------------------
-- Variables.
-------------------------------------------------------------------------------
local players = {}		-- List of players and their data.
local sorted_data = {}
local activity = {}		-- Messages/bytes in/out

local db
local output_frame
local epoch = GetTime()

-------------------------------------------------------------------------------
-- Tooltip and Databroker methods.
-------------------------------------------------------------------------------
local DrawTooltip		-- Upvalue needed for chicken-or-egg-syndrome.

local data_obj
local LDB_anchor
local tooltip

local updater			-- OnUpdate frame for tooltip refreshing/hiding.
local elapsed_line		-- Line in the tooltip where the elapsed time resides.
local new_activity		-- If true, re-sort sort_data during DrawTooltip()

local function UpdateDataFeed(value)
	data_obj.text = DISPLAY_NAMES[value]..": "..(activity[DISPLAY_VALUES[value]] or _G.NONE)
end

do
	local NUM_COLUMNS = 4

	local SetElapsedLine
	do
		local function TimeStr(val)
			local tm = tonumber(val)

			if tm <= 0 then
				return "0s"
			end
			local hours = math.floor(tm / 3600)
			local minutes = math.floor(tm / 60 - (hours * 60))
			local seconds = math.floor(tm - hours * 3600 - minutes * 60)

			hours = hours > 0 and (hours.."h") or ""
			minutes = minutes > 0 and (minutes.."m") or ""
			seconds = seconds > 0 and (seconds.."s") or ""
			return hours..minutes..seconds
		end
		local last_update = GetTime()
		local time_str = TimeStr(last_update - epoch)	-- Cached value used between updates.

		function SetElapsedLine()
			if not elapsed_line then
				return
			end
			local now = GetTime()

			if now - last_update < 1 then
				tooltip:SetCell(elapsed_line, NUM_COLUMNS, time_str)
				return
			end
			last_update = now
			time_str = TimeStr(now - epoch)

			tooltip:SetCell(elapsed_line, NUM_COLUMNS, time_str)
		end
	end
	local last_update = 0
	local check_update = 0

	updater = CreateFrame("Frame", nil, UIParent)
	updater:Hide()

	-- Handles tooltip hiding and the dynamic refresh of data
	updater:SetScript("OnUpdate",
			  function(self, elapsed)
				  check_update = check_update + elapsed

				  if check_update < 0.1 then
					  return
				  end

				  if tooltip:IsMouseOver() or (LDB_anchor and LDB_anchor:IsMouseOver()) then
					  SetElapsedLine()
					  last_update = 0
				  else
					  last_update = last_update + check_update

					  if last_update >= db.tooltip.timer then
						  tooltip = LQT:Release(tooltip)
						  LDB_anchor = nil
						  elapsed_line = nil
						  self:Hide()
					  end
				  end
				  check_update = 0
			  end)

	local function NameOnMouseUp(cell, index)
		sorted_data[index].toggled = not sorted_data[index].toggled
		DrawTooltip(LDB_anchor)
	end

	local function SortOnMouseUp(cell, sort_func)
		db.tooltip.sorting = sort_func
		table.sort(sorted_data, SORT_FUNCS[sort_func])
		DrawTooltip(LDB_anchor)
	end

	function DrawTooltip(anchor)
		LDB_anchor = anchor

		if not tooltip then
			tooltip = LQT:Acquire(ADDON_NAME.."Tooltip", NUM_COLUMNS, "LEFT", "CENTER", "CENTER", "CENTER")

			if _G.TipTac and _G.TipTac.AddModifiedTip then
				-- Pass true as second parameter because hooking OnHide causes C stack overflows
				TipTac:AddModifiedTip(tooltip, true)
			end
		end
		tooltip:Clear()
		tooltip:SmartAnchorTo(anchor)
		tooltip:SetScale(db.tooltip.scale)

		local line, column = tooltip:AddHeader()

		tooltip:SetCell(line, 1, ADDON_NAME, "CENTER", NUM_COLUMNS)
		tooltip:AddSeparator()

		if #sorted_data == 0 then
			line = tooltip:AddLine()
			tooltip:SetCell(line, 1, _G.EMPTY, "CENTER", NUM_COLUMNS)
			tooltip:Show()
			updater:Show()
			return
		end
		line = tooltip:AddLine(" ", " ", L["Messages"], L["Bytes"])
		tooltip:SetCell(line, 1, _G.NAME, "LEFT", 2)

		tooltip:SetCellScript(line, 1, "OnMouseUp", SortOnMouseUp, 1)
		tooltip:SetCellScript(line, 3, "OnMouseUp", SortOnMouseUp, 3)
		tooltip:SetCellScript(line, 4, "OnMouseUp", SortOnMouseUp, 2)

		-- If there is new activity, re-sort the data.
		if new_activity then
			table.sort(sorted_data, SORT_FUNCS[db.tooltip.sorting])
			new_activity = false
		end
		local ICON_PLUS		= [[|TInterface\BUTTONS\UI-PlusButton-Up:20:20|t]]
		local ICON_MINUS	= [[|TInterface\BUTTONS\UI-MinusButton-Up:20:20|t]]

		for index, entry in ipairs(sorted_data) do
			local toggled = entry.toggled

			line = tooltip:AddLine(toggled and ICON_MINUS or ICON_PLUS, " ", entry.messages, entry.output)
			tooltip:SetCell(line, 2, string.format("|cff%s%s|r", CLASS_COLORS[entry.class] or "cccccc", entry.name), "LEFT")

			tooltip:SetLineScript(line, "OnMouseUp", NameOnMouseUp, index)

			if toggled then
				for addon, data in pairs(entry.sources) do
					local color = data.known and COLOR_GREEN or (addon:match("UNKNOWN") and COLOR_YELLOW or COLOR_RED)

					line = tooltip:AddLine(" ", " ", data.messages, data.output)
					tooltip:SetCell(line, 2, string.format("%s%s|r", color, addon), "LEFT")
				end
			end
		end
		tooltip:AddLine(" ")

		elapsed_line = tooltip:AddLine()
		tooltip:SetCell(elapsed_line, 1, _G.TIME_ELAPSED, "LEFT", 3)
		SetElapsedLine()

		if not db.tooltip.hide_hint then
			tooltip:AddLine(" ")

			line = tooltip:AddLine()
			tooltip:SetCell(line, 1, L["Left-click to change datafeed type."], "LEFT", NUM_COLUMNS)

			line = tooltip:AddLine()
			tooltip:SetCell(line, 1, L["Shift+Left-click to clear data."], "LEFT", NUM_COLUMNS)

			line = tooltip:AddLine()
			tooltip:SetCell(line, 1, L["Right-click for options."], "LEFT", NUM_COLUMNS)
		end
		tooltip:Show()
		updater:Show()
	end
end	-- do

-------------------------------------------------------------------------------
-- Helper functions.
-------------------------------------------------------------------------------
local function GetPlayerClass(player)
	local _, class_english = UnitClass(player)

	if class_english then
		return class_english
	end

	if IsInGuild() then
		for count = 1, GetNumGuildMembers(false), 1 do
			local name, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(count)

			if name == player then
				return class
			end
		end
	end
	return nil
end

local function EscapeChar(c)
	return ("\\%03d"):format(c:byte())
end

local function StoreMessage(prefix, message, type, origin, target)
	local addon_name

	if KNOWN_PREFIXES[prefix] then
		addon_name = KNOWN_PREFIXES[prefix]
	elseif prefix:match("^$Tranq") then
		addon_name = "SimpleTranqShot"
	elseif prefix:match("^vgcomm") then
		addon_name = "VGComms"
	elseif prefix:match("^CC_") then
		addon_name = "ClassChannels"
	else
		-- Try escaping it and testing for AceComm-3.0 multi-part.
		local escaped_prefix = prefix:gsub("[%c\092\128-\255]", EscapeChar)

		if escaped_prefix:match(".-\\%d%d%d") then
			local matched_prefix = escaped_prefix:match("(.-)\\%d%d%d")

			if KNOWN_PREFIXES[matched_prefix] then
				addon_name = KNOWN_PREFIXES[matched_prefix]
			end
		end
		-- Cache this in the prefix table.
		KNOWN_PREFIXES[prefix] = addon_name
	end

	if output_frame then
		local color = (not db.tracking[type:lower()]) and COLOR_PINK or COLOR_PALE_GREEN
		local display_name = addon_name and (addon_name.." ("..prefix..")") or prefix

		message = message or ""
		target = target and (" to "..target..", from ") or ""

		output_frame:AddMessage(string.format("%s[%s][%s][%s]|r%s%s[%s]|r",
						      color, display_name, message, type, target, color, origin))
	end
	local bytes = string.len(prefix) + string.len(message)

	if bytes == 0 then
		return
	end
	local known = addon_name and true or false	-- If addon_name is nil, we didn't find a match.
	addon_name = addon_name or prefix		-- Ensure that addon_name is not nil.

	new_activity = true				-- Makes sure we re-sort the tooltip.

	local player = players[origin]

	if not player then
		player = {
			["class"]	= GetPlayerClass(origin),
			["name"]	= origin,
			["messages"]	= 1,
			["output"]	= bytes,
			["sources"]	= {}
		}

		player.sources[addon_name] = {
			["messages"]	= 1,
			["output"]	= bytes,
			["known"]	= known,
		}
		table.insert(sorted_data, player)

		players[origin] = player
	else
		player.messages = player.messages + 1
		player.output = player.output + bytes
		player.class = player.class or GetPlayerClass(origin)

		local source = player.sources[addon_name]

		if not source then
			source = {
				["known"] = known
			}
			player.sources[addon_name] = source
		end
		source.output = (source.output or 0) + bytes
		source.messages = (source.messages or 0) + 1
	end

	if origin == MY_NAME then
		activity.output = (activity.output or 0) + bytes
		activity.sent = (activity.sent or 0) + 1
	else
		activity.input = (activity.input or 0) + bytes
		activity.received = (activity.received or 0) + 1
	end
	activity.bytes = (activity.bytes or 0) + bytes
	activity.messages = (activity.messages or 0) + 1

	UpdateDataFeed(db.datafeed.display)

	if LDB_anchor and tooltip and tooltip:IsVisible() then
		DrawTooltip(LDB_anchor)
	end
end

-------------------------------------------------------------------------------
-- Hooked functions.
-------------------------------------------------------------------------------
function Spamalyzer:SendAddonMessage(prefix, message, type, target)
	if type == "WHISPER" and target and target ~= "" then
		StoreMessage(prefix, message, type, MY_NAME, target)
	end
end

-------------------------------------------------------------------------------
-- Event functions.
-------------------------------------------------------------------------------
function Spamalyzer:OnInitialize()
	local temp_db = LibStub("AceDB-3.0"):New(ADDON_NAME.."DB", defaults)
	db = temp_db.global

	output_frame = CHAT_FRAME_MAP[db.general.display_frame]

	self:SetupOptions()
end

function Spamalyzer:OnEnable()
	data_obj = LDB:NewDataObject(ADDON_NAME, {
		type	= "data source",
		label	= ADDON_NAME,
		text	= " ",
		icon	= "Interface\\Icons\\INV_Letter_16",
		OnEnter	= function(display, motion)
				  DrawTooltip(display)
			  end,
		OnLeave	= function()
			  end,
		OnClick = function(display, button)
				  if button == "RightButton" then
					  local options_frame = InterfaceOptionsFrame

					  if options_frame:IsVisible() then
						  options_frame:Hide()
					  else
						  InterfaceOptionsFrame_OpenToCategory(Spamalyzer.options_frame)
					  end
				  elseif button == "LeftButton" then
					  if IsShiftKeyDown() then
						  while #sorted_data >= 1 do
							  table.remove(sorted_data)
						  end
						  table.wipe(players)
						  table.wipe(activity)

						  epoch = GetTime()
						  elapsed_line = nil
						  DrawTooltip(display)
					  else
						  local cur_val = db.datafeed.display

						  if cur_val == 6 then
							  cur_val = 1
						  else
							  cur_val = math.max(1, math.min(6, cur_val + 1))
						  end
						  db.datafeed.display = cur_val
						  UpdateDataFeed(cur_val)
					  end
				  end
			  end,
	})
	UpdateDataFeed(db.datafeed.display)

	self:RegisterEvent("CHAT_MSG_ADDON")
	self:SecureHook("SendAddonMessage")

	if LDBIcon then
		LDBIcon:Register(ADDON_NAME, data_obj, db.datafeed.minimap_icon)
	end
end

function Spamalyzer:OnDisable()
end

function Spamalyzer:CHAT_MSG_ADDON(event, prefix, message, channel, sender)
	StoreMessage(prefix, message, channel, sender)
end

-------------------------------------------------------------------------------
-- Configuration.
-------------------------------------------------------------------------------
local options

local function GetOptions()
	if not options then
		options = {
			name = ADDON_NAME,
			childGroups = "tab",
			type = "group",
			args = {
				-------------------------------------------------------------------------------
				-- Datafeed options.
				-------------------------------------------------------------------------------
				datafeed = {
					name	= L["Datafeed"],
					order	= 10,
					type	= "group",
					args	= {
						display = {
							order	= 10,
							type	= "select",
							name	= _G.DISPLAY_LABEL,
							desc	= "",
							get	= function() return db.datafeed.display end,
							set	= function(info, value)
									  db.datafeed.display = value
									  UpdateDataFeed(value)
								  end,
							values	= DISPLAY_NAMES,
						},
						minimap_icon = {
							order	= 20,
							type	= "toggle",
							width	= "full",
							name	= L["Minimap Icon"],
							desc	= L["Draws the icon on the minimap."],
							get	= function()
									  return not db.datafeed.minimap_icon.hide
								  end,
							set	= function(info, value)
									  db.datafeed.minimap_icon.hide = not value

									  LDBIcon[value and "Show" or "Hide"](LDBIcon, ADDON_NAME)
								  end,
						},
					}
				},
				-------------------------------------------------------------------------------
				-- General options.
				-------------------------------------------------------------------------------
				general = {
					name	= _G.GENERAL_LABEL,
					order	= 20,
					type	= "group",
					args	= {
						display_frame = {
							order	= 20,
							type	= "select",
							name	= _G.DISPLAY_OPTIONS,
							desc	= L["Secondary location to display AddOn messages."],
							get	= function() return db.general.display_frame end,
							set	= function(info, value)
									  db.general.display_frame = value
									  output_frame = CHAT_FRAME_MAP[value]
								  end,
							values	= {
								[1]	= _G.NONE,
								[2]	= L["ChatFrame1"],
								[3]	= L["ChatFrame2"],
								[4]	= L["ChatFrame3"],
								[5]	= L["ChatFrame4"],
								[6]	= L["ChatFrame5"],
								[7]	= L["ChatFrame6"],
								[8]	= L["ChatFrame7"],
							},
						},
					},
				},
				-------------------------------------------------------------------------------
				-- Tracking options.
				-------------------------------------------------------------------------------
				tracking = {
					name	= L["Tracking"],
					order	= 30,
					type	= "group",
					args	= {
						battleground = {
							order	= 10,
							type	= "toggle",
							width	= "full",
							name	= _G.BATTLEGROUND,
							desc	= string.format(L["Toggle recording of %s AddOn messages."], _G.BATTLEGROUND),
							get	= function() return db.tracking.battleground end,
							set	= function() db.tracking.battleground = not db.tracking.battleground end,
						},
						guild = {
							order	= 20,
							type	= "toggle",
							width	= "full",
							name	= _G.GUILD,
							desc	= string.format(L["Toggle recording of %s AddOn messages."], _G.GUILD),
							get	= function() return db.tracking.guild end,
							set	= function() db.tracking.guild = not db.tracking.guild end,
						},
						party = {
							order	= 30,
							type	= "toggle",
							width	= "full",
							name	= _G.PARTY,
							desc	= string.format(L["Toggle recording of %s AddOn messages."], _G.PARTY),
							get	= function() return db.tracking.party end,
							set	= function() db.tracking.party = not db.tracking.party end,
						},
						raid = {
							order	= 40,
							type	= "toggle",
							width	= "full",
							name	= _G.RAID,
							desc	= string.format(L["Toggle recording of %s AddOn messages."], _G.RAID),
							get	= function() return db.tracking.raid end,
							set	= function() db.tracking.raid = not db.tracking.raid end,
						},
						whisper	= {
							order	= 50,
							type	= "toggle",
							width	= "full",
							name	= _G.WHISPER,
							desc	= string.format(L["Toggle recording of %s AddOn messages."], _G.WHISPER),
							get	= function() return db.tracking.whisper end,
							set	= function() db.tracking.whisper = not db.tracking.whisper end,
						},
					},
				},
				-------------------------------------------------------------------------------
				-- Tooltip options.
				-------------------------------------------------------------------------------
				tooltip = {
					name	= L["Tooltip"],
					order	= 40,
					type	= "group",
					args	= {
						scale = {
							order	= 10,
							type	= "range",
							width	= "full",
							name	= L["Scale"],
							desc	= L["Move the slider to adjust the scale of the tooltip."],
							min	= 0.5,
							max	= 1.5,
							step	= 0.01,
							get	= function()
									  return db.tooltip.scale
								  end,
							set	= function(info, value)
									  db.tooltip.scale = math.max(0.5, math.min(1.5, value))
								  end,
						},
						timer = {
							order	= 20,
							type	= "range",
							width	= "full",
							name	= L["Timer"],
							desc	= L["Move the slider to adjust the tooltip fade time."],
							min	= 0.1,
							max	= 2,
							step	= 0.01,
							get	= function()
									  return db.tooltip.timer
								  end,
							set	= function(info, value)
									  db.tooltip.timer = math.max(0.1, math.min(2, value))
								  end,
						},
						hide_hint = {
							order	= 30,
							type	= "toggle",
							name	= L["Hide Hint Text"],
							desc	= L["Hides the hint text at the bottom of the tooltip."],
							get	= function()
									  return db.tooltip.hide_hint
								  end,
							set	= function(info, value)
									  db.tooltip.hide_hint = value
								  end,
						},
						sorting	= {
							order	= 40,
							type	= "select",
							name	= L["Sort By"],
							desc	= L["Method to use when sorting entries in the tooltip."],
							get	= function() return db.tooltip.sorting end,
							set	= function(info, value)
									  db.tooltip.sorting = value
									  table.sort(sorted_data, SORT_FUNCS[value])
								  end,
							values	= SORT_VALUES,
						},
					},
				},
			},
		}
	end
	return options
end

function Spamalyzer:SetupOptions()
	LibStub("AceConfig-3.0"):RegisterOptionsTable(ADDON_NAME, GetOptions())
	self.options_frame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(ADDON_NAME)
end
