// Chaos Room class - description and management of individual rooms

/datum/chaos_room/proc/load_map(map_file, x, y, z)
    if(!map_file)
        return FALSE
    
    var/list/map_data = load_map_data(map_file)
    if(!map_data)
        return FALSE
    
    var/z_level = get_z_from_data(map_data)
    if(z_level)
        z = z_level
    
    turfs = get_turfs_from_data(map_data)
    
    return TRUE

/datum/chaos_room/proc/load_map_data(map_file)
    var/list/map_instance = input_map(map_file, 0, 0, ZTRAIT_CHAOS_DIMENSION)
    return map_instance

/datum/chaos_room/proc/get_z_from_data(list/map_data)
    if(map_data && map_data["z"])
        return map_data["z"]
    return ZTRAIT_CHAOS_DIMENSION

/datum/chaos_room/proc/get_turfs_from_data(list/map_data)
    var/list/turfs_list = list()
    if(map_data && map_data["turfs"])
        turfs_list = map_data["turfs"]
    return turfs_list

/datum/chaos_room/proc/setup_boundaries()
    setup_fog_boundaries()
    setup_teleport_zones()

/datum/chaos_room/proc/setup_fog_boundaries()
    var/fog_left = new /obj/effect/chaos_fog()
    var/fog_right = new /obj/effect/chaos_fog()
    var/fog_top = new /obj/effect/chaos_fog()
    var/fog_bottom = new /obj/effect/chaos_fog()
    
    fog_left.fog_direction = NORTH
    fog_right.fog_direction = SOUTH
    fog_top.fog_direction = EAST
    fog_bottom.fog_direction = WEST
    
    fog_left.parent_room = src
    fog_right.parent_room = src
    fog_top.parent_room = src
    fog_bottom.parent_room = src

/datum/chaos_room/proc/setup_teleport_zones()
    var/zone_left = new /obj/effect/chaos_teleport_zone()
    var/zone_right = new /obj/effect/chaos_teleport_zone()
    var/zone_top = new /obj/effect/chaos_teleport_zone()
    var/zone_bottom = new /obj/effect/chaos_teleport_zone()
    
    zone_left.zone_direction = SOUTH
    zone_right.zone_direction = NORTH
    zone_top.zone_direction = WEST
    zone_bottom.zone_direction = EAST
    
    zone_left.parent_room = src
    zone_right.parent_room = src
    zone_top.parent_room = src
    zone_bottom.parent_room = src

/datum/chaos_room/proc/check_traveler_boundary(mob/living/traveler)
    if(!traveler || !instance)
        return
    
    var/turf/current_turf = get_turf(traveler)
    if(!current_turf)
        return
    
    var/room_bounds = get_room_bounds()
    if(!room_bounds)
        return
    
    var/new_room = try_teleport(traveler, current_turf, room_bounds)
    if(new_room)
        instance.enter_room(new_room)

/datum/chaos_room/proc/get_room_bounds()
    var/list/bounds = list(
        min_x = 0,
        max_x = 0,
        min_y = 0,
        max_y = 0
    )
    
    var/turf/sample = turfs[1]
    if(sample)
        var/area/sample_area = get_area(sample)
        if(sample_area)
            bounds.min_x = sample.x
            bounds.max_x = sample.x
            bounds.min_y = sample.y
            bounds.max_y = sample.y
            
            for(var/turf/t in area_turfs(sample_area))
                bounds.min_x = min(bounds.min_x, t.x)
                bounds.max_x = max(bounds.max_x, t.x)
                bounds.min_y = min(bounds.min_y, t.y)
                bounds.max_y = max(bounds.max_y, t.y)
    
    return bounds

/datum/chaos_room/proc/try_teleport(mob/living/traveler, turf/current_turf, list/bounds)
    if(!bounds || bounds.max_x <= bounds.min_x || bounds.max_y <= bounds.min_y)
        return null
    
    var/direction = get_teleport_direction(current_turf, bounds)
    if(!direction)
        return null
    
    if(world.time - instance.last_room_change < CHAOS_FOG_TELEPORT_COOLDOWN)
        return null
    
    var/new_room = instance.create_new_room()
    if(new_room)
        return new_room
    
    return null

/datum/chaos_room/proc/get_teleport_direction(turf/t, list/bounds)
    if(t.x <= bounds.min_x + 1)
        return SOUTH
    if(t.x >= bounds.max_x - 1)
        return NORTH
    if(t.y <= bounds.min_y + 1)
        return WEST
    if(t.y >= bounds.max_y - 1)
        return EAST
    
    return null

/datum/chaos_room/proc/activate()
    is_initialized = TRUE
    spawn_entities()
    spawn_loot()

/datum/chaos_room/proc/deactivate()
    is_initialized = FALSE
    for(var/datum/chaos_entity/entity in entities)
        entity.on_destroy()
    entities = list()
    loot = list()
    traps = list()