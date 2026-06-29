// Chaos Fog - visual boundary effect for rooms

/datum/chaos_fog_effect
    name = "Chaos Fog"
    icon = 'icons/effect/chaos_fog.dmi'
    icon_state = "chaos_fog"
    opacity = 0.5
    fog_direction = SOUTH
    speed = 0
    is_active = TRUE
    var/datum/chaos_room/parent_room
    var/triggered = FALSE

/datum/chaos_fog_effect/proc/check_boundary(mob/living/traveler)
    if(!traveler || !is_active)
        return
    
    var/turf/t = get_turf(traveler)
    if(!t)
        return
    
    if(abs(t.x - get_turf(src).x) <= 1 && abs(t.y - get_turf(src).y) <= 1)
        if(!triggered)
            trigger_teleport(traveler)
            triggered = TRUE

/datum/chaos_fog_effect/proc/trigger_teleport(mob/living/traveler)
    if(!parent_room || !parent_room.instance)
        return
    
    var/new_room = parent_room.instance.create_new_room()
    if(new_room)
        parent_room.instance.enter_room(new_room)
    
    triggered = FALSE

/datum/chaos_fog_effect/proc/process_fog()
    if(!is_active)
        return
    
    opacity = 0.3 + rand(0, 0.3)
    
    for(var/mob/living/traveler in range(3, get_turf(src)))
        check_boundary(traveler)

/datum/chaos_fog_effect/Initialize(mapload)
    . = ..()
    is_active = TRUE
    opacity = 0.5