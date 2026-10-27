/obj/item/netrun_memory_test_host/netrun_breach_minigame()
	return "memory"

/obj/item/netrun_routing_test_host/netrun_breach_minigame()
	return "routing"

/obj/item/netrun_memory_test_host/critical/netrun_breach_access_cap(initial_level)
	return initial_level < NETRUN_ACCESS_USER ? NETRUN_ACCESS_USER : NETRUN_ACCESS_ROOT

/// Both overrides and ordinary selection stay stable across repeated attempts.
/datum/unit_test/netrun_breach_protocol_selection/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/target = allocate(/obj/item)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 2, list(ACCESS_RD))
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	var/datum/netrun_breach/first = allocate(/datum/netrun_breach, console, "node", node.address, "machine", 2)
	for(var/i in 1 to 8)
		var/datum/netrun_breach/retry = allocate(/datum/netrun_breach, console, "node", node.address, "machine", 2)
		TEST_ASSERT_EQUAL(retry.minigame, first.minigame, "Retrying the same device must not reroll its protocol kind")
	var/datum/netrun_breach/gateway = allocate(/datum/netrun_breach, console, "network", node.network.id, "LAN", 3)
	var/datum/netrun_breach/firmware = allocate(/datum/netrun_breach, console, "firmware", node.address, "firmware", 5)
	TEST_ASSERT_EQUAL(gateway.minigame, "matrix", "LAN gateways must retain the matrix protocol")
	TEST_ASSERT_EQUAL(firmware.minigame, "matrix", "Firmware attacks must retain the matrix protocol")

/// The server rejects reveal clicks, then removes every answer-bearing field during recall.
/datum/unit_test/netrun_breach_memory_visibility/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/netrun_memory_test_host/target = allocate(/obj/item/netrun_memory_test_host)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 2, list(ACCESS_RD))
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	TEST_ASSERT(console.start_breach("node", node.address), "The real protected host must start its memory breach")
	var/datum/netrun_breach/job = console.intrusion.breach
	TEST_ASSERT_EQUAL(job.minigame, "memory", "A memory override must select the memory implementation")
	TEST_ASSERT_EQUAL(job.size, 5, "Memory must use a readable five-by-five grid")
	TEST_ASSERT(length(job.order) >= 5 && length(job.order) <= 8, "Memory length must stay within the intended short recall challenge")
	var/list/reveal = job.ui_payload()
	TEST_ASSERT_EQUAL(reveal["phase"], "reveal", "The player must see the preparation phase before recall")
	for(var/list/entry as anything in reveal["cells"])
		TEST_ASSERT(!entry["active"], "No memory cell may be clickable during the server's reveal window")
	TEST_ASSERT(!job.choose(job.order[1]), "Forging a reveal-phase click must not advance the answer")
	TEST_ASSERT_EQUAL(job.progress, 0, "Reveal-phase input must leave memory progress untouched")
	job.reveal_until = world.time
	var/list/recall = job.ui_payload()
	TEST_ASSERT_EQUAL(recall["phase"], "recall", "Expired reveal must switch the payload to recall")
	TEST_ASSERT(!("order" in recall) && !("buffer" in recall), "Recall must not publish the stored answer in a top-level field")
	for(var/list/entry as anything in recall["cells"])
		TEST_ASSERT(!("order" in entry), "Recall cell payloads must completely omit hidden sequence positions")
		TEST_ASSERT(entry["active"], "Every unchosen cell must be selectable, rather than highlighting the next answer")
	for(var/list/goal as anything in recall["daemons"])
		TEST_ASSERT_EQUAL(length(goal["sequence"]), 0, "Memory rewards must not leak the hidden sequence through daemon metadata")
	TEST_ASSERT(!job.choose(1.5) && !job.choose("1") && !job.choose(0), "Malformed memory indices must be rejected by the server")
	TEST_ASSERT(job.choose(job.order[1]), "The correct recalled first tile must advance progress")
	TEST_ASSERT(!job.choose(job.order[1]), "A repeated tile must not produce free memory progress")
	var/wrong = 0
	for(var/i in 1 to length(job.matrix))
		if(!job.used[i] && i != job.order[job.progress + 1])
			wrong = i
			break
	var/before_deadline = job.deadline
	var/before_trace = console.intrusion.trace
	TEST_ASSERT(!job.choose(wrong), "An incorrect recalled tile must be rejected")
	TEST_ASSERT_EQUAL(job.deadline, before_deadline - 3 SECONDS, "An incorrect memory answer must pay the announced time penalty")
	TEST_ASSERT_EQUAL(console.intrusion.trace, before_trace + 3, "An incorrect memory answer must leave the announced trace")
	TEST_ASSERT_EQUAL(job.progress, 0, "A recoverable memory error must restart recall progress")
	TEST_ASSERT(job.reveal_until > world.time, "A recoverable error must provide a short repeat preview")

/// A remembered checkpoint survives limited retries, and three errors end the attempt.
/datum/unit_test/netrun_breach_memory_checkpoint/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/netrun_memory_test_host/target = allocate(/obj/item/netrun_memory_test_host)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 2, list(ACCESS_RD))
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	TEST_ASSERT(console.start_breach("node", node.address), "The host must start a real memory breach")
	var/datum/netrun_breach/job = console.intrusion.breach
	job.reveal_until = world.time
	for(var/i in 1 to job.user_goal)
		TEST_ASSERT(job.choose(job.order[i]), "Correct recall must reach the USER checkpoint")
	TEST_ASSERT(job.daemons[1]["done"] && !job.daemons[2]["done"], "The checkpoint must mark USER without prematurely awarding ROOT")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_GUEST, "Checkpoint rewards must wait for the ordinary breach finish lifecycle")
	for(var/attempt in 1 to 3)
		job.reveal_until = world.time
		var/wrong = 0
		for(var/i in 1 to length(job.matrix))
			if(!job.used[i] && i != job.order[job.progress + 1])
				wrong = i
				break
		TEST_ASSERT(!job.choose(wrong), "Wrong recall must consume one of the bounded retries")
	TEST_ASSERT_NULL(console.intrusion.breach, "The third memory error must end the attempt")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_USER, "Finishing after errors must preserve the already earned USER checkpoint")
	TEST_ASSERT(console.start_breach("node", node.address), "A later memory attempt must remain available for ROOT")
	job = console.intrusion.breach
	job.reveal_until = world.time
	var/list/solution = job.order.Copy()
	for(var/index in solution)
		TEST_ASSERT(job.choose(index), "The full remembered sequence must be solvable through actual input")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_ROOT, "Completing memory must use the normal ROOT reward lifecycle")

/// A generated maze is solvable, rejects shortcuts, and backtracking cannot farm USER.
/datum/unit_test/netrun_breach_routing_path/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/netrun_routing_test_host/target = allocate(/obj/item/netrun_routing_test_host)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 2, list(ACCESS_RD))
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	TEST_ASSERT(console.start_breach("node", node.address), "The real host must start its routing challenge")
	var/datum/netrun_breach/job = console.intrusion.breach
	TEST_ASSERT_EQUAL(job.minigame, "routing", "A routing override must select the maze implementation")
	var/list/solution = job.order.Copy()
	TEST_ASSERT(length(solution) >= 9, "ROOT must require more than a trivial entrance-to-exit path")
	TEST_ASSERT(job.user_goal > 2 && job.user_goal < length(solution) - 1, "USER must sit at a distinct checkpoint before the final exit")
	TEST_ASSERT(!job.choose(job.routing_exit), "The server must reject a direct jump to the exit")
	TEST_ASSERT(!job.choose(job.cell(2, 2)), "Diagonal or walled movement must never be accepted")
	TEST_ASSERT(!job.choose(1.5) && !job.choose(0), "The server must reject malformed routing indices")
	for(var/i in 1 to 3)
		TEST_ASSERT(job.choose(solution[2]), "The first orthogonal corridor must be traversable")
		TEST_ASSERT(job.choose(solution[1]), "The player must be able to backtrack out of a corridor")
		TEST_ASSERT_EQUAL(job.progress, 1, "Backtracking must remove path progress instead of farming moves")
		TEST_ASSERT(!job.daemons[1]["done"], "Walking a loop near the entrance must not award USER")
	for(var/i in 2 to job.user_goal)
		TEST_ASSERT(job.choose(solution[i]), "Every generated solution step must be legal through the checkpoint")
	TEST_ASSERT(job.daemons[1]["done"] && !job.daemons[2]["done"], "The explicit checkpoint must award USER before ROOT")
	var/list/payload = job.ui_payload()
	TEST_ASSERT(!("order" in payload), "Routing must not publish its stored solution")
	for(var/list/entry as anything in payload["cells"])
		TEST_ASSERT(!("order" in entry), "Routing cells must describe walls and moves without revealing a solution order")
	for(var/i = job.user_goal + 1, i <= length(solution), i++)
		TEST_ASSERT(job.choose(solution[i]), "The generated route must reach the exit without a teleport or wall crossing")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_ROOT, "Reaching the exit after the checkpoint must award ROOT through the usual lifecycle")

/// Expired or unreachable new challenges cannot accept a last forged winning click.
/datum/unit_test/netrun_breach_grid_lifecycle/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/netrun_routing_test_host/target = allocate(/obj/item/netrun_routing_test_host)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 2, list(ACCESS_RD))
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	TEST_ASSERT(console.start_breach("node", node.address), "The fixture must start its real routing breach")
	var/datum/netrun_breach/job = console.intrusion.breach
	job.deadline = world.time
	TEST_ASSERT(!job.choose(job.order[2]), "An expired maze must reject a delayed input before advancing")
	TEST_ASSERT_NULL(console.intrusion.breach, "An expired input must finish through the ordinary lifecycle")
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_GUEST, "Expiration before the checkpoint must not grant access")
	TEST_ASSERT(console.start_breach("node", node.address), "A fresh attempt must still be possible after expiration")
	job = console.intrusion.breach
	node.offline_until = world.time + 5 SECONDS
	TEST_ASSERT(!job.choose(job.order[2]), "A disabled host must reject a delayed input before granting progress")
	TEST_ASSERT_NULL(console.intrusion.breach, "Loss of the real host must cancel the active puzzle")
	node.offline_until = 0
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_GUEST, "A lost route must not award a stale checkpoint")

/// Every manual protocol displays and honors the critical node's first-stage cap, even with skeleton.
/datum/unit_test/netrun_breach_protocol_access_cap/Run()
	var/obj/item/host = allocate(/obj/item)
	var/obj/item/netrun_memory_test_host/critical/target = allocate(/obj/item/netrun_memory_test_host/critical)
	var/datum/component/netrun_node/node = target.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 2, list(ACCESS_RD))
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.connection.wireless = FALSE
	console.set_jack(node)
	console.inventory.local_store.capacity = 32
	TEST_ASSERT(console.store_file(netrun_daemon_file("skeleton")), "The test must use the real skeleton daemon")
	TEST_ASSERT(console.start_breach("node", node.address), "A critical host must allow its first access stage")
	var/datum/netrun_breach/job = console.intrusion.breach
	TEST_ASSERT_EQUAL(job.initial_access_level, NETRUN_ACCESS_GUEST, "The first stage must capture current guest access before generation")
	TEST_ASSERT_EQUAL(job.access_cap, NETRUN_ACCESS_USER, "The first critical stage must stop at USER even with skeleton")
	for(var/mode in list("matrix", "sequence", "memory", "routing"))
		job.minigame = mode
		job.generate()
		for(var/list/goal as anything in job.daemons)
			TEST_ASSERT(goal["reward"] <= NETRUN_ACCESS_USER, "No manual protocol may publish a reward beyond the first-stage cap")
			TEST_ASSERT(goal["name"] != "ROOT", "A USER-capped reward must not be mislabeled as ROOT")
		var/list/payload = job.ui_payload()
		TEST_ASSERT_EQUAL(payload["access_cap"], NETRUN_ACCESS_USER, "Every manual UI payload must explain the same first-stage cap")
	job.daemons[1]["done"] = TRUE
	job.finish()
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_USER, "The first finished critical breach must award only USER")
	TEST_ASSERT(console.start_breach("node", node.address), "A separate attempt after USER must unlock the second contour")
	job = console.intrusion.breach
	TEST_ASSERT_EQUAL(job.initial_access_level, NETRUN_ACCESS_USER, "The second stage must capture the newly obtained USER grant")
	TEST_ASSERT_EQUAL(job.access_cap, NETRUN_ACCESS_ROOT, "The second contour must permit ROOT")
	TEST_ASSERT_EQUAL(job.daemons[1]["reward"], NETRUN_ACCESS_ROOT, "Skeleton must keep its normal upgrade after the first contour is complete")
