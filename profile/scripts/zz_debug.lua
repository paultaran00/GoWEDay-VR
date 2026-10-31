-- Debug tools (for development, harmless in play):
--  * data/dbg_cmd.lua, when it appears, is run once in the game (helpers below in scope); print() output and the
--    returned values go to data/dbg_out.txt, then dbg_cmd.lua is emptied.
--  * debug camera: cam_at / cam_orbit move the rendered view (both eyes) for a few seconds, then it switches itself
--    off. Gameplay (weapon, aiming) still uses the real head: this script runs after the others.
-- Never call get_objects_matching here: it starts UEVR's UObjectHook, which crashes this game.
-- Development only: set to false (or move this file out of scripts) to switch it off completely.
local DEBUG_TOOLS = true
if not DEBUG_TOOLS then return end

local api = uevr.api
local DIR = "dbg_" -- UEVR io only allows files in GoWEDay-Steam/data (no subfolders): data/dbg_cmd.lua, data/dbg_out.txt
local function log(msg) pcall(function() uevr.params.functions.log_info("[debug] " .. msg) end) end
log(string.format("io %s, os.remove %s, os.rename %s, load %s, fs %s", tostring(io ~= nil), tostring(os ~= nil and os.remove ~= nil),
    tostring(os ~= nil and os.rename ~= nil), tostring(load ~= nil), tostring(fs ~= nil)))
local has_io = io ~= nil and load ~= nil
if not has_io then log("no io/load in this Lua: command file off (debug camera still works)") end

local kismet_string = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
local statics = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local actor_c = api:find_uobject("Class /Script/Engine.Actor")
local actor_comp_c = api:find_uobject("Class /Script/Engine.ActorComponent")
local skeletal_mesh_c = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")

local function fname(s) return kismet_string:Conv_StringToName(s) end
local function v(x, y, z) return { x = x, y = y, z = z } end
local function copy(u) return v(u.x, u.y, u.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function len(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
local function vs(u) return u and string.format("(%.1f, %.1f, %.1f)", u.x, u.y, u.z) or "nil" end

-- value -> readable text (tables to a few levels, UObjects by name)
local function dump(x, depth, seen)
    depth, seen = depth or 0, seen or {}
    local t = type(x)
    if t == "table" then
        if seen[x] or depth > 3 then return "{...}" end
        seen[x] = true
        if x.x ~= nil and x.y ~= nil and x.z ~= nil and type(x.x) == "number" then return vs(x) end
        local parts = {}
        for k, val in pairs(x) do table.insert(parts, tostring(k) .. " = " .. dump(val, depth + 1, seen)) end
        table.sort(parts)
        return "{ " .. table.concat(parts, ", ") .. " }"
    elseif t == "userdata" then
        local ok, n = pcall(function() return x:get_full_name() end)
        if ok and n then return n end
        local ok2, vec = pcall(function() return vs(x) end)
        if ok2 then return vec end
        return tostring(x)
    end
    return tostring(x)
end

---------------------------------------------------------------------------------------------------------------
-- helpers available in cmd.lua
local H = {}
H.api, H.fname, H.v, H.vs, H.dump, H.copy, H.sub, H.add, H.mul, H.len = api, fname, v, vs, dump, copy, sub, add, mul, len
function H.pawn() return api:get_local_pawn(0) end
function H.pc() return api:get_player_controller(0) end
function H.cls(path) return api:find_uobject(path) end -- e.g. "Class /Script/Engine.StaticMeshComponent"
function H.loc(obj) return copy(obj:K2_GetActorLocation()) end
function H.cloc(comp) return copy(comp:K2_GetComponentLocation()) end
function H.bone(comp, name) return copy(comp:GetSocketLocation(fname(name))) end
function H.head() return H.last_head end -- real (headset) eye centre, last frame
function H.H_VIEW() return H.last_view end -- where the eyes look (unit vector), last frame

-- actors of a class (default all) within radius cm of the player, nearest first: { name, class, pos, dist }
function H.actors(radius, class_path)
    local p = H.loc(H.pawn())
    local out = {}
    statics:GetAllActorsOfClass(H.pawn(), class_path and api:find_uobject(class_path) or actor_c, out)
    local res = {}
    for _, a in ipairs(out) do
        local ok, pos = pcall(function() return copy(a:K2_GetActorLocation()) end)
        if ok then
            local d = len(sub(pos, p))
            if d <= (radius or 1500) then
                table.insert(res, { name = a:get_fname():to_string(), class = a:get_class():get_fname():to_string(), pos = pos, dist = d, obj = a })
            end
        end
    end
    table.sort(res, function(a, b) return a.dist < b.dist end)
    return res
end
function H.list_actors(radius, class_path, max)
    for i, a in ipairs(H.actors(radius, class_path)) do
        if i > (max or 60) then break end
        H.print(string.format("%6.0f cm  %-50s %-40s %s", a.dist, a.name, a.class, vs(a.pos)))
    end
end

-- components of an actor: name, class, location
function H.list_components(actor)
    for _, c in ipairs(actor:K2_GetComponentsByClass(actor_comp_c) or {}) do
        local ok, pos = pcall(function() return copy(c:K2_GetComponentLocation()) end)
        H.print(string.format("%-50s %-40s %s", c:get_fname():to_string(), c:get_class():get_fname():to_string(), ok and vs(pos) or ""))
    end
end

-- bones of a skinned component (names, world positions); filter = substring
function H.list_bones(comp, filter)
    local n = comp:GetNumBones()
    for i = 0, n - 1 do
        local name = comp:GetBoneName(i):to_string()
        if filter == nil or name:find(filter) then H.print(string.format("%3d %-30s %s", i, name, vs(H.bone(comp, name)))) end
    end
end

-- head / collar bones of the player (hidden for first person); show them for a third-person look
function H.show_head(on)
    local names = { "b_head", "sc_shoulderpad_L", "sc_shoulderpad_R", "sc_collar_RF", "sc_collar_R", "sc_collar_RB", "sc_collar_LF", "sc_collar_L", "sc_collar_LB" }
    for _, m in ipairs(H.pawn():K2_GetComponentsByClass(skeletal_mesh_c) or {}) do
        for _, b in ipairs(names) do
            pcall(function() if on then m:UnHideBoneByName(fname(b)) else m:HideBoneByName(fname(b), 0) end end)
        end
    end
end

-- debug camera ----------------------------------------------------------------------------------------------
local cam = nil -- { pos = fn() or vec, look = fn() or vec, until_t }
local clock = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) clock = clock + delta end)

-- named targets for the camera: "hand_L", "hand_R", "weapon", "pawn", "head", or a vector, or a function
local function target_pos(t)
    if type(t) == "function" then return t() end
    if type(t) == "table" then return t end
    local pawn = H.pawn()
    if t == "hand_L" or t == "hand_R" then
        local c = arms_left_hand_component and arms_left_hand_component() or pawn.Mesh
        return H.bone(c, t == "hand_L" and "b_hand_L" or "b_hand_R")
    elseif t == "weapon" then
        local inv = pawn:GetComponentByClass(api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent"))
        return H.loc(inv:GetEquippedInventoryItem())
    elseif t == "head" then return H.last_head
    end
    return add(H.loc(pawn), v(0, 0, 40))
end

-- camera at pos looking at look (vectors or targets), for seconds (default 15)
function H.cam_at(pos, look, seconds)
    cam = { pos = pos, look = look, until_t = clock + (seconds or 15) }
end
-- camera orbiting a target: yaw relative to the player's facing (0 = in front of him, looking back at him),
-- pitch up from horizontal, dist cm
function H.cam_orbit(target, yaw, pitch, dist, seconds)
    local function pos()
        local c = target_pos(target)
        local f = copy(H.pawn():GetActorForwardVector())
        local a = math.atan(f.y, f.x) + math.rad(yaw or 0)
        local p = math.rad(pitch or 15)
        local d = dist or 80
        return add(c, v(math.cos(a) * math.cos(p) * d, math.sin(a) * math.cos(p) * d, math.sin(p) * d))
    end
    cam = { pos = pos, look = target, until_t = clock + (seconds or 15) }
end
function H.cam_off() cam = nil end

local eye_pos = {}
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device_ptr, view_index, world_to_meters, position, rotation, is_double)
    eye_pos[view_index] = copy(position)
    if view_index == 1 and eye_pos[0] then
        H.last_head = mul(add(eye_pos[0], eye_pos[1]), 0.5)
        local p, y = math.rad(rotation.x), math.rad(rotation.y)
        H.last_view = v(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)) -- where the eyes look
    end
    if cam == nil then return end
    if clock > cam.until_t then cam = nil log("debug camera off (timeout)") return end
    local ok, err = pcall(function()
        local p = target_pos(cam.pos)
        local l = target_pos(cam.look)
        local d = sub(l, p)
        local yaw = math.deg(math.atan(d.y, d.x))
        local pitch = math.deg(math.atan(d.z, math.sqrt(d.x * d.x + d.y * d.y)))
        local right = v(-math.sin(math.rad(yaw)), math.cos(math.rad(yaw)), 0)
        local e = mul(right, view_index == 0 and -3.2 or 3.2)
        position.x, position.y, position.z = p.x + e.x, p.y + e.y, p.z + e.z
        rotation.x, rotation.y, rotation.z = pitch, yaw, rawget(_G, "CAM_ROLL") or 0
    end)
    if not ok then cam = nil log("debug camera error: " .. tostring(err)) end
end)

-- Headset off (no VR view): the same debug camera through the flat screen - a CameraActor the player controller
-- looks through while cam is set; back to the pawn when it ends. (A scene capture + ExportRenderTarget froze the game.)
local flat_cam, flat_on = nil, false
local function cam_pose()
    local p, l = target_pos(cam.pos), target_pos(cam.look)
    local d = sub(l, p)
    return p, Vector3d.new(math.deg(math.atan(d.z, math.sqrt(d.x * d.x + d.y * d.y))), math.deg(math.atan(d.y, d.x)), 0)
end
uevr.sdk.callbacks.on_post_engine_tick(function()
    local vr_on = uevr.params.vr.is_runtime_ready()
    local pc = api:get_player_controller(0)
    local want = cam ~= nil and not vr_on and pc ~= nil and H.pawn() ~= nil
    if want and clock > cam.until_t then cam = nil want = false log("debug camera off (timeout)") end
    local ok, err = pcall(function()
        if want then
            if flat_cam == nil or flat_cam.pawn ~= H.pawn() then
                local gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
                local tr = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
                local a = gs:BeginDeferredActorSpawnFromClass(H.pawn(), api:find_uobject("Class /Script/Engine.CameraActor"), tr, 1, nil, 0)
                gs:FinishSpawningActor(a, tr, 0)
                flat_cam, flat_on = { actor = a, pawn = H.pawn() }, false
            end
            local p, rot = cam_pose()
            flat_cam.actor:K2_SetActorLocationAndRotation(Vector3d.new(p.x, p.y, p.z), rot, false, {}, true)
            if not flat_on then pc:SetViewTargetWithBlend(flat_cam.actor, 0, 0, 0, false) flat_on = true end
        elseif flat_on then
            flat_on = false
            if pc ~= nil and H.pawn() ~= nil then pc:SetViewTargetWithBlend(H.pawn(), 0, 0, 0, false) end
        end
    end)
    if not ok then cam = nil log("flat debug camera error: " .. tostring(err)) end
end)

-- simulated controllers and gamepad ----------------------------------------------------------------------------
-- hand(side, spec, s): that controller held at spec instead of the real one:
--   spec = { fwd, right, up (cm), yaw, pitch, roll (deg, where the hand points; 0 = straight ahead, level),
--            rel = "head" (default: from the headset, on its flat facing) or "right" (left hand only: from the right
--            hand, along the weapon: fwd = along the barrel, up = weapon up; yaw/pitch/roll then relative to it too) }
-- grip(side, down, s): grip button held / released.   pad(state, s): gamepad, state = { buttons = { "A", "RB", ... },
--   lt, rt (0..1), lx, ly, rx, ry (-1..1) }.   All of it stops by itself after s seconds (default 20); sim_off() now.
local sim = {} -- key -> { value, until_t }; each simulated input stops by itself
local function sim_get(key)
    local e = sim[key]
    if e == nil then return nil end
    if clock > e.until_t then sim[key] = nil log("simulated " .. key .. " off (timeout)") return nil end
    return e.value
end
local function sim_set(key, value, seconds) sim[key] = { value = value, until_t = clock + (seconds or 20) } end
function H.hand(side, spec, seconds) sim_set(side, spec, seconds) end
function H.grip(side, down, seconds) sim_set(side .. "_grip", down, seconds) end
function H.pad(state, seconds) sim_set("pad", state, seconds) end
function H.sim_off() sim = {} end

local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function norm(a) local l = len(a) return l > 1e-6 and mul(a, 1 / l) or a end
local function turn(a, b, deg) -- rotate the pair of axes (a, b) by deg: a towards b
    local c, s = math.cos(math.rad(deg)), math.sin(math.rad(deg))
    return add(mul(a, c), mul(b, s)), sub(mul(b, c), mul(a, s))
end

-- true while a simulated hand is set (weapon.lua: the stand's real hand mapping only runs without one)
function debug_hands_active() return sim_get("left") ~= nil or sim_get("right") ~= nil end

function debug_device(side, hmd, dev, controller_pitch, right_dev)
    local s = sim_get(side)
    if s == nil then return dev end
    local F, R, U, base
    if s.rel == "view" then
        -- relative to where the headset itself points (what the view shows), whatever its tilt
        F, R, U, base = hmd.f, hmd.r, hmd.u, hmd.pos
    elseif s.rel == "right" and right_dev ~= nil then
        -- the right hand's aim axes (the raw controller pitched like weapon.lua does)
        F, U = turn(right_dev.f, right_dev.u, controller_pitch)
        R, base = cross(U, F), right_dev.pos
    else
        F = norm(v(hmd.f.x, hmd.f.y, 0))
        R, U, base = v(-F.y, F.x, 0), v(0, 0, 1), hmd.pos
    end
    local pos = add(base, mul(add(add(mul(F, s.fwd or 0), mul(R, s.right or 0)), mul(U, s.up or 0)), 0.01))
    F, R = turn(F, R, s.yaw or 0)
    F, U = turn(F, U, s.pitch or 0)
    R, U = turn(R, U, s.roll or 0)
    -- back to how a controller is held for that aim (weapon.lua pitches the controller by controller_pitch)
    local f, u = turn(F, U, -controller_pitch)
    return { pos = pos, f = f, u = u, r = cross(u, f) }
end

-- spec for hand("left", ...) that puts the left controller at world point p (cm), relative to the right hand
function H.left_at(p)
    local h = DEBUG_HANDS
    if h == nil then return nil end
    local d = sub(p, h.rh)
    local F, U = h.f, h.u
    local R = cross(U, F)
    local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
    return { rel = "right", fwd = dot(d, F), right = dot(d, R), up = dot(d, U) }
end
function H.weapon_mesh()
    local inv = H.pawn():GetComponentByClass(api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent"))
    local item = inv:GetEquippedInventoryItem()
    return item and item.Mesh, item
end

function debug_grip(side)
    return sim_get(side .. "_grip")
end

local BUTTONS = { UP = 0x1, DOWN = 0x2, LEFT = 0x4, RIGHT = 0x8, START = 0x10, BACK = 0x20, LS = 0x40, RS = 0x80,
                  LB = 0x100, RB = 0x200, A = 0x1000, B = 0x2000, X = 0x4000, Y = 0x8000 }
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    local p = sim_get("pad")
    if p == nil then return end
    local g = state.Gamepad
    local mask = 0
    for _, b in ipairs(p.buttons or {}) do mask = mask | (BUTTONS[b] or 0) end
    g.wButtons = g.wButtons | mask
    if p.lt then g.bLeftTrigger = math.floor(p.lt * 255) end
    if p.rt and not (gestures_fire_blocked and gestures_fire_blocked()) then g.bRightTrigger = math.floor(p.rt * 255) end
    local function axis(x) return math.max(-32768, math.min(32767, math.floor(x * 32767))) end
    if p.lx then g.sThumbLX = axis(p.lx) end
    if p.ly then g.sThumbLY = axis(p.ly) end
    if p.rx then g.sThumbRX = axis(p.rx) end
    if p.ry then g.sThumbRY = axis(p.ry) end
end)

-- command file -----------------------------------------------------------------------------------------------
local ticks = 0
uevr.sdk.callbacks.on_pre_engine_tick(function()
    ticks = ticks + 1
    if not has_io or ticks % 45 ~= 0 then return end -- (a file check costs ~4 ms: not every frame)
    local f = io.open(DIR .. "cmd.lua", "r")
    if f == nil then return end
    local src = f:read("a")
    f:close()
    if os.remove then os.remove(DIR .. "cmd.lua") else io.open(DIR .. "cmd.lua", "w"):close() end
    if src == "" then return end -- emptied (no os.remove): already run

    local lines = {}
    local env = setmetatable({}, { __index = function(_, k) local h = H[k] if h ~= nil then return h end return _G[k] end })
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = dump((select(i, ...))) end
        table.insert(lines, table.concat(parts, "  "))
    end
    H.print = env.print
    local chunk, err = load(src, "cmd", "t", env)
    if chunk == nil then
        table.insert(lines, "SYNTAX ERROR: " .. tostring(err))
    else
        local res = table.pack(xpcall(chunk, function(e) return debug and debug.traceback(tostring(e), 2) or tostring(e) end))
        if not res[1] then table.insert(lines, "ERROR: " .. tostring(res[2]))
        else for i = 2, res.n do table.insert(lines, "=> " .. dump(res[i])) end end
    end
    local o = io.open(DIR .. "out.txt", "w")
    o:write(table.concat(lines, "\n"), "\n")
    o:close()
end)

log("loaded")
