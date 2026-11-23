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

/datum/netdm_space_actor/Destroy()
	// A retired digital actor must not leave an orphaned, still-refreshing UI.
	var/datum/netdm_space/space = window
	window = null
	if(space && !QDELETED(space))
		qdel(space)
	return ..()

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

/datum/netdm_space_actor/ui_host(mob/user)
	return src

/datum/netdm_space_actor/ui_state(mob/user)
	return GLOB.never_state

/datum/netdm_space_actor/ui_status(mob/user, datum/ui_state/state)
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
	return istype(local_terminal) ? local_terminal.user_ref?.resolve() : null

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

GLOBAL_DATUM(netdm_entity_spawner, /obj/effect/mob_spawn/netdm_entity)
GLOBAL_DATUM(netdm_player_entity, /datum/netdm_space_actor/entity)

/// The entity's entry endpoint uses the published APC wire ID and has its own Host identity.
/datum/netdm_apc_operator/entity/authorized()
	var/mob/dead/netdm_entity/controller = user_ref?.resolve()
	return !QDELETED(src) && !QDELETED(apc_ref?.resolve()) && controller?.client && \
		controller.client == operator_client && operator_client.mob == controller

/datum/netdm_space_actor/entity
	var/datum/netdm_apc_operator/entity/entry
	var/datum/weakref/controller_ref
	var/entered = FALSE

/datum/netdm_space_actor/entity/New(mob/dead/netdm_entity/controller, obj/machinery/power/apc/apc, client/owner)
	. = ..()
	controller_ref = WEAKREF(controller)
	entry = new(SSnetdm_observe.diagnostics, null, apc, controller)
	entry.operator_client = owner
	if(!SSnetdm_observe.services?.endpoint_for(entry))
		QDEL_NULL(entry)

/datum/netdm_space_actor/entity/Destroy()
	if(GLOB.netdm_player_entity == src)
		GLOB.netdm_player_entity = null
	QDEL_NULL(entry)
	controller_ref = null
	return ..()

/datum/netdm_space_actor/entity/proc/owns_view(mob/user)
	return !QDELETED(src) && user && user == controller_ref?.resolve() && \
		user.client && user.client == entry?.operator_client && user.client.mob == user

/datum/netdm_space_actor/entity/ui_host(mob/user)
	return controller_ref?.resolve()

/datum/netdm_space_actor/entity/ui_state(mob/user)
	// The actor is the full guard. There is no physical location for TGUI to test.
	return GLOB.always_state

/datum/netdm_space_actor/entity/ui_status(mob/user, datum/ui_state/state)
	return owns_view(user) ? UI_INTERACTIVE : UI_CLOSE

/datum/netdm_space_actor/entity/can_submit()
	return SSticker?.IsRoundInProgress() && SSnetdm_observe?.published && entry?.authorized()

/datum/netdm_space_actor/entity/network_node()
	return entry

/datum/netdm_space_actor/entity/shell_provider()
	return entry?.apc_ref?.resolve()

/datum/netdm_space_actor/entity/title()
	return "Сетевая сущность"

/datum/netdm_space_actor/entity/on_window_close(datum/netdm_space/space, list/last_presence)
	// The entity still exists while its window is closed. Leaving the role retires its endpoint.
	return

/datum/netdm_space_actor/entity/proc/open_network(mob/dead/netdm_entity/controller)
	if(!owns_view(controller))
		return FALSE
	var/datum/netdm_space/space = window || new /datum/netdm_space(src)
	if(!space.ui_interact(controller))
		qdel(space)
		return FALSE
	if(!entered && space.enter())
		entered = TRUE
		space.scan(3)
	return TRUE

/// A client holder in nullspace. The controlled character lives in the network, without ghost verbs.
/mob/dead/netdm_entity
	name = "сетевая сущность"
	real_name = "сетевая сущность"
	density = FALSE
	anchored = TRUE
	invisibility = INVISIBILITY_ABSTRACT
	var/datum/netdm_space_actor/entity/role
	var/leaving_role = FALSE

/mob/dead/netdm_entity/Login()
	. = ..()
	if(client && role)
		INVOKE_ASYNC(role, TYPE_PROC_REF(/datum/netdm_space_actor/entity, open_network), src)

/mob/dead/netdm_entity/Logout()
	. = ..()
	QDEL_NULL(role)
	QDEL_IN(src, 1)

/mob/dead/netdm_entity/Destroy()
	QDEL_NULL(role)
	return ..()

/mob/dead/netdm_entity/Move(NewLoc, direct, glide_size_override)
	return FALSE

/mob/dead/netdm_entity/forceMove(atom/destination)
	return FALSE

/mob/dead/netdm_entity/verb/open_network()
	set name = "Открыть сеть"
	set category = "Сеть"
	role?.open_network(src)

/mob/dead/netdm_entity/verb/leave_network_role()
	set name = "Покинуть сетевую роль"
	set category = "Сеть"
	if(tgui_alert(src, "Вернуться к наблюдению? Сетевая сущность исчезнет.", "Сетевая роль", list("Да", "Нет")) == "Да")
		return_to_observer()

/mob/dead/netdm_entity/proc/return_to_observer()
	if(!client || leaving_role)
		return FALSE
	leaving_role = TRUE
	var/mob/dead/observer/observer = ghostize(FALSE)
	if(!observer)
		leaving_role = FALSE
		return FALSE
	qdel(src)
	return TRUE

/// A virtual option in the shared spawner listings for ghosts and lobby players.
/obj/effect/mob_spawn/netdm_entity
	name = "network entity entry"
	job_description = "Сетевая сущность"
	mob_name = "сетевая сущность"
	mob_type = /mob/dead/netdm_entity
	short_desc = "Самостоятельная роль внутри сети станции."
	flavour_text = "Обнаруживайте узлы, проверяйте маршруты, подключайтесь к сервисам и взламывайте АПЦ из сетевого пространства."
	important_info = "У сущности нет тела. Выход из роли возвращает в наблюдатели."
	banType = ROLE_GHOSTROLE
	roundstart = FALSE
	death = FALSE
	var/datum/weakref/entry_ref

/obj/effect/mob_spawn/netdm_entity/Destroy()
	if(GLOB.netdm_entity_spawner == src)
		GLOB.netdm_entity_spawner = null
	return ..()

/obj/effect/mob_spawn/netdm_entity/can_latejoin()
	var/obj/machinery/power/apc/apc = entry_ref?.resolve()
	return SSticker?.IsRoundInProgress() && SSnetdm_observe?.published && QDELETED(GLOB.netdm_player_entity) && \
		!QDELETED(apc) && SSnetdm_observe.apc_node_id(apc) && apc.netdm_state() == NETDM_STATE_UP

/obj/effect/mob_spawn/netdm_entity/allow_spawn(mob/user, silent = FALSE)
	if(!can_latejoin() || !user?.client || !user.ckey || user.key[1] == "@" || is_antag_training_atom(user))
		return FALSE
	if(jobban_isbanned(user, banType))
		if(!silent)
			to_chat(user, span_warning("Доступ к гост-ролям ограничен."))
		return FALSE
	return isnewplayer(user) || (isobserver(user) && user.can_reenter_round(silent))

/obj/effect/mob_spawn/netdm_entity/attack_ghost(mob/user, latejoinercalling)
	if((isnewplayer(user) && !latejoinercalling) || !allow_spawn(user))
		return FALSE
	var/client/owner = user.client
	var/choice = tgui_alert(user, "Стать сетевой сущностью? При выходе вы вернётесь в наблюдатели.", "Сетевая роль", list("Да", "Нет"))
	if(choice != "Да" || QDELETED(src) || QDELETED(user) || user.client != owner || !allow_spawn(user))
		return FALSE
	var/obj/machinery/power/apc/apc = entry_ref.resolve()
	var/mob/dead/netdm_entity/controller = new(null)
	var/datum/netdm_space_actor/entity/source = new(controller, apc, owner)
	if(!source.entry)
		qdel(source)
		qdel(controller)
		to_chat(user, span_warning("Сеть пока не может создать сущность."))
		return FALSE
	GLOB.netdm_player_entity = source
	controller.role = source
	var/mob/dead/new_player/lobby = user
	if(istype(lobby))
		lobby.spawning = TRUE
		lobby.close_spawn_windows()
		lobby.stop_sound_channel(CHANNEL_LOBBYMUSIC)
	log_game("[key_name(user)] занял роль сетевой сущности.")
	user.transfer_ckey(controller)
	if(owner.mob != controller)
		qdel(controller)
		if(istype(lobby) && !QDELETED(lobby))
			lobby.spawning = FALSE
		return FALSE
	qdel(src)
	return TRUE

/datum/netdm_diagnostics/proc/update_entity_spawner()
	if(world.time < next_entity_spawner_check)
		return
	next_entity_spawner_check = world.time + 5 SECONDS
	var/datum/netdm_space_actor/entity/entity = GLOB.netdm_player_entity
	if(entity)
		var/mob/dead/netdm_entity/controller = entity.controller_ref?.resolve()
		if(!controller?.client)
			qdel(entity)
		else if(QDELETED(entity.entry) || !SSticker?.IsRoundInProgress())
			INVOKE_ASYNC(controller, TYPE_PROC_REF(/mob/dead/netdm_entity, return_to_observer))
		return
	if(GLOB.netdm_entity_spawner?.can_latejoin())
		return
	QDEL_NULL(GLOB.netdm_entity_spawner)
	if(!SSnetdm_observe?.published || !SSticker?.IsRoundInProgress())
		return
	for(var/obj/machinery/power/apc/apc as anything in GLOB.apcs_list)
		if(QDELETED(apc) || !is_station_level(apc.z) || is_antag_training_atom(apc) || \
				!SSnetdm_observe.apc_node_id(apc) || apc.netdm_state() != NETDM_STATE_UP)
			continue
		var/obj/effect/mob_spawn/netdm_entity/spawner = new(null)
		spawner.entry_ref = WEAKREF(apc)
		GLOB.netdm_entity_spawner = spawner
		break
