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

/datum/neural_data_entry/New(duration=30 SECOND)
	decay_duration = duration
	expiry_time = world.time + decay_duration
	return ..()


// ---------------------------------------------------------------------------
// Image Holder - Highlight objects
// ---------------------------------------------------------------------------
/datum/image_holder_data
	var/image/overlay
	var/decay_duration
	var/expire_time
	var/screen_text

/datum/image_holder_data/New(image/overlay_target, text_target = "", duration=5 SECOND)
	decay_duration = duration
	expiry_time = world.time + decay_duration
	overlay = overlay_target
	screen_text = ScreenText(overlay, text_target, "CENTER, CENTER-1")
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

/datum/component/neural_interface/Initialize(mob/user)
	if(!isliving(parent))
		return COMPONENT_INCOMPATIBLE

	host_mob = parent

	// Create screen display
	logs_view = ScreenText(null, "Initialize", screen_loc, maptext_height, maptext_width)

	if(host_mob?.client)
		host_mob.client.screen += logs_view
		attached_client = host_mob.client
		is_client_attached = TRUE

	register_client_signals()

	return ..()

/datum/component/neural_interface/Destroy(force, silent)
	unregister_all_signals()
	unregister_all_monitors()
	delete_user()

	return ..()

// ---------------------------------------------------------------------------
// Monitor Management
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/unregister_all_monitors()
	for(var/datum/neural_monitor/monitor in monitors)
		monitor.disable()
		qdel(monitor)

/datum/component/neural_interface/proc/add_monitor(datum/neural_monitor/monitor)
	LAZYINITLIST(monitors)
	monitors += monitor
	monitor.enable()

/datum/component/neural_interface/proc/add_monitor_by_type(type)
	LAZYINITLIST(monitors)
	var/datum/neural_monitor/monitor = new type(src, host_mob)
	if(!istype(monitor))
		return FALSE
	monitors += monitor
	monitor.enable()

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
		qdel(logs_view)
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
		RegisterSignal(attached_client, COMSIG_PARENT_QDELETING, PROC_REF(on_client_deleted))
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
	UnregisterSignal(attached_client, COMSIG_PARENT_QDELETING)
	for(var/signal_handle in signal_registrations)
		UnregisterSignal(host_mob, signal_handle)
	signal_registrations = list()

// ---------------------------------------------------------------------------
// Client Callback - Client events
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_client_deleted(datum/source)
	if(!host_mob)
		return

	write_log("Client detached from host", "SYNC")
	write_data("CLIENT_STATUS", "DETACHED")
	attached_client = null
	is_client_attached = FALSE

	if(logs_view && host_mob?.client)
		// Client reattached (new client object)
		attached_client = host_mob.client
		host_mob.client.screen += logs_view
		is_client_attached = TRUE
		logs_view.maptext = ""
		compile_display()

// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_mob_key_change(mob/M, mob/new_mob, old_mob)
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
/datum/component/neural_interface/proc/write_data(key, value, decay_duration=30 SECONDS, priority=0)
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
	var/latest_expiry = 0

	// Find entry with lowest priority (highest = most important)
	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.priority < lowest_priority)
			lowest_priority = entry.priority
			target = entry
		else if(entry.priority == lowest_priority && entry.expiry_time < latest_expiry)
			// Same priority, remove the one expiring sooner
			target = entry
			latest_expiry = entry.expiry_time

	if(target)
		data_entries -= target
		qdel(target)

// ---------------------------------------------------------------------------
// Remove specific data entry by key
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/remove_data_entry(key)
	for(var/datum/neural_data_entry/entry in data_entries)
		if(entry.key == key)
			data_entries -= entry
			qdel(entry)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------
// Clear all data entries
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/clear_data_entries()
	for(var/datum/neural_data_entry/entry in data_entries)
		qdel(entry)
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
		qdel(removed)

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

	// Apply category color if defined
	if(log_categories[key])
		color = log_categories[key]

	// Format log message
	var/plain_text = "\[[key]\] - [text]"

	// Remove oldest logs if at capacity
	if(logs.len >= max_logs)
		logs.Splice(1, 2)

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
	logs = list()
	return TRUE

/datum/component/neural_interface/proc/remove_log(index)
	if(index >= 1 && index <= logs.len)
		logs = logs - index
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
	if(world.time - last_update < update_interval / 10)
		return

	last_update = world.time

	if(!logs_view || !visible)
		return

	// Cleanup expired data entries
	cleanup_expired_data()

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
