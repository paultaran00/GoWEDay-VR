-- Gears of War: E-Day first person: put the VR camera between Marcus' eyes and hide his head/hair.
local api = uevr.api

-- Engine functions looked up by name once, then called directly: a method call looks the function up by name
-- every time (measured: 24 us per call by name, 10.5 us with the function kept).
local ucache = {}
local function ucall(obj, name, ...)
    local f = ucache[name]
    if f == nil then f = obj[name] ucache[name] = f end
    return f(obj, ...)
end

local function log(msg)
    pcall(function() uevr.params.functions.log_info("[fp] " .. tostring(msg)) end)
end

local kismet_string = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
local skeletal_mesh_c = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
local groom_c = api:find_uobject("Class /Script/HairStrandsCore.GroomComponent")

local name_eye_l = ucall(kismet_string, "Conv_StringToName", "fc_eye_L")
local name_eye_r = ucall(kismet_string, "Conv_StringToName", "fc_eye_R")

-- Head plus the armour pieces that block the view when looking down/sideways from inside Marcus' bulk.
local hidden_bones = {
    "b_head",
    "sc_shoulderpad_L", "sc_shoulderpad_R",
    "sc_collar_RF", "sc_collar_R", "sc_collar_RB", "sc_collar_LF", "sc_collar_L", "sc_collar_LB",
}

-- Camera pushed this many cm ahead of the capsule centre (horizontally, along the body). Tune here.
local FORWARD_OFFSET_CM = 0.0
-- Eye height above the capsule, low-pass filtered: follows crouching / cover, but not the head bobbing of the walk
-- animation (that would move the camera, and the weapon in the hands with it).
local EYE_HEIGHT_TAU = 0.5 -- seconds; higher = steadier, but slower to follow crouch / cover
local smoothed_rel_z, last_clock = nil, nil

-- Walk where the head looks. MovementOrientation only rotates gamepad stick input, so also let the head drive
-- the player's control rotation (that is what W / the stick move along). AimMethod: 0 = game, 1 = head, 2/3 = right/left controller.
-- Step 1 of the VR controls: aim with the right controller, walk where the head looks (Quest sticks act as a gamepad).
uevr.params.vr.set_mod_value("VR_MovementOrientation", "1")
-- the game's aim follows the HEAD (1), not the right controller (2): its camera, and with it everything the game
-- places on screen from the world (the "Open Door" prompt, locators), followed the gun hand and slid around. Shots do
-- not need it: weapon.lua writes the weapon's targeting caches from the barrel itself (fire_from_hands).
AIM_METHOD_PLAY = "1"
uevr.params.vr.set_mod_value("VR_AimMethod", AIM_METHOD_PLAY)
uevr.params.vr.set_mod_value("VR_AimModifyPlayerControlRotation", "true")

-- The camera sits exactly at the eyes; UEVR's own camera offsets would push it out of the head
-- (they get changed by accident when the UEVR menu opens and the sticks move). Force them back to 0.
uevr.params.vr.set_mod_value("VR_CameraForwardOffset", "0.0")
uevr.params.vr.set_mod_value("VR_CameraRightOffset", "0.0")
uevr.params.vr.set_mod_value("VR_CameraUpOffset", "0.0")

-- No D-pad shifting: with it (method 0) the right thumb resting on the thumbrest - holding the weapon - turned the
-- left stick into the D-pad: no walking, and stick up switched to the grenade. The mod uses no D-pad.
uevr.params.vr.set_mod_value("VR_DPadShifting", "false")
-- the monitor picture steadied against headset tracking noise (our UEVR patch, eday_stab; the headset is untouched).
-- Measured: monitor jitter 4.0-4.5 -> 1.5-1.8 px per grab. "off" = as before. Max correction
-- 0.6 deg (the noise is ~0.3) and zoom 1.06: with 1.5 deg the corners showed black on head turns.
pcall(function() uevr.params.vr.set_mod_value("VR_DesktopStabilize", "on 1.5 0.08 0.6 1.06 0") end)

-- No motion blur: it makes people sick in VR, and the hands/weapon we move after the game's animation get velocity
-- from the animated pose, which smears them into long streaks down to where the animation had them.
local function set_cvar(name, value)
    local ok, err = pcall(function()
        local var = api:get_console_manager():find_variable(name)
        if var == nil then error("not found") end
        var:set_int(value)
    end)
    log("cvar " .. name .. " = " .. tostring(value) .. (ok and "" or (" failed: " .. tostring(err))))
end
set_cvar("r.MotionBlurQuality", 0)
set_cvar("r.MotionBlur.Amount", 0)

local hidden_for = nil

-- cutscene: the head, hair and collar are shown again (hidden again when play resumes)
local function show_head(pawn)
    for _, mesh in ipairs(ucall(pawn, "K2_GetComponentsByClass", skeletal_mesh_c) or {}) do
        for _, bone in ipairs(hidden_bones) do
            pcall(function() ucall(mesh, "UnHideBoneByName", ucall(kismet_string, "Conv_StringToName", bone)) end)
        end
    end
    if groom_c ~= nil then
        for _, groom in ipairs(ucall(pawn, "K2_GetComponentsByClass", groom_c) or {}) do
            pcall(function() groom:SetVisibility(true, true) end)
        end
    end
    pcall(function() pawn.HairCards:SetVisibility(true, true) end)
end

local function hide_head(pawn)
    if hidden_for == pawn then
        return
    end
    hidden_for = pawn

    local meshes = ucall(pawn, "K2_GetComponentsByClass", skeletal_mesh_c)
    for _, mesh in ipairs(meshes or {}) do
        for _, bone in ipairs(hidden_bones) do
            pcall(function() ucall(mesh, "HideBoneByName", ucall(kismet_string, "Conv_StringToName", bone), 0) end)
        end
        log("hid head/shoulder/collar bones on " .. mesh:get_fname():to_string())
    end

    if groom_c ~= nil then
        for _, groom in ipairs(ucall(pawn, "K2_GetComponentsByClass", groom_c) or {}) do
            pcall(function() groom:SetVisibility(false, true) end)
        end
    end

    -- HairCards is a separate skeletal mesh: hide it entirely.
    pcall(function() pawn.HairCards:SetVisibility(false, true) end)
end

-- the squad flashlight (body mesh + light-beam cone) is mounted on Marcus' armour, 5-7 cm from the eyes: it floats in
-- front of the face. Hidden (the spot light itself stays); it can appear mid-mission, so re-checked every 1.5 s.
local static_mesh_c = api:find_uobject("Class /Script/Engine.StaticMeshComponent")
local niagara_c = api:find_uobject("Class /Script/Niagara.NiagaraComponent")
local flash_next = 0
local function hide_flashlight(pawn)
    local now = os.clock()
    if now < flash_next or static_mesh_c == nil then return end
    flash_next = now + 1.5
    pcall(function()
        for _, c in ipairs(ucall(pawn, "K2_GetComponentsByClass", static_mesh_c) or {}) do
            local m = c.StaticMesh
            local n = m and m:get_fname():to_string() or ""
            if (n:find("SquadFlashlight", 1, true) or n:find("SimpleLightBeam", 1, true)) and c:IsVisible() then
                c:SetVisibility(false, false)
            end
        end
        -- the lens glint (Niagara under BP_FlashlightComponent)
        for _, c in ipairs(niagara_c and ucall(pawn, "K2_GetComponentsByClass", niagara_c) or {}) do
            local par = c:GetAttachParent()
            if par and par:get_fname():to_string():find("Flashlight", 1, true) and c:IsVisible() then
                c:SetVisibility(false, false)
            end
        end
    end)
end

-- rotators as axes (FRotationMatrix) and back
local function rot_axes(r)
    local p, y, ro = math.rad(r.x), math.rad(r.y), math.rad(r.z)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return { x = cp * cy, y = cp * sy, z = sp },
        { x = sr * sp * cy - cr * sy, y = sr * sp * sy + cr * cy, z = -sr * cp },
        { x = -(cr * sp * cy + sr * sy), y = cy * sr - cr * sp * sy, z = cr * cp }
end
local function vdot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local paused = false -- game paused (menu): set in the pre-tick below
TURRET_EYE_BACK, TURRET_EYE_UP = 30, 28 -- cm behind the gun's body and above it (its own axes): just over its sight
TURRET_EYE_MAX_UP = 85 -- cm over the swivel at most (the cabin's roof)
TURRET_EYE_SMOOTH = 0.15 -- s: how softly the eyes follow the gun
-- a gun on a stand: the view at Marcus' eyes follows them almost at once (turned fast, the body moved
-- and the view came after - measured up to 130 cm behind his eyes, through the gun when tilting), a little forward
TURRET_GROUND_SMOOTH = 0 -- s (0 = exactly at the eyes: measured steady, 0.08 cm frame to frame)
TURRET_GROUND_FWD = 3 -- cm along the stand's forward
TURRET_GLUE_FROM, TURRET_GLUE_TO, TURRET_GLUE_EASE = 90, 150, 0.3 -- frames after mounting; s
local turret_wait, turret_wait_pawn = 0, nil
local turret_view = {} -- turret: { pawn, off (camera - mount, world), rot (world) } as the game's camera was
uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    local pawn = api:get_local_pawn(0)
    if pawn == nil then
        turret_view.pawn, turret_wait_pawn, TURRET_VIEW_READY = nil, nil, false -- (quit from a turret: the front end must not keep the old view)
        return
    end

    local mesh = pawn.Mesh
    if mesh == nil and not CINEMATIC then
        return
    end
    -- chainsaw running: the game's camera swings after Marcus' body; the view keeps the held aim (weapon.lua)
    if saw_yaw ~= nil and not CINEMATIC then rotation.y = saw_yaw end

    -- turret (weapon.lua sets VEHICLE): the controller turns the game's aim (the only way the gun turns) and the
    -- game's camera swings with it. The view is held as the game's camera was when control passed to the gun - the
    -- same direction in the world, carried along with the gun's mount (the helicopter's moves): what it looked like
    -- with the aim left still, which was right.
    if VEHICLE and GROUND_TURRET then
        -- a gun on a stand (turret.lua): the view at Marcus' own eyes (he stands at its handles), level and turned only
        -- by the headset (turret_final): the game's camera swings with the gun's aim. Taken once he has settled at it.
        pcall(function()
            local body = BODY_PAWN
            if body == nil or body.Mesh == nil then return end
            hide_head(body)
            if turret_view.pawn ~= pawn then
                turret_wait = (turret_wait_pawn == pawn) and (turret_wait + (paused and 0 or 1)) or 0
                turret_wait_pawn = pawn
                TURRET_VIEW_READY = false
                -- (at once: waiting showed the game's third-person camera while Marcus stepped up to it;
                -- the stand's own yaw is right from the first frame)
                local yaw = ucall(pawn, "K2_GetActorRotation").y
                local cx, cy, cz = rot_axes({ x = 0, y = yaw, z = 0 })
                turret_view = { pawn = pawn, ground = true, cur = { cx, cy, cz }, base = {} }
                TURRET_VIEW_READY = true
            end
            local l = ucall(body.Mesh, "GetSocketLocation", name_eye_l)
            local r = ucall(body.Mesh, "GetSocketLocation", name_eye_r)
            local e = { x = (l.x + r.x) * 0.5, y = (l.y + r.y) * 0.5, z = (l.z + r.z) * 0.5 }
            -- glued to the GUN like the helicopter's view (the view lagged a little): Marcus' animated
            -- eyes trail and overshoot the gun's turn by up to 9 deg and sway on after it stops (measured). Once he
            -- has settled at the stand, where his eyes sit relative to the gun (in its yaw frame) is measured
            -- (TURRET_GLUE_FROM..TO frames, averaged) and from then on the view = the gun + that offset, turned with
            -- the gun's yaw only (eased in over TURRET_GLUE_EASE s)
            pcall(function()
                local tv = turret_view
                if tv.gun == nil then tv.gun = pawn.TurretInventoryComponent:GetEquippedInventoryItem().RootComponent end
                local gp = ucall(tv.gun, "K2_GetComponentLocation")
                local gf = ucall(tv.gun, "GetForwardVector")
                local gy = math.atan(gf.y, gf.x)
                local c, s_ = math.cos(gy), math.sin(gy)
                if view_index == 0 then
                    tv.glue_n = (tv.glue_n or 0) + 1
                    if tv.eye_off == nil and tv.glue_n >= TURRET_GLUE_FROM then
                        local dx, dy, dz = e.x - gp.x, e.y - gp.y, e.z - gp.z
                        local a = tv.glue_acc or { x = 0, y = 0, z = 0, n = 0 }
                        a.x, a.y, a.z, a.n = a.x + dx * c + dy * s_, a.y - dx * s_ + dy * c, a.z + dz, a.n + 1
                        tv.glue_acc = a
                        if tv.glue_n >= TURRET_GLUE_TO then
                            tv.eye_off = { x = a.x / a.n, y = a.y / a.n, z = a.z / a.n }
                            tv.glue_t = os.clock()
                        end
                    end
                end
                local o = tv.eye_off
                if o ~= nil then
                    local gl = { x = gp.x + o.x * c - o.y * s_, y = gp.y + o.x * s_ + o.y * c, z = gp.z + o.z }
                    local k = math.min(1, (os.clock() - tv.glue_t) / TURRET_GLUE_EASE)
                    e = { x = e.x + (gl.x - e.x) * k, y = e.y + (gl.y - e.y) * k, z = e.z + (gl.z - e.z) * k }
                end
            end)
            if view_index == 0 then
                local now = os.clock()
                local dt = turret_view.eye_t and math.min(now - turret_view.eye_t, 0.1) or 1
                turret_view.eye_t = now
                local k = TURRET_GROUND_SMOOTH > 0 and 1 - math.exp(-dt / TURRET_GROUND_SMOOTH) or 1
                local sm = turret_view.eye
                turret_view.eye = sm and { x = sm.x + (e.x - sm.x) * k, y = sm.y + (e.y - sm.y) * k, z = sm.z + (e.z - sm.z) * k } or e
            end
            local p = turret_view.eye or e
            local fw = turret_view.cur[1]
            p = { x = p.x + fw.x * TURRET_GROUND_FWD, y = p.y + fw.y * TURRET_GROUND_FWD, z = p.z + fw.z * TURRET_GROUND_FWD }
            position.x, position.y, position.z = p.x, p.y, p.z
            turret_view.base[view_index] = { x = p.x, y = p.y, z = p.z }
        end)
        return
    end
    if VEHICLE then
        if hidden_for ~= nil then pcall(show_head, hidden_for) hidden_for = nil end -- (seen from the game's camera)
        pcall(function()
            local root = pawn.RootComponent
            local mount = ucall(root, "GetAttachParent")
            if mount == nil then return end
            -- held in the helicopter's own frame (turns, banks and climbs with it, like sitting in a real one);
            -- taken from the game's camera when control passed to the gun
            local mp = ucall(mount, "K2_GetComponentLocation")
            local mx, my, mz = rot_axes(ucall(mount, "K2_GetComponentRotation"))
            local function loc(v) return { x = vdot(v, mx), y = vdot(v, my), z = vdot(v, mz) } end
            local function wld(v) return { x = mx.x * v.x + my.x * v.y + mz.x * v.z, y = mx.y * v.x + my.y * v.y + mz.y * v.z, z = mx.z * v.x + my.z * v.y + mz.z * v.z } end
            if turret_view.pawn ~= pawn then
                -- first the game's aim is brought to the middle of the gun's arc (weapon.lua) and its camera
                -- settles behind the gun: the view is taken from it then (taken at any moment it could face away
                -- from the gun, and the gun could not be turned to what was in front)
                turret_wait = (turret_wait_pawn == pawn) and (turret_wait + (paused and 0 or 1)) or 0 -- (not while paused: the camera stands still then)
                turret_wait_pawn = pawn
                TURRET_VIEW_READY = false
                if turret_wait < 60 then return end
                TURRET_VIEW_READY = true
                -- the game's own camera as it stands once the gun is aimed at the middle of its arc (the view the
                -- player liked), level
                -- looking down the middle of the gun's arc (its aim yaw 25..155 relative to the helicopter: 90), so
                -- straight ahead is the gun's middle; the game's camera itself looked off towards one end
                -- the gun on the helicopter's left door (socket ..._L): its arc middle is -90, not +90
                local side = 1
                pcall(function() if ucall(root, "GetAttachSocketName"):to_string():sub(-2) == "_L" then side = -1 end end)
                local fyaw = ucall(mount, "K2_GetComponentRotation").y + 90 * side
                local cx, cy, cz = rot_axes({ x = 0, y = fyaw, z = 0 })
                -- like a gunner at the handles: behind the gun's front and above it, centred on it (the game's
                -- camera stood 165 cm back, the gun in the way)
                -- measured from the gun's swivel (its turning point, which stays put however it is aimed; the front
                -- socket used before swung up and down with the aim and brought the gun into the face)
                local gun = ucall(mount, "GetSocketLocation", ucall(root, "GetAttachSocketName"))
                pcall(function()
                    local sname = ucall(root, "GetAttachSocketName"):to_string():gsub("muzzle", "swivel")
                    if ucall(mount, "GetBoneIndex", ucall(kismet_string, "Conv_StringToName", sname)) >= 0 then
                        gun = ucall(mount, "GetSocketLocation", ucall(kismet_string, "Conv_StringToName", sname))
                    end
                end)
                local a = math.rad(fyaw)
                local eye = { x = gun.x - math.cos(a) * TURRET_EYE_BACK, y = gun.y - math.sin(a) * TURRET_EYE_BACK, z = gun.z + TURRET_EYE_UP }
                turret_view = { pawn = pawn, off = loc({ x = eye.x - mp.x, y = eye.y - mp.y, z = eye.z - mp.z }),
                                ax = { loc(cx), loc(cy), loc(cz) }, base = {} }
            end
            local o = wld(turret_view.off)
            position.x, position.y, position.z = mp.x + o.x, mp.y + o.y, mp.z + o.z
            -- the eyes go with the gun, like holding it from behind: on its centre line (its body bone's x axis),
            -- behind it and above it - aimed down, its back comes up and the eyes rise over it. (The handle
            -- bone sat to one side: the view was off to the gun's side.)
            pcall(function()
                local sock = ucall(root, "GetAttachSocketName"):to_string()
                local body = ucall(kismet_string, "Conv_StringToName", (sock:gsub("muzzle", "")))
                -- just behind and over the gun's sight, as when aiming along it: follows its turn and tilt, with small
                -- distances so it moves little (from far behind and below, the gun's back hid the target; following
                -- the tilt from far away put the head in the ceiling). Never higher than TURRET_EYE_MAX_UP over the
                -- swivel.
                local g = ucall(mount, "GetSocketLocation", body)
                local gx = rot_axes(ucall(mount, "GetSocketRotation", body))
                -- "up" for the gun = the helicopter's up, square to the barrel (the bone's own z points sideways:
                -- it put the eyes beside the gun)
                local k = vdot(mz, gx)
                local gu = { x = mz.x - gx.x * k, y = mz.y - gx.y * k, z = mz.z - gx.z * k }
                local gl = math.sqrt(vdot(gu, gu))
                if gl < 0.1 then return end
                gu = { x = gu.x / gl, y = gu.y / gl, z = gu.z / gl }
                local want = { x = g.x - gx.x * TURRET_EYE_BACK + gu.x * TURRET_EYE_UP, y = g.y - gx.y * TURRET_EYE_BACK + gu.y * TURRET_EYE_UP,
                               z = g.z - gx.z * TURRET_EYE_BACK + gu.z * TURRET_EYE_UP }
                local sw = ucall(mount, "GetSocketLocation", ucall(kismet_string, "Conv_StringToName", (sock:gsub("muzzle", "swivel"))))
                local top = sw.z + TURRET_EYE_MAX_UP
                if want.z > top then want.z = top end
                -- smoothed, in the helicopter's frame (it moves itself): the eyes ease after the gun
                local lw = loc({ x = want.x - mp.x, y = want.y - mp.y, z = want.z - mp.z })
                local sm = turret_view.eye_rel
                if view_index == 0 then
                    local now = os.clock()
                    local dt = turret_view.eye_t and math.min(now - turret_view.eye_t, 0.1) or 1
                    turret_view.eye_t = now
                    local k = 1 - math.exp(-dt / TURRET_EYE_SMOOTH)
                    sm = sm and { x = sm.x + (lw.x - sm.x) * k, y = sm.y + (lw.y - sm.y) * k, z = sm.z + (lw.z - sm.z) * k } or lw
                    turret_view.eye_rel = sm
                end
                local e = wld(sm or lw)
                position.x, position.y, position.z = mp.x + e.x, mp.y + e.y, mp.z + e.z
            end)
            turret_view.cur = { wld(turret_view.ax[1]), wld(turret_view.ax[2]), wld(turret_view.ax[3]) }
            turret_view.base[view_index] = { x = position.x, y = position.y, z = position.z }
        end)
        return
    else
        turret_view.pawn, turret_wait_pawn, TURRET_VIEW_READY = nil, nil, false
    end

    -- cutscene (weapon.lua sets CINEMATIC): the game's own camera, third person as it was made
    if CINEMATIC then
        if hidden_for ~= nil then pcall(show_head, hidden_for) hidden_for = nil end -- (Marcus, also when in a turret)
        return
    end
    hide_head(pawn)
    hide_flashlight(pawn)

    -- Horizontally the camera sits on the capsule's centre, not on the head: the game twists the torso when
    -- aiming/firing and the head swings with it. Height comes from the eyes (crouch, cover), smoothed.
    local l = ucall(mesh, "GetSocketLocation", name_eye_l)
    local r = ucall(mesh, "GetSocketLocation", name_eye_r)
    local base = ucall(pawn, "K2_GetActorLocation")
    local fwd = ucall(pawn, "GetActorForwardVector")
    local eye_z = (l.z + r.z) * 0.5
    if view_index == 0 then
        local now = os.clock()
        local dt = last_clock and math.min(now - last_clock, 0.1) or 0
        last_clock = now
        local rel = eye_z - base.z + (CROUCH_DROP or 0) -- (sprint.lua lowers the body with a real crouch: not the view)
        smoothed_rel_z = smoothed_rel_z == nil and rel or smoothed_rel_z + (rel - smoothed_rel_z) * (1 - math.exp(-dt / EYE_HEIGHT_TAU))
    end
    position.x = base.x + fwd.x * FORWARD_OFFSET_CM
    position.y = base.y + fwd.y * FORWARD_OFFSET_CM
    position.z = base.z + (smoothed_rel_z or (eye_z - base.z))
    -- on a ladder the game's own body is shown (weapon.lua LADDER) and it hangs off the capsule's centre (going down
    -- the camera sat in its chest): the view goes to its eyes, eased so the switch does not jump
    local want_k = (LADDER or os.clock() < (OFF_TURRET_UNTIL or 0)) and 1 or 0
    if view_index == 0 then
        local now = os.clock()
        local dt = ladder_eye_t and math.min(now - ladder_eye_t, 0.1) or 0
        ladder_eye_t = now
        ladder_eye_k = (ladder_eye_k or 0) + (want_k - (ladder_eye_k or 0)) * (1 - math.exp(-dt / 0.15))
    end
    local k = ladder_eye_k or 0
    if k > 0.001 then
        local ex, ey, ez = (l.x + r.x) * 0.5, (l.y + r.y) * 0.5, (l.z + r.z) * 0.5
        position.x = position.x + (ex - position.x) * k
        position.y = position.y + (ey - position.y) * k
        position.z = position.z + (ez - position.z) * k
    end
    if view_index == 0 then FP_BASE = { x = position.x, y = position.y, z = position.z, k = k } end -- (debug: where this callback put the view, before the headset's offset)
end)

-- the first-person eye point (as the view callback places it): for the development drive in weapon.lua
function fp_eye_position(pawn)
    local base = ucall(pawn, "K2_GetActorLocation")
    local l, r = ucall(pawn.Mesh, "GetSocketLocation", name_eye_l), ucall(pawn.Mesh, "GetSocketLocation", name_eye_r)
    return { x = base.x, y = base.y, z = base.z + (smoothed_rel_z or ((l.z + r.z) * 0.5 - base.z + (CROUCH_DROP or 0))) }
end

-- Paused (menu, game in the background): the view stays level and looking straight ahead, the way it faced when the
-- pause began (the hands can still be seen and moved in front of it).
local statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local level_yaw = nil -- (paused: declared above, the view callbacks use it)
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local pawn = api:get_local_pawn(0)
    local ok, p = pcall(function() return pawn ~= nil and ucall(statics, "IsGamePaused", pawn) end)
    paused = ok and p or false
end)

-- turret: the final view is built here from the held camera and the headset itself (its turn and its moves since
-- control passed to the gun, plus the eye's half of the eye distance) - nothing of the game's camera in it.
local hmd_pos_v, hmd_rot_q = UEVR_Vector3f.new(), UEVR_Quaternionf.new()
local IPD = 0.064 -- m
local function qrot(q, x, y, z)
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end
local function to_ue(x, y, z) return { x = -z, y = x, z = y } end
local function turret_final(view_index, world_to_meters, position, rotation)
    local t = turret_view
    local b = t.base and t.base[view_index]
    if t.cur == nil or b == nil then return end
    local vr = uevr.params.vr
    vr.get_pose(vr.get_hmd_index(), hmd_pos_v, hmd_rot_q)
    local q = { x = hmd_rot_q.x, y = hmd_rot_q.y, z = hmd_rot_q.z, w = hmd_rot_q.w }
    local f, r, u = to_ue(qrot(q, 0, 0, -1)), to_ue(qrot(q, 1, 0, 0)), to_ue(qrot(q, 0, 1, 0))
    local p = to_ue(hmd_pos_v.x, hmd_pos_v.y, hmd_pos_v.z)
    -- the way the head faced when the view was taken counts as straight ahead (towards the gun): the headset's own
    -- yaw in the room is taken out (read raw, it left the view turned round - facing away from the gun)
    if t.head0 == nil then t.head0 = p t.yaw0 = math.atan(f.y, f.x) end
    local cy0, sy0 = math.cos(-t.yaw0), math.sin(-t.yaw0)
    local function unyaw(v) return { x = v.x * cy0 - v.y * sy0, y = v.x * sy0 + v.y * cy0, z = v.z } end
    local hx, hy, hz = t.cur[1], t.cur[2], t.cur[3]
    local function held0(v) return { x = hx.x * v.x + hy.x * v.y + hz.x * v.z, y = hx.y * v.x + hy.y * v.y + hz.y * v.z, z = hx.z * v.x + hy.z * v.y + hz.z * v.z } end
    local function held(v) return held0(unyaw(v)) end
    t.held, t.w2m = held, world_to_meters -- (turret_hand_world: the hands in this same frame)
    local x, z = held(f), held(u)
    local y = { x = z.y * x.z - z.z * x.y, y = z.z * x.x - z.x * x.z, z = z.x * x.y - z.y * x.x }
    rotation.x = math.deg(math.asin(math.max(-1, math.min(1, x.z))))
    rotation.y = math.deg(math.atan(x.y, x.x))
    rotation.z = math.deg(math.atan(-y.z, z.z))
    -- the right controller in the same frame: where it points is what the gun is turned to (weapon.lua)
    if view_index == 1 then
        pcall(function()
            local cp, cq = UEVR_Vector3f.new(), UEVR_Quaternionf.new()
            -- (the ';' matters: without it Lua reads 'new()(eday_pose or ...)' - a call on the line above - and the
            --  error, swallowed by pcall, left VEHICLE_AIM unset on every turret since the OpenXR port)
            ;(eday_pose or vr.get_pose)(eday_role_index and eday_role_index("right") or vr.get_right_controller_index(), cp, cq)
            local c = { x = cq.x, y = cq.y, z = cq.z, w = cq.w }
            local cf, cu = to_ue(qrot(c, 0, 0, -1)), to_ue(qrot(c, 0, 1, 0))
            local a = math.rad(-75.0) -- weapon.lua CONTROLLER_PITCH_DEG: how the controller is held for aiming
            local d = { x = cf.x * math.cos(a) + cu.x * math.sin(a), y = cf.y * math.cos(a) + cu.y * math.sin(a), z = cf.z * math.cos(a) + cu.z * math.sin(a) }
            local wd = held(d)
            local l = math.sqrt(wd.x * wd.x + wd.y * wd.y + wd.z * wd.z)
            local cpos = to_ue(cp.x, cp.y, cp.z)
            local o = held({ x = (cpos.x - t.head0.x) * world_to_meters, y = (cpos.y - t.head0.y) * world_to_meters, z = (cpos.z - t.head0.z) * world_to_meters })
            VEHICLE_AIM = { pos = { x = b.x + o.x, y = b.y + o.y, z = b.z + o.z }, dir = { x = wd.x / l, y = wd.y / l, z = wd.z / l } }
            VEHICLE_AIM_FP = true
        end)
    end
    local side = (view_index == 0 and -0.5 or 0.5) * IPD
    local e = { x = (p.x - t.head0.x) + r.x * side, y = (p.y - t.head0.y) + r.y * side, z = (p.z - t.head0.z) + r.z * side }
    local off = held({ x = e.x * world_to_meters, y = e.y * world_to_meters, z = e.z * world_to_meters })
    position.x, position.y, position.z = b.x + off.x, b.y + off.y, b.z + off.z
end

-- a controller's raw tracking position (metres) -> the world, in the view turret_final built (on a
-- gun stand the hands on the handles were ~40 cm from them - weapon.lua mapped them through the game's camera, which
-- is not where this view is). nil until the view is built.
function turret_hand_world(raw)
    local t = turret_view
    local b = t and t.base and t.base[0]
    if t == nil or t.held == nil or b == nil or t.head0 == nil then return nil end
    local c = to_ue(raw.x, raw.y, raw.z)
    local w = t.w2m
    local o = t.held({ x = (c.x - t.head0.x) * w, y = (c.y - t.head0.y) * w, z = (c.z - t.head0.z) * w })
    return { x = b.x + o.x, y = b.y + o.y, z = b.z + o.z }
end

uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if VEHICLE and turret_view.pawn ~= nil and not TURRET_VIEW_DEV_OFF then pcall(turret_final, view_index, world_to_meters, position, rotation) return end
    -- (never in a cutscene: there the game's camera leads, and a pause reported for a frame jerked the view)
    -- (debug only now: with the view locked, the world followed the head in the pause menu and the menu seemed to move)
    if not paused or CINEMATIC or not PAUSE_LEVEL_LOCK then
        level_yaw = rotation.y
        return
    end
    if level_yaw == nil then level_yaw = rotation.y end
    rotation.x, rotation.y, rotation.z = 0, level_yaw, 0
end)

log("loaded")
