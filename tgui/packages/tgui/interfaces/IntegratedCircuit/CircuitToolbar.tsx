import { classes } from 'common/react';
import { ReactNode } from 'react';

import { Box, Button, Icon, Input, Stack } from '../../components';
import type { IeCloneCopyMode, IntegratedCircuitData } from './types';

/** Keep assembly-only actions separate from the shared wiremod editor. */
export const getCircuitToolbarProps = (
  data: IntegratedCircuitData,
  act: (action: string) => void,
) => {
  const isIe = !!data.ie_circuit;
  const battery = isIe ? data.ie_battery_percent : data.circuit_cell_percent;
  return {
    showVariableChip: !isIe,
    ieBatteryPercent: isIe ? battery : undefined,
    circuitCellPercent: isIe ? undefined : battery,
    ieUsedSize: isIe ? data.ie_used_size : undefined,
    ieMaxSize: isIe ? data.ie_max_size : undefined,
    ieUsedComplexity: isIe ? data.ie_used_complexity : undefined,
    ieMaxComplexity: isIe ? data.ie_max_complexity : undefined,
    ieCloneCopyMode: isIe ? data.ie_clone_copy_mode : null,
    onEjectPowerCell: typeof battery === 'number'
      ? () => act(isIe ? 'ie_eject_battery' : 'eject_circuit_cell')
      : undefined,
    onIeClassicUi: isIe ? () => act('ie_switch_classic_ui') : undefined,
    onIeCloneCopy: isIe && data.ie_clone_copy_mode
      ? () => act(data.ie_clone_copy_mode === 'assembly'
        ? 'ie_copy_assembly_code' : 'ie_copy_component_code')
      : undefined,
  };
};

export type CircuitToolbarProps = {
  circuitOn?: boolean | number;
  componentCount: number;
  variableCount?: number;
  zoomPercent: number;
  showVariableChip?: boolean;
  /** Wiremod cell charge % (null = no cell, undefined = field absent). */
  circuitCellPercent?: number | null;
  /** IE assembly battery charge % (null = no battery, undefined = field absent). */
  ieBatteryPercent?: number | null;
  ieCloneCopyMode?: IeCloneCopyMode | null;
  onIeCloneCopy?: () => void;
  onIeClassicUi?: () => void;
  onIePlaceChipCenter?: () => void;
  onEjectPowerCell?: () => void;
  onFitToView?: () => void;
  ieUsedSize?: number | null;
  ieMaxSize?: number | null;
  ieUsedComplexity?: number | null;
  ieMaxComplexity?: number | null;
  /** Spotlight: строка поиска по имени компонента (подсветка на схеме). */
  searchValue?: string;
  onSearchChange?: (value: string) => void;
  componentsPanelOpen?: boolean;
  onToggleComponents?: () => void;
  helpOpen?: boolean;
  onToggleHelp?: () => void;
};

type ChipTone = 'on' | 'off' | 'muted' | 'danger';

const Chip = (props: {
  icon: string;
  tone?: ChipTone;
  title?: string;
  children: ReactNode;
}) => {
  const { icon, tone = 'muted', title, children } = props;
  return (
    <Box
      className={classes([
        'IntegratedCircuit__chip',
        `IntegratedCircuit__chip--${tone}`,
      ])}
      title={title}>
      <Icon name={icon} />
      <span>{children}</span>
    </Box>
  );
};

/**
 * Верхняя панель: состояние платы, счётчики, лимиты корпуса и действия.
 * Ключевая информация слева, действия справа; без дублирующих подписей.
 */
export const CircuitToolbar = (props: CircuitToolbarProps) => {
  const {
    circuitOn,
    componentCount,
    variableCount = 0,
    zoomPercent,
    showVariableChip = true,
    circuitCellPercent,
    ieBatteryPercent,
    ieCloneCopyMode,
    onIeCloneCopy,
    onIeClassicUi,
    onIePlaceChipCenter,
    onEjectPowerCell,
    onFitToView,
    ieUsedSize,
    ieMaxSize,
    ieUsedComplexity,
    ieMaxComplexity,
    searchValue = '',
    onSearchChange,
    componentsPanelOpen,
    onToggleComponents,
    helpOpen,
    onToggleHelp,
  } = props;

  const powered = circuitOn !== false && circuitOn !== 0;
  const showIeLimits = typeof ieUsedSize === 'number'
    && typeof ieUsedComplexity === 'number';

  const sizeFull = typeof ieMaxSize === 'number' && ieUsedSize! >= ieMaxSize;
  const complexityFull = typeof ieMaxComplexity === 'number'
    && ieUsedComplexity! >= ieMaxComplexity;

  const limitSuffix = (used: number, max: number | null | undefined) =>
    typeof max === 'number' ? `${used} / ${max}` : String(used);

  return (
    <Box className="IntegratedCircuit__toolbar">
      <Stack vertical>
        <Stack.Item>
          <Stack align="center" wrap>
            <Stack.Item>
              <Chip icon="power-off" tone={powered ? 'on' : 'off'}>
                {showVariableChip ? (powered ? 'Включено' : 'Выключено') : 'Редактор схемы'}
              </Chip>
            </Stack.Item>
            <Stack.Item>
              <Chip icon="microchip">
                Компонентов: <b>{componentCount}</b>
              </Chip>
            </Stack.Item>
            {showIeLimits && (
              <Stack.Item>
                <Chip
                  icon="cubes"
                  tone={sizeFull ? 'danger' : 'muted'}
                  title="Сумма размеров микросхем / запас корпуса">
                  Размер {limitSuffix(ieUsedSize!, ieMaxSize)}
                </Chip>
              </Stack.Item>
            )}
            {showIeLimits && (
              <Stack.Item>
                <Chip
                  icon="project-diagram"
                  tone={complexityFull ? 'danger' : 'muted'}
                  title="Сумма сложности микросхем / лимит корпуса">
                  Сложность {limitSuffix(ieUsedComplexity!, ieMaxComplexity)}
                </Chip>
              </Stack.Item>
            )}
            {ieBatteryPercent !== undefined && (
              <Stack.Item>
                <Stack align="center">
                  <Chip
                    icon="battery-half"
                    tone={ieBatteryPercent === null || ieBatteryPercent <= 20 ? 'danger' : 'on'}
                    title="Элемент питания в отсеке батареи">
                    Батарея{' '}
                    {ieBatteryPercent === null ? 'нет' : `${ieBatteryPercent}%`}
                  </Chip>
                  {ieBatteryPercent !== null && onEjectPowerCell && (
                    <Button
                      icon="eject"
                      color="transparent"
                      compact
                      tooltip="Извлечь батарею"
                      onClick={onEjectPowerCell}
                    />
                  )}
                </Stack>
              </Stack.Item>
            )}
            {circuitCellPercent !== undefined && (
              <Stack.Item>
                <Stack align="center">
                  <Chip icon="battery-half" tone={circuitCellPercent === null || circuitCellPercent <= 20 ? 'danger' : 'on'}>
                    Ячейка{' '}
                    {circuitCellPercent === null ? 'нет' : `${circuitCellPercent}%`}
                  </Chip>
                  {circuitCellPercent !== null && onEjectPowerCell && (
                    <Button
                      icon="eject"
                      color="transparent"
                      compact
                      tooltip="Извлечь ячейку"
                      onClick={onEjectPowerCell}
                    />
                  )}
                </Stack>
              </Stack.Item>
            )}
            {showVariableChip && (
              <Stack.Item>
                <Chip icon="database">
                  Переменных: <b>{variableCount}</b>
                </Chip>
              </Stack.Item>
            )}
          </Stack>
        </Stack.Item>
        <Stack.Item>
          <Stack align="center" wrap className="IntegratedCircuit__tools">
            {onIePlaceChipCenter && (
              <Stack.Item>
                <Button icon="plus" onClick={onIePlaceChipCenter}
                  tooltip="Вставить микросхему из руки в центр поля. Shift + клик по полю — вставить в выбранное место.">
                  Вставить чип
                </Button>
              </Stack.Item>
            )}
            <Stack.Item>
              <Button icon="list-ul" selected={componentsPanelOpen}
                color="transparent" onClick={onToggleComponents}>
                Компоненты
              </Button>
            </Stack.Item>
            {onSearchChange && (
              <Stack.Item>
                <Input
                  width="13rem"
                  placeholder="Найти имя или номер…"
                  value={searchValue}
                  onInput={(e, value) => onSearchChange(value)}
                />
              </Stack.Item>
            )}
            {onFitToView && (
              <Stack.Item>
                <Button
                  icon="expand"
                  color="transparent"
                  compact
                  tooltip="Вписать все компоненты в поле"
                  onClick={onFitToView}>
                  Показать всё
                </Button>
              </Stack.Item>
            )}
            <Stack.Item>
              <Chip icon="search-plus" title="Текущий масштаб поля">
                {zoomPercent}%
              </Chip>
            </Stack.Item>
            {(ieCloneCopyMode === 'assembly' || ieCloneCopyMode === 'chip')
              && onIeCloneCopy && (
                <Stack.Item>
                  <Button
                    icon="copy"
                    color="transparent"
                    compact
                    tooltip={
                      ieCloneCopyMode === 'assembly'
                        ? 'JSON сборки для принтера'
                        : 'JSON одного чипа'
                    }
                    onClick={onIeCloneCopy}>
                    Экспорт JSON
                  </Button>
                </Stack.Item>
              )}
            {onIeClassicUi && (
              <Stack.Item>
                <Button
                  icon="window-restore"
                  color="transparent"
                  compact
                  tooltip="Классический интерфейс"
                  onClick={onIeClassicUi}>
                  Старый интерфейс
                </Button>
              </Stack.Item>
            )}
            <Stack.Item>
              <Button icon="question-circle" color="transparent"
                selected={helpOpen} onClick={onToggleHelp}>
                Как пользоваться
              </Button>
            </Stack.Item>
          </Stack>
        </Stack.Item>
      </Stack>
    </Box>
  );
};
