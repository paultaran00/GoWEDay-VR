-- Menus with the controllers: a beam from each controller to the UI panel (drawn by our UEVR patch,
-- OverlayComponent.cpp, as overlays over the menu); a trigger clicks where it points. In the pause menu of a mission
-- and the main menu / mission select; not on the title ("hold X") and not in cutscenes. The mouse follows the pointer
-- (items light up under it; the game shows keyboard prompts meanwhile). Face buttons:
-- weapon.lua (Xbox layout).
local api = uevr.api
local vr = uevr.params.vr

local function log(m) pcall(function() uevr.params.functions.log_info("[menu] " .. tostring(m)) end) end

NUDGE_STICK = 11000 -- left stick x (~0.34): the gamepad counts as used again, under Slate's navigation threshold
local NUDGE_POLLS = 5

local statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local menu_on, click_r, click_l, was_click, nudge = false, false, false, false, 0
local sent = nil
local gamepad_nav, nav_anchor = false, nil
local scroll_y, scroll_t = 0, 0
HOVER_RESUME_M = 0.03 -- (meters the laser's end must move to take the hover back from the gamepad)
MENU_POINTER = false

local function in_pause_menu()
    if CINEMATIC and not VEHICLE then return false end -- (a turret / helicopter gun counts as cinematic, but its pause menu needs the lasers)
    local pc = api:get_player_controller(0)
    if pc == nil then return false end
    if api:get_local_pawn(0) == nil then
        -- front end: the main menu / mission select yes, the title ('hold X', camera pitched far down) no
        local vt = pc:GetViewTarget()
        local front = vt ~= nil and vt:get_class():get_fname():to_string():find("FrontendCam") ~= nil
        return front and pc.PlayerCameraManager:GetCameraRotation().x > -20
    end
    local ok, p = pcall(function() return statics:IsGamePaused(pc) end)
    return (ok and p == true) or MENU_UI_OPEN == true
end

-- Menus the game opens over play without pausing it: the supply cache (the Forge loadout scene). While one is up
-- MENU_UI_OPEN is true: everything treats it as the pause menu (weapon.lua: no game buttons / no aim, the UI fixed in
-- the room; here: the lasers). Looked for 5 times a second (none exist while closed).
MENU_UI_OPEN = false
MENU_UI_NAMES = { "UIScene_Forge" } -- (class name parts of such menus; matched by name among the live widgets:
                                    -- finding a class by path that is not loaded would scan every object, ~430 ms)
local wbl, uw_c, ui_check_t = nil, nil, 0
local function check_ui_menus(pc)
    -- only after the interact button (weapon.lua MENU_UI_PROBE_UNTIL: the supply cache opens with it) and while
    -- one is open (to see it close) - nothing is looked for during normal play
    if not MENU_UI_OPEN and os.clock() > (MENU_UI_PROBE_UNTIL or 0) then return end
    if os.clock() - ui_check_t < 0.2 then return end
    ui_check_t = os.clock()
    local open = false
    pcall(function()
        wbl = wbl or api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"):get_class_default_object()
        uw_c = uw_c or api:find_uobject("Class /Script/UMG.UserWidget")
        if pc == nil then return end
        local out = {}
        wbl:GetAllWidgetsOfClass(pc, out, uw_c, false) -- (~1100 widgets, ~2 ms: the scenes sit inside one root)
        for _, w in ipairs(out) do
            local n = w:get_class():get_fname():to_string()
            for _, part in ipairs(MENU_UI_NAMES) do
                if n:find(part, 1, true) and w:IsVisible() then open = true end
            end
        end
    end)
    if open ~= MENU_UI_OPEN then MENU_UI_OPEN = open log(open and "supply cache menu open" or "supply cache menu closed") end
end

uevr.sdk.callbacks.on_pre_engine_tick(function()
    pcall(check_ui_menus, api:get_player_controller(0))
    local on = false
    pcall(function() on = in_pause_menu() end)
    if on ~= menu_on then menu_on = on log(on and "pointer on" or "pointer off") if not on then nudge = NUDGE_POLLS end end -- (leaving the menu: back to gamepad prompts)
    if not on then click_r, click_l = false, false end
    MENU_POINTER = menu_on
    -- moving with the gamepad (d-pad / stick) stops the mouse following the laser until the laser itself moves
    -- HOVER_RESUME_M (hand jitter kept moving the mouse, and its hover took the selection back from the gamepad)
    if menu_on and gamepad_nav then
        pcall(function()
            local v = {}
            for x in vr:get_mod_value("VR_MenuPointerHit"):gmatch("%S+") do v[#v + 1] = tonumber(x) end
            local o = (v[3] == 1) and 13 or 7 -- end point of the active hand's beam
            local p = { v[o], v[o + 1], v[o + 2] }
            if nav_anchor == nil then nav_anchor = p
            elseif math.sqrt((p[1] - nav_anchor[1]) ^ 2 + (p[2] - nav_anchor[2]) ^ 2 + (p[3] - nav_anchor[3]) ^ 2) > HOVER_RESUME_M then
                gamepad_nav, nav_anchor = false, nil
            end
        end)
    end
    if not menu_on then gamepad_nav, nav_anchor = false, nil end
    -- "on click_right click_left wheel hover" - sent only when it changes (hover: the game then shows keyboard prompts)
    -- the right stick up/down scrolls (mouse wheel notches where the laser points, faster the further it is pushed)
    local notches = 0
    if menu_on and math.abs(scroll_y) > 0.35 then
        local now = os.clock()
        local every = 0.22 - 0.15 * math.min(1, (math.abs(scroll_y) - 0.35) / 0.6)
        if now - scroll_t > every then scroll_t, notches = now, (scroll_y > 0 and 1 or -1) end
    end
    local s = string.format("%d %d %d %d %d", menu_on and 1 or 0, click_r and 1 or 0, click_l and 1 or 0, notches, gamepad_nav and 0 or 1)
    if s ~= sent then sent = s pcall(vr.set_mod_value, "VR_MenuPointer", s) end
    MENU_SENT = s -- (debug: tools/dbg.sh)
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    local g = state.Gamepad
    if not menu_on then
        was_click, scroll_y = false, 0
        if nudge > 0 then nudge = nudge - 1 g.sThumbLX = NUDGE_STICK end
        return
    end
    -- (the beams are the physical controllers' - beam 0 the right one; left-handed, UEVR's swapped layout makes the
    -- game's left trigger the physical right one: its click belongs to beam 0)
    click_r = (EDAY_LEFTY and g.bLeftTrigger or g.bRightTrigger) > 128
    click_l = (EDAY_LEFTY and g.bRightTrigger or g.bLeftTrigger) > 128
    g.bLeftTrigger, g.bRightTrigger = 0, 0 -- (the triggers click; the game's RT opens the squad panel)
    -- (no stick nudge back to gamepad prompts: with the mouse following the pointer it made them flicker)
    scroll_y = g.sThumbRY / 32767
    g.sThumbRY = 0 -- (the right stick's up/down scrolls; not passed to the game too)
    local stick = math.max(math.abs(g.sThumbLX), math.abs(g.sThumbLY)) / 32767
    if (g.wButtons & 0x000F) ~= 0 or stick > 0.5 or MENU_SIM_NAV then MENU_SIM_NAV = nil gamepad_nav, nav_anchor = true, nil end -- (MENU_SIM_NAV: debug test)
end)

log("loaded")
