/// On-device data layer for SpendLog.
///
/// The app tries the optional server first; when it is unreachable (the
/// normal case for a portfolio install) everything runs from these
/// SharedPreferences keys instead, so the app stays fully usable offline.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'finance_math.dart';

class LocalStore {
  static const balanceKey = 'simple_planner.balance';
  static const budgetKey = 'simple_planner.daily_budget';
  static const expensesKey = 'simple_planner.expenses_json';

  bool _loaded = false;
  double _balance = 0;
  double _dailyBudget = 0;
  List<ExpenseEntry> _expenses = [];

  /// Guard: callers must not read a snapshot before [load] has run, or they
  /// would render (and then overwrite) blank defaults over real data.
  bool get isLoaded => _loaded;

  double get balance => _balance;

  double get dailyBudget => _dailyBudget;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final b = prefs.getDouble(balanceKey);
      final d = prefs.getDouble(budgetKey);
      if (b != null) _balance = b;
      if (d != null) _dailyBudget = d;
      final raw = prefs.getString(expensesKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final entries = <ExpenseEntry>[];
          for (final e in decoded) {
            final entry = ExpenseEntry.fromJson(e);
            if (entry != null) entries.add(entry);
          }
          _expenses = entries;
        }
      }
    } catch (_) {
      // Corrupt prefs must not strand the app on a blank screen: keep the
      // in-memory defaults and let the user keep typing.
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(balanceKey, _balance);
      await prefs.setDouble(budgetKey, _dailyBudget);
      await prefs.setString(expensesKey,
          jsonEncode([for (final e in _expenses) e.toJson()]));
    } catch (_) {
      // A failed write keeps the in-memory state; the screen stays usable.
    }
  }

  /// Current finance payload computed from on-device data. Never throws.
  Map<String, dynamic> snapshot() {
    try {
      return computeFinance(
        balance: _balance,
        dailyBudget: _dailyBudget,
        expenses: List<ExpenseEntry>.unmodifiable(_expenses),
        now: DateTime.now(),
      );
    } catch (_) {
      return <String, dynamic>{
        'balance': _balance,
        'daily_budget': _dailyBudget,
        'today_spent': 0.0,
        'free_today': _dailyBudget,
        'spent_30d': 0.0,
        'avg_daily_spend': 0.0,
        'currency': 'IDR',
        'local': true,
      };
    }
  }

  Future<void> addExpense(double amount, String note) async {
    _expenses.add(ExpenseEntry(
        amount: amount, note: note, timestamp: DateTime.now()));
    await _persist();
  }

  /// Null arguments leave the current value untouched, so a half-filled form
  /// cannot wipe the other field.
  Future<void> savePlan({double? balance, double? dailyBudget}) async {
    if (balance != null) _balance = balance;
    if (dailyBudget != null) _dailyBudget = dailyBudget;
    await _persist();
  }
}
