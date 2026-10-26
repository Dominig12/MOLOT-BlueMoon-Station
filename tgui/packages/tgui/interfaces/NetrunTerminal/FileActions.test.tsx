import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

import { act, fireEvent, render } from '@testing-library/react';
import { combineReducers, createStore, setGlobalStore } from 'common/redux';

import { backendReducer, backendUpdate } from '../../backend';
import { NodePanel } from './NodePanel';
import { StoragePanel } from './Panels';

// Sass is declared by the build workspace, not by the browser application.
const { compile, compileString } = createRequire(join(__dirname, '../../../../package.json'))('sass');

const file = (uid: string, kind: string) => ({
  uid, kind, name: `${uid}.${kind === 'text' ? 'txt' : 'link'}`, size: 1, preview: null,
});

const setup = () => {
  const topic = jest.fn();
  (global as any).Byond = { topic, winset: () => {} };
  const store = createStore(combineReducers({ backend: backendReducer }));
  setGlobalStore(store);
  store.dispatch(backendUpdate({ config: { interface: 'NetrunTerminal' }, data: {
    workspace_view: 'map', map: {}, networks: [], can_breach: false,
    entity: null, breach: null, locked: 0, file: null,
    storage: { used: 2, capacity: 10, files: [file('local-link', 'techweb_link'), file('local-note', 'text')] },
    shard: { name: 'Шард', used: 2, capacity: 10, files: [file('shard-link', 'techweb_link'), file('shard-note', 'text')] },
    selected: { address: 'SERVER', name: 'Сервер', network: 'RND', type: 'server',
      access: 3, legit: 3, online: true, security: 2, commands: [], status: [],
      files: [file('remote-link', 'techweb_link'), file('remote-note', 'text')] },
  } }));
  const panel = render(<div className="netrun-shell"><StoragePanel /><NodePanel /></div>);
  const sent = (action: string) => topic.mock.calls.filter(([message]) => message.type === `act/${action}`)
    .map(([message]) => JSON.parse(message.payload));
  const update = (data) => act(() => store.dispatch(backendUpdate({ data })));
  return { ...panel, sent, update };
};

let stylesheet: HTMLStyleElement;
beforeAll(() => {
  // Include native Button margins/line-height so the original grid-cell mismatch
  // is covered, rather than checking inline declarations without the real CSS.
  const styles = join(__dirname, '../../styles/components/Button.scss');
  const options = { logger: { warn: () => {}, debug: () => {} } };
  stylesheet = document.createElement('style');
  stylesheet.textContent = compile(styles, options).css
    + compileString(readFileSync(join(__dirname, 'netrun-workspace.scss'), 'utf8'), options).css;
  document.head.appendChild(stylesheet);
});
afterAll(() => stylesheet.remove());

test('local, shard and remote icon actions use the same centered square hit targets', () => {
  const { container } = setup();
  const groups = [...container.querySelectorAll<HTMLElement>('[data-net-file-actions]')];
  expect(groups.map((group) => group.dataset.netFileActions)).toEqual(['local', 'local', 'shard', 'shard', 'remote', 'remote']);
  for (const group of groups) {
    expect(getComputedStyle(group).alignItems).toBe('center');
    // Wrapper divs previously aligned upload to the top of its 24px grid cell.
    expect([...group.children].every((child) => child.classList.contains('Button'))).toBe(true);
    for (const button of group.querySelectorAll<HTMLElement>('.Button')) {
      const style = getComputedStyle(button);
      expect(style.display).toBe('inline-flex');
      expect(style.alignItems).toBe('center');
      expect(style.justifyContent).toBe('center');
      expect(style.width).toBe('24px');
      expect(style.height).toBe('24px');
      expect(style.marginBottom).toBe('0px');
      expect(style.marginRight).toBe('0px');
      expect(style.paddingTop).toBe('0px');
      expect(style.lineHeight).toBe('1');
      expect(getComputedStyle(button.querySelector('.Icon')).margin).toBe('0px');
    }
  }
});

test('a non-text local file retains its upload/delete columns and action clicks do not select the row', () => {
  const { container, sent } = setup();
  const group = container.querySelector<HTMLElement>('[data-net-file-actions="local"]');
  const upload = group.querySelector<HTMLElement>('.fa-upload').parentElement;
  const remove = group.querySelector<HTMLElement>('.fa-trash').parentElement;
  expect(group.querySelector('.fa-eye')).toBeNull();
  expect(upload.style.gridColumn).toBe('2');
  expect(remove.style.gridColumn).toBe('3');
  fireEvent.click(upload);
  fireEvent.click(remove);
  expect(sent('upload')).toEqual([{ uid: 'local-link' }]);
  expect(sent('delete_local')).toEqual([{ uid: 'local-link' }]);
  expect(sent('file_select')).toEqual([]);
});

test('shard and remote controls retain their file UIDs and unavailable upload leaves delete in the last column', () => {
  const { container, sent, update } = setup();
  const shard = container.querySelector<HTMLElement>('[data-net-file-actions="shard"]');
  fireEvent.click(shard.querySelector<HTMLElement>('.fa-upload').parentElement);
  fireEvent.click(shard.querySelector<HTMLElement>('.fa-trash').parentElement);
  expect(sent('upload')).toEqual([{ uid: 'shard-link' }]);
  expect(sent('delete_local')).toEqual([{ uid: 'shard-link' }]);
  expect(sent('file_select')).toEqual([]);
  const remote = container.querySelector<HTMLElement>('[data-net-file-actions="remote"]');
  fireEvent.click(remote.querySelector<HTMLElement>('.fa-sd-card').parentElement);
  fireEvent.click(remote.querySelector<HTMLElement>('.fa-trash').parentElement);
  expect(sent('download')).toEqual([{ uid: 'remote-link', to_shard: true }]);
  expect(sent('delete_remote')).toEqual([{ uid: 'remote-link' }]);
  update({ selected: null });
  const local = container.querySelector<HTMLElement>('[data-net-file-actions="local"]');
  expect(local.querySelector('.fa-upload')).toBeNull();
  expect(local.querySelector<HTMLElement>('.fa-trash').parentElement.style.gridColumn).toBe('3');
});
