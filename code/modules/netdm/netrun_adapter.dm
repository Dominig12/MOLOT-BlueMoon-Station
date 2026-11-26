/**
 * NETRUN device adapter.
 *
 * The world already knows which devices speak on the network: every service a device offers goes through
 * `netdm_service_lane.offer()`. This adapter turns each accepted service into a digital host of NETRUN, so a
 * door, a sensor, a research server or a terminal becomes something a runner can see, inspect and use.
 *
 * Declarations are queued, not fired at registration time: a device registers its services while the world
 * is still being exported, and the control channel only exists once a session is published. One refused
 * request must never block the queue other features share, so a declaration is retried from `tick()` with a
 * bounded attempt count.
 *
 * It is a translation layer and nothing else: it declares hosts, hands out the rights that come from owning
 * a device, and forwards an action. Every decision still happens in the Host, where the action pipeline
 * checks rights, cost and cooldown (ARCH-001).
 */
#define NETRUN_DECLARE_BATCH 8
#define NETRUN_DECLARE_BACKOFF (2 SECONDS)
#define NETRUN_DECLARE_ATTEMPTS 5

/datum/netrun_adapter
	/// "instance" -> host id declared for it in this round; 0 while a declaration is in flight.
	var/list/hosts = list()
	/// "instance" -> TRUE when the declaration was acknowledged by the Host.
	var/list/confirmed = list()
	/// "instance" -> list("type" = service type, "tries" = attempts). Waiting to be declared.
	var/list/wanted = list()
	/// Declarations sent but not yet answered, bounded: a busy round must not queue forever.
	var/pending = 0
	/// When the next attempt may run; a failed attempt backs off instead of spinning.
	var/next_try = 0
	/// Upper bound of declarations per round, matching the Host's endpoint budget.
	var/max_hosts = 4096
	/// netDM node datum -> first service instance it publishes. Lets a device find its own host.
	var/list/devices = list()
	/// Rights handed to an operator on its own device; the rest is won or granted by the game. Holding the
	/// device is the credential (SEC-001, physical): it lets the operator run programs here, look around and
	/// command this host, which is what the §8.2 abilities on your own core need.
	var/own_rights = list("execution", "discovery", "read", "control")

/// A service became reachable on the network: it becomes a host of the digital world once a session exists.
/datum/netrun_adapter/proc/service_registered(datum/netdm_service_lane/lane, datum/netdm_service_endpoint/endpoint, instance)
	if(!istext(instance) || !length(instance))
		return
	if(hosts[instance] || wanted[instance] || length(hosts) + length(wanted) >= max_hosts)
		return
	var/list/service = endpoint?.services[instance]
	if(!islist(service) || !istext(service["type"]))
		return
	var/node = lane?.node_id(endpoint.node)
	if(endpoint.node && !devices[endpoint.node])
		devices[endpoint.node] = instance
	// The network position travels with the declaration, so the Host can measure reach and plan travel.
	wanted[instance] = list("type" = service["type"], "tries" = 0, "node" = node)
	declare()

/**
 * Sends pending declarations. Does nothing before the world is published, which is the whole reason the
 * queue exists: a request sent too early is refused by the bridge and would block every later control
 * message behind it.
 */
/datum/netrun_adapter/proc/declare()
	if(!length(wanted) || pending >= NETRUN_DECLARE_BATCH || world.time < next_try)
		return 0
	var/datum/controller/subsystem/netdm_observe/network = SSnetdm_observe
	if(!network?.published)
		return 0
	var/datum/netdm_service_lane/lane = network.services
	if(!lane)
		return 0
	var/sent = 0
	for(var/instance as anything in wanted.Copy())
		if(sent >= NETRUN_DECLARE_BATCH || pending >= NETRUN_DECLARE_BATCH)
			break
		if(hosts[instance])
			wanted -= instance
			continue
		var/list/entry = wanted[instance]
		if(!islist(entry))
			wanted -= instance
			continue
		entry["tries"]++
		pending++
		hosts[instance] = 0
		var/list/payload = list(
			"name" = netrun_host_name(instance),
			"class" = netrun_host_class(entry["type"]),
			"capacityCu" = 2,
			"rateCu" = 1,
			"memorySlots" = 1,
			"services" = list(entry["type"] = instance),
		)
		// Posture travels with the declaration: a device that publishes research data is a closed host with an
		// IDS, everything else is an ordinary device. The Host still decides what any of that means (§9.3).
		var/list/posture = netrun_host_security(entry["type"])
		payload["security"] = posture["profile"]
		payload["ids"] = posture["ids"]
		payload["maxPresences"] = posture["maxPresences"]
		if(!isnull(entry["node"]))
			payload["node"] = entry["node"]
		var/accepted = lane.control("netrun_host", payload, CALLBACK(src, PROC_REF(on_host_declared), instance))
		if(!accepted)
			// The channel did not take it at all: keep the queue moving and try again later.
			pending--
			hosts -= instance
			entry["tries"]--
			break
		sent++
	if(!sent)
		next_try = world.time + NETRUN_DECLARE_BACKOFF
	return sent

/// Called from the subsystem fire: retries whatever is still waiting for a session or a lost answer.
/datum/netrun_adapter/proc/tick()
	declare()

/datum/netrun_adapter/proc/on_host_declared(instance, list/reply)
	pending = max(0, pending - 1)
	if(!islist(reply) || !reply["ok"])
		hosts -= instance
		var/list/entry = wanted[instance]
		if(!islist(entry) || entry["tries"] >= NETRUN_DECLARE_ATTEMPTS)
			wanted -= instance
		else
			next_try = world.time + NETRUN_DECLARE_BACKOFF
		return
	var/list/result = reply["result"]
	if(!islist(result))
		hosts -= instance
		return
	var/id = text2num(result["host"])
	var/generation = text2num(result["generation"])
	if(!id || !generation)
		hosts -= instance
		return
	hosts[instance] = id
	confirmed[instance] = generation
	wanted -= instance

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

/// The host declared for one service instance, or null when it is unknown or still pending.
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
	return "Terminal"

/**
 * Access posture of a device, declared with its host. Research equipment is a closed host that watches its own
 * traffic; ordinary devices are standard and hold one presence. This is a starting point for content, not a
 * balance decision: the numbers live here so a device can change them without touching the Host (§9.3).
 */
/proc/netrun_host_security(service_type)
	var/type = "[service_type]"
	if(copytext(type, 1, 9) == "research")
		return list("profile" = "secure", "ids" = TRUE, "maxPresences" = 2)
	return list("profile" = "standard", "ids" = FALSE, "maxPresences" = 1)

#undef NETRUN_DECLARE_BATCH
#undef NETRUN_DECLARE_BACKOFF
#undef NETRUN_DECLARE_ATTEMPTS
