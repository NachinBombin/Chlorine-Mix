-- ============================================================
--  ChlorPhos Antidote  |  arctic_med_shots/chlorphos_antidote.lua
--
--  Auto-included by sh_vm_arc_medshots.lua via:
--    file.Find("arctic_med_shots/*", "LUA")
--
--  Compound composition:
--    - Methylprednisolone   : corticosteroid; suppresses airway
--                             inflammation and blunts pulmonary
--                             oedema cascade.
--    - Aminophylline        : bronchodilator / phosphodiesterase
--                             inhibitor; reverses bronchospasm and
--                             improves respiratory muscle function.
--    - N-Acetylcysteine     : mucolytic antioxidant; scavenges
--                             free radicals from oxidative lung
--                             injury; thins secretions.
--    - Bronchodilator       : rapid beta-2 agonist component;
--                             immediate relief of airway constriction
--                             regardless of exposure phase.
--
--  Clears ALL phases of chlorine-phosgene exposure on injection:
--    Phase 1 (immediate chlorine irritation) — motion blur, tint,
--             vignette, and camera sway stopped instantly.
--    Phase 2 (latent false-recovery window) — effect zeroed before
--             the delayed edema timer can fire.
--    Phase 3 (delayed pulmonary oedema)     — active collapse state
--             cleared; visual and audio layers halted.
--
--  The clear function is guarded — if npc_chlorphos_gas_throw.lua
--  is not loaded the injection still succeeds silently.
-- ============================================================

ArcticMedShots["chlorphos_antidote"] = {

    QuickName  = "ChlorPhos-Rx",
    PrintName  = "Chlorine-Phosgene Emergency Antidote Auto-Injector",

    Description = {
        "Multi-compound pulmonary rescue formula.",
        "Arrests all phases of chlorine-phosgene",
        "exposure immediately on injection.",
        "  Methylprednisolone  - anti-inflammatory",
        "  Aminophylline       - bronchodilator / PDE inhibitor",
        "  N-Acetylcysteine    - antioxidant mucolytic",
        "  Bronchodilator      - rapid airway rescue",
    },
    DescriptionColors = {
        Color(220, 240, 180),
        Color(220, 240, 180),
        Color(220, 240, 180),
        Color(80,  230,  80),
        Color(80,  230,  80),
        Color(80,  230,  80),
        Color(80,  230,  80),
    },

    OnInject = function(ply, infl)
        if SERVER then

            -- ------------------------------------------------
            --  Clear chlorine-phosgene effect (all phases).
            --  NPCChlorPhos_AntidoteClear:
            --    - Zeroes playerHighEnd[uid] on the server.
            --      All pending phase timers find expiry < CurTime()
            --      and self-abort without further action.
            --    - Zeroes NWFloat fallbacks (high_start, high_end).
            --    - Sends NPCChlorPhos_ApplyHigh(0, 0) to the client,
            --      which sets cl_highStart = 0 and cl_highEnd = 0,
            --      stopping motion blur, colour modulation, green
            --      overlay, vignette, and camera sway on the next frame.
            -- ------------------------------------------------
            if NPCChlorPhos_AntidoteClear then
                NPCChlorPhos_AntidoteClear(ply)
            end

        end
    end,

    Skin = 1,

    -- Uncomment to use a custom HUD icon:
    -- EntityMaterial = "arc_medshot_chlorphos_antidote",
}
