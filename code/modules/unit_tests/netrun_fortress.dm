/// Two endpoints behind one real APC: A - APC - B, all in one engineering LAN.
/datum/netrun_fortress_scene
	parent_type = /datum/netrun_route_scene
	var/obj/machinery/power/apc/apc
	var/datum/component/netrun_node/apc_node
	var/datum/component/netrun_node/node_a
	var/datum/component/netrun_node/node_b

/datum/netrun_fortress_scene/New(turf/origin)
	..(origin.z)
	var/area/room = room(/area/engineering/netrun_route_test)
	take(origin, room)
	var/turf/b_spot = take(get_step(origin, EAST), room)
	var/turf/apc_spot = take(get_step(origin, NORTH), room)
	apc = machine(/obj/machinery/power/apc, apc_spot)
	apc_node = apc.GetComponent(/datum/component/netrun_node)
	// Anchored endpoints are stationary devices that may carry fortress works.
	var/obj/item/a_host = new(origin)
	a_host.anchored = TRUE
	owned += a_host
	node_a = a_host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL, list(), 1, list(), 4)
	var/obj/item/b_host = new(b_spot)
	b_host.anchored = TRUE
	owned += b_host
	node_b = b_host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_SERVER, list(), 1, list(), 4)
	SSnetrun.ensure_topology()

/datum/netrun_fortress_scene/proc/key_file()
	var/datum/netrun_network/network = node_b.network
	return new /datum/netrun_file("[network.id].key", NETRUN_FILE_KEY, network.passcode, 1, network.id)

/// Bare items are stationary and anchored enough for the fortress slot rule.
/datum/unit_test/proc/netrun_fortress_node(node_type = NETRUN_NODE_SERVER)
	var/obj/item/host = allocate(/obj/item)
	host.anchored = TRUE
	return host.AddComponent(/datum/component/netrun_node, node_type, list(), 1, list(), 4)

/datum/unit_test/netrun_fortress_build_requirements/Run()
	var/datum/component/netrun_node/node = netrun_fortress_node()
	var/mob/camera/netrun_entity/builder = allocate(/mob/camera/netrun_entity)
	builder.enter_node(node)
	var/datum/netrun_console/console = builder.console
	console.access_session.node_access[node.address] = NETRUN_ACCESS_ROOT
	TEST_ASSERT(findtext(netrun_fortress_build_denial(node, console, NETRUN_FORT_WALL), "forge.exe"), "Building must require the forge daemon")
	TEST_ASSERT(console.store_file(netrun_daemon_file("forge")), "The forge daemon must fit client memory")
	TEST_ASSERT_NULL(netrun_fortress_build_denial(node, console, NETRUN_FORT_WALL), "ROOT with forge.exe may build on a server")
	TEST_ASSERT(netrun_fortress_build_denial(node, console, "moat"), "Unknown modules are refused")
	var/before = node.get_security()
	var/datum/netrun_fortress_module/wall = SSnetrun.build_fortress_module(node, NETRUN_FORT_WALL, console)
	TEST_ASSERT_NOTNULL(node.fortress, "The first module founds the fortress")
	TEST_ASSERT(node.fortress.is_owner(console), "The builder owns the new fortress")
	TEST_ASSERT_EQUAL(wall.status, NETRUN_FORT_MODULE_BUILDING, "A new module is a construction site first")
	TEST_ASSERT_EQUAL(node.get_security(), before, "Scaffolding gives no protection")
	wall.complete_build()
	TEST_ASSERT_EQUAL(node.get_security(), min(5, before + 1), "A standing wall raises the node's security")
	TEST_ASSERT(SSnetrun.fortress_nodes[node.address] == node, "Fortified nodes are indexed for siege lookups")
	var/datum/component/netrun_node/camera = netrun_fortress_node(NETRUN_NODE_CAMERA)
	TEST_ASSERT(findtext(netrun_fortress_build_denial(camera, console, NETRUN_FORT_WALL), "не может"), "Cameras cannot carry works")
	TEST_ASSERT(("fort_build@wall" in node.all_command_ids()) && !("fort_build@wall" in camera.all_command_ids()), "Only eligible nodes publish the build menu")
	TEST_ASSERT("fort_dismantle@wall" in node.all_command_ids(), "Built kinds can be dismantled")

/datum/unit_test/netrun_fortress_walls_block_breach/Run()
	var/datum/component/netrun_node/node = netrun_fortress_node()
	var/obj/item/owner_host = allocate(/obj/item)
	var/datum/netrun_console/owner = allocate(/datum/netrun_console, owner_host)
	var/datum/netrun_fortress/fortress = new(node, "Проверка", NETRUN_FACTION_OWNER, owner)
	node.fortress = fortress
	var/datum/netrun_fortress_module/wall = fortress.add_module(NETRUN_FORT_WALL, TRUE)
	var/mob/camera/netrun_entity/intruder = allocate(/mob/camera/netrun_entity)
	intruder.enter_node(node)
	TEST_ASSERT(fortress.blocks_breach(intruder.console), "Standing walls refuse strangers")
	TEST_ASSERT(!fortress.blocks_breach(owner), "The owner is never blocked by own walls")
	TEST_ASSERT(!intruder.console.start_breach("node", node.address), "The breach protocol cannot start through a wall")
	wall.take_damage(1000, "test", null)
	TEST_ASSERT_EQUAL(wall.status, NETRUN_FORT_MODULE_DESTROYED, "Enough damage destroys a module")
	TEST_ASSERT(!fortress.blocks_breach(intruder.console), "A ruined wall no longer protects the node")
	TEST_ASSERT(intruder.console.start_breach("node", node.address), "The node can be cracked once the walls fall")
	intruder.console.intrusion.breach.finish()
	TEST_ASSERT(fortress.ruined(), "A fortress with every module destroyed is a ruin")
	TEST_ASSERT(fortress.can_build(intruder.console), "Ruins may be claimed by a new builder")

/datum/unit_test/netrun_fortress_gate_and_trap/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/obj/item/owner_host = allocate(/obj/item)
	var/datum/netrun_console/owner = allocate(/datum/netrun_console, owner_host)
	var/mob/camera/netrun_entity/visitor = allocate(/mob/camera/netrun_entity)
	visitor.enter_node(scene.apc_node)
	TEST_ASSERT(visitor.console.store_file(scene.key_file()), "The visitor carries the LAN key")
	TEST_ASSERT(visitor.can_enter(scene.node_b), "A LAN key admits travel to an unfortified neighbour")
	var/datum/netrun_fortress/fortress = new(scene.node_b, "Проверка", NETRUN_FACTION_OWNER, owner)
	scene.node_b.fortress = fortress
	fortress.add_module(NETRUN_FORT_GATE, TRUE)
	TEST_ASSERT(!visitor.can_enter(scene.node_b), "A closed gate ignores LAN keys")
	TEST_ASSERT(findtext(visitor.hop_denial(scene.node_b), "врата"), "The refusal names the gate")
	visitor.console.access_session.node_access[scene.node_b.address] = NETRUN_ACCESS_USER
	TEST_ASSERT(visitor.can_enter(scene.node_b), "USER on the node passes the gate")
	visitor.console.access_session.node_access -= scene.node_b.address
	var/datum/netrun_fortress_module/trap = fortress.add_module(NETRUN_FORT_TRAP, TRUE)
	var/trace_before = visitor.console.intrusion.trace
	visitor.enter_node(scene.node_b)
	TEST_ASSERT(visitor.is_stunned(), "An armed trap stuns a hostile arrival")
	TEST_ASSERT(visitor.console.intrusion.trace > trace_before, "A trap exposes the intruder's session")
	TEST_ASSERT(trap.ready_at > world.time, "A sprung trap needs time to re-arm")
	visitor.combat_stun_until = 0
	var/trace_after = visitor.console.intrusion.trace
	visitor.enter_node(scene.apc_node)
	visitor.enter_node(scene.node_b)
	TEST_ASSERT(!visitor.is_stunned() && visitor.console.intrusion.trace == trace_after, "A spent trap does not fire twice")

/datum/unit_test/netrun_fortress_siege_adjacent/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/obj/item/owner_host = allocate(/obj/item)
	var/datum/netrun_console/owner = allocate(/datum/netrun_console, owner_host)
	var/datum/netrun_fortress/fortress = new(scene.node_b, "Проверка", NETRUN_FACTION_OWNER, owner)
	scene.node_b.fortress = fortress
	var/datum/netrun_fortress_module/wall = fortress.add_module(NETRUN_FORT_WALL, TRUE)
	var/datum/netrun_fortress_module/turret = fortress.add_module(NETRUN_FORT_TURRET, TRUE)
	TEST_ASSERT((wall in fortress.siege_targets()) && !(turret in fortress.siege_targets()), "Walls shield the inner works from a siege")
	var/mob/camera/netrun_entity/attacker = allocate(/mob/camera/netrun_entity)
	attacker.enter_node(scene.apc_node)
	TEST_ASSERT(scene.node_b in netrun_adjacent_fortress_nodes(scene.apc_node), "The neighbouring fortress is visible to a besieger")
	var/datum/component/netrun_combatant/combatant = wall.get_netrun_combatant()
	TEST_ASSERT(combatant.allows_remote_attack(attacker.console, scene.apc_node), "Outer works can be hit from an adjacent node")
	TEST_ASSERT(!combatant.allows_remote_attack(attacker.console, scene.node_a), "Two hops away is out of siege range")
	var/found = FALSE
	for(var/list/entry as anything in attacker.console.combat_targets())
		if(entry["ref"] == REF(wall))
			found = TRUE
			TEST_ASSERT_NULL(entry["unavailable_reason"], "An adjacent besieger may target the wall")
			TEST_ASSERT_EQUAL(entry["kind"], "fortress", "Structures are their own target kind")
	TEST_ASSERT(found, "The wall appears among the besieger's targets")
	wall.take_damage(1000, "test", attacker.console)
	TEST_ASSERT(turret in fortress.siege_targets(), "Once the walls fall the inner works are exposed")

/datum/unit_test/netrun_fortress_vault_access/Run()
	var/datum/component/netrun_node/node = netrun_fortress_node()
	var/obj/item/owner_host = allocate(/obj/item)
	var/datum/netrun_console/owner = allocate(/datum/netrun_console, owner_host)
	var/obj/item/stranger_host = allocate(/obj/item)
	var/datum/netrun_console/stranger = allocate(/datum/netrun_console, stranger_host)
	var/base_capacity = node.file_store.capacity
	var/datum/netrun_fortress/fortress = new(node, "Проверка", NETRUN_FACTION_OWNER, owner)
	node.fortress = fortress
	var/datum/netrun_fortress_module/vault = fortress.add_module(NETRUN_FORT_VAULT, TRUE)
	TEST_ASSERT_EQUAL(node.file_store.capacity, base_capacity + NETRUN_FORT_VAULT_STORAGE, "A vault extends the node disk")
	TEST_ASSERT_EQUAL(fortress.file_access_level(stranger), NETRUN_ACCESS_ROOT, "Strangers need ROOT for vault files")
	TEST_ASSERT_EQUAL(fortress.file_access_level(owner), 0, "The owner keeps ordinary file access")
	vault.take_damage(1000, "test", null)
	TEST_ASSERT_EQUAL(node.file_store.capacity, base_capacity, "A destroyed vault returns its storage")
	TEST_ASSERT_EQUAL(fortress.file_access_level(stranger), 0, "A destroyed vault no longer locks files")

/datum/unit_test/netrun_fortress_preset_lifecycle/Run()
	var/datum/component/netrun_node/node = netrun_fortress_node()
	var/datum/netrun_fortress/fortress = SSnetrun.build_fortress_preset(node, "rnd_archive")
	TEST_ASSERT_NOTNULL(fortress, "A preset deploys on an eligible node")
	TEST_ASSERT_EQUAL(fortress.faction, NETRUN_FACTION_STATION, "Station presets belong to the station")
	TEST_ASSERT_EQUAL(length(fortress.modules), 5, "The archive preset deploys all its modules")
	TEST_ASSERT_EQUAL(fortress.intact_count(NETRUN_FORT_WALL), 2, "Preset modules stand immediately")
	TEST_ASSERT_EQUAL(SSnetrun.build_fortress_preset(node, "relay_outpost"), fortress, "A fortified node keeps its fortress")
	var/list/summary = node.ui_entry(allocate(/datum/netrun_console, allocate(/obj/item)))["fortress"]
	TEST_ASSERT_EQUAL(summary?["walls"], 2, "The map summary counts standing walls")
	var/address = node.address
	qdel(node)
	TEST_ASSERT(QDELETED(fortress), "A deleted node takes its fortress with it")
	TEST_ASSERT_NULL(SSnetrun.fortress_nodes[address], "The siege index forgets deleted fortresses")
