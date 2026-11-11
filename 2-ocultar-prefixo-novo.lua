-- KOReader: remove only the "NEW: " / "NOVO: " prefix from menu entries.
-- Keep orphan/new menu entries visible and their current automatic placement.
-- Does not change the user's menu order or alter plugin settings.
local MenuSorter = require("ui/menusorter")
MenuSorter.orphaned_prefix = ""
