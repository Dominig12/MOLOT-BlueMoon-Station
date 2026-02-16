/datum/circuit_variable
	var/name
	var/datatype
	var/color
	var/value

/datum/circuit_variable/New(_name, _datatype)
	name = _name
	datatype = _datatype
	color = "blue" // значение по умолчанию
	value = null

/datum/circuit_variable/proc/set_value(new_value)
	value = new_value
