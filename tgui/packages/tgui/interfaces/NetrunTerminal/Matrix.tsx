import { memo, useCallback, useMemo } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Stack } from '../../components';
import { MatrixState, NetrunData, THEME } from './types';

const LIME = '#d8ff4a';

/** Головоломка-сетка: игрок выбирает клетки по очереди в строке и столбце */
export const MatrixPanel = (props: { state: MatrixState }) => {
  const { act } = useBackend<NetrunData>();
  const signature = JSON.stringify(props.state);
  const state = useMemo(() => props.state, [signature]);
  return <MatrixView state={state} act={act} />;
};

const MatrixView = memo((props: { state: MatrixState; act: (action: string, payload?: object) => void }) => {
  const { state, act } = props;
  const rows = useMemo(() => Array.from({ length: state.size }, (_, row) =>
    Array.from({ length: state.size }, (_, column) => row * state.size + column)), [state.size]);
  const onPick = useCallback((index: number) => act('breach_pick', { index: index + 1 }), [act]);
  return (
    <Box p={1} style={{ background: THEME.bg, border: `1px solid ${LIME}55`, display: 'flex', flexDirection: 'column', width: '100%', height: '100%', minHeight: '220px', boxSizing: 'border-box', overflow: 'auto' }}>
      <Stack align="center" mb={1} style={{ flexShrink: 0 }}>
        <Stack.Item grow>
          <Box color={LIME} bold style={{ fontFamily: 'monospace' }}>
            {state.target}
          </Box>
          <Box color={THEME.muted} fontSize="11px">
            Сложность {state.security} · выбор в {state.pick_row ? 'строке' : 'столбце'}
          </Box>
        </Stack.Item>
        <Stack.Item>
          <Box
            fontSize="20px"
            style={{ fontFamily: 'monospace' }}
            color={state.time_left <= 10 ? THEME.bad : LIME}
          >
            {state.time_left}s
          </Box>
        </Stack.Item>
      </Stack>
      <Stack style={{ flex: '1 1 auto', minHeight: '160px', flexWrap: 'wrap' }}>
        <Stack.Item grow basis="50%" style={{ minWidth: '190px' }}>
          <table style={{ borderCollapse: 'collapse', width: '100%', height: '100%' }}>
            <tbody>
              {rows.map((row, r) => (
                <tr key={r}>
                  {row.map((index) => (
                    <GridCell
                      key={index}
                      code={state.cells[index].code}
                      active={state.cells[index].active}
                      index={index}
                      onPick={onPick}
                    />
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </Stack.Item>
        <Stack.Item grow basis="40%" ml={2} style={{ minWidth: '190px' }}>
          <Box color={THEME.muted} fontSize="11px" mb={0.5}>
            БУФЕР
          </Box>
          <Stack mb={1}>
            {Array.from({ length: state.buffer_size }).map((_, i) => (
              <Stack.Item key={i}>
                <Box
                  style={{
                    width: '28px',
                    height: '24px',
                    lineHeight: '24px',
                    textAlign: 'center',
                    fontFamily: 'monospace',
                    border: `1px dashed ${state.buffer[i] ? LIME : THEME.line}`,
                    color: LIME,
                  }}
                >
                  {state.buffer[i] || ''}
                </Box>
              </Stack.Item>
            ))}
          </Stack>
          <Box color={THEME.muted} fontSize="11px" mb={0.5}>
            ЦЕЛИ
          </Box>
          {state.daemons.map((goal) => (
            <Box key={goal.name} mb={0.5} style={{ fontFamily: 'monospace' }}>
              <Box inline color={goal.done ? THEME.good : THEME.text} mr={1}>
                {goal.sequence.join(' ')}
              </Box>
              <Box inline color={goal.done ? THEME.good : THEME.muted} fontSize="11px">
                {goal.done ? '✔ ' : ''}
                {goal.name}
              </Box>
            </Box>
          ))}
          <Button
            mt={1}
            icon="stop"
            color="bad"
            content="Завершить"
            onClick={() => act('breach_abort')}
          />
        </Stack.Item>
      </Stack>
    </Box>
  );
});

const GridCell = memo((props: {
  code: string | null;
  active: boolean;
  index: number;
  onPick: (index: number) => void;
}) => {
  const { code, active, index, onPick } = props;
  const clickable = active && !!code;
  return (
    <td
      onClick={clickable ? () => onPick(index) : undefined}
      style={{
        minWidth: '24px',
        minHeight: '24px',
        textAlign: 'center',
        fontFamily: 'monospace',
        fontSize: '14px',
        cursor: clickable ? 'pointer' : 'default',
        color: !code ? THEME.line : active ? LIME : THEME.muted,
        background: active ? 'rgba(216, 255, 74, 0.08)' : 'transparent',
        border: `1px solid ${active ? 'rgba(216, 255, 74, 0.3)' : 'transparent'}`,
      }}
    >
      {code || '[ ]'}
    </td>
  );
});
