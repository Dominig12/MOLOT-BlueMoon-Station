/**
 * Makes a movable a netDM network node.
 *
 * The component only reports world facts: the effective turf (the turf under the outermost
 * container), whether the object stands anchored on that turf, its mounting class, radio range
 * and, for machines, whether it has power and works.
 * netDM derives the attachment: an anchored fixed node in an APC-served zone gets a wired port
 * to that APC; every other node uses radio within range. A node never forwards foreign traffic.
 *
 * Node IDs belong to the observing session and live in SSnetdm_observe, so the component keeps
 * no network state. Without Observe the component is never added (see netdm_make_node()).
 */
/datum/component/netdm_node
	dupe_mode = COMPONENT_DUPE_UNIQUE
	/// NETDM_MOUNT_FIXED or NETDM_MOUNT_MOBILE.
	var/mount
	/// Radio range in tiles. Zero: no radio, so the node is isolated unless wired.
	var/radio_range
	/// Movable containers between the parent and its turf, each watched for movement.
	var/list/containers

/datum/component/netdm_node/Initialize(mount = NETDM_MOUNT_FIXED, radio_range = NETDM_NODE_RADIO_RANGE)
	if(!istype(parent, /atom/movable) || !(mount in list(NETDM_MOUNT_FIXED, NETDM_MOUNT_MOBILE)))
		return COMPONENT_INCOMPATIBLE
	if(!isnum(radio_range) || radio_range < 0 || radio_range > NETDM_MAX_RADIO_RANGE)
		return COMPONENT_INCOMPATIBLE
	src.mount = mount
	src.radio_range = round(radio_range)

/datum/component/netdm_node/RegisterWithParent()
	RegisterSignal(parent, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))
	RegisterSignal(parent, COMSIG_OBJ_SETANCHORED, PROC_REF(on_anchored))
	if(ismachinery(parent))
		RegisterSignal(parent, COMSIG_MACHINERY_SET_MACHINE_STAT, PROC_REF(on_machine_stat))
	watch_containers()
	SSnetdm_observe.add_node(src)

/datum/component/netdm_node/UnregisterFromParent()
	UnregisterSignal(parent, list(COMSIG_MOVABLE_MOVED, COMSIG_OBJ_SETANCHORED, COMSIG_MACHINERY_SET_MACHINE_STAT))
	unwatch_containers()
	SSnetdm_observe.remove_node(src)

/// Follows the holder chain so a carried node reports the turf it is actually on.
/datum/component/netdm_node/proc/watch_containers()
	var/atom/movable/body = parent
	var/atom/holder = body.loc
	while(istype(holder, /atom/movable) && length(containers) < 16)
		LAZYADD(containers, holder)
		RegisterSignal(holder, COMSIG_MOVABLE_MOVED, PROC_REF(on_container_moved))
		holder = holder.loc

/datum/component/netdm_node/proc/unwatch_containers()
	for(var/atom/movable/holder as anything in containers)
		UnregisterSignal(holder, COMSIG_MOVABLE_MOVED)
	containers = null

/datum/component/netdm_node/proc/on_moved(atom/movable/source, atom/old_loc, dir, forced)
	SIGNAL_HANDLER
	unwatch_containers()
	watch_containers()
	SSnetdm_observe.node_changed(src)

/datum/component/netdm_node/proc/on_container_moved(atom/movable/source, atom/old_loc, dir, forced)
	SIGNAL_HANDLER
	unwatch_containers()
	watch_containers()
	SSnetdm_observe.node_changed(src)

/datum/component/netdm_node/proc/on_anchored(atom/movable/source, anchorvalue)
	SIGNAL_HANDLER
	SSnetdm_observe.node_changed(src)

/// Power loss, breakage, maintenance and EMP all pass through set_machine_stat().
/// A direct write to machine_stat is seen with the next fact of the node.
/datum/component/netdm_node/proc/on_machine_stat(obj/machinery/source, old_value)
	SIGNAL_HANDLER
	SSnetdm_observe.node_changed(src)

/// NETDM_STATE_* flags: a machine needs power and must not be broken, under maintenance or
/// EMP-disabled. Other objects have no power state and are always up.
/datum/component/netdm_node/proc/state()
	if(!ismachinery(parent))
		return NETDM_STATE_UP
	var/obj/machinery/machine = parent
	. = 0
	if(!(machine.machine_stat & NOPOWER))
		. |= NETDM_STATE_POWERED
	if(!(machine.machine_stat & (BROKEN|MAINT|EMPED)))
		. |= NETDM_STATE_OPERATIONAL

/// The wire fact for this node under `node_id`, or null while the object is in nullspace.
/datum/component/netdm_node/proc/fact(node_id)
	var/atom/movable/body = parent
	var/turf/position = get_turf(body)
	if(!position)
		return null
	// Only an object standing on its turf is mounted; anything carried or stored is loose.
	var/anchored_here = body.anchored && body.loc == position
	var/node_state = state()
	return list("op" = "device_state", "a" = node_id, "x" = position.x, "y" = position.y, "z" = position.z,
		"mount" = mount, "anchored" = anchored_here ? 1 : 0, "range" = radio_range,
		"powered" = node_state & NETDM_STATE_POWERED ? 1 : 0, "operational" = node_state & NETDM_STATE_OPERATIONAL ? 1 : 0)

/// Adds a netDM node to `target` when Observe is enabled; otherwise it costs nothing.
/proc/netdm_make_node(atom/movable/target, mount = NETDM_MOUNT_FIXED, radio_range = NETDM_NODE_RADIO_RANGE)
	if(!SSnetdm_observe?.observing())
		return null
	return target.AddComponent(/datum/component/netdm_node, mount, radio_range)

// Research machines are the first network nodes: servers carry knowledge and points in P5,
// consoles and fabricators reach them over this network.
/obj/machinery/rnd/server/Initialize(mapload)
	. = ..()
	if(. != INITIALIZE_HINT_QDEL)
		netdm_make_node(src)

/obj/machinery/computer/rdconsole/Initialize(mapload)
	. = ..()
	if(. != INITIALIZE_HINT_QDEL)
		netdm_make_node(src)

/obj/machinery/rnd/production/Initialize(mapload)
	. = ..()
	if(. != INITIALIZE_HINT_QDEL)
		netdm_make_node(src)
