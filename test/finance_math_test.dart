/// Tests for the offline finance maths in Simple Financial Planner.
///
/// Pure-Dart behaviour tests: CI verifies these without a device or server.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_finance/finance_math.dart';

void main() {
  ExpenseEntry exp(double amount, DateTime ts, [String note = '']) =>
      ExpenseEntry(amount: amount, note: note, timestamp: ts);

  group('computeFinance', () {
    test('empty ledger has no runway and says nothing invented', () {
      final d = computeFinance(
          balance: 3500000,
          dailyBudget: 150000,
          expenses: [],
          now: DateTime(2026, 10, 3, 12));
      expect(d.containsKey('runway_days'), isFalse);
      expect(d['avg_daily_spend'], 0.0);
      expect(d['today_spent'], 0.0);
      expect(d['free_today'], 150000);
      expect(d['local'], isTrue);
    });

    test('runway is balance over average daily burn', () {
      // 90k/day average over 3 spend days; 900k balance -> 10 days.
      final now = DateTime(2026, 10, 3, 12);
      final d = computeFinance(
        balance: 900000,
        dailyBudget: 150000,
        expenses: [
          exp(100000, DateTime(2026, 10, 1, 9)),
          exp(80000, DateTime(2026, 10, 2, 9)),
          exp(90000, DateTime(2026, 10, 3, 9)),
        ],
        now: now,
      );
      expect(d['spent_30d'], 270000);
      expect(d['avg_daily_spend'], 90000);
      expect(d['runway_days'], 10);
      expect(d['today_spent'], 90000);
      expect(d['free_today'], 60000);
    });

    test('multiple spends on one day count as one burn day', () {
      final now = DateTime(2026, 10, 3, 12);
      final d = computeFinance(
        balance: 200000,
        dailyBudget: 150000,
        expenses: [
          exp(50000, DateTime(2026, 10, 3, 9)),
          exp(50000, DateTime(2026, 10, 3, 18)),
        ],
        now: now,
      );
      expect(d['avg_daily_spend'], 100000);
      expect(d['runway_days'], 2);
    });

    test('spending older than 30 days is ignored', () {
      final now = DateTime(2026, 10, 3, 12);
      final d = computeFinance(
        balance: 100000,
        dailyBudget: 50000,
        expenses: [
          exp(999999, DateTime(2026, 8, 1, 9)),
          exp(50000, DateTime(2026, 10, 3, 9)),
        ],
        now: now,
      );
      expect(d['spent_30d'], 50000);
      expect(d['runway_days'], 2);
    });
  });

  group('ExpenseEntry.fromJson', () {
    test('a corrupt row returns null instead of throwing', () {
      expect(ExpenseEntry.fromJson(null), isNull);
      expect(ExpenseEntry.fromJson('junk'), isNull);
      expect(ExpenseEntry.fromJson({'amount': 'abc', 'ts': 1}), isNull);
      expect(ExpenseEntry.fromJson({'amount': 5}), isNull);
    });

    test('a good row round-trips through toJson', () {
      final e = exp(25000, DateTime(2026, 10, 2, 8), 'kopi');
      final back = ExpenseEntry.fromJson(e.toJson());
      expect(back, isNotNull);
      expect(back!.amount, 25000);
      expect(back.note, 'kopi');
    });
  });
}
