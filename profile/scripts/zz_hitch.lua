-- (debug) Hitch logger: every frame longer than HITCH_MS is logged with its length, to find freezes in the log
-- (a freeze taking the Longshot from a supply cache right after entering the game).
local HITCH_MS = 100
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if delta * 1000 > HITCH_MS then
        pcall(function() uevr.params.functions.log_info(string.format("[hitch] %.0f ms frame", delta * 1000)) end)
    end
end)