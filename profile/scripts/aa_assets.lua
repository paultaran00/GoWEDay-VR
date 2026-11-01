-- The mod's assets (blood, glass cracks and shatter, magazines, ejected rounds, laser material...) loaded in every
-- chapter, all at once ASSET_PREFETCH_DELAY s after a pawn appears (the end of the loading screen), one per frame - not
-- on the first glass hit / bolt pull (a lookup of a missing asset scans every object: ~430 ms freeze).
-- A missing asset is loaded from the game files by our UEVR patch ("VR_LoadAsset": KismetSystemLibrary
-- LoadAsset_Blocking - its soft reference parameter cannot be passed from Lua). What we load ourselves nothing of the
-- game holds, so the garbage collector would destroy it (seen: the glass shatter came back "None.None"): each one gets
-- a holder in the world - an inactive particle component, or a hidden mesh actor far below the player.
-- eday_asset(full_name) -> object or nil (cached per pawn). Scripts add their paths with eday_prefetch_add(fn), fn()
-- returning a list of full names.
local api = uevr.api
local vr = uevr.params.vr
local function log(m) pcall(function() uevr.params.functions.log_info("[assets] " .. tostring(m)) end) end

ASSET_LOADER = true          -- load missing assets from disk (UEVR VR_LoadAsset)
ASSET_HOLDERS = true         -- keep what we loaded alive with holders
ASSET_ROOT = false           -- (UEVR VR_LoadAssetRoot: the root set flag on loads - off)
ASSET_PREFETCH_DELAY = 3.0   -- s after a new pawn
EDAY_ASSETS, EDAY_HOLDERS = {}, {}
local providers = {}
function eday_prefetch_add(fn) table.insert(providers, fn) end

local ks, nfl, statics, sma_c = nil, nil, nil, nil
local cube = "StaticMesh /Engine/BasicShapes/Cube.Cube"

local function hold(full, obj)
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return end
    local l = pawn:K2_GetActorLocation()
    local at = Vector3d.new(l.x, l.y, l.z - 5000)
    if full:find("^NiagaraSystem ") then
        nfl = nfl or api:find_uobject("Class /Script/Niagara.NiagaraFunctionLibrary"):get_class_default_object()
        EDAY_HOLDERS[full] = { comp = nfl:SpawnSystemAtLocation(pawn, obj, at, Vector3d.new(0, 0, 0), Vector3d.new(1, 1, 1), false, false, 0, true) }
    elseif full:find("^StaticMesh ") or full:find("Material") then
        statics = statics or api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
        sma_c = sma_c or api:find_uobject("Class /Script/Engine.StaticMeshActor")
        local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
        xf.Translation = at
        local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
        q.W = 1
        xf.Rotation = q
        xf.Scale3D = Vector3d.new(0.01, 0.01, 0.01)
        local a = statics:FinishSpawningActor(statics:BeginDeferredActorSpawnFromClass(pawn, sma_c, xf, 1, nil, 0), xf, 0)
        local c = a.StaticMeshComponent
        c:SetMobility(2)
        pcall(function() c:SetCollisionEnabled(0) end)
        if full:find("^StaticMesh ") then c:SetStaticMesh(obj) else c:SetStaticMesh(api:find_uobject(cube)) c:SetMaterial(0, obj) end
        a:SetActorHiddenInGame(true)
        EDAY_HOLDERS[full] = { actor = a }
    end
end

function eday_asset(full)
    local c = EDAY_ASSETS[full]
    if c ~= nil and c and full:find("^AkAudioEvent ") then
        -- (Wwise events have no holder: one that was collected is loaded again)
        local ok, valid = pcall(function() ks = ks or api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object() return ks:IsValid(c) end)
        if ok and not valid then EDAY_ASSETS[full], c = nil, nil end
    end
    if c ~= nil then return c or nil end
    local obj, result = nil, ""
    -- classes are only looked up (they are the game's own code; never loaded by us)
    if ASSET_LOADER and not full:find("Class ") then
        pcall(function()
            ks = ks or api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
            -- Wwise events get the root flag: nothing holds them (no holder type) and the collector freed them, so only
            -- the sounds the game had loaded itself played.
            vr.set_mod_value("VR_LoadAssetRoot", (ASSET_ROOT or full:find("^AkAudioEvent ")) and "1" or "0")
            local sp = ks:MakeSoftObjectPath((full:gsub("^%S+%s+", "")))
            vr.set_mod_value("VR_LoadAsset", string.format("%x %x", sp:read_qword(0), sp:read_qword(8)))
            result = vr:get_mod_value("VR_LoadAssetResult") or ""
        end)
    end
    local loaded = tonumber(result, 16)
    if loaded == nil or loaded ~= 0 then pcall(function() obj = api:find_uobject(full) end) end
    if obj == nil then
        log("missing: " .. full .. (loaded == nil and "" or " (not in the game files)"))
    elseif ASSET_HOLDERS and loaded ~= nil then
        local ok, err = pcall(hold, full, obj)
        if not ok then log("holder failed: " .. full .. ": " .. tostring(err)) end
    end
    EDAY_ASSETS[full] = obj or false
    return obj
end

-- a new pawn or none (another chapter, the menu, a checkpoint): everything is looked up again. The old holders are
-- only forgotten, never destroyed from here: after a trip through the menu their world is gone and touching them hung
-- the next mission's loading screen (they go with their world; a checkpoint in the same world leaves a few, harmless).
function eday_assets_reset()
    EDAY_ASSETS, EDAY_HOLDERS = {}, {}
end

-- Another pawn in the SAME world (a turret mount, a cutscene, a checkpoint): the holders are all still there and in this
-- world - kept, with what they hold (only the "not found" entries are tried again). Spawning a new set on every pawn
-- change left ~28 actors per mount that nothing ever removed. A holder missing or in another world (a trip through the
-- menu): everything is forgotten as above.
local function world_of(o) -- (the World among its outers)
    for _ = 1, 6 do
        if o:get_class():get_fname():to_string() == "World" then return o:get_address() end
        o = o:get_outer()
    end
end
local function holders_kept(pawn)
    local ok, yes = pcall(function()
        ks = ks or api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
        local w, n = world_of(pawn), 0
        for _, h in pairs(EDAY_HOLDERS) do
            local o = h.actor or h.comp
            if o == nil or not ks:IsValid(o) or world_of(o) ~= w then return false end
            n = n + 1
        end
        return n > 0
    end)
    if ok and yes then
        for k, v in pairs(EDAY_ASSETS) do if not v then EDAY_ASSETS[k] = nil end end
    end
    return ok and yes
end

local prefetch_pawn, prefetch_at, queue = nil, 0, {}
uevr.sdk.callbacks.on_pre_engine_tick(function()
    local pawn = api:get_local_pawn(0)
    if pawn ~= prefetch_pawn then
        prefetch_pawn, prefetch_at, queue = pawn, os.clock() + ASSET_PREFETCH_DELAY, {}
        if pawn == nil or not holders_kept(pawn) then eday_assets_reset() end -- (also with no pawn: the cached objects may go with the old world)
    end
    if pawn == nil or os.clock() < prefetch_at then return end
    if queue.built == nil then
        queue = { built = true, n = 0, t = os.clock() }
        local seen = {}
        for _, fn in ipairs(providers) do
            local ok, list = pcall(fn, pawn)
            if ok and list then for _, p in ipairs(list) do if not seen[p] then seen[p] = true table.insert(queue, p) end end end
        end
        log(#queue .. " assets to look up")
    end
    local path = table.remove(queue, 1)
    if path ~= nil then
        pcall(eday_asset, path)
        queue.n = queue.n + 1
        if #queue == 0 then
            local ok = 0
            for _, v in pairs(EDAY_ASSETS) do if v then ok = ok + 1 end end
            log(string.format("ready: %d of %d found, in %.1f s", ok, queue.n, os.clock() - queue.t))
        end
    end
end)
