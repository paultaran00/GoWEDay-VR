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
-- The sights the game fits to other weapons (supply caches: WeaponModsComponent.AppliedMods, a mod whose name ends in
-- the key). Offsets from the sight's own bone on the weapon mesh (same axes as above), measured on the Lancer: the
-- sight meshes are the same on every weapon and sit at their bone. eye = just in front of the eyepiece glass, front = the
-- objective. glass = the game's own glass material of that sight (its reticle, drawn over our lens). fov: the game's
-- sights are 4x (WPN_COG_ScopeGlass_FPV4x, the Sniper), 2x (FPV2x, the Marksman) and a TargetFinder (taken as 4x); the
-- Longshot's 5 deg is ~4x (see above), so Sniper / TargetFinder 8, Marksman 13.3 (tuned in the headset). The HoloSight is not here: no zoom,
-- its glass is hidden and our own reticle is drawn (see HOLO_WINDOW).
-- Placed with a plug test (white disc at the lens depth = the eyepiece opening as seen from the player's kind of views, behind and
-- 15 deg above / to the side / below): the lens centre is within 1-2 % of the opening's width of the opening's centre in all of
-- them, and the lens is 0.98-0.99 of the opening's width. Glass planes (the game's own glass, where a lens slid along the bore
-- disappears, as the Longshot's 17.6 did; mesh x, cm): Sniper / TargetFinder ~17.25, Marksman ~21.65; the lenses sit a little in
-- front of them (17.0, 20.4). Offsets are from the sight's bone (mod_sightscope / mod_sighttargetfinder at x 23.66, z 14.36;
-- mod_sightmarksman at x 23.95, z 14.36): lens at z 19.38 (Sniper / TargetFinder), 19.22 (Marksman).
SIGHTS = {
    SniperScope = { bone = "mod_sightscope", eye = { -6.66, 0.0, 5.02 }, front = { 6.84, 0.0, 5.02 }, radius = 1.84, fov = 8.0, glass = "FPV4x" },
    MarksmanScope = { bone = "mod_sightmarksman", eye = { -3.55, 0.0, 4.86 }, front = { 4.0, 0.0, 4.86 }, radius = 1.42, fov = 13.3, glass = "FPV2x" },
    TargetFinder = { bone = "mod_sighttargetfinder", eye = { -6.66, 0.0, 5.02 }, front = { 6.84, 0.0, 5.02 }, radius = 1.84, fov = 8.0, glass = "FPVTargetFinder" },
}
-- The Locust scopes (Hammerburst...): the same mods (names ending MarksmanScope...) but another sight mesh (material WPN_Locust_Scope),
-- so its own numbers, chosen when the weapon's geometry has that material. Measured on the Hammerburst the same way (the glass depth by
-- sliding the lens behind the game's glass, the opening and its centre with the plug disc). Offsets from the sight's bone as above.
-- fov 13.3 = 1.5x (the Sniper's 5 deg is about 4x).
-- Hammerburst: bone mod_sightmarksman (25.33, 0, 14.93); its milky eyepiece glass (Y reticle) sits in front of x ~21, so the lens is at x 20.78 (tuned in the headset)
-- (in front of it) and the capture camera 12 cm past the bone (at 4 it was inside the scope and saw its glass from behind);
-- z 19.2 (centre of the opening), radius 1.8 (the opening is ~1.44 at x 21.1; 1.8 at the lens depth covers the gap off-axis).
SIGHTS_LOCUST = {
    MarksmanScope = { bone = "mod_sightmarksman", eye = { -4.55, 0.0, 4.27 }, front = { 12.0, 0.0, 4.27 }, radius = 1.8, fov = 13.3, glass = "NONE", -- (its own glass, LFPV2x, is a milky layer that hides the picture)
                      glass_name = "FPV2x" },
}
-- The Breechshot (a Locust weapon whose TargetFinder mesh sits at a different place than the Lancer's: the COG numbers put the lens 0.96 cm too high
-- and 0.3 cm too deep): measured with the plug disc (r 2.2 at x 13.2, behind the rim, which crops it): the opening's centre is 1.0 cm lower than the
-- COG lens centre (z 17.0), radius 1.88 (lens 1.95: slightly oversized, the rim crops it); front 12 (the camera must be past the scope body); the lens goes at the tuned depth (a little in front of where it was). Offsets from mod_sighttargetfinder.
SIGHTS_BREECHSHOT = {
    TargetFinder = setmetatable({ eye = { -6.97, 0.0, 4.06 }, front = { 12.0, 0.0, 4.06 }, radius = 1.95 }, { __index = SIGHTS.TargetFinder }),
    -- the Sniper's mesh sits where the TargetFinder's does (its own bone mod_sightscope is 7.6 cm behind): the same numbers from that bone
    SniperScope = setmetatable({ bone = "mod_sighttargetfinder", eye = { -6.97, 0.0, 4.06 }, front = { 12.0, 0.0, 4.06 }, radius = 1.95 }, { __index = SIGHTS.SniperScope }),
}
-- The Magnum (Locust pistol): the same Locust Marksman as the Hammerburst's, but its glass sits 0.7 cm further forward from the bone (found by sliding a
-- disc: x 2.8 = bone - 4.9, the Hammerburst's is bone - 4.2) and the lens was behind it (no lens at all): the Hammerburst entry moved 0.7 cm forward
-- (eye x -4.55 -> -5.25), z 4.27 -> 4.19 (glass centre).
SIGHTS_MAGNUM = {
    MarksmanScope = setmetatable({ eye = { -5.03, 0.0, 4.34 }, front = { 12.0, 0.0, 4.34 } }, { __index = SIGHTS_LOCUST.MarksmanScope }), -- (tuned in the headset)
    -- the Sniper / TargetFinder are the Locust sniper mesh, as the Breechshot's TargetFinder: the same offsets from the bone ("put it exactly like the other one")
    -- 0.20 cm closer to the eye than the Breechshot's numbers (eye x -6.97 -> -7.17); the same for the TargetFinder
    SniperScope = setmetatable({ bone = "mod_sightscope", eye = { -7.17, 0.0, 4.06 }, front = { 12.0, 0.0, 4.06 } }, { __index = SIGHTS_BREECHSHOT.TargetFinder }),
}
SIGHTS_MAGNUM.TargetFinder = SIGHTS_MAGNUM.SniperScope
-- the aim mark: a small red chevron (an inverted V), its tip at the lens centre (the aim point), over the game's reticle, in the lens
-- plane (it moves with the lens: no parallax). Sizes are fractions of the lens' diameter.
local CHEVRON_WIDTH = 0.04
local CHEVRON_STROKE = 0.004
local CHEVRON_BRIGHTNESS = 3 -- (emissive: the widget material's tint above 1 glows)
local CHEVRON_FRONT = 0.2 -- cm in front of the lens
-- The HoloSight (no zoom). Its own reticle is drawn by the glass material for the flat game's aiming camera (it depends on
-- where the eye is, and in VR it is never there), so it does not match where the gun shoots: it is hidden (the mask texture of
-- the material's emissive lights, slot "HoloSight" of the weapon's GeometryCollection: the frame stays) and a reticle at
-- infinity is drawn instead: a ring, a dot and 4 ticks (red, emissive) in the world, far along the barrel's line (50 m, or where
-- the shot lands, minus 20 cm), facing the head and scaled so that its angular size stays constant. Shown only when the line
-- from the head to it passes through the holo window. The window (mesh space, cm): its centre is HOLO_WINDOW from the bone
-- mod_sightholo (25.04, 0, 15.72) -> (25.2, 0, 18.17) (found by sighting the hood's opening from two heights), radius 1.2.
HOLO_WINDOW = { off = { 0.16, 0.0, 2.45 }, radius = 1.2 }
-- The Locust holo (Hammerburst, LMG...: the glass is a tall rectangle in a frame): its own window, a rectangle (half width hw, half
-- height hh, cm) round a centre offset from the bone mod_sightholo.
-- Estimated from a screenshot (the arm and body meshes fill the view from behind the LMG: no plug discs); checked in the headset.
HOLO_WINDOW_LOCUST = { off = { 0.0, 0.0, 2.9 }, hw = 1.6, hh = 2.4 }
-- The Snub's holo (its glass sits 0.8 cm lower than the COG one on the same bone; rough, from a capture: reticle 0.64 cm above the glass centre):
HOLO_WINDOW_SNUB = { off = { 0.16, 0.0, 1.62 }, radius = 1.2 }
-- The Gnasher's holo (an arched hood, 2.1 x 2.3 cm opening; its glass centre is 1.17 cm above the COG one; measured from one capture, 1 mm inside the frame):
HOLO_WINDOW_GNASHER = { off = { 0.16, 0.0, 3.62 }, hw = 0.95, hh = 1.05 }
-- The Magnum's Locust holo (a tall narrow glass, 2.45 x 4.2 cm; its centre 1.5 cm above the LMG window's; from two captures, ~19 px/cm):
HOLO_WINDOW_MAGNUM = { off = { 0.0, 0.0, 4.4 }, hw = 1.1, hh = 2.0 }
local HOLO_BONE = "mod_sightholo"
local HOLO_MASK = "EmissiveLights.Section01.Mask"
local HOLO_CONTROLS = "Emissive.Section01.LightSourceAndFrame.Controls"
local BLACK = "Texture2D /Engine/EngineResources/Black.Black"
-- the Locust holo (Hammerburst...) draws a dark copy of its reticle from its lens texture L01.BaseColor: swapped for the COG one
-- (plain on that glass), put back with the rest
local HOLO_BASE = "L01.BaseColor"
-- The COG holo (every holo but the Locust one) gets the game's M_Invisible in its glass slot: plain see-through glass, the frame and hood
-- stay (other slots). SAFE USE (a SetMaterial that replaced the game's MID and then put it back crashed the game: the MID was
-- collected): the game's MID is never kept, only the slot number and the parent asset's name; the way back is SetMaterial(slot, the parent
-- ASSET) (a loaded asset, kept by aa_assets), and a weapon that is no longer in the hand is never touched.
local HOLO_INVISIBLE = "Material /Game/Fairlight/realization/Utility/Assets/Materials/M_Invisible.M_Invisible"
local HOLO_COG_PARENT = "MaterialInstanceConstant /Game/Fairlight/Weapons/COG/Scope/Materials/WPN_COG_HoloSight.WPN_COG_HoloSight"
-- (a slot the game left invisible after a script reload or a weapon switch is found by its material: the last M_Invisible slot of a weapon with a holo fitted;
-- its parent is not known then: the COG one, or the Snub's)
local HOLO_SNUB_PARENT = "MaterialInstanceConstant /Game/Fairlight/Weapons/COG/Snub/Materials/WPN_Snub_HoloSight.WPN_Snub_HoloSight"
local HOLO_PLAIN = "Texture2D /Game/Fairlight/Interface/Scopes/T_UI_Scopes_Cog_Marksman_01.T_UI_Scopes_Cog_Marksman_01"
local RET_MAX_CM = 5000 -- 50 m
local RET_COLOR = { 0.85, 0.04, 0.06 } -- (red; the game tone maps a thin line towards pink, so less blue than 0.85 0.1 0.2)
local RET_BRIGHT = 0.2 -- (emissive; a soft glow)
local RET_RING_DEG, RET_DOT_DEG, RET_TICK_DEG, RET_STROKE_DEG = 1.2, 0.08, 0.35, 0.05
local RET_SEGMENTS = 16

local function glass_path(k)
    local n = "WPN_COG_ScopeGlass_" .. k
    return "MaterialInstanceConstant /Game/Fairlight/Weapons/COG/Scope/Materials/" .. n .. "." .. n
end
local function locust_glass_path(k)
    local n = "WPN_Locust_ScopeGlass_" .. k
    return "MaterialInstanceConstant /Game/Fairlight/Weapons/Locust/Scope/Materials/" .. n .. "." .. n
end
for _, d in pairs(SIGHTS) do d.gpath = glass_path(d.glass) end
for _, d in pairs(SIGHTS_LOCUST) do d.gpath = locust_glass_path(d.glass_name) end
local function all_sights() -- (both tables, for the glass planes)
    local l = {}
    for _, d in pairs(SIGHTS) do l[#l + 1] = d end
    for _, d in pairs(SIGHTS_LOCUST) do if d.glass ~= "NONE" then l[#l + 1] = d end end -- ("NONE": no glass plane at all)
    return l
end
-- (aa_assets loads them with its prefetch after a level starts: asking for them earlier would cache a miss)
if eday_prefetch_add ~= nil then
    eday_prefetch_add(function()
        local l = {}
        for _, d in ipairs(all_sights()) do l[#l + 1] = d.gpath end
        return l
    end)
end
local GLASS_ROT = { 0, 0, 0 } -- (turns the glass plane about its normal if the reticle comes out turned)
local GLASS_FRACTION = 0.95 -- (measured: the reticle circle fills this much of the glass material's square)
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
            if mesh:find("/Engine/BasicShapes/") and (mn:find("Widget3DPassThrough") or mn:find("ScopeGlass")) then a:K2_DestroyActor() n = n + 1 end
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
        local all = { s.lens, s.line_h, s.line_v, s.cap, s.rt, s.chev[1], s.chev[2], s.holo.root, s.holo.kids[1] }
        for _, g in pairs(s.glass) do all[#all + 1] = g end
        for _, o in ipairs(all) do
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
    local line_mat = material(LINE_MAT, api:find_uobject(WHITE), 0)
    local w, len = RETICLE_WIDTH / 100, SCOPES.BP_Wpn_Longshot_C.radius * 2 / 100
    local line_h = mesh_actor(CUBE, line_mat, Vector3d.new(0.0005, len, w))
    local line_v = mesh_actor(CUBE, line_mat, Vector3d.new(0.0005, w, len))
    local glass = {} -- (the sights' reticles: planes made by glass_planes once the assets are loaded)
    local red = material(LINE_MAT, api:find_uobject(WHITE), 1)
    local rc = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    rc.R, rc.G, rc.B, rc.A = CHEVRON_BRIGHTNESS, 0, 0, 1
    red:SetVectorParameterValue(N("TintColorAndOpacity"), rc)
    local chev = {}
    for i = 1, 2 do
        chev[i] = mesh_actor(CUBE, red, Vector3d.new(0.0005, 0.0001, 0.0001))
        chev[i]:SetActorHiddenInGame(true)
    end
    -- the holo's reticle at infinity: a root actor (no picture; its scale is the distance) with the ring segments, the ticks and
    -- the dot attached to it, in units of radians: each frame only the root is moved, turned to the head and scaled
    local rmat = material(LINE_MAT, api:find_uobject(WHITE), 1)
    local rcol = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    rcol.R, rcol.G, rcol.B, rcol.A = RET_COLOR[1] * RET_BRIGHT, RET_COLOR[2] * RET_BRIGHT, RET_COLOR[3] * RET_BRIGHT, 1
    rmat:SetVectorParameterValue(N("TintColorAndOpacity"), rcol)
    local rroot = mesh_actor(CUBE, rmat, Vector3d.new(1, 1, 1))
    rroot:SetActorHiddenInGame(true)
    local rkids = {}
    local function rkid(mesh, x, y, yaw_deg, sx, sy, sz)
        local a = mesh_actor(mesh, rmat, Vector3d.new(1, 1, 1))
        ucall(a, "K2_AttachToActor", rroot, N("None"), 2, 2, 2, false)
        local c = a.StaticMeshComponent
        -- far away (50 m): the level's cull distance volume gave every small object a 5 m draw distance (CachedMaxDrawDistance 500):
        -- raised, and the mesh set again so that the render proxy takes it
        pcall(function() c.LDMaxDrawDistance = 1000000 c.CachedMaxDrawDistance = 1000000 end)
        c:SetStaticMesh(api:find_uobject(mesh))
        ucall(c, "K2_SetRelativeLocationAndRotation", Vector3d.new(x, y, 0), Vector3d.new(0, yaw_deg, 0), false, {}, false)
        ucall(c, "SetRelativeScale3D", Vector3d.new(sx, sy, sz))
        a:SetActorHiddenInGame(true)
        rkids[#rkids + 1] = a
    end
    local t = math.rad(RET_STROKE_DEG)
    local R = math.rad(RET_RING_DEG / 2)
    local seg = 2 * math.pi * R / RET_SEGMENTS * 1.1
    for i = 0, RET_SEGMENTS - 1 do
        local a = 2 * math.pi * i / RET_SEGMENTS
        rkid(CUBE, R * math.cos(a), R * math.sin(a), math.deg(a) + 90, seg / 100, t / 100, t / 100)
    end
    for i = 0, 3 do
        local a = math.pi / 2 * i
        rkid(CUBE, R * math.cos(a), R * math.sin(a), math.deg(a), math.rad(RET_TICK_DEG) / 100, t / 100, t / 100)
    end
    local dd = math.rad(RET_DOT_DEG)
    rkid(DISC, 0, 0, 0, dd / 100, dd / 100, t / 100 * 0.1)
    log("built")
    return { cap = cap, cc = cc, lens = lens, line_h = line_h, line_v = line_v, glass = glass, chev = chev, rt = rt, running = false,
             holo = { root = rroot, kids = rkids, shown = false },
             shown = true, radius = 0, ret = false } -- (radius 0: the first tick sizes the lens, glass and chevron)
end

local function show(s, on)
    if s.shown == on then return end
    s.shown = on
    s.lens:SetActorHiddenInGame(not on)
    if not on then
        s.line_h:SetActorHiddenInGame(true)
        s.line_v:SetActorHiddenInGame(true)
        for _, a in pairs(s.glass) do a:SetActorHiddenInGame(true) end
        s.chev[1]:SetActorHiddenInGame(true)
        s.chev[2]:SetActorHiddenInGame(true)
        s.ret = false
        s.running = false
    end
end

-- the glass planes (a sight's reticle: the game's own glass material over the lens, hidden until used), made as soon
-- as aa_assets has loaded the materials
local function glass_planes(s)
    for _, d in ipairs(all_sights()) do
        local mic = s.glass[d.glass] == nil and EDAY_ASSETS ~= nil and EDAY_ASSETS[d.gpath]
        if mic then
            pcall(function()
                local g = s.radius * 2 / GLASS_FRACTION / 100
                -- a disc (the cylinder's cap maps the material's square onto the circle): a square plane showed the material's
                -- dark vignette as a rectangle around the lens
                local p = mesh_actor(DISC, mic, Vector3d.new(g, g, 0.001))
                p:SetActorHiddenInGame(true)
                s.glass[d.glass] = p
                s.ret = false -- (apply the reticle choice again)
            end)
        end
    end
end

-- the reticle over the lens: nil = the Longshot's two lines, else the game's glass of that sight
local function set_reticle(s, key)
    if s.ret == key then return end
    s.ret = key
    s.line_h:SetActorHiddenInGame(key ~= nil)
    s.line_v:SetActorHiddenInGame(key ~= nil)
    s.chev[1]:SetActorHiddenInGame(key == nil)
    s.chev[2]:SetActorHiddenInGame(key == nil)
    for k, a in pairs(s.glass) do a:SetActorHiddenInGame(k ~= key) end
end

-- the sight the game fitted to the equipped weapon (not the Longshot, which has its own entry): its def, with eye / front
-- as points on the weapon mesh, from the sight's bone. Looked up at a weapon change and every CHECK_EVERY ticks only
-- (a supply cache can change the mod)
local sight_w, sight_n, sight_def = nil, 0, nil
-- a Locust weapon (the sight mesh is the Locust one): a material of the weapon's geometry whose parent is WPN_Locust_Scope
local function weapon_has_locust_scope(w)
    local ok, r = pcall(function()
        local gc = w.GeometryCollection
        for i = 0, gc:GetNumMaterials() - 1 do
            local m = gc:GetMaterial(i)
            local par = m and m.Parent
            if par ~= nil and par:get_fname():to_string() == "WPN_Locust_Scope" then return true end
        end
        return false
    end)
    return ok and r
end
local function fitted_sight(w)
    local ok, def = pcall(function()
        local am = w.WeaponModsComponent.AppliedMods
        for i = 1, #am do
            local n = am[i]:get_fname():to_string()
            for key, d in pairs(SIGHTS) do
                if n:sub(-#key) == key then
                    if SIGHTS_LOCUST[key] ~= nil and weapon_has_locust_scope(w) then d = SIGHTS_LOCUST[key] end
                    local wn = w:get_fname():to_string()
                    if SIGHTS_BREECHSHOT[key] ~= nil and wn:find("Breechshot") then d = SIGHTS_BREECHSHOT[key] end
                    if SIGHTS_MAGNUM[key] ~= nil and wn:find("Magnum") then d = SIGHTS_MAGNUM[key] end
                    local b = ucall(w.RootComponent, "GetSocketTransform", N(d.bone), 2).Translation
                    local function at(o) return { b.X + o[1], b.Y + o[2], b.Z + o[3] } end
                    return { eye = at(d.eye), front = at(d.front), radius = d.radius, fov = d.fov, glass = d.glass, sight = key }
                end
            end
        end
    end)
    return ok and def or nil
end

-- the holo fitted to the equipped weapon: where its window is (mesh space), looked up with the sight (see scope_tick)
local holo_info = nil
local function fitted_holo(w)
    local ok, info = pcall(function()
        local am = w.WeaponModsComponent.AppliedMods
        for i = 1, #am do
            if am[i]:get_fname():to_string():sub(-9) == "HoloSight" then
                local b = ucall(w.RootComponent, "GetSocketTransform", N(HOLO_BONE), 2).Translation
                local wn = w:get_fname():to_string()
                local win = wn:find("Snub") and HOLO_WINDOW_SNUB or wn:find("Gnasher") and HOLO_WINDOW_GNASHER or HOLO_WINDOW
                local locust = false
                local gc = w.GeometryCollection
                for k = 0, gc:GetNumMaterials() - 1 do
                    local m = gc:GetMaterial(k)
                    local par = m and m.Parent
                    if par ~= nil and par:get_fname():to_string() == "WPN_Locust_HoloSight" then win = HOLO_WINDOW_LOCUST locust = true break end
                end
                if locust and wn:find("Magnum") then win = HOLO_WINDOW_MAGNUM end
                return { cx = b.X + win.off[1], cy = b.Y + win.off[2], cz = b.Z + win.off[3], hw = win.hw, hh = win.hh, locust = locust, front = locust or win == HOLO_WINDOW_SNUB } -- (front: drawn on the eye side of the glass - the Snub has a dark panel behind its glass)
            end
        end
    end)
    return ok and info or nil
end

-- the game's own reticle on the holo glass (the cross, its dots and the glow): every reticle input of the holo material is blanked and
-- put back later: the emissive lights' mask texture swapped for a black one and the light controls vector zeroed (the mask alone let the
-- cross and its dotted glow come back after a weapon change). The hood and frame are geometry and stay. Looked up again at every
-- check and at a weapon change: the game may make a new material or set the parameters again.
local holo_g = nil -- { w = weapon name, mid = material, orig = texture, ctl = {r,g,b,a} of the light controls, on = bool }
local holo_ctl_n = 0
local function holo_find(w)
    local gc = w.GeometryCollection
    for i = 0, gc:GetNumMaterials() - 1 do
        local m = gc:GetMaterial(i)
        local okp, par = pcall(function() return m.Parent end)
        if not okp then par = nil end
        if par == nil and m ~= nil and m:get_fname():to_string():find("HoloSight") then
            -- (the game put a plain material asset there, e.g. WEAP_HoloSightsBase after a mod was fitted: hidden the same way, put back as it is)
            return { inv = true, slot = i, par = m:get_full_name() }
        end
        if par ~= nil and par:get_fname():to_string():find("HoloSight") then
            local g = { mid = m }
            if par:get_fname():to_string() ~= "WPN_Locust_HoloSight" then return { inv = true, slot = i, par = par:get_full_name() } end
            local tp = par.TextureParameterValues
            for j = 1, #tp do
                if tp[j].ParameterInfo.Name:to_string() == HOLO_MASK then g.orig = tp[j].ParameterValue end
                if tp[j].ParameterInfo.Name:to_string() == HOLO_BASE then g.base = tp[j].ParameterValue end
            end
            local vp = par.VectorParameterValues
            for j = 1, #vp do
                if vp[j].ParameterInfo.Name:to_string() == HOLO_CONTROLS then
                    local v = vp[j].ParameterValue
                    g.ctl = { v.R, v.G, v.B, v.A }
                end
            end
            return g
        end
    end
end
local function holo_put(mid, mask, ctl, base)
    mid:SetTextureParameterValue(N(HOLO_MASK), mask)
    if base ~= nil then mid:SetTextureParameterValue(N(HOLO_BASE), base) end
    local c = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
    c.R, c.G, c.B, c.A = ctl[1], ctl[2], ctl[3], ctl[4]
    mid:SetVectorParameterValue(N(HOLO_CONTROLS), c)
end
-- (GetMaterial may return nil; the slot may hold M_Invisible itself or a MID of it: both are "ours")
local function mat_name(gc, k)
    local m = gc:GetMaterial(k)
    return m and m:get_full_name() or ""
end
local function is_inv(name) return name:find("M_Invisible", 1, true) ~= nil end
local holo_miss = nil -- the weapon name for which no holo glass slot was found at the last check (not searched again until CHECK_EVERY)
local function holo_inv_glass(w, wn, on)
    local gc = w ~= nil and w.GeometryCollection or nil
    local inv = eday_asset(HOLO_INVISIBLE)
    if not on then
        -- back to the game's look: only on the weapon that was hidden and is still in the hand, and only if the slot still holds ours
        if gc ~= nil and holo_g.w == wn and is_inv(mat_name(gc, holo_g.slot)) then
            local par = eday_asset(holo_g.par)
            if par ~= nil then gc:SetMaterial(holo_g.slot, par) log("holo: the game's glass restored") end
        end
        holo_g = nil
        return
    end
    if inv == nil then return end
    if holo_g ~= nil and not holo_g.inv then holo_g = nil end -- (another weapon's parameter state: that weapon is never touched)
    holo_ctl_n = holo_ctl_n + 1
    local g = holo_g
    if g ~= nil and g.w == wn and g.on and holo_ctl_n < CHECK_EVERY then return end
    if holo_miss == wn and holo_ctl_n < CHECK_EVERY then return end -- (nothing found a moment ago: no rescan every frame)
    holo_ctl_n = 0
    if g ~= nil and g.w == wn and g.on and is_inv(mat_name(gc, g.slot)) then return end -- (still hidden)
    if g ~= nil and g.w == wn and g.on then log("holo: the game's glass came back, hiding it again") end
    local f = holo_find(w)
    if f == nil then
        for k = gc:GetNumMaterials() - 1, 0, -1 do
            if is_inv(mat_name(gc, k)) then
                f = { inv = true, slot = k, par = wn:find("Snub") and HOLO_SNUB_PARENT or HOLO_COG_PARENT }
                break
            end
        end
    end
    if f == nil or not f.inv then holo_miss = wn return end
    holo_miss = nil
    gc:SetMaterial(f.slot, inv)
    f.w, f.on = wn, true
    holo_g = f
    log("holo: the game's glass hidden (slot " .. f.slot .. ")")
end
local function holo_glass(w, wn, on)
    pcall(function()
        if rawget(_G, "HOLO_PAUSE") then return end -- (debug: leave the glass slot alone)
        if on and not holo_info.locust or not on and holo_g ~= nil and holo_g.inv then return holo_inv_glass(w, wn, on) end
        -- the game's MID is never kept across frames: it is found again on the weapon in hand at each check and written at once
        -- (a MID of a weapon that has left the hand may be gone: an access violation no pcall catches); a weapon that left the hand is never touched
        if on then
            holo_ctl_n = holo_ctl_n + 1
            if holo_g ~= nil and holo_g.w ~= wn then holo_g = nil end
            if holo_g ~= nil and holo_g.inv then holo_g = nil end
            if holo_g == nil or holo_ctl_n >= CHECK_EVERY then
                if holo_g == nil and holo_miss == wn and holo_ctl_n < CHECK_EVERY then return end
                holo_ctl_n = 0
                local g = holo_find(w)
                if g == nil or g.mid == nil or g.mid:get_full_name() == "" then holo_miss = wn return end
                holo_miss = nil
                if holo_g == nil then
                    g.w, g.on, g.mid = wn, false, nil
                    holo_g = g
                else
                    -- (what its parameters are now: has the game put the reticle back?)
                    local okm, t = pcall(function() return g.mid:K2_GetTextureParameterValue(N(HOLO_MASK)) end)
                    local okc, v = pcall(function() return g.mid:K2_GetVectorParameterValue(N(HOLO_CONTROLS)) end)
                    if holo_g.on and ((okm and t and t:get_fname():to_string() ~= "Black") or (okc and v and (v.R > 0 or v.G > 0 or v.B > 0))) then
                        holo_g.on = false
                        log("holo: the game's reticle came back, hiding it again")
                    end
                end
                if holo_g.orig ~= nil and holo_g.ctl ~= nil and not holo_g.on then
                    holo_put(g.mid, api:find_uobject(BLACK), { 0, 0, 0, 0 }, holo_g.base and eday_asset(HOLO_PLAIN))
                    holo_g.on = true
                    log("holo: the game's reticle hidden")
                end
            end
        elseif holo_g ~= nil and holo_g.on then
            if w ~= nil and holo_g.w == wn then
                local g = holo_find(w)
                if g ~= nil and g.mid ~= nil and g.mid:get_full_name() ~= "" and holo_g.orig ~= nil and holo_g.ctl ~= nil then
                    holo_put(g.mid, holo_g.orig, holo_g.ctl, holo_g.base)
                    log("holo: the game's reticle restored")
                end
            end
            holo_g = nil
        end
    end)
end

local function ret_show(rt, on)
    if rt.shown == on then return end
    rt.shown = on
    rt.part_on = {}
    for _, a in ipairs(rt.kids) do a:SetActorHiddenInGame(not on) end
end

local eye_left = nil -- the left eye's position (view 0), for the head's centre
-- the reticle at infinity, once per frame: where, whether it is seen through the window, and its size
local function holo_reticle(s, w, eye)
    local rt = s.holo
    local ok_m, mz = pcall(eday_muzzle_pos, w.RootComponent)
    local sp = SHOT_POINT
    if not ok_m or mz == nil or sp == nil or holo_info == nil then ret_show(rt, false) return end
    local dx, dy, dz = sp.x - mz.x, sp.y - mz.y, sp.z - mz.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist < 1 then ret_show(rt, false) return end
    -- P: where the shot lands (the trace along the barrel from the muzzle), or 50 m along that line
    local D = rawget(_G, "HOLO_D") or math.min(RET_MAX_CM, dist) -- (HOLO_D: debug, a fixed distance for measuring in a closed street)
    local pt = { x = mz.x + dx / dist * D, y = mz.y + dy / dist * D, z = mz.z + dz / dist * D }
    local h = eye
    if eye_left ~= nil then h = { x = (eye.x + eye_left.x) / 2, y = (eye.y + eye_left.y) / 2, z = (eye.z + eye_left.z) / 2 } end
    -- through the window? the line from an eye to P, cut by the window's plane x = cx of the weapon mesh: seen if either eye's
    -- line passes inside the window (both eyes then get the reticle: it is in the world, there is no double image)
    local xf = ucall(w.RootComponent, "K2_GetComponentToWorld")
    local qm = ucall(kmath, "InverseTransformLocation", xf, Vector3d.new(pt.x, pt.y, pt.z))
    local function through(e)
        local em = ucall(kmath, "InverseTransformLocation", xf, Vector3d.new(e.x, e.y, e.z))
        if qm.x - em.x < 1 or em.x >= holo_info.cx then return false, 99, 99 end
        local k = (holo_info.cx - em.x) / (qm.x - em.x)
        local oy, oz = em.y + k * (qm.y - em.y) - holo_info.cy, em.z + k * (qm.z - em.z) - holo_info.cz
        -- seen while any part of the reticle is on the glass: the window grown by the reticle's outer half-size (ring + tick) at the
        -- glass' distance from that eye; the parts off the glass are hidden one by one below (only the half on the glass shows)
        local m = (holo_info.cx - em.x) * math.tan(math.rad(RET_RING_DEG / 2 + RET_TICK_DEG / 2))
        if holo_info.hw ~= nil then return math.abs(oy) <= holo_info.hw + m and math.abs(oz) <= holo_info.hh + m, oy, oz end -- (a rectangle)
        return oy * oy + oz * oz <= (HOLO_WINDOW.radius + m) ^ 2, oy, oz
    end
    -- the AIMING eye: the one whose line to P passes through the window, the one nearest its centre (trial: the reticle is drawn
    -- ON THAT EYE'S LINE at the glass, so the other eye sees it on the glass / hidden by the hood, never floating beside the weapon)
    local seen, oy, oz, ae = false, 99, 99, nil
    for _, e in ipairs(eye_left ~= nil and { eye, eye_left } or { eye }) do
        local sn, y1, z1 = through(e)
        if holo_info.hw == nil then y1, z1 = y1 / HOLO_WINDOW.radius, z1 / HOLO_WINDOW.radius else y1, z1 = y1 / holo_info.hw, z1 / holo_info.hh end
        local d2 = y1 * y1 + z1 * z1
        if (sn and not seen) or (sn == seen and d2 < oy * oy + oz * oz) then seen, oy, oz, ae = sn, y1, z1, e end
    end
    if not seen then ae = eye end
    if rawget(_G, "HOLO_FORCE") then seen = true end -- (debug)
    if rawget(_G, "HOLO_DEBUG") then HOLO_DBG = { seen = seen, p = pt, h = h, d = D, dist = dist, wy = oy, wz = oz } end -- (debug, off unless set)
    if not seen then ret_show(rt, false) return end
    -- the reticle sits on the aiming EYE's ray to P, on the glass (see below): its
    -- direction from the eye still points at P and nothing is between the eye and it, so it is never hidden by depth
    h = ae
    local hp = math.sqrt((pt.x - h.x) ^ 2 + (pt.y - h.y) ^ 2 + (pt.z - h.z) ^ 2)
    local ux, uy, uz = (pt.x - h.x) / hp, (pt.y - h.y) / hp, (pt.z - h.z) / hp
    -- the point where that line crosses the glass plane (mesh x = cx; the Locust holo keeps its glass, so 3 mm on the eye side of it, the
    -- others 2 mm deeper in the hood), found as a distance along the line: no occlusion traces (nothing is between the eye and the glass)
    local em = ucall(kmath, "InverseTransformLocation", xf, Vector3d.new(h.x, h.y, h.z))
    local tx = holo_info.cx + (holo_info.front and -0.3 or 0.2)
    local dr = hp
    if qm.x - em.x > 1 then dr = hp * (tx - em.x) / (qm.x - em.x) end
    local q = { x = h.x + ux * dr, y = h.y + uy * dr, z = h.z + uz * dr }
    if HOLO_DBG ~= nil and rawget(_G, "HOLO_DEBUG") then HOLO_DBG.q, HOLO_DBG.dr = q, dr end
    local hq = math.sqrt((h.x - q.x) ^ 2 + (h.y - q.y) ^ 2 + (h.z - q.z) ^ 2)
    local rot = ucall(kmath, "MakeRotFromZX", Vector3d.new((h.x - q.x) / hq, (h.y - q.y) / hq, (h.z - q.z) / hq), Vector3d.new(0, 0, 1))
    ucall(rt.root, "K2_SetActorLocationAndRotation", Vector3d.new(q.x, q.y, q.z), rot, false, {}, true)
    ucall(rt.root, "SetActorScale3D", Vector3d.new(hq, hq, hq))
    ret_show(rt, true)
    -- clip to the glass: each part (ring segment, tick, dot) is shown only while it lies inside the window (it sits on the glass plane)
    rt.part_on = rt.part_on or {}
    for i, a in ipairs(rt.kids) do
        local pm = ucall(kmath, "InverseTransformLocation", xf, ucall(a, "K2_GetActorLocation"))
        local py, pz = pm.Y - holo_info.cy, pm.Z - holo_info.cz
        local inside
        if holo_info.hw ~= nil then inside = math.abs(py) <= holo_info.hw and math.abs(pz) <= holo_info.hh
        else inside = py * py + pz * pz <= HOLO_WINDOW.radius ^ 2 end
        if rt.part_on[i] ~= inside then rt.part_on[i] = inside a:SetActorHiddenInGame(not inside) end
    end
end

local function scope_tick(eye, view_rot)
    SCOPE_EYE = eye -- (debug: tools/eye_local.lua)
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return end
    local inv = ucall(pawn, "GetComponentByClass", inv_c)
    local w = inv and ucall(inv, "GetEquippedInventoryItem")
    local def = w and SCOPES[w:get_class():get_fname():to_string()]
    if def == nil and w then
        local wn = w:get_fname():to_string()
        sight_n = sight_n + 1
        if wn ~= sight_w or sight_n >= CHECK_EVERY then
            sight_w, sight_n = wn, 0
            local was = sight_def and sight_def.sight
            sight_def = fitted_sight(w)
            if (sight_def and sight_def.sight) ~= was then log("sight: " .. tostring(sight_def and sight_def.sight)) end
            local had_holo = holo_info ~= nil
            holo_info = sight_def == nil and fitted_holo(w) or nil
            if (holo_info ~= nil) ~= had_holo then log("holo: " .. tostring(holo_info ~= nil)) end
        end
        def = sight_def
    elseif w == nil then
        sight_w, sight_def, holo_info = nil, nil, nil
    else
        holo_info = nil -- (the Longshot)
    end
    if holo_g ~= nil or holo_info ~= nil then
        holo_glass(w, w and w:get_fname():to_string(), w ~= nil and def == nil and holo_info ~= nil)
    end
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
    -- (also when the weapon is on the back over the right shoulder - RIGHT_FREE: still equipped, only hidden - the lens
    -- had stayed in the free hand)
    if def == nil and holo_info ~= nil and not RIGHT_FREE then
        holo_reticle(parts, w, eye)
    else
        ret_show(parts.holo, false)
    end
    if def == nil or RIGHT_FREE then
        show(parts, false)
        return
    end
    local s = parts
    glass_planes(s)
    show(s, true)
    set_reticle(s, def.glass)
    s.cc.FOVAngle = def.fov
    if s.radius ~= def.radius then
        s.radius = def.radius
        s.lens:SetActorScale3D(Vector3d.new(def.radius / 50, def.radius / 50, 0.001))
        local g = def.radius * 2 / GLASS_FRACTION / 100
        for _, a in pairs(s.glass) do a:SetActorScale3D(Vector3d.new(g, g, 0.001)) end
        local d = def.radius * 2
        for i = 1, 2 do s.chev[i]:SetActorScale3D(Vector3d.new(0.0005, CHEVRON_WIDTH * d * 0.7071 / 100, CHEVRON_STROKE * d / 100)) end
    end
    -- onto the scope as the weapon is shown now
    local m = w.RootComponent
    local xf = ucall(m, "K2_GetComponentToWorld")
    local rot = ucall(m, "K2_GetComponentRotation")
    local e = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.eye[1], def.eye[2], def.eye[3]))
    local disc_rot = ucall(kmath, "ComposeRotators", Vector3d.new(90, 0, 0), rot) -- the disc's face back along the barrel
    ucall(s.lens, "K2_SetActorLocationAndRotation", e, disc_rot, false, {}, true)
    local r = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.eye[1] - 0.1, def.eye[2], def.eye[3]))
    if def.glass == nil then
        ucall(s.line_h, "K2_SetActorLocationAndRotation", r, rot, false, {}, true)
        ucall(s.line_v, "K2_SetActorLocationAndRotation", r, rot, false, {}, true)
    else
        local gl = s.glass[def.glass]
        if gl ~= nil then
            local gp = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.eye[1] - 0.15, def.eye[2], def.eye[3]))
            ucall(gl, "K2_SetActorLocationAndRotation", gp, ucall(kmath, "ComposeRotators", Vector3d.new(GLASS_ROT[1], GLASS_ROT[2], GLASS_ROT[3]), disc_rot), false, {}, true)
        end
        -- the chevron: two strokes from the tip (the lens centre) 45 deg down to the left and to the right; each is a thin box
        -- along the weapon's y axis turned by +/-45 deg about the barrel axis, its centre half way along the stroke
        local h = CHEVRON_WIDTH * def.radius * 2 / 4
        for i = 1, 2 do
            local sgn = (i == 1) and -1 or 1
            local cp = ucall(kmath, "TransformLocation", xf, Vector3d.new(def.eye[1] - CHEVRON_FRONT, def.eye[2] + sgn * h, def.eye[3] - h))
            local cr = ucall(kmath, "ComposeRotators", Vector3d.new(0, 0, sgn * 45), rot)
            ucall(s.chev[i], "K2_SetActorLocationAndRotation", cp, cr, false, {}, true)
        end
    end
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
    SCOPE_DBG = { near = near, in_view = in_view, eye_dist = math.sqrt(d2), eye = eye, lens = e } -- (debug)
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
    SCOPE_CAPTURES = (rawget(_G, "SCOPE_CAPTURES") or 0) + 1 -- (debug: counted in tests)
    pcall(function() parts.cc:CaptureScene() end)
end)

-- after weapon.lua placed the weapon (its view-1 callback): scope.lua is loaded before weapon.lua, so this is
-- registered on the first tick, after it
local registered = false
uevr.sdk.callbacks.on_pre_engine_tick(function()
    if registered then return end
    registered = true
    uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
        if view_index == 0 then eye_left = { x = position.x, y = position.y, z = position.z } return end
        if view_index ~= 1 then return end
        if CINEMATIC then
            if parts ~= nil then pcall(show, parts, false) pcall(ret_show, parts.holo, false) end
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
