/// The visible recovery window must agree with the action and preserve unspent resources.
/datum/unit_test/netrun_combat_action_recovery/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_console/console = entity.console
	var/datum/netrun_ice/ice = allocate(/datum/netrun_ice, node)
	TEST_ASSERT(console.program_use("builtin:sting", REF(ice)), "An available attack must execute")
	var/list/payload = console.combat_payload()
	TEST_ASSERT_EQUAL(payload["action_ready_in"], 0.5, "The common recovery window must be visible immediately")
	var/trace_before = console.intrusion.trace
	TEST_ASSERT(!console.program_use("builtin:shell", null), "A second program must wait for common recovery")
	TEST_ASSERT_NULL(console.combat_context.program_cd["shell"], "A rejected action must not spend its program cooldown")
	TEST_ASSERT_EQUAL(console.intrusion.trace, trace_before, "A rejected action must not add trace")
	console.combat_context.program_cd["sting"] = world.time + 0.25
	var/list/entry = console.combat_context.program_entry(SSnetrun.get_program("sting"), "builtin:sting", TRUE)
	TEST_ASSERT_EQUAL(entry["ready_in"], 0.1, "A positive remaining cooldown must never be advertised as ready")
	console.combat_context.next_program = world.time
	payload = console.combat_payload()
	TEST_ASSERT_EQUAL(payload["action_ready_in"], 0, "Common recovery must clear exactly at its deadline")

/// Disengagement is lost only after an actual offensive action, including non-damaging stun.
/datum/unit_test/netrun_combat_offense_reveals_process/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.enter_node(node)
	var/datum/netrun_console/console = entity.console
	console.access_session.node_access[node.address] = NETRUN_ACCESS_USER
	var/datum/netrun_ice/ice = allocate(/datum/netrun_ice, node)
	entity.combat_ignore_until = world.time + NETRUN_DISENGAGE_GRACE
	var/grace_until = entity.combat_ignore_until
	TEST_ASSERT(!console.program_use("builtin:sting", null), "An unavailable target must reject the attack")
	TEST_ASSERT_EQUAL(entity.combat_ignore_until, grace_until, "A rejected attack must preserve disengagement")
	TEST_ASSERT(console.program_use("builtin:shell", null), "Defensive preparation must remain available while hidden")
	TEST_ASSERT_EQUAL(entity.combat_ignore_until, grace_until, "A defensive action must preserve disengagement")
	console.combat_context.next_program = world.time
	TEST_ASSERT(console.program_use("builtin:sting", REF(ice)), "An authorized process can still deliberately attack ICE")
	TEST_ASSERT_EQUAL(entity.combat_ignore_until, 0, "A successful attack must reveal the process")
	TEST_ASSERT_EQUAL(ice.find_intruder(node), entity, "The attacked ICE must retaliate even if its attacker has USER access")
	console.disengage_combat()
	TEST_ASSERT(ice.next_attack > world.time, "Disengagement must give its original attacker a reaction pause")
	TEST_ASSERT_NULL(ice.find_intruder(node), "Disengagement must clear deliberate aggression")
	var/datum/netrun_file/blackout = netrun_program_file("blackout")
	TEST_ASSERT(console.store_file(blackout), "The real stun executable must fit in process memory")
	console.combat_context.next_program = world.time
	TEST_ASSERT(console.program_use(blackout.uid, REF(ice)), "The real stun executable must execute against ICE")
	TEST_ASSERT_EQUAL(entity.combat_ignore_until, 0, "An offensive stun must also reveal the process")
	TEST_ASSERT(ice.next_attack <= world.time, "Renewed aggression must remove the attacked ICE's disengagement pause")
	TEST_ASSERT_EQUAL(ice.enemy_ref?.resolve(), entity, "Stun must establish retaliation without requiring damage")
	ice.combat_stun_until = world.time
	TEST_ASSERT_EQUAL(ice.find_intruder(node), entity, "The ICE must retain its attacker after stun ends")

/// Shell must not weaken fortify or extend fortify's stronger protection for free.
/datum/unit_test/netrun_combat_shield_priority/Run()
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	entity.apply_shield(65, 5 SECONDS)
	var/strong_until = entity.combat_shield_until
	entity.apply_shield(35, 10 SECONDS)
	TEST_ASSERT_EQUAL(entity.combat_shield_factor, 1 - 65 / 100, "A weaker shield must not replace stronger protection")
	TEST_ASSERT_EQUAL(entity.combat_shield_until, strong_until, "A weaker shield must not extend stronger protection")
	entity.apply_damage(20)
	TEST_ASSERT_EQUAL(entity.integrity, entity.max_integrity - 7, "The original stronger shield must still determine actual damage")
	entity.combat_shield_until = world.time
	entity.apply_shield(35, 5 SECONDS)
	TEST_ASSERT_EQUAL(entity.combat_shield_factor, 1 - 35 / 100, "Expired stronger protection must not block a fresh weaker shield")
	entity.apply_shield(50, 5 SECONDS)
	TEST_ASSERT_EQUAL(entity.combat_shield_factor, 0.5, "A stronger shield must replace active weaker protection")

/// PvP and external status changes must wake a quiet process UI immediately.
/datum/unit_test/netrun_combat_entity_status_notifications/Run()
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	var/datum/netrun_console/console = entity.console
	console.ui_dirty = FALSE
	entity.apply_stun(2 SECONDS)
	TEST_ASSERT(console.ui_dirty, "An external stun must invalidate the target's own UI")
	console.ui_dirty = FALSE
	entity.apply_shield(50, 5 SECONDS)
	TEST_ASSERT(console.ui_dirty, "An external shield must invalidate the target's own UI")
	console.ui_dirty = FALSE
	entity.take_integrity(10)
	TEST_ASSERT(console.ui_dirty, "External integrity damage must invalidate the target's own UI")
	console.ui_dirty = FALSE
	entity.apply_heal(10)
	TEST_ASSERT(console.ui_dirty, "External repair must invalidate the target's own UI")

/// Opponent status badges expire even when this viewer has no incoming cast or cooldown.
/datum/unit_test/netrun_combat_target_status_expiry/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/mob/camera/netrun_entity/viewer = allocate(/mob/camera/netrun_entity)
	var/mob/camera/netrun_entity/target = allocate(/mob/camera/netrun_entity)
	viewer.enter_node(node)
	target.enter_node(node)
	var/datum/netrun_combat_context/combat = viewer.console.combat_context
	viewer.console.workspace_view = "combat"
	combat.targets()
	TEST_ASSERT(!combat.needs_live_refresh(), "Unchanged visible opponents must allow the UI to become quiet")
	target.apply_stun(2 SECONDS)
	TEST_ASSERT(combat.needs_live_refresh(), "An opponent's active stun must keep its badge current")
	target.combat_stun_until = world.time
	target.apply_shield(50, 5 SECONDS)
	TEST_ASSERT(combat.needs_live_refresh(), "An opponent's active shield must keep its badge current")
	viewer.console.workspace_view = "terminal"
	TEST_ASSERT(!combat.needs_live_refresh(), "Hidden opponent badges must not poll another workspace")
	viewer.console.workspace_view = "combat"
	viewer.console.process_tick(0)
	TEST_ASSERT(viewer.console.live_refresh_until > world.time, "A visible timed status must retain the closing refresh frame")
	target.combat_shield_until = world.time
	TEST_ASSERT(!combat.needs_live_refresh(), "Expired opponent statuses must release live refresh")
	viewer.console.ui_dirty = FALSE
	viewer.console.process_tick(0)
	TEST_ASSERT(viewer.console.ui_dirty, "The status expiry frame must still repaint after its countdown stops")
	var/list/targets = combat.targets()
	var/list/entry = targets[1]
	TEST_ASSERT(!entry["shielded"], "The closing payload must remove the expired opponent badge")
