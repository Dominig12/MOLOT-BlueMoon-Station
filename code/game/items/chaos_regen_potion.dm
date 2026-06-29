// Chaos Regen Potion - item for reducing distortion

/datum/chaos_regen_potion
    name = "Chaos Regen Potion"
    icon = 'icons/item/chaos_regen_potion.dmi'
    icon_state = "chaos_regen_potion"
    distortion_reduction = 10
    sanity_restore = 2
    is_active = TRUE

/datum/chaos_regen_potion/proc/use_potion(mob/living/user)
    if(!user || !is_active)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(user)
    if(instance && instance.distortion)
        instance.distortion.decrease_distortion(distortion_reduction, "regen_potion")
        user << span_notice("The Chaos Regen Potion reduces your distortion by [distortion_reduction]!")
    
    user.SendSignal(user, list(CHAOS_SIG_MODIFY_SANITY), list(value = sanity_restore, duration = 10 SECONDS))
    user << span_notice("The potion soothes your mind.")
    
    qdel(src)

/datum/chaos_regen_potion/Initialize(mapload)
    . = ..()
    is_active = TRUE

/datum/chaos_regen_potion/Destroy()
    is_active = FALSE
    return ..()