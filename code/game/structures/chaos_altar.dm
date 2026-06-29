// Chaos Altar - structure for regeneration in the chaos dimension

/datum/chaos_altar
    name = "Chaos Altar"
    icon = 'icons/obj/chaos_altar.dmi'
    icon_state = "chaos_altar"
    regen_rate = CHAOS_ALTAR_REGEN_RATE
    sanity_regen_rate = CHAOS_ALTAR_SANITY_REGEN_RATE
    is_active = TRUE
    power_consumption = 10
    var/datum/chaos_instance/linked_instance
    var/usage_count = 0

/datum/chaos_altar/proc/activate_altar(mob/living/user)
    if(!is_active || !user)
        return
    
    if(!linked_instance)
        linked_instance = controller.chaos_dimension.get_instance_for_traveler(user)
    
    if(!linked_instance)
        user << span_warning("Not in the Chaos Dimension!")
        return
    
    usage_count++
    
    user.plussign_heal(regen_rate * 10)
    user << span_notice("The Chaos Altar restores [regen_rate * 10] HP!")
    
    user.SendSignal(user, list(CHAOS_SIG_MODIFY_SANITY), list(value = sanity_regen_rate, duration = 10 SECONDS))
    user << span_notice("The Chaos Altar soothes your mind.")
    
    if(linked_instance && linked_instance.distortion)
        linked_instance.distortion.decrease_distortion(5, "altar")
        user << span_notice("The Chaos Altar reduces your distortion!")
    
    usage_count++

/datum/chaos_altar/proc/process_altar()
    if(!is_active)
        return
    
    for(var/mob/living/user in range(2, get_turf(src)))
        if(prob(5))
            user.plussign_heal(regen_rate)
            user.SendSignal(user, list(CHAOS_SIG_MODIFY_SANITY), list(value = sanity_regen_rate * 0.5, duration = 5 SECONDS))

/datum/chaos_altar/proc/deactivate_altar()
    is_active = FALSE

/datum/chaos_altar/proc/reactivate_altar()
    is_active = TRUE

/datum/chaos_altar/Initialize(mapload)
    . = ..()
    is_active = TRUE

/datum/chaos_altar/Destroy()
    is_active = FALSE
    return ..()