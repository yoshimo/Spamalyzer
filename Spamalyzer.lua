-------------------------------------------------------------------------------
-- Localized Lua globals.
-------------------------------------------------------------------------------
local _G = getfenv(0)

local math = _G.math
local string = _G.string
local table = _G.table

local pairs = _G.pairs

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

local db
local data_obj
local output_frame
local tooltip

-------------------------------------------------------------------------------
-- Constants.
-------------------------------------------------------------------------------
local defaults = {
	global = {
		datafeed = {
			display		= 1,	-- Message count
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
	[1]	= L["Name"],
	[2]	= L["Bytes"],
	[3]	= L["Messages"],
}

local DISPLAY_VALUES = {
	[1]	= L["Sent"],
	[2]	= L["Received"],
	[3]	= L["Bytes Out"],
	[4]	= L["Bytes In"],
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
local COLOR_GREY	= "|cffcccccc"
local COLOR_ORANGE	= "|cffeda55f"
local COLOR_PALE_GREEN	= "|cffa3feba"
local COLOR_PINK	= "|cffffbbbb"
local COLOR_RED		= "|cffff0000"
local COLOR_WHITE	= "|cffffffff"
local COLOR_YELLOW	= "|cffffff00"

local ICON_PLUS		= [[|TInterface\BUTTONS\UI-PlusButton-Up:20:20|t]]
local ICON_MINUS	= [[|TInterface\BUTTONS\UI-MinusButton-Up:20:20|t]]

-------------------------------------------------------------------------------
-- Variables.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Helper functions.
-------------------------------------------------------------------------------
local function EscapeChar(c)
	return ("\\%03d"):format(c:byte())
end

local function StoreMessage(prefix, message, type, origin, target)
	local name

	if KNOWN_PREFIXES[prefix] then
		name = KNOWN_PREFIXES[prefix]
	elseif prefix:match("^$Tranq") then
		name = "SimpleTranqShot"
	elseif prefix:match("^vgcomm") then
		name = "VGComms"
	elseif prefix:match("^CC_") then
		name = "ClassChannels"
	else
		-- Try escaping it and testing for AceComm-3.0 multi-part
		local escaped_prefix = prefix:gsub("[%c\092\128-\255]", EscapeChar)

		if escaped_prefix:match(".-\\%d%d%d") then
			local matched_prefix = escaped_prefix:match("(.-)\\%d%d%d")

			if KNOWN_PREFIXES[matched_prefix] then
				name = KNOWN_PREFIXES[matched_prefix]
			end
		end
		-- Cache this in the prefix table
		KNOWN_PREFIXES[prefix] = name
-- DEBUG		print(string.format("Adding prefix %s as '%s'", prefix, name))
	end

	if output_frame then
		local color = (not db.tracking[type:lower()]) and COLOR_PINK or COLOR_PALE_GREEN

		message = message or ""
		target = target and (" to "..target..", from ") or ""

		output_frame:AddMessage(string.format("%s[%s][%s][%s]|r%s%s[%s]|r",
						      color, prefix, message, type, target, color, origin))
	end
	local bytes = string.len(prefix) + string.len(message)

	if bytes == 0 then
		return
	end

	-- TODO: Add storage here.
end

-------------------------------------------------------------------------------
-- Tooltip and Databroker methods.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Hooked functions.
-------------------------------------------------------------------------------
function Spamalyzer:SendAddonMessage(prefix, message, type, target)
	if type == "WHISPER" and target and target ~= "" then
-- DEBUG		print(string.format("SendAddonMessage - %s", prefix))
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
		text	= DISPLAY_VALUES[db.datafeed.display],
		icon	= "Interface\\Icons\\INV_Letter_16",
	})
	self:RegisterEvent("CHAT_MSG_ADDON")
	self:SecureHook("SendAddonMessage")

	if LDBIcon then
		LDBIcon:Register(ADDON_NAME, data_obj, db.datafeed.minimap_icon)
	end
end

function Spamalyzer:OnDisable()
end

function Spamalyzer:CHAT_MSG_ADDON(event, prefix, message, channel, sender)
-- DEBUG	print(string.format("CHAT_MSG_ADDON - %s (%s)", prefix, sender))
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
									  data_obj.text = DISPLAY_VALUES[value]
								  end,
							values	= DISPLAY_VALUES,
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
							set	= function(info, value) db.tooltip.sorting = value end,
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
