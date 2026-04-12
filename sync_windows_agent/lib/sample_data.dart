import 'models.dart';

const discoveredTables = <AgentTable>[
  AgentTable(
    name: 'dbo.Customers',
    keyColumn: 'CustomerId',
    changeColumn: 'ModifiedAt',
    rows: 14820,
    syncEnabled: true,
    syncStatus: 'Synced',
    lastSync: '10:00',
  ),
  AgentTable(
    name: 'dbo.Orders',
    keyColumn: 'OrderId',
    changeColumn: 'RowVersion',
    rows: 942120,
    syncEnabled: true,
    syncStatus: 'Synced',
    lastSync: '09:55',
  ),
  AgentTable(
    name: 'dbo.Inventory',
    keyColumn: 'SkuId',
    changeColumn: 'UpdatedAt',
    rows: 88014,
    syncEnabled: false,
    syncStatus: 'Paused',
    lastSync: '09:52',
  ),
  AgentTable(
    name: 'dbo.Invoices',
    keyColumn: 'InvoiceId',
    changeColumn: 'ModifiedAt',
    rows: 33187,
    syncEnabled: true,
    syncStatus: 'Retrying',
    lastSync: '09:48',
  ),
];

const recentEvents = <AgentEvent>[
  AgentEvent(
    time: '10:00',
    title: 'Plan received from domain',
    message:
        'finance-master-sync was refreshed and scheduled for every 5 minutes.',
    level: AgentEventLevel.info,
  ),
  AgentEvent(
    time: '09:55',
    title: 'Delta sync completed',
    message:
        'Orders and Inventory batches pushed to 2 sink agents successfully.',
    level: AgentEventLevel.info,
  ),
  AgentEvent(
    time: '09:52',
    title: 'Retry succeeded',
    message: 'Warehouse-01 reconnected after a temporary timeout.',
    level: AgentEventLevel.warning,
  ),
];
