/**
 * NETRUN client: the digital life path.
 *
 * The window is not a viewer: it creates a core, asks for a copy and enters the world, and every answer it shows
 * is what the Host decided. This test runs the client's own procs against a live Host, so a broken request
 * builder or a swallowed reply fails here instead of in someone's round.
 */
/datum/unit_test/netdm_observe/netrun_client_life

/datum/unit_test/netdm_observe/netrun_client_life/Run()
	if(world.GetConfig("env", "NETDM_IPC_MODE") != "v1")
		return
	TEST_ASSERT(wait_until_live(), "Observe must publish the initial map ([SSnetdm_observe.observe_state()]).")
	var/datum/netdm_service_lane/lane = SSnetdm_observe.services
	TEST_ASSERT(lane, "The service lane must exist.")
	var/datum/netrun_adapter/adapter = SSnetdm_observe.netrun
	TEST_ASSERT(adapter, "The NETRUN adapter must exist.")

	// The window belongs to an operator with rights on its own device.
	var/deadline = world.time + 60 SECONDS
	var/datum/device_node = null
	var/instance = null
	var/host_id = 0
	while(world.time < deadline && !host_id)
		for(var/datum/node as anything in adapter.devices)
			var/candidate = adapter.devices[node]
			var/host = adapter.host_of(candidate)
			if(!host)
				continue
			device_node = node
			instance = candidate
			host_id = text2num(host["id"])
			break
		if(!host_id)
			sleep(5)
	TEST_ASSERT(host_id, "At least one device must be declared as a digital host.")

	var/mob/operator = allocate(/mob)
	var/datum/netrun_client/window = new(operator)
	window.bind_device(lane, device_node, instance)
	TEST_ASSERT(adapter.grant_operator(lane, window.principal, instance),
		"The operator is granted the rights of its device.")

	// Every step waits for the Host's answer and checks that the answer is one the window can show.
	var/list/expected = list("Ядро", "Отказ", "Не хватает", "Сеть отказала", "не найдено")

	window.notice = null
	TEST_ASSERT(window.life(list("action" = "create", "target" = host_id)), "The window asks for a core.")
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && window.notice == null)
		sleep(5)
	log_world("netDM netrun life create: [window.notice]")
	TEST_ASSERT(window.notice, "The Host answers the core request.")
	var/answered = FALSE
	for(var/word as anything in expected)
		if(findtext(window.notice, word))
			answered = TRUE
			break
	TEST_ASSERT(answered, "The answer is a decision, not silence: [window.notice]")

	// The projection carries the observer's cores after the request; a window that cannot read them is blind.
	window.next_poll = 0
	window.request_panel()
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !islist(window.panel))
		sleep(5)
	TEST_ASSERT(islist(window.panel), "The Host answers with a projection: [window.error]")
	TEST_ASSERT(islist(window.panel["lives"]), "The projection carries the observer's cores.")

	// A copy needs storage. The window must report the refusal instead of pretending the copy exists.
	window.notice = null
	window.life(list("action" = "backup", "target" = host_id))
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && window.notice == null)
		sleep(5)
	TEST_ASSERT(window.notice, "A core copy answers, even when it cannot be made: [window.notice]")

	// Entering where the core lives is the first travel step; a refusal must name the reason.
	window.notice = null
	window.travel(list("mode" = "enter", "target" = host_id))
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && window.notice == null)
		sleep(5)
	log_world("netDM netrun enter: [window.notice]")
	TEST_ASSERT(window.notice, "Entering answers with a state or a reason: [window.notice]")

	// The move needs a fresh projection: the presence appeared after the last read.
	window.next_poll = 0
	window.request_panel()
	deadline = world.time + 30 SECONDS
	while(world.time < deadline && !islist(window.panel?["presence"]))
		sleep(5)
	var/other_host = 0
	for(var/datum/node as anything in adapter.devices)
		var/host = adapter.host_of(adapter.devices[node])
		if(!host)
			continue
		var/id = text2num(host["id"])
		if(id && id != host_id)
			other_host = id
			break
	if(other_host)
		window.notice = null
		window.travel(list("mode" = "move", "target" = other_host))
		deadline = world.time + 30 SECONDS
		while(world.time < deadline && window.notice == null)
			sleep(5)
		log_world("netDM netrun move: [window.notice]")
		TEST_ASSERT(window.notice, "A move answers with a route or a reason: [window.notice]")

	qdel(window)
	qdel(operator)
