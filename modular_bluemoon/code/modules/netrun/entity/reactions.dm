/// A single cancellable deadline per ICE. Reactive work coalesces in the player lane;
/// autonomous patrols continue to use the ordinary population and never acquire this timer.
/datum/netrun_ice_reaction
	var/datum/netrun_ice/owner
	var/timer_id
	var/deadline = 0

/datum/netrun_ice_reaction/New(datum/netrun_ice/owner)
	src.owner = owner

/datum/netrun_ice_reaction/Destroy()
	clear_timer()
	owner = null
	return ..()

/datum/netrun_ice_reaction/proc/clear_timer()
	if(timer_id)
		deltimer(timer_id)
	timer_id = null
	deadline = 0

/datum/netrun_ice_reaction/proc/wake()
	clear_timer()
	if(QDELETED(owner))
		return
	var/datum/netrun_execution_limits/limits = SSnetrun.get_execution_limits()
	SSnetrun.get_task_scheduler().enqueue("ice", owner, limits.interactive_priority, TRUE)

/datum/netrun_ice_reaction/proc/schedule_at(next_deadline)
	if(timer_id && deadline <= next_deadline)
		return
	clear_timer()
	deadline = max(world.time + NETRUN_EXECUTION_MIN_INTERVAL, next_deadline)
	timer_id = addtimer(CALLBACK(src, PROC_REF(wake)), deadline - world.time, TIMER_STOPPABLE | TIMER_DELETE_ME)

/datum/netrun_ice_reaction/proc/schedule_next()
	clear_timer()
	if(QDELETED(owner) || !owner.node?.is_online())
		return
	if(owner.pending_program)
		schedule_at(owner.attack_at)
		return
	var/mob/camera/netrun_entity/prey = owner.find_intruder(owner.node)
	var/tracing = FALSE
	if(!prey && owner.kind == NETRUN_ICE_SENTRY)
		for(var/datum/netrun_console/console as anything in SSnetrun.currentbreaches)
			if(owner.valid_trace_target(console))
				tracing = TRUE
				break
	if(!prey && !tracing)
		return
	if(owner.is_stunned())
		schedule_at(owner.combat_stun_until)
		return
	var/earliest = INFINITY
	for(var/id in owner.program_ids)
		var/datum/netrun_program/program = SSnetrun.get_program(id)
		if(!program || (tracing != (program.role == NETRUN_PROGRAM_TRACE)))
			continue
		if(program.role == NETRUN_PROGRAM_SHIELD && (owner.integrity > owner.max_integrity * 0.75 || world.time < owner.combat_shield_until))
			continue
		var/ready_at = max(owner.next_attack, owner.program_cd[id] || 0)
		if(ready_at > world.time)
			earliest = min(earliest, ready_at)
	if(earliest != INFINITY)
		schedule_at(earliest)

/// Called only by gameplay intent/arrival, never by generic icon or periodic state signals.
/datum/component/netrun_node/proc/wake_defenses()
	for(var/datum/netrun_ice/ice as anything in netrun_ice)
		if(!QDELETED(ice))
			ice.reaction.wake()
