import { NtosWindow } from '../layouts';
import { NetrunContent } from './NetrunTerminal/Content';

export const NtosNetrun = () => {
  return (
    <NtosWindow width={860} height={700}>
      <NtosWindow.Content scrollable>
        <NetrunContent />
      </NtosWindow.Content>
    </NtosWindow>
  );
};
