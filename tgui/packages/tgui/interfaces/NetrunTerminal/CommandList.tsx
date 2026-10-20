import { Box, Button } from '../../components';
import { ACCESS_NAMES, NetCommand, THEME } from './types';

/** The same command metadata and access explanation in a card and machine tab. */
export const CommandList = (props: {
  commands: NetCommand[];
  onCommand: (id: string) => void;
  disabled?: boolean;
}) => {
  const { commands, onCommand, disabled } = props;
  if (!commands.length) {
    return (
      <Box color={THEME.muted}>
        Нет доступных запросов. Получите доступ к узлу или проверьте связь.
      </Box>
    );
  }
  return (
    <Box style={{ display: 'flex', flexWrap: 'wrap', gap: '4px' }}>
      {commands.map((command) => (
        <Button
          key={command.id}
          icon={command.icon}
          content={command.name}
          color={command.danger ? 'bad' : command.illegal ? 'average' : undefined}
          disabled={disabled || !command.allowed}
          tooltip={
            (command.help || command.desc || '') + '\n' +
            `Нужно: ${ACCESS_NAMES[command.access]}.` +
            (command.allowed && command.trace
              ? ` Трассировка +${command.trace}%.`
              : '')
          }
          onClick={() => onCommand(command.id)}
        />
      ))}
    </Box>
  );
};
