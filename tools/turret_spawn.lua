-- (dev) Spawns a mounted turret (BP_TurretV2_<kind>) on the ground TSPAWN_FWD cm in front of Marcus, facing where he
-- faces (he stands behind it). _G.TSPAWN = "Vulkan" | "Troika" | "HeavyBoomshot". tools/dbg.sh -f tools/turret_spawn.lua
-- Result in _G.TURRET; returns its components.
local api = uevr.api
local vr = uevr.params.vr
local kind = rawget(_G, "TSPAWN") or "Vulkan"
local path = "/Game/Fairlight/Gameplay/BlueprintClasses/Turret/BP_TurretV2_" .. kind
local name = path:match("([^/]+)$")
local full = "BlueprintGeneratedClass " .. path .. "." .. name .. "_C"
local cls = api:find_uobject(full)
if cls == nil then
    local ks = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
    vr.set_mod_value("VR_LoadAssetRoot", "0")
    local sp = ks:MakeSoftObjectPath(path .. "." .. name .. "_C")
    vr.set_mod_value("VR_LoadAsset", string.format("%x %x", sp:read_qword(0), sp:read_qword(8)))
    cls = api:find_uobject(full)
end
if cls == nil then return "class not found: " .. full end

local pawn = api:get_local_pawn(0)
local gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local ks = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
local me = pawn:K2_GetActorLocation()
local rot = pawn:K2_GetActorRotation()
local yaw = math.rad(rot.Yaw or rot.y)
local f = { x = math.cos(yaw), y = math.sin(yaw) }
local d = rawget(_G, "TSPAWN_FWD") or 150
local p = { x = me.X + f.x * d, y = me.Y + f.y * d, z = me.Z }
-- the ground under it
local hit = StructObject.new(api:find_uobject("ScriptStruct /Script/Engine.HitResult"))
local col = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.LinearColor"))
local ok_t, got = pcall(function()
    return ks:LineTraceSingle(pawn, Vector3d.new(p.x, p.y, p.z + 50), Vector3d.new(p.x, p.y, p.z - 300), 0, false, { pawn }, 0, hit, true, col, col, 0)
end)
if ok_t and got then p.z = hit.ImpactPoint.Z or hit.ImpactPoint.z end

local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
xf.Translation = Vector3d.new(p.x, p.y, p.z)
local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
q.X, q.Y, q.Z, q.W = 0, 0, math.sin(yaw / 2), math.cos(yaw / 2)
xf.Rotation = q
xf.Scale3D = Vector3d.new(1, 1, 1)
local a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, xf, 1, nil, 0)
a = gs:FinishSpawningActor(a, xf, 0)
if a == nil then return "spawn failed" end
rawset(_G, "TURRET", a)

local out = { "spawned " .. a:get_fname():to_string() .. string.format(" at %.0f %.0f %.0f (ground %s)", p.x, p.y, p.z, tostring(ok_t and got)) }
local comps = {}
pcall(function() a:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine.ActorComponent"), comps) end)
if #comps == 0 then pcall(function() comps = a:K2_GetComponentsByClass(api:find_uobject("Class /Script/Engine.ActorComponent")) end) end
for _, c in ipairs(comps or {}) do
    out[#out + 1] = "  " .. c:get_class():get_fname():to_string() .. " " .. c:get_fname():to_string()
end
local actors = {}
pcall(function() a:GetAttachedActors(actors, true, true) end)
for _, c in ipairs(actors) do out[#out + 1] = "  attached actor " .. c:get_class():get_fname():to_string() .. " " .. c:get_fname():to_string() end
return table.concat(out, "\n")
