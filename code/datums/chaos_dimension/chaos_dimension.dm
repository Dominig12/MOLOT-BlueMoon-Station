// Chaos Dimension base types and subsystem

// Chaos Dimension Subsystem
PROCESSING_SUBSYSTEM_DEF(SSchaosdimension)
    name = "Chaos Dimension"
    flags = SS_BACKGROUND | SS_KEEP_TIMING
    wait = 1 SECONDS
    fire_priority = FIRE_PRIORITY_DEFAULT

/datum/controller/subsystem/proc/initialize_chaos_dimension()
    global.chaos_dimension_initialized = TRUE

/datum/controller/subsystem/process()
    . = ..()
    
    for(var/datum/chaos_instance/instance in global.chaos_instances)
        instance.process()

// Chaos room data type
/datum/chaos_room
    var/template = ""
    var/datum/chaos_instance/instance
    var/z_level = ZTRAIT_CHAOS_DIMENSION
    var/list/turfs = list()
    var/list/entities = list()
    var/list/loot = list()
    var/list/traps = list()
    var/is_initialized = FALSE
    var/biome = ""
    var/list/trait = list()

/datum/chaos_room/proc/initialize()
    IS_BOUNDED_ZLEVEL(z_level)
    
    template = get_room_template()
    biome = get_room_biome()
    trait = get_room_traits()
    
    load_room_template()
    setup_boundaries()
    
    is_initialized = TRUE

/datum/chaos_room/proc/get_room_template()
    if(instance)
        if(instance.is_boss_round)
            return instance.get_boss_room_template()
        return instance.get_random_room_template()
    return "_maps/chaosdimension/room_cold_01.dmm"

/datum/chaos_room/proc/get_room_biome()
    switch(template)
        if("*cold*")
            return "cold"
        if("*warm*")
            return "warm"
        if("*empty*")
            return "empty"
        if("*boss*")
            return "boss"
        default:
            return "random"

/datum/chaos_room/proc/get_room_traits()
    var/list/traits = list()
    traits += ZTRAIT_CHAOS_DIMENSION
    
    if(biome == "cold")
        traits += CHAOS_ROOM_TRAIT_COLD
    else if(biome == "warm")
        traits += CHAOS_ROOM_TRAIT_WARM
    else if(biome == "empty")
        traits += CHAOS_ROOM_TRAIT_EMPTY
    else if(biome == "boss")
        traits += CHAOS_ROOM_TRAIT_BOSS
    
    if(prob(50))
        traits += CHAOS_ROOM_TRAIT_FOG
    
    if(biome == "empty")
        traits += CHAOS_ROOM_TRAIT_RUINED
    
    return traits

/datum/chaos_room/proc/load_room_template()
    var/map_file = template
    if(map_file)
        load_map(map_file, 0, 0, z_level)

/datum/chaos_room/proc/setup_boundaries()
    var/fog_left = new /obj/effect/chaos_fog()
    var/fog_right = new /obj/effect/chaos_fog()
    var/fog_top = new /obj/effect/chaos_fog()
    var/fog_bottom = new /obj/effect/chaos_fog()
    
    fog_left.set_loc(get_turf_at_edge("left"))
    fog_right.set_loc(get_turf_at_edge("right"))
    fog_top.set_loc(get_turf_at_edge("top"))
    fog_bottom.set_loc(get_turf_at_edge("bottom"))

/datum/chaos_room/proc/get_turf_at_edge(edge)
    switch(edge)
        if("left")
            return get_turf_in_direction(1, 0)
        if("right")
            return get_turf_in_direction(-1, 0)
        if("top")
            return get_turf_in_direction(0, 1)
        if("bottom")
            return get_turf_in_direction(0, -1)
    return null

/datum/chaos_room/proc/get_turf_in_direction(dx, dy)
    for(var/turf/t in all_turfs())
        if(t.x == 1 && dx < 0) return t
        if(t.x == max_x && dx > 0) return t
        if(t.y == 1 && dy < 0) return t
        if(t.y == max_y && dy > 0) return t
    return null

/datum/chaos_room/proc/add_traveler(mob/living/traveler)
    if(!is_initialized)
        return
    
    setup_traveler_spawn(traveler)

/datum/chaos_room/proc/setup_traveler_spawn(mob/living/traveler)
    var/safe_turf = find_safe_turf()
    if(safe_turf)
        traveler.teleport(safe_turf)

/datum/chaos_room/proc/remove_traveler(mob/living/traveler)
    traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = 0, action = "room_exit"))

/datum/chaos_room/proc/find_safe_turf()
    for(var/turf/safe in turfs)
        if(!get_mob_at_turf(safe))
            return safe
    return null

/datum/chaos_room/proc/spawn_entities()
    if(!is_initialized)
        return
    
    spawn_ethereal_entities()
    spawn_material_entities()

/datum/chaos_room/proc/spawn_ethereal_entities()
    if(instance && instance.is_boss_round)
        return
    
    if(prob(60))
        var/entity_type = rand(1, 3)
        var/turf/spawn_turf = find_safe_turf()
        if(spawn_turf)
            switch(entity_type)
                if(1)
                    new /datum/chaos_entity/ethereal/ghost(spawn_turf)
                if(2)
                    new /datum/chaos_entity/ethereal/shadow(spawn_turf)
                if(3)
                    new /datum/chaos_entity/ethereal/wisp(spawn_turf)

/datum/chaos_room/proc/spawn_material_entities()
    if(instance && instance.is_boss_round)
        spawn_boss_entity()
        return
    
    if(prob(30))
        var/entity_type = rand(1, 2)
        var/turf/spawn_turf = find_safe_turf()
        if(spawn_turf)
            switch(entity_type)
                if(1)
                    new /datum/chaos_entity/material/beast(spawn_turf)
                if(2)
                    new /datum/chaos_entity/material/aberration(spawn_turf)

/datum/chaos_room/proc/spawn_boss_entity()
    var/turf/spawn_turf = find_safe_turf()
    if(spawn_turf)
        new /datum/chaos_entity/material/boss(spawn_turf)

/datum/chaos_room/proc/spawn_loot()
    if(!is_initialized)
        return
    
    spawn_regen_potion()
    spawn_artifact()
    spawn_altar()

/datum/chaos_room/proc/spawn_regen_potion()
    if(prob(40))
        var/turf/spawn_turf = find_safe_turf()
        if(spawn_turf)
            new /obj/item/chaos_regen_potion(spawn_turf)

/datum/chaos_room/proc/spawn_artifact()
    if(prob(15))
        var/turf/spawn_turf = find_safe_turf()
        if(spawn_turf)
            new /obj/item/chaos_artifact(spawn_turf)

/datum/chaos_room/proc/spawn_altar()
    if(prob(20))
        var/turf/spawn_turf = find_safe_turf()
        if(spawn_turf)
            new /obj/structure/chaos_altar(spawn_turf)

/datum/chaos_room/proc/process()
    if(!is_initialized)
        return
    
    process_entities()
    process_traps()
    process_whisper()

/datum/chaos_room/proc/process_entities()
    for(var/datum/chaos_entity/entity in entities)
        entity.process()

/datum/chaos_room/proc/process_traps()
    for(var/obj/effect/chaos_trap/trap in traps)
        trap.process()

/datum/chaos_room/proc/process_whisper()
    if(world.time % CHAOS_ROOM_SPAWN_WHISPER_INTERVAL == 0)
        if(prob(10))
            trigger_whisper()

/datum/chaos_room/proc/trigger_whisper()
    var/whisper_type = rand(1, 4)
    if(instance && instance.traveler)
        switch(whisper_type)
            if(1)
                instance.traveler << span_eerie("You hear a distant whisper echoing through the chaos...")
            if(2)
                instance.traveler << span_eerie("A vision flashes before your eyes - a glimpse of another dimension...")
            if(3)
                instance.traveler << span_eerie("A voice calls your name from the depths of chaos...")
            if(4)
                instance.traveler << span_eerie("A shadow passes before you, vanishing into the mist...")

// Chaos entity base type
/datum/chaos_entity
    var/turf/current_turf
    var/state = ENTITY_ALIVE
    var/datum/chaos_instance/instance
    var/entity_type = CHAOS_ENTITY_TYPE_ETHEREAL
    var/entity_subtype = ""
    var/is_hostile = FALSE

/datum/chaos_entity/proc/process()
    if(state != ENTITY_ALIVE)
        return
    
    on_process()

/datum/chaos_entity/proc/on_process()

/datum/chaos_entity/proc/on_create()

/datum/chaos_entity/proc/on_destroy()

/datum/chaos_entity/proc/apply_damage(amount, damage_type)
    if(state != ENTITY_ALIVE)
        return
    
    on_damage_taken(amount, damage_type)

/datum/chaos_entity/proc/on_damage_taken(amount, damage_type)

/datum/chaos_entity/proc/apply_effect(effect_type, duration)
    on_effect_applied(effect_type, duration)

/datum/chaos_entity/proc/on_effect_applied(effect_type, duration)