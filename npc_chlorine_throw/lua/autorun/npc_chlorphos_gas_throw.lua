-- ============================================================
--  NPC Chlorine-Phosgene Gas Throw  |  npc_chlorphos_gas_throw.lua
--  Shared (SERVER logic + CLIENT trail + screen effects).
--
--  Enemy NPCs periodically lob a gas canister (prop_physics)
--  toward the player they are targeting.  On impact a yellow-
--  green gas cloud is emitted.  The cloud deals NO damage but
--  applies a choking/disorientation effect to players caught
--  inside:
--    - Motion blur (progressive, based on exposure time)
--    - Yellow-green screen tint (chlorine characteristic colour)
--    - Pulsing vignette (simulates laboured breathing / blackout)
--    - Camera sway (sinusoidal roll + pitch drift)
--    - Movement disruption (random involuntary inputs)
--
--  CLIENT trail: a thin yellow-green smoke tracer follows the vial.
--  CLIENT cloud: yellow-green particle burst fired at detonation point.
--
--  No external addon dependencies.
--
--  NPCs are NOT affected (cloud applies to players only).
--  Gas mask (g4p_gasmask) wearers are fully immune.
--
--  [ANTIDOTE COMPATIBILITY]
--  Exposes NPCChlorPhos_AntidoteClear(ply) so a future antidote
--  syringe (arctic_med_shots/chlorphos_antidote.lua) can clear
--  this effect on demand.  Pattern is identical to NPCStunGas_NarcanClear.
-- ============================================================

-- ============================================================
--  Shared network strings (must run on both realms)
-- ============================================================
util.AddNetworkString("NPCChlorPhos_VialSpawned")
util.AddNetworkString("NPCChlorPhos_CloudEffect")
util.AddNetworkString("NPCChlorPhos_ApplyHigh")

-- ============================================================
--  SERVER
-- ============================================================
if SERVER then

AddCSLuaFile()

-- ============================================================
--  ConVars
-- ============================================================
local SHARED_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)

local cv_enabled    = CreateConVar("npc_chlorphos_gas_throw_enabled",    "1",    SHARED_FLAGS, "Enable/disable NPC chlorine-phosgene gas throws.")
local cv_chance     = CreateConVar("npc_chlorphos_gas_throw_chance",     "0.20", SHARED_FLAGS, "Probability (0-1) that an eligible NPC throws each check.")
local cv_interval   = CreateConVar("npc_chlorphos_gas_throw_interval",   "8",    SHARED_FLAGS, "Seconds between throw-eligibility checks per NPC.")
local cv_cooldown   = CreateConVar("npc_chlorphos_gas_throw_cooldown",   "18",   SHARED_FLAGS, "Minimum seconds between throws for the same NPC.")
local cv_speed      = CreateConVar("npc_chlorphos_gas_throw_speed",      "700",  SHARED_FLAGS, "Launch speed of the canister (units/s).")
local cv_arc        = CreateConVar("npc_chlorphos_gas_throw_arc",        "0.25", SHARED_FLAGS, "Upward arc factor (0 = flat, higher = more lob).")
local cv_spawn_dist = CreateConVar("npc_chlorphos_gas_throw_spawn_dist", "52",   SHARED_FLAGS, "Forward distance from NPC eye to spawn the canister.")
local cv_max_dist   = CreateConVar("npc_chlorphos_gas_throw_max_dist",   "2200", SHARED_FLAGS, "Max distance to player for a throw to be attempted.")
local cv_min_dist   = CreateConVar("npc_chlorphos_gas_throw_min_dist",   "120",  SHARED_FLAGS, "Min distance to player (no throw if closer than this).")
local cv_spin       = CreateConVar("npc_chlorphos_gas_throw_spin",       "1",    SHARED_FLAGS, "Apply a random spin impulse to the canister (1 = enabled).")
local cv_announce   = CreateConVar("npc_chlorphos_gas_throw_announce",   "0",    SHARED_FLAGS, "Print a debug message to console on each throw.")
local cv_cloud_min  = CreateConVar("npc_chlorphos_gas_throw_cloud_min",  "150",  SHARED_FLAGS, "Minimum gas cloud radius in units.")
local cv_cloud_max  = CreateConVar("npc_chlorphos_gas_throw_cloud_max",  "300",  SHARED_FLAGS, "Maximum gas cloud radius in units.")
local cv_high_min   = CreateConVar("npc_chlorphos_gas_throw_high_min",   "30",   SHARED_FLAGS, "Minimum effect duration in seconds.")
local cv_high_max   = CreateConVar("npc_chlorphos_gas_throw_high_max",   "75",   SHARED_FLAGS, "Maximum effect duration in seconds.")

-- ============================================================
--  Constants
-- ============================================================

local VIAL_MODEL    = "models/healthvial.mdl"
local VIAL_MATERIAL = "models/weapons/gv/nerve_vial.vmt"

local IMPACT_SPEED  = 80
local MIN_FLIGHT    = 0.25
local MAX_VIAL_LIFE = 8

local vialCounter   = 0

-- ============================================================
--  Eligible NPC throwers
-- ============================================================

local CHLORPHOS_THROWERS = {
    ["npc_combine_s"]     = true,
    ["npc_metropolice"]   = true,
    ["npc_combine_elite"] = true,
}

local function IsEligibleThrower(npc)
    if not IsValid(npc) or not npc:IsNPC() then return false end
    return CHLORPHOS_THROWERS[npc:GetClass()] == true
end

-- ============================================================
--  Launch helpers
-- ============================================================

local function CalcLaunchVelocity(from, to, speed, arcFactor)
    local dir        = (to - from)
    local horizontal = Vector(dir.x, dir.y, 0)
    local dist       = horizontal:Length()
    if dist < 1 then dist = 1 end
    horizontal:Normalize()
    local velH = horizontal * speed
    local velZ = dist * arcFactor + (to.z - from.z) * 0.3
    velZ = math.Clamp(velZ, -speed * 0.5, speed * 0.8)
    return Vector(velH.x, velH.y, velZ)
end

-- ============================================================
--  ChlorPhos "High" state
--
--  NPCChlorPhos_AntidoteClear has closure access to playerHighEnd
--  because it is defined in this same SERVER block.
-- ============================================================

local playerHighEnd    = {}  -- keyed by UserID: CurTime() when effect expires
local playerExposeStart = {}  -- keyed by UserID: CurTime() when first exposed this session
local playerDmgAccum    = {}  -- keyed by UserID: fractional damage accumulator

local function ApplyChlorPhosHigh(pl)
    if not IsValid(pl) or not pl:IsPlayer() then return end
    if not pl:Alive() then return end

    -- Gas mask wearers are fully immune.
    if pl.GASMASK_Equiped then return end

    local now         = CurTime()
    local uid         = pl:UserID()
    local highDuration = math.Rand(cv_high_min:GetFloat(), cv_high_max:GetFloat())

    -- Extend existing effect rather than restart if already active.
    if (playerHighEnd[uid] or 0) > now then
        playerHighEnd[uid] = math.max(playerHighEnd[uid], now + highDuration)
        pl:SetNWFloat("npc_chlorphos_high_end", playerHighEnd[uid])
        return
    end

    playerHighEnd[uid] = now + highDuration

    -- Record when this player was FIRST exposed this session.
    -- Never overwrite: we want the original timestamp so elapsed
    -- time keeps climbing through re-exposures, driving escalation.
    if not playerExposeStart[uid] then
        playerExposeStart[uid] = now
    end

    net.Start("NPCChlorPhos_ApplyHigh")
        net.WriteFloat(now)
        net.WriteFloat(playerHighEnd[uid])
    net.Send(pl)

    pl:SetNWFloat("npc_chlorphos_high_start", now)
    pl:SetNWFloat("npc_chlorphos_high_end",   playerHighEnd[uid])
    -- No movement disruption: chlorine-phosgene expresses through visuals and sway only.
end

-- ============================================================
--  Damage escalation
--
--  Returns damage-per-second for a given elapsed exposure time.
--  First 10 seconds: no damage (gas is still building up).
--  10-30 s  : 0.0 → 0.2 dps  (starts at 1 dmg per 5 s at 30 s)
--  30-60 s  : 0.2 → 1.0 dps  (noticeable, still survivable)
--  60-120 s : 1.0 → 5.0 dps  (serious, cap at 5)
-- ============================================================

local function GetChlorPhosDPS(elapsed)
    if elapsed < 10 then return 0 end
    if elapsed < 30  then return math.Remap(elapsed, 10, 30,  0.0, 0.2) end
    if elapsed < 60  then return math.Remap(elapsed, 30, 60,  0.2, 1.0) end
    return math.min(math.Remap(elapsed, 60, 120, 1.0, 5.0), 5.0)
end

-- Global 1-second ticker: applies accumulated damage to every affected player.
-- Using an accumulator means fractional dps (e.g. 0.2 dps = 1 dmg every 5 s)
-- resolves correctly without sub-second timers.
timer.Create("ChlorPhosDamageTick", 1, 0, function()
    local now = CurTime()
    for uid, expiry in pairs(playerHighEnd) do
        if expiry < now then continue end  -- effect already expired

        local pl = player.GetByUniqueID and player.GetByUniqueID(uid)
        -- GetByUniqueID may not exist on all builds; fall back to iteration
        if not pl or not IsValid(pl) then
            for _, p in ipairs(player.GetAll()) do
                if p:UserID() == uid then pl = p; break end
            end
        end

        if not IsValid(pl) or not pl:Alive() then continue end

        local exposeStart = playerExposeStart[uid]
        if not exposeStart then continue end

        local elapsed = now - exposeStart
        local dps     = GetChlorPhosDPS(elapsed)
        if dps <= 0 then continue end

        playerDmgAccum[uid] = (playerDmgAccum[uid] or 0) + dps

        -- Deal whole-number damage; carry the remainder forward.
        local dmg = math.floor(playerDmgAccum[uid])
        if dmg >= 1 then
            playerDmgAccum[uid] = playerDmgAccum[uid] - dmg
            pl:TakeDamage(dmg, game.GetWorld(), game.GetWorld())
        end
    end
end)

-- ============================================================
--  Detonation
--  Cloud ticks apply to PLAYERS only (NPCs unaffected).
-- ============================================================

local function DetonateChlorPhosGas(pos, owner, uid)

    local cloudRadius = math.Rand(cv_cloud_min:GetFloat(), cv_cloud_max:GetFloat())

    net.Start("NPCChlorPhos_CloudEffect")
        net.WriteVector(pos)
        net.WriteFloat(cloudRadius)
    net.Broadcast()

    local GAS_DURATION = 18
    local GAS_TICK     = 0.5
    local ticks        = math.floor(GAS_DURATION / GAS_TICK)
    local timerName    = "ChlorPhosGasDmg_" .. uid

    timer.Create(timerName, GAS_TICK, ticks, function()
        for _, ent in ipairs(ents.FindInSphere(pos, cloudRadius)) do
            if not IsValid(ent) then continue end
            if not ent:IsPlayer() then continue end  -- NPCs: no effect
            ApplyChlorPhosHigh(ent)
        end
    end)
end

-- ============================================================
--  Throw logic
-- ============================================================

local function ThrowChlorPhosGas(npc, target)

    do
        local gestureAct  = ACT_GESTURE_RANGE_ATTACK_THROW
        local fallbackAct = ACT_RANGE_ATTACK_THROW
        local seq = npc:SelectWeightedSequence(gestureAct)
        if seq <= 0 then
            seq = npc:SelectWeightedSequence(fallbackAct)
            if seq > 0 then gestureAct = fallbackAct end
        end
        if seq > 0 then npc:AddGesture(gestureAct) end
    end

    npc.__chlorphos_lastThrow = CurTime()
    local distAtTrigger = npc:GetPos():Distance(target:GetPos())

    timer.Simple(1, function()

        if not IsValid(npc) or not IsValid(target) then return end

        local targetPos = target:GetPos() + Vector(0, 0, 36)
        local npcEyePos = npc:EyePos()
        local toTarget  = (targetPos - npcEyePos):GetNormalized()
        local spawnDist = cv_spawn_dist:GetFloat()
        local spawnPos  = npcEyePos + toTarget * spawnDist

        local tr = util.TraceLine({
            start  = npcEyePos,
            endpos = spawnPos,
            filter = { npc },
            mask   = MASK_SOLID_BRUSHONLY,
        })
        if tr.Hit then
            spawnPos = npcEyePos + toTarget * (tr.Fraction * spawnDist * 0.85)
        end

        local vial = ents.Create("prop_physics")
        if not IsValid(vial) then return end

        local eyeAng = toTarget:Angle()
        vial:SetModel(VIAL_MODEL)
        vial:SetMaterial(VIAL_MATERIAL)
        vial:SetPos(spawnPos + eyeAng:Right() * 6 + eyeAng:Up() * -2)
        vial:SetAngles(npc:GetAngles() + Angle(-90, 0, 0))
        vial:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
        vial:Spawn()
        vial:Activate()

        vial.ChlorPhosOwner = npc

        local phys = vial:GetPhysicsObject()
        if IsValid(phys) then
            local speed = cv_speed:GetFloat()
            local vel   = CalcLaunchVelocity(spawnPos, targetPos, speed, cv_arc:GetFloat())
            phys:SetVelocity(vel)

            if cv_spin:GetBool() then
                local spin   = vel:GetNormalized() * math.random(5, 10)
                local offset = vial:LocalToWorld(vial:OBBCenter())
                             + Vector(0, 0, math.random(10, 15))
                phys:ApplyForceOffset(spin, offset)
            end

            phys:Wake()
        end

        net.Start("NPCChlorPhos_VialSpawned")
            net.WriteEntity(vial)
        net.Broadcast()

        if cv_announce:GetBool() then
            print(string.format(
                "[NPC ChlorPhos Gas Throw] %s threw at %s (dist: %.0f)",
                npc:GetClass(), target:Nick(), distAtTrigger
            ))
        end

        vialCounter = vialCounter + 1
        local uid       = vialCounter
        local spawnTime = CurTime()
        local timerName = "ChlorPhosVial_" .. uid

        timer.Create(timerName, 0.05, 0, function()

            if not IsValid(vial) then
                timer.Remove(timerName)
                DetonateChlorPhosGas(spawnPos, npc, uid)
                return
            end

            local age   = CurTime() - spawnTime
            local phys2 = vial:GetPhysicsObject()
            local spd2  = IsValid(phys2) and phys2:GetVelocity():Length() or 0

            local impacted = (age > MIN_FLIGHT) and (spd2 < IMPACT_SPEED)
            local expired  = (age > MAX_VIAL_LIFE)

            if impacted or expired then
                local gasPos = vial:GetPos()
                local owner  = vial.ChlorPhosOwner
                vial:Remove()
                timer.Remove(timerName)
                DetonateChlorPhosGas(gasPos, owner, uid)
            end
        end)

    end)  -- end timer.Simple

    return true
end

-- ============================================================
--  Per-NPC state initialisation (lazy)
-- ============================================================

local function InitNPCState(npc)
    if not IsValid(npc) then return end
    if npc.__chlorphos_hooked then return end
    npc.__chlorphos_hooked    = true
    npc.__chlorphos_nextCheck = CurTime() + math.Rand(1, cv_interval:GetFloat())
    npc.__chlorphos_lastThrow = 0
end

-- ============================================================
--  Main Think loop
-- ============================================================

timer.Create("NPCChlorPhosGasThrow_Think", 0.5, 0, function()
    if not cv_enabled:GetBool() then return end

    local now      = CurTime()
    local interval = cv_interval:GetFloat()
    local cooldown = cv_cooldown:GetFloat()
    local chance   = cv_chance:GetFloat()
    local maxDist  = cv_max_dist:GetFloat()
    local minDist  = cv_min_dist:GetFloat()

    for _, npc in ipairs(ents.GetAll()) do
        if not IsValid(npc) or not npc:IsNPC() then continue end
        if not IsEligibleThrower(npc) then continue end

        InitNPCState(npc)

        if now < (npc.__chlorphos_nextCheck or 0) then continue end
        npc.__chlorphos_nextCheck = now + interval + math.Rand(-1, 1)

        if now - (npc.__chlorphos_lastThrow or 0) < cooldown then continue end

        if npc:Health() <= 0 then continue end
        local enemy = npc:GetEnemy()
        if not IsValid(enemy) or not enemy:IsPlayer() then continue end
        if not enemy:Alive() then continue end

        local dist = npc:GetPos():Distance(enemy:GetPos())
        if dist > maxDist or dist < minDist then continue end

        local losTr = util.TraceLine({
            start  = npc:EyePos(),
            endpos = enemy:EyePos(),
            filter = { npc },
            mask   = MASK_SOLID,
        })
        if losTr.Entity ~= enemy and losTr.Fraction < 0.85 then continue end

        if math.random() > chance then continue end

        ThrowChlorPhosGas(npc, enemy)
    end
end)

-- ============================================================
--  Startup message
-- ============================================================

hook.Add("InitPostEntity", "NPCChlorPhosGasThrow_Init", function()
    print("[NPC ChlorPhos Gas Throw] Addon loaded.")
    print("[NPC ChlorPhos Gas Throw] Use 'npc_chlorphos_gas_throw_*' convars to configure.")
    print("[NPC ChlorPhos Gas Throw] Antidote support: active (NPCChlorPhos_AntidoteClear).")
    print("[NPC ChlorPhos Gas Throw] Gas mask support: active (GASMASK_Equiped guard).")
end)

-- ============================================================
--  Clear effect on player death
-- ============================================================

hook.Add("PlayerDeath", "NPCChlorPhosGasThrow_ClearOnDeath", function(pl)
    if not IsValid(pl) then return end
    local uid = pl:UserID()
    playerHighEnd[uid]    = nil
    playerExposeStart[uid] = nil
    playerDmgAccum[uid]   = nil
    pl:SetNWFloat("npc_chlorphos_high_start", 0)
    pl:SetNWFloat("npc_chlorphos_high_end",   0)
    net.Start("NPCChlorPhos_ApplyHigh")
        net.WriteFloat(0)
        net.WriteFloat(0)
    net.Send(pl)
end)

-- ============================================================
--  [ANTIDOTE COMPATIBILITY] Global clear function
--
--  Called by the antidote syringe via:
--      if NPCChlorPhos_AntidoteClear then
--          NPCChlorPhos_AntidoteClear(ply)
--      end
--
--  Defined inside the SERVER block so it has closure access to
--  the local playerHighEnd table above.
--  Reuses NPCChlorPhos_ApplyHigh(0, 0) -- identical to death
--  clear -- so no additional network strings are needed.
-- ============================================================

--- Immediately clears the chlorine-phosgene effect for a player.
function NPCChlorPhos_AntidoteClear(ply)
    if not IsValid(ply) then return end

    local uid = ply:UserID()

    -- Zero server-side expiry: all pending timer callbacks will find
    -- (playerHighEnd[uid] or 0) < CurTime() and self-abort.
    playerHighEnd[uid]    = nil

    -- Clear damage escalation state so the ticker stops immediately
    -- and accumulated partial damage is discarded.
    playerExposeStart[uid] = nil
    playerDmgAccum[uid]   = nil

    -- Zero NWFloat fallback values used by late-joiners.
    ply:SetNWFloat("npc_chlorphos_high_start", 0)
    ply:SetNWFloat("npc_chlorphos_high_end",   0)

    -- Send ApplyHigh(0, 0) to the client.  The client receiver sets
    -- cl_highStart = 0 and cl_highEnd = 0, which immediately stops
    -- all visual layers on the next frame.
    net.Start("NPCChlorPhos_ApplyHigh")
        net.WriteFloat(0)
        net.WriteFloat(0)
    net.Send(ply)
end

end  -- SERVER

-- ============================================================
--  CLIENT
-- ============================================================
if CLIENT then

-- ============================================================
--  Yellow-green canister tracer
-- ============================================================

local activeVials       = {}
local SMOKE_SPRITE_BASE = "particle/smokesprites_000"

net.Receive("NPCChlorPhos_VialSpawned", function()
    local vial = net.ReadEntity()
    if IsValid(vial) then
        activeVials[vial:EntIndex()] = vial
    end
end)

hook.Add("Think", "NPCChlorPhosGasThrow_VialTracer", function()

    if not next(activeVials) then return end

    for idx, vial in pairs(activeVials) do
        if not IsValid(vial) then
            activeVials[idx] = nil
            continue
        end

        local pos     = vial:GetPos()
        local emitter = ParticleEmitter(pos, false)
        if not emitter then continue end

        -- Primary wisp: yellow-green
        for i = 1, 2 do
            local p = emitter:Add(SMOKE_SPRITE_BASE .. math.random(1, 9), pos)
            if not p then continue end

            p:SetVelocity(Vector(
                math.Rand(-8, 8),
                math.Rand(-8, 8),
                math.Rand(4, 14)
            ))
            p:SetDieTime(math.Rand(0.3, 0.6))
            p:SetColor(160, 230, 40)   -- yellow-green
            p:SetStartAlpha(math.Rand(180, 220))
            p:SetEndAlpha(0)
            p:SetStartSize(math.Rand(3, 6))
            p:SetEndSize(math.Rand(14, 24))
            p:SetRoll(math.Rand(0, 360))
            p:SetRollDelta(math.Rand(-0.5, 0.5))
            p:SetAirResistance(70)
            p:SetGravity(Vector(0, 0, -6))
        end

        -- Occasional larger puff
        if math.random() > 0.55 then
            local p = emitter:Add(SMOKE_SPRITE_BASE .. math.random(1, 9), pos)
            if p then
                p:SetVelocity(Vector(
                    math.Rand(-14, 14),
                    math.Rand(-14, 14),
                    math.Rand(8, 20)
                ))
                p:SetDieTime(math.Rand(0.7, 1.2))
                p:SetColor(130, 210, 20)
                p:SetStartAlpha(math.Rand(70, 110))
                p:SetEndAlpha(0)
                p:SetStartSize(math.Rand(6, 11))
                p:SetEndSize(math.Rand(28, 45))
                p:SetRoll(math.Rand(0, 360))
                p:SetRollDelta(math.Rand(-0.3, 0.3))
                p:SetAirResistance(45)
                p:SetGravity(Vector(0, 0, -4))
            end
        end

        emitter:Finish()
    end
end)

-- ============================================================
--  Yellow-green cloud burst at detonation point
-- ============================================================

net.Receive("NPCChlorPhos_CloudEffect", function()
    local pos         = net.ReadVector()
    local cloudRadius = net.ReadFloat()

    local emitter = ParticleEmitter(pos, false)
    if not emitter then return end

    local count = math.floor(math.Clamp(cloudRadius / 5, 30, 120))

    for i = 1, count do
        local p = emitter:Add(SMOKE_SPRITE_BASE .. math.random(1, 9), pos)
        if not p then continue end

        local speed = math.Rand(cloudRadius * 0.3, cloudRadius * 1.0)
        p:SetVelocity(VectorRand():GetNormalized() * speed)

        if i <= math.floor(count * 0.1) then
            p:SetDieTime(18)
        else
            p:SetDieTime(math.Rand(8, 18))
        end

        -- Yellow-green hue: vary between lime and pale green
        local g = math.random(200, 245)
        local r = math.random(120, 180)
        p:SetColor(r, g, 20)

        p:SetStartAlpha(math.Rand(45, 65))
        p:SetEndAlpha(0)
        p:SetStartSize(math.Rand(40, 60))
        p:SetEndSize(math.Rand(180, 260))
        p:SetRoll(math.Rand(0, 360))
        p:SetRollDelta(math.Rand(-1, 1))
        p:SetAirResistance(100)
        p:SetCollide(true)
        p:SetBounce(1)
    end

    emitter:Finish()
end)

-- ============================================================
--  ChlorPhos High -- screen effects
--
--  Three layered effects, all driven by the same BlurFactor:
--    1. Motion blur (DrawMotionBlur)
--    2. Yellow-green colour modulation
--    3. Pulsing vignette (simulates choking / laboured breathing)
--    4. Sinusoidal camera sway
--
--  Receives both the normal ApplyHigh trigger AND the antidote
--  clear (which sends 0, 0 -- same as PlayerDeath -- to
--  instantly zero all state on the next rendered frame).
-- ============================================================

local CHLORPHOS_TRANSITION = 6     -- seconds to ramp in / ramp out
local CHLORPHOS_INTENSITY  = 1     -- peak factor (0-1)

local cl_highStart = 0
local cl_highEnd   = 0

net.Receive("NPCChlorPhos_ApplyHigh", function()
    cl_highStart = net.ReadFloat()
    cl_highEnd   = net.ReadFloat()
end)

local function GetChlorPhosBlurFactor()
    local now = CurTime()

    local highStart = cl_highStart
    local highEnd   = cl_highEnd

    -- NWFloat fallback for late-joining clients.
    if highStart == 0 then
        highStart = LocalPlayer():GetNWFloat("npc_chlorphos_high_start", 0)
        highEnd   = LocalPlayer():GetNWFloat("npc_chlorphos_high_end",   0)
    end

    if highStart == 0 or highEnd <= now then return 0 end

    local factor = 0

    if highStart + CHLORPHOS_TRANSITION > now then
        -- Ramp in
        local s = highStart
        local e = s + CHLORPHOS_TRANSITION
        factor  = ((now - s) / (e - s)) * CHLORPHOS_INTENSITY

    elseif highEnd - CHLORPHOS_TRANSITION < now then
        -- Ramp out
        local e = highEnd
        local s = e - CHLORPHOS_TRANSITION
        factor  = (1 - (now - s) / (e - s)) * CHLORPHOS_INTENSITY

    else
        factor = CHLORPHOS_INTENSITY
    end

    return math.Clamp(factor, 0, 1)
end

hook.Add("RenderScreenspaceEffects", "NPCChlorPhosGasThrow_High", function()
    local pl = LocalPlayer()
    if not IsValid(pl) then return end

    local factor = GetChlorPhosBlurFactor()
    if factor <= 0 then return end

    -- 1. Motion blur — reduced to feel heavy but not disorienting
    DrawMotionBlur(0.02, factor * 0.6, 0)

    -- 2. 3D scene colour modulation: light green cast, toned down.
    --    R pulled to 0.65, B to 0.60 at peak — noticeable but not blinding.
    render.SetColorModulation(
        1 - factor * 0.35,   -- R: 1.0 → 0.65
        1,                   -- G: always 1.0
        1 - factor * 0.40    -- B: 1.0 → 0.60
    )
end)

-- 3. HUDPaint: yellow-green screen overlay + pulsing vignette.
--    surface.Draw* calls MUST be in a 2D hook (HUDPaint / DrawHUD).
--    Putting them in RenderScreenspaceEffects (a 3D context) produces
--    rectangle artifacts -- this hook is the correct fix.
hook.Add("HUDPaint", "NPCChlorPhosGasThrow_Overlay", function()
    local pl = LocalPlayer()
    if not IsValid(pl) then return end

    local factor = GetChlorPhosBlurFactor()
    if factor <= 0 then return end

    local sw, sh = ScrW(), ScrH()
    local t      = CurTime()

    -- Single full-screen wash that pulses in alpha at breathing rhythm (~1.8 Hz).
    -- No edge strips, no geometric borders — zero rectangle artifacts.
    -- The pulse swings between a dim base and a brighter peak, simulating
    -- the laboured inhale/exhale cycle.  The 3D colour modulation in
    -- RenderScreenspaceEffects handles the green tint on scene geometry;
    -- this layer adds the visible 2D green cast over the HUD.
    local pulse     = math.sin(t * 1.8) * 0.5 + 0.5          -- 0 → 1
    local washAlpha = math.floor((18 + pulse * 28) * factor)  -- 18 → 46 at full factor
    surface.SetDrawColor(100, 190, 0, washAlpha)
    surface.DrawRect(0, 0, sw, sh)
end)

-- 4. Sinusoidal camera sway (slightly different frequency from stun gas for a distinct feel)
hook.Add("CalcView", "NPCChlorPhosGasThrow_Sway", function(pl, origin, angles, fov)
    if not IsValid(pl) then return end

    local factor = GetChlorPhosBlurFactor()
    if factor <= 0 then return end

    local t = CurTime()

    -- Slower, heavier sway -- mimics oxygen-deprived disorientation
    local roll  = math.sin(t * 0.7) * 6 * factor
    local pitch = math.sin(t * 1.3 + 0.9) * 2.5 * factor
    local yaw   = math.sin(t * 0.4 + 0.5) * 1.2 * factor

    local newAngles = Angle(
        angles.p + pitch,
        angles.y + yaw,
        angles.r + roll
    )

    return { origin = origin, angles = newAngles, fov = fov }
end)

-- Reset colour modulation when effect ends (prevents permanent tint)
hook.Add("PostRender", "NPCChlorPhosGasThrow_HighReset", function()
    if cl_highEnd > 0 and cl_highEnd <= CurTime() then
        render.SetColorModulation(1, 1, 1)
        cl_highStart = 0
        cl_highEnd   = 0
    end
end)

end  -- CLIENT
