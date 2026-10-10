import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/media_download_manager.dart';
import '../services/message_cleanup.dart';
import '../services/pending_send_retrier.dart';
import '../services/upload_progress_bus.dart';
import '../storage/chat_store.dart';
import '../storage/pending_send_store.dart';
import '../theme/app_theme.dart';

/// Панель передач (ТЗ). Вызывается по иконке ⇅ из шапки списка чатов и
/// шапки конкретного чата. Окно 5/6 × 5/6 экрана, отцентрировано, без тени.
/// Закрывается тапом мимо. Две вкладки Upload/Download, каждая — две
/// колонки (text/files и manual/automatic). Завершённые строки плавно
/// исчезают.
Future<void> showTransfersPanel(BuildContext context) {
  final screen = MediaQuery.of(context).size;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('transfers.title'),
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, a1, a2) {
      return Center(
        child: SizedBox(
          width: screen.width * 5 / 6,
          height: screen.height * 5 / 6,
          child: Material(
            color: AppColors.surface,
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(16),
            child: const _TransfersPanel(),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(begin: 0.97, end: 1.0).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
  );
}

class _TransfersPanel extends StatefulWidget {
  const _TransfersPanel();

  @override
  State<_TransfersPanel> createState() => _TransfersPanelState();
}

class _TransfersPanelState extends State<_TransfersPanel> {
  int _tab = 0; // 0 = upload, 1 = download

  DownloadSnapshot _dl = const DownloadSnapshot([], []);
  List<UploadRow> _upFiles = [];
  List<({String peerLogin, String messageId, String text})> _upText = [];

  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _refresh();
    void bump(dynamic _) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 120), _refresh);
    }

    _subs.add(MediaDownloadManager.instance.snapshotChanges.listen(bump));
    _subs.add(MediaDownloadManager.instance.progressChanges.listen(bump));
    _subs.add(PendingSendRetrier.instance.snapshotChanges.listen(bump));
    _subs.add(UploadProgressBus.stream.listen(bump));
    _subs.add(ChatStore.changes.listen(bump));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final jobs = await PendingSendStore.getAll();
    final files = PendingSendRetrier.instance.snapshot(jobs);
    final text = await ChatStore.getSendingTextMessages();
    if (!mounted) return;
    setState(() {
      _dl = MediaDownloadManager.instance.snapshot();
      _upFiles = files;
      _upText = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _tabs(),
        Divider(height: 1, color: AppColors.textMuted.withValues(alpha: 0.18)),
        Expanded(child: _tab == 0 ? _uploadTab() : _downloadTab()),
      ],
    );
  }

  Widget _tabs() {
    // Разделитель вкладок — диагональ (не строго вертикальная черта),
    // чтобы визуально не сливался с вертикальным делителем колонок под
    // ним. Активная вкладка — с подсветкой и ярче, неактивная — тусклее.
    return SizedBox(
      height: 46,
      child: CustomPaint(
        painter: _TabSplitPainter(
          activeTab: _tab,
          fill: AppColors.primary.withValues(alpha: 0.13),
          line: AppColors.primary.withValues(alpha: 0.55),
        ),
        child: Row(
          children: [
            _tabButton(0, tr('transfers.upload')),
            _tabButton(1, tr('transfers.download')),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(int index, String label) {
    final active = _tab == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = index),
        child: Container(
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              color: active
                  ? AppColors.primary
                  : AppColors.textMuted.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _uploadTab() {
    return _twoColumns(
      leftTitle: tr('transfers.textQueue'),
      left: [
        for (final t in _upText)
          _RowVM(
            key: 't:${t.messageId}',
            cancelId: t.messageId,
            label: tr('transfers.textMessage'),
            peer: t.peerLogin,
            percent: 0,
            showPercent: false,
            onCancel: () => cancelOutgoingMessages(t.peerLogin, [t.messageId]),
          ),
      ],
      rightTitle: tr('transfers.fileQueue'),
      right: [
        for (final r in _upFiles)
          _RowVM(
            key: 'f:${r.rowKey}',
            cancelId: r.id,
            label: r.label,
            peer: r.peerLogin,
            percent: r.percent,
            showPercent: r.active,
            // Строка файла группы (rowKey != id задания) — ✕ убирает только
            // этот файл из группы; одиночный файл — всё задание целиком.
            onCancel: r.rowKey != r.id
                ? () => PendingSendRetrier.instance.cancelGroupItem(
                    r.id,
                    r.rowKey,
                  )
                : () => PendingSendRetrier.instance.cancelJob(r.id),
          ),
      ],
    );
  }

  Widget _downloadTab() {
    _RowVM dlRow(DownloadRow r, String prefix) => _RowVM(
      key: '$prefix:${r.mediaId}',
      cancelId: r.mediaId,
      label: r.label,
      peer: r.peerLogin,
      percent: r.percent,
      showPercent: r.active,
      onCancel: () =>
          MediaDownloadManager.instance.cancelUserDownload(r.mediaId),
    );
    return _twoColumns(
      leftTitle: tr('transfers.manualQueue'),
      left: [for (final r in _dl.manual) dlRow(r, 'm')],
      rightTitle: tr('transfers.autoQueue'),
      right: [for (final r in _dl.auto) dlRow(r, 'a')],
    );
  }

  Widget _twoColumns({
    required String leftTitle,
    required List<_RowVM> left,
    required String rightTitle,
    required List<_RowVM> right,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _column(leftTitle, left)),
        VerticalDivider(
          width: 1,
          color: AppColors.textMuted.withValues(alpha: 0.18),
        ),
        Expanded(child: _column(rightTitle, right)),
      ],
    );
  }

  Widget _column(String title, List<_RowVM> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppColors.textMuted,
            ),
          ),
        ),
        Expanded(child: _TransferList(rows: rows)),
      ],
    );
  }
}

class _RowVM {
  final String key;
  final String cancelId;
  final String label;
  final String peer;
  final double percent;
  final bool showPercent;
  final VoidCallback onCancel;
  const _RowVM({
    required this.key,
    required this.cancelId,
    required this.label,
    required this.peer,
    required this.percent,
    required this.showPercent,
    required this.onCancel,
  });
}

/// Список строк с плавным появлением/исчезновением. Ушедшая из [rows]
/// строка ещё ~260 мс держится с анимацией сворачивания.
class _TransferList extends StatefulWidget {
  final List<_RowVM> rows;
  const _TransferList({required this.rows});

  @override
  State<_TransferList> createState() => _TransferListState();
}

class _TransferListState extends State<_TransferList> {
  final Map<String, _RowVM> _departing = {};
  final Set<String> _known = {};

  @override
  void didUpdateWidget(_TransferList old) {
    super.didUpdateWidget(old);
    final nowKeys = widget.rows.map((r) => r.key).toSet();
    for (final r in old.rows) {
      if (!nowKeys.contains(r.key) && !_departing.containsKey(r.key)) {
        _departing[r.key] = r;
        Future.delayed(const Duration(milliseconds: 280), () {
          if (mounted) setState(() => _departing.remove(r.key));
        });
      }
    }
    for (final k in nowKeys) {
      _departing.remove(k);
    }
    _known.retainWhere(nowKeys.contains);
  }

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      for (final r in widget.rows) _row(r, departing: false),
      for (final r in _departing.values) _row(r, departing: true),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: items,
    );
  }

  Widget _row(_RowVM r, {required bool departing}) {
    final firstSeen = _known.add(r.key);
    return _AnimatedRow(
      key: ValueKey(r.key),
      appear: firstSeen && !departing,
      departing: departing,
      child: _rowContent(r, departing),
    );
  }

  Widget _rowContent(_RowVM r, bool departing) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 5, 2, 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  r.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
                ),
                Text(
                  r.peer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          if (r.showPercent)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '${r.percent.round()}%',
                style: TextStyle(fontSize: 11, color: AppColors.primary),
              ),
            ),
          if (!departing)
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              icon: Icon(Icons.close, color: AppColors.textMuted),
              onPressed: r.onCancel,
            ),
        ],
      ),
    );
  }
}

/// Фон панели вкладок: заливка активной вкладки (параллелограмм со
/// скошенным краем) + сама диагональная черта-разделитель.
class _TabSplitPainter extends CustomPainter {
  final int activeTab; // 0 = левая (upload), 1 = правая (download)
  final Color fill;
  final Color line;
  const _TabSplitPainter({
    required this.activeTab,
    required this.fill,
    required this.line,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;
    const slant = 16.0;
    final topX = mid + slant; // диагональ идёт из правого-верха…
    final botX = mid - slant; // …в левый-низ

    final path = Path();
    if (activeTab == 0) {
      path
        ..moveTo(0, 0)
        ..lineTo(topX, 0)
        ..lineTo(botX, size.height)
        ..lineTo(0, size.height)
        ..close();
    } else {
      path
        ..moveTo(topX, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(botX, size.height)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawLine(
      Offset(topX, 0),
      Offset(botX, size.height),
      Paint()
        ..color = line
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_TabSplitPainter old) =>
      old.activeTab != activeTab || old.fill != fill || old.line != line;
}

class _AnimatedRow extends StatefulWidget {
  final bool appear;
  final bool departing;
  final Widget child;
  const _AnimatedRow({
    super.key,
    required this.appear,
    required this.departing,
    required this.child,
  });

  @override
  State<_AnimatedRow> createState() => _AnimatedRowState();
}

class _AnimatedRowState extends State<_AnimatedRow> {
  late double _t = widget.appear ? 0 : 1;

  @override
  void initState() {
    super.initState();
    if (widget.appear) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _t = 1);
      });
    }
  }

  @override
  void didUpdateWidget(_AnimatedRow old) {
    super.didUpdateWidget(old);
    if (widget.departing && _t != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _t = 0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _t,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: _t == 0 && widget.departing
            ? const SizedBox(width: double.infinity)
            : widget.child,
      ),
    );
  }
}
