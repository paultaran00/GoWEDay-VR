-- Gears of War: E-Day VR gestures (called by weapon.lua every frame):
--   * weapon switch, right grip: hand at the right hip -> pistol; hand over the left shoulder -> weapon on the back.
--     The game's own equip is used, so the weapon in hand goes back to its holster.
--   * manual reload, left grip, with a real magazine object:
--       grab the magazine at the weapon and slide it down out of the well -> it is in the hand;
--       release -> it drops (physics, gone after 30 s), the rounds left in it are lost;
--       grab a fresh one at the chest -> in the hand; release it away from the weapon -> dropped, one magazine of
--       spare ammo lost; bring it to the well -> it lines up, push it in -> the game's reload (spare -> magazine).
-- The game's own reload (RB) and tac-com (LB) buttons are taken over by these gestures (see weapon.lua).
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
    pcall(function() uevr.params.functions.log_info("[gestures] " .. tostring(msg)) end)
end

-- Zones, relative to the headset (cm): forward / right / up, on the flat head direction. Tune here.
local HIP = { up_max = -45, right_min = 5, right_max = 45, fwd_min = -35, fwd_max = 25 }
local OVER_LEFT_SHOULDER = { up_min = -35, right_max = 0, fwd_max = 5 }
local CHEST = { up_min = -75, up_max = -25, right_abs = 30, fwd_min = -15, fwd_max = 35 }
local MAG_GRAB_RADIUS = 14.0    -- left hand to the magazine on the weapon
local MAG_SLIDE_OUT = 6.0       -- how far the hand pulls the magazine before it comes free
local MAG_ALIGN_RADIUS = 12.0   -- a held magazine this close to the well lines up and slides in
local DROPPED_LIFETIME = 30.0  -- seconds before a dropped magazine disappears
-- The magazine in the hand is attached to Marcus' left hand bone, always in the same grip, shaped from its own
-- size and his hand (hand bone axes: x along the fingers, y back of the hand, -y palm side, z index -> little finger;
-- palm ~7.5 cm from the wrist bone to the knuckles, fingers ~10 cm):
--   upright (long side along the knuckle line, its top towards the index = up), one wide side flat against the palm,
--   its width along the fingers (back edge at the heel of the hand, front edge where the fingertips hook over it).
local GRIP_BACK_EDGE = -1.0    -- cm along the fingers from the wrist bone to the magazine's back edge (heel of the hand)
local GRIP_PALM = 2.5          -- cm from the wrist bone's axis to the palm surface (palm side)
local GRIP_HOLD_AT = 0.75      -- the hand holds it at this fraction of its length from the top (near its base)
-- "book": its back edge in the palm, thumb on one side, fingers wrapped round onto the other (a real reload grip);
-- "palm": the old one (palm flat on its wide side, front edge at the fingertips) - kept to go back to
local MAG_HOLD = "palm" -- "book" bends the wrist badly outwards when inserting; palm it is
local GRIP_FRONT_EDGE = 13.5   -- palm hold: the front edge just before the fingers' middle joints (index_02 at 14.3),
                               -- so the fingers bend round it onto the far side instead of lying flat on it
local GRIP_KNUCKLE = 10.0      -- cm along the fingers from the wrist bone to the knuckles (measured on b_hand_L)

-- Magazine meshes per weapon class (the weapon's own magazine is hidden with its bone while it is out).
local MAG_MESHES = {
    { class = "ChainsawLancer", mesh = "StaticMesh /Game/Fairlight/Weapons/COG/LancerChainsaw/MagDefault/COG_LancerChainsaw_MagDefault.COG_LancerChainsaw_MagDefault" },
    { class = "Lancer", mesh = "StaticMesh /Game/Fairlight/Weapons/COG/Lancer/MagDefault/COG_Lancer_MagDefault.COG_Lancer_MagDefault" },
    -- the Locust LMG: two drum magazines standing up on top (left one taken; mag_spec below)
    { class = "LMG", mesh = "StaticMesh /Game/Fairlight/Weapons/Locust/LMG/MagDefault/Locust_LMG_MagDefault.Locust_LMG_MagDefault" },
    -- the Locust shotgun has a real magazine (bone b_mag; 3 rounds), not a tube
    { class = "LocustShotgun", mesh = "StaticMesh /Game/Fairlight/Weapons/Locust/Shotgun/MagDefault/Locust_Shotgun_MagDefault.Locust_Shotgun_MagDefault" },
    { class = "Snub", mesh = "StaticMesh /Game/Fairlight/Weapons/COG/Snub/MagDefault/COG_Snub_MagDefault.COG_Snub_MagDefault" },
    -- the Magnum is the Locust handgun (its own magazine; by name it would look for Locust/Magnum: generic shown)
    { class = "Magnum", mesh = "StaticMesh /Game/Fairlight/Weapons/Locust/Handgun/MagDefault/Locust_Handgun_MagDefault.Locust_Handgun_MagDefault" },
    -- tube (shotguns: one shell at a time into the loading port) and bolt action (one round at a time): not a magazine
    { class = "Gnasher", mesh = "StaticMesh /Game/Fairlight/Effects/Gameplay/Weapons/_Shared/Firing/Meshes/assault_shell_01a.assault_shell_01a" },
    { class = "Longshot", mesh = "StaticMesh /Game/Fairlight/Effects/Gameplay/Weapons/_Shared/Firing/Meshes/assault_shell_01a.assault_shell_01a" },
    { class = "CogGrenadeLauncher", mesh = "StaticMesh /Game/Fairlight/Weapons/COG/Gutpuncher/Projectile02/COG_Gutpuncher_Projectile02.COG_Gutpuncher_Projectile02" }, -- (same as the Gutpuncher)
    { class = "Gutpuncher", mesh = "StaticMesh /Game/Fairlight/Weapons/COG/Gutpuncher/Projectile02/COG_Gutpuncher_Projectile02.COG_Gutpuncher_Projectile02" }, -- (its own canister: 9.4 x 5 cm along x)
    -- the Breechshot has no magazine (no magazine bone): 4 rounds loaded one at a time through the gates on top; its
    -- own round (the projectile model, 6.8 cm along its x)
    { class = "Breechshot", mesh = "StaticMesh /Game/Fairlight/Weapons/Locust/Breechshot/Projectile02/Locust_Breechshot_Projectile02.Locust_Breechshot_Projectile02" },
}
-- rounds loaded one at a time whose model differs from the shotgun casing (length along x, middle at x = center):
-- port = where it goes in (weapon space, cm), scale = shown this much bigger
ROUND_SPECS = {
    -- (the canister: length along x, bounds origin x 0.4, 5 cm across: pinch = a wide hold - thumb and index tips 5.3 cm
    -- apart on opposite sides, the middle finger bent beside the index; shift = the canister's middle this far from the
    -- tips' midpoint towards the middle finger, so thumb, index and middle all lie on its 9.4 cm length)
    Gutpuncher = { port = { x = 18.5, y = 3.0, z = 10.0 }, scale = 1.0, center = 0.4, shift = 2.6,
                   pinch = { index = { 10, 15, 10 }, middle = { 35, 47, 30 }, ring = { 75, 95, 70 }, pinky = { 75, 95, 70 },
                             thumb = { 0, 10, 10, across = 15, from = 2 } } },
    Breechshot = { port = { x = 8.5, y = 0.0, z = 12.0 }, scale = 1.2, center = -1.2, -- (the loading gates on top: b_loadinggates_01..03)
                   handle = "b_handle" }, -- the ribbed knob sticking out on the right, sliding back in its slot (reference photo)
}
ROUND_SPECS.CogGrenadeLauncher = ROUND_SPECS.Gutpuncher -- (practically the same weapon)
function round_spec(weapon)
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    if not ok then return nil end
    for k, sp in pairs(ROUND_SPECS) do if cname:find(k) then return sp end end
    return nil
end
local GENERIC_MAG = "StaticMesh /Game/Fairlight/Weapons/COG/AmmoMagazine/GP01/COG_AmmoMagazineBody_GP01.COG_AmmoMagazineBody_GP01"
local MAG_BONE, MAG_ATTACH_BONE = "b_magazine", "mod_magdefault"
-- Weapons whose magazine is not b_magazine under the weapon (the LMG's two magazines stand up on
-- top, in front). bone / attach = its bones; up = it comes out upwards; socket_axes = the magazine mesh is drawn in its
-- socket's axes (not the weapon's); bone_axes = its bone's axes and the way out is the bone's x (the LMG's drum slabs lean outward). (globals: gestures.lua is at Lua's 200-locals limit)
-- split = two magazines side by side, each with half the rounds (one fresh magazine = half, both = full; A
-- drops the emptier, A again the other). The one being handled is MAG_SIDE[name] ("L" / "R"); MAG_SPLIT[name] =
-- rounds in each (the game counts one total); MAG_OUT[name][side] = that magazine is out of the weapon.
-- free = the magazine is a drum round the barrel axis: the hand is never locked onto it (the lock forced the wrist
-- into a twist whatever the way the hand came in): it jumps into the free hand at the grab and goes in when it is at the well
MAG_SPECS = { LocustShotgun = { bone = "b_mag", attach = "mod_magdefault", free = true }, LMG = { up = true, socket_axes = true, bone_axes = true, hold_low = 6.0, split = {
    L = { bone = "b_magazineleft", attach = "mod_magdefault_L" }, R = { bone = "b_magazineright", attach = "mod_magdefault_R" } } } }
MAG_SIDE = setmetatable({}, { __mode = "k" })
MAG_SPLIT = setmetatable({}, { __mode = "k" })
MAG_OUT = setmetatable({}, { __mode = "k" })
local mag_spec_of = {}
-- (cached by the weapon actor's unique name, not the mesh object: a new weapon can take a destroyed one's address)
function wkey(weapon) local ok, k = pcall(function() return weapon:GetOwner():get_fname():to_string() end) return ok and k or weapon end
function mag_spec(weapon)
    local key = wkey(weapon)
    local sp = mag_spec_of[key]
    if sp == nil then
        sp = { bone = MAG_BONE, attach = MAG_ATTACH_BONE }
        pcall(function()
            local cname = weapon:GetOwner():get_class():get_fname():to_string()
            for k, v in pairs(MAG_SPECS) do
                if cname:find(k) then
                    sp = v
                    if v.split then -- one ready-made table per side
                        sp = { split = v.split, sides = {} }
                        for side, b in pairs(v.split) do
                            sp.sides[side] = { bone = b.bone, attach = b.attach, up = v.up, socket_axes = v.socket_axes, bone_axes = v.bone_axes, hold_low = v.hold_low, split = v.split, side = side }
                        end
                    end
                end
            end
        end)
        mag_spec_of[key] = sp
    end
    if sp.sides then return sp.sides[MAG_SIDE[wkey(weapon)] or "L"] end
    return sp
end
-- the rounds per magazine of a split weapon, kept in step with the game's single total: shots take from the fuller one
function mag_split_sync(weapon, a)
    local sp = mag_spec(weapon)
    if not sp.split or a == nil then return nil end
    local t = math.max(0, a.AmmoInMagazine)
    local c = MAG_SPLIT[wkey(weapon)]
    local out = MAG_OUT[wkey(weapon)] or {}
    if c == nil then c = { L = math.ceil(t / 2), R = math.floor(t / 2) } MAG_SPLIT[wkey(weapon)] = c end
    local half = math.floor(a.MagazineCapacity / 2)
    while c.L + c.R > t do if c.L >= c.R then c.L = c.L - 1 else c.R = c.R - 1 end end
    while c.L + c.R < t do
        if not out.L and c.L <= c.R and c.L < half then c.L = c.L + 1
        elseif not out.R and c.R < half then c.R = c.R + 1
        elseif not out.L then c.L = c.L + 1 else c.R = c.R + 1 end
    end
    return c
end

local inv_c = api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent")
local mag_c = api:find_uobject("Class /Script/TCWeapon.TCWeaponMagazine")
local static_mesh_c = api:find_uobject("Class /Script/Engine.StaticMeshComponent")
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
local weapon_util = api:find_uobject("Class /Script/TCWeapon.TCWeaponUtil"):get_class_default_object()
local names = {}
local function fname(s)
    if names[s] == nil then names[s] = ucall(kismet_string, "Conv_StringToName", s) end
    return names[s]
end

local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a) local l = len(a) return l > 1e-6 and mul(a, 1 / l) or a end
local function copy(u) return v(u.x, u.y, u.z) end
local function rotator_axes(rot)
    local p, y, r = math.rad(rot.x), math.rad(rot.y), math.rad(rot.z)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return v(cp * cy, cp * sy, sp), v(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp), v(-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp)
end
local function relative(a, b)
    local function loc(p) return v(dot(p, a.x), dot(p, a.y), dot(p, a.z)) end
    return { pos = loc(sub(b.pos, a.pos)), x = loc(b.x), y = loc(b.y), z = loc(b.z) }
end
local function compose(a, rel)
    local function w(p) return add(mul(a.x, p.x), add(mul(a.y, p.y), mul(a.z, p.z))) end
    return { pos = add(a.pos, w(rel.pos)), x = w(rel.x), y = w(rel.y), z = w(rel.z) }
end

local function in_zone(p, z)
    return (z.up_min == nil or p.up >= z.up_min) and (z.up_max == nil or p.up <= z.up_max)
        and (z.right_min == nil or p.right >= z.right_min) and (z.right_max == nil or p.right <= z.right_max)
        and (z.right_abs == nil or math.abs(p.right) <= z.right_abs)
        and (z.fwd_min == nil or p.fwd >= z.fwd_min) and (z.fwd_max == nil or p.fwd <= z.fwd_max)
end

local clock = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) clock = clock + delta end)

---------------------------------------------------------------------------------------------------------------
-- weapon switching

local function attached_weapons(pawn)
    local actors = {}
    pcall(function() ucall(pawn, "GetAttachedActors", actors, true, true) end)
    local list = {}
    for _, a in ipairs(actors) do
        if a:get_class():get_fname():to_string():find("^BP_Wpn_") then table.insert(list, a) end
    end
    return list
end

local function equip(pawn, actor)
    local inv = ucall(pawn, "GetComponentByClass", inv_c)
    local ok = ucall(inv, "EquipInventoryItemInSlot", ucall(inv, "GetItemSlotFromInventoryItem", actor), false)
    log("equip " .. actor:get_fname():to_string() .. " -> " .. tostring(ok))
end

local function switch_to_pistol(pawn, held)
    for _, a in ipairs(attached_weapons(pawn)) do
        -- any pistol (weapon.lua PISTOL_CLASSES: the Magnum from the hip too - it only looked for the Snub)
        local cn = a:get_class():get_fname():to_string()
        local is_pistol = false
        for _, k in ipairs(PISTOL_CLASSES or { "Snub" }) do if cn:find(k) then is_pistol = true end end
        if is_pistol and a ~= held then return equip(pawn, a) end
    end
end

local function switch_to_back_weapon(pawn, held)
    local best = nil
    for _, a in ipairs(attached_weapons(pawn)) do
        local socket = a.RootComponent and a.RootComponent.AttachSocketName:to_string() or ""
        if a ~= held and socket:find("backmount") then
            if best == nil or socket == "socket_backmount_l" then best = a end
        end
    end
    if best ~= nil then equip(pawn, best) end
end

---------------------------------------------------------------------------------------------------------------
-- magazines

local function frame_of(comp, socket)
    local x, y, z = rotator_axes(ucall(comp, "GetSocketRotation", fname(socket)))
    return { pos = copy(ucall(comp, "GetSocketLocation", fname(socket))), x = x, y = y, z = z }
end

local function has_bone(weapon, bone) return ucall(weapon, "GetBoneIndex", fname(bone)) ~= -1 end

-- magazine meshes are found in memory, or loaded from the game files when the level has not loaded them yet
local mag_assets = {}
local function load_asset(full_name)
    if eday_asset ~= nil then return eday_asset(full_name) end -- (aa_assets.lua: loaded at the mission start, kept)
    if mag_assets[full_name] ~= nil then return mag_assets[full_name] end
    local ok, obj = pcall(function() return api:find_uobject(full_name) end)
    if not ok or obj == nil then
        local path = full_name:gsub("^%S+%s+", "") -- "StaticMesh /Game/..." -> "/Game/..."
        ok, obj = pcall(function()
            local soft = ucall(kismet_system, "MakeSoftObjectPath", path)
            return ucall(kismet_system, "LoadAsset_Blocking", ucall(kismet_system, "Conv_SoftObjPathToSoftObjRef", soft))
        end)
        log("loaded " .. path .. ": " .. tostring(ok and obj ~= nil))
        if not ok then obj = nil end
    end
    mag_assets[full_name] = obj
    return obj
end

local mag_of_class = {} -- weapon class -> its magazine asset (or false): a failed lookup scans every object (~430 ms)
local mag_mesh_asset_uncached
local function mag_mesh_asset(weapon)
    local cname = weapon:GetOwner():get_class():get_fname():to_string()
    -- with aa_assets.lua the object is asked for each time (its cache is per world: an object kept here from an
    -- earlier mission may be gone after the menu)
    if eday_asset ~= nil then return mag_mesh_asset_uncached(weapon, cname) end
    if mag_of_class[cname] == nil then mag_of_class[cname] = mag_mesh_asset_uncached(weapon, cname) or false end
    return mag_of_class[cname] or nil
end
mag_mesh_asset_uncached = function(weapon, cname)
    for _, m in ipairs(MAG_MESHES) do
        if cname:find(m.class) then return load_asset(m.mesh) or load_asset(GENERIC_MAG) end
    end
    -- any other weapon: its own magazine, by the game's naming (BP_Wpn_<Name>_C -> Weapons/<COG|Locust>/<Name>/MagDefault)
    local name = cname:match("^BP_Wpn_(.-)_C$")
    if name ~= nil then
        name = name:gsub("_Heroic$", "")
        for _, side in ipairs({ "COG", "Locust" }) do
            local asset = string.format("StaticMesh /Game/Fairlight/Weapons/%s/%s/MagDefault/%s_%s_MagDefault.%s_%s_MagDefault", side, name, side, name, side, name)
            -- (with aa_assets.lua only it decides: a nil from it must not fall through to a plain lookup - a missing
            -- magazine (Breechshot) was searched for twice per grab, ~430 ms each)
            local ok, obj = pcall(function() if eday_asset ~= nil then return eday_asset(asset) end return api:find_uobject(asset) end)
            if ok and obj ~= nil then return obj end
        end
    end
    return load_asset(GENERIC_MAG)
end

-- where the magazine sits in the weapon (its frame) and the direction it slides out
local function well(weapon, weapon_frame) return mag_well(weapon, weapon_frame) end
function mag_well(weapon, weapon_frame)
    local f
    local sp = mag_spec(weapon)
    if has_bone(weapon, sp.attach) then f = frame_of(weapon, sp.attach)
    elseif has_bone(weapon, sp.bone) then f = frame_of(weapon, sp.bone)
    else f = compose(weapon_frame, { pos = v(20, 0, -12), x = v(1, 0, 0), y = v(0, 1, 0), z = v(0, 0, 1) }) end
    -- the magazine's axes are the weapon's own: the Snub's socket is turned (its x = weapon right, z = forward), which
    -- laid the pistol magazine flat while sliding in and turned it in the hand (the wrist had to bend to line it up)
    if not sp.socket_axes then f = { pos = f.pos, x = weapon_frame.x, y = weapon_frame.y, z = weapon_frame.z } end
    -- bone_axes (the LMG): the magazine mesh stands upright in its own axes (z along the magazine, its open feed end at -z,
    -- x its depth, y across the slab); the well leans outward along the bone's x (z forward, y across): mesh z = bone x,
    -- mesh x = bone z (the top leans forward as the game's own does), y = -bone y. It comes out along the bone's x.
    -- (In the socket's axes it lay on its edge, turned 90 degrees at the grab, measured against the in-gun magazine.)
    if sp.bone_axes and has_bone(weapon, sp.bone) then
        local b = frame_of(weapon, sp.bone)
        return { pos = f.pos, x = b.z, y = mul(b.y, -1), z = b.x }, b.x
    end
    return f, mul(weapon_frame.z, sp.up and 1 or -1) -- out = down along the weapon (up: the LMG's)
end
-- a split weapon's magazines in (out = false) or out (true): the side nearest point p, nil when there is none
function mag_side_near(weapon, weapon_frame, p, want_out)
    if not mag_spec(weapon).split then return nil end
    local keep, best = MAG_SIDE[wkey(weapon)], nil
    local out = MAG_OUT[wkey(weapon)] or {}
    for _, side in ipairs({ "L", "R" }) do
        if (out[side] == true) == want_out then
            MAG_SIDE[wkey(weapon)] = side
            local w = mag_well(weapon, weapon_frame)
            local d = len(sub(p, w.pos))
            if best == nil or d < best.d then best = { d = d, side = side } end
        end
    end
    MAG_SIDE[wkey(weapon)] = keep
    return best and best.side or nil
end
function mag_any_out(weapon)
    local out = MAG_OUT[wkey(weapon)]
    return out ~= nil and (out.L or out.R) or false
end

local function spawn_mag(pawn, weapon)
    local comp = api:add_component_by_class(pawn, static_mesh_c)
    if comp == nil then return nil end
    ucall(comp, "K2_DetachFromComponent", 1, 1, 1)
    local asset = mag_mesh_asset(weapon)
    ucall(comp, "SetStaticMesh", asset)
    pcall(function() ucall(comp, "SetCollisionEnabled", 0) end)
    return comp
end

local function place(comp, f)
    local rot = rot_from_xz(Vector3d.new(f.x.x, f.x.y, f.x.z), Vector3d.new(f.z.x, f.z.y, f.z.z))
    ucall(comp, "K2_SetWorldLocationAndRotation", Vector3d.new(f.pos.x, f.pos.y, f.pos.z), rot, false, {}, true)
end

local dropped = {} -- { comp, t }

local function drop(comp, velocity)
    -- one that was attached to the hand bone never simulates after the detach (stays in the air, measured): a fresh
    -- copy in its place falls
    pcall(function()
        local fresh = api:add_component_by_class(comp:GetOwner(), static_mesh_c)
        ucall(fresh, "K2_DetachFromComponent", 1, 1, 1)
        ucall(fresh, "SetStaticMesh", comp.StaticMesh)
        ucall(fresh, "K2_SetWorldTransform", ucall(comp, "K2_GetComponentToWorld"), false, {}, true)
        ucall(comp, "K2_DestroyComponent", comp)
        comp = fresh
    end)
    pcall(function()
        ucall(comp, "SetCollisionEnabled", 3) -- query and physics
        ucall(comp, "SetCollisionProfileName", fname("PhysicsActor"), true)
        ucall(comp, "SetSimulatePhysics", true)
        ucall(comp, "SetPhysicsLinearVelocity", Vector3d.new(velocity.x, velocity.y, velocity.z), false, fname("None"))
    end)
    table.insert(dropped, { comp = comp, t = clock })
end

local function ammo(weapon)
    local ok, a = pcall(function() return weapon:GetOwner():GetAmmoState() end)
    return ok and a or nil
end

-- The game's "Auto Reload Mode" option must be "Manual (Reload Button)": the reload button (RB) is masked, so then
-- only the hand reloads. The mod sets it itself (and saves it) whenever it is something else - first launch on a new
-- profile, or changed in the menu. Through the game's settings system, as the menu does.
local SETTING_ASSET = "TCGameplayBlackboardDataAsset /Game/Fairlight/Interface/Settings/SettingsDefinition/BBDA_SettingDefinition_AutoReloadMode_OptionSelectStyle.BBDA_SettingDefinition_AutoReloadMode_OptionSelectStyle"
local SETTING_MANUAL = 2      -- option 2 of the setting: Manual_ReloadButton
local SETTING_CHECK_EVERY = 5 -- seconds
local reload_setting_manual = false
local setting_checked_at, setting_failures = -100, 0
local function check_reload_setting(pc)
    if clock - setting_checked_at < SETTING_CHECK_EVERY or setting_failures > 5 then return end
    setting_checked_at = clock
    local ok, err = pcall(function()
        local def = api:find_uobject(SETTING_ASSET)
        local key = def.Entries[5].Data.Value      -- Settings.Definition.SettingKey
        local opts = def.Entries[8].Data.Value     -- Settings.Definition.OptionAssets
        local sbl = api:find_uobject("Class /Script/Engine.SubsystemBlueprintLibrary"):get_class_default_object()
        local ss = ucall(sbl, "GetLocalPlayerSubSystemFromPlayerController", pc, api:find_uobject("Class /Script/TCSettings.TCSettingsSubsystem"))
        local bbl = api:find_uobject("Class /Script/TCGameplayBlackboard.TCGameplayBlackboardBlueprintLibrary"):get_class_default_object()
        local manual = opts[SETTING_MANUAL]
        if ucall(bbl, "CheckBlackboardKeyMatch", key, ss.SettingsGameplayBlackboard, manual.AssetBlackboard) then
            reload_setting_manual = true
            return
        end
        ucall(ss, "StageSettingValueChange", key, manual.AssetBlackboard, key)
        ucall(ss, "CommitStagedSettingChanges", 0, true)
        ucall(ss, "SaveSettings")
        reload_setting_manual = ucall(bbl, "CheckBlackboardKeyMatch", key, ss.SettingsGameplayBlackboard, manual.AssetBlackboard)
        log("Auto Reload Mode set to Manual (Reload Button): " .. tostring(reload_setting_manual))
    end)
    if not ok then
        setting_failures, reload_setting_manual = setting_failures + 1, false
        log("could not check the Auto Reload Mode setting: " .. tostring(err))
    end
end

uevr.sdk.callbacks.on_pre_engine_tick(function()
    if clock - setting_checked_at < SETTING_CHECK_EVERY then return end
    local pc = api:get_player_controller(0)
    if pc ~= nil then check_reload_setting(pc) end
end)

-- If the setting could not be made manual, the game would reload by itself as soon as the magazine is empty: then
-- one round always stays in it, can't be fired (weapon.lua blocks the trigger) and counts as empty here.
-- Single-shot weapons (capacity 1-2) keep the game's own reload.
local function reserve(a) return (not reload_setting_manual and a ~= nil and a.MagazineCapacity > 2) and 1 or 0 end
local function rounds_left(a) return a.AmmoInMagazine - reserve(a) end
-- the HUD only follows ammo changes made the way firing makes them: consuming 0 rounds refreshes it
local function refresh_hud(weapon)
    for _, o in ipairs(weapon:GetOwner().ReplicatedAssemblyObjects or {}) do
        if o:is_a(mag_c) then pcall(function() ucall(o, "ServerConsumeResource", 0) end) end
    end
end
local function set_mag_rounds(weapon, a, rounds) -- rounds the player can fire
    local n = rounds + reserve(a)
    local pct = n >= a.MagazineCapacity and 1.0 or (n + 0.25) / math.max(1, a.MagazineCapacity)
    ucall(weapon_util, "SetAmmoPercentOnAllMagazines", weapon:GetOwner(), true, pct, false, 0.0)
    refresh_hud(weapon)
    HUD_AT = { w = weapon, frames = 2, n = n } -- (the counter follows only after the engine tick: BA.hud_run)
end
local fire_blocked = false
function gestures_fire_blocked() return fire_blocked end

-- Empty magazine in the weapon: a light flashes on it, on the side the player looks at (a light inside it would not
-- light its outside), bright enough for daylight.
local point_light_c = api:find_uobject("Class /Script/Engine.PointLightComponent")
local GLINT_PERIOD = 1.6         -- s per pulse
local GLINT_CANDELA = 120.0      -- peak brightness (subtle: just enough to notice)
local GLINT_RADIUS = 14.0        -- cm reach of the light (the magazine, not the hand)
local GLINT_OFFSET = 10.0        -- cm from the magazine's middle towards the eyes (just outside its surface)
local GLINT_MAG_MIDDLE = 9.0     -- cm from the top of the magazine (the well) down to its middle
local glint = nil -- { comp, weapon }
local function glint_off()
    if glint ~= nil then pcall(function() ucall(glint.comp, "K2_DestroyComponent", glint.comp) end) end
    glint = nil
end
local GLINT_LIGHT = false -- replaced by the outline
local function glint_update(ctx, on, middle)
    if not GLINT_LIGHT then on = false end
    if glint ~= nil and (not on or glint.weapon ~= ctx.weapon) then glint_off() end
    if not on or ctx.cam_pos == nil then return end
    if glint == nil then
        local c = api:add_component_by_class(ctx.pawn, point_light_c)
        if c == nil then return end
        ucall(c, "K2_DetachFromComponent", 1, 1, 1)
        pcall(function() ucall(c, "SetIntensityUnits", 1) end) -- candelas
        pcall(function() ucall(c, "SetAttenuationRadius", GLINT_RADIUS) end)
        pcall(function() ucall(c, "SetLightColor", { R = 1.0, G = 0.8, B = 0.45, A = 1.0 }, true) end)
        pcall(function() ucall(c, "SetCastShadows", false) end)
        glint = { comp = c, weapon = ctx.weapon }
        log("empty magazine: glint on")
    end
    local p = add(middle, mul(norm(sub(copy(ctx.cam_pos), middle)), GLINT_OFFSET))
    ucall(glint.comp, "K2_SetWorldLocation", Vector3d.new(p.x, p.y, p.z), false, {}, true)
    local phase = (clock % GLINT_PERIOD) / GLINT_PERIOD
    local k = (0.5 - 0.5 * math.cos(phase * 2 * math.pi)) ^ 2 -- a soft pulse
    pcall(function() ucall(glint.comp, "SetIntensity", GLINT_CANDELA * k) end)
end

-- state: idle | sliding_out (magazine in the well, following the hand down) | holding (magazine in hand)
--        | sliding_in (held magazine lined up with the well, pushed in by the hand)
local reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
local hand_history = {}

local function set_weapon_mag_visible(weapon, visible)
    local mb = mag_spec(weapon).bone
    if not has_bone(weapon, mb) then return end
    if visible then ucall(weapon, "UnHideBoneByName", fname(mb)) else ucall(weapon, "HideBoneByName", fname(mb), 0) end
end

local function reset_reload()
    if reload.weapon ~= nil then pcall(set_weapon_mag_visible, reload.weapon, true) end
    if reload.mag ~= nil then pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end) end
    reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
    HELD_MAG_BOX = nil
end

local function weapon_mag_out(weapon)
    -- magazine out of the weapon: hidden there, and nothing to fire
    set_weapon_mag_visible(weapon, false)
    if mag_spec(weapon).split then MAG_OUT[wkey(weapon)] = MAG_OUT[wkey(weapon)] or {} MAG_OUT[wkey(weapon)][MAG_SIDE[wkey(weapon)] or "L"] = true end
end

---------------------------------------------------------------------------------------------------------------
-- Chest pouch: a magazine of the equipped weapon on the chest (in the CHEST zone), the one the hand takes. It is
-- there while there is spare ammo and it is not in the hand; it can always be taken, put back, or thrown away.
local POUCH = { fwd = 10, right = -5, up = -42, side = 1 } -- cm from the eyes on the head's flat facing: the magazine's top
local pouch = nil -- { comp, weapon, shown }
-- left-handed (aa_xr.lua eday_on_hand): the weapon hand's hip (own side) and the shoulder across it, the pouch on the other side
eday_on_hand(function(left)
    if left then
        HIP.right_min, HIP.right_max = -45, -5
        OVER_LEFT_SHOULDER.right_min, OVER_LEFT_SHOULDER.right_max = 0, nil
        POUCH.right, POUCH.side = 5, -1
    else
        HIP.right_min, HIP.right_max = 5, 45
        OVER_LEFT_SHOULDER.right_min, OVER_LEFT_SHOULDER.right_max = nil, 0
        POUCH.right, POUCH.side = -5, 1
    end
end)

-- the pouch magazine's frame (its top, at the well point, like in the weapon): upright, wide side against the chest
local POUCH_ON_CHEST = { fwd = 22.9, right = 5.9, up = -0.3 } -- cm from the chest bone (b_spine_03), body axes
local function pouch_frame(ctx)
    -- on the chest of the drawn body (its facing, not the camera's: that turns with the weapon's aim)
    local body
    local hc = arms_left_hand_component and arms_left_hand_component()
    local ok = hc ~= nil and pcall(function()
        -- the body's facing (follows the head, not the weapon), from the eyes: leaning towards the hands does not move it
        local f = POUCH_USE_BODY and norm(v(ucall(hc, "GetRightVector").x, ucall(hc, "GetRightVector").y, 0)) or ctx.cam_fwd
        local r = v(-f.y, f.x, 0)
        body = { pos = add(ctx.cam_pos, add(add(mul(f, POUCH.fwd), mul(r, POUCH.right)), v(0, 0, POUCH.up))),
                 x = mul(r, POUCH.side), y = mul(f, -POUCH.side), z = v(0, 0, 1) } -- the weapon's frame turned a quarter: its front to the right (left-handed: to the left)
    end)
    if not ok or body == nil then
        local f = ctx.cam_fwd
        local r = v(-f.y, f.x, 0)
        body = { pos = add(ctx.cam_pos, add(add(mul(f, POUCH.fwd), mul(r, POUCH.right)), v(0, 0, POUCH.up))),
                 x = mul(r, POUCH.side), y = mul(f, -POUCH.side), z = v(0, 0, 1) }
    end
    -- the magazine sits in the weapon along the weapon's own axes (see well())
    local rel = { pos = v(0, 0, 0), x = v(1, 0, 0), y = v(0, 1, 0), z = v(0, 0, 1) }
    return compose(body, rel)
end

-- A script reload starts a new Lua state: magazines and rounds the last one had made (the chest one, one in the hand)
-- stay on Marcus, floating where they were. Removed once, before anything new is made.
local purged = false
local function purge_old(pawn)
    purged = true
    local n = 0
    pcall(function()
        for _, c in ipairs(pawn:K2_GetComponentsByClass(static_mesh_c)) do
            local ok, mesh = pcall(function() return c.StaticMesh:get_full_name() end)
            if ok and mesh and c ~= reload.mag and (mesh:find("MagDefault") or mesh:find("AmmoMagazine") or mesh:find("assault_shell")) then
                pcall(function() ucall(c, "K2_DestroyComponent", c) end)
                n = n + 1
            end
        end
    end)
    if n > 0 then log("removed " .. n .. " magazines / rounds left from an earlier load") end
end

local function pouch_update(ctx, show)
    if not purged then purge_old(ctx.pawn) end
    if pouch ~= nil and pouch.weapon ~= ctx.weapon then
        pcall(function() ucall(pouch.comp, "SetStaticMesh", mag_mesh_asset(ctx.weapon)) end)
        pouch.weapon = ctx.weapon
    end
    if pouch == nil then
        if not show then return end
        local c = spawn_mag(ctx.pawn, ctx.weapon)
        if c == nil then return end
        pouch = { comp = c, weapon = ctx.weapon, shown = true }
        POUCH_COMP = c -- (development: tests find it)
    end
    if show ~= pouch.shown then
        pcall(function() pouch.comp:SetVisibility(show, false) end)
        pouch.shown = show
    end
    if not show then return end
    local f = pouch_frame(ctx)
    local ok_c, cname = pcall(function() return ctx.weapon:GetOwner():get_class():get_fname():to_string() end)
    local round_scale = ok_c and (cname:find("Longshot") and 1.3 or ((cname:find("Gnasher") or cname:find("Gutpuncher") or cname:find("CogGrenadeLauncher")) and 1.6)) or nil
    local spec = round_spec(ctx.weapon)
    if spec then
        -- a round standing up (its length along its x), out of the armour towards the front
        local out = mul(f.y, -1)
        place(pouch.comp, { pos = add(f.pos, mul(out, 4.0)), x = v(0, 0, 1), z = out })
        pcall(function() ucall(pouch.comp, "SetWorldScale3D", Vector3d.new(spec.scale, spec.scale, spec.scale)) end)
    elseif round_scale then -- (bolt action / tube, see BA below: this is above it in the file)
        -- a round (shell) standing up (its length is its y), 4 cm out of the armour towards the front, bigger
        local out = mul(f.y, -1)
        place(pouch.comp, { pos = add(f.pos, mul(out, 4.0)), x = f.x, y = v(0, 0, 1), z = out })
        pcall(function() ucall(pouch.comp, "SetWorldScale3D", Vector3d.new(round_scale, round_scale, round_scale)) end)
    else
        place(pouch.comp, f)
        pcall(function() ucall(pouch.comp, "SetWorldScale3D", Vector3d.new(1, 1, 1)) end)
    end
end

---------------------------------------------------------------------------------------------------------------
-- Chamber: a weapon only fires with a round in the chamber. Firing the magazine dry empties it; then, after a fresh
-- magazine goes in, the charging handle (Lancer bolt / pistol slide) must be pulled back to chamber a round. Pulling
-- it with a round already chambered ejects that round (one round lost) and chambers the next.
local BOLT_BONES = { "b_bolt", "b_slide", "b_charginghandle" } -- (b_charginghandle: the LMG's, a lever on each side of the receiver)
local BOLT_GRAB_RADIUS = 8.0 -- cm from the hand to one of the handle's sides to take it (and closer than the magazine)
local BOLT_KNOB_FWD = { b_bolt = 5.5, b_slide = 0.0, b_handle = 0.0, b_charginghandle = -2.0 } -- cm: the knob is this far in front of the handle's bone (seen with markers)
local BOLT_SIDE = { b_bolt = 4.5, b_slide = 2.5, b_handle = 1.5, b_charginghandle = 5.5 } -- (b_handle: the knob itself, right side only) -- cm: taken on either side of the receiver / slide, this far out
local BOLT_TRAVEL = 7.0      -- cm: pulled all the way back (to the end) works it
local BOLT_KNOB = 1.2 -- cm, half size of the handle's knob (what the fingers close on)
-- what the fingers close on: the knob and the receiver's side next to it (cm, weapon axes: along, across, up)
local KNOB_BOX_HALF = v(1.5, 2.3, 2.5)
local BOLT_FINGER_RADIUS = 5.0 -- cm from the fingers to the knob to take it
-- the set hold on the handle (cm): knuckles this far behind / inward of and above the knob
local RACK_HOLD = { behind = 4.0, outside = 2.5, inward = 4.0, above = 3.5, knuckles = 10.0, knuckle_mid = 1.5 }
-- on the handle only index and middle finger hold it; ring and little finger closed into the palm, thumb up
local RACK_FINGERS = { ring = { 75, 95, 70 }, pinky = { 80, 95, 70 }, thumb = { -25, -15, 0 } }
local HAND_TO_GRIP = { x = 16.0, y = -3.0, z = 0.0 } -- hand bone -> where the fingers close (knuckles, palm side)
local chamber = {}           -- weapon -> round chambered
local last_rounds = {}       -- weapon -> rounds last frame (to see it fired dry)
local rack = nil             -- { start, done } while the hand holds the handle

-- Bolt action (the Longshot: one round at a time). The bolt's back end is taken with the left hand: lifted, it turns
-- up (unlocks); turned, it slides back (the round or spent case in the chamber flies out) and stays back when let go;
-- open, a round from the chest goes into the chamber; then the bolt is pushed forward and turned down (locked). It
-- only fires locked.
local BA = {} -- bolt action settings (one table: the file is at Lua's limit of 200 locals)
-- Left-handed play (arms.lua ARMS_SUPPORT_SIDE): the support hand is Marcus' RIGHT hand. Its bones end in _R, and its
-- bone frame is the left one mirrored: x along the fingers and y the back of the hand as on the left hand, but z points
-- to the INDEX finger (left hand: to the little finger). BA.hs() = +1 left hand bone, -1 right hand bone: every
-- offset along the hand's own z (and the hand's pinky -> index axis) is multiplied by it. The weapon is not mirrored.
function BA.sup() return ARMS_SUPPORT_SIDE or "L" end
function BA.hs() return ARMS_SUPPORT_SIDE == "R" and -1 or 1 end
BA.FOREGRIP = { x = 43.7, y = -1.9, z = -2.1 } -- (the same as weapon.lua's FOREGRIP: where the left hand takes the front)
-- weapons whose knob sits elsewhere on the same bone: the classic Lancer's knob is ON b_bolt (sticks out 5.5 cm on
-- each side), not 5.5 cm in front of it like the chainsaw Lancer's (it grabbed air; seen with markers)
BA.KNOB_CLASS = { BP_Wpn_Lancer_C = { fwd = 0.0, side = 5.5 }, BP_Wpn_HammerBurst_C = { fwd = 0.0, side = 4.5 } } -- (the Hammerburst: knob on b_bolt, seen with markers from above)
function BA.knob_point(weapon, bolt, f, side, bb)
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    local k = ok and BA.KNOB_CLASS[cname] or nil
    local fwd, out = k and k.fwd or (BOLT_KNOB_FWD[bb] or 0), k and k.side or (BOLT_SIDE[bb] or 3.0)
    return add(add(bolt, mul(f.y, side * out)), mul(f.x, fwd))
end
-- per weapon: the drawn hand on the charging handle sits this much further back (cm, towards the stock), so the fingertips hook on the knob;
-- the finger curl is worked out against the knob box moved back by the same amount (rack.back), so the hand keeps its shape
BA.HOLD_BACK = { BP_Wpn_HammerBurst_C = 3.5 }
BA.CLASSES = { "Longshot" }
-- Sounds of the reload: the game's own Wwise events, posted as saw.lua does (ClientTCWisePostEventGlobal).
-- Per weapon (first class-name match): out = magazine out, ins = magazine in, rnd = one round / shell in ("folder/Event"
-- under BA.SND_DIR); what a weapon has no event for falls back to BA.SND_DEF (the Lancer's, the Gnasher's).
BA.SND_DIR = "AkAudioEvent /Game/WwiseAudio/Events/Fairlight_Events/Weapons/"
BA.SND_DEF = { out = "Lancer/Play_WEP_Lancer_Reload_ClipEject", ins = "Lancer/Play_WEP_Lancer_Reload_ClipInsert", rnd = "Gnasher/Play_WEP_Gnasher_Reload_Insert",
              hopen = "Lancer/Play_WEP_Lancer_Reload_CockOpen", hclose = "Lancer/Play_WEP_Lancer_Reload_CockClose" }
-- hopen / hclose = the chamber handle (charging handle, slide, bolt, pump) at full pull / back home (others: the Lancer's)
BA.SND_KINDS = { "out", "ins", "rnd", "hopen", "hclose" }
BA.SND = {
    { cls = "LancerMk1", out = "Lancer_MK1/Play_WEP_Lancer_MK1_Reload_ClipEject", ins = "Lancer_MK1/Play_WEP_Lancer_MK1_Reload_ClipInsert",
      hopen = "Lancer_MK1/Play_WEP_Lancer_MK1_Reload_BoltOpen", hclose = "Lancer_MK1/Play_WEP_Lancer_MK1_Reload_Arm" },
    { cls = "Lancer", out = BA.SND_DEF.out, ins = BA.SND_DEF.ins },
    { cls = "HammerBurst", out = "HammerBurst/Play_WEP_Hammerburst_Reload_ClipEject", ins = "HammerBurst/Play_WEP_HammerBurst_Reload_ClipInsert" },
    { cls = "Snub", out = "Snub/Play_WEP_Snub_Reload_ClipEject", ins = "Snub/Play_WEP_Snub_Reload_ClipInsert", hopen = "Snub/Play_WEP_Snub_Reload_CockClose", hclose = "Snub/Play_WEP_Snub_Reload_CockClose" },
    { cls = "Magnum", out = "Snub/Play_WEP_Snub_Reload_ClipEject", ins = "Snub/Play_WEP_Snub_Reload_ClipInsert", hopen = "Snub/Play_WEP_Snub_Reload_CockClose", hclose = "Snub/Play_WEP_Snub_Reload_CockClose" },
    { cls = "LocustShotgun", out = "LocustShotgun/Play_WEP_LocustShotgun_Reload_EjectClip", hopen = "LocustShotgun/Play_WEP_LocustShotgun_Reload_Breech_Open", hclose = "LocustShotgun/Play_WEP_LocustShotgun_Reload_Breech_Close" }, -- (no insert event: the Lancer's)
    { cls = "Longshot", out = "Longshot/Play_WEP_Longshot_Reload_ClipEject", ins = "Longshot/Play_WEP_Longshot_Reload_ClipInsert", hopen = "Longshot/Play_WEP_Longshot_Reload_BoltOpen", hclose = "Longshot/Play_WEP_Longshot_Reload_BoltClose" },
    { cls = "LMG", out = "LocustLMG/Play_WEP_LocustLMG_Reload_ClipEject", ins = "LocustLMG/Play_WEP_LocustLMG_Reload_ClipInsert" },
    { cls = "Breechshot", rnd = "Breechshot/Play_WEP_Breechshot_Reload_InsertShell", hopen = "Breechshot/Play_WEP_Breechshot_Reload_BreechOpen", hclose = "Breechshot/Play_WEP_Breechshot_Reload_Arm" },
    { cls = "Gnasher", hopen = "Gnasher/Play_WEP_Gnasher_Reload_Open", hclose = "Gnasher/Play_WEP_Gnasher_Reload_Close" },
    { cls = "Gutpuncher", out = "Grenade_Launcher/Play_WEP_Gutpuncher_Reload_ClipEject", hopen = "Grenade_Launcher/Play_WEP_Gutpuncher_Reload_CockOpen", rnd = "Grenade_Launcher/Play_WEP_Gutpuncher_Reload_InsertShell" },
    { cls = "CogGrenadeLauncher", hopen = "Grenade_Launcher/Play_WEP_Gutpuncher_Reload_CockOpen", rnd = "Grenade_Launcher/Play_WEP_Gutpuncher_Reload_InsertShell" },
    { cls = "Boomshot", hclose = "Boomshot/Play_WEP_Boomshot_Reload_Arm", out = "Boomshot/Play_WEP_Boomshot_Reload_ClipEject", rnd = "Boomshot/Play_WEP_Boomshot_Reload_InsertShell" },
}
function BA.snd_event(weapon, kind) -- "folder/Event" of this weapon for kind
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    if ok then
        for _, e in ipairs(BA.SND) do
            if cname:find(e.cls) then return e[kind] or BA.SND_DEF[kind] end
        end
    end
    return BA.SND_DEF[kind]
end
function BA.snd_post(weapon, kind) -- kind: "out" | "ins" | "rnd"
    local e = BA.snd_event(weapon, kind)
    local name = e:match("[^/]+$")
    local ev = load_asset(BA.SND_DIR .. e:match("^[^/]+") .. "/" .. name .. "." .. name)
    local posted = false
    if ev ~= nil then posted = pcall(function() api:get_player_controller(0):ClientTCWisePostEventGlobal(ev, nil) end) end
    BA.SND_LOG = BA.SND_LOG or {}
    table.insert(BA.SND_LOG, string.format("%.2f %s %s", clock, kind, name))
    log(string.format("sound %s: %s (%s)", kind, name, posted and "posted" or "not found"))
end
-- Tube (shotguns): a shell from the chest, held like the bolt action's round, pushed into the loading port under the
-- receiver: one more round (one less spare), up to full. No bolt to work.
BA.TUBE_CLASSES = { "Gnasher", "Breechshot", "Gutpuncher", "CogGrenadeLauncher" }
-- tube weapons that take the shell elsewhere than BA.TUBE_PORT (weapon space, cm; r = how close the shell must be).
-- Gutpuncher: the open window in the receiver's right side (no pump, no handle: loaded by hand only, never cycled)
BA.TUBE_PORTS = { Gutpuncher = { x = 18.5, y = 3.0, z = 10.0, r = 6.0 } }
BA.TUBE_PORTS.CogGrenadeLauncher = BA.TUBE_PORTS.Gutpuncher
function BA.tube_port(weapon)
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    if ok then for k, pt in pairs(BA.TUBE_PORTS) do if cname:find(k) then return pt end end end
    return nil
end
BA.FREE_IN = 4.0 -- cm: a drum (MAG_SPECS free) in the free hand goes in this close to the well
BA.TUBE_PORT = v(30.0, 0.0, -1.0) -- weapon space: the loading port (seen on the Gnasher: the receiver's bottom edge)
BA.TUBE_RADIUS = 7.0               -- cm from the shell to the port: it goes in
BA.TUBE_SCALE = 1.6
-- the Breechshot's handle taken over the top (wrist bone from the knob, hand axes): knuckles = along the fingers,
-- pinky = towards the little finger, palm = out of the palm; back of the hand tilted back_up : back_right
BA.HANDLE_HOLD = { behind = 4.0, above = 3.0, out = 3.5, tilt = 60.0, pitch = 0.0 } -- knuckles behind / above / outside the rod; pitch: fingers pointing down (deg); tilt: back of the hand turned outwards (deg)                -- the shell (a casing model) shown this much bigger
-- Pump lever (the Gnasher's loop in front of the trigger, bone b_lever, pulled forward):
-- taken with the left hand and pulled forward to its end, it ejects the chambered shell and chambers the next. After
-- the tube is fired empty, shells pushed in need a pull before it fires again (as the Lancer's charging handle).
BA.PUMP_BONE = "b_lever"
BA.PUMP_AT = v(9.5, 1.5, -10.0)  -- weapon space: middle of the loop's wrapped tube (grab the wrapped part)
BA.PUMP_AXIS = v(-13, 3, -5)     -- the wrapped tube's direction (claw tip (16,0,-6) -> by the grip (3,3,-11), markers)
BA.PUMP_RADIUS = 11.2             -- cm from the hand / its fingers to it: taken
-- easier grabs / pulls: the pistol slide's and the pump's grab x1.6, other handles x1.3; a handle counts as
-- worked at this share of its (still drawn in full) travel: pump 4.2 of 6 cm, slide / charging handles 5.6 of 7, Breechshot 7 of 9
BA.DONE_FRAC = { pump = 0.7, rod = 7 / 9, def = 0.8 }
function BA.done_frac(r) return r.pump and BA.DONE_FRAC.pump or (r.half and BA.DONE_FRAC.rod or BA.DONE_FRAC.def) end
function BA.bolt_radius(bb) return BOLT_GRAB_RADIUS * (bb == "b_slide" and 1.6 or 1.3) end
-- The ammo counter (HUD) did not follow a count changed inside work_handle (only the next shot refreshed it), while the same
-- SetAmmoPercentOnAllMagazines call made a moment later does. set_mag_rounds sets HUD_AT: the count is re-announced 2 frames after:
-- one round off and back (two announced changes, the widget ends on the real count). Run from the engine tick.
function BA.hud_run()
    local h = HUD_AT
    h.frames = h.frames - 1
    if h.frames > 0 then return end
    HUD_AT = nil
    pcall(function()
        local a = ammo(h.w)
        if a == nil then return end
        local n, cap = h.n, a.MagazineCapacity
        if a.AmmoInMagazine ~= n then return end -- (changed again meanwhile - the game's reload etc.: leave it)
        local function setn(r) ucall(weapon_util, "SetAmmoPercentOnAllMagazines", h.w:GetOwner(), true, r >= cap and 1.0 or (r + 0.25) / math.max(1, cap), false, 0.0) end
        setn(n >= cap and n - 1 or n + 1)
        setn(n)
    end)
end
-- (gestures_update runs in the stereo-view callback, where the game does not announce ammo changes: the engine tick does)
uevr.sdk.callbacks.on_pre_engine_tick(function() if HUD_AT ~= nil then BA.hud_run() end end)
function BA.tick() pcall(function() eday_haptic(0.0, 0.05, 140, 0.8, vr.get_left_joystick_source()) end) end
-- Switching weapons: `reload` is one table for the weapon in hand. Called when the weapon in hand is not reload.weapon:
-- a magazine from the chest in the left hand goes back (reset_reload); a weapon whose magazine was dropped (A) is parked
-- (BA.PARKED) and comes back as "empty" - still needing a magazine, its magazine bone still hidden - when it is equipped again.
BA.PARKED = {}
function BA.park_reload()
    local w = reload.weapon
    if reload.state == "empty" or (reload.fresh and reload.prev_state == "empty") then
        if reload.mag ~= nil then pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end) end
        BA.PARKED[wkey(w)] = true
        reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
        HELD_MAG_BOX = nil
    else
        reset_reload()
    end
end
function BA.unpark_reload(ctx, a)
    local k = wkey(ctx.weapon)
    if not BA.PARKED[k] then return end
    BA.PARKED[k] = nil
    if a ~= nil and rounds_left(a) <= 0 and reload.weapon == nil then
        reload = { state = "empty", weapon = ctx.weapon, mag = nil, fresh = false }
        set_weapon_mag_visible(ctx.weapon, false)
    end
end
BA.PUMP_TRAVEL = 6.0             -- cm forward: worked
BA.PUMP_ARM = 20.0               -- cm from the pivot (b_lever) to the hand's place: the loop turns by pull / arm
BA.PUMP_REST = { "b_lever", "b_bolt", "b_lifter", "b_shell" } -- kept at rest on the drawn gun (no self-loading)
BA.PUMP_BOLT = 5.0                -- cm the bolt slides back at the full pull of the pump
BA.PUMP_BOX = v(4.0, 1.5, 1.5)   -- what the fingers close on (weapon axes)
function BA.has_pump(weapon) return BA.is_tube(weapon) and has_bone(weapon, BA.PUMP_BONE) end
-- Breechshot: its handle (b_handle) is a rod sticking out of the receiver's right side, the game slides it back ~10 cm
-- on every shot (recorded); drawn by the copy at rest, it moves only with the hand
BA.HANDLE_REST = { "b_handle", "b_bolt", "b_lifter" } -- kept at rest on the drawn copy
BA.ROD_AT = v(26.0, 6.4, 7.4)    -- weapon space: the rod's middle at rest (seen with markers from above and the side)
BA.ROD_HALF = v(1.3, 2.0, 1.3)   -- the rod, what index and middle finger hook on (weapon axes)
BA.HANDLE_TRAVEL = 9.0           -- cm back: all the way (the game's own slide is 9.8)
function BA.own_handle(weapon) return BA.is_tube(weapon) and not has_bone(weapon, BA.PUMP_BONE) and has_bone(weapon, "b_handle") end
function BA.pump_auto(weapon) return VR_SETTINGS ~= nil and VR_SETTINGS.pump == "auto" and BA.has_pump(weapon) end
function BA.cycle_gun(weapon) return BA.has_pump(weapon) or BA.own_handle(weapon) end
-- Heavy Boomshot: drawn by the copy with b_bolthandle at rest (the game slides it 14 cm per shot), moved only by the hand
function BA.bolt_gun(weapon)
    local ok, c = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    return ok and c == "BP_Wpn_HeavyBoomshot_C" and has_bone(weapon, "b_bolthandle")
end
function BA.rod_world(f) return add(f.pos, add(add(mul(f.x, BA.ROD_AT.x), mul(f.y, BA.ROD_AT.y)), mul(f.z, BA.ROD_AT.z))) end
-- Weapons only held (machine guns, launchers - no hand reload, no handle): the reload button is
-- masked for the hand reloads, so these are reloaded from their spare ammo as soon as they are empty.
BA.HOLD_ONLY = { "Vulcan", "HeavyBoomshot", "TorqueBow", "Troika", "Glaive", "HeavyCore", "Mulcher", "Mortar" }
function BA.hold_only(weapon)
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    if not ok then return false end
    for _, c in ipairs(BA.HOLD_ONLY) do if cname:find(c) then return true end end
    return false
end
function BA.is_tube(weapon)
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    if not ok then return false end
    for _, c in ipairs(BA.TUBE_CLASSES) do if cname:find(c) then return true end end
    return false
end
-- the handle's ball (cm from b_bolt, weapon axes; seen on the weapon): locked it lies on the right side, low; turned up
-- it stands on top
BA.KNOB = { fwd = -0.3, side = 4.6, low = -3.4 } -- (locked; seen from above and from the side)
BA.LIFT = 4.0         -- cm the hand goes up (down) to turn the bolt up (down)
BA.TURN_DEG = 65      -- turned up
BA.TRAVEL = 8.0       -- cm back: all the way
BA.OPEN = 6.0         -- cm back: open (the chamber empties, a round can go in)
BA.CHAMBER = v(14.0, 0.0, 8.0) -- weapon space: where a round goes in (in front of the bolt, open)
BA.INSERT_RADIUS = 8.0 -- cm from the round to the chamber: it goes in
BA.HOLD = { out = 2.5, wrist_up = 7.0, fwd = 3.0 } -- cm: the wrist bone from the ball (out to the right, up, forward)
BA.GRAB_RADIUS = 14.3 -- cm from the hand (or its fingers) to the ball to take it
BA.BALL_HALF = v(1.4, 1.4, 1.4) -- the ball, what thumb, index and middle finger close on
BA.FIST_FINGER = { 75, 95, 70 }
BA.BALL_FINGERS = { ring = BA.FIST_FINGER, pinky = BA.FIST_FINGER } -- (ring and little finger closed in the palm)
-- the ball held with the fingertips: thumb, index and middle nearly straight, ring and little finger in a fist; the
-- hand slides (BA.SETTLE per frame) until the middle of those three tips is on the ball
-- (the fingers grabbed beside the ball): the old nearly straight pinch {10,15,10} / thumb across 45
-- met INSIDE the ball (tips 1.5-1.8 cm from its centre, the ball is 1.4 cm round) and the middle finger hung 4-5 cm in
-- front of it. Now (measured with the hand servo on): thumb tip behind the ball, index tip in front of it, both 2.5 cm
-- from its centre (on its skin, finger thickness included), level with it; middle, ring and little finger closed in
-- the palm (the middle cannot reach the ball in a front/back pinch: 4.5 cm off however curled).
BA.BALL_CURL = { index = { 30, 45, 30 }, middle = BA.FIST_FINGER, ring = BA.FIST_FINGER, pinky = BA.FIST_FINGER,
                 thumb = { 0, 25, 20, across = 15, from = 2 } }
BA.SETTLE = 0.35
-- A pistol's slide, racked from above: the hand over it (palm down, fingers to its right side), thumb down its left
-- side, index and middle down its right side, ring and little finger in a fist; the hand settles so the slide's
-- middle (BA.SLIDE_AT, from b_slide, weapon axes) is between the thumb's and the index' tips
BA.SLIDE_AT = v(-3.0, 0.0, 1.7) -- the rear serrations (the slide ends just behind the hammer)
BA.SLIDE_CURL = { index = { 70, 70, 30 }, middle = BA.FIST_FINGER, ring = BA.FIST_FINGER, pinky = BA.FIST_FINGER,
                  thumb = { 0, 5, 5, across = 10, from = 2 } }
-- the round (a casing model, 1.4 x 5.8 cm, its pivot at its base, its length along its y): shown a little bigger
BA.ROUND_SCALE = 1.3
BA.ROUND_HALF = 2.9 -- cm, half its length (from its pivot to its middle)
BA.POUCH_GRAB = 12.0 -- cm: the left hand must be this close to the pouch item to take / put back (shown item; 8 cm if none shown)
BA.POUCH_PUT_BACK = 20.0 -- cm: let go this close to the pouch (or anywhere in the chest zone): put back, nothing lost
function BA.at_pouch(ctx, radius)
    local ok, d = pcall(function() return len(sub(ctx.left_pos, pouch_frame(ctx).pos)) end)
    return ok and d <= (radius or ((pouch ~= nil and pouch.shown) and BA.POUCH_GRAB or 8.0))
end
BA.POUCH_OUT = 4.0  -- cm: on the chest it stands this far out of the armour
-- the round between thumb and index tip (hand bone axes: x along the fingers, -y palm, -z the index' side); the
-- other fingers closed in a fist
-- (the round itself is put between the thumb's and the index' tips every frame, as they are drawn)
BA.PINCH_INDEX = { 30, 50, 30 }
BA.PINCH_THUMB = { 15, 30, 20 }
BA.ROUND_GRIP = { pos = v(11.0, -3.5, -3.0), x = v(1, 0, 0), y = v(0, 1, 0), z = v(0, 0, 1) } -- (for the hand lock while taken)
BA.ROUND_BOX = { c = v(0, 40, 0), h = v(0.1, 0.1, 0.1), -- (no contact: every finger has its set pose)
    fixed = { index = BA.PINCH_INDEX, thumb = BA.PINCH_THUMB, middle = BA.FIST_FINGER, ring = BA.FIST_FINGER, pinky = BA.FIST_FINGER } }
BOLT_STATE = BOLT_STATE or {} -- weapon key -> { turned 0..1, pulled cm, ejected } (global: kept over script reloads)
local function is_ba(weapon)
    local ok, cname = pcall(function() return weapon:GetOwner():get_class():get_fname():to_string() end)
    if not ok then return false end
    for _, c in ipairs(BA.CLASSES) do if cname:find(c) then return true end end
    return false
end
local function ba_state(weapon)
    local key = weapon:GetOwner():get_full_name()
    local st = BOLT_STATE[key]
    if st == nil then st = { turned = 0, pulled = 0 } BOLT_STATE[key] = st end
    return st
end
function gestures_ba_hold(out, up, fwd) BA.HOLD = { out = out, wrist_up = up, fwd = fwd } end -- (debug: tuning)
-- the ball's hold turned about the weapon's axis from "fingers straight down" by this much: the hand lies on the
-- receiver, fingers over its right side down to the ball (arched high over the weapon, a big gap
-- under it - it must sit right on the weapon)
BA.HOLD_TILT = 65
function gestures_ba_tilt(t) BA.HOLD_TILT = t end -- (debug: tuning, next grab)
-- the left forearm rolled about its own line while it holds the ball (arms.lua asks gestures_fore_roll each frame):
-- with the hand over the top the forearm was turned 94 deg on the upper arm, the arm looked wrung in the middle
-- (rolled to the left). -90: 6 deg left there, the wrist takes the turn, tips 2.5 cm.
BA.FORE_ROLL = -90
function gestures_fore_roll(side)
    if side == "L" and BA.hs() == 1 and rack ~= nil and rack.ba ~= nil then return BA.FORE_ROLL end
    return nil
end
-- the round's hold (arms.lua curls the fingers so; thumb: "across" swings it over towards the index)
BA.PINCH = { index = { 30, 40, 20 }, middle = BA.FIST_FINGER, ring = BA.FIST_FINGER, pinky = BA.FIST_FINGER,
             thumb = { 0, 35, 35, across = 60, from = 2 } } -- (tips 1.7 cm apart: the round between them)
function gestures_ba_pinch(pinch) BA.PINCH = pinch end -- (debug: tuning)
-- the tips of the left thumb and index as drawn (the last bone carried on a little), and the point between them
function gestures_ba_tips()
    local hc = arms_left_hand_component and arms_left_hand_component()
    if hc == nil then return nil end
    local function b(n) return copy(ucall(hc, "GetSocketLocation", fname(n))) end
    local t1, t2 = b("b_thumb_01_" .. BA.sup()), b("b_thumb_02_" .. BA.sup())
    local i2, i3 = b("b_index_02_" .. BA.sup()), b("b_index_03_" .. BA.sup())
    local m2, m3 = b("b_middle_02_" .. BA.sup()), b("b_middle_03_" .. BA.sup())
    local tt = add(t2, mul(sub(t2, t1), 0.7))
    local it = add(i3, mul(sub(i3, i2), 0.7))
    local mt = add(m3, mul(sub(m3, m2), 0.7))
    return tt, it, mul(add(tt, it), 0.5), norm(sub(i3, i2)), mul(add(add(tt, it), mt), 1 / 3)
end
local function ba_closed(st) return st.turned <= 0.02 and st.pulled <= 0.1 end
-- the ball where the drawn bolt has it: turned about the bolt's own axis by as much as the bone is turned
local function ba_ball(bolt, f, st)
    local a = math.rad(BA.TURN_DEG * st.turned)
    local y0, z0 = BA.KNOB.side, BA.KNOB.low
    local side = y0 * math.cos(a) - z0 * math.sin(a)
    local up = y0 * math.sin(a) + z0 * math.cos(a)
    return add(bolt, add(add(mul(f.x, BA.KNOB.fwd - st.pulled), mul(f.y, side)), mul(f.z, up)))
end

-- Chainsaw lever (the Lancer's: lying folded forward along the receiver). Taken with the left hand it stands up;
-- standing, a pull back (it leans back towards the shooter) starts the chainsaw (the game's B held) and it stands
-- up again, and stays up while the chainsaw runs; another pull stops it and it folds back down onto the weapon.
-- Measured from the game's own pose (B held): lying = the handle bone at 0 in component space; standing = turned
-- 45 deg about the component's z; pulled = both lever bones 3.53 cm back along the component's x.
local LEVER_BONE, LEVER_BASE = "b_chainsawHandle", "b_chainsawHandleBase"
local LEVER_GRAB_RADIUS = 6.0  -- cm from the fingers (or the hand) to the handle to take it (9 took it reaching for the charging handle)
local LEVER_TRAVEL = 8.0       -- cm pulled back (the lever goes with the hand, 1:1; its slot is ~8.5 cm): at the end the chainsaw starts / stops
local LEVER_BASE_X = 45.56     -- the lever's base at rest (component x, the game's pose); pulled back from there
local LEVER_UP_DEG = 45.0      -- standing up: the handle turned this far about the component's z (the game's pose)
local LEVER_PULL_CM = 3.53     -- pulled: both lever bones this far back (the game's pull)
local LEVER_RISE_TIME = 0.15   -- s to stand up / fold
LEVER_POS = LEVER_POS or {}    -- weapon -> how far it stands (0 folded .. 1 up), eased
LEVER_UP = LEVER_UP or {}      -- weapon -> standing up
local LEVER_CLOSED_DEG = 45.0
local LEVER_BOX_HALF = v(1.5, 1.5, 3.0) -- what the fingers close on (weapon axes)
local lever = nil              -- { start, mode "raise"/"pull", raise, pulled, toggled, hand_rel, grip_wl, weapon_frame } while held
CHAINSAW_HOLD = false          -- weapon.lua: the game's B held (the chainsaw runs)
-- The lever is always taken with the same overhand hold on the STANDING handle (the hand used to stay wherever
-- the press was - often in the air - and the fingers closed on a point 4 cm above the pivot, where the handle never
-- is). Seen with markers: standing, the handle is level, 45 deg out to the back-left from its pivot,
-- its wrapped grip ~4..14 cm from the pivot. Palm on top, fingers pointing on along the forearm (forward, a little to
-- the left and up), the handle running across the palm on the slant and the fingers closing round it (arms.lua grasp,
-- HELD_MAG_BOX). Fingers square to the handle (knuckle row along it) bent the wrist 70 deg (measured): unnatural.
BA.LEVER_LEN = 15.0             -- cm: the handle's end from its pivot (it can be taken anywhere along it)
BA.LEVER_GRIP_AT = 9.0          -- cm: the middle of the hand on the handle, from the pivot
BA.LEVER_RADIUS = 1.6           -- cm: half the handle's thickness
BA.LEVER_PALM = { fwd = 6.0, out = 2.2 } -- palm middle: along the fingers from the wrist bone / bone line to the palm skin
BA.LEVER_FINGER_YAW = 15.0      -- deg: the fingers point forward along the weapon, turned this far to the left
BA.LEVER_FINGER_UP = 0.15       -- ...and this much up (the forearm rises from the shoulder to the handle)
function BA.lever_axis(lp) -- the handle's direction from its pivot (weapon coords): folded = back along the weapon
    local a = math.rad(LEVER_UP_DEG * (lp or 1))
    return v(-math.cos(a), -math.sin(a), 0)
end
function BA.hand_knuckles(comp) -- knuckle directions in the hand bone's coords, from the skeleton's reference pose
    if BA.KN == nil then
        local function kn(b) return ref_rel(comp, b, "b_hand_" .. BA.sup()).pos end
        local m, i, p = kn("b_middle_01_" .. BA.sup()), kn("b_index_01_" .. BA.sup()), kn("b_pinky_01_" .. BA.sup())
        local fl = norm(m)
        local tl = norm(sub(sub(i, p), mul(fl, dot(sub(i, p), fl))))
        BA.KN = { fl = fl, tl = tl, nl = v(fl.y * tl.z - fl.z * tl.y, fl.z * tl.x - fl.x * tl.z, fl.x * tl.y - fl.y * tl.x) }
    end
    return BA.KN
end
function BA.lever_hold(wfr, pivot_wl, hand_comp) -- the left hand bone's frame (world) holding the standing handle
    local function W(p) return add(add(mul(wfr.x, p.x), mul(wfr.y, p.y)), mul(wfr.z, p.z)) end
    local ax = BA.lever_axis(1)
    local yaw = math.rad(BA.LEVER_FINGER_YAW)
    local fw = norm(W(v(math.cos(yaw), -math.sin(yaw), BA.LEVER_FINGER_UP)))   -- fingers: on along the forearm
    local up = wfr.z
    local hs = BA.hs() -- (the right hand: its index is on the left)
    local tw = mul(v(up.y * fw.z - up.z * fw.y, up.z * fw.x - up.x * fw.z, up.x * fw.y - up.y * fw.x), hs) -- pinky -> index: right
    tw = norm(sub(tw, mul(fw, dot(tw, fw))))
    local nw = v(fw.y * tw.z - fw.z * tw.y, fw.z * tw.x - fw.x * tw.z, fw.x * tw.y - fw.y * tw.x) -- back of the hand (up)
    local k = BA.hand_knuckles(hand_comp)
    local function axis(c) return add(add(mul(fw, k.fl[c]), mul(tw, k.tl[c])), mul(nw, k.nl[c])) end
    local grip = add(wfr.pos, W(add(pivot_wl, mul(ax, BA.LEVER_GRIP_AT))))
    local palm = add(grip, mul(nw, (BA.LEVER_RADIUS + BA.LEVER_PALM.out) * hs))
    return { pos = sub(palm, mul(fw, BA.LEVER_PALM.fwd)), x = axis("x"), y = axis("y"), z = axis("z") }
end

local function weapon_key(weapon) return weapon:GetOwner():get_full_name() end
local function bolt_bone(weapon)
    if BA.hold_only(weapon) then return nil end -- (only held: their handles are not worked)
    local spec = round_spec(weapon) -- (a weapon loaded one round at a time with its own handle: the Breechshot)
    if spec and spec.handle and has_bone(weapon, spec.handle) then return spec.handle end
    for _, b in ipairs(BOLT_BONES) do if has_bone(weapon, b) then return b end end
    return nil
end

local relinked_gcs = {} -- gc -> true (see the bolt copy below)
-- weapon.lua calls this right after placing the weapon in the hand: its pieces (geometry collection) are drawn
-- from this, so they show exactly where the weapon is this frame
local gc_of = {}
-- the drawn weapon (its geometry collection) follows its skeleton only when told every frame - in cutscenes too
-- Sends a geometry collection's skinned pieces to the renderer: at most once a frame, and never for one that is no
-- longer valid or whose weapon is being destroyed (mid-mission cutscenes swap and destroy weapons; a transfer then
-- crashed the game on a worker thread, twice). Returns false for a dead one.
GC_FRAME, gc_sent = 0, setmetatable({}, { __mode = "k" })
-- (none while the game is paused: nothing moves, and a transfer then - even of our own relinked pieces, in a
-- cutscene - left the game stuck paused after the pause menu was closed; bisected to gestures.lua)
local statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local paused_frame, paused = -1, false
-- early = sent from the pre-tick, BEFORE this frame's placement of the weapon: it carries last frame's positions (a walking
-- hand: 4-8 cm behind, drawn one frame late = the weapon flickers), so it does not count as this frame's transfer: the one
-- after the placement (gestures_weapon_placed) is the one that must be the last
function GC_TRANSFER(gc, early)
    if gc_sent[gc] == GC_FRAME then return true end
    if paused_frame ~= GC_FRAME then
        paused_frame = GC_FRAME
        local pc = api:get_player_controller(0)
        paused = pc ~= nil and statics:IsGamePaused(pc)
    end
    if paused then return true end
    local ok, alive = pcall(function()
        if not ucall(kismet_system, "IsValid", gc) then return false end
        local owner = gc:GetOwner()
        return owner ~= nil and ucall(kismet_system, "IsValid", owner) and not owner:IsActorBeingDestroyed()
    end)
    if not (ok and alive) then return false end
    if not early then gc_sent[gc] = GC_FRAME end
    pcall(function() ucall(gc, "TransferSkinningFromGTtoRT") end)
    return true
end

function gestures_gc_sync(weapon)
    local gc = gc_of[wkey(weapon)]
    if gc == nil then
        pcall(function() gc = weapon:GetOwner():K2_GetComponentsByClass(api:find_uobject("Class /Script/GeometryCollectionEngine.GeometryCollectionComponent"))[1] end)
        gc_of[wkey(weapon)] = gc or false
    end
    -- only pieces we relinked (the game stopped sending those) are ours; the game moves its own weapons' pieces. Sending
    -- the game's own (this is called outside normal play: cutscenes, stands, and also while PAUSED) left the game stuck
    -- paused after the pause menu was closed with B (found by bisecting: gestures.lua -> this call)
    if gc and relinked_gcs[gc] then GC_TRANSFER(gc) end
end

function gestures_weapon_placed(weapon)
    local gc = gc_of[wkey(weapon)]
    if gc == nil then
        pcall(function() gc = weapon:GetOwner():K2_GetComponentsByClass(api:find_uobject("Class /Script/GeometryCollectionEngine.GeometryCollectionComponent"))[1] end)
        gc_of[wkey(weapon)] = gc or false
    end
    if gc then GC_TRANSFER(gc) end
    if laser_update ~= nil then
        local ok, err = pcall(laser_update, weapon)
        if not ok then laser_errors = (laser_errors or 0) + 1 if laser_errors % 200 == 1 then log("laser error: " .. tostring(err)) end end
    end
end
---------------------------------------------------------------------------------------------------------------
-- Laser: the small slider above the trigger (left side) switches it. The left fingers on the slider + grip press
-- flip it; a red beam goes from the muzzle along the barrel to whatever it hits, with a dot there.
LASER_ON = LASER_ON or {} -- weapon class -> on (global: kept across script reloads)
local LASER_SWITCH = { ChainsawLancer = { fwd = 2.0, up = 1.5, side = -4.5 }, Lancer = { fwd = 2.0, up = 1.5, side = -4.5 },
                       Gnasher = { fwd = 2.0, up = 1.5, side = -4.5 }, Snub = { fwd = 2.0, up = 1.5, side = -2.5 }, -- cm, weapon axes (left side)
                       -- turret guns (on a stand or carried): the right stick press only (no slider: out of reach)
                       Breechshot = { fwd = 0, up = 1000, side = 0 }, Vulcan = { fwd = 0, up = 1000, side = 0 }, Troika = { fwd = 0, up = 1000, side = 0 }, HeavyBoomshot = { fwd = 0, up = 1000, side = 0 } }
local LASER_TOUCH = 4.5        -- cm from the fingers to the slider to flip it
local LASER_RANGE = 5000       -- cm
local LASER_RADIUS = 0.15      -- cm (beam thickness / 2)
local LASER_COLOR = { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }
local LASER_GLOW = 18.0        -- beam brightness (additive glow; 12 was lost in daylight, 30 bloomed into blobs far away)
local LASER_DOT_GLOW = 12.0    -- the dot where it lands (15: too dim; 40: lit too much up close; 60+: a ball)
local LASER_DOT = 0.125         -- cm, the dot's size up close
local LASER_DOT_ANGLE = 0.00014 -- cm of dot per cm of distance (0.0036 was too big: just a small bright end)
local LASER_LIGHT_CD = 0.5       -- candela of the red light at the dot (faint)
local LASER_LIGHT_RADIUS = 4.0 -- cm it reaches (small spot; also how its leftovers are recognised after a reload)
-- Far away a fixed-width beam gets thinner than a pixel and flickers in and out: the beam is drawn as segments,
-- each as thick as needed to keep about the same width on screen (LASER_ANGLE cm per cm of distance)
local LASER_ANGLE = 0 -- one thickness all the way (growing with distance it looked like several lasers)
local LASER_SEGMENTS = { 5000 } -- cm: one piece (segments of different glow looked like several lasers)
local LASER_MATERIAL = "Material /Game/Fairlight/Lighting/Materials/M_GlowMaster.M_GlowMaster"
local laser = nil              -- { beam, dot }
local laser_material_lib = api:find_uobject("Class /Script/Engine.KismetMaterialLibrary"):get_class_default_object()
local function lcross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local laser_hit = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
local laser_no_color = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))

local function weapon_kind(weapon)
    local cname = weapon:GetOwner():get_class():get_fname():to_string()
    for k in pairs(LASER_SWITCH) do if cname:find(k) then return k end end
    return nil
end

-- right stick press (weapon.lua): flip the laser of the weapon in hand
function laser_toggle(weapon)
    local kind = weapon and weapon_kind(weapon)
    if kind == nil then return end
    LASER_ON[kind] = not LASER_ON[kind]
    log("laser " .. (LASER_ON[kind] and "on" or "off") .. " (stick)")
end

-- the fingers touching the slider: flip the laser (called on a left grip press, before other grabs)
function laser_try_switch(ctx)
    local kind = weapon_kind(ctx.weapon)
    if kind == nil then return false end
    local sw, f = LASER_SWITCH[kind], ctx.weapon_frame
    local p = add(f.pos, add(add(mul(f.x, sw.fwd), mul(f.z, sw.up)), mul(f.y, sw.side)))
    local fingers = ctx.left_pos
    local hc = arms_left_hand_component and arms_left_hand_component()
    if hc ~= nil then
        pcall(function() fingers = mul(add(copy(ucall(hc, "GetSocketLocation", fname("b_index_02_" .. BA.sup()))), copy(ucall(hc, "GetSocketLocation", fname("b_index_03_" .. BA.sup())))), 0.5) end)
    end
    if len(sub(fingers, p)) > LASER_TOUCH then return false end
    LASER_ON[kind] = not LASER_ON[kind]
    log("laser " .. (LASER_ON[kind] and "on" or "off"))
    return true
end

local function laser_part(pawn, mesh_path, mat)
    local c = api:add_component_by_class(pawn, static_mesh_c)
    ucall(c, "K2_DetachFromComponent", 1, 1, 1)
    ucall(c, "SetStaticMesh", api:find_uobject(mesh_path))
    pcall(function() ucall(c, "SetCollisionEnabled", 0) end)
    pcall(function() ucall(c, "SetCastShadow", false) end)
    for i = 0, ucall(c, "GetNumMaterials") - 1 do ucall(c, "SetMaterial", i, mat) end
    return c
end

-- the beam segments and the dot, with their glowing material (once per pawn)
function laser_create(weapon)
    local pawn = api:get_local_pawn(0)
    -- the laser made for another pawn (a turret one is in control of): its parts go first (left drawn where they were)
    if laser ~= nil then
        for _, c in ipairs(laser.segs or {}) do pcall(function() c:K2_DestroyComponent(c) end) end
        for _, c in ipairs({ laser.dot, laser.light }) do pcall(function() c:K2_DestroyComponent(c) end) end
        laser = nil
    end
    local mat = nil
    if eday_asset ~= nil then mat = eday_asset(LASER_MATERIAL) else mat = api:find_uobject(LASER_MATERIAL) end
    -- the lasers of earlier script loads (their parts stay on the pawn, drawn where they were left: 31 of them were
    -- found - the extra lines and the bright patch mid-beam): every cylinder / sphere with a glow material goes
    pcall(function()
        for _, c in ipairs(ucall(pawn, "K2_GetComponentsByClass", api:find_uobject("Class /Script/Engine.StaticMeshComponent"))) do
            pcall(function()
                local m = c.StaticMesh and c.StaticMesh:get_fname():to_string()
                if m == "Cylinder" or m == "Sphere" then
                    local mi = c:GetMaterial(0)
                    local parent = mi and mi.Parent
                    if (parent and parent == mat) or mi == mat then c:K2_DestroyComponent(c) end
                end
            end)
        end
        for _, c in ipairs(ucall(pawn, "K2_GetComponentsByClass", point_light_c)) do
            pcall(function() local r = c.AttenuationRadius if math.abs(r - LASER_LIGHT_RADIUS) < 0.01 or math.abs(r - 37.5) < 0.01 or math.abs(r - 12.5) < 0.01 then c:K2_DestroyComponent(c) end end)
        end
    end)
    local function glow(brightness)
        local mid = ucall(laser_material_lib, "CreateDynamicMaterialInstance", pawn, mat, fname("None"), 0)
        ucall(mid, "SetVectorParameterValue", fname("Light Color"), LASER_COLOR)
        ucall(mid, "SetScalarParameterValue", fname("Glow Brightness"), brightness)
        ucall(mid, "SetScalarParameterValue", fname("Fresnel Power"), 0)
        return mid
    end
    local beam_mat = glow(LASER_GLOW)
    laser = { pawn = pawn, segs = {}, warm = 2,
              dot = laser_part(pawn, "StaticMesh /Engine/BasicShapes/Sphere.Sphere", glow(LASER_DOT_GLOW)) }
    for i = 1, #LASER_SEGMENTS do
        -- a thicker (farther) segment glows less, in proportion: the beam looks the same all the way, as where it
        -- leaves the weapon (one brightness for all made the far, wider ones bloom into blobs; only the dot is bright)
        local r = math.max(LASER_RADIUS, LASER_SEGMENTS[i] * LASER_ANGLE)
        local m = (r > LASER_RADIUS * 1.01) and glow(LASER_GLOW * LASER_RADIUS / r) or beam_mat
        laser.segs[i] = laser_part(pawn, "StaticMesh /Engine/BasicShapes/Cylinder.Cylinder", m)
    end
    laser.beam = laser.segs[1]
    -- a small red light at the dot: the surface it lands on lights up, like a real laser's spot
    pcall(function()
        local c = api:add_component_by_class(pawn, point_light_c)
        ucall(c, "K2_DetachFromComponent", 1, 1, 1)
        pcall(function() ucall(c, "SetIntensityUnits", 1) end) -- candelas
        ucall(c, "SetIntensity", LASER_LIGHT_CD)
        ucall(c, "SetAttenuationRadius", LASER_LIGHT_RADIUS)
        ucall(c, "SetLightColor", { R = 1.0, G = 0.05, B = 0.02, A = 1.0 }, true)
        pcall(function() ucall(c, "SetCastShadows", false) end)
        c:SetVisibility(false, false)
        laser.light = c
    end)
end

function laser_update(weapon)
    local kind = weapon_kind(weapon)
    local on = kind ~= nil and LASER_ON[kind] and eday_muzzle_name(weapon) ~= nil
    if not on then
        if laser ~= nil then
            pcall(function()
                local warm = (laser.warm or 0) > 0 -- its first frames: drawn tiny at the muzzle (shaders made now)
                if warm then
                    laser.warm = laser.warm - 1
                    local p = copy(eday_muzzle_pos(weapon) or ucall(weapon, "GetSocketLocation", fname("b_muzzle")))
                    for _, c in ipairs({ laser.segs[1], laser.dot }) do
                        ucall(c, "K2_SetWorldLocation", Vector3d.new(p.x, p.y, p.z), false, {}, true)
                        ucall(c, "SetWorldScale3D", Vector3d.new(0.0005, 0.0005, 0.0005))
                    end
                end
                for i, c in ipairs(laser.segs) do c:SetVisibility(warm and i == 1, false) end
                laser.dot:SetVisibility(warm, false)
                if laser.light then laser.light:SetVisibility(false, false) end
            end)
        end
        -- made ahead (hidden) on a weapon that has a laser: creating it on the first switch stalled the game ~0.5 s
        if laser == nil and kind ~= nil and eday_muzzle_name(weapon) ~= nil then laser_create(weapon) end
        return
    end
    local pawn = api:get_local_pawn(0)
    if laser == nil or laser.pawn ~= pawn then laser_create(weapon) end
    local start = copy(eday_muzzle_pos(weapon) or ucall(weapon, "GetSocketLocation", fname("b_muzzle")))
    local dir = copy(ucall(weapon, "GetForwardVector"))
    local stop = add(start, mul(dir, LASER_RANGE))
    local hit = false
    pcall(function()
        hit = ucall(kismet_system, "LineTraceSingle", pawn, Vector3d.new(start.x, start.y, start.z), Vector3d.new(stop.x, stop.y, stop.z),
            0, true, { weapon:GetOwner(), pawn }, 0, laser_hit, true, laser_no_color, laser_no_color, 0.0)
    end)
    local endp = stop
    if hit then local p = laser_hit.ImpactPoint endp = v(p.X or p.x, p.Y or p.y, p.Z or p.z) end
    local length = len(sub(endp, start))
    -- the basic cylinder is 100 cm tall along its z, centred: stand it along the beam
    local mid_p = mul(add(start, endp), 0.5)
    local up = math.abs(dir.z) < 0.9 and v(0, 0, 1) or v(1, 0, 0)
    local x = norm(lcross(up, dir))
    local y = lcross(dir, x)
    local from = 0
    for i, c in ipairs(laser.segs) do
        local to = math.min(LASER_SEGMENTS[i], length)
        if to > from then
            local r = math.max(LASER_RADIUS, to * LASER_ANGLE)
            place(c, { pos = add(start, mul(dir, (from + to) * 0.5)), x = x, y = y, z = dir })
            ucall(c, "SetWorldScale3D", Vector3d.new(r * 2 / 100, r * 2 / 100, (to - from) / 100))
            c:SetVisibility(true, false)
        else
            c:SetVisibility(false, false)
        end
        from = math.max(from, to)
    end
    place(laser.dot, { pos = endp, x = x, y = y, z = dir })
    local ds = math.max(LASER_DOT, length * LASER_DOT_ANGLE) / 100 -- (its own growth: tied to the thin beam it was too small far away)
    ucall(laser.dot, "SetWorldScale3D", Vector3d.new(ds, ds, ds))
    laser.dot:SetVisibility(hit, false)
    if laser.light then
        local lp = sub(endp, mul(dir, 4)) -- just off the surface, on the beam's side
        ucall(laser.light, "K2_SetWorldLocation", Vector3d.new(lp.x, lp.y, lp.z), false, {}, true)
        laser.light:SetVisibility(hit, false)
    end
    LASER_DEBUG = { start = start, stop = endp, hit = hit, length = length }
end

local gc_synced = {} -- weapon -> its pieces' skinning checked to point at the weapon (after a script reload)
local bolt_show = nil -- { weapon, bone, pulled } while the hand holds the handle
local function chamber_update(ctx, a)
    local wk = wkey(ctx.weapon)
    if not gc_synced[wk] and bolt_show == nil then
        gc_synced[wk] = true
        pcall(function()
            local gc = ctx.weapon:GetOwner():K2_GetComponentsByClass(api:find_uobject("Class /Script/GeometryCollectionEngine.GeometryCollectionComponent"))[1]
            if gc ~= nil then relinked_gcs[gc] = true end -- it may have been relinked before a script reload
            if gc ~= nil and ucall(gc, "GetLinkedSkinningTarget", 0) ~= ctx.weapon then
                ucall(gc, "SetAllLinkedSkinningTarget", ctx.weapon, ucall(ctx.weapon, "GetSkeletalMeshAsset"))
                relinked_gcs[gc] = true
                log("weapon pieces linked back to the weapon")
            end
        end)
    end
    if a == nil or bolt_bone(ctx.weapon) == nil or a.MagazineCapacity <= 2 then return true end
    local key = weapon_key(ctx.weapon)
    if chamber[key] == nil then chamber[key] = a.AmmoInMagazine > 0 end
    local prev = last_rounds[key]
    -- VR SETTINGS > SHOTGUN PUMP: AUTO: the pump gun cycles itself - a shot never empties the chamber, a shell loaded into an
    -- empty gun is chambered at once; the pump's two sounds (open, then close 0.25 s later) are played after a shot
    if BA.auto_pump_pending ~= nil and os.clock() >= BA.auto_pump_pending.t then
        BA.snd_post(BA.auto_pump_pending.weapon, "hclose")
        BA.auto_pump_pending = nil
    end
    if BA.pump_auto(ctx.weapon) then
        if reload.state == "idle" and prev ~= nil and a.AmmoInMagazine < prev and a.AmmoInMagazine > 0 then
            BA.snd_post(ctx.weapon, "hopen")
            BA.auto_pump_pending = { weapon = ctx.weapon, t = os.clock() + 0.25 }
        end
        chamber[key] = a.AmmoInMagazine > 0
        last_rounds[key] = a.AmmoInMagazine
        return chamber[key]
    end
    if reload.state == "idle" and prev ~= nil and prev > 0 and a.AmmoInMagazine <= 0 then
        chamber[key] = false -- fired dry: the last round left the chamber
        log("chamber empty")
    elseif reload.state == "idle" and prev ~= nil and a.AmmoInMagazine < prev and BA.cycle_gun(ctx.weapon) then
        chamber[key] = false -- a pump gun / the Breechshot: every shot leaves the chamber empty until the handle is worked
        log("fired: work the handle for the next round")
    end
    last_rounds[key] = a.AmmoInMagazine
    -- a tube weapon with no pump and no handle (the Gutpuncher) is never cycled: it fires whenever it has a round
    if BA.is_tube(ctx.weapon) and not BA.cycle_gun(ctx.weapon) then chamber[key] = a.AmmoInMagazine > 0 end
    return chamber[key]
end

-- The handle moving with the hand: the weapon is the game's animated mesh, so while the hand pulls it a posable copy
-- of the weapon is shown instead (attached to it, same materials), with the handle bone moved back by the pull.
-- Bone edits on a posable mesh only reach the renderer from its own tick, so they are made before the engine tick.
local poseable_c = api:find_uobject("Class /Script/Engine.PoseableMeshComponent")
local COMPONENT_SPACE = 1 -- EBoneSpaces::ComponentSpace
local bolt_copy = nil -- { comp, weapon, shown }
-- (here: it sets bolt_show / fire_blocked / reads lever, all declared above)
BA.CYC = {} -- weapon key -> { last ammo, need (a shot fired, not worked yet), back (pulled all the way) }
function BA.cycle_update(ctx, a)
    local list = WEAPON_HANDLES and WEAPON_HANDLES[ctx.weapon:GetOwner():get_class():get_fname():to_string()]
    local spec = nil
    for _, h in ipairs(list or {}) do if h.bolt then spec = h.bolt end end
    if spec == nil then return end
    local k = wkey(ctx.weapon)
    local st = BA.CYC[k] or {}
    BA.CYC[k] = st
    local n = a and a.AmmoInMagazine
    if n ~= nil and st.last ~= nil and n < st.last then
        st.need = true
        log("fired: pull the bolt rod back and forward for the next round")
    end
    st.last = n
    local pull = (HELD_HANDLE ~= nil and HELD_HANDLE.bolt ~= nil) and (BOLT_PULL or 0) or 0
    if pull >= spec.travel * 0.8 and not st.back then st.back = true BA.snd_post(ctx.weapon, "hopen") end
    if st.back and pull < spec.travel * 0.25 then
        st.back = false
        BA.snd_post(ctx.weapon, "hclose")
        if st.need then st.need = false log("bolt rod worked: next round in") end
    end
    if st.need then fire_blocked = true end
    if pull > 0.5 and rack == nil and lever == nil then
        bolt_show = { weapon = ctx.weapon, bone = spec.bone, pulled = pull }
    end
end
-- Once its skinning has been pointed elsewhere and back, the game no longer sends a geometry collection's piece
-- positions to the renderer: the weapon would stay frozen where it was. We send them every frame from then on.

local function bolt_copy_for(weapon)
    if bolt_copy ~= nil and bolt_copy.weapon == weapon then return bolt_copy end
    if bolt_copy ~= nil then
        if bolt_copy.gc ~= nil then pcall(function() ucall(bolt_copy.gc, "SetAllLinkedSkinningTarget", bolt_copy.weapon, bolt_copy.asset) end) end
        pcall(function() bolt_copy.weapon:SetVisibility(true, false) end)
        pcall(function() ucall(bolt_copy.shown_comp, "K2_DestroyComponent", bolt_copy.shown_comp) end)
        pcall(function() ucall(bolt_copy.comp, "K2_DestroyComponent", bolt_copy.comp) end)
        bolt_copy = nil
    end
    local asset = nil
    pcall(function() asset = ucall(weapon, "GetSkeletalMeshAsset") end)
    if asset == nil then pcall(function() asset = ucall(weapon, "GetSkinnedAsset") end) end
    if asset == nil then return nil end
    -- on the pawn (it ticks; a component on the weapon actor would not, and its bone edits would never be drawn)
    local c = api:add_component_by_class(api:get_local_pawn(0), poseable_c)
    if c == nil then return nil end
    local ok = pcall(function() ucall(c, "SetSkinnedAssetAndUpdate", asset, true) end)
    if not ok then ucall(c, "SetSkeletalMesh", asset, true) end
    for i = 0, ucall(weapon, "GetNumMaterials") - 1 do ucall(c, "SetMaterial", i, ucall(weapon, "GetMaterial", i)) end
    ucall(c, "K2_AttachToComponent", weapon, fname("None"), 2, 2, 2, false) -- snapped onto the weapon
    pcall(function() ucall(c, "SetCollisionEnabled", 0) end)
    pcall(function() ucall(c, "SetComponentTickEnabled", true) end)
    ucall(c, "SetHiddenInGame", true, false)
    -- what is drawn: a plain skeletal mesh following the posable copy's bones (as arms.lua does for the body: the
    -- posable mesh's own drawing does not show the bone edits)
    local skel_c = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
    local fo = api:add_component_by_class(api:get_local_pawn(0), skel_c)
    if fo == nil then return nil end
    local ok2 = pcall(function() ucall(fo, "SetSkinnedAssetAndUpdate", asset, true) end)
    if not ok2 then ucall(fo, "SetSkeletalMesh", asset, true) end
    for i = 0, ucall(weapon, "GetNumMaterials") - 1 do ucall(fo, "SetMaterial", i, ucall(weapon, "GetMaterial", i)) end
    ucall(fo, "K2_AttachToComponent", c, fname("None"), 2, 2, 2, false)
    pcall(function() ucall(fo, "SetCollisionEnabled", 0) end)
    ucall(fo, "SetLeaderPoseComponent", c, true)
    fo:SetVisibility(false, false)
    -- weapons drawn as a geometry collection (the Lancer: pieces skinned to the invisible skeletal mesh) are moved
    -- by pointing that skinning at the copy; others show the copy in place of the weapon
    local gc = nil
    pcall(function() gc = weapon:GetOwner():K2_GetComponentsByClass(api:find_uobject("Class /Script/GeometryCollectionEngine.GeometryCollectionComponent"))[1] end)
    bolt_copy = { comp = c, shown_comp = fo, weapon = weapon, shown = false, gc = gc, asset = asset }
    return bolt_copy
end

uevr.sdk.callbacks.on_pre_engine_tick(function()
    GC_FRAME = GC_FRAME + 1
    for gc in pairs(relinked_gcs) do
        if not GC_TRANSFER(gc, true) then relinked_gcs[gc] = nil end
    end
    local ok, err = pcall(function()
        if api:get_local_pawn(0) == nil then return end -- (level change: nothing of ours is touched while the world goes)
        local s = bolt_show
        local trig = RIGHT_TRIGGER or 0
        if CINEMATIC then s = nil end -- cutscene: the game's weapon as it is (no copy shown in its place)
        -- paused (the menu, from which Quit to main menu comes): the weapon's pieces are skinned back to the weapon, the
        -- copy hidden - they stayed skinned to our copy while the world was torn down (null dereferences in the renderer
        -- and a stuck menu load)
        if TRIGGER_WEAPON ~= nil and not ucall(kismet_system, "IsValid", TRIGGER_WEAPON) then TRIGGER_WEAPON = nil end
        if s == nil and trig > 0.05 and not CINEMATIC and not RIGHT_FREE and TRIGGER_WEAPON ~= nil and trigger_bone(TRIGGER_WEAPON) ~= nil then
            s = { weapon = TRIGGER_WEAPON, bone = nil, pulled = 0 }
        end
        -- a pump gun is always drawn by the copy, its loop kept at rest: the game's firing animation works the pump by
        -- itself, here only the hand does
        if s == nil and not CINEMATIC and not RIGHT_FREE and TRIGGER_WEAPON ~= nil and (BA.cycle_gun(TRIGGER_WEAPON) or BA.bolt_gun(TRIGGER_WEAPON)) then
            s = { weapon = TRIGGER_WEAPON, bone = nil, pulled = 0 }
        end
        if EDAY_IN_GAMEPLAY == false then s = nil end -- (paused: see above)
        if s ~= nil then
            local bc = bolt_copy_for(s.weapon)
            if bc == nil then return end
            -- (its parts deleted by something else: an error below resets it - see the end of this callback)
            if not ucall(kismet_system, "IsValid", bc.shown_comp) or not ucall(kismet_system, "IsValid", bc.comp) then error("bolt copy parts gone") end
            ucall(bc.comp, "CopyPoseFromSkeletalComponent", s.weapon)
            if BA.cycle_gun(s.weapon) or BA.bolt_gun(s.weapon) then
                -- the action at rest (the game's firing animation works it by itself); the bolt slides back only
                -- with the hand's pull on the pump (the Breechshot's handle: with the hand's pull, bone = b_handle)
                for _, b in ipairs(BA.has_pump(s.weapon) and BA.PUMP_REST or (BA.bolt_gun(s.weapon) and { "b_bolthandle" } or BA.HANDLE_REST)) do
                    if has_bone(s.weapon, b) then ucall(bc.comp, "ResetBoneTransformByName", fname(b)) end
                end
                if (s.pump_bolt or 0) > 0 and has_bone(s.weapon, "b_bolt") then
                    local q = copy(ucall(bc.comp, "GetBoneLocationByName", fname("b_bolt"), COMPONENT_SPACE))
                    ucall(bc.comp, "SetBoneLocationByName", fname("b_bolt"), Vector3d.new(q.x - s.pump_bolt, q.y, q.z), COMPONENT_SPACE)
                end
            end
            -- MAG_BONE is hidden on the weapon while its magazine is out: the same on the copy
            local mb = mag_spec(s.weapon).bone
            if not ucall(s.weapon, "IsBoneHiddenByName", fname(mb)) then ucall(bc.comp, "UnHideBoneByName", fname(mb))
            else ucall(bc.comp, "HideBoneByName", fname(mb), 0) end
            if s.bone ~= nil then
                local p = copy(ucall(bc.comp, "GetBoneLocationByName", fname(s.bone), COMPONENT_SPACE))
                ucall(bc.comp, "SetBoneLocationByName", fname(s.bone), Vector3d.new(p.x - s.pulled, p.y, p.z), COMPONENT_SPACE)
                if (s.roll or 0) ~= 0 then
                    local r = copy(ucall(bc.comp, "GetBoneRotationByName", fname(s.bone), COMPONENT_SPACE))
                    ucall(bc.comp, "SetBoneRotationByName", fname(s.bone), Vector3d.new(r.x, r.y, r.z - s.roll), COMPONENT_SPACE)
                end
            end
            if s.lever_open ~= nil then
                -- the chainsaw lever, as the game poses it: standing = the handle turned about the component's z,
                -- pulled = both lever bones back along the component's x
                ucall(bc.comp, "SetBoneRotationByName", fname(LEVER_BONE), Vector3d.new(0, LEVER_UP_DEG * s.lever_open, 0), COMPONENT_SPACE)
                -- only the base slides (the handle sits on it), placed from its rest position: the game's own pull
                -- (3.5 cm while the chainsaw starts) was added on top before and took it out of its slot
                local back = LEVER_TRAVEL * (s.lever_lean or 0) -- with the hand, 1:1
                local q = copy(ucall(bc.comp, "GetBoneLocationByName", fname(LEVER_BASE), COMPONENT_SPACE))
                ucall(bc.comp, "SetBoneLocationByName", fname(LEVER_BASE), Vector3d.new(LEVER_BASE_X - back, q.y, q.z), COMPONENT_SPACE)
            end
            if s.pump_deg ~= nil and s.pump_deg ~= 0 then
                -- the pump loop turns about its pivot (b_lever) and the weapon's right axis, its lower bar forward
                local k = copy(ucall(s.weapon, "GetRightVector"))
                local x, y, z = rotator_axes(ucall(bc.comp, "GetBoneRotationByName", fname(BA.PUMP_BONE), 0))
                local a = math.rad(s.pump_deg)
                local function rot(p) local c, sn = math.cos(a), math.sin(a)
                    local kp = v(k.y * p.z - k.z * p.y, k.z * p.x - k.x * p.z, k.x * p.y - k.y * p.x)
                    return add(add(mul(p, c), mul(kp, sn)), mul(k, dot(k, p) * (1 - c))) end
                local nx, nz = rot(x), rot(z)
                ucall(bc.comp, "SetBoneRotationByName", fname(BA.PUMP_BONE), rot_from_xz(Vector3d.new(nx.x, nx.y, nx.z), Vector3d.new(nz.x, nz.y, nz.z)), 0)
            end
            local tb = trigger_bone(s.weapon)
            if tb ~= nil and trig > 0.02 then
                -- the trigger swings back about the weapon's right axis (its lower end towards the shooter)
                local k = copy(ucall(s.weapon, "GetRightVector"))
                local x, y, z = rotator_axes(ucall(bc.comp, "GetBoneRotationByName", fname(tb), 0))
                local a = math.rad(TRIGGER_PULL_DEG * trig)
                local function rot(p) local c, sn = math.cos(a), math.sin(a)
                    local kp = v(k.y * p.z - k.z * p.y, k.z * p.x - k.x * p.z, k.x * p.y - k.y * p.x)
                    return add(add(mul(p, c), mul(kp, sn)), mul(k, dot(k, p) * (1 - c))) end
                local nx, nz = rot(x), rot(z)
                ucall(bc.comp, "SetBoneRotationByName", fname(tb), rot_from_xz(Vector3d.new(nx.x, nx.y, nx.z), Vector3d.new(nz.x, nz.y, nz.z)), 0)
            end
            if bc.gc ~= nil and bc.shown then GC_TRANSFER(bc.gc, true) end -- pieces follow every frame
            -- (weapon.lua's ladder pass hides every *Component_N, this one too: shown again when the ladder is done)
            if not LADDER and bc.shown_comp.bHiddenInGame then bc.shown_comp:SetHiddenInGame(false, false) end
            if not bc.shown then
                bc.shown_comp:SetVisibility(true, false)
                if bc.gc ~= nil then
                    relinked_gcs[bc.gc] = true
                    ucall(bc.gc, "SetAllLinkedSkinningTarget", bc.shown_comp, bc.asset)
                else
                    s.weapon:SetVisibility(false, false) -- not its children: sights and mods stay
                end
                bc.shown = true
            end
        elseif bolt_copy ~= nil and bolt_copy.shown then
            if bolt_copy.gc ~= nil then pcall(function() ucall(bolt_copy.gc, "SetAllLinkedSkinningTarget", bolt_copy.weapon, bolt_copy.asset) end) end
            bolt_copy.shown_comp:SetVisibility(false, false)
            pcall(function() bolt_copy.weapon:SetVisibility(true, false) end)
            bolt_copy.shown = false
        end
    end)
    if not ok then
        bolt_errors = (bolt_errors or 0) + 1
        if bolt_errors % 200 == 1 then log("bolt copy error #" .. bolt_errors .. ": " .. tostring(err)) end
        bolt_show = nil
        -- (its parts were deleted - e.g. while on a turret: the weapon's pieces stayed skinned to the dead copy and
        -- the gun froze in the air while the hand moved) - pieces back on the weapon, a new copy
        -- is made when one is needed
        if bolt_copy ~= nil then
            if bolt_copy.gc ~= nil then pcall(function() ucall(bolt_copy.gc, "SetAllLinkedSkinningTarget", bolt_copy.weapon, bolt_copy.asset) end) end
            pcall(function() bolt_copy.weapon:SetVisibility(true, false) end)
            bolt_copy = nil
            log("bolt copy lost: weapon pieces linked back, a new copy next time")
        end
    end
end)

-- debug (zz_debug.lua): show the weapon copy with the handle pulled back this far (nil = off)
function gestures_debug_bolt(weapon, pulled)
    bolt_show = pulled and { weapon = weapon, bone = bolt_bone(weapon), pulled = pulled } or nil
end

-- the chambered round flies out of the ejection port (right side of the receiver, at the handle) and falls
local ROUND_MESH = "StaticMesh /Game/Fairlight/Effects/Gameplay/Weapons/_Shared/Firing/Meshes/assault_shell_01a.assault_shell_01a"
local EJECT_PORT = { fwd = 4.0, right = 3.5, up = 1.5 } -- cm from the handle's bone
local function eject_round(ctx)
    pcall(function()
        local mesh = round_spec(ctx.weapon) and mag_mesh_asset(ctx.weapon) or load_asset(ROUND_MESH)
        local bb = bolt_bone(ctx.weapon)
        if mesh == nil or bb == nil then return end
        local f = ctx.weapon_frame
        local p = add(copy(ucall(ctx.weapon, "GetSocketLocation", fname(bb))), add(add(mul(f.x, EJECT_PORT.fwd), mul(f.y, EJECT_PORT.right)), mul(f.z, EJECT_PORT.up)))
        local c = api:add_component_by_class(ctx.pawn, static_mesh_c)
        ucall(c, "K2_DetachFromComponent", 1, 1, 1)
        ucall(c, "SetStaticMesh", mesh)
        place(c, { pos = p, x = f.y, y = mul(f.x, -1), z = f.z })
        local vel = add(add(mul(f.y, 220), mul(f.z, 160)), mul(f.x, -40)) -- out to the right, up, a little back
        drop(c, vel)
    end)
end

TRIGGER_PULL_DEG = 22 -- how far the trigger swings at a full pull
local trigger_bones = {}
function trigger_bone(weapon)
    local wk = wkey(weapon)
    if trigger_bones[wk] == nil then
        trigger_bones[wk] = false
        for _, b in ipairs({ "b_trigger_01", "b_trigger" }) do
            if has_bone(weapon, b) then trigger_bones[wk] = b break end
        end
    end
    return trigger_bones[wk] or nil
end

local function work_handle(ctx)
    local a = ammo(ctx.weapon)
    if a == nil then return end
    if BA.pump_auto(ctx.weapon) then log("pump worked (auto: nothing to do)") return end -- (it cycles itself: no round is ejected)
    local key = weapon_key(ctx.weapon)
    if chamber[key] and a.AmmoInMagazine > 0 then
        -- the chambered round flies out: one round less. Set directly: ServerConsumeResource is applied a frame later and the
        -- ammo counter (HUD) did not follow it until the next shot; SetAmmoPercentOnAllMagazines with a changed value does
        set_mag_rounds(ctx.weapon, a, math.max(0, rounds_left(a) - 1))
        eject_round(ctx)
        log("chambered round ejected")
        a = ammo(ctx.weapon)
    end
    -- ("empty" with rounds left = a two-magazine weapon (LMG) with one magazine out: the other one still feeds it)
    chamber[key] = a ~= nil and a.AmmoInMagazine > 0 and (reload.state == "idle" or reload.state == "empty")
    last_rounds[key] = a and a.AmmoInMagazine
    log("handle pulled: " .. (chamber[key] and "round chambered" or "nothing to chamber"))
end

---------------------------------------------------------------------------------------------------------------
-- Outline (shows which magazine to change / take): a light yellow glowing copy of the magazine, a little bigger and
-- just behind it as seen from the eyes. The magazine hides it, except a thin rim all around its edges.
local OUTLINE_MATERIAL = "Material /Game/Fairlight/Lighting/Materials/ProxyMaterials/LGT_Emissive_Fresnel.LGT_Emissive_Fresnel"
local OUTLINE_COLOR = { R = 1.0, G = 0.85, B = 0.25, A = 1.0 } -- "Emissive.HSV" is plain RGB
local OUTLINE_INTENSITY = 5.0 -- brightness of the rim
local OUTLINE_SCALE = 1.08    -- how much bigger than the magazine: the rim's width
local OUTLINE_BEHIND = 1.5    -- cm behind the magazine (more than its growth in depth, so it never covers it)
local kismet_material = api:find_uobject("Class /Script/Engine.KismetMaterialLibrary"):get_class_default_object()
local outline = nil -- { comp, weapon, shown }

-- frame: the magazine as place() puts it (mesh pivot + axes), or nil to hide the outline
local OUTLINE_ENABLED = false -- off (kept for later: works on free-standing copies)
local function outline_update(ctx, frame)
    if not OUTLINE_ENABLED then frame = nil end
    if outline ~= nil and outline.weapon ~= ctx.weapon then
        pcall(function() ucall(outline.comp, "SetStaticMesh", mag_mesh_asset(ctx.weapon)) end)
        outline.weapon = ctx.weapon
    end
    if outline == nil then
        if frame == nil then return end
        local c = spawn_mag(ctx.pawn, ctx.weapon)
        local mat = api:find_uobject(OUTLINE_MATERIAL)
        if c == nil or mat == nil then return end
        local mid = ucall(kismet_material, "CreateDynamicMaterialInstance", ctx.pawn, mat, fname("None"), 0)
        ucall(mid, "SetVectorParameterValue", fname("Emissive.HSV"), OUTLINE_COLOR)
        ucall(mid, "SetScalarParameterValue", fname("Intensity"), OUTLINE_INTENSITY)
        for i = 0, ucall(c, "GetNumMaterials") - 1 do ucall(c, "SetMaterial", i, mid) end
        pcall(function() ucall(c, "SetCastShadow", false) end)
        outline = { comp = c, weapon = ctx.weapon, shown = true }
    end
    local show = frame ~= nil
    if show ~= outline.shown then
        pcall(function() outline.comp:SetVisibility(show, false) end)
        outline.shown = show
    end
    if not show then return end
    local center_local = v(0, 0, 0)
    pcall(function() center_local = copy(mag_mesh_asset(ctx.weapon):GetBounds().Origin) end)
    local function w(p) return add(add(mul(frame.x, p.x), mul(frame.y, p.y)), mul(frame.z, p.z)) end
    local center = add(frame.pos, w(center_local))
    local back = norm(sub(center, ctx.cam_pos))
    -- scaled about the magazine's middle, then pushed back along the line of sight
    local pos = add(add(frame.pos, w(mul(center_local, 1 - OUTLINE_SCALE))), mul(back, OUTLINE_BEHIND))
    place(outline.comp, { pos = pos, x = frame.x, y = frame.y, z = frame.z })
    ucall(outline.comp, "SetWorldScale3D", Vector3d.new(OUTLINE_SCALE, OUTLINE_SCALE, OUTLINE_SCALE))
end

local function insert_mag(ctx)
    local item = ctx.weapon:GetOwner()
    BA.snd_post(ctx.weapon, "ins")
    local c = mag_split_sync(ctx.weapon, ammo(ctx.weapon))
    if c ~= nil then
        -- one of two magazines: a fresh one adds half the capacity from the spare ammo, the same one its own rounds
        local a = ammo(ctx.weapon)
        local side = MAG_SIDE[wkey(ctx.weapon)] or "L"
        local add_n = reload.rounds or 0
        if reload.fresh then add_n = math.min(math.floor(a.MagazineCapacity / 2), a.SpareAmmo) end
        add_n = math.max(0, math.min(add_n, a.MagazineCapacity - a.AmmoInMagazine))
        local spare = a.SpareAmmo
        set_mag_rounds(ctx.weapon, a, rounds_left(a) + add_n)
        if reload.fresh then
            pcall(function() ucall(weapon_util, "SetAmmoPercentOnAllMagazines", item, false, 0.0, true, (spare - add_n) / math.max(1, a.SpareAmmoCapacity)) end)
            refresh_hud(ctx.weapon)
        end
        c[side] = c[side] + add_n
        MAG_OUT[wkey(ctx.weapon)] = MAG_OUT[wkey(ctx.weapon)] or {}
        MAG_OUT[wkey(ctx.weapon)][side] = nil
    elseif reload.fresh then
        for _, o in ipairs(item.ReplicatedAssemblyObjects or {}) do
            if o:is_a(mag_c) then ucall(o, "ServerDoReload") end -- a full one, from the spare ammo
        end
    else
        local a = ammo(ctx.weapon) -- the same magazine back in, with the rounds it had
        if a ~= nil then set_mag_rounds(ctx.weapon, a, reload.rounds or 0) end
    end
    local a = ammo(ctx.weapon)
    log(string.format("magazine in: %s/%s, spare %s", tostring(a and a.AmmoInMagazine), tostring(a and a.MagazineCapacity), tostring(a and a.SpareAmmo)))
    set_weapon_mag_visible(ctx.weapon, true)
    pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end)
    reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
    -- the other of two magazines still out: the weapon waits for it (a fresh one from the chest can go in)
    if mag_any_out(ctx.weapon) then reload.weapon, reload.state = ctx.weapon, "empty" end
end

local function local_dir(f, d) return v(dot(d, f.x), dot(d, f.y), dot(d, f.z)) end
local function cross3(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function sign(x) return x < 0 and -1 or 1 end

-- the hand's frame in the coordinates of g (g: a frame given in hand coordinates, e.g. the grip)
local function invert(g)
    local function col(c) return v(g.x[c], g.y[c], g.z[c]) end
    return { pos = v(-dot(g.pos, g.x), -dot(g.pos, g.y), -dot(g.pos, g.z)), x = col("x"), y = col("y"), z = col("z") }
end

-- the one grip, in the left hand bone's coordinates, from the magazine's bounding box and how it sits in the weapon
local function hand_grip(ctx, wf)
    local origin, ext = v(0, 0, 0), v(8.5, 3.4, 11.3)
    pcall(function()
        local b = mag_mesh_asset(ctx.weapon):GetBounds()
        origin, ext = copy(b.Origin), copy(b.BoxExtent)
    end)
    local rel = relative(ctx.weapon_frame, wf)           -- magazine axes in weapon coordinates
    local up_local = local_dir(rel, v(0, 0, 1))          -- weapon up (magazine top) in magazine coordinates
    local front_local = local_dir(rel, v(1, 0, 0))       -- weapon front in magazine coordinates
    local e = { x = ext.x, y = ext.y, z = ext.z }
    local order = { "x", "y", "z" }
    table.sort(order, function(a, b) return e[a] > e[b] end)
    local long, wide, thin = order[1], order[2], order[3]

    local dirs = {}                                      -- hand-bone directions of the magazine's local axes
    dirs[long] = v(0, 0, -sign(up_local[long]) * BA.hs()) -- along the knuckle line, top towards the index
    if MAG_HOLD == "book" then
        dirs[wide] = v(0, -sign(front_local[wide]), 0)   -- back edge in the palm, front edge pointing away from it
    else
        dirs[wide] = v(sign(front_local[wide]), 0, 0)    -- width along the fingers, front edge at the fingertips
    end
    if dirs.z == nil then dirs.z = cross3(dirs.x, dirs.y)
    elseif dirs.y == nil then dirs.y = cross3(dirs.z, dirs.x)
    else dirs.x = cross3(dirs.y, dirs.z) end

    -- where its centre goes in the hand
    local center = v(GRIP_BACK_EDGE + e[wide], -(GRIP_PALM + e[thin]), e[long] * 2 * (0.5 - GRIP_HOLD_AT) * BA.hs())
    local box_h = v(e[wide], e[thin], e[long])
    if MAG_HOLD == "palm" then center.x = GRIP_FRONT_EDGE - e[wide] end
    if MAG_HOLD == "book" then
        -- the far side right under the bent fingers (just inside the knuckles), the near side against the thumb
        center = v(GRIP_KNUCKLE - 1.1 - e[thin], -(GRIP_PALM + e[wide]), e[long] * 2 * (0.5 - GRIP_HOLD_AT))
        box_h = v(e[thin], e[wide], e[long])
    end
    -- hold_low (the LMG's tall slab): held by its top part, the rest (the feed end) hangs this many cm lower: the
    -- magazine moves down its own axis, the fingers keep closing on what is left of the old box (the top part)
    local box_c = center
    local low = mag_spec(ctx.weapon).hold_low
    if low then
        local d = dirs[long]
        box_c = sub(center, mul(d, low / 2))
        box_h = v(box_h.x, box_h.y, box_h.z - low / 2)
        center = sub(center, mul(d, low))
    end
    local pivot = sub(center, add(add(mul(dirs.x, origin.x), mul(dirs.y, origin.y)), mul(dirs.z, origin.z)))
    -- arms.lua closes the fingers around it: the box in hand bone coordinates (centre, half sizes)
    HELD_MAG_BOX = { c = box_c, h = box_h }
    log(string.format("magazine %.1f x %.1f x %.1f cm, held at %.1f %.1f %.1f in the hand", ext.x * 2, ext.y * 2, ext.z * 2, center.x, center.y, center.z))
    return { pos = pivot, x = dirs.x, y = dirs.y, z = dirs.z }
end

-- in the hand: attached to the left hand bone of the drawn body, so it moves exactly with the hand
local function attach_to_hand(ctx, wf)
    local hand_comp = arms_left_hand_component and arms_left_hand_component()
    if hand_comp == nil then return false end
    local step = "grip"
    local ok, err = pcall(function()
        local g = hand_grip(ctx, wf)
        reload.grip = g
        step = "attach (mag=" .. tostring(reload.mag) .. ")"
        ucall(reload.mag, "K2_AttachToComponent", hand_comp, fname("b_hand_" .. BA.sup()), 1, 1, 1, false)
        step = "rotation"
        local rot = rot_from_xz(Vector3d.new(g.x.x, g.x.y, g.x.z), Vector3d.new(g.z.x, g.z.y, g.z.z))
        step = "relative transform"
        ucall(reload.mag, "K2_SetRelativeLocationAndRotation", Vector3d.new(g.pos.x, g.pos.y, g.pos.z), rot, false, {}, true)
    end)
    if not ok then
        attach_errors = (attach_errors or 0) + 1
        if attach_errors <= 3 then log("attach failed at " .. step .. ": " .. tostring(err)) end
        return false
    end
    reload.attached = true
    return true
end

local function detach_from_hand()
    if reload.attached and reload.mag ~= nil then
        pcall(function() ucall(reload.mag, "K2_DetachFromComponent", 1, 1, 1) end)
    end
    reload.attached = false
    HELD_MAG_BOX = nil
    LEFT_PINCH_CURL = nil
end

local function hand_velocity()
    local n = #hand_history
    if n < 2 then return v(0, 0, 0) end
    local a, b = hand_history[1], hand_history[n]
    local dt = math.max(b.t - a.t, 1e-3)
    return mul(sub(b.pos, a.pos), 1 / dt)
end

---------------------------------------------------------------------------------------------------------------
-- called by weapon.lua
-- ctx: pawn, weapon (mesh component), weapon_frame (world), left_pos (world), left_frame (world, left controller),
--      left_head / right_head ({fwd,right,up} from the headset)

-- How close the hand is to the charging handle's knob (or the bolt-action ball), as a share of its grab radius
-- (< 1: a press would take it) - the same measure as the bolt grab below. Another part's grab (the chainsaw lever)
-- yields to it when the knob is the closer of the two (reaching for the Lancer's charging handle
-- from the left took the folded chainsaw lever, whose end lies ~6 cm from the knob).
function BA.bolt_share(ctx, fingers)
    local bb = bolt_bone(ctx.weapon)
    if bb == nil or (BA.is_tube(ctx.weapon) and bb ~= "b_handle") then return math.huge end
    local bolt = copy(ucall(ctx.weapon, "GetSocketLocation", fname(bb)))
    local wfr = ctx.weapon_frame
    local point, radius
    if is_ba(ctx.weapon) then
        point, radius = ba_ball(bolt, wfr, ba_state(ctx.weapon)), BA.GRAB_RADIUS
    else
        local side = dot(sub(fingers, bolt), wfr.y) >= 0 and 1 or -1
        if bb == "b_handle" then side = 1 end
        point = BA.knob_point(ctx.weapon, bolt, wfr, side, bb)
        radius = BA.bolt_radius(bb)
    end
    local d = math.min(len(sub(fingers, point)) * (is_ba(ctx.weapon) and BOLT_GRAB_RADIUS or radius) / BOLT_FINGER_RADIUS, len(sub(ctx.left_pos, point)))
    return d / radius
end
-- returns true when the press was used here (so it is not a foregrip grab)
function gestures_left_pressed(ctx)
    if ctx.weapon.GetBoneIndex == nil then return false end -- (empty hands: no skinned mesh, nothing to grab)
    if reload.weapon ~= nil and reload.weapon ~= ctx.weapon then reset_reload() end
    if reload.state == "idle" and rack == nil and laser_try_switch(ctx) then return true end
    local wf, out = well(ctx.weapon, ctx.weapon_frame)
    local bb = bolt_bone(ctx.weapon)
    do -- where the hand is on the weapon (to place the charging handle grab)
        local f = ctx.weapon_frame
        local d = sub(ctx.left_pos, f.pos)
        log(string.format("left press at weapon fwd %.1f right %.1f up %.1f (state %s, %.1f cm from the magazine)",
            dot(d, f.x), dot(d, f.y), dot(d, f.z), tostring(reload.state), len(sub(ctx.left_pos, wf.pos))))
        log(string.format("  hand (%.0f %.0f %.0f) well (%.0f %.0f %.0f) weapon (%.0f %.0f %.0f)", ctx.left_pos.x, ctx.left_pos.y, ctx.left_pos.z,
            wf.pos.x, wf.pos.y, wf.pos.z, f.pos.x, f.pos.y, f.pos.z))
    end
    if has_bone(ctx.weapon, LEVER_BONE) and (reload.state == "idle" or reload.state == "empty") then
        local hp = copy(ucall(ctx.weapon, "GetSocketLocation", fname(LEVER_BONE)))
        local hand_comp = arms_left_hand_component and arms_left_hand_component()
        local fingers = ctx.left_pos
        if hand_comp ~= nil then
            pcall(function()
                fingers = mul(add(copy(ucall(hand_comp, "GetSocketLocation", fname("b_index_02_" .. BA.sup()))), copy(ucall(hand_comp, "GetSocketLocation", fname("b_middle_02_" .. BA.sup())))), 0.5)
            end)
        end
        -- distance to the handle itself (pivot to its end, as it stands now), not only to its pivot
        local wfr0 = ctx.weapon_frame
        local la = BA.lever_axis(LEVER_POS[wkey(ctx.weapon)] or 0)
        local he = add(hp, mul(add(add(mul(wfr0.x, la.x), mul(wfr0.y, la.y)), mul(wfr0.z, la.z)), BA.LEVER_LEN))
        local function seg_d(p)
            local s = sub(he, hp)
            local t = math.max(0, math.min(1, dot(sub(p, hp), s) / dot(s, s)))
            return len(sub(p, add(hp, mul(s, t))))
        end
        local d = math.min(seg_d(fingers), seg_d(ctx.left_pos))
        -- the closer of the lever and the charging handle's knob is taken (each by its own grab radius)
        -- ... and only when it is nearer than the foregrip (weapon.lua FOREGRIP): reaching for the front, a press 3.6 cm
        -- from the foregrip took the lever 5.6 cm away (after a fight: the saw started instead)
        local F = BA.FOREGRIP
        local fg = add(wfr0.pos, add(add(mul(wfr0.x, F.x), mul(wfr0.y, F.y)), mul(wfr0.z, F.z)))
        local nearer_than_front = d < len(sub(ctx.left_pos, fg))
        if d < LEVER_GRAB_RADIUS and nearer_than_front and hand_comp ~= nil and BA.bolt_share(ctx, fingers) > d / LEVER_GRAB_RADIUS then
            local wfr = ctx.weapon_frame
            -- always the same hold on the standing handle (BA.lever_hold); the pivot at its rest place (the game's
            -- own pull, while the chainsaw starts, moves the weapon mesh's lever bones back)
            local gd = sub(hp, wfr.pos)
            local pivot_wl = v(LEVER_BASE_X, dot(gd, wfr.y), dot(gd, wfr.z))
            lever = { start = ctx.left_pos, pulled = 0, hand_rel = relative(wfr, BA.lever_hold(wfr, pivot_wl, hand_comp)),
                      weapon_frame = wfr, grip_wl = pivot_wl }
            LEVER_UP[wkey(ctx.weapon)] = true -- taken: it stands up
            log(string.format("chainsaw lever taken (%.1f cm)", d))
            return true
        end
    end
    if BA.has_pump(ctx.weapon) and (reload.state == "idle" or reload.state == "empty") then
        local wfr = ctx.weapon_frame
        local hand_comp = arms_left_hand_component and arms_left_hand_component()
        local fingers = ctx.left_pos
        if hand_comp ~= nil then
            pcall(function()
                fingers = mul(add(copy(ucall(hand_comp, "GetSocketLocation", fname("b_index_02_" .. BA.sup()))), copy(ucall(hand_comp, "GetSocketLocation", fname("b_middle_02_" .. BA.sup())))), 0.5)
            end)
        end
        local P = BA.PUMP_AT
        local point = add(wfr.pos, add(add(mul(wfr.x, P.x), mul(wfr.y, P.y)), mul(wfr.z, P.z)))
        local d = math.min(len(sub(fingers, point)), len(sub(ctx.left_pos, point)))
        local F1 = BA.FOREGRIP -- (the foregrip wins when the hand is nearer to it)
        local d_fg = len(sub(ctx.left_pos, add(wfr.pos, add(add(mul(wfr.x, F1.x), mul(wfr.y, F1.y)), mul(wfr.z, F1.z)))))
        if hand_comp ~= nil and d < BA.PUMP_RADIUS and d < d_fg then
            -- the hand under the weapon, palm up, its fingers across to the right through the loop and round its
            -- lower bar (hand bone axes: x along the fingers, y back of the hand, z towards the little finger)
            local hs = BA.hs()
            local hx, hy = mul(wfr.y, hs), mul(wfr.z, -1)
            local hz = cross3(hx, hy)
            local knuckles = add(add(point, mul(wfr.y, -1.5 * hs)), mul(wfr.z, -1.5))
            local hand = { pos = add(sub(knuckles, mul(hx, RACK_HOLD.knuckles)), mul(hz, RACK_HOLD.knuckle_mid * hs)), x = hx, y = hy, z = hz }
            -- the closed fist round the wrapped tube, turned about it by the controller (handles.lua)
            if handles_left_frame ~= nil and ctx.left_frame ~= nil then
                local ok, f = pcall(handles_left_frame, wfr, { p = P, a = BA.PUMP_AXIS, half = 0 }, ctx.left_frame)
                if ok and f ~= nil then hand = f end
            end
            local ctrl_rel = ctx.left_frame and relative(wfr, ctx.left_frame)
            rack = { start = ctx.left_pos, done = false, hand_rel = relative(wfr, hand), pulled = 0, knob = P, corr = v(0, 0, 0),
                     side = 1, frames = 100000, pump = true, travel = BA.PUMP_TRAVEL, ctrl_rel = ctrl_rel, pump_frames = 0 }
            log(string.format("pump lever taken (%.1f cm)", d))
            return true
        end
    end
    if bb ~= nil and (reload.state == "idle" or reload.state == "empty") and (not BA.is_tube(ctx.weapon) or bb == "b_handle") then
        local bolt = copy(ucall(ctx.weapon, "GetSocketLocation", fname(bb)))
        local wfr = ctx.weapon_frame
        local hand_comp = arms_left_hand_component and arms_left_hand_component()
        -- where the fingers are (the hand as drawn): touching the knob with them is enough
        local fingers = ctx.left_pos
        if hand_comp ~= nil then
            pcall(function()
                fingers = mul(add(copy(ucall(hand_comp, "GetSocketLocation", fname("b_index_02_" .. BA.sup()))), copy(ucall(hand_comp, "GetSocketLocation", fname("b_middle_02_" .. BA.sup())))), 0.5)
            end)
        end
        local side = dot(sub(fingers, bolt), wfr.y) >= 0 and 1 or -1
        if bb == "b_handle" then side = 1 end -- (its knob is only on the right)
        local ba = is_ba(ctx.weapon)
        local point = BA.knob_point(ctx.weapon, bolt, wfr, side, bb)
        if bb == "b_handle" then point = BA.rod_world(wfr) end -- (the rod at rest: the game slides the bone on a shot)
        if ba then
            -- the ball, wherever the bolt has it now
            side = 1
            point = ba_ball(bolt, wfr, ba_state(ctx.weapon))
        end
        local Rb = BA.bolt_radius(bb)
        local F0 = BA.FOREGRIP
        local d_fg = len(sub(ctx.left_pos, add(wfr.pos, add(add(mul(wfr.x, F0.x), mul(wfr.y, F0.y)), mul(wfr.z, F0.z)))))
        local d_bolt = math.min(len(sub(fingers, point)) * (ba and BOLT_GRAB_RADIUS or Rb) / BOLT_FINGER_RADIUS, len(sub(ctx.left_pos, point)))
        if hand_comp ~= nil and ((ba and d_bolt < BA.GRAB_RADIUS) or (not ba and d_bolt < Rb and d_bolt < len(sub(ctx.left_pos, wf.pos)) and d_bolt < d_fg)) then
            -- one set hold, the same every time (hand bone axes: x along the fingers, y back of the hand, z towards
            -- the little finger; knuckles ~10 cm along x, their middle ~1.5 cm towards the index):
            --  left side: palm down above and behind the knob, fingers forward, index and middle hooking over its front
            --  right side: the hand reaches over the receiver, palm down, fingers out to the right over the knob
            local X, Y, Z = wfr.x, wfr.y, wfr.z
            local hx, hy, knuckles
            local hs = BA.hs() -- (right hand: the left hand's hold for the other side, mirrored)
            if side * hs < 0 then
                -- from the left side: palm towards the weapon, fingers forward past the knob's outer end, index on top;
                -- index and middle curl in around its front
                hx, hy = X, mul(Y, -hs) -- back of the hand outwards, palm (-y) to the weapon
                knuckles = add(add(point, mul(X, -RACK_HOLD.behind)), mul(Y, -RACK_HOLD.outside * hs))
            else
                hx, hy = mul(Y, hs), Z
                knuckles = add(add(point, mul(Y, -RACK_HOLD.inward * hs)), mul(Z, RACK_HOLD.above))
            end
            local hz = cross3(hx, hy)
            local hand = { pos = add(sub(knuckles, mul(hx, RACK_HOLD.knuckles)), mul(hz, RACK_HOLD.knuckle_mid * hs)), x = hx, y = hy, z = hz }
            local okc, cn = pcall(function() return ctx.weapon:GetOwner():get_class():get_fname():to_string() end)
            local back = okc and BA.HOLD_BACK[cn] or 0
            hand.pos = sub(hand.pos, mul(X, back))
            if bb == "b_slide" and not ba then
                -- the pistol's slide pinched at its rear (reference photo): the hand behind it pointing forward, back of the hand up-left, thumb straight forward down its left, the index hooked on its right, the rest a fist
                hx, hy = X, norm(sub(Z, mul(Y, 0.6 * hs)))
                hz = cross3(hx, hy)
                local mid = add(bolt, add(mul(X, BA.SLIDE_AT.x), mul(Z, BA.SLIDE_AT.z)))
                hand = { pos = add(add(mid, mul(hx, -8.0)), mul(hy, 3.0)), x = hx, y = hy, z = hz }
            end
            if bb == "b_handle" then
                -- the Breechshot's rod (right side, along the weapon's y): the hand comes over it from behind, palm
                -- down, wrist straight, fingers forward; index and middle hook over its front (curl against BA.ROD_HALF)
                local H = BA.HANDLE_HOLD
                local t, pt = math.rad(H.tilt), math.rad(H.pitch)
                hx = add(mul(X, math.cos(pt)), mul(Z, -math.sin(pt)))
                hy = norm(add(mul(add(mul(Z, math.cos(pt)), mul(X, math.sin(pt))), math.cos(t)), mul(Y, math.sin(t))))
                hz = cross3(hx, hy)
                local kn = add(add(point, mul(X, -H.behind)), add(mul(Z, H.above), mul(Y, H.out)))
                hand = { pos = add(sub(kn, mul(hx, RACK_HOLD.knuckles)), mul(hz, RACK_HOLD.knuckle_mid * hs)), x = hx, y = hy, z = hz }
            end
            if ba then
                -- the bolt's ball, pinched: the hand to its right, palm to the weapon, fingers down round it, thumb
                -- behind it (thumb, index and middle close on it, see BA.BALL_FINGERS)
                local tilt = math.rad(BA.HOLD_TILT)
                hx = add(mul(Z, -math.cos(tilt)), mul(Y, math.sin(tilt))) -- fingers: down, turned out to the right
                hy = add(mul(Y, math.cos(tilt)), mul(Z, math.sin(tilt)))  -- back of the hand: right, turned up
                hz = cross3(hx, hy)
                hand = { pos = add(add(point, mul(Y, BA.HOLD.out)), add(mul(Z, BA.HOLD.wrist_up), mul(X, BA.HOLD.fwd))), x = hx, y = hy, z = hz }
            end
            local kd = sub(point, wfr.pos)
            if ba then hand.pos = add(hand.pos, mul(wfr.x, ba_state(ctx.weapon).pulled)) end -- (hand_rel as if forward: the pull shifts it)
            rack = { start = ctx.left_pos, done = false, hand_rel = relative(wfr, hand), pulled = 0,
                     knob = v(dot(kd, wfr.x), dot(kd, wfr.y), dot(kd, wfr.z)), corr = v(0, 0, 0), side = side, back = back,
                     frames = 100000 } -- a set hold: no settling
            if bb == "b_handle" then rack.half, rack.travel = BA.ROD_HALF, BA.HANDLE_TRAVEL end
            if ba then
                local st = ba_state(ctx.weapon)
                rack.ba, rack.t0, rack.p0, rack.pulled, rack.turn_at_grab = st, st.turned, st.pulled, st.pulled, st.turned
            end
            rack.slide = (bb == "b_slide" and not ba) or nil
            log(string.format("charging handle taken (%s side)", side > 0 and "right" or "left"))
            return true
        end
    end
    local split_in = (reload.state == "idle" or reload.state == "empty") and mag_side_near(ctx.weapon, ctx.weapon_frame, ctx.left_pos, false) or nil
    if split_in ~= nil then MAG_SIDE[wkey(ctx.weapon)] = split_in wf = well(ctx.weapon, ctx.weapon_frame) end
    if (reload.state == "idle" or split_in ~= nil) and len(sub(ctx.left_pos, wf.pos)) < MAG_GRAB_RADIUS and has_bone(ctx.weapon, mag_spec(ctx.weapon).bone) and not is_ba(ctx.weapon) then
        local a = ammo(ctx.weapon)
        if a == nil then return false end -- (a magazine can always be taken out, even with no spare ammo)
        reload.weapon, reload.fresh = ctx.weapon, false
        reload.mag = spawn_mag(ctx.pawn, ctx.weapon)
        reload.grab_start = ctx.left_pos
        -- the hand takes the magazine right where it is, in the grip (fingers closed around it)
        reload.mag_frame = { pos = wf.pos, x = wf.x, y = wf.y, z = wf.z }
        reload.grip = hand_grip(ctx, wf)
        place(reload.mag, reload.mag_frame)
        reload.state = "sliding_out"
        weapon_mag_out(ctx.weapon)
        if mag_spec(ctx.weapon).free then -- in the free hand at once, no lock (mag_frame nil = no lock)
            reload.mag_frame = nil
            attach_to_hand(ctx, wf)
        end
        log("magazine grabbed")
        return true
    end
    if (reload.state == "idle" or reload.state == "empty") and in_zone(ctx.left_head, CHEST) and BA.at_pouch(ctx) then
        local a = ammo(ctx.weapon)
        if a == nil or a.SpareAmmo <= 0 then log("no spare ammo") return true end
        -- prev_state: "idle" = the weapon still has its magazine (this one can only go back or be thrown)
        reload.prev_state = (reload.state == "idle" and mag_any_out(ctx.weapon)) and "empty" or reload.state
        reload.weapon, reload.fresh = ctx.weapon, true
        reload.mag = spawn_mag(ctx.pawn, ctx.weapon)
        reload.attached = false
        reload.state = "holding"
        -- the hand stays as the controller holds it and the magazine comes into it (all weapons). Locked onto the
        -- pouch for 0.15 s before, the hand kept that offset for the whole hold: up to 24 cm off the controller,
        -- turning about another centre and jumping with every controller wobble (measured)
        reload.mag_frame = pouch_frame(ctx)
        reload.grip = hand_grip(ctx, (well(ctx.weapon, ctx.weapon_frame)))
        reload.lock_until = nil
        if is_ba(ctx.weapon) or BA.is_tube(ctx.weapon) then
            -- a round / shell: the hand stays as the controller holds it (locked onto the pouch, it kept that turn after),
            -- the round comes to its fingertips
            reload.grip, reload.lock_until = BA.ROUND_GRIP, nil
            HELD_MAG_BOX = BA.ROUND_BOX
        end
        log((is_ba(ctx.weapon) or BA.is_tube(ctx.weapon)) and "round taken" or "fresh magazine taken")
        return true
    end
    return false
end

function gestures_left_released(ctx)
    if lever ~= nil then
        lever, bolt_show, HELD_MAG_BOX = nil, nil, nil -- (the chainsaw keeps running until pulled again)
        log("chainsaw lever let go")
        return true
    end
    if rack ~= nil then
        local st = rack.ba
        if st ~= nil then
            -- let go: forward, it drops into its notch (locked) or stays up; it stays as far back as it is
            if st.pulled <= 0.5 then
                st.pulled = 0
                st.turned = st.turned < 0.5 and 0 or 1
            end
            log(string.format("bolt let go: %s", ba_closed(st) and "locked" or (st.pulled >= BA.OPEN and "open" or "unlocked")))
        end
        if rack.ba == nil and rack.done then BA.snd_post(ctx.weapon, "hclose") end -- (let go at full pull: it snaps home)
        rack, bolt_show, HELD_MAG_BOX = nil, nil, nil
        return true
    end
    if reload.state == "sliding_out" then
        -- let go before it came out: it slides back in
        pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end)
        set_weapon_mag_visible(ctx.weapon, true)
        local mo = MAG_OUT[wkey(ctx.weapon)]
        if mo ~= nil then mo[MAG_SIDE[wkey(ctx.weapon)] or "L"] = nil end -- (a split weapon's magazine is back in: not "out")
        reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
        return true
    -- (putting a round / magazine back mostly dropped it - it had to be in the chest zone AND within
    -- 8 cm of the hidden pouch spot; now either is enough)
    elseif reload.fresh and reload.state == "holding" and (in_zone(ctx.left_head, CHEST) or BA.at_pouch(ctx, BA.POUCH_PUT_BACK)) then
        -- let go at the chest: back into the pouch, nothing lost
        detach_from_hand()
        pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end)
        log("fresh magazine put back")
        if reload.prev_state == "empty" then
            reload.mag, reload.state, reload.fresh = nil, "empty", false
        else
            reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
        end
        return true
    elseif reload.state == "holding" or reload.state == "sliding_in" then
        detach_from_hand()
        drop(reload.mag, hand_velocity())
        if reload.fresh then
            -- a fresh magazine thrown away: one magazine of spare ammo is gone
            pcall(function()
                local a = ammo(ctx.weapon)
                local left = math.max(0, a.SpareAmmo - (BA.is_tube(ctx.weapon) and 1 or (mag_spec(ctx.weapon).split and math.floor(a.MagazineCapacity / 2) or a.MagazineCapacity))) -- (a shell: one round)
                ucall(weapon_util, "SetAmmoPercentOnAllMagazines", ctx.weapon:GetOwner(), false, 0.0, true, left / math.max(1, a.SpareAmmoCapacity))
                refresh_hud(ctx.weapon)
            end)
        end
        log((reload.fresh and "fresh" or "old") .. " magazine dropped")
        if reload.fresh and reload.prev_state == "idle" then
            reload = { state = "idle", weapon = nil, mag = nil, fresh = false } -- the weapon still has its own
        else
            reload.mag, reload.state, reload.fresh = nil, "empty", false
        end
        return true
    end
    return false
end

function gestures_right_pressed(ctx)
    if in_zone(ctx.right_head, HIP) then
        switch_to_pistol(ctx.pawn, ctx.weapon:GetOwner())
        return true
    elseif in_zone(ctx.right_head, OVER_LEFT_SHOULDER) then
        switch_to_back_weapon(ctx.pawn, ctx.weapon:GetOwner())
        return true
    end
    return false
end

local gestures_update_inner
function gestures_update(ctx)
    -- BP_Wpn_EmptyHands_C (mission starts): its "mesh" is a SphereComponent, not a skinned mesh -> no weapon for gestures
    if ctx.weapon.GetBoneIndex == nil then return end
    local ok, err = pcall(gestures_update_inner, ctx)
    if not ok then
        update_errors = (update_errors or 0) + 1
        if update_errors % 200 == 1 then log("update error #" .. update_errors .. " (state " .. tostring(reload.state) .. ", mag " .. tostring(reload.mag) .. "): " .. tostring(err)) end
    end
end
-- A on the right controller drops the weapon's magazine (weapon.lua sets this; the game's dodge is masked)
gestures_eject_request = false
local function eject_mag(ctx)
    local a = ammo(ctx.weapon)
    -- also while a fresh magazine from the chest is in the hand and the weapon still has its own
    local holding_fresh = reload.fresh and reload.state == "holding" and reload.prev_state == "idle"
    local split = mag_spec(ctx.weapon).split ~= nil
    local split_ok = split and (reload.state == "empty" or holding_fresh or reload.state == "idle")
    if (reload.state ~= "idle" and not holding_fresh and not split_ok) or a == nil or a.MagazineCapacity <= 2 then return end
    local c = mag_split_sync(ctx.weapon, a)
    if c ~= nil then
        local out = MAG_OUT[wkey(ctx.weapon)] or {}
        local side = nil
        for _, s2 in ipairs({ "L", "R" }) do if not out[s2] and (side == nil or c[s2] < c[side]) then side = s2 end end
        if side == nil then return end -- both already out
        MAG_SIDE[wkey(ctx.weapon)] = side
    end
    if not has_bone(ctx.weapon, mag_spec(ctx.weapon).bone) then return end
    local wf, out = well(ctx.weapon, ctx.weapon_frame)
    local m = spawn_mag(ctx.pawn, ctx.weapon)
    if m == nil then return end
    place(m, { pos = wf.pos, x = wf.x, y = wf.y, z = wf.z })
    weapon_mag_out(ctx.weapon)
    BA.snd_post(ctx.weapon, "out")
    if c ~= nil then
        local side = MAG_SIDE[wkey(ctx.weapon)]
        set_mag_rounds(ctx.weapon, a, math.max(0, rounds_left(a) - c[side]))
        c[side] = 0
    else
        set_mag_rounds(ctx.weapon, a, 0) -- the rounds in it fall with it (a chambered one stays)
    end
    drop(m, mul(out, 150))
    if holding_fresh then
        reload.prev_state = "empty" -- the one in the hand can go in now
    else
        reload.weapon, reload.mag, reload.fresh, reload.state = ctx.weapon, nil, false, "empty"
    end
    log("magazine dropped (A)")
end

gestures_update_inner = function(ctx)
    LAST_GESTURE_WF = ctx.weapon_frame
    if reload.weapon ~= nil and reload.weapon ~= ctx.weapon then BA.park_reload() end -- (a reload of the OTHER weapon must not block this one)
    if next(BA.PARKED) ~= nil then BA.unpark_reload(ctx, ammo(ctx.weapon)) end
    TRIGGER_WEAPON = ctx.weapon
    if gestures_eject_request then
        gestures_eject_request = false
        eject_mag(ctx)
    end
    table.insert(hand_history, { pos = ctx.left_pos, t = clock })
    while #hand_history > 6 do table.remove(hand_history, 1) end

    -- dropped magazines disappear after a while
    for i = #dropped, 1, -1 do
        if clock - dropped[i].t > DROPPED_LIFETIME then
            pcall(function() dropped[i].comp:K2_DestroyComponent(dropped[i].comp) end)
            table.remove(dropped, i)
        end
    end

    -- idle = its magazine is in the weapon: keep it shown (a script reload can leave it hidden)
    if reload.state == "idle" and has_bone(ctx.weapon, mag_spec(ctx.weapon).bone) and ucall(ctx.weapon, "IsBoneHiddenByName", fname(mag_spec(ctx.weapon).bone)) then
        set_weapon_mag_visible(ctx.weapon, true)
    end
    local a = ammo(ctx.weapon)
    -- the weapons only held: reloaded from their spare ammo when empty (the reload button is masked)
    if a ~= nil and a.AmmoInMagazine <= 0 and a.SpareAmmo > 0 and BA.hold_only(ctx.weapon) and clock > (BA.auto_reload_at or 0) then
        BA.auto_reload_at = clock + 1.0
        for _, o in ipairs(ctx.weapon:GetOwner().ReplicatedAssemblyObjects or {}) do
            if o:is_a(mag_c) then pcall(function() ucall(o, "ServerDoReload") end) end
        end
        log("reloaded (a weapon only held)")
        a = ammo(ctx.weapon)
    end
    if reload.state == "idle" then mag_split_sync(ctx.weapon, a) end -- (shots: from the fuller magazine)
    local dry = a ~= nil and a.MagazineCapacity > 2 and rounds_left(a) <= 0
    local chambered = chamber_update(ctx, a)
    fire_blocked = (a ~= nil and reserve(a) > 0 and (dry or reload.state ~= "idle")) or not chambered or rack ~= nil
        or (is_ba(ctx.weapon) and not ba_closed(ba_state(ctx.weapon)))
    if not has_bone(ctx.weapon, LEVER_BONE) then
        if CHAINSAW_HOLD then log("chainsaw: stopped (weapon changed)") end
        CHAINSAW_HOLD = false
    end
    -- up only while held or while the saw runs (after a chainsaw fight the front grab kept taking
    -- the lever - it had been left standing (touched and let go without a pull, or the saw stopped another way), and
    -- standing it sticks out back-left right where the hand passes on its way to the front)
    if lever == nil and not CHAINSAW_HOLD and LEVER_UP[wkey(ctx.weapon)] then LEVER_UP[wkey(ctx.weapon)] = false end
    -- how far it stands (0 folded .. 1 up), eased towards where it should be
    local want_up = LEVER_UP[wkey(ctx.weapon)] and 1 or 0
    local lp = LEVER_POS[wkey(ctx.weapon)] or 0
    local now = os.clock()
    local step = math.min(now - (lever_clock or now), 0.1) / LEVER_RISE_TIME
    lever_clock = now
    lp = lp < want_up and math.min(want_up, lp + step) or math.max(want_up, lp - step)
    LEVER_POS[wkey(ctx.weapon)] = lp
    local lean = 0
    if lever ~= nil then
        local wfr = ctx.weapon_frame
        lever.weapon_frame = wfr
        local d = sub(ctx.left_pos, lever.start)
        lever.pulled = math.max(0, math.min(LEVER_TRAVEL, dot(d, mul(wfr.x, -1))))
        lean = lever.pulled / LEVER_TRAVEL
        if lever.pulled >= LEVER_TRAVEL - 0.5 and not lever.toggled then
            lever.toggled = true
            CHAINSAW_HOLD = not CHAINSAW_HOLD
            log(CHAINSAW_HOLD and "chainsaw: started (lever pulled)" or "chainsaw: stopped (lever pulled)")
            if not CHAINSAW_HOLD then LEVER_UP[wkey(ctx.weapon)] = false end -- stopped: it folds back down
        elseif lever.pulled < LEVER_TRAVEL * 0.3 then
            lever.toggled = false -- back up: it can be pulled again
        end
        -- the fingers close round the handle: a box along it (its own axes, weapon coords), where the hand holds it
        local g = lever.grip_wl
        local back = lever.pulled -- the lever goes back with the hand, 1:1 (the hand is not held back)
        local la = BA.lever_axis(lp)
        HELD_MAG_BOX = { wl = add(v(g.x - back, g.y, g.z), mul(la, BA.LEVER_GRIP_AT)), h = v(6.0, BA.LEVER_RADIUS, BA.LEVER_RADIUS),
                         wax = { x = la, y = v(-la.y, la.x, 0), z = v(0, 0, 1) } }
        lever.shift = v(-back, 0, 0)
    end
    if lp > 0 or lever ~= nil then
        bolt_show = { weapon = ctx.weapon, bone = nil, pulled = 0, lever_open = lp, lever_lean = lean }
    elseif rack == nil then
        bolt_show = nil
        if is_ba(ctx.weapon) then
            local st = ba_state(ctx.weapon)
            if not ba_closed(st) then bolt_show = { weapon = ctx.weapon, bone = bolt_bone(ctx.weapon), pulled = st.pulled, roll = BA.TURN_DEG * st.turned } end
        end
    end
    -- a weapon loaded by its own handle after every shot (handles.lua 'bolt', Heavy Boomshot): a shot
    -- blocks firing until the handle went back (weapon.lua BOLT_PULL, the left hand brought towards the right one) and
    -- forward again; the handle is drawn where the hand has it
    BA.cycle_update(ctx, a)
    if rack ~= nil and rack.ba ~= nil then
        -- bolt action: up/down turns it (only while it is forward), back/forward slides it (only while turned up)
        local st, wfr = rack.ba, ctx.weapon_frame
        rack.weapon_frame = wfr
        -- each phase from where it began (the hand's jitter does not add up): turning (up/down) while it is
        -- forward, sliding (back/forward) once turned up; back at the front, the hand going down turns it again
        local rel = sub(ctx.left_pos, wfr.pos) -- the hand on the weapon (moving the weapon moves nothing)
        local up, back = dot(rel, wfr.z), dot(rel, mul(wfr.x, -1))
        if rack.mode == nil then
            rack.mode = (st.turned >= 0.95) and "slide" or "turn"
            rack.t0, rack.z0, rack.p0, rack.x0 = st.turned, up, st.pulled, back
        end
        if rack.mode == "turn" then
            st.turned = math.max(0, math.min(1, rack.t0 + (up - rack.z0) / BA.LIFT))
            if st.turned >= 1 then rack.mode, rack.p0, rack.x0 = "slide", st.pulled, back end
        else
            st.pulled = math.max(0, math.min(BA.TRAVEL, rack.p0 + back - rack.x0))
            if st.pulled > 0.3 then rack.front_z = nil
            else
                rack.front_z = rack.front_z or up
                if up < rack.front_z - 0.6 then rack.mode, rack.t0, rack.z0 = "turn", 1, rack.front_z end
            end
        end
        rack.pulled = st.pulled
        if st.pulled >= BA.OPEN and not st.ejected then
            -- open: whatever is in the chamber flies out (a live round is lost, as when a bolt is worked)
            st.ejected = true
            BA.snd_post(ctx.weapon, "hopen")
            local a = ammo(ctx.weapon)
            if a ~= nil and a.AmmoInMagazine > 0 then
                for _, o in ipairs(ctx.weapon:GetOwner().ReplicatedAssemblyObjects or {}) do
                    if o:is_a(mag_c) then pcall(function() ucall(o, "ServerConsumeResource", 1) end) end
                end
            end
            eject_round(ctx)
            log("bolt open: chamber emptied")
        elseif st.pulled < 2 then
            if st.ejected then BA.snd_post(ctx.weapon, "hclose") end
            st.ejected = false -- (pushed forward again: the next opening empties it again)
        end
        bolt_show = { weapon = ctx.weapon, bone = bolt_bone(ctx.weapon), pulled = st.pulled, roll = BA.TURN_DEG * st.turned }
        local ball = ba_ball(copy(ucall(ctx.weapon, "GetSocketLocation", fname(bolt_bone(ctx.weapon)))), wfr, st)
        local bw = sub(ball, wfr.pos)
        HELD_MAG_BOX = { wl = v(dot(bw, wfr.x), dot(bw, wfr.y), dot(bw, wfr.z)), h = BA.BALL_HALF, fixed = BA.BALL_FINGERS }
        local ok_t, _, _, pinch = pcall(gestures_ba_tips) -- (between the thumb's and the index' tips)
        if ok_t and pinch ~= nil then
            local e = sub(ball, pinch)
            local c = add(rack.corr or v(0, 0, 0), mul(v(dot(e, wfr.x), dot(e, wfr.y), dot(e, wfr.z)), BA.SETTLE))
            if len(c) > 20 then c = mul(c, 20 / len(c)) end
            rack.corr = c
        end
    elseif rack ~= nil then
        rack.weapon_frame = ctx.weapon_frame
        local pdir = rack.pump and -1 or 1 -- (the pump is pulled forward, a charging handle back)
        rack.pulled = math.max(0, math.min(rack.travel or BOLT_TRAVEL, dot(sub(ctx.left_pos, rack.start), mul(ctx.weapon_frame.x, -pdir))))
        if rack.pump then
            bolt_show = { weapon = ctx.weapon, bone = nil, pulled = 0, pump_deg = -math.deg(rack.pulled / BA.PUMP_ARM),
                          pump_bolt = BA.PUMP_BOLT * rack.pulled / BA.PUMP_TRAVEL }
        else
            bolt_show = { weapon = ctx.weapon, bone = bolt_bone(ctx.weapon), pulled = rack.pulled }
        end
        if rack.slide then
            local wfr = ctx.weapon_frame
            local b0 = copy(ucall(ctx.weapon, "GetSocketLocation", fname(bolt_bone(ctx.weapon))))
            local mid = add(b0, add(mul(wfr.x, BA.SLIDE_AT.x - rack.pulled), mul(wfr.z, BA.SLIDE_AT.z)))
            local ok_t, _, _, pinch = pcall(gestures_ba_tips)
            if ok_t and pinch ~= nil then
                local e = sub(mid, pinch)
                local c = add(rack.corr or v(0, 0, 0), mul(v(dot(e, wfr.x), dot(e, wfr.y), dot(e, wfr.z)), BA.SETTLE))
                if len(c) > 20 then c = mul(c, 20 / len(c)) end
                rack.corr = c
            end
        end
        -- the fingers as drawn last frame (they close around the knob): the hand slides until their middle is on it
        local hc = arms_left_hand_component and arms_left_hand_component()
        rack.frames = (rack.frames or 0) + 1
        if hc ~= nil and rack.knob ~= nil then
            local wfr = ctx.weapon_frame
            local function world(p) return add(wfr.pos, add(add(mul(wfr.x, p.x), mul(wfr.y, p.y)), mul(wfr.z, p.z))) end
            local knob = sub(world(rack.knob), mul(wfr.x, pdir * rack.pulled))
            -- in weapon coordinates (arms.lua places it on the weapon as drawn), and the other fingers' pose
            local kc = sub(sub(sub(knob, mul(wfr.x, rack.back or 0)), mul(wfr.y, rack.half and 0 or rack.side * (KNOB_BOX_HALF.y - BOLT_KNOB))), wfr.pos)
            HELD_MAG_BOX = { wl = v(dot(kc, wfr.x), dot(kc, wfr.y), dot(kc, wfr.z)), h = rack.half or KNOB_BOX_HALF, fixed = RACK_FINGERS }
            if rack.pump then
                -- the wrapped tube: a plain fist round it (arms.lua FIST_CURL); while it closes the hold is worked out
                -- again from the drawn fist (handles.lua puts its hole on the tube)
                HELD_MAG_BOX = { fist = true }
                rack.pump_frames = rack.pump_frames + 1
                if rack.ctrl_rel ~= nil and rack.pump_frames <= 30 and handles_left_frame ~= nil then
                    local ok, f = pcall(handles_left_frame, wfr, { p = rack.knob, a = BA.PUMP_AXIS, half = 0 }, compose(wfr, rack.ctrl_rel))
                    if ok and f ~= nil then rack.hand_rel = relative(wfr, f) end
                end
            end
        end
        if not rack.done and rack.pulled >= (rack.travel or BOLT_TRAVEL) * BA.done_frac(rack) then
            rack.done = true
            BA.tick()
            BA.snd_post(ctx.weapon, "hopen")
            work_handle(ctx)
        elseif rack.done and rack.pulled < (rack.travel or BOLT_TRAVEL) * 0.3 then
            rack.done = false -- pushed forward again: can be worked again
            BA.snd_post(ctx.weapon, "hclose")
        end
    end
    local spare_left = a ~= nil and a.SpareAmmo > 0 and (has_bone(ctx.weapon, mag_spec(ctx.weapon).bone) or BA.is_tube(ctx.weapon))
    local in_hand = reload.fresh and (reload.state == "holding" or reload.state == "sliding_in")
    pouch_update(ctx, spare_left and not in_hand and ctx.cam_fwd ~= nil)
    local wf0, out0 = well(ctx.weapon, ctx.weapon_frame)
    glint_update(ctx, false)
    if dry and reload.state == "idle" then
        outline_update(ctx, { pos = wf0.pos, x = wf0.x, y = wf0.y, z = wf0.z }) -- the weapon's empty magazine
    elseif reload.state == "empty" and spare_left and pouch ~= nil then
        outline_update(ctx, pouch_frame(ctx)) -- the weapon has none: the one on the chest
    else
        outline_update(ctx, nil)
    end

    if reload.weapon ~= nil and reload.weapon ~= ctx.weapon then reset_reload() return end
    if GRIP_DEBUG and reload.state == "idle" then
        local m = spawn_mag(ctx.pawn, ctx.weapon)
        reload.weapon, reload.fresh, reload.mag, reload.attached, reload.state = ctx.weapon, true, m, false, "holding"
    end
    -- (arms.lua's set finger pose: the ball's fingertips while the bolt is worked; the round's pinch set again below)
    LEFT_PINCH_CURL = (rack ~= nil and rack.ba ~= nil and BA.BALL_CURL) or (rack ~= nil and rack.slide and BA.SLIDE_CURL) or nil
    if reload.state == "idle" or reload.state == "empty" then return end
    if reload.state == "holding" then
        local near_out = mag_side_near(ctx.weapon, ctx.weapon_frame, ctx.left_pos, true)
        if near_out ~= nil then MAG_SIDE[wkey(ctx.weapon)] = near_out end
    end
    local wf, out = well(ctx.weapon, ctx.weapon_frame)

    if reload.state == "sliding_out" then
        local pulled = sub(ctx.left_pos, reload.grab_start)
        local d = math.max(0, dot(pulled, out))
        if len(pulled) >= MAG_SLIDE_OUT then
            -- free: from now on it is in the hand
            reload.state = "holding"
            reload.armed = false -- it must leave the well's reach before it can slide back in
            BA.snd_post(ctx.weapon, "out")
            attach_to_hand(ctx, wf)
            -- the rounds left in it leave with it (back in if this same magazine goes back in)
            local a = ammo(ctx.weapon)
            local c = mag_split_sync(ctx.weapon, a)
            if c ~= nil then
                local side = MAG_SIDE[wkey(ctx.weapon)] or "L"
                reload.rounds = c[side]
                c[side] = 0
                set_mag_rounds(ctx.weapon, a, math.max(0, rounds_left(a) - reload.rounds))
            elseif a ~= nil then
                reload.rounds = math.max(0, rounds_left(a))
                set_mag_rounds(ctx.weapon, a, 0)
            end
            log("magazine out" .. (c and (" (" .. (MAG_SIDE[wkey(ctx.weapon)] or "L") .. ", " .. reload.rounds .. " rounds)") or ""))
        else
            if not mag_spec(ctx.weapon).free then
                reload.mag_frame = { pos = add(wf.pos, mul(out, d)), x = wf.x, y = wf.y, z = wf.z }
                place(reload.mag, reload.mag_frame)
            end
        end
        return
    end

    if reload.state == "holding" and (is_ba(ctx.weapon) or BA.is_tube(ctx.weapon)) then
        local tube = BA.is_tube(ctx.weapon)
        HELD_MAG_BOX = BA.ROUND_BOX
        LEFT_PINCH_CURL = (round_spec(ctx.weapon) or {}).pinch or BA.PINCH
        local ok_t, tt, it, mid, dir = pcall(gestures_ba_tips)
        if ok_t and mid ~= nil then
            local up = norm(sub(tt, it))
            local ax = norm(cross3(up, dir))
            local sc = tube and BA.TUBE_SCALE or BA.ROUND_SCALE
            local spec = round_spec(ctx.weapon)
            if spec then
                -- its length (x) across the fingertips like the casing's, its middle between them
                sc = spec.scale
                place(reload.mag, { pos = add(mid, mul(ax, ((spec.shift or 0) - spec.center) * sc)), x = ax, y = mul(dir, -1), z = up })
            else
                place(reload.mag, { pos = sub(mid, mul(ax, BA.ROUND_HALF * sc)), x = dir, y = ax, z = up })
            end
            pcall(function() ucall(reload.mag, "SetWorldScale3D", Vector3d.new(sc, sc, sc)) end)
        end
        local f = ctx.weapon_frame
        local round_at = copy(ucall(reload.mag, "K2_GetComponentLocation"))
        local a = ammo(ctx.weapon)
        if tube then
            -- the shell into the loading port: one more round, one less spare
            local tp = BA.tube_port(ctx.weapon)
            local pp = (round_spec(ctx.weapon) or tp or {}).port or tp or BA.TUBE_PORT
            local port = add(f.pos, add(add(mul(f.x, pp.x), mul(f.y, pp.y)), mul(f.z, pp.z)))
            if reload.fresh and a ~= nil and a.AmmoInMagazine < a.MagazineCapacity and a.SpareAmmo > 0 and len(sub(round_at, port)) < (tp and tp.r or BA.TUBE_RADIUS) then
                set_mag_rounds(ctx.weapon, a, rounds_left(a) + 1)
                pcall(function() ucall(weapon_util, "SetAmmoPercentOnAllMagazines", ctx.weapon:GetOwner(), false, 0.0, true, (a.SpareAmmo - 1) / math.max(1, a.SpareAmmoCapacity)) end)
                detach_from_hand()
                pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end)
                reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
                LEFT_PINCH_CURL = nil
                local b = ammo(ctx.weapon)
                BA.snd_post(ctx.weapon, "rnd")
                log(string.format("shell in: %s/%s, spare %s", tostring(b and b.AmmoInMagazine), tostring(b and b.MagazineCapacity), tostring(b and b.SpareAmmo)))
            end
            return
        end
        local st = ba_state(ctx.weapon)
        local chamber_at = add(f.pos, add(add(mul(f.x, BA.CHAMBER.x - st.pulled * 0), mul(f.y, BA.CHAMBER.y)), mul(f.z, BA.CHAMBER.z)))
        if reload.fresh and st.pulled >= BA.OPEN and a ~= nil and a.AmmoInMagazine <= 0 and len(sub(round_at, chamber_at)) < BA.INSERT_RADIUS then
            for _, o in ipairs(ctx.weapon:GetOwner().ReplicatedAssemblyObjects or {}) do
                if o:is_a(mag_c) then ucall(o, "ServerDoReload") end -- one round, from the spare ammo
            end
            detach_from_hand()
            pcall(function() ucall(reload.mag, "K2_DestroyComponent", reload.mag) end)
            reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
            LEFT_PINCH_CURL = nil
            local b = ammo(ctx.weapon)
            BA.snd_post(ctx.weapon, "rnd")
            log(string.format("round in: %s/%s, spare %s", tostring(b and b.AmmoInMagazine), tostring(b and b.MagazineCapacity), tostring(b and b.SpareAmmo)))
        end
        return
    end

    if reload.state == "holding" then
        if not reload.attached then attach_to_hand(ctx, wf) end
        -- close to the well: it lines up and slides along it
        local weapon_loaded = reload.fresh and reload.prev_state == "idle"
        local mag_pos = copy(ucall(reload.mag, "K2_GetComponentLocation"))
        local to_well = len(sub(mag_pos, wf.pos))
        if to_well > MAG_ALIGN_RADIUS + 3 then reload.armed = true end
        if not GRIP_DEBUG and not weapon_loaded and reload.armed ~= false and to_well < MAG_ALIGN_RADIUS then
            -- from here the magazine follows the hand along the well, kept as far from the hand as it is now
            -- (measuring the hand itself sent it back to "holding" at once when the hand sits far from the well)
            reload.slide_off = dot(sub(ctx.left_pos, mag_pos), out)
            if mag_spec(ctx.weapon).free then -- no slide: in as soon as it is at the well
                if to_well < BA.FREE_IN then detach_from_hand() return insert_mag(ctx) end
                return
            end
            detach_from_hand()
            reload.mag_frame = nil
            reload.state = "sliding_in"
        end
        return
    end

    if reload.state == "sliding_in" then
        local d = dot(sub(ctx.left_pos, wf.pos), out) - (reload.slide_off or 0)
        if d > MAG_ALIGN_RADIUS then reload.state = "holding" return end -- pulled away again (re-attached above)
        if d <= 0.5 then return insert_mag(ctx) end
        reload.mag_frame = { pos = add(wf.pos, mul(out, d)), x = wf.x, y = wf.y, z = wf.z }
            place(reload.mag, reload.mag_frame)
    end
end

---------------------------------------------------------------------------------------------------------------
-- Objective: a tall golden beam of light standing at the objective, out in the world (the game's icon is a HUD
-- element, which in VR hung right in front of the eyes). The places come from the game's objective locators.
local OBJECTIVE_CLASS = "WidgetBlueprintGeneratedClass /Game/Fairlight/Interface/HUD/Locators/ChampionsLocatorInstances/BP_Locator_CampaignObjective.BP_Locator_CampaignObjective_C"
local OBJECTIVE_COLOR = { R = 1.0, G = 0.62, B = 0.1, A = 1.0 }
local OBJECTIVE_GLOW = 20.0
local OBJECTIVE_HEIGHT = 600     -- cm, the beam goes this far up from the objective
local OBJECTIVE_ANGLE = 0.0025   -- its half width per cm of distance (about the same width on screen at any range)
local OBJECTIVE_NEAR = 250       -- cm: closer than this it is not shown (you are there)
local objective = { beams = {}, widgets = {}, looked = -10, mat = nil, tick = 0 }
local widget_lib_g = api:find_uobject("Class /Script/UMG.WidgetBlueprintLibrary"):get_class_default_object()

local function target_location(t)
    if t == nil then return nil end
    local ok, p = pcall(function() return copy(t:K2_GetComponentLocation()) end)
    if ok then return p end
    ok, p = pcall(function() return copy(t:K2_GetActorLocation()) end)
    if ok then return p end
    ok, p = pcall(function() return copy(t:get_outer():K2_GetActorLocation()) end)
    return ok and p or nil
end

OBJECTIVE_BEAM = false -- the golden column at the objective: off (the game's own objective marker is shown again)
function objective_update(pawn)
    if not OBJECTIVE_BEAM then
        for _, b in ipairs(objective.beams or {}) do pcall(function() b:SetVisibility(false, false) end) end
        return
    end
    objective.tick = objective.tick + 1
    if objective.tick % 3 ~= 0 then return end
    if objective.pawn ~= pawn then objective = { beams = {}, widgets = {}, looked = -10, tick = 0, pawn = pawn } end
    if clock - objective.looked > 2 then -- which objectives there are: looked at again every 2 s
        objective.looked = clock
        local cls = api:find_uobject(OBJECTIVE_CLASS)
        local found = {}
        if cls ~= nil then pcall(function() ucall(widget_lib_g, "GetAllWidgetsOfClass", pawn, found, cls, false) end) end
        objective.widgets = found
    end
    local places = {}
    for _, w in ipairs(objective.widgets) do
        local okt, t = pcall(function() return w.LocatorTarget end)
        local p = okt and target_location(t) or nil
        if p ~= nil then table.insert(places, p) end
    end
    local eye = fp_eye_position and fp_eye_position(pawn) or copy(ucall(pawn, "K2_GetActorLocation"))
    for i = 1, math.max(#places, #objective.beams) do
        local p = places[i]
        local b = objective.beams[i]
        if p ~= nil then
            if b == nil then
                if objective.mat == nil then
                    local mid = ucall(laser_material_lib, "CreateDynamicMaterialInstance", pawn, api:find_uobject(LASER_MATERIAL), fname("None"), 0)
                    ucall(mid, "SetVectorParameterValue", fname("Light Color"), OBJECTIVE_COLOR)
                    ucall(mid, "SetScalarParameterValue", fname("Glow Brightness"), OBJECTIVE_GLOW)
                    ucall(mid, "SetScalarParameterValue", fname("Fresnel Power"), 0)
                    objective.mat = mid
                end
                b = laser_part(pawn, "StaticMesh /Engine/BasicShapes/Cylinder.Cylinder", objective.mat)
                objective.beams[i] = b
            end
            local d = len(sub(p, eye))
            local show = d > OBJECTIVE_NEAR
            if show then
                local r = math.max(4, d * OBJECTIVE_ANGLE)
                place(b, { pos = add(p, v(0, 0, OBJECTIVE_HEIGHT * 0.5)), x = v(1, 0, 0), y = v(0, 1, 0), z = v(0, 0, 1) })
                ucall(b, "SetWorldScale3D", Vector3d.new(r * 2 / 100, r * 2 / 100, OBJECTIVE_HEIGHT / 100))
            end
            b:SetVisibility(show, false)
        elseif b ~= nil then
            b:SetVisibility(false, false)
        end
    end
    OBJECTIVE_DEBUG = places
end

-- cutscene (weapon.lua): the pouch, the laser and a magazine in the hand are not left hanging in the air
function gestures_cinematic()
    if pouch ~= nil then pcall(function() pouch.comp:SetVisibility(false, false) end) pouch.shown = false end
    if laser ~= nil then
        pcall(function()
            for _, c in ipairs(laser.segs) do c:SetVisibility(false, false) end
            laser.dot:SetVisibility(false, false)
            if laser.light then laser.light:SetVisibility(false, false) end
        end)
    end
    if reload.state ~= "idle" and reload.state ~= "empty" then reset_reload() end
    rack, bolt_show, lever, CHAINSAW_HOLD = nil, nil, nil, false
    for _, b in ipairs(objective.beams) do pcall(function() b:SetVisibility(false, false) end) end
end

-- new pawn: its magazines (components of the old pawn) are already gone, just forget them
function gestures_forget(pawn_gone)
    glint, fire_blocked = nil, false -- the light went with the old pawn
    -- no pawn at all (quit to the main menu, level change): the world is being torn down and everything in it with it -
    -- calling into the weapon / its copy / the pouch there was an access violation inside the engine (UEVR's handler
    -- caught it; the menu then stayed black, Quit to main menu with the Gnasher's copy alive)
    if pawn_gone then
        pouch, purged = nil, false
        rack, bolt_show, bolt_copy, outline = nil, nil, nil, nil
        TRIGGER_WEAPON = nil
        relinked_gcs, gc_of, laser = {}, {}, nil
        reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
        dropped = {}
        hand_history = {}
        return
    end
    -- the pouch magazine stays on Marcus when only a stand takes over (it floated at the chest, drawn, per mount): gone
    -- with the pawn, and the leftovers of earlier loads / mounts are purged again on his next pouch_update
    if pouch ~= nil then pcall(function() if ucall(kismet_system, "IsValid", pouch.comp) then ucall(pouch.comp, "K2_DestroyComponent", pouch.comp) end end) end
    pouch, purged = nil, false
    -- the drawn copy of the pump gun is a component of the pawn it was made on - Marcus survives a stand (the turret is
    -- the pawn meanwhile): forgotten without being destroyed, one more copy stayed on him per mount
    if bolt_copy ~= nil then
        if bolt_copy.gc ~= nil then pcall(function() ucall(bolt_copy.gc, "SetAllLinkedSkinningTarget", bolt_copy.weapon, bolt_copy.asset) end) end
        pcall(function() bolt_copy.weapon:SetVisibility(true, false) end)
        pcall(function() ucall(bolt_copy.shown_comp, "K2_DestroyComponent", bolt_copy.shown_comp) end)
        pcall(function() ucall(bolt_copy.comp, "K2_DestroyComponent", bolt_copy.comp) end)
    end
    rack, bolt_show, bolt_copy, outline = nil, nil, nil, nil
    TRIGGER_WEAPON = nil
    relinked_gcs, gc_of, laser = {}, {}, nil
    reload = { state = "idle", weapon = nil, mag = nil, fresh = false }
    dropped = {}
    hand_history = {}
end

-- switching hands live (aa_xr.lua eday_on_hand): a magazine / handle / lever held by the other hand is let go
eday_on_hand(function()
    if reload.state ~= "idle" and reload.state ~= "empty" then reset_reload() end
    rack, bolt_show, lever, CHAINSAW_HOLD = nil, nil, nil, false
end)

-- while the magazine slides along the well the hand is locked onto it, in the grip (arms.lua puts it there)
function gestures_left_hand_lock()
    local lock, wf = gestures_left_hand_lock_world()
    return lock, wf or LAST_GESTURE_WF
end
function gestures_left_hand_lock_world()
    if lever ~= nil and lever.weapon_frame ~= nil then
        local wf = lever.weapon_frame
        local h = compose(wf, lever.hand_rel)
        local s = lever.shift or v(0, 0, 0)
        return { pos = add(h.pos, add(add(mul(wf.x, s.x), mul(wf.y, s.y)), mul(wf.z, s.z))), x = h.x, y = h.y, z = h.z }, wf
    end
    if rack ~= nil and rack.hand_rel ~= nil and rack.weapon_frame ~= nil then
        local wf = rack.weapon_frame
        local h = compose(wf, rack.hand_rel)
        local c = rack.corr or v(0, 0, 0)
        local shift = add(add(mul(wf.x, c.x - (rack.pump and -rack.pulled or rack.pulled)), mul(wf.y, c.y)), mul(wf.z, c.z))
        return { pos = add(h.pos, shift), x = h.x, y = h.y, z = h.z }, wf
    end
    local in_pouch = reload.state == "holding" and reload.lock_until ~= nil and clock < reload.lock_until
    if (reload.state == "sliding_out" or reload.state == "sliding_in" or in_pouch) and reload.mag_frame ~= nil and reload.grip ~= nil then
        return compose(reload.mag_frame, invert(reload.grip))
    end
    return nil
end

-- the left hand is holding a magazine (fingers closed around it)
function gestures_hand_full()
    return lever ~= nil or rack ~= nil or reload.state == "sliding_out" or reload.state == "holding" or reload.state == "sliding_in"
end

-- what aa_assets.lua loads at every mission start: the magazines of the weapons Marcus carries, rounds, laser
if eday_prefetch_add ~= nil then
    eday_prefetch_add(function(pawn)
        local list = { GENERIC_MAG, ROUND_MESH, LASER_MATERIAL }
        for _, m in ipairs(MAG_MESHES) do table.insert(list, m.mesh) end
        local seen = {}
        local function add_snd(e) -- (the reload sounds: BA.SND)
            if e ~= nil and not seen[e] then seen[e] = true local n = e:match("[^/]+$") table.insert(list, BA.SND_DIR .. e:match("^[^/]+") .. "/" .. n .. "." .. n) end
        end
        for _, k in ipairs(BA.SND_KINDS) do add_snd(BA.SND_DEF[k]) for _, e in ipairs(BA.SND) do add_snd(e[k]) end end
        for _, a in ipairs(attached_weapons(pawn)) do
            local cname = a:get_class():get_fname():to_string()
            local name = cname:match("^BP_Wpn_(.-)_C$")
            local listed = false
            for _, m in ipairs(MAG_MESHES) do if cname:find(m.class) then listed = true end end
            if name ~= nil and not listed and not name:find("^Equip") then -- (grenades / listed ones: no own magazine)
                name = name:gsub("_Heroic$", "")
                for _, side in ipairs({ "COG", "Locust" }) do
                    table.insert(list, string.format("StaticMesh /Game/Fairlight/Weapons/%s/%s/MagDefault/%s_%s_MagDefault.%s_%s_MagDefault", side, name, side, name, side, name))
                end
            end
        end
        return list
    end)
end

log("loaded")

-- development (tools/dbg.sh): the reload state machine as it is
function gestures_reload_state() return reload end
-- (debug, grab tests) what the left hand holds: "lever", "rack" (charging handle / bolt), a magazine state, or nil
function gestures_left_holds() return (lever and "lever") or (rack and "rack") or (reload.state ~= "idle" and reload.state ~= "empty" and reload.state) or nil end
-- (debug, weapon tests) the handle the left hand works on weapon w: { kind = "pump" | "rack" | "ba", point
-- (world, where the hand takes it), dir (world, the way it is pulled), travel (cm), up (world, the bolt's lift) }
function gestures_handle_hold(t) for k, val in pairs(t or {}) do BA.HANDLE_HOLD[k] = val end return BA.HANDLE_HOLD end -- (debug: next grab)
function gestures_handle_point(w)
    local f = { pos = copy(ucall(w, "K2_GetComponentLocation")), x = copy(ucall(w, "GetForwardVector")),
                y = copy(ucall(w, "GetRightVector")), z = copy(ucall(w, "GetUpVector")) }
    if BA.has_pump(w) then
        local P = BA.PUMP_AT
        return { kind = "pump", point = add(f.pos, add(add(mul(f.x, P.x), mul(f.y, P.y)), mul(f.z, P.z))), dir = f.x, travel = BA.PUMP_TRAVEL + 1 }
    end
    local bb = bolt_bone(w)
    if bb == nil or (BA.is_tube(w) and bb ~= "b_handle") then return nil end
    local bolt = copy(ucall(w, "GetSocketLocation", fname(bb)))
    if is_ba(w) then
        return { kind = "ba", point = ba_ball(bolt, f, ba_state(w)), dir = mul(f.x, -1), travel = BA.OPEN + 1, up = f.z, lift = BA.LIFT + 1 }
    end
    local side = bb == "b_handle" and 1 or -1
    if bb == "b_handle" then return { kind = "rack", bone = bb, point = BA.rod_world(f), dir = mul(f.x, -1), travel = BA.HANDLE_TRAVEL + 1 } end
    return { kind = "rack", bone = bb, point = BA.knob_point(w, bolt, f, side, bb),
             dir = mul(f.x, -1), travel = BOLT_TRAVEL + 1 }
end
