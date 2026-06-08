// ============================================================================
// Neural Interface Auto-Monitor System
// ============================================================================
// Provides modular auto-monitoring capabilities that can be attached to
// neural interface component following OOP composition pattern
// ============================================================================

// ---------------------------------------------------------------------------
// Base Monitor - Abstract interface for all monitors
// ---------------------------------------------------------------------------
/datum/neural_monitor
	var/name = "DEFAULT MONITOR"
	var/datum/component/neural_interface/owner // datum/component/neural_interface
	var/atom/monitor_atom
	var/enabled = FALSE

/datum/neural_monitor/New(datum/component/neural_interface/owner_comp, atom/monitor_target)
	owner = owner_comp
	monitor_atom = monitor_target

	owner.system_log("INITIALIZE: [name]")

/datum/neural_monitor/proc/register_signals()
	// Override in child classes

/datum/neural_monitor/proc/unregister_signals()
	// Override in child classes

/datum/neural_monitor/proc/enable()
	enabled = TRUE
	owner.system_log("[name]: ENABLED")
	if(monitor_atom)
		register_signals()

/datum/neural_monitor/proc/disable()
	enabled = FALSE
	owner.system_log("[name]: DISABLED")
	if(monitor_atom)
		unregister_signals()

// ---------------------------------------------------------------------------
// Health Monitor - Tracks damage, status effects, death/revive
// ---------------------------------------------------------------------------
/datum/neural_monitor/health
	name = "HEALTH MONITOR"
	var/last_brute_damage = 0
	var/last_tox_damage = 0
	var/last_fire_damage = 0
	var/last_oxy_damage = 0
	var/last_stat = 0

/datum/neural_monitor/health/proc/update_health_data()
	if(!monitor_atom || !isliving(monitor_atom) || !iscarbon(monitor_atom))
		return

	var/mob/living/carbon/user = monitor_atom

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
		owner.write_log("Brute damage: [brute_loss]", "HEALTH")
	if(new_tox && (tox_loss - last_tox_damage) > 5)
		owner.write_log("Toxin damage: [tox_loss]", "HEALTH")
	if(new_fire && (fire_loss - last_fire_damage) > 5)
		owner.write_log("Burn damage: [fire_loss]", "HEALTH")
	if(new_oxy && (oxy_loss - last_oxy_damage) > 5)
		owner.write_log("Oxygen loss: [oxy_loss]", "HEALTH")

	// Update status display
	var/health_percent = user.health / user.maxHealth * 100
	var/status_text = "<b>[round(health_percent, 0.1)]</b>"

	if(user.stat == DEAD)
		status_text = "<span class='alert'><b>DESTROYED</b></span>"
	else if(health_percent < 25)
		status_text = "<span class='alert'><b>CRITICAL</b></span>"
	else if(health_percent < 50)
		status_text = "<span class='userdanger'><b>DANGER</b></span>"
	else if(health_percent < 75)
		status_text = "<span class='notice'><b>MINOR</b></span>"

	owner.write_data("STATUS", status_text)
	owner.write_data("BRUTE", "[brute_loss]")
	owner.write_data("TOKSIN", "[tox_loss]")
	owner.write_data("BURN", "[fire_loss]")
	owner.write_data("OXYGEN", "[oxy_loss]")

	// Store last values
	last_brute_damage = brute_loss
	last_tox_damage = tox_loss
	last_fire_damage = fire_loss
	last_oxy_damage = oxy_loss

/datum/neural_monitor/health/register_signals()
	if(!monitor_atom)
		return

	if(ishuman(monitor_atom))
		RegisterSignal(monitor_atom, COMSIG_CARBON_UPDATEHEALTH, PROC_REF(on_carbon_health_update))

	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_STUN, PROC_REF(on_living_stunned))
	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_KNOCKDOWN, PROC_REF(on_living_knockdown))
	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_PARALYZE, PROC_REF(on_living_paralyzed))
	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_UNCONSCIOUS, PROC_REF(on_living_unconscious))
	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_SLEEP, PROC_REF(on_living_sleeping))
	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_DAZE, PROC_REF(on_living_dazed))
	RegisterSignal(monitor_atom, COMSIG_LIVING_STATUS_STAGGER, PROC_REF(on_living_staggered))

	RegisterSignal(monitor_atom, COMSIG_MOB_DEATH, PROC_REF(on_mob_death))
	RegisterSignal(monitor_atom, COMSIG_LIVING_REVIVE, PROC_REF(on_living_revive))
	RegisterSignal(monitor_atom, COMSIG_LIVING_DEATH, PROC_REF(on_living_death))
	RegisterSignal(monitor_atom, COMSIG_LIVING_PREDEATH, PROC_REF(on_living_predeath))
	RegisterSignal(monitor_atom, COMSIG_MOB_APPLY_DAMAGE, PROC_REF(on_mob_apply_damage))

	RegisterSignal(monitor_atom, COMSIG_MOB_GHOSTIZE, PROC_REF(on_mob_ghostize))

/datum/neural_monitor/health/unregister_signals()
	if(!monitor_atom)
		return

	UnregisterSignal(monitor_atom, COMSIG_CARBON_UPDATEHEALTH)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_STUN)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_KNOCKDOWN)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_PARALYZE)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_UNCONSCIOUS)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_SLEEP)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_DAZE)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_STATUS_STAGGER)
	UnregisterSignal(monitor_atom, COMSIG_MOB_DEATH)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_REVIVE)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_DEATH)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_PREDEATH)
	UnregisterSignal(monitor_atom, COMSIG_MOB_APPLY_DAMAGE)
	UnregisterSignal(monitor_atom, COMSIG_MOB_GHOSTIZE)

/datum/neural_monitor/health/proc/on_carbon_health_update(mob/living/carbon/C)
	if(!enabled)
		return
	update_health_data()

/datum/neural_monitor/health/proc/on_living_stunned(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Stunned: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("STUN_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_living_knockdown(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Knocked down: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("KNOCKDOWN_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_living_paralyzed(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Paralyzed: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("PARALYZE_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_living_unconscious(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Unconscious: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("UNCONSCIOUS_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_living_sleeping(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Asleep: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("SLEEP_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_living_dazed(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Dazed: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("DAZE_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_living_staggered(mob/living/L, amount, update, ignore)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Staggered: [round(amount/10, 0.1)]s", "HEALTH")
	owner.write_data("STAGGER_REMAINING", "[round(amount/10, 0.1)]s")

/datum/neural_monitor/health/proc/on_mob_death(mob/M, gibbed)
	if(!enabled || M != monitor_atom)
		return
	owner.error_log("Mob death signal received")

/datum/neural_monitor/health/proc/on_living_death(mob/living/L, gibbed)
	if(!enabled || L != monitor_atom)
		return
	owner.error_log("Living death signal received [gibbed ? "(gibbed)" : ""]")
	owner.write_data("DEATH_STATE", "DIED")
	owner.write_log("Vital signals TERMINATED", "ALERT")

/datum/neural_monitor/health/proc/on_living_predeath(mob/living/L, gibbed)
	if(!enabled || L != monitor_atom)
		return
	owner.warn_log("Pre-death state [gibbed == TRUE ? "(gibbed)" : ""]")
	owner.write_data("PREDEATH_STATE", "TRUE")

/datum/neural_monitor/health/proc/on_living_revive(mob/living/L, full_heal, admin_revive)
	if(!enabled || L != monitor_atom)
		return
	owner.info_log("Revived [full_heal == TRUE ? "(full heal)" : ""]")
	owner.write_data("DEATH_STATE", "ALIVE")
	owner.write_data("PREDEATH_STATE", "FALSE")
	owner.write_log("Vital signals RESTORED", "SYNC")

/datum/neural_monitor/health/proc/on_mob_ghostize(mob/M, can_reenter, special, penalize)
	if(!enabled || M != monitor_atom)
		return
	owner.warn_log("Host ghostized [can_reenter == TRUE ? "(can re-enter)" : ""]")
	owner.write_data("GHOST_STATE", "TRUE")

/datum/neural_monitor/health/proc/on_mob_apply_damage(mob/living/L, damage, damagetype, def_zone, wound_bonus, bare_wound_bonus, sharpness)
	if(!enabled || L != monitor_atom)
		return
	var/damage_log = "Damage: [damage] [damagetype] on [def_zone]"
	owner.write_log(damage_log, "HEALTH")
	owner.write_data("LAST_DAMAGE", "[damage]")
	owner.write_data("LAST_DAMAGE_TYPE", "[damagetype]")
	owner.write_data("LAST_DAMAGE_ZONE", "[def_zone]")

	if(damage > 30)
		owner.write_log("Significant damage applied!", "ALERT")
	else if(damage > 15)
		owner.warn_log("Moderate damage applied")

// ---------------------------------------------------------------------------
// Wound Monitor - Tracks wounds gained/lost
// ---------------------------------------------------------------------------
/datum/neural_monitor/wound
	name = "WOUND MONITOR"

/datum/neural_monitor/wound/register_signals()
	if(!monitor_atom || !ishuman(monitor_atom))
		return
	RegisterSignal(monitor_atom, COMSIG_CARBON_GAIN_WOUND, PROC_REF(on_carbon_gain_wound))
	RegisterSignal(monitor_atom, COMSIG_CARBON_LOSE_WOUND, PROC_REF(on_carbon_lose_wound))

/datum/neural_monitor/wound/unregister_signals()
	if(!monitor_atom)
		return
	UnregisterSignal(monitor_atom, COMSIG_CARBON_GAIN_WOUND)
	UnregisterSignal(monitor_atom, COMSIG_CARBON_LOSE_WOUND)

/datum/neural_monitor/wound/proc/on_carbon_gain_wound(mob/living/carbon/C, datum/wound/W, obj/item/bodypart/L)
	if(!enabled)
		return
	var/wound_info = "Wound: [W.name] on [L.name]"
	owner.write_log(wound_info, "HEALTH")
	if(W.name)
		owner.write_data("ACTIVE_WOUND", W.name)

/datum/neural_monitor/wound/proc/on_carbon_lose_wound(mob/living/carbon/C, datum/wound/W, obj/item/bodypart/L)
	if(!enabled)
		return
	var/wound_info = "Healed: [W.name] on [L.name]"
	owner.write_log(wound_info, "HEALTH")

// ---------------------------------------------------------------------------
// Shock Monitor - Tracks electrical damage
// ---------------------------------------------------------------------------
/datum/neural_monitor/shock
	name = "SHOCK MONITOR"

/datum/neural_monitor/shock/register_signals()
	if(!monitor_atom)
		return
	RegisterSignal(monitor_atom, COMSIG_LIVING_ELECTROCUTE_ACT, PROC_REF(on_living_electrocuted))
	RegisterSignal(monitor_atom, COMSIG_LIVING_MINOR_SHOCK, PROC_REF(on_living_minor_shock))

/datum/neural_monitor/shock/unregister_signals()
	if(!monitor_atom)
		return
	UnregisterSignal(monitor_atom, COMSIG_LIVING_ELECTROCUTE_ACT)
	UnregisterSignal(monitor_atom, COMSIG_LIVING_MINOR_SHOCK)

/datum/neural_monitor/shock/proc/on_living_electrocuted(mob/living/L, shock_damage, source, siemens_coeff, flags)
	if(!enabled || L != monitor_atom)
		return
	owner.write_log("Electrocuted: [shock_damage] damage [siemens_coeff ? "(siemens: [siemens_coeff])" : ""]", "HEALTH")
	owner.write_data("SHOCK_DAMAGE", "[shock_damage]")
	owner.write_log("Electrical damage applied", "ALERT")

/datum/neural_monitor/shock/proc/on_living_minor_shock(mob/living/L)
	if(!enabled || L != monitor_atom)
		return
	owner.warn_log("Minor shock received")
	owner.write_data("MINOR_SHOCK", "TRUE")

// ---------------------------------------------------------------------------
// NTnet Monitor - Tracks NTNET packets
// ---------------------------------------------------------------------------
/datum/neural_monitor/nt_net
	name = "NTNET MONITOR"

/datum/neural_monitor/nt_net/register_signals()
	if(!monitor_atom)
		return
	RegisterSignal(monitor_atom, COMSIG_COMPONENT_NTNET_RECEIVE, PROC_REF(ob_packet_received))

/datum/neural_monitor/nt_net/unregister_signals()
	if(!monitor_atom)
		return
	UnregisterSignal(monitor_atom, COMSIG_COMPONENT_NTNET_RECEIVE)

/datum/neural_monitor/nt_net/proc/ob_packet_received(datum/source, datum/netdata/packet)
	owner.write_data("NTPACKET", "[packet.data["data"]]", 5 SECONDS)
