import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/table_comparison.dart';

void main() {
  test('aligns multiple clients by primary key and reports changed cells', () {
    final differences = buildTableComparisonDifferences(
      keyColumns: const ['Id'],
      clients: const [
        TableComparisonClientRows(
          clientName: 'factory',
          columns: ['Id', 'Name'],
          rows: [
            {'Id': '1', 'Name': 'same'},
            {'Id': '2', 'Name': 'factory'},
          ],
          reportedRowCount: 2,
          truncated: false,
        ),
        TableComparisonClientRows(
          clientName: 'home',
          columns: ['Id', 'Name'],
          rows: [
            {'Id': '1', 'Name': 'same'},
            {'Id': '2', 'Name': 'home'},
            {'Id': '3', 'Name': 'home only'},
          ],
          reportedRowCount: 3,
          truncated: false,
        ),
        TableComparisonClientRows(
          clientName: 'shop',
          columns: ['Id', 'Name'],
          rows: [
            {'Id': '1', 'Name': 'same'},
            {'Id': '2', 'Name': 'factory'},
          ],
          reportedRowCount: 2,
          truncated: false,
        ),
      ],
    );

    expect(differences, hasLength(2));
    expect(differences.first.changedColumns, ['Name']);
    expect(differences.last.rowsByClient['factory'], isNull);
    expect(differences.last.rowsByClient['home']?['Name'], 'home only');
  });

  test('ignores transport metadata and identical rows', () {
    final differences = buildTableComparisonDifferences(
      keyColumns: const ['Id'],
      clients: const [
        TableComparisonClientRows(
          clientName: 'a',
          columns: ['Id', 'Name'],
          rows: [
            {'Id': '1', 'Name': 'same', '__sync_operation_id': 'one'},
          ],
          reportedRowCount: 1,
          truncated: false,
        ),
        TableComparisonClientRows(
          clientName: 'b',
          columns: ['Id', 'Name'],
          rows: [
            {'Id': '1', 'Name': 'same', '__sync_operation_id': 'two'},
          ],
          reportedRowCount: 1,
          truncated: false,
        ),
      ],
    );

    expect(differences, isEmpty);
  });

  test('does not report a missing row until paged client data is complete', () {
    final differences = buildTableComparisonDifferences(
      keyColumns: const ['Id'],
      includeMissingRows: false,
      clients: const [
        TableComparisonClientRows(
          clientName: 'a',
          columns: ['Id', 'Name'],
          rows: [
            {'Id': '1', 'Name': 'loaded first'},
          ],
          reportedRowCount: 2,
          truncated: true,
        ),
        TableComparisonClientRows(
          clientName: 'b',
          columns: ['Id', 'Name'],
          rows: [],
          reportedRowCount: 2,
          truncated: true,
        ),
      ],
    );

    expect(differences, isEmpty);
  });
}
