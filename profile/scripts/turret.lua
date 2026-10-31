-- Gears of War: E-Day VR - mounted guns on a stand in the ground (BP_TurretV2_Vulkan / _Troika / _HeavyBoomshot).
-- Marcus mans one with the game's interact (hold X). Then:
--   * like the helicopter's gun: the gun goes where the right controller points (VEHICLE_AIM, the ray fp.lua builds in
--     its view), One-Euro smoothed and speed / acceleration limited (a heavy gun); the game's control rotation is its aim;
--   * the trigger fires (the game's);
--   * both grips held AND both hands yanked up (TURRET_CFG.rip_up cm within rip_window s): the gun is torn off its
--     stand - the game's "Detach weapon" (Y) - and Marcus carries it (a held-only weapon, weapon.lua / gestures.lua);
--   * the game's prompts: "Detach weapon" shows LB + RB, the prompts sit at the lower right (fix_detach_prompt);
--   * B gets off it (the game's).
-- weapon.lua sets GROUND_TURRET and calls turret_ground_update every frame while on one; fp.lua puts the view at
-- Marcus' eyes behind it.
local api = uevr.api
local vr = uevr.params.vr
local function log(m) pcall(function() uevr.params.functions.log_info("[turret] " .. tostring(m)) end) end

TURRET_CFG = TURRET_CFG or {
    rip_up = 15,       -- cm both hands pulled up ...
    rip_window = 0.4,  -- ... within this many s: torn off (slower, it only tilts the gun)
    y_hold = 1.0,      -- s the game's Y is held for the detach (0.5 detached the Vulcan, not the Troika)
    prompt_x = 490,    -- the turret prompts (B get off, LB RB detach) moved from the middle of the view (UI px)
    prompt_y = 200,
    smooth_min_hz = 1.0, smooth_beta = 0.07, smooth_speed_hz = 3.0, -- aim One-Euro: Hz when still, + per deg/s
    aim_gain = 1.0,    -- sideways: the gun turns this much of the controller's turn (1 = as the helicopter's gun)
    max_yaw_speed = 125, max_pitch_speed = 95, slew_accel = 550, -- deg/s, deg/s, deg/s^2: a heavy mounted gun (70/50/250, then 100/75/400 was too slow)
    pitch_min = -60, pitch_max = 60, -- deg: what is asked of the gun (the game keeps its own limits too)
}
local C = TURRET_CFG

local ks = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
local names = {}
local function name(s) local n = names[s] if n == nil then n = ks:Conv_StringToName(s) names[s] = n end return n end

local function wrap(a) while a > 180 do a = a - 360 end while a < -180 do a = a + 360 end return a end

local st = { pawn = nil, ripped = false, y_until = 0, hist = {} }
TURRET_STATE = st -- (debug)

local function haptic(side, amp, secs)
    pcall(function()
        eday_haptic(0.0, secs or 0.05, 120, amp, side == "R" and vr.get_right_joystick_source() or vr.get_left_joystick_source())
    end)
end

local function gun_mesh(pawn)
    local inv = pawn.TurretInventoryComponent
    local item = inv and inv:GetEquippedInventoryItem()
    return item and item.RootComponent
end

-- The game's prompt "Y Detach weapon" shows the two grip buttons instead (the gun is torn off with both grips).
-- Its BP_UIWidget_TurretActions lists BP_UIWidget_ActionPrompt widgets; the one bound to IA_DetachTurret gets its key
-- icon set to LB and a second key widget RB next to it. Looked for a few times a second while on a stand (the game
-- builds the widget when the stand is manned); each widget changed once.
local prompt_t = 0
local RB_TEX_PATH = "/Game/Fairlight/Interface/Art/Icons/Controller/Xbox/T_UI_Controller_Xbox_RB.T_UI_Controller_Xbox_RB"
local function rb_texture()
    local tex = api:find_uobject("Texture2D " .. RB_TEX_PATH)
    if tex ~= nil then return tex end
    local ksys = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
    vr.set_mod_value("VR_LoadAssetRoot", "0") -- (no root set: the brush that gets the texture, in this same call, keeps it)
    local sp = ksys:MakeSoftObjectPath(RB_TEX_PATH)
    vr.set_mod_value("VR_LoadAsset", string.format("%x %x", sp:read_qword(0), sp:read_qword(8)))
    return api:find_uobject("Texture2D " .. RB_TEX_PATH)
end
local function fix_detach_prompt()
    if os.clock() - prompt_t < 0.3 then return end
    prompt_t = os.clock()
    local wbl = api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"):get_class_default_object()
    local pc = api:get_player_controller(0)
    local all = {}
    wbl:GetAllWidgetsOfClass(pc, all, api:find_uobject("Class /Script/UMG.UserWidget"), false)
    for _, w in ipairs(all) do
        if w:get_class():get_fname():to_string() == "BP_UIWidget_TurretActions_C" then
            -- (the B / LB RB prompts sat in the middle of the view: moved to the lower right)
            pcall(function()
                local t = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Vector2D"))
                t.X, t.Y = C.prompt_x, C.prompt_y
                w:SetRenderTranslation(t)
            end)
            local list = w.WidgetTree.RootWidget.WidgetTree.RootWidget
            for i = 0, list:GetChildrenCount() - 1 do
                local p = list:GetChildAt(i)
                local file = p.ActionFile and p.ActionFile:get_fname():to_string() or ""
                -- (done once: the KeyBox then has 3 children - ChordBox, the key, our RB; userdata keys are not stable)
                if file == "IA_DetachTurret" then
                    local aw = p.ActionWidget
                    local key = aw.BP_UtilWidget_Key
                    -- (the game re-applies Y to this key when the icons are refreshed - vrsettings.lua after a hand / mapping
                    -- change: LB is put back each time, the RB key is made once)
                    key:SetKeyFromName(name("Gamepad_LeftShoulder"))
                    key:OnKeyUpdated()
                    if aw.KeyBox:GetChildrenCount() <= 2 then
                        -- RB: the game's icon list maps Gamepad_RightShoulder to Esc, so its texture is set directly
                        local rb = wbl:Create(w, key:get_class(), pc)
                        aw.KeyBox:AddChild(rb)
                        rb:SetKeyFromName(name("Gamepad_LeftShoulder"))
                        rb:OnKeyUpdated()
                        local tex = rb_texture()
                        if tex ~= nil then rb.KeyIconImage:SetBrushFromTexture(tex, false) end
                        log("detach prompt: LB + RB")
                    end
                end
            end
        end
    end
end
-- ctx: { pawn, R = right hand (world cm), L = left hand, rgrip, lgrip }
function turret_ground_update(ctx)
    local pawn = ctx.pawn
    if st.pawn ~= pawn then
        st.pawn = pawn
        st.ripped, st.y_until, st.hist, st.center_yaw = false, 0, {}, nil
        st.stand = pawn:GetComponentByClass(api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")) -- (the stand's own mesh)
        log("on " .. pawn:get_class():get_fname():to_string())
    end
    if st.stand == nil then return end
    pcall(fix_detach_prompt)
    local g = gun_mesh(pawn)
    if g == nil then return end
    -- its laser, like a hand weapon's: the right stick press (weapon.lua) switches it, drawn from its muzzle
    if TURRET_LASER_REQUEST then
        TURRET_LASER_REQUEST = false
        if laser_toggle ~= nil then pcall(laser_toggle, g) end
    end
    if laser_update ~= nil then pcall(laser_update, g) end
    local hands = { R = ctx.R, L = ctx.L }
    local dev = rawget(_G, "TURRET_DEV_HANDS") -- (debug: world points instead of the controllers)
    if dev then hands = { R = dev.R or hands.R, L = dev.L or hands.L } end
    local grips = { R = ctx.rgrip, L = ctx.lgrip }
    local dg = rawget(_G, "TURRET_DEV_GRIPS")
    if dg then grips = { R = dg.R, L = dg.L } end

    -- (on the stand it works like the helicopter gun, plus the option to tear it off; an earlier version
    --  gripped the two rear handles and turned the gun with the hands)
    -- tear off: both grips held AND both hands yanked up (C.rip_up cm within C.rip_window s) = the game's 'Detach
    -- weapon' (prompt LB RB, fix_detach_prompt). Both grips alone are just holding the gun (holding
    -- both grips tore it off at once)
    local now = os.clock()
    local both = grips.R == true and grips.L == true and hands.R ~= nil and hands.L ~= nil
    if both then
        table.insert(st.hist, { t = now, r = hands.R.z, l = hands.L.z })
        while #st.hist > 0 and now - st.hist[1].t > C.rip_window do table.remove(st.hist, 1) end
        local lo_r, lo_l = math.huge, math.huge
        for _, h in ipairs(st.hist) do lo_r, lo_l = math.min(lo_r, h.r), math.min(lo_l, h.l) end
        if not st.ripped and hands.R.z - lo_r >= C.rip_up and hands.L.z - lo_l >= C.rip_up then
            st.ripped = true
            st.y_until = now + C.y_hold
            haptic("R", 1.0, 0.15) haptic("L", 1.0, 0.15)
            log(string.format("detach: both grips yanked up %.0f / %.0f cm", hands.R.z - lo_r, hands.L.z - lo_l))
        end
    else
        st.hist = {}
    end
    -- aim: like the helicopter gun - the gun goes where the right controller points (fp.lua's ray in the view it
    -- builds; the stand's control rotation is a world rotation)
    local a = VEHICLE_AIM
    if a == nil or not VEHICLE_AIM_FP or a.dir == nil then return end
    local d = a.dir
    -- the same as the helicopter's gun (a 0.6 gain felt off): sideways
    -- 1:1 with the controller, up and down TURRET_PITCH_GAIN times (weapon.lua: bending the wrist far down hurt)
    if st.center_yaw == nil then st.center_yaw = pawn:K2_GetActorRotation().Yaw end
    local want_yaw = st.center_yaw + wrap(math.deg(math.atan(d.y, d.x)) - st.center_yaw) * C.aim_gain
    local want_pitch = math.deg(math.asin(math.max(-1, math.min(1, d.z)))) * (TURRET_PITCH_GAIN or 1.5) + (TURRET_PITCH_OFFSET or 0)
    want_pitch = math.max(C.pitch_min, math.min(C.pitch_max, want_pitch))
    -- One-Euro smoothing of the aim, as weapon.lua does for hand-held weapons (this ray is the raw controller pose:
    -- measured 113 direction flips in 800 frames holding it - on a stand Marcus and the view turn with the gun, so
    -- every tremble shook the view). Slow: smoothed hard; fast: passes almost at once.
    local sm = st.aim_sm
    if sm == nil or now - sm.t > 0.25 then
        st.aim_sm = { t = now, yaw = want_yaw, pitch = want_pitch, speed = 0 }
    elseif now - sm.t > 1e-3 then
        local dt = now - sm.t
        local dy = wrap(want_yaw - sm.yaw)
        local sa = 1 / (1 + 1 / (2 * math.pi * C.smooth_speed_hz) / dt)
        local speed = sm.speed + (math.sqrt(dy * dy + (want_pitch - sm.pitch) ^ 2) / dt - sm.speed) * sa
        local hz = C.smooth_min_hz + C.smooth_beta * speed
        local a = 1 / (1 + 1 / (2 * math.pi * hz) / dt)
        st.aim_sm = { t = now, yaw = sm.yaw + dy * a, pitch = sm.pitch + (want_pitch - sm.pitch) * a, speed = speed }
    end
    want_yaw, want_pitch = st.aim_sm.yaw, st.aim_sm.pitch
    local da = rawget(_G, "TURRET_DEV_AIM") -- (debug: { yaw = deg from the stand's forward, pitch = deg } instead of the controller)
    if da then want_yaw, want_pitch = st.center_yaw + da.yaw, da.pitch end
    -- heavy gun (too fast felt unrealistic): the gun chases the wanted aim with
    -- a speed limit and an acceleration limit, and brakes so as to stop on the target (v <= sqrt(2 * accel * remaining))
    local sl = st.slew
    if sl == nil or now - sl.t > 0.25 then
        st.slew = { t = now, yaw = want_yaw, pitch = want_pitch, vy = 0, vp = 0 }
    elseif now - sl.t > 1e-3 then
        local dt = now - sl.t
        local function step(cur, target, vel, vmax)
            local r = target - cur
            local vdes = (r < 0 and -1 or 1) * math.min(vmax, math.sqrt(2 * C.slew_accel * math.abs(r)))
            local dv = C.slew_accel * dt
            vel = vel + math.max(-dv, math.min(dv, vdes - vel))
            local n = cur + vel * dt
            if (target - n) * r <= 0 then return target, 0 end -- reached / would pass it
            return n, vel
        end
        sl.yaw, sl.vy = step(sl.yaw, sl.yaw + wrap(want_yaw - sl.yaw), sl.vy, C.max_yaw_speed)
        sl.pitch, sl.vp = step(sl.pitch, want_pitch, sl.vp, C.max_pitch_speed)
        sl.t = now
    end
    want_yaw, want_pitch = st.slew.yaw, st.slew.pitch
    st.aim = { yaw = want_yaw, pitch = want_pitch }
    pcall(function()
        local pc = api:get_player_controller(0)
        local r = pc:GetControlRotation()
        local y = r.Yaw + wrap(want_yaw - r.Yaw) -- (continuous with the current yaw: no 360 jump)
        pc:SetControlRotation(Vector3d.new(want_pitch, y, 0))
    end)
end

-- weapon.lua's xinput hook, while on a ground turret: the game's Y for the detach
function TURRET_PAD(state)
    if os.clock() < (st.y_until or 0) then state.Gamepad.wButtons = state.Gamepad.wButtons | 0x8000 end
end

log("loaded")
