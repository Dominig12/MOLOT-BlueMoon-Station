/**
 * Offline tests of the clean-master NetDM module. No native DLL or Host
 * required: the registry and object lifecycle must remain usable alone.
 */
/datum/unit_test/netdm_bridge_strict_radio_booleans/Run()
	var/datum/netdm_bridge/bridge = new
	var/json_enabled = bridge.netdm_serialize_command(list("op" = "game_radio", "a" = 1, "enabled" = TRUE))
	var/json_disabled = bridge.netdm_serialize_command(list("op" = "game_radio", "a" = 1, "enabled" = FALSE))
	TEST_ASSERT(findtext(json_enabled, "\"enabled\":true"), "Radio on must emit a strict JSON boolean")
	TEST_ASSERT(findtext(json_disabled, "\"enabled\":false"), "Radio off must emit a strict JSON boolean")
	TEST_ASSERT(findtext(bridge.netdm_serialize_command(list("op" = "packet_send", "trafficClass" = 1)),
		"\"trafficClass\":1"), "Packet class must remain a number")
	qdel(bridge)

/datum/unit_test/netdm_component_registry/Run()
	var/obj/a = allocate(/obj, run_loc_floor_bottom_left)
	var/obj/b = allocate(/obj, get_step(run_loc_floor_bottom_left, EAST))
	var/datum/component/netdm_node/node_a = a.netdm_connect()
	var/datum/component/netdm_node/node_b = b.netdm_connect()
	TEST_ASSERT_NOTNULL(node_a, "The first network component must attach")
	TEST_ASSERT_NOTNULL(node_b, "The second network component must attach")
	TEST_ASSERT(node_a.node_id > 0 && node_b.node_id > 0, "Endpoint IDs must be positive")
	TEST_ASSERT_NOTEQUAL(node_a.node_id, node_b.node_id, "Endpoint IDs must be unique")

	var/id_a = node_a.node_id
	var/id_b = node_b.node_id
	TEST_ASSERT_EQUAL(SSnetdm.endpoints_by_id["[id_a]"], node_a, "First endpoint must be registered")
	TEST_ASSERT_EQUAL(SSnetdm.endpoints_by_id["[id_b]"], node_b, "Second endpoint must be registered")
	TEST_ASSERT_EQUAL(a.netdm_interface(), node_a, "Component lookup must not allocate duplicates")

	TEST_ASSERT(SSnetdm.connect_nodes(node_a, node_b), "Wired connection must succeed")
	TEST_ASSERT(SSnetdm.connect_nodes(node_a, node_b), "Connecting twice must be idempotent")
	TEST_ASSERT_EQUAL(length(SSnetdm.links), 1, "Must keep one physical link")
	TEST_ASSERT(SSnetdm.disconnect_nodes(node_a, node_b), "Physical disconnection must succeed")
	TEST_ASSERT_EQUAL(length(SSnetdm.links), 0, "Removed link must disappear")
	TEST_ASSERT(SSnetdm.connect_nodes(node_a, node_b), "A disconnected pair can reconnect")

	var/turf/target = get_step(run_loc_floor_bottom_left, NORTH)
	a.forceMove(target)
	node_a.sync_position()
	TEST_ASSERT_EQUAL(node_a.last_x, target.x, "Moved endpoint must update X")
	TEST_ASSERT_EQUAL(node_a.last_y, target.y, "Moved endpoint must update Y")

	qdel(a)
	TEST_ASSERT_NULL(SSnetdm.endpoints_by_id["[id_a]"], "Deleted object must unregister its endpoint")
	TEST_ASSERT_EQUAL(length(SSnetdm.links), 0, "Removing an endpoint must clean up its links")
	qdel(b)
	TEST_ASSERT_NULL(SSnetdm.endpoints_by_id["[id_b]"], "Second object must unregister")
