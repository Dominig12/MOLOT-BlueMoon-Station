/**
 * Optional NetDM interface. Independent from NTNet and old NetRun.
 * Register a device using atom.netdm_connect(); component destruction
 * removes it from the game graph.
 */
/datum/component/netdm_node
	dupe_mode = COMPONENT_DUPE_HIGHLANDER
	var/node_id = 0
	var/radio_range = 14
	var/radio_channel = 1
	var/radio_cost = 8
	var/radio_enabled = TRUE
	var/last_x
	var/last_y
	var/last_z

/datum/component/netdm_node/Initialize(range = 14, channel = 1, enabled = TRUE)
	if(!ismovable(parent))
		return COMPONENT_INCOMPATIBLE
	radio_range = max(1, round(range))
	radio_channel = max(1, round(channel))
	radio_enabled = !!enabled
	return ..()

/datum/component/netdm_node/RegisterWithParent()
	. = ..()
	SSnetdm.register_endpoint(src)

/datum/component/netdm_node/UnregisterFromParent()
	SSnetdm.unregister_endpoint(src)
	return ..()

/datum/component/netdm_node/proc/get_position()
	return get_turf(parent)

/datum/component/netdm_node/proc/sync_position()
	if(!node_id)
		return
	var/turf/current = get_position()
	if(!current || (current.x == last_x && current.y == last_y && current.z == last_z))
		return
	last_x = current.x
	last_y = current.y
	last_z = current.z
	SSnetdm.update_endpoint_position(src)

/datum/component/netdm_node/proc/set_radio(enabled, range = radio_range, channel = radio_channel)
	radio_enabled = !!enabled
	radio_range = max(1, round(range))
	radio_channel = max(1, round(channel))
	SSnetdm.update_endpoint_radio(src)

/datum/component/netdm_node/proc/send_to(datum/component/netdm_node/target,
	list/payload, bytes = 96, interactive = TRUE, timeout_ticks = 30)
	return SSnetdm.send_payload(src, target, payload, bytes, interactive, timeout_ticks)

/atom/movable/proc/netdm_connect(range = 14, channel = 1, enabled = TRUE)
	return AddComponent(/datum/component/netdm_node, range, channel, enabled)

/atom/movable/proc/netdm_interface()
	return GetComponent(/datum/component/netdm_node)

/// Optional host callbacks. They are issued after receipt processing.
/datum/proc/netdm_receive(list/payload, datum/component/netdm_node/sender, request_id)
	return

/datum/proc/netdm_delivery(request_id, state, reason)
	return
