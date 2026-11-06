# NetDM module for BlueMoon SS13 (net-feature-new)

This module was implemented **from the clean master branch**, not from
NetRun. It does not modify the existing NTNet implementation or the
powernet. No existing station machine is registered automatically.

## Pieces

- \`SSnetdm\` (\`code/controllers/subsystem/netdm.dm\`): network object
  registry, physical links, bounded topology changes, bounded polling,
  packet-result correlation, and position synchronization. Uses small
  batches per SS13 subsystem fire; no network IO blocks a game tick.
- \`/datum/component/netdm_node\`: opt-in network endpoint for any
  \`/atom/movable\`; auto register/unregister. A device's position is
  reconciled incrementally (32 endpoints per subsystem fire).
- \`/datum/netdm_bridge\`: wraps the native Win32 DLL's five \`call_ext\`
  exports. Uses the external x64 NetDM.Host's game graph.
- \`/obj/machinery/power/apc/netdm\` and
  \`/obj/machinery/modular_computer/console/netdm\`: explicit example
  device subtypes, with ordinary APCs and modular consoles unchanged.

The NetDM bridge's Win32 DLL is **not checked into the SS13 repo**.
Obtain its tested artifact from NetDM.Core
[PR #25](https://github.com/Dominig12/netDM-core/pull/25) and place
\`netdm_byond.dll\` where BYOND DreamDaemon can load/trust it. Run the
separate NetDM.Host x64 on the same Windows machine. The bridge connects
via \`\\\\.\\pipe\\netdm-core\`. See
[backend documentation](https://github.com/Dominig12/netDM-core/blob/feature/byond-native-bridge/docs/byond-bridge.md).

The native adapter is **disabled by default** to allow normal DM
compilation and ordinary SS13 rounds without any external DLL. Enable
after deploying the binary:

\`\`\`dm
SSnetdm.enable_bridge()
\`\`\`

To stop:

\`\`\`dm
SSnetdm.disable_bridge()
\`\`\`

These are intentionally backend setup calls, not player verbs.

## Register objects and create links

\`\`\`dm
var/obj/machinery/device_a = ... // any initialized movable
var/obj/machinery/device_b = ...
var/datum/component/netdm_node/a = device_a.netdm_connect(14, 1, TRUE)
var/datum/component/netdm_node/b = device_b.netdm_connect(14, 1, TRUE)

// The external game medium can now find local wireless routes.
// Explicit physical cable links are also supported:
SSnetdm.connect_nodes(a, b, 1)
SSnetdm.disconnect_nodes(a, b)
\`\`\`

To get a component without installing a duplicate:

\`\`\`dm
var/datum/component/netdm_node/node = device_a.netdm_interface()
\`\`\`

When deleting an object, its component unregisters from SSnetdm and
physical links are released. Movement sync uses a bounded incremental
position pass. The wire/radio topology is independent from NTNet.

## Send a game payload

\`\`\`dm
var/list/message = list("type" = "ping", "value" = "hello")
var/datum/netdm_transaction/transaction = a.send_to(b, message, 96, TRUE, 30)
if(!transaction)
    // Bridge unavailable, syncing, invalid nodes or local capacity full.
    return
\`\`\`

NetDM.Host currently transports **packet size and route**, not arbitrary
game payload bytes. Therefore \`payload\` remains inside DreamDaemon's
bounded transaction table. It is dispatched to the local recipient
**only after** the external packet returns a terminal Delivered receipt.
Override these DM callbacks on your objects:

\`\`\`dm
/obj/machinery/my_networked_machine/netdm_receive(list/payload,
    datum/component/netdm_node/sender, request_id)
    if(payload["type"] == "ping")
        // Process the incoming message in DM.
        return

/obj/machinery/my_networked_machine/netdm_delivery(request_id, state, reason)
    // state: delivered | rejected | failed | unknown.
    // Transport Delivered is not an ACK that an action was executed.
    return
\`\`\`

The callbacks are dispatched asynchronously after the subsystem
processes its bounded mailbox. Do not assume reception if a command was
merely added to the local shim queue or if \`packet_send\` was accepted
by Host. In-flight transactions are marked \`unknown\` on disconnect,
cursor loss or mailbox overflow. They are **not resent** automatically
because duplicate execution could be unsafe.

## Current limits and next steps

1. No automatic mapping of all APCs, power cables or existing NTNet
   devices. The two example subtypes and component API are a safe
   opt-in foundation; device-specific adapters will follow.
2. Reconnection replays registered nodes and links and offline
   deletion tombstones in command order. It does **not** yet replace
   an arbitrary pre-existing Host graph from a *different SS13 process
   lifetime*. Restart NetDM.Host together with the SS13 round for
   complete cleanup, until a versioned authoritative \`game_reset\`
   or snapshot-replace protocol is added.
3. The payload stays local in one DreamDaemon process. Remote SS13
   servers, content-addressed payload streams, application ACKs,
   gameplay authorization and idempotent request deduplication remain
   future work.
4. The low-level x86 ABI has been tested using a real Windows x86
   harness from NetDM.Core, **not yet compiled/executed in DreamDaemon**
   for this particular SS13 branch. BYOND DM compilation and runtime
   validation remain necessary on the server.


## Observatory · live SS13 map

The independent Host game graph appears in the existing observatory at
`http://127.0.0.1:5087` using **SS13 · LIVE GAME** in Topology explorer.
Select a BYOND Z level and press FIT. The visualizer shows the physical
links and radio domain cells without mixing benchmark graph data.

Initial synchronization now sends `game_reset` followed by acknowledged
batches of up to 48 changes. This avoids a 4096-command startup queue.
Changes during snapshot upload force a new reconciliation pass and failed
batches or lost acknowledgements trigger an automatic retry. The Host
and the game graph are designed for a single trusted SS13 server.
