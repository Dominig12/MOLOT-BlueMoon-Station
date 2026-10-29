/// A disk owns its files. Inventories may borrow a removable disk, never its ownership.
/datum/netrun_file_store
	var/datum/weakref/owner_ref
	var/list/datum/netrun_file/files = list()
	var/capacity = 8 * NETRUN_STORAGE_SCALE
	var/revision = 0

/datum/netrun_file_store/New(datum/owner, capacity = 8 * NETRUN_STORAGE_SCALE)
	owner_ref = owner ? WEAKREF(owner) : null
	src.capacity = capacity

/// Every addressable endpoint has writable memory. Explicit capacities (including
/// zero for read-only media) override these defaults and are already scaled.
/proc/netrun_node_storage_capacity(node_type)
	switch(node_type)
		if(NETRUN_NODE_AI)
			return 24 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_SERVER)
			return 16 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_TERMINAL)
			return 12 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_GATEWAY)
			return 8 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_APC)
			return 6 * NETRUN_STORAGE_SCALE
	return 4 * NETRUN_STORAGE_SCALE

/datum/netrun_file_store/Destroy()
	owner_ref = null
	QDEL_LIST(files)
	return ..()

/datum/netrun_file_store/proc/used()
	return netrun_storage_used(files)

/datum/netrun_file_store/proc/can_fit(datum/netrun_file/file)
	return !QDELETED(file) && used() + file.size <= capacity

/// Map preloads may intentionally exceed the writable capacity of a disk.
/datum/netrun_file_store/proc/insert(datum/netrun_file/file, preload = FALSE)
	if(QDELETED(file))
		return FALSE
	if(file in files)
		return TRUE
	if(!preload && !can_fit(file))
		return FALSE
	files += file
	notify_changed()
	return TRUE

/// Removing transfers ownership to the caller; deletion is an explicit operation.
/datum/netrun_file_store/proc/remove(datum/netrun_file/file)
	if(!(file in files))
		return FALSE
	files -= file
	notify_changed()
	return TRUE

/datum/netrun_file_store/proc/delete_file(datum/netrun_file/file)
	if(!remove(file))
		return FALSE
	qdel(file)
	return TRUE

/datum/netrun_file_store/proc/clear()
	if(!length(files))
		return
	QDEL_LIST(files)
	files = list()
	notify_changed()

/datum/netrun_file_store/proc/find_file(uid)
	for(var/datum/netrun_file/file as anything in files)
		if(file.uid == uid)
			return file

/// Check both disks before moving so a failed write never loses the original file.
/datum/netrun_file_store/proc/transfer_to(datum/netrun_file_store/destination, datum/netrun_file/file, move = FALSE)
	if(QDELETED(destination) || !(file in files) || (move && destination == src) || !destination.can_fit(file))
		return null
	var/datum/netrun_file/result = move ? file : file.copy()
	// A free firmware source produces an ordinary charged text copy that can grow.
	// Validate the actual owned result before changing either disk.
	if(!destination.can_fit(result))
		if(!move)
			qdel(result)
		return null
	if(move)
		files -= file
	destination.files += result
	if(move)
		notify_changed()
	destination.notify_changed()
	return result

/datum/netrun_file_store/proc/notify_changed()
	revision++
	SEND_SIGNAL(src, COMSIG_NETRUN_STORAGE_CHANGED, revision)

/// One session combines its owned memory with a borrowed removable disk.
/datum/netrun_inventory
	var/datum/netrun_console/owner
	var/datum/netrun_file_store/local_store
	/// A dive can borrow the implant disk without taking ownership of its files.
	var/datum/netrun_file_store/owned_store
	var/datum/weakref/borrowed_inventory_ref
	var/obj/item/netrun_shard/shard
	var/selected_file_uid

/datum/netrun_inventory/New(datum/netrun_console/owner, capacity = 6 * NETRUN_STORAGE_SCALE)
	src.owner = owner
	local_store = new(src, capacity)
	owned_store = local_store
	RegisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_store_changed))

/datum/netrun_inventory/Destroy()
	stop_borrowing()
	set_shard(null)
	UnregisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED)
	local_store = null
	QDEL_NULL(owned_store)
	selected_file_uid = null
	owner = null
	return ..()

/// The implant remains the sole owner; reads and writes use the same file datums.
/datum/netrun_inventory/proc/borrow_from(datum/netrun_inventory/source)
	if(QDELETED(source) || source == src || borrowed_inventory_ref)
		return FALSE
	UnregisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED)
	borrowed_inventory_ref = WEAKREF(source)
	local_store = source.local_store
	RegisterSignal(local_store, COMSIG_PARENT_QDELETING, PROC_REF(on_borrowed_source_deleted))
	RegisterSignal(source, COMSIG_NETRUN_INVENTORY_CHANGED, PROC_REF(on_borrowed_inventory_signal))
	RegisterSignal(source, COMSIG_PARENT_QDELETING, PROC_REF(on_borrowed_source_deleted))
	set_shard(source.shard)
	notify_changed()
	return TRUE

/datum/netrun_inventory/proc/stop_borrowing()
	if(!borrowed_inventory_ref)
		return
	var/datum/netrun_inventory/source = borrowed_inventory_ref.resolve()
	if(source)
		UnregisterSignal(source, list(COMSIG_NETRUN_INVENTORY_CHANGED, COMSIG_PARENT_QDELETING))
	if(local_store)
		UnregisterSignal(local_store, list(COMSIG_NETRUN_STORAGE_CHANGED, COMSIG_PARENT_QDELETING))
	borrowed_inventory_ref = null
	local_store = owned_store
	RegisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_store_changed))
	set_shard(null)
	notify_changed()

/datum/netrun_inventory/proc/on_borrowed_source_deleted(datum/source)
	SIGNAL_HANDLER
	stop_borrowing()

/datum/netrun_inventory/proc/on_borrowed_inventory_signal(datum/source)
	SIGNAL_HANDLER
	var/datum/netrun_inventory/inventory = source
	if(shard != inventory.shard)
		set_shard(inventory.shard)
	else
		notify_changed()

/datum/netrun_inventory/proc/all_files(fresh = FALSE)
	if(!fresh && owner?.ui_files)
		return owner.ui_files
	. = local_store.files.Copy()
	if(!QDELETED(shard))
		. += shard.file_store.files

/datum/netrun_inventory/proc/store_for(datum/netrun_file/file)
	RETURN_TYPE(/datum/netrun_file_store)
	if(file in local_store.files)
		return local_store
	if(!QDELETED(shard) && (file in shard.file_store.files))
		return shard.file_store

/datum/netrun_inventory/proc/find_file(uid)
	// Execution resolves actual disk membership, never a retained UI file list.
	var/datum/netrun_file/file = local_store.find_file(uid)
	if(file)
		return file
	return shard?.file_store.find_file(uid)

/datum/netrun_inventory/proc/store_file(datum/netrun_file/file, to_shard = FALSE)
	var/datum/netrun_file_store/destination = to_shard ? shard?.file_store : local_store
	return destination?.insert(file) || FALSE

/datum/netrun_inventory/proc/delete_file(datum/netrun_file/file)
	var/datum/netrun_file_store/source = store_for(file)
	return source?.delete_file(file) || FALSE

/// Explicit local import resolves the live physical disk, never a cached UI
/// entry. A failed copy/move preserves both the removable file and its UID.
/datum/netrun_inventory/proc/import_from_shard(uid, move = FALSE)
	RETURN_TYPE(/datum/netrun_file)
	if(QDELETED(shard) || QDELETED(shard.file_store) || QDELETED(local_store))
		return null
	var/datum/netrun_file/file = shard.file_store.find_file(uid)
	if(QDELETED(file))
		return null
	var/datum/netrun_file/imported = shard.file_store.transfer_to(local_store, file, move)
	if(imported)
		selected_file_uid = imported.uid
	return imported

/datum/netrun_inventory/proc/set_shard(obj/item/netrun_shard/new_shard)
	if(shard == new_shard)
		return
	if(shard)
		UnregisterSignal(shard, list(COMSIG_PARENT_QDELETING, COMSIG_MOVABLE_MOVED))
		if(shard.file_store)
			UnregisterSignal(shard.file_store, COMSIG_NETRUN_STORAGE_CHANGED)
	shard = QDELETED(new_shard) ? null : new_shard
	if(shard)
		RegisterSignal(shard, COMSIG_PARENT_QDELETING, PROC_REF(on_shard_deleted))
		RegisterSignal(shard, COMSIG_MOVABLE_MOVED, PROC_REF(on_shard_moved))
		RegisterSignal(shard.file_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_store_changed))
	notify_changed()

/datum/netrun_inventory/proc/on_shard_deleted(datum/source)
	SIGNAL_HANDLER
	set_shard(null)

/datum/netrun_inventory/proc/on_shard_moved(datum/source)
	SIGNAL_HANDLER
	if(shard?.loc != owner?.host)
		set_shard(null)

/datum/netrun_inventory/proc/on_store_changed(datum/source, revision)
	SIGNAL_HANDLER
	notify_changed()

/datum/netrun_inventory/proc/notify_changed()
	// A loadout change invalidates all derived authorization, including a UI
	// serialization that yielded while a shard was removed or a file was revoked.
	if(owner)
		owner.ui_files = null
		owner.access_cache = null
		owner.ui_keys?.Cut()
		owner.ui_bonuses?.Cut()
		owner.ui_node_levels?.Cut()
		owner.ui_legit_levels?.Cut()
		owner.network_level_cache?.Cut()
		owner.ui_completion_cache?.Cut()
	if(selected_file_uid && !find_file(selected_file_uid))
		selected_file_uid = null
	SEND_SIGNAL(src, COMSIG_NETRUN_INVENTORY_CHANGED)

/datum/netrun_inventory/proc/has_key(datum/netrun_network/network, fresh = FALSE)
	if(!network)
		return FALSE
	for(var/datum/netrun_file/file as anything in all_files(fresh))
		if(file.kind == NETRUN_FILE_KEY && file.network_id == network.id && file.content == network.passcode)
			return TRUE
	return FALSE

/// A loadout uses the strongest effect of each program kind, not the number of copies.
/datum/netrun_inventory/proc/daemon_bonus(id)
	. = 0
	// These effects participate in execution (trace, latency and breach); a
	// previously serialized file list cannot keep a removed program installed.
	for(var/datum/netrun_file/file as anything in all_files(TRUE))
		if(file.kind != NETRUN_FILE_DAEMON)
			continue
		var/datum/netrun_daemon/daemon = SSnetrun.get_daemon(file.content)
		if(daemon && daemon.bonus_kind == id)
			. = max(., daemon.bonus)
