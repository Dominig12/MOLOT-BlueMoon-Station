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

/datum/neural_data_entry/New()
	decay_duration = 30 SECONDS
	expiry_time = world.time + decay_duration
	return ..()


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
	var/list/data_entries = list()
	var/max_data_entries = 10

	// Text animation settings
	var/char_reveal_speed = 10

	// Display configuration
	var/screen_loc = "CENTER-6,CENTER-4"
	var/maptext_width = 450
	var/maptext_height = 250

	// UI customization
	var/display_title = "NEURAL INTERFACE"
	var/header_color = "#4ad1fa86"
	var/separator_color = "#6b7280"
	var/font_size = 12
	var/visible = TRUE

	// Template system - custom display templates
	var/datum/neural_interface_template/current_template

	// Update interval (in seconds)
	var/update_interval = 1 SECONDS
	var/last_update = 0

	// Client tracking
	var/client/attached_client
	var/is_client_attached = FALSE

	// Auto-monitor settings
	var/auto_monitor_health = TRUE
	var/auto_monitor_status = TRUE
	var/auto_monitor_wounds = TRUE
	var/auto_monitor_shock = TRUE

	// Damage tracking state
	var/last_brute_damage = 0
	var/last_tox_damage = 0
	var/last_fire_damage = 0
	var/last_oxy_damage = 0
	var/last_stat = 0

	// Wound tracking
	var/list/active_wounds = list()
	var/total_wound_bonus = 0

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

	// Register auto-monitor signals
	if(auto_monitor_health || auto_monitor_status)
		register_health_signals()

	if(auto_monitor_wounds)
		register_wound_signals()

	if(auto_monitor_shock)
		register_shock_signals()

	register_client_signals()

	return ..()

/datum/component/neural_interface/Destroy(force, silent)
	unregister_all_signals()
	delete_user()

	return ..()

/datum/component/neural_interface/UnregisterFromParent()
	unregister_all_signals()
	delete_user()

	return ..()

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
// Client Tracking - Signal Registration
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/register_health_signals()
	if(!host_mob)
		return

	// Register health change signals
	if(ishuman(host_mob))
		RegisterSignal(host_mob, COMSIG_CARBON_UPDATEHEALTH, PROC_REF(on_carbon_health_update))
		signal_registrations += list(
			COMSIG_CARBON_UPDATEHEALTH
		)

	// Register living status signals
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_STUN, PROC_REF(on_living_stunned))
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_KNOCKDOWN, PROC_REF(on_living_knockdown))
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_PARALYZE, PROC_REF(on_living_paralyzed))
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_UNCONSCIOUS, PROC_REF(on_living_unconscious))
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_SLEEP, PROC_REF(on_living_sleeping))
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_DAZE, PROC_REF(on_living_dazed))
	RegisterSignal(host_mob, COMSIG_LIVING_STATUS_STAGGER, PROC_REF(on_living_staggered))

	// Register death/revive signals
	RegisterSignal(host_mob, COMSIG_MOB_DEATH, PROC_REF(on_mob_death))
	RegisterSignal(host_mob, COMSIG_LIVING_REVIVE, PROC_REF(on_living_revive))
	RegisterSignal(host_mob, COMSIG_LIVING_DEATH, PROC_REF(on_living_death))
	RegisterSignal(host_mob, COMSIG_LIVING_PREDEATH, PROC_REF(on_living_predeath))
	RegisterSignal(host_mob, COMSIG_MOB_APPLY_DAMAGE, PROC_REF(on_mob_apply_damage))

	// Register ghostize signal
	RegisterSignal(host_mob, COMSIG_MOB_GHOSTIZE, PROC_REF(on_mob_ghostize))

	signal_registrations += list(
		COMSIG_LIVING_STATUS_STUN,
		COMSIG_LIVING_STATUS_KNOCKDOWN,
		COMSIG_LIVING_STATUS_PARALYZE,
		COMSIG_LIVING_STATUS_UNCONSCIOUS,
		COMSIG_LIVING_STATUS_SLEEP,
		COMSIG_LIVING_STATUS_DAZE,
		COMSIG_LIVING_STATUS_STAGGER,
		COMSIG_MOB_DEATH,
		COMSIG_LIVING_REVIVE,
		COMSIG_LIVING_DEATH,
		COMSIG_LIVING_PREDEATH,
		COMSIG_MOB_APPLY_DAMAGE,
		COMSIG_MOB_GHOSTIZE)

// ---------------------------------------------------------------------------
// Client Tracking - Client attach/detach signals
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/register_client_signals()
	if(!host_mob)
		return

	if(!attached_client)
		attached_client = host_mob?.client

	if(attached_client)
		RegisterSignal(attached_client, COMSIG_PARENT_QDELETING, PROC_REF(on_client_deleted))
		RegisterSignal(host_mob, COMSIG_MOB_KEY_CHANGE, PROC_REF(on_mob_key_change))
		RegisterSignal(host_mob, COMSIG_MOB_PRE_PLAYER_CHANGE, PROC_REF(on_mob_key_change))
		RegisterSignal(host_mob, COMSIG_CLIENT_MOB_LOGIN, PROC_REF(on_client_reconnect))
		signal_registrations += list(
			COMSIG_PARENT_QDELETING,
			COMSIG_MOB_KEY_CHANGE,
			COMSIG_CLIENT_MOB_LOGIN
		)
		is_client_attached = TRUE

// ---------------------------------------------------------------------------
// Wound tracking signals
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/register_wound_signals()
	if(!host_mob || !ishuman(host_mob))
		return

	RegisterSignal(host_mob, COMSIG_CARBON_GAIN_WOUND, PROC_REF(on_carbon_gain_wound))
	RegisterSignal(host_mob, COMSIG_CARBON_LOSE_WOUND, PROC_REF(on_carbon_lose_wound))
	signal_registrations += list(
		COMSIG_CARBON_GAIN_WOUND,
		COMSIG_CARBON_LOSE_WOUND
	)

// ---------------------------------------------------------------------------
// Shock signals
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/register_shock_signals()
	if(!host_mob)
		return

	RegisterSignal(host_mob, COMSIG_LIVING_ELECTROCUTE_ACT, PROC_REF(on_living_electrocuted))
	RegisterSignal(host_mob, COMSIG_LIVING_MINOR_SHOCK, PROC_REF(on_living_minor_shock))
	signal_registrations += list(
		COMSIG_LIVING_ELECTROCUTE_ACT,
		COMSIG_LIVING_MINOR_SHOCK
	)

// ---------------------------------------------------------------------------
// Signal unregistration
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/unregister_all_signals()
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
// Health Callback - Carbon health update
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_carbon_health_update(mob/living/carbon/C)
	if(!auto_monitor_health)
		return

	update_health_data()

// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/update_health_data()
	if(!host_mob || !isliving(host_mob) || !iscarbon(host_mob))
		return

	var/mob/living/carbon/user = host_mob

	var/oxy_loss = user.getOxyLoss()
	var/tox_loss = user.getToxLoss()
	var/fire_loss = user.getFireLoss()
	var/brute_loss = user.getBruteLoss()

	// Detect new damage
	var/new_brute = brute_loss > last_brute_damage
	var/new_tox = tox_loss > last_tox_damage
	var/new_fire = fire_loss > last_fire_damage
	var/new_oxy = oxy_loss > last_oxy_damage

	if(new_brute && (brute_loss - last_brute_damage) > 5)
		write_log("Brute damage: [brute_loss]", "HEALTH")
	if(new_tox && (tox_loss - last_tox_damage) > 5)
		write_log("Toxin damage: [tox_loss]", "HEALTH")
	if(new_fire && (fire_loss - last_fire_damage) > 5)
		write_log("Burn damage: [fire_loss]", "HEALTH")
	if(new_oxy && (oxy_loss - last_oxy_damage) > 5)
		write_log("Oxygen loss: [oxy_loss]", "HEALTH")

	// Update status display
	var/health_percent = user.health / user.maxHealth * 100
	var/status_text = "<b>[round(health_percent, 0.1)]%</b>"

	if(user.stat == DEAD)
		status_text = "<span class='alert'><b>DESTROYED</b></span>"
	else if(health_percent < 25)
		status_text = "<span class='alert'><b>CRITICAL</b></span>"
	else if(health_percent < 50)
		status_text = "<span class='userdanger'><b>DANGER</b></span>"
	else if(health_percent < 75)
		status_text = "<span class='notice'><b>MINOR</b></span>"

	write_data("STATUS", status_text)
	write_data("BRUTE", "[brute_loss]")
	write_data("TOKSIN", "[tox_loss]")
	write_data("BURN", "[fire_loss]")
	write_data("OXYGEN", "[oxy_loss]")

	// Store last values
	last_brute_damage = brute_loss
	last_tox_damage = tox_loss
	last_fire_damage = fire_loss
	last_oxy_damage = oxy_loss

// ---------------------------------------------------------------------------
// Wound Callback
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_carbon_gain_wound(mob/living/carbon/C, datum/wound/W, obj/item/bodypart/L)
	if(!auto_monitor_wounds)
		return

	var/wound_info = "Wound: [W.name] on [L.name]"
	active_wounds += wound_info

	write_log(wound_info, "HEALTH")

	if(W.name)
		write_data("ACTIVE_WOUND", W.name)

// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_carbon_lose_wound(mob/living/carbon/C, datum/wound/W, obj/item/bodypart/L)
	if(!auto_monitor_wounds)
		return

	var/wound_info = "Healed: [W.name] on [L.name]"
	active_wound_remove(W.name)
	write_log(wound_info, "HEALTH")

// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/active_wound_remove(wound_name)
	for(var/i in 1 to active_wounds.len)
		if(active_wounds[i] && findtext(active_wounds[i], wound_name))
			active_wounds[i] = null
			return

// ---------------------------------------------------------------------------
// Status Callback - Living status effects
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_living_stunned(mob/living/L, amount, update, ignore)
	write_log("Stunned: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("STUN_REMAINING", "[round(amount/10, 0.1)]s")

/datum/component/neural_interface/proc/on_living_knockdown(mob/living/L, amount, update, ignore)
	write_log("Knocked down: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("KNOCKDOWN_REMAINING", "[round(amount/10, 0.1)]s")

/datum/component/neural_interface/proc/on_living_paralyzed(mob/living/L, amount, update, ignore)
	write_log("Paralyzed: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("PARALYZE_REMAINING", "[round(amount/10, 0.1)]s")

/datum/component/neural_interface/proc/on_living_unconscious(mob/living/L, amount, update, ignore)
	write_log("Unconscious: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("UNCONSCIOUS_REMAINING", "[round(amount/10, 0.1)]s")

/datum/component/neural_interface/proc/on_living_sleeping(mob/living/L, amount, update, ignore)
	write_log("Asleep: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("SLEEP_REMAINING", "[round(amount/10, 0.1)]s")

/datum/component/neural_interface/proc/on_living_dazed(mob/living/L, amount, update, ignore)
	write_log("Dazed: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("DAZE_REMAINING", "[round(amount/10, 0.1)]s")

/datum/component/neural_interface/proc/on_living_staggered(mob/living/L, amount, update, ignore)
	write_log("Staggered: [round(amount/10, 0.1)]s", "HEALTH")
	write_data("STAGGER_REMAINING", "[round(amount/10, 0.1)]s")

// ---------------------------------------------------------------------------
// Death/Revive Callback
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_mob_death(mob/M, gibbed)
	if(M != host_mob)
		return

	error_log("Mob death signal received")

/datum/component/neural_interface/proc/on_living_death(mob/living/L, gibbed)
	if(L != host_mob)
		return

	error_log("Living death signal received [gibbed ? "(gibbed)" : ""]")
	write_data("DEATH_STATE", "DIED")
	write_log("Vital signals TERMINATED", "ALERT")

/datum/component/neural_interface/proc/on_living_predeath(mob/living/L, gibbed)
	if(L != host_mob)
		return

	warn_log("Pre-death state [gibbed == TRUE ? "(gibbed)" : ""]")
	write_data("PREDEATH_STATE", "TRUE")

/datum/component/neural_interface/proc/on_living_revive(mob/living/L, full_heal, admin_revive)
	if(L != host_mob)
		return

	info_log("Revived [full_heal == TRUE ? "(full heal)" : ""]")
	write_data("DEATH_STATE", "ALIVE")
	write_data("PREDEATH_STATE", "FALSE")
	write_log("Vital signals RESTORED", "SYNC")

// ---------------------------------------------------------------------------
// Ghost Callback
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_mob_ghostize(mob/M, can_reenter, special, penalize)
	if(M != host_mob)
		return

	warn_log("Host ghostized [can_reenter == TRUE ? "(can re-enter)" : ""]")
	write_data("GHOST_STATE", "TRUE")

// ---------------------------------------------------------------------------
// Shock Callback
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_living_electrocuted(mob/living/L, shock_damage, source, siemens_coeff, flags)
	if(L != host_mob)
		return

	write_log("Electrocuted: [shock_damage] damage [siemens_coeff ? "(siemens: [siemens_coeff])" : ""]", "HEALTH")
	write_data("SHOCK_DAMAGE", "[shock_damage]")
	write_log("Electrical damage applied", "ALERT")

/datum/component/neural_interface/proc/on_living_minor_shock(mob/living/L)
	if(L != host_mob)
		return

	warn_log("Minor shock received")
	write_data("MINOR_SHOCK", "TRUE")

// ---------------------------------------------------------------------------
// Damage Apply Callback
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_mob_apply_damage(mob/living/L, damage, damagetype, def_zone, wound_bonus, bare_wound_bonus, sharpness)
	if(L != host_mob)
		return

	if(!auto_monitor_health)
		return

	var/damage_log = "Damage: [damage] [damagetype] on [def_zone]"
	write_log(damage_log, "HEALTH")
	write_data("LAST_DAMAGE", "[damage]")
	write_data("LAST_DAMAGE_TYPE", "[damagetype]")
	write_data("LAST_DAMAGE_ZONE", "[def_zone]")

	// Log critical damage thresholds
	if(damage > 30)
		write_log("Significant damage applied!", "ALERT")
	else if(damage > 15)
		warn_log("Moderate damage applied")

// ---------------------------------------------------------------------------
// Client Reconnect - Re-attach display
// ---------------------------------------------------------------------------
/datum/component/neural_interface/proc/on_client_reconnect(client/C)
	if(!host_mob)
		return

	attached_client = C
	is_client_attached = TRUE

	if(logs_view)
		if(host_mob?.client)
			host_mob.client.screen += logs_view
		write_log("Client reconnected - display restored", "SYNC")

		if(visible)
			logs_view.maptext = ""
			compile_display()

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
