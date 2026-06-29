// Chaos Gate - device for entering the chaos dimension from the station

/datum/chaos_gate
    name = "Chaos Gate"
    icon = 'icons/obj/chaos_gate.dmi'
    icon_state = "chaos_gate"
    state = CHAOS_GATE_STATE_IDLE
    power_usage = 100
    max_power = 1000
    current_power = 0
    cooldown = 0
    is_online = FALSE
    var/used = FALSE

/datum/chaos_gate/proc/activate_gate(mob/living/user)
    if(state != CHAOS_GATE_STATE_IDLE || !is_online)
        user << span_warning("The Chaos Gate is [state_text()]")
        return
    
    if(cooldown > world.time)
        user << span_warning("The Chaos Gate is recharging...")
        return
    
    if(current_power < max_power * 0.5)
        user << span_warning("Not enough power to activate the Chaos Gate!")
        return
    
    state = CHAOS_GATE_STATE_ACTIVE
    used = TRUE
    cooldown = world.time + 2 MINUTES
    
    user << span_notice("The Chaos Gate activates, swirling with chaotic energy!")
    user << span_eerie("Step through if you dare...")
    
    create_chaos_instance(user)

/datum/chaos_gate/proc/create_chaos_instance(mob/living/user)
    if(!user)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.create_instance(user)
    if(instance)
        user.teleport(0, 0, ZTRAIT_CHAOS_DIMENSION)
        user << span_notice("You have entered the Chaos Dimension!")

/datum/chaos_gate/proc/deactivate_gate()
    state = CHAOS_GATE_STATE_IDLE
    used = FALSE

/datum/chaos_gate/proc/set_state(new_state)
    state = new_state
    
    switch(state)
        if(CHAOS_GATE_STATE_IDLE)
            icon_state = "chaos_gate"
        if(CHAOS_GATE_STATE_ACTIVE)
            icon_state = "chaos_gate_active"
        if(CHAOS_GATE_STATE_OVERHEAT)
            icon_state = "chaos_gate_overheat"

/datum/chaos_gate/proc/state_text()
    switch(state)
        if(CHAOS_GATE_STATE_IDLE)
            return "idle"
        if(CHAOS_GATE_STATE_ACTIVE)
            return "active"
        if(CHAOS_GATE_STATE_OVERHEAT)
            return "overheated"
    return "unknown"

/datum/chaos_gate/proc/proc/process_gate()
    if(!is_online)
        return
    
    if(state == CHAOS_GATE_STATE_ACTIVE && used)
        if(cooldown <= world.time)
            set_state(CHAOS_GATE_STATE_IDLE)
    
    if(current_power > 0)
        current_power -= 1
    else
        set_state(CHAOS_GATE_STATE_OVERHEAT)

/datum/chaos_gate/proc/power_up(amount)
    current_power = min(current_power + amount, max_power)
    if(current_power >= max_power * 0.5 && state == CHAOS_GATE_STATE_OVERHEAT)
        set_state(CHAOS_GATE_STATE_IDLE)

/datum/chaos_gate/Initialize(mapload)
    . = ..()
    is_online = TRUE
    current_power = max_power

/datum/chaos_gate/Destroy()
    is_online = FALSE
    return ..()