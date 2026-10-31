-- Spawns test enemies even where their class is not loaded (a hub / mission start): loads the class through the UEVR
-- patch VR_LoadAsset and spawns IN THE SAME COMMAND (a class nothing holds is garbage-collected before a later spawn:
-- seen 2026-10-20). Inert (no controller = no AI), in rows along the headset view.
-- needs _G.VIEW_POS / VIEW_YAW (set by a post-stereo callback); optional _G.ROWS_CLASS (full name), _G.ROWS
-- ({ {dist cm, yaw offset deg}, ... }), _G.ROWS_N (per row, 4). Run: tools/dbg.sh -f tools/spawn_rows_load.lua
local api = uevr.api
local vr = uevr.params.vr
local full = rawget(_G, "ROWS_CLASS") or "BlueprintGeneratedClass /Game/Fairlight/Gameplay/BlueprintClasses/Characters/Locust/Drone/BP_Pawn_Drone.BP_Pawn_Drone_C"
local rows = rawget(_G, "ROWS") or { { 250, 0 }, { 330, 7 }, { 410, -7 }, { 490, 4 } }
local per = rawget(_G, "ROWS_N") or 4
local cls = api:find_uobject(full)
if cls == nil then
  local ks = api:find_uobject("Class /Script/Engine.KismetSystemLibrary"):get_class_default_object()
  vr.set_mod_value("VR_LoadAssetRoot", "0")
  local sp = ks:MakeSoftObjectPath((full:gsub("^%S+%s+", "")))
  vr.set_mod_value("VR_LoadAsset", string.format("%x %x", sp:read_qword(0), sp:read_qword(8)))
  cls = api:find_uobject(full)
end
if cls == nil then return "class not found: " .. full end
local p = api:get_local_pawn(0)
local gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
local me = p:K2_GetActorLocation()
local vp, vyaw = _G.VIEW_POS, _G.VIEW_YAW
if vp == nil or vyaw == nil then return "no VIEW_POS / VIEW_YAW" end
local n = 0
for _, row in ipairs(rows) do
  for i = 1, per do
    pcall(function()
      local yaw = math.rad(vyaw + row[2] + (i - (per + 1) / 2) * (rawget(_G, "ROWS_SPREAD") or 28))
      local xf = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Transform"))
      xf.Translation = Vector3d.new(vp.x + math.cos(yaw) * row[1], vp.y + math.sin(yaw) * row[1], me.z + 10)
      local q = StructObject.new(api:find_uobject("ScriptStruct /Script/CoreUObject.Quat"))
      local h = (math.deg(yaw) + 180) * math.pi / 360
      q.X, q.Y, q.Z, q.W = 0, 0, math.sin(h), math.cos(h)
      xf.Rotation = q
      xf.Scale3D = Vector3d.new(1, 1, 1)
      local a = gs:BeginDeferredActorSpawnFromClass(p, cls, xf, 1, nil, 0)
      if a ~= nil and gs:FinishSpawningActor(a, xf, 0) ~= nil then n = n + 1 end
    end)
  end
end
return "spawned " .. n .. " of " .. full:match("([^%.]+)$")