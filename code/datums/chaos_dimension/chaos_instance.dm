// Chaos Dimension Instance - personal instance for each traveler

/datum/chaos_instance
    var/mob/living/traveler
    var/state = CHAOS_INSTANCE_STATE_ACTIVE
    var/datum/chaos_distortion/distortion
    var/list/visited_rooms = list()
    var/list/current_room = null
    var/is_generating = FALSE
    var/last_room_change = 0
    var/list/active_entities = list()
    var/list/collected_artifacts = list()
    var/room_count = 0
    var/is_boss_round = FALSE
    var/next_boss_room = 0

/datum/chaos_instance/proc/create_initial_room()
    if(IS_BOUNDED_ZLEVEL(get_z(traveler)))
        return
    
    distortion = new /datum/chaos_distortion()
    distortion.traveler = traveler
    distortion.start()
    
    current_room = create_new_room()
    if(current_room)
        teleport_to_room(current_room)
        visited_rooms += current_room
        room_count++
        calculate_next_boss()

/datum/chaos_instance/proc/create_new_room()
    var/list/template = null
    
    if(is_boss_round)
        template = get_boss_room_template()
        is_boss_round = FALSE
    else
        template = get_random_room_template()
    
    if(!template)
        template = get_random_room_template()
    
    if(!template)
        return null
    
    var/datum/chaos_room/new_room = new /datum/chaos_room()
    new_room.instance = src
    new_room.template = template
    new_room.initialize()
    
    return new_room

/datum/chaos_instance/proc/get_random_room_template()
    var/list/templates = list(
        "_maps/chaosdimension/room_cold_01.dmm",
        "_maps/chaosdimension/room_cold_02.dmm",
        "_maps/chaosdimension/room_cold_03.dmm",
        "_maps/chaosdimension/room_cold_04.dmm",
        "_maps/chaosdimension/room_cold_05.dmm",
        "_maps/chaosdimension/room_cold_06.dmm",
        "_maps/chaosdimension/room_cold_07.dmm",
        "_maps/chaosdimension/room_cold_08.dmm",
        "_maps/chaosdimension/room_cold_09.dmm",
        "_maps/chaosdimension/room_cold_10.dmm",
        "_maps/chaosdimension/room_cold_11.dmm",
        "_maps/chaosdimension/room_cold_12.dmm",
        "_maps/chaosdimension/room_cold_13.dmm",
        "_maps/chaosdimension/room_cold_14.dmm",
        "_maps/chaosdimension/room_cold_15.dmm",
        "_maps/chaosdimension/room_warm_01.dmm",
        "_maps/chaosdimension/room_warm_02.dmm",
        "_maps/chaosdimension/room_warm_03.dmm",
        "_maps/chaosdimension/room_warm_04.dmm",
        "_maps/chaosdimension/room_warm_05.dmm",
        "_maps/chaosdimension/room_warm_06.dmm",
        "_maps/chaosdimension/room_warm_07.dmm",
        "_maps/chaosdimension/room_warm_08.dmm",
        "_maps/chaosdimension/room_warm_09.dmm",
        "_maps/chaosdimension/room_warm_10.dmm",
        "_maps/chaosdimension/room_warm_11.dmm",
        "_maps/chaosdimension/room_warm_12.dmm",
        "_maps/chaosdimension/room_warm_13.dmm",
        "_maps/chaosdimension/room_warm_14.dmm",
        "_maps/chaosdimension/room_warm_15.dmm",
        "_maps/chaosdimension/room_empty_01.dmm",
        "_maps/chaosdimension/room_empty_02.dmm",
        "_maps/chaosdimension/room_empty_03.dmm",
        "_maps/chaosdimension/room_empty_04.dmm",
        "_maps/chaosdimension/room_empty_05.dmm",
        "_maps/chaosdimension/room_empty_06.dmm",
        "_maps/chaosdimension/room_empty_07.dmm",
        "_maps/chaosdimension/room_empty_08.dmm",
        "_maps/chaosdimension/room_empty_09.dmm",
        "_maps/chaosdimension/room_empty_10.dmm",
        "_maps/chaosdimension/room_empty_11.dmm",
        "_maps/chaosdimension/room_empty_12.dmm",
        "_maps/chaosdimension/room_empty_13.dmm",
        "_maps/chaosdimension/room_empty_14.dmm",
        "_maps/chaosdimension/room_empty_15.dmm"
    )
    
    if(templates.len == 0)
        return null
    
    return templates[rand(1, templates.len)]

/datum/chaos_instance/proc/get_boss_room_template()
    var/list/templates = list(
        "_maps/chaosdimension/boss_room_01.dmm",
        "_maps/chaosdimension/boss_room_02.dmm",
        "_maps/chaosdimension/boss_room_03.dmm",
        "_maps/chaosdimension/boss_room_04.dmm"
    )
    
    if(templates.len == 0)
        return null
    
    return templates[rand(1, templates.len)]

/datum/chaos_instance/proc/calculate_next_boss()
    next_boss_room = room_count + rand(CHAOS_BOSS_INTERVAL_MIN, CHAOS_BOSS_INTERVAL_MAX)

/datum/chaos_instance/proc/check_boss_round()
    if(room_count >= next_boss_room)
        is_boss_round = TRUE
        calculate_next_boss()

/datum/chaos_instance/proc/teleport_to_room(room)
    if(!room || !traveler)
        return
    
    var/z = get_z(traveler)
    var/old_x = traveler.x
    var/old_y = traveler.y
    
    traveler.teleport(0, 0, ZTRAIT_CHAOS_DIMENSION)
    
    if(current_room)
        current_room.remove_traveler(traveler)
    
    current_room = room
    room.add_traveler(traveler)
    
    last_room_change = world.time

/datum/chaos_instance/proc/enter_room(new_room)
    if(current_room)
        current_room.remove_traveler(traveler)
    
    current_room = new_room
    visited_rooms += new_room
    room_count++
    
    teleport_to_room(new_room)
    check_boss_round()
    
    new_room.spawn_entities()
    new_room.spawn_loot()

/datum/chaos_instance/proc/check_transformation()
    if(distortion && distortion.distortion >= CHAOS_DISTORTION_MAX)
        if(state != CHAOS_INSTANCE_STATE_TRANSFORMED)
            state = CHAOS_INSTANCE_STATE_TRANSFORMED
            trigger_transformation()

/datum/chaos_instance/proc/trigger_transformation()
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = CHAOS_DISTORTION_MAX, action = "transform"))
        traveler << span_notice("[CHAOS_DIMENSION_NAME]: You have been transformed into a chaos entity!")

/datum/chaos_instance/proc/exit_chaos()
    state = CHAOS_INSTANCE_STATE_EXITED
    if(distortion)
        distortion.stop()
    
    if(current_room)
        current_room.remove_traveler(traveler)
    
    if(traveler)
        traveler.teleport(0, 0, 0)
    
    qdel(src)

/datum/chaos_instance/proc/process()
    if(state != CHAOS_INSTANCE_STATE_ACTIVE)
        return
    
    if(distortion)
        distortion.tick()
    
    if(current_room)
        current_room.process()
    
    check_transformation()

/datum/chaos_instance/New(mob/living/trav, template)
    traveler = trav
    . = ..()
    create_initial_room()

/datum/chaos_instance/Destroy()
    if(distortion)
        distortion.stop()
    state = CHAOS_INSTANCE_STATE_EXITED
    return ..()