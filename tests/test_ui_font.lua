------------------------------------------------------------
-- test_ui_font.lua - the window's text is drawn in LibGlass's font for the
-- client's language (#84).
--
-- LibGlass r12 picks FONTS.arial.file by GetLocale(): Arial Narrow has no
-- Hangul or Han, so on a Korean or Chinese client it names the file Blizzard
-- uses instead (LibGlass#69). A window that sets Arial Narrow itself draws
-- those names as empty boxes. The table is set here the way r12 fills it on
-- such a client, so the test does not depend on which LibGlass CI checks out
-- (tests/libglass-ref.txt).
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_ui_font.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()
WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "SPIRIT_SINGLE", "SHADOW_SINGLE" })
H.Party3()

local ARIAL = "Fonts\\ARIALN.TTF"
local GLASS = LibStub("LibGlass-1.0")
local arial = GLASS.FONTS.arial
local shipped = arial.file

-- Every font string a window drew, with the file it was given: the widgets
-- made while building it whose parent chain reaches its main frame or its
-- popover.
local function windowFonts(ui, from)
    local inside = {}
    if ui.main then inside[ui.main] = true end   -- a window that failed to build has neither
    if ui.pop then inside[ui.pop] = true end
    local list = {}
    for i = from + 1, #WoW.widgets do
        local w = WoW.widgets[i]
        if w._type == "FontString" then
            local p = w._parent
            while p and not inside[p] do p = p._parent end
            if p then list[#list + 1] = w end
        end
    end
    return list
end

-- Builds a window, fills it (so every row's text is set), and returns the
-- files its font strings were drawn in, as a set, and how many had none.
local function build(owner)
    local from = #WoW.widgets
    local host = H.PriestUI({ owner = owner })
    host.engine:RefreshSpells()
    local ok, err = pcall(function()
        host.ui:Open()
        host.ui:Update()
    end)
    H.check(ok, owner .. ": the window opens and fills without error: " .. tostring(err))
    local files, unset, count = {}, 0, 0
    for _, fs in ipairs(windowFonts(host.ui, from)) do
        count = count + 1
        if fs._font then files[fs._font[1]] = true else unset = unset + 1 end
    end
    H.check(count >= 10, owner .. ": the walk reached the window's text (" .. count .. " font strings)")
    return files, unset
end

local function only(files)
    local list = {}
    for f in pairs(files) do list[#list + 1] = f end
    table.sort(list)
    return table.concat(list, ",")
end

------------------------------------------------------------
-- The LibGlass this test runs against: its own Arial Narrow member
------------------------------------------------------------

local files, unset = build("FontDefault")
H.eq(only(files), shipped, "every string is drawn in LibGlass's arial file")
H.eq(unset, 0, "and none is left without a font")

------------------------------------------------------------
-- A Korean client, as LibGlass r12 fills the table there
------------------------------------------------------------

arial.file = "Fonts\\2002.TTF"
files, unset = build("FontKorean")
H.eq(only(files), "Fonts\\2002.TTF", "on koKR every string is drawn in 2002.TTF, not Arial Narrow")
H.eq(unset, 0, "with none left without a font")

------------------------------------------------------------
-- A file this client does not have: back to Arial Narrow
--
-- ARKai_C.ttf is LibGlass r12's zhCN arial, and on an English client SetFont
-- returns false for it and GetFont reads nil (porting guide, "A font file
-- draws one script", 70938). A font string left like that throws on SetText
-- (WowTestKit #69, 70959), so the window would fail to fill.
------------------------------------------------------------

local MISSING = "Fonts\\ARKai_C.ttf"
local kitSetFont = WoW.Methods.SetFont
WoW.Methods.SetFont = function(fs, file, ...)
    if file == MISSING then return false end
    return kitSetFont(fs, file, ...)
end
arial.file = MISSING
files, unset = build("FontMissing")
H.eq(only(files), ARIAL, "a file that does not load falls back to Arial Narrow")
H.eq(unset, 0, "so no string is left without a font")
WoW.Methods.SetFont = kitSetFont

------------------------------------------------------------
-- A LibGlass with no usable entry: Arial Narrow
------------------------------------------------------------

arial.file = ""
files, unset = build("FontEmpty")
H.eq(only(files), ARIAL, "an empty file name in LibGlass's table means Arial Narrow")
H.eq(unset, 0, "and every string still has a font")

arial.file = shipped
H.done("test_ui_font")
