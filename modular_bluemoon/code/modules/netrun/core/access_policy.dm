/// A LAN grant opens transport; a protected controller still owns its own authority.
/// These hooks apply only to runner access, never to native machine-service packets.
/atom/proc/netrun_inherited_access_cap()
	return NETRUN_ACCESS_ROOT

/// A protected endpoint first yields USER. ROOT requires a separate breach started
/// with USER already present. Native credentials and ownership are evaluated separately.
/atom/proc/netrun_breach_access_cap(initial_level)
	if(netrun_inherited_access_cap() <= NETRUN_ACCESS_GUEST && initial_level < NETRUN_ACCESS_USER)
		return NETRUN_ACCESS_USER
	return NETRUN_ACCESS_ROOT

/// Public policy belongs in the guest card, before the player starts a breach.
/atom/proc/netrun_access_policy_status()
	if(netrun_inherited_access_cap() <= NETRUN_ACCESS_GUEST)
		return "Критический узел: права ЛВС дают только ГОСТЯ. USER и ROOT требуют отдельных взломов."
	return null

/// A service may create the node before its target adapter; the floor also covers
/// that initialization order without replacing commands, ownership, or credentials.
/atom/proc/netrun_security_floor()
	return 1

/obj/machinery/power/apc/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/obj/machinery/power/apc/netrun_security_floor()
	return 3

/obj/machinery/ntnet_relay/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/obj/machinery/ntnet_relay/netrun_security_floor()
	return 5

/obj/machinery/telecomms/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/obj/machinery/telecomms/netrun_security_floor()
	return 4

/obj/machinery/rnd/server/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/obj/machinery/rnd/server/netrun_security_floor()
	return 5

/obj/machinery/computer/rdconsole/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/obj/machinery/computer/rdconsole/netrun_security_floor()
	return 4

/mob/living/silicon/ai/netrun_inherited_access_cap()
	return NETRUN_ACCESS_GUEST

/mob/living/silicon/ai/netrun_security_floor()
	return 5
