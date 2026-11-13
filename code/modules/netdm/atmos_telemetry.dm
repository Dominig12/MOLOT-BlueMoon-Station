/// Time a report waits for its netDM deliveries before the comparison with the radio path.
#define NETDM_TELEMETRY_SETTLE (5 SECONDS)
/// Reports kept for comparison at once; the oldest are compared early when this fills up.
#define NETDM_TELEMETRY_REPORTS 256
/// Latency samples kept for percentiles.
#define NETDM_TELEMETRY_SAMPLES 512

/**
 * atmos.telemetry pilot in Shadow mode (P4).
 *
 * Gas sensors keep reporting over the legacy radio frequency, and the atmos consoles keep showing
 * those reports. Every report is also published as atmos.sample by the sensor's service instance;
 * a console subscribes to the instances of the sensors in its list and asks each for a snapshot.
 * Deliveries are only recorded: the console screen does not change. Each report is then compared:
 * which consoles took it from the radio and which received it over netDM, how long that took,
 * and why a console that the radio reached did not receive it.
 *
 * The instance name joins the frequency and the id_tag, the same pair that links them on the radio.
 */
/datum/netdm_telemetry_shadow
	/// "instance/tick" -> report record, in creation order.
	var/list/reports = list()
	/// End-to-end latencies of matched deliveries, microseconds, newest last.
	var/list/latencies = list()
	var/list/snapshot_latencies = list()
	/// Snapshot requests of this session: "endpoint/instance" -> TRUE; operation ID -> start time.
	var/list/snapshots_requested = list()
	var/list/snapshot_started = list()
	var/snapshot_serial = 0
	var/next_snapshot_check = 0
	/// Consoles with a node: console weakref -> TRUE.
	var/list/consoles = list()
	/// Sensors with a node: sensor weakref -> TRUE; instances they offer -> TRUE.
	var/list/sensors = list()
	var/list/sensor_instances = list()
	/// Console endpoint ID -> list("matched", "radio_only", reason -> count), for station reports.
	var/list/per_console = list()
	/// "console/instance" -> list(reason, world.time until it is trusted): a console that the network
	/// cannot reach stays unreachable for a while, so its delivery states are not asked every report.
	var/list/reason_cache = list()
	var/list/counters = list("reports" = 0, "compared" = 0, "unmirrored" = 0, "matched" = 0,
		"legacy_only" = 0, "netdm_only" = 0, "unknown_tick" = 0, "snapshots" = 0, "snapshot_requests" = 0)
	/// Reason of a console that the radio reached and netDM did not -> count.
	var/list/reasons = list()
	/// Latest mismatches, for diagnostics.
	var/list/mismatches = list()

/datum/netdm_telemetry_shadow/proc/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow("atmos.sample", new /datum/netdm_effect_handler/atmos_shadow)
	lane.dispatcher.allow_command("atmos.telemetry", "sample", new /datum/netdm_command_handler/atmos_sample)
	lane.dispatcher.allow_result("sample", new /datum/netdm_effect_handler/atmos_snapshot)

/datum/netdm_telemetry_shadow/proc/reset_session()
	// Deliveries of the old session will never arrive: those reports are not compared.
	reports.Cut()
	reason_cache.Cut()
	snapshots_requested.Cut()
	snapshot_started.Cut()

/datum/netdm_telemetry_shadow/proc/add_sensor(obj/machinery/air_sensor/sensor, datum/component/netdm_node/node)
	var/instance = netdm_atmos_instance(sensor.frequency, sensor.id_tag)
	if(instance && node)
		SSnetdm_observe.services.offer(node, instance, "atmos.telemetry", "atmos.sample", 1)
		sensors[WEAKREF(sensor)] = TRUE
		sensor_instances[instance] = TRUE

/datum/netdm_telemetry_shadow/proc/add_console(obj/machinery/computer/atmos_control/console, datum/component/netdm_node/node)
	if(!node)
		return
	// A tank console without both device tags takes every sensor report as its input device:
	// the signal has no "tag", and null equals null. It never shows sensors, so it does not subscribe.
	if(istype(console, /obj/machinery/computer/atmos_control/tank))
		var/obj/machinery/computer/atmos_control/tank/tank_console = console
		if(!tank_console.input_tag || !tank_console.output_tag)
			return
	consoles[WEAKREF(console)] = TRUE
	for(var/id_tag in console.sensors)
		var/instance = netdm_atmos_instance(console.frequency, id_tag)
		if(instance)
			SSnetdm_observe.services.want(node, instance, instance, "atmos.sample", 1, "full")

/// The full atmos.sample payload of the last radio report, or null before the first one.
/datum/netdm_telemetry_shadow/proc/sample_of(obj/machinery/air_sensor/sensor)
	if(isnull(sensor.last_report_pressure))
		return null
	var/reported_at = sensor.next_forced_report - ATMOS_TELEMETRY_HEARTBEAT
	return list(
		"pressureKPa" = clamp(round(sensor.last_report_pressure, 0.01), 0, 1000000),
		"temperatureK" = clamp(round(sensor.last_report_temperature, 0.01), 0, 1000000),
		"sampleTick" = netdm_tick_of(reported_at),
		"quality" = "current",
	)

/datum/netdm_telemetry_shadow/proc/report_for(instance, tick)
	var/key = "[instance]/[tick]"
	var/list/report = reports[key]
	if(report)
		return report
	report = list("instance" = instance, "tick" = tick, "created" = world.time, "legacy" = list(), "netdm" = list())
	reports[key] = report
	counters["reports"]++
	if(length(reports) > NETDM_TELEMETRY_REPORTS)
		compare(reports[reports[1]])
		reports.Cut(1, 2)
	return report

/// The radio report of a sensor left; its netDM copy goes to the lane.
/datum/netdm_telemetry_shadow/proc/sensor_reported(obj/machinery/air_sensor/sensor)
	var/datum/component/netdm_node/node = sensor.GetComponent(/datum/component/netdm_node)
	var/instance = netdm_atmos_instance(sensor.frequency, sensor.id_tag)
	var/list/payload = sample_of(sensor)
	if(!node || !instance || !payload)
		return
	var/list/report = report_for(instance, payload["sampleTick"])
	var/list/entry = SSnetdm_observe.services.publish(node, instance, payload, CALLBACK(src, PROC_REF(published), report))
	if(entry)
		report["queued_us"] = entry["queued_us"]
	else
		report["unmirrored"] = "not_ready"

/datum/netdm_telemetry_shadow/proc/published(list/report, list/entry, list/reply)
	if(!reply["ok"])
		report["unmirrored"] = reply["error"] || "rejected"
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	report["message"] = islist(value) ? value["messageId"] : null
	report["sent_at"] = entry["sent_at"]
	report["sent_us"] = entry["sent_us"]
	report["accepted_us"] = entry["accepted_us"]

/// A console took a sensor report from the radio.
/datum/netdm_telemetry_shadow/proc/legacy_received(obj/machinery/computer/atmos_control/console, id_tag, timestamp)
	var/instance = netdm_atmos_instance(console.frequency, id_tag)
	// Loop meters and other radio sources are not in the pilot: nothing to compare.
	if(!instance || !isnum(timestamp) || !sensor_instances[instance])
		return
	var/list/report = report_for(instance, netdm_tick_of(timestamp))
	report["legacy"][console_key(console)] = TRUE

/datum/netdm_telemetry_shadow/proc/console_key(obj/machinery/computer/atmos_control/console)
	var/datum/component/netdm_node/node = console.GetComponent(/datum/component/netdm_node)
	var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services.by_node[node] : null
	return endpoint ? endpoint.id : "ref:[REF(console)]"

/// A console received a sample over netDM: recorded, never shown.
/datum/netdm_telemetry_shadow/proc/netdm_received(obj/machinery/computer/atmos_control/console, list/item, kind)
	var/list/payload = item["payload"]
	if(kind == "snapshot")
		counters["snapshots"]++
		var/started = snapshot_started[item["operationId"]]
		if(!isnull(started))
			snapshot_started -= item["operationId"]
			push(snapshot_latencies, netdm_now_us() - started)
		return TRUE
	var/tick = islist(payload) ? payload["sampleTick"] : null
	var/list/report = reports["[item["instance"]]/[tick]"]
	if(!report)
		// A sample older than the comparison window, or from before a new session.
		counters["unknown_tick"]++
		return TRUE
	var/now = netdm_now_us()
	var/latency = isnull(report["queued_us"]) ? 0 : now - report["queued_us"]
	report["netdm"][item["recipient"]] = latency
	// A slow delivery names its stage: waiting in DM, Host acceptance, or transport and inbox.
	if(latency > 500000 && !isnull(report["sent_us"]) && !isnull(report["accepted_us"]))
		note("slow [round(latency / 1000)] ms [report["instance"]] tick [report["tick"]]: queue [round((report["sent_us"] - report["queued_us"]) / 1000)] accept [round((report["accepted_us"] - report["sent_us"]) / 1000)] deliver [round((now - report["accepted_us"]) / 1000)]")
	return TRUE

/datum/netdm_telemetry_shadow/proc/push(list/samples, value)
	samples += value
	if(length(samples) > NETDM_TELEMETRY_SAMPLES)
		samples.Cut(1, 2)

/// Compares settled reports and asks consoles that subscribed for a snapshot. Called every fire.
/datum/netdm_telemetry_shadow/proc/tick()
	while(length(reports))
		var/list/report = reports[reports[1]]
		if(world.time < report["created"] + NETDM_TELEMETRY_SETTLE)
			break
		// A comparison may need a status query. While their queue is full (the Host is late to answer),
		// reports wait, bounded by NETDM_TELEMETRY_REPORTS, instead of losing their reasons.
		if(!SSnetdm_observe.services.can_query())
			break
		reports.Cut(1, 2)
		compare(report)
	if(world.time < next_snapshot_check)
		return
	next_snapshot_check = world.time + 1 SECONDS
	for(var/datum/weakref/console_ref as anything in consoles)
		var/obj/machinery/computer/atmos_control/console = console_ref.resolve()
		if(QDELETED(console))
			consoles -= console_ref
			continue
		var/datum/component/netdm_node/node = console.GetComponent(/datum/component/netdm_node)
		var/datum/netdm_service_endpoint/endpoint = node ? SSnetdm_observe.services.by_node[node] : null
		if(!endpoint)
			continue
		for(var/instance in endpoint.subscribed)
			var/key = "[endpoint.id]/[instance]"
			if(snapshots_requested[key])
				continue
			snapshots_requested[key] = TRUE
			var/list/entry = SSnetdm_observe.services.invoke(node, instance, "sample", "snap[++snapshot_serial]",
				list("reason" = "subscribe"), CALLBACK(src, PROC_REF(snapshot_accepted)))
			if(entry)
				entry["started_us"] = netdm_now_us()
				counters["snapshot_requests"]++

/datum/netdm_telemetry_shadow/proc/snapshot_accepted(list/entry, list/reply)
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	var/operation = islist(value) ? value["operationId"] : null
	if(reply["ok"] && operation)
		snapshot_started[operation] = entry["started_us"]

/datum/netdm_telemetry_shadow/proc/compare(list/report)
	if(report["unmirrored"] || !report["message"])
		counters["unmirrored"]++
		return
	counters["compared"]++
	var/list/legacy = report["legacy"]
	var/list/netdm = report["netdm"]
	var/list/missing = list()
	for(var/console in legacy)
		if(isnull(netdm[console]))
			missing += console
			continue
		counters["matched"]++
		var/list/stats = console_stats(console)
		stats["matched"]++
		push(latencies, netdm[console])
	for(var/console in netdm)
		if(!legacy[console])
			counters["netdm_only"]++
			var/list/stats = console_stats(console)
			stats["netdm_only"]++
			note("[report["instance"]] tick [report["tick"]]: [console] got the sample without the radio")
	if(!length(missing))
		return
	counters["legacy_only"] += length(missing)
	for(var/console in missing)
		var/list/stats = console_stats(console)
		stats["radio_only"]++
	// Consoles that never subscribed explain themselves; the rest need the delivery states.
	var/list/undelivered = list()
	for(var/console in missing)
		var/list/cached = reason_cache["[console]/[report["instance"]]"]
		if(cached && world.time < cached[2])
			reasons[cached[1]]++
			var/list/stats = console_stats(console)
			stats[cached[1]]++
			continue
		var/datum/netdm_service_endpoint/endpoint = SSnetdm_observe.services.endpoints[console]
		if(!endpoint)
			reasons["no_endpoint"]++
			var/list/stats = console_stats(console)
			stats["no_endpoint"]++
		else if(!endpoint.subscribed[report["instance"]])
			reasons["not_subscribed"]++
			var/list/stats = console_stats(console)
			stats["not_subscribed"]++
		else
			undelivered += console
	if(length(undelivered) && !SSnetdm_observe.services.query_status(report["message"], CALLBACK(src, PROC_REF(explain), report, undelivered)))
		reasons["unexplained"] += length(undelivered)

/// Delivery states of the consoles that the radio reached and netDM did not.
/datum/netdm_telemetry_shadow/proc/explain(list/report, list/undelivered, list/reply)
	// Only a missing route outlives one report; any other reason is asked again.
	var/static/list/lasting = list("invalid_route" = TRUE, "no_route" = TRUE)
	var/list/states = list()
	var/list/result = reply["result"]
	var/list/deliveries = islist(result) ? result["deliveries"] : null
	for(var/list/delivery in deliveries)
		states[delivery["recipient"]] = delivery["reason"] || delivery["state"]
	for(var/console in undelivered)
		var/reason = states[console] || why_not_recipient(console, report, reply, length(deliveries))
		reasons[reason]++
		if(lasting[reason])
			reason_cache["[console]/[report["instance"]]"] = list(reason, world.time + 30 SECONDS)
		var/list/stats = console_stats(console)
		stats[reason]++
		note("[report["instance"]] tick [report["tick"]]: [console] [reason]")

/// The Host made no delivery for a console that is subscribed now. It fixed the recipients when it
/// accepted the sample, so a subscription requested after that was not one; anything else is a defect.
/datum/netdm_telemetry_shadow/proc/why_not_recipient(console, list/report, list/reply, deliveries)
	if(!reply["ok"])
		return "status_[reply["error"]]"
	var/datum/netdm_service_endpoint/endpoint = SSnetdm_observe.services.endpoints[console]
	var/subscribed_at = endpoint ? endpoint.acknowledged_at[report["instance"]] : null
	if(!isnull(subscribed_at) && !isnull(report["sent_at"]) && subscribed_at > report["sent_at"])
		return "subscribed_later"
	return deliveries ? "not_recipient" : "no_recipients"

/datum/netdm_telemetry_shadow/proc/console_stats(console)
	var/list/stats = per_console[console]
	if(!stats)
		stats = list("matched" = 0, "radio_only" = 0)
		per_console[console] = stats
	return stats

/datum/netdm_telemetry_shadow/proc/note(text)
	mismatches += text
	if(length(mismatches) > 16)
		mismatches.Cut(1, 2)

/// Percentile of microsecond samples, in milliseconds.
/datum/netdm_telemetry_shadow/proc/percentile_ms(list/samples, fraction)
	if(!length(samples))
		return null
	var/list/sorted = sortTim(samples.Copy(), GLOBAL_PROC_REF(cmp_numeric_asc))
	var/index = clamp(CEILING(length(sorted) * fraction, 1), 1, length(sorted))
	return round(sorted[index] / 1000, 0.1)

/datum/netdm_telemetry_shadow/proc/state()
	var/list/reason_text = list()
	for(var/reason in reasons)
		reason_text += "[reason]:[reasons[reason]]"
	return "telemetry reports=[counters["reports"]] compared=[counters["compared"]] matched=[counters["matched"]] \
		radio_only=[counters["legacy_only"]] netdm_only=[counters["netdm_only"]] unmirrored=[counters["unmirrored"]] \
		p50=[percentile_ms(latencies, 0.5)]ms p95=[percentile_ms(latencies, 0.95)]ms max=[percentile_ms(latencies, 1)]ms \
		snapshots=[counters["snapshots"]]/[counters["snapshot_requests"]] reasons=[jointext(reason_text, ",")]"

/// Instance of a gas sensor: the frequency and id_tag that also link it on the radio, or null.
/proc/netdm_atmos_instance(frequency, id_tag)
	if(!istext(id_tag) || !length(id_tag) || !isnum(frequency))
		return null
	var/static/regex/unsafe = new(@"[^a-z0-9._-]", "g")
	var/name = "atmos.[frequency].[unsafe.Replace(lowertext(id_tag), "-")]"
	return length(name) <= 64 ? name : null

/// Simulation tick of a world.time; the radio timestamp and the netDM sample use the same one.
/proc/netdm_tick_of(time)
	return round(time / world.tick_lag)

/datum/netdm_effect_handler/atmos_shadow/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/computer/atmos_control) || !SSnetdm_observe.telemetry)
		return "not_a_console"
	return SSnetdm_observe.telemetry.netdm_received(target, item, "event")

/datum/netdm_effect_handler/atmos_snapshot/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/computer/atmos_control) || !SSnetdm_observe.telemetry)
		return "not_a_console"
	return SSnetdm_observe.telemetry.netdm_received(target, item, "snapshot")

/// The sensor answers a snapshot request with its last report; a silent sensor has nothing to give.
/datum/netdm_command_handler/atmos_sample/execute(datum/target, list/item)
	var/obj/machinery/air_sensor/sensor = target
	if(!istype(sensor) || !SSnetdm_observe.telemetry)
		return "not_a_sensor"
	var/list/sample = SSnetdm_observe.telemetry.sample_of(sensor)
	return sample ? list("result" = sample) : "no_sample"

// The pilot devices. Without Observe nothing below adds a component or a call.
/obj/machinery/air_sensor/Initialize(mapload)
	. = ..()
	if(. == INITIALIZE_HINT_QDEL)
		return
	var/datum/component/netdm_node/node = netdm_make_node(src)
	if(node)
		SSnetdm_observe.telemetry?.add_sensor(src, node)

/obj/machinery/air_sensor/try_report()
	. = ..()
	if(.)
		SSnetdm_observe.telemetry?.sensor_reported(src)

/obj/machinery/computer/atmos_control/Initialize(mapload)
	. = ..()
	if(. == INITIALIZE_HINT_QDEL)
		return
	var/datum/component/netdm_node/node = netdm_make_node(src)
	if(node)
		SSnetdm_observe.telemetry?.add_console(src, node)

/obj/machinery/computer/atmos_control/receive_signal(datum/signal/signal)
	. = ..()
	var/id_tag = signal?.data["id_tag"]
	// The legacy console took the report exactly when it stored this signal's data.
	if(id_tag && SSnetdm_observe.telemetry && sensor_information[id_tag] == signal.data)
		SSnetdm_observe.telemetry.legacy_received(src, id_tag, signal.data["timestamp"])

#undef NETDM_TELEMETRY_SETTLE
#undef NETDM_TELEMETRY_REPORTS
#undef NETDM_TELEMETRY_SAMPLES
