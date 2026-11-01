-- Gears of War: E-Day VR weapon handling: the equipped weapon sits in the right controller, and the left hand
-- can grab the front of it (hold left grip near the foregrip) to aim with both hands.
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
    pcall(function() uevr.params.functions.log_info("[weapon] " .. tostring(msg)) end)
end

-- Tuning (cm, in weapon space: X = towards the muzzle, Y = right, Z = up).
-- Where the right hand holds the weapon, and where the left hand holds it, from the game's own hand IK targets.
local GRIP = { x = 0.2, y = 3.7, z = -0.8 }
local FOREGRIP = { x = 43.7, y = -1.9, z = -2.1 }
local MUZZLE = { x = 72.9, y = 0.0, z = 10.6 }
local MAX_SHOT_CM = 20000.0 -- how far ahead along the sight line we look for what is being aimed at
local GRAB_RADIUS_CM = 20.0 -- how close the left hand must be to the foregrip when grip is pressed
-- Tilt of the weapon relative to the controller's raw pose (degrees, + = muzzle up). Tune if the gun points too high/low.
local CONTROLLER_PITCH_DEG = -75.0
-- Pistols held with both hands, like in films ("cup"): the bottom of the grip rests in the left palm - palm up under
-- the grip's butt, fingers to the right under it and curled up a little round its side, thumb forward (weapon space,
-- cm; hand bone axes: x along the fingers, y back of the hand, z towards the little finger; the palm's middle ~5 cm
-- along x and ~1.5 cm on the palm side). The right fist covers the grip from z 0 to -8.4: its butt is at ~-10.5.
PISTOL_CLASSES = { "Snub", "Boltok", "Gorgon", "Talon", "Pistol", "Magnum" }
PISTOL_GRAB_CM = 12 -- left grip pressed this near the left palm's place under the grip: both hands on the pistol
PISTOL_FIRST_CM = 9  -- this near, the pistol takes the press before the magazine / chest pouch gestures
PISTOL_LEFT = { palm = { -1.0, -3.0, -11.0 }, forward = 0.3, curl = 0.45 } -- (palm middle 3 cm left of the butt: the butt sits towards the fingers)


-- Marcus' own arms are animated by the game and don't follow the controllers: hide them.
local HIDDEN_ARM_BONES = { "b_upperarm_L", "b_upperarm_R" }

local XINPUT_GAMEPAD_LEFT_SHOULDER = 0x0100
local XINPUT_GAMEPAD_RIGHT_SHOULDER = 0x0200

local inv_c = api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent")
local skeletal_mesh_c = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
local kismet_math = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()

-- rotator from forward (x) and up (z) axes, as KismetMathLibrary.MakeRotFromXZ (same result, no engine call)
local function rot_from_xz(x, z)
    local xl = math.sqrt(x.x * x.x + x.y * x.y + x.z * x.z)
    local fx, fy, fz = x.x / xl, x.y / xl, x.z / xl
    local yx, yy, yz = z.y * fz - z.z * fy, z.z * fx - z.x * fz, z.x * fy - z.y * fx -- y = z ^ x
    local yl = math.sqrt(yx * yx + yy * yy + yz * yz)
    yx, yy, yz = yx / yl, yy / yl, yz / yl
    local zz = fx * yy - fy * yx -- (x ^ y).z
    return Vector3d.new(math.deg(math.asin(math.max(-1, math.min(1, fz)))), math.deg(math.atan(fy, fx)), math.deg(math.atan(-yz, zz)))
end
local kismet_string = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
local kismet_system = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
local primitive_c = api:find_uobject("Class /Script/Engine.PrimitiveComponent")
local hit_result_c = api:find_uobject("ScriptStruct /Script/Engine.HitResult")
local linear_color_c = api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor")
local hit_result = StructObject.new(hit_result_c)
local no_color = StructObject.new(linear_color_c)

local vr = uevr.params.vr
local grip_action = vr.get_action_handle("/actions/default/in/Grip")

-- vector helpers (plain tables {x, y, z})
local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a) local l = len(a) return l > 1e-6 and mul(a, 1 / l) or a end
local function copy(u) return v(u.x, u.y, u.z) end

-- frames { pos, x, y, z }: express b in a's coordinates, and back
function pistol_left_frame(wf)
    local X, Y, Z = wf.x, wf.y, wf.z
    local hx = norm(add(mul(Y, PISTOL_LEFT.side or 1), mul(X, PISTOL_LEFT.forward))) -- fingers to the right under the grip (left-handed: to the left), a little forward
    local hy = mul(Z, -1)                                  -- back of the hand down: palm up
    local hz = cross(hx, hy)                               -- little finger back, thumb forward
    local c = PISTOL_LEFT.palm
    local palm = add(wf.pos, add(add(mul(X, c[1]), mul(Y, c[2])), mul(Z, c[3])))
    return { pos = add(sub(palm, mul(hx, 5.0)), mul(hy, 1.5)), x = hx, y = hy, z = hz }
end

local function relative(a, b)
    local function loc(p) return v(dot(p, a.x), dot(p, a.y), dot(p, a.z)) end
    return { pos = loc(sub(b.pos, a.pos)), x = loc(b.x), y = loc(b.y), z = loc(b.z) }
end
local function compose(a, rel)
    local function w(p) return add(mul(a.x, p.x), add(mul(a.y, p.y), mul(a.z, p.z))) end
    return { pos = add(a.pos, w(rel.pos)), x = w(rel.x), y = w(rel.y), z = w(rel.z) }
end
-- Requests (weapon, hands, camera) are kept relative to where Marcus is, not to which way he faces: when firing,
-- the game swings his body towards the aim (about 15 degrees a frame), and frames that turned with him made the
-- weapon and hands jump sideways for a few frames. His position still counts (walking).
function actor_frame(actor)
    return { pos = copy(ucall(actor, "K2_GetActorLocation")), x = v(1, 0, 0), y = v(0, 1, 0), z = v(0, 0, 1) }
end

-- world position of a weapon-space point, given the weapon origin and axes
local function to_world(origin, f, r, u, p)
    return add(origin, add(mul(f, p.x), add(mul(r, p.y), mul(u, p.z))))
end

-- Controllers in the game world, computed from the VR poses: whatever maps the headset onto the game camera this
-- frame also maps the controllers. (UEVR's own UObjectHook can't hook this game's UObject destructor.)
local pose_pos = UEVR_Vector3f.new()
local pose_rot = UEVR_Quaternionf.new()

-- OpenVR (x right, y up, -z forward, metres) -> Unreal axes (x forward, y right, z up)
local function vr_to_ue(x, y, z) return v(-z, x, y) end

local function rotate(q, x, y, z)
    -- q * (x, y, z) * q^-1
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end

-- position (UE axes, metres) and forward/right/up axes (UE axes) of a tracked device
-- Controller smoothing (One-Euro filter): still or slow hands are smoothed hard (no tremor on the weapon), fast
-- movements pass through almost at once (no lag when swinging the weapon round).
-- (was 1.2 / 6 and 1.0 / 2.5: steady, but the weapon trailed the hand; tuned offline on a simulated hand with
-- tracking noise: about half the lag while moving, still steady (under half a millimetre) when held still)
local SMOOTH_POS_MIN_HZ = 2.5   -- cutoff when still (lower = steadier)
local SMOOTH_POS_BETA = 30.0    -- cutoff rise per m/s of hand speed (higher = less lag when moving)
local SMOOTH_ROT_MIN_HZ = 1.6
local SMOOTH_ROT_BETA = 8.0     -- per rad/s
local SMOOTH_SPEED_HZ = 3.0     -- the speed itself is smoothed too: a noisy speed made the cutoff (and the lag) jitter
local smooth_state = {}
local function lowpass(prev, cur, dt, hz)
    local tau = 1 / (2 * math.pi * hz)
    local a = 1 / (1 + tau / dt)
    return { x = prev.x + (cur.x - prev.x) * a, y = prev.y + (cur.y - prev.y) * a, z = prev.z + (cur.z - prev.z) * a }
end
local function smooth_device(key, dev)
    local now = os.clock()
    local st = smooth_state[key]
    if st == nil or now - st.t > 0.25 then
        smooth_state[key] = { t = now, pos = dev.pos, f = dev.f, u = dev.u }
        return dev
    end
    local dt = math.max(now - st.t, 1e-3)
    local function vlen(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
    local function vsub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
    local T = SMOOTH_TUNE or {} -- development: try other values live (tools/dbg.sh), nil = the ones above
    local sa = 1 / (1 + 1 / (2 * math.pi * (T.speed_hz or SMOOTH_SPEED_HZ)) / dt)
    local speed = (st.speed or 0) + (vlen(vsub(dev.pos, st.pos)) / dt - (st.speed or 0)) * sa
    local ang = (st.ang or 0) + ((vlen(vsub(dev.f, st.f)) + vlen(vsub(dev.u, st.u))) * 0.5 / dt - (st.ang or 0)) * sa
    local pos = lowpass(st.pos, dev.pos, dt, (T.pos_min or SMOOTH_POS_MIN_HZ) + (T.pos_beta or SMOOTH_POS_BETA) * speed)
    local hz = (T.rot_min or SMOOTH_ROT_MIN_HZ) + (T.rot_beta or SMOOTH_ROT_BETA) * ang
    local f, u = lowpass(st.f, dev.f, dt, hz), lowpass(st.u, dev.u, dt, hz)
    local fl = vlen(f) f = { x = f.x / fl, y = f.y / fl, z = f.z / fl }
    local d = f.x * u.x + f.y * u.y + f.z * u.z
    u = { x = u.x - f.x * d, y = u.y - f.y * d, z = u.z - f.z * d }
    local ul = vlen(u) u = { x = u.x / ul, y = u.y / ul, z = u.z / ul }
    smooth_state[key] = { t = now, pos = pos, f = f, u = u, speed = speed, ang = ang }
    local r = { x = u.y * f.z - u.z * f.y, y = u.z * f.x - u.x * f.z, z = u.x * f.y - u.y * f.x }
    return { pos = pos, f = f, u = u, r = r }
end

local function device(index)
    (eday_pose or vr.get_pose)(index, pose_pos, pose_rot) -- (aa_xr.lua: OpenVR grip pose on OpenXR too)
    local q = { x = pose_rot.x, y = pose_rot.y, z = pose_rot.z, w = pose_rot.w }
    return {
        pos = vr_to_ue(pose_pos.x, pose_pos.y, pose_pos.z),
        f = vr_to_ue(rotate(q, 0, 0, -1)),
        r = vr_to_ue(rotate(q, 1, 0, 0)),
        u = vr_to_ue(rotate(q, 0, 1, 0)),
    }
end

-- axes of an Unreal rotator (FRotationMatrix)
local function rotator_axes(rot)
    local p, y, r = math.rad(rot.x), math.rad(rot.y), math.rad(rot.z) -- pitch, yaw, roll
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return v(cp * cy, cp * sy, sp),
        v(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp),
        v(-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp)
end

-- re-express a vector given in the headset's frame (hmd axes) in the camera's world frame (cam axes)
local function hmd_to_world(d, hmd, cf, cr, cu)
    return add(mul(cf, dot(d, hmd.f)), add(mul(cr, dot(d, hmd.r)), mul(cu, dot(d, hmd.u))))
end

local hidden_for = nil

local function hide_arms(pawn)
    if hidden_for == pawn then return end
    hidden_for = pawn
    for _, mesh in ipairs(ucall(pawn, "K2_GetComponentsByClass", skeletal_mesh_c) or {}) do
        for _, bone in ipairs(HIDDEN_ARM_BONES) do
            pcall(function() ucall(mesh, "HideBoneByName", ucall(kismet_string, "Conv_StringToName", bone), 0) end)
        end
    end
end

local two_handed = false
-- the right stick's turn rate, deg/s, for each quarter of its deflection: the game's own (learned while the chainsaw is
-- off, see the pre-tick); used to turn the camera while the chainsaw revs
TURN_RATES = TURN_RATES or { 45, 110, 170, 220 }
local turn_last_yaw = nil
local FIST_KNUCKLES = 8 -- cm from the left controller's point to the knuckles, along it (collisions: they touch first)
local left_grip_was_down = false

local right_grip_was_down = false
-- left-handed (aa_xr.lua eday_on_hand): the hand sits on the other side of the grip, the support hand on the other
-- side of the forend, the pistol's cup mirrors; the weapon itself (bones, sockets) is the same gun
eday_on_hand(function(left)
    local s = left and -1 or 1
    GRIP.y, FOREGRIP.y = 3.7 * s, -1.9 * s
    PISTOL_LEFT.palm[2], PISTOL_LEFT.side = -3.0 * s, s
    two_handed, HELD_HANDLE, left_grip_was_down, right_grip_was_down = false, nil, false, false
    for k in pairs(smooth_state) do smooth_state[k] = nil end
end)
-- debug_grip / debug_device: simulated controllers from zz_debug.lua (development only; nil when it is off)
local function right_grip_down()
    local sim = debug_grip and debug_grip("right")
    if sim ~= nil then return sim end
    return vr.is_action_active(grip_action, vr.get_right_joystick_source())
end

local function left_grip_down()
    local sim = debug_grip and debug_grip("left")
    if sim ~= nil then return sim end
    return vr.is_action_active(grip_action, vr.get_left_joystick_source())
end

local function equipped_weapon_mesh(pawn)
    local inv = ucall(pawn, "GetComponentByClass", inv_c)
    if inv == nil then return nil end
    local item = ucall(inv, "GetEquippedInventoryItem")
    if item == nil then return nil end
    return item.RootComponent
end

local last_weapon = nil
local debug_ticks = 0
local eye0 = nil
last_muzzle = nil

local last_pawn = nil
local PAWN_SETTLE_TIME = 2.0 -- seconds after a new pawn appears (checkpoint load, respawn) before we touch it
local WEAPON_SETTLE_TIME = 0 -- seconds after a weapon is equipped before we move it (was 1.5: the new weapon floated in front and the hand stayed over the shoulder; a new pawn still waits PAWN_SETTLE_TIME)
local clock, pawn_since, weapon_since = 0, 0, 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) clock = clock + delta end)

-- Collisions with the world (walls, objects): the first surface on the way from `from` (the eyes: never inside a
-- wall) to `to`, as the point `gap` cm before it - or nil when nothing is in the way. Marcus and the weapon ignored.
WORLD_CHANNEL = 1 -- the Camera trace channel: it stops at glass too (Visibility went through car windows)
WORLD_GAP = 0.5 -- cm kept from a wall (more, and it turned while it visibly had room)
PIVOT_EASE = 0.3 -- per frame: the pivot's angle eases to the wanted one (a curved surface's touch / no touch made it jump)
pivot_k, pivot_a = nil, 0 -- the eased pivot (axis, angle)
SLIDE_MAX = 20 -- cm the weapon may slide back along itself (still in a wall after the pivot: the hand right at it)
WALL_PUSH_MAX = 60 -- cm the weapon may be pushed back out of a wall along itself
WALL_EYE_CLEAR = 22 -- cm: pushed back no nearer to the eyes than this (the grip)
WALL_PUSH_SPEED = 250 -- cm/s the push back changes at most (steady, no jumps; faster = less time inside a wall)
WALL_PLANE_REACH = 40 -- cm sideways from the last surface hit that it still holds the weapon back when a trace misses
WALL_MIN_COS = 0.35 -- a barrel grazing a wall is pushed back as if this far into it (no huge or flipping pushes)
WALL_FRONT_GAP = 1.0 -- cm left between the weapon's front and the surface it is pushed against (along the barrel)
WALL_PLANE_KEEP = 0.15 -- s a surface hit is still used when the trace misses it (one-frame misses at edges)
slide_back = 0 -- eased
-- Characters (squad, enemies) are not walls: the Camera channel stops at them (measured), so world traces ignore
-- every pawn near (listed every 0.5 s). A Wretch or a squad mate between the eyes and the weapon held it back.
WORLD_IGNORE, world_ignore_t = {}, -10
function world_ignore(pawn, weapon_actor)
    if os.clock() - world_ignore_t > 0.5 then
        world_ignore_t = os.clock()
        local all = {}
        pcall(function() ucall(api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object(), "GetAllActorsOfClass", pawn, api:find_uobject("Class /Script/Engine.Pawn"), all) end)
        local me = ucall(pawn, "K2_GetActorLocation")
        local near = {}
        for _, a in ipairs(all) do
            local ok, l = pcall(function() return a:K2_GetActorLocation() end)
            if ok and (l.x - me.x) ^ 2 + (l.y - me.y) ^ 2 < 1500 * 1500 then table.insert(near, a) end
        end
        WORLD_IGNORE = near
    end
    local t = { pawn, weapon_actor }
    for _, a in ipairs(WORLD_IGNORE) do t[#t + 1] = a end
    return t
end
function world_block(pawn, weapon_actor, from, to, gap)
    local d = sub(to, from)
    local L = len(d)
    if L < 1 then return nil end
    local ok, got = pcall(ucall, kismet_system, "LineTraceSingle", pawn, Vector3d.new(from.x, from.y, from.z), Vector3d.new(to.x, to.y, to.z),
        WORLD_CHANNEL, true, world_ignore(pawn, weapon_actor), 0, hit_result, true, no_color, no_color, 0.0)
    if not ok or not got then return nil end
    local ip = hit_result.ImpactPoint
    local t = dot(sub(v(ip.X or ip.x, ip.Y or ip.y, ip.Z or ip.z), from), mul(d, 1 / L)) - gap
    if t >= L then return nil end
    return add(from, mul(d, math.max(0, t) / L))
end
-- The weapon against the world pivots in the hand, as a real one: its front comes to rest on the surface it meets
-- (WORLD_GAP above it) and slides along it, the grip stays where the hand is. Returns the turn (axis, angle) or nil:
-- nothing between the grip and the front, or the hand itself at the surface (then it is held back as before).
function pivot_on_world(pawn, weapon_actor, grip, front)
    local ok, got = pcall(ucall, kismet_system, "LineTraceSingle", pawn, Vector3d.new(grip.x, grip.y, grip.z), Vector3d.new(front.x, front.y, front.z),
        WORLD_CHANNEL, true, world_ignore(pawn, weapon_actor), 0, hit_result, true, no_color, no_color, 0.0)
    PIVOT_DBG = { hit = ok and got } -- (debug)
    if not ok or not got then return nil end
    local ip, nm = hit_result.ImpactPoint, hit_result.ImpactNormal
    local hp = v(ip.X or ip.x, ip.Y or ip.y, ip.Z or ip.z)
    local n = norm(v(nm.X or nm.x, nm.Y or nm.y, nm.Z or nm.z))
    local h = dot(sub(grip, hp), n) -- the grip's height over the surface
    PIVOT_DBG.h, PIVOT_DBG.n, PIVOT_DBG.actor = h, n, tostring(pcall(function() return hit_result.HitObjectHandle.Actor end))
    if h <= WORLD_GAP + 0.5 then return nil end
    local V = sub(front, grip)
    local L = len(V)
    local sn = (WORLD_GAP - h) / L -- how far the front may point into the surface's normal
    if sn < -1 or sn > 1 then return nil end
    local t = sub(V, mul(n, dot(V, n))) -- along the surface, the way it pointed
    if len(t) < 1e-3 then return nil end
    t = norm(t)
    local W = add(mul(t, math.sqrt(1 - sn * sn)), mul(n, sn)) -- the new direction, grip -> front
    local Vn = mul(V, 1 / L)
    PIVOT_DBG.sn, PIVOT_DBG.vn = sn, dot(Vn, n)
    if dot(Vn, n) >= sn then return nil end -- (already clear of it)
    local k = cross(Vn, W)
    local kl = len(k)
    if kl < 1e-6 then return nil end
    return mul(k, 1 / kl), math.atan(kl, dot(Vn, W))
end
function rotate_vec(k, a, p) -- p turned about the unit axis k by a (radians)
    local c, sn = math.cos(a), math.sin(a)
    return add(add(mul(p, c), mul(cross(k, p), sn)), mul(k, dot(k, p) * (1 - c)))
end

-- the nearer of two stops (from the same start)
function nearer_stop(from, a, b)
    if a == nil then return b end
    if b == nil then return a end
    return len(sub(v(a.x, a.y, a.z), from)) <= len(sub(v(b.x, b.y, b.z), from)) and a or b
end
-- Hand and weapon: the weapon taken as a rod from its stock to its front (WEAPON_ROD_RADIUS thick): a free hand
-- inside it is pushed out to its surface, the shortest way
WEAPON_ROD_RADIUS = 5.0
WEAPON_STOCK_BACK = 12.0 -- cm behind the grip
function out_of_rod(p, a, b, radius)
    local ab = sub(b, a)
    local t = math.max(0, math.min(1, dot(sub(p, a), ab) / math.max(1e-6, dot(ab, ab))))
    local q = add(a, mul(ab, t))
    local d = sub(p, q)
    local l = len(d)
    if l >= radius then return nil end
    if l < 1e-3 then d, l = v(0, 0, 1), 1 end
    return add(q, mul(d, radius / l))
end

-- every laser part on the pawn hidden (beam cylinders, dot spheres, its little lights) - also those an earlier
-- script load left (gestures.lua only knows its own): a laser hung in the air on a ladder
function hide_laser_parts(pawn)
    pcall(function()
        for _, c in ipairs(ucall(pawn, "K2_GetComponentsByClass", api:find_uobject("Class /Script/Engine.StaticMeshComponent"))) do
            pcall(function()
                local m = c.StaticMesh and c.StaticMesh:get_fname():to_string()
                if m == "Cylinder" or m == "Sphere" then c:SetVisibility(false, false) end
            end)
        end
        for _, c in ipairs(ucall(pawn, "K2_GetComponentsByClass", api:find_uobject("Class /Script/Engine.PointLightComponent"))) do
            pcall(function() if c.AttenuationRadius < 40 then c:SetVisibility(false, false) end end)
        end
    end)
end

local function update_weapon(cam_pos, cam_rot, world_to_meters, aim_eye)
    local _t = os.clock() local function SEC(n) if PROF_SEC then PROF_SEC(n, os.clock() - _t) end _t = os.clock() end
    local pawn = api:get_local_pawn(0)
    if pawn ~= last_pawn then
        -- new pawn (checkpoint load, respawn): the old one and its weapon are being destroyed, never touch them again
        last_pawn = pawn
        pawn_since = clock
        last_weapon = nil
        two_handed = false
        HELD_HANDLE = nil
        arms_request = nil
        if gestures_forget ~= nil then gestures_forget(pawn == nil) end
    end
    if pawn == nil or clock - pawn_since < PAWN_SETTLE_TIME then return end
    if not CINEMATIC then CINE_WEAPONS_RESET = false end
    if eyes_of_pawn ~= nil and eyes_of_pawn(pawn) then BODY_PAWN = pawn end
    if CINEMATIC then
        -- Marcus' weapons (also while a turret is controlled): drawn where the game holds them
        if BODY_PAWN == nil and os.clock() - (body_search_t or -10) > 2 then -- not seen yet (e.g. after a reload)
            body_search_t = os.clock()
            pcall(function()
                local found = {}
                ucall(api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object(), "GetAllActorsOfClass", pawn, api:find_uobject("Class /Script/Engine.Character"), found)
                for _, c in ipairs(found) do
                    if c:get_class():get_fname():to_string():find("Marcus") then BODY_PAWN = c break end
                end
            end)
        end
        if BODY_PAWN ~= nil then
            pcall(function()
                local list = {}
                ucall(BODY_PAWN, "GetAttachedActors", list, true, true)
                for _, a in ipairs(list) do
                    if a:get_class():get_fname():to_string():find("^BP_Wpn_") then
                        local r = a.RootComponent
                        if not CINE_WEAPONS_RESET then
                            ucall(r, "K2_SetRelativeLocationAndRotation", Vector3d.new(0, 0, 0), Vector3d.new(0, 0, 0), false, {}, true)
                        end
                        if gestures_gc_sync ~= nil then gestures_gc_sync(r) end
                    end
                end
                CINE_WEAPONS_RESET = true
            end)
        end
        -- turret: where the right controller points, in the world (the pre-tick aims the gun's shots along it)
        if VEHICLE and GROUND_TURRET then
            -- at the stand nothing of Marcus' own weapon shows (the chest magazine hung in front of the
            -- view): pouch, laser, held parts hidden - twice a second (cheap; the pouch belongs to his pawn)
            if gestures_cinematic ~= nil and os.clock() > (TURRET_HIDE_T or 0) then
                TURRET_HIDE_T = os.clock() + 0.5
                pcall(gestures_cinematic)
                -- also magazines / rounds left on him by an earlier script load (not gestures' own any more)
                pcall(function()
                    for _, c in ipairs(BODY_PAWN:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine.StaticMeshComponent")) or {}) do
                        local mn = c.StaticMesh and c.StaticMesh:get_fname():to_string() or ""
                        if (mn:find("Mag") or mn:find("shell") or mn:find("Projectile")) and c:IsVisible() then c:SetVisibility(false, false) end
                    end
                end)
            end
            -- a gun on a stand: both hands in the world, for its handles (turret.lua)
            pcall(function()
                local cf, cr, cu = rotator_axes(cam_rot)
                local hmd = device(vr.get_hmd_index())
                local right = device(eday_role_index("right"))
                local left = device(eday_role_index("left"))
                if debug_device then
                    right = debug_device("right", hmd, right, CONTROLLER_PITCH_DEG)
                    left = debug_device("left", hmd, left, CONTROLLER_PITCH_DEG, right)
                end
                local function wp(d) return add(cam_pos, hmd_to_world(mul(sub(d.pos, hmd.pos), world_to_meters), hmd, cf, cr, cu)) end
                -- the hands in the view fp.lua builds on a stand (its own frame, not the game's camera: they were ~40 cm
                -- off the handles); simulated hands (debug, only while one is set) keep the old mapping
                local function hand_at(index, d)
                    if not (debug_hands_active and debug_hands_active()) and turret_hand_world ~= nil then
                        TURRET_HAND_MAPPED = (TURRET_HAND_MAPPED or 0) + 1 -- (debug counter)
                        local p, q = UEVR_Vector3f.new(), UEVR_Quaternionf.new()
                        ;(eday_pose or vr.get_pose)(index, p, q)
                        local w = turret_hand_world(p)
                        if w ~= nil then return v(w.x, w.y, w.z) end
                    end
                    return wp(d)
                end
                if turret_ground_update ~= nil then
                    local ok_t, err_t = pcall(turret_ground_update, { pawn = pawn, R = hand_at(eday_role_index("right"), right),
                        L = hand_at(eday_role_index("left"), left), rgrip = right_grip_down(), lgrip = left_grip_down() })
                    if not ok_t then turret_errors = (turret_errors or 0) + 1 if turret_errors % 300 == 1 then log("turret: " .. tostring(err_t)) end end
                end
            end)
        elseif VEHICLE then
            pcall(function()
                local cf, cr, cu = rotator_axes(cam_rot)
                local hmd = device(vr.get_hmd_index())
                local right = device(eday_role_index("right"))
                local f, u = norm(hmd_to_world(right.f, hmd, cf, cr, cu)), norm(hmd_to_world(right.u, hmd, cf, cr, cu))
                if CONTROLLER_PITCH_DEG ~= 0 then
                    local a = math.rad(CONTROLLER_PITCH_DEG)
                    f = norm(add(mul(f, math.cos(a)), mul(u, math.sin(a))))
                end
                local pos = add(cam_pos, hmd_to_world(mul(sub(right.pos, hmd.pos), world_to_meters), hmd, cf, cr, cu))
                if not VEHICLE_AIM_FP then VEHICLE_AIM = { pos = pos, dir = f } end -- (fp.lua sets it in its own view)
            end)
            -- the gun turns (and fires) only with the game's aim: the aim follows the right controller; fp.lua keeps
            -- the view where the game's camera was before the aim moved
            -- the gun turns (and fires) with the game's aim: set straight to where the controller points. Until fp.lua
            -- has taken the view: the middle of the gun's arc (TCTurret.AimDir yaw = aim yaw - helicopter yaw + 180,
            -- kept within 25..155 by the game: measured; its middle, 90, is the helicopter's yaw - 90)
            pcall(function()
                local pc = api:get_player_controller(0)
                if not TURRET_VIEW_READY then
                    -- the middle of the gun's arc: TCTurret.AimDir yaw is kept within 25..155, relative to the
                    -- helicopter, so 90
                    local side = 1 -- (gun on the left door, socket ..._L: the arc middle is -90; fp.lua)
                    pcall(function() if ucall(pawn.RootComponent, "GetAttachSocketName"):to_string():sub(-2) == "_L" then side = -1 end end)
                    ucall(pc, "SetControlRotation", Vector3d.new(0, 90 * side, 0))
                    return
                end
                -- the turret takes its aim's yaw relative to the helicopter (measured: the gun's world yaw =
                -- helicopter yaw + aim yaw), so the helicopter's yaw comes off the controller's world direction
                -- both in the helicopter's own frame (it tilts and banks; the view goes with it): straight ahead in
                -- the view = the gun straight ahead. Up and down counts TURRET_PITCH_GAIN times (bending the wrist
                -- far down hurt).
                local d = VEHICLE_AIM.dir
                local mount = ucall(pawn.RootComponent, "GetAttachParent")
                if mount == nil then return end
                local mx, my, mz = rotator_axes(ucall(mount, "K2_GetComponentRotation"))
                local lx, ly, lz = dot(d, mx), dot(d, my), dot(d, mz)
                local pitch = math.deg(math.atan(lz, math.sqrt(lx * lx + ly * ly))) * TURRET_PITCH_GAIN + TURRET_PITCH_OFFSET
                ucall(pc, "SetControlRotation", Vector3d.new(pitch, math.deg(math.atan(ly, lx)), 0))
            end)

        end
        -- cutscene: the game holds the weapon; its drawn copy still has to follow it (it stayed in the air)
        arms_request = nil
        local w = equipped_weapon_mesh(pawn)
        if w ~= nil and gestures_gc_sync ~= nil then gestures_gc_sync(w) end
        return
    end
    if not ARMS_SCRIPT then hide_arms(pawn) end -- arms.lua draws posed arms instead

    local weapon = equipped_weapon_mesh(pawn)
    if weapon ~= last_weapon then
        weapon_since = clock
        last_weapon = weapon
        two_handed = false
        HELD_HANDLE = nil
        log("equipped: " .. (weapon and weapon:get_full_name() or "nothing"))
        -- a melee weapon (wrench, crowbar, pipe): held by its shaft (its own z axis), no foregrip, no shots
        MELEE_WEAPON = false
        pcall(function() MELEE_WEAPON = weapon ~= nil and weapon:GetOwner():get_class():get_fname():to_string():find("MeleeWeapon") ~= nil end)
        -- a pistol: no foregrip - the left hand closes over the right one on the grip (pistol_left_frame)
        PISTOL_WEAPON = false
        pcall(function()
            local cn = weapon:GetOwner():get_class():get_fname():to_string()
            for _, k in ipairs(PISTOL_CLASSES) do if cn:find(k) then PISTOL_WEAPON = true end end
        end)
    end
    -- climbing a ladder (the game puts the weapon away and animates the hands on the rungs): its own body and arms
    -- are shown, as in a cutscene, but the view stays first person; our arms, laser and pouch are set aside. (Our
    -- arms had stayed frozen in the last pose, the laser hanging in the air where it was.)
    local climbing = false
    pcall(function()
        local t = ucall(pawn, "GetComponentByClass", api:find_uobject("Class /Script/TCGameplayTags.TCGameplayTagComponent")).CachedOwnedTagContainer.GameplayTags
        for i = 1, #t do if t[i].TagName:to_string():find("Ladder") then climbing = true break end end
    end)
    -- getting off at the top: the game still animates the dismount (and takes the weapon out) after the ladder tag
    -- is gone - the game's body stays until a weapon is back in hand and LADDER_EXIT_TIME has passed (the
    -- climb looked right, the step off at the top did not)
    if climbing then ladder_seen = clock
    elseif LADDER and (clock - (ladder_seen or 0) < LADDER_EXIT_TIME or (weapon == nil and clock - (ladder_seen or 0) < LADDER_EXIT_MAX)) then climbing = true end
    if climbing ~= (LADDER or false) then
        LADDER = climbing
        log(climbing and "ladder: game's arms" or "ladder done")
        if arms_cinematic ~= nil then pcall(arms_cinematic, pawn, climbing) end
        if climbing and gestures_cinematic ~= nil then pcall(gestures_cinematic) end
    end
    if climbing then
        -- again every 30 frames: the body copies may be (re)made after the switch (a script reload), hiding the
        -- game's body again - seen: followers drawn, the real arms hidden on the ladder
        ladder_frames = (ladder_frames or 0) + 1
        if ladder_frames % 30 == 1 then
            -- straight on the pawn's meshes (arms.lua may not know its copies, e.g. after a script reload): the
            -- game's own meshes shown, every copy of ours (named *Component_<n>) hidden
            pcall(function()
                for _, c in ipairs(ucall(pawn, "K2_GetComponentsByClass", api:find_uobject("Class /Script/Engine.SkinnedMeshComponent"))) do
                    local n = c:get_fname():to_string()
                    local ours = n:find("Component_%d+$") ~= nil
                    if n ~= "HairCards" then c:SetHiddenInGame(ours, false) end
                end
            end)
            hide_laser_parts(pawn)
        end
        arms_request = nil
        return
    end
    if weapon == nil or clock - weapon_since < WEAPON_SETTLE_TIME then
        -- nothing (or a new weapon still settling) in hand: gestures.lua's drawn copy of the last weapon (the pump gun's,
        -- shown every frame while TRIGGER_WEAPON points at it) must not stay drawn on the holstered gun
        TRIGGER_WEAPON = nil
        if weapon == nil and not VEHICLE and arms_hide_loose_weapons ~= nil then -- (not on a turret: its own gun is "loose" on it)
            pcall(arms_hide_loose_weapons, pawn) end
        if gestures_cinematic ~= nil and not laser_off_done then pcall(gestures_cinematic) hide_laser_parts(pawn) laser_off_done = true end -- (no weapon: no laser left hanging)
        arms_request = nil
        return
    end
    laser_off_done = false

    -- headset -> camera mapping
    local cf, cr, cu = rotator_axes(cam_rot)
    local hmd = device(vr.get_hmd_index())
    local right = device(eday_role_index("right"))
    local left = device(eday_role_index("left"))
    if GRIP_DEBUG then
        -- grip test: the left controller held still 40 cm in front of the eyes, like holding a controller
        local fwd = norm(v(hmd.f.x, hmd.f.y, 0))
        local rgt = v(-fwd.y, fwd.x, 0)
        local gp = GRIP_DEBUG_POS or { 0.40, -0.08, -0.12 }
        local hpos = add(hmd.pos, add(mul(fwd, gp[1]), add(mul(rgt, gp[2]), v(0, 0, gp[3]))))
        local yaw = math.rad(GRIP_DEBUG_YAW or 0) -- turn the hand about the vertical to look at it from the side
        fwd, rgt = add(mul(fwd, math.cos(yaw)), mul(rgt, math.sin(yaw))), add(mul(rgt, math.cos(yaw)), mul(fwd, -math.sin(yaw)))
        local a = math.rad(-CONTROLLER_PITCH_DEG)
        local f_raw = norm(add(mul(fwd, math.cos(a)), mul(v(0, 0, 1), math.sin(a))))
        local u_raw = norm(sub(mul(v(0, 0, 1), math.cos(a)), mul(fwd, math.sin(a))))
        left = { pos = hpos, f = f_raw, u = u_raw, r = cross(u_raw, f_raw) }
    end
    if debug_device then -- simulated hands (development): before the smoothing, so it can be measured too
        right = debug_device("right", hmd, right, CONTROLLER_PITCH_DEG)
        left = debug_device("left", hmd, left, CONTROLLER_PITCH_DEG, right)
    end
    right = smooth_device("right", right)
    left = smooth_device("left", left)
    local scale = world_to_meters

    local function world_pos(dev) return add(cam_pos, hmd_to_world(mul(sub(dev.pos, hmd.pos), scale), hmd, cf, cr, cu)) end
    -- the play space in the world (tracking origin and axes): stick turning and walking move it, the head does not
    local room = { pos = sub(cam_pos, hmd_to_world(mul(hmd.pos, scale), hmd, cf, cr, cu)),
                   x = hmd_to_world(v(1, 0, 0), hmd, cf, cr, cu), y = hmd_to_world(v(0, 1, 0), hmd, cf, cr, cu),
                   z = hmd_to_world(v(0, 0, 1), hmd, cf, cr, cu) }
    local rh = world_pos(right)
    local lh = world_pos(left)
    local f = norm(hmd_to_world(right.f, hmd, cf, cr, cu))
    local u = norm(hmd_to_world(right.u, hmd, cf, cr, cu))

    if CONTROLLER_PITCH_DEG ~= 0 then
        local a = math.rad(CONTROLLER_PITCH_DEG)
        f, u = norm(add(mul(f, math.cos(a)), mul(u, math.sin(a)))), norm(sub(mul(u, math.cos(a)), mul(f, math.sin(a))))
    end
    RIGHT_CTRL_FRAME = { pos = rh, x = f, y = cross(u, f), z = u } -- (the free right hand: arms.lua shapes it around this)

    -- Controllers relative to the headset (cm, on the flat head direction), for the body zones of the gestures.
    local hf = norm(v(hmd.f.x, hmd.f.y, 0))
    local hr = v(-hf.y, hf.x, 0)
    local function head_rel(dev)
        local d = mul(sub(dev.pos, hmd.pos), 100)
        return { fwd = dot(d, hf), right = dot(d, hr), up = d.z }
    end
    local r0 = cross(u, f)
    if debug_device then DEBUG_HANDS = { rh = rh, lh = lh, f = f, u = u } end -- for zz_debug.lua (development only)
    local gesture_ctx = {
        pawn = pawn, weapon = weapon, left_pos = lh, right_pos = rh, cam_pos = cam_pos, cam_fwd = norm(v(cf.x, cf.y, 0)),
        left_head = head_rel(left), right_head = head_rel(right),
        -- the weapon as it is on screen right now (it is shown one frame late, see below)
        weapon_frame = { pos = copy(ucall(weapon, "K2_GetComponentLocation")), x = copy(ucall(weapon, "GetForwardVector")),
                         y = copy(ucall(weapon, "GetRightVector")), z = copy(ucall(weapon, "GetUpVector")) },
    }
    do -- the left controller's frame, also for the grip presses below (the pump hold turns with it)
        local lf, lu = norm(hmd_to_world(left.f, hmd, cf, cr, cu)), norm(hmd_to_world(left.u, hmd, cf, cr, cu))
        if CONTROLLER_PITCH_DEG ~= 0 then
            local a = math.rad(CONTROLLER_PITCH_DEG)
            lf, lu = norm(add(mul(lf, math.cos(a)), mul(lu, math.sin(a)))), norm(sub(mul(lu, math.cos(a)), mul(lf, math.sin(a))))
        end
        gesture_ctx.left_frame = { pos = lh, x = lf, y = cross(lu, lf), z = lu }
    end

    -- Right grip: weapon switch gestures (gestures.lua). With the weapon in the hand, the grip over the right shoulder
    -- puts it on the back (RIGHT_FREE: the game keeps it equipped, it is only hidden and its trigger held off; nothing in the
    -- game's inventory changes). The free hand takes a grenade (grenade.lua), the weapon back over a shoulder, or the
    -- pistol at the hip.
    local rgrip = right_grip_down()
    RIGHT_GRIP_DOWN = rgrip -- arms.lua closes the free right hand while it is held
    if rgrip and not right_grip_was_down then
        local rz = gesture_ctx.right_head
        local over_shoulder = rz.up > -35 and rz.fwd < 5
        log(string.format("right grip pressed at head fwd %.0f right %.0f up %.0f (free %s)", rz.fwd, rz.right, rz.up, tostring(RIGHT_FREE)))
        if RIGHT_FREE then
            if grenade_right_pressed ~= nil and grenade_right_pressed(gesture_ctx) then
                -- (grenade.lua: the grenade on the body taken)
            elseif over_shoulder then
                RIGHT_FREE = false
                log("weapon taken back from the back")
            elseif gestures_right_pressed ~= nil and gestures_right_pressed(gesture_ctx) then
                RIGHT_FREE = false -- (the pistol from the hip)
            end
        elseif not (gestures_right_pressed ~= nil and gestures_right_pressed(gesture_ctx)) and over_shoulder then
            -- only over the shoulder, the same place it is taken back from (not wherever the grip is pressed)
            RIGHT_FREE = true
            two_handed = false
            HELD_HANDLE = nil
            log("weapon put on the back: right hand free")
        end
    elseif not rgrip and right_grip_was_down then
        if grenade_right_released ~= nil then grenade_right_released(gesture_ctx) end
    end
    right_grip_was_down = rgrip
    -- the weapon hidden while it is "on the back" (shown again when taken); the one hidden is remembered, so the right
    -- one is shown again after a switch (pistol from the hip, the grenade's throw equipping the grenade for a moment)
    local owner_now = weapon:GetOwner()
    if RIGHT_FREE then
        -- (kept hidden: the game shows a weapon again when it is equipped - switched away and back to the one put on
        -- the back, it floated by the free hand)
        if right_free_actor ~= owner_now or not owner_now.bHidden then
            pcall(function() owner_now:SetActorHiddenInGame(true) end)
            if right_free_actor == nil then right_free_actor = owner_now end
        end
    elseif right_free_actor ~= nil then
        pcall(function() right_free_actor:SetActorHiddenInGame(false) end)
        pcall(function() owner_now:SetActorHiddenInGame(false) end)
        right_free_actor = nil
    elseif not RIGHT_FREE_CHECKED then
        -- first frame after a script reload: a weapon left hidden "on the back" by the previous load is shown again
        RIGHT_FREE_CHECKED = true
        if owner_now.bHidden then pcall(function() owner_now:SetActorHiddenInGame(false) end) log("weapon left hidden by an earlier load: shown") end
    end

    -- Left grip: magazine (gestures.lua) first, otherwise grab / release the foregrip.
    local grip_down = left_grip_down()
    LEFT_GRIP_DOWN = grip_down -- arms.lua closes the empty hand while it is held
    LEFT_FIST_LIMIT = (two_handed and PISTOL_WEAPON) and PISTOL_LEFT.curl or nil -- (the pistol's cup: fingers only half closed)
    LEFT_HAND_POS, TWO_HANDED = lh, two_handed -- saw.lua: the fist's punches
    if grip_down and not left_grip_was_down then
        -- a pistol: only a little under the grip's butt, where the left palm goes (just the bottom part - a bigger
        -- zone took the presses meant for the pistol's magazine). Right at it the grab is the pistol's before any gesture
        -- (held low, the hand was also in the chest pouch's zone, which took the press: "no spare ammo").
        local pistol_d = nil
        if PISTOL_WEAPON then
            local pl = PISTOL_LEFT.palm
            local palm = to_world(sub(rh, to_world(v(0, 0, 0), f, r0, u, GRIP)), f, r0, u, v(pl[1], pl[2], pl[3]))
            pistol_d = len(sub(lh, palm))
        end
        local pistol_near = pistol_d ~= nil and pistol_d < PISTOL_FIRST_CM
        if grenade_left_pressed ~= nil and grenade_left_pressed(gesture_ctx) then
            -- (grenade.lua: the grenade on the body taken)
        elseif RIGHT_FREE then
            -- (the weapon is on the back: nothing on it to take)
        elseif pistol_near or not (gestures_left_pressed ~= nil and gestures_left_pressed(gesture_ctx)) then
            -- a big weapon's own handles (handles.lua: the Vulcan's top bar and side handle)
            HELD_HANDLE = nil
            -- the weapon AS DRAWN (after starting the chainsaw the front grab failed / took the lever):
            -- the running saw holds the drawn weapon back at bodies (up to 20+ cm), and the foregrip was measured on the
            -- weapon where the right controller would put it - the hand on the front the player sees was 'too far',
            -- while the lever (gestures.lua, drawn weapon) was near. Everything the hand takes: on the drawn weapon.
            local wd = gesture_ctx.weapon_frame
            if handles_pick ~= nil and weapon ~= nil and not PISTOL_WEAPON then
                local ok_h, h = pcall(handles_pick, weapon, wd, lh)
                if ok_h and h ~= nil then HELD_HANDLE = h end
                BOLT_D0 = len(sub(lh, rh)) -- (a handle that loads: the hands' distance at the grab = not pulled)
            end
            local foregrip = to_world(wd.pos, wd.x, wd.y, wd.z, FOREGRIP)
            local d = pistol_d or len(sub(lh, foregrip))
            two_handed = HELD_HANDLE ~= nil or (d < (PISTOL_WEAPON and PISTOL_GRAB_CM or GRAB_RADIUS_CM) and not MELEE_WEAPON)
            log(string.format("left grip pressed %.1f cm from foregrip -> %s", d, HELD_HANDLE and ("handle " .. HELD_HANDLE.name) or (two_handed and "grabbed" or "too far")))
        end
    elseif not grip_down and left_grip_was_down then
        if grenade_left_released ~= nil and grenade_left_released(gesture_ctx) then
            -- (grenade.lua: thrown, or put back)
        elseif not (gestures_left_released ~= nil and gestures_left_released(gesture_ctx)) and two_handed then
            two_handed = false
            HELD_HANDLE = nil
            log("foregrip released")
        end
    end
    left_grip_was_down = grip_down

    if not two_handed then BOLT_PULL = 0 end
    if two_handed and not PISTOL_WEAPON then -- (a pistol is aimed by the right hand alone; the left only holds on)
        -- Aim along the line between the hands, keeping the right hand's roll.
        local fore = HELD_HANDLE and HELD_HANDLE.p or FOREGRIP
        -- a handle that loads (handles.lua bolt, Heavy Boomshot): bringing the left hand towards the right one slides
        -- it back (BOLT_PULL, cm; gestures.lua blocks firing after a shot until it went back and forward again)
        BOLT_PULL = 0
        if HELD_HANDLE ~= nil and HELD_HANDLE.bolt ~= nil then
            local dh = len(sub(lh, rh))
            local now = os.clock()
            local dt = now - (BOLT_T or now)
            if dt > 0.004 then -- (once per frame: this runs for each eye)
                BOLT_T = now
                local speed = math.abs(dh - (BOLT_LAST or dh)) / math.min(dt, 0.1)
                BOLT_LAST = dh
                BOLT_D0 = math.max(BOLT_D0 or dh, dh) -- (the hand further out than at the grab: that is the rest)
                -- the arm held still (under 3 cm/s): the rest follows it at 2 cm/s (a grab with the arm stretched, then
                -- relaxed, would read as pulled forever); while the hand moves - a pull - it stays
                if speed < 3 then BOLT_D0 = math.max(dh, BOLT_D0 - 2 * math.min(dt, 0.1)) end
            end
            BOLT_PULL = math.max(0, math.min(HELD_HANDLE.bolt.travel, BOLT_D0 - dh))
            fore = v(fore.x - BOLT_PULL, fore.y, fore.z)
        end
        local grip_to_fore = sub(fore, GRIP)
        f = norm(sub(lh, rh))
        u = norm(sub(u, mul(f, dot(u, f))))
        -- the foregrip is not exactly on the weapon's X axis: rotate so the grip->foregrip line hits the left hand
        local r = cross(u, f)
        f = norm(sub(sub(f, mul(r, grip_to_fore.y / grip_to_fore.x)), mul(u, grip_to_fore.z / grip_to_fore.x)))
        u = norm(sub(u, mul(f, dot(u, f))))
    end

    local r = cross(u, f)
    local origin = sub(rh, to_world(v(0, 0, 0), f, r, u, GRIP))
    -- collisions (saw.lua): the weapon's front stops at an enemy's body instead of going through it (the whole
    -- weapon held back with it; the hands follow it, as they follow the weapon)
    -- and at walls and objects (the nearer of the two)
    if melee_block ~= nil and weapon ~= nil then
        local fl = melee_front_local(weapon)
        local front = add(origin, add(mul(f, fl[1]), add(mul(r, fl[2]), mul(u, fl[3]))))
        WEAPON_RAW_FRONT = front -- (saw.lua: blows on walls - the drawn weapon stops before them)
        -- a wall or object: the weapon follows the hand but its front never goes past the surface - it is pulled back
        -- along itself by exactly how far it went in (seen from the eyes, which are never inside a wall: traces from
        -- the grip started inside walls and found nothing, and weapon, hands and arms went through and vanished).
        -- Continuous, so no jumps; free sideways. (the turn on the surface jumped the weapon up, a full stop
        -- left it stuck - both gone.)
        local wa = weapon:GetOwner()
        local ok_t, got = pcall(ucall, kismet_system, "LineTraceSingle", pawn, Vector3d.new(cam_pos.x, cam_pos.y, cam_pos.z), Vector3d.new(front.x, front.y, front.z),
            WORLD_CHANNEL, true, world_ignore(pawn, wa), 0, hit_result, true, no_color, no_color, 0.0)
        local want_back = v(0, 0, 0)
        -- The surface the front is behind: this frame's hit, or the last one. The trace missed now and then (an edge,
        -- a thin car panel the front went past) or met a nearer surface the front was in front of: recorded while
        -- pushing, the wanted push fell 30 -> 0 for a frame and the weapon went in and out. The last surface still
        -- counts while the front is behind it and the hand has not moved off it sideways; the deeper one wins.
        local hp, n = nil, nil
        local function plane_depth(pl)
            local q = sub(front, pl.p)
            local side = sub(q, mul(pl.n, dot(q, pl.n)))
            if len(side) >= WALL_PLANE_REACH then return nil end
            return dot(q, pl.n)
        end
        local cur = nil
        if ok_t and got then
            local ip, nm = hit_result.ImpactPoint, hit_result.ImpactNormal
            cur = { p = v(ip.X or ip.x, ip.Y or ip.y, ip.Z or ip.z), n = norm(v(nm.X or nm.x, nm.Y or nm.y, nm.Z or nm.z)) }
        end
        local dc = cur and plane_depth(cur) or nil
        -- (a remembered surface is an endless plane: kept longer, it pushed the weapon back with no wall in front -
        -- only a brief miss is bridged)
        if wall_plane ~= nil and os.clock() - (wall_plane.t or 0) > WALL_PLANE_KEEP then wall_plane = nil end
        local dl = wall_plane and plane_depth(wall_plane) or nil
        if dl ~= nil and dl >= WORLD_GAP then dl, wall_plane = nil, nil end -- (the front is out of it: forgotten)
        if dc ~= nil and (dl == nil or dc <= dl) then
            hp, n = cur.p, cur.n
            if dc < WORLD_GAP then wall_plane = cur cur.t = os.clock() end
        elseif dl ~= nil then
            hp, n = wall_plane.p, wall_plane.n
        end
        if hp ~= nil then
            local depth = dot(sub(front, hp), n) - WORLD_GAP -- < 0: the front is that far behind the surface
            local fn = dot(f, n)
            if depth < 0 then
                -- back along the barrel to the surface, always (switching to "out along the normal" for a barrel nearly
                -- parallel to the wall turned a 30 cm push by ~75 deg in one frame: a jump); grazing, it counts the
                -- barrel as at least WALL_MIN_COS into the surface, so the amount stays finite and continuous
                local back = mul(f, math.min(WALL_PUSH_MAX, -depth / math.max(-fn, WALL_MIN_COS)))
                -- never into the face (it may come closer, but must not cover the view): the grip stays at
                -- least WALL_EYE_CLEAR from the eyes - pushed less, the front may then stay in the wall
                local k = 1.0
                for _ = 1, 12 do
                    if len(sub(sub(origin, mul(back, k)), cam_pos)) >= WALL_EYE_CLEAR or k <= 0 then break end
                    k = k - 0.1
                end
                want_back = mul(back, math.max(0, k))
                -- 1 cm from the surface: the push from the surface's plane was too much where the surface
                -- curves or is met at a slant (a visible gap). From the pushed front, along the barrel: whatever room
                -- is left to the surface beyond WALL_FRONT_GAP is given back.
                local s_back = len(want_back)
                if s_back > 0.01 then
                    local pf = sub(front, want_back)
                    local ok2, got2 = pcall(ucall, kismet_system, "LineTraceSingle", pawn, Vector3d.new(pf.x, pf.y, pf.z),
                        Vector3d.new(pf.x + f.x * (s_back + 5), pf.y + f.y * (s_back + 5), pf.z + f.z * (s_back + 5)),
                        WORLD_CHANNEL, true, world_ignore(pawn, wa), 0, hit_result, true, no_color, no_color, 0.0)
                    if ok2 and got2 and hit_result.Distance > WALL_FRONT_GAP then
                        want_back = mul(f, math.max(0, s_back - (hit_result.Distance - WALL_FRONT_GAP)))
                    end
                end
            end
        end
        -- linear (it must come linearly, not jump): the surface the trace meets changes at edges and corners,
        -- and the wanted push jumped (21 -> 0 -> 60 cm from one frame to the next). The push follows it at a steady
        -- speed, along the weapon (its amount; the direction is the latest wanted one).
        local now_w = os.clock()
        local dt_w = wall_push_t and math.min(now_w - wall_push_t, 0.1) or 0
        wall_push_t = now_w
        local want_s = len(want_back)
        local step = WALL_PUSH_SPEED * dt_w -- linear: at most this far per frame, in or out
        wall_push_s = (wall_push_s or 0) + math.max(-step, math.min(step, want_s - (wall_push_s or 0)))
        if wall_push_s < 0.05 then wall_push_s = 0 end
        if wall_push_s > 0 then
            local back = mul(f, wall_push_s) -- (along this frame's barrel: a direction kept from an earlier frame jumped when the hand turned)
            origin, front = sub(origin, back), sub(front, back)
        end
        WALL_PUSH = wall_push_s
        if WALL_REC ~= nil and #WALL_REC < 3000 then -- (debug: per-frame record, tools/dbg.sh)
            table.insert(WALL_REC, { os.clock(), rh.x, rh.y, rh.z, origin.x, origin.y, origin.z, want_s, wall_push_s,
                ok_t and got and 1 or 0, cam_pos.x, cam_pos.y, cam_pos.z, f.x, f.y, f.z })
        end
        -- an enemy: held back towards the eyes - only a melee weapon or the running chainsaw (they must be felt to
        -- land / to cut). Guns pass through bodies: a Wretch jumping on Marcus pushed the held gun left and right.
        -- Blows with a gun still land (saw.lua: a fast swing whose front goes through a body hits it).
        local stop = (MELEE_WEAPON or CHAINSAW_HOLD) and melee_block(cam_pos, front, melee_depth()) or nil
        if stop ~= nil then origin = add(origin, sub(v(stop.x, stop.y, stop.z), front)) end
    end

    -- Arms (arms.lua): right hand on the weapon, left hand on the foregrip or on the left controller.
    -- The hands only reach the screen one frame after their request (see arms.lua), so the weapon is shown one frame
    -- late as well, from the same request. Requests are kept in Marcus' own space: he moves during the engine tick in
    -- between, and world positions would let the hands slide along the weapon while walking.
    local weapon_frame = { pos = origin, x = f, y = r, z = u }
    local shown = weapon_frame
    local actor = actor_frame(pawn)
    if ARMS_SCRIPT then
        local lf, lu = norm(hmd_to_world(left.f, hmd, cf, cr, cu)), norm(hmd_to_world(left.u, hmd, cf, cr, cu))
        if CONTROLLER_PITCH_DEG ~= 0 then
            local a = math.rad(CONTROLLER_PITCH_DEG)
            lf, lu = norm(add(mul(lf, math.cos(a)), mul(lu, math.sin(a)))), norm(sub(mul(lu, math.cos(a)), mul(lf, math.sin(a))))
        end
        local lr = cross(lu, lf)
        LEFT_HAND_FWD = lf -- saw.lua: the knuckles are along it
        -- collisions (saw.lua): the free hand's knuckles stop at an enemy's body
        local lh_shown = lh
        if melee_block ~= nil and not two_handed and not (gestures_hand_full ~= nil and gestures_hand_full()) then
            local knuckles = add(lh, mul(lf, FIST_KNUCKLES))
            local stop = nearer_stop(cam_pos, melee_block(cam_pos, knuckles, 1.5), world_block(pawn, weapon:GetOwner(), cam_pos, knuckles, WORLD_GAP))
            if stop ~= nil then lh_shown = add(lh, sub(v(stop.x, stop.y, stop.z), knuckles)) end
            -- and not into the weapon (as it is held this frame): the middle of the hand pushed out of its rod
            local fl = melee_front_local(weapon)
            local front = add(origin, add(mul(f, fl[1]), add(mul(r, fl[2]), mul(u, fl[3]))))
            local stock = sub(origin, mul(f, WEAPON_STOCK_BACK))
            local palm = add(lh_shown, mul(lf, FIST_KNUCKLES * 0.5))
            local out = out_of_rod(palm, stock, front, WEAPON_ROD_RADIUS)
            if out ~= nil then lh_shown = add(lh_shown, sub(out, palm)) end
        end
        local left_controller = { pos = lh_shown, x = lf, y = lr, z = lu } -- free left hand: arms.lua shapes it around this
        local left_frame = two_handed and weapon_frame or { pos = sub(lh_shown, to_world(v(0, 0, 0), lf, lr, lu, FOREGRIP)), x = lf, y = lr, z = lu }
        local flat_f = norm(v(cf.x, cf.y, 0))
        local cam_frame = { pos = cam_pos, x = flat_f, y = v(-flat_f.y, flat_f.x, 0), z = v(0, 0, 1) }
        local rig_fix = nil
        if arms_request ~= nil and arms_request.weapon_object == weapon and arms_request.pawn == pawn then
            shown = compose(actor, arms_request.weapon_local)
            -- carried along with the play space since that request (stick turning): weapon and arms stay where the
            -- hands are in the room instead of trailing one frame of turning behind the view (lag + shake)
            if arms_request.room_local ~= nil and not RIG_FIX_OFF then
                rig_fix = { from = compose(actor, arms_request.room_local), to = room }
                shown = compose(room, relative(rig_fix.from, shown))
            end
        end
        RIG_FIX = rig_fix -- arms_replace_copies moves the drawn arms the same way
        arms_request = { pawn = pawn, weapon_object = weapon, weapon_local = relative(actor, weapon_frame),
                         left_local = relative(actor, left_frame), cam_local = relative(actor, cam_frame), left_holding = two_handed,
                         left_fingers_closed = two_handed and not PISTOL_WEAPON and HELD_HANDLE == nil, left_holding_mag = gestures_hand_full ~= nil and gestures_hand_full(),
                         right_free = RIGHT_FREE == true or weapon.GetBoneIndex == nil, -- (empty hands: the right fist like a weapon on the back)
                         right_controller_local = RIGHT_CTRL_FRAME and relative(actor, RIGHT_CTRL_FRAME) or nil,
                         left_controller_local = relative(actor, left_controller),
                         room_local = relative(actor, room),
                         left_lock_local = (function()
                             -- the hand locked onto the weapon (magazine, handle): carried onto the weapon as it will be drawn
                             if two_handed and PISTOL_WEAPON then return relative(actor, pistol_left_frame(weapon_frame)) end
                             -- a handle (handles.lua): the fist on it
                             if two_handed and HELD_HANDLE ~= nil and handles_left_frame ~= nil then
                                 local h = HELD_HANDLE
                                 if (BOLT_PULL or 0) > 0 then -- (the fist goes back with the rod)
                                     h = { name = h.name, p = v(h.p.x - BOLT_PULL, h.p.y, h.p.z), a = h.a, half = h.half, over = h.over }
                                 end
                                 local ok_h, hf = pcall(handles_left_frame, weapon_frame, h, left_controller)
                                 if ok_h and hf ~= nil then return relative(actor, hf) end
                             end
                             if gestures_left_hand_lock == nil then return nil end
                             local lk, lwf = gestures_left_hand_lock()
                             if lk == nil then return nil end
                             if lwf ~= nil then lk = compose(weapon_frame, relative(lwf, lk)) end
                             return relative(actor, lk)
                         end)() }
    end

    local rot = rot_from_xz(Vector3d.new(shown.x.x, shown.x.y, shown.x.z), Vector3d.new(shown.z.x, shown.z.y, shown.z.z))
    ucall(weapon, "K2_SetWorldLocationAndRotation", Vector3d.new(shown.pos.x, shown.pos.y, shown.pos.z), rot, false, {}, true)
    if arms_replace_copies ~= nil then arms_replace_copies(pawn) end
    SEC("weapon: controllers + request")
    if ARMS_SCRIPT then place_attachments(pawn, weapon) end
    SEC("weapon: place weapon + attachments")
    if LASER_TOGGLE_REQUEST then
        LASER_TOGGLE_REQUEST = false
        if laser_toggle ~= nil then laser_toggle(weapon) end
    end
    if gestures_weapon_placed ~= nil then gestures_weapon_placed(weapon) end
    SEC("weapon: weapon placed hook (GC, laser)")

    -- magazine in the left hand (gestures.lua)
    if gestures_update ~= nil then
        local lf, lu = norm(hmd_to_world(left.f, hmd, cf, cr, cu)), norm(hmd_to_world(left.u, hmd, cf, cr, cu))
        if CONTROLLER_PITCH_DEG ~= 0 then
            local a = math.rad(CONTROLLER_PITCH_DEG)
            lf, lu = norm(add(mul(lf, math.cos(a)), mul(lu, math.sin(a)))), norm(sub(mul(lu, math.cos(a)), mul(lf, math.sin(a))))
        end
        gesture_ctx.left_frame = { pos = lh, x = lf, y = cross(lu, lf), z = lu }
        gestures_update(gesture_ctx)
        if grenade_update ~= nil then
            local ok_g, err_g = pcall(grenade_update, gesture_ctx)
            if not ok_g then grenade_errors = (grenade_errors or 0) + 1 if grenade_errors % 300 == 1 then log("grenade: " .. tostring(err_g)) end end
        end
        SEC("weapon: gestures")
    end

    -- Shots. The game fires from its own third person camera (behind and right of Marcus) along the control rotation.
    -- So find what the sights point at (a trace along the sight line: with front and rear sight lined up, the aiming
    -- eye is on it, parallel to the barrel) and turn the control rotation so the camera's ray hits that same point.
    local pc = api:get_player_controller(0)
    local pcm = pc ~= nil and pc.PlayerCameraManager or nil
    if pcm == nil then return end
    local game_cam = copy(ucall(pcm, "GetCameraLocation"))
    -- along the barrel from the muzzle (where the laser goes), not from the eye: the shots must land on the laser dot
    local from = aim_eye
    pcall(function() from = copy(eday_muzzle_pos(weapon) or ucall(weapon, "GetSocketLocation", ucall(kismet_string, "Conv_StringToName", "b_muzzle"))) end)
    local sight_end = add(from, mul(f, MAX_SHOT_CM))
    local target = sight_end
    local ok_trace, hit = pcall(function()
        return ucall(kismet_system, "LineTraceSingle", pawn, Vector3d.new(from.x, from.y, from.z), Vector3d.new(sight_end.x, sight_end.y, sight_end.z),
            0, true, { weapon:GetOwner(), pawn }, 0, hit_result, true, no_color, no_color, 0.0)
    end)
    if ok_trace and hit then
        local p = hit_result.ImpactPoint
        target = v(p.X or p.x, p.Y or p.y, p.Z or p.z)
    end
    local shot_dir = norm(sub(target, game_cam))
    SHOT_FROM = { eye = aim_eye, dir = norm(sub(target, aim_eye)) } -- the pre-tick hands these to the game's targeting
    SHOT_POINT = target -- where the shot lands (scope.lua centres its reticle on it)
    last_target_info = string.format("trace %s, target %.0f cm from eye", ok_trace and tostring(hit) or ("error " .. tostring(hit)), len(sub(target, aim_eye)))
    last_muzzle = game_cam
    last_barrel = shot_dir

    SEC("weapon: sight trace")
    -- Control rotation: hand UEVR the shot direction as the aim ray, in VR tracking space (OpenVR axes, metres).
    local function to_vr(w) -- world direction -> UE-axes VR direction -> OpenVR axes
        local d = add(mul(hmd.f, dot(w, cf)), add(mul(hmd.r, dot(w, cr)), mul(hmd.u, dot(w, cu))))
        return d.y, d.z, -d.x
    end
    local dx, dy, dz = to_vr(mul(shot_dir, -1)) -- UEVR's aim ray points along the aim pose's +Z, which is backwards
    -- paused (menu) or headset asleep: the aim stays as it was, so the game's camera does not turn on its own
    if AIM_FROZEN and last_aim_str ~= nil then
        vr.set_mod_value("VR_AimOverride", last_aim_str)
    else
        last_aim_str = string.format("%f %f %f %f %f %f", right.pos.y, right.pos.z, -right.pos.x, dx, dy, dz)
        vr.set_mod_value("VR_AimOverride", last_aim_str)
    end

    -- temporary diagnostics, every ~2 s: positions relative to the camera (forward, right, up)
    debug_ticks = debug_ticks + 1
    if debug_ticks % 150 == 0 then
        local function loc(p) local q = sub(p, cam_pos) return string.format("(%.0f,%.0f,%.0f)", dot(q, cf), dot(q, cr), dot(q, cu)) end
        log("rh=" .. loc(rh) .. " lh=" .. loc(lh) .. " gun=" .. loc(copy(ucall(weapon, "K2_GetComponentLocation"))) ..
            string.format(" aim=(%.2f,%.2f,%.2f) z=(%.2f,%.2f,%.2f) ", dot(f, cf), dot(f, cr), dot(f, cu), dot(u, cf), dot(u, cr), dot(u, cu)) .. tostring(last_target_info))
    end
end

local errors = 0

-- temporary check: does the game still see our point of view when its tick starts?
local check_ticks = 0
uevr.sdk.callbacks.on_pre_engine_tick(function()
    check_ticks = check_ticks + 1
    if check_ticks % 150 ~= 0 or last_muzzle == nil then return end
    local pc = api:get_player_controller(0)
    if pc == nil or pc.PlayerCameraManager == nil then return end
    local c = copy(ucall(pc.PlayerCameraManager, "GetCameraLocation"))
    local cr = ucall(pc, "GetControlRotation")
    local p, y = math.rad(cr.x), math.rad(cr.y)
    local aim = v(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p))
    log(string.format("tick start: camera %.1f cm from last frame's, control rotation %.1f deg from shot direction",
        len(sub(c, last_muzzle)), math.deg(math.acos(math.max(-1, math.min(1, dot(aim, last_barrel)))))))
end)

-- Development only (set by hand: tools/dbg.sh 'DEBUG_DRIVE = true'; zz_debug.lua does not set it): with the headset asleep nothing is rendered and the view
-- callbacks stop; this runs the weapon / hands update from the game camera instead, so tests can still run.
-- DEBUG_DRIVE = "post": after the engine tick instead, the order the headset's view callback has (arms before
-- the tick, the weapon after it) - for timing tests (lag when turning)
local function debug_drive(when)
    if not DEBUG_DRIVE or vr.is_runtime_ready() or (DEBUG_DRIVE == "post") ~= (when == "post") then return end
    local pc = api:get_player_controller(0)
    if pc == nil or pc.PlayerCameraManager == nil then return end
    local c = copy(ucall(pc.PlayerCameraManager, "GetCameraLocation"))
    local pawn = api:get_local_pawn(0)
    if fp_eye_position ~= nil and pawn ~= nil then c = copy(fp_eye_position(pawn)) end
    local r = ucall(pc, "GetControlRotation")
    local ok, err = pcall(update_weapon, c, r, 100.0, c)
    if not ok then DEBUG_DRIVE_ERROR = tostring(err) end
end
uevr.sdk.callbacks.on_pre_engine_tick(function() debug_drive("pre") end)
uevr.sdk.callbacks.on_post_engine_tick(function() debug_drive("post") end)

-- After the final eye positions are known (second eye), before rendering.
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device_ptr, view_index, world_to_meters, position, rotation, is_double)
    if view_index == 0 then
        eye0 = copy(position)
        return
    end
    if eye0 == nil then return end

    local center = mul(add(eye0, copy(position)), 0.5)
    -- view 1 is the right eye: the one that looks down the sights when the weapon is in the right hand
    local ok, err = xpcall(update_weapon, function(e) return debug and debug.traceback(tostring(e), 2) or tostring(e) end, center, rotation, world_to_meters, copy(position))
    if not ok then
        errors = errors + 1
        if errors <= 5 then log("error: " .. tostring(err)) end
    end
    -- the weapon is where it is shown now: the chainsaw's blade (saw.lua) is traced from here
    if saw_after_weapon ~= nil then saw_after_weapon() end
end)

-- While the left hand holds the foregrip, its grip must not also press LB in the game.
-- A (right controller): drops the magazine instead of the game's dodge/roll; in menus and when paused it stays A
local XINPUT_GAMEPAD_A = 0x1000
local XINPUT_GAMEPAD_B = 0x2000
local XINPUT_GAMEPAD_X = 0x4000

-- The game's crosshair is not needed in VR (the weapon is aimed by hand): kept hidden.
local CROSSHAIR_CLASSES = { -- the crosshair, and the focus-zone corners shown around it when aiming
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Crosshair/CrosshairWidget.CrosshairWidget_C",
    -- the red cog in the middle of the screen when hurt (Crimson Omen); the blood around the edges stays
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Omen/OmenV4/BP_UIWidget_OmenV4.BP_UIWidget_OmenV4_C",
    -- the weapon / ammo panel (top right; in VR it hung near the aim), the weapon list on a switch, "no ammo", the
    -- subtitles
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Weapon/Inventory/BP_UIWidget_ActiveItemDisplay.BP_UIWidget_ActiveItemDisplay_C",
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Weapon/Inventory/InventorySwitcher/BP_UIWidget_InventorySwitcher.BP_UIWidget_InventorySwitcher_C",
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Crosshair/BP_UIWidget_NoAmmo.BP_UIWidget_NoAmmo_C",
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Weapon/Inventory/SpecialGear/BP_UIWidget_SpecialGear.BP_UIWidget_SpecialGear_C", -- the cog with "C"
    "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/Subtitles/BP_UIWidget_SubtitlesOverlay.BP_UIWidget_SubtitlesOverlay_C",
    -- (the objective icon is shown again: with the game's aim on the head it stays in its place)
}
local CROSSHAIR_NAMES = { BP_UIWidget_PingZones = true, DisplayedStateWidget = true } -- (DisplayedStateWidget: the aim dot) -- widgets found by name (their class path is not known)
local widget_lib = api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"):get_class_default_object()
local crosshairs, crosshair_looked = {}, -10
local AMMO_PATH = CROSSHAIR_CLASSES[3] -- the ammo panel: hidden unless VR SETTINGS has AMMO COUNTER ON
local ammo_ws, ammo_shown = {}, false
function hide_crosshair(pawn)
    if pawn == nil then return end
    if os.clock() - crosshair_looked > 2 then -- the HUD can be rebuilt (checkpoint, respawn): look again now and then
        crosshair_looked = os.clock()
        local found = {}
        local ammo = {}
        for _, path in ipairs(CROSSHAIR_CLASSES) do
            pcall(function()
                local c = api:find_uobject(path)
                if c == nil then return end
                local out = {}
                ucall(widget_lib, "GetAllWidgetsOfClass", pawn, out, c, false)
                for _, w in ipairs(out) do table.insert(path == AMMO_PATH and ammo or found, w) end
            end)
        end
        ammo_ws = ammo
        -- the focus zones: a child of the HUD panel the crosshair sits in
        local crosshair_count = #found -- (zones are appended below: only look from the crosshairs themselves)
        for i = 1, crosshair_count do
            local w = found[i]
            pcall(function()
                local panel = w:get_outer():get_outer() -- CrosshairWidget -> WidgetTree -> CommonPanel
                for name in pairs(CROSSHAIR_NAMES) do
                    local z = panel[name]
                    if z ~= nil then table.insert(found, z) end
                end
            end)
        end
        crosshairs = found
    end
    local ammo_on = VR_SETTINGS ~= nil and VR_SETTINGS.ammo == "on"
    if ammo_on ~= ammo_shown then -- the setting changed: show the panel again (the game drives it from there) / hide it
        ammo_shown = ammo_on
        for _, w in ipairs(ammo_ws) do
            pcall(function() w:SetRenderOpacity(ammo_on and 1 or 0) w:SetVisibility(ammo_on and 4 or 2) end)
        end
    end
    if not ammo_on then
        for _, w in ipairs(ammo_ws) do
            pcall(function() if w:GetVisibility() ~= 2 then w:SetVisibility(2) end if w:GetRenderOpacity() > 0 then w:SetRenderOpacity(0) end end)
        end
    end
    for _, w in ipairs(crosshairs) do
        pcall(function() if w:GetVisibility() ~= 2 then w:SetVisibility(2) end end) -- ESlateVisibility::Hidden
        -- the game shows the crosshair again during its tick while aiming (it becomes a small dot): also fully
        -- transparent, which it does not touch
        pcall(function() if w:GetRenderOpacity() > 0 then w:SetRenderOpacity(0) end end)
    end
end
LADDER_EXIT_TIME, LADDER_EXIT_MAX = 0.8, 3.0 -- s the game's body stays after the ladder (at most, waiting for the weapon)
-- Gnasher in hand: in the frame the game adds PawnState.Ladder.Climbing it also adds its own position to the capsule's
-- (about 2x the world position, Marcus ends up under the map; the pistol is fine). The tag appearing together with a jump
-- of more than LADDER_JUMP_MAX cm in one tick: put him back where he was the tick before.
-- Wider (a player's ladders failed ~1 in 10, "shot into the skybox"): the same check in a window from when
-- PawnState.ForceWalkingMovement or a Ladder tag shows up until LADDER_GUARD_AFTER s after the Ladder tag is gone, on every tick, and
-- a speed over LADDER_SPEED_MAX cm/s (no ladder move is that fast) is zeroed and undone too. Climbing is a few cm per tick, the
-- game's entry/exit placement < 3 m. LADDER_REC = true records per-tick lines (ring of 600) to data/ladder_rec_N.txt.
LADDER_JUMP_MAX, LADDER_SPEED_MAX, LADDER_GUARD_AFTER = 1000, 2500, 2
LADDER_REC = false
-- The game turns Marcus ~14 deg off the ladder; his arms reach ~50 cm forward, so both hands land 10-16 cm right of the
-- rails. LADDER_FACE_DELAY s after the climb starts (the game has placed him) the wall behind the ladder is measured: traces
-- along his forward at hand height, every 5 cm across +-70 cm; rails/rungs are short outliers, the wall is a line
-- d = a + slope * s. He is turned by atan(slope) to face it (once per ladder), only if the fit is clean.
LADDER_FACE_DELAY, LADDER_FACE_MIN_ERR = 0.3, 2 -- s; deg (any larger turn is allowed)
LADDER_FACE_MIN_HITS, LADDER_FACE_MAX_RES, LADDER_FACE_OUTLIER = 15, 3, 5 -- hits; cm rms; cm off the line
do
    local function fit(pts) -- least squares d = a + b s
        local n, ss, sd, sss, ssd = #pts, 0, 0, 0, 0
        for _, q in ipairs(pts) do ss, sd, sss, ssd = ss + q[1], sd + q[2], sss + q[1] * q[1], ssd + q[1] * q[2] end
        local den = n * sss - ss * ss
        if den == 0 then return nil end
        local b = (n * ssd - ss * sd) / den
        return (sd - b * ss) / n, b
    end
    local function med(t) table.sort(t) local n = #t return n % 2 == 1 and t[(n + 1) // 2] or (t[n // 2] + t[n // 2 + 1]) / 2 end
    -- returns yaw, err (deg), inliers, rms (cm) or nil, reason
    local function ladder_face_at(p, dz)
        local rot = p:K2_GetActorRotation()
        local yaw = rot.Yaw or rot.y
        local c = p:K2_GetActorLocation()
        local z, nz = 0, 0
        for _, n in ipairs({ "b_hand_l", "b_hand_R" }) do
            local ok, l = pcall(function() return ucall(p.Mesh, "GetSocketLocation", ucall(kismet_string, "Conv_StringToName", n)) end)
            if ok and l then z, nz = z + (l.z or l.Z), nz + 1 end
        end
        z = (nz > 0 and z / nz or c.z) + dz
        -- which way is the wall: the nearest hit of 36 traces around him (the game may have turned him 90 deg off)
        local rough, best = yaw, 1e9
        for k = 0, 35 do
            local ra = math.rad(yaw + k * 10)
            local hit = world_block(p, nil, v(c.x, c.y, z), v(c.x + math.cos(ra) * 150, c.y + math.sin(ra) * 150, z), 0)
            if hit then
                local d = math.sqrt((hit.x - c.x) ^ 2 + (hit.y - c.y) ^ 2)
                if d < best then best, rough = d, yaw + k * 10 end
            end
        end
        local r = math.rad(rough)
        local fx, fy, rx, ry = math.cos(r), math.sin(r), -math.sin(r), math.cos(r)
        local pts = {}
        for s = -70, 70, 5 do
            local from = v(c.x + rx * s, c.y + ry * s, z)
            local hit = world_block(p, nil, from, v(from.x + fx * 150, from.y + fy * 150, z), 0)
            if hit then pts[#pts + 1] = { s, math.sqrt((hit.x - from.x) ^ 2 + (hit.y - from.y) ^ 2) } end
        end
        if #pts < LADDER_FACE_MIN_HITS then return nil, "only " .. #pts .. " hits", yaw end
        local sl = {} -- robust start: median slope of far-apart pairs
        for i = 1, #pts do for j = i + 1, #pts do
            if pts[j][1] - pts[i][1] >= 30 then sl[#sl + 1] = (pts[j][2] - pts[i][2]) / (pts[j][1] - pts[i][1]) end
        end end
        if #sl == 0 then return nil, "no spread", yaw end
        local b = med(sl)
        local ic = {}
        for _, q in ipairs(pts) do ic[#ic + 1] = q[2] - b * q[1] end
        local a = med(ic)
        local inl = pts
        for _ = 1, 4 do
            inl = {}
            for _, q in ipairs(pts) do if math.abs(q[2] - (a + b * q[1])) <= LADDER_FACE_OUTLIER then inl[#inl + 1] = q end end
            if #inl < LADDER_FACE_MIN_HITS then return nil, "only " .. #inl .. " inliers of " .. #pts, yaw end
            local a2, b2 = fit(inl)
            if not a2 then return nil, "degenerate", yaw end
            a, b = a2, b2
        end
        local e2 = 0
        for _, q in ipairs(inl) do e2 = e2 + (q[2] - (a + b * q[1])) ^ 2 end
        local rms = math.sqrt(e2 / #inl)
        if rms > LADDER_FACE_MAX_RES then return nil, string.format("residual %.1f cm", rms), yaw end
        local err = math.deg(math.atan(b))
        return yaw, err, #inl, rms, rough, rough - err
    end
    -- At the top of a ladder going down the hands are above the upper floor and see no clean wall: the same search is
    -- repeated LADDER_FACE_DZ cm lower (into the shaft) and the first good fit wins. Returns as ladder_face_at plus the dz
    -- used; on failure nil, "dz0: reason; dz-60: reason...", yaw. results (optional table) gets one line per height.
    LADDER_FACE_DZ = { 0, -60, -120, -180 }
    function ladder_face_measure(p, results)
        local msgs, yaw0 = {}, nil
        for _, dz in ipairs(LADDER_FACE_DZ) do
            local yaw, err, n, rms, rough, final = ladder_face_at(p, dz)
            yaw0 = yaw0 or yaw
            local line
            if yaw and n then line = string.format("dz %d: yaw %.2f rough %.0f err %.2f final %.2f inliers %d rms %.2f cm", dz, yaw, rough, err, final, n, rms)
            else line = "dz " .. dz .. ": no fit (" .. tostring(err) .. ")" end
            msgs[#msgs + 1] = line
            if results then results[#results + 1] = line end
            if yaw and n then return yaw, err, n, rms, rough, final, dz end
        end
        return nil, table.concat(msgs, "; "), yaw0
    end
    function LADDER_FACE_DRY()
        local p = api:get_local_pawn(0)
        if p == nil then return "no pawn" end
        local res = {}
        local yaw, err, n, rms, rough, final, dz = ladder_face_measure(p, res)
        if not yaw then return table.concat(res, " | ") .. " => no fit (yaw " .. tostring(n) .. ")" end
        return table.concat(res, " | ") .. string.format(" => USED dz %d: yaw %.2f -> %.2f", dz, yaw, final)
    end
end
-- st = { last = last good position }. Outside the window (active false) it only follows. Returns the position to put the pawn
-- back to and why ("jump" / "speed"), or nil.
function LADDER_GUARD_DECIDE(st, c, vel, active)
    local last = st.last
    if active and last ~= nil and last.z ~= 0 then
        local dx, dy, dz = c.x - last.x, c.y - last.y, c.z - last.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > LADDER_JUMP_MAX then return last, "jump", d end
        if vel and (math.sqrt(vel.x * vel.x + vel.y * vel.y) > LADDER_SPEED_MAX or math.abs(vel.z) > LADDER_SPEED_MAX) then
            return last, "speed", d
        end
    end
    st.last = { x = c.x, y = c.y, z = c.z }
    return nil
end
do
    local last, last_lad, fix_errors = nil, false, 0
    local lad_t, face_done = 0, true
    local gst, win_until, was_act = {}, 0, false
    local ring, rn, rec_n, rec_at = {}, 0, 0, nil
    local function rec_write()
        rec_n = rec_n + 1
        local f = io.open("ladder_rec_" .. rec_n .. ".txt", "w")
        if not f then return end
        for i = math.max(1, rn - 599), rn do f:write(ring[(i - 1) % 600 + 1], "\n") end
        f:close()
        log("ladder rec written: ladder_rec_" .. rec_n .. ".txt")
    end
    uevr.sdk.callbacks.on_pre_engine_tick(function()
        local ok, err = pcall(function()
            local p = api:get_local_pawn(0)
            if p == nil then last = nil return end
            local c = p:K2_GetActorLocation()
            local lad, fw, names = false, false, ""
            pcall(function()
                local t = p:GetComponentByClass(api:find_uobject("Class /Script/TCGameplayTags.TCGameplayTagComponent")).CachedOwnedTagContainer.GameplayTags
                for i = 1, #t do
                    local n = t[i].TagName:to_string()
                    if n:find("Ladder") then lad = true names = names .. n .. ";" end
                    if n:find("ForceWalkingMovement") then fw = true names = names .. n .. ";" end
                end
            end)
            if lad then win_until = clock + LADDER_GUARD_AFTER elseif fw then win_until = math.max(win_until, clock + 0.2) end
            local active = lad or fw or clock < win_until
            local vel = nil
            if active then pcall(function() vel = p:GetVelocity() end) end
            local back, why, d = LADDER_GUARD_DECIDE(gst, c, vel, active)
            local action = ""
            if back then
                p:K2_SetActorLocation(Vector3d.new(back.x, back.y, back.z), false, {}, true)
                pcall(function() p.CharacterMovement.Velocity = Vector3d.new(0, 0, 0) end)
                action = why
                if not was_act then
                    log(string.format("ladder guard: %s, moved %.0f cm in one tick (vel %.0f,%.0f,%.0f), put back; tags %s", why, d,
                        vel and vel.x or 0, vel and vel.y or 0, vel and vel.z or 0, names))
                end
                c = p:K2_GetActorLocation()
                if LADDER_REC and not rec_at then rec_at = clock + 3 end
            end
            was_act = back ~= nil
            if LADDER_REC and (active or rec_at) then
                rn = rn + 1
                ring[(rn - 1) % 600 + 1] = string.format("%.3f lad=%s fw=%s cap=(%.0f,%.0f,%.0f) vel=(%.0f,%.0f,%.0f) yaw=%.1f act=%s tags=%s", clock,
                    tostring(lad), tostring(fw), c.x, c.y, c.z, vel and vel.x or 0, vel and vel.y or 0, vel and vel.z or 0,
                    p:K2_GetActorRotation().Yaw or 0, action, names)
                if last_lad and not lad and not rec_at then rec_at = clock + 3 end
                if rec_at and clock >= rec_at then rec_at = nil rec_write() end
            end
            if lad and not last_lad and last ~= nil then lad_t, face_done = clock, false end -- (not on the first tick after a reload)
            if not lad then face_done = true end
            if lad and not face_done and clock - lad_t >= LADDER_FACE_DELAY then
                face_done = true
                local yaw, err, n, rms, rough, final, dz = ladder_face_measure(p)
                if not yaw then log("ladder: not turned (" .. tostring(err) .. ")")
                elseif math.abs(final - yaw) % 360 < LADDER_FACE_MIN_ERR or math.abs(final - yaw) % 360 > 360 - LADDER_FACE_MIN_ERR then
                    log(string.format("ladder: not turned (already facing, yaw %.1f)", yaw))
                else
                    p:K2_SetActorRotation(Vector3d.new(0, final, 0), false)
                    log(string.format("ladder: turned to face the wall (yaw %.1f -> %.1f, rough %.0f, err %.1f deg, %d hits, rms %.1f cm, height dz %d)", yaw, final, rough, err, n, rms, dz))
                end
            end
            last, last_lad = { x = c.x, y = c.y, z = c.z }, lad
        end)
        if not ok then fix_errors = fix_errors + 1 if fix_errors % 300 == 1 then log("ladder fix: " .. tostring(err)) end end
    end)
end
-- the game's aim (LT) while the foregrip is held: off. Switching it on or off snapped the game's control rotation to
-- the weapon (50-77 deg in one frame, recorded) and turned the VR view; undoing the snap frame by frame did not work
-- (the game keeps forcing it ~0.4 s). Shots go along the barrel anyway (fire_from_hands).
ADS_ON_GRIP = false
local a_was_down = false
SPRINT_STOP_STICK, SPRINT_STOP_TIME = 0.3, 0.3 -- the sprint stops with the left stick under this for this long (s)
local in_gameplay, heli_play = false, false
last_aim_str = last_aim_str or nil
local statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
TURRET_PITCH_GAIN, TURRET_PITCH_OFFSET = 1.5, 0 -- (an offset of -15 made "straight ahead" aim down)
local eyes_of = setmetatable({}, { __mode = "k" }) -- pawn -> has Marcus' eye socket (a person, not a turret)
function eyes_of_pawn(pawn) return eyes_of[pawn] == true end

-- Just off a turret (B / torn off): for ~2 s the game's own Marcus is what stands there - headless, a big shoulder pad,
-- hands on the weapon as in the original (headset screenshot). arms.lua showed his meshes when control
-- passed to the turret (arms_cinematic) and only makes our VR body again after PAWN_SETTLE_TIME. Until then everything
-- of his that shows - body / armour meshes, and the weapon he holds - is hidden, and put back when our body is made
-- (arms.lua hides the meshes it draws copies of itself: arms_is_source), or after OFFBODY_TIMEOUT. Never what hangs on a
-- weapon (gestures' copies) or on a turret (the stand's gun).
OFFBODY_TIMEOUT = 7 -- s
local OFFBODY = { list = {}, active = false }
local function offbody_on_weapon(comp)
    local ok, yes = pcall(function()
        local c = comp.AttachParent
        for _ = 1, 3 do
            if c == nil then return false end
            local o = c:GetOwner()
            if o ~= nil then
                local n = o:get_class():get_fname():to_string()
                -- (not "Turret": on the stand Marcus himself hangs on it - his own body was skipped until he stepped off)
                if n:find("^BP_Wpn_") then return true end
            end
            c = c.AttachParent
        end
        return false
    end)
    return ok and yes
end
local function offbody_hide_comp(comp, of_weapon)
    pcall(function()
        if comp.bHiddenInGame == false and comp:IsVisible() and (of_weapon or not offbody_on_weapon(comp)) then
            ucall(comp, "SetHiddenInGame", true, false)
            table.insert(OFFBODY.list, comp)
            -- a pawn's static meshes (gestures' laser, pouch magazine and shells switch these themselves) are shown again
            -- whatever the last snapshot said; skeletal meshes and weapon pieces only if they showed in normal play (the
            -- game shows the guns it does not hold during its step-away, arms.lua keeps them hidden)
            -- the body arms.lua draws (made ~2 s after the exit): shown in the game's step-away pose until our arm
            -- placement takes it (the shoulder pad flashed once more). Shown again with the rest,
            -- whatever the snapshot says: its objects are new
            if of_weapon then OFFBODY.wpn[comp:get_address()] = true end
            if arms_is_ours ~= nil and arms_is_ours(comp) then
                OFFBODY.ours[comp:get_address()] = true
                -- (kept posed while hidden: shown again it was drawn one more moment in the game's pose)
                pcall(function() comp.VisibilityBasedAnimTickOption = 0 end)
            end
            if not of_weapon and comp:get_class():get_fname():to_string():find("Static") then OFFBODY.always[comp:get_address()] = true end
        end
    end)
end
-- f(comp, of_weapon) for every mesh of Marcus' body and of the weapons hanging on him
local function offbody_each(f)
    local pawn = BODY_PAWN or api:get_local_pawn(0)
    if pawn == nil then return end
    for _, cls in ipairs({ "SkeletalMeshComponent", "StaticMeshComponent" }) do
        for _, comp in ipairs(pawn:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine." .. cls)) or {}) do f(comp, false) end
    end
    local actors = {}
    pcall(function() ucall(pawn, "GetAttachedActors", actors, true, true) end)
    for _, a in ipairs(actors) do
        -- (not a stand's own gun, which hangs on the stand)
        local on_stand = false
        pcall(function() on_stand = a:GetAttachParentActor():get_class():get_fname():to_string():find("Turret") ~= nil end)
        if a:get_class():get_fname():to_string():find("^BP_Wpn_") and not on_stand then
            for _, comp in ipairs(a:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine.PrimitiveComponent")) or {}) do f(comp, true) end
        end
    end
end
local function offbody_scan() offbody_each(offbody_hide_comp) end
-- what shows in normal play (taken every ~1.5 s while on foot, not during an exit): only these are shown again, so
-- nothing that normal VR play keeps hidden (the armour, the game's arms) comes back after an exit
OFFBODY.always = {}
OFFBODY.wpn = {}
OFFBODY.ours = {}
OFFBODY.normal = {} -- (by address: the same component read again is a new Lua object)
local function offbody_snapshot()
    local set = {}
    offbody_each(function(comp, of_weapon)
        pcall(function()
            if comp.bHiddenInGame == false and comp:IsVisible() and (of_weapon or not offbody_on_weapon(comp)) then set[comp:get_address()] = true end
        end)
    end)
    OFFBODY.normal = set
end
function offbody_hide(hold) -- hold: s at least (debug tests); 0 = until our body is made
    if not OFFBODY.active then OFFBODY.list = {} end
    OFFBODY.t, OFFBODY.hold, OFFBODY.active, OFFBODY.frame = os.clock(), hold or 0, true, 0
    offbody_scan()
    log("off the turret: " .. #OFFBODY.list .. " pieces of the game's body / weapon hidden")
end
function offbody_restore()
    local n = 0
    if arms_rehide_bones ~= nil then pcall(arms_rehide_bones) end
    OFFBODY.rehide = 12 -- frames the shoulder-pad bones are hidden again after the drawn body shows
    -- a gun's pieces come back only if it is the gun in hand now (the tear-off Vulcan was never in the snapshot; the
    -- Lancer was, but is holstered - the mod keeps those hidden), the body's by the snapshot
    local eq = nil
    pcall(function() eq = equipped_weapon_mesh(BODY_PAWN or api:get_local_pawn(0)):GetOwner():get_address() end)
    for _, comp in ipairs(OFFBODY.list) do
        pcall(function()
            local ad = comp:get_address()
            local ok_weapon = OFFBODY.wpn[ad] and eq ~= nil and comp:GetOwner():get_address() == eq
            if (ok_weapon or (not OFFBODY.wpn[ad] and (OFFBODY.normal[ad] or OFFBODY.always[ad] or OFFBODY.ours[ad]))) and not (arms_is_source ~= nil and arms_is_source(comp)) then ucall(comp, "SetHiddenInGame", false, false) n = n + 1 end
        end)
    end
    log("off the turret: " .. n .. " of " .. #OFFBODY.list .. " pieces shown again")
    OFFBODY.list, OFFBODY.always, OFFBODY.wpn, OFFBODY.ours, OFFBODY.active, OFFBODY.pre, OFFBODY.body_t = {}, {}, {}, {}, false, false, nil
end
function OFFBODY_ACTIVE() return OFFBODY.active end
function offbody_count() return #OFFBODY.list, OFFBODY.active end
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local now = os.clock()
    if (OFFBODY.rehide or 0) > 0 then
        OFFBODY.rehide = OFFBODY.rehide - 1
        if arms_rehide_bones ~= nil then pcall(arms_rehide_bones) end
    end
    if not OFFBODY.active then
        -- (the right B pressed on a stand starts the dismount: the game's arm and shoulder swing into view before the
        -- pawn changes - hidden from the press, put back if B is let go and he is still on it)
        if OFFBODY_REQUEST then
            OFFBODY_REQUEST = false
            if VEHICLE and GROUND_TURRET then offbody_hide() OFFBODY.pre = true end
        elseif not VEHICLE and not CINEMATIC and BODY_PAWN ~= nil and api:get_local_pawn(0) == BODY_PAWN and now - (OFFBODY.snap_t or 0) > 1.5 then
            OFFBODY.snap_t = now
            pcall(offbody_snapshot)
        end
        return
    end
    if OFFBODY.pre then
        if not VEHICLE then OFFBODY.pre = false OFFBODY.t = now -- (the pawn changed: the step-away starts)
        elseif not VEHICLE_B_HELD and not VEHICLE_Y_HELD and now - OFFBODY.t > 0.3 then offbody_restore() return end
    end
    if OFFBODY.body_t == nil and arms_left_hand_component ~= nil and arms_left_hand_component() ~= nil then
        OFFBODY.body_t = now
        log(string.format("off the turret: our body made %.2f s after the pawn change", now - OFFBODY.t))
    end
    -- put back when the step-away is over AND the drawn body has had 1.2 s to take our arm placement (its arms settle from the game pose)
    if not OFFBODY.pre and now - OFFBODY.t >= OFFBODY.hold and (now - OFFBODY.t > OFFBODY_TIMEOUT or (now > (OFF_TURRET_UNTIL or 0) and OFFBODY.body_t ~= nil and now - OFFBODY.body_t >= 1.2)) then
        offbody_restore()
        return
    end
    OFFBODY.frame = OFFBODY.frame + 1
    offbody_scan() -- (every frame: the weapon the game equips after its step-away showed for a frame or two otherwise) -- (the weapon the game equips after its step-away)
end)
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local pawn = api:get_local_pawn(0)
    -- (a menu open over the game without pausing it - the supply cache: menu.lua MENU_UI_OPEN - counts as paused)
    local ok, paused = pcall(function() return pawn ~= nil and (ucall(statics, "IsGamePaused", pawn) or MENU_UI_OPEN == true) end)
    -- cutscene: the game's camera follows something else than Marcus (a cinema camera). Everything the mod does to
    -- the body, weapon and view is set aside until it is over (first person in cutscenes was broken, and crashed once)
    local cine = false
    pcall(function()
        local pc = api:get_player_controller(0)
        local vt = pc ~= nil and ucall(pc, "GetViewTarget") or nil
        cine = pawn ~= nil and vt ~= nil and vt ~= pawn
    end)
    -- a turret or vehicle in control (the helicopter's gun): not Marcus - no eyes to sit in, and its gun is not a
    -- hand weapon. Treated like a cutscene: the game's own view behind the gun.
    if pawn ~= nil then
        if eyes_of[pawn] == nil then
            local ok_e, has = pcall(function() return pawn.Mesh ~= nil and ucall(pawn.Mesh, "DoesSocketExist", ucall(kismet_string, "Conv_StringToName", "fc_eye_L")) end)
            eyes_of[pawn] = ok_e and has or false
        end
        local was_vehicle = VEHICLE
        VEHICLE = not eyes_of[pawn]
        -- just off a turret (B, or torn off): the game animates Marcus stepping away for ~2 s before a weapon is in hand
        -- - fp.lua keeps the view at his animated eyes meanwhile (the camera clipped into his body)
        if was_vehicle and not VEHICLE then
            OFF_TURRET_UNTIL = os.clock() + 2.5
            VEHICLE_AIM, VEHICLE_AIM_FP = nil, nil -- (fp.lua sets them in its own view; the next gun starts fresh)
            if not OFFBODY_ACTIVE() then pcall(offbody_hide) end
            -- the game's own arms hang frozen in front of the view for the ~2 s step-away (it equips the weapon only
            -- after its animation - equipping it ourselves earlier is ignored, tested): hidden until our arms are back
            -- (arms.lua unhides them when it makes the body again)
            pcall(function()
                for _, m in ipairs(pawn:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine.SkeletalMeshComponent"))) do
                    for _, sd in ipairs({ "L", "R" }) do pcall(function() m:HideBoneByName(ucall(kismet_string, "Conv_StringToName", "b_upperarm_" .. sd), 0) end) end
                end
                log("off the turret: the game's arms hidden until the weapon is back")
            end)
        end
        -- a gun on a stand in the ground (BP_TurretV2_*): manned at its handles, first person (turret.lua, fp.lua)
        GROUND_TURRET = VEHICLE and pawn:get_class():get_fname():to_string():find("TurretV2") ~= nil
        if VEHICLE then cine = true end
    elseif VEHICLE or GROUND_TURRET then
        -- no pawn (quit to the main menu / loading from a turret): the vehicle state must not outlive it (fp.lua kept
        -- the view at the old helicopter frame, the front end showed black)
        VEHICLE, GROUND_TURRET, VEHICLE_AIM, VEHICLE_AIM_FP = false, false, nil, nil
    end
    if cine ~= (CINEMATIC or false) then
        CINEMATIC = cine
        log(cine and "cutscene: game camera" or "cutscene over: first person")
        -- cutscene: the view turns only with the head (the right controller's aim and the stick do not turn its
        -- camera). A turret keeps the controller aim and the stick: that is how it is aimed.
        if cine then
            LADDER = false -- (set only outside cutscenes / turrets: it would hold 'still' and the aim method for their whole length)
            if arms_cinematic ~= nil then pcall(arms_cinematic, pawn, true) end
            if gestures_cinematic ~= nil then pcall(gestures_cinematic) end
            -- the weapon back in the hand socket as the game holds it (the game hangs weapons right on the socket)
            pcall(function()
                local w = equipped_weapon_mesh(pawn)
                if w ~= nil then ucall(w, "K2_SetRelativeLocationAndRotation", Vector3d.new(0, 0, 0), Vector3d.new(0, 0, 0), false, {}, true) end
            end)
            last_weapon = nil -- read again when play resumes
        elseif arms_cinematic ~= nil then
            pcall(arms_cinematic, pawn, false)
        end
    end
    -- UEVR's controller aim off in cutscenes, turrets (aimed straight from the controller) and while the chainsaw
    -- runs: revving, the game's camera follows the control rotation, so the controller (and the stick) turned the view
    local still = cine or CHAINSAW_HOLD == true or LADDER == true or paused == true -- (ladder: the controller turned the game camera; paused: head aim fed a frozen camera and the view lost the head's turns)
    if still ~= aim_still then
        aim_still = still
        vr.set_mod_value("VR_AimMethod", still and "0" or (AIM_METHOD_PLAY or "2"))
        vr.set_mod_value("VR_AimModifyPlayerControlRotation", still and "false" or "true")
    end
    if cine ~= aim_cine then -- (its own change: 'still' may already be true for another reason - paused, chainsaw)
        aim_cine = cine
        vr.set_mod_value("VR_MovementOrientation", cine and "0" or "1")
    end
    -- revving, the game turns the camera towards Marcus' body (turned away from enemies, saw.lua): held where it was,
    -- turned only by the right stick, at the game's own rate for that deflection (learned while the chainsaw is off)
    local stick = (RIGHT_STICK_X or 0) / 32767
    local bucket = math.min(4, math.floor(math.abs(stick) * 4)) -- 1..4: quarters of the deflection (0: dead zone)
    pcall(function()
        local pc = api:get_player_controller(0)
        local r = pc:GetControlRotation()
        if CHAINSAW_HOLD and not cine and not paused then
            saw_yaw = saw_yaw or r.Yaw
            if bucket >= 1 then saw_yaw = saw_yaw + (stick > 0 and 1 or -1) * TURN_RATES[bucket] * (delta or 0) end
            if math.abs(r.Yaw - saw_yaw) > 0.05 then ucall(pc, "SetControlRotation", Vector3d.new(r.Pitch, saw_yaw, r.Roll)) end
        else
            saw_yaw = nil
            if not cine and not paused and bucket >= 1 and turn_last_yaw ~= nil and (delta or 0) > 0 then
                local dy = r.Yaw - turn_last_yaw
                if dy > 180 then dy = dy - 360 elseif dy < -180 then dy = dy + 360 end
                local rate = math.abs(dy) / delta
                if rate > 5 and rate < 720 then TURN_RATES[bucket] = TURN_RATES[bucket] * 0.95 + rate * 0.05 end
            end
        end
        turn_last_yaw = r.Yaw
    end)
    in_gameplay = pawn ~= nil and ok and not paused and not cine
    EDAY_IN_GAMEPLAY = in_gameplay -- (global for gestures.lua)
    -- the helicopter's gun (a vehicle, not a stand): counted as a cutscene, but the right B is its pause menu (START)
    heli_play = pawn ~= nil and ok and not paused and VEHICLE == true and GROUND_TURRET ~= true

    crosshair_tick = (crosshair_tick or 0) + 1
    if crosshair_tick % 5 == 0 then hide_crosshair(pawn) end -- (it stays fully transparent in between)
    if in_gameplay and objective_update ~= nil then
        local okf, err = pcall(objective_update, pawn)
        if not okf then objective_errors = (objective_errors or 0) + 1 if objective_errors % 300 == 1 then log("objective: " .. tostring(err)) end end
    end
    local hmd_ok = vr.is_runtime_ready() and vr.is_hmd_active()
    AIM_FROZEN = (ok and paused) or not hmd_ok
    -- headset asleep: nothing is rendered, so the aim is not sent from the view callback; keep it alive from here
    if not hmd_ok and last_aim_str ~= nil then vr.set_mod_value("VR_AimOverride", last_aim_str) end
end)

-- Shots from the weapon in the hands. The game aims from its own camera (2 m behind Marcus) and fires from the
-- weapon in its animated (hidden) hand, 1 m from ours: the shots landed where its camera saw, beside the laser
-- (anything between its camera and the target caught them). Its targeting keeps "aim" and "firing" transforms and
-- the frame they were made on, and skips making them again that frame: written here, before the engine tick, with
-- the aim from the eyes towards the point the barrel points at (the laser dot) and the firing point at our muzzle.
-- (Aiming from the muzzle itself made the game's aim trace stop at once; along the sight line instead of at the
-- barrel's point the shots landed some 20 cm beside the dot.)
local targeting_of = {}
TWO_HAND_BLOOM, TWO_HAND_SPREAD = 0.2, 0.35 -- two-handed: bloom cap, spread size factor (see fire_from_hands)
BLOOM_BASE_AT, BLOOM_LIMIT_AT = 0xE8, 0x1C8 -- TCWeaponBloomSettings: the float inside WeaponBloomBase / WeaponBloomLimit
TWO_HAND_PELLETS, PELLET_MOD_AT = 0.5, 0xE00 -- two-handed pellet spread factor; the multi delivery's MultiHitSpreadModifier value
local fire_mode_c = api:find_uobject("Class /Script/TCWeapon.TCWeaponFireModeBase")
local multi_delivery_c = api:find_uobject("Class /Script/TCWeapon.TCAssemblyMassProjectileMultiDelivery")
local spread_c = nil -- the weapon (targeting_of entry) whose spread was last set
local function spread_set(c, small)
    if c.small == small then return end
    c.small = small
    for _, s in pairs(c.spread or {}) do
        pcall(function()
            if s.d ~= nil then s.d:write_float(PELLET_MOD_AT, s.mod * (small and TWO_HAND_PELLETS or 1)) return end
            local k = small and TWO_HAND_SPREAD or 1
            s.b:write_float(BLOOM_BASE_AT, s.base * k) s.b:write_float(BLOOM_LIMIT_AT, s.limit * k)
        end)
    end
end
FIRE_SELF_AIMED = {} -- (the Heavy Glaive was listed: its caches froze the game once; tested with its b_muzzle: fires fine)
local function fire_from_hands()
    local s, pawn = SHOT_FROM, api:get_local_pawn(0)
    if s == nil or pawn == nil or CINEMATIC or not in_gameplay or FIRE_FROM_HANDS_OFF then return end -- (debug switch)
    local weapon = equipped_weapon_mesh(pawn)
    if weapon == nil or eday_muzzle_name(weapon) == nil then return end
    local item = weapon:GetOwner()
    -- weapons the game must aim itself: writing the Heavy Glaive's caches froze the game when it fired (twice in the
    -- weapon suite; with the writes off it fires fine)
    local cname = item:get_class():get_fname():to_string()
    for _, k in ipairs(FIRE_SELF_AIMED) do if cname:find(k) then return end end
    -- (cached per weapon by its unique name: a new weapon can take a destroyed one's address after the engine's
    -- garbage collection - the old component was written to and shots left the game's own hidden weapon)
    local iname = item:get_fname():to_string()
    local c = targeting_of[iname]
    if c == nil then c = { tc = ucall(item, "GetWeaponTargetingComponent") or false } targeting_of[iname] = c end
    local tc = c.tc
    if not tc then return end
    -- held with both hands: steadier, as the game's aim (LT, which snapped the view) - the spread ("bloom", 0 = the
    -- weapon's smallest .. 1 = its widest) is kept at most TWO_HAND_BLOOM; one-handed the game's own as before
    -- and the spread's own size (bloom settings: smallest / widest angle, Lancer 4 / 7) times TWO_HAND_SPREAD
    if c.fms == nil then
        c.fms, c.spread = {}, {}
        for _, o in ipairs(item.ReplicatedAssemblyObjects or {}) do if o:is_a(fire_mode_c) then table.insert(c.fms, o) end end
    end
    -- the game fills these values at the weapon's first shot (0 / 0 before): read until they are plausible angles
    -- (raw offsets), then kept as the weapon's own
    -- (shotguns and the LMG have no bloom of their own but a pellet spread multiplier on their multi-shot delivery)
    for i, o in ipairs(c.fms) do
        if c.spread[i] == nil then
            pcall(function()
                local b = o.CurrentBloomSettings
                local base, limit = b:read_float(BLOOM_BASE_AT), b:read_float(BLOOM_LIMIT_AT)
                if base > 0 and base < 45 and limit > 0 and limit < 45 then -- (the LMG's limit is under its base)
                    c.spread[i] = { b = b, base = base, limit = limit }
                    c.small = nil -- (set again below, now with this one)
                end
            end)
        end
        if c.spread[-i] == nil then
            pcall(function()
                for _, d in ipairs(o.Deliveries or {}) do
                    if d:is_a(multi_delivery_c) then
                        local m = d:read_float(PELLET_MOD_AT)
                        if m > 0 and m < 10 then c.spread[-i] = { d = d, mod = m } c.small = nil end
                    end
                end
            end)
        end
    end
    local aimed = two_handed and not SCOPED_WEAPON
    if spread_c ~= c and spread_c ~= nil then spread_set(spread_c, false) end -- (the weapon put away: as the game had it)
    spread_c = c
    spread_set(c, aimed)
    if aimed then
        for _, fm in ipairs(c.fms) do
            pcall(function() if fm.CurrentWeaponBloomRatio > TWO_HAND_BLOOM then fm.CurrentWeaponBloomRatio = TWO_HAND_BLOOM end end)
        end
    end
    local d = s.dir
    local yaw, pitch = math.atan(d.y, d.x), math.atan(d.z, math.sqrt(d.x * d.x + d.y * d.y))
    local sp, cp, sy, cy = math.sin(pitch / 2), math.cos(pitch / 2), math.sin(yaw / 2), math.cos(yaw / 2)
    local qx, qy, qz, qw = sp * sy, -sp * cy, cp * sy, cp * cy -- FRotator(pitch, yaw, 0) as a quaternion
    local mz = eday_muzzle_pos(weapon)
    local frame = ucall(kismet_system, "GetFrameCount")
    local function put(t, x, y, z, q)
        t.Translation.X, t.Translation.Y, t.Translation.Z = x, y, z
        t.Rotation.X, t.Rotation.Y, t.Rotation.Z, t.Rotation.W = q[1], q[2], q[3], q[4]
    end
    put(tc.CachedAimTransform, s.eye.x, s.eye.y, s.eye.z, { qx, qy, qz, qw }) -- from the eyes towards the barrel's hit point
    -- the firing transform from the muzzle straight along the barrel to the same point (the eye's direction differed
    -- by the eye-muzzle parallax: 2 deg at 15 m on the Troika, whose muzzle sits 45 cm under the eyes)
    local fq = { qx, qy, qz, qw }
    local tp = SHOT_POINT
    if tp ~= nil then
        local bd = norm(v(tp.x - mz.x, tp.y - mz.y, tp.z - mz.z))
        if len(v(tp.x - mz.x, tp.y - mz.y, tp.z - mz.z)) > 30 then
            local by, bp = math.atan(bd.y, bd.x), math.atan(bd.z, math.sqrt(bd.x * bd.x + bd.y * bd.y))
            local sp2, cp2, sy2, cy2 = math.sin(bp / 2), math.cos(bp / 2), math.sin(by / 2), math.cos(by / 2)
            fq = { sp2 * sy2, -sp2 * cy2, cp2 * sy2, cp2 * cy2 }
        end
    end
    put(tc.CachedUnadjustedFiringTransform, mz.x, mz.y, mz.z, fq)
    tc.LastAimTransformCalcuationFrame = frame
    tc.LastUnadjustedFiringTransformCalcuationFrame = frame
end
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local ok, err = pcall(fire_from_hands)
    if not ok then fire_errors = (fire_errors or 0) + 1 if fire_errors % 300 == 1 then log("fire_from_hands: " .. tostring(err)) end end
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    RIGHT_TRIGGER = MELEE_WEAPON and 0 or state.Gamepad.bRightTrigger / 255 -- for the trigger finger and the trigger itself (a melee weapon has none)
    if DEBUG_PAD ~= nil then pcall(DEBUG_PAD, state) end -- (debug: simulated buttons, tools/dbg.sh)
    if VRS_PAD ~= nil then pcall(VRS_PAD, state) end -- (vrsettings.lua: snap turn, A in the VR SETTINGS menu)
    RIGHT_STICK_X = state.Gamepad.sThumbRX
    -- the right B pressed on a turret gets Marcus off it: still held when he is off, it must not open the pause menu
    -- - ignored until it is let go
    if (state.Gamepad.wButtons & XINPUT_GAMEPAD_X) == 0 then VEHICLE_B_HELD = false elseif VEHICLE then
        if not VEHICLE_B_HELD then OFFBODY_REQUEST = true end -- (hides the game's body from the press: offbody_hide)
        VEHICLE_B_HELD = true
    end
    PAD_RAW = { b = state.Gamepad.wButtons, lt = state.Gamepad.bLeftTrigger, rt = state.Gamepad.bRightTrigger, play = in_gameplay } -- (debug: tools/dbg.sh)
    if CINEMATIC then state.Gamepad.sThumbRX, state.Gamepad.sThumbRY = 0, 0 end -- the controller aims a turret, not the stick
    -- on a gun stand the right stick press switches its laser, as with a weapon in hand (turret.lua; not passed on)
    if GROUND_TURRET then
        local rs = (state.Gamepad.wButtons & 0x0080) ~= 0
        if rs and not TURRET_RS_WAS then TURRET_LASER_REQUEST = true end
        TURRET_RS_WAS = rs
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~0x0080
    end
    if not in_gameplay then
        -- menus, pause, cutscenes: an Xbox pad's layout on the Quest controllers (B was on the left controller).
        -- UEVR sends the right B as X and the left X as B - swapped back: right A = A, right B = B, left X = X, left Y = Y
        local w = state.Gamepad.wButtons
        local bx = (w & XINPUT_GAMEPAD_B) ~= 0
        local xx = (w & XINPUT_GAMEPAD_X) ~= 0
        w = w & ~(XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_X)
        if bx then w = w | XINPUT_GAMEPAD_X end
        -- (the right B that opened the pause menu as START is not also "back" until it is let go)
        if not xx then MENU_B_HELD = false end
        if xx and heli_play then w = w | 0x0010 MENU_B_HELD = true -- (helicopter: START, as in play)
        elseif xx and not MENU_B_HELD then w = w | XINPUT_GAMEPAD_B end
        state.Gamepad.wButtons = w
    end
    if in_gameplay then
        -- right stick press: laser on / off (not passed to the game)
        local rs_down = (state.Gamepad.wButtons & 0x0080) ~= 0
        if rs_down and not rs_was_down then LASER_TOGGLE_REQUEST = true end
        rs_was_down = rs_down
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~0x0080
        -- left stick press: the game turns the camera towards the objective while it is held (measured: the view
        -- swung ~100 deg and back) - not passed on. It starts the sprint instead (the game's roadie run = A held):
        -- on until the stick is let go to the middle (SPRINT_STOP_STICK for SPRINT_STOP_TIME) or pressed again.
        local ls_down = (state.Gamepad.wButtons & 0x0040) ~= 0
        if ls_down and not ls_was_down then SPRINTING = not SPRINTING end
        ls_was_down = ls_down
        local lmag = math.sqrt((state.Gamepad.sThumbLX / 32767) ^ 2 + (state.Gamepad.sThumbLY / 32767) ^ 2)
        LEFT_STICK_X, LEFT_STICK_Y = state.Gamepad.sThumbLX / 32767, state.Gamepad.sThumbLY / 32767 -- (sprint.lua)
        if lmag < SPRINT_STOP_STICK then
            sprint_idle_t = sprint_idle_t or os.clock()
            if os.clock() - sprint_idle_t > SPRINT_STOP_TIME then SPRINTING = false end
        else
            sprint_idle_t = nil
        end
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~0x0040
        -- the real left trigger and left X, read before they are changed below
        local left_trigger = state.Gamepad.bLeftTrigger
        -- (UEVR sends the left X as the gamepad's B, the right B as X: VR.cpp)
        local left_x_down = (state.Gamepad.wButtons & XINPUT_GAMEPAD_B) ~= 0
        -- aiming (the game's left trigger: slower walk, better accuracy) while the left hand holds the foregrip
        -- (not with a scope: the game's aim is its full-screen zoom; scope.lua shows the view in the scope instead)
        state.Gamepad.bLeftTrigger = (ADS_ON_GRIP and two_handed and not SCOPED_WEAPON) and 255 or 0
        local a_down = (state.Gamepad.wButtons & XINPUT_GAMEPAD_A) ~= 0
        if a_down and not a_was_down then gestures_eject_request = true end
        a_was_down = a_down
        local right_b_down = (state.Gamepad.wButtons & XINPUT_GAMEPAD_X) ~= 0
        local buttons = state.Gamepad.wButtons & ~(XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_X)
        -- left X: the game's X (pick up, open doors, interact); right B: the pause menu (START);
        -- dash / roadie run (the game's A) only from the left stick press - the right A drops the magazine
        if left_x_down then
            buttons = buttons | XINPUT_GAMEPAD_X
            MENU_UI_PROBE_UNTIL = os.clock() + 2.5 -- (an interaction may open a menu: menu.lua looks for one meanwhile)
        end
        if right_b_down and not VEHICLE_B_HELD then buttons = buttons | 0x0010 MENU_B_HELD = true end
        -- (the game's A only while moving and with nothing ahead to take cover behind - sprint.lua WALL_AHEAD: next to
        -- a wall or from standing still A slides into cover)
        if SPRINTING and lmag >= SPRINT_STOP_STICK and not WALL_AHEAD then buttons = buttons | XINPUT_GAMEPAD_A end
        -- the button mapped to COVER (GAME) in VR SETTINGS (vrsettings.lua; default none): the game's A - cover / evade / slide
        if COVER_PAD then buttons = buttons | XINPUT_GAMEPAD_A end
        -- left trigger held while moving: sprint, for as long as it is held - sprint.lua moves Marcus faster.
        -- Not the game's A (its roadie run starts with a dash; the dash is the left stick press only). (No game melee
        -- on it any more - blows are made with real swings.)
        local lt_down = left_trigger > 128
        if TSPRINT_PAD ~= nil then lt_down = TSPRINT_PAD end -- (VR SETTINGS: the button mapped to the trigger sprint)
        lt_was_down = lt_down
        LT_SPRINT = lt_down and lmag >= SPRINT_STOP_STICK -- sprint.lua: faster walking (the game's A would dash first)
        if os.clock() < (bash_until or 0) then buttons = buttons | XINPUT_GAMEPAD_B end
        -- the chainsaw lever pulled (gestures.lua): the chainsaw runs (B held: revving; saw.lua cuts what it touches).
        -- The game does not fire while it revs: the right trigger lets go of B while it is pulled.
        -- (saw.lua: the game stopped revving on its own - B let go for a few polls, then pressed again)
        if (SAW_REPRESS or 0) > 0 then SAW_REPRESS = SAW_REPRESS - 1
        elseif CHAINSAW_HOLD and state.Gamepad.bRightTrigger < 30 then buttons = buttons | XINPUT_GAMEPAD_B end
        state.Gamepad.wButtons = buttons
    end
    -- The grips are the gesture buttons (weapon switch, magazine, foregrip): the game must not also see them as
    -- RB (reload) and LB (tac-com).
    local masked = XINPUT_GAMEPAD_LEFT_SHOULDER
    masked = masked | XINPUT_GAMEPAD_RIGHT_SHOULDER
    state.Gamepad.wButtons = state.Gamepad.wButtons & ~masked
    -- the buttons mapped to TAC-COM (the game's LB, held) and MAP (its View / Back button) in VR SETTINGS: the only way LB gets past the mask
    if in_gameplay then
        if TACOM_PAD then state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_LEFT_SHOULDER end
        if MAP_PAD then state.Gamepad.wButtons = state.Gamepad.wButtons | 0x0020 end
    end
    PAD_OUT = state.Gamepad.wButtons -- (debug: what the game gets)
    -- magazine empty (only the reserve round left) or out: the trigger does nothing
    if gestures_fire_blocked ~= nil and gestures_fire_blocked() then state.Gamepad.bRightTrigger = 0 end
    -- a melee weapon: the trigger would play the game's own swing - only the swings of the hand hit (saw.lua)
    if MELEE_WEAPON and in_gameplay then state.Gamepad.bRightTrigger = 0 end
    -- the weapon on the back (RIGHT_FREE): its trigger does nothing (a grenade in the right hand reads it, grenade.lua)
    if RIGHT_FREE and in_gameplay then state.Gamepad.bRightTrigger = 0 end
    -- grenade.lua: the left trigger arms a grenade in the hand; the right trigger held for the game's throw
    if GRENADE_PAD ~= nil and in_gameplay then pcall(GRENADE_PAD, state) end
    -- turret.lua: the game's Y (detach) when the gun is torn off its stand
    if TURRET_PAD ~= nil and GROUND_TURRET then pcall(TURRET_PAD, state) end
    -- the tear-off (the game's Y, also pressed by turret.lua's yank) starts the same dismount animation as B: the game's
    -- body is hidden from the press (offbody_hide)
    if VEHICLE and GROUND_TURRET and (state.Gamepad.wButtons & 0x8000) ~= 0 then
        if not VEHICLE_Y_HELD then OFFBODY_REQUEST = true end
        VEHICLE_Y_HELD = true
    else
        VEHICLE_Y_HELD = false
    end
end)

log("loaded")


-- The game's UI follows the view while playing (its objective marker / door prompts are projected through the game's
-- camera, which turns with the head: on a UI panel fixed in the room they slid left and right as the head turned);
-- fixed in the room while paused (menus).
local ui_follow, ui_size = nil, nil
uevr.sdk.callbacks.on_pre_engine_tick(function()
    pcall(function()
        local pc = api:get_player_controller(0)
        local paused = pc ~= nil and (ucall(api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object(), "IsGamePaused", pc) or MENU_UI_OPEN == true)
        -- (a gun stand counts as playing: there the game turns the 'room' with the gun's aim and a fixed panel swung
        -- with the controller - its prompts must stay in the lower right of the view)
        local want = not paused and api:get_local_pawn(0) ~= nil and (not CINEMATIC or GROUND_TURRET == true) -- (menus without a pawn: fixed too)
        -- HUD SIZE (VR SETTINGS): UEVR UI_Size while playing; menus (paused, cutscenes, no pawn) keep the full 2.0
        local sz = (want and VR_SETTINGS ~= nil and ({ medium = "1.6", small = "1.3" })[VR_SETTINGS.hud]) or "2.0"
        if sz ~= ui_size then ui_size = sz vr.set_mod_value("UI_Size", sz) end
        if want ~= ui_follow then
            ui_follow = want
            vr.set_mod_value("UI_FollowView", want and "true" or "false")
        end
    end)
end)

-- The title screen's camera (BP_UIActor_FrontendCam) looks down at the burning title on the ground (pitch -57); UEVR's
-- decoupled pitch levelled it and the title was far below the view. Its pitch is kept on the front end, and
-- the usual decoupled (level) pitch everywhere else.
local frontend_pitch = nil
uevr.sdk.callbacks.on_pre_engine_tick(function()
    pcall(function()
        local pc = api:get_player_controller(0)
        local vt = pc and ucall(pc, "GetViewTarget")
        local fe = vt ~= nil and vt:get_class():get_fname():to_string():find("FrontendCam") ~= nil
        if fe ~= frontend_pitch then
            frontend_pitch = fe
            vr.set_mod_value("VR_DecoupledPitch", fe and "false" or "true")
            -- no head aim on the front end (fp.lua sets it at load): the head turning the control rotation fed back
            -- into the FrontendCam and the title view shook with head turns
            vr.set_mod_value("VR_AimMethod", fe and "0" or (aim_still and "0" or (AIM_METHOD_PLAY or "2")))
        end
    end)
end)
