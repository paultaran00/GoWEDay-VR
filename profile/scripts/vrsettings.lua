-- VR SETTINGS: our own entry in the game's in-mission pause menu (above SETTINGS) that opens a panel with the mod's
-- options, and the snap turn. Safe by construction: no hooks, nothing of the game's own widgets is moved, hidden or
-- removed - only OUR widgets are ADDED: one button at the end of the primary button box (right above the secondary
-- box with SETTINGS) and one panel (vertical box) in the scene's canvas on the empty right half. The scene is rebuilt
-- by the game on every open, so they die with it; we build everything anew for each scene instance.
-- TEXT SAFETY: a label's FText is made ONCE per widget at build time (fresh Conv_NameToText, SetText at once on its own
-- widget) and never touched again (an earlier version cached FText bytes and reused them: use after free, "pure
-- virtual function called"). Values are not rewritten: one entry per value, the current one shown (SetVisibility on
-- our widgets only).
-- Clicks are polled: the laser click (menu.lua's MENU_SENT) over our hovered entry, the gamepad A (VRS_PAD, called from
-- weapon.lua's xinput callback) while our entry has the focus. Never calls SetGamePaused.
-- Settings: global VR_SETTINGS = { hand = "right"|"left", turn = "smooth"|"snap", snap = 30|45|90, pump = "manual"|"auto", map = { action = physical } }
-- (data/eday_vrsettings.lua). map: which physical button does which gameplay action (BUTTON MAPPING page, VRS_PAD).
local api = uevr.api
local vr = uevr.params.vr

local function log(m) pcall(function() uevr.params.functions.log_info("[vrsettings] " .. tostring(m)) end) end

-- settings, saved and loaded (UEVR Lua io: files in GoWEDay-Steam/data only; same pattern as arms.lua's holds) -------
local FILE = "eday_vrsettings.lua"
local DEFAULT_MAP = { interact = "lX", pause = "rB", eject = "rA", laser = "rS", sprint = "lS", gamey = "lY", cover = "none", tsprint = "lT" }
local function default_map() local m = {} for k, v in pairs(DEFAULT_MAP) do m[k] = v end return m end
VR_SETTINGS = { hand = "right", turn = "smooth", snap = 30, pump = "manual", map = default_map() }
local SNAP_ANGLES = { 30, 45, 90 }
-- physical buttons (names of the Quest controllers) and the XInput bits UEVR sends for them (VR.cpp: right A = A,
-- left X = B, right B = X, left Y = Y, stick presses = LEFT / RIGHT_THUMB); gameplay actions and the bit each is
-- handled on in weapon.lua's callback (the defaults' bits)
local PHYS = { { "lX", "LEFT X", 0x2000 }, { "lY", "LEFT Y", 0x8000 }, { "rA", "RIGHT A", 0x1000 }, { "rB", "RIGHT B", 0x4000 },
               { "lS", "LEFT STICK PRESS", 0x0040 }, { "rS", "RIGHT STICK PRESS", 0x0080 },
               { "lT", "LEFT TRIGGER", 0 }, -- (analog: down past half; its bit is 0, see pr())
               { "none", "NONE", 0 } } -- (NONE: no button; the action stays unassigned)
local PHYS_BIT, PHYS_NAME = {}, {}
for _, ph in ipairs(PHYS) do PHYS_BIT[ph[1]], PHYS_NAME[ph[1]] = ph[3], ph[2] end
PHYS_NAME.rT = "RIGHT TRIGGER" -- (label only: the left-handed name of lT)
local ACT_BIT = { interact = 0x2000, pause = 0x4000, eject = 0x1000, laser = 0x0080, sprint = 0x0040, gamey = 0x8000, cover = 0, tsprint = 0 }
-- (gamey = the game's Y: jump / mantle / climb, measured: Marcus rises 54 cm; control scheme screen)
local ACTIONS = { -- (the rows of the mapping page, in order)
    { "interact", "INTERACT" }, { "pause", "PAUSE MENU" }, { "eject", "DROP MAGAZINE" }, { "laser", "LASER ON/OFF" },
    { "sprint", "DASH" }, { "gamey", "JUMP" }, { "cover", "COVER (GAME)" }, { "tsprint", "SPRINT (HOLD)" } } -- (sprint = the game's dash / roadie run: weapon.lua SPRINTING)
-- UEVR's VR_SwapControllerInputs (LEFT) mirrors the buttons: the physical button that makes a role's bit is the other hand's
-- twin (the map is stored by role = bit, so a RIGHT mapping carries over mirrored): the labels name the PHYSICAL button
local MIRROR = { lX = "rA", rA = "lX", lY = "rB", rB = "lY", lS = "rS", rS = "lS", lT = "rT", none = "none" }
local SIX = 0xF0C0 -- the six remappable bits
local map_default = true
-- click-to-listen (BUTTON MAPPING): listen = { act, t0, armed } while a row waits for the next input. VRS_PAD hides the six
-- buttons from the game meanwhile (six_held = what is down; swallow = until they are let go) and publishes them for tick()
local LISTEN_TIMEOUT = 10.0
local listen, swallow, six_held, lt_raw, lt_swallow = nil, false, 0, false, false
local function check_map_default()
    map_default = true
    for k, v in pairs(DEFAULT_MAP) do if VR_SETTINGS.map[k] ~= v then map_default = false end end
end
-- act takes button ph; the action that had ph takes act's old button (swap; NONE swaps with nobody). Any action may be NONE
-- (the game's pause still works from the keyboard's Esc and a real pad's Start)
local function assign(map, act, ph)
    local old = map[act]
    if ph ~= "none" then
        for other, p in pairs(map) do
            if p == ph and other ~= act then map[other] = old end
        end
    end
    map[act] = ph
    return true
end
VRS_ASSIGN = function(act, ph) local r = assign(VR_SETTINGS.map, act, ph) check_map_default() return r end -- (debug: tools/dbg.sh)
local function vrs_save()
    local f = io.open(FILE, "w")
    if f then
        local m = {}
        for _, a in ipairs(ACTIONS) do m[#m + 1] = string.format("%s = %q", a[1], VR_SETTINGS.map[a[1]]) end
        f:write(string.format("return { hand = %q, turn = %q, snap = %d, pump = %q, map = { %s } }\n", VR_SETTINGS.hand, VR_SETTINGS.turn, VR_SETTINGS.snap, VR_SETTINGS.pump, table.concat(m, ", ")))
        f:close()
    end
end
pcall(function()
    local f = io.open(FILE, "r")
    if not f then return end
    local src = f:read("*a") f:close()
    local ok, t = pcall(load(src))
    if not ok or type(t) ~= "table" then return end
    if t.hand == "right" or t.hand == "left" then VR_SETTINGS.hand = t.hand end
    if t.turn == "smooth" or t.turn == "snap" then VR_SETTINGS.turn = t.turn end
    for _, a in ipairs(SNAP_ANGLES) do if t.snap == a then VR_SETTINGS.snap = a end end
    if t.pump == "manual" or t.pump == "auto" then VR_SETTINGS.pump = t.pump end
    if type(t.map) == "table" then -- (valid only whole: every action one known button, no button twice)
        local used, ok_map = {}, true
        for act in pairs(DEFAULT_MAP) do
            local ph = t.map[act]
            if ph == nil and (act == "cover" or act == "tsprint") then ph = DEFAULT_MAP[act] end -- (older files: today's controls)
            if PHYS_BIT[ph] == nil or (used[ph] and ph ~= "none") then ok_map = false break end -- (NONE may repeat)
            used[ph] = true
        end
        if ok_map then for act in pairs(DEFAULT_MAP) do VR_SETTINGS.map[act] = t.map[act] or DEFAULT_MAP[act] end end
    end
    log(string.format("loaded: hand %s, turn %s, snap %d", VR_SETTINGS.hand, VR_SETTINGS.turn, VR_SETTINGS.snap))
end)
check_map_default()
if eday_set_hand ~= nil then eday_set_hand(VR_SETTINGS.hand == "left") end -- (aa_xr.lua: the controllers' roles and the mirrored constants)

-- snap turn --------------------------------------------------------------------------------------------------------
-- VRS_PAD(state): called by weapon.lua right after DEBUG_PAD. With TURNING = SNAP the right stick's X is taken away from
-- the game (zeroed) and a push past SNAP_PUSH turns the view by the angle once; it must go back under SNAP_REARM first.
local SNAP_PUSH, SNAP_REARM = 0.6, 0.3
local snap_armed, snap_dir = false, 0
local a_was, a_edge = false, false
local pause_held_bit = 0
-- is the physical button ph down (w = the pad's buttons, lt = the left trigger is down)
local function pr(ph, w, lt)
    if ph == "lT" then return lt end
    return (w & PHYS_BIT[ph]) ~= 0
end
function VRS_PAD(state)
    local g = state.Gamepad
    if listen ~= nil or swallow then -- (an input is being chosen: the game, the menu, does not get the six buttons)
        six_held, lt_raw = g.wButtons & SIX, g.bLeftTrigger > 128
        swallow = listen ~= nil or six_held ~= 0
        g.wButtons = g.wButtons & ~SIX
    else
        six_held, lt_raw = 0, false
    end
    TSPRINT_PAD = nil -- (nil: weapon.lua reads the left trigger itself; set below when the map is not the default)
    local a = (g.wButtons & 0x1000) ~= 0
    COVER_PAD = false -- (the button mapped to COVER (GAME): weapon.lua sends the game's A while it is down)
    if a and not a_was then a_edge = true end
    a_was = a
    -- button mapping: in gameplay (and on a turret) the six physical bits are turned into the bits of the actions they
    -- are mapped to, i.e. the layout weapon.lua's callback is written for (the defaults: nothing changes). Menus,
    -- cutscenes: the physical layout as it is.
    if (not map_default or VRS_MAP_FORCE) and not VRS_MAP_OFF then -- (VRS_MAP_FORCE / _OFF: debug, tools/dbg.sh)
        local w = g.wButtons
        if EDAY_IN_GAMEPLAY or VEHICLE then
            local out = w & ~SIX
            -- (the left trigger as a button; the grenade in the left hand owns it: grenade.lua arms it with the trigger)
            local lt = g.bLeftTrigger > 128 and not (grenade_hand_side ~= nil and grenade_hand_side() == "L")
            local map = VR_SETTINGS.map
            for act, ph in pairs(map) do
                if pr(ph, w, lt) then out = out | ACT_BIT[act] end
            end
            TSPRINT_PAD = pr(map.tsprint, w, lt) -- (a hold: true for as long as the button is down)
            -- the button that opened the pause menu is held on: it must not act in the menu until let go (right B has
            -- that protection in weapon.lua already)
            if (out & 0x4000) ~= 0 and VR_SETTINGS.map.pause ~= "rB" then pause_held_bit = PHYS_BIT[VR_SETTINGS.map.pause] end
            COVER_PAD = pr(map.cover, w, lt)
            g.wButtons = out
        elseif pause_held_bit ~= 0 then
            if (w & pause_held_bit) ~= 0 then g.wButtons = w & ~pause_held_bit else pause_held_bit = 0 end
        end
    end
    if VR_SETTINGS.turn ~= "snap" or not EDAY_IN_GAMEPLAY or CINEMATIC or VEHICLE then snap_armed = false return end
    local x = g.sThumbRX / 32767
    g.sThumbRX = 0
    if math.abs(x) < SNAP_REARM then snap_armed = true
    elseif snap_armed and math.abs(x) > SNAP_PUSH then snap_dir, snap_armed = (x > 0) and 1 or -1, false end
end

local function apply_snap(pc)
    if snap_dir == 0 then return end
    local d = snap_dir * VR_SETTINGS.snap
    snap_dir = 0
    if not EDAY_IN_GAMEPLAY or CINEMATIC or VEHICLE then return end
    if saw_yaw ~= nil then saw_yaw = saw_yaw + d return end -- (chainsaw running: weapon.lua holds the yaw and writes it)
    local r = pc:GetControlRotation()
    local y = r.Yaw + d
    if y > 180 then y = y - 360 elseif y <= -180 then y = y + 360 end
    pc:SetControlRotation(Vector3d.new(r.Pitch, y, r.Roll))
end

-- the panel: option -> values (label, setting value); one entry per value ----------------------------------------------
local OPTIONS = {
    { key = "hand", values = { { "PRIMARY HAND: RIGHT", "right" }, { "PRIMARY HAND: LEFT (BETA)", "left" } } },
    { key = "turn", values = { { "TURNING: SMOOTH", "smooth" }, { "TURNING: SNAP", "snap" } } },
    { key = "snap", values = { { "SNAP ANGLE: 30", 30 }, { "SNAP ANGLE: 45", 45 }, { "SNAP ANGLE: 90", 90 } } },
    { key = "pump", values = { { "SHOTGUN PUMP: MANUAL", "manual" }, { "SHOTGUN PUMP: AUTO", "auto" } } },
}
local PANEL_X, PANEL_Y = 980, 300 -- (canvas units: the 1920x1080 UI; the empty right half under the chapter header)

-- native-looking widgets -------------------------------------------------------------------------------------------
local statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local wbl = api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"):get_class_default_object()
local uw_c = api:find_uobject("Class /Script/UMG.UserWidget")
local vbox_c = api:find_uobject("Class /Script/UMG.VerticalBox")
local kt_c = api:find_uobject("Class /Script/Engine.KismetTextLibrary")
local kt = kt_c:get_class_default_object()
local ks_sys = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
local ks = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
local f_name2text = kt_c:find_function("Conv_NameToText")
local f_settext = api:find_uobject("Class /Script/UMG.RichTextBlock"):find_function("SetText")
-- (the param buffers of every label are kept for good: never freed or overwritten, so the FText in them keeps its
-- reference for as long as the game runs; a few bytes per label per menu opening)
local KEEP = {}

-- UEVR Lua skips FText: Conv_NameToText through ProcessEvent (virtual 77), its 16 bytes copied into RichText SetText's
-- params. Once per label, at build time, on a fresh buffer; the widget takes its own reference with SetText.
local function set_text_once(item, label)
    local p1 = StructObject.new(f_name2text)
    local p2 = StructObject.new(f_settext)
    KEEP[#KEEP + 1] = p1
    KEEP[#KEEP + 1] = p2
    p1.InName = ks:Conv_StringToName(label)
    kt:DANGEROUS_call_member_virtual(77, f_name2text, p1)
    p2:write_qword(0, p1:read_qword(8))
    p2:write_qword(8, p1:read_qword(16))
    item.PauseTextButton_RichText:DANGEROUS_call_member_virtual(77, f_settext, p2)
end

-- one entry: a generic button with a pause-menu item in its content (big = the primary look, else the secondary one)
local function make_entry(pc, parent, bc, ic, label, big)
    local btn = wbl:Create(pc, bc, pc)
    local item = wbl:Create(pc, ic, pc)
    parent:AddChild(btn)
    btn:SetStyleWidgetClass(nil) -- (else a grey default style box; it also resets the item's text, so before the text)
    btn:SetContent(item)
    item.SetDefaultFont = big
    item:PreConstruct(false)
    set_text_once(item, label)
    return { btn = btn, item = item }
end

local ui = nil          -- the entries of the pause menu scene that is open (see build)
local pause_class = nil -- BP_UIScene_PauseMenu_C (found once among the widgets, then used as a filter)
local last_poll, was_click, click_at = 0, false, nil
local space_key, space_was = nil, false
local mouse_was, fired_at, mouse_key = false, -9, nil -- (a real mouse click; fired_at = one press = one activation)
local FULL_SCAN_EVERY = 1.0

local world_sig = nil
local function world_of(o) -- (the World among o's outers; its address)
    for _ = 1, 6 do
        if o == nil then return 0 end
        if o:get_class():get_fname():to_string() == "World" then return o:get_address() end
        o = o:get_outer()
    end
    return 0
end
local function valid(o) return o ~= nil and ks_sys:IsValid(o) end

local function find_scene(pc)
    if pause_class ~= nil and not valid(pause_class) then pause_class = nil end
    local out = {}
    -- (a hidden leftover instance can exist next to the open one: the visible one counts)
    wbl:GetAllWidgetsOfClass(pc, out, pause_class or uw_c, false)
    for _, w in ipairs(out) do
        if pause_class ~= nil or w:get_class():get_fname():to_string() == "BP_UIScene_PauseMenu_C" then
            pause_class = w:get_class()
            if w:IsVisible() then return w end
        end
    end
    return nil
end

-- the panel has two pages (vertical boxes in the same place): main and the button mapping page; one is shown
local function show_page()
    ui.main_panel:SetVisibility((ui.open and ui.page == "main") and 0 or 1) -- (0 Visible, 1 Collapsed: OUR widgets only)
    ui.map_panel:SetVisibility((ui.open and ui.page == "map") and 0 or 1)
end

local function set_panel(on)
    ui.open = on
    if on then ui.page = "main" end
    show_page()
end

-- shows the entry of the current value of an option, hides the others
local function show_value(opt)
    for _, e in ipairs(opt.entries) do e.btn:SetVisibility(VR_SETTINGS[opt.key] == e.value and 0 or 1) end
end
-- the same for the mapping rows: of each action the entry of the button it is on
local function show_map()
    local hand = VR_SETTINGS.hand
    local la = listen and listen.act
    for _, row in ipairs(ui.map_rows) do
        for _, e in ipairs(row) do e.btn:SetVisibility((VR_SETTINGS.map[e.action] == e.phys and e.hand == hand and la ~= e.action) and 0 or 1) end
    end
    if ui.listen_rows then
        for act, e in pairs(ui.listen_rows) do e.btn:SetVisibility(act == la and 0 or 1) end
    end
end

local function build(pc, scene)
    local sec = scene.SecondaryButtonsTCVerticalBox
    local ml = sec:GetParent()
    local box = ml:GetChildAt(0):GetChildAt(0)
    assert(ml:get_fname():to_string() == "MenuList_VerticalBox" and box:get_fname():to_string() == "PrimaryButtonsTCVerticalBox", "unexpected pause menu tree")
    -- the canvas of the scene: up the tree from the menu list
    local canvas = ml
    for _ = 1, 8 do
        canvas = canvas:GetParent()
        if canvas == nil or canvas:get_fname():to_string() == "CanvasPanel_0" then break end
    end
    assert(canvas ~= nil and canvas:get_fname():to_string() == "CanvasPanel_0", "no CanvasPanel_0")
    local bc = scene.SettingsButton:get_class()
    local ic = scene.SettingsButton.ButtonContentWidget:get_class()
    local name = scene:get_full_name()
    ui = { scene = name, dead = true } -- (a failed build must not run again for this scene)
    -- (our entries of an earlier Lua state - a script reload with the menu open - are still in the box: put away)
    for i = 0, box:GetChildrenCount() - 1 do
        local c = box:GetChildAt(i)
        if c:get_fname():to_string():find("^BP_UtilWidget_GenericButton_C_") then c:SetVisibility(1) end
    end
    -- (same for a panel of ours: a vertical box with a generated name, not the scene's own VerticalBox_0 / _1)
    for i = 0, canvas:GetChildrenCount() - 1 do
        local c = canvas:GetChildAt(i)
        if c:get_fname():to_string():find("^VerticalBox_%d%d%d%d%d") then c:SetVisibility(1) end
    end
    local u = { scene = name, open = false, page = "main", opts = {}, map_rows = {}, entries = { main = {}, map = {} } }
    u.main = make_entry(pc, box, bc, ic, "VR SETTINGS", true)
    local function new_panel()
        local panel = api:spawn_object(vbox_c, scene.WidgetTree)
        assert(panel ~= nil, "no vertical box")
        local slot = canvas:AddChildToCanvas(panel)
        slot:SetAutoSize(true)
        local pos = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Vector2D"))
        pos.X, pos.Y = PANEL_X, PANEL_Y
        slot:SetPosition(pos)
        panel:SetVisibility(1)
        return panel
    end
    local function add(page, panel, label, kind)
        local e = make_entry(pc, panel, bc, ic, label, true)
        e.kind = kind
        if kind ~= "title" then table.insert(u.entries[page], e) else e.btn:SetVisibility(3) end -- (HitTestInvisible: a heading, no hover)
        return e
    end
    -- main page
    u.main_panel = new_panel()
    add("main", u.main_panel, "VR SETTINGS", "title")
    for i, o in ipairs(OPTIONS) do
        local opt = { key = o.key, entries = {} }
        for j, v in ipairs(o.values) do
            local e = add("main", u.main_panel, v[1], "value")
            e.value, e.opt = v[2], opt
            opt.entries[j] = e
        end
        show_value(opt)
        u.opts[i] = opt
    end
    u.mapping = add("main", u.main_panel, "BUTTON MAPPING", "mapping")
    u.back = add("main", u.main_panel, "BACK", "back")
    -- mapping page: one entry per (action, button), the one of the current button shown
    u.map_panel = new_panel()
    add("map", u.map_panel, "BUTTON MAPPING", "title")
    for i, a in ipairs(ACTIONS) do
        u.map_rows[i] = {}
        -- (both label sets are built, once each; the one of the current hand is shown)
        for h, hand in ipairs({ "right", "left" }) do
            for j, ph in ipairs(PHYS) do
                local shown = (hand == "left") and PHYS_NAME[MIRROR[ph[1]]] or ph[2]
                local e = add("map", u.map_panel, a[2] .. ": " .. shown, "map")
                e.action, e.phys, e.hand = a[1], ph[1], hand
                u.map_rows[i][(h - 1) * #PHYS + j] = e
            end
        end
    end
    -- (the row of an action that waits for an input: shown instead of its value)
    u.listen_rows = {}
    for _, a in ipairs(ACTIONS) do
        local e = add("map", u.map_panel, a[2] .. ": WAITING FOR INPUT...", "map")
        e.action, e.phys = a[1], "listen"
        u.listen_rows[a[1]] = e
    end
    u.scene_obj = scene
    ui = u
    show_map()
    add("map", u.map_panel, "PRESS SPACE FOR NONE", "title")
    u.reset = add("map", u.map_panel, "RESET TO DEFAULTS", "reset")
    u.map_back = add("map", u.map_panel, "BACK", "map_back")
    log("built in " .. u.scene)
end

local function stop_listen(why)
    if listen == nil then return end
    listen = nil
    swallow, lt_swallow = true, true -- (what is still held does not act, nor click, until it is let go)
    if ui ~= nil and not ui.dead then show_map() end
    if why then log("listen " .. why) end
end
local function start_listen(act)
    listen = { act = act, t0 = os.clock(), armed = false }
    swallow = true
    show_map()
    log("listening: " .. act)
end
-- the action takes the button (or NONE) and the listening ends
local function commit(act, ph)
    assign(VR_SETTINGS.map, act, ph)
    check_map_default()
    stop_listen()
    show_map()
    vrs_save()
    log("map " .. act .. " -> " .. ph)
end
local function set_none(act) commit(act, "none") end -- (SPACE)
VRS_NONE = function(act) set_none(act) end -- (debug: tools/dbg.sh)

local function activate(e)
    local kind = e.kind
    if kind ~= "map" and listen ~= nil then stop_listen("cancelled") end
    if e == ui.main then
        set_panel(not ui.open)
    elseif kind == "back" then
        set_panel(false)
    elseif kind == "mapping" then
        ui.page = "map" show_page()
    elseif kind == "map_back" then
        ui.page = "main" show_page()
    elseif kind == "value" then
        local opt = e.opt
        for j, x in ipairs(opt.entries) do
            if x == e then
                VR_SETTINGS[opt.key] = opt.entries[j % #opt.entries + 1].value
                break
            end
        end
        show_value(opt)
        if opt.key == "hand" and eday_set_hand ~= nil then eday_set_hand(VR_SETTINGS.hand == "left") show_map() end
        vrs_save()
        log(string.format("hand %s, turn %s, snap %d", VR_SETTINGS.hand, VR_SETTINGS.turn, VR_SETTINGS.snap))
    elseif kind == "map" then
        -- click = listen for the next input (the same row again cancels; another row switches)
        if listen ~= nil and listen.act == e.action then stop_listen("cancelled") else start_listen(e.action) end
    elseif kind == "reset" then
        VR_SETTINGS.map = default_map()
        check_map_default()
        show_map()
        vrs_save()
        log("map reset")
    end
end

-- which of our entries: hovered (laser), or with the keyboard / gamepad focus; of the shown page only
local function pick(laser)
    local function on(e) if laser then return e.btn:IsHovered() end return e.btn:HasAnyUserFocus() or e.btn:HasFocusedDescendants() end
    if on(ui.main) then return ui.main end
    if ui.open then
        for _, e in ipairs(ui.entries[ui.page]) do if on(e) then return e end end
    end
    return nil
end

-- (No key icon remapping: an earlier version rewrote the game's DA_KeyIcons rows and force-loaded the glyphs with the
-- root set flag; shared game data / rooted objects were the suspects of the garbled UI texts. Prompts show the game's own
-- Xbox icons; under LEFT or a custom mapping they name the game's key, not the physical button.)

local function tick()
    local pc = api:get_player_controller(0)
    if pc == nil or api:get_local_pawn(0) == nil then ui, pause_class, world_sig, a_edge, click_at = nil, nil, nil, false, nil return end
    -- a new pawn or world (leaving a mission, a checkpoint, a turret): every cached game object is forgotten
    local sig = tostring(pc:get_address()) .. "/" .. tostring(world_of(pc))
    if sig ~= world_sig then
        world_sig = sig
        ui, pause_class, a_edge, was_click, click_at, mouse_was = nil, nil, false, false, nil, false
    end
    local paused_now = statics:IsGamePaused(pc)
    if not paused_now then
        -- (not paused: the menu is gone - drop our references without touching them)
        if ui ~= nil then ui = nil log("menu closed") end
        a_edge, was_click, click_at, mouse_was = false, false, nil, false
        apply_snap(pc)
        return
    end
    if ui ~= nil and not valid(ui.scene_obj) then ui = nil end -- (the scene died under us: nothing of it is touched)
    local now = os.clock()
    if now - last_poll > (pause_class ~= nil and 0.25 or FULL_SCAN_EVERY) then
        last_poll = now
        -- (not in a vehicle's pause menu - helicopter, gun stand: its settings change nothing there, and on the
        -- helicopter the game's buttons could not be read)
        local scene = (VEHICLE ~= true) and find_scene(pc) or nil
        if scene == nil then
            ui = nil
        elseif ui == nil or ui.scene ~= scene:get_full_name() then
            ui = nil
            local ok, err = pcall(build, pc, scene)
            if not ok then log("build failed: " .. tostring(err)) end
        end
    end
    if ui == nil or ui.dead then a_edge, listen = false, nil return end
    -- a row listens: the first mappable input pressed after everything was let go is its button (the left trigger is read
    -- from menu.lua's click state, which zeroes it)
    local lt_c, rt_c = false, false
    do
        local on, cr, cl = (MENU_SENT or ""):match("^(%d) (%d) (%d)")
        if on == "1" then lt_c, rt_c = (EDAY_LEFTY and cr or cl) == "1", (EDAY_LEFTY and cl or cr) == "1" end
    end
    if lt_swallow and not lt_c and not lt_raw then lt_swallow = false end
    if listen ~= nil then
        if not ui.open or ui.page ~= "map" then stop_listen("cancelled")
        elseif now - listen.t0 > LISTEN_TIMEOUT then stop_listen("timed out")
        else
            local ltd = lt_c or lt_raw
            if not listen.armed then
                if six_held == 0 and not ltd then listen.armed = true end
            else
                local got
                for _, ph in ipairs(PHYS) do
                    if PHYS_BIT[ph[1]] ~= 0 and (six_held & PHYS_BIT[ph[1]]) ~= 0 then got = ph[1] break end
                end
                if got == nil and ltd then got = "lT" end
                if got ~= nil then commit(listen.act, got) end
            end
        end
    end
    -- laser click edge (menu.lua sends "on click_r click_l ...")
    local click = false
    local s = MENU_SENT
    if s ~= nil then local on, cr, cl = s:match("^(%d) (%d) (%d)") 
        -- (the support hand's trigger is a mappable input: it does not click while a row listens)
        click = on == "1" and ((EDAY_LEFTY and cl or cr) == "1" or ((EDAY_LEFTY and cr or cl) == "1" and listen == nil and not lt_swallow)) end
    local edge = click and not was_click
    was_click = click
    if VRS_SIM_CLICK then VRS_SIM_CLICK, edge = nil, true end -- (debug: tools/dbg.sh; a simulated pad does not reach menu.lua)
    -- the click's mouse event reaches Slate a frame or two later: the hover is looked for for a moment after the edge
    if edge then click_at = now end
    local which = nil
    if click_at ~= nil then
        which = pick(true)
        if which ~= nil or now - click_at > 0.25 then click_at = nil end
    end
    if a_edge then a_edge = false which = which or pick(false) end
    -- a real mouse click (PlayerInput still sees it while paused): same hover window as the laser click. The laser's own
    -- SendInput click arrives here too, so any activation locks both sources out for a moment (one press = one activation).
    mouse_key = mouse_key or { KeyName = ks:Conv_StringToName("LeftMouseButton") }
    local m = pc:IsInputKeyDown(mouse_key)
    if m and not mouse_was then click_at = click_at or now end
    mouse_was = m
    if which == nil and click_at ~= nil then
        which = pick(true)
        if which ~= nil or now - click_at > 0.25 then click_at = nil end
    end
    space_key = space_key or { KeyName = ks:Conv_StringToName("SpaceBar") }
    local sp = pc:IsInputKeyDown(space_key)
    if (sp and not space_was) or VRS_SIM_SPACE then
        local e = ui.open and ui.page == "map" and (pick(true) or pick(false)) or nil
        if listen ~= nil and ui.open and ui.page == "map" then fired_at = now which = nil click_at = nil set_none(listen.act) e = nil end -- (listening: SPACE = NONE)
        if VRS_SIM_SPACE then e = VRS_SIM_SPACE VRS_SIM_SPACE = nil end -- (debug: an entry; the real key needs the keyboard)
        if e ~= nil and e.kind == "map" then fired_at = now which = nil click_at = nil set_none(e.action) end
    end
    space_was = sp
    if which ~= nil and now - fired_at < 0.4 then which = nil click_at = nil end
    if which ~= nil then fired_at = now activate(which) end
end

uevr.sdk.callbacks.on_pre_engine_tick(function()
    local ok, err = pcall(tick)
    if not ok then
        vrs_errors = (vrs_errors or 0) + 1
        if vrs_errors % 300 == 1 then log("tick: " .. tostring(err)) end
    end
end)

VRS_MAP_CHECK = check_map_default -- (debug: after a map change from dbg)
VRS_SAVE = vrs_save -- (debug)
VRS_ACTIVATE = activate -- (debug)
VRS_LISTEN = function() return listen end -- (debug)
VRS_STATE = function() return ui end -- (debug: tools/dbg.sh)
log("loaded")
