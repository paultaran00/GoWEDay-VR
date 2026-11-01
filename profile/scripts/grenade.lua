-- Gears of War: E-Day VR - grenades by hand.
-- A frag grenade hangs on the body (left of the belt, seen when looking down) while Marcus has any. The left grip
-- near it takes it; the left trigger pulls the pin (armed: 4 s); swung and let go, it flies with the hand's speed. Not
-- thrown in time, it falls out of the hand. Not armed, letting go puts it back on the body.
-- The explosion (damage, sound, effects) is the game's own: on the throw the game's grenade is equipped and fired in
-- the background (the right trigger for a moment), and its projectile is moved onto ours and given our speed. The
-- game's frag goes off ~1 s after it comes to rest (measured; its timer cannot be moved from Lua).
local api = uevr.api
local vr = uevr.params.vr
local function log(m) pcall(function() uevr.params.functions.log_info("[grenade] " .. tostring(m)) end) end

GRENADE = GRENADE or {
    body = { fwd = 18, right = 14, up = -55 }, -- cm from the eyes on the head's flat facing: right of the belt, in front of the hip
    grab_radius = 10,      -- cm from the left hand to it: taken
    fuse = 4.0,            -- s from the pin pulled (left trigger)
    throw_gain = 1.3,      -- the hand's speed times this (a real throw also has the wrist's snap)
    in_hand = { x = 9.0, y = -4.5, z = 0.0 },   -- (unused since the hold is worked out from the finger bones)
    in_hand_R = { x = 9.0, y = 4.5, z = 0.0 },
    grip_z = -7.5,         -- cm along the grenade (mesh z): the point of the handle in the fist's hole
    handover_timeout = 2.5,
    -- the flight stays ours after the hand-over (the game's own projectile movement steered it down after ~0.2 s):
    restitution = 0.3,     -- bounce: the velocity along the surface normal comes back times this
    friction = 0.6,        -- bounce: the sliding velocity loses this share
    rest_speed = 80,       -- cm/s: slower than this after a bounce (or max_bounces): it lies, the game settles and blows it
    max_bounces = 3,
    max_flight = 6.0,      -- s: then released to the game whatever happens
    scale = 1.0,
}
local G = GRENADE
-- left-handed (aa_xr.lua eday_on_hand): the grenade hangs on the other side of the belt
eday_on_hand(function(left) G.body.right = left and -14 or 14 end)
local BODY_MESH = "StaticMesh /Game/Fairlight/Weapons/COG/GrenadeFrag/GP01/COG_GrenadeFragBody_GP01.COG_GrenadeFragBody_GP01"
local HANDLE_MESH = "StaticMesh /Game/Fairlight/Weapons/COG/GrenadeFrag/GP01/COG_GrenadeFragHandle_GP01.COG_GrenadeFragHandle_GP01"

local gs, kmath, inv_c, weapon_c, proj_c, sma_c
local function init()
    if gs ~= nil then return end
    gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
    kmath = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
    inv_c = api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent")
    weapon_c = api:find_uobject("Class /Script/TCWeapon.TCBaseWeapon")
    proj_c = api:find_uobject("Class /Script/TCWeapon.TCProjectileBase")
    sma_c = api:find_uobject("Class /Script/Engine.StaticMeshActor")
end

local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function len(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
local function copy(u) return v(u.x, u.y, u.z) end

local st = { state = "body", parts = nil, item = nil, item_t = -10, count = 0, hist = {}, armed_at = nil, pawn = nil, side = "L" }
GRENADE_STATE = st -- (debug)

-- a throwable (any of the game's grenades: frag, concussion / stun, incendiary, smoke, revive, Locust frag - all
-- BP_Wpn_ThrowableBase_C; Marcus carries one kind at a time, a new one replaces it)
local throwable_cache = {}
local function is_throwable(a)
    local cls = a:get_class()
    local key = cls:get_fname():to_string()
    if throwable_cache[key] == nil then
        local yes, c = false, cls
        for i = 1, 8 do
            if c == nil then break end
            if c:get_fname():to_string():find("ThrowableBase") then yes = true break end
            local ok, sp = pcall(function() return c:get_super() end)
            c = ok and sp or nil
        end
        throwable_cache[key] = yes
    end
    return throwable_cache[key]
end
-- the pawn's throwable item and how many it has (looked up once a second)
local function grenade_item(pawn)
    local now = os.clock()
    if now - st.item_t < 1.0 and st.pawn == pawn then return st.item end
    st.item_t, st.pawn, st.item, st.count = now, pawn, nil, 0
    pcall(function()
        local all = {}
        gs:GetAllActorsOfClass(pawn, weapon_c, all)
        for _, a in ipairs(all) do
            if a:GetOwner() == pawn and is_throwable(a) then
                local s = a:GetAmmoState()
                st.item, st.count = a, s.AmmoInMagazine + s.SpareAmmo
            end
        end
    end)
    return st.item
end
-- its own look: the Body and Handle meshes the game draws it with
local function item_meshes(item)
    local body, handle = nil, nil
    pcall(function()
        for _, c in ipairs(item:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine.StaticMeshComponent")) or {}) do
            local n = c:get_fname():to_string()
            if n == "Body" then body = c.StaticMesh elseif n == "Handle" then handle = c.StaticMesh end
        end
    end)
    return body, handle
end

-- the grenade we show: body + handle (two mesh actors moved together, no collision)
local function mesh_actor(pawn, mesh)
    if type(mesh) == "string" then mesh = (eday_asset and eday_asset(mesh)) or api:find_uobject(mesh) end
    if mesh == nil then return nil end
    local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
    xf.Translation = pawn:K2_GetActorLocation()
    local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat")) q.W = 1
    xf.Rotation = q
    xf.Scale3D = Vector3d.new(G.scale, G.scale, G.scale)
    local a = gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(pawn, sma_c, xf, 1, nil, 0), xf, 0)
    local c = a.StaticMeshComponent
    c:SetMobility(2)
    pcall(function() c:SetCollisionEnabled(0) end)
    pcall(function() c:SetCastShadow(false) end)
    c:SetStaticMesh(mesh)
    return a
end
local function parts_valid()
    if st.parts == nil then return false end
    local ok, n = pcall(function() return st.parts[1]:get_full_name() end)
    return ok and n ~= nil and n ~= ""
end
-- Parts left by an earlier load of this script (a script reload forgets st.parts but not the actors: the old grenade
-- stayed floating where it was while a new one hung on the belt). Ours = a plain
-- StaticMeshActor with a grenade / throwable mesh, movable and without shadow (mesh_actor) - level props are not.
function grenade_purge_old(pawn)
    local n = 0
    pcall(function()
        local all = {}
        gs:GetAllActorsOfClass(pawn, sma_c, all)
        for _, a in ipairs(all) do
            local mine = st.parts ~= nil and (a == st.parts[1] or a == st.parts[2])
            if not mine then
                local c = a.StaticMeshComponent
                local mn = c and c.StaticMesh and c.StaticMesh:get_full_name() or ""
                if (mn:find("Grenade") or mn:find("Throwable")) and c.Mobility == 2 and not c.CastShadow then
                    pcall(function() a:K2_DestroyActor() end)
                    n = n + 1
                end
            end
        end
    end)
    if n > 0 then log("removed " .. n .. " grenade parts left from an earlier load") end
    return n
end
local function make_parts(pawn, item)
    local body, handle = nil, nil
    if item ~= nil then body, handle = item_meshes(item) end
    local kind = item and item:get_class():get_fname():to_string() or "frag"
    if parts_valid() then
        if st.parts_kind == kind or body == nil then return true end
        -- another kind now (a new one replaced the old): its own meshes
        pcall(function() st.parts[1].StaticMeshComponent:SetStaticMesh(body) end)
        if st.parts[2] and handle then pcall(function() st.parts[2].StaticMeshComponent:SetStaticMesh(handle) end) end
        st.parts_kind = kind
        log("grenade now " .. kind)
        return true
    end
    grenade_purge_old(pawn)
    local b, h = mesh_actor(pawn, body or BODY_MESH), mesh_actor(pawn, handle or HANDLE_MESH)
    if b == nil then return false end
    st.parts, st.parts_kind, st.shown = { b, h }, kind, nil
    log("grenade made (" .. kind .. ")")
    return true
end
local function show_parts(on)
    if st.parts == nil or st.shown == on then return end
    st.shown = on
    for _, a in ipairs(st.parts) do pcall(function() a:SetActorHiddenInGame(not on) end) end
end
-- pos (cm), x / z axes (unit vectors)
local function place_parts(pos, x, z)
    local rot = kmath:MakeRotFromXZ(Vector3d.new(x.x, x.y, x.z), Vector3d.new(z.x, z.y, z.z))
    for _, a in ipairs(st.parts or {}) do
        pcall(function() a:K2_SetActorLocationAndRotation(Vector3d.new(pos.x, pos.y, pos.z), rot, false, {}, true) end)
    end
end

local function body_frame(ctx)
    local f = ctx.cam_fwd
    local r = v(-f.y, f.x, 0)
    local B = G.body
    return add(ctx.cam_pos, add(add(mul(f, B.fwd), mul(r, B.right)), v(0, 0, B.up))), f
end

-- the grenade in the fist: its handle through the fist's hole, the ball above the index (thumb side). Worked out from
-- the drawn hand's own finger bones each frame (both hands, any curl): the mesh's z is the grenade's length (ball +z
-- from -0.9 to 20.1 cm, handle down to -17.9), so the point G.grip_z of it sits in the hole. (take it
-- lower, on its handle - held by the ball the fingers went into it)
local function hand_frame()
    -- (st.side is the role: "L" support hand, "R" weapon hand; the drawn bone side differs when left-handed)
    local side = (st.side or "L") == "L" and (ARMS_SUPPORT_SIDE or "L") or (ARMS_WEAPON_SIDE or "R")
    local hc = arms_left_hand_component and arms_left_hand_component() -- (the drawn body: both hands)
    if hc == nil then return nil end
    local ks = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
    local function bone(n) return copy(hc:GetSocketLocation(ks:Conv_StringToName(n .. side))) end
    local hand = bone("b_hand_")
    local m1, m2, m3 = bone("b_middle_01_"), bone("b_middle_02_"), bone("b_middle_03_")
    local i2, p2 = bone("b_index_02_"), bone("b_pinky_02_")
    local hole = mul(add(add(m1, m2), m3), 1 / 3)
    local axis = sub(i2, p2)
    local al = len(axis)
    if al < 1e-3 then return nil end
    axis = mul(axis, 1 / al) -- along the hole, towards the index: the ball's side
    local fx = sub(m1, hand) -- the fingers' direction, square to the axis
    local d = fx.x * axis.x + fx.y * axis.y + fx.z * axis.z
    fx = sub(fx, mul(axis, d))
    local fl = len(fx)
    fx = fl > 1e-3 and mul(fx, 1 / fl) or v(1, 0, 0)
    return add(hole, mul(axis, -G.grip_z)), fx, axis
end

-- The release velocity: the PEAK of the swing, not the mean of the last 80 ms. At the end of an overhand swing the hand
-- already slows and turns upward, so the mean was too slow and too vertical (a real throw measured 2-3 m/s forward,
-- 8-9 m/s up: ~70 deg, landed 3-4 m away). Velocities are taken over spans of >= 30 ms (noise) and the fastest one that
-- ends in the last 150 ms counts. The second result is the old end-of-swing mean (log only).
local function hand_velocity()
    local h = st.hist
    if #h < 2 then return v(0, 0, 0), v(0, 0, 0) end
    local a, b = h[1], h[#h]
    local old = v(0, 0, 0)
    if b.t - a.t > 1e-3 then old = mul(sub(b.p, a.p), 1 / (b.t - a.t)) end
    local best, bs = nil, -1
    for i = 1, #h - 1 do
        if h[i].t >= b.t - 0.15 then
            for j = i + 1, #h do
                local dt = h[j].t - h[i].t
                if dt >= 0.03 or j == #h then
                    if dt > 1e-3 then
                        local u = mul(sub(h[j].p, h[i].p), 1 / dt)
                        if len(u) > bs then best, bs = u, len(u) end
                    end
                    break
                end
            end
        end
    end
    return best or old, old
end
G.hand_velocity = hand_velocity -- (debug)

local function haptic(amp, secs)
    pcall(function() eday_haptic(0.0, secs or 0.05, 120, amp, st.side == "R" and vr.get_right_joystick_source() or vr.get_left_joystick_source()) end)
end

-- the throw: our grenade flies on; the game's grenade is equipped and fired, its projectile takes our grenade's place
local function start_throw(ctx, vel)
    local inv = ctx.pawn:GetComponentByClass(inv_c)
    st.prev_item = inv and inv:GetEquippedInventoryItem() or nil
    st.known = {}
    pcall(function()
        local all = {}
        gs:GetAllActorsOfClass(ctx.pawn, proj_c, all)
        for _, a in ipairs(all) do st.known[a:get_fname():to_string()] = true end
    end)
    local ok = pcall(function() inv:EquipInventoryItemInSlot(inv:GetItemSlotFromInventoryItem(st.item), false) end)
    st.state, st.fly_vel, st.throw_t, st.fly_t = "flying", vel, os.clock(), os.clock()
    st.proj, st.bounces, st.landed = nil, 0, false
    st.fly_pos = st.fly_pos or hand_frame()
    GRENADE_RT = true
    log(string.format("thrown at %.0f cm/s (equip %s)", len(vel), tostring(ok)))
end

local function restore_item(ctx)
    GRENADE_RT = false
    pcall(function()
        local inv = ctx.pawn:GetComponentByClass(inv_c)
        if st.prev_item ~= nil and inv:GetEquippedInventoryItem() ~= st.prev_item then
            inv:EquipInventoryItemInSlot(inv:GetItemSlotFromInventoryItem(st.prev_item), false)
        end
    end)
    st.prev_item = nil
end

local function end_throw(ctx, why)
    restore_item(ctx)
    st.proj, st.bounces, st.landed = nil, 0, false
    st.state, st.armed_at, st.item_t = "body", nil, -10
    log("throw " .. why)
end

local function find_projectile(pawn)
    local found = nil
    pcall(function()
        local all = {}
        gs:GetAllActorsOfClass(pawn, proj_c, all)
        for _, a in ipairs(all) do
            local n = a:get_fname():to_string()
            if not st.known[n] and not a.bExploded then -- (any kind: its own projectile)
                local mine = true
                pcall(function() local ins = a:GetInstigator() if ins ~= nil and ins ~= pawn then mine = false end end)
                local vv = a.MovementComp.Velocity
                if mine and math.abs(vv.x) + math.abs(vv.y) + math.abs(vv.z) > 50 then found = a end
            end
        end
    end)
    return found
end

-- weapon.lua: the left grip pressed / let go (true: taken here)
function grenade_left_pressed(ctx)
    init()
    if st.state ~= "body" or not st.on_body then return false end
    local p = body_frame(ctx)
    if len(sub(ctx.left_pos, p)) > G.grab_radius then return false end
    st.state, st.armed_at, st.hist, st.side = "hand", nil, {}, "L"
    haptic(0.3)
    log("taken (left hand)")
    return true
end
function grenade_left_released(ctx)
    if st.state ~= "hand" then return false end
    if st.side == "R" and ctx.release_side ~= "R" then return false end
    if st.armed_at == nil then
        st.state = "body"
        log("put back (not armed)")
        return true
    end
    local pk, old = hand_velocity()
    local vel = GRENADE_DEV_VEL or mul(pk, G.throw_gain) -- (GRENADE_DEV_VEL: tests - a simulated hand jumps)
    local function elev(u) return math.deg(math.atan(u.z, math.sqrt(u.x * u.x + u.y * u.y))) end
    log(string.format("release: peak %.0f cm/s at %.0f deg above horizontal; end-of-swing mean %.0f cm/s at %.0f deg; thrown %.0f cm/s",
        len(pk), elev(pk), len(old), elev(old), len(vel)))
    st.fly_pos = (hand_frame())
    start_throw(ctx, vel)
    return true
end
-- the free right hand (its weapon on the back, weapon.lua RIGHT_FREE) takes and throws it the same way
function grenade_right_pressed(ctx)
    init()
    if st.state ~= "body" or not st.on_body or not RIGHT_FREE or ctx.right_pos == nil then return false end
    local p = body_frame(ctx)
    if len(sub(ctx.right_pos, p)) > G.grab_radius then return false end
    st.state, st.armed_at, st.hist, st.side = "hand", nil, {}, "R"
    haptic(0.3)
    log("taken (right hand)")
    return true
end
function grenade_right_released(ctx)
    if st.state ~= "hand" or st.side ~= "R" then return false end
    ctx.release_side = "R"
    local r = grenade_left_released(ctx)
    ctx.release_side = nil
    return r
end
function grenade_in_hand() return st.state == "hand" end
function grenade_hand_side() return st.state == "hand" and st.side or nil end -- (vrsettings.lua: the trigger of that hand is the grenade's)
-- weapon.lua: end of its gamepad hook. The left trigger arms the grenade in the hand (not the sprint then); the
-- right trigger is held for the game's throw.
function GRENADE_PAD(state)
    if st.state == "hand" then
        if st.side == "R" then state.Gamepad.bRightTrigger = 0
        else LT_SPRINT = false state.Gamepad.bLeftTrigger = 0 end
    end
    -- (failsafe: held only while the throw is ours and our updates run - a cutscene / turret / ladder starting mid-throw
    -- stops them, and the trigger stayed at 255: the weapon fired non-stop)
    if GRENADE_RT and (st.state ~= "flying" or (st.upd_frame or -10) < st.frame - 2 or os.clock() - (st.throw_t or 0) > G.handover_timeout + 1) then
        GRENADE_RT = false
        log("right trigger released: the throw is not updated any more")
    end
    if GRENADE_RT then state.Gamepad.bRightTrigger = 255 end
end

-- weapon.lua: every frame with the gesture context
function grenade_update(ctx)
    init()
    st.upd_frame = st.frame
    local now = os.clock()
    local item = grenade_item(ctx.pawn)
    table.insert(st.hist, { p = (st.side == "R" and ctx.right_pos) or ctx.left_pos, t = now })
    while #st.hist > 1 and now - st.hist[1].t > 0.2 do table.remove(st.hist, 1) end
    if not make_parts(ctx.pawn, item) then return end

    if st.state == "body" then
        st.on_body = item ~= nil and st.count > 0 and not CINEMATIC
        show_parts(st.on_body)
        if st.on_body then
            local p, f = body_frame(ctx)
            st.body_pos = p -- (debug)
            place_parts(add(p, v(0, 0, -G.grip_z)), f, v(0, 0, 1)) -- hanging upright, ball up (the mesh's z is its length); p = the handle's grip point
        end
    elseif st.state == "hand" then
        show_parts(true)
        local p, x, z = hand_frame()
        if p then place_parts(p, x, z) end
        -- the pin: the trigger of the hand holding it (GRENADE_DEV_LT: tests, the simulated pad comes after weapon.lua)
        local raw = PAD_RAW and (st.side == "R" and PAD_RAW.rt or PAD_RAW.lt) or 0
        local lt = math.max(raw, GRENADE_DEV_LT or 0)
        if st.armed_at == nil and lt > 128 then
            st.armed_at = now
            haptic(0.8, 0.08)
            log("armed")
        end
        if st.armed_at ~= nil and now - st.armed_at > G.fuse then
            -- not thrown in time: it falls out of the hand
            st.fly_pos = p
            start_throw(ctx, v(0, 0, 0))
        end
    elseif st.state == "flying" then
        local gap = now - (st.fly_t or now)
        if gap > 0.5 then -- updates were off (cutscene / turret): hand it to the game as it is
            show_parts(false)
            if st.proj then pcall(function() st.proj.MovementComp.Velocity = Vector3d.new(0, 0, 0) end) end
            end_throw(ctx, string.format("released: no update for %.1f s", gap))
            return
        end
        local dt = math.min(0.05, gap)
        st.fly_t = now
        -- ours is the flight: gravity, the line trace per step, bounces; the game's projectile (once it exists) is put
        -- on it every tick
        if st.fly_pos and not st.landed then
            st.fly_vel = add(st.fly_vel, v(0, 0, -980 * dt))
            local nxt = add(st.fly_pos, mul(st.fly_vel, dt))
            pcall(function()
                G.hit = G.hit or StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
                G.ksys = G.ksys or api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
                local ign = { ctx.pawn }
                if st.proj then ign[2] = st.proj end
                local got = G.ksys:LineTraceSingle(ctx.pawn, Vector3d.new(st.fly_pos.x, st.fly_pos.y, st.fly_pos.z),
                    Vector3d.new(nxt.x, nxt.y, nxt.z), 1, false, ign, 0, G.hit, true,
                    { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
                if got then
                    local ip, n = G.hit.ImpactPoint, G.hit.ImpactNormal
                    n = v(n.X or n.x, n.Y or n.y, n.Z or n.z)
                    nxt = v((ip.X or ip.x) + n.x * 4, (ip.Y or ip.y) + n.y * 4, (ip.Z or ip.z) + n.z * 4)
                    local fv = st.fly_vel
                    local vn = fv.x * n.x + fv.y * n.y + fv.z * n.z
                    if vn < 0 then
                        local vt = sub(fv, mul(n, vn))
                        st.fly_vel = add(mul(vt, 1 - G.friction), mul(n, -vn * G.restitution))
                        st.bounces = st.bounces + 1
                        st.last_hit = { t = now - st.throw_t, p = copy(nxt) }
                        if st.bounces == 1 then st.first_hit = st.last_hit end
                    end
                    if len(st.fly_vel) < G.rest_speed or st.bounces >= G.max_bounces then
                        st.fly_vel, st.landed = v(0, 0, 0), true
                    end
                end
            end)
            st.fly_pos = nxt
            place_parts(st.fly_pos, v(1, 0, 0), v(0, 0, 1))
        end
        -- the game's grenade item in the hand stays hidden (the throw is ours)
        pcall(function() if item then item:SetActorHiddenInGame(true) end end)
        if st.proj == nil then
            local pr = find_projectile(ctx.pawn)
            if pr ~= nil and st.fly_pos ~= nil then
                st.proj = pr
                show_parts(false) -- (its own mesh shows)
                restore_item(ctx) -- the weapon back in the hand, the trigger let go
                log(string.format("game's grenade found after %.2f s: flight stays ours", now - st.throw_t))
            elseif now - st.throw_t > G.handover_timeout then
                show_parts(false)
                end_throw(ctx, "failed: no projectile from the game")
                return
            end
        end
        if st.proj ~= nil then
            local pr, alive = st.proj, false
            pcall(function() alive = pr:K2_GetActorLocation() ~= nil and not pr.bExploded end)
            if not alive then
                end_throw(ctx, "projectile gone / exploded")
            elseif st.landed or now - st.throw_t > G.max_flight then
                pcall(function()
                    pr:K2_SetActorLocation(Vector3d.new(st.fly_pos.x, st.fly_pos.y, st.fly_pos.z), false, {}, true)
                    pr.MovementComp.Velocity = Vector3d.new(0, 0, 0)
                end)
                end_throw(ctx, string.format("%s after %.2f s", st.landed and "landed" or "max flight, released", now - st.throw_t))
            else
                pcall(function()
                    pr:K2_SetActorLocation(Vector3d.new(st.fly_pos.x, st.fly_pos.y, st.fly_pos.z), false, {}, true)
                    pr.MovementComp.Velocity = Vector3d.new(st.fly_vel.x, st.fly_vel.y, st.fly_vel.z)
                end)
            end
        end
    end
end

-- Not updated (weapon.lua calls grenade_update only with a weapon in first person): mission intros, cutscenes, forced
-- walks. The grenade stayed where it was last placed and hung in the air behind the body - hidden until the
-- updates come back (they show it again where it belongs).
st.frame = 0
uevr.sdk.callbacks.on_pre_engine_tick(function()
    st.frame = st.frame + 1
    if st.shown and (st.upd_frame or -10) < st.frame - 2 then
        show_parts(false)
        log("hidden: no update (intro / cutscene)")
    end
end)

log("loaded")
