-- Gears of War: E-Day VR - extra handles for the left hand on big weapons (the Vulcan has a bar across
-- its top front and a handle by its sight running front to back - the left hand must be able to take either).
-- WEAPON_HANDLES[class] = list of the weapon's handle bones. weapon.lua: on the left grip, handles_pick() takes the
-- nearest within HANDLE_GRAB_CM; while held the weapon is aimed along the right hand -> that handle, and the left fist
-- sits on it: handles_left_frame() places the hand bone so the hole of the closed fist is on the handle's axis, the
-- fist turned about it as the controller is turned.
local api = uevr.api
local function log(m) pcall(function() uevr.params.functions.log_info("[handles] " .. tostring(m)) end) end

WEAPON_HANDLES = {
    -- (weapon space, cm: x to the muzzle, y right, z up; measured with markers - the handle bones sit at their hinges)
    BP_Wpn_Vulcan_C = {
        { name = "top bar", p = { x = 60.0, y = -2.5, z = 3.0 }, a = { x = 0, y = 1, z = 0 }, half = 9, over = true },      -- across the top front
        { name = "side handle", p = { x = 46.0, y = -17.5, z = -3.5 }, a = { x = 1, y = 0, z = 0 }, half = 0 }, -- (half 0: fixed, no sliding) -- by the sight, front to back
    },
    BP_Wpn_HeavyBoomshot_C = { -- (only these two are taken; the bolt rod also loads - bolt = worked
                               --  by pulling it towards the right hand, see weapon.lua BOLT_PULL / gestures BA.cycle)
        { name = "bolt rod", p = { x = 58.0, y = -2.5, z = 3.6 }, a = { x = 0, y = 1, z = 0 }, half = 8, over = true,
          bolt = { bone = "b_bolthandle", travel = 12 } }, -- (the wrapped bar across the top on two posts, y -12.8..+7.8,
                                                           --  measured from the front with markers; moved by b_bolthandle:
                                                           --  the game slides it 14 cm back per shot)
        { name = "left handle", p = { x = 48.5, y = -14.0, z = -5.0 }, a = { x = 1, y = 0, z = 0 }, half = 0 }, -- (half 0: the hand stays fixed at p, no sliding; the wrapped
                                                           --  handle on the top left edge, front to back: its hinge bone b_handle_LF
                                                           --  is at its front end (61.7,-13.6,-2.9); the wrap is x 40.6..56.3, 2.5 cm
                                                           --  radius; measured from the side with markers)
    },
    BP_Wpn_Troika_C = { -- (the Locust twin gun: the same two handles, bandaged)
        -- (measured with markers from the side and from above: the bar sits on the hinge arms' pivot, x 57.5, z 3.7,
        --  wrap y -8.7..8.7; the side handle's bandage runs x 41..55, axis y -14, z -5: half 0, the hand stays at its middle)
        { name = "top bar", p = { x = 57.5, y = 0.0, z = 3.7 }, a = { x = 0, y = 1, z = 0 }, half = 9, over = true },
        { name = "side handle", p = { x = 48.2, y = -14.0, z = -5.0 }, a = { x = 1, y = 0, z = 0 }, half = 0 },
    },
    BP_Wpn_HeavyCoreItem_C = { -- (two upright knurled grips on the sides of the front, each on a pipe bracket top and bottom: measured
                               --  with markers from the side and from above: x 57, y +-14.5, z 0, running up/down (z -8..8))
        { name = "left grip", p = { x = 57.0, y = -14.5, z = 0.0 }, a = { x = 0, y = 0, z = 1 }, half = 0 },
        { name = "right grip", p = { x = 57.0, y = 14.5, z = 0.0 }, a = { x = 0, y = 0, z = 1 }, half = 0 },
    },
    BP_Wpn_Glaive_Chains_C = { -- (the bandaged bar across the top front, like the Troika's: measured with markers from above,
                               --  x 57, wrap y -14..+9, z ~3.7; half 0: the hand stays at its middle)
        { name = "top bar", p = { x = 57.0, y = -2.5, z = 3.7 }, a = { x = 0, y = 1, z = 0 }, half = 0, over = true },
    },
}
HANDLE_GRAB_CM = HANDLE_GRAB_CM or 14
HANDLE_HALF_LEN = 6 -- cm either side of a handle bone along it

local ks = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
local km = api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a) local l = len(a) return l > 1e-6 and mul(a, 1 / l) or a end
local function copy(u) return v(u.x or u.X, u.y or u.Y, u.z or u.Z) end
local function W(f, p) return add(f.pos, add(add(mul(f.x, p.x), mul(f.y, p.y)), mul(f.z, p.z))) end
local function Wd(f, d) return add(add(mul(f.x, d.x), mul(f.y, d.y)), mul(f.z, d.z)) end

-- the handles in the weapon's own coordinates (its mesh is placed on weapon.lua's weapon frame: mesh local = weapon space)
local cache = {}
local function handles_of(mesh)
    local cls = mesh:GetOwner():get_class():get_fname():to_string()
    local list = WEAPON_HANDLES[cls]
    if list == nil then return nil end
    if cache[cls] then return cache[cls] end
    local o = copy(mesh:K2_GetComponentLocation())
    local F, R, U = copy(mesh:GetForwardVector()), copy(mesh:GetRightVector()), copy(mesh:GetUpVector())
    local function loc(d) return v(dot(d, F), dot(d, R), dot(d, U)) end
    local out = {}
    for _, h in ipairs(list) do
        if h.p ~= nil then
            out[#out + 1] = { name = h.name, p = v(h.p.x, h.p.y, h.p.z), a = norm(v(h.a.x, h.a.y, h.a.z)), half = h.half or HANDLE_HALF_LEN, bolt = h.bolt, over = h.over }
        else
            local n = ks:Conv_StringToName(h.bone)
            local p = sub(copy(mesh:GetSocketLocation(n)), o)
            local a = copy(km:GetForwardVector(mesh:GetSocketRotation(n))) -- (the bone's x runs along the handle)
            out[#out + 1] = { name = h.name, bone = h.bone, p = loc(p), a = norm(loc(a)), half = h.half or HANDLE_HALF_LEN }
        end
    end
    cache[cls] = out
    log(cls .. ": " .. #out .. " handles")
    return out
end

-- weapon frame (world, from the right hand), left hand point: the handle taken, or nil
function handles_pick(mesh, wf, lh)
    local list = handles_of(mesh)
    if list == nil then return nil end
    local best, bd = nil, HANDLE_GRAB_CM
    for _, h in ipairs(list) do
        local c, a = W(wf, h.p), Wd(wf, h.a)
        local t = math.max(-h.half, math.min(h.half, dot(sub(lh, c), a)))
        local d = len(sub(lh, add(c, mul(a, t))))
        if d < bd then best, bd = h, d end
    end
    if best then log(string.format("%s taken (%.1f cm)", best.name, bd)) end
    return best, bd
end

-- the closed left fist relative to its hand bone: the hole (middle of the curled middle finger), its axis (index side),
-- the fingers' direction. Read from the drawn hand while the fist is closed; kept.
local fist_rel = nil
local function read_fist()
    local hc = arms_left_hand_component and arms_left_hand_component()
    if hc == nil then return fist_rel end
    local function b(n) return copy(hc:GetSocketLocation(ks:Conv_StringToName(n))) end
    local S = ARMS_SUPPORT_SIDE or "L" -- (the drawn hand of the support role: the right one when left-handed)
    local r = hc:GetSocketRotation(ks:Conv_StringToName("b_hand_" .. S))
    local X, Y, Z = copy(km:GetForwardVector(r)), copy(km:GetRightVector(r)), copy(km:GetUpVector(r))
    local hp = b("b_hand_" .. S)
    local function loc(d) return v(dot(d, X), dot(d, Y), dot(d, Z)) end
    local hole = mul(add(add(b("b_middle_01_" .. S), b("b_middle_02_" .. S)), b("b_middle_03_" .. S)), 1 / 3)
    local rel = { hole = loc(sub(hole, hp)), ax = norm(loc(sub(b("b_index_02_" .. S), b("b_pinky_02_" .. S)))), fing = norm(loc(sub(b("b_middle_01_" .. S), hp))) }
    if (ARMS_LEFT_FIST or 0) > 0.95 then fist_rel = rel end
    return fist_rel or rel
end

-- the left hand bone's frame (world) holding handle h of the weapon at frame wf; ctrl = the left controller's frame
function handles_left_frame(wf, h, ctrl)
    local rel = read_fist()
    if rel == nil then return nil end
    local A = norm(Wd(wf, h.a))
    if dot(A, ctrl.z) < 0 then A = mul(A, -1) end -- index side up the handle the way the controller's top points
    local f = handles_build(wf, h, ctrl, rel, A)
    -- an overhand hold (h.over: the Heavy Boomshot's bar, taken from above): the back of
    -- the hand (hand y) up
    if h.over and dot(f.y, Wd(wf, v(0, 0, 1))) < 0 then f = handles_build(wf, h, ctrl, rel, mul(A, -1)) end
    return f
end
function handles_build(wf, h, ctrl, rel, A)
    local c = W(wf, h.p)
    -- the fist slides along the handle to where the hand is (within its length)
    local t = math.max(-h.half, math.min(h.half, dot(sub(ctrl.pos, c), A)))
    local P = add(c, mul(A, t))
    -- hand basis: e1 = hole axis, e2 = fingers square to it; world: E1 = handle, E2 = the controller's forward square to it
    local e1 = rel.ax
    local e2 = norm(sub(rel.fing, mul(e1, dot(rel.fing, e1))))
    local e3 = cross(e1, e2)
    local E1 = A
    local E2 = sub(ctrl.x, mul(A, dot(ctrl.x, A)))
    if len(E2) < 1e-3 then E2 = sub(ctrl.z, mul(A, dot(ctrl.z, A))) end
    E2 = norm(E2)
    local E3 = cross(E1, E2)
    local function map(p) return add(add(mul(E1, dot(p, e1)), mul(E2, dot(p, e2))), mul(E3, dot(p, e3))) end
    local hx, hy, hz = map(v(1, 0, 0)), map(v(0, 1, 0)), map(v(0, 0, 1))
    return { pos = sub(P, map(rel.hole)), x = hx, y = hy, z = hz }
end

log("loaded")
