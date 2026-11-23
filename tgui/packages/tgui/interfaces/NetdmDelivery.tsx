import { Box, Button } from '../components';
import { DeviceEntry } from './NetdmDeviceState';

type Delivery = NonNullable<DeviceEntry['delivery']>;

const DELIVERY_LABELS: Record<Delivery['state'], [string, string]> = {
  queued: ['В очереди', 'label'],
  applied: ['Устройство приняло команду', 'teal'],
  delivered: ['Ответ получен', 'good'],
  rejected: ['Устройство отказало', 'bad'],
  not_delivered: ['Команда не доставлена', 'bad'],
  unknown: ['Исход неизвестен', 'average'],
};

export const DeliveryStatus = ({ delivery }: { delivery: Delivery }) => {
  const [label, color] = DELIVERY_LABELS[delivery.state];
  return (
    <Box color={color}>
      {label}
      {!!delivery.reason && <Box inline color="label" ml={0.5}>({delivery.reason})</Box>}
    </Box>
  );
};

export const NetdmDeliveryActivity = ({ entries, onSelect }: {
  entries: DeviceEntry[];
  onSelect: (instance: string) => void;
}) => {
  const recent = entries.filter(entry => entry.delivery).slice(-6).reverse();
  if (!recent.length) {
    return null;
  }
  return (
    <div className="NetdmDeliveryActivity">
      {recent.map(entry => entry.delivery && (
        <div className="NetdmDeliveryActivity__entry" key={entry.id}>
          <Button icon="crosshairs" onClick={() => entry.delivery && onSelect(entry.delivery.instance)}>
            {entry.delivery.instance}
          </Button>
          <DeliveryStatus delivery={entry.delivery} />
        </div>
      ))}
    </div>
  );
};
