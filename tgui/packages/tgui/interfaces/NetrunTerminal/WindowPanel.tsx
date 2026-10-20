import { useBackend } from '../../backend';
import { Box, Button, Icon, Section } from '../../components';
import {
  ACCESS_COLORS,
  ACCESS_NAMES,
  MachineWindow,
  NetrunData,
  NODE_ICONS,
  THEME,
} from './types';

/** Окно машины: состояние, команды-запросы и особые действия (часть под взломом) */
export const WindowPanel = (props: { window: MachineWindow }) => {
  const { act } = useBackend<NetrunData>();
  const { window: w } = props;
  return (
    <Section
      title={w.title}
      fill
      scrollable
      buttons={
        <Box inline>
          <Icon name={NODE_ICONS[w.type] || 'window-maximize'} mr={1} />
          <Box inline color={ACCESS_COLORS[w.access]} mr={1}>
            {ACCESS_NAMES[w.access]}
          </Box>
          <Button icon="xmark" onClick={() => act('window_close', { address: w.address })} />
        </Box>
      }
    >
      {!w.online && (
        <Box color={THEME.bad} mb={1}>
          Узел не отвечает.
        </Box>
      )}
      {w.feed && (
        <Box
          mb={1}
          p={1}
          style={{
            background: '#05090d',
            border: `1px solid ${THEME.line}`,
            fontFamily: 'monospace',
            fontSize: '11px',
          }}
        >
          <Box color={w.watching ? THEME.good : THEME.muted} mb={0.5}>
            <Icon name="video" mr={1} />
            {w.watching ? 'ВЫ СМОТРИТЕ ЧЕРЕЗ КАМЕРУ' : 'Видеопоток'}
          </Box>
          {w.feed.map((line, i) => (
            <Box key={i}>— {line}</Box>
          ))}
        </Box>
      )}
      {w.fields.length > 0 && (
        <Box
          mb={1}
          p={1}
          style={{ background: THEME.bg, fontFamily: 'monospace', fontSize: '11px' }}
        >
          {w.fields.map((line, i) => (
            <Box key={i}>{line}</Box>
          ))}
        </Box>
      )}
      {w.extra.length > 0 && (
        <Box mb={1}>
          {w.extra.map((a) => (
            <Button
              key={a.id}
              icon={a.icon}
              content={a.name}
              color={a.danger ? 'bad' : undefined}
              disabled={!a.allowed}
              tooltip={a.desc}
              onClick={() => act('window_act', { address: w.address, waction: a.id })}
            />
          ))}
        </Box>
      )}
      <Box color={THEME.muted} fontSize="11px" mb={0.5}>
        Запросы
      </Box>
      {w.commands.map((cmd) => (
        <Button
          key={cmd.id}
          icon={cmd.icon}
          content={cmd.name}
          color={cmd.danger ? 'bad' : cmd.illegal ? 'average' : undefined}
          disabled={!cmd.allowed}
          tooltip={
            (cmd.desc ? `${cmd.desc} ` : '') +
            `Нужно: ${ACCESS_NAMES[cmd.access]}.` +
            (cmd.allowed && cmd.trace ? ` Трассировка +${cmd.trace}%.` : '')
          }
          onClick={() => act('window_act', { address: w.address, waction: cmd.id })}
        />
      ))}
    </Section>
  );
};
