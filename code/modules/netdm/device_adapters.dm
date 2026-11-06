/**
 * Explicit, opt-in NetDM-capable device variants.
 * The original master APCs/consoles are unchanged.
 */
/obj/machinery/power/apc/netdm
	name = "networked area power controller"

/obj/machinery/power/apc/netdm/Initialize(mapload, ndir, building = FALSE)
	. = ..()
	netdm_connect(14, 1, TRUE)

/obj/machinery/modular_computer/console/netdm
	name = "networked modular console"

/obj/machinery/modular_computer/console/netdm/Initialize(mapload)
	. = ..()
	netdm_connect(14, 1, TRUE)
