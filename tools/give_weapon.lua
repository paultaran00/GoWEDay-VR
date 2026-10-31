-- (dev) Puts a weapon in the hand even where its class is not loaded: loads it through the UEVR patch VR_LoadAsset and
-- adds it IN THE SAME COMMAND (a class nothing holds is garbage-collected before a later use).
-- _G.GIVE = "Dir/BP_Wpn_Name" under /Game/Fairlight/Gameplay/BlueprintClasses/Weapons/WeaponAssets/ (or a full path
-- starting with "/Game/"). AddInventoryItem replaces the weapon in hand when its slots are full.
local api = uevr.api
local vr = uevr.params.vr
local g = rawget(_G, "GIVE")
if g == nil then return "set _G.GIVE" end
local path = g:find("^/Game/") and g or ("/Game/Fairlight/Gameplay/BlueprintClasses/Weapons/WeaponAssets/" .. g)
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
local inv = pawn:GetComponentByClass(api:find_uobject("Class /Script/FairlightGameFramework.FairlightCharacterInventoryComponent"))
local out = {}
local ok, err = pcall(function() inv:AddInventoryItem(cls, true, out, nil) end)
if not ok then return "AddInventoryItem failed: " .. tostring(err) end
local item = inv:GetEquippedInventoryItem()
local item_name = item and item:get_class():get_fname():to_string() or "nil"
if item_name ~= name .. "_C" then
  -- added but not in hand: equip it from its slot
  pcall(function()
    for _, it in ipairs(inv.InventoryItems or {}) do
      if it:get_class():get_fname():to_string() == name .. "_C" then inv:EquipInventoryItemInSlot(inv:GetItemSlotFromInventoryItem(it), false) end
    end
  end)
  item = inv:GetEquippedInventoryItem()
  item_name = item and item:get_class():get_fname():to_string() or "nil"
end
-- already owned (e.g. the Gnasher in its own slot): AddInventoryItem leaves it where it is - equip the owned one
if item_name ~= name .. "_C" then
  pcall(function()
    local gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
    local all = {}
    gs:GetAllActorsOfClass(pawn, cls, all)
    for _, a in ipairs(all) do
      if a:GetOwner() == pawn then inv:EquipInventoryItemInSlot(inv:GetItemSlotFromInventoryItem(a), false) end
    end
  end)
  item = inv:GetEquippedInventoryItem()
  item_name = item and item:get_class():get_fname():to_string() or "nil"
end
-- the weapon it replaced falls to the ground: destroyed (memory - each one a loaded weapon; only ownerless ones within
-- 3 m of the player)
local removed = 0
pcall(function()
  local base = api:find_uobject("Class /Script/TCWeapon.TCBaseWeapon")
  local gs = api:find_uobject("Class /Script/Engine.GameplayStatics"):get_class_default_object()
  local all = {}
  gs:GetAllActorsOfClass(pawn, base, all)
  local me = pawn:K2_GetActorLocation()
  for _, a in ipairs(all) do
    local ok = pcall(function()
      if a:GetOwner() == nil then
        local l = a:K2_GetActorLocation()
        local d = math.sqrt((l.x - me.x) ^ 2 + (l.y - me.y) ^ 2 + (l.z - me.z) ^ 2)
        if d < 300 then a:K2_DestroyActor() removed = removed + 1 end
      end
    end)
  end
end)
return "in hand: " .. item_name .. " (dropped ones removed: " .. removed .. ")"