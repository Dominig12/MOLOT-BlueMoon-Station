// Chaos Artifacts - items that enhance distortion and grant buffs

// Base chaos artifact
/datum/chaos_artifact
    name = "Chaos Artifact"
    icon = 'icons/item/chaos_artifact.dmi'
    icon_state = "chaos_artifact"
    artifact_type = ""
    distortion_bonus = 0
    buff_type = ""
    buff_duration = 0
    buff_value = 0
    is_active = FALSE
    var/datum/chaos_instance/linked_instance
    var/used = FALSE

/datum/chaos_artifact/proc/use_artifact(mob/living/user)
    if(!user || used)
        return
    
    if(!linked_instance)
        linked_instance = controller.chaos_dimension.get_instance_for_traveler(user)
    
    if(!linked_instance || !linked_instance.distortion)
        user << span_warning("No distortion link found!")
        return
    
    linked_instance.distortion.increase_distortion(distortion_bonus, type)
    
    if(buff_type && buff_duration)
        apply_buff(user)
    
    user << span_notice("[name] activates, [buff_description]!")
    used = TRUE

/datum/chaos_artifact/proc/apply_buff(mob/living/user)
    if(!user || !buff_type)
        return
    
    switch(buff_type)
        if(CHAOS_ARTIFACT_BUFF_SPEED)
            user.SendSignal(user, list(CHAOS_SIG_MODIFY_SPEED), list(value = buff_value, duration = buff_duration))
        if(CHAOS_ARTIFACT_BUFF_DAMAGERESIST)
            user.SendSignal(user, list(CHAOS_SIG_MODIFY_REGEN), list(value = buff_value, duration = buff_duration))
        if(CHAOS_ARTIFACT_BUFF_SANITY)
            user.SendSignal(user, list(CHAOS_SIG_MODIFY_SANITY), list(value = buff_value, duration = buff_duration))
        if(CHAOS_ARTIFACT_BUFF_DISTORTION)
            user.SendSignal(user, list(CHAOS_SIG_MODIFY_DISTORTION), list(value = buff_value, duration = buff_duration))
        if(CHAOS_ARTIFACT_BUFF_REGEN)
            user.SendSignal(user, list(CHAOS_SIG_MODIFY_REGEN), list(value = buff_value, duration = buff_duration))

/datum/chaos_artifact/proc/buff_description()
    switch(buff_type)
        if(CHAOS_ARTIFACT_BUFF_SPEED)
            return "increasing your movement speed"
        if(CHAOS_ARTIFACT_BUFF_DAMAGERESIST)
            return "boosting your damage resistance"
        if(CHAOS_ARTIFACT_BUFF_SANITY)
            return "stabilizing your sanity"
        if(CHAOS_ARTIFACT_BUFF_DISTORTION)
            return "intensifying the distortion"
        if(CHAOS_ARTIFACT_BUFF_REGEN)
            return "accelerating your regeneration"
    return "granting a mysterious power"

/datum/chaos_artifact/chaos_core
    name = "Chaos Core"
    artifact_type = "core"
    distortion_bonus = 15
    buff_type = CHAOS_ARTIFACT_BUFF_DISTORTION
    buff_duration = 30 SECONDS
    buff_value = 5

/datum/chaos_artifact/chaos_core/proc/use_artifact(mob/living/user)
    . = ..()
    if(user)
        user << span_notice("The Chaos Core pulses with raw chaotic energy!")

/datum/chaos_artifact/chaos_orb
    name = "Chaos Orb"
    artifact_type = "orb"
    distortion_bonus = 10
    buff_type = CHAOS_ARTIFACT_BUFF_SPEED
    buff_duration = 20 SECONDS
    buff_value = 0.3

/datum/chaos_artifact/chaos_orb/proc/use_artifact(mob/living/user)
    . = ..()
    if(user)
        user << span_notice("The Chaos Orb shimmers, enveloping you in chaotic energy!")

/datum/chaos_artifact/chaos_crown
    name = "Chaos Crown"
    artifact_type = "crown"
    distortion_bonus = 20
    buff_type = CHAOS_ARTIFACT_BUFF_SANITY
    buff_duration = 45 SECONDS
    buff_value = 2

/datum/chaos_artifact/chaos_crown/proc/use_artifact(mob/living/user)
    . = ..()
    if(user)
        user << span_notice("The Chaos Crown descends upon your head, granting dominion over chaos!")

/datum/chaos_artifact/chaaz_staff
    name = "Chaos Staff"
    artifact_type = "staff"
    distortion_bonus = 12
    buff_type = CHAOS_ARTIFACT_BUFF_DAMAGERESIST
    buff_duration = 30 SECONDS
    buff_value = 0.2

/datum/chaos_artifact/chaos_staff/proc/use_artifact(mob/living/user)
    . = ..()
    if(user)
        user << span_notice("The Chaos Staff crackles with arcane energy!")

/datum/chaos_artifact/chaos_gem
    name = "Chaos Gem"
    artifact_type = "gem"
    distortion_bonus = 8
    buff_type = CHAOS_ARTIFACT_BUFF_REGEN
    buff_duration = 15 SECONDS
    buff_value = 1

/datum/chaos_artifact/chaos_gem/proc/use_artifact(mob/living/user)
    . = ..()
    if(user)
        user << span_notice("The Chaos Gem glows with restorative energy!")