-- Gears of War: E-Day VR body: Marcus' full body, standing under the VR camera, arms driven by the controllers.
-- The game keeps animating the real body (gameplay needs it) but the player no longer sees it; a posable copy of each
-- body mesh is drawn instead. Every frame it gets the game's pose (legs, walking, cover...), then:
--   * the body is turned to face where the headset looks (the game's aiming stance turns the left shoulder forward),
--   * the body is shifted so the neck sits just behind the camera (looking down shows chest and legs, not insides),
--   * each arm is re-posed with two-bone IK from its shoulder to its hand: right hand on the weapon grip,
--     left hand on the left controller or on the foregrip.
-- weapon.lua leaves its request in arms_request every frame; it is applied at the start of the next frame, before
-- the engine tick: CopyPoseFromSkeletalComponent sends the copied pose to the renderer right away, while bone edits
-- only reach the renderer on the copy's next tick. Done after the tick (with the weapon), the edits never showed and
-- the copy displayed the game's own pose (its hand IK stretching the arms up to the weapon held in the air).
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
    pcall(function() uevr.params.functions.log_info("[arms] " .. tostring(msg)) end)
end

local skeletal_mesh_c = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
local poseable_c = api:find_uobject("Class /Script/Engine.PoseableMeshComponent")
local controller_c = api:find_uobject("Class /Script/Engine.Controller")
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

local names = {}
local function fname(s)
    if names[s] == nil then names[s] = ucall(kismet_string, "Conv_StringToName", s) end
    return names[s]
end

-- Same as fp.lua: bones that block the view from inside the head.
local HIDDEN_BONES = {
    "b_head",
    "sc_shoulderpad_L", "sc_shoulderpad_R",
    "sc_collar_RF", "sc_collar_R", "sc_collar_RB", "sc_collar_LF", "sc_collar_L", "sc_collar_LB",
}
local WEAPON_SOCKET = "socket_ik_lcl_weapon_01"

local WORLD_SPACE = 0 -- EBoneSpaces::WorldSpace

-- Tuning (cm)
-- Where the neck goes relative to the eyes: Marcus' armour collar is big, the eyes must clear it.
local NECK_BEHIND_CAMERA = 10.0
local NECK_BELOW_CAMERA = 15.0
-- When the controllers are further out than Marcus' arms reach, the body leans after them (up to this much)
-- instead of stretching the arms.
local MAX_LEAN = 6.0 -- (was 20: past NECK_BEHIND_CAMERA the neck came in front of the eyes - the black inside of the neck)
-- ...and before that the shoulder itself reaches forward: the collarbone turns towards the hand, up to this much
-- (a real shoulder does this; shifting the shoulder joint instead stretched the sleeve)
local MAX_SHOULDER_TURN = math.rad(30)
-- Free left hand: the palm centre sits this far in front of the wrist bone (cm), on the controller.
local PALM_TO_WRIST = 9.0
-- after the hand was locked onto a magazine sliding along the weapon's well, it goes back onto the controller in this
-- many seconds (eased) and then moves exactly as the free hand, the magazine in it
local LOCK_RELEASE_TIME = 0.15
-- An animation that swings the torso round the neck (dash, diving into cover: spine_02 measured up to 27 cm IN FRONT of
-- the eyes while the neck stays behind them) must not bring it into the view: the whole body goes back as far as
-- needed. A torso bone must stay this far behind the eyes (cm): clear_high near eye level (the chest is thick in front
-- of the spine), clear_low deep below (normal pose: these bones 7..8 cm behind the eyes, 30..50 cm lower).
local TORSO = { bones = { "b_spine_02", "b_spine_03", "sc_chestarmor" }, clear_low = 4.0, clear_high = 18.0, low = -35.0, high = -15.0, side = 25.0 }

-- Left hand curled around a magazine: bend of each finger joint towards the palm (degrees, joints 1..3).
local MAG_CURL = {
    -- flat along the magazine's side, the last joints hooking over its front edge
    index = { 5, 20, 45 }, middle = { 5, 20, 45 }, ring = { 5, 20, 45 }, pinky = { 5, 20, 45 },
    thumb = { 0, 10, 10 }, -- thumb joints 00..02
}

-- Left hand fingers: reset to the mesh's rest pose (open, relaxed) when the hand is not holding the weapon.
local LEFT_FINGERS = {}
local RIGHT_FINGERS = {} -- (the free right hand: weapon on the back)
for _, finger in ipairs({ "thumb", "index", "middle", "ring", "pinky" }) do
    for i = 0, 3 do table.insert(LEFT_FINGERS, string.format("b_%s_%02d_L", finger, i)) table.insert(RIGHT_FINGERS, string.format("b_%s_%02d_R", finger, i)) end
end
-- Left-handed play (EDAY_LEFTY, aa_xr.lua): the weapon is held in Marcus' LEFT hand and his RIGHT hand is the support hand.
-- The game's animation, the grips learned from it and the weapon itself stay right-handed; the left hand takes the
-- MIRROR of the right hand's hold (mirror_grip, set_mirrored_fingers). Set at the start of every update_arms.
local SIDE = { wpn = "R", sup = "L" } -- skeleton side ("L"/"R") of the weapon hand and of the support hand
local FINGERS = { L = LEFT_FINGERS, R = RIGHT_FINGERS }
local FINGER_BASES = {} -- b_<finger>_0n_ without the side, parents before children
for _, finger in ipairs({ "thumb", "index", "middle", "ring", "pinky" }) do
    for i = 0, 3 do table.insert(FINGER_BASES, string.format("b_%s_%02d_", finger, i)) end
end
local ELBOW_OUT, ELBOW_BACK = 0.6, 0.3 -- elbow bend direction: down, plus this much outwards / backwards

-- vector helpers
local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a) local l = len(a) return l > 1e-6 and mul(a, 1 / l) or a end
local function copy(u) return v(u.x, u.y, u.z) end
local function flat(a) return norm(v(a.x, a.y, 0)) end

-- frame = { pos, x, y, z } (axes in world space)
local function rotator_axes(rot)
    local p, y, r = math.rad(rot.x), math.rad(rot.y), math.rad(rot.z)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return v(cp * cy, cp * sy, sp),
        v(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp),
        v(-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp)
end

local function bone_frame(mesh, bone)
    local x, y, z = rotator_axes(ucall(mesh, "GetSocketRotation", fname(bone)))
    return { pos = copy(ucall(mesh, "GetSocketLocation", fname(bone))), x = x, y = y, z = z }
end

-- express frame b relative to frame a, and back
local function relative(a, b)
    local function loc(p) return v(dot(p, a.x), dot(p, a.y), dot(p, a.z)) end
    return { pos = loc(sub(b.pos, a.pos)), x = loc(b.x), y = loc(b.y), z = loc(b.z) }
end
local function compose(a, rel)
    local function w(p) return add(mul(a.x, p.x), add(mul(a.y, p.y), mul(a.z, p.z))) end
    return { pos = add(a.pos, w(rel.pos)), x = w(rel.x), y = w(rel.y), z = w(rel.z) }
end

-- rotation of vector p by the rotation taking unit vector a onto unit vector b
local function swing(a, b)
    local k = cross(a, b)
    local s, c = len(k), dot(a, b)
    if s < 1e-6 then return function(p) return p end end
    k = mul(k, 1 / s)
    return function(p) return add(add(mul(p, c), mul(cross(k, p), s)), mul(k, dot(k, p) * (1 - c))) end
end

-- rotation around the world Z axis by `angle` radians
local function yaw_rotation(angle)
    local c, s = math.cos(angle), math.sin(angle)
    return function(p) return v(p.x * c - p.y * s, p.x * s + p.y * c, p.z) end
end

local function rotate_frame(f, rot, pivot, offset)
    return { pos = add(add(pivot, rot(sub(f.pos, pivot))), offset), x = rot(f.x), y = rot(f.y), z = rot(f.z) }
end

-- the copies, per pawn
local state = { pawn = nil, copies = {} }

local function make_copies(pawn)
    state.pawn = pawn
    state.copies = {}

    -- copies left by a previous run of this script (hot reload) would stay frozen in place. Not what hangs on a
    -- weapon: gestures.lua's drawn copy of the weapon (the Gnasher's pieces follow it) - deleted here when the body was
    -- made again after a turret, the gun froze in the air
    local function on_weapon(comp)
        local ok, yes = pcall(function()
            local c = comp.AttachParent
            for _ = 1, 3 do
                if c == nil then return false end
                local o = c:GetOwner()
                if o ~= nil and o:get_class():get_fname():to_string():find("^BP_Wpn_") then return true end
                c = c.AttachParent
            end
            return false
        end)
        return ok and yes
    end
    for _, old in ipairs(ucall(pawn, "K2_GetComponentsByClass", poseable_c) or {}) do
        if not on_weapon(old) then ucall(old, "K2_DestroyComponent", old) end
    end
    for _, old in ipairs(ucall(pawn, "K2_GetComponentsByClass", skeletal_mesh_c) or {}) do
        -- (the game's own hair has a generic name in the armoured outfit: kept when it hangs on the mesh; ours are
        -- never hair - an old copy of it got re-parented onto the real hair when its posable parent went)
        local game_part = false
        pcall(function() game_part = ucall(old, "GetSkinnedAsset"):get_fname():to_string():find("Hair") ~= nil and old.AttachParent == pawn.Mesh end)
        if old ~= pawn.Mesh and not game_part and not on_weapon(old) and old:get_fname():to_string():find("^SkeletalMeshComponent_") then
            ucall(old, "K2_DestroyComponent", old)
        end
    end

    for _, mesh in ipairs(ucall(pawn, "K2_GetComponentsByClass", skeletal_mesh_c) or {}) do
        -- the pose is read from the real body: its arm bones must not be hidden (hidden = zero scale)
        for _, side in ipairs({ "L", "R" }) do
            pcall(function() ucall(mesh, "UnHideBoneByName", fname("b_upperarm_" .. side)) end)
        end

        local has_arms = ucall(mesh, "GetBoneIndex", fname("b_upperarm_R")) ~= -1
        local asset = nil
        pcall(function() asset = ucall(mesh, "GetSkeletalMeshAsset") end)
        if asset == nil then pcall(function() asset = ucall(mesh, "GetSkinnedAsset") end) end

        -- (hair by its asset too: the armoured outfit's hair component has a generic name)
        if has_arms and asset ~= nil and not mesh:get_fname():to_string():find("Hair") and not asset:get_fname():to_string():find("Hair") then
            local copy_comp = api:add_component_by_class(pawn, poseable_c)
            if copy_comp ~= nil then
                local ok = pcall(function() ucall(copy_comp, "SetSkinnedAssetAndUpdate", asset, true) end)
                if not ok then ucall(copy_comp, "SetSkeletalMesh", asset, true) end
                for i = 0, ucall(mesh, "GetNumMaterials") - 1 do
                    ucall(copy_comp, "SetMaterial", i, ucall(mesh, "GetMaterial", i))
                end
                ucall(copy_comp, "K2_AttachToComponent", mesh, fname("None"), 2, 2, 2, false) -- snap to the original
                pcall(function() ucall(copy_comp, "SetCollisionEnabled", 0) end) -- display only
                pcall(function() ucall(copy_comp, "SetComponentTickEnabled", true) end) -- its tick sends our bone edits to the renderer
                for _, bone in ipairs(HIDDEN_BONES) do
                    pcall(function() ucall(copy_comp, "HideBoneByName", fname(bone), 0) end)
                end
                -- the original keeps animating (gameplay, weapon socket) and casting shadows, but the player doesn't see it
                pcall(function() mesh.VisibilityBasedAnimTickOption = 0 end) -- AlwaysTickPoseAndRefreshBones
                ucall(mesh, "SetOwnerNoSee", true)
                -- OwnerNoSee alone does not hide it in UEVR's views; and the game's hand IK pulls its arms to the weapon
                -- we hold up in the air, so they would show as long arms coming from below
                ucall(mesh, "SetHiddenInGame", true, false)
                -- What is drawn is a regular skeletal mesh following the posable copy's bones: a posable mesh has no
                -- cloth support, so the body's cloth parts (sleeves, straps) were drawn from their rest positions near
                -- the feet, as long strips hanging from the hands to the floor. Cloth blend 0 = pure skinning.
                local follower = api:add_component_by_class(pawn, skeletal_mesh_c)
                if follower ~= nil then
                    local ok2 = pcall(function() ucall(follower, "SetSkinnedAssetAndUpdate", asset, true) end)
                    if not ok2 then ucall(follower, "SetSkeletalMesh", asset, true) end
                    for i = 0, ucall(mesh, "GetNumMaterials") - 1 do
                        ucall(follower, "SetMaterial", i, ucall(mesh, "GetMaterial", i))
                    end
                    ucall(follower, "K2_AttachToComponent", copy_comp, fname("None"), 2, 2, 2, false)
                    pcall(function() ucall(follower, "SetCollisionEnabled", 0) end)
                    pcall(function() follower.bDisableClothSimulation = true end)
                    pcall(function() follower.ClothBlendWeight = 0.0 end)
                    pcall(function() ucall(follower, "SetClothBlendWeight", 0.0) end)
                    ucall(follower, "SetLeaderPoseComponent", copy_comp, true)
                    for _, bone in ipairs(HIDDEN_BONES) do
                        pcall(function() ucall(follower, "HideBoneByName", fname(bone), 0) end)
                    end
                    ucall(copy_comp, "SetHiddenInGame", true, false) -- the follower is what shows
                end
                table.insert(state.copies, { src = mesh, copy = copy_comp, follower = follower, asset = asset })
                -- the other meshes share the skeleton: their drawn mesh follows the first posed copy, so the arms,
                -- fingers and twist bones are posed once per frame instead of once per mesh
                if #state.copies > 1 and follower ~= nil then
                    pcall(function() ucall(follower, "SetLeaderPoseComponent", state.copies[1].copy, true) end)
                    state.copies[#state.copies].shares_first = true
                    pcall(function() ucall(copy_comp, "SetComponentTickEnabled", false) end)
                end
                log("posable copy of " .. mesh:get_fname():to_string() .. " (" .. asset:get_fname():to_string() .. ")")
            end
        end
    end
end

-- two-bone IK for one arm, from frames already moved with the torso; target = desired world frame of the hand bone
-- the plane of an arm: x shoulder->elbow, z across the bend (shoulder, elbow, wrist), y completes it
-- twist bones of the sleeves: { name prefix, parent bone prefix, index into the solved arm (1 upper, 2 fore) }
TWIST_BONES = {
    { "twist_upperarm_01_", "b_upperarm_", 1 }, { "twist_upperarm_02_", "b_upperarm_", 1 },
    { "twist_forearm_01_", "b_forearm_", 2 }, { "twist_forearm_02_", "b_forearm_", 2 }, { "twist_forearm_03_", "b_forearm_", 2 },
}

local function arm_plane(shoulder, elbow, wrist, fallback)
    local x = norm(sub(elbow, shoulder))
    local z = cross(x, sub(wrist, shoulder))
    if len(z) < 1e-3 then z = cross(x, fallback) end
    z = norm(z)
    return { pos = shoulder, x = x, y = cross(z, x), z = z }
end

-- A relation read from the game's animation (child frame in its parent's coordinates) with its roll about `axis`
-- (parent coordinates) set to the skeleton's reference pose (its y axis there: ref_y): the animation's wrist twist
-- was kept for good (a pistol stance had the left hand turned 85 deg on its forearm: the arm looked cut at the wrist
-- and the sleeve spun). Without it the forearm turns with the hand, as a real one does. No ref_y: unchanged.
function deroll(rel, axis, ref_y)
    if ref_y == nil then return rel end
    local k = norm(axis)
    local function flat(q) return sub(q, mul(k, dot(q, k))) end
    local y0, y1 = flat(ref_y), flat(rel.y)
    if len(y0) < 1e-3 or len(y1) < 1e-3 then return rel end
    y0, y1 = norm(y0), norm(y1)
    local a = -math.atan(dot(cross(y0, y1), k), dot(y0, y1))
    local c, sn = math.cos(a), math.sin(a)
    local function rot(q) return add(add(mul(q, c), mul(cross(k, q), sn)), mul(k, dot(k, q) * (1 - c))) end
    return { pos = rel.pos, x = rot(rel.x), y = rot(rel.y), z = rot(rel.z) }
end
-- a bone in a parent's coordinates in the skeleton's reference pose (local reference transforms chained up)
function ref_rel(comp, bone, parent)
    local function lf(b)
        local t = ucall(comp, "GetRefPoseTransform", ucall(comp, "GetBoneIndex", fname(b)))
        local q, p = t.Rotation, t.Translation
        local x, y, z, w = q.X, q.Y, q.Z, q.W
        return { pos = v(p.X, p.Y, p.Z), x = v(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
                 y = v(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)), z = v(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)) }
    end
    local f, b = lf(bone), ucall(comp, "GetParentBone", fname(bone)):to_string()
    for _ = 1, 6 do
        if b == parent or b == "None" or b == "" then break end
        f = compose(lf(b), f)
        b = ucall(comp, "GetParentBone", fname(b)):to_string()
    end
    return b == parent and f or nil
end

local function solve_arm(up, lo, hand, target, hint, cache)
    local l1, l2 = len(sub(lo.pos, up.pos)), len(sub(hand.pos, lo.pos))
    local to_target = sub(target.pos, up.pos)
    local dir = norm(to_target)
    local max_reach = l1 + l2 - 0.5
    -- read before the shoulder may be moved below: read with a moved shoulder (hand out of reach on the first frame)
    -- it turned the upper arm 34 degrees off its elbow for good (left sleeve pulled out of the chest)
    if cache.up_rel == nil then
        cache.up_rel = relative(arm_plane(up.pos, lo.pos, hand.pos, dir), up)
        cache.hand_in_fore = relative(lo, hand)
        cache.hand_in_fore = deroll(cache.hand_in_fore, cache.hand_in_fore.pos, cache.ref and cache.ref.hand and cache.ref.hand.y)
    end
    local over = len(to_target) - max_reach
    if over > 0 then
        -- out of reach (the hand stays on the controller): a third of what is missing moves the shoulder, two
        -- thirds lengthen the upper arm and forearm evenly. All of it at the shoulder pulled the sleeve out of
        -- the chest (15 cm with the weapon held out at 50 cm).
        local shift = over / 3
        up = { pos = add(up.pos, mul(dir, shift)), x = up.x, y = up.y, z = up.z }
        local grow = (l1 + l2 + over - shift) / (l1 + l2)
        l1, l2 = l1 * grow, l2 * grow
    end
    local d = math.max(len(sub(target.pos, up.pos)), math.abs(l1 - l2) + 0.1)
    local a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
    local h = math.sqrt(math.max(0, l1 * l1 - a * a))
    local bend = norm(sub(hint, mul(dir, dot(hint, dir))))
    local elbow = add(add(up.pos, mul(dir, a)), mul(bend, h))
    local wrist = add(up.pos, mul(dir, d))

    -- Upper arm and forearm roll come only from the arm's own shape (shoulder, elbow, wrist) and the hand: their
    -- relation to the animation is read once (cache). Following the animation every frame made the arm spin round
    -- while the game played its own two-hand / firing animation.
    local upper = compose(arm_plane(up.pos, elbow, wrist, bend), cache.up_rel)
    upper.pos = up.pos
    -- forearm: its roll must follow the hand (otherwise the forearm skin twists up into a thin ribbon, "candy wrapper").
    -- Take the forearm orientation that keeps the animation's forearm->hand relation with the new hand, then swing it
    -- so it points from the elbow to the wrist.
    local r = cache.hand_in_fore -- hand in forearm coordinates (animated pose, read once)
    local fx = add(add(mul(target.x, r.x.x), mul(target.y, r.y.x)), mul(target.z, r.z.x))
    local fy = add(add(mul(target.x, r.x.y), mul(target.y, r.y.y)), mul(target.z, r.z.y))
    local fz = add(add(mul(target.x, r.x.z), mul(target.y, r.y.z)), mul(target.z, r.z.z))
    local along = norm(r.pos) -- forearm->hand direction in forearm coordinates
    local s2 = swing(norm(add(add(mul(fx, along.x), mul(fy, along.y)), mul(fz, along.z))), norm(sub(wrist, elbow)))
    local fore = { pos = elbow, x = s2(fx), y = s2(fy), z = s2(fz) }
    local rh = cache.ref and cache.ref.hand
    if rh ~= nil then
        -- with the reference pose known: the forearm lies on the elbow->wrist line and turns about it so that the
        -- hand's twist on it is the reference pose's (all of a hand's turn is taken by the forearm, none by the
        -- wrist). The swing above added its own twist when the hand was bent far off the forearm's line (the
        -- pistol's palm-up hold: hand 58 deg twisted on the forearm, the arm looked cut at the wrist).
        local k = norm(sub(wrist, elbow))
        local hp = sub(target.y, mul(k, dot(target.y, k)))
        if len(hp) > 1e-3 then
            hp = norm(hp)
            local ref_roll = math.atan(rh.y.z, rh.y.y) -- hand y from forearm y, about the forearm's x
            local c, sn = math.cos(-ref_roll), math.sin(-ref_roll)
            local fy2 = add(add(mul(hp, c), mul(cross(k, hp), sn)), mul(k, dot(k, hp) * (1 - c)))
            fore = { pos = elbow, x = k, y = fy2, z = cross(k, fy2) }
        end
    end

    return upper, fore, { pos = wrist, x = target.x, y = target.y, z = target.z }
end

local function copy_bone_frame(comp, bone)
    local x, y, z = rotator_axes(ucall(comp, "GetBoneRotationByName", fname(bone), WORLD_SPACE))
    return { pos = copy(ucall(comp, "GetBoneLocationByName", fname(bone), WORLD_SPACE)), x = x, y = y, z = z }
end

local function distance_to_segment(p, a, b)
    local ab = sub(b, a)
    local t = math.max(0, math.min(1, dot(sub(p, a), ab) / math.max(dot(ab, ab), 1e-6)))
    return len(sub(p, add(a, mul(ab, t))))
end

-- Bones outside the arm hierarchy that still skin the hands/forearms (IK targets, armour/glove pieces of the
-- body mesh): found once per copy, by where they sit in the pose, so they can be carried along with the arm.
local STRAY_RADIUS = 12.0
local function find_stray_bones(comp, moved)
    local arm_roots = { b_upperarm_L = true, b_upperarm_R = true }
    local stray = {}
    for i = 0, ucall(comp, "GetNumBones") - 1 do
        local name = ucall(comp, "GetBoneName", i):to_string()
        local in_arm, parent = false, name
        while parent ~= nil and parent ~= "None" and parent ~= "" do
            if arm_roots[parent] then in_arm = true break end
            parent = ucall(comp, "GetParentBone", fname(parent)):to_string()
        end
        -- belt and pouches can sit right next to a hand in the pose, but belong to the body
        -- only the animation's IK / hand / weapon helper bones: body and armour bones (chest armour, spine) can pass close
        -- to a forearm held across the chest, and would then be dragged around with the hand
        local helper = name:find("^b_ik_") or name:find("weapon") or name:find("hand")
        if not in_arm and helper and not name:find("pouch") and not name:find("belt") then
            local pos = copy(ucall(comp, "GetBoneLocationByName", fname(name), WORLD_SPACE))
            for side, m in pairs(moved) do
                if len(sub(pos, m.hand.pos)) < STRAY_RADIUS then
                    table.insert(stray, { bone = name, side = side, on = "hand" })
                    break
                elseif distance_to_segment(pos, m.lo.pos, m.hand.pos) < STRAY_RADIUS then
                    table.insert(stray, { bone = name, side = side, on = "lo" })
                    break
                end
            end
        end
    end
    local list = {}
    for _, s in ipairs(stray) do table.insert(list, s.bone .. "->" .. s.side .. "." .. s.on) end
    log(comp:get_fname():to_string() .. " stray arm bones: " .. table.concat(list, ", "))
    return stray
end

local function set_bone(comp, bone, frame)
    local rot = rot_from_xz(Vector3d.new(frame.x.x, frame.x.y, frame.x.z), Vector3d.new(frame.z.x, frame.z.y, frame.z.z))
    ucall(comp, "SetBoneRotationByName", fname(bone), rot, WORLD_SPACE)
    ucall(comp, "SetBoneLocationByName", fname(bone), Vector3d.new(frame.pos.x, frame.pos.y, frame.pos.z), WORLD_SPACE)
end

-- Where each hand sits on the weapon, taken once per weapon from the game's pose (it sways with the walk animation;
-- the hands must stay where the controllers hold the weapon).
local grips = {}
good_grips = good_grips or {} -- weapon class -> last good grip (global: kept across script reloads)
good_grip_d = good_grip_d or {} -- weapon class -> its right hand's distance to the trigger (smaller = better pose)
-- The right hand sits on the weapon socket in every animation; the left one does not (dash, sprint, one-handed moves:
-- after a dash the left hand held the Lancer 62 cm to the left). A reading is kept only with the left
-- hand where the game's two-handed hold has it: in front of the right one, near the barrel (standard (35,-9.4,-3.3)).
local function left_plausible(L)
    local p = L.pos
    return p.x > 20 and p.x < 60 and math.abs(p.y) < 20 and math.abs(p.z) < 15
end
for k, g in pairs(good_grips) do -- (readings kept from before this check, across script reloads)
    if type(g) == "table" and g.L ~= nil and not left_plausible(g.L) then good_grips[k], good_grip_d[k] = nil, nil end
end
local GRIP_SETTLE = 2.0 -- s in the hand before its hold is learned (the switch animation first)
local GRIP_STEADY = 3   -- equal readings in a row (every frame) to learn it
-- the learned holds, saved and loaded (UEVR Lua io: files in GoWEDay-Steam/data only)
local GRIPS_FILE = "eday_grips.lua"
local function ser_frame(f)
    local function vv(a) return string.format("{x=%.5f,y=%.5f,z=%.5f}", a.x, a.y, a.z) end
    return string.format("{pos=%s,x=%s,y=%s,z=%s}", vv(f.pos), vv(f.x), vv(f.y), vv(f.z))
end
function grips_save()
    local t = { "return {" }
    for k, g in pairs(good_grips) do
        if k ~= "left_std" and k ~= "at_trigger" and type(g) == "table" and g.L and g.R then
            table.insert(t, string.format("  [%q] = { L = %s, R = %s, d = %.3f },", k, ser_frame(g.L), ser_frame(g.R), good_grip_d[k] or 0))
        end
    end
    table.insert(t, "}")
    local f = io.open(GRIPS_FILE, "w")
    if f then f:write(table.concat(t, string.char(10))) f:close() end
end
pcall(function()
    local f = io.open(GRIPS_FILE, "r")
    if not f then return end
    local src = f:read("*a") f:close()
    local ok, t = pcall(load(src))
    if ok and type(t) == "table" then
        for k, g in pairs(t) do
            good_grips[k], good_grip_d[k] = { L = g.L, R = g.R }, g.d
            if left_plausible(g.L) and g.L.pos.z < 5 then good_grips.left_std = g.L end -- (the rifle stand-in)
        end
        log("weapon holds loaded from " .. GRIPS_FILE)
    end
end)
local GRIP_TRIGGER_MAX = 20 -- cm: right hand bone (wrist) to the trigger, for a reading to count as holding the weapon

-- weapon: world frame of the weapon (pos = origin, x = muzzle direction, y = right, z = up)
-- left_weapon: same for an imaginary weapon held by its foregrip in the left controller (free left hand)
-- cam: { pos = eye centre, f = flat forward, r = flat right } of the VR camera
-- Free left hand, holding the controller like a handshake: fingers along the controller's pointing direction, index
-- knuckle up, palm inwards. The hand's own axes come from the knuckle positions in the skeleton's REFERENCE pose, read
-- once per body: the drawn hand keeps its palm bones in that pose, while the game's animated hand (read here before)
-- curls them ~68 deg and moves them with every step - the drawn hand came out bent towards the player and swung up and
-- down while walking (measured: wrist on target, knuckle line 5..94 deg off the controller).
local function free_hand_frame(leader, hand_frame, ctrl, side)
    side = side or "L"
    local key = side == "L" and "free_knuckles" or "free_knuckles_R"
    local k = state[key]
    if k == nil then
        local ok, ref = pcall(function()
            local function knuckle(b) return ref_rel(leader, b .. side, "b_hand_" .. side).pos end
            return { m = knuckle("b_middle_01_"), i = knuckle("b_index_01_"), p = knuckle("b_pinky_01_") }
        end)
        if not ok then -- no reference pose: this frame from the animated hand (as before)
            local function knuckle(b) return relative(hand_frame, bone_frame(leader, b .. side)).pos end
            ref = { m = knuckle("b_middle_01_"), i = knuckle("b_index_01_"), p = knuckle("b_pinky_01_") }
        end
        local fl = norm(ref.m)
        local tl = sub(ref.i, ref.p)
        tl = norm(sub(tl, mul(fl, dot(tl, fl))))
        k = { fl = fl, tl = tl, nl = cross(fl, tl) }
        if ok then state[key] = k end
    end
    local fl, tl, nl = k.fl, k.tl, k.nl
    local fw = norm(ctrl.x)
    local tw = norm(sub(ctrl.z, mul(fw, dot(ctrl.z, fw))))
    local nw = cross(fw, tw)
    local function axis(c) return add(add(mul(fw, fl[c]), mul(tw, tl[c])), mul(nw, nl[c])) end
    return { pos = sub(ctrl.pos, mul(fw, PALM_TO_WRIST)), x = axis("x"), y = axis("y"), z = axis("z") }
end

-- rotate p about unit axis k by angle a (radians)
local function rotate_about(k, a, p)
    local c, s = math.cos(a), math.sin(a)
    return add(add(mul(p, c), mul(cross(k, p), s)), mul(k, dot(k, p) * (1 - c)))
end

-- Grasp: each finger joint, from the knuckle out, closes from the open pose towards the palm until the finger
-- would touch the magazine (HELD_MAG_BOX from gestures.lua, in hand bone coordinates), so the fingers always lie
-- on it whatever its size. Range of each joint in degrees (negative opens the finger).
local FINGER_RADIUS = 1.1 -- cm, half the thickness of a gauntlet finger
local GRASP_RANGE = {
    index = { { -40, 90 }, { -30, 100 }, { -20, 80 } }, middle = { { -40, 90 }, { -30, 100 }, { -20, 80 } },
    ring = { { -40, 90 }, { -30, 100 }, { -20, 80 } }, pinky = { { -60, 90 }, { -40, 100 }, { -30, 80 } },
    thumb = { { -30, 40 }, { -30, 50 }, { -20, 60 } },
}
local grasp_cache = nil -- last grasp, kept while the magazine is not attached (sliding into the weapon)

local function bone_exists(comp, bone)
    local ok, i = pcall(function() return ucall(comp, "GetBoneIndex", fname(bone)) end)
    return ok and i ~= nil and i >= 0
end

-- joints of a finger from joint j out, plus its tip (world)
local function finger_points(comp, finger, first, j)
    local all = {}
    for i = first, first + 2 do
        table.insert(all, copy(ucall(comp, "GetBoneLocationByName", fname(string.format("b_%s_%02d_%s", finger, i, SIDE.sup)), WORLD_SPACE)))
    end
    local tip = string.format("b_%s_%02d_%s", finger, first + 3, SIDE.sup)
    if bone_exists(comp, tip) then
        table.insert(all, copy(ucall(comp, "GetBoneLocationByName", fname(tip), WORLD_SPACE)))
    else -- no tip bone: last segment again, a bit shorter
        table.insert(all, add(all[3], mul(sub(all[3], all[2]), 0.8)))
    end
    return { table.unpack(all, j) }
end

local function grasp_left_fingers(comp, palm_dir, box)
    local hf = copy_bone_frame(comp, "b_hand_" .. SIDE.sup)
    local function touches(p)
        if box.ax ~= nil then
            local d = sub(p, box.cw)
            return math.abs(dot(d, box.ax.x)) < box.h.x + FINGER_RADIUS
               and math.abs(dot(d, box.ax.y)) < box.h.y + FINGER_RADIUS
               and math.abs(dot(d, box.ax.z)) < box.h.z + FINGER_RADIUS
        end
        local d = sub(p, hf.pos)
        return math.abs(dot(d, hf.x) - box.c.x) < box.h.x + FINGER_RADIUS
           and math.abs(dot(d, hf.y) - box.c.y) < box.h.y + FINGER_RADIUS
           and math.abs(dot(d, hf.z) - box.c.z) < box.h.z + FINGER_RADIUS
    end
    local function chain_touches(pts, k, a)
        local prev = pts[1]
        for i = 2, #pts do
            local p = add(pts[1], rotate_about(k, a, sub(pts[i], pts[1])))
            for t = 0.25, 1.0, 0.25 do
                if touches(add(prev, mul(sub(p, prev), t))) then return true end
            end
            prev = p
        end
        return false
    end
    -- All joints are read once (a bone read after its parent was set is stale), then each joint closes in turn with
    -- the joints beyond it carried along by the bends so far, all about the finger's own bending axis.
    local result = {}
    for finger, ranges in pairs(GRASP_RANGE) do
        local first = finger == "thumb" and 0 or 1
        result[finger] = {}
        local pts = finger_points(comp, finger, first, 1)
        local names, frames = {}, {}
        for j = 1, 3 do
            names[j] = string.format("b_%s_%02d_%s", finger, first + j - 1, SIDE.sup)
            frames[j] = copy_bone_frame(comp, names[j])
        end
        local k = norm(cross(norm(sub(pts[2], pts[1])), palm_dir))
        local fixed = box.fixed and box.fixed[finger] -- a set pose for this hold (e.g. the charging handle)
        local total = 0
        for j = 1, 3 do
            local chain = { table.unpack(pts, j) }
            -- close step by step; stop at the first contact (start inside: open until free first)
            local lo, hi = ranges[j][1], ranges[j][2]
            local best, was_free = 0, false
            if fixed then best, lo, hi = fixed[j], 1, 0 end
            for deg = lo, hi, 5 do
                local hit = chain_touches(chain, k, math.rad(deg))
                if not hit then best, was_free = deg, true
                elseif was_free then break end
            end
            -- set poses were tuned as each joint's own bend from the open pose: keep them looking the same
            if fixed then best = fixed[j] - (fixed[j - 1] or 0) end
            result[finger][j] = best
            local a = math.rad(best)
            for i = j + 1, #pts do pts[i] = add(pts[j], rotate_about(k, a, sub(pts[i], pts[j]))) end
            total = total + a
            local f = frames[j]
            local nx, nz = rotate_about(k, total, f.x), rotate_about(k, total, f.z)
            ucall(comp, "SetBoneRotationByName", fname(names[j]),
                rot_from_xz(Vector3d.new(nx.x, nx.y, nx.z), Vector3d.new(nz.x, nz.y, nz.z)), WORLD_SPACE)
        end
    end
    return result
end

-- curl the left fingers from their current (open) pose towards the palm, joint by joint
local function curl_left_fingers(comp, palm_dir, angles_by_finger, side)
    -- All joints of a finger are read first, then set: a bone's position read after its parent was set is not up
    -- to date yet, so bending joint by joint lost the middle joint. Each bone gets its bends so far added up, all
    -- about the finger's own bending axis (across the finger, from the palm side). CURL_ORDER picks the order.
    -- (side "R": the free right hand - mirrored, so the thumb's swing over the fingers turns the other way)
    side = side or SIDE.sup
    for finger, angles in pairs(angles_by_finger or MAG_CURL) do
        local first = finger == "thumb" and 0 or 1
        local frames, names = {}, {}
        for j = 1, 3 do
            names[j] = string.format("b_%s_%02d_%s", finger, first + j - 1, side)
            frames[j] = copy_bone_frame(comp, names[j])
        end
        -- "from": the first joint that moves (thumb in a fist: 2 - its first bone, thumb_00, lies inside the palm
        -- and turning it moved the ball of the hand)
        local from = angles.from or 1
        local k = norm(cross(frames[from].x, palm_dir))
        -- "across" (thumb in a fist): the thumb first swings about the palm's normal, over the curled fingers,
        -- then bends as usual about its (swung) bending axis
        local across = math.rad(angles.across or 0) * (side == "R" and -1 or 1)
        local function swing(p) return across ~= 0 and rotate_about(palm_dir, across, p) or p end
        k = swing(k)
        local total = 0
        local targets = {}
        for j = from, 3 do
            total = total + math.rad(angles[j] or 0)
            local f = frames[j]
            targets[j] = { x = rotate_about(k, total, swing(f.x)), z = rotate_about(k, total, swing(f.z)) }
        end
        local order = CURL_ORDER == "reverse" and { 3, 2, 1 } or { 1, 2, 3 }
        for _, j in ipairs(order) do
          if targets[j] ~= nil then
            local t = targets[j]
            ucall(comp, "SetBoneRotationByName", fname(names[j]), rot_from_xz(Vector3d.new(t.x.x, t.x.y, t.x.z), Vector3d.new(t.z.x, t.z.y, t.z.z)), WORLD_SPACE)
          end
        end
    end
end

-- right index finger on the trigger: its joints bend back (towards the shooter) as far as the trigger is pulled
local TRIGGER_FINGER = { 12, 28, 22 } -- degrees per joint at a full pull
function curl_right_index(comp, back, t, side)
    side = side or "R" -- (the weapon hand's side: L when left-handed)
    for j = 1, 3 do
        local bone = string.format("b_index_%02d_%s", j, side)
        local f = copy_bone_frame(comp, bone)
        local seg = f.x
        local cname = string.format("b_index_%02d_%s", j + 1, side)
        if ucall(comp, "GetBoneIndex", fname(cname)) >= 0 then
            local child = copy(ucall(comp, "GetBoneLocationByName", fname(cname), WORLD_SPACE))
            if len(sub(child, f.pos)) > 0.1 then seg = norm(sub(child, f.pos)) end
        end
        local k = norm(cross(seg, back))
        local a = math.rad(TRIGGER_FINGER[j] * t)
        local nx, nz = rotate_about(k, a, f.x), rotate_about(k, a, f.z)
        ucall(comp, "SetBoneRotationByName", fname(bone), rot_from_xz(Vector3d.new(nx.x, nx.y, nx.z), Vector3d.new(nz.x, nz.y, nz.z)), WORLD_SPACE)
    end
end

-- the empty left hand closes into a fist while its grip button is held (eased, ~0.2 s), and opens again
FIST_CURL = { index = { 55, 60, 35 }, middle = { 58, 60, 35 }, ring = { 60, 62, 35 }, pinky = { 62, 62, 35 }, thumb = { 0, 30, 0, across = 55, from = 2 } } -- thumb: only its finger joints move (swing across the palm 55, bend 30), the palm bone stays
local FIST_SPEED = 6.0 -- per second
-- the left palm's direction, from the hand's own bones (whatever way it is turned): perpendicular to the knuckle
-- line and the fingers, on the side the thumb sits
function palm_normal(comp, side)
    side = side or SIDE.sup
    local function b(n) return copy(ucall(comp, "GetBoneLocationByName", fname(n .. side), WORLD_SPACE)) end
    local hand, index, pinky, middle = b("b_hand_"), b("b_index_01_"), b("b_pinky_01_"), b("b_middle_01_")
    local n = norm(cross(sub(index, pinky), sub(middle, hand)))
    local thumb = b("b_thumb_01_")
    if dot(n, sub(thumb, mul(add(index, pinky), 0.5))) < 0 then n = mul(n, -1) end
    return n
end
local left_fist, fist_clock = 0, nil
local right_fist = 0
local function update_fist()
    local now = os.clock()
    local dt = fist_clock and math.min(now - fist_clock, 0.1) or 0
    fist_clock = now
    local want = LEFT_GRIP_DOWN and (LEFT_FIST_LIMIT or 1) or 0
    local step = FIST_SPEED * dt
    if left_fist < want then left_fist = math.min(want, left_fist + step) else left_fist = math.max(want, left_fist - step) end
    ARMS_LEFT_FIST = left_fist -- (handles.lua: the closed fist is read once it is closed)
    local want_r = (state.right_free and RIGHT_GRIP_DOWN) and 1 or 0
    if right_fist < want_r then right_fist = math.min(want_r, right_fist + step) else right_fist = math.max(want_r, right_fist - step) end
    ARMS_RIGHT_FIST = right_fist
end

-- A hand bone's frame in the weapon socket's coordinates, mirrored across the socket's XZ plane (y -> -y): the same hold
-- for the other hand. Measured on the skeleton's reference pose (both hands, all finger bones): the L bone's axes are
-- the R bone's reflected, with its z axis negated: x' = M x, y' = M y, z' = -M z (M = the reflection; det +1).
local function mirror_grip(f)
    local function m(p) return v(p.x, -p.y, p.z) end
    return { pos = m(f.pos), x = m(f.x), y = m(f.y), z = mul(m(f.z), -1) }
end
-- The animated finger bones' axes in their hand bone's own coordinates (read right after the pose was copied).
local function read_finger_axes(comp, side)
    local hx, hy, hz = rotator_axes(ucall(comp, "GetBoneRotationByName", fname("b_hand_" .. side), WORLD_SPACE))
    local out = {}
    for _, base in ipairs(FINGER_BASES) do
        if bone_exists(comp, base .. side) then
            local x, y, z = rotator_axes(ucall(comp, "GetBoneRotationByName", fname(base .. side), WORLD_SPACE))
            local function loc(a) return v(dot(a, hx), dot(a, hy), dot(a, hz)) end
            out[base] = { x = loc(x), y = loc(y), z = loc(z) }
        end
    end
    return out
end
-- Those fingers on the other hand, mirrored: in hand coordinates the same rule as above, z -> -z.
local function set_mirrored_fingers(comp, axes, to_side, hand)
    local function w(a) return add(add(mul(hand.x, a.x), mul(hand.y, a.y)), mul(hand.z, a.z)) end
    for _, base in ipairs(FINGER_BASES) do
        local r = axes[base]
        if r ~= nil then
            local x, z = w(v(r.x.x, r.x.y, -r.x.z)), w(v(-r.z.x, -r.z.y, r.z.z))
            ucall(comp, "SetBoneRotationByName", fname(base .. to_side), rot_from_xz(Vector3d.new(x.x, x.y, x.z), Vector3d.new(z.x, z.y, z.z)), WORLD_SPACE)
        end
    end
end
eday_on_hand(function() -- switching hands live: nothing of the other hand's holds may stay
    state.lock_offset, state.lock_released = nil, nil
    grasp_cache = nil
    left_fist, right_fist = 0, 0
end)

local function update_arms(pawn, weapon, left_weapon, cam, weapon_object, left_holding, left_controller, left_fingers_closed, left_holding_mag, left_lock)
    update_fist()
    local lefty = EDAY_LEFTY == true
    SIDE.wpn, SIDE.sup = lefty and "L" or "R", lefty and "R" or "L"
    ARMS_WEAPON_SIDE, ARMS_SUPPORT_SIDE = SIDE.wpn, SIDE.sup -- (for the other scripts: which drawn hand holds the weapon)
    if state.pawn ~= pawn then make_copies(pawn) end
    if #state.copies == 0 then return end

    local leader = pawn.Mesh
    local _t = os.clock()
    local function SEC(name) if PROF_SEC then PROF_SEC(name, os.clock() - _t) end _t = os.clock() end
    local frames = {}
    for _, b in ipairs({ "b_spine_01", "b_neck", "b_clavicle_L", "b_clavicle_R", "b_spine_02", "b_spine_03", "sc_chestarmor",
                         "b_upperarm_L", "b_forearm_L", "b_hand_L", "b_upperarm_R", "b_forearm_R", "b_hand_R", WEAPON_SOCKET }) do
        frames[b] = bone_frame(leader, b)
    end

    -- hands: where the animation holds them relative to the weapon socket, carried onto our weapon / left controller
    local socket = frames[WEAPON_SOCKET]
    -- Each weapon has its own hold, learned once from the game's animation and then LOCKED (never read again) and
    -- saved (data/eday_grips.lua: kept across restarts). Learned only after the weapon has been in the hand
    -- GRIP_SETTLE s (right after a switch the game still poses the hands for the previous weapon: the Gnasher took the
    -- Vulcan's top bar, then a torque bow's pose), from GRIP_STEADY equal readings in a row, with the
    -- right hand at the trigger and the left one under the barrel. Until then: a stand-in (the right hand on the
    -- trigger as on the last weapon learned, the left one as on the last rifle).
    local cand = nil
    local now_g = os.clock()
    if state.grip_obj ~= weapon_object then state.grip_obj, state.grip_since, state.grip_seen = weapon_object, now_g, nil end
    local kind = weapon_object:GetOwner():get_class():get_fname():to_string()
    local gkey = wkey(weapon_object) -- (by the weapon actor's name: a new weapon can take a destroyed one's address)
    if grips[gkey] == nil and good_grips[kind] ~= nil then grips[gkey] = good_grips[kind] end
    if grips[gkey] == nil then
        cand = { R = relative(socket, frames.b_hand_R), L = relative(socket, frames.b_hand_L) }
        local trigger, trig_rel = nil, nil -- trig_rel: the trigger in the weapon's own coordinates
        -- (only a skinned weapon: ucall's cache is by name, so on the empty hands' plain component it ran the skinned
        -- mesh's GetBoneIndex on the wrong object - after that, closing the pause menu in a cutscene left the game
        -- paused; bisected to this call)
        for _, tb in ipairs(weapon_object.GetBoneIndex ~= nil and { "b_trigger_01", "b_trigger" } or {}) do
            local ok, idx = pcall(function() return ucall(weapon_object, "GetBoneIndex", fname(tb)) end)
            if ok and idx ~= nil and idx >= 0 then
                local tf = bone_frame(weapon_object, tb)
                trigger = tf.pos
                pcall(function()
                    local wf = { pos = copy(ucall(weapon_object, "K2_GetComponentLocation")), x = copy(ucall(weapon_object, "GetForwardVector")),
                                 y = copy(ucall(weapon_object, "GetRightVector")), z = copy(ucall(weapon_object, "GetUpVector")) }
                    trig_rel = relative(wf, tf)
                end)
                break
            end
        end
        local d = trigger and len(sub(compose(weapon, cand.R).pos, trigger)) or 0
        -- (a pistol: the game holds it one-handed, its left hand never under the barrel - only the right hand counts;
        -- the left one has its own cup hold, weapon.lua pistol_left_frame)
        local pistol = PISTOL_WEAPON == true
        if pistol and not left_plausible(cand.L) and good_grips.left_std ~= nil then cand.L = good_grips.left_std end
        local good = trigger ~= nil and d < GRIP_TRIGGER_MAX and (pistol or left_plausible(cand.L)) and now_g - state.grip_since >= GRIP_SETTLE
        if good then
            local prev = state.grip_seen
            local same = prev ~= nil and len(sub(prev.L.pos, cand.L.pos)) < 1.0 and len(sub(prev.R.pos, cand.R.pos)) < 1.0
            state.grip_seen = { L = cand.L, R = cand.R, n = same and (prev.n + 1) or 1 }
            good = state.grip_seen.n >= GRIP_STEADY
        else
            state.grip_seen = nil
        end
        if good then
            grips[gkey], good_grips[kind], good_grip_d[kind] = cand, cand, d
            if cand.L.pos.z < 5 then good_grips.left_std = cand.L end -- (a rifle-style left hand: the stand-in)
            if trig_rel ~= nil then good_grips.at_trigger = relative(trig_rel, cand.R) end
            pcall(grips_save)
            log(string.format("hold of %s learned (right hand %.1f cm from the trigger, left (%.1f,%.1f,%.1f)) - kept", kind, d, cand.L.pos.x, cand.L.pos.y, cand.L.pos.z))
        else
            if good_grips.at_trigger ~= nil and trig_rel ~= nil then cand = { R = compose(trig_rel, good_grips.at_trigger), L = cand.L } end
            if good_grips.left_std ~= nil then cand.L = good_grips.left_std end
        end
    end
    local grip = grips[gkey] or cand -- no good reading yet: this frame's, and read again next frame
    local grip_w, grip_s = grip.R, grip.L
    if lefty then grip_w, grip_s = mirror_grip(grip.R), mirror_grip(grip.L) end
    local hand_target = {}
    hand_target[SIDE.wpn] = compose(weapon, grip_w)
    hand_target[SIDE.sup] = (left_holding or left_controller == nil) and compose(left_weapon, grip_s)
        or free_hand_frame(leader, frames["b_hand_" .. SIDE.sup], left_controller, SIDE.sup)
    -- the weapon hand free (its weapon put on the back, weapon.lua RIGHT_FREE): held like the free support hand
    if state.right_free and state.right_ctrl ~= nil then
        hand_target[SIDE.wpn] = free_hand_frame(leader, frames["b_hand_" .. SIDE.wpn], state.right_ctrl, SIDE.wpn)
    end
    -- magazine: the hand is locked onto it while it slides along the weapon's well (gestures.lua); when that ends it
    -- eases back onto the controller (LOCK_RELEASE_TIME) and then moves exactly as the free hand, magazine in it.
    -- (It used to keep its offset from the controller for the whole hold - up to 24 cm with a chest magazine: it
    -- turned about another centre and every controller wobble made it jump (measured).)
    local free_L = (not left_holding and left_controller ~= nil) and hand_target[SIDE.sup] or nil
    if left_lock ~= nil then
        if free_L ~= nil then state.lock_offset, state.lock_released = relative(free_L, left_lock), nil end
        hand_target[SIDE.sup] = left_lock
    elseif left_holding_mag and state.lock_offset ~= nil and free_L ~= nil then
        state.lock_released = state.lock_released or os.clock()
        local t = math.min(1, (os.clock() - state.lock_released) / LOCK_RELEASE_TIME)
        if t >= 1 then
            state.lock_offset = nil
        else
            local k, o = 1 - t * t * (3 - 2 * t), state.lock_offset
            local x = norm(add(mul(v(1, 0, 0), 1 - k), mul(o.x, k)))
            local z = norm(add(mul(v(0, 0, 1), 1 - k), mul(o.z, k)))
            z = norm(sub(z, mul(x, dot(z, x))))
            hand_target[SIDE.sup] = compose(free_L, { pos = mul(o.pos, k), x = x, y = cross(z, x), z = z })
        end
    elseif not left_holding_mag then
        state.lock_offset = nil
    end
    if GRIP_DEBUG_ROLL and not left_holding then -- grip test: turn the left hand about its fingers to see the palm
        local L, a = hand_target[SIDE.sup], math.rad(GRIP_DEBUG_ROLL)
        hand_target[SIDE.sup] = { pos = L.pos, x = L.x, y = rotate_about(L.x, a, L.y), z = rotate_about(L.x, a, L.z) }
    end

    -- body: turned around the mesh origin (feet) so the shoulder line is square with the headset's right
    local mesh_loc = copy(ucall(leader, "K2_GetComponentLocation"))
    local pivot = mesh_loc
    local chest_right = flat(sub(frames.b_clavicle_R.pos, frames.b_clavicle_L.pos))
    local angle = math.atan(chest_right.x * cam.r.y - chest_right.y * cam.r.x, dot(chest_right, cam.r))
    local turn = yaw_rotation(angle)

    -- whole body: shift so the (turned) neck sits behind and below the eyes
    local neck = add(pivot, turn(sub(frames.b_neck.pos, pivot)))
    local want = sub(cam.pos, add(mul(cam.f, NECK_BEHIND_CAMERA), v(0, 0, NECK_BELOW_CAMERA)))
    local offset = sub(want, neck)

    local function move_arms()
        local moved = {}
        for _, side in ipairs({ "L", "R" }) do
            moved[side] = {
                up = rotate_frame(frames["b_upperarm_" .. side], turn, pivot, offset),
                lo = rotate_frame(frames["b_forearm_" .. side], turn, pivot, offset),
                hand = rotate_frame(frames["b_hand_" .. side], turn, pivot, offset),
            }
        end
        return moved
    end
    local moved = move_arms()

    -- lean forward if a hand is out of reach
    local lean = 0
    for side, m in pairs(moved) do
        local reach = len(sub(m.lo.pos, m.up.pos)) + len(sub(m.hand.pos, m.lo.pos)) - 0.5
        local to_hand = sub(hand_target[side].pos, m.up.pos)
        local beyond = len(to_hand) - reach
        -- only lean after hands reaching out in front
        if dot(norm(v(to_hand.x, to_hand.y, 0)), cam.f) > 0.5 then
            lean = math.max(lean, math.min(MAX_LEAN, beyond))
        end
    end
    if lean > 0 then
        offset = add(offset, mul(cam.f, lean))
        moved = move_arms()
    end
    -- the torso never in front of the eyes (TORSO): the whole body back as far as needed
    local torso_back = 0
    for _, b in ipairs(TORSO.bones) do
        local p = sub(rotate_frame(frames[b], turn, pivot, offset).pos, cam.pos)
        if math.abs(dot(p, cam.r)) < TORSO.side then
            local t = math.max(0, math.min(1, (p.z - TORSO.low) / (TORSO.high - TORSO.low)))
            torso_back = math.max(torso_back, dot(p, cam.f) + TORSO.clear_low + (TORSO.clear_high - TORSO.clear_low) * t)
        end
    end
    if torso_back > 0 then
        offset = sub(offset, mul(cam.f, torso_back))
        moved = move_arms()
    end
    TORSO_PUSH = torso_back -- (debug: how far the body was moved back this frame)

    -- elbows bend down, outwards and a bit back
    local down = v(0, 0, -1)
    SEC("arms: read leader + grips + move")
    local arms = {}
    for side, sign in pairs({ R = 1, L = -1 }) do
        local m = moved[side]
        -- hand out of reach: the collarbone turns the whole arm towards it first
        local target = hand_target[side].pos
        local reach = len(sub(m.lo.pos, m.up.pos)) + len(sub(m.hand.pos, m.lo.pos)) - 0.5
        local beyond = len(sub(target, m.up.pos)) - reach
        if beyond > 0 then
            local clav = rotate_frame(frames["b_clavicle_" .. side], turn, pivot, offset)
            local arm = sub(m.up.pos, clav.pos)
            local to = sub(target, clav.pos)
            local k = cross(arm, to)
            if len(k) > 1e-3 and len(arm) > 1 then
                k = norm(k)
                local between = math.acos(math.max(-1, math.min(1, dot(norm(arm), norm(to)))))
                local a = math.min(MAX_SHOULDER_TURN, between, beyond / len(arm))
                local function turn_frame(f)
                    return { pos = add(clav.pos, rotate_about(k, a, sub(f.pos, clav.pos))),
                             x = rotate_about(k, a, f.x), y = rotate_about(k, a, f.y), z = rotate_about(k, a, f.z) }
                end
                m.clav = turn_frame(clav)
                m.up, m.lo, m.hand = turn_frame(m.up), turn_frame(m.lo), turn_frame(m.hand)
            end
        else
            m.clav = nil
        end
        -- a hold may ask for its own elbow direction (debug: ELBOW_HINT[side] = { down, out, back }, side "L"/"R"): the Longshot
        -- bolt ball taken over the top turned the forearm 85 deg on the upper arm with the elbow hanging down
        local role = (side == SIDE.sup) and "L" or "R" -- (the holds ask for "L" = the support hand, "R" = the weapon hand)
        local eh = ELBOW_HINT and ELBOW_HINT[role]
        local hint = eh and add(add(mul(down, eh[1]), mul(cam.r, eh[2] * sign)), mul(cam.f, -eh[3]))
            or add(add(down, mul(cam.r, ELBOW_OUT * sign)), mul(cam.f, -ELBOW_BACK))
        state.arm_cache = state.arm_cache or {}
        state.arm_cache[side] = state.arm_cache[side] or {}
        local ac0 = state.arm_cache[side]
        if ac0.ref == nil then -- the reference pose's wrist and sleeve twist, for deroll
            ac0.ref = {}
            pcall(function() ac0.ref.hand = ref_rel(leader, "b_hand_" .. side, "b_forearm_" .. side) end)
            for _, t in ipairs(TWIST_BONES) do
                pcall(function() ac0.ref[t[1] .. side] = ref_rel(leader, t[1] .. side, t[2] .. side) end)
            end
        end
        local upper, fore, hand = solve_arm(m.up, m.lo, m.hand, hand_target[side], hint, state.arm_cache[side])
        -- a hold may roll the forearm about its own line (gestures_fore_roll(side), degrees; side "L"/"R"): the Longshot bolt ball
        -- taken over the top left the forearm turned 90 deg on the upper arm (the arm looked wrung in the middle)
        local fr = (FORE_ROLL and FORE_ROLL[role]) or (gestures_fore_roll and gestures_fore_roll(role)) -- FORE_ROLL: debug override
        if fr ~= nil and fr ~= 0 then
            local a = math.rad(fr) * sign
            fore = { pos = fore.pos, x = fore.x, y = rotate_about(fore.x, a, fore.y), z = rotate_about(fore.x, a, fore.z) }
        end
        local new = { up = upper, lo = fore, hand = hand }
        m.new = new
        arms[side] = { upper, fore, hand }
    end

    state.body = { angle = angle, offset = offset }

    local mesh_rot = ucall(leader, "K2_GetComponentRotation")
    local body_rot = Vector3d.new(mesh_rot.x, mesh_rot.y + math.deg(angle), mesh_rot.z)
    local copy_pos = v(mesh_loc.x + offset.x, mesh_loc.y + offset.y, mesh_loc.z + offset.z)
    state.place = { pos = sub(copy_pos, actor_frame(pawn).pos), rot = body_rot }
    SEC("arms: IK")
    for _, c in ipairs(state.copies) do
      ucall(c.copy, "K2_SetWorldLocationAndRotation", Vector3d.new(mesh_loc.x + offset.x, mesh_loc.y + offset.y, mesh_loc.z + offset.z), body_rot, false, {}, true)
      if not c.shares_first then
        ucall(c.copy, "CopyPoseFromSkeletalComponent", leader)
        -- the sleeve's helper bones (cuff ring, sleeve, forearm aim, upper arm aim): the game drives them for ITS arm
        -- pose; on our arms they bent the cuff wrong. Back to the reference pose (they then simply follow our bones).
        if c.sleeve_helpers == nil then
            c.sleeve_helpers = {}
            for i = 0, ucall(c.copy, "GetNumBones") - 1 do
                local n = ucall(c.copy, "GetBoneName", i):to_string()
                if n:find("^sc_cuff") or n:find("^sc_sleeve") or n:find("^sc_forearm") or n:find("^sc_hand_align") or n:find("^sc_upperarm") then
                    table.insert(c.sleeve_helpers, fname(n))
                end
            end
        end
        for _, n in ipairs(c.sleeve_helpers) do pcall(ucall, c.copy, "ResetBoneTransformByName", n) end
        -- left-handed: the animated (right-handed) hand poses, to be mirrored onto the other hands below
        local anim = nil
        if lefty then anim = { L = read_finger_axes(c.copy, "L"), R = read_finger_axes(c.copy, "R") } end
        SEC("arms: copy pose + place")
        if c.stray == nil then c.stray = find_stray_bones(c.copy, moved) end
        local stray_frames = {}
        for _, sb in ipairs(c.stray) do
            local m = moved[sb.side]
            -- where it sits on the hand / forearm: read once (two engine calls per bone per frame saved)
            if sb.rel == nil then sb.rel = relative(m[sb.on], copy_bone_frame(c.copy, sb.bone)) end
            stray_frames[sb] = compose(m.new[sb.on], sb.rel)
        end
        for side, a in pairs(arms) do
            if moved[side].clav ~= nil then set_bone(c.copy, "b_clavicle_" .. side, moved[side].clav) end
            set_bone(c.copy, "b_upperarm_" .. side, a[1])
            set_bone(c.copy, "b_forearm_" .. side, a[2])
            set_bone(c.copy, "b_hand_" .. side, a[3])
            -- the sleeve's twist bones: held where they sit on the arm in the animation (read once), so the skin
            -- under the armour does not keep twisting with the game's own arm animation
            local ac = state.arm_cache and state.arm_cache[side]
            if ac ~= nil then
                -- a reading is kept only with each twist bone on its arm bone's line (once one was read off it, 13.6 cm
                -- towards the chest, and the left sleeve skin was pulled out of the chest); else read again next frame
                local CHILD = { b_upperarm_ = "b_forearm_", b_forearm_ = "b_hand_" }
                local function off_line(p, a0, a1)
                    local d = sub(a1, a0)
                    local t = dot(sub(p, a0), d) / math.max(dot(d, d), 1e-6)
                    return len(sub(p, add(a0, mul(d, t))))
                end
                if ac.twist == nil then
                    local twist, good = {}, true
                    for _, t in ipairs(TWIST_BONES) do
                        local bone = t[1] .. side
                        local ok, rel = pcall(function()
                            local pf, bf = bone_frame(leader, t[2] .. side), bone_frame(leader, bone)
                            local child = bone_frame(leader, CHILD[t[2]] .. side)
                            if off_line(bf.pos, pf.pos, child.pos) > 1.5 then good = false end
                            local r = relative(pf, bf)
                            local rf = ac.ref and ac.ref[bone]
                            return deroll(r, v(1, 0, 0), rf and rf.y) -- (along the arm bone: its x)
                        end)
                        if ok then twist[bone] = { parent = t[3], rel = rel } end
                    end
                    if good then ac.twist = twist end
                end
                -- with the skeleton's reference pose known, the sleeve's twist bones simply sit on our arm bones as
                -- they do there (the animation reading was often rejected, and then they kept the game's own twist)
                if ac.ref ~= nil and next(ac.ref) ~= nil then
                    local all = true
                    for _, t in ipairs(TWIST_BONES) do if ac.ref[t[1] .. side] == nil then all = false end end
                    if all then
                        local tw = {}
                        for _, t in ipairs(TWIST_BONES) do tw[t[1] .. side] = { parent = t[3], rel = ac.ref[t[1] .. side] } end
                        ac.twist = tw
                    end
                end
                for bone, t in pairs(ac.twist or {}) do
                    local f = compose(a[t.parent], t.rel)
                    local child = a[t.parent + 1]
                    if child ~= nil and off_line(f.pos, a[t.parent].pos, child.pos) > 3 then ac.twist = nil break end
                    pcall(set_bone, c.copy, bone, f)
                end
            end
        end
        for sb, frame in pairs(stray_frames) do
            set_bone(c.copy, sb.bone, frame)
        end
        SEC("arms: set arm/twist/stray bones")
        if lefty then
            -- the weapon hand: the right hand's grip fingers mirrored (the index on the trigger, curled below); the support
            -- hand: when it holds the foregrip with the game's fingers, the left hand's mirrored
            if not state.right_free then pcall(set_mirrored_fingers, c.copy, anim.R, SIDE.wpn, arms[SIDE.wpn][3]) end
            if left_fingers_closed then pcall(set_mirrored_fingers, c.copy, anim.L, SIDE.sup, arms[SIDE.sup][3]) end
        end
        if (RIGHT_TRIGGER or 0) > 0.02 then pcall(curl_right_index, c.copy, mul(weapon.x, -1), RIGHT_TRIGGER, SIDE.wpn) end
        if not left_fingers_closed then
            for _, bone in ipairs(FINGERS[SIDE.sup]) do
                pcall(function() ucall(c.copy, "ResetBoneTransformByName", fname(bone)) end)
            end
            -- around a magazine: from the open hand, curl towards the palm (the controller's right for the left hand)
            if left_holding_mag then
                local palm = mul(hand_target[SIDE.sup].y, -1) -- palm side = -y of the hand bone (both hands: mirrored bones)
                if LEFT_PINCH_CURL ~= nil then
                    -- a set pose (gestures.lua: a round between thumb and index tip, the rest a fist)
                    pcall(curl_left_fingers, c.copy, palm, LEFT_PINCH_CURL)
                elseif HELD_MAG_BOX ~= nil and HELD_MAG_BOX.wl ~= nil then
                    -- a box given in weapon coordinates: on the weapon as drawn this frame
                    local b = HELD_MAG_BOX
                    local function wd(p) return add(add(mul(weapon.x, p.x), mul(weapon.y, p.y)), mul(weapon.z, p.z)) end
                    b.cw = add(weapon.pos, wd(b.wl))
                    -- the box's own axes in weapon coords (wax: e.g. the chainsaw lever, 45 deg off), else the weapon's
                    b.ax = b.wax and { x = wd(b.wax.x), y = wd(b.wax.y), z = wd(b.wax.z) } or { x = weapon.x, y = weapon.y, z = weapon.z }
                end
                if LEFT_PINCH_CURL ~= nil then
                elseif HELD_MAG_BOX ~= nil and HELD_MAG_BOX.fist then
                    -- a plain fist round a bar (the Gnasher's pump tube), closing as the grip is held
                    local angles = {}
                    for finger, a in pairs(FIST_CURL) do
                        angles[finger] = { a[1] * left_fist, a[2] * left_fist, a[3] * left_fist, across = (a.across or 0) * left_fist, from = a.from }
                    end
                    local ok_p, pn = pcall(palm_normal, c.copy)
                    if ok_p and pn ~= nil then pcall(curl_left_fingers, c.copy, pn, angles) end
                elseif HELD_MAG_BOX ~= nil then
                    local ok, res = pcall(grasp_left_fingers, c.copy, palm, HELD_MAG_BOX)
                    if ok then grasp_cache = res else log("grasp: " .. tostring(res)) end
                    if GRIP_DEBUG and ok and os.clock() - (grasp_logged or 0) > 3 then
                        grasp_logged = os.clock()
                        local t = {}
                        for f, a in pairs(res) do table.insert(t, string.format("%s %d/%d/%d", f, a[1], a[2], a[3])) end
                        log("grasp " .. table.concat(t, ", "))
                    end
                else
                    pcall(curl_left_fingers, c.copy, palm, grasp_cache)
                end
            elseif left_fist > 0.01 then
                -- grip pressed on nothing: the hand closes into a fist, smoothly
                local angles = {}
                for finger, a in pairs(FIST_CURL) do
                    angles[finger] = { a[1] * left_fist, a[2] * left_fist, a[3] * left_fist, across = (a.across or 0) * left_fist, from = a.from }
                end
                local ok_p, palm = pcall(palm_normal, c.copy)
                if ok_p and palm ~= nil then pcall(curl_left_fingers, c.copy, palm, angles) end
            end
        end
        if state.right_free then
            -- the free right hand: open (rest pose), closing into a fist while its grip is held
            for _, bone in ipairs(FINGERS[SIDE.wpn]) do
                pcall(function() ucall(c.copy, "ResetBoneTransformByName", fname(bone)) end)
            end
            if right_fist > 0.01 then
                local angles = {}
                for finger, a in pairs(FIST_CURL) do
                    angles[finger] = { a[1] * right_fist, a[2] * right_fist, a[3] * right_fist, across = (a.across or 0) * right_fist, from = a.from }
                end
                local ok_p, palm = pcall(palm_normal, c.copy, SIDE.wpn)
                if ok_p and palm ~= nil then pcall(curl_left_fingers, c.copy, palm, angles, SIDE.wpn) end
            end
        end
        SEC("arms: fingers")
      end
        if TEST_COLLAPSE ~= nil then -- temporary render test: shrink a bone's subtree, keep the hands normal size
            ucall(c.copy, "SetBoneScaleByName", fname(TEST_COLLAPSE), Vector3d.new(0.001, 0.001, 0.001), WORLD_SPACE)
            for side, a in pairs(arms) do set_bone(c.copy, "b_hand_" .. side, a[3]) ucall(c.copy, "SetBoneScaleByName", fname("b_hand_" .. side), Vector3d.new(1, 1, 1), WORLD_SPACE) end
        end

    end

    -- temporary diagnostics
    diag_ticks = (diag_ticks or 0) + 1
    if diag_ticks % 200 == 0 then
        local c = state.copies[1].copy
        local function got(bone) return copy(ucall(c, "GetBoneLocationByName", fname(bone), WORLD_SPACE)) end
        local function d(a, b) return string.format("%.0f", len(sub(a, b))) end
        local function rel(p) local q = sub(p, cam.pos) return string.format("(%.0f,%.0f,%.0f)", dot(q, cam.f), dot(q, cam.r), q.z) end
        log(string.format("turn %.0f deg, offset %.0f cm | upR want %s got %s | handR want %s got %s | neck %s pelvis %s",
            math.deg(angle), len(offset), rel(arms.R[1].pos), rel(got("b_upperarm_R")),
            rel(arms.R[3].pos), rel(got("b_hand_R")), rel(got("b_neck")), rel(got("b_pelvis"))))
    end
end

-- Everything else attached to Marcus (holstered weapons, knife, gadgets) gets the same turn and shift as the body.
-- Called by weapon.lua after the engine tick (the game re-places attached parts during the tick). Each part's
-- original placement (its parent socket + relative transform, as the game set it) is recomputed every frame, then
-- moved with the body, so nothing accumulates.
local attachment_rel = {} -- component -> { parent, socket, rel frame }

-- Weapons on the back stick out over the shoulders, right next to the eyes in first person: hidden while they hang
-- there, shown again as soon as they are taken in hand (or moved elsewhere).
local HIDDEN_ON_SOCKETS = { socket_backmount_l = true, socket_backmount_r = true }
local hidden_actors = {} -- actor -> the socket it was hidden on
local shown_before = {} -- actor -> it was showing when we first hid it (what the game hid itself stays hidden)
local prim_c = api:find_uobject("Class /Script/Engine.PrimitiveComponent")
local function has_visible_parts_early(actor)
    for _, comp in ipairs(ucall(actor, "K2_GetComponentsByClass", prim_c) or {}) do
        local ok, vis = pcall(function() return comp:IsVisible() end)
        if ok and vis then return true end
    end
    return false
end
local function set_actor_hidden(actor, hidden)
    -- never a turret's own gun (it sits on the stand, attached to it): hidden by this, the turret 'vanished' after
    -- getting off it (three times by different callers)
    if hidden then
        local ok, turret = pcall(function()
            local par = actor:GetAttachParentActor()
            return par ~= nil and par:get_class():get_fname():to_string():find("Turret") ~= nil
        end)
        if ok and turret then return end
    end
    if hidden and shown_before[actor] == nil then shown_before[actor] = has_visible_parts_early(actor) end
    for _, comp in ipairs(ucall(actor, "K2_GetComponentsByClass", prim_c) or {}) do
        pcall(function() ucall(comp, "SetHiddenInGame", hidden, false) end)
    end
end
-- The attached actors and how they hang are read again a few times a second (they change only on equip / pickup);
-- every frame only the visible ones are moved.
local ATTACH_REFRESH = 20 -- frames
local attach_list, attach_frame, attach_pawn = {}, 0, nil
local function has_visible_parts(actor)
    for _, comp in ipairs(ucall(actor, "K2_GetComponentsByClass", prim_c) or {}) do
        local ok, vis = pcall(function() return comp:IsVisible() end)
        if ok and vis then return true end
    end
    return false
end
local function refresh_attachments(pawn, equipped)
    local actors = {}
    pcall(function() ucall(pawn, "GetAttachedActors", actors, true, true) end)
    local list = {}
    for _, actor in ipairs(actors) do
        local root = actor.RootComponent
        if root ~= nil and not actor:is_a(controller_c) then
            local socket = root.AttachSocketName
            -- also a weapon just put away: during the swap it still hangs on Marcus' own (hidden) hand socket, which
            -- floats beside the camera, until the game moves it onto the back
            local sname = socket:to_string()
            local on_back = root ~= equipped and (HIDDEN_ON_SOCKETS[sname] == true or sname:find("weapon") ~= nil)
            if on_back and hidden_actors[actor] ~= sname then
                -- hidden again on every socket change: the game shows a weapon when it hangs it on the back
                set_actor_hidden(actor, true)
                hidden_actors[actor] = sname
            elseif not on_back and hidden_actors[actor] then
                set_actor_hidden(actor, false)
                hidden_actors[actor] = nil
            end
            if not on_back and has_visible_parts(actor) then
                -- how the game hung it (relative to its socket): read once per socket and kept. Read again on every
                -- refresh it was our own placement (moving it in the world rewrites its relative transform), so the
                -- turn and shift were added again every 20 frames and the holstered pistol drifted around the player.
                local parent = root.AttachParent
                local known = attachment_rel[root]
                if known == nil or known.socket ~= sname or known.parent ~= parent then
                    local rx, ry, rz = rotator_axes(root.RelativeRotation)
                    known = { socket = sname, parent = parent, rel = { pos = copy(root.RelativeLocation), x = rx, y = ry, z = rz } }
                    -- weapons hang right on their socket (grenade, shotgun, gear all read 0): a reading after a script
                    -- reload would be our own placement, so for weapons it is taken as 0
                    if actor:get_class():get_fname():to_string():find("^BP_Wpn_") then
                        known.rel = { pos = v(0, 0, 0), x = v(1, 0, 0), y = v(0, 1, 0), z = v(0, 0, 1) }
                    end
                    attachment_rel[root] = known
                end
                table.insert(list, { root = root, parent = parent, socket = socket, rel = known.rel })
            end
        end
    end
    attach_list = list
end

-- weapon.lua, while nothing is in hand (mission intros, forced walks): the arms are not drawn and nothing is placed,
-- and a holstered weapon hung visible on Marcus' own hidden body - the pistol floated in front of the camera.
-- Hidden until something is equipped; refresh_attachments shows each one again where it belongs.
local loose_frame = 0
function arms_hide_loose_weapons(pawn)
    loose_frame = loose_frame + 1
    if loose_frame < ATTACH_REFRESH then return end
    loose_frame = 0
    local actors = {}
    pcall(function() ucall(pawn, "GetAttachedActors", actors, true, true) end)
    for _, actor in ipairs(actors) do
        -- only what shows now (what the game itself hides, e.g. gear, must stay hidden when shown again later)
        if hidden_actors[actor] == nil and actor:get_class():get_fname():to_string():find("^BP_Wpn_") and has_visible_parts(actor) then
            local ok, sname = pcall(function() return actor.RootComponent.AttachSocketName:to_string() end)
            if ok then set_actor_hidden(actor, true) hidden_actors[actor] = sname end
        end
    end
end

function place_attachments(pawn, equipped)
    local body = state.body
    if body == nil or state.pawn ~= pawn or #state.copies == 0 then return end
    attach_frame = attach_frame + 1
    for actor, sname in pairs(hidden_actors) do -- a put-away weapon moved (hand -> back): look again right away
        local ok, moved = pcall(function() return actor.RootComponent.AttachSocketName:to_string() ~= sname end)
        if not ok then hidden_actors[actor] = nil elseif moved then attach_frame = ATTACH_REFRESH end
    end
    if attach_pawn ~= pawn or attach_frame >= ATTACH_REFRESH or attach_equipped ~= equipped then
        attach_frame, attach_pawn, attach_equipped = 0, pawn, equipped
        refresh_attachments(pawn, equipped)
    end
    local leader = pawn.Mesh
    local pivot = copy(ucall(leader, "K2_GetComponentLocation"))
    local turn = yaw_rotation(body.angle)
    for _, e in ipairs(attach_list) do
        if e.root ~= equipped and e.parent ~= nil then
            pcall(function()
                local px, py, pz = rotator_axes(ucall(e.parent, "GetSocketRotation", e.socket))
                local placed = compose({ pos = copy(ucall(e.parent, "GetSocketLocation", e.socket)), x = px, y = py, z = pz }, e.rel)
                local moved = rotate_frame(placed, turn, pivot, body.offset)
                if RIG_FIX ~= nil then moved = compose(RIG_FIX.to, relative(RIG_FIX.from, moved)) end -- as the arms
                local rot = rot_from_xz(Vector3d.new(moved.x.x, moved.x.y, moved.x.z), Vector3d.new(moved.z.x, moved.z.y, moved.z.z))
                ucall(e.root, "K2_SetWorldLocationAndRotation", Vector3d.new(moved.pos.x, moved.pos.y, moved.pos.z), rot, false, {}, true)
            end)
        end
    end
end

-- Cutscenes (weapon.lua): the game's own third person view. Marcus' real body is shown again and our drawn copies
-- hidden; what we hid or moved (weapons on his back, the holstered pistol) goes back as the game had it.
-- The drawn meshes follow our posed copy (SetLeaderPoseComponent). Cutscenes re-set the leader of every mesh on
-- Marcus to his own animated mesh (seen after a mid-mission one: the drawn arms played the game's animation, the hand
-- off the weapon, a sleeve in the face). Checked every 30 frames (drawn hand vs posed hand) and set again; `force`
-- sets it regardless.
local relink_frame = 0
function arms_relink_followers(force)
    relink_frame = relink_frame + 1
    if not force and relink_frame % 30 ~= 0 then return end
    local first = state.copies[1]
    if first == nil or first.follower == nil then return end
    if not force then
        local ok, d = pcall(function()
            local a, b = ucall(first.follower, "GetSocketLocation", fname("b_hand_R")), ucall(first.copy, "GetSocketLocation", fname("b_hand_R"))
            return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
        end)
        if not ok or d < 3 then return end
        log(string.format("drawn body left our pose (hand %.0f cm off): leader set again", d))
    end
    for _, c in ipairs(state.copies) do
        if c.follower ~= nil then
            pcall(function() ucall(c.follower, "SetLeaderPoseComponent", c.shares_first and first.copy or c.copy, true) end)
        end
    end
end

function arms_cinematic(pawn, on)
    for _, c in ipairs(state.copies) do
        pcall(function()
            if c.follower ~= nil then ucall(c.follower, "SetHiddenInGame", on, false) end
            ucall(c.src, "SetHiddenInGame", not on, false)
            ucall(c.src, "SetOwnerNoSee", not on)
        end)
    end
    if on then
        -- only what we hid while it showed (the game keeps e.g. the grenade hidden in the hand: it showed in cutscenes)
        for actor in pairs(hidden_actors) do
            if shown_before[actor] then pcall(set_actor_hidden, actor, false) end
        end
        hidden_actors, shown_before = {}, {}
        for root, k in pairs(attachment_rel) do
            pcall(function()
                local r = k.rel
                ucall(root, "K2_SetRelativeLocationAndRotation", Vector3d.new(r.pos.x, r.pos.y, r.pos.z),
                    rot_from_xz(Vector3d.new(r.x.x, r.x.y, r.x.z), Vector3d.new(r.z.x, r.z.y, r.z.z)), false, {}, true)
            end)
        end
        attach_list, attach_frame = {}, ATTACH_REFRESH -- looked at again when play resumes
    else
        pcall(arms_relink_followers, true) -- play resumes: the drawn body follows our pose again
    end
end

ARMS_SCRIPT = true -- weapon.lua sends arms_request only when this script runs

-- gestures.lua attaches a held magazine to the left hand bone of the drawn body
-- weapon.lua, after the engine tick, right before it places the weapon: the body copies are put back where they
-- were meant to be relative to Marcus' position. During the tick the game moves and turns him (stick turning, the
-- swing towards the aim when firing) and the copies, attached to him, turned with him while the weapon did not.
function arms_replace_copies(pawn)
    local p = state.place
    if p == nil or state.pawn ~= pawn then return end
    local at = add(actor_frame(pawn).pos, p.pos)
    local rot = p.rot
    local fix = RIG_FIX -- weapon.lua: the play space moved since the request these arms were posed from
    if fix ~= nil then
        local x, y, z = rotator_axes(rot)
        local f = compose(fix.to, relative(fix.from, { pos = at, x = x, y = y, z = z }))
        at, rot = f.pos, rot_from_xz(Vector3d.new(f.x.x, f.x.y, f.x.z), Vector3d.new(f.z.x, f.z.y, f.z.z))
    end
    for _, c in ipairs(state.copies) do
        pcall(function() ucall(c.copy, "K2_SetWorldLocationAndRotation", Vector3d.new(at.x, at.y, at.z), rot, false, {}, true) end)
    end
end

function arms_rehide_bones() -- (weapon.lua offbody: the drawn body, shown again, lost its hidden shoulder pads for some frames)
    for _, c in ipairs(state.copies) do
        for _, comp in ipairs({ c.copy, c.follower }) do
            if comp ~= nil then
                for _, bone in ipairs(HIDDEN_BONES) do pcall(function() ucall(comp, "HideBoneByName", fname(bone), 0) end) end
            end
        end
    end
end
function arms_is_ours(comp) -- (weapon.lua offbody: the drawn body, never hidden by it)
    for _, c in ipairs(state.copies) do if c.copy == comp or c.follower == comp then return true end end
    return false
end
function arms_is_source(comp) -- (weapon.lua offbody: the meshes of the game's body that we draw copies of stay hidden)
    for _, c in ipairs(state.copies) do if c.src == comp then return true end end
    return false
end

function arms_left_hand_component()
    return state.copies[1] and state.copies[1].copy or nil
end

local errors = 0
local PAWN_SETTLE_TIME = 2.0 -- seconds a new pawn exists before its body is copied (the game is still setting it up)
local clock, pawn_since, pawn_seen = 0, 0, nil
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    clock = clock + delta
    local current = api:get_local_pawn(0)
    if current ~= pawn_seen then
        -- control passes to another pawn (a turret, a vehicle) while Marcus stays in the world: his body back as the
        -- game draws it, before everything about him is forgotten (it is set up again when he is back in control)
        if state.pawn ~= nil and state.pawn ~= current then pcall(arms_cinematic, state.pawn, true) end
        pawn_seen, pawn_since = current, clock
        -- the previous pawn's copies and attachments are destroyed with it: forget them, do not touch them
        state = { pawn = nil, copies = {} }
        attachment_rel, hidden_actors, grips = {}, {}, {}
    end
    -- the game can change Marcus' outfit on the same pawn (casual jacket -> Gears armour at Bravo Squad: new mesh
    -- assets on CharacterMesh0 / Body, the Pants component gone): our copies were of the old outfit, posed from a
    -- skeleton that no longer matched. Checked every 30 frames; on a change the copies are made again.
    outfit_check = (outfit_check or 0) + 1
    if outfit_check >= 30 and state.pawn ~= nil and state.pawn == current and #state.copies > 0 then
        outfit_check = 0
        local changed = ARMS_FORCE_OUTFIT == true -- (debug test)
        ARMS_FORCE_OUTFIT = nil
        for _, c in ipairs(state.copies) do
            local ok, now = pcall(function() return ucall(c.src, "GetSkinnedAsset") end)
            if not ok or now ~= c.asset then changed = true end
        end
        if changed then
            log("outfit changed: body copies made again")
            for _, c in ipairs(state.copies) do
                pcall(function() ucall(c.follower, "K2_DestroyComponent", c.follower) end)
                pcall(function() ucall(c.copy, "K2_DestroyComponent", c.copy) end)
            end
            state = { pawn = nil, copies = {} }
            attachment_rel, grips = {}, {}
            pawn_since = clock -- (settle again: the game is still dressing him)
        end
    end
    local r = arms_request
    if r == nil or r.pawn ~= current or clock - pawn_since < PAWN_SETTLE_TIME then return end
    local ok, err = pcall(function()
        local actor = actor_frame(r.pawn)
        local cam = compose(actor, r.cam_local)
        state.right_free = r.right_free
        state.right_ctrl = r.right_controller_local and compose(actor, r.right_controller_local) or nil
        update_arms(r.pawn, compose(actor, r.weapon_local), compose(actor, r.left_local), { pos = cam.pos, f = cam.x, r = cam.y }, r.weapon_object,
            r.left_holding, r.left_controller_local and compose(actor, r.left_controller_local), r.left_fingers_closed, r.left_holding_mag,
            r.left_lock_local and compose(actor, r.left_lock_local))
    end)
    if not ok then
        errors = errors + 1
        if errors <= 5 then log("error: " .. tostring(err)) end
    end
    pcall(arms_relink_followers, false)
end)

log("loaded")
