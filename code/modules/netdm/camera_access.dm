/// A selected feed is valid for a short period. Open consoles renew it through the service lane.
#define NETDM_CAMERA_LEASE (8 SECONDS)
#define NETDM_CAMERA_RENEW (3 SECONDS)
#define NETDM_CAMERA_DEADLINE (5 SECONDS)
#define NETDM_CAMERA_DOMAIN "camera"

/obj/machinery/computer/security
	var/datum/weakref/netdm_camera_target
	/// P13: the network window opened from this console, if any.
	var/datum/netdm_terminal/local/console/netdm_window
	var/netdm_camera_instance
	var/netdm_camera_operation
	var/netdm_camera_request
	var/netdm_camera_stream
	var/netdm_camera_serial = 0
	var/netdm_camera_deadline = 0
	var/netdm_camera_lease = 0
	var/netdm_camera_next = 0
	var/netdm_camera_timer
	var/netdm_camera_status
	var/list/netdm_camera_viewers

/proc/netdm_cameras_enabled()
	return SSnetdm_observe?.observing() && world.GetConfig("env", "NETDM_CAMERA_MODE") == "authoritative"

/// Declares a camera-domain endpoint during initialization, before anyone opens a console.
/proc/netdm_register_camera_node(atom/movable/device, offers_feed = FALSE)
	if(!netdm_cameras_enabled())
		return
	var/datum/component/netdm_node/node = netdm_make_node(device)
	if(!node || !SSnetdm_observe.nodes[node])
		return
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/netdm_service_endpoint/endpoint = lane.endpoint_for(node, NETDM_CAMERA_DOMAIN)
	if(endpoint && offers_feed)
		lane.offer(node, "camera.[endpoint.id]", "camera.access", "camera.access", 1)

/obj/machinery/computer/security/proc/netdm_camera_allowed(obj/machinery/camera/camera)
	return !QDELETED(camera) && z && camera.z && length(network & camera.network) && \
		(camera.z == z || (!is_away_level(z) && !is_away_level(camera.z))) && antag_training_camera_visible(camera, src)

/obj/machinery/computer/security/proc/netdm_camera_select(obj/machinery/camera/camera)
	if(netdm_camera_allowed(camera) && camera == netdm_camera_target?.resolve())
		return TRUE
	netdm_camera_clear()
	if(!netdm_camera_allowed(camera))
		netdm_camera_status = "denied"
		return FALSE
	netdm_camera_target = WEAKREF(camera)
	netdm_camera_status = "connecting"
	netdm_camera_deadline = world.time + NETDM_CAMERA_DEADLINE
	netdm_camera_pump()
	return TRUE

/obj/machinery/computer/security/proc/netdm_camera_clear()
	deltimer(netdm_camera_timer)
	netdm_camera_timer = null
	netdm_camera_target = null
	netdm_camera_instance = null
	netdm_camera_request = null
	netdm_camera_operation = null
	netdm_camera_stream = null
	netdm_camera_deadline = 0
	netdm_camera_lease = 0
	netdm_camera_next = 0
	netdm_camera_status = null
	netdm_camera_set_feed(null)

/obj/machinery/computer/security/proc/netdm_camera_set_feed(obj/machinery/camera/camera)
	if(active_camera == camera && camera)
		return
	active_camera = camera
	last_camera_turf = null
	if(cam_screen && cam_background)
		update_active_camera_screen()

/obj/machinery/computer/security/proc/netdm_camera_pump()
	deltimer(netdm_camera_timer)
	netdm_camera_timer = null
	var/obj/machinery/camera/camera = netdm_camera_target?.resolve()
	if(!netdm_camera_allowed(camera))
		netdm_camera_clear()
		netdm_camera_status = "denied"
		SStgui.update_uis(src)
		return
	netdm_camera_timer = addtimer(CALLBACK(src, PROC_REF(netdm_camera_pump)), 5, TIMER_STOPPABLE)
	if(active_camera && (world.time >= netdm_camera_lease || machine_stat & (NOPOWER|BROKEN|EMPED) || !camera.can_use() || camera.machine_stat & (NOPOWER|BROKEN|EMPED)))
		netdm_camera_set_feed(null)
		netdm_camera_status = "offline"
		SStgui.update_uis(src)
	if(netdm_camera_request && netdm_camera_stream != SSnetdm_observe.bridge?.stream_id)
		netdm_camera_request = null
		netdm_camera_operation = null
	if(netdm_camera_request && world.time < netdm_camera_deadline)
		return
	if(world.time >= netdm_camera_deadline && (netdm_camera_request || netdm_camera_status == "connecting"))
		netdm_camera_request = null
		netdm_camera_operation = null
		if(!active_camera)
			netdm_camera_status = "offline"
			SStgui.update_uis(src)
	if(world.time < netdm_camera_next || !SSnetdm_observe.published || machine_stat & (NOPOWER|BROKEN|EMPED))
		return
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/datum/component/netdm_node/console_node = GetComponent(/datum/component/netdm_node)
	var/datum/component/netdm_node/camera_node = camera.GetComponent(/datum/component/netdm_node)
	if(!console_node || !camera_node)
		return
	var/datum/netdm_service_endpoint/console_endpoint = lane.by_node[console_node]
	var/datum/netdm_service_endpoint/camera_endpoint = lane.by_node[camera_node]
	if(console_endpoint?.domain != NETDM_CAMERA_DOMAIN || camera_endpoint?.domain != NETDM_CAMERA_DOMAIN)
		if(netdm_camera_status != "denied")
			netdm_camera_status = "denied"
			SStgui.update_uis(src)
		netdm_camera_next = world.time + NETDM_CAMERA_RENEW
		return
	netdm_camera_instance = "camera.[camera_endpoint.id]"
	if(!lane.ready(camera_node, netdm_camera_instance))
		return
	var/request = "cam-[console_endpoint.id]-[++netdm_camera_serial]"
	if(lane.invoke(console_node, netdm_camera_instance, "acquire", request, list("request" = request), CALLBACK(src, PROC_REF(netdm_camera_accepted), request), 35))
		netdm_camera_request = request
		netdm_camera_stream = SSnetdm_observe.bridge.stream_id
		netdm_camera_deadline = world.time + NETDM_CAMERA_DEADLINE
		netdm_camera_next = world.time + NETDM_CAMERA_RENEW

/obj/machinery/computer/security/proc/netdm_camera_accepted(request, list/entry, list/reply)
	if(request != netdm_camera_request)
		return
	var/list/operation = reply?["result"]?["value"]
	if(reply?["ok"] && operation?["operationId"])
		netdm_camera_operation = "[operation["operationId"]]"
		return
	netdm_camera_request = null
	if(!active_camera)
		netdm_camera_status = "offline"
		SStgui.update_uis(src)

/obj/machinery/computer/security/proc/netdm_camera_answered(list/item)
	if(!netdm_camera_operation || netdm_camera_operation != "[item["operationId"]]" || item["instance"] != netdm_camera_instance || netdm_camera_stream != SSnetdm_observe.bridge?.stream_id)
		return
	var/list/payload = item["payload"]
	if(payload && payload["request"] != netdm_camera_request)
		return
	var/obj/machinery/camera/camera = netdm_camera_target?.resolve()
	var/state = payload?["state"]
	if(!netdm_camera_allowed(camera) || machine_stat & (NOPOWER|BROKEN|EMPED))
		state = "offline"
	netdm_camera_request = null
	netdm_camera_operation = null
	netdm_camera_status = state || "offline"
	if(state == "ready" && camera.can_use() && !(camera.machine_stat & (NOPOWER|BROKEN|EMPED)))
		netdm_camera_set_feed(camera)
		last_camera = WEAKREF(camera)
		netdm_camera_lease = world.time + NETDM_CAMERA_LEASE
	else
		netdm_camera_set_feed(null)
		netdm_camera_lease = 0
		if(state == "ready")
			netdm_camera_status = "offline"
	SStgui.update_uis(src)

/datum/netdm_command_handler/camera_acquire/execute(datum/target, list/item)
	var/obj/machinery/camera/camera = target
	if(!istype(camera))
		return "invalid_camera"
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	var/obj/machinery/computer/security/console = lane.registry.resolve(item["producer"], item["producerGeneration"])
	var/list/payload = item["payload"]
	var/state = "denied"
	if(istype(console) && console.netdm_camera_allowed(camera) && !(console.machine_stat & (NOPOWER|BROKEN|EMPED)))
		state = camera.can_use() && !(camera.machine_stat & (NOPOWER|BROKEN|EMPED)) ? "ready" : "offline"
	return list("result" = list("request" = payload["request"], "state" = state))

/datum/netdm_effect_handler/camera_acquired/apply(datum/target, list/item)
	var/obj/machinery/computer/security/console = target
	if(!istype(console))
		return "invalid_console"
	console.netdm_camera_answered(item)
	return TRUE

#undef NETDM_CAMERA_LEASE
#undef NETDM_CAMERA_RENEW
#undef NETDM_CAMERA_DEADLINE
#undef NETDM_CAMERA_DOMAIN
