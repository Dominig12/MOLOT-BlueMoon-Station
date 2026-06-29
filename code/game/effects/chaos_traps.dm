// Chaos Traps - effects that trigger in chaos dimension rooms

// Base chaos trap
/datum/chaos_trap
    name = "Chaos Trap"
    icon = 'icons/effect/chaos_trap.dmi'
    icon_state = "chaos_trap"
    trigger_range = 1
    damage = 0
    sanity_drain = 0
    distortion_increase = 0
    is_active = TRUE
    cooldown = 0
    trigger_type = ""
    triggered = FALSE
    var/datum/chaos_room/parent_room

/datum/chaos_trap/proc/activate_trap(mob/living/target)
    if(!target || !is_active || triggered)
        return
    
    if(cooldown > world.time)
        return
    
    switch(trigger_type)
        if("damage")
            apply_damage(target)
        if("sanity")
            apply_sanity_drain(target)
        if("distortion")
            apply_distortion_increase(target)
        if("combined")
            apply_damage(target)
            apply_sanity_drain(target)
            apply_distortion_increase(target)
        if("teleport")
            apply_teleport(target)
        if("stun")
            apply_stun(target)
    
    triggered = TRUE
    cooldown = world.time + 30 SECONDS

/datum/chaos_trap/proc/apply_damage(mob/living/target)
    if(!target || !damage)
        return
    
    target.plussign_take_damage(damage, CHAOS_DAMAGE_TYPE_AOE)
    target << span_damage("A chaos trap damages you for [damage]!")

/datum/chaos_trap/proc/apply_sanity_drain(mob/living/target)
    if(!target || !sanity_drain)
        return
    
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_SANITY), list(value = -sanity_drain, duration = 10 SECONDS))
    target << span_eerie("A chaos trap drains your sanity!")

/datum/chaos_trap/proc/apply_distortion_increase(mob/living/target)
    if(!target || !distortion_increase)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(target)
    if(instance && instance.distortion)
        instance.distortion.increase_distortion(distortion_increase, "trap")
        target << span_eerie("A chaos trap increases your distortion!")

/datum/chaos_trap/proc/apply_teleport(mob/living/target)
    if(!target)
        return
    
    var/new_turf = get_random_turf_in_z(ZTRAIT_CHAOS_DIMENSION)
    if(new_turf)
        target.teleport(new_turf)
        target << span_eerie("A chaos trap teleports you!")

/datum/chaos_trap/proc/apply_stun(mob/living/target)
    if(!target)
        return
    
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_SPEED), list(value = -1, duration = 3 SECONDS))
    target << span_notice("A chaos trap stuns you!")

/datum/chaos_trap/proc/process_trap()
    if(!is_active || triggered)
        return
    
    if(cooldown > world.time)
        return
    
    for(var/mob/living/target in range(trigger_range, get_turf(src)))
        if(prob(20))
            activate_trap(target)

/datum/chaos_trap/proc/reset_trap()
    triggered = FALSE

/datum/chaos_trap/proc/deactivate_trap()
    is_active = FALSE

/datum/chaos_trap/proc/reactivate_trap()
    is_active = TRUE
    reset_trap()

// Specific trap types
/datum/chaos_trap/distortion_burst
    name = "Distortion Burst Trap"
    trigger_type = "distortion"
    distortion_increase = 5
    damage = 5

/datum/chaos_trap/sanity_siphon
    name = "Sanity Siphon Trap"
    trigger_type = "sanity"
    sanity_drain = 2
    damage = 3

/datum/chaos_trap/chaos_mine
    name = "Chaos Mine"
    trigger_type = "combined"
    damage = 15
    sanity_drain = 1
    distortion_increase = 3

/datum/chaos_trap/teleport_pad
    name = "Teleport Pad Trap"
    trigger_type = "teleport"

/datum/chaos_trap/stun_spire
    name = "Stun Spire Trap"
    trigger_type = "stun"
    damage = 10

/datum/chaos_trap/Initialize(mapload)
    . = ..()
    is_active = TRUE
    triggered = FALSE

/datum/chaos_trap/Destroy()
    is_active = FALSE
    return ..()