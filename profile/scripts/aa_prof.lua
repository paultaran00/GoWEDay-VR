-- Development only: times every callback the other scripts register (loads first, wraps the registration).
-- PROF_RESET() starts a new measurement; PROF_REPORT() returns average ms per call and calls per frame.
local PROFILE = false -- development: true times every callback (PROF_RESET / PROF_REPORT via tools/dbg.sh)
if not PROFILE then return end

local cb = uevr.sdk.callbacks
PROF = { stats = {}, frames = 0 }
function PROF_RESET() PROF.stats, PROF.frames, PROF.dt = {}, 0, 0 end
function PROF_REPORT()
    local rows = {}
    for k, s in pairs(PROF.stats) do
        table.insert(rows, { k = k, per_frame = s.t / math.max(1, PROF.frames), calls = s.n / math.max(1, PROF.frames) })
    end
    table.sort(rows, function(a, b) return a.per_frame > b.per_frame end)
    local out = { string.format("%d frames, avg frame %.2f ms", PROF.frames, (PROF.dt or 0) / math.max(1, PROF.frames) * 1000) }
    local total = 0
    for _, r in ipairs(rows) do
        total = total + r.per_frame
        table.insert(out, string.format("%7.3f ms/frame  %4.1f calls/frame  max %.1f ms  %s", r.per_frame * 1000, r.calls, (PROF.stats[r.k].mx or 0) * 1000, r.k))
    end
    table.insert(out, string.format("%7.3f ms/frame  TOTAL", total * 1000))
    return table.concat(out, "\n")
end

-- uevr.sdk and its callbacks are userdata (not writable): the scripts get proxies in their place
local real_sdk = uevr.sdk
local proxy_cb = setmetatable({}, { __index = function(_, k) return cb[k] end })
for _, name in ipairs({ "on_pre_engine_tick", "on_post_engine_tick", "on_early_calculate_stereo_view_offset",
                        "on_pre_calculate_stereo_view_offset", "on_post_calculate_stereo_view_offset", "on_xinput_get_state" }) do
    local orig = cb[name]
    if orig ~= nil then
        proxy_cb[name] = function(fn)
            local info = debug and debug.getinfo and debug.getinfo(2, "Sl")
            PROF.seq = (PROF.seq or 0) + 1
            local key = string.format("#%02d %s", PROF.seq, (name:gsub("^on_", "")))
            return orig(function(...)
                local t0 = os.clock()
                local r = fn(...)
                local s = PROF.stats[key]
                if s == nil then s = { t = 0, n = 0 } PROF.stats[key] = s end
                local dt = os.clock() - t0
                s.t, s.n = s.t + dt, s.n + 1
                if dt > (s.mx or 0) then s.mx = dt end
                -- a long call: logged right away (the game froze ~0.45 s when Wretches attacked)
                if dt > 0.03 then pcall(function() uevr.params.functions.log_info(string.format("[prof] SLOW %s %.0f ms", key, dt * 1000)) end) end
                return r
            end)
        end
    end
end
uevr.sdk = setmetatable({ callbacks = proxy_cb }, { __index = function(_, k) return real_sdk[k] end })
cb.on_pre_engine_tick(function(engine, delta)
    PROF.frames = PROF.frames + 1 PROF.dt = (PROF.dt or 0) + delta
    if delta > 0.15 then pcall(function() uevr.params.functions.log_info(string.format("[prof] FRAME %.0f ms (melee %s)", delta * 1000, MELEE_LAST and string.format("%s %.1f s ago", MELEE_LAST.enemy, os.clock() - MELEE_LAST.at) or "-")) end) end
end)
function PROF_SEC(name, dt)
    local s = PROF.stats[name]
    if s == nil then s = { t = 0, n = 0 } PROF.stats[name] = s end
    s.t, s.n = s.t + dt, s.n + 1
end
