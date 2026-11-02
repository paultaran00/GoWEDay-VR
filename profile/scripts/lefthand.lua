-- PRIMARY HAND LEFT: logic kept apart from the right-handed scripts. Every function is
-- only called under EDAY_LEFTY == true; the existing scripts have one-line hooks. Loaded after aa_xr.lua (alphabetically).
LH = LH or {}

-- Charging handle knobs sit on both sides of the receiver. The right-handed mod takes the one the fingers are on; for a
-- left-handed player the right (support) hand takes the RIGHT-side knob, the mirror of the left hand on the left knob (the
-- arm used to cross over the top of the gun to the left one). Not the Longshot ball / Breechshot rod / pistol slide.
function LH.knob_side(side, bb, ba)
    if ba or bb == "b_handle" or bb == "b_slide" then return side end
    return 1
end

-- The holstered pistol hangs on the left hip: the frame the game gave it (its socket + relative transform) is reflected across
-- the sagittal plane of the game's body (normal = right thigh - left thigh, flat; through the pelvis) and the pistol's lateral
-- axis y is negated so the frame stays a proper rotation. (arms.lua place_attachments, before the body turn and shift)
local function v(x, y, z) return { x = x, y = y, z = z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function LH.mirror_holster(placed, mesh)
    local api = uevr.api
    local ks = api:find_uobject("Class /Script/Engine.KismetStringLibrary"):get_class_default_object()
    local function bone(n) local l = mesh:GetSocketLocation(ks:Conv_StringToName(n)) return v(l.x, l.y, l.z) end
    local tr, tl = bone("b_thigh_R"), bone("b_thigh_L")
    local nx, ny = tr.x - tl.x, tr.y - tl.y
    local nl = math.sqrt(nx * nx + ny * ny)
    if nl < 1e-6 then return placed end
    local n = v(nx / nl, ny / nl, 0)
    local c = v((tr.x + tl.x) / 2, (tr.y + tl.y) / 2, (tr.z + tl.z) / 2)
    local function refl(w) local k = 2 * dot(w, n) return v(w.x - n.x * k, w.y - n.y * k, w.z - n.z * k) end
    local d = refl(v(placed.pos.x - c.x, placed.pos.y - c.y, placed.pos.z - c.z))
    local y = refl(placed.y)
    return { pos = v(d.x + c.x, d.y + c.y, d.z + c.z), x = refl(placed.x), y = v(-y.x, -y.y, -y.z), z = refl(placed.z) }
end
