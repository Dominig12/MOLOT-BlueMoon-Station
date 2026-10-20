import { useState } from 'react';

import { useBackend } from '../../backend';
import { Box, Button, Input } from '../../components';
import { ACCESS_NAMES, MachineWindow, NetrunData, THEME } from './types';

type Remote = NonNullable<MachineWindow['remote']>;

const LABELS: Record<string, string> = {
  name: 'Название', status: 'Состояние', locked: 'Блокировка',
  active: 'Активен', enabled: 'Включено', power: 'Питание',
  charge: 'Заряд', mode: 'Режим', pressure: 'Давление',
  temperature: 'Температура', contents: 'Содержимое', amount: 'Количество',
  network: 'Сеть', address: 'Адрес', error: 'Ошибка',
};

/** Data only: native actions are declared and validated by the machine adapter. */
export const RemotePanel = (props: { address: string; remote: Remote }) => (
  <Box mt={1}>
    <Box bold mb={0.5}>Управление машиной · {props.remote.interface}</Box>
    <Box p={1} mb={1} style={{ background: THEME.bg, maxHeight: '300px', overflowY: 'auto' }}>
      <DataTree value={props.remote.data} depth={0} />
    </Box>
    {props.remote.actions.map((action) => (
      <RemoteAction key={action.id} address={props.address} action={action} />
    ))}
  </Box>
);

const DataTree = (props: { value: unknown; depth: number }) => {
  const { value, depth } = props;
  if (value === null || value === undefined) {
    return <span>—</span>;
  }
  if (typeof value !== 'object') {
    return <span>{typeof value === 'boolean' ? (value ? 'Да' : 'Нет') : String(value)}</span>;
  }
  if (depth > 5) {
    return <span>{JSON.stringify(value)}</span>;
  }
  const entries = Object.entries(value);
  if (!entries.length) {
    return <Box color={THEME.muted}>Нет данных.</Box>;
  }
  return (
    <div style={{ overflowWrap: 'anywhere' }}>
      {entries.map(([key, entry]) => {
        const label = Array.isArray(value) ? `#${Number(key) + 1}` : LABELS[key] || key.replace(/_/g, ' ');
        return entry && typeof entry === 'object' ? (
          <details key={key} open={depth < 1} style={{ marginLeft: depth ? '8px' : 0 }}>
            <summary>{label}</summary>
            <DataTree value={entry} depth={depth + 1} />
          </details>
        ) : (
          <Box key={key} mb={0.25}>
            <Box inline color={THEME.muted}>{label}: </Box>
            <DataTree value={entry} depth={depth + 1} />
          </Box>
        );
      })}
    </div>
  );
};

const RemoteAction = (props: { address: string; action: Remote['actions'][number] }) => {
  const { act } = useBackend<NetrunData>();
  const { action } = props;
  const params = action.params ?? [];
  const [values, setValues] = useState<Record<string, string>>({});
  return (
    <Box mb={0.5}>
      {params.map((param) => (
        <Box key={param.id} inline mr={0.5} mb={0.5}>
          <Box inline mr={0.5}>{param.name}</Box>
          <Input
            width="130px"
            value={values[param.id] ?? param.value ?? (param.type === 'number' ? String(param.min ?? 1) : '')}
            disabled={!action.allowed}
            onInput={(_event, value) => setValues({ ...values, [param.id]: value })}
          />
        </Box>
      ))}
      <Button
        icon="paper-plane"
        content={action.name}
        disabled={!action.allowed}
        color={action.danger ? 'bad' : undefined}
        tooltip={`${action.desc || ''} Нужно: ${ACCESS_NAMES[action.access]}.`}
        onClick={() => {
          const args: Record<string, string | number> = {};
          for (const param of params) {
            const value = values[param.id] ?? param.value ?? (param.type === 'number' ? String(param.min ?? 1) : '');
            args[param.id] = param.type === 'number' ? Number(value) : value;
          }
          act('remote_act', { address: props.address, request: action.id, arguments: args });
        }}
      />
    </Box>
  );
};
