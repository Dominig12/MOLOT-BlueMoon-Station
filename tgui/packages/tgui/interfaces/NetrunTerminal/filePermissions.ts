import type { NetFile } from './types';

export const SESSION_FILE_REASON = 'Только для текущего погружения';
export const isTransferableFile = (file: NetFile) => file.transferable !== false && !file.session_bound;
