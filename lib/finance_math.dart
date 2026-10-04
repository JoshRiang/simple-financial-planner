/// Offline finance maths for SpendLog.
///
/// Pure functions (no Flutter, no plugins) so CI can unit-test the runway
/// calculation without a device or a live server.
library;

class ExpenseEntry {
  ExpenseEntry(
      {required this.amount, required this.note, required this.timestamp});

  final double amount;
  final String note;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'amount': amount,
        'note': note,
        'ts': timestamp.millisecondsSinceEpoch,
      };

  /// Null when the stored row is the wrong shape: a corrupt row is skipped,
  /// never allowed to crash the ledger load.
  static ExpenseEntry? fromJson(dynamic v) {
    if (v is! Map) return null;
    final a = v['amount'];
    final ts = v['ts'];
    if (a is! num || ts is! num) return null;
    final note = v['note'];
    return ExpenseEntry(
      amount: a.toDouble(),
      note: note is String ? note : '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts.toInt()),
    );
  }
}

/// Builds the same payload shape the server returns, from on-device data.
///
/// Mirrors the planner maths the app has always used:
///   avg_daily   = total_spent_30d / days_with_spend
///   runway_days = balance / avg_daily
/// With no spending there is no honest burn rate, so `runway_days` is omitted
/// and the UI renders "No spending logged yet" instead of inventing a figure.
Map<String, dynamic> computeFinance({
  required double balance,
  required double dailyBudget,
  required List<ExpenseEntry> expenses,
  required DateTime now,
  String currency = 'IDR',
}) {
  final today = DateTime(now.year, now.month, now.day);
  final cutoff = today.subtract(const Duration(days: 30));
  var todaySpent = 0.0;
  var spent30d = 0.0;
  final daysWithSpend = <String>{};
  for (final e in expenses) {
    final t = e.timestamp;
    final d = DateTime(t.year, t.month, t.day);
    if (d == today) todaySpent += e.amount;
    if (!d.isBefore(cutoff) && !d.isAfter(today)) {
      spent30d += e.amount;
      daysWithSpend.add('${d.year}-${d.month}-${d.day}');
    }
  }
  final avg = daysWithSpend.isEmpty ? 0.0 : spent30d / daysWithSpend.length;
  final runway = avg > 0 ? (balance / avg).floor() : null;
  return <String, dynamic>{
    'balance': balance,
    'daily_budget': dailyBudget,
    'today_spent': todaySpent,
    'free_today': dailyBudget - todaySpent,
    'spent_30d': spent30d,
    'avg_daily_spend': avg,
    if (runway != null) 'runway_days': runway,
    'currency': currency,
    'local': true,
  };
}
