import { Window } from '../../layouts';
import { NetrunContent } from './Content';

export const NetrunTerminal = () => {
  return (
    <Window width={1280} height={800} theme="ntos">
      <Window.Content fitted>
        <NetrunContent />
      </Window.Content>
    </Window>
  );
};
