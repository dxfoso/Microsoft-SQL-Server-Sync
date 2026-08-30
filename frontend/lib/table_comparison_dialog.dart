import 'dart:async';

import 'package:flutter/material.dart';

import 'live_sync_api.dart';
import 'models.dart';
import 'table_comparison.dart';
import 'theme.dart';

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
  static const _keyColumnWidth = 200.0;
  static const _clientColumnWidth = 280.0;

  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();
  AdminTableComparisonStatus? _status;
  List<_ClientComparisonPageState> _pageStates = const [];
  List<TableComparisonClientRows> _clients = const [];
  List<TableComparisonDifference> _differences = const [];
  List<String> _skippedOfflineClients = const [];
  String? _error;
  String? _pageError;
  bool _loading = true;
  bool _loadingMore = false;
  bool _allPagesLoaded = false;

  @override
  void initState() {
    super.initState();
    _verticalController.addListener(_loadMoreNearBottom);
    unawaited(_load());
  }

  @override
  void dispose() {
    _verticalController
      ..removeListener(_loadMoreNearBottom)
      ..dispose();
    _horizontalController.dispose();
    super.dispose();
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
      if (mounted && request.skippedOfflineClients.isNotEmpty) {
        setState(() => _skippedOfflineClients = request.skippedOfflineClients);
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
      if (!mounted) return;
      setState(() {
        _pageStates = status!.jobs
            .map(_ClientComparisonPageState.new)
            .toList(growable: false);
      });
      await _loadNextPages();
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _loadMoreNearBottom() {
    if (!_verticalController.hasClients || _allPagesLoaded || _loadingMore) {
      return;
    }
    if (_verticalController.position.extentAfter < 480) {
      unawaited(_loadNextPages());
    }
  }

  Future<void> _loadNextPages() async {
    if (_loadingMore || _pageStates.isEmpty || _allPagesLoaded) return;
    if (mounted) {
      setState(() {
        _loadingMore = true;
        _pageError = null;
      });
    }
    try {
      await Future.wait(
        _pageStates.where((state) => !state.done).map(_fetchNextClientPage),
      );
      if (!mounted) return;
      final allPagesLoaded = _pageStates.every((state) => state.done);
      final clients = _pageStates
          .map((state) => state.toClientRows())
          .toList(growable: false);
      final differences = buildTableComparisonDifferences(
        keyColumns: _status!.keyColumns,
        clients: clients,
        // A key absent from a partial page may exist in a later page. Only
        // call it missing after every client stream has been exhausted.
        includeMissingRows: allPagesLoaded,
      );
      setState(() {
        _clients = clients;
        _differences = differences;
        _allPagesLoaded = allPagesLoaded;
      });
      _prefetchIfViewportIsNotFilled();
    } catch (error) {
      if (!mounted) return;
      setState(() => _pageError = error.toString());
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _fetchNextClientPage(_ClientComparisonPageState state) async {
    final page = await widget.api.fetchSyncJobData(
      jobId: state.job.id,
      cursor: state.cursor,
    );
    for (final column in page.columns) {
      if (!state.columns.contains(column)) state.columns.add(column);
    }
    state.rows.addAll(page.rows);
    state.reportedRowCount = page.retainedRowCount;
    state.cursor = page.nextCursor;
    state.done = page.done || page.nextCursor?.trim().isNotEmpty != true;
  }

  void _prefetchIfViewportIsNotFilled() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _allPagesLoaded || _loadingMore) return;
      if (!_verticalController.hasClients ||
          _verticalController.position.maxScrollExtent < 320) {
        unawaited(_loadNextPages());
      }
    });
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
                          style: TextStyle(color: AppTokens.of(context).muted),
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
    final t = AppTokens.of(context);
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
            style: TextStyle(
              color: t.muted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          if (_skippedOfflineClients.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: t.warnWash,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: t.warn.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded, size: 16, color: t.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline, not included: ${_skippedOfflineClients.join(', ')}. '
                      'Reconnect and re-run to compare every client.',
                      style: TextStyle(
                        color: t.warn,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(child: _buildComparisonGrid()),
          if (_pageError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _pageError!,
                      style: TextStyle(color: t.crit),
                    ),
                  ),
                  TextButton(
                    onPressed:
                        _loadingMore ? null : () => unawaited(_loadNextPages()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComparisonGrid() {
    final t = AppTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth =
            _keyColumnWidth + (_clients.length * _clientColumnWidth);
        return Scrollbar(
          controller: _horizontalController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: contentWidth.clamp(constraints.maxWidth, double.infinity),
              height: constraints.maxHeight,
              child: Column(
                children: [
                  Container(
                    height: 46,
                    color: t.surface2,
                    child: Row(
                      children: [
                        _comparisonHeaderCell('Primary key', _keyColumnWidth),
                        for (final client in _clients)
                          _comparisonHeaderCell(
                            client.clientName,
                            _clientColumnWidth,
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Scrollbar(
                      controller: _verticalController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _verticalController,
                        itemCount: _differences.length + 1,
                        itemBuilder: (context, index) {
                          if (index == _differences.length) {
                            return _buildPagingFooter();
                          }
                          final difference = _differences[index];
                          return Container(
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: t.hairline),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: _keyColumnWidth,
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: SelectableText(
                                      difference.key,
                                      style: TextStyle(color: t.ink),
                                    ),
                                  ),
                                ),
                                for (final client in _clients)
                                  _buildDifferenceCell(
                                    difference,
                                    client.clientName,
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _comparisonHeaderCell(String label, double width) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: AppTokens.of(context).ink2,
          ),
        ),
      ),
    );
  }

  Widget _buildPagingFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (!_allPagesLoaded) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: () => unawaited(_loadNextPages()),
            icon: const Icon(Icons.expand_more_rounded, size: 17),
            label: const Text('Load more comparison rows'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Center(
        child: Text(
          _differences.isEmpty
              ? 'No row differences were found.'
              : 'All retained rows compared.',
          style: TextStyle(
            color: AppTokens.of(context).muted,
            fontWeight: FontWeight.w700,
          ),
        ),
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
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Comparison could not be completed',
            style: TextStyle(
              color: t.crit,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(_error!),
          const SizedBox(height: 12),
          Text(
            widget.issue.message,
            style: TextStyle(color: t.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildDifferenceCell(
    TableComparisonDifference difference,
    String clientName,
  ) {
    final t = AppTokens.of(context);
    final row = difference.rowsByClient[clientName];
    if (row == null) {
      return Container(
        width: _clientColumnWidth,
        padding: const EdgeInsets.all(8),
        color: t.critWash,
        child: Text(
          'Row missing',
          style: TextStyle(
            color: t.crit,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    return Container(
      width: _clientColumnWidth,
      padding: const EdgeInsets.all(8),
      color: t.warnWash,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final column in difference.changedColumns)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(
                '$column: ${tableComparisonValue(row[column])}',
                style: TextStyle(fontSize: 12, height: 1.3, color: t.ink2),
              ),
            ),
        ],
      ),
    );
  }
}

class _ClientComparisonPageState {
  _ClientComparisonPageState(this.job) : reportedRowCount = job.rowCount;

  final AdminJob job;
  final List<String> columns = [];
  final List<Map<String, dynamic>> rows = [];
  String? cursor;
  int reportedRowCount;
  bool done = false;

  TableComparisonClientRows toClientRows() => TableComparisonClientRows(
    clientName: job.clientName,
    columns: List.unmodifiable(columns),
    rows: List.unmodifiable(rows),
    reportedRowCount: reportedRowCount,
    truncated: !done || reportedRowCount > rows.length,
  );
}
