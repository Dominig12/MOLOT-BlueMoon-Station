// Chaos Material Entities - beasts, aberrations, bosses

// Base material entity
/datum/chaos_entity/material
    var/health = CHAOS_ENTITY_HEALTH_NORMAL
    var/max_health = CHAOS_ENTITY_HEALTH_NORMAL
    var/damage = CHAOS_ENTITY_DAMAGE_NORMAL
    var/damage_type = CHAOS_DAMAGE_TYPE_MELEE
    var/turf/current_turf
    var/state = ENTITY_ALIVE
    var/is_hostile = TRUE
    var/aggro_range = 5
    var/move_speed = 1
    var/attack_cooldown = 0
    var/datum/chaos_instance/instance

/datum/chaos_entity/material/proc/attack(mob/living/target)
    if(!target || state != ENTITY_ALIVE || attack_cooldown > world.time)
        return
    
    var/damage_dealt = damage + rand(-5, 5)
    target.plussign_take_damage(damage_dealt, CHAOS_DAMAGE_TYPE_AOE)
    attack_cooldown = world.time + 5 SECONDS
    
    target << span_damage("[name] attacks you for [damage_dealt] damage!")

/datum/chaos_entity/material/proc/aoe_attack(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    for(var/mob/living/aoe_target in range(2, get_turf(target)))
        if(aoe_target != target)
            aoe_target.plussign_take_damage(damage / 2, CHAOS_DAMAGE_TYPE_AOE)

/datum/chaos_entity/material/proc/ranged_attack(mob/living/target)
    if(!target || state != ENTITY_ALIVE || attack_cooldown > world.time)
        return
    
    var/projectile = new /obj/projectile/chaos_energy()
    projectile.target = target
    projectile.damage = damage
    projectile.start(get_turf(src), target)
    attack_cooldown = world.time + 8 SECONDS

/datum/chaos_entity/material/proc/process_material()
    if(state != ENTITY_ALIVE)
        return
    
    if(attack_cooldown > world.time)
        attack_cooldown = max(0, attack_cooldown - 1 SECONDS)
    
    if(prob(10))
        move_random()
    
    for(var/mob/living/target in range(aggro_range, current_turf))
        if(!target.pod_world)
            attack(target)

/datum/chaos_entity/material/proc/apply_damage_effect(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    switch(damage_type)
        if(CHAOS_DAMAGE_TYPE_MELEE)
            target.SendSignal(target, list(CHAOS_SIG_MODIFY_REGEN), list(value = -0.2, duration = 10 SECONDS))
        if(CHAOS_DAMAGE_TYPE_RANGED)
            target.SendSignal(target, list(CHAOS_SIG_MODIFY_SPEED), list(value = -0.1, duration = 5 SECONDS))
        if(CHAOS_DAMAGE_TYPE_AOE)
            target.SendSignal(target, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = 2, source = "aoe_impact"))
        if(CHAOS_DAMAGE_TYPE_SANITY)
            target.SendSignal(target, list(CHAOS_SIG_MODIFY_SANITY), list(value = -1, source = "sanity_drain"))
        if(CHAOS_DAMAGE_TYPE_DISTORTION)
            target.SendSignal(target, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = 5, source = "distortion_pulse"))

/datum/chaos_entity/material/proc/take_damage(amount)
    if(state != ENTITY_ALIVE)
        return
    
    health -= amount
    if(health <= 0)
        on_death()

/datum/chaos_entity/material/proc/on_death()
    state = ENTITY_DEAD
    drop_loot()
    qdel(src)

/datum/chaos_entity/material/proc/drop_loot()
    if(instance)
        var/turf/loot_turf = current_turf
        if(loo_turf)
            if(prob(30))
                new /obj/item/chaos_regen_potion(loot_turf)
            if(prob(10))
                new /obj/item/chaos_artifact(loot_turf)

/datum/chaos_entity/material/proc/move_random()
    if(state != ENTITY_ALIVE)
        return
    
    var/turf/new_turf = get_random_adjacent_turf(current_turf)
    if(new_turf)
        current_turf = new_turf

/datum/chaos_entity/material/beast
    name = "Chaos Beast"
    health = CHAOS_ENTITY_HEALTH_NORMAL
    max_health = CHAOS_ENTITY_HEALTH_NORMAL
    damage = CHAOS_ENTITY_DAMAGE_NORMAL
    damage_type = CHAOS_DAMAGE_TYPE_MELEE
    aggro_range = 4
    move_speed = 1

/datum/chaos_entity/material/beast/proc/charge(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    if(prob(20))
        target.SendSignal(target, list(CHAOS_SIG_MODIFY_SPEED), list(value = -0.5, duration = 3 SECONDS))
        target << span_notice("[name] charges at you, knocking you back!")

/datum/chaos_entity/material/beast/proc/bite(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    target.plussign_take_damage(damage * 1.5, CHAOS_DAMAGE_TYPE_MELEE)
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = 3, source = "beast_bite"))

/datum/chaos_entity/material/aberration
    name = "Chaos Aberration"
    health = CHAOS_ENTITY_HEALTH_NORMAL * 1.5
    max_health = CHAOS_ENTITY_HEALTH_NORMAL * 1.5
    damage = CHAOS_ENTITY_DAMAGE_NORMAL * 1.2
    damage_type = CHAOS_DAMAGE_TYPE_RANGED
    aggro_range = 6
    move_speed = 0.8

/datum/chaos_entity/material/aberration/proc/shoot(mob/living/target)
    if(!target || state != ENTITY_ALIVE)
        return
    
    ranged_attack(target)
    target << span_notice("[name] fires a distortion bolt at you!")

/datum/chaos_entity/material/aberration/proc/teleport()
    if(state != ENTITY_ALIVE)
        return
    
    if(prob(15))
        var/turf/new_turf = get_random_turf_in_z(ZTRAIT_CHAOS_DIMENSION)
        if(new_turf)
            current_turf = new_turf
            for(var/mob/living/target in range(2, current_turf))
                target << span_eerie("[name] teleports behind you!")

/datum/chaos_entity/material/boss
    name = "Chaos Boss"
    health = CHAOS_ENTITY_HEALTH_BOSS
    max_health = CHAOS_ENTITY_HEALTH_BOSS
    damage = CHAOS_ENTITY_DAMAGE_BOSS
    damage_type = CHAOS_DAMAGE_TYPE_AOE
    aggro_range = 8
    move_speed = 0.6
    is_hostile = TRUE
    phase = 1

/datum/chaos_entity/material/boss/proc/phase_transition()
    if(state != ENTITY_ALIVE)
        return
    
    if(health < max_health * 0.5 && phase == 1)
        phase = 2
        damage = CHAOS_ENTITY_DAMAGE_BOSS * 1.5
        aggro_range = 10
        move_speed = 0.8
        for(var/mob/living/target in world)
            target << span_notice("[name] enters Phase 2! The chaos intensifies!")

/datum/chaos_entity/material/boss/proc/summin_minions()
    if(state != ENTITY_ALIVE || phase != 2)
        return
    
    if(prob(10))
        for(var/i in 1 to 3)
            var/turf/spawn_turf = get_random_turf_in_z(ZTRAIT_CHAOS_DIMENSION)
            if(spawn_turf)
                new /datum/chaos_entity/material/beast(spawn_turf)

/datum/chaos_entity/material/boss/proc/ultimate_attack()
    if(state != ENTITY_ALIVE || phase != 2)
        return
    
    for(var/mob/living/target in range(10, current_turf))
        target.plussign_take_damage(damage, CHAOS_DAMAGE_TYPE_AOE)
        target.SendSignal(target, list(CHAOS_SIG_MODIFY_SANITY), list(value = -CHAOS_SANITY_MOD_CRITICAL, duration = 10 SECONDS))
        target.SendSignal(target, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = 10, source = "boss_ultimate"))
        target << span_notice("[name] unleashes a devastating chaos wave!")

/datum/chaos_entity/material/boss/proc/on_death()
    state = ENTITY_DEAD
    for(var/mob/living/victim in range(5, current_turf))
        victim << span_notice("[name] collapses, dissolving into chaos energy!")
        victim.SendSignal(victim, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = -10, source = "boss_defeat"))
    drop_loot()
    qdel(src)