/**
 * The authority behind a network-space view, independent of the physical device
 * that opened it. The default implementation is deliberately NOT an actor:
 * it cannot send a packet, issue a world action, or expose a UI to anyone.
 *
 * An autonomous network entity can eventually provide its own long-lived,
 * authenticated endpoint and UI policy here. Nothing in this base class
 * creates an endpoint or bypasses ServiceRuntime.
 */
/datum/netdm_space_actor
	/// At most one interactive view; owned by the actor, but never kept alive by its window.
	var/datum/netdm_space/window

/datum/netdm_space_actor/proc/attach_window(datum/netdm_space/space)
	if(QDELETED(src) || !space || QDELETED(space) || (window && window != space))
		return FALSE
	window = space
	return TRUE

/datum/netdm_space_actor/proc/release_window(datum/netdm_space/space)
	if(window != space)
		return FALSE
	window = null
	return TRUE

/datum/netdm_space_actor/proc/can_submit()
	return FALSE

/datum/netdm_space_actor/proc/network_node()
	return null

/datum/netdm_space_actor/proc/shell_provider()
	return null

/datum/netdm_space_actor/proc/send_guard()
	return CALLBACK(src, PROC_REF(can_submit))

/// Always use the original Host command path and an endpoint-specific guard.
/datum/netdm_space_actor/proc/send(command, list/arguments, datum/callback/on_answer, datum/callback/can_send)
	if(QDELETED(src) || !can_submit())
		return FALSE
	var/datum/node = network_node()
	var/provider = shell_provider()
	var/datum/netdm_diagnostics/diagnostics = SSnetdm_observe?.diagnostics
	if(!node || !provider || !diagnostics)
		return FALSE
	return diagnostics.queue_shell_request(node, provider, command, arguments, on_answer, can_send || send_guard())

/datum/netdm_space_actor/proc/ui_host(mob/user)
	return src

/datum/netdm_space_actor/proc/ui_state(mob/user)
	return GLOB.never_state

/datum/netdm_space_actor/proc/ui_status(mob/user, datum/ui_state/state)
	return UI_CLOSE

/datum/netdm_space_actor/proc/title()
	return "нет связи"

/datum/netdm_space_actor/proc/physical_device()
	return null

/datum/netdm_space_actor/proc/physical_body()
	return null

/datum/netdm_space_actor/proc/neural_implant()
	return null

/datum/netdm_space_actor/proc/can_operate_alarm(mob/living/user)
	return FALSE

/// Closing a view detaches the presence, but never grants new authority.
/datum/netdm_space_actor/proc/on_window_close(datum/netdm_space/space, list/last_presence)
	if(window != space)
		return
	if(last_presence && last_presence["state"] != "ended" && last_presence["status"] != "none")
		space.send("detach", list("note" = "window"),
			CALLBACK(SSnetdm_observe.diagnostics, TYPE_PROC_REF(/datum/netdm_diagnostics, space_ignored)))

/**
 * Compatibility adapter for an ordinary APC, PDA, console or implant terminal.
 * It retains the terminal's original access checks and its actual endpoint.
 * No second transport, surrogate endpoint, or fallback path exists.
 */
/datum/netdm_space_actor/terminal
	var/datum/netdm_terminal/terminal

/datum/netdm_space_actor/terminal/New(datum/netdm_terminal/source)
	terminal = source
	return ..()

/datum/netdm_space_actor/terminal/Destroy()
	terminal = null
	return ..()

/datum/netdm_space_actor/terminal/attach_window(datum/netdm_space/space)
	if(!terminal || QDELETED(terminal) || (terminal.space && terminal.space != space) || !..())
		return FALSE
	terminal.space = space
	return TRUE

/datum/netdm_space_actor/terminal/release_window(datum/netdm_space/space)
	if(terminal?.space == space)
		terminal.space = null
	return ..()

/datum/netdm_space_actor/terminal/can_submit()
	return !QDELETED(terminal) && terminal?.can_submit()

/datum/netdm_space_actor/terminal/network_node()
	return terminal?.node_ref?.resolve()

/datum/netdm_space_actor/terminal/shell_provider()
	return terminal?.shell_provider()

/datum/netdm_space_actor/terminal/send_guard()
	return terminal?.send_guard() || ..()

/datum/netdm_space_actor/terminal/ui_host(mob/user)
	return terminal?.ui_host(user) || src

/datum/netdm_space_actor/terminal/ui_state(mob/user)
	return terminal ? terminal.ui_state(user) : GLOB.never_state

/datum/netdm_space_actor/terminal/ui_status(mob/user, datum/ui_state/state)
	return terminal && !QDELETED(terminal) ? terminal.ui_status(user, state) : UI_CLOSE

/datum/netdm_space_actor/terminal/title()
	return terminal ? terminal.device_title(physical_device()) : "нет связи"

/datum/netdm_space_actor/terminal/physical_device()
	return terminal?.device_ref?.resolve()

/datum/netdm_space_actor/terminal/physical_body()
	var/datum/netdm_terminal/local/local_terminal = terminal
	return local_terminal?.user_ref?.resolve()

/datum/netdm_space_actor/terminal/neural_implant()
	var/obj/item/implant/netdm_terminal/implant = physical_device()
	return istype(implant) ? implant : null

/// Physical alarm actions retain all existing human access and APC checks.
/datum/netdm_space_actor/terminal/can_operate_alarm(mob/living/user)
	if(!istype(user) || !user.client || user.stat || user.incapacitated() || !can_submit() || ui_status(user, ui_state(user)) != UI_INTERACTIVE)
		return FALSE
	var/obj/machinery/power/apc/apc = physical_device()
	return !istype(apc) || SSnetdm_observe.diagnostics?.terminal_access(apc, user)

/datum/netdm_space_actor/terminal/on_window_close(datum/netdm_space/space, list/last_presence)
	if(window != space)
		return
	var/datum/netdm_apc_operator/operator = network_node()
	if(istype(operator))
		// The durable APC operator, not a destroyed window, owns delayed detach.
		operator.detach_needed = TRUE
		return
	return ..()
