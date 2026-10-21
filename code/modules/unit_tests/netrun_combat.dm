/// Automatic breaches reuse real target validation and never award access early.
/datum/unit_test/netrun_autobreach_lifecycle/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_console/console = entity.console
	TEST_ASSERT(!console.start_breach("node", node.address, TRUE), "Automatic hacking must require an actual daemon file")
	TEST_ASSERT(console.store_file(netrun_daemon_file("autobreach")), "The daemon must occupy actual process memory")
	TEST_ASSERT(console.start_breach("node", node.address, TRUE), "The installed daemon must start a normal reachable target")
	var/datum/netrun_breach/automatic/job = console.breach
	TEST_ASSERT(istype(job), "Automatic mode must use its own breach implementation")
	TEST_ASSERT(job.duration >= 14 SECONDS && job.duration <= 30 SECONDS, "Node cracking must have a bounded, useful waiting period")
	TEST_ASSERT(!job.choose(1), "Puzzle clicks must not accelerate automatic cracking")
	job.finish()
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_GUEST, "Stopping early must never award USER")
	TEST_ASSERT(console.start_breach("node", node.address, TRUE), "The daemon must remain usable after a cancelled attempt")
	job = console.breach
	job.deadline = world.time
	job.finish()
	TEST_ASSERT_EQUAL(console.node_level(node), NETRUN_ACCESS_USER, "An uninterrupted completed timer must guarantee USER without a random roll")
	TEST_ASSERT(!console.start_breach("firmware", node.address, TRUE), "Automatic cracking must not bypass the separate firmware challenge")

/datum/unit_test/netrun_autobreach_program_revocation/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_file/file = netrun_daemon_file("autobreach")
	entity.console.store_file(file)
	TEST_ASSERT(entity.console.start_breach("node", node.address, TRUE), "The actual daemon must start its job")
	entity.console.delete_local_file(file)
	entity.console.process_tick(1)
	TEST_ASSERT_NULL(entity.console.breach, "Removing the only daemon copy must cancel the active automatic job")
	TEST_ASSERT_EQUAL(entity.console.node_level(node), NETRUN_ACCESS_GUEST, "A revoked program must not grant delayed access")

/// ICE programs warn first, share shield handling, and retain their own cooldowns.
/datum/unit_test/netrun_ice_program_reaction/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_ice/ice = allocate(/datum/netrun_ice, node)
	var/datum/netrun_program/strike = SSnetrun.get_program("strike")
	var/initial_integrity = entity.integrity
	TEST_ASSERT(ice.begin_program(strike, entity), "A sentry must be able to queue its real strike program")
	TEST_ASSERT(ice.attack_at >= world.time + 2 SECONDS, "The player must receive a meaningful reaction period")
	TEST_ASSERT_EQUAL(entity.integrity, initial_integrity, "Announcing an attack must not deal immediate damage")
	var/list/incoming = entity.console.incoming_programs()
	TEST_ASSERT_EQUAL(length(incoming), 1, "The targeted process must see an incoming program")
	entity.apply_shield(50, 5 SECONDS)
	ice.attack_at = world.time
	ice.resolve_program()
	TEST_ASSERT_EQUAL(entity.integrity, initial_integrity - strike.power * 0.5, "ICE damage must use the same shield-aware dispatcher as player damage")
	ice.next_attack = world.time
	TEST_ASSERT(!ice.begin_program(strike, entity), "The program's own cooldown must prevent another immediate cast")
	ice.program_cd.Cut()
	TEST_ASSERT(ice.begin_program(strike, entity), "An expired program cooldown must allow a new warning")
	ice.apply_stun(2 SECONDS)
	TEST_ASSERT_NULL(ice.pending_program, "Stunning ICE must interrupt its prepared program")
	ice.resolve_program()
	TEST_ASSERT_EQUAL(entity.integrity, initial_integrity - strike.power * 0.5, "An interrupted program must not deal later damage")
	TEST_ASSERT(!entity.console.program_use("builtin:logic_bomb", REF(ice)), "A forged builtin UID must not conjure a consumable program")

/// Entity acquisition is real loot, and a full inventory does not silently lose it.
/datum/unit_test/netrun_entity_daemon_salvage/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_ice/ice = allocate(/datum/netrun_ice, node)
	entity.console.storage_capacity = 0
	ice.drop_loot(entity.console)
	TEST_ASSERT_EQUAL(length(node.salvage), 1, "A defeated sentry must leave a daemon even when the killer has no free memory")
	var/datum/netrun_file/file = node.salvage[1]
	TEST_ASSERT_EQUAL(file.kind, NETRUN_FILE_DAEMON, "The primary reward must be a usable daemon rather than only a combat card")
	TEST_ASSERT(!entity.console.recover_salvage(file.uid), "Picking up debris must honor process memory capacity")
	TEST_ASSERT(file in node.salvage, "A failed pickup must preserve the actual file")
	entity.console.storage_capacity = file.size
	TEST_ASSERT(entity.console.recover_salvage(file.uid), "The resident entity must be able to obtain the daemon without USER rights on the host")
	TEST_ASSERT_EQUAL(length(node.salvage), 0, "Successful pickup must transfer ownership out of the debris cache")
	TEST_ASSERT(file in entity.console.storage, "The actual recovered file must be stored in process memory")
	TEST_ASSERT(!entity.console.recover_salvage(file.uid), "Repeating a pickup request must not duplicate the daemon")
