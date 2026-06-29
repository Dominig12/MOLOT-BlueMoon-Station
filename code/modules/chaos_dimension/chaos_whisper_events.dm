// Chaos Whisper Events - random events in rooms

/datum/chaos_whisper_event
    var/event_name = ""
    var/event_type = 0
    var/chance = 0
    var/duration = 0
    var/is_active = TRUE
    var/mob/living/target
    var/datum/chaos_instance/instance

/datum/chaos_whisper_event/proc/trigger()
    if(!is_active || !target)
        return
    
    switch(event_type)
        if(CHAOS_WHISPER_TYPE_Eerie)
            trigger_eerie()
        if(CHAOS_WHISPER_TYPE_Vision)
            trigger_vision()
        if(CHAOS_WHISPER_TYPE_Voice)
            trigger_voice()
        if(CHAOS_WHISPER_TYPE_Shadow)
            trigger_shadow()

/datum/chaos_whisper_event/proc/trigger_eerie()
    if(!target)
        return
    
    var/eerie_messages = list(
        "You feel a chill run down your spine...",
        "The air grows cold and heavy...",
        "A sense of being watched overwhelms you...",
        "The shadows seem to stretch and twist...",
        "An unexplainable dread fills your heart...",
        "The walls whisper ancient secrets...",
        "A cold breath brushes against your neck...",
        "The ground trembles faintly beneath your feet..."
    )
    target << span_eerie(pick(eerie_messages))
    
    if(instance && instance.distortion)
        instance.distortion.increase_distortion(1, "eerie_whisper")

/datum/chaos_whisper_event/proc/trigger_vision()
    if(!target)
        return
    
    var/vision_messages = list(
        "You see a vision of a distant world - trees of crystal and rivers of light...",
        "A flash of insight shows you the path through the chaos...",
        "You glimpse another dimension - one where chaos reigns supreme...",
        "A vision of your past self walks through the mist...",
        "You see a future where the chaos consumes all...",
        "A vision of the station from afar - a tiny speck in the void..."
    )
    target << span_notice(pick(vision_messages))
    
    if(instance && instance.distortion)
        instance.distortion.decrease_distortion(2, "vision_clarity")

/datum/chaos_whisper_event/proc/trigger_voice()
    if(!target)
        return
    
    var/voice_messages = list(
        "A voice calls: 'Welcome, traveler...'",
        "You hear: 'The chaos consumes all...'",
        "A whisper: 'Find the core...'",
        "A shout: 'Run while you can...'",
        "A song: 'In the depths of chaos, find peace...'",
        "A laugh: 'You are not alone here...'",
        "A cry: 'Help me...'",
        "A command: 'Bow to the chaos...'"
    )
    target << span_eerie(pick(voice_messages))

/datum/chaos_whisper_event/proc/trigger_shadow()
    if(!target)
        return
    
    var/shadow_messages = list(
        "A shadow passes before you, vanishing into the mist...",
        "You see a figure watching from the darkness...",
        "A shadow detaches from the wall and moves away...",
        "The shadows converge into a single entity...",
        "A shadow reaches out to touch you...",
        "You see your own shadow move independently..."
    )
    target << span_eerie(pick(shadow_messages))
    
    if(instance && instance.distortion)
        instance.distortion.increase_distortion(2, "shadow_presence")

/datum/chaos_whisper_event/proc/process_event()
    if(!is_active)
        return
    
    if(prob(chance))
        trigger()

/datum/chaos_whisper_event/chaos_whisper_eerie
    event_name = "Eerie Presence"
    event_type = CHAOS_WHISPER_TYPE_Eerie
    chance = 5

/datum/chaos_whisper_event/chaos_whisper_vision
    event_name = "Chaotic Vision"
    event_type = CHAOS_WHISPER_TYPE_Vision
    chance = 3

/datum/chaos_whisper_event/chaos_whisper_voice
    event_name = "Voices of Chaos"
    event_type = CHAOS_WHISPER_TYPE_Voice
    chance = 8

/datum/chaos_whisper_event/chaos_whisper_shadow
    event_name = "Shadow Encounter"
    event_type = CHAOS_WHISPER_TYPE_Shadow
    chance = 6

// Random event system
/proc/trigger_random_chaos_event(mob/living/target, datum/chaos_instance/instance)
    if(!target || !instance)
        return
    
    var/event_type = rand(1, 4)
    var/event = null
    
    switch(event_type)
        if(1)
            event = new /datum/chaos_whisper_event/chaos_whisper_eerie()
        if(2)
            event = new /datum/chaos_whisper_event/chaos_whisper_vision()
        if(3)
            event = new /datum/chaos_whisper_event/chaos_whisper_voice()
        if(4)
            event = new /datum/chaos_whisper_event/chaos_whisper_shadow()
    
    if(event)
        event.target = target
        event.instance = instance
        event.trigger()
        qdel(event)