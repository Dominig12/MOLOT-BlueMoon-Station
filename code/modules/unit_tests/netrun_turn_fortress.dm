/// Native outer-wall attacks admit a battery; idle decision time cannot fire or heal it.
/datum/unit_test/netrun_turn_fortress_siege/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/datum/netrun_fortress/fortress = new(scene.node_b, "Turn battery", NETRUN_FACTION_ROGUE)
	scene.node_b.fortress = fortress
	var/datum/netrun_fortress_module/wall = fortress.add_module(NETRUN_FORT_WALL, TRUE)
	fortress.add_module(NETRUN_FORT_TURRET, TRUE)
	fortress.add_module(NETRUN_FORT_REGEN, TRUE)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.apc_node)
	TEST_ASSERT(entity.console.store_file(scene.key_file()), "The siege uses a real route through the neighbouring APC")
	TEST_ASSERT(entity.console.program_use("builtin:sting", REF(wall)), "The actual outer-wall program starts a legal adjacent siege")
	var/datum/netrun_combat_encounter/encounter = entity.console.get_combat_encounter()
	TEST_ASSERT(encounter?.contains(fortress) && encounter.has_turn(entity), "One fortress battery joins the initiating player's queue")
	TEST_ASSERT(fortress.valid_turn_siege(entity), "Admission records the exact live neighbouring source without granting entry")
	TEST_ASSERT_EQUAL(entity.host_node, scene.apc_node, "Siege admission does not move the process into the defended node")
	fortress.besiegers[WEAKREF(entity)] = world.time - 21 SECONDS
	var/list/lease = fortress.turn_siege_leases[WEAKREF(entity)]
	lease["until"] = world.time - 1
	TEST_ASSERT(fortress.valid_turn_siege(entity) && fortress.valid_turret_target(entity), "Thinking through several turns cannot expire a live siege's native target lease")
	var/wall_before = wall.integrity
	var/health_before = entity.integrity
	for(var/pass in 1 to 8)
		fortress.process_tick()
	TEST_ASSERT_EQUAL(wall.integrity, wall_before, "A regenerator cannot heal repeatedly while the attacker is deciding")
	TEST_ASSERT_EQUAL(entity.integrity, health_before, "A turret cannot strike between turns")
	TEST_ASSERT_EQUAL(fortress.next_deadline(), INFINITY, "An off-turn battery schedules no polling or combat deadline")
	TEST_ASSERT(encounter.pass(entity), "The attacker yields to the battery")
	SSnetrun.get_task_scheduler().cancel("fortress", fortress)
	fortress.process_tick()
	TEST_ASSERT_EQUAL(wall.integrity, min(wall.max_integrity, wall_before + 6), "The battery spends one AP for exactly its native repair amount")
	TEST_ASSERT(fortress.turret_fire_at && encounter.deferred && encounter.member(fortress).ap == 0, "One AP of regeneration and two AP of volley reserve the full turn")
	TEST_ASSERT_EQUAL(entity.integrity, health_before, "Committing a volley retains its native preparation window")
	fortress.turret_fire_at = world.time
	fortress.process_tick()
	TEST_ASSERT(entity.integrity < health_before && encounter.has_turn(entity), "The prepared volley applies before the battery yields")
	var/after_volley = entity.integrity
	fortress.process_tick()
	TEST_ASSERT_EQUAL(entity.integrity, after_volley, "Another fortress tick cannot fire again in the player's turn")
	scene.apc_node.offline_until = world.time + 1 MINUTES
	TEST_ASSERT(!fortress.valid_turn_siege(entity) && !encounter.member(entity).valid(), "A lost native direct link invalidates the admission lease")
	scene.apc_node.offline_until = 0
	entity.enter_node(scene.node_a)
	TEST_ASSERT(QDELETED(encounter) && !fortress.get_combat_encounter(), "Leaving the admitted siege source releases the battery's encounter")

/// Turret jamming consumes a battery turn; destroying its last active module removes the actor.
/datum/unit_test/netrun_turn_fortress_stun_and_cleanup/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/datum/netrun_fortress/fortress = new(scene.node_b, "Jammed battery", NETRUN_FACTION_ROGUE)
	scene.node_b.fortress = fortress
	var/datum/netrun_fortress_module/turret = fortress.add_module(NETRUN_FORT_TURRET, TRUE)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.node_b)
	var/datum/netrun_combat_encounter/encounter = scene.node_b.get_combat_encounter()
	TEST_ASSERT(encounter.admit(entity, 1, turret), "The native turret maps to its one active battery")
	var/datum/netrun_program/stun = SSnetrun.get_program("blackout")
	turret.jam(stun.power)
	encounter.apply_program_status(stun, turret)
	TEST_ASSERT_EQUAL(turret.jammed_until, INFINITY, "A jam cannot expire during another actor's decision countdown")
	encounter.pass(entity)
	TEST_ASSERT(encounter.has_turn(entity) && !turret.is_jammed(), "The battery's skipped turn consumes only its owned jam sentinel")
	TEST_ASSERT(!encounter.can_apply_program_status(stun, turret), "The battery shares the bounded anti-chain-stun rule")
	TEST_ASSERT(!fortress.turret_fire_at, "A skipped battery turn launches no hidden volley")
	turret.take_damage(10000, "test", entity.console)
	TEST_ASSERT(QDELETED(encounter), "Destroying the last active capability removes the battery immediately")
	TEST_ASSERT_NULL(entity.console.get_combat_encounter(), "The surviving process is released from the dead battery's queue")
	TEST_ASSERT_NULL(fortress.get_combat_encounter(), "The fortress keeps no stale controller binding")

/// Purely passive works remain damage targets without acquiring their own AP turn.
/datum/unit_test/netrun_turn_fortress_passive_walls/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/datum/netrun_fortress/fortress = new(scene.node_b, "Passive wall", NETRUN_FACTION_ROGUE)
	scene.node_b.fortress = fortress
	var/datum/netrun_fortress_module/wall = fortress.add_module(NETRUN_FORT_WALL, TRUE)
	TEST_ASSERT_NULL(netrun_turn_actor(wall), "A wall without an active battery is not an autonomous participant")
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.apc_node)
	TEST_ASSERT(entity.console.store_file(scene.key_file()), "A passive siege still uses a native reachable route")
	TEST_ASSERT(entity.console.program_use("builtin:sting", REF(wall)), "The existing outer-wall damage contract remains available")
	TEST_ASSERT(wall.integrity < wall.max_integrity, "The real program damages the passive module")
	TEST_ASSERT_NULL(entity.console.get_combat_encounter(), "A passive wall creates no artificial opposing turn")

/// Dying-controller teardown cancels its native volley despite weak resolve hiding it.
/datum/unit_test/netrun_turn_fortress_pending_teardown/Run()
	var/datum/netrun_fortress_scene/scene = allocate(/datum/netrun_fortress_scene, run_loc_floor_bottom_left)
	var/datum/netrun_fortress/fortress = new(scene.node_b, "Cancelled battery", NETRUN_FACTION_ROGUE)
	scene.node_b.fortress = fortress
	fortress.add_module(NETRUN_FORT_TURRET, TRUE)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, run_loc_floor_bottom_left, scene.node_b)
	var/health_before = entity.integrity
	fortress.process_tick()
	var/datum/netrun_combat_encounter/encounter = fortress.get_combat_encounter()
	TEST_ASSERT(encounter?.has_turn(fortress) && encounter.deferred && fortress.turret_fire_at, "The native battery reserves a real pending volley")
	entity.enter_node(scene.apc_node)
	TEST_ASSERT(QDELETED(encounter), "The final opponent's forced departure destroys the controller")
	TEST_ASSERT(!fortress.turret_fire_at && !fortress.turret_target_ref, "Controller destruction cancels its already prepared native volley")
	TEST_ASSERT(!fortress.combat_encounter_ref && !entity.console.combat_encounter_ref, "Teardown clears exact weak bindings without resolving the dying controller")
	fortress.process_tick()
	TEST_ASSERT_EQUAL(entity.integrity, health_before, "A later native fortress tick cannot deliver the cancelled volley")
