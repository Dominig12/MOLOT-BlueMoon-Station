import { NetEdge, NetNode } from './types';

const STATIC_FIELDS: (keyof NetNode)[] = [
  'address', 'name', 'type', 'x', 'y', 'z', 'security', 'online', 'access',
  'uplink', 'apc', 'network', 'sector',
];
const GEOMETRY_FIELDS: (keyof NetNode)[] = ['address', 'type', 'x', 'y', 'z'];
const EDGE_FIELDS: (keyof NetEdge)[] = ['id', 'from', 'to', 'kind', 'online'];
const equalFields = <T, >(left: T, right: T, fields: (keyof T)[]) =>
  fields.every((field) => left[field] === right[field]);

/** Moving endpoints and occupants never replace the retained stationary render scene. */
export class StaticMapProjection {
  private generation: string | undefined;
  private snapshot = { nodes: [] as NetNode[], edges: [] as NetEdge[], geometry: 0 };

  update(nodes: NetNode[], edges: NetEdge[], generation?: string) {
    if (generation !== undefined && generation === this.generation) { return this.snapshot; }
    this.generation = generation;
    const previous = this.snapshot;
    const previousNodes = new Map(previous.nodes.map((node) => [node.address, node]));
    const stationary = nodes.filter((node) => !node.dynamic).map((node) => {
      const retained = previousNodes.get(node.address);
      return retained && equalFields(retained, node, STATIC_FIELDS) ? retained
        : { ...node, dynamic: false, entities: 0, ice: 0, active: false, can_hop: undefined };
    });
    const stationaryIds = new Set(stationary.map((node) => node.address));
    const previousEdges = new Map(previous.edges.map((edge) => [edge.id, edge]));
    const stationaryEdges = edges.filter((edge) => stationaryIds.has(edge.from) && stationaryIds.has(edge.to)).map((edge) => {
      const retained = previousEdges.get(edge.id);
      return retained && equalFields(retained, edge, EDGE_FIELDS) ? retained : edge;
    });
    const sameNodes = stationary.length === previous.nodes.length && stationary.every((node, i) => node === previous.nodes[i]);
    const sameEdges = stationaryEdges.length === previous.edges.length && stationaryEdges.every((edge, i) => edge === previous.edges[i]);
    if (sameNodes && sameEdges) { return previous; }
    const sameGeometry = stationary.length === previous.nodes.length
      && stationary.every((node, i) => equalFields(node, previous.nodes[i], GEOMETRY_FIELDS));
    this.snapshot = { nodes: sameNodes ? previous.nodes : stationary,
      edges: sameEdges ? previous.edges : stationaryEdges, geometry: previous.geometry + (sameGeometry ? 0 : 1) };
    return this.snapshot;
  }
}
