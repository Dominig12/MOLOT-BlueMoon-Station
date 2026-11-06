# NetDM module for BlueMoon SS13 (net-feature-new)

## Device topology (automatic)

The game network models **station APC areas**, not the power cable
structure. All normal /obj/machinery instances automatically get an
endpoint; embedded power terminals are skipped, since their APC is the
actual network node.

- **APC**: wired endpoint and radio access point for mobile devices.
  Two APCs have a direct wired link **only when their distinct power
  areas share a border of cardinally adjacent turfs on the same Z-level**.
  A gap, diagonal contact, or merely being on the same map is not
  sufficient. Linked sub-areas use their shared root APC.
- **Anchored machinery, including regular and modular consoles**: a
  wired endpoint with one uplink to the APC registered as
  `get_area(machine).base_area?.power_apc` (or the area's own APC).
  The link is updated when a machine moves or is reanchored.
  Machines in an area with no APC remain present but disconnected.
- **Portable modular computers**: PDA, tablet and item-based laptop
  automatically use the spatial radio medium, channel 1, range 14.
  Console-internal `/obj/item/modular_computer/processor` does **not**
  create a duplicate network node.
- **Unanchored machinery**: automatically switches to radio; when
  reanchored it reconnects to the area's APC.

Subtypes `/apc/netdm` and `/console/netdm` remain aliases for
mapping compatibility, not special opt-in devices. Other kinds of
handheld items can still explicitly call `netdm_connect()`.

- **Between sectors**: operational `/obj/machinery/ntnet_relay`
  machines provide the inter-sector backbone. A single available relay
  per sector participates in a sparse chain to other sectors with an
  operational relay. Powered-off, EMP-disabled, broken or DoS-crashed
  relays stop carrying the inter-sector link. The sector identity is
  taken from `SSmapping.space_grid` and its declarations; for legacy
  maps without sector declarations, each Z-level is treated as a sector.
  Relays attach to their own area's APC, so a sector with no connected
  relay/zone does not gain a magical direct APC connection.

The `SSnetdm` reconciliation pass updates area membership, position,
and anchoring in bounded groups. A separate, bounded border scan
examines APC areas in chunks of 256 contents per fire on topology
changes and builds only real neighboring-area edges. Ordinary devices
are still sent incrementally using acknowledged Host batches.
No link is inferred from electrical cables or NTNet's global
communication datum; only the NTNet relay machines' operational status
is reused.

## Deployment

Put `netdm_byond.dll` beside DreamDaemon's `.dmb`, run the
separate x64 `NetDM.Host` locally, and start SS13. The bridge attempts
to enable automatically while the DLL is available; Host may start
later. Use `SSnetdm.disable_bridge()` to pause or
`SSnetdm.enable_bridge()` to resume.

Open `http://127.0.0.1:5087` and select **SS13 · LIVE GAME** to see
the real APC backbone, area-based wired links, radio domain cells,
and device positions, including new devices spawned during the round.

## Game payloads

An object can retrieve its component through `netdm_interface()`
and send a payload via `endpoint.send_to(target, payload)`. The
binary Host routes only packet size/metadata. DM retains the actual
bounded payload and dispatches it after a Delivered receipt through
`netdm_receive(payload, sender, request_id)`, reporting transport
state via `netdm_delivery(request_id, state, reason)`.
A transport receipt is not an application-level acknowledgement.

The Host and bridge are local trusted-development processes, not a
multi-server service. There is no automatic retry for gameplay
operations that might execute twice.

The boundary scan stops after publishing a stable topology and restarts
only when APCs or relays change, when an APC moves, or when an area-swap
notification invalidates a controller. This avoids rewalking the map on
every subsystem tick.

APC uplinks also compare actual space-sector identities, so a root
area reused on different map sectors cannot silently produce a wired
inter-sector shortcut; such traffic must go through the local Relay.

When an APC changes coordinates/area or a relay changes its operational
state, obsolete managed backbone links are disconnected immediately.
The bounded area rescan only adds links that remain valid afterward.


## First networked gameplay service: R&D

R&D servers of the same research network (same /datum/techweb) now
register in a round-scoped logical /datum/netdm_rnd_cluster. The cluster
owns the authoritative research points, unlocked nodes, research
designs and a bounded deduplication cache (512 mutation request IDs).
Any active member can respond; if all members are offline, clients
cannot issue or read networked R&D operations.

The techweb_holder component acts as the generic NetDM RPC client:
- request_snapshot() reads research points, nodes, unlocked designs,
  availability and prices from an operational server.
- request_research() purchases one research node on the server only,
  after transport delivery and server-side revalidation of its cost.
- request_add_design(), request_upload_tech(), request_upload_designs()
  and request_download_tech() use the same request/response path.
- Device updates are sent only on application replies; transport
  "delivered" is not considered a successful research operation.

R&D consoles render their network snapshots and send node-unlock and
disk operations through the protocol. Fabricators download the designs
snapshot through NetDM into their *local* production cache. If the
Host, route, APC, relay or entire server cluster is unavailable, new
mutations are rejected and existing downloaded recipes can remain
cached locally. Mutating requests are not automatically resent:
the server cluster caches recent request IDs to prevent double-spending
if a response is lost or a request reaches another member.

This is the initial service integration, not yet a full migration of
every legacy research subsystem. Other callers which mutate a raw
datum/techweb directly (e.g. legacy analyzers/boost scripts) must
be migrated to explicit R&D RPCs in subsequent changes. Shared techweb
data is currently one in-process authoritative database per logical
cluster, not durable per-server disk replicas across DreamDaemon
restarts. The Host still routes byte-count metadata, while gameplay
payloads stay in DM.


The nanite program hub is also a snapshot reader: it lists and
downloads only designs in the latest research snapshot delivered via
NetDM. The hub's refresh button asks the server for a new snapshot.
All legacy networked device types can use techweb_holder.request_snapshot()
and the typed request_* helpers without implementing their own pipe
transport.
