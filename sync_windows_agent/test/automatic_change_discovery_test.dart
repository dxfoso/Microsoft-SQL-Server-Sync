import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/automatic_change_discovery.dart';

void main() {
  test('query establishes baselines and detects table-specific changes', () {
    final query = buildAutomaticChangeDiscoveryQuery(
      database: 'AmnDb028',
      tableBaselines: {'dbo.pt000': 42, 'mt000': null},
    );

    expect(query, contains('USE [AmnDb028]'));
    expect(query, contains("N'dbo', N'pt000', N'dbo.pt000', 42"));
    expect(query, contains("N'dbo', N'mt000', N'mt000', NULL"));
    expect(query, contains('CHANGETABLE(CHANGES'));
    expect(query, contains('SYS_CHANGE_CONTEXT <> 0x53514C53594E43'));
    expect(query, contains("N'baseline'"));
    expect(query, contains("N'expired'"));
  });

  test('parser distinguishes changed, baseline, unchanged, and expired', () {
    final probes = parseAutomaticChangeDiscoveryOutput([
      ['auto_change', 'pt000', '101', '5', 'changed'],
      ['auto_change', 'mt000', '101', '5', 'baseline'],
      ['auto_change', 'bi000', '101', '5', 'unchanged'],
      ['auto_change', 'bad000', '101', '50', 'expired'],
      ['noise'],
    ]);

    expect(probes, hasLength(4));
    expect(probes[0].hasChanges, isTrue);
    expect(probes[1].canAdvanceBaseline, isTrue);
    expect(probes[2].canAdvanceBaseline, isTrue);
    expect(probes[3].baselineExpired, isTrue);
  });

  test('identifiers and literals are escaped', () {
    final query = buildAutomaticChangeDiscoveryQuery(
      database: 'db]name',
      tableBaselines: {"odd'schema.ta'ble": 7},
    );

    expect(query, contains('USE [db]]name]'));
    expect(query, contains("N'odd''schema'"));
    expect(query, contains("N'ta''ble'"));
  });
}
