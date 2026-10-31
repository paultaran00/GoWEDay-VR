-- OpenXR port: every hold, hand placement and grab of the mod was measured on OpenVR's controller grip
-- pose. Under OpenXR, SteamVR gives the spec grip pose instead ("openxr_grip"), another point and angle of the same
-- controller: SteamVR's render model (Quest 2 Touch, resources/rendermodels/oculus_quest2_controller_*.json) has
--   grip        origin (0, 0.003, 0.097)                  rotate_xyz (5.037, 0, 0)
--   openxr_grip origin (+-0.007, -0.00182941, 0.1019482)   rotate_xyz (20.6, 0, 0)
-- (the game's binding steam.app.3010850_oculus_touch_2_binding.json takes grippose from pose/openxr_grip). Without a fix
-- the hands sit wrong on the weapon under OpenXR. eday_pose() gives the OpenVR grip pose on both
-- runtimes: OpenVR grip = OpenXR grip * inverse(openxr_grip local) * (grip local), in the grip's own frame
-- (x right, y up, -z forward, metres): a turn of -15.563 deg about x and the offset below.
local vr = uevr.params.vr

local XR_FIX_DEG = 5.037 - 20.6
local function xr_offset(sign)
    -- Rx(-20.6) * (grip origin - openxr_grip origin)
    local a = math.rad(-20.6)
    local dx, dy, dz = -sign * 0.007, 0.003 + 0.00182941, 0.097 - 0.1019482
    return { x = dx, y = math.cos(a) * dy - math.sin(a) * dz, z = math.sin(a) * dy + math.cos(a) * dz }
end
XR_GRIP_FIX = XR_GRIP_FIX or {
    left = { off = xr_offset(1), deg = XR_FIX_DEG },   -- (left: openxr_grip x +0.007 -> grip is 0.007 to its -x)
    right = { off = xr_offset(-1), deg = XR_FIX_DEG }, -- (verified offline: model -> both poses, 0 mm / 0 deg left)
}
XR_GRIP_FIX_ON = (XR_GRIP_FIX_ON == nil) and true or XR_GRIP_FIX_ON -- (debug switch)

-- (kept once true only: read while UEVR is still starting, it is false - the first version kept that for the whole
-- session and the grip fix stayed off on OpenXR)
local is_xr = false
function eday_is_openxr()
    if not is_xr then
        local ok, r = pcall(function() return vr.is_openxr() end)
        is_xr = ok and r == true
    end
    return is_xr
end

local function qmul(a, b)
    return { x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z }
end
local function qrot(q, x, y, z)
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end

-- vr.get_pose with the controllers as OpenVR's grip pose (pos: UEVR_Vector3f, rot: UEVR_Quaternionf, written in place)
function eday_pose(index, pos, rot)
    vr.get_pose(index, pos, rot)
    if not XR_GRIP_FIX_ON or not eday_is_openxr() then return end
    local fix
    if index == vr.get_left_controller_index() then fix = XR_GRIP_FIX.left
    elseif index == vr.get_right_controller_index() then fix = XR_GRIP_FIX.right end
    if fix == nil then return end
    local q = { x = rot.x, y = rot.y, z = rot.z, w = rot.w }
    if q.x == 0 and q.y == 0 and q.z == 0 and q.w == 1 and pos.x == 0 and pos.y == 0 and pos.z == 0 then return end -- (not tracked)
    local ox, oy, oz = qrot(q, fix.off.x, fix.off.y, fix.off.z)
    pos.x, pos.y, pos.z = pos.x + ox, pos.y + oy, pos.z + oz
    local h = math.rad(fix.deg) / 2
    local r = qmul(q, { x = math.sin(h), y = 0, z = 0, w = math.cos(h) })
    rot.x, rot.y, rot.z, rot.w = r.x, r.y, r.z, r.w
end

-- Handedness (VR SETTINGS, PRIMARY HAND). Roles stay "right" = weapon hand, "left" = support hand everywhere; for a
-- left-handed player UEVR's own VR_SwapControllerInputs turns the controllers round (indices, joystick sources, the
-- XInput layout: sticks, triggers, grips, face buttons), and every sideways constant of the mod is mirrored by a hook
-- registered here: eday_on_hand(function(left) ... end) runs at once if the hand is known and on every change.
EDAY_LEFTY = nil -- nil until vrsettings.lua has read the setting
local hand_hooks = {}
function eday_on_hand(fn)
    hand_hooks[#hand_hooks + 1] = fn
    if EDAY_LEFTY ~= nil then pcall(fn, EDAY_LEFTY) end
end
-- The pose of get_left/right_controller_index() is always the PHYSICAL left/right controller (VR.cpp get_transform looks
-- the index up against the swapped numbers: measured, VR_SwapControllerInputs swaps the inputs - buttons, sticks, triggers,
-- grips - and the index numbers, not the poses). So the pose of the weapon hand ("right" role) is the physical left
-- controller's when left-handed: poses of the roles come through here, inputs through get_right/left_joystick_source.
function eday_role_index(role)
    if (role == "right") == (EDAY_LEFTY == true) then return vr.get_left_controller_index() end
    return vr.get_right_controller_index()
end
function eday_set_hand(left)
    EDAY_LEFTY = left == true
    pcall(function() vr.set_mod_value("VR_SwapControllerInputs", EDAY_LEFTY and "true" or "false") end)
    for _, fn in ipairs(hand_hooks) do pcall(fn, EDAY_LEFTY) end
end

-- Haptics. On SteamVR's OpenXR a pulse sometimes keeps going (the left controller buzzed on and
-- on after a Ticker blast); a pulse of amplitude 0 is ignored, a very weak one replaces it (stopped it, tested). So
-- every pulse of ours goes through eday_haptic, and HAPTIC_END s after a hand's last one a weak short pulse ends it.
local HAPTIC_END, HAPTIC_SOFT = 0.25, 0.01
-- eday_haptic_stop(): stop both hands now (debug / anything stuck)
function eday_haptic_stop()
    for _, src in ipairs({ vr.get_right_joystick_source(), vr.get_left_joystick_source() }) do
        pcall(function() vr.trigger_haptic_vibration(0.0, 0.01, 160, 0.0, src) end)
    end
end
local haptic_last = {} -- source key -> { t, src }
function eday_haptic(delay, secs, freq, amp, src)
    vr.trigger_haptic_vibration(delay, secs, freq, amp, src)
    haptic_last[tostring(src)] = { t = os.clock() + delay + secs, src = src }
end
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local now = os.clock()
    for k, h in pairs(haptic_last) do
        if now - h.t > HAPTIC_END then
            haptic_last[k] = nil
            pcall(function() vr.trigger_haptic_vibration(0.0, 0.03, 160, HAPTIC_SOFT, h.src) end)
            -- then a real stop: our UEVR patch turns amplitude 0 into xrStopHapticFeedback (the weak pulse alone did not
            -- end one stuck after a dash); without the patch a 0 pulse is ignored
            pcall(function() vr.trigger_haptic_vibration(0.05, 0.01, 160, 0.0, h.src) end)
        end
    end
end)

-- The muzzle bone of a weapon mesh: b_muzzle on most; the LMG (two barrels) has b_muzzle_01 / _02 and no b_muzzle -
-- the shots then came out of the game's own hidden weapon (down and to the right). Cached per mesh.
local muzzle_of = {}
local MUZZLE_NAMES = { "b_muzzle", "b_muzzle_01", "s_muzzle", "b_muzzle_L" }
-- the Troika (twin gun, b_muzzle_L / b_muzzle_R): the shots start between its barrels' ends (weapon space, cm; measured with
-- markers: the bones sit on the flash hiders' tips, 126.6, +-4.8, -22.25)
local MUZZLE_OFFSET = { BP_Wpn_Troika_C = { 126.6, 0.0, -22.25 } }
function eday_muzzle_name(mesh)
    -- (by the weapon actor's unique name: a new weapon can take a destroyed one's address)
    local okk, key = pcall(function() return mesh:GetOwner():get_fname():to_string() end)
    if not okk then key = mesh end
    local n = muzzle_of[key]
    if n == nil then
        n = false
        local ks = uevr.api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
        for _, c in ipairs(MUZZLE_NAMES) do
            local ok, i = pcall(function() return mesh:GetBoneIndex(ks:Conv_StringToName(c)) end)
            if ok and i ~= nil and i >= 0 then n = c break end
        end
        muzzle_of[key] = n
    end
    return n or nil
end
-- the muzzle point in the world (a vector with x y z): the muzzle bone, or the class's offset on the mesh
function eday_muzzle_pos(mesh)
    local n = eday_muzzle_name(mesh)
    if n == nil then return nil end
    local ok, cls = pcall(function() return mesh:GetOwner():get_class():get_fname():to_string() end)
    local o = ok and MUZZLE_OFFSET[cls] or nil
    local ks = uevr.api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
    if o == nil then return mesh:GetSocketLocation(ks:Conv_StringToName(n)) end
    local km = uevr.api:find_uobject("Class /Script/Engine.KismetMathLibrary"):get_class_default_object()
    return km:TransformLocation(mesh:K2_GetComponentToWorld(), Vector3d.new(o[1], o[2], o[3]))
end

pcall(function() uevr.params.functions.log_info("[xr] loaded, openxr " .. tostring(eday_is_openxr())) end)