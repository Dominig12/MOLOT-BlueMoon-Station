/**
 * Compatibility aliases only: all /obj/machinery and ordinary
 * /obj/item/modular_computer devices now install NetDM automatically.
 * APC and fixed consoles use their zone's wired network; portable
 * items and unanchored machinery use the shared radio medium.
 */
/obj/machinery/power/apc/netdm
	name = "networked area power controller"

/obj/machinery/modular_computer/console/netdm
	name = "networked modular console"
