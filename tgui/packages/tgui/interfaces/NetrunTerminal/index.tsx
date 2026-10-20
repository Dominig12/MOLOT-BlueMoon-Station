import { Window } from '../../layouts';
import { NetrunContent } from './Content';

export const NetrunTerminal = () => {
  return (
    <Window width={860} height={680} theme="ntos">
      <Window.Content scrollable>
        <NetrunContent />
      </Window.Content>
    </Window>
  );
};
