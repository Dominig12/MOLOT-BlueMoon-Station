// Chaos Transformation - mob → chaos entity

/datum/chaos_transformed
    name = "Chaos Entity (Transformed)"
    icon = 'icons/mob/chaos_transformed.dmi'
    icon_state = "chaos_transformed"
    health = 100
    max_health = 100
    damage = 15
    movement_speed = 0.8
    sanity_mod = CHAOS_SANITY_MOD_CRITICAL
    distortion_mod = CHAOS_DISTORTION_LEVEL_5
    is_chaos_entity = TRUE
    var/datum/chaos_instance/instance
    var/phase = 1

/datum/chaos_transformed/proc/transform(mob/living/original_mob)
    if(!original_mob)
        return
    
    // Copy attributes from original mob
    health = original_mob.health
    max_health = original_mob.max_health
    
    // Apply chaos modifiers
    original_mob.SendSignal(original_mob, list(CHAOS_SIG_MODIFY_SPEED), list(value = -0.2, duration = -1))
    original_mob.SendSignal(original_mob, list(CHAOS_SIG_MODIFY_SANITY), list(value = -CHAOS_SANITY_MOD_CRITICAL, duration = -1))
    original_mob.SendSignal(original_mob, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = CHAOS_DISTORTION_MAX, action = "transform"))
    
    original_mob << span_notice("You transform into a chaos entity!")
    original_mob << span_eerie("Your body twists and contorts, becoming one with the chaos...")
    
    // Create instance if not exists
    if(!instance)
        instance = controller.chaos_dimension.get_instance_for_traveler(original_mob)
    
    phase = 1

/datum/chaos_transformed/proc/attack(mob/living/target)
    if(!target)
        return
    
    target.plussign_take_damage(damage, CHAOS_DAMAGE_TYPE_AOE)
    target.SendSignal(target, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = 3, source = "chaos_entity_attack"))
    target << span_damage("The chaos entity attacks you!")

/datum/chaos_transformed/proc/process_entity()
    if(phase == 1 && health < max_health * 0.5)
        phase = 2
        damage = 20
        movement_speed = 1.0
    
    if(prob(5))
        move_random()

/datum/chaos_transformed/proc/revert(mob/living/original_mob)
    if(!original_mob)
        return
    
    original_mob.SendSignal(original_mob, list(CHAOS_SIG_MODIFY_SPEED), list(value = 0.2, duration = 30 SECONDS))
    original_mob << span_notice("The chaos entity reverts to its original form!")

// Transformation handler
/proc/handle_transformation(mob/living/mob_user, datum/chaos_distortion/distortion)
    if(!mob_user || !distortion)
        return
    
    if(distortion.distortion >= CHAOS_DISTORTION_MAX)
        if(!mob_user.pod_world)
            var/datum/chaos_transformed/transformed = new /datum/chaos_transformed()
            transformed.transform(mob_user)
            mob_user.chaos_entity = transformed

// Admin tools for chaos dimension
/proc/admin_enter_chaos(mob/living/admin, mob/living/target)
    if(!target)
        target = admin
    
    if(controller.chaos_dimension.get_instance_for_traveler(target))
        admin << span_notice("[target.name] is already in the Chaos Dimension!")
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.create_instance(target)
    if(instance)
        target.teleport(0, 0, ZTRAIT_CHAOS_DIMENSION)
        admin << span_notice("[target.name] has been sent to the Chaos Dimension!")
        target << span_notice("You have been sent to the Chaos Dimension by [admin.name]!")

/proc/admin_exit_chaos(mob/living/admin, mob/living/target)
    if(!target)
        target = admin
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(target)
    if(!instance)
        admin << span_notice("[target.name] is not in the Chaos Dimension!")
        return
    
    instance.exit_chaos()
    admin << span_notice("[target.name] has been returned from the Chaos Dimension!")
    target << span_notice("You have been returned from the Chaos Dimension by [admin.name]!")

/proc/admin_teleport_chaos(mob/living/admin, mob/living/target, target_room)
    if(!target)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(target)
    if(!instance)
        admin << span_notice("[target.name] is not in the Chaos Dimension!")
        return
    
    if(target_room)
        // Teleport to specific room
        target.teleport(target_room)
        admin << span_notice("[target.name] has been teleported to room [target_room]!")
    else
        // Teleport to new room
        var/new_room = instance.create_new_room()
        if(new_room)
            instance.enter_room(new_room)
            admin << span_notice("[target.name] has been teleported to a new room!")

/proc/admin_set_distortion(mob/living/admin, mob/living/target, amount)
    if(!target)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(target)
    if(!instance || !instance.distortion)
        admin << span_notice("[target.name] has no distortion in the Chaos Dimension!")
        return
    
    instance.distortion.distortion = amount
    instance.distortion.apply_effects()
    admin << span_notice("[target.name]'s distortion has been set to [amount]!")

/proc/admin_chaos_info(mob/living/admin, mob/living/target)
    if(!target)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(target)
    if(!instance)
        admin << span_notice("[target.name] is not in the Chaos Dimension!")
        return
    
    admin << span_notice("--- Chaos Dimension Info for [target.name] ---")
    admin << span_notice("State: [instance.state]")
    admin << span_notice("Rooms visited: [instance.room_count]")
    admin << span_notice("Distortion: [instance.distortion?.distortion || 0]")
    admin << span_notice("Artifacts collected: [instance.collected_artifacts?.len || 0]")
    admin << span_notice("Boss round: [instance.is_boss_round]")

// HUD display for distortion
/proc/update_chaos_hud(mob/living/mob_user)
    if(!mob_user)
        return
    
    var/datum/chaos_instance/instance = controller.chaos_dimension.get_instance_for_traveler(mob_user)
    if(!instance || !instance.distortion)
        return
    
    var/distortion_value = instance.distortion.distortion
    var/distortion_level = instance.distortion.current_level
    
    // Update HUD with distortion meter
    mob_user.send_chaos_distortion_hud(distortion_value, distortion_level)

// HUD proc for mob
/mob/living/proc/send_chaos_distortion_hud(distortion_value, distortion_level)
    var/hud_message = list(
        type = "chaos_distortion",
        distortion = distortion_value,
        level = distortion_level,
        color = CHAOS_UI_COLOR_DISTORTION,
        name = CHAOS_DIMENSION_NAME
    )
    
    // Send to client HUD
    if(client)
        client.send_hud_message(hud_message)