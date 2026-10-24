/// Discovery is a station machine, with the same power and cable dependencies as its clients.
/obj/machinery/netrun_server/dns
	name = "DNS server"
	desc = "Сервер адресов и служб станции. Обрабатывает запросы машин по физической сети."
	circuit = /obj/item/circuitboard/machine/netrun_dns
	server_security = 3

/obj/machinery/netrun_server/dns/netrun_machine_service_types()
	return ..() + list(/datum/netrun_machine_service/dns)

/obj/machinery/netrun_server/dns/netrun_status()
	. = ..()
	. += "Служба: DNS"
	. += "Зарегистрировано служб: [length(SSnetrun.get_machine_transport().services)]"

/datum/netrun_machine_service/dns
	service_id = "dns"

/obj/item/circuitboard/machine/netrun_dns
	name = "DNS Server (Machine Board)"
	icon_state = "science"
	build_path = /obj/machinery/netrun_server/dns
	req_components = list(
		/obj/item/stack/cable_coil = 2,
		/obj/item/stock_parts/matter_bin = 1,
		/obj/item/stock_parts/subspace/filter = 1)

/datum/design/board/netrun_dns
	name = "Machine Design (DNS Server)"
	desc = "Плата сервера адресов и обнаружения сетевых служб."
	id = "netrun_dns"
	build_path = /obj/item/circuitboard/machine/netrun_dns
	category = list("Research Machinery")
	departmental_flags = DEPARTMENTAL_FLAG_ENGINEERING | DEPARTMENTAL_FLAG_SCIENCE
