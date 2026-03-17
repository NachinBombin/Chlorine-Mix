-- ============================================================
--  arc_medshot_chlorphos_antidote  |  entities/arc_medshot_chlorphos_antidote.lua
--
--  Spawnable world pickup entity for the ChlorPhos Antidote injector.
--  Inherits all pickup, touch, and draw logic from arc_medshot_base.
--  On touch, adds 1x "chlorphos_antidote" to the player's
--  ArcticMedShots inventory.
-- ============================================================

AddCSLuaFile()

ENT.PrintName = "ChlorPhos-Rx Antidote"
ENT.Spawnable = true
ENT.Category  = "Arctic's Combat Stims"
ENT.Type      = "anim"
ENT.Base      = "arc_medshot_base"

ENT.Shots = {
    ["chlorphos_antidote"] = 1,
}

-- Skin 1 = alternate syringe colour.
-- Update to match the Skin value set in arctic_med_shots/chlorphos_antidote.lua.
ENT.Skin = 1

-- Optional: uncomment and set a material path to override the syringe texture.
-- ENT.ShotMaterial = "models/weapons/v_models/arc_vm_healthshot/shot_chlorphos_antidote"
