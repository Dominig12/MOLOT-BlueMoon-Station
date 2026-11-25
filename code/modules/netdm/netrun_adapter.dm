/**
 * NETRUN device adapter.
 *
 * The world already knows which devices speak on the network: every service a device offers goes through
 * `netdm_service_lane.offer()`. This adapter turns each accepted service into a digital host of NETRUN, so a
 * door, a sensor, a research server or a terminal becomes something a runner can see, inspect and use.
 *
 * It is a translation layer and nothing else: it declares hosts, hands out the rights that come from owning
 * a device, and forwards an action. Every decision still happens in the Host, where the action pipeline
 * checks rights, cost and cooldown (ARCH-001).
 */
/datum/netrun_adapter
	/// "instance" -> host id declared for it in this round.
	var/list/hosts = list()
	/// "instance" -> TRUE when the declaration was acknowledged by the Host.
	var/list/confirmed = list()
	/// Declarations sent but not yet answered, bounded: a busy round must not queue forever.
	var/pending = 0
	/// Upper bound of declarations per round, matching the Host's endpoint budget.
	var/max_hosts = 4096
	/// Rights handed to an operator on its own device; the rest is won or granted by the game.
	var/own_rights = list("execution", "discovery", "read")
	/// netDM node datum -> first service instance it publishes. Lets a device find its own host.
	var/list/devices = list()

/// A service became reachable on the network: it is now a host of the digital world.
/datum/netrun_adapter/proc/service_registered(datum/netdm_service_lane/lane, datum/netdm_service_endpoint/endpoint, instance)
	if(!istext(instance) || !length(instance))
		return
	if(hosts[instance] || pending >= 64 || length(hosts) >= max_hosts)
		return
	var/list/service = endpoint?.services[instance]
	if(!islist(service))
		return
	var/service_type = service["type"]
	if(endpoint?.node && !devices[endpoint.node])
		devices[endpoint.node] = instance
	var/name = netrun_host_name(instance)
	pending++
	hosts[instance] = 0
	var/sent = lane.control("netrun_host", list(
		"name" = name,
		"class" = netrun_host_class(service_type),
		"capacityCu" = 2,
		"rateCu" = 1,
		"memorySlots" = 1,
		"services" = list(service_type = instance),
	), CALLBACK(src, PROC_REF(on_host_declared), instance))
	if(!sent)
		pending--
		hosts -= instance

/datum/netrun_adapter/proc/on_host_declared(instance, list/reply)
	pending = max(0, pending - 1)
	if(!islist(reply) || !reply["ok"])
		// A refused or lost declaration may be tried again when the service is re-registered.
		hosts -= instance
		return
	var/list/result = reply["result"]
	if(!islist(result))
		return
	var/id = text2num(result["host"])
	var/generation = text2num(result["generation"])
	if(!id || !generation)
		return
	hosts[instance] = id
	confirmed[instance] = generation

/// The netDM node a device is on, if this adapter has seen it publish a service.
/datum/netrun_adapter/proc/node_for_device(atom/thing)
	for(var/datum/node as anything in devices)
		if(!istype(node, /datum/component))
			continue
		var/datum/component/component = node
		if(component.parent == thing)
			return node
	return null

/// The service instance a node publishes first, used as the device identity of the window.
/datum/netrun_adapter/proc/instance_for_node(datum/node)
	return devices[node]

/// The host declared for one service instance, or null when it is unknown yet.
/datum/netrun_adapter/proc/host_of(instance)
	var/id = hosts[instance]
	return id ? list("id" = id, "generation" = confirmed[instance]) : null

/**
 * Hands an operator the rights that come from the device in its hands: use it, find what is around it and
 * read its own state. Nothing here grants control over somebody else's device.
 */
/datum/netrun_adapter/proc/grant_operator(datum/netdm_service_lane/lane, principal, instance)
	var/host = host_of(instance)
	if(!host)
		return FALSE
	var/granted = FALSE
	for(var/category as anything in own_rights)
		if(lane.control("netrun_grant", list(
			"subject" = principal,
			"host" = host["id"],
			"category" = category,
			"lifetimeMs" = 600000,
		), null))
			granted = TRUE
	return granted

/// Name of the digital host of one service instance: stable for the round and inside the Host's alphabet.
/proc/netrun_host_name(instance)
	var/name = copytext(instance, 1, 60)
	return "svc.[replacetext(name, " ", "_")]"

/// Host class of a service type. Content can override it; the defaults only pick a sensible shape.
/proc/netrun_host_class(service_type)
	var/type = "[service_type]"
	if(copytext(type, 1, 9) == "research")
		return "Server"
	if(copytext(type, 1, 6) == "camera")
		return "Terminal"
	if(copytext(type, 1, 7) == "atmos.")
		return "Terminal"
	if(copytext(type, 1, 7) == "machine")
		return "Terminal"
	if(copytext(type, 1, 7) == "pda.mes")
		return "Terminal"
	return "Terminal"
