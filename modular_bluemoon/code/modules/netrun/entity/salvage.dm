/// Only nonempty debris caches are indexed; collectors never need an all-node poll.
/datum/controller/subsystem/netrun
	var/list/salvage_nodes = list()
	var/list/recycling_servers = list()

/// Ownership passes from the caller to this bounded cache only on success.
/// Identity, rather than executable kind, distinguishes independently owned files.
/datum/component/netrun_node/proc/leave_salvage(datum/netrun_file/file, source_name, notify = TRUE)
	if(QDELETED(src) || QDELETED(file) || !file.can_transfer(null, TRUE))
		return FALSE
	if(file in salvage)
		return TRUE
	while(length(salvage) >= NETRUN_MAX_SALVAGE_FILES)
		var/datum/netrun_file/expired = salvage[1]
		salvage.Cut(1, 2)
		qdel(expired)
	salvage += file
	add_log("В обломках процесса[source_name ? " [source_name]" : ""] остался файл: [file.name].")
	if(notify)
		refresh_salvage()
	return TRUE

/// One semantic fact wakes interested collectors and updates shared presentation.
/datum/component/netrun_node/proc/refresh_salvage()
	for(var/datum/netrun_file/file as anything in salvage.Copy())
		if(QDELETED(file))
			salvage -= file
	if(!QDELETED(src) && length(salvage))
		SSnetrun.salvage_nodes[address] = src
	else
		SSnetrun.salvage_nodes -= address
	notify_changed(NETRUN_CHANGED_DETAILS)
	SEND_SIGNAL(SSnetrun, COMSIG_NETRUN_SALVAGE_CHANGED, src)
