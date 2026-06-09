// ============================================================================
// Neural Interface Component - Universal visual display system for user's screen
// ============================================================================
// Provides text-based visual information display through the neural interface,
// supporting logs, data panels, notifications, and custom templates.
// ============================================================================

// ---------------------------------------------------------------------------
// Log Entry - Individual log message with text reveal animation
// ---------------------------------------------------------------------------
/datum/log_entry
	var/plain
	var/color
	var/char_index
	var/char_speed
	var/size

/datum/log_entry/proc/get_line()
	if(char_index < length(plain))
		char_index = min(char_index + char_speed, length(plain)+1)

	var/revealed_text = copytext(plain, 1, char_index)

	return {"<span style='font-family: \"TinyUnicode\"; color: [color]; font-size: [size]pt; line-height: 0.8;-dm-text-outline: 1px black;'>[revealed_text]</span>"}

// ---------------------------------------------------------------------------
// Neural Data Entry - Temporary data with expiration timer
// ---------------------------------------------------------------------------
/datum/neural_data_entry
	var/key
	var/value
	var/decay_duration // seconds before entry expires
	var/expiry_time // world.time when entry expires
	var/priority = 0 // higher priority = less likely to be removed when at capacity

/datum/neural_data_entry/New(duration=10 SECONDS)
	decay_duration = duration
	expiry_time = world.time + decay_duration
	return ..()


// ---------------------------------------------------------------------------
// Image Holder - Highlight objects
// ---------------------------------------------------------------------------
/datum/image_holder_data
	var/key
	var/image/overlay
	var/atom/movable/screen/text/screen_text
	var/decay_duration
	var/expire_time
	var/priority = 0

/datum/image_holder_data/New(key_target, image/overlay_target, text_target = "", duration=5 SECONDS, pixel_x_text=0, pixel_y_text=0)
	key = key_target
	decay_duration = duration
	expire_time = world.time + decay_duration
	overlay = overlay_target
	overlay.plane = BYOND_LIGHTING_PLANE
	if(text_target)
		screen_text = new /atom/movable/screen/text()
		screen_text.maptext = MAPTEXT_TINY_UNICODE(text_target)
		screen_text.maptext_height = 250
		screen_text.maptext_width = 250
		screen_text.pixel_x = pixel_x_text
		screen_text.pixel_y = pixel_y_text
		overlay.add_overlay(screen_text)
	priority = 0

/datum/image_holder_data/proc/change_text(text)
	if(screen_text)
		screen_text.maptext = text

/datum/image_holder_data/Destroy()
	if(screen_text)
		overlay.cut_overlay(screen_text)
		QDEL_NULL(screen_text)
	QDEL_NULL(overlay)
	return ..()

// ---------------------------------------------------------------------------
// Utility Procs
// ---------------------------------------------------------------------------
proc/string_repeat(string, count)
	var/result = ""
	for(var/i in range(1, count))
		result += string

	return result

// ---------------------------------------------------------------------------
// Neural Interface Component - Main component for visual display
// ---------------------------------------------------------------------------
/datum/component/neural_interface
	// Host mob reference
	var/mob/living/host_mob
	var/list/sources = list()

	// Screen display object
	var/atom/movable/screen/logs_view

	// Log storage - list of datum/log_entry
	var/list/logs = list()
	var/max_logs = 3

	// Data entries - list of datum/neural_data_entry with expiration
	var/list/datum/neural_data_entry/data_entries = list()
	var/max_data_entries = 10

	// Data image entries - list of datum/image_holder_data with expiration
	var/list/datum/image_holder_data/image_data_entries = list()
	var/max_image_data_entries = 10

	// Text animation settings
	var/char_reveal_speed = 10

	// Display configuration
	var/screen_loc = "LEFT+1.5,CENTER-1.5"
	var/maptext_width = 450
	var/maptext_height = 250

	// UI customization
	var/display_title = "NEURAL INTERFACE"
	var/header_color = "#4ad1fa86"
	var/separator_color = "#6b7280"
	var/font_size = 12
	var/visible = TRUE

	// Update interval (in seconds)
	var/update_interval = 1 SECONDS
	var/last_update = 0

	// Client tracking
	var/client/attached_client
	var/is_client_attached = FALSE

	// Monitor instances - composition pattern
	var/list/datum/neural_monitor/monitors = list()

	// Signal registration handles
	var/list/signal_registrations = list()

	// Log category configuration
	var/list/log_categories = list(
		"SYSTEM" = "#4ad1fa86",
		"WARNING" = "#f59e0bff",
		"ERROR" = "#ef4444ff",
		"INFO" = "#10b981ff",
		"DATA" = "#8b5cf6ff",
		"SYNC" = "#06b6d4ff",
		"HEALTH" = "#f472b6ff",
		"MODULE" = "#a78bffff",
		"ALERT" = "#ff0000ff",
		"STATUS" = "#6b7280ff",
		"DEBUG" = "#94a3b8ff"
	)

	// Category-specific speeds (0 = use default)
	var/list/log_speeds = list(
		"SYSTEM" = 15,
		"WARNING" = 15,
		"ERROR" = 30,
		"INFO" = 15,
		"DATA" = 15,
		"SYNC" = 15,
		"HEALTH" = 30,
		"MODULE" = 15,
		"ALERT" = 30,
		"STATUS" = 10,
		"DEBUG" = 20
	)

/datum/component/neural_interface/Initialize(
		mob/user,
		display_title_p = "NEURAL INTERFACE",
		max_logs_p = 3,
		max_data_entries_p = 10,
		max_image_data_entries_p = 10,
		char_reveal_speed_p = 10,
		screen_loc_p = "LEFT+1.5,CENTER-1.5"
	)

	if(!isliving(parent))
		return COMPONENT_INCOMPATIBLE

	host_mob = parent
	display_title = display_title_p
	max_logs = max_logs_p
	max_data_entries = max_data_entries_p
	max_image_data_entries = max_image_data_entries_p
	char_reveal_speed = char_reveal_speed_p
	screen_loc = screen_loc_p

	// Create screen display
	logs_view = ScreenText(null, "Initialize", screen_loc, maptext_height, maptext_width)

	if(host_mob?.client)
		host_mob.client.screen += logs_view
		attached_client = host_mob.client
		is_client_attached = TRUE

	register_client_signals()

	START_PROCESSING(SSfastprocess, src)

	return ..()

/datum/component/neural_interface/process(delta_time)
	compile_display()

/datum/component/neural_interface/Destroy(force, silent)
	STOP_PROCESSING(SSfastprocess, src)
	unregister_all_signals()
	unregister_all_monitors()
	clear_image_data_entries()
	clear_data_entries()
	delete_user()

	return ..()

/datum/component/neural_interface/proc/AddSource(id)
	LAZYINITLIST(sources)
	LAZYADD(sources, id)

/datum/component/neural_interface/proc/RemoveSource(id)
	LAZYINITLIST(sources)
	LAZYREMOVE(sources, id)
	var/list/types = list()

	for(var/datum/neural_monitor/monitor in monitors)
		if(monitor.source != id)
			continue

		monitor.disable()
		monitors -= monitor
		types += monitor.type
		QDEL_NULL(monitor)

	if(!sources)
		qdel(src)
		return

	for(var/type in types)
		enable_monitor_by_type(type)

// ---------------------------------------------------------------------------
// Monitor Management
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/unregister_all_monitors()
	LAZYINITLIST(monitors)
	for(var/datum/neural_monitor/monitor in monitors)
		monitor.disable()
	QDEL_LIST(monitors)

/datum/component/neural_interface/proc/add_monitor_by_type(source, type, atom/monitor_atom, ...)
	LAZYINITLIST(sources)
	if(!LAZYFIND(sources, source))
		AddSource(source)
	LAZYINITLIST(monitors)
	var/list/arguments = args.Copy()
	arguments.Splice(1, 4)
	if(!monitor_atom)
		monitor_atom = host_mob
	var/datum/neural_monitor/monitor = new type(arglist(list(src, monitor_atom, source) + arguments))
	if(!istype(monitor))
		return FALSE
	monitors += monitor
	if(!get_enabled_monitor_by_type(type))
		return
	monitor.enable()

/datum/component/neural_interface/proc/add_monitors_by_types(source, list/types)
	LAZYINITLIST(monitors)
	LAZYINITLIST(types)
	for(var/type in types)
		var/list/arguments = list(host_mob)
		if(types[type])
			arguments = types[type]
		add_monitor_by_type(arglist(list(source, type) + arguments))


/datum/component/neural_interface/proc/remove_monitors_by_types(source, list/types)
	LAZYINITLIST(types)
	for(var/type in types)
		remove_monitor_by_type(source, type)

/datum/component/neural_interface/proc/remove_monitor_by_type(source, type)
	LAZYINITLIST(monitors)
	for(var/datum/neural_monitor/monitor in monitors)
		if(istype(monitor, type) && monitor.source == source)
			monitor.disable()
			monitors -= monitor
			QDEL_NULL(monitor)
			enable_monitor_by_type(type)
			break

/datum/component/neural_interface/proc/enable_monitor_by_type(type)
	for(var/datum/neural_monitor/monitor in monitors)
		if(!istype(monitor, type))
			continue

		monitor.enable()
		break

/datum/component/neural_interface/proc/get_enabled_monitor_by_type(type)
	for(var/datum/neural_monitor/monitor in monitors)
		if(!istype(monitor, type) && !monitor.enabled)
			continue
		return monitor

	return FALSE

// ---------------------------------------------------------------------------
// User Management
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/delete_user()
	if(!host_mob)
		return

	// Remove from screen
	if(logs_view)
		if(host_mob?.client)
			host_mob.client.screen -= logs_view
		QDEL_NULL(logs_view)
		logs_view = null

	attached_client = null
	is_client_attached = FALSE
	host_mob = null

// ---------------------------------------------------------------------------
// Client Tracking - Client attach/detach signals
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/register_client_signals()
	if(!host_mob)
		return

	if(!attached_client)
		attached_client = host_mob?.client

	if(attached_client)
		RegisterSignal(host_mob, COMSIG_MOB_GHOSTIZE, PROC_REF(on_mob_ghostize))
		RegisterSignal(host_mob, COMSIG_MOB_KEY_CHANGE, PROC_REF(on_mob_key_change))
		RegisterSignal(host_mob, COMSIG_MOB_PRE_PLAYER_CHANGE, PROC_REF(on_mob_key_change))
		RegisterSignal(host_mob, COMSIG_CLIENT_MOB_LOGIN, PROC_REF(on_client_reconnect))
		signal_registrations += list(
			COMSIG_MOB_GHOSTIZE,
			COMSIG_MOB_KEY_CHANGE,
			COMSIG_MOB_PRE_PLAYER_CHANGE,
			COMSIG_CLIENT_MOB_LOGIN
		)
		is_client_attached = TRUE

// ---------------------------------------------------------------------------
// Signal unregistration
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/unregister_all_signals()
	for(var/signal_handle in signal_registrations)
		UnregisterSignal(host_mob, signal_handle)
	signal_registrations = list()


// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_mob_key_change(mob/M, mob/new_mob, old_mob)
	SIGNAL_HANDLER

	if(M == host_mob)
		write_log("Player transferred control to another mob", "SYNC")
		write_data("PLAYER_TRANSFER", "TRUE")

		if(host_mob?.client)
			attached_client = host_mob.client
			is_client_attached = TRUE

			if(logs_view)
				logs_view.maptext = ""
				compile_display()

// ---------------------------------------------------------------------------
// Client Reconnect - Re-attach display
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_client_reconnect(client/C)
	SIGNAL_HANDLER

	if(!host_mob)
		return

	attached_client = C
	is_client_attached = TRUE

	if(logs_view)
		write_log("Client reconnected - display restored", "SYNC")

		if(visible)
			logs_view.maptext = ""
			compile_display()

// ---------------------------------------------------------------------------
// Client Ghost - De-attach display
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_mob_ghostize(mob/M, can_reenter, special, penalize)
	SIGNAL_HANDLER

	if(M != host_mob)
		return

	attached_client = null
	is_client_attached = FALSE

	warn_log("Host ghostized [can_reenter == TRUE ? "(can re-enter)" : ""]")
	write_data("GHOST_STATE", "TRUE")

// ============================================================================
// DATA ENTRY MANAGEMENT - Objects with expiration timers
// ============================================================================

// ---------------------------------------------------------------------------
// Write Data Entry - Creates or updates with decay timer
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/write_data(key, value, decay_duration=3 SECONDS, priority=0)
	// Check if entry with same key already exists
	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.key == key)
			// Update existing entry - reset timer
			entry.value = value
			entry.decay_duration = decay_duration
			entry.expiry_time = world.time + decay_duration
			entry.priority = priority
			return TRUE

	// Create new entry
	var/datum/neural_data_entry/new_entry = new()
	new_entry.key = key
	new_entry.value = value
	new_entry.decay_duration = decay_duration
	new_entry.expiry_time = world.time + decay_duration
	new_entry.priority = priority

	// Remove oldest/expires-next entry if at capacity
	if(data_entries.len >= max_data_entries)
		remove_oldest_data_entry()

	data_entries += new_entry
	return TRUE

// ---------------------------------------------------------------------------
// Remove oldest data entry - lowest priority first, then earliest expiry
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/remove_oldest_data_entry()
	var/datum/neural_data_entry/target
	var/lowest_priority = 999999
	var/latest_expiry = INFINITY

	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.priority < lowest_priority)
			lowest_priority = entry.priority
			target = entry
			latest_expiry = entry.expiry_time
		else if(entry.priority == lowest_priority && entry.expiry_time < latest_expiry)
			// Same priority, remove the one expiring sooner
			target = entry
			latest_expiry = entry.expiry_time

	if(target)
		data_entries -= target
		QDEL_NULL(target)

// ---------------------------------------------------------------------------
// Remove specific data entry by key
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/remove_data_entry(key)
	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.key == key)
			data_entries -= entry
			QDEL_NULL(entry)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Clear all data entries
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/clear_data_entries()
	for(var/datum/neural_data_entry/entry in data_entries)
		QDEL_NULL(entry)
	data_entries = list()
	return TRUE

// ---------------------------------------------------------------------------
// Cleanup expired data entries
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/cleanup_expired_data()
	var/list/to_remove = list()

	for(var/datum/neural_data_entry/entry in data_entries)
		if(world.time >= entry.expiry_time)
			to_remove += entry

	for(var/removed in to_remove)
		data_entries -= removed
		QDEL_NULL(removed)

// ---------------------------------------------------------------------------
// Get active data entries (non-expired)
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/get_active_data_entries()
	var/list/active = list()
	for(var/datum/neural_data_entry/entry in data_entries)
		if(world.time < entry.expiry_time)
			active[entry.key] = entry.value
	return active

// ---------------------------------------------------------------------------
// Check if data entry exists and is not expired
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/data_entry_exists(key)
	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.key == key && world.time < entry.expiry_time)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Get data entry value by key (returns null if not found or expired)
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/get_data_entry_value(key)
	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.key == key && world.time < entry.expiry_time)
			return entry.value
	return null

// ---------------------------------------------------------------------------
// Log Management - Write messages with categories and formatting
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/write_log(text, key="LOG", color="#4ad1fa86", size=12, speed=0)
	LAZYINITLIST(logs)

	// Apply category color if defined
	if(log_categories[key])
		color = log_categories[key]

	// Format log message
	var/plain_text = "\[[key]\] - [text]"

	// Remove oldest logs if at capacity
	if(logs.len >= max_logs)
		var/datum/log_entry/old = logs[1]
		logs.Splice(1, 2)
		QDEL_NULL(old)

	// Create log entry
	var/datum/log_entry/log = new()

	log.plain = plain_text
	log.color = color
	log.char_index = 1
	log.char_speed = speed > 0 ? speed : char_reveal_speed
	log.size = size

	// Override speed if category has specific speed
	if(log_speeds[key] && speed == 0)
		log.char_speed = log_speeds[key]

	logs += log

	return TRUE

/datum/component/neural_interface/proc/clear_logs()
	QDEL_LIST(logs)
	logs = list()
	return TRUE

/datum/component/neural_interface/proc/remove_log(index)
	if(index >= 1 && index <= logs.len)
		var/datum/log_entry/removed = logs[index]
		logs.Cut(index, index + 1)
		QDEL_NULL(removed)
		return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Display Compilation - Generate HTML for screen rendering
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/compile_display()
	if(!is_client_attached || attached_client == null)
		if(host_mob.client)
			is_client_attached = TRUE
			attached_client = host_mob.client
			host_mob.client.screen += logs_view

	// Throttle updates
	if(world.time - last_update < update_interval)
		return

	last_update = world.time

	if(!logs_view || !visible)
		return

	// Cleanup expired data entries
	cleanup_expired_data()

	// Cleanup expired image data entries
	cleanup_expired_image_data()

	var/write = get_display_header()

	// Add log stream section
	if(logs.len > 0)
		write += get_log_section()

	// Add data section (only active entries)
	if(data_entries.len > 0)
		write += get_data_section()

	// Apply compiled display
	logs_view.maptext = write

/datum/component/neural_interface/proc/compile_log()
	// Alias for compile_display for backward compatibility
	compile_display()

// ---------------------------------------------------------------------------
// Display Sections - Build individual display parts
// ---------------------------------------------------------------------------

/datum/component/neural_interface/proc/get_display_header()
	var/write = {"<span style='font-family: \"TinyUnicode\"; font-size: [font_size]pt; color: [header_color]; line-height: 0.8; -dm-text-outline: 1px black;'>── [display_title] ──</span><br>"}
	write += {"<span style='font-family: \"TinyUnicode\"; font-size: [font_size]pt; color: [separator_color]; line-height: 0.8; -dm-text-outline: 1px black;'>[string_repeat("─", length(display_title) + 6)]</span><br>"}

	return write

/datum/component/neural_interface/proc/get_log_section()
	var/write = ""
	write += {"<span style='font-family: \"TinyUnicode\"; font-size: [font_size]pt; color: [separator_color]; line-height: 0.8; -dm-text-outline: 1px black;'>├─ LOG STREAM</span><br>"}

	for(var/datum/log_entry/log_entry in logs)
		write += "[MAPTEXT_TINY_UNICODE("└ [log_entry.get_line()]")]<br>"

	return write

/datum/component/neural_interface/proc/get_data_section()
	var/write = ""
	write += {"<span style='font-family: \"TinyUnicode\"; font-size: [font_size]pt; color: [separator_color]; line-height: 0.8; -dm-text-outline: 1px black;'>├─ DATA</span><br>"}

	for(var/datum/neural_data_entry/entry in data_entries)
		if(world.time < entry.expiry_time)
			write += "[MAPTEXT_TINY_UNICODE("└ [entry.key]: [entry.value]")]<br>"

	return write

// ---------------------------------------------------------------------------
// Visibility Control
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/show()
	visible = TRUE
	if(logs_view)
		logs_view.maptext = ""
	compile_display()

/datum/component/neural_interface/proc/hide()
	visible = FALSE
	if(logs_view)
		logs_view.maptext = ""

// ---------------------------------------------------------------------------
// Quick Access - Common operations
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/system_log(text)
	return write_log(text, "SYSTEM")

/datum/component/neural_interface/proc/warn_log(text)
	return write_log(text, "WARNING")

/datum/component/neural_interface/proc/error_log(text)
	return write_log(text, "ERROR")

/datum/component/neural_interface/proc/info_log(text)
	return write_log(text, "INFO")

// ============================================================================
// IMAGE DATA ENTRY MANAGEMENT - Images with expiration timers
// ============================================================================

// ---------------------------------------------------------------------------
// Write Image Data Entry - Creates or replaces image with decay timer
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/write_image_data(key, image/overlay, text, decay_duration=30 SECONDS, pixel_x_text = 0, pixel_y_text = 0, priority=0)
	if(!host_mob?.client)
		return FALSE

	// Check if entry with same key already exists
	for(var/datum/image_holder_data/existing_entry in image_data_entries)
		if(existing_entry.key == key)
			// Remove old overlay from host client images
			if(existing_entry.overlay)
				host_mob.client.images -= existing_entry.overlay
			image_data_entries -= existing_entry
			QDEL_NULL(existing_entry)
			break

	// Create new entry
	var/datum/image_holder_data/new_entry = new(key, overlay, text, decay_duration, pixel_x_text, pixel_y_text)
	new_entry.priority = priority

	// Add overlay to host client images
	if(new_entry.overlay)
		host_mob.client.images += new_entry.overlay

	// Remove oldest/expires-next entry if at capacity
	if(image_data_entries.len >= max_image_data_entries)
		remove_oldest_image_data_entry()

	image_data_entries += new_entry
	return TRUE

// ---------------------------------------------------------------------------
// Remove oldest image data entry - lowest priority first, then earliest expiry
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/remove_oldest_image_data_entry()
	var/datum/image_holder_data/target
	var/lowest_priority = INFINITY
	var/earliest_expiry = INFINITY

	// Find entry with lowest priority (lower number = less important) and earliest expiry
	for(var/datum/image_holder_data/entry in image_data_entries)
		if(entry.priority < lowest_priority || (entry.priority == lowest_priority && entry.expire_time < earliest_expiry))
			lowest_priority = entry.priority
			earliest_expiry = entry.expire_time
			target = entry

	if(target)
		image_data_entries -= target
		if(target.overlay && host_mob?.client)
			host_mob.client.images -= target.overlay
		QDEL_NULL(target)

// ---------------------------------------------------------------------------
// Remove specific image data entry by key
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/remove_image_data_entry(key)
	for(var/datum/image_holder_data/entry in image_data_entries)
		if(entry.key == key)
			if(entry.overlay && host_mob?.client)
				host_mob.client.images -= entry.overlay
			image_data_entries -= entry
			QDEL_NULL(entry)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Clear all image data entries
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/clear_image_data_entries()
	for(var/datum/image_holder_data/entry in image_data_entries)
		if(entry.overlay && host_mob?.client)
			host_mob.client.images -= entry.overlay
		QDEL_NULL(entry)
	image_data_entries = list()
	return TRUE

// ---------------------------------------------------------------------------
// Cleanup expired image data entries
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/cleanup_expired_image_data()
	var/list/datum/image_holder_data/to_remove = list()

	for(var/datum/image_holder_data/entry in image_data_entries)
		if(world.time >= entry.expire_time)
			to_remove += entry

	for(var/datum/image_holder_data/removed in to_remove)
		if(removed.overlay && host_mob?.client)
			host_mob.client.images -= removed.overlay
		image_data_entries -= removed
		QDEL_NULL(removed)

// ---------------------------------------------------------------------------
// Get active image data entries (non-expired)
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/get_active_image_data_entries()
	var/list/active = list()
	for(var/datum/image_holder_data/entry in image_data_entries)
		if(world.time < entry.expire_time)
			active[entry.key] = entry.overlay
	return active

// ---------------------------------------------------------------------------
// Check if image data entry exists and is not expired
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/image_data_entry_exists(key)
	for(var/datum/image_holder_data/entry in image_data_entries)
		if(entry.key == key && world.time < entry.expire_time)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Get image data entry overlay by key (returns null if not found or expired)
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/get_image_data_entry_overlay(key)
	for(var/datum/image_holder_data/entry in image_data_entries)
		if(entry.key == key && world.time < entry.expire_time)
			return entry.overlay
	return null
