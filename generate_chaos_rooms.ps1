$basePath = "C:\Users\DaniilAliskandarov\Documents\GitHub\MOLOT-BlueMoon-Station\_maps\chaosdimension"

# Cold room templates
$coldIcons = @("cold_floor", "cold_frost", "cold_ice", "cold_dark", "cold_frozen", "cold_crystal", "cold_snow", "cold_glacier", "cold_blizzard", "cold_arctic", "cold_tundra", "cold_frostbite", "cold_hypothermia", "cold_aurora", "cold_northern")
$biome = "cold"
$area = "chaosdimension/cold"

for($i = 1; $i -le 15; $i++) {
    $filename = "$basePath\room_cold_$([string]::Format('{0:D2}', $i)).dmm"
    $icon = $coldIcons[($i - 1) % $coldIcons.Length]
    
    $content = @"
//MAP CONVERTED BY dmm2tgm.py THIS HEADER COMMENT PREVENTS RECONVERSION, DO NOT REMOVE
"ar" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"aC" = (
/obj/structure/chill_aura{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"b" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"c" = (
/obj/structure/frost_symbol{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"d" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"@
    Set-Content -Path $filename -Value $content -Encoding UTF8
}

# Warm room templates
$warmIcons = @("warm_floor", "warm_mist", "warm_haze", "warm_glow", "warm_ember", "warm_spirit", "warm_dream", "warm_lavender", "warm_sunset", "warm_twilight", "warm_dusk", "warm_candle", "warm_honey", "warm_autumn", "warm_fall")
$biome = "warm"
$area = "chaosdimension/warm"

for($i = 1; $i -le 15; $i++) {
    $filename = "$basePath\room_warm_$([string]::Format('{0:D2}', $i)).dmm"
    $icon = $warmIcons[($i - 1) % $warmIcons.Length]
    
    $content = @"
//MAP CONVERTED BY dmm2tgm.py THIS HEADER COMMENT PREVENTS RECONVERSION, DO NOT REMOVE
"ar" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"aC" = (
/obj/structure/warmth_aura{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"b" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"c" = (
/obj/structure/warm_symbol{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"d" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"@
    Set-Content -Path $filename -Value $content -Encoding UTF8
}

# Empty room templates
$emptyIcons = @("empty_floor", "empty_cracked", "empty_ruin", "empty_dark", "empty_void", "empty_abandoned", "empty_desolate", "empty_barren", "empty_wasteland", "empty_rubble", "empty_dust", "empty_faded", "empty_shattered", "empty_decayed", "empty_collapsed")
$biome = "empty"
$area = "chaosdimension/empty"

for($i = 1; $i -le 15; $i++) {
    $filename = "$basePath\room_empty_$([string]::Format('{0:D2}', $i)).dmm"
    $icon = $emptyIcons[($i - 1) % $emptyIcons.Length]
    
    $content = @"
//MAP CONVERTED BY dmm2tgm.py THIS HEADER COMMENT PREVENTS RECONVERSION, DO NOT REMOVE
"ar" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"aC" = (
/obj/structure/decay_aura{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"b" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"c" = (
/obj/structure/empty_symbol{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"d" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/$area)
"@
    Set-Content -Path $filename -Value $content -Encoding UTF8
}

# Boss room templates
$bossIcons = @("boss_floor", "boss_ritual", "boss_chamber", "boss_throne", "boss_altar", "boss_crypt", "boss_sanctum", "boss_dungeon", "boss_cavern", "boss_void", "boss_awakening", "boss_apocalypse", "boss_judgment", "boss_eclipse", "boss_transformation")

for($i = 1; $i -le 15; $i++) {
    $filename = "$basePath\boss_room_$([string]::Format('{0:D2}', $i)).dmm"
    $icon = $bossIcons[($i - 1) % $bossIcons.Length]
    
    $content = @"
//MAP CONVERTED BY dmm2tgm.py THIS HEADER COMMENT PREVENTS RECONVERSION, DO NOT REMOVE
"ar" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/chaosdimension/boss)
"aC" = (
/obj/structure/boss_throne{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/chaosdimension/boss)
"b" = (
/obj/structure/boss_pedestal{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/chaosdimension/boss)
"c" = (
/obj/structure/boss_altar{
	icon_state = "$icon"
	},
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/chaosdimension/boss)
"d" = (
/turf/open/floor/engine{
	icon_state = "$icon"
	},
/area/chaosdimension/boss)
"@
    Set-Content -Path $filename -Value $content -Encoding UTF8
}

Write-Host "Generated [15] cold room templates"
Write-Host "Generated [15] warm room templates"
Write-Host "Generated [15] empty room templates"
Write-Host "Generated [15] boss room templates"
Write-Host "Total: 60 room templates"