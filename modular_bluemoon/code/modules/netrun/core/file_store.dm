/// A disk owns its files. Inventories may borrow a removable disk, never its ownership.
/datum/netrun_file_store
	var/datum/weakref/owner_ref
	var/list/datum/netrun_file/files = list()
	var/capacity = 8 * NETRUN_STORAGE_SCALE
	var/revision = 0
	/// Per-medium aggregation: a local disk and removable shard remain separate.
	var/canonical_grants_uid
	var/merging_grants = FALSE

/datum/netrun_file_store/New(datum/owner, capacity = 8 * NETRUN_STORAGE_SCALE)
	owner_ref = owner ? WEAKREF(owner) : null
	src.capacity = capacity

/// Every addressable endpoint has writable memory. Explicit capacities (including
/// zero for read-only media) override these defaults and are already scaled.
/proc/netrun_node_storage_capacity(node_type)
	switch(node_type)
		if(NETRUN_NODE_AI)
			return 48 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_SERVER)
			return 32 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_TERMINAL)
			return 24 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_GATEWAY)
			return 16 * NETRUN_STORAGE_SCALE
		if(NETRUN_NODE_APC)
			return 12 * NETRUN_STORAGE_SCALE
	return 8 * NETRUN_STORAGE_SCALE

/datum/netrun_file_store/Destroy()
	owner_ref = null
	QDEL_LIST(files)
	return ..()

/datum/netrun_file_store/proc/used()
	return netrun_storage_used(files)

/datum/netrun_file_store/proc/can_fit(datum/netrun_file/file)
	if(QDELETED(file) || !file.can_store(src))
		return FALSE
	var/used_size = used()
	if(capacity <= 0 || used_size > capacity)
		return FALSE
	if(istype(file, /datum/netrun_file/acquired_key) && ((file in files) || acquired_key_target(file)))
		return TRUE
	return used_size + file.size <= capacity

/// Map preloads may intentionally exceed the writable capacity of a disk.
/datum/netrun_file_store/proc/insert(datum/netrun_file/file, preload = FALSE)
	RETURN_TYPE(/datum/netrun_file)
	if(QDELETED(file) || !file.can_store(src))
		return null
	if(file in files)
		if(istype(file, /datum/netrun_file/acquired_key))
			consolidate_acquired_keys()
			return acquired_key_target()
		return file
	if(!preload && !can_fit(file))
		return null
	if(istype(file, /datum/netrun_file/acquired_key))
		var/datum/netrun_file/acquired_key/incoming = file
		var/datum/netrun_file/acquired_key/canonical = acquired_key_target(incoming)
		if(canonical)
			canonical.merge_from(incoming)
			var/datum/netrun_inventory/inventory = owner_ref?.resolve()
			if(istype(inventory) && inventory.selected_file_uid == incoming.uid)
				inventory.selected_file_uid = canonical.uid
			qdel(incoming)
			consolidate_acquired_keys(FALSE)
			notify_changed()
			return canonical
		canonical_grants_uid = incoming.uid
	files += file
	notify_changed()
	return file

/// Prefer the medium's stable survivor, then its owning inventory's tracked key.
/datum/netrun_file_store/proc/acquired_key_target(datum/netrun_file/exclude)
	RETURN_TYPE(/datum/netrun_file/acquired_key)
	var/datum/netrun_inventory/inventory = owner_ref?.resolve()
	var/preferred_uid = istype(inventory) ? inventory.canonical_key_uid : null
	var/datum/netrun_file/acquired_key/first
	var/datum/netrun_file/acquired_key/preferred
	for(var/datum/netrun_file/acquired_key/key as anything in files)
		if(!istype(key) || QDELETED(key) || key == exclude)
			continue
		if(key.uid == canonical_grants_uid)
			return key
		if(key.uid == preferred_uid)
			preferred = key
		if(!first)
			first = key
	var/datum/netrun_file/acquired_key/result = preferred ? preferred : first
	canonical_grants_uid = result?.uid
	return result

/// Legacy duplicate media are consolidated on storage facts/mount, never on UI
/// reads. Complete all ownership changes before notifying either shared viewer.
/datum/netrun_file_store/proc/consolidate_acquired_keys(publish = TRUE)
	if(merging_grants)
		return FALSE
	var/datum/netrun_file/acquired_key/canonical = acquired_key_target()
	if(!canonical)
		canonical_grants_uid = null
		return FALSE
	merging_grants = TRUE
	var/changed = FALSE
	var/datum/netrun_inventory/inventory = owner_ref?.resolve()
	for(var/datum/netrun_file/acquired_key/key as anything in files.Copy())
		if(!istype(key) || QDELETED(key) || key == canonical)
			continue
		canonical.merge_from(key)
		files -= key
		if(istype(inventory) && inventory.selected_file_uid == key.uid)
			inventory.selected_file_uid = canonical.uid
		qdel(key)
		changed = TRUE
	merging_grants = FALSE
	if(changed && publish)
		notify_changed()
	return changed

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
	if(QDELETED(file) || QDELETED(destination) || !(file in files) || (move && destination == src) || !file.can_transfer(destination, move) || (!move && !file.can_copy()) || !destination.can_fit(file))
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
	var/datum/netrun_file/stored = destination.insert(result)
	if(!stored)
		if(move)
			files += file
		else
			qdel(result)
		return null
	if(move)
		notify_changed()
	return stored

/datum/netrun_file_store/proc/notify_changed()
	revision++
	SEND_SIGNAL(src, COMSIG_NETRUN_STORAGE_CHANGED, revision)

/// One session combines its owned memory with a borrowed removable disk.
/datum/netrun_inventory
	var/datum/netrun_console/owner
	var/datum/netrun_file_store/local_store
	/// A dive can borrow the implant disk without taking ownership of its files.
	var/datum/netrun_file_store/owned_store
	/// Private ephemeral credentials never enter the borrowed implant disk.
	var/datum/netrun_file_store/session_store
	/// Membership only; scope validity is checked live for every authority read.
	var/list/datum/netrun_file/acquired_key/acquired_keys
	var/datum/weakref/borrowed_inventory_ref
	var/obj/item/netrun_shard/shard
	var/selected_file_uid

/datum/netrun_inventory/New(datum/netrun_console/owner, capacity = 6 * NETRUN_STORAGE_SCALE)
	src.owner = owner
	local_store = new(src, capacity)
	owned_store = local_store
	RegisterSignal(local_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_store_changed))

/datum/netrun_inventory/Destroy()
	acquired_keys = null
	clear_session_store()
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
	if(session_store)
		. += session_store.files

/datum/netrun_inventory/proc/store_for(datum/netrun_file/file)
	RETURN_TYPE(/datum/netrun_file_store)
	if(file in local_store.files)
		return local_store
	if(!QDELETED(shard) && (file in shard.file_store.files))
		return shard.file_store
	if(session_store && (file in session_store.files))
		return session_store

/datum/netrun_inventory/proc/find_file(uid)
	// Execution resolves actual disk membership, never a retained UI file list.
	var/datum/netrun_file/file = local_store.find_file(uid)
	if(file)
		return file
	file = shard?.file_store.find_file(uid)
	if(file)
		return file
	return session_store?.find_file(uid)

/// A dedicated, non-writable mount keeps session authority out of physical media.
/datum/netrun_inventory/proc/mount_session_file(datum/netrun_file/file)
	if(QDELETED(file))
		return FALSE
	if(!session_store)
		session_store = new(src, 0)
		RegisterSignal(session_store, COMSIG_NETRUN_STORAGE_CHANGED, PROC_REF(on_store_changed))
	return session_store.insert(file, TRUE)

/datum/netrun_inventory/proc/clear_session_store()
	if(!session_store)
		return
	UnregisterSignal(session_store, COMSIG_NETRUN_STORAGE_CHANGED)
	QDEL_NULL(session_store)
	notify_changed()

/datum/netrun_inventory/proc/store_file(datum/netrun_file/file, to_shard = FALSE)
	RETURN_TYPE(/datum/netrun_file)
	var/datum/netrun_file_store/destination = to_shard ? shard?.file_store : local_store
	return destination?.insert(file)

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
		shard.file_store.consolidate_acquired_keys()
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
	acquired_keys = null
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
	// Read actual source membership without allocating all_files() snapshots or
	// caching authority across a file edit, borrowed disk replacement or removal.
	. = daemon_store_bonus(local_store, id)
	if(!QDELETED(shard))
		. = max(., daemon_store_bonus(shard.file_store, id))

/datum/netrun_inventory/proc/daemon_store_bonus(datum/netrun_file_store/store, id)
	. = 0
	for(var/datum/netrun_file/file as anything in store?.files)
		if(file.kind != NETRUN_FILE_DAEMON)
			continue
		var/datum/netrun_daemon/daemon = SSnetrun.get_daemon(file.content)
		if(daemon)
			. = max(., daemon.effect_bonus(id))
