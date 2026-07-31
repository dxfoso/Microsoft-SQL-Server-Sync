import 'dart:async';

import 'package:flutter/material.dart';

import 'live_sync_api.dart';
import 'models.dart';
import 'table_comparison.dart';

class TableComparisonDialog extends StatefulWidget {
  const TableComparisonDialog({
    super.key,
    required this.api,
    required this.clientName,
    required this.table,
    required this.issue,
  });

  final LiveSyncApiClient api;
  final String clientName;
  final String table;
  final AdminTableSyncIssue issue;

  @override
  State<TableComparisonDialog> createState() => _TableComparisonDialogState();
}

class _TableComparisonDialogState extends State<TableComparisonDialog> {
  static const _maximumRowsPerClient = 5000;
  static const _maximumVisibleDifferences = 200;

  AdminTableComparisonStatus? _status;
  List<TableComparisonClientRows> _clients = const [];
  List<TableComparisonDifference> _differences = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final request = await widget.api.requestTableComparison(
        clientName: widget.clientName,
        table: widget.table,
      );
      if (request.requestId.isEmpty) {
        throw const LiveSyncApiException(
          'The server did not return a comparison request ID.',
        );
      }
      AdminTableComparisonStatus? status;
      for (var attempt = 0; attempt < 90; attempt += 1) {
        if (!mounted) return;
        status = await widget.api.fetchTableComparisonStatus(request.requestId);
        setState(() => _status = status);
        if (status.failed) {
          final detail = status.jobs
              .where(
                (job) =>
                    job.status.toLowerCase() == 'failed' ||
                    job.status.toLowerCase() == 'cancelled',
              )
              .map((job) => '${job.clientName}: ${job.error ?? job.message}')
              .join('\n');
          throw LiveSyncApiException(
            detail.isEmpty ? 'A client comparison snapshot failed.' : detail,
          );
        }
        if (status.complete) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (status == null || !status.complete) {
        throw const LiveSyncApiException(
          'Timed out waiting for clients to upload comparison rows.',
        );
      }
      if (status.keyColumns.isEmpty) {
        throw const LiveSyncApiException(
          'The comparison did not report primary-key columns.',
        );
      }
      final clients = <TableComparisonClientRows>[];
      for (final job in status.jobs) {
        clients.add(await _fetchClientRows(job));
      }
      final differences = buildTableComparisonDifferences(
        keyColumns: status.keyColumns,
        clients: clients,
      );
      if (!mounted) return;
      setState(() {
        _clients = clients;
        _differences = differences;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<TableComparisonClientRows> _fetchClientRows(AdminJob job) async {
    final rows = <Map<String, dynamic>>[];
    final columns = <String>[];
    String? cursor;
    var done = false;
    var reportedRowCount = job.rowCount;
    while (!done && rows.length < _maximumRowsPerClient) {
      final page = await widget.api.fetchSyncJobData(
        jobId: job.id,
        cursor: cursor,
      );
      for (final column in page.columns) {
        if (!columns.contains(column)) columns.add(column);
      }
      final remaining = _maximumRowsPerClient - rows.length;
      rows.addAll(page.rows.take(remaining));
      reportedRowCount = page.retainedRowCount;
      done = page.done || page.nextCursor?.trim().isNotEmpty != true;
      cursor = page.nextCursor;
    }
    return TableComparisonClientRows(
      clientName: job.clientName,
      columns: columns,
      rows: rows,
      reportedRowCount: reportedRowCount,
      truncated: !done || reportedRowCount > rows.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: (size.width - 40).clamp(320, 1320).toDouble(),
        height: (size.height - 40).clamp(360, 820).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.difference_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Compare client rows',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          widget.table,
                          style: const TextStyle(color: Color(0xFF667085)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return _buildLoading();
    if (_error != null) return _buildError();
    final visible = _differences.take(_maximumVisibleDifferences).toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final client in _clients)
                Chip(
                  avatar: const Icon(Icons.computer_rounded, size: 16),
                  label: Text(
                    '${client.clientName}: ${client.reportedRowCount} rows'
                    '${client.truncated ? ' (first ${client.rows.length} loaded)' : ''}',
                  ),
                ),
              Chip(
                avatar: const Icon(Icons.difference_rounded, size: 16),
                label: Text('${_differences.length} different keys'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Rows are aligned by ${_status!.keyColumns.join(', ')}. Only differing fields are shown. This read-only comparison does not advance Change Tracking or change SQL data.',
            style: const TextStyle(
              color: Color(0xFF667085),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child:
                visible.isEmpty
                    ? const Center(
                      child: Text(
                        'No row differences were found in the loaded data.',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    )
                    : Scrollbar(
                      child: SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            dataRowMinHeight: 64,
                            dataRowMaxHeight: 220,
                            columns: [
                              const DataColumn(label: Text('Primary key')),
                              for (final client in _clients)
                                DataColumn(label: Text(client.clientName)),
                            ],
                            rows: [
                              for (final difference in visible)
                                DataRow(
                                  cells: [
                                    DataCell(
                                      SizedBox(
                                        width: 180,
                                        child: SelectableText(difference.key),
                                      ),
                                    ),
                                    for (final client in _clients)
                                      DataCell(
                                        _buildDifferenceCell(
                                          difference,
                                          client.clientName,
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
          ),
          if (_differences.length > visible.length)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Showing the first ${visible.length} of ${_differences.length} differing keys.',
                style: const TextStyle(color: Color(0xFFB54708)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    final jobs = _status?.jobs ?? const <AdminJob>[];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text(
              'Requesting read-only snapshots from every client…',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            if (jobs.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final job in jobs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(job.clientName)),
                      Text('${job.status} ${job.progress}%'),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Comparison could not be completed',
            style: TextStyle(
              color: Color(0xFFB42318),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(_error!),
          const SizedBox(height: 12),
          Text(
            widget.issue.message,
            style: const TextStyle(color: Color(0xFF667085)),
          ),
        ],
      ),
    );
  }

  Widget _buildDifferenceCell(
    TableComparisonDifference difference,
    String clientName,
  ) {
    final row = difference.rowsByClient[clientName];
    if (row == null) {
      return Container(
        width: 260,
        padding: const EdgeInsets.all(8),
        color: const Color(0xFFFFE4E8),
        child: const Text(
          'Row missing',
          style: TextStyle(
            color: Color(0xFFB42318),
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    return Container(
      width: 260,
      padding: const EdgeInsets.all(8),
      color: const Color(0xFFFFF6ED),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final column in difference.changedColumns)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(
                '$column: ${tableComparisonValue(row[column])}',
                style: const TextStyle(fontSize: 12, height: 1.3),
              ),
            ),
        ],
      ),
    );
  }
}
