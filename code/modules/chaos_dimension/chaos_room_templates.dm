// Chaos Room Templates - registration and management of room templates

/datum/chaos_room_template
    var/template_name = ""
    var/template_file = ""
    var/biome = ""
    var/list/traits = list()
    var/weight = 1
    var/is_boss = FALSE
    var/min_room_count = 0
    var/max_room_count = 0

/datum/chaos_room_template/proc/register_template(template_name, template_file, biome, weight, is_boss)
    var/datum/chaos_room_template/template = new /datum/chaos_room_template()
    template.template_name = template_name
    template.template_file = template_file
    template.biome = biome
    template.weight = weight
    template.is_boss = is_boss
    template.traits = get_biome_traits(biome)
    
    if(!global.chaos_room_templates)
        global.chaos_room_templates = list()
    
    global.chaos_room_templates += template
    return template

/datum/chaos_room_template/proc/get_biome_traits(biome)
    var/list/traits = list()
    
    switch(biome)
        if("cold")
            traits += CHAOS_ROOM_TRAIT_COLD
            traits += CHAOS_ROOM_TRAIT_FOG
        if("warm")
            traits += CHAOS_ROOM_TRAIT_WARM
            traits += CHAOS_ROOM_TRAIT_FOG
        if("empty")
            traits += CHAOS_ROOM_TRAIT_EMPTY
            traits += CHAOS_ROOM_TRAIT_RUINED
        if("boss")
            traits += CHAOS_ROOM_TRAIT_BOSS
    
    return traits

/datum/chaos_room_template/proc/get_template_for_biome(biome, is_boss_round)
    if(!global.chaos_room_templates)
        return null
    
    var/list/candidates = list()
    for(var/datum/chaos_room_template/template in global.chaos_room_templates)
        if(template.biome == biome && template.is_boss == is_boss_round)
            candidates += template
    
    if(candidates.len == 0)
        return null
    
    var/weighted_pick = pick_weighted(candidates)
    return weighted_pick

/datum/chaos_room_template/proc/pick_weighted(list/candidates)
    var/total_weight = 0
    for(var/datum/chaos_room_template/template in candidates)
        total_weight += template.weight
    
    var/roll = rand(1, total_weight)
    var/cumulative = 0
    
    for(var/datum/chaos_room_template/template in candidates)
        cumulative += template.weight
        if(roll <= cumulative)
            return template
    
    return candidates[1]

/datum/chaos_room_template/proc/register_all_templates()
    register_cold_room_templates()
    register_warm_room_templates()
    register_empty_room_templates()
    register_boss_room_templates()

/datum/chaos_room_template/proc/register_cold_room_templates()
    for(var/i in 1 to CHAOS_ROOM_COUNT_COLD)
        var/template_name = "room_cold_[i]"
        var/template_file = "_maps/chaosdimension/room_cold_[i].dmm"
        register_template(template_name, template_file, "cold", 1, FALSE)

/datum/chaos_room_template/proc/register_warm_room_templates()
    for(var/i in 1 to CHAOS_ROOM_COUNT_WARM)
        var/template_name = "room_warm_[i]"
        var/template_file = "_maps/chaosdimension/room_warm_[i].dmm"
        register_template(template_name, template_file, "warm", 1, FALSE)

/datum/chaos_room_template/proc/register_empty_room_templates()
    for(var/i in 1 to CHAOS_ROOM_COUNT_EMPTY)
        var/template_name = "room_empty_[i]"
        var/template_file = "_maps/chaosdimension/room_empty_[i].dmm"
        register_template(template_name, template_file, "empty", 1, FALSE)

/datum/chaos_room_template/proc/register_boss_room_templates()
    for(var/i in 1 to CHAOS_ROOM_COUNT_BOSS)
        var/template_name = "boss_room_[i]"
        var/template_file = "_maps/chaosdimension/boss_room_[i].dmm"
        register_template(template_name, template_file, "boss", 1, TRUE)

/datum/chaos_room_template/proc/get_all_templates()
    return global.chaos_room_templates

/datum/chaos_room_template/proc/get_templates_by_type(template_type)
    var/list/results = list()
    if(!global.chaos_room_templates)
        return results
    
    for(var/datum/chaos_room_template/template in global.chaos_room_templates)
        if(template.biome == template_type)
            results += template
    
    return results

// Initialize templates on subsystem start
/proc/initialize_chaos_room_templates()
    var/datum/chaos_room_template/template_manager = new /datum/chaos_room_template()
    template_manager.register_all_templates()

// Chaos fog boundary effect
/datum/chaos_fog
    var/fog_direction = SOUTH
    var/datum/chaos_room/parent_room
    var/opacity = 0.5
    var/is_active = TRUE

/datum/chaos_fog/proc/set_loc(turf/target)
    if(target)
        set_loc(target)

/datum/chaos_fog/proc/check_traveler(mob/living/traveler)
    if(!traveler || !is_active)
        return
    
    var/turf/t = get_turf(traveler)
    if(!t)
        return
    
    var/fog_loc = get_loc(src)
    if(!fog_loc)
        return
    
    if(t.x == fog_loc.x && t.y == fog_loc.y)
        trigger_teleport(traveler)

/datum/chaos_fog/proc/trigger_teleport(mob/living/traveler)
    if(!parent_room || !parent_room.instance)
        return
    
    var/turf/new_turf = find_opposite_turf(traveler, fog_direction)
    if(new_turf)
        traveler.teleport(new_turf)
        parent_room.instance.last_room_change = world.time

/datum/chaos_fog/proc/find_opposite_turf(mob/living/traveler, direction)
    var/z = get_z(traveler)
    var/start_x = traveler.x
    var/start_y = traveler.y
    
    switch(direction)
        if(NORTH)
            return get_turf_at_max_x(z)
        if(SOUTH)
            return get_turf_at_min_x(z)
        if(EAST)
            return get_turf_at_max_y(z)
        if(WEST)
            return get_turf_at_min_y(z)
    
    return null

/datum/chaos_fog/proc/get_turf_at_max_x(z)
    for(var/turf/t in world)
        if(get_z(t) == z)
            return t
    return null

/datum/chaos_fog/proc/get_turf_at_min_x(z)
    for(var/turf/t in world)
        if(get_z(t) == z)
            return t
    return null

/datum/chaos_fog/proc/get_turf_at_max_y(z)
    for(var/turf/t in world)
        if(get_z(t) == z)
            return t
    return null

/datum/chaos_fog/proc/get_turf_at_min_y(z)
    for(var/turf/t in world)
        if(get_z(t) == z)
            return t
    return null

// Chaos teleport zone effect
/datum/chaos_teleport_zone
    var/zone_direction = SOUTH
    var/datum/chaos_room/parent_room
    var/cooldown = 0

/datum/chaos_teleport_zone/proc/activate_zone(mob/living/traveler)
    if(!traveler || cooldown > world.time)
        return
    
    var/new_room = parent_room.instance.create_new_room()
    if(new_room)
        parent_room.instance.enter_room(new_room)
    
    cooldown = world.time + CHAOS_FOG_TELEPORT_COOLDOWN