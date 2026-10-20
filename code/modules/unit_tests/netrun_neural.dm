/// The display is a separate service, not a replacement for the wearer's cyber node.
/datum/unit_test/netrun_neural_endpoint_lifecycle/Run()
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human)
	var/datum/component/netrun_node/cyber_node = user.AddComponent(/datum/component/netrun_node, NETRUN_NODE_IMPLANT, list(), 2)
	var/datum/component/neural_interface/interface = user.LoadComponent(/datum/component/neural_interface)
	interface.AddSource("NETRUN_TEST")
	var/datum/component/netrun_neural_adapter/adapter = interface.GetComponent(/datum/component/netrun_neural_adapter)
	TEST_ASSERT_NOTNULL(adapter, "The neural display has no network adapter")
	var/obj/effect/netrun_endpoint/neural/endpoint = adapter.endpoint
	TEST_ASSERT_NOTNULL(endpoint, "The neural adapter has no endpoint")
	var/datum/component/netrun_node/display_node = endpoint.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT(display_node != cyber_node, "The display reused the cybernetics node")
	TEST_ASSERT_EQUAL(user.GetComponent(/datum/component/netrun_node), cyber_node, "The display replaced the cybernetics node")
	TEST_ASSERT_EQUAL(endpoint.loc, user, "The endpoint does not follow its wearer")
	var/address = display_node.address
	TEST_ASSERT_EQUAL(SSnetrun.find_node(address), display_node, "The endpoint is not addressable")
	interface.RemoveSource("NETRUN_TEST")
	TEST_ASSERT(QDELETED(interface), "Removing the last source kept the interface alive")
	TEST_ASSERT(QDELETED(endpoint), "Removing the interface leaked its endpoint")
	TEST_ASSERT_NULL(SSnetrun.find_node(address), "The destroyed endpoint kept its address")
	TEST_ASSERT(!QDELETED(cyber_node), "Destroying the display also destroyed the cybernetics node")

/// Only carrying a device grants ownership, including carrying it inside a container.
/datum/unit_test/netrun_portable_owner_access/Run()
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human)
	var/obj/item/netrun_deck/deck = allocate(/obj/item/netrun_deck)
	var/obj/item/storage/backpack/bag = allocate(/obj/item/storage/backpack)
	var/datum/netrun_console/console = deck.console
	console.operator = user
	TEST_ASSERT_EQUAL(deck.netrun_owner_access(console), NETRUN_ACCESS_NONE, "A nearby operator received ownership of a floor device")
	bag.forceMove(user)
	deck.forceMove(bag)
	TEST_ASSERT_EQUAL(deck.netrun_owner_access(console), NETRUN_ACCESS_ROOT, "An operator carrying the deck in a container lost ownership")
	deck.forceMove(get_turf(user))
	TEST_ASSERT_EQUAL(deck.netrun_owner_access(console), NETRUN_ACCESS_NONE, "A dropped device retained its previous owner's rights")

/// Standard neural signals, console events and damage feedback all reach resident processes.
/datum/unit_test/netrun_entity_neural_feedback/Run()
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity)
	var/datum/component/neural_interface/interface = entity.GetComponent(/datum/component/neural_interface)
	TEST_ASSERT_NOTNULL(interface, "The resident process rejected the neural display component")
	var/datum/neural_interface_module/data/data_module = interface.modules["data"]
	SEND_SIGNAL(entity, COMSIG_NEURAL_INTERFACE_WRITE_DATA, "TEST_SIGNAL", "received", 5 SECONDS)
	TEST_ASSERT_EQUAL(data_module.get_data_entry_value("TEST_SIGNAL"), "received", "The standard display signal did not reach the process")
	var/datum/neural_interface_module/logs/log_module = interface.modules["log"]
	entity.console.log_line("Error <broken>", "bad")
	var/datum/log_entry/entry = log_module.logs[length(log_module.logs)]
	TEST_ASSERT(findtext(entry.plain, "Error &lt;broken&gt;"), "Console feedback was not delivered as escaped neural text")
	entity.take_integrity(10, "test impact")
	entry = log_module.logs[length(log_module.logs)]
	TEST_ASSERT(findtext(entry.plain, "90/100"), "An integrity event did not update neural feedback")
	var/datum/component/netrun_neural_feedback/feedback = entity.GetComponent(/datum/component/netrun_neural_feedback)
	qdel(entity.console)
	entity.console = null
	TEST_ASSERT(QDELETED(feedback), "Deleting a client leaked its neural feedback adapter")

/// Network notification payloads use an explicit UID, even when filenames collide.
/datum/unit_test/netrun_neural_selected_payload/Run()
	var/mob/living/carbon/human/user = allocate(/mob/living/carbon/human)
	var/datum/component/neural_interface/interface = user.LoadComponent(/datum/component/neural_interface)
	interface.AddSource("NETRUN_TEST")
	var/datum/component/netrun_neural_adapter/adapter = interface.GetComponent(/datum/component/netrun_neural_adapter)
	var/datum/component/netrun_node/node = adapter.endpoint.GetComponent(/datum/component/netrun_node)
	var/obj/item/netrun_deck/deck = allocate(/obj/item/netrun_deck)
	var/datum/netrun_file/selected = new("same.txt", NETRUN_FILE_TEXT, "<selected>")
	var/datum/netrun_file/decoy = new("same.txt", NETRUN_FILE_TEXT, "wrong file")
	deck.console.store_file(selected)
	deck.console.store_file(decoy)
	deck.console.selected_file_uid = selected.uid
	var/datum/netrun_command/notify = SSnetrun.get_command("neural_notify")
	TEST_ASSERT_NOTNULL(notify, "The neural notification command is not registered")
	notify.execute(node, deck.console)
	var/datum/neural_interface_module/logs/log_module = interface.modules["log"]
	var/datum/log_entry/entry = log_module.logs[length(log_module.logs)]
	TEST_ASSERT(findtext(entry.plain, "&lt;selected&gt;"), "The neural command ignored the selected UID or failed to escape text")
	deck.console.selected_file_uid = null
	var/count = length(log_module.logs)
	TEST_ASSERT_NULL(notify.execute(node, deck.console), "The neural command silently fell back to a different file")
	TEST_ASSERT_EQUAL(length(log_module.logs), count, "A failed notification wrote to the remote neural display")

/// A personal AI has its own client without receiving unrestricted station access.
/datum/unit_test/netrun_pai_client_permissions/Run()
	var/obj/item/paicard/card = allocate(/obj/item/paicard)
	var/mob/living/silicon/pai/pai = allocate(/mob/living/silicon/pai, card)
	card.setPersonality(pai)
	TEST_ASSERT_NOTNULL(pai.netrun_console, "The personal AI has no network client")
	TEST_ASSERT_NOTNULL(pai.network_action, "The personal AI has no network action")
	TEST_ASSERT_EQUAL(length(pai.netrun_console.user_access()), 0, "The personal AI client inherited unrestricted silicon access")
	TEST_ASSERT_EQUAL(length(netrun_mob_access(pai)), 0, "A personal AI using another terminal receives unrestricted silicon access")
	TEST_ASSERT_EQUAL(pai.netrun_owner_access(pai.netrun_console), NETRUN_ACCESS_ROOT, "The personal AI cannot administer its own endpoint")
	TEST_ASSERT_NOTNULL(pai.GetComponent(/datum/component/netrun_node), "The personal AI cannot be addressed through the network")
