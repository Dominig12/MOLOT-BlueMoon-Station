// Chaos Distortion system - personal distortion for each traveler

/datum/chaos_distortion
    var/mob/living/traveler
    var/distortion = 0
    var/current_level = CHAOS_DISTORTION_LEVEL_1
    var/last_tick = 0
    var/is_active = FALSE
    var/list/buffed_items = list()
    var/list/debuffed_items = list()

/datum/chaos_distortion/proc/update_level()
    if(distortion <= CHAOS_DISTORTION_LEVEL_1)
        current_level = CHAOS_DISTORTION_LEVEL_1
    else if(distortion <= CHAOS_DISTORTION_LEVEL_2)
        current_level = CHAOS_DISTORTION_LEVEL_2
    else if(distortion <= CHAOS_DISTORTION_LEVEL_3)
        current_level = CHAOS_DISTORTION_LEVEL_3
    else if(distortion <= CHAOS_DISTORTION_LEVEL_4)
        current_level = CHAOS_DISTORTION_LEVEL_4
    else if(distortion <= CHAOS_DISTORTION_LEVEL_5)
        current_level = CHAOS_DISTORTION_LEVEL_5
    else
        current_level = CHAOS_DISTORTION_MAX

/datum/chaos_distortion/proc/apply_effects()
    update_level()
    
    switch(current_level)
        if(CHAOS_DISTORTION_LEVEL_1)
            apply_level_1_effects()
        if(CHAOS_DISTORTION_LEVEL_2)
            apply_level_2_effects()
        if(CHAOS_DISTORTION_LEVEL_3)
            apply_level_3_effects()
        if(CHAOS_DISTORTION_LEVEL_4)
            apply_level_4_effects()
        if(CHAOS_DISTORTION_LEVEL_5)
            apply_level_5_effects()
        if(CHAOS_DISTORTION_MAX)
            apply_level_max_effects()

/datum/chaos_distortion/proc/apply_level_1_effects()
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_REGEN), list(value = -0.1))
        if(prob(5))
            trigger_hallucination(CHAOS_DISTORTION_HALLUCINATION_LIGHT)

/datum/chaos_distortion/proc/apply_level_2_effects()
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_ACTIONSPEED), list(value = -0.2))
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_REGEN), list(value = -0.2))
        if(prob(10))
            trigger_hallucination(CHAOS_DISTORTION_HALLUCINATION_MODERATE)

/datum/chaos_distortion/proc/apply_level_3_effects()
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SPEED), list(value = -0.4))
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SANITY), list(value = -CHAOS_SANITY_MOD_STRONG))
        if(prob(15))
            trigger_hallucination(CHAOS_DISTORTION_HALLUCINATION_STRONG)

/datum/chaos_distortion/proc/apply_level_4_effects()
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SPEED), list(value = -0.6))
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SANITY), list(value = -CHAOS_SANITY_MOD_CRITICAL))
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SKILL), list(value = -0.3))
        if(prob(20))
            trigger_hallucination(CHAOS_DISTORTION_HALLUCINATION_CRITICAL)

/datum/chaos_distortion/proc/apply_level_max_effects()
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SPEED), list(value = -CHAOS_SPEED_MOD_MAXIMUM))
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SANITY), list(value = -CHAOS_SANITY_MOD_MAXIMUM))
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_SKILL), list(value = -0.5))
        if(prob(30))
            trigger_hallucination(CHAOS_DISTORTION_HALLUCINATION_MAXIMUM)
        
        if(!traveler.pod_world)
            if(prob(5))
                trigger_transformation()

/datum/chaos_distortion/proc/trigger_hallucination(hallucination_type)
    if(traveler)
        traveler.SendSignal(traveler, list(CHAOS_SIG_HALLUCINATION), list(type = hallucination_type, duration = 5 SECONDS, intensity = 1))

/datum/chaos_distortion/proc/trigger_transformation()
    if(traveler && distortion >= CHAOS_DISTORTION_MAX)
        traveler.SendSignal(traveler, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = CHAOS_DISTORTION_MAX, action = "transform"))

/datum/chaos_distortion/proc/increase_distortion(amount, source = "")
    distortion = min(distortion + amount, CHAOS_DISTORTION_MAX)
    apply_effects()
    if(traveler)
        traveler << span_notice("[CHAOS_DIMENSION_NAME]: Distortion increased by [amount] ([source])")

/datum/chaos_distortion/proc/decrease_distortion(amount, source = "")
    distortion = max(distortion - amount, 0)
    apply_effects()
    if(traveler)
        traveler << span_notice("[CHAOS_DIMENSION_NAME]: Distortion decreased by [amount] ([source])")

/datum/chaos_distortion/proc/tick()
    if(!is_active || !traveler)
        return
    
    if(world.time - last_tick >= CHAOS_DISTORTION_TICK_INTERVAL)
        increase_distortion(CHAOS_DISTORTION_TIME_PASSIVE_RATE, "time_passage")
        last_tick = world.time

/datum/chaos_distortion/proc/start()
    is_active = TRUE
    if(!traveler)
        qdel(src)

/datum/chaos_distortion/proc/stop()
    is_active = FALSE

/datum/chaos_distortion/New()
    . = ..()
    update_level()

/datum/chaos_distortion/Destroy()
    is_active = FALSE
    return ..()