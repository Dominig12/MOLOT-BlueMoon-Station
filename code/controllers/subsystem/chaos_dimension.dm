// Chaos Dimension Subsystem

/datum/controller/subsystem/chaos_dimension/proc/initialize_chaos_dimension()
    global.chaos_dimension_initialized = TRUE

/datum/controller/subsystem/chaos_dimension/proc/create_instance(mob/living/traveler)
    var/datum/chaos_instance/instance = new /datum/chaos_instance(traveler)
    global.chaos_instances += instance
    return instance

/datum/controller/subsystem/chaos_dimension/proc/remove_instance(datum/chaos_instance/instance)
    if(global.chaos_instances)
        global.chaos_instances -= instance
    qdel(instance)

/datum/controller/subsystem/chaos_dimension/proc/get_instance_for_traveler(mob/living/traveler)
    if(global.chaos_instances)
        for(var/datum/chaos_instance/instance in global.chaos_instances)
            if(instance.traveler == traveler)
                return instance
    return null

/datum/controller/subsystem/chaos_dimension/proc/exit_all_travelers()
    if(global.chaos_instances)
        for(var/datum/chaos_instance/instance in global.chaos_instances)
            if(instance.state == CHAOS_INSTANCE_STATE_ACTIVE)
                instance.exit_chaos()

/datum/controller/subsystem/chaos_dimension/proc/get_active_instance_count()
    var/count = 0
    if(global.chaos_instances)
        for(var/datum/chaos_instance/instance in global.chaos_instances)
            if(instance.state == CHAOS_INSTANCE_STATE_ACTIVE)
                count++
    return count

SUBSYSTEM_DEF(chaos_dimension)
    name = "Chaos Dimension"
    init_order = INIT_ORDER_CHAOS_DIMENSION
    flags = SS_NO_FIRE
    wait = 2
    fire_priority = FIRE_PRIORITY_DEFAULT

/datum/controller/subsystem/chaos_dimension/Initialize()
    . = ..()
    initialize_chaos_dimension()

/datum/controller/subsystem/chaos_dimension/process()
    . = ..()
    
    if(global.chaos_instances)
        for(var/datum/chaos_instance/instance in global.chaos_instances)
            instance.process()