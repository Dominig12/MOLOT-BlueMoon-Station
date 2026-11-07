/**
 * Area APCs are network origin points for station science telemetry.
 * Gas reactions are buffered per APC, then delivered using normal NetDM
 * packet receipts. A lost response replays the SAME RPC id, so the shared
 * R&D cluster journal prevents duplicate credits.
 */

/datum/controller/subsystem/research
	var/list/datum/component/netdm_science_telemetry/netdm_station_sensors = list()
	var/netdm_station_sensor_cursor = 1

/datum/controller/subsystem/research/proc/netdm_station_apc(atom/source)
	if(source)
		var/area/location = get_area(source)
		if(!location)
			return null
		if(location.base_area)
			location = location.base_area
		var/obj/machinery/power/apc/controller = location.power_apc
		if(controller && !QDELETED(controller) && is_station_level(controller.z))
			return controller
		return null
	// Unattributed discoveries use the APC of an operational R&D server,
	// rather than fabricating a network endpoint at a world datum.
	var/datum/netdm_rnd_cluster/cluster = netdm_cluster_for(science_tech)
	var/obj/machinery/rnd/server/server = cluster?.find_server(null)
	if(!server || !is_station_level(server.z))
		return null
	var/area/zone = get_area(server)
	if(zone?.base_area)
		zone = zone.base_area
	return zone?.power_apc

/datum/controller/subsystem/research/proc/netdm_station_sensor(atom/source)
	if(!SSnetdm.enabled || !SSnetdm.connected || !SSnetdm.synchronized || !science_tech)
		return null
	var/obj/machinery/power/apc/controller = netdm_station_apc(source)
	if(!controller || !controller.netdm_interface()?.node_id)
		return null
	return controller.AddComponent(/datum/component/netdm_science_telemetry)

/datum/controller/subsystem/research/proc/netdm_queue_station_points(amount, atom/source, type = TECHWEB_POINT_TYPE_GENERIC)
	if(!isnum(amount) || amount <= 0 || !point_types[type])
		return FALSE
	var/datum/component/netdm_science_telemetry/sensor = netdm_station_sensor(source)
	return sensor?.add_points(type, amount)

/datum/controller/subsystem/research/proc/netdm_queue_station_qcd(amount, atom/source)
	if(!isnum(amount) || amount <= 0)
		return FALSE
	var/datum/component/netdm_science_telemetry/sensor = netdm_station_sensor(source)
	return sensor?.add_qcd(amount)

/datum/controller/subsystem/research/proc/netdm_queue_gas_discovery(gas_id, atom/source)
	if(!gas_id || !GLOB.gas_data.datums[gas_id])
		return FALSE
	var/datum/component/netdm_science_telemetry/sensor = netdm_station_sensor(source)
	return sensor?.add_gas(gas_id)

/datum/controller/subsystem/research/proc/netdm_flush_station_telemetry()
	var/limit = min(8, length(netdm_station_sensors))
	for(var/i = 1, i <= limit, i++)
		if(netdm_station_sensor_cursor > length(netdm_station_sensors))
			netdm_station_sensor_cursor = 1
		var/datum/component/netdm_science_telemetry/sensor = netdm_station_sensors[netdm_station_sensor_cursor++]
		if(sensor && !QDELETED(sensor))
			sensor.flush()

/datum/component/netdm_science_telemetry
	dupe_mode = COMPONENT_DUPE_HIGHLANDER
	var/list/points = list()
	var/list/gases = list()
	var/list/qcd = list()
	var/list/inflight
	var/inflight_id
	var/serial = 0
	var/retry_after = 0

/datum/component/netdm_science_telemetry/Initialize(...)
	if(!istype(parent, /obj/machinery/power/apc))
		return COMPONENT_INCOMPATIBLE
	return ..()

/datum/component/netdm_science_telemetry/RegisterWithParent()
	. = ..()
	RegisterSignal(parent, "netdm_packet_received", PROC_REF(on_packet))
	RegisterSignal(parent, "netdm_packet_delivery", PROC_REF(on_delivery))
	SSresearch.netdm_station_sensors |= src

/datum/component/netdm_science_telemetry/UnregisterFromParent()
	SSresearch.netdm_station_sensors -= src
	return ..()

/datum/component/netdm_science_telemetry/proc/add_points(type, amount)
	if(!SSresearch.point_types[type] || !isnum(amount) || amount <= 0)
		return FALSE
	points[type] = min(10000000, (points[type] || 0) + amount)
	return TRUE

/datum/component/netdm_science_telemetry/proc/add_gas(gas_id)
	if(gases[gas_id] || (inflight && inflight["gases"][gas_id]))
		return TRUE
	if(length(gases) >= 128)
		return FALSE
	gases[gas_id] = TRUE
	return TRUE

/datum/component/netdm_science_telemetry/proc/add_qcd(amount)
	if(!isnum(amount) || amount <= 0 || length(qcd) >= 256)
		return FALSE
	qcd += min(100000, amount)
	return TRUE

/datum/component/netdm_science_telemetry/proc/flush()
	if(!inflight && !length(points) && !length(gases) && !length(qcd))
		return
	if(world.time < retry_after || !SSnetdm.enabled || !SSnetdm.connected || !SSnetdm.synchronized)
		return
	var/obj/machinery/power/apc/apc = parent
	if(!apc || QDELETED(apc) || (apc.machine_stat & (NOPOWER | BROKEN | EMPED)))
		return
	var/datum/component/netdm_node/sender = apc.netdm_interface()
	var/datum/netdm_rnd_cluster/cluster = SSresearch.netdm_cluster_for(SSresearch.science_tech)
	var/obj/machinery/rnd/server/server = cluster?.find_server(apc)
	var/datum/component/netdm_node/recipient = server?.netdm_interface()
	if(!sender?.node_id || !recipient?.node_id)
		return
	if(!inflight)
		serial++
		inflight_id = "ss13-science-[sender.node_id]-[world.realtime]-[serial]"
		inflight = list(
			"kind" = "techweb_request", "rpc_id" = inflight_id,
			"op" = "station_award", "points" = points.Copy(), "gases" = gases.Copy(), "qcd" = qcd.Copy())
		points.Cut()
		gases.Cut()
		qcd.Cut()
	// Retransmissions reuse the identical rpc_id and the identical payload.
	var/datum/netdm_transaction/transaction = sender.send_to(recipient, inflight,
		128 + length(inflight["points"]) * 16 + length(inflight["gases"]) * 16 + length(inflight["qcd"]) * 8, TRUE, 90)
	retry_after = world.time + 100
	if(!transaction)
		retry_after = world.time + 30

/datum/component/netdm_science_telemetry/proc/on_delivery(datum/source, request_id, state, reason)
	SIGNAL_HANDLER
	if(state != "delivered" && inflight)
		retry_after = min(retry_after, world.time + 30)

/datum/component/netdm_science_telemetry/proc/on_packet(datum/source,
	list/payload, datum/component/netdm_node/sender, request_id)
	SIGNAL_HANDLER
	if(!inflight || !islist(payload) || payload["kind"] != "techweb_telemetry_reply" || payload["rpc_id"] != inflight_id)
		return
	var/obj/machinery/rnd/server/server = sender?.parent
	if(!istype(server) || server.stored_research != SSresearch.science_tech)
		return
	if(!payload["ok"])
		retry_after = world.time + 30
		return
	inflight = null
	inflight_id = null
	retry_after = 0
