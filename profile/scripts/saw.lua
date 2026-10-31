-- Gears of War: E-Day VR melee: the chainsaw, and blows with the fist and the weapon.
--   * Fist (the empty left hand, its grip held) and weapon (any; the Lancer only while its chainsaw is off) hit what
--     they reach moving faster than MELEE_SPEED: the game's own melee damage on the bone hit, a little blood, a jolt
--     in the hand. One hit per enemy per MELEE_EVERY s.
--   * Collisions (weapon.lua asks melee_block): the weapon's front and the free left hand stop at an enemy's body
--     instead of going through it (the running chainsaw goes SAW_BITE cm in, to cut; blows BLOW_TOUCH cm, to land).
-- Chainsaw: the Lancer's chainsaw, started with its lever (gestures.lua: CHAINSAW_HOLD, the
-- game's B held = its rev: sound, running teeth), cuts what its blade touches, where it touches.
--   * The game's own cut is a canned execution (the same diagonal cut every time, the player frozen in it). It starts
--     when a revving Marcus has an enemy close in front of his body - his (unseen) body is kept turned away from
--     enemies near him, so it never starts.
--   * The blade (traced on the enemies' meshes, along its run and swept from the last frame) hits a bone: chainsaw
--     damage on that bone (the game's own damage type), every SAW_HIT_EVERY s while it stays in. The game's gore
--     breaks the bone hit (head, arm, leg, waist come off where the blade went) and kills when the health is gone.
local api = uevr.api
local vr = uevr.params.vr

local ucache = {}
local function ucall(obj, name, ...)
    local f = ucache[name]
    if f == nil then f = obj[name] ucache[name] = f end
    return f(obj, ...)
end

local function log(msg)
    pcall(function() uevr.params.functions.log_info("[saw] " .. tostring(msg)) end)
end

local function cdo(path) return api:find_uobject(path):get_class_default_object() end
local kstring = cdo("Class /Script/Engine.KismetStringLibrary")
local kmath = cdo("Class /Script/Engine.KismetMathLibrary")
local statics = cdo("Class /Script/Engine.GameplayStatics")
local pawn_c = api:find_uobject("Class /Script/Engine.Pawn")
local inv_c = api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent")
local tag_c = api:find_uobject("Class /Script/TCGameplayTags.TCGameplayTagComponent")
local hit = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
local NONE = kstring:Conv_StringToName("None")
local DAMAGE_TYPE = "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/DamageTypes/Combat/DamageType_Melee_Chainsaw_Strike.DamageType_Melee_Chainsaw_Strike_C"
local BLOOD = "NiagaraSystem /Game/Fairlight/Effects/_Shared/Niagara/Blood/NS_Blood_Execution_Chainsaw.NS_Blood_Execution_Chainsaw"

-- The blade, in the weapon's space (its teeth b_tooth1..40 run a loop at x 30.6..72.4, z -11..2.7 under the barrel):
-- the lower run (the cutting edge), the upper run, and the tip.
local BLADE = { { { 32, 0, -10 }, { 73, 0, -4 } }, { { 33, 0, 2 }, { 73, 0, 0 } } }
local BLADE_TIP = { 73, 0, -2 }
MELEE_HEAD = { -4, 0, 52 } -- melee weapons' striking point in their space
local SAW_HIT_EVERY = 0.08   -- s between damage hits while the blade stays in a body
local SAW_DAMAGE = 200       -- per hit (the game scales it: a Drone, 1500 health, is through in ~0.4 s; a bone breaks on the first)
local MELEE_SPEED = 180       -- cm/s: slower than this, a fist or weapon only touches
local MELEE_EVERY = 0.35      -- s between blows on the same enemy
local BLOW_SHARE = 0.55        -- of the enemy's full health per blow: 2 blows kill (fist or weapon)
local SMALL_HEALTH = 600      -- full health at or under this (Wretches and the like): 1 blow kills
local blow_scale = {}         -- damage type -> what the game makes of 1 point of it (measured on every blow; ~1.85)
local FIST_KNUCKLES = 8       -- cm from the left controller's point to the knuckles, along the hand
local FIST_REACH = 12         -- cm past the knuckles, along the punch, that still lands (bodies' collision is slimmer than their armour)
local PUNCH_TYPE = "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/DamageTypes/Combat/DamageType_Melee.DamageType_Melee_C"
local BASH_TYPE = "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/DamageTypes/Combat/DamageType_Melee_WeaponBlunt.DamageType_Melee_WeaponBlunt_C"
local SMALL_BLOOD = "NiagaraSystem /Game/Fairlight/Effects/_Shared/Niagara/Blood/NS_Blood_Execution_StrugglePunch.NS_Blood_Execution_StrugglePunch" -- the game's punch blood
local FIST_BLOOD, BASH_BLOOD = 0.7, 1.0 -- its size for a punch, a weapon blow
local SAW_BITE = 4            -- cm the running chainsaw's blade may go into a body (it cuts there)
local BLOW_TOUCH = 1.5        -- cm a weapon or fist goes in (so the blow's trace finds the body)
local NEAR = 400             -- cm: enemies this near Marcus are traced, and his body turns away from them
local PIN_TIME = 0.5          -- s an enemy the blade touched is held where it was (the game's hit reaction steps it back off the blade)
local LIST_EVERY = 0.2       -- s between enemy list refreshes (and right when the chainsaw starts)
local AWAY_MIN_GAP = 50  -- deg: with no direction this far from every enemy near, the rev is re-pressed before it is
                         -- primed (the game only starts its execution once primed; the sound stutters meanwhile)
local PRIME_CUT = 0.5    -- s of priming before that re-press (primed comes at ~0.55)
local REV_LOST_TIME = 0.4    -- s on without the game revving (after an interruption it wants B pressed again): B re-pressed

local enemies, list_clock = {}, -1
local last_hit = setmetatable({}, { __mode = "k" })
local last_tip = nil
local rev_lost = nil
local priming_since = nil
local pinned = setmetatable({}, { __mode = "k" }) -- enemy -> where it stood when the blade first touched it
local saw_near = nil -- this frame's enemies near Marcus (pre-tick), for the blade (after the weapon is placed)
local damage_type, blood = nil, nil
local found = {} -- path -> object (looked up until it is loaded)
-- An asset by its full name, looked up once. Not in memory (this chapter never loaded it): loaded once from the game's
-- files, and if that fails too the miss is remembered - a failed lookup scans every object (~430 ms: it froze the
-- game on every blow when the punch blood was missing).
local function find(path)
    if eday_asset ~= nil then return eday_asset(path) end -- (aa_assets.lua: loaded at the mission start, kept)
    local o = found[path]
    if o == nil then
        o = api:find_uobject(path)
        if o == nil then
            pcall(function()
                local ks = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
                local soft = ks:MakeSoftObjectPath((path:gsub("^%S+%s+", "")))
                o = ks:LoadAsset_Blocking(ks:Conv_SoftObjPathToSoftObjRef(soft))
            end)
            pcall(function() uevr.params.functions.log_info("[saw] asset " .. path .. (o ~= nil and " loaded from disk" or " missing")) end)
        end
        found[path] = o or false
    end
    return o or nil
end
KICK_BLOOD = "NiagaraSystem /Game/Fairlight/Effects/_Shared/Niagara/Blood/NS_Blood_Execution_Kick.NS_Blood_Execution_Kick"
-- (all looked up at the mission start: aa_assets.lua, list at the end of this file)
local melee_last = setmetatable({}, { __mode = "k" })
local last_fist, last_front, melee_clock = nil, nil, nil
local last_raw_front = nil
local muzzle_of = setmetatable({}, { __mode = "k" }) -- weapon mesh -> its muzzle in its own space

-- Blood comes out of the point hit, along the surface's normal, attached to the bone there (it moves with the body):
--   the chainsaw: a running spray per enemy, moved to each new cut, stopped BLOOD_STOP s after the blade left it;
--   a blow: one burst, stopped after BLOOD_STOP s.
local BLOOD_LOOP = "NiagaraSystem /Game/Fairlight/Effects/_Shared/Niagara/Blood/NS_Blood_Execution_Chainsaw_Loop.NS_Blood_Execution_Chainsaw_Loop"
local BLOOD_STOP = 0.15
local saw_fx = setmetatable({}, { __mode = "k" }) -- enemy -> { comp, at }
local bursts = {}                                  -- { comp, at }
local function hit_place()
    local ip, nm = hit.ImpactPoint, hit.ImpactNormal
    local nx, ny, nz = nm.X or nm.x, nm.Y or nm.y, nm.Z or nm.z
    local where = Vector3d.new((ip.X or ip.x) + nx * 2, (ip.Y or ip.y) + ny * 2, (ip.Z or ip.z) + nz * 2)
    local rot = Vector3d.new(math.deg(math.asin(math.max(-1, math.min(1, nz)))), math.deg(math.atan(ny, nx)), 0)
    return where, rot
end
local function blood_at(e, system, size)
    if system == nil then return nil end
    local where, rot = hit_place()
    local ok, comp = pcall(function()
        return cdo("Class /Script/Niagara.NiagaraFunctionLibrary"):SpawnSystemAttached(system, e.Mesh, hit.BoneName, where, rot,
            1, true, true, 0, true) -- (1: keep the world position given)
    end)
    if ok and comp ~= nil then pcall(function() comp:SetWorldScale3D(Vector3d.new(size, size, size)) end) return comp end
    return nil
end
-- the chainsaw cutting enemy e right now (at the hit just traced)
local function saw_blood(e, system)
    local now, fx = os.clock(), saw_fx[e]
    if fx ~= nil then
        local where, rot = hit_place()
        local ok = pcall(function() fx.comp:K2_SetWorldLocationAndRotation(where, rot, false, {}, true) end)
        if ok then fx.at = now return end
    end
    local comp = blood_at(e, system, 1.0)
    if comp ~= nil then saw_fx[e] = { comp = comp, at = now } end
end
local function blow_blood(e, system, size)
    local comp = blood_at(e, system, size)
    if comp ~= nil then table.insert(bursts, { comp = comp, at = os.clock() }) end
end
-- stops what is no longer being cut, and ended bursts (their drops already out still fall)
local function blood_tick()
    local now = os.clock()
    for i = #(glass_shooters or {}), 1, -1 do -- (glass_break's shooters: gone after their shot)
        if now - glass_shooters[i].t > (GLASS_SHOT_LIFE or 2) then
            pcall(function() glass_shooters[i].a:StopShooting() glass_shooters[i].a:K2_DestroyActor() end)
            table.remove(glass_shooters, i)
        end
    end
    for e, fx in pairs(saw_fx) do
        if now - fx.at > BLOOD_STOP then pcall(function() fx.comp:Deactivate() end) saw_fx[e] = nil end
    end
    for i = #bursts, 1, -1 do
        if now - bursts[i].at > BLOOD_STOP then pcall(function() bursts[i].comp:Deactivate() end) table.remove(bursts, i) end
    end
end

local function has_tag(actor, name)
    local tc = ucall(actor, "GetComponentByClass", tag_c)
    if tc == nil then return false end
    local tags = tc.CachedOwnedTagContainer.GameplayTags
    for i = 1, #tags do if tags[i].TagName:to_string() == name then return true end end
    return false
end

-- Sound: while the chainsaw is in an enemy the game's loud execution-cut loop plays; the moment an
-- enemy it cut dies, the flesh rip. Posted through the game's own Wwise layer (FairlightPlayerController
-- ClientTCWisePostEventGlobal) - AkGameplayStatics.PostEvent* return playing id 0 in this game (nothing plays).
local SND_DIR = "AkAudioEvent /Game/WwiseAudio/Events/Fairlight_Events/Characters/Executions/"
local SND = { cut = "Play_EXEC_WEP_Chainsaw_Execution_PCI", cut_stop = "Stop_EXEC_WEP_Chainsaw_Execution_PCI",
              rip = "Play_EXEC_Gore_Chainsaw_FleshRip_VCTM_PCI", rip_stop = "Stop_EXEC_Gore_Chainsaw_FleshRip_VCTM_PCI",
              cut_hold = 0.25,  -- s after the last cut the cutting sound stops
              rip_time = 1.5,   -- s the flesh rip plays
              victim_time = 3.0 } -- s after its last cut an enemy's death still counts as the chainsaw's
local snd = { cutting = false, last_cut = 0, rip_until = nil, victims = setmetatable({}, { __mode = "k" }) }
local function snd_path(n) return SND_DIR .. n .. "." .. n end
local function post(name)
    local ev = find(snd_path(name))
    if ev ~= nil then pcall(function() api:get_player_controller(0):ClientTCWisePostEventGlobal(ev, nil) end) end
end
local function saw_sound_cut(e) -- each cut (blade_tick)
    local now = os.clock()
    snd.last_cut, snd.victims[e] = now, now
    if not snd.cutting then snd.cutting = true post(SND.cut) end
end
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local ok, err = pcall(function()
        local now = os.clock()
        if snd.cutting and now - snd.last_cut > SND.cut_hold then snd.cutting = false post(SND.cut_stop) end
        for e, t in pairs(snd.victims) do
            if now - t > SND.victim_time then snd.victims[e] = nil
            elseif has_tag(e, "PawnState.PendingDeath") or has_tag(e, "PawnState.Dead") then
                snd.victims[e] = nil
                post(SND.rip)
                snd.rip_until = now + SND.rip_time
            end
        end
        if snd.rip_until ~= nil and now > snd.rip_until then snd.rip_until = nil post(SND.rip_stop) end
    end)
    if not ok then snd.errors = (snd.errors or 0) + 1 if snd.errors % 300 == 1 then log("sound: " .. tostring(err)) end end
end)

-- Severing (the body cut where the chainsaw goes). The game can only cut along planes authored in
-- each enemy's model (its gore "bridges"; measured on a Drone, what comes off): SkeletalPlane_Head (head),
-- _Torso (at the waist: pelvis + legs come off), _RightLeg/_LeftLeg (knee), _RightArm1/_LeftArm1 (shoulder: whole arm),
-- _RightArm2/_LeftArm2 (wrist), SlicedPlane1 / SlicedPlane2 (diagonal through the chest: head + left / right
-- shoulder and arm come off); _RightFoot/_LeftFoot break nothing. A free plane is not possible (no plane parameter
-- anywhere: the pieces are whole skeletons masked by the authored cuts). So once the blade has been in a body
-- GORE.after s, the authored cut nearest to where it is, at the blade's angle, is broken (TriggerBreak, forced); a
-- cut through the head or torso also kills. Each cut once per enemy; limbs can go one after another.
GORE = {
    after = 0.24,        -- s of blade in a body before its cut (3 hits)
    flat_cos = 0.8,      -- |blade normal . body up| above this = a level cut (waist); below = a diagonal
    sweep_min = 6,       -- cm the blade must move across itself in the body for its sweep to give the plane
    death_window = 0.6,  -- s after the blade's last hit a death still counts as its cut
    kill = 99999,
    joints = {           -- cut -> the bones its plane sits between (the hit goes to the nearest one); side = L / R
        { cut = "SkeletalPlane_Head", a = "b_neck", b = "b_head", kills = true },
        { cut = "TORSO", a = "b_spine_01", b = "b_spine_03", kills = true }, -- (waist or a diagonal: by the blade)
        { cut = "SkeletalPlane_RightArm1", a = "b_clavicle_R", b = "b_upperarm_R", w = 0.7 },
        { cut = "SkeletalPlane_LeftArm1", a = "b_clavicle_L", b = "b_upperarm_L", w = 0.7 },
        { cut = "SkeletalPlane_RightArm1", a = "b_upperarm_R", b = "b_forearm_R" },
        { cut = "SkeletalPlane_LeftArm1", a = "b_upperarm_L", b = "b_forearm_L" },
        { cut = "SkeletalPlane_RightArm2", a = "b_forearm_R", b = "b_hand_R" },
        { cut = "SkeletalPlane_LeftArm2", a = "b_forearm_L", b = "b_hand_L" },
        { cut = "SkeletalPlane_RightLeg", a = "b_thigh_R", b = "b_foot_R" },
        { cut = "SkeletalPlane_LeftLeg", a = "b_thigh_L", b = "b_foot_L" },
        { cut = "TORSO", a = "b_pelvis", b = "b_spine_01", kills = true },
    },
    settle_time = 0.35, -- s a body the blade killed is held still (its velocity zeroed each frame), then falls
    settle = setmetatable({}, { __mode = "k" }),
    names = {}, in_body = setmetatable({}, { __mode = "k" }), done = setmetatable({}, { __mode = "k" }),
    bridges = {},        -- enemy class -> { cut name = true } (what its model has)
}
local function gname(s) local n = GORE.names[s] if n == nil then n = kstring:Conv_StringToName(s) GORE.names[s] = n end return n end
local function gdot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
-- distance from p to the segment a-b
local function seg_dist(p, a, b)
    local ab = { x = b.x - a.x, y = b.y - a.y, z = b.z - a.z }
    local l2 = math.max(1e-6, gdot(ab, ab))
    local t = math.max(0, math.min(1, gdot({ x = p.x - a.x, y = p.y - a.y, z = p.z - a.z }, ab) / l2))
    local q = { x = a.x + ab.x * t - p.x, y = a.y + ab.y * t - p.y, z = a.z + ab.z * t - p.z }
    return math.sqrt(gdot(q, q))
end
local function bridges_of(e)
    local cls = e:get_class():get_fname():to_string()
    local have = GORE.bridges[cls]
    if have == nil then
        have = {}
        pcall(function()
            for _, b in ipairs(e.CharacterGoreComponent.GoreBridgeBreakDescriptions) do have[b.BridgeLookupName:to_string()] = true end
        end)
        GORE.bridges[cls] = have
    end
    return have
end
-- the body part a hit bone belongs to (any helper bone too: by its name)
local REGIONS = { { "head", "head" }, { "neck", "head" }, { "spine", "torso" }, { "pelvis", "torso" }, { "clavicle", "torso" },
    { "upperarm", "arm" }, { "forearm", "arm" }, { "hand", "arm" }, { "thumb", "arm" }, { "index", "arm" }, { "middle", "arm" },
    { "ring", "arm" }, { "pinky", "arm" }, { "thigh", "leg" }, { "calf", "leg" }, { "foot", "leg" }, { "ball", "leg" } }
function gore_region(bone)
    local b = bone:lower()
    for _, r in ipairs(REGIONS) do
        if b:find(r[1], 1, true) then
            if r[2] == "arm" or r[2] == "leg" then return r[2] .. (b:find("_l$") and "L" or b:find("_r$") and "R" or "?") end
            return r[2]
        end
    end
    return nil
end
-- which authored cut a blade makes in enemy e: by the body parts it went through in this contact (t.reg, hits per
-- part): the torso before the head before a limb (an arm in front of the belly - Drones hold their rifle there - must
-- not take a cut meant for the torso), then within that part the cut nearest the last hit `at`; plane normal n
function saw_pick_cut(e, at, n, reg)
    local m = e.Mesh
    reg = reg or {}
    local part = nil
    if (reg.torso or 0) > 0 and (reg.torso or 0) >= (reg.head or 0) then part = "torso"
    elseif (reg.head or 0) > 0 then part = "head"
    else
        local best = 0
        for k, v in pairs(reg) do if k ~= "torso" and k ~= "head" and v > best then part, best = k, v end end
    end
    local best, best_d = nil, 1e9
    for _, j in ipairs(GORE.joints) do
        local jp = j.cut == "TORSO" and "torso" or j.cut == "SkeletalPlane_Head" and "head"
            or (j.cut:find("Arm") and "arm" or "leg") .. (j.cut:find("Right") and "R" or "L")
        if part == nil or part == jp then
            local ok, d = pcall(function()
                return seg_dist(at, m:GetSocketLocation(gname(j.a)), m:GetSocketLocation(gname(j.b))) / (j.w or 1)
            end)
            if ok and d < best_d then best, best_d = j, d end
        end
    end
    if best == nil then return nil end
    local cut = best.cut
    if cut == "TORSO" then
        local up = e:GetActorUpVector()
        local right = e:GetActorRightVector()
        local nu = gdot(n, up)
        if math.abs(nu) > GORE.flat_cos then cut = "SkeletalPlane_Torso"
        else
            -- SlicedPlane1 runs from the right of the neck down to under the left arm (its plane's normal ~ up - right),
            -- SlicedPlane2 the mirror. A blade standing upright: the side of the chest it is in.
            local s = nu * gdot(n, right)
            if math.abs(nu) < 0.25 then
                local c = m:GetSocketLocation(gname("b_spine_03"))
                s = gdot({ x = at.x - c.x, y = at.y - c.y, z = at.z - c.z }, right) > 0 and 1 or -1
            end
            cut = s < 0 and "SlicedPlane1" or "SlicedPlane2"
        end
    end
    return cut, best.kills or cut == "SlicedPlane1" or cut == "SlicedPlane2"
end
local function break_cut(e, cut)
    local d = StructObject.new(api:find_uobject("ScriptStruct /Script/TCGore.TCGoreBreakDescriptionData"))
    d.bTriggerDefaultBloodSplatter = true
    d.bEnableMainBodyBreakEffects = true
    d.bEnableDismemberedBodyBreakEffects = true
    if cut:find("^Sliced") then d.bBreakByScriptedCut = true d.BreakScriptedCutName = gname(cut)
    else d.bBreakByCutLookup = true d.BreakCutLookup = gname(cut) end
    e.CharacterGoreComponent:TriggerBreak(d, true)
end
-- each blade hit (blade_tick): after GORE.after s in this body, or on the hit that kills it, its cut
-- The plane cut is the one the blade sweeps: its length (axis) and the way it moved in the body (tip since the
-- contact began); moved less than GORE.sweep_min cm, the blade's own flat (normal n).
function saw_gore_cut(e, at, n, weapon, dtype, tip, axis, dying, bone)
    local now = os.clock()
    local t = GORE.in_body[e]
    if t == nil or now - t.last > 0.3 then t = { since = now, tip = tip, reg = {} } GORE.in_body[e] = t end
    t.last = now
    local part = bone and gore_region(bone)
    if part then t.reg[part] = (t.reg[part] or 0) + 1 end
    if tip ~= nil and t.tip ~= nil and axis ~= nil then
        local mv = { x = tip.x - t.tip.x, y = tip.y - t.tip.y, z = tip.z - t.tip.z }
        -- (the part of the move along the blade does not open a plane)
        local al = gdot(mv, axis) / math.max(1e-6, gdot(axis, axis))
        mv = { x = mv.x - axis.x * al, y = mv.y - axis.y * al, z = mv.z - axis.z * al }
        local ml = math.sqrt(gdot(mv, mv))
        if ml > GORE.sweep_min then
            local c = { x = axis.y * mv.z - axis.z * mv.y, y = axis.z * mv.x - axis.x * mv.z, z = axis.x * mv.y - axis.y * mv.x }
            local cl = math.sqrt(gdot(c, c))
            if cl > 1e-6 then n = { x = c.x / cl, y = c.y / cl, z = c.z / cl } end
        end
        GORE_LAST_SWEEP = ml -- (debug)
    end
    -- (kept: the game marks a death a frame or more after the hit - gore_watch cuts it then, with this hit)
    t.at, t.n, t.weapon, t.dtype = at, n, weapon, dtype
    if now - t.since < GORE.after and not dying then return end -- (the hit that kills cuts at once)
    gore_do_cut(e, t, not dying)
end
-- the cut for enemy e from its last blade hit t; alive: a head / torso cut also kills it
function gore_do_cut(e, t, alive)
    local now = os.clock()
    local done = GORE.done[e] or {}
    GORE.done[e] = done
    if done.dead then return end
    local cut, kills = saw_pick_cut(e, t.at, t.n, t.reg)
    if cut == nil or done[cut] then return end
    local have = bridges_of(e)
    if next(have) ~= nil and not have[cut] then
        if cut:find("^Sliced") and have.SkeletalPlane_Torso then cut = "SkeletalPlane_Torso" else return end
    end
    done[cut] = true
    t.since, t.tip, t.reg = now, nil, {} -- (the next cut needs its own time in the body)
    local ok, err = pcall(break_cut, e, cut)
    if kills or not alive then done.dead = true GORE.settle[e] = now end
    if kills and alive then
        -- (the causer must be Marcus: with the weapon as causer ApplyDamage did nothing, measured)
        pcall(ucall, statics, "ApplyDamage", e, GORE.kill, api:get_player_controller(0), api:get_local_pawn(0), t.dtype)
    end
    SAW_LAST_GORE = { enemy = e:get_fname():to_string(), cut = cut, ok = ok, err = err, at = now, alive = alive } -- (debug)
    log("cut " .. cut .. (alive and "" or " (at death)") .. (ok and "" or (" failed: " .. tostring(err))))
end
-- enemies the blade was just in that the game has now marked dying: cut where the blade last was
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local now = os.clock()
    -- killed by the blade: the game's death throws the body (and a severed piece) metres away (measured 1.6-2.9 m,
    -- the kill-shot impulses at 0 too); held still for GORE.settle_time, it drops where it was cut
    for e, t0 in pairs(GORE.settle) do
        if now - t0 > GORE.settle_time then GORE.settle[e] = nil
        else
            pcall(function()
                local z = Vector3d.new(0, 0, 0)
                e.Mesh:SetAllPhysicsLinearVelocity(z, false)
                e.Mesh:SetAllPhysicsAngularVelocityInDegrees(z, false)
                for _, a in ipairs(e.CharacterGoreComponent.SpawnedDismembermentActors or {}) do
                    a.LeaderSkeletalMeshComponent:SetAllPhysicsLinearVelocity(z, false)
                    a.LeaderSkeletalMeshComponent:SetAllPhysicsAngularVelocityInDegrees(z, false)
                end
            end)
        end
    end
    for e, t in pairs(GORE.in_body) do
        if now - t.last > GORE.death_window then GORE.in_body[e] = nil
        elseif not (GORE.done[e] or {}).dead and t.at ~= nil then
            local ok, dead = pcall(function() return has_tag(e, "PawnState.PendingDeath") or has_tag(e, "PawnState.Dead") end)
            if ok and dead then pcall(gore_do_cut, e, t, false) GORE.settle[e] = GORE.settle[e] or now end
        end
    end
end)

-- enemies being cut stay where the blade found them (before and after the game's tick: its reaction moves them in it)
local function hold_pinned()
    local now = os.clock()
    for e, at in pairs(pinned) do
        if now - (last_hit[e] or 0) > PIN_TIME or has_tag(e, "PawnState.PendingDeath") or has_tag(e, "PawnState.Dead") then pinned[e] = nil
        else pcall(function() e:K2_SetActorLocation(at, false, {}, true) end) end
    end
end

-- the game's own identity tags: Locust and anything it calls an enemy, never a human (squad, other COG, civilians)
local function is_enemy(actor)
    local tc = ucall(actor, "GetComponentByClass", tag_c)
    if tc == nil then return false end
    local tags, enemy = tc.CachedOwnedTagContainer.GameplayTags, false
    for i = 1, #tags do
        local n = tags[i].TagName:to_string()
        if n:find("^ID%.Pawn%.Human") or n == "PawnState.Dead" then return false end -- (downed or dying ones count: the game executes those too)
        if n:find("^ID%.Pawn%.Locust") or n:find("^Narrative%.Tag%.Enemy") then enemy = true end
    end
    return enemy
end

-- enemies not dead yet (downed and dying ones too)
ENEMY_CAPSULE_RADIUS = 18 -- cm: enemies' collision capsules are made this slim
slimmed = setmetatable({}, { __mode = "k" }) -- enemy -> capsule already slimmed (global: script reloads keep it)
local function refresh_enemies(pawn)
    local all = {}
    ucall(statics, "GetAllActorsOfClass", pawn, pawn_c, all)
    enemies = {}
    for _, a in ipairs(all) do
        if a ~= pawn and a.Mesh ~= nil and is_enemy(a) then
            table.insert(enemies, a)
            -- their collision capsule is far wider than their bodies (a Wretch's: 50 cm radius, it kept Marcus 85 cm
            -- away): made slim, so he can walk up against them and hit them from close
            if not slimmed[a] then
                slimmed[a] = true
                pcall(function()
                    local c = a.CapsuleComponent
                    if c:GetUnscaledCapsuleRadius() > ENEMY_CAPSULE_RADIUS then c:SetCapsuleRadius(ENEMY_CAPSULE_RADIUS, true) end
                end)
            end
        end
    end
end

local function world(xf, p) return ucall(kmath, "TransformLocation", xf, Vector3d.new(p[1], p[2], p[3])) end
local function dist2(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2 end

local function trace(mesh, a, b)
    if ucall(mesh, "K2_LineTraceComponent", a, b, true, false, false, Vector3d.new(0, 0, 0), Vector3d.new(0, 0, 0), NONE, hit) then return true end
    return ucall(mesh, "K2_LineTraceComponent", b, a, true, false, false, Vector3d.new(0, 0, 0), Vector3d.new(0, 0, 0), NONE, hit) -- (from inside a body)
end

local function haptic(amp)
    pcall(function()
        eday_haptic(0.0, 0.06, 160, amp, vr.get_right_joystick_source())
        eday_haptic(0.0, 0.06, 160, amp, vr.get_left_joystick_source())
    end)
end

local function saw_tick(pawn)
    local now = os.clock()
    if now - list_clock > LIST_EVERY then list_clock = now refresh_enemies(pawn) end
    local me = pawn:K2_GetActorLocation()
    local near = {}
    for _, e in ipairs(enemies) do
        local ok, l = pcall(function() return e:K2_GetActorLocation() end)
        if ok and (l.x - me.x) ^ 2 + (l.y - me.y) ^ 2 < NEAR * NEAR then table.insert(near, { e = e, l = l }) end
    end
    saw_near = {}
    if has_tag(pawn, "PawnState.IsExecuting") then return end
    -- on, but the game is not revving (it stops after being interrupted, and wants B pressed again): re-pressed
    if has_tag(pawn, "PawnState.Chainsaw.Active") or (RIGHT_TRIGGER or 0) > 0.1 then rev_lost = nil
    else
        rev_lost = rev_lost or now
        if now - rev_lost > REV_LOST_TIME then SAW_REPRESS = 4 rev_lost = nil end
    end

    SAW_AWAY_GAP = nil
    saw_turn_away(pawn, me, near)
    saw_near = near
    if has_tag(pawn, "PawnState.Melee.Priming") then priming_since = priming_since or now else priming_since = nil end
    if SAW_AWAY_GAP ~= nil and SAW_AWAY_GAP < AWAY_MIN_GAP and priming_since ~= nil and now - priming_since > PRIME_CUT then
        SAW_REPRESS, priming_since = 2, nil
    end
end

-- the body turned away from the enemies near (the game's execution needs one close in front of it): of 36
-- directions, the one farthest (in angle) from every enemy within AWAY_NEAR cm - not their average, which with enemies
-- on several sides can point right at one of them
local AWAY_NEAR = 250
function saw_turn_away(pawn, me, near)
    local dirs = {}
    for _, n in ipairs(near) do
        local dx, dy = n.l.x - me.x, n.l.y - me.y
        if dx * dx + dy * dy < AWAY_NEAR * AWAY_NEAR then table.insert(dirs, math.deg(math.atan(dy, dx))) end
    end
    if #dirs == 0 then return end
    local best, best_gap = 0, -1
    for k = 0, 35 do
        local yaw = k * 10
        local gap = 180
        for _, a in ipairs(dirs) do
            local diff = math.abs(((a - yaw + 540) % 360) - 180)
            if diff < gap then gap = diff end
        end
        if gap > best_gap + 1 then best, best_gap = yaw, gap end
    end
    ucall(pawn, "K2_SetActorRotation", Vector3d.new(0, best, 0), false)
    SAW_AWAY_GAP = best_gap -- (debug: degrees between the body's front and the nearest enemy)
end

-- Ticker (sawing one must hurt so players avoid it): the blade kills it at once and it blows up
-- right there (its own death explosion: ~190 of Marcus' 2000 at 90 cm on Casual, measured), and the blast hits
-- Marcus for TICKER.share of his full health in all (explosive damage, the game scales what it is given: ~1.85,
-- learned per blast like the blows). Not when he is farther than TICKER.reach from it.
TICKER = { share = 0.5, reach = 250, delay = 0.1, scale = 1.85, explosive =
    "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/DamageTypes/Combat/DamageType_Explosive.DamageType_Explosive_C",
    pending = {} }
function saw_ticker(pawn, e)
    if not e:get_class():get_fname():to_string():find("Ticker") then return false end
    if TICKER.pending[e] then return true end
    local ok, h0 = pcall(function() return pawn.HealthComponent:GetCurrentHealth() end)
    TICKER.pending[e] = { t = os.clock(), h0 = ok and h0 or nil, at = e:K2_GetActorLocation() }
    pcall(ucall, statics, "ApplyDamage", e, GORE.kill, api:get_player_controller(0), pawn, find(DAMAGE_TYPE))
    log("ticker cut: it blows up")
    return true
end
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local now = os.clock()
    for e, pd in pairs(TICKER.pending) do
        if now - pd.t > TICKER.delay and not pd.hit then
            pd.hit = true
            pcall(function()
                local pawn = api:get_local_pawn(0)
                local me = pawn:K2_GetActorLocation()
                if (me.x - pd.at.x) ^ 2 + (me.y - pd.at.y) ^ 2 > TICKER.reach ^ 2 then return end
                local hp = pawn.HealthComponent
                local want = hp:GetCurrentMaxHealth() * TICKER.share - math.max(0, (pd.h0 or hp:GetCurrentHealth()) - hp:GetCurrentHealth())
                pd.h1 = hp:GetCurrentHealth()
                if want > 0 then
                    pd.raw = want / TICKER.scale
                    ucall(statics, "ApplyDamage", pawn, pd.raw, nil, pawn, find(TICKER.explosive))
                end
            end)
        elseif pd.hit and now - pd.t > TICKER.delay + 0.3 then
            TICKER.pending[e] = nil
            pcall(function() -- what the game made of it, for the next one
                local h2 = api:get_local_pawn(0).HealthComponent:GetCurrentHealth()
                if pd.raw and pd.h1 and pd.h1 - h2 > 1 then TICKER.scale = (pd.h1 - h2) / pd.raw end
                TICKER_LAST = { lost = (pd.h0 or 0) - h2, h0 = pd.h0, h1 = pd.h1, h2 = h2, raw = pd.raw, scale = TICKER.scale } -- (debug)
            end)
        end
    end
end)

-- after weapon.lua placed the weapon in the hand for this frame (its view callback): the blade, where it is shown
local function blade_tick(pawn, near)
    local now = os.clock()
    local me = pawn:K2_GetActorLocation()
    local inv = ucall(pawn, "GetComponentByClass", inv_c)
    local weapon = inv and ucall(inv, "GetEquippedInventoryItem")
    local m = weapon and weapon.RootComponent
    if m == nil then last_tip = nil return end
    local xf = ucall(m, "K2_GetComponentToWorld")
    local tip = world(xf, BLADE_TIP)
    local segs = {}
    for _, s in ipairs(BLADE) do table.insert(segs, { world(xf, s[1]), world(xf, s[2]) }) end
    if last_tip ~= nil and dist2(last_tip, tip) > 1 then table.insert(segs, { last_tip, tip }) end
    last_tip = tip

    SAW_DBG = { enemies = #enemies, near = #near, tip = tip, traced = 0, hits = 0, nearest = nil } -- (debug: tools/dbg.sh)
    for _, n in ipairs(near) do
        local d = math.sqrt(dist2(n.l, tip))
        if SAW_DBG.nearest == nil or d < SAW_DBG.nearest then SAW_DBG.nearest = d end
    end
    -- (asked each time: aa_assets.lua caches per world; an object kept here could be gone after the menu)
    damage_type = (eday_asset ~= nil or damage_type == nil) and find(DAMAGE_TYPE) or damage_type
    blood = (eday_asset ~= nil or blood == nil) and find(BLOOD) or blood
    for _, n in ipairs(near) do
        local e = n.e
        -- (not a body the blade has already killed: more hits on it threw it metres away - measured)
        if dist2(n.l, tip) < 200 * 200 and now - (last_hit[e] or 0) >= SAW_HIT_EVERY and not (GORE.done[e] or {}).dead
            and not has_tag(e, "PawnState.PendingDeath") then
            for _, s in ipairs(segs) do
                local ok, got = pcall(trace, e.Mesh, s[1], s[2])
                SAW_DBG.traced = SAW_DBG.traced + 1
                if not ok then SAW_DBG.err = tostring(got) end
                if ok and got then
                    last_hit[e] = now
                    if pinned[e] == nil then local l = e:K2_GetActorLocation() pinned[e] = Vector3d.new(l.x, l.y, l.z) end
                    local ip = hit.ImpactPoint
                    local at = { x = ip.X or ip.x, y = ip.Y or ip.y, z = ip.Z or ip.z }
                    local dx, dy, dz = at.x - me.x, at.y - me.y, at.z - me.z
                    local d = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
                    if saw_ticker(pawn, e) then break end -- (a Ticker blows up on the blade)
                    pcall(ucall, statics, "ApplyPointDamage", e, SAW_DAMAGE, Vector3d.new(dx / d, dy / d, dz / d), hit,
                        api:get_player_controller(0), weapon, damage_type)
                    saw_blood(e, find(BLOOD_LOOP) or blood)
                    saw_sound_cut(e)
                    local o, r, fw = world(xf, { 0, 0, 0 }), world(xf, { 0, 1, 0 }), world(xf, { 1, 0, 0 })
                    -- (health first: the game's PendingDeath tag comes a frame or more later)
                    local okz, zero = pcall(function() return e.HealthComponent:IsZeroHealth() end)
                    local dying = (okz and zero) or has_tag(e, "PawnState.PendingDeath") or has_tag(e, "PawnState.Dead")
                    pcall(saw_gore_cut, e, at, { x = r.x - o.x, y = r.y - o.y, z = r.z - o.z }, weapon, damage_type,
                        tip, { x = fw.x - o.x, y = fw.y - o.y, z = fw.z - o.z }, dying, hit.BoneName:to_string())
                    haptic(0.8)
                    SAW_LAST_CUT = { enemy = e:get_fname():to_string(), bone = hit.BoneName:to_string(), at = now } -- (debug)
                    break
                end
            end
        end
    end
end

-- Collisions. The first enemy body on the way from `from` (the eyes: never inside one) to `to`: the point where the
-- thing at `to` has to stop (`depth` cm past the surface), or nil when nothing is in the way.
melee_near = {}
function melee_block(from, to, depth)
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local L = math.sqrt(dx * dx + dy * dy + dz * dz)
    if L < 1 then return nil end
    local best = nil
    for _, n in ipairs(melee_near) do
        local ok, got = pcall(ucall, n.e.Mesh, "K2_LineTraceComponent", Vector3d.new(from.x, from.y, from.z), Vector3d.new(to.x, to.y, to.z),
            true, false, false, Vector3d.new(0, 0, 0), Vector3d.new(0, 0, 0), NONE, hit)
        if ok and got then
            local ip = hit.ImpactPoint
            local t = ((ip.X or ip.x) - from.x) * dx / L + ((ip.Y or ip.y) - from.y) * dy / L + ((ip.Z or ip.z) - from.z) * dz / L
            if best == nil or t < best then best = t end
        end
    end
    if best == nil or best + depth >= L then return nil end
    local k = (best + depth) / L
    return { x = from.x + dx * k, y = from.y + dy * k, z = from.z + dz * k }
end

-- the weapon's foremost point in its own space (the chainsaw's blade tip, the muzzle, or 50 cm along the barrel)
function melee_front_local(m)
    local wk = wkey(m) -- (by the weapon actor's name: a new weapon can take a destroyed one's address)
    local f = muzzle_of[wk]
    if f ~= nil then return f end
    f = { 50, 0, 0 }
    pcall(function()
        local xf = ucall(m, "K2_GetComponentToWorld")
        local l = ucall(kmath, "InverseTransformLocation", xf, eday_muzzle_pos(m) or ucall(m, "GetSocketLocation", kstring:Conv_StringToName("b_muzzle")))
        if l.x > 10 then f = { l.x, l.y, l.z } end
    end)
    pcall(function()
        if ucall(m, "DoesSocketExist", kstring:Conv_StringToName("b_tooth1")) then f = { BLADE_TIP[1], BLADE_TIP[2], BLADE_TIP[3] } end
    end)
    -- a melee weapon (wrench, crowbar): its head, up its shaft (its z; wrench physics: shaft z -33..27, head 27..61)
    pcall(function() if m:GetOwner():get_class():get_fname():to_string():find("MeleeWeapon") then f = { MELEE_HEAD[1], MELEE_HEAD[2], MELEE_HEAD[3] } end end)
    muzzle_of[wk] = f
    return f
end

function melee_depth() return CHAINSAW_HOLD and SAW_BITE or BLOW_TOUCH end

-- Blows on walls and objects (no enemy hit): the game's melee impact for the surface's material (glass, metal,
-- wood, else dust) where it lands, a jolt in the hand. The scenery around (cars and all) cannot break in this game.
local ksys = cdo("Class /Script/Engine.KismetSystemLibrary")
local IMPACT_DIR = "NiagaraSystem /Game/Fairlight/Effects/Gameplay/Weapons/Melee/NS/"
local IMPACTS = { Glass = "NS_NDC_GP_Melee_Impact_Glass", Metal = "NS_NDC_GP_Melee_Impact_Metal", Wood = "NS_NDC_GP_Melee_Impact_Wood", Dirt = "NS_NDC_GP_Melee_Impact_Dirt" }
local IMPACT_EVERY = 0.25 -- s between two of them
local world_hit = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
local no_col = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
local last_impact = 0
-- glass cracks where a blow lands on glass: the game's crack decal (a flat sheet, 57 x 56 cm, facing its x), small
local CRACK = "StaticMesh /Game/Fairlight/Environments/Art_Tools/BulletproofGlass/Mesh/glass_bulletproof_decal_01a.glass_bulletproof_decal_01a"
local CRACK_SCALE = 0.25    -- (about 14 cm)
local CRACK_OUT = 0.3       -- cm in front of the glass (not flickering with it)
local CRACKS_MAX = 40       -- the oldest go
local cracks = {}
local function crack(pawn, at, n)
    local mesh = find(CRACK)
    if mesh == nil then return end
    pcall(function()
        local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
        xf.Translation = Vector3d.new(at.x + n.x * CRACK_OUT, at.y + n.y * CRACK_OUT, at.z + n.z * CRACK_OUT)
        local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
        q.W = 1
        xf.Rotation = q
        xf.Scale3D = Vector3d.new(1, CRACK_SCALE, CRACK_SCALE)
        local a = ucall(statics, "BeginDeferredActorSpawnFromClass", pawn, api:find_uobject("Class /Script/Engine.StaticMeshActor"), xf, 1, nil, 0)
        a = ucall(statics, "FinishSpawningActor", a, xf, 0)
        local c = a.StaticMeshComponent
        c:SetMobility(2)
        c:SetStaticMesh(mesh)
        c:SetCollisionEnabled(0)
        c:SetCastShadow(false)
        -- facing out of the glass, turned at random about its face (not every crack the same)
        local rot = ucall(kmath, "MakeRotFromX", Vector3d.new(n.x, n.y, n.z))
        a:K2_SetActorLocationAndRotation(xf.Translation, Vector3d.new(rot.x, rot.y, math.random(0, 359)), false, {}, true)
        a:SetActorScale3D(Vector3d.new(1, CRACK_SCALE, CRACK_SCALE))
        table.insert(cracks, a)
        if #cracks > CRACKS_MAX then pcall(function() table.remove(cracks, 1):K2_DestroyActor() end) end
    end)
end
-- The second blow on a cracked spot breaks the glass: the game's car-window shatter (shards falling), the cracks
-- there gone; a real glass part (a vehicle's window component) is hidden with its collision off - a hole. Scenery
-- glass (FastGeo, no component) cannot be touched: it is clear, with the shards and no cracks it reads as broken.
GLASS_BREAK_NEAR = 35 -- cm from an earlier crack: the same spot
local SHATTER = "NiagaraSystem /Game/Fairlight/Effects/Environment/Destructibles/Glass/NS/NS_DEST_GlassShatter_CarWindow_M.NS_DEST_GlassShatter_CarWindow_M"
broken_glass = broken_glass or {} -- spots already broken: further blows there go through (no cracks)
-- The glass itself breaks only the way bullets break it (the game's own shot handling): an invisible, silent
-- shooter (the game's TCWeaponDummyFireActor, AI-possessed, a Gnasher) 30 cm out from the glass fires once at the
-- point; removed GLASS_SHOT_LIFE s later.
GLASS_SHOT_LIFE = 2.0
glass_shooters = glass_shooters or {}
function glass_shot(pawn, at, n)
    pcall(function()
        local cls = api:find_uobject("Class /Script/TCWeapon.TCWeaponDummyFireActor")
        local wcls = find("BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/WeaponAssets/Gnasher/BP_Wpn_Gnasher.BP_Wpn_Gnasher_C")
        if cls == nil or wcls == nil then return end
        local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
        xf.Translation = Vector3d.new(at.x + n.x * 30, at.y + n.y * 30, at.z + n.z * 30)
        local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
        local h = math.atan(-n.y, -n.x) / 2
        q.X, q.Y, q.Z, q.W = 0, 0, math.sin(h), math.cos(h)
        xf.Rotation = q
        xf.Scale3D = Vector3d.new(1, 1, 1)
        local a = ucall(statics, "BeginDeferredActorSpawnFromClass", pawn, cls, xf, 1, pawn, 0)
        local c = a.WeaponDummyFireComponent
        c.WeaponClass = wcls
        c.bHideWeaponMesh = true
        c.bSuppressWeaponTracers = true
        c.bSuppressWeaponPresentationCues = GLASS_SHOT_SILENT ~= false
        c.ShotsToFire = 1
        c.bCleanUpAutomaticallyOnStop = false
        c.bPointMuzzleAtTargetLocation = true
        a.AutoPossessAI = 3 -- (spawned: an AI controller - without one the weapon is never equipped and nothing fires)
        a = ucall(statics, "FinishSpawningActor", a, xf, 0)
        a:StartShootingAtLocation(Vector3d.new(at.x, at.y, at.z))
        table.insert(glass_shooters, { a = a, t = os.clock() })
        GLASS_SHOT_LAST = { at = os.clock(), actor = a } -- (debug)
    end)
end
function glass_break(pawn, at, n, comp)
    local function d2(a) local l = a:K2_GetActorLocation() return (l.x - at.x) ^ 2 + (l.y - at.y) ^ 2 + (l.z - at.z) ^ 2 end
    for _, b in ipairs(broken_glass) do
        if (b.x - at.x) ^ 2 + (b.y - at.y) ^ 2 + (b.z - at.z) ^ 2 < GLASS_BREAK_NEAR ^ 2 * 4 then return true end
    end
    -- the cracks in the world (also those of earlier script loads: the list starts empty on a reload)
    local all, mine = {}, {}
    pcall(function()
        ucall(statics, "GetAllActorsOfClass", pawn, api:find_uobject("Class /Script/Engine.StaticMeshActor"), all)
        local mesh = find(CRACK)
        for _, a in ipairs(all) do
            local ok, m = pcall(function() return a.StaticMeshComponent.StaticMesh end)
            if ok and m == mesh then table.insert(mine, a) end
        end
    end)
    local near = false
    for _, a in ipairs(mine) do
        local ok, d = pcall(d2, a)
        if ok and d < GLASS_BREAK_NEAR ^ 2 then near = true end
    end
    if not near then return false end
    -- broken: the cracks around go, the shards fall
    for _, a in ipairs(mine) do
        local ok, d = pcall(d2, a)
        if ok and d < (GLASS_BREAK_NEAR * 2) ^ 2 then
            pcall(function() a:K2_DestroyActor() end)
            for i = #cracks, 1, -1 do if cracks[i] == a then table.remove(cracks, i) end end
        end
    end
    local fx = find(SHATTER)
    if fx ~= nil then
        pcall(function()
            local rot = ucall(kmath, "MakeRotFromX", Vector3d.new(n.x, n.y, n.z))
            cdo("Class /Script/Niagara.NiagaraFunctionLibrary"):SpawnSystemAtLocation(pawn, fx, Vector3d.new(at.x, at.y, at.z), rot, Vector3d.new(1, 1, 1), true, true, 0, true)
        end)
    end
    if comp ~= nil then
        pcall(function()
            if comp:get_fname():to_string():lower():find("glass") or tostring(comp.StaticMesh and comp.StaticMesh:get_fname():to_string() or ""):lower():find("glass") then
                comp:SetVisibility(false, false)
                comp:SetCollisionEnabled(0)
            end
        end)
    end
    glass_shot(pawn, at, n)
    table.insert(broken_glass, { x = at.x, y = at.y, z = at.z })
    if #broken_glass > 60 then table.remove(broken_glass, 1) end
    GLASS_BROKEN_LAST = { at = os.clock(), comp = comp and comp:get_full_name() or "none", fx = fx ~= nil } -- (debug)
    return true
end
function saw_glass_hit(pawn, p, n, comp) if not glass_break(pawn, p, n, comp) then crack(pawn, p, n) end end -- (debug: tools/dbg.sh)
local function impact_for(material)
    local m = material:lower()
    local kind = (m:find("glass") and "Glass") or ((m:find("metal") or m:find("steel") or m:find("iron") or m:find("car")) and "Metal")
        or ((m:find("wood") or m:find("plank")) and "Wood") or "Dirt"
    local name = IMPACTS[kind]
    return find(IMPACT_DIR .. name .. "." .. name)
end
local function world_impact(pawn, weapon, a, b, hand_source)
    if os.clock() - last_impact < IMPACT_EVERY then return false end
    local ok, got = pcall(ucall, ksys, "LineTraceSingle", pawn, Vector3d.new(a.x, a.y, a.z), Vector3d.new(b.x, b.y, b.z), 1, true,
        { pawn, weapon or pawn }, 0, world_hit, true, no_col, no_col, 0.0)
    if not ok or not got then return false end
    last_impact = os.clock()
    -- the surface's physical material (the hit result's weak pointer to it, read from its memory)
    local material = "?"
    pcall(function() material = uevr.types.FUObjectArray.get():get_object(world_hit:read_dword(176)):get_fname():to_string() end)
    local ip, nm = world_hit.ImpactPoint, world_hit.ImpactNormal
    local at = Vector3d.new(ip.X or ip.x, ip.Y or ip.y, ip.Z or ip.z)
    local rot = ucall(kmath, "MakeRotFromX", Vector3d.new(nm.X or nm.x, nm.Y or nm.y, nm.Z or nm.z))
    local fx = impact_for(material)
    -- what was hit (scenery has none: FastGeo) - the hit result's actor / component, read from its memory
    local comp = nil
    pcall(function() local i = world_hit:read_dword(216) if i ~= 0 then comp = uevr.types.FUObjectArray.get():get_object(i) end end) -- (0: none)
    if material:lower():find("glass") then
        local p, n = { x = at.x, y = at.y, z = at.z }, { x = nm.X or nm.x, y = nm.Y or nm.y, z = nm.Z or nm.z }
        if not glass_break(pawn, p, n, comp) then crack(pawn, p, n) end
    end
    if fx ~= nil then
        pcall(function() cdo("Class /Script/Niagara.NiagaraFunctionLibrary"):SpawnSystemAtLocation(pawn, fx, at, rot, Vector3d.new(1, 1, 1), true, true, 0, true) end)
    end
    pcall(function() eday_haptic(0.0, 0.06, 140, 0.9, hand_source) end)
    WORLD_IMPACT_LAST = { material = material, at = os.clock(), comp = comp and comp:get_full_name() or "none" } -- (debug)
    return true
end

-- one blow: the game's melee damage on the bone hit, a little blood, a jolt in the hand that struck
local function blow(pawn, e, move, type_path, weapon, hand_source)
    local ip = hit.ImpactPoint
    local at = Vector3d.new(ip.X or ip.x, ip.Y or ip.y, ip.Z or ip.z)
    local d = math.max(1, math.sqrt(move.x * move.x + move.y * move.y + move.z * move.z))
    local hc = e.HealthComponent
    local full, before = 1500, nil
    pcall(function() full = hc.CurrentMaxHealth before = hc.CurrentHealth end)
    local share = full <= SMALL_HEALTH and 1.1 or BLOW_SHARE
    local damage = full * share / (blow_scale[type_path] or 1.85)
    pcall(ucall, statics, "ApplyPointDamage", e, damage, Vector3d.new(move.x / d, move.y / d, move.z / d), hit,
        api:get_player_controller(0), weapon or pawn, find(type_path))
    pcall(function()
        local after = hc.CurrentHealth
        if before ~= nil and after > 0 and before - after > 1 then blow_scale[type_path] = (before - after) / damage end
    end)
    blow_blood(e, find(SMALL_BLOOD) or find(KICK_BLOOD) or find(BLOOD), weapon == nil and FIST_BLOOD or BASH_BLOOD) -- (another blow's blood if the punch blood is not loaded)
    pcall(function() eday_haptic(0.0, 0.08, 120, 1.0, hand_source) end)
    MELEE_LAST = { enemy = e:get_fname():to_string(), bone = hit.BoneName:to_string(), damage = damage, at = os.clock() } -- (debug)
end

-- the first enemy (near, not struck just now) one of the segments goes into
local function first_hit(near, segs, now)
    for _, n in ipairs(near) do
        if now - (melee_last[n.e] or 0) >= MELEE_EVERY then
            for _, sg in ipairs(segs) do
                local ok, got = pcall(trace, n.e.Mesh, sg[1], sg[2])
                if ok and got then melee_last[n.e] = now return n.e end
            end
        end
    end
end

local function melee_tick(pawn)
    local now = os.clock()
    local dt = melee_clock and (now - melee_clock) or 0
    melee_clock = now
    if now - list_clock > LIST_EVERY then list_clock = now refresh_enemies(pawn) end
    local me = pawn:K2_GetActorLocation()
    local near = {}
    for _, e in ipairs(enemies) do
        local ok, l = pcall(function() return e:K2_GetActorLocation() end)
        if ok and (l.x - me.x) ^ 2 + (l.y - me.y) ^ 2 < 250 * 250 then table.insert(near, { e = e, l = l }) end
    end
    melee_near = near
    MELEE_DBG = { enemies = #enemies, near = #near, t = now } -- (debug)

    -- the fist
    local lp = LEFT_HAND_POS
    if lp ~= nil and LEFT_HAND_FWD ~= nil then
        local hf = LEFT_HAND_FWD
        lp = { x = lp.x + hf.x * FIST_KNUCKLES, y = lp.y + hf.y * FIST_KNUCKLES, z = lp.z + hf.z * FIST_KNUCKLES }
    end
    local fist = LEFT_GRIP_DOWN and not TWO_HANDED and not (gestures_hand_full ~= nil and gestures_hand_full()) and lp ~= nil
    if fist and last_fist ~= nil and dt > 0 then
        local move = { x = lp.x - last_fist.x, y = lp.y - last_fist.y, z = lp.z - last_fist.z }
        local d = math.sqrt(move.x ^ 2 + move.y ^ 2 + move.z ^ 2)
        if d / dt > MELEE_SPEED then
            local k = FIST_REACH / d
            local reach = Vector3d.new(lp.x + move.x * k, lp.y + move.y * k, lp.z + move.z * k)
            local e = first_hit(near, { { Vector3d.new(last_fist.x, last_fist.y, last_fist.z), reach } }, now)
            if e ~= nil then blow(pawn, e, move, PUNCH_TYPE, nil, vr.get_left_joystick_source())
            else world_impact(pawn, nil, last_fist, reach, vr.get_left_joystick_source()) end
        end
    end
    last_fist = (fist and lp ~= nil) and { x = lp.x, y = lp.y, z = lp.z } or nil

    -- the weapon (the Lancer's running chainsaw cuts instead)
    local inv = ucall(pawn, "GetComponentByClass", inv_c)
    local weapon = inv and ucall(inv, "GetEquippedInventoryItem")
    local m = weapon and weapon.RootComponent
    if m == nil or CHAINSAW_HOLD or RIGHT_FREE then last_front, last_raw_front = nil, nil return end -- (RIGHT_FREE: the weapon is on the back, invisible)
    local xf = ucall(m, "K2_GetComponentToWorld")
    local front = world(xf, melee_front_local(m))
    -- walls: where the hand swings it (the drawn weapon stops before them)
    local raw = WEAPON_RAW_FRONT
    if raw ~= nil and last_raw_front ~= nil and dt > 0 and not CHAINSAW_HOLD then
        local mv = { x = raw.x - last_raw_front.x, y = raw.y - last_raw_front.y, z = raw.z - last_raw_front.z }
        if math.sqrt(mv.x ^ 2 + mv.y ^ 2 + mv.z ^ 2) / dt > MELEE_SPEED then
            world_impact(pawn, weapon, last_raw_front, raw, vr.get_right_joystick_source())
        end
    end
    last_raw_front = raw and { x = raw.x, y = raw.y, z = raw.z } or nil
    if last_front ~= nil and dt > 0 and #near > 0 then
        local move = { x = front.x - last_front.x, y = front.y - last_front.y, z = front.z - last_front.z }
        local d = math.sqrt(move.x ^ 2 + move.y ^ 2 + move.z ^ 2)
        if d / dt > MELEE_SPEED then
            local e = first_hit(near, { { world(xf, { 0, 0, 0 }), front }, { Vector3d.new(last_front.x, last_front.y, last_front.z), front } }, now)
            if e ~= nil then blow(pawn, e, move, BASH_TYPE, weapon, vr.get_right_joystick_source()) end
        end
    end
    last_front = { x = front.x, y = front.y, z = front.z }
end

function saw_after_weapon()
    pcall(blood_tick)
    if CINEMATIC or AIM_FROZEN then last_fist, last_front, melee_clock = nil, nil, nil return end
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return end
    local okm, errm = pcall(melee_tick, pawn)
    if not okm then
        saw_errors = (saw_errors or 0) + 1
        if saw_errors % 300 == 1 then log("melee: " .. tostring(errm)) end
    end
    if not CHAINSAW_HOLD or saw_near == nil then last_tip = nil return end
    local ok, err = pcall(blade_tick, pawn, saw_near)
    if not ok then
        saw_errors = (saw_errors or 0) + 1
        if saw_errors % 300 == 1 then log(tostring(err)) end
    end
end

uevr.sdk.callbacks.on_post_engine_tick(function()
    if not CHAINSAW_HOLD or CINEMATIC or saw_near == nil then return end
    local pawn = api:get_local_pawn(0)
    if pawn ~= nil then pcall(function() saw_turn_away(pawn, pawn:K2_GetActorLocation(), saw_near) end) end
    hold_pinned()
end)

uevr.sdk.callbacks.on_pre_engine_tick(function()
    if not CHAINSAW_HOLD or CINEMATIC or AIM_FROZEN then
        if saw_near ~= nil then list_clock = -1 end -- (just stopped: the next start looks again at once)
        last_tip, saw_near, rev_lost = nil, nil, nil
        return
    end
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return end
    hold_pinned()
    local ok, err = pcall(saw_tick, pawn)
    if not ok then
        saw_errors = (saw_errors or 0) + 1
        if saw_errors % 300 == 1 then log(tostring(err)) end
    end
end)

-- what aa_assets.lua loads at every mission start
if eday_prefetch_add ~= nil then
    eday_prefetch_add(function()
        local list = { CRACK, SHATTER, SMALL_BLOOD, KICK_BLOOD, BLOOD, BLOOD_LOOP, DAMAGE_TYPE, PUNCH_TYPE, BASH_TYPE, TICKER.explosive,
            "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/WeaponAssets/Gnasher/BP_Wpn_Gnasher.BP_Wpn_Gnasher_C" }
        for _, name in pairs(IMPACTS) do table.insert(list, IMPACT_DIR .. name .. "." .. name) end
        for _, k in ipairs({ "cut", "cut_stop", "rip", "rip_stop" }) do table.insert(list, snd_path(SND[k])) end
        return list
    end)
end

log("loaded")
