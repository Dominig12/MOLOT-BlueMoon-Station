/// A failed disk transaction retains the source; a successful move has one owner and one UID.
/datum/unit_test/netrun_machine_manuals/Run()
	var/obj/item/endpoint = allocate(/obj/item)
	var/datum/component/netrun_node/node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_CAMERA, list("scan", "ping"), 1, list(), 2)
	var/datum/netrun_file/manual
	for(var/datum/netrun_file/file as anything in node.file_store?.files)
		if(file.name == "readme.txt")
			manual = file
	TEST_ASSERT_NOTNULL(manual, "Every machine node must expose an in-world readme.txt")
	TEST_ASSERT_EQUAL(manual.kind, NETRUN_FILE_TEXT, "The built-in manual must be readable text")
	TEST_ASSERT(findtext(manual.content, "камер") && findtext(manual.content, "APC") && findtext(manual.content, "ПОЛЬЗОВАТЕЛЬ"), "The manual must explain this machine's role, routing and legitimate access")
	TEST_ASSERT(findtext(manual.content, "scan") && findtext(manual.content, "ping"), "The manual must enumerate commands the node actually supports")
	TEST_ASSERT_EQUAL(node.file_store.used(), 0, "Built-in documentation must not consume payload disk space")
	TEST_ASSERT_EQUAL(node.file_store.capacity, 2, "Documentation must preserve the machine's original writable capacity")
	var/datum/netrun_file/full = new("user.txt", NETRUN_FILE_TEXT, "payload", 2)
	TEST_ASSERT(node.file_store.insert(full), "The entire original payload capacity must remain writable")
	var/datum/netrun_file/copy = manual.copy()
	TEST_ASSERT(copy.size > 0, "A downloaded manual must consume ordinary destination capacity")
	qdel(copy)

/datum/unit_test/netrun_zero_capacity_manual/Run()
	var/obj/item/endpoint = allocate(/obj/item)
	var/datum/component/netrun_node/node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_ATMOS)
	TEST_ASSERT_NOTNULL(node.file_store, "Storage-less nodes still need their built-in documentation")
	TEST_ASSERT_EQUAL(node.file_store.capacity, 0, "Documentation must not grant a new writable disk")
	TEST_ASSERT_EQUAL(length(node.file_store.files), 1, "A storage-less endpoint must contain only its manual")
	var/datum/netrun_file/manual = node.file_store.files[1]
	TEST_ASSERT_EQUAL(manual.name, "readme.txt", "The built-in manual needs the expected filename")
	TEST_ASSERT(findtext(manual.content, "атмос"), "An atmospheric endpoint needs its own usage instructions")

/datum/unit_test/netrun_manual_live_contracts/Run()
	var/obj/item/netrun_provider_test/endpoint = allocate(/obj/item/netrun_provider_test)
	var/datum/component/netrun_node/node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_file/manual = node.file_store.files[1]
	node.command_ids |= "pc_shutdown"
	var/datum/netrun_file/download = manual.copy()
	TEST_ASSERT(findtext(download.content, "pc_shutdown"), "Reading a manual must reflect commands installed after node registration")
	TEST_ASSERT(findtext(download.content, "ProviderTest") && findtext(download.content, "write") && findtext(download.content, "value"), "Provider instructions must include the real interface, actions and parameters")
	TEST_ASSERT(download.size > 0, "A manual copy must be an ordinary charged text file")
	qdel(download)
	qdel(manual)
	node.file_store.files.Cut()
	var/datum/netrun_file/user_readme = new("readme.txt", NETRUN_FILE_TEXT, "User-authored instructions")
	node.file_store.insert(user_readme, TRUE)
	endpoint.ensure_netrun_manual(node)
	TEST_ASSERT_EQUAL(length(node.file_store.files), 1, "Repeated provisioning must not duplicate an existing readme")
	TEST_ASSERT_EQUAL(node.file_store.files[1], user_readme, "Manual provisioning must preserve the actual existing user file")
	TEST_ASSERT_EQUAL(user_readme.content, "User-authored instructions", "Manual provisioning must not overwrite user content")

/datum/unit_test/netrun_manual_provider_coverage/Run()
	var/covered = 0
	for(var/datum/netrun_provider/path as anything in subtypesof(/datum/netrun_provider))
		if(!initial(path.atom_type))
			continue
		var/datum/netrun_provider/provider = allocate(path)
		var/text = jointext(provider.manual_instructions(), "\n")
		for(var/action in provider.actions)
			TEST_ASSERT(findtext(text, action), "Provider [path] omitted its real action [action] from documentation")
			var/list/schema = provider.actions[action]
			for(var/list/parameter as anything in schema["params"])
				TEST_ASSERT(findtext(text, parameter["id"]), "Provider [path] omitted an actual action parameter")
		covered++
	TEST_ASSERT(covered >= 7, "Documentation coverage must include all published native interfaces")

/datum/unit_test/netrun_manual_preload_notes/Run()
	var/obj/machinery/netrun_server/stash/breach_suite/archive = allocate(/obj/machinery/netrun_server/stash/breach_suite)
	var/datum/component/netrun_node/node = archive.GetComponent(/datum/component/netrun_node)
	var/count = 0
	for(var/datum/netrun_file/file as anything in node.file_store.files)
		if(file.name != "readme.txt")
			continue
		count++
		TEST_ASSERT(findtext(file.content, archive.preload_files["readme.txt"]), "The built-in manual must preserve the exact authored archive notes")
		TEST_ASSERT(findtext(file.content, "APC"), "Archive notes must remain alongside real network instructions")
	TEST_ASSERT_EQUAL(count, 1, "A predefined readme must not create ambiguous duplicate filenames")

/// The existing node-independent terminal help must not resolve to a machine hook.
/datum/unit_test/netrun_terminal_manual_contract/Run()
	var/obj/machinery/computer/netrun_terminal/terminal = allocate(/obj/machinery/computer/netrun_terminal, run_loc_floor_bottom_left)
	var/datum/netrun_file/local_manual
	for(var/datum/netrun_file/file as anything in terminal.console.inventory.local_store.files)
		if(file.name == "readme.txt")
			local_manual = file
	TEST_ASSERT_NOTNULL(local_manual, "The terminal must retain its local general-purpose user guide")
	TEST_ASSERT(findtext(local_manual.content, "СЕТЕВОЙ ТЕРМИНАЛ") && findtext(local_manual.content, "Командная строка"), "Terminal initialization must call the original node-independent guide")
	var/datum/component/netrun_node/node = terminal.GetComponent(/datum/component/netrun_node)
	TEST_ASSERT_NOTNULL(node.file_store, "Terminal initialization must separately provision its machine-node guide")
	var/datum/netrun_file/node_manual = node.file_store.files[1]
	TEST_ASSERT(node_manual != local_manual && findtext(node_manual.content, "КОМАНДЫ ЭТОГО УЗЛА"), "The machine guide and the local terminal user guide must have separate ownership and contracts")

/// A free firmware source still produces a charged copy through the generic disk transaction.
/datum/unit_test/netrun_manual_copy_capacity/Run()
	var/obj/item/endpoint = allocate(/obj/item)
	var/datum/component/netrun_node/node = endpoint.AddComponent(/datum/component/netrun_node, NETRUN_NODE_CAMERA)
	var/datum/netrun_file/manual = node.file_store.files[1]
	var/datum/netrun_file_store/destination = allocate(/datum/netrun_file_store, null, 0)
	var/source_revision = node.file_store.revision
	TEST_ASSERT_NULL(node.file_store.transfer_to(destination, manual), "An ordinary manual copy must not bypass a zero-capacity destination")
	TEST_ASSERT_EQUAL(length(destination.files), 0, "A rejected manual copy must not overfill its destination")
	TEST_ASSERT(manual in node.file_store.files, "A rejected copy must preserve the firmware source")
	TEST_ASSERT_EQUAL(node.file_store.revision, source_revision, "A rejected copy must leave source storage unchanged")
	destination.capacity = netrun_text_size(manual.content)
	var/datum/netrun_file/copy = node.file_store.transfer_to(destination, manual)
	TEST_ASSERT_NOTNULL(copy, "The same ordinary copy must fit when the destination has enough payload capacity")
	TEST_ASSERT(copy.size > 0 && destination.used() == copy.size, "The destination must charge the ordinary copy's complete size")

/// The upload boundary must report the actual insert outcome for a charged copy.
/datum/unit_test/netrun_manual_upload_capacity/Run()
	var/datum/netrun_entity_contact_scene/scene = allocate(/datum/netrun_entity_contact_scene, run_loc_floor_bottom_left)
	scene.authorize()
	scene.console.access_session.node_access[scene.target_node.address] = NETRUN_ACCESS_USER
	var/datum/netrun_file/manual = scene.source_node.file_store.files[1]
	TEST_ASSERT(scene.source_node.file_store.remove(manual), "The fixture must transfer actual ownership of a firmware file")
	TEST_ASSERT(scene.console.inventory.local_store.insert(manual), "The sender must actually own the file before upload")
	var/baseline_files = length(scene.target_node.file_store.files)
	TEST_ASSERT(!scene.console.transfer_to_node(manual.uid, scene.target_node, TRUE), "A rejected charged copy must not report a completed upload")
	TEST_ASSERT_EQUAL(length(scene.target_node.file_store.files), baseline_files, "The rejected upload must leave the zero-capacity receiver unchanged")
	TEST_ASSERT(manual in scene.console.inventory.local_store.files, "The failed upload must retain the original sender-owned file")

/datum/unit_test/netrun_file_store_transaction/Run()
	var/datum/netrun_file_store/source = allocate(/datum/netrun_file_store, null, 2)
	var/datum/netrun_file_store/destination = allocate(/datum/netrun_file_store, null, 1)
	var/datum/netrun_file/file = new("owned.txt", NETRUN_FILE_TEXT, "original", 2)
	TEST_ASSERT(source.insert(file), "A file must fit exactly into its source disk")
	var/uid = file.uid
	var/revision = source.revision
	TEST_ASSERT_NULL(source.transfer_to(destination, file, TRUE), "A move must reject an undersized destination")
	TEST_ASSERT((file in source.files) && !(file in destination.files), "Failure must retain the only owner")
	TEST_ASSERT_EQUAL(source.revision, revision, "A rejected transaction must not publish a disk change")
	destination.capacity = 2
	TEST_ASSERT_EQUAL(source.transfer_to(destination, file, TRUE), file, "A move must transfer the original datum")
	TEST_ASSERT(!(file in source.files) && (file in destination.files), "Success must transfer ownership exactly once")
	TEST_ASSERT_EQUAL(file.uid, uid, "Moving between disks must preserve the immutable UID")
	TEST_ASSERT_EQUAL(source.used(), 0, "The source must release its capacity")
	TEST_ASSERT_EQUAL(destination.used(), 2, "The destination must charge the full file size")

/// A session owns its memory, while a removable disk survives session destruction.
/datum/unit_test/netrun_inventory_borrowed_disk/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/obj/item/netrun_shard/shard = allocate(/obj/item/netrun_shard)
	shard.forceMove(host)
	console.inventory.set_shard(shard)
	var/datum/netrun_file/file = new("persistent.txt", NETRUN_FILE_TEXT, "disk")
	TEST_ASSERT(console.store_file(file, TRUE), "A session must write through to the borrowed disk")
	qdel(console)
	TEST_ASSERT(!QDELETED(shard.file_store), "Destroying an inventory must preserve the disk's store")
	TEST_ASSERT(!QDELETED(file) && (file in shard.file_store.files), "Destroying a session must preserve borrowed files")

/// Physical removal invalidates the loadout without waiting for the next UI or subsystem tick.
/datum/unit_test/netrun_inventory_shard_lifecycle/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_network/network = allocate(/datum/netrun_network, "inventory-lifecycle")
	var/obj/item/netrun_shard/shard = allocate(/obj/item/netrun_shard)
	shard.forceMove(host)
	console.inventory.set_shard(shard)
	var/datum/netrun_file/key = new("lan.key", NETRUN_FILE_KEY, network.passcode, 1, network.id)
	TEST_ASSERT(console.store_file(key, TRUE), "The borrowed disk must accept the network key")
	console.inventory.selected_file_uid = key.uid
	TEST_ASSERT(console.inventory.has_key(network), "Attached disk keys must be available to the session")
	shard.forceMove(run_loc_floor_bottom_left)
	TEST_ASSERT_NULL(console.inventory.shard, "Physical removal must detach the disk immediately")
	TEST_ASSERT_NULL(console.inventory.selected_file_uid, "Removing a disk must clear a selected file it owned")
	TEST_ASSERT(!console.inventory.has_key(network), "Physical removal must revoke the borrowed key immediately")
	TEST_ASSERT(key in shard.file_store.files, "Detachment must leave the physical disk and its files intact")
	shard.forceMove(host)
	console.inventory.set_shard(shard)
	qdel(shard)
	TEST_ASSERT_NULL(console.inventory.shard, "Deleting an attached disk must clear the borrowed reference")

/// Neural immersion uses the implant's actual owned disk, not two diverging copies.
/datum/unit_test/netrun_dive_shared_inventory_roundtrip/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/implant = scene.implant.console
	var/obj/item/clothing/under/color/grey/uniform = allocate(/obj/item/clothing/under/color/grey)
	var/obj/item/card/id/card = allocate(/obj/item/card/id)
	card.access = list(ACCESS_MEDICAL)
	TEST_ASSERT(scene.user.equip_to_slot_if_possible(uniform, ITEM_SLOT_ICLOTHING, disable_warning = TRUE), "The diver must wear a real uniform")
	TEST_ASSERT(scene.user.equip_to_slot_if_possible(card, ITEM_SLOT_ID, disable_warning = TRUE), "The diver must wear a real ID")
	var/datum/netrun_file/original = new("original.txt", NETRUN_FILE_TEXT, "original", 1)
	var/datum/netrun_file/deleted = new("deleted.txt", NETRUN_FILE_TEXT, "delete me", 1)
	TEST_ASSERT(implant.store_file(original) && implant.store_file(deleted), "The implant must initially own both local files")
	var/obj/item/netrun_shard/shard = allocate(/obj/item/netrun_shard)
	shard.forceMove(scene.implant)
	implant.inventory.set_shard(shard)
	var/datum/netrun_file/access/credentials = new("shard.access", list(ACCESS_RD))
	TEST_ASSERT(implant.store_file(credentials, TRUE), "The installed shard must contain real credentials")
	scene.authorize()
	TEST_ASSERT(scene.implant.complete_dive(scene.target_node, scene.user), "The authorized owner must enter the network")
	var/mob/camera/netrun_entity/entity = implant.dive_ref?.resolve()
	var/datum/netrun_inventory/inventory = entity.console.inventory
	TEST_ASSERT_EQUAL(inventory.local_store, implant.inventory.local_store, "The physical implant must remain the sole owner of the shared local disk")
	TEST_ASSERT_EQUAL(inventory.find_file(original.uid), original, "Entry must preserve the original local file and UID")
	TEST_ASSERT_EQUAL(inventory.find_file(credentials.uid), credentials, "An inserted shard must be available to the resident without copying")
	TEST_ASSERT((ACCESS_MEDICAL in entity.console.user_access(TRUE)) && (ACCESS_RD in entity.console.user_access(TRUE)), "The resident must receive the body's live ID and the shard credentials")
	var/obj/item/protected = allocate(/obj/item)
	protected.req_access = list(ACCESS_MEDICAL)
	TEST_ASSERT(protected.allowed(entity), "Native ID checks must accept the actual body's worn ID")
	entity.console.eject_shard(entity)
	TEST_ASSERT_EQUAL(shard.loc, scene.implant, "A process cannot teleport a shard out of the unconscious body's implant")
	TEST_ASSERT_EQUAL(inventory.shard, shard, "A rejected remote eject must leave the physical shard attached")
	TEST_ASSERT(inventory.delete_file(deleted), "Deleting in the dive must affect the original implant disk")
	var/datum/netrun_file/downloaded = new("downloaded.txt", NETRUN_FILE_TEXT, "download", 5)
	TEST_ASSERT(inventory.store_file(downloaded), "A file downloaded in the dive must fit the actual implant capacity")
	var/datum/netrun_file/overflow = new("overflow.txt", NETRUN_FILE_TEXT, "overflow", 1)
	TEST_ASSERT(!inventory.store_file(overflow), "The resident must not gain extra capacity that would lose files on return")
	qdel(overflow)
	TEST_ASSERT(scene.user.dropItemToGround(card), "The body's ID must be removable during immersion")
	TEST_ASSERT(!(ACCESS_MEDICAL in entity.console.user_access(TRUE)), "Removing the physical ID must revoke its access immediately")
	TEST_ASSERT(!protected.allowed(entity), "Native ID checks must also reject an ID removed from the body")
	shard.forceMove(scene.far_spot)
	TEST_ASSERT_NULL(inventory.shard, "Physical shard removal must detach it from the active resident")
	TEST_ASSERT_NULL(inventory.find_file(credentials.uid), "A removed shard must immediately revoke its resident files")
	TEST_ASSERT(credentials in shard.file_store.files, "Shard removal must leave its only owned file intact")
	entity.console.access_session.node_access[scene.target_node.address] = NETRUN_ACCESS_ROOT
	entity.console.access_session.network_access[scene.target_node.network.id] = NETRUN_ACCESS_ROOT
	entity.console.learn_server_password(scene.target_node.address)
	entity.return_to_body()
	TEST_ASSERT_EQUAL(implant.inventory.find_file(original.uid), original, "Returning must retain the same original file")
	TEST_ASSERT_EQUAL(implant.inventory.find_file(downloaded.uid), downloaded, "Returning must preserve downloaded data and its UID")
	TEST_ASSERT(QDELETED(deleted), "A file deleted in the dive must never be resurrected")
	TEST_ASSERT_EQUAL(implant.access_session.node_access[scene.target_node.address], NETRUN_ACCESS_ROOT, "Acquired resident privileges must return to the implant")
	TEST_ASSERT_EQUAL(implant.access_session.network_access[scene.target_node.network.id], NETRUN_ACCESS_ROOT, "Acquired resident network access must return to the implant")
	TEST_ASSERT(implant.knows_server_password(scene.target_node.address), "Server credentials learned in the dive must survive return")
	TEST_ASSERT(!QDELETED(shard.file_store) && !QDELETED(credentials), "Returning must not delete a physically detached shard")

/// A queued firewall reset must not be undone by merging the two access sessions.
/datum/unit_test/netrun_dive_access_firewall_return/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/implant = scene.implant.console
	scene.authorize()
	implant.access_session.node_access[scene.target_node.address] = NETRUN_ACCESS_ROOT
	TEST_ASSERT(scene.implant.complete_dive(scene.target_node, scene.user), "The firewall fixture must enter the network")
	var/mob/camera/netrun_entity/entity = implant.dive_ref?.resolve()
	TEST_ASSERT_EQUAL(entity.console.access_session.node_access[scene.target_node.address], NETRUN_ACCESS_ROOT, "Previously acquired node access must be transferred into the dive")
	scene.target_node.raise_firewall()
	entity.return_to_body()
	TEST_ASSERT(!implant.access_session.node_access[scene.target_node.address], "Returning must process both sessions' queued firewall reset before merging")

/// Emergency return must preserve local files; later implant deletion owns them exactly once.
/datum/unit_test/netrun_dive_inventory_emergency_and_deletion/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/implant = scene.implant.console
	var/datum/netrun_file/original = new("persistent.txt", NETRUN_FILE_TEXT, "data", 1)
	TEST_ASSERT(implant.store_file(original), "The implant must own its local file")
	scene.authorize()
	TEST_ASSERT(implant.connection.connect_node(scene.target_node, scene.user), "The fixture must use a real cable")
	TEST_ASSERT(scene.implant.complete_dive(scene.target_node, scene.user), "The owner must enter before emergency disconnection")
	var/mob/camera/netrun_entity/entity = implant.dive_ref?.resolve()
	var/datum/netrun_file/downloaded = new("emergency.txt", NETRUN_FILE_TEXT, "download", 1)
	TEST_ASSERT(entity.console.store_file(downloaded), "The resident must write through to the implant")
	implant.set_jack(null)
	TEST_ASSERT(QDELETED(entity), "Disconnecting the cable must immediately terminate the resident")
	TEST_ASSERT_EQUAL(implant.inventory.find_file(original.uid), original, "Emergency return must preserve existing implant data")
	TEST_ASSERT_EQUAL(implant.inventory.find_file(downloaded.uid), downloaded, "Emergency return must preserve newly downloaded data")
	qdel(scene.implant)
	TEST_ASSERT(QDELETED(original) && QDELETED(downloaded), "The implant remains the sole owner and deletes its files once on destruction")

/// Destroying the implant during immersion returns the mind before its sole-owned disk is deleted.
/datum/unit_test/netrun_dive_inventory_implant_deleted_in_dive/Run()
	var/datum/netrun_client_scene/scene = allocate(/datum/netrun_client_scene, run_loc_floor_bottom_left)
	var/datum/netrun_console/implant/implant = scene.implant.console
	var/datum/netrun_file/file = new("owned.txt", NETRUN_FILE_TEXT, "data", 1)
	TEST_ASSERT(implant.store_file(file), "The physical implant must own the fixture file")
	scene.authorize()
	TEST_ASSERT(scene.implant.complete_dive(scene.target_node, scene.user), "The owner must enter the network")
	var/mob/camera/netrun_entity/entity = implant.dive_ref?.resolve()
	var/datum/mind/mind = entity.mind
	qdel(scene.implant)
	TEST_ASSERT(QDELETED(entity), "Deleting the implant must immediately remove its resident")
	TEST_ASSERT_EQUAL(mind.current, scene.user, "Deleting the implant must return the mind to the body")
	TEST_ASSERT(QDELETED(file), "Only the destroyed implant must delete its owned file")

/// A dive listens to residency signals and releases every body reference when detached.
/datum/unit_test/netrun_dive_link_lifecycle/Run()
	var/turf/origin = run_loc_floor_bottom_left
	var/datum/netrun_route_scene/scene = allocate(/datum/netrun_route_scene, origin.z)
	var/obj/machinery/computer/netrun_terminal/first = scene.machine(/obj/machinery/computer/netrun_terminal, origin)
	var/obj/machinery/computer/netrun_terminal/second = scene.machine(/obj/machinery/computer/netrun_terminal, get_step(origin, EAST))
	var/datum/component/netrun_node/entry = first.GetComponent(/datum/component/netrun_node)
	var/datum/component/netrun_node/next = second.GetComponent(/datum/component/netrun_node)
	var/mob/camera/netrun_entity/entity = allocate(/mob/camera/netrun_entity, origin, entry)
	var/mob/living/carbon/human/body = allocate(/mob/living/carbon/human, origin)
	TEST_ASSERT(entity.dive_link.attach(body, entry), "A dive must attach an existing body and entry node")
	entity.enter_node(next)
	TEST_ASSERT_EQUAL(entity.dive_link.route_chain.len, 2, "Residency signals must append a visited node to the dive route")
	entity.enter_node(entry)
	TEST_ASSERT_EQUAL(entity.dive_link.route_chain.len, 1, "Returning to a visited node must trim the route loop")
	entity.release_body()
	TEST_ASSERT_NULL(entity.dive_link.body, "Releasing the dive must clear the body reference")
	TEST_ASSERT_NULL(entity.dive_link.entry_address, "Releasing the dive must clear the return endpoint")
	TEST_ASSERT_EQUAL(entity.dive_link.route_chain.len, 0, "Releasing the dive must discard its route")
	qdel(body)
	TEST_ASSERT(!QDELETED(entity), "Deleting a previously released body must not destroy a resident process")

/// A delayed packet cannot retain its destroyed endpoint or a timer after cancellation.
/datum/unit_test/netrun_request_dependency_lifecycle/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/component/netrun_node/node = host.AddComponent(/datum/component/netrun_node, NETRUN_NODE_TERMINAL)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_command/command = SSnetrun.get_command("scan")
	var/datum/netrun_request/command/packet = new(console, node, command, "scan", node.network, null, "none")
	TEST_ASSERT(packet.send(30 SECONDS), "A valid endpoint must accept a delayed packet")
	TEST_ASSERT_NOTNULL(packet.timer_id, "A delayed packet must own a cancellable timer")
	qdel(node)
	TEST_ASSERT(QDELETED(packet), "Deleting a delivery dependency must cancel and delete its pending packet")
	TEST_ASSERT_NULL(packet.timer_id, "Cancelling a packet must release its timer")
	TEST_ASSERT(!QDELETED(console), "Cancelling one packet must not destroy the session")

/// A serialized file list describes a past frame; it cannot authorize current execution.
/datum/unit_test/netrun_inventory_ui_snapshot_isolation/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	var/datum/netrun_network/network = allocate(/datum/netrun_network, "inventory-snapshot")
	var/obj/item/netrun_shard/shard = allocate(/obj/item/netrun_shard)
	shard.forceMove(host)
	console.inventory.set_shard(shard)
	var/datum/netrun_file/program = netrun_daemon_file("autobreach")
	var/datum/netrun_file/key = new("snapshot.key", NETRUN_FILE_KEY, network.passcode, 1, network.id)
	var/datum/netrun_file/access/credentials = new("snapshot.access", list(ACCESS_MEDICAL))
	TEST_ASSERT(console.store_file(program, TRUE) && console.store_file(key, TRUE) && console.store_file(credentials, TRUE), "The removable disk must hold the loadout used by the snapshot")
	var/list/serialized_files = console.all_files(TRUE)
	console.ui_files = serialized_files
	TEST_ASSERT(islist(console.all_files()), "A cached inventory read must return its file list rather than a truth value")
	TEST_ASSERT_EQUAL(console.find_local_file(program.uid), program, "An attached file must be resolvable through the execution facade")
	console.inventory.set_shard(null)
	// Simulate a yielded UI serializer still retaining its earlier file array.
	console.ui_files = serialized_files
	TEST_ASSERT(program in serialized_files, "The old presentation snapshot must still exist when revocation is tested")
	TEST_ASSERT_NULL(console.find_local_file(program.uid), "An old snapshot must not make a detached program an executable local file")
	TEST_ASSERT(!(program in console.all_files(TRUE)), "An explicitly fresh file read must bypass the retained UI snapshot")
	TEST_ASSERT(!console.has_key(network, TRUE), "An old snapshot must not preserve a detached network key")
	TEST_ASSERT(!(ACCESS_MEDICAL in console.credential_access(TRUE)), "An old snapshot must not preserve detached ID credentials")
	TEST_ASSERT_EQUAL(console.daemon_bonus("autobreach"), 0, "An old snapshot must not keep a detached passive executable installed")
	console.ui_files = null
