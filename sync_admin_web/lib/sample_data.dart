import 'models.dart';

const machines = <MachineNode>[
  MachineNode(
    id: 'finance-hq',
    name: 'Finance-HQ',
    clientName: 'Finance Client',
    office: 'Berlin HQ',
    sqlInstance: r'SQL01\FINANCE',
    isOnline: true,
    lastHeartbeat: '14 seconds ago',
    tags: ['source-ready', 'windows-agent', 'change-tracking'],
  ),
  MachineNode(
    id: 'warehouse-01',
    name: 'Warehouse-01',
    clientName: 'Warehouse Client',
    office: 'Hamburg Warehouse',
    sqlInstance: r'SQL02\OPS',
    isOnline: true,
    lastHeartbeat: '31 seconds ago',
    tags: ['sink-ready', 'windows-agent'],
  ),
  MachineNode(
    id: 'branch-07',
    name: 'Branch-07',
    clientName: 'Branch Client',
    office: 'Munich Branch',
    sqlInstance: r'SQL03\BRANCH',
    isOnline: true,
    lastHeartbeat: '52 seconds ago',
    tags: ['sink-ready', 'metered-link'],
  ),
  MachineNode(
    id: 'backup-node',
    name: 'Backup-Node',
    clientName: 'Backup Client',
    office: 'Disaster Recovery',
    sqlInstance: r'SQL04\DR',
    isOnline: false,
    lastHeartbeat: '7 minutes ago',
    tags: ['standby', 'sink-ready'],
  ),
];

const tables = <TableProfile>[
  TableProfile(
    name: 'dbo.Customers',
    primaryKey: 'CustomerId',
    changeColumn: 'ModifiedAt',
    estimatedRows: 14820,
  ),
  TableProfile(
    name: 'dbo.Orders',
    primaryKey: 'OrderId',
    changeColumn: 'RowVersion',
    estimatedRows: 942120,
  ),
  TableProfile(
    name: 'dbo.OrderLines',
    primaryKey: 'OrderLineId',
    changeColumn: 'RowVersion',
    estimatedRows: 3287712,
  ),
  TableProfile(
    name: 'dbo.Inventory',
    primaryKey: 'SkuId',
    changeColumn: 'UpdatedAt',
    estimatedRows: 88014,
  ),
  TableProfile(
    name: 'dbo.Invoices',
    primaryKey: 'InvoiceId',
    changeColumn: 'ModifiedAt',
    estimatedRows: 33187,
  ),
];

const recentRuns = <SyncRun>[
  SyncRun(
    title: 'Finance-HQ -> Warehouse-01',
    startedAt: '09:55',
    outcome: SyncOutcome.success,
    message: 'Customers, Orders and Inventory completed in 48 seconds.',
  ),
  SyncRun(
    title: 'Finance-HQ -> Branch-07',
    startedAt: '09:50',
    outcome: SyncOutcome.warning,
    message: 'Orders retried once after a network timeout and then succeeded.',
  ),
  SyncRun(
    title: 'Finance-HQ -> Backup-Node',
    startedAt: '09:45',
    outcome: SyncOutcome.failed,
    message: 'Agent offline. Job kept in queue until heartbeat returns.',
  ),
];
