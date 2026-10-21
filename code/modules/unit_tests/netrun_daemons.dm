/// A new program with an existing effect needs no factory or console switch.
/datum/netrun_daemon/unit_test_buffer
	id = "unit-test-buffer"
	name = "test-buffer.exe"
	size = 4
	bonus_kind = "buffer"
	bonus = 2
	loot_weight = 0

/datum/unit_test/netrun_daemon_registry/Run()
	var/datum/netrun_daemon/definition = SSnetrun.get_daemon("buffer")
	TEST_ASSERT_NOTNULL(definition, "The buffer daemon is not registered")
	TEST_ASSERT_EQUAL(SSnetrun.get_daemon(" BUFFER "), definition, "Daemon IDs are not normalized")
	TEST_ASSERT_NULL(SSnetrun.get_daemon("missing-daemon"), "An unknown ID resolved to a real program")
	TEST_ASSERT_NULL(netrun_daemon_file("missing-daemon"), "The factory created an unknown program")
	var/datum/netrun_file/file = netrun_daemon_file("buffer")
	TEST_ASSERT_EQUAL(file.content, "buffer", "The factory changed the existing file ID")
	TEST_ASSERT_EQUAL(file.size, 2, "The factory changed the existing file capacity cost")
	qdel(file)
	TEST_ASSERT(!QDELETED(definition), "A file incorrectly owns its shared daemon definition")
	var/obj/item/netrun_shard/buffer/buffer_shard = allocate(/obj/item/netrun_shard/buffer)
	var/obj/item/netrun_shard/icepick/icepick_shard = allocate(/obj/item/netrun_shard/icepick)
	var/obj/item/netrun_shard/cloak/cloak_shard = allocate(/obj/item/netrun_shard/cloak)
	for(var/obj/item/netrun_shard/shard in list(buffer_shard, icepick_shard, cloak_shard))
		TEST_ASSERT_EQUAL(length(shard.files), 1, "An individually printable daemon shard contains an unintended suite")
		TEST_ASSERT(netrun_storage_used(shard.files) <= shard.capacity, "A printed program exceeds its shard capacity")
	var/list/definitions = SSnetrun.daemon_definitions()
	var/found_extension = FALSE
	for(var/list/entry as anything in definitions)
		if(entry["id"] == "unit-test-buffer")
			found_extension = TRUE
	TEST_ASSERT(found_extension, "Help metadata ignored a newly added daemon subtype")

/datum/unit_test/netrun_daemon_capacity_and_effects/Run()
	var/obj/item/host = allocate(/obj/item)
	var/datum/netrun_console/console = allocate(/datum/netrun_console, host)
	console.storage_capacity = 4
	TEST_ASSERT(console.store_file(netrun_daemon_file("buffer")), "A daemon did not fit within available memory")
	TEST_ASSERT(console.store_file(netrun_daemon_file("buffer")), "A second copy did not fit exactly in memory")
	TEST_ASSERT_EQUAL(console.daemon_bonus("buffer"), 1, "Duplicate programs stacked their buffer effect")
	var/datum/netrun_file/excess = netrun_daemon_file("buffer")
	TEST_ASSERT(!console.store_file(excess), "A daemon bypassed memory capacity")
	qdel(excess)
	var/obj/item/netrun_shard/shard = allocate(/obj/item/netrun_shard)
	console.shard = shard
	shard.files += netrun_daemon_file("unit-test-buffer")
	TEST_ASSERT_EQUAL(console.daemon_bonus("buffer"), 2, "An analogous program's stronger effect was ignored or summed")
	shard.files += netrun_daemon_file("cloak")
	TEST_ASSERT(abs(console.effective_trace_mult() - 0.7) < 0.001, "The registry changed the existing cloak trace reduction")
	TEST_ASSERT_EQUAL(console.daemon_bonus("missing-effect"), 0, "An unknown effect received an unrelated daemon bonus")
