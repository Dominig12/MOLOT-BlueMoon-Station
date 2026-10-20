import { Window } from '../../layouts';
import { NetrunContent } from './Content';

export const NetrunTerminal = () => {
  return (
    <Window width={1040} height={780} theme="ntos">
      <Window.Content scrollable>
        <NetrunContent />
      </Window.Content>
    </Window>
  );
};
