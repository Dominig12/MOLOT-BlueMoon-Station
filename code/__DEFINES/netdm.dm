// netDM node declarations. The world reports where a node is and how it is mounted;
// netDM decides between a wired APC port and radio.

/// A stationary machine: while anchored on a turf of an APC-served zone it takes a wired port to that APC.
#define NETDM_MOUNT_FIXED "fixed"
/// A mobile device: always radio, even while anchored.
#define NETDM_MOUNT_MOBILE "mobile"
/// Default radio range of a networked machine, in tiles. Zero means the node has no radio.
#define NETDM_NODE_RADIO_RANGE 7
/// Radio range of the access point built into every APC, in tiles.
#define NETDM_APC_ACCESS_RANGE 7
/// Upper bound of radio ranges accepted by the Host.
#define NETDM_MAX_RADIO_RANGE 128

/// Node state flags reported to netDM. A node carries traffic only with both; without them it keeps
/// its identity and attachment but has no links.
#define NETDM_STATE_POWERED (1<<0)
#define NETDM_STATE_OPERATIONAL (1<<1)
#define NETDM_STATE_UP (NETDM_STATE_POWERED | NETDM_STATE_OPERATIONAL)

/// Targets of one PDA message the network carries at most; a larger fanout keeps the legacy path.
#define NETDM_MESSENGER_FANOUT 8
/// Longest PDA presentation text the message schema carries.
#define NETDM_MESSENGER_TEXT 4000

/// Source tag of the traits the network immersion applies to the body left at the access point.
#define NETDM_IMMERSION_TRAIT "netdm_immersion"

/// Emitted by a service lane after the Host accepts an endpoint attachment: (datum/node).
#define COMSIG_NETDM_ENDPOINT_ATTACHED "netdm_endpoint_attached"
