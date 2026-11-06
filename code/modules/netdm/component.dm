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
	/// Engine-assigned modes are maintained as the object changes location/anchoring.
	var/auto_managed = FALSE
	/// Current wired uplink; the APC itself belongs to the sparse APC backbone.
	var/datum/component/netdm_node/zone_apc

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
	zone_apc = null
	return ..()

/datum/component/netdm_node/proc/get_position()
	return get_turf(parent)

/datum/component/netdm_node/proc/sync_position()
	if(!node_id)
		return
	// APC assignments can change without a tile coordinate changing.
	sync_transport()
	var/turf/current = get_position()
	if(!current || (current.x == last_x && current.y == last_y && current.z == last_z))
		return
	last_x = current.x
	last_y = current.y
	last_z = current.z
	SSnetdm.update_endpoint_position(src)

/// Assign a radio profile to movable equipment and an APC uplink to
/// stationary machinery. This runs only on initial registration and on
/// bounded SSnetdm reconciliation; it does not walk the whole machine list.
/datum/component/netdm_node/proc/sync_transport()
	if(!auto_managed || !node_id || QDELETED(parent))
		return
	var/obj/machinery/machine = null
	if(istype(parent, /obj/machinery))
		machine = parent
	// APCs are wired into the backbone, but also serve as access points
	// so that mobile radio clients can reach the wired station graph.
	var/should_radio = !machine || !machine.anchored || istype(machine, /obj/machinery/power/apc)
	if(radio_enabled != should_radio)
		set_radio(should_radio)
	var/datum/component/netdm_node/new_apc = null
	if(machine && machine.anchored && !istype(machine, /obj/machinery/power/apc))
		var/area/zone = get_area(machine)
		if(zone)
			var/area/root = zone.base_area ? zone.base_area : zone
			var/obj/machinery/power/apc/controller = root.power_apc
			if(controller && !QDELETED(controller))
				// A shared area name/root across distinct space sectors
				// must never create an unmediated inter-sector wired path.
				var/turf/device_turf = get_position()
				var/turf/controller_turf = get_turf(controller)
				if(device_turf && controller_turf && SSnetdm.sector_key(device_turf) == SSnetdm.sector_key(controller_turf))
					new_apc = controller.netdm_interface()
	if(new_apc == src)
		new_apc = null
	// A switched-off or crashed quantum relay must not bridge the area.
	if(istype(machine, /obj/machinery/ntnet_relay))
		var/obj/machinery/ntnet_relay/relay = machine
		if(!relay.is_operational())
			new_apc = null
	if(zone_apc == new_apc)
		return
	if(zone_apc && zone_apc.node_id)
		SSnetdm.disconnect_nodes(src, zone_apc)
	zone_apc = new_apc
	if(zone_apc && zone_apc.node_id)
		SSnetdm.connect_nodes(src, zone_apc)

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
