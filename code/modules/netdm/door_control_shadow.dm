/// Time a mirrored press waits for its doors before the comparison: attachment, the command's lifetime and its receipt.
#define NETDM_DOORS_SETTLE (8 SECONDS)
/// A press waits this long, in real time, for its button and doors to attach before its commands are lost.
#define NETDM_DOORS_ATTACH (3 SECONDS)
/// Legacy doors finish moving within this time after a press; their state then is what the press left.
#define NETDM_DOORS_MOTION (3 SECONDS)
/// Mirrored presses kept at once; the oldest is compared early beyond this.
#define NETDM_DOORS_PRESSES 128
/// Doors one press may command over the network; a larger press is a compatibility exception.
#define NETDM_DOORS_FANOUT 32
/// How long the network may carry a door command, in Host ticks of 100 ms.
#define NETDM_DOORS_TTL_TICKS 30
/// Spread map registration over Observe fires. The shared world node budget still applies.
#define NETDM_DOORS_PREWARM_BATCH 8

/**
 * Buttons and doors in Shadow mode (P9.1). Mapped station buttons and their tagged doors join in batches
 * after the first network snapshot. Built or reconfigured controls also join at the first press if needed.
 * A press keeps its legacy effect: the controller finds its doors by
 * ID across the station and acts at once. Besides, the button sends each of those doors the command set_state
 * over the network with the state that press gives it: open or closed, and for an airlock controller the bolts,
 * ID scanner, shock and safety it leaves. The values are absolute, never a toggle, so a retry or a duplicate
 * cannot flip a door back. In Shadow the door only records the arrival and answers its current state with the
 * reason "shadow". Each (press, door) is then compared: reached over the network, or missed with the Host's
 * reason; and whether the legacy door ended where the press put it.
 *
 * Authoritative mode (NETDM_DOOR_MODE=authoritative, or set_authoritative()): the press no longer moves its doors
 * itself. It plans the absolute state each door should take (open or closed, and for an airlock controller where
 * its toggles of bolts, scanner, shock and safety lead), and a door takes it when the command reaches it over the
 * network. A door the network does not reach stays as it was; a door that cannot do part of it (cut bolt wires,
 * no power) answers with the reason. Presses that are compatibility exceptions keep the legacy path in both modes.
 *
 * Compatibility exceptions, counted but not mirrored: a controller outside a button (in an assembly or a hand),
 * an airlock controller without functions, a press of more than NETDM_DOORS_FANOUT doors. Mass drivers,
 * igniters, flashers and the other controllers keep the legacy path without a mirror.
 */
/datum/netdm_door_shadow
	/// NETDM_DOOR_MODE=authoritative, or set_authoritative() at runtime: doors move only by network command.
	var/authoritative = FALSE
	/// Door weakref -> its instance door.<endpoint>, and back.
	var/list/instances = list()
	var/list/by_instance = list()
	/// Weak refs collected while the map initializes. Buttons establish channels before doors are matched.
	var/list/prewarm_buttons = list()
	var/list/prewarm_doors = list()
	var/list/prewarm_channels = list()
	/// Press ID -> record, oldest first.
	var/list/presses = list()
	/// Press ID -> TRUE while some of its doors wait for their endpoints to attach.
	var/list/warming = list()
	/// Operation ID -> list(press ID, door instance), for the receipts.
	var/list/operations = list()
	var/serial = 0
	var/list/counters = list("buttons" = 0, "presses" = 0, "mirrored" = 0, "commands" = 0, "compared" = 0, "reached" = 0,
		"missed" = 0, "kept" = 0, "differs" = 0, "duplicates" = 0, "receipts" = 0, "lane_full" = 0, "exceptions" = 0, "cold" = 0)
	var/list/reasons = list()
	var/list/exceptions = list()
	/// Press to arrival at the door, and press to the receipt back at the button, microseconds.
	/// A command that had to wait for its endpoints to attach counts in cold_arrivals instead.
	var/list/arrivals = list()
	var/list/cold_arrivals = list()
	var/list/round_trips = list()
	var/list/notes = list()

/datum/netdm_door_shadow/proc/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_command("machine.door", "set_state", new /datum/netdm_command_handler/door_set_state)
	lane.dispatcher.allow_result("set_state", new /datum/netdm_effect_handler/door_state, "machine.door")
	if(world.GetConfig("env", "NETDM_DOOR_MODE") == "authoritative")
		set_authoritative(TRUE)

/// Switches who moves the doors. A command keeps the mode of the press that sent it.
/datum/netdm_door_shadow/proc/set_authoritative(enabled)
	authoritative = !!enabled

/datum/netdm_door_shadow/proc/reset_session()
	// Receipts of the old session never arrive; those presses are compared with what arrived so far.
	operations.Cut()

/// A button joins the network as a fixed node with an endpoint. Returns the node.
/datum/netdm_door_shadow/proc/add_button(obj/machinery/button/button)
	var/datum/component/netdm_node/node = device_node(button)
	if(!node)
		return null
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!lane.by_node[node])
		if(!lane.endpoint_for(node))
			return null
		counters["buttons"]++
	return node

/// A door is a fixed node offering door.<endpoint>. Returns the instance.
/datum/netdm_door_shadow/proc/add_door(obj/machinery/door/door)
	var/datum/weakref/door_ref = WEAKREF(door)
	if(instances[door_ref] || QDELETED(door))
		return instances[door_ref]
	var/datum/component/netdm_node/node = device_node(door)
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services?.endpoint_for(node) : null
	if(!endpoint)
		return null
	var/instance = "door.[endpoint.id]"
	SSnetdm_observe.services.offer(node, instance, "machine.door", "machine.door_set", 1)
	instances[door_ref] = instance
	by_instance[instance] = door_ref
	return instance

/// The door is gone; its node leaves with it, the lane drops the endpoint then.
/datum/netdm_door_shadow/proc/remove_door(obj/machinery/door/door)
	var/datum/weakref/door_ref = WEAKREF(door)
	var/instance = instances[door_ref]
	if(instance)
		instances -= door_ref
		by_instance -= instance

/datum/netdm_door_shadow/proc/node_id(atom/movable/thing)
	var/datum/component/netdm_node/node = thing?.GetComponent(/datum/component/netdm_node)
	return node ? SSnetdm_observe.services.node_id(node) : null

/datum/netdm_door_shadow/proc/device_node(atom/movable/device)
	var/datum/component/netdm_node/node = device.GetComponent(/datum/component/netdm_node)
	if(node)
		return SSnetdm_observe.nodes[node] ? node : null
	node = netdm_make_node(device)
	if(node && SSnetdm_observe.nodes[node])
		return node
	qdel(node)
	return null

/datum/netdm_door_shadow/proc/mapped_button_channel(obj/machinery/button/button)
	var/obj/item/assembly/control/control = button.device
	if(!istype(control) || !control.id)
		return null
	if(control.type == /obj/item/assembly/control)
		return "blast:[control.id]"
	if(control.type == /obj/item/assembly/control/airlock)
		var/obj/item/assembly/control/airlock/airlock_control = control
		if(airlock_control.specialfunctions & (OPEN|IDSCAN|BOLTS|SHOCK|SAFE))
			return "airlock:[control.id]"
	return null

/datum/netdm_door_shadow/proc/mapped_door_channel(obj/machinery/door/door)
	if(istype(door, /obj/machinery/door/airlock))
		var/obj/machinery/door/airlock/airlock = door
		return airlock.id_tag ? "airlock:[airlock.id_tag]" : null
	if(istype(door, /obj/machinery/door/poddoor))
		var/obj/machinery/door/poddoor/blast = door
		return blast.id ? "blast:[blast.id]" : null
	return null

/datum/netdm_door_shadow/proc/tick_prewarm()
	if(!SSnetdm_observe.published)
		return
	var/remaining = NETDM_DOORS_PREWARM_BATCH
	while(remaining && length(prewarm_buttons))
		remaining--
		var/datum/weakref/button_ref = prewarm_buttons[prewarm_buttons.len]
		prewarm_buttons.len--
		var/obj/machinery/button/button = button_ref.resolve()
		if(!button || !button.anchored || !isturf(button.loc) || !is_station_level(button.z) || is_antag_training_atom(button))
			continue
		var/channel = mapped_button_channel(button)
		if(channel && add_button(button))
			prewarm_channels[channel] = TRUE
	while(remaining && length(prewarm_doors))
		remaining--
		var/datum/weakref/door_ref = prewarm_doors[prewarm_doors.len]
		prewarm_doors.len--
		var/obj/machinery/door/door = door_ref.resolve()
		if(!door || !door.anchored || !isturf(door.loc) || !is_station_level(door.z) || is_antag_training_atom(door))
			continue
		var/channel = mapped_door_channel(door)
		if(channel && prewarm_channels[channel])
			add_door(door)

// ---- Legacy side -----------------------------------------------------------------------------

/**
 * The doors a controller acts on and the state this press gives each, found the legacy way before it acts:
 * the open-or-close decision depends on the doors as they are now. Null when the press is not mirrored.
 * GLOB.airlocks holds every door, blast doors too, in the order GLOB.machines has them.
 */
/datum/netdm_door_shadow/proc/plan(obj/item/assembly/control/control)
	counters["presses"]++
	var/obj/machinery/button/button = control.loc
	if(!istype(button) || !add_button(button))
		return exception("not_button")
	var/list/doors = list()
	var/functions = 0
	if(istype(control, /obj/item/assembly/control/airlock))
		var/obj/item/assembly/control/airlock/airlock_control = control
		functions = airlock_control.specialfunctions & (OPEN|IDSCAN|BOLTS|SHOCK|SAFE)
		if(!functions)
			return exception("no_function")
		var/close = FALSE
		for(var/obj/machinery/door/airlock/door in GLOB.airlocks)
			if(door.id_tag == control.id)
				doors[door] = list()
				if((functions & OPEN) && !door.density)
					close = TRUE
				if(authoritative)
					// The legacy press toggles these; the command carries where each toggle leads, as absolute values.
					if(functions & BOLTS)
						doors[door]["bolted"] = door.locked ? FALSE : TRUE
					if(functions & IDSCAN)
						doors[door]["id_scan"] = door.aiDisabledIdScanner ? TRUE : FALSE
					if(functions & SHOCK)
						doors[door]["shocked"] = door.secondsElectrified ? FALSE : TRUE
					if(functions & SAFE)
						doors[door]["safety"] = door.safe ? FALSE : TRUE
		if(functions & OPEN)
			for(var/door in doors)
				doors[door]["state"] = close ? "closed" : "open"
	else
		var/openclose
		for(var/obj/machinery/door/poddoor/door in GLOB.airlocks)
			if(door.id == control.id)
				if(isnull(openclose) || !control.sync_doors)
					openclose = door.density
				doors[door] = list("state" = openclose ? "open" : "closed")
	if(!length(doors))
		return exception("no_doors")
	if(length(doors) > NETDM_DOORS_FANOUT)
		return exception("fanout")
	return list("button" = button, "doors" = doors, "functions" = functions)

/datum/netdm_door_shadow/proc/exception(name)
	counters["exceptions"]++
	exceptions[name]++
	return null

/// The legacy controller acted. Each of its doors gets the command over the network; an airlock controller's
/// bolts, scanner, shock and safety are read as the legacy press left them.
/datum/netdm_door_shadow/proc/mirror(list/plan)
	var/obj/machinery/button/button = plan["button"]
	var/datum/component/netdm_node/node = button.GetComponent(/datum/component/netdm_node)
	if(QDELETED(button) || !node)
		return
	var/id = "d-[++serial]-[copytext(md5("[world.time][rand()]"), 1, 7)]"
	var/list/record = list("id" = id, "created" = world.time, "created_us" = netdm_now_us(), "button" = WEAKREF(button),
		"targets" = list(), "wanted" = list(), "arrived" = list(), "states" = list(), "ops" = list(),
		"authoritative" = authoritative, "user" = usr ? WEAKREF(usr) : null)
	presses[id] = record
	if(length(presses) > NETDM_DOORS_PRESSES)
		compare(presses[presses[1]])
	counters["mirrored"]++
	record["started_rt"] = REALTIMEOFDAY
	record["queued"] = list()
	record["cold"] = list()
	var/functions = plan["functions"]
	var/list/doors = plan["doors"]
	for(var/obj/machinery/door/door as anything in doors)
		if(QDELETED(door))
			continue
		var/list/wanted = doors[door]
		if(functions && !authoritative)
			var/obj/machinery/door/airlock/airlock = door
			if(functions & BOLTS)
				wanted["bolted"] = airlock.locked ? TRUE : FALSE
			if(functions & IDSCAN)
				wanted["id_scan"] = airlock.aiDisabledIdScanner ? FALSE : TRUE
			if(functions & SHOCK)
				wanted["shocked"] = airlock.secondsElectrified ? TRUE : FALSE
			if(functions & SAFE)
				wanted["safety"] = airlock.safe ? TRUE : FALSE
		var/instance = instances[WEAKREF(door)] || add_door(door)
		if(!instance)
			continue
		record["targets"][instance] = WEAKREF(door)
		record["wanted"][instance] = wanted
		record["queued"][instance] = TRUE
	send_ready(record, FALSE)
	if(length(record["queued"]))
		warming[id] = TRUE
	// A press is an interactive action: its commands leave now, outside the subsystem's pump.
	SSnetdm_observe.services.flush_invokes()

/// Sends the commands of a press whose button and doors are attached. `cold`: they had to wait for that.
/datum/netdm_door_shadow/proc/send_ready(list/record, cold)
	var/datum/weakref/button_ref = record["button"]
	var/obj/machinery/button/button = button_ref.resolve()
	var/datum/component/netdm_node/node = button?.GetComponent(/datum/component/netdm_node)
	var/datum/netdm_service_endpoint/button_endpoint = node ? SSnetdm_observe.services.by_node[node] : null
	if(!button_endpoint?.attached_node)
		return
	var/list/queued = record["queued"]
	for(var/instance in queued.Copy())
		var/datum/weakref/door_ref = record["targets"][instance]
		var/obj/machinery/door/door = door_ref.resolve()
		var/datum/component/netdm_node/door_node = door?.GetComponent(/datum/component/netdm_node)
		if(door && (!door_node || !SSnetdm_observe.services.ready(door_node, instance)))
			continue
		queued -= instance
		if(!door)
			record["states"][instance] = "door_gone"
			continue
		var/list/wanted = record["wanted"][instance]
		var/list/arguments = wanted.Copy()
		arguments["press"] = record["id"]
		var/list/entry = SSnetdm_observe.services.invoke(node, instance, "set_state", "[record["id"]].[copytext(instance, 6)]", arguments,
			CALLBACK(src, PROC_REF(accepted), record["id"], instance), NETDM_DOORS_TTL_TICKS)
		if(!entry)
			record["states"][instance] = "lane_full"
			counters["lane_full"]++
			continue
		counters["commands"]++
		if(cold)
			record["cold"][instance] = TRUE

// ---- netDM side ------------------------------------------------------------------------------

/datum/netdm_door_shadow/proc/accepted(id, instance, list/entry, list/reply)
	var/list/record = presses[id]
	if(!record)
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		operations["[value["operationId"]]"] = list(id, instance)
		record["ops"][instance] = "[value["operationId"]]"
	else
		record["states"][instance] = "host_[reply["error"] || "refused"]"

/// The command reached the door's node. Shadow records the arrival once and answers the door's state.
/datum/netdm_door_shadow/proc/received(obj/machinery/door/door, list/item)
	var/list/payload = item["payload"]
	var/press = islist(payload) ? payload["press"] : null
	var/instance = item["instance"]
	if(!istext(press))
		return "invalid_press"
	var/list/record = presses[press]
	var/datum/weakref/button_ref = record?["button"]
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/obj/machinery/button/button = button_ref?.resolve()
	var/datum/weakref/door_ref = record?["targets"]?[instance]
	if(!button || lane.registry.resolve(item["producer"], item["producerGeneration"]) != button || door_ref?.resolve() != door)
		return "invalid_press"
	var/first = TRUE
	if(isnull(record["arrived"][instance]))
		record["arrived"][instance] = netdm_now_us() - record["created_us"]
	else
		counters["duplicates"]++
		first = FALSE
	if(!record["authoritative"])
		return list("result" = door_state(door, press, FALSE, "shadow"))
	if(!first)
		return list("result" = door_state(door, press, FALSE, "duplicate")) // The first arrival already applied it.
	var/datum/weakref/user_ref = record?["user"]
	return list("result" = apply(door, record["wanted"][instance], user_ref?.resolve(), press))

/// Authoritative: the door takes the absolute state the command carries. What it cannot do is named in the reason.
/datum/netdm_door_shadow/proc/apply(obj/machinery/door/door, list/payload, mob/user, press)
	var/list/refused = list()
	var/changed = FALSE
	if(istype(door, /obj/machinery/door/airlock))
		var/obj/machinery/door/airlock/airlock = door
		if(!isnull(payload["bolted"]) && airlock.locked != !!payload["bolted"])
			if(airlock.wires.is_cut(WIRE_BOLTS) || !airlock.hasPower())
				refused += "bolts"
			else
				airlock.locked = !!payload["bolted"]
				airlock.update_icon()
				changed = TRUE
				if(user)
					airlock.log_remote_use(user, airlock.locked ? "bolted" : "unbolted", "network button")
		if(!isnull(payload["id_scan"]) && airlock.aiDisabledIdScanner != !payload["id_scan"])
			airlock.aiDisabledIdScanner = !payload["id_scan"]
			changed = TRUE
		if(!isnull(payload["shocked"]) && !!airlock.secondsElectrified != !!payload["shocked"])
			airlock.secondsElectrified = payload["shocked"] ? -1 : 0
			changed = TRUE
			if(payload["shocked"] && user)
				log_combat(user, airlock, "electrified")
		if(!isnull(payload["safety"]) && airlock.safe != !!payload["safety"])
			airlock.safe = !!payload["safety"]
			changed = TRUE
	var/wanted_state = payload["state"]
	if(wanted_state == "open" && door.density)
		INVOKE_ASYNC(door, TYPE_PROC_REF(/obj/machinery/door, open))
		changed = TRUE
	else if(wanted_state == "closed" && !door.density)
		INVOKE_ASYNC(door, TYPE_PROC_REF(/obj/machinery/door, close))
		changed = TRUE
	if(user && wanted_state)
		door.log_remote_use(user, wanted_state == "open" ? "opened" : "closed", "network button")
	return door_state(door, press, changed, length(refused) ? "refused_[jointext(refused, "+")]" : null)

/datum/netdm_door_shadow/proc/door_state(obj/machinery/door/door, press, changed, reason)
	var/list/state = list("press" = press, "state" = door.density ? "closed" : "open", "changed" = changed ? TRUE : FALSE)
	if(istype(door, /obj/machinery/door/airlock))
		var/obj/machinery/door/airlock/airlock = door
		state["bolted"] = airlock.locked ? TRUE : FALSE
	if(reason)
		state["reason"] = reason
	return state

/// The door's answer came back to the button over the network.
/datum/netdm_door_shadow/proc/receipt(atom/button, list/item)
	counters["receipts"]++
	var/list/link = operations["[item["operationId"]]"]
	if(!link)
		return TRUE
	operations -= "[item["operationId"]]"
	var/list/record = presses[link[1]]
	if(!record)
		return TRUE
	var/list/payload = item["payload"]
	record["states"][link[2]] = islist(payload) ? (payload["reason"] || "answered") : (item["outcome"] || "no_result")
	if(islist(payload))
		push(round_trips, netdm_now_us() - record["created_us"])
	return TRUE

// ---- Comparison ------------------------------------------------------------------------------

/datum/netdm_door_shadow/proc/tick()
	tick_prewarm()
	if(length(warming))
		var/now = REALTIMEOFDAY
		for(var/id in warming)
			var/list/record = presses[id]
			if(record)
				send_ready(record, TRUE)
				var/list/queued = record["queued"]
				if(length(queued) && now < record["started_rt"] + NETDM_DOORS_ATTACH)
					continue
				for(var/instance in queued)
					record["states"][instance] = "not_attached"
				queued.Cut()
			warming -= id
		SSnetdm_observe.services.flush_invokes()
	for(var/id in presses)
		var/list/record = presses[id]
		if(world.time < record["created"] + NETDM_DOORS_MOTION)
			break
		if(!record["ended"])
			record_end(record)
	while(length(presses))
		var/list/record = presses[presses[1]]
		if(world.time < record["created"] + NETDM_DOORS_SETTLE)
			break
		compare(record)

/// Where each door of a press stands once the legacy doors have moved: "" when the press put it there, otherwise
/// what it kept ("state", "bolts"). Taken before the comparison, so a later press does not hide it.
/datum/netdm_door_shadow/proc/record_end(list/record)
	var/list/ended = list()
	record["ended"] = ended
	for(var/instance in record["targets"])
		var/list/wanted = record["wanted"][instance]
		var/datum/weakref/door_ref = record["targets"][instance]
		var/obj/machinery/door/door = door_ref.resolve()
		if(!door || !wanted)
			continue
		var/list/now = door_state(door, null, FALSE, null)
		var/list/differs = list()
		if(wanted["state"] && wanted["state"] != now["state"])
			differs += "state"
		if(!isnull(wanted["bolted"]) && wanted["bolted"] != now["bolted"])
			differs += "bolts"
		ended[instance] = jointext(differs, "+")

/// Each door of a mirrored press: reached over the network or missed with a reason, and whether it ended where
/// the press put it. A legacy door that did not (no power, welded, held open by something) refuses the same
/// command under netDM authority too.
/datum/netdm_door_shadow/proc/compare(list/record)
	if(!record["ended"])
		record_end(record)
	presses -= record["id"]
	warming -= record["id"]
	for(var/instance in record["ops"])
		operations -= record["ops"][instance]
	for(var/instance in record["targets"])
		counters["compared"]++
		if(isnull(record["arrived"][instance]))
			counters["missed"]++
			explain(record, instance)
			continue
		counters["reached"]++
		if(record["cold"][instance])
			counters["cold"]++
			push(cold_arrivals, record["arrived"][instance])
		else
			push(arrivals, record["arrived"][instance])
		var/differs = record["ended"][instance]
		if(isnull(differs))
			continue
		if(length(differs))
			counters["differs"]++
			var/datum/weakref/door_ref = record["targets"][instance]
			var/obj/machinery/door/door = door_ref.resolve()
			note("[record["id"]] -> [instance]: legacy door kept [differs] ([door?.type])")
		else
			counters["kept"]++

/// Why the command missed a door: the state recorded on the way, or the command's outcome from the Host.
/datum/netdm_door_shadow/proc/explain(list/record, instance)
	var/state = record["states"][instance]
	var/operation = record["ops"][instance]
	var/datum/weakref/button_ref = record["button"]
	var/obj/machinery/button/button = button_ref.resolve()
	var/datum/component/netdm_node/node = button?.GetComponent(/datum/component/netdm_node)
	if(state || !operation || !node || !SSnetdm_observe.services.query_command(node, operation, CALLBACK(src, PROC_REF(explained), record["id"], instance)))
		reasons[state || "unanswered"]++
		note("[record["id"]] -> [instance]: [state || "unanswered"]")

/datum/netdm_door_shadow/proc/explained(id, instance, list/reply)
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	var/reason = islist(value) ? (value["outcomeReason"] || value["outcome"]) : "status_[reply["error"]]"
	reasons[reason || "unknown"]++
	note("[id] -> [instance]: [reason]")

/datum/netdm_door_shadow/proc/push(list/samples, value)
	samples += value
	if(length(samples) > 256)
		samples.Cut(1, 2)

/datum/netdm_door_shadow/proc/note(text)
	notes += text
	if(length(notes) > 16)
		notes.Cut(1, 2)

/datum/netdm_door_shadow/proc/percentile_ms(list/samples, fraction)
	if(!length(samples))
		return null
	var/list/sorted = sortTim(samples.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	return round(sorted[clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))] / 1000, 0.1)

/datum/netdm_door_shadow/proc/state()
	var/list/reason_text = list()
	for(var/reason in reasons)
		reason_text += "[reason]:[reasons[reason]]"
	var/list/exception_text = list()
	for(var/exception in exceptions)
		exception_text += "[exception]:[exceptions[exception]]"
	return "doors buttons=[counters["buttons"]] doors=[length(instances)] presses=[counters["presses"]] mirrored=[counters["mirrored"]] \
		commands=[counters["commands"]] compared=[counters["compared"]] reached=[counters["reached"]] missed=[counters["missed"]] \
		kept=[counters["kept"]] differs=[counters["differs"]] duplicates=[counters["duplicates"]] receipts=[counters["receipts"]] \
		lane_full=[counters["lane_full"]] pending=[length(presses)] arrival_p50=[percentile_ms(arrivals, 0.5)]ms \
		arrival_p95=[percentile_ms(arrivals, 0.95)]ms cold=[counters["cold"]] cold_p50=[percentile_ms(cold_arrivals, 0.5)]ms \
		cold_p95=[percentile_ms(cold_arrivals, 0.95)]ms warming=[length(warming)] round_trip_p95=[percentile_ms(round_trips, 0.95)]ms \
		reasons=[jointext(reason_text, ",")] exceptions=[jointext(exception_text, ",")]"

/datum/netdm_command_handler/door_set_state/execute(datum/target, list/item)
	if(!SSnetdm_observe.doors || !istype(target, /obj/machinery/door))
		return "not_door"
	return SSnetdm_observe.doors.received(target, item)

/datum/netdm_effect_handler/door_state/apply(datum/target, list/item)
	if(!SSnetdm_observe.doors)
		return "no_doors"
	return SSnetdm_observe.doors.receipt(target, item)

// ---- Hooks; without Observe they add nothing but a null check --------------------------------

/obj/machinery/button/Initialize(mapload, ndir = 0, built = 0)
	. = ..()
	var/datum/netdm_door_shadow/shadow = SSnetdm_observe?.doors
	if(mapload && . != INITIALIZE_HINT_QDEL && shadow?.mapped_button_channel(src))
		shadow.prewarm_buttons += WEAKREF(src)

/obj/machinery/door/Initialize(mapload)
	. = ..()
	var/datum/netdm_door_shadow/shadow = SSnetdm_observe?.doors
	if(mapload && . != INITIALIZE_HINT_QDEL && shadow?.mapped_door_channel(src))
		shadow.prewarm_doors += WEAKREF(src)

/obj/machinery/door/Destroy()
	SSnetdm_observe.doors?.remove_door(src)
	return ..()

/obj/item/assembly/control/activate()
	var/datum/netdm_door_shadow/shadow = SSnetdm_observe.doors
	var/list/plan = shadow?.plan(src)
	if(plan && shadow.authoritative)
		// The doors move when the commands reach them; the button only keeps its cooldown.
		cooldown = TRUE
		addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 10)
		shadow.mirror(plan)
		return
	. = ..()
	if(plan)
		shadow.mirror(plan)

/obj/item/assembly/control/airlock/activate()
	var/datum/netdm_door_shadow/shadow = SSnetdm_observe.doors
	var/list/plan = shadow?.plan(src)
	if(plan && shadow.authoritative)
		cooldown = TRUE
		addtimer(VARSET_CALLBACK(src, cooldown, FALSE), 10)
		shadow.mirror(plan)
		return
	. = ..()
	if(plan)
		shadow.mirror(plan)

#undef NETDM_DOORS_SETTLE
#undef NETDM_DOORS_ATTACH
#undef NETDM_DOORS_MOTION
#undef NETDM_DOORS_PRESSES
#undef NETDM_DOORS_FANOUT
#undef NETDM_DOORS_TTL_TICKS
#undef NETDM_DOORS_PREWARM_BATCH
