// Chaos Ethereal Entities - ghosts, shadows, wisps

// Base ethereal entity
/datum/chaos_entity/ethereal
    var/sanity_mod = CHAOS_SANITY_MOD_LIGHT
    var/is_hostile = FALSE
    var/hallucination_chance = 10
    var/buff_type = ""
    var/debuff_type = ""
    var/duration = 30 SECONDS
    var/turf/current_turf
    var/alpha = 0.5
    var/flicker_rate = 0
    var/state = ENTITY_ALIVE

/datum/chaos_entity/ethereal/proc/modify_sanity(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_SANITY), list(value = -sanity_mod, source = type, duration = duration))

/datum/chaos_entity/ethereal/proc/trigger_hallucination(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    if(prob(hallucination_chance))
        target.SendSignal(target, list(CHAOS_SIG_HALLUCINATION), list(type = "ethereal_hallucination", duration = 10 SECONDS, intensity = 1))

/datum/chaos_entity/ethereal/proc/apply_buff(mob/living/target)
    if(!target || !buff_type || state != ENTITY_ALIVE)
        return
    
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_SPEED), list(value = 0.2, source = type, duration = duration))

/datum/chaos_entity/ethereal/proc/apply_debuff(mob/living/target)
    if(!target || !debuff_type || state != ENTITY_ALIVE)
        return
    
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_ACTIONSPEED), list(value = -0.3, source = type, duration = duration))

/datum/chaos_entity/ethereal/proc/process_ethereal()
    if(state != ENTITY_ALIVE)
        return
    
    flicker_rate++
    if(flicker_rate % 10 == 0)
        alpha = 0.3 + rand(0, 0.4)
    
    if(prob(5))
        apply_effect_to_nearby()

/datum/chaos_entity/ethereal/proc/apply_effect_to_nearby()
    for(var/mob/living/target in range(3, current_turf))
        if(prob(20))
            modify_sanity(target)
        if(prob(10))
            trigger_hallucination(target)

/datum/chaos_entity/ethereal/proc/on_destroy()
    state = ENTITY_DEAD
    qdel(src)

/datum/chaos_entity/ethereal/ghost
    name = "Ethereal Ghost"
    sanity_mod = CHAOS_SANITY_MOD_MODERATE
    hallucination_chance = 15
    buff_type = ""
    debuff_type = "fear"
    duration = 20 SECONDS

/datum/chaos_entity/ethereal/ghost/proc/appear()
    if(state != ENTITY_ALIVE)
        return
    
    for(var/mob/living/target in range(2, current_turf))
        target << span_eerie("A ghostly figure materializes before you, its hollow eyes staring into your soul...")

/datum/chaos_entity/ethereal/ghost/proc/whisper(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    var/whispers = list(
        "The ghost whispers: 'You don't belong here...'",
        "The ghost hisses: 'Feel the cold...'",
        "The ghost murmurs: 'Your sanity fades...'",
        "The ghost cries: 'Let me out...'",
        "The ghost recites: 'In the chaos, all is lost...'"
    )
    target << span_eerie(pick(whispers))

/datum/chaos_entity/ethereal/shadow
    name = "Ethereal Shadow"
    sanity_mod = CHAOS_SANITY_MOD_STRONG
    hallucination_chance = 20
    buff_type = ""
    debuff_type = "darkness"
    duration = 25 SECONDS

/datum/chaos_entity/ethereal/shadow/proc/merge_with_shadow(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    if(prob(15))
        target.SendSignal(target, list(CHAOS_SIG_MODIFY_SPEED), list(value = -0.3, source = "shadow_merge", duration = 15 SECONDS))
        target << span_eerie("You feel a shadow merge with your own, slowing your movements...")

/datum/chaos_entity/ethereal/shadow/proc/elongate()
    if(state != ENTITY_ALIVE)
        return
    
    alpha = 0.2
    for(var/mob/living/target in range(3, current_turf))
        if(prob(10))
            modify_sanity(target)

/datum/chaos_entity/ethereal/wisp
    name = "Ethereal Wisp"
    sanity_mod = CHAOS_SANITY_MOD_LIGHT
    hallucination_chance = 5
    buff_type = "luminescence"
    debuff_type = ""
    duration = 15 SECONDS

/datum/chaos_entity/ethereal/wisp/proc/flicker()
    if(state != ENTITY_ALIVE)
        return
    
    alpha = 0.5 + rand(0, 0.5)
    if(prob(30))
        move_random()

/datum/chaos_entity/ethereal/wisp/proc/glow(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    if(prob(20))
        apply_buff(target)
        target << span_notice("A wisp illuminates your path, granting you a moment of clarity...")

/datum/chaos_entity/ethereal/wisp/proc/dim()
    if(state != ENTITY_ALIVE)
        return
    
    alpha = 0.3
    sanity_mod = CHAOS_SANITY_MOD_MODERATE