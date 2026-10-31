-- Sprint on the left trigger: while it is held and Marcus walks, he goes SPRINT_SPEED_MULT times as
-- fast. The game's own sprint (roadie run = A held) starts with a dash and its own camera / animation, so the trigger
-- does not use it. (weapon.lua still sends A while the left stick press has SPRINTING on, and both can run together:
-- measured: walking 374 cm/s, trigger 600, stick press alone 372, both 600 - the speeds do not stack.)
-- The extra distance is added here each frame along the way he is already walking, as a swept move (walls and
-- objects stop it, the game's movement still slides along them). Nothing else changes - the view only moves with him.
-- weapon.lua sets LT_SPRINT (left trigger held and the left stick pushed, in gameplay); debug: rawset(_G, "SPRINT_TEST", true).
local api = uevr.api
SPRINT_SPEED_MULT = 1.6         -- times the walking speed (375 cm/s walking -> 600)
local MIN_SPEED = 100           -- cm/s: only while really walking (not starting / stopping / blocked)
local MAX_STEP = 20             -- cm per frame at most (a long frame must not jump through things)

local function log(m) pcall(function() uevr.params.functions.log_info("[sprint] " .. m) end) end
local errors = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local on = LT_SPRINT or rawget(_G, "SPRINT_TEST")
    if not on or CINEMATIC or VEHICLE or LADDER or AIM_FROZEN then return end
    local ok, err = pcall(function()
        local pawn = api:get_local_pawn(0)
        if pawn == nil then return end
        local m = pawn.CharacterMovement
        if m == nil or m.MovementMode ~= 1 then return end -- walking on the ground only (not falling, not in cover moves)
        local vel = pawn:GetVelocity()
        local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
        if speed < MIN_SPEED then return end
        local step = math.min(MAX_STEP, speed * (SPRINT_SPEED_MULT - 1) * delta)
        local p = pawn:K2_GetActorLocation()
        pawn:K2_SetActorLocation(Vector3d.new(p.x + vel.x / speed * step, p.y + vel.y / speed * step, p.z), true, {}, false)
    end)
    if not ok then
        errors = errors + 1
        if errors % 200 == 1 then log("error #" .. errors .. ": " .. tostring(err)) end
    end
end)
-- No game cover: in VR the player takes cover himself (crouching, stepping behind a wall). The game's
-- A (the dash on the left stick press) next to a wall snapped Marcus into cover. TCCoverComponent.bCoverEntryDisabled
-- keeps him out of it; set again every second (a new pawn after a checkpoint comes with it off).
local cover_c = api:find_uobject("Class /Script/FairlightGameFramework.FairlightCoverComponent")
local cover_check = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    cover_check = cover_check + delta
    if cover_check < 1.0 then return end
    cover_check = 0
    pcall(function()
        local pawn = api:get_local_pawn(0)
        local c = pawn and pawn:GetComponentByClass(cover_c)
        -- (off again in cutscenes: set during one, the pause menu's Return to game left the game stuck paused;
        -- bisected to this flag)
        local want = not CINEMATIC
        if c ~= nil and c.bCoverEntryDisabled ~= want then
            c.bCoverEntryDisabled = want
            log("game cover entry " .. (want and "disabled" or "enabled (cutscene)"))
        end
    end)
end)
-- ...but that flag does not stop the cover entry of the game's A (the dash on the left stick press / its roadie run):
-- moving towards a wall or low cover, A slides Marcus into cover. weapon.lua sends A only while WALL_AHEAD is
-- false: nothing within COVER_AHEAD cm the way he is going (two traces, waist and knee height, pawns ignored).
WALL_AHEAD = false
local COVER_AHEAD = 250.0
local wall_t = 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if rawget(_G, "DEV_NO_WALLCHECK") then return end
    wall_t = wall_t + delta
    if wall_t < 0.05 then return end
    wall_t = 0
    local ok, err = pcall(function()
        local pawn = api:get_local_pawn(0)
        if pawn == nil or world_block == nil then WALL_AHEAD = false return end
        local vel = pawn:GetVelocity()
        local dx, dy = vel.x, vel.y
        if math.sqrt(dx * dx + dy * dy) < 50 then -- not moving yet: where the left stick points (head aim: control yaw)
            local yaw = math.rad(api:get_player_controller(0).ControlRotation.y)
            local sx, sy = LEFT_STICK_X or 0, LEFT_STICK_Y or 0
            dx = math.cos(yaw) * sy - math.sin(yaw) * sx
            dy = math.sin(yaw) * sy + math.cos(yaw) * sx
        end
        local l = math.sqrt(dx * dx + dy * dy)
        if l < 0.05 then WALL_AHEAD = false return end
        dx, dy = dx / l, dy / l
        local p = pawn:K2_GetActorLocation()
        local wa = nil
        pcall(function() wa = arms_request and arms_request.weapon_object and arms_request.weapon_object:GetOwner() end)
        local hit = false
        for _, h in ipairs({ 0.0, -40.0 }) do
            local from = { x = p.x, y = p.y, z = p.z + h }
            local to = { x = p.x + dx * COVER_AHEAD, y = p.y + dy * COVER_AHEAD, z = p.z + h }
            if world_block(pawn, wa, from, to, 0) ~= nil then hit = true break end
        end
        WALL_AHEAD = hit
    end)
    if not ok then
        errors = errors + 1
        if errors % 200 == 1 then log("wall check error #" .. errors .. ": " .. tostring(err)) end
    end
end)
-- Real crouch: ducking behind something in the room must hide Marcus from the enemies. The game has
-- no crouch outside cover (Crouch() only shrinks the capsule: head 162 cm above the floor either way, measured), so his
-- own body - hidden from the player, hit by the enemies - is lowered as far as the headset went down below the highest
-- it has been (CROUCH.dead cm free for head bobbing, CROUCH.max at most). fp.lua adds CROUCH_DROP back to the camera
-- height: the view follows the headset only. Off in cutscenes / vehicles / ladders.
CROUCH_DROP = 0
local CROUCH = { dead = 10.0, max = 80.0, tau = 0.08 }
local crouch = { pawn = nil, base_z = nil, stand_h = nil }
local hmd_p, hmd_q = UEVR_Vector3f.new(), UEVR_Quaternionf.new()
-- The headset height is read in the view callback (as weapon.lua reads the controllers): read from the engine tick,
-- vr.get_pose / is_hmd_active cost ~12 ms a frame (measured: 72 -> 36 fps); the tick only uses the last value.
local hmd_h, hmd_h_at = nil, 0
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(d, vi, w2m, pos, rot)
    if vi ~= 1 then return end
    pcall(function()
        local vr = uevr.params.vr
        vr.get_pose(vr.get_hmd_index(), hmd_p, hmd_q)
        hmd_h, hmd_h_at = hmd_p.y * 100, os.clock() -- cm above the play-space floor
    end)
end)
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local ok, err = pcall(function()
        local pawn = api:get_local_pawn(0)
        if pawn == nil or pawn.Mesh == nil or rawget(_G, "DEV_NO_CROUCH") then return end
        local mesh = pawn.Mesh
        if pawn ~= crouch.pawn then
            crouch.pawn, crouch.base_z, CROUCH_DROP = pawn, mesh.RelativeLocation.z, 0
        end
        local want = 0
        if hmd_h ~= nil and os.clock() - hmd_h_at < 0.25 and not CINEMATIC and not VEHICLE and not LADDER then
            local h = hmd_h
            crouch.stand_h = math.max(crouch.stand_h or h, h)
            want = math.max(0, math.min(CROUCH.max, crouch.stand_h - h - CROUCH.dead))
        end
        local before = CROUCH_DROP
        CROUCH_DROP = CROUCH_DROP + (want - CROUCH_DROP) * (1 - math.exp(-delta / CROUCH.tau))
        if want == 0 and CROUCH_DROP < 0.05 then CROUCH_DROP = 0 end
        if math.abs(CROUCH_DROP - before) > 0.01 or (CROUCH_DROP == 0 and before ~= 0) then
            local r = mesh.RelativeLocation
            mesh:K2_SetRelativeLocation(Vector3d.new(r.x, r.y, crouch.base_z - CROUCH_DROP), false, {}, true)
        end
    end)
    if not ok then
        errors = errors + 1
        if errors % 200 == 1 then log("crouch error #" .. errors .. ": " .. tostring(err)) end
    end
end)
log("loaded")