// Chaos Compass - item for exiting the chaos dimension

/datum/chaos_compass
    name = "Chaos Compass"
    icon = 'icons/item/chaos_compass.dmi'
    icon_state = "chaos_compass"
    cooldown = 0
    is_chaos_dimension = FALSE
    var/datum/chaos_instance/linked_instance
    var/last_used = 0

/datum/chaos_compass/proc/activate_compass(mob/living/user)
    if(!user)
        return
    
    if(!is_chaos_dimension)
        user << span_warning("You are not in the Chaos Dimension!")
        return
    
    if(cooldown > world.time)
        user << span_warning("The Chaos Compass is recharging...")
        return
    
    if(linked_instance && linked_instance.state == CHAOS_INSTANCE_STATE_ACTIVE)
        linked_instance.exit_chaos()
        user << span_notice("The Chaos Compass guides you back to the station!")
    
    cooldown = world.time + CHAOS_COMPASS_COOLDOWN
    last_used = world.time

/datum/chaos_compass/proc/check_chaos_dimension(mob/living/user)
    if(!user)
        return
    
    if(get_z(user) == ZTRAIT_CHAOS_DIMENSION)
        is_chaos_dimension = TRUE
    else
        is_chaos_dimension = FALSE

/datum/chaos_compass/proc/update_link(mob/living/user)
    if(!user)
        return
    
    linked_instance = controller.chaos_dimension.get_instance_for_traveler(user)

/datum/chaos_compass/proc/handle_click(mob/living/user, mob/living/point, list/params)
    if(!user)
        return
    
    check_chaos_dimension(user)
    if(is_chaos_dimension)
        update_link(user)
        activate_compass(user)
    else
        user << span_notice("The Chaos Compass points toward the Chaos Dimension...")

/datum/chaos_compass/proc/use_in_hand(mob/living/user)
    if(!user)
        return
    
    check_chaos_dimension(user)
    activate_compass(user)

/datum/chaos_compass/Initialize(mapload)
    . = ..()
    is_chaos_dimension = FALSE

/datum/chaos_compass/Destroy()
    is_chaos_dimension = FALSE
    linked_instance = null
    return ..()