import type { DragEvent } from 'react';

import { Box, Button, Icon, Section, Stack } from '../../components';
import type { CircuitComponentView } from './types';

type Props = {
  componentCount: number;
  filteredComponents: { comp: CircuitComponentView; index: number }[];
  filterQuery: string;
  ieAssemblyUi: boolean;
  componentDragOver: number | null;
  selection: number[];
  setComponentsPanelOpen: (open: boolean) => void;
  setComponentsFilter: (value: string) => void;
  handleComponentDragStart: (event: DragEvent, index: number) => void;
  handleComponentDragOver: (event: DragEvent, index: number) => void;
  handleComponentDrop: (event: DragEvent, index: number) => void;
  handleComponentDragEnd: () => void;
  handleJumpToComponent: (comp: CircuitComponentView, index: number) => void;
};

export const CircuitComponentsPanel = (props: Props) => {
  const {
    componentCount, filteredComponents, filterQuery, ieAssemblyUi,
    componentDragOver, selection, setComponentsPanelOpen, setComponentsFilter,
    handleComponentDragStart, handleComponentDragOver, handleComponentDrop,
    handleComponentDragEnd, handleJumpToComponent,
  } = props;
  return (
    <Box
      className="IntegratedCircuit__componentsPanel"
      onMouseDown={(e) => e.stopPropagation()}>
      <Section
        title={`Компоненты (${componentCount})`}
        fill
        scrollable
        buttons={(
          <Button
            icon="times"
            color="transparent"
            tooltip="Закрыть список"
            onClick={() => setComponentsPanelOpen(false)}
          />
        )}>
        <Stack vertical>
          <Stack.Item>
            <Box className="IntegratedCircuit__panelHint">
              Нажмите, чтобы найти на схеме.
              {ieAssemblyUi && ' Перетащите строку, чтобы изменить порядок.'}
            </Box>
            {!!filterQuery && (
              <Button fluid icon="times" color="transparent"
                onClick={() => setComponentsFilter('')}>
                Сбросить поиск · {filteredComponents.length} найдено
              </Button>
            )}
          </Stack.Item>
          {filteredComponents.length === 0 && (
            <Stack.Item>
              <Box color="label" opacity={0.7} mt={0.5}>
                {componentCount === 0 ? 'Нет компонентов' : 'Ничего не найдено'}
              </Box>
            </Stack.Item>
          )}
          {filteredComponents.map(({ comp, index }) => (
            <Stack.Item key={index}>
              <Box
                className={
                  componentDragOver === index
                    ? 'IntegratedCircuit__componentRow IntegratedCircuit__componentRow--dragOver'
                    : 'IntegratedCircuit__componentRow'
                }
                draggable={ieAssemblyUi && comp.removable && !filterQuery}
                title={ieAssemblyUi && comp.removable && !filterQuery ? 'Перетащите, чтобы изменить порядок' : undefined}
                onDragStart={(e) => handleComponentDragStart(e, index)}
                onDragOver={(e) => handleComponentDragOver(e, index)}
                onDrop={(e) => handleComponentDrop(e, index)}
                onDragEnd={handleComponentDragEnd}>
                <Button
                  fluid
                  selected={selection.includes(index)}
                  color="transparent"
                  tooltip={`Перейти к «${comp.name}»`}
                  onClick={() => handleJumpToComponent(comp, index)}>
                  <Icon
                    name="circle"
                    color={comp.recent_pulse ? '#5dff8a' : (comp.color || 'blue')}
                  />
                  {' '}
                  #{index}
                  {' '}
                  {comp.name}
                </Button>
                <Box className="IntegratedCircuit__componentMeta">
                  {comp.input_ports.length} входов · {comp.output_ports.length} выходов
                  {!comp.removable && ' · встроенный'}
                </Box>
              </Box>
            </Stack.Item>
          ))}
        </Stack>
      </Section>
    </Box>
  );
};
