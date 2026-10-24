/** A feed is acquired by a routed request/reply, then checked while it is viewed. */
/datum/netrun_machine_message/camera_request

/datum/netrun_machine_message/camera_feed

/datum/netrun_machine_service/camera
	service_id = "camera.stream"

/datum/netrun_machine_service/camera/tag()
	var/obj/machinery/camera/camera = host
	return camera.c_tag

/datum/netrun_machine_service/camera/matches(datum/netrun_machine_service/source_service, recipient_tag)
	if(!..() || !istype(source_service, /datum/netrun_machine_service/camera_viewer))
		return FALSE
	var/datum/netrun_machine_service/camera_viewer/viewer = source_service
	return viewer.allows_camera(host)

/datum/netrun_machine_service/camera/accepts(datum/netrun_machine_message/message)
	var/obj/machinery/camera/camera = host
	return istype(message, /datum/netrun_machine_message/camera_request) && matches(message.source, tag()) && camera.can_use()

/datum/netrun_machine_service/camera/receive(datum/netrun_machine_message/message)
	var/datum/netrun_machine_message/camera_feed/response = new(list("sequence" = message.payload["sequence"]))
	return message.reply(response)

/datum/netrun_machine_service/camera_viewer
	service_id = "camera.viewer"
	var/request_sequence = 0
	var/pending_tag
	var/datum/weakref/pending_user
	var/datum/netrun_machine_service/camera/active_feed

/datum/netrun_machine_service/camera_viewer/proc/allows_camera(obj/machinery/camera/camera)
	return FALSE

/datum/netrun_machine_service/camera_viewer/proc/request_feed(camera_tag, mob/user)
	request_sequence++
	pending_tag = camera_tag
	pending_user = user ? WEAKREF(user) : null
	active_feed = null
	clear_feed()
	var/datum/netrun_machine_message/camera_request/request = new(list("sequence" = request_sequence))
	return send("camera.stream", request, camera_tag)

/datum/netrun_machine_service/camera_viewer/proc/clear_feed()
	return

/datum/netrun_machine_service/camera_viewer/proc/show_feed(obj/machinery/camera/camera)
	return FALSE

/datum/netrun_machine_service/camera_viewer/proc/feed_available()
	if(QDELETED(active_feed) || !allows_camera(active_feed.host) || !can_reach(active_feed))
		return FALSE
	var/obj/machinery/camera/camera = active_feed.host
	return camera.can_use()

/datum/netrun_machine_service/camera_viewer/accepts(datum/netrun_machine_message/message)
	return istype(message, /datum/netrun_machine_message/camera_feed) && istype(message.source, /datum/netrun_machine_service/camera) && message.payload["sequence"] == request_sequence && pending_tag == message.source.tag() && allows_camera(message.source.host)

/datum/netrun_machine_service/camera_viewer/receive(datum/netrun_machine_message/message)
	active_feed = message.source
	return show_feed(message.source.host)

/datum/netrun_machine_service/camera_viewer/directory_ready(destination_id, recipient_tag)
	if(destination_id == "camera.stream")
		SStgui.update_static_data(host)
		SStgui.update_uis(host)
	return ..()

/datum/netrun_machine_service/camera_viewer/security

/datum/netrun_machine_service/camera_viewer/security/allows_camera(obj/machinery/camera/camera)
	var/obj/machinery/computer/security/console = host
	return !QDELETED(camera) && length(console.network & camera.network) && (camera.z == console.z || !(is_away_level(console.z) || is_away_level(camera.z)))

/datum/netrun_machine_service/camera_viewer/security/clear_feed()
	var/obj/machinery/computer/security/console = host
	console.active_camera = null
	console.last_camera_turf = null
	console.show_camera_static()

/datum/netrun_machine_service/camera_viewer/security/show_feed(obj/machinery/camera/camera)
	var/obj/machinery/computer/security/console = host
	console.active_camera = camera
	console.last_camera_turf = null
	console.update_active_camera_screen()
	SStgui.update_uis(console)
	return TRUE

/datum/netrun_machine_service/camera_viewer/advanced

/datum/netrun_machine_service/camera_viewer/advanced/allows_camera(obj/machinery/camera/camera)
	var/obj/machinery/computer/camera_advanced/console = host
	return !QDELETED(camera) && length(console.networks & camera.network) && (!length(console.z_lock) || (camera.z in console.z_lock))

/datum/netrun_machine_service/camera_viewer/advanced/show_feed(obj/machinery/camera/camera)
	var/obj/machinery/computer/camera_advanced/console = host
	var/mob/living/user = pending_user?.resolve()
	if(!user || !console.can_interact(user) || !console.can_use(user) || (console.current_user && console.current_user != user))
		return FALSE
	if(!console.eyeobj)
		console.CreateEye()
	console.eyeobj.eye_initialized = TRUE
	console.give_eye_control(user)
	console.eyeobj.setLoc(get_turf(camera))
	playsound(console, 'sound/machines/terminal_prompt_confirm.ogg', 25, FALSE)
	return TRUE

/obj/machinery/camera/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/camera)

/obj/machinery/computer/security/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/camera_viewer/security)

/obj/machinery/computer/camera_advanced/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/camera_viewer/advanced)

/obj/machinery/computer/security/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list("reboot"), 2, list(ACCESS_SECURITY))

/obj/machinery/computer/camera_advanced/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list("reboot"), 2, list(ACCESS_SECURITY))

/// Discovery is service-scoped; native cameranet remains only a spatial render cache.
/obj/machinery/proc/netrun_available_cameras()
	var/list/cameras = list()
	var/datum/netrun_machine_service/camera_viewer/service = get_netrun_machine_service("camera.viewer")
	if(!service)
		return cameras
	for(var/datum/netrun_machine_service/camera/endpoint as anything in service.resolve("camera.stream"))
		if(!service.allows_camera(endpoint.host) || !service.can_reach(endpoint))
			continue
		var/obj/machinery/camera/camera = endpoint.host
		if(camera.c_tag)
			cameras[camera.c_tag] = camera
	return cameras

/obj/machinery/computer/camera_advanced/proc/netrun_connect_camera(mob/living/user)
	if(current_user && current_user != user)
		to_chat(user, span_warning("The console is already in use!"))
		return
	if(!can_use(user))
		return
	if(!eyeobj)
		CreateEye()
	// Consoles with a local free-view eye intentionally have no camera feed.
	if(eyeobj.use_static == USE_STATIC_NONE)
		eyeobj.eye_initialized = TRUE
		give_eye_control(user)
		eyeobj.setLoc(get_turf(src))
		return
	var/list/cameras = netrun_available_cameras()
	for(var/camera_tag in cameras)
		var/obj/machinery/camera/camera = cameras[camera_tag]
		if(!camera.can_use())
			continue
		var/datum/netrun_machine_service/camera_viewer/service = get_netrun_machine_service("camera.viewer")
		service.request_feed(camera_tag, user)
		return
	to_chat(user, span_notice("Поиск доступных сетевых камер..."))
	var/datum/netrun_machine_service/camera_viewer/service = get_netrun_machine_service("camera.viewer")
	service.pending_user = WEAKREF(user)

/datum/netrun_machine_service/camera_viewer/advanced/directory_ready(destination_id, recipient_tag)
	. = ..()
	var/obj/machinery/computer/camera_advanced/console = host
	var/mob/living/user = pending_user?.resolve()
	if(destination_id == "camera.stream" && !recipient_tag && user && !console.current_user && console.can_interact(user))
		INVOKE_ASYNC(console, TYPE_PROC_REF(/obj/machinery/computer/camera_advanced, netrun_connect_camera), user)

/mob/camera/aiEye/remote
	/// Extra denial masks keep the global camera chunk cache from leaking other networks.
	var/list/netrun_camera_masks = list()
	var/client/netrun_mask_client

/mob/camera/aiEye/remote/proc/clear_netrun_camera_masks()
	if(netrun_mask_client)
		netrun_mask_client.images -= netrun_camera_masks
	netrun_mask_client = null
	netrun_camera_masks.Cut()

/mob/camera/aiEye/remote/proc/update_netrun_camera_masks()
	clear_netrun_camera_masks()
	var/obj/machinery/computer/camera_advanced/console = origin
	var/client/viewer = GetViewerClient()
	if(!istype(console) || !viewer || use_static == USE_STATIC_NONE || !loc)
		return
	var/list/visible = list()
	var/list/cameras = console.netrun_available_cameras()
	for(var/camera_tag in cameras)
		var/obj/machinery/camera/camera = cameras[camera_tag]
		if(!camera.can_use() || camera.z != z || get_dist(camera, src) > static_visibility_range + camera.view_range)
			continue
		for(var/turf/visible_turf as anything in camera.get_visible_turfs())
			visible[visible_turf] = TRUE
	for(var/turf/hidden_turf in range(static_visibility_range, src))
		if(!visible[hidden_turf])
			netrun_camera_masks += GLOB.cameranet.make_static_image(hidden_turf, use_static)
	netrun_mask_client = viewer
	viewer.images += netrun_camera_masks
