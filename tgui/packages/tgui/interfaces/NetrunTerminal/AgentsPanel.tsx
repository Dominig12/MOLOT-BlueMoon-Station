import { memo } from 'react';

import { Box, Button } from '../../components';
import { Meter } from './CombatPanel';
import { BotAvatar, botKindLabel } from './EntityContacts';
import { AgentState, NetrunData, THEME } from './types';
import { useNetrunBackend as useBackend } from './useNetrunBackend';

const AgentCard = (props: { agent: AgentState; selected: string | null; act: (action: string, payload?: object) => void }) => {
  const { agent, selected, act } = props;
  return (
    <Box p={1} mb={0.5} data-net-agent={agent.bot_kind}
      style={{ background: THEME.bg, border: `1px solid ${THEME.line}`, borderRadius: '6px' }}>
      <Box bold>
        <BotAvatar kind={agent.bot_kind} faction="owner" size={24} />
        {agent.name}
        <Box inline ml={1} fontSize="11px" color={THEME.muted}>{botKindLabel(agent.bot_kind)}</Box>
      </Box>
      <Box fontSize="11px" color={THEME.muted}>
        {agent.node ? `${agent.node_name || ''} ${agent.node}` : 'вне сети'} · {agent.state}
      </Box>
      {!!agent.goal && <Box fontSize="11px">Задача: {agent.goal}</Box>}
      <Meter value={agent.integrity} max={agent.max_integrity} label={`Целостность ${agent.name}`} height={4}
        style={{ margin: '4px 0' }} />
      <Box fontSize="10px" color={THEME.muted}>
        Целостность {agent.integrity}/{agent.max_integrity} · память {agent.storage.used}/{agent.storage.capacity}
      </Box>
      <Box mt={0.5} style={{ display: 'flex', flexWrap: 'wrap', gap: '4px' }}>
        {agent.orders.map((order) => {
          const blocked = order.needs_node && !selected;
          return (
            <Button key={order.id} compact content={order.name} disabled={blocked}
              color={order.id === 'terminate' ? 'bad' : undefined}
              tooltip={blocked ? 'Сначала выберите узел на карте.' : undefined}
              onClick={() => act('agent_order', { ref: agent.ref, order: order.id, address: order.needs_node ? selected : undefined })} />
          );
        })}
      </Box>
    </Box>
  );
};

/** Agents launched from `.bot` files by this console. */
const AgentsPanelView = () => {
  const { act, data } = useBackend<NetrunData>(['agents', 'selected']);
  const agents = data.agents ?? [];
  if (!agents.length) {
    return null;
  }
  return (
    <Box mt={2} data-net-agents>
      <Box bold mb={0.5} color={THEME.text}>Агенты</Box>
      {agents.map((agent) => (
        <AgentCard key={agent.ref} agent={agent} selected={data.selected?.address ?? null} act={act} />
      ))}
    </Box>
  );
};

export const AgentsPanel = memo(AgentsPanelView);
