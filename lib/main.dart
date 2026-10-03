/// Simple Financial Planner — balance, burn rate, runway.
///
/// A standalone portfolio build: fully usable offline. It tries the optional
/// sync server first, and when that is unreachable (the normal case on a fresh
/// install) it falls back silently to the on-device ledger in
/// SharedPreferences, staying fully editable. The maths mirrors the classic
/// planner rule: the app never auto-adjusts the user's daily budget, it only
/// computes and reports.
///
///   avg_daily   = total_spent_30d / days_with_spend
///   runway_days = balance / avg_daily
library;

// ImageFilter comes from dart:ui; importing it explicitly is
// unambiguous and costs nothing.
import 'dart:async' show runZonedGuarded;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'local_store.dart';

/// Editable by default: a portfolio install has no server and no manager, so
/// the app itself is the only writer. Flip it with
/// --dart-define=VECTOR_READ_ONLY=true for a viewer-only build.
const bool kReadOnly =
    bool.fromEnvironment('VECTOR_READ_ONLY', defaultValue: false);

void main() {
  // In release builds a widget whose build() throws is replaced by a
  // blank ErrorWidget that prints nothing, so the screen just goes white
  // and the device reports no reason. Surface it instead.
  ErrorWidget.builder =
      (FlutterErrorDetails d) => _CrashReport(d);
  // ErrorWidget.builder only catches build() failures. An async error (a
  // prefs read, a network call) would otherwise escape silently and leave the
  // spinner up forever, so the whole app runs inside a guarded zone.
  runZonedGuarded(() {
    runApp(const SimplePlannerApp());
  }, (Object e, StackTrace s) {
    // ignore: avoid_print
    print('zone error: $e\n$s');
  });
}

class C {
  static const bg = Color(0xFFF5F5F7);
  static const bgTop = Color(0xFFEEF1FF);
  static const glass = Color(0xCCFFFFFF);
  static const accent = Color(0xFF6366F1);
  static const success = Color(0xFF10B981);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6B7280);
  static const textTertiary = Color(0xFF9CA3AF);
}

class SimplePlannerApp extends StatelessWidget {
  const SimplePlannerApp({super.key});

  @override
  Widget build(BuildContext context) => CupertinoApp(
        title: 'Simple Financial Planner',
        debugShowCheckedModeBanner: false,
        theme: CupertinoThemeData(
            primaryColor: C.accent, scaffoldBackgroundColor: C.bg),
        // Clamp the system text scale: the big runway number and the money rows
        // ran off the right edge at Android's larger font settings.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.8,
          maxScaleFactor: 1.2,
          child: child ?? const SizedBox.shrink(),
        ),
        home: FinancePage(),
      );
}

class FinancePage extends StatefulWidget {
  const FinancePage({super.key});

  @override
  State<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends State<FinancePage> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  final _balanceController = TextEditingController();
  final _budgetController = TextEditingController();
  final _store = LocalStore();
  Api? _api;
  bool _loading = true;
  bool _usingLocal = true;
  String? _error;
  Map<String, dynamic> _data = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(_bootstrap);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _balanceController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // The ledger must be loaded before any read: rendering (or persisting) a
    // blank default over stored data would silently wipe the user's numbers.
    await _store.load();
    String id = Api.defaultUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString('simple_planner.user_id') ??
          prefs.getString('vector.user_id') ??
          Api.defaultUserId;
    } catch (_) {
      // Prefs failure must not strand the app on a blank screen.
    }
    _api = Api(userId: id);
    await _refresh();
  }

  /// Server first with a short budget; any failure falls back silently to the
  /// on-device ledger. An unreachable server is the normal portfolio case, not
  /// an error worth a red card.
  Future<void> _refresh() async {
    if (!_store.isLoaded) await _store.load();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = _api ?? Api(userId: Api.defaultUserId);
      _api = api;
      final d = await api.finance().timeout(const Duration(seconds: 6));
      if (!mounted) return;
      setState(() {
        _data = d;
        _usingLocal = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = _store.snapshot();
        _usingLocal = true;
        _loading = false;
      });
    }
  }

  Future<void> _addExpense() async {
    final amt = double.tryParse(_amountController.text.trim());
    if (amt == null || amt <= 0) return;
    final note = _noteController.text.trim();
    // Local first: the entry is saved even with no signal.
    await _store.addExpense(amt, note);
    if (!mounted) return;
    _amountController.clear();
    _noteController.clear();
    setState(() {
      _data = _store.snapshot();
      _error = null;
    });
    // Best-effort server sync; never blocks the UI or raises an error.
    final api = _api;
    if (api == null) return;
    try {
      await api.addExpense(amt, note: note.isEmpty ? null : note)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Offline is the normal portfolio case; the entry is already saved.
    }
  }

  /// Null or unparseable fields leave the current value untouched, so a
  /// half-filled form cannot wipe the other number.
  Future<void> _savePlan() async {
    final bal = double.tryParse(_balanceController.text.trim());
    final bud = double.tryParse(_budgetController.text.trim());
    if (bal == null && bud == null) return;
    await _store.savePlan(balance: bal, dailyBudget: bud);
    if (!mounted) return;
    _balanceController.clear();
    _budgetController.clear();
    setState(() {
      _data = _store.snapshot();
      _error = null;
    });
  }

  /// Read a numeric field from the finance payload, or null when it is
  /// absent or wrong-typed. A bad value degrades to '—', never throws.
  ///
  /// The `is` test narrows the type, so the cast is safe and cannot throw.
  num? _num(String key) {
    final v = _data[key];
    if (v is num) return v;
    return null;
  }

  String _money(num? v) {
    if (v == null) return '—';
    final s = v.toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '${_data['currency'] ?? 'IDR'} ${buf.toString()}';
  }

  /// Runway is the number that actually changes behaviour, so it gets the
  /// headline slot rather than being buried under the balance.
  Widget _runwayHero() {
    // A wrong-typed value degrades to the default via _num, never throws.
    final days = _num('runway_days')?.toInt();
    final avg = _num('avg_daily_spend')?.toDouble() ?? 0;
    if (days == null || avg <= 0) {
      return _card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('Runway',
                  style: TextStyle(fontSize: 13, color: C.textTertiary)),
              SizedBox(height: 8),
              Text('No spending logged yet',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: C.textPrimary)),
              SizedBox(height: 6),
              Text('Log an expense and this becomes a real number.',
                  style: TextStyle(fontSize: 13, color: C.textSecondary)),
            ],
          ),
        ),
      );
    }
    final critical = days < 7;
    return _card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('RUNWAY AT CURRENT BURN',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.9,
                    color: critical ? C.danger : C.textTertiary)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('$days',
                    style: TextStyle(
                        fontSize: 44,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: critical ? C.danger : C.textPrimary)),
                const SizedBox(width: 8),
                const Text('days',
                    style: TextStyle(fontSize: 17, color: C.textSecondary)),
              ],
            ),
            const SizedBox(height: 10),
            Text('Burning ${_money(avg)}/day',
                style: const TextStyle(fontSize: 14, color: C.textSecondary)),
            if (critical) ...[
              const SizedBox(height: 12),
              Row(children: const [
                Icon(CupertinoIcons.exclamationmark_triangle,
                    size: 15, color: C.danger),
                SizedBox(width: 7),
                Expanded(
                  child: Text('Under a week of runway left.',
                      style: TextStyle(fontSize: 13, color: C.danger)),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [C.bgTop, C.bg],
          ),
        ),
        child: SafeArea(
          // Cupertino pull-to-refresh: CustomScrollView + slivers.
          // RefreshIndicator is a Material widget and this app imports only
          // package:flutter/cupertino.dart, so it would not compile.
          child: CustomScrollView(
            slivers: [
              CupertinoSliverRefreshControl(onRefresh: _refresh),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                sliver: SliverList(
                  delegate: SliverChildListDelegate(_body()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_loading) {
      return const [
        SizedBox(height: 120),
        Center(child: CupertinoActivityIndicator(radius: 14)),
      ];
    }
    if (_error != null && _data.isEmpty) {
      return [
        const SizedBox(height: 100),
        const Icon(CupertinoIcons.wifi_slash, size: 44, color: C.textTertiary),
        const SizedBox(height: 14),
        Text(_error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: C.textSecondary)),
        const SizedBox(height: 20),
        CupertinoButton(onPressed: _refresh, child: const Text('Retry')),
      ];
    }

    final budget = _num('daily_budget')?.toDouble() ?? 0;
    final spentToday = _num('today_spent')?.toDouble() ?? 0;
    final free = _num('free_today')?.toDouble();
    final progress = budget > 0 ? (spentToday / budget).clamp(0.0, 1.0) : 0.0;

    return [
      const Text('Money',
          style: TextStyle(
              fontSize: 34, fontWeight: FontWeight.w700, color: C.textPrimary)),
      const SizedBox(height: 4),
      Text('Balance ${_money(_num('balance'))}',
          style: const TextStyle(fontSize: 15, color: C.textSecondary)),
      if (_usingLocal)
        const Text('Offline — saved on this device',
            style: TextStyle(fontSize: 13, color: C.textTertiary)),
      const SizedBox(height: 22),
      _runwayHero(),
      const SizedBox(height: 14),
      if (budget > 0)
        _card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Today',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: C.textPrimary)),
                    const SizedBox(width: 8),
                    // Flexible + ellipsis: a large amount plus a large system
                    // text scale used to run this figure off the right edge.
                    Flexible(
                      child: Text(free == null ? '—' : '${_money(free)} free',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: progress >= 1 ? C.danger : C.success)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 6,
                    color: const Color(0x14000000),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: progress,
                      child: Container(
                          color: progress >= 1 ? C.danger : C.accent),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text('${_money(spentToday)} of ${_money(budget)}',
                    style: const TextStyle(
                        fontSize: 13, color: C.textSecondary)),
              ],
            ),
          ),
        ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
            child: _miniStat(_money(_num('spent_30d')), 'last 30 days')),
        const SizedBox(width: 12),
        Expanded(
            child: _miniStat(
                _money(_num('avg_daily_spend')), 'avg per day')),
      ]),
      const SizedBox(height: 26),
      // Viewer mode hides every editing surface so exactly one writer changes
      // the data. The portfolio default is editable (kReadOnly=false).
      if (!kReadOnly) ...[
      const Text('YOUR PLAN',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: C.textTertiary)),
      const SizedBox(height: 10),
      _card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            CupertinoTextField(
              controller: _balanceController,
              placeholder: 'Balance, e.g. 3500000',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              padding: const EdgeInsets.all(14),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 10),
            CupertinoTextField(
              controller: _budgetController,
              placeholder: 'Daily budget, e.g. 150000',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              padding: const EdgeInsets.all(14),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: _savePlan,
                child: const Text('Save plan'),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 22),
      const Text('LOG AN EXPENSE',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: C.textTertiary)),
      const SizedBox(height: 10),
      _card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            CupertinoTextField(
              controller: _amountController,
              placeholder: 'Amount',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              padding: const EdgeInsets.all(14),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 10),
            CupertinoTextField(
              controller: _noteController,
              placeholder: 'Note (optional)',
              padding: const EdgeInsets.all(14),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: _addExpense,
                child: const Text('Add'),
              ),
            ),
          ]),
        ),
      ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(_error!,
            style: const TextStyle(fontSize: 13, color: C.danger)),
      ],
    ];
  }

  Widget _miniStat(String value, String label) => _card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: C.textPrimary)),
              const SizedBox(height: 3),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: C.textSecondary)),
            ],
          ),
        ),
      );

  /// Real Liquid Glass: a BackdropFilter blurs the backdrop, then a translucent
  /// two-stop white sits on top. Flat translucency reads as a plain box.
  Widget _card({required Widget child}) => ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xE6FFFFFF), Color(0xB8FFFFFF)],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x33FFFFFF), width: 1),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 24,
                    offset: Offset(0, 8)),
              ],
            ),
            child: child,
          ),
        ),
      );
}

/// Shown instead of Flutter's default ErrorWidget when a widget's build throws.
///
/// In release builds that default is a blank grey box that prints nothing, so a
/// crash looks exactly like a hung request. This renders the message and stack
/// on screen, which is the only way a failure on a real device is reportable.
class _CrashReport extends StatelessWidget {
  const _CrashReport(this.details);

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final msg = details.exception.toString();
    final stack = details.stack?.toString() ?? '';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF111827),
        padding: const EdgeInsets.all(14),
        child: SingleChildScrollView(
          child: Text(
            'Simple Planner ran into a problem\n\n$msg\n\n$stack',
            style: const TextStyle(color: Color(0xFFF9FAFB), fontSize: 11),
          ),
        ),
      ),
    );
  }
}
