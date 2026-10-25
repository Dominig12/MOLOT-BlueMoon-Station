/// One packet is one budgeted task. A yielding native callback does not hold the worker.
/datum/netrun_task/request_delivery
	kind = "request_delivery"

/datum/netrun_task/request_delivery/execute(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/netrun_request/delivery/packet = target()
	if(QDELETED(packet))
		return FALSE
	packet.deliver()
	return TRUE

/datum/netrun_task/machine_delivery
	kind = "machine_delivery"

/datum/netrun_task/machine_delivery/execute(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/netrun_machine_packet/packet = target()
	if(QDELETED(packet))
		return FALSE
	packet.deliver()
	return TRUE
