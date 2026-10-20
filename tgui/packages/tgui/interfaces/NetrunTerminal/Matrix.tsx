import { useBackend } from '../../backend';
import { Box, Button, Stack } from '../../components';
import { MatrixState, NetrunData, THEME } from './types';

const LIME = '#d8ff4a';

/** Головоломка-сетка: игрок выбирает клетки по очереди в строке и столбце */
export const MatrixPanel = (props: { state: MatrixState }) => {
  const { act } = useBackend<NetrunData>();
  const { state } = props;
  const rows: number[][] = [];
  for (let r = 0; r < state.size; r++) {
    const row: number[] = [];
    for (let c = 0; c < state.size; c++) {
      row.push(r * state.size + c);
    }
    rows.push(row);
  }
  return (
    <Box p={1} style={{ background: THEME.bg, border: `1px solid ${LIME}55` }}>
      <Stack align="center" mb={1}>
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
      <Stack>
        <Stack.Item>
          <table style={{ borderCollapse: 'collapse' }}>
            <tbody>
              {rows.map((row, r) => (
                <tr key={r}>
                  {row.map((index) => (
                    <GridCell
                      key={index}
                      code={state.cells[index].code}
                      active={state.cells[index].active}
                      onClick={() => act('breach_pick', { index: index + 1 })}
                    />
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </Stack.Item>
        <Stack.Item grow ml={2}>
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
};

const GridCell = (props: {
  code: string | null;
  active: boolean;
  onClick: () => void;
}) => {
  const { code, active, onClick } = props;
  const clickable = active && !!code;
  return (
    <td
      onClick={clickable ? onClick : undefined}
      style={{
        width: '34px',
        height: '28px',
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
};
