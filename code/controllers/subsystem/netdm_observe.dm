// Authoritative netDM bridge: networked game interactions never bypass the Host.
#define NETDM_OBSERVE_CAP 4096
#define NETDM_OBSERVE_BATCH 64
/// Observed netDM nodes; the Host accepts up to 4096 devices per runtime.
#define NETDM_NODE_CAP 4096
/// Real-time wait for one reply before a new session. Multi-second host stalls were measured on Windows;
/// the Host itself drops a silent owner after 30 seconds.
#define NETDM_OBSERVE_ACK_TIMEOUT (20 SECONDS)
/// A fire above this share of a tick is logged with the timeline of its sections.
#define NETDM_SLOW_FIRE 50

/// Adapter lifecycle for the game features using the service lane.
/datum/netdm_integration/proc/setup(datum/netdm_service_lane/lane)
	return

/datum/netdm_integration/proc/reset_session()
	return

/datum/netdm_integration/proc/tick()
	return

SUBSYSTEM_DEF(netdm_observe)
	name = "netDM Network"
	wait = 1
	// Not a background subsystem: service deliveries have a latency budget, and a background
	// subsystem waited up to 4.7 s for leftover tick time. Every fire is bounded by the tick check.
	priority = FIRE_PRIORITY_DEFAULT
	flags = SS_NO_FIRE
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT

	var/datum/netdm_bridge/v1/staged/bridge
	var/server_id
	var/round_epoch
	var/next_hello = 0
	var/phase
	var/pending
	var/pending_heartbeat = FALSE
	var/ack_deadline
	var/next_heartbeat
	var/next_scan
	var/snapshot_id
	var/fact_sequence
	var/node_serial
	var/manifest
	var/chunk_index
	var/batch_offset
	var/list/apcs
	var/apc_index
	var/list/known
	var/list/sample
	var/datum/netdm_apc_map_export/map_export
	var/geometry_revision = 0
	/// P13: body weakref -> /datum/netdm_immersion. One dive per operator; the registry lets the dive end
	/// from a signal, a close or a failed check without every caller knowing about the others.
	var/list/netdm_immersions = list()
	/// P13: personas live for the round, keyed by ckey: a new neuro-link restores the look, not rights.
	var/list/netdm_personas = list()
	/// P13: the round journal of network incidents: sabotage, repairs, intrusions, banishments.
	var/list/netdm_incidents = list()
	/// P13: the last life poll projected to node -> agent count, so the physical APC panel can show it.
	var/list/netdm_life_nodes = list()
	/// P13: the network population was seeded once for this round when NETDM_NET_LIFE is enabled.
	var/life_seeded = FALSE
	/// P13: the one-time note that the service lane was not ready for the seeding yet.
	var/life_waiting = FALSE
	/// P13: when the population next changes by itself (arrival or retirement).
	var/next_life_event = 0
	var/shuttle_mutations = 0
	var/export_revision
	var/published_revision
	var/apcs_changed
	var/published = FALSE
	var/update_id
	var/shutdown_marker
	var/next_shutdown_check = 0
	var/last_resync_reason
	var/next_resync_log = 0
	/// Every observed /datum/component/netdm_node. A component removes itself when it goes away.
	var/list/nodes = list()
	/// Nodes whose facts may differ from what the Host has.
	var/list/dirty_nodes = list()
	/// Session-scoped wire ID of each node and its last acknowledged fact.
	var/list/node_ids = list()
	var/list/node_facts = list()
	/// Wire IDs the Host must still forget in this session.
	var/list/removed_node_ids = list()
	/// The device delta in flight: node -> fact, and the IDs it removes.
	var/list/inflight_facts
	var/list/inflight_removed
	/// Acknowledged NETDM_STATE_* flags of published APCs by wire ID. An APC without an entry is up,
	/// which is also what the Host assumes for a new map node.
	var/list/apc_states = list()
	/// APC states in the delta in flight: wire ID -> flags.
	var/list/inflight_states
	/// APC power has no signal: states are compared with the acknowledged ones once a second.
	var/next_apc_state_check = 0
	/// Node deltas are rate limited so map rescans keep their share of fires.
	var/next_node_flush = 0
	var/node_cap_logged = FALSE
	/// Exports abandoned because the geometry changed mid-way or the Host refused them.
	var/export_discards = 0
	/// Open topology screens (/datum/netdm_topology_view). Views are polled only while one is open.
	var/list/viewers = list()
	/// Latest Host view per level: "z" -> the view result with its "received" world.time.
	var/list/views = list()
	/// Level of the view request in flight.
	var/pending_view
	var/next_view_poll = 0
	var/view_cursor = 0
	/// Last client renderer report of the topology screen, for diagnostics.
	var/list/last_renderer_report
	/// Fires spent waiting for the reply in flight: tells a starved subsystem from a lost reply.
	var/pending_fires = 0
	/// NETDM_BRIDGE_TRACE=1 logs the native bridge counters every two minutes.
	var/bridge_trace = FALSE
	var/next_bridge_trace = 0
	/// Section marks of the current fire ("name@tick usage"), kept only to explain a slow fire.
	var/list/fire_marks = list()
	/// Service control plane of the session: endpoints, services, subscriptions and the inbox.
	var/datum/netdm_service_lane/services
	/// NETRUN device adapter: turns accepted services into digital hosts of the game layer.
	var/datum/netrun_adapter/netrun
	/// Feature adapters run in registration order for both session resets and processing.
	var/list/integrations = list()
	/// atmos.telemetry pilot in Shadow mode: radio and netDM recipients compared report by report.
	var/datum/netdm_telemetry_shadow/telemetry
	/// research.server pilot in Shadow mode: R&D servers keep their storage in the Host ledger.
	var/datum/netdm_research_shadow/research
	/// pda.messenger pilot in Shadow mode: PDA messages mirrored as addressed network deliveries (P7).
	var/datum/netdm_messenger_shadow/messenger
	/// Radio speech in Shadow mode: where the network would carry a transmission (P8).
	var/datum/netdm_radio_shadow/radio
	/// Buttons and doors in Shadow mode: each press mirrored as set_state commands to its doors (P9.1).
	var/datum/netdm_door_shadow/doors
	/// network.diagnostics: a multitool asks an APC's network module about its own ports.
	var/datum/netdm_diagnostics/diagnostics
	/// Fires that took more than NETDM_SLOW_FIRE percent of a tick; one is logged per 10 seconds.
	var/slow_fires = 0
	/// Longest real time between two fires since the last report: a starved subsystem delays deliveries.
	var/max_fire_gap_us = 0
	var/last_fire_us
	var/next_slow_fire_log = 0

/datum/controller/subsystem/netdm_observe/PreInit()
	// v1 is the supported game transport. No independent Shadow/Observe feature switch.
	if(world.GetConfig("env", "NETDM_IPC_MODE") == "v1")
		flags &= ~SS_NO_FIRE
		// Devices declare their services while atoms initialize, before this subsystem does.
		services = new
		netrun = new
		integrations.Cut()
		telemetry = new
		register_integration(telemetry)
		research = new
		register_integration(research)
		messenger = new
		register_integration(messenger)
		radio = new
		register_integration(radio)
		doors = new
		register_integration(doors)
		diagnostics = new
		register_integration(diagnostics)
		register_integration(new /datum/netdm_integration/camera_access)

/datum/controller/subsystem/netdm_observe/proc/register_integration(datum/netdm_integration/integration)
	integrations += integration
	integration.setup(services)

/datum/controller/subsystem/netdm_observe/Initialize(start_timeofday)
	if(flags & SS_NO_FIRE)
		return ..()
	shutdown_marker = world.GetConfig("env", "NETDM_BUNDLE_STOP_FILE")
	bridge_trace = world.GetConfig("env", "NETDM_BRIDGE_TRACE") == "1"
	var/library_path = world.system_type == UNIX ? "./netdm_byond.so" : "./netdm_byond.dll"
	if(!fexists(library_path))
		log_world("netDM Observe disabled: bridge library missing.")
		flags |= SS_NO_FIRE
		forget_nodes()
		return ..()
	server_id = world.GetConfig("env", "NETDM_SERVER_ID")
	if(!length(server_id))
		server_id = "bluemoon"
	round_epoch = rustg_generate_uuid_v4()
	bridge = new
	if(!bridge.initialize())
		log_world("netDM Observe disabled: bridge initialization failed.")
		Shutdown()
		flags |= SS_NO_FIRE
		forget_nodes()
		return ..()
	// An empty server otherwise suspends after initialization: no MC ticks, no
	// heartbeat, and the Host correctly reports the game as unready. Same hook
	// as HandleTestRun(); only this opt-in integration keeps the world awake.
	Master.sleep_offline_after_initializations = FALSE
	// The runtime station has no R&D server; the research pilot needs one to check anything.
	netdm_spawn_stand_rnd_server()
	log_world("netDM Observe enabled for server '[server_id]'.")
	return ..()

/datum/controller/subsystem/netdm_observe/Shutdown()
	if(bridge)
		bridge.stop()
		bridge = null
	clear_observation()

/// Ends every active dive. Called when the session is reset or the subsystem stops, so no operator is left
/// behind in a body that cannot act.
/datum/controller/subsystem/netdm_observe/proc/end_immersions(reason)
	if(!length(netdm_immersions))
		return
	// The registry is keyed by a weak reference of the operator, so the dive is the value.
	for(var/key in netdm_immersions.Copy())
		var/datum/netdm_immersion/dive = netdm_immersions[key]
		if(!QDELETED(dive))
			dive.surface(reason)
	netdm_immersions.Cut()

/datum/controller/subsystem/netdm_observe/proc/clear_observation()
	// A dive belongs to the session: when the session is gone, every operator comes back to its body
	// instead of being left in trance with blocked hands (audit, §13).
	end_immersions("session_reset")
	phase = null
	pending = null
	pending_heartbeat = FALSE
	snapshot_id = null
	known = null
	sample = null
	apcs = null
	map_export = null
	update_id = null
	published = FALSE
	next_heartbeat = 0
	next_scan = 0
	node_serial = 0
	fact_sequence = 0
	reset_node_session()

/// Wire IDs are scoped to the Host session: a new session re-sends every node under a new ID.
/datum/controller/subsystem/netdm_observe/proc/reset_node_session()
	inflight_facts = null
	inflight_removed = null
	inflight_states = null
	apc_states.Cut()
	next_apc_state_check = 0
	services?.reset_session()
	// P13: the Host session owns the network population: a new session seeds it again.
	life_seeded = FALSE
	life_waiting = FALSE
	for(var/datum/netdm_integration/integration as anything in integrations)
		integration.reset_session()
	pending_view = null
	views.Cut()
	removed_node_ids.Cut()
	if(!length(node_ids))
		return
	node_ids.Cut()
	node_facts.Cut()
	for(var/node in nodes)
		dirty_nodes[node] = TRUE

/datum/controller/subsystem/netdm_observe/proc/forget_nodes()
	nodes.Cut()
	dirty_nodes.Cut()
	node_ids.Cut()
	node_facts.Cut()
	removed_node_ids.Cut()
	inflight_facts = null
	inflight_removed = null
	inflight_states = null
	apc_states.Cut()

/datum/controller/subsystem/netdm_observe/proc/observing()
	return !(flags & SS_NO_FIRE)

/// Compact state for the MC panel and test failures.
/datum/controller/subsystem/netdm_observe/proc/observe_state()
	return "phase=[phase || "none"] published=[published] fence=[!!bridge?.owner_fence] pending=[pending || "none"] \
		facts=[fact_sequence] geometry=[geometry_revision]/[export_revision] discards=[export_discards] \
		map_loading=[Master.map_loading]/[SSair.map_loading_depth] shuttles=[shuttle_mutations] \
		nodes=[length(nodes)] dirty=[length(dirty_nodes)] apcs_down=[length(apc_states)] slow_fires=[slow_fires] fire_gap=[round(max_fire_gap_us / 1000)]ms \
		[services?.state()] [telemetry?.state()] [research?.state()] [messenger?.state()] [radio?.state()] [doors?.state()] [diagnostics?.state()] \
		export=[map_export ? "[map_export.phase]:[map_export.index] cells=[map_export.cells_visited] facts=[length(map_export.facts)]" : "none"]"

/datum/controller/subsystem/netdm_observe/stat_entry(msg)
	if(observing())
		msg += observe_state()
	return ..()

/datum/controller/subsystem/netdm_observe/proc/add_node(datum/component/netdm_node/node)
	if(!observing())
		return
	if(length(nodes) >= NETDM_NODE_CAP)
		if(!node_cap_logged)
			node_cap_logged = TRUE
			log_world("netDM Observe: the budget of [NETDM_NODE_CAP] nodes is reached; further nodes are not observed.")
		return
	nodes[node] = TRUE
	dirty_nodes[node] = TRUE

/datum/controller/subsystem/netdm_observe/proc/node_changed(datum/component/netdm_node/node)
	if(nodes[node])
		dirty_nodes[node] = TRUE

/datum/controller/subsystem/netdm_observe/proc/remove_node(datum/component/netdm_node/node)
	if(!nodes[node])
		return
	nodes -= node
	dirty_nodes -= node
	services?.drop(node)
	if(inflight_facts)
		inflight_facts -= node
	var/node_id = node_ids[node]
	if(node_id)
		// Sent after any delta in flight, so the Host first knows the ID it forgets.
		removed_node_ids += node_id
	node_ids -= node
	node_facts -= node

/datum/controller/subsystem/netdm_observe/proc/same_fact(list/left, list/right)
	return left && right && left["x"] == right["x"] && left["y"] == right["y"] && left["z"] == right["z"] \
		&& left["anchored"] == right["anchored"] && left["mount"] == right["mount"] && left["range"] == right["range"] \
		&& left["powered"] == right["powered"] && left["operational"] == right["operational"] \
		&& left["executionPowered"] == right["executionPowered"]

/// Sends one bounded delta of device facts and APC states. Positions coalesce: only the latest
/// state of a node leaves.
/datum/controller/subsystem/netdm_observe/proc/flush_nodes()
	if(!length(dirty_nodes) && !length(removed_node_ids) && world.time < next_apc_state_check)
		return FALSE
	var/list/changes = list()
	var/list/batch_facts = list()
	var/list/batch_removed = list()
	while(length(removed_node_ids) && length(changes) < NETDM_OBSERVE_BATCH)
		var/node_id = removed_node_ids[length(removed_node_ids)]
		removed_node_ids.len--
		changes += list(list("op" = "device_remove", "a" = node_id))
		batch_removed += node_id
	while(length(dirty_nodes) && length(changes) < NETDM_OBSERVE_BATCH)
		var/datum/component/netdm_node/node = dirty_nodes[length(dirty_nodes)]
		dirty_nodes.len--
		var/node_id = node_ids[node]
		var/list/fact = node.fact(node_id)
		if(!fact)
			// Nullspace: the node leaves the network and takes a new ID when it returns.
			if(node_id)
				node_ids -= node
				node_facts -= node
				services?.node_moved(node)
				changes += list(list("op" = "device_remove", "a" = node_id))
				batch_removed += node_id
			continue
		if(node_id && same_fact(node_facts[node], fact))
			continue
		if(!node_id)
			if(node_serial >= 16000000)
				resynchronize("node_id_budget")
				return TRUE
			node_id = num2text(++node_serial, 16)
			node_ids[node] = node_id
			fact["a"] = node_id
		changes += list(fact)
		batch_facts[node] = fact
	var/list/batch_states = collect_apc_states(changes)
	if(!length(changes))
		return FALSE
	if(!queue(bridge.world_delta(snapshot_id, num2text(fact_sequence + 1, 16), changes)))
		next_apc_state_check = 0
		for(var/node in batch_facts)
			dirty_nodes[node] = TRUE
			// The Host never saw an ID that was only assigned for this batch.
			if(!node_facts[node])
				node_ids -= node
		removed_node_ids += batch_removed
		return TRUE
	inflight_facts = batch_facts
	inflight_removed = batch_removed
	inflight_states = batch_states
	next_node_flush = world.time + 2
	return TRUE

/// Adds node_state facts for published APCs whose state differs from the acknowledged one.
/// A full pass waits a second; a pass cut short by the batch limit resumes on the next flush.
/// Wire ID of an APC in the published map, or null while it is not part of it.
/datum/controller/subsystem/netdm_observe/proc/apc_node_id(obj/machinery/power/apc/apc)
	if(!published || QDELETED(apc))
		return null
	var/list/fact = known?[WEAKREF(apc)]
	return fact?["a"]

/// The APC behind a wire ID of the published map. A linear search: used for a diagnostics report only.
/datum/controller/subsystem/netdm_observe/proc/apc_by_node_id(node_id)
	for(var/datum/weakref/key as anything in known)
		if(known[key]["a"] == node_id)
			return key.resolve()
	return null

/// P13: a busy network agent leaves a physical trace near the APC it runs on.
/datum/controller/subsystem/netdm_observe/proc/netdm_ambient_ping(obj/machinery/power/apc/apc)
	if(QDELETED(apc) || world.time < apc.netdm_ambient_at)
		return FALSE
	apc.netdm_ambient_at = world.time + rand(45 SECONDS, 90 SECONDS)
	playsound(apc, 'sound/machines/beep.ogg', 25, TRUE)
	return TRUE

/// P13: an intruder trips the breaker of the APC it invades; engineers restore it by hand.
/// P13: an engineer agent restores the breaker of the APC it visits; intruders and engineers can
/// trade the same breaker, so the station sees a quiet tug of war instead of a one-way outage.
/datum/controller/subsystem/netdm_observe/proc/netdm_repair(obj/machinery/power/apc/apc, node)
	if(QDELETED(apc) || apc.operating || world.time < apc.netdm_repair_at)
		return FALSE
	apc.netdm_repair_at = world.time + 60 SECONDS
	apc.operating = TRUE
	apc.update()
	apc.update_appearance()
	apc.visible_message(span_notice("Индикаторы [apc] снова горят зелёным: сетевой агент восстановил питание."))
	playsound(apc, 'sound/machines/chime.ogg', 40, TRUE)
	netdm_incident("repair", node, "Инженер восстановил питание [apc].")
	log_game("netDM: a network engineer restored the breaker of [apc] (node [node]).")
	return TRUE

/datum/controller/subsystem/netdm_observe/proc/netdm_sabotage(obj/machinery/power/apc/apc, node)
	if(QDELETED(apc) || world.time < apc.netdm_effect_at)
		return FALSE
	apc.netdm_effect_at = world.time + 60 SECONDS
	apc.operating = FALSE
	apc.update()
	apc.update_appearance()
	apc.visible_message(span_warning("Индикаторы [apc] вспыхивают красным: сетевой агент выбил рубильник!"))
	playsound(apc, 'sound/machines/warning-buzzer.ogg', 50, TRUE)
	netdm_incident("sabotage", node, "Диверсант выбил рубильник [apc].")
	log_game("netDM: a network intruder tripped the breaker of [apc] (node [node]).")
	return TRUE

/datum/controller/subsystem/netdm_observe/proc/collect_apc_states(list/changes)
	var/list/batch_states = list()
	if(world.time < next_apc_state_check || length(changes) >= NETDM_OBSERVE_BATCH)
		return batch_states
	for(var/datum/weakref/key as anything in known)
		var/obj/machinery/power/apc/apc = key.resolve()
		if(QDELETED(apc))
			continue
		var/node_id = known[key]["a"]
		var/state = apc.netdm_state()
		if(state == (isnull(apc_states[node_id]) ? NETDM_STATE_UP : apc_states[node_id]))
			continue
		if(length(changes) >= NETDM_OBSERVE_BATCH)
			return batch_states
		changes += list(list("op" = "node_state", "a" = node_id,
			"powered" = state & NETDM_STATE_POWERED ? 1 : 0, "operational" = state & NETDM_STATE_OPERATIONAL ? 1 : 0))
		batch_states[node_id] = state
	next_apc_state_check = world.time + 1 SECONDS
	return batch_states

/datum/controller/subsystem/netdm_observe/proc/add_viewer(datum/netdm_topology_view/viewer)
	if(!observing())
		return
	viewers[viewer] = TRUE
	next_view_poll = 0

/datum/controller/subsystem/netdm_observe/proc/remove_viewer(datum/netdm_topology_view/viewer)
	viewers -= viewer

/// Asks the Host for one watched level, round robin, at most once a second.
/datum/controller/subsystem/netdm_observe/proc/poll_view()
	if(!length(viewers) || world.time < next_view_poll)
		return FALSE
	var/list/levels = list()
	for(var/datum/netdm_topology_view/viewer as anything in viewers)
		levels |= viewer.z
	view_cursor = (view_cursor % length(levels)) + 1
	var/level = levels[view_cursor]
	var/list/previous = views["[level]"]
	next_view_poll = world.time + 1 SECONDS
	if(!queue(bridge.topology_view(level, previous?["version"])))
		return FALSE
	pending_view = level
	return TRUE

/// Stores a view and pushes it to the screens of that level. An unchanged version sends nothing.
/datum/controller/subsystem/netdm_observe/proc/accept_view(level, list/reply)
	var/list/result = reply["result"]
	var/list/previous = views["[level]"]
	if(!reply["ok"] || !islist(result))
		views["[level]"] = list("error" = reply["error"] || "invalid_view", "received" = world.time)
	else if(result["unchanged"] && previous)
		previous["received"] = world.time
		return
	else
		result["received"] = world.time
		views["[level]"] = result
	for(var/datum/netdm_topology_view/viewer as anything in viewers)
		if(viewer.z == level)
			SStgui.update_uis(viewer)

/datum/controller/subsystem/netdm_observe/proc/commit_nodes()
	for(var/node in inflight_facts)
		if(nodes[node])
			node_facts[node] = inflight_facts[node]
			services?.node_moved(node)
	for(var/node_id in inflight_states)
		var/state = inflight_states[node_id]
		if(state == NETDM_STATE_UP)
			apc_states -= node_id
		else
			apc_states[node_id] = state
	inflight_facts = null
	inflight_removed = null
	inflight_states = null
	fact_sequence++

/datum/controller/subsystem/netdm_observe/proc/resynchronize(reason)
	log_issue("resynchronizing ([reason])")
	clear_observation()
	next_hello = world.time + 10
	bridge.recover_session(reason)

/datum/controller/subsystem/netdm_observe/proc/log_issue(reason)
	if(reason != last_resync_reason || world.time >= next_resync_log)
		log_world("netDM Observe: [reason].")
		last_resync_reason = reason
		next_resync_log = world.time + 1 MINUTES

/datum/controller/subsystem/netdm_observe/proc/mark_geometry_dirty()
	if(bridge)
		geometry_revision++

/datum/controller/subsystem/netdm_observe/proc/begin_shuttle_mutation()
	shuttle_mutations++
	mark_geometry_dirty()

/datum/controller/subsystem/netdm_observe/proc/end_shuttle_mutation()
	shuttle_mutations--
	mark_geometry_dirty()

/datum/controller/subsystem/netdm_observe/StartLoadingMap()
	. = ..()
	mark_geometry_dirty()

/datum/controller/subsystem/netdm_observe/StopLoadingMap()
	. = ..()
	mark_geometry_dirty()

/datum/controller/subsystem/netdm_observe/proc/discard_export(reason)
	if(reason)
		export_discards++
		log_issue(reason)
	apcs = null
	sample = null
	map_export = null
	update_id = null
	phase = published ? "live" : null
	next_scan = world.time + (reason ? 30 : 10)

/datum/controller/subsystem/netdm_observe/fire(resumed = FALSE)
	var/started = TICK_USAGE
	var/now_us = netdm_now_us()
	if(last_fire_us)
		max_fire_gap_us = max(max_fire_gap_us, now_us - last_fire_us)
	last_fire_us = now_us
	fire_marks.len = 0
	fire_step(resumed)
	var/cost = TICK_USAGE - started
	if(cost < NETDM_SLOW_FIRE)
		return
	slow_fires++
	if(world.time >= next_slow_fire_log)
		next_slow_fire_log = world.time + 10 SECONDS
		log_world("netDM Observe slow fire: [round(cost, 0.1)]% of a tick from [round(started, 0.1)]%, \
			marks [jointext(fire_marks, " ")], [observe_state()]")

/datum/controller/subsystem/netdm_observe/proc/mark(name)
	fire_marks += "[name]@[round(TICK_USAGE, 0.1)]"

/datum/controller/subsystem/netdm_observe/proc/fire_step(resumed)
	if(shutdown_marker && world.time >= next_shutdown_check)
		next_shutdown_check = world.time + 10
		if(fexists(shutdown_marker))
			shutdown_marker = null
			spawn(0)
				Master.Shutdown()
				SSpersistence.RecordGracefulEnding()
				shutdown()
			return
	if(!bridge)
		return
	if(bridge_trace && world.time >= next_bridge_trace)
		next_bridge_trace = world.time + 2 MINUTES
		log_world("netDM bridge: [call_ext(world.system_type == UNIX ? "./netdm_byond.so" : "./netdm_byond.dll", "netdm_status")()]")
		mark("bridge_trace")
	mark("start")
	var/list/replies = bridge.pump(16)
	mark("pump")
	if(!bridge.owner_fence)
		clear_observation()
		if(bridge.connected && world.time >= next_hello && length(GLOB.apcs_list) <= NETDM_OBSERVE_CAP)
			next_hello = world.time + 10
			bridge.negotiate(server_id, round_epoch)
		return

	// The service lane has its own replies and in-flight budget; it never waits for the map lane.
	if(services)
		for(var/list/reply in replies)
			services.accept(reply)
		if(published && services.pump(bridge) < 0)
			return
		for(var/datum/netdm_integration/integration as anything in integrations)
			integration.tick()
		mark("services")

	if(pending)
		for(var/list/reply in replies)
			if(reply["id"] != pending)
				continue
			pending = null
			if(!isnull(pending_view))
				var/level = pending_view
				pending_view = null
				accept_view(level, reply)
				mark("view_reply")
				break
			if(!isnull(inflight_facts))
				// A rejected device delta leaves the Host and DM views unknown: start a new session.
				if(!reply["ok"])
					resynchronize("node delta rejected ([reply["error"]])")
					return
				commit_nodes()
				break
			if(!reply["ok"])
				if(pending_heartbeat)
					resynchronize("observe_heartbeat_rejected")
				else
					discard_export("map request rejected ([reply["error"]])")
				return
			pending_heartbeat = FALSE
			break
		if(pending)
			if(REALTIMEOFDAY >= ack_deadline)
				var/waiting_for = pending_heartbeat ? "heartbeat" : (!isnull(inflight_facts) ? "nodes" : (!isnull(pending_view) ? "view" : phase))
				// Native queues tell a request stuck in the DLL from a reply that never came.
				var/native = call_ext(world.system_type == UNIX ? "./netdm_byond.so" : "./netdm_byond.dll", "netdm_status")()
				resynchronize("observe_ack_timeout in [waiting_for], [pending], [pending_fires] fires, \
					[length(replies)] replies [json_encode(replies)], native [native], \
					dropped [bridge.dropped] last [bridge.last_dropped], stream [bridge.stream_id]")
				return
			pending_fires++
			return

	if(phase == "publish_ack")
		if(published)
			fact_sequence++
		else
			log_world("netDM Observe publishing [length(sample)] APCs with area geometry.")
		published = TRUE
		published_revision = export_revision
		known = sample
		services?.refresh_apc_attachments()
		forget_unmapped_apc_states()
		discard_export()
		if(!life_seeded && world.GetConfig("env", "NETDM_NET_LIFE") == "1")
			seed_network_life()

	// Keep the connection alive during the initial scan and the old graph ready during live updates.
	// The lane is created after the first publication; retry the one-time population seeding here.
	if(!life_seeded && world.GetConfig("env", "NETDM_NET_LIFE") == "1")
		seed_network_life()

	// P13: the population also changes by itself, so the network feels alive between player actions.
	if(services && world.GetConfig("env", "NETDM_NET_LIFE") == "1" && world.time >= next_life_event)
		next_life_event = world.time + rand(6 MINUTES, 14 MINUTES)
		if(prob(60))
			services.control("network_life", list("action" = "spawn", "count" = rand(1, 2),
				"goal" = pick("sentinel", "watcher", "archivist", "courier")),
				CALLBACK(src, PROC_REF(network_life_event_answered)))
		else
			services.control("network_life", list("action" = "retire", "count" = 1),
				CALLBACK(src, PROC_REF(network_life_event_answered)))

	// Keep the connection alive during the initial scan and the old graph ready during live updates.
	if(world.time >= next_heartbeat)
		if(queue(bridge.heartbeat(snapshot_id, sequence_text())))
			pending_heartbeat = TRUE
			next_heartbeat = world.time + 10
		return

	// The map loader and shuttle both yield part-way through updating world turfs.
	if(Master.map_loading || SSair.map_loading_depth || shuttle_mutations)
		return
	if(phase && phase != "live" && export_revision != geometry_revision)
		export_discards++
		discard_export()
		return
	// Device facts flow between map transactions: a staged map update is based on the next fact
	// sequence, so no device delta may interleave with its begin, chunks and commit.
	if(published && world.time >= next_node_flush && (phase == "live" || phase == "scan" || phase == "geometry") && flush_nodes())
		mark("flush")
		return
	// Views only read, but share the single request slot and the same map-transaction gate.
	if(published && (phase == "live" || phase == "scan" || phase == "geometry") && poll_view())
		return

	mark(phase || "idle")
	switch(phase)
		if(null)
			if(world.time < next_scan)
				return
			snapshot_id = rustg_generate_uuid_v4()
			known = list()
			start_scan()
		if("live")
			if(world.time >= next_scan)
				start_scan()
		if("scan")
			var/scanned = scan_batch()
			mark("scan_batch")
			if(!scanned)
				return
			apcs = null
			if(published && export_revision == published_revision && !apcs_changed && length(sample) == length(known))
				discard_export()
				return
			map_export = new(sample)
			phase = "geometry"
		if("geometry")
			var/exported = map_export.advance()
			mark("export:[map_export.phase]:[map_export.index]:cells=[map_export.cells_visited]")
			if(!exported)
				return
			if(map_export.error)
				discard_export(map_export.error)
				return
			if(published)
				update_id = rustg_generate_uuid_v4()
			phase = "begin"
		if("begin")
			var/count = length(map_export.facts)
			var/chunks = CEILING(count / NETDM_OBSERVE_BATCH, 1)
			var/request_id = published \
				? bridge.area_update_begin(snapshot_id, update_id, chunks, count, num2text(fact_sequence + 1, 16)) \
				: bridge.snapshot_begin(snapshot_id, chunks, count, sequence_text(), "apc_map")
			if(queue(request_id))
				chunk_index = 0
				batch_offset = 1
				manifest = ""
				phase = "chunks"
		if("chunks")
			if(batch_offset > length(map_export.facts))
				phase = "commit"
				return
			var/end = min(batch_offset + NETDM_OBSERVE_BATCH, length(map_export.facts) + 1)
			var/facts_json = json_encode(map_export.facts.Copy(batch_offset, end))
			var/digest = uppertext(md5(facts_json))
			mark("chunk:[chunk_index]")
			var/request_id = published \
				? bridge.area_update_chunk(snapshot_id, update_id, chunk_index, facts_json, digest) \
				: bridge.snapshot_chunk(snapshot_id, chunk_index, facts_json, digest)
			if(queue(request_id))
				manifest += digest
				chunk_index++
				batch_offset = end
		if("commit")
			if(published)
				if(queue(bridge.area_update_commit(snapshot_id, update_id, md5(manifest))))
					phase = "publish_ack"
			else if(queue(bridge.snapshot_commit(snapshot_id, md5(manifest))))
				phase = "ready"
		if("ready")
			if(queue(bridge.snapshot_ready(snapshot_id, sequence_text())))
				phase = "publish_ack"

/// The Host forgets the state of an APC that leaves the map; new APCs start up and are checked soon.
/datum/controller/subsystem/netdm_observe/proc/forget_unmapped_apc_states()
	next_apc_state_check = 0
	if(!length(apc_states))
		return
	var/list/mapped = list()
	for(var/key in known)
		mapped[known[key]["a"]] = TRUE
	for(var/node_id in apc_states.Copy())
		if(!mapped[node_id])
			apc_states -= node_id

/// Seeds the network population once per round when the layer is enabled. Content stays opt-in: without
/// the flag nothing is sent, and the Host does not populate its network either.
/datum/controller/subsystem/netdm_observe/proc/seed_network_life()
	life_seeded = TRUE
	if(!services)
	{
		// The lane is created after the map is published; the next fire retries the seeding.
		life_seeded = FALSE
		if(!life_waiting)
			life_waiting = TRUE
			log_world("netDM network life: waiting for the service lane.")
		return
	}
	if(!services.control("network_life", list("action" = "spawn", "count" = 3, "goal" = "courier"),
		CALLBACK(src, PROC_REF(network_life_seeded))))
		life_seeded = FALSE

/datum/controller/subsystem/netdm_observe/proc/network_life_seeded(list/reply)
	var/list/result = reply?["result"]
	if(reply?["ok"])
		log_world("netDM network life: seeded [result?["spawned"]] agents.")
	else
		log_world("netDM network life: the Host refused seeding ([reply?["error"] || "no answer"]).")

/datum/controller/subsystem/netdm_observe/proc/queue(request_id)
	if(!request_id)
		return FALSE
	pending = request_id
	pending_fires = 0
	// Real time, not world.time: after the host machine stalls, ticks catch up faster than replies.
	ack_deadline = REALTIMEOFDAY + NETDM_OBSERVE_ACK_TIMEOUT
	return TRUE

/datum/controller/subsystem/netdm_observe/proc/sequence_text()
	return num2text(fact_sequence, 16)

/datum/controller/subsystem/netdm_observe/proc/start_scan()
	if(length(GLOB.apcs_list) > NETDM_OBSERVE_CAP)
		discard_export("APC inventory exceeds its budget")
		return
	apcs = GLOB.apcs_list.Copy()
	apc_index = 1
	sample = list()
	apcs_changed = FALSE
	export_revision = geometry_revision
	phase = "scan"

/datum/controller/subsystem/netdm_observe/proc/scan_batch()
	for(var/i = 1 to NETDM_OBSERVE_BATCH)
		if(apc_index > length(apcs))
			return TRUE
		var/obj/machinery/power/apc/apc = apcs[apc_index++]
		if(QDELETED(apc))
			continue
		var/turf/position = get_turf(apc)
		var/datum/weakref/key = WEAKREF(apc)
		if(!position || !key || sample[key])
			continue
		var/area/root = netdm_power_area(apc.area)
		var/datum/weakref/root_ref = WEAKREF(root)
		var/primary = root?.power_apc == apc
		var/list/previous = known[key]
		if(previous && previous["x"] == position.x && previous["y"] == position.y && previous["z"] == position.z \
			&& previous["root"] == root_ref && previous["primary"] == primary)
			sample[key] = previous
		else
			var/node_id = previous ? previous["a"] : num2text(++node_serial, 16)
			sample[key] = list("a" = node_id, "x" = position.x, "y" = position.y, "z" = position.z,
				"root" = root_ref, "primary" = primary)
			apcs_changed = TRUE
		if(node_serial >= 16000000)
			resynchronize("apc_id_budget")
			return FALSE
		if(MC_TICK_CHECK)
			return FALSE
	return FALSE

#undef NETDM_OBSERVE_BATCH
#undef NETDM_OBSERVE_CAP
#undef NETDM_NODE_CAP
#undef NETDM_OBSERVE_ACK_TIMEOUT
#undef NETDM_SLOW_FIRE

/// P13: a spontaneous arrival or retirement of the population. It is ambient: the window and the
/// activity feed show it; nothing else in the round depends on it.
/datum/controller/subsystem/netdm_observe/proc/network_life_event_answered(list/reply)
	if(!reply?["ok"])
		return
	var/list/result = reply?["result"]
	log_world("netDM network life: population changed, [result?["total"] || "?"] agents.")
	netdm_incident("population", "", "Население сети изменилось: [result?["total"] || "?"] агентов.")

/// P13: one line of the round's network incident journal; bounded, newest last.
/datum/controller/subsystem/netdm_observe/proc/netdm_incident(kind, node, text)
	netdm_incidents += list(list("at" = round(world.time / 10), "kind" = "[kind]", "node" = "[node]", "text" = "[text]"))
	// The station log is the long-term record; the window shows the round's short journal.
	log_game("netDM incident [kind] node=[node]: [text]")
	if(length(netdm_incidents) > 50)
		netdm_incidents.Cut(1, length(netdm_incidents) - 50)
