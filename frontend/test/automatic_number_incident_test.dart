import 'package:flutter_test/flutter_test.dart';
import 'package:sync_admin_web/models.dart';

void main() {
  test(
    'automatic number incident preserves operator before and after audit',
    () {
      final incident = AdminAutomaticNumberIncident.fromJson({
        'id': List.filled(64, 'a').join(),
        'clientName': 'velvet-factory',
        'conflictingClientName': 'alshallan2',
        'table': 'AmnDb048.dbo.ce000',
        'status': 'resolved',
        'reason': 'Voucher number collision',
        'numberColumn': 'Number',
        'beforeNumber': '2307',
        'afterNumber': '2308',
        'scope': {'Type': 1, 'Branch': '00000000-0000-0000-0000-000000000000'},
        'primaryKey': {'GUID': 'purchase-guid'},
        'beforeRow': {'GUID': 'purchase-guid', 'Number': 2307},
        'afterRow': {'GUID': 'purchase-guid', 'Number': 2308},
        'operationId': List.filled(64, 'b').join(),
        'detectedAt': '2026-08-24T12:00:00Z',
        'resolvedAt': '2026-08-24T12:01:00Z',
        'updatedAt': '2026-08-24T12:01:00Z',
      });

      expect(incident.clientName, 'velvet-factory');
      expect(incident.conflictingClientName, 'alshallan2');
      expect(incident.beforeNumber, '2307');
      expect(incident.afterNumber, '2308');
      expect(incident.beforeRow['Number'], 2307);
      expect(incident.afterRow['Number'], 2308);
      expect(incident.primaryKey['GUID'], 'purchase-guid');
    },
  );
}
