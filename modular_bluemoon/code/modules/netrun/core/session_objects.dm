/// Connection state is independent of the permissions granted to this session.
/datum/netrun_connection
	var/datum/netrun_console/owner
	var/datum/component/netrun_node/jack
	var/wireless = TRUE

/datum/netrun_connection/New(datum/netrun_console/owner)
	src.owner = owner

/datum/netrun_connection/Destroy()
	set_jack(null)
	owner = null
	return ..()

/datum/netrun_connection/proc/set_jack(datum/component/netrun_node/node)
	if(jack == node)
		return
	if(jack)
		UnregisterSignal(jack, COMSIG_PARENT_QDELETING)
	jack = QDELETED(node) ? null : node
	if(jack)
		RegisterSignal(jack, COMSIG_PARENT_QDELETING, PROC_REF(on_jack_deleted))

/datum/netrun_connection/proc/on_jack_deleted(datum/source)
	SIGNAL_HANDLER
	set_jack(null)

/datum/netrun_connection/proc/jack_valid()
	var/turf/source_turf = get_turf(owner?.host)
	var/turf/target_turf = get_turf(jack?.parent)
	return source_turf && target_turf && source_turf.z == target_turf.z && get_dist(source_turf, target_turf) <= 1

/// Acquired grants belong to the session; ID credentials still come from its operator.
/datum/netrun_access_session
	var/datum/netrun_console/owner
	var/list/node_access = list()
	var/list/network_access = list()

/datum/netrun_access_session/New(datum/netrun_console/owner)
	src.owner = owner
	RegisterSignal(SSnetrun, COMSIG_NETRUN_FIREWALL_CHANGED, PROC_REF(on_firewall_changed))

/datum/netrun_access_session/Destroy()
	UnregisterSignal(SSnetrun, COMSIG_NETRUN_FIREWALL_CHANGED)
	node_access.Cut()
	network_access.Cut()
	owner = null
	return ..()

/datum/netrun_access_session/proc/revoke_all()
	node_access.Cut()
	network_access.Cut()

/datum/netrun_access_session/proc/revoke_node(address)
	node_access -= address

/// The running breach and trace/lockout lifecycle have one owner.
/datum/netrun_intrusion_session
	var/datum/netrun_console/owner
	var/datum/netrun_breach/breach
	var/trace = 0
	var/trace_mult = 1
	var/last_illegal = -INFINITY
	var/lockout_until = 0
	var/can_breach = TRUE
	var/buffer_bonus = 0

/datum/netrun_intrusion_session/New(datum/netrun_console/owner)
	src.owner = owner

/datum/netrun_intrusion_session/Destroy()
	QDEL_NULL(breach)
	owner = null
	return ..()

/// Windows and physical viewing resources share the remote session's lifetime.
/datum/netrun_remote_session
	var/datum/netrun_console/owner
	var/list/windows = list()
	var/active_window
	var/mob/watch_viewer
	var/datum/component/netrun_node/watch_node
	var/obj/effect/netrun_view_eye/watch_eye
	var/web_site_id
	var/web_slug

/datum/netrun_remote_session/New(datum/netrun_console/owner)
	src.owner = owner

/datum/netrun_remote_session/Destroy()
	stop_watch()
	windows.Cut()
	active_window = null
	web_site_id = null
	web_slug = null
	owner = null
	return ..()

/datum/netrun_remote_session/proc/stop_watch()
	var/mob/previous_viewer = watch_viewer
	var/owns_perspective = previous_viewer?.client?.eye == watch_eye && watch_eye
	if(previous_viewer?.netrun_watch_console == owner)
		previous_viewer.netrun_watch_console = null
	watch_viewer = null
	watch_node = null
	QDEL_NULL(watch_eye)
	if(owns_perspective && previous_viewer?.client)
		previous_viewer.reset_perspective(null)
		if(istype(previous_viewer, /mob/camera/netrun_entity))
			var/mob/camera/netrun_entity/entity = previous_viewer
			entity.update_vision()
