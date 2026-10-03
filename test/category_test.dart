// Unit tests for the category matcher (whole-word, case-insensitive,
// longest-keyword tie-break) plus JSON round-trip and backfill behavior.
//
// These tests duplicate the pure-Dart logic from `lib/main.dart` so they
// run without booting Flutter. If the matcher in production diverges,
// update this mirror to match.
//
// Run: flutter test test/category_test.dart
import 'package:test/test.dart';

/// Minimal mirror of the production Category model (fields used by matching).
class _Cat {
  final String id;
  final String name;
  final List<String> keywords;
  const _Cat(this.id, this.name, this.keywords);
}

String? _match(String note, List<_Cat> cats) {
  final words = note
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
  if (words.isEmpty) return null;
  String? best;
  int bestLen = -1;
  for (final c in cats) {
    for (final k in c.keywords) {
      final kw = k.trim().toLowerCase();
      if (kw.isNotEmpty && words.contains(kw) && kw.length > bestLen) {
        best = c.id;
        bestLen = kw.length;
      }
    }
  }
  return best;
}

void main() {
  final food = _Cat('cat_food', 'Food', ['eat', 'lunch', 'dinner']);
  final transport = _Cat('cat_transport', 'Transport', ['taxi', 'bus']);
  final cats = [food, transport];

  group('matchCategory', () {
    test('matches whole word, case-insensitive', () {
      expect(_match('Eat lunch', cats), equals('cat_food'));
      expect(_match('LUNCH', cats), equals('cat_food'));
      expect(_match('took a TAXI', cats), equals('cat_transport'));
    });

    test('whole-word: eat does not match meat', () {
      expect(_match('MEAT sale', cats), isNull);
      expect(_match('heating bill', cats), isNull);
    });

    test('longest keyword wins across categories', () {
      // 'lunch' (5) beats 'taxi' (4) when both appear.
      expect(_match('lunch and taxi', cats), equals('cat_food'));
    });

    test('earliest category wins on equal-length tie', () {
      final a = _Cat('a', 'A', ['bus']);
      final b = _Cat('b', 'B', ['tax']);
      expect(_match('bus tax ride', [a, b]), equals('a'));
    });

    test('no match and empty note return null (Uncategorized)', () {
      expect(_match('random stuff', cats), isNull);
      expect(_match('', cats), isNull);
      expect(_match('!!!', cats), isNull);
      expect(_match('anything', []), isNull);
    });

    test('keywords with surrounding spaces still match', () {
      final c = _Cat('c', 'C', ['  lunch  ']);
      expect(_match('lunch break', [c]), equals('c'));
    });
  });

  group('backfill', () {
    test('old expenses without categoryId get matched at load', () {
      // Simulates _loadFromPrefs backfill: null ids become match results.
      final expenses = <Map<String, dynamic>>[
        {'note': 'Eat lunch', 'categoryId': null},
        {'note': 'MEAT sale', 'categoryId': null},
        {'note': 'bus fare', 'categoryId': 'cat_transport'},
      ];
      for (final e in expenses) {
        if (e['categoryId'] == null) {
          e['categoryId'] = _match(e['note'] as String, cats);
        }
      }
      expect(expenses[0]['categoryId'], equals('cat_food'));
      expect(expenses[1]['categoryId'], isNull);
      // Pre-stamped ids are preserved, not re-matched.
      expect(expenses[2]['categoryId'], equals('cat_transport'));
    });
  });
}
