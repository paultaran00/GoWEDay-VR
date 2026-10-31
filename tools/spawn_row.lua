-- _G.ROW_N (4) Drones without AI, in an arc _G.ROW_DIST cm (250) along the headset's view; needs _G.VIEW_YAW/VIEW_POS
local api = uevr.api
local p = api:get_local_pawn(0)
local gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local cls = api:find_uobject(_G.ROW_CLASS or "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Characters/Locust/Drone/BP_Pawn_Drone.BP_Pawn_Drone_C")
local me = p:K2_GetActorLocation()
local vp = _G.VIEW_POS
local n = _G.ROW_N or 4
local d = _G.ROW_DIST or 250
_G.SPAWNED = _G.SPAWNED or {}
for i = 1, n do
  local off = (i - (n + 1) / 2) * 28
  local yaw = math.rad(_G.VIEW_YAW + off)
  local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
  xf.Translation = Vector3d.new(vp.x + math.cos(yaw) * d, vp.y + math.sin(yaw) * d, me.z + 10)
  local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
  local h = (math.deg(yaw) + 180) * math.pi / 360
  q.X, q.Y, q.Z, q.W = 0, 0, math.sin(h), math.cos(h)
  xf.Rotation = q
  xf.Scale3D = Vector3d.new(1, 1, 1)
  local a = gs:BeginDeferredActorSpawnFromClass(p, cls, xf, 1, nil, 0)
  if a then a = gs:FinishSpawningActor(a, xf, 0) table.insert(_G.SPAWNED, a) end
end
print("spawned", n)
