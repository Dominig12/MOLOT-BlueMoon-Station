/// A multitool waits this long for the APC's answer before it says there is none.
#define NETDM_DIAGNOSTICS_TIMEOUT (10 SECONDS)
/// Requests waiting for an answer at once; a further one is told to wait.
#define NETDM_DIAGNOSTICS_PENDING 32
/// APCs watched at once; the Host publishes for at most 64 watched devices.
#define NETDM_DIAGNOSTICS_WATCHED 64

/**
 * network.diagnostics (design 7.6, 14.1): an engineer's multitool asks an APC's network module about itself.
 *
 * An APC offers the service the first time it is asked; a station has hundreds of APCs, and nearly all of
 * them are never inspected. The request is a network command to the APC's own node, and the Host answers
 * on the APC's behalf from the published world: the module's state, its radio access point, the devices
 * plugged into it, and each APC its cables lead to with the reason a cable carries nothing. The module
 * reports its own ports only; what lies beyond a dead neighbour is found by walking there.
 * A module without power answers nothing, like any device without power.
 */
/datum/netdm_diagnostics
	/// Idempotency key -> list("apc", "user", "instance", "deadline", "sent").
	var/list/pending = list()
	/// Operation ID -> idempotency key, for the answers.
	var/list/operations = list()
	var/serial = 0
	var/list/counters = list("asked" = 0, "answered" = 0, "no_answer" = 0, "refused" = 0, "events" = 0, "queries" = 0, "pages" = 0)
	/// Watched instance -> its last published link state: list("state", "wired", "wired_up", "radio", "devices", "neighbors", "at").
	/// It is what reached a watcher over the network, so it may be old; "at" is the world time it arrived.
	var/list/link_states = list()
	/// Directory queries waiting for their page: key -> list("asker", "apc", "instance", "arguments", "callback", "deadline", "sent").
	var/list/queries = list()
	/// Operation ID -> query key.
	var/list/query_operations = list()
	/// The last report: list("apc" = weakref, "state", "wired", "wired_up", "radio", "devices", "neighbors" = list(node ID -> state), "lines").
	var/list/last_report

/datum/netdm_diagnostics/proc/setup(datum/netdm_service_lane/lane)
	lane.dispatcher.allow_result("link_state", new /datum/netdm_effect_handler/network_link_state, "network.diagnostics")
	lane.dispatcher.allow("network.link_state", new /datum/netdm_effect_handler/network_link_event)
	lane.dispatcher.allow_result("services", new /datum/netdm_effect_handler/network_query_page, "network.query")

/// A new Host session: the APC endpoints attach again and waiting requests are sent again.
/datum/netdm_diagnostics/proc/reset_session()
	operations.Cut()
	query_operations.Cut()
	for(var/key in pending)
		var/list/request = pending[key]
		request["sent"] = FALSE
	for(var/key in queries)
		var/list/query = queries[key]
		query["sent"] = FALSE

/// Asks the APC's network module. Returns TRUE when the click was taken, also when it only tells why not.
/datum/netdm_diagnostics/proc/inspect(obj/machinery/power/apc/apc, mob/user)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!lane || !SSnetdm_observe.published)
		return FALSE
	if(!SSnetdm_observe.apc_node_id(apc))
		tell(user, span_warning("Сетевой модуль этого АПЦ не входит в карту сети."))
		return TRUE
	counters["asked"]++
	if(apc.netdm_state() != NETDM_STATE_UP)
		// The module itself is dead: it cannot take the request, whatever the network could carry.
		counters["no_answer"]++
		tell(user, span_warning("Сетевой модуль АПЦ не отвечает: нет питания или неисправен."))
		return TRUE
	if(length(pending) >= NETDM_DIAGNOSTICS_PENDING)
		tell(user, span_warning("Диагностика занята, повторите позже."))
		return TRUE
	var/datum/netdm_service_endpoint/endpoint = lane.endpoint_for(apc)
	if(!endpoint)
		return FALSE
	var/instance = "netdiag.[endpoint.id]"
	lane.offer(apc, instance, "network.diagnostics", "network.link_state", 1)
	pending["nd-[++serial]"] = list("apc" = WEAKREF(apc), "user" = user ? WEAKREF(user) : null, "instance" = instance,
		"deadline" = world.time + NETDM_DIAGNOSTICS_TIMEOUT, "sent" = FALSE)
	tell(user, span_notice("Запрос к сетевому модулю АПЦ..."))
	return TRUE

/**
 * State watch: a network node (a netDM device node or an APC) subscribes to an APC's link state. The Host
 * publishes the state from the APC's node when it changes, and the publication travels the network to the
 * watcher: a watcher the network does not reach learns nothing, and a dead APC publishes nothing.
 * Returns the watched instance, or null. The first publication follows within a second.
 */
/datum/netdm_diagnostics/proc/watch(datum/watcher, obj/machinery/power/apc/apc)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!lane || !SSnetdm_observe.apc_node_id(apc))
		return null
	var/datum/netdm_service_endpoint/endpoint = lane.endpoint_for(apc)
	if(!endpoint)
		return null
	var/instance = "netdiag.[endpoint.id]"
	if(isnull(link_states[instance]) && length(link_states) >= NETDM_DIAGNOSTICS_WATCHED)
		return null
	lane.offer(apc, instance, "network.diagnostics", "network.link_state", 1)
	if(!lane.want(watcher, "links.[endpoint.id]", instance, "network.link_state", 1, "full"))
		return null
	if(isnull(link_states[instance]))
		link_states[instance] = list()
	return instance

/// A publication of a watched APC reached a watcher.
/datum/netdm_diagnostics/proc/link_event(list/item)
	var/instance = item["instance"]
	var/list/payload = item["payload"]
	if(isnull(link_states[instance]) || !islist(payload))
		return "not_watched"
	var/list/neighbors = list()
	for(var/pair in splittext("[payload["neighbors"]]", ","))
		var/list/parts = splittext(pair, ":")
		if(length(parts) == 2)
			neighbors[parts[1]] = parts[2]
	link_states[instance] = list("state" = payload["state"], "wired" = netdm_number(payload["wired"]),
		"wired_up" = netdm_number(payload["wiredUp"]), "radio" = !!payload["radio"], "devices" = netdm_number(payload["devices"]),
		"neighbors" = neighbors, "at" = world.time)
	counters["events"]++
	return TRUE

/**
 * network.query (design 14.5): a network node asks an APC which services the network offers. The answer
 * is one bounded page of what the asker may discover and that APC reaches now, in instance order; a
 * service that is hidden or cut off is simply absent. on_page receives
 * list("status", "revision", "cursor", "items" = list(list("instance", "type", "hops"))); the status is
 * "complete", "partial" (pass the cursor to continue), "empty", "snapshot_expired" (the directory changed:
 * start over), "invalid_cursor", or "no_answer" when the network returned nothing in time.
 * Returns FALSE when the query cannot even be queued.
 */
/datum/netdm_diagnostics/proc/query_services(datum/asker, obj/machinery/power/apc/apc, service_type, datum/callback/on_page, limit = 8, cursor)
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(!lane || !on_page || !SSnetdm_observe.apc_node_id(apc) || length(queries) >= NETDM_DIAGNOSTICS_PENDING)
		return FALSE
	var/datum/netdm_service_endpoint/endpoint = lane.endpoint_for(apc)
	if(!endpoint)
		return FALSE
	var/instance = "netquery.[endpoint.id]"
	lane.offer(apc, instance, "network.query", "query.page", 1)
	var/list/arguments = list("limit" = clamp(round(limit), 1, 16))
	if(service_type)
		arguments["type"] = service_type
	if(cursor)
		arguments["cursor"] = cursor
	counters["queries"]++
	queries["nq-[++serial]"] = list("asker" = WEAKREF(asker), "apc" = WEAKREF(apc), "instance" = instance, "arguments" = arguments,
		"callback" = on_page, "deadline" = world.time + NETDM_DIAGNOSTICS_TIMEOUT, "sent" = FALSE)
	return TRUE

/datum/netdm_diagnostics/proc/pump_queries(datum/netdm_service_lane/lane)
	for(var/key in queries.Copy())
		var/list/query = queries[key]
		var/datum/weakref/asker_ref = query["asker"]
		var/datum/weakref/apc_ref = query["apc"]
		var/datum/asker = asker_ref.resolve()
		var/obj/machinery/power/apc/apc = apc_ref.resolve()
		if(QDELETED(asker) || QDELETED(apc) || world.time > query["deadline"])
			finish_query(key, list("status" = "no_answer", "items" = list()))
			continue
		if(query["sent"] || !lane?.ready(apc, query["instance"]))
			continue
		if(lane.invoke(asker, query["instance"], "services", key, query["arguments"], CALLBACK(src, PROC_REF(query_accepted), key)))
			query["sent"] = TRUE

/datum/netdm_diagnostics/proc/query_accepted(key, list/entry, list/reply)
	if(!queries[key])
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		query_operations["[value["operationId"]]"] = key
		return
	finish_query(key, list("status" = "refused", "reason" = reply["error"], "items" = list()))

/// The page came back to the asker over the network.
/datum/netdm_diagnostics/proc/query_answered(list/item)
	var/key = query_operations["[item["operationId"]]"]
	query_operations -= "[item["operationId"]]"
	var/list/payload = item["payload"]
	if(!key || !queries[key] || !islist(payload))
		return TRUE
	var/list/items = list()
	for(var/row in splittext("[payload["items"]]", ","))
		var/list/parts = splittext(row, "|")
		if(length(parts) == 3)
			items += list(list("instance" = parts[1], "type" = parts[2], "hops" = text2num(parts[3])))
	counters["pages"]++
	finish_query(key, list("status" = payload["status"], "revision" = netdm_number(payload["revision"]), "cursor" = payload["cursor"], "items" = items))
	return TRUE

/datum/netdm_diagnostics/proc/finish_query(key, list/page)
	var/list/query = queries[key]
	queries -= key
	var/datum/callback/on_page = query?["callback"]
	on_page?.Invoke(page)

/// Sends the requests whose APC is attached, and gives up on those that waited too long.
/datum/netdm_diagnostics/proc/tick()
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	if(length(queries))
		pump_queries(lane)
	if(!length(pending))
		return
	for(var/key in pending.Copy())
		var/list/request = pending[key]
		var/datum/weakref/apc_ref = request["apc"]
		var/obj/machinery/power/apc/apc = apc_ref.resolve()
		if(QDELETED(apc) || world.time > request["deadline"])
			finish(key, apc ? span_warning("Сетевой модуль АПЦ не отвечает: нет питания, неисправен или нет связи.") : null)
			counters["no_answer"]++
			continue
		if(request["sent"] || !lane?.ready(apc, request["instance"]))
			continue
		if(lane.invoke(apc, request["instance"], "link_state", key, list("reason" = "inspect"), CALLBACK(src, PROC_REF(accepted), key)))
			request["sent"] = TRUE

/datum/netdm_diagnostics/proc/accepted(key, list/entry, list/reply)
	if(!pending[key])
		return
	var/list/result = reply["result"]
	var/list/value = islist(result) ? result["value"] : null
	if(reply["ok"] && islist(value) && !isnull(value["operationId"]))
		operations["[value["operationId"]]"] = key
		return
	counters["refused"]++
	finish(key, span_warning("Сетевой модуль АПЦ отклонил запрос ([reply["error"] || "нет ответа"])."))

/// The APC's answer came back to it: the report goes to whoever asked.
/datum/netdm_diagnostics/proc/answered(obj/machinery/power/apc/apc, list/item)
	var/key = operations["[item["operationId"]]"]
	operations -= "[item["operationId"]]"
	var/list/payload = item["payload"]
	if(!key || !pending[key] || !islist(payload))
		return TRUE
	var/list/neighbors = list()
	var/list/lines = list("Сетевой модуль АПЦ «[get_area_name(apc, TRUE)]»: [state_name(payload["state"])]. \
		Кабелей к соседним АПЦ: [netdm_number(payload["wired"])], на связи: [netdm_number(payload["wiredUp"])]. \
		Радиоточка: [payload["radio"] ? "работает" : "нет"]. Подключено устройств: [netdm_number(payload["devices"])].")
	for(var/pair in splittext("[payload["neighbors"]]", ","))
		var/list/parts = splittext(pair, ":")
		if(length(parts) != 2)
			continue
		neighbors[parts[1]] = parts[2]
		var/obj/machinery/power/apc/neighbor = SSnetdm_observe.apc_by_node_id(parts[1])
		lines += "— [neighbor ? "«[get_area_name(neighbor, TRUE)]»" : "узел [parts[1]]"]: [state_name(parts[2])]"
	if(payload["more"])
		lines += "— ...и другие соседи, не вошедшие в отчёт."
	last_report = list("apc" = WEAKREF(apc), "state" = payload["state"], "wired" = netdm_number(payload["wired"]),
		"wired_up" = netdm_number(payload["wiredUp"]), "radio" = !!payload["radio"], "devices" = netdm_number(payload["devices"]),
		"neighbors" = neighbors, "lines" = lines)
	counters["answered"]++
	finish(key, span_notice(jointext(lines, "<br>")))
	return TRUE

/datum/netdm_diagnostics/proc/state_name(state)
	switch(state)
		if("active", "up")
			return "на связи"
		if("unpowered")
			return "нет питания"
		if("broken")
			return "неисправен"
	return "нет связи"

/datum/netdm_diagnostics/proc/finish(key, text)
	var/list/request = pending[key]
	pending -= key
	var/datum/weakref/user_ref = request?["user"]
	if(text)
		tell(user_ref?.resolve(), text)

/datum/netdm_diagnostics/proc/tell(mob/user, text)
	if(user)
		to_chat(user, text)

/datum/netdm_diagnostics/proc/state()
	return "diagnostics asked=[counters["asked"]] answered=[counters["answered"]] no_answer=[counters["no_answer"]] \
		refused=[counters["refused"]] pending=[length(pending)] watched=[length(link_states)] events=[counters["events"]] \
		queries=[counters["queries"]] pages=[counters["pages"]]"

/datum/netdm_effect_handler/network_link_state/apply(datum/target, list/item)
	if(!istype(target, /obj/machinery/power/apc) || !SSnetdm_observe.diagnostics)
		return "not_an_apc"
	return SSnetdm_observe.diagnostics.answered(target, item)

/datum/netdm_effect_handler/network_query_page/apply(datum/target, list/item)
	return SSnetdm_observe.diagnostics ? SSnetdm_observe.diagnostics.query_answered(item) : "no_diagnostics"

/datum/netdm_effect_handler/network_link_event/apply(datum/target, list/item)
	return SSnetdm_observe.diagnostics ? SSnetdm_observe.diagnostics.link_event(item) : "no_diagnostics"

#undef NETDM_DIAGNOSTICS_WATCHED
#undef NETDM_DIAGNOSTICS_TIMEOUT
#undef NETDM_DIAGNOSTICS_PENDING
