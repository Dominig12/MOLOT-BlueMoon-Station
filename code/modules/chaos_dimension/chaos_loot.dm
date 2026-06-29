// Chaos Loot Tables - loot tables for rooms

/datum/chaos_loot_table
    var/table_name = ""
    var/list/loot_items = list()
    var/weight_total = 0
    var/is_active = TRUE

/datum/chaos_loot_table/proc/add_item(item_type, weight)
    if(!is_active)
        return
    
    loot_items += list(type = item_type, weight = weight)
    weight_total += weight

/datum/chaos_loot_table/proc/pick_loot()
    if(!is_active || !weight_total)
        return null
    
    var/roll = rand(1, weight_total)
    var/cumulative = 0
    
    for(var/item in loot_items)
        cumulative += item["weight"]
        if(roll <= cumulative)
            return item["type"]
    
    return null

/datum/chaos_loot_table/proc/generate_loot(turf/spawn_loc)
    var/item_type = pick_loot()
    if(!item_type || !spawn_loc)
        return
    
    var/datum/item/new_item = new item_type(spawn_loc)
    return new_item

// Regen loot table
/datum/chaos_loot_table/regen
    table_name = "chaos_regen"
    
    New()
        . = ..()
        add_item(/datum/chaos_regen_potion, 40)
        add_item(/obj/item/chaos_regen_potion, 30)
        add_item(/obj/structure/chaos_altar, 10)
        add_item(/obj/item/reagent_containers/glass/potion, 20)

// Artifact loot table
/datum/chaos_loot_table/artifact
    table_name = "chaos_artifact"
    
    New()
        . = ..()
        add_item(/datum/chaos_artifact/chaos_core, 15)
        add_item(/datum/chaos_artifact/chaos_orb, 20)
        add_item(/datum/chaos_artifact/chaos_crown, 10)
        add_item(/datum/chaos_artifact/chaos_staff, 15)
        add_item(/datum/chaos_artifact/chaos_gem, 25)

// Core loot table
/datum/chaos_loot_table/core
    table_name = "chaos_core"
    
    New()
        . = ..()
        add_item(/datum/chaos_artifact/chaos_core, 50)
        add_item(/obj/item/chaos_core, 30)
        add_item(/obj/structure/chaos_pedestal, 20)

// Compass loot table
/datum/chaos_loot_table/compass
    table_name = "chaos_compass"
    
    New()
        . = ..()
        add_item(/datum/chaos_compass, 100)

// Potion loot table
/datum/chaos_loot_table/potion
    table_name = "chaos_potion"
    
    New()
        . = ..()
        add_item(/datum/chaos_regen_potion, 40)
        add_item(/obj/item/reagent_containers/glass/potion/distortion_decrease, 30)
        add_item(/obj/item/reagent_containers/glass/potion/sanity_restore, 20)
        add_item(/obj/item/reagent_containers/glass/potion/hallucination_cure, 10)

// Boss loot table
/datum/chaos_loot_table/boss
    table_name = "chaos_boss"
    
    New()
        . = ..()
        add_item(/datum/chaos_artifact/chaos_crown, 25)
        add_item(/datum/chaos_artifact/chaos_core, 25)
        add_item(/datum/chaos_compass, 20)
        add_item(/obj/item/chaos_core, 15)
        add_item(/obj/structure/chaos_altar, 15)

// Room loot generation
/proc/generate_room_loot(list/room_data)
    var/turf/spawn_loc = room_data["spawn_loc"]
    var/is_boss_room = room_data["is_boss"]
    
    if(!spawn_loc)
        return
    
    var/loot_table = null
    
    if(is_boss_room)
        loot_table = new /datum/chaos_loot_table/boss()
    else
        var/roll = rand(1, 100)
        if(roll <= 40)
            loot_table = new /datum/chaos_loot_table/regen()
        else if(roll <= 60)
            loot_table = new /datum/chaos_loot_table/artifact()
        else if(roll <= 80)
            loot_table = new /datum/chaos_loot_table/potion()
        else
            loot_table = new /datum/chaos_loot_table/core()
    
    if(loot_table)
        loot_table.generate_loot(spawn_loc)