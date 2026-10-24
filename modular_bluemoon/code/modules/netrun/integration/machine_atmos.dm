/** Native atmosphere automation speaks through the same routed network as runners. */
/datum/netrun_machine_message/atmos

/// Actor provenance is separate from the copied wire payload.
/atom/proc/netrun_atmos_send(source_id, destination_id, list/data, mob/user, recipient_tag)
	var/datum/netrun_machine_service/service = get_netrun_machine_service(source_id)
	if(!service)
		return FALSE
	var/list/wire_data = deepCopyList(data)
	wire_data -= "user"
	var/datum/netrun_machine_message/atmos/message = new(wire_data)
	if(user)
		message.user_ref = WEAKREF(user)
	return service.send(destination_id, message, recipient_tag)

/datum/netrun_machine_service/atmos

/datum/netrun_machine_service/atmos/proc/control_frequency()
	return null

/datum/netrun_machine_service/atmos/proc/same_channel(datum/netrun_machine_service/atmos/other)
	return istype(other) && control_frequency() && control_frequency() == other.control_frequency()

/datum/netrun_machine_service/atmos/controller
	service_id = "atmos.controller"

/datum/netrun_machine_service/atmos/controller/control_frequency()
	var/obj/machinery/airalarm/alarm = host
	return alarm.frequency

/datum/netrun_machine_service/atmos/controller/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return ..() && istype(source_service, /datum/netrun_machine_service/atmos/device) && same_channel(source_service) && get_base_area(host) == get_base_area(source_service.host)

/datum/netrun_machine_service/atmos/controller/accepts(datum/netrun_machine_message/message)
	return istype(message, /datum/netrun_machine_message/atmos) && message.payload["sigtype"] == "status" && message.payload["tag"] == message.source.tag() && matches(message.source, null)

/datum/netrun_machine_service/atmos/controller/receive(datum/netrun_machine_message/message)
	var/obj/machinery/airalarm/alarm = host
	var/tag = message.payload["tag"]
	if(message.payload["device"] == "VP")
		alarm.netrun_vent_info[tag] = deepCopyList(message.payload)
	else if(message.payload["device"] == "VS")
		alarm.netrun_scrub_info[tag] = deepCopyList(message.payload)
	else
		return FALSE
	SStgui.update_uis(alarm)
	return TRUE

/datum/netrun_machine_service/atmos/controller/directory_ready(destination_id, recipient_tag)
	if(destination_id == "atmos.device" && recipient_tag)
		var/obj/machinery/airalarm/alarm = host
		alarm.send_signal(recipient_tag, list("status"))
	return ..()

/datum/netrun_machine_service/atmos/alarm_source
	service_id = "atmos.alarm"

/datum/netrun_machine_service/atmos/alarm_source/control_frequency()
	var/obj/machinery/airalarm/alarm = host
	return alarm.alarm_frequency

/datum/netrun_machine_service/atmos/device
	service_id = "atmos.device"

/datum/netrun_machine_service/atmos/device/matches(datum/netrun_machine_service/source_service, recipient_tag)
	if(!..() || !same_channel(source_service))
		return FALSE
	if(istype(source_service, /datum/netrun_machine_service/atmos/controller))
		return get_base_area(host) == get_base_area(source_service.host)
	if(istype(source_service, /datum/netrun_machine_service/atmos/monitor))
		var/obj/machinery/computer/atmos_control/tank/controller = source_service.host
		return istype(controller) && (tag() == controller.input_tag || tag() == controller.output_tag || isnull(recipient_tag))
	return FALSE

/datum/netrun_machine_service/atmos/device/accepts(datum/netrun_machine_message/message)
	return istype(message, /datum/netrun_machine_message/atmos) && message.payload["sigtype"] == "command" && message.payload["tag"] == tag() && matches(message.source, tag())

/datum/netrun_machine_service/atmos/device/receive(datum/netrun_machine_message/message)
	var/list/data = deepCopyList(message.payload)
	data["user"] = message.user_ref?.resolve()
	var/datum/signal/signal = new(data)
	var/obj/machinery/machine = host
	machine.receive_signal(signal)
	qdel(signal)
	return TRUE

/datum/netrun_machine_service/atmos/device/vent

/datum/netrun_machine_service/atmos/device/vent/tag()
	var/obj/machinery/atmospherics/components/unary/vent_pump/device = host
	return device.id_tag

/datum/netrun_machine_service/atmos/device/vent/control_frequency()
	var/obj/machinery/atmospherics/components/unary/vent_pump/device = host
	return device.frequency

/datum/netrun_machine_service/atmos/device/scrubber

/datum/netrun_machine_service/atmos/device/scrubber/tag()
	var/obj/machinery/atmospherics/components/unary/vent_scrubber/device = host
	return device.id_tag

/datum/netrun_machine_service/atmos/device/scrubber/control_frequency()
	var/obj/machinery/atmospherics/components/unary/vent_scrubber/device = host
	return device.frequency

/datum/netrun_machine_service/atmos/device/injector

/datum/netrun_machine_service/atmos/device/injector/tag()
	var/obj/machinery/atmospherics/components/unary/outlet_injector/device = host
	return device.id

/datum/netrun_machine_service/atmos/device/injector/control_frequency()
	var/obj/machinery/atmospherics/components/unary/outlet_injector/device = host
	return device.frequency

/datum/netrun_machine_service/atmos/device/pump

/datum/netrun_machine_service/atmos/device/pump/tag()
	var/obj/machinery/atmospherics/components/binary/pump/device = host
	return device.id

/datum/netrun_machine_service/atmos/device/pump/control_frequency()
	var/obj/machinery/atmospherics/components/binary/pump/device = host
	return device.frequency

/datum/netrun_machine_service/atmos/device/volume_pump

/datum/netrun_machine_service/atmos/device/volume_pump/tag()
	var/obj/machinery/atmospherics/components/binary/volume_pump/device = host
	return device.id

/datum/netrun_machine_service/atmos/device/volume_pump/control_frequency()
	var/obj/machinery/atmospherics/components/binary/volume_pump/device = host
	return device.frequency

/datum/netrun_machine_service/atmos/sensor
	service_id = "atmos.sensor"

/datum/netrun_machine_service/atmos/sensor/tag()
	var/obj/machinery/air_sensor/sensor = host
	return sensor.id_tag

/datum/netrun_machine_service/atmos/sensor/control_frequency()
	var/obj/machinery/air_sensor/sensor = host
	return sensor.frequency

/datum/netrun_machine_service/atmos/sensor/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return ..() && istype(source_service, /datum/netrun_machine_service/atmos/monitor) && same_channel(source_service)

/datum/netrun_machine_service/atmos/monitor
	service_id = "atmos.monitor"
	var/datum/weakref/reconnect_user

/datum/netrun_machine_service/atmos/monitor/control_frequency()
	var/obj/machinery/computer/atmos_control/monitor = host
	return monitor.frequency

/datum/netrun_machine_service/atmos/monitor/matches(datum/netrun_machine_service/source_service, recipient_tag)
	if(!..() || !same_channel(source_service))
		return FALSE
	var/obj/machinery/computer/atmos_control/monitor = host
	if(istype(source_service, /datum/netrun_machine_service/atmos/sensor))
		return source_service.tag() in monitor.sensors
	if(istype(source_service, /datum/netrun_machine_service/atmos/device))
		var/obj/machinery/computer/atmos_control/tank/tank = host
		return istype(tank) && (source_service.tag() == tank.input_tag || source_service.tag() == tank.output_tag)
	return FALSE

/datum/netrun_machine_service/atmos/monitor/accepts(datum/netrun_machine_message/message)
	if(!istype(message, /datum/netrun_machine_message/atmos) || message.payload["sigtype"] != "status" || !matches(message.source, null))
		return FALSE
	return (message.payload["tag"] || message.payload["id_tag"]) == message.source.tag()

/datum/netrun_machine_service/atmos/monitor/receive(datum/netrun_machine_message/message)
	var/datum/signal/signal = new(deepCopyList(message.payload))
	var/obj/machinery/machine = host
	machine.receive_signal(signal)
	qdel(signal)
	SStgui.update_uis(host)
	return TRUE

/datum/netrun_machine_service/atmos/monitor/directory_ready(destination_id, recipient_tag)
	if(destination_id == "atmos.device")
		var/obj/machinery/computer/atmos_control/tank/tank = host
		if(istype(tank))
			if(recipient_tag)
				tank.netrun_poll_device(recipient_tag)
			else if(reconnect_user)
				var/mob/user = reconnect_user.resolve()
				reconnect_user = null
				if(user && tank.can_interact(user))
					INVOKE_ASYNC(tank, TYPE_PROC_REF(/obj/machinery/computer/atmos_control/tank, reconnect), user)
	return ..()

/datum/netrun_machine_service/atmos/alert
	service_id = "atmos.alert"

/datum/netrun_machine_service/atmos/alert/control_frequency()
	var/obj/machinery/computer/atmos_alert/console = host
	return console.receive_frequency

/datum/netrun_machine_service/atmos/alert/matches(datum/netrun_machine_service/source_service, recipient_tag)
	return ..() && istype(source_service, /datum/netrun_machine_service/atmos/alarm_source) && same_channel(source_service)

/datum/netrun_machine_service/atmos/alert/accepts(datum/netrun_machine_message/message)
	return istype(message, /datum/netrun_machine_message/atmos) && matches(message.source, null)

/datum/netrun_machine_service/atmos/alert/receive(datum/netrun_machine_message/message)
	var/datum/signal/signal = new(deepCopyList(message.payload))
	var/obj/machinery/machine = host
	machine.receive_signal(signal)
	qdel(signal)
	SStgui.update_uis(host)
	return TRUE

/obj/machinery/airalarm
	/// Each controller knows only the telemetry actually delivered to its port.
	var/list/netrun_vent_info = list()
	var/list/netrun_scrub_info = list()

/obj/machinery/airalarm/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/controller, /datum/netrun_machine_service/atmos/alarm_source)

/obj/machinery/atmospherics/components/unary/vent_pump/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/device/vent)

/obj/machinery/atmospherics/components/unary/vent_scrubber/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/device/scrubber)

/obj/machinery/atmospherics/components/unary/outlet_injector/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/device/injector)

/obj/machinery/atmospherics/components/binary/pump/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/device/pump)

/obj/machinery/atmospherics/components/binary/volume_pump/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/device/volume_pump)

/obj/machinery/air_sensor/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/sensor)

/obj/machinery/computer/atmos_control/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/monitor)

/obj/machinery/computer/atmos_alert/netrun_machine_service_types()
	return list(/datum/netrun_machine_service/atmos/alert)

/obj/machinery/atmospherics/components/unary/vent_pump/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS, list("reboot"), 1, list(ACCESS_ATMOSPHERICS))

/obj/machinery/atmospherics/components/unary/vent_scrubber/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS, list("reboot"), 1, list(ACCESS_ATMOSPHERICS))

/obj/machinery/atmospherics/components/unary/outlet_injector/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS, list("reboot"), 2, list(ACCESS_ATMOSPHERICS))

/obj/machinery/air_sensor/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS, list("reboot"), 1, list(ACCESS_ATMOSPHERICS))

/obj/machinery/computer/atmos_control/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS, list("reboot"), 2, list(ACCESS_ATMOSPHERICS))

/obj/machinery/computer/atmos_alert/Initialize(mapload)
	. = ..()
	AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS, list("reboot"), 2, list(ACCESS_ATMOSPHERICS))

/obj/machinery/computer/atmos_control/tank/proc/netrun_poll_device(device_tag)
	if(device_tag)
		return netrun_atmos_send("atmos.monitor", "atmos.device", list("sigtype" = "command", "tag" = device_tag, "status" = TRUE), null, device_tag)
	return FALSE
