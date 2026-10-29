/// Useful archives are prepared once per physical server, after authored preloads.
/// No population pass searches for servers or refills an emptied disk.
/datum/controller/subsystem/netrun
	var/server_content_enabled = NETRUN_AUTONOMOUS_CONTENT

/atom/proc/netrun_server_content_profile()
	if(istype(src, /obj/machinery/netrun_server/stash))
		return "stash"
	if(istype(src, /obj/machinery/netrun_server))
		return "data"
	if(istype(src, /obj/machinery/rnd/server))
		return "research"
	if(istype(src, /obj/machinery/telecomms/server))
		return "telecomms"
	return null

/// Node registration calls this once; the component survives replacement of its node.
/atom/proc/ensure_netrun_server_content(datum/component/netrun_node/node)
	if(!SSnetrun.server_content_enabled || node?.node_type != NETRUN_NODE_SERVER)
		return
	var/profile = netrun_server_content_profile()
	if(!profile)
		return
	var/datum/component/netrun_server_archive/archive = LoadComponent(/datum/component/netrun_server_archive, profile)
	if(!archive.seeded)
		SSnetrun.get_task_scheduler().enqueue("server.content", archive, NETRUN_TASK_BACKGROUND)

/datum/component/netrun_server_archive
	/// Disk deletion and node replacement do not create another set of rewards.
	var/seeded = FALSE
	var/profile
	var/inserted = 0

/datum/component/netrun_server_archive/Initialize(profile)
	if(!isatom(parent))
		return COMPONENT_INCOMPATIBLE
	src.profile = profile

/datum/component/netrun_server_archive/Destroy()
	SSnetrun.task_scheduler?.cancel("server.content", src)
	return ..()

/datum/component/netrun_server_archive/proc/seed()
	if(seeded || QDELETED(parent))
		return FALSE
	var/atom/host = parent
	var/datum/component/netrun_node/node = host.GetComponent(/datum/component/netrun_node)
	if(QDELETED(node) || node.node_type != NETRUN_NODE_SERVER || QDELETED(node.file_store))
		return FALSE
	// Commit before modifying storage: storage signals cannot start a second seed.
	seeded = TRUE
	var/list/programs = list("patch" = 3, "barrier" = 2, "strike" = 1)
	var/list/daemons = list("buffer" = 3, "extend" = 2, "scrub" = 2)
	switch(profile)
		if("research")
			programs = list("patch" = 4, "barrier" = 2)
			daemons = list("buffer" = 3, "extend" = 2, "icepick" = 1)
		if("telecomms")
			programs = list("barrier" = 3, "patch" = 2)
			daemons = list("mapper" = 3, "scrub" = 2, "overclock" = 1)
		if("stash")
			programs = list("barrier" = 2, "patch" = 2, "strike" = 2)
			daemons = list("icepick" = 2, "cloak" = 2, "mapper" = 2, "scrub" = 1)
	insert_from_pool(node.file_store, NETRUN_FILE_PROGRAM, programs)
	insert_from_pool(node.file_store, NETRUN_FILE_DAEMON, daemons)
	// Advanced tools stay behind an authored hardened archive or an existing vault.
	// This adds files, never access, security overrides or an automatically built fortress.
	if((profile == "stash" && node.base_security >= 4) || node.fortress?.intact_count(NETRUN_FORT_VAULT))
		insert_from_pool(node.file_store, NETRUN_FILE_DAEMON, list("ghostlink" = 3, "analyst" = 2, "breachkit" = 1))
	return TRUE

/// Each category contributes at most one file; authored copies are never duplicated.
/datum/component/netrun_server_archive/proc/insert_from_pool(datum/netrun_file_store/store, kind, list/pool)
	for(var/datum/netrun_file/existing as anything in store.files)
		if(existing.kind == kind)
			pool -= existing.content
	while(length(pool))
		var/id = pickweight(pool)
		pool -= id
		var/datum/netrun_file/file = kind == NETRUN_FILE_PROGRAM ? netrun_program_file(id) : netrun_daemon_file(id)
		if(QDELETED(file))
			continue
		if(store.insert(file))
			inserted++
			return TRUE
		qdel(file)
	return FALSE

/datum/netrun_task/server_content
	kind = "server.content"

/datum/netrun_task/server_content/execute(datum/controller/subsystem/netrun/worker, datum/netrun_execution_limits/limits)
	var/datum/component/netrun_server_archive/archive = target()
	return !QDELETED(archive) && archive.seed()
