/// A disk owns its files. Inventories may borrow a removable disk, never its ownership.
/datum/netrun_file_store
	var/datum/weakref/owner_ref
	var/list/datum/netrun_file/files = list()
	var/capacity = 0
	var/revision = 0

/datum/netrun_file_store/New(datum/owner, capacity = 0)
	owner_ref = owner ? WEAKREF(owner) : null
	src.capacity = capacity

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
	var/obj/item/netrun_shard/shard
	var/selected_file_uid

/datum/netrun_inventory/New(datum/netrun_console/owner, capacity = 6)
	src.owner = owner
	local_store = new(src, capacity)
	RegisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_store_changed))

/datum/netrun_inventory/Destroy()
	set_shard(null)
	UnregisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED)
	QDEL_NULL(local_store)
	selected_file_uid = null
	owner = null
	return ..()

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
