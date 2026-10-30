/datum/antagonist/traitor/netrun_contract_fixture/on_removal()
	return

/datum/netrun_contract_scene
	parent_type = /datum/netrun_fortress_scene
	var/mob/living/carbon/human/user
	var/datum/netrun_console/client
	var/datum/antagonist/traitor/role
	var/obj/machinery/rnd/server/server
	var/datum/component/netrun_node/research_node
	var/obj/machinery/ntnet_relay/relay

/datum/netrun_contract_scene/New(turf/origin)
	..(origin)
	user = new(origin)
	owned += user
	user.mind_initialize()
	client = new(node_a.parent)
	owned += client
	client.operator = user
	client.inventory.local_store.capacity = 128
	role = new /datum/antagonist/traitor/netrun_contract_fixture
	role.owner = user.mind
	LAZYADD(user.mind.antag_datums, role)
	var/obj/item/holder = new(origin)
	owned += holder
	role.uplink = holder.AddComponent(/datum/component/uplink, user.mind.key, TRUE, FALSE, UPLINK_TRAITORS, 0)
	server = machine(/obj/machinery/rnd/server, get_turf(node_b.parent))
	server.netrun_mapped_server = TRUE
	server.network_id = RND_NETWORK_STATION
	server.stored_research.research_points = list(TECHWEB_POINT_TYPE_GENERIC = 20000)
	server.stored_research.researched_nodes = list("base" = TRUE, "datatheory" = TRUE, "engineering" = TRUE)
	research_node = netrun_find_node(server)
	relay = machine(/obj/machinery/ntnet_relay, origin)
	SSnetworks.station_network.setting_disabled = FALSE
	SSnetrun.ensure_topology()

/datum/netrun_contract_scene/Destroy()
	QDEL_NULL(role)
	return ..()

/// Re-export, rename, disk copies and plain forged text cannot replay a sale.
/datum/unit_test/netrun_contract_technology_novelty/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	TEST_ASSERT(scene.client.has_uplink(), "The broker uses a real operational relay")
	var/datum/netrun_command/export = SSnetrun.get_command("rnd_grab")
	export.execute(scene.research_node, scene.client)
	var/datum/netrun_file/file = scene.client.selected_local_file()
	TEST_ASSERT_NOTNULL(file.data_receipt, "An unauthorized station export receives an opaque receipt")
	var/datum/netrun_file/copy = file.copy()
	TEST_ASSERT(scene.client.store_file(copy), "The copied dump fits ordinary memory")
	TEST_ASSERT_EQUAL(copy.data_receipt, file.data_receipt, "All copies share the same receipt")
	scene.client.inventory.selected_file_uid = copy.uid
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 1, "Three genuine technologies pay one TC")
	scene.client.inventory.selected_file_uid = file.uid
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 1, "Selling the original after a copy cannot pay twice")
	export.execute(scene.research_node, scene.client)
	var/datum/netrun_file/reexported = scene.client.selected_local_file()
	reexported.name = "renamed.web"
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 1, "A fresh export of the same technologies is not novel")
	var/datum/netrun_file/forged = new("forged.web", NETRUN_FILE_TECHWEB, "base;datatheory;engineering", 1)
	scene.client.store_file(forged)
	scene.client.inventory.selected_file_uid = forged.uid
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 1, "Filenames and forged content are not proof of theft")
	var/datum/objective/netrun_exfiltrate/objective = allocate(/datum/objective/netrun_exfiltrate)
	objective.owner = scene.user.mind
	objective.configure("technology", 3)
	TEST_ASSERT(objective.check_completion(), "The actual seller's authenticated receipts complete the objective")
	objective.owner = allocate(/datum/mind)
	TEST_ASSERT(!objective.check_completion(), "Another mind cannot inherit the seller's objective receipts")

/// Points have one authoritative balance shared with rnd_restore; payouts have a round cap.
/datum/unit_test/netrun_contract_research_consumption/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/datum/netrun_command/siphon = SSnetrun.get_command("rnd_siphon")
	var/datum/netrun_command/restore = SSnetrun.get_command("rnd_restore")
	siphon.execute(scene.research_node, scene.client)
	var/datum/netrun_file/research_points/file = scene.client.selected_local_file()
	var/datum/netrun_file/research_points/copy = file.copy()
	scene.client.store_file(copy)
	scene.relay.enabled = FALSE
	scene.client.broker_sell()
	TEST_ASSERT(!file.data_receipt.redeemed && length(file.payload.points), "A lost uplink cannot spend a receipt or its point balance")
	scene.relay.enabled = TRUE
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 5, "The real stolen balance is credited to the traitor's native uplink")
	TEST_ASSERT(!length(file.payload.points), "Cashout consumes the same balance as research restoration")
	scene.client.inventory.selected_file_uid = copy.uid
	var/bank = scene.server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC]
	restore.execute(scene.research_node, scene.client)
	TEST_ASSERT_EQUAL(scene.server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC], bank, "A sold copy cannot also restore research points")
	scene.server.stored_research.research_points[TECHWEB_POINT_TYPE_GENERIC] = 40000
	siphon.execute(scene.research_node, scene.client)
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 6, "Repeated genuine point exports still respect the per-mind round cap")

/// Legal exports and private manufactured banks cannot farm station-theft rewards.
/datum/unit_test/netrun_contract_source_authority/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/datum/netrun_command/export = SSnetrun.get_command("rnd_grab")
	scene.server.netrun_mapped_server = FALSE
	export.execute(scene.research_node, scene.client)
	var/datum/netrun_file/private_dump = scene.client.selected_local_file()
	TEST_ASSERT_NULL(private_dump.data_receipt, "A privately built bank does not issue paid station-theft receipts")
	scene.server.netrun_mapped_server = TRUE
	scene.research_node.required_access = list()
	var/obj/item/card/id/card = allocate(/obj/item/card/id)
	card.access = list(ACCESS_NETWORK)
	var/obj/item/clothing/under/color/grey/uniform = allocate(/obj/item/clothing/under/color/grey)
	scene.user.equip_to_slot_if_possible(uniform, ITEM_SLOT_ICLOTHING)
	scene.user.equip_to_slot_if_possible(card, ITEM_SLOT_ID)
	scene.research_node.required_access = list(ACCESS_NETWORK)
	export.execute(scene.research_node, scene.client)
	var/datum/netrun_file/legal_dump = scene.client.selected_local_file()
	TEST_ASSERT_NULL(legal_dump.data_receipt, "Legally authorized exports cannot be sold as stolen data")

/// Only the exporting mind's live traitor role may spend a receipt.
/datum/unit_test/netrun_contract_role_revalidation/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/datum/netrun_command/export = SSnetrun.get_command("rnd_grab")
	export.execute(scene.research_node, scene.client)
	var/datum/netrun_file/file = scene.client.selected_local_file()
	scene.user.mind.antag_datums -= scene.role
	scene.client.broker_sell()
	TEST_ASSERT(!file.data_receipt.redeemed, "Losing the role preserves the data and rejects payment")
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 0, "A former traitor cannot credit the old uplink")
	scene.user.mind.antag_datums += scene.role
	var/mob/living/carbon/human/other = allocate(/mob/living/carbon/human, run_loc_floor_bottom_left)
	other.mind_initialize()
	scene.client.operator = other
	scene.client.broker_sell()
	TEST_ASSERT(!file.data_receipt.redeemed, "Changing the terminal operator does not transfer the receipt's issuer")

/datum/unit_test/netrun_contract_objective_eligibility/Run()
	var/list/previous_choices = GLOB.objective_choices
	populate_objective_choices()
	var/registered = GLOB.objective_choices["netrun data exfiltration"] == /datum/objective/netrun_exfiltrate
	GLOB.objective_choices = previous_choices
	TEST_ASSERT(registered, "The new objective is available in the native objective picker")
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/datum/traitor_class/human/class = GLOB.traitor_classes[TRAITOR_HUMAN]
	scene.role.should_equip = FALSE
	TEST_ASSERT(!class.try_forge_netrun_objective(scene.role), "Equipment-less special roles are not assigned a network equipment objective")
	scene.role.should_equip = TRUE
	TEST_ASSERT(class.try_forge_netrun_objective(scene.role), "A human traitor with a real station source can receive a network objective")
	var/datum/objective/netrun_exfiltrate/objective = locate() in scene.role.objectives
	allocated += objective
	TEST_ASSERT_NOTNULL(objective, "The forged objective is part of the existing traitor's objective list")
	TEST_ASSERT(length(objective.special_items_given), "The objective supplies the equipment needed before station research")
	var/obj/item/netrun_deck/contract/deck = objective.special_items_given[1]
	TEST_ASSERT(deck.console.daemon_capability("autobreach"), "The issued deck carries a real hacking executable")
	TEST_ASSERT(!class.try_forge_netrun_objective(scene.role), "A single traitor cannot accumulate duplicate network objectives")

/// Native card snapshots retain their receipt through copying and reject the operator's rights.
/datum/unit_test/netrun_contract_credentials/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/obj/item/modular_computer/laptop/computer = allocate(/obj/item/modular_computer/laptop, run_loc_floor_bottom_left)
	computer.enabled = TRUE
	var/obj/item/computer_hardware/card_slot/slot = computer.get_modular_computer_part(MC_CARD)
	if(!slot)
		slot = allocate(/obj/item/computer_hardware/card_slot)
		computer.install_component(slot)
	var/obj/item/card/id/card = allocate(/obj/item/card/id)
	card.access = list(ACCESS_MEDICAL, ACCESS_RD, ACCESS_SECURITY, ACCESS_CARGO, ACCESS_ENGINE)
	TEST_ASSERT(slot.try_insert(card), "The exported data comes from an actual inserted card")
	var/datum/component/netrun_node/node = netrun_find_node(computer)
	var/datum/netrun_command/export = SSnetrun.get_command("extract_credentials")
	export.execute(node, scene.client)
	var/datum/netrun_file/access/file = scene.client.selected_local_file()
	TEST_ASSERT_NOTNULL(file.data_receipt, "A real unauthorized credential snapshot carries its origin receipt")
	var/datum/netrun_file/access/copy = file.copy()
	scene.client.store_file(copy)
	TEST_ASSERT_EQUAL(copy.data_receipt, file.data_receipt, "Credential subtype copies preserve the same receipt")
	scene.client.inventory.selected_file_uid = copy.uid
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 1, "Five real novel access rights are rewarded")
	export.execute(node, scene.client)
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 1, "A newly exported copy of the same card cannot farm rewards")
	var/obj/item/clothing/under/color/grey/uniform = allocate(/obj/item/clothing/under/color/grey)
	var/obj/item/card/id/own_card = allocate(/obj/item/card/id)
	own_card.access = card.access.Copy()
	scene.user.equip_to_slot_if_possible(uniform, ITEM_SLOT_ICLOTHING)
	scene.user.equip_to_slot_if_possible(own_card, ITEM_SLOT_ID)
	export.execute(node, scene.client)
	file = scene.client.selected_local_file()
	TEST_ASSERT_NULL(file.data_receipt, "Rights already on the exporting operator's own ID are not stolen data")

/// Eligibility uses the same native authorization as export receipts, beyond job-name exclusions.
/datum/unit_test/netrun_contract_objective_legal_sources/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/obj/item/clothing/under/color/grey/uniform = allocate(/obj/item/clothing/under/color/grey)
	var/obj/item/card/id/card = allocate(/obj/item/card/id)
	card.access = list(ACCESS_CAPTAIN, ACCESS_RD, ACCESS_NETWORK)
	scene.user.equip_to_slot_if_possible(uniform, ITEM_SLOT_ICLOTHING)
	scene.user.equip_to_slot_if_possible(card, ITEM_SLOT_ID)
	scene.role.owner.assigned_role = "Captain"
	var/datum/traitor_class/human/class = GLOB.traitor_classes[TRAITOR_HUMAN]
	TEST_ASSERT(!class.try_forge_netrun_objective(scene.role), "A captain cannot receive a theft objective for exports already authorized by their native ID")

/// Removing, upgrading and renaming the original ID cannot launder it through a public laptop.
/datum/unit_test/netrun_contract_removed_own_id/Run()
	var/datum/netrun_contract_scene/scene = allocate(/datum/netrun_contract_scene, run_loc_floor_bottom_left)
	var/obj/item/clothing/under/color/grey/uniform = allocate(/obj/item/clothing/under/color/grey)
	var/obj/item/card/id/card = allocate(/obj/item/card/id)
	card.access = list(ACCESS_MEDICAL, ACCESS_RD, ACCESS_SECURITY, ACCESS_CARGO, ACCESS_ENGINE)
	card.registered_name = scene.user.real_name
	scene.user.equip_to_slot_if_possible(uniform, ITEM_SLOT_ICLOTHING)
	scene.user.equip_to_slot_if_possible(card, ITEM_SLOT_ID)
	var/datum/component/netrun_broker_account/account = scene.user.mind.LoadComponent(/datum/component/netrun_broker_account)
	TEST_ASSERT(account.owns_card(card), "The role captures the original physical card before the player can remove it")
	card.access |= list(ACCESS_TOX, ACCESS_ROBOTICS, ACCESS_CHEMISTRY, ACCESS_ENGINE_EQUIP, ACCESS_MAINT_TUNNELS)
	card.registered_name = "Renamed identity"
	TEST_ASSERT(scene.user.temporarilyRemoveItemFromInventory(card), "The owner can remove their real ID")
	card.forceMove(run_loc_floor_bottom_left)
	var/obj/item/modular_computer/laptop/computer = allocate(/obj/item/modular_computer/laptop, run_loc_floor_bottom_left)
	computer.enabled = TRUE
	var/obj/item/computer_hardware/card_slot/slot = computer.get_modular_computer_part(MC_CARD)
	if(!slot)
		slot = allocate(/obj/item/computer_hardware/card_slot)
		computer.install_component(slot)
	TEST_ASSERT(slot.try_insert(card), "The removed ID enters an external native card slot")
	TEST_ASSERT_EQUAL(length(scene.client.user_access(TRUE)), 0, "The current operator no longer carries those rights")
	var/datum/component/netrun_node/node = netrun_find_node(computer)
	var/datum/netrun_command/export = SSnetrun.get_command("extract_credentials")
	export.execute(node, scene.client)
	var/datum/netrun_file/access/file = scene.client.selected_local_file()
	TEST_ASSERT(istype(file) && length(file.accesses) == 10, "The data remains a usable ordinary snapshot of the real card")
	TEST_ASSERT_NULL(file.data_receipt, "The owner's removed, upgraded and renamed ID cannot issue a paid theft receipt")
	scene.client.broker_sell()
	TEST_ASSERT_EQUAL(scene.role.uplink.telecrystals, 0, "Laundering an owned ID earns no TC")
