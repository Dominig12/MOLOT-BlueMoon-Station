import { NtosWindow } from '../layouts';
import { NetrunContent } from './NetrunTerminal/Content';

export const NtosNetrun = () => {
  return (
    <NtosWindow width={1040} height={800}>
      <NtosWindow.Content scrollable>
        <NetrunContent />
      </NtosWindow.Content>
    </NtosWindow>
  );
};
