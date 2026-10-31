-- Gears of War: E-Day VR scope: a real scope on scoped weapons (the Longshot). The game's own scope is a full-screen
-- zoom with a 2D overlay (and it hides the weapon) - in VR that is no scope at all. Here a camera at the scope's
-- front (SceneCapture2D, a narrow field of view) draws into a texture shown on a disc at the eyepiece, with the
-- game's reticle over it: seen through only with the eye at the scope, like a real one. weapon.lua no longer sends
-- the game's aim (its zoom) while one is held (SCOPED_WEAPON).
-- Camera and discs are actors of their own, moved onto the weapon every frame (after weapon.lua placed it): a capture
-- component on the weapon broke the VR view. The camera renders on request (CaptureScene after the engine tick) and
-- only while the eye is at the eyepiece: left rendering every frame by itself, it put the squad in T-pose in the
-- headset's view. The reticle is two thin black lines (the game's reticle texture covered the whole lens).
local api = uevr.api

local ucache = {}
local function ucall(obj, name, ...)
    local f = ucache[name]
    if f == nil then f = obj[name] ucache[name] = f end
    return f(obj, ...)
end
local function log(msg)
    pcall(function() uevr.params.functions.log_info("[scope] " .. tostring(msg)) end)
end
local function cdo(path) return api:find_uobject(path):get_class_default_object() end
local kstring = cdo("Class /Script/Engine.KismetStringLibrary")
local kmat = cdo("Class /Script/Engine.KismetMaterialLibrary")
local kmath = cdo("Class /Script/Engine.KismetMathLibrary")
local krender = cdo("Class /Script/Engine.KismetRenderingLibrary")
local statics = cdo("Class /Script/Engine.GameplayStatics")
local inv_c = api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent")
local function N(s) return kstring:Conv_StringToName(s) end

-- Per weapon class (its mesh's space, cm: x along the barrel, z up), measured with markers on the Longshot: the
-- eyepiece's glass, the scope's front (the camera), the glass' radius, the field of view shown (deg; the glass
-- covers ~20 deg of the eye's view at the eyecup, so 5 deg is ~4x).
SCOPES = {
    BP_Wpn_Longshot_C = { eye = { 17.1, 0.0, 12.9 }, front = { 29.0, 0.0, 12.9 }, radius = 1.7, fov = 5.0 },
}
SCOPES.BP_Wpn_Longshot_Heroic_C = SCOPES.BP_Wpn_Longshot_C -- (the Heroic Longshot: the same scope)
local EYE_NEAR = 25       -- cm from the eyepiece: closer than this the scope's camera runs (it costs a scene render)
local RT_SIZE = 1024 -- (512 looked pixelated in the headset)
-- Cost (the Longshot lowered the frame rate): the camera renders the scene a second time. Every frame only while
-- the eye is at the eyepiece (EYE_NEAR); further away every FAR_EVERY-th frame; not at all while the lens is out of
-- the view (more than VIEW_CONE_DEG off where the head looks).
local FAR_EVERY = 3
local VIEW_CONE_DEG = 60
-- the scope's camera draws nothing further than this (cm): measured -4 ms per capture (22.5 -> 18.1 ms p50 with a
-- capture every frame); a smaller picture (512) gave -1.2 ms but looked pixelated, Lumen off / LOD x4: no gain
local VIEW_DISTANCE = 15000
local RETICLE_WIDTH = 0.035 -- cm, the reticle's lines
local CUBE = "StaticMesh /Engine/BasicShapes/Cube.Cube" -- (100 cm)
local LENS_MAT = "MaterialInstanceConstant /Engine/EngineMaterials/Widget3DPassThrough_Opaque_OneSided.Widget3DPassThrough_Opaque_OneSided"
local LINE_MAT = "MaterialInstanceConstant /Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque"
local WHITE = "Texture2D /Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local DISC = "StaticMesh /Engine/BasicShapes/Cylinder.Cylinder" -- (100 cm across, 100 tall: flattened into a disc)

-- { cap, lens, lines, rt }: built once, shared by every scoped weapon. A script reload starts a new Lua state, so what
-- an earlier one built is found in the world and removed: basic-shape mesh actors drawn with the widget material,
-- and scene captures drawing into a render target made by Marcus' pawn.
local function remove_old()
    local p = api:get_local_pawn(0)
    if p == nil then return false end
    local n = 0
    local all = {}
    ucall(statics, "GetAllActorsOfClass", p, api:find_uobject("Class /Script/Engine.StaticMeshActor"), all)
    for _, a in ipairs(all) do
        pcall(function()
            local c = a.StaticMeshComponent
            local mesh = c.StaticMesh and c.StaticMesh:get_full_name() or ""
            local mat = c:GetMaterial(0)
            local mn = mat and mat:get_full_name() or ""
            pcall(function() mn = mn .. " " .. mat.Parent:get_full_name() end)
            if mesh:find("/Engine/BasicShapes/") and mn:find("Widget3DPassThrough") then a:K2_DestroyActor() n = n + 1 end
        end)
    end
    local caps = {}
    ucall(statics, "GetAllActorsOfClass", p, api:find_uobject("Class /Script/Engine.SceneCapture2D"), caps)
    for _, a in ipairs(caps) do
        pcall(function()
            local rt = a.CaptureComponent2D.TextureTarget
            -- ours: drawing into a target made by Marcus' pawn, or (target already gone) with our view distance;
            -- "rt == nil" alone also destroyed a capture of the game's own at a fresh start
            local cc = a.CaptureComponent2D
            local ours = (rt ~= nil and rt:get_full_name():find("BP_Pawn_") ~= nil)
                or (rt == nil and cc.MaxViewDistanceOverride == VIEW_DISTANCE and cc.CaptureSource == 0)
            if ours then a:K2_DestroyActor() n = n + 1 end
        end)
    end
    if n > 0 then log("removed " .. n .. " left from an earlier load") end
    return true
end
local cleaned = false
local parts = nil
-- a new level / the world streamed (a Longshot from a supply cache had no scope) destroys the lens,
-- lines, camera and render target while this Lua state still holds them (every tick then threw): checked every
-- CHECK_EVERY ticks and right after an error, and built again for whatever scoped weapon is in the hand
local ksys = cdo("Class /Script/Engine.KismetSystemLibrary")
local CHECK_EVERY = 30
local check_n, recheck = 0, false
local function parts_alive(s)
    local ok, alive = pcall(function()
        for _, o in ipairs({ s.lens, s.line_h, s.line_v, s.cap, s.rt }) do
            -- (garbage collected: no name; destroyed but not yet collected: not IsValid)
            if o == nil or o:get_full_name() == "" or not ksys:IsValid(o) then return false end
        end
        return true
    end)
    return ok and alive
end

local function spawn(cls_path)
    local pawn = api:get_local_pawn(0)
    local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
    xf.Translation = pawn:K2_GetActorLocation()
    local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
    q.W = 1
    xf.Rotation = q
    xf.Scale3D = Vector3d.new(1, 1, 1)
    local a = ucall(statics, "BeginDeferredActorSpawnFromClass", pawn, api:find_uobject(cls_path), xf, 1, nil, 0)
    return ucall(statics, "FinishSpawningActor", a, xf, 0)
end

local function material(path, texture, tint)
    local mid = kmat:CreateDynamicMaterialInstance(api:get_local_pawn(0), api:find_uobject(path), N("None"), 0)
    mid:SetTextureParameterValue(N("SlateUI"), texture)
    local c = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    c.R, c.G, c.B, c.A = tint, tint, tint, 1
    mid:SetVectorParameterValue(N("TintColorAndOpacity"), c)
    return mid
end

local function mesh_actor(mesh, mat, scale)
    local a = spawn("Class /Script/Engine.StaticMeshActor")
    local c = a.StaticMeshComponent
    c:SetMobility(2)
    c:SetStaticMesh(api:find_uobject(mesh))
    c:SetMaterial(0, mat)
    c:SetCollisionEnabled(0)
    c:SetCastShadow(false)
    a:SetActorScale3D(scale)
    return a
end

local function build(def)
    local black = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    black.R, black.G, black.B, black.A = 0, 0, 0, 1
    -- RGBA16f + the scene's light before tone mapping (SceneColorHDR): the lens (in the scene) is tone mapped and
    -- exposed once, by the main view, so the picture looks exactly like the view. The final LDR
    -- picture (source 2, RGBA8) was tone mapped twice: darker.
    local rt = krender:CreateRenderTarget2D(api:get_local_pawn(0), RT_SIZE, RT_SIZE, 6, black, true, false) -- (mips: sharp, not grainy, seen small)
    local cap = spawn("Class /Script/Engine.SceneCapture2D")
    local cc = cap.CaptureComponent2D
    cc.TextureTarget = rt
    cc.FOVAngle = def.fov
    cc.CaptureSource = 0 -- SCS_SceneColorHDR (see the render target above)
    cc.MaxViewDistanceOverride = VIEW_DISTANCE
    cc.bCaptureEveryFrame = false
    cc.bCaptureOnMovement = false
    cc.bAlwaysPersistRenderingState = true -- its exposure carries from capture to capture (else: white in bright light)
    local lens = mesh_actor(DISC, material(LENS_MAT, rt, 1), Vector3d.new(def.radius / 50, def.radius / 50, 0.001))
    -- the reticle: in the weapon's axes, a line along y (horizontal) and one along z (vertical), just before the lens
    local black = material(LINE_MAT, api:find_uobject(WHITE), 0)
    local w, len = RETICLE_WIDTH / 100, def.radius * 2 / 100
    local line_h = mesh_actor(CUBE, black, Vector3d.new(0.0005, len, w))
    local line_v = mesh_actor(CUBE, black, Vector3d.new(0.0005, w, len))
    log("built")
    return { cap = cap, cc = cc, lens = lens, line_h = line_h, line_v = line_v, rt = rt, running = false, shown = true }
end

local function show(s, on)
    if s.shown == on then return end
    s.shown = on
    s.lens:SetActorHiddenInGame(not on)
    s.line_h:SetActorHiddenInGame(not on)
    s.line_v:SetActorHiddenInGame(not on)
    if not on then s.running = false end
end

local function scope_tick(eye, view_rot)
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return end
    local inv = ucall(pawn, "GetComponentByClass", inv_c)
    local w = inv and ucall(inv, "GetEquippedInventoryItem")
    local def = w and SCOPES[w:get_class():get_fname():to_string()]
    SCOPED_WEAPON = def ~= nil
    if parts ~= nil then
        check_n = check_n + 1
        if check_n >= CHECK_EVERY or recheck then
            check_n, recheck = 0, false
            if not parts_alive(parts) then
                log("parts gone (new level?): building again")
                parts, SCOPE_PARTS, cleaned = nil, nil, false
            end
        end
    end
    if not cleaned then
        local t0 = os.clock()
        cleaned = remove_old()
        log(string.format("cleanup took %.0f ms", (os.clock() - t0) * 1000))
        if not cleaned then return end
    end
    -- built ahead, hidden, as soon as a level has the pawn, with one capture (its first one compiles its shaders): taking
    -- a scoped weapon then only shows it (a freeze taking the Longshot from a supply cache right after
    -- entering the game; the cleanup alone is ~90 ms: 3700 mesh actors looked at)
    if parts == nil then
        local t0 = os.clock()
        parts = build(def or SCOPES[next(SCOPES)]) SCOPE_PARTS = parts
        parts.first, parts.warm = true, true
        show(parts, false)
        log(string.format("build took %.0f ms", (os.clock() - t0) * 1000))
    end
    if def == nil then
        show(parts, false)
        return
    end
    local s = parts
    show(s, true)
    s.cc.FOVAngle = def.fov
    -- onto the scope as the weapon is shown now
    local m = w.RootComponent
    local xf = ucall(m, "K2_GetComponentToWorld")
    local rot = ucall(m, "K2_GetComponentRotation")
    local e = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.eye[1], def.eye[2], def.eye[3]))
    local disc_rot = ucall(kmath, "ComposeRotators", Vector3d.new(90, 0, 0), rot) -- the disc's face back along the barrel
    ucall(s.lens, "K2_SetActorLocationAndRotation", e, disc_rot, false, {}, true)
    local r = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.eye[1] - 0.1, def.eye[2], def.eye[3]))
    ucall(s.line_h, "K2_SetActorLocationAndRotation", r, rot, false, {}, true)
    ucall(s.line_v, "K2_SetActorLocationAndRotation", r, rot, false, {}, true)
    local f = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.front[1], def.front[2], def.front[3]))
    -- zeroed at any range: the camera looks at where the shot lands (weapon.lua's trace along the barrel, 6.7 cm
    -- below the scope), keeping the weapon's tilt - the reticle's centre is the point of impact
    local look = rot
    local t = SHOT_POINT
    if t ~= nil then
        local dx, dy, dz = t.x - f.x, t.y - f.y, t.z - f.z
        local l = math.sqrt(dx * dx + dy * dy + dz * dz)
        if l > 50 then look = ucall(kmath, "MakeRotFromXZ", Vector3d.new(dx / l, dy / l, dz / l), ucall(m, "GetUpVector")) end
    end
    ucall(s.cap, "K2_SetActorLocationAndRotation", f, look, false, {}, true)
    -- the camera runs only while the eye is at the eyepiece
    -- the picture is kept up all the time the weapon is in the hand (seen from any distance, like a real scope)
    s.running = true
    local d2 = (e.x - eye.x) ^ 2 + (e.y - eye.y) ^ 2 + (e.z - eye.z) ^ 2
    local near = d2 < EYE_NEAR * EYE_NEAR
    -- the lens in the view? (the head's forward vs the direction to the lens)
    local in_view = true
    if not near and view_rot ~= nil and d2 > 1 then
        local p, y = math.rad(view_rot.x), math.rad(view_rot.y)
        local fx, fy, fz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
        local d = math.sqrt(d2)
        in_view = ((e.x - eye.x) * fx + (e.y - eye.y) * fy + (e.z - eye.z) * fz) / d > math.cos(math.rad(VIEW_CONE_DEG))
    end
    s.near, s.in_view = near, in_view
    SCOPE_DBG = { near = near, in_view = in_view, eye_dist = math.sqrt(d2) } -- (debug)
end

-- the scope's picture, rendered on request after the engine tick (see above), while the eye is at it
local capture_n = 0
uevr.sdk.callbacks.on_post_engine_tick(function()
    if parts ~= nil and parts.warm then
        parts.warm = false
        pcall(function() parts.cc:CaptureScene() end)
        log("warm-up capture")
        return
    end
    if parts == nil or not parts.running or not parts.shown then return end
    local dev = rawget(_G, "SCOPE_DEV") -- (debug: { every = n } far rate override for tests)
    if not parts.near then
        if parts.in_view == false then return end
        capture_n = capture_n + 1
        if capture_n % ((dev and dev.every) or FAR_EVERY) ~= 0 then return end
    end
    if parts.first then parts.first = false log("first capture") end
    pcall(function() parts.cc:CaptureScene() end)
end)

-- after weapon.lua placed the weapon (its view-1 callback): scope.lua is loaded before weapon.lua, so this is
-- registered on the first tick, after it
local registered = false
uevr.sdk.callbacks.on_pre_engine_tick(function()
    if registered then return end
    registered = true
    uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
        if view_index ~= 1 then return end
        if CINEMATIC then
            if parts ~= nil then pcall(show, parts, false) end
            return
        end
        local ok, err = pcall(scope_tick, { x = position.x, y = position.y, z = position.z }, { x = rotation.x, y = rotation.y })
        if AIM_FROZEN and parts ~= nil then parts.running = false end -- paused (menu): the lens stays on the scope, its camera rests
        if not ok then
            scope_errors = (scope_errors or 0) + 1
            recheck = true
            if scope_errors % 300 == 1 then log(tostring(err)) end
        end
    end)
end)

log("loaded")
